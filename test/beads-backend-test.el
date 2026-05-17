;;; beads-backend-test.el --- Tests for beads-backend.el -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the backend abstraction layer.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'beads-backend)
(require 'beads-backend-bd)
(require 'beads-backend-br)

;;; Registry tests

(ert-deftest beads-backend-test-bd-registered ()
  "Test that bd backend is registered."
  (should (beads-backend--lookup "bd")))

(ert-deftest beads-backend-test-br-registered ()
  "Test that br backend is registered."
  (should (beads-backend--lookup "br")))

(ert-deftest beads-backend-test-lookup-unknown ()
  "Test that looking up unknown backend returns nil."
  (should-not (beads-backend--lookup "nonexistent")))

(ert-deftest beads-backend-test-register-custom ()
  "Test registering a custom backend."
  (let ((beads-backend--registry beads-backend--registry))
    (beads-backend-register
     (make-beads-backend
      :name "test-custom"
      :cli-program "test-cmd"
      :supported-ops '("list" "show")
      :op-to-cli-args (lambda (_op _args) '("list"))))
    (should (beads-backend--lookup "test-custom"))
    (should (equal (beads-backend-cli-program
                    (beads-backend--lookup "test-custom"))
                   "test-cmd"))))

;;; Capability tests

(ert-deftest beads-backend-test-bd-supports-all-ops ()
  "Test that bd backend supports standard operations."
  (let ((bd (beads-backend--lookup "bd")))
    (dolist (op '("list" "show" "ready" "create" "update" "close"
                   "delete" "stats" "types" "duplicates"
                   "comments-add"))
      (should (beads-backend-supports-p bd op)))))

(ert-deftest beads-backend-test-br-supports-core-ops ()
  "Test that br backend supports core operations."
  (let ((br (beads-backend--lookup "br")))
    (dolist (op '("list" "show" "ready" "create" "update" "close"
                  "delete" "stats"))
      (should (beads-backend-supports-p br op)))))

(ert-deftest beads-backend-test-br-missing-ops ()
  "Test that br backend does not support bd-specific operations."
  (let ((br (beads-backend--lookup "br")))
    (dolist (op '("types" "duplicates"
                    "comments-add" "config_get"))
      (should-not (beads-backend-supports-p br op)))))

(ert-deftest beads-backend-test-require-operation-signals ()
  "Test that require-operation signals for unsupported ops."
  (let ((br (beads-backend--lookup "br")))
    (should-error (beads-backend-require-operation br "health")
                  :type 'beads-backend-error)))

(ert-deftest beads-backend-test-require-operation-passes ()
  "Test that require-operation passes for supported ops."
  (let ((bd (beads-backend--lookup "bd")))
    (should-not (beads-backend-require-operation bd "list"))))

;;; Auto-detection tests

(ert-deftest beads-backend-test-detect-bd ()
  "Test auto-detection prefers bd when available."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (cmd) (when (equal cmd "bd") "/usr/bin/bd")))
            ((symbol-function 'beads-client--project-root)
             (lambda () nil)))
    (let ((beads-cli-program nil)
          (beads-backend--project-cache (make-hash-table :test 'equal)))
      (should (equal (beads-backend-name (beads-backend-for-project)) "bd")))))

(ert-deftest beads-backend-test-detect-br-fallback ()
  "Test auto-detection falls back to br when bd not available."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (cmd) (when (equal cmd "br") "/usr/bin/br")))
            ((symbol-function 'beads-client--project-root)
             (lambda () nil)))
    (let ((beads-cli-program nil)
          (beads-backend--project-cache (make-hash-table :test 'equal)))
      (should (equal (beads-backend-name (beads-backend-for-project)) "br")))))

(ert-deftest beads-backend-test-detect-none-signals ()
  "Test auto-detection signals when no CLI found."
  (cl-letf (((symbol-function 'executable-find) (lambda (_) nil))
            ((symbol-function 'beads-client--project-root)
             (lambda () nil)))
    (let ((beads-cli-program nil)
          (beads-backend--project-cache (make-hash-table :test 'equal)))
      (should-error (beads-backend-for-project)
                    :type 'beads-backend-error))))

(ert-deftest beads-backend-test-override-via-defcustom ()
  "Test that beads-cli-program overrides auto-detection."
  (cl-letf (((symbol-function 'executable-find)
             (lambda (cmd) (when (equal cmd "bd") "/usr/bin/bd")))
            ((symbol-function 'beads-client--project-root)
             (lambda () nil)))
    (let ((beads-cli-program "br")
          (beads-backend--project-cache (make-hash-table :test 'equal)))
      (should (equal (beads-backend-name (beads-backend-for-project)) "br")))))

(ert-deftest beads-backend-test-project-cache ()
  "Test that backends are cached per project root."
  (let ((detect-count 0))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (cmd)
                 (when (equal cmd "bd")
                   (setq detect-count (1+ detect-count))
                   "/usr/bin/bd")))
              ((symbol-function 'beads-client--project-root)
               (lambda () "/fake/project/")))
      (let ((beads-cli-program nil)
            (beads-backend--project-cache (make-hash-table :test 'equal)))
        (beads-backend-for-project)
        (beads-backend-for-project)
        (should (= detect-count 1))))))

;;; CLI arg translation parity tests

(ert-deftest beads-backend-test-bd-list-args ()
  "Test bd backend list operation CLI args."
  (let ((args (beads-backend-bd--operation-to-cli-args
               "list" '((status . "open") (priority . 1)))))
    (should (equal (car args) "list"))
    (should (member "--status" args))
    (should (member "open" args))))

(ert-deftest beads-backend-test-bd-show-args ()
  "Test bd backend show operation CLI args."
  (should (equal (beads-backend-bd--operation-to-cli-args
                  "show" '((id . "bd-001")))
                 '("show" "bd-001"))))

(ert-deftest beads-backend-test-bd-create-args ()
  "Test bd backend create operation CLI args."
  (let ((args (beads-backend-bd--operation-to-cli-args
               "create" '((title . "Test")
                           (priority . 1)
                           (parent . "bd-parent")))))
    (should (equal (car args) "create"))
    (should (equal (cadr args) "Test"))
    (should (member "--priority" args))
    (should (member "--parent" args))
    (should (member "bd-parent" args))))

(ert-deftest beads-backend-test-bd-create-normalizes-legacy-args ()
  "Test bd backend create emits current `bd create' flag names."
  (let ((args (beads-backend-bd--operation-to-cli-args
               "create" '((title . "Test")
                           (issue_type . "bug")
                           (acceptance_criteria . "Done")
                           (dependencies . "blocks:bd-1")))))
    (should (member "--type" args))
    (should (member "bug" args))
    (should-not (member "--issue-type" args))
    (should (member "--acceptance" args))
    (should-not (member "--acceptance-criteria" args))
    (should (member "--deps" args))
    (should-not (member "--dependencies" args))))

(ert-deftest beads-backend-test-bd-close-with-reason ()
  "Test bd backend close with reason."
  (should (equal (beads-backend-bd--operation-to-cli-args
                  "close" '((id . "bd-001") (reason . "done")))
                 '("close" "bd-001" "--reason" "done"))))

(ert-deftest beads-backend-test-bd-close-without-reason ()
  "Test bd backend close without reason."
  (should (equal (beads-backend-bd--operation-to-cli-args
                  "close" '((id . "bd-001")))
                 '("close" "bd-001"))))

(ert-deftest beads-backend-test-bd-update-bulk ()
  "Test bd backend update_bulk produces a single multi-ID CLI call (bdel-iin.4)."
  (let ((args (beads-backend-bd--operation-to-cli-args
               "update_bulk" '((ids . ("bd-1" "bd-2" "bd-3"))
                               (status . "open")))))
    (should (equal (car args) "update"))
    ;; All three IDs are positional and appear before the flags
    (should (equal (seq-subseq args 0 4) '("update" "bd-1" "bd-2" "bd-3")))
    (should (member "--status" args))
    (should (member "open" args))))

(ert-deftest beads-backend-test-bd-update-bulk-multiple-flags ()
  "Test bd backend update_bulk with priority + assignee flags."
  (let ((args (beads-backend-bd--operation-to-cli-args
               "update_bulk" '((ids . ("bd-1" "bd-2"))
                               (priority . 1)
                               (assignee . "alice")))))
    (should (equal (seq-subseq args 0 3) '("update" "bd-1" "bd-2")))
    (should (member "--priority" args))
    (should (member "1" args))
    (should (member "--assignee" args))
    (should (member "alice" args))))

(ert-deftest beads-backend-test-bd-update-bulk-registered ()
  "Test bd backend advertises update_bulk support."
  (should (beads-backend-supports-p
           (beads-backend--lookup "bd") "update_bulk")))

(ert-deftest beads-backend-test-bd-close-bulk-with-reason ()
  "Test bd backend close_bulk produces a single multi-ID CLI call (bdel-iin.4)."
  (should (equal (beads-backend-bd--operation-to-cli-args
                  "close_bulk" '((ids . ("bd-1" "bd-2"))
                                 (reason . "done")))
                 '("close" "bd-1" "bd-2" "--reason" "done"))))

(ert-deftest beads-backend-test-bd-close-bulk-without-reason ()
  "Test bd backend close_bulk without reason."
  (should (equal (beads-backend-bd--operation-to-cli-args
                  "close_bulk" '((ids . ("bd-1" "bd-2"))))
                 '("close" "bd-1" "bd-2"))))

(ert-deftest beads-backend-test-bd-close-bulk-registered ()
  "Test bd backend advertises close_bulk support."
  (should (beads-backend-supports-p
           (beads-backend--lookup "bd") "close_bulk")))

(ert-deftest beads-backend-test-bd-no-extra-flags ()
  "Test bd backend has no extra flags."
  (should-not (beads-backend-bd--cli-extra-flags "list"))
  (should-not (beads-backend-bd--cli-extra-flags "duplicates")))

(ert-deftest beads-backend-test-bd-unknown-op-signals ()
  "Test bd backend signals on unknown operation."
  (should-error (beads-backend-bd--operation-to-cli-args "bogus" nil)
                :type 'beads-backend-error))

(ert-deftest beads-backend-test-br-unknown-op-signals ()
  "Test br backend signals on unknown operation."
  (should-error (beads-backend-br--operation-to-cli-args "health" nil)
                :type 'beads-backend-error))

;;; Shared utility tests

(ert-deftest beads-backend-test-alist-to-cli-flags ()
  "Test alist-to-cli-flags conversion."
  (should (equal (beads-backend--alist-to-cli-flags
                  '((status . "open") (priority . 1)))
                 '("--status" "open" "--priority" "1"))))

(ert-deftest beads-backend-test-alist-to-cli-flags-boolean ()
  "Test alist-to-cli-flags with boolean value."
  (should (equal (beads-backend--alist-to-cli-flags '((force . t)))
                 '("--force"))))

(ert-deftest beads-backend-test-alist-to-cli-flags-nil ()
  "Test alist-to-cli-flags skips nil values."
  (should (equal (beads-backend--alist-to-cli-flags '((force . nil)))
                 '())))

(ert-deftest beads-backend-test-build-cli-args ()
  "Test build-cli-args filters by allowed keys."
  (should (equal (beads-backend--build-cli-args
                  "list" '((status . "open") (bogus . "x")) '(status))
                 '("list" "--status" "open"))))

(ert-deftest beads-backend-test-async-no-pty-chars ()
  "Async CLI must use pipe and never leak raw ANSI/pty chars like ]11;? or ^G."
  (unless (executable-find "bd") (ert-skip "no bd"))
  (let ((done nil) (err nil))
    (beads-backend-cli-execute-async "list" nil
      (lambda (e _d) (setq err e done t)))
    (while (not done) (accept-process-output nil 0.1))
    (should-not err)
    (when err (should-not (string-match-p "[\x07\x1b]]11;\\|\\[c" err)))))

(provide 'beads-backend-test)
;;; beads-backend-test.el ends here
