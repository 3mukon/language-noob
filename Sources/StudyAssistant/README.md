---
id: DOC-mod-studyassistant
type: doc
title: StudyAssistant module
status: current
visibility: public
date: 2026-10-26
summary: Streaming CLI and API adapters with Keychain credentials and temporary card-isolated conversations.
scope: ["Sources/StudyAssistant/**"]
tags: []
---

## Responsibilities

Executable discovery, capability checks, configuration validation, cancellable CLI and HTTP transports, bounded JSON-line and SSE decoding, Keychain credential access, enrichment validation and ordered per-card conversations.

## Not responsible for

It does not store vocabulary or progress, render UI, read another application's credential files or run a shell to interpret user input.

## Interface

`AssistantClient` implements `AssistantServing`. `ConversationBook` is main-actor isolated and emits request-identified events. Each queued submission owns its word snapshot, configuration, question and callback. Requests are ordered within a card and independent across cards. At most five requests can be outstanding per card; duplicate request IDs do not execute again. cancel(card:) discards pending exchanges while retaining earlier successful answers on that card. End each round with `endRound`; it returns the cancelled tasks for callers that must await shutdown. AssistantClient.waitForIdle waits for request tasks and owned child-process termination before a terminal process exits, including the existing forced-termination fallback. Native cancellation remains nonblocking.

Executable discovery prefers an explicit path, then PATH and common standalone installation directories. Claude Code can also fall back to the Claude desktop application’s versioned bundles under its application-support installation directory. This fallback examines only version and build folders, selects the newest complete executable and skips partial updates. It does not inspect conversation data. Explicit invalid paths never fall back.

LocalAssistantPreferencesReader supplies model and effort defaults plus the discovered executable path without a model request or configuration write. Each field resolves independently: an application override, then a readable local preference, then the service default. Codex uses its effective config/read response, including available new-thread defaults; the request session reads the same values before creating its thread. A successful read-only handshake supplies settings without a redundant help process; failure falls back to the usual discovery check so automatic selection still reflects available services. Claude reads the user settings file under CLAUDE_CONFIG_DIR or the home .claude directory, including model, effortLevel, an exact modelSettings effortLevel match and the corresponding model/effort environment overrides. It passes only those preferences to its isolated CLI; project hooks, tools and other settings remain excluded. API modes do not inherit CLI configuration.

The presentation cache shares concurrent lookups and retains at most 16 snapshots for 30 seconds. Configuration files, executable files and provider-reported source paths are checked by modification time, size and file identity before reuse; replacement or deletion invalidates the snapshot. Unavailable providers are retained for only one second. No configuration contents, credentials or snapshots are written to disk. LocalAssistantPreferencesLoad supports a bounded 150-millisecond first-paint wait and ignores delivery after cancellation. This cache serves only the settings display: model requests still perform current capability, configuration and isolation checks.

## Dependencies

StudyCore, Foundation networking, Security, LocalAuthentication and Darwin process signals. No storage or application dependency.

## Invariants

Only the selected word and successful exchanges on its card enter prompts. Failed or partial exchanges are excluded from future context. Discarded contexts cannot emit callbacks or restart queues. Stdin carries CLI prompts; diagnostics are drained without retention. Temporary process directories are removed after process termination. All supported transports deliver actual text increments. No transcript or draft persistence.

Codex uses a dedicated stdio App Server process for each request. Before creating its ephemeral read-only thread, the adapter inventories configured MCP servers and plugins and disables them through thread-local overrides. It verifies the thread policy and that all remaining server records are disabled with no tools before sending the prompt. It never changes global configuration or attaches to the desktop daemon. Agent-message deltas arrive before completion, and final item snapshots contribute only an unreceived suffix. Unexpected tool or approval activity, failed or interrupted turns, protocol limits and cancellation terminate the process. Claude retains its transient, tool-disabled stream-json adapter. Automatic discovery selects only local Codex or Claude while preserving explicit model and effort overrides; explicit providers never fall back.

Messages API and Responses API use native ephemeral HTTP sessions. Remote endpoints require HTTPS; loopback development endpoints may use HTTP. A base URL or a complete matching endpoint is canonicalized, while embedded credentials, queries, fragments and redirects are rejected. The Keychain account combines protocol and endpoint. Only the request transport retrieves a saved value; the settings UI queries existence without reading it. Codable settings contain only provider, model, effort, executable path, base URL and the enrichment concurrency limit. The concurrency limit defaults to one for existing settings and validates one to eight; StudyRuntime enforces it without changing provider request payloads. No request, key or provider diagnostic is logged or sent through the WebKit bridge.

All connection modes expose five effort levels: low, medium, high, xhigh and max. An empty configuration means default and omits an explicit effort override. Explicit Messages API levels enable adaptive thinking and send output_config.effort; the total output cap increases from 4,096 to 16,384 tokens to allow for thinking and answer text. The selected model and endpoint must support adaptive thinking and the chosen level; compatibility is not inferred from arbitrary model aliases and requests are not silently retried at a different level. Responses uses reasoning.effort. Thinking and signature events never become answer text. See the protocol's [effort](https://platform.claude.com/docs/en/build-with-claude/effort) and [thinking](https://platform.claude.com/docs/en/build-with-claude/thinking) contracts.

SSE framing preserves split Unicode and LF, CRLF or CR boundaries. Messages requires message_stop after a successful stop reason; Responses requires response.completed with completed status. Missing terminal events, output truncation, errors and empty answers fail the exchange and exclude partial content from future context. Responses requests use store=false and neither API sends tools or persistent conversation identifiers. Local cleanup does not promise deletion from provider operational logs. Each request is limited to 120 seconds, 2 MB of transport data and 100 KB of answer text. Native fixtures cover incremental delivery before completion, cancellation, error statuses, protocol framing and configuration migration without real credentials or paid requests.
