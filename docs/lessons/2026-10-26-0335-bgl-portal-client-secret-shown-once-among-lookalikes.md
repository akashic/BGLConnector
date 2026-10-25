---
id: 2026-10-26-0335-bgl-portal-client-secret-shown-once-among-lookalikes
title: The BGL app page shows three secret-like values, and the client secret only once
applies_when: >
  copying a BGL app's OAuth client secret from the BGL Developer Portal into a Power Platform
  connector, the harness or a Key Vault secret
rule: >
  When setting up BGL OAuth, take the secret from the app's OAuth 2.0 Details by clicking Generate
  Secret, copy it at once, click Save on the app, and use that one value everywhere, because the
  portal never shows it again and the other secret-like values on the page are rejected with 401.
lesson_type: pitfall
phase: deployment
domain: [identity, security]
tech: [bgl-api]
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
    commit daf016d (bgl-spike/README.md C3 secret guidance and T03 result); harness
    Get-BglToken.ps1 -TestAllStyles runs against BGL staging on 2026-10-26 (all 401, then two
    successes after regenerating the secret)
  author:
related: [2026-10-26-0335-power-platform-oauth-error-reports-two-token-attempts]
proposed_tags: []
---

When a BGL app's client secret is copied from the BGL Developer Portal, it's easy to end up with a value BGL doesn't accept. Every token request then fails with 401, which looks like a request-format problem.

## What happened
Power Platform and the harness both got 401 from `/oauth/token` for every request style, including BGL's own documented style (`BglDocumented`). After a new secret was generated in the portal and pasted into the harness prompt, `BglDocumented` and `FormBodyBasicAuth` returned 200. The connector worked once the same new secret was pasted into its Security tab.

## Why it happened
Not fully confirmed. The value that had been used never matched BGL's current client secret. The app page has three candidates: the OAuth *Client Secret* box, which is empty except right after *Generate Secret*; the webhook *Auth – Secret key*, which stays visible in masked form; and the *Display code*, a GUID with a Copy button. The page also has its own Save button. Any of these could produce a stale or wrong secret: copying the wrong value, generating without saving, or generating a new one after the old one was stored elsewhere.

## What to do instead
- Use only *OAuth 2.0 Details → Client Secret*. Click *Generate Secret*, copy it straight away, then click **Save**.
- Store it in one place, such as a password manager or Key Vault, and paste that same value into the connector and the harness.
- Power Platform asks for the secret again on every connector update. Paste the same value; don't type it from memory.

## How to recognise it early
Every harness style gets 401 from `/oauth/token`, including `BglDocumented`, and the Basic-header attempt returns an empty body. A request-format problem would let at least `BglDocumented` through, and a bad code or scope gives a 400 instead.

## When this does NOT apply
The webhook signing secret: that is the *Auth – Secret key*, and it belongs to the webhook receiver, not OAuth.
