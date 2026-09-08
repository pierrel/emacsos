;;; dtach-shell-init.el --- PinePhone dtach terminal integration -*- lexical-binding: t; -*-

;; Vendored from dtachel commit 4de12de so the signed OpenRC payload owns
;; the exact terminal integration that the bootstrap loads.

(add-to-list 'load-path "/usr/share/emacs/site-lisp")
(require 'dtach-shell)

(provide 'dtach-shell-init)
;;; dtach-shell-init.el ends here
