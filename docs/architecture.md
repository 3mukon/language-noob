---
id: DOC-architecture
type: doc
title: Language Noob hard base
status: current
visibility: public
date: 2026-10-26
summary: The macOS desktop and terminal clients share study behavior, local data and verified guardrails.
scope: []
tags: []
framework: project-foundation@0.1.0
---

This file is part of the hard base. The maintainer approves changes to it and the protected files below; an agent proposes changes with their reason and impact.

## Plane

Code and `docs/` contain only publishable technical content. They never refer to private records, locations, or identities other than a confirmed public commit identity.

## Layers

| Layer | Location and state |
|---|---|
| Code | `Sources/StudyCore`, `Sources/StudyStorage`, `Sources/StudyAssistant`, `Sources/StudyRuntime`, `Sources/LanguageNoob` and `Sources/LanguageNoobCLI` |
| Verification | `sh scripts/check.sh`; Swift module compilation, native and terminal command/session tests, JavaScript syntax validation and local application/CLI packaging |
| Knowledge | `docs/`, stable IDs and templates |
| Agent access | `AGENTS.md`, imported by `CLAUDE.md` |
| Governance | Maintainer's local commit/push hooks, `scripts/`, agent settings, CI configuration |

## Module rules

Slice by business capability. Each module owns a README stating responsibilities, non-responsibilities, interface, allowed dependencies, and data ownership. Keep dependencies explicit and acyclic. The Swift package targets macOS 14 or later. StudyCore, StudyStorage and StudyAssistant supply domain capabilities; StudyRuntime coordinates shared sessions and settings; LanguageNoob and LanguageNoobCLI provide independent desktop and terminal frontends. Do not create untested placeholder application code. ADR-0001, ADR-0002 and ADR-0004 record the accepted interaction and stack boundaries.

## Invariants

| # | Rule | Rationale | Check |
|---|---|---|---|
| 1 | Product files contain publishable content only and no private references | Structural separation prevents context leaking into releases | Local publishability check; generic CI check |
| 2 | Secrets never enter a repository or agent context | Files and model context can leave the machine | Gitleaks; secret-file guards; environment files ignored |
| 3 | Outward text gives technical reasons and public IDs only | Messages and refs are published with code | Commit-message, outgoing-content and ref checks; outward-text guard where needed |
| 4 | Knowledge uses templates, stable IDs, core fields and required sections | Knowledge must survive session/tool changes | Metadata, required-section and index checks |
| 5 | Each fact has one authority; current-state docs change with code | Stale documentation causes incorrect changes | Review; document index consistency |
| 6 | Done means runnable checks passed; checks and hooks are never weakened | Verification must stay independent of implementation | Check command, local bypass guard; CI after remote setup |
| 7 | Only the maintainer changes the hard base and guardrails | An agent cannot rewrite its own constraints | Protected-file rules; agent guards; server review when available |
| 8 | macOS is the only officially supported product platform | Keeps the product aligned with its intended desktop environment | `tools/build-app.sh` rejects non-macOS hosts and uses a macOS 14 deployment target |
| 9 | End-user study and follow-up are available through the graphical application and an optional terminal client; both reuse the same learning and persistence rules | Both interfaces must preserve one study contract | Native launch/resources and CLI command/session checks |
| 10 | Desktop word cards use a lightweight sticky-note window presentation | The desktop remains a compact companion | Native interaction and rendered-motion checks |
| 11 | Follow-ups remain scoped to the current card and temporary round in either frontend | Asking a question must not lose the word being studied or mix card contexts | Shared-session tests and the temporary `ConversationBook` lifecycle |

Rules 8–11 reflect the desktop direction confirmed on 2026-10-26 and its terminal extension confirmed on 2026-10-28. The accepted architecture decisions and product requirement define the current model transport, persistence, language coverage, review algorithm, system version and deferred distribution work.

## Protected files

- `docs/architecture.md` (this list included)
- The `Document core` section of `docs/conventions.md` (section-level protection is a rule, not a file guard)
- `AGENTS.md`, `CLAUDE.md`
- `LICENSE` when created
- `.github/workflows/`, `.github/CODEOWNERS`
- `.gitleaks.toml`, `.gitleaksignore` if created
- `.codex/`, `.claude/`
- `scripts/` (all current scripts are verification or guardrail implementation)
- Installed local Git hook wrappers

## Change rules

| Tier | Owner |
|---|---|
| Hard base: protected files, their lists, document core and guardrails | Maintainer approves; agents propose |
| Conventions outside document core, templates outside required fields/sections, directory details | Agents may adjust; write an ADR for a trade-off |
| Wording, naming, non-guardrail scripts | Agents may adjust |

A plane/reference-boundary change, existing-module split/merge/removal, responsibility/dependency/data-ownership/public-contract change, invariant change, or publication-boundary change is major. It needs a changed requirement and maintainer confirmation. Adding a module is a convention change. New ADRs remain proposed until their text is reviewed.
