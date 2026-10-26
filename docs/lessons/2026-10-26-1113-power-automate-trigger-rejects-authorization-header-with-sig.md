---
id: 2026-10-26-1113-power-automate-trigger-rejects-authorization-header-with-sig
title: A Power Automate HTTP trigger rejects any request that also carries an Authorization header
applies_when: >
  planning to point a third-party webhook, such as BGL's, that signs or authenticates with the
  Authorization header straight at a Power Automate "When an HTTP request is received" trigger
  (or a Logic Apps Request trigger) whose URL carries a sig= shared access signature
rule: >
  When a webhook sender puts anything in the Authorization header, put a receiver in front of the
  flow that moves it to another header or into the body, because the trigger accepts only one
  authorization scheme and returns 401 DirectApiRequestHasMoreThanOneAuthorization before the flow runs.
lesson_type: pitfall
phase: design
domain: [integration, security]
tech: [power-automate, bgl-api]
scope: this-stack
cost_if_ignored: project-level
confidence: one-off
status: active
superseded_by:
expires:
provenance:
  projects: [bgl-connector]
  date: 2026-10-26
  source: direct-experience
  evidence: >
    T08 result in bgl-spike/README.md; Send-BglTestWebhook.ps1 runs against an "Anyone" HTTP trigger
    on 2026-10-26 (HTTP 401 DirectApiRequestHasMoreThanOneAuthorization with two different secrets);
    https://learn.microsoft.com/azure/logic-apps/set-up-security-permissions#access-for-inbound-calls-to-request-based-triggers
  author:
related: [2026-10-14-1534-power-automate-trigger-url-change-breaks-bgl-signature]
proposed_tags: []
---

When a webhook sender authenticates with the `Authorization` header and is pointed straight at a Power Automate HTTP trigger, every delivery fails with 401 and no flow run appears, so the flow can't even log what arrived.

## What happened
The BGL webhook simulator posted a correctly signed message to Flow A's *Anyone* trigger URL, with BGL's signature in the `Authorization` header (`spike <timestamp> <hmac>`). The platform answered 401 `{"error":{"code":"DirectApiRequestHasMoreThanOneAuthorization","message":"The request has SAS authentication scheme, 'spike' authorization scheme or internal token scheme…"}}`. A second run with a different secret got the same response, and the flow's run history stayed empty.

## Why it happened
The `sig=` in the trigger URL is a shared access signature (SAS), and a request trigger accepts exactly one authorization scheme. Any `Authorization` header counts as a second scheme, whatever its contents. An *Anyone* trigger needs the SAS. A *tenant users* trigger expects an Entra ID token in that same header. Only Logic Apps Consumption can turn the SAS off, and then it requires Entra ID. BGL always sends its signature as `Authorization`, and it can't be configured to use another header.

## What to do instead
- Register a fixed receiver (an Azure Function, or APIM) with BGL. It verifies the signature, or moves the header to something like `X-BGL-Authorization` or into the body, before it calls the flow.
- To test the flow side without that receiver, send the signature under another header name: `Send-BglTestWebhook.ps1 -HeaderName X-BGL-Authorization`. Flow A reads `triggerOutputs()?['headers']?['X-BGL-Authorization']`.
- The connector notification proxy (T10) moves the header into the body before it forwards to the flow. Whether its own inbound URL accepts an `Authorization` header is still untested.

## How to recognise it early
The response is a 401 whose code is `DirectApiRequestHasMoreThanOneAuthorization`, with no flow run in the history. If the flow had rejected the message itself, you would see a run that returned 401.

## When this does NOT apply
Senders that authenticate through a query string, or a body field, or a header with another name. Also triggers whose SAS has been disabled and that are called with a real Entra ID token.
