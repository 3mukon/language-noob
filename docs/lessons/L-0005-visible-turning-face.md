---
id: L-0005
type: lesson
title: Keep a visible paper face at the layer exchange
status: active
visibility: public
date: 2026-10-27
summary: A contained edge-on turn still produces an uncomfortable aliased slit; make room for a partial turn while preserving opaque surfaces and layer clearance.
scope: ["Sources/LanguageNoob/Resources/paper-motion.js", "Sources/LanguageNoob/Resources/paper.js", "Tests/LanguageNoobTests/MotionTests.swift", "Tests/ApplicationTests/**"]
tags: []
level: test
occurrences: 1
---

## Symptom

```text
A narrow, broken-looking vertical slit appears beside the stack during navigation.
```

## Root cause

The clearance pose aimed the paper exactly along the perspective camera's view. Its projected width approached zero at the layer exchange. The paper remained opaque and inside the window, but antialiasing reduced its surface, border and text to a distracting thin line.

## Why it looked right

Endpoint screenshots, layer clearance and viewport containment all passed. None required a visible paper face between those endpoints. WebKit's snapshot API can also flatten perspective in intermediate frames, so native window inspection is needed to assess the actual projected appearance.

## Fix

Limit the turn and calculate a shared lateral movement for the deck that clears space for the moving paper. Covered sheets move with that one parent instead of each receiving new layers. Retain each paper's content, opaque surface, continuous shadow and strict layer exchange. Include the parent offset in containment calculations and let the incoming note return after the lateral movement settles.

Pure geometry and actual WebKit bounds checks require each paper's projected face to remain wider than thirty percent of its resting width. The existing 121-frame checks cover minimum and normal window sizes, both directions, drags and cancellation. Native inspection covers the intermediate perspective appearance; endpoint pixel checks continue to detect layer and settlement jumps.

## Occurrences

- 2026-10-27: A clearance pose that solved clipping collapsed the paper to a slit. A partial turn with shared deck clearance retains a visible face without changing stationary paint order.
