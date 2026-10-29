---
id: L-0001
type: lesson
title: Keep every paper surface continuous through motion
status: active
visibility: public
date: 2026-10-26
summary: Geometry, paint order, paper edges, shadows and attached notes must remain continuous throughout motion, with no stationary shadow left by a lifted paper.
scope: ["Sources/LanguageNoob/Resources/**", "Tests/LanguageNoobTests/MotionTests.swift", "Tests/ApplicationTests/**"]
tags: []
level: design
occurrences: 5
---

## Symptom

```text
The paper text or attached note jumps when navigation ends.
A stationary rectangular ghost remains behind a paper during its answer turn.
```

## Root cause

The outgoing path originally ended at the third stack pose, even when a two-card round put it in the second position. Layer changes could happen while papers overlapped, exposing different text instantly. The outgoing note stayed visible until its parent was hidden. Animation completion callbacks also lacked consistent round ownership.

Matching rectangles alone still left three paint discontinuities: hiding an exactly covered sheet changed its overlapping shadow and antialiased edge; reverse pickup could tie the incoming sheet's layer with a stationary sheet and let DOM order expose another word; and gesture release reset the existing lift shadow to zero. All affect actual pixels without necessarily changing a paper's bounding rectangle.

Answer turning retained 35 percent of the full-size contact shadow even at full lift, while also drawing a moving shadow. That stationary footprint looked like a second translucent sheet. The airborne shadow also used an outer box shadow with an empty center, leaving another sharp rectangular cutout when the paper no longer covered it. Its image fixture mutated an already-rendered card object in place, unlike a newly decoded native snapshot; the renderer therefore saw no reveal change and the endpoint comparisons never entered the turn.

## Why it looked right

Static screenshots after navigation and syntax/build checks showed the correct final card. Geometry checks also passed because equal rectangles do not imply equal paint order or rasterization. Testing only near the start of the deck missed the reverse-pickup layer tie near its tail.

Matching endpoints cannot exclude an intermediate ghost. An image check must also prove that its transition actually started; two identical static frames are not evidence of animation continuity.

## Fix

Model geometry, layer, ambient shadow, lift shadow and attached-note opacity as separate parts of one continuous frame. Covered sheets retain their actual content and stay painted at coincident poses; navigation never toggles their display. Only the first three sheets cast ambient shadows at rest, and those shadows fade independently when sheets enter or leave coverage. Gesture release starts with the held lift shadow. Reverse pickup stays strictly below every stationary sheet until the clearance apex. Stationary layer values remain stable; only the moving sheet exchanges its layer, strictly below or above their range (L-0003). A generation token prevents cancelled animations from settling into replacement state. Reading fades the background deck as a group while its papers remain opaque, so covered text cannot accumulate through individual translucent sheets; closing reading restores the original painted stack.

Pure geometry tests cover both directions, endpoints, shadow ownership, note timing and trajectory continuity. WebKit tests inspect pickup, clearance and note return. Rendered-image tests compare sampled RGBA pixels immediately before/after animation start and settlement at both ends of the deck, including a seventy-card batch. They also compare gesture-release, cancellation and reading-restoration frames. Failures save the actual before/after PNGs to a temporary directory. Existing interaction tests cover round replacement, retained drafts, reading zoom and reduced motion.

Answer turns transfer shadow ownership completely: the resting contact shadow reaches zero at full lift, the moving footprint remains, and landing restores the contact shadow continuously. The airborne footprint is a filled, softly blurred surface rather than an empty box-shadow outline; only its transform and opacity animate. Mid-turn image comparisons temporarily hide only the contact surface and require no pixel change at ordinary and enlarged sizes. A shadow-only sample also requires paint at the footprint center, rejecting a hollow outline. Fixtures supply a new card value and require a live turn before sampling. Computed-opacity and interruption checks cover the same ownership and removal of temporary surfaces; native inspection checks the projected appearance. This strengthens the existing design-level guardrail rather than adding another independent shadow layer.

## Occurrences

- 2026-10-26: Removing paper transparency did not resolve layer and content discontinuities.
- 2026-10-26: Adjusting note timing and handoff percentages left visible jumps.
- 2026-10-26: Replaced the shared three-card assumption with tested geometry and round-scoped completion.
- 2026-10-26: Pixel comparisons exposed reverse-layer ties, shadow discontinuities and antialiased-edge changes missed by rectangle checks. Continuous paint surfaces now enforce the invariant by design.
- 2026-10-27: A residual contact-shadow floor left a ghost during answer turning. Complete shadow transfer and intermediate image checks now cover the ordinary and enlarged turn; the fixture must actually enter its animation.
