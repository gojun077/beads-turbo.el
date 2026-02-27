;;; beads-client.el --- Client layer for Beads issue tracker -*- lexical-binding: t -*-

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

;; Client layer for communicating with the Beads issue tracker.
;; Dispatches requests via CLI commands.

;;; Code:

(require 'json)
(require 'cl-lib)
(require 'seq)
(require 'beads-backend)

(defconst beads-client-version "0.1.0")

(define-error 'beads-client-error "Beads client error")

(defvar beads-client--cached-db-path nil)
(defvar beads-client--cache-time nil)
(defconst beads-client--cache-ttl 10)

(cl-defun beads-client--find-database ()
  "Find the Beads database path using auto-discovery.
Checks BEADS_DIR env, BEADS_DB env, then walks up from default-directory."
  (when (and beads-client--cached-db-path
             beads-client--cache-time
             (< (float-time (time-since beads-client--cache-time))
                beads-client--cache-ttl))
    (when (file-exists-p beads-client--cached-db-path)
      (cl-return-from beads-client--find-database beads-client--cached-db-path)))

  (let ((db-path
         (or
          (let ((beads-dir (getenv "BEADS_DIR")))
            (when beads-dir
              (setq beads-dir (expand-file-name beads-dir))
              (setq beads-dir (beads-client--follow-redirect beads-dir))
              (beads-client--find-db-in-dir beads-dir)))

          (let ((beads-db (getenv "BEADS_DB")))
            (when beads-db
              (expand-file-name beads-db)))

          (let ((dir (expand-file-name default-directory)))
            (while (and dir
                        (not (string= dir "/"))
                        (not (string= dir (expand-file-name "~/.."))))
              (let* ((beads-dir (expand-file-name ".beads" dir))
                     (redirected-dir (beads-client--follow-redirect beads-dir))
                     (db (beads-client--find-db-in-dir redirected-dir)))
                (when db
                  (cl-return-from beads-client--find-database
                                  (progn
                                    (setq beads-client--cached-db-path db)
                                    (setq beads-client--cache-time (current-time))
                                    db)))
                (setq dir (file-name-directory (directory-file-name dir)))))
            nil))))

    (when db-path
      (setq beads-client--cached-db-path db-path)
      (setq beads-client--cache-time (current-time)))

    db-path))

(defun beads-client--follow-redirect (beads-dir)
  "Follow redirect file if present in BEADS-DIR."
  (let ((redirect-file (expand-file-name "redirect" beads-dir)))
    (if (file-exists-p redirect-file)
        (with-temp-buffer
          (insert-file-contents redirect-file)
          (string-trim (buffer-string)))
      beads-dir)))

(defun beads-client--find-db-in-dir (beads-dir)
  "Find database file in BEADS-DIR."
  (when (file-directory-p beads-dir)
    (let ((default-db (expand-file-name "beads.db" beads-dir)))
      (if (file-exists-p default-db)
          default-db
        (let ((db-files (directory-files beads-dir t "\\.db\\'")))
          (cl-find-if (lambda (f)
                        (and (not (string-match-p "\\.backup" f))
                             (not (string-match-p "vc\\.db\\'" f))))
                      db-files))))))

(defun beads-client--project-root ()
  "Get the project root directory for the current Beads workspace.
This is the parent directory of .beads/."
  (when-let ((db-path (beads-client--find-database)))
    (file-name-directory
     (directory-file-name
      (file-name-directory db-path)))))

(defun beads-client-request (operation args)
  "Execute OPERATION with ARGS via CLI.
Returns the data on success, signals beads-client-error on failure."
  (let ((project-root (when-let ((db (beads-client--find-database)))
                        (file-name-directory
                         (directory-file-name
                          (file-name-directory db))))))
    (condition-case err
        (beads-backend-cli-execute operation args project-root)
      (beads-backend-error
       (signal 'beads-client-error (cdr err))))))

(defun beads-client-list (&optional filters)
  "List issues with optional FILTERS.
FILTERS is a plist with keys like :status, :priority, :issue-type, :assignee,
:labels, :limit, :title-contains, :parent (for epic-scoped views), etc.
Returns array of issue objects."
  (let ((args (beads-client--plist-to-alist filters)))
    (beads-client-request "list" args)))

(defun beads-client-show (id)
  "Get single issue by ID.
Returns issue object."
  (unless id
    (signal 'beads-client-error (list "Issue ID required")))
  (beads-client-request "show" `((id . ,id))))

(defun beads-client-ready (&optional filters)
  "Get unblocked issues with optional FILTERS.
FILTERS is a plist with keys like :assignee, :priority, :limit, :sort-policy,
:parent (for epic-scoped views).
Returns array of ready issue objects."
  (let ((args (beads-client--plist-to-alist filters)))
    (beads-client-request "ready" args)))

(defun beads-client-create (title &rest args)
  "Create new issue with TITLE and additional ARGS.
ARGS is a plist with keys like :description, :issue-type, :priority,
:assignee, :labels, :design, :acceptance-criteria, :dependencies, :parent,
and :dry-run.  When :dry-run is non-nil, returns a preview without creating.
Returns created (or previewed) issue object."
  (unless title
    (signal 'beads-client-error (list "Title required")))
  (let ((request-args (beads-client--plist-to-alist
                       (plist-put args :title title))))
    (beads-client-request "create" request-args)))

(defun beads-client-update (id &rest args)
  "Update issue ID with ARGS.
ARGS is a plist with keys like :title, :description, :status,
:priority, :assignee, :issue-type, :design, :notes, :add-labels,
:remove-labels, :set-labels.  Returns updated issue object."
  (unless id
    (signal 'beads-client-error (list "Issue ID required")))
  (let ((request-args (beads-client--plist-to-alist
                       (plist-put args :id id))))
    (beads-client-request "update" request-args)))

(defun beads-client-close (id &optional reason)
  "Close issue ID with optional REASON.
Returns closed issue object."
  (unless id
    (signal 'beads-client-error (list "Issue ID required")))
  (let ((args `((id . ,id))))
    (when reason
      (push `(reason . ,reason) args))
    (beads-client-request "close" args)))

(defun beads-client-delete (ids &rest args)
  "Delete issues by IDS (list of issue IDs) with optional ARGS.
ARGS is a plist with keys like :force, :cascade, :reason.
Returns deletion result."
  (unless ids
    (signal 'beads-client-error (list "Issue IDs required")))
  (let ((request-args (beads-client--plist-to-alist
                       (plist-put args :ids ids))))
    (beads-client-request "delete" request-args)))

(defun beads-client-stats ()
  "Get issue statistics.
Returns stats object with counts and breakdowns."
  (beads-client-request "stats" nil))

(defun beads-client-count (&optional filters)
  "Count issues with optional FILTERS.
FILTERS is a plist with keys like :status, :group-by.
Returns count data."
  (let ((args (beads-client--plist-to-alist filters)))
    (beads-client-request "count" args)))

(defun beads-client-types ()
  "Get list of valid issue type names.
Returns a list of type name strings."
  (let ((response (beads-client-request "types" nil)))
    (append (mapcar (lambda (type) (alist-get 'name type))
                    (alist-get 'core_types response))
            (append (alist-get 'custom_types response) nil))))

(defun beads-client-types-full ()
  "Get full types response with core and custom types separated.
Returns alist with `core_types' and `custom_types' keys."
  (beads-client-request "types" nil))

(defconst beads-builtin-types
  '("bug" "feature" "task" "epic" "chore" "gate" "convoy" "agent" "role" "rig")
  "List of built-in issue types supported by beads.
Used as fallback when types cannot be fetched.")

(defvar beads--types-cache nil
  "Cached list of valid issue types.")

(defvar beads--types-cache-time 0
  "Time when types cache was last updated.")

(defconst beads--types-cache-ttl 60
  "Seconds to cache types before refreshing.")

(defun beads-get-types ()
  "Get valid issue types, using cache when fresh.
Falls back to `beads-builtin-types' on error."
  (if (and beads--types-cache
           (< (- (float-time) beads--types-cache-time) beads--types-cache-ttl))
      beads--types-cache
    (condition-case nil
        (let ((types (beads-client-types)))
          (setq beads--types-cache types
                beads--types-cache-time (float-time))
          types)
      (error beads-builtin-types))))

(defun beads-client-config-get (key)
  "Get configuration value for KEY."
  (let ((response (beads-client-request "config_get" `((key . ,key)))))
    (alist-get 'value response)))

(defun beads-client-config-set (key value)
  "Set configuration KEY to VALUE."
  (beads-client-request "config_set" `((key . ,key) (value . ,value))))

(defun beads-client-dep-add (from-id to-id &optional dep-type)
  "Add dependency FROM-ID to TO-ID with optional DEP-TYPE.
DEP-TYPE can be \"blocks\", \"related\", \"parent-child\", or \"discovered-from\".
Defaults to \"blocks\"."
  (unless (and from-id to-id)
    (signal 'beads-client-error (list "Both from-id and to-id required")))
  (let ((args `((from_id . ,from-id)
                (to_id . ,to-id))))
    (when dep-type
      (push `(dep_type . ,dep-type) args))
    (beads-client-request "dep_add" args)))

(defun beads-client-dep-remove (from-id to-id)
  "Remove dependency FROM-ID to TO-ID."
  (unless (and from-id to-id)
    (signal 'beads-client-error (list "Both from-id and to-id required")))
  (beads-client-request "dep_remove" `((from_id . ,from-id)
                                     (to_id . ,to-id))))

(defun beads-client-dep-tree (id &optional max-depth)
  "Get dependency tree for issue ID with optional MAX-DEPTH."
  (unless id
    (signal 'beads-client-error (list "Issue ID required")))
  (let ((args `((id . ,id))))
    (when max-depth
      (push `(max_depth . ,max-depth) args))
    (beads-client-request "dep_tree" args)))

(defun beads-client-label-add (id label)
  "Add LABEL to issue ID."
  (unless (and id label)
    (signal 'beads-client-error (list "Issue ID and label required")))
  (beads-client-request "label_add" `((id . ,id)
                                    (label . ,label))))

(defun beads-client-label-remove (id label)
  "Remove LABEL from issue ID."
  (unless (and id label)
    (signal 'beads-client-error (list "Issue ID and label required")))
  (beads-client-request "label_remove" `((id . ,id)
                                       (label . ,label))))

(defun beads-client-get-mutations (&optional since-id)
  "Get mutations since SINCE-ID for real-time updates.
Returns array of mutation objects."
  (let ((args (when since-id
                `((since_id . ,since-id)))))
    (beads-client-request "get_mutations" args)))

(defun beads-client--plist-to-alist (plist)
  "Convert PLIST with keyword keys to alist with string keys.
Converts :kebab-case to snake_case for JSON."
  (when plist
    (let ((alist '())
          (key nil))
      (while plist
        (setq key (pop plist))
        (unless (keywordp key)
          (signal 'beads-client-error (list "Expected keyword in plist" key)))
        (let* ((key-name (substring (symbol-name key) 1))
               (json-key (replace-regexp-in-string "-" "_" key-name))
               (value (pop plist)))
          (when value
            (push (cons json-key value) alist))))
      (nreverse alist))))

(defun beads-client-clear-cache ()
  "Clear the cached database path.
Useful when switching between projects."
  (interactive)
  (setq beads-client--cached-db-path nil)
  (setq beads-client--cache-time nil))

(provide 'beads-client)
;;; beads-client.el ends here
