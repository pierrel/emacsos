;;; chat.el --- EmacsOS chat surface -*- lexical-binding: t -*-

;; A CHAT page in the keyboard surface, a *chat* transcript buffer in
;; the top window, and a synchronous POST to emacsos-server.  This is
;; the user's primary channel to the agent that customizes the phone.
;;
;; Loaded from os.el via (require 'chat).  The HTTP request shape
;; matches server/emacsos_server/app.py: the server returns
;; {text, side_effect}; we only render text (side_effect is the
;; server's diagnostic, surfaced via its emacsclient back-channel).

(require 'json)
(require 'url)

;;; Customization

(defcustom emacos-chat-server-url "http://localhost:8765/chat"
  "URL of the emacsos-server /chat endpoint."
  :type 'string
  :group 'emacsos)

(defcustom emacos-chat-auth-file (expand-file-name "~/.emacs.d/server/server")
  "Path to the Emacs server auth file.
Sent verbatim to emacsos-server; the server substitutes the
client's reachable IP for the 0.0.0.0 in the file.  Missing file
is not fatal: SEND falls back to a no-`phone` request and the
server echoes without firing its back-channel."
  :type 'file
  :group 'emacsos)

(defcustom emacos-chat-timeout 300
  "Seconds to wait for /chat before reporting an error.

300s accommodates real assist agent runs (research, multi-step
tools).  The server-side timeout is set 30s lower so a stalled
agent surfaces as a clean `bot> [error: agent timed out …]'
before the client gives up.  Bumped from 10s in the
2026-05-17-assist-import experiment.  When streaming lands, drop
this back down; the perceptual budget becomes \"time to first
token\"."
  :type 'integer
  :group 'emacsos)

;;; State

(defvar emacos--chat-in-flight nil
  "Non-nil while a SEND is awaiting a response.  Re-entrancy guard.")

(defconst emacos--chat-prompt "\n> "
  "Marker between the transcript (read-only) and the editable input.")

(defconst emacos--chat-buffer-name "*chat*")

;;; Buffer + input region

(defun emacos--chat-buffer ()
  "Return the *chat* buffer, creating and initializing if absent."
  (let ((buf (get-buffer emacos--chat-buffer-name)))
    (unless buf
      (setq buf (get-buffer-create emacos--chat-buffer-name))
      (emacos--chat-init-buffer buf))
    buf))

(defun emacos--chat-init-buffer (buf)
  "Seed BUF with a read-only header and a fresh input prompt."
  (with-current-buffer buf
    (let ((inhibit-read-only t))
      (erase-buffer)
      (emacos--chat-write-prompt))
    (goto-char (point-max))))

(defun emacos--chat-write-prompt ()
  "Insert the prompt and mark everything before its tail read-only.
Point is left after the prompt so the user can type."
  (let ((before (point)))
    (insert emacos--chat-prompt)
    ;; Read-only covers everything up to and including the prompt.
    ;; rear-nonsticky so text typed AFTER the prompt is editable.
    (add-text-properties before (point)
                         '(read-only t front-sticky t rear-nonsticky t))))

(defun emacos--chat-input-start (buf)
  "Position immediately after the last `emacos--chat-prompt' in BUF.
nil if no prompt is present (buffer is uninitialized)."
  (with-current-buffer buf
    (save-excursion
      (goto-char (point-max))
      (when (search-backward emacos--chat-prompt nil t)
        (+ (point) (length emacos--chat-prompt))))))

(defun emacos--chat-current-input (buf)
  "Text in BUF between the input-start and point-max, trimmed."
  (let ((start (emacos--chat-input-start buf)))
    (when start
      (with-current-buffer buf
        (string-trim (buffer-substring-no-properties start (point-max)))))))

(defun emacos--chat-clear-input (buf)
  "Delete the editable input region in BUF, leaving the prompt intact."
  (let ((start (emacos--chat-input-start buf)))
    (when start
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (delete-region start (point-max)))))))

(defun emacos--chat-append-line (buf line)
  "Append LINE to BUF as a read-only entry, then re-write the prompt.
Caller must have already cleared the editable input region."
  (with-current-buffer buf
    (let ((inhibit-read-only t))
      (goto-char (point-max))
      (let ((before (point)))
        (insert "\n" line)
        (add-text-properties before (point)
                             '(read-only t front-sticky t rear-nonsticky t)))
      (emacos--chat-write-prompt))
    (goto-char (point-max))))

(defun emacos--chat-append-exchange (buf msg reply)
  "Append a complete you/bot exchange to BUF."
  (emacos--chat-clear-input buf)
  (emacos--chat-append-line buf (concat "you> " msg))
  (emacos--chat-append-line buf (concat "bot> " reply)))

(defun emacos--chat-append-error (buf msg reason)
  "Append a you-line + bot-error to BUF."
  (emacos--chat-clear-input buf)
  (emacos--chat-append-line buf (concat "you> " msg))
  (emacos--chat-append-line buf (concat "bot> [error: " reason "]")))

;;; HTTP

(defun emacos--chat-read-auth-file ()
  "Return the auth file contents as a string, or nil if missing.
Read literally so secret bytes survive round-tripping unchanged."
  (when (file-readable-p emacos-chat-auth-file)
    (with-temp-buffer
      (let ((coding-system-for-read 'no-conversion))
        (insert-file-contents-literally emacos-chat-auth-file))
      (buffer-string))))

(defun emacos--chat-encode-request (msg auth)
  "Encode {message, phone:{auth_file}} as UTF-8 bytes.
If AUTH is nil, omit the phone key entirely (server still echoes)."
  (let* ((payload (if auth
                      (list :message msg :phone (list :auth_file auth))
                    (list :message msg)))
         (json-encoding-pretty-print nil)
         (body (json-encode payload)))
    (encode-coding-string body 'utf-8)))

(defun emacos--chat-parse-response ()
  "Parse JSON body in current buffer (assumed positioned past headers).
Return the text field as a string, or signal an error."
  (let* ((parsed (condition-case _
                     (json-parse-buffer :object-type 'plist :null-object nil)
                   (error (error "malformed response"))))
         (text (plist-get parsed :text)))
    (unless (stringp text)
      (error "no text field"))
    text))

(defun emacos--chat-post (msg auth)
  "POST MSG (+ AUTH if non-nil) to `emacos-chat-server-url'.
Return the bot text on success; signal an error on any failure."
  (let* ((url-request-method "POST")
         (url-request-extra-headers
          '(("Content-Type" . "application/json; charset=utf-8")))
         (url-request-data (emacos--chat-encode-request msg auth))
         (buf (condition-case err
                  (url-retrieve-synchronously
                   emacos-chat-server-url t t emacos-chat-timeout)
                (error (error "%s" (error-message-string err))))))
    (unless buf
      (error "timeout after %ds" emacos-chat-timeout))
    (unwind-protect
        (with-current-buffer buf
          (goto-char (point-min))
          ;; Status line: HTTP/1.1 200 OK
          (unless (looking-at "HTTP/[0-9.]+ \\([0-9]+\\)")
            (error "no status line"))
          (let ((code (string-to-number (match-string 1))))
            (unless (and (>= code 200) (< code 300))
              (error "HTTP %d" code)))
          ;; Skip past headers.  url-retrieve-synchronously normally
          ;; sets url-http-end-of-headers; use that when present.
          ;; Fall back to a CRLF-tolerant search for the blank line.
          (if (and (boundp 'url-http-end-of-headers) url-http-end-of-headers)
              (goto-char url-http-end-of-headers)
            (unless (re-search-forward "\r?\n\r?\n" nil t)
              (error "no header terminator")))
          (emacos--chat-parse-response))
      (kill-buffer buf))))

;;; SEND / CLEAR

(defun emacos--chat-send ()
  "Send the current input region to the server and render the exchange.
No-op if a prior SEND is still in flight or the input is empty."
  (interactive)
  (if emacos--chat-in-flight
      (message "chat: request in flight")
    (let* ((buf (emacos--chat-buffer))
           (msg (emacos--chat-current-input buf)))
      (when (and msg (not (string-empty-p msg)))
        (setq emacos--chat-in-flight t)
        (unwind-protect
            (condition-case err
                (let* ((auth (emacos--chat-read-auth-file))
                       (reply (emacos--chat-post msg auth)))
                  (when (buffer-live-p buf)
                    (emacos--chat-append-exchange buf msg reply)))
              (error
               (when (buffer-live-p buf)
                 (emacos--chat-append-error
                  buf msg (error-message-string err)))))
          (setq emacos--chat-in-flight nil))))))

(defun emacos--chat-clear ()
  "Reset the transcript to an empty prompt.  Refuses while in flight."
  (interactive)
  (if emacos--chat-in-flight
      (message "chat: request in flight")
    (emacos--chat-init-buffer (emacos--chat-buffer))))

;;; Page integration

(defun emacos--render-chat-page ()
  "Render the chat-page controls into the *keyboard* buffer.
Big SEND (1.75x scale), smaller CLEAR.  The :height face attribute
on the SEND button scales the displayed character width too, so
the button-width arg has to be DIVIDED by the scale factor — same
pattern as the T9 letter buttons in `emacos--render-keyboard-page'.
A naive `send-w = win-w` would produce a button ~1.75x the window
width and overflow horizontally."
  (let* ((win      (get-buffer-window (current-buffer)))
         (win-w    (if win (window-body-width win) 20))
         (scale    1.75)
         ;; Divide by scale so the rendered button fits the window.
         (send-w   (max 1 (floor (/ win-w scale))))
         (clear-w  (floor (/ win-w 2))))
    (emacos--btn (emacos--center "SEND" send-w)
                 #'emacos--chat-send nil scale)
    (insert "\n")
    (emacos--btn (emacos--center "CLEAR" clear-w)
                 #'emacos--chat-clear)
    (insert "\n")))

(defun emacos--chat-show-top-buffer ()
  "Display *chat* in the editor (target) window.  Idempotent."
  (let ((buf (emacos--chat-buffer))
        (w (emacos--target)))
    (when (and w (not (eq (window-buffer w) buf)))
      (set-window-buffer w buf))))

(provide 'chat)
;;; chat.el ends here
