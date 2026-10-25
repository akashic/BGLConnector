---
id: 2026-10-26-0335-bgl-portal-sample-oauth-urls-are-templates
title: The BGL portal's sample OAuth URLs are templates; pasted into a connector they override it
applies_when: >
  filling in the Authorization URL, Token URL or Refresh URL on a Power Platform custom connector's
  Security tab for BGL, using the URLs shown in the BGL Developer Portal's "OAuth URLs" box
rule: >
  When configuring a connector for BGL, enter the bare authorize and token URLs (plus only a
  deliberate ?scope= on the token and refresh URLs), never the portal's sample URLs, because their
  query strings duplicate the parameters Power Platform adds and BGL can act on the sample values.
lesson_type: pitfall
phase: deployment
domain: [identity, integration]
tech: [power-platform-custom-connectors, bgl-api]
scope: this-stack
cost_if_ignored: rework
confidence: one-off
status: active
superseded_by:
expires:
provenance:
  projects: [bgl-connector]
  date: 2026-10-26
  source: direct-experience
  evidence: >
    commit daf016d (bgl-spike/README.md C3 "Keep the authorization, token and refresh URLs as
    deployed"); connector Security tab and BGL consent page during the 2026-10-26 staging session
  author:
related: [2026-10-26-0335-power-platform-oauth-omits-scope-on-token-call]
proposed_tags: []
---

When a BGL connector's OAuth URLs are copied from the BGL Developer Portal's "OAuth URLs" box, they bring sample query strings with them, and BGL can act on those values instead of the ones Power Platform sends.

## What happened
The connector's Security tab had been filled in from the portal. The Authorization URL already contained `response_type`, `client_id`, `scope=developer` and `redirect_uri`. The Token and Refresh URLs contained `grant_type=authorization_code&code=%3CAUTHCODE%3E&scope=developer&redirect_uri=…`. Power Platform appended its own parameters, so each one appeared twice. BGL's consent page asked only for *Read user details / Read firm details*, the `developer` scope, rather than the `smsf_partner` the connector requested.

## Why it happened
The portal's values are documentation: `%3CAUTHCODE%3E` is a literal `<AUTHCODE>` placeholder. The refresh example even uses the authorization-code grant type. When a parameter is duplicated, BGL apparently uses the first value, which is the pasted one, judging by the consent page. The effect on the token call wasn't observed separately, because a bad client secret was failing it at the same time.

## What to do instead
- Authorization URL: `https://integrations.staging.bgl360.com.au/u/oauth/authorize`
- Token and Refresh URLs: `https://api.staging.bgl360.com.au/oauth/token?scope=<scopes>`
- Put the scopes in the connector's Scope field. Power Platform adds `client_id`, `redirect_uri`, `state`, the code and the grant type itself.

## How to recognise it early
The consent page lists permissions for a scope you didn't configure, or the authorize URL in the pop-up's address bar shows `client_id` or `scope` twice.
