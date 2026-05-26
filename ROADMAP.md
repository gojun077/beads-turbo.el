# beads.el / beads-turbo.el Roadmap

This roadmap records the current direction of the Emacs client after the Dolt
SQL backend, caching layer, and org-mode list work.  Detailed task state lives
in beads; use `bd show <id>` for the authoritative issue record.

## Current Architecture Direction

`bd` remains the source of truth for issue semantics, validation, writes, and
sync.  beads.el optimizes the high-volume interactive read paths by talking to
the local Dolt SQL server when available.

```
                    beads.el
                       │
         ┌─────────────┼─────────────┐
         ▼             ▼             ▼
    Dolt SQL DB    bd CLI        bd CLI
    (reads)       (writes)      (complex ops)
     direct TCP   subprocess    subprocess
```

- **Reads** use `beads-backend-dolt-sql.el` when `beads-dolt-sql-enabled` is
  non-nil and a Dolt SQL server is reachable.
- **Writes** still go through `bd` CLI so Go-side validation, task graph rules,
  JSONL sync, and Dolt commits stay authoritative.
- **Complex operations** that need git scanning or command-specific `bd` logic
  continue to use `bd` CLI.
- **Fallbacks** remain in place: native `mysql.el` is preferred, a persistent
  `mysql`/`mariadb` subprocess is the next fallback, one-shot `mariadb -e` is
  the final SQL fallback, and plain `bd` CLI remains the compatibility path.

## Completed Work

### Direct Dolt SQL Backend — complete

The direct SQL read backend is implemented and the parent epic is closed
(`bdel-4c4`).

- `bdel-4c4.1` — core `beads-backend-dolt-sql.el` module implemented.
- `bdel-4c4.2` — read operations expanded beyond list to show, ready, stats,
  count, and stale.
- `bdel-4c4.3` — opt-in custom variable, persistent CLI transport, and CLI
  fallback integrated.
- `bdel-4c4.4` — end-to-end backend benchmarking completed.
- `bdel-4c4.5` — optional native MySQL wire-protocol path via `mysql.el`
  integrated.

### Client-side Caching and Smart Refresh — complete

The read-side cache work is complete and the parent epic is closed
(`bdel-hba`).

- Stats are computed locally from fetched list data instead of making a separate
  stats call (`bdel-hba.1`, implemented via `bdel-ie8`).
- Project-scoped issue list caching with Dolt-backed freshness tokens is in
  place (`bdel-hba.2`).
- List-to-detail navigation uses full-issue caching plus lazy async loading,
  giving instant partial render and zero subprocess calls on cache hits
  (`bdel-hba.3`).

### Org-mode List View — largely implemented

The list view has moved from the original tabulated-list interface toward an
org-mode based interface (`bdel-7ja`).  The current implementation includes:

- `beads-org-list-mode`, derived from `org-mode`.
- Nested org headings for parent-child issue structure.
- Org TODO keyword mapping for open, blocked, and closed issues.
- Property drawers containing stable issue metadata such as `BEADS_ID`.
- Filtering, marking, bulk actions, hierarchy actions, delete/reopen, and
  detail navigation from the org list.
- Refresh-on-select behavior using the same cache/freshness path as the
  regular list refresh.

Remaining org-list work is tracked under the `bdel-7ja` and `bdel-91f` issue
families rather than duplicated here.

## Active Fork Work

### beads-turbo.el fork — in progress

The fork/repositioning epic is in progress (`bdel-261`).  The goal is to make
the increasingly divergent app distinguishable from the unmaintained upstream
while keeping churn low.

Current child work:

- `bdel-261.1` — refactor `README.md` for the new project identity and remove
  stale references.
- `bdel-261.2` — update this roadmap to reflect completed work and current
  direction.
- `bdel-v3z` — publish/package work remains open, but package metadata and
  distribution details should be revisited after the fork identity is settled.

Naming policy recorded in `bdel-261.3`:

- Keep existing `beads-*` symbols by default.
- Use `beads-turbo.el` / `beads-turbo` for repository, package, README, and
  other user-facing project identity where the fork must be distinguished.
- Consider compact new prefixes such as `bdtel-*` only for genuinely new
  turbo-specific APIs or internals.
- Avoid wholesale symbol renames unless there is a concrete namespace,
  packaging, or user-clarity reason.

## Open Work Areas

### Documentation and packaging

- Update README installation URLs, badges, package naming, and project overview
  for the fork (`bdel-261.1`).
- Revisit MELPA or other package distribution once the fork name and package
  metadata are final (`bdel-v3z`).
- Keep Texinfo/org documentation in sync with the org-list-first workflow.

### Usability bugs

Open usability work is tracked under `bdel-91f`.  Current high-signal items
include multi-workspace org-list buffer behavior and section population bugs in
sorted views.

### Feature backlog

Feature epics such as comments support (`bdel-5as`) and UI polish such as P0
whole-line highlighting (`bdel-zor`) remain open, but are lower priority than
stabilizing the fork identity and documentation.

## Schema Stability Notes

The Dolt tables used by the SQL transport remain the stable read contract:

| Table / View     | Stability | Notes |
|------------------|-----------|-------|
| `issues`         | High      | Core entity, columns rarely change |
| `dependencies`   | High      | Graph edges, type enum may grow |
| `labels`         | High      | Simple many-to-many junction |
| `comments`       | High      | Append-only log |
| `ready_issues`   | High      | Materialized Dolt view |
| `blocked_issues` | Medium    | Auto-generated; column set stable |
| `config`         | Medium    | Key-value; keys may evolve |
| `child_counters` | Low       | Internal counter; avoid direct use |

The practical rule is unchanged: use Dolt SQL for fast reads when available,
but keep `bd` CLI as the authoritative compatibility and write path.
