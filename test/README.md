# Test Directory

This directory contains ERT (Emacs Lisp Regression Testing) tests for beads.el.

## Running Tests

```bash
make test
```

By default, `make test` runs only the hermetic unit tests.
Integration tests that talk to a live `bd` CLI / Dolt server are
skipped unless explicitly opted-in via the
`BEADS_RUN_INTEGRATION_TESTS` environment variable:

```bash
BEADS_RUN_INTEGRATION_TESTS=1 make test
```

Integration tests are tagged with `:integration` and additionally
guarded by `(skip-unless (beads-test-integration-enabled-p))`.
Read-only tests that inspect the current project should also check
`(skip-unless (beads-client--find-database))`; write-path tests should
use the temporary-project helper described below instead.

## E2E Isolation Strategy

Use the narrowest test layer that proves the behavior:

- **Unit tests** mock subprocesses and backend calls; these run in
  every `make test` invocation. Prefer this layer for formatting,
  buffer rendering, command dispatch, error handling, and cache logic.
- **Read-only integration tests** use the repository's current beads
  database only for commands that cannot mutate data. Guard them with
  `BEADS_RUN_INTEGRATION_TESTS`, `:integration`, and project/database
  availability checks.
- **Write-path E2E tests** exercise real `bd` subprocess writes. Never
  run them against the repository database. Wrap real `bd` writes in
  `beads-test-with-temp-project` from `beads-test-helpers.el`; the
  helper creates a temporary `bd init` project, binds
  `default-directory` there, strips `BEADS_DIR` and `BEADS_DB` from the
  environment, clears project/backend caches, and deletes the project
  afterwards.
- **Live Dolt SQL tests** exercise direct SQL read transports. Keep
  them read-only unless they also use a temp project or an explicitly
  disposable database/server. Prefer result shape and semantic
  assertions over hard-coded issue IDs.

## Test Taxonomy, Tags, and Naming

| Layer | Uses real `bd` / Dolt? | May mutate data? | Required tags and guards | Naming |
|-------|------------------------|------------------|--------------------------|--------|
| Unit | No | No | No `:integration` tag; no environment guard | `beads-<module>-test-<behavior>` |
| Read-only CLI integration | Yes, via `beads-client-*` / CLI | No | `:integration`; `(skip-unless (beads-test-integration-enabled-p))`; `(skip-unless (beads-client--find-database))` | `beads-<module>-test-integration-<behavior>` for new tests |
| Write-path E2E | Yes, via real `bd` writes | Yes, but only in temp projects | `:integration :destructive`; integration guard; `(skip-unless (executable-find "bd"))`; `beads-test-with-temp-project` | `beads-<module>-test-e2e-<operation>` |
| Live SQL integration | Yes, via `mariadb`/`mysql.el` and Dolt SQL | No by default | `:integration`; integration guard; database/server/client availability checks | `beads-<module>-test-integration-sql-<behavior>` |

Existing tests predate the stricter naming scheme, so do not rename
old tests only for style. New integration/E2E tests should include
`integration` or `e2e` in the test name so failures are easy to scan in
batch output.

Use `:destructive` only for tests that create, update, close, delete,
or otherwise change issue data. A `:destructive` test must be isolated
with `beads-test-with-temp-project` unless the test itself creates and
tears down an explicitly disposable database/server.

Example write-path E2E shape:

```elisp
(ert-deftest beads-client-test-create-e2e ()
  :tags '(:integration :destructive)
  (skip-unless (beads-test-integration-enabled-p))
  (skip-unless (executable-find "bd"))
  (beads-test-with-temp-project project-root
    (let ((issue (beads-client-create "Temp E2E issue")))
      (should (string-prefix-p "bte-" (alist-get 'id issue))))))
```

Current recommendation: use temp `bd init` projects as the default
isolation primitive for write-path E2E coverage. Dolt branches/clones
are useful for benchmarking or preserving larger fixtures, but they are
more coupled to the developer's local database and easier to leak.
Dedicated ephemeral `dolt sql-server` processes should be introduced
only for SQL transport CI coverage that cannot be exercised through
embedded `bd` projects.

## Adding E2E Coverage

Before adding an E2E or live integration test:

1. Add or keep a unit-level test for deterministic edge cases and error
   handling; use E2E for the real subprocess/storage contract only.
2. Pick the narrowest integration layer from the taxonomy above.
3. Add the right ERT tags and `skip-unless` guards before doing any
   setup that could touch the user's database.
4. For write tests, call `beads-test-with-temp-project` before any
   `beads-client-*` operation that can mutate state.
5. Assert semantics and result shape, not local IDs or data that depend
   on the developer's current issue graph.
6. Keep fixtures small and created inside the test body. If a larger
   fixture is needed, document why and prefer a reusable helper in
   `beads-test-helpers.el`.

## Writing Tests

Test files should:
- End with `-test.el` suffix
- Use `(require 'ert)` at the top
- Define tests using `ert-deftest`

Example:

```elisp
(require 'ert)

(ert-deftest beads-feature-test ()
  "Test that feature works correctly."
  (should (equal (some-function) expected-result)))
```

## ERT Assertions

- `(should CONDITION)` - Assert that condition is true
- `(should-not CONDITION)` - Assert that condition is false
- `(should-error BODY)` - Assert that body signals an error
- `(should-error BODY :type 'error-type)` - Assert specific error type

## Test Organization

- Unit tests: Test individual functions in isolation
- Integration tests: Test component interactions (require bd CLI)

See `example-test.el` for basic examples.

## Supported Beads Versions

This package is tested with **bd 1.0.3**. Tests may not reflect
behavior of older or newer beads CLI versions.

| beads.el | beads CLI | Storage Backend           |
|----------|-----------|---------------------------|
| current  | 1.0.x     | Dolt SQL server (metadata.json) |
| legacy   | 0.49.x    | Dolt (metadata.json)      |

## Storage Backend Discovery Priority

The `beads-client--find-database` function discovers a beads project
by checking for these sentinels in order:

1. `metadata.json` — primary sentinel (Dolt backend, also present in some SQLite setups)
2. `beads.db` — legacy SQLite fallback
3. Any `.db` file (excluding `vc.db` and `*.backup`) — last-resort fallback

## Test Compatibility Notes

- **Discovery tests** (`beads-client-test.el`): Reflect the Dolt-first priority.
  Legacy `beads.db` fallback is tested separately. The legacy `.db` extension
  scanning test was removed.
- **All other test files**: Storage-backend agnostic. Test Emacs Lisp logic
  only (modes, keybindings, rendering, state management).
