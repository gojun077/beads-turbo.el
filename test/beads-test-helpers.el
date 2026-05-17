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

(require 'cl-lib)
(require 'subr-x)

(declare-function beads-backend-clear-cache "beads-backend")
(declare-function beads-client-clear-cache "beads-client")

(defun beads-test-integration-enabled-p ()
  "Return non-nil when integration tests should be executed.
Integration tests require a live bd CLI / Dolt server and are
disabled by default to keep `make test' hermetic.  Set the
environment variable BEADS_RUN_INTEGRATION_TESTS to any non-empty
value to opt in."
  (let ((v (getenv "BEADS_RUN_INTEGRATION_TESTS")))
    (and v (not (string-empty-p v)))))

(defvar beads-test-temp-project-prefix "bte"
  "Issue ID prefix used for temporary E2E beads projects.")

(defun beads-test--without-beads-env (environment)
  "Return ENVIRONMENT with project-selecting beads variables removed.
This prevents a caller's `BEADS_DIR' or `BEADS_DB' from making a temp
project test accidentally operate on an unrelated project."
  (cons "BD_NON_INTERACTIVE=1"
        (cl-remove-if
         (lambda (entry)
           (or (string-prefix-p "BEADS_DIR=" entry)
               (string-prefix-p "BEADS_DB=" entry)
               (string-prefix-p "BD_NON_INTERACTIVE=" entry)))
         environment)))

(defun beads-test--clear-project-caches ()
  "Clear beads.el project/backend caches when their modules are loaded."
  (when (fboundp 'beads-client-clear-cache)
    (beads-client-clear-cache))
  (when (fboundp 'beads-backend-clear-cache)
    (beads-backend-clear-cache)))

(defun beads-test--init-temp-project (project-root)
  "Initialise a fresh bd project in PROJECT-ROOT.
Signals an error with the bd output when initialisation fails."
  (unless (executable-find "bd")
    (error "bd executable not found; cannot create temp beads project"))
  (let ((default-directory (file-name-as-directory project-root)))
    (with-temp-buffer
      (let ((exit-code (call-process
                        "bd" nil t nil
                        "init"
                        "--non-interactive"
                        "--skip-agents"
                        "--skip-hooks"
                        "-p" beads-test-temp-project-prefix)))
        (unless (zerop exit-code)
          (error "bd init failed in %s with exit code %d: %s"
                 project-root exit-code (string-trim (buffer-string))))))))

(defmacro beads-test-with-temp-project (project-root-var &rest body)
  "Create an isolated temporary beads project and evaluate BODY.
PROJECT-ROOT-VAR is bound to the temporary project root, and
`default-directory' is rebound there while BODY runs.  The helper
initialises the project with real `bd init' but removes `BEADS_DIR' and
`BEADS_DB' from the process environment so write-path E2E tests cannot
mutate the repository under test by accident."
  (declare (indent 1) (debug (symbolp body)))
  `(let* ((,project-root-var (file-name-as-directory
                              (make-temp-file "beads-e2e-" t)))
          (process-environment
           (beads-test--without-beads-env process-environment)))
     (unwind-protect
         (progn
           (beads-test--init-temp-project ,project-root-var)
           (beads-test--clear-project-caches)
           (let ((default-directory ,project-root-var))
             ,@body))
       (beads-test--clear-project-caches)
       (when (and ,project-root-var (file-directory-p ,project-root-var))
         (delete-directory ,project-root-var t)))))

(provide 'beads-test-helpers)
;;; beads-test-helpers.el ends here
