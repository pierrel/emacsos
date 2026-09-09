;;; emacos-assist.el --- File-backed chat (.assist) -*- lexical-binding: t -*-

;; A `.assist' file IS a durable chat conversation.  Opening one enters
;; `emacos-assist-mode': the file's transcript renders as a read-only chat
;; surface with an editable prompt at the end, a `#+assist_thread:' header
;; keys the conversation server-side, and SEND streams into THIS buffer
;; (chat.el's stream engine is buffer-agnostic).  The agent reads/edits/runs
;; in the file's directory ON THE PHONE via the server's EmacsBackend.
;;
;; Loaded from os.el via (require 'emacos-assist) after (require 'chat).
;; Wire shape + design: docs/2026-05-27-file-backed-chat.org.

(require 'chat)

(defconst emacos-assist--header-prefix "#+assist_thread: "
  "Prefix of the first-line header carrying the conversation's thread id.")

(defvar-local emacos-assist--thread-id nil
  "This buffer's conversation thread id (read from the header, or minted on
first send).  Buffer-local: each .assist file is its own conversation.")

(defvar-local emacos-assist--workdir nil
  "Directory the agent operates in for this chat — the .assist file's own
directory ON THE PHONE.  Buffer-local.")

;;; Header

(defun emacos-assist--read-header ()
  "Return the thread id from the buffer's first-line header, or nil.
The id must be the WHOLE header value (1-128 slug chars, mirroring the
server's validator) up to optional trailing whitespace + end of line — a
malformed header (e.g. an embedded `/') yields nil rather than a silently
truncated prefix that would key a different server conversation."
  (save-excursion
    (goto-char (point-min))
    (when (looking-at (concat (regexp-quote emacos-assist--header-prefix)
                              "\\([A-Za-z0-9_-]\\{1,128\\}\\)[ \t]*$"))
      (match-string-no-properties 1))))

(defun emacos-assist--mint-id ()
  "Mint a fresh, slug-safe thread id (32 hex chars — matches the server's
thread-id validator)."
  (md5 (format "%s-%s-%s" (float-time)
               (random most-positive-fixnum) (emacs-pid))))

(defun emacos-assist--ensure-thread-id ()
  "Return this buffer's thread id, minting + writing the read-only header at
the top on first use.  Does NOT save: chat.el's send persists the buffer
right after committing the you> turn (one write before the POST), which
captures the header too."
  (or emacos-assist--thread-id
      (let ((id (emacos-assist--mint-id))
            (inhibit-read-only t))
        (save-excursion
          (goto-char (point-min))
          (let ((before (point)))
            (insert emacos-assist--header-prefix id "\n")
            (add-text-properties before (point)
                                 '(read-only t front-sticky t rear-nonsticky t))))
        (setq emacos-assist--thread-id id))))

;;; chat.el surface contract (called from the buffer-agnostic engine)

(defun emacos-assist--surface-context ()
  "Request context for chat.el's send: this file's thread id (minted if
needed) + its directory."
  (list :thread-id (emacos-assist--ensure-thread-id)
        :workdir emacos-assist--workdir))

(defun emacos-assist--save ()
  "Persist the transcript to the .assist file.  Saves the whole buffer as
plain text (read-only text properties are reconstructed on reopen; the
trailing empty prompt is harmless and reused).  No-op when unmodified."
  (when (and buffer-file-name (buffer-modified-p))
    (let ((inhibit-message t)
          (save-silently t))
      (save-buffer))))

(defvar-local emacos-assist--forget-confirm-pending nil
  "Non-nil when Forget awaits a confirming second command invocation.
Cleared by `emacos-assist-forget' or by another EmacsOS button action.
Buffer-local because each .assist file has its own pending state.

This replaced a `y-or-n-p' modal that couldn't be tapped on the
phone touchscreen — mirrors the same fix New-chat got in PR f0ae7f3.")

;;; Commands

(defun emacos-assist-new-file ()
  "Create and open a new .assist conversation file."
  (interactive)
  (let ((name (read-file-name "New .assist file: " default-directory)))
    (unless (string-suffix-p ".assist" name)
      (setq name (concat name ".assist")))
    (find-file name)))

(defun emacos-assist-forget ()
  "Forget this conversation on the server (delete its checkpoint) behind
a TWO-TAP confirm.  The .assist file stays on disk as a transcript.

The clear is irreversible, so the first invocation arms and reports the
command to run again.  The second invocation fires the /forget POST.  Another
EmacsOS button action cancels the pending confirmation.  No minibuffer or GUI
dialog is used
\(see [[file:../memory/feedback_phone_no_modals.md][feedback_phone_no_modals]])."
  (interactive)
  (cond
   (emacos--chat-in-flight
    (message "chat: stream in flight; ABORT before forgetting"))
   ((not emacos-assist--thread-id)
    (message "no server conversation to forget yet"))
   (emacos-assist--forget-confirm-pending
    ;; Second tap: confirmed — POST /forget AND wipe the .assist file
    ;; (mirrors `emacos--chat-new-chat' clearing the *chat* buffer).
    ;; Order: capture the old id first, clear pending state, POST
    ;; (fire-and-forget against the old id), then wipe locally.
    (let ((old-tid emacos-assist--thread-id))
      (setq emacos-assist--forget-confirm-pending nil)
      (emacos-assist--post-forget old-tid)
      (emacos-assist--wipe-buffer))
    (message "forgot the conversation; this chat is fresh"))
   (t
    (setq emacos-assist--forget-confirm-pending t)
    (message "Run emacos-assist-forget again to confirm forget"))))

(defun emacos-assist--wipe-buffer ()
  "Reset this .assist buffer to a fresh-conversation state and persist:
clear the buffer-local thread id, erase contents (including the old
header + transcript), re-run `emacos-assist--init-buffer' to add a
trailing prompt and re-mark read-only, then save.  The next send mints
a new thread-id and writes its header into the now-empty file.

Called from `emacos-assist-forget' after the /forget POST: the SERVER
forgot the old checkpoint AND the LOCAL transcript clears, so the
chat is fresh on both sides.  Mirrors `emacos--chat-new-chat' →
`emacos--chat-init-buffer' for the *chat* buffer."
  (setq emacos-assist--thread-id nil)
  (let ((inhibit-read-only t))
    (erase-buffer))
  (emacos-assist--init-buffer)
  (emacos-assist--save))

(defun emacos-assist--maybe-disarm-forget (action arg)
  "Disarm `emacos-assist--forget-confirm-pending' on another button action.
An invocation through `emacos--run-command' identifies its command as ARG.

The pending flag is buffer-local; check it in the .assist buffer
where it lives (the top-buffer / target window) — not whatever buffer
emacs happens to be current when the tap arrives.  Registered on
`emacos--confirm-disarm-functions'."
  (let* ((tw (and (fboundp 'emacos--target) (emacos--target)))
         (buf (and tw (window-buffer tw))))
    (when (and buf
               (buffer-local-value 'emacos-assist--forget-confirm-pending buf)
               (not (and (eq action #'emacos--run-command)
                         (eq arg #'emacos-assist-forget))))
      (with-current-buffer buf
        (setq emacos-assist--forget-confirm-pending nil)))))

(add-hook 'emacos--confirm-disarm-functions
          #'emacos-assist--maybe-disarm-forget)

(defun emacos-assist--post-forget (thread-id)
  "Fire-and-forget POST /forget {thread_id}; kills the response buffer."
  (let ((url-request-method "POST")
        (url-request-extra-headers
         '(("Content-Type" . "application/json; charset=utf-8")))
        (url-request-data
         (encode-coding-string (json-encode (list :thread_id thread-id)) 'utf-8)))
    (condition-case err
        (url-retrieve (emacos--chat-endpoint "/forget")
                      (lambda (_status &rest _)
                        (when (buffer-live-p (current-buffer))
                          (kill-buffer (current-buffer))))
                      nil t t)
      (error (message "forget failed: %s" (error-message-string err))))))

;;; Revert guard

(defun emacos-assist--revert (&rest args)
  "Refuse to revert while a stream renders into this buffer (it would
invalidate the live markers); otherwise revert normally."
  (if (and emacos--chat-in-flight
           (eq emacos--chat-stream-buffer (current-buffer)))
      (user-error
       "Can't revert this .assist buffer while its chat stream is in flight; ABORT first")
    (let ((revert-buffer-function nil))
      (apply #'revert-buffer args))))

(defun emacos-assist-refresh ()
  "Reload this .assist conversation from disk without a confirmation prompt.

Refuse a modified buffer rather than discard an unsaved prompt.  An active
stream is rejected before the buffer changes so its rendering markers remain
valid."
  (interactive)
  (unless (derived-mode-p 'emacos-assist-mode)
    (user-error "This is not a .assist conversation"))
  (when (buffer-modified-p)
    (user-error "Save or send this .assist draft before refreshing"))
  (emacos-assist--revert t t))

(defun emacos-assist-send ()
  "Send the current file-backed conversation through its own chat surface."
  (interactive)
  (emacos--chat-send (current-buffer)))

;;; Mode

(defun emacos-assist--init-buffer ()
  "Set up the open buffer as a chat surface: read the header, root the
workdir at the file's directory, ensure a trailing prompt, and mark the
existing transcript read-only.  Leaves the buffer's modified flag unchanged
\(appending a prompt to a freshly-opened file must not flag it dirty)."
  (setq emacos-assist--thread-id (emacos-assist--read-header))
  (setq emacos-assist--workdir
        (directory-file-name
         (or (and buffer-file-name (file-name-directory buffer-file-name))
             default-directory)))
  (let ((inhibit-read-only t)
        (was-modified (buffer-modified-p)))
    ;; Ensure exactly one trailing prompt to type after.
    (unless (emacos--chat-input-start (current-buffer))
      (goto-char (point-max))
      (emacos--chat-write-prompt))
    ;; Mark the transcript AND the trailing prompt read-only, up to the start
    ;; of the editable input region (`istart').  Marking THROUGH the prompt
    ;; matters on reopen: a prompt reused from the saved file skipped
    ;; `emacos--chat-write-prompt' (which read-only-marks a fresh prompt), so
    ;; without this it would reload editable.  Only the region after the
    ;; prompt stays typeable (the prompt's rear-nonsticky allows that).
    (let ((istart (emacos--chat-input-start (current-buffer))))
      (when (and istart (> istart (point-min)))
        (add-text-properties (point-min) istart
                             '(read-only t front-sticky t rear-nonsticky t))
        (emacos--chat-present-transcript
         (point-min) (- istart (length emacos--chat-prompt)))))
    (unless was-modified (set-buffer-modified-p nil)))
  (goto-char (point-max)))

(define-derived-mode emacos-assist-mode text-mode "Assist"
  "Major mode for `.assist' file-backed chat conversations.
The file's transcript is a read-only chat surface with an editable prompt;
the utility-row Chat/SEND/ABORT button streams or stops the input in this buffer and the
agent reads/edits/runs files in this file's directory on the phone."
  (variable-pitch-mode 1)
  (emacos--chat-enable-presentation)
  (auto-save-mode -1)               ; the chat surface saves on its own events
  (setq-local revert-buffer-function #'emacos-assist--revert)
  (emacos-conversation-install-actions
   '((send . emacos-assist-send)
     (abort . emacos--chat-abort)
     (new . emacos-assist-new-file)
     (refresh . emacos-assist-refresh)
     (forget . emacos-assist-forget)))
  (emacos-assist--init-buffer))

(define-key emacos-assist-mode-map (kbd "RET")
            #'emacos-conversation-activate-or-newline)

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.assist\\'" . emacos-assist-mode))

(provide 'emacos-assist)
;;; emacos-assist.el ends here
