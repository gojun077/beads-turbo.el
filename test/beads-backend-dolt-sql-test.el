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

(ert-deftest beads-dolt-sql-test-vendored-mysql-is-discoverable ()
  "Test the vendored mysql.el dependency is on `load-path'."
  (beads-dolt-sql--ensure-vendored-mysql-load-path)
  (should (file-directory-p beads-dolt-sql--vendored-mysql-directory))
  (should (file-exists-p
           (expand-file-name "mysql.el" beads-dolt-sql--vendored-mysql-directory)))
  (should (member beads-dolt-sql--vendored-mysql-directory load-path))
  (should (locate-library "mysql")))

(ert-deftest beads-dolt-sql-test-native-mysql-loads-vendored-library ()
  "Test native mysql.el loading does not require a global package install."
  (let ((load-path (remove beads-dolt-sql--vendored-mysql-directory load-path)))
    (should (beads-dolt-sql--native-mysql-load))
    (should (featurep 'mysql))
    (should (member beads-dolt-sql--vendored-mysql-directory load-path))))

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

(ert-deftest beads-dolt-sql-test-one-shot-mariadb-strips-warning-banners ()
  "One-shot mariadb parsing ignores known non-JSON client warnings."
  (cl-letf (((symbol-function 'call-process)
             (lambda (program &optional _infile dest _display &rest _)
               (should (equal program "mariadb"))
               (let ((buf (beads-dolt-sql-test--dest-buffer dest)))
                 (when buf
                   (with-current-buffer buf
                     (insert "/opt/homebrew/bin/mariadb: Deprecated program name. It will be removed in a future release, use '/opt/homebrew/bin/mariadb' instead\n")
                     (insert "WARNING: option --ssl-verify-server-cert is disabled, because of an insecure passwordless login.\n")
                     (insert "[{\"id\":\"warning-ok\"}]"))))
               0)))
    (let ((result (beads-backend-dolt-sql--one-shot-mariadb
                   "SELECT 1"
                   '((host . "127.0.0.1")
                     (port . 3310)
                     (user . "root")
                     (database . "db")))))
      (should (equal (alist-get 'id (car result)) "warning-ok")))))

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

(ert-deftest beads-dolt-sql-test-native-mysql-reconnects-on-database-change ()
  "Test native mysql.el connections are scoped to Dolt connection params."
  (let ((beads-dolt-sql--native-mysql-conn 'old-conn)
        (beads-dolt-sql--native-mysql-params '((database . "db_a")))
        (disconnected nil)
        (connected nil))
    (cl-letf (((symbol-function 'beads-dolt-sql--native-mysql-disconnect)
               (lambda ()
                 (setq disconnected t)
                 (setq beads-dolt-sql--native-mysql-conn nil)
                 (setq beads-dolt-sql--native-mysql-params nil)))
              ((symbol-function 'beads-dolt-sql--native-mysql-connect)
               (lambda (dolt)
                 (setq connected dolt)
                 (setq beads-dolt-sql--native-mysql-conn 'new-conn)
                 (setq beads-dolt-sql--native-mysql-params dolt)
                 'new-conn)))
      (should (eq (beads-dolt-sql--ensure-native-mysql-connected
                   '((database . "db_b")))
                  'new-conn))
      (should disconnected)
      (should (equal connected '((database . "db_b")))))))

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

;;; SQL session cleanup tests

(ert-deftest beads-dolt-sql-test-stop-idle-session-disconnects-native-client ()
  "Test idle cleanup disconnects the only long-lived SQL client."
  (let ((native-disconnected nil))
    (cl-letf (((symbol-function 'beads-dolt-sql--native-mysql-disconnect)
               (lambda () (setq native-disconnected t))))
      (beads-backend-dolt-sql-stop-idle-session)
      (should native-disconnected))))

;; --- Integration with --execute-sql ---

(ert-deftest beads-dolt-sql-test-execute-sql-uses-one-shot-mariadb ()
  "Test `--execute-sql' uses one-shot mariadb when mysql.el is unavailable."
  (let ((called-sql nil))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (cmd)
                 (cond ((equal cmd "mariadb") "/usr/bin/mariadb")
                       ((equal cmd "bd") "/usr/bin/bd")
                       (t nil))))
              ((symbol-function 'beads-dolt-sql--native-mysql-available-p)
               (lambda () nil))
              ((symbol-function 'start-process)
               (lambda (&rest _)
                 (error "execute-sql must not start a persistent mariadb process")))
              ((symbol-function 'beads-backend-dolt-sql--one-shot-mariadb)
               (lambda (sql _dolt)
                 (setq called-sql sql)
                 (beads-dolt-sql--parse-json-output
                  "[{\"id\":\"shot-1\",\"title\":\"s\"}]")))
              ((symbol-function 'beads-backend-dolt-sql--fetch-dolt-params)
               (lambda (&optional _project-root)
                 '((host . "127.0.0.1") (port . 3310)
                   (user . "root") (database . "testdb")))))
      (let ((result (beads-backend-dolt-sql--execute-sql "SELECT 1")))
        (should (equal called-sql "SELECT 1"))
        (should (equal (alist-get 'id (car result)) "shot-1"))))))

(ert-deftest beads-dolt-sql-test-execute-sql-falls-back-to-one-shot-after-native-error ()
  "Test `--execute-sql' falls back to one-shot mariadb after mysql.el fails."
  (let ((native-disconnected nil)
        (one-shot-called nil))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (cmd)
                 (cond ((equal cmd "mariadb") "/usr/bin/mariadb")
                       ((equal cmd "bd") "/usr/bin/bd")
                       (t nil))))
              ((symbol-function 'beads-dolt-sql--native-mysql-available-p)
               (lambda () t))
              ((symbol-function 'beads-dolt-sql--native-mysql-query)
               (lambda (_sql _dolt)
                 (signal 'beads-backend-error '("native mysql failed"))))
              ((symbol-function 'beads-dolt-sql--native-mysql-disconnect)
               (lambda () (setq native-disconnected t)))
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
        (should native-disconnected)
        (should (equal one-shot-called "SELECT 1"))
        (should (equal (alist-get 'id (car result)) "shot-1"))))))

(ert-deftest beads-dolt-sql-test-execute-list-uses-project-root-for-sql-params ()
  "Regression test: switching org/list buffers must switch Dolt databases."
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
              ((symbol-function 'beads-backend-dolt-sql--one-shot-mariadb)
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
        (should (equal (nreverse queries) '("db_a" "db_b")))))))

(ert-deftest beads-dolt-sql-test-native-execute-list-uses-project-root-for-sql-params ()
  "Regression test: native mysql.el transport switches Dolt databases."
  (let ((queries nil))
    (cl-letf (((symbol-function 'beads-dolt-sql--native-mysql-available-p)
               (lambda () t))
              ((symbol-function 'beads-backend-dolt-sql--fetch-dolt-params)
               (lambda (&optional project-root)
                 `((host . "127.0.0.1")
                   (port . 3310)
                   (user . "root")
                   (database . ,(if (equal project-root "/workspace/a/")
                                    "db_a"
                                  "db_b")))))
              ((symbol-function 'beads-dolt-sql--native-mysql-query)
               (lambda (_sql dolt)
                 (push (alist-get 'database dolt) queries)
                 (beads-dolt-sql--parse-json-output
                  (if (equal (alist-get 'database dolt) "db_a")
                      "[{\"id\":\"native-a\",\"title\":\"From A\"}]"
                    "[{\"id\":\"native-b\",\"title\":\"From B\"}]")))))
      (let ((issues-a (beads-backend-dolt-sql--execute-list nil "/workspace/a/"))
            (issues-b (beads-backend-dolt-sql--execute-list nil "/workspace/b/")))
        (should (equal (alist-get 'id (car issues-a)) "native-a"))
        (should (equal (alist-get 'id (car issues-b)) "native-b"))
        (should (equal (nreverse queries) '("db_a" "db_b")))))))

;;; Integration tests (only when live Dolt server is available)

(defmacro beads-dolt-sql-test--with-live-mariadb-sql (&rest body)
  "Evaluate BODY against the live project using the mariadb SQL path.
The native mysql.el path is disabled so these integration tests exercise
the same one-shot mariadb fallback used on systems without mysql.el."
  (declare (indent 0))
  `(let ((beads-dolt-sql--params nil)
         (beads-dolt-sql--params-time nil)
         (beads-dolt-sql--params-root nil)
         (beads-dolt-sql--available t)
         (beads-dolt-sql-enabled t))
     (cl-letf (((symbol-function 'beads-client--project-root)
                (lambda () default-directory))
               ((symbol-function 'beads-dolt-sql--native-mysql-available-p)
                (lambda () nil)))
       ,@body)))

(defun beads-dolt-sql-test--cli (operation args)
  "Execute OPERATION with ARGS through the bd CLI fallback."
  (beads-backend-dolt-sql--execute-fallback operation args default-directory))

(defun beads-dolt-sql-test--unwrap-single (result)
  "Return the only object in RESULT when RESULT is a single-item list."
  (if (and (listp result)
           (= (length result) 1)
           (listp (car result)))
      (car result)
    result))

(defun beads-dolt-sql-test--ids (issues)
  "Return sorted issue ids from ISSUES."
  (sort (mapcar (lambda (issue) (alist-get 'id issue)) issues)
        #'string<))

(defun beads-dolt-sql-test--assert-issue-summary-shape (issue)
  "Assert ISSUE has the fields used by SQL-backed list views."
  (should (stringp (alist-get 'id issue)))
  (should (stringp (alist-get 'title issue)))
  (should (stringp (alist-get 'status issue)))
  (should (integerp (alist-get 'priority issue)))
  (should (integerp (alist-get 'dependency_count issue)))
  (should (integerp (alist-get 'dependent_count issue)))
  (should (integerp (alist-get 'comment_count issue)))
  (should (or (null (alist-get 'parent issue))
              (stringp (alist-get 'parent issue)))))

(defun beads-dolt-sql-test--assert-show-shape (issue)
  "Assert ISSUE has detail fields used by comments and hierarchy views."
  (beads-dolt-sql-test--assert-issue-summary-shape issue)
  (should (listp (alist-get 'comments issue)))
  (should (listp (alist-get 'dependencies issue)))
  (dolist (comment (alist-get 'comments issue))
    (should (integerp (alist-get 'id comment)))
    (should (stringp (alist-get 'author comment)))
    (should (stringp (alist-get 'text comment)))
    (should (stringp (alist-get 'created_at comment))))
  (dolist (dep (alist-get 'dependencies issue))
    (should (stringp (alist-get 'issue_id dep)))
    (should (stringp (alist-get 'depends_on_id dep)))
    (should (stringp (alist-get 'type dep)))))

(defun beads-dolt-sql-test--assert-epic-shape (issue)
  "Assert ISSUE has the fields returned for epic status entries."
  (should (stringp (alist-get 'id issue)))
  (should (stringp (alist-get 'title issue)))
  (should (stringp (alist-get 'status issue)))
  (should (integerp (alist-get 'priority issue)))
  (should (equal (alist-get 'issue_type issue) "epic")))

(ert-deftest beads-dolt-sql-test-integration-list ()
  "Integration: SQL list matches bd CLI ids and exposes view fields."
  :tags '(:integration)
  (skip-unless (beads-test-integration-enabled-p))
  (skip-unless (beads-dolt-sql-test--live-dolt-sql-available-p))
  (beads-dolt-sql-test--with-live-mariadb-sql
    (let ((sql-result (beads-backend-dolt-sql--execute-list nil nil))
          (cli-result (beads-dolt-sql-test--cli
                       "list" '((all . t) (limit . 0)))))
      (should (listp sql-result))
      (should (> (length sql-result) 0))
      (should (equal (beads-dolt-sql-test--ids sql-result)
                     (beads-dolt-sql-test--ids cli-result)))
      (beads-dolt-sql-test--assert-issue-summary-shape (car sql-result)))))

(ert-deftest beads-dolt-sql-test-integration-show ()
  "Integration: SQL show matches CLI details for comments and hierarchy."
  :tags '(:integration)
  (skip-unless (beads-test-integration-enabled-p))
  (skip-unless (beads-dolt-sql-test--live-dolt-sql-available-p))
  (beads-dolt-sql-test--with-live-mariadb-sql
    (let* ((id (alist-get 'id (car (beads-backend-dolt-sql--execute-list nil nil))))
           (sql-result (beads-backend-dolt-sql--execute-show
                        `((id . ,id)) nil))
           (cli-result (beads-dolt-sql-test--unwrap-single
                        (beads-dolt-sql-test--cli "show" `((id . ,id))))))
      (should sql-result)
      (should (equal (alist-get 'id sql-result) id))
      (dolist (field '(id title status priority issue_type))
        (should (equal (alist-get field sql-result)
                       (alist-get field cli-result))))
      (should (= (length (alist-get 'comments sql-result))
                 (length (alist-get 'comments cli-result))))
      (should (= (length (alist-get 'dependencies sql-result))
                 (length (alist-get 'dependencies cli-result))))
      (beads-dolt-sql-test--assert-show-shape sql-result))))

(ert-deftest beads-dolt-sql-test-integration-stats ()
  "Integration: stats operation returns summary."
  :tags '(:integration)
  (skip-unless (beads-test-integration-enabled-p))
  (skip-unless (beads-dolt-sql-test--live-dolt-sql-available-p))
  (beads-dolt-sql-test--with-live-mariadb-sql
    (let* ((result (beads-backend-dolt-sql--execute-stats nil nil))
           (summary (alist-get 'summary result))
           (count (beads-backend-dolt-sql--execute-count nil nil)))
      (should result)
      (should (integerp (alist-get 'total_issues summary)))
      (should (integerp (alist-get 'open_issues summary)))
      (should (= (alist-get 'total_issues summary)
                 (alist-get 'count count))))))

(ert-deftest beads-dolt-sql-test-integration-ready ()
  "Integration: SQL ready matches the bd CLI ready issue set."
  :tags '(:integration)
  (skip-unless (beads-test-integration-enabled-p))
  (skip-unless (beads-dolt-sql-test--live-dolt-sql-available-p))
  (beads-dolt-sql-test--with-live-mariadb-sql
    (let ((sql-result (beads-backend-dolt-sql--execute-ready nil nil))
          (cli-result (beads-dolt-sql-test--cli "ready" nil)))
      (should (listp sql-result))
      (should (equal (beads-dolt-sql-test--ids sql-result)
                     (beads-dolt-sql-test--ids cli-result)))
      (when sql-result
        (beads-dolt-sql-test--assert-issue-summary-shape (car sql-result))))))

(ert-deftest beads-dolt-sql-test-integration-stale ()
  "Integration: SQL stale honors the days filter and matches the CLI."
  :tags '(:integration)
  (skip-unless (beads-test-integration-enabled-p))
  (skip-unless (beads-dolt-sql-test--live-dolt-sql-available-p))
  (beads-dolt-sql-test--with-live-mariadb-sql
    (let ((sql-result (beads-backend-dolt-sql--execute-stale '((days . 365)) nil))
          (cli-result (beads-dolt-sql-test--cli "stale" '((days . 365)))))
      (should (listp sql-result))
      (should (equal (beads-dolt-sql-test--ids sql-result)
                     (beads-dolt-sql-test--ids cli-result)))
      (when sql-result
        (beads-dolt-sql-test--assert-issue-summary-shape (car sql-result))))))

(ert-deftest beads-dolt-sql-test-integration-count ()
  "Integration: count operation returns count."
  :tags '(:integration)
  (skip-unless (beads-test-integration-enabled-p))
  (skip-unless (beads-dolt-sql-test--live-dolt-sql-available-p))
  (beads-dolt-sql-test--with-live-mariadb-sql
    (let ((sql-result (beads-backend-dolt-sql--execute-count nil nil))
          (cli-result (beads-dolt-sql-test--cli "count" nil)))
      (should (integerp (alist-get 'count sql-result)))
      (should (> (alist-get 'count sql-result) 0))
      (should (= (alist-get 'count sql-result)
                 (alist-get 'count cli-result))))))

(ert-deftest beads-dolt-sql-test-integration-epic-status ()
  "Integration: SQL epic status matches the bd CLI epic set."
  :tags '(:integration)
  (skip-unless (beads-test-integration-enabled-p))
  (skip-unless (beads-dolt-sql-test--live-dolt-sql-available-p))
  (beads-dolt-sql-test--with-live-mariadb-sql
    (let ((sql-result (beads-backend-dolt-sql--execute-epic-status nil nil))
          (cli-result (beads-dolt-sql-test--cli "epic_status" nil)))
      (should (listp sql-result))
      (should (equal (beads-dolt-sql-test--ids
                      (mapcar (lambda (entry) (alist-get 'epic entry)) sql-result))
                     (beads-dolt-sql-test--ids
                      (mapcar (lambda (entry) (alist-get 'epic entry)) cli-result))))
      (when sql-result
        (let ((entry (car sql-result)))
          (beads-dolt-sql-test--assert-epic-shape (alist-get 'epic entry))
          (should (integerp (alist-get 'total_children entry)))
          (should (integerp (alist-get 'closed_children entry)))
          (should (memq (alist-get 'eligible_for_close entry) '(t nil))))))))

(ert-deftest beads-dolt-sql-test-integration-freshness ()
  "Integration: SQL freshness returns read-cache tokens for all tables."
  :tags '(:integration)
  (skip-unless (beads-test-integration-enabled-p))
  (skip-unless (beads-dolt-sql-test--live-dolt-sql-available-p))
  (beads-dolt-sql-test--with-live-mariadb-sql
    (let ((freshness (beads-backend-dolt-sql--execute-freshness nil nil))
          (count (beads-backend-dolt-sql--execute-count nil nil)))
      (should (= (alist-get 'issues_count freshness)
                 (alist-get 'count count)))
      (dolist (field '(labels_count deps_count comments_count))
        (should (integerp (alist-get field freshness))))
      (dolist (field '(issues_max_updated deps_max_created comments_max_created))
        (should (or (null (alist-get field freshness))
                    (stringp (alist-get field freshness))))))))

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
