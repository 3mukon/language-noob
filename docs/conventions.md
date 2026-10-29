---
id: DOC-conventions
type: doc
title: Language Noob conventions
status: current
visibility: public
date: 2026-10-26
summary: Document rules, tags, naming, commit format, checks, agent tools and exemplars
scope: []
tags: []
---

This file is the convention tier and may be adjusted to the project's needs: write an ADR when there is a trade-off, otherwise give the reason in the commit message. The Document core section is the exception: it is part of the hard base, and only the maintainer changes it.

## Document core

| Type | ID | Location | Status |
|---|---|---|---|
| doc | `DOC-<slug>`; module READMEs use `DOC-mod-<module>` | Where readers will look | draft / current / superseded / archived |
| adr | `ADR-NNNN` | `docs/adr/` | proposed / accepted / rejected / superseded / deprecated |
| lesson | `L-NNNN` | `docs/lessons/` | active / superseded / obsolete |

- Core fields: id, type, title, status, visibility, date, summary, scope, tags.
- Required sections are marked in each template in `docs/templates/`.

## Documents

- Frontmatter: one field per line, lists written as `[a, b]`; quote values and list items that YAML would misread, for example `scope: ["**/*.go"]`.
- title states the conclusion or the subject; summary is one sentence that answers the question on its own; scope lists globs of the code paths a document concerns, relative to this repository's root; tags uses only tags registered below.
- New number = the highest number among the `id` fields of existing documents of that type + 1, zero-padded to four digits; file names are `<ID>-<slug>.md`; always reference by ID.
- Start from the template for the type in `docs/templates/` (`adr.md`, `lesson.md`, `doc.md`, and `module-readme.md` for module READMEs) and remove its comments; never remove required sections, and if one does not apply, say why.
- Once accepted, an ADR's body never changes; to change the decision, write a new ADR that supersedes it. When a lesson recurs, increment occurrences and move level up at least one rung (doc → rule → comment → test → lint → hook → design).
- When creating a document or changing its status, title or summary, update `docs/INDEX.md` in the same change.
- Authority: code and contracts > current-state docs > accepted ADRs > lessons > historical records; follow superseded_by to the replacement.

## Tags

| Tag | Meaning |
|---|---|

## Naming

Use readable lowercase kebab-case filenames for documents and scripts. Swift source files use type-oriented names; bundled presentation resources use lowercase kebab-case names.

## Commits

```text
<type>: <what changed, in the imperative mood>

<technical reason: why it changed this way; rejected alternatives when relevant>

Refs: ADR-NNNN, L-NNNN
```

type is one of feat, fix, refactor, docs, test, chore. Technical reasons only; `Refs` lists only public IDs. Branch and tag names follow the same rule.

## Checks

| Check | When it runs | What it covers | How to run it by hand |
|---|---|---|---|
| Foundation | Before done; CI | Document core, required sections, index, shell/Python/JSON validity, generic publishability | `sh scripts/check.sh` |
| Secrets | Local pre-commit, commit-msg and pre-push; CI | Staged changes, message, outgoing history | `bash scripts/scan-secrets.sh staged .`; `bash scripts/scan-secrets.sh history . --all` |
| Publishability and identity | Maintainer's local pre-commit, commit-msg, pre-push | Staged blobs/names, public messages/refs and outgoing snapshots/identities | Run installed hooks; installation is maintainer-managed |
| Agent policy | Before supported tools | Hook bypass, secret paths and protected patch targets | Run `scripts/agent-policy.py` with a hook JSON fixture |
| Application build/tests | Before done; CI | Swift compilation, round transitions, storage rollback, assistant lifetimes, native coordination and WebKit interaction | `sh scripts/check-app.sh` |

Foundation dependencies: Bash, Git and Python 3.9+. Scanner: Gitleaks 8.30.1, pinned in CI. CI includes the foundation checks and macOS application verification; remote execution has not yet been verified. The scanner's own checks cannot be skipped; missing/broken scanners block commits and pushes. The short local check does not scan developer secrets or real user data.

## Agent tools

- Codex reads `AGENTS.md`; `.codex/hooks.json` uses current [official hooks](https://learn.chatgpt.com/docs/hooks). Review and trust it via `/hooks` in a new session. Protected `apply_patch` targets are refused: Codex does not support an approval-producing PreToolUse result. Maintainer edits are required for later protected changes. A command failure is mapped to exit 2; runtime timeout behavior remains an unverified gap. Shell mutation matching is an accident guard, not a sandbox.
- Claude Code imports `AGENTS.md` via `CLAUDE.md`; `.claude/settings.json` asks for protected file edits and denies secret reads. Its hook uses `onFailure: block` (requires 2.1.295+). Syntax follows the [official hooks reference](https://code.claude.com/docs/en/hooks) and [permissions reference](https://code.claude.com/docs/en/permissions). No local Claude executable was available at setup, so runtime prompts are unverified.
- Both tools retain their existing global permissions. Hosted tools and specialized tool paths may bypass local hook coverage; other agents have only the written rules and Git checks until integrated.
- Require CI and secret push protection when the remote is created. CODEOWNERS identifies the maintainer; mandatory owner approval waits until at least two people can approve.

## Exemplars

[StudyCore](../Sources/StudyCore/README.md) is the exemplar: pure learning rules, explicit state transitions, injected dates and deterministic regression tests. Module READMEs are authoritative; entries under `docs/modules/` are navigation pointers.

## Language

All project documentation is written in English, including README files, the glossary, indexes, ADRs, templates, and contributor instructions. Use English titles, summaries, prose, table headings, and template guidance. Preserve schema field names, enum values, required section headings, IDs, paths, commands, and API identifiers. Mandatory template-section comments retain their initial `Required` marker so the document checker can identify required headings.

Product UI and UX copy use Simplified Chinese, including navigation, controls, instructions, and status messages. English and Japanese vocabulary and example sentences retain their original languages. Documentation language does not determine interface language.

Describe this product independently, using its own terminology, behavior, and technical decisions.
