---
id: DOC-mod-studystorage
type: doc
title: StudyStorage module
status: current
visibility: public
date: 2026-10-26
summary: SQLite vocabulary, enrichment, progress, review history, search and statistics.
scope: ["Sources/StudyStorage/**"]
tags: []
---

## Responsibilities

Schema initialization, atomic vocabulary imports, search, enrichment cache, idempotent grading and statistics.

## Not responsible for

Conversation messages and drafts are never accepted. Learning policy belongs to StudyCore; UI and process execution belong to other modules.

## Interface

`StudyStore` takes a database URL and is used from one serial executor. `grade` identifies an atomic scheduling/history transaction by card UUID. Repeating an event for the same word is idempotent; reuse for a different language or word throws `conflictingEvent`. Grading reads only the selected word's progress.

cachedEnrichment distinguishes a persisted AI result from an ordinary source entry, even when the source already has a definition. Its language/id lookup returns the normal merged vocabulary view, preserving the source identity and metadata. cacheEnrichment validates the complete word and existing identity before saving; callers update live state only after this write succeeds.

Bundled dictionary installation uses an additive version-marker table and one immediate transaction for insertion, sample reconciliation and the marker. Existing entries win over the bundle. Unmodified legacy samples migrate to matching dictionary identities only when the target has no progress or enrichment conflict; progress keys, review event history and cached enrichment move together. Edited samples and unmatched samples with saved work remain intact. Unused original samples can be removed. Repeated startup checks the marker before resource decoding, and failed installations leave neither partial vocabulary nor a completed marker.

UI callers use `makeSearchWorker()` and await the `VocabularySearching` interface. `StudySearch` owns a separate actor and connection; neither the UI's connection nor its encoder/decoder crosses executors. Search checks task cancellation before work and through SQLite's progress callback. Cancelling first-use construction rolls back its partial index, and later requests can retry on the same worker. Tests inject the cancellation source at SQLite execution checkpoints and verify rollback independently, without relying on elapsed-time races.

Search keeps a derived `library_search` projection of word, reading, definition and the textual fields of cached enrichment. It never scans serialized JSON or matches property names, IDs or other metadata at query time. Exact words and prefixes use a B-tree before other substring matches; empty searches use difficulty and ID order. Only the bounded, ordered result IDs are decoded into words, within the same read transaction.

The [FTS5 trigram tokenizer](https://www.sqlite.org/fts5.html#the_trigram_tokenizer) finds substrings of at least three Unicode scalars. A second, contentless index supports shorter queries through trigrams of boundary-padded hexadecimal UTF-8 values, storing document membership without positions. Candidate membership alone is insufficient: each candidate must also contain the literal query in an original projected field. This rejects matches across fields, reordered trigrams and byte-boundary coincidences. Single-byte queries enumerate their possible adjacent encoded nibbles and boundaries. Query text is bound as data and quoted for FTS; punctuation never becomes query syntax or wildcard behavior.

Both indexes are persistent, derived data, initialized lazily by the search connection. The first search of an existing large library pays the construction cost in the background; later searches reuse it. SQLite triggers update the projection and both indexes in the vocabulary/enrichment transaction, including writes from an already-open connection. Index storage and import work grow in exchange for avoiding repeated full-library scans. The authoritative schema version remains 1 and existing vocabulary, progress and history stay unchanged.

## Dependencies

StudyCore, Foundation and system SQLite3. It must not depend on StudyAssistant or LanguageNoob.

## Invariants

The composite language/id key isolates languages. Schema version 1 remains readable. Imports preserve progress and invalidate replaced enrichment in the same transaction. Any failed vocabulary or grade write rolls the entire transaction back. Unsupported future schema versions fail without deleting data. No credentials, transcripts or provider session identifiers enter SQLite.
