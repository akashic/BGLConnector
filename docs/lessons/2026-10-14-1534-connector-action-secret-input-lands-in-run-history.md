---
id: 2026-10-14-1534-connector-action-secret-input-lands-in-run-history
title: A secret passed as a connector action input is visible in Power Automate run history
applies_when: >
  designing a custom connector action (such as webhook signature validation) that takes a
  shared secret or credential as an input parameter from the calling flow
rule: >
  When a connector action needs a secret from the flow, turn on Secure inputs for that action
  and source the secret from a Key Vault-backed secret environment variable, because run
  history shows action inputs to anyone who can view the flow's runs.
lesson_type: pitfall
phase: design
domain: [security, observability]
tech: [power-automate, power-platform-custom-connectors, azure-key-vault, dataverse]
scope: this-stack
cost_if_ignored: project-level
confidence: one-off
status: active
superseded_by:
expires:
provenance:
  projects: [bgl-connector]
  date: 2026-10-14
  source: pr-review
  evidence: >
    bgl-spike/README.md Part C (Flow A, "Run history is readable"); connector operation
    ValidateBglSignature (secret parameter); Microsoft Learn "Secure data used in cloud flows"
    (learn.microsoft.com/power-automate/guidance/coding-guidelines/use-secure-inputs-outputs-triggers)
  author:
related: []
proposed_tags: []
---

When a custom connector action takes a shared secret as an input parameter, every run's history shows that secret in plain text to anyone who can view the flow's runs.

## What happened
The spike's *Validate BGL signature* action takes the BGL webhook secret as an input, and the runbook had the real secret typed straight into it for T12. Power Automate records action inputs in run history, so the real secret would have been readable by everyone with access to the flow. The inspector flow also composed all the request headers. That exposed the BGL `Authorization` header, which can be replayed within the timestamp window, alongside the trigger URL, whose `sig` makes the URL itself a credential.

## Why it happened
Run history shows inputs and outputs of every action and trigger unless Secure inputs/outputs is turned on. Secret environment variables aren't offered in the dynamic content picker, so the easy path is to type the value in.

## What to do instead
- Turn on **Secure inputs** for the action that takes the secret, and **Secure outputs** for the trigger and any Compose of headers or body (Settings → Security).
- Store the secret in an environment variable of type Secret backed by Azure Key Vault. Read it with the Dataverse *Perform an unbound action* → `RetrieveEnvironmentVariableSecretValue` action, with Secure outputs on.
- Prefer designs where the connector reads the secret itself, so it never passes through flow inputs.

## When this does NOT apply
Throwaway test secrets used only with a simulator, where visible run history helps diagnosis. Switch before any real traffic.
