---
id: 2026-10-14-1534-bgl-multiple-scopes-need-literal-plus-on-token-call
title: BGL wants scopes joined by a literal + in both URLs; form-encoding the plus sends %2B
applies_when: >
  requesting more than one BGL OAuth scope (for example smsf_partner and cas_incorporator)
  and building the authorize URL and the /oauth/token request separately
rule: >
  When requesting multiple BGL scopes, join them with a literal '+' in query strings and
  with a space in form bodies, because BGL requires '+' in both the authorize and token URLs
  and URL-encoding the whole scope string sends '%2B' instead.
lesson_type: pitfall
phase: implementation
domain: [identity, api]
tech: [bgl-api, powershell]
scope: this-stack
cost_if_ignored: rework
confidence: one-off
status: active
superseded_by:
expires:
provenance:
  projects: [bgl-connector]
  date: 2026-10-14
  source: pr-review
  evidence: >
    BGL Postman collection (github.com/BGLCorp/bgl-api-doc, docs/api-doc.json) "Multiple
    Scopes" section; commit 9aa4adb; bgl-spike/harness/Get-BglToken.ps1 $scopeQuery and
    $scopeForm
  author:
related: []
proposed_tags: []
---

When more than one BGL OAuth scope is requested, the authorize call and the token call can end up sending different scope strings, and the token call may then fail even though BGL's documented style is correct.

## What happened
`Get-BglToken.ps1` built the authorize URL with a literal `+` between scopes. Its `BglDocumented` token style ran `[uri]::EscapeDataString` over the whole scope string, so it sent `smsf_partner%2Bcas_incorporator`. BGL would then see a space-separated list on authorize and a literal plus on the token call. That would have made T03 record BGL's own documented style as failing because of the harness.

## Why it happened
BGL's docs say multiple scopes must be "separated by a '+' symbol" in both the authorize URL and the access token URL. In a query string a bare `+` decodes as a space, while `%2B` decodes as a literal plus, so escaping the joined string changes its meaning.

## What to do instead
- Query strings: escape each scope separately and join with a literal `+`.
- Form bodies: join scopes with a space and let form encoding turn it into `+`. That puts the same bytes on the wire as the query-string version.
- Send `scope` on the token and refresh calls as well. BGL marks it as required there.

## How to recognise it early
`invalid_scope` or a scope mismatch on the token call only when more than one scope is requested.

## When this does NOT apply
A single scope, which encodes the same either way.
