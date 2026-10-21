;;; preview.el --- Offline Assist stream layout -*- lexical-binding: t -*-
;; Run in isolated Emacs: emacs -Q -L . -l previews/conversation-stream/preview.el
;; Resize the frame to check native wrapping and the window-relative human inset.
(require 'assist-web)
(require 'emacsos-typography)
(setq inhibit-startup-screen t inhibit-startup-echo-area-message user-login-name)
(defvar emacsos-stream-preview--fixture (make-temp-file "stream-preview-files-" t))
(copy-file (expand-file-name "../conversation-rendering/sample.png"
                             (file-name-directory (or load-file-name buffer-file-name)))
           (expand-file-name "example.png" emacsos-stream-preview--fixture) t)
(advice-add 'emacsos-assist-web-git-local-directory :around
            (lambda (original &rest args)
              (if (equal (buffer-name) "*Conversation stream preview*")
                  emacsos-stream-preview--fixture
                (apply original args))))
(set-face-attribute 'default nil :family "DejaVu Sans Mono" :height 120 :foreground "#202020" :background "white")
(set-frame-parameter nil 'menu-bar-lines 0)
(set-frame-parameter nil 'tool-bar-lines 0)
(set-frame-parameter nil 'vertical-scroll-bars nil)
(set-fringe-mode 4)
(progn
  (switch-to-buffer (get-buffer-create "*Conversation stream preview*"))
  (emacsos-assist-web-mode)
  (setq-local emacsos-assist-web-cache-directory (make-temp-file "stream-preview-json-" t))
  (setq-local header-line-format nil mode-line-format nil)
  (emacsos-assist-web--render
   '((thread . ((id . "stream-preview") (description . "Conversation") (status . "ready") (workspace . ((repo_label . "Demo")))))
     (messages . (((id . "bot-1") (role . "assistant") (state . "final")
                   (text . "This assistant message takes the full available width. It wraps naturally with the window, keeping the source text and your conversation intact."))
                  ((id . "human-1") (role . "user") (state . "final")
                   (text . "This human message is visually inset from the left and slightly grayer. The words wrap naturally within the remaining width, without inserting spaces or hard returns.\n\n- Lists keep their continuation alignment when a longer item wraps onto another screen line.\n> Quotes retain their own indentation too.\n\n```render\ntype: file\npath: /workspace/example.png\n```\n```render\ntype: file\npath: /workspace/missing.pdf\n```\n| Item | Result |\n|------|--------|\n| Width | Full |"))
                  ((id . "bot-2") (role . "assistant") (state . "final")
                   (text . "The next assistant reply uses the full width again. Images and tables retain their native views.\n\n| Item | Result |\n|------|--------|\n| Wrapping | Natural |\n| Source | Literal |"))))))
  (setq-local header-line-format nil mode-line-format nil)
  (goto-char (point-max))
  (insert "Typing is full width. C-a, undo, history and C-RET retain their existing behavior.")
  (goto-char (point-min)))
