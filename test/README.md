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

- Unit tests: mock subprocesses and backend calls; these run in every
  `make test` invocation.
- Read-only integration tests: use the repository's current beads
  database only for commands that cannot mutate data. Guard them with
  `BEADS_RUN_INTEGRATION_TESTS`, `:integration`, and project/database
  availability checks.
- Write-path E2E tests: never run against the repository database.
  Wrap real `bd` writes in `beads-test-with-temp-project` from
  `beads-test-helpers.el`; the helper creates a temporary `bd init`
  project, binds `default-directory` there, strips `BEADS_DIR` and
  `BEADS_DB` from the environment, clears project/backend caches, and
  deletes the project afterwards.
- Live Dolt SQL tests: keep them read-only unless they also use a temp
  project or an explicitly disposable database/server. Prefer result
  shape and semantic assertions over hard-coded issue IDs.

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
- **Activity tests** (`beads-activity-test.el`): Preserved but documented as
  testing only the Emacs Lisp rendering layer. The `bd activity` subcommand
  does not exist in bd 1.0.x (see bdel-a6p).
- **All other test files**: Storage-backend agnostic. Test Emacs Lisp logic
  only (modes, keybindings, rendering, state management).
