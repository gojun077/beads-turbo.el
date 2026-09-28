# `bd serve` evaluation (beads 1.3.0)

Issue: `bdel-4zc`

Date: 2026-09-28

## Decision

Do not replace the default direct Dolt SQL backend with `bd serve` yet.

The HTTP API is the right long-term boundary because it is versioned and owned
by beads, but the 1.3.0 server is still a preview transport rather than a
discoverable workspace service. Keep the current CLI fallback, fix the immediate
1.3 SQL-schema incompatibility under `bdel-0ak`, and revisit an optional HTTP
backend once server discovery/lifecycle and the API surface stabilize.

## What was verified

The installed CLI is beads 1.3.0 at upstream `main` commit `671715bb8`. A local
server was started against this repository with:

```sh
bd serve --addr 127.0.0.1:17777
```

`GET /v0/beads/context`, issue listing, issue detail, ready work, and stats all
worked against the repository's shared Dolt server. The context advertised API
version `v0`, beads version `1.3.0`, Dolt `server` mode, project identity, and
operation capabilities.

The event journal is disabled in this workspace, as it is by default. The
events endpoint correctly returned HTTP 409 `events_journal_disabled`.

## API coverage

Direct HTTP equivalents exist for the hot read path:

| Current operation      | HTTP API                                 |
|------------------------|------------------------------------------|
| list                   | `GET /v0/beads/issues`                   |
| show                   | `GET /v0/beads/issues/{id}`              |
| ready                  | `GET /v0/beads/ready`                    |
| stats                  | `GET /v0/beads/stats`                    |
| count                  | `GET /v0/beads/issues:count`             |
| freshness/invalidation | `GET /v0/beads/events` or `events:watch` |

The API also covers create, update, close, delete, comments, config, dependency
mutation/tree queries, and batch operations. It does not directly cover the
current `stale`, `types`, or aggregate `epic_status` operations. Label add/remove
would require a read-modify-write replacement of the complete label set.

Responses are not drop-in CLI responses. Lists use an `{items, has_more,
next_cursor}` envelope, stats use a `summary` envelope, and mutations have
operation-specific response objects. An HTTP backend therefore needs an
explicit normalization layer rather than transport substitution alone.

For the list view, preserving the current all-normal-issues contract requires:

```text
GET /v0/beads/issues?all=true&limit=0&brief=true
```

The default request excludes closed/done issues and defaults to 50 rows.
Non-loopback servers reject unlimited (`limit=0`) reads, requiring cursor
pagination.

## Lifecycle and compatibility constraints

- The default bind is an ephemeral loopback port. The address is printed to
  stdout but is not registered in a lock file, PID file, or discovery service.
- A process serves exactly one workspace. Supporting multiple open Emacs
  projects means supervising one process per workspace or requiring user-owned
  fixed-port configuration.
- In 1.3.0, `bd serve` refuses embedded Dolt and readonly mode. It works only
  with server, shared-server, external-server, or proxied-server topology.
- Loopback has no authentication by default. Non-loopback serving needs a token
  file (or an explicit insecure override), has no TLS, and enforces a Host
  allowlist.
- HTTP mutations do not run CLI hooks or command-end auto-commit/export/backup
  maintenance. Using HTTP for writes would therefore change behavior.
- The API is `v0` and documented as preview. `/v0/beads/context` capabilities
  must be checked rather than assumed.

## Event journal constraints

The ordered event stream is useful as a cache-invalidation hint, but it cannot
replace authoritative refreshes:

- it is opt-in per workspace (`events-journal` defaults to false);
- enabling it requires restarting an already-running server;
- each clone has an independent sequence;
- `bd dolt pull`/sync changes are not journaled;
- retention can truncate an old checkpoint, returning HTTP 410;
- missing `is_blocked` means false.

The safe cache design would consume events for prompt invalidation while still
rebuilding from current state after sync, clone changes, truncation, reconnect
ambiguity, or server restart.

## Performance observation

On this 218-issue workspace, 20 loopback requests made with `curl` averaged:

| Request                      | Mean wall time |
|------------------------------|---------------:|
| all issues, unlimited, brief |        10.8 ms |
| issue detail                 |         8.0 ms |
| ready, unlimited, brief      |        10.3 ms |
| stats                        |         2.1 ms |

Twenty synchronous Emacs `url-retrieve-synchronously` list requests averaged
31.4 ms including JSON parsing and buffer setup. This is much faster than
forking `bd` per request, but it is not evidence that HTTP beats the native
`mysql.el` path; a production backend should use asynchronous requests and be
benchmarked with its final connection strategy.

## Schema-drift finding

The investigation confirmed the failure mode the HTTP API is intended to
prevent. In beads 1.3.0 the `dependencies` table uses typed target columns such
as `depends_on_issue_id`; the direct SQL backend still references
`depends_on_id`. Live SQL list, ready, show, stale, and epic-status integration
tests fail and normal operation silently falls back to the CLI. This is tracked
separately as `bdel-0ak`.

## Revisit criteria

Implement an opt-in HTTP backend when at least one of these is true:

1. beads publishes a stable discovery/lifecycle mechanism for one workspace
   server, or beads-turbo deliberately owns and supervises ephemeral servers;
2. the HTTP contract leaves preview status and has a compatibility policy;
3. missing operations gain direct endpoints, or retaining CLI fallback for them
   is accepted explicitly.

The first implementation should route reads only, normalize API envelopes to
the existing client contract, verify `/context` project identity and
capabilities, and fall back to the CLI on startup, transport, capability, or
version failure. HTTP writes and SSE-based invalidation should remain separate
follow-up decisions.
