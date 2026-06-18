;;; phone-call.el --- deterministic cellular call primitives -*- lexical-binding: t; -*-

;; The DETERMINISTIC primitive layer for phone calls (see README "Layers").
;; `emacos-call' takes a concrete phone NUMBER and dials it via the SIM7600
;; modem; `emacos-hang-up' ends the current call.  Same number in -> same
;; action out: no name lookup, no confirmation, no agent callback.
;;
;; Name resolution ("call Pierre" -> a number), disambiguation, and
;; confirmation are NOT done here -- that is the agent's interpretive job (the
;; `call' skill), or a user-facing picker.  Both the user (interactively) and
;; the agent (via eval_elisp, e.g. (emacos-call "+14155550123")) drive these
;; same primitives.

(defconst emacos-call--number-re "\\`\\+?[0-9]\\{5,15\\}\\'"
  "A dialable phone number: optional leading + then 5-15 digits.
Guards the deterministic primitive so a stray name/letter can never
reach mmcli.")

(defun emacos-call--mmcli (&rest args)
  "Run \"mmcli ARGS\" as root (passwordless sudo), capturing output.
Return a cons (EXIT-CODE . TRIMMED-OUTPUT).  mmcli voice control needs
root via polkit when emacs runs without a login session."
  (with-temp-buffer
    (let ((code (apply #'call-process "sudo" nil t nil "-n" "mmcli" args)))
      (cons code (string-trim (buffer-string))))))

(defun emacos-call--modem-index ()
  "Return the modem's numeric index as a string, or nil if none present.
Resolved fresh each call because the SIM7600 re-enumerates under load
and its index changes."
  (let ((out (cdr (emacos-call--mmcli "-L"))))
    (when (string-match "/Modem/\\([0-9]+\\)" out)
      (match-string 1 out))))

;;;###autoload
(defun emacos-call (number)
  "Place a cellular voice call to NUMBER (E.164, e.g. \"+14155550123\").
DETERMINISTIC primitive: dials exactly NUMBER -- no name lookup, no
confirmation.  Returns a status string: \"dialing: <call-path>\" on
success, else \"error: <reason>\".  Callable interactively (prompts for a
number) and by the agent via eval_elisp."
  (interactive "sNumber to call (+E164): ")
  (let ((status
         (if (not (string-match-p emacos-call--number-re number))
             (format "error: invalid number: %s" number)
           (let ((m (emacos-call--modem-index)))
             (if (not m)
                 "error: no modem found"
               (let* ((create (cdr (emacos-call--mmcli
                                    "-m" m
                                    (format "--voice-create-call=number=%s" number))))
                      ;; Use the FULL /org/.../Call/N path: mmcli segfaults on
                      ;; a truncated path (see docs/2026-06-18-call-audio.org).
                      (path (when (string-match
                                   "/org/freedesktop/ModemManager1/Call/[0-9]+"
                                   create)
                              (match-string 0 create))))
                 (cond
                  ((not path) (format "error: could not create call: %s" create))
                  ((zerop (car (emacos-call--mmcli "-o" path "--start")))
                   (format "dialing: %s" path))
                  (t (emacos-call--mmcli "-o" path "--hangup")
                     (format "error: dial failed (modem not registered?) for %s"
                             path)))))))))
    (when (called-interactively-p 'interactive) (message "%s" status))
    status))

;;;###autoload
(defun emacos-hang-up ()
  "End the current cellular call.  DETERMINISTIC primitive.
Returns \"hung-up: ...\" or \"error: ...\"."
  (interactive)
  (let* ((m (emacos-call--modem-index))
         (status
          (cond
           ((not m) "error: no modem found")
           ((zerop (car (emacos-call--mmcli "-m" m "--voice-hangup-all")))
            "hung-up: all calls ended")
           (t "error: hangup failed (no active call?)"))))
    (when (called-interactively-p 'interactive) (message "%s" status))
    status))

(provide 'phone-call)
;;; phone-call.el ends here
