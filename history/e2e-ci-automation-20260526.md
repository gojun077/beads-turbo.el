# CI Automation Strategy for Dolt SQL + Emacs E2E Tests

Issue: `bdel-n1d.4`

## Recommendation

Adopt CI integration coverage in two stages:

1. **Every PR:** keep `make check` as the required gate. It runs the
   hermetic ERT suite, lint, build checks, and performance tests without
   requiring a live `bd`/Dolt server.
2. **Nightly or protected/manual job first:** run the focused live Dolt SQL
   integration selector from `test/beads-backend-dolt-sql-test.el`:

   ```bash
   BEADS_RUN_INTEGRATION_TESTS=1 \
   emacs -Q --batch \
     -L lisp -L test -L vendor/vui.el -L vendor/mysql.el \
     -l test/beads-backend-dolt-sql-test.el \
     --eval '(ert-run-tests-batch-and-exit "beads-dolt-sql-test-integration-")'
   ```

   Promote this job to every PR after the live UI/client integration tests
   that currently share `BEADS_RUN_INTEGRATION_TESTS` are made batch-stable.
   Until then, running all opt-in integration tests in CI risks flakes and
   unrelated failures outside the SQL transport contract.

## Required CI Dependencies

- Emacs 30.2+.
- `bd` CLI pinned to the repository-supported 1.0.x line; this repo is tested
  with `bd 1.0.3`.
- Dolt CLI/server.
- `mariadb` client on `PATH`; the SQL integration tests deliberately exercise
  the direct mariadb transport path, not only the vendored mysql.el path.
- Git submodules initialized for `vendor/vui.el` and `vendor/mysql.el`.

Prefer a pinned tool install over `latest` for the SQL job. `latest` is fine for
an exploratory scheduled job, but the PR gate should be reproducible.

## Service Setup

Use an ephemeral CI workspace rather than the developer's `.beads/` database.
The least surprising setup is:

1. Check out the repo with submodules.
2. Install Emacs, `bd`, Dolt, and `mariadb-client`.
3. Run `make setup` or the equivalent explicit setup steps to create `.beads/`,
   configure Dolt server mode, fetch/reset the Dolt database fixture, and start
   the Dolt SQL server on port `3310`.
4. Poll readiness before ERT:

   ```bash
   for i in $(seq 1 30); do
     bd dolt test >/dev/null 2>&1 && break
     sleep 1
   done
   bd dolt test
   mariadb --host 127.0.0.1 --port 3310 --user root \
     --batch --skip-column-names --raw beads_bdel -e 'SELECT 1'
   ```

5. Run the focused SQL integration selector.
6. Always tear down the server:

   ```bash
   bd dolt stop || true
   ```

## Port Conflicts

The repository defaults to Dolt SQL port `3310`. On hosted GitHub Actions this
is usually safe because each job has an isolated VM. On self-hosted Codeberg /
Woodpecker runners, concurrent jobs can collide if they share the same host and
workspace.

Mitigations:

- Prefer one workspace/container per job.
- If the runner can execute concurrent jobs on one host, allocate a job-specific
  port and run `bd dolt set port "$PORT" --update-config` before starting the
  server.
- Add a readiness check that fails fast if the port is already bound by another
  process.
- Always run `bd dolt stop || true` in CI teardown.

## Startup Latency and Flake Controls

- Expect the Dolt server and first SQL connection to add tens of seconds on a
  cold runner, mostly from tool installation and remote fixture fetch.
- Use explicit readiness polling (`bd dolt test` plus a trivial `mariadb -e
  'SELECT 1'`) instead of fixed sleeps.
- Give the SQL integration job its own timeout, e.g. 10-15 minutes, so hung
  services fail cleanly.
- Keep integration assertions semantic: compare ids/counts/shapes rather than
  hard-coded issue ids or timestamps.
- Keep write-path E2E isolated with `beads-test-with-temp-project`; do not run
  destructive tests against the shared Dolt fixture.

## Caching Strategy

Useful caches:

- Tool downloads for Dolt, `bd`, and Emacs where the CI provider supports it.
- Docker image layers if using containerized Dolt or custom step images.
- The Dolt database fixture only when the cache key includes the fixture remote
  revision or an explicit version. Avoid caching `.beads/metadata.json` with a
  stale port or host-specific data.

Avoid caching:

- A running Dolt server state.
- Mutable `.beads/` directories after destructive tests.
- `BEADS_DIR` or `BEADS_DB` environment values from the runner.

## GitHub Actions Sketch

```yaml
name: ci

on:
  pull_request:
  push:

jobs:
  check:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive
      - name: Install dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y emacs-nox mariadb-client
          # Install pinned bd + Dolt here.
      - run: make check

  live-sql-integration:
    runs-on: ubuntu-latest
    timeout-minutes: 15
    # Start as scheduled/manual; promote to pull_request after legacy live
    # integration tests are made batch-stable.
    if: github.event_name != 'pull_request'
    steps:
      - uses: actions/checkout@v4
        with:
          submodules: recursive
      - name: Install dependencies
        run: |
          sudo apt-get update
          sudo apt-get install -y emacs-nox mariadb-client
          # Install pinned bd + Dolt here.
      - name: Start Dolt fixture
        run: |
          make setup
          for i in $(seq 1 30); do
            bd dolt test >/dev/null 2>&1 && break
            sleep 1
          done
          bd dolt test
      - name: Run live SQL ERT selector
        env:
          BEADS_RUN_INTEGRATION_TESTS: "1"
        run: |
          emacs -Q --batch \
            -L lisp -L test -L vendor/vui.el -L vendor/mysql.el \
            -l test/beads-backend-dolt-sql-test.el \
            --eval '(ert-run-tests-batch-and-exit "beads-dolt-sql-test-integration-")'
      - name: Stop Dolt
        if: always()
        run: bd dolt stop || true
```

## Codeberg / Woodpecker Sketch

Use a custom image or step setup that contains Emacs, Dolt, `bd`, and
`mariadb-client`. For self-hosted runners, prefer a per-job container so the
default `3310` port is isolated.

```yaml
steps:
  check:
    image: debian:stable-slim
    commands:
      - apt-get update
      - apt-get install -y emacs-nox git make mariadb-client ca-certificates curl
      - git submodule update --init --recursive
      - ./ci/install-pinned-tools.sh   # bd + Dolt, if a project script is added
      - make check

  live_sql_integration:
    image: debian:stable-slim
    when:
      event: cron
    commands:
      - apt-get update
      - apt-get install -y emacs-nox git make mariadb-client ca-certificates curl
      - git submodule update --init --recursive
      - ./ci/install-pinned-tools.sh
      - make setup
      - |
        for i in $(seq 1 30); do
          bd dolt test >/dev/null 2>&1 && break
          sleep 1
        done
      - bd dolt test
      - |
        BEADS_RUN_INTEGRATION_TESTS=1 emacs -Q --batch \
          -L lisp -L test -L vendor/vui.el -L vendor/mysql.el \
          -l test/beads-backend-dolt-sql-test.el \
          --eval '(ert-run-tests-batch-and-exit "beads-dolt-sql-test-integration-")'
      - bd dolt stop || true
```

## Open Follow-ups Before Making Live SQL Required on Every PR

- Add a project-owned pinned installer script or container image for `bd` and
  Dolt; do not leave CI to unpinned `latest` downloads.
- Add a make target for the focused SQL selector if repeated locally often, for
  example `make integration-sql-test`.
- Fix or split the broader `BEADS_RUN_INTEGRATION_TESTS=1 make test` suite so
  legacy UI/client integration tests can run headlessly without unrelated
  failures.
- Decide whether PRs should use a remote fixture (`make setup`) or a generated
  miniature fixture for faster startup and fewer remote dependencies.

## References

- Dolt project and Docker images: <https://github.com/dolthub/dolt>
- MariaDB client setup action example: <https://github.com/ankane/setup-mariadb>
- GitHub Actions secrets guidance: <https://docs.github.com/actions/security-guides/using-secrets-in-github-actions>
- Woodpecker CI documentation: <https://woodpecker-ci.org/docs>
- Beads CLI installation notes: <https://github.com/gastownhall/beads/blob/main/docs/INSTALLING.md>
