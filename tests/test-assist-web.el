;;; test-assist-web.el --- Tests for the Assist Web client -*- lexical-binding: t -*-

(require 'ert)
(require 'assist-web)
(require 'url-http)

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
  (let* ((emacsos-assist-web--catalog-state nil)
         (emacsos-assist-web--catalog
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

(ert-deftest test-assist-web-asset-request-304-does-not-expand-url-disk-cache ()
  "A real stock 304 decoder must preserve the private cache's empty validator."
  (let ((emacsos-assist-web--requests nil)
        (response (generate-new-buffer " *asset-stock304*")) process result failure
        (etag (concat "\"" (make-string 64 ?a) "\"")))
    (unwind-protect
        (cl-letf (((symbol-function 'emacsos-assist-web--read-token) (lambda () "token"))
                  ((symbol-function 'run-at-time) (lambda (&rest _) nil))
                  ((symbol-function 'url-cache-extract)
                   (lambda (&rest _) (ert-fail "Unowned URL disk cache read")))
                  ((symbol-function 'url-retrieve)
                   (lambda (_url callback &rest _)
                     (setq process (make-pipe-process :name "asset-stock304" :buffer response
                                                       :noquery t :filter #'url-http-generic-filter))
                     (test-assist-web--initialize-url-http-response response process)
                     (with-current-buffer response
                       (setq-local url-callback-function callback url-callback-arguments '(nil)))
                     response)))
          (emacsos-assist-web--request
           "GET" "threads/asset-thread/assets?path=%2Ftmp%2Fchart.png" nil
           (lambda (value problem) (setq result value failure problem))
           nil nil nil nil nil t)
          (funcall (process-filter process) process
                   (concat "HTTP/1.1 304 Not Modified\r\nETag: " etag "\r\n\r\n"))
          (should-not failure)
          (should (= (plist-get result :status) 304))
          (should (equal (plist-get result :etag) etag))
          (should (equal (plist-get result :data) ""))
          ;; The scoped filter binding must leave unrelated URL users alone.
          (should-error (url-cache-extract "outside") :type 'ert-test-failed))
      (when (process-live-p process) (delete-process process))
      (when (buffer-live-p response) (kill-buffer response)))))

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

(ert-deftest test-assist-web-git-http-409-keeps-structured-outcome ()
  "A url-http error marker does not discard a bounded Git refusal body."
  (dolist (outcome '("conflict" "busy" "stale"))
    (let ((emacsos-assist-web--requests nil)
          result)
      (cl-letf (((symbol-function 'emacsos-assist-web--read-token)
                 (lambda () "token"))
                ((symbol-function 'emacsos-assist-web--trustfiles)
                 (lambda () nil))
                ((symbol-function 'run-at-time) (lambda (&rest _) nil))
                ((symbol-function 'url-retrieve)
                 (lambda (_url callback &rest _)
                   (let ((response (generate-new-buffer " *git-409-response*")))
                     (with-current-buffer response
                       (insert "HTTP/1.1 409 Conflict\r\nContent-Type: application/json\r\n\r\n")
                       (setq-local url-http-response-status 409
                                   url-http-content-type "application/json"
                                   url-http-end-of-headers (copy-marker (point)))
                       (insert (format "{\"outcome\":\"%s\"}" outcome))
                       (funcall callback '(:error (error http 409))))
                     response))))
        (emacsos-assist-web--request
         "POST" "threads/thread-1/merge" nil
         (lambda (value problem) (setq result (list value problem)))
         nil t nil nil t))
      (should-not (cadr result))
      (should (equal (alist-get 'http_status (car result)) 409))
      (should (equal (alist-get 'outcome (car result)) outcome)))))

(ert-deftest test-assist-web-json-callback-kill-hook-cannot-switch-cleanup-target ()
  "A signaling response hook must never make cleanup kill the thread buffer."
  (let ((emacsos-assist-web--requests nil)
        (origin (generate-new-buffer " *assist-origin*"))
        response result)
    (unwind-protect
        (with-current-buffer origin
          (cl-letf (((symbol-function 'emacsos-assist-web--read-token)
                     (lambda () "token"))
                    ((symbol-function 'emacsos-assist-web--response-json)
                     (lambda (&rest _) '((ok . t))))
                    ((symbol-function 'run-at-time) (lambda (&rest _) nil))
                    ((symbol-function 'url-retrieve)
                     (lambda (_url callback &rest _)
                       (setq response (generate-new-buffer " *assist-response*"))
                       (with-current-buffer response
                         (add-hook 'kill-buffer-hook
                                   (lambda ()
                                     (setq kill-buffer-hook nil)
                                     (kill-buffer (current-buffer))
                                     (error "hook failed")) nil t)
                         (funcall callback nil))
                       response)))
            (emacsos-assist-web--request
             "GET" "threads" nil
             (lambda (value problem) (setq result (list value problem)))))
          (should (buffer-live-p origin))
          (should-not (buffer-live-p response))
          (should (stringp (cadr result))))
      (when (buffer-live-p response) (kill-buffer response))
      (when (buffer-live-p origin) (kill-buffer origin)))))

(ert-deftest test-assist-web-json-callback-kill-veto-is-forced-on-exact-response ()
  "A response query veto cannot leave an untracked live HTTP buffer."
  (let ((emacsos-assist-web--requests nil) response result)
    (unwind-protect
        (cl-letf (((symbol-function 'emacsos-assist-web--read-token)
                   (lambda () "token"))
                  ((symbol-function 'emacsos-assist-web--response-json)
                   (lambda (&rest _) '((ok . t))))
                  ((symbol-function 'run-at-time) (lambda (&rest _) nil))
                  ((symbol-function 'url-retrieve)
                   (lambda (_url callback &rest _)
                     (setq response (generate-new-buffer " *assist-response*"))
                     (with-current-buffer response
                       (add-hook 'kill-buffer-query-functions
                                 (lambda () nil) nil t)
                       (funcall callback nil))
                     response)))
          (emacsos-assist-web--request
           "GET" "threads" nil
           (lambda (value problem) (setq result (list value problem))))
          (should (equal (car result) '((ok . t))))
          (should-not (cadr result))
          (should-not (buffer-live-p response)))
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

(ert-deftest test-assist-web-git-typed-malformed-denial-precedes-json-parse ()
  (let ((emacsos-assist-web--requests nil)
        (emacsos-assist-web--thread-id "thread-1")
        typed legacy observed)
    (cl-letf (((symbol-function 'emacsos-assist-web--read-token)
               (lambda () "token"))
              ((symbol-function 'run-at-time) (lambda (&rest _) nil))
              ((symbol-function 'emacsos-assist-web--canonical-denied)
               (lambda (status) (push status observed)))
              ((symbol-function 'url-retrieve)
               (lambda (_url callback &rest _)
                 (let ((response (generate-new-buffer " *git-http-test*")))
                   (with-current-buffer response
                     (setq-local url-http-response-status 401
                                 url-http-content-type "text/plain"
                                 url-http-end-of-headers (copy-marker (point-min)))
                     (insert "malformed denial")
                     (funcall callback nil))
                   response))))
      (emacsos-assist-web--request
       "GET" "threads/thread-1" nil
       (lambda (_value problem) (setq legacy problem)))
      (emacsos-assist-web--request
       "GET" "threads/thread-1" nil
       (lambda (_value problem) (setq typed problem))
       nil nil nil nil t))
    (should (stringp legacy))
    (should (equal (plist-get typed :kind) 'http))
    (should (= (plist-get typed :status) 401))
    (should (equal (plist-get typed :text)
                   "Assist Web request failed (401)"))
    (should (equal observed '(401 401)))))

(ert-deftest test-assist-web-git-typed-errors-preserve-legacy-credentials ()
  (let (typed legacy)
    (cl-letf (((symbol-function 'emacsos-assist-web--read-token)
               (lambda () "invalid token")))
      (emacsos-assist-web--request
       "GET" "threads/thread-1" nil
       (lambda (_value problem) (setq legacy problem)))
      (emacsos-assist-web--request
       "GET" "threads/thread-1" nil
       (lambda (_value problem) (setq typed problem))
       nil nil nil nil t))
    (should (equal legacy "Assist Web token is missing or invalid"))
    (should (equal (plist-get typed :kind) 'credentials))
    (should-not (plist-get typed :status))))

(ert-deftest test-assist-web-git-typed-invalid-success-is-parse-not-http ()
  (let ((emacsos-assist-web--requests nil) typed)
    (cl-letf (((symbol-function 'emacsos-assist-web--read-token)
               (lambda () "token"))
              ((symbol-function 'run-at-time) (lambda (&rest _) nil))
              ((symbol-function 'url-retrieve)
               (lambda (_url callback &rest _)
                 (let ((response (generate-new-buffer " *git-parse-test*")))
                   (with-current-buffer response
                     (insert "x")
                     (setq-local url-http-response-status 200
                                 url-http-content-type "text/plain"
                                 url-http-end-of-headers (copy-marker (point-min)))
                     (funcall callback nil))
                   response))))
      (emacsos-assist-web--request
       "GET" "threads/thread-1" nil
       (lambda (_value problem) (setq typed problem))
       nil nil nil nil t))
    (should (equal (plist-get typed :kind) 'parse))
    (should (= (plist-get typed :status) 200))
    (should (equal (plist-get typed :text) "Assist Web response invalid"))))

(ert-deftest test-assist-web-git-oversized-denial-status-precedes-refusal ()
  (let ((emacsos-assist-web-max-response-bytes 90)
        (header "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\n\r\n"))
    (dolist (chunks (list (list (concat header (make-string 100 ?x)))
                          (list header (make-string 100 ?x))))
      (let (statuses refused forwarded)
        (let ((filter
               (emacsos-assist-web--guarded-filter
                (lambda (&rest _) (setq forwarded t))
                (lambda (_process reason) (setq refused reason))
                nil (lambda (status) (push status statuses)))))
          (dolist (chunk chunks) (funcall filter nil chunk)))
        (should (equal statuses '(403)))
        (should (equal refused "Assist Web response is too large"))
        (when (= (length chunks) 1)
          (should-not forwarded))))))

(ert-deftest test-assist-web-git-request-budget-is-not-offline-authority ()
  (let ((emacsos-assist-web--requests '(one two))
        (emacsos-assist-web-max-concurrent-requests 2)
        problem)
    (cl-letf (((symbol-function 'emacsos-assist-web--read-token)
               (lambda () "token")))
      (emacsos-assist-web--request
       "GET" "threads/thread-1" nil
       (lambda (_value error) (setq problem error))
       nil nil nil nil t))
    (should (eq (plist-get problem :kind) 'busy))
    (should (equal (plist-get problem :text)
                   "Assist Web request budget is busy"))
    (should-not (plist-get problem :offline))))

(ert-deftest test-assist-web-git-tls-error-is-not-parse-or-offline ()
  (let ((emacsos-assist-web--requests nil) problem)
    (cl-letf (((symbol-function 'emacsos-assist-web--read-token)
               (lambda () "token"))
              ((symbol-function 'run-at-time) (lambda (&rest _) nil))
              ((symbol-function 'url-retrieve)
               (lambda (_url callback &rest _)
                 (let ((response (generate-new-buffer " *git-tls-test*")))
                   (with-current-buffer response
                     (funcall callback '(:error (tls "bad certificate"))))
                   response))))
      (emacsos-assist-web--request
       "GET" "threads/thread-1" nil
       (lambda (_value error) (setq problem error))
       nil nil nil nil t))
    (should (eq (plist-get problem :kind) 'trust))
    (should (equal (plist-get problem :text)
                   "Assist Web TLS/trust failed"))
    (should-not (plist-get problem :offline))
    (should-not (plist-get problem :status))))

(ert-deftest test-assist-web-git-timeout-is-not-offline-authority ()
  (let ((emacsos-assist-web--requests nil)
        (response (generate-new-buffer " *git-timeout-test*"))
        timer problem)
    (unwind-protect
        (cl-letf (((symbol-function 'emacsos-assist-web--read-token)
                   (lambda () "token"))
                  ((symbol-function 'url-retrieve)
                   (lambda (&rest _) response))
                  ((symbol-function 'run-at-time)
                   (lambda (_delay _repeat callback) (setq timer callback))))
          (emacsos-assist-web--request
           "GET" "threads/thread-1" nil
           (lambda (_value error) (setq problem error))
           nil nil nil nil t)
          (funcall timer)
          (should (eq (plist-get problem :kind) 'timeout))
          (should (equal (plist-get problem :text)
                         "Assist Web request timed out"))
          (should-not (plist-get problem :offline)))
      (when (buffer-live-p response) (kill-buffer response)))))

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

(ert-deftest test-assist-web-canonical-title-does-not-rename-unrelated-buffers ()
  "Canonical rendering leaves buffers outside title-following mode alone."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let ((name (buffer-name)))
      (cl-letf (((symbol-function 'emacsos-assist-web--save-draft)
                 (lambda (&rest _) t)))
        (emacsos-assist-web--render (copy-tree test-assist-web--snapshot)))
      (should (equal (buffer-name) name)))))

(ert-deftest test-assist-web-reopened-incomplete-message-recreates-assistant-markers ()
  "A resumed accepted Run renders live deltas after its canonical user turn."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq emacsos-assist-web--thread-id "thread-1"
          emacsos-assist-web--pending-key "emacsos-0123456789abcdef0123456789abcdef"
          emacsos-assist-web--submitted-text "hello"
          emacsos-assist-web--pending-accepted-p t
          emacsos-assist-web--run-id "run-1")
    (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) (lambda (&rest _) t)))
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

(ert-deftest test-assist-web-interrupted-observation-retains-the-exact-retry ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (emacsos-assist-web--write-prompt)
    (setq emacsos-assist-web--pending-key "retry-key"
          emacsos-assist-web--submitted-text "message"
          emacsos-assist-web--in-flight t
          emacsos--assist-active-surface (current-buffer))
    (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) (lambda (&rest _) nil)))
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
                 (lambda (_method path _payload callback &rest _)
                   (funcall callback
                            (if (string-match-p "/runs/" path)
                                '((id . "run-1") (thread_id . "thread-1")
                                  (status . "success"))
                              test-assist-web--snapshot)
                            nil)))
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
                 (lambda (_method path _payload callback &rest _)
                   (funcall callback
                            (if (string-match-p "/runs/" path)
                                '((id . "run-1") (thread_id . "thread-1")
                                  (status . "success"))
                              busy-snapshot)
                            nil)))
                ((symbol-function 'emacsos-assist-web--write-cache) #'ignore)
                ((symbol-function 'emacsos-assist-web--render) #'ignore))
        (emacsos-assist-web-refresh-thread (current-buffer) "run-1"))
      (should-not emacsos-assist-web--run-id)
      (should-not emacsos-assist-web--pending-key))))

(ert-deftest test-assist-web-legacy-exact-terminal-commits-once ()
  "Successful retirement supplies one success ID; terminal error supplies none."
  (dolist (outcome '("success" "error"))
    (let ((emacsos-assist-web-cache-directory
           (make-temp-file "assist-legacy-terminal-" t))
          run-callback chat-callback causes)
      (unwind-protect
          (with-temp-buffer
            (emacsos-assist-web-mode)
            (emacsos-assist-web--write-prompt)
            (setq emacsos-assist-web--thread-id "thread-1"
                  emacsos-assist-web--run-id "run-1"
                  emacsos-assist-web--pending-key
                  "emacsos-0123456789abcdef0123456789abcdef"
                  emacsos-assist-web--submitted-text "hello"
                  emacsos-assist-web--pending-accepted-p t)
            (should (emacsos-assist-web--save-draft))
            (cl-letf (((symbol-function 'emacsos-assist-web--request)
                       (lambda (_method path _payload callback &rest _)
                         (if (string-match-p "/runs/" path)
                             (setq run-callback callback)
                           (setq chat-callback callback))))
                      ((symbol-function 'emacsos-assist-web-git--note-snapshot)
                       (lambda (_snapshot success-id &rest _)
                         (push success-id causes))))
              (emacsos-assist-web-refresh-thread)
              (should run-callback)
              (should-not chat-callback)
              (funcall run-callback
                       `((id . "run-1") (thread_id . "thread-1")
                         (status . ,outcome)) nil)
              (should chat-callback)
              (should emacsos-assist-web--run-id)
              (funcall run-callback
                       `((id . "run-1") (thread_id . "thread-1")
                         (status . ,outcome)) nil)
              (funcall chat-callback test-assist-web--snapshot nil)
              (funcall chat-callback test-assist-web--snapshot nil))
            (should-not emacsos-assist-web--run-id)
            (should-not emacsos-assist-web--pending-key)
            (should (equal (alist-get 'run_id
                                    (emacsos-assist-web--read-cache
                                     "drafts/thread-1.json"))
                           nil))
            (should (equal (delq nil causes)
                           (and (equal outcome "success") (list "run-1")))))
        (delete-directory emacsos-assist-web-cache-directory t)))))

(ert-deftest test-assist-web-legacy-postcommit-render-failure-does-not-replay-cause ()
  "A presentation throw after retirement cannot resurrect or recount the Run."
  (let ((emacsos-assist-web-cache-directory
         (make-temp-file "assist-legacy-postcommit-" t))
        run-callback chat-callback causes)
    (unwind-protect
        (with-temp-buffer
          (emacsos-assist-web-mode)
          (emacsos-assist-web--write-prompt)
          (setq emacsos-assist-web--thread-id "thread-1"
                emacsos-assist-web--run-id "run-1"
                emacsos-assist-web--pending-key
                "emacsos-0123456789abcdef0123456789abcdef"
                emacsos-assist-web--submitted-text "hello"
                emacsos-assist-web--pending-accepted-p t)
          (should (emacsos-assist-web--save-draft))
          (cl-letf (((symbol-function 'emacsos-assist-web--request)
                     (lambda (_method path _payload callback &rest _)
                       (if (string-match-p "/runs/" path)
                           (setq run-callback callback)
                         (setq chat-callback callback))))
                    ((symbol-function 'emacsos-assist-web-git--note-snapshot)
                     (lambda (_snapshot success-id &rest _)
                       (when success-id (push success-id causes))))
                    ((symbol-function 'emacsos-assist-web--render)
                     (lambda (&rest _) (signal 'quit nil))))
            (emacsos-assist-web-refresh-thread)
            (funcall run-callback
                     '((id . "run-1") (thread_id . "thread-1")
                       (status . "success")) nil)
            (funcall chat-callback test-assist-web--snapshot nil)
            (funcall chat-callback test-assist-web--snapshot nil))
          (should-not emacsos-assist-web--run-id)
          (should (equal causes '("run-1")))
          (should-not (alist-get 'run_id
                                 (emacsos-assist-web--read-cache
                                  "drafts/thread-1.json")))
          (should (string-match-p "Saved; Refresh"
                                  emacsos-assist-web--stream-status)))
      (delete-directory emacsos-assist-web-cache-directory t))))

(ert-deftest test-assist-web-legacy-postcommit-git-note-quit-keeps-receipt-retired ()
  "Optional Git projection quit cannot roll back durable legacy retirement."
  (let ((emacsos-assist-web-cache-directory
         (make-temp-file "assist-legacy-note-quit-" t))
        run-callback chat-callback)
    (unwind-protect
        (with-temp-buffer
          (emacsos-assist-web-mode)
          (emacsos-assist-web--write-prompt)
          (setq emacsos-assist-web--thread-id "thread-1"
                emacsos-assist-web--run-id "run-1"
                emacsos-assist-web--pending-key
                "emacsos-0123456789abcdef0123456789abcdef"
                emacsos-assist-web--submitted-text "hello"
                emacsos-assist-web--pending-accepted-p t)
          (should (emacsos-assist-web--save-draft))
          (cl-letf (((symbol-function 'emacsos-assist-web--request)
                     (lambda (_method path _payload callback &rest _)
                       (if (string-match-p "/runs/" path)
                           (setq run-callback callback)
                         (setq chat-callback callback))))
                    ((symbol-function 'emacsos-assist-web-git--note-snapshot)
                     (lambda (&rest _) (signal 'quit nil)))
                    ((symbol-function 'emacsos-assist-web--render)
                     (lambda (&rest _) nil)))
            (emacsos-assist-web-refresh-thread)
            (funcall run-callback
                     '((id . "run-1") (thread_id . "thread-1")
                       (status . "success")) nil)
            (funcall chat-callback test-assist-web--snapshot nil))
          (should-not emacsos-assist-web--run-id)
          (should-not emacsos-assist-web--pending-accepted-p)
          (should-not (alist-get 'run_id
                                 (emacsos-assist-web--read-cache
                                  "drafts/thread-1.json")))
          (should (string-match-p "Git state unavailable"
                                  emacsos-assist-web-git--unavailable)))
      (delete-directory emacsos-assist-web-cache-directory t))))

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
                ((symbol-function 'emacsos-assist-web--save-draft) (lambda (&rest _) t))
                ((symbol-function 'emacsos-assist-web--render)
                 (lambda (&rest _) (setq rendered t))))
        (emacsos-assist-web-refresh-thread)
        (emacsos-assist-web-send)
        (funcall refresh-callback test-assist-web--snapshot nil)
        (should-not rendered)
        (should send-callback)))))

(ert-deftest test-assist-web-settled-refresh-reacks-the-thread-read ()
  "A visible settled refresh acknowledges; switching away before delivery does not."
  (dolist (visible '(t nil))
    (save-window-excursion
      (let ((emacsos-assist-web--thread-safety (make-hash-table :test 'equal))
            requests callback)
        (with-temp-buffer
          (emacsos-assist-web-mode)
          (setq emacsos-assist-web--thread-id "thread-1")
          (switch-to-buffer (current-buffer))
          (cl-letf (((symbol-function 'emacsos-assist-web--request)
                     (lambda (method path _payload cb &rest _)
                       (push (list method path) requests)
                       (setq callback cb)))
                    ((symbol-function 'emacsos-assist-web--render) #'ignore)
                    ((symbol-function 'emacsos-assist-web--try-write-cache)
                     (lambda (&rest _) t))
                    ((symbol-function 'emacsos-assist-web--git-note-safely) #'ignore))
            (emacsos-assist-web-refresh-thread)
            (unless visible (set-window-buffer (selected-window) (get-buffer-create " *receipt-away*")))
            (funcall callback test-assist-web--snapshot nil)
            (should (member '("GET" "threads/thread-1") requests))
            (should (eq (not (null (member '("POST" "threads/thread-1/open") requests)))
                        visible))))))))

(ert-deftest test-assist-web-busy-refresh-does-not-reack-the-thread-read ()
  "A valid busy snapshot renders without acknowledging in a visible idle buffer."
  (save-window-excursion
    (let ((emacsos-assist-web--thread-safety (make-hash-table :test 'equal))
          (busy-snapshot (copy-tree test-assist-web--snapshot))
          requests callback rendered)
      (setf (alist-get 'status (alist-get 'thread busy-snapshot)) "processing")
      (with-temp-buffer
        (emacsos-assist-web-mode)
        (setq emacsos-assist-web--thread-id "thread-1")
        (switch-to-buffer (current-buffer))
        ;; No local observer owns a provisional render, so a busy view may render.
        (should-not emacsos-assist-web--in-flight)
        (cl-letf (((symbol-function 'emacsos-assist-web--request)
                   (lambda (method path _payload cb &rest _)
                     (push (list method path) requests)
                     (setq callback cb)))
                  ((symbol-function 'emacsos-assist-web--render)
                   (lambda (value) (setq rendered value)))
                  ((symbol-function 'emacsos-assist-web--try-write-cache)
                   (lambda (&rest _) t))
                  ((symbol-function 'emacsos-assist-web--git-note-safely) #'ignore))
          (emacsos-assist-web-refresh-thread)
          (funcall callback busy-snapshot nil)
          (should (get-buffer-window (current-buffer) 'visible))
          (should (eq rendered busy-snapshot))
          (should (member '("GET" "threads/thread-1") requests))
          (should-not (member '("POST" "threads/thread-1/open") requests)))))))

(ert-deftest test-assist-web-settled-refresh-ack-carries-the-rendered-revision ()
  "The read receipt echoes the revision of the snapshot we rendered, so the
server clears only flags for a view that is still current."
  (let ((emacsos-assist-web--thread-safety (make-hash-table :test 'equal))
        requests callback)
    (let ((snapshot (copy-tree test-assist-web--snapshot)))
      (setf (alist-get 'revision (alist-get 'thread snapshot)) "rev-abc")
      (save-window-excursion
       (with-temp-buffer
        (emacsos-assist-web-mode)
        (switch-to-buffer (current-buffer))
        (setq emacsos-assist-web--thread-id "thread-1")
        (cl-letf (((symbol-function 'emacsos-assist-web--request)
                   (lambda (method path payload cb &rest _)
                     (push (list method path payload) requests)
                     (setq callback cb)))
                  ((symbol-function 'emacsos-assist-web--render) #'ignore)
                  ((symbol-function 'emacsos-assist-web--try-write-cache)
                   (lambda (&rest _) t))
                  ((symbol-function 'emacsos-assist-web--git-note-safely)
                   (lambda (&rest _) nil)))
          (emacsos-assist-web-refresh-thread)
          (funcall callback snapshot nil)
          (let ((ack (cl-find-if
                       (lambda (r) (equal (nth 1 r) "threads/thread-1/open"))
                       requests)))
            (should ack)
            (should (equal (nth 0 ack) "POST"))
            (should (equal (nth 2 ack) '((revision . "rev-abc")))))))))))

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
                     (lambda (&rest _) (setq saved (emacsos-assist-web--input)) t))
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
            `((threads
               . (((id . "thread-1") (description . "Thread")
                   (search_description . "thread") (repo_label . "Assist")
                   (status . "ready") (unread . nil) (urgent . nil)
                   (unmerged . nil))))
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
    ;; The projection appends the three state fields to every wire thread; the
    ;; ZWJ/VS16 emoji in the descriptions round-trip byte-for-byte.
    (should
     (equal (alist-get 'threads catalog)
            (cl-loop for thread in threads
                     collect (append thread
                                     '((unread . nil) (urgent . nil)
                                       (unmerged . nil))))))))

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

(ert-deftest test-assist-web-catalog-carries-state-fields-and-tolerates-absent-ones ()
  (let* ((busy '((id . "busy") (description . "Busy") (search_description . "busy")
                 (repo_label . "R") (status . "processing") (urgent . t)))
         (new `((id . "new") (description . "New") (search_description . "new")
                (repo_label . "R") (status . "ready") (unread . t)))
         (plain '((id . "plain") (description . "Plain")
                  (search_description . "plain")
                  (repo_label . "R") (status . "ready")))
         ;; The unmerged wire field is a BOOL or NIL on the new wire
         ;; (true = checked dirty, false/nil = checked clean or not checked);
         ;; the projection must carry it verbatim.
         (dirty `((id . "dirty") (description . "Dirty")
                  (search_description . "dirty")
                  (repo_label . "R") (status . "ready") (unmerged . t)))
         (catalog (emacsos-assist-web--require-catalog
                   (test-assist-web--wire-catalog (list busy new plain dirty) nil nil))))
    ;; The projection keeps the three state fields as nil when the wire object
    ;; omits them, so absent fields degrade to false rather than erroring — and
    ;; carries a present unmerged bool unchanged.
    (should
     (equal (alist-get 'threads catalog)
            '(((id . "busy") (description . "Busy") (search_description . "busy")
               (repo_label . "R") (status . "processing")
               (unread . nil) (urgent . t) (unmerged . nil))
              ((id . "new") (description . "New") (search_description . "new")
               (repo_label . "R") (status . "ready")
               (unread . t) (urgent . nil) (unmerged . nil))
              ((id . "plain") (description . "Plain")
               (search_description . "plain")
               (repo_label . "R") (status . "ready")
               (unread . nil) (urgent . nil) (unmerged . nil))
              ((id . "dirty") (description . "Dirty")
               (search_description . "dirty")
               (repo_label . "R") (status . "ready")
               (unread . nil) (urgent . nil) (unmerged . t)))))))

(ert-deftest test-assist-web-state-pill-matches-web-precedence ()
  (let ((busy "🔄")
        (error "🛑")
        (urgent "⚠️")
        (new "📬")
        (unmerged "🔀"))
    ;; Each of the six live busy stages maps to the single busy token.
    (dolist (stage '("queued" "cloning" "starting_sandbox" "processing"
                     "paused" "initializing"))
      (should (equal (emacsos-assist-web--state-pill
                      `((id . "t") (status . ,stage)))
                     busy)))
    ;; First match wins, in the web's precedence.
    (should (equal (emacsos-assist-web--state-pill
                    `((status . "error") (urgent . t)))
                   error))
    (should (equal (emacsos-assist-web--state-pill
                    `((status . "ready") (urgent . t) (unread . t)))
                   urgent))
    (should (equal (emacsos-assist-web--state-pill
                    `((status . "ready") (unread . t) (unmerged . t)))
                   new))
    (should (equal (emacsos-assist-web--state-pill
                    `((status . "ready") (unmerged . t)))
                   unmerged))
    ;; Unmerged is a bool on the new wire (t/true = dirty). A legacy server may
    ;; still send the tri-state string "yes", which is accepted across the
    ;; two-PR transition window.
    (should (equal (emacsos-assist-web--state-pill
                    `((status . "ready") (unmerged . "yes")))
                   unmerged))
    ;; "no" (checked, confirmed clean) and "unknown" (not checked behind a
    ;; stronger pill) are NOT unmerged — they fall through to the raw stage.
    (should (equal (emacsos-assist-web--state-pill
                    `((status . "ready") (unmerged . "no")))
                   "ready"))
    (should (equal (emacsos-assist-web--state-pill
                    `((status . "ready") (unmerged . "unknown")))
                   "ready"))
    ;; Nothing matches: the raw stage is returned so settled rows keep a state.
    (should (equal (emacsos-assist-web--state-pill
                    `((status . "ready")))
                   "ready"))
    ;; A busy stage masks every flag below it.
    (should (equal (emacsos-assist-web--state-pill
                    `((status . "processing") (urgent . t) (unread . t)
                      (unmerged . t)))
                   busy))))

(ert-deftest test-assist-web-list-metadata-uses-state-pill ()
  (let* ((ready '((id . "a") (description . "Ready")
                  (search_description . "ready")
                  (repo_label . "R") (status . "ready")))
         (new `((id . "b") (description . "New")
                (search_description . "new")
                (repo_label . "R") (status . "ready") (unread . t)))
         (busy `((id . "c") (description . "Busy")
                 (search_description . "busy")
                 (repo_label . "R") (status . "processing")))
         (urgent `((id . "d") (description . "Urgent")
                   (search_description . "urgent")
                   (repo_label . "R") (status . "error") (urgent . t)))
         (dirty `((id . "e") (description . "Dirty")
                  (search_description . "dirty")
                  (repo_label . "R") (status . "ready") (unmerged . "yes")))
         (clean `((id . "f") (description . "Clean")
                  (search_description . "clean")
                  (repo_label . "R") (status . "ready") (unmerged . "no")))
         (emacsos-assist-web--catalog
          (test-assist-web--catalog ready new busy urgent dirty clean)))
    ;; The metadata line is one status token, never a duplicated raw stage.
    ;; Unmerged renders only for the tri-state "yes"; a confirmed-clean "no"
    ;; thread shows its raw stage, not a token.
    (should
     (equal (mapcar (lambda (record)
                      (cons (alist-get 'id (plist-get record :thread))
                            (plist-get record :metadata)))
                    (emacsos-assist-web--list-records 40))
            '(("a" . "R · ready")
              ("b" . "R · 📬")
              ("c" . "R · 🔄")
              ("d" . "R · 🛑")
              ("e" . "R · 🔀")
              ("f" . "R · ready"))))))

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
                ((symbol-function 'emacsos-assist-web--save-draft) (lambda (&rest _) t)))
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
                ((symbol-function 'emacsos-assist-web--save-draft) (lambda (&rest _) t))
                ((symbol-function 'emacsos-assist-web-refresh-thread) #'ignore))
        (emacsos-assist-web-abort)
        (should-not emacsos-assist-web--in-flight)
        (emacsos-assist-web-abort))
      (should (= requests 2))
      (should (equal emacsos-assist-web--stream-status "cancelled; reconciling")))))

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
                    ((symbol-function 'emacsos-assist-web--save-draft) (lambda (&rest _) t))
                    ((symbol-function 'emacsos-assist-web-refresh-thread)
                     (lambda (&rest _) (setq refreshed t))))
            (emacsos-assist-web-abort))
          (should (equal emacsos-assist-web--stream-status expected))
          (should (eq (and refreshed t) refresh)))))))

(ert-deftest test-assist-web-global-send-outside-thread-is-a-safe-noop ()
  (with-temp-buffer
    (emacsos-assist-web-send)
    (should-not emacsos-assist-web--in-flight)))

(ert-deftest test-assist-web-send-admits-a-different-web-buffer ()
  "Aggregate web activity does not reject another canonical thread buffer."
  (let ((emacsos--assist-active-surface 'web)
        requested)
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--thread-id "thread-2")
      (emacsos-assist-web--write-prompt)
      (insert "independent")
      (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) (lambda (&rest _) t))
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
                 (lambda (&rest _) (setq events (append events '(save))) t))
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

(ert-deftest test-assist-web-create-body-overflow-refuses-before-key-or-region ()
  "Create-only repo metadata counts in the real 66KiB body limit."
  (let (requested keys)
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq emacsos-assist-web--draft-repository (make-string 242 ?r)
            emacsos-assist-web--draft-harness (make-string 242 ?h))
      (emacsos-assist-web--write-prompt)
      ;; One-field JSON is under 66KiB; the actual create payload is not.
      (insert (make-string 21850 ?€))
      (let ((draft (emacsos-assist-web--input))
            (point-offset (- (point) (emacsos-assist-web--prompt-start)))
            (regions (how-many "you>" (point-min) (point-max))))
        (cl-letf (((symbol-function 'emacsos-assist-web--request)
                   (lambda (&rest _) (setq requested t)))
                  ((symbol-function 'emacsos-assist-web--new-idempotency-key)
                   (lambda () (setq keys (1+ (or keys 0))) "must-not-mint")))
        (emacsos-assist-web-send))
      (should-not requested)
        (should-not keys)
      (should-not emacsos-assist-web--http-draft)
        (should (= (how-many "you>" (point-min) (point-max)) regions))
        (should (equal (emacsos-assist-web--input) draft))
        (should (= (- (point) (emacsos-assist-web--prompt-start)) point-offset))
      (should (equal emacsos-assist-web--stream-status
                       "Message too large; editable draft retained"))))))

(ert-deftest test-assist-web-render-presents-markdown-and-tags-whole-message ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let ((snapshot
           '((thread . ((id . "thread-1") (description . "Thread")
                        (status . "ready")
                        (workspace . ((repo_label . "Assist")))))
             (messages . (((id . "m-1") (role . "assistant")
                           (text . "# Heading\n- item") (state . "final")))))))
      (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) (lambda (&rest _) t)))
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
      (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) (lambda (&rest _) t)))
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
      (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) (lambda (&rest _) t)))
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
                       (lambda (&rest _) t)))
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
      (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) (lambda (&rest _) t)))
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
            (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) (lambda (&rest _) t))
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
            (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) (lambda (&rest _) t))
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
      (cl-letf (((symbol-function 'emacsos-assist-web--save-draft) (lambda (&rest _) t))
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

(defconst test-assist-web--email-approval
  '((kind . "send_email") (token . "01234567890123456789012345678901")
    (from . "Assistant <assistant@example.test>") (cc . "oversight@example.test")
    (action . ((name . "send_email") (args . ((to . "recipient@example.test")
                                              (subject . "Subject")
                                              (body . "First line\nLast body line")))))))

(defun test-assist-web--approval-button (label)
  "Find the actionable approval button with LABEL in this buffer."
  (save-excursion
    (goto-char (point-min))
    (let (found)
      (while (and (not found) (search-forward label nil t))
        (setq found (button-at (1- (point)))))
      found)))

(ert-deftest test-assist-web-approval-complete-preview-and-two-tap-send ()
  (with-temp-buffer
    (emacsos-assist-web-approval-mode)
    (setq emacsos-assist-web--approval (copy-tree test-assist-web--email-approval))
    (emacsos-assist-web--render-approval)
    (dolist (field '("Assistant <assistant@example.test>" "oversight@example.test"
                     "recipient@example.test" "Subject" "First line\nLast body line"))
      (should (string-match-p (regexp-quote field) (buffer-string))))
    (let ((button (test-assist-web--approval-button "Approve and send")) sent)
      (cl-letf (((symbol-function 'emacsos-assist-web--submit-approval)
                 (lambda (decision) (setq sent decision))))
        (button-activate button)
        (should-not sent)
        (should (equal (button-get button 'display) "Confirm Approve and send?"))
        (button-activate button)
        (should (equal sent "approve"))))))

(ert-deftest test-assist-web-approval-other-action-disarms-confirmation ()
  (with-temp-buffer
    (emacsos-assist-web-approval-mode)
    (setq emacsos-assist-web--approval (copy-tree test-assist-web--email-approval))
    (emacsos-assist-web--render-approval)
    (let ((button (test-assist-web--approval-button "Approve and send")) sent)
      (cl-letf (((symbol-function 'emacsos-assist-web--submit-approval)
                 (lambda (decision) (setq sent decision))))
        (button-activate button)
        (let ((this-command 'forward-char) (last-input-event ?f))
          (emacsos-assist-web--approval-disarm))
        (should-not emacsos-assist-web--approval-armed)
        (should-not (button-get button 'display))
        (button-activate button)
        (should-not sent)))))

(ert-deftest test-assist-web-approval-native-mouse-taps-confirm-and-disarm ()
  (save-window-excursion
    (with-temp-buffer
      (emacsos-assist-web-approval-mode)
      (setq emacsos-assist-web--approval (copy-tree test-assist-web--email-approval))
      (emacsos-assist-web--render-approval)
      (set-window-buffer (selected-window) (current-buffer))
      (let ((approve (test-assist-web--approval-button "Approve and send"))
            (reject (test-assist-web--approval-button "Reject")) sent)
        (cl-letf (((symbol-function 'emacsos-assist-web--submit-approval)
                   (lambda (decision) (push decision sent))))
          (cl-labels ((tap (button)
                        (let ((position (list (selected-window) (button-start button)
                                              '(10 . 10) 0)))
                          (execute-kbd-macro
                           (vector (list 'down-mouse-1 position)
                                   (list 'mouse-1 position))))))
            (tap approve)
            (should-not sent)
            (should emacsos-assist-web--approval-armed)
            (tap approve)
            (should (equal sent '("approve")))
            (tap approve)
            (tap reject)
            (should (equal sent '("approve")))
            (should (equal (cdr emacsos-assist-web--approval-armed) "reject"))
            (execute-kbd-macro (kbd "C-f"))
            (should-not emacsos-assist-web--approval-armed)
            (tap reject)
            (should (equal sent '("approve")))
            (tap reject)
            (should (equal sent '("reject" "approve")))))))))

(ert-deftest test-assist-web-approval-tap-in-other-window-disarms ()
  (save-window-excursion
    (with-temp-buffer
      (emacsos-assist-web-approval-mode)
      (setq emacsos-assist-web--approval (copy-tree test-assist-web--email-approval))
      (emacsos-assist-web--render-approval)
      (set-window-buffer (selected-window) (current-buffer))
      (let* ((button (test-assist-web--approval-button "Approve and send"))
             (other (split-window-right))
             (this-command 'push-button)
             (last-input-event (list 'mouse-2 (list other (button-start button) '(0 . 0) 0))))
        (set-window-buffer other (get-buffer-create " *approval keyboard test*"))
        (unwind-protect
            (progn
              (button-activate button)
              (should emacsos-assist-web--approval-armed)
              (emacsos-assist-web--approval-disarm)
              (should-not emacsos-assist-web--approval-armed))
          (kill-buffer " *approval keyboard test*"))))))

(ert-deftest test-assist-web-approval-old-post-callback-preserves-new-preview ()
  (with-temp-buffer
    (emacsos-assist-web-approval-mode)
    (setq emacsos-assist-web--thread-id "thread-1"
          emacsos-assist-web--approval (copy-tree test-assist-web--email-approval))
    (let (callback)
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _data fn &rest _) (setq callback fn))))
        (emacsos-assist-web--submit-approval "approve"))
      (setq emacsos-assist-web--approval (copy-tree test-assist-web--email-approval))
      (setf (alist-get 'token emacsos-assist-web--approval) "different-proposal-token-123456")
      (emacsos-assist-web--render-approval)
      (funcall callback nil "old request failed")
      (should (string-match-p "Email awaiting approval" (buffer-string)))
      (should-not (string-match-p "Decision not confirmed" (buffer-string))))))

(ert-deftest test-assist-web-approval-editor-returns-to-full-review ()
  (with-temp-buffer
    (emacsos-assist-web-approval-mode)
    (setq emacsos-assist-web--approval (copy-tree test-assist-web--email-approval))
    (emacsos-assist-web--render-approval)
    (emacsos-assist-web--edit-approval)
    (should (eq (current-local-map) widget-keymap))
    (should-not buffer-read-only)
    (let* ((fields (sort (copy-sequence widget-field-list)
                        (lambda (a b) (< (widget-field-start a) (widget-field-start b)))))
           (to (nth 0 fields)) (subject (nth 1 fields)) (body (nth 2 fields)))
      (widget-value-set to "edited@example.test")
      (widget-value-set subject "Edited subject")
      (widget-value-set body "New body\nFinal edited line")
      (goto-char (point-min))
      (search-forward "Review edited email")
      (widget-apply (widget-at (1- (point))) :notify nil)
      (should buffer-read-only)
      (should (equal emacsos-assist-web--approval-edited
                     '((to . "edited@example.test") (subject . "Edited subject")
                       (body . "New body\nFinal edited line"))))
      (should (string-match-p "Final edited line" (buffer-string)))
      (should (test-assist-web--approval-button "Send edited email"))
      (should (equal (alist-get 'token emacsos-assist-web--approval)
                     (alist-get 'token test-assist-web--email-approval))))))

(ert-deftest test-assist-web-approval-email-bodies-links-and-unavailable-preview ()
  (with-temp-buffer
    (emacsos-assist-web-approval-mode)
    (setq emacsos-assist-web--approval
          '((kind . "email_delete") (token . "01234567890123456789012345678901")
            (action . ((name . "email_delete") (args . ((message_ids . ("abc123"))))))
            (messages . (((id . "abc123") (from . "sender@example.test")
                          (to . "reader@example.test") (date . "Yesterday")
                          (subject . "Subject") (body . "Complete mail body"))))))
    (emacsos-assist-web--require-approval
     `((thread_id . "thread-1") (proposal . ,emacsos-assist-web--approval)) "thread-1")
    (emacsos-assist-web--render-approval)
    (should (string-match-p "Complete mail body" (buffer-string)))
    (should-not (string-match-p "Gmail" (buffer-string)))
    (let (opened)
      (cl-letf (((symbol-function 'browse-url) (lambda (url &rest _) (setq opened url))))
        (button-activate (test-assist-web--approval-button "Open email")))
      (should (equal opened "https://mail.google.com/mail/u/0/#all/abc123")))
    (setf (alist-get 'error emacsos-assist-web--approval) "Complete body unavailable"
          (alist-get 'messages emacsos-assist-web--approval) nil)
    (emacsos-assist-web--require-approval
     `((thread_id . "thread-1") (proposal . ,emacsos-assist-web--approval)) "thread-1")
    (emacsos-assist-web--render-approval)
    (should (string-match-p "Complete body unavailable" (buffer-string)))
    (should-not (string-match-p "Approve" (buffer-string)))
    (should (test-assist-web--approval-button "Reject"))))

(ert-deftest test-assist-web-approval-email-opaque-id-and-encoded-link ()
  (with-temp-buffer
    (emacsos-assist-web-approval-mode)
    (setq emacsos-assist-web--approval
          '((kind . "email_archive") (token . "01234567890123456789012345678901")
            (action . ((name . "email_archive")
                       (args . ((message_ids . ("opaque id?#é"))))))
            (messages . (((id . "opaque id?#é") (from . "sender@example.test")
                          (to . "reader@example.test") (date . "Yesterday")
                          (subject . "Subject") (body . "Complete mail body"))))))
    (should (eq emacsos-assist-web--approval
                (emacsos-assist-web--require-approval
                 `((thread_id . "thread-1") (proposal . ,emacsos-assist-web--approval))
                 "thread-1")))
    (emacsos-assist-web--render-approval)
    (should (string-match-p (regexp-quote "Id: opaque id?#é") (buffer-string)))
    (should (test-assist-web--approval-button "Approve"))
    (let (opened)
      (cl-letf (((symbol-function 'browse-url) (lambda (url &rest _) (setq opened url))))
        (button-activate (test-assist-web--approval-button "Open email")))
      (should (equal opened "https://mail.google.com/mail/u/0/#all/opaque%20id%3F%23%C3%A9")))))

(ert-deftest test-assist-web-approval-failure-requires-fresh-preview ()
  (with-temp-buffer
    (emacsos-assist-web-approval-mode)
    (setq emacsos-assist-web--thread-id "thread-1"
          emacsos-assist-web--approval (copy-tree test-assist-web--email-approval))
    (emacsos-assist-web--render-approval)
    (let (payload)
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path data callback &rest _)
                   (setq payload data)
                   (funcall callback nil "request timed out"))))
        (emacsos-assist-web--submit-approval "approve"))
      (should (equal (alist-get 'token payload)
                     (alist-get 'token test-assist-web--email-approval)))
      (should-not (plist-get (emacsos-assist-web--thread-safety-record "thread-1")
                             :approval-pending))
      (should (string-match-p "Decision not confirmed" (buffer-string)))
      (should-not (string-match-p "Approve" (buffer-string)))
      (should (test-assist-web--approval-button "Refresh proposal")))))

(ert-deftest test-assist-web-approval-rejects-spoofing-and-mismatched-message-ids ()
  (let ((proposal (copy-tree test-assist-web--email-approval)))
    (setf (alist-get 'body (alist-get 'args (alist-get 'action proposal)))
          (concat "Hidden" (string #x202e) "text"))
    (should-error (emacsos-assist-web--require-approval
                   `((thread_id . "thread-1") (proposal . ,proposal)) "thread-1")))
  (should-error
   (emacsos-assist-web--require-approval
    '((thread_id . "thread-1")
      (proposal . ((kind . "email_archive") (token . "01234567890123456789012345678901")
                   (action . ((name . "email_archive") (args . ((message_ids . ("abc"))))))
                   (messages . (((id . "def") (from . "") (to . "")
                                 (date . "") (subject . "") (body . "")))))))
    "thread-1")))

(ert-deftest test-assist-web-old-approval-get-cannot-clear-new-denial ()
  "An older preview response cannot reopen a proposal after canonical denial."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq emacsos-assist-web--thread-id "thread-1")
    (let (callback)
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload cb &rest _) (setq callback cb))))
        (emacsos-assist-web-review-approval (current-buffer)))
      (cl-incf emacsos-assist-web--auth-epoch)
      (setq emacsos-assist-web--denied t)
      (funcall callback `((thread_id . "thread-1")
                          (proposal . ,(copy-tree test-assist-web--email-approval))) nil)
      (should emacsos-assist-web--denied)
      (should-not (get-buffer "*assist Approval thread-1*")))))

(ert-deftest test-assist-web-approval-rejects-multiline-headers ()
  "Email proposal headers cannot insert trusted field labels or body lines."
  (dolist (field '(from cc to subject))
    (let* ((proposal (copy-tree test-assist-web--email-approval))
           (target (if (memq field '(from cc)) proposal
                     (alist-get 'args (alist-get 'action proposal)))))
      (setf (alist-get field target) "attacker\nCc: hidden@example.test")
      (should-error (emacsos-assist-web--require-approval
                     `((thread_id . "thread-1") (proposal . ,proposal)) "thread-1")))))

(ert-deftest test-assist-web-empty-refresh-closes-stale-approval ()
  "An authoritative empty preview removes the old decision controls."
  (let ((source (generate-new-buffer " *empty approval source*"))
        (preview (get-buffer-create "*assist Approval thread-1*")))
    (unwind-protect
        (progn
          (with-current-buffer source
            (emacsos-assist-web-mode)
            (setq emacsos-assist-web--thread-id "thread-1"))
          (with-current-buffer preview
            (emacsos-assist-web-approval-mode)
            (setq emacsos-assist-web--approval-source source
                  emacsos-assist-web--approval (copy-tree test-assist-web--email-approval))
            (emacsos-assist-web--render-approval))
          (cl-letf (((symbol-function 'emacsos-assist-web--request)
                     (lambda (_method _path _payload callback &rest _)
                       (funcall callback '((thread_id . "thread-1") (proposal)) nil)))
                    ((symbol-function 'emacsos-assist-web-refresh-thread) #'ignore))
            (emacsos-assist-web-review-approval source))
          (should-not (buffer-live-p preview)))
      (when (buffer-live-p preview) (kill-buffer preview))
      (kill-buffer source))))


(ert-deftest test-assist-web-approval-editor-rejects-header-newlines ()
  "Reviewing an edit preserves the editor until single-line headers are valid."
  (with-temp-buffer
    (emacsos-assist-web-approval-mode)
    (setq emacsos-assist-web--approval (copy-tree test-assist-web--email-approval))
    (emacsos-assist-web--edit-approval)
    (let* ((fields (sort (copy-sequence widget-field-list)
                         (lambda (a b) (< (widget-field-start a) (widget-field-start b)))))
           (subject (nth 1 fields)))
      (widget-value-set subject "Spoof\nCc: hidden@example.test"))
    (goto-char (point-min))
    (search-forward "Review edited email")
    (widget-apply (widget-at (1- (point))) :notify nil)
    (should-not emacsos-assist-web--approval-edited)
    (should-not buffer-read-only)))


(ert-deftest test-assist-web-approval-rejects-multiline-mailbox-headers ()
  "Exact email previews admit multiline bodies but reject injected header rows."
  (dolist (field '(from to date subject))
    (let* ((message '((id . "abc123") (from . "sender@example.test")
                      (to . "reader@example.test") (date . "Yesterday")
                      (subject . "Subject") (body . "Full\nbody")))
           (mail (copy-tree message))
           (proposal `((kind . "email_delete") (token . "01234567890123456789012345678901")
                       (action . ((name . "email_delete") (args . ((message_ids . ("abc123"))))))
                       (messages . (,mail)))))
      (setf (alist-get field mail) "Spoof\nFrom: someone@example.test")
      (should-error (emacsos-assist-web--require-approval
                     `((thread_id . "thread-1") (proposal . ,proposal)) "thread-1")))))

(ert-deftest test-assist-web-empty-old-refresh-preserves-newer-peer-proposal ()
  "An empty response can close only the preview present when its read began."
  (let ((source (generate-new-buffer " *old empty source*"))
        (preview (get-buffer-create "*assist Approval thread-1*")) callback)
    (unwind-protect
        (progn
          (with-current-buffer source
            (emacsos-assist-web-mode)
            (setq emacsos-assist-web--thread-id "thread-1"))
          (with-current-buffer preview
            (emacsos-assist-web-approval-mode)
            (setq emacsos-assist-web--approval (copy-tree test-assist-web--email-approval)))
          (cl-letf (((symbol-function 'emacsos-assist-web--request)
                     (lambda (_method _path _payload cb &rest _) (setq callback cb)))
                    ((symbol-function 'emacsos-assist-web-refresh-thread) #'ignore))
            (emacsos-assist-web-review-approval source)
            (with-current-buffer preview
              (setq emacsos-assist-web--approval (copy-tree test-assist-web--email-approval))
              (emacsos-assist-web--render-approval))
            (funcall callback '((thread_id . "thread-1") (proposal)) nil))
          (should (buffer-live-p preview))
          (with-current-buffer preview
            (should (test-assist-web--approval-button "Approve and send"))))
      (when (buffer-live-p preview) (kill-buffer preview))
      (kill-buffer source))))

(ert-deftest test-assist-web-approval-http-denial-fences-preview-and-old-callback ()
  "Malformed approval denials latch every peer before an old callback can return."
  (dolist (status '(401 403 404))
   (dolist (path '("approval" "approvals"))
    (let ((source (generate-new-buffer " *approval denial source*"))
          (peer (generate-new-buffer " *approval denial peer*"))
          (preview (get-buffer-create "*assist Approval thread-1*"))
          (emacsos-assist-web--thread-safety (make-hash-table :test #'equal))
          (emacsos-assist-web--requests nil)
          old-callback)
      (unwind-protect
          (progn
            (dolist (buffer (list source peer))
              (with-current-buffer buffer
                (emacsos-assist-web-mode)
                (setq emacsos-assist-web--thread-id "thread-1")))
            (with-current-buffer preview
              (emacsos-assist-web-approval-mode)
              (setq emacsos-assist-web--thread-id "thread-1"
                    emacsos-assist-web--approval-source source
                    emacsos-assist-web--approval (copy-tree test-assist-web--email-approval))
              (emacsos-assist-web--render-approval))
            (cl-letf (((symbol-function 'emacsos-assist-web--request)
                       (lambda (_method _path _payload callback &rest _)
                         (setq old-callback callback))))
              (emacsos-assist-web-review-approval source))
            (cl-letf (((symbol-function 'emacsos-assist-web--read-token)
                       (lambda () "token"))
                      ((symbol-function 'run-at-time) (lambda (&rest _) nil))
                      ((symbol-function 'url-retrieve)
                       (lambda (_url callback &rest _)
                         (let ((response (generate-new-buffer " *approval denial response*")))
                           (with-current-buffer response
                             (setq-local url-http-response-status status
                                         url-http-content-type "text/plain"
                                         url-http-end-of-headers (copy-marker (point-min)))
                             (insert "malformed denial")
                             (funcall callback nil))
                           response))))
              (with-current-buffer source
                (emacsos-assist-web--request
                 "GET" (format "threads/thread-1/%s" path) nil (lambda (&rest _) nil))))
            (dolist (buffer (list source peer))
              (with-current-buffer buffer
                (should emacsos-assist-web--denied)
                (should (= emacsos-assist-web--thread-denial-status status))
                (should (> emacsos-assist-web--auth-epoch 0))))
            (should-not (buffer-live-p preview))
            (funcall old-callback
                     `((thread_id . "thread-1")
                       (proposal . ,(copy-tree test-assist-web--email-approval))) nil)
            (should-not (get-buffer "*assist Approval thread-1*")))
        (dolist (buffer (list preview peer source))
          (when (buffer-live-p buffer) (kill-buffer buffer))))))))

(ert-deftest test-assist-web-canonical-reauthorization-clears-thread-denial ()
  "Canonical authorization clears a denied thread and its live peers."
  (let ((source (generate-new-buffer " *reauthorization source*"))
        (peer (generate-new-buffer " *reauthorization peer*"))
        (emacsos-assist-web--thread-safety (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (dolist (buffer (list source peer))
            (with-current-buffer buffer
              (emacsos-assist-web-mode)
              (setq emacsos-assist-web--thread-id "thread-1")))
          (with-current-buffer source
            (emacsos-assist-web--canonical-denied 401)
            (let ((epoch emacsos-assist-web--auth-epoch))
              (should emacsos-assist-web--denied)
              (should (plist-get
                       (emacsos-assist-web--thread-safety-record "thread-1")
                       :denial))
              (emacsos-assist-web--canonical-authorized epoch)
              (should-not emacsos-assist-web--denied)
              (should-not (plist-get
                           (emacsos-assist-web--thread-safety-record "thread-1")
                           :denial))))
          (with-current-buffer peer
            (should-not emacsos-assist-web--denied)))
      (dolist (buffer (list peer source))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest test-assist-web-approval-orders-reads-across-peers ()
  "An older peer's response cannot replace or close the newer peer's preview."
  (dolist (old-value (list `((thread_id . "thread-1")
                            (proposal . ,(copy-tree test-assist-web--email-approval)))
                          '((thread_id . "thread-1") (proposal))))
    (let ((a (generate-new-buffer " *approval older peer*"))
          (b (generate-new-buffer " *approval newer peer*"))
          (emacsos-assist-web--thread-safety (make-hash-table :test #'equal))
          callbacks)
      (unwind-protect
          (progn
            (dolist (buffer (list a b))
              (with-current-buffer buffer
                (emacsos-assist-web-mode)
                (setq emacsos-assist-web--thread-id "thread-1")))
            (cl-letf (((symbol-function 'emacsos-assist-web--request)
                       (lambda (_method _path _payload callback &rest _)
                         (push callback callbacks)))
                      ((symbol-function 'emacsos-assist-web-refresh-thread) #'ignore))
              (emacsos-assist-web-review-approval a)
              (emacsos-assist-web-review-approval b)
              (let ((new (copy-tree test-assist-web--email-approval)))
                (setf (alist-get 'token new) "newer-proposal-token-1234567890")
                (funcall (car callbacks) `((thread_id . "thread-1") (proposal . ,new)) nil)
                (funcall (cadr callbacks) old-value nil)
                (with-current-buffer "*assist Approval thread-1*"
                  (should (eq emacsos-assist-web--approval new))))))
        (when-let ((preview (get-buffer "*assist Approval thread-1*")))
          (kill-buffer preview))
        (kill-buffer a)
        (kill-buffer b)))))

(ert-deftest test-assist-web-approval-transient-failure-keeps-canonical-state ()
  "Only definitive approval access denials affect canonical authorization."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq emacsos-assist-web--thread-id "thread-1")
    (let (uncertain)
      (cl-letf (((symbol-function 'emacsos-assist-web--canonical-uncertain)
                 (lambda () (setq uncertain t))))
        (dolist (status '(nil 500))
          (should-not (emacsos-assist-web--http-access-status
                       (current-buffer) "GET" "threads/thread-1/approval" status t))
          (should-not uncertain))
        (should (emacsos-assist-web--http-access-status
                 (current-buffer) "GET" "threads/thread-1" nil t))
        (should uncertain)))))

(ert-deftest test-assist-web-approval-delayed-get-after-accepted-post ()
  (let ((a (generate-new-buffer " *reviewer approval a*"))
        (b (generate-new-buffer " *reviewer approval b*"))
        (emacsos-assist-web--thread-safety (make-hash-table :test #'equal))
        gets post)
    (unwind-protect
        (progn
          (dolist (buf (list a b))
            (with-current-buffer buf
              (emacsos-assist-web-mode)
              (setq emacsos-assist-web--thread-id "thread-1")))
          (cl-letf (((symbol-function 'emacsos-assist-web--request)
                     (lambda (method _path _payload cb &rest _)
                       (if (equal method "GET") (push cb gets) (setq post cb))))
                    ((symbol-function 'emacsos-assist-web-refresh-thread) #'ignore))
            (emacsos-assist-web-review-approval a)
            (funcall (car gets) `((thread_id . "thread-1") (proposal . ,(copy-tree test-assist-web--email-approval))) nil)
            (emacsos-assist-web-review-approval b)
            (let ((delayed (car gets)))
              (with-current-buffer "*assist Approval thread-1*"
                (emacsos-assist-web--submit-approval "approve"))
              (funcall post '((thread_id . "thread-1") (run_id . "accepted-resume")) nil)
              (should-not (get-buffer "*assist Approval thread-1*"))
              (funcall delayed `((thread_id . "thread-1") (proposal . ,(copy-tree test-assist-web--email-approval))) nil)
              (should-not (get-buffer "*assist Approval thread-1*")))))
      (when-let ((preview (get-buffer "*assist Approval thread-1*"))) (kill-buffer preview))
      (kill-buffer a) (kill-buffer b))))

(ert-deftest test-assist-web-approval-valid-ack-survives-preview-reentry ()
  (let ((a (generate-new-buffer " *reviewer approval a*"))
        (b (generate-new-buffer " *reviewer approval b*"))
        (emacsos-assist-web--thread-safety (make-hash-table :test #'equal))
        gets post refreshed)
    (unwind-protect
        (progn
          (dolist (buf (list a b))
            (with-current-buffer buf
              (emacsos-assist-web-mode)
              (setq emacsos-assist-web--thread-id "thread-1")))
          (cl-letf (((symbol-function 'emacsos-assist-web--request)
                     (lambda (method _path _payload cb &rest _)
                       (if (equal method "GET") (push cb gets) (setq post cb))))
                    ((symbol-function 'emacsos-assist-web-refresh-thread)
                     (lambda (buffer &rest _) (push buffer refreshed))))
            (emacsos-assist-web-review-approval a)
            (funcall (car gets) `((thread_id . "thread-1") (proposal . ,(copy-tree test-assist-web--email-approval))) nil)
            (emacsos-assist-web-review-approval b)
            (let ((delayed (car gets)))
              (with-current-buffer "*assist Approval thread-1*"
                (emacsos-assist-web--submit-approval "approve"))
              (funcall delayed `((thread_id . "thread-1") (proposal . ,(copy-tree test-assist-web--email-approval))) nil)
              (funcall post '((thread_id . "thread-1") (run_id . "accepted-resume")) nil)
              (should (memq a refreshed))
              (should-not (get-buffer "*assist Approval thread-1*")))))
      (when-let ((preview (get-buffer "*assist Approval thread-1*"))) (kill-buffer preview))
      (kill-buffer a) (kill-buffer b))))

(ert-deftest test-assist-web-approval-editor-enforces-api-field-boundaries ()
  "Oversized edits stay in the editor; valid boundary text returns to review."
  (dolist (field-limit '((to 320 ?a) (subject 998 ?a) (body 65536 ?a)
                       (subject 499 ?é) (body 32768 ?é)))
    (dolist (extra '(0 1))
      (with-temp-buffer
        (emacsos-assist-web-approval-mode)
        (setq emacsos-assist-web--approval (copy-tree test-assist-web--email-approval))
        (emacsos-assist-web--edit-approval)
        (let* ((fields (sort (copy-sequence widget-field-list)
                             (lambda (a b) (< (widget-field-start a) (widget-field-start b)))))
               (field (nth (cl-position (car field-limit) '(to subject body)) fields))
               (value (make-string (+ (cadr field-limit) extra) (caddr field-limit)))
               notice)
          (widget-value-set field value)
          (goto-char (point-min))
          (search-forward "Review edited email")
          (cl-letf (((symbol-function 'message)
                     (lambda (format &rest args) (setq notice (apply #'format format args)))))
            (widget-apply (widget-at (1- (point))) :notify nil))
          (if (= extra 0)
              (progn
                (should buffer-read-only)
                (should (equal (alist-get (car field-limit) emacsos-assist-web--approval-edited) value)))
            (should-not buffer-read-only)
            (should-not emacsos-assist-web--approval-edited)
            (should (equal (widget-value field) value))
            (should (string-prefix-p "Email exceeds approval limits" notice))))))))

(ert-deftest test-assist-web-approval-pending-post-survives-preview-reentry ()
  (dolist (recreate '(nil t))
    (let ((source (generate-new-buffer " *pending approval source*"))
          (emacsos-assist-web--thread-safety (make-hash-table :test #'equal))
          get posts)
      (unwind-protect
          (progn
            (with-current-buffer source
              (emacsos-assist-web-mode)
              (setq emacsos-assist-web--thread-id "thread-1"))
            (cl-letf (((symbol-function 'emacsos-assist-web--request)
                       (lambda (method _path _payload callback &rest _)
                         (if (equal method "GET") (setq get callback)
                           (push callback posts))))
                      ((symbol-function 'emacsos-assist-web-refresh-thread) #'ignore))
              (emacsos-assist-web-review-approval source)
              (funcall get `((thread_id . "thread-1")
                            (proposal . ,(copy-tree test-assist-web--email-approval))) nil)
              (emacsos-assist-web-review-approval source)
              (with-current-buffer "*assist Approval thread-1*"
                (emacsos-assist-web--submit-approval "approve"))
              (when recreate (kill-buffer "*assist Approval thread-1*"))
              (funcall get `((thread_id . "thread-1")
                            (proposal . ,(copy-tree test-assist-web--email-approval))) nil)
              (with-current-buffer "*assist Approval thread-1*"
                (let ((reject (test-assist-web--approval-button "Reject")))
                  (button-activate reject)
                  (button-activate reject))
                (should (= (length posts) 1))
                (should-error (emacsos-assist-web--submit-approval "reject") :type 'user-error))
              (funcall (car posts) '((thread_id . "thread-1") (run_id . "accepted-resume")) nil)
              (should-not (get-buffer "*assist Approval thread-1*"))
              (should-not (plist-get (emacsos-assist-web--thread-safety-record "thread-1")
                                     :approval-pending))))
        (when-let ((preview (get-buffer "*assist Approval thread-1*"))) (kill-buffer preview))
        (kill-buffer source)))))

(ert-deftest test-assist-web-approval-native-taps-in-two-preview-windows-rearm ()
  (save-window-excursion
    (with-temp-buffer
      (emacsos-assist-web-approval-mode)
      (setq emacsos-assist-web--approval (copy-tree test-assist-web--email-approval))
      (emacsos-assist-web--render-approval)
      (set-window-buffer (selected-window) (current-buffer))
      (let ((first (selected-window)) (second (split-window-right))
            (approve (test-assist-web--approval-button "Approve and send")) sent)
        (set-window-buffer second (current-buffer))
        (cl-letf (((symbol-function 'emacsos-assist-web--submit-approval)
                   (lambda (decision) (setq sent decision))))
          (cl-labels ((tap (window)
                        (select-window window)
                        (let ((position (list window (button-start approve) '(10 . 10) 0)))
                          (execute-kbd-macro
                           (vector (list 'down-mouse-1 position) (list 'mouse-1 position))))))
            (tap first)
            (tap second)
            (should-not sent)
            (tap second)
            (should (equal sent "approve"))))))))

(ert-deftest test-assist-web-approval-editor-canonicalizes-crlf-body ()
  (with-temp-buffer
    (emacsos-assist-web-approval-mode)
    (setq emacsos-assist-web--approval (copy-tree test-assist-web--email-approval))
    (setf (alist-get 'body (alist-get 'args (alist-get 'action emacsos-assist-web--approval)))
          "First\r\nLast")
    (emacsos-assist-web--edit-approval)
    (goto-char (point-min))
    (search-forward "Review edited email")
    (widget-apply (widget-at (1- (point))) :notify nil)
    (should buffer-read-only)
    (should (equal (alist-get 'body emacsos-assist-web--approval-edited) "First\nLast"))))

(ert-deftest test-assist-web-approval-ack-closes-recreated-preview ()
  (let ((source (generate-new-buffer " *reviewer recreated source*"))
        (emacsos-assist-web--thread-safety (make-hash-table :test #'equal))
        get post)
    (unwind-protect
        (progn
          (with-current-buffer source
            (emacsos-assist-web-mode)
            (setq emacsos-assist-web--thread-id "thread-1"))
          (cl-letf (((symbol-function 'emacsos-assist-web--request)
                     (lambda (method _path _payload cb &rest _)
                       (if (equal method "GET") (setq get cb) (setq post cb))))
                    ((symbol-function 'emacsos-assist-web-refresh-thread) #'ignore))
            (emacsos-assist-web-review-approval source)
            (funcall get `((thread_id . "thread-1") (proposal . ,(copy-tree test-assist-web--email-approval))) nil)
            (with-current-buffer "*assist Approval thread-1*" (emacsos-assist-web--submit-approval "approve"))
            (kill-buffer "*assist Approval thread-1*")
            (emacsos-assist-web-review-approval source)
            (funcall get `((thread_id . "thread-1") (proposal . ,(copy-tree test-assist-web--email-approval))) nil)
            (funcall post '((thread_id . "thread-1") (run_id . "accepted-resume")) nil)
            (should-not (get-buffer "*assist Approval thread-1*"))))
      (when-let ((preview (get-buffer "*assist Approval thread-1*"))) (kill-buffer preview))
      (kill-buffer source))))

(ert-deftest test-assist-web-approval-reuses-preapproval-safety-record ()
  "An open thread's pre-approval record remains usable after code upgrade."
  (let ((source (generate-new-buffer " *old safety approval source*"))
        (emacsos-assist-web--thread-safety (make-hash-table :test #'equal))
        get)
    (unwind-protect
        (progn
          (with-current-buffer source
            (emacsos-assist-web-mode)
            (setq emacsos-assist-web--thread-id "thread-1"))
          (let ((old (list :buffers (list source) :stops nil :denial nil)))
            (puthash "thread-1" old emacsos-assist-web--thread-safety)
            (cl-letf (((symbol-function 'emacsos-assist-web--request)
                       (lambda (_method _path _payload callback &rest _) (setq get callback))))
              (emacsos-assist-web-review-approval source)
              (should (eq old (gethash "thread-1" emacsos-assist-web--thread-safety)))
              (should (= (plist-get old :approval-generation) 1))
              (funcall get `((thread_id . "thread-1")
                            (proposal . ,(copy-tree test-assist-web--email-approval))) nil)
              (with-current-buffer "*assist Approval thread-1*"
                (should (test-assist-web--approval-button "Approve and send"))
                (emacsos-assist-web--submit-approval "approve")
                (should (plist-get old :approval-pending))
                (should-error (emacsos-assist-web--submit-approval "reject") :type 'user-error)))))
      (when-let ((preview (get-buffer "*assist Approval thread-1*"))) (kill-buffer preview))
      (kill-buffer source))))

(ert-deftest test-assist-web-approval-scalar-ack-requires-fresh-preview ()
  "Every non-object JSON acknowledgment removes unconfirmed decision controls."
  (dolist (ack '("accepted" 1 t :false [] nil))
    (let ((source (generate-new-buffer " *scalar ack source*"))
          (preview (get-buffer-create "*assist Approval thread-1*"))
          (emacsos-assist-web--thread-safety (make-hash-table :test #'equal))
          post)
      (unwind-protect
          (progn
            (with-current-buffer source
              (emacsos-assist-web-mode)
              (setq emacsos-assist-web--thread-id "thread-1"))
            (with-current-buffer preview
              (emacsos-assist-web-approval-mode)
              (setq emacsos-assist-web--thread-id "thread-1"
                    emacsos-assist-web--approval-source source
                    emacsos-assist-web--approval (copy-tree test-assist-web--email-approval))
              (emacsos-assist-web--render-approval)
              (cl-letf (((symbol-function 'emacsos-assist-web--request)
                         (lambda (_method _path _payload callback &rest _) (setq post callback))))
                (emacsos-assist-web--submit-approval "approve")))
            (funcall post ack nil)
            (should-not (plist-get (emacsos-assist-web--thread-safety-record "thread-1") :approval-pending))
            (with-current-buffer preview
              (should (string-prefix-p "Decision not confirmed" (buffer-string)))
              (should-not (test-assist-web--approval-button "Approve and send"))
              (should-not (test-assist-web--approval-button "Reject"))
              (should (test-assist-web--approval-button "Refresh proposal"))))
        (when (buffer-live-p preview) (kill-buffer preview))
        (kill-buffer source)))))

(defconst test-assist-web--egress-approval
  '((kind . "egress") (token . "01234567890123456789012345678901")
    (state . "pending") (host . "docs.example.test") (port . 443)
    (task . "Read synthetic documentation") (main_task . "")
    (lifetime . "") (decisions . ("hour" "always" "decline"))))

(ert-deftest test-assist-web-parity-approval-ready-thread-discovery ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let ((snapshot (copy-tree test-assist-web--snapshot)))
      (setf (alist-get 'approval_count (alist-get 'thread snapshot)) 1)
      (emacsos-assist-web--render snapshot)
      (should (test-assist-web--approval-button "Review pending action")))))

(ert-deftest test-assist-web-parity-approval-egress-scope-and-two-taps ()
  (with-temp-buffer
    (emacsos-assist-web-approval-mode)
    (setq emacsos-assist-web--thread-id "parity-egress"
          emacsos-assist-web--approval (copy-tree test-assist-web--egress-approval))
    (should (emacsos-assist-web--require-approval
             `((thread_id . "parity-egress") (proposal . ,emacsos-assist-web--approval)) "parity-egress"))
    (emacsos-assist-web--render-approval)
    (should (string-match-p "docs.example.test:443" (buffer-string)))
    (should (string-match-p "For this thread only" (buffer-string)))
    (let ((button (test-assist-web--approval-button "Allow for 1 hour")) decisions)
      (cl-letf (((symbol-function 'emacsos-assist-web--submit-approval)
                 (lambda (decision) (push decision decisions))))
        (button-activate button)
        (should-not decisions)
        (button-activate button)
        (should (equal decisions '("hour")))))))

(ert-deftest test-assist-web-parity-approval-all-kinds-share-one-chooser ()
  (let ((source (generate-new-buffer " *parity-source*")) preview)
    (unwind-protect
        (progn
          (with-current-buffer source
            (emacsos-assist-web-mode)
            (setq emacsos-assist-web--thread-id "parity-list"))
          (emacsos-assist-web--approval-choose
           source "parity-list" (list (copy-tree test-assist-web--egress-approval)
                                     (copy-tree test-assist-web--email-approval)))
          (setq preview (current-buffer))
          (should (string-match-p "egress: docs.example.test" (buffer-string)))
          (should (string-match-p "send_email: Email" (buffer-string)))
          (button-activate (test-assist-web--approval-button "egress: docs.example.test [pending]"))
          (should (test-assist-web--approval-button "Allow for this thread")))
      (when (buffer-live-p preview) (kill-buffer preview))
      (kill-buffer source))))

(ert-deftest test-assist-web-parity-approval-result-does-not-offer-grants ()
  (with-temp-buffer
    (emacsos-assist-web-approval-mode)
    (setq emacsos-assist-web--approval (copy-tree test-assist-web--egress-approval))
    (setf (alist-get 'state emacsos-assist-web--approval) "declined"
          (alist-get 'decisions emacsos-assist-web--approval) nil)
    (emacsos-assist-web--render-approval)
    (should (string-match-p "State: declined" (buffer-string)))
    (should-not (test-assist-web--approval-button "Allow for 1 hour"))
    (should-not (test-assist-web--approval-button "Decline"))))

(ert-deftest test-assist-web-parity-approval-non-run-ack-is-exact ()
  (let ((proposal test-assist-web--egress-approval))
    (should (emacsos-assist-web--approval-ack-p
             `((thread_id . "thread-1") (kind . "egress")
               (token . ,(alist-get 'token proposal)) (status . "approved")) "thread-1" proposal))
    (should-not (emacsos-assist-web--approval-ack-p
                 '((thread_id . "thread-1") (run_id . "forged") (status . "approved"))
                 "thread-1" proposal))
    (should-not (emacsos-assist-web--approval-ack-p
                 '((thread_id . "thread-1") (kind . "egress") (token . "other") (status . "approved"))
                 "thread-1" proposal))))

(ert-deftest test-assist-web-parity-approval-invalid-summary-preserves-draft ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (emacsos-assist-web--render (copy-tree test-assist-web--snapshot))
    (emacsos-assist-web--replace-input "Unsent draft")
    (let ((before (buffer-string))
          (snapshot (copy-tree test-assist-web--snapshot)))
      (setf (alist-get 'approval_count (alist-get 'thread snapshot)) "1"
            (alist-get 'approval_results (alist-get 'thread snapshot)) t)
      (should-error (emacsos-assist-web--render snapshot))
      (should (equal (buffer-string) before))
      (should (equal (emacsos-assist-web--input) "Unsent draft")))))

(ert-deftest test-assist-web-parity-approval-empty-refresh-closes-selected-chooser ()
  (let ((source (generate-new-buffer " *parity-empty-source*")) preview callback
        (emacsos-assist-web--thread-safety (make-hash-table :test #'equal)))
    (unwind-protect
        (progn
          (with-current-buffer source
            (emacsos-assist-web-mode)
            (setq emacsos-assist-web--thread-id "parity-empty"))
          (emacsos-assist-web--approval-choose
           source "parity-empty" (list test-assist-web--egress-approval test-assist-web--email-approval))
          (setq preview (current-buffer))
          (cl-letf (((symbol-function 'emacsos-assist-web--request)
                     (lambda (_method _path _payload cb &rest _) (setq callback cb)))
                    ((symbol-function 'emacsos-assist-web-refresh-thread) #'ignore))
            (emacsos-assist-web-review-approval source)
            (with-current-buffer preview
              (button-activate (test-assist-web--approval-button "egress: docs.example.test [pending]")))
            (funcall callback '((thread_id . "parity-empty") (proposals . nil)) nil)
            (should-not (buffer-live-p preview))))
      (when (buffer-live-p preview) (kill-buffer preview))
      (kill-buffer source))))

(defconst test-assist-web--reply-approval
  '((kind . "send_reply") (token . "01234567890123456789012345678901")
    (state . "pending") (sender . "+15555550100")
    (action . ((name . "send_reply") (args . ((text . "Complete synthetic reply\nFinal line")))))
    (decisions . ("approve" "edit" "reject"))))

(defconst test-assist-web--download-approval
  '((kind . "geo_download") (token . "01234567890123456789012345678901")
    (state . "pending") (slug . "test/exact-region") (display_name . "Synthetic region")
    (size_bytes . 1200) (warning . "Import rebuilds the geocoder; requests pause during replacement.")
    (decisions . ("approve" "reject"))))

(ert-deftest test-assist-web-approval-pending-requires-complete-advertised-decisions ()
  (dolist (fixture (list test-assist-web--egress-approval test-assist-web--reply-approval
                         test-assist-web--download-approval))
    (let ((complete (alist-get 'decisions fixture)))
      (dolist (partial (list nil (list (car complete)) (make-list (length complete) (car complete))))
        (let ((proposal (copy-tree fixture)))
          (setf (alist-get 'decisions proposal) partial)
          (should-error (emacsos-assist-web--require-approval
                         `((thread_id . "thread-1") (proposal . ,proposal)) "thread-1"))))
      (let ((proposal (copy-tree fixture)))
        (setf (alist-get 'decisions proposal) (reverse (copy-sequence complete)))
        (should (emacsos-assist-web--require-approval
                 `((thread_id . "thread-1") (proposal . ,proposal)) "thread-1")))))
  (let ((proposal (copy-tree test-assist-web--egress-approval)))
    (setf (alist-get 'decisions proposal) '("revoke"))
    (should-error (emacsos-assist-web--require-approval
                   `((thread_id . "thread-1") (proposal . ,proposal)) "thread-1"))))

(ert-deftest test-assist-web-approval-reply-renders-complete-recipient-and-text ()
  (with-temp-buffer
    (emacsos-assist-web-approval-mode)
    (setq emacsos-assist-web--approval (copy-tree test-assist-web--reply-approval))
    (emacsos-assist-web--require-approval
     `((thread_id . "thread-1") (proposal . ,emacsos-assist-web--approval)) "thread-1")
    (emacsos-assist-web--render-approval)
    (should (string-match-p (regexp-quote "Reply to: +15555550100\n\nComplete synthetic reply\nFinal line")
                            (buffer-string)))
    (should (test-assist-web--approval-button "Approve and send"))
    (should (test-assist-web--approval-button "Edit reply"))
    (should (test-assist-web--approval-button "Reject"))))

(ert-deftest test-assist-web-approval-download-renders-exact-region-size-and-warning ()
  (dolist (size '(1200 nil))
    (with-temp-buffer
      (emacsos-assist-web-approval-mode)
      (setq emacsos-assist-web--approval (copy-tree test-assist-web--download-approval))
      (setf (alist-get 'size_bytes emacsos-assist-web--approval) size)
      (emacsos-assist-web--require-approval
       `((thread_id . "thread-1") (proposal . ,emacsos-assist-web--approval)) "thread-1")
      (emacsos-assist-web--render-approval)
      (dolist (text (list "Download: Synthetic region" "Region: test/exact-region"
                         (if size "Size: 1200 bytes" "Size unknown")
                         (alist-get 'warning emacsos-assist-web--approval)))
        (should (string-match-p (regexp-quote text) (buffer-string))))
      (should (test-assist-web--approval-button "Approve download"))
      (should (test-assist-web--approval-button "Decline")))))


(ert-deftest test-assist-web-approval-uncertain-post-invalidates-chooser-and-older-get ()
  (dolist (get-first '(nil t))
    (let ((source (generate-new-buffer " *uncertain chooser source*"))
          (emacsos-assist-web--thread-safety (make-hash-table :test #'equal))
          get post posts)
      (unwind-protect
          (progn
            (with-current-buffer source
              (emacsos-assist-web-mode)
              (setq emacsos-assist-web--thread-id "thread-1"))
            (cl-letf (((symbol-function 'emacsos-assist-web--request)
                       (lambda (method _path payload callback &rest _)
                         (if (equal method "GET") (setq get callback)
                           (push payload posts) (setq post callback))))
                      ((symbol-function 'emacsos-assist-web-refresh-thread) #'ignore))
              (emacsos-assist-web-review-approval source)
              (funcall get `((thread_id . "thread-1")
                            (proposal . ,(copy-tree test-assist-web--reply-approval))) nil)
              (with-current-buffer "*assist Approval thread-1*"
                (emacsos-assist-web--submit-approval "approve"))
              (emacsos-assist-web-review-approval source)
              (let ((old-get get)
                    (collection `((thread_id . "thread-1")
                                  (proposals . ,(list test-assist-web--reply-approval
                                                      test-assist-web--egress-approval)))))
                (when get-first (funcall old-get collection nil))
                (funcall post nil "synthetic timeout")
                (unless get-first (funcall old-get collection nil))
                (with-current-buffer "*assist Approval thread-1*"
                  (should (string-match-p "Decision not confirmed" (buffer-string)))
                  (should-not (test-assist-web--approval-button "send_reply: +15555550100 [pending]"))
                  (should-not (test-assist-web--approval-button "Approve and send")))
                (should (= (length posts) 1))
                ;; Only a read started after the uncertain result can restore controls.
                (emacsos-assist-web-review-approval source)
                (funcall get collection nil)
                (with-current-buffer "*assist Approval thread-1*"
                  (button-activate (test-assist-web--approval-button "send_reply: +15555550100 [pending]"))
                  (let ((button (test-assist-web--approval-button "Approve and send")))
                    (button-activate button)
                    (should (= (length posts) 1))
                    (button-activate button)
                    (should (= (length posts) 2)))))))
        (when-let ((preview (get-buffer "*assist Approval thread-1*"))) (kill-buffer preview))
        (kill-buffer source)))))

(ert-deftest test-assist-web-approval-reply-editor-reviews-before-exact-second-tap ()
  (with-temp-buffer
    (emacsos-assist-web-approval-mode)
    (setq emacsos-assist-web--thread-id "reply-editor"
          emacsos-assist-web--approval (copy-tree test-assist-web--reply-approval))
    (let ((emacsos-assist-web--thread-safety (make-hash-table :test #'equal)) posts)
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (method path payload _callback &rest _)
                   (push (list method path payload) posts))))
        (emacsos-assist-web--edit-reply)
        (widget-value-set (car widget-field-list) "Edited reply\r\nFinal line")
        (goto-char (point-min))
        (search-forward "Review edited reply")
        (widget-apply (widget-at (1- (point))) :notify nil)
        (should buffer-read-only)
        (should (equal emacsos-assist-web--approval-edited '((text . "Edited reply\nFinal line"))))
        (should (string-match-p "Edited reply\nFinal line" (buffer-string)))
        (should-not posts)
        (let ((button (test-assist-web--approval-button "Send edited reply")))
          (button-activate button)
          (should-not posts)
          (button-activate button))
        (should (equal posts
                       `(("POST" "threads/reply-editor/approval"
                          ((kind . "send_reply") (token . ,(alist-get 'token test-assist-web--reply-approval))
                           (decision . "edit") (text . "Edited reply\nFinal line"))))))))))

(ert-deftest test-assist-web-approval-reply-editor-cancel-keeps-reviewed-text ()
  (dolist (prior '(nil "Previously reviewed edit"))
    (with-temp-buffer
      (emacsos-assist-web-approval-mode)
      (setq emacsos-assist-web--thread-id "reply-cancel"
            emacsos-assist-web--approval (copy-tree test-assist-web--reply-approval)
            emacsos-assist-web--approval-edited (and prior `((text . ,prior))))
      (let ((emacsos-assist-web--thread-safety (make-hash-table :test #'equal)))
        (cl-letf (((symbol-function 'emacsos-assist-web--request)
                   (lambda (&rest _) (ert-fail "Cancelling an edit submitted a request"))))
          (emacsos-assist-web--edit-reply)
          (widget-value-set (car widget-field-list) "Discard this edit")
          (goto-char (point-min))
          (search-forward "Cancel edit")
          (widget-apply (widget-at (1- (point))) :notify nil)
          (should buffer-read-only)
          (should (equal emacsos-assist-web--approval-edited (and prior `((text . ,prior)))))
          (should (string-match-p (regexp-quote (or prior "Complete synthetic reply\nFinal line"))
                                  (buffer-string)))
          (should-not (string-match-p "Discard this edit" (buffer-string))))))))

(ert-deftest test-assist-web-approval-reply-editor-enforces-utf8-boundary ()
  (dolist (value (list (make-string 65536 ?a) (make-string 32768 ?é)
                       (make-string 65537 ?a) (make-string 32769 ?é) "   " "bad\0text"))
    (with-temp-buffer
      (emacsos-assist-web-approval-mode)
      (setq emacsos-assist-web--thread-id "reply-size"
            emacsos-assist-web--approval (copy-tree test-assist-web--reply-approval))
      (let ((emacsos-assist-web--thread-safety (make-hash-table :test #'equal)))
        (emacsos-assist-web--edit-reply)
        (let ((field (car widget-field-list)))
          (widget-value-set field value)
          (goto-char (point-min))
          (search-forward "Review edited reply")
          (widget-apply (widget-at (1- (point))) :notify nil)
          (if (= (string-bytes value) 65536)
              (progn (should buffer-read-only)
                     (should (equal (alist-get 'text emacsos-assist-web--approval-edited) value)))
            (should-not buffer-read-only)
            (should-not emacsos-assist-web--approval-edited)
            (should (equal (widget-value field) value))))))))


(ert-deftest test-assist-web-approval-reply-crlf-collection-canonicalizes-before-validation ()
  (dolist (text '("First line\r\nSecond line" "First line\rSecond line"))
    (let ((proposal (copy-tree test-assist-web--reply-approval)))
      (setf (alist-get 'text (alist-get 'args (alist-get 'action proposal))) text)
      (let* ((collection (emacsos-assist-web--approval-response
                          `((thread_id . "thread-1")
                            (proposals . ,(list proposal test-assist-web--egress-approval))) "thread-1"))
             (reply (car collection)))
        (should (= (length collection) 2))
        (should (equal (alist-get 'token reply) (alist-get 'token proposal)))
        (should (equal (alist-get 'text (alist-get 'args (alist-get 'action proposal))) text))
        (with-temp-buffer
          (emacsos-assist-web-approval-mode)
          (setq emacsos-assist-web--thread-id "thread-1" emacsos-assist-web--approval reply)
          (let ((emacsos-assist-web--thread-safety (make-hash-table :test #'equal)))
            (emacsos-assist-web--render-approval)
            (should (string-match-p "First line\nSecond line" (buffer-string)))
            (should (test-assist-web--approval-button "Reject"))
            (emacsos-assist-web--edit-reply)
            (should (equal (widget-value (car widget-field-list)) "First line\nSecond line"))))))))

(ert-deftest test-assist-web-approval-success-closes-stale-chooser-preserving-selected-peer ()
  (dolist (order '(before after different-peer))
    (let ((source (generate-new-buffer " *success chooser source*"))
          (emacsos-assist-web--thread-safety (make-hash-table :test #'equal))
          get post)
      (unwind-protect
          (progn
            (with-current-buffer source
              (emacsos-assist-web-mode)
              (setq emacsos-assist-web--thread-id "thread-1"))
            (cl-letf (((symbol-function 'emacsos-assist-web--request)
                       (lambda (method _path _payload callback &rest _)
                         (if (equal method "GET") (setq get callback) (setq post callback))))
                      ((symbol-function 'emacsos-assist-web-refresh-thread) #'ignore))
              (emacsos-assist-web-review-approval source)
              (funcall get `((thread_id . "thread-1") (proposal . ,test-assist-web--reply-approval)) nil)
              (with-current-buffer "*assist Approval thread-1*"
                (emacsos-assist-web--submit-approval "approve"))
              (emacsos-assist-web-review-approval source)
              (let ((old-get get)
                    (collection `((thread_id . "thread-1")
                                  (proposals . ,(list test-assist-web--reply-approval
                                                      test-assist-web--egress-approval)))))
                (unless (eq order 'after) (funcall old-get collection nil))
                (when (eq order 'different-peer)
                  (with-current-buffer "*assist Approval thread-1*"
                    (button-activate (test-assist-web--approval-button "egress: docs.example.test [pending]"))))
                (funcall post '((thread_id . "thread-1") (run_id . "accepted-reply")) nil)
                (when (eq order 'after) (funcall old-get collection nil))
                (if (eq order 'different-peer)
                    (with-current-buffer "*assist Approval thread-1*"
                      (should (equal (alist-get 'kind emacsos-assist-web--approval) "egress"))
                      (should (test-assist-web--approval-button "Allow for 1 hour")))
                  (should-not (get-buffer "*assist Approval thread-1*"))))))
        (when-let ((preview (get-buffer "*assist Approval thread-1*"))) (kill-buffer preview))
        (kill-buffer source)))))

(provide 'test-assist-web)


(ert-deftest test-assist-web-read-receipt-transport-fences-definitive-auth-denial ()
  "Exercise actual request parsing; old-server 404 and transient failures stay benign."
  (dolist (status '(401 403 404 500))
    (let ((emacsos-assist-web-api-url "https://assist.invalid/api/v1/phone")
          (emacsos-assist-web--thread-safety (make-hash-table :test #'equal))
          (emacsos-assist-web--requests nil) bearer endpoint)
      (with-temp-buffer
        (emacsos-assist-web-mode)
        (setq emacsos-assist-web--thread-id "thread-1")
        (cl-letf (((symbol-function 'emacsos-assist-web--read-token) (lambda () "token"))
                  ((symbol-function 'run-at-time) (lambda (&rest _) nil))
                  ((symbol-function 'url-retrieve)
                   (lambda (url callback &rest _)
                     (setq endpoint url bearer (assoc "Authorization" url-request-extra-headers))
                     (let ((response (generate-new-buffer " *receipt response*")))
                       (with-current-buffer response
                         (setq-local url-http-response-status status
                                     url-http-content-type "text/plain"
                                     url-http-end-of-headers (copy-marker (point-min)))
                         (insert "malformed response")
                         (funcall callback nil))
                       response))))
          (emacsos-assist-web--ack-thread-read "thread-1" "revision"))
        (should bearer)
        (should (equal endpoint "https://assist.invalid/api/v1/phone/threads/thread-1/open"))
        (should (eq (not (null emacsos-assist-web--denied))
                    (not (null (memq status '(401 403))))))))))

(ert-deftest test-assist-web-unicode-request-is-byte-exact-with-restored-headers ()
  "The stock HTTP builder accepts file credentials and restored JSON keys."
  (require 'url-http)
  (let* ((emacsos-assist-web-token-file (make-temp-file "assist-synthetic-token-"))
         (emacsos-assist-web-api-url "https://assist.invalid/api/v1/phone")
         (emacsos-assist-web--requests nil)
         (text "café — 🐟\nsecond line")
         (key (alist-get 'key (json-parse-string
                              "{\"key\":\"emacsos-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa\"}"
                              :object-type 'alist)))
         (response (generate-new-buffer " *unicode-wire*"))
         request problem (attempts 0))
    (unwind-protect
        (progn
          (with-temp-file emacsos-assist-web-token-file (insert "synthetic-only\n"))
          (should (multibyte-string-p (emacsos-assist-web--read-token)))
          (should (multibyte-string-p key))
          (cl-letf (((symbol-function 'run-at-time) (lambda (&rest _) nil))
                    ((symbol-function 'url-retrieve)
                     (lambda (url &rest _)
                       (cl-incf attempts)
                       (cl-progv
                           '(url-http-target-url url-http-method url-http-extra-headers
                             url-http-data url-http-proxy url-http-referer
                             url-http-version url-privacy-level)
                           (list (url-generic-parse-url url) url-request-method
                                 url-request-extra-headers url-request-data nil nil
                                 "1.1" 'paranoid)
                         (setq request (url-http-create-request)))
                       response)))
            (emacsos-assist-web--request
             "POST" "threads/synthetic/messages" `((message . ,text))
             (lambda (_value error) (setq problem error))
             `(("Idempotency-Key" . ,key))))
          ;; Do not print the builder's request-bearing exception on failure.
          (should-not (not (null problem)))
          (should (= attempts 1))
          (should (= (length request) (string-bytes request)))
          (let* ((boundary (string-match "\r\n\r\n" request))
                 (body (substring request (+ boundary 4)))
                 (decoded (json-parse-string (decode-coding-string body 'utf-8)
                                             :object-type 'alist)))
            (should (equal (alist-get 'message decoded) text))
            (should (string-match
                     (format "Content-length: %d\r\n" (string-bytes body)) request))
            (should (string-match-p (concat "Idempotency-Key: " key "\r\n") request))))
      (delete-file emacsos-assist-web-token-file)
      (when (buffer-live-p response) (kill-buffer response)))))
