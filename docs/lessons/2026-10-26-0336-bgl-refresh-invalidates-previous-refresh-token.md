---
id: 2026-10-26-0336-bgl-refresh-invalidates-previous-refresh-token
title: BGL issues a new refresh token on every refresh and the old one stops working
applies_when: >
  more than one client or process holds the same BGL refresh token (for example a Power Platform
  connection and a test harness or token-owning Function sharing one consent), or a refresh
  response could be lost before its new refresh token is saved
rule: >
  When designing BGL token handling, give each refresher its own BGL login or app and save the new refresh
  token from every refresh response before using the access token, because BGL rotates refresh
  tokens and rejects the previous one, so a second holder or a lost response loses the grant.
lesson_type: pitfall
phase: design
domain: [identity, reliability]
tech: [bgl-api]
scope: this-stack
cost_if_ignored: outage
confidence: one-off
status: active
superseded_by:
expires:
provenance:
  projects: [bgl-connector]
  date: 2026-10-26
  source: direct-experience
  evidence: >
    commit daf016d (T05 result in bgl-spike/README.md test matrix); Get-BglToken.ps1 -TestAllStyles
    refresh section against BGL staging on 2026-10-26 (rotated=True, previous refresh token
    reusable: False, current token still valid afterwards: True)
  author:
related: [2026-10-14-1645-bgl-refresh-response-cannot-show-sliding-expiry]
proposed_tags: []
---

When more than one process holds the same BGL refresh token, or a refresh response is lost before it's saved, the next refresh with the old token fails, and the connection or service has to be re-consented.

## What happened
T05 refreshed a BGL staging token with each request style. Every successful refresh returned a different refresh token (`rotated=True`). Then the harness tried the *previous* refresh token again, and BGL rejected it. The *current* refresh token still worked afterwards, so reusing an old one didn't revoke the whole token family.

## Why it happened
BGL rotates refresh tokens: each refresh replaces the stored grant, and the token that was just used is no longer valid. Its documentation doesn't say this. A Power Platform connection should cope, since it keeps the refresh token returned with each new access token, but that hasn't yet been observed over a real 7-day refresh. Anything that copies or shares a refresh token can't cope.

## What to do instead
- Don't share one grant between a Power Platform connection and another client. Give each its own BGL login or BGL app, or let one service own the token. A second consent by the same login to the same app may not help: BGL's `is_new_token` field suggests it can hand back the existing token.
- In a token-owning service, such as a Function with the refresh token in Key Vault, save the new refresh token before using the new access token, and make sure only one refresh runs at a time.
- Use only the latest token saved under `.secrets/` from harness runs. Earlier copies are dead.

## How to recognise it early
A refresh that worked yesterday is rejected by `/oauth/token`, while a different client using the same BGL login keeps working.

## When this does NOT apply
A single Power Platform connection used on its own, provided it stores each new refresh token as expected. Whether refreshing also extends the 30-day expiry is a separate question; see the related lesson.
