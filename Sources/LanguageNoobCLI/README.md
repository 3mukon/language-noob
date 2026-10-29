---
id: DOC-mod-languagenoobcli
type: doc
title: LanguageNoobCLI module
status: current
visibility: public
date: 2026-10-28
summary: Chinese terminal commands and interactive study over the shared runtime.
scope: ["Sources/LanguageNoobCLI/**"]
tags: []
---

## Responsibilities

Parse terminal arguments, format readable or structured results, handle line input and interruption, and adapt terminal study actions to StudySession. The executable is named language-noob and supports macOS 14 or later.

## Not responsible for

Workload selection, grading, retry policy, storage transactions, assistant protocols and ordinary settings persistence belong to the shared modules. This module has no desktop dependency and does not emulate paper animations.

## Interface

Run language-noob --help for command syntax. study, learn and review create independent temporary rounds. search, info and stats accept --json. import uses the shared validated JSON format. --lang selects en or ja for one command without rewriting saved preferences. --data-directory isolates the database and settings; without it, both clients share the application-support directory. Command-line learning limits apply to that round only.

Interactive sessions support next/prev, reveal, numeric grades, ask, enrich, search/open, practice, back and new. Navigation wraps and never grades. The display prints only the prompt before reveal and never includes the hidden word's ID or pronunciation. The user explicitly reveals before grading or asking a question. AI output arrives incrementally as plain text; input remains available for cancel or quit. Cancelling a reply retains the earlier successful exchanges on its card. EOF, quit or interruption cancels temporary work, waits for owned request/child-process cleanup and preserves committed grades. SIGINT exits with status 130. Piped learning requires explicit --batch; ordinary query commands need no input. Empty workloads remain usable for searching or starting another round.

StudySession automatically queues this round’s unique uncached words using the configured concurrency limit, which defaults to one. The terminal displays loading or fallback state without blocking navigation. Complete validated enrichment refreshes only the current card, respecting hidden answers; raw partial JSON is never printed. The explicit enrich command reuses saved results or completes a missing revealed entry and cannot duplicate a pending request. For cached entries it explains the explicit enrich --force command that confirms regeneration and replacement; reuse never prints a loading state. cancel also stops the remaining automatic preparation queue. Search and other read-only commands never trigger enrichment.

config show displays ordinary saved values; --effective also resolves inherited local provider preferences. config set accepts one or more field/value pairs so API provider and model can change atomically. config unset clears an override. enrichment-concurrency accepts one to eight, defaults to one, and remains editable in automatic provider mode. API keys are never accepted as arguments or read back for display: config key set requires a real terminal and a concealed prompt, saving through the existing Keychain API. Automatic provider mode displays inherited model, effort and executable values; editing those fields requires an explicit provider.

The packaged directory contains bin/language-noob, lib, Resources/Vocabulary and the application LICENSE; move the entire directory together. Dictionary notices remain beside the vocabulary resources. Its libraries use relative runtime locations. Invalid arguments return status 2; operational failures return status 1. JSON goes to stdout; diagnostics go to stderr. Terminal controls from vocabulary or model output are removed before display.

## Dependencies

StudyRuntime, StudyCore, StudyStorage, StudyAssistant, Foundation and Darwin terminal/signal APIs. LanguageNoob and LanguageNoobCLI never import each other.

## Invariants

Ordinary library commands make no model requests, and study remains usable when the selected service is unavailable. Terminal text and input are injectable at the session boundary. Process tests use disposable databases and fake local services, including automatic cache reuse, incremental delivery and a child process that ignores graceful termination. No credential or real model service is needed for tests.
