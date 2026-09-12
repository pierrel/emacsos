;;; os.el --- EmacsOS -*- lexical-binding: t -*-

(require 'seq)  ; seq-filter, used by the modifier keyboard

(defgroup emacsos nil
  "EmacsOS: malleable, agent-customizable, local-first phone OS."
  :group 'applications
  :prefix "emacsos-")

(defcustom emacsos-use-internal-keyboard t
  "Whether EmacsOS renders its built-in text keyboard and utility row.
Set this to nil on devices that provide a compositor-level keyboard.  Such
devices have no ordinary control window; one appears temporarily only when a
buffer supplies a safety-critical `emacsos--keyboard-plane'."
  :type 'boolean
  :group 'emacsos)

(defcustom emacsos-control-window-percent 75
  "Percentage of the Emacs frame reserved for the bottom control pane."
  :type 'integer
  :group 'emacsos)

(defcustom emacsos-initial-buffer-function
  (lambda () (get-buffer-create "*scratch*"))
  "Function returning the top buffer shown when EmacsOS starts."
  :type 'function
  :group 'emacsos)

(defun emacsos-open-command-reference ()
  "Open the EmacsOS command reference from the current user's home."
  (interactive)
  (let ((path (expand-file-name "EMACSOS-COMMANDS.org" "~/")))
    (unless (file-readable-p path)
      (user-error "EmacsOS command reference is not installed"))
    (find-file path)))

(defun emacsos-command-new-thread ()
  "Create a canonical Assist thread."
  (interactive)
  (require 'assist-web)
  (call-interactively #'emacsos-assist-web-new-thread))

(defun emacsos-command-open-thread ()
  "Open a canonical Assist thread."
  (interactive)
  (require 'assist-web)
  (call-interactively #'emacsos-assist-web-open-thread))

(defvar emacsos-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "c") #'emacsos--chat-show-top-buffer)
    (define-key map (kbd "t") #'emacsos-command-open-thread)
    (define-key map (kbd "n") #'emacsos-command-new-thread)
    (define-key map (kbd "r") #'emacsos-assist-web-refresh-threads)
    (define-key map (kbd "f") #'emacsos-assist-new-file)
    (define-key map (kbd "d") #'emacsos-call)
    (define-key map (kbd "m") #'emacsos-send-message)
    (define-key map (kbd "w") #'emacsos-net-show)
    (define-key map (kbd "h") #'emacsos-open-command-reference)
    map)
  "Global EmacsOS commands under the C-c e prefix.")

(defvar emacsos-command-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c e") emacsos-command-map)
    (define-key map (kbd "C-c C-a n") #'emacsos-command-new-thread)
    (define-key map (kbd "C-c C-a t") #'emacsos-command-open-thread)
    map)
  "Global map for portable EmacsOS commands.")

(define-minor-mode emacsos-command-mode
  "Enable the one global EmacsOS command map."
  :global t
  :keymap emacsos-command-mode-map)

;; Disable chrome
(setq inhibit-startup-screen t
      inhibit-startup-message t
      window-min-height 1)

(menu-bar-mode -1)
(when (fboundp 'tool-bar-mode) (tool-bar-mode -1))

;; Global, minimal modeline: the EmacsOS label + device-supplied segments + a
;; tappable cell/wifi status segment (`emacsos-net-mode-line-string', network.el)
;; + tappable hidden call/SMS badges (`emacsos-call-mode-line-string',
;; phone-call.el; `emacsos-sms-mode-line-string', phone-sms.el), shown on every
;; top (editing) buffer only while their status screen is hidden.  Replaces
;; the stock clutter (buffer position, minor modes, encoding); the *keyboard*
;; buffer overrides this to nil on each render (`emacsos--render-page').
;; time/date/battery are left for the "Modeline status bar" roadmap item to
;; append here.  Set at load time (not in `emacsos--init') so a hot-reload
;; re-applies it.  The `:eval's resolve their functions at redisplay, after
;; the module `require's at the bottom of this file.
(defvar emacsos-platform-mode-line-segments nil
  "Additional mode-line segments supplied by the device bootstrap.
Each entry must be valid `mode-line-format' data.  The platform sets this
before loading EmacsOS so the segment also survives a live reload of os.el.")

(setq-default mode-line-format
              (append '(" EmacsOS  ")
                      emacsos-platform-mode-line-segments
                      '((:eval (emacsos-net-mode-line-string))
                        (:eval (emacsos-call-mode-line-string))
                        (:eval (emacsos-sms-mode-line-string)))))

;;; Optimal-T9 Keyboard (Qin et al., ISS 2018)
;;
;;  [ q w  ] [e r t y u i] [ o p  ]
;;  [ a s  ] [ d f g h   ] [j k l ]
;;  [z x c ] [ v b n     ] [  m   ]
;;  [     SPACE     ] [RET] [ DEL ]
;;  [CAPS]

(defvar emacsos-t9-layout
  '(("qw" "ertyui" "op")
    ("as" "dfgh"   "jkl")
    ("zxc" "vbn"   "m"))
  "Optimal-T9 letter layout.  Each key group is a string of letters.")

(defvar emacsos-123-layout
  '(("1" "2" "3")
    ("4" "5" "6")
    ("7" "8" "90"))
  "Numbers layer.  Digits 1-8 are single-tap; 9 and 0 share the last key.")

(defvar emacsos-symbols-layout
  '((".:/" ",;\"" "?!'")
    ("@#&" "-_~"  "+*=")
    ("()%" "[]$"  "{}|"))
  "Symbols layer.  Multi-tap reaches the rarer symbols in a group.")

(defvar emacsos--kbd-mode 'lower
  "Active keyboard mode, cycled by the CAPS button:
`lower' (abc) -> `caps' (ABC) -> `number' (123) -> `symbol' (#+=) -> loop.
Replaces the old caps boolean: `caps' is the uppercase-letters state.")

(defun emacsos--active-layout ()
  "The key-group layout for the current `emacsos--kbd-mode'.
`lower' and `caps' both type letters; `number'/`symbol' swap the grid."
  (pcase emacsos--kbd-mode
    ('number emacsos-123-layout)
    ('symbol emacsos-symbols-layout)
    (_       emacsos-t9-layout)))

;; Multi-tap state
(defvar emacsos--target-window nil)
(defvar emacsos--current-key nil)
(defvar emacsos--tap-index 0)
(defvar emacsos--commit-timer nil)

;; Double-tap-space → ". " state
(defvar emacsos--last-space-time nil
  "`float-time' of the most recent SPC tap, or nil.
Drives the double-tap-space gesture (`emacsos--double-space-p'): a second
SPC within `emacsos--double-space-threshold' turns the just-typed space
into a period + space.")

(defconst emacsos--double-space-threshold 0.5
  "Max seconds between two SPC taps for the double-space → \". \" gesture.
Past this they're treated as two ordinary spaces, matching the \"tap
twice rapidly\" feel.")

;; Modifier-key state.  See docs/2026-05-27-modifier-keys.org.
(defvar emacsos--modifier nil
  "Active modifier for the next bound-command tap.
Value is one of nil, the symbol C, M, or C-M.  Sticky across
keystrokes — only an explicit MOD-button tap changes it.")

(defvar emacsos--armed-tap nil
  "When non-nil, a plist `(:group SUBSET :index N :window W :buffer B)`
naming a binding ARMED under `emacsos--modifier' but not yet committed.
Set by `emacsos--tap-modified-key' (multi-letter subset path); cleared by
`emacsos--commit-armed-tap' (fires) or `emacsos--abandon-armed-tap' (clears
without firing — QUIT's path).  The 1.0s `emacsos--armed-tap-timer'
commits if nothing else does first.")

(defvar emacsos--armed-tap-timer nil
  "Timer that fires `emacsos--commit-armed-tap' after 1.0s of inactivity.
Mirrors `emacsos--commit-timer' for the bound-command path; cancelled by
any commit / abandon.")

;; Render state
(defvar emacsos--in-render nil
  "Non-nil while `emacsos--render-page' is running.
Transient re-entry guard so the `window-buffer-change-functions'
follower can't recurse into a render that is already in progress.
The chosen hook does not fire on our in-place re-render today, but a
future render that swaps a window's buffer would reintroduce the loop
hazard, and on a phone an infinite re-render bricks the device — so the
guard is kept even though nothing can trip it now.")

(defvar-local emacsos--keyboard-plane nil
  "Buffer-local override for the keyboard surface: a render function, or nil.
When the top buffer sets this to a function, `emacsos--render-page' paints a
temporary `*keyboard*' control window with that function.  nil means the
built-in keyboard and utility row when `emacsos-use-internal-keyboard' is
non-nil, or no control window when an external keyboard supplies text entry.
Call and SMS buffers use temporary planes for local confirmation controls.")

(defvar emacsos--last-plane 'unset
  "The keyboard plane `emacsos--render-page' last rendered.
The window-buffer follower re-renders only when this plane changes, except
that the built-in modifier keyboard also re-renders on every buffer change
while a modifier is active because keymaps are buffer-local.")

(defun emacsos--target ()
  "Return the editing window (not the keyboard).
Prefer the minibuffer when it is active."
  (or (active-minibuffer-window)
      (if (and (windowp emacsos--target-window)
               (window-live-p emacsos--target-window))
          emacsos--target-window
        (let ((kb (get-buffer "*keyboard*")))
          (catch 'found
            (walk-windows
             (lambda (w)
               (unless (eq (window-buffer w) kb)
                 (setq emacsos--target-window w)
                 (throw 'found w)))
             nil (selected-frame)))))))

(defun emacsos--refocus ()
  "Return focus to the editing window."
  (let ((w (emacsos--target)))
    (when w (select-window w))))

(defun emacsos--cancel-timer ()
  (when (timerp emacsos--commit-timer)
    (cancel-timer emacsos--commit-timer)
    (setq emacsos--commit-timer nil)))

(defun emacsos--commit ()
  (emacsos--cancel-timer)
  (setq emacsos--current-key nil emacsos--tap-index 0))

(defun emacsos--char-str (ch)
  "Return CH as a string, upcased only in `caps' mode.
A no-op for digits/symbols (upcase leaves them unchanged)."
  (funcall (if (eq emacsos--kbd-mode 'caps) #'upcase #'identity)
           (char-to-string ch)))

;;; Modifier-key state + filter (see docs/2026-05-27-modifier-keys.org).
;;
;; The MOD button cycles the modifier state; under a non-nil modifier,
;; letter-key taps fire a *bound command* instead of inserting a letter.
;; The grid filters to letters that have a binding under the current
;; modifier in the target buffer's full active-keymap stack.

(defun emacsos--modifier-prefix (mod)
  "Elisp key-sequence prefix for MOD.
nil maps to the empty string; the symbols C, M, C-M map to \"C-\",
\"M-\", \"C-M-\" respectively."
  (pcase mod
    ('nil "") ('C "C-") ('M "M-") ('C-M "C-M-")))

(defun emacsos--modifier-next (mod)
  "Cycle MOD one step: nil → C → M → C-M → nil."
  (pcase mod
    ('nil 'C) ('C 'M) ('M 'C-M) ('C-M nil)))

(defun emacsos--letter-bound-p (ch modifier buf)
  "Non-nil iff MODIFIER + CH is bound to a command in BUF's active keymaps
at point.  `key-binding' consults the full active-keymap stack
(overriding → emulation → minor → major → text-property/overlay at
point → global), so text-property and overlay keymap properties are
respected as the user expects.  `commandp' filters out prefix keys
(e.g. `Control-X-prefix', whose function-value is a keymap)."
  (with-current-buffer buf
    (let* ((kseq (kbd (concat (emacsos--modifier-prefix modifier)
                              (char-to-string ch))))
           (binding (key-binding kseq t)))
      (and binding (commandp binding)))))

(defun emacsos--bound-letters-in-group (kg modifier buf)
  "Return the letters of group KG that are bound under MODIFIER in BUF,
in original order.  Empty string when none."
  (apply #'string
         (seq-filter (lambda (ch)
                       (emacsos--letter-bound-p ch modifier buf))
                     kg)))

(defun emacsos--bound-groups (modifier buf)
  "Return the ACTIVE layout filtered to bound-char subsets under MODIFIER
in BUF (so MOD works over letters, digits, or symbols — whatever layer is
showing).  Same shape as the layout; empty groups stay positional as
empty strings (not removed) so the grid doesn't reflow."
  (mapcar (lambda (row)
            (mapcar (lambda (kg)
                      (emacsos--bound-letters-in-group kg modifier buf))
                    row))
          (emacsos--active-layout)))

(defun emacsos--cancel-armed-tap-timer ()
  "Cancel the armed-tap timer if it's running."
  (when (timerp emacsos--armed-tap-timer)
    (cancel-timer emacsos--armed-tap-timer)
    (setq emacsos--armed-tap-timer nil)))

(defun emacsos--abandon-armed-tap ()
  "Clear `emacsos--armed-tap' WITHOUT firing it.  QUIT's path; also used
internally when arm-time validation fails (dead window/buffer).  When
state actually cleared, re-renders so the armed-letter preview goes away
(no other path is guaranteed to render after an abandon — notably QUIT
in the active-minibuffer branch which `throws' before its own render)."
  (let ((had-state emacsos--armed-tap))
    (emacsos--cancel-armed-tap-timer)
    (setq emacsos--armed-tap nil)
    (when had-state (emacsos--render-page))))

(defun emacsos--commit-armed-tap ()
  "Fire the armed binding (if any) in its captured window/buffer; clear
state.  Silent no-op when nothing is armed.  D3 validation: silent
abandon if the captured window/buffer no longer exists or the window has
re-pointed at a different buffer.  Race-safe: also a silent no-op when
the binding has evaporated since arm time (a minor mode disabled, a
keymap mutated).

Dispatches via the CAPTURED window — not `emacsos--run-command' which
would re-derive target via `emacsos--target' and prefer any minibuffer
that happened to pop up between arm and the 1s timer fire.  D3 is the
whole point of capturing :window at arm time; honor it at fire time."
  (let ((armed emacsos--armed-tap))
    ;; Clear FIRST so a re-entrant fire (the command itself triggers a
    ;; render/follower that calls back into a commit path) can't loop.
    ;; abandon-armed-tap also re-renders, clearing the armed highlight.
    (emacsos--abandon-armed-tap)
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
                 (kseq (kbd (concat (emacsos--modifier-prefix emacsos--modifier)
                                    (char-to-string ch))))
                 ;; Look up in the captured buffer (not the current one).
                 (binding (with-current-buffer b (key-binding kseq t))))
            (when (and binding (commandp binding))
              (unwind-protect
                  (with-selected-window w
                    (call-interactively binding))
                ;; Mirror emacsos--run-command's post-action refresh when an
                ;; in-place command changes the buffer's special plane.
                (unless (eq (emacsos--top-keyboard-plane) emacsos--last-plane)
                  (emacsos--render-page))
                (emacsos--refocus)))))))))

;;; Key actions

(defun emacsos--tap-key (kg)
  "Handle a tap on key group KG.
Under an active modifier (`emacsos--modifier' non-nil), routes to
`emacsos--tap-modified-key' (fires a bound command).  Otherwise,
multi-tap cycles through the group's characters for insertion."
  (if emacsos--modifier
      (emacsos--tap-modified-key kg)
    (let ((w (emacsos--target)))
      (when w
        (emacsos--cancel-timer)
        (if (equal kg emacsos--current-key)
            ;; Same key: cycle to next character
            (let ((i (mod (1+ emacsos--tap-index) (length kg))))
              (setq emacsos--tap-index i)
              (with-selected-window w
                (delete-char -1)
                (insert (emacsos--char-str (aref kg i)))))
          ;; Different key: commit previous, start new
          (emacsos--commit)
          (setq emacsos--current-key kg emacsos--tap-index 0)
          (with-selected-window w
            (insert (emacsos--char-str (aref kg 0)))))
        ;; Auto-commit after timeout
        (setq emacsos--commit-timer
              (run-with-timer 1.0 nil #'emacsos--commit))
        (emacsos--refocus)))))

(defun emacsos--tap-modified-key (kg)
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
  (let* ((w (emacsos--target))
         (buf (and w (window-buffer w)))
         (subset (and buf (emacsos--bound-letters-in-group
                           kg emacsos--modifier buf))))
    (cond
     ;; Empty subset: silent no-op (no fire, no arm).
     ((or (null subset) (string-empty-p subset))
      nil)
     ;; Single-letter fast-path: fire immediately.  `emacsos--run-command'
     ;; tops with `emacsos--commit-armed-tap', which fires any prior arm
     ;; (different-group/different-letter semantics) and re-renders the
     ;; stale armed highlight away — no need for an explicit commit here.
     ((= (length subset) 1)
      (let* ((ch (aref subset 0))
             (kseq (kbd (concat (emacsos--modifier-prefix emacsos--modifier)
                                (char-to-string ch))))
             (binding (with-current-buffer buf (key-binding kseq t))))
        (when (and binding (commandp binding))
          (emacsos--run-command binding))))
     ;; Multi-letter subset: arm-then-commit cycle.
     (t
      (let ((armed emacsos--armed-tap))
        (if (and armed
                 (equal (plist-get armed :group) subset)
                 (eq (plist-get armed :window) w))
            ;; Same group: cycle within the bound subset.  `plist-put'
            ;; mutates the cons spine in place and returns the same head;
            ;; the setq is for documentation, not aliasing.
            (plist-put armed :index
                       (mod (1+ (plist-get armed :index)) (length subset)))
          ;; Different group (or first arm): commit any prior, arm new.
          (emacsos--commit-armed-tap)
          (setq emacsos--armed-tap
                (list :group subset :index 0 :window w :buffer buf)))
        (emacsos--cancel-armed-tap-timer)
        (setq emacsos--armed-tap-timer
              (run-with-timer 1.0 nil #'emacsos--commit-armed-tap))
        (emacsos--render-page)
        (emacsos--refocus))))))

(defun emacsos--tap-modifier ()
  "Action handler for the MOD button.
A2: when a binding is armed, COMMITS it before advancing the modifier.
Sticky modifier survives that commit (A1) — the cycle still steps once."
  (emacsos--commit)              ; commit any in-flight multi-tap character
  (emacsos--commit-armed-tap)    ; A2: commit armed binding (no-op if nil)
  (setq emacsos--modifier (emacsos--modifier-next emacsos--modifier))
  (emacsos--render-page)
  (emacsos--refocus))

(defun emacsos--double-space-p (now)
  "Non-nil if a SPC tap at time NOW (a `float-time') should become \". \".
True when the previous SPC tap was within `emacsos--double-space-threshold'
AND the char before the just-inserted space is alphanumeric — so the
mobile period gesture fires after a word, never after punctuation, after
another space, or at line start (which would double-period or misplace a
period).  Reads point in the current buffer; pure given that + NOW."
  (and emacsos--last-space-time
       (<= (- now emacsos--last-space-time) emacsos--double-space-threshold)
       (> (point) (1+ (point-min)))
       (eq (char-before) ?\s)
       (let ((c (char-before (1- (point)))))
         (and c (string-match-p "[[:alnum:]]" (string c))))))

(defun emacsos--tap-space ()
  "Insert a space.  Two SPC taps in quick succession after a word turn the
just-typed space into \". \" — the familiar mobile period shortcut (see
`emacsos--double-space-p' for exactly when it fires)."
  (emacsos--commit)
  (emacsos--commit-armed-tap)         ; A3: utility tap commits armed.
  (let ((w (emacsos--target))
        (now (float-time)))
    (when w
      (with-selected-window w
        (if (emacsos--double-space-p now)
            (progn
              (delete-char -1)
              (insert ". ")
              ;; Consume the gesture so a third rapid tap doesn't re-fire
              ;; off the period+space we just wrote.
              (setq emacsos--last-space-time nil))
          (insert " ")
          (setq emacsos--last-space-time now)))
      (emacsos--refocus))))

(defun emacsos--tap-return ()
  "Accept the minibuffer, or activate a safe object before newline fallback."
  (emacsos--commit)
  (emacsos--commit-armed-tap)         ; A3: utility tap commits armed.
  (let ((w (emacsos--target)))
    (when w
      (if (active-minibuffer-window)
          (with-selected-window w (exit-minibuffer))
        (with-selected-window w
          (if (fboundp 'emacsos-conversation-activate-or-newline)
              (emacsos-conversation-activate-or-newline)
            (newline)))
        (emacsos--refocus)))))

(defun emacsos--tap-backspace ()
  "Delete one character backward."
  (emacsos--cancel-timer)
  (setq emacsos--current-key nil emacsos--tap-index 0)
  (emacsos--commit-armed-tap)         ; A3: utility tap commits armed.
  (let ((w (emacsos--target)))
    (when w
      (with-selected-window w
        (when (> (point) (point-min))
          (delete-char -1)))
      (emacsos--refocus))))

(defun emacsos--tap-cycle-mode ()
  "Cycle the keyboard mode: lower -> caps -> number -> symbol -> lower.
One button does shift + layer.  A MOD modifier stays active across the
cycle (it then filters whatever layer now shows); like other utility taps,
any in-flight multi-tap character and pending armed binding commit first."
  (emacsos--commit)                 ; finalize any in-flight multi-tap character
  (emacsos--commit-armed-tap)       ; utility tap commits an armed binding
  (setq emacsos--kbd-mode
        (pcase emacsos--kbd-mode
          ('lower 'caps) ('caps 'number) ('number 'symbol) (_ 'lower)))
  (emacsos--render-page)
  (emacsos--refocus))

(defun emacsos--tap-tab ()
  "Context-aware TAB: complete in the minibuffer, else indent.
Mirrors the minibuffer special-case in `emacsos--tap-return'.  Uses
`call-interactively' so the underlying commands read their own
context (region, `this-command', `tab-always-indent', etc.)."
  (emacsos--commit)
  (emacsos--commit-armed-tap)         ; A3: utility tap commits armed.
  (let ((w (emacsos--target)))
    (when w
      (if (active-minibuffer-window)
          (with-selected-window w (call-interactively #'minibuffer-complete))
        (with-selected-window w (call-interactively #'indent-for-tab-command))
        (emacsos--refocus)))))

(defun emacsos--tap-quit ()
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
  window survives because `emacsos--init' gives it the
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
  (emacsos--commit)
  (emacsos--abandon-armed-tap)        ; A3: QUIT abandons, never commits.
  (if (active-minibuffer-window)
      (abort-recursive-edit)
    (let* ((w (emacsos--target))
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
        (emacsos--render-page)
        (emacsos--refocus)))))

;;; Rendering helpers

(defconst emacsos--btn-label-scale 0.8
  "Font :height for a keyboard button's LABEL (not its tap-target size).
Drives two things that must agree: the glyph size of the label, and the
per-row width budget (`emacsos--unit-width' divides by this).  Kept below
1.0 so the longest T9 group (\"ertyui\", 6 chars) fits in a group's cell
budget instead of truncating to \"ert\" — at 0.8 the budget is ~7 cells
wide at the phone's ~20-col keyboard.

Decoupled from button HEIGHT on purpose: a text button is otherwise only
as tall as its glyphs, so a label small enough to fit would also shrink
the tap target.  `emacsos--btn-vpad' adds the height back via box padding,
so the label can be small AND the button big.")

(defconst emacsos--btn-vpad 8
  "Vertical box padding (pixels) added top+bottom to every keyboard button.
This is the button-HEIGHT knob, decoupled from `emacsos--btn-label-scale'
\(the font size): it pads the tap target taller without enlarging the
glyphs.  Maps to the HWIDTH (top/bottom) element of the face `:box'
`:line-width' — vertical only, so it never widens a button and can't push
a row past the window edge (which would wrap the keyboard).")

(defconst emacsos--btn-hpad 1
  "Horizontal box padding (pixels) on a keyboard button's left+right edges.
Kept small: unlike `emacsos--btn-vpad', horizontal padding adds width the
per-row cell math (`emacsos--unit-width') doesn't account for, so a large
value would overflow the ~20-col row and wrap the keyboard.  Maps to the
VWIDTH (left/right) element of the face `:box' `:line-width'.")

(defconst emacsos--btn-gap 1.5
  "Visual width (in character cells) of the gap between buttons in a row.")

(defun emacsos--center (text width)
  "Center TEXT in a field of WIDTH characters."
  (let* ((len (string-width text))
         (pad (max 0 (- width len)))
         (l (/ pad 2))
         (r (- pad l)))
    (concat (make-string l ?\s) text (make-string r ?\s))))

(defun emacsos--unit-width (win-w gap-w units gaps)
  "Character width of ONE layout unit for a row spanning UNITS unit-widths
\(scaled by `emacsos--btn-label-scale') and GAPS inter-button gaps across WIN-W
columns.  A button may span more than one unit (e.g. a double-wide RET is
2 units), so UNITS and the button count can differ.  Floored, min 1 so a
pathologically narrow window can't drive a width <= 0 (which would crash
the letter-key `substring').  Pure — testable off the device."
  (max 1 (floor (/ (- win-w (* gaps gap-w)) (* units emacsos--btn-label-scale)))))

(defun emacsos--key-display (kg)
  "Format key group KG for display."
  (let ((s (if (eq emacsos--kbd-mode 'caps) (upcase kg) kg)))
    s))

(defvar emacsos--confirm-disarm-functions nil
  "Abnormal hook for disarming pending confirmation actions.
Each registered function receives (ACTION ARG) from an EmacsOS button.
It clears its own pending state unless the pair represents its confirming
second action.  Touchscreen call/SMS controls use a two-tap confirmation;
destructive M-x commands use two invocations.  Feature files register their
own disarm functions so shared button actions cancel stale pending state.")

(defun emacsos--maybe-cancel-confirm (action arg)
  "Run `emacsos--confirm-disarm-functions' with button ACTION and ARG.
Each registered function decides whether this is its confirming action or an
unrelated action that disarms it.  No-op when nothing is pending."
  (run-hook-with-args 'emacsos--confirm-disarm-functions action arg))

(defun emacsos--btn (label action &optional arg height bg)
  "Insert a clickable button showing LABEL that calls ACTION (with ARG).
HEIGHT, if given, is a face :height float for the LABEL font (callers
pass `emacsos--btn-label-scale').  The button's tap-target HEIGHT is
separate: it comes from the `:box' vertical padding (`emacsos--btn-vpad'),
so a small label still gets a big button.  BG, if given, overrides the
default gray background — used to accent a high-priority affordance (the
Chat button) so it reads as the app, not plumbing."
  (insert-text-button
   label
   ;; Every tap first offers pending confirmations a chance to disarm, then
   ;; runs ACTION.
   'action (lambda (_)
             (emacsos--maybe-cancel-confirm action arg)
             (if arg (funcall action arg) (funcall action)))
   'follow-link t
   'face `(:box (:line-width (,emacsos--btn-hpad . ,emacsos--btn-vpad)
                 :style released-button)
           :background ,(or bg "gray25") :foreground "white"
           ,@(when height `(:height ,height)))
   'mouse-face `(:box (:line-width (,emacsos--btn-hpad . ,emacsos--btn-vpad)
                       :style pressed-button)
                 :background "gray45" :foreground "white")))

;;; Command execution

(defun emacsos--run-command (cmd)
  "Run CMD interactively in the target (editing) window, then refresh.
Re-render only when CMD changes the current buffer's special keyboard plane;
buffer swaps are handled by `window-buffer-change-functions'.
`unwind-protect' keeps the refresh+refocus even when CMD throws (a bad
find-file path, a user-error, an aborted kill-buffer query).

A3: utility buttons commit any armed tap first.  Safe
under re-entrancy: `emacsos--commit-armed-tap' clears armed-tap BEFORE
firing, so the inner `emacsos--run-command' (for the armed binding) hits
a no-op commit at its own top."
  (emacsos--commit-armed-tap)
  (let ((w (emacsos--target)))
    (when w
      (unwind-protect
          (with-selected-window w
            (call-interactively cmd))
        (unless (eq (emacsos--top-keyboard-plane) emacsos--last-plane)
          (emacsos--render-page))
        (emacsos--refocus)))))

;; Defined in chat.el (required at the bottom of this file).  Forward-declared
;; so the byte-compiler can resolve the built-in keyboard utility row.
(declare-function emacsos--chat-show-top-buffer "chat")
(declare-function emacsos--chat-button "chat")
(declare-function emacsos--chat-button-label "chat")

;; Defined in network.el (required at the bottom of this file).
(declare-function emacsos-net-mode-line-string "network")
(declare-function emacsos-net--ensure-timer "network")
(declare-function emacsos-net--refresh "network")

;; Defined in phone-call.el (required at the bottom of this file).
(declare-function emacsos-call--watcher-ensure "phone-call")
(declare-function emacsos-call-mode-line-string "phone-call")
(declare-function emacsos-send-message "phone-sms")
(declare-function emacsos-sms-mode-line-string "phone-sms")
(declare-function emacsos-sms-show-status "phone-sms")

(defun emacsos--top-keyboard-plane ()
  "Return the TOP buffer's `emacsos--keyboard-plane' (a render fn), or nil.
nil while the minibuffer is active — a prompt needs the real keyboard, not a
buffer's control plane.  Otherwise reads the editing window's buffer."
  (unless (active-minibuffer-window)
    (let* ((target (emacsos--target))
           (buf (and target (window-buffer target))))
      (and (buffer-live-p buf)
           (buffer-local-value 'emacsos--keyboard-plane buf)))))

(defun emacsos--on-window-buffer-change (_frame)
  "Re-render when the top buffer changes its special keyboard plane.
When the built-in keyboard has an active modifier, also re-render for every
buffer change because the filtered bindings depend on buffer-local keymaps.
No-op while a render is in progress."
  (unless (or emacsos--in-render
              (and (null emacsos--modifier)
                   (eq (emacsos--top-keyboard-plane) emacsos--last-plane)))
    (emacsos--render-page)))

;;; Surface renderers
;;
;; All buttons share the same label font (`emacsos--btn-label-scale') and
;; the same tap-target height (`emacsos--btn-vpad' box padding); the
;; keyboard window scrolls, so bands stack as tall as they need.

(defun emacsos--render-keyboard ()
  "Render the active layer's rows (3 rows of key groups — letters, digits,
or symbols per `emacsos--kbd-mode') sized to fit the keyboard window.

Under an active modifier (`emacsos--modifier' non-nil), groups are
*filtered* to bound-character subsets via `emacsos--bound-groups' (computed
once per render — B2: no module-level cache).  Groups with no bound
characters under the modifier render as a dimmed placeholder (`gray40',
non-tappable), preserving positional muscle memory.  An armed character
(when `emacsos--armed-tap' names this group) is face-stacked in bold
yellow inside its button label.

The action keys and utility row are separate bands —
see `emacsos--render-page'."
  (let* ((win        (get-buffer-window (current-buffer)))
         (win-w      (if win (window-body-width win) 20))
         (gap-w      emacsos--btn-gap)
         ;; 3 key groups per row, 2 gaps between them.
         (btn-w      (emacsos--unit-width win-w gap-w 3 2))
         (target-win (emacsos--target))
         (target-buf (and target-win (window-buffer target-win)))
         (filtered   (when (and emacsos--modifier target-buf)
                       (emacsos--bound-groups emacsos--modifier target-buf)))
         (armed-sub  (and emacsos--armed-tap
                          (plist-get emacsos--armed-tap :group)))
         (armed-idx  (and emacsos--armed-tap
                          (plist-get emacsos--armed-tap :index)))
         (row-i 0))
    (dolist (row (emacsos--active-layout))
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
                             ((not filtered) (emacsos--key-display kg))
                             (dimmed-p kg)
                             (t subset)))
                 (trunc     (substring display 0 (min (length display) btn-w)))
                 (label     (emacsos--center trunc btn-w)))
            (if dimmed-p
                ;; Empty subset under MOD: render a button-shaped slot with
                ;; a darker bg + dim fg.  Same box/height as live buttons so
                ;; the slot stays positional; the bg+fg contrast reads as
                ;; "dimmed, inactive" rather than a plain `propertize' which
                ;; on the phone's buffer background looked like a blank
                ;; white block.  `#'ignore' makes the tap a no-op.
                (let ((btn-start (point)))
                  (emacsos--btn label #'ignore nil
                               emacsos--btn-label-scale "gray15")
                  ;; Override the button face's hardcoded `:foreground "white"'
                  ;; with a dim gray; PREPEND so it wins the face merge.
                  (add-face-text-property btn-start (point)
                                          '(:foreground "gray45")
                                          nil))
              (let ((btn-start (point)))
                (emacsos--btn label #'emacsos--tap-key kg
                             emacsos--btn-label-scale)
                ;; Armed-character face stacking: bold yellow on the cycled
                ;; character inside this group's button (when armed here).
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
                      ;; the armed character would render invisibly.
                      (add-face-text-property
                       armed-pos (1+ armed-pos)
                       '(:weight bold :foreground "yellow")
                       nil)))))))
          (setq col-i (1+ col-i))))
      (insert "\n")
      (setq row-i (1+ row-i)))))

(defun emacsos--render-action-row ()
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
         (gap-w emacsos--btn-gap)
         ;; DEL is one letter-key width (1/3, matching the keyboard groups).
         (third (emacsos--unit-width win-w gap-w 3 1))
         ;; SPC fills the REST of the row: total button-cell budget (1 gap)
         ;; minus DEL — so the spacebar reads as the wide primary key and
         ;; no slack is left at the right edge.
         (spc   (- (emacsos--unit-width win-w gap-w 1 1) third))
         ;; MOD(2) + CAPS(1) + TAB(1) + RET(2) = 6 units, 3 gaps.
         (unit  (emacsos--unit-width win-w gap-w 6 3)))
    ;; Row: DEL (left, letter-key width), SPC (right, fills the rest).
    (emacsos--btn (emacsos--center "DEL" third) #'emacsos--tap-backspace nil
                 emacsos--btn-label-scale)
    (insert " ")
    (put-text-property (1- (point)) (point) 'display `(space :width ,gap-w))
    (emacsos--btn (emacsos--center "SPC" spc) #'emacsos--tap-space nil
                 emacsos--btn-label-scale)
    (insert "\n")
    ;; Row: MOD(double-wide), CAPS, TAB, RET(double-wide).  MOD is leftmost
    ;; so the state-bearing button sits opposite the most-tapped one (RET).
    (emacsos--btn (emacsos--center
                  (if emacsos--modifier
                      (symbol-name emacsos--modifier)
                    "mod")
                  (* 2 unit))
                 #'emacsos--tap-modifier nil emacsos--btn-label-scale
                 (and emacsos--modifier "firebrick4"))
    (insert " ")
    (put-text-property (1- (point)) (point) 'display `(space :width ,gap-w))
    (emacsos--btn (emacsos--center
                  (pcase emacsos--kbd-mode
                    ('lower "abc") ('caps "ABC") ('number "123") ('symbol "#+=")
                    (_ "abc"))   ; unknown mode -> letters, matching emacsos--active-layout
                  unit)
                 #'emacsos--tap-cycle-mode nil emacsos--btn-label-scale)
    (insert " ")
    (put-text-property (1- (point)) (point) 'display `(space :width ,gap-w))
    (emacsos--btn (emacsos--center "TAB" unit) #'emacsos--tap-tab nil
                 emacsos--btn-label-scale)
    (insert " ")
    (put-text-property (1- (point)) (point) 'display `(space :width ,gap-w))
    (emacsos--btn (emacsos--center "RET" (* 2 unit)) #'emacsos--tap-return nil
                 emacsos--btn-label-scale)
    (insert "\n")))

(defun emacsos--render-utility-row ()
  "Render the persistent utility row: QUIT, M-x, Chat/SEND/ABORT (3-up).
`QUIT' (`emacsos--tap-quit') clears popup/minibuffer clutter off the top;
`M-x' runs `execute-extended-command' (manual command entry); the third
button (`emacsos--chat-button', accent face) opens ordinary chat off a
conversation surface and runs the displayed surface's primary action.  Its
label is Chat, SEND, or ABORT.  CAPS lives on the action row
(`emacsos--render-action-row')."
  (let* ((win   (get-buffer-window (current-buffer)))
         (win-w (if win (window-body-width win) 20))
         (gap-w emacsos--btn-gap)
         (util-w (emacsos--unit-width win-w gap-w 3 2)))
    (emacsos--btn (emacsos--center "QUIT" util-w) #'emacsos--tap-quit nil
                 emacsos--btn-label-scale)
    (insert " ")
    (put-text-property (1- (point)) (point) 'display `(space :width ,gap-w))
    (emacsos--btn (emacsos--center "M-x" util-w)
                 #'emacsos--run-command #'execute-extended-command
                 emacsos--btn-label-scale)
    (insert " ")
    (put-text-property (1- (point)) (point) 'display `(space :width ,gap-w))
    (emacsos--btn (emacsos--center (emacsos--chat-button-label) util-w)
                 #'emacsos--run-command #'emacsos--chat-button
                 emacsos--btn-label-scale "dodger blue")
    (insert "\n")))

;;; Render dispatch

(defun emacsos--ensure-control-window ()
  "Return the `*keyboard*' window, creating it below the editing window."
  (or (get-buffer-window "*keyboard*" (selected-frame))
      (let* ((target (or (emacsos--target) (selected-window)))
             (total (window-total-height target))
             (percent (max 1 (min 99 emacsos-control-window-percent)))
             (height (max 1 (/ (* total percent) 100)))
             (window (split-window target (- total height) 'below)))
        (set-window-buffer window (get-buffer-create "*keyboard*"))
        (set-window-dedicated-p window t)
        (set-window-parameter window 'no-other-window t)
        (set-window-parameter window 'no-delete-other-windows t)
        (setq emacsos--target-window target)
        window)))

(defun emacsos--remove-control-window ()
  "Delete the temporary external-keyboard control window and its buffer."
  (when-let ((window (get-buffer-window "*keyboard*" (selected-frame))))
    (set-window-parameter window 'no-delete-other-windows nil)
    (set-window-dedicated-p window nil)
    (delete-window window))
  (when-let ((buffer (get-buffer "*keyboard*")))
    (unless (get-buffer-window buffer t)
      (kill-buffer buffer))))

(defun emacsos--render-page ()
  "Render the built-in keyboard or a temporary safety-control plane.
With an external keyboard and no special `emacsos--keyboard-plane', delete the
control window and its buffer so ordinary content owns the whole Emacs area.
Bind `emacsos--in-render' so window changes caused here cannot recurse."
  (let ((emacsos--in-render t)
        (plane (emacsos--top-keyboard-plane)))
    (if (and (not emacsos-use-internal-keyboard) (null plane))
        (progn
          (emacsos--remove-control-window)
          (setq emacsos--last-plane nil))
      (let* ((window (emacsos--ensure-control-window))
             (buffer (window-buffer window)))
        (with-current-buffer buffer
          (let ((inhibit-read-only t))
            (erase-buffer)
            (if plane
                (funcall plane)
              (emacsos--render-keyboard)
              (emacsos--render-action-row)
              (emacsos--render-utility-row))
            ;; Record only after a successful render so a failed plane remains
            ;; eligible for the next explicit refresh.
            (setq emacsos--last-plane plane))
          (setq buffer-read-only t)
          (setq-local cursor-type nil)
          (setq-local mode-line-format nil)
          (setq-local truncate-lines t)
          (setq-local auto-hscroll-mode nil)
          (setq-local line-spacing 0)
          (set-window-hscroll window 0)
          (goto-char (point-min)))))))

;;; Initialization

(defun emacsos--init ()
  "Set up the EmacsOS environment."
  (set-frame-name "EmacsOS")
  ;; Main editing buffer
  (switch-to-buffer (funcall emacsos-initial-buffer-function))
  (setq emacsos--target-window (selected-window))
  ;; The built-in keyboard creates its persistent window here.  External
  ;; keyboards leave ordinary content unsplit; call/SMS planes create a
  ;; temporary control window on demand.
  (emacsos--render-page)
  ;; Prime the network poller so the modeline status segment is live from
  ;; boot, not only after the first *network* visit.
  (emacsos-net--ensure-timer)
  (emacsos-net--refresh)
  ;; Listen for incoming calls from boot (D-Bus CallAdded -> incoming screen).
  (emacsos-call--watcher-ensure))

;; Defer init until the window system is ready
(add-hook 'window-setup-hook #'emacsos--init)

;; Register the auto-follow hook at load time (not inside `emacsos--init')
;; so a hot-reload of os.el — the agent-driven-customization workflow —
;; keeps the follower active without a full restart.  `add-hook'
;; de-dupes, so re-loading doesn't double-register.
(add-hook 'window-buffer-change-functions #'emacsos--on-window-buffer-change)

;; Companion modules live alongside os.el; add this file's dir to
;; load-path so `(require 'chat)` works regardless of cwd.
(add-to-list 'load-path
             (file-name-directory (or load-file-name buffer-file-name)))
(require 'chat)
(require 'emacsos-assist)
(require 'assist-web)
(require 'network)
(require 'phone-call)
(require 'phone-sms)
(emacsos-command-mode 1)

(provide 'os)
;;; os.el ends here
