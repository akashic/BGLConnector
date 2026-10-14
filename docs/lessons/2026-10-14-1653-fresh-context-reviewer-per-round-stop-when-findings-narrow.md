---
id: 2026-10-14-1653-fresh-context-reviewer-per-round-stop-when-findings-narrow
title: Use a fresh-context reviewer for each review round, and stop when findings narrow
applies_when: >
  running repeated code reviews of a spike or integration where the same agent wrote the code, made
  the earlier fixes, and would otherwise review its own work
rule: >
  When reviewing code the reviewer helped write, give each round to a fresh reviewer with no shared
  context but a list of what's already fixed, verify its claims before acting, and stop reviewing
  once a round finds nothing above low, because self-review misses its own wrong assumptions and later
  rounds return less than integration testing.
lesson_type: convention
phase: testing
domain: [process, security]
scope: this-stack
cost_if_ignored: rework
confidence: one-off
status: active
superseded_by:
expires:
provenance:
  projects: [bgl-connector]
  date: 2026-10-14
  source: retro
  evidence: >
    docs/journal/2026-10-14.md entries 16:17 and round 5; round 3 overturned a round-2 security
    claim (lesson 2026-10-14-1534-docusign-notification-proxy-pattern-trusts-query-target superseded);
    round 5 found the empty-secret fail-open missed by rounds 1-4 (commit ddd7858); findings narrowed
    from 13 (round 3) to 11 (round 4) to 8 mostly low (round 5)
  author:
related: [2026-10-14-1645-connector-hmac-verify-fails-open-on-empty-secret]
proposed_tags: []
---

When the same agent writes the code, makes the fixes and then reviews them, repeated reviews keep confirming its own assumptions. A fresh reviewer with no shared context finds what self-review can't.

## What happened
Rounds 1 and 2 were reviewed by the agent that wrote the fixes. Round 2 added a host allow-list to the connector proxy and declared it safe. Rounds 3 to 5 were each given to a new reviewer that had only the repo and a list of what was already fixed. Round 3 showed the allow-list restricted nothing, because Logic Apps hosts are shared by every tenant, and that the threat model was overstated. Round 5 found the connector accepted any signature when the secret was empty, which every earlier round had missed.

## What to do instead
- Give each round to a new reviewer. Supply the repo, the docs to check against, and a list of fixes not to re-report, but ask it to check whether those fixes are right.
- Require file and line references, a concrete failure scenario, and CONFIRMED or PLAUSIBLE for each finding. Verify doc-based claims yourself before acting.
- Tell the reviewer that few or no findings is a valid result, so it doesn't pad the report.
- Stop when a round finds nothing above low and most findings are narrowing refinements of the last round's fixes. Move to testing against the real system.

## When this does NOT apply
One-off reviews of code you didn't write, where there's no accumulated context to bias the reviewer.
