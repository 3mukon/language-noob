---
id: L-0002
type: lesson
title: Fit the projected paper and note to the window throughout motion
status: active
visibility: public
date: 2026-10-27
summary: Card-width travel can clip papers and attached notes; constrain their projected corners to the available window space.
scope: ["Sources/LanguageNoob/Resources/**", "Tests/LanguageNoobTests/MotionTests.swift", "Tests/ApplicationTests/**"]
tags: []
level: design
occurrences: 1
---

## Symptom

```text
The attached note crosses the right window boundary while dragging.
The lifted paper leaves the left window boundary during navigation.
```

## Root cause

Travel distances were fixed fractions of card width. They did not account for the attached note, the current viewport, or perspective projection. Resting layouts fit the window but intermediate frames did not.

## Why it looked right

Start and settlement pixel comparisons passed. The layer exchange also cleared the stationary papers, but that clearance was achieved partly outside the visible window. Neither check established that every intermediate surface remained visible.

## Fix

Use the same perspective distance for CSS and motion geometry. Project paper and note corners through their actual rotations, scale and depth, then constrain them to the viewport with an eight-pixel surface margin. Fit word-paper translation independently and solve the attached note's local horizontal offset so it can tuck inward at an edge without restricting the entire gesture. Account for the deck's shared lateral shift, and choose a contained clearance pose that retains a visible paper face (L-0005). Both drag directions share a soft travel limit; manual navigation wraps at both ends, including a full rightward pull from the first study card. Reverse departure uses an outward excursion based on the forward visible range before settling into its final stack offset. Retain the resulting paper, note and shadow poses on release, and recompute note containment throughout cancellation instead of interpolating only its endpoints.

Cancellation reaches the exact resting transform before removing its animation effects, with the note and elevation shadow on the same sampled easing curve. This prevents fractional layout coordinates and a residual interpolated 3D scale from changing text rasterization at the final handoff.

WebKit regression tests measure visible surfaces at 121 points per transition for two- and four-card rounds at 700, 820 and 940 pixels. They cover keyboard navigation, long drags in both directions, release and cancellation, and verify that the contained layer exchange remains clear. Equal-pull checks include the first card and validate the native input outlines while the note is tucked inward, waiting for the new outline message to complete its native bridge round trip. Pure geometry checks compare left/right visible excursions. Rendered-image comparisons at minimum and default widths retain the start/settlement continuity checks from L-0001, including long-pull release and narrow-window note restoration.

## Occurrences

- 2026-10-27: A long right drag placed the note roughly 130 pixels beyond the default window edge. The same probe found left-side overflow during normal navigation. Projection-aware containment now keeps the surfaces within the viewport.
