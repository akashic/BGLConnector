using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace BglWebhookReceiver;

/// <summary>
/// Posts verified events to a Power Automate HTTP trigger. The request carries no Authorization header: the trigger
/// URL's sig is its credential, and a second scheme would be rejected (DirectApiRequestHasMoreThanOneAuthorization).
/// </summary>
public sealed partial class HttpEventForwarder(IHttpClientFactory httpClientFactory, IOptions<ReceiverOptions> options,
    ILogger<HttpEventForwarder> logger) : IEventForwarder
{
    public const string ClientName = "forward";

    public bool IsConfigured => ConfiguredValue.IsSet(options.Value.AuditForwardUrl);

    public async Task<ForwardResult> ForwardAsync(ReadOnlyMemory<byte> body, BglEvent evt, string? clientCode,
        CancellationToken cancellationToken)
    {
        // The body is forwarded byte for byte, labelled as JSON whatever Content-Type BGL sent.
        using var content = new ReadOnlyMemoryContent(body);
        content.Headers.ContentType = new MediaTypeHeaderValue("application/json");
        using var request = new HttpRequestMessage(HttpMethod.Post, options.Value.AuditForwardUrl) { Content = content };
        request.Headers.Add("x-bgl-event-id", evt.EventId);
        request.Headers.Add("x-bgl-event-type", evt.EventType ?? string.Empty);
        request.Headers.Add("x-bgl-client-code", clientCode ?? string.Empty);
        try
        {
            using var response = await httpClientFactory.CreateClient(ClientName).SendAsync(request, cancellationToken);
            return response.IsSuccessStatusCode
                ? new(true, $"HTTP {(int)response.StatusCode}")
                : new(false, $"HTTP {(int)response.StatusCode}");
        }
        catch (Exception ex) when (ex is HttpRequestException || (ex is TaskCanceledException && !cancellationToken.IsCancellationRequested))
        {
            // Never log the URL: it contains the trigger's sig.
            LogForwardFailed(ex.GetType().Name);
            return new(false, ex is TaskCanceledException ? "timed out" : ex.GetType().Name);
        }
    }

    [LoggerMessage(Level = LogLevel.Warning, Message = "Forwarding to Power Automate failed: {Error}")]
    private partial void LogForwardFailed(string error);
}

/// <summary>
/// Posts error reports to a Power Automate HTTP trigger, which decides who is told (email, Teams, a Dataverse log).
/// Best effort: failures are logged and swallowed, and a short timeout keeps BGL's response quick.
/// </summary>
public sealed partial class HttpErrorReporter(IHttpClientFactory httpClientFactory, IOptions<ReceiverOptions> options,
    ILogger<HttpErrorReporter> logger) : IErrorReporter
{
    public const string ClientName = "errors";

    private static readonly JsonSerializerOptions Json = new(JsonSerializerDefaults.Web);

    public bool IsConfigured => ConfiguredValue.IsSet(options.Value.ErrorReportUrl);

    public async Task ReportAsync(ErrorReport report, CancellationToken cancellationToken)
    {
        if (!IsConfigured) return;
        try
        {
            // Buffered rather than PostAsJsonAsync, which streams with chunked encoding and no Content-Length.
            using var content = new StringContent(JsonSerializer.Serialize(report, Json), Encoding.UTF8, "application/json");
            using var response = await httpClientFactory.CreateClient(ClientName)
                .PostAsync(options.Value.ErrorReportUrl, content, cancellationToken);
            if (!response.IsSuccessStatusCode) LogReportFailed($"HTTP {(int)response.StatusCode}");
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException)
        {
            LogReportFailed(ex.GetType().Name);
        }
    }

    [LoggerMessage(Level = LogLevel.Warning, Message = "Error report to Power Automate failed: {Error}")]
    private partial void LogReportFailed(string error);
}
