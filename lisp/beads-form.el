;;; beads-form.el --- Form-based metadata editor for Beads -*- lexical-binding: t -*-

;; Copyright (C) 2025 Christian Tietze

;; Author: Christian Tietze
;; Keywords: tools, ui, forms

;; This program is free software; you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; VUI-based form editor for editing issue metadata at once.

;;; Code:

(require 'vui)
(require 'beads-client)
(require 'beads-core)

(declare-function vui-mount "vui")
(declare-function vui-component "vui")
(declare-function beads-vui-form-view "beads-vui")
(declare-function beads-org-list-refresh "beads-list")

(defgroup beads-form nil
  "Form-based editing for Beads issues."
  :group 'beads)

(defun beads-form-open (issue)
  "Open VUI form editor for ISSUE."
  (let* ((id (alist-get 'id issue))
         (buffer-name (format "*Beads Form: %s*" id))
         (buffer (get-buffer-create buffer-name)))
    (beads-form--render-vui buffer issue)
    (pop-to-buffer buffer)))

(defvar-local beads-form--vui-save-action nil
  "Save action for vui form, set by component via vui-use-effect.")

(defvar-local beads-form--vui-cancel-action nil
  "Cancel action for vui form, set by component via vui-use-effect.")

(defun beads-form--field-at-point-p ()
  "Return non-nil if point is in an editable VUI field."
  (let ((field (get-char-property (point) 'field)))
    (if (eq field 'boundary)
        (get-char-property (point) 'real-field)
      field)))

(defun beads-form--self-insert-or-undefined ()
  "Insert character if in a VUI field, otherwise signal undefined.
This undoes special-mode's suppression of `self-insert-command' for form
buffers, allowing typing in editable fields while preserving special-mode
behavior elsewhere."
  (interactive)
  (if (beads-form--field-at-point-p)
      (call-interactively #'self-insert-command)
    (undefined)))

(defvar beads-form-vui-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c C-c") #'beads-form-vui-save)
    (define-key map (kbd "C-c C-k") #'beads-form-vui-cancel)
    (define-key map [remap self-insert-command] #'beads-form--self-insert-or-undefined)
    map)
  "Keymap for `beads-form-vui-mode'.")

(declare-function vui-mode "vui")

(defun beads-form--patch-field-keymaps ()
  "Add form keybindings to all VUI field overlays in current buffer.
This ensures C-c C-c and C-c C-k work inside editable fields.
Uses the actual keybindings from the mode map for consistency with user remaps."
  (let ((save-keys (or (where-is-internal #'beads-form-vui-save beads-form-vui-mode-map)
                       (list (kbd "C-c C-c"))))
        (cancel-keys (or (where-is-internal #'beads-form-vui-cancel beads-form-vui-mode-map)
                         (list (kbd "C-c C-k")))))
    (dolist (ov (overlays-in (point-min) (point-max)))
      (when (overlay-get ov 'field)
        (let ((km (overlay-get ov 'local-map)))
          (when km
            (dolist (key save-keys)
              (define-key km key #'beads-form-vui-save))
            (dolist (key cancel-keys)
              (define-key km key #'beads-form-vui-cancel))))))))

(define-derived-mode beads-form-vui-mode vui-mode "Beads-Form"
  "Major mode for vui-based Beads form editor.
Derives from `vui-mode' and adds form-specific keybindings.

\\{beads-form-vui-mode-map}"
  (add-hook 'pre-command-hook #'beads-form--patch-field-keymaps nil t)
  (beads-show-hint))

(declare-function evil-set-initial-state "evil-core")

;; Configure evil-mode IF user has it loaded (does not enable evil)
(with-eval-after-load 'evil
  (evil-set-initial-state 'beads-form-vui-mode 'emacs))

(defun beads-form-vui-save ()
  "Save the vui form."
  (interactive)
  (if beads-form--vui-save-action
      (funcall beads-form--vui-save-action)
    (user-error "No save action available")))

(defun beads-form-vui-cancel ()
  "Cancel the vui form."
  (interactive)
  (if beads-form--vui-cancel-action
      (funcall beads-form--vui-cancel-action)
    (beads-form--close)))

(defun beads-form--render-vui (buffer issue)
  "Render form for ISSUE into BUFFER using vui.el components."
  (require 'beads-vui)
  (let ((issue-id (alist-get 'id issue)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'beads-form-vui-mode)
        (beads-form-vui-mode)))
    (save-window-excursion
      (vui-mount (vui-component 'beads-vui-form-view
                                :issue issue
                                :on-save (lambda (changes)
                                           (if (null changes)
                                               (progn
                                                 (message "No changes to save")
                                                 (beads-form--close))
                                             (condition-case err
                                                 (progn
                                                   (apply #'beads-client-update issue-id changes)
                                                   (message "Updated %s" issue-id)
                                                   (beads-form--close)
                                                   (beads-form--refresh-views issue-id))
                                               (beads-client-error
                                                (message "Failed to update: %s"
                                                         (error-message-string err))))))
                                :on-cancel (lambda ()
                                             (beads-form--close)
                                             (message "Cancelled")))
                 (buffer-name buffer))
      (run-with-timer 0 nil
                      (lambda ()
                        (when (buffer-live-p buffer)
                          (with-current-buffer buffer
                            (beads-form--patch-field-keymaps))))))))

(defun beads-form--close ()
  "Close the form buffer."
  (quit-window t))

(defun beads-form--refresh-views (issue-id)
  "Refresh detail and list views after form edit for ISSUE-ID."
  (dolist (buf (buffer-list))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (cond
         ((eq major-mode 'beads-org-list-mode)
          (when (fboundp 'beads-org-list-refresh)
            (beads-org-list-refresh)))
         ((and (derived-mode-p 'beads-detail-vui-mode)
               (boundp 'beads-detail--current-issue-id)
               (equal beads-detail--current-issue-id issue-id))
           (when (fboundp 'beads-detail-refresh)
             (beads-detail-refresh))))))))

(provide 'beads-form)
;;; beads-form.el ends here
