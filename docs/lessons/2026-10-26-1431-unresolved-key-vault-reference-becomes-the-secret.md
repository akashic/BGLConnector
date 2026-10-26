---
id: 2026-10-26-1431-unresolved-key-vault-reference-becomes-the-secret
title: An unresolved Key Vault reference reaches the app as literal text, which can become a public secret
applies_when: >
  an Azure Functions or App Service app reads a signing key, HMAC secret or other credential from an app setting
  that is a Key Vault reference (@Microsoft.KeyVault(...))
rule: >
  When a secret comes from a Key Vault reference, treat a value starting "@Microsoft.KeyVault(" as unset and fail
  closed, because when the secret is missing or the identity can't read it the app receives the reference text
  itself, and a check that only rejects empty values would verify against a string anyone can read in the template.
lesson_type: pitfall
phase: implementation
domain: [security, integration]
tech: [azure-functions, azure-key-vault]
scope: universal
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
    bgl-spike/receiver/src/BglWebhookReceiver/ReceiverOptions.cs (ConfiguredValue.IsSet) and its tests
    (WebhookProcessorTests.Missing_or_unresolved_secret_fails_closed); Microsoft Learn, "Use Key Vault references
    as app settings" (references are resolved by the platform and cached; a failed resolution is reported in the
    portal's Environment variables blade)
  author:
related: [2026-10-14-1645-connector-hmac-verify-fails-open-on-empty-secret]
proposed_tags: []
---

When a webhook receiver reads its HMAC secret from a Key Vault reference, a missing secret or a missing role assignment doesn't produce an empty value. The app gets the reference text, and a fail-closed check that only looks for an empty string then accepts it as the key.

## What happened
The BGL receiver's Bicep template sets `Bgl__WebhookSecret` to `@Microsoft.KeyVault(VaultName=…;SecretName=bgl-webhook-secret)`. The secret is set by a person after the first deployment, so for a while it doesn't exist. During that window the app setting holds the reference string. The template is in a public repo, so anyone can work out that string, sign a request with it, and pass a check that only rejects `null` or `""`.

## Why it happened
App Service resolves the reference outside the app. If it can't (no secret, no *Key Vault Secrets User* role yet, or role propagation still in progress), it passes the original setting value through unchanged, and only the portal shows the failure. .NET happily computes an HMAC with any key, as the earlier empty-secret lesson found.

## What to do instead
- Use one helper for "has a usable value" that rejects null, whitespace and anything starting with `@Microsoft.KeyVault(` (case-insensitive). Use it for the secret and for any credential-bearing URL.
- Return 500 and refuse every request while it's unset. Report this on the health endpoint (`secretConfigured: false`), so a deployment smoke test can see it.
- Unit-test it by signing a request *with* the literal reference text and expecting it to be rejected.
- After setting or rotating the secret, refresh references with `POST …/config/configreferences/appsettings/refresh` instead of waiting up to 24 hours.

## How to recognise it early
The health endpoint or logs show a setting configured while Key Vault has no such secret. Or the portal's *Environment variables* blade shows a red Key Vault status on the setting.

## When this does NOT apply
Apps that read secrets with the Key Vault SDK at runtime, where a missing secret throws instead.
