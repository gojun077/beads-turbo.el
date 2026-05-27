;;; beads-perf-test.el --- Deterministic performance tests -*- lexical-binding: t; -*-

;;; Commentary:
;; Hermetic performance regression tests for pure hot paths.  Thresholds are
;; intentionally generous: these tests should catch runaway behavior and clear
;; complexity regressions without depending on a specific developer machine.

;;; Code:

(require 'cl-lib)
(require 'ert)
(require 'beads-client)
(require 'beads-filter)
(require 'beads-list)
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

(defun beads-perf-test--count-matches (regexp string)
  "Return the number of REGEXP matches in STRING."
  (let ((start 0)
        (count 0))
    (while (string-match regexp string start)
      (cl-incf count)
      (setq start (match-end 0)))
    count))

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
    ;; These broad caps leave two orders of magnitude of headroom on a
    ;; typical developer machine.  The relative 4x-size/8x-time check is
    ;; the primary regression guard; absolute caps catch runaway behavior.
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
    ;; Forest construction should scale close to linearly.  Keep the
    ;; wall-clock caps intentionally loose and use the growth ratios to
    ;; flag obvious O(n^2) regressions while avoiding machine-specific
    ;; timing requirements in the default gate.
    (beads-perf-test--assert-under broad-larger 3.0)
    (beads-perf-test--assert-under deep-larger 3.0)
    (beads-perf-test--assert-growth-under broad-base broad-larger 8.0)
    (beads-perf-test--assert-growth-under deep-base deep-larger 12.0)))

(defun beads-perf-test--expected-filter-count (issues filter-fn)
  "Return the count of ISSUES for which FILTER-FN returns non-nil.

FILTER-FN is a plain Elisp predicate, not a `beads-filter' object.
Used as a reference implementation to verify `beads-filter-apply'
returns the same set."
  (cl-count-if filter-fn issues))

(ert-deftest beads-perf-test-filter-common-predicates ()
  "Common `beads-filter' predicates stay correct and near-linear.

Exercises the hot filter paths used by the list view:
- `beads-filter-not-closed' (status pipeline)
- `beads-filter-by-status' open
- `beads-filter-by-priority' P1
- `beads-filter-by-label' on a known generated label
- `beads-filter-compose' of not-closed + priority + label

Result sets are validated against simple reference predicates on
the generated fixtures, and timing growth is bounded by a generous
ratio so this catches accidental O(n^2) regressions without
flaking on noisy machines."
  (let* ((base-size (beads-perf-test--scaled-size 400))
         (larger-size (beads-perf-test--scaled-size 1600))
         (base-issues (beads-perf-test--flat-issues base-size))
         (larger-issues (beads-perf-test--flat-issues larger-size))
         (not-closed (beads-filter-not-closed))
         (open (beads-filter-by-status "open"))
         (p1 (beads-filter-by-priority 1))
         (label-area-0 (beads-filter-by-label "area-0"))
         (composed (beads-filter-compose not-closed p1 label-area-0))
         (filters (list (cons "not-closed" not-closed)
                        (cons "status:open" open)
                        (cons "priority:P1" p1)
                        (cons "label:area-0" label-area-0)
                        (cons "composed" composed)))
         (references
          (list (cons "not-closed"
                      (lambda (i)
                        (not (string= (alist-get 'status i) "closed"))))
                (cons "status:open"
                      (lambda (i)
                        (string= (alist-get 'status i) "open")))
                (cons "priority:P1"
                      (lambda (i) (= 1 (alist-get 'priority i))))
                (cons "label:area-0"
                      (lambda (i)
                        (member "area-0" (alist-get 'labels i))))
                (cons "composed"
                      (lambda (i)
                        (and (not (string= (alist-get 'status i) "closed"))
                             (= 1 (alist-get 'priority i))
                             (member "area-0" (alist-get 'labels i))))))))
    (dolist (entry filters)
      (let* ((label (car entry))
             (filter (cdr entry))
             (reference (alist-get label references nil nil #'string=))
             (base (beads-perf-test--measure
                    (format "beads-filter-apply %s" label) base-size
                    (lambda () (beads-filter-apply filter base-issues))))
             (larger (beads-perf-test--measure
                      (format "beads-filter-apply %s" label) larger-size
                      (lambda () (beads-filter-apply filter larger-issues)))))
        (should (= (beads-perf-test--expected-filter-count base-issues reference)
                   (length (plist-get base :result))))
        (should (= (beads-perf-test--expected-filter-count larger-issues reference)
                   (length (plist-get larger :result))))
        ;; Caps and growth ratio are intentionally generous; the goal is
        ;; to catch accidental superlinear regressions, not to enforce
        ;; absolute timings on any particular machine.
        (beads-perf-test--assert-under base 1.0)
        (beads-perf-test--assert-under larger 3.0)
        (beads-perf-test--assert-growth-under base larger 8.0)))))

(ert-deftest beads-perf-test-org-render-large-sectioned-list ()
  "Org list rendering stays correct and near-linear on large fixtures.

This exercises the default `beads-list-render-org' path used by the
interactive org list view, but keeps the test hermetic by rendering
generated issue alists directly into a string instead of creating a
display buffer or calling `bd'."
  (let* ((base-size (beads-perf-test--scaled-size 300))
         (larger-size (beads-perf-test--scaled-size 1200))
         (base-issues (beads-perf-test--flat-issues base-size))
         (larger-issues (beads-perf-test--flat-issues larger-size))
         (base (beads-perf-test--measure
                "beads-list-render-org sectioned" base-size
                (lambda ()
                  (beads-list-render-org base-issues 1 t))))
         (larger (beads-perf-test--measure
                  "beads-list-render-org sectioned" larger-size
                  (lambda ()
                    (beads-list-render-org larger-issues 1 t))))
         (base-text (plist-get base :result))
         (larger-text (plist-get larger :result)))
    (should (= base-size
               (beads-perf-test--count-matches "^:BEADS_ID: " base-text)))
    (should (= larger-size
               (beads-perf-test--count-matches "^:BEADS_ID: " larger-text)))
    (should (string-match-p "^\* Ready" larger-text))
    (should (string-match-p "^\* In Progress" larger-text))
    (should (string-match-p "^\* Blocked" larger-text))
    (should (string-match-p "^\* Completed" larger-text))
    ;; Rendering produces a sizeable org string, so the cap is deliberately
    ;; broad.  The 4x-size/8x-time growth check is the useful regression
    ;; signal for accidental quadratic string/tree handling.
    (beads-perf-test--assert-under base 1.0)
    (beads-perf-test--assert-under larger 3.0)
    (beads-perf-test--assert-growth-under base larger 8.0)))

(defun beads-perf-test--make-fake-projects (root project-count nested-depth)
  "Create PROJECT-COUNT fake beads projects under ROOT.

Each project has a `.beads/metadata.json' marker and a nested
directory chain NESTED-DEPTH levels deep used as `default-directory'
for lookups.  Returns a list of plists describing each project:
  (:db PATH :leaf-dir DIR)
where DB is the metadata.json path the discovery should return,
and LEAF-DIR is the deepest subdirectory the test should chdir to."
  (let (projects)
    (dotimes (p project-count)
      (let* ((proj-dir (expand-file-name (format "proj-%03d" p) root))
             (beads-dir (expand-file-name ".beads" proj-dir))
             (metadata (expand-file-name "metadata.json" beads-dir))
             (leaf-dir proj-dir))
        (make-directory beads-dir t)
        (with-temp-file metadata
          (insert "{\"version\":\"perf-test\"}"))
        (dotimes (d nested-depth)
          (setq leaf-dir (expand-file-name (format "sub-%02d" d) leaf-dir))
          (make-directory leaf-dir t))
        (push (list :db metadata :leaf-dir leaf-dir) projects)))
    (nreverse projects)))

(defun beads-perf-test--lookup-from (dir)
  "Resolve a beads database with `default-directory' temporarily set to DIR.

Hermetic: unsets `BEADS_DIR'/`BEADS_DB' for the call so only the
on-disk fixture under DIR is consulted."
  (let ((default-directory (file-name-as-directory dir))
        ;; Without `=', these entries unset the variable rather than
        ;; setting it to empty (which would be truthy and short-circuit
        ;; the discovery code into returning `default-directory').
        (process-environment (cons "BEADS_DIR" (cons "BEADS_DB" process-environment))))
    (beads-client--find-database)))

(ert-deftest beads-perf-test-client-find-database-cache ()
  "`beads-client--find-database' returns correct per-project paths fast.

Creates a tree of fake projects, each with a `.beads/metadata.json'
marker and a nested chain of subdirectories.  Walks every leaf
once to populate the per-search-directory cache, verifies the
returned database path matches the expected metadata file, then
repeats the same walks N times and asserts the cached pass is at
least roughly as cheap as the cold pass and well under absolute
caps.  Bounds are intentionally generous — the goal is to catch
regressions like a broken cache or quadratic path-walk, not to
enforce machine-specific timings."
  (let* ((tmp-root (make-temp-file "beads-perf-find-db-" t))
         (project-count (beads-perf-test--scaled-size 6))
         (nested-depth 5)
         (repeat-count (beads-perf-test--scaled-size 20)))
    (unwind-protect
        (let* ((projects (beads-perf-test--make-fake-projects
                          tmp-root project-count nested-depth))
               (leaves (mapcar (lambda (p) (plist-get p :leaf-dir)) projects))
               (fixture-size (* project-count nested-depth)))
          (clrhash beads-client--db-cache)
          ;; Cold pass: each unique leaf dir is a cache miss that walks
          ;; the tree.  Verify correctness as we go.
          (let ((cold (beads-perf-test--measure
                       "beads-client--find-database cold" fixture-size
                       (lambda ()
                         (dolist (proj projects)
                           (let ((expected (plist-get proj :db))
                                 (got (beads-perf-test--lookup-from
                                       (plist-get proj :leaf-dir))))
                             (should (file-equal-p expected got))))
                         t))))
            ;; Warm pass: repeatedly chdir into every leaf and resolve
            ;; from the cache.  This is the path real interactive use
            ;; hits on every list refresh.
            (let ((warm (beads-perf-test--measure
                         "beads-client--find-database cached"
                         (* repeat-count (length leaves))
                         (lambda ()
                           (dotimes (_ repeat-count)
                             (dolist (leaf leaves)
                               (beads-perf-test--lookup-from leaf)))
                           t))))
              (beads-perf-test--assert-under cold 2.0)
              (beads-perf-test--assert-under warm 2.0)
              ;; Cached lookups should not blow past a small multiple of
              ;; the cold cost when normalized per call.  Be generous to
              ;; avoid flakes on noisy machines.
              (let* ((cold-per-call (/ (plist-get cold :elapsed)
                                       (max 1 (length projects))))
                     (warm-per-call (/ (plist-get warm :elapsed)
                                       (max 1 (* repeat-count
                                                 (length leaves)))))
                     (ratio (/ warm-per-call (max 1e-9 cold-per-call))))
                (when (> ratio 2.0)
                  (ert-fail
                   (format
                    "cached lookup %.6fs/call exceeded 2x cold %.6fs/call"
                    warm-per-call cold-per-call)))))))
      (delete-directory tmp-root t))))

(provide 'beads-perf-test)
;;; beads-perf-test.el ends here
