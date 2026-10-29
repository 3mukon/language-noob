# Index

Read this index first, then open documents by their summaries. Keep one row per document and place closed documents at the end of their section. Add or remove rows, not columns. Update the index whenever a document is created or its status, title, or summary changes.

Current-state documents and the authoritative module READMEs describe the implemented product. Accepted ADRs retain their decision-time context: ADR-0003 extends ADR-0002's assistant integration, and ADR-0004 extends its client and module composition. Read those extensions together instead of treating the earlier proposal wording as the current feature list.

## Foundation

| ID | Status | Title | Summary |
|---|---|---|---|
| [DOC-glossary](glossary.md) | current | Vocabulary and interaction terms | Define word cards, word pages, follow-up notes, and temporary conversation context. |
| [DOC-conventions](conventions.md) | current | Language Noob conventions | Document rules, tags, naming, commit format, checks, agent tools and exemplars |
| [DOC-architecture](architecture.md) | current | Language Noob hard base | The macOS desktop and terminal clients share study behavior, local data and verified guardrails. |

## Current-state docs

| ID | Status | Title | Summary |
|---|---|---|---|

## Modules

| ID | Status | Title | Summary |
|---|---|---|---|
| [DOC-mod-studycore](modules/StudyCore.md) | current | StudyCore module | Vocabulary validation, SM-2 scheduling, workload selection and round-local card identity. |
| [DOC-mod-studystorage](modules/StudyStorage.md) | current | StudyStorage module | SQLite vocabulary, enrichment, progress, review history, search and statistics. |
| [DOC-mod-studyassistant](modules/StudyAssistant.md) | current | StudyAssistant module | Streaming CLI and API adapters with Keychain credentials and temporary card-isolated conversations. |
| [DOC-mod-studyruntime](modules/StudyRuntime.md) | current | StudyRuntime module | Shared study sessions, settings, local data locations and bundled dictionary bootstrap. |
| [DOC-mod-languagenoobcli](modules/LanguageNoobCLI.md) | current | LanguageNoobCLI module | Chinese terminal commands and interactive study over the shared runtime. |
| [DOC-mod-languagenoob](modules/LanguageNoob.md) | current | LanguageNoob module | AppKit window, bundled WebKit presentation and the typed message bridge. |

## Architecture decisions

| ID | Status | Title | Summary |
|---|---|---|---|
| [ADR-0004](adr/ADR-0004-shared-desktop-and-terminal-sessions.md) | accepted | Share session orchestration between desktop and terminal frontends | Add an optional macOS terminal client over shared session services and existing domain modules. |
| [ADR-0003](adr/ADR-0003-key-authenticated-assistant-apis.md) | accepted | Add explicit streaming API connections with Keychain credentials | Extend local assistant adapters with Messages and Responses HTTP streams while keeping credentials out of settings and card context. |
| [ADR-0001](adr/ADR-0001-word-card-interaction.md) | accepted | Use word cards for macOS study and continuous follow-up questions | Fixed-size stacked word cards with attached follow-up notes and conversation context limited to the current study card. |
| [ADR-0002](adr/ADR-0002-macos-application-stack.md) | accepted | Host the paper interface in a native macOS window with a Swift learning core | AppKit and WebKit host the approved paper interface, with Swift modules for learning, storage, and local AI adapters. |

## Lessons

| ID | Status | Level | Title | Summary |
|---|---|---|---|---|
| [L-0007](lessons/L-0007-native-paper-input-boundary.md) | active | test | Match native window input to the painted paper outlines | Transparent pixels still intercept other applications unless native window routing follows the visible paper surfaces. |
| [L-0006](lessons/L-0006-text-gesture-ownership.md) | active | design | Reserve native text regions before recognizing paper gestures | Native selection owns inline text fragments from pointer-down; blank layout space remains available for paper gestures. |
| [L-0001](lessons/L-0001-continuous-paper-handoff.md) | active | design | Keep every paper surface continuous through motion | Geometry, paint order, paper edges, shadows and attached notes must remain continuous throughout motion, with no stationary shadow left by a lifted paper. |
| [L-0002](lessons/L-0002-contain-projected-paper-motion.md) | active | design | Fit the projected paper and note to the window throughout motion | Card-width travel can clip papers and attached notes; constrain their projected corners to the available window space. |
| [L-0003](lessons/L-0003-stable-stationary-layers.md) | active | design | Prepare the shared deck layer and keep paper layers stable | Preparing or reordering the entire deck at pickup can stall navigation; prepare its shared layer while idle and exchange only the moving paper's layer. |
| [L-0004](lessons/L-0004-stable-reading-layout.md) | active | design | Keep one text layout scale throughout reading zoom | Switching from a transform to CSS zoom can move system-font text and erase native textarea placeholders even when paper bounds match. |
| [L-0005](lessons/L-0005-visible-turning-face.md) | active | test | Keep a visible paper face at the layer exchange | A contained edge-on turn still produces an uncomfortable aliased slit; make room for a partial turn while preserving opaque surfaces and layer clearance. |
