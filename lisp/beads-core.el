;;; beads-core.el --- Shared utilities for Beads -*- lexical-binding: t -*-

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

;; Shared utilities for Beads report views and other modules.
;; Provides common patterns for:
;; - Buffer header rendering
;; - Issue navigation helpers
;; - CLI invocation wrappers
;; - Text property helpers

;;; Code:

(declare-function beads-detail-open "beads-detail")
(declare-function beads-detail-rerender-if-current "beads-detail")
(declare-function beads-cache-get-full-issue "beads-cache")
(declare-function beads-cache-put-full-issue "beads-cache")
(declare-function beads-client-show "beads-client")
(declare-function beads-client-show-async "beads-client")
(declare-function beads-backend-dolt-sql-stop-idle-session "beads-backend-dolt-sql")

(defcustom beads-verbose t
  "When non-nil, show helpful hints about keybindings in the minibuffer.
Hints are shown when entering beads modes to help with discoverability."
  :type 'boolean
  :group 'beads)

(defvar beads-hints-alist
  '((beads-org-list-mode
     . "? menu | RET open | e <key> edit | f <key> filter | E form | P preview | q quit")
    (beads-org-list-mode-preview
     . "↑↓ browse | RET open | e/E edit | P/q exit preview | ? menu")
    (beads-detail-vui-mode
     . "? menu | e <key> edit | E form | g refresh | q quit")
    (beads-form-vui-mode
     . "TAB next | C-c C-c save | C-c C-k cancel"))
  "Alist of mode symbols to hint strings.")

(defun beads-show-hint ()
  "Show hint for current major mode if `beads-verbose' is enabled."
  (when beads-verbose
    (let* ((mode-key (if (and (eq major-mode 'beads-org-list-mode)
                              (bound-and-true-p beads-preview-mode))
                         'beads-org-list-mode-preview
                       major-mode))
           (hint (alist-get mode-key beads-hints-alist)))
      (when hint
        (run-at-time 0.1 nil (lambda (h) (message h)) hint)))))

(defun beads-core-render-header (title description keybindings &optional separator-width)
  "Render a standard report header.
TITLE is displayed bold, DESCRIPTION and KEYBINDINGS in shadow face.
SEPARATOR-WIDTH defaults to 50."
  (let ((width (or separator-width 50)))
    (insert (propertize (concat title "\n") 'face 'bold))
    (insert (propertize (concat description "\n") 'face 'shadow))
    (insert (propertize (concat keybindings "\n") 'face 'shadow))
    (insert (make-string width ?=) "\n\n")))

(defun beads-core-id-at-point (property-name)
  "Return issue ID at point using PROPERTY-NAME.
PROPERTY-NAME should be a symbol like `beads-orphan-id'."
  (get-text-property (point) property-name))

(defun beads-core--issue-with-id (id issue)
  "Return ISSUE with ID in an `id' field.
When ISSUE is nil, return a minimal detail issue containing only ID."
  (cond
   ((null issue) `((id . ,id)))
   ((alist-get 'id issue nil nil #'equal) issue)
   (t (cons (cons 'id id) issue))))

(defun beads-core-open-issue-detail (issue-or-id)
  "Open ISSUE-OR-ID using the standard detail navigation flow.

This mirrors `beads-list-goto-issue': render available list/report data
immediately, then asynchronously hydrate the detail buffer with the full
issue record.  A cached full issue opens directly without an extra client
request."
  (require 'beads-cache)
  (require 'beads-client)
  (require 'beads-detail)
  (let* ((id (if (stringp issue-or-id)
                 issue-or-id
               (alist-get 'id issue-or-id nil nil #'equal)))
         (issue (if (stringp issue-or-id)
                    `((id . ,issue-or-id))
                  issue-or-id)))
    (unless id
      (user-error "No issue at point"))
    (if-let ((full-issue (beads-cache-get-full-issue id)))
        (beads-detail-open full-issue)
      (beads-detail-open issue)
      (condition-case err
          (beads-client-show-async
           id
           (lambda (err full-issue)
             (cond
              (err
               (message "Failed to fetch issue details: %s"
                        (error-message-string err)))
              (full-issue
               (beads-cache-put-full-issue id full-issue)
               (beads-detail-rerender-if-current id full-issue)))))
        (beads-client-error
         (message "Failed to fetch issue details: %s"
                  (error-message-string err)))))))

(defun beads-core-goto-issue-at-point (id-property &optional issue-property)
  "Open issue at point in detail view using ID-PROPERTY.
When ISSUE-PROPERTY is non-nil, use its value as the partial issue data
for the initial render."
  (let ((id (beads-core-id-at-point id-property)))
    (unless id
      (user-error "No issue at point"))
    (beads-core-open-issue-detail
     (beads-core--issue-with-id
      id
      (and issue-property (get-text-property (point) issue-property))))))

(defun beads-core-quit-window-kill-buffer ()
  "Quit the selected window and kill its buffer."
  (interactive)
  (quit-window t))

(defun beads-core--beads-buffer-p (&optional buffer)
  "Return non-nil when BUFFER is owned by beads.el."
  (with-current-buffer (or buffer (current-buffer))
    (or (string-prefix-p "beads-" (symbol-name major-mode))
        (bound-and-true-p beads-edit-mode))))

(defun beads-core--other-beads-buffer-live-p ()
  "Return non-nil when another live beads.el buffer exists."
  (let ((current (current-buffer))
        found)
    (dolist (buffer (buffer-list) found)
      (when (and (not (eq buffer current))
                 (buffer-live-p buffer)
                 (beads-core--beads-buffer-p buffer))
        (setq found t)))))

(defun beads-core--maybe-stop-idle-backend ()
  "Stop persistent backend sessions when the last beads.el buffer closes."
  (when (and (beads-core--beads-buffer-p)
             (not (beads-core--other-beads-buffer-live-p))
             (fboundp 'beads-backend-dolt-sql-stop-idle-session))
    (ignore-errors
      (beads-backend-dolt-sql-stop-idle-session))))

(add-hook 'kill-buffer-hook #'beads-core--maybe-stop-idle-backend)

(provide 'beads-core)
;;; beads-core.el ends here
