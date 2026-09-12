;;; test-emacsos-assist.el --- Tests for file-backed chat (.assist) -*- lexical-binding: t -*-

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
(require 'emacsos-assist)

;;; Header + thread id

(ert-deftest test-assist-read-header ()
  (with-temp-buffer
    (insert "#+assist_thread: abc123DEF-_\n\nyou> hi\n")
    (should (equal (emacsos-assist--read-header) "abc123DEF-_")))
  (with-temp-buffer
    (insert "no header here\n")
    (should (null (emacsos-assist--read-header)))))

(ert-deftest test-assist-physical-ret-in-file-chat-remains-newline-without-an-object ()
  (with-temp-buffer
    (emacsos-assist-mode)
    (goto-char (point-max))
    (call-interactively (lookup-key (current-local-map) (kbd "RET")))
    (should (string-suffix-p "\n" (buffer-string)))))

(ert-deftest test-assist-send-targets-the-current-file-chat-surface ()
  "The shared action map must not fall back to the unrelated *chat* buffer."
  (with-temp-buffer
    (emacsos-assist-mode)
    (let (surface)
      (cl-letf (((symbol-function 'emacsos--chat-send)
                 (lambda (&optional value) (setq surface value))))
        (emacsos-conversation--run 'send))
      (should (eq surface (current-buffer))))))

(ert-deftest test-assist-command-chooser-stays-contextual ()
  "A .assist local new-file action is the only new action in its chooser."
  (with-temp-buffer
    (emacsos-assist-mode)
    (let (choices)
      (cl-letf (((symbol-function 'completing-read)
                 (lambda (_prompt collection &rest _)
                   (setq choices collection)
                   nil)))
        (emacsos-conversation-command))
      (should (member "new" choices))
      (should-not (member "new Assist thread" choices)))))

(ert-deftest test-assist-read-header-rejects-malformed-value ()
  ;; The whole value must be a valid slug to end-of-line; a header with an
  ;; embedded invalid char yields nil (mint fresh), not a truncated prefix
  ;; that would key a different server conversation.
  (with-temp-buffer
    (insert "#+assist_thread: abc/def\n\nyou> hi\n")
    (should (null (emacsos-assist--read-header))))
  (with-temp-buffer
    (insert "#+assist_thread: " (make-string 200 ?a) "\n")   ; over 128
    (should (null (emacsos-assist--read-header))))
  (with-temp-buffer                                          ; trailing ws ok
    (insert "#+assist_thread: ok123  \n")
    (should (equal (emacsos-assist--read-header) "ok123"))))

(ert-deftest test-assist-mint-id-is-a-slug ()
  (let ((id (emacsos-assist--mint-id)))
    (should (string-match-p "\\`[A-Za-z0-9_-]+\\'" id))
    (should (= (length id) 32))))

(ert-deftest test-assist-ensure-thread-id-mints-and-writes-header-once ()
  (with-temp-buffer
    (insert "\n> ")                       ; a bare prompt, no header yet
    (setq emacsos-assist--thread-id nil)
    (let ((id (emacsos-assist--ensure-thread-id)))
      (should (stringp id))
      (should (equal emacsos-assist--thread-id id))
      (should (string-prefix-p (concat emacsos-assist--header-prefix id)
                               (buffer-string)))
      ;; idempotent: same id, no duplicate header line
      (should (equal (emacsos-assist--ensure-thread-id) id))
      (should (= 1 (how-many (regexp-quote emacsos-assist--header-prefix)
                             (point-min) (point-max)))))))

(ert-deftest test-assist-ensure-thread-id-keeps-existing ()
  (with-temp-buffer
    (insert "#+assist_thread: existing123\n\n> ")
    (setq emacsos-assist--thread-id (emacsos-assist--read-header))
    (should (equal (emacsos-assist--ensure-thread-id) "existing123"))))

;;; Surface context (what chat.el's send sends)

(ert-deftest test-assist-surface-context ()
  (with-temp-buffer
    (insert "#+assist_thread: ctx1\n\n> ")
    (setq emacsos-assist--thread-id "ctx1"
          emacsos-assist--workdir "/data/proj")
    (let ((ctx (emacsos-assist--surface-context)))
      (should (equal (plist-get ctx :thread-id) "ctx1"))
      (should (equal (plist-get ctx :workdir) "/data/proj")))))

;;; Forget two-invocation confirm (phone has no modal y-or-n-p; see
;;; memory/feedback_phone_no_modals.md).  Mirrors the New-chat
;;; confirm tests in test-chat.el (chat-test-new-chat-*).

(ert-deftest test-assist-forget-first-tap-arms ()
  "First invocation arms confirmation and does not POST /forget yet."
  (with-temp-buffer
    (setq emacsos-assist--thread-id "abc"
          emacsos-assist--forget-confirm-pending nil)
    (let ((posted nil))
      (cl-letf (((symbol-function 'emacsos-assist--post-forget)
                 (lambda (_id) (setq posted t))))
        (let ((emacsos--chat-in-flight nil))
          (emacsos-assist-forget))
        (should emacsos-assist--forget-confirm-pending)
        (should-not posted)))))

(ert-deftest test-assist-forget-second-tap-confirms ()
  "Armed, a second invocation POSTs /forget, wipes the local .assist buffer
\(clears transcript, clears thread-id), and disarms.  Both halves of
\"Forget = server forgets + this chat is fresh\" are exercised."
  (let ((file (make-temp-file "test-assist-forget" nil ".assist")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "#+assist_thread: abc\n\nyou> earlier\nbot> reply\n> "))
          (with-current-buffer (find-file-noselect file)
            (setq emacsos-assist--thread-id "abc"
                  emacsos-assist--forget-confirm-pending t)
            (let ((posted-with nil))
              (cl-letf (((symbol-function 'emacsos-assist--post-forget)
                         (lambda (id) (setq posted-with id))))
                (let ((emacsos--chat-in-flight nil))
                  (emacsos-assist-forget))
                (should-not emacsos-assist--forget-confirm-pending)
                ;; /forget was posted against the OLD thread-id (not nil —
                ;; the wipe clears it but we capture it first).
                (should (equal posted-with "abc"))
                ;; Local buffer was wiped: thread-id cleared, transcript
                ;; gone, only a trailing prompt remains.
                (should-not emacsos-assist--thread-id)
                (should-not (string-match-p "earlier\\|reply"
                                            (buffer-string)))))))
      (when (file-exists-p file) (delete-file file)))))

(ert-deftest test-assist-wipe-buffer-resets-and-persists ()
  "`emacsos-assist--wipe-buffer' clears thread-id, erases the transcript,
re-runs init (which appends a fresh trailing prompt), and saves.  The
next send would mint a new thread-id and write its header."
  (let ((file (make-temp-file "test-assist-wipe" nil ".assist")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "#+assist_thread: old123\n\nyou> hi\nbot> bye\n> "))
          (with-current-buffer (find-file-noselect file)
            (setq emacsos-assist--thread-id "old123")
            (emacsos-assist--wipe-buffer)
            (should-not emacsos-assist--thread-id)
            ;; Old transcript and header are gone.
            (let ((body (buffer-string)))
              (should-not (string-match-p "old123\\|hi\\|bye" body))
              ;; A trailing prompt was re-added by --init-buffer.
              (should (emacsos--chat-input-start (current-buffer))))
            ;; And it was saved (no longer modified).
            (should-not (buffer-modified-p))
            ;; On-disk content reflects the wipe (no old header / transcript).
            (let ((on-disk (with-temp-buffer
                             (insert-file-contents file)
                             (buffer-string))))
              (should-not (string-match-p "old123\\|hi\\|bye" on-disk)))))
      (when (file-exists-p file) (delete-file file)))))

(ert-deftest test-assist-forget-disarm-on-unrelated-tap ()
  "Another EmacsOS button action disarms Forget; Forget itself does not."
  (with-temp-buffer
    (setq emacsos-assist--thread-id "abc"
          emacsos-assist--forget-confirm-pending t)
    (let ((buf (current-buffer)))
      (cl-letf (((symbol-function 'emacsos--target)
                 (lambda () (selected-window)))
                ((symbol-function 'window-buffer)
                 (lambda (&optional _) buf)))
        ;; Some unrelated command was tapped → disarm.
        (emacsos-assist--maybe-disarm-forget #'emacsos--run-command
                                            #'save-buffer)
        (should-not emacsos-assist--forget-confirm-pending))))
  (with-temp-buffer
    (setq emacsos-assist--thread-id "abc"
          emacsos-assist--forget-confirm-pending t)
    (let ((buf (current-buffer)))
      (cl-letf (((symbol-function 'emacsos--target)
                 (lambda () (selected-window)))
                ((symbol-function 'window-buffer)
                 (lambda (&optional _) buf)))
        ;; The Forget command itself was tapped → keep armed (the handler
        ;; will see the flag and confirm).
        (emacsos-assist--maybe-disarm-forget #'emacsos--run-command
                                            #'emacsos-assist-forget)
        (should emacsos-assist--forget-confirm-pending)))))

(ert-deftest test-assist-forget-no-modal-y-or-n-p ()
  "Regression guard: `emacsos-assist-forget' must NOT call any modal
confirm primitive — the phone touchscreen can't answer it.  Verified
by stubbing y-or-n-p/yes-or-no-p to raise if called."
  (with-temp-buffer
    (setq emacsos-assist--thread-id "abc"
          emacsos-assist--forget-confirm-pending nil)
    (cl-letf (((symbol-function 'y-or-n-p)
               (lambda (&rest _) (error "y-or-n-p must not run on phone")))
              ((symbol-function 'yes-or-no-p)
               (lambda (&rest _) (error "yes-or-no-p must not run on phone"))))
      (let ((emacsos--chat-in-flight nil))
        (emacsos-assist-forget))     ; first invocation arms, never modal
      (let ((emacsos--chat-in-flight nil))
        (cl-letf (((symbol-function 'emacsos-assist--post-forget) #'ignore))
          (emacsos-assist-forget)))  ; second invocation confirms, never modal
      )))

;;; Mode open-time setup

(ert-deftest test-assist-mode-adds-prompt-and-marks-transcript-readonly ()
  (with-temp-buffer
    (insert "#+assist_thread: m1\n\nyou> hi\nbot> hello")   ; no trailing prompt
    (emacsos-assist-mode)
    (should (emacsos--chat-input-start (current-buffer)))     ; a prompt was appended
    (should (equal emacsos-assist--thread-id "m1"))           ; header parsed
    (should (get-text-property (point-min) 'read-only))))    ; transcript locked

(ert-deftest test-assist-mode-reused-prompt-is-read-only ()
  ;; On reopen, a trailing prompt already in the saved file is reused (no
  ;; fresh write-prompt) — but it must still be read-only, with only the
  ;; input region after it editable.
  (with-temp-buffer
    (insert "#+assist_thread: m2\n\nyou> hi\nbot> hello\n> ")
    (emacsos-assist-mode)
    (let* ((istart (emacsos--chat-input-start (current-buffer)))
           (prompt-start (- istart (length emacsos--chat-prompt))))
      (should (= istart (point-max)))                        ; reused, none appended
      (should (get-text-property prompt-start 'read-only))))) ; prompt itself locked

(ert-deftest test-assist-refresh-is-nonconfirming-and-refuses-an-active-stream ()
  (with-temp-buffer
    (emacsos-assist-mode)
    (let (revert-args)
      (cl-letf (((symbol-function 'revert-buffer)
                 (lambda (&rest args) (setq revert-args args)))
                ((symbol-function 'y-or-n-p)
                 (lambda (&rest _) (error "refresh must not prompt")))
                ((symbol-function 'yes-or-no-p)
                 (lambda (&rest _) (error "refresh must not prompt"))))
        (emacsos-assist-refresh)
        (should (equal revert-args '(t t)))
        (setq revert-args nil)
        (set-buffer-modified-p t)
        (should-error (emacsos-assist-refresh) :type 'user-error)
        (should-not revert-args)
        (set-buffer-modified-p nil)
        (let ((emacsos--chat-in-flight t)
              (emacsos--chat-stream-buffer (current-buffer)))
          (should-error (emacsos-assist-refresh) :type 'user-error)
          (should-not revert-args))))))

(ert-deftest test-assist-refresh-refuses-other-buffer-types ()
  (with-temp-buffer
    (let (reverted)
      (cl-letf (((symbol-function 'revert-buffer)
                 (lambda (&rest _) (setq reverted t))))
        (should-error (emacsos-assist-refresh) :type 'user-error)
        (should-not reverted)))))

(ert-deftest test-assist-mode-presents-reopened-markdown-without-changing-file-text ()
  (with-temp-buffer
    (insert "#+assist_thread: m3\n\nyou> # Question\nbot> - answer\n> ")
    (let ((source (buffer-string)))
      (set-buffer-modified-p nil)
      (emacsos-assist-mode)
      (should visual-line-mode)
      (should (equal (buffer-string) source))
      (should-not (buffer-modified-p))
      (goto-char (point-min))
      (search-forward "Question")
      (should (memq 'emacsos-chat-heading-face
                    (get-text-property (match-beginning 0) 'font-lock-face)))
      (search-forward "answer")
      (should (stringp
               (get-text-property (match-beginning 0) 'wrap-prefix))))))

(ert-deftest test-assist-mode-registered-in-auto-mode-alist ()
  (should (eq (cdr (assoc "\\.assist\\'" auto-mode-alist)) 'emacsos-assist-mode)))

;;; chat.el engine: buffer-agnostic target + thread_id/workdir encoding

(ert-deftest test-chat-render-buffer-prefers-stream-buffer ()
  (let ((b (generate-new-buffer " *t-render*")))
    (unwind-protect
        (let ((emacsos--chat-stream-buffer b))
          (should (eq (emacsos--chat-render-buffer) b)))
      (kill-buffer b)))
  ;; unset -> falls back to (creates) the *chat* buffer
  (let ((emacsos--chat-stream-buffer nil))
    (should (eq (emacsos--chat-render-buffer)
                (get-buffer emacsos--chat-buffer-name)))))

(ert-deftest test-chat-encode-request-includes-thread-and-workdir ()
  (let ((s (decode-coding-string
            (emacsos--chat-encode-request "hi" nil "tid9" "/data/proj") 'utf-8)))
    (should (string-match-p "thread_id" s))
    (should (string-match-p "tid9" s))
    (should (string-match-p "workdir" s))
    (should (string-match-p "/data/proj" s))
    (should (string-match-p "hi" s)))
  ;; omitted when nil (legacy *chat* path is byte-for-byte unaffected)
  (let ((s (decode-coding-string
            (emacsos--chat-encode-request "hi" nil) 'utf-8)))
    (should-not (string-match-p "thread_id" s))
    (should-not (string-match-p "workdir" s))))

(provide 'test-emacsos-assist)
;;; test-emacsos-assist.el ends here
