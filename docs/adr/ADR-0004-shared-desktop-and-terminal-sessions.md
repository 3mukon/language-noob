---
id: ADR-0004
type: adr
title: Share session orchestration between desktop and terminal frontends
status: accepted
visibility: public
date: 2026-10-28
summary: Add an optional macOS terminal client over shared session services and existing domain modules.
scope: ["Package.swift", "Sources/**", "Tests/**", "tools/**", "README.md", "docs/architecture.md"]
tags: []
related: [ADR-0002, ADR-0003]
supersedes: []
superseded_by:
---

## Context

Terminal study should use the same vocabulary, review schedule, saved progress and assistant adapters as the desktop application. Native orchestration currently combines learning effects and settings with WebKit message payloads. A second independent coordinator would let reveal, grading, retry and conversation behavior diverge.

## Options

| Option | Trade-off |
|---|---|
| Share session services and add a thin terminal frontend | Preserves one behavior contract and local data; requires separating native bridge code from orchestration |
| Duplicate the native coordinator in a terminal executable | Initially smaller extraction, but creates two implementations of persistence and asynchronous lifetimes |
| Drive the graphical application through terminal commands | Reuses the window's process but requires a graphical session and cannot provide independent terminal study |

## Decision

Use StudyRuntime as a presentation-independent composition layer over StudyCore, StudyStorage and StudyAssistant. It owns shared session effects, ordinary settings, data locations and bundled vocabulary bootstrap. It has no AppKit or WebKit dependency. LanguageNoob maps typed session actions and snapshots to the existing native/web presentation. LanguageNoobCLI supplies Chinese terminal interaction and executable commands; neither frontend imports the other.

Keep macOS 14 or later as the supported platform and preserve the desktop's paper interface. The terminal client offers study, learn, review, search, info, import, stats and configuration commands. Read-only queries support structured output. Interactive sessions preserve reveal-before-grade, explicit assessment completion, card-local streaming questions and temporary context cleanup.

Both clients use the same default data directory, schema and Keychain destinations, with an explicit directory override for isolated operation. Each process owns its live round. Persistent writes remain transactional; settings changes preserve unrelated fields. Model/API configuration and cancellation retain ADR-0003's boundaries. Terminal input and output are injectable so process tests can exercise EOF, interruption and noninteractive behavior without a real model service.

Package and verify both executables through the existing application build entry point. Retain every native regression and add shared-session, terminal-command and cross-client persistence checks. Do not bundle a new corpus as a side effect of adding a frontend.

## Consequences

Both clients can evolve their presentation without reimplementing learning policy. The native coordinator becomes a smaller adapter, and the build carries a shared runtime plus another executable. CLI releases still depend on macOS system SQLite and Keychain; this decision does not establish cross-platform support or live synchronization between open sessions.

This proposal extends ADR-0002's composition and graphical-only delivery boundary while preserving its existing desktop behavior. The protected architecture document must be updated only after approval.

## Revisit when

Another platform, remote sessions, persistent conversations or multiple concurrently synchronized study views become requirements.
