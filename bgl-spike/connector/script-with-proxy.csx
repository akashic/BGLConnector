// BGL SF360 spike connector - custom code.
// PROXY variant: core + undocumented Context.CreateNotificationUri and Context.OriginalRequestUri.
// Swap this in for T09/T10 only after the core variant works.
// Those calls are copied from the DocuSign and Zellis certified connectors. If this variant
// fails to save or compile in your tenant, that is the answer to T09.
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
                case "CreateNotificationProxyUrl": return await CreateProxyUrl().ConfigureAwait(false);
                case "SpikeWebhookReceiver": return await ReceiveWebhook().ConfigureAwait(false);
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

    // ---------- T09: can an ACTION create a notification proxy URL? ----------
    // Uses Context.CreateNotificationUri, as the DocuSign certified connector does for triggers.
    private async Task<HttpResponseMessage> CreateProxyUrl()
    {
        var input = JObject.Parse(await this.Context.Request.Content.ReadAsStringAsync().ConfigureAwait(false));
        var target = (string)input["targetUrl"];
        if (string.IsNullOrEmpty(target))
            return Json(HttpStatusCode.BadRequest, new JObject { ["message"] = "targetUrl is required" });

        var encoded = Uri.EscapeDataString(Convert.ToBase64String(Encoding.UTF8.GetBytes(target)));
        var proxy = this.Context.CreateNotificationUri($"/spike/webhook?target={encoded}");
        return Json(HttpStatusCode.OK, new JObject
        {
            ["proxyUrl"] = proxy.AbsoluteUri,
            ["note"] = "Send simulator traffic (or register with BGL) to proxyUrl. Diagnostics are forwarded to targetUrl."
        });
    }

    // ---------- T10: what does a proxied webhook look like inside custom code? ----------
    private async Task<HttpResponseMessage> ReceiveWebhook()
    {
        var received = DateTime.UtcNow;
        var raw = this.Context.Request.Content == null ? "" : await this.Context.Request.Content.ReadAsStringAsync().ConfigureAwait(false);

        var query = HttpUtility.ParseQueryString(this.Context.Request.RequestUri.Query);
        string target = null;
        try { target = Encoding.UTF8.GetString(Convert.FromBase64String(query.Get("target") ?? "")); }
        catch (FormatException) { }

        string auth = null;
        IEnumerable<string> values;
        if (this.Context.Request.Headers.TryGetValues("Authorization", out values)) auth = values.FirstOrDefault();
        var platformReplacedAuth = auth != null && auth.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase);

        var headers = new JObject();
        foreach (var h in this.Context.Request.Headers)
            headers[h.Key] = h.Key.Equals("Authorization", StringComparison.OrdinalIgnoreCase) ? "(see authorizationHeader)" : string.Join(",", h.Value);
        if (this.Context.Request.Content != null)
            foreach (var h in this.Context.Request.Content.Headers) headers["content:" + h.Key] = string.Join(",", h.Value);

        var requestUri = this.Context.Request.RequestUri?.ToString();
        var originalUri = this.Context.OriginalRequestUri?.ToString();

        // Only with the throwaway simulator secret: which URL makes the signature verify?
        var verification = new JArray();
        if (!string.IsNullOrEmpty(SpikeTestSecret) && auth != null && !platformReplacedAuth)
        {
            foreach (var candidate in new[] { requestUri, originalUri }.Where(u => !string.IsNullOrEmpty(u)).Distinct())
            {
                var v = Verify(auth, candidate, raw, SpikeTestSecret, null, 300);
                v["candidateUrl"] = RedactSig(candidate);
                verification.Add(v);
            }
        }

        var diag = new JObject
        {
            ["spike"] = "BGL webhook proxy diagnostics",
            ["receivedAtUtc"] = received.ToString("o"),
            ["seenRequestUri"] = RedactSig(requestUri),
            ["seenOriginalRequestUri"] = RedactSig(originalUri),
            ["authorizationHeaderPresent"] = auth != null,
            ["platformReplacedAuthorization"] = platformReplacedAuth,
            // Forwarded for the spike only. The BGL header is NOT single-use: nothing here or in Verify keeps
            // a replay cache, so anyone who sees header + body + URL can replay them within the skew window.
            // A real receiver must also dedupe on eventId. A platform bearer token is never forwarded.
            ["authorizationHeader"] = platformReplacedAuth ? "Bearer *** (BGL header not visible)" : auth,
            ["headers"] = headers,
            ["rawBody"] = raw,
            ["rawBodyBase64"] = Convert.ToBase64String(Encoding.UTF8.GetBytes(raw)),
            ["rawBodyLength"] = raw.Length,
            ["verificationWithTestSecret"] = verification
        };

        if (string.IsNullOrEmpty(target))
            return Json(HttpStatusCode.OK, new JObject { ["message"] = "request accepted.", ["warning"] = "No target URL to forward to", ["diagnostics"] = diag });

        var forward = new HttpRequestMessage(HttpMethod.Post, target) { Content = CreateJsonContent(diag.ToString()) };
        var fwd = await this.Context.SendAsync(forward, this.CancellationToken).ConfigureAwait(false);
        return Json(fwd.IsSuccessStatusCode ? HttpStatusCode.OK : HttpStatusCode.InternalServerError, new JObject
        {
            ["message"] = fwd.IsSuccessStatusCode ? "request accepted." : "System maintenance.",
            ["forwardStatus"] = (int)fwd.StatusCode
        });
    }
}
