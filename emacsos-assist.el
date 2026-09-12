;;; emacsos-assist.el --- File-backed chat (.assist) -*- lexical-binding: t -*-

;; A `.assist' file IS a durable chat conversation.  Opening one enters
;; `emacsos-assist-mode': the file's transcript renders as a read-only chat
;; surface with an editable prompt at the end, a `#+assist_thread:' header
;; keys the conversation server-side, and SEND streams into THIS buffer
;; (chat.el's stream engine is buffer-agnostic).  The agent reads/edits/runs
;; in the file's directory ON THE PHONE via the server's EmacsBackend.
;;
;; Loaded from os.el via (require 'emacsos-assist) after (require 'chat).
;; Wire shape + design: docs/2026-05-27-file-backed-chat.org.

(require 'chat)

(defconst emacsos-assist--header-prefix "#+assist_thread: "
  "Prefix of the first-line header carrying the conversation's thread id.")

(defvar-local emacsos-assist--thread-id nil
  "This buffer's conversation thread id (read from the header, or minted on
first send).  Buffer-local: each .assist file is its own conversation.")

(defvar-local emacsos-assist--workdir nil
  "Directory the agent operates in for this chat — the .assist file's own
directory ON THE PHONE.  Buffer-local.")

;;; Header

(defun emacsos-assist--read-header ()
  "Return the thread id from the buffer's first-line header, or nil.
The id must be the WHOLE header value (1-128 slug chars, mirroring the
server's validator) up to optional trailing whitespace + end of line — a
malformed header (e.g. an embedded `/') yields nil rather than a silently
truncated prefix that would key a different server conversation."
  (save-excursion
    (goto-char (point-min))
    (when (looking-at (concat (regexp-quote emacsos-assist--header-prefix)
                              "\\([A-Za-z0-9_-]\\{1,128\\}\\)[ \t]*$"))
      (match-string-no-properties 1))))

(defun emacsos-assist--mint-id ()
  "Mint a fresh, slug-safe thread id (32 hex chars — matches the server's
thread-id validator)."
  (md5 (format "%s-%s-%s" (float-time)
               (random most-positive-fixnum) (emacs-pid))))

(defun emacsos-assist--ensure-thread-id ()
  "Return this buffer's thread id, minting + writing the read-only header at
the top on first use.  Does NOT save: chat.el's send persists the buffer
right after committing the you> turn (one write before the POST), which
captures the header too."
  (or emacsos-assist--thread-id
      (let ((id (emacsos-assist--mint-id))
            (inhibit-read-only t))
        (save-excursion
          (goto-char (point-min))
          (let ((before (point)))
            (insert emacsos-assist--header-prefix id "\n")
            (add-text-properties before (point)
                                 '(read-only t front-sticky t rear-nonsticky t))))
        (setq emacsos-assist--thread-id id))))

;;; chat.el surface contract (called from the buffer-agnostic engine)

(defun emacsos-assist--surface-context ()
  "Request context for chat.el's send: this file's thread id (minted if
needed) + its directory."
  (list :thread-id (emacsos-assist--ensure-thread-id)
        :workdir emacsos-assist--workdir))

(defun emacsos-assist--save ()
  "Persist the transcript to the .assist file.  Saves the whole buffer as
plain text (read-only text properties are reconstructed on reopen; the
trailing empty prompt is harmless and reused).  No-op when unmodified."
  (when (and buffer-file-name (buffer-modified-p))
    (let ((inhibit-message t)
          (save-silently t))
      (save-buffer))))

(defvar-local emacsos-assist--forget-confirm-pending nil
  "Non-nil when Forget awaits a confirming second command invocation.
Cleared by `emacsos-assist-forget' or by another EmacsOS button action.
Buffer-local because each .assist file has its own pending state.

This replaced a `y-or-n-p' modal that couldn't be tapped on the
phone touchscreen — mirrors the same fix New-chat got in PR f0ae7f3.")

;;; Commands

(defun emacsos-assist-new-file ()
  "Create and open a new .assist conversation file."
  (interactive)
  (let ((name (read-file-name "New .assist file: " default-directory)))
    (unless (string-suffix-p ".assist" name)
      (setq name (concat name ".assist")))
    (find-file name)))

(defun emacsos-assist-forget ()
  "Forget this conversation on the server (delete its checkpoint) behind
a TWO-TAP confirm.  The .assist file stays on disk as a transcript.

The clear is irreversible, so the first invocation arms and reports the
command to run again.  The second invocation fires the /forget POST.  Another
EmacsOS button action cancels the pending confirmation.  No minibuffer or GUI
dialog is used
\(see [[file:../memory/feedback_phone_no_modals.md][feedback_phone_no_modals]])."
  (interactive)
  (cond
   (emacsos--chat-in-flight
    (message "chat: stream in flight; ABORT before forgetting"))
   ((not emacsos-assist--thread-id)
    (message "no server conversation to forget yet"))
   (emacsos-assist--forget-confirm-pending
    ;; Second tap: confirmed — POST /forget AND wipe the .assist file
    ;; (mirrors `emacsos--chat-new-chat' clearing the *chat* buffer).
    ;; Order: capture the old id first, clear pending state, POST
    ;; (fire-and-forget against the old id), then wipe locally.
    (let ((old-tid emacsos-assist--thread-id))
      (setq emacsos-assist--forget-confirm-pending nil)
      (emacsos-assist--post-forget old-tid)
      (emacsos-assist--wipe-buffer))
    (message "forgot the conversation; this chat is fresh"))
   (t
    (setq emacsos-assist--forget-confirm-pending t)
    (message "Run emacsos-assist-forget again to confirm forget"))))

(defun emacsos-assist--wipe-buffer ()
  "Reset this .assist buffer to a fresh-conversation state and persist:
clear the buffer-local thread id, erase contents (including the old
header + transcript), re-run `emacsos-assist--init-buffer' to add a
trailing prompt and re-mark read-only, then save.  The next send mints
a new thread-id and writes its header into the now-empty file.

Called from `emacsos-assist-forget' after the /forget POST: the SERVER
forgot the old checkpoint AND the LOCAL transcript clears, so the
chat is fresh on both sides.  Mirrors `emacsos--chat-new-chat' →
`emacsos--chat-init-buffer' for the *chat* buffer."
  (setq emacsos-assist--thread-id nil)
  (let ((inhibit-read-only t))
    (erase-buffer))
  (emacsos-assist--init-buffer)
  (emacsos-assist--save))

(defun emacsos-assist--maybe-disarm-forget (action arg)
  "Disarm `emacsos-assist--forget-confirm-pending' on another button action.
An invocation through `emacsos--run-command' identifies its command as ARG.

The pending flag is buffer-local; check it in the .assist buffer
where it lives (the top-buffer / target window) — not whatever buffer
emacs happens to be current when the tap arrives.  Registered on
`emacsos--confirm-disarm-functions'."
  (let* ((tw (and (fboundp 'emacsos--target) (emacsos--target)))
         (buf (and tw (window-buffer tw))))
    (when (and buf
               (buffer-local-value 'emacsos-assist--forget-confirm-pending buf)
               (not (and (eq action #'emacsos--run-command)
                         (eq arg #'emacsos-assist-forget))))
      (with-current-buffer buf
        (setq emacsos-assist--forget-confirm-pending nil)))))

(add-hook 'emacsos--confirm-disarm-functions
          #'emacsos-assist--maybe-disarm-forget)

(defun emacsos-assist--post-forget (thread-id)
  "Fire-and-forget POST /forget {thread_id}; kills the response buffer."
  (let ((url-request-method "POST")
        (url-request-extra-headers
         '(("Content-Type" . "application/json; charset=utf-8")))
        (url-request-data
         (encode-coding-string (json-encode (list :thread_id thread-id)) 'utf-8)))
    (condition-case err
        (url-retrieve (emacsos--chat-endpoint "/forget")
                      (lambda (_status &rest _)
                        (when (buffer-live-p (current-buffer))
                          (kill-buffer (current-buffer))))
                      nil t t)
      (error (message "forget failed: %s" (error-message-string err))))))

;;; Revert guard

(defun emacsos-assist--revert (&rest args)
  "Refuse to revert while a stream renders into this buffer (it would
invalidate the live markers); otherwise revert normally."
  (if (and emacsos--chat-in-flight
           (eq emacsos--chat-stream-buffer (current-buffer)))
      (user-error
       "Can't revert this .assist buffer while its chat stream is in flight; ABORT first")
    (let ((revert-buffer-function nil))
      (apply #'revert-buffer args))))

(defun emacsos-assist-refresh ()
  "Reload this .assist conversation from disk without a confirmation prompt.

Refuse a modified buffer rather than discard an unsaved prompt.  An active
stream is rejected before the buffer changes so its rendering markers remain
valid."
  (interactive)
  (unless (derived-mode-p 'emacsos-assist-mode)
    (user-error "This is not a .assist conversation"))
  (when (buffer-modified-p)
    (user-error "Save or send this .assist draft before refreshing"))
  (emacsos-assist--revert t t))

(defun emacsos-assist-send ()
  "Send the current file-backed conversation through its own chat surface."
  (interactive)
  (emacsos--chat-send (current-buffer)))

;;; Mode

(defun emacsos-assist--init-buffer ()
  "Set up the open buffer as a chat surface: read the header, root the
workdir at the file's directory, ensure a trailing prompt, and mark the
existing transcript read-only.  Leaves the buffer's modified flag unchanged
\(appending a prompt to a freshly-opened file must not flag it dirty)."
  (setq emacsos-assist--thread-id (emacsos-assist--read-header))
  (setq emacsos-assist--workdir
        (directory-file-name
         (or (and buffer-file-name (file-name-directory buffer-file-name))
             default-directory)))
  (let ((inhibit-read-only t)
        (was-modified (buffer-modified-p)))
    ;; Ensure exactly one trailing prompt to type after.
    (unless (emacsos--chat-input-start (current-buffer))
      (goto-char (point-max))
      (emacsos--chat-write-prompt))
    ;; Mark the transcript AND the trailing prompt read-only, up to the start
    ;; of the editable input region (`istart').  Marking THROUGH the prompt
    ;; matters on reopen: a prompt reused from the saved file skipped
    ;; `emacsos--chat-write-prompt' (which read-only-marks a fresh prompt), so
    ;; without this it would reload editable.  Only the region after the
    ;; prompt stays typeable (the prompt's rear-nonsticky allows that).
    (let ((istart (emacsos--chat-input-start (current-buffer))))
      (when (and istart (> istart (point-min)))
        (add-text-properties (point-min) istart
                             '(read-only t front-sticky t rear-nonsticky t))
        (emacsos--chat-present-transcript
         (point-min) (- istart (length emacsos--chat-prompt)))))
    (unless was-modified (set-buffer-modified-p nil)))
  (goto-char (point-max)))

(define-derived-mode emacsos-assist-mode text-mode "Assist"
  "Major mode for `.assist' file-backed chat conversations.
The file's transcript is a read-only chat surface with an editable prompt;
the utility-row Chat/SEND/ABORT button streams or stops the input in this buffer and the
agent reads/edits/runs files in this file's directory on the phone."
  (variable-pitch-mode 1)
  (emacsos--chat-enable-presentation)
  (auto-save-mode -1)               ; the chat surface saves on its own events
  (setq-local revert-buffer-function #'emacsos-assist--revert)
  (emacsos-conversation-install-actions
   '((send . emacsos-assist-send)
     (abort . emacsos--chat-abort)
     (new . emacsos-assist-new-file)
     (refresh . emacsos-assist-refresh)
     (forget . emacsos-assist-forget)))
  (emacsos-assist--init-buffer))

(define-key emacsos-assist-mode-map (kbd "RET")
            #'emacsos-conversation-activate-or-newline)

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.assist\\'" . emacsos-assist-mode))

(provide 'emacsos-assist)
;;; emacsos-assist.el ends here
