# beads.el Roadmap

## Architecture Strategy: Dolt SQL as Stable FFI

`bd` CLI is a fast-moving target — 200k+ lines of Go, rapid iteration, frequent
flag and output format changes. Every `bd` invocation is a fresh Go binary that
connects to Dolt, executes a query, serializes JSON, and exits. The per-call
overhead is dominated by Go runtime startup (~50ms) + MySQL handshake (~10ms),
not the query itself (~1ms).

**Dolt SQL is the more stable interface:**

- Dolt schema has versioned migrations (`schema_migrations` table)
- Core tables (`issues`, `dependencies`, `labels`) are structurally stable
- The `ready_issues` view already materializes complex recursive CTEs
- Dolt speaks standard MySQL protocol — any MySQL-compatible client works

**Recommended long-term architecture:**

```
                    beads.el
                       │
         ┌─────────────┼─────────────┐
         ▼             ▼             ▼
    Dolt SQL DB    bd CLI        bd CLI
    (reads, 80%)  (writes, 15%)  (complex, 5%)
     direct TCP   subprocess     subprocess
```

- **Reads** (list, show, ready, stats, stale, count) → direct SQL queries
  against the Dolt MySQL server. No Go binary, no intermediate serialization.
- **Writes** (create, update, close, delete) → `bd` CLI for Go-side
  validation, JSONL sync, and orchestration logic.
- **Complex ops** (orphans, lint, batch, epic close-eligible) → `bd` CLI
  for operations that need git scanning or cross-table validation.

## Performance: Direct SQL vs bd CLI

Benchmarked with mariadb 11.8.6, bd 1.0.3, 88 issues:

| Operation | `bd` CLI | Direct SQL | Speedup |
|-----------|----------|------------|---------|
| list      | 64ms     | 12ms       | 5.3x    |
| show      | 51ms     | 9ms        | 5.7x    |
| ready     | 47ms     | 7ms        | 6.7x    |
| stats     | 210ms    | 8ms        | 26.3x   |
| orphans   | 216ms    | N/A (git)  | -       |
| stale     | 244ms    | SQL doable | -       |

Even with `mariadb` subprocess overhead (~10ms), direct SQL is 5-26x faster.
With a native MySQL protocol client (see Tier 2 below), latency would drop
below 1ms — making auto-refresh and preview near-instant.

## Implementation Plan

### Tier 1: `mariadb -e` Transport (current)

Create `beads-backend-dolt-sql.el` that issues SELECT queries via the
`mariadb` CLI subprocess. Reads Dolt connection params from `bd dolt show`
(host, port, user, database). Returns results in JSON matching `bd` CLI
format so existing elisp callers work unchanged.

- **Effort:** ~200 lines of elisp
- **Speedup:** 5-26x vs `bd` CLI
- **Risk:** Low — thin wrapper, falls back to `bd` if Dolt is down
- **Status:** [bdel-4c4.1][] (core), [bdel-4c4.2][] (expand ops)

### Tier 2: Native MySQL Protocol (future)

Replace the `mariadb` subprocess with a native Elisp MySQL protocol client
using `make-network-process`. Talks MySQL binary protocol directly to Dolt
over TCP. Passwordless auth (Dolt defaults) simplifies the handshake.

- **Effort:** ~500 lines of elisp (handshake + result set parsing)
- **Speedup:** 50x+ vs `bd` CLI, ~10x vs Tier 1
- **Status:** [bdel-4c4.5][] (stretch goal)

### Opt-in Gate

Both tiers are gated behind `beads-dolt-sql-enabled` (defcustom, default
`nil`). When disabled or when Dolt server is unreachable, beads.el silently
falls back to `bd` CLI. This ensures zero risk for existing users while
allowing early adopters to opt in.

## Schema Stability Notes

The Dolt tables used by the SQL transport:

| Table / View    | Stability | Notes |
|-----------------|-----------|-------|
| `issues`        | High      | Core entity, columns rarely change |
| `dependencies`  | High      | Graph edges, type enum may grow |
| `labels`        | High      | Simple many-to-many junction |
| `comments`      | High      | Append-only log |
| `ready_issues`  | High      | Materialized Dolt view |
| `blocked_issues`| Medium    | Auto-generated; column set stable |
| `config`        | Medium    | Key-value; keys may evolve |
| `child_counters`| Low       | Internal counter; avoid direct use |

The `bd` binary will continue to evolve — new flags, changed output format,
additional subcommands. By anchoring beads.el to the Dolt schema for reads,
we decouple from that velocity and only need to track schema migrations.

## Related Issues

All tracked in beads (`bd show <id>` for details):

- `bdel-4c4` — Epic: Investigate direct Dolt SQL transport
- `bdel-4c4.1` — Implement `beads-backend-dolt-sql.el` core
- `bdel-4c4.2` — Expand to show, ready, stats, count, stale
- `bdel-4c4.3` — Opt-in custom variable + CLI fallback
- `bdel-4c4.4` — Benchmark end-to-end
- `bdel-4c4.5` — Native MySQL protocol (stretch)
- `bdel-hba.1` — Compute stats locally (eliminate 2nd CLI call)
- `bdel-hba.3` — Avoid re-fetching list→detail (cache list data)
