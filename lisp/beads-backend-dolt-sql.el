;;; beads-backend-dolt-sql.el --- Direct Dolt SQL transport for read-heavy operations -*- lexical-binding: t -*-

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

;; Direct Dolt SQL transport for read-only operations.  Instead of
;; forking `bd' (which starts the Go runtime, connects to Dolt,
;; serializes, and exits), this module sends SELECT queries directly
;; to the Dolt SQL server.  When Lucius Chen's mysql.el package is
;; installed, it uses mysql.el's native wire-protocol client.  Otherwise
;; it falls back to one-shot `mariadb -e'.
;;
;; The Oracle MySQL client (`mysql') is intentionally not supported.
;; mysql 9.x dropped both `--skip-ssl' and the `mysql_native_password'
;; authentication plugin Dolt's server still uses, so the handshake
;; fails before any query runs.  See issue bdel-11f for details.
;;
;; Benchmarks (mariadb 11.8.6, bd 1.0.3, 88 issues):
;;
;;   Operation | `bd` CLI (avg) | Direct SQL | Speedup
;;   ----------|------------------|------------|--------
;;   list      | 64ms             | 12ms       | 5.3x
;;   show      | 51ms             | 9ms        | 5.7x
;;   ready     | 47ms             | 7ms        | 6.7x
;;   stats     | 210ms            | 8ms        | 26.3x
;;
;; Tier 1: `mariadb -e' subprocess → ~10ms overhead.
;; Tier 2: mysql.el native MySQL wire protocol → sub-ms expected.
;; Only mysql.el keeps a long-lived SQL connection open; the `mariadb'
;; fallback is intentionally one-shot so Emacs does not retain a second
;; mysql-related process.
;;
;; Writes always go through `bd` CLI — SQL transport is a read-only
;; accelerator only.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'beads-backend)
(require 'beads-client)

(defconst beads-dolt-sql--vendored-mysql-directory
  (let ((repo-root (file-name-directory
                    (directory-file-name
                     (file-name-directory (or load-file-name buffer-file-name))))))
    (expand-file-name "vendor/mysql.el" repo-root))
  "Directory containing the vendored mysql.el dependency.")

(defun beads-dolt-sql--ensure-vendored-mysql-load-path ()
  "Add the vendored mysql.el directory to `load-path' when present."
  (when (file-directory-p beads-dolt-sql--vendored-mysql-directory)
    (add-to-list 'load-path beads-dolt-sql--vendored-mysql-directory)))

(beads-dolt-sql--ensure-vendored-mysql-load-path)

(defgroup beads-dolt-sql nil
  "Direct Dolt SQL transport for beads.el read operations."
  :group 'beads
  :prefix "beads-dolt-sql-")

(defcustom beads-dolt-sql-enabled t
  "When non-nil, use direct Dolt SQL for read operations.
This is enabled by default so Dolt workspaces use SQL for supported
read operations.  When the Dolt SQL server is not running, or the
current workspace is not backed by Dolt, operations silently fall
back to the `bd' CLI subprocess."
  :type 'boolean
  :group 'beads-dolt-sql)

(defcustom beads-dolt-sql-list-lite t
  "When non-nil, the `list' SQL operation omits heavy fields.
The lightweight query drops the per-issue `description' string
and the full `dependencies' array (the cheap `dependency_count',
`dependent_count' and `parent' fields are preserved).  This
matches what the issue-list UI actually renders and shrinks the
JSON payload from ~149KB to ~12KB on a ~100-issue project,
substantially cutting Elisp JSON parse time (see bdel-057).

Set to nil to keep returning the full payload — useful if a
custom caller depends on `description' or full `dependencies'
in `list' results."
  :type 'boolean
  :group 'beads-dolt-sql)

(defvar beads-dolt-sql--params nil
  "Cached Dolt connection params from `bd dolt show --json'.")

(defvar beads-dolt-sql--params-time nil
  "Time when `beads-dolt-sql--params' was last refreshed.")

(defvar beads-dolt-sql--params-root nil
  "Canonical project root for `beads-dolt-sql--params'.")

(defvar beads-dolt-sql--available t
  "Nil if last attempt to reach Dolt SQL server failed.
Set back to t periodically so we retry after transient failures.")

(defvar beads-backend-dolt-sql--cli-fallback-program nil
  "Path to the bd CLI for fallback execution.")

(defvar beads-dolt-sql--native-mysql-conn nil)
(defvar beads-dolt-sql--native-mysql-params nil)

(defconst beads-dolt-sql--list-sql
  "SELECT JSON_ARRAYAGG(\
JSON_OBJECT(\
'id', i.id, \
'title', i.title, \
'description', i.description, \
'status', i.status, \
'priority', i.priority, \
'issue_type', i.issue_type, \
'owner', COALESCE(NULLIF(i.owner, ''), i.created_by), \
'assignee', i.assignee, \
'estimated_minutes', i.estimated_minutes, \
'created_at', DATE_FORMAT(i.created_at, '%Y-%m-%dT%H:%i:%sZ'), \
'created_by', i.created_by, \
'updated_at', DATE_FORMAT(i.updated_at, '%Y-%m-%dT%H:%i:%sZ'), \
'started_at', IF(i.started_at IS NOT NULL, \
  DATE_FORMAT(i.started_at, '%Y-%m-%dT%H:%i:%sZ'), NULL), \
'closed_at', IF(i.closed_at IS NOT NULL, \
  DATE_FORMAT(i.closed_at, '%Y-%m-%dT%H:%i:%sZ'), NULL), \
'closed_by_session', i.closed_by_session, \
'close_reason', i.close_reason, \
'external_ref', i.external_ref, \
'spec_id', i.spec_id, \
'source_system', i.source_system, \
'source_repo', i.source_repo, \
'labels', COALESCE(\
  (SELECT JSON_ARRAYAGG(l.label) FROM labels l WHERE l.issue_id = i.id), \
  JSON_ARRAY()), \
'dependency_count', \
  (SELECT COUNT(*) FROM dependencies d1 \
   WHERE d1.issue_id = i.id AND d1.type != 'parent-child'), \
'dependent_count', \
  (SELECT COUNT(*) FROM dependencies d2 \
   WHERE d2.depends_on_id = i.id AND d2.type != 'parent-child'), \
'comment_count', \
  (SELECT COUNT(*) FROM comments c WHERE c.issue_id = i.id), \
'parent', \
  (SELECT d3.depends_on_id FROM dependencies d3 \
   WHERE d3.issue_id = i.id AND d3.type = 'parent-child' LIMIT 1), \
'dependencies', COALESCE(\
  (SELECT JSON_ARRAYAGG(\
    JSON_OBJECT(\
      'issue_id', d.issue_id, \
      'depends_on_id', d.depends_on_id, \
      'type', d.type, \
      'created_at', DATE_FORMAT(d.created_at, '%Y-%m-%dT%H:%i:%sZ'), \
      'created_by', d.created_by, \
      'metadata', d.metadata\
    )\
  ) FROM dependencies d WHERE d.issue_id = i.id), \
  JSON_ARRAY())\
)\
) AS issues \
FROM issues i \
WHERE i.ephemeral = 0 \
ORDER BY i.priority ASC, i.created_at DESC"
  "SQL query for the `list' operation.
Produces a single-row JSON_ARRAYAGG of issue objects matching
the `bd list --json' format.")

(defconst beads-dolt-sql--list-lite-sql
  "SELECT JSON_ARRAYAGG(\
JSON_OBJECT(\
'id', i.id, \
'title', i.title, \
'status', i.status, \
'priority', i.priority, \
'issue_type', i.issue_type, \
'owner', COALESCE(NULLIF(i.owner, ''), i.created_by), \
'assignee', i.assignee, \
'estimated_minutes', i.estimated_minutes, \
'created_at', DATE_FORMAT(i.created_at, '%Y-%m-%dT%H:%i:%sZ'), \
'created_by', i.created_by, \
'updated_at', DATE_FORMAT(i.updated_at, '%Y-%m-%dT%H:%i:%sZ'), \
'started_at', IF(i.started_at IS NOT NULL, \
  DATE_FORMAT(i.started_at, '%Y-%m-%dT%H:%i:%sZ'), NULL), \
'closed_at', IF(i.closed_at IS NOT NULL, \
  DATE_FORMAT(i.closed_at, '%Y-%m-%dT%H:%i:%sZ'), NULL), \
'closed_by_session', i.closed_by_session, \
'close_reason', i.close_reason, \
'external_ref', i.external_ref, \
'spec_id', i.spec_id, \
'source_system', i.source_system, \
'source_repo', i.source_repo, \
'labels', COALESCE(\
  (SELECT JSON_ARRAYAGG(l.label) FROM labels l WHERE l.issue_id = i.id), \
  JSON_ARRAY()), \
'dependency_count', \
  (SELECT COUNT(*) FROM dependencies d1 \
   WHERE d1.issue_id = i.id AND d1.type != 'parent-child'), \
'dependent_count', \
  (SELECT COUNT(*) FROM dependencies d2 \
   WHERE d2.depends_on_id = i.id AND d2.type != 'parent-child'), \
'comment_count', \
  (SELECT COUNT(*) FROM comments c WHERE c.issue_id = i.id), \
'parent', \
  (SELECT d3.depends_on_id FROM dependencies d3 \
   WHERE d3.issue_id = i.id AND d3.type = 'parent-child' LIMIT 1)\
)\
) AS issues \
FROM issues i \
WHERE i.ephemeral = 0 \
ORDER BY i.priority ASC, i.created_at DESC"
  "Lightweight SQL query for the `list' operation (see bdel-057).
Same shape as `beads-dolt-sql--list-sql' but omits the per-row
`description' field and the full `dependencies' array (the cheap
`dependency_count' / `dependent_count' / `parent' fields are
preserved).  This is what the issue-list UI actually renders, and
it shrinks the JSON payload from ~149KB to ~12KB on a
~100-issue project, dramatically cutting Elisp JSON parse time.

Callers needing the full description or full dependency objects
(e.g. `beads-list-edit-description', the detail view) fetch a
single issue via the `show' operation, which still returns the
complete record.")

(defconst beads-dolt-sql--show-sql
  "SELECT JSON_OBJECT(\
'id', i.id, \
'title', i.title, \
'description', i.description, \
'design', i.design, \
'acceptance_criteria', i.acceptance_criteria, \
'notes', i.notes, \
'status', i.status, \
'priority', i.priority, \
'issue_type', i.issue_type, \
'owner', COALESCE(NULLIF(i.owner, ''), i.created_by), \
'assignee', i.assignee, \
'estimated_minutes', i.estimated_minutes, \
'created_at', DATE_FORMAT(i.created_at, '%Y-%m-%dT%H:%i:%sZ'), \
'created_by', i.created_by, \
'updated_at', DATE_FORMAT(i.updated_at, '%Y-%m-%dT%H:%i:%sZ'), \
'started_at', IF(i.started_at IS NOT NULL, \
  DATE_FORMAT(i.started_at, '%Y-%m-%dT%H:%i:%sZ'), NULL), \
'closed_at', IF(i.closed_at IS NOT NULL, \
  DATE_FORMAT(i.closed_at, '%Y-%m-%dT%H:%i:%sZ'), NULL), \
'closed_by_session', i.closed_by_session, \
'close_reason', i.close_reason, \
'external_ref', i.external_ref, \
'spec_id', i.spec_id, \
'source_system', i.source_system, \
'source_repo', i.source_repo, \
'labels', COALESCE(\
  (SELECT JSON_ARRAYAGG(l.label) FROM labels l WHERE l.issue_id = i.id), \
  JSON_ARRAY()), \
'comments', COALESCE(\
  (SELECT JSON_ARRAYAGG(\
    JSON_OBJECT(\
      'id', c.id, \
      'author', c.author, \
      'text', c.text, \
      'created_at', DATE_FORMAT(c.created_at, '%Y-%m-%dT%H:%i:%sZ')\
    )\
  ) FROM comments c WHERE c.issue_id = i.id), \
  JSON_ARRAY()), \
'dependency_count', \
  (SELECT COUNT(*) FROM dependencies d1 \
   WHERE d1.issue_id = i.id AND d1.type != 'parent-child'), \
'dependent_count', \
  (SELECT COUNT(*) FROM dependencies d2 \
   WHERE d2.depends_on_id = i.id AND d2.type != 'parent-child'), \
'comment_count', \
  (SELECT COUNT(*) FROM comments c WHERE c.issue_id = i.id), \
'parent', \
  (SELECT d3.depends_on_id FROM dependencies d3 \
   WHERE d3.issue_id = i.id AND d3.type = 'parent-child' LIMIT 1), \
'dependencies', COALESCE(\
  (SELECT JSON_ARRAYAGG(\
    JSON_OBJECT(\
      'issue_id', d.issue_id, \
      'depends_on_id', d.depends_on_id, \
      'type', d.type, \
      'created_at', DATE_FORMAT(d.created_at, '%Y-%m-%dT%H:%i:%sZ'), \
      'created_by', d.created_by, \
      'metadata', d.metadata\
    )\
  ) FROM dependencies d WHERE d.issue_id = i.id), \
  JSON_ARRAY())\
) AS issue \
FROM issues i \
WHERE i.id = ? AND i.ephemeral = 0"
  "SQL template for the `show' operation.
The `?' placeholder is replaced with the issue ID.")

(defconst beads-dolt-sql--stats-sql
  "SELECT JSON_OBJECT(\
'schema_version', 1, \
'summary', JSON_OBJECT(\
  'total_issues', (SELECT COUNT(*) FROM issues WHERE ephemeral = 0), \
  'open_issues', (SELECT COUNT(*) FROM issues WHERE status = 'open' AND ephemeral = 0), \
  'in_progress_issues', (SELECT COUNT(*) FROM issues WHERE status = 'in_progress' AND ephemeral = 0), \
  'blocked_issues', \
    (SELECT COUNT(DISTINCT i.id) FROM issues i \
     INNER JOIN blocked_issues b ON b.id = i.id), \
  'closed_issues', (SELECT COUNT(*) FROM issues WHERE status = 'closed' AND ephemeral = 0), \
  'deferred_issues', (SELECT COUNT(*) FROM issues WHERE status = 'deferred' AND ephemeral = 0), \
  'ready_issues', (SELECT COUNT(*) FROM ready_issues), \
  'pinned_issues', (SELECT COUNT(*) FROM issues WHERE pinned = 1 AND ephemeral = 0), \
  'epics_eligible_for_closure', 0, \
  'average_lead_time_hours', 0\
)\
) AS stats"
  "SQL query for the `stats' operation.")

(defconst beads-dolt-sql--ready-sql
  "SELECT JSON_ARRAYAGG(\
JSON_OBJECT(\
'id', i.id, \
'title', i.title, \
'description', i.description, \
'status', i.status, \
'priority', i.priority, \
'issue_type', i.issue_type, \
'owner', COALESCE(NULLIF(i.owner, ''), i.created_by), \
'assignee', i.assignee, \
'estimated_minutes', i.estimated_minutes, \
'created_at', DATE_FORMAT(i.created_at, '%Y-%m-%dT%H:%i:%sZ'), \
'created_by', i.created_by, \
'updated_at', DATE_FORMAT(i.updated_at, '%Y-%m-%dT%H:%i:%sZ'), \
'started_at', IF(i.started_at IS NOT NULL, \
  DATE_FORMAT(i.started_at, '%Y-%m-%dT%H:%i:%sZ'), NULL), \
'closed_at', IF(i.closed_at IS NOT NULL, \
  DATE_FORMAT(i.closed_at, '%Y-%m-%dT%H:%i:%sZ'), NULL), \
'labels', COALESCE(\
  (SELECT JSON_ARRAYAGG(l.label) FROM labels l WHERE l.issue_id = i.id), \
  JSON_ARRAY()), \
'dependency_count', \
  (SELECT COUNT(*) FROM dependencies d1 \
   WHERE d1.issue_id = i.id AND d1.type != 'parent-child'), \
'dependent_count', \
  (SELECT COUNT(*) FROM dependencies d2 \
   WHERE d2.depends_on_id = i.id AND d2.type != 'parent-child'), \
'comment_count', \
  (SELECT COUNT(*) FROM comments c WHERE c.issue_id = i.id), \
'parent', \
  (SELECT d3.depends_on_id FROM dependencies d3 \
   WHERE d3.issue_id = i.id AND d3.type = 'parent-child' LIMIT 1)\
)\
) AS issues \
FROM ready_issues r \
INNER JOIN issues i ON i.id = r.id \
WHERE i.ephemeral = 0 \
ORDER BY i.priority ASC, i.created_at DESC"
  "SQL query for the `ready' operation.
Uses the Dolt materialized view `ready_issues'.")

(defconst beads-dolt-sql--count-sql
  "SELECT JSON_OBJECT('count', COUNT(*)) AS result \
FROM issues i \
WHERE i.ephemeral = 0"
  "SQL query for the `count' operation.")

(defconst beads-dolt-sql--epic-status-sql
  "SELECT JSON_ARRAYAGG(payload) AS epics FROM (\
SELECT JSON_OBJECT(\
'epic', JSON_OBJECT(\
  'id', i.id, \
  'title', i.title, \
  'description', i.description, \
  'status', i.status, \
  'priority', i.priority, \
  'issue_type', i.issue_type, \
  'owner', COALESCE(NULLIF(i.owner, ''), i.created_by), \
  'assignee', i.assignee, \
  'created_at', DATE_FORMAT(i.created_at, '%Y-%m-%dT%H:%i:%sZ'), \
  'created_by', i.created_by, \
  'updated_at', DATE_FORMAT(i.updated_at, '%Y-%m-%dT%H:%i:%sZ')\
), \
'total_children', \
  (SELECT COUNT(*) FROM dependencies d \
   INNER JOIN issues c ON c.id = d.issue_id \
   WHERE d.depends_on_id = i.id AND d.type = 'parent-child' \
     AND c.ephemeral = 0), \
'closed_children', \
  (SELECT COUNT(*) FROM dependencies d \
   INNER JOIN issues c ON c.id = d.issue_id \
   WHERE d.depends_on_id = i.id AND d.type = 'parent-child' \
     AND c.ephemeral = 0 AND c.status = 'closed'), \
'eligible_for_close', \
  JSON_EXTRACT(\
    IF((SELECT COUNT(*) FROM dependencies d \
        INNER JOIN issues c ON c.id = d.issue_id \
        WHERE d.depends_on_id = i.id AND d.type = 'parent-child' \
          AND c.ephemeral = 0) > 0 AND \
       (SELECT COUNT(*) FROM dependencies d \
        INNER JOIN issues c ON c.id = d.issue_id \
        WHERE d.depends_on_id = i.id AND d.type = 'parent-child' \
          AND c.ephemeral = 0 AND c.status != 'closed') = 0, \
       'true', 'false'), '$')\
) AS payload, \
i.priority AS priority, \
i.created_at AS created_at, \
(SELECT COUNT(*) FROM dependencies d \
 INNER JOIN issues c ON c.id = d.issue_id \
 WHERE d.depends_on_id = i.id AND d.type = 'parent-child' \
   AND c.ephemeral = 0) AS child_count \
FROM issues i \
WHERE i.issue_type = 'epic' \
  AND i.status != 'closed' \
  AND i.ephemeral = 0 \
HAVING child_count > 0 \
ORDER BY priority ASC, created_at DESC\
) t"
  "SQL query for the `epic_status' operation.
Mirrors `bd epic status': returns all non-closed epics that have at
least one child, with `total_children', `closed_children', and an
`eligible_for_close' boolean computed as
`total_children > 0 AND closed_children == total_children'.")

(defconst beads-dolt-sql--freshness-sql
  "SELECT JSON_OBJECT(\
'issues_count', \
  (SELECT COUNT(*) FROM issues WHERE ephemeral = 0), \
'issues_max_updated', \
  (SELECT DATE_FORMAT(MAX(updated_at), '%Y-%m-%dT%H:%i:%sZ') \
   FROM issues WHERE ephemeral = 0), \
'labels_count', (SELECT COUNT(*) FROM labels), \
'deps_count', (SELECT COUNT(*) FROM dependencies), \
'deps_max_created', \
  (SELECT DATE_FORMAT(MAX(created_at), '%Y-%m-%dT%H:%i:%sZ') \
   FROM dependencies), \
'comments_count', (SELECT COUNT(*) FROM comments), \
'comments_max_created', \
  (SELECT DATE_FORMAT(MAX(created_at), '%Y-%m-%dT%H:%i:%sZ') FROM comments)\
) AS freshness"
  "Lightweight freshness token query for the `freshness' operation.
Returns counts and max timestamps across the four tables that drive
list-view display: issues, labels, dependencies, comments.  The
combination of count + max(timestamp) detects inserts, updates, and
deletes across each table at ~1 second precision, in a single round
trip.

Used by `beads-cache' to decide whether a cached issue list is still
valid without re-fetching the full list payload.")

(defconst beads-dolt-sql--stale-sql
  "SELECT JSON_ARRAYAGG(\
JSON_OBJECT(\
'id', i.id, \
'title', i.title, \
'description', i.description, \
'status', i.status, \
'priority', i.priority, \
'issue_type', i.issue_type, \
'owner', COALESCE(NULLIF(i.owner, ''), i.created_by), \
'assignee', i.assignee, \
'created_at', DATE_FORMAT(i.created_at, '%Y-%m-%dT%H:%i:%sZ'), \
'created_by', i.created_by, \
'updated_at', DATE_FORMAT(i.updated_at, '%Y-%m-%dT%H:%i:%sZ'), \
'started_at', IF(i.started_at IS NOT NULL, \
  DATE_FORMAT(i.started_at, '%Y-%m-%dT%H:%i:%sZ'), NULL), \
'closed_at', IF(i.closed_at IS NOT NULL, \
  DATE_FORMAT(i.closed_at, '%Y-%m-%dT%H:%i:%sZ'), NULL), \
'labels', COALESCE(\
  (SELECT JSON_ARRAYAGG(l.label) FROM labels l WHERE l.issue_id = i.id), \
  JSON_ARRAY()), \
'dependency_count', \
  (SELECT COUNT(*) FROM dependencies d1 \
   WHERE d1.issue_id = i.id AND d1.type != 'parent-child'), \
'dependent_count', \
  (SELECT COUNT(*) FROM dependencies d2 \
   WHERE d2.depends_on_id = i.id AND d2.type != 'parent-child'), \
'comment_count', \
  (SELECT COUNT(*) FROM comments c WHERE c.issue_id = i.id), \
'parent', \
  (SELECT d3.depends_on_id FROM dependencies d3 \
   WHERE d3.issue_id = i.id AND d3.type = 'parent-child' LIMIT 1)\
)\
) AS issues \
FROM issues i \
WHERE i.ephemeral = 0 \
  AND i.status IN ('open', 'in_progress', 'blocked') \
  AND i.updated_at < DATE_SUB(NOW(), INTERVAL ? DAY) \
ORDER BY i.priority ASC, i.created_at DESC"
  "SQL template for the `stale' operation.")

(defun beads-dolt-sql--normalize-json-value (value)
  "Normalize VALUE to the backend's public alist/list representation."
  (cond
   ((eq value :null) nil)
   ((hash-table-p value)
    (let (alist)
      (maphash (lambda (key val)
                 (push (cons (if (stringp key) (intern key) key)
                             (beads-dolt-sql--normalize-json-value val))
                       alist))
               value)
      (nreverse alist)))
   ((vectorp value)
    (mapcar #'beads-dolt-sql--normalize-json-value (append value nil)))
   ((and (consp value) (consp (car value)))
    (mapcar (lambda (entry)
              (cons (car entry)
                    (beads-dolt-sql--normalize-json-value (cdr entry))))
            value))
   ((listp value)
    (mapcar #'beads-dolt-sql--normalize-json-value value))
   (t value)))

(defun beads-dolt-sql--parse-json-output (raw)
  "Parse RAW JSON using the backend's public alist/list representation."
  (condition-case nil
      (with-temp-buffer
        (insert raw)
        (goto-char (point-min))
        (beads-dolt-sql--normalize-json-value (json-read)))
    (json-error
     (signal 'beads-backend-error
             (list (format "SQL query returned invalid JSON: %s" raw))))))

(defun beads-dolt-sql--native-mysql-available-p ()
  "Return non-nil when Lucius Chen's mysql.el package can be loaded."
  (beads-dolt-sql--ensure-vendored-mysql-load-path)
  (or (featurep 'mysql)
      (locate-library "mysql")))

(defun beads-dolt-sql--native-mysql-load ()
  "Load mysql.el if available."
  (beads-dolt-sql--ensure-vendored-mysql-load-path)
  (or (featurep 'mysql)
      (require 'mysql nil t)))

(defun beads-dolt-sql--native-mysql-disconnect ()
  "Disconnect and clear the native mysql.el connection, if any."
  (when beads-dolt-sql--native-mysql-conn
    (ignore-errors (mysql-disconnect beads-dolt-sql--native-mysql-conn)))
  (setq beads-dolt-sql--native-mysql-conn nil)
  (setq beads-dolt-sql--native-mysql-params nil))

(defun beads-dolt-sql--native-mysql-connect (dolt)
  "Open a native mysql.el connection to DOLT params."
  (unless (beads-dolt-sql--native-mysql-load)
    (signal 'beads-backend-error '("mysql.el is not available")))
  (let* ((host (alist-get 'host dolt "127.0.0.1"))
         (port (alist-get 'port dolt 3310))
         (user (alist-get 'user dolt "root"))
         (password (alist-get 'password dolt ""))
         (database (alist-get 'database dolt "beads_bdel")))
    (setq beads-dolt-sql--native-mysql-conn
          (mysql-connect :host host
                         :port port
                         :user user
                         :password password
                         :database database
                         :tls nil))
    (setq beads-dolt-sql--native-mysql-params dolt)
    beads-dolt-sql--native-mysql-conn))

(defun beads-dolt-sql--ensure-native-mysql-connected (dolt)
  "Return a live mysql.el connection for DOLT params."
  (if (and beads-dolt-sql--native-mysql-conn
           (equal beads-dolt-sql--native-mysql-params dolt))
      beads-dolt-sql--native-mysql-conn
    (beads-dolt-sql--native-mysql-disconnect)
    (beads-dolt-sql--native-mysql-connect dolt)))

(defun beads-dolt-sql--native-mysql-query (sql dolt)
  "Execute SQL against DOLT via mysql.el and parse the JSON result cell."
  (let* ((conn (beads-dolt-sql--ensure-native-mysql-connected dolt))
         (result (mysql-query conn sql))
         (rows (mysql-result-rows result))
         (cell (caar rows)))
    (cond
     ((stringp cell) (beads-dolt-sql--parse-json-output cell))
     ((or (vectorp cell) (listp cell) (hash-table-p cell))
      (beads-dolt-sql--normalize-json-value cell))
     ((null cell) nil)
     (t (signal 'beads-backend-error
                (list (format "SQL query returned unsupported value: %S" cell)))))))

(defun beads-backend-dolt-sql-stop-idle-session ()
  "Stop the persistent mysql.el SQL session after all beads buffers are closed."
  (beads-dolt-sql--native-mysql-disconnect))

(defun beads-dolt-sql--strip-banner (output)
  "Strip mariadb/mysql deprecation banners and non-error warnings from OUTPUT.
Removes lines that are client version banners (e.g. deprecated program name)
or ssl-verify-server-cert warnings, which are not SQL errors."
  (with-temp-buffer
    (insert output)
    (goto-char (point-min))
    (while (re-search-forward
            "^/.*: Deprecated program name.*\n\\|WARNING: option --ssl-verify-server-cert.*\n?"
            nil t)
      (replace-match ""))
    (string-trim (buffer-string))))

(defun beads-backend-dolt-sql--canonical-project-root (&optional project-root)
  "Return the canonical project root used to scope SQL connection state."
  (file-name-as-directory
   (expand-file-name
    (or project-root (beads-client--project-root) default-directory))))

(cl-defun beads-backend-dolt-sql--fetch-dolt-params (&optional project-root)
  "Fetch Dolt SQL server connection params from `bd dolt show --json'.
Returns nil and sets `beads-dolt-sql--available' to nil on failure.
Caches result for 60 seconds."
  (let ((root (beads-backend-dolt-sql--canonical-project-root project-root)))
    (when (and beads-dolt-sql--params
               beads-dolt-sql--params-time
               (or (null beads-dolt-sql--params-root)
                   (equal beads-dolt-sql--params-root root))
               (< (float-time (time-since beads-dolt-sql--params-time)) 60))
      (cl-return-from beads-backend-dolt-sql--fetch-dolt-params
        beads-dolt-sql--params))
    (let ((default-directory root))
      (ignore-errors
        (with-temp-buffer
          (let ((exit-code (call-process "bd" nil t nil
                                         "dolt" "show" "--json")))
            (goto-char (point-min))
            (if (zerop exit-code)
                (let ((parsed (json-read)))
                  (if (and (eq t (alist-get 'connection_ok parsed))
                           (equal "dolt" (alist-get 'backend parsed)))
                      (progn
                        (setq beads-dolt-sql--params parsed)
                        (setq beads-dolt-sql--params-time (current-time))
                        (setq beads-dolt-sql--params-root root)
                        (setq beads-dolt-sql--available t)
                        parsed)
                    (progn
                      (setq beads-dolt-sql--available nil)
                      nil)))
              (progn
                (setq beads-dolt-sql--available nil)
                nil))))))))

(cl-defun beads-backend-dolt-sql--available-p ()
  "Return non-nil if Dolt SQL transport is available."
  (unless beads-dolt-sql-enabled
    (cl-return-from beads-backend-dolt-sql--available-p nil))
  (unless beads-dolt-sql--available
    (cl-return-from beads-backend-dolt-sql--available-p nil))
  (unless (or (beads-dolt-sql--native-mysql-available-p)
              (executable-find "mariadb"))
    (cl-return-from beads-backend-dolt-sql--available-p nil))
  (and (beads-backend-dolt-sql--fetch-dolt-params) t))

(defun beads-backend-dolt-sql--mark-unavailable ()
  "Mark Dolt SQL transport as unavailable."
  (setq beads-dolt-sql--available nil))

(defun beads-backend-dolt-sql--one-shot-mariadb (sql-str dolt)
  (let* ((host (alist-get 'host dolt "127.0.0.1"))
         (port (number-to-string (alist-get 'port dolt 3310)))
         (user (alist-get 'user dolt "root"))
         (database (alist-get 'database dolt "beads_bdel")))
    (with-temp-buffer
       (let* ((default-directory temporary-file-directory)
             (exit-code (apply #'call-process "mariadb" nil (list t nil) nil (list "-h" host "-P" port "-u" user database "--batch" "--skip-column-names" "--raw" "-e" sql-str))))
        (goto-char (point-min))
        (unless (zerop exit-code) (signal 'beads-backend-error (list (format "mariadb failed with exit code %d: %s" exit-code (string-trim (buffer-string))))))
        (goto-char (point-min))
        (beads-dolt-sql--parse-json-output
         (beads-dolt-sql--strip-banner (buffer-string)))))))

(defun beads-backend-dolt-sql--execute-sql (sql &optional params project-root)
  (let ((dolt (beads-backend-dolt-sql--fetch-dolt-params project-root)))
    (unless dolt (signal 'beads-backend-error '("Dolt SQL server not available")))
    (let ((sql-str sql))
      (when params (dolist (param params) (setq sql-str (replace-regexp-in-string "\\?" (if (stringp param) (concat "'" (replace-regexp-in-string "'" "''" param) "'") (format "%s" param)) sql-str t t))))
      (cond
       ((beads-dolt-sql--native-mysql-available-p)
        (condition-case _err
            (beads-dolt-sql--native-mysql-query sql-str dolt)
          (error
           (beads-dolt-sql--native-mysql-disconnect)
           (if (executable-find "mariadb")
               (beads-backend-dolt-sql--one-shot-mariadb sql-str dolt)
             (signal 'beads-backend-error
                     '("mysql.el query failed and the mariadb client is not on PATH; install it (e.g. `brew install mariadb')"))))))
       ((executable-find "mariadb")
        (beads-backend-dolt-sql--one-shot-mariadb sql-str dolt))
       (t
        (signal 'beads-backend-error
                '("Neither mysql.el nor the mariadb client is available; install mariadb (e.g. `brew install mariadb')")))))))

(defun beads-backend-dolt-sql--execute-list (_args project-root)
  "Execute `list' operation via direct SQL.
Uses `beads-dolt-sql--list-lite-sql' when `beads-dolt-sql-list-lite'
is non-nil (the default), otherwise falls back to the full
`beads-dolt-sql--list-sql' that mirrors `bd list --json' exactly.

The SQL list contract is all normal issues (`ephemeral = 0'), including
closed issues.  That is the same status set requested from the bd CLI
backend when callers pass `:all t'."
  (beads-backend-dolt-sql--execute-sql
   (if beads-dolt-sql-list-lite
       beads-dolt-sql--list-lite-sql
     beads-dolt-sql--list-sql)
   nil project-root))

(defun beads-backend-dolt-sql--execute-show (args project-root)
  "Execute `show' operation via direct SQL."
  (let ((id (alist-get 'id args)))
    (unless id
      (signal 'beads-backend-error '("show requires an id")))
    (beads-backend-dolt-sql--execute-sql beads-dolt-sql--show-sql
                                         (list id) project-root)))

(defun beads-backend-dolt-sql--execute-stats (_args project-root)
  "Execute `stats' operation via direct SQL."
  (beads-backend-dolt-sql--execute-sql beads-dolt-sql--stats-sql
                                       nil project-root))

(defun beads-backend-dolt-sql--execute-ready (_args project-root)
  "Execute `ready' operation via direct SQL."
  (beads-backend-dolt-sql--execute-sql beads-dolt-sql--ready-sql
                                       nil project-root))

(defun beads-backend-dolt-sql--execute-count (_args project-root)
  "Execute `count' operation via direct SQL."
  (beads-backend-dolt-sql--execute-sql beads-dolt-sql--count-sql
                                       nil project-root))

(defun beads-backend-dolt-sql--execute-stale (args project-root)
  "Execute `stale' operation via direct SQL."
  (let ((days (or (alist-get 'days args) 14)))
    (beads-backend-dolt-sql--execute-sql beads-dolt-sql--stale-sql
                                         (list days) project-root)))

(defun beads-backend-dolt-sql--execute-epic-status (_args project-root)
  "Execute `epic_status' operation via direct SQL."
  (beads-backend-dolt-sql--execute-sql beads-dolt-sql--epic-status-sql
                                       nil project-root))

(defun beads-backend-dolt-sql--execute-freshness (_args project-root)
  "Execute `freshness' operation via direct SQL.
Returns a small alist (counts + max timestamps) used as a cache token."
  (beads-backend-dolt-sql--execute-sql beads-dolt-sql--freshness-sql
                                       nil project-root))

(defun beads-backend-dolt-sql--operation-to-sql-fn (operation)
  "Return the SQL executor function for OPERATION, or nil."
  (pcase operation
    ("list" #'beads-backend-dolt-sql--execute-list)
    ("show" #'beads-backend-dolt-sql--execute-show)
    ("stats" #'beads-backend-dolt-sql--execute-stats)
    ("ready" #'beads-backend-dolt-sql--execute-ready)
    ("count" #'beads-backend-dolt-sql--execute-count)
    ("stale" #'beads-backend-dolt-sql--execute-stale)
    ("epic_status" #'beads-backend-dolt-sql--execute-epic-status)
    ("freshness" #'beads-backend-dolt-sql--execute-freshness)))

(defun beads-backend-dolt-sql--check ()
  "Check if Dolt SQL transport is available and operational.
Returns t if ready, signals an error otherwise."
  (interactive)
  (unless beads-dolt-sql-enabled
    (if (called-interactively-p 'any)
        (message "Dolt SQL transport is disabled (beads-dolt-sql-enabled is nil)")
      (signal 'beads-backend-error '("Dolt SQL transport is disabled"))))
  (unless (or (beads-dolt-sql--native-mysql-available-p)
              (executable-find "mariadb"))
    (if (called-interactively-p 'any)
        (message "mysql.el or mariadb client not found; install mariadb (e.g. `brew install mariadb')")
      (signal 'beads-backend-error
              '("mysql.el or mariadb client not found; install mariadb (e.g. `brew install mariadb')"))))
  (let ((params (beads-backend-dolt-sql--fetch-dolt-params)))
    (unless params
      (if (called-interactively-p 'any)
          (message "Dolt SQL server not reachable")
        (signal 'beads-backend-error '("Dolt SQL server not reachable"))))
    (if (called-interactively-p 'any)
        (message "Dolt SQL transport available: %s:%s/%s as %s"
                 (alist-get 'host params)
                 (alist-get 'port params)
                 (alist-get 'database params)
                 (alist-get 'user params))
      t)))

(defun beads-backend-dolt-sql--executor (operation args project-root)
  "Execute OPERATION via direct Dolt SQL, falling back to bd CLI.
This is the executor function set on the bd-dolt-sql backend's
`executor' slot."
  (if-let ((sql-fn (beads-backend-dolt-sql--operation-to-sql-fn operation)))
      ;; SQL-mapped operation: try SQL first, fall back to CLI
      (condition-case sql-err
          (funcall sql-fn args project-root)
        (error
         (beads-backend-dolt-sql--mark-unavailable)
         (beads-backend-dolt-sql--execute-fallback
          operation args project-root sql-err)))
    ;; Not mapped to SQL: use CLI directly
    (beads-backend-dolt-sql--execute-fallback
     operation args project-root nil)))

(defun beads-backend-dolt-sql--execute-fallback (operation args project-root
                                                  &optional _previous-error)
  "Execute OPERATION via the regular bd CLI subprocess.
PREVIOUS-ERROR is the error from the failed SQL attempt, for context."
  (let* ((bd-backend (beads-backend--lookup "bd"))
         (program (or beads-backend-dolt-sql--cli-fallback-program
                      (executable-find (beads-backend-cli-program bd-backend)))))
    (unless program
      (signal 'beads-backend-error '("bd CLI not found for fallback")))
    (setq beads-backend-dolt-sql--cli-fallback-program program)
    (let ((op-args (funcall (beads-backend-op-to-cli-args bd-backend)
                            operation args))
          (extra (when-let ((fn (beads-backend-cli-extra-flags bd-backend)))
                   (funcall fn operation)))
          (cmd-args nil))
      (setq cmd-args (append extra op-args '("--json")))
      (with-temp-buffer
        (let* ((default-directory (or project-root default-directory))
               (exit-code (apply #'call-process program nil t nil cmd-args)))
          (unless (zerop exit-code)
            (signal 'beads-backend-error
                    (list (format "bd CLI failed with exit code %d: %s"
                                  exit-code
                                  (string-trim (buffer-string))))))
          (goto-char (point-min))
          (condition-case nil
              (let ((output (json-read)))
                (if (vectorp output) (append output nil) output))
            (json-error
             (signal 'beads-backend-error
                     (list (format "bd CLI returned invalid JSON: %s"
                                   (buffer-string)))))))))))

(defconst beads-backend-dolt-sql
  (make-beads-backend
   :name "bd-dolt-sql"
   :cli-program "bd"
   :supported-ops '("list" "show" "ready" "create" "update" "update_bulk"
                     "close" "close_bulk"
                     "delete" "stats" "count" "dep_add" "dep_remove" "dep_tree"
                     "label_add" "label_remove" "types"
                     "config_get" "config_set" "config_unset"
                     "duplicates" "duplicate"
                     "comments-add" "lint" "orphans" "stale" "epic_status"
                     "freshness")
                     :op-to-cli-args #'beads-backend-bd--operation-to-cli-args
   :cli-extra-flags #'beads-backend-bd--cli-extra-flags
   :executor #'beads-backend-dolt-sql--executor)
  "Backend for direct Dolt SQL transport with bd CLI fallback.")

(declare-function beads-backend-bd--operation-to-cli-args "beads-backend-bd")
(declare-function beads-backend-bd--cli-extra-flags "beads-backend-bd")
(declare-function mysql-connect "mysql")
(declare-function mysql-disconnect "mysql")
(declare-function mysql-query "mysql")
(declare-function mysql-result-rows "mysql")

(defun beads-backend-dolt-sql--auto-detect-advice (orig-fun &rest args)
  "Advice for `beads-backend--auto-detect' to prefer SQL transport.
When `beads-dolt-sql-enabled' is non-nil and `bd' is available,
returns the bd-dolt-sql backend.  The backend itself validates SQL
availability per operation and falls back to `bd' when needed."
  (if (and beads-dolt-sql-enabled (executable-find "bd"))
      (or (beads-backend--lookup "bd-dolt-sql")
          (apply orig-fun args))
    (apply orig-fun args)))

(defun beads-backend-dolt-sql--install-default ()
  "Register Dolt SQL backend and install auto-detect advice."
  (beads-backend-register beads-backend-dolt-sql)
  (unless (advice-member-p #'beads-backend-dolt-sql--auto-detect-advice
                           'beads-backend--auto-detect)
    (advice-add 'beads-backend--auto-detect
                :around #'beads-backend-dolt-sql--auto-detect-advice)))

;;;###autoload
(defun beads-backend-dolt-sql-activate ()
  "Activate Dolt SQL transport for the current Emacs session."
  (interactive)
  (setq beads-dolt-sql-enabled t)
  (setq beads-dolt-sql--available t)
  (setq beads-dolt-sql--params nil)
  (setq beads-dolt-sql--params-time nil)
  (setq beads-dolt-sql--params-root nil)
  (beads-dolt-sql--native-mysql-disconnect)
  (beads-backend-dolt-sql--install-default)
  (beads-backend-clear-cache)
  (message "Dolt SQL transport activated (beads-dolt-sql)"))

;;;###autoload
(defun beads-backend-dolt-sql-deactivate ()
  "Deactivate Dolt SQL transport, reverting to bd CLI for all operations."
  (interactive)
  (setq beads-dolt-sql-enabled nil)
  (setq beads-dolt-sql--available nil)
  (setq beads-dolt-sql--params-root nil)
  (beads-dolt-sql--native-mysql-disconnect)
  (advice-remove 'beads-backend--auto-detect
                 #'beads-backend-dolt-sql--auto-detect-advice)
  (beads-backend-clear-cache)
  (message "Dolt SQL transport deactivated"))

(beads-backend-dolt-sql--install-default)

(provide 'beads-backend-dolt-sql)

;;; beads-backend-dolt-sql.el ends here
