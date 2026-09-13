;;; test-call.el --- Tests for phone-call.el deterministic primitives -*- lexical-binding: t -*-

;; Covers public call proposals plus the private dial / hang-up transports:
;; the segfault-safe full-call-path extraction, the start-failure cleanup, and
;; the status-string contract.  Real mmcli execution + actually dialing are
;; validated on the live phone, not here -- emacsos-call--mmcli is stubbed.

(require 'ert)
(require 'cl-lib)
(require 'phone-call)
;; The render tests stub `emacsos--btn'; they only need a value for the
;; `emacsos--btn-label-scale' arg it's passed (phone-call.el declares the var
;; without a value).  Bind a dummy here instead of pulling in all of os.el.
(defvar emacsos--btn-label-scale 0.8)
;; os.el defines this buffer-local; the screen renderers set it.  Declare it
;; here (os.el isn't loaded in these tests) so it goes buffer-local as on device.
(defvar-local emacsos--keyboard-plane nil)

;; Special (dynamic) so the stub lambda built in `test-call--stub' and the
;; `let'-binding in `test-call--with' refer to the SAME variable across
;; functions (a lexical binding wouldn't reach the stub).
(defvar test-call--seen nil
  "Arg-lists passed to the stubbed `emacsos-call--mmcli', most-recent-first.")

(defun test-call--stub (responses)
  "Return a stub for `emacsos-call--mmcli' driven by RESPONSES.
RESPONSES is a list of (PRED . (CODE . OUT)); the first PRED matching the
arg list wins.  Also records calls in the dynamic var `test-call--seen'."
  (lambda (&rest args)
    (push args test-call--seen)
    (let ((hit (cl-find-if (lambda (r) (funcall (car r) args)) responses)))
      (if hit
          (cdr hit)
        ;; Fail loudly on an unanticipated mmcli call rather than masking it
        ;; with a default success — a test must declare every call it expects.
        (error "unexpected emacsos-call--mmcli call: %S" args)))))

(defmacro test-call--with (responses &rest body)
  (declare (indent 1))
  `(let ((test-call--seen nil))
     (cl-letf (((symbol-function 'emacsos-call--mmcli)
                (test-call--stub ,responses)))
       ,@body)))

(defun test-call--has (args sub)
  "Non-nil if ARGS contains an element with SUB as a substring."
  (cl-some (lambda (a) (and (stringp a) (string-match-p (regexp-quote sub) a))) args))

(defconst test-call--owner ":1.test")

;; D-Bus is absent in batch.  Give direct signal-handler tests one stable
;; service owner; tests of restart behavior override this function locally.
(defalias 'emacsos-call--modem-manager-owner (lambda () test-call--owner))

(defmacro test-call--with-ui (&rest body)
  "Run BODY with one fake phone top window and isolated call state."
  (declare (indent 0))
  `(let ((test-call--window-buffer (get-buffer-create "test-call-home"))
         (emacsos-call--state nil)
         (emacsos-call--state-handle nil)
         (emacsos-call--watched-call nil)
         (emacsos-call--call-path nil)
         (emacsos-call--call-owner nil)
         (emacsos-call--call-number nil)
         (emacsos-call--prev-buffer nil)
         (emacsos-call--next-proposal-id 0)
         (emacsos-call--proposal-id nil)
         (emacsos-call--dial-confirm-id nil)
         (emacsos-call--dial-confirm-timer nil)
         (emacsos-call--skip-next-post-command-disarm nil)
         (emacsos-call--failure-reason nil)
         (emacsos-call--ignored-call-path nil)
         (emacsos-call--ignored-call-owner nil)
         (emacsos-call--requested-call-events nil)
         (emacsos-call--deferred-call-event nil)
         (emacsos-call--owner-generation 0)
         (emacsos-call--current-owner test-call--owner)
         (emacsos-call--next-operation-id 0)
         (emacsos-call--pending-operation nil))
     (cl-letf (((symbol-function 'emacsos--target) (lambda () 'win))
               ((symbol-function 'window-buffer)
                (lambda (&rest _) test-call--window-buffer))
               ((symbol-function 'set-window-buffer)
                (lambda (_win buffer &rest _)
                  (setq test-call--window-buffer buffer)))
               ((symbol-function 'emacsos-call--modem-manager-owner)
                (lambda () test-call--owner))
               ((symbol-function 'emacsos-call--call-snapshot-async)
                (lambda (owner path completion)
                  (let ((emacsos-call--property-owner owner))
                    (funcall completion
                             (list (emacsos-call--call-prop path "Direction")
                                   (emacsos-call--call-prop path "State")
                                   (or (emacsos-call--call-prop
                                        path "Number") ""))))))
               ((symbol-function 'emacsos-call--rerender) #'ignore)
               ((symbol-function 'run-at-time)
                (lambda (&rest _) 'test-call-timer))
               ((symbol-function 'timerp)
                (lambda (value) (eq value 'test-call-timer)))
               ((symbol-function 'cancel-timer) #'ignore))
       (unwind-protect
           (progn ,@body)
         (dolist (name '("test-call-home" "*call*" "*incoming-call*"))
           (when (get-buffer name) (kill-buffer name)))))))

(ert-deftest emacsos-call-rejects-non-number ()
  "A name (or anything non-numeric) errors without touching mmcli."
  (test-call--with nil
    (should (string-prefix-p "error: invalid number" (emacsos-call--dial "Ana")))
    (should (null test-call--seen))))

(ert-deftest emacsos-call-dials-and-extracts-full-path ()
  (test-call--with
      (list (cons (lambda (a) (member "-L" a))
                  (cons 0 "  /org/freedesktop/ModemManager1/Modem/3 [QUALCOMM] SIM7600"))
            (cons (lambda (a) (test-call--has a "--voice-create-call"))
                  (cons 0 "Successfully created new call: /org/freedesktop/ModemManager1/Call/2"))
            (cons (lambda (a) (member "--start" a)) (cons 0 "")))
    (should (equal (emacsos-call--dial "+14155550123")
                   "dialing: /org/freedesktop/ModemManager1/Call/2"))))

(ert-deftest emacsos-call-no-modem ()
  (test-call--with (list (cons (lambda (a) (member "-L" a)) (cons 0 "No modems were found")))
    (should (equal (emacsos-call--dial "+14155550123") "error: no modem found"))))

(ert-deftest emacsos-call-start-failure-hangs-up ()
  (test-call--with
      (list (cons (lambda (a) (member "-L" a))
                  (cons 0 "/org/freedesktop/ModemManager1/Modem/3"))
            (cons (lambda (a) (test-call--has a "--voice-create-call"))
                  (cons 0 "Successfully created new call: /org/freedesktop/ModemManager1/Call/2"))
            (cons (lambda (a) (member "--start" a)) (cons 1 "error"))
            (cons (lambda (a) (member "--hangup" a)) (cons 0 "")))
    (should (string-prefix-p
             "error: call-path=/org/freedesktop/ModemManager1/Call/2; dial failed"
             (emacsos-call--dial "+14155550123")))
    ;; start failed -> we must have issued a --hangup on the created path
    (should (cl-some (lambda (a) (member "--hangup" a)) test-call--seen))))

(ert-deftest emacsos-call-start-and-cleanup-failure-stays-uncertain ()
  (test-call--with
      (list (cons (lambda (a) (member "-L" a))
                  (cons 0 "/org/freedesktop/ModemManager1/Modem/3"))
            (cons (lambda (a) (test-call--has a "--voice-create-call"))
                  (cons 0 "created /org/freedesktop/ModemManager1/Call/2"))
            (cons (lambda (a) (member "--start" a)) (cons 1 "start timed out"))
            (cons (lambda (a) (member "--hangup" a)) (cons 1 "cleanup failed")))
    (should (equal
             (emacsos-call--dial "+14155550123")
             (concat "error: uncertain-call-path="
                     "/org/freedesktop/ModemManager1/Call/2; "
                     "dial failed: start timed out; cleanup failed: cleanup failed")))))

(ert-deftest emacsos-call-start-failure-normalizes-multiline-diagnostics ()
  (test-call--with
      (list (cons (lambda (a) (member "-L" a))
                  (cons 0 "/org/freedesktop/ModemManager1/Modem/3"))
            (cons (lambda (a) (test-call--has a "--voice-create-call"))
                  (cons 0 "created /org/freedesktop/ModemManager1/Call/2"))
            (cons (lambda (a) (member "--start" a))
                  (cons 1 "start\n rejected\t now"))
            (cons (lambda (a) (member "--hangup" a))
                  (cons 1 "cleanup\n failed")))
    (should (equal
             (emacsos-call--dial "+14155550123")
             (concat "error: uncertain-call-path="
                     "/org/freedesktop/ModemManager1/Call/2; "
                     "dial failed: start rejected now; "
                     "cleanup failed: cleanup failed")))))

(ert-deftest emacsos-hang-up-status ()
  (test-call--with
      (list (cons (lambda (a) (member "-L" a))
                  (cons 0 "/org/freedesktop/ModemManager1/Modem/3"))
            (cons (lambda (a) (member "--voice-hangup-all" a)) (cons 0 "")))
    (should (string-prefix-p "hung-up:" (emacsos-hang-up)))))

(ert-deftest emacsos-call-create-failure ()
  "Create yields no /Call/N path -> error, and --start is never issued."
  (test-call--with
      (list (cons (lambda (a) (member "-L" a))
                  (cons 0 "/org/freedesktop/ModemManager1/Modem/3"))
            (cons (lambda (a) (test-call--has a "--voice-create-call"))
                  (cons 1 "error: couldn't create call")))
    (should (string-prefix-p "error: could not create call"
                             (emacsos-call--dial "+14155550123")))
    (should-not (cl-some (lambda (a) (member "--start" a)) test-call--seen))))

(ert-deftest emacsos-call-legacy-errors-are-bounded-one-line-statuses ()
  (test-call--with
      (list (cons (lambda (args) (member "-L" args))
                  (cons 0 "/org/freedesktop/ModemManager1/Modem/3"))
            (cons (lambda (args) (test-call--has args "--voice-create-call"))
                  (cons 1 "create\nfailed\tbadly")))
    (should (equal (emacsos-call--dial "+14155550123")
                   "error: could not create call: create failed badly")))
  (test-call--with
      (list (cons (lambda (args) (member "-L" args))
                  (cons 0 "/org/freedesktop/ModemManager1/Modem/3"))
            (cons (lambda (args) (member "--voice-hangup-all" args))
                  (cons 1 "hangup\nfailed\tbadly")))
    (should (equal (emacsos-hang-up)
                   "error: hangup failed: hangup failed badly"))))

(ert-deftest emacsos-call-sudo-unavailable ()
  "Denied mmcli (no passwordless sudo) is reported distinctly, not as no-modem."
  (test-call--with
      (list (cons (lambda (a) (member "-L" a))
                  (cons 1 "sudo: a password is required")))
    (should (string-prefix-p "error: mmcli unavailable"
                             (emacsos-call--dial "+14155550123")))))

(ert-deftest emacsos-call-number-boundaries ()
  "Too short / too long reject without touching mmcli (the dial guard)."
  (test-call--with nil
    (should (string-prefix-p "error: invalid number" (emacsos-call--dial "1234")))
    (should (string-prefix-p "error: invalid number"
                             (emacsos-call--dial "1234567890123456")))
    (should (null test-call--seen))))

(ert-deftest emacsos-call-platform-dial-routes-audio-and-operation ()
  (let ((emacsos-call-operation-function
         (lambda (operation _owner value _completion)
           (should (eq operation 'dial))
           (should (equal value "+14155550123"))
           "dialing: /org/freedesktop/ModemManager1/Call/4"))
        (emacsos-call-audio-function (lambda (active) (should active))))
    (should (string-prefix-p "dialing:" (emacsos-call--dial "+14155550123")))))

(ert-deftest emacsos-call-terminal-handler-restores-audio-on-sync-failure ()
  (let* ((audio nil)
        (emacsos-call-operation-function (lambda (&rest _) "error: rejected"))
        (emacsos-call-audio-function (lambda (active) (push active audio))))
    (setq emacsos-call--state 'dial-requested
          emacsos-call--proposal-id 1
          emacsos-call--call-number "+14155550123")
    (let ((status (emacsos-call--dial "+14155550123")))
      (should (equal (nreverse audio) '(t)))
      (emacsos-call--dial-finished 1 test-call--owner status))
    (should (equal (nreverse audio) '(t nil)))))

(ert-deftest emacsos-call-platform-answer-uses-tracked-path ()
  (let ((emacsos-call--state 'incoming)
        (emacsos-call--call-owner ":1.42")
        (emacsos-call--call-path "/org/freedesktop/ModemManager1/Call/8")
        (emacsos-call-audio-function #'ignore)
        (emacsos-call-operation-function
         (lambda (operation _owner value _completion)
           (should (eq operation 'answer))
           (should (equal value "/org/freedesktop/ModemManager1/Call/8"))
           "answered: call active")))
    (should (string-prefix-p "answered:" (emacsos-answer)))))

(ert-deftest emacsos-call-platform-hangup-restores-audio ()
  (let* ((path "/org/freedesktop/ModemManager1/Call/8")
        (emacsos-call--state 'active)
        (emacsos-call--call-owner ":1.42")
        (emacsos-call--call-path path)
        (audio 'unset)
        (emacsos-call-operation-function
         (lambda (operation _owner value _completion)
           (should (eq operation 'hangup))
           (should (equal value path))
           "hung-up: call ended"))
        (emacsos-call-audio-function (lambda (active) (setq audio active))))
    (should (string-prefix-p "hung-up:" (emacsos-hang-up)))
    (should-not audio)))

(ert-deftest emacsos-call-platform-hangup-restores-audio-on-completion ()
  (let (backend-completion audio)
    (let ((emacsos-call--state 'active)
          (emacsos-call--call-owner ":1.42")
          (emacsos-call--call-path "/org/freedesktop/ModemManager1/Call/8")
          (emacsos-call-operation-function
           (lambda (_operation _owner _value completion)
             (setq backend-completion completion)
             "pending: hangup requested"))
          (emacsos-call-audio-function
           (lambda (active) (push active audio))))
      (should (string-prefix-p
               "pending:" (emacsos-hang-up)))
      (should-not audio)
      (funcall backend-completion "hung-up: all calls ended")
      (should (equal audio '(nil))))))

(ert-deftest emacsos-call-direct-async-hangup-failure-remains-visible ()
  (let ((emacsos-call--state 'active)
        (emacsos-call--call-number "+14155550123")
        backend-completion shown)
    (let ((emacsos-call-operation-function
           (lambda (_operation _owner _value completion)
             (setq backend-completion completion)
             "pending: hangup requested")))
      (cl-letf (((symbol-function 'emacsos-call--show-active)
                 (lambda (status) (setq shown status))))
        (should (string-prefix-p "pending:" (emacsos-hang-up)))
        (funcall backend-completion "error: modem busy")
        (should (eq emacsos-call--state 'active))
        (should (equal shown "Hang up failed"))))))

(ert-deftest emacsos-call-direct-async-answer-success-updates-visible-state ()
  (let ((emacsos-call--state 'incoming)
        (emacsos-call--call-owner ":1.42")
        (emacsos-call--call-path "/org/freedesktop/ModemManager1/Call/8")
        (emacsos-call--call-number "+14155550123")
        backend-completion shown)
    (let ((emacsos-call-operation-function
           (lambda (_operation _owner _value completion)
             (setq backend-completion completion)
             "pending: answer requested"))
          (emacsos-call-audio-function #'ignore))
      (cl-letf (((symbol-function 'emacsos-call--show-active)
                 (lambda (status) (setq shown status))))
        (should (string-prefix-p "pending:" (emacsos-answer)))
        (funcall backend-completion "answered: call active")
        (should (eq emacsos-call--state 'active))
        (should (equal shown "In progress"))))))

(ert-deftest emacsos-call-direct-answer-completion-cannot-update-replacement ()
  (let ((emacsos-call--state 'incoming)
        (emacsos-call--call-owner ":1.old")
        (emacsos-call--call-path "/org/freedesktop/ModemManager1/Call/1")
        backend-completion shown audio)
    (let ((emacsos-call-operation-function
           (lambda (_operation _owner _value completion)
             (setq backend-completion completion)
             "pending: answer requested"))
          (emacsos-call-audio-function
           (lambda (active) (push active audio))))
      (cl-letf (((symbol-function 'emacsos-call--show-active)
                 (lambda (status) (setq shown status))))
        (emacsos-answer)
        (setq emacsos-call--pending-operation nil
              emacsos-call--state 'incoming
              emacsos-call--call-owner ":1.new"
              emacsos-call--call-path "/org/freedesktop/ModemManager1/Call/1")
        (funcall backend-completion "answered: old call active")
        (should (eq emacsos-call--state 'incoming))
        (should-not shown)
        (should (equal audio '(t)))))))

(ert-deftest emacsos-call-direct-hangup-completion-cannot-dismiss-replacement ()
  (let ((emacsos-call--state 'active)
        (emacsos-call--call-owner ":1.old")
        (emacsos-call--call-path "/org/freedesktop/ModemManager1/Call/1")
        backend-completion dismissed audio)
    (let ((emacsos-call-operation-function
           (lambda (_operation _owner _value completion)
             (setq backend-completion completion)
             "pending: hangup requested"))
          (emacsos-call-audio-function
           (lambda (active) (push active audio))))
      (cl-letf (((symbol-function 'emacsos-call--dismiss)
                 (lambda () (setq dismissed t))))
        (emacsos-hang-up)
        (setq emacsos-call--pending-operation nil
              emacsos-call--state 'active
              emacsos-call--call-owner ":1.new"
              emacsos-call--call-path "/org/freedesktop/ModemManager1/Call/1")
        (funcall backend-completion "hung-up: old call ended")
        (should-not dismissed)
        (should-not audio)))))

(ert-deftest emacsos-call-platform-hangup-failure-keeps-call-audio ()
  (let* ((audio nil)
         (emacsos-call-operation-function
          (lambda (&rest _) "error: hangup failed"))
         (emacsos-call-audio-function (lambda (active) (push active audio))))
    (should (string-prefix-p "error:" (emacsos-hang-up)))
    (should-not audio)))

(ert-deftest emacsos-call-untracked-platform-errors-do-not-create-call-ui ()
  (let ((emacsos-call--state nil)
        (emacsos-call--call-path nil)
        (emacsos-call--call-owner nil)
        (emacsos-call-operation-function
         (lambda (&rest _) "error: no tracked call")))
    (cl-letf (((symbol-function 'emacsos-call-show-incoming)
               (lambda (&rest _) (error "must not invent an incoming call")))
              ((symbol-function 'emacsos-call--show-active)
               (lambda (&rest _) (error "must not invent an active call"))))
      (should (string-prefix-p "error:" (emacsos-answer)))
      (should (string-prefix-p "error:" (emacsos-hang-up)))
      (should-not emacsos-call--pending-operation)
      (should-not emacsos-call--state))))

(ert-deftest emacsos-call-direct-operations-refuse-overlap ()
  "Public direct commands cannot replace an existing operation identity."
  (let ((emacsos-call--state 'incoming)
        (emacsos-call--call-owner ":1.42")
        (emacsos-call--call-path "/org/freedesktop/ModemManager1/Call/8")
        (emacsos-call--pending-operation '(7 answer path incoming owner))
        (emacsos-call-operation-function
         (lambda (&rest _) (error "overlapping backend invocation"))))
    (should (equal (emacsos-answer) "error: call operation already pending"))
    (should (equal (emacsos-hang-up) "error: call operation already pending"))
    (should (equal (emacsos-answer #'ignore)
                   "error: call operation already pending"))
    (should (equal (emacsos-hang-up #'ignore)
                   "error: call operation already pending"))
    (should (equal emacsos-call--pending-operation
                   '(7 answer path incoming owner)))))

(ert-deftest emacsos-call-platform-global-hangup-only-recovers-unknown-call ()
  (let ((emacsos-call--state 'proposed)
        (emacsos-call-operation-function
         (lambda (&rest _) (error "global hangup escaped its recovery state"))))
    (should (equal (emacsos-hang-up) "error: no tracked call")))
  (let* ((emacsos-call--state 'active)
         (emacsos-call--call-path nil)
         (seen nil)
        (emacsos-call-operation-function
         (lambda (operation owner value _completion)
           (setq seen (list operation value))
           (should-not owner)
           "hung-up: all calls ended")))
    (should (string-prefix-p "hung-up:" (emacsos-hang-up)))
    (should (equal seen '(hangup nil)))))

(ert-deftest emacsos-call-uncertain-answer-with-unreadable-state-stays-actionable ()
  (let ((emacsos-call--state 'incoming)
        (emacsos-call--call-path "/org/freedesktop/ModemManager1/Call/8")
        (emacsos-call--call-owner ":1.42")
        (emacsos-call--call-number "+14155550123")
        backend-completion snapshot-completion shown audio)
    (let ((emacsos-call-operation-function
           (lambda (_operation _owner _value completion)
             (setq backend-completion completion)
             "pending: answer requested"))
          (emacsos-call-audio-function
           (lambda (active) (push active audio))))
      (cl-letf (((symbol-function 'emacsos-call--modem-manager-owner)
                 (lambda () (error "synchronous owner read")))
                ((symbol-function 'emacsos-call--call-prop)
                 (lambda (&rest _) (error "synchronous property read")))
                ((symbol-function 'emacsos-call--call-snapshot-async)
                 (lambda (_owner _path completion)
                   (setq snapshot-completion completion)))
                ((symbol-function 'emacsos-call--show-active)
                 (lambda (status) (setq shown status))))
        (emacsos-answer)
        (funcall backend-completion
                 "error: uncertain-answer; helper status unavailable")
        (should emacsos-call--pending-operation)
        (funcall snapshot-completion nil)
        (should (eq emacsos-call--state 'active))
        (should-not emacsos-call--call-path)
        (should (equal shown "Status unknown"))
        (should (equal audio '(t)))))))

(ert-deftest emacsos-hang-up-no-modem ()
  (test-call--with (list (cons (lambda (a) (member "-L" a))
                               (cons 0 "No modems were found")))
    (should (string-prefix-p "error: no modem found" (emacsos-hang-up)))))

(ert-deftest emacsos-call--mmcli-catches-launch-failure ()
  "A process-launch failure (e.g. sudo absent) returns a status cons, not a
raised signal — so the primitives keep their string-return contract."
  (cl-letf (((symbol-function 'call-process)
             (lambda (&rest _)
               (signal 'file-error '("Searching for program" "no such file" "sudo")))))
    (let ((r (emacsos-call--mmcli "-L")))
      (should (= (car r) 1))
      (should (string-match-p "sudo" (cdr r))))))

(ert-deftest emacsos-call--mmcli-normalizes-signal-death ()
  "A signal-killed child (call-process returns a STRING) becomes a non-zero
INT code, so callers' (zerop code) never breaks; the description is kept."
  (cl-letf (((symbol-function 'call-process)
             (lambda (&rest _) (insert "partial") "Segmentation fault")))
    (let ((r (emacsos-call--mmcli "-L")))
      (should (integerp (car r)))
      (should (= (car r) 1))
      (should (string-match-p "Segmentation fault" (cdr r))))))

;;; Outgoing proposal and confirmation state machine ;;;

(ert-deftest emacsos-call-public-stages-without-dialing ()
  "The advertised command shows a proposal and cannot touch the backend."
  (test-call--with-ui
    (cl-letf (((symbol-function 'emacsos-call--dial)
               (lambda (&rest _) (error "dial must not run while staging"))))
      (should (equal (emacsos-call "+14155550123")
                     "confirmation-required: confirm on phone"))
      (should (eq emacsos-call--state 'proposed))
      (should (= emacsos-call--proposal-id 1))
      (should-not emacsos-call--dial-confirm-id)
      (should (eq test-call--window-buffer
                  (get-buffer emacsos-call--active-buffer))))))

(ert-deftest emacsos-call-public-rejects-during-a-tracked-call ()
  (test-call--with-ui
    (setq emacsos-call--state 'active
          emacsos-call--call-number "+14155550123")
    (should (equal (emacsos-call "+14155550124")
                   "error: call already in progress"))
    (should (equal emacsos-call--call-number "+14155550123"))))

(ert-deftest emacsos-call-restage-creates-new-unarmed-proposal ()
  "Replacing A with B cannot carry A's first activation into B."
  (test-call--with-ui
    (emacsos-call "+14155550123")
    (emacsos-call--dial-tap)
    (let ((old-id emacsos-call--proposal-id))
      (should (equal emacsos-call--dial-confirm-id old-id))
      (emacsos-call "+14155550124")
      (should (> emacsos-call--proposal-id old-id))
      (should-not emacsos-call--dial-confirm-id)
      (should (equal emacsos-call--call-number "+14155550124")))))

(ert-deftest emacsos-call-invalid-restage-disarms-existing-proposal ()
  "Even a rejected public command breaks adjacency between the local taps."
  (test-call--with-ui
    (emacsos-call "+14155550123")
    (emacsos-call--dial-tap)
    (should emacsos-call--dial-confirm-id)
    (should (string-prefix-p "error: invalid number" (emacsos-call "Ana")))
    (should-not emacsos-call--dial-confirm-id)
    (should (eq emacsos-call--state 'proposed))
    (should (equal emacsos-call--call-number "+14155550123"))))

(ert-deftest emacsos-call-two-visible-actions-dial-once ()
  "First action arms; only the second action on that proposal invokes dial."
  (test-call--with-ui
    (let ((dialed nil) completion)
      (cl-letf (((symbol-function 'emacsos-call--dial)
                 (lambda (number done _owner)
                   (push number dialed)
                   (setq completion done)
                   "pending: dial requested")))
        (emacsos-call "+14155550123")
        (emacsos-call--dial-tap)
        (should-not dialed)
        (emacsos-call--post-command-disarm)
        (emacsos-call--dial-tap)
        (should (equal dialed '("+14155550123")))
        (should (eq emacsos-call--state 'dial-requested))
        (should completion)))))

(ert-deftest emacsos-call-second-tap-uses-cached-owner-without-blocking ()
  "The authorized tap launches against the watched owner without a bus read."
  (test-call--with-ui
    (let (dialed dial-owner)
      (cl-letf (((symbol-function 'emacsos-call--modem-manager-owner)
                 (lambda () (error "synchronous owner lookup")))
                ((symbol-function 'emacsos-call--dial)
                 (lambda (number _completion owner)
                   (setq dialed number)
                   (setq dial-owner owner)
                   "pending: dial requested")))
        (emacsos-call "+14155550123")
        (emacsos-call--dial-tap)
        (emacsos-call--post-command-disarm)
        (emacsos-call--dial-tap)
        (should (equal dialed "+14155550123"))
        (should (equal dial-owner test-call--owner))
        (should (eq emacsos-call--state 'dial-requested))
        (should (equal emacsos-call--call-number "+14155550123"))
        (should (equal emacsos-call--proposal-id 1))
        (should-not emacsos-call--requested-call-events)))))

(ert-deftest emacsos-call-unrelated-command-disarms ()
  (test-call--with-ui
    (emacsos-call "+14155550123")
    (emacsos-call--dial-tap)
    (emacsos-call--post-command-disarm)
    (should emacsos-call--dial-confirm-id)
    (emacsos-call--post-command-disarm)
    (should-not emacsos-call--dial-confirm-id)))

(ert-deftest emacsos-call-hidden-proposal-cannot-confirm ()
  (test-call--with-ui
    (let ((dialed nil))
      (cl-letf (((symbol-function 'emacsos-call--dial)
                 (lambda (&rest _) (setq dialed t))))
        (emacsos-call "+14155550123")
        (emacsos-call--dial-tap)
        (setq test-call--window-buffer (get-buffer-create "test-call-other"))
        (emacsos-call--dial-tap)
        (should-not dialed)
        (should-not emacsos-call--dial-confirm-id)
        (kill-buffer "test-call-other")))))

(ert-deftest emacsos-call-confirm-timeout-is-proposal-bound ()
  (test-call--with-ui
    (emacsos-call "+14155550123")
    (emacsos-call--dial-tap)
    (let ((old-id emacsos-call--proposal-id))
      (emacsos-call "+14155550124")
      (emacsos-call--dial-tap)
      (emacsos-call--expire-dial-confirm old-id)
      (should (equal emacsos-call--dial-confirm-id emacsos-call--proposal-id))
      (emacsos-call--expire-dial-confirm emacsos-call--proposal-id)
      (should-not emacsos-call--dial-confirm-id))))

(ert-deftest emacsos-call-terminal-success-binds-exact-path ()
  (test-call--with-ui
    (let (watched shown)
      (setq emacsos-call--state 'dial-requested
            emacsos-call--proposal-id 7
            emacsos-call--call-number "+14155550123")
      (cl-letf (((symbol-function 'emacsos-call--watch-call-end)
                 (lambda (path _owner) (setq watched path)))
                ((symbol-function 'emacsos-call--call-prop)
                 (lambda (_path prop)
                   (pcase prop
                     ("Direction" 2)
                     ("State" 2)
                     ("Number" "+14155550123"))))
                ((symbol-function 'emacsos-call--show-active)
                 (lambda (status) (setq shown status))))
        (emacsos-call--dial-finished
         7 test-call--owner
         "dialing: /org/freedesktop/ModemManager1/Call/4")
        (should (eq emacsos-call--state 'active))
        (should (equal watched "/org/freedesktop/ModemManager1/Call/4"))
        (should (equal shown "Calling…"))))))

(ert-deftest emacsos-call-terminal-success-with-missing-state-stays-actionable ()
  "A modem restart after helper success leaves Hang up, not a phantom failure."
  (test-call--with-ui
    (let (shown)
      (setq emacsos-call--state 'dial-requested
            emacsos-call--proposal-id 7
            emacsos-call--call-number "+14155550123")
      (cl-letf (((symbol-function 'emacsos-call--watch-call-end) #'ignore)
                ((symbol-function 'emacsos-call--call-prop) #'ignore)
                ((symbol-function 'emacsos-call--show-active)
                 (lambda (status) (setq shown status))))
        (emacsos-call--dial-finished
         7 test-call--owner
         "dialing: /org/freedesktop/ModemManager1/Call/4")
        (should (eq emacsos-call--state 'active))
        (should (equal shown "Status unknown"))))))

(ert-deftest emacsos-call-terminal-success-rejects-reused-path-from-new-owner ()
  "A delayed helper result cannot bind a path reused after ModemManager restart."
  (test-call--with-ui
    (let (watched shown)
      (setq emacsos-call--state 'dial-requested
            emacsos-call--proposal-id 7
            emacsos-call--call-number "+14155550123")
      (cl-letf (((symbol-function 'emacsos-call--modem-manager-owner)
                 (lambda () ":1.new"))
                ((symbol-function 'emacsos-call--call-prop)
                 (lambda (_path prop)
                   (pcase prop
                     ("Direction" 2)
                     ("State" 2)
                     ("Number" "+19995550123"))))
                ((symbol-function 'emacsos-call--watch-call-end)
                 (lambda (&rest _) (setq watched t)))
                ((symbol-function 'emacsos-call--show-active)
                 (lambda (status) (setq shown status))))
        (emacsos-call--dial-finished
         7 ":1.old" "dialing: /org/freedesktop/ModemManager1/Call/4" 1)
        (should (eq emacsos-call--state 'active))
        (should-not emacsos-call--call-path)
        (should-not watched)
        (should (equal shown "Status unknown"))))))

(ert-deftest emacsos-call-terminal-success-reconciles-current-state ()
  "A state transition preceding helper completion is not lost."
  (dolist (case '((4 active "In progress") (7 nil "Calling…")))
    (test-call--with-ui
      (let ((current (nth 0 case)) shown)
        (setq emacsos-call--state 'dial-requested
              emacsos-call--proposal-id 7
              emacsos-call--call-number "+14155550123")
        (cl-letf (((symbol-function 'emacsos-call--watch-call-end) #'ignore)
                  ((symbol-function 'emacsos-call--call-prop)
                   (lambda (_path prop)
                     (pcase prop
                       ("Direction" 2)
                       ("State" current)
                       ("Number" "+14155550123"))))
                  ((symbol-function 'get-buffer-window)
                   (lambda (buffer &rest _)
                     (and (equal buffer emacsos-call--active-buffer) 'win)))
                  ((symbol-function 'emacsos-call--render-active)
                   (lambda (_number status) (setq shown status)))
                  ((symbol-function 'emacsos-call--show-active)
                   (lambda (status) (setq shown status))))
          (emacsos-call--dial-finished
           7 test-call--owner
           "dialing: /org/freedesktop/ModemManager1/Call/4")
          (should (eq emacsos-call--state (nth 1 case)))
          (should (equal shown (nth 2 case))))))))

(ert-deftest emacsos-call-terminal-failure-persists-and-stale-result-noops ()
  (test-call--with-ui
    (let ((audio nil))
      (setq emacsos-call--state 'dial-requested
            emacsos-call--proposal-id 8
            emacsos-call--call-number "+14155550123")
      (cl-letf (((symbol-function 'emacsos-call--audio)
                 (lambda (active) (setq audio active)))
                ((symbol-function 'emacsos-call--modem-manager-owner)
                 (lambda () ":1.42")))
        (emacsos-call--dial-finished 7 test-call--owner "error: stale")
        (should (eq emacsos-call--state 'dial-requested))
        (emacsos-call--dial-finished
         8 ":1.42"
         "error: call-path=/org/freedesktop/ModemManager1/Call/12; rejected by modem")
        (should (eq emacsos-call--state 'failed))
        (should (equal emacsos-call--ignored-call-path
                       "/org/freedesktop/ModemManager1/Call/12"))
        (should (equal emacsos-call--ignored-call-owner ":1.42"))
        (should-not audio)
        (should (string-match-p "rejected by modem"
                                (with-current-buffer emacsos-call--active-buffer
                                  (buffer-string))))))))

(ert-deftest emacsos-call-multiline-terminal-error-cannot-set-ignored-path ()
  "Only one exact helper status line may authorize a D-Bus tombstone."
  (test-call--with-ui
    (setq emacsos-call--state 'dial-requested
          emacsos-call--proposal-id 8
          emacsos-call--call-number "+14155550123")
    (cl-letf (((symbol-function 'emacsos-call--audio) #'ignore))
      (emacsos-call--dial-finished
       8 test-call--owner
       "error: call-path=/org/freedesktop/ModemManager1/Call/12; rejected\nextra")
      (should (eq emacsos-call--state 'failed))
      (should-not emacsos-call--ignored-call-path))))

(ert-deftest emacsos-call-uncertain-cleanup-keeps-hangup-and-audio ()
  "A possibly live call cannot be hidden behind the harmless failure plane."
  (test-call--with-ui
    (let ((audio nil) shown watched)
      (setq emacsos-call--state 'dial-requested
            emacsos-call--proposal-id 8
            emacsos-call--call-number "+14155550123")
      (cl-letf (((symbol-function 'emacsos-call--audio)
                 (lambda (active) (setq audio active)))
                ((symbol-function 'emacsos-call--watch-call-end)
                 (lambda (path _owner) (setq watched path)))
                ((symbol-function 'emacsos-call--call-prop)
                 (lambda (_path prop)
                   (pcase prop
                     ("Direction" 2)
                     ("State" 2)
                     ("Number" "+14155550123"))))
                ((symbol-function 'emacsos-call--show-active)
                 (lambda (status) (setq shown status))))
        (emacsos-call--dial-finished
         8 test-call--owner
         "error: uncertain-call-path=/org/freedesktop/ModemManager1/Call/12; start timed out; cleanup failed")
        (should (eq emacsos-call--state 'active))
        (should (equal emacsos-call--call-path
                       "/org/freedesktop/ModemManager1/Call/12"))
        (should (equal watched emacsos-call--call-path))
        (should (equal shown "Status unknown"))
        ;; Dial selected call audio before invoking its backend; uncertainty
        ;; must neither restore nor duplicate that transition.
        (should-not audio)))))

(ert-deftest emacsos-call-invalid-terminal-success-becomes-failure ()
  (test-call--with-ui
    (setq emacsos-call--state 'dial-requested
          emacsos-call--proposal-id 9
          emacsos-call--call-number "+14155550123")
    (cl-letf (((symbol-function 'emacsos-call--audio) #'ignore))
      (emacsos-call--dial-finished
       9 test-call--owner "dialing: ../../not-a-call")
      (should (eq emacsos-call--state 'failed)))))

(ert-deftest emacsos-call-multiline-terminal-success-is-invalid ()
  "A valid first line cannot smuggle trailing output into the D-Bus path."
  (test-call--with-ui
    (setq emacsos-call--state 'dial-requested
          emacsos-call--proposal-id 9
          emacsos-call--call-number "+14155550123")
    (cl-letf (((symbol-function 'emacsos-call--audio) #'ignore))
      (emacsos-call--dial-finished
       9 test-call--owner
       "dialing: /org/freedesktop/ModemManager1/Call/4\nerror: extra")
      (should (eq emacsos-call--state 'failed))
      (should-not emacsos-call--call-path))))

;;; Inbound: answer / detect / screen ;;;

(ert-deftest emacsos-answer-ata-success ()
  "ATA returning VOICE CALL: BEGIN / OK is reported as answered."
  (cl-letf (((symbol-function 'emacsos-call--at)
             (lambda (_cmd) "ATA\r\r\nVOICE CALL: BEGIN\r\nOK\r\n")))
    (should (string-prefix-p "answered:" (emacsos-answer)))))

(ert-deftest emacsos-answer-no-incoming-call ()
  "ATA with no call to answer (NO CARRIER) is an error, not a success."
  (cl-letf (((symbol-function 'emacsos-call--at) (lambda (_cmd) "\r\nNO CARRIER\r\n")))
    (should (string-prefix-p "error: answer failed" (emacsos-answer)))))

(ert-deftest emacsos-answer-at-port-error-passthrough ()
  "A serial-port failure surfaces verbatim, not as a false success."
  (cl-letf (((symbol-function 'emacsos-call--at)
             (lambda (_cmd) "error: AT port /dev/ttyUSB3: no such file")))
    (should (string-prefix-p "error:" (emacsos-answer)))
    (should-not (string-prefix-p "answered:" (emacsos-answer)))))

(ert-deftest emacsos-call-render-incoming-context-and-plane ()
  "The incoming TOP buffer shows caller context only (controls live in the
keyboard plane) and sets the incoming keyboard plane."
  (with-current-buffer (emacsos-call--render-incoming "+14155550123")
    (let ((s (buffer-string)))
      (should (string-match-p "Incoming call" s))
      (should (string-match-p (regexp-quote "+14155550123") s))
      (should-not (string-match-p "Decline" s))   ; moved to the plane
      (should-not (string-match-p "Accept" s)))
    (should (eq emacsos--keyboard-plane #'emacsos-call--plane-incoming)))
  (kill-buffer emacsos-call--incoming-buffer))

(ert-deftest emacsos-call-render-incoming-unknown-number ()
  (with-current-buffer (emacsos-call--render-incoming "")
    (should (string-match-p "Unknown" (buffer-string))))
  (kill-buffer emacsos-call--incoming-buffer))

(ert-deftest emacsos-call-render-active-context-and-plane ()
  "The *call* TOP buffer shows status + number and sets the active plane."
  (with-current-buffer (emacsos-call--render-active "+14155550123" "In progress")
    (let ((s (buffer-string)))
      (should (string-match-p "In progress" s))
      (should (string-match-p (regexp-quote "+14155550123") s)))
    (should (eq emacsos--keyboard-plane #'emacsos-call--plane-active)))
  (kill-buffer emacsos-call--active-buffer))

(ert-deftest emacsos-call-render-proposal-and-failure-planes ()
  (with-current-buffer (emacsos-call--render-proposal "+14155550123")
    (should (string-match-p "Call?" (buffer-string)))
    (should (eq emacsos--keyboard-plane #'emacsos-call--plane-proposed)))
  (with-current-buffer
      (emacsos-call--render-failed "+14155550123" "helper\nrejected")
    (should (string-match-p "Call failed" (buffer-string)))
    (should (string-match-p "helper rejected" (buffer-string)))
    (should (eq emacsos--keyboard-plane #'emacsos-call--plane-failed)))
  (kill-buffer emacsos-call--active-buffer))

;; The plane renderers paint *keyboard*; stub the os.el button + centering
;; primitives to capture labels (the planes run without os.el here).
(defmacro test-call--render-plane (plane &rest body)
  (declare (indent 1))
  `(cl-letf (((symbol-function 'emacsos--btn)
              (lambda (label &rest _) (insert label)))
             ((symbol-function 'emacsos--center) (lambda (s &rest _) s)))
     (with-temp-buffer
       (funcall ,plane)
       (let ((s (buffer-string))) ,@body))))

(ert-deftest emacsos-call-plane-incoming-buttons ()
  "Incoming plane paints Decline + Accept; arming flips Accept's label."
  (let ((emacsos-call--answer-confirm-pending nil))
    (test-call--render-plane #'emacsos-call--plane-incoming
      (should (string-match-p "Decline" s))
      (should (string-match-p "Accept" s))
      (should-not (string-match-p "Confirm answer?" s))))
  (let ((emacsos-call--answer-confirm-pending t))
    (test-call--render-plane #'emacsos-call--plane-incoming
      (should (string-match-p "Confirm answer?" s)))))

(ert-deftest emacsos-call-plane-active-buttons ()
  "Active plane paints Hang up + Back; arming flips Hang up's label."
  (let ((emacsos-call--hangup-confirm-pending nil))
    (test-call--render-plane #'emacsos-call--plane-active
      (should (string-match-p "Hang up" s))
      (should (string-match-p "Back" s))
      (should-not (string-match-p "Confirm hang up?" s))))
  (let ((emacsos-call--hangup-confirm-pending t))
    (test-call--render-plane #'emacsos-call--plane-active
      (should (string-match-p "Confirm hang up?" s)))))

(ert-deftest emacsos-call-plane-proposal-buttons ()
  "Proposal always paints Cancel plus Call or its armed label."
  (let ((emacsos-call--dial-confirm-id nil))
    (test-call--render-plane #'emacsos-call--plane-proposed
      (should (string-match-p "Cancel" s))
      (should (string-match-p "Call" s))
      (should-not (string-match-p "Confirm call?" s))))
  (let ((emacsos-call--dial-confirm-id 3))
    (test-call--render-plane #'emacsos-call--plane-proposed
      (should (string-match-p "Cancel" s))
      (should (string-match-p "Confirm call?" s)))))

(ert-deftest emacsos-call-plane-requested-has-no-cancel-action ()
  (test-call--render-plane #'emacsos-call--plane-dial-requested
    (should (string-match-p "Starting call" s))
    (should-not (string-match-p "Cancel\|Dismiss\|Hang up" s))))

(ert-deftest emacsos-call-plane-gap-is-configurable ()
  "A short platform pane can retain both spatially separated controls."
  (let ((emacsos-call-control-gap-lines 1)
        (emacsos-call--answer-confirm-pending nil))
    (test-call--render-plane #'emacsos-call--plane-incoming
      (should (string-match-p "Decline\n\nAccept" s)))))

(ert-deftest emacsos-call-on-call-added-incoming-shows ()
  "An INCOMING call (Direction=1) records path/number, sets state, shows the
incoming screen."
  (let ((shown nil) (emacsos-call--call-path nil) (emacsos-call--state nil))
    (cl-letf (((symbol-function 'emacsos-call--call-prop)
               (lambda (_p prop)
                 (pcase prop
                   ("Direction" 1) ("State" 3) ("Number" "+14155550123"))))
              ((symbol-function 'emacsos-call--watch-call-end) #'ignore)
              ((symbol-function 'emacsos-call-show-incoming)
               (lambda (num) (setq shown num))))
      (emacsos-call--on-call-added "/org/freedesktop/ModemManager1/Call/0")
      (should (equal shown "+14155550123"))
      (should (eq emacsos-call--state 'incoming))
      (should (equal emacsos-call--call-path
                     "/org/freedesktop/ModemManager1/Call/0")))))

(ert-deftest emacsos-call-on-call-added-incoming-wakes-before-showing ()
  (let* ((events nil) (emacsos-call--state nil)
        (emacsos-call-wake-function (lambda () (push 'wake events))))
    (cl-letf (((symbol-function 'emacsos-call--call-prop)
               (lambda (_path prop)
                 (pcase prop ("Direction" 1) ("State" 3) ("Number" "1"))))
              ((symbol-function 'emacsos-call--watch-call-end) #'ignore)
              ((symbol-function 'emacsos-call-show-incoming)
               (lambda (_number) (push 'show events))))
      (emacsos-call--on-call-added "/org/freedesktop/ModemManager1/Call/0")
      (should (equal (nreverse events) '(wake show))))))

(ert-deftest emacsos-call-on-call-added-outgoing-shows-active ()
  "An OUTGOING call (Direction=2) shows the in-progress *call* screen, not the
incoming screen."
  (let ((active nil) (incoming nil) (emacsos-call--state nil) (emacsos-call--call-path nil))
    (cl-letf (((symbol-function 'emacsos-call--call-prop)
               (lambda (_p prop)
                 (pcase prop ("Direction" 2) ("State" 2) ("Number" "+1999"))))
              ((symbol-function 'emacsos-call--watch-call-end) #'ignore)
              ((symbol-function 'emacsos-call-show-incoming) (lambda (_n) (setq incoming t)))
              ((symbol-function 'emacsos-call--show-active) (lambda (_s) (setq active t))))
      (emacsos-call--on-call-added "/org/freedesktop/ModemManager1/Call/9")
      (should active)
      (should-not incoming)
      (should (eq emacsos-call--state 'active)))))

(ert-deftest emacsos-call-on-call-added-supersedes-proposal ()
  "An external outgoing call cancels a proposal before adopting its path."
  (let ((emacsos-call--state 'proposed)
        (emacsos-call--proposal-id 4)
        dismissed active)
    (cl-letf (((symbol-function 'emacsos-call--call-prop)
               (lambda (_p prop)
                 (pcase prop ("Direction" 2) ("State" 2) ("Number" "+1999"))))
              ((symbol-function 'emacsos-call--dismiss)
               (lambda () (setq dismissed t emacsos-call--state nil)))
              ((symbol-function 'emacsos-call--watch-call-end) #'ignore)
              ((symbol-function 'emacsos-call--show-active)
               (lambda (_status) (setq active t))))
      (emacsos-call--on-call-added "/org/freedesktop/ModemManager1/Call/9")
      (should dismissed)
      (should active)
      (should (eq emacsos-call--state 'active)))))

(ert-deftest emacsos-call-on-call-added-unknown-direction-disarms-proposal ()
  "An unreadable trusted event replaces a dialable proposal with recovery."
  (test-call--with-ui
    (emacsos-call "+14155550123")
    (emacsos-call--dial-tap)
    (should emacsos-call--dial-confirm-id)
    (cl-letf (((symbol-function 'emacsos-call--call-prop) #'ignore))
      (emacsos-call--on-call-added "/org/freedesktop/ModemManager1/Call/9"))
    (should-not emacsos-call--dial-confirm-id)
    (should (eq emacsos-call--state 'active))
    (should-not emacsos-call--call-path)
    (should (equal emacsos-call--call-owner test-call--owner))))

(ert-deftest emacsos-call-on-call-added-does-not-adopt-terminated-object ()
  "A delayed retained call object cannot overwrite a useful failed surface."
  (let ((emacsos-call--state 'failed)
        (emacsos-call--failure-reason "start failed")
        watched shown)
    (cl-letf (((symbol-function 'emacsos-call--call-prop)
               (lambda (_path prop)
                 (pcase prop ("Direction" 2) ("State" 7) ("Number" "+1999"))))
              ((symbol-function 'emacsos-call--watch-call-end)
               (lambda (&rest _) (setq watched t)))
              ((symbol-function 'emacsos-call--show-active)
               (lambda (&rest _) (setq shown t))))
      (emacsos-call--on-call-added "/org/freedesktop/ModemManager1/Call/9")
      (should (eq emacsos-call--state 'failed))
      (should (equal emacsos-call--failure-reason "start failed"))
      (should-not watched)
      (should-not shown))))

(ert-deftest emacsos-call-on-call-added-requires-readable-state ()
  "An unreadable trusted object cannot vanish behind an idle UI."
  (let ((emacsos-call--state nil) watched shown)
    (cl-letf (((symbol-function 'emacsos-call--call-prop)
               (lambda (_path prop)
                 (pcase prop ("Direction" 2) ("State" nil) ("Number" "+1999"))))
              ((symbol-function 'emacsos-call--watch-call-end)
               (lambda (&rest _) (setq watched t)))
              ((symbol-function 'emacsos-call--show-active)
               (lambda (&rest _) (setq shown t))))
      (emacsos-call--on-call-added "/org/freedesktop/ModemManager1/Call/9")
      (should (eq emacsos-call--state 'active))
      (should-not emacsos-call--call-path)
      (should-not watched)
      (should shown))))

(ert-deftest emacsos-call-delayed-failed-path-is-ignored-once ()
  "A late CallAdded from the failed helper cannot replace its error screen."
  (let ((path "/org/freedesktop/ModemManager1/Call/9")
        (emacsos-call--state 'failed)
        (emacsos-call--failure-reason "could not start call")
        (emacsos-call--ignored-call-path "/org/freedesktop/ModemManager1/Call/9")
        (emacsos-call--ignored-call-owner ":1.42"))
    (cl-letf (((symbol-function 'emacsos-call--call-prop)
               (lambda (&rest _) (error "ignored path must not be inspected")))
              ((symbol-function 'emacsos-call--modem-manager-owner)
               (lambda () ":1.42")))
      (emacsos-call--on-call-added path)
      (should (eq emacsos-call--state 'failed))
      (should (equal emacsos-call--failure-reason "could not start call"))
      (should-not emacsos-call--ignored-call-path)
      (should-not emacsos-call--ignored-call-owner))))

(ert-deftest emacsos-call-failed-path-does-not-cross-modem-manager-owner ()
  "A restart that reuses a path cannot hide the new owner's legitimate call."
  (let ((path "/org/freedesktop/ModemManager1/Call/9")
        (emacsos-call--state nil)
        (emacsos-call--ignored-call-path "/org/freedesktop/ModemManager1/Call/9")
        (emacsos-call--ignored-call-owner ":1.41")
        shown)
    (cl-letf (((symbol-function 'emacsos-call--modem-manager-owner)
               (lambda () ":1.42"))
              ((symbol-function 'emacsos-call--call-prop)
               (lambda (_path prop)
                 (pcase prop ("Direction" 1) ("State" 3) ("Number" "+1999"))))
              ((symbol-function 'emacsos-call--watch-call-end) #'ignore)
              ((symbol-function 'emacsos-call-show-incoming)
               (lambda (&rest _) (setq shown t))))
      (emacsos-call--on-call-added path)
      (should shown)
      (should (eq emacsos-call--state 'incoming))
      (should-not emacsos-call--ignored-call-path)
      (should-not emacsos-call--ignored-call-owner))))

(ert-deftest emacsos-call-early-cleaned-path-does-not-leave-tombstone ()
  "A helper-confirmed cleanup wins over its earlier unreadable event."
  (test-call--with-ui
    (let ((path "/org/freedesktop/ModemManager1/Call/9"))
      (setq emacsos-call--state 'dial-requested
            emacsos-call--proposal-id 8
            emacsos-call--call-number "+14155550123")
      (cl-letf (((symbol-function 'emacsos-call--call-prop)
                 (lambda (&rest _) nil))
                ((symbol-function 'emacsos-call--audio) #'ignore))
        (emacsos-call--on-call-added path)
        (should (member (cons test-call--owner path)
                        emacsos-call--requested-call-events))
        (emacsos-call--dial-finished
         8 test-call--owner
         (concat "error: call-path=" path "; could not start call"))
        (should (eq emacsos-call--state 'failed))
        (should-not emacsos-call--call-path)
        (should-not emacsos-call--call-owner)
        (should-not emacsos-call--requested-call-events)
        (should-not emacsos-call--ignored-call-path)))))

(ert-deftest emacsos-call-failed-dial-keeps-concurrent-call-recoverable ()
  "A concurrent CallAdded becomes global recovery when dialing fails."
  (test-call--with-ui
    (let ((path "/org/freedesktop/ModemManager1/Call/7"))
      (setq emacsos-call--state 'dial-requested
            emacsos-call--proposal-id 8
            emacsos-call--call-number "+14155550123")
      (cl-letf (((symbol-function 'emacsos-call--call-prop)
                 (lambda (candidate prop)
                   (when (equal candidate path)
                     (pcase prop
                       ("Direction" 1)
                       ("State" 3)
                       ("Number" "+19995550123")))))
                ((symbol-function 'emacsos-call--audio) #'ignore)
                ((symbol-function 'emacsos-call--watch-call-end) #'ignore))
        (emacsos-call--on-call-added path)
        (should (eq emacsos-call--state 'dial-requested))
        (emacsos-call--dial-finished 8 test-call--owner "error: dial rejected")
        (should (eq emacsos-call--state 'active))
        (should-not emacsos-call--call-path)
        (should (equal emacsos-call--call-owner test-call--owner))))))

(ert-deftest emacsos-call-adopted-outgoing-enables-call-audio ()
  (let ((emacsos-call--state nil) audio)
    (cl-letf (((symbol-function 'emacsos-call--call-prop)
               (lambda (_path prop)
                 (pcase prop ("Direction" 2) ("State" 2) ("Number" "+1999"))))
              ((symbol-function 'emacsos-call--watch-call-end) #'ignore)
              ((symbol-function 'emacsos-call--audio)
               (lambda (active) (setq audio active)))
              ((symbol-function 'emacsos-call--show-active) #'ignore))
      (emacsos-call--on-call-added "/org/freedesktop/ModemManager1/Call/9")
      (should audio))))

(ert-deftest emacsos-call-adopted-active-incoming-enables-call-audio ()
  (let ((emacsos-call--state nil) audio)
    (cl-letf (((symbol-function 'emacsos-call--call-prop)
               (lambda (_path prop)
                 (pcase prop ("Direction" 1) ("State" 4) ("Number" "+1999"))))
              ((symbol-function 'emacsos-call--watch-call-end) #'ignore)
              ((symbol-function 'emacsos-call--audio)
               (lambda (active) (setq audio active)))
              ((symbol-function 'emacsos-call--show-active) #'ignore))
      (emacsos-call--on-call-added "/org/freedesktop/ModemManager1/Call/9")
      (should audio))))

(ert-deftest emacsos-call-state-watch-filters-exact-event-owner-and-path ()
  "A stale-owner signal cannot dismiss a replacement at the same path."
  (let ((path "/org/freedesktop/ModemManager1/Call/1")
        (emacsos-call--state 'active)
        (emacsos-call--call-owner ":1.43"))
    (setq emacsos-call--call-path path)
    (emacsos-call--watch-call-end path ":1.43")
    (cl-letf (((symbol-function 'emacsos-call--event-owner) (lambda () ":1.42"))
              ((symbol-function 'emacsos-call--event-path) (lambda () path))
              ((symbol-function 'emacsos-call--audio)
               (lambda (&rest _) (error "stale callback changed audio")))
              ((symbol-function 'emacsos-call--dismiss)
               (lambda () (error "stale callback dismissed current call"))))
      (emacsos-call--on-call-state-event 4 7 0)
      (should (eq emacsos-call--state 'active)))))

(ert-deftest emacsos-call-global-watches-filter-after-trusted-owner-change ()
  "Persistent wildcard call watches coexist with one exact owner watch."
  (let ((emacsos-call--watcher-handles nil)
        (emacsos-call--owner-watch-handle nil)
        (emacsos-call--call-added-handle nil)
        (emacsos-call--state-handle nil)
        (emacsos-call--sms-added-handle nil)
        (emacsos-call--installed-watcher-topology nil)
        registered)
    (cl-letf (((symbol-function 'dbus-register-signal)
               (lambda (&rest args)
                 (push args registered)
                 (length registered)))
              ((symbol-function 'emacsos-call--modem-manager-owner)
               (lambda () ":1.mm")))
      (emacsos-call--watcher-ensure)
      (let ((state-watch (car registered))
            (call-watch (cadr registered))
            (sms-watch (caddr registered))
            (owner-watch (cadddr registered)))
        (should-not (nth 1 call-watch))
        (should (equal (nth 3 call-watch)
                       "org.freedesktop.ModemManager1.Modem.Voice"))
        (should-not (nth 1 state-watch))
        (should (equal (nth 3 state-watch)
                       "org.freedesktop.ModemManager1.Call"))
        (should-not (nth 1 sms-watch))
        (should (equal (nth 3 sms-watch)
                       "org.freedesktop.ModemManager1.Modem.Messaging"))
        (should (equal (nth 1 owner-watch) "org.freedesktop.DBus"))
        (should (equal (nth 2 owner-watch) "/org/freedesktop/DBus"))
        (should (equal (nth 4 owner-watch) "NameOwnerChanged"))
        (should (eq (nth 6 owner-watch) :arg0))
        (should (equal (nth 7 owner-watch)
                       "org.freedesktop.ModemManager1"))
        (should (= (length emacsos-call--watcher-handles) 4))
        (should (= emacsos-call--installed-watcher-topology
                   emacsos-call--watcher-topology-version))))))

(ert-deftest emacsos-call-sms-wake-requires-the-current-owner-and-received-state ()
  (let* ((woke nil)
        (emacsos-call--current-owner ":1.mm")
        (emacsos-call-wake-function (lambda () (setq woke t))))
    (cl-letf (((symbol-function 'emacsos-call--event-owner) (lambda () ":1.mm")))
      (emacsos-call--on-sms-added "/org/freedesktop/ModemManager1/SMS/1" t)
      (should woke)
      (setq woke nil)
      (emacsos-call--on-sms-added "/org/freedesktop/ModemManager1/SMS/1" nil)
      (should-not woke))
    (cl-letf (((symbol-function 'emacsos-call--event-owner) (lambda () ":1.other")))
      (emacsos-call--on-sms-added "/org/freedesktop/ModemManager1/SMS/1" t)
      (should-not woke))))

(ert-deftest emacsos-call-watcher-stop-clears-the-sms-registration ()
  (let ((emacsos-call--watcher-handles '(owner sms))
        (emacsos-call--sms-added-handle 'sms)
        removed)
    (cl-letf (((symbol-function 'emacsos-call--unregister-signal-bounded)
               (lambda (handle) (push handle removed))))
      (emacsos-call--watcher-stop)
      (should (equal removed '(sms owner)))
      (should-not emacsos-call--sms-added-handle))))

(ert-deftest emacsos-call-untrusted-call-signals-are-inert-and-bounded ()
  "Invalid paths cannot disarm; trusted pending events retain only four."
  (test-call--with-ui
    (emacsos-call "+14155550123")
    (emacsos-call--dial-tap)
    (emacsos-call--on-call-added-from-owner test-call--owner "../../spoof")
    (emacsos-call--on-call-added-from-owner
     ":1.old" "/org/freedesktop/ModemManager1/Call/1")
    (should emacsos-call--dial-confirm-id)
    (setq emacsos-call--state 'dial-requested)
    (cl-letf (((symbol-function 'emacsos-call--call-prop) #'ignore))
      (dotimes (index 100)
        (emacsos-call--on-call-added-from-owner
         test-call--owner
         (format "/org/freedesktop/ModemManager1/Call/%d" index))))
    (should (= (length emacsos-call--requested-call-events) 4))))

(ert-deftest emacsos-call-owner-read-failure-still-disarms-proposal ()
  (test-call--with-ui
    (emacsos-call "+14155550123")
    (emacsos-call--dial-tap)
    (cl-letf (((symbol-function 'emacsos-call--modem-manager-owner) #'ignore))
      (emacsos-call--on-call-added-from-owner
       test-call--owner "/org/freedesktop/ModemManager1/Call/4"))
    (should-not emacsos-call--dial-confirm-id)
    (should (eq emacsos-call--state 'proposed))))

(ert-deftest emacsos-call-owner-change-untrusts-old-path-without-match-churn ()
  (let ((emacsos-call--state 'active)
        (emacsos-call--call-path "/org/freedesktop/ModemManager1/Call/1")
        (emacsos-call--call-owner ":1.old")
        (emacsos-call--state-handle 'state-watch)
        (emacsos-call--watched-call
         '(":1.old" . "/org/freedesktop/ModemManager1/Call/1"))
        (emacsos-call--owner-generation 7)
        (emacsos-call--owner-watch-handle 'owner-watch)
        (emacsos-call--call-added-handle 'call-watch)
        (emacsos-call--watcher-handles '(owner-watch call-watch state-watch))
        shown)
    (cl-letf (((symbol-function 'emacsos-call--register-signal-bounded)
               (lambda (&rest _) (error "live callback changed a bus match")))
              ((symbol-function 'emacsos-call--unregister-signal-bounded)
               (lambda (&rest _) (error "live callback changed a bus match")))
              ((symbol-function 'emacsos-call--show-active)
               (lambda (status) (setq shown status))))
      (emacsos-call--on-owner-changed
       "org.freedesktop.ModemManager1" ":1.old" ":1.new")
      (should (eq emacsos-call--state 'active))
      (should-not emacsos-call--call-path)
      (should (equal emacsos-call--call-owner ":1.old"))
      (should-not emacsos-call--watched-call)
      (should (eq emacsos-call--state-handle 'state-watch))
      (should (= emacsos-call--owner-generation 8))
      (should (equal shown "Status unknown"))
      (should (equal emacsos-call--current-owner ":1.new"))
      (should (eq emacsos-call--call-added-handle 'call-watch)))))

(ert-deftest emacsos-call-owner-change-retains-helper-exclusion-until-completion ()
  "A dead D-Bus owner cannot expose a second mutation while its helper runs."
  (let* ((path "/org/freedesktop/ModemManager1/Call/1")
         (identity (list 7 'hangup path 'active ":1.old"))
         (emacsos-call--state 'active)
         (emacsos-call--call-path path)
         (emacsos-call--call-owner ":1.old")
         (emacsos-call--pending-operation identity)
         (emacsos-call--owner-watch-handle 'owner-watch)
         (emacsos-call--call-added-handle 'call-watch)
         snapshot-completion shown)
    (cl-letf (((symbol-function 'dbus-unregister-object) #'ignore)
              ((symbol-function 'dbus-register-signal) (lambda (&rest _) 'watch))
              ((symbol-function 'emacsos-call--call-snapshot-async)
               (lambda (_owner _path completion)
                 (setq snapshot-completion completion)))
              ((symbol-function 'emacsos-call--watch-call-end) #'ignore)
              ((symbol-function 'emacsos-call-show-incoming)
               (lambda (number) (setq shown number)))
              ((symbol-function 'emacsos-call--show-active)
               (lambda (status) (setq shown status))))
      (emacsos-call--on-owner-changed
       "org.freedesktop.ModemManager1" ":1.old" ":1.new")
      (should (equal emacsos-call--pending-operation identity))
      (should-not (nth 2 identity))
      (should (eq (nth 3 identity) 'active))
      (should (equal shown "Status unknown"))
      (let ((emacsos-call-operation-function
             (lambda (&rest _) (error "overlapping backend invocation"))))
        (should (equal (emacsos-hang-up)
                       "error: call operation already pending")))
      (emacsos-call--on-call-added-async
       ":1.new" "/org/freedesktop/ModemManager1/Call/2")
      (should (equal emacsos-call--deferred-call-event
                     '(":1.new" . "/org/freedesktop/ModemManager1/Call/2")))
      (should-not snapshot-completion)
      (emacsos-call--hangup-finished identity "error: old owner unavailable")
      (should-not emacsos-call--pending-operation)
      (should-not emacsos-call--deferred-call-event)
      (should snapshot-completion)
      (funcall snapshot-completion '(1 3 "+1999"))
      (should (eq emacsos-call--state 'incoming))
      (should (equal emacsos-call--call-path
                     "/org/freedesktop/ModemManager1/Call/2"))
      (should (equal emacsos-call--call-owner ":1.new"))
      (should (equal shown "+1999")))))

(ert-deftest emacsos-call-deferred-new-owner-read-failure-releases-exclusion ()
  "A failed deferred snapshot stays actionable after the old helper exits."
  (let* ((new-path "/org/freedesktop/ModemManager1/Call/2")
         (identity (list 7 'hangup nil 'active ":1.old"))
         (emacsos-call--state 'active)
         (emacsos-call--call-path nil)
         (emacsos-call--call-owner ":1.old")
         (emacsos-call--current-owner ":1.new")
         (emacsos-call--pending-operation identity)
         snapshot-completion shown)
    (cl-letf (((symbol-function 'emacsos-call--call-snapshot-async)
               (lambda (_owner _path completion)
                 (setq snapshot-completion completion)))
              ((symbol-function 'emacsos-call--show-active)
               (lambda (status) (setq shown status))))
      (emacsos-call--on-call-added-async ":1.new" new-path)
      (emacsos-call--hangup-finished identity "error: old owner unavailable")
      (should-not emacsos-call--pending-operation)
      (funcall snapshot-completion nil)
      (should (eq emacsos-call--state 'active))
      (should-not emacsos-call--call-path)
      (should (equal emacsos-call--call-owner ":1.new"))
      (should (equal shown "Status unknown")))))

(ert-deftest emacsos-call-successful-hangup-replays-deferred-call-event ()
  "Successful cleanup cannot discard a call queued behind its helper."
  (let* ((path "/org/freedesktop/ModemManager1/Call/1")
         (identity (list 9 'hangup path 'active ":1.old"))
         (emacsos-call--state 'active)
         (emacsos-call--call-path path)
         (emacsos-call--call-owner ":1.old")
         (emacsos-call--pending-operation identity)
         dismissed replayed)
    (cl-letf (((symbol-function 'emacsos-call--audio) #'ignore)
              ((symbol-function 'emacsos-call--dismiss)
               (lambda () (setq dismissed t)))
              ((symbol-function 'emacsos-call--replay-deferred-call-event)
               (lambda () (setq replayed t))))
      (emacsos-call--hangup-finished identity "hung-up: call ended")
      (should-not emacsos-call--pending-operation)
      (should dismissed)
      (should replayed))))

(ert-deftest emacsos-call-same-owner-event-cannot-replace-pathless-unknown ()
  "Uncertainty retains its generation marker until the owner changes."
  (let ((emacsos-call--state 'active)
        (emacsos-call--call-path nil)
        (emacsos-call--call-owner ":1.42"))
    (cl-letf (((symbol-function 'emacsos-call--modem-manager-owner)
               (lambda () ":1.42"))
              ((symbol-function 'emacsos-call--call-prop)
               (lambda (_path prop)
                 (pcase prop ("Direction" 2) ("State" 2) ("Number" "+1999"))))
              ((symbol-function 'emacsos-call--watch-call-end)
               (lambda (&rest _) (error "same-owner event was adopted"))))
      (emacsos-call--on-call-added-from-owner
       ":1.42" "/org/freedesktop/ModemManager1/Call/9")
      (should (eq emacsos-call--state 'active))
      (should-not emacsos-call--call-path)
      (should (equal emacsos-call--call-owner ":1.42")))))

(ert-deftest emacsos-call-reentrant-outer-event-cannot-untrust-adopted-call ()
  "A nested same-owner CallAdded wins over its stale outer callback."
  (let ((outer "/org/freedesktop/ModemManager1/Call/8")
        (inner "/org/freedesktop/ModemManager1/Call/9")
        (emacsos-call--state nil)
        reentered)
    (cl-letf (((symbol-function 'emacsos-call--modem-manager-owner)
               (lambda () ":1.42"))
              ((symbol-function 'emacsos-call--call-prop)
               (lambda (path prop)
                 (when (and (equal path outer) (not reentered))
                   (setq reentered t)
                   (emacsos-call--on-call-added-from-owner ":1.42" inner))
                 (pcase prop
                   ("Direction" 1) ("State" 3) ("Number" "+1999"))))
              ((symbol-function 'emacsos-call--watch-call-end) #'ignore)
              ((symbol-function 'emacsos-call-show-incoming) #'ignore)
              ((symbol-function 'emacsos-call--show-active)
               (lambda (&rest _) (error "adopted call was untrusted"))))
      (emacsos-call--on-call-added-from-owner ":1.42" outer)
      (should (eq emacsos-call--state 'incoming))
      (should (equal emacsos-call--call-path inner))
      (should (equal emacsos-call--call-owner ":1.42")))))

(ert-deftest emacsos-call-live-added-snapshot-never-runs-sync-dbus-reads ()
  "The registered signal path defers all modem reads off the input callback."
  (let ((emacsos-call--state nil)
        (emacsos-call--current-owner ":1.42")
        callback shown)
    (cl-letf (((symbol-function 'emacsos-call--call-snapshot-async)
               (lambda (_owner _path completion)
                 (setq callback completion)))
              ((symbol-function 'emacsos-call--modem-manager-owner)
               (lambda () (error "synchronous owner read")))
              ((symbol-function 'emacsos-call--call-prop)
               (lambda (&rest _) (error "synchronous property read")))
              ((symbol-function 'emacsos-call--watch-call-end) #'ignore)
              ((symbol-function 'emacsos-call--refresh-adopted-state-async)
               #'ignore)
              ((symbol-function 'emacsos-call-show-incoming)
               (lambda (number) (setq shown number))))
      (emacsos-call--on-call-added-async
       ":1.42" "/org/freedesktop/ModemManager1/Call/9")
      (should callback)
      (funcall callback '(1 3 "+1999"))
      (should (eq emacsos-call--state 'incoming))
      (should (equal shown "+1999")))))

(ert-deftest emacsos-call-live-outgoing-snapshot-never-runs-sync-dbus-reads ()
  "External outgoing adoption and gap closure are fully asynchronous."
  (let ((emacsos-call--state nil)
        (emacsos-call--current-owner ":1.42")
        callbacks shown)
    (cl-letf (((symbol-function 'emacsos-call--call-snapshot-async)
               (lambda (_owner _path completion)
                 (push completion callbacks)))
              ((symbol-function 'emacsos-call--modem-manager-owner)
               (lambda () (error "synchronous owner read")))
              ((symbol-function 'emacsos-call--call-prop)
               (lambda (&rest _) (error "synchronous property read")))
              ((symbol-function 'emacsos-call--watch-call-end) #'ignore)
              ((symbol-function 'emacsos-call--show-active)
               (lambda (status) (setq shown status))))
      (emacsos-call--on-call-added-async
       ":1.42" "/org/freedesktop/ModemManager1/Call/9")
      (funcall (car callbacks) '(2 2 "+1999"))
      (should (eq emacsos-call--state 'active))
      (should (equal shown "Calling…"))
      (should (= (length callbacks) 2))
      (funcall (car callbacks) '(2 4 "+1999"))
      (should (equal shown "In progress")))))

(ert-deftest emacsos-call-dial-helper-sentinel-never-runs-sync-dbus-reads ()
  "Helper success binds safely while verification continues asynchronously."
  (test-call--with-ui
    (let (callback shown)
      (setq emacsos-call--state 'dial-requested
            emacsos-call--proposal-id 8
            emacsos-call--call-number "+14155550123")
      (cl-letf (((symbol-function 'emacsos-call--call-snapshot-async)
                 (lambda (_owner _path completion)
                   (setq callback completion)))
                ((symbol-function 'emacsos-call--modem-manager-owner)
                 (lambda () (error "synchronous owner read")))
                ((symbol-function 'emacsos-call--call-prop)
                 (lambda (&rest _) (error "synchronous property read")))
                ((symbol-function 'emacsos-call--watch-call-end) #'ignore)
                ((symbol-function 'emacsos-call--show-active)
                 (lambda (status) (setq shown status))))
        (emacsos-call--dial-finished
         8 ":1.42" "dialing: /org/freedesktop/ModemManager1/Call/9")
        (should (eq emacsos-call--state 'active))
        (should callback)
        (should (equal shown "Calling…"))
        (funcall callback '(2 4 "+14155550123"))
        (should (equal shown "In progress"))))))

(ert-deftest emacsos-call-live-added-snapshot-failure-stays-actionable ()
  "A bounded async read failure cannot erase a trusted call event."
  (let ((emacsos-call--state nil)
        (emacsos-call--current-owner ":1.42")
        callback shown)
    (cl-letf (((symbol-function 'emacsos-call--call-snapshot-async)
               (lambda (_owner _path completion)
                 (setq callback completion)))
              ((symbol-function 'emacsos-call--show-active)
               (lambda (status) (setq shown status))))
      (emacsos-call--on-call-added-async
       ":1.42" "/org/freedesktop/ModemManager1/Call/9")
      (funcall callback nil)
      (should (eq emacsos-call--state 'active))
      (should-not emacsos-call--call-path)
      (should (equal emacsos-call--call-owner ":1.42"))
      (should (equal shown "Status unknown")))))

(ert-deftest emacsos-call-old-owner-async-snapshot-is-inert ()
  "A NameOwnerChanged generation invalidates the old owner's delayed reply."
  (let ((emacsos-call--state nil)
        (emacsos-call--call-path nil)
        (emacsos-call--call-owner nil)
        (emacsos-call--current-owner ":1.old")
        (emacsos-call--owner-generation 4)
        callback)
    (cl-letf (((symbol-function 'emacsos-call--call-snapshot-async)
               (lambda (_owner _path completion)
                 (setq callback completion)))
              ((symbol-function 'emacsos-call--watch-call-end)
               (lambda (&rest _) (error "stale snapshot was adopted"))))
      (emacsos-call--on-call-added-async
       ":1.old" "/org/freedesktop/ModemManager1/Call/9")
      (setq emacsos-call--owner-generation 5)
      (funcall callback '(1 3 "+1999"))
      (should-not emacsos-call--state)
      (should-not emacsos-call--call-path))))

(ert-deftest emacsos-call-queued-old-owner-event-is-inert-before-reading ()
  "A signal queued before owner replacement cannot query or alter the new state."
  (let ((emacsos-call--state nil)
        (emacsos-call--call-path nil)
        (emacsos-call--call-owner nil)
        (emacsos-call--current-owner ":1.new"))
    (cl-letf (((symbol-function 'emacsos-call--call-snapshot-async)
               (lambda (&rest _) (error "stale owner was queried"))))
      (emacsos-call--on-call-added-async
       ":1.old" "/org/freedesktop/ModemManager1/Call/9")
      (should-not emacsos-call--state)
      (should-not emacsos-call--call-path))))

(ert-deftest emacsos-call-success-with-extra-live-call-keeps-global-recovery ()
  "A concurrent call cannot disappear behind the completed outgoing object."
  (let ((emacsos-call--state 'dial-requested)
        (emacsos-call--proposal-id 8)
        (emacsos-call--call-number "+14155550123")
        (emacsos-call--requested-call-events
         '((":1.42" . "/org/freedesktop/ModemManager1/Call/10")
           (":1.42" . "/org/freedesktop/ModemManager1/Call/9"))))
    (cl-letf (((symbol-function 'emacsos-call--modem-manager-owner)
               (lambda () ":1.42"))
              ((symbol-function 'emacsos-call--call-prop)
               (lambda (path prop)
                 (if (equal path "/org/freedesktop/ModemManager1/Call/10")
                     (pcase prop ("Direction" 1) ("State" 3)
                            ("Number" "+1999"))
                   (pcase prop ("Direction" 2) ("State" 2)
                          ("Number" "+14155550123")))))
              ((symbol-function 'emacsos-call--show-active) #'ignore))
      (emacsos-call--dial-finished
       8 ":1.42" "dialing: /org/freedesktop/ModemManager1/Call/9")
      (should (eq emacsos-call--state 'active))
      (should-not emacsos-call--call-path)
      (should (equal emacsos-call--call-owner ":1.42")))))

(ert-deftest emacsos-call-markerless-dial-failure-reconciles-outgoing-event ()
  "A helper death before its marker cannot hide an observed carrier call."
  (test-call--with-ui
    (let ((path "/org/freedesktop/ModemManager1/Call/9"))
      (setq emacsos-call--state 'dial-requested
            emacsos-call--proposal-id 8
            emacsos-call--call-number "+14155550123")
      (cl-letf (((symbol-function 'emacsos-call--call-prop)
                 (lambda (_path prop)
                   (pcase prop ("Direction" 2) ("State" 2)
                          ("Number" "+14155550123"))))
                ((symbol-function 'emacsos-call--show-active) #'ignore))
        (emacsos-call--on-call-added-from-owner test-call--owner path)
        (emacsos-call--dial-finished
         8 test-call--owner "error: helper terminated")
        (should (eq emacsos-call--state 'active))
        (should-not emacsos-call--call-path)
        (should (equal emacsos-call--call-owner test-call--owner))))))

(ert-deftest emacsos-call-watcher-hot-reload-removes-legacy-authority ()
  (let ((emacsos-call--watcher-handles '(legacy-one legacy-two))
        (emacsos-call--owner-watch-handle nil)
        (emacsos-call--call-added-handle nil)
        (emacsos-call--state-handle nil)
        (emacsos-call--sms-added-handle nil)
        (emacsos-call--installed-watcher-topology 1)
        (emacsos-call--state 'active)
        (emacsos-call--call-path "/org/freedesktop/ModemManager1/Call/4")
        (emacsos-call--call-owner nil)
        removed registered)
    (cl-letf (((symbol-function 'dbus-unregister-object)
               (lambda (handle) (push handle removed)))
              ((symbol-function 'dbus-register-signal)
               (lambda (&rest args)
                 (push args registered)
                 (pcase (nth 3 args)
                   ("org.freedesktop.DBus" 'owner-watch)
                   ("org.freedesktop.ModemManager1.Modem.Voice" 'call-watch)
                   ("org.freedesktop.ModemManager1.Modem.Messaging" 'sms-watch)
                   (_ 'state-watch))))
              ((symbol-function 'emacsos-call--modem-manager-owner)
               (lambda () ":1.42"))
              ((symbol-function 'emacsos-call--show-active) #'ignore))
      (emacsos-call--watcher-ensure)
      (should (equal removed '(legacy-two legacy-one)))
      (should-not emacsos-call--call-path)
      (should (equal emacsos-call--call-owner ":1.42"))
      (should (eq emacsos-call--owner-watch-handle 'owner-watch))
      (should (eq emacsos-call--call-added-handle 'call-watch))
      (should (eq emacsos-call--state-handle 'state-watch))
      (should (eq emacsos-call--sms-added-handle 'sms-watch))
      (should (= (length registered) 4)))))

(ert-deftest emacsos-call-owner-change-does-not-churn-persistent-matches ()
  (let ((emacsos-call--owner-watch-handle 'owner-watch)
        (emacsos-call--call-added-handle 'call-watch)
        (emacsos-call--state-handle 'state-watch)
        (emacsos-call--watcher-handles '(owner-watch call-watch state-watch)))
    (cl-letf (((symbol-function 'emacsos-call--register-signal-bounded)
               (lambda (&rest _) (error "owner callback registered a match")))
              ((symbol-function 'emacsos-call--unregister-signal-bounded)
               (lambda (&rest _) (error "owner callback removed a match"))))
      (emacsos-call--on-owner-changed
       "org.freedesktop.ModemManager1" ":1.old" ":1.new")
      (should (equal emacsos-call--current-owner ":1.new"))
      (should (equal emacsos-call--watcher-handles
                     '(owner-watch call-watch state-watch))))))

(ert-deftest emacsos-call-on-call-added-reconciles-after-registering ()
  "Termination between the first snapshot and installed watch is observed."
  (let ((emacsos-call--state nil) (state-reads 0) watched shown)
    (cl-letf (((symbol-function 'emacsos-call--call-prop)
               (lambda (_path prop)
                 (pcase prop
                   ("Direction" 2)
                   ("Number" "+1999")
                   ("State" (cl-incf state-reads) (if (= state-reads 1) 3 7)))))
              ((symbol-function 'emacsos-call--watch-call-end)
               (lambda (&rest _) (setq watched t)))
              ((symbol-function 'emacsos-call--call-snapshot-async)
               (lambda (owner path completion)
                 (let ((emacsos-call--property-owner owner))
                   (funcall completion
                            (list (emacsos-call--call-prop path "Direction")
                                  (emacsos-call--call-prop path "State")
                                  (emacsos-call--call-prop path "Number"))))))
              ((symbol-function 'emacsos-call--show-active)
               (lambda (status) (setq shown status))))
      (emacsos-call--on-call-added "/org/freedesktop/ModemManager1/Call/9")
      (should watched)
      (should (= state-reads 2))
      (should-not emacsos-call--state)
      (should-not emacsos-call--call-path)
      (should (equal shown "Calling…")))))

(ert-deftest emacsos-call-adopted-refresh-failure-drops-path-trust ()
  "A failed post-watch snapshot keeps only pathless recovery controls."
  (let ((path "/org/freedesktop/ModemManager1/Call/9")
        (emacsos-call--state 'active)
        (emacsos-call--call-owner ":1.42")
        callback shown)
    (setq emacsos-call--call-path path)
    (cl-letf (((symbol-function 'emacsos-call--call-snapshot-async)
               (lambda (_owner _path completion) (setq callback completion)))
              ((symbol-function 'emacsos-call--show-active)
               (lambda (status) (setq shown status))))
      (emacsos-call--refresh-adopted-state-async ":1.42" path 3)
      (funcall callback nil)
      (should (eq emacsos-call--state 'active))
      (should-not emacsos-call--call-path)
      (should (equal emacsos-call--call-owner ":1.42"))
      (should (equal shown "Status unknown")))))

(ert-deftest emacsos-call-outgoing-terminal-signal-cannot-resurrect-call ()
  (let ((emacsos-call--state 'active)
        (emacsos-call--call-path "/org/freedesktop/ModemManager1/Call/9")
        (emacsos-call--call-owner ":1.42") shown)
    (cl-letf (((symbol-function 'emacsos-call--watch-call-end) #'ignore)
              ((symbol-function 'emacsos-call--call-snapshot-async)
               (lambda (_owner _path completion)
                 (funcall completion '(2 7 "+1999"))))
              ((symbol-function 'emacsos-call--show-active)
               (lambda (status) (setq shown status))))
      (emacsos-call--adopt-outgoing-path
       "/org/freedesktop/ModemManager1/Call/9" "+1999" ":1.42")
      (should-not emacsos-call--state)
      (should-not emacsos-call--call-path)
      (should (equal shown "Calling…")))))

(ert-deftest emacsos-call-incoming-second-state-read-failure-keeps-controls ()
  "A transient reconciliation read cannot dismiss a proven live incoming call."
  (let ((emacsos-call--state nil) (reads 0) shown)
    (cl-letf (((symbol-function 'emacsos-call--modem-manager-owner)
               (lambda () ":1.42"))
              ((symbol-function 'emacsos-call--call-prop)
               (lambda (_path prop)
                 (pcase prop
                   ("Direction" 1)
                   ("Number" "+1999")
                   ("State" (cl-incf reads) (and (= reads 1) 3)))))
              ((symbol-function 'emacsos-call--watch-call-end) #'ignore)
              ((symbol-function 'emacsos-call-show-incoming)
               (lambda (_number) (setq shown t))))
      (emacsos-call--on-call-added "/org/freedesktop/ModemManager1/Call/9")
      (should shown)
      (should (eq emacsos-call--state 'incoming))
      (should (= reads 2)))))

(ert-deftest emacsos-call-active-incoming-snapshot-survives-unreadable-reread ()
  (let ((emacsos-call--state nil) (reads 0) shown audio)
    (cl-letf (((symbol-function 'emacsos-call--modem-manager-owner)
               (lambda () ":1.42"))
              ((symbol-function 'emacsos-call--call-prop)
               (lambda (_path prop)
                 (pcase prop
                   ("Direction" 1)
                   ("Number" "+1999")
                   ("State" (cl-incf reads) (and (= reads 1) 4)))))
              ((symbol-function 'emacsos-call--watch-call-end) #'ignore)
              ((symbol-function 'emacsos-call--audio)
               (lambda (active) (setq audio active)))
              ((symbol-function 'emacsos-call--show-active)
               (lambda (status) (setq shown status))))
      (emacsos-call--on-call-added "/org/freedesktop/ModemManager1/Call/9")
      (should (eq emacsos-call--state 'active))
      (should audio)
      (should (equal shown "In progress"))
      (should (= reads 2)))))

(ert-deftest emacsos-call-new-owner-call-replaces-stale-active-object ()
  "A post-restart CallAdded can replace an active object from the old owner."
  (let ((emacsos-call--state 'active)
        (emacsos-call--call-owner ":1.old")
        (emacsos-call--call-path "/org/freedesktop/ModemManager1/Call/1")
        dismissed shown audio)
    (cl-letf (((symbol-function 'emacsos-call--modem-manager-owner)
               (lambda () ":1.new"))
              ((symbol-function 'emacsos-call--call-prop)
               (lambda (_path prop)
                 (pcase prop
                   ("Direction" 1)
                   ("State" 3)
                   ("Number" "+1999"))))
              ((symbol-function 'emacsos-call--dismiss)
               (lambda ()
                 (setq dismissed t
                       emacsos-call--state nil
                       emacsos-call--call-path nil
                       emacsos-call--call-owner nil)))
              ((symbol-function 'emacsos-call--watch-call-end) #'ignore)
              ((symbol-function 'emacsos-call--audio)
               (lambda (active) (push active audio)))
              ((symbol-function 'emacsos-call-show-incoming)
               (lambda (&rest _) (setq shown t))))
      (emacsos-call--on-call-added "/org/freedesktop/ModemManager1/Call/1")
      (should dismissed)
      (should shown)
      (should (equal audio '(nil)))
      (should (eq emacsos-call--state 'incoming))
      (should (equal emacsos-call--call-owner ":1.new")))))

(ert-deftest emacsos-call-on-call-added-shows-already-active-call ()
  "A newly adopted active call is visible rather than badge-only."
  (let ((emacsos-call--state nil) shown)
    (cl-letf (((symbol-function 'emacsos-call--call-prop)
               (lambda (_path prop)
                 (pcase prop ("Direction" 2) ("Number" "+1999") ("State" 4))))
              ((symbol-function 'emacsos-call--watch-call-end) #'ignore)
              ((symbol-function 'emacsos-call--show-active)
               (lambda (status) (setq shown status))))
      (emacsos-call--on-call-added "/org/freedesktop/ModemManager1/Call/9")
      (should (eq emacsos-call--state 'active))
      (should (equal shown "In progress")))))

(ert-deftest emacsos-call-on-call-added-does-not-bind-requested-attempt ()
  "Only the attempt-bound helper result may supply a requested call's path."
  (let ((emacsos-call--state 'dial-requested)
        (emacsos-call--proposal-id 5)
        (emacsos-call--call-path nil))
    (cl-letf (((symbol-function 'emacsos-call--call-prop)
               (lambda (&rest _) 2)))
      (emacsos-call--on-call-added "/org/freedesktop/ModemManager1/Call/9")
      (should (eq emacsos-call--state 'dial-requested))
      (should-not emacsos-call--call-path))))

(ert-deftest emacsos-call-on-call-state-active-and-terminated ()
  "State 4 (active) flips state to active and does NOT dismiss; 7 dismisses."
  (let ((dismissed 0) (emacsos-call--state 'incoming))
    (cl-letf (((symbol-function 'emacsos-call--dismiss) (lambda () (cl-incf dismissed)))
              ;; no windows in batch -> the active branch's get-buffer-window
              ;; both return nil, so on-call-state just flips state.
              ((symbol-function 'emacsos-call--show-active) (lambda (&rest _) nil))
              ((symbol-function 'emacsos-call--render-active) (lambda (&rest _) nil)))
      (emacsos-call--on-call-state 3 4 0)
      (should (= dismissed 0))
      (should (eq emacsos-call--state 'active))
      (emacsos-call--on-call-state 4 7 0)
      (should (= dismissed 1)))))

(ert-deftest emacsos-call-external-answer-enables-call-audio ()
  "A ringing call answered outside this UI still receives the voice route."
  (let ((emacsos-call--state 'incoming) audio)
    (cl-letf (((symbol-function 'emacsos-call--audio)
               (lambda (active) (setq audio active)))
              ((symbol-function 'get-buffer-window) #'ignore))
      (emacsos-call--on-call-state 3 4 0)
      (should audio)
      (should (eq emacsos-call--state 'active)))))

(ert-deftest emacsos-call-answer-tap-two-tap ()
  "First Accept tap arms (no answer); second answers + shows in-progress."
  (let ((answered 0) (active 0)
        (emacsos-call--answer-confirm-pending nil) (emacsos-call--state nil))
    (cl-letf (((symbol-function 'emacsos-answer)
               (lambda (&optional _completion)
                 (cl-incf answered)
                 "answered: x"))
              ((symbol-function 'emacsos-call--show-active) (lambda (&rest _) (cl-incf active))))
      (emacsos-call--answer-tap)
      (should emacsos-call--answer-confirm-pending)
      (should (= answered 0))
      (emacsos-call--answer-tap)
      (should (= answered 1))
      (should (= active 1))
      (should (eq emacsos-call--state 'active))
      (should-not emacsos-call--answer-confirm-pending))))

(ert-deftest emacsos-call-answer-awaits-terminal-backend-success ()
  (let ((emacsos-call--state 'incoming)
        (emacsos-call--call-path "/org/freedesktop/ModemManager1/Call/1")
        (emacsos-call--call-owner ":1.42")
        (emacsos-call--answer-confirm-pending t)
        callback shown)
    (cl-letf (((symbol-function 'emacsos-answer)
               (lambda (completion)
                 (setq callback completion)
                 "pending: answer requested"))
              ((symbol-function 'emacsos-call--show-active)
               (lambda (status) (setq shown status))))
      (emacsos-call--answer-tap)
      (should emacsos-call--pending-operation)
      (should-not shown)
      (funcall callback "answered: call active")
      (should-not emacsos-call--pending-operation)
      (should (eq emacsos-call--state 'active))
      (should (equal shown "In progress")))))

(ert-deftest emacsos-call-stale-answer-error-cannot-disable-active-call-audio ()
  "A D-Bus active transition makes the later helper completion UI-stale."
  (let ((emacsos-call--state 'incoming)
        (emacsos-call--call-path "/org/freedesktop/ModemManager1/Call/1")
        (emacsos-call--call-owner ":1.42")
        (emacsos-call--answer-confirm-pending t)
        backend-completion audio)
    (let ((emacsos-call-operation-function
           (lambda (_operation _owner _value completion)
             (setq backend-completion completion)
             "pending: answer requested"))
          (emacsos-call-audio-function
           (lambda (active) (push active audio))))
      (cl-letf (((symbol-function 'get-buffer-window) #'ignore))
        (emacsos-call--answer-tap)
        (emacsos-call--on-call-state 3 4 0)
        (should emacsos-call--pending-operation)
        (funcall backend-completion "error: helper raced active state")
        (should (eq emacsos-call--state 'active))
        (should-not (memq nil audio))))))

(ert-deftest emacsos-call-answer-tap-failure-keeps-incoming-controls ()
  "A failed answer remains visible and retryable."
  (let ((dismissed 0) shown (emacsos-call--answer-confirm-pending t)
        (emacsos-call--state 'incoming))
    (cl-letf (((symbol-function 'emacsos-answer)
               (lambda (&optional _completion) "error: answer failed"))
              ((symbol-function 'emacsos-call--show-active)
               (lambda (&rest _) (error "should not show active on failure")))
              ((symbol-function 'emacsos-call-show-incoming)
               (lambda (_number) (setq shown t)))
              ((symbol-function 'emacsos-call--dismiss)
               (lambda () (cl-incf dismissed))))
      (emacsos-call--answer-tap)
      (should (= dismissed 0))
      (should shown)
      (should (eq emacsos-call--state 'incoming)))))

(ert-deftest emacsos-call-hangup-tap-two-tap ()
  "First Hang-up tap arms; second hangs up + dismisses."
  (let ((hung 0) (dismissed 0) (emacsos-call--hangup-confirm-pending nil))
    (cl-letf (((symbol-function 'emacsos-hang-up)
               (lambda (&optional _completion)
                 (cl-incf hung)
                 "hung-up: x"))
              ((symbol-function 'emacsos-call--dismiss) (lambda () (cl-incf dismissed))))
      (emacsos-call--hangup-tap)
      (should emacsos-call--hangup-confirm-pending)
      (should (= hung 0))
      (emacsos-call--hangup-tap)
      (should (= hung 1))
      (should (= dismissed 1))
      (should-not emacsos-call--hangup-confirm-pending))))

(ert-deftest emacsos-call-hangup-awaits-terminal-backend-result ()
  (let ((emacsos-call--state 'active)
        (emacsos-call--call-path "/org/freedesktop/ModemManager1/Call/1")
        (emacsos-call--hangup-confirm-pending t)
        callback dismissed shown)
    (cl-letf (((symbol-function 'emacsos-hang-up)
               (lambda (completion)
                 (setq callback completion)
                 "pending: hangup requested"))
              ((symbol-function 'emacsos-call--dismiss)
               (lambda () (setq dismissed t)))
              ((symbol-function 'emacsos-call--show-active)
               (lambda (status) (setq shown status))))
      (emacsos-call--hangup-tap)
      (should emacsos-call--pending-operation)
      (should-not dismissed)
      (funcall callback "error: modem unavailable")
      (should-not emacsos-call--pending-operation)
      (should-not dismissed)
      (should (equal shown "Hang up failed")))))

(ert-deftest emacsos-call-stale-hangup-success-cannot-disable-replacement-audio ()
  (let ((emacsos-call--state 'active)
        (emacsos-call--call-path "/org/freedesktop/ModemManager1/Call/1")
        (emacsos-call--hangup-confirm-pending t)
        backend-completion audio)
    (let ((emacsos-call-operation-function
           (lambda (_operation _owner _value completion)
             (setq backend-completion completion)
             "pending: hangup requested"))
          (emacsos-call-audio-function
           (lambda (active) (push active audio))))
      (emacsos-call--hangup-tap)
      ;; A replacement call makes the old completion stale.
      (setq emacsos-call--pending-operation nil
            emacsos-call--call-path "/org/freedesktop/ModemManager1/Call/2")
      (funcall backend-completion "hung-up: old call ended")
      (should-not audio))))

(ert-deftest emacsos-call-terminated-signal-retains-hangup-exclusion ()
  "Carrier termination cannot admit a second helper before the first exits."
  (let ((emacsos-call--state 'active)
        (emacsos-call--call-path "/org/freedesktop/ModemManager1/Call/1")
        (emacsos-call--call-owner ":1.42")
        (emacsos-call--hangup-confirm-pending t)
        backend-completion dismissed)
    (let ((emacsos-call-operation-function
           (lambda (_operation _owner _value completion)
             (setq backend-completion completion)
             "pending: hangup requested")))
      (cl-letf (((symbol-function 'emacsos-call--audio) #'ignore)
                ((symbol-function 'emacsos-call--show-active) #'ignore)
                ((symbol-function 'emacsos-call--dismiss)
                 (lambda () (setq dismissed t))))
        (emacsos-call--hangup-tap)
        (emacsos-call--on-call-state 6 7 0)
        (should (eq emacsos-call--state 'terminated))
        (should emacsos-call--pending-operation)
        (should (equal (emacsos-hang-up) "error: call operation already pending"))
        (should-not dismissed)
        (funcall backend-completion "error: helper raced terminated state")
        (should dismissed)))))

(ert-deftest emacsos-call-hangup-failure-keeps-recovery-control ()
  "A possibly live call stays visible and retryable after hangup failure."
  (let ((dismissed nil) shown
        (emacsos-call--state 'active)
        (emacsos-call--hangup-confirm-pending t))
    (cl-letf (((symbol-function 'emacsos-hang-up)
               (lambda (&optional _completion) "error: modem unavailable"))
              ((symbol-function 'emacsos-call--dismiss)
               (lambda () (setq dismissed t)))
              ((symbol-function 'emacsos-call--show-active)
               (lambda (status) (setq shown status))))
      (emacsos-call--hangup-tap)
      (should-not dismissed)
      (should (equal shown "Hang up failed"))
      (should-not emacsos-call--hangup-confirm-pending))))

(ert-deftest emacsos-call-decline-failure-keeps-incoming-controls ()
  (let ((dismissed nil) (rendered nil)
        (emacsos-call--state 'incoming))
    (cl-letf (((symbol-function 'emacsos-hang-up)
               (lambda (&optional _completion) "error: modem unavailable"))
              ((symbol-function 'emacsos-call--dismiss)
               (lambda () (setq dismissed t)))
              ((symbol-function 'emacsos-call--rerender)
               (lambda () (setq rendered t))))
      (emacsos-call--decline)
      (should-not dismissed)
      (should rendered)
      (should (eq emacsos-call--state 'incoming)))))

(ert-deftest emacsos-call-maybe-disarm-clears-pending ()
  "A non-arming tap disarms a pending two-tap (Accept or Hang-up); the arming
button itself keeps it."
  (let ((emacsos-call--answer-confirm-pending t))
    (emacsos-call--maybe-disarm #'emacsos-call--decline nil)
    (should-not emacsos-call--answer-confirm-pending))
  (let ((emacsos-call--answer-confirm-pending t))
    (emacsos-call--maybe-disarm #'emacsos-call--answer-tap nil)
    (should emacsos-call--answer-confirm-pending))
  (let ((emacsos-call--hangup-confirm-pending t))
    (emacsos-call--maybe-disarm #'emacsos-call--back nil)
    (should-not emacsos-call--hangup-confirm-pending))
  (let ((emacsos-call--hangup-confirm-pending t))
    (emacsos-call--maybe-disarm #'emacsos-call--hangup-tap nil)
    (should emacsos-call--hangup-confirm-pending))
  (let ((emacsos-call--dial-confirm-id 3)
        (emacsos-call--dial-confirm-timer nil))
    (emacsos-call--maybe-disarm #'emacsos-call--cancel-proposal nil)
    (should-not emacsos-call--dial-confirm-id))
  (let ((emacsos-call--dial-confirm-id 3)
        (emacsos-call--dial-confirm-timer nil))
    (emacsos-call--maybe-disarm #'emacsos-call--dial-tap nil)
    (should emacsos-call--dial-confirm-id)))

(ert-deftest emacsos-call-mode-line-badge ()
  "Badge shows only while active AND the *call* screen is hidden."
  (let ((emacsos-call--state nil))
    (should (equal (emacsos-call-mode-line-string) "")))
  (when (get-buffer emacsos-call--active-buffer)
    (kill-buffer emacsos-call--active-buffer))
  (let ((emacsos-call--state 'active))           ; no *call* window in batch
    (should (string-match-p "Call" (emacsos-call-mode-line-string)))))

;; Dismiss restores the pre-call buffer.  The window stubs are variadic + guard
;; on our fake `win'; kill-buffer is no-op'd so the test isolates the restore.
(defmacro test-call--with-dismiss-window (restored-var &rest body)
  (declare (indent 1))
  `(cl-letf (((symbol-function 'emacsos--target) (lambda () 'win))
             ((symbol-function 'window-buffer)
              (lambda (&rest _) (get-buffer emacsos-call--incoming-buffer)))
             ((symbol-function 'set-window-buffer)
              (lambda (w b &rest _) (when (eq w 'win) (setq ,restored-var b))))
             ((symbol-function 'emacsos--render-page) #'ignore)
             ((symbol-function 'kill-buffer) (lambda (&rest _) nil)))
     (get-buffer-create emacsos-call--incoming-buffer)
     ,@body))

(ert-deftest emacsos-call-dismiss-restores-prev-buffer ()
  "Dismiss restores the captured pre-call buffer when live, and clears state."
  (let ((prev (get-buffer-create "test-prev")) (restored nil))
    (test-call--with-dismiss-window restored
      (let ((emacsos-call--prev-buffer prev) (emacsos-call--state 'active))
        (emacsos-call--dismiss)
        (should (eq restored prev))
        (should-not emacsos-call--prev-buffer)     ; cleared
        (should-not emacsos-call--state)))         ; cleared
    (when (buffer-live-p prev) (kill-buffer prev))))

(ert-deftest emacsos-call-dismiss-falls-back-to-scratch-when-prev-dead ()
  "If the captured buffer was killed mid-call, dismiss restores *scratch*,
not a dead buffer."
  (let ((dead (get-buffer-create "test-dead")) (restored nil))
    (kill-buffer dead)
    (test-call--with-dismiss-window restored
      (let ((emacsos-call--prev-buffer dead))
        (emacsos-call--dismiss)
        (should (eq restored (get-buffer-create "*scratch*")))))))

(ert-deftest emacsos-call-back-restores-prev-keeps-active ()
  "Back returns to the pre-call buffer but leaves the call RUNNING (state
stays `active', so the modeline badge appears) and disarms a pending hang-up."
  (let ((prev (get-buffer-create "test-prev")) (restored nil)
        (emacsos-call--state 'active)
        (emacsos-call--hangup-confirm-pending t))
    (get-buffer-create emacsos-call--active-buffer)
    (let ((emacsos-call--prev-buffer prev))
      (cl-letf (((symbol-function 'emacsos--target) (lambda () 'win))
                ((symbol-function 'window-buffer)
                 (lambda (&rest _) (get-buffer emacsos-call--active-buffer)))
                ((symbol-function 'set-window-buffer)
                 (lambda (w b &rest _) (when (eq w 'win) (setq restored b))))
                ((symbol-function 'emacsos--render-page) #'ignore))
        (emacsos-call--back)
        (should (eq restored prev))               ; returned to pre-call buffer
        (should (eq emacsos-call--state 'active))   ; call still running
        (should-not emacsos-call--hangup-confirm-pending)))
    (when (buffer-live-p prev) (kill-buffer prev))
    (when (get-buffer emacsos-call--active-buffer)
      (kill-buffer emacsos-call--active-buffer))))

(provide 'test-call)
;;; test-call.el ends here
