using Azure.Core;
using Microsoft.Extensions.Options;

namespace BglWebhookReceiver.Tests;

public class FlowAuthHandlerTests
{
    private sealed class FakeCredential : TokenCredential
    {
        public List<string> Scopes { get; } = [];
        public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken)
        {
            Scopes.AddRange(requestContext.Scopes);
            return new("token-1", DateTimeOffset.UtcNow.AddHours(1));
        }
        public override ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken)
            => ValueTask.FromResult(GetToken(requestContext, cancellationToken));
    }

    private sealed class Capture : HttpMessageHandler
    {
        public HttpRequestMessage? Request { get; private set; }
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
        {
            Request = request;
            return Task.FromResult(new HttpResponseMessage(System.Net.HttpStatusCode.Accepted));
        }
    }

    private static async Task<(HttpRequestMessage Sent, FakeCredential Credential)> Send(FlowAuthentication mode)
    {
        var credential = new FakeCredential();
        var capture = new Capture();
        using var handler = new FlowAuthHandler(credential, Options.Create(new ReceiverOptions { FlowAuthentication = mode })) { InnerHandler = capture };
        using var client = new HttpClient(handler);
        await client.PostAsync(new Uri("https://example.invalid/flow"), new StringContent("{}"));
        return (capture.Request!, credential);
    }

    [Fact]
    public async Task Entra_mode_sends_a_token_for_the_flow_audience_with_its_trailing_slash()
    {
        var (sent, credential) = await Send(FlowAuthentication.Entra);
        Assert.Equal("Bearer token-1", sent.Headers.Authorization?.ToString());
        Assert.Equal("https://service.flow.microsoft.com//.default", Assert.Single(credential.Scopes));
    }

    [Fact]
    public async Task Sas_mode_sends_no_authorization_header()
    {
        var (sent, credential) = await Send(FlowAuthentication.Sas);
        Assert.Null(sent.Headers.Authorization);
        Assert.Empty(credential.Scopes);
    }

    [Fact]
    public void Entra_is_the_default() => Assert.Equal(FlowAuthentication.Entra, new ReceiverOptions().FlowAuthentication);
}
