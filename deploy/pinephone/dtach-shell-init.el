;;; dtach-shell-init.el --- PinePhone dtach terminal integration -*- lexical-binding: t; -*-

;; dtach-shell.el is vendored from dtachel commit 4de12de.  This phone-only
;; bootstrap adds native vterm history browsing to the signed OpenRC payload.

(add-to-list 'load-path "/usr/share/emacs/site-lisp")
(require 'dtach-shell)
(require 'touch-screen)

(defvar vterm-copy-mode)
(declare-function vterm-copy-mode "vterm" (&optional arg))
(defvar-local emacsos-pinephone-vterm-live-map nil
  "Terminal keymap restored when native copy mode ends.")

(defun emacsos-pinephone-vterm-history (&optional enable)
  "Browse native vterm history, or return to live output.
ENABLE enters copy mode without toggling it off.  Copy mode pauses PTY
output and may block producers until the user returns to live output."
  (interactive)
  (if (and vterm-copy-mode (not enable))
      (vterm-copy-mode -1)
    (unless vterm-copy-mode
      (setq emacsos-pinephone-vterm-live-map (current-local-map))
      (vterm-copy-mode 1))))

(defun emacsos-pinephone-vterm-restore-map ()
  "Restore this phone terminal's bindings after native copy mode ends."
  (when (and (not vterm-copy-mode) emacsos-pinephone-vterm-live-map)
    (use-local-map emacsos-pinephone-vterm-live-map)
    (setq emacsos-pinephone-vterm-live-map nil)))

(defun emacsos-pinephone-vterm-scroll (event)
  "Scroll touch EVENT, entering native copy mode in phone terminals."
  (interactive "e")
  (with-selected-window (nth 1 event)
    (when (bound-and-true-p emacsos-pinephone-vterm-history-mode)
      (emacsos-pinephone-vterm-history t))
    (touch-screen-scroll event)))

(defun emacsos-pinephone-vterm-history-click (event)
  "Toggle history in the header-line window clicked by EVENT."
  (interactive "e")
  (with-selected-window (posn-window (event-start event))
    (emacsos-pinephone-vterm-history)))

(defconst emacsos-pinephone-vterm-history-header-map
  (let ((map (make-sparse-keymap)))
    (define-key map [header-line mouse-1]
      #'emacsos-pinephone-vterm-history-click)
    map)
  "Tap bindings for the phone terminal's History/Live control.")

(defun emacsos-pinephone-vterm-history-label ()
  "Return the phone terminal control with its current output state."
  (propertize (if vterm-copy-mode " Live | Output paused " " History ")
              'local-map emacsos-pinephone-vterm-history-header-map
              'mouse-face 'mode-line-highlight
              'help-echo (if vterm-copy-mode
                             "Resume terminal output"
                           "Browse history; terminal output pauses")))

(define-minor-mode emacsos-pinephone-vterm-history-mode
  "Enable phone history controls without changing desktop vterm maps."
  :lighter nil
  :keymap (let ((map (make-sparse-keymap)))
            (define-key map (kbd "C-c C-t")
              #'emacsos-pinephone-vterm-history)
            map))

(defun emacsos-pinephone-vterm-setup-history ()
  "Install the phone's history controls in a new vterm buffer."
  (emacsos-pinephone-vterm-history-mode 1)
  (setq-local header-line-format
              '(:eval (emacsos-pinephone-vterm-history-label)))
  (add-hook 'vterm-copy-mode-hook
            #'emacsos-pinephone-vterm-restore-map nil t))

;; Translated touch events name their target window, which need not be selected.
(global-set-key [touchscreen-scroll] #'emacsos-pinephone-vterm-scroll)
(add-hook 'vterm-mode-hook #'emacsos-pinephone-vterm-setup-history)

(provide 'dtach-shell-init)
;;; dtach-shell-init.el ends here
