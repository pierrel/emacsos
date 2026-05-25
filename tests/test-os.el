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
