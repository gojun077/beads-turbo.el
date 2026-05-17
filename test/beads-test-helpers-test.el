;;; beads-test-helpers-test.el --- Tests for beads-test-helpers.el -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for shared ERT helper functions.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'seq)
(require 'beads-test-helpers)

(ert-deftest beads-test-helpers-test-without-beads-env ()
  "Project-selecting environment variables are stripped for temp E2E tests."
  (let ((result (beads-test--without-beads-env
                 '("BEADS_DIR=/real/project/.beads"
                   "BEADS_DB=/real/project/.beads/metadata.json"
                   "BD_NON_INTERACTIVE=0"
                   "KEEP_ME=1"))))
    (should (member "BD_NON_INTERACTIVE=1" result))
    (should (member "KEEP_ME=1" result))
    (should-not (seq-some (lambda (entry) (string-prefix-p "BEADS_DIR=" entry)) result))
    (should-not (seq-some (lambda (entry) (string-prefix-p "BEADS_DB=" entry)) result))
    (should-not (member "BD_NON_INTERACTIVE=0" result))))

(ert-deftest beads-test-helpers-test-with-temp-project-binds-directory ()
  "`beads-test-with-temp-project' initialises and enters a temp project."
  (let (init-directory
        init-args
        body-directory
        body-root
        body-beads-dir
        body-beads-db)
    (cl-letf (((symbol-function 'executable-find)
               (lambda (program)
                 (when (equal program "bd") "/usr/bin/bd")))
              ((symbol-function 'call-process)
               (lambda (program &optional _infile _destination _display &rest args)
                 (should (equal program "bd"))
                 (setq init-directory default-directory
                       init-args args)
                 0)))
      (let ((process-environment
             '("BEADS_DIR=/real/project/.beads"
               "BEADS_DB=/real/project/.beads/metadata.json")))
        (beads-test-with-temp-project project-root
          (setq body-root project-root
                body-directory default-directory
                body-beads-dir (getenv "BEADS_DIR")
                body-beads-db (getenv "BEADS_DB"))
          (should (file-directory-p project-root))))
      (should (equal init-args
                     (list "init" "--non-interactive" "--skip-agents"
                           "--skip-hooks" "-p" beads-test-temp-project-prefix)))
      (should (equal init-directory body-directory))
      (should (equal body-root body-directory))
      (should-not body-beads-dir)
      (should-not body-beads-db)
      (should-not (file-exists-p body-root)))))

(provide 'beads-test-helpers-test)
;;; beads-test-helpers-test.el ends here
