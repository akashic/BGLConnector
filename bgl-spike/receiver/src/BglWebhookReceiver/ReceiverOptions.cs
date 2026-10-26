using System.Diagnostics.CodeAnalysis;

namespace BglWebhookReceiver;

/// <summary>App settings under <c>Bgl__*</c>. Secrets and URLs that carry credentials are Key Vault references.</summary>
public sealed class ReceiverOptions
{
    public const string SectionName = "Bgl";

    /// <summary>
    /// The URL registered with BGL without its query string, e.g. https://&lt;host&gt;/api/bgl/webhook. The request's raw
    /// query string (which carries the function key) is appended, because BGL signs the full URL it calls. The URL
    /// isn't rebuilt from the request's scheme and host, which the platform's front end can change.
    /// </summary>
    public string? ReceiverBaseUrl { get; set; }

    /// <summary>Optional: the exact full URL registered with BGL. When set it is used as-is instead of the base URL.</summary>
    public string? ReceiverUrl { get; set; }

    /// <summary>BGL's webhook "Auth – Secret key" (not the OAuth client secret).</summary>
    public string? WebhookSecret { get; set; }

    /// <summary>Optional. When set, the header's client code must match it (compared in lowercase).</summary>
    public string? ExpectedClientCode { get; set; }

    /// <summary>Allowed clock skew in seconds either side; 0 disables the check.</summary>
    public int MaxSkewSeconds { get; set; } = 300;

    /// <summary>Spike only: return the rejection reason in the response body so the simulator can report it.</summary>
    public bool ExposeRejectionReason { get; set; }

    /// <summary>Optional: the Power Automate HTTP trigger URL that receives verified events (includes its sig).</summary>
    public string? AuditForwardUrl { get; set; }

    /// <summary>Optional: the Power Automate HTTP trigger URL that receives error reports (includes its sig).</summary>
    public string? ErrorReportUrl { get; set; }

    /// <summary>How the Function proves itself to Flows D and E. See <see cref="BglWebhookReceiver.FlowAuthentication"/>.</summary>
    public FlowAuthentication FlowAuthentication { get; set; } = FlowAuthentication.Entra;

    /// <summary>
    /// Audience of Power Automate's HTTP triggers. Public cloud by default; Microsoft's "Add OAuth authentication for
    /// HTTP request triggers" lists the other clouds' values. Must match exactly, including the trailing slash.
    /// </summary>
    public string FlowAudience { get; set; } = "https://service.flow.microsoft.com/";

    /// <summary>Table Storage table that records event IDs already handled.</summary>
    public string EventTableName { get; set; } = "BglEvents";
}

public enum FlowAuthentication
{
    /// <summary>
    /// A managed-identity token on every call. The flows' triggers are set to "Specific users in my tenant" with this
    /// app's object ID, so a leaked trigger URL can't start them.
    /// </summary>
    Entra,

    /// <summary>
    /// No token: for triggers set to "Anyone", where the URL's sig is the only credential. A fallback for regions that
    /// don't offer the trigger's Entra option yet; a sig trigger rejects any request that also has a token (T08).
    /// </summary>
    Sas,
}

public static class ConfiguredValue
{
    /// <summary>
    /// True when a setting has a usable value. An unresolved Key Vault reference (the secret is missing or the app
    /// can't read it) reaches the app as the literal "@Microsoft.KeyVault(...)" text; treating that as a value would
    /// make a publicly known string the HMAC secret, so it counts as unset.
    /// </summary>
    public static bool IsSet([NotNullWhen(true)] string? value)
        => !string.IsNullOrWhiteSpace(value)
           && !value.TrimStart().StartsWith("@Microsoft.KeyVault(", StringComparison.OrdinalIgnoreCase);
}
