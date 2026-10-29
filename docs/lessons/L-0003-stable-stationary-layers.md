---
id: L-0003
type: lesson
title: Prepare the shared deck layer and keep paper layers stable
status: active
visibility: public
date: 2026-10-27
summary: Preparing or reordering the entire deck at pickup can stall navigation; prepare its shared layer while idle and exchange only the moving paper's layer.
scope: ["Sources/LanguageNoob/Resources/**", "Tests/LanguageNoobTests/MotionTests.swift", "Tests/ApplicationTests/**"]
tags: []
level: design
occurrences: 3
---

## Symptom

```text
A long stack pauses at the beginning of a card transition.
JavaScript setup is brief, but the first rendered frame arrives late.
```

## Root cause

Every navigation reassigned all paper layers from their new logical positions. Even fully covered sheets changed paint-order values. A foreground WebKit probe isolated the long frame to pickup; retaining stationary layer values removed that spike in the same seventy-card fixture. Separating the discrete layer effect from transform animation alone did not remove it.

Introducing shared deck movement exposed a second source of layer work: its first animation promoted the whole stack at pickup. Layout-based movement also produced repeated long frames in a seventy-card fixture. A compositor transform removed those repeated stalls; preparing the shared transform layer while idle moves its initial preparation out of the interaction.

Reading fades exposed the same preparation problem in alpha composition. Animating every background paper promoted many separate surfaces; creating a new background group also rebuilt the whole stack. Reusing the existing deck bounded that work, but a fully opaque resting deck still switched to a new blend path on first zoom. `will-change` alone did not prepare that path.

## Why it looked right

Continuous geometry and matching endpoint pixels establish visual correctness, not rendering cost. Short JavaScript setup also does not account for the subsequent paint and composition work. Measuring only animation cadence without an idle baseline can confuse WebKit's ambient frame cadence with a transition-specific pause.

## Fix

Keep every stationary paper's layer unchanged. At the cleared midpoint, place the one moving paper strictly below the minimum stationary layer for forward navigation or strictly above the maximum for reverse navigation. Preserve that ordering at settlement. Initial loading and structural reconciliation may normalize layers while idle. Keep the exchange discrete and separate from transforms; skip constant opacity effects and unchanged text writes.

The deck owns one persistent compositor layer, with an idle `translate3d(0,0,0)` matching the animated transform and hints for transform and opacity. The hints alone did not eliminate first-use preparation. Shared lateral clearance animates this parent transform instead of layout or all covered children. Its idle preparation and lifetime are explicit presentation design choices; individual stationary paint-order values remain stable.

Reading moves only the active card into a foreground host and fades the existing deck as one surface. Its individual papers remain opaque and continue to cover underlying text. Keep the deck's idle alpha at `0.9999`: the subpixel difference is not a visible fade, but keeps WebKit's blend surface prepared instead of creating it at first zoom. Preserve the active editor's native selection and scrolling through the host move; never clear the document selection merely to enlarge a paper. Closing restores the same card to its logical order.

Pure motion tests traverse decks in both directions, including repeated reversal, and assert strict ordering with no tied layers. WebKit checks assert that stationary layer values survive navigation. The existing boundary and rendered-pixel checks continue to verify clearance, coverage, note timing and start/settlement continuity. Performance investigations compare foreground transitions against idle cadence and record first-frame timing; they do not impose a machine-dependent frame-rate threshold on the test suite.

Reading checks bound the number of animated surfaces independently of deck length, verify opaque background occlusion and original node order, and compare actual pixels at pickup, cleanup and interrupted return. They retain glyph, placeholder, draft, scroll and selection checks. Probe both initial and repeated opening before removing the idle alpha preparation.

## Occurrences

- 2026-10-27: A seventy-card fixture exposed a pickup frame much longer than idle cadence. Changing only the moving layer removed the observed spike without hiding covered papers.
- 2026-10-27: Shared deck movement reintroduced a first-navigation promotion spike. A persistent prepared parent layer and compositor-only movement remove interaction-time layout and layer preparation.
- 2026-10-27: Coordinated reading fades revealed first-use alpha preparation in a seventy-card fixture. Reusing the deck, bounding animated surfaces and keeping its blend path prepared brought initial and repeated zoom frames back near idle cadence. The guardrail remains at the design tier, with explicit layer ownership and reading boundary tests.
