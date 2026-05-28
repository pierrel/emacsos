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

(defun emacos-assist--command-set ()
  "Command-list entries for a .assist buffer: ABORT while streaming, else
New file + Forget this chat."
  (if emacos--chat-in-flight
      (list (cons "ABORT" #'emacos--chat-abort))
    (list (cons "New file" #'emacos-assist-new-file)
          (cons "Forget" #'emacos-assist-forget))))

;;; Commands

(defun emacos-assist-new-file ()
  "Create and open a new .assist conversation file."
  (interactive)
  (let ((name (read-file-name "New .assist file: " default-directory)))
    (unless (string-suffix-p ".assist" name)
      (setq name (concat name ".assist")))
    (find-file name)))

(defun emacos-assist-forget ()
  "Forget this conversation on the server (delete its checkpoint).  The file
stays on disk as a transcript.  Guarded by a confirmation."
  (interactive)
  (cond
   (emacos--chat-in-flight
    (message "chat: stream in flight; ABORT before forgetting"))
   ((not emacos-assist--thread-id)
    (message "no server conversation to forget yet"))
   ((y-or-n-p "Forget this chat on the server? ")
    (emacos-assist--post-forget emacos-assist--thread-id)
    (message "asked the server to forget this conversation"))))

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
                             '(read-only t front-sticky t rear-nonsticky t))))
    (unless was-modified (set-buffer-modified-p nil)))
  (goto-char (point-max)))

(define-derived-mode emacos-assist-mode text-mode "Assist"
  "Major mode for `.assist' file-backed chat conversations.
The file's transcript is a read-only chat surface with an editable prompt;
the utility-row Chat/SEND button streams the input into this buffer and the
agent reads/edits/runs files in this file's directory on the phone."
  (variable-pitch-mode 1)
  (auto-save-mode -1)               ; the chat surface saves on its own events
  (setq-local revert-buffer-function #'emacos-assist--revert)
  (emacos-assist--init-buffer))

;;;###autoload
(add-to-list 'auto-mode-alist '("\\.assist\\'" . emacos-assist-mode))

(provide 'emacos-assist)
;;; emacos-assist.el ends here
