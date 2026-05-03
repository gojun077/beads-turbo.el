# Beads Version Compatibility

Tested CLI version: 1.0.3
Minimum DB version: 0.35.0

## Changelog

https://github.com/gastownhall/beads/blob/main/CHANGELOG.md

## Version History

| beads.el | beads CLI | Notes |
|----------|-----------|-------|
| 1.0.3    | 1.0.3     | Dolt SQL backend, bd batch, multi-ID update/close/delete, removed daemon/mutations/resolve-conflicts |
| 0.49.1   | 0.49.1    | --append-notes, export filters, activity --details |
| 0.49.0   | 0.49.0    | bd children, bd rename, bd types, Dolt backend |
| 0.47.1   | 0.47.1    | Pull-first sync, `--ready` flag, dry-run create |
| 0.46.0   | 0.46.0    | Custom types, rig type, hierarchy view, dependencies in detail |
| 0.44.0   | 0.44.0    | Initial version tracking |

## New Features by Version

### v1.0.3
- Persistent Dolt SQL server backend (auto-started, no manual daemon)
- `bd batch` for stdin-driven multi-op transactions (close/update/create/dep)
- `bd update/close/delete` accept multiple IDs natively
- `bd dolt` subcommand tree (start/stop/status/show)
- `bd dep tree --direction` (up/down/both)
- `bd dep add --blocked-by` and `--depends-on` flag aliases
- `bd find-duplicates` command (AI/mechanical)
- `bd gate`, `bd merge-slot`, `bd swarm`, `bd formula`, `bd mol`, `bd federation`, `bd ship`
- `bd stats` and `bd status` both return `--json` output (different schemas)
- Removed: `bd daemon`, `bd mutations`, `bd resolve-conflicts`, `bd activity`

### v0.49.1
- `bd update --append-notes` flag for additive note editing
- `bd update --ephemeral` and `--persistent` flags for phase control
- `bd activity --details/-d` for comprehensive issue information
- `bd export --id` and `--parent` filters for targeted exports
- `bd show --id` flag for IDs resembling command flags
- Dolt backend server mode with multi-client access
- Doctor `--server` flag for Dolt server health checks

### v0.49.0
- `bd children <id>` command to list child issues
- `bd rename <old-id> <new-id>` command to rename issues
- `bd types` command to list valid issue types
- `bd view` alias for `bd show`
- `bd close -m` alias for `--reason`
- `bd show --children` flag to display child issues inline
- Dolt backend support with pluggable storage
- "enhancement" alias for "feature" type

### v0.47.1
- `bd list --ready` flag to display issues with no blockers
- Markdown rendering support in comments
- Various bug fixes

### v0.47.0
- Pull-first sync with 3-way merge for conflict reconciliation
- `bd resolve-conflicts` command for JSONL merge conflict markers
- `bd create --dry-run` flag to preview issue creation
- `bd ready --gated` flag for gated molecules
- Prevention of closing issues with open blockers
- CLI refactored to subcommands

### v0.46.0
- Custom issue types (project-configurable beyond built-in types)

### v0.45.0
- New `rig` issue type for Gas Town rig tracking
- `--filter-parent` alias for `--parent` in `bd list`

## Known Breaking Changes

### v1.0.0
- **Removed `bd daemon`**: No Unix socket IPC; Dolt SQL server is the persistent backend
- **Removed `bd mutations`**: `get_mutations` operation broken; no replacement in 1.0+
- **Removed `bd activity`**: No activity feed command in 1.0+ (see bdel-a6p)
- **Removed `bd resolve-conflicts`**: No JSONL conflict resolution in 1.0+
- **Architecture shift**: Per-call SQLite → persistent Dolt SQL server
- **`bd stats`** JSON schema changed: now includes `schema_version` and `summary` wrapper

### v0.33.1
- Field rename: `ephemeral` -> `wisp` in JSON

### v0.30.0
- Removed `--resolve-collisions` flag

### v0.21.6
- Default to hash-based IDs

### v0.20.0
- Per-project daemon socket (removed in v1.0.0)
