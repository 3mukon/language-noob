# AGENTS.md

## Start here

1. Read `docs/INDEX.md` and open documents based on their summaries.
2. Before changing a path, read its module's README and the ADRs and lessons that concern it: check the summaries in `docs/INDEX.md`, then list scopes with `rg -n "^scope:" docs -g '!**/templates/**'` and match the path by directory or extension.
3. The protected files are listed in `docs/architecture.md` (Protected files): propose changes to them to the maintainer, and edit only after they approve.

## Invariants

A summary of `docs/architecture.md`, which wins on conflict; the maintainer updates both together.

1. Code and `docs/` contain only publishable content and never reference deliberation records.
2. Never read, write or print secrets; never read `.env` or other secret files.
3. Commit messages, branch and tag names, PRs and issues give only technical reasons and cite only public IDs (ADR-NNNN, L-NNNN).
4. Write ADRs, lessons and current-state docs from the templates in `docs/templates/`, and update `docs/INDEX.md` in the same change.
5. Each fact lives in one place; when code changes, update the docs that describe it.
6. Run the check command before declaring anything done; never weaken checks or bypass hooks.
7. Never edit a protected file on your own (see Start here): propose the change, and edit only after the maintainer approves it.

## Map

| What | Where |
|---|---|
| Hard base and protected files | `docs/architecture.md` (Protected files) |
| Conventions: documents, tags, commits, checks, agent tools | `docs/conventions.md` |
| Terms | `docs/glossary.md` |
| Decisions, lessons | `docs/adr/`, `docs/lessons/` (each created with its first document) |
| Templates | `docs/templates/` |
| Modules | Module READMEs, listed in `docs/INDEX.md` (Modules); the exemplar is named in `docs/conventions.md` (Exemplars) |

## Commands

- Check, run before calling work done: sh scripts/check.sh
- Test: sh scripts/check.sh (foundation validation, Swift build and application tests on macOS)
- Commit-time, push-time and CI checks: see `docs/conventions.md` (Checks), column When it runs.

## Workflow

- New ADRs, lessons, module READMEs and current-state docs start from the templates in `docs/templates/`; keep required sections and remove template comments.
- Commit message format: see `docs/conventions.md`.
- When the same mistake happens again, update its lesson and move its guardrail up at least one rung; moving it into this file needs the maintainer's approval.
