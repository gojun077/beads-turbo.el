;;; beads-client-test.el --- Tests for beads-client.el -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for the Beads client module.
;;
;; Test categories:
;; 1. Discovery tests - auto-discovery of .beads/beads.db
;; 2. Request dispatch tests - CLI dispatch (mocked)
;; 3. Integration tests - actual CLI communication (tagged :integration)
;;
;; Note on test isolation:
;; Integration tests connect to the actual beads CLI in this repo.
;; Tests that create issues are tagged :destructive and MUST delete
;; their test data via beads-client-delete to avoid polluting the
;; production database.  Read-only integration tests are safe to run.

;;; Code:

(require 'ert)
(require 'json)
(require 'beads-client)

;;; Discovery tests

(ert-deftest beads-client-test-find-database-current-dir ()
  "Test that beads-client--find-database finds .beads/beads.db in current directory."
  (let ((temp-dir (make-temp-file "beads-test-" t)))
    (unwind-protect
        (let ((beads-dir (expand-file-name ".beads" temp-dir))
              (default-directory temp-dir))
          (make-directory beads-dir)
          (write-region "" nil (expand-file-name "beads.db" beads-dir))
          (should (equal (beads-client--find-database)
                        (expand-file-name ".beads/beads.db" temp-dir))))
      (delete-directory temp-dir t))))

(ert-deftest beads-client-test-find-database-parent-dir ()
  "Test that beads-client--find-database walks up parent directories."
  (let ((temp-root (make-temp-file "beads-test-root-" t)))
    (unwind-protect
        (let* ((beads-dir (expand-file-name ".beads" temp-root))
               (sub-dir (expand-file-name "sub/dir" temp-root))
               (default-directory sub-dir))
          (make-directory beads-dir)
          (make-directory sub-dir t)
          (write-region "" nil (expand-file-name "beads.db" beads-dir))
          (should (equal (beads-client--find-database)
                        (expand-file-name ".beads/beads.db" temp-root))))
      (delete-directory temp-root t))))

(ert-deftest beads-client-test-find-database-not-found ()
  "Test that beads-client--find-database returns nil when no database found."
  (let ((temp-dir (make-temp-file "beads-test-" t)))
    (unwind-protect
        (let ((default-directory temp-dir))
          (should (null (beads-client--find-database))))
      (delete-directory temp-dir t))))

(ert-deftest beads-client-test-find-database-beads-db-env ()
  "Test that BEADS_DB environment variable overrides auto-discovery."
  (let ((temp-dir (make-temp-file "beads-test-" t)))
    (unwind-protect
        (let* ((db-path (expand-file-name "custom/beads.db" temp-dir))
               (process-environment (cons (concat "BEADS_DB=" db-path)
                                         process-environment))
               (default-directory temp-dir))
          (make-directory (file-name-directory db-path) t)
          (write-region "" nil db-path)
          (should (equal (beads-client--find-database) db-path)))
      (delete-directory temp-dir t))))

(ert-deftest beads-client-test-find-database-beads-dir-env ()
  "Test that BEADS_DIR environment variable is used for discovery."
  (let ((temp-dir (make-temp-file "beads-test-" t)))
    (unwind-protect
        (let* ((beads-dir (expand-file-name "custom-beads" temp-dir))
               (db-path (expand-file-name "beads.db" beads-dir))
               (process-environment (cons (concat "BEADS_DIR=" beads-dir)
                                         process-environment))
               (default-directory temp-dir))
          (make-directory beads-dir t)
          (write-region "" nil db-path)
          (should (equal (beads-client--find-database) db-path)))
      (delete-directory temp-dir t))))

(ert-deftest beads-client-test-find-database-redirect ()
  "Test that .beads/redirect file is followed."
  (let ((temp-dir (make-temp-file "beads-test-" t)))
    (unwind-protect
        (let* ((real-beads-dir (expand-file-name "real-beads" temp-dir))
               (fake-beads-dir (expand-file-name ".beads" temp-dir))
               (redirect-file (expand-file-name "redirect" fake-beads-dir))
               (db-path (expand-file-name "beads.db" real-beads-dir))
               (default-directory temp-dir))
          (make-directory fake-beads-dir t)
          (make-directory real-beads-dir t)
          (write-region real-beads-dir nil redirect-file)
          (write-region "" nil db-path)
          (should (equal (beads-client--find-database) db-path)))
      (delete-directory temp-dir t))))

(ert-deftest beads-client-test-find-database-custom-db-name ()
  "Test that custom .db files are found (excluding vc.db and backups)."
  (let ((temp-dir (make-temp-file "beads-test-" t)))
    (unwind-protect
        (let* ((beads-dir (expand-file-name ".beads" temp-dir))
               (custom-db (expand-file-name "custom.db" beads-dir))
               (default-directory temp-dir))
          (make-directory beads-dir t)
          (write-region "" nil custom-db)
          (write-region "" nil (expand-file-name "vc.db" beads-dir))
          (write-region "" nil (expand-file-name "backup.db" beads-dir))
          (should (equal (beads-client--find-database) custom-db)))
      (delete-directory temp-dir t))))

;;; Request dispatch tests (mock the CLI)

(ert-deftest beads-client-test-request-dispatches-to-cli ()
  "Test that beads-client-request dispatches to CLI backend."
  (let ((cli-called nil))
    (cl-letf (((symbol-function 'beads-backend-cli-execute)
               (lambda (operation args _project-root)
                 (setq cli-called (list operation args))
                 '((id . "bd-001") (title . "Test")))))
      (let ((result (beads-client-request "show" '((id . "bd-001")))))
        (should cli-called)
        (should (equal (car cli-called) "show"))
        (should (equal (alist-get 'id result) "bd-001"))))))

(ert-deftest beads-client-test-request-error-handling ()
  "Test that beads-client-request wraps backend errors."
  (cl-letf (((symbol-function 'beads-backend-cli-execute)
             (lambda (_op _args _root)
               (signal 'beads-backend-error '("CLI failed")))))
    (should-error (beads-client-request "test-operation" nil)
                  :type 'beads-client-error)))

;;; Integration tests (require bd CLI)

(ert-deftest beads-client-test-list ()
  "Test that beads-client-list returns issues."
  :tags '(:integration)
  (skip-unless (beads-client--find-database))
  (let ((issues (beads-client-list)))
    (should (listp issues))))

(ert-deftest beads-client-test-list-with-filters ()
  "Test that beads-client-list accepts filter arguments."
  :tags '(:integration)
  (skip-unless (beads-client--find-database))
  (let ((issues (beads-client-list '(:status "open" :priority 1))))
    (should (listp issues))))

(ert-deftest beads-client-test-ready ()
  "Test that beads-client-ready returns unblocked issues."
  :tags '(:integration)
  (skip-unless (beads-client--find-database))
  (let ((issues (beads-client-ready)))
    (should (listp issues))))

(ert-deftest beads-client-test-stats ()
  "Test that beads-client-stats returns statistics."
  :tags '(:integration)
  (skip-unless (beads-client--find-database))
  (let ((stats (beads-client-stats)))
    (should (numberp (alist-get 'total_issues stats)))
    (should (numberp (alist-get 'open_issues stats)))
    (should (numberp (alist-get 'closed_issues stats)))))

(ert-deftest beads-client-test-show ()
  "Test that beads-client-show returns issue details."
  :tags '(:integration)
  (skip-unless (beads-client--find-database))
  (let ((issues (beads-client-list '(:limit 1))))
    (skip-unless (> (length issues) 0))
    (let* ((issue-id (alist-get 'id (car issues)))
           (issue (beads-client-show issue-id)))
      (should (stringp (alist-get 'id issue)))
      (should (stringp (alist-get 'title issue)))
      (should (stringp (alist-get 'status issue))))))

(ert-deftest beads-client-test-create-and-close ()
  "Test creating and closing an issue via CLI."
  :tags '(:integration :destructive)
  (skip-unless (beads-client--find-database))
  (let* ((title "Test issue from ERT")
         (issue (beads-client-create
                 title
                 :description "Test description"
                 :priority 2
                 :issue-type "task"))
         (issue-id (alist-get 'id issue)))
    (should (stringp issue-id))
    (should (equal (alist-get 'title issue) title))
    (unwind-protect
        (progn
          (let ((show-issue (beads-client-show issue-id)))
            (should (stringp (alist-get 'id show-issue))))
          (let ((closed-issue (beads-client-close issue-id "Test cleanup")))
            (should (equal (alist-get 'status closed-issue) "closed"))))
      (beads-client-delete (list issue-id) :force t))))

(ert-deftest beads-client-test-update ()
  "Test updating an issue via CLI."
  :tags '(:integration :destructive)
  (skip-unless (beads-client--find-database))
  (let* ((issue (beads-client-create
                 "Test update issue"
                 :priority 2))
         (issue-id (alist-get 'id issue)))
    (unwind-protect
        (let* ((updated-issue (beads-client-update
                               issue-id
                               :status "in_progress"
                               :priority 1
                               :notes "Working on it"))
               (show-issue (beads-client-show issue-id)))
          (should (equal (alist-get 'status updated-issue) "in_progress"))
          (should (equal (alist-get 'priority show-issue) 1)))
      (beads-client-delete (list issue-id) :force t))))

(ert-deftest beads-client-test-count ()
  "Test that beads-client-count returns grouped counts."
  :tags '(:integration)
  (skip-unless (beads-client--find-database))
  (let ((counts (beads-client-count '(:group-by "status"))))
    (should (listp counts))))

(ert-deftest beads-client-test-dep-add-remove ()
  "Test adding and removing dependencies via CLI."
  :tags '(:integration :destructive)
  (skip-unless (beads-client--find-database))
  (let* ((issue1 (beads-client-create "Dependency test 1"))
         (issue2 (beads-client-create "Dependency test 2"))
         (id1 (alist-get 'id issue1))
         (id2 (alist-get 'id issue2)))
    (unwind-protect
        (progn
          (let ((_add-result (beads-client-dep-add id1 id2 "blocks")))
            (should t))
          (let ((_show-issue (beads-client-show id1)))
            (should t))
          (let ((_remove-result (beads-client-dep-remove id1 id2)))
            (should t)))
      (beads-client-delete (list id1 id2) :force t))))

(ert-deftest beads-client-test-label-operations ()
  "Test adding and removing labels via CLI."
  :tags '(:integration :destructive)
  (skip-unless (beads-client--find-database))
  (let* ((issue (beads-client-create "Label test"))
         (issue-id (alist-get 'id issue)))
    (unwind-protect
        (progn
          (let ((_add-result (beads-client-label-add issue-id "test-label")))
            (should t))
          (let* ((show-issue (beads-client-show issue-id))
                 (labels (alist-get 'labels show-issue)))
            (should (member "test-label" (append labels nil))))
          (let ((_remove-result (beads-client-label-remove issue-id "test-label")))
            (should t)))
      (beads-client-delete (list issue-id) :force t))))

(ert-deftest beads-client-test-invalid-operation ()
  "Test that invalid operations are handled."
  :tags '(:integration)
  (skip-unless (beads-client--find-database))
  (should-error (beads-client-request "invalid-operation" nil)
                :type 'beads-client-error))

(provide 'beads-client-test)
;;; beads-client-test.el ends here
