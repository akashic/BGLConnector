using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Extensions.Options;

namespace BglWebhookReceiver.Functions;

/// <summary>
/// The URL registered with BGL. Three things stop anyone else from using it: the function key in its query string
/// (the platform rejects calls without it before this code runs), BGL's HMAC signature over the timestamp, full URL
/// and raw body, and optionally an IP allow-list on the app (allowedIpRanges in infra/main.bicep).
/// </summary>
public sealed class WebhookFunction(WebhookProcessor processor, IOptions<ReceiverOptions> options)
{
    // A BGL webhook body is a few hundred bytes; this stops an oversized body from being buffered.
    internal const int MaxBodyBytes = 64 * 1024;

    [Function("BglWebhook")]
    public async Task<IActionResult> Run(
        [HttpTrigger(AuthorizationLevel.Function, "post", Route = "bgl/webhook")] HttpRequest req,
        FunctionContext context,
        CancellationToken cancellationToken)
    {
        var request = new WebhookRequest(req.Headers.Authorization.ToString(), req.QueryString.Value, [], context.InvocationId);

        if (req.ContentLength > MaxBodyBytes) return await TooLarge(request, cancellationToken);

        // Read the raw bytes whatever the Content-Type (BGL's own example sends JSON as form-urlencoded). Content-Length
        // can be absent, so stop once the limit is passed.
        using var buffer = new MemoryStream();
        var chunk = new byte[8192];
        int read;
        while ((read = await req.Body.ReadAsync(chunk, cancellationToken)) > 0)
        {
            buffer.Write(chunk, 0, read);
            if (buffer.Length > MaxBodyBytes) return await TooLarge(request, cancellationToken);
        }

        var outcome = await processor.ProcessAsync(request with { Body = buffer.ToArray() }, cancellationToken);
        return Respond(outcome);
    }

    private async Task<IActionResult> TooLarge(WebhookRequest request, CancellationToken cancellationToken)
        => Respond(await processor.FailAsync(413, "Payload too large", $"Body over {MaxBodyBytes / 1024} KB", "request",
            request, null, cancellationToken));

    private ObjectResult Respond(WebhookOutcome outcome)
    {
        // BGL ignores the body; it reads the status. Reasons and the duplicate flag are for the simulator in the spike.
        var expose = options.Value.ExposeRejectionReason;
        object body = outcome.StatusCode == 200
            ? expose ? new { message = outcome.Message, duplicate = outcome.Duplicate } : new { message = outcome.Message }
            : expose ? new { message = outcome.Message, reason = outcome.Reason } : new { message = outcome.Message };
        return new ObjectResult(body) { StatusCode = outcome.StatusCode };
    }
}
