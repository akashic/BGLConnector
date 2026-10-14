---
id: 2026-10-14-1538-connector-script-variants-share-marked-block-checked-by-script
title: Keep code shared by connector script variants in a marked block that a script checks
applies_when: >
  a Power Platform custom connector needs two or more versions of its custom code (for example a
  core script and a proxy or debug variant), so common code has to be copied into each .csx file
rule: >
  When connector script variants must duplicate code, put the shared part between identical
  BEGIN SHARED / END SHARED marker comments, keep variant-only code outside them, and run a check
  that fails if the marked blocks differ, because a connector accepts only one script file and
  copied fixes otherwise drift silently.
lesson_type: convention
phase: implementation
domain: [tooling, reliability]
tech: [power-platform-custom-connectors, csharp-script, powershell]
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
    commit 9aa4adb (maxSkewSeconds null fix and header-split fix each applied separately to
    script.csx and script-with-proxy.csx); bgl-spike/harness/Test-ConnectorSync.ps1 and its
    negative test (one-character change in a copy reported "Shared block identical" FAIL);
    Microsoft Learn "Use custom code in a custom connector" FAQ (one script file per connector)
  author:
related: [2026-10-14-1534-connector-jvalue-null-is-not-csharp-null]
proposed_tags: []
---

When a Power Platform custom connector needs more than one version of its custom code, the common code has to be copied into each `.csx` file, and fixes made to one copy silently miss the other unless the duplication is marked and checked.

## What happened
The spike has a core script and a proxy variant that adds undocumented webhook-proxy calls. About 110 lines are copied into both: signature checking, the self-test, the echo operation and helpers. In one review, two fixes (an explicit JSON `null` crash and the header-splitting rule) each had to be made twice, once per file. Nothing would have flagged a missed copy, and T07/T08 results from the core variant would then no longer describe the proxy variant used in T10.

## Why it happened
Microsoft allows only one script file per connector, and there's no include mechanism. Variants therefore mean copies, and copies drift.

## What to do instead
- Wrap the shared code in identical comment lines in every variant:
  `// ===== BEGIN SHARED: keep identical in <files> (checked by <script>) =====` … `// ===== END SHARED =====`.
  Naming the check inside the marker tells the next editor about the rule.
- Keep variant-specific code outside the markers. Here that's the `switch` in `ExecuteAsync` above the block and the proxy-only methods below it.
- Run a check (`Test-ConnectorSync.ps1`) that extracts each block and fails unless they match exactly. Have the same check confirm the list of code-handled operations agrees across the scripts, `apiProperties.json` and the OpenAPI definition.
- Run it after every connector edit, alongside the compile check.

## When this does NOT apply
A connector with a single script. Also cases where the variants can be generated from one source at build time; that's stronger, but it adds a build step a spike may not justify.
