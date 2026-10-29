---
id: L-0006
type: lesson
title: Reserve native text regions before recognizing paper gestures
status: active
visibility: public
date: 2026-10-27
summary: Native selection owns inline text fragments from pointer-down; blank layout space remains available for paper gestures.
scope: ["Sources/LanguageNoob/Resources/**", "Tests/ApplicationTests/**"]
tags: []
level: design
occurrences: 2
---

## Symptom

```text
Double-clicking text also enlarges the paper.
Dragging across vocabulary moves the card instead of selecting the text.
Document select-all includes the covered cards and their answers.
The text cursor and selection region extend far into empty row space.
```

## Root cause

The word paper started horizontal gestures anywhere except controls, examples and the attached note. Its double-click handler excluded editing controls but still accepted example and reply text. Most vocabulary inherited unselectable styling from the page. Separate exclusion lists gave the same content contradictory behavior across gestures, while unmodified arrow handlers also ignored an existing document selection.

Native WebKit select-all additionally traversed covered, inert cards. CSS selection styling and accessibility exclusions did not constrain the range created by the Edit menu.

Unprefixed selection declarations also failed to make blank paper and the header unselectable in the hosted WebKit version. Header dragging could fall through to selection, and its asynchronous native request relied on `NSApp.currentEvent` still being the original mouse-down.

The first shared marker also covered full-width block and flex containers. Their hit rectangles included blank row tails and paragraph space, so the exclusion predicate protected much more than text. Shrinking a block to its longest line would still reserve unused space beside shorter wrapped lines.

## Why it looked right

Editable fields and vertical message scrolling already worked, and blank-paper gesture tests passed. Those checks did not exercise reading or copying ordinary vocabulary and replies. Raising a drag threshold cannot resolve the ambiguity: selecting a sentence also involves substantial horizontal movement.

Dispatching synthetic events directly to marked elements verifies handler routing but cannot establish that the browser chooses the right element at a real pointer position.

## Fix

Mark selectable content once with inline `ln-selectable` spans, using them for both native text styling and the common gesture exclusion predicate in `paper.js`. Keep block layout, flex spacing, separator padding and paragraph margins outside those spans. The browser's inline fragments then define the actual hit area on every wrapped line, without custom pointer geometry or layout reads during movement. Content reconciliation and streamed replies update the span's text rather than replacing its container. This strengthens the existing design-tier guardrail by making text-only hit regions part of content construction.

Decide ownership at pointer-down before pointer capture; a selection that crosses onto blank paper remains a native gesture. Double-click text selects text, while blank paper toggles reading. Reserve the header for native window movement. Keep modifiers and existing selections out of arrow navigation without clearing or recreating native selections.

Route the native select-all command to the renderer only when its view owns focus. Preserve editor selection through the editor's native `select()` operation; for document content, create one range bounded by the active paper's visible text regions. Resolve the surface from the last pointer region or the enlarged paper, never from the whole document. Library results remain within the library, and AppKit dialogs keep their original responder action.

Restore the menu item's standard responder-chain action when the study window resigns key status, then restore scoped handling when it becomes key again. A permanent application target is disabled by AppKit during modal editing even if its handler contains a native fallback. Verify the actual modal menu and field selection, not only the renderer callback.

Declare both prefixed and standard selection styles, and test both the selectable text and the unselectable surroundings. Prevent selection at header pointer-down. The native window retains that mouse-down event until release or consumption so a delayed bridge callback can start window dragging without depending on the current event; a released pointer cannot start a stale drag.

WebKit interaction checks cover vocabulary, replies and the editor at ordinary and enlarged sizes, crossing from text onto blank paper, preserved ranges, modified gestures, arrow navigation, the header boundary and scoped select-all from both menu commands and keyboard events. Existing tests retain blank-paper dragging, reading transitions and keyboard restoration. Real mouse and edit-menu checks remain necessary because synthetic DOM events do not perform WebKit's native selection default actions. Read WebKit's prefixed CSSOM alias when the standard selection-style property is unavailable.

Hit-region checks use actual `elementFromPoint` results at text and whitespace positions in normal and minimum-width windows, before and after reading zoom. They cover row tails, pronunciation separators, wrapped definitions/examples and short reply lines, then route zoom and dragging through those resolved targets. Rendered-image checks retain the existing typography and motion continuity coverage.

## Occurrences

- 2026-10-27: Ordinary vocabulary, example and reply selection competed with reading zoom and paper navigation; shared region ownership separates the actions while preserving the existing presentation.
- 2026-10-27: A full-width pronunciation row retained the text cursor far beyond its part of speech. Inline content fragments now define the native selection boundary, with real hit-testing regressions for text and whitespace on both paper types.
