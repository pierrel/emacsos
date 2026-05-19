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
  (let ((seen nil))
    (cl-letf (((symbol-function 'emacos--chat-handle-token)
               (lambda (event) (setq seen event))))
      (emacos--chat-dispatch-line "{\"type\":\"token\",\"text\":\"hi\"}")
      (should (equal (plist-get seen :type) "token"))
      (should (equal (plist-get seen :text) "hi")))))

(ert-deftest chat-test-dispatch-line-ignores-malformed-json ()
  (chat-test--reset)
  (let ((called nil))
    (cl-letf (((symbol-function 'emacos--chat-handle-token)
               (lambda (_) (setq called t))))
      ;; Should not raise; should not invoke handler.
      (emacos--chat-dispatch-line "this is not json")
      (should-not called))))

(ert-deftest chat-test-dispatch-line-ignores-unknown-type ()
  (chat-test--reset)
  ;; Unknown type => no handler => no error.
  (emacos--chat-dispatch-line "{\"type\":\"unknown_kind\",\"x\":1}"))

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

;;; Page integration

(ert-deftest chat-test-page-shows-abort-when-in-flight ()
  (chat-test--reset)
  (require 'os)
  (with-temp-buffer
    (setq emacos--chat-in-flight nil)
    (emacos--render-chat-page)
    (should (string-match-p "CLEAR" (buffer-string)))
    (should-not (string-match-p "ABORT" (buffer-string))))
  (with-temp-buffer
    (setq emacos--chat-in-flight t)
    (emacos--render-chat-page)
    (should (string-match-p "ABORT" (buffer-string)))
    (should-not (string-match-p "CLEAR" (buffer-string))))
  (setq emacos--chat-in-flight nil))

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

(provide 'test-chat)
;;; test-chat.el ends here
