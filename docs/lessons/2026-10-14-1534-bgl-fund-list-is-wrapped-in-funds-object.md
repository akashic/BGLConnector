---
id: 2026-10-14-1534-bgl-fund-list-is-wrapped-in-funds-object
title: BGL /fund/list returns {"funds":[...]} with fundID, so first-item lookups find nothing
applies_when: >
  taking a fund or entity ID from the BGL GET /fund/list response to drive follow-up calls
  such as /sf/funds/{fundId}
rule: >
  When reading BGL's /fund/list, unwrap the funds array and read fundID, because the response
  is an object rather than a bare array and code that takes the first element finds no ID and
  silently skips every per-fund call.
lesson_type: pitfall
phase: implementation
domain: [api, integration]
tech: [bgl-api, powershell]
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
    BGL Postman collection (github.com/BGLCorp/bgl-api-doc, docs/api-doc.json) request
    "Entity List" example response; bgl-spike/harness/Invoke-BglProbe.ps1 fund detection;
    docs/journal/2026-10-14.md 15:26 entry
  author:
related: []
proposed_tags: []
---

When code takes a fund ID from the first item of BGL's GET /fund/list response, it finds no ID, and every follow-up per-fund call is skipped without an error.

## What happened
The API probe took `@($funds) | Select-Object -First 1` and looked for `id`, `fundId` or `entityId` to drive probes P05–P09. It only ever printed "No fund id found - pass -FundId", so those five probes never ran unless an ID was passed by hand. The problem was found by comparing the code with BGL's documented example response.

## Why it happened
BGL documents the response as `{"funds":[{"fundID":"...", "fundCode":"..."}]}`. The first element of that is the wrapper object, which has a `funds` property but no ID. PowerShell property access is case-insensitive, so `fundId` would have matched `fundID`; the code was just looking at the wrong object. Other list endpoints wrap their arrays the same way, for example `/sf/contacts` returns `{"contacts":[...]}`.

## What to do instead
- Unwrap first, falling back to a bare array: `$list = if ($null -ne $json.funds) { $json.funds } else { $json }`.
- Read `fundID` explicitly.
- Check the endpoint's example response in the Postman collection before writing a parser, rather than guessing the shape.

## How to recognise it early
A probe or flow that always reports "no ID found" while the list call itself returns 200 with a non-empty body.
