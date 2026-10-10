;;; preview-typography.el --- Offline representative buffers -*- lexical-binding: t -*-
;; From the checkout: emacs -Q -L . -l tests/preview-typography.el
;; Then M-x emacsos-typography-preview.  No request or draft persistence occurs.
(require 'assist-web)
(require 'org)

(defun emacsos-typography-preview ()
  "Open representative Org, Markdown and Assist buffers without network access.
Switch with C-x b.  A phone reviewer can load this fixture from a temporary
file with the installed payload on load-path; it does not change user config."
  (interactive)
  (let ((inhibit-modification-hooks t))
    (with-current-buffer (get-buffer-create "*Typography Org*")
      (erase-buffer)
      (insert "#+title: Shared typography\n* Readable prose\nA short paragraph with *bold*, /italic/, =code= and [[https://example.org][a link]].\n- A useful list item\n- Another item\n** Code and tables\n| Name | Count |\n|------+-------|\n| Item |    12 |\n#+begin_src emacs-lisp\n(message \"Fixed pitch\")\n#+end_src\n")
      (org-mode) (font-lock-ensure) (set-buffer-modified-p nil))
    (with-current-buffer (get-buffer-create "*Typography Markdown*")
      (erase-buffer)
      (emacsos-markdown-mode)
      (insert "# Readable prose\nA short paragraph with **bold**, *italic*, `code` and [a link](https://example.org).\n- A useful list item\n- Another item\n## Code and tables\n| Name | Count |\n| Item |    12 |\n```elisp\n(message \"Fixed pitch\")\n```\n")
      (jit-lock-fontify-now) (set-buffer-modified-p nil))
    (with-current-buffer (get-buffer-create "*Typography Assist*")
      (let ((inhibit-read-only t))
        (erase-buffer)
        (emacsos-assist-web-mode)
        (insert "Offline typography preview\n\n")
        (dolist (message '((user . "Show headings, code and a small table.")
                           (assistant . "# Readable prose\nA short **answer** with `code` and [a link](https://example.org).\n- A useful list item\n| Name | Count |\n| Item |    12 |\n```elisp\n(message \"Fixed pitch\")\n```")))
          (let ((start (point)))
            (insert (if (eq (car message) 'user) "you> " "bot> "))
            (let ((body (point)))
              (insert (cdr message))
              (emacsos--chat-present-message start body (point) (car message)))
            (insert "\n\n")))
        (add-text-properties (point-min) (point) '(read-only t rear-nonsticky t))
        (emacsos-assist-web--write-prompt)
        (insert "An editable draft. Navigation does not send it.")
        (set-buffer-modified-p nil))))
  (switch-to-buffer "*Typography Assist*"))

(provide 'preview-typography)
