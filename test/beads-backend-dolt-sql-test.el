;;; beads-backend-dolt-sql-test.el --- Tests for beads-backend-dolt-sql.el -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the Dolt SQL transport backend.  Uses `cl-letf' mocking
;; for unit tests and a live integration section guarded by
;; `beads-backend-dolt-sql--available-p'.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'beads-backend)
(require 'beads-backend-bd)
(require 'beads-backend-dolt-sql)
(require 'beads-test-helpers)

;;; Helpers

(defun beads-dolt-sql-test--dest-buffer (dest)
  "Resolve a `call-process' DEST argument to the buffer to write into.
Handles `t' (current buffer), a buffer/buffer-name, and the
\\(STDOUT STDERR\\) form used by `--one-shot-mariadb', where STDOUT
itself may be `t' or a buffer."
  (let ((stdout (cond ((consp dest) (car dest))
                      (t dest))))
    (cond ((eq stdout t) (current-buffer))
          ((bufferp stdout) stdout)
          ((stringp stdout) (get-buffer stdout))
          (t nil))))

(defmacro beads-dolt-sql-test--with-mocks (mariadb-output &rest body)
  "Eval BODY with `call-process' mocked to return MARIADB-OUTPUT.
MARIADB-OUTPUT is inserted into the temp buffer on each call-process
targeting \"mariadb\".  Calls targeting \"bd\" pass through."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'call-process)
              (lambda (program &optional _infile dest _display &rest _)
                (if (equal program "mariadb")
                    (let ((buf (beads-dolt-sql-test--dest-buffer dest)))
                      (when buf
                        (with-current-buffer buf
                          (insert ,mariadb-output)))
                      0)
                  ;; Fake bd success
                  0))))
     ,@body))

(defmacro beads-dolt-sql-test--with-bd-dolt-show (json-output &rest body)
  "Eval BODY with `bd dolt show --json' returning JSON-OUTPUT."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'call-process)
               (lambda (program &optional _infile dest _display &rest all-args)
                 (if (and (equal program "bd")
                          (member "dolt" all-args)
                          (member "show" all-args)
                          (member "--json" all-args))
                    (let ((buf (if (eq dest t)
                                   (current-buffer)
                                 (car-safe dest))))
                      (when buf
                        (with-current-buffer buf
                          (insert ,json-output)))
                      0)
                  0))))
     ,@body))

(defun beads-dolt-sql-test--live-dolt-sql-available-p ()
  "Return non-nil when the current project has live Dolt SQL access."
  (and (executable-find "mariadb")
       (ignore-errors
         (require 'beads-client)
         (let ((default-directory
                (or (beads-client--project-root) default-directory)))
           (zerop (call-process "bd" nil nil nil "dolt" "status"))))))

(defun beads-dolt-sql-test--with-clean-state (body-fn)
  "Call BODY-FN with Dolt SQL state clean (enabled, available, fresh cache).
Pre-populates `beads-dolt-sql--params' so `--fetch-dolt-params' returns
from cache and never invokes the real `bd dolt show'.  Mocks
`executable-find' to report mariadb+bd present so `--execute-sql'
takes the one-shot mariadb branch (which uses `call-process',
easy to mock)."
  (let ((beads-dolt-sql--params '((backend . "dolt")
                                  (connection_ok . t)
                                  (database . "testdb")
                                  (host . "127.0.0.1")
                                  (port . 3310)
                                  (user . "root")))
        (beads-dolt-sql--params-time (current-time))
        (beads-dolt-sql--params-root "/fake/project/")
        (beads-dolt-sql--available t)
        (beads-dolt-sql-enabled t))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (cmd)
                 (cond ((equal cmd "mariadb") "/usr/bin/mariadb")
                       ((equal cmd "bd") "/usr/bin/bd")
                       (t nil))))
              ((symbol-function 'locate-library)
               (lambda (_library) nil))
              ((symbol-function 'beads-dolt-sql--native-mysql-available-p)
               (lambda () nil))
              ((symbol-function 'beads-client--project-root)
               (lambda () "/fake/project/")))
      (funcall body-fn))))

;;; Struct / registration tests

(ert-deftest beads-dolt-sql-test-backend-struct ()
  "Test the bd-dolt-sql backend struct fields."
  (should (beads-backend-p beads-backend-dolt-sql))
  (should (equal (beads-backend-name beads-backend-dolt-sql) "bd-dolt-sql"))
  (should (equal (beads-backend-cli-program beads-backend-dolt-sql) "bd"))
  (should (functionp (beads-backend-executor beads-backend-dolt-sql))))

(ert-deftest beads-dolt-sql-test-enabled-by-default ()
  "Test Dolt SQL transport is enabled by default."
  (should (eval (car (get 'beads-dolt-sql-enabled 'standard-value)) t)))

(ert-deftest beads-dolt-sql-test-registered-after-activate ()
  "Test backend is registered after activate."
  (let ((beads-backend--registry beads-backend--registry))
    (beads-backend-dolt-sql-activate)
    (should (beads-backend--lookup "bd-dolt-sql"))
    (beads-backend-dolt-sql-deactivate)))

(ert-deftest beads-dolt-sql-test-deactivate-removes-advice ()
  "Test deactivate removes advice from auto-detect."
  (beads-backend-dolt-sql-activate)
  (beads-backend-dolt-sql-deactivate)
  (should-not (advice-member-p #'beads-backend-dolt-sql--auto-detect-advice
                               'beads-backend--auto-detect)))

;;; Supported operations tests

(ert-deftest beads-dolt-sql-test-supports-all-bd-ops ()
  "Test dolt-sql backend supports same ops as bd backend."
  (let ((bd-ops (beads-backend-supported-ops (beads-backend--lookup "bd")))
        (sql-ops (beads-backend-supported-ops beads-backend-dolt-sql)))
    (dolist (op bd-ops)
      (should (member op sql-ops)))))

(ert-deftest beads-dolt-sql-test-sql-mapped-ops ()
  "Test the SQL function lookup for mapped operations."
  (dolist (op '("list" "show" "stats" "ready" "count" "stale"))
    (should (functionp (beads-backend-dolt-sql--operation-to-sql-fn op)))))

(ert-deftest beads-dolt-sql-test-non-sql-ops-return-nil ()
  "Test that non-SQL operations return nil from operation-to-sql-fn."
  (dolist (op '("create" "update" "close" "delete" "types" "lint" "orphans"))
    (should-not (beads-backend-dolt-sql--operation-to-sql-fn op))))

;;; Connection params tests

(ert-deftest beads-dolt-sql-test-fetch-dolt-params-success ()
  "Test fetching Dolt params on success."
  (beads-dolt-sql-test--with-bd-dolt-show
   "{\"backend\":\"dolt\",\"connection_ok\":true,\"database\":\"testdb\",\"host\":\"127.0.0.1\",\"port\":3310,\"user\":\"root\"}"
   (let ((beads-dolt-sql--params nil)
         (beads-dolt-sql--params-time nil)
         (beads-dolt-sql--available t))
     (cl-letf (((symbol-function 'beads-client--project-root)
                (lambda () "/fake/project/")))
       (let ((result (beads-backend-dolt-sql--fetch-dolt-params)))
         (should result)
         (should (equal (alist-get 'database result) "testdb"))
         (should (equal (alist-get 'host result) "127.0.0.1"))
         (should (= (alist-get 'port result) 3310)))))))

(ert-deftest beads-dolt-sql-test-fetch-dolt-params-connection-false ()
  "Test fetch marks unavailable when connection_ok is false."
  (beads-dolt-sql-test--with-bd-dolt-show
   "{\"backend\":\"dolt\",\"connection_ok\":false,\"database\":\"testdb\",\"host\":\"127.0.0.1\",\"port\":3310,\"user\":\"root\"}"
   (let ((beads-dolt-sql--params nil)
         (beads-dolt-sql--params-time nil)
         (beads-dolt-sql--available t))
     (cl-letf (((symbol-function 'beads-client--project-root)
                (lambda () "/fake/project/")))
       (should-not (beads-backend-dolt-sql--fetch-dolt-params))
       (should-not beads-dolt-sql--available)))))

(ert-deftest beads-dolt-sql-test-fetch-dolt-params-cached ()
  "Test params are cached for 60 seconds."
  (beads-dolt-sql-test--with-bd-dolt-show
   "{\"backend\":\"dolt\",\"connection_ok\":true,\"database\":\"testdb\",\"host\":\"127.0.0.1\",\"port\":3310,\"user\":\"root\"}"
   (let ((beads-dolt-sql--params '((database . "cached") (host . "x")))
         (beads-dolt-sql--params-time (current-time)) ;; fresh cache
         (beads-dolt-sql--params-root "/fake/project/")
         (beads-dolt-sql--available t))
     (cl-letf (((symbol-function 'beads-client--project-root)
                (lambda () "/fake/project/")))
       (let ((result (beads-backend-dolt-sql--fetch-dolt-params)))
         (should (equal (alist-get 'database result) "cached")))))))

(ert-deftest beads-dolt-sql-test-fetch-dolt-params-cache-is-project-scoped ()
  "Fresh params cached for one project are not reused for another."
  (let ((beads-dolt-sql--params nil)
        (beads-dolt-sql--params-time nil)
        (beads-dolt-sql--params-root nil)
        (beads-dolt-sql--available t)
        (current-root "/fake/project-a/")
        calls)
    (cl-letf (((symbol-function 'beads-client--project-root)
               (lambda () current-root))
              ((symbol-function 'call-process)
               (lambda (program &optional _infile dest _display &rest all-args)
                 (if (and (equal program "bd")
                          (member "dolt" all-args)
                          (member "show" all-args)
                          (member "--json" all-args))
                     (let ((buf (if (eq dest t)
                                    (current-buffer)
                                  (car-safe dest)))
                           (db (if (equal default-directory "/fake/project-a/")
                                   "db_a"
                                 "db_b")))
                       (push default-directory calls)
                       (when buf
                         (with-current-buffer buf
                           (insert (format "{\"backend\":\"dolt\",\"connection_ok\":true,\"database\":\"%s\",\"host\":\"127.0.0.1\",\"port\":3310,\"user\":\"root\"}"
                                           db))))
                       0)
                   0))))
      (let ((result-a (beads-backend-dolt-sql--fetch-dolt-params)))
        (should (equal (alist-get 'database result-a) "db_a")))
      (let ((cached-a (beads-backend-dolt-sql--fetch-dolt-params)))
        (should (equal (alist-get 'database cached-a) "db_a")))
      (setq current-root "/fake/project-b/")
      (let ((result-b (beads-backend-dolt-sql--fetch-dolt-params)))
        (should (equal (alist-get 'database result-b) "db_b")))
      (should (equal (nreverse calls)
                     '("/fake/project-a/" "/fake/project-b/"))))))

(ert-deftest beads-dolt-sql-test-fetch-dolt-params-expired-cache ()
  "Test expired cache triggers refetch."
  (beads-dolt-sql-test--with-bd-dolt-show
   "{\"backend\":\"dolt\",\"connection_ok\":true,\"database\":\"fresh\",\"host\":\"127.0.0.1\",\"port\":3310,\"user\":\"root\"}"
   (let ((beads-dolt-sql--params '((database . "stale") (host . "x")))
         (beads-dolt-sql--params-time (time-subtract (current-time) 120))
         (beads-dolt-sql--params-root "/fake/project/")
         (beads-dolt-sql--available t))
     (cl-letf (((symbol-function 'beads-client--project-root)
                (lambda () "/fake/project/")))
       (let ((result (beads-backend-dolt-sql--fetch-dolt-params)))
         (should (equal (alist-get 'database result) "fresh")))))))

;;; Availability tests

(ert-deftest beads-dolt-sql-test-available-when-enabled ()
  "Test available-p returns t when enabled and mariadb present."
  (beads-dolt-sql-test--with-bd-dolt-show
   "{\"backend\":\"dolt\",\"connection_ok\":true,\"database\":\"db\",\"host\":\"127.0.0.1\",\"port\":3310,\"user\":\"root\"}"
   (let ((beads-dolt-sql--params nil)
         (beads-dolt-sql--params-time nil)
         (beads-dolt-sql--available t)
         (beads-dolt-sql-enabled t))
     (cl-letf (((symbol-function 'executable-find)
                (lambda (cmd)
                  (cond ((equal cmd "mariadb") "/usr/bin/mariadb")
                        (t nil))))
               ((symbol-function 'beads-client--project-root)
                (lambda () "/fake/project/")))
       (should (beads-backend-dolt-sql--available-p))))))

(ert-deftest beads-dolt-sql-test-unavailable-when-disabled ()
  "Test available-p returns nil when disabled."
  (let ((beads-dolt-sql-enabled nil)
        (beads-dolt-sql--available t))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (cmd)
                 (cond ((equal cmd "mariadb") "/usr/bin/mariadb")
                       (t nil)))))
      (should-not (beads-backend-dolt-sql--available-p)))))

(ert-deftest beads-dolt-sql-test-unavailable-when-marked-down ()
  "Test available-p returns nil when marked unavailable."
  (let ((beads-dolt-sql-enabled t)
        (beads-dolt-sql--available nil))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (cmd)
                 (cond ((equal cmd "mariadb") "/usr/bin/mariadb")
                       (t nil)))))
      (should-not (beads-backend-dolt-sql--available-p)))))

(ert-deftest beads-dolt-sql-test-unavailable-no-mariadb ()
  "Test available-p returns nil when no SQL transport is found."
  (let ((beads-dolt-sql-enabled t)
        (beads-dolt-sql--available t))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_cmd) nil))
              ((symbol-function 'locate-library)
               (lambda (_library) nil))
              ((symbol-function 'beads-dolt-sql--native-mysql-available-p)
               (lambda () nil)))
      (should-not (beads-backend-dolt-sql--available-p)))))

(ert-deftest beads-dolt-sql-test-mark-unavailable ()
  "Test mark-unavailable sets the flag."
  (let ((beads-dolt-sql--available t))
    (beads-backend-dolt-sql--mark-unavailable)
    (should-not beads-dolt-sql--available)))

;;; SQL execution tests

(ert-deftest beads-dolt-sql-test-execute-sql-returns-json ()
  "Test execute-sql parses JSON output from mariadb."
  (beads-dolt-sql-test--with-clean-state
   (lambda ()
     (cl-letf (((symbol-function 'call-process)
                (lambda (program &optional _infile dest _display &rest _)
                  (if (equal program "mariadb")
                      (let ((buf (beads-dolt-sql-test--dest-buffer dest)))
                        (when buf
                          (with-current-buffer buf
                            (insert "[{\"id\":\"t1\",\"title\":\"test\"}]")))
                        0)
                    0))))
       (let ((result (beads-backend-dolt-sql--execute-sql "SELECT 1")))
         (should (listp result))
         (should (= (length result) 1))
         (should (equal (alist-get 'id (car result)) "t1")))))))

(ert-deftest beads-dolt-sql-test-execute-sql-no-dolt-params ()
  "Test execute-sql signals when params unavailable."
  (let ((beads-dolt-sql--params nil)
        (beads-dolt-sql--params-time nil)
        (beads-dolt-sql--available nil))
    (cl-letf (((symbol-function 'beads-backend-dolt-sql--fetch-dolt-params)
               (lambda (&optional _project-root) nil)))
      (should-error (beads-backend-dolt-sql--execute-sql "SELECT 1")
                    :type 'beads-backend-error))))

(ert-deftest beads-dolt-sql-test-execute-sql-mariadb-fails ()
  "Test execute-sql signals on non-zero mariadb exit."
  (beads-dolt-sql-test--with-bd-dolt-show
   "{\"backend\":\"dolt\",\"connection_ok\":true,\"database\":\"db\",\"host\":\"127.0.0.1\",\"port\":3310,\"user\":\"root\"}"
   (let ((beads-dolt-sql--params nil)
         (beads-dolt-sql--params-time nil)
         (beads-dolt-sql--available t))
     (cl-letf (((symbol-function 'beads-client--project-root)
                (lambda () "/fake/project/"))
               ((symbol-function 'call-process)
                 (lambda (program &optional _infile dest _display &rest _)
                   (if (equal program "mariadb")
                       (let ((buf (beads-dolt-sql-test--dest-buffer dest)))
                         (when buf
                           (with-current-buffer buf
                             (insert "ERROR: table not found")))
                         1)
                     0))))
       (should-error (beads-backend-dolt-sql--execute-sql "BOGUS")
                     :type 'beads-backend-error)))))

(ert-deftest beads-dolt-sql-test-execute-sql-invalid-json ()
  "Test execute-sql signals on invalid JSON from mariadb."
  (beads-dolt-sql-test--with-bd-dolt-show
   "{\"backend\":\"dolt\",\"connection_ok\":true,\"database\":\"db\",\"host\":\"127.0.0.1\",\"port\":3310,\"user\":\"root\"}"
   (let ((beads-dolt-sql--params nil)
         (beads-dolt-sql--params-time nil)
         (beads-dolt-sql--available t))
     (cl-letf (((symbol-function 'beads-client--project-root)
                (lambda () "/fake/project/"))
               ((symbol-function 'call-process)
                (lambda (program &optional _infile dest _display &rest _)
                  (if (equal program "mariadb")
                      (let ((buf (beads-dolt-sql-test--dest-buffer dest)))
                        (when buf
                          (with-current-buffer buf
                            (insert "not json at all")))
                        0)
                    0))))
       (should-error (beads-backend-dolt-sql--execute-sql "SELECT 1")
                     :type 'beads-backend-error)))))

(ert-deftest beads-dolt-sql-test-execute-sql-param-replacement ()
  "Test that ? placeholders are replaced with escaped values."
  (let ((captured-sql nil))
    (beads-dolt-sql-test--with-clean-state
     (lambda ()
       (cl-letf (((symbol-function 'call-process)
                  (lambda (program &optional _infile dest _display &rest args)
                    (if (equal program "mariadb")
                        (let ((buf (beads-dolt-sql-test--dest-buffer dest)))
                          (setq captured-sql (car (last args)))
                          (when buf
                            (with-current-buffer buf
                              (insert "[]")))
                          0)
                      0))))
         (beads-backend-dolt-sql--execute-sql "WHERE id = ?" '("test-1"))
         (should (string-match "test-1" captured-sql))
         (should-not (string-match "\\?" captured-sql)))))))

(ert-deftest beads-dolt-sql-test-native-mysql-execute-sql-returns-json ()
  "Test execute-sql prefers mysql.el when it is available."
  (let ((called-native nil))
    (beads-dolt-sql-test--with-clean-state
     (lambda ()
       (cl-letf (((symbol-function 'beads-dolt-sql--native-mysql-available-p)
                  (lambda () t))
                 ((symbol-function 'beads-dolt-sql--native-mysql-query)
                  (lambda (sql _dolt)
                    (setq called-native sql)
                    (beads-dolt-sql--parse-json-output
                     "[{\"id\":\"native-1\",\"title\":\"native\"}]"))))
         (let ((result (beads-backend-dolt-sql--execute-sql "SELECT 1")))
           (should called-native)
           (should (equal (alist-get 'id (car result)) "native-1"))))))))

(ert-deftest beads-dolt-sql-test-native-mysql-normalizes-hash-json ()
  "Test mysql.el-parsed hash-table JSON is converted to alists."
  (let ((issue (make-hash-table :test 'equal)))
    (puthash "id" "native-1" issue)
    (puthash "priority" 1 issue)
    (let ((result (beads-dolt-sql--normalize-json-value (vector issue))))
      (should (listp result))
      (should (equal (alist-get 'id (car result)) "native-1"))
      (should (= (alist-get 'priority (car result)) 1)))))

;;; Operation-specific tests

(ert-deftest beads-dolt-sql-test-execute-show-requires-id ()
  "Test show signals without an id."
  (should-error (beads-backend-dolt-sql--execute-show '() nil)
                :type 'beads-backend-error))

(ert-deftest beads-dolt-sql-test-execute-list-returns-array ()
  "Test list returns a plain list."
  (beads-dolt-sql-test--with-mocks
   "[{\"id\":\"a\",\"title\":\"one\"},{\"id\":\"b\",\"title\":\"two\"}]"
   (beads-dolt-sql-test--with-clean-state
    (lambda ()
      (let ((result (beads-backend-dolt-sql--execute-list nil nil)))
        (should (listp result))
        (should (= (length result) 2))
        (should (equal (alist-get 'id (car result)) "a"))
        (should (equal (alist-get 'id (cadr result)) "b")))))))

(ert-deftest beads-dolt-sql-test-list-lite-sql-omits-heavy-fields ()
  "The lite list query must omit description and the dependencies array,
but keep dependency_count, dependent_count, comment_count, and parent
(see bdel-057)."
  (let ((sql beads-dolt-sql--list-lite-sql))
    (should (stringp sql))
    ;; Heavy fields removed.
    (should-not (string-match-p "'description'" sql))
    (should-not (string-match-p "'dependencies'" sql))
    ;; Cheap counts and parent retained.
    (should (string-match-p "'dependency_count'" sql))
    (should (string-match-p "'dependent_count'" sql))
    (should (string-match-p "'comment_count'" sql))
    (should (string-match-p "'parent'" sql))
    (should (string-match-p "'labels'" sql))))

(ert-deftest beads-dolt-sql-test-list-sql-contract-is-all-non-ephemeral ()
  "The SQL list path is already the all-normal-issues contract.
It filters out ephemeral issues but does not filter by status, so it
includes closed issues like `bd list --all'."
  (dolist (sql (list beads-dolt-sql--list-sql
                     beads-dolt-sql--list-lite-sql))
    (should (string-match-p "WHERE i\\.ephemeral = 0" sql))
    (should-not (string-match-p "i\\.status[[:space:]]*=" sql))
    (should-not (string-match-p "i\\.status[[:space:]]+IN" sql))))

(ert-deftest beads-dolt-sql-test-parent-subquery-uses-dependency-source ()
  "The SQL `parent' field must return the issue this issue depends on.
For parent-child edges, `issue_id' is the child and `depends_on_id' is
the parent; reversing that shows a child as an epic's parent."
  (let ((correct-parent-subquery
         "SELECT d3\\.depends_on_id FROM dependencies d3[[:space:]]+WHERE d3\\.issue_id = i\\.id AND d3\\.type = 'parent-child'")
        (reversed-parent-subquery
         "SELECT d3\\.issue_id FROM dependencies d3[[:space:]]+WHERE d3\\.depends_on_id = i\\.id AND d3\\.type = 'parent-child'"))
    (dolist (sql (list beads-dolt-sql--list-sql
                       beads-dolt-sql--list-lite-sql
                       beads-dolt-sql--show-sql
                       beads-dolt-sql--ready-sql
                       beads-dolt-sql--stale-sql))
      (should (string-match-p correct-parent-subquery sql))
      (should-not (string-match-p reversed-parent-subquery sql)))))

(ert-deftest beads-dolt-sql-test-execute-list-selects-lite-by-default ()
  "`beads-backend-dolt-sql--execute-list' uses the lite SQL when
`beads-dolt-sql-list-lite' is non-nil and the full SQL otherwise."
  (let (captured)
    (cl-letf (((symbol-function 'beads-backend-dolt-sql--execute-sql)
               (lambda (sql &rest _)
                 (setq captured sql)
                 nil)))
      (let ((beads-dolt-sql-list-lite t))
        (beads-backend-dolt-sql--execute-list nil nil)
        (should (eq captured beads-dolt-sql--list-lite-sql)))
      (let ((beads-dolt-sql-list-lite nil))
        (beads-backend-dolt-sql--execute-list nil nil)
        (should (eq captured beads-dolt-sql--list-sql))))))

(ert-deftest beads-dolt-sql-test-execute-stats-returns-summary ()
  "Test stats returns summary alist."
  (beads-dolt-sql-test--with-mocks
   "{\"schema_version\":1,\"summary\":{\"total_issues\":42,\"open_issues\":10,\"closed_issues\":30,\"ready_issues\":5}}"
   (beads-dolt-sql-test--with-clean-state
    (lambda ()
      (let ((result (beads-backend-dolt-sql--execute-stats nil nil)))
        (should (alist-get 'summary result))
        (let ((s (alist-get 'summary result)))
          (should (= (alist-get 'total_issues s) 42))
          (should (= (alist-get 'open_issues s) 10))
          (should (= (alist-get 'closed_issues s) 30))
          (should (= (alist-get 'ready_issues s) 5))))))))

(ert-deftest beads-dolt-sql-test-execute-count-returns-count ()
  "Test count returns count alist."
  (beads-dolt-sql-test--with-mocks
   "{\"count\":99}"
   (beads-dolt-sql-test--with-clean-state
    (lambda ()
      (let ((result (beads-backend-dolt-sql--execute-count nil nil)))
        (should (= (alist-get 'count result) 99)))))))

;;; Executor routing tests

(ert-deftest beads-dolt-sql-test-executor-routes-list-to-sql ()
  "Test executor routes 'list' to SQL when available."
  (let ((called-sql nil))
    (cl-letf (((symbol-function 'beads-backend-dolt-sql--available-p)
               (lambda () t))
              ((symbol-function 'beads-backend-dolt-sql--execute-list)
               (lambda (_args _project-root)
                 (setq called-sql t)
                 '((id . "x")))))
      (beads-backend-dolt-sql--executor "list" nil nil)
      (should called-sql))))

(ert-deftest beads-dolt-sql-test-executor-routes-show-to-sql ()
  "Test executor routes 'show' to SQL when available."
  (let ((called-sql nil))
    (cl-letf (((symbol-function 'beads-backend-dolt-sql--available-p)
               (lambda () t))
              ((symbol-function 'beads-backend-dolt-sql--execute-show)
               (lambda (_args _project-root)
                 (setq called-sql t)
                 '((id . "y")))))
      (beads-backend-dolt-sql--executor "show" nil nil)
      (should called-sql))))

(ert-deftest beads-dolt-sql-test-executor-falls-back-for-create ()
  "Test executor falls back to bd CLI for non-SQL 'create' op."
  (let ((called-fallback nil))
    (cl-letf (((symbol-function 'beads-backend-dolt-sql--available-p)
               (lambda () t))
              ((symbol-function 'beads-backend-dolt-sql--execute-fallback)
               (lambda (_op _args _project-root &optional _prev)
                 (setq called-fallback t)
                 '((id . "new")))))
      (beads-backend-dolt-sql--executor "create" '((title . "test")) nil)
      (should called-fallback))))

(ert-deftest beads-dolt-sql-test-executor-falls-back-on-sql-error ()
  "Test executor falls back when SQL raises an error."
  (let ((called-fallback nil))
    (cl-letf (((symbol-function 'beads-backend-dolt-sql--available-p)
               (lambda () t))
              ((symbol-function 'beads-backend-dolt-sql--execute-list)
               (lambda (_args _project-root)
                 (signal 'beads-backend-error '("SQL failed"))))
              ((symbol-function 'beads-backend-dolt-sql--execute-fallback)
               (lambda (_op _args _project-root &optional _prev)
                 (setq called-fallback t)
                 (list '((id . "fallback"))))))
      (let ((result (beads-backend-dolt-sql--executor "list" nil nil)))
        (should called-fallback)
        (should (equal (alist-get 'id (car result)) "fallback"))))))

(ert-deftest beads-dolt-sql-test-executor-falls-back-when-disabled ()
  "Test executor uses bd CLI when disabled."
  (let ((called-fallback nil))
    (cl-letf (((symbol-function 'beads-backend-dolt-sql--available-p)
               (lambda () nil))
              ;; Force the SQL path to fail so executor exercises the
              ;; fallback branch even though available-p returns nil
              ;; (the executor itself doesn't gate on available-p for
              ;; SQL-mapped ops).
              ((symbol-function 'beads-backend-dolt-sql--execute-list)
               (lambda (_args _project-root)
                 (signal 'beads-backend-error '("SQL disabled"))))
              ((symbol-function 'beads-backend-dolt-sql--execute-fallback)
               (lambda (_op _args _project-root &optional _prev)
                 (setq called-fallback t)
                 (list '((id . "bd"))))))
      (let ((result (beads-backend-dolt-sql--executor "list" nil nil)))
        (should called-fallback)
        (should (equal (alist-get 'id (car result)) "bd"))))))

;;; Auto-detect advice tests

(ert-deftest beads-dolt-sql-test-auto-detect-prefers-sql-when-available ()
  "Test auto-detect returns bd-dolt-sql by default when bd is available."
  (let ((beads-backend--registry beads-backend--registry))
    (beads-backend-register beads-backend-dolt-sql)
    (cl-letf (((symbol-function 'executable-find)
               (lambda (cmd) (when (equal cmd "bd") "/usr/bin/bd"))))
      (let ((beads-dolt-sql-enabled t))
        (should (equal (beads-backend-name
                        (beads-backend-dolt-sql--auto-detect-advice
                         (lambda () (beads-backend--lookup "bd"))
                         nil))
                       "bd-dolt-sql"))))))

(ert-deftest beads-dolt-sql-test-auto-detect-falls-through-when-disabled ()
  "Test auto-detect passes through when SQL transport disabled."
  (let ((beads-backend--registry beads-backend--registry))
    (beads-backend-register beads-backend-dolt-sql)
    (cl-letf (((symbol-function 'executable-find)
               (lambda (cmd) (when (equal cmd "bd") "/usr/bin/bd"))))
      (let ((beads-dolt-sql-enabled nil))
        (should (equal (beads-backend-name
                        (beads-backend-dolt-sql--auto-detect-advice
                         (lambda (&rest _) (beads-backend--lookup "bd"))
                         nil))
                       "bd"))))))

;;; Activate / deactivate tests

(ert-deftest beads-dolt-sql-test-activate-sets-vars ()
  "Test activate sets enabled flags and clears cache."
  (let ((beads-dolt-sql-enabled nil)
        (beads-dolt-sql--available nil)
        (beads-dolt-sql--params '((stale . t)))
        (beads-dolt-sql--params-time (current-time))
        (beads-dolt-sql--params-root "/stale/project/")
        (beads-backend--registry beads-backend--registry))
    (beads-backend-dolt-sql-activate)
    (should beads-dolt-sql-enabled)
    (should beads-dolt-sql--available)
    (should-not beads-dolt-sql--params)
    (should-not beads-dolt-sql--params-time)
    (should-not beads-dolt-sql--params-root)
    (should (advice-member-p #'beads-backend-dolt-sql--auto-detect-advice
                             'beads-backend--auto-detect))
    (beads-backend-dolt-sql-deactivate)))

(ert-deftest beads-dolt-sql-test-deactivate-sets-vars ()
  "Test deactivate clears enabled flags and removes advice."
  (let ((beads-backend--registry beads-backend--registry))
    (beads-backend-dolt-sql-activate)
    (beads-backend-dolt-sql-deactivate)
    (should-not beads-dolt-sql-enabled)
    (should-not beads-dolt-sql--available)
    (should-not (advice-member-p #'beads-backend-dolt-sql--auto-detect-advice
                                 'beads-backend--auto-detect))))

;;; Health check tests

(ert-deftest beads-dolt-sql-test-check-disabled ()
  "Test check signals when disabled non-interactively."
  (let ((beads-dolt-sql-enabled nil))
    (should-error (beads-backend-dolt-sql--check)
                  :type 'beads-backend-error)))

(ert-deftest beads-dolt-sql-test-check-no-mariadb ()
  "Test check signals when no SQL transport is found."
  (let ((beads-dolt-sql-enabled t))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_cmd) nil))
              ((symbol-function 'locate-library)
               (lambda (_library) nil))
              ((symbol-function 'beads-dolt-sql--native-mysql-available-p)
               (lambda () nil)))
      (should-error (beads-backend-dolt-sql--check)
                    :type 'beads-backend-error))))

(ert-deftest beads-dolt-sql-test-check-available ()
  "Test check returns t when everything is ready."
  (beads-dolt-sql-test--with-bd-dolt-show
   "{\"backend\":\"dolt\",\"connection_ok\":true,\"database\":\"db\",\"host\":\"127.0.0.1\",\"port\":3310,\"user\":\"root\"}"
   (let ((beads-dolt-sql--params nil)
         (beads-dolt-sql--params-time nil)
         (beads-dolt-sql--available t)
         (beads-dolt-sql-enabled t))
     (cl-letf (((symbol-function 'executable-find)
                (lambda (cmd)
                  (cond ((equal cmd "mariadb") "/usr/bin/mariadb")
                        (t nil))))
               ((symbol-function 'beads-client--project-root)
                (lambda () "/fake/project/")))
       (should (beads-backend-dolt-sql--check))))))

;;; Fallback execution tests

(defun beads-dolt-sql-test--mock-backend-lookup (_name)
  "Mock `beads-backend--lookup' to return bd backend for any NAME."
  beads-backend-bd)

(defun beads-dolt-sql-test--mock-exec-find-bd (cmd)
  "Mock `executable-find' returning bd path when CMD is \"bd\"."
  (when (equal cmd "bd") "/usr/bin/bd"))

(defun beads-dolt-sql-test--mock-exec-find-none (_cmd)
  "Mock `executable-find' returning nil for any CMD."
  nil)

(ert-deftest beads-dolt-sql-test-fallback-uses-bd-cli ()
  "Test fallback executes via bd CLI subprocess."
  (let ((called-bd-args nil)
        (beads-backend-dolt-sql--cli-fallback-program nil))
    (cl-letf (((symbol-function 'beads-backend--lookup)
               #'beads-dolt-sql-test--mock-backend-lookup)
              ((symbol-function 'executable-find)
               #'beads-dolt-sql-test--mock-exec-find-bd)
              ((symbol-function 'call-process)
               (lambda (program &optional _infile dest _display &rest args)
                 ;; The program is the resolved path
                 ;; (e.g. "/usr/bin/bd"), so match by basename.
                 (when (equal (file-name-nondirectory program) "bd")
                   (setq called-bd-args args)
                   (when dest
                     (let ((buf (if (eq dest t)
                                    (current-buffer)
                                  (car-safe dest))))
                       (when buf
                         (with-current-buffer buf
                           (insert "[]"))))))
                 0)))
      (let ((result (beads-backend-dolt-sql--execute-fallback "list" nil nil)))
        (should (listp result))
        (should called-bd-args)
        (should (member "--json" called-bd-args))))))

(ert-deftest beads-dolt-sql-test-fallback-signals-no-bd ()
  "Test fallback signals when bd not found."
  (let ((beads-backend-dolt-sql--cli-fallback-program nil))
    (cl-letf (((symbol-function 'beads-backend--lookup)
               #'beads-dolt-sql-test--mock-backend-lookup)
              ((symbol-function 'executable-find)
               #'beads-dolt-sql-test--mock-exec-find-none))
      (should-error (beads-backend-dolt-sql--execute-fallback "list" nil nil)
                    :type 'beads-backend-error))))

(ert-deftest beads-dolt-sql-test-fallback-signals-bd-error ()
  "Test fallback signals when bd CLI fails."
  (let ((beads-backend-dolt-sql--cli-fallback-program nil))
    (cl-letf (((symbol-function 'beads-backend--lookup)
               #'beads-dolt-sql-test--mock-backend-lookup)
              ((symbol-function 'executable-find)
               #'beads-dolt-sql-test--mock-exec-find-bd)
               ((symbol-function 'call-process)
                (lambda (&rest _)
                  1)))
      (should-error (beads-backend-dolt-sql--execute-fallback "list" nil nil)
                    :type 'beads-backend-error))))

;;; Persistent mysql/mariadb subprocess (Tier 1.5) tests

(defun beads-dolt-sql-test--make-fake-proc ()
  "Return a sentinel symbol used as a stand-in for a live process.
All persistent-client process operations are stubbed so the tests
never touch a real subprocess."
  (make-symbol "fake-mysql-proc"))

(defmacro beads-dolt-sql-test--with-mysql-state (&rest body)
  "Eval BODY with all `--mysql-*' state vars freshly bound to nil."
  (declare (indent 0))
  `(let ((beads-dolt-sql--mysql-proc nil)
         (beads-dolt-sql--mysql-output nil)
         (beads-dolt-sql--mysql-params nil)
         (beads-dolt-sql--mysql-shutting-down nil)
         (beads-dolt-sql--available t))
     ,@body))

;; --- Filter tests ---

(ert-deftest beads-dolt-sql-test-mysql-filter-appends-chunks ()
  "Test `--mysql-filter' concatenates successive chunks."
  (beads-dolt-sql-test--with-mysql-state
    (setq beads-dolt-sql--mysql-output "")
    (beads-dolt-sql--mysql-filter nil "abc")
    (beads-dolt-sql--mysql-filter nil "def")
    (beads-dolt-sql--mysql-filter nil "ghi\n")
    (should (equal beads-dolt-sql--mysql-output "abcdefghi\n"))))

(ert-deftest beads-dolt-sql-test-mysql-filter-handles-nil-start ()
  "Test `--mysql-filter' tolerates a nil starting `--mysql-output'."
  (beads-dolt-sql-test--with-mysql-state
    (should (null beads-dolt-sql--mysql-output))
    (beads-dolt-sql--mysql-filter nil "first")
    (should (equal beads-dolt-sql--mysql-output "first"))
    (beads-dolt-sql--mysql-filter nil "+second")
    (should (equal beads-dolt-sql--mysql-output "first+second"))))

;; --- Sentinel tests ---

(ert-deftest beads-dolt-sql-test-mysql-sentinel-clears-on-finished ()
  "Test sentinel clears state and marks unavailable on `finished'."
  (beads-dolt-sql-test--with-mysql-state
    (setq beads-dolt-sql--mysql-proc (beads-dolt-sql-test--make-fake-proc))
    (setq beads-dolt-sql--mysql-output "buffered")
    (setq beads-dolt-sql--mysql-params '((host . "x")))
    (beads-dolt-sql--mysql-sentinel nil "finished\n")
    (should-not beads-dolt-sql--mysql-proc)
    (should-not beads-dolt-sql--mysql-output)
    (should-not beads-dolt-sql--mysql-params)
    (should-not beads-dolt-sql--available)))

(ert-deftest beads-dolt-sql-test-mysql-sentinel-clears-on-exited ()
  "Test sentinel clears state on `exited' event."
  (beads-dolt-sql-test--with-mysql-state
    (setq beads-dolt-sql--mysql-proc (beads-dolt-sql-test--make-fake-proc))
    (beads-dolt-sql--mysql-sentinel nil "exited abnormally with code 1\n")
    (should-not beads-dolt-sql--mysql-proc)))

(ert-deftest beads-dolt-sql-test-mysql-sentinel-clears-on-killed ()
  "Test sentinel clears state on `killed' event."
  (beads-dolt-sql-test--with-mysql-state
    (setq beads-dolt-sql--mysql-proc (beads-dolt-sql-test--make-fake-proc))
    (beads-dolt-sql--mysql-sentinel nil "killed\n")
    (should-not beads-dolt-sql--mysql-proc)))

(ert-deftest beads-dolt-sql-test-mysql-sentinel-ignores-other-events ()
  "Test sentinel leaves state alone for non-terminating events."
  (beads-dolt-sql-test--with-mysql-state
    (let ((proc (beads-dolt-sql-test--make-fake-proc)))
      (setq beads-dolt-sql--mysql-proc proc)
      (setq beads-dolt-sql--mysql-output "still here")
      (beads-dolt-sql--mysql-sentinel nil "open from 127.0.0.1\n")
      (should (eq beads-dolt-sql--mysql-proc proc))
      (should (equal beads-dolt-sql--mysql-output "still here"))
      (should beads-dolt-sql--available))))

;; --- Start / ensure tests ---

(defmacro beads-dolt-sql-test--with-start-process-stub (capture &rest body)
  "Eval BODY with `start-process' stubbed.
CAPTURE is a list-cell whose car is set to an alist of call args:
  ((name . NAME) (buffer . BUFFER) (program . PROGRAM)
   (args . ARGS) (proc . PROC))."
  (declare (indent 1))
  `(cl-letf (((symbol-function 'start-process)
              (lambda (name buffer program &rest args)
                (let ((proc (beads-dolt-sql-test--make-fake-proc)))
                  (setcar ,capture
                          (list (cons 'name name)
                                (cons 'buffer buffer)
                                (cons 'program program)
                                (cons 'args args)
                                (cons 'connection-type process-connection-type)
                                (cons 'proc proc)))
                  proc)))
             ((symbol-function 'set-process-filter)
              (lambda (proc fn)
                (setcar ,capture
                        (cons (cons 'filter (cons proc fn))
                              (car ,capture)))))
             ((symbol-function 'set-process-sentinel)
              (lambda (proc fn)
                (setcar ,capture
                        (cons (cons 'sentinel (cons proc fn))
                              (car ,capture)))))
             ((symbol-function 'executable-find)
              (lambda (cmd)
                (cond ((equal cmd "mariadb") "/usr/bin/mariadb")
                      (t nil)))))
     (unwind-protect
         (progn ,@body)
       (when-let ((buffer (alist-get 'buffer (car ,capture))))
         (when (buffer-live-p buffer)
           (kill-buffer buffer))))))

(ert-deftest beads-dolt-sql-test-start-mysql-proc-sets-state ()
  "Test `--start-mysql-proc' wires up state, filter, and sentinel."
  (beads-dolt-sql-test--with-mysql-state
    (let* ((capture (list nil))
           (dolt '((host . "127.0.0.1")
                   (port . 3310)
                   (user . "root")
                   (database . "testdb"))))
      (beads-dolt-sql-test--with-start-process-stub capture
        (let ((proc (beads-dolt-sql--start-mysql-proc dolt)))
          (should proc)
          (should (eq beads-dolt-sql--mysql-proc proc))
          (should (equal beads-dolt-sql--mysql-params dolt))
          (should (equal beads-dolt-sql--mysql-output ""))
          (let ((c (car capture)))
            (should (equal (alist-get 'name c) "beads-mysql"))
            (should (equal (alist-get 'program c) "/usr/bin/mariadb"))
            ;; Pipe (not pty) is required: mariadb on a pty echoes BEL
            ;; characters and never delivers the sentinel marker (bdel-dgy).
            (should (null (alist-get 'connection-type c)))
            (let ((args (alist-get 'args c)))
              (should (member "--batch" args))
              (should (member "--skip-column-names" args))
              ;; --force keeps the batch alive after a SQL error so the
              ;; trailing sentinel SELECT (see bdel-dgy) still runs.
              (should (member "--force" args))
              ;; --unbuffered flushes after every query so small results
              ;; (count, stats, the sentinel itself) reach us without
              ;; sitting in mariadb's stdout block buffer (bdel-dgy).
              (should (member "--unbuffered" args))
              (should (member "--host" args))
              (should (member "127.0.0.1" args))
              (should (member "--port" args))
              (should (member "3310" args))
              (should (member "--user" args))
              (should (member "root" args))
              (should (member "testdb" args)))
            ;; filter and sentinel were attached to the same proc.
            (should (eq (cadr (assq 'filter c)) proc))
            (should (eq (cddr (assq 'filter c)) #'beads-dolt-sql--mysql-filter))
            (should (eq (cadr (assq 'sentinel c)) proc))
            (should (eq (cddr (assq 'sentinel c))
                        #'beads-dolt-sql--mysql-sentinel))))))))

(ert-deftest beads-dolt-sql-test-ensure-mysql-connected-reuses-live ()
  "Test `--ensure-mysql-connected' returns existing live proc."
  (beads-dolt-sql-test--with-mysql-state
    (let* ((proc (beads-dolt-sql-test--make-fake-proc))
           (dolt '((host . "127.0.0.1") (port . 3310) (database . "db_a")))
           (start-called nil))
      (setq beads-dolt-sql--mysql-proc proc)
      (setq beads-dolt-sql--mysql-params dolt)
      (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                ((symbol-function 'beads-dolt-sql--start-mysql-proc)
                 (lambda (_dolt) (setq start-called t) 'new-proc)))
        (should (eq (beads-dolt-sql--ensure-mysql-connected dolt) proc))
        (should-not start-called)))))

(ert-deftest beads-dolt-sql-test-ensure-mysql-connected-restarts-on-param-change ()
  "Test persistent mariadb is restarted when the requested Dolt DB changes."
  (beads-dolt-sql-test--with-mysql-state
    (let* ((old-proc (beads-dolt-sql-test--make-fake-proc))
           (old-dolt '((host . "127.0.0.1") (port . 3310) (database . "db_a")))
           (new-dolt '((host . "127.0.0.1") (port . 3310) (database . "db_b")))
           (deleted nil)
           (started-with nil))
      (setq beads-dolt-sql--mysql-proc old-proc)
      (setq beads-dolt-sql--mysql-params old-dolt)
      (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                ((symbol-function 'delete-process)
                 (lambda (p) (setq deleted p)))
                ((symbol-function 'beads-dolt-sql--start-mysql-proc)
                 (lambda (dolt)
                   (setq started-with dolt)
                   'new-proc)))
        (should (eq (beads-dolt-sql--ensure-mysql-connected new-dolt) 'new-proc))
        (should (eq deleted old-proc))
        (should (equal started-with new-dolt))))))

(ert-deftest beads-dolt-sql-test-ensure-mysql-connected-restarts-dead ()
  "Test `--ensure-mysql-connected' restarts when proc is dead."
  (beads-dolt-sql-test--with-mysql-state
    (let* ((dead (beads-dolt-sql-test--make-fake-proc))
           (deleted nil)
           (started-with nil))
      (setq beads-dolt-sql--mysql-proc dead)
      (cl-letf (((symbol-function 'process-live-p) (lambda (_) nil))
                ((symbol-function 'delete-process)
                 (lambda (p) (setq deleted p)))
                ((symbol-function 'beads-backend-dolt-sql--fetch-dolt-params)
                 (lambda () '((host . "127.0.0.1") (port . 3310))))
                ((symbol-function 'beads-dolt-sql--start-mysql-proc)
                 (lambda (dolt)
                   (setq started-with dolt)
                   'fresh-proc)))
        (should (eq (beads-dolt-sql--ensure-mysql-connected) 'fresh-proc))
        (should (eq deleted dead))
        (should (equal (alist-get 'host started-with) "127.0.0.1"))))))

(ert-deftest beads-dolt-sql-test-ensure-mysql-connected-no-params-signals ()
  "Test `--ensure-mysql-connected' signals when no Dolt params available."
  (beads-dolt-sql-test--with-mysql-state
    (cl-letf (((symbol-function 'process-live-p) (lambda (_) nil))
              ((symbol-function 'beads-backend-dolt-sql--fetch-dolt-params)
               (lambda () nil)))
      (should-error (beads-dolt-sql--ensure-mysql-connected)
                    :type 'beads-backend-error))))

(ert-deftest beads-dolt-sql-test-stop-mysql-proc-quits-gracefully ()
  "Test idle cleanup sends mariadb quit and does not mark SQL unavailable."
  (beads-dolt-sql-test--with-mysql-state
    (let ((proc (beads-dolt-sql-test--make-fake-proc))
          (sent nil)
          (accepted nil)
          (deleted nil)
          (marked-unavailable nil)
          (live t))
      (setq beads-dolt-sql--mysql-proc proc)
      (setq beads-dolt-sql--mysql-output "buffered")
      (setq beads-dolt-sql--mysql-params '((host . "127.0.0.1")))
      (cl-letf (((symbol-function 'process-live-p) (lambda (_) live))
                ((symbol-function 'process-send-string)
                 (lambda (p string)
                   (setq sent (cons p string))))
                ((symbol-function 'accept-process-output)
                 (lambda (p _timeout)
                   (setq accepted p)
                   (beads-dolt-sql--mysql-sentinel p "finished\n")
                   (setq live nil)))
                ((symbol-function 'delete-process)
                 (lambda (p) (setq deleted p)))
                ((symbol-function 'beads-backend-dolt-sql--mark-unavailable)
                 (lambda () (setq marked-unavailable t))))
        (beads-dolt-sql--stop-mysql-proc)
        (should (equal sent (cons proc "\\q\n")))
        (should (eq accepted proc))
        (should-not deleted)
        (should-not marked-unavailable)
        (should-not beads-dolt-sql--mysql-proc)
        (should-not beads-dolt-sql--mysql-output)
        (should-not beads-dolt-sql--mysql-params)))))

(ert-deftest beads-dolt-sql-test-stop-idle-session-disconnects-clients ()
  "Test idle cleanup disconnects native mysql and persistent mariadb clients."
  (let ((native-disconnected nil)
        (mysql-stopped nil))
    (cl-letf (((symbol-function 'beads-dolt-sql--native-mysql-disconnect)
               (lambda () (setq native-disconnected t)))
              ((symbol-function 'beads-dolt-sql--stop-mysql-proc)
               (lambda () (setq mysql-stopped t))))
      (beads-backend-dolt-sql-stop-idle-session)
      (should native-disconnected)
      (should mysql-stopped))))

;; --- Query tests ---

(defmacro beads-dolt-sql-test--with-mysql-query-stubs
    (proc sent-store &rest body)
  "Stub `--ensure-mysql-connected', `process-send-string', and friends.
PROC is the symbol used as the fake live proc returned by ensure.
SENT-STORE is a list-cell whose car captures the SQL string sent."
  (declare (indent 2))
  `(cl-letf (((symbol-function 'beads-dolt-sql--ensure-mysql-connected)
              (lambda (&optional _dolt) ,proc))
             ((symbol-function 'process-send-string)
              (lambda (_p s) (setcar ,sent-store s))))
     ,@body))

(ert-deftest beads-dolt-sql-test-mysql-query-sends-sql-and-parses-json ()
  "Test `--mysql-query' sends \"<sql>;\\nSELECT '<marker>';\\n\".
The polling loop must wait for the sentinel marker (bdel-dgy) and
the marker line must be stripped before JSON parsing."
  (beads-dolt-sql-test--with-mysql-state
    (let* ((proc (beads-dolt-sql-test--make-fake-proc))
           (sent (list nil))
           (poll-count 0)
           (marker beads-dolt-sql--mysql-end-marker))
      (setq beads-dolt-sql--mysql-output "stale-leftover")
      (beads-dolt-sql-test--with-mysql-query-stubs proc sent
        (cl-letf (((symbol-function 'accept-process-output)
                   (lambda (&rest _)
                     (cl-incf poll-count)
                     (setq beads-dolt-sql--mysql-output
                           (concat "[{\"id\":\"x\",\"title\":\"t\"}]\n"
                                   marker "\n")))))
          (let ((result (beads-dolt-sql--mysql-query "SELECT 1")))
            ;; Stale output was reset before send and both the real
            ;; query and the sentinel SELECT were sent in one batch.
            (should (equal (car sent)
                           (concat "SELECT 1;\nSELECT '" marker "';\n")))
            (should (> poll-count 0))
            (should (listp result))
            (should (equal (alist-get 'id (car result)) "x"))))))))

(ert-deftest beads-dolt-sql-test-mysql-query-resets-output-before-send ()
  "Test `--mysql-query' resets `--mysql-output' before sending."
  (beads-dolt-sql-test--with-mysql-state
    (let* ((proc (beads-dolt-sql-test--make-fake-proc))
           (sent (list nil))
           (output-at-send nil)
           (marker beads-dolt-sql--mysql-end-marker))
      (setq beads-dolt-sql--mysql-output "GARBAGE FROM PREVIOUS QUERY")
      (cl-letf (((symbol-function 'beads-dolt-sql--ensure-mysql-connected)
                 (lambda (&optional _dolt) proc))
                ((symbol-function 'process-send-string)
                 (lambda (_p s)
                   (setq output-at-send beads-dolt-sql--mysql-output)
                   (setcar sent s)))
                ((symbol-function 'accept-process-output)
                 (lambda (&rest _)
                   (setq beads-dolt-sql--mysql-output
                         (concat "[]\n" marker "\n")))))
        (beads-dolt-sql--mysql-query "SELECT 2")
        (should (equal output-at-send ""))
        (should (equal (car sent)
                       (concat "SELECT 2;\nSELECT '" marker "';\n")))))))

(ert-deftest beads-dolt-sql-test-mysql-query-times-out-cleanly ()
  "Test `--mysql-query' exits the polling loop without spinning.
When the sentinel marker never arrives the buffered output (here
empty) is handed to the JSON parser, which raises
`beads-backend-error' for empty input.  The externally observable
behaviour is: an error is signalled quickly, never an infinite loop."
  (beads-dolt-sql-test--with-mysql-state
    (let* ((proc (beads-dolt-sql-test--make-fake-proc))
           (sent (list nil))
           ;; First call returns 0 (start), all later calls return a
           ;; value past the 5s timeout so the loop exits immediately.
           (first-call t)
           (poll-count 0)
           (marker beads-dolt-sql--mysql-end-marker))
      (beads-dolt-sql-test--with-mysql-query-stubs proc sent
        (cl-letf (((symbol-function 'float-time)
                   (lambda (&rest _)
                     (if first-call (progn (setq first-call nil) 0.0) 100.0)))
                  ((symbol-function 'accept-process-output)
                   (lambda (&rest _)
                     (cl-incf poll-count)
                     ;; Never set output — simulating no data arriving.
                     nil)))
          ;; If the loop spun on the real wall-clock the test would
          ;; hang for 5s; instead `should-error' returns immediately
          ;; because our mocked `float-time' makes the loop guard
          ;; false on its very first re-check.
          (should-error (beads-dolt-sql--mysql-query "SELECT 3")
                        :type 'beads-backend-error)
          ;; Loop body must not have run more than once given our
          ;; mocked clock jump.
          (should (<= poll-count 1))
          (should (equal (car sent)
                         (concat "SELECT 3;\nSELECT '" marker "';\n"))))))))

(ert-deftest beads-dolt-sql-test-mysql-query-signals-on-error-prefix ()
  "Test `--mysql-query' signals when output starts with ERROR.
With `--force' the sentinel SELECT runs even after a SQL error, so
the marker arrives after the error text; the marker and trailing
output are stripped before the ERROR check fires."
  (beads-dolt-sql-test--with-mysql-state
    (let* ((proc (beads-dolt-sql-test--make-fake-proc))
           (sent (list nil))
           (marker beads-dolt-sql--mysql-end-marker))
      (beads-dolt-sql-test--with-mysql-query-stubs proc sent
        (cl-letf (((symbol-function 'accept-process-output)
                   (lambda (&rest _)
                     (setq beads-dolt-sql--mysql-output
                           (concat "ERROR 1146 (42S02): Table doesn't exist\n"
                                   marker "\n")))))
          (should-error (beads-dolt-sql--mysql-query "SELECT bogus")
                        :type 'beads-backend-error))))))

(ert-deftest beads-dolt-sql-test-mysql-query-strips-marker-from-result ()
  "Test `--mysql-query' strips the sentinel marker (and anything after
it) from the output before JSON parsing.  Regression test for bdel-dgy."
  (beads-dolt-sql-test--with-mysql-state
    (let* ((proc (beads-dolt-sql-test--make-fake-proc))
           (sent (list nil))
           (marker beads-dolt-sql--mysql-end-marker))
      (beads-dolt-sql-test--with-mysql-query-stubs proc sent
        (cl-letf (((symbol-function 'accept-process-output)
                   (lambda (&rest _)
                     (setq beads-dolt-sql--mysql-output
                           (concat "[{\"id\":\"abc\",\"title\":\"t\"}]\n"
                                   marker "\nextra trailing junk\n")))))
          (let ((result (beads-dolt-sql--mysql-query "SELECT 1")))
            (should (listp result))
            (should (equal (alist-get 'id (car result)) "abc"))))))))

(ert-deftest beads-dolt-sql-test-mysql-query-tolerates-mid-chunk-newlines ()
  "Test `--mysql-query' does NOT terminate the polling loop when an
intermediate chunk happens to end with a newline.  This is the
correctness bug fixed alongside the performance fix in bdel-dgy."
  (beads-dolt-sql-test--with-mysql-state
    (let* ((proc (beads-dolt-sql-test--make-fake-proc))
           (sent (list nil))
           (marker beads-dolt-sql--mysql-end-marker)
           ;; Simulate the output arriving in three chunks.  The first
           ;; two chunks end with \n but do NOT contain the marker;
           ;; the loop must keep polling until the marker appears.
           (chunks (list "[{\"id\":\"a\"},\n"
                         "{\"id\":\"b\"}]\n"
                         (concat marker "\n")))
           (chunk-idx 0))
      (beads-dolt-sql-test--with-mysql-query-stubs proc sent
        (cl-letf (((symbol-function 'accept-process-output)
                   (lambda (&rest _)
                     (when (< chunk-idx (length chunks))
                       (setq beads-dolt-sql--mysql-output
                             (concat (or beads-dolt-sql--mysql-output "")
                                     (nth chunk-idx chunks)))
                       (cl-incf chunk-idx)))))
          (let ((result (beads-dolt-sql--mysql-query "SELECT 1")))
            ;; All three chunks must have been consumed, not just the
            ;; first one with its dangling \n.
            (should (= chunk-idx 3))
            (should (= (length result) 2))
            (should (equal (alist-get 'id (car result)) "a"))
            (should (equal (alist-get 'id (cadr result)) "b"))))))))

;; --- Integration with --execute-sql ---

(ert-deftest beads-dolt-sql-test-execute-sql-uses-persistent-mysql ()
  "Test `--execute-sql' uses `--mysql-query' when the `mariadb' client is found."
  (beads-dolt-sql-test--with-mysql-state
    (let ((called-sql nil))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (cmd)
                   (cond ((equal cmd "mariadb") "/usr/bin/mariadb")
                         ((equal cmd "bd") "/usr/bin/bd")
                         (t nil))))
                ((symbol-function 'beads-dolt-sql--native-mysql-available-p)
                 (lambda () nil))
                ((symbol-function 'beads-dolt-sql--mysql-query)
                 (lambda (sql &optional _dolt)
                   (setq called-sql sql)
                   (beads-dolt-sql--parse-json-output
                    "[{\"id\":\"persistent-1\",\"title\":\"p\"}]")))
                ((symbol-function 'beads-backend-dolt-sql--fetch-dolt-params)
                 (lambda (&optional _project-root)
                   '((host . "127.0.0.1") (port . 3310)
                     (user . "root") (database . "testdb")))))
        (let ((result (beads-backend-dolt-sql--execute-sql "SELECT 1")))
          (should (equal called-sql "SELECT 1"))
          (should (equal (alist-get 'id (car result)) "persistent-1")))))))

(ert-deftest beads-dolt-sql-test-execute-sql-falls-back-on-persistent-error ()
  "Test `--execute-sql' falls back to `--one-shot-mariadb' on persistent error."
  (beads-dolt-sql-test--with-mysql-state
    (let ((one-shot-called nil))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (cmd)
                   (cond ((equal cmd "mariadb") "/usr/bin/mariadb")
                         ((equal cmd "bd") "/usr/bin/bd")
                         (t nil))))
                ((symbol-function 'beads-dolt-sql--native-mysql-available-p)
                 (lambda () nil))
                ((symbol-function 'beads-dolt-sql--mysql-query)
                 (lambda (_sql &optional _dolt)
                   (signal 'beads-backend-error '("persistent client died"))))
                ((symbol-function 'beads-backend-dolt-sql--one-shot-mariadb)
                 (lambda (sql _dolt)
                   (setq one-shot-called sql)
                   (beads-dolt-sql--parse-json-output
                    "[{\"id\":\"shot-1\",\"title\":\"s\"}]")))
                ((symbol-function 'beads-backend-dolt-sql--fetch-dolt-params)
                 (lambda (&optional _project-root)
                   '((host . "127.0.0.1") (port . 3310)
                     (user . "root") (database . "testdb")))))
        (let ((result (beads-backend-dolt-sql--execute-sql "SELECT 1")))
          (should (equal one-shot-called "SELECT 1"))
          (should (equal (alist-get 'id (car result)) "shot-1")))))))

(ert-deftest beads-dolt-sql-test-execute-list-uses-project-root-for-sql-params ()
  "Regression test: switching org/list buffers must switch Dolt databases."
  (beads-dolt-sql-test--with-mysql-state
    (let ((queries nil))
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (cmd)
                   (cond ((equal cmd "mariadb") "/usr/bin/mariadb")
                         ((equal cmd "bd") "/usr/bin/bd")
                         (t nil))))
                ((symbol-function 'beads-dolt-sql--native-mysql-available-p)
                 (lambda () nil))
                ((symbol-function 'beads-backend-dolt-sql--fetch-dolt-params)
                 (lambda (&optional project-root)
                   `((host . "127.0.0.1")
                     (port . 3310)
                     (user . "root")
                     (database . ,(if (equal project-root "/workspace/a/")
                                      "db_a"
                                    "db_b")))))
                ((symbol-function 'beads-dolt-sql--mysql-query)
                 (lambda (_sql dolt)
                   (push (alist-get 'database dolt) queries)
                   (beads-dolt-sql--parse-json-output
                    (if (equal (alist-get 'database dolt) "db_a")
                        "[{\"id\":\"bd-a\",\"title\":\"From A\"}]"
                      "[{\"id\":\"bd-b\",\"title\":\"From B\"}]")))))
        (let ((issues-a (beads-backend-dolt-sql--execute-list nil "/workspace/a/"))
              (issues-b (beads-backend-dolt-sql--execute-list nil "/workspace/b/")))
          (should (equal (alist-get 'id (car issues-a)) "bd-a"))
          (should (equal (alist-get 'id (car issues-b)) "bd-b"))
          (should (equal (nreverse queries) '("db_a" "db_b"))))))))

;;; Integration tests (only when live Dolt server is available)

(ert-deftest beads-dolt-sql-test-integration-list ()
  "Integration: list operation returns issues from live Dolt server."
  :tags '(:integration)
  (skip-unless (beads-test-integration-enabled-p))
  (skip-unless (beads-dolt-sql-test--live-dolt-sql-available-p))
  (let ((beads-dolt-sql--params nil)
        (beads-dolt-sql--params-time nil)
        (beads-dolt-sql--available t)
        (beads-dolt-sql-enabled t))
    (cl-letf (((symbol-function 'beads-client--project-root)
               (lambda () default-directory)))
      (let ((result (beads-backend-dolt-sql--execute-list nil nil)))
        (should (listp result))
        (should (> (length result) 0))
        (let ((issue (car result)))
          (should (stringp (alist-get 'id issue)))
          (should (stringp (alist-get 'title issue)))
          (should (integerp (alist-get 'priority issue))))))))

(ert-deftest beads-dolt-sql-test-integration-show ()
  "Integration: show operation returns a known issue."
  :tags '(:integration)
  (skip-unless (beads-test-integration-enabled-p))
  (skip-unless (beads-dolt-sql-test--live-dolt-sql-available-p))
  (let ((beads-dolt-sql--params nil)
        (beads-dolt-sql--params-time nil)
        (beads-dolt-sql--available t)
        (beads-dolt-sql-enabled t))
    (cl-letf (((symbol-function 'beads-client--project-root)
               (lambda () default-directory)))
      ;; Use a known existing issue
      (let ((result (beads-backend-dolt-sql--execute-show
                     '((id . "bdel-4c4.1")) nil)))
        (should result)
        (should (equal (alist-get 'id result) "bdel-4c4.1"))
        (should (stringp (alist-get 'title result)))))))

(ert-deftest beads-dolt-sql-test-integration-stats ()
  "Integration: stats operation returns summary."
  :tags '(:integration)
  (skip-unless (beads-test-integration-enabled-p))
  (skip-unless (beads-dolt-sql-test--live-dolt-sql-available-p))
  (let ((beads-dolt-sql--params nil)
        (beads-dolt-sql--params-time nil)
        (beads-dolt-sql--available t)
        (beads-dolt-sql-enabled t))
    (cl-letf (((symbol-function 'beads-client--project-root)
               (lambda () default-directory)))
      (let ((result (beads-backend-dolt-sql--execute-stats nil nil)))
        (should result)
        (let ((s (alist-get 'summary result)))
          (should (integerp (alist-get 'total_issues s)))
          (should (integerp (alist-get 'open_issues s))))))))

(ert-deftest beads-dolt-sql-test-integration-ready ()
  "Integration: ready operation returns ready issues."
  :tags '(:integration)
  (skip-unless (beads-test-integration-enabled-p))
  (skip-unless (beads-dolt-sql-test--live-dolt-sql-available-p))
  (let ((beads-dolt-sql--params nil)
        (beads-dolt-sql--params-time nil)
        (beads-dolt-sql--available t)
        (beads-dolt-sql-enabled t))
    (cl-letf (((symbol-function 'beads-client--project-root)
               (lambda () default-directory)))
      (let ((result (beads-backend-dolt-sql--execute-ready nil nil)))
        (should (listp result))
        (should (> (length result) 0))))))

(ert-deftest beads-dolt-sql-test-integration-stale ()
  "Integration: stale operation returns stale issues."
  :tags '(:integration)
  (skip-unless (beads-test-integration-enabled-p))
  (skip-unless (beads-dolt-sql-test--live-dolt-sql-available-p))
  (let ((beads-dolt-sql--params nil)
        (beads-dolt-sql--params-time nil)
        (beads-dolt-sql--available t)
        (beads-dolt-sql-enabled t))
    (cl-letf (((symbol-function 'beads-client--project-root)
               (lambda () default-directory)))
      (let ((result (beads-backend-dolt-sql--execute-stale '((days . 365)) nil)))
        (should (listp result))))))

(ert-deftest beads-dolt-sql-test-integration-count ()
  "Integration: count operation returns count."
  :tags '(:integration)
  (skip-unless (beads-test-integration-enabled-p))
  (skip-unless (beads-dolt-sql-test--live-dolt-sql-available-p))
  (let ((beads-dolt-sql--params nil)
        (beads-dolt-sql--params-time nil)
        (beads-dolt-sql--available t)
        (beads-dolt-sql-enabled t))
    (cl-letf (((symbol-function 'beads-client--project-root)
               (lambda () default-directory)))
      (let ((result (beads-backend-dolt-sql--execute-count nil nil)))
        (should (integerp (alist-get 'count result)))
        (should (> (alist-get 'count result) 0))))))

(ert-deftest beads-dolt-sql-test-integration-executor-fallback ()
  "Integration: executor falls back to bd CLI for non-SQL ops."
  :tags '(:integration)
  (skip-unless (beads-test-integration-enabled-p))
  (skip-unless (beads-dolt-sql-test--live-dolt-sql-available-p))
  (let ((beads-dolt-sql--params nil)
        (beads-dolt-sql--params-time nil)
        (beads-dolt-sql--available t)
        (beads-dolt-sql-enabled t))
    (cl-letf (((symbol-function 'beads-client--project-root)
               (lambda () default-directory)))
      (let ((result (beads-backend-dolt-sql--executor "types" nil nil)))
        (should result)
        (should (alist-get 'core_types result))))))

(provide 'beads-backend-dolt-sql-test)
;;; beads-backend-dolt-sql-test.el ends here
