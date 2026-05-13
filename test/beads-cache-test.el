;;; beads-cache-test.el --- Tests for beads-cache.el -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the project-scoped issue cache.  Uses `cl-letf' to mock
;; `beads-client-list', `beads-client-freshness', and the backend
;; capability check so the tests run hermetically without a live
;; Dolt SQL server.

;;; Code:

(require 'ert)
(require 'cl-lib)
(require 'beads-cache)
(require 'beads-client)

(defmacro beads-cache-test--with-mocks (root list-result freshness-tokens
                                              supported-p &rest body)
  "Eval BODY with cache + client functions mocked.

ROOT is the project root reported by `beads-client--project-root'.

LIST-RESULT is the value `beads-client-list' returns each call.

FRESHNESS-TOKENS is a list of values; each call to
`beads-client-freshness' pops the head and returns it.  When
exhausted, returns the last element forever.

SUPPORTED-P is the boolean returned by `beads-cache-supported-p'.

Each invocation also resets the cache registry."
  (declare (indent 4))
  `(let ((beads-cache--registry (make-hash-table :test 'equal))
         (beads-cache-enabled t)
         (--list-calls 0)
         (--freshness-calls 0)
         (--remaining-tokens (copy-sequence ,freshness-tokens)))
     (cl-letf (((symbol-function 'beads-client--project-root)
                (lambda () ,root))
               ((symbol-function 'beads-cache-supported-p)
                (lambda () ,supported-p))
               ((symbol-function 'beads-client-list)
                (lambda (&optional _filters)
                  (cl-incf --list-calls)
                  ,list-result))
               ((symbol-function 'beads-client-freshness)
                (lambda ()
                  (cl-incf --freshness-calls)
                  (if (cdr --remaining-tokens)
                      (pop --remaining-tokens)
                    (car --remaining-tokens)))))
       ,@body)))

;;; Cache lookup / registry

(ert-deftest beads-cache-test-for-project-creates-entry ()
  "Calling `beads-cache-for-project' twice returns the same instance."
  (beads-cache-test--with-mocks "/tmp/proj/" '() '(nil) t
    (let ((c1 (beads-cache-for-project))
          (c2 (beads-cache-for-project)))
      (should c1)
      (should (eq c1 c2)))))

(ert-deftest beads-cache-test-for-project-no-root ()
  "When no project root can be resolved, return nil."
  (beads-cache-test--with-mocks nil '() '(nil) t
    (should-not (beads-cache-for-project))))

(ert-deftest beads-cache-test-invalidate-drops-entry ()
  "`beads-cache-invalidate' removes the registry entry."
  (beads-cache-test--with-mocks "/tmp/proj/" '() '(nil) t
    (let ((c1 (beads-cache-for-project)))
      (should c1)
      (beads-cache-invalidate)
      ;; New call returns a fresh struct, not the same instance.
      (should-not (eq c1 (beads-cache-for-project))))))

;;; Refresh semantics

(ert-deftest beads-cache-test-refresh-cold-fetches-list ()
  "First refresh on a cold cache always fetches the list."
  (beads-cache-test--with-mocks "/tmp/proj/" '(((id . "a"))) '(token-1) t
    (let ((result (beads-cache-refresh)))
      (should (car result))                    ; CHANGED-P = t
      (should (equal (cdr result) '(((id . "a")))))
      (should (= --list-calls 1)))))

(ert-deftest beads-cache-test-refresh-unchanged-token-skips-fetch ()
  "Second refresh with same token returns cached, no list call."
  (beads-cache-test--with-mocks "/tmp/proj/" '(((id . "a")))
                                '(token-1 token-1) t
    ;; First refresh primes the cache.
    (beads-cache-refresh)
    (should (= --list-calls 1))
    ;; Second refresh: token unchanged, no new list fetch.
    (let ((result (beads-cache-refresh)))
      (should-not (car result))                ; CHANGED-P = nil
      (should (equal (cdr result) '(((id . "a")))))
      (should (= --list-calls 1))              ; still 1, not 2
      (should (= --freshness-calls 2)))))      ; one per refresh

(ert-deftest beads-cache-test-refresh-changed-token-refetches ()
  "Token change triggers a fresh list fetch."
  (beads-cache-test--with-mocks "/tmp/proj/" '(((id . "a")))
                                '(token-1 token-2) t
    (beads-cache-refresh)
    (let ((result (beads-cache-refresh)))
      (should (car result))                    ; CHANGED-P = t
      (should (= --list-calls 2)))))

(ert-deftest beads-cache-test-refresh-force-bypasses-token-check ()
  "FORCE re-fetches even when the token would say unchanged."
  (beads-cache-test--with-mocks "/tmp/proj/" '(((id . "a")))
                                '(token-1 token-1) t
    (beads-cache-refresh)
    (should (= --list-calls 1))
    (beads-cache-refresh nil t)
    (should (= --list-calls 2))))

(ert-deftest beads-cache-test-refresh-without-backend-support ()
  "When backend lacks freshness op, every refresh re-fetches."
  (beads-cache-test--with-mocks "/tmp/proj/" '(((id . "a"))) '(nil) nil
    (beads-cache-refresh)
    (beads-cache-refresh)
    (should (= --list-calls 2))
    (should (= --freshness-calls 0))))         ; never called

(ert-deftest beads-cache-test-refresh-disabled-passthrough ()
  "When `beads-cache-enabled' is nil, every call refetches."
  (beads-cache-test--with-mocks "/tmp/proj/" '(((id . "a"))) '(token-1) t
    (let ((beads-cache-enabled nil))
      (beads-cache-refresh)
      (beads-cache-refresh)
      (should (= --list-calls 2)))))

(ert-deftest beads-cache-test-refresh-token-fetched-before-list ()
  "On a full re-fetch, the freshness token is captured BEFORE the list.
Verified by the call order: freshness first, then list."
  (let ((order nil))
    (beads-cache-test--with-mocks "/tmp/proj/" '(((id . "a"))) '(token-1) t
      (cl-letf* ((orig-freshness (symbol-function 'beads-client-freshness))
                 ((symbol-function 'beads-client-freshness)
                  (lambda () (push 'freshness order) (funcall orig-freshness)))
                 (orig-list (symbol-function 'beads-client-list))
                 ((symbol-function 'beads-client-list)
                  (lambda (&optional filters)
                    (push 'list order) (funcall orig-list filters))))
        (beads-cache-refresh)
        (should (equal (nreverse order) '(freshness list)))))))

(ert-deftest beads-cache-test-refresh-freshness-failure-degrades ()
  "If freshness check returns nil, fall back to a full fetch."
  (beads-cache-test--with-mocks "/tmp/proj/" '(((id . "a")))
                                '(token-1 nil) t
    ;; First refresh primes with token-1.
    (beads-cache-refresh)
    (should (= --list-calls 1))
    ;; Second refresh: freshness returns nil → degrade to full fetch.
    (let ((result (beads-cache-refresh)))
      (should (car result))                    ; CHANGED-P = t
      (should (= --list-calls 2)))))

;;; Get-issues helper

(ert-deftest beads-cache-test-get-issues-after-refresh ()
  "`beads-cache-get-issues' returns the cached issues."
  (beads-cache-test--with-mocks "/tmp/proj/" '(((id . "a")) ((id . "b")))
                                '(token-1) t
    (beads-cache-refresh)
    (should (equal (beads-cache-get-issues)
                   '(((id . "a")) ((id . "b")))))))

;;; Write-invalidation advice

(ert-deftest beads-cache-test-write-invalidates-cache ()
  "Successful write operation drops the project cache entry."
  (beads-cache-test--with-mocks "/tmp/proj/" '(((id . "a"))) '(token-1) t
    ;; Prime cache.
    (beads-cache-refresh)
    (should (beads-cache-get-issues))
    ;; Mock the underlying request to succeed; the advice should fire.
    (cl-letf (((symbol-function 'beads-backend-cli-execute)
               (lambda (&rest _) '((id . "x")))))
      (beads-client-update "x" :status "closed"))
    ;; Cache entry has been invalidated.
    (should-not (beads-cache-get-issues))))

(ert-deftest beads-cache-test-read-does-not-invalidate ()
  "Read operations (e.g. `show', `stats') leave the cache intact."
  (beads-cache-test--with-mocks "/tmp/proj/" '(((id . "a"))) '(token-1) t
    (beads-cache-refresh)
    (should (beads-cache-get-issues))
    (cl-letf (((symbol-function 'beads-backend-cli-execute)
               (lambda (&rest _) '((id . "a")))))
      (beads-client-show "a"))
    (should (beads-cache-get-issues))))

(ert-deftest beads-cache-test-dry-run-create-does-not-invalidate ()
  "A dry-run `create' must not drop the cache (no DB write happens)."
  (beads-cache-test--with-mocks "/tmp/proj/" '(((id . "a"))) '(token-1) t
    (beads-cache-refresh)
    (should (beads-cache-get-issues))
    (cl-letf (((symbol-function 'beads-backend-cli-execute)
               (lambda (&rest _) '((id . "preview")))))
      (beads-client-create "T" :dry-run t))
    (should (beads-cache-get-issues))))

(provide 'beads-cache-test)
;;; beads-cache-test.el ends here
