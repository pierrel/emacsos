;;; test-chat.el --- Tests for chat.el -*- lexical-binding: t -*-

(require 'ert)
(require 'cl-lib)
(require 'chat)

;;; Helpers

(defun chat-test--reset ()
  "Tear down state between tests."
  (when (get-buffer emacos--chat-buffer-name)
    (let ((kill-buffer-query-functions nil))
      (kill-buffer emacos--chat-buffer-name)))
  (setq emacos--chat-in-flight nil))

(defmacro chat-test--with-fake-server (response &rest body)
  "Run BODY with `url-retrieve-synchronously` stubbed to return RESPONSE.
RESPONSE is a string \"STATUS-LINE\\nHEADERS\\n\\nBODY\" or nil for timeout.
Captured request body is bound to `last-request-body` (a string)."
  (declare (indent 1))
  `(let ((last-request-body nil))
     (cl-letf* (((symbol-function 'url-retrieve-synchronously)
                 (lambda (&rest _args)
                   (setq last-request-body
                         (when (boundp 'url-request-data) url-request-data))
                   (when ,response
                     (let ((buf (generate-new-buffer " *fake-url*")))
                       (with-current-buffer buf
                         (insert ,response))
                       buf)))))
       ,@body)))

(defun chat-test--http (status-line body)
  "Build a fake url-retrieve-synchronously buffer payload."
  (format "%s\r\nContent-Type: application/json\r\n\r\n%s" status-line body))

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

(ert-deftest chat-test-current-input-ignores-transcript ()
  (chat-test--reset)
  (let ((buf (emacos--chat-buffer)))
    ;; Splice a fake exchange into the transcript.
    (emacos--chat-clear-input buf)
    (emacos--chat-append-line buf "you> old")
    (emacos--chat-append-line buf "bot> old reply")
    (with-current-buffer buf (goto-char (point-max)) (insert "new"))
    (should (equal (emacos--chat-current-input buf) "new"))))

(ert-deftest chat-test-transcript-read-only ()
  (chat-test--reset)
  (let ((buf (emacos--chat-buffer)))
    (with-current-buffer buf
      (goto-char (1+ (point-min)))           ; mid-prompt
      (should-error (delete-char -1) :type 'text-read-only))))

(ert-deftest chat-test-input-region-editable ()
  (chat-test--reset)
  (let ((buf (emacos--chat-buffer)))
    (with-current-buffer buf
      (goto-char (point-max))
      (insert "x")                            ; must not error
      (should (equal (buffer-substring-no-properties (1- (point-max)) (point-max))
                     "x")))))

;;; SEND scenarios

(ert-deftest chat-test-send-empty-noop ()
  (chat-test--reset)
  (chat-test--with-fake-server (chat-test--http "HTTP/1.1 200 OK" "{\"text\":\"x\"}")
    (let ((buf (emacos--chat-buffer)))
      (emacos--chat-send)
      ;; Buffer is still just the prompt; HTTP never invoked.
      (should (equal (with-current-buffer buf (buffer-string))
                     emacos--chat-prompt))
      (should (null last-request-body)))))

(ert-deftest chat-test-send-happy-path ()
  (chat-test--reset)
  (let ((buf (emacos--chat-buffer)))
    (with-current-buffer buf (goto-char (point-max)) (insert "hi"))
    (chat-test--with-fake-server
        (chat-test--http "HTTP/1.1 200 OK"
                         "{\"text\":\"echo: hi\",\"side_effect\":null}")
      (emacos--chat-send))
    (with-current-buffer buf
      (let ((s (buffer-string)))
        (should (string-match-p "\nyou> hi" s))
        (should (string-match-p "\nbot> echo: hi" s))
        (should (string-suffix-p emacos--chat-prompt s))
        (should (= (point) (point-max)))))))

(ert-deftest chat-test-send-timeout ()
  (chat-test--reset)
  (let ((buf (emacos--chat-buffer)))
    (with-current-buffer buf (goto-char (point-max)) (insert "hi"))
    (chat-test--with-fake-server nil
      (emacos--chat-send))
    (should (string-match-p "bot> \\[error: timeout"
                            (with-current-buffer buf (buffer-string))))))

(ert-deftest chat-test-send-http-error ()
  (chat-test--reset)
  (let ((buf (emacos--chat-buffer)))
    (with-current-buffer buf (goto-char (point-max)) (insert "hi"))
    (chat-test--with-fake-server
        (chat-test--http "HTTP/1.1 500 Internal Server Error" "{}")
      (emacos--chat-send))
    (should (string-match-p "bot> \\[error: HTTP 500\\]"
                            (with-current-buffer buf (buffer-string))))))

(ert-deftest chat-test-send-malformed-json ()
  (chat-test--reset)
  (let ((buf (emacos--chat-buffer)))
    (with-current-buffer buf (goto-char (point-max)) (insert "hi"))
    (chat-test--with-fake-server
        (chat-test--http "HTTP/1.1 200 OK" "not-json")
      (emacos--chat-send))
    (should (string-match-p "bot> \\[error: malformed response\\]"
                            (with-current-buffer buf (buffer-string))))))

(ert-deftest chat-test-send-missing-text-field ()
  (chat-test--reset)
  (let ((buf (emacos--chat-buffer)))
    (with-current-buffer buf (goto-char (point-max)) (insert "hi"))
    (chat-test--with-fake-server
        (chat-test--http "HTTP/1.1 200 OK" "{\"side_effect\":null}")
      (emacos--chat-send))
    (should (string-match-p "bot> \\[error: no text field\\]"
                            (with-current-buffer buf (buffer-string))))))

(ert-deftest chat-test-send-missing-auth-file ()
  (chat-test--reset)
  (let ((emacos-chat-auth-file "/nonexistent/path/never/exists")
        (buf (emacos--chat-buffer)))
    (with-current-buffer buf (goto-char (point-max)) (insert "hi"))
    (chat-test--with-fake-server
        (chat-test--http "HTTP/1.1 200 OK" "{\"text\":\"echo: hi\"}")
      (emacos--chat-send)
      ;; Request body has no "phone" key.
      (should last-request-body)
      (should-not (string-match-p "phone" last-request-body)))))

(ert-deftest chat-test-send-includes-auth-file ()
  (chat-test--reset)
  (let* ((tmp (make-temp-file "chat-test-auth"))
         (emacos-chat-auth-file tmp)
         (buf (emacos--chat-buffer)))
    (unwind-protect
        (progn
          (with-temp-file tmp (insert "12345 abcdef\nDEADBEEF"))
          (with-current-buffer buf (goto-char (point-max)) (insert "hi"))
          (chat-test--with-fake-server
              (chat-test--http "HTTP/1.1 200 OK" "{\"text\":\"echo: hi\"}")
            (emacos--chat-send)
            (should last-request-body)
            (let ((body (decode-coding-string last-request-body 'utf-8)))
              (should (string-match-p "phone" body))
              (should (string-match-p "12345 abcdef" body))
              (should (string-match-p "DEADBEEF" body)))))
      (delete-file tmp))))

(ert-deftest chat-test-send-in-flight-lockout ()
  (chat-test--reset)
  (let ((emacos--chat-in-flight t)
        (buf (emacos--chat-buffer))
        (called nil))
    (with-current-buffer buf (goto-char (point-max)) (insert "hi"))
    (cl-letf (((symbol-function 'url-retrieve-synchronously)
               (lambda (&rest _) (setq called t) nil)))
      (emacos--chat-send))
    (should-not called)
    ;; Input region preserved (not cleared, since SEND short-circuited).
    (should (equal (emacos--chat-current-input buf) "hi"))))

;;; CLEAR

(ert-deftest chat-test-clear-resets-buffer ()
  (chat-test--reset)
  (let ((buf (emacos--chat-buffer)))
    (with-current-buffer buf (goto-char (point-max)) (insert "junk"))
    (emacos--chat-append-line buf "you> old")
    (emacos--chat-clear)
    (should (equal (with-current-buffer buf (buffer-string))
                   emacos--chat-prompt))))

;;; Page integration

(ert-deftest chat-test-page-in-bar ()
  (chat-test--reset)
  ;; Run the page-bar renderer in a temp buffer; insert-text-button still
  ;; inserts the label as visible text.  Needs os.el loaded for the
  ;; renderer; loading os.el at top-level is risky (init hooks), so
  ;; require it lazily here.
  (require 'os)
  (with-temp-buffer
    (let ((emacos--current-page 'chat))
      (emacos--render-page-bar))
    (should (string-match-p "CHAT" (buffer-string)))
    (should (string-match-p "KBD" (buffer-string)))))

(ert-deftest chat-test-switch-shows-top-buffer ()
  (chat-test--reset)
  ;; Stub emacos--target to return a temporary window pointing at *scratch*.
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
