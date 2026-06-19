;;; phone-call.el --- deterministic cellular call primitives -*- lexical-binding: t; -*-

;; The DETERMINISTIC primitive layer for phone calls (see README "Layers").
;; `emacos-call' takes a concrete phone NUMBER and dials it via the SIM7600
;; modem; `emacos-hang-up' ends the current call.  Same number in -> same
;; action out: no name lookup, no confirmation, no agent callback.
;;
;; Name resolution ("call Ana" -> a number), disambiguation, and
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
root via polkit when emacs runs without a login session.  A failure to
even launch the process (e.g. `sudo' absent / not on PATH) is caught and
returned as a non-zero code with the message, so callers always get a
(code . output) cons and this helper never raises a signal."
  (with-temp-buffer
    (let* ((raw (condition-case err
                    (apply #'call-process "sudo" nil t nil "-n" "mmcli" args)
                  (error (insert (error-message-string err)) 1)))
           ;; call-process returns a descriptive STRING (not an int) when the
           ;; child dies on a signal — e.g. mmcli segfaults. Normalize to a
           ;; non-zero int (and record the description) so callers' arithmetic
           ;; (`zerop' on the code) never sees a non-integer.
           (code (if (integerp raw) raw (progn (insert (format " (%s)" raw)) 1))))
      (cons code (string-trim (buffer-string))))))

(defun emacos-call--modem-index ()
  "Resolve the modem's numeric index, fresh (the SIM7600 re-enumerates
under load and its index changes).  Return the index as a string; or an
\"error: ...\" status string that distinguishes a DENIED mmcli
(passwordless sudo / polkit not configured) from a genuinely ABSENT
modem, so a sudo regression isn't misreported as \"no modem\".  Callers
pass an \"error:\"-prefixed return straight through."
  (let* ((r (emacos-call--mmcli "-L"))
         (code (car r)) (out (cdr r)))
    (cond
     ((string-match "/Modem/\\([0-9]+\\)" out) (match-string 1 out))
     ((and (not (zerop code)) (string-match-p "sudo\\|password" out))
      "error: mmcli unavailable (passwordless sudo not configured?)")
     (t "error: no modem found"))))

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
             (if (string-prefix-p "error:" m)
                 m
               (let* ((create (cdr (emacos-call--mmcli
                                    "-m" m
                                    (format "--voice-create-call=number=%s" number))))
                      ;; Use the FULL /org/.../Call/N path: mmcli segfaults on
                      ;; a truncated path (see the call-audio findings doc).
                      (path (when (string-match
                                   "/org/freedesktop/ModemManager1/Call/[0-9]+"
                                   create)
                              (match-string 0 create))))
                 (if (not path)
                     (format "error: could not create call: %s" create)
                   (let ((start (emacos-call--mmcli "-o" path "--start")))
                     (if (zerop (car start))
                         (format "dialing: %s" path)
                       ;; --start failed: drop the orphaned (created-but-
                       ;; unstarted) call object, then surface mmcli's ACTUAL
                       ;; reason rather than a fixed guess.
                       (emacos-call--mmcli "-o" path "--hangup")
                       (format "error: dial failed: %s"
                               (let ((d (cdr start)))
                                 (if (string= d "") "mmcli --start failed" d))))))))))))
    (when (called-interactively-p 'interactive) (message "%s" status))
    status))

;;;###autoload
(defun emacos-hang-up ()
  "End the current cellular call.  DETERMINISTIC primitive.
Returns \"hung-up: ...\" or \"error: ...\"."
  (interactive)
  (let* ((m (emacos-call--modem-index))
         (status
          (if (string-prefix-p "error:" m)
              m
            (let ((r (emacos-call--mmcli "-m" m "--voice-hangup-all")))
              (if (zerop (car r))
                  "hung-up: all calls ended"
                ;; Often benign (the call already dropped on a mid-call USB
                ;; re-enumeration), but surface mmcli's reason, not a guess.
                (format "error: hangup failed: %s"
                        (let ((d (cdr r)))
                          (if (string= d "") "no active call?" d))))))))
    (when (called-interactively-p 'interactive) (message "%s" status))
    status))

;;; ------------------------------------------------------------------
;;; Inbound: detect (D-Bus) -> screen -> answer (AT) / decline
;;; ------------------------------------------------------------------
;; ModemManager's QMI accept is broken on the SIM7600G-H ("InvalidQosId"),
;; so we ANSWER via raw AT `ATA' on a ModemManager-ignored AT port (a udev
;; rule frees ttyUSB3).  DETECTION still rides ModemManager: the Voice
;; `CallAdded' D-Bus signal + the call's properties (no sudo to read).
;; See docs/2026-06-18-inbound-answering.org.

(require 'dbus)

;; Defined in os.el (which `require's this file at its end, so these are
;; bound at load time); declared here to keep a standalone byte-compile clean.
(declare-function emacos--btn "os")
(declare-function emacos--target "os")
(defvar emacos--btn-label-scale)
(defvar emacos--confirm-disarm-functions)

(defvar emacos-call-at-port "/dev/ttyUSB3"
  "AT command port for voice control, freed from ModemManager via udev.")

(defconst emacos-call--incoming-buffer "*incoming-call*")

(defvar emacos-call--watcher-handles nil
  "Global D-Bus signal registration (Voice.CallAdded); nil = unarmed.")
(defvar emacos-call--state-handle nil
  "Per-call Call.StateChanged registration for the shown call; dismisses the
screen when the caller gives up.  CallDeleted does not fire promptly on this
modem, so we key dismissal on the call's own state going terminated.")
(defvar emacos-call--ringing-path nil "Object path of the call being shown.")
(defvar emacos-call--ringing-number nil "Caller number being shown.")
(defvar emacos-call--prev-buffer nil
  "Top buffer to restore when the incoming screen dismisses.")
(defvar emacos-call--answer-confirm-pending nil "Two-tap Answer arm state.")

;;; AT transport on the freed port

(defun emacos-call--at (cmd)
  "Send AT CMD to `emacos-call-at-port'; return the modem's response string,
or \"error: ...\".  Per-call open/close with guaranteed teardown -- a leaked
serial process would make the next open fail device-busy."
  (condition-case err
      (let* ((buf (generate-new-buffer " *emacos-at*"))
             (proc (make-serial-process
                    :port emacos-call-at-port :speed 115200
                    :coding 'no-conversion :noquery t :buffer buf)))
        (unwind-protect
            (progn
              (process-send-string proc (concat cmd "\r"))
              ;; `accept-process-output' returns on ANY output, so loop and
              ;; accumulate until a terminal token or the deadline.
              (let ((deadline (+ (float-time) 2.0)))
                (catch 'done
                  (while (< (float-time) deadline)
                    (accept-process-output proc 0.3)
                    (when (string-match-p
                           "OK\\|ERROR\\|NO CARRIER\\|BEGIN"
                           (with-current-buffer buf (buffer-string)))
                      (throw 'done nil)))))
              (with-current-buffer buf (buffer-string)))
          (when (process-live-p proc) (delete-process proc))
          (when (buffer-live-p buf) (kill-buffer buf))))
    (error (format "error: AT port %s: %s"
                   emacos-call-at-port (error-message-string err)))))

;;; Answer (deterministic primitive)

;;;###autoload
(defun emacos-answer ()
  "Answer the ringing call.  DETERMINISTIC primitive: sends `ATA' on the
freed AT port (ModemManager's QMI accept is broken on this modem).
Returns \"answered: ...\" or \"error: ...\"."
  (interactive)
  (let* ((resp (emacos-call--at "ATA"))
         (status
          (cond ((string-prefix-p "error:" resp) resp)
                ((string-match-p "NO CARRIER\\|ERROR" resp)
                 (format "error: answer failed: %s" (string-trim resp)))
                ((string-match-p "BEGIN\\|OK" resp) "answered: call active")
                (t (format "error: answer unconfirmed: %s" (string-trim resp))))))
    (when (called-interactively-p 'interactive) (message "%s" status))
    status))

;;; Incoming-call screen (a top buffer, NOT a modal)

(defun emacos-call--render-incoming (number)
  "Paint the incoming-call screen for NUMBER; return its buffer."
  (let ((buf (get-buffer-create emacos-call--incoming-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "\n  Incoming call\n\n  "
                (if (and number (not (string-empty-p number))) number "Unknown")
                "\n\n\n")
        ;; Decline on top, Answer at the bottom -- spatially separated so a
        ;; mis-tap toward one can't trigger the other.
        (emacos--btn "  Decline  " #'emacos-call--decline nil emacos--btn-label-scale)
        (insert "\n\n\n\n\n")
        (emacos--btn (if emacos-call--answer-confirm-pending
                         "  Confirm answer?  " "  Answer  ")
                     #'emacos-call--answer-tap nil emacos--btn-label-scale
                     (and emacos-call--answer-confirm-pending "firebrick4"))
        (goto-char (point-min)))
      (setq buffer-read-only t))
    buf))

(defun emacos-call-show-incoming (number)
  "Show the incoming-call screen for NUMBER in the top window."
  (setq emacos-call--answer-confirm-pending nil)
  (let ((buf (emacos-call--render-incoming number))
        (w (and (fboundp 'emacos--target) (emacos--target))))
    (when (and w (not (eq (window-buffer w) buf)))
      ;; Capture the pre-call buffer ONCE so dismiss can restore it.
      (unless (buffer-live-p emacos-call--prev-buffer)
        (setq emacos-call--prev-buffer (window-buffer w)))
      (set-window-buffer w buf))))

(defun emacos-call--dismiss-incoming ()
  "Tear down the incoming screen and restore the pre-call top buffer."
  (when emacos-call--state-handle
    (ignore-errors (dbus-unregister-object emacos-call--state-handle))
    (setq emacos-call--state-handle nil))
  (setq emacos-call--ringing-path nil
        emacos-call--ringing-number nil
        emacos-call--answer-confirm-pending nil)
  (let* ((w (and (fboundp 'emacos--target) (emacos--target)))
         (buf (get-buffer emacos-call--incoming-buffer))
         (prev (if (buffer-live-p emacos-call--prev-buffer)
                   emacos-call--prev-buffer
                 (get-buffer-create "*scratch*"))))
    (setq emacos-call--prev-buffer nil)
    (when (and w buf (eq (window-buffer w) buf))
      (set-window-buffer w prev))
    (when buf (kill-buffer buf))))

(defun emacos-call--answer-tap ()
  "Two-tap Answer: first tap arms, second tap answers + dismisses."
  (if emacos-call--answer-confirm-pending
      (progn
        (setq emacos-call--answer-confirm-pending nil)
        (message "%s" (emacos-answer))
        (emacos-call--dismiss-incoming))
    (setq emacos-call--answer-confirm-pending t)
    (when (get-buffer emacos-call--incoming-buffer)
      (emacos-call--render-incoming emacos-call--ringing-number))))

(defun emacos-call--decline ()
  "Decline the ringing call (single tap): hang up + dismiss."
  (setq emacos-call--answer-confirm-pending nil)
  (message "%s" (emacos-hang-up))
  (emacos-call--dismiss-incoming))

(defun emacos-call--maybe-disarm (action _arg)
  "Disarm the two-tap Answer on any tap that isn't Answer itself.
Registered on `emacos--confirm-disarm-functions' (the chat.el pattern)."
  (when (and emacos-call--answer-confirm-pending
             (not (eq action #'emacos-call--answer-tap)))
    (setq emacos-call--answer-confirm-pending nil)
    (when (get-buffer emacos-call--incoming-buffer)
      (emacos-call--render-incoming emacos-call--ringing-number))))

(add-hook 'emacos--confirm-disarm-functions #'emacos-call--maybe-disarm)

;;; Detection (ModemManager Voice D-Bus signals)

(defun emacos-call--call-prop (path prop)
  "Read PROP from the ModemManager Call object at PATH (D-Bus, no sudo)."
  (ignore-errors
    (dbus-get-property :system "org.freedesktop.ModemManager1" path
                       "org.freedesktop.ModemManager1.Call" prop)))

(defun emacos-call--on-call-added (path &rest _)
  "Handle Voice.CallAdded: show the screen for an INCOMING call at PATH.
A newly-added incoming call is ringing by definition (MMCallDirection:
1 = incoming)."
  (when (equal (emacos-call--call-prop path "Direction") 1)
    (setq emacos-call--ringing-path path
          emacos-call--ringing-number (or (emacos-call--call-prop path "Number") ""))
    (emacos-call--watch-call-end path)
    (emacos-call-show-incoming emacos-call--ringing-number)))

(defun emacos-call--on-call-state (_old new _reason)
  "Dismiss the incoming screen when the watched call ends.
MMCallState 7 = terminated.  Used instead of Voice.CallDeleted, which does
not fire promptly on this modem — the screen would stick after the caller
gives up."
  (when (eq new 7) (emacos-call--dismiss-incoming)))

(defun emacos-call--watch-call-end (path)
  "Watch the call at PATH so the screen auto-dismisses when it ends.
Replaces any prior watch (single call at a time)."
  (when emacos-call--state-handle
    (ignore-errors (dbus-unregister-object emacos-call--state-handle)))
  (setq emacos-call--state-handle
        (dbus-register-signal
         :system "org.freedesktop.ModemManager1" path
         "org.freedesktop.ModemManager1.Call" "StateChanged"
         #'emacos-call--on-call-state)))

(defun emacos-call--watcher-ensure ()
  "Subscribe to Voice.CallAdded (idempotent; safe across hot-reload).  The
nil-path match is path-independent, so it keeps firing after the modem object
path changes on re-enumeration.  Per-call StateChanged (for dismissal) is
registered dynamically in `emacos-call--watch-call-end'."
  (unless emacos-call--watcher-handles
    (setq emacos-call--watcher-handles
          (list
           (dbus-register-signal
            :system "org.freedesktop.ModemManager1" nil
            "org.freedesktop.ModemManager1.Modem.Voice" "CallAdded"
            #'emacos-call--on-call-added)))))

(defun emacos-call--watcher-stop ()
  "Unsubscribe the incoming-call signals (dev/debug affordance)."
  (interactive)
  (dolist (h emacos-call--watcher-handles) (ignore-errors (dbus-unregister-object h)))
  (when emacos-call--state-handle (ignore-errors (dbus-unregister-object emacos-call--state-handle)))
  (setq emacos-call--watcher-handles nil emacos-call--state-handle nil))

(provide 'phone-call)
;;; phone-call.el ends here
