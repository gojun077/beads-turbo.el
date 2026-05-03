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
  "Find database indicator in BEADS-DIR.
Returns a path inside BEADS-DIR if a beads project is found, nil otherwise.
Checks for metadata.json (present in both SQLite and Dolt setups),
beads.db (legacy SQLite), or any .db file."
  (when (file-directory-p beads-dir)
    (let ((metadata (expand-file-name "metadata.json" beads-dir)))
      (if (file-exists-p metadata)
          metadata
        (let ((default-db (expand-file-name "beads.db" beads-dir)))
          (if (file-exists-p default-db)
              default-db
            (let ((db-files (directory-files beads-dir t "\\.db\\'")))
              (cl-find-if (lambda (f)
                            (and (not (string-match-p "\\.backup" f))
                                 (not (string-match-p "vc\\.db\\'" f))))
                          db-files))))))))

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

(defun beads-client-request-async (operation args callback)
  "Execute OPERATION with ARGS asynchronously via CLI.

CALLBACK is called with (ERROR DATA) when complete:
  ERROR is nil on success, or a string describing the error.
  DATA is the parsed result on success, or nil on failure.

Use `beads-client-request' for synchronous (blocking) operations."
  (let ((project-root (when-let ((db (beads-client--find-database)))
                        (file-name-directory
                         (directory-file-name
                          (file-name-directory db))))))
    (beads-backend-cli-execute-async
     operation args
     (lambda (err data)
       (if err
           (funcall callback err nil)
         (funcall callback nil data)))
     project-root)))

(defun beads-client--unwrap-single (result)
  "Unwrap RESULT if it is a single-element list.
Some CLI commands return a one-element array where a single object
is expected."
  (if (and (listp result)
           (= (length result) 1)
           (listp (car result)))
      (car result)
    result))

(defun beads-client-list (&optional filters)
  "List issues with optional FILTERS.
FILTERS is a plist with keys like :status, :priority, :issue-type, :assignee,
:labels, :limit, :title-contains, :parent (for epic-scoped views), etc.
Returns array of issue objects."
  (let ((args (beads-client--plist-to-alist filters)))
    (beads-client-request "list" args)))

(defun beads-client-list-async (callback &optional filters)
  "Fetch issue list asynchronously with optional FILTERS.
CALLBACK is called with (ERROR DATA) when complete.
FILTERS uses the same plist format as `beads-client-list'."
  (let ((args (beads-client--plist-to-alist filters)))
    (beads-client-request-async "list" args callback)))

(defun beads-client-show (id)
  "Get single issue by ID.
Returns issue object."
  (unless id
    (signal 'beads-client-error (list "Issue ID required")))
  (beads-client--unwrap-single
   (beads-client-request "show" `((id . ,id)))))

(defun beads-client-show-async (id callback)
  "Fetch single issue by ID asynchronously.
CALLBACK is called with (ERROR DATA) when complete."
  (unless id
    (signal 'beads-client-error (list "Issue ID required")))
  (beads-client-request-async "show" `((id . ,id))
    (lambda (err data)
      (if err
          (funcall callback err nil)
        (funcall callback nil (beads-client--unwrap-single data))))))

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
    (beads-client--unwrap-single
     (beads-client-request "update" request-args))))

(defun beads-client-update-bulk (ids &rest args)
  "Update multiple issue IDS in a single CLI call with ARGS (plist).
ARGS uses the same plist format as `beads-client-update' — the same
fields are applied to every ID in IDS.  Implemented via
`bd update [id...] --flag value ...' which applies all flags to each
listed ID in one subprocess.  Requires backend support for the
\"update_bulk\" operation; callers that want transparent fallback to
per-ID calls should use the helper in beads-list.el rather than
handling `beads-client-error' themselves.  Returns the parsed CLI
response (typically the array of updated issues)."
  (unless (and ids (listp ids) (> (length ids) 0))
    (signal 'beads-client-error (list "Issue IDs (non-empty list) required")))
  (let ((request-args (beads-client--plist-to-alist
                       (plist-put args :ids ids))))
    (beads-client-request "update_bulk" request-args)))

(defun beads-client-close (id &optional reason)
  "Close issue ID with optional REASON.
Returns closed issue object."
  (unless id
    (signal 'beads-client-error (list "Issue ID required")))
  (let ((args `((id . ,id))))
    (when reason
      (push `(reason . ,reason) args))
    (beads-client--unwrap-single
     (beads-client-request "close" args))))

(defun beads-client-close-bulk (ids &optional reason)
  "Close multiple issue IDS in a single CLI call with optional REASON.
Implemented via `bd close [id...] [--reason TEXT]' which closes every
listed ID in one subprocess.  Requires backend support for the
\"close_bulk\" operation.  Returns the parsed CLI response."
  (unless (and ids (listp ids) (> (length ids) 0))
    (signal 'beads-client-error (list "Issue IDs (non-empty list) required")))
  (let ((args `((ids . ,ids))))
    (when reason
      (push `(reason . ,reason) args))
    (beads-client-request "close_bulk" args)))

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

(defun beads-client-activity (&optional filters)
  "Fetch activity events with optional FILTERS plist.
Supported keys: :limit, :mol (issue prefix), :type.
Returns array of activity event objects."
  (let ((args (beads-client--plist-to-alist filters)))
    (beads-client-request "activity" args)))

(defun beads-client-lint (&optional type-filter)
  "Fetch lint results.
Optional TYPE-FILTER restricts to a specific issue type.
Returns alist with `results' and `total' keys."
  (let ((args (when type-filter
                `((type . ,type-filter)))))
    (beads-client-request "lint" args)))

(defun beads-client-orphans ()
  "Fetch orphaned issues (referenced in commits but not closed).
Returns list of orphan objects."
  (beads-client-request "orphans" nil))

(defun beads-client-stale (&optional days status)
  "Fetch stale issues with optional DAYS threshold and STATUS filter.
Returns list of stale issue objects."
  (let (args)
    (when days
      (push `(days . ,days) args))
    (when status
      (push `(status . ,status) args))
    (beads-client-request "stale" args)))

(defun beads-client--plist-to-alist (plist)
  "Convert PLIST with keyword keys to alist with symbol keys.
Converts :kebab-case to snake_case symbols."
  (when plist
    (let ((alist '())
          (key nil))
      (while plist
        (setq key (pop plist))
        (unless (keywordp key)
          (signal 'beads-client-error (list "Expected keyword in plist" key)))
        (let* ((key-name (substring (symbol-name key) 1))
               (snake-key (intern (replace-regexp-in-string "-" "_" key-name)))
               (value (pop plist)))
           (when value
             (push (cons snake-key value) alist))))
      (nreverse alist))))

(defun beads-client-clear-cache ()
  "Clear the cached database path.
Useful when switching between projects."
  (interactive)
  (setq beads-client--cached-db-path nil)
  (setq beads-client--cache-time nil))

(provide 'beads-client)
;;; beads-client.el ends here
