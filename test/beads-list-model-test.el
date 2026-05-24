;;; beads-list-model-test.el --- Tests for beads-list-model.el -*- lexical-binding: t; -*-

;;; Commentary:
;; Tests for pure list model helpers.  These do not require a live bd
;; process.

;;; Code:

(require 'ert)
(require 'beads-filter)
(require 'beads-list-model)

(defun beads-list-model-test--tree-ids (nodes)
  "Return IDS from NODES in preorder."
  (let (ids)
    (dolist (node nodes)
      (push (alist-get 'id (alist-get 'issue node)) ids)
      (setq ids (append (nreverse (beads-list-model-test--tree-ids
                                   (alist-get 'children node)))
                        ids)))
    (nreverse ids)))

(ert-deftest beads-list-model-test-build-applies-filter-marked-sort-and-stats ()
  "List model applies pure shaping while stats keep the all-issues count."
  (let* ((issues '(((id . "later") (status . "closed") (priority . 1)
                    (closed_at . "2026-01-01T00:00:00Z"))
                   ((id . "open-p2") (status . "open") (priority . 2)
                    (dependency_count . 0))
                   ((id . "open-p0") (status . "open") (priority . 0)
                    (dependency_count . 0))))
         (model (beads-list-model-build
                 issues
                 :filter (beads-filter-not-closed)
                 :marked-ids '("open-p0")
                 :show-only-marked t
                 :sort-mode 'sectioned)))
    (should (equal (mapcar (lambda (issue) (alist-get 'id issue))
                           (beads-list-model-issues model))
                   '("open-p2" "open-p0")))
    (should (equal (mapcar (lambda (issue) (alist-get 'id issue))
                           (beads-list-model-display-issues model))
                   '("open-p0")))
    (should (= 3 (alist-get 'total_issues (beads-list-model-stats model))))
    (should (= 1 (alist-get 'closed_issues (beads-list-model-stats model))))))

(ert-deftest beads-list-model-test-find-by-id-and-section ()
  "Lookup and section classification work without renderer state."
  (let ((issues '(((id . "a") (status . "open"))
                  ((id . "b") (status . "blocked"))
                  ((id . "c") (status . "closed")))))
    (should (equal (alist-get 'status (beads-list-model-find-by-id issues "b"))
                   "blocked"))
    (should-not (beads-list-model-find-by-id issues "missing"))
    (should (= 0 (beads-list-model-issue-section (car issues))))
    (should (= 1 (beads-list-model-issue-section (cadr issues))))
    (should (= 2 (beads-list-model-issue-section (caddr issues))))))

(ert-deftest beads-list-model-test-open-issue-with-dependencies-is-blocked-section ()
  "Open issues with incomplete blockers sort into the blocked section."
  (should (= 1 (beads-list-model-issue-section
                '((id . "blocked-open")
                  (status . "open")
                  (dependency_count . 2))))))

(ert-deftest beads-list-model-test-flat-issues-to-forest-roots-and-nested-children ()
  "Flat issues become deterministic roots with nested children."
  (let* ((issues '(((id . "root") (title . "Root"))
                   ((id . "child") (title . "Child") (parent . "root"))
                   ((id . "grandchild") (title . "Grandchild")
                    (parent_id . "child"))
                   ((id . "other") (title . "Other"))))
         (forest (beads-list-model-flat-issues-to-forest issues))
         (root (car forest))
         (child (car (alist-get 'children root))))
    (should (equal (mapcar (lambda (node)
                             (alist-get 'id (alist-get 'issue node)))
                           forest)
                   '("root" "other")))
    (should (equal (alist-get 'id (alist-get 'issue child)) "child"))
    (should (equal (alist-get 'id (alist-get 'issue
                                             (car (alist-get 'children child))))
                   "grandchild"))
    (should (equal (beads-list-model-test--tree-ids forest)
                   '("root" "child" "grandchild" "other")))))

(ert-deftest beads-list-model-test-flat-issues-to-forest-missing-parent-is-root ()
  "Issues whose parent is absent become roots and keep parent metadata."
  (let* ((issues '(((id . "orphan") (title . "Orphan")
                    (parent . "missing-parent"))))
         (forest (beads-list-model-flat-issues-to-forest issues))
         (issue (alist-get 'issue (car forest))))
    (should (= 1 (length forest)))
    (should (equal (alist-get 'id issue) "orphan"))
    (should (equal (alist-get 'parent issue) "missing-parent"))))

(ert-deftest beads-list-model-test-flat-issues-to-forest-prevents-duplicates ()
  "Duplicate ids are represented once in the forest."
  (let* ((issues '(((id . "root") (title . "First root"))
                   ((id . "root") (title . "Duplicate root"))
                   ((id . "child") (parent . "root"))))
         (forest (beads-list-model-flat-issues-to-forest issues)))
    (should (equal (beads-list-model-test--tree-ids forest)
                   '("root" "child")))
    (should (equal (alist-get 'title (alist-get 'issue (car forest)))
                   "First root"))))

(ert-deftest beads-list-model-test-flat-issues-to-forest-filtered-subset-orphans-child ()
  "Filtered subsets can be tree-built without the filtered-out parent."
  (let* ((issues '(((id . "parent") (status . "closed"))
                   ((id . "child") (status . "open") (parent . "parent"))))
         (open-only (beads-list-model-apply-filter
                     issues (beads-filter-not-closed)))
         (forest (beads-list-model-flat-issues-to-forest open-only))
         (issue (alist-get 'issue (car forest))))
    (should (equal (beads-list-model-test--tree-ids forest) '("child")))
    (should (equal (alist-get 'parent issue) "parent"))))

(provide 'beads-list-model-test)
;;; beads-list-model-test.el ends here
