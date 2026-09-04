;;; phone-call.el --- deterministic cellular call primitives -*- lexical-binding: t; -*-

;; The DETERMINISTIC primitive layer for phone calls (see README "Layers").
;; `emacos-call' takes a concrete phone NUMBER and stages it in the local
;; two-tap call UI.  The ordinary public flow invokes the private dial transport,
;; which defaults to the original SIM7600 path; `emacos-hang-up' ends the current
;; call.  Same number in -> same staged target out: no lookup or agent callback.
;;
;; Name resolution ("call Ana" -> a number) and disambiguation are the agent's
;; interpretive job (the `call' skill), or a user-facing picker.  Authorization
;; is local and deterministic: the agent may create the proposal, but the
;; visible Call control must be activated twice before the modem is touched.

(defconst emacos-call--number-re "\\`\\+?[0-9]\\{5,15\\}\\'"
  "A dialable phone number: optional leading + then 5-15 digits.
Guards the deterministic primitive so a stray name/letter can never
reach a modem-control backend.")

(defconst emacos-call--path-re
  "\\`/org/freedesktop/ModemManager1/Call/[0-9]+\\'"
  "Exact ModemManager call-object path accepted from helpers and D-Bus.")

;; Defined with their full documentation in the UI-state section below; these
;; declarations keep the transport primitives above it byte-compile clean.
(defvar emacos-call--state)
(defvar emacos-call--call-number)
(defvar emacos-call--call-path)
(defvar emacos-call--pending-operation)
(defvar emacos-call--operation-identity :unbound
  "Internal authorization for the exact already-created UI operation.")

(defcustom emacos-call-operation-function nil
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

(defcustom emacos-call-audio-function nil
  "Optional function selecting call audio for non-nil, normal audio for nil."
  :type '(choice (const nil) function)
  :group 'emacsos)

(defcustom emacos-call-wake-function nil
  "Optional function used to illuminate the display on an incoming call."
  :type '(choice (const nil) function)
  :group 'emacsos)

(defcustom emacos-call-control-gap-lines 3
  "Blank lines between the two call controls.
The roomy default preserves the original EmacsOS phone layout.  A platform
with a separate on-screen keyboard can reduce the gap so both controls remain
visible in its shorter Emacs control pane."
  :type 'natnum
  :group 'emacsos)

(defun emacos-call--audio (active)
  "Ask the platform to set call-audio ACTIVE, without breaking the call UI."
  (when emacos-call-audio-function
    (condition-case err
        (funcall emacos-call-audio-function active)
      (error (message "emacos-call: audio routing failed: %s"
                      (error-message-string err))))))

(defun emacos-call--platform-operation
    (operation owner value &optional completion)
  "Run platform OPERATION for OWNER and VALUE with optional COMPLETION."
  (condition-case err
      (let ((status (funcall emacos-call-operation-function
                             operation owner value completion)))
        (if (stringp status) status "error: call backend returned no status"))
    (error (format "error: call backend failed: %s" (error-message-string err)))))

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

(defun emacos-call--status-detail (detail fallback)
  "Return bounded, one-line DETAIL, or FALLBACK when DETAIL is empty."
  (let ((clean (replace-regexp-in-string
                "[\r\n\t ]+" " " (string-trim (or detail "")))))
    (if (string-empty-p clean)
        fallback
      (truncate-string-to-width clean 4096 nil nil "…"))))

(defun emacos-call--dial-start-failure (path start)
  "Attempt to clean up PATH after failed START; preserve cleanup uncertainty."
  (let* ((cleanup (emacos-call--mmcli "-o" path "--hangup"))
         (start-detail (emacos-call--status-detail
                        (cdr start) "mmcli --start failed")))
    (if (zerop (car cleanup))
        (format "error: call-path=%s; dial failed: %s" path start-detail)
      (format (concat "error: uncertain-call-path=%s; "
                      "dial failed: %s; cleanup failed: %s")
              path start-detail
              (emacos-call--status-detail
               (cdr cleanup) "mmcli --hangup failed")))))

(defun emacos-call--dial (number &optional completion owner)
  "Dial validated NUMBER through the private transport.
COMPLETION is passed to the platform backend.  A synchronous backend ignores
it and returns a terminal \"dialing:\" / \"error:\" status; an asynchronous backend
returns \"pending:\" and invokes it later.  Public and agent code stages calls
with `emacos-call'.  OWNER is the platform-service identity captured before a
confirmed dial begins."
  (let ((status
         (if (not (and (stringp number)
                       (string-match-p emacos-call--number-re number)))
             (format "error: invalid number: %s" number)
           (if emacos-call-operation-function
               (progn
                 (emacos-call--audio t)
                 (emacos-call--platform-operation
                  'dial owner number completion))
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
                       (format "error: could not create call: %s"
                               (emacos-call--status-detail
                                create "mmcli create failed"))
                     (let ((start (emacos-call--mmcli "-o" path "--start")))
                       (if (zerop (car start))
                           (format "dialing: %s" path)
                         ;; --start failed: drop the orphaned (created-but-
                         ;; unstarted) call object, then surface mmcli's ACTUAL
                         ;; reason rather than a fixed guess.
                         (emacos-call--dial-start-failure
                          path start)))))))))))
    status))

;;;###autoload
(defun emacos-call (number)
  "Stage a local two-tap call proposal for concrete NUMBER.
NUMBER is validated here and again by the private transport.  This command
never dials.  Return \"confirmation-required:\" when the proposal is shown,
or \"error:\" without changing an in-progress call."
  (interactive "sNumber to call (+E164): ")
  (let ((status (emacos-call--stage number)))
    (when (called-interactively-p 'interactive) (message "%s" status))
    status))

;;;###autoload
(defun emacos-hang-up (&optional completion)
  "End the current cellular call.  DETERMINISTIC primitive.
Return \"pending: ...\" for an asynchronous platform backend, otherwise
\"hung-up: ...\" or \"error: ...\".  Invoke optional COMPLETION with the
terminal asynchronous result."
  (interactive)
  (let* ((blocked (and emacos-call--pending-operation
                       (not (equal emacos-call--operation-identity
                                   emacos-call--pending-operation))))
         (tracked (or (and (eq emacos-call--state 'incoming)
                           emacos-call--call-path)
                      (eq emacos-call--state 'active)))
         (path (and tracked emacos-call--call-path))
         (identity (and emacos-call-operation-function
                        (null completion)
                        (not blocked)
                        tracked
                        (emacos-call--begin-operation 'hangup)))
         (finish (or completion
                     (and identity
                          (lambda (result)
                            (emacos-call--hangup-finished identity result)))))
         (status
          (cond
           (emacos-call-operation-function
            (cond
             (blocked
              "error: call operation already pending")
             ((not tracked) "error: no tracked call")
             (t (emacos-call--platform-operation
                 'hangup (and path emacos-call--call-owner) path finish))))
           (t
            (let ((m (emacos-call--modem-index)))
              (if (string-prefix-p "error:" m)
                  m
                (let ((result
                       (emacos-call--mmcli "-m" m "--voice-hangup-all")))
                  (if (zerop (car result))
                      "hung-up: all calls ended"
                    (format "error: hangup failed: %s"
                            (emacos-call--status-detail
                             (cdr result) "no active call?"))))))))))
    (when identity
      (emacos-call--finish-unless-pending status finish))
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
(declare-function emacos--btn "os")
(declare-function emacos--target "os")
(declare-function emacos--render-page "os")
(declare-function emacos--center "os")
(defvar emacos--btn-label-scale)
(defvar emacos--confirm-disarm-functions)
;; Names the keyboard plane os.el paints (the touch control plane is reactive
;; to the top buffer).  Canonically defined in os.el; declared `defvar-local'
;; here too so the call-screen renderers' `setq' stays buffer-local even if
;; this file is loaded before/without os.el (byte-compile, standalone tests) —
;; idempotent with os.el's identical declaration on device.
(defvar-local emacos--keyboard-plane nil)

(defvar emacos-call-at-port "/dev/ttyUSB3"
  "AT command port for voice control, freed from ModemManager via udev.")

(defconst emacos-call--incoming-buffer "*incoming-call*")
(defconst emacos-call--active-buffer "*call*")
(defconst emacos-call--confirm-timeout-seconds 15
  "Seconds allowed between the two outgoing-call confirmation actions.")

(defvar emacos-call--state nil
  "Current call-UI state.
Values are nil, `proposed', `dial-requested', `failed', `incoming', or
`active', plus transient `terminated' while an answer or hangup helper releases
its exclusion token after the carrier ends the call.  Drives the top buffer,
keyboard plane, and call badge.")
(defvar emacos-call--watcher-handles nil
  "Global D-Bus signal registrations; nil means inbound detection is unarmed.")
(defvar emacos-call--call-added-handle nil
  "Persistent CallAdded registration with callback-side unique-owner checks.")
(defvar emacos-call--owner-watch-handle nil
  "Exact bus-daemon NameOwnerChanged registration for ModemManager.")
(defconst emacos-call--watcher-topology-version 2
  "Persistent wildcard signal topology with callback-side owner/path checks.")
(defvar emacos-call--installed-watcher-topology nil
  "Watcher topology currently installed in this Emacs process.")
(defvar emacos-call--current-owner nil
  "Cached unique ModemManager owner maintained by the owner watch.")
(defvar emacos-call--owner-generation 0
  "Monotonic identity invalidating work captured before an owner change.")
(defvar emacos-call--state-handle nil
  "Persistent wildcard Call.StateChanged registration.
The callback accepts only the exact current ModemManager owner and tracked
call path.  CallDeleted does not fire promptly on this modem, so state 4 drives
the active transition and state 7 drives dismissal.")
(defvar emacos-call--watched-call nil
  "Exact (OWNER . PATH) accepted by the persistent StateChanged callback.")
(defvar emacos-call--call-path nil "Object path of the current call (in or out).")
(defvar emacos-call--call-owner nil
  "Unique D-Bus owner for the tracked call or pathless recovery state.")
(defvar emacos-call--call-number nil
  "Number of the current proposal, attempt, failure, or call.")
(defvar emacos-call--prev-buffer nil
  "Pre-call top buffer to restore when the call UI dismisses.")
(defvar emacos-call--next-proposal-id 0
  "Monotonic identity source for outgoing call proposals.")
(defvar emacos-call--proposal-id nil
  "Identity of the current proposed or requested outgoing call.")
(defvar emacos-call--dial-confirm-id nil
  "Proposal identity armed by the first outgoing Call activation.")
(defvar emacos-call--dial-confirm-timer nil
  "Timer that expires `emacos-call--dial-confirm-id'.")
(defvar emacos-call--skip-next-post-command-disarm nil
  "Non-nil immediately after arming, so that same command may finish first.")
(defvar emacos-call--failure-reason nil
  "Terminal reason for the current failed call attempt.")
(defvar emacos-call--ignored-call-path nil
  "Failed helper path whose next matching delayed CallAdded is ignored.")
(defvar emacos-call--ignored-call-owner nil
  "D-Bus unique owner paired with `emacos-call--ignored-call-path'.")
(defvar emacos-call--requested-call-events nil
  "At most four trusted (OWNER . PATH) events seen while dialing was pending.")
(defvar emacos-call--deferred-call-event nil
  "Newest (OWNER . PATH) event held while an answer or hangup helper runs.")
(defvar emacos-call--property-owner nil
  "Dynamically bound unique D-Bus owner for call-property reads.")
(defvar emacos-call--next-operation-id 0
  "Monotonic identity source for asynchronous answer and hangup operations.")
(defvar emacos-call--pending-operation nil
  "Current asynchronous operation as (ID OP PATH STATE OWNER), or nil.")
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
(defun emacos-answer (&optional completion)
  "Answer the ringing call through the configured platform operation.
The legacy transport sends `ATA' on the freed AT port because ModemManager's
QMI accept is broken on the SIM7600 modem.
Return \"pending: ...\" for an asynchronous platform backend, otherwise
\"answered: ...\" or \"error: ...\".  Invoke optional COMPLETION with the
terminal asynchronous result."
  (interactive)
  (let* ((blocked (and emacos-call--pending-operation
                       (not (equal emacos-call--operation-identity
                                   emacos-call--pending-operation))))
         (tracked (and (eq emacos-call--state 'incoming)
                       emacos-call--call-owner
                       emacos-call--call-path))
         (identity
          (and emacos-call-operation-function
               (null completion)
               (not blocked)
               tracked
               (emacos-call--begin-operation 'answer)))
         (finish
          (or completion
              (and identity
                   (lambda (result)
                     (emacos-call--answer-finished identity result)))))
         (status
          (if emacos-call-operation-function
              (cond
               (blocked
                "error: call operation already pending")
               ((not tracked) "error: no tracked incoming call")
               (t
                (when (or completion identity) (emacos-call--audio t))
                (emacos-call--platform-operation
                 'answer emacos-call--call-owner
                 emacos-call--call-path finish)))
            (let ((resp (emacos-call--at "ATA")))
              (cond ((string-prefix-p "error:" resp) resp)
                    ((string-match-p "NO CARRIER\\|ERROR" resp)
                     (format "error: answer failed: %s" (string-trim resp)))
                    ((string-match-p "BEGIN\\|OK" resp) "answered: call active")
                    (t (format "error: answer unconfirmed: %s"
                               (string-trim resp))))))))
    (when identity
      (emacos-call--finish-unless-pending status finish))
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

(defun emacos-call--render-call (heading number plane &optional detail)
  "Paint the shared *call* buffer with HEADING, NUMBER, PLANE, and DETAIL."
  (let ((buf (get-buffer-create emacos-call--active-buffer)))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "\n  " heading "\n\n  "
                (if (and number (not (string-empty-p number))) number "Unknown")
                "\n")
        (when detail (insert "\n  " detail "\n"))
        (goto-char (point-min)))
      (setq buffer-read-only t)
      (setq emacos--keyboard-plane plane))
    buf))

(defun emacos-call--render-proposal (number)
  "Paint a local outgoing-call proposal for NUMBER."
  (emacos-call--render-call "Call?" number #'emacos-call--plane-proposed))

(defun emacos-call--render-requested (number)
  "Paint the non-cancellable pending call attempt for NUMBER."
  (emacos-call--render-call
   "Starting call…" number #'emacos-call--plane-dial-requested))

(defun emacos-call--render-failed (number reason)
  "Paint a persistent failed-call surface for NUMBER.
REASON is whitespace-normalized and bounded for display."
  (let ((bounded (truncate-string-to-width
                  (replace-regexp-in-string "[\r\n\t ]+" " " reason)
                  160 nil nil "…")))
    (emacos-call--render-call
     "Call failed" number #'emacos-call--plane-failed bounded)))

(defun emacos-call--render-active (number status)
  "Paint the active call buffer for NUMBER with STATUS text."
  (emacos-call--render-call
   (concat "Call — " status) number #'emacos-call--plane-active))

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
  (if emacos-call--pending-operation
      (insert (if (eq (cadr emacos-call--pending-operation) 'answer)
                  "\n\n  Answering…\n"
                "\n\n  Ending call…\n"))
    (insert "\n")
    (emacos-call--plane-button "Decline" #'emacos-call--decline)
    (insert (make-string emacos-call-control-gap-lines ?\n))
    (emacos-call--plane-button
     (if emacos-call--answer-confirm-pending "Confirm answer?" "Accept")
     #'emacos-call--answer-tap
     (and emacos-call--answer-confirm-pending "firebrick4"))))

(defun emacos-call--plane-proposed ()
  "Keyboard plane for an outgoing proposal: Cancel plus two-tap Call."
  (insert "\n")
  (emacos-call--plane-button "Cancel" #'emacos-call--cancel-proposal)
  (insert (make-string emacos-call-control-gap-lines ?\n))
  (emacos-call--plane-button
   (if emacos-call--dial-confirm-id "Confirm call?" "Call")
   #'emacos-call--dial-tap
   (and emacos-call--dial-confirm-id "firebrick4")))

(defun emacos-call--plane-dial-requested ()
  "Keyboard plane while the dial request is being issued or pending."
  (insert "\n\n  Starting call…\n"))

(defun emacos-call--plane-failed ()
  "Keyboard plane for a persistent failed-call result."
  (insert "\n")
  (emacos-call--plane-button "Dismiss" #'emacos-call--dismiss-failure))

(defun emacos-call--plane-active ()
  "Keyboard plane for an in-progress call: Hang up (two-tap) + Back."
  (if emacos-call--pending-operation
      (insert "\n\n  Ending call…\n")
    (insert "\n")
    (emacos-call--plane-button
     (if emacos-call--hangup-confirm-pending "Confirm hang up?" "Hang up")
     #'emacos-call--hangup-tap
     (and emacos-call--hangup-confirm-pending "firebrick4"))
    (insert (make-string emacos-call-control-gap-lines ?\n))
    (emacos-call--plane-button "Back" #'emacos-call--back)))

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
  "Show call BUF in the top window and re-render; return that window."
  (let ((w (and (fboundp 'emacos--target) (emacos--target))))
    (when w
      (emacos-call--capture-prev w)
      (unless (eq (window-buffer w) buf)
        (set-window-buffer w buf))
      (emacos-call--rerender)
      w)))

(defun emacos-call-show-incoming (number)
  "Show the incoming-call screen for NUMBER."
  (setq emacos-call--answer-confirm-pending nil)
  (emacos-call--show-buffer (emacos-call--render-incoming number)))

(defun emacos-call--show-active (status)
  "Show the in-progress *call* screen (STATUS text) for the current number."
  (setq emacos-call--hangup-confirm-pending nil)
  (emacos-call--show-buffer
   (emacos-call--render-active emacos-call--call-number status)))

(defun emacos-call--cancel-dial-confirm-timer ()
  "Cancel and clear the outgoing confirmation timer."
  (when (timerp emacos-call--dial-confirm-timer)
    (cancel-timer emacos-call--dial-confirm-timer))
  (setq emacos-call--dial-confirm-timer nil))

(defun emacos-call--clear-dial-confirm (&optional rerender)
  "Clear the outgoing confirmation arm.
When RERENDER is non-nil and a proposal remains, repaint its Call label."
  (emacos-call--cancel-dial-confirm-timer)
  (setq emacos-call--dial-confirm-id nil
        emacos-call--skip-next-post-command-disarm nil)
  (when (and rerender (eq emacos-call--state 'proposed))
    (emacos-call--rerender)))

(defun emacos-call--proposal-visible-p ()
  "Return non-nil when the current proposal owns the top call surface."
  (let ((w (and (fboundp 'emacos--target) (emacos--target))))
    (and w
         (eq (window-buffer w) (get-buffer emacos-call--active-buffer)))))

(defun emacos-call--show-proposal ()
  "Show the current outgoing proposal."
  (emacos-call--show-buffer
   (emacos-call--render-proposal emacos-call--call-number)))

(defun emacos-call--show-requested ()
  "Show the non-cancellable current dial attempt."
  (emacos-call--show-buffer
   (emacos-call--render-requested emacos-call--call-number)))

(defun emacos-call--show-failed ()
  "Show the current persistent dial failure."
  (emacos-call--show-buffer
   (emacos-call--render-failed
    emacos-call--call-number
    (or emacos-call--failure-reason "call helper failed"))))

(defun emacos-call--stage (number)
  "Validate NUMBER and stage a fresh, unarmed outgoing proposal."
  ;; A public command between the two local taps always invalidates the arm,
  ;; even when its new argument is rejected before replacing the proposal.
  (when (eq emacos-call--state 'proposed)
    (emacos-call--clear-dial-confirm t))
  (cond
   ((not (and (stringp number)
              (string-match-p emacos-call--number-re number)))
    (format "error: invalid number: %s" number))
   ((memq emacos-call--state '(dial-requested incoming active))
    "error: call already in progress")
   (t
    (setq emacos-call--next-proposal-id (1+ emacos-call--next-proposal-id)
          emacos-call--proposal-id emacos-call--next-proposal-id
          emacos-call--state 'proposed
          emacos-call--call-path nil
          emacos-call--call-owner nil
          emacos-call--call-number number
          emacos-call--failure-reason nil)
    (if (emacos-call--show-proposal)
        "confirmation-required: confirm on phone"
      (emacos-call--dismiss)
      "error: call UI unavailable"))))

(defun emacos-call--parse-dial-status (status)
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

(defun emacos-call--adopt-outgoing-path
    (path number owner &optional activate-audio default-status
          observed-state snapshot-known-p)
  "Adopt outgoing PATH from OWNER for NUMBER without blocking Emacs input.
ACTIVATE-AUDIO selects call audio for an externally created call.
DEFAULT-STATUS defaults to \"Calling…\".  SNAPSHOT-KNOWN-P says OBSERVED-STATE
came from a CallAdded snapshot whose immutable sender matched the current
unique owner.  An asynchronous snapshot closes the path-adoption gap and
verifies direction and number."
  (setq emacos-call--call-path path
        emacos-call--call-owner owner
        emacos-call--call-number number
        emacos-call--state 'active)
  (emacos-call--watch-call-end path owner)
  (if snapshot-known-p
      (emacos-call--render-outgoing-state
       path owner observed-state activate-audio default-status)
    (when activate-audio (emacos-call--audio t))
    (emacos-call--show-active (or default-status "Calling…")))
  (let ((owner-generation emacos-call--owner-generation))
    (emacos-call--call-snapshot-async
     owner path
     (lambda (snapshot)
       (when (and (= owner-generation emacos-call--owner-generation)
                  (eq emacos-call--state 'active)
                  (equal emacos-call--call-path path)
                  (equal emacos-call--call-owner owner))
         (if (and snapshot
                  (eq (nth 0 snapshot) 2)
                  (emacos-call--same-number-p number (nth 2 snapshot)))
             (emacos-call--render-outgoing-state
              path owner (nth 1 snapshot) nil default-status)
           (emacos-call--show-unverified-call nil owner)))))))

(defun emacos-call--render-outgoing-state
    (path owner state activate-audio default-status)
  "Render owner-bound outgoing PATH in STATE without reading D-Bus."
  (when (and (eq emacos-call--state 'active)
             (equal emacos-call--call-path path)
             (equal emacos-call--call-owner owner))
    (cond
     ((eq state 7)
      (emacos-call--on-call-state nil 7 nil))
     ((not (memq state '(0 1 2 3 4 5 6)))
      (emacos-call--show-unverified-call activate-audio owner))
     ((eq state 4)
      (when activate-audio (emacos-call--audio t))
      (emacos-call--show-active "In progress"))
     (t
      (when activate-audio (emacos-call--audio t))
      (emacos-call--show-active (or default-status "Calling…"))))))

(defun emacos-call--same-number-p (left right)
  "Return non-nil when LEFT and RIGHT differ only by a leading plus."
  (and (stringp left)
       (stringp right)
       (equal (string-remove-prefix "+" left)
              (string-remove-prefix "+" right))))

(defun emacos-call--show-unverified-call (&optional activate-audio owner)
  "Keep global Hang up available when a call path cannot be trusted.
OWNER, when known, is retained as a stale-generation marker so a same-owner
CallAdded event cannot silently replace this uncertain call."
  (setq emacos-call--watched-call nil)
  (setq emacos-call--call-path nil
        emacos-call--call-owner owner
        emacos-call--state 'active)
  (when activate-audio (emacos-call--audio t))
  (emacos-call--show-active "Status unknown"))

(defun emacos-call--extra-requested-event-p (events owner &optional path)
  "Return non-nil when EVENTS has an OWNER event other than optional PATH."
  (seq-some (lambda (event)
              (and (equal (car event) owner)
                   (not (equal (cdr event) path))))
            events))

(defun emacos-call--dial-finished
    (proposal-id operation-owner status &optional owner-generation)
  "Apply dial STATUS to PROPOSAL-ID from OPERATION-OWNER.
OWNER-GENERATION, when supplied by the live path, must still match."
  (when (and (eq emacos-call--state 'dial-requested)
             (equal proposal-id emacos-call--proposal-id))
    (let* ((parsed (emacos-call--parse-dial-status status))
           (kind (nth 0 parsed))
           (path (nth 1 parsed))
           (detail (nth 2 parsed))
           (events emacos-call--requested-call-events))
      (cond
       ((and owner-generation
             (/= owner-generation emacos-call--owner-generation))
        (setq emacos-call--requested-call-events nil)
        (emacos-call--show-unverified-call nil operation-owner)
        (message "emacos-call: ModemManager restarted during dial"))
       ((eq kind 'dialing)
        (when (equal emacos-call--ignored-call-path path)
          (setq emacos-call--ignored-call-path nil
                emacos-call--ignored-call-owner nil))
        (setq emacos-call--requested-call-events nil)
        (if (emacos-call--extra-requested-event-p
             events operation-owner path)
            (emacos-call--show-unverified-call nil operation-owner)
          ;; The trusted root helper created and started this exact path under
          ;; OPERATION-OWNER.  Registration-gap verification is asynchronous.
          (emacos-call--adopt-outgoing-path
           path emacos-call--call-number operation-owner))
        (message "%s" status))
       ((eq kind 'uncertain)
        ;; --start may have taken effect before timing out, and the helper
        ;; could not prove cleanup.  Keep call audio plus Hang up available.
        (setq emacos-call--requested-call-events nil)
        (if (and path
                 (not (emacos-call--extra-requested-event-p
                       events operation-owner path)))
            (emacos-call--adopt-outgoing-path
             path emacos-call--call-number operation-owner nil
             "Status unknown")
          (emacos-call--show-unverified-call nil operation-owner))
        (message "emacos-call: call status unknown; hang up to ensure it ends"))
       (t
        (let* ((failed-path path)
               (unseen-path
                (and failed-path
                     (not (member (cons operation-owner failed-path) events))
                     failed-path))
               (owner (and unseen-path operation-owner)))
          (setq emacos-call--requested-call-events nil)
          (if (emacos-call--extra-requested-event-p
               events operation-owner failed-path)
              (emacos-call--show-unverified-call nil operation-owner)
            (progn
            (emacos-call--audio nil)
            (setq emacos-call--state 'failed
                  emacos-call--call-path nil
                  emacos-call--call-owner nil
                  emacos-call--ignored-call-path (and owner unseen-path)
                  emacos-call--ignored-call-owner owner
                  emacos-call--failure-reason detail)
            (emacos-call--show-failed)
            (message "emacos-call: %s" emacos-call--failure-reason)))))))))

(defun emacos-call--back ()
  "Leave the *call* screen for the pre-call buffer; the call KEEPS RUNNING.
The keyboard reverts to T9 and the modeline call badge appears (tap it to
return).  Only reachable from the active plane's Back button, so *call* is
the showing buffer — the buffer-restore is guarded regardless; the disarm +
re-render always run."
  (setq emacos-call--hangup-confirm-pending nil)
  (let ((w (and (fboundp 'emacos--target) (emacos--target)))
        (prev (if (buffer-live-p emacos-call--prev-buffer)
                  emacos-call--prev-buffer
                (get-buffer-create "*scratch*"))))
    (when (and w (eq (window-buffer w) (get-buffer emacos-call--active-buffer)))
      (set-window-buffer w prev))
    (emacos-call--rerender)))

(defun emacos-call--dismiss ()
  "End the call UI: clear tracked-call identity, restore the pre-call
buffer, kill the call buffers, drop the badge.  Idempotent."
  (emacos-call--clear-dial-confirm)
  (setq emacos-call--state nil
        emacos-call--watched-call nil
        emacos-call--call-path nil
        emacos-call--call-owner nil
        emacos-call--call-number nil
        emacos-call--proposal-id nil
        emacos-call--failure-reason nil
        emacos-call--requested-call-events nil
        emacos-call--pending-operation nil
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

(defun emacos-call--expire-dial-confirm (proposal-id)
  "Expire the arm only when it still belongs to PROPOSAL-ID."
  (when (and (eq emacos-call--state 'proposed)
             (equal proposal-id emacos-call--proposal-id)
             (equal proposal-id emacos-call--dial-confirm-id))
    (setq emacos-call--dial-confirm-timer nil
          emacos-call--dial-confirm-id nil
          emacos-call--skip-next-post-command-disarm nil)
    (emacos-call--rerender)))

(defun emacos-call--arm-dial ()
  "Arm the current visible proposal for one next local action."
  (emacos-call--cancel-dial-confirm-timer)
  (setq emacos-call--dial-confirm-id emacos-call--proposal-id
        emacos-call--skip-next-post-command-disarm t
        emacos-call--dial-confirm-timer
        (run-at-time emacos-call--confirm-timeout-seconds nil
                     #'emacos-call--expire-dial-confirm
                     emacos-call--proposal-id))
  (emacos-call--rerender))

(defun emacos-call--dial-tap ()
  "Two-tap outgoing Call action bound to one visible proposal identity."
  (cond
   ((not (and (eq emacos-call--state 'proposed)
              emacos-call--proposal-id
              (emacos-call--proposal-visible-p)))
    (emacos-call--clear-dial-confirm t)
    (message "emacos-call: proposal is no longer visible"))
   ((equal emacos-call--dial-confirm-id emacos-call--proposal-id)
    (let ((proposal-id emacos-call--proposal-id)
          (number emacos-call--call-number))
      ;; Consume the local authorization before launching the backend.  The
      ;; owner comes from the exact watch cache, so this input path does not
      ;; wait on D-Bus.
      (emacos-call--clear-dial-confirm)
      (setq emacos-call--state 'dial-requested
            emacos-call--requested-call-events nil)
      (emacos-call--show-requested)
      (let* ((operation-owner emacos-call--current-owner)
             (owner-generation emacos-call--owner-generation)
             (finish (lambda (result)
                       (emacos-call--dial-finished
                        proposal-id operation-owner result owner-generation))))
        (emacos-call--finish-unless-pending
         (emacos-call--dial number finish operation-owner)
         finish))))
   (t (emacos-call--arm-dial))))

(defun emacos-call--cancel-proposal ()
  "Dismiss the current proposal without touching the modem."
  (when (eq emacos-call--state 'proposed)
    (emacos-call--dismiss)))

(defun emacos-call--dismiss-failure ()
  "Acknowledge and dismiss the persistent failed-call surface."
  (when (eq emacos-call--state 'failed)
    (emacos-call--dismiss)))

(defun emacos-call--post-command-disarm ()
  "Make an armed outgoing call expire after the next unrelated command."
  (when emacos-call--dial-confirm-id
    (if emacos-call--skip-next-post-command-disarm
        (setq emacos-call--skip-next-post-command-disarm nil)
      (emacos-call--clear-dial-confirm t))))

(add-hook 'post-command-hook #'emacos-call--post-command-disarm)

(defun emacos-call--begin-operation (operation)
  "Mark OPERATION pending for the exact current call; return its identity."
  (setq emacos-call--next-operation-id (1+ emacos-call--next-operation-id))
  (let ((identity (list emacos-call--next-operation-id
                        operation
                        emacos-call--call-path
                        emacos-call--state
                        emacos-call--call-owner)))
    (setq emacos-call--pending-operation identity
          emacos-call--answer-confirm-pending nil
          emacos-call--hangup-confirm-pending nil)
    (emacos-call--rerender)
    identity))

(defun emacos-call--operation-current-p (identity)
  "Return non-nil when asynchronous IDENTITY still owns the visible call."
  (and (equal identity emacos-call--pending-operation)
       (equal (nth 2 identity) emacos-call--call-path)
       (eq (nth 3 identity) emacos-call--state)
       (equal (nth 4 identity) emacos-call--call-owner)))

(defun emacos-call--finish-unless-pending (status finish)
  "Call FINISH with terminal STATUS; leave asynchronous pending work alone."
  (unless (string-prefix-p "pending:" status)
    (funcall finish status)))

(defun emacos-call--uncertain-answer-p (status path)
  "Return non-nil when STATUS is an uncertain answer for tracked PATH."
  (and (stringp status)
       (or (string-match-p "\\`error: uncertain-answer; .+\\'" status)
           (and (string-match
                 (concat "\\`error: uncertain-answer-call-path="
                         "\\(/org/freedesktop/ModemManager1/Call/[0-9]+\\); .+\\'")
                 status)
                (equal (match-string 1 status) path)))))

(defun emacos-call--answer-finished (identity status)
  "Apply terminal answer STATUS only to matching operation IDENTITY."
  (when (emacos-call--operation-current-p identity)
    (message "%s" status)
    (cond
     ((eq emacos-call--state 'terminated)
      ;; D-Bus proved the call ended while Accept was still returning.
      (setq emacos-call--pending-operation nil)
      (emacos-call--dismiss)
      (emacos-call--replay-deferred-call-event))
     ((eq emacos-call--state 'active)
      ;; D-Bus either proved Accept took effect or the owner changed and left
      ;; pathless recovery.  The later helper result releases exclusion but
      ;; cannot restore trust in a lost call object.
      (setq emacos-call--pending-operation nil)
      (emacos-call--show-active
       (if emacos-call--call-path "In progress" "Status unknown"))
      (emacos-call--replay-deferred-call-event))
     ((string-prefix-p "answered:" status)
      (setq emacos-call--pending-operation nil
            emacos-call--state 'active)
      (emacos-call--show-active "In progress")
      (emacos-call--replay-deferred-call-event))
     ((emacos-call--uncertain-answer-p status (nth 2 identity))
      (let ((path (nth 2 identity))
            (owner (nth 4 identity)))
        (emacos-call--call-snapshot-async
         owner path
         (lambda (snapshot)
           (when (emacos-call--operation-current-p identity)
             (setq emacos-call--pending-operation nil)
             (let ((same-call (and (equal path emacos-call--call-path)
                                   (equal owner emacos-call--call-owner)))
                   (direction (nth 0 snapshot))
                   (current (nth 1 snapshot)))
               (cond
                ((and same-call (eq direction 1) (eq current 4))
                 (setq emacos-call--state 'active)
                 (emacos-call--show-active "In progress"))
                ((and same-call (eq direction 1) (eq current 7))
                 (emacos-call--audio nil)
                 (emacos-call--dismiss))
                ((and same-call (eq direction 1)
                      (memq current '(0 1 2 3 5 6)))
                 (emacos-call--audio nil)
                 (emacos-call-show-incoming emacos-call--call-number))
                (t
                 (emacos-call--show-unverified-call nil owner))))
             (emacos-call--replay-deferred-call-event))))))
     (t
      (setq emacos-call--pending-operation nil)
      (emacos-call--audio nil)
      (emacos-call-show-incoming emacos-call--call-number)
      (emacos-call--replay-deferred-call-event)))))

(defun emacos-call--hangup-finished (identity status)
  "Apply terminal hangup STATUS only to matching operation IDENTITY."
  (when (emacos-call--operation-current-p identity)
    (setq emacos-call--pending-operation nil)
    (message "%s" status)
    (if (or (eq emacos-call--state 'terminated)
            (string-prefix-p "hung-up:" status))
        (progn
          (emacos-call--audio nil)
          (emacos-call--dismiss))
      (if (eq emacos-call--state 'incoming)
          (emacos-call-show-incoming emacos-call--call-number)
        (emacos-call--show-active "Hang up failed")))
    (emacos-call--replay-deferred-call-event)))

(defun emacos-call--answer-tap ()
  "Two-tap Accept: first tap arms; second starts the answer operation.
Terminal helper success or a proven active D-Bus state shows in-progress."
  (if emacos-call--answer-confirm-pending
      (let* ((identity (emacos-call--begin-operation 'answer))
             (finish (lambda (result)
                       (emacos-call--answer-finished identity result))))
        (emacos-call--finish-unless-pending
         (let ((emacos-call--operation-identity identity))
           (emacos-answer finish))
         finish))
    (setq emacos-call--answer-confirm-pending t)
    (emacos-call--rerender)))

(defun emacos-call--decline ()
  "Decline the ringing call; await terminal hangup before dismissing."
  (let* ((identity (emacos-call--begin-operation 'hangup))
         (finish (lambda (result)
                   (emacos-call--hangup-finished identity result))))
    (emacos-call--finish-unless-pending
     (let ((emacos-call--operation-identity identity))
       (emacos-hang-up finish))
     finish)))

(defun emacos-call--hangup-tap ()
  "Two-tap Hang up; dismiss only after the backend confirms success."
  (if emacos-call--hangup-confirm-pending
      (let* ((identity (emacos-call--begin-operation 'hangup))
             (finish (lambda (result)
                       (emacos-call--hangup-finished identity result))))
        (emacos-call--finish-unless-pending
         (let ((emacos-call--operation-identity identity))
           (emacos-hang-up finish))
         finish))
    (setq emacos-call--hangup-confirm-pending t)
    (emacos-call--rerender)))

(defun emacos-call--maybe-disarm (action _arg)
  "Disarm any pending call confirmation on a different button tap.
Registered on `emacos--confirm-disarm-functions'."
  (let (changed)
    (when (and emacos-call--dial-confirm-id
               (not (eq action #'emacos-call--dial-tap)))
      (emacos-call--clear-dial-confirm)
      (setq changed t))
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
    (define-key m [mode-line mouse-1] #'emacos-call--badge-tap)
    m)
  "Keymap for the tappable call badge (built once; the :eval runs each redisplay).")

(defun emacos-call--badge-tap ()
  "Modeline call-badge handler: re-show the backgrounded *call* screen."
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
  "Read PROP from the ModemManager Call object at PATH (D-Bus, no sudo).
Owner-sensitive callers dynamically bind `emacos-call--property-owner' to a
unique bus name so a read sequence cannot cross a service restart."
  (when (fboundp 'dbus-get-property)
    (ignore-errors
      (dbus-get-property :system
                         (or emacos-call--property-owner
                             "org.freedesktop.ModemManager1") path
                         "org.freedesktop.ModemManager1.Call" prop))))

(defun emacos-call--modem-manager-owner ()
  "Return ModemManager's current unique D-Bus owner, or nil, within 500 ms."
  (when (fboundp 'dbus-call-method)
    (ignore-errors
      (dbus-call-method
       :system "org.freedesktop.DBus" "/org/freedesktop/DBus"
       "org.freedesktop.DBus" "GetNameOwner" :timeout 500
       "org.freedesktop.ModemManager1"))))

(defun emacos-call--record-requested-event (owner path)
  "Remember trusted OWNER and PATH while bounding pending dial state."
  (let ((event (cons owner path)))
    (setq emacos-call--requested-call-events
          (delete event emacos-call--requested-call-events))
    (push event emacos-call--requested-call-events)
    (when (nthcdr 4 emacos-call--requested-call-events)
      (setcdr (nthcdr 3 emacos-call--requested-call-events) nil))))

(defun emacos-call--defer-call-event (owner path)
  "Retain the newest trusted OWNER/PATH while a root helper owns exclusion."
  (setq emacos-call--deferred-call-event (cons owner path)))

(defun emacos-call--replay-deferred-call-event ()
  "Apply the newest deferred CallAdded event after helper exclusion ends."
  (let ((event emacos-call--deferred-call-event))
    (setq emacos-call--deferred-call-event nil)
    (when event
      (emacos-call--on-call-added-async (car event) (cdr event)))))

(defun emacos-call--adopt-call-snapshot
    (owner path direction observed-state number
           &optional trusted-owner-snapshot)
  "Adopt one owner-bound call snapshot; return non-nil on adoption.
TRUSTED-OWNER-SNAPSHOT means the properties were returned asynchronously by
the exact unique owner, so this function performs no synchronous D-Bus read."
  (let ((stale-owner
         (and emacos-call--call-owner
              (memq emacos-call--state '(incoming active))
              (not (equal owner emacos-call--call-owner)))))
    (when (and (or trusted-owner-snapshot
                   (equal owner (emacos-call--modem-manager-owner)))
               (memq direction '(1 2))
               (memq observed-state '(0 1 2 3 4 5 6))
               (or (memq emacos-call--state '(nil proposed failed))
                   stale-owner))
      (when (and stale-owner (eq emacos-call--state 'active))
        (emacos-call--audio nil))
      (when emacos-call--state
        (emacos-call--dismiss))
      (if (eq direction 2)
          (emacos-call--adopt-outgoing-path
           path number owner t nil observed-state t)
        (setq emacos-call--call-path path
              emacos-call--call-owner owner
              emacos-call--call-number number
              emacos-call--state 'incoming)
        ;; Establish a visible surface before any registration/read that can
        ;; dispatch a reentrant StateChanged callback.
        (if (eq observed-state 4)
            (progn
              (setq emacos-call--state 'active)
              (emacos-call--audio t)
              (emacos-call--show-active "In progress"))
          (when emacos-call-wake-function
            (ignore-errors (funcall emacos-call-wake-function)))
          (emacos-call-show-incoming emacos-call--call-number))
        (emacos-call--watch-call-end path owner)
        ;; Re-read after adoption to close the transition gap.  The live
        ;; signal path does this asynchronously so modem latency cannot block
        ;; Emacs input; direct/test callers retain the original bounded read.
        (if trusted-owner-snapshot
            (emacos-call--refresh-adopted-state-async
             owner path observed-state)
          (emacos-call--refresh-adopted-state
           owner path observed-state)))
      t)))

(defun emacos-call--snapshot-value (properties name)
  "Return NAME from raw D-Bus GetAll PROPERTIES."
  (let ((entry (assoc name properties)))
    (and entry (caadr entry))))

(defun emacos-call--call-snapshot-async (owner path completion)
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
                     (list (emacos-call--snapshot-value properties "Direction")
                           (emacos-call--snapshot-value properties "State")
                           (or (emacos-call--snapshot-value
                                properties "Number") "")))))))
         :timeout 500 "org.freedesktop.ModemManager1.Call")
      (error
       (when (timerp fallback) (cancel-timer fallback))
       (unless done
         (setq done t)
         (funcall completion nil))))))

(defun emacos-call--apply-adopted-state (owner path observed-state current)
  "Reconcile CURRENT for an adopted PATH from OWNER against OBSERVED-STATE."
  (let ((effective (if (memq current '(0 1 2 3 4 5 6 7))
                       current observed-state)))
    (when (and (memq emacos-call--state '(incoming active))
               (equal emacos-call--call-path path)
               (equal emacos-call--call-owner owner))
      (cond
       ((eq effective 7) (emacos-call--on-call-state nil 7 nil))
       ((eq effective 4)
        (unless (eq emacos-call--state 'active)
          (setq emacos-call--state 'active)
          (emacos-call--audio t))
        (emacos-call--show-active "In progress"))
       ((eq emacos-call--state 'active)
        (setq emacos-call--state 'incoming)
        (emacos-call--audio nil)
        (emacos-call-show-incoming emacos-call--call-number))))))

(defun emacos-call--refresh-adopted-state (owner path observed-state)
  "Synchronously close the direct/test adoption gap for PATH."
  (let ((emacos-call--property-owner owner)
        (current (emacos-call--call-prop path "State")))
    (when (equal owner (emacos-call--modem-manager-owner))
      (emacos-call--apply-adopted-state owner path observed-state current))))

(defun emacos-call--refresh-adopted-state-async (owner path observed-state)
  "Asynchronously close the live signal adoption gap for PATH."
  (emacos-call--call-snapshot-async
   owner path
   (lambda (snapshot)
     (if snapshot
         (emacos-call--apply-adopted-state
          owner path observed-state (nth 1 snapshot))
       (when (and (memq emacos-call--state '(incoming active))
                  (equal emacos-call--call-path path)
                  (equal emacos-call--call-owner owner))
         (emacos-call--show-unverified-call nil owner))))))

(defun emacos-call--apply-call-added-snapshot
    (owner path initial-state initial-path initial-owner snapshot
           &optional trusted-owner-snapshot)
  "Apply one CallAdded SNAPSHOT if its captured UI identity is still current."
  (let ((dir (nth 0 snapshot))
        (observed-state (nth 1 snapshot))
        (number (or (nth 2 snapshot) "")))
    (unless (emacos-call--adopt-call-snapshot
             owner path dir observed-state number trusted-owner-snapshot)
      (when (and (eq emacos-call--state initial-state)
                 (equal emacos-call--call-path initial-path)
                 (equal emacos-call--call-owner initial-owner)
                 (not (eq emacos-call--state 'dial-requested))
                 (not (eq observed-state 7))
                 (or (memq dir '(1 2))
                     (not (memq observed-state '(0 1 2 3 4 5 6 7)))))
        (emacos-call--show-unverified-call nil owner)))))

(defun emacos-call--consume-ignored-call-event (owner path)
  "Return non-nil and consume an ignored OWNER/PATH event when it matches."
  (when (and emacos-call--ignored-call-owner
             (not (equal owner emacos-call--ignored-call-owner)))
    (setq emacos-call--ignored-call-path nil
          emacos-call--ignored-call-owner nil))
  (when (and (equal path emacos-call--ignored-call-path)
             (equal owner emacos-call--ignored-call-owner))
    (setq emacos-call--ignored-call-path nil
          emacos-call--ignored-call-owner nil)
    t))

(defun emacos-call--on-call-added-async (owner path)
  "Handle live CallAdded PATH from unique OWNER without blocking input."
  (when (and owner
             (equal owner emacos-call--current-owner)
             (stringp path)
             (string-match-p emacos-call--path-re path))
    (cond
     (emacos-call--pending-operation
      (emacos-call--defer-call-event owner path))
     ((eq emacos-call--state 'dial-requested)
      (emacos-call--record-requested-event owner path))
     ((not (emacos-call--consume-ignored-call-event owner path))
      (let ((initial-state emacos-call--state)
            (initial-path emacos-call--call-path)
            (initial-owner emacos-call--call-owner)
            (owner-generation emacos-call--owner-generation))
        (when (eq emacos-call--state 'proposed)
          (emacos-call--clear-dial-confirm t))
        (emacos-call--call-snapshot-async
         owner path
         (lambda (snapshot)
           (when (= owner-generation emacos-call--owner-generation)
             (if snapshot
                 (emacos-call--apply-call-added-snapshot
                  owner path initial-state initial-path initial-owner snapshot
                  t)
               (when (and (eq emacos-call--state initial-state)
                          (equal emacos-call--call-path initial-path)
                          (equal emacos-call--call-owner initial-owner))
                 (when emacos-call-wake-function
                   (ignore-errors (funcall emacos-call-wake-function)))
                 (emacos-call--show-unverified-call nil owner)))))))))))

(defun emacos-call--on-call-added-from-owner (owner path)
  "Synchronously handle CallAdded PATH for direct development and tests.
The live persistent subscription verifies its immutable sender, then uses
`emacos-call--on-call-added-async'."
  (when (and owner
             (stringp path)
             (string-match-p emacos-call--path-re path))
    ;; This callback is already bound to a unique bus owner.  Record its exact
    ;; identity before GetNameOwner, which can itself dispatch another signal.
    (when (eq emacos-call--state 'dial-requested)
      (emacos-call--record-requested-event owner path))
    (let ((initial-state emacos-call--state)
          (initial-path emacos-call--call-path)
          (initial-owner emacos-call--call-owner)
          (current-owner (emacos-call--modem-manager-owner)))
      ;; The callback is bound to OWNER.  A temporarily unreadable owner still
      ;; breaks local confirmation adjacency; a known different owner is stale.
      (when (and (or (null current-owner) (equal owner current-owner))
                 (eq emacos-call--state 'proposed))
        (emacos-call--clear-dial-confirm t))
      (when (and (equal owner current-owner)
                 (not (emacos-call--consume-ignored-call-event owner path)))
        (let ((emacos-call--property-owner owner))
          (emacos-call--apply-call-added-snapshot
           owner path initial-state initial-path initial-owner
           (list (emacos-call--call-prop path "Direction")
                 (emacos-call--call-prop path "State")
                 (or (emacos-call--call-prop path "Number") ""))))))))

(defun emacos-call--on-call-added (path &rest _)
  "Handle a CallAdded PATH using ModemManager's current unique owner.
The live subscription instead invokes `emacos-call--on-call-added-async' with
immutable sender metadata; this wrapper remains a direct development and test
entry point."
  (let ((owner (emacos-call--modem-manager-owner)))
    (when owner
      (emacos-call--on-call-added-from-owner owner path))))

(defun emacos-call--on-call-state (_old new _reason)
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
    (let ((was-incoming (eq emacos-call--state 'incoming)))
      (setq emacos-call--state 'active)
      (when emacos-call--pending-operation
        ;; Preserve the helper's exclusion token until its sentinel runs while
        ;; moving the identity to the state already proven by D-Bus.
        (setcar (nthcdr 3 emacos-call--pending-operation) 'active))
      (when was-incoming (emacos-call--audio t))
      (cond
       ((get-buffer-window emacos-call--incoming-buffer)
        (emacos-call--show-active "In progress")) ; answered → swap incoming→*call*
       ((get-buffer-window emacos-call--active-buffer)
        (emacos-call--render-active emacos-call--call-number "In progress")
        (emacos-call--rerender)))))                ; outbound ringing → connected
   ((eq new 7)
    (when emacos-call-operation-function (emacos-call--audio nil))
    ;; A helper still owns the root flock.  Keep its non-interactive pending
    ;; surface until the sentinel reports, so no second mutation can collide.
    (if emacos-call--pending-operation
        (progn
          (setq emacos-call--state 'terminated)
          (setcar (nthcdr 3 emacos-call--pending-operation) 'terminated)
          (emacos-call--show-active "Ending call…"))
      (emacos-call--dismiss)))))

(defun emacos-call--register-signal-bounded (&rest args)
  "Register one D-Bus signal match, failing instead of blocking past 500 ms."
  (with-timeout (0.5 (error "D-Bus signal registration timed out"))
    (apply #'dbus-register-signal args)))

(defun emacos-call--unregister-signal-bounded (handle)
  "Remove HANDLE without letting D-Bus stall Emacs past 500 ms."
  (when handle
    (with-timeout (0.5 nil)
      (ignore-errors (dbus-unregister-object handle)))))

(defun emacos-call--watch-call-end (path owner)
  "Select exact OWNER/PATH for the persistent StateChanged subscription.
A still-running helper retains its pending surface until its sentinel runs.
No D-Bus match is added or removed on this live path."
  (setq emacos-call--watched-call (cons owner path)))

(defun emacos-call--event-owner ()
  "Return the immutable unique sender of the current D-Bus event."
  (when (and (fboundp 'dbus-event-service-name) last-input-event)
    (ignore-errors (dbus-event-service-name last-input-event))))

(defun emacos-call--event-path ()
  "Return the object path carried by the current D-Bus event metadata."
  (when (and (fboundp 'dbus-event-path-name) last-input-event)
    (ignore-errors (dbus-event-path-name last-input-event))))

(defun emacos-call--on-call-state-event (old new reason)
  "Apply a wildcard StateChanged event only to the exact tracked call."
  (let ((owner (emacos-call--event-owner))
        (path (emacos-call--event-path)))
    (when (and (equal emacos-call--watched-call (cons owner path))
               (equal emacos-call--call-owner owner)
               (equal emacos-call--call-path path))
      (emacos-call--on-call-state old new reason))))

(defun emacos-call--register-call-added (owner)
  "Register persistent call signals and accept only current unique OWNER."
  (setq emacos-call--current-owner owner)
  (setq emacos-call--call-added-handle
        (or emacos-call--call-added-handle
            (emacos-call--register-signal-bounded
             :system nil nil
             "org.freedesktop.ModemManager1.Modem.Voice" "CallAdded"
             (lambda (path &rest _)
               (emacos-call--on-call-added-async
                (emacos-call--event-owner) path)))))
  (setq emacos-call--state-handle
        (or emacos-call--state-handle
            (emacos-call--register-signal-bounded
             :system nil nil
             "org.freedesktop.ModemManager1.Call" "StateChanged"
             #'emacos-call--on-call-state-event)))
  (setq emacos-call--watcher-handles
        (delq nil (list emacos-call--owner-watch-handle
                        emacos-call--call-added-handle
                        emacos-call--state-handle))))

(defun emacos-call--on-owner-changed (name old-owner new-owner)
  "Update accepted call identity when ModemManager NAME changes owner."
  (when (equal name "org.freedesktop.ModemManager1")
    (setq emacos-call--current-owner
          (unless (string-empty-p new-owner) new-owner)
          emacos-call--owner-generation
          (1+ emacos-call--owner-generation)
          emacos-call--requested-call-events nil)
    (when (equal emacos-call--ignored-call-owner old-owner)
      (setq emacos-call--ignored-call-path nil
            emacos-call--ignored-call-owner nil))
    (when (equal (car-safe emacos-call--deferred-call-event) old-owner)
      (setq emacos-call--deferred-call-event nil))
    (when (and old-owner
               (equal emacos-call--call-owner old-owner)
               (memq emacos-call--state '(incoming active)))
      (setq emacos-call--watched-call nil
            emacos-call--call-path nil
            emacos-call--call-owner old-owner
            emacos-call--state 'active)
      ;; The helper may still own the root flock.  Preserve its exclusion
      ;; identity but move it to the conservative pathless state so its
      ;; completion can release the UI without trusting the dead owner.
      (when emacos-call--pending-operation
        (setcar (nthcdr 2 emacos-call--pending-operation) nil)
        (setcar (nthcdr 3 emacos-call--pending-operation) 'active))
      (emacos-call--show-active "Status unknown"))))

(defun emacos-call--watcher-ensure ()
  "Subscribe to trusted CallAdded and ModemManager owner changes.
CallAdded and StateChanged use persistent sender-wildcard bus matches, then
validate immutable event metadata against the cached unique owner and tracked
path.  Only boot, hot migration, or explicit stop changes bus matches; live
call and owner callbacks never do.  Idempotent and a no-op without D-Bus."
  ;; Hot reload may preserve the older per-owner/per-call match topology.
  ;; Replace it once, invalidating any queued callback identities.
  (when (and emacos-call--watcher-handles
             (not (equal emacos-call--installed-watcher-topology
                         emacos-call--watcher-topology-version)))
    (dolist (handle emacos-call--watcher-handles)
      (emacos-call--unregister-signal-bounded handle))
    (setq emacos-call--watcher-handles nil
          emacos-call--owner-watch-handle nil
          emacos-call--call-added-handle nil
          emacos-call--state-handle nil
          emacos-call--installed-watcher-topology nil
          emacos-call--watched-call nil
          emacos-call--owner-generation (1+ emacos-call--owner-generation)))
  (when (and (not emacos-call--watcher-handles)
             (fboundp 'dbus-register-signal))
    ;; condition-case: os.el calls this at boot, so a system-bus/service that
    ;; isn't ready yet must NOT take down init -- honor the "never a boot
    ;; failure" promise above (inbound just stays off until re-armed).
    (condition-case err
        (progn
          (setq emacos-call--owner-watch-handle
                (emacos-call--register-signal-bounded
                 :system "org.freedesktop.DBus" "/org/freedesktop/DBus"
                 "org.freedesktop.DBus" "NameOwnerChanged"
                 #'emacos-call--on-owner-changed
                 :arg0 "org.freedesktop.ModemManager1"))
          (emacos-call--register-call-added
           (emacos-call--modem-manager-owner))
          (setq emacos-call--installed-watcher-topology
                emacos-call--watcher-topology-version)
          (when (memq emacos-call--state '(incoming active))
            (if (and emacos-call--call-owner emacos-call--call-path)
                (emacos-call--watch-call-end
                 emacos-call--call-path emacos-call--call-owner)
              (emacos-call--show-unverified-call
               nil emacos-call--current-owner))))
      (error
       (dolist (handle (delq nil (list emacos-call--owner-watch-handle
                                      emacos-call--call-added-handle
                                      emacos-call--state-handle)))
         (emacos-call--unregister-signal-bounded handle))
       (setq emacos-call--watcher-handles nil
             emacos-call--owner-watch-handle nil
             emacos-call--call-added-handle nil
             emacos-call--state-handle nil
             emacos-call--installed-watcher-topology nil
             emacos-call--current-owner nil)
       (message "emacos-call: inbound watcher unavailable: %s"
                (error-message-string err))))))

(defun emacos-call--watcher-stop ()
  "Unsubscribe all call and owner signals (dev/debug affordance)."
  (interactive)
  (dolist (handle emacos-call--watcher-handles)
    (emacos-call--unregister-signal-bounded handle))
  (setq emacos-call--watcher-handles nil
        emacos-call--owner-watch-handle nil
        emacos-call--call-added-handle nil
        emacos-call--current-owner nil
        emacos-call--state-handle nil
        emacos-call--installed-watcher-topology nil
        emacos-call--watched-call nil
        emacos-call--owner-generation (1+ emacos-call--owner-generation)
        emacos-call--ignored-call-path nil
        emacos-call--ignored-call-owner nil
        emacos-call--requested-call-events nil
        emacos-call--deferred-call-event nil))

;; Apply the persistent-filter migration during a development hot reload.
;; Cold boot still arms the watcher from os.el after startup.
(when emacos-call--watcher-handles
  (emacos-call--watcher-ensure))

(provide 'phone-call)
;;; phone-call.el ends here
