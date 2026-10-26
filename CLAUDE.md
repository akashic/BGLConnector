# CLAUDE.md

## What this repo is

A time-boxed **spike**, not a product. It answers one question: what can Power Platform do natively with the BGL SF360 API (OAuth, API calls, webhook signature verification), and what needs Azure (APIM / Functions) in front of it? Every test has an ID **T01–T15**. Code comments, script synopses and the README's test matrix all use these IDs, so keep them when adding or changing tests.

`bgl-spike/README.md` is the source of truth: run order, test matrix, decision guide and open questions for BGL. The root `README.md` is a short overview that links to it; keep detail in the runbook, not the overview.

The repo is public. Keep all code, comments and docs **company- and project-agnostic**: no client or employer names, no organisation-specific plans or integration direction, no initials as sample values (the simulator's sample client code is `spike`).

## Commands

Everything is PowerShell 7 (`pwsh`), run from `bgl-spike/harness/`. There is no build step for the harness and no linter. The connector C# is checked by `Test-ConnectorCompile.ps1`. It wraps each `.csx` with Microsoft's supported `using` list and builds it against the stubs in `bgl-spike/compile-check/` (net472 reference assemblies, C# 7.3). The stubs for the undocumented `CreateNotificationUri`/`OriginalRequestUri` are inferred, so the proxy variant still needs a real deployment for T09. They're compiled only for the proxy variant (`PROXY_VARIANT`), so `script.csx` fails to build if it uses them.

```powershell
./Test-BglSignature.ps1        # T01: offline, no credentials. Exit 0 = pass.
./Test-ConnectorSync.ps1       # Offline: shared .csx code and operation lists agree. Run after any connector edit.
./Test-ConnectorCompile.ps1    # Compiles both .csx files (needs the .NET SDK). Run after any connector edit.
# CI (.github/workflows/offline-checks.yml) runs all three on pushes and PRs, on ubuntu-latest with .NET 8. It skips
# changes that only touch docs/ or *.md files (paths-ignore); keep it that way only while no check reads those files.
# The sync check runs there WITHOUT -AllowDeployValues, so CI fails if ProxyTargetPrefix or SpikeTestSecret is committed.
```

The other harness scripts (`Get-BglToken.ps1`, `Invoke-BglProbe.ps1`, `Send-BglTestWebhook.ps1`) call real BGL staging and need a BGL app client ID/secret plus an interactive browser consent. Don't run them unless the user asks. Their parameters and behaviour are in `bgl-spike/harness/CLAUDE.md`. `Invoke-BglProbe.ps1` blocks writes to Production unless `-AllowProductionWrite` is passed. Never echo a GET record back in a PUT: GET returns read-only fields and masks `tfn` as `Provided`. BGL doesn't document whether PUT clears omitted fields, so T13 needs a throwaway contact.

Connector deployment (`pac connector create/update` with the three `connector/` files) is in README Part B.

## Architecture

There are two independent implementations of the same BGL logic. They have to agree with each other.

- **`harness/BglSpike.psm1`**: the shared module that every harness script imports. It holds the environment URLs (`Get-BglEnvironment`; the staging authorize URL was confirmed by T02), HMAC signing and verification, the Basic auth header, and token and result persistence. Tokens are written in plain text to `bgl-spike/.secrets/` and results to `bgl-spike/results/*.json`. Both locations are git-ignored.
- **`connector/`**: a Power Platform custom connector.
  - `apiDefinition.swagger.json` defines real BGL GET operations, which pass straight through to `api.staging.bgl360.com.au`, plus fake `/spike/*` POST operations that custom code handles and never sends to BGL.
  - `apiProperties.json` holds the generic `oauth2` provider settings. `clientId` is the placeholder `REPLACE_WITH_BGL_CLIENT_ID`. `scriptOperations` lists the operations routed to code.
  - `script.csx` (core, documented APIs only) and `script-with-proxy.csx` (core plus the undocumented `Context.CreateNotificationUri` / `OriginalRequestUri`, copied from the DocuSign and Zellis certified connectors). The proxy file is a superset of the core one, so **core changes must be made in both files**.

Cross-file invariants (`Test-ConnectorSync.ps1` checks the first two, and that the deploy-time constants `ProxyTargetPrefix`/`SpikeTestSecret` are empty unless `-AllowDeployValues` is passed. It also checks that every `/spike/*` operation is in `scriptOperations`. A missing one makes the platform forward that call, with its secret and the user's BGL token, to BGL instead of running the code):

- The swagger `operationId`, the `scriptOperations` entry in `apiProperties.json`, and `KnownOperations` plus the `switch` in **both** `.csx` files.
- Everything between `// ===== BEGIN SHARED` and `// ===== END SHARED =====` must be identical in both `.csx` files. Put proxy-only code outside that block.
- The proxy only forwards to a target with the same host and path as the `ProxyTargetPrefix` constant (`IsAllowedTarget`), which must be set to Flow B's trigger URL before deploying. A host allow-list is not enough, because `*.logic.azure.com` and `*.api.powerplatform.com` are shared by every tenant.
- The signature algorithm in `BglSpike.psm1` (`Get-BglSignature` / `Test-BglAuthorizationHeader`) and in the `.csx` (`ComputeSignature` / `Verify`). Both are checked against BGL's published worked example: T01 in the harness and `SpikeSelfTest` in the connector. If you change one, the shared test vector must still pass in both.

## BGL webhook signature facts that are easy to break

- Header: `{clientCode} {UTC timestamp yyyy-MM-ddTHH:mm:ss.fffZ} {Base64 HMAC-SHA256(secret, timestamp + "POST" + fullUrl + rawBody)}`. The client code is lowercased. Both implementations trim the header and split on single spaces only (tabs or double spaces are rejected), and T01 checks that.
- The signature covers the **exact raw body bytes** and the **full URL including its query string**, such as the `sig=` on a Power Automate trigger URL. Re-serialising JSON, or verifying against a URL without its query string, will fail verification. T01 deliberately tests both cases.
- Comparisons are constant-time. There is a ±300 s timestamp skew window (`MaxSkewSeconds`, 0 disables it). There is no replay protection: a captured header and body verify again within that window, so a real receiver must deduplicate on `eventId`.
- Flow run history shows action inputs and outputs. Anything carrying the real secret, the BGL header or the trigger URL needs Secure inputs/outputs, and the real secret belongs in a Key Vault-backed environment variable (README Part C).
- A Power Automate HTTP trigger rejects any request carrying both its `sig=` and an `Authorization` header (401 `DirectApiRequestHasMoreThanOneAuthorization`), so BGL can't call a flow directly. A trigger also re-serialises the JSON body, so `string(triggerBody())` loses BGL's newlines and fails verification (T11). Flow A gets the header as `X-BGL-Authorization` from the simulator (`-HeaderName`); real traffic needs the connector proxy (T10) or a receiver in Azure.
- Redact `sig=` in anything logged or returned (`RedactSig`). Never put a real BGL secret in connector code. `SpikeTestSecret` in `script-with-proxy.csx` must stay empty except for simulator runs.

## BGL API constraints that drive the design

These come from BGL's Postman collection (github.com/BGLCorp/bgl-api-doc) and are summarised in the README:

- Only the Authorization Code grant is available. BGL documents token parameters in the **query string** with a **Basic** header. T03/T04 showed it also accepts them in a form body, but only with the client credentials in the Basic header, and `scope` is required (400 `invalid_scope` without it). The generic Power Platform OAuth provider falls back to a Basic header by itself but never sends `scope`, so `tokenUrlTemplate` and `refreshUrlTemplate` in `apiProperties.json` carry `?scope=smsf_partner`. Keep that query string in step with the `scopes` array.
- Multiple scopes are separated by a literal `+` in both the authorize and token URLs. In `Get-BglToken.ps1`, `$scopeQuery` builds that for query strings and `$scopeForm` (space-separated) gives the same wire bytes in form bodies.
- Access tokens last 7 days and refresh tokens 30 days, so an idle connection dies after 30 days.
- BGL keeps one live token per login per app: a new sign-in revokes the previous access token (401 `invalid_token`). A harness sign-in logs out the Power Automate connection when they share a BGL login, and the reverse.
- The rate limit is 100 calls per 10 minutes.
- Date filters are sent as `yyyy-MM-dd'T'HH:mm:ss'Z'`. BGL documents that format for `updatedAfter`; for `modifiedAfter` it says only "UTC Time", so the same format is assumed.
- Webhooks are registered per app in the BGL Developer Portal against a fixed URL. There is no subscribe API, so a native connector webhook trigger isn't possible. SF360 sends only the Audit event, so detecting client changes means polling.
