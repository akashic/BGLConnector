---
id: 2026-10-14-1645-bgl-docs-use-curly-quotes-so-exact-searches-miss
title: BGL's docs use curly quotes, so exact-string searches of the collection miss formats
applies_when: >
  checking code against BGL's API documentation by searching the Postman collection JSON
  (docs/api-doc.json) for a format string, field list or enum value
rule: >
  When searching BGL's Postman collection, search loosely (for an example value, or with the quotes
  as a wildcard) and confirm "not documented" with a second search, because descriptions use curly
  quotes (’, ‘) and an exact search for yyyy-MM-dd'T'HH:mm:ss finds nothing.
lesson_type: pitfall
phase: implementation
domain: [api, process]
tech: [bgl-api, postman]
scope: this-stack
cost_if_ignored: rework
confidence: one-off
status: active
superseded_by:
expires:
provenance:
  projects: [bgl-connector]
  date: 2026-10-14
  source: direct-experience
  evidence: >
    review round 3 verification: a search for yyyy-MM-dd'T'HH:mm:ss returned only the webhook
    timestamp, while "List All Documents" documents updatedAfter as yyyy-MM-dd’T’HH:mm:ss (found by
    searching for the example 2000-10-31T01:30:00Z); commit 35b0ed5
  author:
related: [2026-10-14-1645-bgl-date-filters-need-iso-date-time]
proposed_tags: []
---

When code is checked against BGL's Postman collection by searching for an exact format string, curly quotes in BGL's descriptions make the search miss, and a documented rule can be wrongly reported as undocumented.

## What happened
While verifying a reviewer's claim that BGL documents `updatedAfter` as `yyyy-MM-dd'T'HH:mm:ss`, a regex search of `docs/api-doc.json` for that string matched only the webhook timestamp format. The claim looked unsupported. Searching for the documented example `2000-10-31T01:30:00Z` found it: the description reads `yyyy-MM-dd’T’HH:mm:ss`, with typographic quotes. The same curly quotes appear throughout BGL's field tables (`‘People’`, `‘Male’/‘Female’`).

## Why it happened
BGL's descriptions were written in a rich-text editor that substitutes curly quotes, so ASCII `'` in a search pattern never matches.

## What to do instead
- Search for example values, or use a character class for quotes: `yyyy-MM-dd.T.HH:mm:ss`.
- Before concluding something isn't documented, search again by the request name and read its whole description.
- When parsing enum lists from BGL's tables, normalise `‘’“”` to ASCII first.
