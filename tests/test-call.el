;;; test-call.el --- Tests for phone-call.el deterministic primitives -*- lexical-binding: t -*-

;; Covers the PURE logic of emacos-call / emacos-hang-up: number validation,
;; the segfault-safe full-call-path extraction, the start-failure cleanup, and
;; the status-string contract.  Real mmcli execution + actually dialing are
;; validated on the live phone, not here -- emacos-call--mmcli is stubbed.

(require 'ert)
(require 'cl-lib)
(require 'phone-call)
(require 'os)   ; for emacos--btn-label-scale (render tests) — keeps this file self-contained

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

(ert-deftest emacos-call-render-incoming-shows-number-and-buttons ()
  "The screen renders the caller number + Answer + Decline; arming the
two-tap flips the Answer label."
  (cl-letf (((symbol-function 'emacos--btn)
             (lambda (label &rest _) (insert label "\n"))))
    (let ((emacos--btn-label-scale 0.8)
          (emacos-call--answer-confirm-pending nil))
      (with-current-buffer (emacos-call--render-incoming "+14155550123")
        (let ((s (buffer-string)))
          (should (string-match-p "Incoming call" s))
          (should (string-match-p (regexp-quote "+14155550123") s))
          (should (string-match-p "Answer" s))
          (should (string-match-p "Decline" s))
          (should-not (string-match-p "Confirm answer?" s))))
      (let ((emacos-call--answer-confirm-pending t))
        (with-current-buffer (emacos-call--render-incoming "+14155550123")
          (should (string-match-p "Confirm answer?" (buffer-string)))))
      (kill-buffer emacos-call--incoming-buffer))))

(ert-deftest emacos-call-render-incoming-unknown-number ()
  (cl-letf (((symbol-function 'emacos--btn) (lambda (label &rest _) (insert label "\n"))))
    (let ((emacos--btn-label-scale 0.8) (emacos-call--answer-confirm-pending nil))
      (with-current-buffer (emacos-call--render-incoming "")
        (should (string-match-p "Unknown" (buffer-string))))
      (kill-buffer emacos-call--incoming-buffer))))

(ert-deftest emacos-call-on-call-added-incoming-shows ()
  "An INCOMING call (Direction=1) records the path/number and shows the screen."
  (let ((shown nil) (emacos-call--ringing-path nil))
    (cl-letf (((symbol-function 'emacos-call--call-prop)
               (lambda (_p prop) (pcase prop ("Direction" 1) ("Number" "+14155550123"))))
              ((symbol-function 'emacos-call--watch-call-end) #'ignore)
              ((symbol-function 'emacos-call-show-incoming)
               (lambda (num) (setq shown num))))
      (emacos-call--on-call-added "/org/freedesktop/ModemManager1/Call/0")
      (should (equal shown "+14155550123"))
      (should (equal emacos-call--ringing-path
                     "/org/freedesktop/ModemManager1/Call/0")))))

(ert-deftest emacos-call-on-call-added-outgoing-ignored ()
  "An OUTGOING call (Direction=2) must NOT pop the incoming screen."
  (let ((shown nil) (emacos-call--ringing-path nil))
    (cl-letf (((symbol-function 'emacos-call--call-prop)
               (lambda (_p prop) (pcase prop ("Direction" 2) ("Number" "+1999"))))
              ((symbol-function 'emacos-call-show-incoming)
               (lambda (_num) (setq shown t))))
      (emacos-call--on-call-added "/org/freedesktop/ModemManager1/Call/9")
      (should-not shown)
      (should-not emacos-call--ringing-path))))

(ert-deftest emacos-call-on-call-state-dismisses-on-terminated ()
  "The watched call going terminated (state 7) dismisses the screen; other
states (e.g. active=4) do not."
  (let ((dismissed 0))
    (cl-letf (((symbol-function 'emacos-call--dismiss-incoming)
               (lambda () (cl-incf dismissed))))
      (emacos-call--on-call-state 3 4 0) (should (= dismissed 0))    ; ringing->active
      (emacos-call--on-call-state 4 7 0) (should (= dismissed 1))))) ; ->terminated

(ert-deftest emacos-call-answer-tap-two-tap ()
  "First Answer tap arms (no answer); second tap answers + dismisses."
  (let ((answered 0) (dismissed 0)
        (emacos-call--answer-confirm-pending nil))
    (cl-letf (((symbol-function 'emacos-answer) (lambda () (cl-incf answered) "answered: x"))
              ((symbol-function 'emacos-call--dismiss-incoming) (lambda () (cl-incf dismissed)))
              ((symbol-function 'emacos-call--render-incoming) (lambda (&rest _) nil)))
      (emacos-call--answer-tap)
      (should emacos-call--answer-confirm-pending)
      (should (= answered 0))
      (emacos-call--answer-tap)
      (should (= answered 1))
      (should (= dismissed 1))
      (should-not emacos-call--answer-confirm-pending))))

(ert-deftest emacos-call-maybe-disarm-clears-on-other-tap ()
  "A tap that isn't Answer disarms a pending two-tap; the Answer tap keeps it."
  (cl-letf (((symbol-function 'emacos-call--render-incoming) (lambda (&rest _) nil)))
    (let ((emacos-call--answer-confirm-pending t))
      (emacos-call--maybe-disarm #'emacos-call--decline nil)
      (should-not emacos-call--answer-confirm-pending))
    (let ((emacos-call--answer-confirm-pending t))
      (emacos-call--maybe-disarm #'emacos-call--answer-tap nil)
      (should emacos-call--answer-confirm-pending))))

;; The dismiss stubs are variadic + guard on our fake `win' (the real
;; set-window-buffer takes a 3rd arg, and kill-buffer's window machinery calls
;; it too); kill-buffer is no-op'd so the test isolates the restore decision.
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
  "Dismiss restores the captured pre-call buffer when it is still live."
  (let ((prev (get-buffer-create "test-prev")) (restored nil))
    (test-call--with-dismiss-window restored
      (let ((emacos-call--prev-buffer prev))
        (emacos-call--dismiss-incoming)
        (should (eq restored prev))
        (should-not emacos-call--prev-buffer)))   ; cleared
    (when (buffer-live-p prev) (kill-buffer prev))))

(ert-deftest emacos-call-dismiss-falls-back-to-scratch-when-prev-dead ()
  "If the captured buffer was killed mid-ring, dismiss restores *scratch*,
not a dead buffer."
  (let ((dead (get-buffer-create "test-dead")) (restored nil))
    (kill-buffer dead)
    (test-call--with-dismiss-window restored
      (let ((emacos-call--prev-buffer dead))
        (emacos-call--dismiss-incoming)
        (should (eq restored (get-buffer-create "*scratch*")))))))

(provide 'test-call)
;;; test-call.el ends here
