;;; test-chat.el --- Tests for chat.el streaming surface -*- lexical-binding: t -*-

(require 'ert)
(require 'cl-lib)
(require 'chat)

;;; Helpers

(defun chat-test--reset ()
  "Tear down state between tests."
  (when (get-buffer emacos--chat-buffer-name)
    (let ((kill-buffer-query-functions nil))
      (kill-buffer emacos--chat-buffer-name)))
  (setq emacos--chat-in-flight nil
        emacos--assist-active-surface nil
        emacos--chat-confirm-pending nil
        emacos--chat-rollback-pending nil
        emacos--chat-process nil
        emacos--chat-stream-insert-marker nil
        emacos--chat-status-start nil
        emacos--chat-status-end nil
        emacos--chat-tokens-seen 0)
  (dolist (sym '(emacos--chat-first-token-timer
                 emacos--chat-watchdog-timer))
    (let ((tm (symbol-value sym)))
      (when (timerp tm) (cancel-timer tm)))
    (set sym nil)))

(defun chat-test--seed-you-line (buf msg)
  "Simulate emacos--chat-send having just inserted the you> line.
Sets up the buffer so handlers operate against a realistic state."
  (with-current-buffer buf
    (emacos--chat-clear-input buf)
    (let* ((input-start (emacos--chat-input-start buf))
           (prompt-start (when input-start
                           (- input-start (length emacos--chat-prompt)))))
      (when prompt-start
        (let ((inhibit-read-only t))
          (save-excursion
            (goto-char prompt-start)
            (let ((before (point)))
              (insert "\nyou> " msg)
              (add-text-properties
               before (point)
               '(read-only t front-sticky t rear-nonsticky t)))))))))

;;; Buffer + input region

(ert-deftest chat-test-buffer-initializes-with-prompt ()
  (chat-test--reset)
  (let ((buf (emacos--chat-buffer)))
    (with-current-buffer buf
      (should (equal (buffer-substring-no-properties (point-min) (point-max))
                     emacos--chat-prompt))
      (should (= (point) (point-max))))))

(ert-deftest chat-test-current-input-after-prompt ()
  (chat-test--reset)
  (let ((buf (emacos--chat-buffer)))
    (with-current-buffer buf
      (goto-char (point-max))
      (insert "hi"))
    (should (equal (emacos--chat-current-input buf) "hi"))))

(ert-deftest chat-test-transcript-read-only ()
  (chat-test--reset)
  (let ((buf (emacos--chat-buffer)))
    (with-current-buffer buf
      (goto-char (1+ (point-min)))
      (should-error (delete-char -1) :type 'text-read-only))))

(ert-deftest chat-test-input-region-editable ()
  (chat-test--reset)
  (let ((buf (emacos--chat-buffer)))
    (with-current-buffer buf
      (goto-char (point-max))
      (insert "x")
      (should (equal (buffer-substring-no-properties (1- (point-max)) (point-max))
                     "x")))))

;;; Stream handlers (independent of network)

(ert-deftest chat-test-start-handler-creates-bot-line-and-markers ()
  "After `handle-start`, the buffer has a `\\nbot> ` line above
the prompt and the three markers are set."
  (chat-test--reset)
  (let ((buf (emacos--chat-buffer)))
    (chat-test--seed-you-line buf "hi")
    (emacos--chat-handle-start '(:type "start"))
    (with-current-buffer buf
      (should (string-match-p "\nbot> " (buffer-string)))
      (should (markerp emacos--chat-stream-insert-marker))
      (should (markerp emacos--chat-status-start))
      (should (markerp emacos--chat-status-end)))))

(ert-deftest chat-test-token-handler-inserts-content ()
  (chat-test--reset)
  (let ((buf (emacos--chat-buffer)))
    (chat-test--seed-you-line buf "hi")
    (emacos--chat-handle-start '(:type "start"))
    (emacos--chat-handle-token '(:type "token" :text "Hello "))
    (emacos--chat-handle-token '(:type "token" :text "world!"))
    (with-current-buffer buf
      (should (string-match-p "bot> Hello world!" (buffer-string))))))

(ert-deftest chat-test-status-then-first-token-clears-bracket ()
  "Status renders as `[<text>] `; first token clears the bracket."
  (chat-test--reset)
  (let ((buf (emacos--chat-buffer)))
    (chat-test--seed-you-line buf "hi")
    (emacos--chat-handle-start '(:type "start"))
    (emacos--chat-handle-status '(:type "status" :text "calling task"))
    (with-current-buffer buf
      (should (string-match-p "bot> \\[calling task\\] " (buffer-string))))
    (emacos--chat-handle-token '(:type "token" :text "Done."))
    (with-current-buffer buf
      (should-not (string-match-p "\\[calling task\\]" (buffer-string)))
      (should (string-match-p "bot> Done\\." (buffer-string))))))

(ert-deftest chat-test-status-replacement-handles-read-only ()
  "Each new status replaces the previous bracket; read-only props
on the prior bracket must not block the replacement."
  (chat-test--reset)
  (let ((buf (emacos--chat-buffer)))
    (chat-test--seed-you-line buf "hi")
    (emacos--chat-handle-start '(:type "start"))
    (emacos--chat-handle-status '(:type "status" :text "first"))
    (emacos--chat-handle-status '(:type "status" :text "second"))
    (with-current-buffer buf
      (should (string-match-p "\\[second\\]" (buffer-string)))
      (should-not (string-match-p "\\[first\\]" (buffer-string))))))

(ert-deftest chat-test-status-after-tokens-preserves-tokens ()
  "Status arriving AFTER tokens have streamed must replace its own
bracket only — not delete the streamed content.  Pins the marker
type-nil contract: if `status-end' moved forward with token inserts,
the next status's clear-bracket would wipe out streamed tokens."
  (chat-test--reset)
  (let ((buf (emacos--chat-buffer)))
    (chat-test--seed-you-line buf "hi")
    (emacos--chat-handle-start '(:type "start"))
    (emacos--chat-handle-status '(:type "status" :text "one"))
    (emacos--chat-handle-token '(:type "token" :text "Hello "))
    (emacos--chat-handle-token '(:type "token" :text "world!"))
    (emacos--chat-handle-status '(:type "status" :text "two"))
    (with-current-buffer buf
      (should (string-match-p "\\[two\\]" (buffer-string)))
      (should (string-match-p "Hello world!" (buffer-string)))
      (should-not (string-match-p "\\[one\\]" (buffer-string))))))

(ert-deftest chat-test-end-handler-resets-state ()
  (chat-test--reset)
  (setq emacos--chat-in-flight t)
  (let ((buf (emacos--chat-buffer)))
    (chat-test--seed-you-line buf "hi")
    (emacos--chat-handle-start '(:type "start"))
    (emacos--chat-handle-token '(:type "token" :text "ok"))
    (emacos--chat-handle-end '(:type "end"))
    (should-not emacos--chat-in-flight)
    (should-not emacos--chat-stream-insert-marker)))

(ert-deftest chat-test-error-handler-appends-error-line ()
  (chat-test--reset)
  (setq emacos--chat-in-flight t)
  (let ((buf (emacos--chat-buffer)))
    (chat-test--seed-you-line buf "hi")
    (emacos--chat-handle-start '(:type "start"))
    (emacos--chat-handle-error '(:type "error" :reason "boom"))
    (with-current-buffer buf
      (should (string-match-p "\\[error: boom\\]" (buffer-string))))
    (should-not emacos--chat-in-flight)))

(ert-deftest chat-test-heartbeat-is-noop ()
  (chat-test--reset)
  ;; Should not change buffer or any state when called.
  (let ((buf (emacos--chat-buffer)))
    (let ((before (with-current-buffer buf (buffer-string))))
      (emacos--chat-handle-heartbeat '(:type "heartbeat"))
      (should (equal (with-current-buffer buf (buffer-string)) before)))))

;;; NDJSON line dispatch

(ert-deftest chat-test-dispatch-line-routes-by-type ()
  "Parse one NDJSON line; the correct handler should fire."
  (chat-test--reset)
  (setq emacos--chat-in-flight t)
  (let ((seen nil))
    (cl-letf (((symbol-function 'emacos--chat-handle-token)
               (lambda (event) (setq seen event))))
      (emacos--chat-dispatch-line "{\"type\":\"token\",\"text\":\"hi\"}")
      (should (equal (plist-get seen :type) "token"))
      (should (equal (plist-get seen :text) "hi")))))

(ert-deftest chat-test-dispatch-line-ignores-malformed-json ()
  (chat-test--reset)
  (setq emacos--chat-in-flight t)
  (let ((called nil))
    (cl-letf (((symbol-function 'emacos--chat-handle-token)
               (lambda (_) (setq called t))))
      ;; Should not raise; should not invoke handler.
      (emacos--chat-dispatch-line "this is not json")
      (should-not called))))

(ert-deftest chat-test-dispatch-line-ignores-unknown-type ()
  (chat-test--reset)
  (setq emacos--chat-in-flight t)
  ;; Unknown type => no handler => no error.
  (emacos--chat-dispatch-line "{\"type\":\"unknown_kind\",\"x\":1}"))

(ert-deftest chat-test-dispatch-line-drops-events-when-not-in-flight ()
  "Late bytes (eg. url-http drained after ABORT) must not be dispatched."
  (chat-test--reset)
  (setq emacos--chat-in-flight nil)
  (let ((called nil))
    (cl-letf (((symbol-function 'emacos--chat-handle-token)
               (lambda (_) (setq called t))))
      (emacos--chat-dispatch-line "{\"type\":\"token\",\"text\":\"hi\"}")
      (should-not called))))

(ert-deftest chat-test-dispatch-line-abandons-when-stream-buffer-killed ()
  "If the .assist surface is killed mid-stream, events must NOT fall back to
*chat* — the stream is abandoned (state torn down, *chat* never created)."
  (chat-test--reset)
  (let ((dead (generate-new-buffer "doomed.assist")))
    (let ((kill-buffer-query-functions nil)) (kill-buffer dead))  ; now dead
    (setq emacos--chat-in-flight t
          emacos--chat-stream-buffer dead)
    (let ((rendered nil))
      (cl-letf (((symbol-function 'emacos--chat-handle-token)
                 (lambda (_) (setq rendered t))))
        (emacos--chat-dispatch-line "{\"type\":\"token\",\"text\":\"hi\"}")
        (should-not rendered)                ; nothing leaked into a render target
        (should-not emacos--chat-in-flight)  ; stream abandoned
        (should-not (get-buffer emacos--chat-buffer-name)))))) ; *chat* not created

(ert-deftest chat-test-send-save-failure-tears-down-not-strands ()
  "A pre-POST transcript save failure must surface an error + tear the
stream down (the save is inside the request's error guard), not strand the
UI in the in-flight/ABORT state with no process to clean it up."
  (chat-test--reset)
  (let ((buf (get-buffer-create emacos--chat-buffer-name)))
    (emacos--chat-init-buffer buf)
    (with-current-buffer buf (goto-char (point-max)) (insert "hello"))
    (cl-letf (((symbol-function 'emacos--chat-save-surface)
               (lambda (_buf) (error "disk full")))
              ((symbol-function 'emacos--chat-read-auth-file)
               (lambda () nil))
              ;; The save throws before url-retrieve; assert we never reach it.
              ((symbol-function 'url-retrieve)
               (lambda (&rest _) (error "url-retrieve must not be reached"))))
      (emacos--chat-send buf)
      (should-not emacos--chat-in-flight)        ; cleaned up, not stranded
      (should (string-match-p "disk full"
                              (with-current-buffer buf (buffer-string)))))))

(ert-deftest chat-test-send-does-not-overlap-an-assist-web-request ()
  "The local chat and canonical Web client share one phone request slot."
  (chat-test--reset)
  (let ((buf (get-buffer-create emacos--chat-buffer-name)) requested)
    (emacos--chat-init-buffer buf)
    (with-current-buffer buf (goto-char (point-max)) (insert "hello"))
    (setq emacos--assist-active-surface (generate-new-buffer " *web-owner*"))
    (unwind-protect
        (cl-letf (((symbol-function 'url-retrieve)
                   (lambda (&rest _) (setq requested t))))
          (emacos--chat-send buf)
          (should-not requested)
          (should-not emacos--chat-in-flight))
      (kill-buffer emacos--assist-active-surface)
      (setq emacos--assist-active-surface nil))))

(ert-deftest chat-test-rollback-note-targets-chat-not-active-stream ()
  "An async /rollback result must land in *chat* (the legacy config flow),
not in a .assist stream the user started before the callback returned."
  (chat-test--reset)
  (let ((chat (emacos--chat-buffer))            ; *chat*, initialized w/ prompt
        (assist (generate-new-buffer "x.assist")))
    (unwind-protect
        (progn
          (with-current-buffer assist (emacos--chat-write-prompt))
          (setq emacos--chat-stream-buffer assist) ; pretend it's the live target
          (let ((resp (generate-new-buffer " *rollback-resp*")))
            (with-current-buffer resp
              (insert "HTTP/1.1 200 OK\n\n{\"status\":\"applied\",\"detail\":\"ok\"}")
              (goto-char (point-min))
              (emacos--chat-rollback-callback nil)))  ; kills resp internally
          (should (string-match-p "rollback applied"
                                  (with-current-buffer chat (buffer-string))))
          (should-not (string-match-p "rollback"
                                      (with-current-buffer assist (buffer-string)))))
      (when (buffer-live-p assist)
        (let ((kill-buffer-query-functions nil)) (kill-buffer assist)))
      (setq emacos--chat-stream-buffer nil))))

;;; Request encoding (wire shape contract)

(defun chat-test--decode-utf8-json (bytes)
  "Decode the UTF-8 bytes BYTES into a JSON plist."
  (let ((s (decode-coding-string bytes 'utf-8)))
    (json-parse-string s :object-type 'plist :null-object nil :array-type 'list)))

(ert-deftest chat-test-encode-request-includes-phone-when-auth-present ()
  "AUTH non-nil → payload has {message, phone:{auth_file}}."
  (let* ((bytes (emacos--chat-encode-request "hi" "127.0.0.1:1234\nsecret\n"))
         (obj (chat-test--decode-utf8-json bytes)))
    (should (equal (plist-get obj :message) "hi"))
    (should (plist-member obj :phone))
    (should (equal (plist-get (plist-get obj :phone) :auth_file)
                   "127.0.0.1:1234\nsecret\n"))))

(ert-deftest chat-test-encode-request-omits-phone-when-no-auth ()
  "AUTH nil → payload omits the `phone' key entirely (not present as null)."
  (let* ((bytes (emacos--chat-encode-request "hi" nil))
         (obj (chat-test--decode-utf8-json bytes)))
    (should (equal (plist-get obj :message) "hi"))
    (should-not (plist-member obj :phone))))

;;; ABORT

(ert-deftest chat-test-abort-deletes-process ()
  (chat-test--reset)
  (setq emacos--chat-in-flight t)
  (let ((delete-called nil))
    (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
              ((symbol-function 'processp) (lambda (_) t))
              ((symbol-function 'delete-process)
               (lambda (_) (setq delete-called t))))
      (setq emacos--chat-process 'fake-proc)
      (emacos--chat-abort)
      (should delete-called))))

(ert-deftest chat-test-abort-clears-in-flight-immediately ()
  "ABORT must reset `emacos--chat-in-flight' synchronously, without
waiting for the watchdog timer.  Renders `[error: aborted]' on the
bot line if a stream was open (start handler had run)."
  (chat-test--reset)
  (setq emacos--chat-in-flight t)
  (let ((buf (emacos--chat-buffer)))
    (chat-test--seed-you-line buf "hi")
    (emacos--chat-handle-start '(:type "start"))
    (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
              ((symbol-function 'processp) (lambda (_) t))
              ((symbol-function 'delete-process) (lambda (_) nil)))
      (setq emacos--chat-process 'fake-proc)
      (emacos--chat-abort))
    (should-not emacos--chat-in-flight)
    (with-current-buffer buf
      (should (string-match-p "\\[error: aborted\\]" (buffer-string))))))

(ert-deftest chat-test-abort-noop-when-not-in-flight ()
  (chat-test--reset)
  (setq emacos--chat-in-flight nil)
  (let ((delete-called nil))
    (cl-letf (((symbol-function 'delete-process)
               (lambda (_) (setq delete-called t))))
      (setq emacos--chat-process 'fake-proc)
      (emacos--chat-abort)
      (should-not delete-called))))

(ert-deftest chat-test-old-process-filter-cannot-dispatch-into-a-new-request ()
  (chat-test--reset)
  (let ((emacos--chat-process 'new-process)
        raw-filter-called drained)
    (cl-letf (((symbol-function 'emacos--chat-drain-body)
               (lambda () (setq drained t))))
      (funcall (emacos--chat-make-filter
                (lambda (_proc _bytes) (setq raw-filter-called t)))
               'old-process "late bytes"))
    (should raw-filter-called)
    (should-not drained)))

;;; Chat/SEND utility button (emacos--chat-button)

(ert-deftest chat-test-button-sends-when-chat-on-top ()
  "The utility Chat/SEND button SENDs when *chat* is the top buffer."
  (chat-test--reset)
  (let ((fired nil))
    (cl-letf (((symbol-function 'emacos--chat-surface-on-top)
               (lambda () (current-buffer)))
              ((symbol-function 'emacos--chat-send)
               (lambda (&optional _s) (setq fired 'send)))
              ((symbol-function 'emacos--chat-show-top-buffer)
               (lambda () (setq fired 'open))))
      (emacos--chat-button))
    (should (eq fired 'send))))

(ert-deftest chat-test-button-opens-chat-when-elsewhere ()
  "The utility Chat/SEND button OPENS chat when *chat* isn't on top."
  (chat-test--reset)
  (let ((fired nil))
    (cl-letf (((symbol-function 'emacos--chat-surface-on-top) (lambda () nil))
              ((symbol-function 'emacos--chat-send)
               (lambda (&optional _s) (setq fired 'send)))
              ((symbol-function 'emacos--chat-show-top-buffer)
               (lambda () (setq fired 'open))))
      (emacos--chat-button))
    (should (eq fired 'open))))

(ert-deftest chat-test-button-label-flips-with-chat-on-top ()
  "Label is SEND when *chat* is on top (button sends), Chat otherwise."
  (cl-letf (((symbol-function 'emacos--chat-on-top-p) (lambda () t)))
    (should (equal (emacos--chat-button-label) "SEND")))
  (cl-letf (((symbol-function 'emacos--chat-on-top-p) (lambda () nil)))
    (should (equal (emacos--chat-button-label) "Chat"))))

(ert-deftest chat-test-button-label-and-action-follow-the-displayed-owner ()
  "A keyboard-buffer current-buffer must not make another surface show SEND."
  (let ((owner (generate-new-buffer " *assist-web-owner*")) fired)
    (unwind-protect
        (progn
          (with-current-buffer owner
            (emacos-conversation-install-actions
             '((send . ignore) (abort . emacos-assist-web-abort)))
            (setq-local emacos-assist-web--in-flight t))
          (let ((emacos--assist-active-surface owner))
            (with-temp-buffer
              (cl-letf (((symbol-function 'emacos--chat-surface-on-top) (lambda () owner))
                        ((symbol-function 'emacos--chat-on-top-p) (lambda () t))
                        ((symbol-function 'emacos-assist-web-abort)
                         (lambda () (interactive) (setq fired (current-buffer)))))
                (should (equal (emacos--chat-button-label) "ABORT"))
                (emacos--chat-button)
                (should (eq fired owner))))))
      (when (buffer-live-p owner) (kill-buffer owner)))))

(ert-deftest chat-test-object-mouse-activation-uses-the-event-position ()
  "Mouse activation resolves the clicked object's URL, not stale point."
  (with-temp-buffer
    (insert "one two")
    (put-text-property 5 8 'emacos-conversation-url "https://example.test/two")
    (let (opened)
      (goto-char 1)
      (cl-letf (((symbol-function 'mouse-event-p) (lambda (_event) t))
                ((symbol-function 'mouse-set-point) (lambda (_event) (goto-char 5)))
                ((symbol-function 'browse-url) (lambda (url &rest _) (setq opened url))))
        (emacos-conversation-open-object 'fake-mouse))
      (should (equal opened "https://example.test/two")))))

(ert-deftest chat-test-physical-ret-in-plain-chat-remains-newline-without-an-object ()
  (chat-test--reset)
  (let ((buffer (emacos--chat-buffer)))
    (with-current-buffer buffer
      (goto-char (point-max))
      (call-interactively (lookup-key (current-local-map) (kbd "RET")))
      (should (string-suffix-p "\n" (buffer-string))))))

(ert-deftest chat-test-shared-marker-kernel-keeps-provisional-body-read-only ()
  "Both transport adapters rely on these marker operations for transcript text."
  (with-temp-buffer
    (insert "you> hello\nbot> ")
    (let* ((body-start (point))
           (markers (emacos-conversation-begin-assistant body-start body-start))
           (start (car markers))
           (end (cdr markers)))
      (emacos-conversation-commit-user (point-min) (+ (point-min) 5) body-start)
      (set-marker end
                  (emacos-conversation-replace-marked start end "[queued]\n"))
      (set-marker end (emacos-conversation-set-status start end "queued"))
      (set-marker end (emacos-conversation-reset-assistant start end))
      (set-marker end (emacos-conversation-append-delta end "answer"))
      (emacos-conversation-finish-assistant start end)
      (set-marker end (emacos-conversation-fail-assistant start end "unverified"))
      (should (equal (buffer-substring-no-properties start end) "[unverified]"))
      (should (get-text-property start 'read-only)))))

(ert-deftest chat-test-switch-shows-top-buffer ()
  (chat-test--reset)
  (let ((scratch (get-buffer-create "*scratch*")))
    (with-temp-buffer
      (let ((w (selected-window)))
        (set-window-buffer w scratch)
        (cl-letf (((symbol-function 'emacos--target) (lambda () w)))
          (emacos--chat-show-top-buffer)
          (should (eq (window-buffer w)
                      (get-buffer emacos--chat-buffer-name))))))))

;;; Rollback command

(ert-deftest chat-test-endpoint-derives-rollback-url ()
  "The /rollback URL is derived from the configured /chat URL so they
share one host:port."
  (let ((emacos-chat-server-url "http://10.0.0.5:8765/chat"))
    (should (equal (emacos--chat-endpoint "/rollback")
                   "http://10.0.0.5:8765/rollback"))))


(ert-deftest chat-test-encode-rollback-with-and-without-auth ()
  (let ((with-auth (decode-coding-string
                    (emacos--chat-encode-rollback "host:1 2\nsec\n") 'utf-8))
        (no-auth (decode-coding-string
                  (emacos--chat-encode-rollback nil) 'utf-8)))
    (should (string-match-p "\"auth_file\"" with-auth))
    (should (equal no-auth "{}"))))


(ert-deftest chat-test-applied-event-notes-success ()
  (chat-test--reset)
  (emacos--chat-buffer)  ; init so the note has a prompt to insert above
  (emacos--chat-handle-applied
   (list :type "applied" :detail "blue cursor (vabc123)" :broken :false))
  (with-current-buffer emacos--chat-buffer-name
    (should (string-match-p "blue cursor" (buffer-string)))
    ;; A non-broken apply must NOT be flagged BROKEN (JSON false parses
    ;; to the symbol :false, which is truthy in elisp — regression guard).
    (should-not (string-match-p "BROKEN" (buffer-string)))))


(ert-deftest chat-test-applied-broken-event-warns ()
  (chat-test--reset)
  (emacos--chat-buffer)
  (emacos--chat-handle-applied
   (list :type "applied" :detail "x (vabc123)" :broken t))
  (with-current-buffer emacos--chat-buffer-name
    (should (string-match-p "BROKEN" (buffer-string)))
    (should (string-match-p "inspect failure" (buffer-string)))
    (should-not (string-match-p "consider rolling back" (buffer-string)))))


(ert-deftest chat-test-rollback-first-tap-arms ()
  "First rollback invocation only arms confirmation; it must not POST."
  (chat-test--reset)
  (emacos--chat-buffer)
  (let ((posted nil))
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (&rest _) (setq posted t) nil)))
      (emacos--chat-rollback))
    (should emacos--chat-rollback-pending)
    (should-not posted)))

(ert-deftest chat-test-rollback-second-tap-posts-and-disarms ()
  "Armed, a second rollback invocation POSTs and disarms."
  (chat-test--reset)
  (emacos--chat-buffer)
  (setq emacos--chat-rollback-pending t)  ; armed → this invocation fires
  (let ((posted-url nil)
        (emacos-chat-server-url "http://10.0.0.5:8765/chat"))
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (url &rest _) (setq posted-url url) nil)))
      (emacos--chat-rollback))
    (should (and posted-url (string-suffix-p "/rollback" posted-url)))
    (should-not emacos--chat-rollback-pending)))

(ert-deftest chat-test-rollback-refuses-in-flight ()
  "Rollback during a stream neither arms nor POSTs."
  (chat-test--reset)
  (emacos--chat-buffer)
  (setq emacos--chat-in-flight t)
  (let ((posted nil))
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (&rest _) (setq posted t) nil)))
      (emacos--chat-rollback))
    (should-not posted)
    (should-not emacos--chat-rollback-pending)))

(ert-deftest chat-test-rollback-disarmed-by-other-tap ()
  "Another EmacsOS button action disarms pending rollback."
  (chat-test--reset)
  (emacos--chat-buffer)
  (setq emacos--chat-rollback-pending t)
  (emacos--chat-maybe-disarm-confirm #'emacos--run-command #'emacos--chat-new-chat)
  (should-not emacos--chat-rollback-pending))

(ert-deftest chat-test-rollback-arming-reset-by-new-apply ()
  "A new apply clears stale pending rollback confirmation."
  (chat-test--reset)
  (emacos--chat-buffer)
  (setq emacos--chat-rollback-pending t)
  (emacos--chat-handle-applied '(:detail "applied: set x" :broken nil))
  (should-not emacos--chat-rollback-pending))

(ert-deftest chat-test-new-chat-first-tap-arms ()
  "First invocation only arms; it must not clear or POST anything yet."
  (chat-test--reset)
  (emacos--chat-buffer)
  (let ((forgot nil)
        (reinit nil))
    (cl-letf (((symbol-function 'emacos--chat-forget-server)
               (lambda () (setq forgot t)))
              ((symbol-function 'emacos--chat-init-buffer)
               (lambda (&rest _) (setq reinit t))))
      (emacos--chat-new-chat))
    (should emacos--chat-confirm-pending)
    (should-not forgot)
    (should-not reinit)))

(ert-deftest chat-test-new-chat-second-tap-confirms ()
  "Armed, a second invocation clears for real (forget + reset transcript) and
disarms."
  (chat-test--reset)
  (emacos--chat-buffer)
  (setq emacos--chat-confirm-pending t)
  (let ((forgot nil)
        (reinit nil))
    (cl-letf (((symbol-function 'emacos--chat-forget-server)
               (lambda () (setq forgot t)))
              ((symbol-function 'emacos--chat-init-buffer)
               (lambda (&rest _) (setq reinit t))))
      (emacos--chat-new-chat))
    (should-not emacos--chat-confirm-pending)
    (should forgot)
    (should reinit)))

(ert-deftest chat-test-new-chat-resets-rollback-confirmation ()
  "Confirming New chat clears a pending rollback confirmation."
  (chat-test--reset)
  (emacos--chat-buffer)
  (setq emacos--chat-rollback-pending t
        emacos--chat-confirm-pending t)   ; armed → this invocation confirms
  (cl-letf (((symbol-function 'emacos--chat-forget-server) #'ignore))
    (emacos--chat-new-chat))
  (should-not emacos--chat-rollback-pending))

(ert-deftest chat-test-new-chat-posts-to-clear-endpoint ()
  "The confirming invocation POSTs to the server's /clear endpoint (so the
agent forgets the conversation), and clears the transcript regardless."
  (chat-test--reset)
  (emacos--chat-buffer)
  (setq emacos--chat-confirm-pending t)   ; armed → this invocation confirms
  (let ((emacos-chat-server-url "http://10.0.0.5:8765/chat")
        (posted '())
        (resp nil)
        (body nil))
    (cl-letf (((symbol-function 'url-retrieve)
               (lambda (url &rest _)
                 (push (cons url url-request-method) posted)
                 (setq body url-request-data)
                 ;; Return a buffer like the real url-retrieve; track it so
                 ;; we can kill it (we don't invoke the callback, which
                 ;; would otherwise do the killing) — no leaked ` *http*'
                 ;; buffers across the ERT run.
                 (setq resp (generate-new-buffer " *clear-resp*")))))
      (emacos--chat-new-chat))
    (when (buffer-live-p resp) (kill-buffer resp))
    (should (equal (caar posted) "http://10.0.0.5:8765/clear"))
    (should (equal (cdar posted) "POST"))
    ;; Empty-but-valid JSON body, matching the declared Content-Type.
    (should (equal body "{}"))))

(ert-deftest chat-test-new-chat-refuses-in-flight ()
  "New chat is a no-op while a stream is in flight: it must not POST
/clear, wipe the transcript, NOR arm the confirm (abort first)."
  (chat-test--reset)
  (emacos--chat-buffer)
  (let ((emacos--chat-in-flight t)
        (called nil))
    (cl-letf (((symbol-function 'emacos--chat-forget-server)
               (lambda () (setq called t))))
      (emacos--chat-new-chat))
    (should-not called)
    (should-not emacos--chat-confirm-pending)))

(ert-deftest chat-test-forget-callback-kills-response-buffer ()
  "The /clear response buffer must be killed so repeated New-chat commands
don't leak ` *http*' buffers."
  (chat-test--reset)
  (let ((resp (generate-new-buffer " *clear-resp*")))
    (with-current-buffer resp
      (emacos--chat-forget-callback nil))
    (should-not (buffer-live-p resp))))

(ert-deftest chat-test-rollback-callback-kills-response-buffer ()
  "The url-retrieve response buffer must be killed so repeated rollbacks
don't leak ` *http*' buffers."
  (chat-test--reset)
  (emacos--chat-buffer)
  (let ((resp (generate-new-buffer " *rollback-resp*")))
    (with-current-buffer resp
      (insert "HTTP/1.1 200 OK\n\n{\"status\":\"applied\",\"detail\":\"ok\"}")
      (emacos--chat-rollback-callback nil))
    (should-not (buffer-live-p resp))))

(ert-deftest chat-test-native-markdown-presentation-keeps-source-and-safe-objects ()
  (with-temp-buffer
    (emacos--chat-enable-presentation)
    (insert "bot> # Heading\n- item\n> quote\n**bold** *italic* [docs](https://example.test) `code`\n```elisp\n**literal**\n```")
    (let ((source (buffer-string)))
      (set-buffer-modified-p nil)
      (emacos--chat-present-message 1 6 (point-max) 'assistant)
      (should (equal (buffer-string) source))
      (should-not (buffer-modified-p))
      (should (memq 'emacos-chat-assistant-role-face
                    (get-text-property 1 'font-lock-face)))
      (goto-char (point-min))
      (search-forward "Heading")
      (should (memq 'emacos-chat-heading-face
                    (get-text-property (match-beginning 0) 'font-lock-face)))
      (search-forward "item")
      (should (stringp (get-text-property (match-beginning 0) 'wrap-prefix)))
      (search-forward "quote")
      (should (memq 'emacos-chat-quote-face
                    (get-text-property (match-beginning 0) 'font-lock-face)))
      (search-forward "bold")
      (should (memq 'bold
                    (get-text-property (match-beginning 0) 'font-lock-face)))
      (search-forward "italic")
      (should (memq 'italic
                    (get-text-property (match-beginning 0) 'font-lock-face)))
      (search-forward "docs")
      (should (memq 'emacos-chat-link-face
                    (get-text-property (match-beginning 0) 'font-lock-face)))
      (search-forward "code")
      (should (memq 'emacos-chat-code-face
                    (get-text-property (match-beginning 0) 'font-lock-face)))
      (search-forward "literal")
      (let ((faces (get-text-property (match-beginning 0) 'font-lock-face)))
        (should (memq 'emacos-chat-code-face faces))
        (should-not (memq 'bold faces)))
      (let ((position (point-min)))
        (while (< position (point-max))
          (let ((properties (text-properties-at position)))
            (while properties
              (should (memq (pop properties)
                            '(font-lock-face wrap-prefix emacos-conversation-url
                              keymap mouse-face)))
              (pop properties)))
          (setq position (next-property-change position nil (point-max)))))
      (let ((kill-ring nil))
        (kill-ring-save (point-min) (point-max))
        (should-not (text-properties-at 0 (car kill-ring)))
        (erase-buffer)
        (yank)
        (should (equal (buffer-string) source))
        (should-not (text-properties-at (point-min)))))))

(ert-deftest chat-test-inline-code-wins-and-identifiers-are-not-emphasis ()
  (with-temp-buffer
    (insert "bot> **outer `code` tail** file_name __init__")
    (emacos--chat-present-message 1 6 (point-max) 'assistant)
    (goto-char (point-min))
    (search-forward "code")
    (let ((faces (get-text-property (match-beginning 0) 'font-lock-face)))
      (should (memq 'emacos-chat-code-face faces))
      (should-not (memq 'bold faces)))
    (search-forward "name")
    (should-not (memq 'italic
                      (get-text-property (match-beginning 0) 'font-lock-face)))
    (search-forward "init")
    (should-not (memq 'bold
                      (get-text-property (match-beginning 0) 'font-lock-face)))))

(ert-deftest chat-test-markdown-budget-skips-body-formatting ()
  (with-temp-buffer
    (insert "bot> ``` unmatched **bold\n" (make-string 32 ?x))
    (let ((emacos--chat-presentation-max-bytes 16))
      (emacos--chat-present-message 1 6 (point-max) 'assistant))
    (goto-char 6)
    (should-not (get-text-property (point) 'font-lock-face))))

(ert-deftest chat-test-reopened-transcript-has-one-total-presentation-budget ()
  (with-temp-buffer
    (insert "bot> **first**\nbot> **second**")
    (let ((emacos--chat-presentation-max-bytes 16))
      (emacos--chat-present-transcript (point-min) (point-max)))
    (goto-char (point-min))
    (should-not (get-text-property (point) 'font-lock-face))))

(ert-deftest chat-test-stream-formats-only-a-genuine-end-and-keeps-draft-point ()
  (chat-test--reset)
  (setq emacos--chat-in-flight t)
  (let ((buf (emacos--chat-buffer)))
    (chat-test--seed-you-line buf "hi")
    (with-current-buffer buf
      (goto-char (point-max))
      (insert "draft")
      (backward-char 2))
    (emacos--chat-handle-start '(:type "start"))
    (emacos--chat-handle-token '(:type "token" :text "**done**"))
    (with-current-buffer buf
      (goto-char (point-min))
      (search-forward "done")
      (should-not (get-text-property (match-beginning 0) 'font-lock-face)))
    (emacos--chat-handle-end '(:type "end"))
    (with-current-buffer buf
      (goto-char (point-min))
      (search-forward "done")
      (should (memq 'bold
                    (get-text-property (match-beginning 0) 'font-lock-face)))
      (should (equal (emacos--chat-current-input buf) "draft")))))

(ert-deftest chat-test-presentation-error-cannot-strand-end-cleanup ()
  (chat-test--reset)
  (setq emacos--chat-in-flight t)
  (let ((buf (emacos--chat-buffer)))
    (chat-test--seed-you-line buf "hi")
    (emacos--chat-handle-start '(:type "start"))
    (cl-letf (((symbol-function 'emacos--chat-present-markdown-1)
               (lambda (&rest _) (error "broken presenter"))))
      (emacos--chat-handle-end '(:type "end")))
    (should-not emacos--chat-in-flight)
    (should-not emacos--chat-stream-insert-marker)))

(ert-deftest chat-test-watchdog-end-leaves-incomplete-markdown-plain ()
  (chat-test--reset)
  (setq emacos--chat-in-flight t)
  (let ((buf (emacos--chat-buffer)))
    (chat-test--seed-you-line buf "hi")
    (emacos--chat-handle-start '(:type "start"))
    (emacos--chat-handle-token '(:type "token" :text "**unfinished**"))
    (emacos--chat-handle-end nil)
    (with-current-buffer buf
      (goto-char (point-min))
      (search-forward "unfinished")
      (should-not (get-text-property (match-beginning 0) 'font-lock-face)))))

(provide 'test-chat)
;;; test-chat.el ends here
