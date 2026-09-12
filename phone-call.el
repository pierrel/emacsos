;;; phone-call.el --- deterministic cellular call primitives -*- lexical-binding: t; -*-

;; The DETERMINISTIC primitive layer for phone calls (see README "Layers").
;; `emacsos-call' takes a concrete phone NUMBER and stages it in the local
;; two-tap call UI.  The ordinary public flow invokes the private dial transport,
;; which defaults to the original SIM7600 path; `emacsos-hang-up' ends the current
;; call.  Same number in -> same staged target out: no lookup or agent callback.
;;
;; Name resolution ("call Ana" -> a number) and disambiguation are the agent's
;; interpretive job (the `call' skill), or a user-facing picker.  Authorization
;; is local and deterministic: the agent may create the proposal, but the
;; visible Call control must be activated twice before the modem is touched.

(defconst emacsos-call--number-re "\\`\\+?[0-9]\\{5,15\\}\\'"
  "A dialable phone number: optional leading + then 5-15 digits.
Guards the deterministic primitive so a stray name/letter can never
reach a modem-control backend.")

(defconst emacsos-call--path-re
  "\\`/org/freedesktop/ModemManager1/Call/[0-9]+\\'"
  "Exact ModemManager call-object path accepted from helpers and D-Bus.")

;; Defined with their full documentation in the UI-state section below; these
;; declarations keep the transport primitives above it byte-compile clean.
(defvar emacsos-call--state)
(defvar emacsos-call--call-number)
(defvar emacsos-call--call-path)
(defvar emacsos-call--pending-operation)
(defvar emacsos-call--operation-identity :unbound
  "Internal authorization for the exact already-created UI operation.")

(defcustom emacsos-call-operation-function nil
  "Optional platform call operation function.
When non-nil it is called as (FUNCTION OP OWNER VALUE COMPLETION), where OP is
`dial', `answer', or `hangup'.  OWNER is the captured platform-service identity
for the operation, or nil for a global recovery hangup.  VALUE is a validated
number, the tracked call object path, or nil.  Every operation receives
COMPLETION: an asynchronous backend returns a status beginning \"pending:\" and
later calls COMPLETION once with its terminal status, while a synchronous
backend ignores it and returns that status directly.  Dial success is exactly
\"dialing: /org/.../Call/N\".
Failures begin \"error:\"; a created call whose cleanup failed uses the exact
\"error: uncertain-call-path=/org/.../Call/N; DETAIL\" grammar.  nil retains the
SIM7600 transport implemented here."
  :type '(choice (const :tag "SIM7600 transport" nil) function)
  :group 'emacsos)

(defcustom emacsos-call-audio-function nil
  "Optional function selecting call audio for non-nil, normal audio for nil."
  :type '(choice (const nil) function)
  :group 'emacsos)

(defcustom emacsos-call-wake-function nil
  "Optional function used to illuminate the display on an incoming call."
  :type '(choice (const nil) function)
  :group 'emacsos)

(defcustom emacsos-call-control-gap-lines 3
  "Blank lines between the two call controls.
The roomy default preserves the original EmacsOS phone layout.  A platform
with a separate on-screen keyboard can reduce the gap so both controls remain
visible in its shorter Emacs control pane."
  :type 'natnum
  :group 'emacsos)

(defun emacsos-call--audio (active)
  "Ask the platform to set call-audio ACTIVE, without breaking the call UI."
  (when emacsos-call-audio-function
    (condition-case err
        (funcall emacsos-call-audio-function active)
      (error (message "emacsos-call: audio routing failed: %s"
                      (error-message-string err))))))

(defun emacsos-call--platform-operation
    (operation owner value &optional completion)
  "Run platform OPERATION for OWNER and VALUE with optional COMPLETION."
  (condition-case err
      (let ((status (funcall emacsos-call-operation-function
                             operation owner value completion)))
        (if (stringp status) status "error: call backend returned no status"))
    (error (format "error: call backend failed: %s" (error-message-string err)))))

(defun emacsos-call--mmcli (&rest args)
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

(defun emacsos-call--modem-index ()
  "Resolve the modem's numeric index, fresh (the SIM7600 re-enumerates
under load and its index changes).  Return the index as a string; or an
\"error: ...\" status string that distinguishes a DENIED mmcli
(passwordless sudo / polkit not configured) from a genuinely ABSENT
modem, so a sudo regression isn't misreported as \"no modem\".  Callers
pass an \"error:\"-prefixed return straight through."
  (let* ((r (emacsos-call--mmcli "-L"))
         (code (car r)) (out (cdr r)))
    (cond
     ((string-match "/Modem/\\([0-9]+\\)" out) (match-string 1 out))
     ((and (not (zerop code)) (string-match-p "sudo\\|password" out))
      "error: mmcli unavailable (passwordless sudo not configured?)")
     (t "error: no modem found"))))

(defun emacsos-call--status-detail (detail fallback)
  "Return bounded, one-line DETAIL, or FALLBACK when DETAIL is empty."
  (let ((clean (replace-regexp-in-string
                "[\r\n\t ]+" " " (string-trim (or detail "")))))
    (if (string-empty-p clean)
        fallback
      (truncate-string-to-width clean 4096 nil nil "…"))))

(defun emacsos-call--dial-start-failure (path start)
  "Attempt to clean up PATH after failed START; preserve cleanup uncertainty."
  (let* ((cleanup (emacsos-call--mmcli "-o" path "--hangup"))
         (start-detail (emacsos-call--status-detail
                        (cdr start) "mmcli --start failed")))
    (if (zerop (car cleanup))
        (format "error: call-path=%s; dial failed: %s" path start-detail)
      (format (concat "error: uncertain-call-path=%s; "
                      "dial failed: %s; cleanup failed: %s")
              path start-detail
              (emacsos-call--status-detail
               (cdr cleanup) "mmcli --hangup failed")))))

(defun emacsos-call--dial (number &optional completion owner)
  "Dial validated NUMBER through the private transport.
COMPLETION is passed to the platform backend.  A synchronous backend ignores
it and returns a terminal \"dialing:\" / \"error:\" status; an asynchronous backend
returns \"pending:\" and invokes it later.  Public and agent code stages calls
with `emacsos-call'.  OWNER is the platform-service identity captured before a
confirmed dial begins."
  (let ((status
         (if (not (and (stringp number)
                       (string-match-p emacsos-call--number-re number)))
             (format "error: invalid number: %s" number)
           (if emacsos-call-operation-function
               (progn
                 (emacsos-call--audio t)
                 (emacsos-call--platform-operation
                  'dial owner number completion))
             (let ((m (emacsos-call--modem-index)))
               (if (string-prefix-p "error:" m)
                   m
                 (let* ((create (cdr (emacsos-call--mmcli
                                      "-m" m
                                      (format "--voice-create-call=number=%s" number))))
                        ;; Use the FULL /org/.../Call/N path: mmcli segfaults on
                        ;; a truncated path (see the call-audio findings doc).
                        (path (when (string-match
                                     "/org/freedesktop/ModemManager1/Call/[0-9]+"
                                     create)
                                (match-string 0 create))))
                   (if (not path)
                       (format "error: could not create call: %s"
                               (emacsos-call--status-detail
                                create "mmcli create failed"))
                     (let ((start (emacsos-call--mmcli "-o" path "--start")))
                       (if (zerop (car start))
                           (format "dialing: %s" path)
                         ;; --start failed: drop the orphaned (created-but-
                         ;; unstarted) call object, then surface mmcli's ACTUAL
                         ;; reason rather than a fixed guess.
                         (emacsos-call--dial-start-failure
                          path start)))))))))))
    status))

;;;###autoload
(defun emacsos-call (number)
  "Stage a local two-tap call proposal for concrete NUMBER.
NUMBER is validated here and again by the private transport.  This command
never dials.  Return \"confirmation-required:\" when the proposal is shown,
or \"error:\" without changing an in-progress call."
  (interactive "sNumber to call (+E164): ")
  (let ((status (emacsos-call--stage number)))
    (when (called-interactively-p 'interactive) (message "%s" status))
    status))

;;;###autoload
(defun emacsos-hang-up (&optional completion)
  "End the current cellular call.  DETERMINISTIC primitive.
Return \"pending: ...\" for an asynchronous platform backend, otherwise
\"hung-up: ...\" or \"error: ...\".  Invoke optional COMPLETION with the
terminal asynchronous result."
  (interactive)
  (let* ((blocked (and emacsos-call--pending-operation
                       (not (equal emacsos-call--operation-identity
                                   emacsos-call--pending-operation))))
         (tracked (or (and (eq emacsos-call--state 'incoming)
                           emacsos-call--call-path)
                      (eq emacsos-call--state 'active)))
         (path (and tracked emacsos-call--call-path))
         (identity (and emacsos-call-operation-function
                        (null completion)
                        (not blocked)
                        tracked
                        (emacsos-call--begin-operation 'hangup)))
         (finish (or completion
                     (and identity
                          (lambda (result)
                            (emacsos-call--hangup-finished identity result)))))
         (status
          (cond
           (emacsos-call-operation-function
            (cond
             (blocked
              "error: call operation already pending")
             ((not tracked) "error: no tracked call")
             (t (emacsos-call--platform-operation
                 'hangup (and path emacsos-call--call-owner) path finish))))
           (t
            (let ((m (emacsos-call--modem-index)))
              (if (string-prefix-p "error:" m)
                  m
                (let ((result
                       (emacsos-call--mmcli "-m" m "--voice-hangup-all")))
                  (if (zerop (car result))
                      "hung-up: all calls ended"
                    (format "error: hangup failed: %s"
                            (emacsos-call--status-detail
                             (cdr result) "no active call?"))))))))))
    (when identity
      (emacsos-call--finish-unless-pending status finish))
    (when (called-interactively-p 'interactive) (message "%s" status))
    status))

;;; ------------------------------------------------------------------
;;; Inbound: detect (D-Bus) -> screen -> platform answer / decline
;;; ------------------------------------------------------------------
;; The legacy SIM7600 transport answers through raw AT because its
;; ModemManager QMI accept path is broken ("InvalidQosId").  A configured
;; platform backend may answer differently.  DETECTION rides ModemManager: the Voice
;; `CallAdded' D-Bus signal + the call's properties (no sudo to read).
;; See docs/2026-06-18-inbound-answering.org.

;; D-Bus is OPTIONAL only for the legacy SIM7600 transport: it powers inbound
;; DETECTION there, while legacy outbound and raw-AT answer work without it.
;; The PinePhone platform backend requires ModemManager's unique D-Bus owner
;; and tracked call path for exact dial, answer, hangup, and state verification.
;; Soft-require so the file still loads on an Emacs built without D-Bus; the
;; watcher + property reads are fboundp-guarded so a missing D-Bus just means
;; "no incoming-call screen", never a load/boot failure.
(require 'dbus nil t)

;; Defined in os.el (which `require's this file at its end, so these are
;; bound at load time); declared here to keep a standalone byte-compile clean.
(declare-function emacsos--btn "os")
(declare-function emacsos--target "os")
(declare-function emacsos--render-page "os")
(declare-function emacsos--center "os")
(defvar emacsos--btn-label-scale)
(defvar emacsos--confirm-disarm-functions)
;; Names the keyboard plane os.el paints (the touch control plane is reactive
;; to the top buffer).  Canonically defined in os.el; declared `defvar-local'
;; here too so the call-screen renderers' `setq' stays buffer-local even if
;; this file is loaded before/without os.el (byte-compile, standalone tests) —
;; idempotent with os.el's identical declaration on device.
(defvar-local emacsos--keyboard-plane nil)

(defvar emacsos-call-at-port "/dev/ttyUSB3"
  "AT command port for voice control, freed from ModemManager via udev.")

(defconst emacsos-call--incoming-buffer "*incoming-call*")
(defconst emacsos-call--active-buffer "*call*")
(defconst emacsos-call--confirm-timeout-seconds 15
  "Seconds allowed between the two outgoing-call confirmation actions.")

(defvar emacsos-call--state nil
  "Current call-UI state.
Values are nil, `proposed', `dial-requested', `failed', `incoming', or
`active', plus transient `terminated' while an answer or hangup helper releases
its exclusion token after the carrier ends the call.  Drives the top buffer,
keyboard plane, and call badge.")
(defvar emacsos-call--watcher-handles nil
  "Global D-Bus signal registrations; nil means inbound detection is unarmed.")
(defvar emacsos-call--call-added-handle nil
  "Persistent CallAdded registration with callback-side unique-owner checks.")
(defvar emacsos-call--sms-added-handle nil
  "Persistent received-SMS registration with callback-side owner checks.")
(defvar emacsos-call--owner-watch-handle nil
  "Exact bus-daemon NameOwnerChanged registration for ModemManager.")
(defconst emacsos-call--watcher-topology-version 3
  "Persistent wildcard signal topology with callback-side owner/path checks.")
(defvar emacsos-call--installed-watcher-topology nil
  "Watcher topology currently installed in this Emacs process.")
(defvar emacsos-call--current-owner nil
  "Cached unique ModemManager owner maintained by the owner watch.")
(defvar emacsos-call--owner-generation 0
  "Monotonic identity invalidating work captured before an owner change.")
(defvar emacsos-call--state-handle nil
  "Persistent wildcard Call.StateChanged registration.
The callback accepts only the exact current ModemManager owner and tracked
call path.  CallDeleted does not fire promptly on this modem, so state 4 drives
the active transition and state 7 drives dismissal.")
(defvar emacsos-call--watched-call nil
  "Exact (OWNER . PATH) accepted by the persistent StateChanged callback.")
(defvar emacsos-call--call-path nil "Object path of the current call (in or out).")
(defvar emacsos-call--call-owner nil
  "Unique D-Bus owner for the tracked call or pathless recovery state.")
(defvar emacsos-call--call-number nil
  "Number of the current proposal, attempt, failure, or call.")
(defvar emacsos-call--prev-buffer nil
  "Pre-call top buffer to restore when the call UI dismisses.")
(defvar emacsos-call--next-proposal-id 0
  "Monotonic identity source for outgoing call proposals.")
(defvar emacsos-call--proposal-id nil
  "Identity of the current proposed or requested outgoing call.")
(defvar emacsos-call--dial-confirm-id nil
  "Proposal identity armed by the first outgoing Call activation.")
(defvar emacsos-call--dial-confirm-timer nil
  "Timer that expires `emacsos-call--dial-confirm-id'.")
(defvar emacsos-call--skip-next-post-command-disarm nil
  "Non-nil immediately after arming, so that same command may finish first.")
(defvar emacsos-call--failure-reason nil
  "Terminal reason for the current failed call attempt.")
(defvar emacsos-call--ignored-call-path nil
  "Failed helper path whose next matching delayed CallAdded is ignored.")
(defvar emacsos-call--ignored-call-owner nil
  "D-Bus unique owner paired with `emacsos-call--ignored-call-path'.")
(defvar emacsos-call--requested-call-events nil
  "At most four trusted (OWNER . PATH) events seen while dialing was pending.")
(defvar emacsos-call--deferred-call-event nil
  "Newest (OWNER . PATH) event held while an answer or hangup helper runs.")
(defvar emacsos-call--property-owner nil
  "Dynamically bound unique D-Bus owner for call-property reads.")
(defvar emacsos-call--next-operation-id 0
  "Monotonic identity source for asynchronous answer and hangup operations.")
(defvar emacsos-call--pending-operation nil
  "Current asynchronous operation as (ID OP PATH STATE OWNER), or nil.")
(defvar emacsos-call--answer-confirm-pending nil "Two-tap Accept arm state.")
(defvar emacsos-call--hangup-confirm-pending nil "Two-tap Hang-up arm state.")

;;; AT transport on the freed port

(defun emacsos-call--at (cmd)
  "Send AT CMD to `emacsos-call-at-port'; return the modem's response string,
or \"error: ...\".  Per-call open/close with guaranteed teardown -- a leaked
serial process would make the next open fail device-busy."
  ;; Buffer created OUTERMOST so it is killed even if `make-serial-process'
  ;; itself signals (missing/permission-denied port) before the proc exists.
  (let ((buf (generate-new-buffer " *emacsos-at*")))
    (unwind-protect
        (condition-case err
            (let ((proc (make-serial-process
                         :port emacsos-call-at-port :speed 115200
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
                         emacsos-call-at-port (error-message-string err))))
      (when (buffer-live-p buf) (kill-buffer buf)))))

;;; Answer (deterministic primitive)

;;;###autoload
(defun emacsos-answer (&optional completion)
  "Answer the ringing call through the configured platform operation.
The legacy transport sends `ATA' on the freed AT port because ModemManager's
QMI accept is broken on the SIM7600 modem.
Return \"pending: ...\" for an asynchronous platform backend, otherwise
\"answered: ...\" or \"error: ...\".  Invoke optional COMPLETION with the
terminal asynchronous result."
  (interactive)
  (let* ((blocked (and emacsos-call--pending-operation
                       (not (equal emacsos-call--operation-identity
                                   emacsos-call--pending-operation))))
         (tracked (and (eq emacsos-call--state 'incoming)
                       emacsos-call--call-owner
                       emacsos-call--call-path))
         (identity
          (and emacsos-call-operation-function
               (null completion)
               (not blocked)
               tracked
               (emacsos-call--begin-operation 'answer)))
         (finish
          (or completion
              (and identity
                   (lambda (result)
                     (emacsos-call--answer-finished identity result)))))
         (status
          (if emacsos-call-operation-function
              (cond
               (blocked
                "error: call operation already pending")
               ((not tracked) "error: no tracked incoming call")
               (t
                (when (or completion identity) (emacsos-call--audio t))
                (emacsos-call--platform-operation
                 'answer emacsos-call--call-owner
                 emacsos-call--call-path finish)))
            (let ((resp (emacsos-call--at "ATA")))
              (cond ((string-prefix-p "error:" resp) resp)
                    ((string-match-p "NO CARRIER\\|ERROR" resp)
                     (format "error: answer failed: %s" (string-trim resp)))
                    ((string-match-p "BEGIN\\|OK" resp) "answered: call active")
                    (t (format "error: answer unconfirmed: %s"
                               (string-trim resp))))))))
    (when identity
      (emacsos-call--finish-unless-pending status finish))
    (when (called-interactively-p 'interactive) (message "%s" status))
    status))

;;; Call screens (top buffers = CONTEXT only; the controls live in the
;;; keyboard plane — the keyboard is the touch control plane, reactive to the
;;; top buffer.  See docs/2026-06-20-call-control-keyboard.org.)

(defun emacsos-call--rerender ()
  "Re-render the keyboard plane, when os.el's renderer is loaded.
Guarded so phone-call.el stays usable/testable without os.el."
  (when (fboundp 'emacsos--render-page) (emacsos--render-page)))

(defun emacsos-call--render-incoming (number)
  "Paint the incoming-call TOP buffer for NUMBER (context only — the
Accept/Decline controls are in the keyboard plane).  Return its buffer."
  (let ((buf (get-buffer-create emacsos-call--incoming-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "\n  Incoming call\n\n  "
                (if (and number (not (string-empty-p number))) number "Unknown")
                "\n")
        (goto-char (point-min)))
      (setq buffer-read-only t)
      (setq emacsos--keyboard-plane #'emacsos-call--plane-incoming))
    buf))

(defun emacsos-call--render-call (heading number plane &optional detail)
  "Paint the shared *call* buffer with HEADING, NUMBER, PLANE, and DETAIL."
  (let ((buf (get-buffer-create emacsos-call--active-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "\n  " heading "\n\n  "
                (if (and number (not (string-empty-p number))) number "Unknown")
                "\n")
        (when detail (insert "\n  " detail "\n"))
        (goto-char (point-min)))
      (setq buffer-read-only t)
      (setq emacsos--keyboard-plane plane))
    buf))

(defun emacsos-call--render-proposal (number)
  "Paint a local outgoing-call proposal for NUMBER."
  (emacsos-call--render-call "Call?" number #'emacsos-call--plane-proposed))

(defun emacsos-call--render-requested (number)
  "Paint the non-cancellable pending call attempt for NUMBER."
  (emacsos-call--render-call
   "Starting call…" number #'emacsos-call--plane-dial-requested))

(defun emacsos-call--render-failed (number reason)
  "Paint a persistent failed-call surface for NUMBER.
REASON is whitespace-normalized and bounded for display."
  (let ((bounded (truncate-string-to-width
                  (replace-regexp-in-string "[\r\n\t ]+" " " reason)
                  160 nil nil "…")))
    (emacsos-call--render-call
     "Call failed" number #'emacsos-call--plane-failed bounded)))

(defun emacsos-call--render-active (number status)
  "Paint the active call buffer for NUMBER with STATUS text."
  (emacsos-call--render-call
   (concat "Call — " status) number #'emacsos-call--plane-active))

;;; Keyboard planes (paint *keyboard*; run with it as `current-buffer')

(defun emacsos-call--plane-button (label action &optional bg)
  "Insert one full-width call-control button (LABEL → ACTION, BG accent)."
  (let* ((win   (get-buffer-window (current-buffer)))
         (win-w (if win (window-body-width win) 20))
         (w     (max 6 (- win-w 2))))
    (emacsos--btn (emacsos--center label w) action nil emacsos--btn-label-scale bg)
    (insert "\n")))

(defun emacsos-call--plane-incoming ()
  "Keyboard plane for an incoming call: Decline (top) + Accept (bottom),
spatially separated so a mis-tap toward one can't trigger the other.  Accept
is two-tap (arms → \"Confirm answer?\")."
  (if emacsos-call--pending-operation
      (insert (if (eq (cadr emacsos-call--pending-operation) 'answer)
                  "\n\n  Answering…\n"
                "\n\n  Ending call…\n"))
    (insert "\n")
    (emacsos-call--plane-button "Decline" #'emacsos-call--decline)
    (insert (make-string emacsos-call-control-gap-lines ?\n))
    (emacsos-call--plane-button
     (if emacsos-call--answer-confirm-pending "Confirm answer?" "Accept")
     #'emacsos-call--answer-tap
     (and emacsos-call--answer-confirm-pending "firebrick4"))))

(defun emacsos-call--plane-proposed ()
  "Keyboard plane for an outgoing proposal: Cancel plus two-tap Call."
  (insert "\n")
  (emacsos-call--plane-button "Cancel" #'emacsos-call--cancel-proposal)
  (insert (make-string emacsos-call-control-gap-lines ?\n))
  (emacsos-call--plane-button
   (if emacsos-call--dial-confirm-id "Confirm call?" "Call")
   #'emacsos-call--dial-tap
   (and emacsos-call--dial-confirm-id "firebrick4")))

(defun emacsos-call--plane-dial-requested ()
  "Keyboard plane while the dial request is being issued or pending."
  (insert "\n\n  Starting call…\n"))

(defun emacsos-call--plane-failed ()
  "Keyboard plane for a persistent failed-call result."
  (insert "\n")
  (emacsos-call--plane-button "Dismiss" #'emacsos-call--dismiss-failure))

(defun emacsos-call--plane-active ()
  "Keyboard plane for an in-progress call: Hang up (two-tap) + Back."
  (if emacsos-call--pending-operation
      (insert "\n\n  Ending call…\n")
    (insert "\n")
    (emacsos-call--plane-button
     (if emacsos-call--hangup-confirm-pending "Confirm hang up?" "Hang up")
     #'emacsos-call--hangup-tap
     (and emacsos-call--hangup-confirm-pending "firebrick4"))
    (insert (make-string emacsos-call-control-gap-lines ?\n))
    (emacsos-call--plane-button "Back" #'emacsos-call--back)))

;;; Show / back / dismiss

(defun emacsos-call--capture-prev (w)
  "Capture the pre-call top buffer of window W ONCE (so dismiss can restore
it).  Never captures a call buffer — e.g. the incoming→*call* swap keeps the
ORIGINAL pre-call buffer."
  (unless (buffer-live-p emacsos-call--prev-buffer)
    (let ((cur (window-buffer w)))
      (unless (member (buffer-name cur)
                      (list emacsos-call--incoming-buffer emacsos-call--active-buffer))
        (setq emacsos-call--prev-buffer cur)))))

(defun emacsos-call--show-buffer (buf)
  "Show call BUF in the top window and re-render; return that window."
  (let ((w (and (fboundp 'emacsos--target) (emacsos--target))))
    (when w
      (emacsos-call--capture-prev w)
      (unless (eq (window-buffer w) buf)
        (set-window-buffer w buf))
      (emacsos-call--rerender)
      w)))

(defun emacsos-call-show-incoming (number)
  "Show the incoming-call screen for NUMBER."
  (setq emacsos-call--answer-confirm-pending nil)
  (emacsos-call--show-buffer (emacsos-call--render-incoming number)))

(defun emacsos-call--show-active (status)
  "Show the in-progress *call* screen (STATUS text) for the current number."
  (setq emacsos-call--hangup-confirm-pending nil)
  (emacsos-call--show-buffer
   (emacsos-call--render-active emacsos-call--call-number status)))

(defun emacsos-call--cancel-dial-confirm-timer ()
  "Cancel and clear the outgoing confirmation timer."
  (when (timerp emacsos-call--dial-confirm-timer)
    (cancel-timer emacsos-call--dial-confirm-timer))
  (setq emacsos-call--dial-confirm-timer nil))

(defun emacsos-call--clear-dial-confirm (&optional rerender)
  "Clear the outgoing confirmation arm.
When RERENDER is non-nil and a proposal remains, repaint its Call label."
  (emacsos-call--cancel-dial-confirm-timer)
  (setq emacsos-call--dial-confirm-id nil
        emacsos-call--skip-next-post-command-disarm nil)
  (when (and rerender (eq emacsos-call--state 'proposed))
    (emacsos-call--rerender)))

(defun emacsos-call--proposal-visible-p ()
  "Return non-nil when the current proposal owns the top call surface."
  (let ((w (and (fboundp 'emacsos--target) (emacsos--target))))
    (and w
         (eq (window-buffer w) (get-buffer emacsos-call--active-buffer)))))

(defun emacsos-call--show-proposal ()
  "Show the current outgoing proposal."
  (emacsos-call--show-buffer
   (emacsos-call--render-proposal emacsos-call--call-number)))

(defun emacsos-call--show-requested ()
  "Show the non-cancellable current dial attempt."
  (emacsos-call--show-buffer
   (emacsos-call--render-requested emacsos-call--call-number)))

(defun emacsos-call--show-failed ()
  "Show the current persistent dial failure."
  (emacsos-call--show-buffer
   (emacsos-call--render-failed
    emacsos-call--call-number
    (or emacsos-call--failure-reason "call helper failed"))))

(defun emacsos-call--stage (number)
  "Validate NUMBER and stage a fresh, unarmed outgoing proposal."
  ;; A public command between the two local taps always invalidates the arm,
  ;; even when its new argument is rejected before replacing the proposal.
  (when (eq emacsos-call--state 'proposed)
    (emacsos-call--clear-dial-confirm t))
  (cond
   ((not (and (stringp number)
              (string-match-p emacsos-call--number-re number)))
    (format "error: invalid number: %s" number))
   ((memq emacsos-call--state '(dial-requested incoming active))
    "error: call already in progress")
   (t
    (setq emacsos-call--next-proposal-id (1+ emacsos-call--next-proposal-id)
          emacsos-call--proposal-id emacsos-call--next-proposal-id
          emacsos-call--state 'proposed
          emacsos-call--call-path nil
          emacsos-call--call-owner nil
          emacsos-call--call-number number
          emacsos-call--failure-reason nil)
    (if (emacsos-call--show-proposal)
        "confirmation-required: confirm on phone"
      (emacsos-call--dismiss)
      "error: call UI unavailable"))))

(defun emacsos-call--parse-dial-status (status)
  "Parse terminal dial STATUS as (KIND PATH DETAIL).
KIND is `dialing', `uncertain', or `error'.  PATH is present only when the
root helper returned an exact ModemManager call path."
  (let ((call-path-re "/org/freedesktop/ModemManager1/Call/[0-9]+"))
    (cond
     ((and (stringp status)
           (string-match (format "\\`dialing: \\(%s\\)\\'" call-path-re) status))
      (list 'dialing (match-string 1 status) nil))
     ((and (stringp status)
           (string-match
            (format "\\`error: uncertain-call-path=\\(%s\\); \\(.+\\)\\'"
                    call-path-re)
            status))
      (list 'uncertain (match-string 1 status) (match-string 2 status)))
     ((and (stringp status)
           (string-match "\\`error: uncertain-call; \\(.+\\)\\'" status))
      (list 'uncertain nil (match-string 1 status)))
     ((and (stringp status)
           (string-match
            (format "\\`error: call-path=\\(%s\\); \\(.+\\)\\'" call-path-re)
            status))
      (list 'error (match-string 1 status) (match-string 2 status)))
     ((and (stringp status) (string-prefix-p "error:" status))
      (list 'error nil (string-trim (substring status (length "error:")))))
     (t (list 'error nil "call helper returned an invalid result")))))

(defun emacsos-call--adopt-outgoing-path
    (path number owner &optional activate-audio default-status
          observed-state snapshot-known-p)
  "Adopt outgoing PATH from OWNER for NUMBER without blocking Emacs input.
ACTIVATE-AUDIO selects call audio for an externally created call.
DEFAULT-STATUS defaults to \"Calling…\".  SNAPSHOT-KNOWN-P says OBSERVED-STATE
came from a CallAdded snapshot whose immutable sender matched the current
unique owner.  An asynchronous snapshot closes the path-adoption gap and
verifies direction and number."
  (setq emacsos-call--call-path path
        emacsos-call--call-owner owner
        emacsos-call--call-number number
        emacsos-call--state 'active)
  (emacsos-call--watch-call-end path owner)
  (if snapshot-known-p
      (emacsos-call--render-outgoing-state
       path owner observed-state activate-audio default-status)
    (when activate-audio (emacsos-call--audio t))
    (emacsos-call--show-active (or default-status "Calling…")))
  (let ((owner-generation emacsos-call--owner-generation))
    (emacsos-call--call-snapshot-async
     owner path
     (lambda (snapshot)
       (when (and (= owner-generation emacsos-call--owner-generation)
                  (eq emacsos-call--state 'active)
                  (equal emacsos-call--call-path path)
                  (equal emacsos-call--call-owner owner))
         (if (and snapshot
                  (eq (nth 0 snapshot) 2)
                  (emacsos-call--same-number-p number (nth 2 snapshot)))
             (emacsos-call--render-outgoing-state
              path owner (nth 1 snapshot) nil default-status)
           (emacsos-call--show-unverified-call nil owner)))))))

(defun emacsos-call--render-outgoing-state
    (path owner state activate-audio default-status)
  "Render owner-bound outgoing PATH in STATE without reading D-Bus."
  (when (and (eq emacsos-call--state 'active)
             (equal emacsos-call--call-path path)
             (equal emacsos-call--call-owner owner))
    (cond
     ((eq state 7)
      (emacsos-call--on-call-state nil 7 nil))
     ((not (memq state '(0 1 2 3 4 5 6)))
      (emacsos-call--show-unverified-call activate-audio owner))
     ((eq state 4)
      (when activate-audio (emacsos-call--audio t))
      (emacsos-call--show-active "In progress"))
     (t
      (when activate-audio (emacsos-call--audio t))
      (emacsos-call--show-active (or default-status "Calling…"))))))

(defun emacsos-call--same-number-p (left right)
  "Return non-nil when LEFT and RIGHT differ only by a leading plus."
  (and (stringp left)
       (stringp right)
       (equal (string-remove-prefix "+" left)
              (string-remove-prefix "+" right))))

(defun emacsos-call--show-unverified-call (&optional activate-audio owner)
  "Keep global Hang up available when a call path cannot be trusted.
OWNER, when known, is retained as a stale-generation marker so a same-owner
CallAdded event cannot silently replace this uncertain call."
  (setq emacsos-call--watched-call nil)
  (setq emacsos-call--call-path nil
        emacsos-call--call-owner owner
        emacsos-call--state 'active)
  (when activate-audio (emacsos-call--audio t))
  (emacsos-call--show-active "Status unknown"))

(defun emacsos-call--extra-requested-event-p (events owner &optional path)
  "Return non-nil when EVENTS has an OWNER event other than optional PATH."
  (seq-some (lambda (event)
              (and (equal (car event) owner)
                   (not (equal (cdr event) path))))
            events))

(defun emacsos-call--dial-finished
    (proposal-id operation-owner status &optional owner-generation)
  "Apply dial STATUS to PROPOSAL-ID from OPERATION-OWNER.
OWNER-GENERATION, when supplied by the live path, must still match."
  (when (and (eq emacsos-call--state 'dial-requested)
             (equal proposal-id emacsos-call--proposal-id))
    (let* ((parsed (emacsos-call--parse-dial-status status))
           (kind (nth 0 parsed))
           (path (nth 1 parsed))
           (detail (nth 2 parsed))
           (events emacsos-call--requested-call-events))
      (cond
       ((and owner-generation
             (/= owner-generation emacsos-call--owner-generation))
        (setq emacsos-call--requested-call-events nil)
        (emacsos-call--show-unverified-call nil operation-owner)
        (message "emacsos-call: ModemManager restarted during dial"))
       ((eq kind 'dialing)
        (when (equal emacsos-call--ignored-call-path path)
          (setq emacsos-call--ignored-call-path nil
                emacsos-call--ignored-call-owner nil))
        (setq emacsos-call--requested-call-events nil)
        (if (emacsos-call--extra-requested-event-p
             events operation-owner path)
            (emacsos-call--show-unverified-call nil operation-owner)
          ;; The trusted root helper created and started this exact path under
          ;; OPERATION-OWNER.  Registration-gap verification is asynchronous.
          (emacsos-call--adopt-outgoing-path
           path emacsos-call--call-number operation-owner))
        (message "%s" status))
       ((eq kind 'uncertain)
        ;; --start may have taken effect before timing out, and the helper
        ;; could not prove cleanup.  Keep call audio plus Hang up available.
        (setq emacsos-call--requested-call-events nil)
        (if (and path
                 (not (emacsos-call--extra-requested-event-p
                       events operation-owner path)))
            (emacsos-call--adopt-outgoing-path
             path emacsos-call--call-number operation-owner nil
             "Status unknown")
          (emacsos-call--show-unverified-call nil operation-owner))
        (message "emacsos-call: call status unknown; hang up to ensure it ends"))
       (t
        (let* ((failed-path path)
               (unseen-path
                (and failed-path
                     (not (member (cons operation-owner failed-path) events))
                     failed-path))
               (owner (and unseen-path operation-owner)))
          (setq emacsos-call--requested-call-events nil)
          (if (emacsos-call--extra-requested-event-p
               events operation-owner failed-path)
              (emacsos-call--show-unverified-call nil operation-owner)
            (progn
            (emacsos-call--audio nil)
            (setq emacsos-call--state 'failed
                  emacsos-call--call-path nil
                  emacsos-call--call-owner nil
                  emacsos-call--ignored-call-path (and owner unseen-path)
                  emacsos-call--ignored-call-owner owner
                  emacsos-call--failure-reason detail)
            (emacsos-call--show-failed)
            (message "emacsos-call: %s" emacsos-call--failure-reason)))))))))

(defun emacsos-call--back ()
  "Leave the *call* screen for the pre-call buffer; the call KEEPS RUNNING.
The keyboard reverts to T9 and the modeline call badge appears (tap it to
return).  Only reachable from the active plane's Back button, so *call* is
the showing buffer — the buffer-restore is guarded regardless; the disarm +
re-render always run."
  (setq emacsos-call--hangup-confirm-pending nil)
  (let ((w (and (fboundp 'emacsos--target) (emacsos--target)))
        (prev (if (buffer-live-p emacsos-call--prev-buffer)
                  emacsos-call--prev-buffer
                (get-buffer-create "*scratch*"))))
    (when (and w (eq (window-buffer w) (get-buffer emacsos-call--active-buffer)))
      (set-window-buffer w prev))
    (emacsos-call--rerender)))

(defun emacsos-call--dismiss ()
  "End the call UI: clear tracked-call identity, restore the pre-call
buffer, kill the call buffers, drop the badge.  Idempotent."
  (emacsos-call--clear-dial-confirm)
  (setq emacsos-call--state nil
        emacsos-call--watched-call nil
        emacsos-call--call-path nil
        emacsos-call--call-owner nil
        emacsos-call--call-number nil
        emacsos-call--proposal-id nil
        emacsos-call--failure-reason nil
        emacsos-call--requested-call-events nil
        emacsos-call--pending-operation nil
        emacsos-call--answer-confirm-pending nil
        emacsos-call--hangup-confirm-pending nil)
  (let* ((w (and (fboundp 'emacsos--target) (emacsos--target)))
         (prev (if (buffer-live-p emacsos-call--prev-buffer)
                   emacsos-call--prev-buffer
                 (get-buffer-create "*scratch*"))))
    (setq emacsos-call--prev-buffer nil)
    (when (and w (memq (window-buffer w)
                       (list (get-buffer emacsos-call--incoming-buffer)
                             (get-buffer emacsos-call--active-buffer))))
      (set-window-buffer w prev))
    (dolist (name (list emacsos-call--incoming-buffer emacsos-call--active-buffer))
      (when (get-buffer name) (kill-buffer name)))
    (emacsos-call--rerender)))

;;; Tap handlers (call the deterministic primitives)

(defun emacsos-call--expire-dial-confirm (proposal-id)
  "Expire the arm only when it still belongs to PROPOSAL-ID."
  (when (and (eq emacsos-call--state 'proposed)
             (equal proposal-id emacsos-call--proposal-id)
             (equal proposal-id emacsos-call--dial-confirm-id))
    (setq emacsos-call--dial-confirm-timer nil
          emacsos-call--dial-confirm-id nil
          emacsos-call--skip-next-post-command-disarm nil)
    (emacsos-call--rerender)))

(defun emacsos-call--arm-dial ()
  "Arm the current visible proposal for one next local action."
  (emacsos-call--cancel-dial-confirm-timer)
  (setq emacsos-call--dial-confirm-id emacsos-call--proposal-id
        emacsos-call--skip-next-post-command-disarm t
        emacsos-call--dial-confirm-timer
        (run-at-time emacsos-call--confirm-timeout-seconds nil
                     #'emacsos-call--expire-dial-confirm
                     emacsos-call--proposal-id))
  (emacsos-call--rerender))

(defun emacsos-call--dial-tap ()
  "Two-tap outgoing Call action bound to one visible proposal identity."
  (cond
   ((not (and (eq emacsos-call--state 'proposed)
              emacsos-call--proposal-id
              (emacsos-call--proposal-visible-p)))
    (emacsos-call--clear-dial-confirm t)
    (message "emacsos-call: proposal is no longer visible"))
   ((equal emacsos-call--dial-confirm-id emacsos-call--proposal-id)
    (let ((proposal-id emacsos-call--proposal-id)
          (number emacsos-call--call-number))
      ;; Consume the local authorization before launching the backend.  The
      ;; owner comes from the exact watch cache, so this input path does not
      ;; wait on D-Bus.
      (emacsos-call--clear-dial-confirm)
      (setq emacsos-call--state 'dial-requested
            emacsos-call--requested-call-events nil)
      (emacsos-call--show-requested)
      (let* ((operation-owner emacsos-call--current-owner)
             (owner-generation emacsos-call--owner-generation)
             (finish (lambda (result)
                       (emacsos-call--dial-finished
                        proposal-id operation-owner result owner-generation))))
        (emacsos-call--finish-unless-pending
         (emacsos-call--dial number finish operation-owner)
         finish))))
   (t (emacsos-call--arm-dial))))

(defun emacsos-call--cancel-proposal ()
  "Dismiss the current proposal without touching the modem."
  (when (eq emacsos-call--state 'proposed)
    (emacsos-call--dismiss)))

(defun emacsos-call--dismiss-failure ()
  "Acknowledge and dismiss the persistent failed-call surface."
  (when (eq emacsos-call--state 'failed)
    (emacsos-call--dismiss)))

(defun emacsos-call--post-command-disarm ()
  "Make an armed outgoing call expire after the next unrelated command."
  (when emacsos-call--dial-confirm-id
    (if emacsos-call--skip-next-post-command-disarm
        (setq emacsos-call--skip-next-post-command-disarm nil)
      (emacsos-call--clear-dial-confirm t))))

(add-hook 'post-command-hook #'emacsos-call--post-command-disarm)

(defun emacsos-call--begin-operation (operation)
  "Mark OPERATION pending for the exact current call; return its identity."
  (setq emacsos-call--next-operation-id (1+ emacsos-call--next-operation-id))
  (let ((identity (list emacsos-call--next-operation-id
                        operation
                        emacsos-call--call-path
                        emacsos-call--state
                        emacsos-call--call-owner)))
    (setq emacsos-call--pending-operation identity
          emacsos-call--answer-confirm-pending nil
          emacsos-call--hangup-confirm-pending nil)
    (emacsos-call--rerender)
    identity))

(defun emacsos-call--operation-current-p (identity)
  "Return non-nil when asynchronous IDENTITY still owns the visible call."
  (and (equal identity emacsos-call--pending-operation)
       (equal (nth 2 identity) emacsos-call--call-path)
       (eq (nth 3 identity) emacsos-call--state)
       (equal (nth 4 identity) emacsos-call--call-owner)))

(defun emacsos-call--finish-unless-pending (status finish)
  "Call FINISH with terminal STATUS; leave asynchronous pending work alone."
  (unless (string-prefix-p "pending:" status)
    (funcall finish status)))

(defun emacsos-call--uncertain-answer-p (status path)
  "Return non-nil when STATUS is an uncertain answer for tracked PATH."
  (and (stringp status)
       (or (string-match-p "\\`error: uncertain-answer; .+\\'" status)
           (and (string-match
                 (concat "\\`error: uncertain-answer-call-path="
                         "\\(/org/freedesktop/ModemManager1/Call/[0-9]+\\); .+\\'")
                 status)
                (equal (match-string 1 status) path)))))

(defun emacsos-call--answer-finished (identity status)
  "Apply terminal answer STATUS only to matching operation IDENTITY."
  (when (emacsos-call--operation-current-p identity)
    (message "%s" status)
    (cond
     ((eq emacsos-call--state 'terminated)
      ;; D-Bus proved the call ended while Accept was still returning.
      (setq emacsos-call--pending-operation nil)
      (emacsos-call--dismiss)
      (emacsos-call--replay-deferred-call-event))
     ((eq emacsos-call--state 'active)
      ;; D-Bus either proved Accept took effect or the owner changed and left
      ;; pathless recovery.  The later helper result releases exclusion but
      ;; cannot restore trust in a lost call object.
      (setq emacsos-call--pending-operation nil)
      (emacsos-call--show-active
       (if emacsos-call--call-path "In progress" "Status unknown"))
      (emacsos-call--replay-deferred-call-event))
     ((string-prefix-p "answered:" status)
      (setq emacsos-call--pending-operation nil
            emacsos-call--state 'active)
      (emacsos-call--show-active "In progress")
      (emacsos-call--replay-deferred-call-event))
     ((emacsos-call--uncertain-answer-p status (nth 2 identity))
      (let ((path (nth 2 identity))
            (owner (nth 4 identity)))
        (emacsos-call--call-snapshot-async
         owner path
         (lambda (snapshot)
           (when (emacsos-call--operation-current-p identity)
             (setq emacsos-call--pending-operation nil)
             (let ((same-call (and (equal path emacsos-call--call-path)
                                   (equal owner emacsos-call--call-owner)))
                   (direction (nth 0 snapshot))
                   (current (nth 1 snapshot)))
               (cond
                ((and same-call (eq direction 1) (eq current 4))
                 (setq emacsos-call--state 'active)
                 (emacsos-call--show-active "In progress"))
                ((and same-call (eq direction 1) (eq current 7))
                 (emacsos-call--audio nil)
                 (emacsos-call--dismiss))
                ((and same-call (eq direction 1)
                      (memq current '(0 1 2 3 5 6)))
                 (emacsos-call--audio nil)
                 (emacsos-call-show-incoming emacsos-call--call-number))
                (t
                 (emacsos-call--show-unverified-call nil owner))))
             (emacsos-call--replay-deferred-call-event))))))
     (t
      (setq emacsos-call--pending-operation nil)
      (emacsos-call--audio nil)
      (emacsos-call-show-incoming emacsos-call--call-number)
      (emacsos-call--replay-deferred-call-event)))))

(defun emacsos-call--hangup-finished (identity status)
  "Apply terminal hangup STATUS only to matching operation IDENTITY."
  (when (emacsos-call--operation-current-p identity)
    (setq emacsos-call--pending-operation nil)
    (message "%s" status)
    (if (or (eq emacsos-call--state 'terminated)
            (string-prefix-p "hung-up:" status))
        (progn
          (emacsos-call--audio nil)
          (emacsos-call--dismiss))
      (if (eq emacsos-call--state 'incoming)
          (emacsos-call-show-incoming emacsos-call--call-number)
        (emacsos-call--show-active "Hang up failed")))
    (emacsos-call--replay-deferred-call-event)))

(defun emacsos-call--answer-tap ()
  "Two-tap Accept: first tap arms; second starts the answer operation.
Terminal helper success or a proven active D-Bus state shows in-progress."
  (if emacsos-call--answer-confirm-pending
      (let* ((identity (emacsos-call--begin-operation 'answer))
             (finish (lambda (result)
                       (emacsos-call--answer-finished identity result))))
        (emacsos-call--finish-unless-pending
         (let ((emacsos-call--operation-identity identity))
           (emacsos-answer finish))
         finish))
    (setq emacsos-call--answer-confirm-pending t)
    (emacsos-call--rerender)))

(defun emacsos-call--decline ()
  "Decline the ringing call; await terminal hangup before dismissing."
  (let* ((identity (emacsos-call--begin-operation 'hangup))
         (finish (lambda (result)
                   (emacsos-call--hangup-finished identity result))))
    (emacsos-call--finish-unless-pending
     (let ((emacsos-call--operation-identity identity))
       (emacsos-hang-up finish))
     finish)))

(defun emacsos-call--hangup-tap ()
  "Two-tap Hang up; dismiss only after the backend confirms success."
  (if emacsos-call--hangup-confirm-pending
      (let* ((identity (emacsos-call--begin-operation 'hangup))
             (finish (lambda (result)
                       (emacsos-call--hangup-finished identity result))))
        (emacsos-call--finish-unless-pending
         (let ((emacsos-call--operation-identity identity))
           (emacsos-hang-up finish))
         finish))
    (setq emacsos-call--hangup-confirm-pending t)
    (emacsos-call--rerender)))

(defun emacsos-call--maybe-disarm (action _arg)
  "Disarm any pending call confirmation on a different button tap.
Registered on `emacsos--confirm-disarm-functions'."
  (let (changed)
    (when (and emacsos-call--dial-confirm-id
               (not (eq action #'emacsos-call--dial-tap)))
      (emacsos-call--clear-dial-confirm)
      (setq changed t))
    (when (and emacsos-call--answer-confirm-pending
               (not (eq action #'emacsos-call--answer-tap)))
      (setq emacsos-call--answer-confirm-pending nil changed t))
    (when (and emacsos-call--hangup-confirm-pending
               (not (eq action #'emacsos-call--hangup-tap)))
      (setq emacsos-call--hangup-confirm-pending nil changed t))
    (when changed (emacsos-call--rerender))))

(add-hook 'emacsos--confirm-disarm-functions #'emacsos-call--maybe-disarm)

;;; Modeline call badge (return to a backgrounded call)

(defconst emacsos-call--mode-line-keymap
  (let ((m (make-sparse-keymap)))
    (define-key m [mode-line mouse-1] #'emacsos-call--badge-tap)
    m)
  "Keymap for the tappable call badge (built once; the :eval runs each redisplay).")

(defun emacsos-call--badge-tap ()
  "Modeline call-badge handler: re-show the backgrounded *call* screen."
  (interactive)
  (when (eq emacsos-call--state 'active)
    (emacsos-call--show-active "In progress")))

(defun emacsos-call-mode-line-string ()
  "Modeline segment: a tappable \"● Call\" badge while a call is `active' AND
the *call* screen is hidden (you tapped Back).  Empty otherwise.  Wrapped so a
redisplay-time error can never brick the modeline."
  (condition-case nil
      (if (and (eq emacsos-call--state 'active)
               (not (get-buffer-window emacsos-call--active-buffer)))
          (concat " " (propertize "● Call"
                                  'local-map emacsos-call--mode-line-keymap
                                  'mouse-face 'mode-line-highlight
                                  'help-echo "In a call — tap to return"))
        "")
    (error "")))

;;; Detection (ModemManager Voice D-Bus signals)

(defun emacsos-call--call-prop (path prop)
  "Read PROP from the ModemManager Call object at PATH (D-Bus, no sudo).
Owner-sensitive callers dynamically bind `emacsos-call--property-owner' to a
unique bus name so a read sequence cannot cross a service restart."
  (when (fboundp 'dbus-get-property)
    (ignore-errors
      (dbus-get-property :system
                         (or emacsos-call--property-owner
                             "org.freedesktop.ModemManager1") path
                         "org.freedesktop.ModemManager1.Call" prop))))

(defun emacsos-call--modem-manager-owner ()
  "Return ModemManager's current unique D-Bus owner, or nil, within 500 ms."
  (when (fboundp 'dbus-call-method)
    (ignore-errors
      (dbus-call-method
       :system "org.freedesktop.DBus" "/org/freedesktop/DBus"
       "org.freedesktop.DBus" "GetNameOwner" :timeout 500
       "org.freedesktop.ModemManager1"))))

(defun emacsos-call--record-requested-event (owner path)
  "Remember trusted OWNER and PATH while bounding pending dial state."
  (let ((event (cons owner path)))
    (setq emacsos-call--requested-call-events
          (delete event emacsos-call--requested-call-events))
    (push event emacsos-call--requested-call-events)
    (when (nthcdr 4 emacsos-call--requested-call-events)
      (setcdr (nthcdr 3 emacsos-call--requested-call-events) nil))))

(defun emacsos-call--defer-call-event (owner path)
  "Retain the newest trusted OWNER/PATH while a root helper owns exclusion."
  (setq emacsos-call--deferred-call-event (cons owner path)))

(defun emacsos-call--replay-deferred-call-event ()
  "Apply the newest deferred CallAdded event after helper exclusion ends."
  (let ((event emacsos-call--deferred-call-event))
    (setq emacsos-call--deferred-call-event nil)
    (when event
      (emacsos-call--on-call-added-async (car event) (cdr event)))))

(defun emacsos-call--adopt-call-snapshot
    (owner path direction observed-state number
           &optional trusted-owner-snapshot)
  "Adopt one owner-bound call snapshot; return non-nil on adoption.
TRUSTED-OWNER-SNAPSHOT means the properties were returned asynchronously by
the exact unique owner, so this function performs no synchronous D-Bus read."
  (let ((stale-owner
         (and emacsos-call--call-owner
              (memq emacsos-call--state '(incoming active))
              (not (equal owner emacsos-call--call-owner)))))
    (when (and (or trusted-owner-snapshot
                   (equal owner (emacsos-call--modem-manager-owner)))
               (memq direction '(1 2))
               (memq observed-state '(0 1 2 3 4 5 6))
               (or (memq emacsos-call--state '(nil proposed failed))
                   stale-owner))
      (when (and stale-owner (eq emacsos-call--state 'active))
        (emacsos-call--audio nil))
      (when emacsos-call--state
        (emacsos-call--dismiss))
      (if (eq direction 2)
          (emacsos-call--adopt-outgoing-path
           path number owner t nil observed-state t)
        (setq emacsos-call--call-path path
              emacsos-call--call-owner owner
              emacsos-call--call-number number
              emacsos-call--state 'incoming)
        ;; Establish a visible surface before any registration/read that can
        ;; dispatch a reentrant StateChanged callback.
        (if (eq observed-state 4)
            (progn
              (setq emacsos-call--state 'active)
              (emacsos-call--audio t)
              (emacsos-call--show-active "In progress"))
          (when emacsos-call-wake-function
            (ignore-errors (funcall emacsos-call-wake-function)))
          (emacsos-call-show-incoming emacsos-call--call-number))
        (emacsos-call--watch-call-end path owner)
        ;; Re-read after adoption to close the transition gap.  The live
        ;; signal path does this asynchronously so modem latency cannot block
        ;; Emacs input; direct/test callers retain the original bounded read.
        (if trusted-owner-snapshot
            (emacsos-call--refresh-adopted-state-async
             owner path observed-state)
          (emacsos-call--refresh-adopted-state
           owner path observed-state)))
      t)))

(defun emacsos-call--snapshot-value (properties name)
  "Return NAME from raw D-Bus GetAll PROPERTIES."
  (let ((entry (assoc name properties)))
    (and entry (caadr entry))))

(defun emacsos-call--call-snapshot-async (owner path completion)
  "Read PATH properties from unique OWNER without blocking the UI loop.
Invoke COMPLETION once with (DIRECTION STATE NUMBER), or nil after failure or
the 750 ms local fallback."
  (let ((done nil)
        fallback)
    (setq fallback
          (run-at-time
           0.75 nil
           (lambda ()
             (unless done
               (setq done t)
               (funcall completion nil)))))
    (condition-case nil
        (dbus-call-method-asynchronously
         :system owner path "org.freedesktop.DBus.Properties" "GetAll"
         (lambda (&rest reply)
           (unless done
             (setq done t)
             (when (timerp fallback) (cancel-timer fallback))
             (let ((properties (car reply)))
               (funcall
                completion
                (and (listp properties)
                     (list (emacsos-call--snapshot-value properties "Direction")
                           (emacsos-call--snapshot-value properties "State")
                           (or (emacsos-call--snapshot-value
                                properties "Number") "")))))))
         :timeout 500 "org.freedesktop.ModemManager1.Call")
      (error
       (when (timerp fallback) (cancel-timer fallback))
       (unless done
         (setq done t)
         (funcall completion nil))))))

(defun emacsos-call--apply-adopted-state (owner path observed-state current)
  "Reconcile CURRENT for an adopted PATH from OWNER against OBSERVED-STATE."
  (let ((effective (if (memq current '(0 1 2 3 4 5 6 7))
                       current observed-state)))
    (when (and (memq emacsos-call--state '(incoming active))
               (equal emacsos-call--call-path path)
               (equal emacsos-call--call-owner owner))
      (cond
       ((eq effective 7) (emacsos-call--on-call-state nil 7 nil))
       ((eq effective 4)
        (unless (eq emacsos-call--state 'active)
          (setq emacsos-call--state 'active)
          (emacsos-call--audio t))
        (emacsos-call--show-active "In progress"))
       ((eq emacsos-call--state 'active)
        (setq emacsos-call--state 'incoming)
        (emacsos-call--audio nil)
        (emacsos-call-show-incoming emacsos-call--call-number))))))

(defun emacsos-call--refresh-adopted-state (owner path observed-state)
  "Synchronously close the direct/test adoption gap for PATH."
  (let ((emacsos-call--property-owner owner)
        (current (emacsos-call--call-prop path "State")))
    (when (equal owner (emacsos-call--modem-manager-owner))
      (emacsos-call--apply-adopted-state owner path observed-state current))))

(defun emacsos-call--refresh-adopted-state-async (owner path observed-state)
  "Asynchronously close the live signal adoption gap for PATH."
  (emacsos-call--call-snapshot-async
   owner path
   (lambda (snapshot)
     (if snapshot
         (emacsos-call--apply-adopted-state
          owner path observed-state (nth 1 snapshot))
       (when (and (memq emacsos-call--state '(incoming active))
                  (equal emacsos-call--call-path path)
                  (equal emacsos-call--call-owner owner))
         (emacsos-call--show-unverified-call nil owner))))))

(defun emacsos-call--apply-call-added-snapshot
    (owner path initial-state initial-path initial-owner snapshot
           &optional trusted-owner-snapshot)
  "Apply one CallAdded SNAPSHOT if its captured UI identity is still current."
  (let ((dir (nth 0 snapshot))
        (observed-state (nth 1 snapshot))
        (number (or (nth 2 snapshot) "")))
    (unless (emacsos-call--adopt-call-snapshot
             owner path dir observed-state number trusted-owner-snapshot)
      (when (and (eq emacsos-call--state initial-state)
                 (equal emacsos-call--call-path initial-path)
                 (equal emacsos-call--call-owner initial-owner)
                 (not (eq emacsos-call--state 'dial-requested))
                 (not (eq observed-state 7))
                 (or (memq dir '(1 2))
                     (not (memq observed-state '(0 1 2 3 4 5 6 7)))))
        (emacsos-call--show-unverified-call nil owner)))))

(defun emacsos-call--consume-ignored-call-event (owner path)
  "Return non-nil and consume an ignored OWNER/PATH event when it matches."
  (when (and emacsos-call--ignored-call-owner
             (not (equal owner emacsos-call--ignored-call-owner)))
    (setq emacsos-call--ignored-call-path nil
          emacsos-call--ignored-call-owner nil))
  (when (and (equal path emacsos-call--ignored-call-path)
             (equal owner emacsos-call--ignored-call-owner))
    (setq emacsos-call--ignored-call-path nil
          emacsos-call--ignored-call-owner nil)
    t))

(defun emacsos-call--on-call-added-async (owner path)
  "Handle live CallAdded PATH from unique OWNER without blocking input."
  (when (and owner
             (equal owner emacsos-call--current-owner)
             (stringp path)
             (string-match-p emacsos-call--path-re path))
    (cond
     (emacsos-call--pending-operation
      (emacsos-call--defer-call-event owner path))
     ((eq emacsos-call--state 'dial-requested)
      (emacsos-call--record-requested-event owner path))
     ((not (emacsos-call--consume-ignored-call-event owner path))
      (let ((initial-state emacsos-call--state)
            (initial-path emacsos-call--call-path)
            (initial-owner emacsos-call--call-owner)
            (owner-generation emacsos-call--owner-generation))
        (when (eq emacsos-call--state 'proposed)
          (emacsos-call--clear-dial-confirm t))
        (emacsos-call--call-snapshot-async
         owner path
         (lambda (snapshot)
           (when (= owner-generation emacsos-call--owner-generation)
             (if snapshot
                 (emacsos-call--apply-call-added-snapshot
                  owner path initial-state initial-path initial-owner snapshot
                  t)
               (when (and (eq emacsos-call--state initial-state)
                          (equal emacsos-call--call-path initial-path)
                          (equal emacsos-call--call-owner initial-owner))
                 (when emacsos-call-wake-function
                   (ignore-errors (funcall emacsos-call-wake-function)))
                 (emacsos-call--show-unverified-call nil owner)))))))))))

(defun emacsos-call--on-call-added-from-owner (owner path)
  "Synchronously handle CallAdded PATH for direct development and tests.
The live persistent subscription verifies its immutable sender, then uses
`emacsos-call--on-call-added-async'."
  (when (and owner
             (stringp path)
             (string-match-p emacsos-call--path-re path))
    ;; This callback is already bound to a unique bus owner.  Record its exact
    ;; identity before GetNameOwner, which can itself dispatch another signal.
    (when (eq emacsos-call--state 'dial-requested)
      (emacsos-call--record-requested-event owner path))
    (let ((initial-state emacsos-call--state)
          (initial-path emacsos-call--call-path)
          (initial-owner emacsos-call--call-owner)
          (current-owner (emacsos-call--modem-manager-owner)))
      ;; The callback is bound to OWNER.  A temporarily unreadable owner still
      ;; breaks local confirmation adjacency; a known different owner is stale.
      (when (and (or (null current-owner) (equal owner current-owner))
                 (eq emacsos-call--state 'proposed))
        (emacsos-call--clear-dial-confirm t))
      (when (and (equal owner current-owner)
                 (not (emacsos-call--consume-ignored-call-event owner path)))
        (let ((emacsos-call--property-owner owner))
          (emacsos-call--apply-call-added-snapshot
           owner path initial-state initial-path initial-owner
           (list (emacsos-call--call-prop path "Direction")
                 (emacsos-call--call-prop path "State")
                 (or (emacsos-call--call-prop path "Number") ""))))))))

(defun emacsos-call--on-call-added (path &rest _)
  "Handle a CallAdded PATH using ModemManager's current unique owner.
The live subscription instead invokes `emacsos-call--on-call-added-async' with
immutable sender metadata; this wrapper remains a direct development and test
entry point."
  (let ((owner (emacsos-call--modem-manager-owner)))
    (when owner
      (emacsos-call--on-call-added-from-owner owner path))))

(defun emacsos-call--on-call-state (_old new _reason)
  "Drive the call UI from the watched call's state.
4 = active → in-progress screen (covers inbound-answered AND outbound-
connected); 7 = terminated → dismiss after any pending helper releases its
exclusion token.  On active we refresh the *call* screen
only if it (or the incoming screen) is showing — a backgrounded call (you
tapped Back) is left alone; the modeline badge already reflects it.  Other
states are ignored.  Used instead of Voice.CallDeleted, which does not fire
promptly on this modem."
  (cond
   ((eq new 4)
    (let ((was-incoming (eq emacsos-call--state 'incoming)))
      (setq emacsos-call--state 'active)
      (when emacsos-call--pending-operation
        ;; Preserve the helper's exclusion token until its sentinel runs while
        ;; moving the identity to the state already proven by D-Bus.
        (setcar (nthcdr 3 emacsos-call--pending-operation) 'active))
      (when was-incoming (emacsos-call--audio t))
      (cond
       ((get-buffer-window emacsos-call--incoming-buffer)
        (emacsos-call--show-active "In progress")) ; answered → swap incoming→*call*
       ((get-buffer-window emacsos-call--active-buffer)
        (emacsos-call--render-active emacsos-call--call-number "In progress")
        (emacsos-call--rerender)))))                ; outbound ringing → connected
   ((eq new 7)
    (when emacsos-call-operation-function (emacsos-call--audio nil))
    ;; A helper still owns the root flock.  Keep its non-interactive pending
    ;; surface until the sentinel reports, so no second mutation can collide.
    (if emacsos-call--pending-operation
        (progn
          (setq emacsos-call--state 'terminated)
          (setcar (nthcdr 3 emacsos-call--pending-operation) 'terminated)
          (emacsos-call--show-active "Ending call…"))
      (emacsos-call--dismiss)))))

(defun emacsos-call--register-signal-bounded (&rest args)
  "Register one D-Bus signal match, failing instead of blocking past 500 ms."
  (with-timeout (0.5 (error "D-Bus signal registration timed out"))
    (apply #'dbus-register-signal args)))

(defun emacsos-call--unregister-signal-bounded (handle)
  "Remove HANDLE without letting D-Bus stall Emacs past 500 ms."
  (when handle
    (with-timeout (0.5 nil)
      (ignore-errors (dbus-unregister-object handle)))))

(defun emacsos-call--watch-call-end (path owner)
  "Select exact OWNER/PATH for the persistent StateChanged subscription.
A still-running helper retains its pending surface until its sentinel runs.
No D-Bus match is added or removed on this live path."
  (setq emacsos-call--watched-call (cons owner path)))

(defun emacsos-call--event-owner ()
  "Return the immutable unique sender of the current D-Bus event."
  (when (and (fboundp 'dbus-event-service-name) last-input-event)
    (ignore-errors (dbus-event-service-name last-input-event))))

(defun emacsos-call--event-path ()
  "Return the object path carried by the current D-Bus event metadata."
  (when (and (fboundp 'dbus-event-path-name) last-input-event)
    (ignore-errors (dbus-event-path-name last-input-event))))

(defun emacsos-call--on-call-state-event (old new reason)
  "Apply a wildcard StateChanged event only to the exact tracked call."
  (let ((owner (emacsos-call--event-owner))
        (path (emacsos-call--event-path)))
    (when (and (equal emacsos-call--watched-call (cons owner path))
               (equal emacsos-call--call-owner owner)
               (equal emacsos-call--call-path path))
      (emacsos-call--on-call-state old new reason))))

(defun emacsos-call--on-sms-added (_path received)
  "Wake the handset for a received SMS from the current ModemManager owner."
  (when (and received emacsos-call-wake-function
             (equal (emacsos-call--event-owner) emacsos-call--current-owner))
    (ignore-errors (funcall emacsos-call-wake-function))))

(defun emacsos-call--register-call-added (owner)
  "Register persistent call signals and accept only current unique OWNER."
  (setq emacsos-call--current-owner owner)
  (setq emacsos-call--sms-added-handle
        (or emacsos-call--sms-added-handle
            (emacsos-call--register-signal-bounded
             :system nil nil
             "org.freedesktop.ModemManager1.Modem.Messaging" "Added"
             #'emacsos-call--on-sms-added)))
  (setq emacsos-call--call-added-handle
        (or emacsos-call--call-added-handle
            (emacsos-call--register-signal-bounded
             :system nil nil
             "org.freedesktop.ModemManager1.Modem.Voice" "CallAdded"
             (lambda (path &rest _)
               (emacsos-call--on-call-added-async
                (emacsos-call--event-owner) path)))))
  (setq emacsos-call--state-handle
        (or emacsos-call--state-handle
            (emacsos-call--register-signal-bounded
             :system nil nil
             "org.freedesktop.ModemManager1.Call" "StateChanged"
             #'emacsos-call--on-call-state-event)))
  (setq emacsos-call--watcher-handles
        (delq nil (list emacsos-call--owner-watch-handle
                        emacsos-call--call-added-handle
                        emacsos-call--state-handle
                        emacsos-call--sms-added-handle))))

(defun emacsos-call--on-owner-changed (name old-owner new-owner)
  "Update accepted call identity when ModemManager NAME changes owner."
  (when (equal name "org.freedesktop.ModemManager1")
    (setq emacsos-call--current-owner
          (unless (string-empty-p new-owner) new-owner)
          emacsos-call--owner-generation
          (1+ emacsos-call--owner-generation)
          emacsos-call--requested-call-events nil)
    (when (equal emacsos-call--ignored-call-owner old-owner)
      (setq emacsos-call--ignored-call-path nil
            emacsos-call--ignored-call-owner nil))
    (when (equal (car-safe emacsos-call--deferred-call-event) old-owner)
      (setq emacsos-call--deferred-call-event nil))
    (when (and old-owner
               (equal emacsos-call--call-owner old-owner)
               (memq emacsos-call--state '(incoming active)))
      (setq emacsos-call--watched-call nil
            emacsos-call--call-path nil
            emacsos-call--call-owner old-owner
            emacsos-call--state 'active)
      ;; The helper may still own the root flock.  Preserve its exclusion
      ;; identity but move it to the conservative pathless state so its
      ;; completion can release the UI without trusting the dead owner.
      (when emacsos-call--pending-operation
        (setcar (nthcdr 2 emacsos-call--pending-operation) nil)
        (setcar (nthcdr 3 emacsos-call--pending-operation) 'active))
      (emacsos-call--show-active "Status unknown"))))

(defun emacsos-call--watcher-ensure ()
  "Subscribe to trusted call, SMS, and ModemManager owner signals.
CallAdded, Added, and StateChanged use persistent sender-wildcard bus matches, then
validate immutable event metadata against the cached unique owner and tracked
path.  Only boot, hot migration, or explicit stop changes bus matches; live
call and owner callbacks never do.  Idempotent and a no-op without D-Bus."
  ;; Hot reload may preserve the older per-owner/per-call match topology.
  ;; Replace it once, invalidating any queued callback identities.
  (when (and emacsos-call--watcher-handles
             (not (equal emacsos-call--installed-watcher-topology
                         emacsos-call--watcher-topology-version)))
    (dolist (handle emacsos-call--watcher-handles)
      (emacsos-call--unregister-signal-bounded handle))
    (setq emacsos-call--watcher-handles nil
          emacsos-call--owner-watch-handle nil
          emacsos-call--call-added-handle nil
          emacsos-call--state-handle nil
          emacsos-call--sms-added-handle nil
          emacsos-call--installed-watcher-topology nil
          emacsos-call--watched-call nil
          emacsos-call--owner-generation (1+ emacsos-call--owner-generation)))
  (when (and (not emacsos-call--watcher-handles)
             (fboundp 'dbus-register-signal))
    ;; condition-case: os.el calls this at boot, so a system-bus/service that
    ;; isn't ready yet must NOT take down init -- honor the "never a boot
    ;; failure" promise above (inbound just stays off until re-armed).
    (condition-case err
        (progn
          (setq emacsos-call--owner-watch-handle
                (emacsos-call--register-signal-bounded
                 :system "org.freedesktop.DBus" "/org/freedesktop/DBus"
                 "org.freedesktop.DBus" "NameOwnerChanged"
                 #'emacsos-call--on-owner-changed
                 :arg0 "org.freedesktop.ModemManager1"))
          (emacsos-call--register-call-added
           (emacsos-call--modem-manager-owner))
          (setq emacsos-call--installed-watcher-topology
                emacsos-call--watcher-topology-version)
          (when (memq emacsos-call--state '(incoming active))
            (if (and emacsos-call--call-owner emacsos-call--call-path)
                (emacsos-call--watch-call-end
                 emacsos-call--call-path emacsos-call--call-owner)
              (emacsos-call--show-unverified-call
               nil emacsos-call--current-owner))))
      (error
       (dolist (handle (delq nil (list emacsos-call--owner-watch-handle
                                      emacsos-call--call-added-handle
                                      emacsos-call--state-handle
                                      emacsos-call--sms-added-handle)))
         (emacsos-call--unregister-signal-bounded handle))
       (setq emacsos-call--watcher-handles nil
             emacsos-call--owner-watch-handle nil
             emacsos-call--call-added-handle nil
             emacsos-call--state-handle nil
             emacsos-call--sms-added-handle nil
             emacsos-call--installed-watcher-topology nil
             emacsos-call--current-owner nil)
       (message "emacsos-call: inbound watcher unavailable: %s"
                (error-message-string err))))))

(defun emacsos-call--watcher-stop ()
  "Unsubscribe all call, SMS, and owner signals (dev/debug affordance)."
  (interactive)
  (dolist (handle emacsos-call--watcher-handles)
    (emacsos-call--unregister-signal-bounded handle))
  (setq emacsos-call--watcher-handles nil
        emacsos-call--owner-watch-handle nil
        emacsos-call--call-added-handle nil
        emacsos-call--current-owner nil
        emacsos-call--state-handle nil
        emacsos-call--sms-added-handle nil
        emacsos-call--installed-watcher-topology nil
        emacsos-call--watched-call nil
        emacsos-call--owner-generation (1+ emacsos-call--owner-generation)
        emacsos-call--ignored-call-path nil
        emacsos-call--ignored-call-owner nil
        emacsos-call--requested-call-events nil
        emacsos-call--deferred-call-event nil))

;; Apply the persistent-filter migration during a development hot reload.
;; Cold boot still arms the watcher from os.el after startup.
(when emacsos-call--watcher-handles
  (emacsos-call--watcher-ensure))

(provide 'phone-call)
;;; phone-call.el ends here
