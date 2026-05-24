;;; beads-perf-test.el --- Deterministic performance tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Hermetic performance regression tests for pure hot paths.  Thresholds are
;; intentionally generous: these tests should catch runaway behavior and clear
;; complexity regressions without depending on a specific developer machine.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'beads-filter)
(require 'beads-list-model)

(defun beads-perf-test--scale ()
  "Return the positive integer fixture scale from BEADS_PERF_SCALE."
  (let* ((raw (or (getenv "BEADS_PERF_SCALE") "1"))
         (scale (string-to-number raw)))
    (max 1 scale)))

(defun beads-perf-test--scaled-size (size)
  "Return SIZE multiplied by `beads-perf-test--scale'."
  (* size (beads-perf-test--scale)))

(defun beads-perf-test--measure (operation size thunk)
  "Measure OPERATION for fixture SIZE by calling THUNK.

Return a plist containing `:operation', `:size', `:elapsed' and
`:result'.  Garbage collection runs before the measurement to reduce
noise in batch runs."
  (garbage-collect)
  (let ((start (float-time))
        result)
    (setq result (funcall thunk))
    (list :operation operation
          :size size
          :elapsed (- (float-time) start)
          :result result)))

(defun beads-perf-test--assert-under (measurement limit)
  "Assert MEASUREMENT elapsed time is under LIMIT seconds."
  (let ((elapsed (plist-get measurement :elapsed)))
    (when (>= elapsed limit)
      (ert-fail
       (format "%s size=%d elapsed %.4fs exceeded %.4fs"
               (plist-get measurement :operation)
               (plist-get measurement :size)
               elapsed
               limit)))))

(defun beads-perf-test--assert-growth-under (base larger ratio-limit)
  "Assert LARGER elapsed growth over BASE stays under RATIO-LIMIT."
  (let* ((base-elapsed (max 0.000001 (plist-get base :elapsed)))
         (larger-elapsed (plist-get larger :elapsed))
         (ratio (/ larger-elapsed base-elapsed)))
    (when (>= ratio ratio-limit)
      (ert-fail
       (format "%s growth %.2fx exceeded %.2fx (base size=%d %.4fs, larger size=%d %.4fs)"
               (plist-get larger :operation)
               ratio
               ratio-limit
               (plist-get base :size)
               (plist-get base :elapsed)
               (plist-get larger :size)
               larger-elapsed)))))

(defun beads-perf-test--flat-issues (count)
  "Return COUNT generated mixed issue alists for flat list-model tests."
  (let ((statuses ["open" "in_progress" "blocked" "closed"])
        (types ["task" "bug" "feature" "chore"])
        issues)
    (cl-loop for i from 0 below count do
      (let* ((status (aref statuses (% i (length statuses))))
             (closedp (string= status "closed"))
             (dependency-count (if (and (string= status "open")
                                        (zerop (% i 10)))
                                   1
                                 0)))
        (push (list (cons 'id (format "perf-%05d" i))
                    (cons 'title (format "Generated performance issue %05d" i))
                    (cons 'description
                          (format "Synthetic issue %05d for list model timing" i))
                    (cons 'status status)
                    (cons 'priority (% i 5))
                    (cons 'issue_type (aref types (% i (length types))))
                    (cons 'assignee (unless (zerop (% i 3))
                                      (format "user-%d" (% i 7))))
                    (cons 'dependency_count dependency-count)
                    (cons 'labels (list (format "area-%d" (% i 6))))
                    (cons 'closed_at (when closedp
                                       (format "2026-05-%02dT12:00:00Z"
                                               (1+ (% i 28))))))
              issues)))
    (nreverse issues)))

(defun beads-perf-test--count-status (issues status)
  "Return number of ISSUES whose status equals STATUS."
  (cl-count-if (lambda (issue)
                 (string= (alist-get 'status issue) status))
               issues))

(defun beads-perf-test--assert-flat-model-correct (model all-issues)
  "Assert MODEL has expected counts for ALL-ISSUES."
  (let* ((stats (beads-list-model-stats model))
         (expected-open (beads-perf-test--count-status all-issues "open"))
         (expected-in-progress (beads-perf-test--count-status all-issues "in_progress"))
         (expected-blocked (beads-perf-test--count-status all-issues "blocked"))
         (expected-closed (beads-perf-test--count-status all-issues "closed")))
    (should (= (length all-issues)
               (alist-get 'total_issues stats)))
    (should (= expected-open (alist-get 'open_issues stats)))
    (should (= expected-in-progress (alist-get 'in_progress_issues stats)))
    (should (= expected-closed (alist-get 'closed_issues stats)))
    ;; Some generated open issues have dependency_count > 0 and therefore
    ;; count as blocked in the model stats in addition to explicit blocked
    ;; issues.
    (should (>= (alist-get 'blocked_issues stats) expected-blocked))
    (should (= (- (length all-issues) expected-closed)
               (length (beads-list-model-issues model))))
    (should (= (length (beads-list-model-issues model))
               (length (beads-list-model-display-issues model))))))

(defun beads-perf-test--build-flat-model (issues)
  "Build a representative flat list model from ISSUES."
  (beads-list-model-build
   issues
   :filter (beads-filter-not-closed)
   :marked-ids nil
   :show-only-marked nil
   :sort-mode 'sectioned))

(defun beads-perf-test--broad-hierarchy-issues (children-count)
  "Return one root issue with CHILDREN-COUNT direct children."
  (let ((issues (list (list (cons 'id "broad-root")
                            (cons 'title "Broad root")))))
    (cl-loop for i from 0 below children-count do
      (push (list (cons 'id (format "broad-child-%05d" i))
                  (cons 'title (format "Broad child %05d" i))
                  (cons 'parent "broad-root"))
            issues))
    (nreverse issues)))

(defun beads-perf-test--deep-hierarchy-issues (count)
  "Return COUNT issues in a single parent-child chain."
  (let (issues)
    (cl-loop for i from 0 below count do
      (push (list (cons 'id (format "deep-%05d" i))
                  (cons 'title (format "Deep issue %05d" i))
                  (cons 'parent (unless (zerop i)
                                  (format "deep-%05d" (1- i)))))
            issues))
    (nreverse issues)))

(defun beads-perf-test--forest-count (nodes)
  "Return total node count in forest NODES."
  (let ((stack (copy-sequence nodes))
        (count 0))
    (while stack
      (let ((node (pop stack)))
        (cl-incf count)
        (setq stack (append (alist-get 'children node) stack))))
    count))

(defun beads-perf-test--forest-max-depth (nodes)
  "Return maximum tree depth in forest NODES."
  (let ((stack (mapcar (lambda (node) (cons node 1)) nodes))
        (max-depth 0))
    (while stack
      (let* ((entry (pop stack))
             (node (car entry))
             (depth (cdr entry)))
        (setq max-depth (max max-depth depth))
        (dolist (child (alist-get 'children node))
          (push (cons child (1+ depth)) stack))))
    max-depth))

(defun beads-perf-test--root-child-count (node)
  "Return direct child count for NODE."
  (let ((count 0))
    (dolist (_child (alist-get 'children node) count)
      (cl-incf count)
      count)))

(defun beads-perf-test--assert-broad-forest-correct (forest expected-count)
  "Assert broad hierarchy FOREST contains EXPECTED-COUNT issues."
  (should (= 1 (length forest)))
  (should (= expected-count (beads-perf-test--forest-count forest)))
  (should (= (1- expected-count)
             (beads-perf-test--root-child-count (car forest)))))

(defun beads-perf-test--assert-deep-forest-correct (forest expected-count)
  "Assert deep hierarchy FOREST contains EXPECTED-COUNT issues."
  (should (= 1 (length forest)))
  (should (= expected-count (beads-perf-test--forest-count forest)))
  (should (= expected-count (beads-perf-test--forest-max-depth forest))))

(ert-deftest beads-perf-test-list-model-large-flat-build ()
  "Flat list model build stays correct and near-linear on large fixtures."
  (let* ((base-size (beads-perf-test--scaled-size 400))
         (larger-size (beads-perf-test--scaled-size 1600))
         (base-issues (beads-perf-test--flat-issues base-size))
         (larger-issues (beads-perf-test--flat-issues larger-size))
         (base (beads-perf-test--measure
                "beads-list-model-build flat" base-size
                (lambda ()
                  (beads-perf-test--build-flat-model base-issues))))
         (larger (beads-perf-test--measure
                  "beads-list-model-build flat" larger-size
                  (lambda ()
                    (beads-perf-test--build-flat-model larger-issues)))))
    (beads-perf-test--assert-flat-model-correct
     (plist-get base :result) base-issues)
    (beads-perf-test--assert-flat-model-correct
     (plist-get larger :result) larger-issues)
    (beads-perf-test--assert-under base 1.0)
    (beads-perf-test--assert-under larger 3.0)
    (beads-perf-test--assert-growth-under base larger 8.0)))

(ert-deftest beads-perf-test-list-model-hierarchy-forest-build ()
  "Hierarchy forest construction stays correct on broad and deep fixtures."
  (let* ((broad-base-children (beads-perf-test--scaled-size 200))
         (broad-larger-children (beads-perf-test--scaled-size 800))
         (deep-base-size (beads-perf-test--scaled-size 100))
         (deep-larger-size (beads-perf-test--scaled-size 400))
         (broad-base-issues
          (beads-perf-test--broad-hierarchy-issues broad-base-children))
         (broad-larger-issues
          (beads-perf-test--broad-hierarchy-issues broad-larger-children))
         (deep-base-issues
          (beads-perf-test--deep-hierarchy-issues deep-base-size))
         (deep-larger-issues
          (beads-perf-test--deep-hierarchy-issues deep-larger-size))
         (broad-base (beads-perf-test--measure
                      "beads-list-model-flat-issues-to-forest broad"
                      (length broad-base-issues)
                      (lambda ()
                        (beads-list-model-flat-issues-to-forest
                         broad-base-issues))))
         (broad-larger (beads-perf-test--measure
                        "beads-list-model-flat-issues-to-forest broad"
                        (length broad-larger-issues)
                        (lambda ()
                          (beads-list-model-flat-issues-to-forest
                           broad-larger-issues))))
         (deep-base (beads-perf-test--measure
                     "beads-list-model-flat-issues-to-forest deep"
                     (length deep-base-issues)
                     (lambda ()
                       (beads-list-model-flat-issues-to-forest
                        deep-base-issues))))
         (deep-larger (beads-perf-test--measure
                       "beads-list-model-flat-issues-to-forest deep"
                       (length deep-larger-issues)
                       (lambda ()
                         (beads-list-model-flat-issues-to-forest
                          deep-larger-issues)))))
    (beads-perf-test--assert-broad-forest-correct
     (plist-get broad-base :result) (length broad-base-issues))
    (beads-perf-test--assert-broad-forest-correct
     (plist-get broad-larger :result) (length broad-larger-issues))
    (beads-perf-test--assert-deep-forest-correct
     (plist-get deep-base :result) (length deep-base-issues))
    (beads-perf-test--assert-deep-forest-correct
     (plist-get deep-larger :result) (length deep-larger-issues))
    (beads-perf-test--assert-under broad-larger 3.0)
    (beads-perf-test--assert-under deep-larger 3.0)
    (beads-perf-test--assert-growth-under broad-base broad-larger 8.0)
    (beads-perf-test--assert-growth-under deep-base deep-larger 12.0)))

(provide 'beads-perf-test)
;;; beads-perf-test.el ends here
