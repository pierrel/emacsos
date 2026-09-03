;;; test-call.el --- Tests for phone-call.el deterministic primitives -*- lexical-binding: t -*-

;; Covers the PURE logic of emacos-call / emacos-hang-up: number validation,
;; the segfault-safe full-call-path extraction, the start-failure cleanup, and
;; the status-string contract.  Real mmcli execution + actually dialing are
;; validated on the live phone, not here -- emacos-call--mmcli is stubbed.

(require 'ert)
(require 'cl-lib)
(require 'phone-call)
;; The render tests stub `emacos--btn'; they only need a value for the
;; `emacos--btn-label-scale' arg it's passed (phone-call.el declares the var
;; without a value).  Bind a dummy here instead of pulling in all of os.el.
(defvar emacos--btn-label-scale 0.8)
;; os.el defines this buffer-local; the screen renderers set it.  Declare it
;; here (os.el isn't loaded in these tests) so it goes buffer-local as on device.
(defvar-local emacos--keyboard-plane nil)

;; Special (dynamic) so the stub lambda built in `test-call--stub' and the
;; `let'-binding in `test-call--with' refer to the SAME variable across
;; functions (a lexical binding wouldn't reach the stub).
(defvar test-call--seen nil
  "Arg-lists passed to the stubbed `emacos-call--mmcli', most-recent-first.")

(defun test-call--stub (responses)
  "Return a stub for `emacos-call--mmcli' driven by RESPONSES.
RESPONSES is a list of (PRED . (CODE . OUT)); the first PRED matching the
arg list wins.  Also records calls in the dynamic var `test-call--seen'."
  (lambda (&rest args)
    (push args test-call--seen)
    (let ((hit (cl-find-if (lambda (r) (funcall (car r) args)) responses)))
      (if hit
          (cdr hit)
        ;; Fail loudly on an unanticipated mmcli call rather than masking it
        ;; with a default success — a test must declare every call it expects.
        (error "unexpected emacos-call--mmcli call: %S" args)))))

(defmacro test-call--with (responses &rest body)
  (declare (indent 1))
  `(let ((test-call--seen nil))
     (cl-letf (((symbol-function 'emacos-call--mmcli)
                (test-call--stub ,responses)))
       ,@body)))

(defun test-call--has (args sub)
  "Non-nil if ARGS contains an element with SUB as a substring."
  (cl-some (lambda (a) (and (stringp a) (string-match-p (regexp-quote sub) a))) args))

(ert-deftest emacos-call-rejects-non-number ()
  "A name (or anything non-numeric) errors without touching mmcli."
  (test-call--with nil
    (should (string-prefix-p "error: invalid number" (emacos-call "Ana")))
    (should (null test-call--seen))))

(ert-deftest emacos-call-dials-and-extracts-full-path ()
  (test-call--with
      (list (cons (lambda (a) (member "-L" a))
                  (cons 0 "  /org/freedesktop/ModemManager1/Modem/3 [QUALCOMM] SIM7600"))
            (cons (lambda (a) (test-call--has a "--voice-create-call"))
                  (cons 0 "Successfully created new call: /org/freedesktop/ModemManager1/Call/2"))
            (cons (lambda (a) (member "--start" a)) (cons 0 "")))
    (should (equal (emacos-call "+14155550123")
                   "dialing: /org/freedesktop/ModemManager1/Call/2"))))

(ert-deftest emacos-call-no-modem ()
  (test-call--with (list (cons (lambda (a) (member "-L" a)) (cons 0 "No modems were found")))
    (should (equal (emacos-call "+14155550123") "error: no modem found"))))

(ert-deftest emacos-call-start-failure-hangs-up ()
  (test-call--with
      (list (cons (lambda (a) (member "-L" a))
                  (cons 0 "/org/freedesktop/ModemManager1/Modem/3"))
            (cons (lambda (a) (test-call--has a "--voice-create-call"))
                  (cons 0 "Successfully created new call: /org/freedesktop/ModemManager1/Call/2"))
            (cons (lambda (a) (member "--start" a)) (cons 1 "error"))
            (cons (lambda (a) (member "--hangup" a)) (cons 0 "")))
    (should (string-prefix-p "error: dial failed" (emacos-call "+14155550123")))
    ;; start failed -> we must have issued a --hangup on the created path
    (should (cl-some (lambda (a) (member "--hangup" a)) test-call--seen))))

(ert-deftest emacos-hang-up-status ()
  (test-call--with
      (list (cons (lambda (a) (member "-L" a))
                  (cons 0 "/org/freedesktop/ModemManager1/Modem/3"))
            (cons (lambda (a) (member "--voice-hangup-all" a)) (cons 0 "")))
    (should (string-prefix-p "hung-up:" (emacos-hang-up)))))

(ert-deftest emacos-call-create-failure ()
  "Create yields no /Call/N path -> error, and --start is never issued."
  (test-call--with
      (list (cons (lambda (a) (member "-L" a))
                  (cons 0 "/org/freedesktop/ModemManager1/Modem/3"))
            (cons (lambda (a) (test-call--has a "--voice-create-call"))
                  (cons 1 "error: couldn't create call")))
    (should (string-prefix-p "error: could not create call"
                             (emacos-call "+14155550123")))
    (should-not (cl-some (lambda (a) (member "--start" a)) test-call--seen))))

(ert-deftest emacos-call-sudo-unavailable ()
  "Denied mmcli (no passwordless sudo) is reported distinctly, not as no-modem."
  (test-call--with
      (list (cons (lambda (a) (member "-L" a))
                  (cons 1 "sudo: a password is required")))
    (should (string-prefix-p "error: mmcli unavailable"
                             (emacos-call "+14155550123")))))

(ert-deftest emacos-call-number-boundaries ()
  "Too short / too long reject without touching mmcli (the dial guard)."
  (test-call--with nil
    (should (string-prefix-p "error: invalid number" (emacos-call "1234")))
    (should (string-prefix-p "error: invalid number"
                             (emacos-call "1234567890123456")))
    (should (null test-call--seen))))

(ert-deftest emacos-call-platform-dial-routes-audio-and-operation ()
  (let ((emacos-call-operation-function
         (lambda (operation value)
           (should (eq operation 'dial))
           (should (equal value "+14155550123"))
           "dialing: /org/freedesktop/ModemManager1/Call/4"))
        (emacos-call-audio-function (lambda (active) (should active))))
    (should (string-prefix-p "dialing:" (emacos-call "+14155550123")))))

(ert-deftest emacos-call-platform-dial-failure-restores-audio ()
  (let* ((audio nil)
        (emacos-call-operation-function (lambda (&rest _) "error: rejected"))
        (emacos-call-audio-function (lambda (active) (push active audio))))
    (should (equal (emacos-call "+14155550123") "error: rejected"))
    (should (equal (nreverse audio) '(t nil)))))

(ert-deftest emacos-call-platform-answer-uses-tracked-path ()
  (let ((emacos-call--call-path "/org/freedesktop/ModemManager1/Call/8")
        (emacos-call-audio-function #'ignore)
        (emacos-call-operation-function
         (lambda (operation value)
           (should (eq operation 'answer))
           (should (equal value "/org/freedesktop/ModemManager1/Call/8"))
           "answered: call active")))
    (should (string-prefix-p "answered:" (emacos-answer)))))

(ert-deftest emacos-call-platform-hangup-restores-audio ()
  (let* ((audio 'unset)
        (emacos-call-operation-function
         (lambda (operation value)
           (should (eq operation 'hangup))
           (should-not value)
           "hung-up: all calls ended"))
        (emacos-call-audio-function (lambda (active) (setq audio active))))
    (should (string-prefix-p "hung-up:" (emacos-hang-up)))
    (should-not audio)))

(ert-deftest emacos-hang-up-no-modem ()
  (test-call--with (list (cons (lambda (a) (member "-L" a))
                               (cons 0 "No modems were found")))
    (should (string-prefix-p "error: no modem found" (emacos-hang-up)))))

(ert-deftest emacos-call--mmcli-catches-launch-failure ()
  "A process-launch failure (e.g. sudo absent) returns a status cons, not a
raised signal — so the primitives keep their string-return contract."
  (cl-letf (((symbol-function 'call-process)
             (lambda (&rest _)
               (signal 'file-error '("Searching for program" "no such file" "sudo")))))
    (let ((r (emacos-call--mmcli "-L")))
      (should (= (car r) 1))
      (should (string-match-p "sudo" (cdr r))))))

(ert-deftest emacos-call--mmcli-normalizes-signal-death ()
  "A signal-killed child (call-process returns a STRING) becomes a non-zero
INT code, so callers' (zerop code) never breaks; the description is kept."
  (cl-letf (((symbol-function 'call-process)
             (lambda (&rest _) (insert "partial") "Segmentation fault")))
    (let ((r (emacos-call--mmcli "-L")))
      (should (integerp (car r)))
      (should (= (car r) 1))
      (should (string-match-p "Segmentation fault" (cdr r))))))

;;; Inbound: answer / detect / screen ;;;

(ert-deftest emacos-answer-ata-success ()
  "ATA returning VOICE CALL: BEGIN / OK is reported as answered."
  (cl-letf (((symbol-function 'emacos-call--at)
             (lambda (_cmd) "ATA\r\r\nVOICE CALL: BEGIN\r\nOK\r\n")))
    (should (string-prefix-p "answered:" (emacos-answer)))))

(ert-deftest emacos-answer-no-incoming-call ()
  "ATA with no call to answer (NO CARRIER) is an error, not a success."
  (cl-letf (((symbol-function 'emacos-call--at) (lambda (_cmd) "\r\nNO CARRIER\r\n")))
    (should (string-prefix-p "error: answer failed" (emacos-answer)))))

(ert-deftest emacos-answer-at-port-error-passthrough ()
  "A serial-port failure surfaces verbatim, not as a false success."
  (cl-letf (((symbol-function 'emacos-call--at)
             (lambda (_cmd) "error: AT port /dev/ttyUSB3: no such file")))
    (should (string-prefix-p "error:" (emacos-answer)))
    (should-not (string-prefix-p "answered:" (emacos-answer)))))

(ert-deftest emacos-call-render-incoming-context-and-plane ()
  "The incoming TOP buffer shows caller context only (controls live in the
keyboard plane) and sets the incoming keyboard plane."
  (with-current-buffer (emacos-call--render-incoming "+14155550123")
    (let ((s (buffer-string)))
      (should (string-match-p "Incoming call" s))
      (should (string-match-p (regexp-quote "+14155550123") s))
      (should-not (string-match-p "Decline" s))   ; moved to the plane
      (should-not (string-match-p "Accept" s)))
    (should (eq emacos--keyboard-plane #'emacos-call--plane-incoming)))
  (kill-buffer emacos-call--incoming-buffer))

(ert-deftest emacos-call-render-incoming-unknown-number ()
  (with-current-buffer (emacos-call--render-incoming "")
    (should (string-match-p "Unknown" (buffer-string))))
  (kill-buffer emacos-call--incoming-buffer))

(ert-deftest emacos-call-render-active-context-and-plane ()
  "The *call* TOP buffer shows status + number and sets the active plane."
  (with-current-buffer (emacos-call--render-active "+14155550123" "In progress")
    (let ((s (buffer-string)))
      (should (string-match-p "In progress" s))
      (should (string-match-p (regexp-quote "+14155550123") s)))
    (should (eq emacos--keyboard-plane #'emacos-call--plane-active)))
  (kill-buffer emacos-call--active-buffer))

;; The plane renderers paint *keyboard*; stub the os.el button + centering
;; primitives to capture labels (the planes run without os.el here).
(defmacro test-call--render-plane (plane &rest body)
  (declare (indent 1))
  `(cl-letf (((symbol-function 'emacos--btn)
              (lambda (label &rest _) (insert label)))
             ((symbol-function 'emacos--center) (lambda (s &rest _) s)))
     (with-temp-buffer
       (funcall ,plane)
       (let ((s (buffer-string))) ,@body))))

(ert-deftest emacos-call-plane-incoming-buttons ()
  "Incoming plane paints Decline + Accept; arming flips Accept's label."
  (let ((emacos-call--answer-confirm-pending nil))
    (test-call--render-plane #'emacos-call--plane-incoming
      (should (string-match-p "Decline" s))
      (should (string-match-p "Accept" s))
      (should-not (string-match-p "Confirm answer?" s))))
  (let ((emacos-call--answer-confirm-pending t))
    (test-call--render-plane #'emacos-call--plane-incoming
      (should (string-match-p "Confirm answer?" s)))))

(ert-deftest emacos-call-plane-active-buttons ()
  "Active plane paints Hang up + Back; arming flips Hang up's label."
  (let ((emacos-call--hangup-confirm-pending nil))
    (test-call--render-plane #'emacos-call--plane-active
      (should (string-match-p "Hang up" s))
      (should (string-match-p "Back" s))
      (should-not (string-match-p "Confirm hang up?" s))))
  (let ((emacos-call--hangup-confirm-pending t))
    (test-call--render-plane #'emacos-call--plane-active
      (should (string-match-p "Confirm hang up?" s)))))

(ert-deftest emacos-call-plane-gap-is-configurable ()
  "A short platform pane can retain both spatially separated controls."
  (let ((emacos-call-control-gap-lines 1)
        (emacos-call--answer-confirm-pending nil))
    (test-call--render-plane #'emacos-call--plane-incoming
      (should (string-match-p "Decline\n\nAccept" s)))))

(ert-deftest emacos-call-on-call-added-incoming-shows ()
  "An INCOMING call (Direction=1) records path/number, sets state, shows the
incoming screen."
  (let ((shown nil) (emacos-call--call-path nil) (emacos-call--state nil))
    (cl-letf (((symbol-function 'emacos-call--call-prop)
               (lambda (_p prop) (pcase prop ("Direction" 1) ("Number" "+14155550123"))))
              ((symbol-function 'emacos-call--watch-call-end) #'ignore)
              ((symbol-function 'emacos-call-show-incoming)
               (lambda (num) (setq shown num))))
      (emacos-call--on-call-added "/org/freedesktop/ModemManager1/Call/0")
      (should (equal shown "+14155550123"))
      (should (eq emacos-call--state 'incoming))
      (should (equal emacos-call--call-path
                     "/org/freedesktop/ModemManager1/Call/0")))))

(ert-deftest emacos-call-on-call-added-incoming-wakes-before-showing ()
  (let* ((events nil) (emacos-call--state nil)
        (emacos-call-wake-function (lambda () (push 'wake events))))
    (cl-letf (((symbol-function 'emacos-call--call-prop)
               (lambda (_path prop) (pcase prop ("Direction" 1) ("Number" "1"))))
              ((symbol-function 'emacos-call--watch-call-end) #'ignore)
              ((symbol-function 'emacos-call-show-incoming)
               (lambda (_number) (push 'show events))))
      (emacos-call--on-call-added "/org/freedesktop/ModemManager1/Call/0")
      (should (equal (nreverse events) '(wake show))))))

(ert-deftest emacos-call-on-call-added-outgoing-shows-active ()
  "An OUTGOING call (Direction=2) shows the in-progress *call* screen, not the
incoming screen."
  (let ((active nil) (incoming nil) (emacos-call--state nil) (emacos-call--call-path nil))
    (cl-letf (((symbol-function 'emacos-call--call-prop)
               (lambda (_p prop) (pcase prop ("Direction" 2) ("Number" "+1999"))))
              ((symbol-function 'emacos-call--watch-call-end) #'ignore)
              ((symbol-function 'emacos-call-show-incoming) (lambda (_n) (setq incoming t)))
              ((symbol-function 'emacos-call--show-active) (lambda (_s) (setq active t))))
      (emacos-call--on-call-added "/org/freedesktop/ModemManager1/Call/9")
      (should active)
      (should-not incoming)
      (should (eq emacos-call--state 'active)))))

(ert-deftest emacos-call-on-call-state-active-and-terminated ()
  "State 4 (active) flips state to active and does NOT dismiss; 7 dismisses."
  (let ((dismissed 0) (emacos-call--state 'incoming))
    (cl-letf (((symbol-function 'emacos-call--dismiss) (lambda () (cl-incf dismissed)))
              ;; no windows in batch -> the active branch's get-buffer-window
              ;; both return nil, so on-call-state just flips state.
              ((symbol-function 'emacos-call--show-active) (lambda (&rest _) nil))
              ((symbol-function 'emacos-call--render-active) (lambda (&rest _) nil)))
      (emacos-call--on-call-state 3 4 0)
      (should (= dismissed 0))
      (should (eq emacos-call--state 'active))
      (emacos-call--on-call-state 4 7 0)
      (should (= dismissed 1)))))

(ert-deftest emacos-call-answer-tap-two-tap ()
  "First Accept tap arms (no answer); second answers + shows in-progress."
  (let ((answered 0) (active 0)
        (emacos-call--answer-confirm-pending nil) (emacos-call--state nil))
    (cl-letf (((symbol-function 'emacos-answer) (lambda () (cl-incf answered) "answered: x"))
              ((symbol-function 'emacos-call--show-active) (lambda (&rest _) (cl-incf active))))
      (emacos-call--answer-tap)
      (should emacos-call--answer-confirm-pending)
      (should (= answered 0))
      (emacos-call--answer-tap)
      (should (= answered 1))
      (should (= active 1))
      (should (eq emacos-call--state 'active))
      (should-not emacos-call--answer-confirm-pending))))

(ert-deftest emacos-call-answer-tap-failure-dismisses ()
  "A failed answer (not \"answered:\") dismisses rather than showing active."
  (let ((dismissed 0) (emacos-call--answer-confirm-pending t))
    (cl-letf (((symbol-function 'emacos-answer) (lambda () "error: answer failed"))
              ((symbol-function 'emacos-call--show-active)
               (lambda (&rest _) (error "should not show active on failure")))
              ((symbol-function 'emacos-call--dismiss) (lambda () (cl-incf dismissed))))
      (emacos-call--answer-tap)
      (should (= dismissed 1)))))

(ert-deftest emacos-call-hangup-tap-two-tap ()
  "First Hang-up tap arms; second hangs up + dismisses."
  (let ((hung 0) (dismissed 0) (emacos-call--hangup-confirm-pending nil))
    (cl-letf (((symbol-function 'emacos-hang-up) (lambda () (cl-incf hung) "hung-up: x"))
              ((symbol-function 'emacos-call--dismiss) (lambda () (cl-incf dismissed))))
      (emacos-call--hangup-tap)
      (should emacos-call--hangup-confirm-pending)
      (should (= hung 0))
      (emacos-call--hangup-tap)
      (should (= hung 1))
      (should (= dismissed 1))
      (should-not emacos-call--hangup-confirm-pending))))

(ert-deftest emacos-call-maybe-disarm-clears-pending ()
  "A non-arming tap disarms a pending two-tap (Accept or Hang-up); the arming
button itself keeps it."
  (let ((emacos-call--answer-confirm-pending t))
    (emacos-call--maybe-disarm #'emacos-call--decline nil)
    (should-not emacos-call--answer-confirm-pending))
  (let ((emacos-call--answer-confirm-pending t))
    (emacos-call--maybe-disarm #'emacos-call--answer-tap nil)
    (should emacos-call--answer-confirm-pending))
  (let ((emacos-call--hangup-confirm-pending t))
    (emacos-call--maybe-disarm #'emacos-call--back nil)
    (should-not emacos-call--hangup-confirm-pending))
  (let ((emacos-call--hangup-confirm-pending t))
    (emacos-call--maybe-disarm #'emacos-call--hangup-tap nil)
    (should emacos-call--hangup-confirm-pending)))

(ert-deftest emacos-call-mode-line-badge ()
  "Badge shows only while active AND the *call* screen is hidden."
  (let ((emacos-call--state nil))
    (should (equal (emacos-call-mode-line-string) "")))
  (when (get-buffer emacos-call--active-buffer)
    (kill-buffer emacos-call--active-buffer))
  (let ((emacos-call--state 'active))           ; no *call* window in batch
    (should (string-match-p "Call" (emacos-call-mode-line-string)))))

;; Dismiss restores the pre-call buffer.  The window stubs are variadic + guard
;; on our fake `win'; kill-buffer is no-op'd so the test isolates the restore.
(defmacro test-call--with-dismiss-window (restored-var &rest body)
  (declare (indent 1))
  `(cl-letf (((symbol-function 'emacos--target) (lambda () 'win))
             ((symbol-function 'window-buffer)
              (lambda (&rest _) (get-buffer emacos-call--incoming-buffer)))
             ((symbol-function 'set-window-buffer)
              (lambda (w b &rest _) (when (eq w 'win) (setq ,restored-var b))))
             ((symbol-function 'kill-buffer) (lambda (&rest _) nil)))
     (get-buffer-create emacos-call--incoming-buffer)
     ,@body))

(ert-deftest emacos-call-dismiss-restores-prev-buffer ()
  "Dismiss restores the captured pre-call buffer when live, and clears state."
  (let ((prev (get-buffer-create "test-prev")) (restored nil))
    (test-call--with-dismiss-window restored
      (let ((emacos-call--prev-buffer prev) (emacos-call--state 'active))
        (emacos-call--dismiss)
        (should (eq restored prev))
        (should-not emacos-call--prev-buffer)     ; cleared
        (should-not emacos-call--state)))         ; cleared
    (when (buffer-live-p prev) (kill-buffer prev))))

(ert-deftest emacos-call-dismiss-falls-back-to-scratch-when-prev-dead ()
  "If the captured buffer was killed mid-call, dismiss restores *scratch*,
not a dead buffer."
  (let ((dead (get-buffer-create "test-dead")) (restored nil))
    (kill-buffer dead)
    (test-call--with-dismiss-window restored
      (let ((emacos-call--prev-buffer dead))
        (emacos-call--dismiss)
        (should (eq restored (get-buffer-create "*scratch*")))))))

(ert-deftest emacos-call-back-restores-prev-keeps-active ()
  "Back returns to the pre-call buffer but leaves the call RUNNING (state
stays `active', so the modeline badge appears) and disarms a pending hang-up."
  (let ((prev (get-buffer-create "test-prev")) (restored nil)
        (emacos-call--state 'active)
        (emacos-call--hangup-confirm-pending t))
    (get-buffer-create emacos-call--active-buffer)
    (let ((emacos-call--prev-buffer prev))
      (cl-letf (((symbol-function 'emacos--target) (lambda () 'win))
                ((symbol-function 'window-buffer)
                 (lambda (&rest _) (get-buffer emacos-call--active-buffer)))
                ((symbol-function 'set-window-buffer)
                 (lambda (w b &rest _) (when (eq w 'win) (setq restored b)))))
        (emacos-call--back)
        (should (eq restored prev))               ; returned to pre-call buffer
        (should (eq emacos-call--state 'active))   ; call still running
        (should-not emacos-call--hangup-confirm-pending)))
    (when (buffer-live-p prev) (kill-buffer prev))
    (when (get-buffer emacos-call--active-buffer)
      (kill-buffer emacos-call--active-buffer))))

(provide 'test-call)
;;; test-call.el ends here
