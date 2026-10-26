using System.Net.Http.Headers;
using Azure.Core;
using Microsoft.Extensions.Options;

namespace BglWebhookReceiver;

/// <summary>
/// On the HTTP clients for Flows D and E: adds the app's managed-identity token when
/// <see cref="ReceiverOptions.FlowAuthentication"/> is Entra. The trigger checks the token's audience, tenant and object
/// ID, so Flow D only runs for events this Function has verified. With Sas nothing is added.
/// </summary>
public sealed class FlowAuthHandler(TokenCredential credential, IOptions<ReceiverOptions> options) : DelegatingHandler
{
    protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        var o = options.Value;
        if (o.FlowAuthentication == FlowAuthentication.Entra)
        {
            // The scope is the resource plus "/.default". Power Automate's audience ends in "/", so the scope has "//",
            // and the token's aud keeps the trailing slash the trigger requires. Azure.Identity caches the token.
            var token = await credential.GetTokenAsync(new TokenRequestContext([o.FlowAudience + "/.default"]), cancellationToken);
            request.Headers.Authorization = new AuthenticationHeaderValue("Bearer", token.Token);
        }
        return await base.SendAsync(request, cancellationToken);
    }
}
