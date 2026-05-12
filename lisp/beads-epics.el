;;; beads-epics.el --- Epic status view for Beads -*- lexical-binding: t -*-

;; Copyright (C) 2026 Peter Jun Koh

;; Author: Peter Jun Koh
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

;; Interactive buffer for viewing epic completion status, mirroring the
;; output of the `bd epic status' CLI command.  Shows all non-closed
;; epics that have at least one child issue, along with their progress
;; (closed_children / total_children) and an `eligible_for_close' marker
;; for epics whose children are all closed.
;;
;; When the Dolt SQL transport is enabled, the data is fetched directly
;; via SQL; otherwise it falls back to invoking `bd epic status --json'.

;;; Code:

(require 'beads-core)
(require 'beads-client)

(defvar-local beads-epics--data nil
  "List of epic-status entries in current buffer.")

(defvar-local beads-epics--eligible-only nil
  "Non-nil when the buffer is filtered to eligible-for-close epics only.")

(defvar beads-epics-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "RET") #'beads-epics-goto-issue)
    (define-key map (kbd "g") #'beads-epics-refresh)
    (define-key map (kbd "f") #'beads-epics-toggle-eligible-only)
    (define-key map (kbd "q") #'quit-window)
    map)
  "Keymap for beads-epics-mode.")

(define-derived-mode beads-epics-mode special-mode "Beads-Epics"
  "Major mode for viewing Beads epic completion status.

Mirrors `bd epic status': displays all non-closed epics that have at
least one child, with progress and eligibility for closure.

\\{beads-epics-mode-map}"
  (setq buffer-read-only t))

(defun beads-epics--fetch (&optional eligible-only)
  "Fetch epic status entries.
When ELIGIBLE-ONLY is non-nil, return only epics where all children
are closed."
  (beads-client-epic-status eligible-only))

(defun beads-epics--eligible-p (entry)
  "Return non-nil if epic ENTRY is eligible for closure.
Accepts JSON-true encoded as `t' or `:json-true', and integer 1, to
interoperate with both the bd CLI backend and the direct Dolt SQL
backend regardless of which JSON parser settings are in effect."
  (let ((val (alist-get 'eligible_for_close entry)))
    (cond
     ((eq val t) t)
     ((eq val :json-true) t)
     ((eq val :json-false) nil)
     ((null val) nil)
     ((numberp val) (> val 0))
     (t nil))))

(defun beads-epics--progress-bar (closed total &optional width)
  "Build a unicode progress bar showing CLOSED of TOTAL.
WIDTH is the bar width in characters (default 10)."
  (let* ((width (or width 10))
         (ratio (if (> total 0) (/ (float closed) total) 0.0))
         (filled (round (* ratio width)))
         (empty (- width filled)))
    (concat (make-string filled ?█)
            (make-string empty ?░))))

(defun beads-epics--render (entries)
  "Render epic status ENTRIES into current buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (beads-core-render-header
     "Epic Status"
     (if beads-epics--eligible-only
         "Epics eligible for closure (all children closed)"
       "Non-closed epics with at least one child issue")
     "RET=view  f=toggle eligible-only  g=refresh  q=quit"
     70)
    (if (null entries)
        (insert (if beads-epics--eligible-only
                    "No epics are currently eligible for closure.\n"
                  "No epics found.\n"))
      (dolist (entry entries)
        (let* ((epic (alist-get 'epic entry))
               (id (alist-get 'id epic))
               (title (alist-get 'title epic ""))
               (status (alist-get 'status epic ""))
               (total (or (alist-get 'total_children entry) 0))
               (closed (or (alist-get 'closed_children entry) 0))
               (eligible (beads-epics--eligible-p entry))
               (pct (if (> total 0)
                        (round (* 100 (/ (float closed) total)))
                      0))
               (marker (cond
                        (eligible (propertize "✓" 'face 'success))
                        ((string= status "in_progress")
                         (propertize "◐" 'face 'warning))
                        (t (propertize "○" 'face 'shadow))))
               (start (point)))
          (insert marker " ")
          (insert (propertize id 'face 'bold))
          (insert " ")
          (insert title)
          (insert "\n")
          (insert (format "    Progress: %s %d/%d children closed (%d%%)"
                          (beads-epics--progress-bar closed total)
                          closed total pct))
          (when eligible
            (insert (propertize "  ELIGIBLE FOR CLOSURE" 'face 'success)))
          (insert "\n\n")
          (put-text-property start (point) 'beads-epic-id id)
          (put-text-property start (point) 'beads-epic-data entry))))))

;;;###autoload
(defun beads-epics (&optional eligible-only)
  "Display epic completion status in an interactive buffer.
With prefix argument or non-nil ELIGIBLE-ONLY, show only epics
whose children are all closed (eligible for closure)."
  (interactive "P")
  (condition-case err
      (let ((entries (beads-epics--fetch eligible-only)))
        (with-current-buffer (get-buffer-create "*Beads Epics*")
          (beads-epics-mode)
          (setq beads-epics--eligible-only (and eligible-only t))
          (setq beads-epics--data entries)
          (beads-epics--render entries)
          (goto-char (point-min))
          (pop-to-buffer (current-buffer)
                         '((display-buffer-reuse-window
                            display-buffer-in-side-window)
                           (side . bottom)
                           (window-height . fit-window-to-buffer)))
          (beads-show-hint)))
    (error
     (message "Failed to fetch epic status: %s"
              (error-message-string err)))))

(defun beads-epics--id-at-point ()
  "Return epic issue ID at point, or nil."
  (beads-core-id-at-point 'beads-epic-id))

(defun beads-epics-goto-issue ()
  "Open the epic at point in detail view."
  (interactive)
  (beads-core-goto-issue-at-point 'beads-epic-id))

(defun beads-epics-refresh ()
  "Refresh the epic status list."
  (interactive)
  (unless (derived-mode-p 'beads-epics-mode)
    (user-error "Not in beads-epics-mode"))
  (condition-case err
      (let ((entries (beads-epics--fetch beads-epics--eligible-only)))
        (setq beads-epics--data entries)
        (let ((saved-point (point)))
          (beads-epics--render entries)
          (goto-char (min saved-point (point-max))))
        (message "Refreshed epic status"))
    (error
     (message "Failed to refresh epic status: %s"
              (error-message-string err)))))

(defun beads-epics-toggle-eligible-only ()
  "Toggle the eligible-only filter and refresh."
  (interactive)
  (unless (derived-mode-p 'beads-epics-mode)
    (user-error "Not in beads-epics-mode"))
  (setq beads-epics--eligible-only (not beads-epics--eligible-only))
  (beads-epics-refresh))

(provide 'beads-epics)
;;; beads-epics.el ends here
