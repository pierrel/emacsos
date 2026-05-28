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
  (let ((emacos--chat-in-flight nil))
    (let ((cs (emacos-assist--command-set)))
      (should (assoc "New file" cs))
      (should (assoc "Forget" cs))))
  (let ((emacos--chat-in-flight t))
    (should (assoc "ABORT" (emacos-assist--command-set)))))

;;; Mode open-time setup

(ert-deftest test-assist-mode-adds-prompt-and-marks-transcript-readonly ()
  (with-temp-buffer
    (insert "#+assist_thread: m1\n\nyou> hi\nbot> hello")   ; no trailing prompt
    (emacos-assist-mode)
    (should (emacos--chat-input-start (current-buffer)))     ; a prompt was appended
    (should (equal emacos-assist--thread-id "m1"))           ; header parsed
    (should (get-text-property (point-min) 'read-only))))    ; transcript locked

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
