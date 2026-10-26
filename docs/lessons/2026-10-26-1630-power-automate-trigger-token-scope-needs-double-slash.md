---
id: 2026-10-26-1630-power-automate-trigger-token-scope-needs-double-slash
title: A token for an Entra-protected Power Automate HTTP trigger must be requested with the scope "https://service.flow.microsoft.com//.default"
applies_when: >
  code (a Function, an app, a managed identity) calls a Power Automate "When an HTTP request is received" trigger set to
  "Any user in my tenant" or "Specific users in my tenant"
rule: >
  Request the token with scope "https://service.flow.microsoft.com//.default" (two slashes), because the trigger requires
  aud to be exactly "https://service.flow.microsoft.com/" with its trailing slash, and the single-slash scope yields an
  aud without it. Allow a service principal by its object ID (the token's oid), and send no sig-bearing URL plus token
  mix: a SAS trigger rejects a second credential.
lesson_type: pitfall
phase: implementation
domain: [security, integration]
tech: [power-automate, azure-identity, entra-id]
scope: universal
cost_if_ignored: hours
confidence: verified
status: active
superseded_by:
expires:
provenance:
  projects: [bgl-connector]
  date: 2026-10-26
  source: direct-experience
  evidence: >
    az account get-access-token with each scope form: "//.default" gave aud "https://service.flow.microsoft.com/",
    "/.default" gave aud without the slash. Microsoft Learn "Add OAuth authentication for HTTP request triggers"
    (audience must match exactly, including trailing slashes; service principal object IDs allowed).
    bgl-spike/receiver/src/BglWebhookReceiver/FlowAuthHandler.cs and FlowAuthHandlerTests.
  author:
related: [2026-10-26-1113-power-automate-trigger-rejects-authorization-header-with-sig]
proposed_tags: []
---

Power Automate's Entra option on HTTP triggers checks the token's `aud` against `https://service.flow.microsoft.com/` exactly, trailing slash included. The obvious scope, audience plus `.default`, drops that slash.

## What happened
While protecting the BGL receiver's flows so only the Function's managed identity could start them, the token scope was first written as audience + `.default`. Requesting tokens with both forms showed the difference:
- `https://service.flow.microsoft.com//.default` gives `aud` = `https://service.flow.microsoft.com/`
- `https://service.flow.microsoft.com/.default` gives `aud` = `https://service.flow.microsoft.com`

The second form would have been rejected by the trigger, which reports a 401 such as `MisMatchingOAuthClaims` that doesn't say which claim is wrong.

## Why it happened
Entra treats everything before the final `/.default` as the resource identifier, and copies it into `aud`. To keep a trailing slash in the resource, you need two slashes in the scope. The same applies to other resources registered with a trailing slash, such as `https://management.core.windows.net/`.

## What to do instead
- Build the scope as `audience + "/.default"` where the audience already ends in `/`, giving `//.default`. Unit-test the exact scope string.
- To limit the trigger to one app, choose *Specific users in my tenant* and enter the service principal's **object ID**. For a Function, that's the managed identity's `principalId`, which is the token's `oid`.
- Set the trigger and the caller to the same mode. A trigger on *Anyone* (with a `sig` in the URL) rejects any request that also has an `Authorization` header.
- Check a token's `aud`, `tid` and `oid` by decoding it, for example from `az account get-access-token --scope ...`, before blaming the flow.

## When this does NOT apply
Sovereign clouds use a different audience (Microsoft's page lists them), but the double-slash rule still applies whenever the audience ends in `/`.
