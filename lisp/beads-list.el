;;; beads-list.el --- Issue list mode for Beads -*- lexical-binding: t -*-

;; Copyright (C) 2025 Christian Tietze

;; Author: Christian Tietze
;; Keywords: tools

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

;; Org task/tree issue list mode with sorting, filtering, and bulk operations.
;; The legacy tabulated-list view remains available via `beads-list-legacy'.

;;; Code:

(require 'beads-client)
(require 'beads-cache)
(require 'beads-detail)
(require 'beads-list-model)

(declare-function beads-client-types "beads-client")
(require 'beads-filter)
(require 'beads-preview)
(require 'beads-faces)
(require 'tabulated-list)
(require 'org)
(require 'seq)
(require 'cl-lib)
(require 'beads-core)

(declare-function beads-menu "beads-transient")
(declare-function beads-form-open "beads-form")
(declare-function beads-edit-field-minibuffer "beads-edit")
(declare-function beads-edit-field-completing "beads-edit")
(declare-function beads-edit-field-markdown "beads-edit")
(declare-function beads-project-buffer-name "beads-project")
(declare-function beads-project-root "beads-project")
(declare-function evil-set-initial-state "evil-core")
(declare-function evil-make-overriding-map "evil-core")

(defgroup beads-list nil
  "Issue list display for Beads."
  :group 'beads)

(defcustom beads-list-show-header-stats t
  "Whether to show statistics in the mode line.
When non-nil, displays issue counts (total, open, blocked, ready)
in the mode line of the list view."
  :type 'boolean
  :group 'beads-list)

(defcustom beads-list-columns
  '(id date status priority type title)
  "Columns to display in the legacy tabulated beads list view.
Available: id, date, status, priority, type, title, assignee, labels, deps.
This only affects `beads-list-legacy'; the default `beads-list' org view
renders issue metadata in org property drawers instead of columns."
  :type '(repeat (choice (const :tag "ID" id)
                         (const :tag "Date" date)
                         (const :tag "Status" status)
                         (const :tag "Priority" priority)
                         (const :tag "Type" type)
                         (const :tag "Title" title)
                         (const :tag "Assignee" assignee)
                         (const :tag "Labels" labels)
                         (const :tag "Dependencies" deps)))
  :group 'beads-list)

(define-obsolete-variable-alias 'beads-list-type-style 'beads-type-style "0.47")
(define-obsolete-variable-alias 'beads-list-type-glyph 'beads-type-glyph "0.47")

(defcustom beads-list-sort-mode 'sectioned
  "How to sort issues in the list view.
When `sectioned', group issues into status sections.  The org view
renders Ready, In Progress, Blocked, and Completed headings.  The legacy
table keeps the existing unblocked/blocked/completed sections.
When `column', use standard tabulated-list column sorting."
  :type '(choice (const :tag "Sectioned (unblocked/blocked/closed)" sectioned)
                 (const :tag "Column-based" column))
  :group 'beads-list)

(defcustom beads-list-section-separators t
  "Whether to show visual separators between legacy table sections.
Only applies to `beads-list-legacy' when `beads-list-sort-mode' is
`sectioned'.  The default org list renders sections as org headings."
  :type 'boolean
  :group 'beads-list)

(defcustom beads-list-id-column-max-width nil
  "Maximum width for the ID column in the legacy tabulated beads list view.
When nil, the column width is unlimited and adjusts to the longest ID.
When an integer, the column width will not exceed this value.
This only affects `beads-list-legacy'."
  :type '(choice (const :tag "Unlimited" nil)
                 (integer :tag "Maximum width"))
  :group 'beads-list)

(define-obsolete-face-alias 'beads-list-status-open 'beads-status-open "0.47")
(define-obsolete-face-alias 'beads-list-status-in-progress 'beads-status-in-progress "0.47")
(define-obsolete-face-alias 'beads-list-status-closed 'beads-status-closed "0.47")
(define-obsolete-face-alias 'beads-list-status-blocked 'beads-status-blocked "0.47")
(define-obsolete-face-alias 'beads-list-status-hooked 'beads-status-hooked "0.47")
(define-obsolete-face-alias 'beads-list-priority-p0 'beads-priority-p0 "0.47")
(define-obsolete-face-alias 'beads-list-priority-p1 'beads-priority-p1 "0.47")

(defface beads-list-header-line
  '((t :inherit header-line))
  "Face for stats header line.")

(defface beads-list-header-count
  '((t :inherit bold))
  "Face for counts in header line.")

(defface beads-list-deps-blocked
  '((t :foreground "red"))
  "Face for blocked dependency indicator.")

(defface beads-list-deps-parent
  '((t :foreground "yellow"))
  "Face for has-parent dependency indicator.")

(defface beads-list-deps-child
  '((t :foreground "green"))
  "Face for has-children dependency indicator.")

(define-obsolete-face-alias 'beads-list-type-gate 'beads-type-gate "0.47")
(define-obsolete-face-alias 'beads-list-type-convoy 'beads-type-convoy "0.47")
(define-obsolete-face-alias 'beads-list-type-agent 'beads-type-agent "0.47")
(define-obsolete-face-alias 'beads-list-type-role 'beads-type-role "0.47")
(define-obsolete-face-alias 'beads-list-type-rig 'beads-type-rig "0.47")

(defface beads-list-row-p0
  '((((class color) (background light))
     :background "#ffe0e0" :extend t)
    (((class color) (background dark))
     :background "#4a1a1a" :extend t))
  "Face for entire row of P0 priority issues.
Uses `:extend t' to highlight to end of line."
  :group 'beads-list)

(defcustom beads-list-highlight-p0-rows t
  "Whether to highlight entire rows for P0 priority issues.
When non-nil, P0 issues get a distinctive background color
across the entire row for maximum visibility."
  :type 'boolean
  :group 'beads-list)

(defvar beads-list--column-defs
  '((id       . ("ID"       10 t              beads-list--format-id))
    (date     . ("Date"     10 beads-list--sort-by-date beads-list--format-date))
    (status   . ("Status"   12 t              beads--format-status))
    (priority . ("Pri"       4 t              beads--format-priority))
    (type     . ("Type"      8 t              beads--format-type))
    (title    . ("Title"    50 t              beads-list--format-title))
    (assignee . ("Assignee" 12 t              beads-list--format-assignee))
    (labels   . ("Labels"   15 t              beads-list--format-labels))
    (deps     . ("Dep"       3 t              beads-list--format-deps)))
  "Column definitions for beads list view.
Each entry is (SYMBOL . (HEADER WIDTH SORTABLE FORMATTER)).")

(defconst beads-list--org-status-todo-map
  '(("open" . "TODO")
    ("in_progress" . "WIP")
    ("blocked" . "WAIT")
    ("hooked" . "WAIT")
    ("deferred" . "WAIT")
    ("closed" . "DONE"))
  "Mapping from beads issue status strings to org TODO keywords.
Unknown or missing statuses use TODO in headings and keep their raw
status only in the `BEADS_STATUS' property.")

(defconst beads-list--org-todo-status-map
  '(("TODO" . "open")
    ("WIP" . "in_progress")
    ("WAIT" . "blocked")
    ("DONE" . "closed"))
  "Mapping from org TODO keywords to beads issue status strings.")

(defconst beads-list--org-todo-cycle '("TODO" "WIP" "WAIT" "DONE")
  "TODO keywords cycled by `beads-org-list-todo'.")

(defconst beads-list--org-property-fields
  '((BEADS_ID . id)
    (BEADS_STATUS . status)
    (BEADS_TYPE . issue_type)
    (BEADS_PRIORITY . priority)
    (BEADS_ASSIGNEE . assignee)
    (BEADS_LABELS . labels)
    (BEADS_PARENT . parent)
    (BEADS_PARENT . parent_id)
    (BEADS_DEPENDENCY_COUNT . dependency_count)
    (BEADS_DEPENDENT_COUNT . dependent_count)
    (BEADS_CREATED_AT . created_at)
    (BEADS_UPDATED_AT . updated_at)
    (BEADS_CLOSED_AT . closed_at)
    (BEADS_EXTERNAL_REF . external_ref)
    (BEADS_SPEC_ID . spec_id)
    (BEADS_SOURCE_REPO . source_repo))
  "Org property drawer contract for a beads issue.

Each issue renders as one org task heading:

  * TODO [#B] Issue title :task:

The heading intentionally stays compact: it contains only the org
TODO keyword, optional org priority cookie, title, and optional issue
type as an org tag.  Stable lookup and wide metadata live in the
property drawer.  `BEADS_ID' is the canonical property for looking up
the issue at point.  Missing or empty values are omitted, including
unknown fields, so headings and drawers do not grow noisy.  If both
`parent' and `parent_id' are present, `parent' wins.")

(defvar-local beads-list--marked nil
  "List of marked issue IDs in current buffer.")

(defvar-local beads-list--show-only-marked nil
  "When non-nil, only show marked issues in the list.")

(defun beads-list--build-format (&optional id-width)
  "Build `tabulated-list-format' from `beads-list-columns'.
Automatically prepends the mark column.
When ID-WIDTH is provided, use it instead of the default for the id column."
  (vconcat
   (cons (list " " 1 nil)
         (mapcar (lambda (col)
                   (let ((def (alist-get col beads-list--column-defs)))
                     (if def
                         (list (nth 0 def)
                               (if (and id-width (eq col 'id))
                                   id-width
                                 (nth 1 def))
                               (nth 2 def))
                       (error "Unknown column: %s" col))))
                 beads-list-columns))))

(defun beads-list--max-id-width (issues)
  "Return the ID column width for ISSUES.
Computes the maximum ID length with a minimum of 5.
Respects `beads-list-id-column-max-width' when set."
  (let ((max-len (seq-reduce (lambda (acc issue)
                               (max acc (length (alist-get 'id issue))))
                             issues 0)))
    (setq max-len (max 5 max-len))
    (if beads-list-id-column-max-width
        (min max-len beads-list-id-column-max-width)
      max-len)))

(defun beads-list--build-entry (issue)
  "Build entry vector for ISSUE based on `beads-list-columns'.
Automatically prepends the mark indicator."
  (let ((id (alist-get 'id issue)))
    (vconcat
     (cons (if (member id beads-list--marked) "*" " ")
           (mapcar (lambda (col)
                     (let ((def (alist-get col beads-list--column-defs)))
                       (if def
                           (funcall (nth 3 def) issue)
                         "")))
                   beads-list-columns)))))

(defun beads-list--column-names ()
  "Get list of column header names for current configuration."
  (mapcar (lambda (col)
            (let ((def (alist-get col beads-list--column-defs)))
              (if def (nth 0 def) "")))
          beads-list-columns))

(defvar beads-list--issues nil
  "Cached list of issues for current buffer.")

(defvar-local beads-list--filter nil
  "Current filter applied to issue list.
Created via `beads-filter-make' functions.")

(defvar-local beads-list--sort-mode-override nil
  "Buffer-local override for `beads-list-sort-mode'.
When non-nil, overrides the global setting for this buffer.")

(defvar-local beads-list--section-overlays nil
  "List of overlays used for section separators.")

(defvar-local beads-list--org-mark-overlays nil
  "Overlays used to visually mark issue headings in org list buffers.")

(defun beads-list--effective-sort-mode ()
  "Return the effective sort mode for this buffer."
  (or beads-list--sort-mode-override beads-list-sort-mode))

(defun beads-list--sort-column-name (column)
  "Return the canonical list column name for COLUMN.
Legacy sort commands historically used some long names, such as
\"Priority\", while the table header currently displays the shorter
\"Pri\"."
  (pcase column
    ((or "Priority" "Pri") "Pri")
    (_ column)))

(defun beads-list--sort-column-value (issue column)
  "Return ISSUE's comparable value for list sort COLUMN."
  (pcase (beads-list--sort-column-name column)
    ("ID" (or (alist-get 'id issue) ""))
    ("Date" (or (alist-get 'created_at issue) ""))
    ("Status" (or (alist-get 'status issue) ""))
    ("Pri" (or (alist-get 'priority issue) 99))
    ("Type" (or (alist-get 'issue_type issue) ""))
    ("Title" (or (alist-get 'title issue) ""))
    (_ "")))

(defun beads-list--compare-sort-values (a b)
  "Return non-nil when sort value A should appear before B."
  (cond
   ((and (numberp a) (numberp b)) (< a b))
   ((numberp a) t)
   ((numberp b) nil)
   (t (string< (format "%s" a) (format "%s" b)))))

(defun beads-list--column-sort-issues (issues column &optional descending)
  "Return ISSUES sorted by COLUMN.
When DESCENDING is non-nil, reverse the natural column order.  Ties are
resolved by issue id to keep org rendering deterministic."
  (let ((canonical-column (beads-list--sort-column-name column)))
    (sort (append issues nil)
          (lambda (a b)
            (let ((value-a (beads-list--sort-column-value a canonical-column))
                  (value-b (beads-list--sort-column-value b canonical-column)))
              (cond
               ((equal value-a value-b)
                (string< (or (alist-get 'id a) "")
                         (or (alist-get 'id b) "")))
               (descending
                (beads-list--compare-sort-values value-b value-a))
               (t
                (beads-list--compare-sort-values value-a value-b))))))))

(defvar-local beads-list--project-root nil
  "Project root for this beads list buffer.
Used to ensure refresh uses the correct project context.")

(defvar-local beads-org-list--project-root nil
  "Project root for this org list buffer.
Used to ensure refresh uses the correct project context.")

(declare-function beads-filter-menu "beads-transient")
(declare-function beads-delete-issue "beads-transient")
(declare-function beads-reopen-issue "beads-transient")
(declare-function beads-search "beads-transient")
(declare-function beads-stats "beads-transient")
(declare-function beads-create-issue "beads-transient")
(declare-function beads-create-issue-preview "beads-transient")
(declare-function beads-hierarchy-show "beads-hierarchy")
(declare-function beads-types-edit "beads-types")
(declare-function beads-views-menu "beads-transient")

(defvar beads-list-mark-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "m") #'beads-list-mark-regexp)
    map)
  "Keymap for mark prefix commands in beads-list-mode.")

(defvar beads-list-bulk-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "s") #'beads-list-bulk-status)
    (define-key map (kbd "p") #'beads-list-bulk-priority)
    (define-key map (kbd "a") #'beads-list-quick-assign)
    (define-key map (kbd "c") #'beads-list-bulk-close)
    (define-key map (kbd "D") #'beads-list-bulk-delete)
    map)
  "Keymap for bulk operation commands in beads-list-mode.")

(defvar beads-list-edit-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "t") #'beads-list-edit-title)
    (define-key map (kbd "s") #'beads-list-edit-status)
    (define-key map (kbd "p") #'beads-list-edit-priority)
    (define-key map (kbd "T") #'beads-list-edit-type)
    (define-key map (kbd "d") #'beads-list-edit-description)
    map)
  "Keymap for edit commands in beads-list-mode.")

(defvar beads-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map tabulated-list-mode-map)
    (define-key map (kbd "g") #'beads-list-refresh)
    (define-key map (kbd "RET") #'beads-list-goto-issue)
    (define-key map (kbd "c") #'beads-create-issue)
    (define-key map (kbd "C") #'beads-create-issue-preview)
    (define-key map (kbd "e") beads-list-edit-map)
    (define-key map (kbd "E") #'beads-list-edit-form)
    (define-key map (kbd "f") #'beads-filter-menu)
    (define-key map (kbd "/") #'beads-search)
    (define-key map (kbd "H") #'beads-hierarchy-show)
    (define-key map (kbd "P") #'beads-preview-mode)
    (define-key map (kbd "S") #'beads-stats)
    (define-key map (kbd "T") #'beads-types-edit)
    (define-key map (kbd "D") #'beads-delete-issue)
    (define-key map (kbd "R") #'beads-reopen-issue)
    (define-key map (kbd "s") #'beads-list-toggle-sort-mode)
    (define-key map (kbd "o") #'beads-list-cycle-sort)
    (define-key map (kbd "O") #'beads-list-reverse-sort)
    (define-key map (kbd "m") #'beads-list-mark)
    (define-key map (kbd "u") #'beads-list-unmark)
    (define-key map (kbd "U") #'beads-list-unmark-all)
    (define-key map (kbd "t") #'beads-list-toggle-marks)
    (define-key map (kbd "%") beads-list-mark-map)
    (define-key map (kbd "* m") #'beads-list-mark-regexp)
    (define-key map (kbd "* *") #'beads-list-toggle-marked-filter)
    (define-key map (kbd "B") beads-list-bulk-map)
    (define-key map (kbd "x") #'beads-list-bulk-close)
    (define-key map (kbd "a") #'beads-list-quick-assign)
    (define-key map (kbd "A") #'beads-list-assign-to-me)
    (define-key map (kbd "V") #'beads-views-menu)
    (define-key map (kbd "q") #'beads-list-quit)
    (define-key map (kbd "?") #'beads-menu)
    (define-key map (kbd "C-c m") #'beads-menu)
    (define-key map (kbd "M-n") #'beads-list-next-section)
    (define-key map (kbd "M-p") #'beads-list-previous-section)
    map)
  "Keymap for beads-list-mode.")

(defvar beads-org-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map org-mode-map)
    (define-key map (kbd "g") #'beads-org-list-refresh)
    (define-key map (kbd "RET") #'beads-list-goto-issue)
    (define-key map (kbd "c") #'beads-create-issue)
    (define-key map (kbd "C") #'beads-create-issue-preview)
    (define-key map (kbd "e") beads-list-edit-map)
    (define-key map (kbd "E") #'beads-list-edit-form)
    (define-key map (kbd "f") #'beads-filter-menu)
    (define-key map (kbd "/") #'beads-search)
    (define-key map (kbd "H") #'beads-org-list-hierarchy-show)
    (define-key map (kbd "P") #'beads-preview-mode)
    (define-key map (kbd "S") #'beads-stats)
    (define-key map (kbd "C-c C-t") #'beads-org-list-todo)
    (define-key map (kbd "T") #'beads-types-edit)
    (define-key map (kbd "D") #'beads-org-list-delete-issue)
    (define-key map (kbd "R") #'beads-org-list-reopen-issue)
    (define-key map (kbd "s") #'beads-list-toggle-sort-mode)
    (define-key map (kbd "m") #'beads-list-mark)
    (define-key map (kbd "u") #'beads-list-unmark)
    (define-key map (kbd "U") #'beads-list-unmark-all)
    (define-key map (kbd "t") #'beads-list-toggle-marks)
    (define-key map (kbd "%") beads-list-mark-map)
    (define-key map (kbd "* m") #'beads-list-mark-regexp)
    (define-key map (kbd "* *") #'beads-list-toggle-marked-filter)
    (define-key map (kbd "B") beads-list-bulk-map)
    (define-key map (kbd "x") #'beads-list-bulk-close)
    (define-key map (kbd "a") #'beads-list-quick-assign)
    (define-key map (kbd "A") #'beads-list-assign-to-me)
    (define-key map (kbd "V") #'beads-views-menu)
    (define-key map (kbd "n") #'org-next-visible-heading)
    (define-key map (kbd "p") #'org-previous-visible-heading)
    (define-key map (kbd "TAB") #'org-cycle)
    (define-key map (kbd "q") #'beads-list-quit)
    (define-key map (kbd "?") #'beads-menu)
    (define-key map (kbd "C-c m") #'beads-menu)
    map)
  "Keymap for `beads-org-list-mode'.")

(defun beads-list--row-face-for-id (id)
  "Return row face for issue ID, or nil if no special styling needed."
  (when beads-list-highlight-p0-rows
    (when-let ((issue (seq-find (lambda (i) (equal (alist-get 'id i) id))
                                beads-list--issues)))
      (when (= 0 (alist-get 'priority issue 2))
        'beads-list-row-p0))))

(defun beads-list--print-entry (id cols)
  "Print entry ID with COLS, applying row-level styling for P0 issues."
  (let ((beg (point)))
    (tabulated-list-print-entry id cols)
    (when-let ((row-face (beads-list--row-face-for-id id)))
      (font-lock-prepend-text-property beg (point) 'face row-face))))

(defun beads-list--format-header-line (stats)
  "Format STATS for display in header line."
  (let ((total (alist-get 'total_issues stats 0))
        (open (alist-get 'open_issues stats 0))
        (in-progress (alist-get 'in_progress_issues stats 0))
        (blocked (alist-get 'blocked_issues stats 0))
        (ready (alist-get 'ready_issues stats 0)))
    (format " %s total | %s open | %s in progress | %s blocked | %s ready"
            (propertize (number-to-string total) 'face 'beads-list-header-count)
            (propertize (number-to-string open) 'face 'beads-list-header-count)
            (propertize (number-to-string in-progress) 'face 'beads-list-header-count)
            (propertize (number-to-string blocked) 'face 'beads-list-header-count)
            (propertize (number-to-string ready) 'face 'beads-list-header-count))))

(defun beads-list--compute-stats (issues)
  "Compute stats alist from ISSUES list.

Returns an alist matching the shape consumed by
`beads-list--format-header-line': `total_issues', `open_issues',
`in_progress_issues', `blocked_issues', `closed_issues' and
`ready_issues'.

In beads, an issue's `status' can be \"open\" while it is also
considered blocked.  A blocked issue is reported by `bd' with
`dependency_count' > 0 (i.e. one or more incomplete blocking
dependencies).  Therefore `blocked_issues' counts entries whose
`dependency_count' is positive, and `ready_issues' counts open
entries with no incomplete blocking deps.

Note: counts reflect the issues currently fetched into the list
view.  List refreshes request all normal issues explicitly, so closed
issues are included when the backend supports the all-issues contract."
  (beads-list-model-compute-stats issues))

(defun beads-list--update-mode-line (&optional stats)
  "Update the mode line with current stats.

When STATS is non-nil, use it directly (an alist matching the
shape produced by `beads-list--compute-stats').  Otherwise
compute stats from `beads-list--issues'.

Respects `beads-list-show-header-stats'."
  (if beads-list-show-header-stats
      (let ((stats (or stats (beads-list--compute-stats beads-list--issues))))
        (setq mode-line-format
              `(" "
                mode-line-buffer-identification
                "  "
                ,(beads-list--format-header-line stats))))
    (setq mode-line-format (default-value 'mode-line-format))))

(defvar-local beads-list--window-selected nil
  "Non-nil when this list buffer's window was selected last time we
checked.  Used by `beads-list--maybe-refresh-on-select' to fire
`beads-list-refresh-async' only on the leading edge of a re-selection
(e.g. returning from a detail buffer), not on every window-state
change while the buffer is already selected.")

(defun beads-list--maybe-refresh-on-select (frame-or-window)
  "Run an async refresh when a `beads-list-mode' buffer becomes selected.

Hooked into `window-selection-change-functions' buffer-locally by
`beads-list-mode'.  Walks every window on FRAME-OR-WINDOW (a frame
or a window) and, for each `beads-list-mode' buffer whose window
just transitioned from unselected to selected, calls
`beads-list-refresh-async' silently.

The refresh is cheap: when `beads-cache' is active and the
freshness token is unchanged, the call short-circuits without any
list fetch or buffer rebuild (see `beads-list-refresh-async').
This is the event-driven replacement for the old 30s timer-based
auto-refresh: refresh happens when the user returns to the list
buffer (e.g. from `beads-detail-mode'), not on a fixed cadence."
  (let ((frame (cond ((framep frame-or-window) frame-or-window)
                     ((windowp frame-or-window)
                      (window-frame frame-or-window))
                     (t (selected-frame)))))
    (dolist (win (window-list frame 'no-mini))
      (when-let ((buf (window-buffer win)))
        (with-current-buffer buf
          (when (derived-mode-p 'beads-list-mode)
            (let ((now-selected (eq win (frame-selected-window frame))))
              (when (and now-selected
                         (not beads-list--window-selected))
                (beads-list-refresh-async t))
              (setq beads-list--window-selected now-selected))))))))

(defun beads-org-list--maybe-refresh-on-select (frame-or-window)
  "Run an async refresh when a `beads-org-list-mode' buffer becomes selected.

This mirrors `beads-list--maybe-refresh-on-select' for the experimental
org list and uses the same freshness short-circuit via
`beads-org-list-refresh-async'."
  (let ((frame (cond ((framep frame-or-window) frame-or-window)
                     ((windowp frame-or-window)
                      (window-frame frame-or-window))
                     (t (selected-frame)))))
    (dolist (win (window-list frame 'no-mini))
      (when-let ((buf (window-buffer win)))
        (with-current-buffer buf
          (when (derived-mode-p 'beads-org-list-mode)
            (let ((now-selected (eq win (frame-selected-window frame))))
              (when (and now-selected
                         (not beads-list--window-selected))
                (beads-org-list-refresh-async t))
              (setq beads-list--window-selected now-selected))))))))

(define-derived-mode beads-list-mode tabulated-list-mode "Beads-List"
  "Major mode for displaying Beads issues in a table.

\\{beads-list-mode-map}"
  (setq tabulated-list-format (beads-list--build-format))
  (setq tabulated-list-padding 2)
  (setq tabulated-list-sort-key (cons "Date" t))
  (setq tabulated-list-printer #'beads-list--print-entry)
  (add-hook 'tabulated-list-revert-hook #'beads-list-refresh nil t)
  ;; Event-driven refresh: re-fetch when the user returns to this
  ;; buffer (e.g. from a detail view).  The async refresh short-
  ;; circuits via the cache freshness token when nothing changed,
  ;; so this is essentially free in the common case.  Replaces the
  ;; old timer-based auto-refresh (see bdel-lc6).
  (add-hook 'window-selection-change-functions
            #'beads-list--maybe-refresh-on-select nil t)
  (tabulated-list-init-header)
  (hl-line-mode 1)
  (beads-show-hint))

(define-derived-mode beads-org-list-mode org-mode "Beads-Org-List"
  "Major mode for displaying Beads issues as org headings.

This mode renders a generated, project-scoped org buffer from Beads data;
it does not visit or require an org file on disk.  The legacy table view
remains available through `beads-list-legacy'.

\\{beads-org-list-mode-map}"
  (setq-local org-todo-keywords '((sequence "TODO" "WIP" "WAIT" "|" "DONE")))
  (setq-local org-todo-keyword-faces '(("DONE" . beads-status-closed)))
  (setq-local org-startup-folded nil)
  (setq-local beads-org-list--project-root nil)
  (setq buffer-read-only t)
  (add-hook 'window-selection-change-functions
            #'beads-org-list--maybe-refresh-on-select nil t)
  (hl-line-mode 1)
  (beads-list--update-mode-line))

;; Configure evil-mode IF user has it loaded (does not enable evil)
(with-eval-after-load 'evil
  (evil-set-initial-state 'beads-list-mode 'normal)
  (evil-set-initial-state 'beads-org-list-mode 'normal)
  (evil-make-overriding-map beads-list-mode-map 'normal)
  (evil-make-overriding-map beads-org-list-mode-map 'normal))

(defun beads-list--rebuild-from-issues (all-issues &optional silent message-prefix)
  "Rebuild the tabulated-list display from ALL-ISSUES.

When SILENT is non-nil, suppress the refresh message.
MESSAGE-PREFIX (default \"Refreshed\") is the verb used in the message.

Saves point/line/window-start before rebuilding and restores them after,
so refreshes never yank the cursor back to the top of the buffer.

Applies `beads-list--filter' if set, and the `beads-list--show-only-marked'
filter.  Updates `beads-list--issues' to the filtered set, but computes
mode-line stats from the unfiltered ALL-ISSUES.

Shared by `beads-list-refresh' (sync) and `beads-list-refresh-async'
(async).  Must be called with the list buffer current."
  (let* ((saved-id (tabulated-list-get-id))
         (saved-line (line-number-at-pos))
         (saved-start (when-let ((win (get-buffer-window (current-buffer))))
                        (window-start win)))
         (effective-sort-mode (beads-list--effective-sort-mode))
         (model (beads-list-model-build
                 all-issues
                 :filter beads-list--filter
                 :marked-ids beads-list--marked
                 :show-only-marked beads-list--show-only-marked
                 :sort-mode effective-sort-mode))
         (display-issues (beads-list-model-display-issues model))
         (id-width (beads-list--max-id-width display-issues)))
    (setq beads-list--issues (beads-list-model-issues model))
    (setq tabulated-list-format (beads-list--build-format id-width))
    (tabulated-list-init-header)
    (when (eq effective-sort-mode 'sectioned)
      (setq tabulated-list-sort-key nil))
    (setq tabulated-list-entries (beads-list-entries display-issues))
    (tabulated-list-print t)
    (beads-list--add-section-separators)
    ;; Restore point: prefer matching the issue id, then the line
    ;; number, then top-of-buffer as a last resort.
    (if saved-id
        (unless (beads-list-goto-id saved-id)
          (goto-char (point-min))
          (forward-line (1- (min saved-line
                                 (line-number-at-pos (point-max))))))
      (goto-char (point-min)))
    ;; Restore window-start so the visible region doesn't jump.
    (when-let ((win (get-buffer-window (current-buffer)))
               (start saved-start))
      (set-window-start win (min start (point-max))))
    (beads-list--update-mode-line (beads-list-model-stats model))
    (unless silent
      (let ((filter-msg (if beads-list--filter
                            (format " [%s]" (beads-filter-name beads-list--filter))
                          ""))
            (sort-msg (if (eq effective-sort-mode 'sectioned)
                          " (sectioned)"
                        "")))
        (message "%s %d issues%s%s"
                 (or message-prefix "Refreshed")
                 (length beads-list--issues) filter-msg sort-msg)))))

(defun beads-org-list--rebuild-from-issues (all-issues &optional silent message-prefix)
  "Rebuild the generated org list display from ALL-ISSUES.

When SILENT is non-nil, suppress the refresh message.
MESSAGE-PREFIX (default \"Refreshed\") is the verb used in the message.

Preserves point by `BEADS_ID' when possible, falls back to a nearby
heading when the current issue no longer exists, and reapplies folded
subtrees by issue ID after regenerating the org text.

Must be called with a `beads-org-list-mode' buffer current."
  (let* ((saved-id (beads-list--org-id-at-point))
         (saved-index (and saved-id
                           (cl-position saved-id beads-list--issues
                                        :key (lambda (issue)
                                               (alist-get 'id issue))
                                        :test #'equal)))
         (saved-line (line-number-at-pos))
         (saved-start-line (when-let ((win (get-buffer-window (current-buffer))))
                             (line-number-at-pos (window-start win))))
         (folded-ids (beads-list--org-folded-ids))
         (effective-sort-mode (beads-list--effective-sort-mode))
         (model (beads-list-model-build
                 all-issues
                 :filter beads-list--filter
                 :marked-ids beads-list--marked
                 :show-only-marked beads-list--show-only-marked
                 :sort-mode effective-sort-mode))
         (display-issues (if (and (eq effective-sort-mode 'column)
                                  (car tabulated-list-sort-key))
                             (beads-list--column-sort-issues
                              (beads-list-model-display-issues model)
                              (car tabulated-list-sort-key)
                              (cdr tabulated-list-sort-key))
                           (beads-list-model-display-issues model)))
         (org-text (beads-list-render-org
                    display-issues nil (eq effective-sort-mode 'sectioned)))
         (inhibit-read-only t))
    (setq beads-list--issues (beads-list-model-issues model))
    (erase-buffer)
    (insert "#+TITLE: Beads Issues\n")
    (insert "#+TODO: TODO WIP WAIT | DONE\n\n")
    (unless (string= org-text "")
      (insert org-text)
      (insert "\n"))
    (beads-list--org-update-mark-display)
    (beads-list--org-restore-folds folded-ids)
    (cond
     ((and saved-id (beads-list--org-goto-id saved-id)))
     ((and saved-index display-issues)
      (beads-list--org-goto-id
       (alist-get 'id (nth (min saved-index (1- (length display-issues)))
                           display-issues))))
     (t
      (beads-list--org-goto-near-line saved-line)))
    (when-let ((win (get-buffer-window (current-buffer)))
               (line saved-start-line))
      (let ((restored-point (point)))
        (save-excursion
          (goto-char (point-min))
          (forward-line (1- (min line (line-number-at-pos (point-max)))))
          (set-window-start win (point)))
        (unless (pos-visible-in-window-p restored-point win)
          (save-excursion
            (goto-char restored-point)
            (beginning-of-line)
            (set-window-start win (point))))))
    (beads-list--update-mode-line (beads-list-model-stats model))
    (unless silent
      (let ((filter-msg (if beads-list--filter
                            (format " [%s]" (beads-filter-name beads-list--filter))
                          ""))
            (sort-msg (if (eq effective-sort-mode 'sectioned)
                          " (sectioned)"
                        "")))
        (message "%s %d issues%s%s (org)"
                 (or message-prefix "Refreshed")
                 (length beads-list--issues) filter-msg sort-msg)))))

(defun beads-list-refresh (&optional silent)
  "Fetch issues from daemon and refresh the display.
When SILENT is non-nil, don't show message.
Applies `beads-list--filter' if set, and `beads-list--show-only-marked' filter.

When called from `beads-org-list-mode', refresh the org view so shared
menu entries continue to work in the default list UI.

Synchronous: blocks until the fetch completes and always rebuilds the
display.  Use this for interactive refreshes and after writes where the
user expects to see the new state immediately.  For background/timer
refreshes that may safely no-op when nothing has changed, use
`beads-list-refresh-async' instead."
  (interactive)
  (if (derived-mode-p 'beads-org-list-mode)
      (beads-org-list-refresh silent)
    (condition-case err
        (let ((all-issues (cdr (beads-cache-refresh))))
          (beads-list--rebuild-from-issues all-issues silent "Refreshed"))
      (beads-client-error
       (message "Failed to fetch issues: %s" (error-message-string err))))))

(cl-defun beads-list-refresh-async (&optional silent)
  "Fetch issues asynchronously and refresh the display.

When SILENT is non-nil, suppress the refresh message.
Unlike `beads-list-refresh', this uses `make-process' to fetch
issues without blocking Emacs.  Intended for event-driven background
refreshes (e.g. the on-window-selection hook installed by
`beads-list-mode'; see `beads-list--maybe-refresh-on-select') where
the user isn't waiting for the result.

Preserves point and window-start across the rebuild so a background
refresh fired while the user is scrolling does not yank the cursor
back to the top of the buffer (see bdel-efx).

When the cache is enabled and the active backend supports the
`freshness' check, runs a sub-10ms freshness query first.  If the
freshness token is unchanged, returns immediately without fetching
the list or touching the buffer — eliminating both the async list
RPC and the redundant rebuild for the common no-change case.  This
short-circuit is intentional and is why `beads-list-refresh-async'
is NOT a drop-in replacement for `beads-list-refresh': callers that
mutate purely client-side state (sort mode, marked-only filter, …)
need the unconditional rebuild that the sync version provides.

When the token has changed, the freshness value captured here is
stored on the cache after the async list returns, preserving the
token-before-list ordering invariant (see `beads-cache.el')."
  (let* ((buffer (current-buffer))
         (cache (and beads-cache-enabled
                     (beads-cache-supported-p)
                     (beads-cache-for-project)))
         (cached-token (and cache (beads-cache-freshness-token cache)))
         ;; Fetch the token only when the cache could possibly use it:
         ;; either to short-circuit (cached-token present) or to store
         ;; alongside the result (cache present, token absent).  Skip
         ;; the round-trip entirely when the cache isn't usable.
         (current-token
          (and cache
               (condition-case nil
                   (beads-client-freshness)
                 (beads-client-error nil)
                 (beads-backend-error nil)))))
    ;; Fast path: cache hot AND token unchanged → no list fetch, no
    ;; UI churn.  Primary win for the on-select event-driven refresh:
    ;; returning to a list buffer after a brief detour costs only the
    ;; sub-10ms freshness query.
    (when (and cached-token current-token
               (equal cached-token current-token))
      (cl-return-from beads-list-refresh-async nil))
    (beads-client-list-async
     (lambda (err all-issues)
       (unless (buffer-live-p buffer)
         (cl-return-from nil))
       ;; Update the cache with the result we just fetched so future
       ;; calls (sync or async) can short-circuit.
       (when (and cache (null err))
         (setf (beads-cache-issues cache) all-issues)
         (setf (beads-cache-freshness-token cache) current-token))
       (with-current-buffer buffer
         (if err
             (message "Auto-refresh failed: %s"
                      (if (> (length err) 200)
                          (concat (substring err 0 197) "...")
                        err))
           (beads-list--rebuild-from-issues all-issues silent "Auto-refreshed"))))
     '(:all t))))

(defun beads-org-list-refresh (&optional silent)
  "Fetch all issues and refresh the org list display.
When SILENT is non-nil, don't show a message."
  (interactive)
  (condition-case err
      (let ((all-issues (cdr (beads-cache-refresh))))
        (beads-org-list--rebuild-from-issues all-issues silent "Refreshed"))
    (beads-client-error
     (message "Failed to fetch issues: %s" (error-message-string err)))))

(cl-defun beads-org-list-refresh-async (&optional silent)
  "Fetch all issues asynchronously and refresh the org list.

When SILENT is non-nil, suppress the refresh message.  Like
`beads-list-refresh-async', this uses the project cache freshness token
when available and no-ops if the issue list has not changed."
  (let* ((buffer (current-buffer))
         (cache (and beads-cache-enabled
                     (beads-cache-supported-p)
                     (beads-cache-for-project)))
         (cached-token (and cache (beads-cache-freshness-token cache)))
         (current-token
          (and cache
               (condition-case nil
                   (beads-client-freshness)
                 (beads-client-error nil)
                 (beads-backend-error nil)))))
    (when (and cached-token current-token
               (equal cached-token current-token))
      (cl-return-from beads-org-list-refresh-async nil))
    (beads-client-list-async
     (lambda (err all-issues)
       (when (buffer-live-p buffer)
         (when (and cache (null err))
           (setf (beads-cache-issues cache) all-issues)
           (setf (beads-cache-freshness-token cache) current-token))
         (with-current-buffer buffer
           (if err
               (message "Auto-refresh failed: %s"
                        (if (> (length err) 200)
                            (concat (substring err 0 197) "...")
                          err))
             (beads-org-list--rebuild-from-issues all-issues silent
                                                  "Auto-refreshed")))))
     '(:all t))))

(defun beads-list-goto-id (id)
  "Move point to the line with issue ID.
Returns t if found, nil otherwise."
  (let ((found nil))
    (goto-char (point-min))
    (while (and (not found) (not (eobp)))
      (if (equal id (tabulated-list-get-id))
          (setq found t)
        (forward-line 1)))
    found))

(defun beads-list-entries (issues)
  "Convert ISSUES to tabulated-list entries."
  (mapcar (lambda (issue)
            (let ((id (alist-get 'id issue)))
              (list id (beads-list--build-entry issue))))
          issues))

(defun beads-list--org-todo-keyword (issue)
  "Return the org TODO keyword for ISSUE's beads status."
  (or (cdr (assoc (alist-get 'status issue) beads-list--org-status-todo-map))
      "TODO"))

(defun beads-list--org-status-for-todo-keyword (todo)
  "Return the beads status represented by org TODO keyword TODO."
  (cdr (assoc todo beads-list--org-todo-status-map)))

(defun beads-list--org-next-todo-keyword (todo)
  "Return the next editable beads org TODO keyword after TODO."
  (or (cadr (member todo beads-list--org-todo-cycle))
      (car beads-list--org-todo-cycle)))

(defun beads-list--org-current-todo-keyword ()
  "Return the editable beads org TODO keyword at the current heading."
  (save-excursion
    (org-back-to-heading t)
    (let ((regexp (concat "^\\*+\\s-+\\("
                          (regexp-opt beads-list--org-todo-cycle)
                          "\\)\\(?:\\s-\\|$\\)")))
      (when (looking-at regexp)
        (match-string-no-properties 1)))))

(defun beads-org-list-todo ()
  "Cycle the current org list issue through TODO, WIP, WAIT, and DONE.

The generated `beads-org-list-mode' buffer is read-only, so this command
updates the underlying beads issue instead of editing the buffer text in
place.  The mapping is TODO -> open, WIP -> in_progress,
WAIT -> blocked, and DONE -> closed."
  (interactive)
  (unless (derived-mode-p 'beads-org-list-mode)
    (user-error "Not in a beads org list buffer"))
  (let* ((issue (beads-list--get-issue-at-point))
         (id (alist-get 'id issue)))
    (unless id
      (user-error "No issue at point"))
    (let* ((current-todo (beads-list--org-current-todo-keyword))
           (next-todo (beads-list--org-next-todo-keyword current-todo))
           (status (beads-list--org-status-for-todo-keyword next-todo)))
      (beads-client-update id :status status)
      (beads-org-list-refresh t)
      (message "Updated %s to %s" id status))))

(defun beads-list--org-priority-cookie (issue)
  "Return an org priority cookie for ISSUE, or nil when absent.
Beads P0/P1/P2 map to org A/B/C respectively.  Lower-priority
beads values are omitted to keep headings compact."
  (pcase (alist-get 'priority issue)
    (0 "[#A]")
    (1 "[#B]")
    (2 "[#C]")
    (_ nil)))

(defun beads-list--org-tag (value)
  "Return VALUE converted to an org tag-safe string, or nil.
Spaces and punctuation become underscores; empty results are omitted."
  (when (and value (stringp value) (> (length value) 0))
    (let ((tag (replace-regexp-in-string "[^[:alnum:]_@#%]" "_" value)))
      (unless (string= tag "")
        tag))))

(defun beads-list--org-single-line (value)
  "Return string VALUE normalized for one-line org heading/property use.
Newlines and tabs are replaced with spaces so issue data cannot escape
its heading line or property drawer entry."
  (replace-regexp-in-string "[\n\r\t]+" " " value))

(defun beads-list--org-heading (issue &optional level)
  "Return a compact org heading for ISSUE at LEVEL.
The heading contains stars, TODO keyword, optional org priority
cookie, title, and optional issue type as a tag.  Wide metadata is
reserved for `beads-list--org-properties'."
  (let* ((stars (make-string (or level 1) ?*))
         (todo (beads-list--org-todo-keyword issue))
         (priority (beads-list--org-priority-cookie issue))
         (title (beads-list--org-single-line (or (alist-get 'title issue) "")))
         (type-tag (beads-list--org-tag (alist-get 'issue_type issue)))
         (parts (delq nil (list stars todo priority title))))
    (concat (mapconcat #'identity parts " ")
            (if type-tag (format " :%s:" type-tag) ""))))

(defun beads-list--org-property-value (value)
  "Return VALUE formatted for an org property drawer, or nil if empty."
  (cond
   ((null value) nil)
   ((stringp value)
    (unless (string= value "")
      (beads-list--org-single-line value)))
   ((vectorp value) (beads-list--org-property-value (append value nil)))
   ((listp value)
    (let ((items (delq nil (mapcar #'beads-list--org-property-value value))))
      (unless (null items)
        (mapconcat #'identity items ","))))
   (t (format "%s" value))))

(defun beads-list--org-properties (issue)
  "Return ISSUE metadata as org property drawer pairs.
The returned alist has string property names, including stable lookup
property `BEADS_ID'.  Missing and empty values are omitted."
  (let (properties seen)
    (dolist (field beads-list--org-property-fields)
      (let* ((property (car field))
             (source (cdr field))
             (value (beads-list--org-property-value (alist-get source issue))))
        (when (and value (not (memq property seen)))
          (push property seen)
          (push (cons (symbol-name property) value) properties))))
    (nreverse properties)))

(defun beads-list--org-property-drawer (issue)
  "Return an org property drawer string for ISSUE.
Returns an empty string when ISSUE has no non-empty org properties."
  (let ((properties (beads-list--org-properties issue)))
    (if properties
        (concat ":PROPERTIES:\n"
                (mapconcat (lambda (property)
                             (format ":%s: %s" (car property) (cdr property)))
                           properties "\n")
                "\n:END:")
      "")))

(defun beads-list--org-render-node (node level)
  "Return org text for forest NODE rendered at heading LEVEL."
  (let* ((issue (alist-get 'issue node))
         (children (alist-get 'children node))
         (drawer (beads-list--org-property-drawer issue))
         (lines (delq nil
                      (append (list (beads-list--org-heading issue level)
                                    (unless (string= drawer "") drawer))
                              (mapcar (lambda (child)
                                        (beads-list--org-render-node child (1+ level)))
                                      children)))))
    (mapconcat #'identity lines "\n")))

(defun beads-list--org-render-forest (forest &optional level)
  "Return org text for FOREST of beads list model nodes.
LEVEL defaults to 1.  Parent-child relationships are represented by
org heading depth."
  (mapconcat (lambda (node)
               (beads-list--org-render-node node (or level 1)))
             forest "\n"))

(defun beads-list--org-section-name (section)
  "Return the org section heading name for SECTION number."
  (pcase section
    (0 "Ready")
    (1 "In Progress")
    (2 "Blocked")
    (3 "Completed")
    (_ "Other")))

(defun beads-list--org-issue-section (issue)
  "Return org section number for ISSUE.
Sections are 0=Ready, 1=In Progress, 2=Blocked, and 3=Completed.
Org sections primarily follow the rendered TODO keyword.  Open issues
with positive `dependency_count' remain in Blocked to preserve existing
dependency grouping."
  (let ((todo (beads-list--org-todo-keyword issue))
        (dep-count (or (alist-get 'dependency_count issue) 0)))
    (cond
     ((string= todo "DONE") 3)
     ((string= todo "WIP") 1)
     ((or (string= todo "WAIT")
          (> dep-count 0))
      2)
     (t 0))))

(defun beads-list--org-render-sectioned-forest (forest &optional level)
  "Return org text for FOREST grouped by root issue section.

Only root nodes are grouped.  Descendants remain nested under their
parent regardless of their own status, preserving the one-heading-per-
issue tree invariant and avoiding duplicate children across sections.
Section headings intentionally omit `BEADS_ID' properties so issue-at-
point commands skip them."
  (let ((level (or level 1))
        (sections (list (cons 0 nil) (cons 1 nil) (cons 2 nil) (cons 3 nil))))
    (dolist (node forest)
      (let* ((issue (alist-get 'issue node))
             (section (beads-list--org-issue-section issue))
             (cell (assq section sections)))
        (when cell
          (setcdr cell (append (cdr cell) (list node))))))
    (mapconcat
     #'identity
     (delq nil
           (mapcar (lambda (section)
                     (when (cdr section)
                       (concat (make-string level ?*) " "
                               (beads-list--org-section-name (car section))
                               "\n"
                               (beads-list--org-render-forest
                                (cdr section) (1+ level)))))
                   sections))
     "\n")))

(defun beads-list-render-org (issues &optional level sectioned)
  "Return deterministic org text rendering ISSUES as nested headings.
ISSUES is a flat list of issue alists.  Parent-child nesting is built
with `beads-list-model-flat-issues-to-forest', preserving orphaned
issues as roots while keeping their parent metadata in the property
drawer.  LEVEL defaults to 1.

When SECTIONED is non-nil, group only root issues under Ready,
In Progress, Blocked, and Completed headings.  Child issues always stay
below their parent and are never repeated in another section."
  (let ((forest (beads-list-model-flat-issues-to-forest issues)))
    (if sectioned
        (beads-list--org-render-sectioned-forest forest level)
      (beads-list--org-render-forest forest level))))

(defun beads-list--format-id (issue)
  "Format ID column for ISSUE."
  (alist-get 'id issue))

(defun beads-list--format-date (issue)
  "Format date column for ISSUE.
Displays YYYY-MM-DD from created_at timestamp."
  (let ((created (alist-get 'created_at issue)))
    (if (and created (stringp created))
        (let ((parts (split-string created "T")))
          (or (car parts) ""))
      "")))

(defun beads-list--sort-by-date (a b)
  "Compare entries A and B by their date column for sorting.
Returns non-nil if A should come before B."
  (let ((date-a (aref (cadr a) 1))
        (date-b (aref (cadr b) 1)))
    (string< date-a date-b)))

(defun beads-list--issue-section (issue)
  "Return section number for ISSUE: 0=unblocked, 1=blocked, 2=closed."
  (beads-list-model-issue-section issue))

(defun beads-list--sectioned-sort (issues)
  "Sort ISSUES into sections: unblocked, blocked, closed.
ISSUES can be a list or vector.
Within unblocked and blocked sections, sort by priority (ascending).
Within closed section, sort by closed_at date (most recent first)."
  (beads-list-model-sectioned-sort issues))

(defun beads-list--clear-section-overlays ()
  "Remove all section separator overlays."
  (mapc #'delete-overlay beads-list--section-overlays)
  (setq beads-list--section-overlays nil))

(defun beads-list--add-section-separators ()
  "Add visual separators between sections after printing.
Only adds separators when in sectioned sort mode and
`beads-list-section-separators' is non-nil."
  (beads-list--clear-section-overlays)
  (when (and beads-list-section-separators
             (eq (beads-list--effective-sort-mode) 'sectioned))
    (save-excursion
      (goto-char (point-min))
      (let ((prev-section nil))
        (while (not (eobp))
          (when-let* ((id (tabulated-list-get-id))
                      (issue (seq-find (lambda (i) (equal (alist-get 'id i) id))
                                       beads-list--issues))
                      (section (beads-list--issue-section issue)))
            (when (and prev-section (> section prev-section))
              (let* ((ov (make-overlay (line-beginning-position)
                                       (line-beginning-position)))
                     (label (pcase section
                              (1 "Blocked")
                              (2 "Completed")))
                     (separator (propertize (format "\n  ── %s ──\n" label)
                                            'face 'shadow)))
                (overlay-put ov 'before-string separator)
                (push ov beads-list--section-overlays)))
            (setq prev-section section))
          (forward-line 1))))))

(defun beads-list--section-positions ()
  "Return sorted list of section start positions.
Includes `point-min' for the first section and overlay positions
for subsequent sections."
  (let ((positions (list (point-min))))
    (dolist (ov beads-list--section-overlays)
      (when (overlay-buffer ov)
        (push (overlay-start ov) positions)))
    (sort positions #'<)))

(defun beads-list-next-section ()
  "Move point to the next section in the beads list."
  (interactive)
  (let* ((positions (beads-list--section-positions))
         (next (seq-find (lambda (pos) (> pos (point))) positions)))
    (when next
      (goto-char next))))

(defun beads-list-previous-section ()
  "Move point to the previous section in the beads list."
  (interactive)
  (let* ((positions (reverse (beads-list--section-positions)))
         (prev (seq-find (lambda (pos) (< pos (point))) positions)))
    (when prev
      (goto-char prev))))

(defun beads-list--format-title (issue)
  "Format title column for ISSUE, truncating if needed."
  (let ((title (alist-get 'title issue "")))
    (if (> (length title) 50)
        (concat (substring title 0 47) "...")
      title)))

(defun beads-list--format-assignee (issue)
  "Format assignee column for ISSUE."
  (or (alist-get 'assignee issue) ""))

(defun beads-list--format-labels (issue)
  "Format labels column for ISSUE as comma-separated string."
  (let ((labels (alist-get 'labels issue)))
    (if (and labels (> (length labels) 0))
        (mapconcat #'identity labels ",")
      "")))

(defun beads-list--format-deps (issue)
  "Format dependency indicator for ISSUE.
Shows ↑ for has parents, ↓ for has children, ↕ for both."
  (let ((dep-count (alist-get 'dependency_count issue 0))
        (dependent-count (alist-get 'dependent_count issue 0)))
    (cond
     ((and (> dep-count 0) (> dependent-count 0))
      (propertize "↕" 'face 'beads-list-deps-parent))
     ((> dep-count 0)
      (propertize "↑" 'face 'beads-list-deps-blocked))
     ((> dependent-count 0)
      (propertize "↓" 'face 'beads-list-deps-child))
     (t ""))))

(defun beads-list--tabulated-id-at-point ()
  "Return the tabulated issue ID at point, tolerating trailing blank lines."
  (or (tabulated-list-get-id)
      (save-excursion
        (beginning-of-line)
        (tabulated-list-get-id))
      (save-excursion
        (beginning-of-line)
        (when (and (not (bobp))
                   (looking-at-p "[[:space:]]*$"))
          (forward-line -1)
          (end-of-line)
          (tabulated-list-get-id)))))

(defun beads-list--get-issue-at-point ()
  "Get issue data at current line.
Returns the issue alist or nil if not found."
  (when-let ((id (cond
                  ((derived-mode-p 'beads-org-list-mode)
                   (beads-list--org-id-at-point))
                  ((derived-mode-p 'tabulated-list-mode)
                   (beads-list--tabulated-id-at-point)))))
    (beads-list-model-find-by-id beads-list--issues id)))

(defun beads-list--org-id-at-point ()
  "Return the BEADS_ID for the org heading at point, or nil.

The lookup is intentionally non-inheriting so commands in generated
org list buffers do not accidentally target a parent issue when point is
on a group/section heading or another heading without Beads metadata."
  (when (and (derived-mode-p 'org-mode)
             (not (org-before-first-heading-p)))
    (org-entry-get nil "BEADS_ID" nil)))

(defun beads-list--org-goto-id (id)
  "Move point to the org heading with BEADS_ID equal to ID.
Returns t when the heading is found."
  (let (found)
    (goto-char (point-min))
    (while (and (not found)
                (re-search-forward org-heading-regexp nil t))
      (beginning-of-line)
      (if (equal id (org-entry-get nil "BEADS_ID" nil))
          (setq found t)
        (forward-line 1)))
    found))

(defun beads-list--org-goto-near-line (line)
  "Move point to a deterministic nearby issue heading around LINE.
Prefer the heading containing LINE, then the next heading, then the
previous heading, and finally `point-min' for an empty generated list."
  (goto-char (point-min))
  (forward-line (1- (min (max line 1)
                         (line-number-at-pos (point-max)))))
  (cond
   ((and (org-at-heading-p)
         (beads-list--org-id-at-point)))
   ((and (not (org-before-first-heading-p))
         (save-excursion
           (org-back-to-heading t)
           (beads-list--org-id-at-point)))
    (org-back-to-heading t))
   ((re-search-forward org-heading-regexp nil t)
    (beginning-of-line))
   ((re-search-backward org-heading-regexp nil t)
    (beginning-of-line))
   (t
    (goto-char (point-min)))))

(defun beads-list--org-heading-folded-p ()
  "Return non-nil when the current org heading's subtree is folded."
  (save-excursion
    (end-of-line)
    (or (and (fboundp 'org-fold-folded-p)
             (org-fold-folded-p (point)))
        (outline-invisible-p (point)))))

(defun beads-list--org-folded-ids ()
  "Return BEADS_ID values for currently folded org issue subtrees."
  (let (ids)
    (when (derived-mode-p 'org-mode)
      (save-excursion
        (goto-char (point-min))
        (while (re-search-forward org-heading-regexp nil t)
          (beginning-of-line)
          (when-let ((id (and (beads-list--org-heading-folded-p)
                              (org-entry-get nil "BEADS_ID" nil))))
            (push id ids))
          (forward-line 1))))
    (nreverse ids)))

(defun beads-list--org-restore-folds (ids)
  "Fold generated org issue subtrees whose BEADS_ID is in IDS."
  (when ids
    (save-excursion
      (dolist (id ids)
        (when (beads-list--org-goto-id id)
          (org-fold-hide-subtree))))))

(defun beads-list--org-clear-mark-overlays ()
  "Remove org list mark overlays from the current buffer."
  (mapc #'delete-overlay beads-list--org-mark-overlays)
  (setq beads-list--org-mark-overlays nil))

(defun beads-list--org-update-mark-display ()
  "Update visual mark indicators for generated org issue headings."
  (beads-list--org-clear-mark-overlays)
  (when beads-list--marked
    (save-excursion
      (dolist (id beads-list--marked)
        (when (beads-list--org-goto-id id)
          (let ((overlay (make-overlay (line-beginning-position)
                                       (line-beginning-position))))
            (overlay-put overlay 'before-string
                         (propertize "★ " 'face 'bold))
            (push overlay beads-list--org-mark-overlays)))))))

(defun beads-list--issue-id-at-point ()
  "Return the current issue ID in either list view, or nil."
  (cond
   ((derived-mode-p 'beads-org-list-mode)
    (beads-list--org-id-at-point))
   ((derived-mode-p 'tabulated-list-mode)
    (tabulated-list-get-id))))

(defun beads-list--forward-after-mark ()
  "Move to the next issue after a mark command in the current view."
  (cond
   ((derived-mode-p 'beads-org-list-mode)
    (forward-line 1)
    (unless (re-search-forward org-heading-regexp nil t)
      (goto-char (point-max)))
    (when (org-at-heading-p)
      (beginning-of-line)))
   ((derived-mode-p 'tabulated-list-mode)
    (forward-line 1))))

(defun beads-list--refresh-current-view (&optional silent)
  "Refresh the current Beads list view.
When SILENT is non-nil, suppress the refresh message where supported."
  (cond
   ((derived-mode-p 'beads-org-list-mode)
    (beads-org-list-refresh silent))
   ((derived-mode-p 'beads-list-mode)
    (beads-list-refresh silent))))

(defun beads-list--has-active-filter ()
  "Return non-nil if any filter is currently active."
  (or beads-list--filter beads-list--show-only-marked))

(defun beads-list-quit ()
  "Quit beads list, clearing filters progressively.
First clears active filters, then closes preview, then kills the buffer."
  (interactive)
  (cond
   ((beads-list--has-active-filter)
    (setq beads-list--filter nil)
    (setq beads-list--show-only-marked nil)
    (beads-list--refresh-current-view t)
    (message "Filter cleared"))
   (beads-preview-mode
    (beads-preview-mode -1))
   (t
    (beads-core-quit-window-kill-buffer))))

(defun beads-list-toggle-sort-mode ()
  "Toggle between sectioned and unsectioned sort modes.

In the table view, unsectioned mode uses normal tabulated-list column
sorting.  In the org view, unsectioned mode applies the current column
sort before rendering parent-child nesting."
  (interactive)
  (setq beads-list--sort-mode-override
        (if (eq (beads-list--effective-sort-mode) 'sectioned)
            'column
          'sectioned))
  (if (and (or (derived-mode-p 'beads-list-mode)
               (derived-mode-p 'beads-org-list-mode))
           (eq beads-list--sort-mode-override 'column))
      (setq tabulated-list-sort-key (cons "Date" t)))
  (beads-list--refresh-current-view t)
  (message "Sort mode: %s" beads-list--sort-mode-override))

(defun beads-list-cycle-sort ()
  "Cycle through sort columns.
If in sectioned mode, first switches to column mode."
  (interactive)
  (when (eq (beads-list--effective-sort-mode) 'sectioned)
    (setq beads-list--sort-mode-override 'column)
    (setq tabulated-list-sort-key (cons "Date" nil)))
  (let* ((columns (beads-list--column-names))
         (current (car tabulated-list-sort-key))
         (flip (cdr tabulated-list-sort-key))
         (idx (or (seq-position columns current #'string=) 0))
         (next-idx (mod (1+ idx) (length columns)))
         (next-col (nth next-idx columns)))
    (setq tabulated-list-sort-key (cons next-col flip))
    (tabulated-list-init-header)
    (tabulated-list-print t)
    (message "Sorted by %s%s" next-col (if flip " (descending)" ""))))

(defun beads-list-reverse-sort ()
  "Reverse the current sort direction.
If in sectioned mode, first switches to column mode."
  (interactive)
  (when (eq (beads-list--effective-sort-mode) 'sectioned)
    (setq beads-list--sort-mode-override 'column)
    (setq tabulated-list-sort-key (cons "Date" nil)))
  (let ((current (car tabulated-list-sort-key))
        (flip (cdr tabulated-list-sort-key)))
    (setq tabulated-list-sort-key (cons current (not flip)))
    (tabulated-list-init-header)
    (tabulated-list-print t)
    (message "Sorted by %s%s" current (if (not flip) " (descending)" ""))))

(defun beads-list--update-mark-display ()
  "Update the display after marking changes."
  (cond
   ((derived-mode-p 'beads-org-list-mode)
    (beads-list--org-update-mark-display))
   ((derived-mode-p 'beads-list-mode)
    (setq tabulated-list-entries (beads-list-entries beads-list--issues))
    (tabulated-list-print t))))

(defun beads-list-mark ()
  "Mark issue at point and move to next line."
  (interactive)
  (when-let ((id (beads-list--issue-id-at-point)))
    (unless (member id beads-list--marked)
      (push id beads-list--marked))
    (beads-list--update-mark-display)
    (beads-list--forward-after-mark)
    (message "%d marked" (length beads-list--marked))))

(defun beads-list-unmark ()
  "Unmark issue at point and move to next line."
  (interactive)
  (when-let ((id (beads-list--issue-id-at-point)))
    (setq beads-list--marked (delete id beads-list--marked))
    (beads-list--update-mark-display)
    (beads-list--forward-after-mark)
    (message "%d marked" (length beads-list--marked))))

(defun beads-list-unmark-all ()
  "Unmark all marked issues."
  (interactive)
  (let ((count (length beads-list--marked)))
    (setq beads-list--marked nil)
    (beads-list--update-mark-display)
    (message "Unmarked %d issue%s" count (if (= count 1) "" "s"))))

(defun beads-list-toggle-marks ()
  "Toggle marks: marked become unmarked and vice versa."
  (interactive)
  (let ((all-ids (mapcar (lambda (issue) (alist-get 'id issue)) beads-list--issues)))
    (setq beads-list--marked
          (seq-filter (lambda (id) (not (member id beads-list--marked))) all-ids))
    (beads-list--update-mark-display)
    (message "%d marked" (length beads-list--marked))))

(defun beads-list-mark-regexp (regexp)
  "Mark all issues whose title matches REGEXP."
  (interactive "sMark issues matching (title): ")
  (let ((count 0))
    (dolist (issue beads-list--issues)
      (let ((id (alist-get 'id issue))
            (title (alist-get 'title issue "")))
        (when (string-match-p regexp title)
          (unless (member id beads-list--marked)
            (push id beads-list--marked)
            (setq count (1+ count))))))
    (beads-list--update-mark-display)
    (message "Marked %d issue%s (%d total)" count (if (= count 1) "" "s") (length beads-list--marked))))

(defun beads-list-toggle-marked-filter ()
  "Toggle display between all issues and only marked issues."
  (interactive)
  (if (null beads-list--marked)
      (message "No marked issues")
    (setq beads-list--show-only-marked (not beads-list--show-only-marked))
    (beads-list--refresh-current-view t)
    (message "%s" (if beads-list--show-only-marked
                      (format "Showing %d marked issue(s)" (length beads-list--marked))
                    "Showing all issues"))))

(defun beads-list--get-marked-or-at-point ()
  "Return list of marked issue IDs, or ID at point if none marked."
  (if beads-list--marked
      beads-list--marked
    (when-let ((id (beads-list--issue-id-at-point)))
      (list id))))

(cl-defun beads-list--bulk-try-then-loop (ids bulk-fn per-id-fn
                                              &key on-error-match)
  "Run BULK-FN on IDS as one CLI call; fall back to PER-ID-FN loop on error.

BULK-FN is called as (funcall BULK-FN IDS) — a single multi-ID CLI
invocation.  On success, returns a plist
  (:success N :errors 0 :matched-ids nil)
where N is (length IDS).

On `beads-client-error' from BULK-FN — including when the active
backend does not support the bulk operation (bdel-iin.4) — falls
back to calling (funcall PER-ID-FN ID) for each ID, accumulating
per-ID success and error counts so the user-visible messaging (e.g.
blocked-issue detection) matches the pre-batching behaviour.

When ON-ERROR-MATCH is a regexp, per-ID errors whose message matches
are collected into :matched-ids (used by `beads-list-bulk-close' to
list blocked issues).

Note: bd 1.0 multi-ID writes are not documented as transactional.
In practice, when some IDs fail bd exits 0 but writes an error to
stderr, which the backend's `call-process' call merges into stdout
and corrupts the JSON — so the helper sees `beads-client-error' and
falls back to the per-ID loop, yielding accurate per-issue counts.
For a full-success bulk call, the fast path is taken and all IDs
are reported as successful in a single subprocess.  close/delete
may surface `already closed' errors in the fallback for IDs that
succeeded before the partial bulk failure — these are counted as
errors."
  (condition-case nil
      (progn
        (funcall bulk-fn ids)
        (list :success (length ids) :errors 0 :matched-ids nil))
    (beads-client-error
     (let ((success 0) (errors 0) (matched nil))
       (dolist (id ids)
         (condition-case err
             (progn (funcall per-id-fn id) (cl-incf success))
           (beads-client-error
            (cl-incf errors)
            (when (and on-error-match
                       (string-match-p on-error-match
                                       (error-message-string err)))
              (push id matched)))))
       (list :success success :errors errors :matched-ids matched)))))

(defun beads-list-bulk-status (status)
  "Set STATUS for all marked issues (or issue at point if none marked)."
  (interactive
   (list (completing-read "Status: " '("open" "in_progress" "blocked" "hooked" "closed") nil t)))
  (let ((ids (beads-list--get-marked-or-at-point)))
    (unless ids
      (user-error "No issues marked or at point"))
    (let* ((result (beads-list--bulk-try-then-loop
                    ids
                    (lambda (ids) (beads-client-update-bulk ids :status status))
                    (lambda (id)  (beads-client-update id :status status))))
           (count (plist-get result :success))
           (errors (plist-get result :errors)))
      (beads-list--refresh-current-view t)
      (if (> errors 0)
          (message "Updated %d issue(s), %d error(s)" count errors)
        (message "Updated %d issue(s) to %s" count status)))))

(defun beads-list-bulk-priority (priority)
  "Set PRIORITY for all marked issues (or issue at point if none marked)."
  (interactive
   (let ((choice (completing-read "Priority: " '("P0" "P1" "P2" "P3" "P4") nil t)))
     (list (string-to-number (substring choice 1)))))
  (let ((ids (beads-list--get-marked-or-at-point)))
    (unless ids
      (user-error "No issues marked or at point"))
    (let* ((result (beads-list--bulk-try-then-loop
                    ids
                    (lambda (ids) (beads-client-update-bulk ids :priority priority))
                    (lambda (id)  (beads-client-update id :priority priority))))
           (count (plist-get result :success))
           (errors (plist-get result :errors)))
      (beads-list--refresh-current-view t)
      (if (> errors 0)
          (message "Updated %d issue(s), %d error(s)" count errors)
        (message "Updated %d issue(s) to P%d" count priority)))))

(defun beads-list-bulk-close ()
  "Close all marked issues (or issue at point if none marked)."
  (interactive)
  (let ((ids (beads-list--get-marked-or-at-point)))
    (unless ids
      (user-error "No issues marked or at point"))
    (when (or (= (length ids) 1)
              (yes-or-no-p (format "Close %d issues? " (length ids))))
      (let* ((result (beads-list--bulk-try-then-loop
                      ids
                      (lambda (ids) (beads-client-close-bulk ids))
                      (lambda (id)  (beads-client-close id))
                      :on-error-match "\\(blocker\\|blocked\\|open depend\\)"))
             (count (plist-get result :success))
             (errors (plist-get result :errors))
             (blocked-ids (plist-get result :matched-ids)))
        (setq beads-list--marked nil)
        (beads-list--refresh-current-view t)
        (cond
         (blocked-ids
          (message "Closed %d issue(s), %d blocked (press H on issue to view blockers)"
                   count (length blocked-ids)))
         ((> errors 0)
          (message "Closed %d issue(s), %d error(s)" count errors))
         (t
          (message "Closed %d issue(s)" count)))))))

(defun beads-list-bulk-delete ()
  "Delete all marked issues (or issue at point if none marked).
Prompts for confirmation."
  (interactive)
  (let ((ids (beads-list--get-marked-or-at-point)))
    (unless ids
      (user-error "No issues marked or at point"))
    (when (yes-or-no-p (format "DELETE %d issue(s)? This cannot be undone! " (length ids)))
      ;; `beads-client-delete' already takes a list of IDs and passes them
      ;; positionally to `bd delete [id...]' in a single subprocess, so the
      ;; fast path is just one call.  We still fall back on error so the
      ;; count reflects per-ID successes when bd rejects some IDs.
      (let* ((result (beads-list--bulk-try-then-loop
                      ids
                      (lambda (ids) (beads-client-delete ids))
                      (lambda (id)  (beads-client-delete (list id)))))
             (count (plist-get result :success))
             (errors (plist-get result :errors)))
        (setq beads-list--marked nil)
        (beads-list--refresh-current-view t)
        (if (> errors 0)
            (message "Deleted %d issue(s), %d error(s)" count errors)
          (message "Deleted %d issue(s)" count))))))

(defun beads-list--collect-assignees ()
  "Collect unique assignees from current issue list."
  (let ((assignees nil))
    (dolist (issue beads-list--issues)
      (when-let ((assignee (alist-get 'assignee issue)))
        (unless (or (string-empty-p assignee)
                    (member assignee assignees))
          (push assignee assignees))))
    (sort assignees #'string<)))

(defun beads-list--collect-types ()
  "Collect unique issue types from current issue list."
  (let ((types nil))
    (dolist (issue beads-list--issues)
      (when-let ((type (alist-get 'issue_type issue)))
        (unless (or (string-empty-p type)
                    (member type types))
          (push type types))))
    (sort types #'string<)))

(defun beads-list-available-types ()
  "Return list of available issue types.
Combines types from daemon with any custom types found in current issues."
  (let ((daemon-types (beads-get-types))
        (custom-types (beads-list--collect-types)))
    (sort (seq-uniq (append daemon-types custom-types)) #'string<)))

(defun beads-list-quick-assign (assignee)
  "Assign ASSIGNEE to marked issues or issue at point.
With completion for known assignees from current issues."
  (interactive
   (let* ((known (beads-list--collect-assignees))
          (user (or (getenv "USER") (getenv "USERNAME") "me"))
          (choices (delete-dups (cons user known))))
     (list (completing-read "Assign to: " choices nil nil))))
  (let ((ids (beads-list--get-marked-or-at-point)))
    (unless ids
      (user-error "No issues marked or at point"))
    (let* ((result (beads-list--bulk-try-then-loop
                    ids
                    (lambda (ids) (beads-client-update-bulk ids :assignee assignee))
                    (lambda (id)  (beads-client-update id :assignee assignee))))
           (count (plist-get result :success))
           (errors (plist-get result :errors)))
      (setq beads-list--marked nil)
      (beads-list--refresh-current-view t)
      (if (> errors 0)
          (message "Assigned %d issue(s) to %s, %d error(s)" count assignee errors)
        (message "Assigned %d issue(s) to %s" count assignee)))))

(defun beads-list-assign-to-me ()
  "Assign marked issues or issue at point to current user."
  (interactive)
  (let ((user (or (getenv "USER") (getenv "USERNAME") "me")))
    (beads-list-quick-assign user)))

(defun beads-list-goto-issue ()
  "Navigate to or display details for issue at point.

Cache hit (full issue already cached): renders immediately with no
subprocess call.  Cache miss: renders the partial list-level data
immediately, then asynchronously fetches the full issue and
re-renders the detail buffer when the data arrives."
  (interactive)
  (if-let ((issue (beads-list--get-issue-at-point)))
      (beads-core-open-issue-detail issue)
    (message "No issue at point")))

(defun beads-list-edit-form ()
  "Open form editor for issue at point."
  (interactive)
  (if-let ((issue (beads-list--get-issue-at-point)))
      (condition-case err
          (let ((id (alist-get 'id issue)))
            (let ((full-issue (beads-cache-show id)))
              (require 'beads-form)
              (beads-form-open full-issue)))
        (beads-client-error
         (message "Failed to fetch issue: %s" (error-message-string err))))
    (message "No issue at point")))

(defun beads-list-edit-title ()
  "Edit title of issue at point."
  (interactive)
  (if-let ((issue (beads-list--get-issue-at-point)))
      (let ((id (alist-get 'id issue))
            (title (alist-get 'title issue)))
        (require 'beads-edit)
        (when (beads-edit-field-minibuffer id :title title "Title: ")
          (beads-list--refresh-current-view)))
    (message "No issue at point")))

(defun beads-list-edit-status ()
  "Edit status of issue at point."
  (interactive)
  (if-let ((issue (beads-list--get-issue-at-point)))
      (let ((id (alist-get 'id issue))
            (status (alist-get 'status issue)))
        (require 'beads-edit)
        (when (beads-edit-field-completing
               id :status status "Status: "
               '("open" "in_progress" "blocked" "hooked" "closed"))
          (beads-list--refresh-current-view)))
    (message "No issue at point")))

(defun beads-list-edit-priority ()
  "Edit priority of issue at point."
  (interactive)
  (if-let ((issue (beads-list--get-issue-at-point)))
      (let* ((id (alist-get 'id issue))
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
                    (beads-list--refresh-current-view))
                (beads-client-error
                 (message "Failed to update: %s" (error-message-string err))))))))
    (message "No issue at point")))

(defun beads-list-edit-type ()
  "Edit type of issue at point."
  (interactive)
  (if-let ((issue (beads-list--get-issue-at-point)))
      (let ((id (alist-get 'id issue))
            (type (alist-get 'issue_type issue)))
        (require 'beads-edit)
        (when (beads-edit-field-completing
               id :issue-type type "Type: "
               (beads-get-types))
          (beads-list--refresh-current-view)))
    (message "No issue at point")))

(defun beads-list-edit-description ()
  "Edit description of issue at point."
  (interactive)
  (if-let ((issue (beads-list--get-issue-at-point)))
      (condition-case err
          (let* ((id (alist-get 'id issue))
                 (full-issue (beads-cache-show id))
                 (description (alist-get 'description full-issue)))
            (require 'beads-edit)
            (beads-edit-field-markdown id :description description))
        (beads-client-error
         (message "Failed to fetch issue: %s" (error-message-string err))))
    (message "No issue at point")))

(defun beads-org-list-hierarchy-show ()
  "Display dependency tree for the org list issue at point."
  (interactive)
  (if-let ((issue (beads-list--get-issue-at-point)))
      (beads-hierarchy-show (alist-get 'id issue))
    (message "No issue at point")))

(defun beads-org-list-delete-issue ()
  "Permanently delete the org list issue at point.
Prompts for confirmation with `yes-or-no-p'."
  (interactive)
  (if-let ((issue (beads-list--get-issue-at-point)))
      (let* ((id (alist-get 'id issue))
             (title (alist-get 'title issue))
             (display-title (if (and title (> (length title) 30))
                                (concat (substring title 0 27) "...")
                              (or title "")))
             (prompt (if (string-empty-p display-title)
                         (format "Permanently delete issue %s? " id)
                       (format "Permanently delete '%s' (%s)? " display-title id))))
        (when (yes-or-no-p prompt)
          (condition-case err
              (progn
                (beads-client-delete (list id))
                (message "Deleted issue %s" id)
                (beads-org-list-refresh))
            (beads-client-error
             (message "Failed to delete issue: %s" (error-message-string err))))))
    (message "No issue at point")))

(defun beads-org-list-reopen-issue ()
  "Reopen the org list issue at point."
  (interactive)
  (if-let ((issue (beads-list--get-issue-at-point)))
      (let ((id (alist-get 'id issue)))
        (condition-case err
            (progn
              (beads-client-update id :status "open")
              (message "Reopened issue %s" id)
              (beads-org-list-refresh))
          (beads-client-error
           (message "Failed to reopen issue: %s" (error-message-string err)))))
    (message "No issue at point")))

(defun beads-org-list--buffer-name (&optional project-root)
  "Return the buffer name for the org list in PROJECT-ROOT.

When another org list buffer already uses the display name for a
different beads project, include the abbreviated project path so both
projects can stay open in the same Emacs session."
  (let* ((root (and project-root (file-name-as-directory project-root)))
         (base-name (if root
                        (format "*Beads Org: %s*"
                                (file-name-nondirectory
                                 (directory-file-name root)))
                      "*Beads Org Issues*"))
         (existing (and root (get-buffer base-name))))
    (or (when root
          (cl-loop for buffer in (buffer-list)
                   when (with-current-buffer buffer
                          (and (derived-mode-p 'beads-org-list-mode)
                               (equal beads-org-list--project-root root)))
                   return (buffer-name buffer)))
        (if (and existing
                 (with-current-buffer existing
                   (and (local-variable-p 'beads-org-list--project-root)
                        beads-org-list--project-root
                        (not (equal beads-org-list--project-root root)))))
            (format "*Beads Org: %s <%s>*"
                    (file-name-nondirectory (directory-file-name root))
                    (abbreviate-file-name (directory-file-name root)))
          base-name))))

;;;###autoload
(defun beads-org-list ()
  "Open the org-mode Beads issue list buffer.

The buffer is generated from Beads data for the current project and does
not visit an org file on disk.  This is also the default view opened by
`beads-list'.  Use `beads-list-legacy' for the old tabulated-list UI."
  (interactive)
  (let* ((project-root (file-name-as-directory
                        (or (beads-client--project-root)
                            (and (featurep 'beads-project)
                                 (beads-project-root))
                            default-directory)))
         (per-project-buffers (or (not (boundp 'beads-project-per-project-buffers))
                                  (bound-and-true-p beads-project-per-project-buffers)))
         (buffer-name (beads-org-list--buffer-name
                       (and per-project-buffers project-root)))
         (buffer (get-buffer-create buffer-name)))
    (with-current-buffer buffer
      (unless (eq major-mode 'beads-org-list-mode)
        (beads-org-list-mode))
      (setq beads-org-list--project-root project-root)
      (setq beads-list--project-root project-root)
      ;; Pin default-directory to the project root so generated org
      ;; refreshes do not depend on the caller's current buffer or any
      ;; org file path.
      (setq default-directory project-root)
      (beads-org-list-refresh))
    (switch-to-buffer buffer)))

;;;###autoload
(defun beads-list ()
  "Open the default org-mode Beads issue list buffer.

The list is a generated org task/tree view.  Use `beads-list-legacy' to
open the old tabulated-list UI during the transition."
  (interactive)
  (beads-org-list))

;;;###autoload
(defun beads-list-legacy ()
  "Open the legacy tabulated Beads issue list buffer.

If beads-project.el is loaded and per-project buffers are enabled,
creates a project-specific buffer.

Pins `default-directory' in the resulting buffer to the project root so
that subsequent refreshes always resolve to the correct beads database,
even when multiple projects are open simultaneously."
  (interactive)
  (let* ((buffer-name (if (featurep 'beads-project)
                          (beads-project-buffer-name)
                        "*Beads Issues*"))
         (buffer (get-buffer-create buffer-name))
         (project-root default-directory))
    (with-current-buffer buffer
      (unless (eq major-mode 'beads-list-mode)
        (beads-list-mode))
      (setq beads-list--project-root project-root)
      ;; Pin default-directory to the project root so client lookups
      ;; (which key off default-directory) always target this project,
      ;; regardless of which buffer the user was in when refresh fires.
      (setq default-directory project-root)
      (beads-list-refresh))
    (switch-to-buffer buffer)))

(provide 'beads-list)
;;; beads-list.el ends here
