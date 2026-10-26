using System.Globalization;
using System.Security.Cryptography;
using System.Text;

namespace BglWebhookReceiver;

public sealed record SignatureResult(bool IsValid, string Reason, string? ClientCode = null, double? SkewSeconds = null);

/// <summary>
/// BGL webhook signature: "{clientCode} {UTC timestamp} {Base64 HMAC-SHA256(secret, timestamp + "POST" + fullUrl + rawBody)}".
/// Port of ComputeSignature/Verify in the connector's .csx files and Get-BglSignature/Test-BglAuthorizationHeader in
/// harness/BglSpike.psm1. All three are checked against BGL's published worked example; keep them in step.
/// </summary>
public static class BglSignature
{
    public static string Compute(string timestamp, string url, ReadOnlySpan<byte> body, string secret)
    {
        // Sign the body's bytes as received, so nothing is decoded and re-encoded on the way.
        var prefix = Encoding.UTF8.GetBytes(timestamp + "POST" + url);
        var data = new byte[prefix.Length + body.Length];
        prefix.CopyTo(data, 0);
        body.CopyTo(data.AsSpan(prefix.Length));
        return Convert.ToBase64String(HMACSHA256.HashData(Encoding.UTF8.GetBytes(secret), data));
    }

    public static SignatureResult Verify(string? header, string url, ReadOnlySpan<byte> body, string? secret,
        string? expectedClientCode, int maxSkewSeconds, DateTimeOffset now)
    {
        // Fail closed: .NET computes an HMAC with an empty key, so a missing secret would let anyone sign a valid header.
        if (string.IsNullOrEmpty(secret)) return new(false, "Secret is empty");
        if (string.IsNullOrEmpty(header)) return new(false, "Authorization header missing");

        // Single spaces only, matching BGL's format and the other two implementations.
        var parts = header.Trim().Split(' ');
        if (parts.Length != 3) return new(false, $"Expected 3 header parts, got {parts.Length}");
        var clientCode = parts[0];

        if (!string.IsNullOrEmpty(expectedClientCode)
            && !string.Equals(clientCode, expectedClientCode.ToLowerInvariant(), StringComparison.Ordinal))
            return new(false, "Client code mismatch", clientCode);

        if (!DateTimeOffset.TryParse(parts[1], CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal | DateTimeStyles.AdjustToUniversal, out var timestamp))
            return new(false, "Timestamp not parseable", clientCode);
        var skew = Math.Round((now - timestamp).TotalSeconds, 1);

        var expected = Compute(parts[1], url, body, secret);
        if (!CryptographicOperations.FixedTimeEquals(Encoding.ASCII.GetBytes(expected), Encoding.ASCII.GetBytes(parts[2])))
            return new(false, "Signature mismatch", clientCode, skew);
        if (maxSkewSeconds > 0 && Math.Abs(skew) > maxSkewSeconds)
            return new(false, $"Signature valid but timestamp outside +/-{maxSkewSeconds}s", clientCode, skew);

        return new(true, "OK", clientCode, skew);
    }
}
