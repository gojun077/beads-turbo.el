;;; beads-list-model.el --- Pure list model helpers for Beads -*- lexical-binding: t -*-

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

;; Pure helpers for shaping beads issue lists before rendering.  This
;; module intentionally does not require the client or tabulated-list so
;; table and org renderers can share filtering, sorting, stats, lookup,
;; and parent-child tree assembly without a live bd process.

;;; Code:

(require 'beads-filter)
(require 'cl-lib)
(require 'seq)

(cl-defstruct (beads-list-model
               (:constructor beads-list-model--make))
  "Data prepared from a flat list of Beads issues.

`issues' is the filtered issue set before marked-only filtering.
`display-issues' is the issue set after marked-only filtering and
optional sectioned sorting.  `stats' always describes the original
unfiltered input so the list header keeps showing project-level counts."
  all-issues issues display-issues stats)

(defun beads-list-model-compute-stats (issues)
  "Compute stats alist from ISSUES list.

Returns an alist with `total_issues', `open_issues',
`in_progress_issues', `blocked_issues', `closed_issues' and
`ready_issues'.

Open issues with positive `dependency_count' count as blocked rather
than ready, matching the existing list-mode status summary."
  (let ((total (length issues))
        (open 0) (in-progress 0) (blocked 0)
        (closed 0) (ready 0))
    (dolist (issue issues)
      (let ((status (alist-get 'status issue))
            (dep-count (or (alist-get 'dependency_count issue) 0)))
        (pcase status
          ("open"
           (cl-incf open)
           (if (> dep-count 0)
               (cl-incf blocked)
             (cl-incf ready)))
          ("in_progress" (cl-incf in-progress))
          ("blocked" (cl-incf blocked))
          ("closed" (cl-incf closed)))))
    `((total_issues . ,total)
      (open_issues . ,open)
      (in_progress_issues . ,in-progress)
      (blocked_issues . ,blocked)
      (closed_issues . ,closed)
      (ready_issues . ,ready))))

(defun beads-list-model-apply-filter (issues filter)
  "Return ISSUES after applying FILTER.
When FILTER is nil, return ISSUES unchanged."
  (if filter
      (beads-filter-apply filter issues)
    issues))

(defun beads-list-model-apply-marked-only (issues marked-ids show-only-marked)
  "Return ISSUES filtered to MARKED-IDS when SHOW-ONLY-MARKED is non-nil."
  (if show-only-marked
      (seq-filter (lambda (issue)
                    (member (alist-get 'id issue) marked-ids))
                  issues)
    issues))

(defun beads-list-model-issue-section (issue)
  "Return section number for ISSUE: 0=ready/open, 1=blocked, 2=closed.

Open issues with positive `dependency_count' are treated as blocked,
matching `beads-list-model-compute-stats'."
  (let ((status (alist-get 'status issue))
        (dep-count (or (alist-get 'dependency_count issue) 0)))
    (cond
     ((string= status "closed") 2)
     ((or (string= status "blocked")
          (> dep-count 0))
      1)
     (t 0))))

(defun beads-list-model-sectioned-sort (issues)
  "Sort ISSUES into unblocked, blocked, and closed sections.
ISSUES can be a list or vector.  Within unblocked and blocked
sections, sort by priority ascending, with in-progress issues first
in the unblocked section.  Within the closed section, sort by
`closed_at' descending."
  (let ((unblocked nil)
        (blocked nil)
        (closed nil))
    (seq-doseq (issue issues)
      (pcase (beads-list-model-issue-section issue)
        (0 (push issue unblocked))
        (1 (push issue blocked))
        (2 (push issue closed))))
    (setq unblocked (sort unblocked
                          (lambda (a b)
                            (let ((status-a (alist-get 'status a))
                                  (status-b (alist-get 'status b))
                                  (prio-a (alist-get 'priority a 2))
                                  (prio-b (alist-get 'priority b 2)))
                              (cond
                               ((and (string= status-a "in_progress")
                                     (not (string= status-b "in_progress")))
                                t)
                               ((and (not (string= status-a "in_progress"))
                                     (string= status-b "in_progress"))
                                nil)
                               (t (< prio-a prio-b)))))))
    (setq blocked (sort blocked
                        (lambda (a b)
                          (< (alist-get 'priority a 2)
                             (alist-get 'priority b 2)))))
    (setq closed (sort closed
                       (lambda (a b)
                         (let ((date-a (or (alist-get 'closed_at a) ""))
                               (date-b (or (alist-get 'closed_at b) "")))
                           (string> date-a date-b)))))
    (append unblocked blocked closed)))

(cl-defun beads-list-model-build (all-issues &key filter marked-ids
                                             show-only-marked sort-mode)
  "Build a pure list model from ALL-ISSUES.
FILTER is a `beads-filter' object or nil.  MARKED-IDS and
SHOW-ONLY-MARKED control marked-only filtering.  SORT-MODE may be
`sectioned' to apply sectioned list sorting; any other value leaves
display order unchanged."
  (let* ((issues (beads-list-model-apply-filter all-issues filter))
         (display-issues (beads-list-model-apply-marked-only
                          issues marked-ids show-only-marked))
         (display-issues (if (eq sort-mode 'sectioned)
                             (beads-list-model-sectioned-sort display-issues)
                           display-issues)))
    (beads-list-model--make
     :all-issues all-issues
     :issues (append issues nil)
     :display-issues display-issues
     :stats (beads-list-model-compute-stats all-issues))))

(defun beads-list-model-find-by-id (issues id)
  "Return the issue in ISSUES whose `id' equals ID, or nil."
  (seq-find (lambda (issue)
              (equal (alist-get 'id issue) id))
            issues))

(defun beads-list-model-parent-id (issue)
  "Return ISSUE's normalized parent id, or nil.
The explicit `parent' field wins over `parent_id', matching the org
property contract.  Empty strings are treated as no parent."
  (let ((parent (or (alist-get 'parent issue)
                    (alist-get 'parent_id issue))))
    (unless (or (null parent)
                (and (stringp parent) (string= parent "")))
      parent)))

(defun beads-list-model--forest-node (issue)
  "Return a mutable forest node for ISSUE."
  (list (cons 'issue issue) (cons 'children nil)))

(defun beads-list-model--node-issue (node)
  "Return NODE's issue alist."
  (alist-get 'issue node))

(defun beads-list-model--node-children-cell (node)
  "Return NODE's children cons cell."
  (assq 'children node))

(defun beads-list-model--ancestor-p (candidate-id node by-id)
  "Return non-nil if CANDIDATE-ID is NODE or one of NODE's parents."
  (let ((seen nil)
        (current node)
        found)
    (while (and current (not found))
      (let* ((issue (beads-list-model--node-issue current))
             (id (alist-get 'id issue))
             (parent-id (beads-list-model-parent-id issue)))
        (cond
         ((equal candidate-id id)
          (setq found t))
         ((or (null parent-id) (member id seen))
          (setq current nil))
         (t
          (push id seen)
          (setq current (gethash parent-id by-id))))))
    found))

(defun beads-list-model-flat-issues-to-forest (issues)
  "Return a parent-child forest built from flat ISSUES.

Each returned node is an alist of the shape `((issue . ISSUE)
(children . NODES))'.  Parent ids are read via
`beads-list-model-parent-id', so both `parent' and `parent_id' input
metadata are supported.  Missing parents are deterministic roots and
their original parent metadata is preserved on the issue.

Duplicate issue ids are ignored after their first occurrence, so each
id appears at most once in the output.  If a parent cycle is detected,
the affected issue is kept as a root instead of being linked twice."
  (let ((by-id (make-hash-table :test #'equal))
        nodes roots)
    (seq-doseq (issue issues)
      (let ((id (alist-get 'id issue)))
        (when (and id (not (gethash id by-id)))
          (let ((node (beads-list-model--forest-node issue)))
            (puthash id node by-id)
            (push node nodes)))))
    (setq nodes (nreverse nodes))
    (dolist (node nodes)
      (let* ((issue (beads-list-model--node-issue node))
             (id (alist-get 'id issue))
             (parent-id (beads-list-model-parent-id issue))
             (parent (and parent-id (gethash parent-id by-id))))
        (if (and parent
                 (not (equal parent-id id))
                 (not (beads-list-model--ancestor-p id parent by-id)))
            (let ((children-cell (beads-list-model--node-children-cell parent)))
              (setcdr children-cell (append (cdr children-cell) (list node))))
          (push node roots))))
    (nreverse roots)))

(provide 'beads-list-model)
;;; beads-list-model.el ends here
