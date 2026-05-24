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
(require 'seq)

(declare-function vui-mount "vui")
(declare-function vui-component "vui")
(defvar vui-mode-map)
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

(defcustom beads-detail-render-markdown t
  "Whether to render markdown syntax highlighting in detail view.
When non-nil and `markdown-mode' is available, descriptions, design notes,
acceptance criteria, and comments will be fontified with markdown highlighting."
  :type 'boolean
  :group 'beads-detail)

(defcustom beads-detail-use-vui t
  "Whether to use vui.el for rendering the detail view.
When non-nil, uses declarative vui components for layout.
When nil, uses traditional text insertion with properties."
  :type 'boolean
  :group 'beads-detail)

(defcustom beads-detail-section-style 'heading
  "How to render content sections in the detail view.
`heading'   - section heading with indented content, no separator line.
`separator' - horizontal rule above each section heading (classic style)."
  :type '(choice (const :tag "Heading only (compact)" heading)
                 (const :tag "Separator line above heading" separator))
  :group 'beads-detail)

(defcustom beads-detail-vui-editable t
  "Whether to show inline edit buttons in vui detail view.
Only applies when `beads-detail-use-vui' is non-nil."
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
  "Keymap for label commands in beads-detail-mode.")

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
  "Keymap for edit commands in beads-detail-mode.")

(defvar beads-detail-mode-map
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
    (define-key map (kbd "M-n") #'beads-detail-next-section)
    (define-key map (kbd "M-p") #'beads-detail-previous-section)
    map)
  "Keymap for beads-detail-mode.")

(define-derived-mode beads-detail-mode special-mode "Beads-Detail"
  "Major mode for displaying Beads issue details.

\\{beads-detail-mode-map}"
  (setq buffer-read-only t)
  (setq truncate-lines nil)
  (beads-show-hint))

(declare-function vui-mode "vui")

(defvar beads-detail-vui-mode-map
  (make-sparse-keymap)
  "Keymap for `beads-detail-vui-mode'.
Inherits bindings from both `beads-detail-mode-map' and `vui-mode-map'.")

(define-derived-mode beads-detail-vui-mode vui-mode "Beads-Detail"
  "Major mode for vui-based Beads detail view.
Derives from `vui-mode' and inherits keybindings from `beads-detail-mode'.

\\{beads-detail-vui-mode-map}"
  (setq truncate-lines nil)
  (set-keymap-parent beads-detail-vui-mode-map
                     (make-composed-keymap beads-detail-mode-map vui-mode-map))
  (beads-show-hint))

;; Configure evil-mode IF user has it loaded (does not enable evil)
(with-eval-after-load 'evil
  (evil-set-initial-state 'beads-detail-mode 'normal)
  (evil-make-overriding-map beads-detail-mode-map 'normal)
  (evil-set-initial-state 'beads-detail-vui-mode 'normal)
  (evil-make-overriding-map beads-detail-vui-mode-map 'normal))

(defun beads-detail-open (issue)
  "Open ISSUE in a dedicated detail buffer in bottom window.
Creates a unique buffer per issue and focuses it."
  (let* ((id (alist-get 'id issue))
         (buffer-name (format "*Beads Detail: %s*" id))
         (buffer (get-buffer-create buffer-name)))
    (with-current-buffer buffer
      (if beads-detail-use-vui
          (beads-detail--render-vui buffer issue)
        (unless (eq major-mode 'beads-detail-mode)
          (beads-detail-mode))
        (setq beads-detail--current-issue-id id)
        (setq beads-detail--current-issue issue)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (beads-detail--render issue)
          (goto-char (point-min)))))
    (let ((window (display-buffer buffer
                                  '((display-buffer-reuse-mode-window
                                     display-buffer-below-selected)
                                    (mode . beads-detail-mode)
                                    (window-height . 0.4)))))
      (when window
        (select-window window)))))

(defun beads-detail-show (issue)
  "Display ISSUE in preview buffer (for preview mode).
Uses a single reusable buffer in a side window without focusing."
  (let* ((id (alist-get 'id issue))
         (buffer (get-buffer-create "*Beads Preview*")))
    (with-current-buffer buffer
      (if beads-detail-use-vui
          (beads-detail--render-vui buffer issue)
        (unless (eq major-mode 'beads-detail-mode)
          (beads-detail-mode))
        (setq beads-detail--current-issue-id id)
        (setq beads-detail--current-issue issue)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (beads-detail--render issue)
          (goto-char (point-min)))))
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
            (if (derived-mode-p 'beads-detail-vui-mode)
                (beads-detail--render-vui buffer issue)
              (let ((inhibit-read-only t))
                (erase-buffer)
                (beads-detail--render issue)))
            (goto-char (min saved-point (point-max)))
            (when (and window saved-start)
              (set-window-start window (min saved-start (point-max))))))))))

(defun beads-detail--refresh-list-buffers ()
  "Refresh all Beads list buffers."
  (dolist (buf (buffer-list))
    (when (and (buffer-live-p buf)
               (memq (buffer-local-value 'major-mode buf)
                     '(beads-list-mode beads-org-list-mode)))
      (with-current-buffer buf
        (if (eq major-mode 'beads-org-list-mode)
            (beads-org-list-refresh)
          (beads-list-refresh))))))

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
          (if (derived-mode-p 'beads-detail-vui-mode)
              (beads-detail--render-vui buffer issue)
            (let ((inhibit-read-only t))
              (erase-buffer)
              (beads-detail--render issue)))
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
    (beads-edit-field-markdown id :description description)))

(defun beads-detail-edit-design ()
  "Edit the design notes of the current issue."
  (interactive)
  (let* ((issue (beads-detail--require-issue))
         (id (alist-get 'id issue))
         (design (alist-get 'design issue)))
    (beads-edit-field-markdown id :design design)))

(defun beads-detail-edit-acceptance ()
  "Edit the acceptance criteria of the current issue."
  (interactive)
  (let* ((issue (beads-detail--require-issue))
         (id (alist-get 'id issue))
         (acceptance (alist-get 'acceptance_criteria issue)))
    (beads-edit-field-markdown id :acceptance-criteria acceptance)))

(defun beads-detail-edit-notes ()
  "Edit the notes of the current issue."
  (interactive)
  (let* ((issue (beads-detail--require-issue))
         (id (alist-get 'id issue))
         (notes (alist-get 'notes issue)))
    (beads-edit-field-markdown id :notes notes)))

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

(defun beads-detail--render-vui (buffer issue)
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

(defun beads-detail--render (issue)
  "Insert formatted ISSUE content into current buffer."
  (beads-detail--insert-header issue)
  (insert "\n")
  (beads-detail--insert-separator ?═)
  (insert "\n")
  (beads-detail--insert-metadata issue)
  (insert "\n")
  (beads-detail--insert-separator ?─)
  (insert "\n\n")

  (when-let ((description (alist-get 'description issue)))
    (unless (string-empty-p description)
      (beads-detail--insert-section "Description" description)))

  (when-let ((design (alist-get 'design issue)))
    (unless (string-empty-p design)
      (beads-detail--insert-section "Design Notes" design)))

  (when-let ((acceptance (alist-get 'acceptance_criteria issue)))
    (unless (string-empty-p acceptance)
      (beads-detail--insert-section "Acceptance Criteria" acceptance)))

  (when-let ((notes (alist-get 'notes issue)))
    (unless (string-empty-p notes)
      (beads-detail--insert-section "Notes" notes)))

  (when-let ((comments (alist-get 'comments issue)))
    (when (> (length comments) 0)
      (beads-detail--insert-comments comments))))

(defun beads-detail--insert-header (issue)
  "Insert ID and title for ISSUE."
  (let ((id (alist-get 'id issue))
        (title (alist-get 'title issue "")))
    (insert (propertize (format "[%s] " id) 'face 'beads-detail-id-face))
    (insert (propertize title 'face 'beads-detail-title-face))))

(defun beads-detail--insert-metadata (issue)
  "Insert status, priority, type, assignee, timestamps, and labels for ISSUE."
  (let ((status (alist-get 'status issue))
        (priority (alist-get 'priority issue))
        (type (alist-get 'issue_type issue))
        (owner (alist-get 'owner issue))
        (assignee (alist-get 'assignee issue))
        (created-by (alist-get 'created_by issue))
        (created (alist-get 'created_at issue))
        (started (alist-get 'started_at issue))
        (updated (alist-get 'updated_at issue))
        (closed (alist-get 'closed_at issue))
        (close-reason (alist-get 'close_reason issue))
        (external-ref (alist-get 'external_ref issue))
        (labels (alist-get 'labels issue))
        (parent (or (alist-get 'parent issue)
                    (alist-get 'parent_id issue))))

    (beads-detail--insert-field "Status" status)
    (insert "     ")
    (beads-detail--insert-field "Priority" (format "P%d" priority))
    (insert "     ")
    (beads-detail--insert-field "Type" type)
    (insert "\n")

    (let ((first t))
      (dolist (pair (list (cons "Owner" owner)
                          (cons "Assignee" assignee)
                          (cons "Created by" created-by)))
        (when (cdr pair)
          (unless first (insert "  "))
          (beads-detail--insert-field (car pair) (cdr pair))
          (setq first nil)))
      (unless first (insert "\n")))

    (let ((first t))
      (dolist (pair (list (cons "Created" created)
                          (cons "Started" started)
                          (cons "Updated" updated)
                          (cons "Closed" closed)))
        (when (cdr pair)
          (unless first (insert "  "))
          (beads-detail--insert-field (car pair)
                                      (beads-detail--format-timestamp (cdr pair)))
          (setq first nil)))
      (unless first (insert "\n")))

    (when (and close-reason (not (string-empty-p close-reason)))
      (beads-detail--insert-field "Close reason" close-reason)
      (insert "\n"))

    (when (and external-ref (not (string-empty-p external-ref)))
      (beads-detail--insert-field "External ref" external-ref)
      (insert "\n"))

    ;; Only show simple Parent: <id> link when the parent will NOT be
    ;; rendered as a richer item in the relationships section below
    ;; (i.e. when the dependencies array does not include a parent-child
    ;; entry).
    (when (and parent
               (not (beads-detail--has-parent-child-dep-p issue)))
      (beads-detail--insert-parent-link parent)
      (insert "\n"))

    (beads-detail--insert-field "Labels"
                                (if (and labels (> (length labels) 0))
                                    (mapconcat #'identity (append labels nil) ", ")
                                  "(none)"))
    (insert "\n")

    (beads-detail--insert-relationships issue)))

(defun beads-detail--insert-field (label value)
  "Insert a LABEL: VALUE pair."
  (insert (propertize (concat label ": ") 'face 'beads-detail-label-face))
  (insert (propertize (or value "") 'face 'beads-detail-value-face)))

(defun beads-detail--insert-parent-link (parent-id)
  "Insert clickable parent link for PARENT-ID."
  (insert (propertize "Parent: " 'face 'beads-detail-label-face))
  (insert-text-button parent-id
                      'action (lambda (_) (beads-detail-goto-parent))
                      'follow-link t
                      'help-echo "Click to view parent issue"))

(defun beads-detail--insert-dep-link (dep)
  "Insert clickable link for dependency/dependent DEP."
  (let* ((id (alist-get 'id dep))
         (title (alist-get 'title dep ""))
         (status (alist-get 'status dep))
         (type (alist-get 'dependency_type dep)))
    (insert "  ")
    (insert-text-button id
                        'action (lambda (_button)
                                  (condition-case err
                                      (beads-core-open-issue-detail dep)
                                    (beads-client-error
                                     (message "Failed to open %s: %s" id (error-message-string err)))))
                        'follow-link t
                        'help-echo (format "Click to view %s" id))
    (insert " ")
    (insert (truncate-string-to-width title 40 nil nil "…"))
    (when status
      (insert (format " [%s]" status)))
    (when (and type (not (string= type "parent-child")))
      (insert (format " (%s)" type)))
    (insert "\n")))

(defun beads-detail--has-parent-child-dep-p (issue)
  "Return non-nil if ISSUE has a parent-child dependency entry."
  (let ((deps (alist-get 'dependencies issue))
        (found nil))
    (seq-doseq (dep deps)
      (when (string= (alist-get 'dependency_type dep) "parent-child")
        (setq found t)))
    found))

(defun beads-detail--bucket-deps (deps)
  "Bucket DEPS (vector or list) by `dependency_type'.
Returns an alist of (TYPE . LIST-OF-DEPS), in stable insertion order."
  (let ((buckets nil))
    (seq-doseq (dep deps)
      (let* ((type (or (alist-get 'dependency_type dep) "blocks"))
             (cell (assoc type buckets)))
        (if cell
            (setcdr cell (append (cdr cell) (list dep)))
          (push (cons type (list dep)) buckets))))
    (nreverse buckets)))

(defun beads-detail--insert-rel-group (label deps)
  "Insert a labeled relationship group with LABEL and DEPS list."
  (when (and deps (> (length deps) 0))
    (insert (propertize (concat label ":") 'face 'beads-detail-label-face))
    (insert "\n")
    (dolist (dep deps)
      (beads-detail--insert-dep-link dep))))

(defun beads-detail--insert-relationships (issue)
  "Insert categorized relationships and epic progress for ISSUE.
Groups dependencies/dependents by `dependency_type' into Parent,
Children, Discovered From, Discovered, Related, Depends on, Dependents
sections, matching `bd show' output."
  (let* ((deps (alist-get 'dependencies issue))
         (dependents (alist-get 'dependents issue))
         (dep-buckets (beads-detail--bucket-deps deps))
         (dependent-buckets (beads-detail--bucket-deps dependents))
         (epic-total (alist-get 'epic_total_children issue))
         (epic-closed (alist-get 'epic_closed_children issue)))

    ;; Parent (from dependencies with type=parent-child)
    (beads-detail--insert-rel-group
     "Parent" (alist-get "parent-child" dep-buckets nil nil #'string=))

    ;; Children (from dependents with type=parent-child)
    (beads-detail--insert-rel-group
     "Children" (alist-get "parent-child" dependent-buckets nil nil #'string=))

    ;; Epic progress
    (when (and epic-total (> epic-total 0))
      (let ((pct (if (and epic-closed (> epic-total 0))
                     (round (* 100.0 (/ (float (or epic-closed 0)) epic-total)))
                   0)))
        (insert (propertize "  ◐ " 'face 'beads-detail-label-face))
        (insert (format "%d/%d complete (%d%%)\n"
                        (or epic-closed 0) epic-total pct))))

    ;; Discovered From (deps)
    (beads-detail--insert-rel-group
     "Discovered From" (alist-get "discovered-from" dep-buckets nil nil #'string=))

    ;; Discovered (dependents)
    (beads-detail--insert-rel-group
     "Discovered" (alist-get "discovered-from" dependent-buckets nil nil #'string=))

    ;; Related (either side, merged & de-duped by id)
    (let* ((related-in (alist-get "related" dep-buckets nil nil #'string=))
           (related-out (alist-get "related" dependent-buckets nil nil #'string=))
           (combined (append related-in related-out))
           (seen (make-hash-table :test 'equal))
           (unique nil))
      (dolist (dep combined)
        (let ((id (alist-get 'id dep)))
          (unless (gethash id seen)
            (puthash id t seen)
            (push dep unique))))
      (beads-detail--insert-rel-group "Related" (nreverse unique)))

    ;; Generic depends-on / dependents (anything not parent/discovered/related)
    (dolist (cell dep-buckets)
      (let ((type (car cell)))
        (unless (member type '("parent-child" "discovered-from" "related"))
          (beads-detail--insert-rel-group
           (if (string= type "blocks") "Depends on" (capitalize type))
           (cdr cell)))))
    (dolist (cell dependent-buckets)
      (let ((type (car cell)))
        (unless (member type '("parent-child" "discovered-from" "related"))
          (beads-detail--insert-rel-group
           (if (string= type "blocks") "Dependents" (capitalize type))
           (cdr cell)))))))

(defun beads-detail--fontify-markdown (text)
  "Fontify TEXT with markdown-mode if available and enabled.
Returns the fontified string with text properties, or the original text
if markdown rendering is disabled or markdown-mode is unavailable."
  (if (and beads-detail-render-markdown
           (fboundp 'markdown-mode))
      (with-temp-buffer
        (insert text)
        (delay-mode-hooks (markdown-mode))
        (font-lock-mode 1)
        (font-lock-ensure)
        (buffer-string))
    text))

(defun beads-detail--insert-section (title content)
  "Insert a section with TITLE and CONTENT."
  (pcase beads-detail-section-style
    ('separator
     (beads-detail--insert-separator ?─)
     (insert "\n")
     (insert (propertize (concat title ":\n") 'face 'beads-detail-header-face))
     (insert "\n")
     (insert (beads-detail--fontify-markdown content))
     (insert "\n\n"))
    (_
     (insert (propertize (concat title ":") 'face 'beads-detail-header-face))
     (insert "\n\n")
     (insert "  " (replace-regexp-in-string
                    "\n" "\n  " (beads-detail--fontify-markdown content)))
     (insert "\n\n"))))

(defun beads-detail--insert-comments (comments)
  "Insert COMMENTS section.
COMMENTS is a vector/list of comment objects with id, author, text, created_at."
  (beads-detail--insert-separator ?─)
  (insert "\n")
  (insert (propertize (format "Comments (%d):\n" (length comments))
                      'face 'beads-detail-header-face))
  (insert "\n")
  (seq-doseq (comment comments)
    (let ((author (alist-get 'author comment "unknown"))
          (text (alist-get 'text comment ""))
          (created (alist-get 'created_at comment)))
      (insert (propertize (format "[%s] " author) 'face 'beads-detail-label-face))
      (when created
        (insert (propertize (beads-detail--format-timestamp created)
                            'face 'shadow)))
      (insert "\n")
      (insert (beads-detail--fontify-markdown text))
      (insert "\n\n"))))

(defun beads-detail--insert-separator (char)
  "Insert a separator line using CHAR."
  (insert (make-string 60 char)))

(defun beads-detail--format-timestamp (timestamp)
  "Format TIMESTAMP string for display."
  (if (stringp timestamp)
      (let ((parts (split-string timestamp "T")))
        (if (car parts)
            (car parts)
          timestamp))
    (format "%s" timestamp)))

(defun beads-detail--section-positions ()
  "Return sorted list of section header positions.
Finds all positions where `beads-detail-header-face' is used."
  (let ((positions nil)
        (pos (point-min)))
    (while (< pos (point-max))
      (when (eq (get-text-property pos 'face) 'beads-detail-header-face)
        (push pos positions)
        (setq pos (next-single-property-change pos 'face nil (point-max))))
      (setq pos (or (next-single-property-change pos 'face nil (point-max))
                    (point-max))))
    (nreverse positions)))

(defun beads-detail-next-section ()
  "Move point to the next section header in the detail view."
  (interactive)
  (let* ((positions (beads-detail--section-positions))
         (next (seq-find (lambda (pos) (> pos (point))) positions)))
    (when next
      (goto-char next))))

(defun beads-detail-previous-section ()
  "Move point to the previous section header in the detail view."
  (interactive)
  (let* ((positions (reverse (beads-detail--section-positions)))
         (prev (seq-find (lambda (pos) (< pos (point))) positions)))
    (when prev
      (goto-char prev))))

(provide 'beads-detail)
;;; beads-detail.el ends here
