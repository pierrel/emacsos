;;; emacsos-typography.el --- Shared prose presentation -*- lexical-binding: t -*-

;;; Commentary:
;; Inspired by Diego Zamboni's supplied Org beautification example:
;; https://zzamboni.org/post/beautifying-org-mode-in-emacs/
;; The linked article and dot-emacs repository state no explicit code license.
;; This independent implementation uses buffer-local faces and built-in modes;
;; it does not copy the example or download org-bullets, packages, or fonts.

;;; Code:
(require 'face-remap)
(require 'jit-lock)

(defgroup emacsos-typography nil
  "Shared phone and desktop prose presentation."
  :group 'faces)

(defcustom emacsos-prose-font-family "Inter"
  "Preferred installed prose font, or nil to inherit `variable-pitch'.
An explicitly configured variable-pitch family takes precedence.  Missing
fonts and text terminals retain the existing face; no fonts are downloaded."
  :type '(choice (const nil) string)
  :group 'emacsos-typography)

(defcustom emacsos-prose-typography t
  "Whether to enable shared prose styling in Org, Markdown and Assist."
  :type 'boolean
  :group 'emacsos-typography)

(declare-function emacsos--chat-present-markdown-1 "chat" (beg end))
(declare-function emacsos--chat-copy-raw "chat" (beg end delete))
(defvar emacsos--chat-presentation-max-bytes)
(defvar-local emacsos-typography--cookies nil)
(defvar-local emacsos-markdown--styled-end nil)

(defun emacsos-typography--explicit-font-p (face)
  "Return non-nil when FACE customization explicitly selects font attributes."
  (when-let ((spec (or (get face 'customized-face) (get face 'saved-face))))
    (let ((attributes (face-spec-choose spec (selected-frame))))
      (or (plist-member attributes :family)
          (plist-member attributes :font)
          (plist-member attributes :inherit)))))

(defun emacsos-typography-apply ()
  "Apply local prose faces without changing user themes or global faces."
  (when emacsos-prose-typography
    (mapc #'face-remap-remove-relative emacsos-typography--cookies)
    (setq emacsos-typography--cookies nil)
    (let* ((family (face-attribute 'variable-pitch :family nil))
           (preferred
            (and (display-graphic-p) emacsos-prose-font-family
                 (not (emacsos-typography--explicit-font-p 'variable-pitch))
                 (equal family
                        (plist-get
                         (face-spec-choose
                          (get 'variable-pitch 'face-defface-spec)
                          (selected-frame)) :family))
                 (let ((font (find-font
                              (font-spec :family emacsos-prose-font-family))))
                   (and font
                        (equal (format "%s" (font-get font :family))
                               emacsos-prose-font-family))))))
      (when preferred
        (push (face-remap-add-relative
               'variable-pitch :family emacsos-prose-font-family)
              emacsos-typography--cookies)))
    (push (face-remap-add-relative 'default 'variable-pitch)
          emacsos-typography--cookies)
    (visual-line-mode 1)
    (when (derived-mode-p 'org-mode)
      (dolist (face '(org-block org-code org-verbatim org-table
                     org-meta-line org-document-info-keyword
                     org-special-keyword org-property-value))
        (unless (emacsos-typography--explicit-font-p face)
          (push (face-remap-add-relative face 'fixed-pitch)
                emacsos-typography--cookies)))
      (dolist (face '(org-level-1 org-level-2 org-level-3 org-level-4
                     org-level-5 org-level-6 org-level-7 org-level-8))
        (unless (or (get face 'customized-face) (get face 'saved-face))
          (push (face-remap-add-relative face :inherit 'variable-pitch
                                         :weight 'bold :height 1.12)
                emacsos-typography--cookies)))
      (unless (or (get 'org-document-title 'customized-face)
                  (get 'org-document-title 'saved-face))
        (push (face-remap-add-relative 'org-document-title
                                       :inherit 'variable-pitch :height 1.2)
              emacsos-typography--cookies)))
    (when (derived-mode-p 'markdown-mode)
      (dolist (face '(markdown-code-face markdown-inline-code-face
                     markdown-pre-face markdown-table-face))
        (when (and (facep face)
                   (not (emacsos-typography--explicit-font-p face)))
          (push (face-remap-add-relative face 'fixed-pitch)
                emacsos-typography--cookies))))))

(defun emacsos-markdown--fontify (_beg _end)
  "Present a bounded Markdown buffer with complete fence context.
Return the actual jit-lock coverage so display chunks do not repeat the work."
  (save-restriction
    (widen)
    (if (<= (- (position-bytes (point-max))
               (position-bytes (point-min)))
            emacsos--chat-presentation-max-bytes)
        (progn
          (emacsos--chat-present-markdown-1 (point-min) (point-max))
          (setq emacsos-markdown--styled-end (copy-marker (point-max))))
      (when emacsos-markdown--styled-end
        (with-silent-modifications
          (remove-text-properties
           (point-min) emacsos-markdown--styled-end
           '(font-lock-face nil wrap-prefix nil emacsos-conversation-url nil
             keymap nil mouse-face nil display nil emacsos-conversation-object nil)))
        (setq emacsos-markdown--styled-end nil)))
    `(jit-lock-bounds ,(point-min) . ,(point-max))))

(define-derived-mode emacsos-markdown-mode text-mode "Markdown"
  "Edit literal Markdown with the bounded native Assist presentation.
Files above the message presentation limit remain ordinary text.  Existing
Markdown mode associations take precedence over this built-in fallback."
  (require 'chat)
  (setq-local filter-buffer-substring-function #'emacsos--chat-copy-raw)
  (emacsos-typography-apply)
  (when emacsos-prose-typography
    (jit-lock-register #'emacsos-markdown--fontify)))

(add-to-list 'auto-mode-alist
             '("\\.\\(?:md\\|markdown\\)\\'" . emacsos-markdown-mode) t)
(add-hook 'org-mode-hook #'emacsos-typography-apply)
(add-hook 'markdown-mode-hook #'emacsos-typography-apply)
(add-hook 'emacsos-assist-web-mode-hook #'emacsos-typography-apply)
(add-hook 'emacsos-assist-web-thread-list-mode-hook #'emacsos-typography-apply)

(provide 'emacsos-typography)
;;; emacsos-typography.el ends here
