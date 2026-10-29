---
id: ADR-0003
type: adr
title: Add explicit streaming API connections with Keychain credentials
status: accepted
visibility: public
date: 2026-10-28
summary: Extend local assistant adapters with Messages and Responses HTTP streams while keeping credentials out of settings and card context.
scope: ["Sources/StudyAssistant/**", "Sources/LanguageNoob/**", "Tests/**"]
tags: []
related: [ADR-0002]
supersedes: []
superseded_by:
---

## Context

Local command-line adapters require a separately installed and authenticated provider. API access should use the same temporary card conversation without exposing credentials to the web presentation. The current Codex exec protocol provides completed messages; Claude CLI exposes text deltas. The API protocols provide server-sent text events.

## Options

| Option | Trade-off |
|---|---|
| Native HTTP transports and Keychain storage | Uses system networking and credential storage, supports real increments and explicit destination ownership; requires protocol and cancellation tests |
| Persist keys beside ordinary settings | Simpler settings handling but mixes secrets into ordinary data files and backups; rejected |
| A local proxy or additional CLI for API access | Reuses process integration but adds a service and installation requirement; rejected |

## Decision

Extend the assistant-integration portion of ADR-0002 with explicit Messages API and Responses API modes, and remove the unavailable Grok adapter. Keep its four-module stack, local study persistence and presentation decisions unchanged. Automatic selection continues to choose only available local Codex or Claude adapters. Explicit selections never fall back to another destination.

StudyAssistant owns HTTP request construction, bounded SSE parsing, cancellation, and a narrow injectable credential-store interface backed by macOS Keychain. LanguageNoob owns native configuration fields and secure key entry. Keys are scoped by API protocol and canonical endpoint; they never enter Codable settings, prompts, diagnostics, or the WebKit bridge. Saved values are not filled back into the UI. A blank field preserves a saved key and a separate operation removes it.

Use HTTPS for remote endpoints and permit HTTP only for loopback development services. Reject embedded URL credentials, queries, fragments and HTTP redirects. Use ephemeral URL sessions with no cache or cookie persistence. Send only the current card's quoted vocabulary and successful conversation. Set stream to true, omit tools and persistent conversation identifiers, and set Responses store to false. Service-side operational retention is governed by the service and is not guaranteed by local session cleanup.

Successful completion requires the protocol's terminal event and nonempty text. Errors, limits, interruptions and incomplete responses remain failed exchanges. Render actual text increments immediately, never an artificial replay of buffered text. Use a separate stdio Codex App Server process for each request. Verify ephemeral, read-only thread creation and an empty external-tool inventory before sending the prompt; disable executable, app, browser and delegation capabilities for the session. Consume agent-message deltas and terminate the process on completion, error or cancellation. No connection to the desktop shared daemon or persisted thread is used.

## Consequences

Users can configure API access without another executable. The assistant module adds system networking and Security framework responsibilities, while storage and study dependencies remain unchanged. Fixtures must verify framing, errors, timeout and cancellation, key scoping, settings migration and absence of credentials from persisted settings. Real keys are entered by the user through the native application.

## Revisit when

A provider changes its streaming contract, compatible endpoints require another authentication scheme, or Codex App Server changes its transient-session and isolation contract.
