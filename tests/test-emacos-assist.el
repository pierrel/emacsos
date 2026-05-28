;;; test-emacos-assist.el --- Tests for file-backed chat (.assist) -*- lexical-binding: t -*-

;; Covers the pure / buffer-level pieces of the file-backed chat surface:
;; the header parse + thread-id mint, the surface context, the command set,
;; the mode's open-time setup, and the chat.el engine changes that make it
;; buffer-agnostic (render-buffer target + thread_id/workdir encoding).
;; The live stream + the EmacsBackend round trip are out of scope here (they
;; need a phone); the end-to-end round-trip on hardware is still pending.
;;
;; Placeholder workdir is /data/proj (a `/home/...' path would trip the
;; no-real-paths audit).

(require 'ert)
(require 'emacos-assist)

;;; Header + thread id

(ert-deftest test-assist-read-header ()
  (with-temp-buffer
    (insert "#+assist_thread: abc123DEF-_\n\nyou> hi\n")
    (should (equal (emacos-assist--read-header) "abc123DEF-_")))
  (with-temp-buffer
    (insert "no header here\n")
    (should (null (emacos-assist--read-header)))))

(ert-deftest test-assist-read-header-rejects-malformed-value ()
  ;; The whole value must be a valid slug to end-of-line; a header with an
  ;; embedded invalid char yields nil (mint fresh), not a truncated prefix
  ;; that would key a different server conversation.
  (with-temp-buffer
    (insert "#+assist_thread: abc/def\n\nyou> hi\n")
    (should (null (emacos-assist--read-header))))
  (with-temp-buffer
    (insert "#+assist_thread: " (make-string 200 ?a) "\n")   ; over 128
    (should (null (emacos-assist--read-header))))
  (with-temp-buffer                                          ; trailing ws ok
    (insert "#+assist_thread: ok123  \n")
    (should (equal (emacos-assist--read-header) "ok123"))))

(ert-deftest test-assist-mint-id-is-a-slug ()
  (let ((id (emacos-assist--mint-id)))
    (should (string-match-p "\\`[A-Za-z0-9_-]+\\'" id))
    (should (= (length id) 32))))

(ert-deftest test-assist-ensure-thread-id-mints-and-writes-header-once ()
  (with-temp-buffer
    (insert "\n> ")                       ; a bare prompt, no header yet
    (setq emacos-assist--thread-id nil)
    (let ((id (emacos-assist--ensure-thread-id)))
      (should (stringp id))
      (should (equal emacos-assist--thread-id id))
      (should (string-prefix-p (concat emacos-assist--header-prefix id)
                               (buffer-string)))
      ;; idempotent: same id, no duplicate header line
      (should (equal (emacos-assist--ensure-thread-id) id))
      (should (= 1 (how-many (regexp-quote emacos-assist--header-prefix)
                             (point-min) (point-max)))))))

(ert-deftest test-assist-ensure-thread-id-keeps-existing ()
  (with-temp-buffer
    (insert "#+assist_thread: existing123\n\n> ")
    (setq emacos-assist--thread-id (emacos-assist--read-header))
    (should (equal (emacos-assist--ensure-thread-id) "existing123"))))

;;; Surface context (what chat.el's send sends)

(ert-deftest test-assist-surface-context ()
  (with-temp-buffer
    (insert "#+assist_thread: ctx1\n\n> ")
    (setq emacos-assist--thread-id "ctx1"
          emacos-assist--workdir "/data/proj")
    (let ((ctx (emacos-assist--surface-context)))
      (should (equal (plist-get ctx :thread-id) "ctx1"))
      (should (equal (plist-get ctx :workdir) "/data/proj")))))

;;; Command set

(ert-deftest test-assist-command-set-flips-on-in-flight ()
  (let ((emacos--chat-in-flight nil)
        (emacos-assist--forget-confirm-pending nil))
    (let ((cs (emacos-assist--command-set)))
      (should (assoc "New file" cs))
      (should (assoc "Forget" cs))))
  (let ((emacos--chat-in-flight t))
    (should (assoc "ABORT" (emacos-assist--command-set)))))

;;; Forget two-tap confirm (phone has no modal y-or-n-p; see
;;; memory/feedback_phone_no_modals.md).  Mirrors the New-chat
;;; confirm tests in test-chat.el (chat-test-new-chat-*).

(ert-deftest test-assist-forget-first-tap-arms ()
  "First tap only ARMS the two-tap confirm (relabels the button to
\"Confirm forget?\"); it must NOT POST /forget yet."
  (with-temp-buffer
    (setq emacos-assist--thread-id "abc"
          emacos-assist--forget-confirm-pending nil)
    (let ((posted nil))
      (cl-letf (((symbol-function 'emacos-assist--post-forget)
                 (lambda (_id) (setq posted t)))
                ((symbol-function 'emacos--render-page) (lambda () nil)))
        (let ((emacos--chat-in-flight nil))
          (emacos-assist-forget))
        (should emacos-assist--forget-confirm-pending)
        (should-not posted)))))

(ert-deftest test-assist-forget-second-tap-confirms ()
  "Armed, a second tap POSTs /forget and disarms."
  (with-temp-buffer
    (setq emacos-assist--thread-id "abc"
          emacos-assist--forget-confirm-pending t)
    (let ((posted nil))
      (cl-letf (((symbol-function 'emacos-assist--post-forget)
                 (lambda (_id) (setq posted t)))
                ((symbol-function 'emacos--render-page) (lambda () nil)))
        (let ((emacos--chat-in-flight nil))
          (emacos-assist-forget))
        (should-not emacos-assist--forget-confirm-pending)
        (should posted)))))

(ert-deftest test-assist-forget-command-set-relabels-when-armed ()
  "When `emacos-assist--forget-confirm-pending' is t, the command list
shows \"Confirm forget?\" instead of \"Forget\" (same action, different
label — the relabel is the only visual confirmation cue)."
  (with-temp-buffer
    (let ((emacos--chat-in-flight nil))
      (setq emacos-assist--forget-confirm-pending nil)
      (let ((cs (emacos-assist--command-set)))
        (should (assoc "Forget" cs))
        (should-not (assoc "Confirm forget?" cs)))
      (setq emacos-assist--forget-confirm-pending t)
      (let ((cs (emacos-assist--command-set)))
        (should (assoc "Confirm forget?" cs))
        (should-not (assoc "Forget" cs))))))

(ert-deftest test-assist-forget-disarm-on-unrelated-tap ()
  "When something other than the Forget command is tapped, the disarm
hook clears `emacos-assist--forget-confirm-pending'.  Tapping the
Forget command itself does NOT disarm (the second tap must reach
the handler with the flag still t to confirm)."
  (with-temp-buffer
    (setq emacos-assist--thread-id "abc"
          emacos-assist--forget-confirm-pending t)
    (let ((buf (current-buffer)))
      (cl-letf (((symbol-function 'emacos--target)
                 (lambda () (selected-window)))
                ((symbol-function 'window-buffer)
                 (lambda (&optional _) buf))
                ((symbol-function 'emacos--render-page) (lambda () nil)))
        ;; Some unrelated command was tapped → disarm.
        (emacos-assist--maybe-disarm-forget #'emacos--run-command
                                            #'save-buffer)
        (should-not emacos-assist--forget-confirm-pending))))
  (with-temp-buffer
    (setq emacos-assist--thread-id "abc"
          emacos-assist--forget-confirm-pending t)
    (let ((buf (current-buffer)))
      (cl-letf (((symbol-function 'emacos--target)
                 (lambda () (selected-window)))
                ((symbol-function 'window-buffer)
                 (lambda (&optional _) buf))
                ((symbol-function 'emacos--render-page) (lambda () nil)))
        ;; The Forget command itself was tapped → keep armed (the handler
        ;; will see the flag and confirm).
        (emacos-assist--maybe-disarm-forget #'emacos--run-command
                                            #'emacos-assist-forget)
        (should emacos-assist--forget-confirm-pending)))))

(ert-deftest test-assist-forget-no-modal-y-or-n-p ()
  "Regression guard: `emacos-assist-forget' must NOT call any modal
confirm primitive — the phone touchscreen can't answer it.  Verified
by stubbing y-or-n-p/yes-or-no-p to raise if called."
  (with-temp-buffer
    (setq emacos-assist--thread-id "abc"
          emacos-assist--forget-confirm-pending nil)
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (&rest _) (error "y-or-n-p must not run on phone")))
              ((symbol-function 'yes-or-no-p)
               (lambda (&rest _) (error "yes-or-no-p must not run on phone")))
              ((symbol-function 'emacos--render-page) (lambda () nil)))
      (let ((emacos--chat-in-flight nil))
        (emacos-assist-forget))     ; first tap → arm, must not modal
      (let ((emacos--chat-in-flight nil))
        (cl-letf (((symbol-function 'emacos-assist--post-forget) #'ignore))
          (emacos-assist-forget)))  ; second tap → confirm, must not modal
      )))

;;; Mode open-time setup

(ert-deftest test-assist-mode-adds-prompt-and-marks-transcript-readonly ()
  (with-temp-buffer
    (insert "#+assist_thread: m1\n\nyou> hi\nbot> hello")   ; no trailing prompt
    (emacos-assist-mode)
    (should (emacos--chat-input-start (current-buffer)))     ; a prompt was appended
    (should (equal emacos-assist--thread-id "m1"))           ; header parsed
    (should (get-text-property (point-min) 'read-only))))    ; transcript locked

(ert-deftest test-assist-mode-reused-prompt-is-read-only ()
  ;; On reopen, a trailing prompt already in the saved file is reused (no
  ;; fresh write-prompt) — but it must still be read-only, with only the
  ;; input region after it editable.
  (with-temp-buffer
    (insert "#+assist_thread: m2\n\nyou> hi\nbot> hello\n> ")
    (emacos-assist-mode)
    (let* ((istart (emacos--chat-input-start (current-buffer)))
           (prompt-start (- istart (length emacos--chat-prompt))))
      (should (= istart (point-max)))                        ; reused, none appended
      (should (get-text-property prompt-start 'read-only))))) ; prompt itself locked

(ert-deftest test-assist-mode-registered-in-auto-mode-alist ()
  (should (eq (cdr (assoc "\\.assist\\'" auto-mode-alist)) 'emacos-assist-mode)))

;;; chat.el engine: buffer-agnostic target + thread_id/workdir encoding

(ert-deftest test-chat-render-buffer-prefers-stream-buffer ()
  (let ((b (generate-new-buffer " *t-render*")))
    (unwind-protect
        (let ((emacos--chat-stream-buffer b))
          (should (eq (emacos--chat-render-buffer) b)))
      (kill-buffer b)))
  ;; unset -> falls back to (creates) the *chat* buffer
  (let ((emacos--chat-stream-buffer nil))
    (should (eq (emacos--chat-render-buffer)
                (get-buffer emacos--chat-buffer-name)))))

(ert-deftest test-chat-encode-request-includes-thread-and-workdir ()
  (let ((s (decode-coding-string
            (emacos--chat-encode-request "hi" nil "tid9" "/data/proj") 'utf-8)))
    (should (string-match-p "thread_id" s))
    (should (string-match-p "tid9" s))
    (should (string-match-p "workdir" s))
    (should (string-match-p "/data/proj" s))
    (should (string-match-p "hi" s)))
  ;; omitted when nil (legacy *chat* path is byte-for-byte unaffected)
  (let ((s (decode-coding-string
            (emacos--chat-encode-request "hi" nil) 'utf-8)))
    (should-not (string-match-p "thread_id" s))
    (should-not (string-match-p "workdir" s))))

(provide 'test-emacos-assist)
;;; test-emacos-assist.el ends here
