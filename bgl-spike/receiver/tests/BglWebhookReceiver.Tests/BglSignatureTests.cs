using System.Text;

namespace BglWebhookReceiver.Tests;

/// <summary>The same cases as T01 (harness/Test-BglSignature.ps1), against BGL's published worked example.</summary>
public class BglSignatureTests
{
    internal const string Timestamp = "2020-09-09T06:18:33.082Z";
    internal const string Url = "https://provider-site.com/api/bgl/messages";
    internal const string Secret = "my-secrete-key";
    internal const string Body = "{\"entityId\":\"8ad08a066555bb32016555d9ebac0003\",\"eventId\":\"039403940\",\"eventType\":\"audit\",\"firmId\":\"bgltest\",\"tenants\":[{\"tenantId\":\"ASFAUDIT4550\",\"tenantType\":\"fundCode\"},{\"tenantId\":\"73124784265\",\"tenantType\":\"abn\"},{\"tenantId\":\"2015/2016\",\"tenantType\":\"financialYear\"}],\"userId\":\"info@bglcorp.com.au\"}";
    internal const string Expected = "fcCSdGwSgTXseS5eFWOphImuEM9LT6KjgHfuiPWB48A=";
    internal const string Header = $"provider1 {Timestamp} {Expected}";
    internal static readonly DateTimeOffset ExampleTime = DateTimeOffset.Parse(Timestamp, System.Globalization.CultureInfo.InvariantCulture);

    private static byte[] Bytes(string s) => Encoding.UTF8.GetBytes(s);

    private static SignatureResult Verify(string header = Header, string url = Url, string body = Body, string? secret = Secret,
        string? expectedClientCode = null, int maxSkew = 300, DateTimeOffset? now = null)
        => BglSignature.Verify(header, url, Bytes(body), secret, expectedClientCode, maxSkew, now ?? ExampleTime);

    [Fact]
    public void Signature_matches_BGL_example() => Assert.Equal(Expected, BglSignature.Compute(Timestamp, Url, Bytes(Body), Secret));

    [Fact]
    public void Header_verifies_with_correct_inputs()
    {
        var result = Verify(expectedClientCode: "provider1");
        Assert.True(result.IsValid, result.Reason);
    }

    [Fact]
    public void Rejects_modified_body() => Assert.Equal("Signature mismatch", Verify(body: Body.Replace("audit", "Audit")).Reason);

    [Fact]
    public void Rejects_reserialised_body() => Assert.False(Verify(body: Body.Replace(",", ",\n")).IsValid);

    [Fact]
    public void Rejects_url_with_query_string_added() => Assert.False(Verify(url: Url + "?sig=abc").IsValid);

    [Fact]
    public void Rejects_tab_separated_header() => Assert.StartsWith("Expected 3 header parts", Verify(header: Header.Replace(' ', '\t')).Reason);

    [Fact]
    public void Rejects_double_spaced_header() => Assert.False(Verify(header: Header.Replace(" ", "  ")).IsValid);

    [Theory]
    [InlineData("")]
    [InlineData(null)]
    public void Rejects_empty_secret(string? secret) => Assert.Equal("Secret is empty", Verify(secret: secret).Reason);

    [Fact]
    public void Rejects_header_signed_with_empty_key_when_secret_empty()
    {
        var forged = $"attacker {Timestamp} {BglSignature.Compute(Timestamp, Url, Bytes(Body), "")}";
        Assert.False(Verify(header: forged, secret: "").IsValid);
    }

    [Fact]
    public void Rejects_wrong_secret() => Assert.False(Verify(secret: "wrong").IsValid);

    [Fact]
    public void Rejects_stale_timestamp()
    {
        var result = Verify(now: ExampleTime.AddMinutes(10));
        Assert.Equal("Signature valid but timestamp outside +/-300s", result.Reason);
    }

    [Fact]
    public void Skew_check_can_be_disabled() => Assert.True(Verify(maxSkew: 0, now: ExampleTime.AddDays(1)).IsValid);

    [Fact]
    public void Rejects_other_client_code() => Assert.Equal("Client code mismatch", Verify(expectedClientCode: "someoneelse").Reason);

    [Fact]
    public void Unsigned_request_does_not_learn_the_expected_client_code()
        => Assert.Equal("Signature mismatch", Verify(header: $"someoneelse {Timestamp} {Expected}", body: "{}", expectedClientCode: "provider1").Reason);

    [Fact]
    public void Expected_client_code_is_compared_in_lowercase() => Assert.True(Verify(expectedClientCode: "PROVIDER1").IsValid);

    [Fact]
    public void Rejects_missing_header() => Assert.Equal("Authorization header missing", Verify(header: "").Reason);

    [Fact]
    public void Verifies_url_including_function_key_and_raw_bytes()
    {
        var url = "https://example.azurewebsites.net/api/bgl/webhook?code=abc%2Bdef";
        var body = Bytes("{\"eventId\":\"1\",\n\"eventType\":\"audit\"}");
        var header = $"spike {Timestamp} {BglSignature.Compute(Timestamp, url, body, Secret)}";
        Assert.True(BglSignature.Verify(header, url, body, Secret, "spike", 300, ExampleTime).IsValid);
        Assert.False(BglSignature.Verify(header, url.Replace("%2B", "+"), body, Secret, "spike", 300, ExampleTime).IsValid);
    }
}
