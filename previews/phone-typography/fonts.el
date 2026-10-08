;;; fonts.el --- Load the staged phone font study once -*- lexical-binding: t; -*-
;; Root stages this file as /tmp/fonts.el. Load it in the phone's graphical Emacs.

(require 'xdg)

(let* ((stage "/tmp/emacsos-font-study-890bb9")
       (source (expand-file-name "phone-fonts" stage))
       (destination
        (expand-file-name "fonts/emacsos-phone-type-study" (xdg-data-home)))
       (fonts (directory-files
               source t
               "\\`Phone\\(?:Type\\|Code\\)[0-9][0-9]-\\(?:Regular\\|SemiBold\\)\\.ttf\\'"))
       (licenses (directory-files source t "\\`[a-z0-9]+-OFL\\.txt\\'")))
  (unless (display-graphic-p)
    (user-error "Load /tmp/fonts.el in the phone's graphical Emacs"))
  (unless (and (= (length fonts) 19) (= (length licenses) 12))
    (error "Incomplete phone font study: expected 19 fonts and 12 licenses"))
  (unless (and (executable-find "timeout") (executable-find "fc-cache"))
    (error "Phone font study needs timeout and fc-cache"))
  (make-directory destination t)
  (dolist (file (append fonts licenses))
    (copy-file file (expand-file-name (file-name-nondirectory file) destination) t))
  (with-temp-buffer
    (let ((status (call-process "timeout" nil t nil "15" "fc-cache" "-f" destination)))
      (unless (eq status 0)
        (error "Font-cache refresh failed (%s): %s" status (buffer-string)))))
  (clear-font-cache)
  (load (expand-file-name "phone-specimen.el" stage) nil t)
  (let ((display-buffer-overriding-action '(display-buffer-same-window)))
    (emacsos-type-study-show)))

;;; fonts.el ends here
