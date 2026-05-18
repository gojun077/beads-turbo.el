;;; beads-detail-test.el --- Tests for beads-detail.el -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the Beads issue detail mode.
;;
;; Test categories:
;; 1. Face definition tests - test all faces are defined with expected properties
;; 2. Render tests - test beads-detail--render inserts expected sections (mocked)
;; 3. Mode tests - test mode setup, keybindings, and read-only behavior
;; 4. Integration tests - test with actual daemon (tagged :integration)
;;
;; Note on test isolation:
;; Read-only integration tests may inspect the current repo when
;; explicitly enabled.  Write-path coverage belongs in temp-project E2E
;; tests rather than this file's repo-backed integration tests.

;;; Code:

(require 'ert)
(require 'beads-detail)
(require 'beads-test-helpers)

;;; Face definition tests (no daemon needed)

(ert-deftest beads-detail-test-faces-defined ()
  "Test that all detail mode faces are defined."
  (should (facep 'beads-detail-id-face))
  (should (facep 'beads-detail-title-face))
  (should (facep 'beads-detail-header-face))
  (should (facep 'beads-detail-label-face))
  (should (facep 'beads-detail-value-face)))

(ert-deftest beads-detail-test-id-face-properties ()
  "Test that beads-detail-id-face has expected properties."
  (let ((face-attrs (face-all-attributes 'beads-detail-id-face nil)))
    (should (listp face-attrs))))

(ert-deftest beads-detail-test-title-face-properties ()
  "Test that beads-detail-title-face has expected properties."
  (let ((face-attrs (face-all-attributes 'beads-detail-title-face nil)))
    (should (listp face-attrs))))

(ert-deftest beads-detail-test-header-face-properties ()
  "Test that beads-detail-header-face has expected properties."
  (let ((face-attrs (face-all-attributes 'beads-detail-header-face nil)))
    (should (listp face-attrs))))

(ert-deftest beads-detail-test-label-face-properties ()
  "Test that beads-detail-label-face has expected properties."
  (let ((face-attrs (face-all-attributes 'beads-detail-label-face nil)))
    (should (listp face-attrs))))

(ert-deftest beads-detail-test-value-face-properties ()
  "Test that beads-detail-value-face has expected properties."
  (let ((face-attrs (face-all-attributes 'beads-detail-value-face nil)))
    (should (listp face-attrs))))

;;; Render tests (mocked, no daemon)

(ert-deftest beads-detail-test-render-inserts-header ()
  "Test that beads-detail--render inserts ID and title in header."
  (with-temp-buffer
    (let ((issue '((id . "bd-test123")
                   (title . "Test Issue Title")
                   (status . "open")
                   (priority . 2)
                   (issue_type . "task"))))
      (beads-detail--render issue)
      (goto-char (point-min))
      (should (search-forward "bd-test123" nil t))
      (should (search-forward "Test Issue Title" nil t)))))

(ert-deftest beads-detail-test-render-inserts-metadata ()
  "Test that beads-detail--render inserts status, priority, and type."
  (with-temp-buffer
    (let ((issue '((id . "bd-test")
                   (title . "Test")
                   (status . "in_progress")
                   (priority . 1)
                   (issue_type . "bug"))))
      (beads-detail--render issue)
      (let ((buffer-content (buffer-string)))
        (should (string-match-p "in_progress" buffer-content))
        (should (string-match-p "1" buffer-content))
        (should (string-match-p "bug" buffer-content))))))

(ert-deftest beads-detail-test-render-created-by-present ()
  "Test that beads-detail--render shows created_by when present."
  (with-temp-buffer
    (let ((issue '((id . "bd-test")
                   (title . "Test")
                   (status . "open")
                   (priority . 2)
                   (issue_type . "task")
                   (created_by . "alice"))))
      (beads-detail--render issue)
      (let ((buffer-content (buffer-string)))
        (should (string-match-p "Created by:" buffer-content))
        (should (string-match-p "alice" buffer-content))))))

(ert-deftest beads-detail-test-render-created-by-absent ()
  "Test that beads-detail--render handles missing created_by gracefully."
  (with-temp-buffer
    (let ((issue '((id . "bd-test")
                   (title . "Test")
                   (status . "open")
                   (priority . 2)
                   (issue_type . "task"))))
      (beads-detail--render issue)
      (let ((buffer-content (buffer-string)))
        (should-not (string-match-p "Created by:" buffer-content))))))

(ert-deftest beads-detail-test-render-comments-present ()
  "Test that beads-detail--render shows comments when present."
  (with-temp-buffer
    (let ((issue '((id . "bd-test")
                   (title . "Test")
                   (status . "open")
                   (priority . 2)
                   (issue_type . "task")
                   (comments . [((id . 1)
                                 (author . "alice")
                                 (text . "This is a test comment")
                                 (created_at . "2026-01-06T10:00:00Z"))]))))
      (beads-detail--render issue)
      (let ((buffer-content (buffer-string)))
        (should (string-match-p "Comments (1):" buffer-content))
        (should (string-match-p "\\[alice\\]" buffer-content))
        (should (string-match-p "This is a test comment" buffer-content))))))

(ert-deftest beads-detail-test-render-comments-absent ()
  "Test that beads-detail--render handles missing comments gracefully."
  (with-temp-buffer
    (let ((issue '((id . "bd-test")
                   (title . "Test")
                   (status . "open")
                   (priority . 2)
                   (issue_type . "task"))))
      (beads-detail--render issue)
      (let ((buffer-content (buffer-string)))
        (should-not (string-match-p "Comments" buffer-content))))))

(ert-deftest beads-detail-test-render-comments-empty ()
  "Test that beads-detail--render handles empty comments array gracefully."
  (with-temp-buffer
    (let ((issue '((id . "bd-test")
                   (title . "Test")
                   (status . "open")
                   (priority . 2)
                   (issue_type . "task")
                   (comments . []))))
      (beads-detail--render issue)
      (let ((buffer-content (buffer-string)))
        (should-not (string-match-p "Comments" buffer-content))))))

(ert-deftest beads-detail-test-render-description-present ()
  "Test that beads-detail--render shows description when present."
  (with-temp-buffer
    (let ((issue '((id . "bd-test")
                   (title . "Test")
                   (status . "open")
                   (priority . 2)
                   (issue_type . "task")
                   (description . "This is a test description"))))
      (beads-detail--render issue)
      (goto-char (point-min))
      (should (search-forward "This is a test description" nil t)))))

(ert-deftest beads-detail-test-render-description-absent ()
  "Test that beads-detail--render handles missing description gracefully."
  (with-temp-buffer
    (let ((issue '((id . "bd-test")
                   (title . "Test")
                   (status . "open")
                   (priority . 2)
                   (issue_type . "task"))))
      (beads-detail--render issue)
      (let ((buffer-content (buffer-string)))
        (should-not (string-match-p "Description:" buffer-content))))))

(ert-deftest beads-detail-test-render-description-empty ()
  "Test that beads-detail--render handles empty description gracefully."
  (with-temp-buffer
    (let ((issue '((id . "bd-test")
                   (title . "Test")
                   (status . "open")
                   (priority . 2)
                   (issue_type . "task")
                   (description . ""))))
      (beads-detail--render issue)
      (let ((buffer-content (buffer-string)))
        (should-not (string-match-p "Description:" buffer-content))))))

(ert-deftest beads-detail-test-render-design-present ()
  "Test that beads-detail--render shows design section when present."
  (with-temp-buffer
    (let ((issue '((id . "bd-test")
                   (title . "Test")
                   (status . "open")
                   (priority . 2)
                   (issue_type . "task")
                   (design . "Design notes here"))))
      (beads-detail--render issue)
      (goto-char (point-min))
      (should (search-forward "Design notes here" nil t)))))

(ert-deftest beads-detail-test-render-design-absent ()
  "Test that beads-detail--render handles missing design gracefully."
  (with-temp-buffer
    (let ((issue '((id . "bd-test")
                   (title . "Test")
                   (status . "open")
                   (priority . 2)
                   (issue_type . "task"))))
      (beads-detail--render issue)
      (let ((buffer-content (buffer-string)))
        (should-not (string-match-p "Design:" buffer-content))))))

(ert-deftest beads-detail-test-render-acceptance-present ()
  "Test that beads-detail--render shows acceptance criteria when present."
  (with-temp-buffer
    (let ((issue '((id . "bd-test")
                   (title . "Test")
                   (status . "open")
                   (priority . 2)
                   (issue_type . "task")
                   (acceptance_criteria . "Acceptance criteria here"))))
      (beads-detail--render issue)
      (goto-char (point-min))
      (should (search-forward "Acceptance criteria here" nil t)))))

(ert-deftest beads-detail-test-render-acceptance-absent ()
  "Test that beads-detail--render handles missing acceptance criteria gracefully."
  (with-temp-buffer
    (let ((issue '((id . "bd-test")
                   (title . "Test")
                   (status . "open")
                   (priority . 2)
                   (issue_type . "task"))))
      (beads-detail--render issue)
      (let ((buffer-content (buffer-string)))
        (should-not (string-match-p "Acceptance:" buffer-content))))))

(ert-deftest beads-detail-test-render-dependencies-present ()
  "Test that beads-detail--render shows dependencies when present."
  (with-temp-buffer
    (let ((issue '((id . "bd-test")
                   (title . "Test")
                   (status . "open")
                   (priority . 2)
                   (issue_type . "task")
                   (dependencies . [((id . "bd-dep1")
                                      (dependency_type . "blocks"))
                                     ((id . "bd-dep2")
                                      (dependency_type . "related"))]))))
      (beads-detail--render issue)
      (let ((buffer-content (buffer-string)))
        (should (string-match-p "bd-dep1" buffer-content))
        (should (string-match-p "bd-dep2" buffer-content))))))

(ert-deftest beads-detail-test-render-dependencies-absent ()
  "Test that beads-detail--render handles missing dependencies gracefully."
  (with-temp-buffer
    (let ((issue '((id . "bd-test")
                   (title . "Test")
                   (status . "open")
                   (priority . 2)
                   (issue_type . "task"))))
      (beads-detail--render issue)
      (let ((buffer-content (buffer-string)))
        (should-not (string-match-p "Dependencies:" buffer-content))))))

(ert-deftest beads-detail-test-render-labels-present ()
  "Test that beads-detail--render shows labels when present."
  (with-temp-buffer
    (let ((issue '((id . "bd-test")
                   (title . "Test")
                   (status . "open")
                   (priority . 2)
                   (issue_type . "task")
                   (labels . ["backend" "urgent"]))))
      (beads-detail--render issue)
      (goto-char (point-min))
      (should (search-forward "backend" nil t))
      (should (search-forward "urgent" nil t)))))

(ert-deftest beads-detail-test-render-labels-absent ()
  "Test that beads-detail--render handles missing labels gracefully."
  (with-temp-buffer
    (let ((issue '((id . "bd-test")
                   (title . "Test")
                   (status . "open")
                   (priority . 2)
                   (issue_type . "task"))))
      (beads-detail--render issue)
      (let ((buffer-content (buffer-string)))
        (should-not (string-match-p "Labels:" buffer-content))))))

(ert-deftest beads-detail-test-render-timestamps ()
  "Test that beads-detail--render shows created and updated timestamps."
  (with-temp-buffer
    (let ((issue '((id . "bd-test")
                   (title . "Test")
                   (status . "open")
                   (priority . 2)
                   (issue_type . "task")
                   (created_at . "2025-01-01T10:00:00Z")
                   (updated_at . "2025-01-02T11:00:00Z"))))
      (beads-detail--render issue)
      (let ((buffer-content (buffer-string)))
        (should (string-match-p "2025-01-01" buffer-content))
        (should (string-match-p "2025-01-02" buffer-content))))))

(ert-deftest beads-detail-test-render-assignee-present ()
  "Test that beads-detail--render shows assignee when present."
  (with-temp-buffer
    (let ((issue '((id . "bd-test")
                   (title . "Test")
                   (status . "open")
                   (priority . 2)
                   (issue_type . "task")
                   (assignee . "alice"))))
      (beads-detail--render issue)
      (goto-char (point-min))
      (should (search-forward "alice" nil t)))))

(ert-deftest beads-detail-test-render-minimal-issue ()
  "Test that beads-detail--render handles minimal issue with only required fields."
  (with-temp-buffer
    (let ((issue '((id . "bd-minimal")
                   (title . "Minimal Issue")
                   (status . "open")
                   (priority . 2)
                   (issue_type . "task"))))
      (beads-detail--render issue)
      (goto-char (point-min))
      (should (search-forward "bd-minimal" nil t))
      (should (search-forward "Minimal Issue" nil t)))))

(ert-deftest beads-detail-test-render-all-fields ()
  "Test that beads-detail--render handles issue with all fields populated."
  (with-temp-buffer
    (let ((issue '((id . "bd-full")
                   (title . "Full Issue")
                   (status . "in_progress")
                   (priority . 1)
                   (issue_type . "feature")
                   (description . "Full description")
                   (design . "Design notes")
                   (acceptance_criteria . "Acceptance criteria")
                   (assignee . "bob")
                   (labels . ["frontend" "ui"])
                   (dependencies . [((id . "bd-dep1")
                                      (dependency_type . "blocks"))])
                   (created_at . "2025-01-01T10:00:00Z")
                   (updated_at . "2025-01-02T11:00:00Z"))))
      (beads-detail--render issue)
      (let ((buffer-content (buffer-string)))
        (should (string-match-p "bd-full" buffer-content))
        (should (string-match-p "Full Issue" buffer-content))
        (should (string-match-p "Full description" buffer-content))
        (should (string-match-p "Design notes" buffer-content))
        (should (string-match-p "Acceptance criteria" buffer-content))
        (should (string-match-p "bob" buffer-content))
        (should (string-match-p "frontend" buffer-content))
        (should (string-match-p "bd-dep1" buffer-content))))))

(ert-deftest beads-detail-test-render-parent-present ()
  "Test that beads-detail--render shows parent link when present."
  (with-temp-buffer
    (let ((issue '((id . "bd-child")
                   (title . "Child Issue")
                   (status . "open")
                   (priority . 2)
                   (issue_type . "task")
                   (parent_id . "bd-parent"))))
      (beads-detail--render issue)
      (let ((buffer-content (buffer-string)))
        (should (string-match-p "Parent:" buffer-content))
        (should (string-match-p "bd-parent" buffer-content))))))

(ert-deftest beads-detail-test-render-parent-absent ()
  "Test that beads-detail--render handles missing parent gracefully."
  (with-temp-buffer
    (let ((issue '((id . "bd-test")
                   (title . "Test")
                   (status . "open")
                   (priority . 2)
                   (issue_type . "task"))))
      (beads-detail--render issue)
      (let ((buffer-content (buffer-string)))
        (should-not (string-match-p "Parent:" buffer-content))))))

;;; bdel-91f.9: render parity with `bd show'

(ert-deftest beads-detail-test-render-parent-from-parent-field ()
  "Parent should be shown when issue uses top-level `parent' string field
\(as returned by `bd show --json'), not just `parent_id'."
  (with-temp-buffer
    (let ((issue '((id . "bd-child")
                   (title . "Child")
                   (status . "open")
                   (priority . 2)
                   (issue_type . "task")
                   (parent . "bd-parent"))))
      (beads-detail--render issue)
      (let ((buffer-content (buffer-string)))
        (should (string-match-p "Parent:" buffer-content))
        (should (string-match-p "bd-parent" buffer-content))))))

(ert-deftest beads-detail-test-render-owner ()
  "Owner field should be displayed when present."
  (with-temp-buffer
    (let ((issue '((id . "bd-test")
                   (title . "Test")
                   (status . "open")
                   (priority . 2)
                   (issue_type . "task")
                   (owner . "carol@example.com"))))
      (beads-detail--render issue)
      (let ((buffer-content (buffer-string)))
        (should (string-match-p "Owner:" buffer-content))
        (should (string-match-p "carol@example.com" buffer-content))))))

(ert-deftest beads-detail-test-render-started-at ()
  "Started timestamp should be displayed when present."
  (with-temp-buffer
    (let ((issue '((id . "bd-test")
                   (title . "Test")
                   (status . "in_progress")
                   (priority . 2)
                   (issue_type . "task")
                   (started_at . "2025-03-04T08:00:00Z"))))
      (beads-detail--render issue)
      (let ((buffer-content (buffer-string)))
        (should (string-match-p "Started:" buffer-content))
        (should (string-match-p "2025-03-04" buffer-content))))))

(ert-deftest beads-detail-test-render-closed-at-and-reason ()
  "Closed timestamp and close reason should be displayed when present."
  (with-temp-buffer
    (let ((issue '((id . "bd-test")
                   (title . "Test")
                   (status . "closed")
                   (priority . 2)
                   (issue_type . "task")
                   (closed_at . "2025-04-05T12:00:00Z")
                   (close_reason . "Done"))))
      (beads-detail--render issue)
      (let ((buffer-content (buffer-string)))
        (should (string-match-p "Closed:" buffer-content))
        (should (string-match-p "2025-04-05" buffer-content))
        (should (string-match-p "Close reason:" buffer-content))
        (should (string-match-p "Done" buffer-content))))))

(ert-deftest beads-detail-test-render-external-ref ()
  "External ref should be displayed when present."
  (with-temp-buffer
    (let ((issue '((id . "bd-test")
                   (title . "Test")
                   (status . "open")
                   (priority . 2)
                   (issue_type . "task")
                   (external_ref . "JIRA-1234"))))
      (beads-detail--render issue)
      (let ((buffer-content (buffer-string)))
        (should (string-match-p "External ref:" buffer-content))
        (should (string-match-p "JIRA-1234" buffer-content))))))

(ert-deftest beads-detail-test-render-notes-section ()
  "Notes section should render when notes field is present and non-empty
\(regression test for bdel-91f.8: notes field missing in detail view)."
  (with-temp-buffer
    (let ((issue '((id . "bd-test")
                   (title . "Test")
                   (status . "open")
                   (priority . 2)
                   (issue_type . "task")
                   (notes . "Implementation notes here"))))
      (beads-detail--render issue)
      (let ((buffer-content (buffer-string)))
        (should (string-match-p "Notes:" buffer-content))
        (should (string-match-p "Implementation notes here" buffer-content))))))

(ert-deftest beads-detail-test-render-notes-absent ()
  "Notes section should not appear when notes is missing or empty."
  (with-temp-buffer
    (let ((issue '((id . "bd-test")
                   (title . "Test")
                   (status . "open")
                   (priority . 2)
                   (issue_type . "task"))))
      (beads-detail--render issue)
      (let ((buffer-content (buffer-string)))
        (should-not (string-match-p "^Notes:" buffer-content)))))
  (with-temp-buffer
    (let ((issue '((id . "bd-test")
                   (title . "Test")
                   (status . "open")
                   (priority . 2)
                   (issue_type . "task")
                   (notes . ""))))
      (beads-detail--render issue)
      (let ((buffer-content (buffer-string)))
        (should-not (string-match-p "^Notes:" buffer-content))))))

(ert-deftest beads-detail-test-render-categorized-relationships ()
  "Dependencies/dependents should be grouped by `dependency_type' into
named sections matching `bd show' (Parent, Children, Discovered From,
Discovered, Related, Depends on, Dependents)."
  (with-temp-buffer
    (let ((issue '((id . "bd-epic")
                   (title . "Epic")
                   (status . "open")
                   (priority . 2)
                   (issue_type . "epic")
                   (dependencies . [((id . "bd-parent")
                                     (title . "Parent")
                                     (dependency_type . "parent-child"))
                                    ((id . "bd-origin")
                                     (title . "Origin")
                                     (dependency_type . "discovered-from"))
                                    ((id . "bd-blocker")
                                     (title . "Blocker")
                                     (dependency_type . "blocks"))])
                   (dependents . [((id . "bd-child")
                                    (title . "Child")
                                    (dependency_type . "parent-child"))
                                   ((id . "bd-derived")
                                    (title . "Derived")
                                    (dependency_type . "discovered-from"))
                                   ((id . "bd-relative")
                                    (title . "Relative")
                                    (dependency_type . "related"))]))))
      (beads-detail--render issue)
      (let ((buffer-content (buffer-string)))
        (should (string-match-p "Parent:" buffer-content))
        (should (string-match-p "bd-parent" buffer-content))
        (should (string-match-p "Children:" buffer-content))
        (should (string-match-p "bd-child" buffer-content))
        (should (string-match-p "Discovered From:" buffer-content))
        (should (string-match-p "bd-origin" buffer-content))
        (should (string-match-p "Discovered:" buffer-content))
        (should (string-match-p "bd-derived" buffer-content))
        (should (string-match-p "Related:" buffer-content))
        (should (string-match-p "bd-relative" buffer-content))
        (should (string-match-p "Depends on:" buffer-content))
        (should (string-match-p "bd-blocker" buffer-content))))))

(ert-deftest beads-detail-test-render-epic-progress ()
  "Epic progress (X/Y complete (Z%)) should be displayed for epics."
  (with-temp-buffer
    (let ((issue '((id . "bd-epic")
                   (title . "Epic")
                   (status . "open")
                   (priority . 2)
                   (issue_type . "epic")
                   (epic_total_children . 12)
                   (epic_closed_children . 8))))
      (beads-detail--render issue)
      (let ((buffer-content (buffer-string)))
        (should (string-match-p "8/12 complete" buffer-content))
        (should (string-match-p "67%" buffer-content))))))

(ert-deftest beads-detail-test-bucket-deps-by-type ()
  "`beads-detail--bucket-deps' should group deps by `dependency_type'."
  (let* ((deps [((id . "a") (dependency_type . "parent-child"))
                ((id . "b") (dependency_type . "blocks"))
                ((id . "c") (dependency_type . "parent-child"))])
         (buckets (beads-detail--bucket-deps deps)))
    (should (= 2 (length buckets)))
    (let ((pc (alist-get "parent-child" buckets nil nil #'string=))
          (bl (alist-get "blocks" buckets nil nil #'string=)))
      (should (= 2 (length pc)))
      (should (equal "a" (alist-get 'id (car pc))))
      (should (equal "c" (alist-get 'id (cadr pc))))
      (should (= 1 (length bl)))
      (should (equal "b" (alist-get 'id (car bl)))))))

;;; Parent navigation tests (no daemon)

(ert-deftest beads-detail-test-goto-parent-defined ()
  "Test that beads-detail-goto-parent is defined as a command."
  (should (fboundp 'beads-detail-goto-parent))
  (should (commandp 'beads-detail-goto-parent)))

(ert-deftest beads-detail-test-view-children-defined ()
  "Test that beads-detail-view-children is defined as a command."
  (should (fboundp 'beads-detail-view-children))
  (should (commandp 'beads-detail-view-children)))

(ert-deftest beads-detail-test-keybinding-goto-parent ()
  "Test that P is bound to beads-detail-goto-parent."
  (with-temp-buffer
    (beads-detail-mode)
    (should (eq (lookup-key beads-detail-mode-map (kbd "P"))
                #'beads-detail-goto-parent))))

(ert-deftest beads-detail-test-keybinding-view-children ()
  "Test that C is bound to beads-detail-view-children."
  (with-temp-buffer
    (beads-detail-mode)
    (should (eq (lookup-key beads-detail-mode-map (kbd "C"))
                #'beads-detail-view-children))))

(ert-deftest beads-detail-test-goto-parent-no-parent ()
  "Test that beads-detail-goto-parent errors when no parent."
  (with-temp-buffer
    (beads-detail-mode)
    (setq beads-detail--current-issue '((id . "bd-test")
                                        (title . "Test")
                                        (status . "open")
                                        (priority . 2)
                                        (issue_type . "task")))
    (should-error (beads-detail-goto-parent) :type 'user-error)))

;;; Comment tests (no daemon)

(ert-deftest beads-detail-test-add-comment-defined ()
  "Test that beads-detail-add-comment is defined as a command."
  (should (fboundp 'beads-detail-add-comment))
  (should (commandp 'beads-detail-add-comment)))

(ert-deftest beads-detail-test-keybinding-add-comment ()
  "Test that c is bound to beads-detail-add-comment."
  (with-temp-buffer
    (beads-detail-mode)
    (should (eq (lookup-key beads-detail-mode-map (kbd "c"))
                #'beads-detail-add-comment))))

(ert-deftest beads-detail-test-add-comment-empty-text ()
  "Test that beads-detail-add-comment errors on empty text."
  (with-temp-buffer
    (beads-detail-mode)
    (setq beads-detail--current-issue '((id . "bd-test")
                                        (title . "Test")
                                        (status . "open")
                                        (priority . 2)
                                        (issue_type . "task")))
    (cl-letf (((symbol-function 'read-string) (lambda (_) "")))
      (should-error (beads-detail-add-comment) :type 'user-error))))

;;; Mode tests (no daemon)

(ert-deftest beads-detail-test-mode-derived-from-special ()
  "Test that beads-detail-mode is derived from special-mode."
  (with-temp-buffer
    (beads-detail-mode)
    (should (derived-mode-p 'special-mode))
    (should (derived-mode-p 'beads-detail-mode))))

(ert-deftest beads-detail-test-mode-buffer-read-only ()
  "Test that beads-detail-mode sets buffer to read-only."
  (with-temp-buffer
    (beads-detail-mode)
    (should buffer-read-only)))

(ert-deftest beads-detail-test-mode-keybinding-refresh ()
  "Test that beads-detail-mode binds 'g' to beads-detail-refresh."
  (with-temp-buffer
    (beads-detail-mode)
    (should (eq (lookup-key beads-detail-mode-map (kbd "g"))
                #'beads-detail-refresh))))

(ert-deftest beads-detail-test-mode-keybinding-quit ()
  "Test that beads-detail-mode binds 'q' to quit-window."
  (with-temp-buffer
    (beads-detail-mode)
    (should (eq (lookup-key beads-detail-mode-map (kbd "q"))
                #'quit-window))))

(ert-deftest beads-detail-test-mode-keybinding-edit ()
  "Test that beads-detail-mode binds 'e' to edit prefix map."
  (with-temp-buffer
    (beads-detail-mode)
    (should (keymapp (lookup-key beads-detail-mode-map (kbd "e"))))
    (should (eq (lookup-key beads-detail-mode-map (kbd "e d"))
                #'beads-detail-edit-description))))

(ert-deftest beads-detail-test-mode-keybinding-label-prefix ()
  "Test that 'e l' is a prefix map for label commands."
  (with-temp-buffer
    (beads-detail-mode)
    (should (keymapp (lookup-key beads-detail-mode-map (kbd "e l"))))
    (should (eq (lookup-key beads-detail-mode-map (kbd "e l a"))
                #'beads-detail-edit-label-add))
    (should (eq (lookup-key beads-detail-mode-map (kbd "e l r"))
                #'beads-detail-edit-label-remove))))

(ert-deftest beads-detail-test-label-add-defined ()
  "Test that beads-detail-edit-label-add is defined as a command."
  (should (fboundp 'beads-detail-edit-label-add))
  (should (commandp 'beads-detail-edit-label-add)))

(ert-deftest beads-detail-test-label-remove-defined ()
  "Test that beads-detail-edit-label-remove is defined as a command."
  (should (fboundp 'beads-detail-edit-label-remove))
  (should (commandp 'beads-detail-edit-label-remove)))

(ert-deftest beads-detail-test-label-add-calls-rpc ()
  "Test that beads-detail-edit-label-add calls beads-client-label-add."
  (let ((rpc-called nil)
        (rpc-args nil))
    (with-temp-buffer
      (beads-detail-mode)
      (setq beads-detail--current-issue '((id . "test-123")
                                          (title . "Test")
                                          (status . "open")
                                          (priority . 2)
                                          (issue_type . "task")
                                          (labels . ["existing"])))
      (cl-letf (((symbol-function 'read-string)
                 (lambda (_prompt)
                   "new-label"))
                ((symbol-function 'beads-client-label-add)
                 (lambda (id label)
                   (setq rpc-called t)
                   (setq rpc-args (list id label))))
                ((symbol-function 'beads-detail-refresh)
                 (lambda () nil)))
        (beads-detail-edit-label-add)
        (should rpc-called)
        (should (equal rpc-args '("test-123" "new-label")))))))

(ert-deftest beads-detail-test-label-add-empty-input ()
  "Test that beads-detail-edit-label-add ignores empty input."
  (let ((rpc-called nil))
    (with-temp-buffer
      (beads-detail-mode)
      (setq beads-detail--current-issue '((id . "test-123")
                                          (title . "Test")
                                          (status . "open")
                                          (priority . 2)
                                          (issue_type . "task")))
      (cl-letf (((symbol-function 'read-string)
                 (lambda (_prompt) ""))
                ((symbol-function 'beads-client-label-add)
                 (lambda (_id _label)
                   (setq rpc-called t))))
        (beads-detail-edit-label-add)
        (should-not rpc-called)))))

(ert-deftest beads-detail-test-label-remove-no-labels ()
  "Test that beads-detail-edit-label-remove handles issues with no labels."
  (let ((completing-read-called nil))
    (with-temp-buffer
      (beads-detail-mode)
      (setq beads-detail--current-issue '((id . "test-123")
                                          (title . "Test")
                                          (status . "open")
                                          (priority . 2)
                                          (issue_type . "task")
                                          (labels . [])))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (&rest _)
                   (setq completing-read-called t)
                   "")))
        (beads-detail-edit-label-remove)
        (should-not completing-read-called)))))

(ert-deftest beads-detail-test-label-remove-calls-rpc ()
  "Test that beads-detail-edit-label-remove calls beads-client-label-remove."
  (let ((rpc-called nil)
        (rpc-args nil))
    (with-temp-buffer
      (beads-detail-mode)
      (setq beads-detail--current-issue '((id . "test-456")
                                          (title . "Test")
                                          (status . "open")
                                          (priority . 2)
                                          (issue_type . "task")
                                          (labels . ["label1" "label2"])))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt _choices &rest _)
                   "label1"))
                ((symbol-function 'beads-client-label-remove)
                 (lambda (id label)
                   (setq rpc-called t)
                   (setq rpc-args (list id label))))
                ((symbol-function 'beads-detail-refresh)
                 (lambda () nil)))
        (beads-detail-edit-label-remove)
        (should rpc-called)
        (should (equal rpc-args '("test-456" "label1")))))))

(ert-deftest beads-detail-test-mode-inherits-parent-keybindings ()
  "Test that beads-detail-mode inherits special-mode keybindings."
  (with-temp-buffer
    (beads-detail-mode)
    (should (commandp (lookup-key beads-detail-mode-map (kbd "SPC"))))))

(ert-deftest beads-detail-test-mode-sets-buffer-name ()
  "Test that beads-detail-mode sets appropriate buffer name pattern."
  (with-temp-buffer
    (beads-detail-mode)
    (should (eq major-mode 'beads-detail-mode))))

;;; Integration tests (require bd CLI)

(ert-deftest beads-detail-test-show-creates-buffer ()
  "Test that beads-detail-show creates detail buffer."
  :tags '(:integration)
  (skip-unless (beads-test-integration-enabled-p))
  (skip-unless (beads-client--find-database))
  (let ((issues (beads-client-list '(:limit 1))))
    (skip-unless (> (length issues) 0))
    (let* ((issue-id (alist-get 'id (aref issues 0)))
           (buffer-name (format "*Beads: %s*" issue-id)))
      (when (get-buffer buffer-name)
        (kill-buffer buffer-name))
      (unwind-protect
          (progn
            (beads-detail-show issue-id)
            (should (get-buffer buffer-name))
            (with-current-buffer buffer-name
              (should (eq major-mode 'beads-detail-mode))))
        (when (get-buffer buffer-name)
          (kill-buffer buffer-name))))))

(ert-deftest beads-detail-test-show-displays-content ()
  "Test that beads-detail-show displays issue content."
  :tags '(:integration)
  (skip-unless (beads-test-integration-enabled-p))
  (skip-unless (beads-client--find-database))
  (let ((issues (beads-client-list '(:limit 1))))
    (skip-unless (> (length issues) 0))
    (let* ((issue-id (alist-get 'id (aref issues 0)))
           (buffer-name (format "*Beads: %s*" issue-id)))
      (when (get-buffer buffer-name)
        (kill-buffer buffer-name))
      (unwind-protect
          (progn
            (beads-detail-show issue-id)
            (with-current-buffer buffer-name
              (goto-char (point-min))
              (should (search-forward issue-id nil t))))
        (when (get-buffer buffer-name)
          (kill-buffer buffer-name))))))

(ert-deftest beads-detail-test-show-sets-buffer-local-issue-id ()
  "Test that beads-detail-show sets buffer-local issue ID."
  :tags '(:integration)
  (skip-unless (beads-test-integration-enabled-p))
  (skip-unless (beads-client--find-database))
  (let ((issues (beads-client-list '(:limit 1))))
    (skip-unless (> (length issues) 0))
    (let* ((issue-id (alist-get 'id (aref issues 0)))
           (buffer-name (format "*Beads: %s*" issue-id)))
      (when (get-buffer buffer-name)
        (kill-buffer buffer-name))
      (unwind-protect
          (progn
            (beads-detail-show issue-id)
            (with-current-buffer buffer-name
              (should (boundp 'beads-detail--current-issue-id))
              (should (equal beads-detail--current-issue-id issue-id))))
        (when (get-buffer buffer-name)
          (kill-buffer buffer-name))))))

(ert-deftest beads-detail-test-refresh-updates-content ()
  "Test that beads-detail-refresh updates buffer content."
  :tags '(:integration)
  (skip-unless (beads-test-integration-enabled-p))
  (skip-unless (beads-client--find-database))
  (let ((issues (beads-client-list '(:limit 1))))
    (skip-unless (> (length issues) 0))
    (let* ((issue-id (alist-get 'id (aref issues 0)))
           (buffer-name (format "*Beads: %s*" issue-id)))
      (when (get-buffer buffer-name)
        (kill-buffer buffer-name))
      (unwind-protect
          (progn
            (beads-detail-show issue-id)
            (with-current-buffer buffer-name
              (let ((old-content (buffer-string)))
                (beads-detail-refresh)
                (let ((new-content (buffer-string)))
                  (should (string= old-content new-content))))))
        (when (get-buffer buffer-name)
          (kill-buffer buffer-name))))))

(ert-deftest beads-detail-test-show-error-handling ()
  "Test that beads-detail-show handles RPC errors gracefully."
  :tags '(:integration)
  (skip-unless (beads-test-integration-enabled-p))
  (skip-unless (beads-client--find-database))
  (let ((buffer-name "*Beads: bd-nonexistent*"))
    (when (get-buffer buffer-name)
      (kill-buffer buffer-name))
    (unwind-protect
        (should-error (beads-detail-show "bd-nonexistent")
                      :type 'beads-client-error)
      (when (get-buffer buffer-name)
        (kill-buffer buffer-name)))))

(ert-deftest beads-detail-test-refresh-without-issue-id ()
  "Test that beads-detail-refresh handles missing issue ID gracefully."
  (with-temp-buffer
    (beads-detail-mode)
    (should-error (beads-detail-refresh))))

;;; Regression tests for bdel-ylt / bdel-kry / bdel-91f.2

(defun beads-detail-test--capture-on-refresh (buffer issue)
  "Run `beads-detail--render-vui' on BUFFER with ISSUE and return the
on-refresh callback that would be passed to vui. Useful for testing
the closure created inside `beads-detail--render-vui'."
  (require 'beads-vui)
  (let (captured-on-refresh)
    (cl-letf (((symbol-function 'vui-mount) (lambda (&rest _) nil))
              ((symbol-function 'vui-component)
               (lambda (_component &rest args)
                 (setq captured-on-refresh (plist-get args :on-refresh))
                 nil)))
      (beads-detail--render-vui buffer issue))
    captured-on-refresh))

(ert-deftest beads-detail-test-vui-render-sets-issue-id-after-mode ()
  "Regression test for bdel-ylt: `beads-detail--render-vui' must set
`beads-detail--current-issue-id' AFTER activating
`beads-detail-vui-mode', because `define-derived-mode' calls
`kill-all-local-variables' and would otherwise wipe the var. The
vui on-click refresh handler depends on this var being bound."
  (let ((buffer (generate-new-buffer "*beads-detail-test-vui*"))
        (issue '((id . "bd-vui-regression-1")
                 (title . "Regression")
                 (status . "open")
                 (priority . 2)
                 (issue_type . "task"))))
    (require 'beads-vui)
    (unwind-protect
        (cl-letf (((symbol-function 'vui-mount) (lambda (&rest _) nil))
                  ((symbol-function 'vui-component) (lambda (&rest _) nil)))
          (beads-detail--render-vui buffer issue)
          (with-current-buffer buffer
            (should (derived-mode-p 'beads-detail-vui-mode))
            (should (equal beads-detail--current-issue-id
                           "bd-vui-regression-1"))
            (should (equal (alist-get 'id beads-detail--current-issue)
                           "bd-vui-regression-1"))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest beads-detail-test-render-vui-passes-on-refresh-closure ()
  "`beads-detail--render-vui' must pass an on-refresh callback to vui."
  (let ((buffer (generate-new-buffer "*beads-detail-test-vui-closure*"))
        (issue '((id . "bd-vui-closure-1")
                 (title . "Closure capture")
                 (status . "open")
                 (priority . 2)
                 (issue_type . "task"))))
    (unwind-protect
        (let ((on-refresh (beads-detail-test--capture-on-refresh
                           buffer issue)))
          (should (functionp on-refresh)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest beads-detail-test-vui-relationships-renders-dependency-lists ()
  "Regression test for bdel-91f.10: dependency buckets must render vnodes.
Do not pass raw `mapcar' cons lists as `vui-fragment' children, or
opening an issue with dependencies from list mode signals an
unknown-vnode error."
  (require 'beads-vui)
  (let ((issue '((id . "bd-vui-deps-1")
                 (title . "Dependency render regression")
                 (status . "open")
                 (priority . 2)
                 (issue_type . "task")
                 (dependencies . [((id . "bd-parent")
                                   (title . "Parent")
                                   (status . "open")
                                   (dependency_type . "parent-child"))
                                  ((id . "bd-blocker")
                                   (title . "Blocker")
                                   (status . "open")
                                   (dependency_type . "blocks"))])
                 (dependents . [((id . "bd-child")
                                 (title . "Child")
                                 (status . "open")
                                 (dependency_type . "parent-child"))]))))
    (with-temp-buffer
      (vui-render (vui-component 'beads-vui-relationships :issue issue)
                  (current-buffer))
      (let ((content (buffer-string)))
        (should (string-match-p "Parent:" content))
        (should (string-match-p "Depends on:" content))
        (should (string-match-p "Children:" content))))))

(ert-deftest beads-detail-test-refresh-fn-switches-to-detail-buffer ()
  "Regression test: refresh-fn closure captured by `beads-detail--render-vui'
must switch to the detail buffer it was created for, even when invoked
from a different current-buffer (e.g. after the minibuffer edit handler
finishes). This prevents the \"No issue to refresh\" vui warning from
bdel-91f.2."
  (let ((detail-buffer (generate-new-buffer "*beads-detail-test-refresh-fn*"))
        (other-buffer (generate-new-buffer "*beads-detail-test-other*"))
        (issue '((id . "bd-refresh-fn-1")
                 (title . "Refresh closure")
                 (status . "open")
                 (priority . 2)
                 (issue_type . "task")))
        observed-buffer)
    (unwind-protect
        (let ((on-refresh (beads-detail-test--capture-on-refresh
                           detail-buffer issue)))
          (should (functionp on-refresh))
          (cl-letf (((symbol-function 'beads-detail-refresh)
                     (lambda () (setq observed-buffer (current-buffer)))))
            ;; Invoke the closure from a DIFFERENT current-buffer (as
            ;; would happen after the minibuffer edit handler finishes).
            (with-current-buffer other-buffer
              (funcall on-refresh))
            (should (eq observed-buffer detail-buffer))))
      (when (buffer-live-p detail-buffer) (kill-buffer detail-buffer))
      (when (buffer-live-p other-buffer) (kill-buffer other-buffer)))))

(ert-deftest beads-detail-test-refresh-fn-survives-killed-buffer ()
  "refresh-fn closure must not error when its detail buffer was killed
before it fires (buffer-live-p guard)."
  (let ((detail-buffer (generate-new-buffer "*beads-detail-test-killed*"))
        (issue '((id . "bd-killed-1")
                 (title . "Killed buffer")
                 (status . "open")
                 (priority . 2)
                 (issue_type . "task"))))
    (let ((on-refresh (beads-detail-test--capture-on-refresh
                       detail-buffer issue)))
      (kill-buffer detail-buffer)
      ;; Should be a no-op, not an error.
      (should-not (funcall on-refresh)))))

(ert-deftest beads-detail-test-edit-refresh-flow-no-error ()
  "End-to-end regression for bdel-91f.2: invoking the on-refresh closure
after an edit handler completes must NOT raise \"No issue to refresh\".

Simulates the full flow: render-vui builds the closure, the edit
handler eventually calls the closure from outside the detail buffer's
context, and the closure must successfully call beads-client-show via
beads-detail-refresh without user-error."
  (let ((detail-buffer (generate-new-buffer "*beads-detail-test-flow*"))
        (issue '((id . "bd-flow-1")
                 (title . "Flow")
                 (status . "open")
                 (priority . 2)
                 (issue_type . "task")))
        (client-show-called-with nil))
    (unwind-protect
        (let ((on-refresh (beads-detail-test--capture-on-refresh
                           detail-buffer issue)))
          (cl-letf (((symbol-function 'beads-client-show)
                     (lambda (id)
                       (setq client-show-called-with id)
                       ;; Return updated issue
                       '((id . "bd-flow-1")
                         (title . "Flow updated")
                         (status . "in_progress")
                         (priority . 2)
                         (issue_type . "task"))))
                    ;; Stub re-render: avoid pulling in vui internals
                    ;; for this flow test.
                    ((symbol-function 'beads-detail--render-vui)
                     (lambda (&rest _) nil)))
            ;; Invoke from a different buffer to mimic post-edit context.
            (with-temp-buffer
              (funcall on-refresh))
            (should (equal client-show-called-with "bd-flow-1"))))
      (when (buffer-live-p detail-buffer) (kill-buffer detail-buffer)))))

(ert-deftest beads-detail-test-buffer-reuse ()
  "Test that calling beads-detail-show twice reuses the same buffer."
  :tags '(:integration)
  (skip-unless (beads-test-integration-enabled-p))
  (skip-unless (beads-client--find-database))
  (let ((issues (beads-client-list '(:limit 1))))
    (skip-unless (> (length issues) 0))
    (let* ((issue-id (alist-get 'id (aref issues 0)))
           (buffer-name (format "*Beads: %s*" issue-id)))
      (when (get-buffer buffer-name)
        (kill-buffer buffer-name))
      (unwind-protect
          (progn
            (beads-detail-show issue-id)
            (let ((first-buffer (get-buffer buffer-name)))
              (beads-detail-show issue-id)
              (should (eq first-buffer (get-buffer buffer-name)))))
        (when (get-buffer buffer-name)
          (kill-buffer buffer-name))))))

;;; Markdown fontification tests

(ert-deftest beads-detail-test-fontify-markdown-defined ()
  "Test that beads-detail--fontify-markdown is defined."
  (should (fboundp 'beads-detail--fontify-markdown)))

(ert-deftest beads-detail-test-fontify-markdown-returns-string ()
  "Test that beads-detail--fontify-markdown returns a string."
  (let ((result (beads-detail--fontify-markdown "test text")))
    (should (stringp result))
    (should (string= result "test text"))))

(ert-deftest beads-detail-test-fontify-markdown-preserves-content ()
  "Test that beads-detail--fontify-markdown preserves text content."
  (let ((text "# Heading\n\n**bold** and *italic*\n\n`code`"))
    (let ((result (beads-detail--fontify-markdown text)))
      (should (string-match-p "Heading" result))
      (should (string-match-p "bold" result))
      (should (string-match-p "italic" result))
      (should (string-match-p "code" result)))))

(ert-deftest beads-detail-test-fontify-markdown-disabled ()
  "Test that beads-detail--fontify-markdown respects the disable flag."
  (let ((beads-detail-render-markdown nil)
        (text "**bold** text"))
    (let ((result (beads-detail--fontify-markdown text)))
      (should (string= result text)))))

(ert-deftest beads-detail-test-render-markdown-customizable ()
  "Test that beads-detail-render-markdown is a customizable option."
  (should (custom-variable-p 'beads-detail-render-markdown)))

(ert-deftest beads-detail-test-render-description-with-markdown ()
  "Test that description is rendered through markdown fontification."
  (let ((beads-detail-render-markdown nil))
    (with-temp-buffer
      (let ((issue '((id . "bd-test")
                     (title . "Test")
                     (status . "open")
                     (priority . 2)
                     (issue_type . "task")
                     (description . "**bold** description"))))
        (beads-detail--render issue)
        (let ((buffer-content (buffer-string)))
          (should (string-match-p "\\*\\*bold\\*\\* description" buffer-content)))))))

(ert-deftest beads-detail-test-render-comments-with-markdown ()
  "Test that comments are rendered through markdown fontification."
  (let ((beads-detail-render-markdown nil))
    (with-temp-buffer
      (let ((issue '((id . "bd-test")
                     (title . "Test")
                     (status . "open")
                     (priority . 2)
                     (issue_type . "task")
                     (comments . [((id . 1)
                                   (author . "alice")
                                   (text . "**bold** comment")
                                   (created_at . "2026-01-06T10:00:00Z"))]))))
        (beads-detail--render issue)
        (let ((buffer-content (buffer-string)))
          (should (string-match-p "\\*\\*bold\\*\\* comment" buffer-content)))))))

(provide 'beads-detail-test)
;;; beads-detail-test.el ends here
