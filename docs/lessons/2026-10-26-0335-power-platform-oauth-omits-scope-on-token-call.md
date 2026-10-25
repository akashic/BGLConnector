---
id: 2026-10-26-0335-power-platform-oauth-omits-scope-on-token-call
title: Power Platform's generic OAuth never sends scope on the token call; BGL rejects that
applies_when: >
  creating a connection to a custom connector that uses the Generic OAuth 2 identity provider
  against an API, such as BGL, whose /oauth/token endpoint requires a scope parameter
rule: >
  When the token endpoint requires scope, put it in the query string of the connector's token and
  refresh URLs (tokenUrlTemplate/refreshUrlTemplate, e.g. ?scope=smsf_partner) and keep it in step
  with the scopes array, because the generic provider sends scope only on the authorize call.
lesson_type: workaround
phase: deployment
domain: [identity, integration]
tech: [power-platform-custom-connectors, bgl-api]
scope: this-stack
cost_if_ignored: project-level
confidence: one-off
status: active
superseded_by:
expires: 2027-04-26
provenance:
  projects: [bgl-connector]
  date: 2026-10-26
  source: direct-experience
  evidence: >
    commit daf016d (bgl-spike/connector/apiProperties.json token and refresh URLs; T04 result in
    bgl-spike/README.md); live T04 connection attempt against BGL staging on 2026-10-26
  author:
related: [2026-10-14-1534-bgl-multiple-scopes-need-literal-plus-on-token-call]
proposed_tags: []
---

When a custom connector uses the Generic OAuth 2 identity provider against a token endpoint that requires `scope`, the connection fails after consent, and it looks like the connector can't work without a token proxy.

## What happened
The spike connector's connection to BGL staging failed after consent. The Basic-header token attempt returned 400 `{"error":"invalid_scope","error_description":"Empty scope (either the client or the user is not allowed the requested scopes)"}`. The harness's `FormBodyBasicAuth` style, which sends the same request plus `scope` in the body, succeeded. With the token and refresh URLs changed to `https://api.staging.bgl360.com.au/oauth/token?scope=smsf_partner`, the connection was created and *Get user details* returned 200 (T04).

## Why it happened
The generic provider sends the connector's Scope setting on the authorize request only, not on the code exchange or the refresh. BGL marks `scope` as required on `/oauth/token`. It reads parameters from the query string as well as the form body, so a static `scope` in the URL combines with the code and grant type that Power Platform posts in the body.

## What to do instead
- Set `tokenUrlTemplate` and `refreshUrlTemplate` in `apiProperties.json` to the token URL plus `?scope=<scopes>`, with multiple scopes joined by a literal `+`.
- Whenever you add a scope to the `scopes` array, add it to both URLs too.
- Re-check this before building an APIM token proxy: this one change was all T04 needed.

## How to recognise it early
The connection error quotes a 400 `invalid_scope` / `Empty scope` from the *Basic authorization header* attempt.

## When this does NOT apply
APIs that don't require `scope` on the token call, or that ignore query-string parameters on a POST. Re-review on the expiry date, in case Power Platform starts sending `scope` on the token call.
