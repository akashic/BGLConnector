---
id: 2026-10-14-1534-bgl-contact-get-masks-tfn-put-takes-fewer-fields
title: BGL contact GET masks tfn and returns fields PUT rejects, so echoing it back corrupts data
applies_when: >
  reading a contact with GET /sf/contactsByIds and writing it back with PUT /sf/contacts/{id},
  for example in an idempotent write or permission test against SF360
rule: >
  When writing a BGL contact back, build the PUT body from the fields BGL documents for PUT,
  never send tfn, and compare the whole record before and after, because GET masks tfn as
  'Provided' and BGL doesn't document whether PUT clears fields it isn't sent.
lesson_type: pitfall
phase: testing
domain: [data-integrity, api]
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
    BGL Postman collection (github.com/BGLCorp/bgl-api-doc, docs/api-doc.json) requests
    "List of Contacts by IDs" and "Update Contacts"; commit 9aa4adb (PUT field whitelist);
    bgl-spike/harness/Invoke-BglProbe.ps1 ConvertTo-BglContactUpdate and Compare-BglRecord;
    docs/journal/2026-10-14.md 15:26 entry
  author:
related: []
proposed_tags: []
---

When a BGL contact read with GET /sf/contactsByIds is written back with PUT /sf/contacts/{id}, the round trip can overwrite or clear real client data, even though the values look unchanged.

## What happened
The T13 "idempotent write" probe PUT the GET record straight back. A first review found it could also PUT an error body if the read failed. Checking BGL's docs then showed a worse problem: GET returns `tfn` as `Provided`/`Not Provided`, so echoing it back could replace a real tax file number with the word `Provided`. The fix whitelisted the PUT fields. A second review found that fix compared only the fields sent, so a cleared TFN would still have reported "unchanged".

## Why it happened
GET and PUT have different shapes. GET returns read-only fields (`contactId`, `contactType`, `entityRelationships`, `addressId`) and masked ones (`tfn`). PUT documents a narrower set, and some values differ in form: `sex` comes back as `MALE`, while PUT accepts only `Male`/`Female`. BGL doesn't say whether omitted PUT fields are left alone or cleared.

## What to do instead
- Build the PUT body from BGL's documented PUT fields only, without `tfn`.
- Send `abn`/`acn` exactly as read. Converting them to numbers, as the PUT table suggests, drops an ACN's leading zero.
- Compare the whole GET record before and after, and list every changed field.
- Run write tests only against a throwaway staging contact, and require confirmation.

## How to recognise it early
`tfn` changing from `Provided` to `Not Provided`, or a 400 response that is really a shape mismatch rather than a permission problem.

## When this does NOT apply
A contact with no TFN or entity relationships, where there's nothing to lose. Still compare the whole record.
