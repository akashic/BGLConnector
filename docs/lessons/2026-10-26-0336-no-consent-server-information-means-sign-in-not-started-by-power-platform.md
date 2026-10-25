---
id: 2026-10-26-0336-no-consent-server-information-means-sign-in-not-started-by-power-platform
title: '"No consent server information" means Power Platform did not start that OAuth sign-in'
applies_when: >
  a browser lands on global.consent.azure-apim.net/ErrorHandler with "Invalid request parameters:
  No consent server information was associated with this request" after approving on an identity
  provider's consent page
rule: >
  When this error appears, check where the sign-in started and restart it from Power Platform's
  Sign in button, because the consent service only accepts codes for sign-ins it began; a refreshed
  or copied pop-up, or another client (such as a test harness) using the connector's redirect URL,
  sends it a code it can't match.
lesson_type: pitfall
phase: testing
domain: [identity, integration]
tech: [power-platform-custom-connectors, powershell, bgl-api]
scope: this-stack
cost_if_ignored: minor
confidence: one-off
status: active
superseded_by:
expires:
provenance:
  projects: [bgl-connector]
  date: 2026-10-26
  source: direct-experience
  evidence: >
    commit daf016d (bgl-spike/README.md C4 error table and Part A -RedirectUri note); harness run on
    2026-10-26 whose authorize URL carried redirect_uri=https://global.consent.azure-apim.net/redirect/...
  author:
related: [2026-10-26-0336-connector-redirect-url-changes-with-connector-name]
proposed_tags: []
---

When the browser ends up on Microsoft's consent error page saying "No consent server information was associated with this request", the code went to Power Platform's consent service from a sign-in Power Platform didn't start. This looks like a connector problem, but it isn't one.

## What happened
While the connector was being troubleshot, the laptop's copy of `Get-BglToken.ps1` had been edited to use the connector's redirect URL, so that BGL would accept the redirect. BGL then sent the harness's authorization code to `global.consent.azure-apim.net`, which showed this error. The same edit also made the harness's own listener fail at once with `Exception calling "Parse" with "1" argument(s): "An invalid IP address was specified."`, because the listener only works on a local IP address.

## Why it happened
The consent service matches each returning code to a sign-in it began, using the `state` value and a cookie set when Power Platform opens the pop-up. A code from any other client, a pop-up that was refreshed or reached with Back, or an authorize URL pasted into a new tab carries no such record.

## What to do instead
- For the connector: close stale BGL and consent tabs and start again from **Sign in** in the flow, or from *Connections → New connection*. Don't refresh the pop-up or copy its URL.
- For the harness: keep `-RedirectUri` on `http://127.0.0.1:8765/callback` and register that on the BGL app. With `-ManualCode`, paste the `127.0.0.1` URL you land on, not BGL's authorize page.

## How to recognise it early
The authorize URL contains `redirect_uri=https%3A%2F%2Fglobal.consent.azure-apim.net…`, but you didn't start the sign-in from Power Platform.

## When this does NOT apply
If the sign-in was started fresh from Power Platform and still fails this way, suspect the browser blocking the consent service's cookie, for example Edge's tracking prevention.
