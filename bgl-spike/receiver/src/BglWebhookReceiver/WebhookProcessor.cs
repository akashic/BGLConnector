using System.Reflection;
using System.Text.Json;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace BglWebhookReceiver;

public sealed record WebhookRequest(string? AuthorizationHeader, string? QueryString, byte[] Body, string InvocationId);

public sealed record WebhookOutcome(int StatusCode, string Message, string? Reason = null, string? EventId = null, bool Duplicate = false)
{
    public const string Accepted = "request accepted.";
}

/// <summary>
/// Verify, de-duplicate and hand off one BGL webhook. Status codes follow what a retry can fix: 4xx when retrying
/// the same message can't help, 5xx when it might (BGL's retry policy is undocumented, open question 6).
/// </summary>
public sealed partial class WebhookProcessor(
    IOptions<ReceiverOptions> options,
    IEventStore store,
    IEventForwarder forwarder,
    IErrorReporter errors,
    TimeProvider time,
    ILogger<WebhookProcessor> logger)
{
    internal static readonly string Version =
        typeof(WebhookProcessor).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion ?? "unknown";

    /// <summary>The URL BGL signed: <see cref="ReceiverOptions.ReceiverUrl"/>, or the base URL plus the raw query string.</summary>
    public static string? ResolveSignedUrl(ReceiverOptions o, string? queryString)
        => ConfiguredValue.IsSet(o.ReceiverUrl) ? o.ReceiverUrl
            : ConfiguredValue.IsSet(o.ReceiverBaseUrl) ? o.ReceiverBaseUrl + (queryString ?? string.Empty)
            : null;

    public async Task<WebhookOutcome> ProcessAsync(WebhookRequest request, CancellationToken cancellationToken)
    {
        var o = options.Value;

        // Fail closed on configuration before looking at the message.
        if (!ConfiguredValue.IsSet(o.WebhookSecret))
            return await FailAsync(500, "Receiver misconfigured", "Webhook secret not set, or its Key Vault reference did not resolve",
                "config", request, null, cancellationToken);
        var url = ResolveSignedUrl(o, request.QueryString);
        if (url is null)
            return await FailAsync(500, "Receiver misconfigured", "Bgl__ReceiverBaseUrl is not set", "config", request, null, cancellationToken);

        var signature = BglSignature.Verify(request.AuthorizationHeader, url, request.Body, o.WebhookSecret,
            o.ExpectedClientCode, o.MaxSkewSeconds, time.GetUtcNow());
        if (!signature.IsValid)
            return await FailAsync(401, "Unauthorized", signature.Reason, "signature", request, null, cancellationToken);

        BglEvent evt;
        try { evt = BglEvent.Parse(request.Body); }
        catch (JsonException ex)
        {
            return await FailAsync(400, "Bad request", $"Body is not a JSON object: {ex.Message}", "parse", request, null, cancellationToken);
        }

        if (string.IsNullOrWhiteSpace(evt.EventId))
            return await FailAsync(400, "Bad request", "eventId missing", "parse", request, evt, cancellationToken);

        // Record the event before handing it off: a captured message replayed within the skew window, or a BGL retry,
        // is then accepted without being forwarded twice.
        var key = EventKey.For(evt);
        bool added;
        try { added = await store.TryAddAsync(key, evt, cancellationToken); }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            return await FailAsync(503, "Temporarily unavailable", $"Event store failed: {ex.GetType().Name}", "dedupe", request, evt, cancellationToken);
        }

        if (!added)
        {
            LogDuplicate(evt.EventId, evt.EventType);
            return new(200, WebhookOutcome.Accepted, EventId: evt.EventId, Duplicate: true);
        }

        if (!forwarder.IsConfigured)
        {
            LogAcceptedNotForwarded(evt.EventId, evt.EventType);
            return new(200, WebhookOutcome.Accepted, EventId: evt.EventId);
        }

        var forwarded = await forwarder.ForwardAsync(request.Body, evt, signature.ClientCode, cancellationToken);
        if (!forwarded.Succeeded)
        {
            // Forget the event so BGL's retry (if any) is processed instead of dropped as a duplicate.
            try { await store.RemoveAsync(key, cancellationToken); }
            catch (Exception ex) when (ex is not OperationCanceledException) { LogRemoveFailed(evt.EventId, ex.GetType().Name); }
            return await FailAsync(503, "Temporarily unavailable", $"Hand-off to Power Automate failed: {forwarded.Detail}",
                "forward", request, evt, cancellationToken);
        }

        LogForwarded(evt.EventId, evt.EventType);
        return new(200, WebhookOutcome.Accepted, EventId: evt.EventId);
    }

    /// <summary>Logs and reports a rejection or failure, then returns the outcome.</summary>
    internal async Task<WebhookOutcome> FailAsync(int status, string message, string reason, string stage,
        WebhookRequest request, BglEvent? evt, CancellationToken cancellationToken)
    {
        LogRejected(status, stage, reason, evt?.EventId);
        await errors.ReportAsync(new ErrorReport(
            Severity: status >= 500 ? "error" : "warning",
            Stage: stage,
            StatusReturned: status,
            Message: message,
            Reason: reason,
            EventId: evt?.EventId,
            EventType: evt?.EventType,
            InvocationId: request.InvocationId,
            TimestampUtc: time.GetUtcNow(),
            Version: Version), cancellationToken);
        return new(status, message, reason, evt?.EventId);
    }

    [LoggerMessage(Level = LogLevel.Warning, Message = "Returned {Status} at stage {Stage}: {Reason} (eventId {EventId})")]
    private partial void LogRejected(int status, string stage, string reason, string? eventId);

    [LoggerMessage(Level = LogLevel.Information, Message = "Duplicate event {EventId} ({EventType}) accepted without forwarding")]
    private partial void LogDuplicate(string? eventId, string? eventType);

    [LoggerMessage(Level = LogLevel.Information, Message = "Event {EventId} ({EventType}) accepted; no forward URL configured")]
    private partial void LogAcceptedNotForwarded(string? eventId, string? eventType);

    [LoggerMessage(Level = LogLevel.Information, Message = "Event {EventId} ({EventType}) forwarded")]
    private partial void LogForwarded(string? eventId, string? eventType);

    [LoggerMessage(Level = LogLevel.Error, Message = "Couldn't remove event {EventId} after a failed hand-off ({Error}); a BGL retry will be dropped as a duplicate")]
    private partial void LogRemoveFailed(string? eventId, string error);
}
