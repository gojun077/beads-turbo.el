---
name: beads-compat
description: Check and update beads version compatibility for beads.el. Use when upgrading beads, checking if installed beads version is compatible, or updating version documentation after testing with a new beads release.
---

# Beads Compatibility

This skill helps track beads CLI version compatibility for beads.el.

## Version Checking

Run `.claude/skills/beads-compat/scripts/check-version.sh` to compare installed beads version against documented compatible version.

## Upgrade Workflow

When upgrading beads:

1. Run `bd --version` to get new version
2. Review changelog for breaking changes: https://github.com/gastownhall/beads/blob/main/CHANGELOG.md
3. Test beads.el functionality against new version
4. Update version in `references/version-info.md`
5. Update version in `README.md` and `AGENTS.md`
6. Create git tag matching beads version (e.g., `1.0.3`) - no `v` prefix

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
| `bd activity` | `activity` | Broken (bdel-a6p) |
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
