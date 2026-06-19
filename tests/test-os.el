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

(ert-deftest test-os-mode-commands-prog-mode-walk ()
  "A code buffer with no own entry walks up to the prog-mode set."
  (define-derived-mode test-os--child-prog prog-mode "ChildProg")
  (unwind-protect
      (should (equal (emacos--mode-commands-for 'test-os--child-prog)
                     (cdr (assq 'prog-mode emacos-mode-commands))))
    (put 'test-os--child-prog 'derived-mode-parent nil)))

(ert-deftest test-os-mode-commands-text-mode-walk ()
  "A text buffer with no own entry walks up to the text-mode set."
  (define-derived-mode test-os--child-text text-mode "ChildText")
  (unwind-protect
      (should (equal (emacos--mode-commands-for 'test-os--child-text)
                     (cdr (assq 'text-mode emacos-mode-commands))))
    (put 'test-os--child-text 'derived-mode-parent nil)))

(ert-deftest test-os-mode-commands-magit-is-data-only ()
  "magit-status-mode resolves to its command set WITHOUT magit loaded —
the alist is data; entries only ever fire when the user is in that mode
(so the package is already loaded).  Regression guard: don't add a
`require' to the alist definition."
  (let ((set (emacos--mode-commands-for 'magit-status-mode)))
    (should set)
    (should (equal (caar set) "Stage"))
    (should (<= (length set) emacos--max-commands))))

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
                           '("New chat"))))
          ;; In flight, the abort path must surface via top-commands.
          (let ((emacos--chat-in-flight t))
            (should (equal (mapcar #'car (emacos--top-commands))
                           '("ABORT")))))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer chat-buf)))))

(ert-deftest test-os-top-commands-assist-reads-buffer-local-confirm-pending ()
  "`emacos-assist--forget-confirm-pending' is buffer-local to each
.assist buffer.  `emacos--top-commands' must call
`emacos-assist--command-set' INSIDE that buffer so the buffer-local
value is read — otherwise the keyboard's render-time `current-buffer'
\(the *keyboard* buffer) yields the global nil, the command-set
returns \"Forget\" instead of \"Confirm forget?\", and the two-tap
relabel never shows.  Caught live 2026-05-30."
  (require 'emacos-assist)
  (with-temp-buffer
    (emacos-assist-mode)
    (setq emacos-assist--forget-confirm-pending t)
    (let ((assist-buf (current-buffer))
          (keyboard-buf (get-buffer-create "*keyboard*")))
      (unwind-protect
          (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () nil))
                    ((symbol-function 'emacos--target) (lambda () 'w))
                    ((symbol-function 'window-buffer) (lambda (_) assist-buf)))
            ;; Simulate the render-time call site: `current-buffer' is the
            ;; keyboard buffer (where `--render-keyboard' inserts), NOT the
            ;; .assist file.  The fix is `with-current-buffer assist-buf'
            ;; around `(emacos-assist--command-set)' inside top-commands.
            (with-current-buffer keyboard-buf
              (let ((emacos--chat-in-flight nil))
                (should (assoc "Confirm forget?" (emacos--top-commands))))))
        (kill-buffer keyboard-buf)))))

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
                   '("New chat")))))

(ert-deftest test-os-chat-command-set-in-flight-shows-abort ()
  "The abort path must survive mid-stream: in flight, the second button
is ABORT, not New chat."
  (let ((emacos--chat-in-flight t))
    (should (equal (mapcar #'car (emacos--chat-command-set))
                   '("ABORT")))))

;;; emacos--unit-width (pure per-unit width math)

;; These pin the MATH, so they bind `emacos--btn-label-scale' to a fixed
;; value rather than reading the production default — tuning the default
;; (the keyboard label font) must not break the width-math assertions.
(ert-deftest test-os-unit-width-full-width-single-button ()
  "1 unit, 0 gaps → floor(win-w / scale).  At scale 1.75, win-w 35 → 20."
  (let ((emacos--btn-label-scale 1.75))
    (should (= (emacos--unit-width 35 1.5 1 0) 20))))

(ert-deftest test-os-unit-width-accounts-for-gaps ()
  "N units with G gaps subtract G*gap before dividing by N*scale:
floor((36 - 3*1.5) / (4*1.75)) = floor(31.5/7.0) = 4."
  (let ((emacos--btn-label-scale 1.75))
    (should (= (emacos--unit-width 36 1.5 4 3) 4))))

(ert-deftest test-os-unit-width-min-1 ()
  "A pathologically narrow window can't drive a width <= 0."
  (let ((emacos--btn-label-scale 1.75))
    (should (= (emacos--unit-width 1 1.5 4 3) 1))))

(ert-deftest test-os-label-scale-fits-longest-t9-group ()
  "Regression: the production `emacos--btn-label-scale' must leave enough
per-group cells that the longest T9 group renders in full — decoupling the
font from button height is what lets it be small enough to (the \"ert…\"
truncation bug).  3 groups, 2 gaps; the render `substring's each label to
the budget.  Pinned at win-w 20 (the phone's keyboard width); re-derives
the longest group from `emacos-t9-layout' so it tracks layout edits."
  (let* ((longest (apply #'max (mapcar #'length
                                       (apply #'append emacos-t9-layout))))
         (budget (emacos--unit-width 20 emacos--btn-gap 3 2)))
    (should (>= budget longest))))

(ert-deftest test-os-btn-applies-vertical-box-padding ()
  "A button's tap-target height comes from `emacos--btn-vpad' via the face
box `:line-width' (HWIDTH = top/bottom), decoupled from the label font —
so a small label still yields a big button.  `emacos--btn-hpad' is the
VWIDTH (left/right); both land in the (VWIDTH . HWIDTH) cons."
  (with-temp-buffer
    (emacos--btn "x" #'ignore)
    (let* ((face (get-text-property (point-min) 'face))
           (line-width (plist-get (plist-get face :box) :line-width)))
      (should (equal line-width (cons emacos--btn-hpad emacos--btn-vpad))))))

(ert-deftest test-os-action-row-widths ()
  "Row 4: DEL 1/3 (1 unit) + SPC 2/3 (2 units).
Row 5: MOD 2 + mode 1 + TAB 1 + RET 2 (6 units / 3 gaps total).  MOD and
RET are both `(* 2 unit)' so the state-toggle and the most-tapped key get
equal fingertip-friendly width on a 320x240 screen.  All positive; the
wide ones beat the narrow."
  (let* ((win-w 36) (gap 1.5)
         (third (emacos--unit-width win-w gap 3 1))    ; DEL=1u, SPC=2u
         (unit  (emacos--unit-width win-w gap 6 3)))   ; mode/TAB=1u, MOD/RET=2u
    (should (> third 0))
    (should (> unit 0))
    (should (> (* 2 third) third))   ; SPC (2/3) wider than DEL (1/3)
    (should (> (* 2 unit) unit))))   ; MOD/RET (2u) wider than mode/TAB (1u)

(ert-deftest test-os-action-row-renders-del-spc-mode-tab-ret ()
  (with-temp-buffer
    (let ((emacos--kbd-mode 'lower))    ; bind, don't rely on the global default
      (emacos--render-action-row)
      (let ((s (buffer-string)))
        (should (string-match-p "DEL" s))
        (should (string-match-p "SPC" s))
        (should (string-match-p "abc" s))   ; the mode button in `lower'
        (should (string-match-p "TAB" s))
        (should (string-match-p "RET" s))))))

;;; Double-tap-space → ". " gesture

(ert-deftest test-os-double-space-fires-after-word ()
  "Rapid second SPC after a word: trailing space, alnum before it, within
the threshold → convert."
  (with-temp-buffer
    (insert "word ")
    (let ((emacos--last-space-time (- 100.0 0.1)))
      (should (emacos--double-space-p 100.0)))))

(ert-deftest test-os-double-space-not-when-slow ()
  "Past the threshold the two taps are just two ordinary spaces."
  (with-temp-buffer
    (insert "word ")
    (let ((emacos--last-space-time
           (- 100.0 (* 2 emacos--double-space-threshold))))
      (should-not (emacos--double-space-p 100.0)))))

(ert-deftest test-os-double-space-not-after-punctuation ()
  "Char before the space isn't alphanumeric (already \". \") → no fire, so
the gesture can't double-period."
  (with-temp-buffer
    (insert "word. ")
    (let ((emacos--last-space-time (- 100.0 0.1)))
      (should-not (emacos--double-space-p 100.0)))))

(ert-deftest test-os-double-space-not-without-prior-space ()
  "No prior SPC tap recorded → never fires (a lone first space)."
  (with-temp-buffer
    (insert "word ")
    (let ((emacos--last-space-time nil))
      (should-not (emacos--double-space-p 100.0)))))

(ert-deftest test-os-double-space-not-mid-word ()
  "Point not preceded by a space → no fire (you're inside a word)."
  (with-temp-buffer
    (insert "word")
    (let ((emacos--last-space-time (- 100.0 0.1)))
      (should-not (emacos--double-space-p 100.0)))))

(ert-deftest test-os-tap-space-double-writes-period-space ()
  "Integration: a rapid second SPC rewrites the trailing space to \". \"
and consumes the gesture (`emacos--last-space-time' back to nil)."
  (let ((buf (get-buffer-create " *dst-test*")))
    (unwind-protect
        (cl-letf (((symbol-function 'emacos--commit) #'ignore)
                  ((symbol-function 'emacos--refocus) #'ignore)
                  ((symbol-function 'emacos--target) (lambda () (selected-window))))
          (save-window-excursion
            (set-window-buffer (selected-window) buf)
            (with-current-buffer buf
              (erase-buffer) (insert "word ") (goto-char (point-max)))
            (setq emacos--last-space-time (- (float-time) 0.05))
            (emacos--tap-space)
            (should (equal (with-current-buffer buf (buffer-string)) "word. "))
            (should-not emacos--last-space-time)))
      (let ((kill-buffer-query-functions nil)) (kill-buffer buf)))))

(ert-deftest test-os-tap-space-single-inserts-space ()
  "A first SPC (no recent prior) inserts a plain space and records the time
so a follow-up tap can complete the gesture."
  (let ((buf (get-buffer-create " *dst-test2*")))
    (unwind-protect
        (cl-letf (((symbol-function 'emacos--commit) #'ignore)
                  ((symbol-function 'emacos--refocus) #'ignore)
                  ((symbol-function 'emacos--target) (lambda () (selected-window))))
          (save-window-excursion
            (set-window-buffer (selected-window) buf)
            (with-current-buffer buf
              (erase-buffer) (insert "word") (goto-char (point-max)))
            (setq emacos--last-space-time nil)
            (emacos--tap-space)
            (should (equal (with-current-buffer buf (buffer-string)) "word "))
            (should emacos--last-space-time)))
      (let ((kill-buffer-query-functions nil)) (kill-buffer buf)))))

;;; Two-tap New-chat confirm: disarm-on-other-tap (emacos--maybe-cancel-confirm)

(ert-deftest test-os-maybe-cancel-confirm-disarms-on-other-command ()
  "Tapping a DIFFERENT command-list entry (run-command + other cmd) while
armed cancels the confirm and re-renders."
  (let ((emacos--chat-confirm-pending t) (rendered nil))
    (cl-letf (((symbol-function 'emacos--render-page) (lambda () (setq rendered t))))
      (emacos--maybe-cancel-confirm #'emacos--run-command #'save-buffer))
    (should-not emacos--chat-confirm-pending)
    (should rendered)))

(ert-deftest test-os-maybe-cancel-confirm-disarms-on-keyboard-tap ()
  "Tapping any keyboard key (a direct action, not run-command) while armed
cancels the confirm."
  (let ((emacos--chat-confirm-pending t) (rendered nil))
    (cl-letf (((symbol-function 'emacos--render-page) (lambda () (setq rendered t))))
      (emacos--maybe-cancel-confirm #'emacos--tap-key "abc"))
    (should-not emacos--chat-confirm-pending)))

(ert-deftest test-os-maybe-cancel-confirm-keeps-armed-on-newchat-tap ()
  "Re-tapping the New-chat command itself (run-command + emacos--chat-new-chat)
must NOT disarm — that tap is the confirming second tap."
  (let ((emacos--chat-confirm-pending t) (rendered nil))
    (cl-letf (((symbol-function 'emacos--render-page) (lambda () (setq rendered t))))
      (emacos--maybe-cancel-confirm #'emacos--run-command #'emacos--chat-new-chat))
    (should emacos--chat-confirm-pending)
    (should-not rendered)))

(ert-deftest test-os-maybe-cancel-confirm-noop-when-unarmed ()
  "Nothing armed → no-op, no spurious re-render (the common path on every
tap)."
  (let ((emacos--chat-confirm-pending nil) (rendered nil))
    (cl-letf (((symbol-function 'emacos--render-page) (lambda () (setq rendered t))))
      (emacos--maybe-cancel-confirm #'emacos--tap-key "abc"))
    (should-not rendered)))

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

;;; Utility row: QUIT + M-x + Chat (the mode button lives on the action row)

(ert-deftest test-os-utility-row-has-quit-mx-chat ()
  (with-temp-buffer
    (let ((emacos--kbd-mode 'lower))
      (emacos--render-utility-row)
      (let ((s (buffer-string)))
        (should (string-match-p "QUIT" s))
        (should (string-match-p "M-x" s))
        (should (string-match-p "Chat" s))
        ;; the mode button lives on the action row, not here
        (should-not (string-match-p "abc\\|ABC" s))))))

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

;;; Modifier keys (Ctrl / Meta / Ctrl-Meta) — see
;;; docs/2026-05-27-modifier-keys.org.  Pure helpers tested directly;
;;; tap dispatch + commit/abandon tested with real keymaps in
;;; with-temp-buffer scopes and minimal cl-letf stubs.

(ert-deftest test-os-modifier-cycle-none-C-M-CM-none ()
  "Pure cycle, no state side effects."
  (should (eq (emacos--modifier-next nil) 'C))
  (should (eq (emacos--modifier-next 'C) 'M))
  (should (eq (emacos--modifier-next 'M) 'C-M))
  (should (eq (emacos--modifier-next 'C-M) nil)))

(ert-deftest test-os-modifier-prefix-strings ()
  (should (equal (emacos--modifier-prefix nil) ""))
  (should (equal (emacos--modifier-prefix 'C) "C-"))
  (should (equal (emacos--modifier-prefix 'M) "M-"))
  (should (equal (emacos--modifier-prefix 'C-M) "C-M-")))

;;; Filter — empty / partial / all-bound (Decision B)
;;
;; `key-binding' walks the FULL active keymap stack including the
;; global map, where (in a vanilla Emacs) `C-q' = `quoted-insert',
;; `C-y' = `yank', etc.  Tests that just `(use-local-map ...)' or set
;; `overriding-local-map' would still see those — and the filter
;; would return most of the alphabet, not the specific subset under
;; test.  Stub `key-binding' to consult ONLY the test's keymap.

(defun test-os--with-map (map fn)
  "Run FN with `key-binding' stubbed to look up keys ONLY in MAP.
MAP is a sparse keymap.  Sidesteps the global map's near-saturated
C-/M- bindings so a test of \"only C-q is bound\" is actually true."
  (cl-letf (((symbol-function 'key-binding)
             (lambda (kseq &optional _accept-default &rest _)
               (let ((b (lookup-key map kseq)))
                 ;; lookup-key returns a NUMBER for partial sequences;
                 ;; treat that as unbound (we only probe single keys).
                 (if (numberp b) nil b)))))
    (funcall fn)))

(ert-deftest test-os-bound-letters-in-group ()
  "letter-bound-p is the leaf; bound-letters-in-group filters one group.
Covers the empty / partial / all-bound cases in one shot."
  (with-temp-buffer
    (let ((map (make-sparse-keymap)))
      (define-key map (kbd "C-q") #'ignore)
      (define-key map (kbd "C-y") #'ignore)
      (test-os--with-map map
        (lambda ()
          (let ((buf (current-buffer)))
            ;; partial: only q,y bound in "qwerty"
            (should (equal (emacos--bound-letters-in-group "qwerty" 'C buf) "qy"))
            ;; empty: nothing bound under M
            (should (equal (emacos--bound-letters-in-group "qwerty" 'M buf) ""))
            ;; single-letter result preserved
            (should (equal (emacos--bound-letters-in-group "qw" 'C buf) "q"))))))))

(ert-deftest test-os-letter-bound-p-rejects-non-command ()
  "Prefix keys (function-value is a keymap) must NOT be commandp."
  (with-temp-buffer
    (let ((map (make-sparse-keymap)))
      (define-key map (kbd "C-z") (make-sparse-keymap))   ; prefix
      (test-os--with-map map
        (lambda ()
          (should-not (emacos--letter-bound-p ?z 'C (current-buffer))))))))

(ert-deftest test-os-bound-groups-preserves-shape ()
  "bound-groups returns the same row/col shape as emacos-t9-layout."
  (with-temp-buffer
    (let ((map (make-sparse-keymap)))
      (define-key map (kbd "C-q") #'ignore)
      (test-os--with-map map
        (lambda ()
          (let ((bg (emacos--bound-groups 'C (current-buffer))))
            (should (= (length bg) (length emacos-t9-layout)))
            (cl-loop for filt-row in bg
                     for orig-row in emacos-t9-layout
                     do (should (= (length filt-row) (length orig-row))))
            ;; q lives in the first group of the first row; only q bound.
            (should (equal (caar bg) "q"))))))))

;;; Tap dispatch under MOD
;;
;; These tests shadow the global keymap via `overriding-local-map' so
;; the filter returns ONLY the letters the test explicitly binds — not
;; whatever the developer's emacs has globally under C- (e.g. C-q is
;; globally `quoted-insert', C-w is `kill-region').  Without the
;; shadow the filter's bound-subset includes most of the alphabet
;; under C-, and the test for "single-letter fast-path" can't fire.

(defmacro test-os--with-tap-env (bindings &rest body)
  "Run BODY with a fresh keymap holding BINDINGS as THE keymap for
`key-binding', plus a consistent view of the test's window/buffer.

Stubs:
- `key-binding' → consults only the test map (no global noise).
- `emacos--target' → returns the selected window.
- `window-buffer' → returns the temp buffer (so D3 validation passes;
  in batch mode the selected window doesn't display the temp buffer).
- `emacos--refocus', `emacos--render-page', `run-with-timer' → no-ops.

BINDINGS is a list of (KEY CMD) pairs; `kbd' is applied to KEY."
  (declare (indent 1))
  `(let ((map (make-sparse-keymap)))
     ,@(mapcar (lambda (b) `(define-key map (kbd ,(car b)) ,(cadr b)))
               bindings)
     (let ((win (selected-window))
           (buf (current-buffer)))
       (cl-letf (((symbol-function 'key-binding)
                  (lambda (kseq &optional _accept-default &rest _)
                    (let ((b (lookup-key map kseq)))
                      (if (numberp b) nil b))))
                 ((symbol-function 'window-buffer) (lambda (&optional _) buf))
                 ((symbol-function 'emacos--target) (lambda () win))
                 ((symbol-function 'emacos--refocus) (lambda () nil))
                 ((symbol-function 'emacos--render-page) (lambda () nil))
                 ((symbol-function 'run-with-timer) (lambda (&rest _) nil)))
         ,@body))))

(ert-deftest test-os-tap-modified-key-single-bound-fires-immediately ()
  "Single-letter fast-path: only one letter bound under MOD → fire on
tap, no arm, no timer.  Honors the user's literal \"click is C-q\"."
  (let ((fired nil)
        (emacos--modifier 'C)
        (emacos--armed-tap nil))
    (with-temp-buffer
      (test-os--with-tap-env (("C-q" (lambda () (interactive) (setq fired t))))
        (emacos--tap-modified-key "qw")
        (should fired)
        (should-not emacos--armed-tap)))))

(ert-deftest test-os-tap-modified-key-arms-then-commits ()
  "Multi-letter subset: first tap arms (no fire), re-tap cycles,
explicit commit fires the cycled letter."
  (let ((fired-cmd nil)
        (emacos--modifier 'C)
        (emacos--armed-tap nil)
        (emacos--armed-tap-timer nil))
    (with-temp-buffer
      (test-os--with-tap-env
          (("C-q" (lambda () (interactive) (setq fired-cmd 'q)))
           ("C-w" (lambda () (interactive) (setq fired-cmd 'w))))
        ;; First tap: arms at q.
        (emacos--tap-modified-key "qw")
        (should emacos--armed-tap)
        (should (equal (plist-get emacos--armed-tap :group) "qw"))
        (should (= (plist-get emacos--armed-tap :index) 0))
        (should-not fired-cmd)
        ;; Re-tap: cycles to w.
        (emacos--tap-modified-key "qw")
        (should (= (plist-get emacos--armed-tap :index) 1))
        (should-not fired-cmd)
        ;; Commit fires C-w.
        (emacos--commit-armed-tap)
        (should (eq fired-cmd 'w))
        (should-not emacos--armed-tap)))))

(ert-deftest test-os-tap-modified-key-empty-group-noop ()
  "Empty subset under MOD: silent no-op (no fire, no arm)."
  (let ((emacos--modifier 'C)
        (emacos--armed-tap nil))
    (with-temp-buffer
      (test-os--with-tap-env ()                       ; nothing bound
        (emacos--tap-modified-key "qw")
        (should-not emacos--armed-tap)))))

(ert-deftest test-os-tap-modified-key-different-group-commits-prior ()
  "Arm group A (qw), tap group B (as): A's binding fires, B becomes armed."
  (let ((fired-cmd nil)
        (emacos--modifier 'C)
        (emacos--armed-tap nil)
        (emacos--armed-tap-timer nil))
    (with-temp-buffer
      (test-os--with-tap-env
          (("C-q" (lambda () (interactive) (setq fired-cmd 'q)))
           ("C-w" (lambda () (interactive) (setq fired-cmd 'w)))
           ("C-a" (lambda () (interactive) (setq fired-cmd 'a)))
           ("C-s" (lambda () (interactive) (setq fired-cmd 's))))
        (emacos--tap-modified-key "qw")     ; arms C-q
        (should-not fired-cmd)
        (emacos--tap-modified-key "as")     ; commits C-q, arms C-a
        (should (eq fired-cmd 'q))
        (should (equal (plist-get emacos--armed-tap :group) "as"))
        (should (= (plist-get emacos--armed-tap :index) 0))))))

;;; A2: MOD-tap commits armed, advances state.  A3: QUIT abandons; SPC/RET/DEL/TAB commit.

(ert-deftest test-os-tap-modifier-with-armed-commits-then-cycles ()
  "A2: MOD-tap with a binding armed COMMITS the armed binding, then
advances the modifier cycle."
  (let ((fired nil)
        (emacos--modifier 'C)
        (emacos--armed-tap nil)
        (emacos--armed-tap-timer nil))
    (with-temp-buffer
      (test-os--with-tap-env
          (("C-q" (lambda () (interactive) (setq fired t)))
           ("C-w" #'ignore))                          ; force arm path
        (cl-letf (((symbol-function 'emacos--commit) (lambda () nil)))
          (setq emacos--armed-tap
                (list :group "qw" :index 0
                      :window win :buffer (current-buffer)))
          (emacos--tap-modifier)
          (should fired)                              ; A2: armed fired
          (should (eq emacos--modifier 'M))           ; ... then advanced
          (should-not emacos--armed-tap))))))

(ert-deftest test-os-tap-quit-abandons-armed ()
  "A3: QUIT abandons (does NOT fire) the armed binding.
QUIT is the phone's C-g; firing the armed command on QUIT would
violate the documented escape-hatch contract."
  (let ((fired nil)
        (emacos--armed-tap nil)
        (emacos--modifier 'C))
    (with-temp-buffer
      (test-os--with-tap-env
          (("C-q" (lambda () (interactive) (setq fired t))))
        (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () nil))
                  ((symbol-function 'delete-other-windows) #'ignore))
          (setq emacos--armed-tap
                (list :group "q" :index 0
                      :window win :buffer (current-buffer)))
          (emacos--tap-quit)
          (should-not fired)
          (should-not emacos--armed-tap))))))

(ert-deftest test-os-utility-taps-commit-armed ()
  "A3 (non-QUIT half): SPC / RET / DEL / TAB commit any armed binding
before doing their thing.  QUIT is its own test (abandons)."
  (dolist (tap-fn '(emacos--tap-space emacos--tap-return
                    emacos--tap-backspace emacos--tap-tab))
    (let ((fired nil)
          (emacos--armed-tap nil)
          (emacos--modifier 'C))
      (with-temp-buffer
        (test-os--with-tap-env
            (("C-q" (lambda () (interactive) (setq fired t))))
          (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () nil))
                    ;; suppress side effects of the real handlers
                    ((symbol-function 'indent-for-tab-command)
                     (lambda (&rest _) (interactive))))
            (setq emacos--armed-tap
                  (list :group "q" :index 0
                        :window win :buffer (current-buffer)))
            (funcall tap-fn)
            (should fired)
            (should-not emacos--armed-tap)))))))

;;; A1: sticky modifier survives binding fire

(ert-deftest test-os-modifier-survives-binding-fire ()
  "After a command fires, emacos--modifier is unchanged — that's the
whole point of \"sticky\"."
  (let ((emacos--modifier 'C)
        (emacos--armed-tap nil))
    (with-temp-buffer
      (test-os--with-tap-env (("C-q" (lambda () (interactive))))
        (emacos--tap-modified-key "qw")               ; single-letter fast-fire
        (should (eq emacos--modifier 'C))))))

;;; Caps ignored under MOD (locked decision 2)

(ert-deftest test-os-modifier-ignores-caps ()
  "Caps state is ignored under MOD; canonical lowercase key fires.
If caps influenced the lookup, the test would probe C-Q (unbound) and
the binding would not fire."
  (let ((fired nil)
        (emacos--modifier 'C)
        (emacos--kbd-mode 'caps)
        (emacos--armed-tap nil))
    (with-temp-buffer
      (test-os--with-tap-env
          (("C-q" (lambda () (interactive) (setq fired t))))
        (emacos--tap-modified-key "qw")               ; only q bound
        (should fired)))))

;;; Race + teardown (Decision D)

(ert-deftest test-os-modifier-runtime-unbinding-is-silent ()
  "Race: armed letter unbound between arm and commit (e.g. minor mode
disabled).  commit-armed-tap silently abandons — no error, no fire."
  (let ((emacos--armed-tap nil)
        (emacos--armed-tap-timer nil)
        (emacos--modifier 'C))
    (with-temp-buffer
      (test-os--with-tap-env ()                       ; nothing bound NOW
        (setq emacos--armed-tap
              (list :group "q" :index 0
                    :window win :buffer (current-buffer)))
        ;; Should not throw, should clear state.
        (emacos--commit-armed-tap)
        (should-not emacos--armed-tap)))))

(ert-deftest test-os-modifier-armed-abandoned-on-buffer-killed ()
  "D3: captured buffer killed before commit → silent abandon.
Defends against `with-current-buffer' on a dead buffer."
  (let ((emacos--armed-tap nil)
        (emacos--modifier 'C))
    (let ((win (selected-window))
          (buf (generate-new-buffer " *armed-buffer-killed*")))
      (with-current-buffer buf
        (let ((map (make-sparse-keymap)))
          (define-key map (kbd "C-q") #'ignore)
          (use-local-map map)))
      (setq emacos--armed-tap
            (list :group "q" :index 0 :window win :buffer buf))
      (kill-buffer buf)
      (emacos--commit-armed-tap)               ; must not throw
      (should-not emacos--armed-tap))))

(ert-deftest test-os-modifier-armed-abandoned-on-buffer-change ()
  "D3: window still live but now displays a DIFFERENT buffer (the
captured buffer was killed or the user switched).  Silent abandon."
  (let ((fired nil)
        (emacos--armed-tap nil)
        (emacos--modifier 'C))
    (let ((win (selected-window))
          (buf-arm (generate-new-buffer " *arm*"))
          (buf-now (generate-new-buffer " *now*")))
      (unwind-protect
          (progn
            (with-current-buffer buf-arm
              (let ((map (make-sparse-keymap)))
                (define-key map (kbd "C-q")
                  (lambda () (interactive) (setq fired t)))
                (use-local-map map)))
            (setq emacos--armed-tap
                  (list :group "q" :index 0 :window win :buffer buf-arm))
            (set-window-buffer win buf-now)
            (emacos--commit-armed-tap)
            (should-not fired)
            (should-not emacos--armed-tap))
        (kill-buffer buf-arm)
        (kill-buffer buf-now)))))

;;; Action row rendering

(ert-deftest test-os-action-row-mod-label-cycles ()
  "Action row line 2 is MOD / mode button / TAB / RET; the MOD label
reflects the current state through all four positions of the cycle (and
the row keeps showing DEL/SPC/the mode button (abc)/TAB/RET alongside)."
  (dolist (pair '((nil . "mod") (C . "C") (M . "M") (C-M . "C-M")))
    (with-temp-buffer
      (let ((emacos--modifier (car pair))
            (emacos--kbd-mode 'lower))
        (emacos--render-action-row)
        (let ((s (buffer-string)))
          (should (string-match-p (regexp-quote (cdr pair)) s))
          (should (string-match-p "DEL" s))
          (should (string-match-p "SPC" s))
          (should (string-match-p "abc" s))
          (should (string-match-p "TAB" s))
          (should (string-match-p "RET" s)))))))

;;; Armed-letter preview rendering — face priority

(ert-deftest test-os-armed-letter-face-wins-foreground ()
  "When a group is armed, the armed letter's face must place yellow
*before* the button's white in the merged face list (else the white
wins via face-merge precedence and the indicator renders invisibly).
Regression for the APPEND=t-vs-nil choice in `add-face-text-property'."
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-q") #'ignore)
    (define-key map (kbd "C-w") #'ignore)
    (with-temp-buffer
      (let ((emacos--modifier 'C)
            (emacos--kbd-mode 'lower)
            (emacos--armed-tap (list :group "qw" :index 1
                                     :window (selected-window)
                                     :buffer (current-buffer)))
            (kbd-buf (current-buffer)))
        (cl-letf (((symbol-function 'key-binding)
                   (lambda (kseq &optional _accept-default &rest _)
                     (let ((b (lookup-key map kseq)))
                       (if (numberp b) nil b))))
                  ((symbol-function 'emacos--target)
                   (lambda () (selected-window)))
                  ((symbol-function 'window-buffer)
                   (lambda (&optional _) kbd-buf)))
          (emacos--render-keyboard)
          ;; Find the position whose face property mentions "yellow"
          ;; (the armed letter), then verify yellow precedes white in
          ;; THAT character's merged face spec.  Searching the whole
          ;; buffer-string would compare unrelated positions' faces.
          (let ((armed-face nil))
            (save-excursion
              (goto-char (point-min))
              (while (and (not armed-face) (< (point) (point-max)))
                (let ((face (get-text-property (point) 'face)))
                  (when (string-match-p "yellow" (format "%S" face))
                    (setq armed-face face)))
                (forward-char 1)))
            (should armed-face)             ; armed face exists
            (let* ((s (format "%S" armed-face))
                   (y-pos (string-match ":foreground[ \t]+\"yellow\"" s))
                   (w-pos (string-match ":foreground[ \t]+\"white\"" s)))
              (should y-pos)
              (when w-pos
                (should (< y-pos w-pos))))))))))

;;; Re-render on commit/abandon — armed highlight clears

(ert-deftest test-os-abandon-armed-tap-re-renders-when-state-cleared ()
  "Stale yellow highlight class of bug: after armed state clears (via
QUIT, timer, MOD-tap, etc.) the rendered yellow must go away — the
abandon seam re-renders to make that true.  No render fires when there
was nothing to clear (saves cycles)."
  (let ((renders 0))
    (cl-letf (((symbol-function 'emacos--render-page)
               (lambda () (cl-incf renders))))
      ;; No state to clear → no render.
      (let ((emacos--armed-tap nil)
            (emacos--armed-tap-timer nil))
        (emacos--abandon-armed-tap)
        (should (= renders 0)))
      ;; State was set → render once.
      (let ((emacos--armed-tap (list :group "q" :index 0
                                     :window (selected-window)
                                     :buffer (current-buffer)))
            (emacos--armed-tap-timer nil))
        (emacos--abandon-armed-tap)
        (should (= renders 1))
        (should-not emacos--armed-tap)))))

;;; Follower under MOD re-renders on buffer change regardless of command-set

(ert-deftest test-os-follower-rerenders-under-modifier-even-if-set-same ()
  "Under MOD, the keymap filter is per-buffer (minor modes vary even
when the major-mode command set doesn't).  The follower must re-render
on buffer change when modifier is active, regardless of whether
top-commands changed."
  (let ((rendered nil)
        (emacos--in-render nil)
        (emacos--last-commands '(("SAME" . same)))
        (emacos--modifier 'C))
    (cl-letf (((symbol-function 'emacos--render-page)
               (lambda () (setq rendered t)))
              ((symbol-function 'emacos--top-commands)
               (lambda () '(("SAME" . same)))))
      (emacos--on-window-buffer-change nil)
      (should rendered))))

;;; Keyboard mode cycle: numbers / symbols ;;;

(ert-deftest test-os-active-layout-per-mode ()
  "The active layout follows the mode; lower/caps both type letters."
  (let ((emacos--kbd-mode 'lower))  (should (eq (emacos--active-layout) emacos-t9-layout)))
  (let ((emacos--kbd-mode 'caps))   (should (eq (emacos--active-layout) emacos-t9-layout)))
  (let ((emacos--kbd-mode 'number)) (should (eq (emacos--active-layout) emacos-123-layout)))
  (let ((emacos--kbd-mode 'symbol)) (should (eq (emacos--active-layout) emacos-symbols-layout))))

(ert-deftest test-os-char-str-upcases-only-in-caps ()
  (let ((emacos--kbd-mode 'lower)) (should (equal (emacos--char-str ?a) "a")))
  (let ((emacos--kbd-mode 'caps))  (should (equal (emacos--char-str ?a) "A")))
  ;; caps is a no-op for digits/symbols (upcase leaves them unchanged)
  (let ((emacos--kbd-mode 'caps))
    (should (equal (emacos--char-str ?7) "7"))
    (should (equal (emacos--char-str ?@) "@"))))

(ert-deftest test-os-cycle-mode-sequence ()
  "CAPS cycles lower -> caps -> number -> symbol -> lower."
  (cl-letf (((symbol-function 'emacos--render-page) #'ignore)
            ((symbol-function 'emacos--refocus) #'ignore)
            ((symbol-function 'emacos--commit) #'ignore)
            ((symbol-function 'emacos--commit-armed-tap) #'ignore))
    (let ((emacos--kbd-mode 'lower))
      (emacos--tap-cycle-mode) (should (eq emacos--kbd-mode 'caps))
      (emacos--tap-cycle-mode) (should (eq emacos--kbd-mode 'number))
      (emacos--tap-cycle-mode) (should (eq emacos--kbd-mode 'symbol))
      (emacos--tap-cycle-mode) (should (eq emacos--kbd-mode 'lower)))))

(ert-deftest test-os-mode-button-label-per-mode ()
  "The mode button shows abc/ABC/123/#+= for each mode."
  (dolist (pair '((lower . "abc") (caps . "ABC") (number . "123") (symbol . "#+=")))
    (with-temp-buffer
      (let ((emacos--modifier nil) (emacos--kbd-mode (car pair)))
        (emacos--render-action-row)
        (should (string-match-p (regexp-quote (cdr pair)) (buffer-string)))))))

(ert-deftest test-os-numbers-9-0-share-key ()
  "Numbers layer: 1-8 single-tap, 9 and 0 share the last key."
  (let ((groups (apply #'append emacos-123-layout)))
    (should (member "90" groups))
    (dolist (d '("1" "2" "3" "4" "5" "6" "7" "8"))
      (should (member d groups)))))

(ert-deftest test-os-mod-filters-active-layer ()
  "MOD reads the ACTIVE layer, so C-/M- works over digits too (not just
letters): bound-groups returns the number layout's shape with the bound
digit surviving the filter."
  (with-temp-buffer
    (test-os--with-tap-env (("C-7" (lambda () (interactive))))
      (let* ((emacos--kbd-mode 'number)
             (bg (emacos--bound-groups 'C (current-buffer))))
        (should (= (length bg) (length emacos-123-layout)))
        (should (member "7" (apply #'append bg)))))))

(provide 'test-os)
;;; test-os.el ends here
