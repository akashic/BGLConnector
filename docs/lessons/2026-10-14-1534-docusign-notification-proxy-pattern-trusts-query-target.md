---
id: 2026-10-14-1534-docusign-notification-proxy-pattern-trusts-query-target
title: The DocuSign webhook-proxy pattern forwards to a target URL taken from the query string
applies_when: >
  copying the Context.CreateNotificationUri webhook proxy pattern from a certified connector
  (such as DocuSign) into custom connector code that forwards webhook headers and body
rule: >
  When a connector proxy forwards to a target taken from the notification URL's query string,
  allow-list the target to https Power Automate or Logic Apps trigger hosts, because neither
  the pattern nor the platform is known to stop someone editing the query to redirect signed
  webhook data.
lesson_type: pitfall
phase: design
domain: [security, integration]
tech: [power-platform-custom-connectors, csharp-script, power-automate]
scope: this-stack
cost_if_ignored: project-level
confidence: one-off
status: superseded
superseded_by: 2026-10-14-1557-connector-proxy-target-needs-pinning-not-host-allow-list
expires:
provenance:
  projects: [bgl-connector]
  date: 2026-10-14
  source: pr-review
  evidence: >
    microsoft/PowerPlatformConnectors certified-connectors/DocuSign/script.csx
    RedirectWebhookNotification (logicAppsUri decoded from the query, no host check);
    bgl-spike/connector/script-with-proxy.csx IsAllowedTarget; bgl-spike/README.md T10
  author:
related: [2026-10-14-1557-connector-proxy-target-needs-pinning-not-host-allow-list]
proposed_tags: []
---

> **Superseded.** The fix below (a host allow-list) is insufficient, and the threat model overstated: editing a proxy URL cannot capture webhooks BGL sends to the registered URL. See [2026-10-14-1557-connector-proxy-target-needs-pinning-not-host-allow-list](2026-10-14-1557-connector-proxy-target-needs-pinning-not-host-allow-list.md).

When custom connector code copies the certified connectors' notification-proxy pattern, it forwards webhook headers and body to whatever target URL is in the notification URL's query string, with no check on where that is.

## What happened
The spike's proxy variant copied the DocuSign pattern: `Context.CreateNotificationUri("/spike/webhook?target=<base64 url>")`, then the receiver decodes `target` and POSTs diagnostics to it. Those diagnostics include BGL's `Authorization` header and the raw body. DocuSign's `RedirectWebhookNotification` likewise decodes `logicAppsUri` and posts to it without validating the host.

## Why it happened
The pattern assumes only the platform-generated URL is ever called. It's undocumented whether the platform rejects a notification URL whose query was edited. If it doesn't, anyone holding a proxy URL could point it at their own server and collect replayable signed webhooks.

## What to do instead
- Allow only https targets whose host ends in `.logic.azure.com` or `.api.powerplatform.com`, both when creating the proxy URL and when forwarding.
- Test the platform's behaviour: edit the `target` parameter in a real proxy URL, for example to another flow's trigger, send traffic, and record whether it arrives (T10).

## When this does NOT apply
Proxies whose target is fixed in code or configuration rather than carried in the URL.
