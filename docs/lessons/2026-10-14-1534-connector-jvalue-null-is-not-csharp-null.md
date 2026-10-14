---
id: 2026-10-14-1534-connector-jvalue-null-is-not-csharp-null
title: In connector code, an explicit JSON null passes a != null check and then crashes the cast
applies_when: >
  reading an optional numeric or boolean field from a JObject request body in Power Platform
  custom connector .csx code, where a flow may send the field as JSON null
rule: >
  When reading optional fields from a JObject in connector code, use input.Value<int?>("name")
  ?? default instead of checking input["name"] != null and casting, because a JSON null is a
  JValue (not C# null) and the cast throws.
lesson_type: pitfall
phase: implementation
domain: [api, reliability]
tech: [power-platform-custom-connectors, csharp-script, newtonsoft-json]
scope: this-stack
cost_if_ignored: minor
confidence: one-off
status: active
superseded_by:
expires:
provenance:
  projects: [bgl-connector]
  date: 2026-10-14
  source: pr-review
  evidence: >
    commit 9aa4adb; bgl-spike/connector/script.csx and script-with-proxy.csx ValidateSignature
    (maxSkewSeconds)
  author:
related: []
proposed_tags: []
---

When Power Platform custom connector code reads an optional field from a JObject request body and a flow sends that field as JSON `null`, a `!= null` check passes and the cast that follows throws, so the action returns a 500.

## What happened
`ValidateSignature` read `input["maxSkewSeconds"] != null ? (int)input["maxSkewSeconds"] : 300`. A flow that sends `{"maxSkewSeconds": null}`, which happens when an optional field is cleared or bound to an empty expression, would make the cast throw. The action would then return "Spike custom code error" instead of a verification result, making T08/T11 look broken.

## Why it happened
Newtonsoft returns a `JValue` whose type is `Null` for an explicit JSON null, and that object isn't C# `null`. Casting a null `JValue` to `int` throws `ArgumentException`.

## What to do instead
- Use `input.Value<int?>("maxSkewSeconds") ?? 300`. It handles a missing field and an explicit JSON null the same way.
- Apply the same pattern to strings (`input.Value<string>("x") ?? ""`) and booleans (`Value<bool?>`).

## When this does NOT apply
Required fields that the OpenAPI definition marks as required and Power Automate always populates. Even then, the safe accessor costs nothing.
