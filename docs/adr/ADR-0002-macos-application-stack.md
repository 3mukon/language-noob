---
id: ADR-0002
type: adr
title: Host the paper interface in a native macOS window with a Swift learning core
status: accepted
visibility: public
date: 2026-10-26
summary: AppKit and WebKit host the approved paper interface, with Swift modules for learning, storage, and local AI adapters.
scope: ["Package.swift", "Sources/**", "Tests/**", "tools/**"]
tags: []
related: [ADR-0001]
supersedes: []
superseded_by:
---

## Context

The paper interaction has been approved for application development. Its layered cards, physical transitions, upright text on tilted paper, temporary conversations, and optional reading zoom are the UI baseline. The application must launch as a macOS app and support offline learning without requiring terminal interaction during study.

## Options

| Option | Trade-off |
|---|---|
| AppKit window, bundled WebKit interface, Swift core | Preserves the approved layout and motion while providing native window, menu, file import, and process integration; requires a small explicit message bridge |
| SwiftUI with AppKit window integration | Uses native view controls throughout, but requires translating and revalidating the paper layout, text editor, and animation behavior |
| Electron or Tauri | Supports web-based presentation but adds a runtime or toolchain unnecessary for a macOS-only application |

## Decision

Propose a Swift package targeting macOS 14 or later. AppKit owns a single transparent, borderless study window and the macOS menu. A bundled HTML/CSS/JavaScript interface runs in WKWebView without a local HTTP server. The window presents the papers directly. Menus provide settings, library management, statistics, and session actions without adding permanent application chrome to the stack.

Keep the implementation in four feature modules:

- `StudyCore`: vocabulary models, SM-2 scheduling, workload selection, and card-instance identity. It depends only on Foundation.
- `StudyStorage`: SQLite vocabulary, review history, progress, and word enrichment; it depends on StudyCore and the system SQLite library.
- `StudyAssistant`: local executable discovery, adapter configuration, cancellable requests, response validation, and temporary per-card context; it depends on StudyCore.
- `LanguageNoob`: native application lifecycle, window and menu integration, bundled presentation, and a typed message bridge. It composes the other modules.

Use native file dialogs for JSON vocabulary import. Imported entries must become searchable and eligible for learning; validate an entire import before committing it. Persist application settings and learning data under Application Support. Do not persist messages, drafts, provider session identifiers, or conversation transcripts.

Study due entries first, cap the initial review batch at 30, and normally add 10 new words. Reduce new words to 5 when more than 10 entries are due and to 0 when more than 20 are due. Support separate learn and review modes. Review answers are revealed before grading as Again, Hard, Good, or Easy. Store each grade and history event in one transaction and prevent duplicate submission from advancing the schedule twice.

Provide Codex, Claude, and Grok adapters, with automatic selection using that order and explicit selection disabling fallback. Model and reasoning settings remain empty unless the user chooses them. Detect missing executables and authentication failures in the GUI. Requests carry only the selected word and that card's temporary messages. Use separate process arguments rather than a shell command, disable tool use where supported, and cancel active work when its round ends. Only adapters with a verified incremental protocol expose live text increments; buffered responses must not be presented as live model streaming.

First delivery is a locally runnable development `.app` with original sample vocabulary and JSON import. Wider vocabulary distribution requires documented data permissions. Signing, notarization, distribution, and Intel validation are release work and are not implied by a successful local Apple Silicon build.

## Consequences

The approved UI can be carried into the application without a browser dependency or development server. The web view must load bundled assets only, reject external navigation, and expose only a fixed set of bridge operations. Assistant output and imported text are rendered as text, never executable markup.

Tests must cover scheduling boundaries, due/new selection, import validation and visibility, storage transactions, context isolation, cancellation, and adapter argument and response handling with fake executables. Build checks must compile the app and execute these tests. GUI verification must also cover paper-only presentation, card gestures, editable-field selection, reading zoom, retained drafts, and restoration.

## Revisit when

Reassess the presentation layer if native accessibility or input behavior cannot meet acceptance, or if platform support changes. Reassess local process adapters if a provider removes the required stateless, restricted execution mode.
