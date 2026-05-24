;;; beads-transient-test.el --- Tests for beads-transient.el -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the Beads transient menu system.
;;
;; Test categories:
;; 1. Transient definition tests - test beads-menu is a transient prefix (no daemon)
;; 2. Keybinding tests - test ? and C-c m in beads-list-mode and beads-detail-mode (no daemon)
;; 3. Placeholder command tests - test placeholder commands exist (no daemon)
;;
;; Note on test isolation:
;; All tests in this file are unit tests that do not require the daemon.
;; They test menu definitions, keybindings, and command availability only.

;;; Code:

(require 'ert)
(require 'beads-transient)
(require 'beads-list)
(require 'beads-detail)

;;; Transient definition tests (no daemon needed)

(ert-deftest beads-transient-test-menu-defined ()
  "Test that beads-menu is defined as a command."
  (should (commandp 'beads-menu)))

(ert-deftest beads-transient-test-menu-is-transient-prefix ()
  "Test that beads-list-menu is a transient prefix command."
  (should (get 'beads-list-menu 'transient--prefix)))

(ert-deftest beads-transient-test-menu-has-prefix-object ()
  "Test that beads-list-menu has a transient prefix object."
  (let ((prefix-obj (get 'beads-list-menu 'transient--prefix)))
    (should prefix-obj)))

;;; Keybinding tests (no daemon)

(ert-deftest beads-transient-test-list-mode-help-key ()
  "Test that ? is bound to beads-menu in beads-list-mode."
  (with-temp-buffer
    (beads-list-mode)
    (should (eq (lookup-key beads-list-mode-map (kbd "?"))
                #'beads-menu))))

(ert-deftest beads-transient-test-org-list-mode-help-key ()
  "Test that ? is bound to beads-menu in beads-org-list-mode."
  (with-temp-buffer
    (beads-org-list-mode)
    (should (eq (lookup-key beads-org-list-mode-map (kbd "?"))
                #'beads-menu))))

(ert-deftest beads-transient-test-list-mode-menu-key ()
  "Test that C-c m is bound to beads-menu in beads-list-mode."
  (with-temp-buffer
    (beads-list-mode)
    (should (eq (lookup-key beads-list-mode-map (kbd "C-c m"))
                #'beads-menu))))

(ert-deftest beads-transient-test-org-list-mode-menu-key ()
  "Test that C-c m is bound to beads-menu in beads-org-list-mode."
  (with-temp-buffer
    (beads-org-list-mode)
    (should (eq (lookup-key beads-org-list-mode-map (kbd "C-c m"))
                #'beads-menu))))

(ert-deftest beads-transient-test-detail-mode-help-key ()
  "Test that ? is bound to beads-menu in beads-detail-mode."
  (with-temp-buffer
    (beads-detail-mode)
    (should (eq (lookup-key beads-detail-mode-map (kbd "?"))
                #'beads-menu))))

(ert-deftest beads-transient-test-detail-mode-menu-key ()
  "Test that C-c m is bound to beads-menu in beads-detail-mode."
  (with-temp-buffer
    (beads-detail-mode)
    (should (eq (lookup-key beads-detail-mode-map (kbd "C-c m"))
                #'beads-menu))))

(ert-deftest beads-transient-test-list-mode-keybindings-interactive ()
  "Test that beads-menu can be called interactively from beads-list-mode."
  (with-temp-buffer
    (beads-list-mode)
    (let ((cmd (lookup-key beads-list-mode-map (kbd "?"))))
      (should (commandp cmd))
      (should (eq cmd #'beads-menu)))))

(ert-deftest beads-transient-test-detail-mode-keybindings-interactive ()
  "Test that beads-menu can be called interactively from beads-detail-mode."
  (with-temp-buffer
    (beads-detail-mode)
    (let ((cmd (lookup-key beads-detail-mode-map (kbd "?"))))
      (should (commandp cmd))
      (should (eq cmd #'beads-menu)))))

;;; Placeholder command tests (no daemon)

(ert-deftest beads-transient-test-create-issue-defined ()
  "Test that beads-create-issue is defined."
  (should (fboundp 'beads-create-issue)))

(ert-deftest beads-transient-test-create-issue-interactive ()
  "Test that beads-create-issue is an interactive command."
  (should (commandp 'beads-create-issue)))

(ert-deftest beads-transient-test-create-issue-requires-title ()
  "Test that beads-create-issue requires a title."
  (cl-letf (((symbol-function 'read-string) (lambda (&rest _) ""))
            ((symbol-function 'completing-read) (lambda (&rest _) "task")))
    (let ((message-log-max t))
      (beads-create-issue)
      (with-current-buffer "*Messages*"
        (goto-char (point-max))
        (forward-line -1)
        (should (string-match-p "Title is required"
                               (buffer-substring (line-beginning-position)
                                                (line-end-position))))))))

(ert-deftest beads-transient-test-create-issue-passes-parent ()
  "Test that beads-create-issue passes an optional parent to create."
  (let (created-title created-args)
    (cl-letf (((symbol-function 'beads-get-types)
               (lambda () '("task" "bug")))
              ((symbol-function 'read-string)
               (lambda (prompt &rest _)
                 (cond
                  ((string= prompt "Title: ") "Child issue")
                  ((string= prompt "Parent issue ID (optional): ") "bd-parent")
                  (t ""))))
              ((symbol-function 'completing-read)
               (lambda (prompt &rest _)
                 (if (string= prompt "Priority: ") "P2" "task")))
              ((symbol-function 'beads-client-create)
               (lambda (title &rest args)
                 (setq created-title title
                       created-args args)
                 '((id . "bd-child")))))
      (beads-create-issue))
    (should (equal created-title "Child issue"))
    (should (equal (plist-get created-args :type) "task"))
    (should (equal (plist-get created-args :priority) 2))
    (should (equal (plist-get created-args :parent) "bd-parent"))))

(ert-deftest beads-transient-test-close-issue-defined ()
  "Test that beads-close-issue is defined."
  (should (fboundp 'beads-close-issue)))

(ert-deftest beads-transient-test-close-issue-interactive ()
  "Test that beads-close-issue is an interactive command."
  (should (commandp 'beads-close-issue)))

(ert-deftest beads-transient-test-close-issue-requires-context ()
  "Test that beads-close-issue requires an issue context."
  (with-temp-buffer
    (let ((message-log-max t))
      (beads-close-issue)
      (with-current-buffer "*Messages*"
        (goto-char (point-max))
        (forward-line -1)
        (should (string-match-p "No issue at point"
                               (buffer-substring (line-beginning-position)
                                                (line-end-position))))))))

(ert-deftest beads-transient-test-filter-status-defined ()
  "Test that beads-filter-status is defined."
  (should (fboundp 'beads-filter-status)))

(ert-deftest beads-transient-test-filter-status-interactive ()
  "Test that beads-filter-status is an interactive command."
  (should (commandp 'beads-filter-status)))

(ert-deftest beads-transient-test-filter-status-requires-list-mode ()
  "Test that beads-filter-status requires beads-list-mode."
  (with-temp-buffer
    (should-error (beads-filter-status) :type 'user-error)))

(ert-deftest beads-transient-test-filter-priority-defined ()
  "Test that beads-filter-priority is defined."
  (should (fboundp 'beads-filter-priority)))

(ert-deftest beads-transient-test-filter-priority-interactive ()
  "Test that beads-filter-priority is an interactive command."
  (should (commandp 'beads-filter-priority)))

(ert-deftest beads-transient-test-filter-priority-requires-list-mode ()
  "Test that beads-filter-priority requires beads-list-mode."
  (with-temp-buffer
    (should-error (beads-filter-priority) :type 'user-error)))

;;; Integration tests for menu structure

(ert-deftest beads-transient-test-menu-contains-list-command ()
  "Test that beads-menu includes beads-list command."
  (should (commandp 'beads-list))
  (should (commandp 'beads-list-legacy)))

(ert-deftest beads-transient-test-menu-contains-refresh-command ()
  "Test that beads-menu includes beads-list-refresh command."
  (should (commandp 'beads-list-refresh)))

(ert-deftest beads-transient-test-menu-contains-edit-command ()
  "Test that beads-detail-edit-description command exists."
  (should (commandp 'beads-detail-edit-description)))

(ert-deftest beads-transient-test-menu-contains-describe-mode ()
  "Test that beads-menu includes describe-mode command."
  (should (commandp 'describe-mode)))

(ert-deftest beads-transient-test-menu-contains-quit-command ()
  "Test that beads-menu includes transient-quit-one command."
  (should (commandp 'transient-quit-one)))

;;; Command availability tests

(ert-deftest beads-transient-test-all-placeholder-commands-available ()
  "Test that all placeholder commands are available and interactive."
  (should (commandp 'beads-create-issue))
  (should (commandp 'beads-close-issue))
  (should (commandp 'beads-filter-status))
  (should (commandp 'beads-filter-priority)))

(ert-deftest beads-transient-test-orphans-defined ()
  "Test that beads-orphans is defined."
  (should (fboundp 'beads-orphans)))

(ert-deftest beads-transient-test-orphans-interactive ()
  "Test that beads-orphans is an interactive command."
  (should (commandp 'beads-orphans)))

(ert-deftest beads-transient-test-keybindings-dont-conflict ()
  "Test that ? keybinding doesn't conflict with other bindings in list mode."
  (with-temp-buffer
    (beads-org-list-mode)
    (should (eq (lookup-key beads-org-list-mode-map (kbd "?")) #'beads-menu))
    (should (eq (lookup-key beads-org-list-mode-map (kbd "g")) #'beads-org-list-refresh))
    (should (eq (lookup-key beads-org-list-mode-map (kbd "RET")) #'beads-list-goto-issue))
    (should (eq (lookup-key beads-org-list-mode-map (kbd "q")) #'beads-list-quit))))

(ert-deftest beads-transient-test-detail-keybindings-dont-conflict ()
  "Test that ? keybinding doesn't conflict with other bindings in detail mode."
  (with-temp-buffer
    (beads-detail-mode)
    (should (eq (lookup-key beads-detail-mode-map (kbd "?")) #'beads-menu))
    (should (eq (lookup-key beads-detail-mode-map (kbd "g")) #'beads-detail-refresh))
    (should (keymapp (lookup-key beads-detail-mode-map (kbd "e"))))
    (should (eq (lookup-key beads-detail-mode-map (kbd "e d")) #'beads-detail-edit-description))
    (should (eq (lookup-key beads-detail-mode-map (kbd "e D")) #'beads-detail-edit-design))
    (should (eq (lookup-key beads-detail-mode-map (kbd "e a")) #'beads-detail-edit-acceptance))
    (should (eq (lookup-key beads-detail-mode-map (kbd "e n")) #'beads-detail-edit-notes))
    (should (eq (lookup-key beads-detail-mode-map (kbd "e l a")) #'beads-detail-edit-label-add))
    (should (eq (lookup-key beads-detail-mode-map (kbd "e l r")) #'beads-detail-edit-label-remove))
    (should (eq (lookup-key beads-detail-mode-map (kbd "q")) #'beads-core-quit-window-kill-buffer))))

;;; Dolt SQL toggle tests

(require 'beads-backend-dolt-sql)

(ert-deftest beads-transient-test-dolt-sql-toggle-defined ()
  "Test that beads-transient-toggle-dolt-sql is defined and interactive."
  (should (fboundp 'beads-transient-toggle-dolt-sql))
  (should (commandp 'beads-transient-toggle-dolt-sql)))

(ert-deftest beads-transient-test-dolt-sql-enabled-predicate ()
  "Test the enabled-p predicate reflects beads-dolt-sql-enabled."
  (let ((beads-dolt-sql-enabled nil))
    (should-not (beads-transient--dolt-sql-enabled-p)))
  (let ((beads-dolt-sql-enabled t))
    (should (beads-transient--dolt-sql-enabled-p))))

(ert-deftest beads-transient-test-dolt-sql-toggle-activates ()
  "Test that toggling from disabled calls the activate function."
  (let ((beads-dolt-sql-enabled nil)
        (called nil))
    (cl-letf (((symbol-function 'beads-backend-dolt-sql-activate)
               (lambda () (setq called 'activate)))
              ((symbol-function 'beads-backend-dolt-sql-deactivate)
               (lambda () (setq called 'deactivate))))
      (call-interactively 'beads-transient-toggle-dolt-sql)
      (should (eq called 'activate)))))

(ert-deftest beads-transient-test-dolt-sql-toggle-deactivates ()
  "Test that toggling from enabled calls the deactivate function."
  (let ((beads-dolt-sql-enabled t)
        (called nil))
    (cl-letf (((symbol-function 'beads-backend-dolt-sql-activate)
               (lambda () (setq called 'activate)))
              ((symbol-function 'beads-backend-dolt-sql-deactivate)
               (lambda () (setq called 'deactivate))))
      (call-interactively 'beads-transient-toggle-dolt-sql)
      (should (eq called 'deactivate)))))

(ert-deftest beads-transient-test-config-menu-defined ()
  "Test that beads-config-menu is a transient prefix."
  (should (commandp 'beads-config-menu))
  (should (get 'beads-config-menu 'transient--prefix)))

(provide 'beads-transient-test)
;;; beads-transient-test.el ends here
