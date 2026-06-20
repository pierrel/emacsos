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

;; D-Bus is OPTIONAL: it powers only inbound DETECTION.  Outbound (emacos-call
;; / emacos-hang-up) and answering (emacos-answer, raw AT) work without it.
;; Soft-require so the file still loads on an Emacs built without D-Bus; the
;; watcher + property reads are fboundp-guarded so a missing D-Bus just means
;; "no incoming-call screen", never a load/boot failure.
(require 'dbus nil t)

;; Defined in os.el (which `require's this file at its end, so these are
;; bound at load time); declared here to keep a standalone byte-compile clean.
(declare-function emacos--btn "os")
(declare-function emacos--target "os")
(declare-function emacos--render-page "os")
(declare-function emacos--center "os")
(defvar emacos--btn-label-scale)
(defvar emacos--confirm-disarm-functions)
;; Buffer-local on a call buffer: names the keyboard plane os.el paints (the
;; touch control plane is reactive to the top buffer).  Defined in os.el.
(defvar emacos--keyboard-plane)

(defvar emacos-call-at-port "/dev/ttyUSB3"
  "AT command port for voice control, freed from ModemManager via udev.")

(defconst emacos-call--incoming-buffer "*incoming-call*")
(defconst emacos-call--active-buffer "*call*")

(defvar emacos-call--state nil
  "Current call-UI state: nil (no call), `incoming', or `active'.
Drives which top buffer/keyboard plane shows and the modeline call badge.")
(defvar emacos-call--watcher-handles nil
  "Global D-Bus signal registration (Voice.CallAdded); nil = unarmed.")
(defvar emacos-call--state-handle nil
  "Per-call Call.StateChanged registration for the current call; drives the
answered→active transition and dismissal.  CallDeleted does not fire promptly
on this modem, so we key off the call's own state (4 active / 7 terminated).")
(defvar emacos-call--call-path nil "Object path of the current call (in or out).")
(defvar emacos-call--call-number nil "Number of the current call.")
(defvar emacos-call--prev-buffer nil
  "Pre-call top buffer to restore when the call UI dismisses.")
(defvar emacos-call--answer-confirm-pending nil "Two-tap Accept arm state.")
(defvar emacos-call--hangup-confirm-pending nil "Two-tap Hang-up arm state.")

;;; AT transport on the freed port

(defun emacos-call--at (cmd)
  "Send AT CMD to `emacos-call-at-port'; return the modem's response string,
or \"error: ...\".  Per-call open/close with guaranteed teardown -- a leaked
serial process would make the next open fail device-busy."
  ;; Buffer created OUTERMOST so it is killed even if `make-serial-process'
  ;; itself signals (missing/permission-denied port) before the proc exists.
  (let ((buf (generate-new-buffer " *emacos-at*")))
    (unwind-protect
        (condition-case err
            (let ((proc (make-serial-process
                         :port emacos-call-at-port :speed 115200
                         :coding 'no-conversion :noquery t :buffer buf)))
              (unwind-protect
                  (progn
                    (process-send-string proc (concat cmd "\r"))
                    ;; `accept-process-output' returns on ANY output, so loop
                    ;; and accumulate until a terminal token or the deadline.
                    (let ((deadline (+ (float-time) 2.0)))
                      (catch 'done
                        (while (< (float-time) deadline)
                          (accept-process-output proc 0.3)
                          (when (string-match-p
                                 "OK\\|ERROR\\|NO CARRIER\\|BEGIN"
                                 (with-current-buffer buf (buffer-string)))
                            (throw 'done nil)))))
                    (with-current-buffer buf (buffer-string)))
                (when (process-live-p proc) (delete-process proc))))
          (error (format "error: AT port %s: %s"
                         emacos-call-at-port (error-message-string err))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

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

;;; Call screens (top buffers = CONTEXT only; the controls live in the
;;; keyboard plane — the keyboard is the touch control plane, reactive to the
;;; top buffer.  See docs/2026-06-20-call-control-keyboard.org.)

(defun emacos-call--rerender ()
  "Re-render the keyboard plane, when os.el's renderer is loaded.
Guarded so phone-call.el stays usable/testable without os.el."
  (when (fboundp 'emacos--render-page) (emacos--render-page)))

(defun emacos-call--render-incoming (number)
  "Paint the incoming-call TOP buffer for NUMBER (context only — the
Accept/Decline controls are in the keyboard plane).  Return its buffer."
  (let ((buf (get-buffer-create emacos-call--incoming-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "\n  Incoming call\n\n  "
                (if (and number (not (string-empty-p number))) number "Unknown")
                "\n")
        (goto-char (point-min)))
      (setq buffer-read-only t)
      (setq emacos--keyboard-plane #'emacos-call--plane-incoming))
    buf))

(defun emacos-call--render-active (number status)
  "Paint the in-progress *call* TOP buffer for NUMBER with STATUS text
\(\"Calling…\" / \"In progress\"); controls are in the keyboard plane.
Return its buffer."
  (let ((buf (get-buffer-create emacos-call--active-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "\n  Call — " status "\n\n  "
                (if (and number (not (string-empty-p number))) number "Unknown")
                "\n")
        (goto-char (point-min)))
      (setq buffer-read-only t)
      (setq emacos--keyboard-plane #'emacos-call--plane-active))
    buf))

;;; Keyboard planes (paint *keyboard*; run with it as `current-buffer')

(defun emacos-call--plane-button (label action &optional bg)
  "Insert one full-width call-control button (LABEL → ACTION, BG accent)."
  (let* ((win   (get-buffer-window (current-buffer)))
         (win-w (if win (window-body-width win) 20))
         (w     (max 6 (- win-w 2))))
    (emacos--btn (emacos--center label w) action nil emacos--btn-label-scale bg)
    (insert "\n")))

(defun emacos-call--plane-incoming ()
  "Keyboard plane for an incoming call: Decline (top) + Accept (bottom),
spatially separated so a mis-tap toward one can't trigger the other.  Accept
is two-tap (arms → \"Confirm answer?\")."
  (insert "\n")
  (emacos-call--plane-button "Decline" #'emacos-call--decline)
  (insert "\n\n\n")
  (emacos-call--plane-button
   (if emacos-call--answer-confirm-pending "Confirm answer?" "Accept")
   #'emacos-call--answer-tap
   (and emacos-call--answer-confirm-pending "firebrick4")))

(defun emacos-call--plane-active ()
  "Keyboard plane for an in-progress call: Hang up (two-tap) + Back."
  (insert "\n")
  (emacos-call--plane-button
   (if emacos-call--hangup-confirm-pending "Confirm hang up?" "Hang up")
   #'emacos-call--hangup-tap
   (and emacos-call--hangup-confirm-pending "firebrick4"))
  (insert "\n\n\n")
  (emacos-call--plane-button "Back" #'emacos-call--back))

;;; Show / back / dismiss

(defun emacos-call--capture-prev (w)
  "Capture the pre-call top buffer of window W ONCE (so dismiss can restore
it).  Never captures a call buffer — e.g. the incoming→*call* swap keeps the
ORIGINAL pre-call buffer."
  (unless (buffer-live-p emacos-call--prev-buffer)
    (let ((cur (window-buffer w)))
      (unless (member (buffer-name cur)
                      (list emacos-call--incoming-buffer emacos-call--active-buffer))
        (setq emacos-call--prev-buffer cur)))))

(defun emacos-call--show-buffer (buf)
  "Show call BUF in the top window + re-render the keyboard plane."
  (let ((w (and (fboundp 'emacos--target) (emacos--target))))
    (when w
      (emacos-call--capture-prev w)
      (unless (eq (window-buffer w) buf)
        (set-window-buffer w buf))
      (emacos-call--rerender))))

(defun emacos-call-show-incoming (number)
  "Show the incoming-call screen for NUMBER."
  (setq emacos-call--answer-confirm-pending nil)
  (emacos-call--show-buffer (emacos-call--render-incoming number)))

(defun emacos-call--show-active (status)
  "Show the in-progress *call* screen (STATUS text) for the current number."
  (setq emacos-call--hangup-confirm-pending nil)
  (emacos-call--show-buffer
   (emacos-call--render-active emacos-call--call-number status)))

(defun emacos-call--back ()
  "Leave the *call* screen for the pre-call buffer; the call KEEPS RUNNING.
The keyboard reverts to T9 and the modeline call badge appears (tap it to
return).  No-op'd if the *call* screen isn't the one showing."
  (setq emacos-call--hangup-confirm-pending nil)
  (let ((w (and (fboundp 'emacos--target) (emacos--target)))
        (prev (if (buffer-live-p emacos-call--prev-buffer)
                  emacos-call--prev-buffer
                (get-buffer-create "*scratch*"))))
    (when (and w (eq (window-buffer w) (get-buffer emacos-call--active-buffer)))
      (set-window-buffer w prev))
    (emacos-call--rerender)))

(defun emacos-call--dismiss ()
  "End the call UI: drop the per-call watch, clear state, restore the pre-call
buffer, kill the call buffers, drop the badge.  Idempotent."
  (when emacos-call--state-handle
    (ignore-errors (dbus-unregister-object emacos-call--state-handle))
    (setq emacos-call--state-handle nil))
  (setq emacos-call--state nil
        emacos-call--call-path nil
        emacos-call--call-number nil
        emacos-call--answer-confirm-pending nil
        emacos-call--hangup-confirm-pending nil)
  (let* ((w (and (fboundp 'emacos--target) (emacos--target)))
         (prev (if (buffer-live-p emacos-call--prev-buffer)
                   emacos-call--prev-buffer
                 (get-buffer-create "*scratch*"))))
    (setq emacos-call--prev-buffer nil)
    (when (and w (memq (window-buffer w)
                       (list (get-buffer emacos-call--incoming-buffer)
                             (get-buffer emacos-call--active-buffer))))
      (set-window-buffer w prev))
    (dolist (name (list emacos-call--incoming-buffer emacos-call--active-buffer))
      (when (get-buffer name) (kill-buffer name)))
    (emacos-call--rerender)))

;;; Tap handlers (call the deterministic primitives)

(defun emacos-call--answer-tap ()
  "Two-tap Accept: first tap arms; second answers and flips to the in-progress
screen (or dismisses on answer failure)."
  (if emacos-call--answer-confirm-pending
      (progn
        (setq emacos-call--answer-confirm-pending nil)
        (let ((r (emacos-answer)))
          (message "%s" r)
          ;; Belt-and-suspenders: flip to in-progress on a confirmed answer,
          ;; rather than depending solely on the active D-Bus signal.
          (if (string-prefix-p "answered:" r)
              (progn (setq emacos-call--state 'active)
                     (emacos-call--show-active "In progress"))
            (emacos-call--dismiss))))
    (setq emacos-call--answer-confirm-pending t)
    (emacos-call--rerender)))

(defun emacos-call--decline ()
  "Decline the ringing call (single tap): hang up + dismiss."
  (setq emacos-call--answer-confirm-pending nil)
  (message "%s" (emacos-hang-up))
  (emacos-call--dismiss))

(defun emacos-call--hangup-tap ()
  "Two-tap Hang up: first tap arms; second ends the call + dismisses."
  (if emacos-call--hangup-confirm-pending
      (progn
        (setq emacos-call--hangup-confirm-pending nil)
        (message "%s" (emacos-hang-up))
        (emacos-call--dismiss))
    (setq emacos-call--hangup-confirm-pending t)
    (emacos-call--rerender)))

(defun emacos-call--maybe-disarm (action _arg)
  "Disarm a pending two-tap (Accept or Hang-up) on any tap that isn't its own
arming button.  Registered on `emacos--confirm-disarm-functions'."
  (let (changed)
    (when (and emacos-call--answer-confirm-pending
               (not (eq action #'emacos-call--answer-tap)))
      (setq emacos-call--answer-confirm-pending nil changed t))
    (when (and emacos-call--hangup-confirm-pending
               (not (eq action #'emacos-call--hangup-tap)))
      (setq emacos-call--hangup-confirm-pending nil changed t))
    (when changed (emacos-call--rerender))))

(add-hook 'emacos--confirm-disarm-functions #'emacos-call--maybe-disarm)

;;; Modeline call badge (return to a backgrounded call)

(defconst emacos-call--mode-line-keymap
  (let ((m (make-sparse-keymap)))
    (define-key m [mode-line mouse-1] #'emacos-call--show-active-again)
    m)
  "Keymap for the tappable call badge (built once; the :eval runs each redisplay).")

(defun emacos-call--show-active-again ()
  "Re-show the *call* screen (from the modeline badge)."
  (interactive)
  (when (eq emacos-call--state 'active)
    (emacos-call--show-active "In progress")))

(defun emacos-call-mode-line-string ()
  "Modeline segment: a tappable \"● Call\" badge while a call is `active' AND
the *call* screen is hidden (you tapped Back).  Empty otherwise.  Wrapped so a
redisplay-time error can never brick the modeline."
  (condition-case nil
      (if (and (eq emacos-call--state 'active)
               (not (get-buffer-window emacos-call--active-buffer)))
          (concat " " (propertize "● Call"
                                  'local-map emacos-call--mode-line-keymap
                                  'mouse-face 'mode-line-highlight
                                  'help-echo "In a call — tap to return"))
        "")
    (error "")))

;;; Detection (ModemManager Voice D-Bus signals)

(defun emacos-call--call-prop (path prop)
  "Read PROP from the ModemManager Call object at PATH (D-Bus, no sudo)."
  (when (fboundp 'dbus-get-property)
    (ignore-errors
      (dbus-get-property :system "org.freedesktop.ModemManager1" path
                         "org.freedesktop.ModemManager1.Call" prop))))

(defun emacos-call--on-call-added (path &rest _)
  "Handle Voice.CallAdded for a call at PATH (MMCallDirection: 1 incoming,
2 outgoing).  Incoming → the incoming screen; outgoing → the in-progress
*call* screen (\"Calling…\").  Registers a per-call StateChanged watch for the
answered/connected/terminated transitions."
  (let ((dir (emacos-call--call-prop path "Direction")))
    (when (memq dir '(1 2))
      (setq emacos-call--call-path path
            emacos-call--call-number (or (emacos-call--call-prop path "Number") ""))
      (emacos-call--watch-call-end path)
      (if (eq dir 1)
          (progn (setq emacos-call--state 'incoming)
                 (emacos-call-show-incoming emacos-call--call-number))
        (setq emacos-call--state 'active)
        (emacos-call--show-active "Calling…")))))

(defun emacos-call--on-call-state (_old new _reason)
  "Drive the call UI from the watched call's state.
4 = active → in-progress screen (covers inbound-answered AND outbound-
connected); 7 = terminated → dismiss.  On active we refresh the *call* screen
only if it (or the incoming screen) is showing — a backgrounded call (you
tapped Back) is left alone; the modeline badge already reflects it.  Other
states are ignored.  Used instead of Voice.CallDeleted, which does not fire
promptly on this modem."
  (cond
   ((eq new 4)
    (setq emacos-call--state 'active)
    (cond
     ((get-buffer-window emacos-call--incoming-buffer)
      (emacos-call--show-active "In progress"))   ; answered → swap incoming→*call*
     ((get-buffer-window emacos-call--active-buffer)
      (emacos-call--render-active emacos-call--call-number "In progress")
      (emacos-call--rerender))))                   ; outbound ringing → connected
   ((eq new 7) (emacos-call--dismiss))))

(defun emacos-call--watch-call-end (path)
  "Watch the call at PATH so the screen auto-dismisses when it ends.
Replaces any prior watch (single call at a time)."
  (when (fboundp 'dbus-register-signal)
    (when emacos-call--state-handle
      (ignore-errors (dbus-unregister-object emacos-call--state-handle)))
    ;; ignore-errors: a registration failure (bus hiccup / MM mid-restart) must
    ;; not throw out of the CallAdded handler — the screen still shows, it just
    ;; loses auto-dismiss (the user can still Decline).
    (setq emacos-call--state-handle
          (ignore-errors
            (dbus-register-signal
             :system "org.freedesktop.ModemManager1" path
             "org.freedesktop.ModemManager1.Call" "StateChanged"
             #'emacos-call--on-call-state)))))

(defun emacos-call--watcher-ensure ()
  "Subscribe to Voice.CallAdded (idempotent; safe across hot-reload).  The
nil-path match is path-independent, so it keeps firing after the modem object
path changes on re-enumeration.  Per-call StateChanged (for dismissal) is
registered dynamically in `emacos-call--watch-call-end'.  No-op without D-Bus
(inbound detection off; outbound/answer still work)."
  (when (and (not emacos-call--watcher-handles) (fboundp 'dbus-register-signal))
    ;; condition-case: os.el calls this at boot, so a system-bus/service that
    ;; isn't ready yet must NOT take down init -- honor the "never a boot
    ;; failure" promise above (inbound just stays off until re-armed).
    (condition-case err
        (setq emacos-call--watcher-handles
              (list
               (dbus-register-signal
                :system "org.freedesktop.ModemManager1" nil
                "org.freedesktop.ModemManager1.Modem.Voice" "CallAdded"
                #'emacos-call--on-call-added)))
      (error (setq emacos-call--watcher-handles nil)
             (message "emacos-call: inbound watcher unavailable: %s"
                      (error-message-string err))))))

(defun emacos-call--watcher-stop ()
  "Unsubscribe the incoming-call signals (dev/debug affordance)."
  (interactive)
  (dolist (h emacos-call--watcher-handles) (ignore-errors (dbus-unregister-object h)))
  (when emacos-call--state-handle (ignore-errors (dbus-unregister-object emacos-call--state-handle)))
  (setq emacos-call--watcher-handles nil emacos-call--state-handle nil))

(provide 'phone-call)
;;; phone-call.el ends here
