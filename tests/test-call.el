;;; test-call.el --- Tests for phone-call.el deterministic primitives -*- lexical-binding: t -*-

;; Covers the PURE logic of emacos-call / emacos-hang-up: number validation,
;; the segfault-safe full-call-path extraction, the start-failure cleanup, and
;; the status-string contract.  Real mmcli execution + actually dialing are
;; validated on the live phone, not here -- emacos-call--mmcli is stubbed.

(require 'ert)
(require 'cl-lib)
(require 'phone-call)

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
    (or (cdr (cl-find-if (lambda (r) (funcall (car r) args)) responses))
        (cons 0 ""))))

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
            (cons (lambda (a) (member "--start" a)) (cons 1 "error")))
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

(provide 'test-call)
;;; test-call.el ends here
