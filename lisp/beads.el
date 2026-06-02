;;; beads.el --- Emacs client for Beads issue tracker -*- lexical-binding: t -*-

;; Copyright (C) 2025 Christian Tietze

;; Author: Christian Tietze
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (transient "0.4.0") (vui "0.1.0"))
;; Keywords: tools, project, ui
;; URL: https://codeberg.org/ctietze/beads.el

;; This file is NOT part of GNU Emacs.

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

;; beads.el provides an Emacs interface to the Beads issue tracking system.
;; Beads is a Git-backed, AI-native issue tracker that stores data in `.beads/`
;; and communicates via CLI commands.
;;
;; Usage:
;;   M-x beads  - Open the Beads issue list
;;
;; The client automatically discovers the Beads project by walking up from
;; `default-directory` looking for `.beads/metadata.json`.
;;
;; You can use beads.el on multiple projects at the same time.
;;
;; Make sure to try:
;;
;; - Transient menu to discover all user-facing functions, including
;;   the various ways to edit parts of an issue, or the whole issue
;;   at once in a form.
;; - Preview mode, where you can 'peek' at issue details as you move
;;   point in the list.

;;; Code:

(require 'subr-x)
(require 'vui)

(defgroup beads nil
  "Beads issue tracker."
  :group 'tools
  :prefix "beads-")

(require 'beads-core)

(require 'beads-client)
(require 'beads-backend-dolt-sql)
(require 'beads-list)
(require 'beads-detail)
(require 'beads-transient)
(require 'beads-project)

(autoload 'beads-hierarchy-show "beads-hierarchy" "Display dependency tree." t)
(autoload 'beads-backend-dolt-sql-activate "beads-backend-dolt-sql"
  "Activate Dolt SQL transport for the current Emacs session." t)
(autoload 'beads-backend-dolt-sql-deactivate "beads-backend-dolt-sql"
  "Deactivate Dolt SQL transport, reverting to bd CLI for all operations." t)

(defconst beads-about--buffer-name "*Beads Turbo About*"
  "Name of the Beads Turbo about buffer.")

(defconst beads-about--ascii-art
  "            ____________/  __                     __
           ____________/  / /_  ___  ____ _____ _/ /____
          ____________/  / __ \\/ _ \\/ __ `/ __ `/ / ___/
         ____________/  / /_/ /  __/ /_/ / /_/ / (__  )
        ____________/  /_.___/\\___/\\__,_/\\__,_/_/____/
       ____________/  / / / / / / / / / / / / / / / /
      ____________/ ________  ______  ____  ____            __
     ____________/ /_  __/ / / / __ \\/ __ )/ __ \\     ___  / /
    ____________/   / / / / / / /_/ / __  / / / /    / _ \\/ /
   ____________/   / / / /_/ / _, _/ /_/ / /_/ / _  /  __/ /
  ____________/   /_/  \\____/_/ |_/_____/\\____/ (_) \\___/_/
                  / / / / / / / / / / / / / / / / / / /
                (O) (O) (O) (O) (O) (O) (O) (O) (O) (O)"
  "ASCII art displayed by `beads-about'.")

(defun beads-about--source-file ()
  "Return the loaded Beads source file, or nil if it cannot be found."
  (locate-library "beads"))

(defun beads-about--git-root ()
  "Return the Git root for the loaded Beads source, or nil if unavailable."
  (when-let* ((source (beads-about--source-file)))
    (locate-dominating-file source ".git")))

(defun beads-about--process-output (program &rest args)
  "Run PROGRAM with ARGS and return trimmed stdout, or nil on failure."
  (when (executable-find program)
    (with-temp-buffer
      (when (zerop (apply #'process-file program nil t nil args))
        (let ((output (string-trim (buffer-string))))
          (unless (string-empty-p output)
            output))))))

(defun beads-about--git-output (&rest args)
  "Run Git with ARGS in the Beads source checkout."
  (when-let* ((root (beads-about--git-root)))
    (apply #'beads-about--process-output "git" "-C" root args)))

(defun beads-about--insert-field (label value)
  "Insert an about buffer field named LABEL with VALUE."
  (insert (format "%-19s %s\n" (concat label ":") (or value "unknown"))))

;;;###autoload
(defun beads-about ()
  "Display version and source information for Beads Turbo."
  (interactive)
  (let ((buffer (get-buffer-create beads-about--buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert beads-about--ascii-art "\n\n")
        (insert "beads-turbo.el\n\n")
        (beads-about--insert-field "Package version" beads-client-version)
        (beads-about--insert-field
         "Git tag"
         (beads-about--git-output "describe" "--tags" "--always" "--dirty"))
        (beads-about--insert-field
         "Commit"
         (beads-about--git-output "rev-parse" "--short" "HEAD"))
        (beads-about--insert-field
         "Commit date"
         (beads-about--git-output "log" "-1" "--format=%cs"))
        (beads-about--insert-field "Loaded from" (beads-about--source-file))
        (beads-about--insert-field
         "bd version"
         (car (split-string (or (beads-about--process-output "bd" "--version") "")
                            "\n" t)))
        (beads-about--insert-field
         "Dolt SQL read path"
         (if (bound-and-true-p beads-dolt-sql-enabled) "enabled" "disabled"))
        (beads-about--insert-field
         "Project database"
         (or (ignore-errors (beads-client--find-database))
             "not found from current directory")))
      (goto-char (point-min))
      (special-mode))
    (pop-to-buffer buffer)))

;;;###autoload
(defun beads ()
  "Open the Beads issue tracker."
  (interactive)
  (beads-list))

(provide 'beads)
;;; beads.el ends here
