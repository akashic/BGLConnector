---
id: 2026-10-14-1653-guard-deploy-time-values-with-failing-check-and-ci
title: Guard deploy-time values in a public repo with a check that fails until they're cleared
applies_when: >
  a public repository's code needs values edited in place for a test or deployment (a trigger URL,
  a test secret, an environment host) that must never be committed
rule: >
  When code needs in-place deploy-time values in a public repo, keep them as empty constants, make a
  check fail while any is set (with an explicit override for the run that needs them), and run that
  check in CI without the override, because a reminder in a README doesn't stop a careless commit.
lesson_type: convention
phase: deployment
domain: [security, source-control, ci]
tech: [github-actions, powershell]
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
    review round 4 finding S1; commit 35b0ed5 (Test-ConnectorSync fails while ProxyTargetPrefix or
    SpikeTestSecret is set, unless -AllowDeployValues); commit 4149910 (.github/workflows/offline-checks.yml
    runs it without the override); first CI run 38517567791 showing both "is empty" checks passing
  author:
related: [2026-10-14-1557-connector-proxy-target-needs-pinning-not-host-allow-list]
proposed_tags: []
---

When code in a public repository needs values edited in place for a test or deployment, a careless commit can publish them, and a "clear before committing" note in the README is easy to miss.

## What happened
The spike connector's proxy variant needs `ProxyTargetPrefix` set to a real Flow B trigger URL for T09/T10, and the simulator test can use a `SpikeTestSecret` constant. Both live in a tracked `.csx` file in a public repo. A fourth review pointed out that after a T09/T10 run, `git commit -a` would publish the environment host and workflow ID, or a test secret. That breaks the repo's company-agnostic rule even though the trigger's `sig` isn't included.

## What to do instead
- Keep such values as constants that are empty in the repo, and make the code refuse to act while they're empty, so a forgotten value fails safe.
- Have an offline check fail while any of them is set (`Test-ConnectorSync.ps1`: "ProxyTargetPrefix is empty (clear it before committing)").
- Give the check an explicit override (`-AllowDeployValues`) for the local run that legitimately needs the values, and name it in the runbook step.
- Run the check in CI without the override, so a set value can't be merged even if the local check is skipped.

## When this does NOT apply
Values the platform can supply at runtime (environment variables, connection parameters). Prefer those. This convention is for constants that have to be edited into code, such as single-file connector scripts.
