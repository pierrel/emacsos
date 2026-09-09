;;; test-os.el --- Tests for the os.el keyboard surface -*- lexical-binding: t -*-

;; Covers the keyboard's pure width and modifier helpers, temporary control
;; plane lifecycle, follower guard, built-in utility row, and tap dispatch.

(require 'ert)
(require 'cl-lib)
(require 'os)

(ert-deftest test-os-default-modeline-includes-sms-status ()
  "Every ordinary EmacsOS buffer exposes pending SMS status."
  (should (member '(:eval (emacos-sms-mode-line-string))
                  (default-value 'mode-line-format))))

(ert-deftest test-os-command-list-surface-is-absent ()
  (dolist (symbol '(emacos--render-commands emacos--top-commands
                    emacos--mode-commands-for emacos--chat-command-set
                    emacos-assist--command-set emacos-net--command-set))
    (should-not (fboundp symbol)))
  (dolist (symbol '(emacos-mode-commands emacos-global-commands
                    emacos--last-commands emacos--max-commands))
    (should-not (boundp symbol))))

(ert-deftest test-os-open-command-reference-uses-current-home ()
  (let ((home (make-temp-file "emacos-reference-home" t))
        (process-environment (copy-sequence process-environment))
        opened)
    (unwind-protect
        (progn
          (setenv "HOME" home)
          (let ((path (expand-file-name "EMACSOS-COMMANDS.org" home)))
            (with-temp-file path (insert "commands"))
            (cl-letf (((symbol-function 'find-file)
                       (lambda (file) (setq opened file))))
              (emacos-open-command-reference))
            (should (equal opened path))))
      (delete-directory home t))))

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

;;; Pending confirmations: disarm on another EmacsOS button action

(ert-deftest test-os-maybe-cancel-confirm-disarms-on-other-command ()
  "A different utility action cancels pending confirmation."
  (let ((emacos--chat-confirm-pending t))
    (emacos--maybe-cancel-confirm #'emacos--run-command #'save-buffer)
    (should-not emacos--chat-confirm-pending)))

(ert-deftest test-os-maybe-cancel-confirm-disarms-on-keyboard-tap ()
  "Tapping any keyboard key (a direct action, not run-command) while armed
cancels the confirm."
  (let ((emacos--chat-confirm-pending t))
    (emacos--maybe-cancel-confirm #'emacos--tap-key "abc")
    (should-not emacos--chat-confirm-pending)))

(ert-deftest test-os-maybe-cancel-confirm-keeps-armed-on-newchat-tap ()
  "A New-chat invocation through an EmacsOS button remains confirmable."
  (let ((emacos--chat-confirm-pending t))
    (emacos--maybe-cancel-confirm #'emacos--run-command #'emacos--chat-new-chat)
    (should emacos--chat-confirm-pending)))

(ert-deftest test-os-maybe-cancel-confirm-noop-when-unarmed ()
  "Nothing armed remains a no-op."
  (let ((emacos--chat-confirm-pending nil))
    (emacos--maybe-cancel-confirm #'emacos--tap-key "abc")
    (should-not emacos--chat-confirm-pending)))

(ert-deftest test-os-follower-noop-when-plane-unchanged ()
  (let ((rendered nil)
        (emacos--in-render nil)
        (emacos--last-plane nil))
    (cl-letf (((symbol-function 'emacos--render-page) (lambda () (setq rendered t)))
              ((symbol-function 'emacos--top-keyboard-plane) (lambda () nil)))
      (emacos--on-window-buffer-change nil)
      (should-not rendered))))

(ert-deftest test-os-follower-rerenders-on-plane-change ()
  "A keyboard-plane change creates or removes the temporary control window."
  (let ((rendered nil)
        (emacos--in-render nil)
        (emacos--last-plane nil))
    (cl-letf (((symbol-function 'emacos--render-page) (lambda () (setq rendered t)))
              ((symbol-function 'emacos--top-keyboard-plane) (lambda () #'ignore)))
      (emacos--on-window-buffer-change nil)
      (should rendered))))

(ert-deftest test-os-follower-noop-during-render ()
  "Re-entry guard (the brick-insurance): the follower bails when a render
is already in progress, even if the plane differs."
  (let ((rendered nil) (emacos--in-render t))
    (cl-letf (((symbol-function 'emacos--render-page) (lambda () (setq rendered t)))
              ((symbol-function 'emacos--top-keyboard-plane) (lambda () #'ignore)))
      (emacos--on-window-buffer-change nil)
      (should-not rendered))))

;;; Render dispatch: keyboard plane vs the T9 bands

(ert-deftest test-os-render-page-uses-plane-when-set ()
  "When the top buffer declares a keyboard plane, render-page paints THAT into
*keyboard* instead of the keyboard and utility rows."
  (unwind-protect       ; *keyboard* is a shared global buffer — clean it up even on failure
      (cl-letf (((symbol-function 'emacos--top-keyboard-plane)
                 (lambda () (lambda () (insert "PLANE-SENTINEL")))))
        (emacos--render-page)
        (with-current-buffer "*keyboard*"
          (let ((s (buffer-string)))
            (should (string-match-p "PLANE-SENTINEL" s))
            (should-not (string-match-p "QUIT" s)))))   ; T9 utility row absent
    (when (get-buffer "*keyboard*") (kill-buffer "*keyboard*"))))

(ert-deftest test-os-render-page-t9-when-no-plane ()
  "With no plane on the top buffer, render-page paints the normal keyboard
\(the utility row's QUIT is present, no plane content)."
  (unwind-protect
      (cl-letf (((symbol-function 'emacos--top-keyboard-plane) (lambda () nil)))
        (emacos--render-page)
        (with-current-buffer "*keyboard*"
          (let ((s (buffer-string)))
            (should (string-match-p "QUIT" s))
            (should-not (string-match-p "PLANE-SENTINEL" s)))))
    (when (get-buffer "*keyboard*") (kill-buffer "*keyboard*"))))

(ert-deftest test-os-render-page-external-keyboard-removes-control-window ()
  "An external keyboard leaves ordinary Emacs content unsplit."
  (let ((emacos-use-internal-keyboard nil)
        (text-rows 0))
    (unwind-protect
        (cl-letf (((symbol-function 'emacos--top-keyboard-plane) (lambda () nil))
                  ((symbol-function 'emacos--render-keyboard)
                   (lambda () (cl-incf text-rows)))
                  ((symbol-function 'emacos--render-action-row)
                   (lambda () (cl-incf text-rows))))
          (emacos--render-page)
          (should (= text-rows 0))
          (should-not (get-buffer "*keyboard*")))
      (when (get-buffer "*keyboard*") (kill-buffer "*keyboard*")))))

(ert-deftest test-os-render-page-external-keyboard-keeps-special-plane ()
  "Call/SMS safety planes still get a temporary control window."
  (let ((emacos-use-internal-keyboard nil))
    (unwind-protect
        (cl-letf (((symbol-function 'emacos--top-keyboard-plane)
                   (lambda () (lambda () (insert "SAFETY")))))
          (emacos--render-page)
          (should (get-buffer-window "*keyboard*"))
          (with-current-buffer "*keyboard*"
            (should (equal (buffer-string) "SAFETY"))))
      (when (get-buffer-window "*keyboard*")
        (delete-window (get-buffer-window "*keyboard*")))
      (when (get-buffer "*keyboard*") (kill-buffer "*keyboard*")))))

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

(ert-deftest test-os-tap-return-uses-conversation-activation-or-newline-and-minibuffer-ret ()
  "Touch RET shares physical conversation activation but never steals minibuffer RET."
  (let (activated accepted)
    (with-temp-buffer
      (let ((target-buffer (window-buffer (selected-window))))
        (cl-letf (((symbol-function 'emacos--commit) (lambda () nil))
                  ((symbol-function 'emacos--target) (lambda () (selected-window)))
                  ((symbol-function 'emacos--refocus) (lambda () nil))
                  ((symbol-function 'active-minibuffer-window) (lambda () nil))
                  ((symbol-function 'emacos-conversation-activate-or-newline)
                   (lambda () (setq activated (current-buffer)))))
          (emacos--tap-return)
          (should (eq activated target-buffer)))))
    (with-temp-buffer
      (cl-letf (((symbol-function 'emacos--commit) (lambda () nil))
                ((symbol-function 'emacos--target) (lambda () (selected-window)))
                ((symbol-function 'emacos--refocus) (lambda () nil))
                ((symbol-function 'active-minibuffer-window) (lambda () 'minibuffer))
                ((symbol-function 'exit-minibuffer) (lambda () (setq accepted t)))
                ((symbol-function 'emacos-conversation-activate-or-newline)
                 (lambda () (ert-fail "minibuffer RET must not activate chat"))))
        (emacos--tap-return)
        (should accepted)))))

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

;;; Follower under MOD re-renders on every buffer change

(ert-deftest test-os-follower-rerenders-under-modifier-even-if-plane-same ()
  "Under MOD, keymap filtering is buffer-local, so every change re-renders."
  (let ((rendered nil)
        (emacos--in-render nil)
        (emacos--modifier 'C))
    (cl-letf (((symbol-function 'emacos--render-page)
               (lambda () (setq rendered t))))
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
