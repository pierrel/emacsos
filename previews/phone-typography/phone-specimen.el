;;; phone-specimen.el --- Temporary named phone font samples -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'button)

(defconst emacsos-type-study-fonts
  '(("Droid Sans" "Droid Sans" "Droid Sans Mono" "Droid Sans Mono")
    ("IBM Plex Sans" "Phone Type 02" "IBM Plex Mono" "Phone Code 02")
    ("Inter" "Phone Type 03" "JetBrains Mono" "Phone Code 03")
    ("Source Sans 3" "Phone Type 04" "Source Code Pro" "Phone Code 04")
    ("Atkinson Hyperlegible Next" "Phone Type 05" "Atkinson Hyperlegible Mono" "Phone Code 05")
    ("Geist" "Phone Type 06" "Geist Mono" "Phone Code 06")
    ("Manrope" "Phone Type 07" "JetBrains Mono" "Phone Code 03")
    ("Source Serif 4" "Phone Type 08" "Source Code Pro" "Phone Code 04"))
  "Visible parent names paired with exact installed specimen family names.
The Phone Type/Code families are fixed-axis derivatives, renamed for OFL compliance.")

(defvar-local emacsos-type-study-markers nil)

(defun emacsos-type-study--font (family weight)
  "Return FAMILY at WEIGHT, refusing a silent substitute."
  (let* ((font (find-font (font-spec :family family :weight weight)))
         (actual (and font (font-get font :family))))
    (unless (and actual (string-equal (downcase (symbol-name actual)) (downcase family)))
      (error "Specimen font missing: %s %s (resolved %s)" family weight actual))
    (let ((resolved (font-get font :weight)))
      (unless (if (eq weight 'normal)
                  (memq resolved '(normal regular))
                (eq resolved weight))
        (error "Specimen weight missing: %s %s (resolved %s)"
               family weight resolved)))
    font))

(defun emacsos-type-study--insert (text family height &optional weight)
  "Insert TEXT with a local FAMILY/HEIGHT face at WEIGHT."
  (insert (propertize text 'face `(:family ,family :height ,height
                                :weight ,(or weight 'normal)))))

(defun emacsos-type-study--jump (button)
  "Move to the named sample attached to BUTTON."
  (goto-char (button-get button 'sample-marker))
  (recenter 0))

(defun emacsos-type-study--move (direction)
  "Move to the adjacent sample in DIRECTION."
  (let* ((here (point))
         (positions (mapcar #'marker-position emacsos-type-study-markers))
         (target (if (> direction 0)
                     (cl-find-if (lambda (p) (> p here)) positions)
                   (car (last (cl-remove-if-not (lambda (p) (< p here)) positions))))))
    (when target (goto-char target) (recenter 0))))

(defun emacsos-type-study-next ()
  "Go to the next named font section."
  (interactive)
  (emacsos-type-study--move 1))

(defun emacsos-type-study-previous ()
  "Go to the previous named font section."
  (interactive)
  (emacsos-type-study--move -1))

(defun emacsos-type-study-index ()
  "Return to the tappable font index."
  (interactive)
  (goto-char (point-min))
  (recenter 0))

(define-derived-mode emacsos-type-study-mode special-mode "Font study"
  "Read-only font samples. Tap a name, scroll, or use n/p/i for next/previous/index."
  (setq-local truncate-lines nil
              line-spacing 0.15)
  (local-set-key (kbd "n") #'emacsos-type-study-next)
  (local-set-key (kbd "p") #'emacsos-type-study-previous)
  (local-set-key (kbd "i") #'emacsos-type-study-index))

(defun emacsos-type-study-show ()
  "Display all named font candidates without changing any global face.
Require every intended family and semibold sample before creating the buffer.
Prose sizes are 12, 14 and 16 pt, Emacs height 120, 140 and 160.
Code is 13 pt; heading is 16 pt semibold. Current theme and keyboard are retained."
  (interactive)
  ;; Preflight the complete set before presenting any sample as authentic.
  (dolist (entry emacsos-type-study-fonts)
    (emacsos-type-study--font (nth 1 entry) 'normal)
    (emacsos-type-study--font (nth 1 entry)
                            (if (string-equal (car entry) "Droid Sans") 'bold 'semi-bold))
    (emacsos-type-study--font (nth 3 entry) 'normal))
  (let ((buffer (get-buffer-create "*Phone font studies*")))
    (with-current-buffer buffer
      (emacsos-type-study-mode)
      (let ((inhibit-read-only t)
            (index-links nil))
        (erase-buffer)
        (setq emacsos-type-study-markers nil)
        (insert "PHONE FONT STUDIES\n\n")
        (insert "Tap a font name. Scroll its sample.\nn/p: next/previous   i: index\n\n")
        (dolist (entry emacsos-type-study-fonts)
          (let ((button (insert-text-button
                         (car entry) 'follow-link t
                         'action #'emacsos-type-study--jump)))
            (push button index-links))
          (insert "\n\n"))
        (insert "Synthetic text. Global faces unchanged.\nCurrent phone theme and keyboard retained.\n\n")
        (cl-loop for entry in emacsos-type-study-fonts
                 for button in (nreverse index-links)
                 for number from 1
                 do
                 (pcase-let ((`(,name ,family ,mono-name ,mono-family) entry))
                   (let ((marker (copy-marker (point))))
                     (push marker emacsos-type-study-markers)
                     (button-put button 'sample-marker marker))
                   (insert (format "\n%02d / %s\n" number name))
                   (insert (format "Code: %s\n" mono-name))
                   (insert-text-button "↑ Font index" 'follow-link t
                                       'action (lambda (_) (emacsos-type-study-index)))
                   (insert "\n\n")
                   (emacsos-type-study--insert
                    "A little structure\n" family 160
                    (if (string-equal name "Droid Sans") 'bold 'semi-bold))
                   (dolist (height '(120 140 160))
                     (insert (format "\n%d pt / regular\n" (/ height 10)))
                     (emacsos-type-study--insert
                      "you> Give me a simple plan for tomorrow.\n\nbot> Keep the morning open. Pick one thing that matters, then leave room to walk.\n\n"
                      family height))
                   (insert "14 pt / UI and numbers\n")
                   (emacsos-type-study--insert
                    "Networks\nDone\n* Studio  92%\n[lock] Library  78%\nNext\n\nI l 1 · O 0 · rn m\n08:45 · 14:30 · +12025550142\nIl était déjà près de l’été.\n\n"
                    family 140)
                   (insert "13 pt / fixed-pitch code\n")
                   (emacsos-type-study--insert
                    "(defun quiet-morning ()\n  (interactive)\n  (find-file \"tomorrow.org\"))\n\nname      size   state\nnotes      128   saved\nplan       064   draft\n\nI l 1 | O 0 | rn m | {} []\n\n"
                    mono-family 130)
                   (insert-text-button "↑ Font index" 'follow-link t
                                       'action (lambda (_) (emacsos-type-study-index)))
                   (insert "\n\n")))
        (setq emacsos-type-study-markers (nreverse emacsos-type-study-markers))
        (goto-char (point-min))))
    (pop-to-buffer buffer)
    buffer))

(provide 'phone-specimen)
;;; phone-specimen.el ends here
