---
id: 2026-10-26-0335-power-platform-oauth-error-reports-two-token-attempts
title: Power Platform's OAuth error lists two token attempts; with BGL, only the second matters
applies_when: >
  diagnosing a "Create and authorize OAuth connection failed ... failed to exchange code for access
  token" error on a custom connector that uses the Generic OAuth 2 identity provider
rule: >
  When the connection error quotes two token attempts, ignore BGL's 401 on the form-body attempt
  and diagnose from the Basic authorization header attempt, because BGL always rejects credentials
  in the body and Power Platform then retries with a Basic header.
lesson_type: pitfall
phase: testing
domain: [identity, integration]
tech: [power-platform-custom-connectors, bgl-api]
scope: this-stack
cost_if_ignored: rework
confidence: one-off
status: active
superseded_by:
expires:
provenance:
  projects: [bgl-connector]
  date: 2026-10-26
  source: direct-experience
  evidence: >
    commit daf016d (bgl-spike/README.md C4 error table and T03/T04 results); connection errors
    from the spike connector against BGL staging on 2026-10-26
  author:
related: [2026-10-26-0335-power-platform-oauth-omits-scope-on-token-call]
proposed_tags: []
---

When a Generic OAuth 2 custom connector fails to exchange the code for a token, the error text quotes BGL's response to two separate attempts, and the first one is always a misleading 401.

## What happened
Each failed connection to BGL staging reported "Client ID and secret sent in form body.. Response status code=Unauthorized", then "Client ID and secret sent in Basic authorization header..", each with its own response body. The form-body 401 (`Full authentication is required to access this resource`) never changed. Only the second response changed as each problem was fixed, and it pointed to the real cause each time.

## Why it happened
The generic provider first sends the client ID and secret in the form body (RFC 6749 client_secret_post). If that fails, it retries with them in a Basic header (client_secret_basic). BGL accepts only the Basic header: harness T03 showed `FormBody` and `FormBodyWithScope` always 401, while `BglDocumented` and `FormBodyBasicAuth` succeed.

## What to do instead
Read the Basic-header attempt's response:

| Response | Cause |
| --- | --- |
| 401, empty body | BGL rejected the client ID and secret: the secret is stale, unsaved or the wrong value |
| 400 `invalid_scope`, `Empty scope` | Add `?scope=` to the token and refresh URLs |
| 200 | The token exchange worked; look elsewhere |

If you're unsure whether the secret or the request format is at fault, run `Get-BglToken.ps1 -TestAllStyles`. If every style gets 401, including `BglDocumented`, it's the credentials.

## When this does NOT apply
Identity providers other than Generic OAuth 2, and token endpoints that accept client credentials in the body. For those, the first attempt is the meaningful one.
