---
id: 2026-10-26-0336-connector-redirect-url-changes-with-connector-name
title: A custom connector's OAuth redirect URL changes when the connector is renamed or re-created
applies_when: >
  renaming a Power Platform custom connector that uses a per-connector OAuth redirect URL
  (redirectMode GlobalPerConnector), or running pac connector create again for one that already
  exists, after its redirect URL was registered with the identity provider
rule: >
  When a connector is renamed or re-created, copy the new Redirect URL from its Security tab into
  the identity provider's app and delete any connector you no longer use, because the redirect URL
  is derived from the connector's name and the provider rejects the new one until it's registered.
lesson_type: pitfall
phase: deployment
domain: [identity, integration]
tech: [power-platform-custom-connectors, pac-cli, bgl-api]
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
    commit daf016d (bgl-spike/README.md C3 "The redirect URL comes from the connector's name");
    BGL "Invalid redirect" error during the 2026-10-26 staging session
  author:
related: []
proposed_tags: []
---

When a custom connector with a per-connector OAuth redirect URL is renamed or created again, its redirect URL changes, and the identity provider starts rejecting the sign-in.

## What happened
The spike connector had been renamed in the portal to *BGL SF360 SpikeTest*, and its redirect `…/redirect/new-5fbgl-20sf360-20spiketest-<id>` was registered on the BGL app. Running `pac connector create` again made a second connector, named *BGL SF360 Spike* from the swagger `info.title`. A sign-in through that connector sent `…/redirect/new-5fbgl-20sf360-20spike-<id>`, and BGL showed `401 Invalid redirect: … is not a registered redirect`.

## Why it happened
With `redirectMode: GlobalPerConnector`, Power Platform builds the redirect URL from the connector's name (the `5f` and `20` are the encoded `_` and space). `pac connector create` always makes a new connector rather than updating one, and it takes the name from the swagger file, not from any portal rename. `pac connector update` keeps the existing connector.

## What to do instead
- After any rename or re-create, copy the Redirect URL from the connector's Security tab and add it to the BGL app's redirect URLs. BGL allows 5, so remove stale entries.
- Use `pac connector update --connector-id <id>` for changes, not `create`.
- Delete connectors you aren't using, so a flow can't silently bind to the wrong one.

## How to recognise it early
An `Invalid redirect` error from the provider whose URL differs from the registered one only in the connector-name segment. Or more than one connector of the same kind under *Custom connectors*.

## When this does NOT apply
Connectors on the shared redirect (`https://global.consent.azure-apim.net/redirect` with no suffix), where the redirect URL doesn't include the connector name.
