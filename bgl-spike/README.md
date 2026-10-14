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
| Token request | `POST /oauth/token?grant_type=…&code=…&scope=…&redirect_uri=…` with **parameters in the query string** and a **Basic** auth header. Refresh uses the same endpoint with `grant_type=refresh_token&scope=…&refresh_token=…` | Power Platform's generic OAuth 2.0 provider is expected to send a form body instead. **T03/T04 test whether BGL accepts that.** |
| Scope on token call | `scope` marked REQUIRED on the token request | The generic provider may not send scope on the token call. Also covered by T03. |
| Redirect URIs | Up to 5 per app. `localhost` blocked, `127.0.0.1` allowed | Add the connector's redirect URL *and* `http://127.0.0.1:8765/callback` for the harness. |
| Webhook registration | **Per app, in the BGL Developer Portal**: you enter a URL against each message type, and BGL must approve it. No subscription API. | A native connector webhook trigger (which needs a subscribe API) is not possible. Receiving needs a fixed URL. |
| Webhook message types | Audit (**SF360**); New Company, Identity Check, Document Change (all **CAS 360**) | **SF360 only sends the Audit webhook.** Detecting SF360 client changes needs polling. |
| Rate limits | Default 100 requests per 10 min, 1,000 per day. `GET /client/rateLimitStatus` is free | Constrains polling frequency. |
| Document download | Returns a pre-signed S3 URL valid for 3 minutes | Flows must download immediately. |
| Owner applications | A firm accessing its own data emails api@bglcorp.com.au for Developer Portal access; staging is optional | The route for an organisation integrating with its own BGL data rather than building a product for other firms. |
| Contact updates | `PUT /sf/contacts/{id}` accepts a narrower field set than `GET /sf/contactsByIds` returns; GET masks `tfn` as `Provided`/`Not Provided` | Never echo a GET record straight back. The T13 probe sends only the documented PUT fields and never `tfn`. |

Relevant scopes: `smsf_partner` (SF360 entities, documents, establishment and contacts) and `bgl_partner` (adds CAS 360; the user needs both products). Multiple scopes are separated by a literal `+` in both the authorize URL and the token URL.

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
#   If the browser can't reach the listener, add -ManualCode and paste the redirect URL.
#   If the staging authorize URL is wrong, pass -AuthorizeUrl (see T02).

# T06, T14, T15 - which endpoints work with this scope, polling fields, rate limits
#   Stops if the saved access token has expired (7 days); re-run Get-BglToken.ps1 first.
#   Workpapers use the current Australian financial year (ending 30 June); override with -FinancialYear.
./Invoke-BglProbe.ps1

# T13 - idempotent write test on STAGING. Use a THROWAWAY contact: BGL doesn't document whether PUT
#   clears fields it isn't sent (tfn, entity relationships). The script asks for confirmation, PUTs the
#   documented fields back unchanged, then compares the whole record and lists any field that changed.
./Invoke-BglProbe.ps1 -WriteTestContactId '<staging contact id>'
```

### Part B: spike connector

**C1. Set the client ID.** In `connector/apiProperties.json`, replace `REPLACE_WITH_BGL_CLIENT_ID`. If you need extra scopes, add them to the `scopes` array.

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

**C4. Create a connection** and run `Get user details` in a test flow. That is **T04**.

**C5. Swap in the proxy variant** for T09/T10:

```powershell
pac connector update --connector-id <id> --script-file ./connector/script-with-proxy.csx
```

If the save or compile fails, record that as the T09 result. Because `Test-ConnectorCompile.ps1` has already ruled out syntax and type errors, a failure here means the undocumented `CreateNotificationUri` or `OriginalRequestUri` isn't available to custom connectors in your tenant. Then switch back to `script.csx`.

### Part C: test flows

Build both flows in the dev environment and delete them afterwards. An anonymous HTTP trigger may be blocked by your DLP policy; that itself is a finding.

**Run history is readable by anyone with access to the flow.** It shows action inputs and outputs, including the shared secret, the BGL `Authorization` header and the trigger URL. The trigger URL (with its `sig`) is itself a credential, and a captured header and body can be replayed within the 300-second window. For simulator runs with `spike-test-secret` that's acceptable and useful for diagnosis. Before any real BGL traffic (T12):

- turn on **Secure inputs** for the *Validate BGL signature* action, and **Secure outputs** for the trigger and the `Headers`/`BodyAsString` Compose actions (action **Settings → Security**);
- keep the real secret in an environment variable of type **Secret** backed by Azure Key Vault, read it with the Dataverse *Perform an unbound action* → `RetrieveEnvironmentVariableSecretValue` action (with **Secure outputs** on), and pass that output to the validation action. Secret environment variables aren't offered in the dynamic content picker.

**Flow A — "BGL Spike – Inspector"** (T08, T11, T12)

1. Trigger: *When an HTTP request is received*. Who can trigger: **Anyone** (spike only). New triggers default to *Any user in my tenant*, which rejects BGL because it can't send an Entra ID token. No JSON schema.
2. Save, copy the trigger URL, and store it in an environment variable `bgl_spike_trigger_url`. The signature covers the *full* URL, including the `sig` query string.
3. Compose `Headers` = `triggerOutputs()?['headers']`
4. Compose `BodyAsString` = `string(triggerBody())`
5. Action: **BGL SF360 Spike → Validate BGL signature**
   - Authorization header: `triggerOutputs()?['headers']?['Authorization']`
   - URL BGL called: the `bgl_spike_trigger_url` variable
   - Raw body: output of `BodyAsString`
   - Shared secret: `spike-test-secret` (simulator), or for T12 the real BGL secret from the Key Vault-backed environment variable (see above)
   - Expected client code: `spike` for the simulator, or the client code BGL assigns
6. Response: 200 `{"message":"request accepted."}` if `isValid` is true, otherwise 401.

**Flow B — "BGL Spike – Proxy target"** (T09, T10)

1. Trigger: *When an HTTP request is received*. Copy its URL.
2. Manual flow (run once): call **Create notification proxy URL** with targetUrl = Flow B's URL. Record the returned `proxyUrl`. The code only accepts https targets on `*.logic.azure.com` or `*.api.powerplatform.com` (Power Automate and Logic Apps trigger hosts), so the proxy can't be pointed at an arbitrary URL.
3. In Flow B, after the trigger:
   - Compose `Diagnostics` = `triggerBody()`
   - **Validate BGL signature** with:
     - Authorization header: `triggerBody()?['authorizationHeader']`
     - URL: the `proxyUrl` from step 2
     - Raw body: `triggerBody()?['rawBody']`
4. Look at the run history. The diagnostics show the URL the code saw, whether the platform replaced the Authorization header, and whether the body arrived intact.

Send simulator traffic:

```powershell
# T08/T11: straight to the flow trigger (valid message, then the tamper suite)
./Send-BglTestWebhook.ps1 -Url '<flow A trigger URL>' -Secret 'spike-test-secret' -ClientCode spike
./Send-BglTestWebhook.ps1 -Url '<flow A trigger URL>' -Secret 'spike-test-secret' -ClientCode spike -Tamper All

# T10: through the connector proxy
./Send-BglTestWebhook.ps1 -Url '<proxyUrl>' -Secret 'spike-test-secret' -ClientCode spike
```

For T10 you can also put `spike-test-secret` in the `SpikeTestSecret` constant in `script-with-proxy.csx`. The receiver then tries both URLs it can see and reports which one makes the signature verify. Clear the constant afterwards.

Also for T10, check whether the platform protects the proxy URL's query string. Edit the `target` parameter in `proxyUrl`, for example by base64-encoding Flow A's trigger URL instead of Flow B's, and send simulator traffic to it. If the message reaches Flow A, the platform does not sign the query and the host allow-list in the code is the only thing stopping redirection. Record that either way.

**T12 (real BGL traffic):** register Flow A's trigger URL (or the proxy URL, if T10 passed) against the **Audit** message type in the staging Developer Portal. Wait for BGL approval, then use *Send to Audit* on a staging fund in SF360.

BGL signs the exact URL it calls, so the registered URL and the `bgl_spike_trigger_url` variable must match character for character. Power Automate trigger URLs aren't stable: Microsoft moved them to a new format (old URLs stopped working on 30 November 2025) and from June 2026 can include a scale-unit segment (`/direct/cu/<n>/workflows/...`). They can also be longer than 255 characters, so check that the BGL portal accepts the full URL. Whenever the trigger URL changes, update both the BGL registration and the variable. This fragility is another argument for a fixed receiver (see Decision guide).

---

## Test matrix

| ID | Question | How | Pass criteria | Result |
| --- | --- | --- | --- | --- |
| T01 | Does the harness reproduce BGL's signature exactly? | `Test-BglSignature.ps1` | All 9 checks pass | |
| T02 | Do authorize and the 127.0.0.1 redirect work in staging? Is the staging authorize URL right? | `Get-BglToken.ps1` | Code received. If not, record the correct URL from BGL. | |
| T03 | Which token request styles does BGL accept? | `Get-BglToken.ps1 -TestAllStyles` | Record each style. **Key question: does `FormBody` succeed?** | |
| T04 | Does Power Platform's generic OAuth 2.0 provider work with BGL? | Create a connection (C4), run *Get user details* | Connection is created and the action returns 200 | |
| T05 | Does BGL rotate refresh tokens? Does reusing an old one revoke the new one? Does refreshing extend the refresh token's 30-day expiry? | `Get-BglToken.ps1` refresh section | Record rotated, reusable, current-still-valid, `RefreshExpiryExtended` and `is_new_token` | |
| T06 | Which endpoints does the granted scope reach? | `Invoke-BglProbe.ps1` | 200 vs 401/403 per endpoint | |
| T07 | Does HMAC-SHA256 run in the custom code sandbox? | *Spike: signature self-test* action | `pass: true` | |
| T08 | Can a flow verify a signature through the connector action? | Simulator → Flow A | Valid message accepted; all tamper cases rejected | |
| T09 | Can an action create a notification proxy URL? | Proxy variant → *Create notification proxy URL* | Returns `proxyUrl` (or record the save/compile error) | |
| T10 | Does a proxied webhook keep its Authorization header, body and a verifiable URL? Does the platform reject an edited proxy URL? | Simulator → proxyUrl → Flow B, then the edited-`target` check | Header not replaced, body intact, signature verifies against a known URL; record whether the edited URL was rejected | |
| T11 | Does `string(triggerBody())` keep the exact bytes BGL signed? | Simulator → Flow A, compare `isValid` | Verifies. If not, raw-body fidelity rules out this design. | |
| T12 | What does a real BGL Audit webhook look like? Can owner apps register one? | Portal registration and *Send to Audit* | Message received and verified with the real secret | |
| T13 | Can client details be written with the granted scope? | Probe `-WriteTestContactId` (throwaway staging contact) | PUT returns 2xx and no field changed (the script lists any that did) | |
| T14 | Is polling feasible for SF360 changes? | Probe date fields, lodgements `modifiedAfter` | Record which endpoints expose usable change dates or filters | |
| T15 | What are the actual rate limits for the app? | Probe P03 and the headers | Record the 10-minute and daily limits | |

---

## Decision guide

**If T03 shows only `BglDocumented` succeeds and T04 fails,** the generic OAuth provider can't talk to BGL's token endpoint as-is. The options are:

- Point the connector's token URL at an **APIM endpoint** that rewrites the form body into BGL's query string plus Basic header.
- Have an **Azure Function own the BGL token** (refresh token in Key Vault), with the connector calling the Function using Entra ID.

**If T04 passes,** native connectors work for API calls. Whether a keep-alive helps depends on T05:

- If refreshing extends the refresh token's expiry (`RefreshExpiryExtended` is true), add a weekly keep-alive flow that calls *Get rate limit status*. It's free against the rate limit, and each weekly call triggers a refresh once the 7-day access token has expired, which pushes the 30-day expiry out.
- If the expiry is fixed from first consent, no keep-alive can save the connection: someone has to re-authorise it at least every 30 days, or a token-owning service (below) has to handle it.

**Webhooks:** registration is a fixed URL per message type, so a **fixed receiver** is needed:

- An Azure Function or APIM verifies the signature, then hands off through Service Bus to a flow. This is the recommended design.
- If T10 and T11 both pass, a flow-only design is technically possible. It still exposes an anonymous trigger URL, though.
- Either way, the receiver must reject replays. A valid signature can be resent within the timestamp window, and neither the harness nor the connector keeps a replay cache, so deduplicate on `eventId`.

**SF360 change detection:** only Audit is sent for SF360, so client-detail changes need polling, sized against T15's limits. Integrations that only write to BGL don't depend on webhooks at all.

---

## Open questions for BGL (api@bglcorp.com.au)

1. What is the staging authorize URL?
2. Does `/oauth/token` accept RFC 6749 form-encoded bodies with the client credentials in the body? Is `scope` required on the token call?
3. Do you rotate refresh tokens, and what happens if an old refresh token is reused?
4. Can an **Owner Application** subscribe to webhooks? Is Audit the only SF360 message type?
5. The webhook docs list `documentChange` with sub-types in one place, and `newDocument`/`deleteDocument`/`newStatus`/`newAttachment` in another. Which `eventType` values are actually sent today?
6. What are the webhook retry policy, delivery timeout and source IP ranges (for allow-listing)?
7. Is there a change feed or `modifiedAfter` filter for SF360 funds and contacts?

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
