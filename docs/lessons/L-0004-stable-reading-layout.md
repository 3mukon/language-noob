---
id: L-0004
type: lesson
title: Keep one text layout scale throughout reading zoom
status: active
visibility: public
date: 2026-10-27
summary: Switching from a transform to CSS zoom can move system-font text and erase native textarea placeholders even when paper bounds match.
scope: ["Sources/LanguageNoob/Resources/paper-reader.js", "Tests/ApplicationTests/**"]
tags: []
level: design
occurrences: 1
---

## Symptom

```text
The pronunciation and part-of-speech separator jump when reading zoom settles.
The enlarged writing invitation disappears while its underline remains visible.
```

## Root cause

Reading animation ended by replacing a transform scale with CSS zoom. WebKit laid out the system-font pronunciation at different effective font metrics: a sampled pronunciation row became about nine CSS pixels narrower. The same handoff left the native textarea's empty placeholder unpainted, despite its value, placeholder attribute and bounds remaining valid. Typing a draft made the editor paint again, masking the failure in draft-only checks.

## Why it looked right

Whole-paper rectangles matched before and after the handoff, and opening then closing restored the original screenshot. Neither check observed the enlarged text itself. DOM text and accessibility labels also remained present when no placeholder pixels were painted.

## Fix

Use a 2D transform throughout reading and retain the same layout scale during animation, settlement and reversal. No final CSS zoom mutation or forced persistent 3D texture is needed. Keep the native input instance and original inline styles; allow the existing writing-size animation to finish normally.

WebKit tests compare glyph ranges across settlement and closing pickup. Rendered comparisons cover those boundaries as well as restored paper surfaces. Separate pixel checks inspect the editor interior above its underline for both an empty placeholder and a retained draft; a border alone cannot satisfy them.

## Occurrences

- 2026-10-27: Native WebKit captures reproduced both the pronunciation-width change and missing empty placeholder. Removing the layout-scale handoff kept the text geometry and editor paint continuous.
