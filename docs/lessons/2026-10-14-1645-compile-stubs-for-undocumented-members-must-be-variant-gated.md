---
id: 2026-10-14-1645-compile-stubs-for-undocumented-members-must-be-variant-gated
title: Gate stubs for undocumented connector members to the script variant that may use them
applies_when: >
  compiling custom connector .csx scripts locally against stub ScriptBase/IScriptContext classes,
  where one variant uses undocumented members (CreateNotificationUri, OriginalRequestUri) and another
  must not
rule: >
  When local compile stubs include undocumented members, define them only for the variant allowed to
  use them (for example behind #if PROXY_VARIANT), because otherwise the documented-only script can
  start using them, still pass locally, and fail only when saved to the platform.
lesson_type: pitfall
phase: testing
domain: [tooling]
tech: [power-platform-custom-connectors, csharp-script, dotnet]
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
    review round 3 finding D3 (core script using CreateNotificationUri built successfully);
    commit 35b0ed5 (PROXY_VARIANT in compile-check/Stubs.cs and CompileCheck.csproj); negative test:
    core script using OriginalRequestUri now fails with CS1061
  author:
related: [2026-10-14-1538-connector-script-variants-share-marked-block-checked-by-script]
proposed_tags: []
---

When local compile stubs for custom connector code include undocumented members, the compile check can't tell whether the documented-only script variant has started using them.

## What happened
`compile-check/Stubs.cs` declared `CreateNotificationUri` and `OriginalRequestUri` on `IScriptContext` for both scripts. A third review added those calls to the core `script.csx`, which must use documented APIs only, and the build passed. On the platform, that script would fail to save, and the failure would be misread as a core problem, distorting T07/T08.

## Why it happened
One stub file served both variants, so it defined the superset of members.

## What to do instead
- Wrap undocumented members in `#if PROXY_VARIANT` in the stubs.
- In the project file, define `PROXY_VARIANT` only when building the proxy variant (`<DefineConstants>` with a condition on `ScriptVariant`).
- Keep a negative test: a core script that uses an undocumented member must fail with CS1061.
