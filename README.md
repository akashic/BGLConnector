# BGL Connector spike

[![Offline checks](https://github.com/akashic/BGLConnector/actions/workflows/offline-checks.yml/badge.svg)](https://github.com/akashic/BGLConnector/actions/workflows/offline-checks.yml)

A technical spike that tests how far Microsoft Power Platform can integrate with the [BGL](https://www.bgl360.com.au/) SF360 and CAS 360 API on its own, and where Azure services are needed in front of it.

It answers one question: **what can Power Platform do natively with the BGL API (OAuth, API calls, webhooks), and what needs Azure?**

> This is a spike, not a production connector. It targets BGL's **staging** environment, and some steps deliberately trade security for visibility (for example, an anonymous flow trigger and diagnostic output). Read the security notes below before using real data.

## Why a spike is needed

BGL's API has several traits that don't fit Power Platform's defaults:

| BGL behaviour | Why it matters for Power Platform |
| --- | --- |
| Only the OAuth Authorization Code grant is supported, and the token call takes its parameters in the **query string** with a **Basic** auth header | Power Platform's generic OAuth 2.0 provider sends a standard form body. Tested: BGL accepts that once the provider falls back to a Basic header, but the provider doesn't send the required `scope`, so the connector's token URL carries it (T03/T04). |
| Access tokens last 7 days and refresh tokens 30 days | An idle connection dies after 30 days unless refreshing extends that expiry. |
| Webhooks are registered against a fixed URL per message type in BGL's Developer Portal, with no subscription API | A native connector webhook trigger isn't possible, so receiving events needs a fixed endpoint. |
| Webhooks are signed with HMAC-SHA256 over the timestamp, the full URL and the **exact raw body** | The receiver must see the exact bytes and URL BGL signed, which Power Automate may not preserve. BGL sends the signature in the `Authorization` header, which a Power Automate HTTP trigger rejects alongside its own `sig` (T08), so BGL can't call a flow directly. |
| SF360 sends only the Audit webhook | Detecting SF360 client changes means polling, within BGL's rate limits (100 requests per 10 minutes, 1,000 per day by default). |

## How it works

The spike tests the same questions from two sides, so a failure can be traced to BGL or to Power Platform.

```text
                 ┌───────────────────────────────┐
                 │   BGL API (staging)           │
                 │   OAuth · REST · webhooks     │
                 └──────▲───────────────▲────────┘
                        │               │
     direct HTTPS calls │               │ connector calls / signed webhooks
                        │               │
┌───────────────────────┴──┐   ┌────────┴──────────────────────────────┐
│ Harness (PowerShell 7)   │   │ Power Platform                        │
│ OAuth styles, API probe, │   │ Spike custom connector + custom code  │
│ signature tests,         │   │ Two test flows (inspector and proxy)  │
│ webhook simulator ───────┼──►│                                       │
└──────────────────────────┘   └───────────────────────────────────────┘
```

- **Harness** (`bgl-spike/harness/`): PowerShell 7 scripts that call BGL directly, with no Power Platform involved. They run the OAuth flow and try four token-request styles, probe which endpoints the granted scope reaches, test BGL's webhook signature, and simulate signed BGL webhooks, including a tamper suite.
- **Spike connector** (`bgl-spike/connector/`): a Power Platform custom connector. It has pass-through operations for real BGL endpoints and custom C# code for signature validation, diagnostics, and an optional notification-proxy pattern.
- **Test flows**: two small Power Automate flows you build by hand. One receives and verifies webhooks; the other is the target for the proxy pattern.

Every test has an ID from **T01 to T15**. Each records a result in the test matrix, and the results feed a decision guide on whether to use native connectors, APIM, or an Azure Function.

## Repository layout

```text
.
├── README.md                  This overview
├── CLAUDE.md                  Guidance for AI coding agents working in this repo
├── .github/workflows/         CI: runs the offline checks on pushes and pull requests (skips docs-only changes)
├── docs/
│   ├── guides/                Reusable guides, e.g. testing a custom connector with paconn
│   ├── journal/               Dated session notes
│   └── lessons/               Lessons learned; taxonomy.yml defines the allowed tags
└── bgl-spike/
    ├── README.md              Full runbook: prerequisites, run order, test matrix, decision guide
    ├── harness/               PowerShell 7 test scripts and shared module
    ├── connector/             Custom connector definition, OAuth settings and C# custom code
    ├── compile-check/         .NET project that compiles the connector code locally
    └── results/               Test output (git-ignored)
```

## Getting started

1. Read the runbook in [`bgl-spike/README.md`](bgl-spike/README.md). It covers prerequisites, including BGL staging access, a Power Platform dev environment and PowerShell 7.
2. Run the offline checks. They need no credentials, and only the compile check's first run needs network access:

   ```powershell
   cd bgl-spike/harness
   ./Test-BglSignature.ps1     # T01: signing matches BGL's published worked example
   ./Test-ConnectorSync.ps1    # the two connector scripts and the connector definition agree
   ./Test-ConnectorCompile.ps1 # both connector scripts compile (needs the .NET SDK; first run downloads packages)
   ```

   GitHub Actions runs the same three checks on pushes and pull requests (`.github/workflows/offline-checks.yml`), except when a change only touches `docs/` or Markdown files.

3. Follow the runbook's three parts in order:
   - **Part A**: the harness against BGL staging.
   - **Part B**: deploy the spike connector. To check the connector definition with Power Platform's validator first, see [Testing a custom connector with paconn](docs/guides/paconn-connector-testing.md). `pac`, which the runbook deploys with, has no validate command.
   - **Part C**: build the test flows.

## Security notes

- **No secrets in the repo.** The harness stores tokens in `bgl-spike/.secrets/`, which is git-ignored and has owner-only permissions on macOS and Linux. Delete it when you finish.
- **Flow run history exposes inputs and outputs.** Before sending real BGL traffic, turn on Secure inputs/outputs on the relevant flow steps, and keep the real webhook secret in a Key Vault-backed environment variable. The runbook explains how.
- **There is no replay protection.** A valid signed webhook verifies again within the timestamp window, so any production receiver must deduplicate on `eventId`.
- **The write test changes data.** T13 PUTs contact details back to BGL. Run it only against a throwaway staging contact.

## References

- [Testing a custom connector with paconn](docs/guides/paconn-connector-testing.md): validating, deploying and testing a custom connector definition
- BGL API documentation: [docs.api.bgl360.com.au](https://docs.api.bgl360.com.au/) and its Postman collection at [github.com/BGLCorp/bgl-api-doc](https://github.com/BGLCorp/bgl-api-doc)
- Microsoft: [Write code in a custom connector](https://learn.microsoft.com/connectors/custom-connectors/write-code)
- Microsoft: [Secure data used in cloud flows](https://learn.microsoft.com/power-automate/guidance/coding-guidelines/use-secure-inputs-outputs-triggers)
