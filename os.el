;;; os.el --- EmacsOS -*- lexical-binding: t -*-

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

;; Render state
(defvar emacos--in-render nil
  "Non-nil while `emacos--render-page' is running.
Transient re-entry guard so the `window-buffer-change-functions'
follower can't recurse into a render that is already in progress.
The chosen hook does not fire on our in-place re-render today, but a
future render that swaps a window's buffer would reintroduce the loop
hazard, and on a phone an infinite re-render bricks the device.  Two
cheap lines of insurance against a catastrophic failure mode.")

(defvar emacos--last-commands 'unset
  "The command set `emacos--render-command-strip' last rendered.
The follower re-renders only when the top buffer's derived command set
actually changes, so transient buffers (*Completions*, *Help*) don't
flicker the strip — the keyboard itself never moves.")

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

(defun emacos--tap-space ()
  "Insert a space."
  (emacos--commit)
  (let ((w (emacos--target)))
    (when w
      (with-selected-window w (insert " "))
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

;;; Rendering helpers

(defun emacos--center (text width)
  "Center TEXT in a field of WIDTH characters."
  (let* ((len (string-width text))
         (pad (max 0 (- width len)))
         (l (/ pad 2))
         (r (- pad l)))
    (concat (make-string l ?\s) text (make-string r ?\s))))

(defun emacos--key-display (kg)
  "Format key group KG for display."
  (let ((s (if emacos--caps (upcase kg) kg)))
    s))

(defun emacos--btn (label action &optional arg height bg)
  "Insert a clickable button showing LABEL that calls ACTION (with ARG).
HEIGHT, if given, is a face :height float (e.g. 1.75 = 75%% taller).
BG, if given, overrides the default gray background — used to accent a
high-priority affordance (the Chat button) so it reads as the app, not
plumbing."
  (insert-text-button
   label
   'action (if arg
              (lambda (_) (funcall action arg))
            (lambda (_) (funcall action)))
   'follow-link t
   'face `(:box (:line-width (1 . 1) :style released-button)
           :background ,(or bg "gray25") :foreground "white"
           ,@(when height `(:height ,height)))
   'mouse-face '(:box (:line-width (1 . 1) :style pressed-button)
                 :background "gray45" :foreground "white")))

;;; Command execution

(defun emacos--run-command (cmd)
  "Run CMD interactively in the target (editing) window, then refresh.
The keyboard surface is always shown, so unlike the old swap model
there is no page to force/restore — just run, re-render (in case CMD
changed the top buffer's major mode IN PLACE, which the
window-buffer-change follower wouldn't catch), and refocus.  The
`unwind-protect' keeps the refresh+refocus even when CMD throws (a bad
find-file path, a user-error, an aborted kill-buffer query)."
  (let ((w (emacos--target)))
    (when w
      (unwind-protect
          (with-selected-window w
            (call-interactively cmd))
        (emacos--render-page)
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
     ("Refresh" . revert-buffer)))
  "Alist mapping major modes to lists of (LABEL . COMMAND) pairs.
Command-centric modes (where the user invokes commands more than they
type) belong here.  A mode absent from this alist falls back to
`emacos-global-commands' in the strip (see `emacos--top-commands').
Order each list by PRIORITY: the command strip is one row and shows
only as many commands as fit (earlier = kept); the rest are reachable
via M-x.  Grow this incrementally.")

(defvar emacos-global-commands
  '(("Save"          . save-buffer)
    ("Undo"          . undo)
    ("Find File"     . find-file)
    ("Switch Buffer" . switch-to-buffer))
  "Command-strip fallback for buffers whose major mode has no entry in
`emacos-mode-commands'.  Keeps the universal actions (save, undo, open,
switch) one tap away on a T9 keyboard, where `M-x find-file RET' is
~20 multi-taps.  Ordered by priority (the strip truncates to one row).")

(defun emacos--mode-commands-for (mode)
  "Return the command list for MODE, walking up parent modes."
  (let ((m mode) result)
    (while (and m (not result))
      (setq result (cdr (assq m emacos-mode-commands)))
      (setq m (get m 'derived-mode-parent)))
    result))

;;; Top-buffer command set (feeds the command strip)

;; Defined in chat.el (required at the bottom of this file).  Forward-
;; declared so the byte-compiler doesn't warn about the free variable /
;; unknown functions in `emacos--top-commands' and the utility row;
;; resolved at call time, after the require.
(defvar emacos--chat-buffer-name)
(declare-function emacos--chat-command-set "chat")
(declare-function emacos--chat-show-top-buffer "chat")

(defun emacos--top-commands ()
  "Return the command list ((LABEL . CMD) ...) for the TOP (editing)
buffer — the contents of the command strip.  One `cond':
an active minibuffer → nil (you're typing into a prompt; the strip
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
  "Re-render when the top buffer changes the strip's command set.
Registered on `window-buffer-change-functions'.  No-ops while a render
is in progress (the `emacos--in-render' re-entry guard) and when the
derived command set is unchanged — so transient buffers (*Completions*,
*Help*) don't flicker the strip.  The keyboard itself never moves; only
the bottom strip row could change."
  (unless (or emacos--in-render
              (equal (emacos--top-commands) emacos--last-commands))
    (emacos--render-page)))

;;; Page renderers

(defun emacos--render-keyboard ()
  "Render the Optimal-T9 letter rows + the SPC/RET/DEL/TAB action row,
sized to fit the keyboard window.  The caps toggle lives in the
utility row (`emacos--render-utility-row'), not here."
  (let* ((win      (get-buffer-window (current-buffer)))
         (win-w    (if win (window-body-width win) 20))
         ;; gap-w: visual width of the gap between buttons, in character widths.
         ;; Can be fractional; btn-w shrinks to compensate.
         (gap-w  1.5)
         ;; Letter buttons are scale times taller (and wider) than default.
         ;; btn-w shrinks so 3 scaled buttons + 2 gaps still fill the window.
         (scale  1.75)
         ;; max 1 so a pathologically narrow window can't drive widths
         ;; <=0 (which would crash the letter-key `substring' below).
         (btn-w  (max 1 (floor (/ (- win-w (* 2 gap-w)) (* 3 scale)))))
         ;; Action row (SPC/RET/DEL/TAB) is 4-up with its OWN width so
         ;; adding TAB doesn't shrink the letter keys (the hot path).
         (action-w (max 1 (floor (/ (- win-w (* 3 gap-w)) (* 4 scale))))))
    ;; Letter rows — :height scale makes each row ~1.75x taller automatically
    (dolist (row emacos-t9-layout)
      (let ((i 0))
        (dolist (kg row)
          (when (> i 0)
            (insert " ")
            (put-text-property (1- (point)) (point)
                               'display `(space :width ,gap-w)))
          (let* ((s (emacos--key-display kg))
                 (s (substring s 0 (min (length s) btn-w))))
            (emacos--btn (emacos--center s btn-w) #'emacos--tap-key kg scale))
          (setq i (1+ i))))
      (insert "\n"))
    ;; Action row: Space, Return, Backspace, Tab — 4-up at action-w
    (emacos--btn (emacos--center "SPC" action-w) #'emacos--tap-space nil scale)
    (insert " ")
    (put-text-property (1- (point)) (point) 'display `(space :width ,gap-w))
    (emacos--btn (emacos--center "RET" action-w) #'emacos--tap-return nil scale)
    (insert " ")
    (put-text-property (1- (point)) (point) 'display `(space :width ,gap-w))
    (emacos--btn (emacos--center "DEL" action-w) #'emacos--tap-backspace nil scale)
    (insert " ")
    (put-text-property (1- (point)) (point) 'display `(space :width ,gap-w))
    (emacos--btn (emacos--center "TAB" action-w) #'emacos--tap-tab nil scale)
    (insert "\n")))

(defun emacos--render-utility-row ()
  "Render the persistent utility row: caps, M-x, and Chat.
The non-letter affordances always within reach — `caps' is a keyboard
modifier (toggles + re-renders); `M-x' runs `execute-extended-command'
\(the manual command-entry escape hatch); `Chat' shows the *chat*
buffer (the phone's home app, so it carries the accent face).  All
three are 3-up at `util-w'."
  (let* ((win   (get-buffer-window (current-buffer)))
         (win-w (if win (window-body-width win) 20))
         (util-w (floor (/ (- win-w 2) 3))))
    (emacos--btn (emacos--center (if emacos--caps "CAPS" "caps") util-w)
                 #'emacos--tap-caps)
    (insert " ")
    (emacos--btn (emacos--center "M-x" util-w)
                 #'emacos--run-command #'execute-extended-command)
    (insert " ")
    (emacos--btn (emacos--center "Chat" util-w)
                 #'emacos--run-command #'emacos--chat-show-top-buffer
                 nil "dodger blue")
    (insert "\n")))

(defun emacos--command-spec (entry)
  "Normalize a command-strip ENTRY to (LABEL CMD HEIGHT).
ENTRY is either (LABEL . CMD) — the common shape, HEIGHT nil — or
(LABEL CMD HEIGHT) when a command wants a non-default button height
\(only chat's SEND does today; see `emacos--chat-command-set')."
  (if (consp (cdr entry))
      (list (car entry) (cadr entry) (caddr entry))
    (list (car entry) (cdr entry) nil)))

(defun emacos--commands-fitting (commands width)
  "Return the prefix of COMMANDS whose buttons fit one row of WIDTH cols.
Each button renders as \" LABEL \" (label + 2 padding) plus a one-space
inter-button gap, so the Nth button costs (length label) + 3.  Order is
priority: earlier entries survive, the rest fall to M-x.  Pure — WIDTH
is passed in, so it's testable off the device."
  (let ((used 0) (kept '()))
    (catch 'done
      (dolist (entry commands)
        (let ((cost (+ (length (car entry)) 3)))
          (if (<= (+ used cost) width)
              (setq used (+ used cost)
                    kept (cons entry kept))
            (throw 'done nil)))))
    (nreverse kept)))

(defun emacos--render-command-strip ()
  "Render one row of the top buffer's commands (the \"top commands under
the keyboard\"), truncated to a single row; overflow is reachable via
M-x.  Caches the derived set in `emacos--last-commands' so the follower
can no-op when nothing changed."
  (let* ((win   (get-buffer-window (current-buffer)))
         (win-w (if win (window-body-width win) 20))
         (commands (emacos--top-commands)))
    (setq emacos--last-commands commands)
    (dolist (entry (emacos--commands-fitting commands win-w))
      (let* ((spec (emacos--command-spec entry)))
        (emacos--btn (concat " " (nth 0 spec) " ")
                     #'emacos--run-command (nth 1 spec) (nth 2 spec))
        (insert " ")))
    (insert "\n")))

;;; Page dispatch

(defun emacos--render-page ()
  "Render the *keyboard* window: the always-on composite of the T9
keyboard, the utility row, and the top-buffer command strip.  Binds
`emacos--in-render' for the duration so the window-buffer-change
follower can't recurse into an in-progress render."
  (let ((buf (get-buffer-create "*keyboard*"))
        (emacos--in-render t))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (emacos--render-keyboard)
        (emacos--render-utility-row)
        (emacos--render-command-strip))
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
  ;; command strip derives from the top buffer at render time, and the
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
