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
        try
        {
            if (req.ContentLength > MaxBodyBytes) return await TooLarge(request);

            // Read the raw bytes whatever the Content-Type (BGL's own example sends JSON as form-urlencoded).
            // Content-Length can be absent, so stop once the limit is passed. Cancelling here loses nothing: no event
            // has been recorded yet.
            using var buffer = new MemoryStream();
            var chunk = new byte[8192];
            int read;
            while ((read = await req.Body.ReadAsync(chunk, cancellationToken)) > 0)
            {
                buffer.Write(chunk, 0, read);
                if (buffer.Length > MaxBodyBytes) return await TooLarge(request);
            }

            return Respond(await processor.ProcessAsync(request with { Body = buffer.ToArray() }));
        }
        catch (Exception ex) when (!cancellationToken.IsCancellationRequested)
        {
            // Without Application Insights, Flow E is the only place an unexpected failure would show. The type name
            // only: an exception message could quote a URL or part of the request.
            return Respond(await processor.FailAsync(500, "Internal error", $"Unhandled {ex.GetType().Name}", "unhandled",
                request, null));
        }
    }

    private async Task<IActionResult> TooLarge(WebhookRequest request)
        => Respond(await processor.FailAsync(413, "Payload too large", $"Body over {MaxBodyBytes / 1024} KB", "request",
            request, null));

    private ObjectResult Respond(WebhookOutcome outcome)
    {
        // BGL ignores the body; it reads the status. Reasons and the duplicate flag are for the simulator (T17 only).
        var expose = options.Value.ExposeRejectionReason;
        object body = outcome.StatusCode == 200
            ? expose ? new { message = outcome.Message, duplicate = outcome.Duplicate } : new { message = outcome.Message }
            : expose ? new { message = outcome.Message, reason = outcome.Reason } : new { message = outcome.Message };
        return new ObjectResult(body) { StatusCode = outcome.StatusCode };
    }
}
