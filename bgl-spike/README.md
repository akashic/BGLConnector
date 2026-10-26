# BGL SF360 spike: API, OAuth and webhook authentication

The spike answers one question: **what can Power Platform do natively with the BGL API, and what needs Azure in front of it?**

It has three parts:

- **Harness** (`harness/`): PowerShell 7 scripts that test BGL directly, with no Power Platform involved.
- **Spike connector** (`connector/`): a custom connector that tests the same things from inside Power Platform.
- **Test flows**: small Power Automate flows you build by hand (steps below).
- **Receiver** (`receiver/`): an Azure Function that receives BGL's webhook, because a flow can't (Part D).

Every test has an ID (T01–T17). Fill in the Result column as you go.

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
| Send to Audit | A button (*Send To Audit* on the Fund Dashboard, *Notify → Auditor* on Workpapers) that only sends the Audit webhook. It appears only after BGL enables your app, and is aimed at audit apps ([BGL blog](https://blog.api.bgl360.com.au/send-to-audit/)). Its example request has `Content-Type: application/x-www-form-urlencoded` with a JSON body | Nothing is stored that the API can read back, so the click itself can't be polled. Audit status has only a write endpoint (`POST …/audit/changeAuditStatus/`). Workflow job stages such as *Waiting on auditor* can be polled (T16). A receiver must verify the raw bytes whatever the `Content-Type`. |
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
#   Signing in here revokes the Power Automate connection's token if both use the same BGL login and app
#   (and the connection's sign-in revokes this one). Run the harness first, then use Fix connection.

# T06, T14, T15 - which endpoints work with this scope, polling fields, rate limits
#   Stops if the saved access token has expired (7 days); re-run Get-BglToken.ps1 first.
#   Every call returning 401 invalid_token ("Invalid access token: <token>") means BGL no longer honours the saved
#   token even though it hasn't expired: get a new one. BGL repeats the rejected token in that error, so treat
#   error bodies in results, logs and run history as sensitive.
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

**Flow C — "BGL Spike – Audit poller"** (T16)

Detects funds going to audit without webhooks or Azure, by polling workflow job stages every hour. It catches a job moving to *Waiting on auditor*, not the *Send to Audit* click itself, so it only works if staff move the fund's job when they send it. One page of up to 1,000 jobs is one API call, so an hourly run costs about 24 calls a day per 1,000 jobs.

1. **Record of jobs already notified.** Create a Dataverse table *BGL audit notification* with the columns *Job code* (the primary name column), *Fund ID*, *Fund name*, *Stage* and *Notified on* (date and time). A SharePoint list with the same columns also works.
2. **Trigger:** *Recurrence*, every 1 hour. In the trigger's settings, turn on concurrency control with a degree of parallelism of 1, so runs never overlap.
3. **Variables:** `page` (integer, 0), `isLast` (boolean, false), `waiting` (array, `[]`). Also `auditStage` (string, `Waiting on auditor`), so a firm that uses a custom stage name can change it in one place.
4. **Do until** `variables('isLast')` is equal to `true`, with the count limit set to 20:
   - **BGL SF360 Spike → List workflow jobs**, with Page = `variables('page')` and Page size = `1000`.
   - **Filter array:** From = `body('List_workflow_jobs')?['content']`, where `item()?['stageName']` is equal to `variables('auditStage')`.
   - **Apply to each** over `body('Filter_array')`: **Append to array variable** `waiting` with `items('Apply_to_each')`.
   - **Set variable** `isLast` = `body('List_workflow_jobs')?['last']`, then **Increment variable** `page` by 1.
5. **Apply to each** over `variables('waiting')`:
   - **Dataverse → List rows** from *BGL audit notification*, with the filter `<prefix>_jobcode eq '@{items('Apply_to_each_2')?['jobCode']}'` and a row count of 1.
   - **Condition:** `length(outputs('List_rows')?['body/value'])` is equal to `0`. If yes, this job has just reached the stage: take the business action (an email or Teams message naming `fundName` and `fundId`), then **Add a new row** with the job's details and `utcNow()`.
6. Optional: when a job leaves the stage, delete its row, so the flow fires again if it comes back.

The first run reports every job that is already waiting. To avoid that, run it once with the business action turned off, then turn it on.

**T12 (real BGL traffic):** BGL can't call a flow trigger directly (see Flow A), so T12 uses the Azure receiver (Part D) and its steps. The proxy route (T09/T10) was skipped. Register that URL against the **Audit** message type in the staging Developer Portal. Wait for BGL approval, then use *Send to Audit* on a staging fund in SF360.

BGL signs the exact URL it calls, so the URL you register and the URL the receiver verifies against must match character for character. Power Automate trigger URLs aren't stable: Microsoft moved them to a new format (old URLs stopped working on 30 November 2025) and from June 2026 can include a scale-unit segment (`/direct/cu/<n>/workflows/...`). They can also be longer than 255 characters, so check that the BGL portal accepts the full URL. Whenever the trigger URL changes, update both the BGL registration and the variable. This fragility is another argument for a fixed receiver (see Decision guide).

### Part D: Azure receiver for the Audit webhook (T17, T12)

A flow trigger can't receive BGL's webhook (T08, T11), so an Azure Function in `receiver/` does: BGL calls the Function, and the Function calls a flow. It follows an existing Flex Consumption Function's patterns (Bicep, managed identity, no storage keys), without Application Insights: errors go to a Power Automate endpoint instead.

For each request the Function:

1. reads the raw body (at most 64 KB) whatever its `Content-Type`; BGL's own example sends JSON as `application/x-www-form-urlencoded`;
2. verifies BGL's signature over the timestamp, the full URL it was called on (including `?code=`) and the exact bytes, failing closed if the secret is missing or its Key Vault reference didn't resolve;
3. records `firmId` + `eventId` in Table Storage, so a BGL retry or a replayed message is accepted but not handed on twice;
4. posts the body, byte for byte, to **Flow D** with headers `x-bgl-event-id`, `x-bgl-event-type` and `x-bgl-client-code`, and no `Authorization` header (so no SAS clash);
5. replies 200 `{"message":"request accepted."}`. Rejections get 401 (signature), 400 (unusable body) or 413 (too large); 500 means it's misconfigured, and 503 means the hand-off failed (the event is forgotten, so BGL's retry can succeed). Every non-200 is posted to **Flow E**.

**Only BGL can call it:** the platform rejects any call without the function key in the URL before the code runs; the code then rejects anything not signed with BGL's secret within ±300 s; and `allowedIpRanges` in `receiver/infra/env/dev.bicepparam` limits callers to BGL's addresses once BGL publishes them (open question 6). Secrets live in Key Vault, read through the Function's managed identity.

**Flow D — "BGL Audit handler"**

1. Trigger: *When an HTTP request is received*, *Who can trigger* **Anyone**. Request body JSON schema: `{"type":"object","properties":{"entityId":{"type":"string"},"eventId":{"type":"string"},"eventType":{"type":"string"},"firmId":{"type":"string"},"tenants":{"type":"array","items":{"type":"object","properties":{"tenantId":{"type":"string"},"tenantType":{"type":"string"}}}},"userId":{"type":"string"}}}`
2. **Filter array** on `tenants` where `item()?['tenantType']` is equal to `fundCode` (and again for `financialYear`).
3. The business action, for example an email or Teams message: "Fund `first(body('Filter_array'))?['tenantId']` sent to audit by `userId`". Don't add a Response action: the trigger then replies 202 at once, which the Function treats as success.

**Flow E — "BGL receiver errors"**

1. Trigger: *When an HTTP request is received*, **Anyone**. Schema: `{"type":"object","properties":{"severity":{"type":"string"},"stage":{"type":"string"},"statusReturned":{"type":"integer"},"message":{"type":"string"},"reason":{"type":"string"},"eventId":{"type":"string"},"eventType":{"type":"string"},"invocationId":{"type":"string"},"timestampUtc":{"type":"string"},"version":{"type":"string"},"source":{"type":"string"}}}`
2. Notify someone, for example only when `severity` is `error`; `warning` covers rejected signatures, which T17 produces on purpose. Reports never contain the header, the body or a secret.

Both trigger URLs are credentials (their `sig`), so they go into Key Vault, not app settings.

#### Deploy from a laptop (spike testing)

Needs PowerShell 7, the Azure CLI (`az bicep install` once), and **Owner** (or Contributor + User Access Administrator) on the resource group, because the template creates role assignments. The .NET 10 SDK is only needed to build the package yourself. Run from the repo root:

```powershell
# D1. Sign in and create the resource group (Flex Consumption is available in australiaeast)
az login
az account set --subscription '<subscription id>'
$rg = 'rg-bglhook-dev'
az group create -n $rg -l australiaeast

# D2. Deploy the infrastructure: storage (no keys), Key Vault, the Flex Consumption app and its role assignments.
#     $t17 adds the simulator settings: rejection reasons in responses, and client code 'spike' so the ClientCode
#     tamper is refused. Set $t17 = $false and repeat D2 before T12; dev.bicepparam alone keeps reasons off.
$t17 = $true
$t17Params = if ($t17) { @('--parameters', 'exposeRejectionReason=true', 'expectedClientCode=spike') } else { @() }
$out = az deployment group create -g $rg --name bglhook-laptop `
  --parameters bgl-spike/receiver/infra/env/dev.bicepparam @t17Params --query properties.outputs -o json | ConvertFrom-Json
$app = $out.functionAppName.value; $kv = $out.keyVaultName.value; $base = $out.receiverBaseUrl.value

# D3. Let yourself set secrets: Owner doesn't include Key Vault data access under the RBAC model.
#     Role assignments can take a few minutes to apply.
$me = az ad signed-in-user show --query id -o tsv
az role assignment create --role 'Key Vault Secrets Officer' --assignee-object-id $me `
  --assignee-principal-type User --scope (az group show -n $rg --query id -o tsv)

# D4. Set the secrets. Read-Host keeps the URLs out of your PowerShell history (see the T08 notes).
az keyvault secret set --vault-name $kv -n bgl-webhook-secret --value 'spike-test-secret'   # simulator secret for T17
az keyvault secret set --vault-name $kv -n audit-forward-url --value (Read-Host 'Flow D trigger URL' -MaskInput)
az keyvault secret set --vault-name $kv -n error-report-url --value (Read-Host 'Flow E trigger URL' -MaskInput)
#     The app caches Key Vault references for up to 24 hours; this documented call makes it fetch them now.
az rest --method post --url "https://management.azure.com$(az functionapp show -g $rg -n $app --query id -o tsv)/config/configreferences/appsettings/refresh?api-version=2022-03-01"

# D5. Get the package: the latest "Receiver" workflow run's artifact (no .NET SDK needed)...
gh run download (gh run list --workflow receiver.yml --branch main --status success -L 1 --json databaseId -q '.[0].databaseId') -n receiver
#     ...or build it yourself with the .NET 10 SDK:
# dotnet publish bgl-spike/receiver/src/BglWebhookReceiver/BglWebhookReceiver.csproj -c Release -r linux-x64 --self-contained false -o publish-receiver
# Compress-Archive -Path publish-receiver/* -DestinationPath receiver.zip -Force

# D6. Deploy the code
az functionapp deployment source config-zip -g $rg -n $app --src receiver.zip

# D7. Check it and build the URL to register with BGL. The key is percent-encoded because BGL signs the URL exactly
#     as it calls it. Treat $receiverUrl as a secret: it holds the function key.
#     Health needs a key too; the host key works for every function, so keep it out of anything you share.
$hostKey = az functionapp keys list -g $rg -n $app --query functionKeys.default -o tsv
Invoke-RestMethod "https://$($out.functionAppHostName.value)/api/health" -Headers @{ 'x-functions-key' = $hostKey }   # secretConfigured, forwardConfigured, errorReportConfigured: True
$key = az functionapp function keys list -g $rg -n $app --function-name BglWebhook --query default -o tsv
$receiverUrl = "${base}?code=$([uri]::EscapeDataString($key))"
```

**T17** (from `bgl-spike/harness`, with `$receiverUrl` from D7):

```powershell
./Send-BglTestWebhook.ps1 -Url $receiverUrl -Secret 'spike-test-secret' -ClientCode spike -Tamper All
./Send-BglTestWebhook.ps1 -Url $receiverUrl -Secret 'spike-test-secret' -ClientCode spike -BodyStyle Bgl
Invoke-WebRequest -Method Post -Uri $base -Body '{}' -SkipHttpErrorCheck | Select-Object StatusCode   # 401: no function key
```

This needs D2 run with `$t17 = $true` (or the workflow's **t17** input). Without it, every rejection shows no reason and the `ClientCode` case is accepted, because BGL doesn't sign the client code. Expect every line **AS EXPECTED**: `None` 200; `Body`, `Signature` and `Url` 401 "Signature mismatch"; `Timestamp` 401 "outside +/-300s"; `ClientCode` 401 "Client code mismatch"; `Replay` 200 with `"duplicate":true`; and the `-BodyStyle Bgl` run 200, the layout a flow trigger couldn't verify (T11). Flow D should run three times (the two `None` messages and the first `Replay` copy) and Flow E five times, all `warning` / `signature`.

**T12** (once BGL has enabled your app for *Send to Audit*, open question 4):

1. Generate a new webhook *Auth – Secret key* in the BGL portal (the old one was typed into a shell during T08), and store it: `az keyvault secret set --vault-name $kv -n bgl-webhook-secret --value (Read-Host 'BGL webhook secret' -MaskInput)`, then repeat D4's refresh call.
2. Turn off the T17 settings: repeat D2 with `$t17 = $false`, or run the workflow with **t17** unticked. Rejection reasons stop appearing in responses, and the client code check is off until step 4.
3. Register `$receiverUrl` (with `?code=`) against the **Audit** message type and wait for BGL's approval.
4. Press *Send to Audit* on a staging fund. Flow D should run once; Flow E should stay quiet. Flow D's trigger outputs show `x-bgl-client-code`: put it in `expectedClientCode` and redeploy.

If a key or secret is ever exposed, regenerate the function key (`az functionapp function keys set … --key-name default`) or the BGL secret, and update the registration.

#### Deploy with GitHub Actions

`.github/workflows/receiver.yml` builds, tests and lints on every push that touches `receiver/`, and deploys only when run by hand. It signs in with OIDC, so GitHub stores no Azure secret.

1. Once, as an Owner: `./bgl-spike/receiver/scripts/Setup-GitHubOidc.ps1 -SubscriptionId <id> -ResourceGroup rg-bglhook-dev -GitHubRepository <owner>/<repo> -SetGitHubVariables`. It creates a deployment identity trusted only by the repo's `dev` environment, grants it Contributor plus a role-assignment right limited to the Function's three roles, and gives you Key Vault Secrets Officer.
   `-SetGitHubVariables` also protects the `dev` environment: only `main` can deploy, and each run waits for a reviewer's approval (you, or `-Reviewer <login>`). That matters because the deployment identity can deploy code that runs as the Function, and the Function can read every Key Vault secret. Without these rules, anyone able to push a branch could deploy their own code. Check *Settings → Environments → dev* shows both rules.
2. *Actions → Receiver → Run workflow* from `main`, tick **deploy**, and tick **t17** only for T17. Approve the run when it pauses. The job runs what-if, deploys the template and the package, and smoke-tests:
   - the new version serves `/api/health` (called with the host key);
   - calls to either endpoint without a key get 401;
   - an unsigned call with the key gets 401 (500 until the secret is set).
3. Set the secrets (D3–D4; step 1 already granted D3) and continue from D7.

The laptop and the pipeline deploy the same template to the same resource group, so you can switch between them.

**Tear down:** `az group delete -n rg-bglhook-dev`, then `az keyvault purge -n <vault name>` (soft delete keeps the name for 7 days), and remove the registration in the BGL portal.

---

## Test matrix

| ID | Question | How | Pass criteria | Result |
| --- | --- | --- | --- | --- |
| T01 | Does the harness reproduce BGL's signature exactly? | `Test-BglSignature.ps1` | All 10 checks pass | |
| T02 | Do authorize and the 127.0.0.1 redirect work in staging? Is the staging authorize URL right? | `Get-BglToken.ps1` | Code received. If not, record the correct URL from BGL. | **Pass** (2026-10-26). The authorize URL is confirmed (the Developer Portal shows it), and `http://127.0.0.1:8765/callback` works once registered. |
| T03 | Which token request styles does BGL accept? | `Get-BglToken.ps1 -TestAllStyles` | Record each style. **Key question: does `FormBody` succeed?** | (2026-10-26) `BglDocumented` 200, `FormBody` 401, `FormBodyWithScope` 401, `FormBodyBasicAuth` 200. **`FormBody` fails:** credentials in the body get 401 `Full authentication is required to access this resource`. The credentials must be in the Basic header; the other parameters work in the query string or the form body. |
| T04 | Does Power Platform's generic OAuth 2.0 provider work with BGL? | Create a connection (C4), run *Get user details* | Connection is created and the action returns 200 | **Pass, with `?scope=smsf_partner` on the token and refresh URLs** (2026-10-26): connection created and *Get user details* returned 200. The provider sends the credentials in the form body (401), then retries with a Basic header. That second attempt is the one that matters, and without the scope in the URL it gets 400 `invalid_scope` (`Empty scope`). |
| T05 | Does BGL rotate refresh tokens? Does reusing an old one revoke the new one? Does refreshing extend the refresh token's 30-day expiry? | `Get-BglToken.ps1` refresh section | Record rotated, reusable, current-still-valid, `RefreshExpiryExtended`, `RefreshExpiryDeltaSeconds` and `is_new_token`. `RefreshExpiryExtended` is `Extended`, `NotExtended`, or a value starting `Unknown` or `Inconclusive`. Every style is compared with the code exchange's expiry. | (2026-10-26) Rotated: **yes**. Previous refresh token reusable: **no**. Current token still valid after the reuse attempt: **yes**. Expiry: `Inconclusive (existing token returned)` for both styles that worked, so this is undecided. Refreshing also needs the Basic header: the body-credential styles got 401. |
| T06 | Which endpoints does the granted scope reach? | `Invoke-BglProbe.ps1` | 200 vs 401/403 per endpoint | (2026-10-26, `smsf_partner`) **200:** user and account details, rate-limit status, fund list, fund details, trustees, fund contacts, fund documents, firm contacts, firm lodgements, workflow jobs. **Workpapers:** 404 "no working papers found for <fund> in 2026" (and 2027): the endpoint is reachable, and the staging fund has none. **CAS 360** companies and documents: 401 "Authentication failed … not authorized to access the resource", so CAS needs its own scope. |
| T07 | Does HMAC-SHA256 run in the custom code sandbox? | *Spike: signature self-test* action | `pass: true` | **Pass** (2026-10-26). `pass`, `signatureMatches` and `emptySecretRejected` all `true`; the sandbox reproduced BGL's worked example `fcCSdGwSgTXseS5eFWOphImuEM9LT6KjgHfuiPWB48A=`. |
| T08 | Can a flow verify a signature through the connector action? | Simulator → Flow A with `-HeaderName X-BGL-Authorization` | Valid message accepted; all tamper cases rejected | **Pass, via a renamed header** (2026-10-26). With BGL's `Authorization` header the trigger itself returns 401 `DirectApiRequestHasMoreThanOneAuthorization` before the flow runs: **BGL can't call a flow trigger directly.** With `X-BGL-Authorization`, the action gave the right verdict for all six cases: valid `isValid: true`; `Body`, `Signature` and `Url` "Signature mismatch"; `Timestamp` "Signature valid but timestamp outside +/-300s" (skew 7199.6 s); `ClientCode` "Client code mismatch". Flow A returned HTTP 200 for every case because its Response wasn't conditional, so the simulator flagged the rejects as UNEXPECTED; the verdicts in the response bodies are what count. Without a Response action the trigger returns 202 before the flow runs. |
| T09 | Can an action create a notification proxy URL? | Proxy variant → *Create notification proxy URL* | Returns `proxyUrl` (or record the save/compile error) || **Skipped.** The Azure receiver (Part D) replaces the proxy, which relies on undocumented platform calls. |
| T10 | Does a proxied webhook keep its Authorization header, body and a verifiable URL? Does the platform reject an edited proxy URL? | Simulator → proxyUrl → Flow B, then the edited-`target` check | Header not replaced, body intact, signature verifies against a known URL; record whether the edited URL was rejected || **Skipped**, as T09. |
| T11 | Does `string(triggerBody())` keep the exact bytes BGL signed? | Simulator → Flow A with `-BodyStyle Compact` and `-BodyStyle Bgl`, compare `isValid` | Both verify. If either fails, raw-body fidelity rules out this design. | **Fail** (2026-10-26). Compact body: `isValid: true`. BGL's layout (`-BodyStyle Bgl`): `isValid: false`, "Signature mismatch". The flow parses the JSON body and `string(triggerBody())` re-serialises it compactly, so the newlines BGL signed are lost. A flow can't verify BGL's signature from its own trigger body. |
| T12 | What does a real BGL Audit webhook look like? Can owner apps register one? | Register the receiver URL (Part D) against Audit, then *Send to Audit* | Flow D receives the event; Flow E stays quiet | Waiting for BGL to enable the app (open question 4). Not to Flow A: see T08. |
| T13 | Can client details be written with the granted scope? | Probe `-WriteTestContactId` (throwaway staging contact) | PUT returns 2xx and no field changed (the script lists any that did, with before and after values). BGL's PUT example names `address.suburb` and `phone1` where its table and GET use `city` and `telephone`, so a changed `address.city` may come from that naming. | **Pass** (2026-10-26, `smsf_partner`). On a throwaway staging Individual: `PUT /sf/contacts/{id}` with only the PUT-table fields returned 200 and the updated contact (`abn`, `accountId`, `address`, `birthCountry`, …). A full re-read found no field changed. The scope can write contacts. Rerun with a TFN and a fund link set: both survived a PUT that leaves them out. The only difference was the address: `streetLine2` went from `""` (as saved by the SF360 form) to `null`, and BGL replaced the address row (`addressId` 65909 → 65910). An integration shouldn't use `addressId` as a stable key, and should treat `""` and `null` as equal. |
| T14 | Is polling feasible for SF360 changes? | Probe date fields, lodgements `modifiedAfter` | Record which endpoints expose usable change dates or filters | (2026-10-26) **Only lodgements take a change filter**: `/sf/firm/lodgements?modifiedAfter=` returned 200 (whether it filters wasn't checked). Fund records carry no last-modified date (`dateFormed`, `dateOfBirth`, `systemStartDate`, `trustDeedLastModifiedDate`, `windUpDate`), and contacts none either (`dateOfDeath`, `establishmentDate`). Detecting fund or contact changes means paging the full list (`/sf/contacts?offset=&limit=`) and comparing it with the last copy. Workflow jobs are paged (`page`, `size`). |
| T15 | What are the actual rate limits for the app? | Probe P03 and the headers | Record the 10-minute and daily limits | (2026-10-26) **100 per 10 minutes, 1,000 per day**, as documented. Ordinary responses carry only `x-rate-daily-limit-remaining`; the 10-minute count is visible only from `/client/rateLimitStatus`. The counts fit that call being free. The 10-minute reset came 10 minutes after the probe's first call, so the window appears to start at the first call rather than on the clock. |
| T16 | Can hourly polling detect a fund going to audit? | Flow C against a staging fund's workflow job moved to *Waiting on auditor* | The first run after the move reports the job once; the next run doesn't report it again | |
| T17 | Does the Azure receiver verify, de-duplicate and forward BGL-signed messages? | Simulator → receiver URL with `-Tamper All` and `-BodyStyle Bgl` (Part D) | Every case AS EXPECTED, including `Replay` (200, `duplicate`) and BGL's body layout; Flow D runs for valid messages only; Flow E gets the rejections | |

---

## Decision guide

**OAuth: T04 passed, so no token proxy is needed.** The generic OAuth provider works with BGL's token endpoint once the token and refresh URLs carry `?scope=…`. Had it failed, the options would have been:

- Point the connector's token URL at an **APIM endpoint** that rewrites the form body into BGL's query string plus Basic header.
- Have an **Azure Function own the BGL token** (refresh token in Key Vault), with the connector calling the Function using Entra ID.

A token-owning Function is still an option if the 30-day refresh expiry (below) can't be managed any other way.

**One live token per BGL login per app.** A new sign-in revokes the previous access token: the harness and the connection, sharing a login, logged each other out (401 `invalid_token`). Each client needs its own BGL login or BGL app. That includes one per Power Platform environment, and any token-owning Function.

**T04 passed, so native connectors work for API calls.** Whether a keep-alive helps depends on T05:

- If refreshing extends the refresh token's expiry (`RefreshExpiryExtended` is `Extended`), add a weekly keep-alive flow that calls *Get rate limit status*. It's free against the rate limit, and each weekly call triggers a refresh once the 7-day access token has expired, which pushes the 30-day expiry out.
- If the expiry is fixed from first consent (`NotExtended`), no keep-alive can save the connection: someone has to re-authorise it at least every 30 days, or a token-owning service (below) has to handle it.
- If the result starts with `Unknown`, BGL's refresh response didn't include `refresh_token_expires_at`. That's what BGL's documented refresh example shows, so this is the likely outcome.
- If it starts with `Inconclusive`, BGL handed back the existing, still-valid token (same access token, `is_new_token` false, or a shorter `expires_in`).

T05 refreshes within minutes of consent, while the access token is still valid. A keep-alive depends on what happens when the refresh comes *after* the 7-day access token has expired, which one session can't observe. Treat anything other than a clear `Extended` or `NotExtended` as undecided, and don't choose a keep-alive design until BGL answers open question 3.

**Detecting a fund going to audit:** the *Send to Audit* click reaches you only as the Audit webhook, and only once BGL enables your app (open question 4). Polling workflow job stages (Flow C, T16) needs neither BGL's approval nor Azure. But it sees a job moving to *Waiting on auditor*, not the click, so it depends on staff keeping jobs up to date.

**Webhooks:** registration is a fixed URL per message type, so a **fixed receiver** is needed. **Chosen: an Azure Function** (Part D, T17):

- The Function verifies the signature on the raw bytes and the full URL, drops duplicates on `eventId` (BGL retries and replays within the timestamp window), and posts the event to a flow over HTTP. Service Bus between them would survive the flow being down; add it if T12 shows BGL doesn't retry.
- A flow trigger can't be the registered URL, for two reasons. It rejects BGL's `Authorization` header alongside its own `sig` (T08), and it re-serialises the JSON body, so the bytes BGL signed are gone before the flow can verify them (T11 failed).
- The connector proxy (T09/T10) could have avoided Azure, but it relies on undocumented platform calls and an anonymous URL, so it was skipped.

**SF360 change detection:** only Audit is sent for SF360, so client-detail changes need polling, sized against T15's limits (100 calls per 10 minutes, 1,000 per day). Funds and contacts have no last-modified date (T14), so a poller has to page the whole list and compare it with the previous copy. Size the page size and schedule against the number of contacts in the firm. Integrations that only write to BGL don't depend on webhooks at all.

---

## Open questions for BGL (api@bglcorp.com.au)

1. What is the staging authorize URL? **Answered:** `https://integrations.staging.bgl360.com.au/u/oauth/authorize`, as shown in the Developer Portal (T02).
2. Does `/oauth/token` accept RFC 6749 form-encoded bodies with the client credentials in the body? Is `scope` required on the token call? **Answered by testing (T03/T04):** form bodies work, but only with the credentials in a Basic header; credentials in the body get 401. `scope` is required: without it the call gets 400 `invalid_scope`.
3. Do you rotate refresh tokens, and what happens if an old refresh token is reused? Does refreshing extend the refresh token's 30-day expiry (sliding), or is it fixed from first consent? Can the refresh response include `refresh_token_expires_at`, as the code exchange does?
4. Can an **Owner Application** subscribe to webhooks? Is Audit the only SF360 message type? Can you enable *Send to Audit* for an app that isn't an audit product, so that the button sends our firm's own app the Audit webhook?
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
| `receiver/src/BglWebhookReceiver/` | T17/T12 Azure Function: verifies BGL's webhook, de-duplicates on `eventId`, forwards to Flow D, reports errors to Flow E |
| `receiver/tests/` | xUnit tests, including BGL's worked example and the T01 cases (CI: `.github/workflows/receiver.yml`) |
| `receiver/infra/` | Bicep: Flex Consumption app, storage without keys, Key Vault; `env/dev.bicepparam` for the spike |
| `receiver/scripts/Setup-GitHubOidc.ps1` | Deployment identity and GitHub variables for the workflow's deploy job |

The connector's error handler returns the exception type and message to the caller so spike failures are easy to diagnose. A production connector should log the detail and return a generic error.

**Cleanup:** delete `.secrets/`, the test flows, the receiver's resource group (Part D), the spike connector and its connections, and remove the test webhook registrations from the BGL portal.
