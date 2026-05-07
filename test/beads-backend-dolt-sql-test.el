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

(defun beads-dolt-sql-test--with-clean-state (body-fn)
  "Call BODY-FN with Dolt SQL state clean (enabled, available, fresh cache).
Pre-populates `beads-dolt-sql--params' so `--fetch-dolt-params' returns
from cache and never invokes the real `bd dolt show'.  Mocks
`executable-find' to report mariadb+bd present and mysql absent so
`--execute-sql' takes the one-shot mariadb branch (which uses
`call-process', easy to mock)."
  (let ((beads-dolt-sql--params '((backend . "dolt")
                                  (connection_ok . t)
                                  (database . "testdb")
                                  (host . "127.0.0.1")
                                  (port . 3310)
                                  (user . "root")))
        (beads-dolt-sql--params-time (current-time))
        (beads-dolt-sql--available t)
        (beads-dolt-sql-enabled t))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (cmd)
                 (cond ((equal cmd "mariadb") "/usr/bin/mariadb")
                       ((equal cmd "bd") "/usr/bin/bd")
                       (t nil))))
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
         (beads-dolt-sql--available t))
     (cl-letf (((symbol-function 'beads-client--project-root)
                (lambda () "/fake/project/")))
       (let ((result (beads-backend-dolt-sql--fetch-dolt-params)))
         (should (equal (alist-get 'database result) "cached")))))))

(ert-deftest beads-dolt-sql-test-fetch-dolt-params-expired-cache ()
  "Test expired cache triggers refetch."
  (beads-dolt-sql-test--with-bd-dolt-show
   "{\"backend\":\"dolt\",\"connection_ok\":true,\"database\":\"fresh\",\"host\":\"127.0.0.1\",\"port\":3310,\"user\":\"root\"}"
   (let ((beads-dolt-sql--params '((database . "stale") (host . "x")))
         (beads-dolt-sql--params-time (time-subtract (current-time) 120))
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
  "Test available-p returns nil when mariadb not found."
  (let ((beads-dolt-sql-enabled t)
        (beads-dolt-sql--available t))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_cmd) nil)))
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
               (lambda () nil)))
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
  "Test auto-detect returns bd-dolt-sql when SQL transport available."
  (let ((beads-backend--registry beads-backend--registry))
    (beads-backend-register beads-backend-dolt-sql)
    (cl-letf (((symbol-function 'beads-backend-dolt-sql--available-p)
               (lambda () t)))
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
    (cl-letf (((symbol-function 'beads-backend-dolt-sql--available-p)
               (lambda () t)))
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
        (beads-backend--registry beads-backend--registry))
    (beads-backend-dolt-sql-activate)
    (should beads-dolt-sql-enabled)
    (should beads-dolt-sql--available)
    (should-not beads-dolt-sql--params)
    (should-not beads-dolt-sql--params-time)
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
  "Test check signals when mariadb not found."
  (let ((beads-dolt-sql-enabled t))
    (cl-letf (((symbol-function 'executable-find)
               (lambda (_cmd) nil)))
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

;;; Integration tests (only when live Dolt server is available)

(ert-deftest beads-dolt-sql-test-integration-list ()
  "Integration: list operation returns issues from live Dolt server."
  (skip-unless (and (executable-find "mariadb")
                    (ignore-errors
                      (progn (require 'beads-client)
                             (let ((default-directory
                                     (or (beads-client--project-root)
                                         default-directory)))
                               (zerop (call-process "bd" nil nil nil
                                                    "dolt" "status")))))))
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
  (skip-unless (and (executable-find "mariadb")
                    (ignore-errors
                      (progn (require 'beads-client)
                             (let ((default-directory
                                     (or (beads-client--project-root)
                                         default-directory)))
                               (zerop (call-process "bd" nil nil nil
                                                    "dolt" "status")))))))
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
  (skip-unless (and (executable-find "mariadb")
                    (ignore-errors
                      (progn (require 'beads-client)
                             (let ((default-directory
                                     (or (beads-client--project-root)
                                         default-directory)))
                               (zerop (call-process "bd" nil nil nil
                                                    "dolt" "status")))))))
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
  (skip-unless (and (executable-find "mariadb")
                    (ignore-errors
                      (progn (require 'beads-client)
                             (let ((default-directory
                                     (or (beads-client--project-root)
                                         default-directory)))
                               (zerop (call-process "bd" nil nil nil
                                                    "dolt" "status")))))))
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
  (skip-unless (and (executable-find "mariadb")
                    (ignore-errors
                      (progn (require 'beads-client)
                             (let ((default-directory
                                     (or (beads-client--project-root)
                                         default-directory)))
                               (zerop (call-process "bd" nil nil nil
                                                    "dolt" "status")))))))
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
  (skip-unless (and (executable-find "mariadb")
                    (ignore-errors
                      (progn (require 'beads-client)
                             (let ((default-directory
                                     (or (beads-client--project-root)
                                         default-directory)))
                               (zerop (call-process "bd" nil nil nil
                                                    "dolt" "status")))))))
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
  (skip-unless (and (executable-find "mariadb")
                    (ignore-errors
                      (progn (require 'beads-client)
                             (let ((default-directory
                                     (or (beads-client--project-root)
                                         default-directory)))
                               (zerop (call-process "bd" nil nil nil
                                                    "dolt" "status")))))))
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
