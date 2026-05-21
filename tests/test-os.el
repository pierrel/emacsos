;;; test-os.el --- Tests for os.el page derivation + state -*- lexical-binding: t -*-

;; Covers the pure / state-machine pieces of the dynamic-surface +
;; TAB work: `emacos--derive-page', `emacos--mode-commands-for'
;; parent-walking, the auto/pinned state transitions, and
;; `emacos--tap-tab' dispatch.  Hook firing, real window geometry,
;; and the page-bar visuals are validated by smoke + a live phone
;; pass, not here.

(require 'ert)
(require 'cl-lib)
(require 'os)

;;; Helpers

(defmacro test-os--with-page-state (&rest body)
  "Run BODY with page state reset, restoring it afterward."
  (declare (indent 0))
  `(let ((emacos--current-page 'keyboard)
         (emacos--page-mode 'auto))
     ,@body))

(defun test-os--fake-target-buffer (buf)
  "Return a thunk usable to stub `emacos--target' so the editing
window's buffer is BUF.  We stub at the `window-buffer' boundary by
faking `emacos--target' to return a symbol and `window-buffer' to
map it to BUF."
  (lambda () 'fake-window))

;;; emacos--mode-commands-for (parent walk)

(ert-deftest test-os-mode-commands-direct ()
  (should (equal (emacos--mode-commands-for 'org-mode)
                 (cdr (assq 'org-mode emacos-mode-commands)))))

(ert-deftest test-os-mode-commands-parent-walk ()
  "A mode derived from emacs-lisp-mode resolves to the elisp set even
though only the parent is in the alist."
  (define-derived-mode test-os--child-elisp emacs-lisp-mode "ChildEl")
  (unwind-protect
      (should (equal (emacos--mode-commands-for 'test-os--child-elisp)
                     (cdr (assq 'emacs-lisp-mode emacos-mode-commands))))
    (put 'test-os--child-elisp 'derived-mode-parent nil)))

(ert-deftest test-os-mode-commands-unknown-is-nil ()
  (should-not (emacos--mode-commands-for 'fundamental-mode)))

;;; emacos--derive-page

(ert-deftest test-os-derive-minibuffer-is-keyboard ()
  "Active minibuffer always derives to keyboard (you're typing a prompt)."
  (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () 'mb)))
    (should (eq (emacos--derive-page) 'keyboard))))

(ert-deftest test-os-derive-fundamental-is-keyboard ()
  "A mode with no command set falls back to the keyboard, never a dead
\" No commands\" surface."
  (with-temp-buffer
    (fundamental-mode)
    (let ((buf (current-buffer)))
      (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () nil))
                ((symbol-function 'emacos--target) (lambda () 'w))
                ((symbol-function 'window-buffer) (lambda (_) buf)))
        (should (eq (emacos--derive-page) 'keyboard))))))

(ert-deftest test-os-derive-org-is-mode ()
  (with-temp-buffer
    (let ((buf (current-buffer)))
      (setq-local major-mode 'org-mode)
      (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () nil))
                ((symbol-function 'emacos--target) (lambda () 'w))
                ((symbol-function 'window-buffer) (lambda (_) buf)))
        (should (eq (emacos--derive-page) 'mode))))))

(ert-deftest test-os-derive-dired-is-mode ()
  "dired-mode was seeded into the alist, so it derives to a command surface."
  (with-temp-buffer
    (let ((buf (current-buffer)))
      (setq-local major-mode 'dired-mode)
      (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () nil))
                ((symbol-function 'emacos--target) (lambda () 'w))
                ((symbol-function 'window-buffer) (lambda (_) buf)))
        (should (eq (emacos--derive-page) 'mode))))))

(ert-deftest test-os-derive-chat-is-chat ()
  "The *chat* buffer (by identity) derives to the chat page."
  (let ((chat-buf (get-buffer-create emacos--chat-buffer-name)))
    (unwind-protect
        (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () nil))
                  ((symbol-function 'emacos--target) (lambda () 'w))
                  ((symbol-function 'window-buffer) (lambda (_) chat-buf)))
          (should (eq (emacos--derive-page) 'chat)))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer chat-buf)))))

;;; State transitions: auto / pinned

(ert-deftest test-os-switch-page-pins ()
  (test-os--with-page-state
    (cl-letf (((symbol-function 'emacos--render-page) (lambda () nil))
              ((symbol-function 'emacos--refocus) (lambda () nil))
              ((symbol-function 'emacos--chat-show-top-buffer) (lambda () nil)))
      (emacos--switch-page 'global)
      (should (eq emacos--page-mode 'pinned))
      (should (eq emacos--current-page 'global)))))

(ert-deftest test-os-switch-to-auto-rederives ()
  (test-os--with-page-state
    (setq emacos--page-mode 'pinned
          emacos--current-page 'global)
    (cl-letf (((symbol-function 'emacos--render-page) (lambda () nil))
              ((symbol-function 'emacos--refocus) (lambda () nil))
              ((symbol-function 'emacos--derive-page) (lambda () 'mode)))
      (emacos--switch-to-auto)
      (should (eq emacos--page-mode 'auto))
      (should (eq emacos--current-page 'mode)))))

(ert-deftest test-os-follower-noop-when-pinned ()
  "The window-buffer-change follower must NOT touch state when pinned."
  (test-os--with-page-state
    (setq emacos--page-mode 'pinned
          emacos--current-page 'global)
    (let ((rendered nil))
      (cl-letf (((symbol-function 'emacos--render-page)
                 (lambda () (setq rendered t)))
                ((symbol-function 'emacos--derive-page) (lambda () 'mode)))
        (emacos--on-window-buffer-change nil)
        (should (eq emacos--current-page 'global))
        (should-not rendered)))))

(ert-deftest test-os-follower-rederives-when-auto ()
  (test-os--with-page-state
    (setq emacos--current-page 'keyboard)
    (let ((rendered nil))
      (cl-letf (((symbol-function 'emacos--render-page)
                 (lambda () (setq rendered t)))
                ((symbol-function 'emacos--derive-page) (lambda () 'mode)))
        (emacos--on-window-buffer-change nil)
        (should (eq emacos--current-page 'mode))
        (should rendered)))))

(ert-deftest test-os-follower-noop-when-derived-equals-shown ()
  "No re-render when the derived page already matches what's shown."
  (test-os--with-page-state
    (setq emacos--current-page 'mode)
    (let ((rendered nil))
      (cl-letf (((symbol-function 'emacos--render-page)
                 (lambda () (setq rendered t)))
                ((symbol-function 'emacos--derive-page) (lambda () 'mode)))
        (emacos--on-window-buffer-change nil)
        (should-not rendered)))))

(ert-deftest test-os-follower-noop-during-render ()
  "Re-entry guard: follower bails when a render is already in progress."
  (test-os--with-page-state
    (setq emacos--current-page 'keyboard)
    (let ((emacos--in-render t)
          (rendered nil))
      (cl-letf (((symbol-function 'emacos--render-page)
                 (lambda () (setq rendered t)))
                ((symbol-function 'emacos--derive-page) (lambda () 'mode)))
        (emacos--on-window-buffer-change nil)
        (should-not rendered)
        (should (eq emacos--current-page 'keyboard))))))

;;; emacos--tap-tab dispatch

(ert-deftest test-os-tap-tab-indents-in-buffer ()
  ;; Stubs must be commands (`call-interactively' rejects non-commands),
  ;; hence the (interactive) form in each.
  (let ((called nil))
    (cl-letf (((symbol-function 'emacos--commit) (lambda () nil))
              ((symbol-function 'emacos--target) (lambda () (selected-window)))
              ((symbol-function 'emacos--refocus) (lambda () nil))
              ((symbol-function 'active-minibuffer-window) (lambda () nil))
              ((symbol-function 'indent-for-tab-command)
               (lambda (&rest _) (interactive) (setq called 'indent)))
              ((symbol-function 'minibuffer-complete)
               (lambda (&rest _) (interactive) (setq called 'complete))))
      (emacos--tap-tab)
      (should (eq called 'indent)))))

(ert-deftest test-os-tap-tab-completes-in-minibuffer ()
  (let ((called nil))
    (cl-letf (((symbol-function 'emacos--commit) (lambda () nil))
              ((symbol-function 'emacos--target) (lambda () (selected-window)))
              ((symbol-function 'emacos--refocus) (lambda () nil))
              ((symbol-function 'active-minibuffer-window) (lambda () 'mb))
              ((symbol-function 'indent-for-tab-command)
               (lambda (&rest _) (interactive) (setq called 'indent)))
              ((symbol-function 'minibuffer-complete)
               (lambda (&rest _) (interactive) (setq called 'complete))))
      (emacos--tap-tab)
      (should (eq called 'complete)))))

(provide 'test-os)
;;; test-os.el ends here
