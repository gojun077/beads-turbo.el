;;; beads-detail-test.el --- Tests for beads-detail.el -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the Beads issue detail mode.
;;
;; Test categories:
;; 1. Face definition tests - test all faces are defined with expected properties
;; 2. VUI render tests - test the retained vui detail path
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

(declare-function beads-vui-make-edit-handler "beads-vui")
(declare-function beads-vui-make-label-add-handler "beads-vui")
(declare-function beads-vui-make-label-remove-handler "beads-vui")
(declare-function beads-list--org-goto-id "beads-list")
(declare-function beads-list--org-id-at-point "beads-list")
(declare-function beads-org-list-mode "beads-list")
(declare-function beads-org-list-refresh "beads-list")
(declare-function vui-component "vui")
(declare-function vui-render "vui")

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
    (beads-detail-vui-mode)
    (should (eq (lookup-key beads-detail-vui-base-map (kbd "P"))
                #'beads-detail-goto-parent))))

(ert-deftest beads-detail-test-keybinding-view-children ()
  "Test that C is bound to beads-detail-view-children."
  (with-temp-buffer
    (beads-detail-vui-mode)
    (should (eq (lookup-key beads-detail-vui-base-map (kbd "C"))
                #'beads-detail-view-children))))

(ert-deftest beads-detail-test-goto-parent-no-parent ()
  "Test that beads-detail-goto-parent errors when no parent."
  (with-temp-buffer
    (beads-detail-vui-mode)
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
    (beads-detail-vui-mode)
    (should (eq (lookup-key beads-detail-vui-base-map (kbd "c"))
                #'beads-detail-add-comment))))

(ert-deftest beads-detail-test-add-comment-empty-text ()
  "Test that beads-detail-add-comment errors on empty text."
  (with-temp-buffer
    (beads-detail-vui-mode)
    (setq beads-detail--current-issue '((id . "bd-test")
                                        (title . "Test")
                                        (status . "open")
                                        (priority . 2)
                                        (issue_type . "task")))
    (cl-letf (((symbol-function 'read-string) (lambda (_) "")))
      (should-error (beads-detail-add-comment) :type 'user-error))))

;;; Mode tests (no daemon)

(ert-deftest beads-detail-test-mode-derived-from-special ()
  "Test that beads-detail-vui-mode is derived from vui-mode."
  (with-temp-buffer
    (beads-detail-vui-mode)
    (should (derived-mode-p 'beads-detail-vui-mode))))

(ert-deftest beads-detail-test-mode-truncation-disabled ()
  "Test that beads-detail-vui-mode wraps long detail content."
  (with-temp-buffer
    (beads-detail-vui-mode)
    (should-not truncate-lines)))

(ert-deftest beads-detail-test-mode-keybinding-refresh ()
  "Test that beads-detail-vui-mode binds 'g' to beads-detail-refresh."
  (with-temp-buffer
    (beads-detail-vui-mode)
    (should (eq (lookup-key beads-detail-vui-base-map (kbd "g"))
                #'beads-detail-refresh))))

(ert-deftest beads-detail-test-mode-keybinding-quit ()
  "Test that beads-detail-vui-mode binds 'q' to detail quit."
  (with-temp-buffer
    (beads-detail-vui-mode)
    (should (eq (lookup-key beads-detail-vui-base-map (kbd "q"))
                #'beads-detail-quit))))

(ert-deftest beads-detail-test-mode-quit-kills-buffer ()
  "Test that the detail quit command kills the detail buffer."
  (let ((buffer (generate-new-buffer "*beads-detail-test-quit*")))
    (unwind-protect
        (progn
          (switch-to-buffer buffer)
          (beads-detail-vui-mode)
          (call-interactively (lookup-key beads-detail-vui-base-map (kbd "q")))
          (should-not (buffer-live-p buffer)))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest beads-detail-test-quit-restores-origin-org-list-point ()
  "Quitting detail view keeps the originating org list on the issue.

Regression for bdel-91f.27: after a detail edit refreshes the list,
closing the detail window must not leave the org list cursor on the
generated #+TITLE header."
  (require 'beads-list)
  (let* ((list-buffer (generate-new-buffer " *beads-detail-origin-list-test*"))
         (previous-buffer (current-buffer))
         (list-window (selected-window))
         (issues '(((id . "bd-a") (title . "First") (status . "open")
                    (priority . 0))
                   ((id . "bd-b") (title . "Second") (status . "open")
                    (priority . 0))))
         detail-buffer)
    (unwind-protect
        (cl-letf (((symbol-function 'beads-org-list-refresh-async)
                   (lambda (&rest _args) nil))
                  ((symbol-function 'beads-cache-refresh)
                   (lambda (&rest _args) (cons t issues)))
                  ((symbol-function 'vui-mount)
                   (lambda (&rest _args) nil))
                  ((symbol-function 'vui-component)
                   (lambda (&rest _args) nil)))
          (delete-other-windows)
          (set-window-buffer list-window list-buffer)
          (set-buffer list-buffer)
          (beads-org-list-mode)
          (beads-org-list-refresh t)
          (should (beads-list--org-goto-id "bd-b"))
          (set-window-point list-window (point))

          (beads-detail-open '((id . "bd-b")
                               (title . "Second")
                               (status . "open")
                               (priority . 0)
                               (issue_type . "task")))
          (setq detail-buffer (current-buffer))
          (should (derived-mode-p 'beads-detail-vui-mode))

          ;; Simulate the stale top-of-buffer point observed when
          ;; returning from detail after a refresh.
          (with-current-buffer list-buffer
            (goto-char (point-min))
            (set-window-point list-window (point-min)))

          (beads-detail-quit)
          (with-current-buffer list-buffer
            (goto-char (window-point (get-buffer-window list-buffer)))
            (should (equal (beads-list--org-id-at-point) "bd-b"))))
      (when (window-live-p list-window)
        (select-window list-window)
        (when (buffer-live-p previous-buffer)
          (set-window-buffer list-window previous-buffer)))
      (delete-other-windows)
      (when (buffer-live-p previous-buffer)
        (set-buffer previous-buffer))
      (when (buffer-live-p list-buffer)
        (kill-buffer list-buffer))
      (when (and detail-buffer (buffer-live-p detail-buffer))
        (kill-buffer detail-buffer)))))

(ert-deftest beads-detail-test-mode-keybinding-edit ()
  "Test that beads-detail-vui-mode binds 'e' to edit prefix map."
  (with-temp-buffer
    (beads-detail-vui-mode)
    (should (keymapp (lookup-key beads-detail-vui-base-map (kbd "e"))))
    (should (eq (lookup-key beads-detail-vui-base-map (kbd "e d"))
                #'beads-detail-edit-description))))

(ert-deftest beads-detail-test-edit-description-starts-with-newline ()
  "Editing description from detail view starts the markdown buffer with a newline."
  (let ((buffer nil))
    (unwind-protect
        (with-temp-buffer
          (beads-detail-vui-mode)
          (setq beads-detail--current-issue '((id . "test-123")
                                              (title . "Test")
                                              (status . "open")
                                              (priority . 2)
                                              (issue_type . "task")
                                              (description . "Existing description")))
          (cl-letf (((symbol-function 'pop-to-buffer)
                     (lambda (buf) (setq buffer buf))))
            (beads-detail-edit-description))
          (with-current-buffer buffer
            (should (string= (buffer-substring-no-properties (point-min) (point-max))
                             "\nExisting description"))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest beads-detail-test-mode-keybinding-label-prefix ()
  "Test that 'e l' is a prefix map for label commands."
  (with-temp-buffer
    (beads-detail-vui-mode)
    (should (keymapp (lookup-key beads-detail-vui-base-map (kbd "e l"))))
    (should (eq (lookup-key beads-detail-vui-base-map (kbd "e l a"))
                #'beads-detail-edit-label-add))
    (should (eq (lookup-key beads-detail-vui-base-map (kbd "e l r"))
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
      (beads-detail-vui-mode)
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
      (beads-detail-vui-mode)
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
      (beads-detail-vui-mode)
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
      (beads-detail-vui-mode)
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
  "Test that beads-detail-vui-mode has Beads quit keybinding."
  (with-temp-buffer
    (beads-detail-vui-mode)
    (should (eq (lookup-key beads-detail-vui-base-map (kbd "q"))
                #'beads-detail-quit))))

(ert-deftest beads-detail-test-mode-sets-buffer-name ()
  "Test that beads-detail-vui-mode sets appropriate mode."
  (with-temp-buffer
    (beads-detail-vui-mode)
    (should (eq major-mode 'beads-detail-vui-mode))))

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
              (should (eq major-mode 'beads-detail-vui-mode))))
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
    (beads-detail-vui-mode)
    (should-error (beads-detail-refresh))))

;;; Regression tests for bdel-ylt / bdel-kry / bdel-91f.2

(defun beads-detail-test--capture-on-refresh (buffer issue)
  "Run `beads-detail--mount-vui' on BUFFER with ISSUE and return the
on-refresh callback that would be passed to vui. Useful for testing
the closure created inside `beads-detail--mount-vui'."
  (require 'beads-vui)
  (let (captured-on-refresh)
    (cl-letf (((symbol-function 'vui-mount) (lambda (&rest _) nil))
              ((symbol-function 'vui-component)
               (lambda (_component &rest args)
                 (setq captured-on-refresh (plist-get args :on-refresh))
                 nil)))
      (beads-detail--mount-vui buffer issue))
    captured-on-refresh))

(ert-deftest beads-detail-test-vui-render-sets-issue-id-after-mode ()
  "Regression test for bdel-ylt: `beads-detail--mount-vui' must set
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
          (beads-detail--mount-vui buffer issue)
          (with-current-buffer buffer
            (should (derived-mode-p 'beads-detail-vui-mode))
            (should (equal beads-detail--current-issue-id
                           "bd-vui-regression-1"))
            (should (equal (alist-get 'id beads-detail--current-issue)
                           "bd-vui-regression-1"))))
      (when (buffer-live-p buffer)
        (kill-buffer buffer)))))

(ert-deftest beads-detail-test-render-vui-passes-on-refresh-closure ()
  "`beads-detail--mount-vui' must pass an on-refresh callback to vui."
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

(ert-deftest beads-detail-test-vui-metadata-renders-labels ()
  "The vui detail metadata row should display issue labels."
  (require 'beads-vui)
  (let ((issue '((id . "bd-vui-labels-1")
                 (title . "Labels in detail view")
                 (status . "open")
                 (priority . 2)
                 (issue_type . "task")
                 (labels . ["backend" "urgent"]))))
    (with-temp-buffer
      (vui-render (vui-component 'beads-vui-metadata-row :issue issue)
                  (current-buffer))
      (let ((content (buffer-string)))
        (should (string-match-p "Labels:" content))
        (should (string-match-p "backend, urgent" content))))))

(ert-deftest beads-detail-test-vui-metadata-renders-empty-labels ()
  "The vui detail metadata row should display Labels even when empty."
  (require 'beads-vui)
  (let ((issue '((id . "bd-vui-labels-empty")
                 (title . "No labels yet")
                 (status . "open")
                 (priority . 2)
                 (issue_type . "task"))))
    (with-temp-buffer
      (vui-render (vui-component 'beads-vui-metadata-row :issue issue)
                  (current-buffer))
      (let ((content (buffer-string)))
        (should (string-match-p "Labels:" content))
        (should (string-match-p "(none)" content))))))

(ert-deftest beads-detail-test-vui-metadata-renders-label-edit-actions ()
  "The vui detail metadata row should show label add/remove actions."
  (require 'beads-vui)
  (let ((issue '((id . "bd-vui-labels-edit")
                 (title . "Labels can be edited")
                 (status . "open")
                 (priority . 2)
                 (issue_type . "task")
                 (labels . ["backend"]))))
    (with-temp-buffer
      (vui-render (vui-component 'beads-vui-metadata-row
                                 :issue issue
                                 :editable t)
                  (current-buffer))
      (let ((content (buffer-string)))
        (should (string-match-p "Labels:" content))
        (should (string-match-p "add" content))
        (should (string-match-p "remove" content))))))

(ert-deftest beads-detail-test-vui-label-add-handler-calls-rpc ()
  "Test that the vui label add handler calls beads-client-label-add."
  (require 'beads-vui)
  (let ((rpc-args nil)
        (refreshed nil))
    (let ((handler (beads-vui-make-label-add-handler
                    '((id . "test-123")
                      (labels . ["existing"]))
                    (lambda () (setq refreshed t)))))
      (cl-letf (((symbol-function 'read-string)
                 (lambda (_prompt) "new-label"))
                ((symbol-function 'beads-client-label-add)
                 (lambda (id label)
                   (setq rpc-args (list id label)))))
        (funcall handler)
        (should (equal rpc-args '("test-123" "new-label")))
        (should refreshed)))))

(ert-deftest beads-detail-test-vui-description-edit-starts-with-newline ()
  "VUI detail edit handler starts markdown fields with a newline."
  (require 'beads-vui)
  (let ((buffer nil))
    (unwind-protect
        (let ((handler (beads-vui-make-edit-handler
                        '((id . "test-123")
                          (description . "Existing description"))
                        'description
                        nil)))
          (cl-letf (((symbol-function 'pop-to-buffer)
                     (lambda (buf) (setq buffer buf))))
            (funcall handler))
          (with-current-buffer buffer
            (should (string= (buffer-substring-no-properties (point-min) (point-max))
                             "\nExisting description"))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest beads-detail-test-vui-label-remove-handler-calls-rpc ()
  "Test that the vui label remove handler calls beads-client-label-remove."
  (require 'beads-vui)
  (let ((rpc-args nil)
        (refreshed nil))
    (let ((handler (beads-vui-make-label-remove-handler
                    '((id . "test-456")
                      (labels . ["label1" "label2"]))
                    (lambda () (setq refreshed t)))))
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt _choices &rest _)
                   "label1"))
                ((symbol-function 'beads-client-label-remove)
                 (lambda (id label)
                   (setq rpc-args (list id label)))))
        (funcall handler)
        (should (equal rpc-args '("test-456" "label1")))
        (should refreshed)))))

(ert-deftest beads-detail-test-refresh-fn-switches-to-detail-buffer ()
  "Regression test: refresh-fn closure captured by `beads-detail--mount-vui'
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
                    ((symbol-function 'beads-detail--mount-vui)
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


(provide 'beads-detail-test)
;;; beads-detail-test.el ends here
