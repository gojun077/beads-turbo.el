;;; beads-transient.el --- Transient menus for Beads -*- lexical-binding: t -*-

;; Copyright (C) 2025 Christian Tietze

;; Author: Christian Tietze
;; Keywords: tools, transient

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

;; Transient menus for Beads commands and navigation.

;;; Code:

(require 'transient)
(require 'beads-client)
(require 'beads-filter)

(defvar beads-list--filter)
(defvar beads-list--marked)

(declare-function beads-list-mark "beads-list")
(declare-function beads-list-unmark "beads-list")
(declare-function beads-list-unmark-all "beads-list")
(declare-function beads-list-toggle-marks "beads-list")
(declare-function beads-list-mark-regexp "beads-list")
(declare-function beads-list-toggle-marked-filter "beads-list")
(declare-function beads-list-bulk-status "beads-list")
(declare-function beads-list-bulk-priority "beads-list")
(declare-function beads-list-bulk-close "beads-list")
(declare-function beads-list-bulk-delete "beads-list")
(declare-function beads-list-toggle-sort-mode "beads-list")
(declare-function beads-list-reverse-sort "beads-list")

(declare-function beads-filter-by-label "beads-filter")
(declare-function beads-filter-by-parent "beads-filter")
(declare-function beads-filter-ready "beads-filter")
(declare-function beads-filter-blocked "beads-filter")
(declare-function beads-filter-by-search "beads-filter")

(declare-function beads-list "beads-list")
(declare-function beads-list-refresh "beads-list")
(declare-function beads-list--refresh-current-view "beads-list")
(declare-function beads-list--get-issue-at-point "beads-list")
(declare-function beads-list-edit-form "beads-list")
(declare-function beads-list--sort-column-name "beads-list")
(declare-function beads-list-available-types "beads-list")
(declare-function beads-get-types "beads-client")
(declare-function beads-preview-mode "beads-preview")
(declare-function beads-detail-refresh "beads-detail")
(declare-function beads-detail-edit-form "beads-detail")
(declare-function beads-hierarchy-show "beads-hierarchy")
(autoload 'beads-about "beads" "Display version and source information for Beads Turbo." t)

(defvar beads-dolt-sql-enabled)
(declare-function beads-backend-dolt-sql-activate "beads-backend-dolt-sql")
(declare-function beads-backend-dolt-sql-deactivate "beads-backend-dolt-sql")

(defgroup beads-transient nil
  "Transient menus for Beads issue tracker."
  :group 'beads)

(defun beads-transient--list-view-p ()
  "Return non-nil when the current buffer is a Beads list view."
  (derived-mode-p 'beads-org-list-mode))

(defun beads-transient--truncate-middle (str max-len)
  "Truncate STR to MAX-LEN using middle ellipsis.
Shows beginning and end of string with … in the middle."
  (if (<= (length str) max-len)
      str
    (let* ((ellipsis "…")
           (available (- max-len (length ellipsis)))
           (head-len (/ (1+ available) 2))
           (tail-len (/ available 2)))
      (concat (substring str 0 head-len)
              ellipsis
              (substring str (- (length str) tail-len))))))

(defun beads-create-issue--optional-string (prompt)
  "Read PROMPT and return nil when the input is empty."
  (let ((value (read-string prompt)))
    (unless (string-empty-p value)
      value)))

(defun beads-create-issue--read-params ()
  "Read issue creation parameters and return them as a plist.
Returns nil when the required title is empty."
  (let ((title (read-string "Title: ")))
    (unless (string-empty-p title)
      (let* ((type (completing-read "Type: "
                                    (beads-get-types)
                                    nil t "task"))
             (priority-str (completing-read "Priority: "
                                             '("P0" "P1" "P2" "P3" "P4")
                                             nil t "P2"))
             (priority (string-to-number (substring priority-str 1)))
             (description (beads-create-issue--optional-string
                           "Description (optional): "))
             (assignee (beads-create-issue--optional-string
                        "Assignee (optional): "))
             (labels (beads-create-issue--optional-string
                      "Labels, comma-separated (optional): "))
             (parent (beads-create-issue--optional-string
                      "Parent issue ID (optional): "))
             (deps (beads-create-issue--optional-string
                    "Dependencies, comma-separated (optional): "))
             (params (list :title title
                           :type type
                           :priority priority)))
        (when description
          (setq params (plist-put params :description description)))
        (when assignee
          (setq params (plist-put params :assignee assignee)))
        (when labels
          (setq params (plist-put params :labels labels)))
        (when parent
          (setq params (plist-put params :parent parent)))
        (when deps
          (setq params (plist-put params :deps deps)))
        params))))

(defun beads-create-issue ()
  "Create a new issue interactively.
Prompts for title (required), type, priority, and common `bd create' options."
  (interactive)
  (let ((params (beads-create-issue--read-params)))
    (if (not params)
        (message "Title is required")
      (condition-case err
          (let ((issue (apply #'beads-client-create
                              (plist-get params :title)
                              (beads-transient--plist-remove params :title))))
            (message "Created issue %s" (alist-get 'id issue))
            (when (beads-transient--list-view-p)
              (beads-list-refresh)))
        (beads-client-error
         (message "Failed to create issue: %s" (error-message-string err)))))))

(defvar-local beads-create-preview--params nil
  "Parameters for issue creation in preview buffer.")

(defvar beads-create-preview-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'beads-create-preview-confirm)
    (define-key map (kbd "C-c C-k") #'beads-create-preview-cancel)
    (define-key map (kbd "q") #'beads-create-preview-cancel)
    map)
  "Keymap for beads-create-preview-mode.")

(define-derived-mode beads-create-preview-mode special-mode "Beads-Preview"
  "Mode for previewing issue creation.

\\{beads-create-preview-mode-map}")

(defun beads-create-issue-preview ()
  "Preview a new issue before creating it.
Shows what the issue will look like, then press C-c C-c to create."
  (interactive)
  (let ((params (beads-create-issue--read-params)))
    (if (not params)
        (message "Title is required")
      (condition-case err
          (let ((preview (apply #'beads-client-create
                                (plist-get params :title)
                                (append (beads-transient--plist-remove params :title)
                                        (list :dry-run t)))))
            (beads-create-preview--show preview params))
        (beads-client-error
         (message "Failed to preview issue: %s" (error-message-string err)))))))

(defun beads-create-preview--show (preview params)
  "Show PREVIEW issue in buffer with PARAMS for creation."
  (let ((buffer (get-buffer-create "*Beads Create Preview*")))
    (with-current-buffer buffer
      (beads-create-preview-mode)
      (setq beads-create-preview--params params)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (propertize "Issue Preview\n" 'face 'bold))
        (insert (make-string 40 ?─) "\n\n")
        (insert (propertize "Title: " 'face 'bold)
                (alist-get 'title preview "") "\n")
        (insert (propertize "Type:  " 'face 'bold)
                (alist-get 'issue_type preview "") "\n")
        (insert (propertize "Priority: " 'face 'bold)
                (format "P%d" (alist-get 'priority preview 2)) "\n")
        (when-let ((parent (or (alist-get 'parent preview)
                               (alist-get 'parent_id preview)
                               (plist-get params :parent))))
          (insert (propertize "Parent: " 'face 'bold)
                  parent "\n"))
        (insert (propertize "Status: " 'face 'bold)
                (alist-get 'status preview "open") "\n")
        (insert "\n" (make-string 40 ?─) "\n")
        (insert (propertize "C-c C-c" 'face 'help-key-binding)
                " to create, "
                (propertize "C-c C-k" 'face 'help-key-binding)
                " or "
                (propertize "q" 'face 'help-key-binding)
                " to cancel\n")
        (goto-char (point-min))))
    (pop-to-buffer buffer)))

(defun beads-create-preview-confirm ()
  "Create the previewed issue."
  (interactive)
  (let ((params beads-create-preview--params))
    (unless params
      (user-error "No issue to create"))
    (condition-case err
        (let ((issue (apply #'beads-client-create
                            (plist-get params :title)
                            (beads-transient--plist-remove params :title))))
          (quit-window t)
          (message "Created issue %s" (alist-get 'id issue))
          (when (beads-transient--list-view-p)
            (beads-list-refresh)))
      (beads-client-error
       (message "Failed to create issue: %s" (error-message-string err))))))

(defun beads-create-preview-cancel ()
  "Cancel issue creation preview."
  (interactive)
  (quit-window t)
  (message "Cancelled"))

(defun beads-transient--plist-remove (plist key)
  "Return PLIST with KEY removed."
  (let ((result nil))
    (while plist
      (unless (eq (car plist) key)
        (setq result (cons (cadr plist) (cons (car plist) result))))
      (setq plist (cddr plist)))
    (nreverse result)))

(defun beads-close-issue ()
  "Close the issue at point or in current detail buffer.
Prompts for an optional close reason."
  (interactive)
  (let ((id (cond
             ((derived-mode-p 'beads-detail-mode)
              (bound-and-true-p beads-detail--current-issue-id))
             ((beads-transient--list-view-p)
              (alist-get 'id (beads-list--get-issue-at-point)))
             (t nil))))
    (if (not id)
        (message "No issue at point")
      (let ((reason (read-string (format "Close %s reason (optional): " id))))
        (condition-case err
            (progn
              (beads-client-close id (unless (string-empty-p reason) reason))
              (message "Closed issue %s" id)
              (cond
               ((beads-transient--list-view-p)
                (beads-list-refresh))
               ((derived-mode-p 'beads-detail-mode)
                (beads-detail-refresh))))
          (beads-client-error
           (let ((err-msg (error-message-string err)))
             (if (string-match-p "\\(blocker\\|blocked\\|open depend\\)" err-msg)
                 (message "Cannot close %s: has open blockers. Press H to view dependency tree." id)
               (message "Failed to close %s: %s" id err-msg)))))))))

(defun beads-delete-issue ()
  "Permanently delete the issue at point.
Prompts for confirmation with `yes-or-no-p'."
  (interactive)
  (let* ((list-issue (and (beads-transient--list-view-p)
                          (beads-list--get-issue-at-point)))
         (id (cond
              ((derived-mode-p 'beads-detail-mode)
               (bound-and-true-p beads-detail--current-issue-id))
              (list-issue
               (alist-get 'id list-issue))
              (t nil)))
         (title (cond
                 ((derived-mode-p 'beads-detail-mode)
                  (alist-get 'title (bound-and-true-p beads-detail--current-issue)))
                 (list-issue
                  (alist-get 'title list-issue))
                 (t nil)))
         (display-title (if title
                            (beads-transient--truncate-middle title 30)
                          ""))
         (prompt (if (string-empty-p display-title)
                     (format "Permanently delete issue %s? " id)
                   (format "Permanently delete '%s' (%s)? " display-title id))))
    (if (not id)
        (message "No issue at point")
      (when (yes-or-no-p prompt)
        (condition-case err
            (progn
              (beads-client-delete (list id))
              (message "Deleted issue %s" id)
              (cond
               ((beads-transient--list-view-p)
                (beads-list-refresh))
               ((derived-mode-p 'beads-detail-mode)
                (quit-window t))))
          (beads-client-error
           (message "Failed to delete issue: %s" (error-message-string err))))))))

(defun beads-reopen-issue ()
  "Reopen the closed issue at point.
Sets status to open and clears closed_at timestamp."
  (interactive)
  (let ((id (cond
             ((derived-mode-p 'beads-detail-mode)
              (bound-and-true-p beads-detail--current-issue-id))
             ((beads-transient--list-view-p)
              (alist-get 'id (beads-list--get-issue-at-point)))
             (t nil))))
    (if (not id)
        (message "No issue at point")
      (condition-case err
          (progn
            (beads-client-update id :status "open")
            (message "Reopened issue %s" id)
            (cond
             ((beads-transient--list-view-p)
              (beads-list-refresh))
             ((derived-mode-p 'beads-detail-mode)
              (beads-detail-refresh))))
        (beads-client-error
         (message "Failed to reopen issue: %s" (error-message-string err)))))))

(defun beads-stats ()
  "Display project statistics in a popup buffer.
Press `q' to close the stats window."
  (interactive)
  (condition-case err
      (let ((stats (beads-client-stats)))
        (with-current-buffer (get-buffer-create "*Beads Stats*")
          (let ((inhibit-read-only t))
            (erase-buffer)
            (insert (propertize "Beads Project Statistics\n" 'face 'bold))
            (insert (make-string 25 ?=) "\n\n")
            (insert (format "%-20s %d\n" "Total Issues:" (alist-get 'total_issues stats 0)))
            (insert (format "%-20s %d\n" "Open:" (alist-get 'open_issues stats 0)))
            (insert (format "%-20s %d\n" "In Progress:" (alist-get 'in_progress_issues stats 0)))
            (insert (format "%-20s %d\n" "Closed:" (alist-get 'closed_issues stats 0)))
            (insert (format "%-20s %d\n" "Blocked:" (alist-get 'blocked_issues stats 0)))
            (insert (format "%-20s %d\n" "Ready:" (alist-get 'ready_issues stats 0)))
            (let ((lead-time (alist-get 'average_lead_time_hours stats)))
              (when (and lead-time (> lead-time 0))
                (insert (format "\n%-20s %.1f hours\n" "Avg Lead Time:" lead-time)))))
          (special-mode)
          (goto-char (point-min))
          (pop-to-buffer (current-buffer)
                         '((display-buffer-in-side-window)
                           (side . bottom)
                           (window-height . fit-window-to-buffer)))))
    (beads-client-error
     (message "Failed to fetch stats: %s" (error-message-string err)))))

(autoload 'beads-orphans "beads-orphans" nil t)
(autoload 'beads-stale "beads-stale" nil t)
(autoload 'beads-epics "beads-epics" nil t)
(autoload 'beads-duplicates "beads-duplicates" nil t)
(autoload 'beads-conflicts "beads-conflicts" nil t)
(autoload 'beads-lint "beads-lint" nil t)

(defun beads-filter-status ()
  "Filter issues by status.
Select a status to filter, or \"all\" to clear the filter."
  (interactive)
  (unless (beads-transient--list-view-p)
    (user-error "Not in beads list mode"))
  (let* ((choices '("all" "open" "in_progress" "blocked" "hooked" "closed"))
         (current (when beads-list--filter
                    (plist-get (plist-get beads-list--filter :config) :value)))
         (status (completing-read "Filter by status: " choices nil t
                                  (or current ""))))
    (setq beads-list--filter
          (unless (string= status "all")
            (beads-filter-by-status status)))
    (beads-list--refresh-current-view)))

(defun beads-filter-priority ()
  "Filter issues by priority.
Select a priority to filter, or \"all\" to clear the filter."
  (interactive)
  (unless (beads-transient--list-view-p)
    (user-error "Not in beads list mode"))
  (let* ((choices '("all" "P0" "P1" "P2" "P3" "P4"))
         (current (when beads-list--filter
                    (let ((val (plist-get (plist-get beads-list--filter :config) :value)))
                      (when (numberp val) (format "P%d" val)))))
         (priority-str (completing-read "Filter by priority: " choices nil t
                                        (or current ""))))
    (setq beads-list--filter
          (unless (string= priority-str "all")
            (beads-filter-by-priority
             (string-to-number (substring priority-str 1)))))
    (beads-list--refresh-current-view)))

(defun beads-filter-type ()
  "Filter issues by type.
Includes built-in types and any custom types found in current issues."
  (interactive)
  (unless (beads-transient--list-view-p)
    (user-error "Not in beads list mode"))
  (let* ((types (beads-list-available-types))
         (choices (cons "all" types))
         (type (completing-read "Filter by type: " choices nil t)))
    (setq beads-list--filter
          (unless (string= type "all")
            (beads-filter-by-type type)))
    (beads-list--refresh-current-view)))

(defun beads-filter-assignee ()
  "Filter issues by assignee."
  (interactive)
  (unless (beads-transient--list-view-p)
    (user-error "Not in beads list mode"))
  (let* ((issues (beads-client-list))
         (assignees (seq-uniq
                     (seq-filter #'identity
                                 (mapcar (lambda (i) (alist-get 'assignee i)) issues))))
         (choices (cons "all" (cons "unassigned" (sort assignees #'string<))))
         (assignee (completing-read "Filter by assignee: " choices nil t)))
    (setq beads-list--filter
          (cond
           ((string= assignee "all") nil)
           ((string= assignee "unassigned") (beads-filter-unassigned))
           (t (beads-filter-by-assignee assignee))))
    (beads-list--refresh-current-view)))

(defun beads-filter-label ()
  "Filter issues by label."
  (interactive)
  (unless (beads-transient--list-view-p)
    (user-error "Not in beads list mode"))
  (let* ((issues (beads-client-list))
         (labels (seq-uniq
                  (apply #'append
                         (mapcar (lambda (i) (alist-get 'labels i)) issues))))
         (choices (cons "all" (sort labels #'string<)))
         (label (completing-read "Filter by label: " choices nil t)))
    (setq beads-list--filter
          (unless (string= label "all")
            (beads-filter-by-label label)))
    (beads-list--refresh-current-view)))

(defun beads-filter-parent ()
  "Filter issues by parent (for epic-scoped views)."
  (interactive)
  (unless (beads-transient--list-view-p)
    (user-error "Not in beads list mode"))
  (let* ((issues (beads-client-list '(:issue-type "epic")))
         (epics (mapcar (lambda (i)
                          (cons (format "%s: %s"
                                        (alist-get 'id i)
                                        (alist-get 'title i))
                                (alist-get 'id i)))
                        issues))
         (choices (cons '("all" . nil) epics))
         (selection (completing-read "Filter by parent epic: "
                                     (mapcar #'car choices) nil t))
         (parent-id (cdr (assoc selection choices))))
    (setq beads-list--filter
          (when parent-id
            (beads-filter-by-parent parent-id)))
    (beads-list--refresh-current-view)
    (if parent-id
        (message "Showing children of %s" parent-id)
      (message "Showing all issues"))))

(defun beads-filter-ready-issues ()
  "Filter to show only ready issues (no blockers)."
  (interactive)
  (unless (beads-transient--list-view-p)
    (user-error "Not in beads list mode"))
  (setq beads-list--filter (beads-filter-ready))
  (beads-list--refresh-current-view)
  (message "Showing ready issues only"))

(defun beads-filter-blocked-issues ()
  "Filter to show only blocked issues."
  (interactive)
  (unless (beads-transient--list-view-p)
    (user-error "Not in beads list mode"))
  (setq beads-list--filter (beads-filter-blocked))
  (beads-list--refresh-current-view)
  (message "Showing blocked issues only"))

(defun beads-filter-clear ()
  "Clear all filters."
  (interactive)
  (unless (beads-transient--list-view-p)
    (user-error "Not in beads list mode"))
  (setq beads-list--filter nil)
  (beads-list--refresh-current-view)
  (message "Filters cleared"))

(defun beads-search ()
  "Search issues by title or description.
Prompts for a search query and filters the list to matching issues."
  (interactive)
  (unless (beads-transient--list-view-p)
    (user-error "Not in beads list mode"))
  (let ((query (read-string "Search issues: ")))
    (if (string-empty-p query)
        (progn
          (setq beads-list--filter nil)
          (beads-list--refresh-current-view)
          (message "Search cleared"))
      (setq beads-list--filter (beads-filter-by-search query))
      (beads-list--refresh-current-view))))

(defun beads-transient--dolt-sql-enabled-p ()
  "Return non-nil if Dolt SQL transport is currently enabled."
  (and (boundp 'beads-dolt-sql-enabled) beads-dolt-sql-enabled))

(transient-define-suffix beads-transient-toggle-dolt-sql ()
  "Toggle the Dolt SQL read-path transport.
When enabled, read operations (list/show/ready/stats/count/stale)
prefer a persistent mysql client session against the local Dolt
SQL server for speed; writes always fall back to the bd CLI.
See `beads-backend-dolt-sql-activate' and
`beads-backend-dolt-sql-deactivate'."
  :description (lambda ()
                 (format "%s Dolt SQL read path"
                         (if (beads-transient--dolt-sql-enabled-p)
                             "[x]" "[ ]")))
  (interactive)
  (require 'beads-backend-dolt-sql)
  (if (beads-transient--dolt-sql-enabled-p)
      (beads-backend-dolt-sql-deactivate)
    (beads-backend-dolt-sql-activate)))

(transient-define-prefix beads-config-menu ()
  "Configure beads list view."
  :transient-suffix 'transient--do-call
  ["Configuration"
   ("d" beads-transient-toggle-dolt-sql)]
  ["Navigation"
   ("q" "Back" transient-quit-one)])

(defun beads-transient--mark-menu-description ()
  "Return description for mark menu entry showing count."
  (let ((count (length beads-list--marked)))
    (if (> count 0)
        (format "Mark & Bulk (%d)..." count)
      "Mark & Bulk...")))

(transient-define-prefix beads-mark-menu ()
  "Mark issues and perform bulk operations."
  :transient-suffix 'transient--do-call
  [["Mark"
    ("m" "Mark" beads-list-mark :transient t)
    ("u" "Unmark" beads-list-unmark :transient t)
    ("U" "Unmark all" beads-list-unmark-all :transient t)
    ("t" "Toggle all" beads-list-toggle-marks :transient t)
    ("%" "Regexp (title)" beads-list-mark-regexp :transient t)
    ("*" "Show only marked" beads-list-toggle-marked-filter :transient t)]
   ["Bulk"
    ("s" "Set status" beads-list-bulk-status)
    ("p" "Set priority" beads-list-bulk-priority)
    ("a" "Assign..." beads-list-quick-assign)
    ("A" "Assign to me" beads-list-assign-to-me)
    ("x" "Close" beads-list-bulk-close)
    ("D" "Delete!" beads-list-bulk-delete)]]
  ["Navigation"
   ("q" "Back" transient-quit-one)]
  [""
   :hide always
   ("n" "Next" next-line :transient t)
   ("p" "Prev" previous-line :transient t)
   ("j" "Next" next-line :transient t)
   ("k" "Prev" previous-line :transient t)
   ("<down>" "Next" next-line :transient t)
   ("<up>" "Prev" previous-line :transient t)
   ("C-n" "Next" next-line :transient t)
   ("C-p" "Prev" previous-line :transient t)])

(defvar-local beads-list--sort-mode-override nil)
(defvar beads-list--sort-key)

(defun beads-sort-by-column (column &optional descending)
  "Sort list by COLUMN.  When DESCENDING is non-nil, reverse order."
  (setq beads-list--sort-mode-override 'column)
  (setq beads-list--sort-key
        (cons (beads-list--sort-column-name column) descending))
  (beads-list--refresh-current-view t)
  (message "Sorted by %s%s" column (if descending " (descending)" "")))

(defun beads-sort-by-id ()
  "Sort issues by ID."
  (interactive)
  (beads-sort-by-column "ID"))

(defun beads-sort-by-date ()
  "Sort issues by date (newest first)."
  (interactive)
  (beads-sort-by-column "Date" t))

(defun beads-sort-by-status ()
  "Sort issues by status."
  (interactive)
  (beads-sort-by-column "Status"))

(defun beads-sort-by-priority ()
  "Sort issues by priority (highest first)."
  (interactive)
  (beads-sort-by-column "Priority"))

(defun beads-sort-by-type ()
  "Sort issues by type."
  (interactive)
  (beads-sort-by-column "Type"))

(defun beads-sort-by-title ()
  "Sort issues by title."
  (interactive)
  (beads-sort-by-column "Title"))

(defun beads-sort-sectioned ()
  "Use sectioned sort (unblocked/blocked/closed groups)."
  (interactive)
  (setq beads-list--sort-mode-override 'sectioned)
  (beads-list--refresh-current-view t)
  (message "Sort mode: sectioned"))

(defun beads-transient--sort-menu-description ()
  "Return description for sort menu showing current sort."
  (if (eq beads-list--sort-mode-override 'sectioned)
      "Sort: sectioned"
    (let ((key (car beads-list--sort-key))
          (desc (cdr beads-list--sort-key)))
      (format "Sort: %s%s" (or key "default") (if desc " ↓" " ↑")))))

(transient-define-prefix beads-sort-menu ()
  "Beads sort menu."
  [["Sort by Column"
    ("i" "ID" beads-sort-by-id)
    ("d" "Date" beads-sort-by-date)
    ("s" "Status" beads-sort-by-status)
    ("p" "Priority" beads-sort-by-priority)
    ("t" "Type" beads-sort-by-type)
    ("T" "Title" beads-sort-by-title)]
   ["Sort Mode"
    ("S" "Sectioned (default)" beads-sort-sectioned)
    ("r" "Reverse direction" beads-list-reverse-sort)
    ""
    ("q" "Back" transient-quit-one)]])

(transient-define-prefix beads-filter-menu ()
  "Beads filter menu."
  [["Filter by"
    ("s" "Status" beads-filter-status)
    ("p" "Priority" beads-filter-priority)
    ("t" "Type" beads-filter-type)
    ("a" "Assignee" beads-filter-assignee)
    ("l" "Label" beads-filter-label)
    ("e" "Parent epic" beads-filter-parent)]
   ["Quick Filters"
    ("r" "Ready (no blockers)" beads-filter-ready-issues)
    ("b" "Blocked" beads-filter-blocked-issues)
    ""
    ("c" "Clear all filters" beads-filter-clear)
    ""
    ("q" "Back" transient-quit-one)]])

(autoload 'beads-types-edit "beads-types" nil t)

(transient-define-prefix beads-views-menu ()
  "Beads views menu for reports and diagnostics."
  [["Views"
    ("o" "Orphaned issues" beads-orphans)
    ("s" "Stale issues" beads-stale)
    ("e" "Epic status" beads-epics)
    ("d" "Duplicates" beads-duplicates)
    ("l" "Lint report" beads-lint)
    ("x" "Resolve conflicts" beads-conflicts)]
   [""
    ("q" "Back" transient-quit-one)]])

(transient-define-prefix beads-list-menu ()
  "Beads list mode menu."
  [["Navigation"
    ("g" "Refresh" beads-list-refresh)
    ("RET" "View issue" beads-list-goto-issue)
    ("P" "Toggle preview" beads-preview-mode)
    ("H" "Dependency tree" beads-hierarchy-show)
    ("S" "Project stats" beads-stats)
    ("T" "Configure types" beads-types-edit)]
   ["Actions"
    ("c" "Create issue" beads-create-issue)
    ("C" "Create with preview" beads-create-issue-preview)
    ("E" "Edit issue" beads-list-edit-form)
    ("x" "Close marked/at point" beads-list-bulk-close)
    ("R" "Reopen issue" beads-reopen-issue)
    ("D" "Delete issue" beads-delete-issue)]
   ["Search & Filter"
    ("/" "Search..." beads-search)
    ("f" "Filter menu..." beads-filter-menu)
    ("s" "Toggle sort mode" beads-list-toggle-sort-mode)
    ("o" "Cycle sort column" beads-list-cycle-sort)
    ("O" "Reverse sort" beads-list-reverse-sort)]]
  [["Mark"
    ("m" "Mark" beads-list-mark)
    ("u" "Unmark" beads-list-unmark)
    ("U" "Unmark all" beads-list-unmark-all)
    ("t" "Toggle marks" beads-list-toggle-marks)
    ("a" "Assign..." beads-list-quick-assign)
    ("A" "Assign to me" beads-list-assign-to-me)]
   ["More"
    ("B" "Bulk menu..." beads-mark-menu)
    ("V" "Views..." beads-views-menu)
    ("," "Config..." beads-config-menu)
    ("i" "About Beads Turbo" beads-about)
    ""
    ("?" "Describe mode" describe-mode)
    ("q" "Quit" transient-quit-one)]])

(transient-define-prefix beads-detail-menu ()
  "Beads detail mode menu."
  [["Navigation"
    ("l" "List issues" beads-list)
    ("g" "Refresh" beads-detail-refresh)
    ("P" "Go to parent" beads-detail-goto-parent)
    ("C" "View children" beads-detail-view-children)
    ("H" "Dependency tree" beads-hierarchy-show)
    ("S" "Project stats" beads-stats)]
   ["Edit"
    ("E" "Edit form" beads-detail-edit-form)
    ("e d" "Description" beads-detail-edit-description)
    ("e D" "Design notes" beads-detail-edit-design)
    ("e a" "Acceptance criteria" beads-detail-edit-acceptance)
    ("e n" "Notes" beads-detail-edit-notes)
    ("e s" "Status" beads-detail-edit-status)
    ("e p" "Priority" beads-detail-edit-priority)
    ("e t" "Title" beads-detail-edit-title)
    ("e T" "Type" beads-detail-edit-type)
    ("e A" "Assignee" beads-detail-edit-assignee)
    ("e x" "External ref" beads-detail-edit-external-ref)
    ("e l a" "Add label" beads-detail-edit-label-add)
    ("e l r" "Remove label" beads-detail-edit-label-remove)]
   ["Actions"
    ("c" "Add comment" beads-detail-add-comment)
    ("x" "Close issue" beads-close-issue)
    ("R" "Reopen issue" beads-reopen-issue)
    ("D" "Delete issue" beads-delete-issue)
    ("," "Config..." beads-config-menu)
    ("i" "About Beads Turbo" beads-about)
    ""
    ("?" "Describe mode" describe-mode)
    ("q" "Quit" transient-quit-one)]])

(defun beads-menu ()
  "Show context-appropriate Beads menu."
  (interactive)
  (cond
   ((derived-mode-p 'beads-detail-mode)
    (beads-detail-menu))
   ((beads-transient--list-view-p)
    (beads-list-menu))
   (t
    (beads-list-menu))))

(provide 'beads-transient)
;;; beads-transient.el ends here
