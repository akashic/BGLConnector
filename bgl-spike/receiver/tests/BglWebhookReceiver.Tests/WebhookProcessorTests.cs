using System.Text;
using Microsoft.Extensions.Logging.Abstractions;
using Microsoft.Extensions.Options;

namespace BglWebhookReceiver.Tests;

public class WebhookProcessorTests
{
    private const string BaseUrl = "https://example.azurewebsites.net/api/bgl/webhook";
    private const string Query = "?code=function-key";
    private const string Secret = "spike-test-secret";
    private static readonly DateTimeOffset Now = new(2026, 10, 26, 1, 0, 0, TimeSpan.Zero);
    private static readonly string NowText = Now.ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", System.Globalization.CultureInfo.InvariantCulture);
    private const string Body = "{\"entityId\":\"e1\",\"eventId\":\"123\",\"eventType\":\"audit\",\"firmId\":\"firm\",\"tenants\":[],\"userId\":\"u@example.com\"}";

    private sealed class FixedTime(DateTimeOffset now) : TimeProvider
    {
        public override DateTimeOffset GetUtcNow() => now;
    }

    private sealed class FakeStore : IEventStore
    {
        public HashSet<EventKey> Keys { get; } = [];
        public bool Throw { get; set; }
        public Task<bool> TryAddAsync(EventKey key, BglEvent evt, CancellationToken cancellationToken)
            => Throw ? throw new InvalidOperationException("store down") : Task.FromResult(Keys.Add(key));
        public Task RemoveAsync(EventKey key, CancellationToken cancellationToken) { Keys.Remove(key); return Task.CompletedTask; }
    }

    private sealed class FakeForwarder(bool configured = true, bool succeed = true) : IEventForwarder
    {
        public List<byte[]> Sent { get; } = [];
        public List<string?> ClientCodes { get; } = [];
        public bool IsConfigured => configured;
        public Task<ForwardResult> ForwardAsync(ReadOnlyMemory<byte> body, BglEvent evt, string? clientCode, CancellationToken cancellationToken)
        {
            Sent.Add(body.ToArray());
            ClientCodes.Add(clientCode);
            return Task.FromResult(new ForwardResult(succeed, succeed ? "HTTP 202" : "HTTP 500"));
        }
    }

    private sealed class FakeReporter : IErrorReporter
    {
        public List<ErrorReport> Reports { get; } = [];
        public bool IsConfigured => true;
        public Task ReportAsync(ErrorReport report, CancellationToken cancellationToken) { Reports.Add(report); return Task.CompletedTask; }
    }

    private sealed record Harness(WebhookProcessor Processor, FakeStore Store, FakeForwarder Forwarder, FakeReporter Reporter);

    private static Harness Create(ReceiverOptions? o = null, FakeForwarder? forwarder = null)
    {
        o ??= new ReceiverOptions { ReceiverBaseUrl = BaseUrl, WebhookSecret = Secret, ExpectedClientCode = "spike" };
        var store = new FakeStore();
        forwarder ??= new FakeForwarder();
        var reporter = new FakeReporter();
        var processor = new WebhookProcessor(Options.Create(o), store, forwarder, reporter, new FixedTime(Now),
            NullLogger<WebhookProcessor>.Instance);
        return new(processor, store, forwarder, reporter);
    }

    private static WebhookRequest Signed(string body = Body, string url = BaseUrl + Query, string clientCode = "spike",
        string secret = Secret, string? timestamp = null)
    {
        var ts = timestamp ?? NowText;
        var bytes = Encoding.UTF8.GetBytes(body);
        return new($"{clientCode} {ts} {BglSignature.Compute(ts, url, bytes, secret)}", Query, bytes, "inv-1");
    }

    [Fact]
    public async Task Valid_message_is_forwarded_byte_for_byte()
    {
        var h = Create();
        var bglLayout = Body.Replace(",", ",\n");
        var outcome = await h.Processor.ProcessAsync(Signed(bglLayout), default);
        Assert.Equal(200, outcome.StatusCode);
        Assert.Equal(WebhookOutcome.Accepted, outcome.Message);
        Assert.Equal(Encoding.UTF8.GetBytes(bglLayout), Assert.Single(h.Forwarder.Sent));
        Assert.Equal("spike", Assert.Single(h.Forwarder.ClientCodes));
        Assert.Empty(h.Reporter.Reports);
    }

    [Fact]
    public async Task Duplicate_event_is_accepted_but_not_forwarded_again()
    {
        var h = Create();
        await h.Processor.ProcessAsync(Signed(), default);
        var second = await h.Processor.ProcessAsync(Signed(), default);
        Assert.Equal(200, second.StatusCode);
        Assert.True(second.Duplicate);
        Assert.Single(h.Forwarder.Sent);
    }

    [Theory]
    [InlineData("body")]
    [InlineData("signature")]
    [InlineData("url")]
    [InlineData("clientCode")]
    [InlineData("timestamp")]
    public async Task Tampered_messages_are_rejected_and_reported(string tamper)
    {
        var h = Create();
        var request = tamper switch
        {
            "body" => Signed() with { Body = Encoding.UTF8.GetBytes(Body.Replace("audit", "tampered")) },
            "signature" => Signed() with { AuthorizationHeader = $"spike {NowText} {Convert.ToBase64String(new byte[32])}" },
            "url" => Signed(url: BaseUrl + Query + "&tampered=1"),
            "clientCode" => Signed(clientCode: "someoneelse"),
            _ => Signed(timestamp: Now.AddHours(-2).ToString("yyyy-MM-dd'T'HH:mm:ss.fff'Z'", System.Globalization.CultureInfo.InvariantCulture)),
        };
        var outcome = await h.Processor.ProcessAsync(request, default);
        Assert.Equal(401, outcome.StatusCode);
        Assert.Empty(h.Forwarder.Sent);
        Assert.Empty(h.Store.Keys);
        var report = Assert.Single(h.Reporter.Reports);
        Assert.Equal("signature", report.Stage);
        Assert.Equal("warning", report.Severity);
    }

    [Fact]
    public async Task Signature_covers_the_function_key_in_the_query_string()
    {
        var h = Create();
        var outcome = await h.Processor.ProcessAsync(Signed() with { QueryString = "?code=other-key" }, default);
        Assert.Equal(401, outcome.StatusCode);
    }

    [Fact]
    public async Task Configured_full_url_is_used_instead_of_base_plus_query()
    {
        var full = "https://custom.example.com/bgl?code=k";
        var h = Create(new ReceiverOptions { ReceiverUrl = full, ReceiverBaseUrl = BaseUrl, WebhookSecret = Secret });
        var outcome = await h.Processor.ProcessAsync(Signed(url: full), default);
        Assert.Equal(200, outcome.StatusCode);
    }

    [Theory]
    [InlineData(null)]
    [InlineData("")]
    [InlineData("@Microsoft.KeyVault(VaultName=kv;SecretName=bgl-webhook-secret)")]
    public async Task Missing_or_unresolved_secret_fails_closed(string? secret)
    {
        var h = Create(new ReceiverOptions { ReceiverBaseUrl = BaseUrl, WebhookSecret = secret });
        // A header signed with the literal Key Vault reference text must not be accepted.
        var outcome = await h.Processor.ProcessAsync(Signed(secret: secret ?? "x"), default);
        Assert.Equal(500, outcome.StatusCode);
        Assert.Equal("config", Assert.Single(h.Reporter.Reports).Stage);
        Assert.Empty(h.Forwarder.Sent);
    }

    [Fact]
    public async Task Missing_receiver_url_fails_closed()
    {
        var h = Create(new ReceiverOptions { WebhookSecret = Secret });
        Assert.Equal(500, (await h.Processor.ProcessAsync(Signed(), default)).StatusCode);
    }

    [Theory]
    [InlineData("not json")]
    [InlineData("[1,2]")]
    [InlineData("{\"eventType\":\"audit\"}")]
    public async Task Signed_but_unusable_body_is_rejected_with_400(string body)
    {
        var h = Create();
        var outcome = await h.Processor.ProcessAsync(Signed(body), default);
        Assert.Equal(400, outcome.StatusCode);
        Assert.Empty(h.Forwarder.Sent);
    }

    [Fact]
    public async Task Failed_hand_off_returns_503_and_forgets_the_event_so_a_retry_works()
    {
        var failing = new FakeForwarder(succeed: false);
        var h = Create(forwarder: failing);
        var outcome = await h.Processor.ProcessAsync(Signed(), default);
        Assert.Equal(503, outcome.StatusCode);
        Assert.Empty(h.Store.Keys);
        Assert.Equal("forward", Assert.Single(h.Reporter.Reports).Stage);
    }

    [Fact]
    public async Task Event_store_failure_returns_503()
    {
        var h = Create();
        h.Store.Throw = true;
        var outcome = await h.Processor.ProcessAsync(Signed(), default);
        Assert.Equal(503, outcome.StatusCode);
        Assert.Empty(h.Forwarder.Sent);
    }

    [Fact]
    public async Task Without_a_forward_url_the_event_is_accepted_and_recorded()
    {
        var h = Create(forwarder: new FakeForwarder(configured: false));
        var outcome = await h.Processor.ProcessAsync(Signed(), default);
        Assert.Equal(200, outcome.StatusCode);
        Assert.Single(h.Store.Keys);
    }

    [Fact]
    public void Event_key_is_safe_for_table_storage()
    {
        var key = EventKey.For(new BglEvent("a/b#c?d\\e", "audit", "firm/1", null));
        Assert.Matches("^[0-9a-f]{64}$", key.RowKey);
        Assert.Equal(key.RowKey[..2], key.PartitionKey);
    }

    [Theory]
    [InlineData(null, false)]
    [InlineData("  ", false)]
    [InlineData("@Microsoft.KeyVault(SecretUri=https://kv.vault.azure.net/secrets/x)", false)]
    [InlineData(" @microsoft.keyvault(VaultName=kv;SecretName=x)", false)]
    [InlineData("value", true)]
    public void Configured_value_treats_unresolved_key_vault_references_as_unset(string? value, bool expected)
        => Assert.Equal(expected, ConfiguredValue.IsSet(value));
}
