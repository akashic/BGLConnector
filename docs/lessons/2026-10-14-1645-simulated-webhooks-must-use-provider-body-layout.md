---
id: 2026-10-14-1645-simulated-webhooks-must-use-provider-body-layout
title: Simulated BGL webhooks must use BGL's newline body layout or raw-body tests falsely pass
applies_when: >
  testing whether a receiver (such as a Power Automate HTTP trigger) preserves the exact raw bytes
  of a BGL webhook body for HMAC verification, using a simulator that generates the body
rule: >
  When simulating BGL webhooks to test raw-body fidelity, send BGL's documented layout (a newline
  after each top-level field) as well as compact JSON, because a receiver that re-serialises JSON
  leaves compact bodies unchanged and breaks only BGL's real layout.
lesson_type: pitfall
phase: testing
domain: [security, integration]
tech: [bgl-api, power-automate, powershell]
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
    BGL Postman collection (github.com/BGLCorp/bgl-api-doc, docs/api-doc.json) webhook request
    template; review round 3 finding D5; commit 35b0ed5 (Send-BglTestWebhook -BodyStyle Bgl, T11 needs
    both styles); check run: a BGL-style body verified as sent and failed after compact
    re-serialisation; live T11 run on 2026-10-26 (bgl-spike/README.md test matrix): the same signed
    message verified with -BodyStyle Compact and failed "Signature mismatch" with -BodyStyle Bgl
  author:
related: [2026-10-14-1534-power-automate-trigger-url-change-breaks-bgl-signature]
proposed_tags: []
---

When a simulator tests whether a receiver keeps BGL's exact webhook bytes, compact single-line JSON can pass even though real BGL bodies would fail.

## What happened
T11 asks whether Flow A's `string(triggerBody())` returns the bytes BGL signed. The simulator only ever sent compact JSON. BGL's own webhook template has a newline after every field: `{"entityId":"…",\n"eventId":"…",\n…}`. Power Automate parses the JSON body and `string()` re-serialises it compactly. A compact body comes out byte-identical, so T11 would pass, and the design would then fail at T12 on real traffic.

Confirmed live on 2026-10-26: against Flow A, the compact body verified and BGL's layout failed with "Signature mismatch". A compact-only test would have passed T11.

## Why it happened
Re-serialisation is only visible when the input wasn't already in the serialiser's output format. The simulator happened to match the receiver's format, not the provider's.

## What to do instead
- Generate both layouts (`-BodyStyle Compact` and `-BodyStyle Bgl`) and require both to verify before passing T11.
- Check the layout against a sample or template from the provider. Don't assume compact JSON.

## How to recognise it early
A raw-body test that passes, while the receiver is known to parse JSON before your code sees it.
