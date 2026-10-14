---
id: 2026-10-14-1645-connector-hmac-verify-fails-open-on-empty-secret
title: Connector HMAC verification accepts any signature when the secret is empty
applies_when: >
  custom connector or other .NET code verifies an HMAC webhook signature using a shared secret that
  arrives as an input parameter, environment variable or Key Vault lookup that could be empty or null
rule: >
  When verifying an HMAC signature, reject an empty or null secret before computing anything, because
  .NET's HMACSHA256 accepts an empty key, so a mis-bound or missing secret lets anyone sign a header
  that verifies.
lesson_type: pitfall
phase: implementation
domain: [security]
tech: [power-platform-custom-connectors, csharp-script]
scope: this-stack
cost_if_ignored: project-level
confidence: one-off
status: active
superseded_by:
expires:
provenance:
  projects: [bgl-connector]
  date: 2026-10-14
  source: pr-review
  evidence: >
    review round 5 finding S1 (reproduced by reflection on the compiled script); commit ddd7858
    (Verify rejects an empty secret, SpikeSelfTest emptySecretRejected, T01 check 10);
    docs/journal/2026-10-14.md round 5 entry
  author:
related: [2026-10-14-1534-connector-action-secret-input-lands-in-run-history]
proposed_tags: []
---

When connector code verifies an HMAC webhook signature with a secret that can arrive empty or null, it accepts any header signed with an empty key, so the check fails open.

## What happened
The spike connector's *Validate BGL signature* action read the secret with `(string)input["secret"] ?? ""` and passed it straight to `Verify`. In T12 the secret is bound to a Key Vault environment variable lookup. A mis-bound expression or failed lookup would send null, which became `""`. A fifth review signed a header with an empty HMAC key, any client code and the current time, and the compiled `Verify` returned `isValid: true`. Four earlier reviews missed it.

## Why it happened
`new HMACSHA256(Encoding.UTF8.GetBytes(""))` is valid in .NET, so an empty key raises no error. The PowerShell harness was safe only by accident: `-Secret` is a mandatory `[string]`, which rejects an empty string. So the two implementations disagreed, and only the connector failed open.

## What to do instead
- Put `if (string.IsNullOrEmpty(secret)) { reason = "Secret is empty"; return invalid; }` at the top of the verify function, before parsing the header.
- Add a self-test that signs with an empty key and expects rejection, so a deployed connector proves it fails closed.
- Test the same case in the other implementation, so the two can't drift.

## How to recognise it early
Any verify path where the secret has a fallback such as `?? ""` or `|| ''`.
