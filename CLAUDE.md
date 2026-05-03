# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**AGENTS.md is the source of truth** for all agent instructions, issue tracking with bd, quality gates, and session completion protocol. See AGENTS.md.

## Project Overview

This is **beads.el** — an Emacs Lisp client for the Beads (bd) issue tracking system. Issues are stored in `.beads/` (Dolt-backed), all interaction via the `bd` CLI.

## Architecture

```
beads-list.el ──┐
beads-detail.el ┤
beads-form.el  ─┼─→ beads-client.el ──→ beads-backend.el
beads-edit.el  ─┤      (dispatch)          (CLI detection + registry)
  ...          ─┘                                │
                                            ┌─────┴─────┐
                                         beads-backend-bd.el  beads-backend-dolt-sql.el
```

Key modules:
- `beads-client.el`: Public API; all consumers call `beads-client-request`.
- `beads-backend.el`: Backend abstraction, auto-detection per project, executor dispatch.
- `beads-backend-bd.el`: Primary bd backend (full ops).
- `beads-backend-dolt-sql.el`: Optional direct Dolt SQL transport (Tier 1/1.5, read-only accel).
- `beads-core.el`: Shared utilities, header rendering.

**Auto-discovery**: Walks up from `default-directory` for `.beads/`.
**Backend selection**: Per-project cache; `beads-dolt-sql-enabled` opt-in for SQL path.

## Development

**Quality gates** (see AGENTS.md for full table): `make check`, `make lint`, `make test`, `make build`.

**Interactive/manual testing**:
```bash
make interactive   # Starts Emacs with --init-directory=dev (loads dev/init.el)
```
Then `M-x beads-list` or `M-x beads-detail` to exercise.

**Verify CLI connectivity** (from project root):
```bash
bd list --json
bd ready --json
bd stats --json
bd dolt show --json
```

## Session Completion

See AGENTS.md. Requires successful `git push` (after `git pull --rebase`). Use `bd dolt commit` / `bd dolt push` for task graph updates (no legacy `bd sync`).

## Beads Version Compatibility

Tested with **bd 1.0.3**. Run `/beads-compat` (skill) to verify. Version info in `.claude/skills/beads-compat/references/version-info.md`.
