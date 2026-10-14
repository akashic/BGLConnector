---
id: 2026-10-14-1557-connector-proxy-target-needs-pinning-not-host-allow-list
title: Pin a connector proxy's target to your own flow; a trigger-host allow-list isn't enough
applies_when: >
  custom connector code forwards webhook requests to a target URL carried in a
  Context.CreateNotificationUri proxy URL's query string, and the target is checked only against
  Power Automate or Logic Apps host names
rule: >
  When a connector proxy takes its forward target from the query string, pin it to your own flow's
  trigger host and path (a constant set at deploy time, or an HMAC over the target), because
  *.logic.azure.com and *.api.powerplatform.com are shared by every tenant and anyone holding a proxy
  URL can point it at their own flow.
lesson_type: pitfall
phase: design
domain: [security, integration]
tech: [power-platform-custom-connectors, csharp-script, power-automate]
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
    third code review of commit a2b9463 (finding S1); Microsoft Learn "Call, trigger, or nest
    workflows with HTTPS endpoints in Azure Logic Apps" (shared prod-NN.<region>.logic.azure.com
    trigger hosts); bgl-spike/connector/script-with-proxy.csx ProxyTargetPrefix and IsAllowedTarget;
    reflection test of IsAllowedTarget (same-host other flow and other-tenant host both rejected)
  author:
related: [2026-10-14-1534-docusign-notification-proxy-pattern-trusts-query-target]
proposed_tags: []
---

When custom connector code forwards webhooks to a target taken from a notification proxy URL's query string, checking only that the target is a Power Automate or Logic Apps host doesn't restrict where it can forward, because those hosts are shared by every tenant.

## What happened
An earlier review found that the proxy variant (copied from the DocuSign pattern) forwarded to any `target`. The fix allowed only https hosts ending in `.logic.azure.com` or `.api.powerplatform.com`, and the docs claimed the proxy "can't be pointed at an arbitrary URL". A third review pointed out that Consumption Logic Apps trigger URLs live on shared hosts such as `prod-24.northcentralus.logic.azure.com`. Anyone with an Azure subscription can create one, so the allow-list still let the proxy relay into any tenant's flow.

## Why it happened
The check was made on the host, which identifies the platform, not the owner. The earlier threat model was also wrong. Editing `target` changes only where requests sent to *that edited URL* go. The webhook provider keeps calling the URL registered with it, so real events can't be collected by editing a copy. The real remaining risk is an open relay.

## What to do instead
- Pin the target: a `ProxyTargetPrefix` constant set to your own trigger URL up to the `?`, and forward only when scheme, host, port and path match. Refuse everything while it's empty.
- Alternatively, have the code that creates the proxy URL add an HMAC over the target, and verify it before forwarding.
- To learn whether the platform signs the query, edit `target` in a real proxy URL and see whether the platform rejects it or your code's own 400 comes back.

## When this does NOT apply
Proxies whose target is fixed in code or configuration rather than carried in the URL.
