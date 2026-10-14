// BGL SF360 spike connector - custom code.
// CORE variant: uses only documented custom-code APIs. Deploy this first.
// script-with-proxy.csx adds the undocumented Context.CreateNotificationUri / OriginalRequestUri
// calls (copied from the DocuSign and Zellis certified connectors). If that variant fails to
// save or compile, that is the answer to T09.
public class Script : ScriptBase
{
    // TEST-ONLY secret used by the proxy receiver when testing with Send-BglTestWebhook.ps1.
    // Leave empty for real BGL traffic. Never put a production secret in connector code.
    private const string SpikeTestSecret = "";

    private static readonly string[] KnownOperations =
    {
        "SpikeSelfTest", "SpikeEcho", "ValidateBglSignature", "CreateNotificationProxyUrl", "SpikeWebhookReceiver"
    };

    public override async Task<HttpResponseMessage> ExecuteAsync()
    {
        try
        {
            switch (GetOperationId())
            {
                case "SpikeSelfTest": return SelfTest();
                case "SpikeEcho": return await Echo().ConfigureAwait(false);
                case "ValidateBglSignature": return await ValidateSignature().ConfigureAwait(false);
                case "CreateNotificationProxyUrl":
                case "SpikeWebhookReceiver":
                    return Json(HttpStatusCode.NotImplemented, new JObject
                    {
                        ["message"] = "Proxy operations need script-with-proxy.csx (test T09/T10)."
                    });
                default:
                    return await this.Context.SendAsync(this.Context.Request, this.CancellationToken).ConfigureAwait(false);
            }
        }
        catch (Exception ex)
        {
            this.Context.Logger.LogError($"Spike error: {ex.GetType().Name}: {ex.Message}");
            return Json(HttpStatusCode.InternalServerError, new JObject
            {
                ["message"] = "Spike custom code error",
                ["errorType"] = ex.GetType().FullName,
                ["error"] = ex.Message
            });
        }
    }

    // Some certified connectors defensively decode OperationId in case it arrives Base64-encoded.
    private string GetOperationId()
    {
        var id = this.Context.OperationId;
        if (Array.IndexOf(KnownOperations, id) >= 0) return id;
        try
        {
            var decoded = Encoding.UTF8.GetString(Convert.FromBase64String(id));
            return Array.IndexOf(KnownOperations, decoded) >= 0 ? decoded : id;
        }
        catch (FormatException) { return id; }
    }

    // ---------- T07: does HMAC-SHA256 work in the custom code sandbox? ----------
    private HttpResponseMessage SelfTest()
    {
        const string ts = "2020-09-09T06:18:33.082Z";
        const string url = "https://provider-site.com/api/bgl/messages";
        const string secret = "my-secrete-key";
        const string body = "{\"entityId\":\"8ad08a066555bb32016555d9ebac0003\",\"eventId\":\"039403940\",\"eventType\":\"audit\",\"firmId\":\"bgltest\",\"tenants\":[{\"tenantId\":\"ASFAUDIT4550\",\"tenantType\":\"fundCode\"},{\"tenantId\":\"73124784265\",\"tenantType\":\"abn\"},{\"tenantId\":\"2015/2016\",\"tenantType\":\"financialYear\"}],\"userId\":\"info@bglcorp.com.au\"}";
        const string expected = "fcCSdGwSgTXseS5eFWOphImuEM9LT6KjgHfuiPWB48A=";

        var actual = ComputeSignature(ts, url, body, secret);
        return Json(HttpStatusCode.OK, new JObject
        {
            ["pass"] = FixedTimeEquals(actual, expected),
            ["expected"] = expected,
            ["actual"] = actual
        });
    }

    // ---------- What does custom code see for an ordinary action call? ----------
    private async Task<HttpResponseMessage> Echo()
    {
        var content = this.Context.Request.Content == null ? "" : await this.Context.Request.Content.ReadAsStringAsync().ConfigureAwait(false);
        var headerNames = new JArray();
        foreach (var h in this.Context.Request.Headers) headerNames.Add(h.Key);
        return Json(HttpStatusCode.OK, new JObject
        {
            ["operationIdRaw"] = this.Context.OperationId,
            ["requestUri"] = this.Context.Request.RequestUri?.ToString(),
            ["method"] = this.Context.Request.Method.Method,
            ["headerNames"] = headerNames,
            ["bodyLength"] = content.Length,
            ["correlationId"] = this.Context.CorrelationId
        });
    }

    // ---------- T08 / T11: verify a BGL webhook signature ----------
    private async Task<HttpResponseMessage> ValidateSignature()
    {
        var input = JObject.Parse(await this.Context.Request.Content.ReadAsStringAsync().ConfigureAwait(false));
        var header = (string)input["authorizationHeader"] ?? "";
        var url = (string)input["url"] ?? "";
        var rawBody = (string)input["rawBody"] ?? "";
        var secret = (string)input["secret"] ?? "";
        var expectedClientCode = (string)input["expectedClientCode"];
        var maxSkew = input.Value<int?>("maxSkewSeconds") ?? 300;   // also covers an explicit JSON null

        var result = Verify(header, url, rawBody, secret, expectedClientCode, maxSkew);
        result["inputUrl"] = RedactSig(url);
        result["rawBodyLength"] = rawBody.Length;
        return Json(HttpStatusCode.OK, result);
    }

    private static JObject Verify(string header, string url, string body, string secret, string expectedClientCode, int maxSkewSeconds)
    {
        var r = new JObject { ["isValid"] = false };
        // Single spaces only, matching BGL's format and Test-BglAuthorizationHeader in the harness.
        var parts = header.Trim().Split(' ');
        if (parts.Length != 3) { r["reason"] = $"Expected 3 header parts, got {parts.Length}"; return r; }
        r["clientCode"] = parts[0];
        r["timestamp"] = parts[1];

        if (!string.IsNullOrEmpty(expectedClientCode) && !string.Equals(parts[0], expectedClientCode.ToLowerInvariant(), StringComparison.Ordinal))
        { r["reason"] = "Client code mismatch"; return r; }

        DateTime ts;
        if (!DateTime.TryParse(parts[1], System.Globalization.CultureInfo.InvariantCulture, System.Globalization.DateTimeStyles.AssumeUniversal | System.Globalization.DateTimeStyles.AdjustToUniversal, out ts))
        { r["reason"] = "Timestamp not parseable"; return r; }
        var skew = (DateTime.UtcNow - ts).TotalSeconds;
        r["skewSeconds"] = Math.Round(skew, 1);

        var expected = ComputeSignature(parts[1], url, body, secret);
        if (!FixedTimeEquals(expected, parts[2])) { r["reason"] = "Signature mismatch"; return r; }
        if (maxSkewSeconds > 0 && Math.Abs(skew) > maxSkewSeconds)
        { r["reason"] = $"Signature valid but timestamp outside +/-{maxSkewSeconds}s"; return r; }

        r["isValid"] = true;
        r["reason"] = "OK";
        return r;
    }

    private static string ComputeSignature(string timestamp, string url, string body, string secret)
    {
        using (var hmac = new HMACSHA256(Encoding.UTF8.GetBytes(secret)))
        {
            return Convert.ToBase64String(hmac.ComputeHash(Encoding.UTF8.GetBytes(timestamp + "POST" + url + body)));
        }
    }

    private static bool FixedTimeEquals(string a, string b)
    {
        if (a == null || b == null || a.Length != b.Length) return false;
        var diff = 0;
        for (var i = 0; i < a.Length; i++) diff |= a[i] ^ b[i];
        return diff == 0;
    }

    private static string RedactSig(string url) => Regex.Replace(url ?? "", "sig=[^&]+", "sig=REDACTED");

    private HttpResponseMessage Json(HttpStatusCode status, JObject body)
    {
        var response = new HttpResponseMessage(status);
        response.Content = CreateJsonContent(body.ToString());
        return response;
    }

}
