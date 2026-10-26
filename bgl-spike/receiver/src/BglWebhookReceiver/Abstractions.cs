namespace BglWebhookReceiver;

/// <summary>Records event IDs already handled, so BGL retries and replayed messages are processed once.</summary>
public interface IEventStore
{
    /// <summary>Returns false when the event was already recorded.</summary>
    Task<bool> TryAddAsync(EventKey key, BglEvent evt, CancellationToken cancellationToken);

    /// <summary>Forgets an event, so a retry after a failed hand-off is processed again.</summary>
    Task RemoveAsync(EventKey key, CancellationToken cancellationToken);
}

public sealed record ForwardResult(bool Succeeded, string Detail);

/// <summary>Hands a verified event to Power Automate.</summary>
public interface IEventForwarder
{
    bool IsConfigured { get; }
    /// <param name="clientCode">From BGL's verified Authorization header, which isn't forwarded.</param>
    Task<ForwardResult> ForwardAsync(ReadOnlyMemory<byte> body, BglEvent evt, string? clientCode, CancellationToken cancellationToken);
}

/// <summary>
/// One error or rejection, posted to a Power Automate endpoint. Never contains the Authorization header, the body or
/// any secret.
/// </summary>
public sealed record ErrorReport(
    string Severity,
    string Stage,
    int StatusReturned,
    string Message,
    string? Reason,
    string? EventId,
    string? EventType,
    string InvocationId,
    DateTimeOffset TimestampUtc,
    string Version,
    string Source = "bgl-webhook-receiver");

/// <summary>Reports errors to Power Automate. Implementations must never throw: reporting can't break processing.</summary>
public interface IErrorReporter
{
    bool IsConfigured { get; }
    Task ReportAsync(ErrorReport report, CancellationToken cancellationToken);
}
