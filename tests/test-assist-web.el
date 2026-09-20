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

(defun test-assist-web--catalog (&rest threads)
  "Return a complete catalog containing THREADS."
  `((threads
     . ,(mapcar
         (lambda (thread)
           (let ((copy (copy-tree thread)))
             (unless (assq 'search_description copy)
               (setf (alist-get 'search_description copy)
                     (alist-get 'description copy)))
             copy))
         threads))
    (repositories . nil) (harnesses . nil)))

(defun test-assist-web--wire-object (fields)
  "Return a string-keyed JSON object hash table for FIELDS."
  (let ((object (make-hash-table :test #'equal)))
    (dolist (field fields object)
      (puthash (symbol-name (car field)) (cdr field) object))))

(defun test-assist-web--wire-catalog (threads repositories harnesses)
  "Return a string-keyed wire catalog with array identity preserved."
  (let ((catalog (make-hash-table :test #'equal)))
    (puthash "threads"
             (vconcat (mapcar #'test-assist-web--wire-object threads)) catalog)
    (puthash "repositories"
             (vconcat (mapcar #'test-assist-web--wire-object repositories)) catalog)
    (puthash "harnesses"
             (vconcat (mapcar #'test-assist-web--wire-object harnesses)) catalog)
    catalog))

(defun test-assist-web--initialize-url-http-response (buffer process)
  "Initialize BUFFER and PROCESS for stock `url-http-generic-filter' tests."
  (with-current-buffer buffer
    (mm-disable-multibyte)
    (setq-local url-http-after-change-function
                'url-http-wait-for-headers-change-function
                url-http-end-of-headers nil
                url-http-chunked-counter 0
                url-http-chunked-last-crlf-missing nil
                url-http-chunked-length nil
                url-http-chunked-start nil
                url-http-response-status nil
                url-http-content-type nil
                url-http-transfer-encoding nil
                url-http-content-length nil
                url-http-process process
                url-http-no-retry t
                url-http-connection-opened t
                url-http-method "GET"
                url-http-extra-headers nil
                url-http-noninteractive t
                url-http-data nil
                url-http-response-version nil
                url-callback-function nil
                url-callback-arguments nil
                url-current-object
                (url-generic-parse-url "https://assist.invalid/")
                url-http-target-url url-current-object)))

(ert-deftest test-assist-web-completion-matches-server-search-text-and-keeps-identity ()
  (let* ((emacsos-assist-web--catalog
          (test-assist-web--catalog
           '((id . "thread-1") (description . "🧪")
             (search_description . "Release check")
             (repo_label . "Assist") (status . "ready"))))
         (records (emacsos-assist-web--completion-records))
         (table (emacsos-assist-web--completion-table records)))
    (should (equal (all-completions "release" table)
                   (list
                    (concat
                     "#1  "
                     (emacsos-assist-web--isolate-display-text
                      "*assist 🧪 - Assist* [ready]")))))
    (should (equal (alist-get 'id (plist-get (car records) :thread)) "thread-1"))))

(ert-deftest test-assist-web-duplicate-thread-labels-show-leading-ordinals ()
  (let* ((emacsos-assist-web--catalog
          (test-assist-web--catalog
           '((id . "thread-a-shared") (description . "Same")
             (repo_label . "Assist") (status . "ready"))
           '((id . "thread-b-shared") (description . "Same")
             (repo_label . "Assist") (status . "ready"))))
         (records (emacsos-assist-web--completion-records))
         (displays (mapcar (lambda (record) (plist-get record :display)) records)))
    (should (= (length (delete-dups (copy-sequence displays))) 2))
    (should (string-prefix-p "#1  " (car displays)))
    (should (string-prefix-p "#2  " (cadr displays)))))

(ert-deftest test-assist-web-completion-returns-all-substring-matches ()
  (let* ((emacsos-assist-web--catalog
          (test-assist-web--catalog
           '((id . "thread-1") (description . "Release one")
             (repo_label . "Assist") (status . "ready"))
           '((id . "thread-2") (description . "Release two")
             (repo_label . "EmacsOS") (status . "ready"))))
         (table (emacsos-assist-web--completion-table
                 (emacsos-assist-web--completion-records))))
    (should (= (length (all-completions "release" table)) 2))
    (should (equal (try-completion "release" table) "release"))
    (should (test-completion (car (all-completions "release" table)) table))))

(ert-deftest test-assist-web-completion-rejects-thread-removed-during-selection ()
  (let* ((thread '((id . "thread-1") (description . "Release")
                   (search_description . "release")
                   (repo_label . "Assist") (status . "ready")))
         (emacsos-assist-web--catalog (test-assist-web--catalog thread))
         notice)
    (cl-letf (((symbol-function 'emacsos-assist-web-refresh-threads) #'ignore)
              ((symbol-function 'completing-read)
               (lambda (_prompt table &rest _)
                 (prog1 (car (all-completions "" table))
                   (setq emacsos-assist-web--catalog
                         (test-assist-web--catalog)))))
              ((symbol-function 'emacsos-assist-web--show-thread)
               (lambda (&rest _) (ert-fail "removed thread must not open")))
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (setq notice (apply #'format format-string args)))))
      (emacsos-assist-web-open-thread))
    (should (string-match-p "no longer available" notice))))

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

(ert-deftest test-assist-web-rejects-unbounded-or-spoofable-snapshot-metadata ()
  (dolist (case `((description . ,(concat "false" (string #x202e) "title"))
                  (status . "ready\nfalse status")
                  (error . ,(make-string 513 ?x))
                  (repo_label . ,(concat "same" (string #x034f)))))
    (let* ((snapshot (copy-tree test-assist-web--snapshot))
           (thread (alist-get 'thread snapshot)))
      (if (eq (car case) 'repo_label)
          (setf (alist-get 'repo_label (alist-get 'workspace thread)) (cdr case))
        (setf (alist-get (car case) thread) (cdr case)))
      (setf (alist-get 'thread snapshot) thread)
      (should-error
       (emacsos-assist-web--require-snapshot snapshot "thread-1")))))

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

(ert-deftest test-assist-web-catalog-json-does-not-intern-untrusted-keys ()
  (let ((key "assist-web-untrusted-key-7d52a9"))
    (should-not (intern-soft key))
    (with-temp-buffer
      (insert (format "{\"threads\":[],\"repositories\":[],\"harnesses\":[],\"%s\":1}"
                      key))
      (setq-local url-http-response-status 200
                  url-http-content-type "application/json"
                  url-http-end-of-headers (copy-marker (point-min)))
      (let ((value (emacsos-assist-web--response-json
                    (current-buffer) nil 'array 'hash-table)))
        (should (= (gethash key value) 1))))
    (should-not (intern-soft key))))

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
  "A structured non-2xx response needs a real status and one JSON object."
  (dolist (case '((nil "{}") (0 "{}") (999 "{}")
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
  (let* ((emacsos-assist-web--catalog-state 'cached)
         (emacsos-assist-web--catalog
          (test-assist-web--catalog
           '((id . "thread-1") (description . "Thread")
             (repo_label . "Assist") (status . "running"))))
         (record (car (emacsos-assist-web--completion-records))))
    (should (equal (plist-get record :display)
                   (concat
                    "#1  "
                    (emacsos-assist-web--isolate-display-text
                     "*assist Thread - Assist* [running, cached]"))))))

(ert-deftest test-assist-web-cache-rejects-an-oversized-record ()
  (let ((emacsos-assist-web-cache-directory (make-temp-file "assist-web-cache-" t))
        (emacsos-assist-web-max-cache-bytes 8))
    (unwind-protect
        (should-error (emacsos-assist-web--write-cache "threads.json" '((x . "too long"))))
      (delete-directory emacsos-assist-web-cache-directory t))))

(ert-deftest test-assist-web-empty-wire-catalog-cache-round-trips-as-arrays ()
  (let ((emacsos-assist-web-cache-directory
         (make-temp-file "assist-web-cache-" t))
        (wire (test-assist-web--wire-catalog nil nil nil)))
    (unwind-protect
        (progn
          (emacsos-assist-web--write-cache emacsos-assist-web--catalog-file wire)
          (should (equal (emacsos-assist-web--read-catalog-cache)
                         '((threads . nil)
                           (repositories . nil)
                           (harnesses . nil)))))
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
          (insert "\nevent: terminal\ndata: {}\n\n")
          (setq-local url-http-end-of-headers (copy-marker (point-min)))
          (cl-letf (((symbol-function 'emacsos-assist-web--dispatch-event)
                     (lambda (actual-target event data)
                       (setq seen (list actual-target event data)))))
            (emacsos-assist-web--drain-events target 0 (point-max)))
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
            (insert "\nevent: terminal\ndata: {}\n\n")
            (setq-local url-http-end-of-headers (copy-marker (point-min)))
            (emacsos-assist-web--drain-events target 0 (point-max)))
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
                      (insert "\nevent: terminal\ndata: {}\n\n")
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
                            (insert "\nevent: terminal\ndata: {}\n\n")
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
          (insert "\nevent: status\ndata: {}\n\nevent: status\ndata: {}\n\n")
          (setq-local url-http-end-of-headers (copy-marker (point-min)))
          (cl-letf (((symbol-function 'emacsos-assist-web--dispatch-event)
                     (lambda (_target event _data) (push event seen))))
            (emacsos-assist-web--drain-events target 0 (point-max)))
          (should (equal seen '("status" "status"))))
      (when (buffer-live-p target) (kill-buffer target))
      (when (buffer-live-p source) (kill-buffer source)))))

(ert-deftest test-assist-web-event-parser-accepts-decoded-crlf-records ()
  "Decoded SSE CRLF framing dispatches the same event as LF framing."
  (let ((target (generate-new-buffer " *assist-web-target*"))
        (source (generate-new-buffer " *assist-web-source*"))
        seen)
    (unwind-protect
        (with-current-buffer source
          (insert "\nevent: status\r\ndata: {\"status\":\"working\"}\r\n\r\n")
          (setq-local url-http-end-of-headers (copy-marker (point-min)))
          (cl-letf (((symbol-function 'emacsos-assist-web--dispatch-event)
                     (lambda (_target event data) (setq seen (list event data)))))
            (emacsos-assist-web--drain-events target 0 (point-max)))
          (should (equal seen '("status" "{\"status\":\"working\"}"))))
      (when (buffer-live-p target) (kill-buffer target))
      (when (buffer-live-p source) (kill-buffer source)))))

(ert-deftest test-assist-web-live-status-rejects-spoofing-and-oversized-text ()
  (dolist (data
           (list (json-serialize
                  `((status . ,(concat "spoof" (string #x202e)))))
                 (json-serialize `((status . ,(make-string 513 ?x))))
                 "{}"
                 "null"
                 "{\"status\":\"working\",\"status\":null}"
                 "not json"))
    (let (interrupted)
      (with-temp-buffer
        (cl-letf (((symbol-function 'emacsos-assist-web--stream-interrupted)
                   (lambda (buffer reason)
                     (setq interrupted (list buffer reason)))))
          (emacsos-assist-web--dispatch-event
           (current-buffer) "status" data)
          (should (equal interrupted
                         (list (current-buffer) "invalid Assist status"))))))))

(ert-deftest test-assist-web-event-parser-tiny-fragments-scan-only-new-suffix ()
  "A fragmented record is dispatched once without quadratic retained-buffer copies."
  (let ((target (generate-new-buffer " *assist-web-target*"))
        (source (generate-new-buffer " *assist-web-source*"))
        (payload (concat "event: status\ndata: {\"status\":\"working\"}\n\n"))
        (copied 0) seen)
    (unwind-protect
        (with-current-buffer source
          (insert "\n")
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
                (emacsos-assist-web--drain-events target 0 (point-max)))))
          ;; The old parser copied the whole unfinished record per callback.
          ;; This implementation copies only a completed record for dispatch.
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

(ert-deftest test-assist-web-raw-filter-bounds-one-transport-callback ()
  "A raw callback is bounded without interpreting HTTP bytes as SSE records."
  (let ((emacsos-assist-web-max-stream-chunk-bytes 32) forwarded rejected)
    (funcall
     (emacsos-assist-web--guarded-filter
      (lambda (&rest _) (setq forwarded t))
      (lambda (_process problem) (setq rejected problem))
      t)
     nil
     (make-string 33 ?x))
    (should-not forwarded)
    (should (equal rejected "Assist stream transport chunk is too large"))))

(ert-deftest test-assist-web-raw-filter-rejects-transfer-encoding-chains ()
  "Only the exact transfer coding decoded by stock `url-http' is admitted."
  (let (forwarded rejected)
    (funcall
     (emacsos-assist-web--guarded-filter
      (lambda (&rest _) (setq forwarded t))
      (lambda (_process problem) (setq rejected problem))
      t)
     nil
     (concat "HTTP/1.1 200 OK\r\n"
             "Content-Type: text/event-stream\r\n"
             "Transfer-Encoding: identity, chunked\r\n\r\n"))
    (should-not forwarded)
    (should (equal rejected "Assist Web transfer encoding is not accepted"))))

(ert-deftest test-assist-web-stock-filter-rejects-folded-transfer-encoding ()
  "A folded transfer field cannot make raw chunk bytes look decoded."
  (let ((target (generate-new-buffer " *assist-web-target*"))
        (source (generate-new-buffer " *assist-web-source*"))
        process rejected seen filter)
    (unwind-protect
        (progn
          (setq process (make-pipe-process :name "assist-web-folded-transfer"
                                           :buffer source :noquery t))
          (with-current-buffer target (emacsos-assist-web-mode))
          (test-assist-web--initialize-url-http-response source process)
          (setq filter
                (emacsos-assist-web--guarded-filter
                 (emacsos-assist-web--event-filter
                  #'url-http-generic-filter target 0)
                 (lambda (_active problem) (setq rejected problem))
                 t))
          (cl-letf (((symbol-function 'emacsos-assist-web--dispatch-event)
                     (lambda (_target event data)
                       (push (list event data) seen))))
            (funcall filter process
                     (concat "HTTP/1.1 200 OK\r\n"
                             "Content-Type: text/event-stream\r\n"
                             "Transfer-Encoding: chunked\r\n"
                             "\t, gzip\r\n\r\n"
                             "1d\r\nevent: terminal\ndata: {}\n\n\r\n"
                             "0\r\n\r\n")))
          (should (equal rejected
                         "Assist Web folded response headers are not accepted"))
          (should-not seen))
      (when (process-live-p process) (delete-process process))
      (when (buffer-live-p target) (kill-buffer target))
      (when (buffer-live-p source) (kill-buffer source)))))

(ert-deftest test-assist-web-chunked-crlf-stream-uses-decoded-event-accounting ()
  "Stock `url-http' chunk framing never becomes decoded SSE data."
  (let ((target (generate-new-buffer " *assist-web-target*"))
        (source (generate-new-buffer " *assist-web-source*"))
        (emacsos-assist-web-max-event-bytes 52)
        (emacsos-assist-web-max-stream-chunk-bytes 512)
        process seen rejected filter)
    (unwind-protect
        (progn
          (setq process (make-pipe-process :name "assist-web-chunked-crlf"
                                           :buffer source :noquery t))
          (with-current-buffer target (emacsos-assist-web-mode))
          (test-assist-web--initialize-url-http-response source process)
          (setq filter
                (emacsos-assist-web--guarded-filter
                 (emacsos-assist-web--event-filter
                  #'url-http-generic-filter target 0)
                 (lambda (_active problem) (setq rejected problem))
                 t))
          (let ((first "event: status\r\n")
                (second "data: {\"status\":\"working\"}\r\n\r\n"))
            (cl-letf (((symbol-function 'emacsos-assist-web--dispatch-event)
                       (lambda (_target event data)
                         (push (list event data) seen))))
              (funcall
               filter process
               (concat "HTTP/1.1 200 OK\r\n"
                       "Content-Type: text/event-stream\r\n"
                       "Transfer-Encoding: chunked\r\n\r\n"
                       (format "%x\r\n" (string-bytes first)) first "\r\n"))
              ;; The raw transport terminator after an incomplete decoded
              ;; record must not complete or dispatch that record.
              (should-not seen)
              (funcall filter process
                       (concat (format "%x\r\n" (string-bytes second))
                               second "\r\n")))
            (should-not rejected)
            (should (equal (nreverse seen)
                           '(("status" "{\"status\":\"working\"}"))))
            (with-current-buffer source
              (should (= url-http-chunked-counter 2)))))
      (when (process-live-p process) (delete-process process))
      (when (buffer-live-p target) (kill-buffer target))
      (when (buffer-live-p source) (kill-buffer source)))))

(ert-deftest test-assist-web-stream-parser-hot-reload-ignores-old-raw-count ()
  "A legacy response migrates its decoded tail without retaining raw accounting."
  (let ((target (generate-new-buffer " *assist-web-target*"))
        (source (generate-new-buffer " *assist-web-source*"))
        seen)
    (unwind-protect
        (progn
          (with-current-buffer target (emacsos-assist-web-mode))
          (with-current-buffer source
            (insert "HTTP/1.1 200 OK\r\n\r\nevent: terminal\r\n\r\n")
            (setq-local url-http-end-of-headers (copy-marker 19)
                        url-http-transfer-encoding nil
                        url-http-content-length nil
                        emacsos-assist-web--stream-body-marker (copy-marker 20)
                        emacsos-assist-web--stream-unconsumed-bytes
                        emacsos-assist-web-max-event-bytes)
            (cl-letf (((symbol-function 'emacsos-assist-web--dispatch-event)
                       (lambda (_target event data)
                         (setq seen (list event data)))))
              (emacsos-assist-web--drain-events target 0 (point-max))))
          (should (equal seen '("terminal" ""))))
      (when (buffer-live-p target) (kill-buffer target))
      (when (buffer-live-p source) (kill-buffer source)))))

(ert-deftest test-assist-web-hot-reload-retires-an-installed-stream-filter ()
  "Reload cleanup cannot leave a pre-reload process-filter closure active."
  (let ((target (generate-new-buffer " *assist-web-target*"))
        (source (generate-new-buffer " *assist-web-source*"))
        process)
    (unwind-protect
        (progn
          (setq process (make-pipe-process :name "assist-web-old-filter"
                                           :buffer source :noquery t
                                           :filter (lambda (&rest _))))
          (with-current-buffer target
            (emacsos-assist-web-mode)
            (setq-local emacsos-assist-web--stream-process process
                        emacsos-assist-web--stream-response source))
          (emacsos-assist-web--retire-active-streams-after-reload)
          (should-not (process-live-p process))
          (with-current-buffer target
            (should-not emacsos-assist-web--stream-process)
            (should-not emacsos-assist-web--stream-response)))
      (when (process-live-p process) (delete-process process))
      (when (buffer-live-p target) (kill-buffer target))
      (when (buffer-live-p source) (kill-buffer source)))))

(ert-deftest test-assist-web-stock-filter-bounds-an-incomplete-chunk-header ()
  "Opaque chunk framing is bounded before stock regex matching can grow."
  (let ((target (generate-new-buffer " *assist-web-target*"))
        (source (generate-new-buffer " *assist-web-source*"))
        (emacsos-assist-web-max-header-bytes 128)
        process rejected filter)
    (unwind-protect
        (progn
          (setq process (make-pipe-process :name "assist-web-incomplete-chunk"
                                           :buffer source :noquery t))
          (with-current-buffer target (emacsos-assist-web-mode))
          (test-assist-web--initialize-url-http-response source process)
          (setq filter
                (emacsos-assist-web--guarded-filter
                 (emacsos-assist-web--event-filter
                  #'url-http-generic-filter target 0)
                 (lambda (_active problem) (setq rejected problem))
                 t))
          (funcall filter process
                   (concat "HTTP/1.1 200 OK\r\n"
                           "Content-Type: text/event-stream\r\n"
                           "Transfer-Encoding: chunked\r\n\r\n"
                           "a"))
          (funcall filter process (make-string 64 ?a))
          (funcall filter process (make-string 64 ?a))
          (should (equal rejected
                         "Assist stream transport framing is too large"))
          (with-current-buffer source
            (should (<= (emacsos-assist-web--pending-transport-bytes process)
                        emacsos-assist-web-max-header-bytes))))
      (when (process-live-p process) (delete-process process))
      (when (buffer-live-p target) (kill-buffer target))
      (when (buffer-live-p source) (kill-buffer source)))))

(ert-deftest test-assist-web-stock-filter-rejects-an-oversized-content-length ()
  "A fixed-length SSE response cannot retain an attacker-sized body."
  (let ((target (generate-new-buffer " *assist-web-target*"))
        (source (generate-new-buffer " *assist-web-source*"))
        (emacsos-assist-web-max-response-bytes 128)
        process interrupted filter)
    (unwind-protect
        (progn
          (setq process (make-pipe-process :name "assist-web-content-length"
                                           :buffer source :noquery t))
          (with-current-buffer target (emacsos-assist-web-mode))
          (test-assist-web--initialize-url-http-response source process)
          (setq filter
                (emacsos-assist-web--guarded-filter
                 (emacsos-assist-web--event-filter
                  #'url-http-generic-filter target 0)
                 #'ignore t))
          (cl-letf (((symbol-function 'emacsos-assist-web--stream-interrupted)
                     (lambda (_target problem) (setq interrupted problem))))
            (funcall filter process
                     (concat "HTTP/1.1 200 OK\r\n"
                             "Content-Type: text/event-stream\r\n"
                             "Content-Length: 129\r\n\r\n")))
          (should (equal interrupted "Assist stream response is too large")))
      (when (process-live-p process) (delete-process process))
      (when (buffer-live-p target) (kill-buffer target))
      (when (buffer-live-p source) (kill-buffer source)))))

(ert-deftest test-assist-web-stock-filter-rejects-an-oversized-decoded-chunk ()
  "Stock decoding cannot retain a declared entity chunk above its bound."
  (let ((target (generate-new-buffer " *assist-web-target*"))
        (source (generate-new-buffer " *assist-web-source*"))
        (emacsos-assist-web-max-stream-chunk-bytes 128)
        process rejected interrupted filter)
    (unwind-protect
        (progn
          (setq process (make-pipe-process :name "assist-web-decoded-chunk"
                                           :buffer source :noquery t))
          (with-current-buffer target (emacsos-assist-web-mode))
          (test-assist-web--initialize-url-http-response source process)
          (setq filter
                (emacsos-assist-web--guarded-filter
                 (emacsos-assist-web--event-filter
                  #'url-http-generic-filter target 0)
                 (lambda (_active problem) (setq rejected problem))
                 t))
          (cl-letf (((symbol-function 'emacsos-assist-web--stream-interrupted)
                     (lambda (_target problem) (setq interrupted problem))))
            (funcall filter process
                     (concat "HTTP/1.1 200 OK\r\n"
                             "Content-Type: text/event-stream\r\n"
                             "Transfer-Encoding: chunked\r\n\r\n"
                             "81\r\n")))
          (should-not rejected)
          (should (equal interrupted
                         "Assist stream transport chunk is too large")))
      (when (process-live-p process) (delete-process process))
      (when (buffer-live-p target) (kill-buffer target))
      (when (buffer-live-p source) (kill-buffer source)))))

(ert-deftest test-assist-web-stock-filter-preserves-split-final-chunk-crlf ()
  "Parser pruning preserves stock `url-http' final-chunk positions."
  (let ((target (generate-new-buffer " *assist-web-target*"))
        (source (generate-new-buffer " *assist-web-source*"))
        process activated seen filter)
    (unwind-protect
        (progn
          (setq process (make-pipe-process :name "assist-web-final-crlf"
                                           :buffer source :noquery t))
          (with-current-buffer target (emacsos-assist-web-mode))
          (test-assist-web--initialize-url-http-response source process)
          (with-current-buffer source
            (setq-local url-callback-function (lambda (&rest _) (setq activated t))))
          (setq filter
                (emacsos-assist-web--guarded-filter
                 (emacsos-assist-web--event-filter
                  #'url-http-generic-filter target 0)
                 #'ignore t))
          (let ((event "event: terminal\r\ndata: {}\r\n\r\n"))
            (cl-letf (((symbol-function 'emacsos-assist-web--dispatch-event)
                       (lambda (_target name _data) (setq seen name))))
              (funcall filter process
                       (concat "HTTP/1.1 200 OK\r\n"
                               "Content-Type: text/event-stream\r\n"
                               "Transfer-Encoding: chunked\r\n\r\n"
                               (format "%x\r\n" (string-bytes event))
                               event "\r\n0\r\n"))
              (should (equal seen "terminal"))
              (with-current-buffer source
                (should (integerp url-http-chunked-last-crlf-missing)))
              (funcall filter process "\r\n")))
          (should activated)
          (with-current-buffer source
            (should (= url-http-chunked-counter 2))))
      (when (process-live-p process) (delete-process process))
      (when (buffer-live-p target) (kill-buffer target))
      (when (buffer-live-p source) (kill-buffer source)))))

(ert-deftest test-assist-web-event-parser-rejects-an-oversized-tail-in-place ()
  "An unfinished event is rejected without an oversized parser copy."
  (let ((target (generate-new-buffer " *assist-web-target*"))
        (source (generate-new-buffer " *assist-web-source*"))
        (emacsos-assist-web-max-event-bytes 32)
        interrupted)
    (unwind-protect
        (progn
          (with-current-buffer target (emacsos-assist-web-mode))
          (with-current-buffer source
            (insert "\n" (make-string 33 ?x))
            (setq-local url-http-end-of-headers (copy-marker (point-min))
                        url-http-transfer-encoding nil
                        url-http-content-length nil)
            (cl-letf (((symbol-function 'emacsos-assist-web--stream-interrupted)
                       (lambda (_target problem) (setq interrupted problem))))
              (emacsos-assist-web--drain-events target 0 (point-max)))
            (should (= (buffer-size) 1)))
          (should (equal interrupted "Assist event is too large")))
      (when (buffer-live-p target) (kill-buffer target))
      (when (buffer-live-p source) (kill-buffer source)))))

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
                ((symbol-function 'emacsos-assist-web--observe-entry) #'ignore))
        (emacsos-assist-web-send))
      (should (= (how-many "you> old" (point-min) (point-max)) 1))
      (should (= (how-many "you> new" (point-min) (point-max)) 1))
      (let ((entry (emacsos-assist-web--queue-head)))
        (should (markerp (plist-get entry :assistant-start)))
        (goto-char (marker-position (plist-get entry :assistant-start)))
        (should (> (point) (string-match "you> new" (buffer-string))))))))

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
  (let ((oversized (json-encode `((attempt . 1) (index . 2)
                                   (text . ,(make-string
                                             (1+ (* 16 1024)) ?x)))))
        (hostile (json-encode `((attempt . 1) (index . 2)
                                 (text . ,(concat "spoof"
                                                  (string #x202e)))))))
    (dolist (data (list "{not json}" oversized hostile))
      (with-temp-buffer
        (emacsos-assist-web-mode)
        (emacsos-assist-web--write-prompt)
        (emacsos-assist-web--append-pending "hello")
        (emacsos-assist-web--reset-assistant 1)
        (emacsos-assist-web--append-delta 1 1 "partial")
        (emacsos-assist-web--dispatch-event
         (current-buffer) "assistant-delta" data)
        (should (string-match-p "partial" (buffer-string)))
        (should (equal emacsos-assist-web--stream-status
                       "invalid Assist delta"))))))

(ert-deftest test-assist-web-cumulative-deltas-stop-before-message-cap ()
  "Individually bounded deltas cannot build an oversized provisional message."
  (let ((emacsos-assist-web--max-message-bytes 7))
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (emacsos-assist-web--write-prompt)
      (emacsos-assist-web--append-pending "hello")
      (emacsos-assist-web--reset-assistant 1)
      (emacsos-assist-web--append-delta 1 1 "partial")
      (emacsos-assist-web--dispatch-event
       (current-buffer) "assistant-delta"
       (json-encode '((attempt . 1) (index . 2) (text . "x"))))
      (should (string-match-p "partial" (buffer-string)))
      (should-not (string-match-p "partialx" (buffer-string)))
      (should-not emacsos-assist-web--stream-raw-bytes)
      (should (= emacsos-assist-web--stream-index 1))
      (should (equal emacsos-assist-web--stream-status
                     "invalid Assist delta")))))

(ert-deftest test-assist-web-hot-reload-fails-closed-without-raw-state ()
  (let ((emacsos-assist-web--max-message-bytes 7))
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (emacsos-assist-web--write-prompt)
      (emacsos-assist-web--append-pending "hello")
      (emacsos-assist-web--reset-assistant 1)
      (emacsos-assist-web--append-delta 1 1 "partial")
      ;; A newly introduced `defvar-local' has no trustworthy state in an
      ;; already-streaming buffer after code reload.
      (kill-local-variable 'emacsos-assist-web--stream-raw-bytes)
      (kill-local-variable 'emacsos-assist-web--stream-undecided-suffix)
      (emacsos-assist-web--dispatch-event
       (current-buffer) "assistant-delta"
       (json-encode '((attempt . 1) (index . 2) (text . "x"))))
      (should (string-match-p "partial" (buffer-string)))
      (should-not (string-match-p "partialx" (buffer-string)))
      (should (= emacsos-assist-web--stream-index 1))
      (should (equal emacsos-assist-web--stream-status
                     "Assist stream is missing its reset; refresh to reconcile"))
      (emacsos-assist-web--reset-assistant 2)
      (emacsos-assist-web--append-delta 2 1 "new")
      (should (= emacsos-assist-web--stream-raw-bytes 3)))))

(ert-deftest test-assist-web-canonicalizes-message-line-endings-and-flags ()
  (let* ((snapshot (copy-tree test-assist-web--snapshot))
         (text (concat "a\r\nb\rc" (nth 0 emacsos-assist-web--subdivision-flags))))
    (setf (alist-get 'text (car (alist-get 'messages snapshot))) text)
    (setq snapshot (emacsos-assist-web--require-snapshot snapshot))
    (should (equal (alist-get 'text (car (alist-get 'messages snapshot)))
                   (concat "a\nb\nc" (nth 0 emacsos-assist-web--subdivision-flags))))
    (should (equal snapshot (emacsos-assist-web--require-snapshot snapshot))))
  (dolist (flag emacsos-assist-web--subdivision-flags)
    (let ((snapshot (copy-tree test-assist-web--snapshot)))
      (setf (alist-get 'text (car (alist-get 'messages snapshot))) flag)
      (should (equal (alist-get 'text
                                (car (alist-get 'messages
                                                (emacsos-assist-web--require-snapshot snapshot))))
                     flag)))))

(ert-deftest test-assist-web-rejects-unapproved-tag-text ()
  (dolist (text (list (concat (string #x1f3f4 #xe0067 #xe007f))
                      (concat (string #x1f3f4 #xe0067 #xe0062 #xe007f))
                      (concat (nth 0 emacsos-assist-web--subdivision-flags)
                              (string #xe0067))))
    (let ((snapshot (copy-tree test-assist-web--snapshot)))
      (setf (alist-get 'text (car (alist-get 'messages snapshot))) text)
      (should-error (emacsos-assist-web--require-snapshot snapshot)))))

(ert-deftest test-assist-web-raw-transcript-limits-precede-normalization ()
  (let ((snapshot (copy-tree test-assist-web--snapshot)))
    (setf (alist-get 'text (car (alist-get 'messages snapshot))) "\r\nx")
    (let ((emacsos-assist-web--max-message-bytes 2))
      (should-error (emacsos-assist-web--require-snapshot snapshot)))
    (let ((emacsos-assist-web--max-message-bytes 3))
      (should (equal (alist-get 'text
                                (car (alist-get 'messages
                                                (emacsos-assist-web--require-snapshot snapshot))))
                     "\nx")))))

(ert-deftest test-assist-web-raw-aggregate-and-exact-canonical-limits ()
  (let ((snapshot (copy-tree test-assist-web--snapshot)))
    (setf (alist-get 'messages snapshot)
          '(((id . "m-1") (role . "assistant") (text . "\r\nx") (state . "final"))
            ((id . "m-2") (role . "assistant") (text . "\r\ny") (state . "final"))))
    (let ((emacsos-assist-web--max-snapshot-transcript-bytes 5))
      (should-error (emacsos-assist-web--require-snapshot snapshot))))
  (let ((snapshot (copy-tree test-assist-web--snapshot)))
    (setf (alist-get 'text (car (alist-get 'messages snapshot))) "xy")
    (let ((emacsos-assist-web--max-message-bytes 2)
          (emacsos-assist-web--max-snapshot-transcript-bytes 2))
      (should (emacsos-assist-web--require-snapshot snapshot)))))

(ert-deftest test-assist-web-history-page-raw-aggregate-rejects-before-normalization ()
  (let ((current (copy-tree test-assist-web--snapshot))
        (page '((thread . ((id . "thread-1") (description . "Thread") (status . "ready")
                           (workspace . ((repo_label . "Assist")))))
                (messages . (((id . "m-0") (role . "user") (text . "\r\nx") (state . "final"))
                             ((id . "m-minus") (role . "user") (text . "\r\ny") (state . "final")))))))
    (let ((emacsos-assist-web--max-snapshot-transcript-bytes 5))
      (should-error (emacsos-assist-web--require-history-page page "thread-1" current "cursor-1")))))

(ert-deftest test-assist-web-rejected-transcript-does-not-partially-canonicalize ()
  (let ((snapshot (copy-tree test-assist-web--snapshot)))
    (setf (alist-get 'messages snapshot)
          `(((id . "m-1") (role . "assistant") (text . "a\r\nb") (state . "final"))
            ((id . "m-2") (role . "assistant")
             (text . ,(concat "bad" (string #x202e))) (state . "final"))))
    (let ((before (copy-tree snapshot)))
      (should-error (emacsos-assist-web--require-snapshot snapshot))
      (should (equal snapshot before)))))

(ert-deftest test-assist-web-stream-canonicalization-is-segmentation-invariant ()
  (dolist (text (cons "a\r\nb" emacsos-assist-web--subdivision-flags))
    (dotimes (split (1- (length text)))
      (with-temp-buffer
        (emacsos-assist-web-mode)
        (emacsos-assist-web--write-prompt)
        (emacsos-assist-web--append-pending "hello")
        (emacsos-assist-web--reset-assistant 1)
        (emacsos-assist-web--append-delta 1 1 (substring text 0 (1+ split)))
        (emacsos-assist-web--append-delta 1 2 (substring text (1+ split)))
        (should (string-match-p
                 (regexp-quote (emacsos-assist-web--canonical-message-text text))
                 (buffer-string)))
        (should (string-empty-p emacsos-assist-web--stream-undecided-suffix))
        (should (= emacsos-assist-web--stream-raw-bytes (string-bytes text)))))))

(ert-deftest test-assist-web-stream-keeps-unsafe-flag-prefix-unrendered ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (emacsos-assist-web--write-prompt)
    (emacsos-assist-web--append-pending "hello")
    (emacsos-assist-web--reset-assistant 1)
    (emacsos-assist-web--append-delta 1 1 (string #x1f3f4))
    (should-not (string-match-p (regexp-quote (string #x1f3f4)) (buffer-string)))
    (emacsos-assist-web--dispatch-event
     (current-buffer) "assistant-delta"
     (json-encode `((attempt . 1) (index . 2) (text . ,(string #xe007a)))))
    (should-not (string-match-p (regexp-quote (string #x1f3f4)) (buffer-string)))
    (should (equal emacsos-assist-web--stream-status "invalid Assist delta"))))

(ert-deftest test-assist-web-stream-keeps-multiple-suffix-only-events-bounded ()
  (let ((flag (nth 0 emacsos-assist-web--subdivision-flags)))
    (with-temp-buffer
      (emacsos-assist-web-mode) (emacsos-assist-web--write-prompt)
      (emacsos-assist-web--append-pending "hello") (emacsos-assist-web--reset-assistant 1)
      (dotimes (index (1- (length flag)))
        (emacsos-assist-web--append-delta 1 (1+ index) (substring flag index (1+ index)))
        (should-not (string-match-p (regexp-quote (string #x1f3f4)) (buffer-string))))
      (emacsos-assist-web--append-delta 1 (length flag) (substring flag (1- (length flag))))
      (should (string-match-p (regexp-quote flag) (buffer-string)))
      (emacsos-assist-web--stream-cleanup t t)
      (should-not emacsos-assist-web--stream-undecided-suffix)
      (should-not emacsos-assist-web--stream-raw-bytes))))

(ert-deftest test-assist-web-stream-lifecycle-discards-held-suffix ()
  (dolist (finish (list (lambda () (emacsos-assist-web--reset-assistant 2))
                        (lambda () (emacsos-assist-web--stream-interrupted (current-buffer) "lost"))
                        (lambda () (emacsos-assist-web--stream-cleanup t t))))
    (with-temp-buffer
      (emacsos-assist-web-mode) (emacsos-assist-web--write-prompt)
      (emacsos-assist-web--append-pending "hello") (emacsos-assist-web--reset-assistant 1)
      (emacsos-assist-web--append-delta 1 1 (string #x1f3f4))
      (should emacsos-assist-web--stream-undecided-suffix)
      (funcall finish)
      (should (or (equal emacsos-assist-web--stream-undecided-suffix "")
                  (null emacsos-assist-web--stream-undecided-suffix))))))

(ert-deftest test-assist-web-stream-terminal-flushes-only-safe-tails ()
  (dolist (tail (list "\r" (string #x1f3f4)))
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (emacsos-assist-web--write-prompt)
      (emacsos-assist-web--append-pending "hello")
      (emacsos-assist-web--reset-assistant 1)
      (emacsos-assist-web--append-delta 1 1 tail)
      (emacsos-assist-web--dispatch-event (current-buffer) "terminal" "{}")
      (should (string-match-p (regexp-quote (if (equal tail "\r") "\n" tail))
                              (buffer-string)))))
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (emacsos-assist-web--write-prompt)
    (emacsos-assist-web--append-pending "hello")
    (emacsos-assist-web--reset-assistant 1)
    (emacsos-assist-web--append-delta 1 1
                                      (substring (nth 0 emacsos-assist-web--subdivision-flags) 0 2))
    (emacsos-assist-web--dispatch-event (current-buffer) "terminal" "{}")
    (should (equal emacsos-assist-web--stream-status "invalid Assist delta"))))

(ert-deftest test-assist-web-stream-terminal-tail-reconciles-authoritatively ()
  (let ((emacsos-assist-web-cache-directory (make-temp-file "assist-web-terminal-" t)))
    (unwind-protect
        (with-temp-buffer
          (emacsos-assist-web-mode) (emacsos-assist-web--write-prompt)
          (setq emacsos-assist-web--thread-id "thread-1")
          (emacsos-assist-web--append-pending "hello") (emacsos-assist-web--reset-assistant 1)
          (emacsos-assist-web--append-delta 1 1 "\r")
          (cl-letf (((symbol-function 'emacsos-assist-web--request)
                     (lambda (_m _p _v callback &rest _) (funcall callback test-assist-web--snapshot nil)))
                    ((symbol-function 'emacsos-assist-web--try-write-cache) #'ignore))
            (emacsos-assist-web--dispatch-event (current-buffer) "terminal" "{}"))
          (should (equal (alist-get 'text (car (alist-get 'messages emacsos-assist-web--snapshot))) "old")))
      (delete-directory emacsos-assist-web-cache-directory t))))

(ert-deftest test-assist-web-delta-admits-layout-and-emoji-format-points ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (emacsos-assist-web--write-prompt)
    (emacsos-assist-web--append-pending "hello")
    (emacsos-assist-web--reset-assistant 1)
    (let ((text (concat "first\n\tsecond "
                        (string #x2764 #xfe0f #x200d #x1f525))))
      (emacsos-assist-web--dispatch-event
       (current-buffer) "assistant-delta"
       (json-encode `((attempt . 1) (index . 1) (text . ,text))))
      (should (string-match-p (regexp-quote text) (buffer-string)))
      (should (= emacsos-assist-web--stream-index 1)))))

(ert-deftest test-assist-web-snapshot-bounds-message-and-cumulative-text ()
  (let ((snapshot (copy-tree test-assist-web--snapshot)))
    (let ((emacsos-assist-web--max-message-bytes 2))
      (should-error (emacsos-assist-web--require-snapshot snapshot)))
    (let ((emacsos-assist-web--max-snapshot-messages 0))
      (should-error (emacsos-assist-web--require-snapshot snapshot)))
    (let ((emacsos-assist-web--max-snapshot-transcript-bytes 2))
      (should-error (emacsos-assist-web--require-snapshot snapshot)))))

(ert-deftest test-assist-web-snapshot-rejects-transcript-spoofing-controls ()
  (dolist (character '(#x0000 #x007f #x2028 #x2029 #x202e #x034f #x2060
                       #x3164 #xe0001))
    (let ((snapshot (copy-tree test-assist-web--snapshot)))
      (setf (alist-get 'text (car (alist-get 'messages snapshot)))
            (concat "visible" (string character) "hidden"))
      (should-error (emacsos-assist-web--require-snapshot snapshot)))))

(ert-deftest test-assist-web-snapshot-admits-layout-and-emoji-format-points ()
  (let* ((snapshot (copy-tree test-assist-web--snapshot))
         (text (concat "first\n\tsecond "
                       (string #x2764 #xfe0f #x200d #x1f525))))
    (setf (alist-get 'text (car (alist-get 'messages snapshot))) text)
    (should (equal (alist-get 'text
                              (car (alist-get
                                    'messages
                                    (emacsos-assist-web--require-snapshot
                                     snapshot))))
                   text))))

(ert-deftest test-assist-web-snapshot-discards-unconsumed-message-extensions ()
  (let ((snapshot (copy-tree test-assist-web--snapshot)))
    (setf (alist-get 'remote_extension
                     (car (alist-get 'messages snapshot)))
          (make-string (* 512 1024) ?x))
    (emacsos-assist-web--require-snapshot snapshot)
    (should-not (assq 'remote_extension
                      (car (alist-get 'messages snapshot))))
    (should (equal (mapcar #'car (car (alist-get 'messages snapshot)))
                   '(id role text state)))))

(ert-deftest test-assist-web-history-page-validates-before-union-policy ()
  (let ((current (copy-tree test-assist-web--snapshot))
        (page '((thread . ((id . "thread-1") (description . "Thread")
                           (status . "ready")
                           (workspace . ((repo_label . "Assist")))))
                (messages . (((id . "m-0") (role . "user") (text . "older")
                              (state . "final"))))
                (has_older_messages . nil) (next_before . nil)))
        (emacsos-assist-web--max-rendered-messages 1))
    (should (eq
             (emacsos-assist-web--require-history-page
              page "thread-1" current "cursor-1")
             page))))

(ert-deftest test-assist-web-history-combines-wire-pages-to-rendered-limit ()
  (let ((current (copy-tree test-assist-web--snapshot))
        (page '((thread . ((id . "thread-1") (description . "Thread")
                           (status . "ready")
                           (workspace . ((repo_label . "Assist")))))
                (messages . (((id . "m-0") (role . "user") (text . "older")
                              (state . "final"))))
                (has_older_messages . nil) (next_before . nil)))
        (emacsos-assist-web--max-snapshot-messages 1)
        (emacsos-assist-web--max-rendered-messages 2))
    (should (eq (emacsos-assist-web--require-history-page
                 page "thread-1" current "cursor-1")
                page))))

(ert-deftest test-assist-web-render-drops-oversized-live-reload-history ()
  (let ((fresh (copy-tree test-assist-web--snapshot))
        (older (copy-tree test-assist-web--snapshot))
        (emacsos-assist-web--max-rendered-messages 1))
    (setf (alist-get 'messages older)
          '(((id . "m-0") (role . "user") (text . "older")
             (state . "final"))
            ((id . "m-minus-1") (role . "assistant") (text . "oldest")
             (state . "final"))))
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1"
            emacsos-assist-web--snapshot older)
      (emacsos-assist-web--render fresh)
      (should (equal (mapcar (lambda (message) (alist-get 'id message))
                             (alist-get 'messages
                                        emacsos-assist-web--snapshot))
                     '("m-1"))))))

(ert-deftest test-assist-web-transcript-count-stops-at-the-first-excess-record ()
  (let* ((first '((id . "m-1") (role . "assistant") (text . "one")
                  (state . "final")))
         (second '((id . "m-2") (role . "assistant") (text . "two")
                   (state . "final")))
         (messages (list first second)))
    (setcdr (cdr messages) messages)
    (should-error
     (emacsos-assist-web--require-transcript-limits messages 1 1024))))


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

(ert-deftest test-assist-web-history-union-uses-canonical-not-mixed-raw-bytes ()
  (let ((emacsos-assist-web-cache-directory (make-temp-file "assist-web-history-" t))
        (emacsos-assist-web--max-rendered-transcript-bytes 3)
        (snapshot (copy-tree test-assist-web--snapshot))
        rendered
        (page '((thread . ((id . "thread-1") (description . "Thread")
                           (status . "ready")
                           (workspace . ((repo_label . "Assist")))))
                (messages . (((id . "m-0") (role . "user") (text . "\r\nx")
                              (state . "final"))))
                (has_older_messages . nil) (next_before . nil))))
    (setf (alist-get 'text (car (alist-get 'messages snapshot))) "z")
    (unwind-protect
        (with-temp-buffer
          (emacsos-assist-web-mode)
          (setq emacsos-assist-web--thread-id "thread-1")
          (cl-letf (((symbol-function 'emacsos-assist-web--read-cache)
                     (lambda (&rest _) snapshot))
                    ((symbol-function 'emacsos-assist-web--request)
                     (lambda (_method _path _payload callback &rest _)
                       (funcall callback page nil)))
                    ((symbol-function 'emacsos-assist-web--render)
                     (lambda (value &rest _) (setq rendered value))))
            (emacsos-assist-web-load-older))
          (should (equal (mapcar (lambda (message) (alist-get 'text message))
                                 (alist-get 'messages rendered))
                         '("\nx" "z"))))
      (delete-directory emacsos-assist-web-cache-directory t))))

(ert-deftest test-assist-web-history-at-rendered-cap-clears-older-cursor ()
  (let ((emacsos-assist-web-cache-directory (make-temp-file "assist-web-history-" t))
        (emacsos-assist-web--max-rendered-messages 2)
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
                    ((symbol-function 'emacsos-assist-web--request)
                     (lambda (_method _path _payload callback &rest _)
                       (funcall callback page nil))))
            (emacsos-assist-web-load-older))
          (should (= (length (alist-get 'messages
                                        emacsos-assist-web--snapshot)) 2))
          (should-not (alist-get 'has_older_messages
                                 emacsos-assist-web--snapshot))
          (should-not (alist-get 'next_before emacsos-assist-web--snapshot)))
      (delete-directory emacsos-assist-web-cache-directory t))))

(ert-deftest test-assist-web-history-at-rendered-byte-cap-clears-older-cursor ()
  (let ((emacsos-assist-web-cache-directory (make-temp-file "assist-web-history-" t))
        (emacsos-assist-web--max-rendered-transcript-bytes 8)
        (snapshot (copy-tree test-assist-web--snapshot))
        rendered
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
                    ((symbol-function 'emacsos-assist-web--request)
                     (lambda (_method _path _payload callback &rest _)
                       (funcall callback page nil)))
                    ((symbol-function 'emacsos-assist-web--render)
                     (lambda (value &rest _) (setq rendered value))))
            (emacsos-assist-web-load-older))
          (should (= (length (alist-get 'messages rendered)) 2))
          (should-not (alist-get 'has_older_messages rendered))
          (should-not (alist-get 'next_before rendered)))
      (delete-directory emacsos-assist-web-cache-directory t))))

(ert-deftest test-assist-web-history-over-rendered-cap-keeps-current-and-stops ()
  (let ((emacsos-assist-web-cache-directory (make-temp-file "assist-web-history-" t))
        (emacsos-assist-web--max-rendered-messages 1)
        (snapshot (copy-tree test-assist-web--snapshot))
        requested
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
                    ((symbol-function 'emacsos-assist-web--request)
                     (lambda (_method _path _payload callback &rest _)
                       (setq requested t)
                       (funcall callback page nil))))
            (emacsos-assist-web-load-older))
          (should requested)
          (should (equal (mapcar (lambda (message) (alist-get 'id message))
                                 (alist-get 'messages
                                            emacsos-assist-web--snapshot))
                         '("m-1")))
          (should-not (alist-get 'has_older_messages
                                 emacsos-assist-web--snapshot))
          (should-not (alist-get 'next_before emacsos-assist-web--snapshot)))
      (delete-directory emacsos-assist-web-cache-directory t))))

(ert-deftest test-assist-web-load-older-drops-oversized-legacy-state-before-copy ()
  (let ((emacsos-assist-web--max-rendered-messages 1)
        (snapshot (copy-tree test-assist-web--snapshot))
        requested)
    (setf (alist-get 'messages snapshot)
          '(((id . "m-0") (role . "user") (text . "older") (state . "final"))
            ((id . "m-1") (role . "assistant") (text . "newer")
             (state . "final"))))
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1"
            emacsos-assist-web--snapshot snapshot)
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (&rest _) (setq requested t))))
        (emacsos-assist-web-load-older))
      (should-not requested)
      (should-not emacsos-assist-web--snapshot))))

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

(ert-deftest test-assist-web-refresh-and-history-rejection-retain-the-view ()
  (let ((buffer (generate-new-buffer " *assist-rejected-refresh*"))
        (window (selected-window))
        (old-buffer (window-buffer (selected-window)))
        (emacsos-assist-web-cache-directory (make-temp-file "assist-web-rejected-" t))
        (good (copy-tree test-assist-web--snapshot))
        (bad nil))
    (setf (alist-get 'messages good)
          `(((id . "m-0") (role . "user") (text . "older") (state . "final"))
            ,@(alist-get 'messages good))
          (alist-get 'has_older_messages good) t
          (alist-get 'next_before good) "cursor-old")
    (setq bad (copy-tree good))
    (setf (alist-get 'text (car (alist-get 'messages bad)))
          (concat "bad" (string #x202e)))
    (unwind-protect
        (with-current-buffer buffer
          (emacsos-assist-web-mode)
          (set-window-buffer window buffer)
          (setq emacsos-assist-web--thread-id "thread-1")
          (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) #'ignore))
            (emacsos-assist-web--render good))
          (insert "draft")
          (goto-char (- (point-max) 2))
          (set-window-start window (point-min) t)
          (let* ((before (copy-tree emacsos-assist-web--snapshot))
                 (input-point-offset-before
                  (- (point) (emacsos-assist-web--prompt-start)))
                 (window-start-before (window-start window))
                 (input-before (emacsos-assist-web--input))
                 ;; Status is intentionally the only mutable rendered region.
                 (view-before
                  (concat (buffer-substring-no-properties
                           (point-min) emacsos-assist-web--status-start)
                          (buffer-substring-no-properties
                           emacsos-assist-web--status-end (point-max)))))
            (cl-letf (((symbol-function 'emacsos-assist-web--request)
                       (lambda (_m _p _v callback &rest _) (funcall callback bad nil)))
                      ((symbol-function 'emacsos-assist-web--try-write-cache)
                       (lambda (&rest _) (ert-fail "rejected refresh must not cache")))
                      ((symbol-function 'emacsos-assist-web--render)
                       (lambda (&rest _) (ert-fail "rejected refresh must not redraw"))))
              (emacsos-assist-web-refresh-thread))
            (should (equal emacsos-assist-web--snapshot before))
            (should (equal (mapcar (lambda (message) (alist-get 'id message))
                                   (alist-get 'messages emacsos-assist-web--snapshot))
                           '("m-0" "m-1")))
            (should (equal (alist-get 'next_before emacsos-assist-web--snapshot)
                           "cursor-old"))
            (should (equal (emacsos-assist-web--input) input-before))
            (should (= (- (point) (emacsos-assist-web--prompt-start))
                       input-point-offset-before))
            (should (= (window-start window) window-start-before))
            (should (equal (concat (buffer-substring-no-properties
                                    (point-min) emacsos-assist-web--status-start)
                                   (buffer-substring-no-properties
                                    emacsos-assist-web--status-end (point-max)))
                           view-before))
            (should (equal emacsos-assist-web--stream-status
                           "refresh rejected; cached; C-c C-a g retries"))
            (cl-letf (((symbol-function 'emacsos-assist-web--request)
                       (lambda (_m _p _v callback &rest _) (funcall callback bad nil)))
                      ((symbol-function 'emacsos-assist-web--render)
                       (lambda (&rest _) (ert-fail "rejected history must not redraw"))))
              (emacsos-assist-web-load-older))
            (should (equal emacsos-assist-web--snapshot before))
            (should (equal (alist-get 'next_before emacsos-assist-web--snapshot)
                           "cursor-old"))
            (should (equal (emacsos-assist-web--input) input-before))
            (should (= (- (point) (emacsos-assist-web--prompt-start))
                       input-point-offset-before))
            (should (= (window-start window) window-start-before))
            (should (equal (concat (buffer-substring-no-properties
                                    (point-min) emacsos-assist-web--status-start)
                                   (buffer-substring-no-properties
                                    emacsos-assist-web--status-end (point-max)))
                           view-before))
            (should (equal emacsos-assist-web--stream-status
                           "older history rejected; cached; C-c C-a l retries"))))
      (set-window-buffer window old-buffer)
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (delete-directory emacsos-assist-web-cache-directory t))))

(ert-deftest test-assist-web-first-refresh-rejection-has-no-cache-status ()
  (let ((bad (copy-tree test-assist-web--snapshot))
        (emacsos-assist-web-cache-directory (make-temp-file "assist-web-first-rejected-" t)))
    (setf (alist-get 'text (car (alist-get 'messages bad))) (concat "bad" (string #x202e)))
    (unwind-protect
        (with-temp-buffer
          (emacsos-assist-web-mode) (emacsos-assist-web--write-prompt)
          (setq emacsos-assist-web--thread-id "thread-1")
          (cl-letf (((symbol-function 'emacsos-assist-web--request)
                     (lambda (_m _p _v callback &rest _) (funcall callback bad nil))))
            (emacsos-assist-web-refresh-thread))
          (should-not emacsos-assist-web--snapshot)
          (should (equal emacsos-assist-web--stream-status "refresh rejected; C-c C-a g retries")))
      (delete-directory emacsos-assist-web-cache-directory t))))

(ert-deftest test-assist-web-list-activation-refreshes-crlf-and-england-flag ()
  (let* ((thread '((id . "thread-1") (description . "Thread")
                   (repo_label . "Assist") (status . "ready")))
         (snapshot (copy-tree test-assist-web--snapshot))
         (flag (nth 0 emacsos-assist-web--subdivision-flags))
         (buffer nil)
         (list-buffer nil)
         (emacsos-assist-web-cache-directory (make-temp-file "assist-web-list-" t))
         (emacsos-assist-web--catalog (test-assist-web--catalog thread)))
    (setf (alist-get 'text (car (alist-get 'messages snapshot)))
          (concat "a\r\nb " flag))
    (unwind-protect
        (cl-letf (((symbol-function 'emacsos-assist-web--read-cache) (lambda (&rest _) nil))
                  ((symbol-function 'emacsos-assist-web--request)
                   (lambda (_m _p _v callback &rest _) (funcall callback snapshot nil)))
                  ((symbol-function 'emacsos-assist-web--try-write-cache) #'ignore)
                  ((symbol-function 'switch-to-buffer) #'ignore))
          (setq list-buffer (get-buffer-create emacsos-assist-web--thread-list-buffer-name))
          (with-current-buffer list-buffer
            (emacsos-assist-web-thread-list-mode)
            (emacsos-assist-web--render-thread-list)
            (goto-char (emacsos-assist-web--thread-row-position "thread-1"))
            (emacsos-assist-web-list-activate))
          (setq buffer (emacsos-assist-web--thread-buffer "thread-1"))
          (with-current-buffer buffer
            (should (string-match-p (regexp-quote (concat "a\nb " flag)) (buffer-string)))
            (should (equal (alist-get 'text (car (alist-get 'messages emacsos-assist-web--snapshot)))
                           (concat "a\nb " flag)))))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (when (buffer-live-p list-buffer) (kill-buffer list-buffer))
      (delete-directory emacsos-assist-web-cache-directory t))))

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

(ert-deftest test-assist-web-refresh-keeps-every-recognized-active-status ()
  "A manual refresh cannot settle local ownership from an active status alone."
  (dolist (status emacsos-assist-web--active-snapshot-statuses)
    (let ((snapshot
           `((thread . ((id . "thread-1") (description . "Thread")
                        (status . ,status)
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
                     (funcall callback snapshot nil)))
                  ((symbol-function 'emacsos-assist-web--try-write-cache) #'ignore)
                  ((symbol-function 'emacsos-assist-web--render)
                   (lambda (&rest _) (setq rendered t))))
          (emacsos-assist-web-refresh-thread))
        (should-not rendered)
        (should emacsos-assist-web--in-flight)
        (should (equal emacsos-assist-web--run-id "run-1"))
        (should (equal emacsos-assist-web--pending-key "retry-key"))))))

(ert-deftest test-assist-web-refresh-unknown-status-fails-closed ()
  "A bounded future status is not proof that an accepted Run settled."
  (let ((snapshot
         '((thread . ((id . "thread-1") (description . "Thread")
                      (status . "future-state")
                      (workspace . ((repo_label . "Assist")))))
           (messages . nil)))
        rendered cached)
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
                   (funcall callback snapshot nil)))
                ((symbol-function 'emacsos-assist-web--try-write-cache)
                 (lambda (&rest _) (setq cached t)))
                ((symbol-function 'emacsos-assist-web--render)
                 (lambda (&rest _) (setq rendered t))))
        (emacsos-assist-web-refresh-thread))
      (should-not cached)
      (should-not rendered)
      (should emacsos-assist-web--in-flight)
      (should (equal emacsos-assist-web--run-id "run-1"))
      (should (equal emacsos-assist-web--pending-key "retry-key")))))

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
  (let* ((cache '((threads . nil)
                  (repositories . (((repo_key . "repo-key")
                                    (label . "Assist"))))
                  (harnesses . (((key . "deepagents")
				 (label . "Deep Agents"))))))
         (emacsos-assist-web--catalog cache))
    (cl-letf (((symbol-function 'completing-read)
               (lambda (prompt &rest _) (if (string-prefix-p "Harness" prompt)
                                            (concat "#1  "
                                                    (emacsos-assist-web--isolate-display-text
                                                     "Deep Agents"))
                                          (concat "#1  "
                                                  (emacsos-assist-web--isolate-display-text
                                                   "Assist")))))
              ((symbol-function 'emacsos-assist-web-refresh-threads) #'ignore)
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
  (let* ((cache '((repositories . (((repo_key . "repo-a") (label . "Same"))
                                    ((repo_key . "repo-b") (label . "Same"))))
                  (harnesses . (((key . "deepagents")
                                 (label . "Deep Agents"))))))
         (emacsos-assist-web--catalog cache))
    (when (get-buffer "*assist New thread*") (kill-buffer "*assist New thread*"))
    (cl-letf (((symbol-function 'emacsos-assist-web--read-cache) (lambda (&rest _) nil))
              ((symbol-function 'completing-read)
               (lambda (prompt &rest _)
                 (if (string-prefix-p "Harness" prompt)
                     (concat "#1  "
                             (emacsos-assist-web--isolate-display-text
                              "Deep Agents"))
                   (concat "#2  "
                           (emacsos-assist-web--isolate-display-text "Same")))))
              ((symbol-function 'switch-to-buffer) #'ignore))
      (emacsos-assist-web--new-thread-from-catalog cache))
    (let ((buffer (get-buffer "*assist New thread*")))
      (unwind-protect
          (with-current-buffer buffer
            (should (equal emacsos-assist-web--draft-repository "repo-b")))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest test-assist-web-labeled-records-cannot-collide-with-label-text ()
  (let* ((items '(((repo_key . "attacker") (label . "Prod"))
                  ((repo_key . "victim") (label . "Prod"))
                  ((repo_key . "literal") (label . "Prod  #1"))))
         (records (emacsos-assist-web--labeled-records items 'repo_key))
         (displays (mapcar (lambda (record) (plist-get record :display))
                           records)))
    (should (= (length displays)
               (length (delete-dups (copy-sequence displays)))))
    (should (equal
             (alist-get 'repo_key
                        (plist-get
                         (emacsos-assist-web--record-for-display
                          (concat "#3  "
                                  (emacsos-assist-web--isolate-display-text
                                   "Prod"))
                          records)
                         :item))
             "victim"))))

(ert-deftest test-assist-web-new-draft-reopens-without-reselecting-workspace ()
  (let* ((emacsos-assist-web-cache-directory (make-temp-file "assist-web-draft-" t))
         (cache '((repositories . (((repo_key . "repo-key") (label . "Assist"))))
                  (harnesses . (((key . "deepagents") (label . "Deep Agents"))))))
         (emacsos-assist-web--catalog cache))
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

(ert-deftest test-assist-web-new-draft-rejects-choices-removed-during-selection ()
  (let* ((catalog
          '((threads . nil)
            (repositories . (((repo_key . "repo") (label . "Assist"))))
            (harnesses . (((key . "deepagents") (label . "Deep Agents"))))))
         (emacsos-assist-web--catalog catalog)
         notice)
    (cl-letf (((symbol-function 'emacsos-assist-web--read-cache) #'ignore)
              ((symbol-function 'completing-read)
               (lambda (_prompt choices &rest _)
                 (prog1 (car choices)
                   (setq emacsos-assist-web--catalog
                         '((threads . nil)
                           (repositories . nil)
                           (harnesses . nil))))))
              ((symbol-function 'switch-to-buffer)
               (lambda (&rest _) (ert-fail "stale workspace must not open")))
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (setq notice (apply #'format format-string args)))))
      (emacsos-assist-web--new-thread-from-catalog catalog))
    (should-not (get-buffer "*assist New thread*"))
    (should (string-match-p "No Assist repositories are available" notice))))

(ert-deftest test-assist-web-new-thread-fetches-catalog-with-no-existing-thread ()
  (let ((catalog (test-assist-web--wire-catalog
                  nil
                  '(((repo_key . "repo-key") (label . "Assist")))
                  '(((key . "deepagents") (label . "Deep Agents")))))
        (emacsos-assist-web--catalog nil)
        (emacsos-assist-web--catalog-state nil)
        (emacsos-assist-web--catalog-refreshing-p nil)
        (emacsos-assist-web--new-thread-pending-p nil)
        (requests 0))
    (cl-letf (((symbol-function 'emacsos-assist-web--read-cache) (lambda (&rest _) nil))
              ((symbol-function 'emacsos-assist-web--request)
               (lambda (method path _payload callback &rest _)
                 (setq requests (1+ requests))
                 (should (equal method "GET"))
                 (should (equal path "threads"))
                 (funcall callback catalog nil)))
              ((symbol-function 'emacsos-assist-web--write-cache) (lambda (&rest _) nil))
              ((symbol-function 'completing-read)
               (lambda (prompt &rest _) (if (string-prefix-p "Harness" prompt)
                                            (concat "#1  "
                                                    (emacsos-assist-web--isolate-display-text
                                                     "Deep Agents"))
                                          (concat "#1  "
                                                  (emacsos-assist-web--isolate-display-text
                                                   "Assist")))))
              ((symbol-function 'switch-to-buffer) (lambda (&rest _) nil)))
      (emacsos-assist-web-new-thread)
      (should (= requests 1))
      (should (equal emacsos-assist-web--catalog
                     '((threads . nil)
                       (repositories . (((repo_key . "repo-key")
                                         (label . "Assist"))))
                       (harnesses . (((key . "deepagents")
                                      (label . "Deep Agents")))))))
      (should-not emacsos-assist-web--new-thread-pending-p)
      (let ((buffer (get-buffer "*assist New thread*")))
        (unwind-protect
            (with-current-buffer buffer
              (should (derived-mode-p 'emacsos-assist-web-mode))
              (should (equal emacsos-assist-web--draft-repository "repo-key")))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest test-assist-web-first-open-shows-visible-retryable-loading-failure ()
  (let ((emacsos-assist-web--catalog nil)
        (emacsos-assist-web--catalog-state nil)
        (emacsos-assist-web--catalog-refreshing-p nil))
    (cl-letf (((symbol-function 'emacsos-assist-web--read-cache) (lambda (&rest _) nil))
              ((symbol-function 'emacsos-assist-web--request)
               (lambda (_method _path _payload callback &rest _)
                 (funcall callback nil "offline"))))
      (emacsos-assist-web-open-thread)
      (let ((buffer (get-buffer "*assist Threads*")))
        (unwind-protect
            (with-current-buffer buffer
              (should (string-match-p "could not be loaded" (buffer-string)))
              (should (string-match-p "Retry" (buffer-string)))
              (should (eq (key-binding (kbd "g"))
                          #'emacsos-assist-web-refresh-threads))
              (should buffer-read-only))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest test-assist-web-empty-loaded-catalog-offers-new-thread ()
  (let ((emacsos-assist-web--catalog (test-assist-web--catalog))
        (emacsos-assist-web--catalog-refreshing-p t))
    (cl-letf (((symbol-function 'emacsos-assist-web-refresh-threads) #'ignore)
              ((symbol-function 'switch-to-buffer) #'ignore))
      (unwind-protect
          (progn
            (emacsos-assist-web-show-thread-list)
            (with-current-buffer "*assist Threads*"
              (should (string-match-p "No Assist threads yet" (buffer-string)))
              (should (string-match-p "C-c a n" (buffer-string)))))
        (when (get-buffer "*assist Threads*") (kill-buffer "*assist Threads*"))))))

(ert-deftest test-assist-web-loaded-catalog-without-repository-does-not-prompt ()
  (let ((emacsos-assist-web--catalog
         '((threads . nil)
           (repositories . nil)
           (harnesses . (((key . "deepagents") (label . "Deep Agents"))))))
        (emacsos-assist-web--catalog-state 'current)
        (emacsos-assist-web--new-thread-pending-p nil)
        notice)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (&rest _) (ert-fail "empty choices must not prompt")))
              ((symbol-function 'emacsos-assist-web-refresh-threads) #'ignore)
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (setq notice (apply #'format format-string args)))))
      (emacsos-assist-web-new-thread))
    (should (string-match-p "No Assist repositories are available" notice))
    (should-not emacsos-assist-web--new-thread-pending-p)))

(ert-deftest test-assist-web-new-thread-starts-refresh-before-cached-chooser ()
  (let ((emacsos-assist-web--catalog
         '((threads . nil)
           (repositories . (((repo_key . "repo") (label . "Assist"))))
           (harnesses . (((key . "deepagents") (label . "Deep Agents"))))))
        calls)
    (cl-letf (((symbol-function 'emacsos-assist-web-refresh-threads)
               (lambda () (push 'refresh calls)))
              ((symbol-function 'emacsos-assist-web--open-pending-new-thread)
               (lambda () (push 'chooser calls))))
      (emacsos-assist-web-new-thread))
    (should (equal (nreverse calls) '(refresh chooser)))))

(ert-deftest test-assist-web-synchronous-refresh-failure-still-opens-cached-chooser ()
  (let* ((catalog
          '((threads . nil)
            (repositories . (((repo_key . "repo") (label . "Assist"))))
            (harnesses . (((key . "deepagents") (label . "Deep Agents"))))))
         (emacsos-assist-web--catalog catalog)
         (emacsos-assist-web--catalog-state 'cached)
         (emacsos-assist-web--catalog-refreshing-p nil)
         (emacsos-assist-web--new-thread-pending-p nil))
    (cl-letf (((symbol-function 'emacsos-assist-web--request)
               (lambda (_method _path _payload callback &rest _)
                 (funcall callback nil "missing token")))
              ((symbol-function 'completing-read)
               (lambda (_prompt choices &rest _) (car choices)))
              ((symbol-function 'emacsos-assist-web--read-cache) #'ignore)
              ((symbol-function 'switch-to-buffer) #'ignore))
      (unwind-protect
          (progn
            (emacsos-assist-web-new-thread)
            (with-current-buffer "*assist New thread*"
              (should (equal emacsos-assist-web--draft-repository "repo"))
              (should (equal emacsos-assist-web--draft-harness "deepagents")))
            (should-not emacsos-assist-web--new-thread-pending-p))
        (when (get-buffer "*assist New thread*")
          (kill-buffer "*assist New thread*"))))))

(ert-deftest test-assist-web-synchronous-refresh-failure-cancels-deferred-cached-chooser ()
  (let* ((window (selected-window))
         (original-buffer (window-buffer window))
         (minibuffer (generate-new-buffer " *assist-sync-failed-minibuffer*"))
         (emacsos-assist-web--catalog
          '((threads . nil)
            (repositories . (((repo_key . "repo") (label . "Assist"))))
            (harnesses . (((key . "deepagents") (label . "Deep Agents"))))))
         (emacsos-assist-web--catalog-state 'cached)
         (emacsos-assist-web--catalog-refreshing-p nil)
         (emacsos-assist-web--new-thread-pending-p nil))
    (unwind-protect
        (progn
          (set-window-buffer window minibuffer)
          (cl-letf (((symbol-function 'active-minibuffer-window)
                     (lambda () window))
                    ((symbol-function 'emacsos-assist-web--request)
                     (lambda (_method _path _payload callback &rest _)
                       (funcall callback nil "missing token")))
                    ((symbol-function 'completing-read)
                     (lambda (&rest _) (ert-fail "failed refresh must not defer"))))
            (emacsos-assist-web-new-thread)
            (should-not emacsos-assist-web--new-thread-pending-p)
            (with-current-buffer minibuffer
              (should-not (memq #'emacsos-assist-web--resume-new-thread-after-minibuffer
                                minibuffer-exit-hook)))))
      (set-window-buffer window original-buffer)
      (kill-buffer minibuffer))))

(ert-deftest test-assist-web-catalog-consumers-coalesce-one-refresh ()
  (let ((emacsos-assist-web--catalog nil)
        (emacsos-assist-web--catalog-state nil)
        (emacsos-assist-web--catalog-refreshing-p nil)
        (emacsos-assist-web--new-thread-pending-p nil)
        callback (requests 0) (new-thread-opens 0)
        (catalog (test-assist-web--wire-catalog
                  '(((id . "thread-1") (description . "Thread")
                     (search_description . "thread")
                     (repo_label . "Assist") (status . "ready")))
                  '(((repo_key . "repo") (label . "Assist")))
                  '(((key . "deepagents") (label . "Deep Agents"))))))
    (cl-letf (((symbol-function 'emacsos-assist-web--read-cache) #'ignore)
              ((symbol-function 'emacsos-assist-web--request)
               (lambda (_method _path _payload cb &rest _)
                 (setq requests (1+ requests) callback cb)))
              ((symbol-function 'emacsos-assist-web--write-cache) #'ignore)
              ((symbol-function 'emacsos-assist-web--new-thread-from-catalog)
               (lambda (_catalog) (setq new-thread-opens (1+ new-thread-opens)))))
      (unwind-protect
          (progn
            (emacsos-assist-web-open-thread)
            (emacsos-assist-web-show-thread-list)
            (emacsos-assist-web-new-thread)
            (should (= requests 1))
            (should emacsos-assist-web--new-thread-pending-p)
            (funcall callback catalog nil)
            (should (equal (alist-get 'id
                                      (car (alist-get
                                            'threads
                                            emacsos-assist-web--catalog)))
                           "thread-1"))
            (should (= new-thread-opens 1))
            (should-not emacsos-assist-web--catalog-refreshing-p))
        (when (get-buffer "*assist Threads*") (kill-buffer "*assist Threads*"))))))

(ert-deftest test-assist-web-empty-cached-choices-resume-after-refresh ()
  (let ((emacsos-assist-web--catalog (test-assist-web--catalog))
        (emacsos-assist-web--catalog-state 'cached)
        (emacsos-assist-web--catalog-refreshing-p nil)
        (emacsos-assist-web--new-thread-pending-p nil)
        callback (opened 0))
    (cl-letf (((symbol-function 'emacsos-assist-web--request)
               (lambda (_method _path _payload cb &rest _)
                 (setq callback cb)))
              ((symbol-function 'emacsos-assist-web--write-cache) #'ignore)
              ((symbol-function 'emacsos-assist-web--new-thread-from-catalog)
               (lambda (_catalog) (setq opened (1+ opened)))))
      (emacsos-assist-web-new-thread)
      (should emacsos-assist-web--new-thread-pending-p)
      (funcall callback
               (test-assist-web--wire-catalog
                nil
                '(((repo_key . "repo") (label . "Assist")))
                '(((key . "deepagents") (label . "Deep Agents"))))
               nil)
      (should (= opened 1))
      (should-not emacsos-assist-web--new-thread-pending-p))))

(ert-deftest test-assist-web-new-thread-waits-for-active-minibuffer-exit ()
  (let* ((window (selected-window))
         (original-buffer (window-buffer window))
         (minibuffer (generate-new-buffer " *assist-active-minibuffer*"))
         (emacsos-assist-web--catalog nil)
         (emacsos-assist-web--catalog-state nil)
         (emacsos-assist-web--catalog-refreshing-p nil)
         (emacsos-assist-web--new-thread-pending-p t)
         (active t)
         (opened 0))
    (unwind-protect
        (progn
          (set-window-buffer window minibuffer)
          (cl-letf (((symbol-function 'active-minibuffer-window)
                     (lambda () (and active window)))
                    ((symbol-function 'run-at-time)
                     (lambda (_time _repeat function &rest arguments)
                       (apply function arguments)))
                    ((symbol-function 'emacsos-assist-web--request)
                     (lambda (_method _path _payload callback &rest _)
                       (funcall callback
                                (test-assist-web--wire-catalog
                                 nil
                                 '(((repo_key . "repo") (label . "Assist")))
                                 '(((key . "deepagents")
                                    (label . "Deep Agents"))))
                                nil)))
                    ((symbol-function 'emacsos-assist-web--write-cache) #'ignore)
                    ((symbol-function 'emacsos-assist-web--new-thread-from-catalog)
                     (lambda (_catalog) (setq opened (1+ opened)))))
            (emacsos-assist-web-refresh-threads)
            (should emacsos-assist-web--new-thread-pending-p)
            (should (= opened 0))
            (setq active nil)
            (with-current-buffer minibuffer
              (run-hooks 'minibuffer-exit-hook))
            (should (= opened 1))
            (should-not emacsos-assist-web--new-thread-pending-p)))
      (set-window-buffer window original-buffer)
      (kill-buffer minibuffer))))

(ert-deftest test-assist-web-confirmed-empty-refresh-cancels-deferred-new-thread ()
  (let* ((window (selected-window))
         (original-buffer (window-buffer window))
         (minibuffer (generate-new-buffer " *assist-empty-minibuffer*"))
         (emacsos-assist-web--catalog nil)
         (emacsos-assist-web--catalog-state nil)
         (emacsos-assist-web--catalog-refreshing-p nil)
         (emacsos-assist-web--new-thread-pending-p t)
         notice)
    (unwind-protect
        (progn
          (set-window-buffer window minibuffer)
          (cl-letf (((symbol-function 'active-minibuffer-window)
                     (lambda () window))
                    ((symbol-function 'emacsos-assist-web--request)
                     (lambda (_method _path _payload callback &rest _)
                       (funcall callback
                                (test-assist-web--wire-catalog nil nil nil)
                                nil)))
                    ((symbol-function 'emacsos-assist-web--write-cache) #'ignore)
                    ((symbol-function 'emacsos-assist-web--new-thread-from-catalog)
                     (lambda (&rest _) (ert-fail "empty choices must not open")))
                    ((symbol-function 'message)
                     (lambda (format-string &rest args)
                       (setq notice (apply #'format format-string args)))))
            (emacsos-assist-web-refresh-threads)
            (should-not emacsos-assist-web--new-thread-pending-p)
            (should (string-match-p "No Assist repositories are available" notice))
            (with-current-buffer minibuffer
              (should-not (memq #'emacsos-assist-web--resume-new-thread-after-minibuffer
                                minibuffer-exit-hook)))))
      (set-window-buffer window original-buffer)
      (kill-buffer minibuffer))))

(ert-deftest test-assist-web-load-catalog-repairs-a-hot-reloaded-legacy-shape ()
  (let* ((legacy '(((id . "old") (description . "Old"))))
         (cached (test-assist-web--catalog
                  '((id . "current") (description . "Current")
                    (search_description . "current")
                    (repo_label . "Assist") (status . "ready"))))
         (emacsos-assist-web--catalog legacy))
    (cl-letf (((symbol-function 'emacsos-assist-web--read-catalog-cache)
               (lambda () cached)))
      (emacsos-assist-web--load-catalog))
    (should (eq emacsos-assist-web--catalog cached))
    (should (eq emacsos-assist-web--catalog-state 'cached))))

(ert-deftest test-assist-web-refresh-failure-preserves-catalog-and-discards-new-intent ()
  (let* ((catalog (test-assist-web--catalog
                   '((id . "existing") (description . "Existing")
                     (search_description . "existing")
                     (repo_label . "Assist") (status . "ready"))))
         (emacsos-assist-web--catalog catalog)
         (emacsos-assist-web--catalog-state 'current)
         (emacsos-assist-web--catalog-refreshing-p nil)
         (emacsos-assist-web--new-thread-pending-p t))
    (cl-letf (((symbol-function 'emacsos-assist-web--request)
               (lambda (_method _path _payload callback &rest _)
                 (funcall callback nil "offline"))))
      (emacsos-assist-web-refresh-threads))
    (should (eq emacsos-assist-web--catalog catalog))
    (should (eq emacsos-assist-web--catalog-state 'refresh-failed))
    (should-not emacsos-assist-web--new-thread-pending-p)))

(ert-deftest test-assist-web-refresh-failure-cancels-deferred-new-thread ()
  (let* ((window (selected-window))
         (original-buffer (window-buffer window))
         (minibuffer (generate-new-buffer " *assist-failed-minibuffer*"))
         (emacsos-assist-web--catalog
          '((threads . nil)
            (repositories . (((repo_key . "repo") (label . "Assist"))))
            (harnesses . (((key . "deepagents") (label . "Deep Agents"))))))
         (emacsos-assist-web--catalog-refreshing-p nil)
         (emacsos-assist-web--catalog-state 'current)
         (emacsos-assist-web--new-thread-pending-p t)
         (active t)
         (opened 0))
    (unwind-protect
        (progn
          (set-window-buffer window minibuffer)
          (cl-letf (((symbol-function 'active-minibuffer-window)
                     (lambda () (and active window)))
                    ((symbol-function 'run-at-time)
                     (lambda (_time _repeat function &rest arguments)
                       (apply function arguments)))
                    ((symbol-function 'emacsos-assist-web--request)
                     (lambda (_method _path _payload callback &rest _)
                       (funcall callback nil "offline")))
                    ((symbol-function 'emacsos-assist-web--new-thread-from-catalog)
                     (lambda (_catalog) (setq opened (1+ opened)))))
            (emacsos-assist-web-refresh-threads)
            (should-not emacsos-assist-web--new-thread-pending-p)
            (setq active nil)
            (with-current-buffer minibuffer
              (run-hooks 'minibuffer-exit-hook))
            (should (= opened 0))))
      (set-window-buffer window original-buffer)
      (kill-buffer minibuffer))))

(ert-deftest test-assist-web-async-refresh-failure-removes-armed-minibuffer-hook ()
  (let* ((window (selected-window))
         (original-buffer (window-buffer window))
         (minibuffer (generate-new-buffer " *assist-async-failed-minibuffer*"))
         (emacsos-assist-web--catalog
          '((threads . nil)
            (repositories . (((repo_key . "repo") (label . "Assist"))))
            (harnesses . (((key . "deepagents") (label . "Deep Agents"))))))
         (emacsos-assist-web--catalog-state 'cached)
         (emacsos-assist-web--catalog-refreshing-p nil)
         (emacsos-assist-web--new-thread-pending-p nil)
         callback)
    (unwind-protect
        (progn
          (set-window-buffer window minibuffer)
          (cl-letf (((symbol-function 'active-minibuffer-window)
                     (lambda () window))
                    ((symbol-function 'emacsos-assist-web--request)
                     (lambda (_method _path _payload cb &rest _)
                       (setq callback cb))))
            (emacsos-assist-web-new-thread)
            (with-current-buffer minibuffer
              (should (memq #'emacsos-assist-web--resume-new-thread-after-minibuffer
                            minibuffer-exit-hook)))
            (funcall callback nil "offline")
            (should-not emacsos-assist-web--new-thread-pending-p)
            (with-current-buffer minibuffer
              (should-not (memq #'emacsos-assist-web--resume-new-thread-after-minibuffer
                                minibuffer-exit-hook)))))
      (set-window-buffer window original-buffer)
      (kill-buffer minibuffer))))

(ert-deftest test-assist-web-cache-write-failure-remains-visible-after-live-refresh ()
  (let ((emacsos-assist-web--catalog nil)
        (emacsos-assist-web--catalog-refreshing-p nil)
        (emacsos-assist-web--catalog-state nil)
        (reply (test-assist-web--wire-catalog nil nil nil)))
    (cl-letf (((symbol-function 'emacsos-assist-web--request)
               (lambda (_method _path _payload callback &rest _)
                 (if (stringp reply)
                     (funcall callback nil reply)
                   (funcall callback reply nil))))
              ((symbol-function 'emacsos-assist-web--try-write-cache)
               (lambda (&rest _) nil)))
      (emacsos-assist-web-refresh-threads)
      (should (eq emacsos-assist-web--catalog-state 'cache-write-failed))
      (setq reply "offline")
      (emacsos-assist-web-refresh-threads))
    (should emacsos-assist-web--catalog)
    (should (eq emacsos-assist-web--catalog-state 'refresh-failed))))

(ert-deftest test-assist-web-reload-keeps-one-refresh-until-old-callback-finishes ()
  (let* ((old (test-assist-web--catalog
               '((id . "old") (description . "Old")
                 (repo_label . "Assist") (status . "ready"))))
         (replacement (test-assist-web--catalog
                       '((id . "replacement") (description . "Replacement")
                         (repo_label . "Assist") (status . "ready"))))
         (wire (test-assist-web--wire-catalog
                '(((id . "late") (description . "Late")
                   (search_description . "late")
                   (repo_label . "Assist") (status . "ready")))
                nil nil))
         (emacsos-assist-web--catalog old)
         (emacsos-assist-web--catalog-generation 7)
         (emacsos-assist-web--catalog-state 'current)
         (emacsos-assist-web--catalog-refreshing-p nil)
         callback (requests 0))
    (cl-letf (((symbol-function 'emacsos-assist-web--request)
               (lambda (_method _path _payload cb &rest _)
                 (setq requests (1+ requests) callback cb))))
      (emacsos-assist-web-refresh-threads)
      ;; Package reload invalidates old callbacks but retains their refresh
      ;; claim until they finish, so another consumer cannot start a second GET.
      (setq emacsos-assist-web--catalog-generation 8
            emacsos-assist-web--new-thread-pending-p nil
            emacsos-assist-web--catalog replacement)
      (emacsos-assist-web-refresh-threads)
      (should (= requests 1))
      (funcall callback wire nil)
      (should-not emacsos-assist-web--catalog-refreshing-p)
      (emacsos-assist-web-refresh-threads)
      (should (= requests 2)))
    (should (eq emacsos-assist-web--catalog replacement))
    (should emacsos-assist-web--catalog-refreshing-p)))

(ert-deftest test-assist-web-malformed-catalog-does-not-replace-valid-state ()
  (let* ((catalog (test-assist-web--catalog
                   '((id . "existing") (description . "Existing")
                     (search_description . "existing")
                     (repo_label . "Assist") (status . "ready"))))
         (emacsos-assist-web--catalog catalog)
         (emacsos-assist-web--catalog-state 'current)
         (emacsos-assist-web--catalog-refreshing-p nil))
    (cl-letf (((symbol-function 'emacsos-assist-web--request)
               (lambda (_method _path _payload callback &rest _)
                 (funcall callback "not an object" nil))))
      (emacsos-assist-web-refresh-threads))
    (should (eq emacsos-assist-web--catalog catalog))
    (should (eq emacsos-assist-web--catalog-state 'refresh-failed))))

(ert-deftest test-assist-web-catalog-rejects-unbounded-or-spoofable-display-data ()
  (let ((valid-thread '((id . "thread-1") (description . "Thread")
                        (search_description . "thread")
                        (repo_label . "Assist") (status . "ready"))))
    (should
     (equal (emacsos-assist-web--require-catalog
             (test-assist-web--wire-catalog (list valid-thread) nil nil))
            `((threads . (,valid-thread))
              (repositories . nil) (harnesses . nil))))
    (should-error
     (emacsos-assist-web--require-catalog
      (test-assist-web--wire-catalog (make-list 501 valid-thread) nil nil)))
    (let ((wrong-array (test-assist-web--wire-catalog nil nil nil)))
      (puthash "threads" nil wrong-array)
      (should-error (emacsos-assist-web--require-catalog wrong-array)))
    (dolist (description (list (make-string 513 ?x)
                               "false\nrow"
                               (concat "false" (string #x0085) "row")
                               (concat "false" (string #x2028) "row")
                               (concat "false" (string #x2029) "row")
                               (concat "ready" (string #x202e) "not")
                               (concat "same" (string #x034f))
                               (concat "same" (string #xfe0e))))
      (let ((thread (copy-tree valid-thread)))
        (setf (alist-get 'description thread) description)
        (should-error
         (emacsos-assist-web--require-catalog
          (test-assist-web--wire-catalog (list thread) nil nil)))))
    (should-error
     (emacsos-assist-web--require-catalog
      (test-assist-web--wire-catalog
       (list valid-thread (copy-tree valid-thread)) nil nil)))))

(ert-deftest test-assist-web-catalog-accepts-production-emoji-zwj-and-vs16 ()
  (let* ((joined (concat "Coding " (string #x1f469 #x200d #x1f4bb)))
         (emoji (concat "Weather " (string #x2600 #xfe0f)))
         (threads
          (cl-loop
           for index from 1 to 148
           collect
           `((id . ,(format "thread-%d" index))
             (description . ,(cond ((= index 7) joined)
                                    ((= index 60) emoji)
                                    (t (format "Thread %d" index))))
             (search_description . ,(if (= index 48) joined
                                      (format "thread %d" index)))
             (repo_label . "Assist") (status . "ready"))))
         (catalog
          (emacsos-assist-web--require-catalog
           (test-assist-web--wire-catalog threads nil nil))))
    (should (= (length (alist-get 'threads catalog)) 148))
    (should (equal (alist-get 'threads catalog) threads))))

(ert-deftest test-assist-web-catalog-rejects-other-hostile-format-text ()
  (let ((valid-thread '((id . "thread-1") (description . "Thread")
                        (search_description . "thread")
                        (repo_label . "Assist") (status . "ready"))))
    (dolist (character '(#x00ad #x200b #x200c #x200e
                         #x2066 #xfe0e #xe0100))
      (dolist (field '(description search_description))
        (let ((thread (copy-tree valid-thread)))
          (setf (alist-get field thread)
                (concat "hostile" (string character) "text"))
          (should-error
           (emacsos-assist-web--require-catalog
            (test-assist-web--wire-catalog (list thread) nil nil))))))
    (dolist (character '(#x200d #xfe0f))
      (let ((key (concat "key" (string character))))
        (should-error
         (emacsos-assist-web--require-catalog
          (test-assist-web--wire-catalog
           nil `(((repo_key . ,key) (label . "Repository"))) nil)))
        (should-error
         (emacsos-assist-web--require-catalog
          (test-assist-web--wire-catalog
           nil nil `(((key . ,key) (label . "Harness"))))))))))

(ert-deftest test-assist-web-native-list-renders-stable-collision-ordinals ()
  (let* ((a '((id . "a") (description . "Same description alpha")
              (search_description . "same description alpha")
              (repo_label . "Very long repository label") (status . "ready")))
         (z '((id . "z") (description . "Same description beta")
              (search_description . "same description beta")
              (repo_label . "Very long repository label") (status . "ready")))
         (emacsos-assist-web--catalog (test-assist-web--catalog z a)))
    (unwind-protect
        (progn
          (with-current-buffer
              (get-buffer-create emacsos-assist-web--thread-list-buffer-name)
            (emacsos-assist-web-thread-list-mode)
            (should (eq bidi-paragraph-direction 'left-to-right)))
          (cl-letf (((symbol-function 'emacsos-assist-web--list-width)
                     (lambda () 16)))
            (emacsos-assist-web--render-thread-list))
          (with-current-buffer emacsos-assist-web--thread-list-buffer-name
            (should (string-match-p "#1" (buffer-string)))
            (should (string-match-p "#2" (buffer-string))))
          (setq emacsos-assist-web--catalog (test-assist-web--catalog a z))
          (let ((ordinals
                 (mapcar (lambda (record)
                         (cons (alist-get 'id (plist-get record :thread))
                                 (plist-get record :ordinal)))
                         (emacsos-assist-web--list-records 16))))
            (should (equal ordinals '(("a" . 1) ("z" . 2))))))
      (when (get-buffer emacsos-assist-web--thread-list-buffer-name)
        (kill-buffer emacsos-assist-web--thread-list-buffer-name)))))

(ert-deftest test-assist-web-native-list-ordinals-cover-admitted-emoji-marks ()
  (let* ((plain '((id . "a") (description . "Same")
                  (search_description . "same")
                  (repo_label . "Assist") (status . "ready")))
         (vs16 `((id . "b") (description . ,(concat "Same" (string #xfe0f)))
                 (search_description . "same")
                 (repo_label . "Assist") (status . "ready")))
         (zwj `((id . "c") (description . ,(concat "Sa" (string #x200d) "me"))
                (search_description . "same")
                (repo_label . "Assist") (status . "ready")))
         (emacsos-assist-web--catalog (test-assist-web--catalog plain vs16 zwj)))
    (should
     (equal (mapcar (lambda (record)
                      (cons (alist-get 'id (plist-get record :thread))
                            (plist-get record :ordinal)))
                    (emacsos-assist-web--list-records 40))
            '(("a" . 1) ("b" . 2) ("c" . 3))))))

(ert-deftest test-assist-web-native-list-groups-canonically-equivalent-rows ()
  (let* ((composed '((id . "a") (description . "é")
                     (search_description . "é")
                     (repo_label . "Assist") (status . "ready")))
         (decomposed '((id . "b") (description . "é")
                       (search_description . "é")
                       (repo_label . "Assist") (status . "ready")))
         (emacsos-assist-web--catalog
          (test-assist-web--catalog composed decomposed)))
    (should (equal (mapcar (lambda (record) (plist-get record :ordinal))
                           (emacsos-assist-web--list-records 16))
                   '(1 2)))))

(ert-deftest test-assist-web-native-list-reserves-ordinal-column-from-server-text ()
  (let* ((first '((id . "a") (description . "Same")
                  (search_description . "same")
                  (repo_label . "R") (status . "abcdefghijklmnopqrst")))
         (second '((id . "b") (description . "Same")
                   (search_description . "same")
                   (repo_label . "R") (status . "abcdefghijklmnopqrstu")))
         (spoof '((id . "c") (description . "Same")
                  (search_description . "same")
                  (repo_label . "R") (status . "abcdefg…  #1")))
         (emacsos-assist-web--catalog
          (test-assist-web--catalog first second spoof))
         rows)
    (dolist (record (emacsos-assist-web--list-records 16))
      (with-temp-buffer
        (emacsos-assist-web--insert-thread-row record)
        (push (buffer-string) rows)))
    (should (= 3 (length (delete-dups rows))))))

(ert-deftest test-assist-web-native-list-isolates-natural-rtl-from-trusted-ordinal ()
  (let ((record (list :thread '((id . "rtl"))
                      :description "مرحبا #1"
                      :metadata "مستودع · ready"
                      :ordinal 2)))
    (with-temp-buffer
      (emacsos-assist-web--insert-thread-row record)
      (should
       (equal (buffer-string)
              (concat
               (emacsos-assist-web--isolate-display-text "مرحبا #1") "\n"
               (emacsos-assist-web--isolate-display-text "مستودع · ready")
               "   #2\n"))))))

(ert-deftest test-assist-web-native-list-opens-the-exact-id-at-point ()
  (let* ((a '((id . "thread-a") (description . "Same")
              (search_description . "same")
              (repo_label . "Assist") (status . "ready")))
         (b '((id . "thread-b") (description . "Same")
              (search_description . "same")
              (repo_label . "Assist") (status . "ready")))
         (emacsos-assist-web--catalog (test-assist-web--catalog a b))
         opened)
    (unwind-protect
        (progn
          (with-current-buffer
              (get-buffer-create emacsos-assist-web--thread-list-buffer-name)
            (emacsos-assist-web-thread-list-mode))
          (emacsos-assist-web--render-thread-list)
          (with-current-buffer emacsos-assist-web--thread-list-buffer-name
            (goto-char (emacsos-assist-web--thread-row-position "thread-b"))
            (cl-letf (((symbol-function 'emacsos-assist-web--show-thread)
                       (lambda (thread) (setq opened (alist-get 'id thread)))))
              (emacsos-assist-web-list-activate)))
          (should (equal opened "thread-b")))
      (when (get-buffer emacsos-assist-web--thread-list-buffer-name)
        (kill-buffer emacsos-assist-web--thread-list-buffer-name)))))

(ert-deftest test-assist-web-has-direct-contextual-conversation-actions ()
  (with-temp-buffer
    (org-mode)
    (dolist (key '("C-c C-a t" "C-c C-a n" "C-c C-a g" "C-c C-a s"
                   "C-c C-a o" "C-c C-a l" "C-c C-a a"))
      (should-not (memq (key-binding (kbd key))
                         '(emacsos-conversation-refresh
                           emacsos-conversation-send
                           emacsos-conversation-open-object
                           emacsos-conversation-load-older
                           emacsos-conversation-abort)))))
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (dolist (binding '(("C-<return>" . emacsos-conversation-send)
                       ("C-c C-r" . emacsos-conversation-refresh)
                       ("C-c C-k" . emacsos-conversation-abort)
                       ("C-c C-o" . emacsos-conversation-open-object)
                       ("C-c C-l" . emacsos-conversation-load-older)))
      (should (eq (key-binding (kbd (car binding))) (cdr binding))))))

(ert-deftest test-assist-web-object-action-belongs-to-its-backend ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (should (eq (alist-get 'open-object emacsos-conversation-actions)
                #'emacsos-conversation--open-object))))

(ert-deftest test-assist-web-control-return-sends-from-its-current-buffer ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let (sent)
      (cl-letf (((symbol-function 'emacsos-assist-web-send)
                 (lambda () (interactive) (setq sent (current-buffer)))))
        (call-interactively (key-binding (kbd "C-<return>"))))
      (should (eq sent (current-buffer))))))

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
      (should (eq (plist-get (emacsos-assist-web--queue-head) :state)
                  'acceptance-unknown))
      (should (equal (plist-get (emacsos-assist-web--queue-head) :text) "hello")))))

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
                ((symbol-function 'emacsos-assist-web--observe-entry)
                 (lambda (&rest _) (ert-fail "late acceptance must not observe"))))
        (emacsos-assist-web-send)
        (let* ((entry (emacsos-assist-web--queue-head))
               (key (plist-get entry :key)))
          (should (string-match-p "you> hello" (buffer-string)))
          (should (string-match-p "\\[queued\\]" (buffer-string)))
          (should (equal (butlast request 2)
                         '("POST" "threads/thread-1/messages" ((message . "hello")))))
          (should (stringp key))
          (emacsos-assist-web-abort)
          (should (equal (plist-get entry :key) key))
          (should (equal (plist-get entry :text) "hello"))
          (should (eq (plist-get entry :state) 'acceptance-unknown))
          (should (string-match-p "acceptance unknown" (buffer-string)))
          (funcall (nth 3 request) '((thread_id . "thread-1") (run_id . "run-late")) nil)
          (should-not (plist-get entry :run-id))
          (should (eq (plist-get entry :state) 'acceptance-unknown)))))))

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
      (should-not emacsos-assist-web--queue)
      (should-not emacsos--assist-active-surface)
      (should (equal emacsos-assist-web--stream-status
                     "local cache full; message remains in draft")))))

(ert-deftest test-assist-web-stale-post-callback-cannot-replace-a-newer-send ()
  (let ((emacsos--assist-active-surface nil)
        (emacsos-assist-web--requests nil))
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
                  ((symbol-function 'emacsos-assist-web--observe-entry)
                   (lambda (_buffer) (setq observed t))))
          (emacsos-assist-web-send)
          (emacsos-assist-web-abort)
          (emacsos-assist-web-send)
          (funcall (car callbacks)
                   '((thread_id . "thread-1") (run_id . "stale-run")) nil)
          (should-not (plist-get (emacsos-assist-web--queue-head) :run-id))
          (should-not observed)
          (should (= (length callbacks) 2))
          (funcall (cadr callbacks)
                   '((thread_id . "thread-1") (run_id . "current-run")) nil)
          (should (equal (plist-get (emacsos-assist-web--queue-head) :run-id)
                         "current-run"))
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
        (should (eq emacsos--assist-active-surface 'web))
        (should (equal emacsos-assist-web--thread-id "thread-1"))
        (should (eq (plist-get (emacsos-assist-web--queue-head) :state)
                    'acceptance-unknown))
        (should (plist-get (emacsos-assist-web--queue-head) :key))))))

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
      (should (eq emacsos--assist-active-surface 'web))
      (should (eq (plist-get (emacsos-assist-web--queue-head) :state)
                  'acceptance-unknown))
      (should (plist-get (emacsos-assist-web--queue-head) :key)))))

(ert-deftest test-assist-web-global-send-outside-thread-is-a-safe-noop ()
  (with-temp-buffer
    (emacsos-assist-web-send)
    (should-not emacsos-assist-web--in-flight)))

(ert-deftest test-assist-web-replayed-send-does-not-duplicate-local-pending-text ()
  (let ((emacsos-assist-web--requests nil))
    (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq emacsos-assist-web--thread-id "thread-1")
    (emacsos-assist-web--write-prompt)
    (let ((entry (emacsos-assist-web--entry
                  "hello" 'acceptance-unknown
                  "emacsos-0123456789abcdef0123456789abcdef"))
          callback observed)
      (setq emacsos-assist-web--queue (list entry))
      (emacsos-assist-web--entry-render entry)
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload cb &rest _) (setq callback cb)))
                ((symbol-function 'emacsos-assist-web--save-draft) (lambda () t))
                ((symbol-function 'emacsos-assist-web--observe-entry)
                 (lambda (&rest _) (setq observed t))))
        (emacsos-assist-web-send)
        (funcall callback
                 '((thread_id . "thread-1") (run_id . "run-1") (replayed . t)) nil))
      (goto-char (point-min))
      (should (= (how-many "you> hello" (point-min) (point-max)) 1))
      ;; The replayed journal, not a concurrent snapshot, owns this
      ;; provisional region until its terminal event reconciles it.
      (should observed)))))

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
                 (lambda ()
                   (push (plist-get (emacsos-assist-web--queue-head) :run-id) saved) t))
                ((symbol-function 'emacsos-assist-web--observe-entry)
                 (lambda (_entry) (setq observed (member "run-1" saved)))))
        (emacsos-assist-web-send)
        (funcall callback '((thread_id . "thread-1") (run_id . "run-1")
                            (live_text . t)) nil))
      (should (member "run-1" saved))
      (should observed))))

(ert-deftest test-assist-web-accepted-run-never-observes-before-its-draft-saves ()
  "The accepted queue record reaches durable state before observation starts."
  (let ((emacsos--assist-active-surface nil) callback observed (saves 0))
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1")
      (emacsos-assist-web--write-prompt)
      (insert "hello")
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload cb &rest _) (setq callback cb)))
                ((symbol-function 'emacsos-assist-web--save-draft)
                 (lambda () (setq saves (1+ saves)) t))
                ((symbol-function 'emacsos-assist-web--observe-entry)
                 (lambda (_entry) (setq observed t))))
        (emacsos-assist-web-send)
        (funcall callback '((thread_id . "thread-1") (run_id . "run-1")
                            (live_text . t)) nil))
      (should observed)
      (should (equal (plist-get (emacsos-assist-web--queue-head) :run-id) "run-1"))
      (should (eq (plist-get (emacsos-assist-web--queue-head) :state)
                  'observing))
      (should (>= saves 2)))))

(ert-deftest test-assist-web-awaiting-approval-recovery-keeps-the-exact-run ()
  "A nonterminal approval wait survives until its canonical refresh succeeds."
  (let ((emacsos--assist-active-surface nil)
        callback
        (snapshot (copy-tree test-assist-web--snapshot)))
    (setf (alist-get 'status (alist-get 'thread snapshot)) "awaiting_approval")
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
                ((symbol-function 'emacsos-assist-web--try-write-cache) #'ignore))
        (emacsos-assist-web--resume-accepted-run)
        (funcall callback '((status . "awaiting_approval")) nil)
        (funcall callback snapshot nil))
      (should (equal emacsos-assist-web--run-id "run-1"))
      (should emacsos-assist-web--pending-accepted-p)
      (should (equal (alist-get 'status
                                (alist-get 'thread
                                           emacsos-assist-web--snapshot))
                     "awaiting_approval")))))

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
                  ((symbol-function 'emacsos-assist-web--observe-entry) #'ignore))
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

(ert-deftest test-assist-web-restored-run-never-steals-local-chat-ownership ()
  "A recovered accepted run waits without losing its exact retry identity."
  (let (requested)
    (let ((emacsos--assist-active-surface 'chat))
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
            (should (eq emacsos--assist-active-surface 'chat))
            (should-not emacsos-assist-web--in-flight)
            (should (equal emacsos-assist-web--pending-key
                           "emacsos-0123456789abcdef0123456789abcdef"))
            (should (equal emacsos-assist-web--submitted-text "hello"))
            (should emacsos-assist-web--pending-accepted-p)
            (should (equal emacsos-assist-web--run-id "run-1"))
            (should (string-match-p "another conversation is active"
                                    emacsos-assist-web--stream-status))))))

(ert-deftest test-assist-web-send-queues-one-same-thread-follow-up ()
  "A second public Send remains local while the first Run is observed."
  (let ((emacsos--assist-active-surface 'web))
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (let ((active (emacsos-assist-web--entry
                     "first" 'observing
                     "emacsos-0123456789abcdef0123456789abcdef")))
        (setf (plist-get active :run-id) "run-1")
        (setq emacsos-assist-web--thread-id "thread-1"
              emacsos-assist-web--queue (list active)
              emacsos-assist-web--stream-entry active)
      (emacsos-assist-web--write-prompt)
      (insert "follow up")
      (let (request)
        (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) (lambda () t))
                  ((symbol-function 'emacsos-assist-web--request)
                   (lambda (method path _payload _callback &rest _)
                     (setq request (list method path)))))
        (emacsos-assist-web-send))
        (should (equal request '("POST" "threads/thread-1/messages"))))
      (should-not (string-match-p "A web-thread request is already running"
                                  (buffer-string)))
      (should (equal (mapcar (lambda (entry) (plist-get entry :text))
                             emacsos-assist-web--queue)
                     '("first" "follow up")))
      (should (string-match-p emacsos-assist-web--idempotency-regexp
                              (plist-get (cadr emacsos-assist-web--queue) :key)))
      (should (eq (plist-get (cadr emacsos-assist-web--queue) :state) 'posting))
      (should (string-empty-p (emacsos-assist-web--input)))))))

(ert-deftest test-assist-web-send-admits-a-different-web-buffer ()
  "Aggregate web activity does not reject another canonical thread buffer."
  (let ((emacsos--assist-active-surface 'web)
        requested)
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-2")
      (emacsos-assist-web--write-prompt)
      (insert "independent")
      (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) (lambda () t))
                ((symbol-function 'emacsos-assist-web--request)
                 (lambda (method path _payload _callback &rest _)
                   (setq requested (list method path)))))
        (emacsos-assist-web-send))
      (should (equal requested '("POST" "threads/thread-2/messages")))
      (should (eq emacsos--assist-active-surface 'web)))))

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
      (setq emacsos-assist-web--thread-id nil
            emacsos-assist-web--draft-id "new-thread"
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
      (should (equal (seq-take events 2) '(save save)))
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
                      ((symbol-function 'emacsos-assist-web--observe-entry)
                       (lambda (_entry) (push (current-buffer) observations))))
              (emacsos-assist-web-send)
              (switch-to-buffer draft)
              ;; The source remains editable while POST acceptance is in flight.
              (insert "next draft")
              (funcall callback
                       '((thread_id . "thread-new") (run_id . "run-new")) nil)))
          (should-not (buffer-live-p draft))
          (should (equal observations (list canonical)))
          ;; The discovered canonical buffer remains the controller.  Its
          ;; observer must not be torn down merely because S1 adopts into it.
          (should-not cleaned)
          (should (eq emacsos--assist-active-surface 'web))
          (with-current-buffer canonical
            (should (equal (plist-get (car emacsos-assist-web--queue) :run-id)
                           "run-new"))
            (should (= emacsos-assist-web--refresh-generation 0))
            (should (= emacsos-assist-web--send-generation 0))
            (should (= emacsos-assist-web--stream-generation 0))
            (should (= (how-many "you> hello" (point-min) (point-max)) 1))
            (should (equal (emacsos-assist-web--input) ""))
            (should (equal emacsos-assist-web--recovery-draft "next draft"))))
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
                      ((symbol-function 'emacsos-assist-web--observe-entry)
                       (lambda (_buffer) (setq observed t))))
              (emacsos-assist-web-send)
              (funcall callback
                       '((thread_id . "thread-new") (run_id . "run-new")
                         (live_text . t)) nil)))
          (should-not observed)
          (should-not deleted)
          (should (buffer-live-p draft))
          (should (eq emacsos--assist-active-surface 'web))
          (with-current-buffer canonical
            (should-not emacsos-assist-web--run-id)
            (should-not emacsos-assist-web--pending-accepted-p)
            (should-not emacsos-assist-web--in-flight)))
          (with-current-buffer draft
            (should-not emacsos-assist-web--thread-id)
            (should (equal emacsos-assist-web--draft-id "new-thread"))
            (should (equal (plist-get (car emacsos-assist-web--queue) :run-id)
                           "run-new"))
            (should (eq (plist-get (car emacsos-assist-web--queue) :state)
                        'accepted-unobserved))
            (should-not emacsos-assist-web--in-flight))
      (when (buffer-live-p draft) (kill-buffer draft))
      (when (buffer-live-p canonical) (kill-buffer canonical))
      (setq emacsos--assist-active-surface nil))))

(ert-deftest test-assist-web-send-adopts-source-run-before-destination-fifo ()
  "Public Send preserves S1,C1,C2,S2 by key while retaining D's controller."
  (let ((emacsos--assist-active-surface nil)
        (canonical (generate-new-buffer " *assist-canonical-order*"))
        (source (generate-new-buffer " *assist-source-order*"))
        first-post destination-controller)
    (unwind-protect
        (progn
          (with-current-buffer canonical
            (emacsos-assist-web-mode)
            (setq emacsos-assist-web--thread-id "thread-new")
            (emacsos-assist-web--write-prompt)
            (insert "destination tail")
            (let ((c1 (emacsos-assist-web--entry "C1" 'observing
                                                 "emacsos-11111111111111111111111111111111"))
                  (c2 (emacsos-assist-web--entry "C2" 'queued
                                                 "emacsos-22222222222222222222222222222222")))
              (setf (plist-get c1 :run-id) "run-c1")
              (setq emacsos-assist-web--queue (list c1 c2)
                    emacsos-assist-web--stream-entry c1
                    destination-controller c1)))
          (with-current-buffer source
            (emacsos-assist-web-mode)
            (setq emacsos-assist-web--draft-id "new-thread"
                  emacsos-assist-web--draft-repository "repo-key"
                  emacsos-assist-web--draft-harness "deepagents")
            (emacsos-assist-web--write-prompt)
            (insert "S1")
            (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) (lambda () t))
                      ((symbol-function 'emacsos-assist-web--thread-buffer)
                       (lambda (thread-id)
                         (and (equal thread-id "thread-new") canonical)))
                      ((symbol-function 'emacsos-assist-web--delete-cache) (lambda (&rest _) t))
                      ((symbol-function 'emacsos-assist-web--observe-run) #'ignore)
                      ((symbol-function 'emacsos-assist-web--request)
                       (lambda (_method _path _payload callback &rest _)
                         (unless first-post
                           (setq first-post callback)))))
              (emacsos-assist-web-send)
              ;; Same text as destination C2 but a distinct client turn/key.
              (insert "C2")
              (emacsos-assist-web-send)
              (funcall first-post
                       '((thread_id . "thread-new") (run_id . "run-s1")) nil)))
          (with-current-buffer canonical
            (should (eq emacsos-assist-web--stream-entry destination-controller))
            (should (equal (emacsos-assist-web--input) "destination tail"))
            (should (equal (mapcar (lambda (entry) (plist-get entry :text))
                                   emacsos-assist-web--queue)
                           '("S1" "C1" "C2" "C2")))
            (should (= (length (delete-dups
                                (mapcar (lambda (entry) (plist-get entry :key))
                                        emacsos-assist-web--queue)))
                       4))))
      (when (buffer-live-p source) (kill-buffer source))
      (when (buffer-live-p canonical) (kill-buffer canonical))
      (setq emacsos--assist-active-surface nil))))

(ert-deftest test-assist-web-queue-filter-rejects-a-reversed-entry-callback ()
  "A stale A filter cannot mutate B after B becomes the observed entry."
  (let ((target (generate-new-buffer " *assist-queue-target*"))
        (source (generate-new-buffer " *assist-queue-source*"))
        process calls)
    (unwind-protect
        (progn
          (setq process (make-pipe-process :name "assist-queue-stale"
                                           :buffer source :noquery t))
          (with-current-buffer target
            (emacsos-assist-web-mode)
            (let ((a (emacsos-assist-web--entry
                      "A" 'observing "emacsos-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
                  (b (emacsos-assist-web--entry
                      "B" 'observing "emacsos-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")))
              (setq emacsos-assist-web--queue (list a b)
                    emacsos-assist-web--stream-entry a)
              (cl-letf (((symbol-function 'emacsos-assist-web--legacy-event-filter)
                         (lambda (&rest _)
                           (lambda (&rest _) (setq calls (1+ (or calls 0)))))))
                (let ((a-filter (emacsos-assist-web--event-filter #'ignore target 0)))
                  ;; B is the later controller before delayed A bytes arrive.
                  (setq emacsos-assist-web--stream-entry b)
                  (funcall a-filter process "late A")))
              (should-not calls)
              (should (eq emacsos-assist-web--stream-entry b)))))
      (when (process-live-p process) (delete-process process))
      (when (buffer-live-p target) (kill-buffer target))
      (when (buffer-live-p source) (kill-buffer source)))))

(ert-deftest test-assist-web-queue-buffer-kill-releases-each-entry-token ()
  "Killing a queue owner releases its pre-header token exactly once."
  (let ((emacsos-assist-web--requests nil))
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (let* ((entry (emacsos-assist-web--entry
                     "A" 'observing "emacsos-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
             (token (list (current-buffer) (plist-get entry :key))))
        (setf (plist-get entry :handshake-token) token)
        (setq emacsos-assist-web--queue (list entry)
              emacsos-assist-web--stream-entry entry
              emacsos-assist-web--requests (list token))
        (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) (lambda () t)))
          (emacsos-assist-web--buffer-killed))
        (should-not emacsos-assist-web--requests)
        (should-not (plist-get entry :handshake-token))))))

(ert-deftest test-assist-web-queue-parser-keeps-reset-delta-and-terminal-on-one-entry ()
  "Reset, delta, and terminal mutate one entry's markers and cleanup token."
  (let ((emacsos-assist-web--requests nil)
        (emacsos--assist-active-surface 'web))
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (emacsos-assist-web--write-prompt)
      (let* ((entry (emacsos-assist-web--entry
                     "A" 'observing "emacsos-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
             (token (list (current-buffer) (plist-get entry :key))))
        (setf (plist-get entry :run-id) "run-a"
              (plist-get entry :handshake-token) token)
        (setq emacsos-assist-web--queue (list entry)
              emacsos-assist-web--stream-entry entry
              emacsos-assist-web--requests (list token))
        (emacsos-assist-web--entry-render entry)
        (emacsos-assist-web--dispatch-event (current-buffer) "assistant-reset"
                                            "{\"attempt\":1}")
        (emacsos-assist-web--dispatch-event
         (current-buffer) "assistant-delta"
         "{\"attempt\":1,\"index\":1,\"text\":\"owned delta\"}")
        (should (equal (list (plist-get entry :stream-attempt)
                             (plist-get entry :stream-index)
                             emacsos-assist-web--stream-status)
                       '(1 1 "working")))
        (should (string-match-p "owned delta" (buffer-string)))
        (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) (lambda () t))
                  ((symbol-function 'emacsos-assist-web--legacy-refresh-thread) #'ignore)
                  ((symbol-function 'emacsos-assist-web--reconcile-when-settled) #'ignore))
          (emacsos-assist-web--dispatch-event (current-buffer) "terminal" "{}"))
        (should (eq (plist-get entry :state) 'terminal-unreconciled))
        (should-not emacsos-assist-web--stream-entry)
        (should-not emacsos-assist-web--requests)
        (should-not (plist-get entry :handshake-token))))))

(ert-deftest test-assist-web-restore-normalization-never-starts-network-before-save ()
  "A transport-only restored state stays inert if normalized cache persistence fails."
  (let (requested)
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1")
      (emacsos-assist-web--write-prompt)
      (cl-letf (((symbol-function 'emacsos-assist-web--read-cache)
                 (lambda (&rest _)
                   '((text . "")
                     (queue . (((text . "A")
                                (key . "emacsos-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
                                (state . "posting")))))))
                ((symbol-function 'emacsos-assist-web--save-draft) (lambda () nil))
                ((symbol-function 'emacsos-assist-web--request)
                 (lambda (&rest _) (setq requested t))))
        (emacsos-assist-web--restore-draft))
      (should-not requested)
      (should (eq (plist-get (emacsos-assist-web--queue-head) :state)
                  'acceptance-unknown)))))

(ert-deftest test-assist-web-recovered-create-requires-restore-before-send ()
  "Reset recovery keeps S2 separate until the user explicitly restores it."
  (let (requests)
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id nil
            emacsos-assist-web--draft-id "new-thread"
            emacsos-assist-web--draft-repository "repo"
            emacsos-assist-web--draft-harness "deepagents")
      (emacsos-assist-web--write-prompt)
      (insert "later tail")
      (let ((entry (emacsos-assist-web--entry "S2" 'recovered-head nil)))
        (setq emacsos-assist-web--queue (list entry))
        (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) (lambda () t))
                  ((symbol-function 'emacsos-assist-web--request)
                   (lambda (method path payload _callback &rest _)
                     (push (list method path payload) requests))))
          (emacsos-assist-web-send)
          (should-not requests)
          (should (equal (emacsos-assist-web--input) "later tail"))
          (should (eq (emacsos-assist-web--queue-entry nil) entry))
          (should-not emacsos-assist-web--thread-id)
          (emacsos-assist-web--restore-create-entry nil)
          (should (plist-get entry :recovered-ready))
          (emacsos-assist-web-send))
        (should (equal (caar requests) "POST"))
        (should (equal (cadar requests) "threads"))
        (should (equal (alist-get 'message (caddar requests)) "S2"))
        (should (equal (emacsos-assist-web--input) "later tail"))))))

(ert-deftest test-assist-web-reconcile-persists-snapshot-before-retiring-entries ()
  "Terminal queue entries stay visible unless snapshot then queue persistence succeeds."
  (let (events rendered)
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1")
      (let ((entry (emacsos-assist-web--entry
                    "A" 'terminal-unreconciled
                    "emacsos-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")))
        (setf (plist-get entry :run-id) "run-a")
        (setq emacsos-assist-web--queue (list entry))
        (cl-letf (((symbol-function 'emacsos-assist-web--save-draft)
                   (lambda () (push 'queue events) t))
                  ((symbol-function 'emacsos-assist-web--try-write-cache)
                   (lambda (&rest _) (push 'snapshot events) t))
                  ((symbol-function 'emacsos-assist-web--request)
                   (lambda (_method _path _payload callback &rest _)
                     (funcall callback test-assist-web--snapshot nil)))
                  ((symbol-function 'emacsos-assist-web--render)
                   (lambda (_snapshot) (setq rendered t))))
          (emacsos-assist-web--reconcile-when-settled))
        (should rendered)
        (should-not emacsos-assist-web--queue)
        (should (equal (reverse events) '(queue snapshot queue)))))))

(ert-deftest test-assist-web-abort-detach-button-appears-only-for-observed-entry ()
  "Queued work retains SEND reachability without a premature detach affordance."
  (let ((emacsos-assist-web--requests nil))
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1")
      (emacsos-assist-web--write-prompt)
      (let ((entry (emacsos-assist-web--entry
                    "A" 'accepted-unobserved
                    "emacsos-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")))
        (setf (plist-get entry :run-id) "run-a")
        (setq emacsos-assist-web--queue (list entry))
        (emacsos-assist-web--entry-render entry)
        (should-not (string-match-p "Abort/Detach" (buffer-string)))
        (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) (lambda () t))
                  ((symbol-function 'emacsos-assist-web--observe-run) #'ignore))
          (emacsos-assist-web--start-observation entry))
        (should (string-match-p "Abort/Detach" (buffer-string)))))))

(ert-deftest test-assist-web-preheader-budget-refuses-a-fifth-observer ()
  "The shared bounded request list prevents a fifth pre-header SSE open."
  (let ((emacsos-assist-web--requests (list 'one 'two 'three 'four))
        opened)
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-1")
      (let ((entry (emacsos-assist-web--entry
                    "A" 'accepted-unobserved
                    "emacsos-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")))
        (setf (plist-get entry :run-id) "run-a")
        (setq emacsos-assist-web--queue (list entry))
        (cl-letf (((symbol-function 'emacsos-assist-web--observe-run)
                   (lambda (&rest _) (setq opened t))))
          (emacsos-assist-web--start-observation entry))
        (should-not opened)
        (should (eq (plist-get entry :state) 'accepted-unobserved))
        (should (= (length emacsos-assist-web--requests) 4))))))

(ert-deftest test-assist-web-queue-without-observer-never-falls-back-to-legacy-parser ()
  "A delayed queue callback with no exact owner is an inert stale callback."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq emacsos-assist-web--queue
          (list (emacsos-assist-web--entry
                 "A" 'accepted-unobserved
                 "emacsos-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")))
    (cl-letf (((symbol-function 'emacsos-assist-web--legacy-dispatch-event)
               (lambda (&rest _) (ert-fail "queue callback reached legacy parser"))))
      (emacsos-assist-web--dispatch-event
       (current-buffer) "assistant-delta"
       "{\"attempt\":1,\"index\":1,\"text\":\"late\"}"))))

(ert-deftest test-assist-web-handshake-cleanup-exits-are-exact-and-idempotent ()
  "Every pre-header exit releases only its captured entry generation once."
  (dolist (exit '(validated-headers non-2xx-429 synchronous-open-error
                  missing-process invalid-2xx header-timeout disconnect
                  guarded-filter buffer-kill reload adoption))
    (let ((emacsos-assist-web--requests nil))
      (with-temp-buffer
        (emacsos-assist-web-mode)
        (let* ((entry (emacsos-assist-web--entry
                       "A" 'observing
                       "emacsos-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))
               (token (list exit)))
          (setf (plist-get entry :epoch) 7
                (plist-get entry :handshake-token) token)
          (setq emacsos-assist-web--requests (list token))
          (emacsos-assist-web--cleanup-handshake entry 6)
          (should (equal emacsos-assist-web--requests (list token)))
          (emacsos-assist-web--cleanup-handshake entry 7)
          (emacsos-assist-web--cleanup-handshake entry 7)
          (should-not emacsos-assist-web--requests)
          (should-not (plist-get entry :handshake-token)))))))

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
          ;; A proven accepted Run remains an aggregate web exclusion even
          ;; though its source cache could not yet retire.
          (should (eq emacsos--assist-active-surface 'web))
          (with-current-buffer draft
            (should (equal emacsos-assist-web--draft-id "new-thread"))
            (should (equal (plist-get (car emacsos-assist-web--queue) :run-id)
                           "run-new"))
            (should (eq (plist-get (car emacsos-assist-web--queue) :state)
                        'accepted-unobserved))))
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

(ert-deftest test-assist-web-refresh-evicts-oldest-loaded-history-at-cap ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let ((emacsos-assist-web--max-rendered-messages 2)
          (old
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
      (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) #'ignore))
        (emacsos-assist-web--render old)
        (emacsos-assist-web--render fresh))
      (should (equal (mapcar (lambda (message) (alist-get 'id message))
                             (alist-get 'messages
                                        emacsos-assist-web--snapshot))
                     '("m-1" "m-2")))
      (should-not (alist-get 'has_older_messages
                             emacsos-assist-web--snapshot))
      (should-not (alist-get 'next_before emacsos-assist-web--snapshot)))))

(ert-deftest test-assist-web-refresh-retains-no-history-across-byte-gap ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let ((emacsos-assist-web--max-rendered-transcript-bytes 30)
          (old
           `((thread . ((id . "thread-1") (description . "Thread")
                        (status . "ready")
                        (workspace . ((repo_label . "Assist")))))
             (messages . (((id . "m-old") (role . "assistant")
                           (text . "small") (state . "final"))
                          ((id . "m-large") (role . "assistant")
                           (text . ,(make-string 15 ?x)) (state . "final"))
                          ((id . "m-1") (role . "assistant")
                           (text . "newer") (state . "final"))))
             (has_older_messages . t) (next_before . "cursor-old")))
          (fresh
           `((thread . ((id . "thread-1") (description . "Thread")
                        (status . "ready")
                        (workspace . ((repo_label . "Assist")))))
             (messages . (((id . "m-1") (role . "assistant")
                           (text . "newer") (state . "final"))
                          ((id . "m-2") (role . "assistant")
                           (text . ,(make-string 15 ?y)) (state . "final"))))
             (has_older_messages . t) (next_before . "cursor-new"))))
      (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) #'ignore))
        (emacsos-assist-web--render old)
        (emacsos-assist-web--render fresh))
      (should (equal (mapcar (lambda (message) (alist-get 'id message))
                             (alist-get 'messages
                                        emacsos-assist-web--snapshot))
                     '("m-1" "m-2")))
      (should-not (alist-get 'next_before emacsos-assist-web--snapshot)))))

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
      (should (markerp (plist-get (emacsos-assist-web--queue-head)
                                   :assistant-start))))))

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
