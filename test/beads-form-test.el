;;; beads-form-test.el --- Tests for beads-form.el -*- lexical-binding: t; -*-

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'beads-form)
(require 'beads-detail)

(ert-deftest beads-form-test-vui-mode-defined ()
  "Test that `beads-form-vui-mode' is defined."
  (should (fboundp 'beads-form-vui-mode)))

(ert-deftest beads-form-test-open-defined ()
  "Test that `beads-form-open' is defined."
  (should (fboundp 'beads-form-open)))

(ert-deftest beads-form-test-vui-save-defined ()
  "Test that `beads-form-vui-save' is defined as a command."
  (should (fboundp 'beads-form-vui-save))
  (should (commandp 'beads-form-vui-save)))

(ert-deftest beads-form-test-vui-cancel-defined ()
  "Test that `beads-form-vui-cancel' is defined as a command."
  (should (fboundp 'beads-form-vui-cancel))
  (should (commandp 'beads-form-vui-cancel)))

(ert-deftest beads-form-test-keybindings ()
  "Test that keybindings are set up correctly."
  (should (eq (lookup-key beads-form-vui-mode-map (kbd "C-c C-c"))
              #'beads-form-vui-save))
  (should (eq (lookup-key beads-form-vui-mode-map (kbd "C-c C-k"))
              #'beads-form-vui-cancel)))

(ert-deftest beads-form-test-open-creates-buffer ()
  "Test that beads-form-open creates a buffer."
  (let ((buffer nil)
        (issue '((id . "test-123")
                 (title . "Test Issue")
                 (status . "open")
                 (priority . 2)
                 (issue_type . "task"))))
    (unwind-protect
        (cl-letf (((symbol-function 'beads-get-types)
                   (lambda () '("bug" "feature" "task")))
                  ((symbol-function 'switch-to-buffer)
                   (lambda (buf &rest _) buf))
                  ((symbol-function 'pop-to-buffer)
                   (lambda (buf) (setq buffer buf))))
          (beads-form-open issue)
          (should buffer)
          (should (buffer-live-p buffer))
          (should (string= "*Beads Form: test-123*"
                           (buffer-name buffer))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest beads-form-test-open-sets-vui-mode-and-actions ()
  "Test that `beads-form-open' installs the VUI form mode and actions."
  (let ((buffer nil)
        (issue '((id . "test-456")
                 (title . "Test Issue")
                 (status . "open")
                 (priority . 2)
                 (issue_type . "task"))))
    (unwind-protect
        (cl-letf (((symbol-function 'beads-get-types)
                   (lambda () '("bug" "feature" "task")))
                  ((symbol-function 'switch-to-buffer)
                   (lambda (buf &rest _) buf))
                  ((symbol-function 'pop-to-buffer)
                   (lambda (buf) (setq buffer buf))))
          (beads-form-open issue)
          (with-current-buffer buffer
            (should (derived-mode-p 'beads-form-vui-mode))
            (should (functionp beads-form--vui-save-action))
            (should (functionp beads-form--vui-cancel-action))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest beads-form-test-open-renders-fields ()
  "Test that `beads-form-open' renders all expected VUI fields."
  (let ((buffer nil)
        (issue '((id . "test-789")
                 (title . "Test Title")
                 (status . "in_progress")
                 (priority . 1)
                 (issue_type . "feature")
                 (description . "Test description"))))
    (unwind-protect
        (cl-letf (((symbol-function 'beads-get-types)
                   (lambda () '("bug" "feature" "task")))
                  ((symbol-function 'switch-to-buffer)
                   (lambda (buf &rest _) buf))
                  ((symbol-function 'pop-to-buffer)
                   (lambda (buf) (setq buffer buf))))
          (beads-form-open issue)
          (with-current-buffer buffer
            (let ((content (buffer-string)))
              (should (string-match-p "Edit Issue: test-789" content))
              (should (string-match-p "Title:" content))
              (should (string-match-p "Status:" content))
              (should (string-match-p "Priority:" content))
              (should (string-match-p "Type:" content))
              (should (string-match-p "Description:" content)))))
      (when (and buffer (buffer-live-p buffer))
        (kill-buffer buffer)))))

(ert-deftest beads-form-test-detail-edit-form-keybinding ()
  "Test that E is bound to beads-detail-edit-form in detail mode."
  (with-temp-buffer
    (beads-detail-vui-mode)
    (should (eq (lookup-key beads-detail-vui-base-map (kbd "E"))
                #'beads-detail-edit-form))))

(ert-deftest beads-form-test-detail-edit-form-defined ()
  "Test that beads-detail-edit-form is defined as a command."
  (should (fboundp 'beads-detail-edit-form))
  (should (commandp 'beads-detail-edit-form)))

(provide 'beads-form-test)
;;; beads-form-test.el ends here
