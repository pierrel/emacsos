;;; preview.el --- Offline native rendering specimen -*- lexical-binding: t -*-
;; Run in an isolated Emacs: emacs -Q -L . -l previews/conversation-rendering/preview.el
(require 'chat)
(require 'assist-web)
(require 'emacsos-typography)
(let* ((fixture (make-temp-file "emacsos-render-preview-" t))
       (notes (expand-file-name "notes.md" fixture)))
  (write-region "# Local preview\nThis is a disposable local file.\n" nil notes nil 'silent)
  (copy-file (expand-file-name "sample.png"
                               (file-name-directory (or load-file-name buffer-file-name)))
             (expand-file-name "example.png" fixture))
  ;; This isolated specimen substitutes only the documented read-only resolver.
  (advice-add 'emacsos-assist-web-git-local-directory :around
              (lambda (original &rest args)
                (if (equal (buffer-name) "*Native render preview*") fixture
                  (apply original args))))
  (switch-to-buffer (get-buffer-create "*Native render preview*"))
  (emacsos--chat-enable-presentation)
  (emacsos-typography-apply)
  (insert "bot> # Native rendering\nWrapped conversation prose stays readable on narrow windows. Open the table, scroll horizontally, then tap Back or use C-c b.\n\n")
  (insert "```render\ntype: file\npath: /workspace/example.png\n```\n[Local notes](/user/notes.md:2)\n\n")
  (insert "| Item | kcal | P | C | F |\n|------|------|---|---|---|\n| 1 slice bread + Kite Hill cream cheese + nutritional yeast | 236 | 10g | 27g | 9g |\n| ½ chocolate croissant | 110 | 2.5g | 14g | 6g |\n| ½ small coffee cake | 125 | 2g | 17.5g | 5.5g |\n| **Total** | **470** | **15g** | **59g** | **20g** |\n\n")
  (insert "```render\ntype: file\npath: /tmp/server-only.png\n```\n```render\ntype: map\npin: 1,2 Map stays source\n```\n")
  (emacsos--chat-present-message (point-min) 6 (point-max) 'assistant)
  (insert "\n> Unsaved preview draft")
  (goto-char (point-min)))
