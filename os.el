;;; os.el --- EmacsOS -*- lexical-binding: t -*-

(require 'seq)  ; seq-take, used by `emacos--render-commands'

(defgroup emacsos nil
  "EmacsOS: malleable, agent-customizable, local-first phone OS."
  :group 'applications
  :prefix "emacos-")

;; Disable chrome
(setq inhibit-startup-screen t
      inhibit-startup-message t
      window-min-height 1)

(menu-bar-mode -1)
(when (fboundp 'tool-bar-mode) (tool-bar-mode -1))

;;; Optimal-T9 Keyboard (Qin et al., ISS 2018)
;;
;;  [ q w  ] [e r t y u i] [ o p  ]
;;  [ a s  ] [ d f g h   ] [j k l ]
;;  [z x c ] [ v b n     ] [  m   ]
;;  [     SPACE     ] [RET] [ DEL ]
;;  [CAPS]

(defvar emacos-t9-layout
  '(("qw" "ertyui" "op")
    ("as" "dfgh"   "jkl")
    ("zxc" "vbn"   "m"))
  "Optimal-T9 keyboard layout.  Each key group is a string of letters.")

;; Multi-tap state
(defvar emacos--target-window nil)
(defvar emacos--current-key nil)
(defvar emacos--tap-index 0)
(defvar emacos--commit-timer nil)
(defvar emacos--caps nil)

;; Double-tap-space → ". " state
(defvar emacos--last-space-time nil
  "`float-time' of the most recent SPC tap, or nil.
Drives the double-tap-space gesture (`emacos--double-space-p'): a second
SPC within `emacos--double-space-threshold' turns the just-typed space
into a period + space.")

(defconst emacos--double-space-threshold 0.5
  "Max seconds between two SPC taps for the double-space → \". \" gesture.
Past this they're treated as two ordinary spaces, matching the \"tap
twice rapidly\" feel.")

;; Render state
(defvar emacos--in-render nil
  "Non-nil while `emacos--render-page' is running.
Transient re-entry guard so the `window-buffer-change-functions'
follower can't recurse into a render that is already in progress.
The chosen hook does not fire on our in-place re-render today, but a
future render that swaps a window's buffer would reintroduce the loop
hazard, and on a phone an infinite re-render bricks the device — so the
guard is kept even though nothing can trip it now.")

(defvar emacos--last-commands 'unset
  "The command set `emacos--render-commands' last rendered.
The follower re-renders only when the top buffer's derived command set
actually changes, so transient buffers (*Completions*, *Help*) don't
flicker the command list — the keyboard itself never moves.")

(defun emacos--target ()
  "Return the editing window (not the keyboard).
Prefer the minibuffer when it is active."
  (or (active-minibuffer-window)
      (if (and (windowp emacos--target-window)
               (window-live-p emacos--target-window))
          emacos--target-window
        (let ((kb (get-buffer "*keyboard*")))
          (catch 'found
            (walk-windows
             (lambda (w)
               (unless (eq (window-buffer w) kb)
                 (setq emacos--target-window w)
                 (throw 'found w)))
             nil (selected-frame)))))))

(defun emacos--refocus ()
  "Return focus to the editing window."
  (let ((w (emacos--target)))
    (when w (select-window w))))

(defun emacos--cancel-timer ()
  (when (timerp emacos--commit-timer)
    (cancel-timer emacos--commit-timer)
    (setq emacos--commit-timer nil)))

(defun emacos--commit ()
  (emacos--cancel-timer)
  (setq emacos--current-key nil emacos--tap-index 0))

(defun emacos--char-str (ch)
  "Return CH as a string, respecting caps state."
  (funcall (if emacos--caps #'upcase #'identity)
           (char-to-string ch)))

;;; Key actions

(defun emacos--tap-key (kg)
  "Handle a tap on key group KG.  Multi-tap cycles through letters."
  (let ((w (emacos--target)))
    (when w
      (emacos--cancel-timer)
      (if (equal kg emacos--current-key)
          ;; Same key: cycle to next letter
          (let ((i (mod (1+ emacos--tap-index) (length kg))))
            (setq emacos--tap-index i)
            (with-selected-window w
              (delete-char -1)
              (insert (emacos--char-str (aref kg i)))))
        ;; Different key: commit previous, start new
        (emacos--commit)
        (setq emacos--current-key kg emacos--tap-index 0)
        (with-selected-window w
          (insert (emacos--char-str (aref kg 0)))))
      ;; Auto-commit after timeout
      (setq emacos--commit-timer
            (run-with-timer 1.0 nil #'emacos--commit))
      (emacos--refocus))))

(defun emacos--double-space-p (now)
  "Non-nil if a SPC tap at time NOW (a `float-time') should become \". \".
True when the previous SPC tap was within `emacos--double-space-threshold'
AND the char before the just-inserted space is alphanumeric — so the
mobile period gesture fires after a word, never after punctuation, after
another space, or at line start (which would double-period or misplace a
period).  Reads point in the current buffer; pure given that + NOW."
  (and emacos--last-space-time
       (<= (- now emacos--last-space-time) emacos--double-space-threshold)
       (> (point) (1+ (point-min)))
       (eq (char-before) ?\s)
       (let ((c (char-before (1- (point)))))
         (and c (string-match-p "[[:alnum:]]" (string c))))))

(defun emacos--tap-space ()
  "Insert a space.  Two SPC taps in quick succession after a word turn the
just-typed space into \". \" — the familiar mobile period shortcut (see
`emacos--double-space-p' for exactly when it fires)."
  (emacos--commit)
  (let ((w (emacos--target))
        (now (float-time)))
    (when w
      (with-selected-window w
        (if (emacos--double-space-p now)
            (progn
              (delete-char -1)
              (insert ". ")
              ;; Consume the gesture so a third rapid tap doesn't re-fire
              ;; off the period+space we just wrote.
              (setq emacos--last-space-time nil))
          (insert " ")
          (setq emacos--last-space-time now)))
      (emacos--refocus))))

(defun emacos--tap-return ()
  "Insert a newline, or exit the minibuffer when it is active."
  (emacos--commit)
  (let ((w (emacos--target)))
    (when w
      (if (active-minibuffer-window)
          (with-selected-window w (exit-minibuffer))
        (with-selected-window w (newline))
        (emacos--refocus)))))

(defun emacos--tap-backspace ()
  "Delete one character backward."
  (emacos--cancel-timer)
  (setq emacos--current-key nil emacos--tap-index 0)
  (let ((w (emacos--target)))
    (when w
      (with-selected-window w
        (when (> (point) (point-min))
          (delete-char -1)))
      (emacos--refocus))))

(defun emacos--tap-caps ()
  "Toggle caps lock and re-render the keyboard."
  (setq emacos--caps (not emacos--caps))
  (emacos--render-page)
  (emacos--refocus))

(defun emacos--tap-tab ()
  "Context-aware TAB: complete in the minibuffer, else indent.
Mirrors the minibuffer special-case in `emacos--tap-return'.  Uses
`call-interactively' so the underlying commands read their own
context (region, `this-command', `tab-always-indent', etc.)."
  (emacos--commit)
  (let ((w (emacos--target)))
    (when w
      (if (active-minibuffer-window)
          (with-selected-window w (call-interactively #'minibuffer-complete))
        (with-selected-window w (call-interactively #'indent-for-tab-command))
        (emacos--refocus)))))

(defun emacos--tap-quit ()
  "Smart escape: clear whatever is cluttering the TOP area in one tap —
a stuck minibuffer, a *Help*/*Completions*/special-mode popup, extra
split windows — WITHOUT touching the keyboard.

- Active minibuffer → `abort-recursive-edit'.  This throws back to the
  minibuffer's recursive edit (which restores focus itself), so the
  code below is intentionally unreachable on that branch — do NOT move
  a re-render above the `if'.  We use it rather than `keyboard-quit'
  precisely because the latter signals `quit' out of this button
  callback and would skip the rest of the handler.
- Otherwise, in the editing window: a help-like buffer that took OVER
  the window is dismissed with `quit-window' (its `q' action), then
  `delete-other-windows' collapses any popup SPLITS.  The keyboard
  window survives because `emacos--init' gives it the
  `no-delete-other-windows' parameter.  `delete-other-windows' is the
  workhorse (handles popups-in-splits regardless of mode); `quit-window'
  only matters when the clutter took over the target window itself.
  *Completions* is `completion-list-mode', whose parent is nil in Emacs
  30, so it's checked explicitly alongside `special-mode'.

NOTE: window/popup-focused (the actual overload).  Does NOT cancel a
non-recursive pending state (isearch, an active region, a prefix arg) —
out of scope for v1."
  (emacos--commit)
  (if (active-minibuffer-window)
      (abort-recursive-edit)
    (let* ((w (emacos--target))
           (buf (and w (window-buffer w)))
           ;; Decide BEFORE selecting the window so the mode check reads
           ;; the top buffer explicitly (and stays unit-testable).
           (clutter (and buf
                         (with-current-buffer buf
                           (or (derived-mode-p 'special-mode)
                               (eq major-mode 'completion-list-mode))))))
      (when w
        (with-selected-window w
          (when clutter (quit-window))
          (delete-other-windows))
        (emacos--render-page)
        (emacos--refocus)))))

;;; Rendering helpers

(defconst emacos--btn-label-scale 0.8
  "Font :height for a keyboard button's LABEL (not its tap-target size).
Drives two things that must agree: the glyph size of the label, and the
per-row width budget (`emacos--unit-width' divides by this).  Kept below
1.0 so the longest T9 group (\"ertyui\", 6 chars) fits in a group's cell
budget instead of truncating to \"ert\" — at 0.8 the budget is ~7 cells
wide at the phone's ~20-col keyboard.

Decoupled from button HEIGHT on purpose: a text button is otherwise only
as tall as its glyphs, so a label small enough to fit would also shrink
the tap target.  `emacos--btn-vpad' adds the height back via box padding,
so the label can be small AND the button big.")

(defconst emacos--btn-vpad 8
  "Vertical box padding (pixels) added top+bottom to every keyboard button.
This is the button-HEIGHT knob, decoupled from `emacos--btn-label-scale'
\(the font size): it pads the tap target taller without enlarging the
glyphs.  Maps to the HWIDTH (top/bottom) element of the face `:box'
`:line-width' — vertical only, so it never widens a button and can't push
a row past the window edge (which would wrap the keyboard).")

(defconst emacos--btn-hpad 1
  "Horizontal box padding (pixels) on a keyboard button's left+right edges.
Kept small: unlike `emacos--btn-vpad', horizontal padding adds width the
per-row cell math (`emacos--unit-width') doesn't account for, so a large
value would overflow the ~20-col row and wrap the keyboard.  Maps to the
VWIDTH (left/right) element of the face `:box' `:line-width'.")

(defconst emacos--btn-gap 1.5
  "Visual width (in character cells) of the gap between buttons in a row.")

(defun emacos--center (text width)
  "Center TEXT in a field of WIDTH characters."
  (let* ((len (string-width text))
         (pad (max 0 (- width len)))
         (l (/ pad 2))
         (r (- pad l)))
    (concat (make-string l ?\s) text (make-string r ?\s))))

(defun emacos--unit-width (win-w gap-w units gaps)
  "Character width of ONE layout unit for a row spanning UNITS unit-widths
\(scaled by `emacos--btn-label-scale') and GAPS inter-button gaps across WIN-W
columns.  A button may span more than one unit (e.g. a double-wide RET is
2 units), so UNITS and the button count can differ.  Floored, min 1 so a
pathologically narrow window can't drive a width <= 0 (which would crash
the letter-key `substring').  Pure — testable off the device."
  (max 1 (floor (/ (- win-w (* gaps gap-w)) (* units emacos--btn-label-scale)))))

(defun emacos--key-display (kg)
  "Format key group KG for display."
  (let ((s (if emacos--caps (upcase kg) kg)))
    s))

(defun emacos--maybe-cancel-confirm (action arg)
  "Cancel a pending New-chat confirmation when ANY button other than the
New-chat command itself is tapped, so the armed \"Confirm clear?\" state
can't linger (the two-tap design in `emacos--chat-new-chat').  Command-list
buttons run their command through `emacos--run-command' (the command is
ARG), so the New-chat command is the (`emacos--run-command' . `emacos--chat-new-chat')
pair; every other tap disarms and re-renders.  No-op when nothing is
armed, which is the common case."
  (when (and (bound-and-true-p emacos--chat-confirm-pending)
             (not (and (eq action #'emacos--run-command)
                       (eq arg #'emacos--chat-new-chat))))
    (setq emacos--chat-confirm-pending nil)
    (emacos--render-page)))

(defun emacos--btn (label action &optional arg height bg)
  "Insert a clickable button showing LABEL that calls ACTION (with ARG).
HEIGHT, if given, is a face :height float for the LABEL font (callers
pass `emacos--btn-label-scale').  The button's tap-target HEIGHT is
separate: it comes from the `:box' vertical padding (`emacos--btn-vpad'),
so a small label still gets a big button.  BG, if given, overrides the
default gray background — used to accent a high-priority affordance (the
Chat button) so it reads as the app, not plumbing."
  (insert-text-button
   label
   ;; Every tap first cancels any pending two-tap confirm (unless it IS the
   ;; armed command) — see `emacos--maybe-cancel-confirm' — then runs ACTION.
   'action (lambda (_)
             (emacos--maybe-cancel-confirm action arg)
             (if arg (funcall action arg) (funcall action)))
   'follow-link t
   'face `(:box (:line-width (,emacos--btn-hpad . ,emacos--btn-vpad)
                 :style released-button)
           :background ,(or bg "gray25") :foreground "white"
           ,@(when height `(:height ,height)))
   'mouse-face `(:box (:line-width (,emacos--btn-hpad . ,emacos--btn-vpad)
                       :style pressed-button)
                 :background "gray45" :foreground "white")))

;;; Command execution

(defun emacos--run-command (cmd)
  "Run CMD interactively in the target (editing) window, then refresh.
The keyboard surface is always shown, so unlike the old swap model
there is no page to force/restore.  Re-render only when CMD actually
changed the command set: an in-place `M-x <mode>' won't fire
`window-buffer-change-functions', so the follower can't catch it — but
a CMD that swaps the top buffer DOES fire the hook, so rendering here
unconditionally would render twice (and flicker).  Comparing against
`emacos--last-commands' covers the in-place case, leaves buffer swaps
to the follower, and skips the render entirely when nothing changed.
`unwind-protect' keeps the refresh+refocus even when CMD throws (a bad
find-file path, a user-error, an aborted kill-buffer query)."
  (let ((w (emacos--target)))
    (when w
      (unwind-protect
          (with-selected-window w
            (call-interactively cmd))
        (unless (equal (emacos--top-commands) emacos--last-commands)
          (emacos--render-page))
        (emacos--refocus)))))

;;; Mode-specific commands

(defvar emacos-mode-commands
  '((org-mode
     ("Heading" . org-insert-heading)
     ("TODO"    . org-todo)
     ("Export"  . org-export-dispatch))
    (emacs-lisp-mode
     ("Eval Buffer"    . eval-buffer)
     ("Eval Last Sexp" . eval-last-sexp))
    (dired-mode
     ("Open"   . dired-find-file)
     ("Up"     . dired-up-directory)
     ("Rename" . dired-do-rename)
     ("Copy"   . dired-do-copy)
     ("Delete" . dired-do-delete)
     ("Refresh" . revert-buffer))
    (magit-status-mode
     ("Stage"   . magit-stage)
     ("Unstage" . magit-unstage)
     ("Commit"  . magit-commit-create)
     ("Push"    . magit-push)
     ("Pull"    . magit-pull)
     ("Fetch"   . magit-fetch)
     ("Branch"  . magit-branch)
     ("Log"     . magit-log)
     ("Diff"    . magit-diff)
     ("Refresh" . magit-refresh))
    ;; prog-mode is a common ancestor: code buffers without their own
    ;; entry walk up to here.  Indent is intentionally omitted — the
    ;; keyboard's TAB button already runs `indent-for-tab-command'.
    (prog-mode
     ("Save"       . save-buffer)
     ("Comment"    . comment-line)
     ("Goto Line"  . goto-line)
     ("Search"     . isearch-forward)
     ("Replace"    . query-replace)
     ("Next Error" . next-error)
     ("Xref Def"   . xref-find-definitions))
    (text-mode
     ("Save"      . save-buffer)
     ("Search"    . isearch-forward)
     ("Replace"   . query-replace)
     ("Spell"     . ispell-buffer)
     ("Fill"      . fill-paragraph)
     ("Goto Line" . goto-line)))
  "Alist mapping major modes to lists of (LABEL . COMMAND) pairs.
Command-centric modes (where the user invokes commands more than they
type) belong here.  A mode absent from this alist falls back to
`emacos-global-commands' in the command list (see `emacos--top-commands').
Order each list by PRIORITY: the command list shows up to
`emacos--max-commands' (earlier = kept), one per row; the rest are
reachable via M-x.  Grow this incrementally.")

(defvar emacos-global-commands
  '(("Save"          . save-buffer)
    ("Undo"          . undo)
    ("Find File"     . find-file)
    ("Switch Buffer" . switch-to-buffer))
  "Command-list fallback for buffers whose major mode has no entry in
`emacos-mode-commands'.  Keeps the universal actions (save, undo, open,
switch) one tap away on a T9 keyboard, where `M-x find-file RET' is
~20 multi-taps.  Ordered by priority (the list shows up to
`emacos--max-commands').")

(defun emacos--mode-commands-for (mode)
  "Return the command list for MODE, walking up parent modes."
  (let ((m mode) result)
    (while (and m (not result))
      (setq result (cdr (assq m emacos-mode-commands)))
      (setq m (get m 'derived-mode-parent)))
    result))

;;; Top-buffer command set (feeds the command list)

;; Defined in chat.el (required at the bottom of this file).  Forward-
;; declared so the byte-compiler doesn't warn about the free variable /
;; unknown functions in `emacos--top-commands' and the utility row;
;; resolved at call time, after the require.
(defvar emacos--chat-buffer-name)
(declare-function emacos--chat-command-set "chat")
(declare-function emacos--chat-show-top-buffer "chat")
(declare-function emacos--chat-button "chat")
(declare-function emacos--chat-button-label "chat")

(defun emacos--top-commands ()
  "Return the command list ((LABEL . CMD) ...) for the TOP (editing)
buffer — the contents of the command list band.  One `cond':
an active minibuffer → nil (you're typing into a prompt; the list
stays empty); the *chat* buffer (by identity) →
`emacos--chat-command-set'; a major mode with a command set →
`emacos--mode-commands-for'; everything else → `emacos-global-commands'
so a plain text buffer still has Save/Undo/Find File one tap away
rather than only M-x."
  (cond
   ((active-minibuffer-window) nil)
   (t
    (let* ((target (emacos--target))
           (buf (and target (window-buffer target)))
           (mode (if buf (buffer-local-value 'major-mode buf)
                   'fundamental-mode)))
      (cond
       ((and buf (eq buf (get-buffer emacos--chat-buffer-name)))
        (emacos--chat-command-set))
       ((emacos--mode-commands-for mode))
       (t emacos-global-commands))))))

(defun emacos--on-window-buffer-change (_frame)
  "Re-render when the top buffer changes the command set.
Registered on `window-buffer-change-functions'.  No-ops while a render
is in progress (the `emacos--in-render' re-entry guard) and when the
derived command set is unchanged — so transient buffers (*Completions*,
*Help*) don't flicker the command list.  The keyboard itself never
moves; only the command-list band could change."
  (unless (or emacos--in-render
              (equal (emacos--top-commands) emacos--last-commands))
    (emacos--render-page)))

;;; Surface renderers (the four bands of the composite)
;;
;; All buttons share the same label font (`emacos--btn-label-scale') and
;; the same tap-target height (`emacos--btn-vpad' box padding); the
;; keyboard window scrolls, so bands stack as tall as they need.

(defun emacos--render-keyboard ()
  "Render the Optimal-T9 letter rows (3 rows of key groups) sized to fit
the keyboard window.  The action keys, utility row, and command list are
separate bands — see `emacos--render-page'."
  (let* ((win   (get-buffer-window (current-buffer)))
         (win-w (if win (window-body-width win) 20))
         (gap-w emacos--btn-gap)
         ;; 3 key groups per row, 2 gaps between them.
         (btn-w (emacos--unit-width win-w gap-w 3 2)))
    (dolist (row emacos-t9-layout)
      (let ((i 0))
        (dolist (kg row)
          (when (> i 0)
            (insert " ")
            (put-text-property (1- (point)) (point)
                               'display `(space :width ,gap-w)))
          (let* ((s (emacos--key-display kg))
                 (s (substring s 0 (min (length s) btn-w))))
            (emacos--btn (emacos--center s btn-w) #'emacos--tap-key kg
                         emacos--btn-label-scale))
          (setq i (1+ i))))
      (insert "\n"))))

(defun emacos--render-action-row ()
  "Render the editing keys across two rows: DEL (one letter-key width) +
SPC (the rest of the row) on one row, then CAPS / TAB / RET with RET
DOUBLE-WIDE."
  (let* ((win   (get-buffer-window (current-buffer)))
         (win-w (if win (window-body-width win) 20))
         (gap-w emacos--btn-gap)
         ;; DEL is one letter-key width (1/3, matching the keyboard groups).
         (third (emacos--unit-width win-w gap-w 3 1))
         ;; SPC fills the REST of the row: total button-cell budget (1 gap)
         ;; minus DEL — so the spacebar reads as the wide primary key and no
         ;; slack is left at the right edge.
         (spc   (- (emacos--unit-width win-w gap-w 1 1) third))
         ;; CAPS(1) + TAB(1) + RET(2) = 4 units, 2 gaps.
         (unit  (emacos--unit-width win-w gap-w 4 2)))
    ;; Row: DEL (left, letter-key width), SPC (right, fills the rest).
    (emacos--btn (emacos--center "DEL" third) #'emacos--tap-backspace nil
                 emacos--btn-label-scale)
    (insert " ")
    (put-text-property (1- (point)) (point) 'display `(space :width ,gap-w))
    (emacos--btn (emacos--center "SPC" spc) #'emacos--tap-space nil
                 emacos--btn-label-scale)
    (insert "\n")
    ;; Row: CAPS, TAB, RET (RET double-wide).  CAPS sits where DEL was.
    (emacos--btn (emacos--center (if emacos--caps "CAPS" "caps") unit)
                 #'emacos--tap-caps nil emacos--btn-label-scale)
    (insert " ")
    (put-text-property (1- (point)) (point) 'display `(space :width ,gap-w))
    (emacos--btn (emacos--center "TAB" unit) #'emacos--tap-tab nil
                 emacos--btn-label-scale)
    (insert " ")
    (put-text-property (1- (point)) (point) 'display `(space :width ,gap-w))
    (emacos--btn (emacos--center "RET" (* 2 unit)) #'emacos--tap-return nil
                 emacos--btn-label-scale)
    (insert "\n")))

(defun emacos--render-utility-row ()
  "Render the persistent utility row: QUIT, M-x, Chat/SEND (3-up).
`QUIT' (`emacos--tap-quit') clears popup/minibuffer clutter off the top;
`M-x' runs `execute-extended-command' (manual command entry); the third
button (`emacos--chat-button', accent face) opens the *chat* home app
when chat isn't on top and SENDS the input when it is — its label flips
between \"Chat\" and \"SEND\" accordingly.  CAPS lives on the action row
(`emacos--render-action-row')."
  (let* ((win   (get-buffer-window (current-buffer)))
         (win-w (if win (window-body-width win) 20))
         (gap-w emacos--btn-gap)
         (util-w (emacos--unit-width win-w gap-w 3 2)))
    (emacos--btn (emacos--center "QUIT" util-w) #'emacos--tap-quit nil
                 emacos--btn-label-scale)
    (insert " ")
    (put-text-property (1- (point)) (point) 'display `(space :width ,gap-w))
    (emacos--btn (emacos--center "M-x" util-w)
                 #'emacos--run-command #'execute-extended-command
                 emacos--btn-label-scale)
    (insert " ")
    (put-text-property (1- (point)) (point) 'display `(space :width ,gap-w))
    (emacos--btn (emacos--center (emacos--chat-button-label) util-w)
                 #'emacos--run-command #'emacos--chat-button
                 emacos--btn-label-scale "dodger blue")
    (insert "\n")))

;; Cap on the command list.  No mode currently has this many; it's a
;; bound so a future over-long set can't run the (scrollable but finite)
;; keyboard off the bottom.
(defconst emacos--max-commands 10)

(defun emacos--render-commands ()
  "Render up to `emacos--max-commands' of the top buffer's commands, ONE
PER ROW as same-height buttons (the keyboard window scrolls, so this can
run past the fold).  Caches the FULL derived set in `emacos--last-commands'
so the follower can no-op when the set is unchanged."
  (let ((commands (emacos--top-commands)))
    (setq emacos--last-commands commands)
    (dolist (entry (seq-take commands emacos--max-commands))
      (emacos--btn (concat " " (car entry) " ") #'emacos--run-command
                   (cdr entry) emacos--btn-label-scale)
      (insert "\n"))))

;;; Render dispatch

(defun emacos--render-page ()
  "Render the *keyboard* window: the always-on composite of the T9
keyboard, the action row, the utility row, and the top-buffer command
list.  Binds `emacos--in-render' for the duration so the
window-buffer-change follower can't recurse into an in-progress render."
  (let ((buf (get-buffer-create "*keyboard*"))
        (emacos--in-render t))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (emacos--render-keyboard)
        (emacos--render-action-row)
        (emacos--render-utility-row)
        (emacos--render-commands))
      (setq buffer-read-only t)
      (setq-local cursor-type nil)
      (setq-local mode-line-format nil)
      (setq-local truncate-lines t)
      (setq-local auto-hscroll-mode nil)
      (setq-local line-spacing 0)
      ;; Only reset hscroll when *keyboard* is actually displayed.
      ;; The load-time follower can reach render before the keyboard
      ;; window exists (eg. a buffer change between os.el load and
      ;; `emacos--init' creating the split), where `get-buffer-window'
      ;; is nil and `set-window-hscroll' would error.
      (when-let ((kw (get-buffer-window buf)))
        (set-window-hscroll kw 0))
      (goto-char (point-min)))))

;;; Initialization

(defun emacos--init ()
  "Set up the EmacsOS environment."
  (set-frame-name "EmacsOS")
  ;; Main editing buffer
  (switch-to-buffer (get-buffer-create "*scratch*"))
  (setq-local mode-line-format " EmacsOS")
  ;; Split: top = editor, bottom = keyboard
  (let* ((total (window-total-height))
         (kbd-height (/ (* total 3) 4))
         (kw (split-window nil (- total kbd-height) 'below)))
    (set-window-buffer kw (get-buffer-create "*keyboard*"))
    (set-window-dedicated-p kw t)
    (set-window-parameter kw 'no-other-window t)
    (set-window-parameter kw 'no-delete-other-windows t)
    (setq emacos--target-window (selected-window)))
  ;; Render after the window is visible so dimensions are known.  The
  ;; command list derives from the top buffer at render time, and the
  ;; follower hook (registered at load time, below) keeps it in sync.
  (emacos--render-page))

;; Defer init until the window system is ready
(add-hook 'window-setup-hook #'emacos--init)

;; Register the auto-follow hook at load time (not inside `emacos--init')
;; so a hot-reload of os.el — the agent-driven-customization workflow —
;; keeps the follower active without a full restart.  `add-hook'
;; de-dupes, so re-loading doesn't double-register.
(add-hook 'window-buffer-change-functions #'emacos--on-window-buffer-change)

;; Companion modules live alongside os.el; add this file's dir to
;; load-path so `(require 'chat)` works regardless of cwd.
(add-to-list 'load-path
             (file-name-directory (or load-file-name buffer-file-name)))
(require 'chat)

(provide 'os)
;;; os.el ends here
