;;; beads-detail.el --- Issue detail view for Beads -*- lexical-binding: t -*-

;; Copyright (C) 2025 Christian Tietze

;; Author: Christian Tietze
;; Keywords: tools, ui

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; Full issue detail view with all fields and metadata display.

;;; Code:

(require 'beads-client)
(require 'beads-backend)
(require 'beads-edit)
(require 'vui)

(declare-function vui-mount "vui")
(declare-function vui-component "vui")
(declare-function beads-vui-detail-view "beads-vui")

(declare-function beads-menu "beads-transient")
(declare-function beads-delete-issue "beads-transient")
(declare-function beads-reopen-issue "beads-transient")
(declare-function beads-list "beads-list")
(declare-function beads-list-refresh "beads-list")
(declare-function beads-org-list-refresh "beads-list")
(declare-function beads-list--refresh-current-view "beads-list")
(declare-function beads-filter-by-parent "beads-filter")
(declare-function beads-form-open "beads-form")
(declare-function beads-hierarchy-show "beads-hierarchy")
(require 'beads-core)
(declare-function evil-set-initial-state "evil-core")
(declare-function evil-make-overriding-map "evil-core")

(defgroup beads-detail nil
  "Issue detail display for Beads."
  :group 'beads)

(defcustom beads-detail-section-style 'heading
  "How to render content sections in the detail view.
`heading'   - section heading with indented content, no separator line.
`separator' - horizontal rule above each section heading (classic style)."
  :type '(choice (const :tag "Heading only (compact)" heading)
                 (const :tag "Separator line above heading" separator))
  :group 'beads-detail)

(defcustom beads-detail-vui-editable t
  "Whether to show inline edit buttons in the detail view."
  :type 'boolean
  :group 'beads-detail)

(defface beads-detail-id-face
  '((t :weight bold))
  "Face for issue ID in detail view.")

(defface beads-detail-title-face
  '((t :height 1.2 :weight bold))
  "Face for issue title in detail view.")

(defface beads-detail-header-face
  '((t :weight bold :underline t))
  "Face for section headers in detail view.")

(defface beads-detail-label-face
  '((t :weight bold))
  "Face for field labels in detail view.")

(defface beads-detail-value-face
  '((t :inherit default))
  "Face for field values in detail view.")

(defvar-local beads-detail--current-issue-id nil
  "Issue ID currently displayed in this buffer.")

(defvar-local beads-detail--current-issue nil
  "Full issue data currently displayed in this buffer.")

(defvar beads-detail-label-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'beads-detail-edit-label-add)
    (define-key map (kbd "r") #'beads-detail-edit-label-remove)
    map)
  "Keymap for label commands in `beads-detail-vui-mode'.")

(defvar beads-detail-edit-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "d") #'beads-detail-edit-description)
    (define-key map (kbd "D") #'beads-detail-edit-design)
    (define-key map (kbd "a") #'beads-detail-edit-acceptance)
    (define-key map (kbd "n") #'beads-detail-edit-notes)
    (define-key map (kbd "t") #'beads-detail-edit-title)
    (define-key map (kbd "s") #'beads-detail-edit-status)
    (define-key map (kbd "p") #'beads-detail-edit-priority)
    (define-key map (kbd "T") #'beads-detail-edit-type)
    (define-key map (kbd "A") #'beads-detail-edit-assignee)
    (define-key map (kbd "x") #'beads-detail-edit-external-ref)
    (define-key map (kbd "l") beads-detail-label-map)
    map)
  "Keymap for edit commands in `beads-detail-vui-mode'.")

(defvar beads-detail-vui-base-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "g") #'beads-detail-refresh)
    (define-key map (kbd "q") #'beads-core-quit-window-kill-buffer)
    (define-key map (kbd "e") beads-detail-edit-map)
    (define-key map (kbd "E") #'beads-detail-edit-form)
    (define-key map (kbd "H") #'beads-hierarchy-show)
    (define-key map (kbd "P") #'beads-detail-goto-parent)
    (define-key map (kbd "C") #'beads-detail-view-children)
    (define-key map (kbd "c") #'beads-detail-add-comment)
    (define-key map (kbd "D") #'beads-delete-issue)
    (define-key map (kbd "R") #'beads-reopen-issue)
    (define-key map (kbd "?") #'beads-menu)
    (define-key map (kbd "C-c m") #'beads-menu)
    map)
  "Base keymap for `beads-detail-vui-mode'.")

(declare-function vui-mode "vui")

(defvar beads-detail-vui-mode-map
  (make-sparse-keymap)
  "Keymap for `beads-detail-vui-mode'.
Inherits bindings from both `beads-detail-vui-base-map' and `vui-mode-map'.")

(define-derived-mode beads-detail-vui-mode vui-mode "Beads-Detail"
  "Major mode for vui-based Beads detail view.
Derives from `vui-mode' and installs Beads detail keybindings.

\\{beads-detail-vui-mode-map}"
  (setq truncate-lines nil)
  (set-keymap-parent beads-detail-vui-mode-map
                     (make-composed-keymap beads-detail-vui-base-map vui-mode-map))
  (beads-show-hint))

;; Configure evil-mode IF user has it loaded (does not enable evil)
(with-eval-after-load 'evil
  (evil-set-initial-state 'beads-detail-vui-mode 'normal)
  (evil-make-overriding-map beads-detail-vui-mode-map 'normal))

(defun beads-detail-open (issue)
  "Open ISSUE in a dedicated detail buffer in bottom window.
Creates a unique buffer per issue and focuses it."
  (let* ((id (alist-get 'id issue))
         (buffer-name (format "*Beads Detail: %s*" id))
         (buffer (get-buffer-create buffer-name)))
    (with-current-buffer buffer
      (beads-detail--mount-vui buffer issue))
    (let ((window (display-buffer buffer
                                  '((display-buffer-reuse-mode-window
                                     display-buffer-below-selected)
                                    (mode . beads-detail-vui-mode)
                                    (window-height . 0.4)))))
      (when window
        (select-window window)))))

(defun beads-detail-show (issue)
  "Display ISSUE in preview buffer (for preview mode).
Uses a single reusable buffer in a side window without focusing."
  (let* ((id (alist-get 'id issue))
         (buffer (get-buffer-create "*Beads Preview*")))
    (with-current-buffer buffer
      (beads-detail--mount-vui buffer issue))
    (display-buffer buffer '((display-buffer-in-side-window)
                             (side . right)
                             (window-width . 0.4)))))

(defun beads-detail-rerender-if-current (id issue)
  "Re-render ISSUE in its detail buffer iff that buffer still shows ID.

Used by the standard lazy-load detail navigation path: the buffer is
opened immediately with partial list/report data, then the full issue
arrives asynchronously and is rendered here.  The ID guard prevents
stomping on the user if they have already navigated away."
  (let* ((buffer-name (format "*Beads Detail: %s*" id))
         (buffer (get-buffer buffer-name)))
    (when (and buffer (buffer-live-p buffer))
      (with-current-buffer buffer
        (when (equal beads-detail--current-issue-id id)
          (let* ((window (get-buffer-window buffer))
                 (saved-point (point))
                 (saved-start (and window (window-start window))))
            (setq beads-detail--current-issue issue)
            (beads-detail--mount-vui buffer issue)
            (goto-char (min saved-point (point-max)))
            (when (and window saved-start)
              (set-window-start window (min saved-start (point-max))))))))))

(defun beads-detail--refresh-list-buffers ()
  "Refresh all Beads list buffers."
  (dolist (buf (buffer-list))
    (when (and (buffer-live-p buf)
               (memq (buffer-local-value 'major-mode buf)
                     '(beads-org-list-mode)))
      (with-current-buffer buf
        (beads-org-list-refresh)))))

(defun beads-detail-refresh ()
  "Re-fetch and redisplay current issue."
  (interactive)
  (unless beads-detail--current-issue-id
    (user-error "No issue to refresh"))
  (let ((saved-point (point))
        (saved-start (window-start))
        (buffer (current-buffer)))
    (condition-case err
        (let ((issue (beads-client-show beads-detail--current-issue-id)))
          (setq beads-detail--current-issue issue)
          (beads-detail--mount-vui buffer issue)
          (goto-char (min saved-point (point-max)))
          (when-let ((win (get-buffer-window buffer)))
            (set-window-start win (min saved-start (point-max))))
          (beads-detail--refresh-list-buffers)
          (message "Refreshed issue %s" beads-detail--current-issue-id))
      (beads-client-error
       (message "Failed to refresh issue: %s" (error-message-string err))))))

(defun beads-detail--require-issue ()
  "Return current issue or signal error."
  (unless beads-detail--current-issue
    (user-error "No issue in current buffer"))
  beads-detail--current-issue)

(defun beads-detail-goto-parent ()
  "Navigate to the parent issue of the current issue."
  (interactive)
  (let* ((issue (beads-detail--require-issue))
         (parent-id (or (alist-get 'parent issue)
                        (alist-get 'parent_id issue))))
    (unless parent-id
      (user-error "This issue has no parent"))
    (beads-core-open-issue-detail parent-id)))

(defun beads-detail-view-children ()
  "View children of the current issue in a filtered list.
Filters the issue list to show only issues whose parent is this issue."
  (interactive)
  (let* ((issue (beads-detail--require-issue))
         (id (alist-get 'id issue)))
    (require 'beads-list)
    (require 'beads-filter)
    (beads-list)
    (with-current-buffer (current-buffer)
      (setq-local beads-list--filter (beads-filter-by-parent id))
      (beads-list--refresh-current-view)
      (message "Showing children of %s" id))))

(defun beads-detail-add-comment ()
  "Add a comment to the current issue.
Uses CLI fallback since RPC does not support comment_add."
  (interactive)
  (let* ((issue (beads-detail--require-issue))
         (id (alist-get 'id issue))
         (text (read-string (format "Comment on %s: " id))))
    (when (string-empty-p text)
      (user-error "Comment text is required"))
    (let ((exit-code (beads-backend-cli-call-raw
                      (list "comments" "add" id text))))
      (if (zerop exit-code)
          (progn
            (message "Added comment to %s" id)
            (beads-detail-refresh))
        (user-error "Failed to add comment")))))

(defun beads-detail-edit-description ()
  "Edit the description of the current issue."
  (interactive)
  (let* ((issue (beads-detail--require-issue))
         (id (alist-get 'id issue))
         (description (alist-get 'description issue)))
    (beads-edit-field-markdown id :description description t)))

(defun beads-detail-edit-design ()
  "Edit the design notes of the current issue."
  (interactive)
  (let* ((issue (beads-detail--require-issue))
         (id (alist-get 'id issue))
         (design (alist-get 'design issue)))
    (beads-edit-field-markdown id :design design t)))

(defun beads-detail-edit-acceptance ()
  "Edit the acceptance criteria of the current issue."
  (interactive)
  (let* ((issue (beads-detail--require-issue))
         (id (alist-get 'id issue))
         (acceptance (alist-get 'acceptance_criteria issue)))
    (beads-edit-field-markdown id :acceptance-criteria acceptance t)))

(defun beads-detail-edit-notes ()
  "Edit the notes of the current issue."
  (interactive)
  (let* ((issue (beads-detail--require-issue))
         (id (alist-get 'id issue))
         (notes (alist-get 'notes issue)))
    (beads-edit-field-markdown id :notes notes t)))

(defun beads-detail-edit-title ()
  "Edit the title of the current issue."
  (interactive)
  (let* ((issue (beads-detail--require-issue))
         (id (alist-get 'id issue))
         (title (alist-get 'title issue)))
    (when (beads-edit-field-minibuffer id :title title "Title: ")
      (beads-detail-refresh))))

(defun beads-detail-edit-status ()
  "Edit the status of the current issue."
  (interactive)
  (let* ((issue (beads-detail--require-issue))
         (id (alist-get 'id issue))
         (status (alist-get 'status issue)))
    (when (beads-edit-field-completing
           id :status status "Status: "
           '("open" "in_progress" "blocked" "hooked" "closed"))
      (beads-detail-refresh))))

(defun beads-detail-edit-priority ()
  "Edit the priority of the current issue."
  (interactive)
  (let* ((issue (beads-detail--require-issue))
         (id (alist-get 'id issue))
         (priority (alist-get 'priority issue))
         (priority-str (format "P%d" priority))
         (choices '("P0" "P1" "P2" "P3" "P4")))
    (when-let ((new-value (completing-read "Priority: " choices nil t priority-str)))
      (unless (string= new-value priority-str)
        (let ((new-priority (string-to-number (substring new-value 1))))
          (condition-case err
              (progn
                (beads-client-update id :priority new-priority)
                (message "Updated priority for %s" id)
                (beads-detail-refresh))
            (beads-client-error
             (message "Failed to update: %s" (error-message-string err)))))))))

(defun beads-detail-edit-type ()
  "Edit the type of the current issue."
  (interactive)
  (let* ((issue (beads-detail--require-issue))
         (id (alist-get 'id issue))
         (type (alist-get 'issue_type issue)))
    (when (beads-edit-field-completing
           id :issue-type type "Type: "
           '("bug" "feature" "task" "epic" "chore" "gate" "convoy" "agent" "role"))
      (beads-detail-refresh))))

(defun beads-detail-edit-assignee ()
  "Edit the assignee of the current issue."
  (interactive)
  (let* ((issue (beads-detail--require-issue))
         (id (alist-get 'id issue))
         (assignee (alist-get 'assignee issue)))
    (when (beads-edit-field-minibuffer id :assignee assignee "Assignee: ")
      (beads-detail-refresh))))

(defun beads-detail-edit-external-ref ()
  "Edit the external reference of the current issue."
  (interactive)
  (let* ((issue (beads-detail--require-issue))
         (id (alist-get 'id issue))
         (external-ref (alist-get 'external_ref issue)))
    (when (beads-edit-field-minibuffer id :external-ref external-ref "External ref: ")
      (beads-detail-refresh))))

(defun beads-detail-edit-label-add ()
  "Add a label to the current issue."
  (interactive)
  (let* ((issue (beads-detail--require-issue))
         (id (alist-get 'id issue))
         (labels (alist-get 'labels issue))
         (labels-str (if (and labels (> (length labels) 0))
                         (format " [current: %s]" (mapconcat #'identity (append labels nil) ", "))
                       ""))
         (label (read-string (format "Add label%s: " labels-str))))
    (when (and label (not (string-empty-p label)))
      (condition-case err
          (progn
            (beads-client-label-add id label)
            (message "Added label '%s' to %s" label id)
            (beads-detail-refresh))
        (beads-client-error
         (message "Failed to add label: %s" (error-message-string err)))))))

(defun beads-detail-edit-label-remove ()
  "Remove a label from the current issue."
  (interactive)
  (let* ((issue (beads-detail--require-issue))
         (id (alist-get 'id issue))
         (labels (alist-get 'labels issue))
         (labels-list (when labels (append labels nil))))
    (if (not labels-list)
        (message "Issue %s has no labels to remove" id)
      (let ((label (completing-read "Remove label: " labels-list nil t)))
        (when (and label (not (string-empty-p label)))
          (condition-case err
              (progn
                (beads-client-label-remove id label)
                (message "Removed label '%s' from %s" label id)
                (beads-detail-refresh))
            (beads-client-error
             (message "Failed to remove label: %s" (error-message-string err)))))))))

(defun beads-detail-edit-form ()
  "Open form editor for the current issue."
  (interactive)
  (let ((issue (beads-detail--require-issue)))
    (require 'beads-form)
    (beads-form-open issue)))

(defun beads-detail--mount-vui (buffer issue)
  "Render ISSUE into BUFFER using vui.el components."
  (require 'beads-vui)
    (let ((refresh-fn (lambda ()
                        (when (buffer-live-p buffer)
                          (with-current-buffer buffer
                            (beads-detail-refresh)))))
        (navigate-fn (lambda (id)
                       (beads-core-open-issue-detail id))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'beads-detail-vui-mode)
        (beads-detail-vui-mode))
      ;; NOTE: define-derived-mode (and special-mode/vui-mode) call
      ;; `kill-all-local-variables', wiping any buffer-locals set before
      ;; mode activation. Set them AFTER the mode is active so that the
      ;; vui on-click refresh handler can find the current issue id.
      (setq beads-detail--current-issue-id (alist-get 'id issue))
      (setq beads-detail--current-issue issue))
    (save-window-excursion
      (vui-mount (vui-component 'beads-vui-detail-view
                                :issue issue
                                :on-refresh refresh-fn
                                :on-navigate navigate-fn
                                :editable beads-detail-vui-editable)
                 (buffer-name buffer)))))

(provide 'beads-detail)
;;; beads-detail.el ends here
