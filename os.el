;;; os.el --- EmacsOS -*- lexical-binding: t -*-

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
  "Current page shown in the *keyboard* buffer.
One of `keyboard', `global', or `mode'.")

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

(defun emacos--btn (label action &optional arg)
  "Insert a clickable button showing LABEL that calls ACTION (with ARG)."
  (insert-text-button
   label
   'action (if arg
              (lambda (_) (funcall action arg))
            (lambda (_) (funcall action)))
   'follow-link t
   'face '(:box (:line-width (1 . 1) :style released-button)
           :background "gray25" :foreground "white")
   'mouse-face '(:box (:line-width (1 . 1) :style pressed-button)
                 :background "gray45" :foreground "white")))

;;; Command execution

(defun emacos--run-command (cmd)
  "Run CMD interactively in the target window.
If the command opens the minibuffer, switch to the keyboard page."
  (let ((w (emacos--target)))
    (when w
      (setq emacos--current-page 'keyboard)
      (emacos--render-page)
      (with-selected-window w
        (call-interactively cmd))
      (emacos--refocus))))

;;; Mode-specific commands

(defvar emacos-mode-commands
  '((org-mode
     ("Heading" . org-insert-heading)
     ("TODO"    . org-todo)
     ("Export"  . org-export-dispatch))
    (emacs-lisp-mode
     ("Eval Buffer"    . eval-buffer)
     ("Eval Last Sexp" . eval-last-sexp)))
  "Alist mapping major modes to lists of (LABEL . COMMAND) pairs.")

(defun emacos--mode-commands-for (mode)
  "Return the command list for MODE, walking up parent modes."
  (let ((m mode) result)
    (while (and m (not result))
      (setq result (cdr (assq m emacos-mode-commands)))
      (setq m (get m 'derived-mode-parent)))
    result))

;;; Page bar

(defun emacos--switch-page (page)
  "Switch to PAGE and re-render."
  (setq emacos--current-page page)
  (emacos--render-page)
  (emacos--refocus))

(defun emacos--render-page-bar ()
  "Insert the [KBD] [CMD] [MODE] page bar."
  (insert "\n")
  (dolist (entry '((keyboard . "KBD") (global . "CMD") (mode . "MODE")))
    (let* ((page (car entry))
           (label (cdr entry))
           (active (eq page emacos--current-page))
           (switch-fn (lambda (_) (emacos--switch-page page))))
      (insert-text-button
       (concat " " label " ")
       'action switch-fn
       'follow-link t
       'face (if active
                 '(:box (:line-width (1 . 1) :style released-button)
                   :background "dodger blue" :foreground "white" :weight bold)
               '(:box (:line-width (1 . 1) :style released-button)
                 :background "gray25" :foreground "gray70"))
       'mouse-face '(:box (:line-width (1 . 1) :style pressed-button)
                     :background "gray45" :foreground "white")))
    (insert " ")))

;;; Page renderers

(defun emacos--render-keyboard-page ()
  "Render the Optimal-T9 keyboard into the current buffer."
  ;; Letter rows
  (dolist (row emacos-t9-layout)
    (let ((widths '(6 6 6))
          (i 0))
      (dolist (kg row)
        (when (> i 0) (insert " "))
        (emacos--btn
         (emacos--center (emacos--key-display kg) (nth i widths))
         #'emacos--tap-key kg)
        (setq i (1+ i))))
    (insert "\n"))
  ;; Space, Return, Backspace
  (emacos--btn (emacos--center "SPC" 10) #'emacos--tap-space)
  (insert " ")
  (emacos--btn (emacos--center "RET" 4) #'emacos--tap-return)
  (insert " ")
  (emacos--btn (emacos--center "DEL" 4) #'emacos--tap-backspace)
  (insert "\n")
  ;; Caps toggle
  (emacos--btn
   (if emacos--caps (emacos--center "CAPS" 6) (emacos--center "caps" 6))
   #'emacos--tap-caps))

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
  "Render the current page into the *keyboard* buffer."
  (let ((buf (get-buffer-create "*keyboard*")))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (pcase emacos--current-page
          ('keyboard (emacos--render-keyboard-page))
          ('global   (emacos--render-global-page))
          ('mode     (emacos--render-mode-page)))
        (emacos--render-page-bar))
      (setq buffer-read-only t)
      (setq-local cursor-type nil)
      (setq-local mode-line-format nil)
      (setq-local truncate-lines t)
      (setq-local line-spacing 6)
      (goto-char (point-min)))))

;;; Initialization

(defun emacos--init ()
  "Set up the EmacsOS environment."
  (set-frame-name "EmacsOS")
  ;; Main editing buffer
  (switch-to-buffer (get-buffer-create "*scratch*"))
  (setq-local mode-line-format " EmacsOS")
  ;; Render keyboard page
  (emacos--render-page)
  ;; Split: top = editor, bottom = keyboard
  (let* ((total (window-total-height))
         (kbd-height (min 7 (/ total 2)))
         (kw (split-window nil (- total kbd-height) 'below)))
    (set-window-buffer kw (get-buffer "*keyboard*"))
    (set-window-dedicated-p kw t)
    (set-window-parameter kw 'no-other-window t)
    (set-window-parameter kw 'no-delete-other-windows t)
    (setq emacos--target-window (selected-window))))

;; Defer init until the window system is ready
(add-hook 'window-setup-hook #'emacos--init)

(provide 'os)
;;; os.el ends here
