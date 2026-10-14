---
id: 2026-10-14-1645-bgl-refresh-response-cannot-show-sliding-expiry
title: A BGL token refresh usually can't show whether the 30-day refresh token expiry slides
applies_when: >
  testing whether refreshing a BGL OAuth token extends the refresh token's 30-day expiry, to decide
  whether a keep-alive flow can keep a Power Platform connection alive
rule: >
  When judging whether BGL refresh tokens slide, don't decide from a refresh made soon after consent:
  compare against the code exchange's expiry, wait between calls, and treat a missing
  refresh_token_expires_at or a returned existing token as undecided, then confirm with BGL.
lesson_type: pitfall
phase: testing
domain: [identity, reliability]
tech: [bgl-api, powershell]
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
    BGL Postman collection (github.com/BGLCorp/bgl-api-doc, docs/api-doc.json) "Obtain an Access
    Token" vs "Refresh an Access Token" example responses; review rounds 4 (C1) and 5 (C1, C3);
    commits 35b0ed5 and ddd7858; T05 simulation against four mock behaviours (journal round 5 entry)
  author:
related: []
proposed_tags: []
---

When a test refreshes a BGL token soon after consent to find out whether the 30-day refresh token expiry slides, the result usually can't answer the question, yet it can look like a clear "not extended".

## What happened
T05 compared `refresh_token_expires_at` before and after a refresh. Three problems turned up over two reviews:
- BGL's documented refresh response has no `refresh_token_expires_at`, only the code exchange does.
- The value is in whole seconds, so a refresh within the same second shows no change even when the expiry slides.
- With `-TestAllStyles`, each style was compared with the previous style's token, so the first style showed `Extended` and the rest `NotExtended`.

Each problem read as "expiry fixed", which steers the decision guide to "no keep-alive can save the connection".

## Why it happened
BGL also returns `is_new_token`, and its documented refresh `expires_in` (581977) is about 6 hours below the exchange's (604798). Both suggest BGL can hand back the existing, still-valid token. A keep-alive depends on a refresh *after* the 7-day access token expires, which one test session can't reach.

## What to do instead
- Compare every refresh with the expiry captured at the code exchange, and wait at least 2 seconds before each refresh.
- Report `Extended`, `NotExtended`, `Unknown` (field missing) or `Inconclusive` (existing token returned: same access token, `is_new_token` false, or a shorter `expires_in`), with the difference in seconds.
- Ask BGL directly whether the expiry slides before designing a keep-alive.
