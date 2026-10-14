---
id: 2026-10-14-1645-connector-op-missing-from-scriptoperations-goes-to-backend
title: A connector operation missing from scriptOperations is sent to the real API host
applies_when: >
  a Power Platform custom connector defines fake or code-only operations (such as /spike/* actions
  that validate signatures) and routes them to custom code through apiProperties.json scriptOperations
rule: >
  When a connector has code-only operations, check that every one of them is listed in
  scriptOperations, because an operation that isn't listed is forwarded to the connector's host with
  its body and the user's OAuth token instead of running the code.
lesson_type: pitfall
phase: implementation
domain: [security, integration]
tech: [power-platform-custom-connectors]
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
    review round 3 finding S2 (reproduced: sync check passed with ValidateBglSignature removed from
    scriptOperations and both scripts); commit 35b0ed5 (Test-ConnectorSync "Every /spike/* swagger
    operation is routed to code"); commit 4149910 (CI runs the check)
  author:
related: [2026-10-14-1538-connector-script-variants-share-marked-block-checked-by-script]
proposed_tags: []
---

When a custom connector's code-only operation is left out of `scriptOperations`, the platform doesn't run the custom code for it. It forwards the request to the connector's real host.

## What happened
The spike connector's OpenAPI definition has `/spike/*` operations, such as `ValidateBglSignature`, that exist only in custom code. A third review removed one from `scriptOperations` and from both scripts, leaving the swagger path in place. The sync check still passed. In that state the platform would POST the action's body, including the webhook secret and the BGL `Authorization` header, plus the user's BGL bearer token, to `https://api.staging.bgl360.com.au/spike/validate-signature`.

## Why it happened
`scriptOperations` decides which operations go to code; everything else is a pass-through to `host`. The sync check compared lists against each other, but never checked that every code-only path was in the list.

## What to do instead
- Give code-only operations a recognisable path prefix (here `/spike/`) and check that every operation under it is in `scriptOperations`.
- Check that each listed operation has a `case` in the script's `switch`.
- Run the check in CI so a missing entry can't be merged.

## When this does NOT apply
Connectors whose `scriptOperations` is empty, which routes every operation to code.
