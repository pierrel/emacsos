;;; dtach-shell-init.el --- PinePhone dtach terminal integration -*- lexical-binding: t; -*-

;; Vendored from dtachel commit 4de12de so the signed OpenRC payload owns
;; the exact terminal integration that the bootstrap loads.

(add-to-list 'load-path "/usr/share/emacs/site-lisp")
(require 'dtach-shell)

(setq emacos-global-commands
      (cons '("Dtach" . dtach-shell)
            (assoc-delete-all "Dtach" emacos-global-commands)))

(advice-add 'emacos--chat-command-set :filter-return
            (lambda (commands)
              (cons '("Dtach" . dtach-shell)
                    (assoc-delete-all "Dtach" commands))))

(provide 'dtach-shell-init)
;;; dtach-shell-init.el ends here
