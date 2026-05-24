;;; beads-cache.el --- Project-scoped issue cache with Dolt-backed invalidation -*- lexical-binding: t -*-

;; Copyright (C) 2026 Peter Jun Koh

;; Author: Peter Jun Koh
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

;; Project-scoped client-side cache for the issue list, designed to
;; eliminate redundant `beads-client-list' fetches when the Dolt
;; database has not changed between refreshes (the common case for
;; auto-refresh).
;;
;; The cache stores the last `beads-client-list' result alongside a
;; lightweight "freshness token" — counts and max timestamps across
;; the issues, labels, dependencies, and comments tables, fetched in
;; one cheap SQL round trip via `beads-client-freshness'.  When the
;; token is unchanged on the next refresh, the cached issues are
;; returned without re-fetching the list payload.
;;
;; The cache only kicks in when the active backend supports the
;; `freshness' operation (currently `bd-dolt-sql' only).  Without it,
;; calls degrade to plain `beads-client-list' with no caching, so the
;; CLI-only path is unaffected.
;;
;; Cache invalidation:
;;
;;   1. Token-based: any write that bumps `issues.updated_at',
;;      `dependencies.created_at', `comments.created_at', or any of
;;      the row counts will be detected on the next freshness check.
;;   2. Explicit: `beads-cache--write-invalidator-advice' wraps
;;      `beads-client-request' and clears the cache after any write
;;      operation succeeds.  This makes a same-second update visible
;;      immediately even if `updated_at' precision (1s) would mask it.
;;
;; Ordering: when refreshing, the freshness token is fetched BEFORE
;; the list, never after.  Token-after-list can permanently strand a
;; stale cache when a write lands between the two reads:
;;
;;   list  -> A     ; old data
;;   write -> B
;;   token -> B     ; saved alongside A
;;   next refresh: token == B -> cached A served forever.
;;
;; Token-before-list can produce one redundant refresh on the next
;; cycle, but never permanent staleness.

;;; Code:

(require 'cl-lib)
(require 'beads-client)
(require 'beads-backend)

(defgroup beads-cache nil
  "Client-side caching for the Beads issue list."
  :group 'beads
  :prefix "beads-cache-")

(defcustom beads-cache-enabled t
  "When non-nil, use the project-scoped issue cache.
When the active backend does not support the `freshness' operation,
the cache is silently bypassed regardless of this setting."
  :type 'boolean
  :group 'beads-cache)

(cl-defstruct beads-cache
  "Project-scoped cache of the last `beads-client-list' result.

`issues' is the list of issue alists last returned by the backend.
`freshness-token' is the lightweight token captured immediately
before that list was fetched (see commentary for ordering rationale).
`full-issues' is a hash table mapping issue ID to the full
`beads-client-show' result (including long-form fields like
description, design, notes, acceptance_criteria, comments) for
zero-subprocess detail navigation."
  issues
  freshness-token
  (full-issues (make-hash-table :test 'equal)))

(defvar beads-cache--registry (make-hash-table :test 'equal)
  "Hash table mapping project-root -> `beads-cache' instance.")

(defun beads-cache--canonical-root (&optional project-root)
  "Return the canonicalised project root, or nil if none can be resolved."
  (when-let ((root (or project-root (beads-client--project-root))))
    (file-name-as-directory (expand-file-name root))))

(defun beads-cache-for-project (&optional project-root)
  "Return the cache instance for PROJECT-ROOT, creating one if needed.
Returns nil when no project root can be resolved."
  (when-let ((root (beads-cache--canonical-root project-root)))
    (or (gethash root beads-cache--registry)
        (puthash root (make-beads-cache) beads-cache--registry))))

(defun beads-cache-invalidate (&optional project-root)
  "Drop the cached entry for PROJECT-ROOT (or current project)."
  (when-let ((root (beads-cache--canonical-root project-root)))
    (remhash root beads-cache--registry)))

(defun beads-cache-clear-all ()
  "Drop every cached entry across all projects."
  (interactive)
  (clrhash beads-cache--registry))

(defun beads-cache-supported-p ()
  "Return non-nil when the active backend supports the freshness check.
This is the precondition for any cache benefit; without it
`beads-cache-refresh' falls back to a plain `beads-client-list'."
  (condition-case nil
      (beads-backend-supports-p (beads-backend-for-project) "freshness")
    (beads-backend-error nil)))

(defun beads-cache--fetch-token ()
  "Return the current freshness token, or nil if unavailable."
  (condition-case nil
      (beads-client-freshness)
    (beads-client-error nil)
    (beads-backend-error nil)))

(defun beads-cache-refresh (&optional cache force)
  "Refresh CACHE, returning a cons (CHANGED-P . ISSUES).

CHANGED-P is non-nil when the issue list payload was re-fetched
this call; nil when the cached payload was reused unchanged.

When CACHE is nil it defaults to the current project's cache.

When FORCE is non-nil, skip the freshness check and always re-fetch.

If `beads-cache-enabled' is nil, or the backend does not support
the freshness check, or no project cache can be resolved, this
falls through to a plain `beads-client-list' with no caching.

The cached list is explicitly requested with `:all t' so list views use
the same all-normal-issues contract across bd CLI and Dolt SQL backends."
  (let ((cache (or cache (beads-cache-for-project))))
    (cond
     ;; No cache available: passthrough.
     ((or (not beads-cache-enabled) (null cache))
      (cons t (beads-client-list '(:all t))))
     ;; Backend can't check freshness: passthrough.
     ((not (beads-cache-supported-p))
      (cons t (beads-client-list '(:all t))))
     ;; Forced refresh, or cold cache: capture token BEFORE list.
     ((or force (null (beads-cache-freshness-token cache)))
      (let* ((token (beads-cache--fetch-token))
             (issues (beads-client-list '(:all t))))
        (setf (beads-cache-freshness-token cache) token)
        (setf (beads-cache-issues cache) issues)
        (cons t issues)))
     (t
      (let ((token (beads-cache--fetch-token)))
        (cond
         ;; Freshness check itself failed: degrade gracefully to a
         ;; full fetch and clear the token so we retry cleanly later.
         ((null token)
          (let ((issues (beads-client-list '(:all t))))
            (setf (beads-cache-freshness-token cache) nil)
            (setf (beads-cache-issues cache) issues)
            (cons t issues)))
         ;; Token unchanged: serve from cache, no list fetch.
         ((equal token (beads-cache-freshness-token cache))
          (cons nil (beads-cache-issues cache)))
         ;; Token changed: re-fetch, then store the token we just saw.
         ;; (Note: we capture the token BEFORE the list to avoid
         ;; permanently stranding stale data if a write lands between
         ;; the two reads.)
         (t
          (let ((issues (beads-client-list '(:all t))))
            (setf (beads-cache-freshness-token cache) token)
            (setf (beads-cache-issues cache) issues)
            (cons t issues)))))))))

(defun beads-cache-get-issues (&optional cache)
  "Return the cached list of issues for CACHE (default: current project)."
  (when-let ((cache (or cache (beads-cache-for-project))))
    (beads-cache-issues cache)))

;;; Full-issue cache (for list -> detail navigation)

(defun beads-cache-get-full-issue (id &optional cache)
  "Return the cached full-issue alist for ID, or nil if missing.
CACHE defaults to the current project's cache."
  (when-let* ((cache (or cache (beads-cache-for-project)))
              (table (beads-cache-full-issues cache)))
    (gethash id table)))

(defun beads-cache-put-full-issue (id issue &optional cache)
  "Store ISSUE as the cached full record for ID in CACHE.
CACHE defaults to the current project's cache.
Returns ISSUE for convenience."
  (when-let* ((cache (or cache (beads-cache-for-project)))
              (table (beads-cache-full-issues cache)))
    (puthash id issue table))
  issue)

(defun beads-cache-show (id)
  "Return the full issue for ID, consulting the project cache first.

On a cache hit, returns immediately with no subprocess call.  On a
miss, falls back to `beads-client-show' and stores the result for
subsequent calls.

When `beads-cache-enabled' is nil or no project root resolves, this
is equivalent to `beads-client-show' (no caching)."
  (or (and beads-cache-enabled (beads-cache-get-full-issue id))
      (let ((issue (beads-client-show id)))
        (when beads-cache-enabled
          (beads-cache-put-full-issue id issue))
        issue)))

;;; Write-invalidation advice

(defconst beads-cache--write-operations
  '("create" "update" "update_bulk" "close" "close_bulk" "delete"
    "dep_add" "dep_remove" "label_add" "label_remove"
    "comments-add" "config_set" "config_unset" "duplicate")
  "Operations whose successful completion should drop the cache.

Read-only operations and the `freshness' check itself are not in
this list; they never invalidate the cache.")

(defun beads-cache--is-dry-run-p (operation args)
  "Return non-nil if OPERATION+ARGS represents a dry-run with no DB write."
  (and (equal operation "create")
       (let ((dry (alist-get 'dry_run args)))
         (and dry (not (equal dry :json-false))))))

(defun beads-cache--invalidate-on-write-advice (orig-fn operation args
                                                        &rest rest)
  "Around-advice for `beads-client-request': invalidate after writes.
ORIG-FN is the original function; OPERATION and ARGS are the call
arguments; REST is forwarded for forward-compatibility."
  (let ((result (apply orig-fn operation args rest)))
    (when (and (member operation beads-cache--write-operations)
               (not (beads-cache--is-dry-run-p operation args)))
      (beads-cache-invalidate))
    result))

(defun beads-cache-install ()
  "Install the write-invalidation advice on `beads-client-request'.
Idempotent: safe to call multiple times."
  (advice-add 'beads-client-request
              :around #'beads-cache--invalidate-on-write-advice))

(defun beads-cache-uninstall ()
  "Remove the write-invalidation advice and clear all cached entries."
  (interactive)
  (advice-remove 'beads-client-request
                 #'beads-cache--invalidate-on-write-advice)
  (beads-cache-clear-all))

;; Install on load so writes always invalidate, even when a caller
;; reaches `beads-client-request' without going through this module.
(beads-cache-install)

(provide 'beads-cache)

;;; beads-cache.el ends here
