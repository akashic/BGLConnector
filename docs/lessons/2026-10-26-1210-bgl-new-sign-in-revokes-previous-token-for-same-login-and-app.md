---
id: 2026-10-26-1210-bgl-new-sign-in-revokes-previous-token-for-same-login-and-app
title: A new BGL sign-in revokes the previous access token for the same login and app
applies_when: >
  more than one client signs in to the same BGL app with the same BGL login: a Power Platform
  connection and a test harness, two connections (for example in different environments), or a
  connection and a token-owning Azure Function
rule: >
  When planning BGL OAuth clients, give each client its own BGL login or its own BGL app, because
  BGL keeps one live token per login per app and each new sign-in makes the previous access token
  fail with 401 invalid_token, which stops the other client until someone signs it in again.
lesson_type: pitfall
phase: design
domain: [identity, reliability]
tech: [bgl-api, power-platform-custom-connectors]
scope: this-stack
cost_if_ignored: outage
confidence: repeated
status: active
superseded_by:
expires:
provenance:
  projects: [bgl-connector]
  date: 2026-10-26
  source: direct-experience
  evidence: >
    bgl-spike/README.md decision guide and T06 note; on 2026-10-26 the harness token was rejected
    with invalid_token after the connection signed in, and the connection's Get user details failed
    with invalid access token after the harness signed in again
  author:
related: [2026-10-26-0336-bgl-refresh-invalidates-previous-refresh-token]
proposed_tags: []
---

When two clients sign in to the same BGL app with the same BGL login, the one that signed in first starts failing with 401 `invalid_token` before its token has expired, and nothing tells it why.

## What happened
In the morning, the harness got a token with `Get-BglToken.ps1`. Later, a Power Automate connection to the spike connector signed in with the same BGL login and app. The next harness probe got 401 `{"error":"invalid_token","error_description":"Invalid access token: <token>"}` on every call, although the token had days left. A new harness sign-in fixed the probe, and straight afterwards the connection's *Get user details* failed with "invalid access token". So it happened in both directions.

## Why it happened
BGL appears to keep one live token per login per app. A new authorization replaces the existing token instead of issuing a second one alongside it. This fits BGL's `is_new_token` field on the token response. BGL doesn't document it. Power Platform refreshes a connection's token only when it expires, so a revoked but unexpired token stays broken until someone uses *Fix connection*.

## What to do instead
- Give each client its own BGL login or its own BGL app: the Power Platform connection, the harness, and any token-owning Function.
- Use a separate BGL app per Power Platform environment, or one service account per environment, so a dev connection can't log out production.
- Expect *Fix connection* or a new connection to log out whatever else uses that login. Do harness work first, then fix the connection.
- After a re-sign-in, check the other clients with a cheap call such as `/client/rateLimitStatus`.

## How to recognise it early
A 401 `invalid_token` whose message names the token, on a token that hasn't expired, shortly after someone signed in elsewhere with the same BGL login.

## When this does NOT apply
Clients that use different BGL logins, or different BGL apps. Not yet tested: whether the revoked token's refresh token still works.
