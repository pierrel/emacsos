;;; chat.el --- EmacsOS chat surface -*- lexical-binding: t -*-

;; A CHAT page in the keyboard surface, a *chat* transcript buffer
;; in the top window, and a STREAMED POST to emacsos-server.  The
;; phone's main loop is never blocked: the request runs through
;; url-retrieve (async) with a process filter that drains NDJSON
;; events as they arrive.  Tokens insert above the prompt as the
;; agent produces them; the user can keep editing their next input
;; in the prompt area throughout.  ABORT cancels the in-flight
;; stream.
;;
;; Loaded from os.el via (require 'chat).  Wire shape documented in
;; emacsos/docs/2026-05-17-streaming-responses.org.

(require 'cl-lib)
(require 'font-lock)
(require 'json)
(require 'mouse)
(require 'url)
(require 'url-http)

;; Defined in os.el (which `require's this file); resolved at call time.
(declare-function emacsos--target "os")

;;; Customization

(defcustom emacsos-chat-server-url "http://localhost:8765/chat"
  "URL of the emacsos-server /chat endpoint."
  :type 'string
  :group 'emacsos)

(defcustom emacsos-chat-auth-file (expand-file-name "~/.emacs.d/server/server")
  "Path to the Emacs server auth file.
Sent verbatim to emacsos-server in the optional `phone' field of
each /chat request, reserving the round trip for future
phone-control tools the agent may call.  The automatic
post-response flash that the older sync design used is gone;
nothing in the current request/response cycle requires this
file, so a missing file is not fatal: SEND just omits the
`phone' field and the stream still runs."
  :type 'file
  :group 'emacsos)

(defcustom emacsos-chat-first-token-timeout 30
  "Seconds to wait for the first stream event before reporting
\"no response from server\".  Replaces the old sync-call total
timeout (300s in the pre-streaming version).  No total-stream
timeout exists by design — once the stream starts, the user owns
the budget and can run `emacsos--chat-abort' to cancel.  See design doc §6."
  :type 'integer
  :group 'emacsos)

;;; State (global to the chat feature)
;;
;; There is only ever one `*chat*' buffer in the running phone, so
;; these are plain `defvar's rather than `defvar-local's.  The markers
;; below are buffer-positioned *within* that one chat buffer, but the
;; defvar bindings themselves are global.  Don't open a second chat
;; buffer expecting independent state — that's not what this code
;; supports.

(defvar emacsos--chat-in-flight nil
  "Non-nil while a stream is open.  Re-entrancy guard for SEND.")

(defvar emacsos--assist-active-surface nil
  "Owner of the phone-wide Assist request slot, or nil when it is free.")

(defvar emacsos--chat-confirm-pending nil
  "Non-nil when New chat was invoked once and awaits a second invocation.
Cleared by the confirming `emacsos--chat-new-chat' invocation or by another
EmacsOS button action.  This command-based guard avoids a modal prompt.")

(defvar emacsos--chat-rollback-pending nil
  "Non-nil when rollback awaits a confirming second command invocation.
Rollback reverts the last applied config live on the phone, so it gets the
same two-action guard as New chat.  A different EmacsOS button action or a new
apply clears the pending state.")

(defvar emacsos--chat-process nil
  "The url-retrieve process backing the in-flight stream, or nil.
Used by ABORT to delete-process.")

(defvar emacsos--chat-stream-insert-marker nil
  "Marker into the `*chat*' buffer positioned just before the prompt
at stream start.  Token events insert here.  Insertion-type t so it
moves forward as tokens are inserted.")

(defvar emacsos--chat-status-start nil
  "Marker into the `*chat*' buffer: left edge of the status bracket
inside the in-progress bot line.  Insertion-type nil (anchored).")

(defvar emacsos--chat-status-end nil
  "Marker into the `*chat*' buffer: right edge of the status bracket.
Insertion-type nil (stationary) so that token inserts at the same
position via `emacsos--chat-stream-insert-marker' do NOT drag this
marker forward.  The handle-status path explicitly `set-marker's
this to (point) after inserting its bracket text, so the
stationary type doesn't lose tracking inside the bracket itself.")

(defvar emacsos--chat-tokens-seen 0
  "Count of `token` events received this stream.  Used by the
first-token timer to decide whether to fire.")

(defvar emacsos--chat-last-event-time nil
  "`float-time' of the most recent NDJSON event of any kind from
this stream.  Used by the watchdog to distinguish \"still
arriving\" from \"connection dead, no end event\".")

(defvar emacsos--chat-first-token-timer nil
  "Timer that fires the no-response-from-server error if the
first event doesn't arrive within `emacsos-chat-first-token-timeout`.")

(defvar emacsos--chat-watchdog-timer nil
  "Repeating timer that detects connection-closed-but-stream-not-
cleaned-up.  Necessary because url-http kills its response buffer
on close, sometimes before our filter has parsed the final chunk
\(which may contain the end event).  Fires every 1s while a
stream is in flight; on dead process, synthesizes end (if tokens
were seen) or error (if not).")

(defvar-local emacsos--chat-body-read-marker nil
  "Buffer-local cursor into the url response buffer marking the
boundary between bytes our NDJSON parser has consumed and bytes
url-http has appended but we haven't yet read.  Initialised on
the first `emacsos--chat-drain-body' call against this buffer.
Insertion-type nil so url-http's filter appends BEYOND it
rather than pushing it forward.")

(defconst emacsos--chat-prompt "\n> "
  "Marker between the transcript (read-only) and the editable input.")

(defconst emacsos--chat-buffer-name "*chat*")

(defconst emacsos--chat-bot-prefix "bot> ")

(defconst emacsos--chat-presentation-max-bytes (* 256 1024)
  "Largest single message body formatted synchronously on the phone.")

(defface emacsos-chat-user-role-face
  '((t :inherit font-lock-keyword-face :weight bold))
  "Face for the visible `you> ' role label."
  :group 'emacsos)

(defface emacsos-chat-assistant-role-face
  '((t :inherit font-lock-function-name-face :weight bold))
  "Face for the visible `bot> ' role label."
  :group 'emacsos)

(defface emacsos-chat-heading-face
  '((t :inherit variable-pitch :weight bold :height 1.15))
  "Face for Markdown heading text in a conversation."
  :group 'emacsos)

(defface emacsos-chat-markup-face
  '((t :inherit shadow))
  "Face for visible Markdown punctuation."
  :group 'emacsos)

(defface emacsos-chat-code-face
  '((t :inherit (fixed-pitch font-lock-constant-face)))
  "Face for inline and fenced Markdown code."
  :group 'emacsos)

(defface emacsos-chat-quote-face
  '((t :inherit font-lock-comment-face :slant italic))
  "Face for Markdown block quotes."
  :group 'emacsos)

(defface emacsos-chat-link-face
  '((t :inherit font-lock-constant-face :underline nil))
  "Neutral, inactive face for Markdown link labels."
  :group 'emacsos)

(defun emacsos--chat-copy-raw (beg end delete)
  "Return plain source text from BEG to END, deleting it when DELETE is non-nil."
  (let ((text (buffer-substring-no-properties beg end)))
    (when delete (delete-region beg end))
    text))

(defun emacsos--chat-enable-presentation ()
  "Enable phone-readable wrapping and raw copy/paste in the current buffer."
  (visual-line-mode 1)
  (setq-local truncate-lines nil
              word-wrap t
              filter-buffer-substring-function #'emacsos--chat-copy-raw))

(defun emacsos-conversation-activate-or-newline ()
  "Open a literal HTTP(S) object at point, otherwise insert an ordinary newline."
  (interactive)
  (let ((url (get-text-property (point) 'emacsos-conversation-url)))
    (if (emacsos-conversation--safe-url-p url)
        (browse-url url)
      (newline))))

(defun emacsos-conversation--safe-url-p (url)
  "Return non-nil for one literal HTTP(S) URL suitable for explicit opening."
  (and (stringp url)
       (string-match-p "\\`https?://[^[:space:]]+\\'" url)
       (cl-loop for character across url
                never (or (< character #x20)
                          (<= #x7f character #x9f)))))

(defvar emacsos-conversation-object-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'emacsos-conversation-open-object)
    (define-key map (kbd "RET") #'emacsos-conversation-open-object)
    map)
  "Keymap on validated, inert-until-activated native conversation objects.")

(defun emacsos-conversation-open-object (&optional event)
  "Open the validated native object at point, or explain that none is present."
  (interactive (list last-input-event))
  (when (mouse-event-p event) (mouse-set-point event))
  (let ((url (get-text-property (point) 'emacsos-conversation-url)))
    (if (emacsos-conversation--safe-url-p url)
        (browse-url url)
      (message "No HTTP(S) object at point"))))

(defvar-local emacsos-conversation-actions nil
  "Alist of capabilities installed by this conversation backend.")

(defun emacsos-conversation-install-actions (actions)
  "Install backend-owned ACTIONS in the current conversation buffer.

Each entry is (CAPABILITY . COMMAND).  Transport, persistence, and lifecycle
remain owned by the backend; this small kernel owns only discovery and binding."
  (setq-local emacsos-conversation-actions actions)
  (local-set-key (kbd "C-c C-a") emacsos-conversation-command-map))

(defun emacsos-conversation--run (capability)
  "Invoke CAPABILITY in this buffer, or give one compact unavailable message."
  (let ((command (alist-get capability emacsos-conversation-actions)))
    (if (commandp command)
        (call-interactively command)
      (message "%s is unavailable in this conversation"
               (capitalize (replace-regexp-in-string "-" " " (symbol-name capability)))))))

(dolist (entry '((send . emacsos-conversation-send)
                 (abort . emacsos-conversation-abort)
                 (refresh . emacsos-conversation-refresh)
                 (older . emacsos-conversation-load-older)
                 (forget . emacsos-conversation-forget)
                 (catalog . emacsos-conversation-refresh-catalog)))
  (defalias (cdr entry)
    `(lambda () ,(format "Run the %s action for this conversation." (car entry))
       (interactive) (emacsos-conversation--run ',(car entry)))))

(defun emacsos-conversation-command ()
  "Run an action supported by the current conversation buffer."
  (interactive)
  (let* ((choices (mapcar (lambda (entry) (symbol-name (car entry)))
                          emacsos-conversation-actions))
         (choice (and choices (completing-read "Conversation: " choices nil t))))
    (pcase choice
      ((and (pred stringp) action) (emacsos-conversation--run (intern action)))
      (_ (message "No conversation actions are available here")))))

(defvar emacsos-conversation-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "s") #'emacsos-conversation-send)
    (define-key map (kbd "a") #'emacsos-conversation-abort)
    (define-key map (kbd "g") #'emacsos-conversation-refresh)
    (define-key map (kbd "o") #'emacsos-conversation-open-object)
    (define-key map (kbd "l") #'emacsos-conversation-load-older)
    (define-key map (kbd "f") #'emacsos-conversation-forget)
    map)
  "Contextual Assist commands under the C-c C-a prefix.")

(defun emacsos--chat-add-face (beg end face)
  "Append FACE to text from BEG to END through the inert font-lock channel."
  (when (< beg end)
    (font-lock-append-text-property beg end 'font-lock-face face)))

(defun emacsos--chat-match-verbatim-p ()
  "Return non-nil when any part of the current match is already verbatim."
  (text-property-not-all (match-beginning 0) (match-end 0)
                         'emacsos--chat-verbatim nil))

(defun emacsos--chat-present-markdown-1 (beg end)
  "Apply the flat native Markdown presentation to BEG..END.

The caller supplies one message body.  The grammar is intentionally small:
triple-backtick fences; logical-line headings, lists, and quotes; then
single-line non-nested code, links, bold, and italic.  Source characters are
never replaced or hidden."
  (when (and (<= beg end)
             (<= (- (position-bytes end) (position-bytes beg))
                 emacsos--chat-presentation-max-bytes))
    (with-silent-modifications
      (save-excursion
        (remove-text-properties beg end
                                '(font-lock-face nil wrap-prefix nil
                                  emacsos--chat-verbatim nil
                                  emacsos-conversation-url nil keymap nil
                                  mouse-face nil))
        (save-restriction
          (narrow-to-region beg end)
          (let ((in-fence nil))
            (goto-char (point-min))
            (while (< (point) (point-max))
              (let ((line-start (point))
                    (line-end (line-end-position)))
                (cond
                 ((looking-at "[ \t]*```")
                  (emacsos--chat-add-face line-start line-end
                                         'emacsos-chat-code-face)
                  (emacsos--chat-add-face (match-beginning 0) (match-end 0)
                                         'emacsos-chat-markup-face)
                  (put-text-property line-start line-end
                                     'emacsos--chat-verbatim t)
                  (setq in-fence (not in-fence)))
                 (in-fence
                  (emacsos--chat-add-face line-start line-end
                                         'emacsos-chat-code-face)
                  (put-text-property line-start line-end
                                     'emacsos--chat-verbatim t))
                 ((looking-at "[ \t]*\\(#\\{1,6\\}\\)[ \t]+")
                  (emacsos--chat-add-face (match-beginning 1) (match-end 1)
                                         'emacsos-chat-markup-face)
                  (emacsos--chat-add-face (match-end 0) line-end
                                         'emacsos-chat-heading-face))
                 ((looking-at
                   "[ \t]*\\(?:[-+*]\\|[0-9]+[.)]\\)[ \t]+")
                  (emacsos--chat-add-face (match-beginning 0) (match-end 0)
                                         'font-lock-builtin-face)
                  (put-text-property line-start line-end 'wrap-prefix
                                     (make-string
                                      (save-excursion
                                        (goto-char (match-end 0))
                                        (current-column))
                                      ?\s)))
                 ((looking-at "[ \t]*>[ \t]*")
                  (emacsos--chat-add-face (match-beginning 0) (match-end 0)
                                         'emacsos-chat-markup-face)
                  (emacsos--chat-add-face (match-end 0) line-end
                                         'emacsos-chat-quote-face)
                  (put-text-property line-start line-end 'wrap-prefix
                                     (make-string
                                      (save-excursion
                                        (goto-char (match-end 0))
                                        (current-column))
                                      ?\s)))))
              (forward-line 1)))

          ;; Inline code wins: later passes skip ranges marked verbatim.
          (goto-char (point-min))
          (while (re-search-forward "`\\([^`\n]+\\)`" nil t)
            (unless (emacsos--chat-match-verbatim-p)
              (emacsos--chat-add-face (match-beginning 0) (match-end 0)
                                     'emacsos-chat-code-face)
              (emacsos--chat-add-face (match-beginning 0) (1+ (match-beginning 0))
                                     'emacsos-chat-markup-face)
              (emacsos--chat-add-face (1- (match-end 0)) (match-end 0)
                                     'emacsos-chat-markup-face)
              (put-text-property (match-beginning 0) (match-end 0)
                                 'emacsos--chat-verbatim t)))

          (goto-char (point-min))
          (while (re-search-forward
                  "\\[\\([^]\n]+\\)\\](\\([^()\n]+\\))" nil t)
            (unless (emacsos--chat-match-verbatim-p)
              (emacsos--chat-add-face (match-beginning 1) (match-end 1)
                                     'emacsos-chat-link-face)
              (emacsos--chat-add-face (match-beginning 0) (match-beginning 1)
                                     'emacsos-chat-markup-face)
              (emacsos--chat-add-face (match-end 1) (match-end 0)
                                     'emacsos-chat-markup-face)
              (let ((target (match-string-no-properties 2)))
                (when (emacsos-conversation--safe-url-p target)
                  (add-text-properties
                   (match-beginning 1) (match-end 1)
                   `(emacsos-conversation-url ,target
                     keymap ,emacsos-conversation-object-map
                     mouse-face highlight))))
              (put-text-property (match-beginning 0) (match-end 0)
                                 'emacsos--chat-verbatim t)))

          (dolist (regexp '("\\*\\*\\([^*\n]+\\)\\*\\*"))
            (goto-char (point-min))
            (while (re-search-forward regexp nil t)
              (unless (emacsos--chat-match-verbatim-p)
                (emacsos--chat-add-face (match-beginning 1) (match-end 1) 'bold)
                (emacsos--chat-add-face (match-beginning 0) (match-beginning 1)
                                       'emacsos-chat-markup-face)
                (emacsos--chat-add-face (match-end 1) (match-end 0)
                                       'emacsos-chat-markup-face)
                (put-text-property (match-beginning 0) (match-end 0)
                                   'emacsos--chat-verbatim t))))

          (dolist (regexp '("\\*\\([^*\n]+\\)\\*"))
            (goto-char (point-min))
            (while (re-search-forward regexp nil t)
              (if (emacsos--chat-match-verbatim-p)
                  (goto-char
                   (or (next-single-property-change
                        (match-beginning 0) 'emacsos--chat-verbatim nil
                        (point-max))
                       (point-max)))
                (emacsos--chat-add-face (match-beginning 1) (match-end 1) 'italic)
                (emacsos--chat-add-face (match-beginning 0) (match-beginning 1)
                                       'emacsos-chat-markup-face)
                (emacsos--chat-add-face (match-end 1) (match-end 0)
                                       'emacsos-chat-markup-face))))
          (remove-text-properties (point-min) (point-max)
                                  '(emacsos--chat-verbatim nil)))))))

(defun emacsos--chat-present-message (prefix-start body-start end role)
  "Present one ROLE message without changing PREFIX-START..END source text.

BODY-START follows the visible role prefix.  Presentation is deliberately
best-effort and never allowed to interrupt chat lifecycle code."
  (condition-case error
      (progn
        (with-silent-modifications
          (remove-text-properties prefix-start body-start
                                  '(font-lock-face nil))
          (emacsos--chat-add-face
           prefix-start body-start
           (if (eq role 'user)
               'emacsos-chat-user-role-face
             'emacsos-chat-assistant-role-face)))
        (emacsos--chat-present-markdown-1 body-start end))
    (error
     (message "chat: couldn't present Markdown: %s"
              (error-message-string error))
     nil)))

(defun emacsos--chat-present-transcript (beg end)
  "Present role-prefixed messages between BEG and END as cosmetic hints."
  (condition-case error
      (when (<= (- (position-bytes end) (position-bytes beg))
                emacsos--chat-presentation-max-bytes)
        (save-excursion
          (goto-char beg)
          (let (messages)
            (while (re-search-forward "^\\(you> \\|bot> \\)" end t)
              (push (list (match-beginning 1) (match-end 1)
                          (if (eq (char-after (match-beginning 1)) ?y)
                              'user 'assistant))
                    messages))
            (setq messages (nreverse messages))
            (while messages
              (let* ((message (car messages))
                     (next (cadr messages)))
                (emacsos--chat-present-message
                 (nth 0 message) (nth 1 message)
                 (if next (nth 0 next) end) (nth 2 message)))
              (setq messages (cdr messages))))))
    (error
     (message "chat: couldn't present transcript: %s"
              (error-message-string error))
     nil)))

;;; Marker-scoped conversation kernel

(defun emacsos-conversation-commit-user (prefix-start body-start end)
  "Present the just-committed user region PREFIX-START through END."
  (emacsos--chat-present-message prefix-start body-start end 'user))

(defun emacsos-conversation-begin-assistant (body-start body-end)
  "Return non-inserting markers delimiting one provisional assistant body."
  (cons (copy-marker body-start nil) (copy-marker body-end nil)))

(defun emacsos-conversation-replace-marked (start end text)
  "Replace START through END with TEXT and return the new exclusive end.
This is the shared exact-text primitive for conversation adapters.  The caller
owns marker storage; it only changes the marked, read-only transcript region
and preserves point in the editable draft."
  (let ((inhibit-read-only t) (inhibit-modification-hooks t))
    (save-excursion
      (goto-char start)
      (delete-region start end)
      (let ((before (point)))
        (insert text)
        (add-text-properties before (point)
                             '(read-only t front-sticky t rear-nonsticky t))
        (point)))))

(defun emacsos-conversation-set-status (start end status &optional trailing-space)
  "Replace the status marker region START..END with visible STATUS.
When TRAILING-SPACE is non-nil, retain the local stream's token separator."
  (emacsos-conversation-replace-marked
   start end (format "[%s]%s" status (if trailing-space " " ""))))

(defun emacsos-conversation-reset-assistant (start end)
  "Clear only the provisional assistant marker region START..END."
  (emacsos-conversation-replace-marked start end ""))

(defun emacsos-conversation-append-delta (end text)
  "Append read-only TEXT at provisional assistant marker END and return its end."
  (emacsos-conversation-replace-marked end end text))

(defun emacsos-conversation-finish-assistant (body-start body-end)
  "Present the completed assistant body delimited by BODY-START and BODY-END."
  (emacsos--chat-present-markdown-1 body-start body-end))

(defun emacsos-conversation-fail-assistant (start end reason)
  "Replace provisional START..END with one read-only failure REASON."
  (emacsos-conversation-replace-marked start end (format "[%s]" reason)))

;; The chat stream engine is buffer-agnostic: handlers render into the
;; buffer that initiated the current stream, not the literal *chat*.  That
;; buffer is the *chat* scratch or a file-backed `emacsos-assist-mode' buffer.
;; The phone-wide active-surface slot means only one conversation stream is
;; ever in flight, so this global safely names the local transport target.
(defvar emacsos--chat-stream-buffer nil
  "Buffer the in-flight stream renders into; set at SEND.  See above.")

;; Defined by the two Assist surfaces required by os.el alongside chat.
;; Resolved at call time so chat.el remains the generic send engine.
(declare-function emacsos-assist--surface-context "emacsos-assist")
(declare-function emacsos-assist--save "emacsos-assist")
(declare-function emacsos-assist-web-send "assist-web")

(defun emacsos--chat-render-buffer ()
  "The buffer the stream handlers render into: the active stream buffer if
set and live, else the *chat* buffer (creating it if needed).
The *chat* fallback is reached only with NO active stream (legacy path) or a
live target — the stream paths intercept a killed target first via
`emacsos--chat-render-target-lost-p', so a dead .assist buffer never falls
through to *chat'."
  (or (and (buffer-live-p emacsos--chat-stream-buffer) emacsos--chat-stream-buffer)
      (emacsos--chat-buffer)))

(defun emacsos--chat-render-target-lost-p ()
  "Non-nil when a stream is in flight but the surface it renders into was
killed.  Falling back to *chat* then would leak this conversation's tokens
into the unrelated legacy buffer, so the stream paths abandon instead."
  (and emacsos--chat-stream-buffer
       (not (buffer-live-p emacsos--chat-stream-buffer))))

(defun emacsos--chat-abandon-stream ()
  "Kill the in-flight URL process and tear down silently — used when the
originating .assist surface was killed mid-stream, so there is nowhere to
render the rest of the response (and nothing to error onto)."
  (when (and (processp emacsos--chat-process)
             (process-live-p emacsos--chat-process))
    (delete-process emacsos--chat-process))
  (emacsos--chat-stream-cleanup))

(defun emacsos--chat-surface-context (buf)
  "Request context plist (:thread-id :workdir) for chat-surface BUF.
A `emacsos-assist-mode' file buffer gets its per-file thread id (minted +
written into the file's header on first send) and the file's directory; the
plain *chat* buffer gets nil context (the legacy fixed conversation)."
  (if (and (buffer-live-p buf)
           (with-current-buffer buf (derived-mode-p 'emacsos-assist-mode)))
      (with-current-buffer buf (emacsos-assist--surface-context))
    nil))

(defun emacsos--chat-save-surface (buf)
  "Persist BUF's transcript if it is a `emacsos-assist-mode' file buffer
\(no-op for the ephemeral *chat*)."
  (when (and (buffer-live-p buf)
             (with-current-buffer buf (derived-mode-p 'emacsos-assist-mode)))
    (with-current-buffer buf (emacsos-assist--save))))

;;; Buffer + input region

(defun emacsos--chat-buffer ()
  "Return the *chat* buffer, creating and initializing if absent."
  (let ((buf (get-buffer emacsos--chat-buffer-name)))
    (unless buf
      (setq buf (get-buffer-create emacsos--chat-buffer-name))
      (emacsos--chat-init-buffer buf))
    buf))

(defun emacsos--chat-init-buffer (buf)
  "Seed BUF with an empty read-only header and a fresh prompt."
  (setq emacsos--chat-rollback-pending nil)
  (with-current-buffer buf
    ;; Chat is prose, not code — render the transcript + input in the
    ;; proportional `variable-pitch' face (the keyboard stays monospace
    ;; in its own buffer).  The face family is set in the init snippet.
    (variable-pitch-mode 1)
    (emacsos--chat-enable-presentation)
    (emacsos-conversation-install-actions
     '((send . emacsos--chat-send)
       (abort . emacsos--chat-abort)
       (new . emacsos--chat-new-chat)))
    (local-set-key (kbd "RET") #'emacsos-conversation-activate-or-newline)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (emacsos--chat-write-prompt))
    (goto-char (point-max))))

(defun emacsos--chat-write-prompt ()
  "Insert the prompt and mark it read-only.  Point left after it."
  (let ((before (point)))
    (insert emacsos--chat-prompt)
    (add-text-properties before (point)
                         '(read-only t front-sticky t rear-nonsticky t))))

(defun emacsos--chat-input-start (buf)
  "Position immediately after the last `emacsos--chat-prompt' in BUF."
  (with-current-buffer buf
    (save-excursion
      (goto-char (point-max))
      (when (search-backward emacsos--chat-prompt nil t)
        (+ (point) (length emacsos--chat-prompt))))))

(defun emacsos--chat-current-input (buf)
  "Text in BUF between the input-start and point-max, trimmed."
  (let ((start (emacsos--chat-input-start buf)))
    (when start
      (with-current-buffer buf
        (string-trim (buffer-substring-no-properties start (point-max)))))))

(defun emacsos--chat-clear-input (buf)
  "Delete the editable input region in BUF, leaving the prompt intact."
  (let ((start (emacsos--chat-input-start buf)))
    (when start
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (delete-region start (point-max)))))))

;;; Stream handlers (called from the process filter, per NDJSON event)

(defun emacsos--chat-handle-start (_event)
  "Open a new bot line in the active conversation buffer.  Set up the three
markers (insert / status-start / status-end) used by subsequent
event handlers."
  (if (markerp emacsos--chat-stream-insert-marker)
      ;; Send already reserved the single provisional region before opening
      ;; the transport; a delayed start only updates that existing status.
      (emacsos--chat-handle-status '(:text "working"))
    (let ((buf (emacsos--chat-render-buffer)))
    (with-current-buffer buf
      ;; Clear any stale per-stream first-token timer.
      (when (timerp emacsos--chat-first-token-timer)
        (cancel-timer emacsos--chat-first-token-timer)
        (setq emacsos--chat-first-token-timer nil))
      ;; Insert "\nbot> " above the prompt, anchored by markers.
      (let* ((input-start (emacsos--chat-input-start buf))
             (prompt-start (when input-start
                             (- input-start (length emacsos--chat-prompt)))))
        (when prompt-start
          (let ((inhibit-read-only t))
            (save-excursion
              (goto-char prompt-start)
              ;; Insert "\nbot> " at the prompt's position.  The
              ;; existing prompt and input get pushed down.
              (let ((line-start (point)))
                (insert "\n")
                (let ((prefix-start (point)))
                  (insert emacsos--chat-bot-prefix)
                  (emacsos--chat-present-message
                   prefix-start (point) (point) 'assistant))
                ;; Insert marker sits just after "bot> " — that's where
                ;; tokens and status both insert.  Marker insertion-type
                ;; t so it moves forward as content is added.
                (setq emacsos--chat-stream-insert-marker
                      (copy-marker (point) t))
                ;; Status markers also sit here for now; status events
                ;; insert "[ ... ] " between them, and tokens insert
                ;; after status-end.  Both insertion-type nil: status-
                ;; start anchors the left edge; status-end stays put
                ;; when tokens insert at the same position via the
                ;; insert-marker, so a subsequent status event's
                ;; clear-bracket can't accidentally delete streamed
                ;; tokens.  handle-status `set-marker's status-end
                ;; explicitly after inserting its bracket text.
                (pcase-let ((`(,status-start . ,status-end)
                             (emacsos-conversation-begin-assistant (point) (point))))
                  (setq emacsos--chat-status-start status-start
                        emacsos--chat-status-end status-end))
                ;; The "\nbot> " text we just inserted needs read-only
                ;; props applied (the per-token insertion path applies
                ;; props to each token).
                (add-text-properties line-start (point)
                                     '(read-only t front-sticky t rear-nonsticky t)))))))))))

(defun emacsos--chat-clear-status-bracket ()
  "Delete the status bracket between `status-start' and `status-end'.
Caller must `inhibit-read-only`."
  (when (and (markerp emacsos--chat-status-start)
             (markerp emacsos--chat-status-end)
             (< emacsos--chat-status-start emacsos--chat-status-end))
    (delete-region emacsos--chat-status-start emacsos--chat-status-end)
    ;; Both markers collapse onto the same position now.
    (set-marker emacsos--chat-status-end emacsos--chat-status-start)))

(defun emacsos--chat-handle-status (event)
  "Replace the status bracket with `[<event.text>] '."
  (let ((text (plist-get event :text))
        (buf (emacsos--chat-render-buffer)))
    (when (and text buf (buffer-live-p buf)
               (markerp emacsos--chat-status-start))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (save-excursion
            (emacsos--chat-clear-status-bracket)
            (set-marker emacsos--chat-status-end
                        (emacsos-conversation-set-status
                         emacsos--chat-status-start emacsos--chat-status-end text t))))))))

(defun emacsos--chat-handle-token (event)
  "Append the token text after `status-end'.  First token also
clears any lingering status bracket (the agent is now talking, not
working silently)."
  (let ((text (plist-get event :text))
        (buf (emacsos--chat-render-buffer)))
    (when (and text buf (buffer-live-p buf)
               (markerp emacsos--chat-stream-insert-marker))
      (with-current-buffer buf
        (cl-incf emacsos--chat-tokens-seen)
        (let ((inhibit-read-only t))
          (save-excursion
            (when (= emacsos--chat-tokens-seen 1)
              (emacsos--chat-clear-status-bracket))
            (set-marker emacsos--chat-stream-insert-marker
                        (emacsos-conversation-append-delta
                         emacsos--chat-stream-insert-marker text))))))))

(defun emacsos--chat-handle-heartbeat (_event)
  "Heartbeat is purely transport-level — no UI change."
  nil)

(defun emacsos--chat-handle-end (event)
  "Finish or recover a stream described by EVENT.
Clear status and release the in-flight lock and markers.  A genuine end event
also presents the complete Markdown body; a nil watchdog event leaves it raw."
  (let ((buf (emacsos--chat-render-buffer)))
    (unwind-protect
        (when (and buf (buffer-live-p buf))
          (with-current-buffer buf
            (let* ((inhibit-read-only t)
                   (window (get-buffer-window buf))
                   (window-start-position (and window (window-start window))))
              (emacsos--chat-clear-status-bracket)
              ;; A nil EVENT is the watchdog's synthetic cleanup after a
              ;; connection close.  Only a real terminal event proves that a
              ;; half-received Markdown delimiter is complete.
              (when (and (equal (plist-get event :type) "end")
                         (markerp emacsos--chat-status-start)
                         (markerp emacsos--chat-stream-insert-marker))
                (condition-case error
                    (emacsos-conversation-finish-assistant
                     (marker-position emacsos--chat-status-start)
                     (marker-position emacsos--chat-stream-insert-marker))
                  (error
                   (message "chat: couldn't present Markdown: %s"
                            (error-message-string error)))))
              (when (and window-start-position (window-live-p window))
                (set-window-start window window-start-position t)))))
      (emacsos--chat-stream-cleanup))))

(defun emacsos--chat-handle-error (event)
  "Render `[error: <reason>]' on the bot line and clean up.
If start has already run (markers present), insert at the marker.
Otherwise (error before any server response), synthesize a fresh
`\\nbot> [error: ...]' above the prompt so the user sees something."
  (let ((reason (or (plist-get event :reason) "unknown"))
        (buf (emacsos--chat-render-buffer)))
    (when (and buf (buffer-live-p buf))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (save-excursion
            (cond
             ;; Stream had a start: append to existing bot line.
             ((markerp emacsos--chat-stream-insert-marker)
              (emacsos--chat-clear-status-bracket)
              (set-marker emacsos--chat-stream-insert-marker
                          (emacsos-conversation-fail-assistant
                           emacsos--chat-stream-insert-marker
                           emacsos--chat-stream-insert-marker
                           (format "error: %s" reason))))
             ;; Error before any server response: render a fresh
             ;; bot line above the prompt directly.
             (t
              (let* ((input-start (emacsos--chat-input-start buf))
                     (prompt-start (when input-start
                                     (- input-start (length emacsos--chat-prompt)))))
                (when prompt-start
                  (goto-char prompt-start)
                  (let ((before (point)))
                    (insert "\n")
                    (let ((prefix-start (point)))
                      (insert emacsos--chat-bot-prefix)
                      (let ((body-start (point)))
                        (insert "[error: " reason "]")
                        (emacsos--chat-present-message
                         prefix-start body-start (point) 'assistant)))
                    (add-text-properties
                     before (point)
                     '(read-only t front-sticky t rear-nonsticky t)))))))))))
    (emacsos--chat-stream-cleanup)))

(defun emacsos--chat-note (text &optional buffer)
  "Insert TEXT as a read-only `bot> ' note line above the input prompt.
Renders into BUFFER, defaulting to the active render target
\(`emacsos--chat-render-buffer').  Used for applied / rollback notices
(system messages, not streamed bot output).  Async, non-stream callers —
the /rollback flow, a legacy *chat*-only config operation — MUST pass an
explicit buffer so a delayed response can't land in an unrelated .assist
stream that started meanwhile."
  (let ((buf (or buffer (emacsos--chat-render-buffer))))
    (when (and buf (buffer-live-p buf))
      (with-current-buffer buf
        (let* ((inhibit-read-only t)
               (input-start (emacsos--chat-input-start buf))
               (prompt-start (when input-start
                               (- input-start (length emacsos--chat-prompt)))))
          (when prompt-start
            (save-excursion
              (goto-char prompt-start)
              (let ((before (point)))
                (insert "\n")
                (let ((prefix-start (point)))
                  (insert emacsos--chat-bot-prefix)
                  (let ((body-start (point)))
                    (insert text)
                    (emacsos--chat-present-message
                     prefix-start body-start (point) 'assistant)))
                (add-text-properties before (point)
                                     '(read-only t front-sticky t rear-nonsticky t))))))))))

(defun emacsos--chat-handle-applied (event)
  "Handle the `applied' event: the agent shipped a config to the phone.
Note it in the transcript and enable the rollback command.  `:broken' t
means it was committed but loading or platform finalization errored (a JSON
false parses as the symbol `:false', so test for `t' explicitly)."
  (let ((detail (or (plist-get event :detail) "config applied"))
        (broken (eq (plist-get event :broken) t)))
    (emacsos--chat-note
     (if broken
         (format "[applied but BROKEN; inspect failure: %s]" detail)
       (format "[%s]" detail)))
    (setq emacsos--chat-rollback-pending nil)))

(defun emacsos--chat-stream-cleanup ()
  "Tear down per-stream state.  Idempotent: safe to call from any
of the terminal handlers (end, error, abort, watchdog)."
  (dolist (sym '(emacsos--chat-first-token-timer
                 emacsos--chat-watchdog-timer))
    (let ((tm (symbol-value sym)))
      (when (timerp tm) (cancel-timer tm)))
    (set sym nil))
  (dolist (sym '(emacsos--chat-stream-insert-marker
                 emacsos--chat-status-start
                 emacsos--chat-status-end))
    (let ((m (symbol-value sym)))
      (when (markerp m) (set-marker m nil)))
    (set sym nil))
  ;; Persist a file-backed (.assist) surface's transcript on stream
  ;; end/error/abort, then drop the stream-buffer reference.  Best-effort:
  ;; a save failure here (e.g. the same broken file that triggered the error
  ;; we're cleaning up after) must NOT abort teardown and strand the UI
  ;; in-flight — surface it and carry on.
  (condition-case err
      (emacsos--chat-save-surface emacsos--chat-stream-buffer)
    (error (message "chat: couldn't save transcript: %s"
                    (error-message-string err))))
  (setq emacsos--chat-stream-buffer nil)
  (setq emacsos--chat-tokens-seen 0
        emacsos--chat-last-event-time nil
        emacsos--chat-in-flight nil
        emacsos--chat-process nil)
  (when (eq emacsos--assist-active-surface 'chat)
    (setq emacsos--assist-active-surface nil)))

(defconst emacsos--chat-watchdog-quiet-secs 5.0
  "Watchdog grace window — see `emacsos--chat-watchdog-tick'.")

(defun emacsos--chat-watchdog-tick ()
  "Detect connection-closed-but-stream-not-cleaned-up.

Known v1 limitation: url-http sometimes kills its response buffer
before our filter has drained the chunk containing the end event,
or url-http swaps sentinels mid-stream so our hook is detached.
Either way, `emacsos--chat-in-flight' can stay t after the stream
naturally ends, leaving the UI stuck on ABORT.  This timer
notices.  The 5-second grace window after the last NDJSON event
is generous enough that fast-streaming runs always finish
gracefully via the real end event, and slow / no-end runs get
synthesized cleanup within ~5s of the real connection close."
  (when (and emacsos--chat-in-flight
             (or (not (processp emacsos--chat-process))
                 (not (process-live-p emacsos--chat-process))))
    (when (and (processp emacsos--chat-process)
               (buffer-live-p (process-buffer emacsos--chat-process)))
      (with-current-buffer (process-buffer emacsos--chat-process)
        (when (and (boundp 'url-http-end-of-headers)
                   url-http-end-of-headers)
          (emacsos--chat-drain-body))))
    (let ((quiet-for (if emacsos--chat-last-event-time
                         (- (float-time) emacsos--chat-last-event-time)
                       0.0)))
      (when (>= quiet-for emacsos--chat-watchdog-quiet-secs)
        (cond
         ((emacsos--chat-render-target-lost-p) (emacsos--chat-abandon-stream))
         ((> emacsos--chat-tokens-seen 0) (emacsos--chat-handle-end nil))
         (t (emacsos--chat-handle-error
             (list :type "error"
                   :reason "connection closed without end event"))))))))

(defconst emacsos--chat-event-handlers
  '(("start"     . emacsos--chat-handle-start)
    ("token"     . emacsos--chat-handle-token)
    ("status"    . emacsos--chat-handle-status)
    ("end"       . emacsos--chat-handle-end)
    ("error"     . emacsos--chat-handle-error)
    ("applied"   . emacsos--chat-handle-applied)
    ("heartbeat" . emacsos--chat-handle-heartbeat)))

;;; HTTP request encoding

(defun emacsos--chat-endpoint (path)
  "Return the server URL for PATH (e.g. \"/rollback\"), derived from
`emacsos-chat-server-url' by swapping its path component.  Keeping one
configured base URL means /chat and /rollback can't drift to different
hosts."
  (let ((u (url-generic-parse-url emacsos-chat-server-url)))
    (setf (url-filename u) path)
    (url-recreate-url u)))

(defun emacsos--chat-read-auth-file ()
  "Return the auth file contents as a string, or nil if missing."
  (when (file-readable-p emacsos-chat-auth-file)
    (with-temp-buffer
      (let ((coding-system-for-read 'no-conversion))
        (insert-file-contents-literally emacsos-chat-auth-file))
      (buffer-string))))

(defun emacsos--chat-encode-request (msg auth &optional thread-id workdir)
  "Encode the request body as UTF-8 bytes.
With AUTH non-nil, the payload includes phone:{auth_file}; the `phone' key
is omitted when AUTH is nil so the server treats it as absent rather than
null.  THREAD-ID + WORKDIR (file-backed chat) are included only when
non-nil; absent => the server's legacy fixed conversation."
  (let* ((payload (append (list :message msg)
                          (when auth (list :phone (list :auth_file auth)))
                          (when thread-id (list :thread_id thread-id))
                          (when workdir (list :workdir workdir))))
         (json-encoding-pretty-print nil)
         (body (json-encode payload)))
    (encode-coding-string body 'utf-8)))

(defun emacsos--chat-encode-rollback (auth)
  "Encode the /rollback request body as UTF-8 bytes: {phone:{auth_file}}
when AUTH is non-nil, else {}."
  (let* ((payload (if auth (list :phone (list :auth_file auth)) nil))
         (json-encoding-pretty-print nil)
         (body (json-encode (or payload (make-hash-table)))))
    (encode-coding-string body 'utf-8)))

;;; Process filter (NDJSON parser)

(defun emacsos--chat-make-filter (url-filter)
  "Build a wrapping process-filter that calls URL-FILTER first
\(so url-http's state machine processes headers + appends to the
response buffer) then drains any new body bytes through our NDJSON
parser.  Captures URL-FILTER in a closure rather than calling
`url-http-generic-filter' directly, because url-http installs
several different filter functions depending on the request mode
\(generic, chunked, content-length); whichever was installed at
url-retrieve time is what we must preserve."
  (lambda (proc bytes)
    (when (functionp url-filter)
      (funcall url-filter proc bytes))
    ;; url-http may drain an aborted process after another request starts.
    ;; Only the process currently owning the phone-wide chat state may dispatch.
    (when (eq proc emacsos--chat-process)
      (let ((buf (process-buffer proc)))
        (when (and buf (buffer-live-p buf))
          (with-current-buffer buf
            (when (and (boundp 'url-http-end-of-headers)
                       url-http-end-of-headers)
              (emacsos--chat-drain-body))))))))

;; Note: we used to wrap the process-sentinel for client-side
;; connection-lost detection, but url-http SWAPS its sentinel as the
;; connection state evolves (idle → async → end-of-document → ...).
;; A wrap captured at install time shadows later sentinels with
;; whichever one we caught first — request never gets written.
;; Cleanup paths today: stream events (server emits start/end/error)
;; or the first-token timeout.  Connection-lost-without-event is
;; therefore detected via the timeout, not the sentinel.

(defun emacsos--chat-drain-body ()
  "Called inside the url process buffer with point/headers parsed.
Reads everything after `url-http-end-of-headers' that we haven't
seen yet, splits on \\n, dispatches each JSON line.  Idempotent —
tracks how much body has already been processed via a buffer-local
marker.  The marker has insertion-type nil (stationary on insert)
so it stays at the read/unread boundary as the URL filter
continues appending bytes after it."
  (unless (and (local-variable-p 'emacsos--chat-body-read-marker)
               (markerp emacsos--chat-body-read-marker))
    ;; url-http-end-of-headers is a marker pointing at the first
    ;; byte of the body (right after the \r\n\r\n separator).
    ;; Position our read-cursor there; nil insertion-type so url's
    ;; filter inserts BEYOND us rather than pushing us forward.
    (setq-local emacsos--chat-body-read-marker
                (copy-marker (marker-position url-http-end-of-headers)
                             nil)))
  (let ((from (marker-position emacsos--chat-body-read-marker))
        (to (point-max)))
    (when (< from to)
      (let* ((raw (buffer-substring-no-properties from to))
             (last-nl (cl-position ?\n raw :from-end t)))
        (when last-nl
          (let ((complete (substring raw 0 (1+ last-nl))))
            (set-marker emacsos--chat-body-read-marker
                        (+ from (length complete)))
            (dolist (line (split-string complete "\n" t))
              (emacsos--chat-dispatch-line line))))))))

(defun emacsos--chat-dispatch-line (line)
  "Parse one NDJSON line as a JSON object, dispatch to handler.
Silently drops events that arrive after `emacsos--chat-in-flight'
has cleared (eg. url-http drains buffered bytes after ABORT
deletes the process) so a late `start' can't resurrect bot
markers/lines after the UI has been cleaned up."
  (when emacsos--chat-in-flight
    (if (emacsos--chat-render-target-lost-p)
        (emacsos--chat-abandon-stream)   ; surface killed mid-stream: bail
    (let ((event (condition-case _
                     (json-parse-string line
                                        :object-type 'plist
                                        :null-object nil
                                        :array-type 'list)
                   (error nil))))
      (when (and event (listp event))
        (setq emacsos--chat-last-event-time (float-time))
        (let* ((etype (plist-get event :type))
               (handler (cdr (assoc etype emacsos--chat-event-handlers))))
          (when handler
            (condition-case err
                (funcall handler event)
              (error
               (message "chat: handler %s failed: %s" etype err))))))))))

;; Note: no process-sentinel installed.  url-http swaps sentinels
;; mid-stream as its state machine progresses (idle → async →
;; end-of-document), so any sentinel we'd hook up would be silently
;; detached.  Connection-lost-without-end is caught by the watchdog
;; (synthesizes an end / error event after a quiet grace window).
;; ABORT calls `emacsos--chat-stream-cleanup' synchronously.

;;; SEND / CLEAR / ABORT

(defun emacsos--chat-send (&optional surface)
  "Open a streaming request to /chat with SURFACE's current input.
SURFACE defaults to the *chat* buffer; a `emacsos-assist-mode' file buffer
sends its per-file thread id + the file's directory so the server keys a
  per-file conversation and operates on that directory."
  (interactive)
  (when (and (bufferp emacsos--assist-active-surface)
             (not (buffer-live-p emacsos--assist-active-surface)))
    (setq emacsos--assist-active-surface nil))
  (if (or emacsos--chat-in-flight emacsos--assist-active-surface)
      (message "another Assist request is in flight; abort it before sending")
    (let* ((buf (or surface (emacsos--chat-buffer)))
           (msg (emacsos--chat-current-input buf))
           (ctx nil))
      (when (and msg (not (string-empty-p msg)))
        ;; Derive context only now that we're committing to a turn: for a
        ;; .assist surface this mints the thread id + writes the header, so an
        ;; empty-input tap must not reach it (it would dirty a fresh file).
        (setq ctx (emacsos--chat-surface-context buf))
        (setq emacsos--chat-in-flight t
              emacsos--assist-active-surface 'chat
              emacsos--chat-tokens-seen 0
              emacsos--chat-stream-buffer buf)
        ;; Commit the user turn and reserve its one provisional assistant body
        ;; before url-retrieve can call any callback.
        (let ((inhibit-read-only t))
          (with-current-buffer buf
            (emacsos--chat-clear-input buf)
            (let* ((input-start (emacsos--chat-input-start buf))
                   (prompt-start (when input-start
                                   (- input-start (length emacsos--chat-prompt)))))
              (when prompt-start
                (save-excursion
                  (goto-char prompt-start)
                  (let ((before (point)))
                    (insert "\n")
                    (let ((prefix-start (point)))
                      (insert "you> ")
                      (let ((body-start (point)))
                        (insert msg)
                        (emacsos-conversation-commit-user
                         prefix-start body-start (point))))
                    (add-text-properties before (point)
                                         '(read-only t front-sticky t rear-nonsticky t))))))))
        (emacsos--chat-handle-start nil)
        (emacsos--chat-handle-status '(:text "queued"))
        ;; First-token watchdog.  Fires once if no event lands
        ;; within the configured timeout AND we're still in flight.
        ;; Uses `emacsos--chat-terminate-stream' so the URL process is
        ;; actually killed -- otherwise a late-arriving response would
        ;; keep delivering events into the just-cleaned-up UI.
        (setq emacsos--chat-first-token-timer
              (run-with-timer
               emacsos-chat-first-token-timeout nil
               (lambda ()
                 (when (and emacsos--chat-in-flight
                            (= emacsos--chat-tokens-seen 0))
                   (emacsos--chat-terminate-stream
                    (format "no response from server after %ds"
                            emacsos-chat-first-token-timeout))))))
        ;; Connection-close watchdog.  Polls every 1s; only fires
        ;; end/error when the process is dead AND at least
        ;; `emacsos--chat-watchdog-quiet-secs' have passed since the
        ;; last NDJSON event (lets the filter drain the final chunk).
        (setq emacsos--chat-last-event-time (float-time))
        (setq emacsos--chat-watchdog-timer
              (run-with-timer 1 1 #'emacsos--chat-watchdog-tick))
        ;; Fire the request.  `url-retrieve` returns a BUFFER (not a
        ;; process); the process is `get-buffer-process` on it.
        (condition-case err
            (let* ((auth (emacsos--chat-read-auth-file))
                   (url-request-method "POST")
                   (url-request-extra-headers
                    '(("Content-Type" . "application/json; charset=utf-8")))
                   (url-request-data (emacsos--chat-encode-request
                                      msg auth
                                      (plist-get ctx :thread-id)
                                      (plist-get ctx :workdir)))
                   ;; Persist the you> turn just before the POST fires
                   ;; (file-backed .assist only; no-op for *chat*).  Bound
                   ;; here, inside the request's error guard, so a save
                   ;; failure (read-only file, missing dir) tears the stream
                   ;; down via the same handler instead of stranding the UI
                   ;; in-flight with no process to clean it up.
                   (_save (emacsos--chat-save-surface buf))
                   ;; url-retrieve args: URL, CALLBACK, CBARGS, SILENT,
                   ;; INHIBIT-COOKIES.  (No TIMEOUT arg in Emacs >=24;
                   ;; we rely on `emacsos--chat-first-token-timer' and
                   ;; the watchdog for cancellation instead.)
                   (response-buf (url-retrieve emacsos-chat-server-url
                                               #'ignore nil
                                               t   ; SILENT
                                               t)) ; INHIBIT-COOKIES
                   (proc (and (buffer-live-p response-buf)
                              (get-buffer-process response-buf))))
              (unless proc
                (error "url-retrieve returned no live process for %s"
                       emacsos-chat-server-url))
              (setq emacsos--chat-process proc)
              ;; Wrap (don't replace) url-http's filter.  Capture the
              ;; CURRENT filter; url-http installs the right one before
              ;; url-retrieve returns and doesn't swap it mid-stream.
              ;;
              ;; We intentionally do NOT wrap the sentinel: url-http
              ;; SWAPS the sentinel as the connection state evolves
              ;; (idle → async → end-of-document → ...), and any wrap
              ;; captured at this moment would shadow later sentinels
              ;; with whichever one we caught first.  Cleanup happens
              ;; via stream events (server always emits start/end/error)
              ;; or via the first-token timeout when nothing arrives.
              (set-process-filter
               proc (emacsos--chat-make-filter (process-filter proc))))
          (error
           (emacsos--chat-handle-error
            (list :type "error"
                  :reason (format "send failed: %s"
                                  (error-message-string err))))))))))

(defun emacsos--chat-new-chat ()
  "Clear the conversation behind a two-invocation confirmation.

The clear is irreversible: it wipes the conversation and the agent's
working-directory memory.  The first invocation arms and reports what to run
again; the second clears the server and local transcript.  Another EmacsOS
button action cancels the arm.  No minibuffer or GUI confirmation is used.

Refuses (without arming) while a stream is in flight; run
`emacsos--chat-abort' first.
The /clear POST is fire-and-forget: the local transcript clears regardless
of whether it succeeds.  This is the ONLY thing that makes the agent
forget; the conversation otherwise persists across turns and restarts."
  (interactive)
  (cond
   (emacsos--chat-in-flight
    (message "chat: stream in flight; run emacsos--chat-abort to cancel"))
   (emacsos--chat-confirm-pending
    ;; Second invocation: confirmed — clear for real.
    (setq emacsos--chat-confirm-pending nil)
    (emacsos--chat-forget-server)
    (emacsos--chat-init-buffer (emacsos--chat-buffer)))
   (t
    (setq emacsos--chat-confirm-pending t)
    (message "Run emacsos--chat-new-chat again to confirm clear"))))

(defun emacsos--chat-maybe-disarm-confirm (action arg)
  "Disarm New chat or rollback confirmation on a different EmacsOS button.
Utility and safety-control buttons run through `emacsos--run-command' with the
command function as ARG.  Registered on `emacsos--confirm-disarm-functions'."
  (let ((tapped (and (eq action #'emacsos--run-command) arg)))
    (when (and emacsos--chat-confirm-pending
               (not (eq tapped #'emacsos--chat-new-chat)))
      (setq emacsos--chat-confirm-pending nil))
    (when (and emacsos--chat-rollback-pending
               (not (eq tapped #'emacsos--chat-rollback)))
      (setq emacsos--chat-rollback-pending nil))))

(add-hook 'emacsos--confirm-disarm-functions
          #'emacsos--chat-maybe-disarm-confirm)

(defun emacsos--chat-forget-server ()
  "POST /clear so the server forgets the persistent conversation.
Argument-free: /clear resets server-side conversation state — the
checkpoint AND the agent's working-dir memory (=AGENTS.md=) — and never
calls back into this emacs (unlike /rollback), so it needs no phone
context.  Fire-and-forget — a failure is logged via `message', never
blocking the local transcript reset."
  (let ((url-request-method "POST")
        (url-request-extra-headers
         '(("Content-Type" . "application/json; charset=utf-8")))
        ;; Empty but valid JSON to match the declared Content-Type; the
        ;; server ignores the body (/clear is argument-free).
        (url-request-data "{}"))
    (condition-case err
        (url-retrieve (emacsos--chat-endpoint "/clear")
                      #'emacsos--chat-forget-callback nil t t)
      (error
       (message "chat: /clear failed: %s" (error-message-string err))))))

(defun emacsos--chat-forget-callback (status &rest _)
  "Kill the /clear response buffer so repeated New-chat taps don't leak
` *http*' buffers; report a transport error via `message' if one
occurred.  Runs after the local reset, so it only reports."
  (let ((resp (current-buffer)))
    (when (plist-get status :error)
      (message "chat: /clear error: %S" (plist-get status :error)))
    (when (buffer-live-p resp) (kill-buffer resp))))

(defun emacsos--chat-terminate-stream (reason)
  "Kill the in-flight stream's URL process (if any) and render
`[error: REASON]' on the bot line, then tear down per-stream
state.  Used by ABORT and by the first-token timeout so neither
leaves a half-killed stream that keeps delivering events into a
cleaned-up UI.  Safe no-op when no stream is in flight."
  (when emacsos--chat-in-flight
    (when (and (processp emacsos--chat-process)
               (process-live-p emacsos--chat-process))
      (delete-process emacsos--chat-process))
    (if (emacsos--chat-render-target-lost-p)
        (emacsos--chat-stream-cleanup)   ; nowhere to render the error
      (emacsos--chat-handle-error
       (list :type "error" :reason reason)))))

(defun emacsos--chat-abort ()
  "Cancel the in-flight stream.  Synchronously kills the URL process
and renders `[error: aborted]', so the UI returns to CLEAR
immediately without waiting for the watchdog.  We can't rely on
url-http's sentinel here -- it gets swapped mid-stream by the
url-http state machine, so any sentinel-driven cleanup is unreliable."
  (interactive)
  (emacsos--chat-terminate-stream "aborted"))

;;; Rollback

(defun emacsos--chat-rollback ()
  "Roll back the last applied config by POSTing /rollback.

ASYNC on purpose: the server's /rollback handler calls back INTO this
emacs (via emacsclient) to load the reverted config, so a synchronous
request would deadlock — this emacs would be blocked waiting for the
response it must itself service.  The result is reported in the
transcript by `emacsos--chat-rollback-callback'."
  (interactive)
  (cond
   (emacsos--chat-in-flight
    (message "chat: stream in flight; ABORT before rolling back"))
   ((not emacsos--chat-rollback-pending)
    (setq emacsos--chat-rollback-pending t)
    (message "Run emacsos--chat-rollback again to confirm rollback"))
   (t
    ;; Second tap: confirmed — POST /rollback for real.
    (setq emacsos--chat-rollback-pending nil)
    (let* ((auth (emacsos--chat-read-auth-file))
           (url-request-method "POST")
           (url-request-extra-headers
            '(("Content-Type" . "application/json; charset=utf-8")))
           (url-request-data (emacsos--chat-encode-rollback auth)))
      ;; Rollback is a legacy *chat*-only config flow; pin its notices to
      ;; *chat* (not the implicit render target) so the async callback can't
      ;; write into a .assist stream the user starts before it returns.
      (emacsos--chat-note "[rolling back…]" (emacsos--chat-buffer))
      (condition-case err
          (url-retrieve (emacsos--chat-endpoint "/rollback")
                        #'emacsos--chat-rollback-callback nil t t)
        (error
         (emacsos--chat-note
          (format "[rollback failed: %s]" (error-message-string err))
          (emacsos--chat-buffer))))))))

(defun emacsos--chat-rollback-callback (status &rest _)
  "Parse the /rollback JSON response and report it in the transcript.
Runs in the url-retrieve response buffer, which we kill when done so
repeated rollbacks don't leak ` *http*` buffers."
  (let* ((resp (current-buffer))
         (result
          (condition-case err
              (if (plist-get status :error)
                  (list :status "error"
                        :detail (format "%S" (plist-get status :error)))
                ;; Skip past the HTTP headers to the JSON body.  Search
                ;; the blank-line boundary (handles \r\n\r\n real
                ;; responses and \n\n test fixtures) rather than relying
                ;; on url-http-end-of-headers, which is a buffer-local
                ;; marker that's awkward to reproduce off the wire.
                (goto-char (point-min))
                (re-search-forward "\r?\n\r?\n" nil t)
                (json-parse-buffer :object-type 'plist
                                   :null-object nil
                                   :array-type 'list))
            (error (list :status "error"
                         :detail (error-message-string err))))))
    (unwind-protect
        (let ((st (or (plist-get result :status) "error"))
              (detail (or (plist-get result :detail) "")))
          (emacsos--chat-note (format "[rollback %s: %s]" st detail)
                             (emacsos--chat-buffer))
          ;; A reached-and-recorded rollback consumes pending confirmation.
          (when (member st '("applied" "load_error"))
            (setq emacsos--chat-rollback-pending nil)))
      (when (buffer-live-p resp) (kill-buffer resp)))))

(defun emacsos--chat-show-top-buffer ()
  "Display *chat* in the editor (target) window.  Idempotent.
Interactive so M-x can reach it; the built-in keyboard's Chat utility button
reaches it through `emacsos--chat-button'."
  (interactive)
  (let ((buf (emacsos--chat-buffer))
        (w (emacsos--target)))
    (when (and w (not (eq (window-buffer w) buf)))
      (set-window-buffer w buf))))

(defun emacsos--chat-surface-on-top ()
  "Return an Assist-surface buffer in the target (editor) window.

This recognizes the *chat* scratch, a file-backed `emacsos-assist-mode'
buffer, or a canonical `emacsos-assist-web-mode' buffer for shared shell
utilities; the web client has its own transport and parser.  Return nil for
other buffers.  Uses `emacsos--target' (the authority on \"what's on top\"),
not `current-buffer' (safety-control renders can run with *keyboard* current)."
  (let* ((w (emacsos--target))
         (b (and w (window-buffer w))))
    (when (and b
               (or (eq b (get-buffer emacsos--chat-buffer-name))
                   (with-current-buffer b
                     (or (derived-mode-p 'emacsos-assist-mode)
                         (derived-mode-p 'emacsos-assist-web-mode)))))
      b)))

(defun emacsos--chat-on-top-p ()
  "Non-nil when a local, file-backed, or web Assist surface is on top."
  (and (emacsos--chat-surface-on-top) t))

(defun emacsos-conversation-primary-action ()
  "Send when idle, or abort/detach when this conversation owns the stream."
  (interactive)
  (if (emacsos-conversation-owns-active-stream-p (current-buffer))
      (emacsos-conversation-abort)
    (if emacsos-conversation-actions
        (emacsos-conversation-send)
      ;; The legacy scratch test surface may predate installation; its
      ;; transport remains the same local adapter.
      (emacsos--chat-send (current-buffer)))))

(defun emacsos-conversation-owns-active-stream-p (buffer)
  "Return non-nil only when BUFFER owns the phone-wide stream control."
  (and (buffer-live-p buffer)
       (with-current-buffer buffer
         (or (and emacsos--chat-in-flight
                  (eq emacsos--chat-stream-buffer buffer))
             (and (boundp 'emacsos-assist-web--in-flight)
                  emacsos-assist-web--in-flight
                  (eq emacsos--assist-active-surface buffer))))))

(defun emacsos--chat-button ()
  "Utility-row Chat/SEND/ABORT button for the active Assist surface."
  (interactive)
  (let ((surface (emacsos--chat-surface-on-top)))
    (if surface
        (with-current-buffer surface (emacsos-conversation-primary-action))
      (emacsos--chat-show-top-buffer))))

(defun emacsos--chat-button-label ()
  "Return the active conversation's truthful Chat/SEND/ABORT label."
  (if (not (emacsos--chat-on-top-p)) "Chat"
    (if (and (fboundp 'emacsos--target)
             (emacsos-conversation-owns-active-stream-p
              (emacsos--chat-surface-on-top)))
        "ABORT" "SEND")))

(provide 'chat)
;;; chat.el ends here
