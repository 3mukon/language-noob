---
id: DOC-mod-studycore
type: doc
title: StudyCore module
status: current
visibility: public
date: 2026-10-26
summary: Vocabulary validation, SM-2 scheduling, workload selection and round-local card identity.
scope: ["Sources/StudyCore/**"]
tags: []
---

## Responsibilities

Vocabulary validation, SM-2 scheduling, workload selection, card identity and explicit round transitions. Scheduling and round state have no I/O.

## Not responsible for

Persistence and SQL belong to StudyStorage. Processes and conversations belong to StudyAssistant. Session effects belong to StudyRuntime; presentation belongs to the desktop and terminal frontends.

## Interface

`Word` and `VocabularyImport` validate vocabulary. `Scheduler.review` accepts a date and calendar. `Workload.select` chooses due and new words; `cards(shuffle:)` creates review, introduction and recall phases with injectable recall ordering.

Each new round samples unseen words by shuffling the entire eligible pool before applying its quota. Reviews first select the thirty earliest due entries, then shuffle that batch. Introduction order follows the sampled new words, and recall receives a separate shuffle. Selection has an injectable shuffle for deterministic regressions. Navigating an existing round never reshuffles its cards or changes eligibility.

`StudyRound` owns the round ID, current card, pending assessments and grading count. Introduction and browse papers are reading material; only recall, review and retry cards require a grade. `navigate` changes selection within `visibleCards` only. Call `didGrade` after persistence succeeds. `browse` accepts ordered search results and a selected word key; it exposes only those entries, retaining one browse identity per word for the round. The study sequence and position stay separate. `returnToStudy` restores that position. `practice` returns to study and reuses an unfinished assessment and its preceding introduction when appropriate. All existing card identities remain available for temporary conversations. `end` permanently discards both views.

## Dependencies

Foundation only. No dependency on storage, assistant or application modules.

## Invariants

Each encounter has a unique UUID, including repeated words. Missing definitions use a word prompt and still require reveal. Grades are idempotent. Due-review retries precede new-word introduction; a word can receive at most one retry per round. Reading and navigation never mark learning complete or write progress. An explicit zero new-word quota is preserved.

An assessment remembers its preferred prompt direction. Enrichment can supply a Chinese prompt before that card is first visited; once displayed, its direction is fixed for that encounter, so a delayed update never swaps the question and answer underneath the learner. Word updates retain card identities, reveal and grading state.
