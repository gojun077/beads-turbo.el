;;; beads-about-test.el --- Tests for beads-about -*- lexical-binding: t; -*-

;;; Commentary:
;; Unit tests for the Beads Turbo about buffer.

;;; Code:

(require 'ert)
(require 'beads)

(ert-deftest beads-about-test-command-defined ()
  "Test that `beads-about' is an interactive command."
  (should (commandp 'beads-about)))

(ert-deftest beads-about-test-ascii-art-renders-literally ()
  "Test that the about buffer ASCII art preserves literal backslashes."
  (should
   (string=
    beads-about--ascii-art
    "            ____________/  __                     __
           ____________/  / /_  ___  ____ _____ _/ /____
          ____________/  / __ \\/ _ \\/ __ `/ __ `/ / ___/
         ____________/  / /_/ /  __/ /_/ / /_/ / (__  )
        ____________/  /_.___/\\___/\\__,_/\\__,_/_/____/
       ____________/  / / / / / / / / / / / / / / / /
      ____________/ ________  ______  ____  ____            __
     ____________/ /_  __/ / / / __ \\/ __ )/ __ \\     ___  / /
    ____________/   / / / / / / /_/ / __  / / / /    / _ \\/ /
   ____________/   / / / /_/ / _, _/ /_/ / /_/ / _  /  __/ /
  ____________/   /_/  \\____/_/ |_/_____/\\____/ (_) \\___/_/
                  / / / / / / / / / / / / / / / / / / /
                (O) (O) (O) (O) (O) (O) (O) (O) (O) (O)")))

(ert-deftest beads-about-test-renders-buffer ()
  "Test that `beads-about' renders identity and diagnostic information."
  (cl-letf (((symbol-function 'beads-about--git-output)
             (lambda (&rest args)
               (pcase args
                 ('("describe" "--tags" "--always" "--dirty") "v0.1.0-test")
                 ('("rev-parse" "--short" "HEAD") "abc1234")
                 ('("log" "-1" "--format=%cs") "2026-05-26")
                 (_ nil))))
            ((symbol-function 'beads-about--process-output)
             (lambda (&rest _) "bd 1.0.3"))
            ((symbol-function 'beads-about--source-file)
             (lambda () "/tmp/beads-turbo.el/lisp/beads.el"))
            ((symbol-function 'beads-client--find-database)
             (lambda (&rest _) "/tmp/project/.beads/dolt"))
            ((symbol-function 'pop-to-buffer)
             (lambda (buffer &rest _)
               (set-buffer buffer))))
    (unwind-protect
        (progn
          (beads-about)
          (with-current-buffer beads-about--buffer-name
            (let ((contents (buffer-string)))
              (should (string-match-p "beads-turbo.el" contents))
              (should (string-match-p "___________/" contents))
              (should (string-match-p "Package version:" contents))
              (should (string-match-p "Git tag:[[:space:]]+v0.1.0-test" contents))
              (should (string-match-p "Commit:[[:space:]]+abc1234" contents))
              (should (string-match-p "bd version:[[:space:]]+bd 1.0.3" contents))
              (should (eq major-mode 'special-mode)))))
      (when (get-buffer beads-about--buffer-name)
        (kill-buffer beads-about--buffer-name)))))

(provide 'beads-about-test)
;;; beads-about-test.el ends here
