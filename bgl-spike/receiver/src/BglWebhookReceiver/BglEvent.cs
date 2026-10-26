using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace BglWebhookReceiver;

/// <summary>The fields of a BGL webhook body that the receiver uses. The body is forwarded unchanged.</summary>
public sealed record BglEvent(string? EventId, string? EventType, string? FirmId, string? EntityId)
{
    /// <exception cref="JsonException">The body isn't a JSON object.</exception>
    public static BglEvent Parse(ReadOnlySpan<byte> body)
    {
        var reader = new Utf8JsonReader(body);
        using var doc = JsonDocument.ParseValue(ref reader);
        var root = doc.RootElement;
        if (root.ValueKind != JsonValueKind.Object) throw new JsonException("The body is not a JSON object.");
        return new(Read(root, "eventId"), Read(root, "eventType"), Read(root, "firmId"), Read(root, "entityId"));
    }

    private static string? Read(JsonElement root, string name)
        => !root.TryGetProperty(name, out var value) ? null
            : value.ValueKind == JsonValueKind.String ? value.GetString()
            : value.ValueKind is JsonValueKind.Null or JsonValueKind.Undefined ? null
            : value.GetRawText();
}

/// <summary>
/// Table Storage key for an event. Keys can't contain '/', '\', '#', '?' or control characters, so the row key is a
/// SHA-256 of firm and event ID, and the partition key its first two hex characters (spreads rows across partitions).
/// </summary>
public sealed record EventKey(string PartitionKey, string RowKey)
{
    public static EventKey For(BglEvent evt)
    {
        var hash = Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes($"{evt.FirmId}\n{evt.EventId}")));
        return new(hash[..2], hash);
    }
}
