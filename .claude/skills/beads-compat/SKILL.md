---
name: beads-compat
description: Check and update beads main-branch compatibility for beads.el. Use when upgrading beads, checking if the installed bd matches upstream main, or updating compatibility documentation after testing a new upstream commit.
---

# Beads Compatibility

This skill helps track beads CLI version compatibility for beads.el.

## Version Checking

Run `.claude/skills/beads-compat/scripts/check-version.sh` to compare the
installed beads commit against the latest upstream `main` commit.

## Upgrade Workflow

When upstream `main` changes:

1. Run `.agents/setup` to build the latest upstream `main`
2. Run `bd version` and record the commit
3. Review changelog for breaking changes: https://github.com/gastownhall/beads/blob/main/CHANGELOG.md
4. Test beads.el functionality against the new commit
5. Update compatibility notes in `references/version-info.md` when behavior changes

## Breaking Change Patterns

Watch for these in the changelog:
- CLI interface changes (affects `--json` output)
- Field renames in JSON responses
- Command/flag deprecations or removals
- New required fields in requests
- Architecture shifts (e.g., 0.49 → 1.0 Dolt SQL server)

## Major Version Break: 0.49.x → 1.0+

bd 1.0 introduced a fundamental architecture change from per-call SQLite to a
persistent Dolt SQL server. This has significant CLI surface implications:

### Removed Commands (break beads.el code paths)

| Command | Affected beads.el Operation | Status |
|---------|-----------------------------|--------|
| `bd activity` | `activity` | Handled (bdel-a6p) |
| `bd mutations` | `get_mutations` | Handled (bdel-mrb) |
| `bd resolve-conflicts` | `resolve-conflicts` | Handled (bdel-itn) |
| `bd daemon` | N/A (docs only) | Removed — no socket IPC |

### New Commands in 1.0+

| Command | Description |
|---------|-------------|
| `bd batch` | Stdin-driven multi-op transactions (close/update/create/dep) |
| `bd dolt` | Dolt server lifecycle (start/stop/status/show) |
| `bd gate` | Async coordination gates |
| `bd merge-slot` | Serialized conflict resolution gates |
| `bd swarm` | Structured epic management |
| `bd formula` | Workflow formulas |
| `bd mol` | Work templates (molecules) |
| `bd federation` | Peer-to-peer workspace federation |
| `bd ship` | Cross-project capability publishing |
| `bd find-duplicates` | AI/mechanical duplicate detection (complements `bd duplicates`) |

### Changed Behavior

- `bd update/close/delete` accept multiple IDs natively (no separate `_bulk` needed, but `_bulk` ops still work)
- `bd dep tree` adds `--direction` flag (up/down/both); `--max-depth` still works
- `bd dep add` supports `--blocked-by` and `--depends-on` flag aliases
- `bd stats` and `bd status` both work with `--json` (overlapping but different schemas)
- Dolt SQL server auto-starts transparently (no manual daemon needed)

### Verified Working Operations (bd 1.0.3)

list, show, ready, create, update, update_bulk, close, close_bulk, delete,
stats, count, dep_add, dep_remove, dep_tree, label_add, label_remove,
types, config_get, config_set, config_unset, duplicates, duplicate,
comments-add, lint, orphans, stale

## Files to Update

When bumping version:
- `references/version-info.md` - source of truth
- `README.md` - Requirements section
- `AGENTS.md` - compatibility header
