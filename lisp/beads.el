;;; beads.el --- Emacs client for Beads issue tracker -*- lexical-binding: t -*-

;; Copyright (C) 2025 Christian Tietze

;; Author: Christian Tietze
;; Version: 0.1.0
;; Package-Requires: ((emacs "28.1") (transient "0.4.0") (vui "0.1.0"))
;; Keywords: tools, project, ui, widget
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
;; The client automatically discovers the Beads database by walking up from
;; `default-directory` looking for `.beads/beads.db`.  Multiple CLI backends
;; are supported (bd, br) and auto-detected per project; see
;; `beads-cli-program'.
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

;;;###autoload
(defun beads ()
  "Open the Beads issue tracker."
  (interactive)
  (beads-list))

(provide 'beads)
;;; beads.el ends here
