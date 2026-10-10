;;; test-interaction-typography.el --- Shared interaction checks -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(require 'assist-desktop)
(require 'org)
(emacsos-desktop-assist-mode -1)

(defconst interaction-test--snapshot
  '((thread . ((id . "thread-1") (description . "Typography")
               (status . "ready") (workspace . ((repo_label . "Demo")))))
    (messages . (((id . "m1") (role . "user") (text . "First") (state . "final"))
                 ((id . "m2") (role . "assistant")
                  (text . "# Heading\n| A | B |\n| 1 | 2 |\n`code`")
                  (state . "final"))))
    (has_older_messages . nil) (next_before . nil)))

(defmacro interaction-test--thread (&rest body)
  (declare (indent 0))
  `(let ((emacsos-desktop-assist-mode t)
          (emacsos-assist-web-cache-directory (make-temp-file "interaction-" t)))
     (unwind-protect
         (with-temp-buffer
           (emacsos-assist-web-mode)
           (emacsos-assist-web--render interaction-test--snapshot)
           ,@body)
       (delete-directory emacsos-assist-web-cache-directory t))))

(ert-deftest interaction-keys-and-context-refresh ()
  (let ((emacsos-desktop-assist-mode t))
   (with-temp-buffer
    (should (eq (key-binding (kbd "C-c a g"))
                #'emacsos-assist-web-refresh-context))
    (should (eq (key-binding (kbd "C-c a d"))
                #'emacsos-assist-web-git-diff))
    (should-not (eq (key-binding (kbd "C-c b"))
                    #'emacsos-assist-web-previous-message))
    (let (called)
      (cl-letf (((symbol-function 'emacsos-assist-web-refresh-threads)
                 (lambda () (interactive) (push 'catalog called))))
        (call-interactively (key-binding (kbd "C-c a g")))
        (should (equal called '(catalog)))))))
  (interaction-test--thread
    (let (called)
      (goto-char (point-max)) (insert "unsent")
      (cl-letf (((symbol-function 'emacsos-assist-web-refresh-thread)
                 (lambda () (interactive)
                   (push 'thread called)
                   (emacsos-assist-web--render interaction-test--snapshot)))
                ((symbol-function 'emacsos-assist-web-git-refresh)
                 (lambda () (interactive) (push 'git called)))
                ((symbol-function 'emacsos-assist-web-send)
                 (lambda () (error "Navigation/refresh submitted input"))))
        (call-interactively (key-binding (kbd "C-c a g")))
        (should (equal called '(git thread)))
        (should (equal (emacsos-assist-web--input) "unsent"))))))

(ert-deftest interaction-message-navigation-stops-at-compose ()
  (interaction-test--thread
    (goto-char (point-max)) (insert "draft")
    (let ((draft (emacsos-assist-web--input))
          (input (emacsos-assist-web--prompt-start)))
      (call-interactively (key-binding (kbd "C-c b")))
      (should (< (point) input))
      (should (looking-at "bot> "))
      (call-interactively (key-binding (kbd "C-c b")))
      (should (looking-at "you> "))
      (call-interactively (key-binding (kbd "C-c f")))
      (should (looking-at "bot> "))
      (call-interactively (key-binding (kbd "C-c f")))
      (should (= (point) input))
      (call-interactively (key-binding (kbd "C-c f")))
      (should (= (point) input))
      (should (equal (emacsos-assist-web--input) draft))
      (should-not (get-text-property input 'read-only)))))

(ert-deftest interaction-live-message-boundary-and-marker-survive-presentation ()
  (interaction-test--thread
    (let ((inhibit-read-only t)
          (input emacsos-assist-web--input-marker)
          (draft "untouched"))
      (goto-char (point-max)) (insert draft)
      (goto-char emacsos-assist-web--prompt-marker)
      (let ((prefix (point)))
        (insert "bot> ")
        (let* ((body (point))
               (end (progn (insert "```\na | b\n```\n") (point)))
               (markers (emacsos-conversation-begin-assistant body end)))
          (emacsos--chat-present-message prefix body end 'assistant)
          (emacsos-conversation-replace-marked
           (car markers) (cdr markers) "| C | D |\n")
          (emacsos--chat-present-message prefix body (cdr markers) 'assistant)
          (should (get-text-property prefix 'emacsos-conversation-message-start))
          (should (eq input emacsos-assist-web--input-marker))
          (goto-char (point-max))
          (emacsos-assist-web-previous-message)
          (should (= (point) prefix))
          (should (equal (emacsos-assist-web--input) draft)))))))

(ert-deftest interaction-find-file-and-diff-use-workspace-boundary ()
  (interaction-test--thread
    (let ((directory (make-temp-file "interaction-workspace-" t)) seen)
      (unwind-protect
          (cl-letf (((symbol-function 'emacsos-assist-web-git-local-directory)
                     (lambda () (file-name-as-directory directory)))
                    ((symbol-function 'emacsos-assist-web-git-diff)
                     (lambda () (interactive) (setq seen default-directory))))
            (run-hooks 'pre-command-hook)
            (should (equal default-directory (file-name-as-directory directory)))
            (should (eq (key-binding (kbd "C-x C-f")) #'find-file))
            (call-interactively (key-binding (kbd "C-c a d")))
            (should (equal seen default-directory)))
        (delete-directory directory t)))))

(ert-deftest typography-org-faces-preserve-source-and-global-customization ()
  (let ((old-family (face-attribute 'variable-pitch :family nil))
        (old-table (face-attribute 'org-table :inherit nil)))
    (unwind-protect
        (progn
          (set-face-attribute 'variable-pitch nil :family "Custom Prose")
          (with-temp-buffer
            (insert "* Heading\n- List\nProse =code= [[https://example.org][link]]\n| A | B |\n#+begin_src emacs-lisp\n(+ 1 2)\n#+end_src\n")
            (let ((raw (buffer-string)))
              (org-mode) (font-lock-ensure)
              (should (equal raw (buffer-substring-no-properties (point-min) (point-max))))
              (should (assq 'org-table face-remapping-alist))
              (should (assq 'org-block face-remapping-alist))
              (should (assq 'default face-remapping-alist))
              (should-not (assq 'variable-pitch face-remapping-alist))
              (emacsos-typography-apply)
              (should (= (length emacsos-typography--cookies)
                         (length (delete-dups (copy-sequence emacsos-typography--cookies)))))))
          (should (equal (face-attribute 'variable-pitch :family nil) "Custom Prose"))
          (should (equal (face-attribute 'org-table :inherit nil) old-table)))
      (set-face-attribute 'variable-pitch nil :family old-family))))

(ert-deftest typography-markdown-code-table-edit-and-raw-copy ()
  (with-temp-buffer
    (emacsos-markdown-mode)
    (insert "# Heading\nText **bold** [link](https://example.org)\n```\n# code\n```\n| A | B |\n")
    (let ((raw (buffer-string)))
      (jit-lock-fontify-now)
      (should (equal raw (buffer-substring-no-properties (point-min) (point-max))))
      (goto-char (point-min)) (search-forward "# code")
      (should (memq 'emacsos-chat-code-face (get-text-property (1- (point)) 'font-lock-face)))
      (search-forward "| A")
      (should (memq 'emacsos-chat-code-face (get-text-property (1- (point)) 'font-lock-face)))
      (goto-char (point-min)) (search-forward "```\n")
      (delete-region (- (point) 4) (point))
      (jit-lock-fontify-now)
      (search-forward "# code")
      (should (memq 'emacsos-chat-heading-face (get-text-property (1- (point)) 'font-lock-face))))))

(ert-deftest typography-markdown-cap-clears-old-presentation ()
  (with-temp-buffer
    (emacsos-markdown-mode)
    (insert "# Title\n") (jit-lock-fontify-now)
    (should (get-text-property 3 'font-lock-face))
    (goto-char (point-max))
    (insert (make-string emacsos--chat-presentation-max-bytes ?x))
    (jit-lock-fontify-now)
    (should-not (get-text-property 3 'font-lock-face))))

(ert-deftest typography-markdown-association-retains-existing-mode ()
  (let ((auto-mode-alist (cons '("\\.md\\'" . text-mode) auto-mode-alist)))
    (with-temp-buffer
      (setq buffer-file-name "/tmp/typography.md")
      (set-auto-mode)
      (should (eq major-mode 'text-mode)))))


(ert-deftest interaction-real-queued-messages-have-separate-boundaries ()
  (interaction-test--thread
    (goto-char (point-max)) (insert "retain draft")
    (let ((entry (emacsos-assist-web--entry "Queued question" 'queued "key-q")))
      (emacsos-assist-web--entry-append-pending entry)
      (goto-char (point-max))
      (emacsos-assist-web-previous-message)
      (should (looking-at "bot> "))
      (let ((prefix (point)))
        (emacsos-assist-web-previous-message)
        (should (looking-at "you> Queued question"))
        (emacsos-assist-web-next-message)
        (should (= (point) prefix))
        (emacsos-assist-web-next-message)
        (should (= (point) (emacsos-assist-web--prompt-start))))
      (should (equal (emacsos-assist-web--input) "retain draft")))))

(ert-deftest interaction-unresolved-thread-does-not-inherit-another-checkout ()
  (let ((other (make-temp-file "interaction-other-thread-" t)))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory (file-name-as-directory other))
          (emacsos-assist-web-mode)
          (should (equal default-directory (expand-file-name "~/")))
          (should-not (equal default-directory (file-name-as-directory other))))
      (delete-directory other t))))

(ert-deftest typography-respects-explicit-org-heading-customization ()
  (let ((saved (get 'org-level-1 'saved-face))
        (customized (get 'org-level-1 'customized-face))
        (spec (face-user-default-spec 'org-level-1)))
    (unwind-protect
        (progn
          (custom-set-faces '(org-level-1 ((t (:weight normal :height 1.6)))))
          (with-temp-buffer
            (org-mode)
            (should-not (assq 'org-level-1 face-remapping-alist))))
      (put 'org-level-1 'saved-face saved)
      (put 'org-level-1 'customized-face customized)
      (face-spec-set 'org-level-1 spec))))

(ert-deftest typography-unmatched-brackets-and-normal-links ()
  (with-temp-buffer
    (emacsos-markdown-mode)
    (insert (make-string (* 64 1024) ?\[))
    (insert "\n[ordinary](https://example.org)\n")
    (jit-lock-fontify-now)
    (goto-char (point-max)) (search-backward "ordinary")
    (should (equal (get-text-property (point) 'emacsos-conversation-url)
                   "https://example.org"))))

(ert-deftest interaction-phone-prefix-has-same-refresh-and-diff ()
  (with-temp-buffer
    (should
     (= 0 (call-process
           (expand-file-name invocation-name invocation-directory)
           nil (current-buffer) nil "-Q" "--batch" "-L" default-directory
           "--eval"
           "(progn (require 'os) (emacsos-command-mode 1) (unless (and (eq (key-binding (kbd \"C-c a g\")) 'emacsos-assist-web-refresh-context) (eq (key-binding (kbd \"C-c a d\")) 'emacsos-assist-web-git-diff)) (kill-emacs 1)))")))))


(ert-deftest typography-color-only-table-customization-keeps-fixed-pitch ()
  (let ((saved (get 'org-table 'saved-face))
        (customized (get 'org-table 'customized-face))
        (spec (face-user-default-spec 'org-table)))
    (unwind-protect
        (progn
          (custom-set-faces '(org-table ((t (:foreground "red")))))
          (with-temp-buffer
            (org-mode)
            (should (assq 'org-table face-remapping-alist))
            (should (equal (face-attribute 'org-table :foreground nil) "red"))))
      (put 'org-table 'saved-face saved)
      (put 'org-table 'customized-face customized)
      (face-spec-set 'org-table spec))))

(provide 'test-interaction-typography)
