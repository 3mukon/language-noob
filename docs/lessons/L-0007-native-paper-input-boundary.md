---
id: L-0007
type: lesson
title: Match native window input to the painted paper outlines
status: active
visibility: public
date: 2026-10-27
summary: Transparent pixels still intercept other applications unless native window routing follows the visible paper surfaces.
scope: ["Sources/LanguageNoob/**", "Tests/ApplicationTests/**", "tools/build-app.sh"]
tags: []
level: test
occurrences: 1
---

## Symptom

```text
Clicking transparent space below the papers cannot activate the application underneath.
```

## Root cause

The borderless WebKit window reserves a large rectangle for paper motion. A transparent background and DOM pointer exclusions change its appearance and internal event targets, but do not release native input space to another process.

## Why it looked right

Screenshots show the underlying application through the empty space. Renderer hit tests can also report an empty background correctly while WindowServer still chooses the enclosing native window. Synthetic events addressed directly to an application do not establish which application the system would choose for a physical click.

## Fix

Report visible paper outlines to AppKit and use the public [NSWindow.ignoresMouseEvents](https://developer.apple.com/documentation/appkit/nswindow/ignoresmouseevents) property outside them. Local and global mouse monitors update routing on movement and release; they never alter events delivered to another application. Keep routing unchanged while a button is held, preserving selection and dragging from either side. Include only revealed native controls, and release monitors when the window is closed, hidden or minimized.

Measure four zero-size markers through the browser's transforms and perspective. Prepare markers during card construction and sample only exposed surfaces during motion. Deduplicate messages, stop sampling while idle and change the native routing property only when necessary. Reading, completion, library, resize and replacement update the same boundary. Validate finite, bounded geometry and viewport identity; clear the map when the renderer terminates.

Native tests cover tilted corners, margins, invalid geometry, stale viewports, held-button ownership and monitor lifecycle. Queries to WindowServer with two overlapping windows require paper points to choose the study window and transparent points to choose the window beneath it. Allow ordering and input-shape commits to reach the next run-loop boundary before querying. WebKit checks compare reported outlines against actual transformed bounds through navigation and reading, including a seventy-card round, library and completion. Existing image and gesture regressions retain text selection, typography and motion continuity coverage.

## Occurrences

- 2026-10-27: Transparent space below the cards blocked another application's input area. Native input now follows paper surfaces instead of the entire animation viewport.
