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
  (let* ((emacsos-assist-web--catalog
          '(((id . "thread-1") (description . "🧪")
             (search_description . "Release check")
             (repo_label . "Assist") (status . "ready"))))
         (records (emacsos-assist-web--completion-records))
         (table (emacsos-assist-web--completion-table records)))
    (should (equal (all-completions "release" table)
                   '("*assist 🧪 - Assist* [ready]")))
    (should (equal (alist-get 'id (plist-get (car records) :thread)) "thread-1"))))

(ert-deftest test-assist-web-duplicate-thread-labels-show-full-identity ()
  (let* ((emacsos-assist-web--catalog
          '(((id . "thread-a-shared") (description . "Same")
             (repo_label . "Assist") (status . "ready"))
            ((id . "thread-b-shared") (description . "Same")
             (repo_label . "Assist") (status . "ready"))))
         (records (emacsos-assist-web--completion-records))
         (displays (mapcar (lambda (record) (plist-get record :display)) records)))
    (should (= (length (delete-dups (copy-sequence displays))) 2))
    (should (string-match-p "thread-a-shared" (car displays)))
    (should (string-match-p "thread-b-shared" (cadr displays)))))

(ert-deftest test-assist-web-completion-returns-all-substring-matches ()
  (let* ((emacsos-assist-web--catalog
          '(((id . "thread-1") (description . "Release one")
             (repo_label . "Assist") (status . "ready"))
            ((id . "thread-2") (description . "Release two")
             (repo_label . "EmacsOS") (status . "ready"))))
         (table (emacsos-assist-web--completion-table
                 (emacsos-assist-web--completion-records))))
    (should (= (length (all-completions "release" table)) 2))
    (should (equal (try-completion "release" table) "release"))
    (should (test-completion (car (all-completions "release" table)) table))))

(ert-deftest test-assist-web-endpoint-requires-https ()
  (let ((emacsos-assist-web-api-url "http://10.0.0.1:5050/api/v1/phone"))
    (should-error (emacsos-assist-web--endpoint "threads")))
  (let ((emacsos-assist-web-api-url "https://10.0.0.1:5050/api/v1/phone"))
    (should (equal (emacsos-assist-web--endpoint "threads")
                   "https://10.0.0.1:5050/api/v1/phone/threads"))))

(ert-deftest test-assist-web-token-cannot-inject-a-header ()
  (should (emacsos-assist-web--safe-token-p "0123abcd._~-"))
  (should-not (emacsos-assist-web--safe-token-p "token\r\nInjected: yes"))
  (should-not (emacsos-assist-web--safe-token-p "token with spaces"))
  (should-not (emacsos-assist-web--safe-token-p "token:colon"))
  (should-not (emacsos-assist-web--safe-token-p "")))

(ert-deftest test-assist-web-token-reader-removes-only-one-final-newline ()
  (let ((file (make-temp-file "assist-web-token-")))
    (unwind-protect
        (progn
          (with-temp-file file (insert "safe-token\n"))
          (let ((emacsos-assist-web-token-file file))
            (should (equal (emacsos-assist-web--read-token) "safe-token")))
          (with-temp-file file
            (insert (make-string 512 ?A) "\nX"))
          (let* ((emacsos-assist-web-token-file file)
                 (token (emacsos-assist-web--read-token)))
            (should-not (emacsos-assist-web--safe-token-p token)))
          (with-temp-file file (insert " leading-space"))
          (let* ((emacsos-assist-web-token-file file)
                 (token (emacsos-assist-web--read-token)))
            (should-not (emacsos-assist-web--safe-token-p token))))
      (delete-file file))))

(ert-deftest test-assist-web-ca-extends-trust-only-through-request-binding ()
  (let ((ca (make-temp-file "assist-web-ca-")))
    (unwind-protect
        (cl-progv '(gnutls-trustfiles) '(("system-ca"))
          (let ((emacsos-assist-web-ca-file ca))
            (should (equal (emacsos-assist-web--trustfiles)
                           (list ca "system-ca")))
            (should (equal (symbol-value 'gnutls-trustfiles)
                           '("system-ca")))))
      (delete-file ca))))

(ert-deftest test-assist-web-ca-supports-function-valued-system-trust ()
  (let ((ca (make-temp-file "assist-web-ca-")))
    (unwind-protect
        (cl-progv '(gnutls-trustfiles) '((lambda () '("system-ca")))
          (let ((emacsos-assist-web-ca-file ca))
            (should (equal (emacsos-assist-web--trustfiles)
                           (list ca "system-ca")))))
      (delete-file ca))))

(ert-deftest test-assist-web-closes-only-idle-connections-for-its-origin ()
  (let* ((emacsos-assist-web-api-url
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
          (emacsos-assist-web--close-idle-origin-connections)
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
    (should (eq (emacsos-assist-web--require-snapshot snapshot "thread-1")
                snapshot))))

(ert-deftest test-assist-web-rejects-a-non-string-thread-error ()
  (let ((snapshot (copy-tree test-assist-web--snapshot)))
    (setf (alist-get 'error (alist-get 'thread snapshot)) '((detail . "bad")))
    (should-error (emacsos-assist-web--require-snapshot snapshot "thread-1"))))

(ert-deftest test-assist-web-json-response-requires-json-content-type ()
  (with-temp-buffer
    (insert "{}")
    (setq-local url-http-response-status 200
                url-http-content-type "text/plain"
                url-http-end-of-headers (copy-marker (point-min)))
    (should-error (emacsos-assist-web--response-json (current-buffer))))
  (with-temp-buffer
    (insert "{}")
    (setq-local url-http-response-status 200
                url-http-content-type "application/json; charset=utf-8"
                url-http-end-of-headers (copy-marker (point-min)))
    (should (equal (emacsos-assist-web--response-json (current-buffer)) nil))))

(ert-deftest test-assist-web-recognizes-only-the-sanitized-run-store-response ()
  (with-temp-buffer
    (insert "{\"detail\":\"run-store-unavailable\"}")
    (setq-local url-http-response-status 503
                url-http-content-type "application/json"
                url-http-end-of-headers (copy-marker (point-min)))
    (should (emacsos-assist-web--run-store-unavailable-response-p (current-buffer)))
    (should-error (emacsos-assist-web--response-json (current-buffer))
                  :type 'error))
  (with-temp-buffer
    (insert "{\"detail\":\"other\"}")
    (setq-local url-http-response-status 503
                url-http-content-type "application/json"
                url-http-end-of-headers (copy-marker (point-min)))
    (should-not (emacsos-assist-web--run-store-unavailable-response-p (current-buffer)))))

(ert-deftest test-assist-web-status-bearing-response-requires-status-and-object ()
  "A status-bearing response requires a status and exactly one JSON object."
  (dolist (case '((nil "{}") (0 "{}") (500 "{}") (999 "{}")
                  (409 "\"running\"") (409 "[]")
                  (200 "{\"outcome\":\"cancelled\"} trailing")))
    (with-temp-buffer
      (insert (cadr case))
      (setq-local url-http-response-status (car case)
                  url-http-content-type "application/json"
                  url-http-end-of-headers (copy-marker (point-min)))
      (should-error (emacsos-assist-web--response-json (current-buffer) t))))
  (with-temp-buffer
    (insert "{}")
    (setq-local url-http-response-status 409
                url-http-content-type "application/json"
                url-http-end-of-headers (copy-marker (point-min)))
    (should (equal (emacsos-assist-web--response-json (current-buffer) t)
                   '((http_status . 409))))))

(ert-deftest test-assist-web-completion-marks-cached-source-and-state ()
  (let* ((emacsos-assist-web--catalog-stale t)
         (emacsos-assist-web--catalog
          '(((id . "thread-1") (description . "Thread")
             (repo_label . "Assist") (status . "running"))))
         (record (car (emacsos-assist-web--completion-records))))
    (should (equal (plist-get record :display)
                   "*assist Thread - Assist* [running, cached]"))))

(ert-deftest test-assist-web-cache-rejects-an-oversized-record ()
  (let ((emacsos-assist-web-cache-directory (make-temp-file "assist-web-cache-" t))
        (emacsos-assist-web-max-cache-bytes 8))
    (unwind-protect
        (should-error (emacsos-assist-web--write-cache "threads.json" '((x . "too long"))))
      (delete-directory emacsos-assist-web-cache-directory t))))

(ert-deftest test-assist-web-cache-path-does-not-create-the-cache-directory ()
  (let* ((parent (make-temp-file "assist-web-cache-parent-" t))
         (emacsos-assist-web-cache-directory (expand-file-name "missing" parent)))
    (unwind-protect
        (progn
          (should (equal (emacsos-assist-web--cache-path "threads.json")
                         (expand-file-name "missing/threads.json" parent)))
          (should-not (file-exists-p emacsos-assist-web-cache-directory)))
      (delete-directory parent t))))

(ert-deftest test-assist-web-request-reports-an-invalid-endpoint-to-its-callback ()
  (let ((emacsos-assist-web-api-url "http://assist.invalid/api/v1/phone") result)
    (cl-letf (((symbol-function 'emacsos-assist-web--read-token)
               (lambda () "safe-token")))
      (emacsos-assist-web--request
       "GET" "threads" nil
       (lambda (value error) (setq result (list value error)))))
    (should-not (car result))
    (should (string-match-p "must be HTTPS" (cadr result)))))

(ert-deftest test-assist-web-request-reports-token-read-errors-to-its-callback ()
  (let (result)
    (cl-letf (((symbol-function 'emacsos-assist-web--read-token)
               (lambda () (error "token I/O failed"))))
      (emacsos-assist-web--request
       "GET" "threads" nil
       (lambda (value error) (setq result (list value error)))))
    (should-not (car result))
    (should (equal (cadr result) "token I/O failed"))))

(ert-deftest test-assist-web-rejects-an-untrusted-thread-id-before-it-reaches-cache-path ()
  (should-error (emacsos-assist-web--snapshot-cache-name "../../outside"))
  (should (equal (emacsos-assist-web--snapshot-cache-name "thread-1")
                 "threads/thread-1.json")))

(ert-deftest test-assist-web-event-parser-keeps-target-outside-response-buffer ()
  (let ((target (generate-new-buffer " *assist-web-target*"))
        (source (generate-new-buffer " *assist-web-source*"))
        seen)
    (unwind-protect
        (with-current-buffer source
          (insert "event: terminal\ndata: {}\n\n")
          (setq-local url-http-end-of-headers (copy-marker (point-min)))
          (cl-letf (((symbol-function 'emacsos-assist-web--dispatch-event)
                     (lambda (actual-target event data)
                       (setq seen (list actual-target event data)))))
            (emacsos-assist-web--drain-events target 0))
          (should (equal seen (list target "terminal" "{}"))))
      (when (buffer-live-p target) (kill-buffer target))
      (when (buffer-live-p source) (kill-buffer source)))))

(ert-deftest test-assist-web-terminal-event-keeps-response-buffer-alive-through-drain ()
  (let ((target (generate-new-buffer " *assist-web-target*"))
        (source (generate-new-buffer " *assist-web-source*")))
    (unwind-protect
        (progn
          (with-current-buffer target
            (emacsos-assist-web-mode)
            (setq-local emacsos-assist-web--stream-response source))
          (with-current-buffer source
            (insert "event: terminal\ndata: {}\n\n")
            (setq-local url-http-end-of-headers (copy-marker (point-min)))
            (emacsos-assist-web--drain-events target 0))
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
            (emacsos-assist-web-mode))
          (let ((filter
                 (emacsos-assist-web--event-filter
                  (lambda (active _bytes)
                    (with-current-buffer source
                      (erase-buffer)
                      (insert "event: terminal\ndata: {}\n\n")
                      (setq-local url-http-response-status 200
                                  url-http-content-type "text/event-stream"
                                  url-http-end-of-headers (copy-marker (point-min))))
                    (set-process-buffer active nil))
                  target 0)))
            (cl-letf (((symbol-function 'emacsos-assist-web--dispatch-event)
                       (lambda (_target event _data) (setq seen event))))
              (funcall filter process "final")))
          (should (equal seen "terminal")))
      (when (process-live-p process) (delete-process process))
      (when (buffer-live-p target) (kill-buffer target))
      (when (buffer-live-p source) (kill-buffer source)))))

(ert-deftest test-assist-web-final-callback-waits-for-terminal-event-drain ()
  (let ((target (generate-new-buffer " *assist-web-target*"))
        (source (generate-new-buffer " *assist-web-source*"))
        (emacsos-assist-web-api-url "https://assist.invalid/api/v1/phone")
        process finished interrupted callback keepalive trustfiles)
    (unwind-protect
        (progn
          (setq process (make-pipe-process :name "assist-web-callback-order"
                                           :buffer source :noquery t))
          (with-current-buffer target
            (emacsos-assist-web-mode)
            (setq emacsos-assist-web--thread-id "thread-1"
                  emacsos-assist-web--run-id "run-1"
                  emacsos-assist-web--in-flight t))
          (cl-letf (((symbol-function 'emacsos-assist-web--read-token)
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
                    ((symbol-function 'emacsos-assist-web--trustfiles)
                     (lambda () '("assist-ca" "system-ca")))
                    ((symbol-function 'emacsos-assist-web--stream-finish)
                     (lambda (buffer)
                       (setq finished t)
                       (with-current-buffer buffer
                         (cl-incf emacsos-assist-web--stream-generation))))
                    ((symbol-function 'emacsos-assist-web--stream-interrupted)
                     (lambda (&rest _) (setq interrupted t))))
            (emacsos-assist-web--observe-run target)
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

(ert-deftest test-assist-web-stream-reports-an-invalid-token ()
  (let (interrupted)
    (with-temp-buffer
      (let ((target (current-buffer)))
        (cl-letf (((symbol-function 'emacsos-assist-web--read-token)
                   (lambda () "invalid token"))
                  ((symbol-function 'emacsos-assist-web--stream-interrupted)
                   (lambda (buffer status)
                     (setq interrupted (list buffer status)))))
          (emacsos-assist-web--observe-run target)
          (should (equal interrupted
                         (list target "token missing or invalid"))))))))

(ert-deftest test-assist-web-event-parser-bounds-each-record-not-whole-callback ()
  (let ((target (generate-new-buffer " *assist-web-target*"))
        (source (generate-new-buffer " *assist-web-source*"))
        (emacsos-assist-web-max-event-bytes 32)
        seen)
    (unwind-protect
        (with-current-buffer source
          (insert "event: status\ndata: {}\n\nevent: status\ndata: {}\n\n")
          (setq-local url-http-end-of-headers (copy-marker (point-min)))
          (cl-letf (((symbol-function 'emacsos-assist-web--dispatch-event)
                     (lambda (_target event _data) (push event seen))))
            (emacsos-assist-web--drain-events target 0))
          (should (equal seen '("status" "status"))))
      (when (buffer-live-p target) (kill-buffer target))
      (when (buffer-live-p source) (kill-buffer source)))))

(ert-deftest test-assist-web-event-parser-tiny-fragments-scan-only-new-suffix ()
  "A fragmented record is dispatched once without quadratic retained-buffer copies."
  (let ((target (generate-new-buffer " *assist-web-target*"))
        (source (generate-new-buffer " *assist-web-source*"))
        (payload (concat "event: status\ndata: {\"status\":\"working\"}\n\n"))
        (copied 0) seen)
    (unwind-protect
        (with-current-buffer source
          (setq-local url-http-end-of-headers (copy-marker (point-min)))
          (let ((original (symbol-function 'buffer-substring-no-properties)))
            (cl-letf (((symbol-function 'buffer-substring-no-properties)
                       (lambda (start end)
                         (cl-incf copied (- end start))
                         (funcall original start end)))
                      ((symbol-function 'emacsos-assist-web--dispatch-event)
                       (lambda (_target event _data) (push event seen))))
              (dolist (byte (string-to-list payload))
                (goto-char (point-max))
                (insert-char byte)
                (emacsos-assist-web--drain-events target 0 1))))
          ;; The old parser copied the whole unfinished record per callback.
          ;; This implementation copies it once, after the delimiter arrives.
          (should (< copied (* 3 (length payload))))
          (should (equal seen '("status"))))
      (when (buffer-live-p target) (kill-buffer target))
      (when (buffer-live-p source) (kill-buffer source)))))

(ert-deftest test-assist-web-raw-filter-rejects-encoded-response-before-url-filter ()
  (let (forwarded rejected)
    (funcall
     (emacsos-assist-web--guarded-filter
      (lambda (&rest _) (setq forwarded t))
      (lambda (_process problem) (setq rejected problem)))
     nil "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\ncompressed")
    (should-not forwarded)
    (should (equal rejected "Assist Web encoded responses are not accepted"))))

(ert-deftest test-assist-web-raw-filter-forwards-body-chunks-after-headers ()
  (let (forwarded rejected)
    (let ((filter
           (emacsos-assist-web--guarded-filter
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
     (emacsos-assist-web--guarded-filter
      (lambda (&rest _) (setq forwarded t))
      (lambda (_process problem) (setq rejected problem)))
     nil (concat "HTTP/1.1 200 OK\r\n"
                 "Content-Encoding : identity\r\n"
                 "Content-Encoding: gzip\r\n\r\ncompressed"))
    (should-not forwarded)
    (should (equal rejected "Assist Web encoded responses are not accepted"))))

(ert-deftest test-assist-web-json-request-disables-redirects-and-encoding ()
  (let ((emacsos-assist-web--requests nil)
        (response (generate-new-buffer " *assist-web-request*"))
        encoding keepalive trustfiles)
    (unwind-protect
        (cl-letf (((symbol-function 'emacsos-assist-web--read-token)
                   (lambda () "token"))
                  ((symbol-function 'url-retrieve)
                   (lambda (&rest _)
                     (setq encoding url-mime-encoding-string
                           keepalive url-http-attempt-keepalives
                           trustfiles gnutls-trustfiles)
                     response))
                  ((symbol-function 'emacsos-assist-web--trustfiles)
                   (lambda () '("assist-ca" "system-ca")))
                  ((symbol-function 'run-at-time) (lambda (&rest _) nil)))
          (emacsos-assist-web--request "GET" "threads" nil #'ignore)
          (with-current-buffer response
            (should (= url-max-redirections 0)))
          (should (equal encoding "identity"))
          (should-not keepalive)
          (should (equal trustfiles '("assist-ca" "system-ca"))))
      (when (buffer-live-p response) (kill-buffer response)))))

(ert-deftest test-assist-web-json-request-has-a-global-concurrency-bound ()
  (let ((emacsos-assist-web--requests '(one two))
        (emacsos-assist-web-max-concurrent-requests 2)
        result)
    (cl-letf (((symbol-function 'emacsos-assist-web--read-token)
               (lambda () "token")))
      (emacsos-assist-web--request
       "GET" "threads" nil
       (lambda (value error) (setq result (list value error)))))
    (should (equal result
                   '(nil "Too many Assist Web requests are already running")))))

(ert-deftest test-assist-web-json-request-reports-an-invalid-token ()
  (let (result)
    (cl-letf (((symbol-function 'emacsos-assist-web--read-token)
               (lambda () "invalid token")))
      (emacsos-assist-web--request
       "GET" "threads" nil
       (lambda (value error) (setq result (list value error)))))
    (should (equal result
                   '(nil "Assist Web token is missing or invalid")))))

(ert-deftest test-assist-web-raw-filter-bounds-an-unterminated-header ()
  (let ((emacsos-assist-web-max-header-bytes 8) forwarded rejected)
    (funcall
     (emacsos-assist-web--guarded-filter
      (lambda (&rest _) (setq forwarded t))
      (lambda (_process problem) (setq rejected problem))
      t)
     nil "HTTP/1.1 200")
    (should-not forwarded)
    (should (equal rejected "Assist Web response headers are too large"))))

(ert-deftest test-assist-web-header-bound-does-not-count-same-chunk-body ()
  (let ((emacsos-assist-web-max-header-bytes 32) forwarded rejected)
    (funcall
     (emacsos-assist-web--guarded-filter
      (lambda (&rest _) (setq forwarded t))
      (lambda (_process problem) (setq rejected problem))
      t)
     nil (concat "HTTP/1.1 200 OK\r\n\r\n" (make-string 128 ?x)))
    (should forwarded)
    (should-not rejected)))

(ert-deftest test-assist-web-raw-filter-bounds-a-stalled-json-503-response ()
  "A non-SSE error response cannot grow url-http's retained stream forever."
  (let ((emacsos-assist-web-max-response-bytes 128) (forwarded 0) rejected)
    (let ((filter
           (emacsos-assist-web--guarded-filter
            (lambda (&rest _) (cl-incf forwarded))
            (lambda (_process problem) (setq rejected problem))
            t)))
      (funcall filter nil (concat "HTTP/1.1 503 Service Unavailable\r\n"
                                  "Content-Type: application/json\r\n\r\n"))
      (funcall filter nil (make-string 32 ?x))
      (funcall filter nil (make-string 32 ?x)))
    (should (= forwarded 2))
    (should (equal rejected "Assist Web response is too large"))))

(ert-deftest test-assist-web-raw-filter-does-not-trust-a-lookalike-content-type ()
  "Only the exact Content-Type header may make a response stream unbounded."
  (let ((emacsos-assist-web-max-response-bytes 128) (forwarded 0) rejected)
    (let ((filter
           (emacsos-assist-web--guarded-filter
            (lambda (&rest _) (cl-incf forwarded))
            (lambda (_process problem) (setq rejected problem))
            t)))
      (funcall filter nil (concat "HTTP/1.1 200 OK\r\n"
                                  "X-Content-Type: text/event-stream\r\n\r\n"))
      (funcall filter nil (make-string 128 ?x)))
    (should (= forwarded 1))
    (should (equal rejected "Assist Web response is too large"))))

(ert-deftest test-assist-web-raw-filter-allows-batched-bounded-sse-events ()
  "TCP batching does not turn several valid events into one oversized event."
  (let* ((emacsos-assist-web-max-event-bytes 64)
         (event "event: status\ndata: {\"s\":\"xxxxxxxxxxxxxxxx\"}\n\n")
         (body (apply #'concat (make-list 1600 event)))
         forwarded rejected)
    (should (< (string-bytes event) emacsos-assist-web-max-event-bytes))
    (should (> (string-bytes body) (* 64 1024)))
    (funcall
     (emacsos-assist-web--guarded-filter
      (lambda (_process bytes) (setq forwarded bytes))
      (lambda (_process problem) (setq rejected problem))
      t)
     nil
     (concat "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n" body))
    (should forwarded)
    (should-not rejected)))

(ert-deftest test-assist-web-raw-filter-rejects-one-oversized-sse-record-before-forwarding ()
  "A bad incomplete record never reaches url-http's retained response buffer."
  (let ((emacsos-assist-web-max-event-bytes 32) forwarded rejected)
    (funcall
     (emacsos-assist-web--guarded-filter
      (lambda (&rest _) (setq forwarded t))
      (lambda (_process problem) (setq rejected problem))
      t)
     nil
     (concat "HTTP/1.1 200 OK\r\nContent-Type: text/event-stream\r\n\r\n"
             (make-string 33 ?x)))
    (should-not forwarded)
    (should (equal rejected "Assist event is too large"))))

(ert-deftest test-assist-web-render-preserves-draft-and-updates-status-in-place ()
  (let ((emacsos-assist-web-cache-directory (make-temp-file "assist-web-render-" t)))
    (unwind-protect
        (with-temp-buffer
          (emacsos-assist-web-mode)
          (emacsos-assist-web--render test-assist-web--snapshot t)
          (insert "next draft")
          (emacsos-assist-web--set-status "running")
          (should (equal (emacsos-assist-web--input) "next draft"))
          (should (string-match-p "\\[running\\]" (buffer-string)))
          (should (string-match-p "\\[cached\\]" (buffer-string))))
      (delete-directory emacsos-assist-web-cache-directory t))))

(ert-deftest test-assist-web-reopened-incomplete-message-recreates-assistant-markers ()
  "A resumed accepted Run renders live deltas after its canonical user turn."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq emacsos-assist-web--thread-id "thread-1"
          emacsos-assist-web--pending-key "emacsos-0123456789abcdef0123456789abcdef"
          emacsos-assist-web--submitted-text "hello"
          emacsos-assist-web--pending-accepted-p t
          emacsos-assist-web--run-id "run-1")
    (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) (lambda () t)))
      (emacsos-assist-web--render
       '((thread . ((id . "thread-1") (description . "Thread")
                    (status . "processing")
                    (workspace . ((repo_label . "Assist")))))
         (messages . (((id . "m-1") (role . "user") (text . "hello")
                       (state . "incomplete")))))))
    (should emacsos-assist-web--pending-rendered-p)
    (should (markerp emacsos-assist-web--assistant-start))
    (should (markerp emacsos-assist-web--assistant-end))
    (emacsos-assist-web--dispatch-event (current-buffer) "assistant-reset"
                                       "{\"attempt\":1}")
    (emacsos-assist-web--dispatch-event (current-buffer) "assistant-delta"
                                       "{\"attempt\":1,\"index\":1,\"text\":\"live\"}")
    (should (string-match-p "bot> live" (buffer-string)))))

(ert-deftest test-assist-web-input-preserves-exact-multiline-text ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq emacsos-assist-web--thread-id "thread-1")
    (setq emacsos-assist-web--status-start (copy-marker (point) nil))
    (insert "[ready]")
    (setq emacsos-assist-web--status-end (copy-marker (point) nil))
    (emacsos-assist-web--write-prompt)
    (insert "  first line\nsecond line  \n")
    (should (equal (emacsos-assist-web--input)
                   "  first line\nsecond line  \n"))))

(ert-deftest test-assist-web-physical-ret-remains-newline-without-an-object ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (insert "draft")
    (call-interactively (lookup-key (current-local-map) (kbd "RET")))
    (should (string-suffix-p "draft\n" (buffer-string)))))

(ert-deftest test-assist-web-pending-transcript-removes-the-old-prompt ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (emacsos-assist-web--write-prompt)
    (insert "hello")
    (emacsos-assist-web--append-pending "hello")
    (should (= (how-many "^> " (point-min) (point-max)) 1))
    (should (= (how-many "you> hello" (point-min) (point-max)) 1))))

(ert-deftest test-assist-web-render-rejects-a-mismatched-snapshot-identity ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq emacsos-assist-web--thread-id "thread-1")
    (should-error
     (emacsos-assist-web--render
      '((thread . ((id . "thread-2") (description . "Wrong")
                   (status . "ready") (workspace . nil)))
        (messages . nil))))))

(ert-deftest test-assist-web-invalid-cached-retry-key-is-not-restored ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq emacsos-assist-web--thread-id "thread-1")
    (emacsos-assist-web--write-prompt)
    (cl-letf (((symbol-function 'emacsos-assist-web--read-cache)
               (lambda (&rest _)
                 '((text . "draft") (pending_key . "bad\r\nInjected: yes")
                   (submitted_text . "draft")))))
      (emacsos-assist-web--restore-draft))
    (should-not emacsos-assist-web--pending-key)
    (should-not emacsos-assist-web--submitted-text)
    (should (equal (emacsos-assist-web--input) "draft"))))

(ert-deftest test-assist-web-restores-an-accepted-pending-message-visibly ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq emacsos-assist-web--thread-id "thread-1")
    (setq emacsos-assist-web--status-start (copy-marker (point) nil))
    (insert "[ready]")
    (setq emacsos-assist-web--status-end (copy-marker (point) nil))
    (emacsos-assist-web--write-prompt)
    (cl-letf (((symbol-function 'emacsos-assist-web--read-cache)
               (lambda (&rest _)
                 '((text . "")
                   (pending_key . "emacsos-0123456789abcdef0123456789abcdef")
                   (submitted_text . "already accepted")
                   (pending_accepted . t)))))
      (emacsos-assist-web--restore-draft))
    (should (string-match-p "you> already accepted" (buffer-string)))
    (should (string-match-p "observation interrupted" (buffer-string)))
    (should emacsos-assist-web--pending-accepted-p)))

(ert-deftest test-assist-web-does-not-duplicate-canonical-incomplete-message-on-restore ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq emacsos-assist-web--thread-id "thread-1"
          emacsos-assist-web--snapshot
          '((messages . (((role . "user") (state . "incomplete")
                          (text . "already accepted"))))))
    (insert "you> already accepted\n")
    (setq emacsos-assist-web--status-start (copy-marker (point) nil))
    (insert "[processing]")
    (setq emacsos-assist-web--status-end (copy-marker (point) nil))
    (emacsos-assist-web--write-prompt)
    ;; `--render` owns this marker after it has actually drawn the incomplete
    ;; submission; text equality in an unrendered snapshot is not enough.
    (setq emacsos-assist-web--pending-rendered-p t)
    (cl-letf (((symbol-function 'emacsos-assist-web--read-cache)
               (lambda (&rest _)
                 '((text . "")
                   (pending_key . "emacsos-0123456789abcdef0123456789abcdef")
                   (submitted_text . "already accepted")
                   (pending_accepted . t)))))
      (emacsos-assist-web--restore-draft))
    (should (= (how-many "you> already accepted" (point-min) (point-max)) 1))))

(ert-deftest test-assist-web-editing-after-a-failed-send-mints-a-new-retry-identity ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq emacsos-assist-web--pending-key "old-key"
          emacsos-assist-web--submitted-text "old")
    (emacsos-assist-web--write-prompt)
    (insert "new")
    (emacsos-assist-web--after-change)
    (should-not emacsos-assist-web--pending-key)
    (should-not emacsos-assist-web--submitted-text)))

(ert-deftest test-assist-web-edited-failed-retry-renders-a-fresh-pending-turn ()
  "A distinct retry cannot stream into the failed turn's old markers."
  (let ((emacsos--assist-active-surface nil))
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1"
            emacsos-assist-web--pending-key
            "emacsos-0123456789abcdef0123456789abcdef"
            emacsos-assist-web--submitted-text "old")
      (emacsos-assist-web--write-prompt)
      (emacsos-assist-web--append-pending "old")
      (should emacsos-assist-web--pending-rendered-p)
      (insert "new")
      (emacsos-assist-web--after-change)
      (should-not emacsos-assist-web--pending-rendered-p)
      (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) (lambda () t))
                ((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload callback &rest _)
                   (funcall callback '((thread_id . "thread-1") (run_id . "run-2")
                                       (live_text . t)) nil)))
                ((symbol-function 'emacsos-assist-web--observe-run) #'ignore))
        (emacsos-assist-web-send))
      (should (= (how-many "you> old" (point-min) (point-max)) 1))
      (should (= (how-many "you> new" (point-min) (point-max)) 1))
      (goto-char (marker-position emacsos-assist-web--assistant-start))
      (should (> (point) (string-match "you> new" (buffer-string)))))))

(ert-deftest test-assist-web-interrupted-observation-retains-the-exact-retry ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (emacsos-assist-web--write-prompt)
    (setq emacsos-assist-web--pending-key "retry-key"
          emacsos-assist-web--submitted-text "message"
          emacsos-assist-web--in-flight t
          emacsos--assist-active-surface (current-buffer))
    (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) (lambda () nil)))
      (emacsos-assist-web--stream-interrupted (current-buffer) "observation disconnected"))
    (should (equal emacsos-assist-web--pending-key "retry-key"))
    (should (equal emacsos-assist-web--submitted-text "message"))
    (should-not emacsos-assist-web--in-flight)
    (should (equal emacsos-assist-web--stream-status "observation disconnected"))))

(ert-deftest test-assist-web-truncation-and-interruption-keep-streamed-partial ()
  "A nonterminal notice or failed observer must not erase visible evidence."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (emacsos-assist-web--write-prompt)
    (emacsos-assist-web--append-pending "hello")
    (emacsos-assist-web--reset-assistant 1)
    (emacsos-assist-web--append-delta 1 1 "partial answer")
    (emacsos-assist-web--dispatch-event (current-buffer) "assistant-truncated" "{}")
    (should (string-match-p "partial answer" (buffer-string)))
    (emacsos-assist-web--stream-interrupted (current-buffer) "observation disconnected")
    (should (string-match-p "partial answer" (buffer-string)))))

(ert-deftest test-assist-web-requires-reset-before-first-delta ()
  "A stale replay cannot append into a queued region without its reset boundary."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (emacsos-assist-web--write-prompt)
    (emacsos-assist-web--append-pending "hello")
    (emacsos-assist-web--append-delta 1 1 "stale")
    (should-not (string-match-p "stale" (buffer-string)))
    (should (equal emacsos-assist-web--stream-status
                   "Assist stream is missing its reset; refresh to reconcile"))))

(ert-deftest test-assist-web-indexed-replay-rejects-duplicate-and-gap-but-keeps-partial ()
  "Duplicate or other non-next indexes keep existing stream evidence visible."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (emacsos-assist-web--write-prompt)
    (emacsos-assist-web--append-pending "hello")
    (emacsos-assist-web--reset-assistant 1)
    (emacsos-assist-web--append-delta 1 1 "first")
    ;; Same-attempt duplicate is not another next delta, so reconcile rather
    ;; than risking duplicated model text.
    (emacsos-assist-web--append-delta 1 1 "duplicate")
    (should (string-match-p "first" (buffer-string)))
    (should-not (string-match-p "duplicate" (buffer-string)))
    (should (string-match-p "gap" emacsos-assist-web--stream-status))
    ;; A later replay reset deliberately replaces the provisional attempt.
    (emacsos-assist-web--reset-assistant 2)
    (emacsos-assist-web--append-delta 2 1 "retry")
    (should (string-match-p "retry" (buffer-string)))
    (should-not (string-match-p "first" (buffer-string)))
    (emacsos-assist-web--append-delta 2 3 "gap")
    (should (string-match-p "retry" (buffer-string)))
    (should-not (string-match-p "gap\\n" (buffer-string)))))

(ert-deftest test-assist-web-interruptions-keep-partial-and-mark-it-unverified ()
  "Every parser/transport interruption retains partial text instead of blanking it."
  (dolist (reason '("observation disconnected" "invalid Assist delta"
                    "Assist event is too large" "Assist observation was rejected"
                    "Assist observation timed out"))
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (emacsos-assist-web--write-prompt)
      (emacsos-assist-web--append-pending "hello")
      (emacsos-assist-web--reset-assistant 1)
      (emacsos-assist-web--append-delta 1 1 "partial")
      (emacsos-assist-web--stream-interrupted (current-buffer) reason)
      (should (string-match-p "partial" (buffer-string)))
      (should (equal emacsos-assist-web--stream-status reason)))))

(ert-deftest test-assist-web-malformed-and-oversized-deltas-keep-the-real-partial ()
  "The event adapter, not only its shared failure helper, retains prior text."
  (dolist (data (list "{not json}"
                      (json-encode `((attempt . 1) (index . 2)
                                     (text . ,(make-string (1+ (* 16 1024)) ?x))))))
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (emacsos-assist-web--write-prompt)
      (emacsos-assist-web--append-pending "hello")
      (emacsos-assist-web--reset-assistant 1)
      (emacsos-assist-web--append-delta 1 1 "partial")
      (emacsos-assist-web--dispatch-event (current-buffer) "assistant-delta" data)
      (should (string-match-p "partial" (buffer-string)))
      (should (equal emacsos-assist-web--stream-status "invalid Assist delta")))))

(ert-deftest test-assist-web-history-merges-chronologically-and-keeps-page-cursor ()
  (let ((emacsos-assist-web-cache-directory (make-temp-file "assist-web-history-" t))
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
          (emacsos-assist-web-mode)
          (setq emacsos-assist-web--thread-id "thread-1")
          (cl-letf (((symbol-function 'emacsos-assist-web--read-cache)
                     (lambda (&rest _) snapshot))
                    ((symbol-function 'emacsos-assist-web--write-cache)
                     (lambda (&rest _) (ert-fail "history pages must not be cached")))
                    ((symbol-function 'emacsos-assist-web--request)
                     (lambda (method path _payload callback &rest _)
                       (should (equal method "GET"))
                       (should (string-suffix-p "before=cursor-1" path))
                       (funcall callback page nil)))
                    ((symbol-function 'emacsos-assist-web--render)
                     (lambda (value &rest _) (setq rendered value))))
            (emacsos-assist-web-load-older))
          (should (equal (mapcar (lambda (message) (alist-get 'id message))
                                 (alist-get 'messages rendered))
                         '("m-0" "m-1")))
          (should (equal (alist-get 'next_before rendered) "cursor-0")))
      (delete-directory emacsos-assist-web-cache-directory t))))

(ert-deftest test-assist-web-history-rejects-a-mismatched-thread-page ()
  (let ((snapshot (copy-tree test-assist-web--snapshot)) rendered)
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1")
      (cl-letf (((symbol-function 'emacsos-assist-web--read-cache)
                 (lambda (&rest _) snapshot))
                ((symbol-function 'emacsos-assist-web--request)
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
                ((symbol-function 'emacsos-assist-web--render)
                 (lambda (&rest _) (setq rendered t))))
        (emacsos-assist-web-load-older))
      (should-not rendered))))

(ert-deftest test-assist-web-terminal-refresh-releases-a-live-observer ()
  (let ((emacsos--assist-active-surface nil))
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1"
            emacsos-assist-web--run-id "run-1"
            emacsos-assist-web--pending-key "retry-key"
            emacsos-assist-web--submitted-text "hello"
            emacsos-assist-web--pending-accepted-p t
            emacsos-assist-web--in-flight t
            emacsos--assist-active-surface (current-buffer))
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload callback &rest _)
                   (funcall callback test-assist-web--snapshot nil)))
                ((symbol-function 'emacsos-assist-web--write-cache) #'ignore)
                ((symbol-function 'emacsos-assist-web--render) #'ignore))
        (emacsos-assist-web-refresh-thread))
      (should-not emacsos-assist-web--in-flight)
      (should-not emacsos--assist-active-surface)
      (should-not emacsos-assist-web--run-id)
      (should-not emacsos-assist-web--pending-key))))

(ert-deftest test-assist-web-terminal-run-settles-even-if-thread-is-busy-again ()
  (let ((emacsos--assist-active-surface nil)
        (busy-snapshot
         '((thread . ((id . "thread-1") (description . "Thread")
                      (status . "processing")
                      (workspace . ((repo_label . "Assist")))))
           (messages . (((id . "m-2") (role . "user") (text . "external")
                         (state . "incomplete")))))))
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1"
            emacsos-assist-web--run-id "run-1"
            emacsos-assist-web--pending-key "retry-key"
            emacsos-assist-web--submitted-text "hello"
            emacsos-assist-web--pending-accepted-p t)
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload callback &rest _)
                   (funcall callback busy-snapshot nil)))
                ((symbol-function 'emacsos-assist-web--write-cache) #'ignore)
                ((symbol-function 'emacsos-assist-web--render) #'ignore))
        (emacsos-assist-web-refresh-thread (current-buffer) "run-1"))
      (should-not emacsos-assist-web--run-id)
      (should-not emacsos-assist-web--pending-key))))

(ert-deftest test-assist-web-busy-refresh-keeps-live-provisional-markers ()
  "A nonterminal snapshot cannot redraw underneath its active SSE observer."
  (let ((busy-snapshot
         '((thread . ((id . "thread-1") (description . "Thread")
                      (status . "processing")
                      (workspace . ((repo_label . "Assist")))))
           (messages . nil)))
        rendered)
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1"
            emacsos-assist-web--run-id "run-1"
            emacsos-assist-web--pending-key "retry-key"
            emacsos-assist-web--submitted-text "hello"
            emacsos-assist-web--pending-accepted-p t
            emacsos-assist-web--in-flight t)
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload callback &rest _)
                   (funcall callback busy-snapshot nil)))
                ((symbol-function 'emacsos-assist-web--try-write-cache) #'ignore)
                ((symbol-function 'emacsos-assist-web--render)
                 (lambda (&rest _) (setq rendered t))))
        (emacsos-assist-web-refresh-thread))
      (should-not rendered)
      (should emacsos-assist-web--in-flight)
      (should (equal emacsos-assist-web--run-id "run-1")))))

(ert-deftest test-assist-web-ready-refresh-keeps-an-unconfirmed-retry-key ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq emacsos-assist-web--thread-id "thread-1"
          emacsos-assist-web--pending-key "emacsos-0123456789abcdef0123456789abcdef"
          emacsos-assist-web--submitted-text "hello"
          emacsos-assist-web--pending-accepted-p nil)
    (cl-letf (((symbol-function 'emacsos-assist-web--request)
               (lambda (_method _path _payload callback &rest _)
                 (funcall callback test-assist-web--snapshot nil)))
              ((symbol-function 'emacsos-assist-web--write-cache) #'ignore)
              ((symbol-function 'emacsos-assist-web--render) #'ignore))
      (emacsos-assist-web-refresh-thread))
    (should emacsos-assist-web--pending-key)
    (should (equal emacsos-assist-web--submitted-text "hello"))))

(ert-deftest test-assist-web-final-refresh-failure-keeps-accepted-pending-turn ()
  (let ((emacsos--assist-active-surface nil))
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1")
      (emacsos-assist-web--render test-assist-web--snapshot)
      (setq emacsos-assist-web--run-id "run-1"
            emacsos-assist-web--pending-key "retry-key"
            emacsos-assist-web--submitted-text "hello"
            emacsos-assist-web--pending-accepted-p t
            emacsos-assist-web--in-flight t
            emacsos--assist-active-surface (current-buffer))
      (emacsos-assist-web--append-pending "hello")
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload callback &rest _)
                   (funcall callback nil "offline")))
                ((symbol-function 'emacsos-assist-web--save-draft) (lambda () t)))
        (emacsos-assist-web--stream-finish (current-buffer)))
      (should (= (how-many "you> hello" (point-min) (point-max)) 1))
      (should emacsos-assist-web--pending-accepted-p)
      (should (equal emacsos-assist-web--pending-key "retry-key"))
      (should-not emacsos-assist-web--in-flight)
      (should-not emacsos--assist-active-surface)
      (should (string-match-p "refresh failed" emacsos-assist-web--stream-status)))))

(ert-deftest test-assist-web-newer-refresh-cannot-be-overwritten-by-an-older-response ()
  (let (callbacks written rendered)
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1")
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload callback &rest _)
                   (push callback callbacks)))
                ((symbol-function 'emacsos-assist-web--write-cache)
                 (lambda (_name value) (setq written value)))
                ((symbol-function 'emacsos-assist-web--render)
                 (lambda (value &rest _) (setq rendered value))))
        (emacsos-assist-web-refresh-thread)
        (emacsos-assist-web-refresh-thread)
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
  (let ((emacsos--assist-active-surface nil)
        refresh-callback send-callback rendered)
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1")
      (emacsos-assist-web--write-prompt)
      (insert "new turn")
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (method _path _payload callback &rest _)
                   (if (equal method "GET")
                       (setq refresh-callback callback)
                     (setq send-callback callback))))
                ((symbol-function 'emacsos-assist-web--save-draft) (lambda () t))
                ((symbol-function 'emacsos-assist-web--render)
                 (lambda (&rest _) (setq rendered t))))
        (emacsos-assist-web-refresh-thread)
        (emacsos-assist-web-send)
        (funcall refresh-callback test-assist-web--snapshot nil)
        (should-not rendered)
        (should send-callback)))))

(ert-deftest test-assist-web-reopening-thread-preserves-live-buffer-state ()
  (let* ((thread '((id . "thread-1") (description . "Thread")
                   (repo_label . "Assist") (status . "running")))
         (name (format "%s <thread-1>" (emacsos-assist-web--thread-label thread))))
    (cl-letf (((symbol-function 'emacsos-assist-web--read-cache) (lambda (&rest _) nil))
              ((symbol-function 'emacsos-assist-web-refresh-thread) (lambda (&rest _) nil))
              ((symbol-function 'switch-to-buffer) (lambda (&rest _) nil)))
      (unwind-protect
          (progn
            (emacsos-assist-web--show-thread thread)
            (with-current-buffer name
              (setq emacsos-assist-web--in-flight t
                    emacsos-assist-web--run-id "run-1"))
            (emacsos-assist-web--show-thread thread)
            (with-current-buffer name
              (should emacsos-assist-web--in-flight)
              (should (equal emacsos-assist-web--run-id "run-1"))))
        (when (get-buffer name) (kill-buffer name))))))

(ert-deftest test-assist-web-killing-an-active-buffer-releases-the-global-run-slot ()
  (let ((emacsos--assist-active-surface nil)
        (buffer (generate-new-buffer " *assist-web-active*")))
    (with-current-buffer buffer
      (emacsos-assist-web-mode)
      (setq-local emacsos-assist-web--in-flight t)
      (setq emacsos--assist-active-surface buffer))
    (kill-buffer buffer)
    (should-not emacsos--assist-active-surface)))

(ert-deftest test-assist-web-kill-flushes-the-current-draft-before-cleanup ()
  (let ((buffer (generate-new-buffer " *assist-web-draft*")) saved cleaned)
    (unwind-protect
        (with-current-buffer buffer
          (emacsos-assist-web-mode)
          (emacsos-assist-web--write-prompt)
          (insert "last edit")
          (cl-letf (((symbol-function 'emacsos-assist-web--save-draft)
                     (lambda () (setq saved (emacsos-assist-web--input)) t))
                    ((symbol-function 'emacsos-assist-web--stream-cleanup)
                     (lambda (&rest _) (setq cleaned t))))
            (emacsos-assist-web--buffer-killed))
          (should (equal saved "last edit"))
          (should cleaned))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest test-assist-web-new-draft-has-no-server-thread-before-send ()
  (let ((cache '((threads . nil)
                 (repositories . (((repo_key . "repo-key")
                                   (label . "Assist"))))
                 (harnesses . (((key . "deepagents")
				(label . "Deep Agents")))))))
    (cl-letf (((symbol-function 'emacsos-assist-web--read-cache) (lambda (&rest _) cache))
              ((symbol-function 'completing-read)
               (lambda (prompt &rest _) (if (string-prefix-p "Harness" prompt)
                                            "Deep Agents" "Assist")))
              ((symbol-function 'switch-to-buffer) (lambda (&rest _) nil)))
      (emacsos-assist-web-new-thread)
      (let ((buffer (get-buffer "*assist New thread*")))
        (unwind-protect
            (with-current-buffer buffer
              (should (derived-mode-p 'emacsos-assist-web-mode))
              (should-not emacsos-assist-web--thread-id)
              (should (equal emacsos-assist-web--draft-repository "repo-key")))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest test-assist-web-placeholder-is-not-treated-as-a-cached-snapshot ()
  (let ((thread '((id . "thread-1") (description . "Thread")
                  (repo_label . "Assist") (status . "ready")))
        rendered-stale snapshot)
    (cl-letf (((symbol-function 'emacsos-assist-web--read-cache) (lambda (&rest _) nil))
              ((symbol-function 'emacsos-assist-web-refresh-thread) #'ignore)
              ((symbol-function 'switch-to-buffer) #'ignore)
              ((symbol-function 'emacsos-assist-web--render)
               (lambda (value &optional stale)
                 (setq rendered-stale stale
                       emacsos-assist-web--snapshot value))))
      (emacsos-assist-web--show-thread thread))
    (let ((buffer (emacsos-assist-web--thread-buffer "thread-1")))
      (unwind-protect
          (with-current-buffer buffer
            (setq snapshot emacsos-assist-web--snapshot)
            (should-not rendered-stale)
            (should-not snapshot))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest test-assist-web-duplicate-repository-label-selects-exact-identity ()
  (let ((cache '((repositories . (((repo_key . "repo-a") (label . "Same"))
                                   ((repo_key . "repo-b") (label . "Same"))))
                 (harnesses . (((key . "deepagents")
                                (label . "Deep Agents")))))))
    (when (get-buffer "*assist New thread*") (kill-buffer "*assist New thread*"))
    (cl-letf (((symbol-function 'emacsos-assist-web--read-cache) (lambda (&rest _) nil))
              ((symbol-function 'completing-read)
               (lambda (prompt &rest _)
                 (if (string-prefix-p "Harness" prompt)
                     "Deep Agents"
                   "Same [repo-b]")))
              ((symbol-function 'switch-to-buffer) #'ignore))
      (emacsos-assist-web--new-thread-from-catalog cache))
    (let ((buffer (get-buffer "*assist New thread*")))
      (unwind-protect
          (with-current-buffer buffer
            (should (equal emacsos-assist-web--draft-repository "repo-b")))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest test-assist-web-new-draft-reopens-without-reselecting-workspace ()
  (let ((emacsos-assist-web-cache-directory (make-temp-file "assist-web-draft-" t))
        (cache '((repositories . (((repo_key . "repo-key") (label . "Assist"))))
                 (harnesses . (((key . "deepagents") (label . "Deep Agents")))))))
    (unwind-protect
        (progn
          (with-temp-buffer
            (emacsos-assist-web-mode)
            (setq emacsos-assist-web--draft-id "new-thread"
                  emacsos-assist-web--draft-repository "repo-key"
                  emacsos-assist-web--draft-harness "deepagents"
                  emacsos-assist-web--pending-key
                  "emacsos-0123456789abcdef0123456789abcdef")
            (emacsos-assist-web--write-prompt)
            (insert "saved locally")
            (should (emacsos-assist-web--save-draft)))
          (cl-letf (((symbol-function 'completing-read)
                     (lambda (&rest _) (ert-fail "saved choices should be reused")))
                    ((symbol-function 'switch-to-buffer) #'ignore))
            (emacsos-assist-web--new-thread-from-catalog cache))
          (with-current-buffer "*assist New thread*"
            (should (equal (emacsos-assist-web--input) "saved locally"))))
      (when (get-buffer "*assist New thread*") (kill-buffer "*assist New thread*"))
      (delete-directory emacsos-assist-web-cache-directory t))))

(ert-deftest test-assist-web-new-thread-fetches-catalog-with-no-existing-thread ()
  (let ((catalog '((threads . nil)
                   (repositories . (((repo_key . "repo-key")
                                     (label . "Assist"))))
                   (harnesses . (((key . "deepagents")
                                  (label . "Deep Agents")))))))
    (cl-letf (((symbol-function 'emacsos-assist-web--read-cache) (lambda (&rest _) nil))
              ((symbol-function 'emacsos-assist-web--request)
               (lambda (method path _payload callback &rest _)
                 (should (equal method "GET"))
                 (should (equal path "threads"))
                 (funcall callback catalog nil)))
              ((symbol-function 'emacsos-assist-web--write-cache) (lambda (&rest _) nil))
              ((symbol-function 'completing-read)
               (lambda (prompt &rest _) (if (string-prefix-p "Harness" prompt)
                                            "Deep Agents" "Assist")))
              ((symbol-function 'switch-to-buffer) (lambda (&rest _) nil)))
      (emacsos-assist-web-new-thread)
      (let ((buffer (get-buffer "*assist New thread*")))
        (unwind-protect
            (with-current-buffer buffer
              (should (derived-mode-p 'emacsos-assist-web-mode))
              (should (equal emacsos-assist-web--draft-repository "repo-key")))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest test-assist-web-first-open-shows-visible-retryable-loading-failure ()
  (let ((emacsos-assist-web--catalog nil))
    (cl-letf (((symbol-function 'emacsos-assist-web--read-cache) (lambda (&rest _) nil))
              ((symbol-function 'emacsos-assist-web--request)
               (lambda (_method _path _payload callback &rest _)
                 (funcall callback nil "offline"))))
      (emacsos-assist-web-open-thread)
      (let ((buffer (get-buffer "*assist Threads*")))
        (unwind-protect
            (with-current-buffer buffer
              (should (string-match-p "could not be loaded" (buffer-string)))
              (should (string-match-p "C-c e r" (buffer-string))))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest test-assist-web-empty-loaded-catalog-offers-new-thread ()
  (let ((emacsos-assist-web--catalog nil)
        (emacsos-assist-web--catalog-loaded-p t)
        shown)
    (cl-letf (((symbol-function 'emacsos-assist-web--load-catalog) #'ignore)
              ((symbol-function 'emacsos-assist-web--show-notice)
               (lambda (_name text) (setq shown text))))
      (emacsos-assist-web-open-thread))
    (should (string-match-p "C-c e n" shown))))

(ert-deftest test-assist-web-newer-catalog-response-wins ()
  (let ((emacsos-assist-web--catalog nil)
        (emacsos-assist-web--catalog-loaded-p nil)
        (emacsos-assist-web--catalog-generation 0)
        callbacks)
    (cl-letf (((symbol-function 'emacsos-assist-web--request)
               (lambda (_method _path _payload callback &rest _)
                 (push callback callbacks)))
              ((symbol-function 'emacsos-assist-web--write-cache) #'ignore))
      (emacsos-assist-web-refresh-threads)
      (emacsos-assist-web-refresh-threads)
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
    (should (equal (alist-get 'id (car emacsos-assist-web--catalog)) "new"))))

(ert-deftest test-assist-web-new-thread-fetch-cannot-overwrite-a-newer-catalog ()
  (let ((emacsos-assist-web--catalog nil)
        (emacsos-assist-web--catalog-loaded-p nil)
        (emacsos-assist-web--catalog-generation 0)
        callbacks)
    (cl-letf (((symbol-function 'emacsos-assist-web--read-cache) (lambda (&rest _) nil))
              ((symbol-function 'emacsos-assist-web--request)
               (lambda (_method _path _payload callback &rest _)
                 (setq callbacks (append callbacks (list callback)))))
              ((symbol-function 'emacsos-assist-web--write-cache) #'ignore)
              ((symbol-function 'emacsos-assist-web--new-thread-from-catalog) #'ignore))
      (emacsos-assist-web-new-thread)
      (emacsos-assist-web-refresh-threads)
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
    (should (equal (alist-get 'id (car emacsos-assist-web--catalog)) "new"))))

(ert-deftest test-assist-web-malformed-catalog-does-not-replace-valid-state ()
  (let ((emacsos-assist-web--catalog
         '(((id . "existing") (description . "Existing")
            (search_description . "existing")
            (repo_label . "Assist") (status . "ready"))))
        (emacsos-assist-web--catalog-loaded-p t))
    (cl-letf (((symbol-function 'emacsos-assist-web--request)
               (lambda (_method _path _payload callback &rest _)
                 (funcall callback "not an object" nil))))
      (emacsos-assist-web-refresh-threads))
    (should (equal (alist-get 'id (car emacsos-assist-web--catalog))
                   "existing"))))

(ert-deftest test-assist-web-has-contextual-conversation-command-prefix ()
  (with-temp-buffer
    (org-mode)
    (should (eq (key-binding (kbd "C-c C-a t"))
                #'emacsos-command-open-thread))
    (should (eq (key-binding (kbd "C-c C-a n"))
                #'emacsos-command-new-thread))
    (dolist (key '("C-c C-a g" "C-c C-a s" "C-c C-a o"
                   "C-c C-a l" "C-c C-a a"))
      (should-not (memq (key-binding (kbd key))
                         '(emacsos-conversation-refresh
                           emacsos-conversation-send
                           emacsos-conversation-open-object
                           emacsos-conversation-load-older
                           emacsos-conversation-abort)))))
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (dolist (binding '(("C-c C-a g" . emacsos-conversation-refresh)
                       ("C-c C-a s" . emacsos-conversation-send)
                       ("C-c C-a o" . emacsos-conversation-open-object)
                       ("C-c C-a l" . emacsos-conversation-load-older)
                       ("C-c C-a a" . emacsos-conversation-abort)))
      (should (eq (key-binding (kbd (car binding))) (cdr binding))))))

(ert-deftest test-assist-web-stream-cleanup-forgets-an-interrupted-record-budget ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq emacsos-assist-web--stream-scan-marker (copy-marker (point-min))
          emacsos-assist-web--stream-unconsumed-bytes 99)
    (emacsos-assist-web--stream-cleanup nil t)
    (should-not emacsos-assist-web--stream-scan-marker)
    (should-not emacsos-assist-web--stream-unconsumed-bytes)))

(ert-deftest test-assist-web-abort-cleans-up-and-refreshes ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq emacsos-assist-web--thread-id "thread-1"
          emacsos-assist-web--run-id "run-1"
          emacsos-assist-web--in-flight t)
    (let (request refreshed)
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (method path _payload callback &rest _)
                   (setq request (list method path))
                   (funcall callback '((http_status . 200)
                                       (outcome . "cancelled")) nil)))
                ((symbol-function 'emacsos-assist-web-refresh-thread)
                 (lambda (&optional buffer completed-run-id)
                   (setq refreshed (list buffer completed-run-id)))))
        (emacsos-assist-web-abort))
      (should (equal request '("DELETE" "threads/thread-1/runs/run-1")))
      (should (equal refreshed (list (current-buffer) "run-1")))
      (should-not emacsos-assist-web--in-flight))))

(ert-deftest test-assist-web-unconfirmed-abort-retains-accepted-retry-state ()
  (let ((emacsos--assist-active-surface nil))
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1"
            emacsos-assist-web--run-id "run-1"
            emacsos-assist-web--pending-key "retry-key"
            emacsos-assist-web--submitted-text "hello"
            emacsos-assist-web--pending-accepted-p t
            emacsos-assist-web--in-flight t
            emacsos--assist-active-surface (current-buffer))
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload callback &rest _)
                   (funcall callback nil "offline")))
                ((symbol-function 'emacsos-assist-web-refresh-thread) #'ignore)
                ((symbol-function 'emacsos-assist-web--save-draft) (lambda () t)))
        (emacsos-assist-web-abort))
      (should (equal emacsos-assist-web--pending-key "retry-key"))
      (should (equal emacsos-assist-web--submitted-text "hello"))
      (should emacsos-assist-web--pending-accepted-p)
      (should-not emacsos-assist-web--in-flight))))

(ert-deftest test-assist-web-abort-retries-a-pending-cancellation-receipt ()
  "A detached accepted Run remains eligible for the required DELETE replay."
  (let ((emacsos--assist-active-surface nil) (requests 0))
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1"
            emacsos-assist-web--run-id "run-1"
            emacsos-assist-web--pending-key "retry-key"
            emacsos-assist-web--submitted-text "hello"
            emacsos-assist-web--pending-accepted-p t
            emacsos-assist-web--in-flight t
            emacsos--assist-active-surface (current-buffer))
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload callback &rest _)
                   (cl-incf requests)
                   (funcall callback
                            (and (= requests 2)
                                 '((http_status . 200) (outcome . "cancelled")))
                            (and (= requests 1) "offline"))))
                ((symbol-function 'emacsos-assist-web--save-draft) (lambda () t))
                ((symbol-function 'emacsos-assist-web-refresh-thread) #'ignore))
        (emacsos-assist-web-abort)
        (should-not emacsos-assist-web--in-flight)
        (emacsos-assist-web-abort))
      (should (= requests 2))
      (should (equal emacsos-assist-web--stream-status "cancelled; reconciling")))))

(ert-deftest test-assist-web-abort-during-post-cannot-target-an-old-run ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq emacsos-assist-web--thread-id "thread-1"
          emacsos-assist-web--run-id "old-run")
    (emacsos-assist-web--write-prompt)
    (insert "hello")
    (let (requests)
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (method path _payload _callback &rest _)
                   (push (list method path) requests)))
                ((symbol-function 'emacsos-assist-web--save-draft) (lambda () t)))
        (emacsos-assist-web-send)
        (emacsos-assist-web-abort))
      (should (equal requests '(("POST" "threads/thread-1/messages"))))
      (should-not emacsos-assist-web--run-id)
      (should-not emacsos-assist-web--in-flight))))

(ert-deftest test-assist-web-preaccept-abort-keeps-exact-retry-and-ignores-late-acceptance ()
  "Abort before POST acceptance is visibly unknown and makes its old callback inert."
  (let ((emacsos--assist-active-surface nil) request)
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1")
      (emacsos-assist-web--write-prompt)
      (insert "hello")
      (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) (lambda () t))
                ((symbol-function 'emacsos-assist-web--request)
                 (lambda (method path payload callback &optional headers &rest _)
                   (setq request (list method path payload callback headers))))
                ((symbol-function 'emacsos-assist-web--observe-run)
                 (lambda (&rest _) (ert-fail "late acceptance must not observe"))))
        (emacsos-assist-web-send)
        (let ((key emacsos-assist-web--pending-key))
          (should (string-match-p "you> hello" (buffer-string)))
          (should (string-match-p "\\[queued\\]" (buffer-string)))
          (should (equal (butlast request 2)
                         '("POST" "threads/thread-1/messages" ((message . "hello")))))
          (should (equal (cdr (assoc "Idempotency-Key" (nth 4 request))) key))
          (emacsos-assist-web-abort)
          (should (equal emacsos-assist-web--pending-key key))
          (should (equal emacsos-assist-web--submitted-text "hello"))
          (should-not emacsos-assist-web--in-flight)
          (should (string-match-p "acceptance unknown" (buffer-string)))
          (funcall (nth 3 request) '((thread_id . "thread-1") (run_id . "run-late")) nil)
          (should-not emacsos-assist-web--run-id)
          (should (string-match-p "acceptance unknown" emacsos-assist-web--stream-status)))))))

(ert-deftest test-assist-web-abort-honors-structured-status-outcome-pairs ()
  "Only the documented DELETE response pairs claim a confirmed cancellation."
  (dolist (case '((200 "cancelled" "cancelled; reconciling" t)
                  (409 "running" "stopped watching; Assist is running" nil)
                  (409 "transitioning" "stopped watching; Assist is transitioning" nil)
                  (200 "running" "stopped watching; cancellation unconfirmed" nil)
                  ;; A terminal logical outcome can race DELETE after a pause;
                  ;; 409 still means canonical refresh rather than uncertainty.
                  (409 "cancelled" "cancelled; reconciling" t)))
    (pcase-let ((`(,status ,outcome ,expected ,refresh) case))
      (let ((emacsos--assist-active-surface nil) refreshed)
        (with-temp-buffer
          (emacsos-assist-web-mode)
          (setq emacsos-assist-web--thread-id "thread-1"
                emacsos-assist-web--run-id "run-1"
                emacsos-assist-web--in-flight t
                emacsos--assist-active-surface (current-buffer))
          (cl-letf (((symbol-function 'emacsos-assist-web--request)
                     (lambda (_method _path _payload callback &rest _)
                       (funcall callback `((http_status . ,status) (outcome . ,outcome)) nil)))
                    ((symbol-function 'emacsos-assist-web--save-draft) (lambda () t))
                    ((symbol-function 'emacsos-assist-web-refresh-thread)
                     (lambda (&rest _) (setq refreshed t))))
            (emacsos-assist-web-abort))
          (should (equal emacsos-assist-web--stream-status expected))
          (should (eq (and refreshed t) refresh)))))))

(ert-deftest test-assist-web-cache-failure-prevents-an-unrecoverable-send ()
  (let ((emacsos--assist-active-surface nil) requested)
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1")
      (emacsos-assist-web--render test-assist-web--snapshot)
      (insert "hello")
      (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) (lambda () nil))
                ((symbol-function 'emacsos-assist-web--request)
                 (lambda (&rest _) (setq requested t))))
        (emacsos-assist-web-send))
      (should-not requested)
      (should-not emacsos-assist-web--in-flight)
      (should-not emacsos--assist-active-surface)
      (should (equal emacsos-assist-web--stream-status
                     "not sent; local draft could not be saved")))))

(ert-deftest test-assist-web-stale-post-callback-cannot-replace-a-newer-send ()
  (let ((emacsos--assist-active-surface nil))
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1")
      (emacsos-assist-web--write-prompt)
      (insert "hello")
      (let (callbacks observed)
	(cl-letf (((symbol-function 'emacsos-assist-web--request)
                   (lambda (_method _path _payload callback &rest _)
                     (setq callbacks (append callbacks (list callback)))))
                  ((symbol-function 'emacsos-assist-web--save-draft) (lambda () t))
                  ((symbol-function 'emacsos-assist-web--observe-run)
                   (lambda (_buffer) (setq observed t))))
          (emacsos-assist-web-send)
          (setq emacsos-assist-web--in-flight nil
		emacsos--assist-active-surface nil)
          (emacsos-assist-web-send)
          (funcall (car callbacks)
                   '((thread_id . "thread-1") (run_id . "stale-run")) nil)
          (should-not emacsos-assist-web--run-id)
          (should-not observed)
          (funcall (cadr callbacks)
                   '((thread_id . "thread-1") (run_id . "current-run")) nil)
          (should (equal emacsos-assist-web--run-id "current-run"))
          (should observed))))))

(ert-deftest test-assist-web-invalid-send-response-releases-active-slot-for-retry ()
  (let ((emacsos--assist-active-surface nil))
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1")
      (emacsos-assist-web--write-prompt)
      (insert "hello")
      (let (callback)
        (cl-letf (((symbol-function 'emacsos-assist-web--request)
                   (lambda (_method _path _payload cb &rest _) (setq callback cb)))
                  ((symbol-function 'emacsos-assist-web--save-draft) (lambda () t)))
          (emacsos-assist-web-send)
          (funcall callback
                   '((thread_id . "../../wrong") (run_id . "run-1")) nil))
        (should-not emacsos-assist-web--in-flight)
        (should-not emacsos--assist-active-surface)
        (should (equal emacsos-assist-web--thread-id "thread-1"))
        (should-not emacsos-assist-web--run-id)
        (should emacsos-assist-web--pending-key)))))

(ert-deftest test-assist-web-invalid-send-endpoint-releases-active-slot-for-retry ()
  (let ((emacsos--assist-active-surface nil)
        (emacsos-assist-web-api-url "http://assist.invalid/api/v1/phone"))
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1")
      (emacsos-assist-web--write-prompt)
      (insert "hello")
      (cl-letf (((symbol-function 'emacsos-assist-web--read-token)
                 (lambda () "safe-token"))
                ((symbol-function 'emacsos-assist-web--save-draft) (lambda () t)))
        (emacsos-assist-web-send))
      (should-not emacsos-assist-web--in-flight)
      (should-not emacsos--assist-active-surface)
      (should emacsos-assist-web--pending-key)
      (should (equal emacsos-assist-web--stream-status
                     "send failed; Send retries")))))

(ert-deftest test-assist-web-global-send-outside-thread-is-a-safe-noop ()
  (with-temp-buffer
    (emacsos-assist-web-send)
    (should-not emacsos-assist-web--in-flight)))

(ert-deftest test-assist-web-replayed-send-does-not-duplicate-local-pending-text ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq emacsos-assist-web--thread-id "thread-1"
          emacsos-assist-web--pending-key
          "emacsos-0123456789abcdef0123456789abcdef"
          emacsos-assist-web--submitted-text "hello")
    (emacsos-assist-web--write-prompt)
    (emacsos-assist-web--append-pending "hello")
    (let (callback observed)
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload cb &rest _) (setq callback cb)))
                ((symbol-function 'emacsos-assist-web--save-draft) (lambda () t))
                ((symbol-function 'emacsos-assist-web--observe-run)
                 (lambda (&rest _) (setq observed t))))
        (emacsos-assist-web-send)
        (funcall callback
                 '((thread_id . "thread-1") (run_id . "run-1") (replayed . t)) nil))
      (goto-char (point-min))
      (should (= (how-many "you> hello" (point-min) (point-max)) 1))
      ;; The replayed journal, not a concurrent snapshot, owns this
      ;; provisional region until its terminal event reconciles it.
      (should observed))))

(ert-deftest test-assist-web-replay-consumes-an-unrendered-submitted-prompt ()
  (let ((emacsos--assist-active-surface nil))
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1"
            emacsos-assist-web--pending-key
            "emacsos-0123456789abcdef0123456789abcdef"
            emacsos-assist-web--submitted-text "hello")
      (emacsos-assist-web--write-prompt)
      (insert "hello")
      (let (callback)
        (cl-letf (((symbol-function 'emacsos-assist-web--request)
                   (lambda (_method _path _payload cb &rest _) (setq callback cb)))
                  ((symbol-function 'emacsos-assist-web--save-draft) (lambda () t))
                  ((symbol-function 'emacsos-assist-web-refresh-thread) #'ignore)
                  ((symbol-function 'emacsos-assist-web--observe-run) #'ignore))
          (emacsos-assist-web-send)
          (funcall callback
                   '((thread_id . "thread-1") (run_id . "run-1")
                     (replayed . t)) nil)))
      (should (= (how-many "you> hello" (point-min) (point-max)) 1))
      (should (equal (emacsos-assist-web--input) "")))))

(ert-deftest test-assist-web-existing-acceptance-saves-its-exact-run-before-observing ()
  "A crash after POST acceptance can reopen the exact canonical Run."
  (let ((emacsos--assist-active-surface nil) callback saved observed)
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1")
      (emacsos-assist-web--write-prompt)
      (insert "hello")
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload cb &rest _) (setq callback cb)))
                ((symbol-function 'emacsos-assist-web--save-draft)
                 (lambda () (push emacsos-assist-web--run-id saved) t))
                ((symbol-function 'emacsos-assist-web--observe-run)
                 (lambda (_buffer) (setq observed (member "run-1" saved)))))
        (emacsos-assist-web-send)
        (funcall callback '((thread_id . "thread-1") (run_id . "run-1")
                            (live_text . t)) nil))
      (should (member "run-1" saved))
      (should observed))))

(ert-deftest test-assist-web-accepted-run-never-observes-before-its-draft-saves ()
  "A failed accepted-run save detaches with the replay tuple instead of streaming."
  (let ((emacsos--assist-active-surface nil) callback observed (saves 0))
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1")
      (emacsos-assist-web--write-prompt)
      (insert "hello")
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload cb &rest _) (setq callback cb)))
                ((symbol-function 'emacsos-assist-web--save-draft)
                 (lambda () (setq saves (1+ saves)) (= saves 1)))
                ((symbol-function 'emacsos-assist-web--observe-run)
                 (lambda (_buffer) (setq observed t))))
        (emacsos-assist-web-send)
        (funcall callback '((thread_id . "thread-1") (run_id . "run-1")
                            (live_text . t)) nil))
      (should-not observed)
      (should (equal emacsos-assist-web--run-id "run-1"))
      (should emacsos-assist-web--pending-accepted-p)
      (should-not emacsos-assist-web--in-flight)
      (should-not emacsos--assist-active-surface))))

(ert-deftest test-assist-web-awaiting-approval-recovery-keeps-the-exact-run ()
  "A nonterminal approval wait survives until its canonical refresh succeeds."
  (let ((emacsos--assist-active-surface nil) callback refreshed)
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1"
            emacsos-assist-web--run-id "run-1"
            emacsos-assist-web--pending-key
            "emacsos-0123456789abcdef0123456789abcdef"
            emacsos-assist-web--submitted-text "hello"
            emacsos-assist-web--pending-accepted-p t)
      (emacsos-assist-web--write-prompt)
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload cb &rest _) (setq callback cb)))
                ((symbol-function 'emacsos-assist-web--save-draft) (lambda () t))
                ((symbol-function 'emacsos-assist-web-refresh-thread)
                 (lambda (buffer completed-run-id)
                   (setq refreshed (list buffer completed-run-id)))))
        (emacsos-assist-web--resume-accepted-run)
        (funcall callback '((status . "awaiting_approval")) nil))
      (should (equal emacsos-assist-web--run-id "run-1"))
      (should emacsos-assist-web--pending-accepted-p)
      (should (equal refreshed (list (current-buffer) "run-1"))))))

(ert-deftest test-assist-web-unknown-run-status-keeps-the-exact-retry-tuple ()
  "An unrecognized projection cannot discard accepted durable work."
  (let ((emacsos--assist-active-surface nil) callback observed)
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1"
            emacsos-assist-web--run-id "run-1"
            emacsos-assist-web--pending-key
            "emacsos-0123456789abcdef0123456789abcdef"
            emacsos-assist-web--submitted-text "hello"
            emacsos-assist-web--pending-accepted-p t)
      (emacsos-assist-web--write-prompt)
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload cb &rest _) (setq callback cb)))
                ((symbol-function 'emacsos-assist-web--save-draft) (lambda () t))
                ((symbol-function 'emacsos-assist-web--observe-run)
                 (lambda (&rest _) (setq observed t))))
        (emacsos-assist-web--resume-accepted-run)
        (funcall callback '((status . "unknown-future-status")) nil))
      (should-not observed)
      (should (equal emacsos-assist-web--run-id "run-1"))
      (should emacsos-assist-web--pending-accepted-p)
      (should (equal emacsos-assist-web--pending-key
                     "emacsos-0123456789abcdef0123456789abcdef"))
      (should-not emacsos-assist-web--in-flight)
      (should-not emacsos--assist-active-surface)
      (should (string-match-p "invalid Assist run status"
                              emacsos-assist-web--stream-status)))))

(ert-deftest test-assist-web-replay-renders-a-new-submission-with-the-same-text ()
  (let ((emacsos--assist-active-surface nil)
        (snapshot
         '((thread . ((id . "thread-1") (description . "Thread")
                      (status . "ready")
                      (workspace . ((repo_label . "Assist")))))
           (messages . (((id . "m-1") (role . "user") (text . "hello")
                         (state . "final")))))))
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1")
      (emacsos-assist-web--render snapshot)
      (insert "hello")
      (setq emacsos-assist-web--pending-key
            "emacsos-0123456789abcdef0123456789abcdef"
            emacsos-assist-web--submitted-text "hello")
      (let (callback)
        (cl-letf (((symbol-function 'emacsos-assist-web--request)
                   (lambda (_method _path _payload cb &rest _) (setq callback cb)))
                  ((symbol-function 'emacsos-assist-web--save-draft) (lambda () t))
                  ((symbol-function 'emacsos-assist-web-refresh-thread) #'ignore)
                  ((symbol-function 'emacsos-assist-web--observe-run) #'ignore))
          (emacsos-assist-web-send)
          (funcall callback
                   '((thread_id . "thread-1") (run_id . "run-1")
                     (replayed . t)) nil)))
      (should (= (how-many "you> hello" (point-min) (point-max)) 2))
      (should (equal (emacsos-assist-web--input) "")))))

(ert-deftest test-assist-web-restored-final-submission-is-not-a-false-pending-turn ()
  (let ((emacsos--assist-active-surface nil)
        (snapshot
         '((thread . ((id . "thread-1") (description . "Thread")
                      (status . "ready")
                      (workspace . ((repo_label . "Assist")))))
           (messages . (((id . "m-1") (role . "user") (text . "hello")
                         (state . "final")))))))
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1")
      (let (refreshed request)
      (cl-letf (((symbol-function 'emacsos-assist-web--read-cache)
                 (lambda (&rest _)
                   '((text . "hello")
                     (pending_key . "emacsos-0123456789abcdef0123456789abcdef")
                     (submitted_text . "hello") (pending_accepted . t)
                     (run_id . "run-1"))))
                ((symbol-function 'emacsos-assist-web--try-write-cache) #'ignore)
                ((symbol-function 'emacsos-assist-web--request)
                 (lambda (method path _payload callback &rest _)
                   (setq request (list method path))
                   (funcall callback '((status . "success")) nil)))
                ((symbol-function 'emacsos-assist-web-refresh-thread)
                 (lambda (&rest _) (setq refreshed t))))
          (emacsos-assist-web--render snapshot))
        (should (equal request '("GET" "threads/thread-1/runs/run-1")))
        (should refreshed)
        (should (= (how-many "you> hello" (point-min) (point-max)) 1))
        (should-not (string-match-p "observation interrupted" (buffer-string)))
        (should-not emacsos-assist-web--pending-key)
        (should (equal (emacsos-assist-web--input) ""))))))

(ert-deftest test-assist-web-restores-an-active-repeated-submission-by-run-id ()
  "A prior identical final turn cannot suppress the restored active submission."
  (let ((emacsos--assist-active-surface nil)
        (snapshot
         '((thread . ((id . "thread-1") (description . "Thread")
                      (status . "processing")
                      (workspace . ((repo_label . "Assist")))))
           (messages . (((id . "m-1") (role . "user") (text . "hello")
                         (state . "final")))))))
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1")
      (let (observed)
        (cl-letf (((symbol-function 'emacsos-assist-web--read-cache)
                   (lambda (&rest _)
                     '((text . "")
                       (pending_key . "emacsos-0123456789abcdef0123456789abcdef")
                       (submitted_text . "hello") (pending_accepted . t)
                       (run_id . "run-2"))))
                  ((symbol-function 'emacsos-assist-web--try-write-cache) #'ignore)
                  ((symbol-function 'emacsos-assist-web--request)
                   (lambda (_method _path _payload callback &rest _)
                     (funcall callback '((status . "pending")) nil)))
                  ((symbol-function 'emacsos-assist-web--observe-run)
                   (lambda (&rest _) (setq observed t))))
          (emacsos-assist-web--render snapshot))
        (should (= (how-many "you> hello" (point-min) (point-max)) 2))
        (should emacsos-assist-web--in-flight)
        (should observed)))))

(ert-deftest test-assist-web-restored-run-never-steals-another-active-surface ()
  "A recovered accepted run waits without losing its exact retry identity."
  (let ((owner (generate-new-buffer " *local-chat-owner*"))
        requested)
    (unwind-protect
        (let ((emacsos--assist-active-surface owner))
          (with-temp-buffer
            (emacsos-assist-web-mode)
            (setq emacsos-assist-web--thread-id "thread-1"
                  emacsos-assist-web--pending-key
                  "emacsos-0123456789abcdef0123456789abcdef"
                  emacsos-assist-web--submitted-text "hello"
                  emacsos-assist-web--pending-accepted-p t
                  emacsos-assist-web--run-id "run-1")
            (cl-letf (((symbol-function 'emacsos-assist-web--request)
                       (lambda (&rest _) (setq requested t))))
              (emacsos-assist-web--resume-accepted-run))
            (should-not requested)
            (should (eq emacsos--assist-active-surface owner))
            (should-not emacsos-assist-web--in-flight)
            (should (equal emacsos-assist-web--pending-key
                           "emacsos-0123456789abcdef0123456789abcdef"))
            (should (equal emacsos-assist-web--submitted-text "hello"))
            (should emacsos-assist-web--pending-accepted-p)
            (should (equal emacsos-assist-web--run-id "run-1"))
            (should (string-match-p "another conversation is active"
                                    emacsos-assist-web--stream-status))))
      (when (buffer-live-p owner) (kill-buffer owner)))))

(ert-deftest test-assist-web-does-not-overlap-the-local-chat-stream ()
  (let ((emacsos--assist-active-surface 'chat) requested)
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1")
      (emacsos-assist-web--write-prompt)
      (insert "hello")
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (&rest _) (setq requested t))))
        (emacsos-assist-web-send))
      (should-not requested)
      (should-not emacsos-assist-web--in-flight))))

(ert-deftest test-assist-web-new-thread-saves-canonical-state-before-removing-local-draft ()
  (let ((emacsos--assist-active-surface nil) callback events)
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--draft-id "new-thread"
            emacsos-assist-web--draft-repository "repo-key"
            emacsos-assist-web--draft-harness "deepagents")
      (emacsos-assist-web--write-prompt)
      (insert "hello")
      (cl-letf (((symbol-function 'emacsos-assist-web--save-draft)
                 (lambda () (setq events (append events '(save))) t))
                ((symbol-function 'emacsos-assist-web--delete-cache)
                 (lambda (&rest _) (setq events (append events '(delete))) t))
                ((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload cb &rest _) (setq callback cb)))
                ((symbol-function 'emacsos-assist-web--observe-run) #'ignore))
        (emacsos-assist-web-send)
        (funcall callback '((thread_id . "thread-new") (run_id . "run-new")) nil))
      (should (equal events '(save save delete)))
      (should (eq (emacsos-assist-web--thread-buffer "thread-new")
                  (current-buffer))))))

(ert-deftest test-assist-web-new-thread-acceptance-adopts-an-existing-canonical-buffer ()
  (let ((emacsos--assist-active-surface nil)
        (canonical (generate-new-buffer " *assist-canonical*"))
        (draft (generate-new-buffer " *assist-new-draft*"))
        callback observations cleaned
        (original-cleanup (symbol-function 'emacsos-assist-web--stream-cleanup)))
    (unwind-protect
        (progn
          (with-current-buffer canonical
            (emacsos-assist-web-mode)
            (setq emacsos-assist-web--thread-id "thread-new")
            (emacsos-assist-web--write-prompt))
          (with-current-buffer draft
            (emacsos-assist-web-mode)
            (setq emacsos-assist-web--draft-id "new-thread"
                  emacsos-assist-web--draft-repository "repo-key"
                  emacsos-assist-web--draft-harness "deepagents")
            (emacsos-assist-web--write-prompt)
            (insert "hello")
            (cl-letf (((symbol-function 'emacsos-assist-web--stream-cleanup)
                       (lambda (&optional keep-pending no-render)
                         (when (eq (current-buffer) canonical)
                           (setq cleaned (list keep-pending no-render)))
                         (funcall original-cleanup keep-pending no-render)))
                      ((symbol-function 'emacsos-assist-web--save-draft) (lambda () t))
                      ((symbol-function 'emacsos-assist-web--delete-cache)
                       (lambda (&rest _) t))
                      ((symbol-function 'emacsos-assist-web--request)
                       (lambda (_method _path _payload cb &rest _) (setq callback cb)))
                      ((symbol-function 'emacsos-assist-web--observe-run)
                       (lambda (buffer) (push buffer observations))))
              (emacsos-assist-web-send)
              (switch-to-buffer draft)
              ;; The source remains editable while POST acceptance is in flight.
              (insert "next draft")
              (funcall callback
                       '((thread_id . "thread-new") (run_id . "run-new")) nil)))
          (should-not (buffer-live-p draft))
          (should (equal observations (list canonical)))
          (should (equal cleaned '(t t)))
          (should (eq emacsos--assist-active-surface canonical))
          (with-current-buffer canonical
            (should (equal emacsos-assist-web--run-id "run-new"))
            (should (= emacsos-assist-web--refresh-generation 1))
            (should (= emacsos-assist-web--send-generation 1))
            (should (= emacsos-assist-web--stream-generation 1))
            (should (= (how-many "you> hello" (point-min) (point-max)) 1))
            (should (equal (emacsos-assist-web--input) "next draft"))
            (should (string-match-p "working; live text unavailable"
                                    (buffer-string)))))
      (when (buffer-live-p draft) (kill-buffer draft))
      (when (buffer-live-p canonical) (kill-buffer canonical))
      (setq emacsos--assist-active-surface nil))))

(ert-deftest test-assist-web-transfer-waits-for-the-final-owner-save ()
  "A failed canonical save leaves the source draft and ownership untouched."
  (let ((emacsos--assist-active-surface nil)
        (canonical (generate-new-buffer " *assist-canonical*"))
        (draft (generate-new-buffer " *assist-new-draft*"))
        callback observed deleted)
    (unwind-protect
        (progn
          (with-current-buffer canonical
            (emacsos-assist-web-mode)
            (setq emacsos-assist-web--thread-id "thread-new")
            (emacsos-assist-web--write-prompt))
          (with-current-buffer draft
            (emacsos-assist-web-mode)
            (setq emacsos-assist-web--draft-id "new-thread"
                  emacsos-assist-web--draft-repository "repo-key"
                  emacsos-assist-web--draft-harness "deepagents"
                  emacsos-assist-web--pending-key
                  "emacsos-0123456789abcdef0123456789abcdef")
            (emacsos-assist-web--write-prompt)
            (insert "hello")
            (cl-letf (((symbol-function 'emacsos-assist-web--save-draft)
                       (lambda () (not (eq (current-buffer) canonical))))
                      ((symbol-function 'emacsos-assist-web--delete-cache)
                       (lambda (&rest _) (setq deleted t)))
                      ((symbol-function 'emacsos-assist-web--request)
                       (lambda (_method _path _payload cb &rest _) (setq callback cb)))
                      ((symbol-function 'emacsos-assist-web--observe-run)
                       (lambda (_buffer) (setq observed t))))
              (emacsos-assist-web-send)
              (funcall callback
                       '((thread_id . "thread-new") (run_id . "run-new")
                         (live_text . t)) nil)))
          (should-not observed)
          (should-not deleted)
          (should (buffer-live-p draft))
          (should-not emacsos--assist-active-surface)
          (with-current-buffer canonical
            (should-not emacsos-assist-web--run-id)
            (should-not emacsos-assist-web--pending-accepted-p)
            (should-not emacsos-assist-web--in-flight)))
          (with-current-buffer draft
            (should-not emacsos-assist-web--thread-id)
            (should (equal emacsos-assist-web--draft-id "new-thread"))
            (should (equal emacsos-assist-web--pending-key
                           "emacsos-0123456789abcdef0123456789abcdef"))
            (should-not emacsos-assist-web--pending-accepted-p)
            (should-not emacsos-assist-web--run-id)
            (should-not emacsos-assist-web--in-flight))
      (when (buffer-live-p draft) (kill-buffer draft))
      (when (buffer-live-p canonical) (kill-buffer canonical))
      (setq emacsos--assist-active-surface nil))))

(ert-deftest test-assist-web-transfer-keeps-source-until-its-old-cache-is-retired ()
  "A stale new-thread cache cannot outlive accepted canonical ownership."
  (let ((emacsos--assist-active-surface nil)
        (canonical (generate-new-buffer " *assist-canonical*"))
        (draft (generate-new-buffer " *assist-new-draft*"))
        callback observed)
    (unwind-protect
        (progn
          (with-current-buffer canonical
            (emacsos-assist-web-mode)
            (setq emacsos-assist-web--thread-id "thread-new")
            (emacsos-assist-web--write-prompt))
          (with-current-buffer draft
            (emacsos-assist-web-mode)
            (setq emacsos-assist-web--draft-id "new-thread"
                  emacsos-assist-web--draft-repository "repo-key"
                  emacsos-assist-web--draft-harness "deepagents"
                  emacsos-assist-web--pending-key
                  "emacsos-0123456789abcdef0123456789abcdef")
            (emacsos-assist-web--write-prompt)
            (insert "hello")
            (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) (lambda () t))
                      ((symbol-function 'emacsos-assist-web--delete-cache) (lambda (&rest _) nil))
                      ((symbol-function 'emacsos-assist-web--request)
                       (lambda (_method _path _payload cb &rest _) (setq callback cb)))
                      ((symbol-function 'emacsos-assist-web--observe-run)
                       (lambda (_buffer) (setq observed t))))
              (emacsos-assist-web-send)
              (funcall callback
                       '((thread_id . "thread-new") (run_id . "run-new")
                         (live_text . t)) nil)))
          (should-not observed)
          (should (buffer-live-p draft))
          (should-not emacsos--assist-active-surface)
          (with-current-buffer draft
            (should (equal emacsos-assist-web--draft-id "new-thread"))
            (should (equal emacsos-assist-web--pending-key
                           "emacsos-0123456789abcdef0123456789abcdef"))))
      (when (buffer-live-p draft) (kill-buffer draft))
      (when (buffer-live-p canonical) (kill-buffer canonical))
      (setq emacsos--assist-active-surface nil))))

(ert-deftest test-assist-web-render-presents-markdown-and-tags-whole-message ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let ((snapshot
           '((thread . ((id . "thread-1") (description . "Thread")
                        (status . "ready")
                        (workspace . ((repo_label . "Assist")))))
             (messages . (((id . "m-1") (role . "assistant")
                           (text . "# Heading\n- item") (state . "final")))))))
      (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) (lambda () t)))
        (emacsos-assist-web--render snapshot))
      (should visual-line-mode)
      (goto-char (point-min))
      (search-forward "Heading")
      (should (memq 'emacsos-chat-heading-face
                    (get-text-property (match-beginning 0) 'font-lock-face)))
      (goto-char (point-min))
      (search-forward "bot> ")
      (let ((message-start (match-beginning 0)))
        (search-forward "\n\n")
        (should (equal (get-text-property
                        message-start 'emacsos-assist-web-message-id)
                       "m-1"))
        (should (equal (get-text-property
                        (1- (point)) 'emacsos-assist-web-message-id)
                       "m-1"))))))

(ert-deftest test-assist-web-render-rejects-duplicate-message-identities ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (should-error
     (emacsos-assist-web--render
      '((thread . ((id . "thread-1") (description . "Thread")
                   (status . "ready")
                   (workspace . ((repo_label . "Assist")))))
        (messages . (((id . "same") (role . "user") (text . "one")
                      (state . "final"))
                     ((id . "same") (role . "assistant") (text . "two")
                      (state . "final")))))))))

(ert-deftest test-assist-web-render-has-one-total-presentation-budget ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let ((emacsos--chat-presentation-max-bytes 12)
          (snapshot
           '((thread . ((id . "thread-1") (description . "Thread")
                        (status . "ready")
                        (workspace . ((repo_label . "Assist")))))
             (messages . (((id . "m-1") (role . "assistant")
                           (text . "**one**") (state . "final"))
                          ((id . "m-2") (role . "assistant")
                           (text . "**two**") (state . "final")))))))
      (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) (lambda () t)))
        (emacsos-assist-web--render snapshot)))
    (goto-char (point-min))
    (search-forward "one")
    (should-not (memq 'bold
                      (get-text-property (match-beginning 0) 'font-lock-face)))))

(ert-deftest test-assist-web-refresh-retains-draft-cursor-and-loaded-history ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let* ((old
            '((thread . ((id . "thread-1") (description . "Thread")
                         (status . "ready")
                         (workspace . ((repo_label . "Assist")))))
              (messages . (((id . "m-old") (role . "assistant")
                            (text . "older") (state . "final"))
                           ((id . "m-1") (role . "assistant")
                            (text . "recent") (state . "final"))))
              (has_older_messages . t) (next_before . "cursor-old")))
           (fresh
            '((thread . ((id . "thread-1") (description . "Thread")
                         (status . "ready")
                         (workspace . ((repo_label . "Assist")))))
              (messages . (((id . "m-1") (role . "assistant")
                            (text . "recent final") (state . "final"))
                           ((id . "m-2") (role . "assistant")
                            (text . "new") (state . "final"))))
              (has_older_messages . t) (next_before . "cursor-new"))))
      (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) (lambda () t)))
        (emacsos-assist-web--render old)
        (insert "draft text")
        (goto-char (+ (emacsos-assist-web--prompt-start) 3))
        (emacsos-assist-web--render fresh))
      (should (= (point) (+ (emacsos-assist-web--prompt-start) 3)))
      (should (string-match-p "older" (buffer-string)))
      (should (string-match-p "recent final" (buffer-string)))
      (should (equal (alist-get 'next_before emacsos-assist-web--snapshot)
                     "cursor-old")))))

(ert-deftest test-assist-web-render-keeps-phone-viewport-on-message-anchor ()
  (let ((buffer (generate-new-buffer " *assist-anchor-test*"))
        (window (selected-window))
        (old-buffer (window-buffer (selected-window))))
    (unwind-protect
        (with-current-buffer buffer
          (emacsos-assist-web-mode)
          (set-window-buffer window buffer)
          (let* ((long-text
                  (mapconcat (lambda (number) (format "line %d" number))
                             (number-sequence 1 60) "\n"))
                 (initial
                  `((thread . ((id . "thread-1") (description . "Thread")
                               (status . "ready")
                               (workspace . ((repo_label . "Assist")))))
                    (messages . (((id . "m-1") (role . "assistant")
                                  (text . ,long-text) (state . "final"))))))
                 (updated (copy-tree initial)))
            (setf (alist-get 'messages updated)
                  `(((id . "m-0") (role . "user")
                     (text . ,(mapconcat
                               (lambda (number) (format "older %d" number))
                               (number-sequence 1 30) "\n"))
                     (state . "final"))
                    ((id . "m-1") (role . "assistant")
                     (text . ,long-text) (state . "final"))))
            (cl-letf (((symbol-function 'emacsos-assist-web--save-draft)
                       (lambda () t)))
              (emacsos-assist-web--render initial)
            (goto-char (point-min))
              (search-forward "line 25")
            (goto-char (match-beginning 0))
            (set-window-start window (match-beginning 0) t)
              (redisplay t)
              (should (equal
                       (get-text-property
                        (window-start window) 'emacsos-assist-web-message-id)
                       "m-1"))
              (emacsos-assist-web--render updated))
            (should (equal
                     (get-text-property
                      (window-start window) 'emacsos-assist-web-message-id)
                     "m-1"))
            (should (looking-at "line 25"))))
      (set-window-buffer window old-buffer)
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest test-assist-web-message-anchor-clamps-inside-a-shortened-record ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let* ((long (concat "bot> " (make-string 40 ?x) "\n\n"))
           (short "bot> x\n\n")
           (id "message-1"))
      (insert long "bot> next\n\n")
      (put-text-property (point-min) (1+ (length long))
                         'emacsos-assist-web-message-id id)
      (let ((anchor (emacsos-assist-web--anchor-at (+ (point-min) 30))))
        (erase-buffer)
        (insert short "bot> next\n\n")
        (put-text-property (point-min) (1+ (length short))
                           'emacsos-assist-web-message-id id)
        (let ((resolved (emacsos-assist-web--resolve-anchor anchor)))
          (should (equal (get-text-property
                          resolved 'emacsos-assist-web-message-id)
                         id)))))))

(ert-deftest test-assist-web-pending-commit-preserves-next-draft-cursor ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (emacsos-assist-web--write-prompt)
    (insert "next draft")
    (goto-char (+ (emacsos-assist-web--prompt-start) 4))
    (emacsos-assist-web--append-pending "sent")
    (should (= (point) (+ (emacsos-assist-web--prompt-start) 4)))
    (should (equal (emacsos-assist-web--input) "next draft"))))

(ert-deftest test-assist-web-deleted-thread-closes-without-losing-visible-partial-or-next-draft ()
  (let ((emacsos--assist-active-surface nil))
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1"
            emacsos-assist-web--run-id "run-1"
            emacsos-assist-web--pending-key "emacsos-0123456789abcdef0123456789abcdef"
            emacsos-assist-web--submitted-text "sent"
            emacsos-assist-web--pending-accepted-p t
            emacsos-assist-web--in-flight t
            emacsos--assist-active-surface (current-buffer))
      (emacsos-assist-web--write-prompt)
      (insert "next draft")
      (emacsos-assist-web--append-pending "sent")
      (emacsos-assist-web--reset-assistant 1)
      (emacsos-assist-web--append-delta 1 1 "partial")
      (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) (lambda () t)))
        (emacsos-assist-web--dispatch-event
         (current-buffer) "closed-set" "{\"reason\":\"thread-gone\"}"))
      (should-not emacsos-assist-web--thread-id)
      (should-not emacsos-assist-web--run-id)
      (should-not emacsos-assist-web--pending-key)
      (should-not emacsos-assist-web--pending-accepted-p)
      (should-not emacsos-assist-web--in-flight)
      (should-not emacsos--assist-active-surface)
      (should (equal emacsos-assist-web--stream-status
                     "thread deleted; start a new thread"))
      (should (string-match-p "partial" (buffer-string)))
      (should (equal (emacsos-assist-web--input) "next draft"))
      (should-not emacsos-assist-web--pending-rendered-p)
      (should-not emacsos-assist-web--assistant-start)
      (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) (lambda () t))
                ((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload callback &rest _)
                   (funcall callback '((thread_id . "thread-2") (run_id . "run-2")
                                       (live_text . t)) nil)))
                ((symbol-function 'emacsos-assist-web--observe-run) #'ignore))
        (emacsos-assist-web-send))
      (should (string-match-p "you> next draft" (buffer-string)))
      (should (markerp emacsos-assist-web--assistant-start)))))

(ert-deftest test-assist-web-deleted-thread-persists-the-next-draft-as-local ()
  (let ((emacsos-assist-web-cache-directory (make-temp-file "assist-web-deleted-" t)))
    (unwind-protect
        (with-temp-buffer
          (emacsos-assist-web-mode)
          (setq emacsos-assist-web--thread-id "thread-1"
                emacsos-assist-web--run-id "run-1"
                emacsos-assist-web--pending-key "emacsos-0123456789abcdef0123456789abcdef"
                emacsos-assist-web--submitted-text "sent"
                emacsos-assist-web--pending-accepted-p t)
          (emacsos-assist-web--write-prompt)
          (insert "next draft")
          (emacsos-assist-web--dispatch-event
           (current-buffer) "closed-set" "{\"reason\":\"thread-gone\"}")
          (should (equal (alist-get 'text
                                    (emacsos-assist-web--read-cache "drafts/new-thread.json"))
                         "next draft")))
      (delete-directory emacsos-assist-web-cache-directory t))))

(ert-deftest test-assist-web-run-store-error-keeps-accepted-identity-for-operator-repair ()
  (let ((emacsos--assist-active-surface nil))
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1"
            emacsos-assist-web--run-id "run-1"
            emacsos-assist-web--pending-key "emacsos-0123456789abcdef0123456789abcdef"
            emacsos-assist-web--submitted-text "sent"
            emacsos-assist-web--pending-accepted-p t
            emacsos-assist-web--in-flight t
            emacsos--assist-active-surface (current-buffer))
      (emacsos-assist-web--write-prompt)
      (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) (lambda () t)))
        (emacsos-assist-web--dispatch-event
         (current-buffer) "error" "{\"detail\":\"run-store-unavailable\"}"))
      (should (equal emacsos-assist-web--thread-id "thread-1"))
      (should (equal emacsos-assist-web--run-id "run-1"))
      (should (equal emacsos-assist-web--pending-key
                     "emacsos-0123456789abcdef0123456789abcdef"))
      (should emacsos-assist-web--pending-accepted-p)
      (should-not emacsos-assist-web--in-flight)
      (should-not emacsos--assist-active-surface)
      (should (equal emacsos-assist-web--stream-status
                     "observation unavailable; operator repair required"))
      (should-not (string-match-p "Send retries" (buffer-string))))))

(ert-deftest test-assist-web-pre-sse-run-store-error-keeps-accepted-identity ()
  (let ((emacsos--assist-active-surface nil)
        (source (generate-new-buffer " *assist-web-unavailable*")))
    (unwind-protect
        (progn
          (with-current-buffer source
            (insert "{\"detail\":\"run-store-unavailable\"}")
            (setq-local url-http-response-status 503
                        url-http-content-type "application/json"
                        url-http-end-of-headers (copy-marker (point-min))))
          (with-temp-buffer
            (emacsos-assist-web-mode)
            (setq emacsos-assist-web--thread-id "thread-1"
                  emacsos-assist-web--run-id "run-1"
                  emacsos-assist-web--pending-key "emacsos-0123456789abcdef0123456789abcdef"
                  emacsos-assist-web--submitted-text "sent"
                  emacsos-assist-web--pending-accepted-p t
                  emacsos-assist-web--in-flight t
                  emacsos--assist-active-surface (current-buffer))
            (emacsos-assist-web--write-prompt)
            (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) (lambda () t))
                      ((symbol-function 'run-at-time)
                       (lambda (_delay _repeat function &rest args)
                         (apply function args))))
              (emacsos-assist-web--finish-observation-response
               (current-buffer) emacsos-assist-web--stream-generation source))
            (should (equal emacsos-assist-web--thread-id "thread-1"))
            (should (equal emacsos-assist-web--run-id "run-1"))
            (should (equal emacsos-assist-web--stream-status
                           "observation unavailable; operator repair required"))))
      (when (buffer-live-p source) (kill-buffer source)))))

(ert-deftest test-assist-web-pre-sse-store-error-survives-url-sentinel-ordering ()
  "The URL sentinel must not clear identity before its deferred 503 verdict."
  (let ((emacsos--assist-active-surface nil)
        (source (generate-new-buffer " *assist-web-unavailable*"))
        timer)
    (unwind-protect
        (progn
          (with-current-buffer source
            (insert "{\"detail\":\"run-store-unavailable\"}")
            (setq-local url-http-response-status 503
                        url-http-content-type "application/json"
                        url-http-end-of-headers (copy-marker (point-min))))
          (with-temp-buffer
            (emacsos-assist-web-mode)
            (setq emacsos-assist-web--thread-id "thread-1"
                  emacsos-assist-web--run-id "run-1"
                  emacsos-assist-web--pending-key "emacsos-0123456789abcdef0123456789abcdef"
                  emacsos-assist-web--submitted-text "sent"
                  emacsos-assist-web--pending-accepted-p t
                  emacsos-assist-web--in-flight t
                  emacsos-assist-web--stream-generation 3
                  emacsos-assist-web--stream-process 'ended
                  emacsos--assist-active-surface (current-buffer))
            (emacsos-assist-web--write-prompt)
            (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) (lambda () t))
                      ((symbol-function 'run-at-time)
                       (lambda (_delay _repeat function &rest args)
                         (setq timer (cons function args)) 'timer)))
              (funcall
               (emacsos-assist-web--stream-sentinel
                (lambda (_ended _event)
                  (emacsos-assist-web--finish-observation-response
                   (current-buffer) 3 source))
                (current-buffer) 3)
               'ended "finished")
              ;; The sentinel only schedules the completion verdict.  A generic
              ;; disconnect here would invalidate this tuple before the 503 is read.
              (should (equal emacsos-assist-web--run-id "run-1"))
              (apply (car timer) (cdr timer)))
            (should (equal emacsos-assist-web--thread-id "thread-1"))
            (should (equal emacsos-assist-web--run-id "run-1"))
            (should (equal emacsos-assist-web--stream-status
                           "observation unavailable; operator repair required"))))
      (when (buffer-live-p source) (kill-buffer source)))))

(ert-deftest test-assist-web-recovered-run-store-error-keeps-accepted-identity ()
  (let ((emacsos--assist-active-surface nil))
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1"
            emacsos-assist-web--run-id "run-1"
            emacsos-assist-web--pending-key "emacsos-0123456789abcdef0123456789abcdef"
            emacsos-assist-web--submitted-text "sent"
            emacsos-assist-web--pending-accepted-p t)
      (emacsos-assist-web--write-prompt)
      (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) (lambda () t))
                ((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload callback &rest _)
                   (funcall callback nil "Assist Web run store is unavailable"))))
        (emacsos-assist-web--resume-accepted-run))
      (should (equal emacsos-assist-web--thread-id "thread-1"))
      (should (equal emacsos-assist-web--run-id "run-1"))
      (should (equal emacsos-assist-web--stream-status
                     "observation unavailable; operator repair required")))))

(ert-deftest test-assist-web-abort-run-store-error-keeps-accepted-identity ()
  "A failed DELETE read is observation loss, not an unconfirmed cancellation."
  (let ((emacsos--assist-active-surface nil))
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1"
            emacsos-assist-web--run-id "run-1"
            emacsos-assist-web--pending-key "emacsos-0123456789abcdef0123456789abcdef"
            emacsos-assist-web--submitted-text "sent"
            emacsos-assist-web--pending-accepted-p t
            emacsos-assist-web--in-flight t
            emacsos--assist-active-surface (current-buffer))
      (emacsos-assist-web--write-prompt)
      (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) (lambda () t))
                ((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload callback &rest _)
                   (funcall callback nil "Assist Web run store is unavailable"))))
        (emacsos-assist-web-abort))
      (should (equal emacsos-assist-web--thread-id "thread-1"))
      (should (equal emacsos-assist-web--run-id "run-1"))
      (should (equal emacsos-assist-web--pending-key
                     "emacsos-0123456789abcdef0123456789abcdef"))
      (should emacsos-assist-web--pending-accepted-p)
      (should-not emacsos-assist-web--in-flight)
      (should (equal emacsos-assist-web--stream-status
                     "observation unavailable; operator repair required")))))

(provide 'test-assist-web)
;;; test-assist-web.el ends here
