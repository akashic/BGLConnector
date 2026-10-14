---
id: 2026-10-14-1645-stackowner-blocks-connector-updates
title: stackOwner in apiProperties.json blocks paconn updates, which can look like a code failure
applies_when: >
  updating a custom connector from the command line (paconn, possibly pac connector update) when
  apiProperties.json contains a stackOwner property
rule: >
  When a custom connector will be updated from the CLI, leave stackOwner out of apiProperties.json,
  because Microsoft documents that paconn can't update a connector that has it, and the failure can
  be misread as a problem with the code being deployed.
lesson_type: pitfall
phase: deployment
domain: [tooling, integration]
tech: [power-platform-custom-connectors, pac-cli]
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
    Microsoft Learn "Create a custom connector with the CLI" limitations
    (learn.microsoft.com/connectors/custom-connectors/paconn-cli#limitations); review round 3
    finding D4; commit 35b0ed5 (stackOwner and publisher removed)
  author:
related: []
proposed_tags: [paconn]
---

When a custom connector's `apiProperties.json` contains `stackOwner`, paconn can't update the connector, and in a spike that failure can be recorded as the answer to the wrong question.

## What happened
The spike's `apiProperties.json` had `"stackOwner": "BGL Corporate Solutions"` and a `publisher`. Step C5 swaps in the proxy script with `pac connector update --script-file`, and the runbook said a failed save means the undocumented `CreateNotificationUri` isn't available (the T09 answer). If the update failed because of `stackOwner`, T09 would have recorded a false result.

## Why it happened
Microsoft documents: "there's a limitation that prevents you from updating your connector's artifacts in your environment using Paconn when the `stackOwner` property is present". Whether `pac connector update` shares the limitation isn't documented. `stackOwner` and `publisher` matter only for certification. Here, `stackOwner` also wrongly claimed BGL owned the connector.

## What to do instead
- Leave `stackOwner` (and `publisher`) out of a connector that isn't being certified.
- If certifying, keep two versions of the properties file, as Microsoft suggests: one with `stackOwner` for submission, one without for updating in your own environment.
- Before reading a failed CLI update as a code result, rule out tooling causes. Here the local compile check rules out syntax errors.
