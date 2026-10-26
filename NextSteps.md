# Next steps

Recommendations for taking the BGL SF360 spike from "code ready" to an architecture decision. The code has been through five review rounds; the later rounds found progressively narrower issues and every review finding is fixed, and the connector definition passes Power Platform's validator. **What's left can only be answered by BGL's staging environment or by BGL itself**, so the next steps are about running the spike, not more code review.

Status as of 26 Oct 2026:

| Area | State |
| --- | --- |
| Offline checks (T01 signature tests, connector sync, connector compile) | Pass locally and in CI |
| Connector definition | Accepted by Power Platform as a private connector: 0 errors, 0 warnings. A probe copy passes certification rules too ([guide](docs/guides/paconn-connector-testing.md)) |
| Harness against BGL staging (T02–T06, T13–T15) | T02, T03 and T05 run on 26 Oct 2026 (results in the runbook's test matrix). T06 and T13–T15 not run yet. |
| Connector and flows in Power Platform (T04, T07–T12) | T04 passes: the connector connects and *Get user details* returns 200, with `?scope=` on its token and refresh URLs. T07–T12 not run yet. |

## 1. Contact BGL now

Do this first; replies take time and several later steps depend on them. Email api@bglcorp.com.au:

- **Ask for staging access and an app.** Done. Register `http://127.0.0.1:8765/callback` as a redirect URL on the app yourself, in the Developer Portal.
- **Send the open questions** in [`bgl-spike/README.md`](bgl-spike/README.md#open-questions-for-bgl-apibglcorpcomau). The ones that decide the design:
  - **#1** and **#2** (the staging authorize URL, and whether `/oauth/token` accepts a form body) are answered by T02–T04; no need to send them;
  - **#3** whether refreshing extends the 30-day refresh-token expiry: this decides whether a keep-alive flow is possible;
  - **#4** whether an owner application can subscribe to webhooks;
  - **#8** which field names the contact PUT accepts (`city`/`telephone` or `suburb`/`phone1`).

## 2. Run Part A: the harness against staging (about 30 minutes)

Follow [`bgl-spike/README.md` Part A](bgl-spike/README.md#part-a-harness-only-no-power-platform--about-30-minutes). You run it yourself, because it opens a browser for BGL consent.

1. **T02/T03: done.** `BglDocumented` and `FormBodyBasicAuth` succeed; the styles with the credentials in the body get 401. A form body works as long as the credentials are in a Basic header, which T04 confirmed Power Platform falls back to.
2. **T05: done, inconclusive.** BGL returned the existing token, so the result is `Inconclusive…`, and the keep-alive question waits for BGL's answer to question 3.
3. **`Invoke-BglProbe.ps1`** for T06, T14 and T15: which endpoints the scope reaches, which change dates and filters exist, and the real rate limits.
4. **T13 on a throwaway staging contact only.** BGL doesn't document whether PUT clears fields it isn't sent. The script asks for confirmation and lists every field that changed, with before and after values.

Fill in the Result column of the test matrix as you go.

## 3. Run Parts B and C: connector and flows

1. **Validate before deploying** whenever the connector definition changes: [Testing a custom connector with paconn](docs/guides/paconn-connector-testing.md), §4.
2. **Core connector (C1–C4): deployed, T04 and T07 pass.** A flow trigger rejects BGL's `Authorization` header (T08), so run T08 with `-HeaderName X-BGL-Authorization`.
3. **Run T11 with both body styles** (`-BodyStyle Compact` and `-BodyStyle Bgl`). If either fails, a flow-only webhook receiver is ruled out.
4. **T09/T10 (proxy variant):** set `ProxyTargetPrefix` to Flow B's trigger URL first, run the sync check with `-AllowDeployValues`, and **clear the constant before committing**. CI fails if it's committed.
5. **Before any real BGL traffic (T12):** turn on Secure inputs/outputs on the flow steps and keep the real webhook secret in a Key Vault-backed environment variable (runbook Part C).

## 4. Record the results and decide

Use the [Decision guide](bgl-spike/README.md#decision-guide) to settle:

- **API calls:** settled by T04: a native custom connector, with `?scope=` on its token and refresh URLs. No APIM or Function is needed in front of BGL's token endpoint.
- **Connection lifetime:** a weekly keep-alive flow, or a service that owns the token and re-authorises (T05 plus BGL's answer to question 3).
- **Webhooks:** most likely a fixed Azure receiver (Function or APIM) that verifies the signature, deduplicates on `eventId` and hands off to a flow. BGL can't call a flow trigger directly: the trigger rejects a request that carries an `Authorization` header as well as its `sig` (T08). The connector proxy (T10) is the only flow-only route left, and trigger URLs that change and can exceed 255 characters make it fragile.
- **Change detection:** SF360 sends only the Audit webhook, so client changes need polling sized to the measured rate limits (T14/T15).

Then capture what staging taught you: lessons in `docs/lessons/` (anything that surprised you about BGL or Power Platform) and a journal entry.

## 5. Smaller items

- **Run `paconn logout`** when you're finished validating; the token file holds a refresh token.
- **Copilot review report:** `docs/github-copilot-review/2026-10-14 16-46 review.md` flags `Invoke-BglProbe.ps1:48` as sending a placeholder token. That's a false positive (the line sends `"Bearer $($token.access_token)"`), most likely from GitHub masking credential-like text. Add a note so nobody acts on it.
- **Windows:** if anyone runs the harness on Windows, check that the `icacls` owner-only permission on `.secrets/` works; it hasn't been tested there.
- **Certification (only if the connector is ever submitted to Microsoft):** add `info.contact`, operation and parameter descriptions, `x-ms-connector-metadata`, and typed response schemas. None are needed for a private connector.
