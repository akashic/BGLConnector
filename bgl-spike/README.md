# BGL SF360 spike: API, OAuth and webhook authentication

The spike answers one question: **what can Power Platform do natively with the BGL API, and what needs Azure in front of it?**

It has three parts:

- **Harness** (`harness/`): PowerShell 7 scripts that test BGL directly, with no Power Platform involved.
- **Spike connector** (`connector/`): a custom connector that tests the same things from inside Power Platform.
- **Test flows**: two small Power Automate flows you build by hand (steps below).

Every test has an ID (T01–T15). Fill in the Result column as you go.

---

## What BGL's public documentation says

Source: BGL's Postman collection, [github.com/BGLCorp/bgl-api-doc](https://github.com/BGLCorp/bgl-api-doc) (`docs/api-doc.json`).

| Topic | What BGL documents | Why it matters |
| --- | --- | --- |
| Grant types | **Authorization Code only.** No client credentials grant. | Every connection is tied to the BGL user who consents. Use a dedicated service BGL login. |
| Token lifetimes | Auth code 10 min, access token 7 days, refresh token 30 days | A connection idle for 30 days dies. A keep-alive is needed (see Decision guide). |
| Token request | `POST /oauth/token?grant_type=…&code=…&scope=…&redirect_uri=…` with **parameters in the query string** and a **Basic** auth header. Refresh uses the same endpoint with `grant_type=refresh_token&scope=…&refresh_token=…` | **Tested (T03/T04):** BGL also accepts the parameters in a form body, but the client credentials must be in the Basic header; credentials in the body get a 401. Power Platform's generic OAuth 2.0 provider retries with a Basic header on its own. |
| Scope on token call | `scope` marked REQUIRED on the token request | **Confirmed required:** without it BGL returns 400 `invalid_scope` ("Empty scope"). The generic provider doesn't send it, so the connector's token and refresh URLs carry `?scope=…` in their query string (T04). |
| Redirect URIs | Up to 5 per app. `localhost` blocked, `127.0.0.1` allowed | Add the connector's redirect URL *and* `http://127.0.0.1:8765/callback` for the harness. |
| Webhook registration | **Per app, in the BGL Developer Portal**: you enter a URL against each message type, and BGL must approve it. No subscription API. | A native connector webhook trigger (which needs a subscribe API) is not possible. Receiving needs a fixed URL. |
| Webhook message types | Audit (**SF360**); New Company, Identity Check, Document Change (all **CAS 360**) | **SF360 only sends the Audit webhook.** Detecting SF360 client changes needs polling. |
| Rate limits | Default 100 requests per 10 min, 1,000 per day. `GET /client/rateLimitStatus` is free | Constrains polling frequency. |
| Document download | Returns a pre-signed S3 URL valid for 3 minutes | Flows must download immediately. |
| Owner applications | A firm accessing its own data emails api@bglcorp.com.au for Developer Portal access; staging is optional | The route for an organisation integrating with its own BGL data rather than building a product for other firms. |
| Contact updates | `PUT /sf/contacts/{id}` accepts a narrower field set than `GET /sf/contactsByIds` returns; GET masks `tfn` as `Provided`/`Not Provided` | Never echo a GET record straight back. The T13 probe sends only the documented PUT fields and never `tfn`. |

Relevant scopes: `smsf_partner` (SF360 entities, documents, establishment and contacts) and `bgl_partner` (adds CAS 360; the user needs both products). Multiple scopes are separated by a literal `+` in both the authorize URL and the token URL. In the connector, a scope therefore goes in two places: the `scopes` array and the `?scope=` on its token and refresh URLs (C1).

---

## Prerequisites

1. **BGL staging access and an app.** Email api@bglcorp.com.au, then create an app in the [staging Developer Portal](https://developer.staging.bgl360.com.au/d/). Note the client ID, client secret and granted scopes.
2. **Redirect URL on the BGL app:** `http://127.0.0.1:8765/callback`. Add the connector's redirect URL later (step C3).
3. **PowerShell 7** (`pwsh`), and the **.NET SDK** for the connector compile check (Mac: `brew install dotnet`; Windows: `winget install Microsoft.DotNet.SDK.8`). Mac: `brew install --cask powershell`. Windows: `winget install Microsoft.PowerShell`. On an IT-managed machine you may need IT to install it.
4. **A dev Power Platform environment** where you can create custom connectors and flows, plus `pac` CLI (optional; you can import through the portal instead).

Secrets never go into the repo. The harness writes tokens to `.secrets/` (owner-only permissions on macOS and Linux) and results to `results/`, and both are git-ignored. Delete `.secrets/` when you finish.

---

## Run order

### Part A: harness only (no Power Platform) — about 30 minutes

```powershell
cd harness

# T01 - offline: the harness HMAC matches BGL's worked example
./Test-BglSignature.ps1

# Offline: the two connector scripts and the connector definition are in sync (run after any connector edit)
./Test-ConnectorSync.ps1

# Both connector scripts compile against Microsoft's documented supporting classes (needs the .NET SDK;
#   the first run downloads NuGet packages). Run after any connector edit.
./Test-ConnectorCompile.ps1

# T02, T03, T05 - authorize, try all four token request styles, test refresh behaviour
./Get-BglToken.ps1 -ClientId '<client id>' -Scope smsf_partner -TestAllStyles
#   You'll authorise once per style; after the first consent BGL should redirect immediately.
#   If the browser can't reach the listener, add -ManualCode. After each Authorise, paste the URL of the
#   127.0.0.1 page you land on (it contains code= and state=), not BGL's page: that has no code.
#   Keep -RedirectUri on 127.0.0.1. Pointed at the connector's redirect URL, BGL sends the code to
#   Microsoft's consent service, which rejects it ("No consent server information was associated
#   with this request").
#   A 401 from every style means BGL rejected the client ID and secret, not the request format.

# T06, T14, T15 - which endpoints work with this scope, polling fields, rate limits
#   Stops if the saved access token has expired (7 days); re-run Get-BglToken.ps1 first.
#   Workpapers use the current Australian financial year (ending 30 June); override with -FinancialYear.
./Invoke-BglProbe.ps1

# T13 - idempotent write test on STAGING. Use a THROWAWAY contact: BGL doesn't document whether PUT
#   clears fields it isn't sent (tfn, entity relationships). The script asks for confirmation, PUTs back
#   only the fields BGL's PUT table allows for the contact's type, then compares the whole record and
#   lists any field that changed.
./Invoke-BglProbe.ps1 -WriteTestContactId '<staging contact id>'
```

### Part B: spike connector

**C1. Set the client ID.** In `connector/apiProperties.json`, replace `REPLACE_WITH_BGL_CLIENT_ID`. If you need extra scopes, add them to the `scopes` array **and** to the `?scope=` query string on `tokenUrlTemplate` and `refreshUrlTemplate`, joined with a literal `+` (`?scope=smsf_partner+bgl_partner`). Power Platform doesn't send `scope` on the token call, and BGL rejects the call without it (T04).

**C2. Deploy the core variant.**

```powershell
pac auth create --environment <your-dev-environment-url>
pac connector create `
  --api-definition-file ./connector/apiDefinition.swagger.json `
  --api-properties-file ./connector/apiProperties.json `
  --script-file ./connector/script.csx
```

Portal alternative: Custom connectors → New → Import an OpenAPI file. Then on the Code tab, enable code, paste `script.csx`, and select the five `Spike*`/`Validate*`/`CreateNotification*` operations.

**C3. Finish security.** Open the connector → Security tab. Enter the client secret, then copy the **Redirect URL** shown there into the BGL app's redirect URLs.

- **The secret** is the one under the BGL app's *OAuth 2.0 Details*, not the webhook *Auth – Secret key* or the *Display code*. BGL shows it only once, when you click *Generate Secret*: copy it, click **Save** on the app, and use that same value in the connector and the harness. Power Platform asks for the secret again every time you update the connector.
- **Keep the authorization, token and refresh URLs as deployed.** Don't paste in the examples from the portal's *OAuth URLs* box. Their query strings (`code=<AUTHCODE>`, `scope=developer`, `redirect_uri=…`) are templates, and BGL reads them in place of the values Power Platform sends.
- **The redirect URL comes from the connector's name.** Renaming the connector gives it a new one. So does running `pac connector create` again, which makes a second connector named from the swagger title. Add the new URL to the BGL app, and delete any connector you aren't using so the flow can't pick it.

**C4. Create a connection** and run `Get user details` in a test flow. That is **T04**. Start the sign-in from Power Platform's **Sign in** button, and don't refresh the pop-up or copy its URL into another tab. If it fails, the error text quotes BGL's response:

| Error | Cause |
| --- | --- |
| BGL page: `Invalid redirect: … is not a registered redirect` | Add that exact URL to the BGL app's redirect URLs |
| 401 `Full authentication is required to access this resource` on the *form body* attempt | Expected: BGL won't take credentials in the body. Power Platform then retries with a Basic header. |
| 401 with an empty body on the *Basic authorization header* attempt | The client secret doesn't match BGL's current one (stale, not saved, or the wrong value) |
| 400 `invalid_scope`, `Empty scope` | The token and refresh URLs are missing `?scope=…` |
| `No consent server information was associated with this request` (Microsoft page) | The sign-in didn't start from Power Platform: a refreshed or copied pop-up, or another client pointed at the connector's redirect URL |

**C5. Swap in the proxy variant** for T09/T10. First create Flow B's trigger (Part C, Flow B step 1) and set `ProxyTargetPrefix` in `script-with-proxy.csx` to its trigger URL up to, but not including, the `?`. The proxy refuses to forward anywhere else, and refuses everything while the constant is empty. Run `Test-ConnectorCompile.ps1` again, and `Test-ConnectorSync.ps1 -AllowDeployValues` (without the switch it fails while the constant is set). **Clear `ProxyTargetPrefix` and `SpikeTestSecret` before committing**: the repo is public, and the plain sync check fails until you do. Then:

```powershell
pac connector update --connector-id <id> --script-file ./connector/script-with-proxy.csx
```

If the save or compile fails, record that as the T09 result. Because `Test-ConnectorCompile.ps1` has already ruled out syntax and type errors, a failure here means the undocumented `CreateNotificationUri` or `OriginalRequestUri` isn't available to custom connectors in your tenant. Then switch back to `script.csx`.

### Part C: test flows

Build both flows in the dev environment and delete them afterwards. An anonymous HTTP trigger may be blocked by your DLP policy; that itself is a finding.

**Run history is readable by anyone with access to the flow.** It shows action inputs and outputs, including the shared secret, the BGL `Authorization` header and the trigger URL. The trigger URL (with its `sig`) is itself a credential, and a captured header and body can be replayed within the 300-second window. For simulator runs with `spike-test-secret` that's acceptable and useful for diagnosis. Before any real BGL traffic (T12):

- turn on **Secure inputs** for the *Validate BGL signature* action, and **Secure outputs** for the trigger and the `Headers`/`BodyAsString` Compose actions (action **Settings → Security**);
- keep the real secret in an environment variable of type **Secret** backed by Azure Key Vault, read it with the Dataverse *Perform an unbound action* → `RetrieveEnvironmentVariableSecretValue` action (with **Secure outputs** on), and pass that output to the validation action. Secret environment variables aren't offered in the dynamic content picker.

**Flow A — "BGL Spike – Inspector"** (T08, T11)

A Power Automate HTTP trigger rejects any request that has both the `sig=` in its URL and an `Authorization` header, with 401 `DirectApiRequestHasMoreThanOneAuthorization`, before the flow runs ([Microsoft](https://learn.microsoft.com/azure/logic-apps/set-up-security-permissions#access-for-inbound-calls-to-request-based-triggers): a request trigger accepts one authorization scheme). BGL always signs in the `Authorization` header, so BGL can't call Flow A directly. The simulator sends the signature as `X-BGL-Authorization` instead (`-HeaderName`), which is what a fixed receiver in front of the flow would do. Flow A therefore tests the validation action and raw-body fidelity, not direct delivery.

1. Trigger: *When an HTTP request is received*. Who can trigger: **Anyone** (spike only). New triggers default to *Any user in my tenant*, which rejects BGL because it can't send an Entra ID token. No JSON schema.
2. Save, copy the trigger URL, and store it in an environment variable `bgl_spike_trigger_url`. The signature covers the *full* URL, including the `sig` query string.
3. Compose `Headers` = `triggerOutputs()?['headers']`
4. Compose `BodyAsString` = `string(triggerBody())`
5. Action: **BGL SF360 Spike → Validate BGL signature**
   - Authorization header: `triggerOutputs()?['headers']?['X-BGL-Authorization']`
   - URL BGL called: the `bgl_spike_trigger_url` variable
   - Raw body: output of `BodyAsString`
   - Shared secret: `spike-test-secret`. Never the real BGL secret: Flow A only ever receives simulator traffic.
   - Expected client code: `spike` for the simulator, or the client code BGL assigns
6. Response: 200 `{"message":"request accepted."}` if `isValid` is true, otherwise 401 with the validation action's output as the body, so the simulator prints the `reason`.

**Flow B — "BGL Spike – Proxy target"** (T09, T10)

1. Trigger: *When an HTTP request is received*. Copy its URL.
2. Manual flow (run once): call **Create notification proxy URL** with targetUrl = Flow B's URL. Record the returned `proxyUrl`. The code only accepts a target with the same host and path as `ProxyTargetPrefix` (step C5). A host allow-list wouldn't be enough: `*.logic.azure.com` and `*.api.powerplatform.com` are shared by every tenant, so anyone could point the proxy at a flow of their own.
3. In Flow B, after the trigger:
   - Compose `Diagnostics` = `triggerBody()`
   - **Validate BGL signature** with:
     - Authorization header: `triggerBody()?['authorizationHeader']`
     - URL: the `proxyUrl` from step 2
     - Raw body: `triggerBody()?['rawBody']`
4. Look at the run history. The diagnostics show the URL the code saw, whether the platform replaced the Authorization header, and whether the body arrived intact.

Send simulator traffic:

```powershell
# T08/T11: straight to the flow trigger (valid message, then the tamper suite). -HeaderName is required:
#   with the default Authorization header the trigger returns 401 DirectApiRequestHasMoreThanOneAuthorization.
$flowA = '<flow A trigger URL, including ?...&sig=...>'
./Send-BglTestWebhook.ps1 -Url $flowA -Secret 'spike-test-secret' -ClientCode spike -HeaderName X-BGL-Authorization
./Send-BglTestWebhook.ps1 -Url $flowA -Secret 'spike-test-secret' -ClientCode spike -HeaderName X-BGL-Authorization -Tamper All

# T11 again with BGL's own body layout (a newline after each field). Flow A re-serialises the body:
#   compact JSON survives that, BGL's layout may not, so T11 only passes if BOTH verify.
./Send-BglTestWebhook.ps1 -Url $flowA -Secret 'spike-test-secret' -ClientCode spike -HeaderName X-BGL-Authorization -BodyStyle Bgl

# T10: through the connector proxy, with BGL's real header name (the proxy moves it into the body)
./Send-BglTestWebhook.ps1 -Url '<proxyUrl>' -Secret 'spike-test-secret' -ClientCode spike
```

For T10 you can also put `spike-test-secret` in the `SpikeTestSecret` constant in `script-with-proxy.csx`. The receiver then tries both URLs it can see and reports which one makes the signature verify. Clear the constant afterwards.

Also for T10, check whether the platform protects the proxy URL's query string. Edit the `target` parameter in `proxyUrl`, for example by replacing it with Flow A's trigger URL encoded as `[uri]::EscapeDataString([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes('<flow A URL>')))`. Percent-encoding matters: raw base64 can contain `+`, which the query parser turns into a space. Send simulator traffic to the edited URL. There are three possible outcomes:

- The platform rejects the edited URL (an error before your code runs): it signs the query.
- The code's own `400 missing required parameters` comes back: the platform passed the edited URL through, and only the `ProxyTargetPrefix` pin stopped the redirect.
- `200 request accepted.` with the warning "No target URL to forward to": the edit was malformed (usually unencoded base64). Fix the encoding and retry.

Record which one you saw. Editing a proxy URL only affects requests sent to that edited URL; BGL keeps calling the URL that is registered with it.

**T09/T10 step by step.** The *Create notification proxy URL* action tests whether a custom connector **action** can call the undocumented `Context.CreateNotificationUri`. This checklist puts step C5 and Flow B in order. Start with the core variant deployed and a working connection (C2–C4).

1. **Create Flow B's trigger.** Add *When an HTTP request is received*, set *Who can trigger* to **Anyone**, save, and copy the trigger URL.
2. **Pin the proxy to Flow B.** Set `ProxyTargetPrefix` in `script-with-proxy.csx` to the trigger URL up to, but not including, the `?`. Then, from `harness/`, run `./Test-ConnectorCompile.ps1` and `./Test-ConnectorSync.ps1 -AllowDeployValues`.
3. **Deploy the proxy variant:** `pac connector update --connector-id <id> --script-file ./connector/script-with-proxy.csx`. If the save or compile fails, that's the T09 result: switch back to `script.csx`.
4. **Run the action.** In a manually triggered flow, add **BGL SF360 Spike → Spike: create notification proxy URL**. Set *Target URL* to Flow B's **full** trigger URL, including `?…&sig=…`, run it once and record `proxyUrl`. The result tells you:
   - **200 with `proxyUrl`:** T09 passes.
   - **400 "targetUrl must match ProxyTargetPrefix":** the prefix from step 2 doesn't match the host and path of the target URL.
   - **500 "Spike custom code error":** `CreateNotificationUri` failed at run time. Record the `errorType` and message as the T09 result.
5. **Finish Flow B** (steps 3–4 of Flow B above): add the `Diagnostics` Compose and *Validate BGL signature* against `proxyUrl`.
6. **Send simulator traffic through the proxy:** `./Send-BglTestWebhook.ps1 -Url '<proxyUrl>' -Secret 'spike-test-secret' -ClientCode spike`. Flow B's run history shows the URL the code saw, whether the platform replaced the `Authorization` header, and whether the body arrived intact (T10).
7. **Try an edited `target`** in `proxyUrl`, as described above, and record which of the three outcomes you get.
8. **Clean up.** Clear `ProxyTargetPrefix` and `SpikeTestSecret` before committing; the plain `./Test-ConnectorSync.ps1` fails until you do. Delete the test flows: their run history shows trigger URLs and headers.

Use `proxyUrl` for T12 only if T10 passed.

**T12 (real BGL traffic):** BGL can't call a flow trigger directly (see Flow A), so T12 needs either the proxy URL, if T10 passed, or a fixed receiver in Azure that moves BGL's header out of `Authorization`. Register that URL against the **Audit** message type in the staging Developer Portal. Wait for BGL approval, then use *Send to Audit* on a staging fund in SF360.

BGL signs the exact URL it calls, so the URL you register and the URL the receiver verifies against must match character for character. Power Automate trigger URLs aren't stable: Microsoft moved them to a new format (old URLs stopped working on 30 November 2025) and from June 2026 can include a scale-unit segment (`/direct/cu/<n>/workflows/...`). They can also be longer than 255 characters, so check that the BGL portal accepts the full URL. Whenever the trigger URL changes, update both the BGL registration and the variable. This fragility is another argument for a fixed receiver (see Decision guide).

---

## Test matrix

| ID | Question | How | Pass criteria | Result |
| --- | --- | --- | --- | --- |
| T01 | Does the harness reproduce BGL's signature exactly? | `Test-BglSignature.ps1` | All 10 checks pass | |
| T02 | Do authorize and the 127.0.0.1 redirect work in staging? Is the staging authorize URL right? | `Get-BglToken.ps1` | Code received. If not, record the correct URL from BGL. | **Pass** (2026-10-26). The authorize URL is confirmed (the Developer Portal shows it), and `http://127.0.0.1:8765/callback` works once registered. |
| T03 | Which token request styles does BGL accept? | `Get-BglToken.ps1 -TestAllStyles` | Record each style. **Key question: does `FormBody` succeed?** | (2026-10-26) `BglDocumented` 200, `FormBody` 401, `FormBodyWithScope` 401, `FormBodyBasicAuth` 200. **`FormBody` fails:** credentials in the body get 401 `Full authentication is required to access this resource`. The credentials must be in the Basic header; the other parameters work in the query string or the form body. |
| T04 | Does Power Platform's generic OAuth 2.0 provider work with BGL? | Create a connection (C4), run *Get user details* | Connection is created and the action returns 200 | **Pass, with `?scope=smsf_partner` on the token and refresh URLs** (2026-10-26): connection created and *Get user details* returned 200. The provider sends the credentials in the form body (401), then retries with a Basic header. That second attempt is the one that matters, and without the scope in the URL it gets 400 `invalid_scope` (`Empty scope`). |
| T05 | Does BGL rotate refresh tokens? Does reusing an old one revoke the new one? Does refreshing extend the refresh token's 30-day expiry? | `Get-BglToken.ps1` refresh section | Record rotated, reusable, current-still-valid, `RefreshExpiryExtended`, `RefreshExpiryDeltaSeconds` and `is_new_token`. `RefreshExpiryExtended` is `Extended`, `NotExtended`, or a value starting `Unknown` or `Inconclusive`. Every style is compared with the code exchange's expiry. | (2026-10-26) Rotated: **yes**. Previous refresh token reusable: **no**. Current token still valid after the reuse attempt: **yes**. Expiry: `Inconclusive (existing token returned)` for both styles that worked, so this is undecided. Refreshing also needs the Basic header: the body-credential styles got 401. |
| T06 | Which endpoints does the granted scope reach? | `Invoke-BglProbe.ps1` | 200 vs 401/403 per endpoint | |
| T07 | Does HMAC-SHA256 run in the custom code sandbox? | *Spike: signature self-test* action | `pass: true` | **Pass** (2026-10-26). `pass`, `signatureMatches` and `emptySecretRejected` all `true`; the sandbox reproduced BGL's worked example `fcCSdGwSgTXseS5eFWOphImuEM9LT6KjgHfuiPWB48A=`. |
| T08 | Can a flow verify a signature through the connector action? | Simulator → Flow A with `-HeaderName X-BGL-Authorization` | Valid message accepted; all tamper cases rejected | **Pass, via a renamed header** (2026-10-26). With BGL's `Authorization` header the trigger itself returns 401 `DirectApiRequestHasMoreThanOneAuthorization` before the flow runs: **BGL can't call a flow trigger directly.** With `X-BGL-Authorization`, the action gave the right verdict for all six cases: valid `isValid: true`; `Body`, `Signature` and `Url` "Signature mismatch"; `Timestamp` "Signature valid but timestamp outside +/-300s" (skew 7199.6 s); `ClientCode` "Client code mismatch". Flow A returned HTTP 200 for every case because its Response wasn't conditional, so the simulator flagged the rejects as UNEXPECTED; the verdicts in the response bodies are what count. Without a Response action the trigger returns 202 before the flow runs. |
| T09 | Can an action create a notification proxy URL? | Proxy variant → *Create notification proxy URL* | Returns `proxyUrl` (or record the save/compile error) | |
| T10 | Does a proxied webhook keep its Authorization header, body and a verifiable URL? Does the platform reject an edited proxy URL? | Simulator → proxyUrl → Flow B, then the edited-`target` check | Header not replaced, body intact, signature verifies against a known URL; record whether the edited URL was rejected | |
| T11 | Does `string(triggerBody())` keep the exact bytes BGL signed? | Simulator → Flow A with `-BodyStyle Compact` and `-BodyStyle Bgl`, compare `isValid` | Both verify. If either fails, raw-body fidelity rules out this design. || **Fail** (2026-10-26). Compact body: `isValid: true`. BGL's layout (`-BodyStyle Bgl`): `isValid: false`, "Signature mismatch". The flow parses the JSON body and `string(triggerBody())` re-serialises it compactly, so the newlines BGL signed are lost. A flow can't verify BGL's signature from its own trigger body. |
| T12 | What does a real BGL Audit webhook look like? Can owner apps register one? | Portal registration of the proxy URL or a fixed receiver, then *Send to Audit* | Message received and verified with the real secret | Not to Flow A: see T08. |
| T13 | Can client details be written with the granted scope? | Probe `-WriteTestContactId` (throwaway staging contact) | PUT returns 2xx and no field changed (the script lists any that did, with before and after values). BGL's PUT example names `address.suburb` and `phone1` where its table and GET use `city` and `telephone`, so a changed `address.city` may come from that naming. | |
| T14 | Is polling feasible for SF360 changes? | Probe date fields, lodgements `modifiedAfter` | Record which endpoints expose usable change dates or filters | |
| T15 | What are the actual rate limits for the app? | Probe P03 and the headers | Record the 10-minute and daily limits | |

---

## Decision guide

**OAuth: T04 passed, so no token proxy is needed.** The generic OAuth provider works with BGL's token endpoint once the token and refresh URLs carry `?scope=…`. Had it failed, the options would have been:

- Point the connector's token URL at an **APIM endpoint** that rewrites the form body into BGL's query string plus Basic header.
- Have an **Azure Function own the BGL token** (refresh token in Key Vault), with the connector calling the Function using Entra ID.

A token-owning Function is still an option if the 30-day refresh expiry (below) can't be managed any other way.

**T04 passed, so native connectors work for API calls.** Whether a keep-alive helps depends on T05:

- If refreshing extends the refresh token's expiry (`RefreshExpiryExtended` is `Extended`), add a weekly keep-alive flow that calls *Get rate limit status*. It's free against the rate limit, and each weekly call triggers a refresh once the 7-day access token has expired, which pushes the 30-day expiry out.
- If the expiry is fixed from first consent (`NotExtended`), no keep-alive can save the connection: someone has to re-authorise it at least every 30 days, or a token-owning service (below) has to handle it.
- If the result starts with `Unknown`, BGL's refresh response didn't include `refresh_token_expires_at`. That's what BGL's documented refresh example shows, so this is the likely outcome.
- If it starts with `Inconclusive`, BGL handed back the existing, still-valid token (same access token, `is_new_token` false, or a shorter `expires_in`).

T05 refreshes within minutes of consent, while the access token is still valid. A keep-alive depends on what happens when the refresh comes *after* the 7-day access token has expired, which one session can't observe. Treat anything other than a clear `Extended` or `NotExtended` as undecided, and don't choose a keep-alive design until BGL answers open question 3.

**Webhooks:** registration is a fixed URL per message type, so a **fixed receiver** is needed:

- An Azure Function or APIM verifies the signature, then hands off through Service Bus to a flow. This is the recommended design.
- A flow trigger can't be the registered URL, for two reasons. It rejects BGL's `Authorization` header alongside its own `sig` (T08), and it re-serialises the JSON body, so the bytes BGL signed are gone before the flow can verify them (T11 failed).
- The only flow-only route left is the connector proxy. Its code reads the raw bytes and forwards them to the flow as a string (`rawBody`), so T11's problem doesn't apply. It works only if T10 shows the proxy URL accepts BGL's `Authorization` header. It still exposes an anonymous URL, though.
- Either way, the receiver must reject replays. A valid signature can be resent within the timestamp window, and neither the harness nor the connector keeps a replay cache, so deduplicate on `eventId`.

**SF360 change detection:** only Audit is sent for SF360, so client-detail changes need polling, sized against T15's limits. Integrations that only write to BGL don't depend on webhooks at all.

---

## Open questions for BGL (api@bglcorp.com.au)

1. What is the staging authorize URL? **Answered:** `https://integrations.staging.bgl360.com.au/u/oauth/authorize`, as shown in the Developer Portal (T02).
2. Does `/oauth/token` accept RFC 6749 form-encoded bodies with the client credentials in the body? Is `scope` required on the token call? **Answered by testing (T03/T04):** form bodies work, but only with the credentials in a Basic header; credentials in the body get 401. `scope` is required: without it the call gets 400 `invalid_scope`.
3. Do you rotate refresh tokens, and what happens if an old refresh token is reused? Does refreshing extend the refresh token's 30-day expiry (sliding), or is it fixed from first consent? Can the refresh response include `refresh_token_expires_at`, as the code exchange does?
4. Can an **Owner Application** subscribe to webhooks? Is Audit the only SF360 message type?
5. The webhook docs list `documentChange` with sub-types in one place, and `newDocument`/`deleteDocument`/`newStatus`/`newAttachment` in another. Which `eventType` values are actually sent today?
6. What are the webhook retry policy, delivery timeout and source IP ranges (for allow-listing)?
7. Is there a change feed or `modifiedAfter` filter for SF360 funds and contacts?
8. Your *Update Contacts* example body uses `address.suburb` and `phone1`, but the field table and GET responses use `city` and `telephone`. Which names does `PUT /sf/contacts/{id}` accept?

---

## Files

| File | Purpose |
| --- | --- |
| `harness/BglSpike.psm1` | Shared signing, verification, token storage and results helpers |
| `harness/Test-BglSignature.ps1` | T01 offline signature tests |
| `harness/Get-BglToken.ps1` | T02, T03, T05 OAuth and token style tests |
| `harness/Invoke-BglProbe.ps1` | T06, T13, T14, T15 API probe |
| `harness/Send-BglTestWebhook.ps1` | Webhook simulator with tamper suite |
| `harness/Test-ConnectorSync.ps1` | Offline check that the two scripts' shared code and the connector's operation lists agree |
| `harness/Test-ConnectorCompile.ps1` | Compiles both connector scripts locally using `compile-check/` |
| `compile-check/` | .NET project and Microsoft's documented `ScriptBase`/`IScriptContext` stubs used by the compile check |
| `connector/apiDefinition.swagger.json` | Spike connector definition (staging host) |
| `connector/apiProperties.json` | OAuth settings and the operations handled by code |
| `connector/script.csx` | Core custom code, documented APIs only |
| `connector/script-with-proxy.csx` | Core plus the DocuSign/Zellis notification proxy pattern |

The connector's error handler returns the exception type and message to the caller so spike failures are easy to diagnose. A production connector should log the detail and return a generic error.

**Cleanup:** delete `.secrets/`, the two test flows, the spike connector and its connections, and remove the test webhook registrations from the BGL portal.
