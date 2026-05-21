;;; test-os.el --- Tests for os.el command strip + utility row -*- lexical-binding: t -*-

;; Covers the pure pieces of the single keyboard + commands combo:
;; `emacos--top-commands' (the strip's command set for the top buffer),
;; `emacos--mode-commands-for' parent-walking, the pure layout helpers
;; (`emacos--command-spec', `emacos--commands-fitting'), the follower's
;; change-detection guard, the chat command set, and `emacos--tap-tab'
;; dispatch.  Hook firing and real window geometry are validated by
;; smoke + a live phone pass, not here.

(require 'ert)
(require 'cl-lib)
(require 'os)

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

;;; emacos--top-commands (the strip's command set)

(ert-deftest test-os-top-commands-minibuffer-is-empty ()
  "An active minibuffer means you're typing a prompt — empty strip."
  (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () 'mb)))
    (should-not (emacos--top-commands))))

(ert-deftest test-os-top-commands-fundamental-falls-back-to-globals ()
  "A mode with no command set shows the global commands (Save/Undo/...),
never an empty strip — so a plain text buffer keeps them one tap away."
  (with-temp-buffer
    (fundamental-mode)
    (let ((buf (current-buffer)))
      (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () nil))
                ((symbol-function 'emacos--target) (lambda () 'w))
                ((symbol-function 'window-buffer) (lambda (_) buf)))
        (should (equal (emacos--top-commands) emacos-global-commands))))))

(ert-deftest test-os-top-commands-org-is-org-set ()
  (with-temp-buffer
    (let ((buf (current-buffer)))
      (setq-local major-mode 'org-mode)
      (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () nil))
                ((symbol-function 'emacos--target) (lambda () 'w))
                ((symbol-function 'window-buffer) (lambda (_) buf)))
        (should (equal (emacos--top-commands)
                       (cdr (assq 'org-mode emacos-mode-commands))))))))

(ert-deftest test-os-top-commands-dired-is-dired-set ()
  (with-temp-buffer
    (let ((buf (current-buffer)))
      (setq-local major-mode 'dired-mode)
      (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () nil))
                ((symbol-function 'emacos--target) (lambda () 'w))
                ((symbol-function 'window-buffer) (lambda (_) buf)))
        (should (equal (emacos--top-commands)
                       (cdr (assq 'dired-mode emacos-mode-commands))))))))

(ert-deftest test-os-top-commands-chat-buffer-idle ()
  "The *chat* buffer (by identity) derives to the chat command set."
  (let ((chat-buf (get-buffer-create emacos--chat-buffer-name)))
    (unwind-protect
        (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () nil))
                  ((symbol-function 'emacos--target) (lambda () 'w))
                  ((symbol-function 'window-buffer) (lambda (_) chat-buf)))
          (let ((emacos--chat-in-flight nil))
            (should (equal (mapcar #'car (emacos--top-commands))
                           '("SEND" "CLEAR"))))
          ;; In flight, the strip's abort path must surface via top-commands.
          (let ((emacos--chat-in-flight t))
            (should (equal (mapcar #'car (emacos--top-commands))
                           '("SEND" "ABORT")))))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer chat-buf)))))

;;; emacos--chat-command-set (dynamic: CLEAR idle / ABORT in flight)

(ert-deftest test-os-chat-command-set-idle ()
  (let ((emacos--chat-in-flight nil))
    (should (equal (mapcar #'car (emacos--chat-command-set))
                   '("SEND" "CLEAR")))))

(ert-deftest test-os-chat-command-set-in-flight-shows-abort ()
  "The abort path must survive mid-stream: in flight, the second button
is ABORT, not CLEAR."
  (let ((emacos--chat-in-flight t))
    (should (equal (mapcar #'car (emacos--chat-command-set))
                   '("SEND" "ABORT")))))

(ert-deftest test-os-chat-send-carries-prominent-height ()
  "SEND (the device's hot path) carries a height so the strip renders it
larger than the uniform command buttons."
  (let ((emacos--chat-in-flight nil))
    (should (equal (emacos--command-spec (car (emacos--chat-command-set)))
                   '("SEND" emacos--chat-send 1.5)))))

;;; emacos--command-spec (normalize both entry shapes)

(ert-deftest test-os-command-spec-cons-shape ()
  (should (equal (emacos--command-spec '("X" . foo)) '("X" foo nil))))

(ert-deftest test-os-command-spec-list-shape-with-height ()
  (should (equal (emacos--command-spec '("Y" bar 1.5)) '("Y" bar 1.5))))

;;; emacos--commands-fitting (one row, order = priority, width-accurate)

(ert-deftest test-os-commands-fitting-keeps-order-preserving-prefix ()
  "Stops at the first button that would overflow; keeps the prefix.
Each button costs (length label) + 3 (\" LABEL \" padding + gap), so
\"AAA\"=6, \"BBB\"=6: width 13 fits two (12), the third (18) overflows."
  (should (equal (emacos--commands-fitting
                  '(("AAA" . a) ("BBB" . b) ("CCC" . c)) 13)
                 '(("AAA" . a) ("BBB" . b)))))

(ert-deftest test-os-commands-fitting-all-fit-when-wide ()
  (should (equal (emacos--commands-fitting
                  '(("AAA" . a) ("BBB" . b)) 100)
                 '(("AAA" . a) ("BBB" . b)))))

(ert-deftest test-os-commands-fitting-width-accounts-for-label-length ()
  "Width counts the displayed label, not a fixed slot: a long first
label can crowd out a short second one."
  (should (equal (emacos--commands-fitting
                  '(("Heading" . h) ("X" . x)) 10)  ; "Heading"=10, fits; "X"=4 overflows
                 '(("Heading" . h)))))

(ert-deftest test-os-commands-fitting-empty-when-nothing-fits ()
  (should-not (emacos--commands-fitting '(("AAA" . a)) 2)))

;;; Follower: re-render only when the command set changed

(ert-deftest test-os-follower-rerenders-on-command-set-change ()
  (let ((rendered nil)
        (emacos--in-render nil)
        (emacos--last-commands '(("OLD" . old))))
    (cl-letf (((symbol-function 'emacos--render-page) (lambda () (setq rendered t)))
              ((symbol-function 'emacos--top-commands) (lambda () '(("NEW" . new)))))
      (emacos--on-window-buffer-change nil)
      (should rendered))))

(ert-deftest test-os-follower-noop-when-command-set-unchanged ()
  (let ((rendered nil)
        (emacos--in-render nil)
        (emacos--last-commands '(("SAME" . same))))
    (cl-letf (((symbol-function 'emacos--render-page) (lambda () (setq rendered t)))
              ((symbol-function 'emacos--top-commands) (lambda () '(("SAME" . same)))))
      (emacos--on-window-buffer-change nil)
      (should-not rendered))))

(ert-deftest test-os-follower-noop-during-render ()
  "Re-entry guard (the brick-insurance): the follower bails when a render
is already in progress, even if the command set differs."
  (let ((rendered nil)
        (emacos--in-render t)
        (emacos--last-commands '(("OLD" . old))))
    (cl-letf (((symbol-function 'emacos--render-page) (lambda () (setq rendered t)))
              ((symbol-function 'emacos--top-commands) (lambda () '(("NEW" . new)))))
      (emacos--on-window-buffer-change nil)
      (should-not rendered))))

;;; Utility row: caps + M-x + Chat are always present

(ert-deftest test-os-utility-row-always-has-caps-mx-chat ()
  (with-temp-buffer
    (emacos--render-utility-row)
    (let ((s (buffer-string)))
      (should (string-match-p "caps" s))
      (should (string-match-p "M-x" s))
      (should (string-match-p "Chat" s)))))

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
