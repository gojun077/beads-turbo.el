;;; beads-test-helpers.el --- Shared helpers for beads.el ERT tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Shared helpers used by ERT tests in this repository.
;;
;; Integration test gating
;; -----------------------
;; Integration tests in beads-client-test.el, beads-detail-test.el and
;; beads-list-test.el make real `beads-client-*' calls that invoke the
;; bd CLI / Dolt SQL backend.  They require:
;;
;;   - cwd inside a beads-initialised project (with .beads/ containing
;;     metadata.json + dolt db)
;;   - a running dolt server on the configured port
;;   - bd in PATH and able to find the DB
;;
;; Because this repository itself is beads-managed, the previous gate
;; `(skip-unless (beads-client--find-database))' did not skip them in
;; `make test', and they failed (CLI exit 1 / wrong-type errors).
;;
;; Tests that need the real backend should now use:
;;
;;   (skip-unless (beads-test-integration-enabled-p))
;;
;; in addition to (or instead of) the database-presence check.  The
;; gate is opt-in via the `BEADS_RUN_INTEGRATION_TESTS' environment
;; variable.  Set it to any non-empty value to run integration tests,
;; e.g.:
;;
;;   BEADS_RUN_INTEGRATION_TESTS=1 make test

;;; Code:

(defun beads-test-integration-enabled-p ()
  "Return non-nil when integration tests should be executed.
Integration tests require a live bd CLI / Dolt server and are
disabled by default to keep `make test' hermetic.  Set the
environment variable BEADS_RUN_INTEGRATION_TESTS to any non-empty
value to opt in."
  (let ((v (getenv "BEADS_RUN_INTEGRATION_TESTS")))
    (and v (not (string-empty-p v)))))

(provide 'beads-test-helpers)
;;; beads-test-helpers.el ends here
