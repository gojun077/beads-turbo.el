;;; beads-list-test.el --- Tests for beads-list.el -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the Beads issue list mode.
;;
;; Test categories:
;; 1. Formatter tests - test formatters without daemon
;; 3. Mode tests - test mode setup and keybindings
;; 4. Integration tests - test with actual daemon (tagged :integration)
;;
;; Note on test isolation:
;; Read-only integration tests may inspect the current repo when
;; explicitly enabled.  Write-path coverage belongs in temp-project E2E
;; tests rather than this file's repo-backed integration tests.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'beads-list)
(require 'beads-core)
(require 'beads-transient)
(require 'beads-test-helpers)
(require 'beads-backend-dolt-sql)

(declare-function beads-create-issue "beads-transient")
(declare-function beads-filter-menu "beads-transient")
(declare-function beads-menu "beads-transient")
(declare-function beads-search "beads-transient")

;;; Formatter tests (no daemon needed)

(ert-deftest beads-list-test-core-idle-backend-keeps-session-with-other-buffer ()
  "Test idle backend cleanup is skipped while another beads buffer exists."
  (let ((buffer-a (generate-new-buffer " *beads-idle-a*"))
        (buffer-b (generate-new-buffer " *beads-idle-b*"))
        (stop-count 0))
    (unwind-protect
        (progn
          (with-current-buffer buffer-a
            (beads-org-list-mode))
          (with-current-buffer buffer-b
            (beads-org-list-mode))
          (cl-letf (((symbol-function 'buffer-list)
                     (lambda (&optional _frame) (list buffer-a buffer-b)))
                    ((symbol-function 'beads-backend-dolt-sql-stop-idle-session)
                     (lambda () (cl-incf stop-count))))
            (with-current-buffer buffer-a
              (beads-core--maybe-stop-idle-backend))
            (should (zerop stop-count))))
      (when (buffer-live-p buffer-a) (kill-buffer buffer-a))
      (when (buffer-live-p buffer-b) (kill-buffer buffer-b)))))

(ert-deftest beads-list-test-core-idle-backend-stops-after-last-buffer ()
  "Test idle backend cleanup runs when the last beads buffer closes."
  (let ((buffer (generate-new-buffer " *beads-idle-last*"))
        (stop-count 0))
    (unwind-protect
        (progn
          (with-current-buffer buffer
            (beads-org-list-mode))
          (cl-letf (((symbol-function 'buffer-list)
                     (lambda (&optional _frame) (list buffer)))
                    ((symbol-function 'beads-backend-dolt-sql-stop-idle-session)
                     (lambda () (cl-incf stop-count))))
            (with-current-buffer buffer
              (beads-core--maybe-stop-idle-backend))
            (should (= stop-count 1))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))



(ert-deftest beads-list-test-format-status-open ()
  "Test that beads--format-status formats open status correctly."
  (let ((issue '((status . "open"))))
    (let ((result (beads--format-status issue)))
      (should (equal result "open"))
      (should (eq (get-text-property 0 'face result) 'beads-status-open)))))

(ert-deftest beads-list-test-format-status-in-progress ()
  "Test that beads--format-status formats in_progress status with face."
  (let ((issue '((status . "in_progress"))))
    (let ((result (beads--format-status issue)))
      (should (equal result "in_progress"))
      (should (eq (get-text-property 0 'face result) 'beads-status-in-progress)))))

(ert-deftest beads-list-test-format-status-closed ()
  "Test that beads--format-status formats closed status with face."
  (let ((issue '((status . "closed"))))
    (let ((result (beads--format-status issue)))
      (should (equal result "closed"))
      (should (eq (get-text-property 0 'face result) 'beads-status-closed)))))

(ert-deftest beads-list-test-closed-status-face-is-muted-gray ()
  "Closed status uses a muted gray face instead of strong org green."
  (should (equal (face-attribute 'beads-status-closed :foreground nil 'default)
                 "light gray")))

(ert-deftest beads-list-test-format-status-blocked ()
  "Test that beads--format-status formats blocked status with face."
  (let ((issue '((status . "blocked"))))
    (let ((result (beads--format-status issue)))
      (should (equal result "blocked"))
      (should (eq (get-text-property 0 'face result) 'beads-status-blocked)))))

(ert-deftest beads-list-test-format-status-hooked ()
  "Test that beads--format-status formats hooked status with face."
  (let ((issue '((status . "hooked"))))
    (let ((result (beads--format-status issue)))
      (should (equal result "hooked"))
      (should (eq (get-text-property 0 'face result) 'beads-status-hooked)))))

(ert-deftest beads-list-test-format-priority-p0 ()
  "Test that beads--format-priority formats P0 with bold red face."
  (let ((issue '((priority . 0))))
    (let ((result (beads--format-priority issue)))
      (should (equal result "P0"))
      (should (eq (get-text-property 0 'face result) 'beads-priority-p0)))))

(ert-deftest beads-list-test-format-priority-p1 ()
  "Test that beads--format-priority formats P1 with orange face."
  (let ((issue '((priority . 1))))
    (let ((result (beads--format-priority issue)))
      (should (equal result "P1"))
      (should (eq (get-text-property 0 'face result) 'beads-priority-p1)))))

(ert-deftest beads-list-test-format-priority-p2 ()
  "Test that beads--format-priority formats P2 with default face."
  (let ((issue '((priority . 2))))
    (let ((result (beads--format-priority issue)))
      (should (equal result "P2"))
      (should (eq (get-text-property 0 'face result) 'default)))))

(ert-deftest beads-list-test-format-priority-p3 ()
  "Test that beads--format-priority formats P3 correctly."
  (let ((issue '((priority . 3))))
    (should (equal (beads--format-priority issue) "P3"))))

(ert-deftest beads-list-test-format-priority-p4 ()
  "Test that beads--format-priority formats P4 correctly."
  (let ((issue '((priority . 4))))
    (should (equal (beads--format-priority issue) "P4"))))

(ert-deftest beads-list-test-format-type-full-style ()
  "Test that beads--format-type returns full type names when style is full."
  (let ((beads-type-style 'full)
        (beads-type-glyph nil))
    (should (equal (beads--format-type '((issue_type . "bug"))) "bug"))
    (should (equal (beads--format-type '((issue_type . "feature"))) "feature"))
    (should (equal (beads--format-type '((issue_type . "task"))) "task"))
    (should (equal (beads--format-type '((issue_type . "epic"))) "epic"))
    (should (equal (beads--format-type '((issue_type . "chore"))) "chore"))
    (should (equal (beads--format-type '((issue_type . "gate"))) "gate"))
    (should (equal (beads--format-type '((issue_type . "convoy"))) "convoy"))
    (should (equal (beads--format-type '((issue_type . "rig"))) "rig"))
    (should (equal (beads--format-type '((issue_type . "agent"))) "agent"))
    (should (equal (beads--format-type '((issue_type . "role"))) "role"))))

(ert-deftest beads-list-test-format-type-short-style ()
  "Test that beads--format-type abbreviates types when style is short."
  (let ((beads-type-style 'short)
        (beads-type-glyph nil))
    (should (equal (beads--format-type '((issue_type . "bug"))) "bug"))
    (should (equal (beads--format-type '((issue_type . "feature"))) "feat"))
    (should (equal (beads--format-type '((issue_type . "task"))) "task"))
    (should (equal (beads--format-type '((issue_type . "epic"))) "epic"))
    (should (equal (beads--format-type '((issue_type . "chore"))) "chor"))
    (should (equal (beads--format-type '((issue_type . "gate"))) "gate"))
    (should (equal (beads--format-type '((issue_type . "convoy"))) "conv"))
    (should (equal (beads--format-type '((issue_type . "rig"))) "rig"))
    (should (equal (beads--format-type '((issue_type . "agent"))) "agnt"))
    (should (equal (beads--format-type '((issue_type . "role"))) "role"))))

(ert-deftest beads-list-test-format-type-special-faces ()
  "Test that special types get appropriate faces."
  (let ((beads-type-style 'full)
        (beads-type-glyph nil))
    (should (eq (get-text-property 0 'face (beads--format-type '((issue_type . "gate"))))
                'beads-type-gate))
    (should (eq (get-text-property 0 'face (beads--format-type '((issue_type . "convoy"))))
                'beads-type-convoy))
    (should (eq (get-text-property 0 'face (beads--format-type '((issue_type . "agent"))))
                'beads-type-agent))
    (should (eq (get-text-property 0 'face (beads--format-type '((issue_type . "role"))))
                'beads-type-role))
    (should (eq (get-text-property 0 'face (beads--format-type '((issue_type . "rig"))))
                'beads-type-rig))))

(ert-deftest beads-list-test-format-type-regular-no-face ()
  "Test that regular types have no special face."
  (let ((beads-type-style 'full)
        (beads-type-glyph nil))
    (should (null (get-text-property 0 'face (beads--format-type '((issue_type . "bug"))))))
    (should (null (get-text-property 0 'face (beads--format-type '((issue_type . "feature"))))))
    (should (null (get-text-property 0 'face (beads--format-type '((issue_type . "task"))))))))

(ert-deftest beads-list-test-format-type-glyphs ()
  "Test that glyphs are prepended when beads-type-glyph is non-nil."
  (let ((beads-type-style 'full)
        (beads-type-glyph t))
    (should (string-prefix-p "■ " (beads--format-type '((issue_type . "gate")))))
    (should (string-prefix-p "▶ " (beads--format-type '((issue_type . "convoy")))))
    (should (string-prefix-p "◉ " (beads--format-type '((issue_type . "agent")))))
    (should (string-prefix-p "● " (beads--format-type '((issue_type . "role")))))
    (should (string-prefix-p "⚙ " (beads--format-type '((issue_type . "rig")))))))

(ert-deftest beads-list-test-format-type-no-glyph-regular ()
  "Test that regular types have no glyph even when glyphs enabled."
  (let ((beads-type-style 'full)
        (beads-type-glyph t))
    (should (equal (beads--format-type '((issue_type . "bug"))) "bug"))
    (should (equal (beads--format-type '((issue_type . "task"))) "task"))))

(ert-deftest beads-list-test-format-type-glyph-with-short ()
  "Test that glyphs work with short style."
  (let ((beads-type-style 'short)
        (beads-type-glyph t))
    (should (equal (beads--format-type '((issue_type . "convoy"))) "▶ conv"))
    (should (equal (beads--format-type '((issue_type . "agent"))) "◉ agnt"))))

(ert-deftest beads-list-test-format-type-unknown ()
  "Test that beads--format-type returns unknown types unchanged."
  (let ((beads-type-style 'full)
        (beads-type-glyph nil))
    (should (equal (beads--format-type '((issue_type . "unknown"))) "unknown"))))









;;; Entry conversion tests (mocked)











(ert-deftest beads-list-test-org-heading-open-issue ()
  "Open issues render as compact TODO headings with type tags."
  (let ((issue '((id . "bd-open")
                 (title . "Open issue")
                 (status . "open")
                 (priority . 1)
                 (issue_type . "task"))))
    (should (equal (beads-list--org-heading issue)
                   "* TODO [#B] Open issue :task:"))))

(ert-deftest beads-list-test-org-heading-in-progress-issue ()
  "In-progress issues render with WIP keyword while preserving raw status metadata."
  (let ((issue '((id . "bd-next")
                 (title . "Doing it")
                 (status . "in_progress")
                 (priority . 0)
                 (issue_type . "feature"))))
    (should (equal (beads-list--org-heading issue 2)
                   "** WIP [#A] Doing it :feature:"))))

(ert-deftest beads-list-test-org-heading-blocked-issue ()
  "Blocked issues render with WAIT TODO keyword."
  (let ((issue '((id . "bd-wait")
                 (title . "Waiting")
                 (status . "blocked")
                 (priority . 2)
                 (issue_type . "bug"))))
    (should (equal (beads-list--org-heading issue)
                   "* WAIT [#C] Waiting :bug:"))))

(ert-deftest beads-list-test-org-heading-closed-issue ()
  "Closed issues render with DONE TODO keyword."
  (let ((issue '((id . "bd-done")
                 (title . "Finished")
                 (status . "closed")
                 (priority . 3)
                 (issue_type . "chore"))))
    (should (equal (beads-list--org-heading issue)
                   "* DONE Finished :chore:"))))

(ert-deftest beads-list-test-org-todo-mapping-waiting-statuses ()
  "Hooked and deferred statuses share the WAIT org TODO keyword."
  (should (equal (beads-list--org-todo-keyword '((status . "hooked"))) "WAIT"))
  (should (equal (beads-list--org-todo-keyword '((status . "deferred"))) "WAIT")))

(ert-deftest beads-list-test-org-todo-status-edit-mapping ()
  "Editable org TODO keywords map back to beads statuses."
  (should (equal (beads-list--org-status-for-todo-keyword "TODO") "open"))
  (should (equal (beads-list--org-status-for-todo-keyword "WIP") "in_progress"))
  (should (equal (beads-list--org-status-for-todo-keyword "WAIT") "blocked"))
  (should (equal (beads-list--org-status-for-todo-keyword "DONE") "closed")))

(ert-deftest beads-list-test-org-todo-cycle-keywords ()
  "Org list status editing cycles through TODO, WIP, WAIT, and DONE."
  (should (equal (beads-list--org-next-todo-keyword "TODO") "WIP"))
  (should (equal (beads-list--org-next-todo-keyword "WIP") "WAIT"))
  (should (equal (beads-list--org-next-todo-keyword "WAIT") "DONE"))
  (should (equal (beads-list--org-next-todo-keyword "DONE") "TODO")))

(ert-deftest beads-list-test-org-properties-include-stable-lookup-and-metadata ()
  "Org properties include BEADS_ID and non-noisy metadata."
  (let* ((issue '((id . "bd-meta")
                  (title . "Metadata")
                  (status . "open")
                  (issue_type . "task")
                  (priority . 2)
                  (assignee . "alice")
                  (labels . ["ui" "urgent"])
                  (parent . "bd-parent")
                  (parent_id . "bd-parent-id")
                  (dependency_count . 1)
                  (dependent_count . 2)
                  (created_at . "2026-05-24T00:00:00Z")
                  (updated_at . "2026-05-24T01:00:00Z")
                  (closed_at . "")
                  (external_ref . "JIRA-123")
                  (spec_id . "SPEC-7")
                  (source_repo . "codeberg.org/gojun077/beads.el")))
         (properties (beads-list--org-properties issue)))
    (should (equal (cdr (assoc "BEADS_ID" properties)) "bd-meta"))
    (should (equal (cdr (assoc "BEADS_STATUS" properties)) "open"))
    (should (equal (cdr (assoc "BEADS_LABELS" properties)) "ui,urgent"))
    (should (equal (cdr (assoc "BEADS_PARENT" properties)) "bd-parent"))
    (should (equal (cdr (assoc "BEADS_DEPENDENCY_COUNT" properties)) "1"))
    (should (equal (cdr (assoc "BEADS_DEPENDENT_COUNT" properties)) "2"))
    (should (equal (cdr (assoc "BEADS_EXTERNAL_REF" properties)) "JIRA-123"))
    (should (equal (cdr (assoc "BEADS_SPEC_ID" properties)) "SPEC-7"))
    (should (equal (cdr (assoc "BEADS_SOURCE_REPO" properties))
                   "codeberg.org/gojun077/beads.el"))
    (should-not (assoc "BEADS_CLOSED_AT" properties))))

(ert-deftest beads-list-test-org-property-drawer-format ()
  "Org property drawer stores machine-readable metadata below headings."
  (let ((issue '((id . "bd-drawer")
                 (status . "closed")
                 (issue_type . "task"))))
    (should (equal (beads-list--org-property-drawer issue)
                   ":PROPERTIES:\n:BEADS_ID: bd-drawer\n:BEADS_STATUS: closed\n:BEADS_TYPE: task\n:END:"))))

(ert-deftest beads-list-test-org-render-flat-issues ()
  "Flat issues render as sibling org headings with property drawers."
  (let ((issues '(((id . "bd-a")
                   (title . "First")
                   (status . "open")
                   (priority . 1)
                   (issue_type . "task"))
                  ((id . "bd-b")
                   (title . "Second")
                   (status . "in_progress")
                   (priority . 0)
                   (issue_type . "feature")))))
    (should (equal (beads-list-render-org issues)
                   "* TODO [#B] First :task:\n:PROPERTIES:\n:BEADS_ID: bd-a\n:BEADS_STATUS: open\n:BEADS_TYPE: task\n:BEADS_PRIORITY: 1\n:END:\n* WIP [#A] Second :feature:\n:PROPERTIES:\n:BEADS_ID: bd-b\n:BEADS_STATUS: in_progress\n:BEADS_TYPE: feature\n:BEADS_PRIORITY: 0\n:END:"))))

(ert-deftest beads-list-test-org-render-nested-issues-use-heading-depth ()
  "Parent-child relationships render with nested heading levels."
  (let ((issues '(((id . "bd-parent")
                   (title . "Parent")
                   (status . "open")
                   (priority . 2)
                   (issue_type . "epic"))
                  ((id . "bd-child")
                   (title . "Child")
                   (status . "open")
                   (priority . 1)
                   (issue_type . "task")
                   (parent . "bd-parent"))
                  ((id . "bd-grandchild")
                   (title . "Grandchild")
                   (status . "open")
                   (issue_type . "bug")
                   (parent . "bd-child")))))
    (should (equal (beads-list-render-org issues)
                   "* TODO [#C] Parent :epic:\n:PROPERTIES:\n:BEADS_ID: bd-parent\n:BEADS_STATUS: open\n:BEADS_TYPE: epic\n:BEADS_PRIORITY: 2\n:END:\n** TODO [#B] Child :task:\n:PROPERTIES:\n:BEADS_ID: bd-child\n:BEADS_STATUS: open\n:BEADS_TYPE: task\n:BEADS_PRIORITY: 1\n:BEADS_PARENT: bd-parent\n:END:\n*** TODO Grandchild :bug:\n:PROPERTIES:\n:BEADS_ID: bd-grandchild\n:BEADS_STATUS: open\n:BEADS_TYPE: bug\n:BEADS_PARENT: bd-child\n:END:"))))

(ert-deftest beads-list-test-org-render-closed-blocked-and-orphan-parent ()
  "Closed, blocked, and orphan-parent issues render deterministically."
  (let ((issues '(((id . "bd-closed")
                   (title . "Closed")
                   (status . "closed")
                   (priority . 3)
                   (issue_type . "chore")
                   (closed_at . "2026-05-24T02:00:00Z"))
                  ((id . "bd-blocked")
                   (title . "Blocked")
                   (status . "blocked")
                   (priority . 2)
                   (issue_type . "bug")
                   (dependency_count . 2))
                  ((id . "bd-orphan")
                   (title . "Orphan")
                   (status . "open")
                   (issue_type . "task")
                   (parent . "bd-missing")))))
    (should (equal (beads-list-render-org issues)
                   "* DONE Closed :chore:\n:PROPERTIES:\n:BEADS_ID: bd-closed\n:BEADS_STATUS: closed\n:BEADS_TYPE: chore\n:BEADS_PRIORITY: 3\n:BEADS_CLOSED_AT: 2026-05-24T02:00:00Z\n:END:\n* WAIT [#C] Blocked :bug:\n:PROPERTIES:\n:BEADS_ID: bd-blocked\n:BEADS_STATUS: blocked\n:BEADS_TYPE: bug\n:BEADS_PRIORITY: 2\n:BEADS_DEPENDENCY_COUNT: 2\n:END:\n* TODO Orphan :task:\n:PROPERTIES:\n:BEADS_ID: bd-orphan\n:BEADS_STATUS: open\n:BEADS_TYPE: task\n:BEADS_PARENT: bd-missing\n:END:"))))

(ert-deftest beads-list-test-org-render-sanitizes-multiline-values-and-labels ()
  "Special characters, multiline values, nil values, and labels render safely."
  (let ((issue '((id . "bd-safe")
                 (title . "Needs\nnewline :tag:")
                 (status . "open")
                 (issue_type . "custom/type")
                 (assignee)
                 (labels . ["ui label" "urgent\nnow"])
                 (external_ref . "REF\n123"))))
    (should (equal (beads-list-render-org (list issue))
                   "* TODO Needs newline :tag: :custom_type:\n:PROPERTIES:\n:BEADS_ID: bd-safe\n:BEADS_STATUS: open\n:BEADS_TYPE: custom/type\n:BEADS_LABELS: ui label,urgent now\n:BEADS_EXTERNAL_REF: REF 123\n:END:"))))

(ert-deftest beads-list-test-org-render-each-issue-has-one-beads-id ()
  "Rendered issues have exactly one BEADS_ID property each."
  (let* ((issues '(((id . "bd-parent") (title . "Parent") (parent_id . "ignored"))
                   ((id . "bd-child") (title . "Child") (parent . "bd-parent"))))
         (text (beads-list-render-org issues))
         (start 0)
         (count 0))
    (while (string-match "^:BEADS_ID:" text start)
      (cl-incf count)
      (setq start (match-end 0)))
    (should (= count (length issues)))))



;;; Mode tests (no daemon)









(ert-deftest beads-list-test-mode-sets-sort-key ()
  "Test that beads-org-list-mode sets initial sort key to Date (descending)."
  (with-temp-buffer
    (beads-org-list-mode)
    (should (equal beads-list--sort-key '("Date" . t)))))

(ert-deftest beads-list-test-mode-keybindings ()
  "Test that beads-org-list-mode sets up keybindings correctly."
  (with-temp-buffer
    (beads-org-list-mode)
    (should (eq (lookup-key beads-org-list-mode-map (kbd "g")) #'beads-org-list-refresh))
    (should (eq (lookup-key beads-org-list-mode-map (kbd "RET")) #'beads-list-goto-issue))
    (should (eq (lookup-key beads-org-list-mode-map (kbd "q")) #'beads-list-quit))))



(ert-deftest beads-list-test-org-list-mode-derived-from-org ()
  "Org list mode derives from org-mode."
  (with-temp-buffer
    (beads-org-list-mode)
    (should (derived-mode-p 'org-mode))
    (should (derived-mode-p 'beads-org-list-mode))
    (should (equal (cdr (assoc "DONE" org-todo-keyword-faces))
                   'beads-status-closed))
    (let ((inhibit-read-only t))
      (insert "* WAIT Waiting\n")
      (goto-char (point-min))
      (should (equal (beads-list--org-current-todo-keyword) "WAIT")))
    (should buffer-read-only)
    (should (local-variable-p 'beads-org-list--project-root))))

(ert-deftest beads-list-test-org-list-mode-keybindings ()
  "Org list mode binds list refresh/navigation/edit keys."
  (with-temp-buffer
    (beads-org-list-mode)
    (should (eq (lookup-key beads-org-list-mode-map (kbd "g"))
                #'beads-org-list-refresh))
    (should (eq (lookup-key beads-org-list-mode-map (kbd "RET"))
                #'beads-list-goto-issue))
    (should (eq (lookup-key beads-org-list-mode-map (kbd "c"))
                #'beads-create-issue))
    (should (eq (lookup-key beads-org-list-mode-map (kbd "f"))
                #'beads-filter-menu))
    (should (eq (lookup-key beads-org-list-mode-map (kbd "/"))
                #'beads-search))
    (should (eq (lookup-key beads-org-list-mode-map (kbd "E"))
                #'beads-list-edit-form))
    (should (eq (lookup-key beads-org-list-mode-map (kbd "P"))
                #'beads-preview-mode))
    (should (eq (lookup-key beads-org-list-mode-map (kbd "H"))
                #'beads-org-list-hierarchy-show))
    (should (eq (lookup-key beads-org-list-mode-map (kbd "C-c C-t"))
                #'beads-org-list-todo))
    (should (eq (lookup-key beads-org-list-mode-map (kbd "s"))
                #'beads-list-toggle-sort-mode))
    (should (eq (lookup-key beads-org-list-mode-map (kbd "m"))
                #'beads-list-mark))
    (should (eq (lookup-key beads-org-list-mode-map (kbd "u"))
                #'beads-list-unmark))
    (should (eq (lookup-key beads-org-list-mode-map (kbd "B"))
                beads-list-bulk-map))
    (should (eq (lookup-key beads-org-list-mode-map (kbd "x"))
                #'beads-list-bulk-close))
    (should (eq (lookup-key beads-org-list-mode-map (kbd "a"))
                #'beads-list-quick-assign))
    (should (eq (lookup-key beads-org-list-mode-map (kbd "?"))
                #'beads-menu))
    (should (eq (lookup-key beads-org-list-mode-map (kbd "C-c m"))
                #'beads-menu))
    (should (eq (lookup-key beads-org-list-mode-map (kbd "n"))
                #'org-next-visible-heading))
    (should (eq (lookup-key beads-org-list-mode-map (kbd "p"))
                #'org-previous-visible-heading))
    (should (eq (lookup-key beads-org-list-mode-map (kbd "TAB"))
                #'org-cycle))))

(ert-deftest beads-list-test-org-list-refresh-mocked ()
  "Org list refresh renders generated org text from bd data."
  (let ((issues '(((id . "bd-a")
                   (title . "First")
                   (status . "open")
                   (priority . 1)
                   (issue_type . "task"))
                  ((id . "bd-b")
                   (title . "Second")
                   (status . "closed")
                   (issue_type . "bug"))
                  ((id . "bd-c")
                   (title . "Third")
                   (status . "in_progress")
                   (priority . 0)
                   (issue_type . "feature")))))
    (with-temp-buffer
      (beads-org-list-mode)
      (cl-letf (((symbol-function 'beads-cache-refresh)
                 (lambda (&rest _args) (cons t issues))))
        (beads-org-list-refresh t)
        (should (equal beads-list--issues issues))
        (should (null buffer-file-name))
        (should (string-match-p "^#\\+TITLE: Beads Issues" (buffer-string)))
        (should (string-match-p "^#\\+TODO: TODO WIP WAIT | DONE" (buffer-string)))
        (should (string-match-p "^\\* Ready" (buffer-string)))
        (should (string-match-p "^\\*\\* TODO \\[#B\\] First :task:" (buffer-string)))
        (should (string-match-p "^\\* In Progress" (buffer-string)))
        (should (string-match-p "^\\*\\* WIP \\[#A\\] Third :feature:" (buffer-string)))
        (should (string-match-p "^\\* Completed" (buffer-string)))
        (should (string-match-p "^\\*\\* DONE Second :bug:" (buffer-string)))))))

(ert-deftest beads-list-test-org-list-legacy-sort-by-title ()
  "Legacy `beads-sort-by-title' reorders the org list view."
  (let ((issues '(((id . "bd-b")
                   (title . "Beta")
                   (status . "open"))
                  ((id . "bd-a")
                   (title . "Alpha")
                   (status . "open")))))
    (with-temp-buffer
      (beads-org-list-mode)
      (cl-letf (((symbol-function 'beads-cache-refresh)
                 (lambda (&rest _args) (cons t issues))))
        (beads-org-list-refresh t)
        (beads-sort-by-title)
        (should (eq beads-list--sort-mode-override 'column))
        (should (equal beads-list--sort-key '("Title" . nil)))
        (should (< (string-match-p "Alpha" (buffer-string))
                   (string-match-p "Beta" (buffer-string))))))))

(ert-deftest beads-list-test-org-list-legacy-sort-by-priority ()
  "Legacy `beads-sort-by-priority' maps to the Pri column in org view."
  (let ((issues '(((id . "bd-low")
                   (title . "Low priority")
                   (status . "open")
                   (priority . 2))
                  ((id . "bd-high")
                   (title . "High priority")
                   (status . "open")
                   (priority . 0)))))
    (with-temp-buffer
      (beads-org-list-mode)
      (cl-letf (((symbol-function 'beads-cache-refresh)
                 (lambda (&rest _args) (cons t issues))))
        (beads-org-list-refresh t)
        (beads-sort-by-priority)
        (should (equal beads-list--sort-key '("Pri" . nil)))
        (should (< (string-match-p "High priority" (buffer-string))
                   (string-match-p "Low priority" (buffer-string))))))))

(ert-deftest beads-list-test-org-list-legacy-sort-sectioned ()
  "Legacy `beads-sort-sectioned' restores sectioned org rendering."
  (let ((issues '(((id . "bd-open")
                   (title . "Open issue")
                   (status . "open"))
                  ((id . "bd-closed")
                   (title . "Closed issue")
                   (status . "closed")))))
    (with-temp-buffer
      (beads-org-list-mode)
      (let ((beads-list--sort-mode-override 'column))
        (cl-letf (((symbol-function 'beads-cache-refresh)
                   (lambda (&rest _args) (cons t issues))))
          (beads-sort-sectioned)
          (should (eq beads-list--sort-mode-override 'sectioned))
          (should (string-match-p "^\\* Ready" (buffer-string)))
          (should (string-match-p "^\\* Completed" (buffer-string))))))))

(ert-deftest beads-list-test-org-list-refresh-applies-filter-marked-and-sections ()
  "Org refresh applies list model filters and tree-safe section grouping."
  (let ((issues '(((id . "bd-ready")
                   (title . "Ready")
                   (status . "open")
                   (priority . 2))
                  ((id . "bd-blocked-parent")
                   (title . "Blocked parent")
                   (status . "blocked")
                   (priority . 1))
                  ((id . "bd-closed-child")
                   (title . "Closed child")
                   (status . "closed")
                   (parent . "bd-blocked-parent"))
                  ((id . "bd-closed-root")
                   (title . "Closed root")
                   (status . "closed")))))
    (with-temp-buffer
      (beads-org-list-mode)
      (let ((beads-list--filter (beads-filter-not-closed))
            (beads-list--marked '("bd-blocked-parent"))
            (beads-list--show-only-marked t))
        (cl-letf (((symbol-function 'beads-cache-refresh)
                   (lambda (&rest _args) (cons t issues))))
          (beads-org-list-refresh t)
          (should (equal (mapcar (lambda (issue) (alist-get 'id issue))
                                 beads-list--issues)
                         '("bd-ready" "bd-blocked-parent")))
          (should (string-match-p "^\\* Blocked" (buffer-string)))
          (should (string-match-p "^\\*\\* WAIT \\[#B\\] Blocked parent" (buffer-string)))
          (should-not (string-match-p "^\\* Ready" (buffer-string)))
          (should-not (string-match-p "Closed child" (buffer-string)))
          (should-not (string-match-p "Closed root" (buffer-string))))))))

(ert-deftest beads-list-test-org-mark-display-uses-overlays ()
  "Org marks are displayed visually without changing generated org text."
  (let ((issues '(((id . "bd-a") (title . "First") (status . "open"))
                  ((id . "bd-b") (title . "Second") (status . "open")))))
    (with-temp-buffer
      (beads-org-list-mode)
      (cl-letf (((symbol-function 'beads-cache-refresh)
                 (lambda (&rest _args) (cons t issues))))
        (beads-org-list-refresh t)
        (let ((before (buffer-string)))
          (should (beads-list--org-goto-id "bd-b"))
          (beads-list-mark)
          (should (equal beads-list--marked '("bd-b")))
          (should (= (length beads-list--org-mark-overlays) 1))
          (should (equal (overlay-get (car beads-list--org-mark-overlays)
                                      'before-string)
                         (propertize "★ " 'face 'bold)))
          (should (equal (buffer-string) before))
          (should (equal (beads-list--org-id-at-point) "bd-a")))))))

(ert-deftest beads-list-test-org-unmark-all-clears-mark-overlays ()
  "Unmarking all org headings removes visual mark indicators."
  (let ((issues '(((id . "bd-a") (title . "First") (status . "open")))))
    (with-temp-buffer
      (beads-org-list-mode)
      (cl-letf (((symbol-function 'beads-cache-refresh)
                 (lambda (&rest _args) (cons t issues))))
        (beads-org-list-refresh t)
        (should (beads-list--org-goto-id "bd-a"))
        (beads-list-mark)
        (should beads-list--org-mark-overlays)
        (beads-list-unmark-all)
        (should-not beads-list--marked)
        (should-not beads-list--org-mark-overlays)))))

(ert-deftest beads-list-test-org-marked-only-refresh-renders-marked-issue ()
  "Marked-only org rendering uses the shared marked ID filter."
  (let ((issues '(((id . "bd-a") (title . "First") (status . "open"))
                  ((id . "bd-b") (title . "Second") (status . "open")))))
    (with-temp-buffer
      (beads-org-list-mode)
      (let ((beads-list--marked '("bd-b"))
            (beads-list--show-only-marked t))
        (cl-letf (((symbol-function 'beads-cache-refresh)
                   (lambda (&rest _args) (cons t issues))))
          (beads-org-list-refresh t)
          (should (string-match-p "Second" (buffer-string)))
          (should-not (string-match-p "First" (buffer-string)))
          (should (= (length beads-list--org-mark-overlays) 1)))))))

(ert-deftest beads-list-test-org-todo-command-updates-status-at-point ()
  "C-c C-t in org list cycles the current issue status through bd statuses."
  (let ((updated nil)
        (refreshed nil)
        (issues '(((id . "bd-a") (title . "First") (status . "open"))
                  ((id . "bd-b") (title . "Second") (status . "blocked")))))
    (with-temp-buffer
      (beads-org-list-mode)
      (let ((inhibit-read-only t)
            (beads-list--issues issues))
        (insert "* TODO First\n:PROPERTIES:\n:BEADS_ID: bd-a\n:END:\n* WAIT Second\n:PROPERTIES:\n:BEADS_ID: bd-b\n:END:\n")
        (should (beads-list--org-goto-id "bd-a"))
        (cl-letf (((symbol-function 'beads-client-update)
                   (lambda (id &rest args)
                     (setq updated (cons id args))))
                  ((symbol-function 'beads-org-list-refresh)
                   (lambda (&optional _silent) (setq refreshed t))))
          (beads-org-list-todo)
          (should (equal updated '("bd-a" :status "in_progress")))
          (should refreshed))))))

(ert-deftest beads-list-test-org-todo-command-cycles-wip-to-blocked ()
  "C-c C-t in org list cycles WIP headings to the blocked beads status."
  (let ((updated nil)
        (refreshed nil)
        (issues '(((id . "bd-a") (title . "First") (status . "in_progress")))))
    (with-temp-buffer
      (beads-org-list-mode)
      (let ((inhibit-read-only t)
            (beads-list--issues issues))
        (insert "* WIP First\n:PROPERTIES:\n:BEADS_ID: bd-a\n:END:\n")
        (goto-char (point-min))
        (cl-letf (((symbol-function 'beads-client-update)
                   (lambda (id &rest args)
                     (setq updated (cons id args))))
                  ((symbol-function 'beads-org-list-refresh)
                   (lambda (&optional _silent) (setq refreshed t))))
          (beads-org-list-todo)
          (should (equal updated '("bd-a" :status "blocked")))
          (should refreshed))))))

(ert-deftest beads-list-test-org-todo-command-cycles-wait-to-closed ()
  "C-c C-t in org list cycles WAIT headings to the closed beads status."
  (let ((updated nil)
        (refreshed nil)
        (issues '(((id . "bd-a") (title . "First") (status . "blocked")))))
    (with-temp-buffer
      (beads-org-list-mode)
      (let ((inhibit-read-only t)
            (beads-list--issues issues))
        (insert "* WAIT First\n:PROPERTIES:\n:BEADS_ID: bd-a\n:END:\n")
        (goto-char (point-min))
        (cl-letf (((symbol-function 'beads-client-update)
                   (lambda (id &rest args)
                     (setq updated (cons id args))))
                  ((symbol-function 'beads-org-list-refresh)
                   (lambda (&optional _silent) (setq refreshed t))))
          (beads-org-list-todo)
          (should (equal updated '("bd-a" :status "closed")))
          (should refreshed))))))

(ert-deftest beads-list-test-org-todo-command-targets-containing-heading ()
  "Org list TODO editing resolves the containing issue from body text."
  (let ((updated nil)
        (issues '(((id . "bd-a") (title . "First") (status . "closed")))))
    (with-temp-buffer
      (beads-org-list-mode)
      (let ((inhibit-read-only t)
            (beads-list--issues issues))
        (insert "* DONE First\n:PROPERTIES:\n:BEADS_ID: bd-a\n:END:\nBody\n")
        (goto-char (point-min))
        (search-forward "Body")
        (cl-letf (((symbol-function 'beads-client-update)
                   (lambda (id &rest args)
                     (setq updated (cons id args))))
                  ((symbol-function 'beads-org-list-refresh)
                   (lambda (&optional _silent) nil)))
          (beads-org-list-todo)
          (should (equal updated '("bd-a" :status "open"))))))))

(ert-deftest beads-list-test-org-bulk-status-targets-issue-at-point-without-marks ()
  "Org bulk operations use the heading at point when no marks exist."
  (let ((updated nil)
        (refreshed nil)
        (issues '(((id . "bd-a") (title . "First") (status . "open"))
                  ((id . "bd-b") (title . "Second") (status . "open")))))
    (with-temp-buffer
      (beads-org-list-mode)
      (let ((inhibit-read-only t)
            (beads-list--issues issues))
        (insert "* TODO First\n:PROPERTIES:\n:BEADS_ID: bd-a\n:END:\n* TODO Second\n:PROPERTIES:\n:BEADS_ID: bd-b\n:END:\n")
        (should (beads-list--org-goto-id "bd-b"))
        (cl-letf (((symbol-function 'beads-client-update-bulk)
                   (lambda (ids &rest args)
                     (setq updated (cons ids args))))
                  ((symbol-function 'beads-list--refresh-current-view)
                   (lambda (&optional _silent) (setq refreshed t))))
          (beads-list-bulk-status "blocked")
          (should (equal updated '(("bd-b") :status "blocked")))
          (should refreshed))))))

(ert-deftest beads-list-test-org-bulk-priority-prefers-marked-ids ()
  "Org bulk operations use marked IDs instead of the heading at point."
  (let ((updated nil)
        (refreshed nil)
        (issues '(((id . "bd-a") (title . "First") (status . "open"))
                  ((id . "bd-b") (title . "Second") (status . "open")))))
    (with-temp-buffer
      (beads-org-list-mode)
      (let ((inhibit-read-only t)
            (beads-list--issues issues)
            (beads-list--marked '("bd-a")))
        (insert "* TODO First\n:PROPERTIES:\n:BEADS_ID: bd-a\n:END:\n* TODO Second\n:PROPERTIES:\n:BEADS_ID: bd-b\n:END:\n")
        (should (beads-list--org-goto-id "bd-b"))
        (cl-letf (((symbol-function 'beads-client-update-bulk)
                   (lambda (ids &rest args)
                     (setq updated (cons ids args))))
                  ((symbol-function 'beads-list--refresh-current-view)
                   (lambda (&optional _silent) (setq refreshed t))))
          (beads-list-bulk-priority 1)
          (should (equal updated '(("bd-a") :priority 1)))
          (should refreshed))))))

(ert-deftest beads-list-test-org-list-refresh-preserves-point-by-id ()
  "Sync org refresh keeps point on the same bead heading when it still exists."
  (let ((issues '(((id . "bd-a") (title . "First") (status . "open"))
                  ((id . "bd-b") (title . "Second") (status . "open"))
                  ((id . "bd-c") (title . "Third") (status . "open")))))
    (with-temp-buffer
      (beads-org-list-mode)
      (cl-letf (((symbol-function 'beads-cache-refresh)
                 (lambda (&rest _args) (cons t issues))))
        (beads-org-list-refresh t)
        (should (beads-list--org-goto-id "bd-b"))
        (beads-org-list-refresh t)
        (should (equal (beads-list--org-id-at-point) "bd-b"))))))

(ert-deftest beads-list-test-org-list-refresh-keeps-moved-issue-visible ()
  "Org refresh keeps the selected issue visible after it moves sections."
  (let* ((buffer (generate-new-buffer " *beads-org-list-window-test*"))
         (ready-issues
          (cl-loop for i from 1 to 20
                   collect `((id . ,(format "bd-ready-%02d" i))
                             (title . ,(format "Ready %02d" i))
                             (status . "open")
                             (priority . 4)
                             (dependency_count . 0))))
         (initial-issues
          (append ready-issues
                  '(((id . "bd-moving")
                     (title . "Moving issue")
                     (status . "blocked")
                     (priority . 4)
                     (dependency_count . 0)))))
         (updated-issues
          (append ready-issues
                  '(((id . "bd-moving")
                     (title . "Moving issue")
                     (status . "open")
                     (priority . 0)
                     (dependency_count . 0)))))
         (previous-buffer (current-buffer))
         (window (selected-window))
         (calls 0))
    (unwind-protect
        (progn
          (set-window-buffer window buffer)
          (set-buffer buffer)
          (beads-org-list-mode)
          (cl-letf (((symbol-function 'beads-cache-refresh)
                     (lambda (&rest _args)
                       (cl-incf calls)
                       (cons t (if (= calls 1)
                                   initial-issues
                                 updated-issues)))))
            (beads-org-list-refresh t)
            (should (beads-list--org-goto-id "bd-moving"))
            (set-window-start window (line-beginning-position))
            (beads-org-list-refresh t)
            (should (equal (beads-list--org-id-at-point) "bd-moving"))
            (should (= (line-number-at-pos (window-start window))
                       (line-number-at-pos)))))
      (when (buffer-live-p previous-buffer)
        (set-window-buffer window previous-buffer)
        (set-buffer previous-buffer))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest beads-list-test-org-list-refresh-falls-back-nearby-when-id-disappears ()
  "Org refresh falls back to a nearby issue heading instead of point-min."
  (let ((first '(((id . "bd-a") (title . "First") (status . "open"))
                 ((id . "bd-b") (title . "Second") (status . "open"))
                 ((id . "bd-c") (title . "Third") (status . "open"))))
        (second '(((id . "bd-a") (title . "First") (status . "open"))
                  ((id . "bd-c") (title . "Third") (status . "open")))))
    (with-temp-buffer
      (beads-org-list-mode)
      (let ((calls 0))
        (cl-letf (((symbol-function 'beads-cache-refresh)
                   (lambda (&rest _args)
                     (cl-incf calls)
                     (cons t (if (= calls 1) first second)))))
          (beads-org-list-refresh t)
          (should (beads-list--org-goto-id "bd-b"))
          (beads-org-list-refresh t)
          (should (member (beads-list--org-id-at-point) '("bd-a" "bd-c")))
          (should-not (equal (beads-list--org-id-at-point) "bd-b"))
          (should-not (= (point) (point-min))))))))

(ert-deftest beads-list-test-org-list-refresh-skips-section-heading-for-edit ()
  "Background org refresh lands on an issue heading, not a section heading.

Regression for bdel-91f.26: detail-view edits refresh visible list
buffers.  If point was on a generated section heading such as Ready,
the refresh fallback must move to a real issue so the next list edit
command does not report No issue at point."
  (let ((issues '(((id . "bd-a") (title . "First") (status . "open")
                   (priority . 0))
                  ((id . "bd-b") (title . "Second") (status . "open")
                   (priority . 1)))))
    (with-temp-buffer
      (beads-org-list-mode)
      (cl-letf (((symbol-function 'beads-cache-refresh)
                 (lambda (&rest _args) (cons t issues))))
        (beads-org-list-refresh t)
        (goto-char (point-min))
        (re-search-forward "^\\* Ready")
        (beginning-of-line)
        (beads-org-list-refresh t)
        (should (equal (beads-list--org-id-at-point) "bd-a"))
        (let ((edited nil)
              (refreshed nil))
          (cl-letf (((symbol-function 'beads-edit-field-minibuffer)
                     (lambda (id field current prompt)
                       (setq edited (list id field current prompt))
                       t))
                    ((symbol-function 'beads-org-list-refresh)
                     (lambda (&optional _silent) (setq refreshed t))))
            (beads-list-edit-title)
            (should (equal edited '("bd-a" :title "First" "Title: ")))
            (should refreshed)))))))

(ert-deftest beads-list-test-org-list-refresh-preserves-folded-subtrees ()
  "Org refresh reapplies folded issue subtrees by bead ID."
  (let ((issues '(((id . "bd-parent")
                   (title . "Parent")
                   (status . "open")
                   (dependent_count . 1))
                  ((id . "bd-child")
                   (title . "Child")
                   (status . "open")
                   (parent . "bd-parent")))))
    (with-temp-buffer
      (beads-org-list-mode)
      (cl-letf (((symbol-function 'beads-cache-refresh)
                 (lambda (&rest _args) (cons t issues))))
        (beads-org-list-refresh t)
        (should (beads-list--org-goto-id "bd-parent"))
        (org-fold-hide-subtree)
        (should (beads-list--org-heading-folded-p))
        (beads-org-list-refresh t)
        (should (equal (beads-list--org-id-at-point) "bd-parent"))
        (should (beads-list--org-heading-folded-p))))))

(ert-deftest beads-list-test-org-list-refresh-async-preserves-point-by-id ()
  "Async org refresh keeps point on the same bead heading when it still exists."
  (let ((issues '(((id . "bd-a") (title . "First") (status . "open"))
                  ((id . "bd-b") (title . "Second") (status . "open"))
                  ((id . "bd-c") (title . "Third") (status . "open")))))
    (with-temp-buffer
      (let ((beads-cache-enabled nil))
        (beads-org-list-mode)
        (cl-letf (((symbol-function 'beads-client-list-async)
                   (lambda (callback &rest _args)
                     (funcall callback nil issues))))
          (beads-org-list-refresh-async t)
          (should (beads-list--org-goto-id "bd-b"))
          (beads-org-list-refresh-async t)
          (should (equal (beads-list--org-id-at-point) "bd-b")))))))

(ert-deftest beads-list-test-org-list-command-creates-project-scoped-buffer ()
  "Org command creates a generated project-pinned buffer."
  (let* ((project-root (file-name-as-directory
                        (expand-file-name "beads-org-list-project" temporary-file-directory)))
         (buffer-name "*beads-org-list-test*")
         (issues '(((id . "bd-a") (title . "First") (status . "open"))))
         refreshed)
    (make-directory project-root t)
    (when (get-buffer buffer-name)
      (kill-buffer buffer-name))
    (unwind-protect
        (let ((default-directory project-root))
          (cl-letf (((symbol-function 'beads-org-list--buffer-name)
                     (lambda (&optional _project-root) buffer-name))
                    ((symbol-function 'beads-client--project-root)
                     (lambda () project-root))
                    ((symbol-function 'beads-cache-refresh)
                     (lambda (&rest _args)
                       (setq refreshed default-directory)
                       (cons t issues))))
            (beads-org-list)
            (should (get-buffer buffer-name))
            (with-current-buffer buffer-name
              (should (eq major-mode 'beads-org-list-mode))
              (should (equal default-directory project-root))
              (should (equal beads-org-list--project-root project-root))
              (should (equal refreshed project-root))
              (should (null buffer-file-name))
              (should (string-match-p "^\\* Ready\n\\*\\* TODO First" (buffer-string))))))
      (when (get-buffer buffer-name)
        (kill-buffer buffer-name))
      (when (file-directory-p project-root)
        (delete-directory project-root t)))))

(ert-deftest beads-list-test-org-list-command-opens-separate-workspace-buffers ()
  "Org command keeps same-name beads projects in different roots separate."
  (let* ((workspace-a (file-name-as-directory
                       (expand-file-name "beads-workspace-a" temporary-file-directory)))
         (workspace-b (file-name-as-directory
                       (expand-file-name "beads-workspace-b" temporary-file-directory)))
         (project-a (file-name-as-directory (expand-file-name "shared" workspace-a)))
         (project-b (file-name-as-directory (expand-file-name "shared" workspace-b)))
         (issues-a '(((id . "bd-a") (title . "From A") (status . "open"))))
         (issues-b '(((id . "bd-b") (title . "From B") (status . "open"))))
         (current-root project-a))
    (make-directory project-a t)
    (make-directory project-b t)
    (unwind-protect
        (cl-letf (((symbol-function 'beads-client--project-root)
                   (lambda () current-root))
                  ((symbol-function 'beads-cache-refresh)
                   (lambda (&rest _args)
                     (cons t (if (equal default-directory project-a)
                                 issues-a
                               issues-b)))))
          (let ((default-directory project-a))
            (beads-org-list))
          (let ((buffer-a (current-buffer)))
            (setq current-root project-b)
            (let ((default-directory project-b))
              (beads-org-list))
            (let ((buffer-b (current-buffer)))
              (should-not (eq buffer-a buffer-b))
              (with-current-buffer buffer-a
                (should (equal default-directory project-a))
                (should (equal beads-org-list--project-root project-a))
                (should (string-match-p "From A" (buffer-string)))
                (should-not (string-match-p "From B" (buffer-string))))
              (with-current-buffer buffer-b
                (should (equal default-directory project-b))
                (should (equal beads-org-list--project-root project-b))
                (should (string-match-p "From B" (buffer-string)))
                (should-not (string-match-p "From A" (buffer-string)))))))
      (dolist (buffer (buffer-list))
        (with-current-buffer buffer
          (when (and (derived-mode-p 'beads-org-list-mode)
                     (member beads-org-list--project-root (list project-a project-b)))
            (kill-buffer buffer))))
      (when (file-directory-p workspace-a)
        (delete-directory workspace-a t))
      (when (file-directory-p workspace-b)
        (delete-directory workspace-b t)))))

(ert-deftest beads-list-test-list-command-opens-org-view-by-default ()
  "The default beads-list command opens beads-org-list-mode."
  (let ((buffer-name "*beads-list-default-org-test*")
        (issues '(((id . "bd-a") (title . "First") (status . "open")))))
    (when (get-buffer buffer-name)
      (kill-buffer buffer-name))
    (unwind-protect
        (cl-letf (((symbol-function 'beads-org-list--buffer-name)
                   (lambda (&optional _project-root) buffer-name))
                  ((symbol-function 'beads-cache-refresh)
                   (lambda (&rest _args) (cons t issues))))
          (beads-list)
          (with-current-buffer buffer-name
            (should (eq major-mode 'beads-org-list-mode))
            (should (string-match-p "^\\* Ready\n\\*\\* TODO First" (buffer-string)))))
      (when (get-buffer buffer-name)
        (kill-buffer buffer-name)))))

(ert-deftest beads-list-test-org-get-issue-at-heading-body ()
  "Org list issue lookup resolves the containing issue heading from body text."
  (let ((issues '(((id . "bd-parent") (title . "Parent") (status . "open"))
                  ((id . "bd-child") (title . "Child") (status . "open")))))
    (with-temp-buffer
      (beads-org-list-mode)
      (let ((inhibit-read-only t)
            (beads-list--issues issues))
        (insert "* TODO Parent\n:PROPERTIES:\n:BEADS_ID: bd-parent\n:END:\nBody text\n** TODO Child\n:PROPERTIES:\n:BEADS_ID: bd-child\n:END:\nChild body\n")
        (goto-char (point-min))
        (search-forward "Body text")
        (should (equal (alist-get 'id (beads-list--get-issue-at-point)) "bd-parent"))
        (search-forward "Child body")
        (should (equal (alist-get 'id (beads-list--get-issue-at-point)) "bd-child"))))))

(ert-deftest beads-list-test-org-get-issue-at-property-drawer ()
  "Org list issue lookup resolves the current heading from property drawer lines."
  (let ((issues '(((id . "bd-drawer") (title . "Drawer") (status . "open")))))
    (with-temp-buffer
      (beads-org-list-mode)
      (let ((inhibit-read-only t)
            (beads-list--issues issues))
        (insert "* TODO Drawer\n:PROPERTIES:\n:BEADS_ID: bd-drawer\n:BEADS_STATUS: open\n:END:\n")
        (goto-char (point-min))
        (search-forward ":BEADS_STATUS:")
        (should (equal (alist-get 'id (beads-list--get-issue-at-point)) "bd-drawer"))))))

(ert-deftest beads-list-test-org-get-issue-at-no-issue-locations ()
  "Org list issue lookup returns nil before headings and on metadata-only headings."
  (let ((issues '(((id . "bd-real") (title . "Real") (status . "open")))))
    (with-temp-buffer
      (beads-org-list-mode)
      (let ((inhibit-read-only t)
            (beads-list--issues issues))
        (insert "#+TITLE: Beads Issues\n\n* Section\nSection body\n** TODO Real\n:PROPERTIES:\n:BEADS_ID: bd-real\n:END:\n")
        (goto-char (point-min))
        (should (null (beads-list--get-issue-at-point)))
        (search-forward "Section body")
        (should (null (beads-list--get-issue-at-point)))))))

(ert-deftest beads-list-test-org-ret-opens-heading-issue ()
  "RET in org list opens the same detail path using the heading issue."
  (let ((opened nil)
        (issues '(((id . "bd-open") (title . "Open") (status . "open")))))
    (with-temp-buffer
      (beads-org-list-mode)
      (let ((inhibit-read-only t)
            (beads-list--issues issues))
        (insert "* TODO Open\n:PROPERTIES:\n:BEADS_ID: bd-open\n:END:\n")
        (cl-letf (((symbol-function 'beads-core-open-issue-detail)
                   (lambda (issue) (setq opened issue))))
          (beads-list-goto-issue)
          (should (equal (alist-get 'id opened) "bd-open")))))))

(ert-deftest beads-list-test-org-edit-title-targets-heading-issue ()
  "Org edit commands target the issue identified by the current heading."
  (let ((edited nil)
        (refreshed nil)
        (issues '(((id . "bd-parent") (title . "Parent") (status . "open"))
                  ((id . "bd-child") (title . "Child") (status . "open")))))
    (with-temp-buffer
      (beads-org-list-mode)
      (let ((inhibit-read-only t)
            (beads-list--issues issues))
        (insert "* TODO Parent\n:PROPERTIES:\n:BEADS_ID: bd-parent\n:END:\n** TODO Child\n:PROPERTIES:\n:BEADS_ID: bd-child\n:END:\nChild body\n")
        (goto-char (point-min))
        (search-forward "Child body")
        (cl-letf (((symbol-function 'beads-edit-field-minibuffer)
                   (lambda (id field current prompt)
                     (setq edited (list id field current prompt))
                     t))
                  ((symbol-function 'beads-org-list-refresh)
                   (lambda (&optional _silent) (setq refreshed t))))
          (beads-list-edit-title)
          (should (equal edited '("bd-child" :title "Child" "Title: ")))
          (should refreshed))))))





(ert-deftest beads-list-test-get-issue-at-point-not-found ()
  "Test that beads-list--get-issue-at-point returns nil when no issue at point."
  (with-temp-buffer
    (beads-org-list-mode)
    (let ((beads-list--issues '()))
      (should (null (beads-list--get-issue-at-point))))))



;;; Integration tests (require bd CLI)

(ert-deftest beads-list-test-refresh-with-cli ()
  "Test that beads-list-refresh fetches issues via CLI."
  :tags '(:integration)
  (skip-unless (beads-test-integration-enabled-p))
  (skip-unless (beads-client--find-database))
  (with-temp-buffer
    (beads-org-list-mode)
    (beads-list-refresh)
    (should (vectorp (beads-client-list)))
    (should (>= (length beads-list--issues) 0))
    (should (listp beads-list--issues))))



(ert-deftest beads-list-test-refresh-error-handling ()
  "Test that beads-list-refresh handles RPC errors gracefully."
  :tags '(:integration)
  (with-temp-buffer
    (beads-org-list-mode)
    (cl-letf (((symbol-function 'beads-client-list)
               (lambda (&rest _args)
                 (signal 'beads-client-error '("Test error")))))
       (beads-list-refresh)
       (should t))))

(ert-deftest beads-list-test-refresh-async-error-handling ()
  (with-temp-buffer
    (beads-org-list-mode)
    (cl-letf (((symbol-function 'beads-client-list-async)
               (lambda (cb &rest _args)
                 (funcall cb "Test async error" nil))))
      (beads-list-refresh-async)
      (should t))))

(ert-deftest beads-list-test-refresh-async-requests-all-issues ()
  "Async list refresh explicitly requests all normal issues."
  (let (filters-seen)
    (with-temp-buffer
      (beads-org-list-mode)
      (cl-letf (((symbol-function 'beads-client-list-async)
                 (lambda (cb &optional filters)
                   (setq filters-seen filters)
                   (funcall cb nil '()))))
        (beads-list-refresh-async)
        (should (equal filters-seen '(:all t)))))))



(ert-deftest beads-list-test-list-command-creates-buffer ()
  "Test that beads-list creates and switches to issue buffer."
  :tags '(:integration)
  (skip-unless (beads-test-integration-enabled-p))
  (skip-unless (beads-client--find-database))
  (let ((buffer-name "*Beads Org Issues*"))
    (when (get-buffer buffer-name)
      (kill-buffer buffer-name))
    (unwind-protect
        (progn
          (beads-list)
          (should (get-buffer buffer-name))
          (should (eq major-mode 'beads-org-list-mode)))
      (when (get-buffer buffer-name)
        (kill-buffer buffer-name)))))

(ert-deftest beads-list-test-list-command-refreshes ()
  "Test that beads-list fetches issues on open."
  :tags '(:integration)
  (skip-unless (beads-test-integration-enabled-p))
  (skip-unless (beads-client--find-database))
  (let ((buffer-name "*Beads Org Issues*"))
    (when (get-buffer buffer-name)
      (kill-buffer buffer-name))
    (unwind-protect
        (progn
          (beads-list)
          (with-current-buffer buffer-name
            (should (>= (length beads-list--issues) 0))))
      (when (get-buffer buffer-name)
        (kill-buffer buffer-name)))))

(ert-deftest beads-list-test-goto-issue-with-issue ()
  "Test that beads-list-goto-issue displays message for issue at point."
  :tags '(:integration)
  (skip-unless (beads-test-integration-enabled-p))
  (skip-unless (beads-client--find-database))
  (let ((buffer-name "*Beads Org Issues*"))
    (when (get-buffer buffer-name)
      (kill-buffer buffer-name))
    (unwind-protect
        (progn
          (beads-list)
          (with-current-buffer buffer-name
            (when (> (length beads-list--issues) 0)
              (goto-char (point-min))
              (forward-line 1)
              (let ((message-log-max t))
                (beads-list-goto-issue)
                (should (get-buffer "*Messages*"))))))
      (when (get-buffer buffer-name)
        (kill-buffer buffer-name)))))

(ert-deftest beads-list-test-goto-issue-no-issue ()
  "Test that beads-list-goto-issue shows message when no issue at point."
  (with-temp-buffer
    (beads-org-list-mode)
    (let ((beads-list--issues '()))
      (let ((message-log-max t))
        (beads-list-goto-issue)
        (should (get-buffer "*Messages*"))))))

(ert-deftest beads-list-test-buffer-reuse ()
  "Test that calling beads-list twice reuses the same buffer."
  :tags '(:integration)
  (skip-unless (beads-test-integration-enabled-p))
  (skip-unless (beads-client--find-database))
  (let ((buffer-name "*Beads Org Issues*"))
    (when (get-buffer buffer-name)
      (kill-buffer buffer-name))
    (unwind-protect
        (progn
          (beads-list)
          (let ((first-buffer (get-buffer buffer-name)))
            (beads-list)
            (should (eq first-buffer (get-buffer buffer-name)))))
      (when (get-buffer buffer-name)
        (kill-buffer buffer-name)))))

;;; Quit behavior tests

(ert-deftest beads-list-test-has-active-filter-none ()
  "Test that beads-list--has-active-filter returns nil with no filter."
  (with-temp-buffer
    (beads-org-list-mode)
    (setq beads-list--filter nil)
    (setq beads-list--show-only-marked nil)
    (should-not (beads-list--has-active-filter))))

(ert-deftest beads-list-test-has-active-filter-with-filter ()
  "Test that beads-list--has-active-filter detects beads-list--filter."
  (with-temp-buffer
    (beads-org-list-mode)
    (setq beads-list--filter '(:type :status :config (:value "open")))
    (setq beads-list--show-only-marked nil)
    (should (beads-list--has-active-filter))))

(ert-deftest beads-list-test-has-active-filter-with-marked ()
  "Test that beads-list--has-active-filter detects show-only-marked."
  (with-temp-buffer
    (beads-org-list-mode)
    (setq beads-list--filter nil)
    (setq beads-list--show-only-marked t)
    (should (beads-list--has-active-filter))))

(ert-deftest beads-list-test-quit-clears-filter ()
  "Test that beads-list-quit clears filter instead of quitting."
  (with-temp-buffer
    (beads-org-list-mode)
    (setq beads-list--filter '(:type :status :config (:value "open")))
    (setq beads-list--issues '())
    (cl-letf (((symbol-function 'beads-client-list) (lambda (&rest _) '()))
              ((symbol-function 'beads-client-stats) (lambda () '())))
      (beads-list-quit)
      (should-not beads-list--filter)
      (should-not beads-list--show-only-marked))))

(ert-deftest beads-list-test-quit-clears-marked-filter ()
  "Test that beads-list-quit clears show-only-marked filter."
  (with-temp-buffer
    (beads-org-list-mode)
    (setq beads-list--filter nil)
    (setq beads-list--show-only-marked t)
    (setq beads-list--issues '())
    (cl-letf (((symbol-function 'beads-client-list) (lambda (&rest _) '()))
              ((symbol-function 'beads-client-stats) (lambda () '())))
      (beads-list-quit)
      (should-not beads-list--filter)
      (should-not beads-list--show-only-marked))))

(ert-deftest beads-list-test-quit-kills-buffer-without-filter ()
  "Test that beads-list-quit kills the list buffer when no filter is active."
  (let ((buffer (generate-new-buffer "*beads-list-test-quit*")))
    (unwind-protect
        (progn
          (switch-to-buffer buffer)
          (beads-org-list-mode)
          (setq beads-list--filter nil)
          (setq beads-list--show-only-marked nil)
          (beads-list-quit)
          (should-not (buffer-live-p buffer)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest beads-list-test-quit-command-defined ()
  "Test that beads-list-quit is a command."
  (should (fboundp 'beads-list-quit))
  (should (commandp 'beads-list-quit)))

;;; Quick assign tests

(ert-deftest beads-list-test-quick-assign-command-defined ()
  "Test that beads-list-quick-assign is a command."
  (should (fboundp 'beads-list-quick-assign))
  (should (commandp 'beads-list-quick-assign)))

(ert-deftest beads-list-test-assign-to-me-command-defined ()
  "Test that beads-list-assign-to-me is a command."
  (should (fboundp 'beads-list-assign-to-me))
  (should (commandp 'beads-list-assign-to-me)))

(ert-deftest beads-list-test-quick-assign-keybinding ()
  "Test that 'a' is bound to beads-list-quick-assign."
  (should (eq (lookup-key beads-org-list-mode-map (kbd "a"))
              #'beads-list-quick-assign)))

(ert-deftest beads-list-test-assign-to-me-keybinding ()
  "Test that 'A' is bound to beads-list-assign-to-me."
  (should (eq (lookup-key beads-org-list-mode-map (kbd "A"))
              #'beads-list-assign-to-me)))

(ert-deftest beads-list-test-bulk-assign-keybinding ()
  "Test that 'B a' is bound to beads-list-quick-assign."
  (should (eq (lookup-key beads-list-bulk-map (kbd "a"))
              #'beads-list-quick-assign)))

(ert-deftest beads-list-test-collect-assignees-empty ()
  "Test collecting assignees from empty list."
  (let ((beads-list--issues nil))
    (should (null (beads-list--collect-assignees)))))

(ert-deftest beads-list-test-collect-assignees-with-data ()
  "Test collecting assignees from issues."
  (let ((beads-list--issues '(((id . "bd-001") (assignee . "alice"))
                               ((id . "bd-002") (assignee . "bob"))
                               ((id . "bd-003") (assignee . "alice")))))
    (should (equal (beads-list--collect-assignees) '("alice" "bob")))))

(ert-deftest beads-list-test-collect-assignees-skips-empty ()
  "Test that empty assignees are skipped."
  (let ((beads-list--issues '(((id . "bd-001") (assignee . "alice"))
                               ((id . "bd-002") (assignee . ""))
                               ((id . "bd-003") (assignee . nil)))))
    (should (equal (beads-list--collect-assignees) '("alice")))))

;;; Custom type support tests

(ert-deftest beads-list-test-builtin-types-defined ()
  "Test that beads-builtin-types is defined with expected types."
  (should (listp beads-builtin-types))
  (should (member "bug" beads-builtin-types))
  (should (member "feature" beads-builtin-types))
  (should (member "task" beads-builtin-types))
  (should (member "epic" beads-builtin-types))
  (should (member "rig" beads-builtin-types)))

(ert-deftest beads-list-test-collect-types-empty ()
  "Test collecting types from empty list."
  (let ((beads-list--issues nil))
    (should (null (beads-list--collect-types)))))

(ert-deftest beads-list-test-collect-types-with-data ()
  "Test collecting types from issues."
  (let ((beads-list--issues '(((id . "bd-001") (issue_type . "bug"))
                               ((id . "bd-002") (issue_type . "task"))
                               ((id . "bd-003") (issue_type . "bug")))))
    (should (equal (beads-list--collect-types) '("bug" "task")))))

(ert-deftest beads-list-test-collect-types-with-custom ()
  "Test collecting custom types from issues."
  (let ((beads-list--issues '(((id . "bd-001") (issue_type . "custom-type"))
                               ((id . "bd-002") (issue_type . "task")))))
    (should (member "custom-type" (beads-list--collect-types)))))

(ert-deftest beads-list-test-available-types-includes-builtin ()
  "Test that available-types includes built-in types.
Stub `beads-get-types' so the result is deterministic and does not
depend on whatever the daemon currently advertises."
  (let ((beads-list--issues nil))
    (cl-letf (((symbol-function 'beads-get-types)
               (lambda () beads-builtin-types)))
      (let ((types (beads-list-available-types)))
        (should (member "bug" types))
        (should (member "feature" types))
        (should (member "rig" types))))))

(ert-deftest beads-list-test-available-types-includes-custom ()
  "Test that available-types includes custom types from issues."
  (let ((beads-list--issues '(((id . "bd-001") (issue_type . "my-custom-type")))))
    (let ((types (beads-list-available-types)))
      (should (member "my-custom-type" types))
      (should (member "bug" types)))))

(ert-deftest beads-list-test-available-types-from-dolt-sql ()
  "Validate `beads-list-available-types' against the real Dolt DB.

Issues a SQL query (via the Dolt SQL FFI in
`beads-backend-dolt-sql--execute-sql') to fetch the canonical set of
issue type names actually present in the beads Dolt database — both
declared custom types in the `custom_types' table and any in-use
types observed in the `issues.issue_type' column.

Asserts that every name returned by SQL is exposed by
`beads-list-available-types'.  Acts as a drift detector between:
  - elisp-side `beads-builtin-types'
  - daemon `types' RPC response (via `beads-get-types')
  - the Dolt backend's stored type names.

Skipped cleanly when integration mode is not enabled, no beads
database is reachable, or the mariadb client is unavailable."
  :tags '(:integration)
  (skip-unless (beads-test-integration-enabled-p))
  (skip-unless (beads-client--find-database))
  (skip-unless (executable-find "mariadb"))
  (skip-unless (beads-backend-dolt-sql--fetch-dolt-params))
  (let* ((custom-types
          (or (ignore-errors
                (beads-backend-dolt-sql--execute-sql
                 "SELECT JSON_ARRAYAGG(name) FROM custom_types;"))
              '()))
         (in-use-types
          (or (ignore-errors
                (beads-backend-dolt-sql--execute-sql
                 "SELECT JSON_ARRAYAGG(issue_type) FROM \
(SELECT DISTINCT issue_type FROM issues \
WHERE issue_type IS NOT NULL AND issue_type <> '') t;"))
              '()))
         (sql-types (delete-dups (append custom-types in-use-types)))
         (available (beads-list-available-types)))
    ;; Sanity: SQL must return at least one type, otherwise the test is
    ;; not actually exercising anything.
    (should (> (length sql-types) 0))
    ;; Drift check: every type the DB knows about must be exposed by
    ;; `beads-list-available-types'.  Include the offending name in the
    ;; failure message so diffs are obvious.
    (dolist (type sql-types)
      (unless (member type available)
        (ert-fail
         (format "Type %S is in the Dolt DB but not in \
`beads-list-available-types' %S (builtin: %S)"
                 type available beads-builtin-types))))))

(ert-deftest beads-list-test-format-type-custom ()
  "Test that custom types are formatted without error."
  (let ((beads-type-style 'full)
        (beads-type-glyph nil))
    (should (equal (beads--format-type '((issue_type . "my-custom-type")))
                   "my-custom-type"))))

(ert-deftest beads-list-test-format-type-custom-no-glyph ()
  "Test that custom types have no glyph even when glyphs enabled."
  (let ((beads-type-style 'full)
        (beads-type-glyph t))
    (should (equal (beads--format-type '((issue_type . "my-custom-type")))
                   "my-custom-type"))))

(ert-deftest beads-list-test-format-type-custom-no-face ()
  "Test that custom types have no special face."
  (let ((beads-type-style 'full)
        (beads-type-glyph nil))
    (should (null (get-text-property 0 'face
                    (beads--format-type '((issue_type . "my-custom-type"))))))))

;;; beads-list--compute-stats tests

(ert-deftest beads-list-test-compute-stats-empty ()
  "Empty issue list yields all zero counts."
  (let ((stats (beads-list--compute-stats nil)))
    (should (= 0 (alist-get 'total_issues stats)))
    (should (= 0 (alist-get 'open_issues stats)))
    (should (= 0 (alist-get 'in_progress_issues stats)))
    (should (= 0 (alist-get 'blocked_issues stats)))
    (should (= 0 (alist-get 'closed_issues stats)))
    (should (= 0 (alist-get 'ready_issues stats)))))

(ert-deftest beads-list-test-compute-stats-mixed-statuses ()
  "Counts are split correctly across known statuses."
  (let* ((issues '(((id . "a") (status . "open")        (dependency_count . 0))
                   ((id . "b") (status . "open")        (dependency_count . 0))
                   ((id . "c") (status . "in_progress") (dependency_count . 0))
                   ((id . "d") (status . "closed")      (dependency_count . 0))))
         (stats (beads-list--compute-stats issues)))
    (should (= 4 (alist-get 'total_issues stats)))
    (should (= 2 (alist-get 'open_issues stats)))
    (should (= 1 (alist-get 'in_progress_issues stats)))
    (should (= 1 (alist-get 'closed_issues stats)))
    (should (= 0 (alist-get 'blocked_issues stats)))
    (should (= 2 (alist-get 'ready_issues stats)))))

(ert-deftest beads-list-test-compute-stats-blocked-from-dep-count ()
  "Open issues with dependency_count > 0 count as blocked, not ready."
  (let* ((issues '(((id . "a") (status . "open") (dependency_count . 0))
                   ((id . "b") (status . "open") (dependency_count . 2))
                   ((id . "c") (status . "open") (dependency_count . 1))))
         (stats (beads-list--compute-stats issues)))
    (should (= 3 (alist-get 'open_issues stats)))
    (should (= 2 (alist-get 'blocked_issues stats)))
    (should (= 1 (alist-get 'ready_issues stats)))))

(ert-deftest beads-list-test-compute-stats-explicit-blocked-status ()
  "Issues with status=blocked also contribute to blocked_issues."
  (let* ((issues '(((id . "a") (status . "blocked") (dependency_count . 0))
                   ((id . "b") (status . "open")    (dependency_count . 0))))
         (stats (beads-list--compute-stats issues)))
    (should (= 1 (alist-get 'blocked_issues stats)))
    (should (= 1 (alist-get 'open_issues stats)))
    (should (= 1 (alist-get 'ready_issues stats)))))

(ert-deftest beads-list-test-compute-stats-missing-dependency-count ()
  "Missing dependency_count is treated as 0."
  (let* ((issues '(((id . "a") (status . "open"))))
         (stats (beads-list--compute-stats issues)))
    (should (= 1 (alist-get 'open_issues stats)))
    (should (= 0 (alist-get 'blocked_issues stats)))
    (should (= 1 (alist-get 'ready_issues stats)))))

(ert-deftest beads-list-test-update-mode-line-uses-passed-stats ()
  "When STATS is passed, do not call beads-client-stats."
  (with-temp-buffer
    (beads-org-list-mode)
    (let ((beads-list-show-header-stats t)
          (called nil))
      (cl-letf (((symbol-function 'beads-client-stats)
                 (lambda () (setq called t) '())))
        (beads-list--update-mode-line
         '((total_issues . 7) (open_issues . 5) (in_progress_issues . 1)
           (blocked_issues . 1) (closed_issues . 0) (ready_issues . 4)))
        (should-not called)
        ;; mode-line was set to a list (not the default symbol).
        (should (listp mode-line-format))))))

(ert-deftest beads-list-test-update-mode-line-computes-from-issues ()
  "Without STATS arg, compute from beads-list--issues without subprocess."
  (with-temp-buffer
    (beads-org-list-mode)
    (let ((beads-list-show-header-stats t)
          (called nil))
      (setq beads-list--issues
            '(((id . "a") (status . "open") (dependency_count . 0))
              ((id . "b") (status . "in_progress") (dependency_count . 0))))
      (cl-letf (((symbol-function 'beads-client-stats)
                 (lambda () (setq called t) '())))
        (beads-list--update-mode-line)
        (should-not called)
        (should (listp mode-line-format))))))

(ert-deftest beads-list-test-update-mode-line-disabled ()
  "When header stats are disabled, mode-line falls back to default."
  (with-temp-buffer
    (beads-org-list-mode)
    (let ((beads-list-show-header-stats nil))
      (beads-list--update-mode-line
       '((total_issues . 1) (open_issues . 1) (in_progress_issues . 0)
         (blocked_issues . 0) (closed_issues . 0) (ready_issues . 1)))
      (should (equal mode-line-format (default-value 'mode-line-format))))))

(ert-deftest beads-list-test-refresh-has-silent-arg ()
  "Test that beads-list-refresh accepts silent argument."
  (should (member 'silent (help-function-arglist 'beads-list-refresh))))





(provide 'beads-list-test)
;;; beads-list-test.el ends here
