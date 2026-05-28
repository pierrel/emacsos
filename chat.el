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
(require 'json)
(require 'url)
(require 'url-http)

;; Defined in os.el (which `require's this file); resolved at call time.
(declare-function emacos--target "os")
(declare-function emacos--render-page "os")

;;; Customization

(defcustom emacos-chat-server-url "http://localhost:8765/chat"
  "URL of the emacsos-server /chat endpoint."
  :type 'string
  :group 'emacsos)

(defcustom emacos-chat-auth-file (expand-file-name "~/.emacs.d/server/server")
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

(defcustom emacos-chat-first-token-timeout 30
  "Seconds to wait for the first stream event before reporting
\"no response from server\".  Replaces the old sync-call total
timeout (300s in the pre-streaming version).  No total-stream
timeout exists by design — once the stream starts, the user owns
the budget and can tap ABORT to cancel.  See design doc §6."
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

(defvar emacos--chat-in-flight nil
  "Non-nil while a stream is open.  Re-entrancy guard for SEND.")

(defvar emacos--chat-can-rollback nil
  "Non-nil when the last turn applied a config (an `applied' event
arrived), so the chat command list offers a ROLLBACK entry (at the
bottom).  Cleared on a successful rollback (v1 is one-level undo —
apply again to get a new rollback point).")

(defvar emacos--chat-confirm-pending nil
  "Non-nil when New chat has been tapped once and awaits a confirming
second tap — the button relabels to \"Confirm clear?\".  Cleared by the
confirming tap (`emacos--chat-new-chat'), or by tapping anything else
\(`emacos--maybe-cancel-confirm' in os.el), so the armed state can't
linger.  This tap-only guard replaced a minibuffer/GUI confirm that
fought the touchscreen.")

(defvar emacos--chat-process nil
  "The url-retrieve process backing the in-flight stream, or nil.
Used by ABORT to delete-process.")

(defvar emacos--chat-stream-insert-marker nil
  "Marker into the `*chat*' buffer positioned just before the prompt
at stream start.  Token events insert here.  Insertion-type t so it
moves forward as tokens are inserted.")

(defvar emacos--chat-status-start nil
  "Marker into the `*chat*' buffer: left edge of the status bracket
inside the in-progress bot line.  Insertion-type nil (anchored).")

(defvar emacos--chat-status-end nil
  "Marker into the `*chat*' buffer: right edge of the status bracket.
Insertion-type nil (stationary) so that token inserts at the same
position via `emacos--chat-stream-insert-marker' do NOT drag this
marker forward.  The handle-status path explicitly `set-marker's
this to (point) after inserting its bracket text, so the
stationary type doesn't lose tracking inside the bracket itself.")

(defvar emacos--chat-tokens-seen 0
  "Count of `token` events received this stream.  Used by the
first-token timer to decide whether to fire.")

(defvar emacos--chat-last-event-time nil
  "`float-time' of the most recent NDJSON event of any kind from
this stream.  Used by the watchdog to distinguish \"still
arriving\" from \"connection dead, no end event\".")

(defvar emacos--chat-first-token-timer nil
  "Timer that fires the no-response-from-server error if the
first event doesn't arrive within `emacos-chat-first-token-timeout`.")

(defvar emacos--chat-watchdog-timer nil
  "Repeating timer that detects connection-closed-but-stream-not-
cleaned-up.  Necessary because url-http kills its response buffer
on close, sometimes before our filter has parsed the final chunk
\(which may contain the end event).  Fires every 1s while a
stream is in flight; on dead process, synthesizes end (if tokens
were seen) or error (if not).")

(defvar-local emacos--chat-body-read-marker nil
  "Buffer-local cursor into the url response buffer marking the
boundary between bytes our NDJSON parser has consumed and bytes
url-http has appended but we haven't yet read.  Initialised on
the first `emacos--chat-drain-body' call against this buffer.
Insertion-type nil so url-http's filter appends BEYOND it
rather than pushing it forward.")

(defconst emacos--chat-prompt "\n> "
  "Marker between the transcript (read-only) and the editable input.")

(defconst emacos--chat-buffer-name "*chat*")

(defconst emacos--chat-bot-prefix "bot> ")

;; The chat stream engine is buffer-agnostic: handlers render into the
;; buffer that initiated the current stream, not the literal *chat*.  That
;; buffer is the *chat* scratch OR a file-backed `emacos-assist-mode' buffer.
;; The single server-wide stream lock means only one stream is ever in
;; flight, so this global safely names its target for the duration.
(defvar emacos--chat-stream-buffer nil
  "Buffer the in-flight stream renders into; set at SEND.  See above.")

;; Defined in emacos-assist.el (required by os.el alongside chat).  Resolved
;; at call time — chat.el is the generic engine; the .assist surface plugs in.
(declare-function emacos-assist--surface-context "emacos-assist")
(declare-function emacos-assist--save "emacos-assist")

(defun emacos--chat-render-buffer ()
  "The buffer the stream handlers render into: the active stream buffer if
set and live, else the *chat* buffer (creating it if needed).
The *chat* fallback is reached only with NO active stream (legacy path) or a
live target — the stream paths intercept a killed target first via
`emacos--chat-render-target-lost-p', so a dead .assist buffer never falls
through to *chat'."
  (or (and (buffer-live-p emacos--chat-stream-buffer) emacos--chat-stream-buffer)
      (emacos--chat-buffer)))

(defun emacos--chat-render-target-lost-p ()
  "Non-nil when a stream is in flight but the surface it renders into was
killed.  Falling back to *chat* then would leak this conversation's tokens
into the unrelated legacy buffer, so the stream paths abandon instead."
  (and emacos--chat-stream-buffer
       (not (buffer-live-p emacos--chat-stream-buffer))))

(defun emacos--chat-abandon-stream ()
  "Kill the in-flight URL process and tear down silently — used when the
originating .assist surface was killed mid-stream, so there is nowhere to
render the rest of the response (and nothing to error onto)."
  (when (and (processp emacos--chat-process)
             (process-live-p emacos--chat-process))
    (delete-process emacos--chat-process))
  (emacos--chat-stream-cleanup))

(defun emacos--chat-surface-context (buf)
  "Request context plist (:thread-id :workdir) for chat-surface BUF.
A `emacos-assist-mode' file buffer gets its per-file thread id (minted +
written into the file's header on first send) and the file's directory; the
plain *chat* buffer gets nil context (the legacy fixed conversation)."
  (if (and (buffer-live-p buf)
           (with-current-buffer buf (derived-mode-p 'emacos-assist-mode)))
      (with-current-buffer buf (emacos-assist--surface-context))
    nil))

(defun emacos--chat-save-surface (buf)
  "Persist BUF's transcript if it is a `emacos-assist-mode' file buffer
\(no-op for the ephemeral *chat*)."
  (when (and (buffer-live-p buf)
             (with-current-buffer buf (derived-mode-p 'emacos-assist-mode)))
    (with-current-buffer buf (emacos-assist--save))))

;;; Buffer + input region

(defun emacos--chat-buffer ()
  "Return the *chat* buffer, creating and initializing if absent."
  (let ((buf (get-buffer emacos--chat-buffer-name)))
    (unless buf
      (setq buf (get-buffer-create emacos--chat-buffer-name))
      (emacos--chat-init-buffer buf))
    buf))

(defun emacos--chat-init-buffer (buf)
  "Seed BUF with an empty read-only header and a fresh prompt.
Also clears `emacos--chat-can-rollback' so a fresh / CLEARed transcript
doesn't dangle a ROLLBACK button with no surrounding context."
  (setq emacos--chat-can-rollback nil)
  (with-current-buffer buf
    ;; Chat is prose, not code — render the transcript + input in the
    ;; proportional `variable-pitch' face (the keyboard stays monospace
    ;; in its own buffer).  The face family is set in the init snippet.
    (variable-pitch-mode 1)
    (let ((inhibit-read-only t))
      (erase-buffer)
      (emacos--chat-write-prompt))
    (goto-char (point-max))))

(defun emacos--chat-write-prompt ()
  "Insert the prompt and mark it read-only.  Point left after it."
  (let ((before (point)))
    (insert emacos--chat-prompt)
    (add-text-properties before (point)
                         '(read-only t front-sticky t rear-nonsticky t))))

(defun emacos--chat-input-start (buf)
  "Position immediately after the last `emacos--chat-prompt' in BUF."
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

;;; Stream handlers (called from the process filter, per NDJSON event)

(defun emacos--chat-handle-start (_event)
  "Open a new bot line in the *chat* buffer.  Sets up the three
markers (insert / status-start / status-end) used by subsequent
event handlers."
  (let ((buf (emacos--chat-render-buffer)))
    (with-current-buffer buf
      ;; Clear any stale per-stream first-token timer.
      (when (timerp emacos--chat-first-token-timer)
        (cancel-timer emacos--chat-first-token-timer)
        (setq emacos--chat-first-token-timer nil))
      ;; Insert "\nbot> " above the prompt, anchored by markers.
      (let* ((input-start (emacos--chat-input-start buf))
             (prompt-start (when input-start
                             (- input-start (length emacos--chat-prompt)))))
        (when prompt-start
          (let ((inhibit-read-only t))
            (save-excursion
              (goto-char prompt-start)
              ;; Insert "\nbot> " at the prompt's position.  The
              ;; existing prompt and input get pushed down.
              (let ((line-start (point)))
                (insert "\n" emacos--chat-bot-prefix)
                ;; Insert marker sits just after "bot> " — that's where
                ;; tokens and status both insert.  Marker insertion-type
                ;; t so it moves forward as content is added.
                (setq emacos--chat-stream-insert-marker
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
                (setq emacos--chat-status-start
                      (copy-marker (point) nil))
                (setq emacos--chat-status-end
                      (copy-marker (point) nil))
                ;; The "\nbot> " text we just inserted needs read-only
                ;; props applied (the per-token insertion path applies
                ;; props to each token).
                (add-text-properties line-start (point)
                                     '(read-only t front-sticky t rear-nonsticky t))))))))))

(defun emacos--chat-clear-status-bracket ()
  "Delete the status bracket between `status-start' and `status-end'.
Caller must `inhibit-read-only`."
  (when (and (markerp emacos--chat-status-start)
             (markerp emacos--chat-status-end)
             (< emacos--chat-status-start emacos--chat-status-end))
    (delete-region emacos--chat-status-start emacos--chat-status-end)
    ;; Both markers collapse onto the same position now.
    (set-marker emacos--chat-status-end emacos--chat-status-start)))

(defun emacos--chat-handle-status (event)
  "Replace the status bracket with `[<event.text>] '."
  (let ((text (plist-get event :text))
        (buf (emacos--chat-render-buffer)))
    (when (and text buf (buffer-live-p buf)
               (markerp emacos--chat-status-start))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (save-excursion
            (emacos--chat-clear-status-bracket)
            (goto-char emacos--chat-status-end)
            (let ((before (point)))
              (insert "[" text "] ")
              (add-text-properties before (point)
                                   '(read-only t front-sticky t rear-nonsticky t))
              (set-marker emacos--chat-status-end (point)))))))))

(defun emacos--chat-handle-token (event)
  "Append the token text after `status-end'.  First token also
clears any lingering status bracket (the agent is now talking, not
working silently)."
  (let ((text (plist-get event :text))
        (buf (emacos--chat-render-buffer)))
    (when (and text buf (buffer-live-p buf)
               (markerp emacos--chat-stream-insert-marker))
      (with-current-buffer buf
        (cl-incf emacos--chat-tokens-seen)
        (let ((inhibit-read-only t))
          (save-excursion
            (when (= emacos--chat-tokens-seen 1)
              (emacos--chat-clear-status-bracket))
            (goto-char emacos--chat-stream-insert-marker)
            (let ((before (point)))
              (insert text)
              (add-text-properties before (point)
                                   '(read-only t front-sticky t rear-nonsticky t))
              (set-marker emacos--chat-stream-insert-marker (point)))))))))

(defun emacos--chat-handle-heartbeat (_event)
  "Heartbeat is purely transport-level — no UI change."
  nil)

(defun emacos--chat-handle-end (_event)
  "Stream complete.  Clear status, release the in-flight lock,
release markers, re-render the page so CLEAR returns."
  (let ((buf (emacos--chat-render-buffer)))
    (when (and buf (buffer-live-p buf))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (emacos--chat-clear-status-bracket))))
    (emacos--chat-stream-cleanup)))

(defun emacos--chat-handle-error (event)
  "Render `[error: <reason>]' on the bot line and clean up.
If start has already run (markers present), insert at the marker.
Otherwise (error before any server response), synthesize a fresh
`\\nbot> [error: ...]' above the prompt so the user sees something."
  (let ((reason (or (plist-get event :reason) "unknown"))
        (buf (emacos--chat-render-buffer)))
    (when (and buf (buffer-live-p buf))
      (with-current-buffer buf
        (let ((inhibit-read-only t))
          (save-excursion
            (cond
             ;; Stream had a start: append to existing bot line.
             ((markerp emacos--chat-stream-insert-marker)
              (emacos--chat-clear-status-bracket)
              (goto-char emacos--chat-stream-insert-marker)
              (let ((before (point)))
                (insert "[error: " reason "]")
                (add-text-properties before (point)
                                     '(read-only t front-sticky t rear-nonsticky t))))
             ;; Error before any server response: render a fresh
             ;; bot line above the prompt directly.
             (t
              (let* ((input-start (emacos--chat-input-start buf))
                     (prompt-start (when input-start
                                     (- input-start (length emacos--chat-prompt)))))
                (when prompt-start
                  (goto-char prompt-start)
                  (let ((before (point)))
                    (insert "\n" emacos--chat-bot-prefix "[error: " reason "]")
                    (add-text-properties
                     before (point)
                     '(read-only t front-sticky t rear-nonsticky t)))))))))))
    (emacos--chat-stream-cleanup)))

(defun emacos--chat-note (text)
  "Insert TEXT as a read-only `bot> ' note line above the input prompt
in *chat*.  Used for applied / rollback notices (system messages, not
streamed bot output)."
  (let ((buf (emacos--chat-render-buffer)))
    (when (and buf (buffer-live-p buf))
      (with-current-buffer buf
        (let* ((inhibit-read-only t)
               (input-start (emacos--chat-input-start buf))
               (prompt-start (when input-start
                               (- input-start (length emacos--chat-prompt)))))
          (when prompt-start
            (save-excursion
              (goto-char prompt-start)
              (let ((before (point)))
                (insert "\n" emacos--chat-bot-prefix text)
                (add-text-properties before (point)
                                     '(read-only t front-sticky t rear-nonsticky t))))))))))

(defun emacos--chat-handle-applied (event)
  "Handle the `applied' event: the agent shipped a config to the phone.
Note it in the transcript and offer a ROLLBACK button.  `:broken' t
means it was committed but errored while loading (a JSON false parses
as the symbol `:false', so test for `t' explicitly)."
  (let ((detail (or (plist-get event :detail) "config applied"))
        (broken (eq (plist-get event :broken) t)))
    (emacos--chat-note
     (if broken
         (format "[applied but BROKEN — consider rolling back: %s]" detail)
       (format "[%s]" detail)))
    (setq emacos--chat-can-rollback t)
    (when (fboundp 'emacos--render-page)
      (emacos--render-page))))

(defun emacos--chat-stream-cleanup ()
  "Tear down per-stream state.  Idempotent: safe to call from any
of the terminal handlers (end, error, abort, watchdog)."
  (dolist (sym '(emacos--chat-first-token-timer
                 emacos--chat-watchdog-timer))
    (let ((tm (symbol-value sym)))
      (when (timerp tm) (cancel-timer tm)))
    (set sym nil))
  (dolist (sym '(emacos--chat-stream-insert-marker
                 emacos--chat-status-start
                 emacos--chat-status-end))
    (let ((m (symbol-value sym)))
      (when (markerp m) (set-marker m nil)))
    (set sym nil))
  ;; Persist a file-backed (.assist) surface's transcript on stream
  ;; end/error/abort, then drop the stream-buffer reference.
  (emacos--chat-save-surface emacos--chat-stream-buffer)
  (setq emacos--chat-stream-buffer nil)
  (setq emacos--chat-tokens-seen 0
        emacos--chat-last-event-time nil
        emacos--chat-in-flight nil
        emacos--chat-process nil)
  ;; Re-render the keyboard page so CLEAR returns + ABORT goes away.
  (when (fboundp 'emacos--render-page)
    (emacos--render-page)))

(defconst emacos--chat-watchdog-quiet-secs 5.0
  "Watchdog grace window — see `emacos--chat-watchdog-tick'.")

(defun emacos--chat-watchdog-tick ()
  "Detect connection-closed-but-stream-not-cleaned-up.

Known v1 limitation: url-http sometimes kills its response buffer
before our filter has drained the chunk containing the end event,
or url-http swaps sentinels mid-stream so our hook is detached.
Either way, `emacos--chat-in-flight' can stay t after the stream
naturally ends, leaving the UI stuck on ABORT.  This timer
notices.  The 5-second grace window after the last NDJSON event
is generous enough that fast-streaming runs always finish
gracefully via the real end event, and slow / no-end runs get
synthesized cleanup within ~5s of the real connection close."
  (when (and emacos--chat-in-flight
             (or (not (processp emacos--chat-process))
                 (not (process-live-p emacos--chat-process))))
    (when (and (processp emacos--chat-process)
               (buffer-live-p (process-buffer emacos--chat-process)))
      (with-current-buffer (process-buffer emacos--chat-process)
        (when (and (boundp 'url-http-end-of-headers)
                   url-http-end-of-headers)
          (emacos--chat-drain-body))))
    (let ((quiet-for (if emacos--chat-last-event-time
                         (- (float-time) emacos--chat-last-event-time)
                       0.0)))
      (when (>= quiet-for emacos--chat-watchdog-quiet-secs)
        (cond
         ((emacos--chat-render-target-lost-p) (emacos--chat-abandon-stream))
         ((> emacos--chat-tokens-seen 0) (emacos--chat-handle-end nil))
         (t (emacos--chat-handle-error
             (list :type "error"
                   :reason "connection closed without end event"))))))))

(defconst emacos--chat-event-handlers
  '(("start"     . emacos--chat-handle-start)
    ("token"     . emacos--chat-handle-token)
    ("status"    . emacos--chat-handle-status)
    ("end"       . emacos--chat-handle-end)
    ("error"     . emacos--chat-handle-error)
    ("applied"   . emacos--chat-handle-applied)
    ("heartbeat" . emacos--chat-handle-heartbeat)))

;;; HTTP request encoding

(defun emacos--chat-endpoint (path)
  "Return the server URL for PATH (e.g. \"/rollback\"), derived from
`emacos-chat-server-url' by swapping its path component.  Keeping one
configured base URL means /chat and /rollback can't drift to different
hosts."
  (let ((u (url-generic-parse-url emacos-chat-server-url)))
    (setf (url-filename u) path)
    (url-recreate-url u)))

(defun emacos--chat-read-auth-file ()
  "Return the auth file contents as a string, or nil if missing."
  (when (file-readable-p emacos-chat-auth-file)
    (with-temp-buffer
      (let ((coding-system-for-read 'no-conversion))
        (insert-file-contents-literally emacos-chat-auth-file))
      (buffer-string))))

(defun emacos--chat-encode-request (msg auth &optional thread-id workdir)
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

(defun emacos--chat-encode-rollback (auth)
  "Encode the /rollback request body as UTF-8 bytes: {phone:{auth_file}}
when AUTH is non-nil, else {}."
  (let* ((payload (if auth (list :phone (list :auth_file auth)) nil))
         (json-encoding-pretty-print nil)
         (body (json-encode (or payload (make-hash-table)))))
    (encode-coding-string body 'utf-8)))

;;; Process filter (NDJSON parser)

(defun emacos--chat-make-filter (url-filter)
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
    (let ((buf (process-buffer proc)))
      (when (and buf (buffer-live-p buf))
        (with-current-buffer buf
          (when (and (boundp 'url-http-end-of-headers)
                     url-http-end-of-headers)
            (emacos--chat-drain-body)))))))

;; Note: we used to wrap the process-sentinel for client-side
;; connection-lost detection, but url-http SWAPS its sentinel as the
;; connection state evolves (idle → async → end-of-document → ...).
;; A wrap captured at install time shadows later sentinels with
;; whichever one we caught first — request never gets written.
;; Cleanup paths today: stream events (server emits start/end/error)
;; or the first-token timeout.  Connection-lost-without-event is
;; therefore detected via the timeout, not the sentinel.

(defun emacos--chat-drain-body ()
  "Called inside the url process buffer with point/headers parsed.
Reads everything after `url-http-end-of-headers' that we haven't
seen yet, splits on \\n, dispatches each JSON line.  Idempotent —
tracks how much body has already been processed via a buffer-local
marker.  The marker has insertion-type nil (stationary on insert)
so it stays at the read/unread boundary as the URL filter
continues appending bytes after it."
  (unless (and (local-variable-p 'emacos--chat-body-read-marker)
               (markerp emacos--chat-body-read-marker))
    ;; url-http-end-of-headers is a marker pointing at the first
    ;; byte of the body (right after the \r\n\r\n separator).
    ;; Position our read-cursor there; nil insertion-type so url's
    ;; filter inserts BEYOND us rather than pushing us forward.
    (setq-local emacos--chat-body-read-marker
                (copy-marker (marker-position url-http-end-of-headers)
                             nil)))
  (let ((from (marker-position emacos--chat-body-read-marker))
        (to (point-max)))
    (when (< from to)
      (let* ((raw (buffer-substring-no-properties from to))
             (last-nl (cl-position ?\n raw :from-end t)))
        (when last-nl
          (let ((complete (substring raw 0 (1+ last-nl))))
            (set-marker emacos--chat-body-read-marker
                        (+ from (length complete)))
            (dolist (line (split-string complete "\n" t))
              (emacos--chat-dispatch-line line))))))))

(defun emacos--chat-dispatch-line (line)
  "Parse one NDJSON line as a JSON object, dispatch to handler.
Silently drops events that arrive after `emacos--chat-in-flight'
has cleared (eg. url-http drains buffered bytes after ABORT
deletes the process) so a late `start' can't resurrect bot
markers/lines after the UI has been cleaned up."
  (when emacos--chat-in-flight
    (if (emacos--chat-render-target-lost-p)
        (emacos--chat-abandon-stream)   ; surface killed mid-stream: bail
    (let ((event (condition-case _
                     (json-parse-string line
                                        :object-type 'plist
                                        :null-object nil
                                        :array-type 'list)
                   (error nil))))
      (when (and event (listp event))
        (setq emacos--chat-last-event-time (float-time))
        (let* ((etype (plist-get event :type))
               (handler (cdr (assoc etype emacos--chat-event-handlers))))
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
;; ABORT calls `emacos--chat-stream-cleanup' synchronously.

;;; SEND / CLEAR / ABORT

(defun emacos--chat-send (&optional surface)
  "Open a streaming request to /chat with SURFACE's current input.
SURFACE defaults to the *chat* buffer; a `emacos-assist-mode' file buffer
sends its per-file thread id + the file's directory so the server keys a
per-file conversation and operates on that directory."
  (interactive)
  (if emacos--chat-in-flight
      (message "chat: stream in flight; tap ABORT to cancel")
    (let* ((buf (or surface (emacos--chat-buffer)))
           (msg (emacos--chat-current-input buf))
           (ctx nil))
      (when (and msg (not (string-empty-p msg)))
        ;; Derive context only now that we're committing to a turn: for a
        ;; .assist surface this mints the thread id + writes the header, so an
        ;; empty-input tap must not reach it (it would dirty a fresh file).
        (setq ctx (emacos--chat-surface-context buf))
        (setq emacos--chat-in-flight t
              emacos--chat-tokens-seen 0
              emacos--chat-stream-buffer buf)
        ;; Render the you> line + clear input region right away;
        ;; the bot line is created by the start handler.
        (let ((inhibit-read-only t))
          (with-current-buffer buf
            (emacos--chat-clear-input buf)
            (let* ((input-start (emacos--chat-input-start buf))
                   (prompt-start (when input-start
                                   (- input-start (length emacos--chat-prompt)))))
              (when prompt-start
                (save-excursion
                  (goto-char prompt-start)
                  (let ((before (point)))
                    (insert "\nyou> " msg)
                    (add-text-properties before (point)
                                         '(read-only t front-sticky t rear-nonsticky t))))))))
        ;; Persist the you> turn before the request goes out (file-backed
        ;; .assist surfaces only; no-op for the ephemeral *chat*).
        (emacos--chat-save-surface buf)
        ;; First-token watchdog.  Fires once if no event lands
        ;; within the configured timeout AND we're still in flight.
        ;; Uses `emacos--chat-terminate-stream' so the URL process is
        ;; actually killed -- otherwise a late-arriving response would
        ;; keep delivering events into the just-cleaned-up UI.
        (setq emacos--chat-first-token-timer
              (run-with-timer
               emacos-chat-first-token-timeout nil
               (lambda ()
                 (when (and emacos--chat-in-flight
                            (= emacos--chat-tokens-seen 0))
                   (emacos--chat-terminate-stream
                    (format "no response from server after %ds"
                            emacos-chat-first-token-timeout))))))
        ;; Connection-close watchdog.  Polls every 1s; only fires
        ;; end/error when the process is dead AND at least
        ;; `emacos--chat-watchdog-quiet-secs' have passed since the
        ;; last NDJSON event (lets the filter drain the final chunk).
        (setq emacos--chat-last-event-time (float-time))
        (setq emacos--chat-watchdog-timer
              (run-with-timer 1 1 #'emacos--chat-watchdog-tick))
        ;; Fire the request.  `url-retrieve` returns a BUFFER (not a
        ;; process); the process is `get-buffer-process` on it.
        (condition-case err
            (let* ((auth (emacos--chat-read-auth-file))
                   (url-request-method "POST")
                   (url-request-extra-headers
                    '(("Content-Type" . "application/json; charset=utf-8")))
                   (url-request-data (emacos--chat-encode-request
                                      msg auth
                                      (plist-get ctx :thread-id)
                                      (plist-get ctx :workdir)))
                   ;; url-retrieve args: URL, CALLBACK, CBARGS, SILENT,
                   ;; INHIBIT-COOKIES.  (No TIMEOUT arg in Emacs >=24;
                   ;; we rely on `emacos--chat-first-token-timer' and
                   ;; the watchdog for cancellation instead.)
                   (response-buf (url-retrieve emacos-chat-server-url
                                               #'ignore nil
                                               t   ; SILENT
                                               t)) ; INHIBIT-COOKIES
                   (proc (and (buffer-live-p response-buf)
                              (get-buffer-process response-buf))))
              (unless proc
                (error "url-retrieve returned no live process for %s"
                       emacos-chat-server-url))
              (setq emacos--chat-process proc)
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
               proc (emacos--chat-make-filter (process-filter proc)))
              ;; Re-render the keyboard page so CLEAR -> ABORT.
              (when (fboundp 'emacos--render-page)
                (emacos--render-page)))
          (error
           (emacos--chat-handle-error
            (list :type "error"
                  :reason (format "url-retrieve failed: %s"
                                  (error-message-string err))))))))))

(defun emacos--chat-new-chat ()
  "Clear the conversation behind a TWO-TAP confirm.

The button lives on the always-present command list and is an easy
mis-tap, and the clear is irreversible (it wipes the conversation AND the
agent's working-dir memory).  So the FIRST tap only ARMS: the button
relabels to \"Confirm clear?\" (`emacos--chat-confirm-pending').  A SECOND
tap on it actually clears — POSTing /clear so the server forgets the
conversation, then resetting the local transcript.  Tapping ANYTHING ELSE
cancels the pending confirm (`emacos--maybe-cancel-confirm' in os.el), so
the armed state can't linger.  Tap-only — no minibuffer or GUI dialog,
both of which fought the touchscreen.

Refuses (without arming) while a stream is in flight — tap ABORT first.
The /clear POST is fire-and-forget: the local transcript clears regardless
of whether it succeeds.  This is the ONLY thing that makes the agent
forget; the conversation otherwise persists across turns and restarts."
  (interactive)
  (cond
   (emacos--chat-in-flight
    (message "chat: stream in flight; tap ABORT to cancel"))
   (emacos--chat-confirm-pending
    ;; Second tap: confirmed — clear for real.
    (setq emacos--chat-confirm-pending nil)
    (emacos--chat-forget-server)
    (emacos--chat-init-buffer (emacos--chat-buffer)))
   (t
    ;; First tap: arm, and re-render so the button relabels to
    ;; "Confirm clear?".
    (setq emacos--chat-confirm-pending t)
    (when (fboundp 'emacos--render-page) (emacos--render-page)))))

(defun emacos--chat-forget-server ()
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
        (url-retrieve (emacos--chat-endpoint "/clear")
                      #'emacos--chat-forget-callback nil t t)
      (error
       (message "chat: /clear failed: %s" (error-message-string err))))))

(defun emacos--chat-forget-callback (status &rest _)
  "Kill the /clear response buffer so repeated New-chat taps don't leak
` *http*' buffers; report a transport error via `message' if one
occurred.  Runs after the local reset, so it only reports."
  (let ((resp (current-buffer)))
    (when (plist-get status :error)
      (message "chat: /clear error: %S" (plist-get status :error)))
    (when (buffer-live-p resp) (kill-buffer resp))))

(defun emacos--chat-terminate-stream (reason)
  "Kill the in-flight stream's URL process (if any) and render
`[error: REASON]' on the bot line, then tear down per-stream
state.  Used by ABORT and by the first-token timeout so neither
leaves a half-killed stream that keeps delivering events into a
cleaned-up UI.  Safe no-op when no stream is in flight."
  (when emacos--chat-in-flight
    (when (and (processp emacos--chat-process)
               (process-live-p emacos--chat-process))
      (delete-process emacos--chat-process))
    (if (emacos--chat-render-target-lost-p)
        (emacos--chat-stream-cleanup)   ; nowhere to render the error
      (emacos--chat-handle-error
       (list :type "error" :reason reason)))))

(defun emacos--chat-abort ()
  "Cancel the in-flight stream.  Synchronously kills the URL process
and renders `[error: aborted]', so the UI returns to CLEAR
immediately without waiting for the watchdog.  We can't rely on
url-http's sentinel here -- it gets swapped mid-stream by the
url-http state machine, so any sentinel-driven cleanup is unreliable."
  (interactive)
  (emacos--chat-terminate-stream "aborted"))

;;; Command-list integration

(defun emacos--chat-command-set ()
  "Command-list entries for the *chat* buffer.  The first button is ABORT
while a stream is in flight; otherwise New chat — which relabels to
\"Confirm clear?\" once armed (`emacos--chat-confirm-pending', the two-tap
guard).  ROLLBACK sits at the very bottom, only after a config apply
(rarely used).  SEND is no longer here — it moved to the always-present
utility row's Chat/SEND button (`emacos--chat-button'), so the most-used
action is one tap away on every screen.  Plain (LABEL . CMD) conses;
dynamic — re-derived on every `emacos--render-page', so the first button
flips with `emacos--chat-in-flight' / the confirm state and ROLLBACK
appears/disappears with `emacos--chat-can-rollback'."
  (append
   (list (cond
          (emacos--chat-in-flight (cons "ABORT" #'emacos--chat-abort))
          (emacos--chat-confirm-pending
           (cons "Confirm clear?" #'emacos--chat-new-chat))
          (t (cons "New chat" #'emacos--chat-new-chat))))
   ;; ROLLBACK last — rarely used, and only available after an apply.
   (when emacos--chat-can-rollback
     (list (cons "ROLLBACK" #'emacos--chat-rollback)))))

;;; Rollback

(defun emacos--chat-rollback ()
  "Roll back the last applied config by POSTing /rollback.

ASYNC on purpose: the server's /rollback handler calls back INTO this
emacs (via emacsclient) to load the reverted config, so a synchronous
request would deadlock — this emacs would be blocked waiting for the
response it must itself service.  The result is reported in the
transcript by `emacos--chat-rollback-callback'."
  (interactive)
  (if emacos--chat-in-flight
      (message "chat: stream in flight; ABORT before rolling back")
    (let* ((auth (emacos--chat-read-auth-file))
           (url-request-method "POST")
           (url-request-extra-headers
            '(("Content-Type" . "application/json; charset=utf-8")))
           (url-request-data (emacos--chat-encode-rollback auth)))
      (emacos--chat-note "[rolling back…]")
      (condition-case err
          (url-retrieve (emacos--chat-endpoint "/rollback")
                        #'emacos--chat-rollback-callback nil t t)
        (error
         (emacos--chat-note
          (format "[rollback failed: %s]" (error-message-string err))))))))

(defun emacos--chat-rollback-callback (status &rest _)
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
          (emacos--chat-note (format "[rollback %s: %s]" st detail))
          ;; A reached rollback (applied / load_error) consumes the undo;
          ;; hide ROLLBACK until the next apply.  noop/unreachable/error
          ;; keep it available to retry.
          (when (member st '("applied" "load_error"))
            (setq emacos--chat-can-rollback nil))
          (when (fboundp 'emacos--render-page)
            (emacos--render-page)))
      (when (buffer-live-p resp) (kill-buffer resp)))))

(defun emacos--chat-show-top-buffer ()
  "Display *chat* in the editor (target) window.  Idempotent.
Interactive so M-x can reach it; the Chat utility button reaches it via
`emacos--chat-button' when *chat* isn't already on top."
  (interactive)
  (let ((buf (emacos--chat-buffer))
        (w (emacos--target)))
    (when (and w (not (eq (window-buffer w) buf)))
      (set-window-buffer w buf))))

(defun emacos--chat-surface-on-top ()
  "Return the chat-surface buffer in the target (editor) window — the *chat*
scratch OR a file-backed `emacos-assist-mode' buffer — else nil.  Uses
`emacos--target' (the authority on \"what's on top\"), not `current-buffer'
\(renders/callbacks run with *keyboard* current), so it agrees with
`emacos--top-commands'."
  (let* ((w (emacos--target))
         (b (and w (window-buffer w))))
    (when (and b
               (or (eq b (get-buffer emacos--chat-buffer-name))
                   (with-current-buffer b (derived-mode-p 'emacos-assist-mode))))
      b)))

(defun emacos--chat-on-top-p ()
  "Non-nil when a chat surface (*chat* or a .assist buffer) is on top."
  (and (emacos--chat-surface-on-top) t))

(defun emacos--chat-button ()
  "Utility-row Chat/SEND button: SEND when *chat* is already on top, else
open *chat*.  The always-present third utility button doubles as the
home-app affordance (open chat) and — once you're in chat — the
most-used action (send).  While a stream is in flight, `emacos--chat-send'
refuses with a hint and the command list shows ABORT."
  (interactive)
  (let ((surface (emacos--chat-surface-on-top)))
    (if surface
        (emacos--chat-send surface)
      (emacos--chat-show-top-buffer))))

(defun emacos--chat-button-label ()
  "Label for the utility-row Chat/SEND button: \"SEND\" when *chat* is on
top (the button sends), else \"Chat\" (it opens chat)."
  (if (emacos--chat-on-top-p) "SEND" "Chat"))

(provide 'chat)
;;; chat.el ends here
