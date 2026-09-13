;;; assist-web.el --- Assist Web threads in EmacsOS -*- lexical-binding: t -*-

;;; Commentary:

;; This is deliberately separate from emacsos-assist.el.  A .assist file is a
;; phone-local conversation owned by emacsos-server; this mode is a client of
;; Assist Web's canonical thread/run state.

;;; Code:

(require 'cl-lib)
(require 'chat)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'url)
(require 'url-http)
(require 'url-util)

(declare-function emacsos--render-page "os")
(defvar url-http-content-type)
(defvar url-http-end-of-headers)
(defvar url-http-open-connections)
(defvar url-http-response-status)
(defvar url-http-attempt-keepalives)
(defvar gnutls-trustfiles)

(defgroup emacsos-assist-web nil
  "Assist Web thread client for EmacsOS."
  :group 'emacsos)

(defcustom emacsos-assist-web-api-url "https://assist.invalid/api/v1/phone"
  "Base URL of the authenticated Assist Web phone API."
  :type 'string
  :group 'emacsos-assist-web)

(defcustom emacsos-assist-web-token-file
  (expand-file-name "~/.config/emacsos/assist-web-token")
  "0600 file holding the Assist Web bearer token."
  :type 'file
  :group 'emacsos-assist-web)

(defcustom emacsos-assist-web-ca-file nil
  "Optional CA certificate trusted only for Assist Web requests."
  :type '(choice (const :tag "System trust only" nil) file)
  :group 'emacsos-assist-web)

(defcustom emacsos-assist-web-cache-directory
  (expand-file-name "~/.cache/emacsos/assist-web")
  "Private on-phone cache for Assist Web catalogs, snapshots, and drafts."
  :type 'directory
  :group 'emacsos-assist-web)

(defcustom emacsos-assist-web-max-cache-bytes (* 512 1024)
  "Maximum encoded size of one private Assist Web cache record."
  :type 'integer
  :group 'emacsos-assist-web)

(defcustom emacsos-assist-web-max-response-bytes (* 1024 1024)
  "Maximum buffered JSON response accepted from Assist Web."
  :type 'integer
  :group 'emacsos-assist-web)

(defcustom emacsos-assist-web-max-event-bytes (* 64 1024)
  "Maximum size of one complete or unfinished SSE event from Assist Web."
  :type 'integer
  :group 'emacsos-assist-web)

(defcustom emacsos-assist-web-max-header-bytes (* 64 1024)
  "Maximum HTTP response-header size accepted from Assist Web."
  :type 'integer
  :group 'emacsos-assist-web)

(defcustom emacsos-assist-web-request-timeout 30
  "Seconds allowed for one bounded Assist Web JSON request."
  :type 'integer
  :group 'emacsos-assist-web)

(defcustom emacsos-assist-web-max-concurrent-requests 4
  "Maximum simultaneous bounded Assist Web JSON requests."
  :type 'integer
  :group 'emacsos-assist-web)

(defconst emacsos-assist-web--prompt "\n> ")
(defconst emacsos-assist-web--catalog-file "threads.json")
(defconst emacsos-assist-web--id-regexp "\\`[A-Za-z0-9][A-Za-z0-9._-]\\{0,127\\}\\'")
(defconst emacsos-assist-web--record-id-regexp
  "\\`[A-Za-z0-9_-]\\{1,242\\}\\'")
(defconst emacsos-assist-web--idempotency-regexp "\\`emacsos-[0-9a-f]\\{32\\}\\'")
(defvar emacsos-assist-web--catalog nil)
(defvar emacsos-assist-web--catalog-loaded-p nil)
(defvar emacsos-assist-web--catalog-stale nil)
(defvar emacsos-assist-web--catalog-generation 0)
(defvar emacsos-assist-web--requests nil)
(defvar-local emacsos-assist-web--thread-id nil)
(defvar-local emacsos-assist-web--draft-repository nil)
(defvar-local emacsos-assist-web--draft-harness nil)
(defvar-local emacsos-assist-web--run-id nil)
(defvar-local emacsos-assist-web--pending-key nil)
(defvar-local emacsos-assist-web--in-flight nil)
(defvar-local emacsos-assist-web--snapshot nil)
(defvar-local emacsos-assist-web--stream-process nil)
(defvar-local emacsos-assist-web--stream-response nil)
(defvar-local emacsos-assist-web--stream-body-marker nil)
(defvar-local emacsos-assist-web--stream-scan-marker nil)
(defvar-local emacsos-assist-web--stream-unconsumed-bytes nil)
(defvar-local emacsos-assist-web--status-start nil)
(defvar-local emacsos-assist-web--status-end nil)
(defvar-local emacsos-assist-web--stream-status nil)
(defvar-local emacsos-assist-web--submitted-text nil)
(defvar-local emacsos-assist-web--draft-id nil)
(defvar-local emacsos-assist-web--draft-save-timer nil)
(defvar-local emacsos-assist-web--refresh-generation 0)
(defvar-local emacsos-assist-web--send-generation 0)
(defvar-local emacsos-assist-web--stream-generation 0)
(defvar-local emacsos-assist-web--stream-header-timer nil)
(defvar-local emacsos-assist-web--prompt-marker nil)
(defvar-local emacsos-assist-web--input-marker nil)
(defvar-local emacsos-assist-web--pending-accepted-p nil)
(defvar-local emacsos-assist-web--pending-rendered-p nil)
(defvar-local emacsos-assist-web--assistant-start nil)
(defvar-local emacsos-assist-web--assistant-end nil)
(defvar-local emacsos-assist-web--stream-attempt nil)
(defvar-local emacsos-assist-web--stream-index 0)

(defun emacsos-assist-web--cache-path (&optional name)
  "Return the cache path for NAME without changing the filesystem."
  (expand-file-name (or name emacsos-assist-web--catalog-file)
                    emacsos-assist-web-cache-directory))

(defun emacsos-assist-web--write-cache (name value)
  "Atomically save VALUE as JSON cache NAME."
  (let ((encoded (json-encode value))
        (path (emacsos-assist-web--cache-path name))
        (temporary nil))
    (when (> (string-bytes encoded) emacsos-assist-web-max-cache-bytes)
      (error "Assist Web cache record is too large"))
    (make-directory emacsos-assist-web-cache-directory t)
    (set-file-modes emacsos-assist-web-cache-directory #o700)
    (make-directory (file-name-directory path) t)
    (set-file-modes (file-name-directory path) #o700)
    (setq temporary (make-temp-file (concat path ".") nil ".tmp"))
    (unwind-protect
        (progn
          (with-temp-file temporary
            (insert encoded))
          (set-file-modes temporary #o600)
          (rename-file temporary path t)
          (setq temporary nil))
      (when (and temporary (file-exists-p temporary))
        (delete-file temporary)))))

(defun emacsos-assist-web--try-write-cache (name value)
  "Write cache NAME as VALUE, returning nil after a visible local failure."
  (condition-case error
      (progn (emacsos-assist-web--write-cache name value) t)
    (error
     (message "Assist Web could not update its local cache: %s"
              (error-message-string error))
     nil)))

(defun emacsos-assist-web--delete-cache (name)
  "Delete cache NAME if present, reporting but containing local failures."
  (condition-case error
      (let ((path (emacsos-assist-web--cache-path name)))
        (when (file-exists-p path) (delete-file path))
        t)
    (error
     (message "Assist Web could not remove an old local draft: %s"
              (error-message-string error))
     nil)))

(defun emacsos-assist-web--read-cache (name)
  "Return parsed JSON cache NAME, or nil when no valid cache exists."
  (condition-case nil
      (let ((path (emacsos-assist-web--cache-path name)))
        (when (and (file-readable-p path)
                   (<= (file-attribute-size (file-attributes path))
                       emacsos-assist-web-max-cache-bytes))
          (with-temp-buffer
            (insert-file-contents path)
            (json-parse-buffer :object-type 'alist :array-type 'list
                               :null-object nil :false-object nil))))
    (error nil)))

(defun emacsos-assist-web--read-token ()
  "Return the bearer token without exposing it in a message or URL."
  (when (file-readable-p emacsos-assist-web-token-file)
    (with-temp-buffer
      ;; Two bytes beyond the token limit distinguish one optional final LF
      ;; from an oversized or multi-line file without an unbounded read.
      (insert-file-contents-literally emacsos-assist-web-token-file nil 0 514)
      (let ((contents (buffer-string)))
        (if (string-suffix-p "\n" contents)
            (substring contents 0 -1)
          contents)))))

(defun emacsos-assist-web--safe-token-p (token)
  "Return non-nil when TOKEN matches the provisioned bearer-token contract."
  (and (stringp token)
       (<= (length token) 512)
       (string-match-p "\\`[A-Za-z0-9._~-]+\\'" token)))

(defun emacsos-assist-web--endpoint (path)
  "Join API PATH without accepting a caller-controlled host."
  (let ((parsed (url-generic-parse-url emacsos-assist-web-api-url)))
    (unless (and (equal (url-type parsed) "https")
                 (stringp (url-host parsed))
                 (not (string-empty-p (url-host parsed))))
      (error "Assist Web API URL must be HTTPS"))
    (concat (replace-regexp-in-string "/+\\'" "" emacsos-assist-web-api-url)
            "/" (replace-regexp-in-string "\\`/+" "" path))))

(defun emacsos-assist-web--trustfiles ()
  "Return GnuTLS trust files with the configured Assist CA first."
  (let* ((configured (and (boundp 'gnutls-trustfiles) gnutls-trustfiles))
         (system-trust (if (functionp configured)
                           (funcall configured)
                         configured)))
    (unless (listp system-trust)
      (error "GnuTLS trust configuration must return a list"))
    (if (and emacsos-assist-web-ca-file
             (file-readable-p emacsos-assist-web-ca-file))
        (cons emacsos-assist-web-ca-file
              (cl-remove emacsos-assist-web-ca-file system-trust :test #'equal))
      system-trust)))

(defun emacsos-assist-web--close-idle-origin-connections ()
  "Close pooled URL connections for the configured Assist origin."
  (let* ((parsed (url-generic-parse-url emacsos-assist-web-api-url))
         (key (cons (url-host parsed) (url-port parsed))))
    (when (hash-table-p url-http-open-connections)
      (dolist (process (copy-sequence
                        (gethash key url-http-open-connections)))
        (when (processp process)
          (set-process-query-on-exit-flag process nil)
          (delete-process process)))
      (remhash key url-http-open-connections))))

(defun emacsos-assist-web--valid-id-p (value)
  "Return non-nil when VALUE is a safe opaque Assist Web identifier."
  (and (stringp value) (string-match-p emacsos-assist-web--id-regexp value)))

(defun emacsos-assist-web--require-id (value)
  "Return VALUE or reject it before it reaches an endpoint or cache path."
  (unless (emacsos-assist-web--valid-id-p value)
    (error "Assist Web returned an invalid identifier"))
  value)

(defun emacsos-assist-web--require-record-id (value)
  "Return a bounded opaque message or history-cursor VALUE."
  (unless (and (stringp value)
               (string-match-p emacsos-assist-web--record-id-regexp value))
    (error "Assist Web returned an invalid record identifier"))
  value)

(defun emacsos-assist-web--require-idempotency-key (value)
  "Return locally minted VALUE or reject it before HTTP header construction."
  (unless (and (stringp value)
               (string-match-p emacsos-assist-web--idempotency-regexp value))
    (error "Assist Web retry identity is invalid"))
  value)

(defun emacsos-assist-web--object-p (value)
  "Return non-nil when VALUE is an alist-shaped JSON object."
  (and (listp value) (seq-every-p #'consp value)))

(defun emacsos-assist-web--require-catalog (value)
  "Return the validated thread/repository/harness catalog VALUE."
  (unless (and (emacsos-assist-web--object-p value)
               (assq 'threads value) (listp (alist-get 'threads value))
               (assq 'repositories value) (listp (alist-get 'repositories value))
               (assq 'harnesses value) (listp (alist-get 'harnesses value)))
    (error "Assist Web returned an invalid catalog"))
  (dolist (thread (alist-get 'threads value))
    (unless (and (emacsos-assist-web--object-p thread)
                 (emacsos-assist-web--valid-id-p (alist-get 'id thread))
                 (stringp (alist-get 'description thread))
                 (stringp (alist-get 'search_description thread))
                 (stringp (alist-get 'repo_label thread))
                 (stringp (alist-get 'status thread)))
      (error "Assist Web returned an invalid thread catalog entry")))
  (dolist (repository (alist-get 'repositories value))
    (unless (and (emacsos-assist-web--object-p repository)
                 (stringp (alist-get 'repo_key repository))
                 (not (string-empty-p (alist-get 'repo_key repository)))
                 (stringp (alist-get 'label repository)))
      (error "Assist Web returned an invalid repository choice")))
  (dolist (harness (alist-get 'harnesses value))
    (unless (and (emacsos-assist-web--object-p harness)
                 (stringp (alist-get 'key harness))
                 (not (string-empty-p (alist-get 'key harness)))
                 (stringp (alist-get 'label harness)))
      (error "Assist Web returned an invalid harness choice")))
  value)

(defun emacsos-assist-web--require-snapshot (value &optional expected-thread-id)
  "Return validated snapshot VALUE for EXPECTED-THREAD-ID when supplied."
  (let ((thread (and (emacsos-assist-web--object-p value)
                     (alist-get 'thread value)))
        (messages (and (emacsos-assist-web--object-p value)
                       (alist-get 'messages value))))
    (unless (and (emacsos-assist-web--object-p thread)
                 (assq 'messages value) (listp messages)
                 (emacsos-assist-web--valid-id-p (alist-get 'id thread))
                 (stringp (alist-get 'description thread))
                 (stringp (alist-get 'status thread))
                 (let ((remote-error (alist-get 'error thread)))
                   (or (null remote-error) (stringp remote-error)))
                 (emacsos-assist-web--object-p (alist-get 'workspace thread))
                 (stringp (alist-get 'repo_label
                                     (alist-get 'workspace thread))))
      (error "Assist Web returned an invalid thread snapshot"))
    (when (and expected-thread-id
               (not (equal expected-thread-id (alist-get 'id thread))))
      (error "Assist Web snapshot identity does not match request"))
    (let ((seen (make-hash-table :test #'equal)))
      (dolist (message messages)
        (unless (and (emacsos-assist-web--object-p message)
                     (condition-case nil
                         (progn
                           (emacsos-assist-web--require-record-id
                            (alist-get 'id message))
                           t)
                       (error nil))
                     (member (alist-get 'role message) '("user" "assistant"))
                     (stringp (alist-get 'text message))
                     (member (alist-get 'state message) '("final" "incomplete")))
          (error "Assist Web returned an invalid thread message"))
        (let ((identity (alist-get 'id message)))
          (when (gethash identity seen)
            (error "Assist Web returned duplicate message identities"))
          (puthash identity t seen))))
    (when-let ((cursor (alist-get 'next_before value)))
      (emacsos-assist-web--require-record-id cursor))
    value))

(defun emacsos-assist-web--require-history-page (page thread-id current before)
  "Return PAGE after validating its identity and progress from CURRENT/BEFORE."
  (emacsos-assist-web--require-snapshot page thread-id)
  (let ((seen (make-hash-table :test #'equal))
        (next (alist-get 'next_before page)))
    (dolist (message (alist-get 'messages current))
      (puthash (alist-get 'id message) t seen))
    (dolist (message (alist-get 'messages page))
      (let ((identity (alist-get 'id message)))
        (when (gethash identity seen)
          (error "Assist Web returned overlapping history"))
        (puthash identity t seen)))
    (when (and next (equal next before))
      (error "Assist Web history cursor did not advance"))
    (when (and (alist-get 'has_older_messages page) (not next))
      (error "Assist Web returned incomplete history progress")))
  page)

(defun emacsos-assist-web--run-store-unavailable-response-p (buffer)
  "Return non-nil only for Assist's bounded unavailable-Run-store response."
  (with-current-buffer buffer
    (let ((status (and (boundp 'url-http-response-status)
                       url-http-response-status))
          (content-type (and (boundp 'url-http-content-type)
                             url-http-content-type))
          (start (and (boundp 'url-http-end-of-headers) url-http-end-of-headers)))
      (and (integerp status)
           (= status 503)
           (stringp content-type)
           (string-match-p "\\`application/json\\(?:[ ;]\\|\\'\\)"
                           (downcase content-type))
           start
           (condition-case nil
               (save-excursion
                 (goto-char start)
                 (skip-chars-forward " \\t\\r\\n")
                 (let ((value (json-parse-buffer :object-type 'alist :array-type 'list
                                                 :null-object nil :false-object nil)))
                   (skip-chars-forward " \\t\\r\\n")
                   (and (eobp)
                        (equal (alist-get 'detail value) "run-store-unavailable"))))
             (error nil))))))

(defun emacsos-assist-web--response-json (buffer &optional allow-status)
  "Return BUFFER's JSON value or signal a useful local error.
When ALLOW-STATUS is non-nil, require an integer HTTP status and a top-level
object, retaining that status as `http_status' so the DELETE adapter can
distinguish its bounded structured 409 outcomes."
  (with-current-buffer buffer
    (let ((status url-http-response-status)
          (start (and (boundp 'url-http-end-of-headers) url-http-end-of-headers)))
      (unless (and (integerp status)
                   (or (<= 200 status 299)
                       (and allow-status (= status 409))))
        (if (emacsos-assist-web--run-store-unavailable-response-p buffer)
            (error "Assist Web run store is unavailable")
          (error "Assist Web request failed (%s)" (or status "no response"))))
      (unless (and (stringp url-http-content-type)
                   (string-match-p "\\`application/json\\(?:[ ;]\\|\\'\\)"
                                   (downcase url-http-content-type)))
        (error "Assist Web returned an unexpected response type"))
      (unless start (error "Assist Web returned no response body"))
      (goto-char start)
      (skip-chars-forward " \t\r\n")
      (when (and allow-status (not (eq (char-after) ?{)))
        (error "Assist Web returned an unexpected response body"))
      (let ((value (json-parse-buffer :object-type 'alist :array-type 'list
                                      :null-object nil :false-object nil)))
        (skip-chars-forward " \t\r\n")
        (unless (eobp)
          (error "Assist Web returned an unexpected response body"))
        (if allow-status (cons (cons 'http_status status) value) value)))))

(defun emacsos-assist-web--guarded-filter (url-filter fail &optional streaming)
  "Wrap URL-FILTER with raw HTTP bounds, invoking FAIL with a safe message.

STREAMING permits an unbounded body only for a valid 200 SSE response; it
bounds every other response and each individual SSE record before URL-FILTER
retains it.  Headers and encoded responses are rejected before URL-FILTER can
redirect or decompress them."
  (let ((received 0) (header "") (header-complete nil) (failed nil)
        (stream-record-bytes 0) (stream-delimiter-prefix nil)
        (bounded-body (not streaming)))
    (cl-labels
        ((check-stream-body
          (process body)
          ;; Retain one possible delimiter byte between TCP callbacks.  A
          ;; callback may contain arbitrarily many bounded SSE records, but an
          ;; unterminated record is rejected before url-http copies it.
          (let ((body (concat (or stream-delimiter-prefix "") body))
                (start 0))
            (setq stream-delimiter-prefix nil)
            (while (and (not failed) (string-match "\n\n" body start))
              (cl-incf stream-record-bytes
                       (string-bytes (substring body start (match-beginning 0))))
              (if (> stream-record-bytes emacsos-assist-web-max-event-bytes)
                  (progn
                    (setq failed t)
                    (funcall fail process "Assist event is too large"))
                (setq stream-record-bytes 0
                      start (match-end 0))))
            (when (not failed)
              (let ((tail (substring body start)))
                (when (string-suffix-p "\n" tail)
                  (setq stream-delimiter-prefix "\n"
                        tail (substring tail 0 -1)))
                (cl-incf stream-record-bytes (string-bytes tail))
                (when (> stream-record-bytes emacsos-assist-web-max-event-bytes)
                  (setq failed t)
                  (funcall fail process "Assist event is too large")))))))
      (lambda (process bytes)
        (unless failed
          (let ((body (and header-complete bytes)))
            (setq received (+ received (string-bytes bytes)))
            (when (and bounded-body
                       (> received emacsos-assist-web-max-response-bytes))
              (setq failed t)
              (funcall fail process "Assist Web response is too large"))
            (unless (or failed header-complete)
              (setq header (concat header bytes))
              (let ((header-end (string-match "\r?\n\r?\n" header)))
                (cond
                 ((and (not header-end)
                       (> (string-bytes header) emacsos-assist-web-max-header-bytes))
                  (setq failed t)
                  (funcall fail process "Assist Web response headers are too large"))
                 (header-end
                  (let ((headers-only (substring header 0 (match-end 0))))
                    (if (> (string-bytes headers-only)
                           emacsos-assist-web-max-header-bytes)
                        (progn
                          (setq failed t)
                          (funcall fail process "Assist Web response headers are too large"))
                      (setq header-complete t
                            body (substring header (match-end 0))
                            bounded-body
                            (not (and streaming
                                      (not (null (string-match-p
                                       "\\`HTTP/[0-9.]+[ \\t]+200\\(?:[ \\t]\\|\\r?\\n\\)"
                                       headers-only)))
                                      (let ((case-fold-search t))
                                        (string-match-p
                                         "\\(?:\\`\\|[\r\n]\\)Content-Type[ \t]*:[ \t]*text/event-stream\\(?:[; \t\r\n]\\|\\'\\)"
                                         headers-only)))))
                      (let ((case-fold-search t)
                            (position 0))
                        (while (and (not failed)
                                    (string-match
                                     "\\(?:\\`\\|[\r\n]\\)Content-Encoding[ \t]*:[ \t]*\\([^\r\n]*\\)"
                                     headers-only position))
                          (unless (equal (downcase (string-trim
                                                    (match-string 1 headers-only)))
                                         "identity")
                            (setq failed t)
                            (funcall fail process
                                     "Assist Web encoded responses are not accepted"))
                          (setq position (match-end 0))))
                    (setq header nil)
                    (when (and (not failed) bounded-body
                               (> received emacsos-assist-web-max-response-bytes))
                      (setq failed t)
                      (funcall fail process "Assist Web response is too large"))))))))
            (when (and (not failed) streaming header-complete (not bounded-body))
              (check-stream-body process body))
            (when (and (not failed) (functionp url-filter))
              (funcall url-filter process bytes))))))))

(defun emacsos-assist-web--request (method path payload callback &optional headers allow-status)
  "Send METHOD to PATH with optional JSON PAYLOAD and HEADERS.

Invoke CALLBACK with (VALUE ERROR).  Report network and parsing failures as
ERROR rather than raising them from url-http's asynchronous callback.  Pass
ALLOW-STATUS only for a bounded structured non-2xx response the caller owns."
  (let (token token-error)
    (condition-case error
        (setq token (emacsos-assist-web--read-token))
      (error (setq token-error (error-message-string error))))
    (if token-error
        (funcall callback nil token-error)
      (if (not (emacsos-assist-web--safe-token-p token))
        (funcall callback nil "Assist Web token is missing or invalid")
      (if (>= (length emacsos-assist-web--requests)
              emacsos-assist-web-max-concurrent-requests)
          (funcall callback nil "Too many Assist Web requests are already running")
        (let* ((url-request-method method)
               (url-request-extra-headers
		(append `(("Authorization" . ,(concat "Bearer " token))
                          ("Accept" . "application/json"))
			(when payload '(("Content-Type" . "application/json")))
			headers))
               (url-request-data
		(and payload (encode-coding-string (json-encode payload) 'utf-8)))
               (url nil)
               (finished nil)
               response process timer)
          (cl-labels
              ((finish (value problem)
		 (unless finished
                   (setq finished t)
                   (when (timerp timer) (cancel-timer timer))
                   (setq emacsos-assist-web--requests
			 (delq response emacsos-assist-web--requests))
                   (funcall callback value problem))))
            (condition-case error
		(progn
                  (setq url (emacsos-assist-web--endpoint path))
                  (setq response
			(let ((url-mime-encoding-string "identity")
                                      (url-debug nil)
                                      (url-automatic-caching nil)
                                      (url-http-attempt-keepalives nil)
                                      (gnutls-trustfiles
                                       (emacsos-assist-web--trustfiles)))
                          (emacsos-assist-web--close-idle-origin-connections)
                          (url-retrieve
                           url
                           (lambda (_status)
                             (let (value problem)
                               (unwind-protect
                                   (condition-case parse-error
                                       (setq value
                                             (emacsos-assist-web--response-json
                                              (current-buffer) allow-status))
                                     (error
                                      (setq problem
                                            (error-message-string parse-error))))
				 (kill-buffer (current-buffer)))
                               (finish value problem)))
                           nil t t)))
                  (when (buffer-live-p response)
                    (with-current-buffer response
                      (setq-local url-max-redirections 0
                                  url-http-no-retry t
                                  url-debug nil
                                  url-automatic-caching nil))
                    (push response emacsos-assist-web--requests))
                  (setq process (and (buffer-live-p response)
                                     (get-buffer-process response)))
                  (setq timer
			(run-at-time
			 emacsos-assist-web-request-timeout nil
			 (lambda ()
                           (unless finished
                             (when (process-live-p process)
                               (set-process-filter process nil)
                               (set-process-sentinel process nil)
                               (delete-process process))
                             (when (buffer-live-p response) (kill-buffer response))
                             (finish nil "Assist Web request timed out")))))
		  (when (process-live-p process)
                    (let ((url-filter (process-filter process)))
                      (set-process-filter
                       process
                       (emacsos-assist-web--guarded-filter
			url-filter
			(lambda (active problem)
			  (set-process-filter active nil)
			  (set-process-sentinel active nil)
			  (when (process-live-p active) (delete-process active))
			  (when (buffer-live-p (process-buffer active))
                            (emacsos-assist-web--kill-buffer-later
                             (process-buffer active)))
			  (finish nil problem)))))))
              (error (finish nil (error-message-string error)))))))))))

(defun emacsos-assist-web--display-status (status)
  "Replace the visible STATUS without changing its durable state source."
  (when (and (markerp emacsos-assist-web--status-start)
             (marker-buffer emacsos-assist-web--status-start))
    (let ((inhibit-read-only t) (inhibit-modification-hooks t))
      (set-marker emacsos-assist-web--status-end
                  (emacsos-conversation-set-status
                   emacsos-assist-web--status-start emacsos-assist-web--status-end status)))))

(defun emacsos-assist-web--set-status (status)
  "Store and display STATUS without inventing transcript content."
  (setq emacsos-assist-web--stream-status status)
  (emacsos-assist-web--display-status status))

(defun emacsos-assist-web--set-unverified-status (status)
  "Store interruption STATUS while visibly distinguishing provisional text."
  (setq emacsos-assist-web--stream-status status)
  (emacsos-assist-web--display-status
   (format "unverified; refresh; %s" status)))

(defun emacsos-assist-web--set-assistant-status (status)
  "Replace the provisional assistant body with STATUS, keeping it read-only."
  (when (and (markerp emacsos-assist-web--assistant-start)
             (markerp emacsos-assist-web--assistant-end))
    (set-marker emacsos-assist-web--assistant-end
                (emacsos-conversation-replace-marked
                 emacsos-assist-web--assistant-start emacsos-assist-web--assistant-end
                 (format "[%s]\n" status)))))

(defun emacsos-assist-web--replace-empty-assistant-status (status)
  "Replace only an empty or queued provisional body with STATUS.

Streamed text is evidence the reader may need while refresh/replay recovers, so
interruption and truncation leave a nonempty body intact."
  (when (and (markerp emacsos-assist-web--assistant-start)
             (markerp emacsos-assist-web--assistant-end))
    (let ((body (buffer-substring-no-properties
                 emacsos-assist-web--assistant-start emacsos-assist-web--assistant-end)))
      (when (member body '("" "[queued]\n" "[working; live text unavailable]\n"))
        (emacsos-assist-web--set-assistant-status status)))))

(defun emacsos-assist-web--kill-buffer-later (buffer)
  "Kill BUFFER after the current URL process filter has returned."
  (run-at-time 0 nil
               (lambda (candidate)
                 (when (buffer-live-p candidate) (kill-buffer candidate)))
               buffer))

(defun emacsos-assist-web--stream-cleanup (&optional keep-pending no-render)
  "Release this buffer's event stream.

Retain retry identity when KEEP-PENDING is non-nil.  When NO-RENDER is non-nil,
do not ask the phone shell to redraw a dying buffer."
  (let ((process emacsos-assist-web--stream-process)
        (response emacsos-assist-web--stream-response))
    (cl-incf emacsos-assist-web--stream-generation)
    (when (timerp emacsos-assist-web--stream-header-timer)
      (cancel-timer emacsos-assist-web--stream-header-timer))
    (setq emacsos-assist-web--stream-process nil
          emacsos-assist-web--stream-response nil
          emacsos-assist-web--stream-body-marker nil
          emacsos-assist-web--stream-scan-marker nil
          emacsos-assist-web--stream-unconsumed-bytes nil
          emacsos-assist-web--stream-header-timer nil
          emacsos-assist-web--in-flight nil)
    (when (eq emacsos--assist-active-surface (current-buffer))
      (setq emacsos--assist-active-surface nil))
    (when (process-live-p process)
      (set-process-sentinel process nil)
      (delete-process process))
    ;; A terminal event is parsed inside RESPONSE.  Deferring its destruction
    ;; keeps the URL filter's marker update valid, then reclaims it promptly.
    (when (buffer-live-p response) (emacsos-assist-web--kill-buffer-later response))
    (unless keep-pending
      (setq emacsos-assist-web--pending-key nil
            emacsos-assist-web--submitted-text nil
            emacsos-assist-web--pending-accepted-p nil
            emacsos-assist-web--run-id nil
            emacsos-assist-web--stream-status nil))
    (when (and (not no-render) (fboundp 'emacsos--render-page))
      (emacsos--render-page))))

(defun emacsos-assist-web--buffer-killed ()
  "Release local active-stream ownership when this thread buffer is killed.

The canonical server Run continues independently; a later snapshot or reopen
observes its durable state."
  (when (timerp emacsos-assist-web--draft-save-timer)
    (cancel-timer emacsos-assist-web--draft-save-timer))
  (unwind-protect
      (emacsos-assist-web--save-draft)
    (emacsos-assist-web--stream-cleanup t t)))

(defun emacsos-assist-web--stream-finish (buffer)
  "Finish BUFFER's event observation and request its canonical transcript."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((completed-run-id emacsos-assist-web--run-id))
        ;; A terminal SSE is not the answer.  Keep the marker-scoped text raw
        ;; until the canonical snapshot has replaced this provisional region.
        (emacsos-assist-web--stream-cleanup t t)
        (emacsos-assist-web--set-status "reconciling")
        (emacsos-assist-web--save-draft)
        (emacsos-assist-web-refresh-thread buffer completed-run-id)))))

(defun emacsos-assist-web--stream-interrupted (buffer status)
  "Keep BUFFER's exact pending submission and visibly mark STATUS unverified."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (emacsos-assist-web--stream-cleanup t)
      (when (and (markerp emacsos-assist-web--assistant-start)
                 (markerp emacsos-assist-web--assistant-end))
        (emacsos-assist-web--replace-empty-assistant-status "unverified; refresh"))
      (emacsos-assist-web--set-unverified-status status)
      (emacsos-assist-web--save-draft)
      (message "%s. C-c C-a g refreshes; Send retries the same message."
               status))))

(defun emacsos-assist-web--thread-gone (buffer)
  "Release BUFFER after Assist confirms the observed thread was deleted."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (emacsos-assist-web--stream-cleanup nil)
      (setq emacsos-assist-web--thread-id nil
            emacsos-assist-web--snapshot nil
            ;; Keep partial text visible, but make the next Send create its
            ;; own pending region instead of streaming into this dead thread.
            emacsos-assist-web--pending-rendered-p nil
            emacsos-assist-web--assistant-start nil
            emacsos-assist-web--assistant-end nil
            emacsos-assist-web--stream-attempt nil
            emacsos-assist-web--stream-index 0
            ;; The next editable tail is now a locally recoverable new draft.
            emacsos-assist-web--draft-id "new-thread")
      (emacsos-assist-web--set-status "thread deleted; start a new thread")
      (emacsos-assist-web--save-draft)
      (message "Thread deleted; start a new thread."))))

(defun emacsos-assist-web--run-store-unavailable (buffer)
  "Keep BUFFER's accepted identity while operator repair restores observation."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (emacsos-assist-web--stream-cleanup t)
      (emacsos-assist-web--replace-empty-assistant-status
       "observation unavailable; operator repair required")
      (emacsos-assist-web--set-unverified-status
       "observation unavailable; operator repair required")
      (emacsos-assist-web--save-draft)
      (message "Assist observation unavailable; operator repair is required."))))

(defun emacsos-assist-web--finish-observation-response (target generation response)
  "Settle TARGET after RESPONSE closes without a completed SSE observation."
  (let ((unavailable (and (buffer-live-p response)
                          (emacsos-assist-web--run-store-unavailable-response-p response))))
    ;; url-http may run its final callback inside the last filter invocation.
    ;; Defer cleanup so an error event in that callback remains authoritative.
    (run-at-time
     0 nil
     (lambda (buffer expected-generation store-unavailable)
       (when (and (buffer-live-p buffer)
                  (with-current-buffer buffer
                    (= expected-generation emacsos-assist-web--stream-generation)))
         (if store-unavailable
             (emacsos-assist-web--run-store-unavailable buffer)
           (emacsos-assist-web--stream-interrupted
            buffer "observation disconnected"))))
     target generation unavailable)))

(defun emacsos-assist-web--stream-sentinel (url-sentinel target generation)
  "Run URL-SENTINEL; it owns final observation settlement when installed."
  (lambda (ended event)
    (if (functionp url-sentinel)
        ;; url-retrieve invokes our completion callback from this sentinel.  That
        ;; callback defers its verdict so its final filter can still deliver a
        ;; terminal event or recognize the sanitized 503 response.
        (funcall url-sentinel ended event)
      (when (and (not (process-live-p ended)) (buffer-live-p target))
        (with-current-buffer target
          (when (and (= generation emacsos-assist-web--stream-generation)
                     (eq ended emacsos-assist-web--stream-process))
            (emacsos-assist-web--stream-interrupted
             target "observation disconnected")))))))

(defun emacsos-assist-web--dispatch-event (target event data)
  "Handle one bounded SSE EVENT with JSON DATA for TARGET."
  (when (buffer-live-p target)
    (with-current-buffer target
      (cond
       ((equal event "status")
        (condition-case nil
            (let ((status (json-parse-string data :object-type 'alist)))
              (emacsos-assist-web--set-status
               (or (alist-get 'status status) "working")))
          (error nil)))
       ((equal event "assistant-reset")
        (condition-case nil
            (let ((value (json-parse-string data :object-type 'alist)))
              (emacsos-assist-web--reset-assistant (alist-get 'attempt value)))
          (error (emacsos-assist-web--stream-interrupted target "invalid Assist reset"))))
       ((equal event "assistant-delta")
        (condition-case nil
            (let ((value (json-parse-string data :object-type 'alist)))
              (emacsos-assist-web--append-delta (alist-get 'attempt value)
                                                (alist-get 'index value)
                                                (alist-get 'text value)))
          (error (emacsos-assist-web--stream-interrupted target "invalid Assist delta"))))
       ((equal event "assistant-truncated")
        (emacsos-assist-web--replace-empty-assistant-status
         "live text truncated; waiting for final")
        (emacsos-assist-web--set-status "live text truncated; waiting for final"))
       ((equal event "terminal") (emacsos-assist-web--stream-finish target))
       ((equal event "closed-set")
        (condition-case nil
            (when (equal (alist-get 'reason (json-parse-string data :object-type 'alist))
                         "thread-gone")
              (emacsos-assist-web--thread-gone target))
          (error (emacsos-assist-web--stream-interrupted target "invalid Assist closure"))))
       ((equal event "error")
        (condition-case nil
            (if (equal (alist-get 'detail (json-parse-string data :object-type 'alist))
                       "run-store-unavailable")
                (emacsos-assist-web--run-store-unavailable target)
              (emacsos-assist-web--stream-interrupted target "observation interrupted"))
          (error (emacsos-assist-web--stream-interrupted target "invalid Assist error"))))))))

(defun emacsos-assist-web--reset-assistant (attempt)
  "Clear only the provisional assistant body for ATTEMPT."
  (unless (integerp attempt) (error "invalid stream attempt"))
  (setq emacsos-assist-web--stream-attempt attempt
        emacsos-assist-web--stream-index 0)
  (when (and (markerp emacsos-assist-web--assistant-start)
             (markerp emacsos-assist-web--assistant-end))
    (set-marker emacsos-assist-web--assistant-end
                (emacsos-conversation-reset-assistant
                 emacsos-assist-web--assistant-start emacsos-assist-web--assistant-end))))

(defun emacsos-assist-web--append-delta (attempt index text)
  "Append the next bounded delta for ATTEMPT/INDEX to this buffer only."
  (unless (and (integerp attempt) (integerp index) (stringp text)
               (<= (string-bytes text) (* 16 1024)))
    (error "invalid Assist delta"))
  (cond
   ((not (integerp emacsos-assist-web--stream-attempt))
    (emacsos-assist-web--stream-interrupted
     (current-buffer) "Assist stream is missing its reset; refresh to reconcile"))
   ((< attempt emacsos-assist-web--stream-attempt) nil)
   ((or (not (equal attempt emacsos-assist-web--stream-attempt))
        (/= index (1+ emacsos-assist-web--stream-index)))
    (emacsos-assist-web--stream-interrupted
     (current-buffer) "Assist stream has a gap; refresh to reconcile"))
   ((and (markerp emacsos-assist-web--assistant-end)
         (marker-buffer emacsos-assist-web--assistant-end))
    (set-marker emacsos-assist-web--assistant-end
                (emacsos-conversation-append-delta
                 emacsos-assist-web--assistant-end text))
      (setq emacsos-assist-web--stream-index index)
      (emacsos-assist-web--set-status "working"))))

(defun emacsos-assist-web--drain-events (target generation &optional received-bytes)
  "Consume new complete SSE records for TARGET without rescanning a suffix.
RECEIVED-BYTES is the raw size newly appended after the first parsed response."
  (unless (markerp emacsos-assist-web--stream-body-marker)
    (setq-local emacsos-assist-web--stream-body-marker
                (copy-marker (marker-position url-http-end-of-headers) nil)
                emacsos-assist-web--stream-scan-marker
                (copy-marker (marker-position url-http-end-of-headers) nil)))
  (let* ((marker emacsos-assist-web--stream-body-marker)
         (scan-marker emacsos-assist-web--stream-scan-marker)
         (start (marker-position marker))
         (too-large nil))
    ;; The first callback includes headers.  Thereafter the process filter's
    ;; byte count lets us enforce the incomplete-record cap without copying or
    ;; rescanning the whole retained suffix for every tiny callback.
    (if (integerp emacsos-assist-web--stream-unconsumed-bytes)
        (cl-incf emacsos-assist-web--stream-unconsumed-bytes (or received-bytes 0))
      (setq-local emacsos-assist-web--stream-unconsumed-bytes
                  (string-bytes (buffer-substring-no-properties start (point-max)))))
    ;; url-http can split any byte sequence across callbacks.  Resume at the
    ;; final possible delimiter start, so each retained character is scanned
    ;; at most once (apart from that one boundary character).
    (goto-char (marker-position scan-marker))
    (while (and (not too-large) (search-forward "\n\n" nil t))
      (let* ((record-end (point))
             (event nil) (data nil)
             (record (buffer-substring-no-properties start (- record-end 2))))
        (if (> (string-bytes record) emacsos-assist-web-max-event-bytes)
            (progn
              (setq too-large t)
              (when (and (buffer-live-p target)
                         (with-current-buffer target
                           (= generation emacsos-assist-web--stream-generation)))
                (emacsos-assist-web--stream-interrupted
                 target "Assist event is too large")))
          (dolist (line (split-string record "\n" t))
            (cond
             ((string-prefix-p "event: " line) (setq event (substring line 7)))
             ((string-prefix-p "data: " line) (setq data (substring line 6)))))
          (when (and event (buffer-live-p target)
                     (with-current-buffer target
                       (= generation emacsos-assist-web--stream-generation)))
            (emacsos-assist-web--dispatch-event target event (or data "")))
          (cl-decf emacsos-assist-web--stream-unconsumed-bytes
                   (+ (string-bytes record) 2))
          (delete-region start record-end)
          (set-marker marker start)
          (set-marker scan-marker start)
          (goto-char start))))
    (when too-large
      (delete-region start (point-max))
      (set-marker scan-marker start)
      (setq-local emacsos-assist-web--stream-unconsumed-bytes 0))
    (unless too-large
      ;; Retain only an incomplete final record.  Otherwise a long healthy
      ;; stream would still accumulate every already-consumed event.
      (set-marker scan-marker (max start (1- (point-max)))))
    (when (> emacsos-assist-web--stream-unconsumed-bytes
             emacsos-assist-web-max-event-bytes)
      (delete-region start (point-max))
      (set-marker scan-marker start)
      (setq-local emacsos-assist-web--stream-unconsumed-bytes 0)
      (when (and (buffer-live-p target)
                 (with-current-buffer target
                   (= generation emacsos-assist-web--stream-generation)))
        (emacsos-assist-web--stream-interrupted target "Assist event is too large")))))

(defun emacsos-assist-web--event-filter (url-filter target generation)
  "Wrap URL-FILTER and dispatch SSE records to TARGET for GENERATION."
  (lambda (process bytes)
    ;; The stock filter may detach PROCESS from its buffer on the final chunk.
    ;; Retain the response first so a terminal event in that chunk is not lost.
    (let ((response (process-buffer process)))
      (when (functionp url-filter) (funcall url-filter process bytes))
      (when (buffer-live-p response)
        (with-current-buffer response
          (when (and (boundp 'url-http-end-of-headers) url-http-end-of-headers)
            (if (not (and (integerp url-http-response-status)
                          (<= 200 url-http-response-status 299)
                          (stringp url-http-content-type)
                          (string-match-p "\\`text/event-stream\\(?:[ ;]\\|\\'\\)"
                                          (downcase url-http-content-type))))
                (when (and (buffer-live-p target)
                         (with-current-buffer target
                           (= generation emacsos-assist-web--stream-generation)))
                  ;; A 503 body can distinguish unavailable durable observation
                  ;; only after url-http has received it all.  Its completion
                  ;; callback below preserves the accepted identity and reports
                  ;; operator repair rather than a generic retry.
                  (unless (= url-http-response-status 503)
                    (emacsos-assist-web--stream-interrupted
                     target "Assist observation was rejected")))
              (when (and (buffer-live-p target)
                         (with-current-buffer target
                           (= generation emacsos-assist-web--stream-generation)))
                (with-current-buffer target
                  (when (timerp emacsos-assist-web--stream-header-timer)
                    (cancel-timer emacsos-assist-web--stream-header-timer)
                    (setq emacsos-assist-web--stream-header-timer nil))))
              (emacsos-assist-web--drain-events
               target generation (string-bytes bytes)))))))))

(defun emacsos-assist-web--observe-run (buffer)
  "Open BUFFER's authenticated status stream for its current run.

Response headers and each individual event are bounded; the stream remains
open until the run reaches a terminal state, awaits approval, or observation is
interrupted."
  (let ((token (emacsos-assist-web--read-token)))
    (if (not (emacsos-assist-web--safe-token-p token))
        (emacsos-assist-web--stream-interrupted buffer "token missing or invalid")
      (with-current-buffer buffer
        (condition-case error
            (let* ((generation (cl-incf emacsos-assist-web--stream-generation))
                   (thread-id (emacsos-assist-web--require-id emacsos-assist-web--thread-id))
                   (run-id (emacsos-assist-web--require-id emacsos-assist-web--run-id))
                   (url-request-method "GET")
                   (url-request-extra-headers
                    `(("Authorization" . ,(concat "Bearer " token))
                      ("Accept" . "text/event-stream")))
                   (response
                    (let ((url-mime-encoding-string "identity")
                          (url-debug nil)
                          (url-automatic-caching nil)
                          (url-http-attempt-keepalives nil)
                          (gnutls-trustfiles
                           (emacsos-assist-web--trustfiles)))
                      (emacsos-assist-web--close-idle-origin-connections)
                      (url-retrieve
                       (emacsos-assist-web--endpoint
                        (format "threads/%s/runs/%s/events" thread-id run-id))
                       (lambda (_status)
                         ;; url-http can activate this callback from inside its
                         ;; final filter call.  Let our wrapper drain that same
                         ;; chunk before deciding that no terminal event arrived.
                         (emacsos-assist-web--finish-observation-response
                          buffer generation (current-buffer)))
                       nil t t)))
                   (process (and (buffer-live-p response) (get-buffer-process response))))
              (if (not process)
                  (emacsos-assist-web--stream-interrupted buffer "observation unavailable")
                (with-current-buffer response
                  (setq-local url-max-redirections 0
                              url-http-no-retry t
                              url-debug nil
                              url-automatic-caching nil))
                (setq emacsos-assist-web--stream-response response
                      emacsos-assist-web--stream-process process
                      emacsos-assist-web--stream-header-timer
                      (run-at-time
                       emacsos-assist-web-request-timeout nil
                       (lambda ()
                         (when (and (buffer-live-p buffer)
                                    (with-current-buffer buffer
                                      (and (= generation emacsos-assist-web--stream-generation)
                                           (buffer-live-p emacsos-assist-web--stream-response)
                                           (with-current-buffer emacsos-assist-web--stream-response
                                             (not (and (boundp 'url-http-end-of-headers)
                                                       url-http-end-of-headers))))))
                           (emacsos-assist-web--stream-interrupted
                            buffer "Assist observation timed out")))))
                (let* ((url-filter (process-filter process))
                       (event-filter
                        (emacsos-assist-web--event-filter url-filter buffer generation)))
                  (set-process-filter
                   process
                   (emacsos-assist-web--guarded-filter
                    event-filter
                    (lambda (active problem)
                      (if (and (buffer-live-p buffer)
                               (with-current-buffer buffer
                                 (and (= generation emacsos-assist-web--stream-generation)
                                      (eq active emacsos-assist-web--stream-process))))
                          (emacsos-assist-web--stream-interrupted buffer problem)
                        (when (process-live-p active) (delete-process active))))
                    t)))
                (set-process-sentinel
                 process
                 (emacsos-assist-web--stream-sentinel
                  (process-sentinel process) buffer generation))))
          (error
           (emacsos-assist-web--stream-interrupted buffer
                                                  (error-message-string error))))))))

(defun emacsos-assist-web--thread-label (thread &optional suffix)
  "Display THREAD in the requested thread-buffer format with optional SUFFIX."
  (format "*assist %s - %s%s*"
          (alist-get 'description thread)
          (or (alist-get 'repo_label thread) "No repository")
          (or suffix "")))

(defun emacsos-assist-web--completion-records ()
  "Return completion records with identity kept separate from display text."
  (let ((counts (make-hash-table :test #'equal)))
    (dolist (thread emacsos-assist-web--catalog)
      (let ((label (emacsos-assist-web--thread-label thread)))
        (puthash label (1+ (gethash label counts 0)) counts)))
    (mapcar
     (lambda (thread)
       (let* ((label (emacsos-assist-web--thread-label thread))
              (identity-label
               (if (> (gethash label counts) 1)
                   (emacsos-assist-web--thread-label
                    thread
                    (format " [%s]"
                            (emacsos-assist-web--require-id
                             (alist-get 'id thread))))
                 label))
              (state (or (alist-get 'status thread) "unknown"))
              (display (format "%s [%s%s]" identity-label state
                               (if emacsos-assist-web--catalog-stale ", cached" ""))))
         (list :display display :thread thread
               :search (downcase (concat (or (alist-get 'search_description thread) "")
                                         " " (alist-get 'description thread)
                                         " " (or (alist-get 'repo_label thread) "")
                                         " " state)))))
     emacsos-assist-web--catalog)))

(defun emacsos-assist-web--completion-table (records)
  "Build a completion table from RECORDS with server search-text matching."
  (lambda (string predicate action)
    (if (eq action 'metadata)
        '(metadata (category . emacsos-assist-web-thread))
      (let* ((needle (downcase string))
             (matches
              (seq-filter
               (lambda (record)
                 (and (or (equal string (plist-get record :display))
                          (string-match-p (regexp-quote needle)
                                          (plist-get record :search)))
                      (or (not predicate)
                          (funcall predicate (plist-get record :display)))))
               records))
             (displays (mapcar (lambda (record) (plist-get record :display))
                               matches)))
        (cond
         ((eq action t) displays)
         ((eq action 'lambda) (and (member string displays) t))
         ((member string displays) t)
         ((= (length displays) 1) (car displays))
         (displays string))))))

(defun emacsos-assist-web--record-for-display (display records)
  "Return from RECORDS the completion record selected by DISPLAY."
  (seq-find (lambda (record) (equal display (plist-get record :display))) records))

(defun emacsos-assist-web--labeled-records (items identity-key)
  "Return completion records for ITEMS, disambiguated by IDENTITY-KEY.

The human label remains primary.  Only duplicate labels expose their full
opaque identity, so selecting a display string always selects one exact item."
  (let ((counts (make-hash-table :test #'equal)))
    (dolist (item items)
      (let ((label (alist-get 'label item)))
        (puthash label (1+ (gethash label counts 0)) counts)))
    (mapcar
     (lambda (item)
       (let* ((label (alist-get 'label item))
              (identity (alist-get identity-key item)))
         (unless (and (stringp label) (stringp identity)
                      (not (string-empty-p identity)))
           (error "Assist Web returned an invalid catalog choice"))
         (list :display (if (> (gethash label counts) 1)
                            (format "%s [%s]" label identity)
                          label)
               :item item)))
     items)))

(defun emacsos-assist-web--select-labeled-item
    (prompt items identity-key saved-identity)
  "Select one of ITEMS by PROMPT while retaining its IDENTITY-KEY.

SAVED-IDENTITY reuses a still-present choice without prompting."
  (let* ((records (emacsos-assist-web--labeled-records items identity-key))
         (saved
          (and saved-identity
               (seq-find
                (lambda (record)
                  (equal saved-identity
                         (alist-get identity-key (plist-get record :item))))
                records))))
    (or saved
        (and records
             (let ((choice
                    (completing-read
                     prompt
                     (mapcar (lambda (record) (plist-get record :display)) records)
                     nil t nil nil (plist-get (car records) :display))))
               (emacsos-assist-web--record-for-display choice records))))))

(defun emacsos-assist-web--thread-buffer (thread-id)
  "Return the live Assist Web buffer whose canonical id is THREAD-ID."
  (seq-find
   (lambda (buffer)
     (and (buffer-live-p buffer)
          (with-current-buffer buffer
            (and (derived-mode-p 'emacsos-assist-web-mode)
                 (equal emacsos-assist-web--thread-id thread-id)))))
   (buffer-list)))

(defun emacsos-assist-web--show-notice (name text)
  "Show a small visible non-blocking notice buffer named NAME with TEXT."
  (let ((buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (special-mode)
        (erase-buffer)
        (insert text "\n")))
    (switch-to-buffer buffer)
    buffer))

(defun emacsos-assist-web--prompt-start ()
  "Return the editable region's start in the current web-thread buffer."
  (and (markerp emacsos-assist-web--input-marker)
       (marker-buffer emacsos-assist-web--input-marker)
       (marker-position emacsos-assist-web--input-marker)))

(defun emacsos-assist-web--input ()
  "Return current user input from the web-thread prompt."
  (let ((start (emacsos-assist-web--prompt-start)))
    (and start (buffer-substring-no-properties start (point-max)))))

(defun emacsos-assist-web--replace-input (text)
  "Replace this buffer's editable prompt with TEXT without firing draft hooks."
  (when-let ((start (emacsos-assist-web--prompt-start)))
    (let ((inhibit-read-only t)
          (inhibit-modification-hooks t))
      (delete-region start (point-max))
      (goto-char start)
      (insert text))))

(defun emacsos-assist-web--write-prompt ()
  "Append the one editable prompt after a rendered transcript."
  (let ((before (point)))
    (setq emacsos-assist-web--prompt-marker (copy-marker before nil))
    (insert emacsos-assist-web--prompt)
    (add-text-properties before (point)
                         '(read-only t front-sticky t rear-nonsticky t))
    (setq emacsos-assist-web--input-marker (copy-marker (point) nil))))

(defun emacsos-assist-web--anchor-at (position)
  "Describe POSITION in the current rendered thread using logical content."
  (let ((input-start (emacsos-assist-web--prompt-start))
        (position (max (point-min) (min position (point-max)))))
    (cond
     ((and input-start (>= position input-start))
      (list :kind 'input :offset (- position input-start)))
     ((< position (point-max))
      (let ((identity (get-text-property
                       position 'emacsos-assist-web-message-id)))
        (if identity
            (let ((start position))
              (while (and (> start (point-min))
                          (equal identity
                                 (get-text-property
                                  (1- start)
                                  'emacsos-assist-web-message-id)))
                (setq start (previous-single-property-change
                             start 'emacsos-assist-web-message-id nil
                             (point-min))))
              (list :kind 'message :id identity
                    :offset (- position start)
                    :fallback position))
          (list :kind 'absolute :position position))))
     (t (list :kind 'absolute :position position)))))

(defun emacsos-assist-web--resolve-anchor (anchor)
  "Resolve logical ANCHOR in the current rendered thread."
  (pcase (plist-get anchor :kind)
    ('input
     (let ((start (or (emacsos-assist-web--prompt-start) (point-max))))
       (min (point-max) (+ start (plist-get anchor :offset)))))
    ('message
     (if-let ((start
               (let ((position (point-min)) found)
                 ;; Property search primitives compare string values by
                 ;; identity.  Snapshot redraws produce equal, newly allocated
                 ;; id strings, so walk the bounded property runs explicitly.
                 (while (and (< position (point-max)) (not found))
                   (when (equal (get-text-property
                                 position 'emacsos-assist-web-message-id)
                                (plist-get anchor :id))
                     (setq found position))
                   (unless found
                     (setq position
                           (next-single-property-change
                            position 'emacsos-assist-web-message-id nil
                            (point-max)))))
                 found)))
         (let ((end (or (next-single-property-change
                         start 'emacsos-assist-web-message-id nil (point-max))
                        (point-max))))
           ;; END is exclusive.  Clamping to END can silently move the anchor
           ;; onto the following message when a refreshed record gets shorter.
           (min (max start (1- end))
                (+ start (plist-get anchor :offset))))
       (max (point-min)
            (min (or (plist-get anchor :fallback) (point-min))
                 (point-max)))))
    (_
     (max (point-min)
          (min (or (plist-get anchor :position) (point-min))
               (point-max))))))

(defun emacsos-assist-web--capture-render-state ()
  "Capture point and the one displayed phone window before a redraw."
  (when (and (markerp emacsos-assist-web--input-marker)
             (marker-buffer emacsos-assist-web--input-marker))
    (let ((window (get-buffer-window (current-buffer))))
      (list :point (emacsos-assist-web--anchor-at (point))
            :window window
            :window-point (and window
                               (emacsos-assist-web--anchor-at
                                (window-point window)))
            :window-start (and window
                               (emacsos-assist-web--anchor-at
                                (window-start window)))))))

(defun emacsos-assist-web--restore-render-state (state)
  "Restore logical point and phone viewport from STATE after a redraw."
  (if (not state)
      (goto-char (point-max))
    (let ((window (plist-get state :window)))
      (when (and window (window-live-p window)
                 (eq (window-buffer window) (current-buffer)))
        (set-window-point
         window
         (emacsos-assist-web--resolve-anchor
          (plist-get state :window-point)))
        (set-window-start
         window
         (emacsos-assist-web--resolve-anchor
          (plist-get state :window-start)) t))
      (goto-char (emacsos-assist-web--resolve-anchor
                  (plist-get state :point))))))

(defun emacsos-assist-web--retain-loaded-history (fresh previous)
  "Return FRESH with canonical messages already loaded in PREVIOUS retained.

Thread messages are append-only.  A fresh recent page replaces records with
matching ids; older records no longer present in that bounded page stay ahead
of it, together with the oldest pagination cursor already reached."
  (if (not previous)
      fresh
    (let ((fresh-by-id (make-hash-table :test #'equal))
          (older nil)
          (has-old-only nil)
          (result (copy-tree fresh)))
      (dolist (message (alist-get 'messages fresh))
        (puthash (alist-get 'id message) message fresh-by-id))
      (dolist (message (alist-get 'messages previous))
        (unless (gethash (alist-get 'id message) fresh-by-id)
          (setq has-old-only t)
          (push message older)))
      (setf (alist-get 'messages result)
            (append (nreverse older) (alist-get 'messages fresh)))
      (when has-old-only
        (setf (alist-get 'has_older_messages result)
              (alist-get 'has_older_messages previous)
              (alist-get 'next_before result)
              (alist-get 'next_before previous)))
      result)))

(defun emacsos-assist-web--render (snapshot &optional stale)
  "Render SNAPSHOT in the current remote-thread buffer, marked STALE if needed."
  (let ((inhibit-read-only t)
        (inhibit-modification-hooks t)
        (draft (emacsos-assist-web--input))
        (render-state (emacsos-assist-web--capture-render-state)))
    (emacsos-assist-web--require-snapshot snapshot emacsos-assist-web--thread-id)
    (setq snapshot
          (emacsos-assist-web--retain-loaded-history
           snapshot emacsos-assist-web--snapshot))
    (let ((thread (alist-get 'thread snapshot))
          (presentation-bytes
           (cl-loop for message in (alist-get 'messages snapshot)
                    sum (string-bytes (alist-get 'text message)))))
      (let ((returned-id
             (emacsos-assist-web--require-id (alist-get 'id thread))))
        (when (and emacsos-assist-web--thread-id
                   (not (equal returned-id emacsos-assist-web--thread-id)))
          (error "Assist Web snapshot identity does not match this buffer"))
        (setq emacsos-assist-web--thread-id returned-id))
      (setq emacsos-assist-web--snapshot snapshot
            emacsos-assist-web--pending-rendered-p nil)
      (erase-buffer)
      (let ((transcript-start (point)))
        (insert (format "%s%s\n"
                        (emacsos-assist-web--thread-label
                         `((description . ,(alist-get 'description thread))
                           (repo_label . ,(alist-get
                                           'repo_label
                                           (alist-get 'workspace thread)))))
                        (if stale " [cached]" "")))
        (setq emacsos-assist-web--status-start (copy-marker (point) nil))
        (insert (format "[%s%s]" (or emacsos-assist-web--stream-status
                                     (alist-get 'status thread))
                        (if-let ((error (alist-get 'error thread)))
                            (concat ": " error) "")))
        (setq emacsos-assist-web--status-end (copy-marker (point) nil))
        (insert "\n\n")
        (let ((emacsos--chat-presentation-max-bytes
               (if (<= presentation-bytes emacsos--chat-presentation-max-bytes)
                   emacsos--chat-presentation-max-bytes
                 0)))
          (dolist (message (alist-get 'messages snapshot))
            (let* ((message-start (point))
                   (role (if (equal (alist-get 'role message) "user")
                             'user 'assistant)))
              (insert (if (eq role 'user) "you> " "bot> "))
              (let ((body-start (point)))
                (insert (alist-get 'text message))
                (emacsos--chat-present-message
                 message-start body-start (point) role))
              (when (and emacsos-assist-web--pending-accepted-p
                         (equal (alist-get 'role message) "user")
                         (equal (alist-get 'state message) "incomplete")
                         (equal (alist-get 'text message)
                                emacsos-assist-web--submitted-text))
                (setq emacsos-assist-web--pending-rendered-p t)
                ;; The canonical snapshot has already rendered the user turn,
                ;; so recreate only the provisional assistant insertion range.
                ;; A resumed SSE reset/delta must have these markers to render.
                (let ((assistant-start (point)))
                  (insert "\n\nbot> ")
                  (let ((body-start (point)))
                    (insert "[queued]\n")
                    (pcase-let ((`(,start . ,end)
                                 (emacsos-conversation-begin-assistant
                                  body-start (point))))
                      (setq emacsos-assist-web--assistant-start start
                            emacsos-assist-web--assistant-end end))
                    (emacsos--chat-present-message assistant-start body-start
                                                   (point) 'assistant))))
              (insert "\n\n")
              (add-text-properties
               message-start (point)
               `(emacsos-assist-web-message-id ,(alist-get 'id message)
                 rear-nonsticky t)))))
        (add-text-properties transcript-start (point)
                             '(read-only t front-sticky t rear-nonsticky t))
        (emacsos-assist-web--write-prompt)
        (if draft (insert draft) (emacsos-assist-web--restore-draft))
        (emacsos-assist-web--restore-render-state render-state)
        (setq buffer-read-only nil)
        (set-buffer-modified-p nil)
        (emacsos-assist-web--save-draft)))))

(defun emacsos-assist-web--snapshot-cache-name (tid)
  "Return the bounded per-thread snapshot cache filename for TID."
  (concat "threads/" (emacsos-assist-web--require-id tid) ".json"))

(defun emacsos-assist-web--draft-cache-name ()
  "Return the private cache name for this thread or local draft buffer."
  (when-let ((identity (or (and emacsos-assist-web--thread-id
                                (emacsos-assist-web--require-id
                                 emacsos-assist-web--thread-id))
                           (and emacsos-assist-web--draft-id
                                (emacsos-assist-web--require-id
                                 emacsos-assist-web--draft-id)))))
    (concat "drafts/" identity ".json")))

(defun emacsos-assist-web--save-draft ()
  "Persist the current editable tail and retry identity, if this buffer has one.

Return non-nil on success or when this buffer has no draft identity."
  (if-let ((name (emacsos-assist-web--draft-cache-name)))
      (emacsos-assist-web--try-write-cache
       name `((text . ,(or (emacsos-assist-web--input) ""))
              (pending_key . ,emacsos-assist-web--pending-key)
              (submitted_text . ,emacsos-assist-web--submitted-text)
              (pending_accepted . ,emacsos-assist-web--pending-accepted-p)
              (run_id . ,emacsos-assist-web--run-id)
              (repo_key . ,emacsos-assist-web--draft-repository)
              (harness . ,emacsos-assist-web--draft-harness)))
    t))

(defun emacsos-assist-web--after-change (&rest _)
  "Debounce local draft persistence after a user edit."
  (when (and (derived-mode-p 'emacsos-assist-web-mode)
             (not inhibit-modification-hooks))
    (when (and (not emacsos-assist-web--in-flight)
               emacsos-assist-web--pending-key
               (not (equal (emacsos-assist-web--input)
                           emacsos-assist-web--submitted-text)))
      (setq emacsos-assist-web--pending-key nil
            emacsos-assist-web--submitted-text nil
            emacsos-assist-web--pending-accepted-p nil
            emacsos-assist-web--run-id nil
            ;; The next distinct Send must create its own provisional region,
            ;; not stream into the failed submission's old markers.
            emacsos-assist-web--pending-rendered-p nil
            emacsos-assist-web--stream-status nil)
      (when emacsos-assist-web--status-start
        (emacsos-assist-web--display-status
         (if emacsos-assist-web--thread-id
             (or (alist-get 'status (alist-get 'thread emacsos-assist-web--snapshot))
                 "ready")
           "local draft"))))
    (when (timerp emacsos-assist-web--draft-save-timer)
      (cancel-timer emacsos-assist-web--draft-save-timer))
    (setq emacsos-assist-web--draft-save-timer
          (run-with-idle-timer
           0.5 nil
           (lambda (buffer)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (setq emacsos-assist-web--draft-save-timer nil)
                 (emacsos-assist-web--save-draft))))
           (current-buffer)))))

(defun emacsos-assist-web--resume-accepted-run ()
  "Resume the exact accepted Run saved in this buffer's draft cache.

The exact Run status tells whether this saved submission is still active.
That durable identity avoids both a false duplicate after a crash and
suppressing a genuine repeated submission."
  (when (and emacsos-assist-web--thread-id emacsos-assist-web--run-id)
    (let ((buffer (current-buffer)))
      (if (and emacsos--assist-active-surface
               (not (eq emacsos--assist-active-surface buffer)))
          ;; A recovered durable retry may wait, but it must never steal the
          ;; phone-wide stream owner from an open local or canonical chat.
          (emacsos-assist-web--set-unverified-status
           "another conversation is active; Send re-observes")
        (let* ((tid (emacsos-assist-web--require-id emacsos-assist-web--thread-id))
               (run-id (emacsos-assist-web--require-id emacsos-assist-web--run-id))
               (generation (cl-incf emacsos-assist-web--send-generation)))
      (setq emacsos-assist-web--in-flight t
            emacsos--assist-active-surface buffer)
      (emacsos-assist-web--request
       "GET" (format "threads/%s/runs/%s" tid run-id) nil
       (lambda (value error)
         (when (and (buffer-live-p buffer)
                    (= generation emacsos-assist-web--send-generation))
           (with-current-buffer buffer
             (if error
                 (if (equal error "Assist Web run store is unavailable")
                     (emacsos-assist-web--run-store-unavailable buffer)
                   (unless emacsos-assist-web--pending-rendered-p
                     (emacsos-assist-web--append-pending
                      emacsos-assist-web--submitted-text))
                   (emacsos-assist-web--stream-interrupted
                    buffer "observation interrupted"))
               (condition-case problem
                   (let ((status (alist-get 'status value)))
                     (unless (stringp status) (error "invalid Assist run status"))
                     (cond
                      ((member status '("pending" "running" "transitioning"))
                       (unless emacsos-assist-web--pending-rendered-p
                         (emacsos-assist-web--append-pending
                          emacsos-assist-web--submitted-text))
                       (emacsos-assist-web--set-status status)
                       (emacsos-assist-web--save-draft)
                       (emacsos-assist-web--observe-run buffer))
                      ((equal status "awaiting_approval")
                       ;; It ends this observer but remains a durable Run until
                       ;; the canonical refresh has made its approval state visible.
                       (emacsos-assist-web--stream-finish buffer))
                      ((member status '("success" "error" "timeout" "interrupted"
                                       "cancelled"))
                       (setq emacsos-assist-web--pending-key nil
                             emacsos-assist-web--submitted-text nil
                             emacsos-assist-web--pending-accepted-p nil
                             emacsos-assist-web--run-id nil
                             emacsos-assist-web--stream-status nil
                             emacsos-assist-web--in-flight nil)
                       (when (eq emacsos--assist-active-surface buffer)
                         (setq emacsos--assist-active-surface nil))
                       (emacsos-assist-web--save-draft)
                       (emacsos-assist-web-refresh-thread buffer))
                      (t
                       (unless emacsos-assist-web--pending-rendered-p
                         (emacsos-assist-web--append-pending
                          emacsos-assist-web--submitted-text))
                       (emacsos-assist-web--stream-interrupted
                        buffer "invalid Assist run status"))))
                 (error
                  (unless emacsos-assist-web--pending-rendered-p
                  (emacsos-assist-web--append-pending
                     emacsos-assist-web--submitted-text))
                  (emacsos-assist-web--stream-interrupted
                   buffer (error-message-string problem))))))))))))))

(defun emacsos-assist-web--restore-draft ()
  "Restore this thread's local tail and any accepted, unobserved submission."
  (when-let* ((name (emacsos-assist-web--draft-cache-name))
              (draft (emacsos-assist-web--read-cache name)))
    (let ((key (alist-get 'pending_key draft))
          (submitted (alist-get 'submitted_text draft))
          (run-id (alist-get 'run_id draft))
          (text (alist-get 'text draft)))
      (if (and (stringp key)
               (string-match-p emacsos-assist-web--idempotency-regexp key)
               (stringp submitted))
          (setq emacsos-assist-web--pending-key key
                emacsos-assist-web--submitted-text submitted
                emacsos-assist-web--pending-accepted-p
                (and (alist-get 'pending_accepted draft) t)
                emacsos-assist-web--run-id
                (and (stringp run-id)
                     (string-match-p emacsos-assist-web--id-regexp run-id)
                     run-id))
        (setq emacsos-assist-web--pending-key nil
              emacsos-assist-web--submitted-text nil
              emacsos-assist-web--pending-accepted-p nil
              emacsos-assist-web--run-id nil))
      (if emacsos-assist-web--pending-accepted-p
          (progn
            (if emacsos-assist-web--run-id
                (emacsos-assist-web--resume-accepted-run)
              (unless emacsos-assist-web--pending-rendered-p
                (emacsos-assist-web--append-pending submitted))
              (emacsos-assist-web--set-status
               "observation interrupted; C-c C-a g refreshes"))
            ;; A crash can leave the accepted submission in the saved editable
            ;; tail even though the provisional rendering is restored above.
            (when (and (stringp text)
                       (not (equal text submitted)))
              (insert text)))
        (when (stringp text) (insert text))))))

(defun emacsos-assist-web--show-thread (thread)
  "Select THREAD's dedicated buffer and refresh it unless a send is active."
  (let* ((name (emacsos-assist-web--thread-label thread))
         (tid (emacsos-assist-web--require-id (alist-get 'id thread)))
         ;; The human label remains in the rendered header.  The opaque suffix
         ;; makes the Emacs buffer identity one-to-one even for duplicate titles.
         (existing (emacsos-assist-web--thread-buffer tid))
         (buffer (or existing (get-buffer-create (format "%s <%s>" name tid)))))
    (with-current-buffer buffer
      (unless existing
        (emacsos-assist-web-mode))
      (setq emacsos-assist-web--thread-id tid)
      (unless existing
        (if-let ((cached (emacsos-assist-web--read-cache
                          (emacsos-assist-web--snapshot-cache-name tid))))
            (condition-case nil
                (emacsos-assist-web--render cached t)
              (error nil))
          (emacsos-assist-web--render
           `((thread . ((id . ,tid)
                        (description . ,(alist-get 'description thread))
                        (status . "loading")
                        (workspace . ((repo_label . ,(alist-get 'repo_label thread))))))
             (messages . nil))
           nil)
          ;; The placeholder makes the buffer useful while offline without
          ;; claiming that a canonical transcript was cached.
          (setq emacsos-assist-web--snapshot nil)))
    (switch-to-buffer buffer)
    (unless (with-current-buffer buffer emacsos-assist-web--in-flight)
      (emacsos-assist-web-refresh-thread buffer)))))

(defun emacsos-assist-web-open-thread ()
  "Choose and open one cached Assist Web thread without a network wait."
  (interactive)
  (emacsos-assist-web--load-catalog)
  (if (not emacsos-assist-web--catalog-loaded-p)
      (progn
        (emacsos-assist-web--show-notice
         "*assist Threads*" "Loading Assist threads…")
        (emacsos-assist-web-refresh-threads))
    (if (null emacsos-assist-web--catalog)
        (emacsos-assist-web--show-notice
         "*assist Threads*"
         "No Assist threads yet. C-c e n creates one; C-c e t opens one; C-c e r retries.")
      (let* ((records (emacsos-assist-web--completion-records))
           (choice (completing-read "Assist thread: "
                                    (emacsos-assist-web--completion-table records)
                                    nil t))
           (record (emacsos-assist-web--record-for-display choice records)))
        (when record (emacsos-assist-web--show-thread (plist-get record :thread)))))))

(defun emacsos-assist-web-refresh-threads ()
  "Refresh the thread chooser cache asynchronously."
  (interactive)
  (let ((notice (get-buffer "*assist Threads*"))
        (generation (cl-incf emacsos-assist-web--catalog-generation)))
    (emacsos-assist-web--request
     "GET" "threads" nil
     (lambda (value error)
       (when (= generation emacsos-assist-web--catalog-generation)
         (if error
           (progn
             (when emacsos-assist-web--catalog-loaded-p
               (setq emacsos-assist-web--catalog-stale t))
             (when (buffer-live-p notice)
               (with-current-buffer notice
                 (let ((inhibit-read-only t))
                   (erase-buffer)
                   (insert "Assist threads could not be loaded.\n"
                           "Reconnect, then use C-c e r to retry.\n"))))
             (message "Thread refresh failed: %s" error))
         (condition-case problem
             (progn
               (emacsos-assist-web--require-catalog value)
               (setq emacsos-assist-web--catalog (alist-get 'threads value)
                     emacsos-assist-web--catalog-loaded-p t
                     emacsos-assist-web--catalog-stale nil)
               (emacsos-assist-web--try-write-cache
                emacsos-assist-web--catalog-file value)
               (when (buffer-live-p notice)
                 (with-current-buffer notice
                   (let ((inhibit-read-only t))
                     (erase-buffer)
                     (insert "Assist threads are ready.\n"
                             "Use C-c e t to choose one. C-c e r refreshes.\n"))))
               (message "Threads updated. Open Threads to choose one."))
           (error
            (when (buffer-live-p notice)
              (with-current-buffer notice
                (let ((inhibit-read-only t))
                  (erase-buffer)
                  (insert "Assist threads returned invalid data.\n"
                          "Use C-c e r to retry.\n"))))
            (message "Thread refresh rejected: %s"
                     (error-message-string problem))))))))))

(defun emacsos-assist-web--read-catalog-cache ()
  "Return the validated local catalog cache, or nil when absent or invalid."
  (when-let ((cached
              (emacsos-assist-web--read-cache emacsos-assist-web--catalog-file)))
    (condition-case nil
        (emacsos-assist-web--require-catalog cached)
      (error nil))))

(defun emacsos-assist-web--load-catalog ()
  "Load the catalog cache once, at package load or first use."
  (unless emacsos-assist-web--catalog-loaded-p
    (when-let ((cached (emacsos-assist-web--read-catalog-cache)))
      (setq emacsos-assist-web--catalog (alist-get 'threads cached)
            emacsos-assist-web--catalog-loaded-p t
            emacsos-assist-web--catalog-stale t))))

(defun emacsos-assist-web-refresh-thread (&optional buffer completed-run-id)
  "Fetch and render BUFFER's canonical thread snapshot asynchronously.

COMPLETED-RUN-ID identifies a run whose terminal event initiated this refresh."
  (interactive)
  (let ((buffer (or buffer (current-buffer))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when emacsos-assist-web--thread-id
          (let ((tid (emacsos-assist-web--require-id emacsos-assist-web--thread-id))
                (generation (cl-incf emacsos-assist-web--refresh-generation))
                (send-generation emacsos-assist-web--send-generation))
            (emacsos-assist-web--request
             "GET" (concat "threads/" tid) nil
             (lambda (value error)
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (when (and (= generation emacsos-assist-web--refresh-generation)
                              (= send-generation emacsos-assist-web--send-generation))
                     (if error
                         (progn
                           ;; Preserve the visible pending turn and editable tail.
                           ;; Re-rendering an older snapshot here would erase work
                           ;; that Assist has already accepted.
                           (if emacsos-assist-web--pending-accepted-p
                               (emacsos-assist-web--set-unverified-status
                                "refresh failed; C-c C-a g retries")
                             (emacsos-assist-web--set-status
                              (if emacsos-assist-web--snapshot
                                  "refresh failed; cached; C-c C-a g retries"
                                "refresh failed; C-c C-a g retries")))
                           (message "Thread refresh failed: %s" error))
                       (condition-case problem
                           (progn
                             (emacsos-assist-web--require-snapshot value tid)
                             (let ((busy
                                    (member
                                     (alist-get 'status (alist-get 'thread value))
                                     '("queued" "processing" "paused"
                                       "initializing" "cloning"
                                       "starting_sandbox"))))
                               (emacsos-assist-web--try-write-cache
                                (emacsos-assist-web--snapshot-cache-name tid) value)
                               (when (or (and completed-run-id
                                              (equal completed-run-id
                                                     emacsos-assist-web--run-id))
                                         (and emacsos-assist-web--pending-accepted-p
                                              (not busy)))
                                 ;; A manual refresh can discover completion while
                                 ;; the observer is live; a terminal-event refresh
                                 ;; can also see a newer external run.  In either
                                 ;; case, settle the exact locally observed run.
                                 (when emacsos-assist-web--in-flight
                                   (emacsos-assist-web--stream-cleanup nil t))
                                 (setq emacsos-assist-web--stream-status nil
                                       emacsos-assist-web--pending-key nil
                                       emacsos-assist-web--submitted-text nil
                                       emacsos-assist-web--pending-accepted-p nil
                                       emacsos-assist-web--run-id nil))
                               (when busy
                                 (setq emacsos-assist-web--stream-status nil))
                               ;; While this buffer owns a live observer, the
                               ;; existing provisional markers remain the only
                               ;; safe insertion target.  Cache a still-busy
                               ;; snapshot but leave that rendered region intact;
                               ;; a terminal refresh performs the reconciliation.
                               (unless (and busy emacsos-assist-web--in-flight)
                                 (emacsos-assist-web--render value))))
                         (error
                          (message "Thread refresh rejected: %s"
                                   (error-message-string problem))))))))))))))))

(defun emacsos-assist-web-load-older ()
  "Load one older bounded page of this thread's canonical visible history."
  (interactive)
  (if (not emacsos-assist-web--thread-id)
      (message "This draft has no history")
    (let* ((tid (emacsos-assist-web--require-id emacsos-assist-web--thread-id))
           (name (emacsos-assist-web--snapshot-cache-name tid))
           (cached (or emacsos-assist-web--snapshot
                       (emacsos-assist-web--read-cache name)))
           (before (and cached (alist-get 'next_before cached)))
           (buffer (current-buffer))
           (generation (cl-incf emacsos-assist-web--refresh-generation)))
      (if (not before)
          (message "No older messages are available")
        (emacsos-assist-web--request
         "GET" (format "threads/%s/history?before=%s" tid (url-hexify-string before)) nil
         (lambda (page error)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (when (and (= generation emacsos-assist-web--refresh-generation)
                          (equal before (alist-get 'next_before
                                                   (or emacsos-assist-web--snapshot cached))))
                 (if error
                     (message "Older history failed: %s" error)
                   (condition-case problem
                       (let ((updated
                              (copy-tree
                               (or emacsos-assist-web--snapshot cached))))
                         (emacsos-assist-web--require-history-page
                          page tid updated before)
                         (setf (alist-get 'messages updated)
                               (append (alist-get 'messages page)
                                       (alist-get 'messages updated))
                               (alist-get 'has_older_messages updated)
                               (alist-get 'has_older_messages page)
                               (alist-get 'next_before updated)
                               (alist-get 'next_before page))
                         (emacsos-assist-web--render updated))
                     (error
                      (message "Older history rejected: %s"
                               (error-message-string problem))))))))))))))

(defun emacsos-assist-web--new-idempotency-key ()
  "Mint one opaque retry key; it is persisted in the buffer while pending."
  (concat "emacsos-" (md5 (format "%s-%s-%s" (float-time) (random) (emacs-pid)))))

(defun emacsos-assist-web--release-send (buffer status)
  "Release BUFFER's send reservation, show STATUS, and persist retry state."
  (setq emacsos-assist-web--in-flight nil)
  (when (eq emacsos--assist-active-surface buffer)
    (setq emacsos--assist-active-surface nil))
  (emacsos-assist-web--set-status status)
  (emacsos-assist-web--save-draft))

(defun emacsos-assist-web-send ()
  "Send this buffer's prompt to its canonical web thread exactly once."
  (interactive)
  (when (and (bufferp emacsos--assist-active-surface)
             (not (buffer-live-p emacsos--assist-active-surface)))
    (setq emacsos--assist-active-surface nil))
  (let ((text (or emacsos-assist-web--submitted-text
                  (emacsos-assist-web--input))))
    (cond
     ((not (derived-mode-p 'emacsos-assist-web-mode))
      (message "Open an Assist Web thread before sending"))
     ((or (not (stringp text)) (string-empty-p (string-trim text)))
      (message "Nothing to send"))
     (emacsos-assist-web--in-flight
      (message "A web-thread request is already running"))
     ((and emacsos--assist-active-surface
           (not (eq emacsos--assist-active-surface (current-buffer))))
      (message "Another Assist request is still running"))
     (t
      (let* ((generation (cl-incf emacsos-assist-web--send-generation))
             (buffer (current-buffer))
             (existing-thread-id emacsos-assist-web--thread-id))
        ;; Any older snapshot callback describes the transcript before this send.
        (cl-incf emacsos-assist-web--refresh-generation)
        (setq emacsos-assist-web--in-flight t
              emacsos--assist-active-surface buffer
              emacsos-assist-web--pending-key
              (or emacsos-assist-web--pending-key
                  (emacsos-assist-web--new-idempotency-key))
              emacsos-assist-web--submitted-text text
              emacsos-assist-web--pending-accepted-p nil
              ;; There is no current run to cancel until POST returns.
              emacsos-assist-web--run-id nil)
        ;; The phone must see its own turn and a live queued region before an
        ;; asynchronous POST gets a chance to call back.
        (unless emacsos-assist-web--pending-rendered-p
          (emacsos-assist-web--append-pending text))
        (if (not (emacsos-assist-web--save-draft))
            (emacsos-assist-web--release-send
             buffer "not sent; local draft could not be saved")
          (let ((key (emacsos-assist-web--require-idempotency-key
                      emacsos-assist-web--pending-key))
                path payload)
            (if existing-thread-id
                (setq path (concat "threads/"
                                   (emacsos-assist-web--require-id existing-thread-id)
                                   "/messages")
                      payload `((message . ,text)))
              (setq path "threads"
                    payload `((message . ,text)
                              (repo_key . ,emacsos-assist-web--draft-repository)
                              (harness . ,(or emacsos-assist-web--draft-harness
                                              "deepagents")))))
            (emacsos-assist-web--request
             "POST" path payload
             (lambda (value error)
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (when (and (= generation emacsos-assist-web--send-generation)
                              emacsos-assist-web--in-flight
                              (equal key emacsos-assist-web--pending-key))
                     (if error
                         (progn
                           (emacsos-assist-web--release-send
                            buffer "send failed; Send retries")
                           (message "Send failed. Retry keeps the same message: %s"
                                    error))
                       (condition-case problem
                           (let* ((thread-id (emacsos-assist-web--require-id
                                              (alist-get 'thread_id value)))
                                  (run-id (emacsos-assist-web--require-id
                                           (alist-get 'run_id value)))
                                  ;; Resolve another canonical owner before this
                                  ;; draft acquires the returned thread id.
                                  (canonical
                                   (and (not existing-thread-id)
                                        (emacsos-assist-web--thread-buffer
                                         thread-id))))
                             (when (and existing-thread-id
                                        (not (equal existing-thread-id thread-id)))
                               (error "Assist Web send changed thread identity"))
                             (if (and (not existing-thread-id) canonical
                                      (not (eq canonical buffer)))
                                 ;; A local draft must retain its retry tuple until the
                                 ;; final canonical owner has durably saved it.  Stage
                                 ;; that cache record without changing either buffer's
                                 ;; ownership; a failed save leaves the source intact.
                                 (let* ((draft buffer)
                                        (next-draft (emacsos-assist-web--input))
                                        (persisted
                                        (with-current-buffer canonical
                                          (let ((emacsos-assist-web--run-id run-id)
                                                (emacsos-assist-web--pending-key key)
                                                (emacsos-assist-web--submitted-text text)
                                                (emacsos-assist-web--pending-accepted-p t)
                                                (emacsos-assist-web--in-flight t))
                                            ;; The active source can receive the
                                            ;; user's next draft while POST waits.
                                            ;; Its accepted canonical owner must
                                            ;; persist that tail before source
                                            ;; ownership is released.
                                            (when (and (stringp next-draft)
                                                       (not (string-empty-p next-draft)))
                                              (emacsos-assist-web--replace-input next-draft))
                                            (emacsos-assist-web--save-draft)))))
                                   (if (not (and persisted
                                                 (emacsos-assist-web--delete-cache
                                                  "drafts/new-thread.json")))
                                       (emacsos-assist-web--stream-interrupted
                                        draft "accepted; local recovery could not be saved")
                                     (with-current-buffer canonical
                                       ;; Retire the canonical buffer's old observer
                                       ;; before assigning it this accepted Run.  Merely
                                       ;; invalidating its generation would orphan that
                                       ;; process and consume a server observer slot.
                                       (emacsos-assist-web--stream-cleanup t t)
                                       ;; Invalidate callbacks started before this
                                       ;; buffer became the accepted run's owner.
                                       (cl-incf emacsos-assist-web--refresh-generation)
                                       (cl-incf emacsos-assist-web--send-generation)
                                       (setq emacsos-assist-web--run-id run-id
                                             emacsos-assist-web--pending-key key
                                             emacsos-assist-web--submitted-text text
                                             emacsos-assist-web--pending-accepted-p t
                                             emacsos-assist-web--in-flight t)
                                       (unless emacsos-assist-web--pending-rendered-p
                                         (emacsos-assist-web--append-pending text)))
                                     (setq emacsos--assist-active-surface canonical)
                                     (with-current-buffer draft
                                       (setq emacsos-assist-web--thread-id nil
                                             emacsos-assist-web--draft-id nil
                                             emacsos-assist-web--pending-key nil
                                             emacsos-assist-web--pending-accepted-p nil
                                             emacsos-assist-web--run-id nil
                                             emacsos-assist-web--in-flight nil))
                                     (kill-buffer draft)
                                     (setq buffer canonical)
                                     (switch-to-buffer canonical)
                                     (with-current-buffer buffer
                                       (unless (alist-get 'live_text value)
                                         (emacsos-assist-web--set-assistant-status
                                          "working; live text unavailable")
                                         (emacsos-assist-web--set-status
                                          "working; live text unavailable"))
                                       (emacsos-assist-web--observe-run buffer))))
                               ;; Keep the ordinary path in one explicit branch: a
                               ;; canonical adoption starts its observer above, and
                               ;; every other acceptance starts exactly this one.
                               (progn
                                 (setq emacsos-assist-web--thread-id thread-id
                                       emacsos-assist-web--run-id run-id
                                       emacsos-assist-web--pending-accepted-p t)
                                 (unless existing-thread-id
                                   (rename-buffer (format "*assist Thread <%s>*" thread-id) t)
                                   (setq emacsos-assist-web--draft-id nil))
                                 (with-current-buffer buffer
                                   (unless (alist-get 'live_text value)
                                     (emacsos-assist-web--set-assistant-status
                                      "working; live text unavailable")
                                     (emacsos-assist-web--set-status
                                      "working; live text unavailable"))
                                   (unless emacsos-assist-web--pending-rendered-p
                                     (emacsos-assist-web--append-pending text))
                                   ;; POST acceptance is not recoverable until this exact
                                   ;; canonical Run and its idempotency tuple reach disk.
                                   ;; Do not start a stream that could outlive that record.
                                   (if (emacsos-assist-web--save-draft)
                                       (progn
                                         (unless existing-thread-id
                                           (emacsos-assist-web--delete-cache
                                            "drafts/new-thread.json"))
                                         (emacsos-assist-web--observe-run buffer))
                                     (emacsos-assist-web--stream-interrupted
                                      buffer "accepted; local recovery could not be saved"))))))
                         (error
                          (emacsos-assist-web--release-send
                           buffer "send response rejected; Send retries")
                          (message "Send response rejected. Retry is safe: %s"
                                   (error-message-string problem)))))))))
             `(("Idempotency-Key" . ,key))))))))))

(defun emacsos-assist-web--append-pending (text)
  "Commit sent TEXT to this transcript while preserving a newly typed draft."
  (let* ((input-start (emacsos-assist-web--prompt-start))
         (draft (emacsos-assist-web--input))
         (input-offset (and input-start (>= (point) input-start)
                            (- (point) input-start)))
         (prompt-start (and (markerp emacsos-assist-web--prompt-marker)
                            (marker-position emacsos-assist-web--prompt-marker)))
         (inhibit-read-only t))
    (when prompt-start
      (delete-region prompt-start (point-max))
      (let ((transcript-start (point))
            (start (point)) body-start)
        (insert "you> ")
        (setq body-start (point))
        (insert text)
        (emacsos-conversation-commit-user start body-start (point))
        (insert "\n\n")
        (setq start (point))
        (insert "bot> ")
        (setq body-start (point))
        (insert "[queued]\n")
        (pcase-let ((`(,assistant-start . ,assistant-end)
                     (emacsos-conversation-begin-assistant body-start (point))))
          (setq emacsos-assist-web--assistant-start assistant-start
                ;; This marks the body boundary, not the following prompt.
                emacsos-assist-web--assistant-end assistant-end))
        (emacsos--chat-present-message start body-start (point) 'assistant)
        (add-text-properties transcript-start (point)
                             '(read-only t front-sticky t rear-nonsticky t)))
      (emacsos-assist-web--write-prompt)
      (when (and draft (not (equal draft text))) (insert draft))
      (setq emacsos-assist-web--pending-rendered-p t)
      (if input-offset
          (goto-char (min (point-max)
                          (+ (emacsos-assist-web--prompt-start) input-offset)))
        (goto-char (point-max))))))

(defun emacsos-assist-web-abort ()
  "Abort an unclaimed run, or honestly detach if Assist has already started it."
  (interactive)
  (if (and emacsos-assist-web--in-flight (not emacsos-assist-web--run-id))
      (progn
        ;; There is no durable Run identity yet.  Forget this callback, retain
        ;; the key/text tuple, and let the next Send discover any late acceptance.
        (cl-incf emacsos-assist-web--send-generation)
        (emacsos-assist-web--stream-cleanup t)
        (emacsos-assist-web--set-assistant-status
         "stopped watching; acceptance unknown; Send re-observes")
        (emacsos-assist-web--set-status "acceptance unknown; Send retries safely")
        (emacsos-assist-web--save-draft)
        (message "Stopped waiting for acceptance; Send reuses this exact message"))
    (if (not (and emacsos-assist-web--thread-id emacsos-assist-web--run-id
                  (or emacsos-assist-web--in-flight
                      emacsos-assist-web--pending-accepted-p)))
        (message "No Assist run is being observed")
      (let ((buffer (current-buffer))
            (send-generation emacsos-assist-web--send-generation)
            (path (format "threads/%s/runs/%s"
                          (emacsos-assist-web--require-id emacsos-assist-web--thread-id)
                          (emacsos-assist-web--require-id emacsos-assist-web--run-id))))
        ;; Detach before the cancellation request: a network outage must not hold
        ;; the one active-run slot hostage.  Assist remains canonical either way.
        (emacsos-assist-web--stream-cleanup t)
        (emacsos-assist-web--set-status "stopped watching; cancellation unconfirmed")
        (emacsos-assist-web--save-draft)
        (message "Stopped watching; cancellation is not yet confirmed")
        (emacsos-assist-web--request
         "DELETE" path nil
         (lambda (value error)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (when (= send-generation emacsos-assist-web--send-generation)
                 (if error
                     (if (equal error "Assist Web run store is unavailable")
                         (emacsos-assist-web--run-store-unavailable buffer)
                       (emacsos-assist-web--set-status
                        "stopped watching; cancellation unconfirmed")
                       (message "Cancellation unconfirmed: %s" error))
                   (pcase (cons (alist-get 'http_status value) (alist-get 'outcome value))
                     (`(200 . "cancelled")
                      (emacsos-assist-web--set-status "cancelled; reconciling")
                      (message "Queued Assist run cancelled")
                      (emacsos-assist-web-refresh-thread buffer emacsos-assist-web--run-id))
                     (`(409 . "running")
                      (emacsos-assist-web--set-status "stopped watching; Assist is running"))
                     (`(409 . "transitioning")
                      (emacsos-assist-web--set-status "stopped watching; Assist is transitioning"))
                     (`(409 . ,outcome)
                      (if (member outcome '("success" "error" "timeout" "cancelled"
                                           "interrupted" "awaiting_approval"))
                          (progn
                            (emacsos-assist-web--set-status
                             (format "%s; reconciling" outcome))
                            (emacsos-assist-web-refresh-thread
                             buffer emacsos-assist-web--run-id))
                        (emacsos-assist-web--set-status
                         "stopped watching; cancellation unconfirmed")))
                     (_
                      (emacsos-assist-web--set-status
                       "stopped watching; cancellation unconfirmed"))))
                 (emacsos-assist-web--save-draft)))))
         nil t)))))

(defun emacsos-assist-web--new-thread-from-catalog (cache)
  "Open the existing new-thread draft, or choose its workspace from CACHE."
  (if-let ((existing (get-buffer "*assist New thread*")))
      (switch-to-buffer existing)
    (let* ((repositories (alist-get 'repositories cache))
         (saved (emacsos-assist-web--read-cache "drafts/new-thread.json"))
         (saved-repo-key (alist-get 'repo_key saved))
         (saved-harness-key (alist-get 'harness saved))
         (repo-record (emacsos-assist-web--select-labeled-item
                       "Repository: " repositories 'repo_key saved-repo-key))
         (repo (and repo-record (plist-get repo-record :item)))
         (selected (and repo-record (plist-get repo-record :display)))
         (harnesses (alist-get 'harnesses cache))
         (harness-record (emacsos-assist-web--select-labeled-item
                          "Harness: " harnesses 'key saved-harness-key))
         (harness (and harness-record (plist-get harness-record :item)))
         (selected-harness (and harness-record
                                (plist-get harness-record :display)))
         (buffer (get-buffer-create "*assist New thread*")))
    (if (not (and repo harness))
        (progn (kill-buffer buffer)
               (message "Refresh thread catalog before creating a thread"))
      (with-current-buffer buffer
        (emacsos-assist-web-mode)
        (setq emacsos-assist-web--draft-id "new-thread"
              emacsos-assist-web--draft-repository (alist-get 'repo_key repo)
              emacsos-assist-web--draft-harness (alist-get 'key harness))
        (let ((inhibit-read-only t) (inhibit-modification-hooks t))
          (insert (format "*assist New thread - %s*\n" selected))
          (setq emacsos-assist-web--status-start (copy-marker (point) nil))
          (insert (format "[%s local draft]" selected-harness))
          (setq emacsos-assist-web--status-end (copy-marker (point) nil))
          (insert "\n\n")
          (emacsos-assist-web--write-prompt)
          (emacsos-assist-web--restore-draft)))
      (switch-to-buffer buffer)))))

(defun emacsos-assist-web-new-thread ()
  "Create a local draft, fetching repository choices on first use if needed."
  (interactive)
  (let ((cache (emacsos-assist-web--read-catalog-cache)))
    (if (and (alist-get 'repositories cache) (alist-get 'harnesses cache))
        (emacsos-assist-web--new-thread-from-catalog cache)
      (message "Fetching repositories for a new Assist thread…")
      (let ((generation (cl-incf emacsos-assist-web--catalog-generation)))
        (emacsos-assist-web--request
         "GET" "threads" nil
         (lambda (value error)
           (when (= generation emacsos-assist-web--catalog-generation)
             (if error
                 (message "Cannot create a thread until repository choices load: %s"
                          error)
               (condition-case problem
                   (progn
                     (emacsos-assist-web--require-catalog value)
                     (setq emacsos-assist-web--catalog (alist-get 'threads value)
                           emacsos-assist-web--catalog-loaded-p t
                           emacsos-assist-web--catalog-stale nil)
                     (emacsos-assist-web--try-write-cache
                      emacsos-assist-web--catalog-file value)
                     (emacsos-assist-web--new-thread-from-catalog value))
                 (error
                  (message "Cannot create a thread from invalid catalog data: %s"
                           (error-message-string problem))))))))))))

(define-derived-mode emacsos-assist-web-mode text-mode "Assist Web"
  "Major mode for a canonical Assist Web thread or unsent local draft."
  (variable-pitch-mode 1)
  (emacsos--chat-enable-presentation)
  (emacsos-conversation-install-actions
   '((send . emacsos-assist-web-send)
     (abort . emacsos-assist-web-abort)
     (refresh . emacsos-assist-web-refresh-thread)
     (older . emacsos-assist-web-load-older)
     (catalog . emacsos-assist-web-refresh-threads)))
  (add-hook 'after-change-functions #'emacsos-assist-web--after-change nil t)
  (add-hook 'kill-buffer-hook #'emacsos-assist-web--buffer-killed nil t))

(define-key emacsos-assist-web-mode-map (kbd "RET")
            #'emacsos-conversation-activate-or-newline)

(emacsos-assist-web--load-catalog)

(provide 'assist-web)
;;; assist-web.el ends here
