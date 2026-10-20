;;; test-pinephone-vterm-history.el --- Native phone terminal history tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'dtach-shell-init)
(require 'vterm)

(defun emacsos-test-vterm-wait (predicate process)
  "Wait at most three seconds for PREDICATE while servicing PROCESS."
  (let ((deadline (+ (float-time) 3)))
    (while (and (not (funcall predicate)) (< (float-time) deadline))
      (accept-process-output process 0.02))
    (should (funcall predicate))))

(ert-deftest emacsos-phone-vterm-drag-enters-native-copy-and-restores-dtach ()
  (let ((vterm-shell "/bin/sh")
        (vterm-kill-buffer-on-exit nil)
        (vterm-timer-delay nil)
        buffer keys)
    (unwind-protect
        (save-window-excursion
          (vterm " *phone-history-drag*")
          (setq buffer (current-buffer))
          (dtach-shell--install-buffer-keybindings)
          (let ((terminal-map (current-local-map))
                (shared-map (copy-keymap vterm-mode-map))
                (capture (lambda (key &rest _) (push key keys))))
            (vterm--write-input
             vterm--term
             (mapconcat (lambda (i) (format "History line %03d\r\n" i))
                        (number-sequence 1 200) ""))
            (let ((inhibit-read-only t)) (vterm--redraw vterm--term))
            (goto-char (point-min))
            (forward-line 100)
            (set-window-start (selected-window) (point))
            (let ((before (window-start))
                  (touch-screen-current-tool
                   (list nil (selected-window) nil 'scroll nil 0 0 0 0))
                  (touch-screen-precision-scroll nil))
              (advice-add 'vterm-send-key :before capture)
              (unwind-protect
                  (progn
                    (funcall (key-binding [touchscreen-scroll])
                             (list 'touchscreen-scroll (selected-window) 0
                                   (* -5 (frame-char-height))))
                    (should vterm-copy-mode)
                    (should (< (window-start) before))
                    (should (string-match-p "Output paused"
                                            (emacsos-pinephone-vterm-history-label)))
                    ;; Native copy-mode RET exits too, without losing dtach keys.
                    (vterm-copy-mode-done nil)
                    (should-not vterm-copy-mode)
                    (should (eq (current-local-map) terminal-map))
                    (should (eq (key-binding [3 68])
                                #'dtach-shell-reconnect))
                    (should (equal (reverse keys) '("<stop>" "<start>")))
                    (should (equal vterm-mode-map shared-map)))
                (advice-remove 'vterm-send-key capture)))))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (delete-process vterm--process))
        (kill-buffer buffer)))))

(ert-deftest emacsos-phone-vterm-copy-pauses-real-pty-output-until-live ()
  (let* ((directory (make-temp-file "phone-history-pty-" t))
         (script (expand-file-name "producer.py" directory))
         (gate (expand-file-name "gate" directory))
         (state (expand-file-name "state" directory))
         (vterm-shell (format "python3 %s %s" (shell-quote-argument script)
                              (shell-quote-argument directory)))
         (vterm-kill-buffer-on-exit nil)
         (vterm-timer-delay nil)
         buffer)
    (unwind-protect
        (save-window-excursion
          (write-region
           (concat "import pathlib,sys\n"
                   "d=pathlib.Path(sys.argv[1])\n"
                   "for i in range(200): print(f'History {i:03}')\n"
                   "print('READY',flush=True)\n"
                   "with (d/'gate').open() as f: f.read(1)\n"
                   "(d/'state').write_text('attempt')\n"
                   "print('RESUMED',flush=True)\n"
                   "(d/'state').write_text('done')\n")
           nil script nil 'silent)
          (should (zerop (call-process "mkfifo" nil nil nil gate)))
          (vterm " *phone-history-pty*")
          (setq buffer (current-buffer))
          (emacsos-test-vterm-wait
           (lambda () (save-excursion (goto-char (point-min))
                                     (search-forward "READY" nil t)))
           vterm--process)
          (emacsos-pinephone-vterm-history)
          (should vterm-copy-mode)
          (should (zerop
                   (call-process "timeout" nil nil nil "3" "python3" "-c"
                                 "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('x')"
                                 gate)))
          (emacsos-test-vterm-wait (lambda () (file-exists-p state))
                                  vterm--process)
          (should (equal (with-temp-buffer (insert-file-contents state)
                                          (buffer-string)) "attempt"))
          (should-not (save-excursion (goto-char (point-min))
                                      (search-forward "RESUMED" nil t)))
          (emacsos-pinephone-vterm-history)
          (should-not vterm-copy-mode)
          (emacsos-test-vterm-wait
           (lambda () (save-excursion (goto-char (point-min))
                                     (search-forward "RESUMED" nil t)))
           vterm--process)
          (should (equal (emacsos-pinephone-vterm-history-label) " History ")))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          (when (process-live-p vterm--process) (delete-process vterm--process)))
        (kill-buffer buffer))
      (delete-directory directory t))))

(ert-deftest emacsos-phone-vterm-header-tap-targets-its-window ()
  (let ((vterm-shell "/bin/sh")
        (vterm-kill-buffer-on-exit nil)
        first second)
    (unwind-protect
        (save-window-excursion
          (vterm " *phone-history-first*")
          (setq first (current-buffer))
          (let ((target (selected-window))
                (other (split-window-below)))
            (select-window other)
            (vterm " *phone-history-second*")
            (setq second (current-buffer))
            (emacsos-pinephone-vterm-history-click
             (list 'mouse-1 (list target 'header-line '(0 . 0) 0)))
            (should (eq (selected-window) other))
            (should-not vterm-copy-mode)
            (with-current-buffer first
              (should vterm-copy-mode)
              (emacsos-pinephone-vterm-history))))
      (dolist (buffer (list first second))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer (delete-process vterm--process))
          (kill-buffer buffer))))))

(ert-deftest emacsos-phone-vterm-touch-dispatch-uses-target-not-selected-buffer ()
  (let ((vterm-shell "/bin/sh") (vterm-kill-buffer-on-exit nil)
        terminal (ordinary (generate-new-buffer " *phone-history-ordinary*")))
    (unwind-protect
        (save-window-excursion
          (vterm " *phone-history-target*")
          (setq terminal (current-buffer))
          (let ((tw (selected-window)) (ow (split-window-below)))
            (set-window-buffer ow ordinary)
            (dolist (buffer (list terminal ordinary))
              (with-current-buffer buffer
                (let ((inhibit-read-only t))
                  (if (eq buffer terminal)
                      (progn
                        (vterm--write-input vterm--term
                                            (apply #'concat (make-list 200 "History line\r\n")))
                        (vterm--redraw vterm--term))
                    (insert (apply #'concat (make-list 200 "Ordinary line\n")))))
                (goto-char (point-min)) (forward-line 100)))
            (dolist (target (list tw ow))
              (set-window-point target (with-current-buffer (window-buffer target) (point)))
              (set-window-start target (window-point target)))
            (dolist (target (list tw ow))
              (let* ((selected (if (eq target tw) ow tw))
                     (before (window-start target))
                     (event (list 'touchscreen-scroll target 0 (* -5 (frame-char-height))))
                     (touch-screen-current-tool (list nil target nil 'scroll nil 0 0 0 0))
                     (touch-screen-precision-scroll nil))
                (select-window selected)
                (let* ((unread-command-events (list event))
                       (keys (read-key-sequence-vector nil)))
                  (funcall (key-binding keys) event))
                (should (eq (selected-window) selected))
                (should (< (window-start target) before))))
            (with-current-buffer terminal
              (should vterm-copy-mode)
              (emacsos-pinephone-vterm-history))))
      (when (buffer-live-p terminal)
        (with-current-buffer terminal (delete-process vterm--process))
        (kill-buffer terminal))
      (kill-buffer ordinary))))

;;; test-pinephone-vterm-history.el ends here
