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

;; Global, minimal modeline: the EmacsOS label + a tappable cell/wifi
;; status segment (`emacos-net-mode-line-string', network.el), shown on
;; every top (editing) buffer.  Replaces the stock clutter (buffer
;; position, minor modes, encoding); the *keyboard* buffer overrides this
;; to nil on each render (`emacos--render-page').  time/date/battery are
;; left for the "Modeline status bar" roadmap item to append here.  Set at
;; load time (not in `emacos--init') so a hot-reload re-applies it.  The
;; `:eval' resolves the network function at redisplay, after the
;; `(require 'network)' at the bottom of this file.
(setq-default mode-line-format
              '(" EmacsOS  " (:eval (emacos-net-mode-line-string))))

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
  "Optimal-T9 letter layout.  Each key group is a string of letters.")

(defvar emacos-123-layout
  '(("1" "2" "3")
    ("4" "5" "6")
    ("7" "8" "90"))
  "Numbers layer.  Digits 1-8 are single-tap; 9 and 0 share the last key.")

(defvar emacos-symbols-layout
  '((".:/" ",;\"" "?!'")
    ("@#&" "-_~"  "+*=")
    ("()%" "[]$"  "{}|"))
  "Symbols layer.  Multi-tap reaches the rarer symbols in a group.")

(defvar emacos--kbd-mode 'lower
  "Active keyboard mode, cycled by the CAPS button:
`lower' (abc) -> `caps' (ABC) -> `number' (123) -> `symbol' (#+=) -> loop.
Replaces the old caps boolean: `caps' is the uppercase-letters state.")

(defun emacos--active-layout ()
  "The key-group layout for the current `emacos--kbd-mode'.
`lower' and `caps' both type letters; `number'/`symbol' swap the grid."
  (pcase emacos--kbd-mode
    ('number emacos-123-layout)
    ('symbol emacos-symbols-layout)
    (_       emacos-t9-layout)))

;; Multi-tap state
(defvar emacos--target-window nil)
(defvar emacos--current-key nil)
(defvar emacos--tap-index 0)
(defvar emacos--commit-timer nil)

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

;; Modifier-key state.  See docs/2026-05-27-modifier-keys.org.
(defvar emacos--modifier nil
  "Active modifier for the next bound-command tap.
Value is one of nil, the symbol C, M, or C-M.  Sticky across
keystrokes — only an explicit MOD-button tap changes it.")

(defvar emacos--armed-tap nil
  "When non-nil, a plist `(:group SUBSET :index N :window W :buffer B)`
naming a binding ARMED under `emacos--modifier' but not yet committed.
Set by `emacos--tap-modified-key' (multi-letter subset path); cleared by
`emacos--commit-armed-tap' (fires) or `emacos--abandon-armed-tap' (clears
without firing — QUIT's path).  The 1.0s `emacos--armed-tap-timer'
commits if nothing else does first.")

(defvar emacos--armed-tap-timer nil
  "Timer that fires `emacos--commit-armed-tap' after 1.0s of inactivity.
Mirrors `emacos--commit-timer' for the bound-command path; cancelled by
any commit / abandon.")

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
  "Return CH as a string, upcased only in `caps' mode.
A no-op for digits/symbols (upcase leaves them unchanged)."
  (funcall (if (eq emacos--kbd-mode 'caps) #'upcase #'identity)
           (char-to-string ch)))

;;; Modifier-key state + filter (see docs/2026-05-27-modifier-keys.org).
;;
;; The MOD button cycles the modifier state; under a non-nil modifier,
;; letter-key taps fire a *bound command* instead of inserting a letter.
;; The grid filters to letters that have a binding under the current
;; modifier in the target buffer's full active-keymap stack.

(defun emacos--modifier-prefix (mod)
  "Elisp key-sequence prefix for MOD.
nil maps to the empty string; the symbols C, M, C-M map to \"C-\",
\"M-\", \"C-M-\" respectively."
  (pcase mod
    ('nil "") ('C "C-") ('M "M-") ('C-M "C-M-")))

(defun emacos--modifier-next (mod)
  "Cycle MOD one step: nil → C → M → C-M → nil."
  (pcase mod
    ('nil 'C) ('C 'M) ('M 'C-M) ('C-M nil)))

(defun emacos--letter-bound-p (ch modifier buf)
  "Non-nil iff MODIFIER + CH is bound to a command in BUF's active keymaps
at point.  `key-binding' consults the full active-keymap stack
(overriding → emulation → minor → major → text-property/overlay at
point → global), so text-property and overlay keymap properties are
respected as the user expects.  `commandp' filters out prefix keys
(e.g. `Control-X-prefix', whose function-value is a keymap)."
  (with-current-buffer buf
    (let* ((kseq (kbd (concat (emacos--modifier-prefix modifier)
                              (char-to-string ch))))
           (binding (key-binding kseq t)))
      (and binding (commandp binding)))))

(defun emacos--bound-letters-in-group (kg modifier buf)
  "Return the letters of group KG that are bound under MODIFIER in BUF,
in original order.  Empty string when none."
  (apply #'string
         (seq-filter (lambda (ch)
                       (emacos--letter-bound-p ch modifier buf))
                     kg)))

(defun emacos--bound-groups (modifier buf)
  "Return the ACTIVE layout filtered to bound-char subsets under MODIFIER
in BUF (so MOD works over letters, digits, or symbols — whatever layer is
showing).  Same shape as the layout; empty groups stay positional as
empty strings (not removed) so the grid doesn't reflow."
  (mapcar (lambda (row)
            (mapcar (lambda (kg)
                      (emacos--bound-letters-in-group kg modifier buf))
                    row))
          (emacos--active-layout)))

(defun emacos--cancel-armed-tap-timer ()
  "Cancel the armed-tap timer if it's running."
  (when (timerp emacos--armed-tap-timer)
    (cancel-timer emacos--armed-tap-timer)
    (setq emacos--armed-tap-timer nil)))

(defun emacos--abandon-armed-tap ()
  "Clear `emacos--armed-tap' WITHOUT firing it.  QUIT's path; also used
internally when arm-time validation fails (dead window/buffer).  When
state actually cleared, re-renders so the armed-letter preview goes away
(no other path is guaranteed to render after an abandon — notably QUIT
in the active-minibuffer branch which `throws' before its own render)."
  (let ((had-state emacos--armed-tap))
    (emacos--cancel-armed-tap-timer)
    (setq emacos--armed-tap nil)
    (when had-state (emacos--render-page))))

(defun emacos--commit-armed-tap ()
  "Fire the armed binding (if any) in its captured window/buffer; clear
state.  Silent no-op when nothing is armed.  D3 validation: silent
abandon if the captured window/buffer no longer exists or the window has
re-pointed at a different buffer.  Race-safe: also a silent no-op when
the binding has evaporated since arm time (a minor mode disabled, a
keymap mutated).

Dispatches via the CAPTURED window — not `emacos--run-command' which
would re-derive target via `emacos--target' and prefer any minibuffer
that happened to pop up between arm and the 1s timer fire.  D3 is the
whole point of capturing :window at arm time; honor it at fire time."
  (let ((armed emacos--armed-tap))
    ;; Clear FIRST so a re-entrant fire (the command itself triggers a
    ;; render/follower that calls back into a commit path) can't loop.
    ;; abandon-armed-tap also re-renders, clearing the armed highlight.
    (emacos--abandon-armed-tap)
    (when armed
      (let* ((w (plist-get armed :window))
             (b (plist-get armed :buffer))
             (subset (plist-get armed :group))
             (i (plist-get armed :index)))
        (when (and (window-live-p w)
                   (buffer-live-p b)
                   (eq (window-buffer w) b)
                   (< i (length subset)))
          (let* ((ch (aref subset i))
                 (kseq (kbd (concat (emacos--modifier-prefix emacos--modifier)
                                    (char-to-string ch))))
                 ;; Look up in the captured buffer (not the current one).
                 (binding (with-current-buffer b (key-binding kseq t))))
            (when (and binding (commandp binding))
              (unwind-protect
                  (with-selected-window w
                    (call-interactively binding))
                ;; Mirror emacos--run-command's post-action refresh:
                ;; re-render when the command-set changed (the follower
                ;; on a top-buffer swap will do its own render).
                (unless (equal (emacos--top-commands) emacos--last-commands)
                  (emacos--render-page))
                (emacos--refocus)))))))))

;;; Key actions

(defun emacos--tap-key (kg)
  "Handle a tap on key group KG.
Under an active modifier (`emacos--modifier' non-nil), routes to
`emacos--tap-modified-key' (fires a bound command).  Otherwise,
multi-tap cycles through letters for insertion."
  (if emacos--modifier
      (emacos--tap-modified-key kg)
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
        (emacos--refocus)))))

(defun emacos--tap-modified-key (kg)
  "Tap KG under an active modifier — fires a bound command instead of
inserting a letter.  Three paths by bound-subset size:

- Empty subset (no letter in KG is bound under the current modifier):
  silent no-op.
- Single-letter subset: fire immediately (the single-letter fast-path —
  the visible grid tells the user a tap fires, not cycles).
- Multi-letter subset: arm-then-commit.  First tap arms; same-key
  re-tap cycles within the bound subset; commit fires on the 1.0s
  timer, a different-group tap, a MOD tap (A2), or any utility tap
  EXCEPT QUIT (A3 — QUIT abandons).  See
  docs/2026-05-27-modifier-keys.org."
  (let* ((w (emacos--target))
         (buf (and w (window-buffer w)))
         (subset (and buf (emacos--bound-letters-in-group
                           kg emacos--modifier buf))))
    (cond
     ;; Empty subset: silent no-op (no fire, no arm).
     ((or (null subset) (string-empty-p subset))
      nil)
     ;; Single-letter fast-path: fire immediately.  `emacos--run-command'
     ;; tops with `emacos--commit-armed-tap', which fires any prior arm
     ;; (different-group/different-letter semantics) and re-renders the
     ;; stale armed highlight away — no need for an explicit commit here.
     ((= (length subset) 1)
      (let* ((ch (aref subset 0))
             (kseq (kbd (concat (emacos--modifier-prefix emacos--modifier)
                                (char-to-string ch))))
             (binding (with-current-buffer buf (key-binding kseq t))))
        (when (and binding (commandp binding))
          (emacos--run-command binding))))
     ;; Multi-letter subset: arm-then-commit cycle.
     (t
      (let ((armed emacos--armed-tap))
        (if (and armed
                 (equal (plist-get armed :group) subset)
                 (eq (plist-get armed :window) w))
            ;; Same group: cycle within the bound subset.  `plist-put'
            ;; mutates the cons spine in place and returns the same head;
            ;; the setq is for documentation, not aliasing.
            (plist-put armed :index
                       (mod (1+ (plist-get armed :index)) (length subset)))
          ;; Different group (or first arm): commit any prior, arm new.
          (emacos--commit-armed-tap)
          (setq emacos--armed-tap
                (list :group subset :index 0 :window w :buffer buf)))
        (emacos--cancel-armed-tap-timer)
        (setq emacos--armed-tap-timer
              (run-with-timer 1.0 nil #'emacos--commit-armed-tap))
        (emacos--render-page)
        (emacos--refocus))))))

(defun emacos--tap-modifier ()
  "Action handler for the MOD button.
A2: when a binding is armed, COMMITS it before advancing the modifier.
Sticky modifier survives that commit (A1) — the cycle still steps once."
  (emacos--commit)              ; commit any in-flight multi-tap letter
  (emacos--commit-armed-tap)    ; A2: commit armed binding (no-op if nil)
  (setq emacos--modifier (emacos--modifier-next emacos--modifier))
  (emacos--render-page)
  (emacos--refocus))

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
  (emacos--commit-armed-tap)         ; A3: utility tap commits armed.
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
  (emacos--commit-armed-tap)         ; A3: utility tap commits armed.
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
  (emacos--commit-armed-tap)         ; A3: utility tap commits armed.
  (let ((w (emacos--target)))
    (when w
      (with-selected-window w
        (when (> (point) (point-min))
          (delete-char -1)))
      (emacos--refocus))))

(defun emacos--tap-cycle-mode ()
  "Cycle the keyboard mode: lower -> caps -> number -> symbol -> lower.
One button does shift + layer.  A MOD modifier stays active across the
cycle (it then filters whatever layer now shows); like other utility taps,
any in-flight multi-tap character and pending armed binding commit first."
  (emacos--commit)                 ; finalize any in-flight multi-tap character
  (emacos--commit-armed-tap)       ; utility tap commits an armed binding
  (setq emacos--kbd-mode
        (pcase emacos--kbd-mode
          ('lower 'caps) ('caps 'number) ('number 'symbol) (_ 'lower)))
  (emacos--render-page)
  (emacos--refocus))

(defun emacos--tap-tab ()
  "Context-aware TAB: complete in the minibuffer, else indent.
Mirrors the minibuffer special-case in `emacos--tap-return'.  Uses
`call-interactively' so the underlying commands read their own
context (region, `this-command', `tab-always-indent', etc.)."
  (emacos--commit)
  (emacos--commit-armed-tap)         ; A3: utility tap commits armed.
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
out of scope for v1.

QUIT is the phone's `C-g'.  Decision A3: when an armed-tap is in
flight under a modifier, QUIT ABANDONS it (does NOT fire) — every
other utility tap commits, but QUIT must be a true escape."
  (emacos--commit)
  (emacos--abandon-armed-tap)        ; A3: QUIT abandons, never commits.
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
  (let ((s (if (eq emacos--kbd-mode 'caps) (upcase kg) kg)))
    s))

(defvar emacos--confirm-disarm-functions nil
  "Abnormal hook of disarm functions for two-tap-confirm features.
Each registered function receives (ACTION ARG) — the button being
tapped (ARG is the command, ACTION is usually `emacos--run-command').
Each disarm-fn should clear its own pending-armed state and re-render,
UNLESS the (ACTION ARG) pair IS the armed command itself (in which
case the user is performing the confirming second tap and arming must
persist into that handler's check).

The phone touchscreen can't tap modal y-or-n-p / GUI dialogs, so every
destructive command instead uses the in-row two-tap pattern: first tap
arms (relabels its button to \"Confirm X?\"), second tap fires.  Any
other button tap cancels the pending arm via this hook — so the armed
state can't linger across unrelated interactions.  Add a disarm-fn from
the feature's own file (chat.el for New-chat, emacos-assist.el for
Forget, etc.); the shared disarm rail keeps os.el out of the loop.")

(defun emacos--maybe-cancel-confirm (action arg)
  "Run `emacos--confirm-disarm-functions' with the tapped (ACTION ARG).
Each registered disarm-fn decides whether the current tap matches its
armed command (= confirming second tap, keep armed) or not (disarm).
No-op when nothing is armed, which is the common case."
  (run-hook-with-args 'emacos--confirm-disarm-functions action arg))

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
find-file path, a user-error, an aborted kill-buffer query).

A3: M-x and command-list buttons commit any armed-tap first.  Safe
under re-entrancy: `emacos--commit-armed-tap' clears armed-tap BEFORE
firing, so the inner `emacos--run-command' (for the armed binding) hits
a no-op commit at its own top."
  (emacos--commit-armed-tap)
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
    ("Switch Buffer" . switch-to-buffer)
    ("Net"           . emacos-net-show))
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
(declare-function emacos-assist--command-set "emacos-assist")

;; Defined in network.el (required at the bottom of this file).
(defvar emacos-net--buffer-name)
(declare-function emacos-net--command-set "network")
(declare-function emacos-net-mode-line-string "network")
(declare-function emacos-net-show "network")
(declare-function emacos-net--ensure-timer "network")
(declare-function emacos-net--refresh "network")

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
       ((and buf (with-current-buffer buf
                   (derived-mode-p 'emacos-assist-mode)))
        ;; Run `emacos-assist--command-set' INSIDE the .assist buffer:
        ;; it reads `emacos-assist--forget-confirm-pending', which is
        ;; buffer-local to each .assist file (a "Confirm forget?" arm
        ;; on one .assist file mustn't bleed into another's command list).
        ;; The render call site has the *keyboard* buffer as
        ;; `current-buffer', so without this wrap the buffer-local read
        ;; sees nil and "Forget" never relabels — caught live 2026-05-30.
        (with-current-buffer buf (emacos-assist--command-set)))
       ((and buf (eq buf (get-buffer emacos-net--buffer-name)))
        (emacos-net--command-set))
       ((emacos--mode-commands-for mode))
       (t emacos-global-commands))))))

(defun emacos--on-window-buffer-change (_frame)
  "Re-render when the top buffer changes the command set, OR when a
modifier is active (the keymap filter is per-buffer; two buffers with
the same command-set can still have different active keymaps via minor
modes).  Registered on `window-buffer-change-functions'.  No-ops while
a render is in progress (the `emacos--in-render' re-entry guard) and,
when no modifier is active, when the derived command set is unchanged —
so transient buffers (*Completions*, *Help*) don't flicker the command
list."
  (unless (or emacos--in-render
              (and (null emacos--modifier)
                   (equal (emacos--top-commands) emacos--last-commands)))
    (emacos--render-page)))

;;; Surface renderers (the four bands of the composite)
;;
;; All buttons share the same label font (`emacos--btn-label-scale') and
;; the same tap-target height (`emacos--btn-vpad' box padding); the
;; keyboard window scrolls, so bands stack as tall as they need.

(defun emacos--render-keyboard ()
  "Render the active layer's rows (3 rows of key groups — letters, digits,
or symbols per `emacos--kbd-mode') sized to fit the keyboard window.

Under an active modifier (`emacos--modifier' non-nil), groups are
*filtered* to bound-letter subsets via `emacos--bound-groups' (computed
once per render — B2: no module-level cache).  Groups with no bound
letters under the modifier render as a dimmed placeholder (`gray40',
non-tappable), preserving positional muscle memory.  An armed letter
(when `emacos--armed-tap' names this group) is face-stacked in bold
yellow inside its button label.

The action keys, utility row, and command list are separate bands —
see `emacos--render-page'."
  (let* ((win        (get-buffer-window (current-buffer)))
         (win-w      (if win (window-body-width win) 20))
         (gap-w      emacos--btn-gap)
         ;; 3 key groups per row, 2 gaps between them.
         (btn-w      (emacos--unit-width win-w gap-w 3 2))
         (target-win (emacos--target))
         (target-buf (and target-win (window-buffer target-win)))
         (filtered   (when (and emacos--modifier target-buf)
                       (emacos--bound-groups emacos--modifier target-buf)))
         (armed-sub  (and emacos--armed-tap
                          (plist-get emacos--armed-tap :group)))
         (armed-idx  (and emacos--armed-tap
                          (plist-get emacos--armed-tap :index)))
         (row-i 0))
    (dolist (row (emacos--active-layout))
      (let ((col-i 0))
        (dolist (kg row)
          (when (> col-i 0)
            (insert " ")
            (put-text-property (1- (point)) (point)
                               'display `(space :width ,gap-w)))
          (let* ((subset    (and filtered (nth col-i (nth row-i filtered))))
                 (dimmed-p  (and filtered (or (null subset)
                                              (string-empty-p subset))))
                 (display   (cond
                             ((not filtered) (emacos--key-display kg))
                             (dimmed-p kg)
                             (t subset)))
                 (trunc     (substring display 0 (min (length display) btn-w)))
                 (label     (emacos--center trunc btn-w)))
            (if dimmed-p
                ;; Empty subset under MOD: render a button-shaped slot with
                ;; a darker bg + dim fg.  Same box/height as live buttons so
                ;; the slot stays positional; the bg+fg contrast reads as
                ;; "dimmed, inactive" rather than a plain `propertize' which
                ;; on the phone's buffer background looked like a blank
                ;; white block.  `#'ignore' makes the tap a no-op.
                (let ((btn-start (point)))
                  (emacos--btn label #'ignore nil
                               emacos--btn-label-scale "gray15")
                  ;; Override the button face's hardcoded `:foreground "white"'
                  ;; with a dim gray; PREPEND so it wins the face merge.
                  (add-face-text-property btn-start (point)
                                          '(:foreground "gray45")
                                          nil))
              (let ((btn-start (point)))
                (emacos--btn label #'emacos--tap-key kg
                             emacos--btn-label-scale)
                ;; Armed-letter face stacking: bold yellow on the cycled
                ;; letter inside this group's button (when armed here).
                (when (and armed-sub (equal subset armed-sub)
                           (numberp armed-idx)
                           (< armed-idx (length trunc)))
                  (let* ((pad       (max 0 (- btn-w (length trunc))))
                         (lead      (/ pad 2))
                         (armed-pos (+ btn-start lead armed-idx)))
                    (when (< armed-pos (point))
                      ;; PREPEND (no APPEND arg): in face merging, earlier
                      ;; entries win on conflict.  With APPEND=t the
                      ;; button face's `:foreground "white"' would win and
                      ;; the armed letter would render invisibly.
                      (add-face-text-property
                       armed-pos (1+ armed-pos)
                       '(:weight bold :foreground "yellow")
                       nil)))))))
          (setq col-i (1+ col-i))))
      (insert "\n")
      (setq row-i (1+ row-i)))))

(defun emacos--render-action-row ()
  "Render the editing keys across two rows: DEL (one letter-key width) +
SPC (fills the rest of the row) on one row, then MOD / mode / TAB / RET
(the mode button cycles abc/ABC/123/#+=) with MOD and RET both
DOUBLE-WIDE.  MOD is leftmost on row 2; the row
is 6 units / 3 gaps.  MOD is doubled (matching RET) because it's a
frequent state-toggle on a 320x240 screen where 1u was too narrow for
a fingertip (live-pass found taps missing the target).  Accent the MOD
button when a modifier is active (firebrick4 vs Chat's dodger blue)."
  (let* ((win   (get-buffer-window (current-buffer)))
         (win-w (if win (window-body-width win) 20))
         (gap-w emacos--btn-gap)
         ;; DEL is one letter-key width (1/3, matching the keyboard groups).
         (third (emacos--unit-width win-w gap-w 3 1))
         ;; SPC fills the REST of the row: total button-cell budget (1 gap)
         ;; minus DEL — so the spacebar reads as the wide primary key and
         ;; no slack is left at the right edge.
         (spc   (- (emacos--unit-width win-w gap-w 1 1) third))
         ;; MOD(2) + CAPS(1) + TAB(1) + RET(2) = 6 units, 3 gaps.
         (unit  (emacos--unit-width win-w gap-w 6 3)))
    ;; Row: DEL (left, letter-key width), SPC (right, fills the rest).
    (emacos--btn (emacos--center "DEL" third) #'emacos--tap-backspace nil
                 emacos--btn-label-scale)
    (insert " ")
    (put-text-property (1- (point)) (point) 'display `(space :width ,gap-w))
    (emacos--btn (emacos--center "SPC" spc) #'emacos--tap-space nil
                 emacos--btn-label-scale)
    (insert "\n")
    ;; Row: MOD(double-wide), CAPS, TAB, RET(double-wide).  MOD is leftmost
    ;; so the state-bearing button sits opposite the most-tapped one (RET).
    (emacos--btn (emacos--center
                  (if emacos--modifier
                      (symbol-name emacos--modifier)
                    "mod")
                  (* 2 unit))
                 #'emacos--tap-modifier nil emacos--btn-label-scale
                 (and emacos--modifier "firebrick4"))
    (insert " ")
    (put-text-property (1- (point)) (point) 'display `(space :width ,gap-w))
    (emacos--btn (emacos--center
                  (pcase emacos--kbd-mode
                    ('lower "abc") ('caps "ABC") ('number "123") ('symbol "#+=")
                    (_ "abc"))   ; unknown mode -> letters, matching emacos--active-layout
                  unit)
                 #'emacos--tap-cycle-mode nil emacos--btn-label-scale)
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
  (emacos--render-page)
  ;; Prime the network poller so the modeline status segment is live from
  ;; boot, not only after the first *network* visit.
  (emacos-net--ensure-timer)
  (emacos-net--refresh))

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
(require 'emacos-assist)
(require 'network)
(require 'phone-call)

(provide 'os)
;;; os.el ends here
