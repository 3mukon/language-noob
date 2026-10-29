---
id: DOC-mod-studyruntime
type: doc
title: StudyRuntime module
status: current
visibility: public
date: 2026-10-28
summary: Shared study sessions, settings, local data locations and bundled dictionary bootstrap.
scope: ["Sources/StudyRuntime/**"]
tags: []
---

## Responsibilities

Compose the learning, storage and assistant modules without a presentation dependency. StudySession owns a temporary round, persistence-before-acknowledgement, card-local conversations and enrichment cancellation. StudySettings owns ordinary preferences and merges edited fields under a process-shared file lock. StudyEnvironment resolves the common application-support location or an explicit directory. BundledVocabulary owns attributed offline resources and delegates atomic installation and legacy migration to StudyStorage.

## Not responsible for

Scheduling and pure round transitions belong to StudyCore; SQL and migration transactions belong to StudyStorage; provider protocols and credentials belong to StudyAssistant. AppKit, WebKit messages, animation timing, terminal parsing and output belong to the frontends.

## Interface

StudySession runs on the main actor and exposes a typed StudyRound snapshot. begin selects the configured language and workload, with injectable time and shuffle for tests. reveal and grade accept only the current card; a failed grade write leaves it ungraded. navigate(to:) lets a presentation acknowledge its selected identity; navigate(offset:) wraps manual movement in either view. advanceAfterGrade follows the sequence and then pending assessments; it returns false when no assessments remain. Frontends choose when to finish or display the result.

browse, returnToStudy and practice preserve round-local identities. question requires a revealed current card and emits request-identified ConversationBook events. enrich reuses persisted results by default; force is reserved for explicit frontend confirmation. Each word has at most one queued or active request, and a validated replacement is committed before notifying the frontend. WordCompletion distinguishes a reused result from a newly saved one. Replacement, finishing and import preparation discard obsolete work. cancelCurrentReply retains earlier successful conversation context while stopping the current request. shutdown awaits cancelled session tasks before terminal process shutdown waits for provider processes. No callback from an ended or replaced round can mutate the current session.

Beginning study queues unique uncached round words in study order, including upcoming reading, recall and review cards. Default concurrency is one; assistant.enrichmentConcurrency sets a shared limit from one to eight for automatic and manual completion. Increasing the limit fills free slots without restarting work; decreasing it lets existing requests finish before starting more. Navigation retains in-flight work. Explicit browsing adds only the selected entry, never the whole result set. Each queued entry rechecks persisted enrichment before making a request, so another client's completed result can be reused.

Complete validated output is cached before updating all matching round cards. No partial JSON enters the display or database. Individual invalid results remain failed without automatic retry; unavailable services, configuration, authentication and rate-limit errors stop pending background attempts. Manual completion can retry, and a forced regeneration failure preserves the previous saved result. Provider configuration changes reset failed attempts; merely adjusting concurrency does not cancel work. Ordinary library panels pause preparation and resume missing round entries when closed. Explicit cancellation stops the round's queue until a manual action, configuration change or a new round. Replacement queues wait for cancelled tasks to settle before using new slots.

preparationState exposes idle, queued, loading, ready and failed states. preparationChanged coalesces changed word keys per actor turn, follows frontend navigation publication and retains round ownership. Persisted cache status determines completion across sessions; source entries that happen to contain definitions are not treated as AI-generated.

StudySettings.save(to:replacing:) compares the caller's previous snapshot with its edits, reloads the latest file under a sidecar lock and merges changed top-level and assistant fields. Unknown fields and unrelated concurrent edits survive. The merged configuration is validated before atomic replacement. GUI and CLI use the same JSON shape, database location and Keychain account rules; live rounds remain process-local.

Both clients install the same versioned English and Japanese resources. An installed marker skips parsing. The conversion tool consumes original local source files and records provenance; sample resources exist only for conservative migration. Native packaging places Vocabulary beside the paper resources; terminal packaging carries the same directory with its libraries. Resources resolve from the loaded executable, following symlinks, so invoking the terminal command through PATH does not depend on the working directory. Swift Package Manager uses the runtime's resource bundle.

## Dependencies

StudyCore, StudyStorage, StudyAssistant, Foundation and Darwin file locking. No AppKit, WebKit or frontend dependency. Both frontends depend on this module.

## Invariants

Each selected language has its own workload. A round's random order remains fixed after creation. Reading and manual navigation never write progress. Persistence succeeds before in-memory grading; temporary conversation data never enters settings or SQLite. Separate processes share saved state but never share a live round.
