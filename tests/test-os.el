;;; test-os.el --- Tests for the os.el keyboard surface -*- lexical-binding: t -*-

;; Covers the keyboard's pure width and modifier helpers, temporary control
;; plane lifecycle, follower guard, built-in utility row, and tap dispatch.

(require 'ert)
(require 'cl-lib)
(require 'os)

(ert-deftest test-os-default-modeline-includes-sms-status ()
  "Every ordinary EmacsOS buffer exposes pending SMS status."
  (should (member '(:eval (emacsos-sms-mode-line-string))
                  (default-value 'mode-line-format))))

(ert-deftest test-os-command-list-surface-is-absent ()
  (dolist (symbol '(emacsos--render-commands emacsos--top-commands
                    emacsos--mode-commands-for emacsos--chat-command-set
                    emacsos-assist--command-set emacsos-net--command-set))
    (should-not (fboundp symbol)))
  (dolist (symbol '(emacsos-mode-commands emacsos-global-commands
                    emacsos--last-commands emacsos--max-commands))
    (should-not (boundp symbol))))

(ert-deftest test-os-open-command-reference-uses-current-home ()
  (let ((home (make-temp-file "emacsos-reference-home" t))
        (process-environment (copy-sequence process-environment))
        opened)
    (unwind-protect
        (progn
          (setenv "HOME" home)
          (let ((path (expand-file-name "EMACSOS-COMMANDS.org" home)))
            (with-temp-file path (insert "commands"))
            (cl-letf (((symbol-function 'find-file)
                       (lambda (file) (setq opened file))))
              (emacsos-open-command-reference))
            (should (equal opened path))))
      (delete-directory home t))))

(ert-deftest test-os-global-command-prefix-owns-portable-actions ()
  (should emacsos-command-mode)
  (dolist (binding '(("C-c e c" . emacsos--chat-show-top-buffer)
                     ("C-c e t" . emacsos-command-open-thread)
                     ("C-c e n" . emacsos-command-new-thread)
                     ("C-c e r" . emacsos-assist-web-refresh-threads)
                     ("C-c e f" . emacsos-assist-new-file)
                     ("C-c e d" . emacsos-call)
                     ("C-c e m" . emacsos-send-message)
                     ("C-c e w" . emacsos-net-show)
                     ("C-c e h" . emacsos-open-command-reference)
                     ("C-c C-a n" . emacsos-command-new-thread)
                     ("C-c C-a t" . emacsos-command-open-thread)))
    (should (eq (key-binding (kbd (car binding))) (cdr binding)))))

;;; emacsos--unit-width (pure per-unit width math)

;; These pin the MATH, so they bind `emacsos--btn-label-scale' to a fixed
;; value rather than reading the production default — tuning the default
;; (the keyboard label font) must not break the width-math assertions.
(ert-deftest test-os-unit-width-full-width-single-button ()
  "1 unit, 0 gaps → floor(win-w / scale).  At scale 1.75, win-w 35 → 20."
  (let ((emacsos--btn-label-scale 1.75))
    (should (= (emacsos--unit-width 35 1.5 1 0) 20))))

(ert-deftest test-os-unit-width-accounts-for-gaps ()
  "N units with G gaps subtract G*gap before dividing by N*scale:
floor((36 - 3*1.5) / (4*1.75)) = floor(31.5/7.0) = 4."
  (let ((emacsos--btn-label-scale 1.75))
    (should (= (emacsos--unit-width 36 1.5 4 3) 4))))

(ert-deftest test-os-unit-width-min-1 ()
  "A pathologically narrow window can't drive a width <= 0."
  (let ((emacsos--btn-label-scale 1.75))
    (should (= (emacsos--unit-width 1 1.5 4 3) 1))))

(ert-deftest test-os-label-scale-fits-longest-t9-group ()
  "Regression: the production `emacsos--btn-label-scale' must leave enough
per-group cells that the longest T9 group renders in full — decoupling the
font from button height is what lets it be small enough to (the \"ert…\"
truncation bug).  3 groups, 2 gaps; the render `substring's each label to
the budget.  Pinned at win-w 20 (the phone's keyboard width); re-derives
the longest group from `emacsos-t9-layout' so it tracks layout edits."
  (let* ((longest (apply #'max (mapcar #'length
                                       (apply #'append emacsos-t9-layout))))
         (budget (emacsos--unit-width 20 emacsos--btn-gap 3 2)))
    (should (>= budget longest))))

(ert-deftest test-os-btn-applies-vertical-box-padding ()
  "A button's tap-target height comes from `emacsos--btn-vpad' via the face
box `:line-width' (HWIDTH = top/bottom), decoupled from the label font —
so a small label still yields a big button.  `emacsos--btn-hpad' is the
VWIDTH (left/right); both land in the (VWIDTH . HWIDTH) cons."
  (with-temp-buffer
    (emacsos--btn "x" #'ignore)
    (let* ((face (get-text-property (point-min) 'face))
           (line-width (plist-get (plist-get face :box) :line-width)))
      (should (equal line-width (cons emacsos--btn-hpad emacsos--btn-vpad))))))

(ert-deftest test-os-action-row-widths ()
  "Row 4: DEL 1/3 (1 unit) + SPC 2/3 (2 units).
Row 5: MOD 2 + mode 1 + TAB 1 + RET 2 (6 units / 3 gaps total).  MOD and
RET are both `(* 2 unit)' so the state-toggle and the most-tapped key get
equal fingertip-friendly width on a 320x240 screen.  All positive; the
wide ones beat the narrow."
  (let* ((win-w 36) (gap 1.5)
         (third (emacsos--unit-width win-w gap 3 1))    ; DEL=1u, SPC=2u
         (unit  (emacsos--unit-width win-w gap 6 3)))   ; mode/TAB=1u, MOD/RET=2u
    (should (> third 0))
    (should (> unit 0))
    (should (> (* 2 third) third))   ; SPC (2/3) wider than DEL (1/3)
    (should (> (* 2 unit) unit))))   ; MOD/RET (2u) wider than mode/TAB (1u)

(ert-deftest test-os-action-row-renders-del-spc-mode-tab-ret ()
  (with-temp-buffer
    (let ((emacsos--kbd-mode 'lower))    ; bind, don't rely on the global default
      (emacsos--render-action-row)
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
    (let ((emacsos--last-space-time (- 100.0 0.1)))
      (should (emacsos--double-space-p 100.0)))))

(ert-deftest test-os-double-space-not-when-slow ()
  "Past the threshold the two taps are just two ordinary spaces."
  (with-temp-buffer
    (insert "word ")
    (let ((emacsos--last-space-time
           (- 100.0 (* 2 emacsos--double-space-threshold))))
      (should-not (emacsos--double-space-p 100.0)))))

(ert-deftest test-os-double-space-not-after-punctuation ()
  "Char before the space isn't alphanumeric (already \". \") → no fire, so
the gesture can't double-period."
  (with-temp-buffer
    (insert "word. ")
    (let ((emacsos--last-space-time (- 100.0 0.1)))
      (should-not (emacsos--double-space-p 100.0)))))

(ert-deftest test-os-double-space-not-without-prior-space ()
  "No prior SPC tap recorded → never fires (a lone first space)."
  (with-temp-buffer
    (insert "word ")
    (let ((emacsos--last-space-time nil))
      (should-not (emacsos--double-space-p 100.0)))))

(ert-deftest test-os-double-space-not-mid-word ()
  "Point not preceded by a space → no fire (you're inside a word)."
  (with-temp-buffer
    (insert "word")
    (let ((emacsos--last-space-time (- 100.0 0.1)))
      (should-not (emacsos--double-space-p 100.0)))))

(ert-deftest test-os-tap-space-double-writes-period-space ()
  "Integration: a rapid second SPC rewrites the trailing space to \". \"
and consumes the gesture (`emacsos--last-space-time' back to nil)."
  (let ((buf (get-buffer-create " *dst-test*")))
    (unwind-protect
        (cl-letf (((symbol-function 'emacsos--commit) #'ignore)
                  ((symbol-function 'emacsos--refocus) #'ignore)
                  ((symbol-function 'emacsos--target) (lambda () (selected-window))))
          (save-window-excursion
            (set-window-buffer (selected-window) buf)
            (with-current-buffer buf
              (erase-buffer) (insert "word ") (goto-char (point-max)))
            (setq emacsos--last-space-time (- (float-time) 0.05))
            (emacsos--tap-space)
            (should (equal (with-current-buffer buf (buffer-string)) "word. "))
            (should-not emacsos--last-space-time)))
      (let ((kill-buffer-query-functions nil)) (kill-buffer buf)))))

(ert-deftest test-os-tap-space-single-inserts-space ()
  "A first SPC (no recent prior) inserts a plain space and records the time
so a follow-up tap can complete the gesture."
  (let ((buf (get-buffer-create " *dst-test2*")))
    (unwind-protect
        (cl-letf (((symbol-function 'emacsos--commit) #'ignore)
                  ((symbol-function 'emacsos--refocus) #'ignore)
                  ((symbol-function 'emacsos--target) (lambda () (selected-window))))
          (save-window-excursion
            (set-window-buffer (selected-window) buf)
            (with-current-buffer buf
              (erase-buffer) (insert "word") (goto-char (point-max)))
            (setq emacsos--last-space-time nil)
            (emacsos--tap-space)
            (should (equal (with-current-buffer buf (buffer-string)) "word "))
            (should emacsos--last-space-time)))
      (let ((kill-buffer-query-functions nil)) (kill-buffer buf)))))

;;; Pending confirmations: disarm on another EmacsOS button action

(ert-deftest test-os-maybe-cancel-confirm-disarms-on-other-command ()
  "A different utility action cancels pending confirmation."
  (let ((emacsos--chat-confirm-pending t))
    (emacsos--maybe-cancel-confirm #'emacsos--run-command #'save-buffer)
    (should-not emacsos--chat-confirm-pending)))

(ert-deftest test-os-maybe-cancel-confirm-disarms-on-keyboard-tap ()
  "Tapping any keyboard key (a direct action, not run-command) while armed
cancels the confirm."
  (let ((emacsos--chat-confirm-pending t))
    (emacsos--maybe-cancel-confirm #'emacsos--tap-key "abc")
    (should-not emacsos--chat-confirm-pending)))

(ert-deftest test-os-maybe-cancel-confirm-keeps-armed-on-newchat-tap ()
  "A New-chat invocation through an EmacsOS button remains confirmable."
  (let ((emacsos--chat-confirm-pending t))
    (emacsos--maybe-cancel-confirm #'emacsos--run-command #'emacsos--chat-new-chat)
    (should emacsos--chat-confirm-pending)))

(ert-deftest test-os-maybe-cancel-confirm-noop-when-unarmed ()
  "Nothing armed remains a no-op."
  (let ((emacsos--chat-confirm-pending nil))
    (emacsos--maybe-cancel-confirm #'emacsos--tap-key "abc")
    (should-not emacsos--chat-confirm-pending)))

(ert-deftest test-os-follower-noop-when-plane-unchanged ()
  (let ((rendered nil)
        (emacsos--in-render nil)
        (emacsos--last-plane nil))
    (cl-letf (((symbol-function 'emacsos--render-page) (lambda () (setq rendered t)))
              ((symbol-function 'emacsos--top-keyboard-plane) (lambda () nil)))
      (emacsos--on-window-buffer-change nil)
      (should-not rendered))))

(ert-deftest test-os-follower-rerenders-on-plane-change ()
  "A keyboard-plane change creates or removes the temporary control window."
  (let ((rendered nil)
        (emacsos--in-render nil)
        (emacsos--last-plane nil))
    (cl-letf (((symbol-function 'emacsos--render-page) (lambda () (setq rendered t)))
              ((symbol-function 'emacsos--top-keyboard-plane) (lambda () #'ignore)))
      (emacsos--on-window-buffer-change nil)
      (should rendered))))

(ert-deftest test-os-follower-noop-during-render ()
  "Re-entry guard (the brick-insurance): the follower bails when a render
is already in progress, even if the plane differs."
  (let ((rendered nil) (emacsos--in-render t))
    (cl-letf (((symbol-function 'emacsos--render-page) (lambda () (setq rendered t)))
              ((symbol-function 'emacsos--top-keyboard-plane) (lambda () #'ignore)))
      (emacsos--on-window-buffer-change nil)
      (should-not rendered))))

;;; Render dispatch: keyboard plane vs the T9 bands

(ert-deftest test-os-render-page-uses-plane-when-set ()
  "When the top buffer declares a keyboard plane, render-page paints THAT into
*keyboard* instead of the keyboard and utility rows."
  (unwind-protect       ; *keyboard* is a shared global buffer — clean it up even on failure
      (cl-letf (((symbol-function 'emacsos--top-keyboard-plane)
                 (lambda () (lambda () (insert "PLANE-SENTINEL")))))
        (emacsos--render-page)
        (with-current-buffer "*keyboard*"
          (let ((s (buffer-string)))
            (should (string-match-p "PLANE-SENTINEL" s))
            (should-not (string-match-p "QUIT" s)))))   ; T9 utility row absent
    (when (get-buffer "*keyboard*") (kill-buffer "*keyboard*"))))

(ert-deftest test-os-render-page-t9-when-no-plane ()
  "With no plane on the top buffer, render-page paints the normal keyboard
\(the utility row's QUIT is present, no plane content)."
  (unwind-protect
      (cl-letf (((symbol-function 'emacsos--top-keyboard-plane) (lambda () nil)))
        (emacsos--render-page)
        (with-current-buffer "*keyboard*"
          (let ((s (buffer-string)))
            (should (string-match-p "QUIT" s))
            (should-not (string-match-p "PLANE-SENTINEL" s)))))
    (when (get-buffer "*keyboard*") (kill-buffer "*keyboard*"))))

(ert-deftest test-os-render-page-external-keyboard-removes-control-window ()
  "An external keyboard leaves ordinary Emacs content unsplit."
  (let ((emacsos-use-internal-keyboard nil)
        (text-rows 0))
    (unwind-protect
        (cl-letf (((symbol-function 'emacsos--top-keyboard-plane) (lambda () nil))
                  ((symbol-function 'emacsos--render-keyboard)
                   (lambda () (cl-incf text-rows)))
                  ((symbol-function 'emacsos--render-action-row)
                   (lambda () (cl-incf text-rows))))
          (emacsos--render-page)
          (should (= text-rows 0))
          (should-not (get-buffer "*keyboard*")))
      (when (get-buffer "*keyboard*") (kill-buffer "*keyboard*")))))

(ert-deftest test-os-render-page-external-keyboard-keeps-special-plane ()
  "Call/SMS safety planes still get a temporary control window."
  (let ((emacsos-use-internal-keyboard nil))
    (unwind-protect
        (cl-letf (((symbol-function 'emacsos--top-keyboard-plane)
                   (lambda () (lambda () (insert "SAFETY")))))
          (emacsos--render-page)
          (should (get-buffer-window "*keyboard*"))
          (with-current-buffer "*keyboard*"
            (should (equal (buffer-string) "SAFETY"))))
      (when (get-buffer-window "*keyboard*")
        (delete-window (get-buffer-window "*keyboard*")))
      (when (get-buffer "*keyboard*") (kill-buffer "*keyboard*")))))

;;; Utility row: QUIT + M-x + Chat (the mode button lives on the action row)

(ert-deftest test-os-utility-row-has-quit-mx-chat ()
  (with-temp-buffer
    (let ((emacsos--kbd-mode 'lower))
      (emacsos--render-utility-row)
      (let ((s (buffer-string)))
        (should (string-match-p "QUIT" s))
        (should (string-match-p "M-x" s))
        (should (string-match-p "Chat" s))
        ;; the mode button lives on the action row, not here
        (should-not (string-match-p "abc\\|ABC" s))))))

;;; emacsos--tap-quit (smart escape)

(ert-deftest test-os-tap-quit-aborts-active-minibuffer ()
  "With a minibuffer active, QUIT aborts it and does NOT touch windows."
  (let ((aborted nil) (quit-win nil) (del-others nil))
    (cl-letf (((symbol-function 'emacsos--commit) (lambda () nil))
              ((symbol-function 'active-minibuffer-window) (lambda () 'mb))
              ((symbol-function 'abort-recursive-edit)
               (lambda () (setq aborted t)))
              ((symbol-function 'quit-window) (lambda (&rest _) (setq quit-win t)))
              ((symbol-function 'delete-other-windows)
               (lambda (&rest _) (setq del-others t))))
      (emacsos--tap-quit)
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
        (cl-letf (((symbol-function 'emacsos--commit) (lambda () nil))
                  ((symbol-function 'active-minibuffer-window) (lambda () nil))
                  ((symbol-function 'emacsos--target) (lambda () (selected-window)))
                  ((symbol-function 'window-buffer) (lambda (&rest _) buf))
                  ((symbol-function 'emacsos--render-page) (lambda () nil))
                  ((symbol-function 'emacsos--refocus) (lambda () nil))
                  ((symbol-function 'quit-window) (lambda (&rest _) (setq quit-win t)))
                  ((symbol-function 'delete-other-windows)
                   (lambda (&rest _) (setq del-others t))))
          (emacsos--tap-quit)
          (should quit-win)
          (should del-others))))))

(ert-deftest test-os-tap-quit-completion-list-is-quit ()
  "*Completions* is completion-list-mode (parent nil in Emacs 30), so
the predicate must catch it explicitly — quit-window must fire."
  (let ((quit-win nil))
    (with-temp-buffer
      (setq-local major-mode 'completion-list-mode)
      (let ((buf (current-buffer)))
        (cl-letf (((symbol-function 'emacsos--commit) (lambda () nil))
                  ((symbol-function 'active-minibuffer-window) (lambda () nil))
                  ((symbol-function 'emacsos--target) (lambda () (selected-window)))
                  ((symbol-function 'window-buffer) (lambda (&rest _) buf))
                  ((symbol-function 'emacsos--render-page) (lambda () nil))
                  ((symbol-function 'emacsos--refocus) (lambda () nil))
                  ((symbol-function 'quit-window) (lambda (&rest _) (setq quit-win t)))
                  ((symbol-function 'delete-other-windows) (lambda (&rest _) nil)))
          (emacsos--tap-quit)
          (should quit-win))))))

(ert-deftest test-os-tap-quit-ordinary-buffer-no-quit-window ()
  "An ordinary (non-special) top buffer: don't quit-window it, but still
collapse popup windows (harmless no-op when there are none)."
  (let ((quit-win nil) (del-others nil))
    (with-temp-buffer
      (fundamental-mode)
      (let ((buf (current-buffer)))
        (cl-letf (((symbol-function 'emacsos--commit) (lambda () nil))
                  ((symbol-function 'active-minibuffer-window) (lambda () nil))
                  ((symbol-function 'emacsos--target) (lambda () (selected-window)))
                  ((symbol-function 'window-buffer) (lambda (&rest _) buf))
                  ((symbol-function 'emacsos--render-page) (lambda () nil))
                  ((symbol-function 'emacsos--refocus) (lambda () nil))
                  ((symbol-function 'quit-window) (lambda (&rest _) (setq quit-win t)))
                  ((symbol-function 'delete-other-windows)
                   (lambda (&rest _) (setq del-others t))))
          (emacsos--tap-quit)
          (should-not quit-win)
          (should del-others))))))

;;; emacsos--tap-tab dispatch

(ert-deftest test-os-tap-tab-indents-in-buffer ()
  ;; Stubs must be commands (`call-interactively' rejects non-commands),
  ;; hence the (interactive) form in each.
  (let ((called nil))
    (cl-letf (((symbol-function 'emacsos--commit) (lambda () nil))
              ((symbol-function 'emacsos--target) (lambda () (selected-window)))
              ((symbol-function 'emacsos--refocus) (lambda () nil))
              ((symbol-function 'active-minibuffer-window) (lambda () nil))
              ((symbol-function 'indent-for-tab-command)
               (lambda (&rest _) (interactive) (setq called 'indent)))
              ((symbol-function 'minibuffer-complete)
               (lambda (&rest _) (interactive) (setq called 'complete))))
      (emacsos--tap-tab)
      (should (eq called 'indent)))))

(ert-deftest test-os-tap-tab-completes-in-minibuffer ()
  (let ((called nil))
    (cl-letf (((symbol-function 'emacsos--commit) (lambda () nil))
              ((symbol-function 'emacsos--target) (lambda () (selected-window)))
              ((symbol-function 'emacsos--refocus) (lambda () nil))
              ((symbol-function 'active-minibuffer-window) (lambda () 'mb))
              ((symbol-function 'indent-for-tab-command)
               (lambda (&rest _) (interactive) (setq called 'indent)))
              ((symbol-function 'minibuffer-complete)
               (lambda (&rest _) (interactive) (setq called 'complete))))
      (emacsos--tap-tab)
      (should (eq called 'complete)))))

(ert-deftest test-os-tap-return-uses-conversation-activation-or-newline-and-minibuffer-ret ()
  "Touch RET shares physical conversation activation but never steals minibuffer RET."
  (let (activated accepted)
    (with-temp-buffer
      (let ((target-buffer (window-buffer (selected-window))))
        (cl-letf (((symbol-function 'emacsos--commit) (lambda () nil))
                  ((symbol-function 'emacsos--target) (lambda () (selected-window)))
                  ((symbol-function 'emacsos--refocus) (lambda () nil))
                  ((symbol-function 'active-minibuffer-window) (lambda () nil))
                  ((symbol-function 'emacsos-conversation-activate-or-newline)
                   (lambda () (setq activated (current-buffer)))))
          (emacsos--tap-return)
          (should (eq activated target-buffer)))))
    (with-temp-buffer
      (cl-letf (((symbol-function 'emacsos--commit) (lambda () nil))
                ((symbol-function 'emacsos--target) (lambda () (selected-window)))
                ((symbol-function 'emacsos--refocus) (lambda () nil))
                ((symbol-function 'active-minibuffer-window) (lambda () 'minibuffer))
                ((symbol-function 'exit-minibuffer) (lambda () (setq accepted t)))
                ((symbol-function 'emacsos-conversation-activate-or-newline)
                 (lambda () (ert-fail "minibuffer RET must not activate chat"))))
        (emacsos--tap-return)
        (should accepted)))))

;;; Modifier keys (Ctrl / Meta / Ctrl-Meta) — see
;;; docs/2026-05-27-modifier-keys.org.  Pure helpers tested directly;
;;; tap dispatch + commit/abandon tested with real keymaps in
;;; with-temp-buffer scopes and minimal cl-letf stubs.

(ert-deftest test-os-modifier-cycle-none-C-M-CM-none ()
  "Pure cycle, no state side effects."
  (should (eq (emacsos--modifier-next nil) 'C))
  (should (eq (emacsos--modifier-next 'C) 'M))
  (should (eq (emacsos--modifier-next 'M) 'C-M))
  (should (eq (emacsos--modifier-next 'C-M) nil)))

(ert-deftest test-os-modifier-prefix-strings ()
  (should (equal (emacsos--modifier-prefix nil) ""))
  (should (equal (emacsos--modifier-prefix 'C) "C-"))
  (should (equal (emacsos--modifier-prefix 'M) "M-"))
  (should (equal (emacsos--modifier-prefix 'C-M) "C-M-")))

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
            (should (equal (emacsos--bound-letters-in-group "qwerty" 'C buf) "qy"))
            ;; empty: nothing bound under M
            (should (equal (emacsos--bound-letters-in-group "qwerty" 'M buf) ""))
            ;; single-letter result preserved
            (should (equal (emacsos--bound-letters-in-group "qw" 'C buf) "q"))))))))

(ert-deftest test-os-letter-bound-p-rejects-non-command ()
  "Prefix keys (function-value is a keymap) must NOT be commandp."
  (with-temp-buffer
    (let ((map (make-sparse-keymap)))
      (define-key map (kbd "C-z") (make-sparse-keymap))   ; prefix
      (test-os--with-map map
        (lambda ()
          (should-not (emacsos--letter-bound-p ?z 'C (current-buffer))))))))

(ert-deftest test-os-bound-groups-preserves-shape ()
  "bound-groups returns the same row/col shape as emacsos-t9-layout."
  (with-temp-buffer
    (let ((map (make-sparse-keymap)))
      (define-key map (kbd "C-q") #'ignore)
      (test-os--with-map map
        (lambda ()
          (let ((bg (emacsos--bound-groups 'C (current-buffer))))
            (should (= (length bg) (length emacsos-t9-layout)))
            (cl-loop for filt-row in bg
                     for orig-row in emacsos-t9-layout
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
- `emacsos--target' → returns the selected window.
- `window-buffer' → returns the temp buffer (so D3 validation passes;
  in batch mode the selected window doesn't display the temp buffer).
- `emacsos--refocus', `emacsos--render-page', `run-with-timer' → no-ops.

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
                 ((symbol-function 'emacsos--target) (lambda () win))
                 ((symbol-function 'emacsos--refocus) (lambda () nil))
                 ((symbol-function 'emacsos--render-page) (lambda () nil))
                 ((symbol-function 'run-with-timer) (lambda (&rest _) nil)))
         ,@body))))

(ert-deftest test-os-tap-modified-key-single-bound-fires-immediately ()
  "Single-letter fast-path: only one letter bound under MOD → fire on
tap, no arm, no timer.  Honors the user's literal \"click is C-q\"."
  (let ((fired nil)
        (emacsos--modifier 'C)
        (emacsos--armed-tap nil))
    (with-temp-buffer
      (test-os--with-tap-env (("C-q" (lambda () (interactive) (setq fired t))))
        (emacsos--tap-modified-key "qw")
        (should fired)
        (should-not emacsos--armed-tap)))))

(ert-deftest test-os-tap-modified-key-arms-then-commits ()
  "Multi-letter subset: first tap arms (no fire), re-tap cycles,
explicit commit fires the cycled letter."
  (let ((fired-cmd nil)
        (emacsos--modifier 'C)
        (emacsos--armed-tap nil)
        (emacsos--armed-tap-timer nil))
    (with-temp-buffer
      (test-os--with-tap-env
          (("C-q" (lambda () (interactive) (setq fired-cmd 'q)))
           ("C-w" (lambda () (interactive) (setq fired-cmd 'w))))
        ;; First tap: arms at q.
        (emacsos--tap-modified-key "qw")
        (should emacsos--armed-tap)
        (should (equal (plist-get emacsos--armed-tap :group) "qw"))
        (should (= (plist-get emacsos--armed-tap :index) 0))
        (should-not fired-cmd)
        ;; Re-tap: cycles to w.
        (emacsos--tap-modified-key "qw")
        (should (= (plist-get emacsos--armed-tap :index) 1))
        (should-not fired-cmd)
        ;; Commit fires C-w.
        (emacsos--commit-armed-tap)
        (should (eq fired-cmd 'w))
        (should-not emacsos--armed-tap)))))

(ert-deftest test-os-tap-modified-key-empty-group-noop ()
  "Empty subset under MOD: silent no-op (no fire, no arm)."
  (let ((emacsos--modifier 'C)
        (emacsos--armed-tap nil))
    (with-temp-buffer
      (test-os--with-tap-env ()                       ; nothing bound
        (emacsos--tap-modified-key "qw")
        (should-not emacsos--armed-tap)))))

(ert-deftest test-os-tap-modified-key-different-group-commits-prior ()
  "Arm group A (qw), tap group B (as): A's binding fires, B becomes armed."
  (let ((fired-cmd nil)
        (emacsos--modifier 'C)
        (emacsos--armed-tap nil)
        (emacsos--armed-tap-timer nil))
    (with-temp-buffer
      (test-os--with-tap-env
          (("C-q" (lambda () (interactive) (setq fired-cmd 'q)))
           ("C-w" (lambda () (interactive) (setq fired-cmd 'w)))
           ("C-a" (lambda () (interactive) (setq fired-cmd 'a)))
           ("C-s" (lambda () (interactive) (setq fired-cmd 's))))
        (emacsos--tap-modified-key "qw")     ; arms C-q
        (should-not fired-cmd)
        (emacsos--tap-modified-key "as")     ; commits C-q, arms C-a
        (should (eq fired-cmd 'q))
        (should (equal (plist-get emacsos--armed-tap :group) "as"))
        (should (= (plist-get emacsos--armed-tap :index) 0))))))

;;; A2: MOD-tap commits armed, advances state.  A3: QUIT abandons; SPC/RET/DEL/TAB commit.

(ert-deftest test-os-tap-modifier-with-armed-commits-then-cycles ()
  "A2: MOD-tap with a binding armed COMMITS the armed binding, then
advances the modifier cycle."
  (let ((fired nil)
        (emacsos--modifier 'C)
        (emacsos--armed-tap nil)
        (emacsos--armed-tap-timer nil))
    (with-temp-buffer
      (test-os--with-tap-env
          (("C-q" (lambda () (interactive) (setq fired t)))
           ("C-w" #'ignore))                          ; force arm path
        (cl-letf (((symbol-function 'emacsos--commit) (lambda () nil)))
          (setq emacsos--armed-tap
                (list :group "qw" :index 0
                      :window win :buffer (current-buffer)))
          (emacsos--tap-modifier)
          (should fired)                              ; A2: armed fired
          (should (eq emacsos--modifier 'M))           ; ... then advanced
          (should-not emacsos--armed-tap))))))

(ert-deftest test-os-tap-quit-abandons-armed ()
  "A3: QUIT abandons (does NOT fire) the armed binding.
QUIT is the phone's C-g; firing the armed command on QUIT would
violate the documented escape-hatch contract."
  (let ((fired nil)
        (emacsos--armed-tap nil)
        (emacsos--modifier 'C))
    (with-temp-buffer
      (test-os--with-tap-env
          (("C-q" (lambda () (interactive) (setq fired t))))
        (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () nil))
                  ((symbol-function 'delete-other-windows) #'ignore))
          (setq emacsos--armed-tap
                (list :group "q" :index 0
                      :window win :buffer (current-buffer)))
          (emacsos--tap-quit)
          (should-not fired)
          (should-not emacsos--armed-tap))))))

(ert-deftest test-os-utility-taps-commit-armed ()
  "A3 (non-QUIT half): SPC / RET / DEL / TAB commit any armed binding
before doing their thing.  QUIT is its own test (abandons)."
  (dolist (tap-fn '(emacsos--tap-space emacsos--tap-return
                    emacsos--tap-backspace emacsos--tap-tab))
    (let ((fired nil)
          (emacsos--armed-tap nil)
          (emacsos--modifier 'C))
      (with-temp-buffer
        (test-os--with-tap-env
            (("C-q" (lambda () (interactive) (setq fired t))))
          (cl-letf (((symbol-function 'active-minibuffer-window) (lambda () nil))
                    ;; suppress side effects of the real handlers
                    ((symbol-function 'indent-for-tab-command)
                     (lambda (&rest _) (interactive))))
            (setq emacsos--armed-tap
                  (list :group "q" :index 0
                        :window win :buffer (current-buffer)))
            (funcall tap-fn)
            (should fired)
            (should-not emacsos--armed-tap)))))))

;;; A1: sticky modifier survives binding fire

(ert-deftest test-os-modifier-survives-binding-fire ()
  "After a command fires, emacsos--modifier is unchanged — that's the
whole point of \"sticky\"."
  (let ((emacsos--modifier 'C)
        (emacsos--armed-tap nil))
    (with-temp-buffer
      (test-os--with-tap-env (("C-q" (lambda () (interactive))))
        (emacsos--tap-modified-key "qw")               ; single-letter fast-fire
        (should (eq emacsos--modifier 'C))))))

;;; Caps ignored under MOD (locked decision 2)

(ert-deftest test-os-modifier-ignores-caps ()
  "Caps state is ignored under MOD; canonical lowercase key fires.
If caps influenced the lookup, the test would probe C-Q (unbound) and
the binding would not fire."
  (let ((fired nil)
        (emacsos--modifier 'C)
        (emacsos--kbd-mode 'caps)
        (emacsos--armed-tap nil))
    (with-temp-buffer
      (test-os--with-tap-env
          (("C-q" (lambda () (interactive) (setq fired t))))
        (emacsos--tap-modified-key "qw")               ; only q bound
        (should fired)))))

;;; Race + teardown (Decision D)

(ert-deftest test-os-modifier-runtime-unbinding-is-silent ()
  "Race: armed letter unbound between arm and commit (e.g. minor mode
disabled).  commit-armed-tap silently abandons — no error, no fire."
  (let ((emacsos--armed-tap nil)
        (emacsos--armed-tap-timer nil)
        (emacsos--modifier 'C))
    (with-temp-buffer
      (test-os--with-tap-env ()                       ; nothing bound NOW
        (setq emacsos--armed-tap
              (list :group "q" :index 0
                    :window win :buffer (current-buffer)))
        ;; Should not throw, should clear state.
        (emacsos--commit-armed-tap)
        (should-not emacsos--armed-tap)))))

(ert-deftest test-os-modifier-armed-abandoned-on-buffer-killed ()
  "D3: captured buffer killed before commit → silent abandon.
Defends against `with-current-buffer' on a dead buffer."
  (let ((emacsos--armed-tap nil)
        (emacsos--modifier 'C))
    (let ((win (selected-window))
          (buf (generate-new-buffer " *armed-buffer-killed*")))
      (with-current-buffer buf
        (let ((map (make-sparse-keymap)))
          (define-key map (kbd "C-q") #'ignore)
          (use-local-map map)))
      (setq emacsos--armed-tap
            (list :group "q" :index 0 :window win :buffer buf))
      (kill-buffer buf)
      (emacsos--commit-armed-tap)               ; must not throw
      (should-not emacsos--armed-tap))))

(ert-deftest test-os-modifier-armed-abandoned-on-buffer-change ()
  "D3: window still live but now displays a DIFFERENT buffer (the
captured buffer was killed or the user switched).  Silent abandon."
  (let ((fired nil)
        (emacsos--armed-tap nil)
        (emacsos--modifier 'C))
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
            (setq emacsos--armed-tap
                  (list :group "q" :index 0 :window win :buffer buf-arm))
            (set-window-buffer win buf-now)
            (emacsos--commit-armed-tap)
            (should-not fired)
            (should-not emacsos--armed-tap))
        (kill-buffer buf-arm)
        (kill-buffer buf-now)))))

;;; Action row rendering

(ert-deftest test-os-action-row-mod-label-cycles ()
  "Action row line 2 is MOD / mode button / TAB / RET; the MOD label
reflects the current state through all four positions of the cycle (and
the row keeps showing DEL/SPC/the mode button (abc)/TAB/RET alongside)."
  (dolist (pair '((nil . "mod") (C . "C") (M . "M") (C-M . "C-M")))
    (with-temp-buffer
      (let ((emacsos--modifier (car pair))
            (emacsos--kbd-mode 'lower))
        (emacsos--render-action-row)
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
      (let ((emacsos--modifier 'C)
            (emacsos--kbd-mode 'lower)
            (emacsos--armed-tap (list :group "qw" :index 1
                                     :window (selected-window)
                                     :buffer (current-buffer)))
            (kbd-buf (current-buffer)))
        (cl-letf (((symbol-function 'key-binding)
                   (lambda (kseq &optional _accept-default &rest _)
                     (let ((b (lookup-key map kseq)))
                       (if (numberp b) nil b))))
                  ((symbol-function 'emacsos--target)
                   (lambda () (selected-window)))
                  ((symbol-function 'window-buffer)
                   (lambda (&optional _) kbd-buf)))
          (emacsos--render-keyboard)
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
    (cl-letf (((symbol-function 'emacsos--render-page)
               (lambda () (cl-incf renders))))
      ;; No state to clear → no render.
      (let ((emacsos--armed-tap nil)
            (emacsos--armed-tap-timer nil))
        (emacsos--abandon-armed-tap)
        (should (= renders 0)))
      ;; State was set → render once.
      (let ((emacsos--armed-tap (list :group "q" :index 0
                                     :window (selected-window)
                                     :buffer (current-buffer)))
            (emacsos--armed-tap-timer nil))
        (emacsos--abandon-armed-tap)
        (should (= renders 1))
        (should-not emacsos--armed-tap)))))

;;; Follower under MOD re-renders on every buffer change

(ert-deftest test-os-follower-rerenders-under-modifier-even-if-plane-same ()
  "Under MOD, keymap filtering is buffer-local, so every change re-renders."
  (let ((rendered nil)
        (emacsos--in-render nil)
        (emacsos--modifier 'C))
    (cl-letf (((symbol-function 'emacsos--render-page)
               (lambda () (setq rendered t))))
      (emacsos--on-window-buffer-change nil)
      (should rendered))))

;;; Keyboard mode cycle: numbers / symbols ;;;

(ert-deftest test-os-active-layout-per-mode ()
  "The active layout follows the mode; lower/caps both type letters."
  (let ((emacsos--kbd-mode 'lower))  (should (eq (emacsos--active-layout) emacsos-t9-layout)))
  (let ((emacsos--kbd-mode 'caps))   (should (eq (emacsos--active-layout) emacsos-t9-layout)))
  (let ((emacsos--kbd-mode 'number)) (should (eq (emacsos--active-layout) emacsos-123-layout)))
  (let ((emacsos--kbd-mode 'symbol)) (should (eq (emacsos--active-layout) emacsos-symbols-layout))))

(ert-deftest test-os-char-str-upcases-only-in-caps ()
  (let ((emacsos--kbd-mode 'lower)) (should (equal (emacsos--char-str ?a) "a")))
  (let ((emacsos--kbd-mode 'caps))  (should (equal (emacsos--char-str ?a) "A")))
  ;; caps is a no-op for digits/symbols (upcase leaves them unchanged)
  (let ((emacsos--kbd-mode 'caps))
    (should (equal (emacsos--char-str ?7) "7"))
    (should (equal (emacsos--char-str ?@) "@"))))

(ert-deftest test-os-cycle-mode-sequence ()
  "CAPS cycles lower -> caps -> number -> symbol -> lower."
  (cl-letf (((symbol-function 'emacsos--render-page) #'ignore)
            ((symbol-function 'emacsos--refocus) #'ignore)
            ((symbol-function 'emacsos--commit) #'ignore)
            ((symbol-function 'emacsos--commit-armed-tap) #'ignore))
    (let ((emacsos--kbd-mode 'lower))
      (emacsos--tap-cycle-mode) (should (eq emacsos--kbd-mode 'caps))
      (emacsos--tap-cycle-mode) (should (eq emacsos--kbd-mode 'number))
      (emacsos--tap-cycle-mode) (should (eq emacsos--kbd-mode 'symbol))
      (emacsos--tap-cycle-mode) (should (eq emacsos--kbd-mode 'lower)))))

(ert-deftest test-os-mode-button-label-per-mode ()
  "The mode button shows abc/ABC/123/#+= for each mode."
  (dolist (pair '((lower . "abc") (caps . "ABC") (number . "123") (symbol . "#+=")))
    (with-temp-buffer
      (let ((emacsos--modifier nil) (emacsos--kbd-mode (car pair)))
        (emacsos--render-action-row)
        (should (string-match-p (regexp-quote (cdr pair)) (buffer-string)))))))

(ert-deftest test-os-numbers-9-0-share-key ()
  "Numbers layer: 1-8 single-tap, 9 and 0 share the last key."
  (let ((groups (apply #'append emacsos-123-layout)))
    (should (member "90" groups))
    (dolist (d '("1" "2" "3" "4" "5" "6" "7" "8"))
      (should (member d groups)))))

(ert-deftest test-os-mod-filters-active-layer ()
  "MOD reads the ACTIVE layer, so C-/M- works over digits too (not just
letters): bound-groups returns the number layout's shape with the bound
digit surviving the filter."
  (with-temp-buffer
    (test-os--with-tap-env (("C-7" (lambda () (interactive))))
      (let* ((emacsos--kbd-mode 'number)
             (bg (emacsos--bound-groups 'C (current-buffer))))
        (should (= (length bg) (length emacsos-123-layout)))
        (should (member "7" (apply #'append bg)))))))

(provide 'test-os)
;;; test-os.el ends here
