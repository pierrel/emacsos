;;; assist-desktop.el --- Assist threads in ordinary Emacs -*- lexical-binding: t -*-

;;; Commentary:
;; Load this file from a checkout or alongside chat.el, assist-web.el,
;; assist-web-git.el and assist-web-git-helper.py.  Configure the existing
;; emacsos-assist-web options in your private init before loading this file,
;; then use C-c a l or M-x emacsos-desktop-assist.  Loading enables the canonical
;; Assist shortcuts through emacsos-desktop-assist-mode.  See README.org for setup.

;;; Code:

(add-to-list 'load-path
             (file-name-directory (or load-file-name buffer-file-name)))
(require 'assist-web)

(define-key emacsos-assist-web-thread-list-mode-map (kbd "C-c a n")
            #'emacsos-assist-web-new-thread)

(defvar emacsos-desktop-assist-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c a l") #'emacsos-assist-web-show-thread-list)
    (define-key map (kbd "C-c a t") #'emacsos-assist-web-open-thread)
    (define-key map (kbd "C-c a n") #'emacsos-assist-web-new-thread)
    (define-key map (kbd "C-c a r") #'emacsos-assist-web-refresh-threads)
    map)
  "Desktop shortcuts for canonical Assist threads.")

(define-minor-mode emacsos-desktop-assist-mode
  "Enable the canonical Assist shortcuts globally without editing user keymaps."
  :global t
  :group 'emacsos-assist-web
  :keymap emacsos-desktop-assist-mode-map)

(emacsos-desktop-assist-mode 1)

;;;###autoload
(defun emacsos-desktop-assist ()
  "Open the Assist thread list and refresh it asynchronously."
  (interactive)
  (emacsos-assist-web-show-thread-list))

(provide 'assist-desktop)
;;; assist-desktop.el ends here
