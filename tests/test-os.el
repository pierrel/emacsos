;;; test-os.el --- Tests for the os.el keyboard surface -*- lexical-binding: t -*-

;; Covers the pure pieces of the keyboard: `emacos--top-commands' (the
;; command set for the top buffer), `emacos--mode-commands-for'
;; parent-walking, the pure width helper (`emacos--unit-width'), the
;; follower's change-detection guard, the chat command set,
;; `emacos--tap-tab' / `emacos--tap-quit' dispatch, and the utility row.
;; Hook firing and real window geometry are validated by a live phone
;; pass, not here.

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

;;; emacos--top-commands (the command set for the top buffer)

(ert-deftest test-os-top-commands-minibuffer-is-empty ()
  "An active minibuffer means you're typing a prompt — empty command set."
  (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () 'mb)))
    (should-not (emacos--top-commands))))

(ert-deftest test-os-top-commands-fundamental-falls-back-to-globals ()
  "A mode with no command set shows the global commands (Save/Undo/...),
never an empty list — so a plain text buffer keeps them one tap away."
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
                           '("SEND" "New chat"))))
          ;; In flight, the abort path must surface via top-commands.
          (let ((emacos--chat-in-flight t))
            (should (equal (mapcar #'car (emacos--top-commands))
                           '("SEND" "ABORT")))))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer chat-buf)))))

(ert-deftest test-os-top-commands-capped-at-max ()
  "The command list shows at most `emacos--max-commands' (the renderer
caps it); a mode with more entries than that is truncated by the
renderer, but `emacos--top-commands' returns the full set (the follower
compares against the full set)."
  (let ((emacos-mode-commands
         (list (cons 'fundamental-mode
                     (cl-loop for i from 1 to 15
                              collect (cons (format "C%d" i) #'ignore))))))
    (with-temp-buffer
      (fundamental-mode)
      (let ((buf (current-buffer)))
        (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () nil))
                  ((symbol-function 'emacos--target) (lambda () 'w))
                  ((symbol-function 'window-buffer) (lambda (_) buf)))
          (should (= (length (emacos--top-commands)) 15))
          (should (= (length (seq-take (emacos--top-commands)
                                       emacos--max-commands))
                     10)))))))

;;; emacos--chat-command-set (dynamic: New chat idle / ABORT in flight)

(ert-deftest test-os-chat-command-set-idle ()
  (let ((emacos--chat-in-flight nil))
    (should (equal (mapcar #'car (emacos--chat-command-set))
                   '("SEND" "New chat")))))

(ert-deftest test-os-chat-command-set-in-flight-shows-abort ()
  "The abort path must survive mid-stream: in flight, the second button
is ABORT, not New chat."
  (let ((emacos--chat-in-flight t))
    (should (equal (mapcar #'car (emacos--chat-command-set))
                   '("SEND" "ABORT")))))

;;; emacos--unit-width (pure per-unit width math)

(ert-deftest test-os-unit-width-full-width-single-button ()
  "1 unit, 0 gaps → floor(win-w / scale).  At scale 1.75, win-w 35 → 20."
  (should (= (emacos--unit-width 35 1.5 1 0) 20)))

(ert-deftest test-os-unit-width-accounts-for-gaps ()
  "N units with G gaps subtract G*gap before dividing by N*scale:
floor((36 - 3*1.5) / (4*1.75)) = floor(31.5/7.0) = 4."
  (should (= (emacos--unit-width 36 1.5 4 3) 4)))

(ert-deftest test-os-unit-width-min-1 ()
  "A pathologically narrow window can't drive a width <= 0."
  (should (= (emacos--unit-width 1 1.5 4 3) 1)))

(ert-deftest test-os-action-row-widths ()
  "Row 4: DEL 1/3 (1 unit) + SPC 2/3 (2 units).  Row 5: CAPS/TAB 1 unit,
RET 2 units (double-wide).  All positive; the wide ones beat the narrow."
  (let* ((win-w 36) (gap 1.5)
         (third (emacos--unit-width win-w gap 3 1))    ; DEL=1u, SPC=2u
         (unit  (emacos--unit-width win-w gap 4 2)))   ; CAPS/TAB=1u, RET=2u
    (should (> third 0))
    (should (> unit 0))
    (should (> (* 2 third) third))   ; SPC (2/3) wider than DEL (1/3)
    (should (> (* 2 unit) unit))))   ; RET (2u) wider than CAPS/TAB (1u)

(ert-deftest test-os-action-row-renders-del-spc-caps-tab-ret ()
  (with-temp-buffer
    (emacos--render-action-row)
    (let ((s (buffer-string)))
      (should (string-match-p "DEL" s))
      (should (string-match-p "SPC" s))
      (should (string-match-p "caps" s))
      (should (string-match-p "TAB" s))
      (should (string-match-p "RET" s)))))

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

;;; Utility row: QUIT + M-x + Chat (CAPS lives on the action row)

(ert-deftest test-os-utility-row-has-quit-mx-chat ()
  (with-temp-buffer
    (emacos--render-utility-row)
    (let ((s (buffer-string)))
      (should (string-match-p "QUIT" s))
      (should (string-match-p "M-x" s))
      (should (string-match-p "Chat" s))
      ;; CAPS moved to the action row.
      (should-not (string-match-p "caps\\|CAPS" s)))))

;;; emacos--tap-quit (smart escape)

(ert-deftest test-os-tap-quit-aborts-active-minibuffer ()
  "With a minibuffer active, QUIT aborts it and does NOT touch windows."
  (let ((aborted nil) (quit-win nil) (del-others nil))
    (cl-letf (((symbol-function 'emacos--commit) (lambda () nil))
              ((symbol-function 'active-minibuffer-window) (lambda () 'mb))
              ((symbol-function 'abort-recursive-edit)
               (lambda () (setq aborted t)))
              ((symbol-function 'quit-window) (lambda (&rest _) (setq quit-win t)))
              ((symbol-function 'delete-other-windows)
               (lambda (&rest _) (setq del-others t))))
      (emacos--tap-quit)
      (should aborted)
      (should-not quit-win)
      (should-not del-others))))

(ert-deftest test-os-tap-quit-quits-special-mode-and-clears-windows ()
  "No minibuffer + a special-mode (help-like) top buffer: quit-window
the popup AND delete-other-windows (keyboard survives via its window
parameter on a real frame)."
  (let ((quit-win nil) (del-others nil))
    (with-temp-buffer
      (special-mode)
      (let ((buf (current-buffer)))
        (cl-letf (((symbol-function 'emacos--commit) (lambda () nil))
                  ((symbol-function 'active-minibuffer-window) (lambda () nil))
                  ((symbol-function 'emacos--target) (lambda () (selected-window)))
                  ((symbol-function 'window-buffer) (lambda (&rest _) buf))
                  ((symbol-function 'emacos--render-page) (lambda () nil))
                  ((symbol-function 'emacos--refocus) (lambda () nil))
                  ((symbol-function 'quit-window) (lambda (&rest _) (setq quit-win t)))
                  ((symbol-function 'delete-other-windows)
                   (lambda (&rest _) (setq del-others t))))
          (emacos--tap-quit)
          (should quit-win)
          (should del-others))))))

(ert-deftest test-os-tap-quit-completion-list-is-quit ()
  "*Completions* is completion-list-mode (parent nil in Emacs 30), so
the predicate must catch it explicitly — quit-window must fire."
  (let ((quit-win nil))
    (with-temp-buffer
      (setq-local major-mode 'completion-list-mode)
      (let ((buf (current-buffer)))
        (cl-letf (((symbol-function 'emacos--commit) (lambda () nil))
                  ((symbol-function 'active-minibuffer-window) (lambda () nil))
                  ((symbol-function 'emacos--target) (lambda () (selected-window)))
                  ((symbol-function 'window-buffer) (lambda (&rest _) buf))
                  ((symbol-function 'emacos--render-page) (lambda () nil))
                  ((symbol-function 'emacos--refocus) (lambda () nil))
                  ((symbol-function 'quit-window) (lambda (&rest _) (setq quit-win t)))
                  ((symbol-function 'delete-other-windows) (lambda (&rest _) nil)))
          (emacos--tap-quit)
          (should quit-win))))))

(ert-deftest test-os-tap-quit-ordinary-buffer-no-quit-window ()
  "An ordinary (non-special) top buffer: don't quit-window it, but still
collapse popup windows (harmless no-op when there are none)."
  (let ((quit-win nil) (del-others nil))
    (with-temp-buffer
      (fundamental-mode)
      (let ((buf (current-buffer)))
        (cl-letf (((symbol-function 'emacos--commit) (lambda () nil))
                  ((symbol-function 'active-minibuffer-window) (lambda () nil))
                  ((symbol-function 'emacos--target) (lambda () (selected-window)))
                  ((symbol-function 'window-buffer) (lambda (&rest _) buf))
                  ((symbol-function 'emacos--render-page) (lambda () nil))
                  ((symbol-function 'emacos--refocus) (lambda () nil))
                  ((symbol-function 'quit-window) (lambda (&rest _) (setq quit-win t)))
                  ((symbol-function 'delete-other-windows)
                   (lambda (&rest _) (setq del-others t))))
          (emacos--tap-quit)
          (should-not quit-win)
          (should del-others))))))

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
