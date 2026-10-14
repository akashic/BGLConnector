---
id: 2026-10-14-1645-bgl-date-filters-need-iso-date-time
title: BGL change-date filters take ISO date-times, not plain dates
applies_when: >
  calling BGL list endpoints with change filters such as /cas/documents?updatedAfter= or
  /sf/firm/lodgements?modifiedAfter= to poll for changes
rule: >
  When sending BGL date filters, use a UTC ISO date-time such as 2026-09-14T00:00:00Z, because BGL
  documents updatedAfter as yyyy-MM-dd'T'HH:mm:ss and a plain date may be rejected or ignored,
  making change polling look impossible.
lesson_type: pitfall
phase: implementation
domain: [api, integration]
tech: [bgl-api]
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
    BGL Postman collection (github.com/BGLCorp/bgl-api-doc, docs/api-doc.json) "List All Documents"
    updatedAfter and "ATO Lodgements (Firm)" modifiedAfter descriptions; review round 3 finding D2;
    commit 35b0ed5 (Invoke-BglProbe $since format, swagger descriptions)
  author:
related: []
proposed_tags: []
---

When BGL list endpoints are polled with a plain date in a change filter, BGL may reject or ignore it, and the probe then concludes the documented change filters don't work.

## What happened
The T14 probe sent `updatedAfter=2026-09-14` and `modifiedAfter=2026-09-14`, and the connector definition described the parameter as "Date, e.g. 2026-09-01". BGL documents `/cas/documents` `updatedAfter` as "a UTC date in ISO format: yyyy-MM-dd'T'HH:mm:ss. Example: 2000-10-31T01:30:00Z". For `/sf/firm/lodgements` `modifiedAfter`, it says only "UTC Time", with response values like `2018-12-14T05:45:00.000+0000`.

## Why it happened
The format was assumed from the parameter name rather than checked against the description.

## What to do instead
- Send `yyyy-MM-dd'T'HH:mm:ss'Z'` in UTC for `updatedAfter`, and assume the same for `modifiedAfter` until T14 confirms it.
- Say in the connector description which format is documented and which is assumed.
