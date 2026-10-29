---
id: ADR-0001
type: adr
title: Use word cards for macOS study and continuous follow-up questions
status: accepted
visibility: public
date: 2026-10-26
summary: Fixed-size stacked word cards with attached follow-up notes and conversation context limited to the current study card.
scope: []
tags: []
related: []
supersedes: []
superseded_by:
---

## Context

On 2026-10-26, the maintainer requested a graphical interface, official support for macOS only, lightweight sticky-note windows, and continuous follow-up questions on the same word page. Everyday study and follow-up questions take place through the graphical interface.

## Options

| Option | Trade-off |
|---|---|
| Retain a terminal interface | Incompatible with the graphical interface requirement |
| Browser-style tabs | Incompatible with the confirmed sticky-note appearance |
| Sticky-note word cards | Preserves a lightweight window experience and keeps each word beside its follow-up questions |

## Decision

Propose a stack of paper-style word cards. Swipe left for the next card and right for the previous card, with equivalent keyboard and native-menu controls. Keep the paper surface free of persistent previous/next buttons so the stack remains the primary interaction.

Each paper card contains an actual vocabulary entry, including the cards behind the active one. Word cards have fixed dimensions during ordinary study. Follow-up questions appear in a smaller, horizontally proportioned note attached at the lower right, with a fixed size and independently scrolling messages and input. Preserve the right-side placement at ordinary desktop preview widths. A new note has an empty conversation area with a short invitation in the input field; it contains no introductory message or suggested questions. Right-align the invitation and composed text above a writing line, without a rectangular field frame. Retain a native input and emphasize its underline on focus. The paper can be tilted, but the text, input, and controls remain upright for reading and editing. Conversation content never enlarges the word card, and asking questions does not require expansion. The attached note remains part of the current word page.

Offer optional reading zoom by double-clicking an individual word paper or attached note, with an equivalent accessible control. Omit zoom and restore icons; reveal text controls only on keyboard focus. Double-click again, press Escape, or use the restore control to return to the stack. Enlarge only the selected paper and retain the same content and input instance, including its draft, scroll position, and active reply. Preserve native double-click selection inside editable fields. Keep background navigation inactive during focused reading, restore keyboard focus on return, and fit zoom to the available width. Skip zoom transitions under reduced motion.

Present the note as an exchange of letters without a visible panel title, using legible serif typography. The learner's messages align to the right and progressively written replies align to the left. Use plain text and spacing without visible speaker labels, while retaining accessible role descriptions. Enter submits and Shift+Enter inserts a newline; composition input must not submit. New text follows the bottom only while the learner is already reading there. Allow drafting and navigation during a reply, and answer additional submissions in order for that card. Respect reduced motion by presenting complete replies directly, and announce completed replies rather than every text increment to assistive technology.

Switch cards along a continuous pickup, move-under, and set-down trajectory; reverse navigation draws a card from below onto the top. The follow-up note travels with its word card, and each card keeps its content identity. Use direct switching when the system requests reduced motion.

Each study card is an independent instance for explanations and follow-up questions; context must not be reused solely by vocabulary-entry ID. Returning to the same card within a round continues its temporary conversation. The same word appearing as a new study card starts fresh context. End-of-session cleanup removes temporary questions and answers without persisting or restoring them in the next round. Define window, study-logic, and model-transport modules and interfaces after choosing the stack.

## Consequences

The first interaction implementation must verify context isolation between card instances, continuous follow-up on the same page, and context disposal. AI adapters must observe the same lifetime and avoid accidentally reusing a previous round's session. Storage for static vocabulary and learning progress is designed separately; nonpersistent conversations do not imply that all learning data is transient. Multiple independent windows and always-on-top behavior remain undecided. This decision does not select SwiftUI, AppKit, or another framework.

Streaming output and queued requests belong to the originating card instance. Changing the visible card cannot redirect an in-progress reply. Ending the round cancels pending output and queued requests before discarding messages and drafts. The interaction prototype uses sample replies; transport integration and error handling remain implementation work.

## Verification

This is an architecture proposal; there is no product code to verify yet. For the first implementation, use a controlled model substitute to verify that switching cards does not mix conversations, returning within a round allows continued follow-up, and studying the same word again or restarting does not restore old questions and answers. Verify in the macOS interface that horizontal navigation does not interfere with text input.

Interaction acceptance also covers long conversations without card resizing, vertical scrolling inside the note without navigation, real content on front and rear cards, and continuous release motion without layer flashes. Rapid navigation must not lose drafts or attach a response to the wrong card. Note text and controls must remain upright at rest and fit within the paper at supported widths and tilt angles. Measure animation behavior in an actual macOS window; exploratory browser measurements cannot replace application acceptance.

Verify incremental delivery, ordered follow-ups submitted during an active reply, manual scroll retention, reduced-motion completion, and cancellation during a partial reply. A new round must remain empty after old scheduled output would otherwise have arrived. Check Chinese input composition and Shift+Enter independently from submission.

Verify reading zoom on both paper types, double-click and keyboard restoration, editable-field selection, focus containment, and draft and reply retention. Rear cards must retain their dimensions. Check narrow widths and clean restoration before ending a round or changing layout.

## Revisit when

Reassess through a new requirement if the maintainer changes the window form or cross-word interaction. Choosing a stack does not by itself change the confirmed interaction direction.
