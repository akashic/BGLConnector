# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A time-boxed **spike**, not a product. It answers one question: what can Power Platform do natively with the BGL SF360 API (OAuth, API calls, webhook signature verification), and what needs Azure (APIM / Functions) in front of it? Every test has an ID **T01–T15**. Code comments, script synopses and the README's test matrix all use these IDs, so keep them when adding or changing tests.

`bgl-spike/README.md` is the source of truth: run order, test matrix, decision guide and open questions for BGL.

The repo is public. Keep all code, comments and docs **company- and project-agnostic**: no client or employer names, no organisation-specific plans or integration direction, no initials as sample values (the simulator's sample client code is `spike`).

## Commands

Everything is PowerShell 7 (`pwsh`), run from `bgl-spike/harness/`. There is no build step and no linter.

```powershell
./Test-BglSignature.ps1        # T01: offline, no credentials. Exit 0 = pass. This is the only self-contained test.
```

The other harness scripts call real BGL staging and need a BGL app client ID/secret plus an interactive browser consent. Don't run them unless the user asks:

- `Get-BglToken.ps1 -ClientId <id> [-TestAllStyles] [-ManualCode]` (T02/T03/T05): Authorization Code flow on `127.0.0.1:8765`, then tries four token-request styles (`BglDocumented`, `FormBody`, `FormBodyWithScope`, `FormBodyBasicAuth`).
- `Invoke-BglProbe.ps1 [-WriteTestContactId <id>] [-FinancialYear <yyyy>]` (T06/T13–T15): uses the saved token (refuses to run once it has expired) and about 15 calls against a 100-per-10-minutes limit. Writes to Production are blocked unless `-AllowProductionWrite` is passed. The write test builds its PUT body from a whitelist of fields BGL documents for `PUT /sf/contacts/{id}` (`ConvertTo-BglContactUpdate`). Never echo a GET record back: GET returns read-only fields and masks `tfn` as `Provided`.
- `Send-BglTestWebhook.ps1 -Url <url> -Secret spike-test-secret -ClientCode spike [-Tamper All]`: webhook simulator.

Connector deployment (`pac connector create/update` with the three `connector/` files) is in README Part B.

## Architecture

There are two independent implementations of the same BGL logic. They have to agree with each other.

- **`harness/BglSpike.psm1`**: the shared module that every harness script imports. It holds the environment URLs (`Get-BglEnvironment`; the staging authorize URL is an *unconfirmed guess*), HMAC signing and verification, the Basic auth header, and token and result persistence. Tokens are written in plain text to `bgl-spike/.secrets/` and results to `bgl-spike/results/*.json`. Both locations are git-ignored.
- **`connector/`**: a Power Platform custom connector.
  - `apiDefinition.swagger.json` defines real BGL GET operations, which pass straight through to `api.staging.bgl360.com.au`, plus fake `/spike/*` POST operations that custom code handles and never sends to BGL.
  - `apiProperties.json` holds the generic `oauth2` provider settings. `clientId` is the placeholder `REPLACE_WITH_BGL_CLIENT_ID`. `scriptOperations` lists the operations routed to code.
  - `script.csx` (core, documented APIs only) and `script-with-proxy.csx` (core plus the undocumented `Context.CreateNotificationUri` / `OriginalRequestUri`, copied from the DocuSign and Zellis certified connectors). The proxy file is a superset of the core one, so **core changes must be made in both files**.

Cross-file invariants to keep in sync when adding or renaming a code-handled operation:

- The swagger `operationId`, the `scriptOperations` entry in `apiProperties.json`, and `KnownOperations` plus the `switch` in **both** `.csx` files.
- The signature algorithm in `BglSpike.psm1` (`Get-BglSignature` / `Test-BglAuthorizationHeader`) and in the `.csx` (`ComputeSignature` / `Verify`). Both are checked against BGL's published worked example: T01 in the harness and `SpikeSelfTest` in the connector. If you change one, the shared test vector must still pass in both.

## BGL webhook signature facts that are easy to break

- Header: `{clientCode} {UTC timestamp yyyy-MM-ddTHH:mm:ss.fffZ} {Base64 HMAC-SHA256(secret, timestamp + "POST" + fullUrl + rawBody)}`. The client code is lowercased. Both implementations trim the header and split on single spaces only (tabs or double spaces are rejected), and T01 checks that.
- The signature covers the **exact raw body bytes** and the **full URL including its query string**, such as the `sig=` on a Power Automate trigger URL. Re-serialising JSON, or verifying against a URL without its query string, will fail verification. T01 deliberately tests both cases.
- Comparisons are constant-time. There is a ±300 s timestamp skew window (`MaxSkewSeconds`, 0 disables it). There is no replay protection: a captured header and body verify again within that window, so a real receiver must deduplicate on `eventId`.
- Redact `sig=` in anything logged or returned (`RedactSig`). Never put a real BGL secret in connector code. `SpikeTestSecret` in `script-with-proxy.csx` must stay empty except for simulator runs.

## BGL API constraints that drive the design

These come from BGL's Postman collection (github.com/BGLCorp/bgl-api-doc) and are summarised in the README:

- Only the Authorization Code grant is available. BGL documents token parameters in the **query string** with a **Basic** header, but the generic Power Platform OAuth provider sends a form body. That mismatch is the key open question (T03/T04).
- Multiple scopes are separated by a literal `+` in both the authorize and token URLs. In `Get-BglToken.ps1`, `$scopeQuery` builds that for query strings and `$scopeForm` (space-separated) gives the same wire bytes in form bodies.
- Access tokens last 7 days and refresh tokens 30 days, so an idle connection dies after 30 days.
- Webhooks are registered per app in the BGL Developer Portal against a fixed URL. There is no subscribe API, so a native connector webhook trigger isn't possible. SF360 sends only the Audit event, so detecting client changes means polling.
