;;; test-assist-web.el --- Tests for the Assist Web client -*- lexical-binding: t -*-

(require 'ert)
(require 'assist-web)

(defconst test-assist-web--snapshot
  '((thread . ((id . "thread-1") (description . "Thread")
               (status . "ready")
               (workspace . ((repo_label . "Assist")))))
    (messages . (((id . "m-1") (role . "assistant") (text . "old")
                  (state . "final"))))
    (has_older_messages . t)
    (next_before . "cursor-1")))

(ert-deftest test-assist-web-completion-matches-server-search-text-and-keeps-identity ()
  (let* ((emacos-assist-web--catalog
          '(((id . "thread-1") (description . "🧪")
             (search_description . "Release check")
             (repo_label . "Assist") (status . "ready"))))
         (records (emacos-assist-web--completion-records))
         (table (emacos-assist-web--completion-table records)))
    (should (equal (all-completions "release" table)
                   '("*assist 🧪 - Assist* [ready]")))
    (should (equal (alist-get 'id (plist-get (car records) :thread)) "thread-1"))))

(ert-deftest test-assist-web-duplicate-thread-labels-show-full-identity ()
  (let* ((emacos-assist-web--catalog
          '(((id . "thread-a-shared") (description . "Same")
             (repo_label . "Assist") (status . "ready"))
            ((id . "thread-b-shared") (description . "Same")
             (repo_label . "Assist") (status . "ready"))))
         (records (emacos-assist-web--completion-records))
         (displays (mapcar (lambda (record) (plist-get record :display)) records)))
    (should (= (length (delete-dups (copy-sequence displays))) 2))
    (should (string-match-p "thread-a-shared" (car displays)))
    (should (string-match-p "thread-b-shared" (cadr displays)))))

(ert-deftest test-assist-web-completion-returns-all-substring-matches ()
  (let* ((emacos-assist-web--catalog
          '(((id . "thread-1") (description . "Release one")
             (repo_label . "Assist") (status . "ready"))
            ((id . "thread-2") (description . "Release two")
             (repo_label . "EmacsOS") (status . "ready"))))
         (table (emacos-assist-web--completion-table
                 (emacos-assist-web--completion-records))))
    (should (= (length (all-completions "release" table)) 2))
    (should (equal (try-completion "release" table) "release"))
    (should (test-completion (car (all-completions "release" table)) table))))

(ert-deftest test-assist-web-endpoint-requires-https ()
  (let ((emacos-assist-web-api-url "http://10.0.0.1:5050/api/v1/phone"))
    (should-error (emacos-assist-web--endpoint "threads")))
  (let ((emacos-assist-web-api-url "https://10.0.0.1:5050/api/v1/phone"))
    (should (equal (emacos-assist-web--endpoint "threads")
                   "https://10.0.0.1:5050/api/v1/phone/threads"))))

(ert-deftest test-assist-web-token-cannot-inject-a-header ()
  (should (emacos-assist-web--safe-token-p "0123abcd._~-"))
  (should-not (emacos-assist-web--safe-token-p "token\r\nInjected: yes"))
  (should-not (emacos-assist-web--safe-token-p "")))

(ert-deftest test-assist-web-ca-extends-trust-only-through-request-binding ()
  (let ((ca (make-temp-file "assist-web-ca-")))
    (unwind-protect
        (cl-progv '(gnutls-trustfiles) '(("system-ca"))
          (let ((emacos-assist-web-ca-file ca))
            (should (equal (emacos-assist-web--trustfiles)
                           (list ca "system-ca")))
            (should (equal (symbol-value 'gnutls-trustfiles)
                           '("system-ca")))))
      (delete-file ca))))

(ert-deftest test-assist-web-ca-supports-function-valued-system-trust ()
  (let ((ca (make-temp-file "assist-web-ca-")))
    (unwind-protect
        (cl-progv '(gnutls-trustfiles) '((lambda () '("system-ca")))
          (let ((emacos-assist-web-ca-file ca))
            (should (equal (emacos-assist-web--trustfiles)
                           (list ca "system-ca")))))
      (delete-file ca))))

(ert-deftest test-assist-web-closes-only-idle-connections-for-its-origin ()
  (let* ((emacos-assist-web-api-url
          "https://10.0.0.1:5050/api/v1/phone")
         (url-http-open-connections (make-hash-table :test #'equal))
         (assist (make-pipe-process :name "assist-web-idle" :noquery t))
         (other (make-pipe-process :name "other-idle" :noquery t)))
    (unwind-protect
        (progn
          (puthash '("10.0.0.1" . 5050) (list assist)
                   url-http-open-connections)
          (puthash '("example.net" . 443) (list other)
                   url-http-open-connections)
          (emacos-assist-web--close-idle-origin-connections)
          (should-not (process-live-p assist))
          (should-not (gethash '("10.0.0.1" . 5050)
                               url-http-open-connections))
          (should (process-live-p other))
          (should (equal (gethash '("example.net" . 443)
                                  url-http-open-connections)
                         (list other))))
      (when (process-live-p assist) (delete-process assist))
      (when (process-live-p other) (delete-process other)))))

(ert-deftest test-assist-web-accepts-server-bounded-sealed-record-identifiers ()
  (let* ((sealed (concat "c-" (make-string 240 ?A)))
         (snapshot
          `((thread . ((id . "thread-1") (description . "Thread")
                       (status . "ready") (error . nil)
                       (workspace . ((repo_label . "Assist")))))
            (messages . (((id . ,(concat "m-" (make-string 240 ?B)))
                          (role . "assistant") (text . "answer")
                          (state . "final"))))
            (next_before . ,sealed))))
    (should (eq (emacos-assist-web--require-snapshot snapshot "thread-1")
                snapshot))))

(ert-deftest test-assist-web-rejects-a-non-string-thread-error ()
  (let ((snapshot (copy-tree test-assist-web--snapshot)))
    (setf (alist-get 'error (alist-get 'thread snapshot)) '((detail . "bad")))
    (should-error (emacos-assist-web--require-snapshot snapshot "thread-1"))))

(ert-deftest test-assist-web-json-response-requires-json-content-type ()
  (with-temp-buffer
    (insert "{}")
    (setq-local url-http-response-status 200
                url-http-content-type "text/plain"
                url-http-end-of-headers (copy-marker (point-min)))
    (should-error (emacos-assist-web--response-json (current-buffer))))
  (with-temp-buffer
    (insert "{}")
    (setq-local url-http-response-status 200
                url-http-content-type "application/json; charset=utf-8"
                url-http-end-of-headers (copy-marker (point-min)))
    (should (equal (emacos-assist-web--response-json (current-buffer)) nil))))

(ert-deftest test-assist-web-completion-marks-cached-source-and-state ()
  (let* ((emacos-assist-web--catalog-stale t)
         (emacos-assist-web--catalog
          '(((id . "thread-1") (description . "Thread")
             (repo_label . "Assist") (status . "running"))))
         (record (car (emacos-assist-web--completion-records))))
    (should (equal (plist-get record :display)
                   "*assist Thread - Assist* [running, cached]"))))

(ert-deftest test-assist-web-cache-rejects-an-oversized-record ()
  (let ((emacos-assist-web-cache-directory (make-temp-file "assist-web-cache-" t))
        (emacos-assist-web-max-cache-bytes 8))
    (unwind-protect
        (should-error (emacos-assist-web--write-cache "threads.json" '((x . "too long"))))
      (delete-directory emacos-assist-web-cache-directory t))))

(ert-deftest test-assist-web-cache-path-does-not-create-the-cache-directory ()
  (let* ((parent (make-temp-file "assist-web-cache-parent-" t))
         (emacos-assist-web-cache-directory (expand-file-name "missing" parent)))
    (unwind-protect
        (progn
          (should (equal (emacos-assist-web--cache-path "threads.json")
                         (expand-file-name "missing/threads.json" parent)))
          (should-not (file-exists-p emacos-assist-web-cache-directory)))
      (delete-directory parent t))))

(ert-deftest test-assist-web-request-reports-an-invalid-endpoint-to-its-callback ()
  (let ((emacos-assist-web-api-url "http://assist.invalid/api/v1/phone") result)
    (cl-letf (((symbol-function 'emacos-assist-web--read-token)
               (lambda () "safe-token")))
      (emacos-assist-web--request
       "GET" "threads" nil
       (lambda (value error) (setq result (list value error)))))
    (should-not (car result))
    (should (string-match-p "must be HTTPS" (cadr result)))))

(ert-deftest test-assist-web-request-reports-token-read-errors-to-its-callback ()
  (let (result)
    (cl-letf (((symbol-function 'emacos-assist-web--read-token)
               (lambda () (error "token I/O failed"))))
      (emacos-assist-web--request
       "GET" "threads" nil
       (lambda (value error) (setq result (list value error)))))
    (should-not (car result))
    (should (equal (cadr result) "token I/O failed"))))

(ert-deftest test-assist-web-rejects-an-untrusted-thread-id-before-it-reaches-cache-path ()
  (should-error (emacos-assist-web--snapshot-cache-name "../../outside"))
  (should (equal (emacos-assist-web--snapshot-cache-name "thread-1")
                 "threads/thread-1.json")))

(ert-deftest test-assist-web-event-parser-keeps-target-outside-response-buffer ()
  (let ((target (generate-new-buffer " *assist-web-target*"))
        (source (generate-new-buffer " *assist-web-source*"))
        seen)
    (unwind-protect
        (with-current-buffer source
          (insert "event: terminal\ndata: {}\n\n")
          (setq-local url-http-end-of-headers (copy-marker (point-min)))
          (cl-letf (((symbol-function 'emacos-assist-web--dispatch-event)
                     (lambda (actual-target event data)
                       (setq seen (list actual-target event data)))))
            (emacos-assist-web--drain-events target 0))
          (should (equal seen (list target "terminal" "{}"))))
      (when (buffer-live-p target) (kill-buffer target))
      (when (buffer-live-p source) (kill-buffer source)))))

(ert-deftest test-assist-web-terminal-event-keeps-response-buffer-alive-through-drain ()
  (let ((target (generate-new-buffer " *assist-web-target*"))
        (source (generate-new-buffer " *assist-web-source*")))
    (unwind-protect
        (progn
          (with-current-buffer target
            (emacos-assist-web-mode)
            (setq-local emacos-assist-web--stream-response source))
          (with-current-buffer source
            (insert "event: terminal\ndata: {}\n\n")
            (setq-local url-http-end-of-headers (copy-marker (point-min)))
            (emacos-assist-web--drain-events target 0))
          (should (buffer-live-p source)))
      (when (buffer-live-p target) (kill-buffer target))
      (when (buffer-live-p source) (kill-buffer source)))))

(ert-deftest test-assist-web-final-filter-chunk-survives-process-buffer-detach ()
  (let ((target (generate-new-buffer " *assist-web-target*"))
        (source (generate-new-buffer " *assist-web-source*"))
        process seen)
    (unwind-protect
        (progn
          (setq process (make-pipe-process :name "assist-web-final-filter"
                                           :buffer source
                                           :noquery t))
          (with-current-buffer target
            (emacos-assist-web-mode))
          (let ((filter
                 (emacos-assist-web--event-filter
                  (lambda (active _bytes)
                    (with-current-buffer source
                      (erase-buffer)
                      (insert "event: terminal\ndata: {}\n\n")
                      (setq-local url-http-response-status 200
                                  url-http-content-type "text/event-stream"
                                  url-http-end-of-headers (copy-marker (point-min))))
                    (set-process-buffer active nil))
                  target 0)))
            (cl-letf (((symbol-function 'emacos-assist-web--dispatch-event)
                       (lambda (_target event _data) (setq seen event))))
              (funcall filter process "final")))
          (should (equal seen "terminal")))
      (when (process-live-p process) (delete-process process))
      (when (buffer-live-p target) (kill-buffer target))
      (when (buffer-live-p source) (kill-buffer source)))))

(ert-deftest test-assist-web-final-callback-waits-for-terminal-event-drain ()
  (let ((target (generate-new-buffer " *assist-web-target*"))
        (source (generate-new-buffer " *assist-web-source*"))
        (emacos-assist-web-api-url "https://assist.invalid/api/v1/phone")
        process finished interrupted callback keepalive trustfiles)
    (unwind-protect
        (progn
          (setq process (make-pipe-process :name "assist-web-callback-order"
                                           :buffer source :noquery t))
          (with-current-buffer target
            (emacos-assist-web-mode)
            (setq emacos-assist-web--thread-id "thread-1"
                  emacos-assist-web--run-id "run-1"
                  emacos-assist-web--in-flight t))
          (cl-letf (((symbol-function 'emacos-assist-web--read-token)
                     (lambda () "token"))
                    ((symbol-function 'url-retrieve)
                     (lambda (_url cb &rest _)
                       (setq callback cb
                             keepalive url-http-attempt-keepalives
                             trustfiles gnutls-trustfiles)
                       (set-process-filter
                        process
                        (lambda (_active _bytes)
                          (with-current-buffer source
                            (erase-buffer)
                            (insert "event: terminal\ndata: {}\n\n")
                            (setq-local url-http-response-status 200
                                        url-http-content-type "text/event-stream"
                                        url-http-end-of-headers
                                        (copy-marker (point-min))))
                          (funcall callback nil)))
                       source))
                    ((symbol-function 'emacos-assist-web--trustfiles)
                     (lambda () '("assist-ca" "system-ca")))
                    ((symbol-function 'emacos-assist-web--stream-finish)
                     (lambda (buffer)
                       (setq finished t)
                       (with-current-buffer buffer
                         (cl-incf emacos-assist-web--stream-generation))))
                    ((symbol-function 'emacos-assist-web--stream-interrupted)
                     (lambda (&rest _) (setq interrupted t))))
            (emacos-assist-web--observe-run target)
            (funcall (process-filter process) process
                     "HTTP/1.1 200 OK\r\n\r\n")
            (sleep-for 0.01))
          (should finished)
          (should-not interrupted)
          (should-not keepalive)
          (should (equal trustfiles '("assist-ca" "system-ca"))))
      (when (process-live-p process) (delete-process process))
      (when (buffer-live-p target) (kill-buffer target))
      (when (buffer-live-p source) (kill-buffer source)))))

(ert-deftest test-assist-web-event-parser-bounds-each-record-not-whole-callback ()
  (let ((target (generate-new-buffer " *assist-web-target*"))
        (source (generate-new-buffer " *assist-web-source*"))
        (emacos-assist-web-max-event-bytes 32)
        seen)
    (unwind-protect
        (with-current-buffer source
          (insert "event: status\ndata: {}\n\nevent: status\ndata: {}\n\n")
          (setq-local url-http-end-of-headers (copy-marker (point-min)))
          (cl-letf (((symbol-function 'emacos-assist-web--dispatch-event)
                     (lambda (_target event _data) (push event seen))))
            (emacos-assist-web--drain-events target 0))
          (should (equal seen '("status" "status"))))
      (when (buffer-live-p target) (kill-buffer target))
      (when (buffer-live-p source) (kill-buffer source)))))

(ert-deftest test-assist-web-raw-filter-rejects-encoded-response-before-url-filter ()
  (let (forwarded rejected)
    (funcall
     (emacos-assist-web--guarded-filter
      (lambda (&rest _) (setq forwarded t))
      (lambda (_process problem) (setq rejected problem)))
     nil "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\ncompressed")
    (should-not forwarded)
    (should (equal rejected "Assist Web encoded responses are not accepted"))))

(ert-deftest test-assist-web-raw-filter-forwards-body-chunks-after-headers ()
  (let (forwarded rejected)
    (let ((filter
           (emacos-assist-web--guarded-filter
            (lambda (_process bytes) (push bytes forwarded))
            (lambda (_process problem) (setq rejected problem)))))
      (funcall filter nil
               "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n")
      (funcall filter nil "{\"threads\":[]}")
      (funcall filter nil "\n"))
    (should-not rejected)
    (should (equal (nreverse forwarded)
                   '("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n"
                     "{\"threads\":[]}"
                     "\n")))))

(ert-deftest test-assist-web-raw-filter-checks-every-content-encoding-header ()
  (let (forwarded rejected)
    (funcall
     (emacos-assist-web--guarded-filter
      (lambda (&rest _) (setq forwarded t))
      (lambda (_process problem) (setq rejected problem)))
     nil (concat "HTTP/1.1 200 OK\r\n"
                 "Content-Encoding : identity\r\n"
                 "Content-Encoding: gzip\r\n\r\ncompressed"))
    (should-not forwarded)
    (should (equal rejected "Assist Web encoded responses are not accepted"))))

(ert-deftest test-assist-web-json-request-disables-redirects-and-encoding ()
  (let ((emacos-assist-web--requests nil)
        (response (generate-new-buffer " *assist-web-request*"))
        encoding keepalive trustfiles)
    (unwind-protect
        (cl-letf (((symbol-function 'emacos-assist-web--read-token)
                   (lambda () "token"))
                  ((symbol-function 'url-retrieve)
                   (lambda (&rest _)
                     (setq encoding url-mime-encoding-string
                           keepalive url-http-attempt-keepalives
                           trustfiles gnutls-trustfiles)
                     response))
                  ((symbol-function 'emacos-assist-web--trustfiles)
                   (lambda () '("assist-ca" "system-ca")))
                  ((symbol-function 'run-at-time) (lambda (&rest _) nil)))
          (emacos-assist-web--request "GET" "threads" nil #'ignore)
          (with-current-buffer response
            (should (= url-max-redirections 0)))
          (should (equal encoding "identity"))
          (should-not keepalive)
          (should (equal trustfiles '("assist-ca" "system-ca"))))
      (when (buffer-live-p response) (kill-buffer response)))))

(ert-deftest test-assist-web-json-request-has-a-global-concurrency-bound ()
  (let ((emacos-assist-web--requests '(one two))
        (emacos-assist-web-max-concurrent-requests 2)
        result)
    (cl-letf (((symbol-function 'emacos-assist-web--read-token)
               (lambda () "token")))
      (emacos-assist-web--request
       "GET" "threads" nil
       (lambda (value error) (setq result (list value error)))))
    (should (equal result
                   '(nil "Too many Assist Web requests are already running")))))

(ert-deftest test-assist-web-raw-filter-bounds-an-unterminated-header ()
  (let ((emacos-assist-web-max-header-bytes 8) forwarded rejected)
    (funcall
     (emacos-assist-web--guarded-filter
      (lambda (&rest _) (setq forwarded t))
      (lambda (_process problem) (setq rejected problem))
      t)
     nil "HTTP/1.1 200")
    (should-not forwarded)
    (should (equal rejected "Assist Web response headers are too large"))))

(ert-deftest test-assist-web-header-bound-does-not-count-same-chunk-body ()
  (let ((emacos-assist-web-max-header-bytes 32) forwarded rejected)
    (funcall
     (emacos-assist-web--guarded-filter
      (lambda (&rest _) (setq forwarded t))
      (lambda (_process problem) (setq rejected problem))
      t)
     nil (concat "HTTP/1.1 200 OK\r\n\r\n" (make-string 128 ?x)))
    (should forwarded)
    (should-not rejected)))

(ert-deftest test-assist-web-render-preserves-draft-and-updates-status-in-place ()
  (let ((emacos-assist-web-cache-directory (make-temp-file "assist-web-render-" t)))
    (unwind-protect
        (with-temp-buffer
          (emacos-assist-web-mode)
          (emacos-assist-web--render test-assist-web--snapshot t)
          (insert "next draft")
          (emacos-assist-web--set-status "running")
          (should (equal (emacos-assist-web--input) "next draft"))
          (should (string-match-p "\\[running\\]" (buffer-string)))
          (should (string-match-p "\\[cached\\]" (buffer-string))))
      (delete-directory emacos-assist-web-cache-directory t))))

(ert-deftest test-assist-web-input-preserves-exact-multiline-text ()
  (with-temp-buffer
    (emacos-assist-web-mode)
    (setq emacos-assist-web--thread-id "thread-1")
    (setq emacos-assist-web--status-start (copy-marker (point) nil))
    (insert "[ready]")
    (setq emacos-assist-web--status-end (copy-marker (point) nil))
    (emacos-assist-web--write-prompt)
    (insert "  first line\nsecond line  \n")
    (should (equal (emacos-assist-web--input)
                   "  first line\nsecond line  \n"))))

(ert-deftest test-assist-web-pending-transcript-removes-the-old-prompt ()
  (with-temp-buffer
    (emacos-assist-web-mode)
    (emacos-assist-web--write-prompt)
    (insert "hello")
    (emacos-assist-web--append-pending "hello")
    (should (= (how-many "^> " (point-min) (point-max)) 1))
    (should (= (how-many "you> hello" (point-min) (point-max)) 1))))

(ert-deftest test-assist-web-render-rejects-a-mismatched-snapshot-identity ()
  (with-temp-buffer
    (emacos-assist-web-mode)
    (setq emacos-assist-web--thread-id "thread-1")
    (should-error
     (emacos-assist-web--render
      '((thread . ((id . "thread-2") (description . "Wrong")
                   (status . "ready") (workspace . nil)))
        (messages . nil))))))

(ert-deftest test-assist-web-invalid-cached-retry-key-is-not-restored ()
  (with-temp-buffer
    (emacos-assist-web-mode)
    (setq emacos-assist-web--thread-id "thread-1")
    (emacos-assist-web--write-prompt)
    (cl-letf (((symbol-function 'emacos-assist-web--read-cache)
               (lambda (&rest _)
                 '((text . "draft") (pending_key . "bad\r\nInjected: yes")
                   (submitted_text . "draft")))))
      (emacos-assist-web--restore-draft))
    (should-not emacos-assist-web--pending-key)
    (should-not emacos-assist-web--submitted-text)
    (should (equal (emacos-assist-web--input) "draft"))))

(ert-deftest test-assist-web-restores-an-accepted-pending-message-visibly ()
  (with-temp-buffer
    (emacos-assist-web-mode)
    (setq emacos-assist-web--thread-id "thread-1")
    (setq emacos-assist-web--status-start (copy-marker (point) nil))
    (insert "[ready]")
    (setq emacos-assist-web--status-end (copy-marker (point) nil))
    (emacos-assist-web--write-prompt)
    (cl-letf (((symbol-function 'emacos-assist-web--read-cache)
               (lambda (&rest _)
                 '((text . "")
                   (pending_key . "emacsos-0123456789abcdef0123456789abcdef")
                   (submitted_text . "already accepted")
                   (pending_accepted . t)))))
      (emacos-assist-web--restore-draft))
    (should (string-match-p "you> already accepted" (buffer-string)))
    (should (string-match-p "observation interrupted" (buffer-string)))
    (should emacos-assist-web--pending-accepted-p)))

(ert-deftest test-assist-web-does-not-duplicate-canonical-incomplete-message-on-restore ()
  (with-temp-buffer
    (emacos-assist-web-mode)
    (setq emacos-assist-web--thread-id "thread-1"
          emacos-assist-web--snapshot
          '((messages . (((role . "user") (state . "incomplete")
                          (text . "already accepted"))))))
    (insert "you> already accepted\n")
    (setq emacos-assist-web--status-start (copy-marker (point) nil))
    (insert "[processing]")
    (setq emacos-assist-web--status-end (copy-marker (point) nil))
    (emacos-assist-web--write-prompt)
    (cl-letf (((symbol-function 'emacos-assist-web--read-cache)
               (lambda (&rest _)
                 '((text . "")
                   (pending_key . "emacsos-0123456789abcdef0123456789abcdef")
                   (submitted_text . "already accepted")
                   (pending_accepted . t)))))
      (emacos-assist-web--restore-draft))
    (should (= (how-many "you> already accepted" (point-min) (point-max)) 1))))

(ert-deftest test-assist-web-editing-after-a-failed-send-mints-a-new-retry-identity ()
  (with-temp-buffer
    (emacos-assist-web-mode)
    (setq emacos-assist-web--pending-key "old-key"
          emacos-assist-web--submitted-text "old")
    (emacos-assist-web--write-prompt)
    (insert "new")
    (emacos-assist-web--after-change)
    (should-not emacos-assist-web--pending-key)
    (should-not emacos-assist-web--submitted-text)))

(ert-deftest test-assist-web-interrupted-observation-retains-the-exact-retry ()
  (with-temp-buffer
    (emacos-assist-web-mode)
    (emacos-assist-web--write-prompt)
    (setq emacos-assist-web--pending-key "retry-key"
          emacos-assist-web--submitted-text "message"
          emacos-assist-web--in-flight t
          emacos--assist-active-surface (current-buffer))
    (cl-letf (((symbol-function 'emacos-assist-web--save-draft) (lambda () nil)))
      (emacos-assist-web--stream-interrupted (current-buffer) "observation disconnected"))
    (should (equal emacos-assist-web--pending-key "retry-key"))
    (should (equal emacos-assist-web--submitted-text "message"))
    (should-not emacos-assist-web--in-flight)
    (should (equal emacos-assist-web--stream-status "observation disconnected"))))

(ert-deftest test-assist-web-history-merges-chronologically-and-keeps-page-cursor ()
  (let ((emacos-assist-web-cache-directory (make-temp-file "assist-web-history-" t))
        (rendered nil)
        (snapshot (copy-tree test-assist-web--snapshot))
        (page '((thread . ((id . "thread-1") (description . "Thread")
                           (status . "ready")
                           (workspace . ((repo_label . "Assist")))))
                (messages . (((id . "m-0") (role . "user") (text . "older")
                              (state . "final"))))
                (has_older_messages . t) (next_before . "cursor-0"))))
    (unwind-protect
        (with-temp-buffer
          (emacos-assist-web-mode)
          (setq emacos-assist-web--thread-id "thread-1")
          (cl-letf (((symbol-function 'emacos-assist-web--read-cache)
                     (lambda (&rest _) snapshot))
                    ((symbol-function 'emacos-assist-web--write-cache)
                     (lambda (&rest _) (ert-fail "history pages must not be cached")))
                    ((symbol-function 'emacos-assist-web--request)
                     (lambda (method path _payload callback &rest _)
                       (should (equal method "GET"))
                       (should (string-suffix-p "before=cursor-1" path))
                       (funcall callback page nil)))
                    ((symbol-function 'emacos-assist-web--render)
                     (lambda (value &rest _) (setq rendered value))))
            (emacos-assist-web-load-older))
          (should (equal (mapcar (lambda (message) (alist-get 'id message))
                                 (alist-get 'messages rendered))
                         '("m-0" "m-1")))
          (should (equal (alist-get 'next_before rendered) "cursor-0")))
      (delete-directory emacos-assist-web-cache-directory t))))

(ert-deftest test-assist-web-history-rejects-a-mismatched-thread-page ()
  (let ((snapshot (copy-tree test-assist-web--snapshot)) rendered)
    (with-temp-buffer
      (emacos-assist-web-mode)
      (setq emacos-assist-web--thread-id "thread-1")
      (cl-letf (((symbol-function 'emacos-assist-web--read-cache)
                 (lambda (&rest _) snapshot))
                ((symbol-function 'emacos-assist-web--request)
                 (lambda (_method _path _payload callback &rest _)
                   (funcall callback
                            '((thread . ((id . "thread-2")
                                         (description . "Wrong")
                                         (status . "ready")
                                         (workspace . ((repo_label . "Other")))))
                              (messages . nil)
                              (has_older_messages . nil)
                              (next_before . nil))
                            nil)))
                ((symbol-function 'emacos-assist-web--render)
                 (lambda (&rest _) (setq rendered t))))
        (emacos-assist-web-load-older))
      (should-not rendered))))

(ert-deftest test-assist-web-terminal-refresh-releases-a-live-observer ()
  (let ((emacos--assist-active-surface nil))
    (with-temp-buffer
      (emacos-assist-web-mode)
      (setq emacos-assist-web--thread-id "thread-1"
            emacos-assist-web--run-id "run-1"
            emacos-assist-web--pending-key "retry-key"
            emacos-assist-web--submitted-text "hello"
            emacos-assist-web--pending-accepted-p t
            emacos-assist-web--in-flight t
            emacos--assist-active-surface (current-buffer))
      (cl-letf (((symbol-function 'emacos-assist-web--request)
                 (lambda (_method _path _payload callback &rest _)
                   (funcall callback test-assist-web--snapshot nil)))
                ((symbol-function 'emacos-assist-web--write-cache) #'ignore)
                ((symbol-function 'emacos-assist-web--render) #'ignore))
        (emacos-assist-web-refresh-thread))
      (should-not emacos-assist-web--in-flight)
      (should-not emacos--assist-active-surface)
      (should-not emacos-assist-web--run-id)
      (should-not emacos-assist-web--pending-key))))

(ert-deftest test-assist-web-terminal-run-settles-even-if-thread-is-busy-again ()
  (let ((emacos--assist-active-surface nil)
        (busy-snapshot
         '((thread . ((id . "thread-1") (description . "Thread")
                      (status . "processing")
                      (workspace . ((repo_label . "Assist")))))
           (messages . (((id . "m-2") (role . "user") (text . "external")
                         (state . "incomplete")))))))
    (with-temp-buffer
      (emacos-assist-web-mode)
      (setq emacos-assist-web--thread-id "thread-1"
            emacos-assist-web--run-id "run-1"
            emacos-assist-web--pending-key "retry-key"
            emacos-assist-web--submitted-text "hello"
            emacos-assist-web--pending-accepted-p t)
      (cl-letf (((symbol-function 'emacos-assist-web--request)
                 (lambda (_method _path _payload callback &rest _)
                   (funcall callback busy-snapshot nil)))
                ((symbol-function 'emacos-assist-web--write-cache) #'ignore)
                ((symbol-function 'emacos-assist-web--render) #'ignore))
        (emacos-assist-web-refresh-thread (current-buffer) "run-1"))
      (should-not emacos-assist-web--run-id)
      (should-not emacos-assist-web--pending-key))))

(ert-deftest test-assist-web-ready-refresh-keeps-an-unconfirmed-retry-key ()
  (with-temp-buffer
    (emacos-assist-web-mode)
    (setq emacos-assist-web--thread-id "thread-1"
          emacos-assist-web--pending-key "emacsos-0123456789abcdef0123456789abcdef"
          emacos-assist-web--submitted-text "hello"
          emacos-assist-web--pending-accepted-p nil)
    (cl-letf (((symbol-function 'emacos-assist-web--request)
               (lambda (_method _path _payload callback &rest _)
                 (funcall callback test-assist-web--snapshot nil)))
              ((symbol-function 'emacos-assist-web--write-cache) #'ignore)
              ((symbol-function 'emacos-assist-web--render) #'ignore))
      (emacos-assist-web-refresh-thread))
    (should emacos-assist-web--pending-key)
    (should (equal emacos-assist-web--submitted-text "hello"))))

(ert-deftest test-assist-web-final-refresh-failure-keeps-accepted-pending-turn ()
  (let ((emacos--assist-active-surface nil))
    (with-temp-buffer
      (emacos-assist-web-mode)
      (setq emacos-assist-web--thread-id "thread-1")
      (emacos-assist-web--render test-assist-web--snapshot)
      (setq emacos-assist-web--run-id "run-1"
            emacos-assist-web--pending-key "retry-key"
            emacos-assist-web--submitted-text "hello"
            emacos-assist-web--pending-accepted-p t
            emacos-assist-web--in-flight t
            emacos--assist-active-surface (current-buffer))
      (emacos-assist-web--append-pending "hello")
      (cl-letf (((symbol-function 'emacos-assist-web--request)
                 (lambda (_method _path _payload callback &rest _)
                   (funcall callback nil "offline")))
                ((symbol-function 'emacos-assist-web--save-draft) (lambda () t)))
        (emacos-assist-web--stream-finish (current-buffer)))
      (should (= (how-many "you> hello" (point-min) (point-max)) 1))
      (should emacos-assist-web--pending-accepted-p)
      (should (equal emacos-assist-web--pending-key "retry-key"))
      (should-not emacos-assist-web--in-flight)
      (should-not emacos--assist-active-surface)
      (should (string-match-p "refresh failed" emacos-assist-web--stream-status)))))

(ert-deftest test-assist-web-newer-refresh-cannot-be-overwritten-by-an-older-response ()
  (let (callbacks written rendered)
    (with-temp-buffer
      (emacos-assist-web-mode)
      (setq emacos-assist-web--thread-id "thread-1")
      (cl-letf (((symbol-function 'emacos-assist-web--request)
                 (lambda (_method _path _payload callback &rest _)
                   (push callback callbacks)))
                ((symbol-function 'emacos-assist-web--write-cache)
                 (lambda (_name value) (setq written value)))
                ((symbol-function 'emacos-assist-web--render)
                 (lambda (value &rest _) (setq rendered value))))
        (emacos-assist-web-refresh-thread)
        (emacos-assist-web-refresh-thread)
        (let ((newer (pop callbacks))
              (older (pop callbacks)))
          (funcall newer test-assist-web--snapshot nil)
          (funcall older
                   '((thread . ((id . "thread-1") (description . "stale")))
                     (messages . nil))
                   nil)))
      (should (equal (alist-get 'description (alist-get 'thread written)) "Thread"))
      (should (equal written rendered)))))

(ert-deftest test-assist-web-send-invalidates-an-older-thread-refresh ()
  (let ((emacos--assist-active-surface nil)
        refresh-callback send-callback rendered)
    (with-temp-buffer
      (emacos-assist-web-mode)
      (setq emacos-assist-web--thread-id "thread-1")
      (emacos-assist-web--write-prompt)
      (insert "new turn")
      (cl-letf (((symbol-function 'emacos-assist-web--request)
                 (lambda (method _path _payload callback &rest _)
                   (if (equal method "GET")
                       (setq refresh-callback callback)
                     (setq send-callback callback))))
                ((symbol-function 'emacos-assist-web--save-draft) (lambda () t))
                ((symbol-function 'emacos-assist-web--render)
                 (lambda (&rest _) (setq rendered t))))
        (emacos-assist-web-refresh-thread)
        (emacos-assist-web-send)
        (funcall refresh-callback test-assist-web--snapshot nil)
        (should-not rendered)
        (should send-callback)))))

(ert-deftest test-assist-web-reopening-thread-preserves-live-buffer-state ()
  (let* ((thread '((id . "thread-1") (description . "Thread")
                   (repo_label . "Assist") (status . "running")))
         (name (format "%s <thread-1>" (emacos-assist-web--thread-label thread))))
    (cl-letf (((symbol-function 'emacos-assist-web--read-cache) (lambda (&rest _) nil))
              ((symbol-function 'emacos-assist-web-refresh-thread) (lambda (&rest _) nil))
              ((symbol-function 'switch-to-buffer) (lambda (&rest _) nil)))
      (unwind-protect
          (progn
            (emacos-assist-web--show-thread thread)
            (with-current-buffer name
              (setq emacos-assist-web--in-flight t
                    emacos-assist-web--run-id "run-1"))
            (emacos-assist-web--show-thread thread)
            (with-current-buffer name
              (should emacos-assist-web--in-flight)
              (should (equal emacos-assist-web--run-id "run-1"))))
        (when (get-buffer name) (kill-buffer name))))))

(ert-deftest test-assist-web-killing-an-active-buffer-releases-the-global-run-slot ()
  (let ((emacos--assist-active-surface nil)
        (buffer (generate-new-buffer " *assist-web-active*")))
    (with-current-buffer buffer
      (emacos-assist-web-mode)
      (setq-local emacos-assist-web--in-flight t)
      (setq emacos--assist-active-surface buffer))
    (kill-buffer buffer)
    (should-not emacos--assist-active-surface)))

(ert-deftest test-assist-web-kill-flushes-the-current-draft-before-cleanup ()
  (let ((buffer (generate-new-buffer " *assist-web-draft*")) saved cleaned)
    (unwind-protect
        (with-current-buffer buffer
          (emacos-assist-web-mode)
          (emacos-assist-web--write-prompt)
          (insert "last edit")
          (cl-letf (((symbol-function 'emacos-assist-web--save-draft)
                     (lambda () (setq saved (emacos-assist-web--input)) t))
                    ((symbol-function 'emacos-assist-web--stream-cleanup)
                     (lambda (&rest _) (setq cleaned t))))
            (emacos-assist-web--buffer-killed))
          (should (equal saved "last edit"))
          (should cleaned))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest test-assist-web-new-draft-has-no-server-thread-before-send ()
  (let ((cache '((threads . nil)
                 (repositories . (((repo_key . "repo-key")
                                   (label . "Assist"))))
                 (harnesses . (((key . "deepagents")
				(label . "Deep Agents")))))))
    (cl-letf (((symbol-function 'emacos-assist-web--read-cache) (lambda (&rest _) cache))
              ((symbol-function 'completing-read)
               (lambda (prompt &rest _) (if (string-prefix-p "Harness" prompt)
                                            "Deep Agents" "Assist")))
              ((symbol-function 'switch-to-buffer) (lambda (&rest _) nil)))
      (emacos-assist-web-new-thread)
      (let ((buffer (get-buffer "*assist New thread*")))
        (unwind-protect
            (with-current-buffer buffer
              (should (derived-mode-p 'emacos-assist-web-mode))
              (should-not emacos-assist-web--thread-id)
              (should (equal emacos-assist-web--draft-repository "repo-key")))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest test-assist-web-placeholder-is-not-treated-as-a-cached-snapshot ()
  (let ((thread '((id . "thread-1") (description . "Thread")
                  (repo_label . "Assist") (status . "ready")))
        rendered-stale snapshot)
    (cl-letf (((symbol-function 'emacos-assist-web--read-cache) (lambda (&rest _) nil))
              ((symbol-function 'emacos-assist-web-refresh-thread) #'ignore)
              ((symbol-function 'switch-to-buffer) #'ignore)
              ((symbol-function 'emacos-assist-web--render)
               (lambda (value &optional stale)
                 (setq rendered-stale stale
                       emacos-assist-web--snapshot value))))
      (emacos-assist-web--show-thread thread))
    (let ((buffer (emacos-assist-web--thread-buffer "thread-1")))
      (unwind-protect
          (with-current-buffer buffer
            (setq snapshot emacos-assist-web--snapshot)
            (should-not rendered-stale)
            (should-not snapshot))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest test-assist-web-duplicate-repository-label-selects-exact-identity ()
  (let ((cache '((repositories . (((repo_key . "repo-a") (label . "Same"))
                                   ((repo_key . "repo-b") (label . "Same"))))
                 (harnesses . (((key . "deepagents")
                                (label . "Deep Agents")))))))
    (when (get-buffer "*assist New thread*") (kill-buffer "*assist New thread*"))
    (cl-letf (((symbol-function 'emacos-assist-web--read-cache) (lambda (&rest _) nil))
              ((symbol-function 'completing-read)
               (lambda (prompt &rest _)
                 (if (string-prefix-p "Harness" prompt)
                     "Deep Agents"
                   "Same [repo-b]")))
              ((symbol-function 'switch-to-buffer) #'ignore))
      (emacos-assist-web--new-thread-from-catalog cache))
    (let ((buffer (get-buffer "*assist New thread*")))
      (unwind-protect
          (with-current-buffer buffer
            (should (equal emacos-assist-web--draft-repository "repo-b")))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest test-assist-web-new-draft-reopens-without-reselecting-workspace ()
  (let ((emacos-assist-web-cache-directory (make-temp-file "assist-web-draft-" t))
        (cache '((repositories . (((repo_key . "repo-key") (label . "Assist"))))
                 (harnesses . (((key . "deepagents") (label . "Deep Agents")))))))
    (unwind-protect
        (progn
          (with-temp-buffer
            (emacos-assist-web-mode)
            (setq emacos-assist-web--draft-id "new-thread"
                  emacos-assist-web--draft-repository "repo-key"
                  emacos-assist-web--draft-harness "deepagents")
            (emacos-assist-web--write-prompt)
            (insert "saved locally")
            (should (emacos-assist-web--save-draft)))
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (&rest _) (ert-fail "saved choices should be reused")))
                    ((symbol-function 'switch-to-buffer) #'ignore))
            (emacos-assist-web--new-thread-from-catalog cache))
          (with-current-buffer "*assist New thread*"
            (should (equal (emacos-assist-web--input) "saved locally"))))
      (when (get-buffer "*assist New thread*") (kill-buffer "*assist New thread*"))
      (delete-directory emacos-assist-web-cache-directory t))))

(ert-deftest test-assist-web-new-thread-fetches-catalog-with-no-existing-thread ()
  (let ((catalog '((threads . nil)
                   (repositories . (((repo_key . "repo-key")
                                     (label . "Assist"))))
                   (harnesses . (((key . "deepagents")
                                  (label . "Deep Agents")))))))
    (cl-letf (((symbol-function 'emacos-assist-web--read-cache) (lambda (&rest _) nil))
              ((symbol-function 'emacos-assist-web--request)
               (lambda (method path _payload callback &rest _)
                 (should (equal method "GET"))
                 (should (equal path "threads"))
                 (funcall callback catalog nil)))
              ((symbol-function 'emacos-assist-web--write-cache) (lambda (&rest _) nil))
              ((symbol-function 'completing-read)
               (lambda (prompt &rest _) (if (string-prefix-p "Harness" prompt)
                                            "Deep Agents" "Assist")))
              ((symbol-function 'switch-to-buffer) (lambda (&rest _) nil)))
      (emacos-assist-web-new-thread)
      (let ((buffer (get-buffer "*assist New thread*")))
        (unwind-protect
            (with-current-buffer buffer
              (should (derived-mode-p 'emacos-assist-web-mode))
              (should (equal emacos-assist-web--draft-repository "repo-key")))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest test-assist-web-first-open-shows-visible-retryable-loading-failure ()
  (let ((emacos-assist-web--catalog nil))
    (cl-letf (((symbol-function 'emacos-assist-web--read-cache) (lambda (&rest _) nil))
              ((symbol-function 'emacos-assist-web--request)
               (lambda (_method _path _payload callback &rest _)
                 (funcall callback nil "offline"))))
      (emacos-assist-web-open-thread)
      (let ((buffer (get-buffer "*assist Threads*")))
        (unwind-protect
            (with-current-buffer buffer
              (should (string-match-p "could not be loaded" (buffer-string)))
              (should (string-match-p "C-c C-a r" (buffer-string))))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest test-assist-web-empty-loaded-catalog-offers-new-thread ()
  (let ((emacos-assist-web--catalog nil)
        (emacos-assist-web--catalog-loaded-p t)
        shown)
    (cl-letf (((symbol-function 'emacos-assist-web--load-catalog) #'ignore)
              ((symbol-function 'emacos-assist-web--show-notice)
               (lambda (_name text) (setq shown text))))
      (emacos-assist-web-open-thread))
    (should (string-match-p "C-c C-a n" shown))))

(ert-deftest test-assist-web-newer-catalog-response-wins ()
  (let ((emacos-assist-web--catalog nil)
        (emacos-assist-web--catalog-loaded-p nil)
        (emacos-assist-web--catalog-generation 0)
        callbacks)
    (cl-letf (((symbol-function 'emacos-assist-web--request)
               (lambda (_method _path _payload callback &rest _)
                 (push callback callbacks)))
              ((symbol-function 'emacos-assist-web--write-cache) #'ignore))
      (emacos-assist-web-refresh-threads)
      (emacos-assist-web-refresh-threads)
      (let ((newer (pop callbacks))
            (older (pop callbacks)))
        (funcall newer
                 '((threads . (((id . "new") (description . "New")
                                (search_description . "new")
                                (repo_label . "Assist") (status . "ready"))))
                   (repositories . nil) (harnesses . nil)) nil)
        (funcall older
                 '((threads . (((id . "old") (description . "Old")
                                (search_description . "old")
                                (repo_label . "Assist") (status . "ready"))))
                   (repositories . nil) (harnesses . nil)) nil)))
    (should (equal (alist-get 'id (car emacos-assist-web--catalog)) "new"))))

(ert-deftest test-assist-web-new-thread-fetch-cannot-overwrite-a-newer-catalog ()
  (let ((emacos-assist-web--catalog nil)
        (emacos-assist-web--catalog-loaded-p nil)
        (emacos-assist-web--catalog-generation 0)
        callbacks)
    (cl-letf (((symbol-function 'emacos-assist-web--read-cache) (lambda (&rest _) nil))
              ((symbol-function 'emacos-assist-web--request)
               (lambda (_method _path _payload callback &rest _)
                 (setq callbacks (append callbacks (list callback)))))
              ((symbol-function 'emacos-assist-web--write-cache) #'ignore)
              ((symbol-function 'emacos-assist-web--new-thread-from-catalog) #'ignore))
      (emacos-assist-web-new-thread)
      (emacos-assist-web-refresh-threads)
      (funcall
       (cadr callbacks)
       '((threads . (((id . "new") (description . "New")
                      (search_description . "new")
                      (repo_label . "Assist") (status . "ready"))))
         (repositories . nil) (harnesses . nil)) nil)
      (funcall
       (car callbacks)
       '((threads . (((id . "old") (description . "Old")
                      (search_description . "old")
                      (repo_label . "Assist") (status . "ready"))))
         (repositories . nil) (harnesses . nil)) nil))
    (should (equal (alist-get 'id (car emacos-assist-web--catalog)) "new"))))

(ert-deftest test-assist-web-malformed-catalog-does-not-replace-valid-state ()
  (let ((emacos-assist-web--catalog
         '(((id . "existing") (description . "Existing")
            (search_description . "existing")
            (repo_label . "Assist") (status . "ready"))))
        (emacos-assist-web--catalog-loaded-p t))
    (cl-letf (((symbol-function 'emacos-assist-web--request)
               (lambda (_method _path _payload callback &rest _)
                 (funcall callback "not an object" nil))))
      (emacos-assist-web-refresh-threads))
    (should (equal (alist-get 'id (car emacos-assist-web--catalog))
                   "existing"))))

(ert-deftest test-assist-web-has-one-step-two-command-prefix ()
  (should (keymapp (lookup-key (current-global-map) (kbd "C-c C-a"))))
  (dolist (binding '(("C-c C-a t" . emacos-assist-web-open-thread)
                     ("C-c C-a n" . emacos-assist-web-new-thread)
                     ("C-c C-a r" . emacos-assist-web-refresh-threads)
                     ("C-c C-a g" . emacos-assist-web-refresh-thread)
                     ("C-c C-a s" . emacos-assist-web-send)
                     ("C-c C-a o" . emacos-assist-web-load-older)
                     ("C-c C-a a" . emacos-assist-web-abort)))
    (should (eq (key-binding (kbd (car binding))) (cdr binding))))
  (dolist (key '("C-c C-a d" "C-c C-a f" "C-c C-a p" "C-c C-a i"))
    (should-not (key-binding (kbd key)))))

(ert-deftest test-assist-web-abort-cleans-up-and-refreshes ()
  (with-temp-buffer
    (emacos-assist-web-mode)
    (setq emacos-assist-web--thread-id "thread-1"
          emacos-assist-web--run-id "run-1"
          emacos-assist-web--in-flight t)
    (let (request refreshed)
      (cl-letf (((symbol-function 'emacos-assist-web--request)
                 (lambda (method path _payload callback &rest _)
                   (setq request (list method path))
                   (funcall callback nil nil)))
                ((symbol-function 'emacos-assist-web-refresh-thread)
                 (lambda (&optional buffer) (setq refreshed buffer))))
        (emacos-assist-web-abort))
      (should (equal request '("DELETE" "threads/thread-1/runs/run-1")))
      (should (eq refreshed (current-buffer)))
      (should-not emacos-assist-web--in-flight))))

(ert-deftest test-assist-web-unconfirmed-abort-retains-accepted-retry-state ()
  (let ((emacos--assist-active-surface nil))
    (with-temp-buffer
      (emacos-assist-web-mode)
      (setq emacos-assist-web--thread-id "thread-1"
            emacos-assist-web--run-id "run-1"
            emacos-assist-web--pending-key "retry-key"
            emacos-assist-web--submitted-text "hello"
            emacos-assist-web--pending-accepted-p t
            emacos-assist-web--in-flight t
            emacos--assist-active-surface (current-buffer))
      (cl-letf (((symbol-function 'emacos-assist-web--request)
                 (lambda (_method _path _payload callback &rest _)
                   (funcall callback nil "offline")))
                ((symbol-function 'emacos-assist-web-refresh-thread) #'ignore)
                ((symbol-function 'emacos-assist-web--save-draft) (lambda () t)))
        (emacos-assist-web-abort))
      (should (equal emacos-assist-web--pending-key "retry-key"))
      (should (equal emacos-assist-web--submitted-text "hello"))
      (should emacos-assist-web--pending-accepted-p)
      (should-not emacos-assist-web--in-flight))))

(ert-deftest test-assist-web-abort-during-post-cannot-target-an-old-run ()
  (with-temp-buffer
    (emacos-assist-web-mode)
    (setq emacos-assist-web--thread-id "thread-1"
          emacos-assist-web--run-id "old-run")
    (emacos-assist-web--write-prompt)
    (insert "hello")
    (let (requests)
      (cl-letf (((symbol-function 'emacos-assist-web--request)
                 (lambda (method path _payload _callback &rest _)
                   (push (list method path) requests)))
                ((symbol-function 'emacos-assist-web--save-draft) (lambda () t)))
        (emacos-assist-web-send)
        (emacos-assist-web-abort))
      (should (equal requests '(("POST" "threads/thread-1/messages"))))
      (should-not emacos-assist-web--run-id)
      (should emacos-assist-web--in-flight))))

(ert-deftest test-assist-web-cache-failure-prevents-an-unrecoverable-send ()
  (let ((emacos--assist-active-surface nil) requested)
    (with-temp-buffer
      (emacos-assist-web-mode)
      (setq emacos-assist-web--thread-id "thread-1")
      (emacos-assist-web--render test-assist-web--snapshot)
      (insert "hello")
      (cl-letf (((symbol-function 'emacos-assist-web--save-draft) (lambda () nil))
                ((symbol-function 'emacos-assist-web--request)
                 (lambda (&rest _) (setq requested t))))
        (emacos-assist-web-send))
      (should-not requested)
      (should-not emacos-assist-web--in-flight)
      (should-not emacos--assist-active-surface)
      (should (equal emacos-assist-web--stream-status
                     "not sent; local draft could not be saved")))))

(ert-deftest test-assist-web-stale-post-callback-cannot-replace-a-newer-send ()
  (let ((emacos--assist-active-surface nil))
    (with-temp-buffer
      (emacos-assist-web-mode)
      (setq emacos-assist-web--thread-id "thread-1")
      (emacos-assist-web--write-prompt)
      (insert "hello")
      (let (callbacks observed)
	(cl-letf (((symbol-function 'emacos-assist-web--request)
                   (lambda (_method _path _payload callback &rest _)
                     (setq callbacks (append callbacks (list callback)))))
                  ((symbol-function 'emacos-assist-web--save-draft) (lambda () t))
                  ((symbol-function 'emacos-assist-web--observe-run)
                   (lambda (_buffer) (setq observed t))))
          (emacos-assist-web-send)
          (setq emacos-assist-web--in-flight nil
		emacos--assist-active-surface nil)
          (emacos-assist-web-send)
          (funcall (car callbacks)
                   '((thread_id . "thread-1") (run_id . "stale-run")) nil)
          (should-not emacos-assist-web--run-id)
          (should-not observed)
          (funcall (cadr callbacks)
                   '((thread_id . "thread-1") (run_id . "current-run")) nil)
          (should (equal emacos-assist-web--run-id "current-run"))
          (should observed))))))

(ert-deftest test-assist-web-invalid-send-response-releases-active-slot-for-retry ()
  (let ((emacos--assist-active-surface nil))
    (with-temp-buffer
      (emacos-assist-web-mode)
      (setq emacos-assist-web--thread-id "thread-1")
      (emacos-assist-web--write-prompt)
      (insert "hello")
      (let (callback)
        (cl-letf (((symbol-function 'emacos-assist-web--request)
                   (lambda (_method _path _payload cb &rest _) (setq callback cb)))
                  ((symbol-function 'emacos-assist-web--save-draft) (lambda () t)))
          (emacos-assist-web-send)
          (funcall callback
                   '((thread_id . "../../wrong") (run_id . "run-1")) nil))
        (should-not emacos-assist-web--in-flight)
        (should-not emacos--assist-active-surface)
        (should (equal emacos-assist-web--thread-id "thread-1"))
        (should-not emacos-assist-web--run-id)
        (should emacos-assist-web--pending-key)))))

(ert-deftest test-assist-web-invalid-send-endpoint-releases-active-slot-for-retry ()
  (let ((emacos--assist-active-surface nil)
        (emacos-assist-web-api-url "http://assist.invalid/api/v1/phone"))
    (with-temp-buffer
      (emacos-assist-web-mode)
      (setq emacos-assist-web--thread-id "thread-1")
      (emacos-assist-web--write-prompt)
      (insert "hello")
      (cl-letf (((symbol-function 'emacos-assist-web--read-token)
                 (lambda () "safe-token"))
                ((symbol-function 'emacos-assist-web--save-draft) (lambda () t)))
        (emacos-assist-web-send))
      (should-not emacos-assist-web--in-flight)
      (should-not emacos--assist-active-surface)
      (should emacos-assist-web--pending-key)
      (should (equal emacos-assist-web--stream-status
                     "send failed; Send retries")))))

(ert-deftest test-assist-web-global-send-outside-thread-is-a-safe-noop ()
  (with-temp-buffer
    (emacos-assist-web-send)
    (should-not emacos-assist-web--in-flight)))

(ert-deftest test-assist-web-replayed-send-does-not-duplicate-local-pending-text ()
  (with-temp-buffer
    (emacos-assist-web-mode)
    (setq emacos-assist-web--thread-id "thread-1"
          emacos-assist-web--pending-key
          "emacsos-0123456789abcdef0123456789abcdef"
          emacos-assist-web--submitted-text "hello")
    (emacos-assist-web--write-prompt)
    (emacos-assist-web--append-pending "hello")
    (let (callback refreshed observed)
      (cl-letf (((symbol-function 'emacos-assist-web--request)
                 (lambda (_method _path _payload cb &rest _) (setq callback cb)))
                ((symbol-function 'emacos-assist-web--save-draft) (lambda () t))
                ((symbol-function 'emacos-assist-web-refresh-thread)
                 (lambda (&rest _) (setq refreshed t)))
                ((symbol-function 'emacos-assist-web--observe-run)
                 (lambda (&rest _) (setq observed t))))
        (emacos-assist-web-send)
        (funcall callback
                 '((thread_id . "thread-1") (run_id . "run-1") (replayed . t)) nil))
      (goto-char (point-min))
      (should (= (how-many "you> hello" (point-min) (point-max)) 1))
      (should refreshed)
      (should observed))))

(ert-deftest test-assist-web-replay-consumes-an-unrendered-submitted-prompt ()
  (let ((emacos--assist-active-surface nil))
    (with-temp-buffer
      (emacos-assist-web-mode)
      (setq emacos-assist-web--thread-id "thread-1"
            emacos-assist-web--pending-key
            "emacsos-0123456789abcdef0123456789abcdef"
            emacos-assist-web--submitted-text "hello")
      (emacos-assist-web--write-prompt)
      (insert "hello")
      (let (callback)
        (cl-letf (((symbol-function 'emacos-assist-web--request)
                   (lambda (_method _path _payload cb &rest _) (setq callback cb)))
                  ((symbol-function 'emacos-assist-web--save-draft) (lambda () t))
                  ((symbol-function 'emacos-assist-web-refresh-thread) #'ignore)
                  ((symbol-function 'emacos-assist-web--observe-run) #'ignore))
          (emacos-assist-web-send)
          (funcall callback
                   '((thread_id . "thread-1") (run_id . "run-1")
                     (replayed . t)) nil)))
      (should (= (how-many "you> hello" (point-min) (point-max)) 1))
      (should (equal (emacos-assist-web--input) "")))))

(ert-deftest test-assist-web-replay-consumes-a-submission-already-in-the-snapshot ()
  (let ((emacos--assist-active-surface nil)
        (snapshot
         '((thread . ((id . "thread-1") (description . "Thread")
                      (status . "ready")
                      (workspace . ((repo_label . "Assist")))))
           (messages . (((id . "m-1") (role . "user") (text . "hello")
                         (state . "final")))))))
    (with-temp-buffer
      (emacos-assist-web-mode)
      (setq emacos-assist-web--thread-id "thread-1")
      (emacos-assist-web--render snapshot)
      (insert "hello")
      (setq emacos-assist-web--pending-key
            "emacsos-0123456789abcdef0123456789abcdef"
            emacos-assist-web--submitted-text "hello")
      (let (callback)
        (cl-letf (((symbol-function 'emacos-assist-web--request)
                   (lambda (_method _path _payload cb &rest _) (setq callback cb)))
                  ((symbol-function 'emacos-assist-web--save-draft) (lambda () t))
                  ((symbol-function 'emacos-assist-web-refresh-thread) #'ignore)
                  ((symbol-function 'emacos-assist-web--observe-run) #'ignore))
          (emacos-assist-web-send)
          (funcall callback
                   '((thread_id . "thread-1") (run_id . "run-1")
                     (replayed . t)) nil)))
      (should (= (how-many "you> hello" (point-min) (point-max)) 1))
      (should (equal (emacos-assist-web--input) "")))))

(ert-deftest test-assist-web-restored-final-submission-is-not-a-false-pending-turn ()
  (let ((snapshot
         '((thread . ((id . "thread-1") (description . "Thread")
                      (status . "ready")
                      (workspace . ((repo_label . "Assist")))))
           (messages . (((id . "m-1") (role . "user") (text . "hello")
                         (state . "final")))))))
    (with-temp-buffer
      (emacos-assist-web-mode)
      (setq emacos-assist-web--thread-id "thread-1"
            emacos-assist-web--snapshot snapshot)
      (emacos-assist-web--write-prompt)
      (cl-letf (((symbol-function 'emacos-assist-web--read-cache)
                 (lambda (&rest _)
                   '((text . "hello")
                     (pending_key . "emacsos-0123456789abcdef0123456789abcdef")
                     (submitted_text . "hello") (pending_accepted . t)))))
        (emacos-assist-web--restore-draft))
      (should-not (string-match-p "waiting for Assist" (buffer-string)))
      (should (equal (emacos-assist-web--input) "")))))

(ert-deftest test-assist-web-does-not-overlap-the-local-chat-stream ()
  (let ((emacos--assist-active-surface 'chat) requested)
    (with-temp-buffer
      (emacos-assist-web-mode)
      (setq emacos-assist-web--thread-id "thread-1")
      (emacos-assist-web--write-prompt)
      (insert "hello")
      (cl-letf (((symbol-function 'emacos-assist-web--request)
                 (lambda (&rest _) (setq requested t))))
        (emacos-assist-web-send))
      (should-not requested)
      (should-not emacos-assist-web--in-flight))))

(ert-deftest test-assist-web-new-thread-saves-canonical-state-before-removing-local-draft ()
  (let ((emacos--assist-active-surface nil) callback events)
    (with-temp-buffer
      (emacos-assist-web-mode)
      (setq emacos-assist-web--draft-id "new-thread"
            emacos-assist-web--draft-repository "repo-key"
            emacos-assist-web--draft-harness "deepagents")
      (emacos-assist-web--write-prompt)
      (insert "hello")
      (cl-letf (((symbol-function 'emacos-assist-web--save-draft)
                 (lambda () (setq events (append events '(save))) t))
                ((symbol-function 'emacos-assist-web--delete-cache)
                 (lambda (&rest _) (setq events (append events '(delete))) t))
                ((symbol-function 'emacos-assist-web--request)
                 (lambda (_method _path _payload cb &rest _) (setq callback cb)))
                ((symbol-function 'emacos-assist-web--observe-run) #'ignore))
        (emacos-assist-web-send)
        (funcall callback '((thread_id . "thread-new") (run_id . "run-new")) nil))
      (should (equal events '(save save delete)))
      (should (eq (emacos-assist-web--thread-buffer "thread-new")
                  (current-buffer))))))

(ert-deftest test-assist-web-new-thread-acceptance-adopts-an-existing-canonical-buffer ()
  (let ((emacos--assist-active-surface nil)
        (canonical (generate-new-buffer " *assist-canonical*"))
        (draft (generate-new-buffer " *assist-new-draft*"))
        callback observed)
    (unwind-protect
        (progn
          (with-current-buffer canonical
            (emacos-assist-web-mode)
            (setq emacos-assist-web--thread-id "thread-new")
            (emacos-assist-web--write-prompt))
          (with-current-buffer draft
            (emacos-assist-web-mode)
            (setq emacos-assist-web--draft-id "new-thread"
                  emacos-assist-web--draft-repository "repo-key"
                  emacos-assist-web--draft-harness "deepagents")
            (emacos-assist-web--write-prompt)
            (insert "hello")
            (cl-letf (((symbol-function 'emacos-assist-web--save-draft) (lambda () t))
                      ((symbol-function 'emacos-assist-web--delete-cache) #'ignore)
                      ((symbol-function 'emacos-assist-web--request)
                       (lambda (_method _path _payload cb &rest _) (setq callback cb)))
                      ((symbol-function 'emacos-assist-web--observe-run)
                       (lambda (buffer) (setq observed buffer))))
              (emacos-assist-web-send)
              (switch-to-buffer draft)
              (funcall callback
                       '((thread_id . "thread-new") (run_id . "run-new")) nil)))
          (should-not (buffer-live-p draft))
          (should (eq observed canonical))
          (should (eq emacos--assist-active-surface canonical))
          (with-current-buffer canonical
            (should (equal emacos-assist-web--run-id "run-new"))
            (should (= emacos-assist-web--refresh-generation 1))
            (should (= emacos-assist-web--send-generation 1))
            (should (= emacos-assist-web--stream-generation 1))
            (should (= (how-many "you> hello" (point-min) (point-max)) 1))))
      (when (buffer-live-p draft) (kill-buffer draft))
      (when (buffer-live-p canonical) (kill-buffer canonical))
      (setq emacos--assist-active-surface nil))))

(provide 'test-assist-web)
;;; test-assist-web.el ends here
