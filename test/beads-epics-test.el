;;; beads-epics-test.el --- Tests for beads-epics.el -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the Beads epic-status view.
;;
;; Test categories:
;; 1. Mode definition tests
;; 2. Keybinding tests
;; 3. Command availability tests
;; 4. Render tests
;; 5. Error handling tests
;; 6. Eligibility predicate tests (interop with both bd CLI and SQL backends)

;;; Code:

(require 'ert)
(require 'beads-epics)

;;; Mode definition tests

(ert-deftest beads-epics-test-mode-defined ()
  "Test that beads-epics-mode is defined."
  (should (fboundp 'beads-epics-mode)))

(ert-deftest beads-epics-test-mode-is-special ()
  "Test that beads-epics-mode is derived from special-mode."
  (with-temp-buffer
    (beads-epics-mode)
    (should (derived-mode-p 'special-mode))
    (should (derived-mode-p 'beads-epics-mode))))

(ert-deftest beads-epics-test-mode-readonly ()
  "Test that beads-epics-mode sets buffer to read-only."
  (with-temp-buffer
    (beads-epics-mode)
    (should buffer-read-only)))

;;; Keybinding tests

(ert-deftest beads-epics-test-keybinding-return ()
  "Test that RET is bound to beads-epics-goto-issue."
  (with-temp-buffer
    (beads-epics-mode)
    (should (eq (lookup-key beads-epics-mode-map (kbd "RET"))
                #'beads-epics-goto-issue))))

(ert-deftest beads-epics-test-keybinding-refresh ()
  "Test that g is bound to beads-epics-refresh."
  (with-temp-buffer
    (beads-epics-mode)
    (should (eq (lookup-key beads-epics-mode-map (kbd "g"))
                #'beads-epics-refresh))))

(ert-deftest beads-epics-test-keybinding-toggle-eligible ()
  "Test that f toggles the eligible-only filter."
  (with-temp-buffer
    (beads-epics-mode)
    (should (eq (lookup-key beads-epics-mode-map (kbd "f"))
                #'beads-epics-toggle-eligible-only))))

(ert-deftest beads-epics-test-keybinding-quit ()
  "Test that q is bound to kill-buffer quit."
  (with-temp-buffer
    (beads-epics-mode)
    (should (eq (lookup-key beads-epics-mode-map (kbd "q"))
                #'beads-core-quit-window-kill-buffer))))

;;; Command availability tests

(ert-deftest beads-epics-test-command-defined ()
  "Test that beads-epics is defined as a command."
  (should (fboundp 'beads-epics))
  (should (commandp 'beads-epics)))

(ert-deftest beads-epics-test-goto-issue-defined ()
  "Test that beads-epics-goto-issue is defined as a command."
  (should (fboundp 'beads-epics-goto-issue))
  (should (commandp 'beads-epics-goto-issue)))

(ert-deftest beads-epics-test-refresh-defined ()
  "Test that beads-epics-refresh is defined as a command."
  (should (fboundp 'beads-epics-refresh))
  (should (commandp 'beads-epics-refresh)))

(ert-deftest beads-epics-test-toggle-eligible-defined ()
  "Test that beads-epics-toggle-eligible-only is defined as a command."
  (should (fboundp 'beads-epics-toggle-eligible-only))
  (should (commandp 'beads-epics-toggle-eligible-only)))

;;; Eligibility predicate tests

(ert-deftest beads-epics-test-eligible-p-json-true-t ()
  "JSON-true encoded as `t' should be eligible."
  (should (beads-epics--eligible-p '((eligible_for_close . t)))))

(ert-deftest beads-epics-test-eligible-p-json-true-keyword ()
  "JSON-true encoded as `:json-true' should be eligible."
  (should (beads-epics--eligible-p '((eligible_for_close . :json-true)))))

(ert-deftest beads-epics-test-eligible-p-json-false-keyword ()
  "JSON-false encoded as `:json-false' (default `json-read') should not be eligible."
  (should-not (beads-epics--eligible-p '((eligible_for_close . :json-false)))))

(ert-deftest beads-epics-test-eligible-p-json-false-nil ()
  "JSON-false encoded as `nil' should not be eligible."
  (should-not (beads-epics--eligible-p '((eligible_for_close . nil)))))

(ert-deftest beads-epics-test-eligible-p-integer-one ()
  "Integer 1 (legacy SQL fallback) should be eligible."
  (should (beads-epics--eligible-p '((eligible_for_close . 1)))))

(ert-deftest beads-epics-test-eligible-p-integer-zero ()
  "Integer 0 (legacy SQL fallback) should not be eligible."
  (should-not (beads-epics--eligible-p '((eligible_for_close . 0)))))

;;; Render tests

(defun beads-epics-test--sample-entries ()
  "Return a sample list of epic-status entries for rendering tests."
  '(((epic . ((id . "bdel-aaa")
              (title . "Sample epic alpha")
              (status . "open")
              (priority . 2)
              (issue_type . "epic")))
     (total_children . 4)
     (closed_children . 4)
     (eligible_for_close . t))
    ((epic . ((id . "bdel-bbb")
              (title . "Sample epic beta")
              (status . "in_progress")
              (priority . 1)
              (issue_type . "epic")))
     (total_children . 3)
     (closed_children . 1)
     (eligible_for_close . :json-false))))

(ert-deftest beads-epics-test-render-empty ()
  "Test that beads-epics--render handles empty list."
  (with-temp-buffer
    (beads-epics-mode)
    (beads-epics--render nil)
    (should (string-match-p "No epics found" (buffer-string)))))

(ert-deftest beads-epics-test-render-empty-eligible-only ()
  "Empty render in eligible-only mode shows distinct message."
  (with-temp-buffer
    (beads-epics-mode)
    (setq beads-epics--eligible-only t)
    (beads-epics--render nil)
    (should (string-match-p "No epics are currently eligible for closure"
                            (buffer-string)))))

(ert-deftest beads-epics-test-render-entries ()
  "Test that beads-epics--render displays epic data."
  (with-temp-buffer
    (beads-epics-mode)
    (beads-epics--render (beads-epics-test--sample-entries))
    (let ((content (buffer-string)))
      (should (string-match-p "bdel-aaa" content))
      (should (string-match-p "Sample epic alpha" content))
      (should (string-match-p "bdel-bbb" content))
      (should (string-match-p "Sample epic beta" content))
      (should (string-match-p "4/4 children closed" content))
      (should (string-match-p "1/3 children closed" content))
      (should (string-match-p "ELIGIBLE FOR CLOSURE" content)))))

(ert-deftest beads-epics-test-render-sets-text-properties ()
  "Test that beads-epics--render sets text properties for navigation."
  (with-temp-buffer
    (beads-epics-mode)
    (beads-epics--render (beads-epics-test--sample-entries))
    (goto-char (point-min))
    (search-forward "bdel-aaa")
    (should (equal (get-text-property (point) 'beads-epic-id) "bdel-aaa"))))

(ert-deftest beads-epics-test-progress-bar ()
  "Test that the progress bar renders the right number of filled cells."
  (let ((bar (beads-epics--progress-bar 5 10 10)))
    (should (= (length bar) 10))
    ;; 5/10 = 50% of 10 = 5 filled cells
    (should (string-match-p "█████░░░░░" bar)))
  (let ((bar (beads-epics--progress-bar 0 0 10)))
    (should (= (length bar) 10))
    (should (string-match-p "░░░░░░░░░░" bar)))
  (let ((bar (beads-epics--progress-bar 10 10 10)))
    (should (= (length bar) 10))
    (should (string-match-p "██████████" bar))))

;;; Error handling tests

(ert-deftest beads-epics-test-goto-no-epic ()
  "Test that beads-epics-goto-issue errors when no epic at point."
  (with-temp-buffer
    (beads-epics-mode)
    (beads-epics--render nil)
    (should-error (beads-epics-goto-issue) :type 'user-error)))

(ert-deftest beads-epics-test-refresh-wrong-mode ()
  "Test that beads-epics-refresh errors outside epics mode."
  (with-temp-buffer
    (should-error (beads-epics-refresh) :type 'user-error)))

(ert-deftest beads-epics-test-toggle-wrong-mode ()
  "Test that beads-epics-toggle-eligible-only errors outside epics mode."
  (with-temp-buffer
    (should-error (beads-epics-toggle-eligible-only) :type 'user-error)))

;;; Client integration tests (mocked)

(ert-deftest beads-epics-test-fetch-passes-eligible-only ()
  "Test that beads-epics--fetch passes ELIGIBLE-ONLY through to the client."
  (let ((captured nil))
    (cl-letf (((symbol-function 'beads-client-epic-status)
               (lambda (&optional eligible-only)
                 (setq captured eligible-only)
                 nil)))
      (beads-epics--fetch t)
      (should (eq captured t))
      (beads-epics--fetch nil)
      (should (eq captured nil)))))

(provide 'beads-epics-test)
;;; beads-epics-test.el ends here
