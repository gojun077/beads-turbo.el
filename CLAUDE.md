# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**Note**: This project uses [bd (beads)](https://github.com/steveyegge/beads)
for issue tracking. Use `bd` commands instead of markdown TODOs.
See AGENTS.md for workflow details.

## Project Overview

This is **beads.el** - an Emacs Lisp client for the Beads issue tracking system. Beads is a Git-backed, AI-native issue tracker that stores data in `.beads/` and communicates via CLI.

The canonical upstream is https://codeberg.org/ctietze/beads.el

## Beads Version Compatibility

Tested with **beads CLI 0.49.1**. Version info maintained in `.claude/skills/beads-compat/references/version-info.md`.

- Changelog: https://github.com/steveyegge/beads/blob/main/CHANGELOG.md
- Run `/beads-compat` to check installed version
- beads.el versioning mirrors beads CLI version (e.g., beads.el 0.44.0 = tested with beads 0.44.0)
- Git tags use bare version numbers without `v` prefix (e.g., `0.49.0` not `v0.49.0`)

## Architecture

```
beads-list.el ──┐
beads-detail.el ┤
beads-form.el  ─┼─→ beads-client.el ──→ beads-backend.el
beads-edit.el  ─┤      (dispatch)          (CLI detection)
  ...          ─┘                                │
                                           ┌─────┴─────┐
                                        beads-backend-bd.el  beads-backend-br.el
```

Key modules:
- **`beads-client.el`**: Entry point for all operations. Dispatches requests via CLI. All consumer modules call `beads-client-request`.
- **`beads-backend.el`**: Backend abstraction. Registry, per-project auto-detection, CLI execution. `executable-find` and `call-process` for beads CLI live here only.
- **`beads-backend-bd.el`**: bd backend — full operation set.
- **`beads-backend-br.el`**: br backend — CLI only, reduced operation set, removable.
- **`beads-core.el`**: Shared utilities (header rendering, CLI wrappers for report views).

Key concepts:
- **Auto-discovery**: Walk up from `default-directory` looking for `.beads/beads.db`
- **Backend detection**: Per-project, cached. `beads-cli-program` defcustom overrides (safe for `.dir-locals.el`).
- **CLI communication**: All operations use `bd <command> --json` via `call-process`

## Protocol Reference

See `docs/beads-client-howto.md` for the complete protocol specification including:
- Request/response structures
- All operations (list, show, ready, create, update, close, dep_add, etc.)
- Issue object schema
- Example implementations in multiple languages including Emacs Lisp

## Development

**Tools**: Go, Python (managed by mise, see `mise.toml`)

**Quality checks** (run before committing):
```bash
mise run check   # Run lint + test
mise run lint    # Check syntax/parens, byte-compile
mise run test    # Run ERT tests
mise run build   # Byte-compile all .el files
```

**Interactive testing**:
```bash
mise run interactive   # Launch Emacs with beads.el loaded
```
This starts Emacs with `--init-directory=dev`, loading dev/init.el which sets up load-path and requires beads modules. Run `M-x beads-list` to test.

**Testing the CLI connection**:
```bash
bd list --json
bd ready --json
bd create "Title" --json
```

## Issue Tracking

This project uses **bd (beads)** for issue tracking. Do NOT use markdown TODOs.

```bash
bd ready              # Find available work
bd update <id> --status in_progress  # Claim work
bd close <id>         # Complete work
bd sync               # Sync with git
```

## Commit Strategy

**Atomic commits as you go** - Create logical commits during development, not after:

1. **Tests must pass** - Never commit breaking changes. Run `mise run check` before every commit.
2. **Fix code, not tests** - If tests fail, fix the implementation first. Only modify tests if they are genuinely wrong.
3. **Commit at logical points**:
   - When a beads task is complete
   - When a meaningful milestone is reached during an in-progress task
   - After fixing a bug or completing a feature unit
4. **No reconstructed history** - Don't batch changes then create artificial commits from a working state. Commits must represent actual development order so checking out any commit yields a working state.
5. **Branches and rollbacks are fine** - Use feature branches, rollback broken changes, experiment freely.

## Documentation

User-facing feature changes must be documented in README.md:
- Add new commands to the Usage section
- Add keybinding tables for new modes
- Add customization options with examples

For visual changes (new UI, modified display):
1. Create a beads task to capture an appropriate screenshot
2. Add an HTML comment in README.md where the screenshot should go:
   ```markdown
   <!-- TODO: Add screenshot for X (see bdel-xxx) -->
   ```

## Session Completion

Work is NOT complete until `git push` succeeds:
```bash
git pull --rebase && bd sync && git push
```
