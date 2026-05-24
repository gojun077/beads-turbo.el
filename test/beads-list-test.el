;;; beads-list-test.el --- Tests for beads-list.el -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the Beads issue list mode.
;;
;; Test categories:
;; 1. Formatter tests - test formatters without daemon
;; 2. Entry conversion tests - test issue to tabulated-list conversion (mocked)
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
(require 'beads-test-helpers)
(require 'beads-backend-dolt-sql)

;;; Formatter tests (no daemon needed)

(ert-deftest beads-list-test-core-idle-backend-keeps-session-with-other-buffer ()
  "Test idle backend cleanup is skipped while another beads buffer exists."
  (let ((buffer-a (generate-new-buffer " *beads-idle-a*"))
        (buffer-b (generate-new-buffer " *beads-idle-b*"))
        (stop-count 0))
    (unwind-protect
        (progn
          (with-current-buffer buffer-a
            (beads-list-mode))
          (with-current-buffer buffer-b
            (beads-list-mode))
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
            (beads-list-mode))
          (cl-letf (((symbol-function 'buffer-list)
                     (lambda (&optional _frame) (list buffer)))
                    ((symbol-function 'beads-backend-dolt-sql-stop-idle-session)
                     (lambda () (cl-incf stop-count))))
            (with-current-buffer buffer
              (beads-core--maybe-stop-idle-backend))
            (should (= stop-count 1))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest beads-list-test-format-id ()
  "Test that beads-list--format-id returns the issue ID."
  (let ((issue '((id . "bd-a1b2")
                 (title . "Test issue"))))
    (should (equal (beads-list--format-id issue) "bd-a1b2"))))

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

(ert-deftest beads-list-test-format-title-short ()
  "Test that beads-list--format-title returns short titles unchanged."
  (let ((issue '((title . "Short title"))))
    (should (equal (beads-list--format-title issue) "Short title"))))

(ert-deftest beads-list-test-format-title-long ()
  "Test that beads-list--format-title truncates long titles to 50 chars."
  (let ((issue '((title . "This is a very long title that should be truncated because it exceeds the maximum length"))))
    (let ((result (beads-list--format-title issue)))
      (should (equal (length result) 50))
      (should (string-suffix-p "..." result))
      (should (equal result "This is a very long title that should be trunca...")))))

(ert-deftest beads-list-test-format-title-exactly-50 ()
  "Test that beads-list--format-title does not truncate 50-char titles."
  (let ((issue '((title . "12345678901234567890123456789012345678901234567890"))))
    (should (equal (beads-list--format-title issue)
                   "12345678901234567890123456789012345678901234567890"))))

(ert-deftest beads-list-test-format-title-missing ()
  "Test that beads-list--format-title handles missing title gracefully."
  (let ((issue '((id . "bd-test"))))
    (should (equal (beads-list--format-title issue) ""))))

;;; Entry conversion tests (mocked)

(ert-deftest beads-list-test-entries-single-issue ()
  "Test that beads-list-entries converts a single issue correctly."
  (let ((issues '(((id . "bd-a1b2")
                   (title . "Test issue")
                   (status . "open")
                   (priority . 2)
                   (issue_type . "task")))))
    (let ((entries (beads-list-entries issues)))
      (should (= (length entries) 1))
      (let ((entry (car entries)))
        (should (equal (car entry) "bd-a1b2"))
        (should (vectorp (cadr entry)))
        ;; Mark column + 6 default columns (id date status priority type title)
        (should (= (length (cadr entry)) 7))))))

(ert-deftest beads-list-test-entries-multiple-issues ()
  "Test that beads-list-entries converts multiple issues correctly."
  (let ((issues '(((id . "bd-a1b2")
                   (title . "First issue")
                   (status . "open")
                   (priority . 1)
                   (issue_type . "bug"))
                  ((id . "bd-c3d4")
                   (title . "Second issue")
                   (status . "in_progress")
                   (priority . 0)
                   (issue_type . "feature")))))
    (let ((entries (beads-list-entries issues)))
      (should (= (length entries) 2))
      (should (equal (car (nth 0 entries)) "bd-a1b2"))
      (should (equal (car (nth 1 entries)) "bd-c3d4")))))

(ert-deftest beads-list-test-entries-empty ()
  "Test that beads-list-entries handles empty issue list."
  (let ((issues '()))
    (should (equal (beads-list-entries issues) '()))))

(ert-deftest beads-list-test-entries-column-order ()
  "Test that beads-list-entries produces columns in correct order."
  (let ((beads-type-style 'full)
        (beads-type-glyph nil)
        (issues '(((id . "bd-test")
                   (title . "Test")
                   (status . "closed")
                   (priority . 0)
                   (issue_type . "feature")))))
    (let* ((entries (beads-list-entries issues))
           (entry (car entries))
           (columns (cadr entry)))
      ;; Default column order: mark, id, date, status, priority, type, title.
      (should (equal (aref columns 0) " "))
      (should (equal (aref columns 1) "bd-test"))
      (should (equal (aref columns 2) ""))
      (should (equal (aref columns 3) "closed"))
      (should (equal (aref columns 4) "P0"))
      (should (equal (aref columns 5) "feature"))
      (should (equal (aref columns 6) "Test")))))

(ert-deftest beads-list-test-entries-preserves-faces ()
  "Test that beads-list-entries preserves text properties from formatters."
  (let ((issues '(((id . "bd-test")
                   (title . "Test")
                   (status . "in_progress")
                   (priority . 0)
                   (issue_type . "task")))))
    (let* ((entries (beads-list-entries issues))
           (columns (cadr (car entries)))
           ;; Default column order: mark, id, date, status, priority, type, title.
           (status-col (aref columns 3))
           (priority-col (aref columns 4)))
      (should (eq (get-text-property 0 'face status-col) 'beads-status-in-progress))
      (should (eq (get-text-property 0 'face priority-col) 'beads-priority-p0)))))

;;; Mode tests (no daemon)

(ert-deftest beads-list-test-mode-derived-from-tabulated-list ()
  "Test that beads-list-mode is derived from tabulated-list-mode."
  (with-temp-buffer
    (beads-list-mode)
    (should (derived-mode-p 'tabulated-list-mode))
    (should (derived-mode-p 'beads-list-mode))))

(ert-deftest beads-list-test-mode-sets-format ()
  "Test that beads-list-mode sets tabulated-list-format correctly."
  (with-temp-buffer
    (beads-list-mode)
    (should (vectorp tabulated-list-format))
    ;; Mark column + 6 default columns (id date status priority type title).
    (should (= (length tabulated-list-format) 7))
    (should (equal (car (aref tabulated-list-format 0)) " "))
    (should (equal (car (aref tabulated-list-format 1)) "ID"))
    (should (equal (car (aref tabulated-list-format 2)) "Date"))
    (should (equal (car (aref tabulated-list-format 3)) "Status"))
    (should (equal (car (aref tabulated-list-format 4)) "Pri"))
    (should (equal (car (aref tabulated-list-format 5)) "Type"))
    (should (equal (car (aref tabulated-list-format 6)) "Title"))))

(ert-deftest beads-list-test-id-column-width-shows-long-ids ()
  "Test that the ID column widens to fit long issue IDs by default."
  (let* ((long-id "bdel-91f.11-very-long-id")
         (issues `(((id . ,long-id)
                    (title . "Long ID issue")
                    (status . "open")
                    (priority . 2)
                    (issue_type . "task")))))
    (should (null beads-list-id-column-max-width))
    (should (= (beads-list--max-id-width issues) (length long-id)))))

(ert-deftest beads-list-test-mode-sets-padding ()
  "Test that beads-list-mode sets tabulated-list-padding."
  (with-temp-buffer
    (beads-list-mode)
    (should (= tabulated-list-padding 2))))

(ert-deftest beads-list-test-mode-sets-sort-key ()
  "Test that beads-list-mode sets initial sort key to Date (descending)."
  (with-temp-buffer
    (beads-list-mode)
    (should (equal tabulated-list-sort-key '("Date" . t)))))

(ert-deftest beads-list-test-mode-keybindings ()
  "Test that beads-list-mode sets up keybindings correctly."
  (with-temp-buffer
    (beads-list-mode)
    (should (eq (lookup-key beads-list-mode-map (kbd "g")) #'beads-list-refresh))
    (should (eq (lookup-key beads-list-mode-map (kbd "RET")) #'beads-list-goto-issue))
    (should (eq (lookup-key beads-list-mode-map (kbd "q")) #'beads-list-quit))))

(ert-deftest beads-list-test-mode-inherits-parent-keybindings ()
  "Test that beads-list-mode inherits tabulated-list-mode keybindings.
Use a key that is not overridden by `beads-list-mode-map' (e.g. `n')."
  (with-temp-buffer
    (beads-list-mode)
    (should (eq (lookup-key beads-list-mode-map (kbd "n"))
                (lookup-key tabulated-list-mode-map (kbd "n"))))))

(ert-deftest beads-list-test-get-issue-at-point-found ()
  "Test that beads-list--get-issue-at-point returns issue when found."
  (with-temp-buffer
    (beads-list-mode)
    (let* ((issues '(((id . "bd-a1b2")
                      (title . "Test issue")
                      (status . "open")
                      (priority . 2)
                      (issue_type . "task"))
                     ((id . "bd-c3d4")
                      (title . "Another issue")
                      (status . "closed")
                      (priority . 1)
                      (issue_type . "bug"))))
           (beads-list--issues issues))
      (setq tabulated-list-entries (beads-list-entries issues))
      (tabulated-list-print)
      (goto-char (point-min))
      (forward-line 1)
      (let ((issue (beads-list--get-issue-at-point)))
        (should issue)
        (should (member (alist-get 'id issue) '("bd-a1b2" "bd-c3d4")))))))

(ert-deftest beads-list-test-get-issue-at-point-trailing-blank-line ()
  "Regression test for bdel-3rv: point at table end still finds issue.
`tabulated-list-print' leaves a trailing newline after the final entry;
if point lands there, `tabulated-list-get-id' returns nil even though
the previous line is the intended issue row."
  (with-temp-buffer
    (beads-list-mode)
    (let* ((issues '(((id . "bd-a1b2")
                      (title . "Test issue")
                      (status . "open")
                      (priority . 2)
                      (issue_type . "task"))))
           (beads-list--issues issues))
      (setq tabulated-list-entries (beads-list-entries issues))
      (tabulated-list-print)
      (goto-char (point-max))
      (should-not (tabulated-list-get-id))
      (let ((issue (beads-list--get-issue-at-point)))
        (should issue)
        (should (equal (alist-get 'id issue) "bd-a1b2"))))))

(ert-deftest beads-list-test-get-issue-at-point-not-found ()
  "Test that beads-list--get-issue-at-point returns nil when no issue at point."
  (with-temp-buffer
    (beads-list-mode)
    (let ((beads-list--issues '()))
      (should (null (beads-list--get-issue-at-point))))))

(ert-deftest beads-list-test-get-issue-at-point-multiple-issues ()
  "Test that beads-list--get-issue-at-point can find different issues."
  (with-temp-buffer
    (beads-list-mode)
    (let* ((issues '(((id . "bd-a1b2")
                      (title . "First")
                      (status . "open")
                      (priority . 2)
                      (issue_type . "task"))
                     ((id . "bd-c3d4")
                      (title . "Second")
                      (status . "closed")
                      (priority . 1)
                      (issue_type . "bug"))
                     ((id . "bd-e5f6")
                      (title . "Third")
                      (status . "open")
                      (priority . 3)
                      (issue_type . "feature"))))
           (beads-list--issues issues))
      (setq tabulated-list-entries (beads-list-entries issues))
      (tabulated-list-print)
      (goto-char (point-min))
      (forward-line 1)
      (let* ((issue1 (beads-list--get-issue-at-point))
             (id1 (alist-get 'id issue1)))
        (should issue1)
        (should (member id1 '("bd-a1b2" "bd-c3d4" "bd-e5f6")))
        (forward-line 1)
        (let* ((issue2 (beads-list--get-issue-at-point))
               (id2 (when issue2 (alist-get 'id issue2))))
          (when issue2
            (should (member id2 '("bd-a1b2" "bd-c3d4" "bd-e5f6")))
            (should-not (equal id1 id2))))))))

;;; Integration tests (require bd CLI)

(ert-deftest beads-list-test-refresh-with-cli ()
  "Test that beads-list-refresh fetches issues via CLI."
  :tags '(:integration)
  (skip-unless (beads-test-integration-enabled-p))
  (skip-unless (beads-client--find-database))
  (with-temp-buffer
    (beads-list-mode)
    (beads-list-refresh)
    (should (vectorp (beads-client-list)))
    (should (>= (length beads-list--issues) 0))
    (should (listp beads-list--issues))))

(ert-deftest beads-list-test-refresh-populates-entries ()
  "Test that beads-list-refresh populates tabulated-list-entries."
  :tags '(:integration)
  (skip-unless (beads-test-integration-enabled-p))
  (skip-unless (beads-client--find-database))
  (with-temp-buffer
    (beads-list-mode)
    (beads-list-refresh)
    (should (listp tabulated-list-entries))
    (should (= (length tabulated-list-entries) (length beads-list--issues)))))

(ert-deftest beads-list-test-refresh-error-handling ()
  "Test that beads-list-refresh handles RPC errors gracefully."
  :tags '(:integration)
  (with-temp-buffer
    (beads-list-mode)
    (cl-letf (((symbol-function 'beads-client-list)
               (lambda (&rest _args)
                 (signal 'beads-client-error '("Test error")))))
       (beads-list-refresh)
       (should t))))

(ert-deftest beads-list-test-refresh-async-error-handling ()
  (with-temp-buffer
    (beads-list-mode)
    (cl-letf (((symbol-function 'beads-client-list-async)
               (lambda (cb &rest _args)
                 (funcall cb "Test async error" nil))))
      (beads-list-refresh-async)
      (should t))))

(ert-deftest beads-list-test-refresh-async-requests-all-issues ()
  "Async list refresh explicitly requests all normal issues."
  (let (filters-seen)
    (with-temp-buffer
      (beads-list-mode)
      (cl-letf (((symbol-function 'beads-client-list-async)
                 (lambda (cb &optional filters)
                   (setq filters-seen filters)
                   (funcall cb nil '()))))
        (beads-list-refresh-async)
        (should (equal filters-seen '(:all t)))))))

(ert-deftest beads-list-test-refresh-async-preserves-point ()
  "Auto-refresh must not yank the cursor back to the top of the buffer.

Regression test for bdel-efx: `beads-list-refresh-async' previously
called `(goto-char (point-min))' unconditionally after rebuilding the
table, clobbering the user's cursor position every time the auto-refresh
timer fired."
  (let* ((issues (mapcar (lambda (i)
                           `((id . ,(format "bd-%03d" i))
                             (title . ,(format "Issue %d" i))
                             (status . "open")
                             (priority . 2)
                             (issue_type . "task")
                             (created_at . "2025-01-01T00:00:00Z")
                             (updated_at . "2025-01-01T00:00:00Z")))
                         (number-sequence 1 5)))
         (target-id "bd-003"))
    (with-temp-buffer
      (cl-letf (((symbol-function 'beads-client-list-async)
                 (lambda (cb &rest _args) (funcall cb nil issues)))
                ;; Stub the hint helper (defined in beads.el, which the
                ;; test does not load) so beads-list-mode setup doesn't
                ;; signal void-function.
                ((symbol-function 'beads-show-hint)
                 (lambda () nil)))
        (beads-list-mode)
        ;; Initial population.
        (beads-list-refresh-async)
        ;; Move point to a specific row.
        (should (beads-list-goto-id target-id))
        (should (equal (tabulated-list-get-id) target-id))
        ;; Fire another async refresh and confirm point stays put.
        (beads-list-refresh-async)
        (should (equal (tabulated-list-get-id) target-id))
        (should-not (= (point) (point-min)))))))

(ert-deftest beads-list-test-list-command-creates-buffer ()
  "Test that beads-list creates and switches to issue buffer."
  :tags '(:integration)
  (skip-unless (beads-test-integration-enabled-p))
  (skip-unless (beads-client--find-database))
  (let ((buffer-name "*Beads Issues*"))
    (when (get-buffer buffer-name)
      (kill-buffer buffer-name))
    (unwind-protect
        (progn
          (beads-list)
          (should (get-buffer buffer-name))
          (should (eq major-mode 'beads-list-mode)))
      (when (get-buffer buffer-name)
        (kill-buffer buffer-name)))))

(ert-deftest beads-list-test-list-command-refreshes ()
  "Test that beads-list fetches issues on open."
  :tags '(:integration)
  (skip-unless (beads-test-integration-enabled-p))
  (skip-unless (beads-client--find-database))
  (let ((buffer-name "*Beads Issues*"))
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
  (let ((buffer-name "*Beads Issues*"))
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
    (beads-list-mode)
    (let ((beads-list--issues '()))
      (let ((message-log-max t))
        (beads-list-goto-issue)
        (should (get-buffer "*Messages*"))))))

(ert-deftest beads-list-test-buffer-reuse ()
  "Test that calling beads-list twice reuses the same buffer."
  :tags '(:integration)
  (skip-unless (beads-test-integration-enabled-p))
  (skip-unless (beads-client--find-database))
  (let ((buffer-name "*Beads Issues*"))
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
    (beads-list-mode)
    (setq beads-list--filter nil)
    (setq beads-list--show-only-marked nil)
    (should-not (beads-list--has-active-filter))))

(ert-deftest beads-list-test-has-active-filter-with-filter ()
  "Test that beads-list--has-active-filter detects beads-list--filter."
  (with-temp-buffer
    (beads-list-mode)
    (setq beads-list--filter '(:type :status :config (:value "open")))
    (setq beads-list--show-only-marked nil)
    (should (beads-list--has-active-filter))))

(ert-deftest beads-list-test-has-active-filter-with-marked ()
  "Test that beads-list--has-active-filter detects show-only-marked."
  (with-temp-buffer
    (beads-list-mode)
    (setq beads-list--filter nil)
    (setq beads-list--show-only-marked t)
    (should (beads-list--has-active-filter))))

(ert-deftest beads-list-test-quit-clears-filter ()
  "Test that beads-list-quit clears filter instead of quitting."
  (with-temp-buffer
    (beads-list-mode)
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
    (beads-list-mode)
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
          (beads-list-mode)
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
  (should (eq (lookup-key beads-list-mode-map (kbd "a"))
              #'beads-list-quick-assign)))

(ert-deftest beads-list-test-assign-to-me-keybinding ()
  "Test that 'A' is bound to beads-list-assign-to-me."
  (should (eq (lookup-key beads-list-mode-map (kbd "A"))
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
    (beads-list-mode)
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
    (beads-list-mode)
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
    (beads-list-mode)
    (let ((beads-list-show-header-stats nil))
      (beads-list--update-mode-line
       '((total_issues . 1) (open_issues . 1) (in_progress_issues . 0)
         (blocked_issues . 0) (closed_issues . 0) (ready_issues . 1)))
      (should (equal mode-line-format (default-value 'mode-line-format))))))

(ert-deftest beads-list-test-goto-id-defined ()
  "Test that beads-list-goto-id is defined."
  (should (fboundp 'beads-list-goto-id)))

(ert-deftest beads-list-test-refresh-has-silent-arg ()
  "Test that beads-list-refresh accepts silent argument."
  (should (member 'silent (help-function-arglist 'beads-list-refresh))))

(ert-deftest beads-list-test-on-select-hook-installed ()
  "`beads-list-mode' must register the event-driven refresh hook
buffer-locally on `window-selection-change-functions' (replaces the
old timer-based auto-refresh — see bdel-lc6)."
  (with-temp-buffer
    (cl-letf (((symbol-function 'beads-show-hint) #'ignore))
      (beads-list-mode))
    (should (memq #'beads-list--maybe-refresh-on-select
                  window-selection-change-functions))))

(ert-deftest beads-list-test-on-select-fires-async-on-leading-edge ()
  "`beads-list--maybe-refresh-on-select' must call
`beads-list-refresh-async' exactly once when a list buffer's window
transitions from unselected to selected, and not again while it
remains selected."
  (let* ((calls 0)
         (buf (generate-new-buffer "*beads-list-test*")))
    (unwind-protect
        (with-current-buffer buf
          (cl-letf (((symbol-function 'beads-show-hint) #'ignore)
                    ((symbol-function 'beads-list-refresh-async)
                     (lambda (&rest _) (cl-incf calls))))
            (beads-list-mode)
            ;; Simulate window selected: leading edge -> 1 call.
            (let ((win (selected-window)))
              ;; Force the buffer-into-window association
              (set-window-buffer win buf)
              (cl-letf (((symbol-function 'frame-selected-window)
                         (lambda (&optional _f) win))
                        ((symbol-function 'window-list)
                         (lambda (&optional _f _m _w) (list win))))
                (beads-list--maybe-refresh-on-select (selected-frame))
                (should (= calls 1))
                ;; Already selected: no additional call.
                (beads-list--maybe-refresh-on-select (selected-frame))
                (should (= calls 1))))))
      (kill-buffer buf))))

(provide 'beads-list-test)
;;; beads-list-test.el ends here
