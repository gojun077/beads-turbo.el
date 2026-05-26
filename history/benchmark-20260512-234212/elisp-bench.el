;;; elisp-bench.el --- Dolt SQL benchmark script -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'json)
(require 'beads-backend)
(require 'beads-backend-bd)
(require 'beads-backend-dolt-sql)
(require 'beads-client)

(defvar bench-iters 10)
(defvar bench-results nil)

(defun bench--time-it (fn)
  (let ((times nil))
    (dotimes (_ bench-iters)
      (garbage-collect)
      (let* ((start (float-time))
             (_ (funcall fn))
             (elapsed (* 1000.0 (- (float-time) start))))
        (push elapsed times)))
    (nreverse times)))

(defun bench--stats (times)
  (let* ((sorted (sort (copy-sequence times) #'<))
         (n (length sorted))
         (total (cl-reduce #'+ sorted))
         (avg (/ total n 1.0))
         (min (car sorted))
         (max (car (last sorted))))
    (list :avg avg :min min :max max :samples sorted)))

(defun bench--format-row (label stats)
  (format "%-20s | avg=%6.1fms min=%6.1fms max=%6.1fms"
          label
          (plist-get stats :avg)
          (plist-get stats :min)
          (plist-get stats :max)))

;; ---- Setup ----
(setq beads-dolt-sql-enabled t)
(setq beads-dolt-sql--available t)
(setq beads-dolt-sql--params nil)
(setq beads-dolt-sql--params-time nil)

;; Pre-warm dolt params cache
(beads-backend-dolt-sql--fetch-dolt-params)

;; Pre-warm persistent mysql client
(when (and beads-dolt-sql--mysql-proc (process-live-p beads-dolt-sql--mysql-proc))
  (delete-process beads-dolt-sql--mysql-proc)
  (setq beads-dolt-sql--mysql-proc nil))

;; ---- Cold cache benchmark ----
(message "\n--- Cold cache (first call per operation) ---\n")

;; Cold: clear all caches
(setq beads-dolt-sql--params nil)
(setq beads-dolt-sql--params-time nil)
(when (and beads-dolt-sql--mysql-proc (process-live-p beads-dolt-sql--mysql-proc))
  (delete-process beads-dolt-sql--mysql-proc)
  (setq beads-dolt-sql--mysql-proc nil))

(let* ((start (float-time))
       (_ (beads-backend-dolt-sql--execute-list nil default-directory))
       (elapsed (* 1000.0 (- (float-time) start))))
  (message "Cold list (SQL Tier 1.5): %.1fms" elapsed))

;; ---- Warm cache benchmarks ----

(message "\n--- Warm cache benchmarks (%d iterations) ---\n" bench-iters)

;; list
(let* ((cli-times (bench--time-it
                   (lambda ()
                     (let ((default-directory (or (beads-client--project-root) default-directory)))
                       (with-temp-buffer
                         (apply #'call-process "bd" nil t nil '("list" "--json"))
                         (goto-char (point-min))
                         (json-read))))))
       (cli-stats (bench--stats cli-times))
       (sql-times (bench--time-it
                   (lambda ()
                     (beads-backend-dolt-sql--execute-list nil default-directory))))
       (sql-stats (bench--stats sql-times))
       (cli-avg (plist-get cli-stats :avg))
       (sql-avg (plist-get sql-stats :avg))
       (speedup (if (> sql-avg 0) (/ cli-avg sql-avg 1.0) 0)))
  (message "[list]")
  (message "%s" (bench--format-row "bd-cli" cli-stats))
  (message "%s" (bench--format-row "dolt-sql" sql-stats))
  (message "Speedup: %.1fx" speedup))

;; show
(let* ((cli-times (bench--time-it
                   (lambda ()
                     (let ((default-directory (or (beads-client--project-root) default-directory)))
                       (with-temp-buffer
                         (apply #'call-process "bd" nil t nil '("show" "bdel-4c4.1" "--json"))
                         (goto-char (point-min))
                         (json-read))))))
       (cli-stats (bench--stats cli-times))
       (sql-times (bench--time-it
                   (lambda ()
                     (beads-backend-dolt-sql--execute-show '((id . "bdel-4c4.1")) default-directory))))
       (sql-stats (bench--stats sql-times))
       (cli-avg (plist-get cli-stats :avg))
       (sql-avg (plist-get sql-stats :avg))
       (speedup (if (> sql-avg 0) (/ cli-avg sql-avg 1.0) 0)))
  (message "\n[show]")
  (message "%s" (bench--format-row "bd-cli" cli-stats))
  (message "%s" (bench--format-row "dolt-sql" sql-stats))
  (message "Speedup: %.1fx" speedup))

;; ready
(let* ((cli-times (bench--time-it
                   (lambda ()
                     (let ((default-directory (or (beads-client--project-root) default-directory)))
                       (with-temp-buffer
                         (apply #'call-process "bd" nil t nil '("ready" "--json"))
                         (goto-char (point-min))
                         (json-read))))))
       (cli-stats (bench--stats cli-times))
       (sql-times (bench--time-it
                   (lambda ()
                     (beads-backend-dolt-sql--execute-ready nil default-directory))))
       (sql-stats (bench--stats sql-times))
       (cli-avg (plist-get cli-stats :avg))
       (sql-avg (plist-get sql-stats :avg))
       (speedup (if (> sql-avg 0) (/ cli-avg sql-avg 1.0) 0)))
  (message "\n[ready]")
  (message "%s" (bench--format-row "bd-cli" cli-stats))
  (message "%s" (bench--format-row "dolt-sql" sql-stats))
  (message "Speedup: %.1fx" speedup))

;; stats
(let* ((cli-times (bench--time-it
                   (lambda ()
                     (let ((default-directory (or (beads-client--project-root) default-directory)))
                       (with-temp-buffer
                         (apply #'call-process "bd" nil t nil '("stats" "--json"))
                         (goto-char (point-min))
                         (json-read))))))
       (cli-stats (bench--stats cli-times))
       (sql-times (bench--time-it
                   (lambda ()
                     (beads-backend-dolt-sql--execute-stats nil default-directory))))
       (sql-stats (bench--stats sql-times))
       (cli-avg (plist-get cli-stats :avg))
       (sql-avg (plist-get sql-stats :avg))
       (speedup (if (> sql-avg 0) (/ cli-avg sql-avg 1.0) 0)))
  (message "\n[stats]")
  (message "%s" (bench--format-row "bd-cli" cli-stats))
  (message "%s" (bench--format-row "dolt-sql" sql-stats))
  (message "Speedup: %.1fx" speedup))

;; count
(let* ((cli-times (bench--time-it
                   (lambda ()
                     (let ((default-directory (or (beads-client--project-root) default-directory)))
                       (with-temp-buffer
                         (apply #'call-process "bd" nil t nil '("list" "--json" "--limit" "1"))
                         (goto-char (point-min))
                         (json-read))))))
       (cli-stats (bench--stats cli-times))
       (sql-times (bench--time-it
                   (lambda ()
                     (beads-backend-dolt-sql--execute-count nil default-directory))))
       (sql-stats (bench--stats sql-times))
       (cli-avg (plist-get cli-stats :avg))
       (sql-avg (plist-get sql-stats :avg))
       (speedup (if (> sql-avg 0) (/ cli-avg sql-avg 1.0) 0)))
  (message "\n[count]")
  (message "%s" (bench--format-row "bd-cli" cli-stats))
  (message "%s" (bench--format-row "dolt-sql" sql-stats))
  (message "Speedup: %.1fx" speedup))

;; stale
(let* ((cli-times (bench--time-it
                   (lambda ()
                     (let ((default-directory (or (beads-client--project-root) default-directory)))
                       (with-temp-buffer
                         (apply #'call-process "bd" nil t nil '("stale" "--json"))
                         (goto-char (point-min))
                         (json-read))))))
       (cli-stats (bench--stats cli-times))
       (sql-times (bench--time-it
                   (lambda ()
                     (beads-backend-dolt-sql--execute-stale '((days . 365)) default-directory))))
       (sql-stats (bench--stats sql-times))
       (cli-avg (plist-get cli-stats :avg))
       (sql-avg (plist-get sql-stats :avg))
       (speedup (if (> sql-avg 0) (/ cli-avg sql-avg 1.0) 0)))
  (message "\n[stale]")
  (message "%s" (bench--format-row "bd-cli" cli-stats))
  (message "%s" (bench--format-row "dolt-sql" sql-stats))
  (message "Speedup: %.1fx" speedup))

;; ---- Tier 1 vs Tier 1.5 profiling ----
(message "\n--- Tier 1 (one-shot mariadb -e) vs Tier 1.5 (persistent mysql client) ---\n")

;; Force Tier 1 by killing persistent client
(when (and beads-dolt-sql--mysql-proc (process-live-p beads-dolt-sql--mysql-proc))
  (delete-process beads-dolt-sql--mysql-proc)
  (setq beads-dolt-sql--mysql-proc nil))

;; Tier 1: one-shot mariadb
(let* ((tier1-times (bench--time-it
                     (lambda ()
                       (let ((dolt (beads-backend-dolt-sql--fetch-dolt-params)))
                         (beads-backend-dolt-sql--one-shot-mariadb
                          beads-dolt-sql--list-sql dolt)))))
       (tier1-stats (bench--stats tier1-times)))

  ;; Tier 1.5: ensure persistent client is up
  (beads-dolt-sql--ensure-mysql-connected)

  (let* ((tier15-times (bench--time-it
                        (lambda ()
                          (beads-dolt-sql--mysql-query beads-dolt-sql--list-sql))))
         (tier15-stats (bench--stats tier15-times))
         (t1-avg (plist-get tier1-stats :avg))
         (t15-avg (plist-get tier15-stats :avg))
         (speedup (if (> t15-avg 0) (/ t1-avg t15-avg 1.0) 0)))
    (message "[list - Tier comparison]")
    (message "%s" (bench--format-row "Tier1-one-shot" tier1-stats))
    (message "%s" (bench--format-row "Tier1.5-persist" tier15-stats))
    (message "Speedup: %.1fx" speedup)))

;; Clean up
(when (and beads-dolt-sql--mysql-proc (process-live-p beads-dolt-sql--mysql-proc))
  (delete-process beads-dolt-sql--mysql-proc))

(message "\nBenchmark complete.")
