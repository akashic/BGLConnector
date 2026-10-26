---
id: 2026-10-26-1600-record-then-forward-dedupe-must-undo-on-every-exit
title: A webhook receiver that records an event before forwarding it must undo the record on every way out, and mustn't let the caller cancel in between
applies_when: >
  a webhook or message receiver de-duplicates by recording an event ID first and then hands the event to another
  system, relying on the sender's retry when the hand-off fails
rule: >
  Once the event is recorded, every exit other than a successful hand-off must remove the record, including exceptions
  and timeouts. Don't pass the incoming request's cancellation token to the record or hand-off steps; bound them with
  their own timeouts. Otherwise an interrupted hand-off leaves the event recorded and the sender's retry is dropped as
  a duplicate, losing the event silently.
lesson_type: pitfall
phase: implementation
domain: [integration, reliability]
tech: [azure-functions, dotnet]
scope: universal
cost_if_ignored: project-level
confidence: one-off
status: active
superseded_by:
expires:
provenance:
  projects: [bgl-connector]
  date: 2026-10-26
  source: code-review
  evidence: >
    bgl-spike/receiver/src/BglWebhookReceiver/WebhookProcessor.cs (ProcessAsync, ForgetAsync) and WebhookProcessorTests
    (Hand_off_that_throws_still_forgets_the_event, Event_store_failure_returns_503_and_leaves_no_record)
  author:
related: [2026-10-26-1431-unresolved-key-vault-reference-becomes-the-secret]
proposed_tags: []
---

Recording an event ID before forwarding stops replays and duplicate retries. But it turns any interrupted hand-off into a lost event: the record says "done", so the sender's retry is accepted and thrown away.

## What happened
A security review of the BGL receiver found that the record was removed only when the forwarder *returned* a failure. Three other ways out left it in place:
- the request's cancellation token firing mid hand-off (the host shutting down, or possibly the caller disconnecting), which the forwarder deliberately rethrew;
- `HttpRequestHeaders.Add` throwing on a body-supplied value it wouldn't accept;
- a table write that timed out on the client after it had reached the table.

None of them was reported either, because the exception escaped the code that reports errors.

## Why it happened
The happy path and the "forwarder said no" path were tested; exceptions weren't. Passing the request's token everywhere looks like good practice, but here it lets the caller stop the work halfway, between "recorded" and "forwarded".

## What to do instead
- After the record is written, wrap the hand-off so that *any* exception counts as a failed hand-off and removes the record.
- If writing the record itself fails, try a removal too: the write may have landed.
- Don't use the request token for these steps. Give the store and HTTP clients short timeouts instead (here, 5 s per storage try and 20 s for the hand-off).
- Sanitise values copied from the body into headers, rather than letting them throw.
- Add a catch-all at the function boundary that reports anything unexpected.
- Test with a forwarder that *throws* (including `OperationCanceledException`), and then check that a retry is forwarded.

## When this does NOT apply
Receivers that forward first and record afterwards. They accept occasional duplicates instead, and the downstream system must be idempotent.
