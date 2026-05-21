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

;; Page state
(defvar emacos--current-page 'keyboard
  "The concrete page currently shown in the *keyboard* buffer.
One of `keyboard', `global', `mode', or `chat'.  Whether this value
is followed (auto-derived from the top buffer) or held fixed is
governed by `emacos--page-mode'.")

(defvar emacos--page-mode 'auto
  "Whether the keyboard surface follows the top buffer or is pinned.
`auto' (default): the surface re-derives from the top buffer's major
mode on every top-buffer change (see `emacos--derive-page').
`pinned': the user tapped a specific page in the bar; the follower is
inert until they tap the AUTO chip.")

(defvar emacos--in-render nil
  "Non-nil while `emacos--render-page' is running.
Transient re-entry guard so the window-buffer-change follower can't
recurse into a render that is already in progress.  Belt-and-
suspenders: the chosen hook does not fire on the in-place keyboard
re-render, but a future render that swaps a window's buffer would
reintroduce the loop hazard, and on a phone an infinite re-render
bricks the device.")

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
Mirrors `emacos--tap-return''s minibuffer special-case.  Uses
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

(defun emacos--btn (label action &optional arg height)
  "Insert a clickable button showing LABEL that calls ACTION (with ARG).
HEIGHT, if given, is a face :height float (e.g. 1.75 = 75%% taller)."
  (insert-text-button
   label
   'action (if arg
              (lambda (_) (funcall action arg))
            (lambda (_) (funcall action)))
   'follow-link t
   'face `(:box (:line-width (1 . 1) :style released-button)
           :background "gray25" :foreground "white"
           ,@(when height `(:height ,height)))
   'mouse-face '(:box (:line-width (1 . 1) :style pressed-button)
                 :background "gray45" :foreground "white")))

;;; Command execution

(defun emacos--run-command (cmd)
  "Run CMD interactively in the target window.
Shows the keyboard page while the command runs (so a minibuffer
prompt has the T9 surface to type into), then restores the surface:
in `auto' mode re-derive from the (possibly changed) top buffer; in
`pinned' mode restore the page that was showing before."
  (let ((w (emacos--target))
        (prior emacos--current-page))
    (when w
      (setq emacos--current-page 'keyboard)
      (emacos--render-page)
      ;; unwind-protect so a command that throws (bad find-file path,
      ;; a user-error, an aborted kill-buffer query) still restores the
      ;; surface instead of stranding it on the forced keyboard page.
      (unwind-protect
          (with-selected-window w
            (call-interactively cmd))
        (if (eq emacos--page-mode 'auto)
            (emacos--follow)
          (setq emacos--current-page prior)
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
     ("Refresh" . revert-buffer)))
  "Alist mapping major modes to lists of (LABEL . COMMAND) pairs.
Command-centric modes (where the user invokes commands more than they
type) belong here; text-entry modes are intentionally absent so they
auto-derive to the T9 keyboard (see `emacos--derive-page').  Grow
this incrementally — the keyboard fallback means an un-listed mode
degrades gracefully.")

(defun emacos--mode-commands-for (mode)
  "Return the command list for MODE, walking up parent modes."
  (let ((m mode) result)
    (while (and m (not result))
      (setq result (cdr (assq m emacos-mode-commands)))
      (setq m (get m 'derived-mode-parent)))
    result))

;;; Auto-following surface

;; Defined in chat.el (required at the bottom of this file).  Forward-
;; declared so the byte-compiler doesn't warn about a free variable in
;; `emacos--derive-page'; resolved at call time, after the require.
(defvar emacos--chat-buffer-name)

(defun emacos--derive-page ()
  "Map the top (editing) buffer to the page symbol auto mode should show.
Order matters: an active minibuffer means the user is typing into a
prompt, so the T9 keyboard is the right surface regardless of the
underlying buffer's mode.  Then: the *chat* buffer (by identity) →
`chat'; a major mode with a command set → `mode'; everything else →
`keyboard' so the phone can always type."
  (cond
   ((active-minibuffer-window) 'keyboard)
   (t
    (let* ((target (emacos--target))
           (buf (and target (window-buffer target)))
           (mode (if buf (buffer-local-value 'major-mode buf)
                   'fundamental-mode)))
      (cond
       ((and buf (eq buf (get-buffer emacos--chat-buffer-name))) 'chat)
       ((emacos--mode-commands-for mode) 'mode)
       (t 'keyboard))))))

(defun emacos--follow ()
  "In `auto' mode, sync the shown page to the derived page and render.
Home for the \"auto means `emacos--current-page' tracks
`emacos--derive-page'\" invariant; called by the AUTO chip
\(`emacos--switch-to-auto') and the `emacos--run-command' tail.  The
window-buffer-change follower does NOT call this — it needs the
re-entry guard and a no-op-render-when-unchanged optimization for
loop-safety, so it inlines its own variant.  No-op when pinned."
  (when (eq emacos--page-mode 'auto)
    (let ((derived (emacos--derive-page)))
      (unless (eq derived emacos--current-page)
        (setq emacos--current-page derived))
      (emacos--render-page))))

(defun emacos--on-window-buffer-change (_frame)
  "Re-derive the surface when the TOP buffer changes, in `auto' mode.
Registered on `window-buffer-change-functions'.  Inert when pinned or
already rendering.  NOTE: unlike `emacos--switch-page', this does NOT
swap *chat* onto the top window — derivation is driven BY the top
buffer (the chat buffer is already on top when we derive `chat'),
whereas manual selection drives the top buffer."
  (unless (or emacos--in-render (not (eq emacos--page-mode 'auto)))
    (let ((derived (emacos--derive-page)))
      (unless (eq derived emacos--current-page)
        (setq emacos--current-page derived)
        (emacos--render-page)))))

(defun emacos--switch-to-auto ()
  "Hand control back to the follower: re-enter `auto' and re-derive."
  (setq emacos--page-mode 'auto)
  (emacos--follow)
  (emacos--refocus))

;;; Page bar

(defun emacos--switch-page (page)
  "Switch to PAGE and re-render.  A manual tap PINS the surface.
Switching to `chat' also swaps the *chat* buffer into the editor
window; other pages never touch the top window.  (The auto-follower
`emacos--on-window-buffer-change' deliberately does NOT do this swap
— it reacts to *chat* already being on top.)"
  (setq emacos--page-mode 'pinned)
  (setq emacos--current-page page)
  (when (eq page 'chat)
    (emacos--chat-show-top-buffer))
  (emacos--render-page)
  (emacos--refocus))

(defun emacos--page-bar-chip (label active action)
  "Insert one page-bar chip: LABEL, highlighted if ACTIVE, calling ACTION."
  (insert-text-button
   (concat " " label " ")
   'action action
   'follow-link t
   'face (if active
             '(:box (:line-width (1 . 1) :style released-button)
               :background "dodger blue" :foreground "white" :weight bold)
           '(:box (:line-width (1 . 1) :style released-button)
             :background "gray25" :foreground "gray70"))
   'mouse-face '(:box (:line-width (1 . 1) :style pressed-button)
                 :background "gray45" :foreground "white"))
  (insert " "))

(defun emacos--render-page-bar ()
  "Insert the [KBD] [CMD] [MODE] [CHAT] [AUTO] page bar.
The shown-page chip is always active-highlighted; the AUTO chip is
active iff `emacos--page-mode' is `auto' — so the bar reads both
\"which surface\" and \"following or pinned\" at a glance."
  (insert "\n")
  (dolist (entry '((keyboard . "KBD") (global . "CMD") (mode . "MODE") (chat . "CHAT")))
    (let ((page (car entry)))
      (emacos--page-bar-chip
       (cdr entry)
       (eq page emacos--current-page)
       (lambda (_) (emacos--switch-page page)))))
  ;; AUTO chip: tapping it hands control back to the follower.
  (emacos--page-bar-chip
   "AUTO"
   (eq emacos--page-mode 'auto)
   (lambda (_) (emacos--switch-to-auto))))

;;; Page renderers

(defun emacos--render-keyboard-page ()
  "Render the Optimal-T9 keyboard, sized to fit the keyboard window."
  (let* ((win      (get-buffer-window (current-buffer)))
         (win-w    (if win (window-body-width win) 20))
         (win-lines (if win (window-body-height win) 9))
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
         (action-w (max 1 (floor (/ (- win-w (* 3 gap-w)) (* 4 scale)))))
         ;; Utility buttons use full-width columns at normal scale.
         (util-w (floor (/ (- win-w 2) 3))))
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
    (insert "\n")
    ;; Caps toggle
    (emacos--btn (emacos--center (if emacos--caps "CAPS" "caps") util-w)
                 #'emacos--tap-caps)
    (setq-local line-spacing 0)))

(defun emacos--render-global-page ()
  "Render global command buttons into the current buffer."
  (let ((commands '(("Find File"     . find-file)
                    ("Save"          . save-buffer)
                    ("Save As"       . write-file)
                    ("Switch Buffer" . switch-to-buffer)
                    ("Kill Buffer"   . kill-buffer)
                    ("Undo"          . undo)
                    ("Goto Line"     . goto-line)))
        (col 0))
    (dolist (entry commands)
      (let ((label (car entry))
            (cmd (cdr entry)))
        (when (> col 0) (insert " "))
        (emacos--btn (concat " " label " ") #'emacos--run-command cmd)
        (setq col (1+ col))
        (when (>= col 3)
          (insert "\n")
          (setq col 0))))
    (when (> col 0) (insert "\n"))))

(defun emacos--render-mode-page ()
  "Render mode-specific command buttons into the current buffer."
  (let* ((target (emacos--target))
         (mode (if target
                   (buffer-local-value 'major-mode (window-buffer target))
                 'fundamental-mode))
         (commands (emacos--mode-commands-for mode)))
    (if (not commands)
        (insert (format " No commands for %s\n" mode))
      (let ((col 0))
        (dolist (entry commands)
          (let ((label (car entry))
                (cmd (cdr entry)))
            (when (> col 0) (insert " "))
            (emacos--btn (concat " " label " ") #'emacos--run-command cmd)
            (setq col (1+ col))
            (when (>= col 3)
              (insert "\n")
              (setq col 0))))
        (when (> col 0) (insert "\n"))))))

;;; Page dispatch

(defun emacos--render-page ()
  "Render the current page into the *keyboard* buffer.
Binds `emacos--in-render' for the duration so the window-buffer-change
follower can't recurse into an in-progress render."
  (let ((buf (get-buffer-create "*keyboard*"))
        (emacos--in-render t))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (pcase emacos--current-page
          ('keyboard (emacos--render-keyboard-page))
          ('global   (emacos--render-global-page))
          ('mode     (emacos--render-mode-page))
          ('chat     (emacos--render-chat-page)))
        (emacos--render-page-bar))
      (setq buffer-read-only t)
      (setq-local cursor-type nil)
      (setq-local mode-line-format nil)
      (setq-local truncate-lines t)
      (setq-local auto-hscroll-mode nil)
      (set-window-hscroll (get-buffer-window buf) 0)
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
  ;; Auto-follow (default 'auto): derive the initial surface so boot
  ;; lands on the right page.  The follower hook itself is registered
  ;; at load time (below) so it survives hot-reloads via `local-deploy'.
  (setq emacos--current-page (emacos--derive-page))
  ;; Render after window is visible so dimensions are known
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
