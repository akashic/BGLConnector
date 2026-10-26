using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Options;

namespace BglWebhookReceiver.Functions;

/// <summary>
/// Used by the deployment smoke test. Reports the build version and whether each setting resolved, never their values.
/// Needs a key (the smoke test uses the host key): anonymous, it would tell anyone which settings are missing and run
/// code, at our cost, for every caller.
/// </summary>
public sealed class HealthFunction(IOptions<ReceiverOptions> options)
{
    [Function("Health")]
    public IActionResult Run([HttpTrigger(AuthorizationLevel.Function, "get", Route = "health")] HttpRequest req)
    {
        var o = options.Value;
        return new OkObjectResult(new HealthResponse(
            Status: "ok",
            Version: WebhookProcessor.Version,
            SecretConfigured: ConfiguredValue.IsSet(o.WebhookSecret),
            ReceiverUrlConfigured: ConfiguredValue.IsSet(o.ReceiverUrl) || ConfiguredValue.IsSet(o.ReceiverBaseUrl),
            // Host and path only: the function key is in the query string, which isn't configured here.
            ReceiverBaseUrl: ConfiguredValue.IsSet(o.ReceiverBaseUrl) ? o.ReceiverBaseUrl : null,
            ForwardConfigured: ConfiguredValue.IsSet(o.AuditForwardUrl),
            ErrorReportConfigured: ConfiguredValue.IsSet(o.ErrorReportUrl)));
    }
}

public sealed record HealthResponse(string Status, string Version, bool SecretConfigured, bool ReceiverUrlConfigured,
    string? ReceiverBaseUrl, bool ForwardConfigured, bool ErrorReportConfigured);
