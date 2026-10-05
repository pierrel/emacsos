;;; assist-desktop.el --- Assist threads in ordinary Emacs -*- lexical-binding: t -*-

;;; Commentary:
;; Load this file from a checkout or alongside chat.el, assist-web.el,
;; assist-web-git.el and assist-web-git-helper.py.  Configure the existing
;; emacsos-assist-web options in your private init, then run
;; M-x emacsos-desktop-assist.  See README.org for setup and commands.

;;; Code:

(add-to-list 'load-path
             (file-name-directory (or load-file-name buffer-file-name)))
(require 'assist-web)

;;;###autoload
(defun emacsos-desktop-assist ()
  "Open the Assist thread list and refresh it asynchronously."
  (interactive)
  (emacsos-assist-web-show-thread-list))

(provide 'assist-desktop)
;;; assist-desktop.el ends here
