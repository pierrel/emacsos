;;; assist-web.el --- Assist Web threads in EmacsOS -*- lexical-binding: t -*-

;;; Commentary:

;; This is deliberately separate from emacos-assist.el.  A .assist file is a
;; phone-local conversation owned by emacsos-server; this mode is a client of
;; Assist Web's canonical thread/run state.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'url)
(require 'url-http)
(require 'url-util)

(declare-function emacos--render-page "os")

(defgroup emacos-assist-web nil
  "Assist Web thread client for EmacsOS."
  :group 'emacsos)

(defcustom emacos-assist-web-api-url "https://assist.invalid/api/v1/phone"
  "Base URL of the authenticated Assist Web phone API."
  :type 'string
  :group 'emacos-assist-web)

(defcustom emacos-assist-web-token-file
  (expand-file-name "~/.config/emacsos/assist-web-token")
  "0600 file holding the Assist Web bearer token."
  :type 'file
  :group 'emacos-assist-web)

(defcustom emacos-assist-web-cache-directory
  (expand-file-name "~/.cache/emacsos/assist-web")
  "Private on-phone cache for Assist Web catalogs, snapshots, and drafts."
  :type 'directory
  :group 'emacos-assist-web)

(defcustom emacos-assist-web-max-cache-bytes (* 512 1024)
  "Maximum encoded size of one private Assist Web cache record."
  :type 'integer
  :group 'emacos-assist-web)

(defcustom emacos-assist-web-max-response-bytes (* 1024 1024)
  "Maximum buffered JSON response accepted from Assist Web."
  :type 'integer
  :group 'emacos-assist-web)

(defcustom emacos-assist-web-max-event-bytes (* 64 1024)
  "Maximum size of one complete or unfinished SSE event from Assist Web."
  :type 'integer
  :group 'emacos-assist-web)

(defcustom emacos-assist-web-max-header-bytes (* 64 1024)
  "Maximum HTTP response-header size accepted from Assist Web."
  :type 'integer
  :group 'emacos-assist-web)

(defcustom emacos-assist-web-request-timeout 30
  "Seconds allowed for one bounded Assist Web JSON request."
  :type 'integer
  :group 'emacos-assist-web)

(defcustom emacos-assist-web-max-concurrent-requests 4
  "Maximum simultaneous bounded Assist Web JSON requests."
  :type 'integer
  :group 'emacos-assist-web)

(defconst emacos-assist-web--prompt "\n> ")
(defconst emacos-assist-web--catalog-file "threads.json")
(defconst emacos-assist-web--id-regexp "\\`[A-Za-z0-9][A-Za-z0-9._-]\\{0,127\\}\\'")
(defconst emacos-assist-web--idempotency-regexp "\\`emacsos-[0-9a-f]\\{32\\}\\'")
(defvar emacos-assist-web--catalog nil)
(defvar emacos-assist-web--catalog-stale nil)
(defvar emacos-assist-web--active-buffer nil)
(defvar emacos-assist-web--requests nil)

(defvar-local emacos-assist-web--thread-id nil)
(defvar-local emacos-assist-web--draft-repository nil)
(defvar-local emacos-assist-web--draft-harness nil)
(defvar-local emacos-assist-web--run-id nil)
(defvar-local emacos-assist-web--pending-key nil)
(defvar-local emacos-assist-web--in-flight nil)
(defvar-local emacos-assist-web--snapshot nil)
(defvar-local emacos-assist-web--stream-process nil)
(defvar-local emacos-assist-web--stream-response nil)
(defvar-local emacos-assist-web--stream-body-marker nil)
(defvar-local emacos-assist-web--status-start nil)
(defvar-local emacos-assist-web--status-end nil)
(defvar-local emacos-assist-web--stream-status nil)
(defvar-local emacos-assist-web--submitted-text nil)
(defvar-local emacos-assist-web--draft-id nil)
(defvar-local emacos-assist-web--draft-save-timer nil)
(defvar-local emacos-assist-web--refresh-generation 0)
(defvar-local emacos-assist-web--send-generation 0)
(defvar-local emacos-assist-web--stream-generation 0)
(defvar-local emacos-assist-web--stream-header-timer nil)

(defun emacos-assist-web--cache-path (&optional name)
  "Return cache path NAME, creating the private cache root when needed."
  (make-directory emacos-assist-web-cache-directory t)
  (set-file-modes emacos-assist-web-cache-directory #o700)
  (expand-file-name (or name emacos-assist-web--catalog-file)
                    emacos-assist-web-cache-directory))

(defun emacos-assist-web--write-cache (name value)
  "Atomically save VALUE as JSON cache NAME."
  (let ((encoded (json-encode value))
        (path (emacos-assist-web--cache-path name))
        (temporary nil))
    (when (> (string-bytes encoded) emacos-assist-web-max-cache-bytes)
      (error "Assist Web cache record is too large"))
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

(defun emacos-assist-web--read-cache (name)
  "Return parsed JSON cache NAME, or nil when no valid cache exists."
  (condition-case nil
      (let ((path (emacos-assist-web--cache-path name)))
        (when (and (file-readable-p path)
                   (<= (file-attribute-size (file-attributes path))
                       emacos-assist-web-max-cache-bytes))
          (with-temp-buffer
            (insert-file-contents path)
            (json-parse-buffer :object-type 'alist :array-type 'list
                               :null-object nil :false-object nil))))
    (error nil)))

(defun emacos-assist-web--read-token ()
  "Return the bearer token without exposing it in a message or URL."
  (when (file-readable-p emacos-assist-web-token-file)
    (with-temp-buffer
      (insert-file-contents-literally emacos-assist-web-token-file)
      (string-trim (buffer-string)))))

(defun emacos-assist-web--endpoint (path)
  "Join API PATH without accepting a caller-controlled host."
  (concat (replace-regexp-in-string "/+\\'" "" emacos-assist-web-api-url)
          "/" (replace-regexp-in-string "\\`/+" "" path)))

(defun emacos-assist-web--valid-id-p (value)
  "Return non-nil when VALUE is a safe opaque Assist Web identifier."
  (and (stringp value) (string-match-p emacos-assist-web--id-regexp value)))

(defun emacos-assist-web--require-id (value)
  "Return VALUE or reject it before it reaches an endpoint or cache path."
  (unless (emacos-assist-web--valid-id-p value)
    (error "Assist Web returned an invalid identifier"))
  value)

(defun emacos-assist-web--require-idempotency-key (value)
  "Return locally minted VALUE or reject it before HTTP header construction."
  (unless (and (stringp value)
               (string-match-p emacos-assist-web--idempotency-regexp value))
    (error "Assist Web retry identity is invalid"))
  value)

(defun emacos-assist-web--response-json (buffer)
  "Return BUFFER's JSON response object or signal a useful local error."
  (with-current-buffer buffer
    (let ((status url-http-response-status)
          (start (and (boundp 'url-http-end-of-headers) url-http-end-of-headers)))
      (unless (and status (<= 200 status 299))
        (error "Assist Web request failed (%s)" (or status "no response")))
      (unless start (error "Assist Web returned no response body"))
      (goto-char start)
      (json-parse-buffer :object-type 'alist :array-type 'list
                         :null-object nil :false-object nil))))

(defun emacos-assist-web--guarded-filter (url-filter fail &optional streaming)
  "Wrap URL-FILTER with raw HTTP bounds, invoking FAIL with a safe message.

STREAMING permits an unbounded total body; its individual SSE records are
bounded after URL-FILTER parses the response.  Headers and encoded responses
are rejected before URL-FILTER can redirect or decompress them."
  (let ((received 0) (header "") (header-complete nil) (failed nil))
    (lambda (process bytes)
      (unless failed
        (setq received (+ received (string-bytes bytes)))
        (when (and (not streaming)
                   (> received emacos-assist-web-max-response-bytes))
          (setq failed t)
          (funcall fail process "Assist Web response is too large"))
        (unless (or failed header-complete)
          (setq header (concat header bytes))
          (let ((header-end (string-match "\r?\n\r?\n" header)))
            (cond
             ((and (not header-end)
                   (> (string-bytes header) emacos-assist-web-max-header-bytes))
              (setq failed t)
              (funcall fail process "Assist Web response headers are too large"))
             (header-end
              (let ((headers-only (substring header 0 (match-end 0))))
                (if (> (string-bytes headers-only)
                       emacos-assist-web-max-header-bytes)
                    (progn
                      (setq failed t)
                      (funcall fail process "Assist Web response headers are too large"))
                  (setq header-complete t)
                  (let ((case-fold-search t))
                    (when (and
                           (string-match
                            "\\(?:\\`\\|[\r\n]\\)Content-Encoding:[ \t]*\\([^ \t\r\n]+\\)"
                            headers-only)
                           (not (equal (downcase (match-string 1 headers-only))
                                       "identity")))
                      (setq failed t)
                      (funcall fail process
                               "Assist Web encoded responses are not accepted"))))
                (setq header nil))))))
        (when (and (not failed) (functionp url-filter))
          (funcall url-filter process bytes))))))

(defun emacos-assist-web--request (method path payload callback &optional headers)
  "Send METHOD to PATH with optional JSON PAYLOAD and HEADERS.

Invoke CALLBACK with (VALUE ERROR).  Report network and parsing failures as
ERROR rather than raising them from url-http's asynchronous callback."
  (let ((token (emacos-assist-web--read-token)))
    (if (not (and token (not (string-empty-p token))))
        (funcall callback nil "Assist Web token is missing")
      (if (>= (length emacos-assist-web--requests)
              emacos-assist-web-max-concurrent-requests)
          (funcall callback nil "Too many Assist Web requests are already running")
        (let* ((url-request-method method)
               (url-request-extra-headers
		(append `(("Authorization" . ,(concat "Bearer " token))
                          ("Accept" . "application/json"))
			(when payload '(("Content-Type" . "application/json")))
			headers))
               (url-request-data
		(and payload (encode-coding-string (json-encode payload) 'utf-8)))
               (url (emacos-assist-web--endpoint path))
               (finished nil)
               response process timer)
          (cl-labels
              ((finish (value problem)
		 (unless finished
                   (setq finished t)
                   (when (timerp timer) (cancel-timer timer))
                   (setq emacos-assist-web--requests
			 (delq response emacos-assist-web--requests))
                   (funcall callback value problem))))
            (condition-case error
		(progn
                  (setq response
			(let ((url-mime-encoding-string "identity"))
                          (url-retrieve
                           url
                           (lambda (_status)
                             (let (value problem)
                               (unwind-protect
                                   (condition-case parse-error
                                       (setq value
                                             (emacos-assist-web--response-json
                                              (current-buffer)))
                                     (error
                                      (setq problem
                                            (error-message-string parse-error))))
				 (kill-buffer (current-buffer)))
                               (finish value problem)))
                           nil t t)))
                  (when (buffer-live-p response)
                    (with-current-buffer response
                      (setq-local url-max-redirections 0))
                    (push response emacos-assist-web--requests))
                  (setq process (and (buffer-live-p response)
                                     (get-buffer-process response)))
                  (setq timer
			(run-at-time
			 emacos-assist-web-request-timeout nil
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
                       (emacos-assist-web--guarded-filter
			url-filter
			(lambda (active problem)
			  (set-process-filter active nil)
			  (set-process-sentinel active nil)
			  (when (process-live-p active) (delete-process active))
			  (when (buffer-live-p (process-buffer active))
                            (emacos-assist-web--kill-buffer-later
                             (process-buffer active)))
			  (finish nil problem)))))))
              (error (finish nil (error-message-string error))))))))))

(defun emacos-assist-web--leading-emoji-p (character)
  "Return non-nil when CHARACTER is pictographic title-prefix syntax."
  (or (and (>= character #x1f000) (<= character #x1faff))
      (and (>= character #x2600) (<= character #x27bf))
      (member character '(#x200d #xfe0e #xfe0f))))

(defun emacos-assist-web--set-status (status)
  "Show STATUS in this thread buffer without inventing transcript content."
  (setq emacos-assist-web--stream-status status)
  (when (and (markerp emacos-assist-web--status-start)
             (marker-buffer emacos-assist-web--status-start))
    (let ((inhibit-read-only t) (inhibit-modification-hooks t))
      (save-excursion
        (goto-char emacos-assist-web--status-start)
        (delete-region emacos-assist-web--status-start emacos-assist-web--status-end)
        (insert (format "[%s]" status))
        (set-marker emacos-assist-web--status-end (point))))))

(defun emacos-assist-web--kill-buffer-later (buffer)
  "Kill BUFFER after the current URL process filter has returned."
  (run-at-time 0 nil
               (lambda (candidate)
                 (when (buffer-live-p candidate) (kill-buffer candidate)))
               buffer))

(defun emacos-assist-web--stream-cleanup (&optional keep-pending no-render)
  "Release this buffer's event stream.

Retain retry identity when KEEP-PENDING is non-nil.  When NO-RENDER is non-nil,
do not ask the phone shell to redraw a dying buffer."
  (let ((process emacos-assist-web--stream-process)
        (response emacos-assist-web--stream-response))
    (cl-incf emacos-assist-web--stream-generation)
    (when (timerp emacos-assist-web--stream-header-timer)
      (cancel-timer emacos-assist-web--stream-header-timer))
    (setq emacos-assist-web--stream-process nil
          emacos-assist-web--stream-response nil
          emacos-assist-web--stream-body-marker nil
          emacos-assist-web--stream-header-timer nil
          emacos-assist-web--in-flight nil)
    (when (eq emacos-assist-web--active-buffer (current-buffer))
      (setq emacos-assist-web--active-buffer nil))
    (when (process-live-p process)
      (set-process-sentinel process nil)
      (delete-process process))
    ;; A terminal event is parsed inside RESPONSE.  Deferring its destruction
    ;; keeps the URL filter's marker update valid, then reclaims it promptly.
    (when (buffer-live-p response) (emacos-assist-web--kill-buffer-later response))
    (unless keep-pending
      (setq emacos-assist-web--pending-key nil
            emacos-assist-web--submitted-text nil
            emacos-assist-web--stream-status nil))
    (when (and (not no-render) (fboundp 'emacos--render-page))
      (emacos--render-page))))

(defun emacos-assist-web--buffer-killed ()
  "Release a global run reservation when this thread buffer is killed."
  (when (timerp emacos-assist-web--draft-save-timer)
    (cancel-timer emacos-assist-web--draft-save-timer))
  (emacos-assist-web--stream-cleanup t t))

(defun emacos-assist-web--stream-finish (buffer)
  "Finish BUFFER's event observation and request its canonical transcript."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (emacos-assist-web--stream-cleanup)
      (emacos-assist-web-refresh-thread buffer))))

(defun emacos-assist-web--stream-interrupted (buffer status)
  "Keep BUFFER's exact pending submission and display interruption STATUS."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (emacos-assist-web--stream-cleanup t)
      (emacos-assist-web--set-status status)
      (emacos-assist-web--save-draft)
      (message "%s. Refresh to see the canonical result; Send retries the same message."
               status))))

(defun emacos-assist-web--dispatch-event (target event data)
  "Handle one bounded SSE EVENT with JSON DATA for TARGET."
  (when (buffer-live-p target)
    (with-current-buffer target
      (cond
       ((equal event "status")
        (condition-case nil
            (let ((status (json-parse-string data :object-type 'alist)))
              (emacos-assist-web--set-status
               (or (alist-get 'status status) "working")))
          (error nil)))
       ((equal event "terminal") (emacos-assist-web--stream-finish target))
       ((equal event "error")
        (emacos-assist-web--stream-interrupted target "observation interrupted"))))))

(defun emacos-assist-web--drain-events (target generation)
  "Consume complete SSE records for TARGET if GENERATION is still current."
  (unless (markerp emacos-assist-web--stream-body-marker)
    (setq-local emacos-assist-web--stream-body-marker
                (copy-marker (marker-position url-http-end-of-headers) nil)))
  (let* ((marker emacos-assist-web--stream-body-marker)
         (start (marker-position marker))
         (raw (buffer-substring-no-properties start (point-max)))
         (offset 0)
         (too-large nil))
    ;; url-http can split any byte sequence across callbacks; retain partial records.
    (while (and (not too-large) (string-match "\n\n" raw offset))
      (let ((record-end (match-end 0))
            (event nil) (data nil)
            (record (substring raw offset (match-beginning 0))))
        (if (> (string-bytes record) emacos-assist-web-max-event-bytes)
            (progn
              (setq too-large t)
              (setq offset (length raw))
              (when (and (buffer-live-p target)
                         (with-current-buffer target
                           (= generation emacos-assist-web--stream-generation)))
                (emacos-assist-web--stream-interrupted
                 target "Assist event is too large")))
          (dolist (line (split-string record "\n" t))
            (cond
             ((string-prefix-p "event: " line) (setq event (substring line 7)))
             ((string-prefix-p "data: " line) (setq data (substring line 6)))))
          (when (and event (buffer-live-p target)
                     (with-current-buffer target
                       (= generation emacos-assist-web--stream-generation)))
            (emacos-assist-web--dispatch-event target event (or data "")))
          (setq offset record-end))))
    (when (> offset 0)
      ;; Retain only an incomplete final record.  Otherwise a long healthy
      ;; stream would still accumulate every already-consumed event.
      (delete-region start (+ start offset))
      (set-marker marker start))
    (when (> (string-bytes
              (buffer-substring-no-properties start (point-max)))
             emacos-assist-web-max-event-bytes)
      (delete-region start (point-max))
      (when (and (buffer-live-p target)
                 (with-current-buffer target
                   (= generation emacos-assist-web--stream-generation)))
        (emacos-assist-web--stream-interrupted target "Assist event is too large")))))

(defun emacos-assist-web--event-filter (url-filter target generation)
  "Wrap URL-FILTER and dispatch SSE records to TARGET for GENERATION."
  (lambda (process bytes)
    (when (functionp url-filter) (funcall url-filter process bytes))
    (let ((response (process-buffer process)))
      (when (buffer-live-p response)
        (with-current-buffer response
          (when (and (boundp 'url-http-end-of-headers) url-http-end-of-headers)
            (when (and (buffer-live-p target)
                       (with-current-buffer target
                         (= generation emacos-assist-web--stream-generation)))
              (with-current-buffer target
                (when (timerp emacos-assist-web--stream-header-timer)
                  (cancel-timer emacos-assist-web--stream-header-timer)
                  (setq emacos-assist-web--stream-header-timer nil))))
            (emacos-assist-web--drain-events target generation)))))))

(defun emacos-assist-web--observe-run (buffer)
  "Open BUFFER's bounded authenticated status stream for its current run."
  (let ((token (emacos-assist-web--read-token)))
    (if (not (and token (not (string-empty-p token))))
        (emacos-assist-web--stream-interrupted buffer "token missing")
      (with-current-buffer buffer
        (condition-case error
            (let* ((generation (cl-incf emacos-assist-web--stream-generation))
                   (thread-id (emacos-assist-web--require-id emacos-assist-web--thread-id))
                   (run-id (emacos-assist-web--require-id emacos-assist-web--run-id))
                   (url-request-method "GET")
                   (url-request-extra-headers `(("Authorization" . ,(concat "Bearer " token))))
                   (response
                    (let ((url-mime-encoding-string "identity"))
                      (url-retrieve
                       (emacos-assist-web--endpoint
                        (format "threads/%s/runs/%s/events" thread-id run-id))
                       #'ignore nil t t)))
                   (process (and (buffer-live-p response) (get-buffer-process response))))
              (if (not process)
                  (emacos-assist-web--stream-interrupted buffer "observation unavailable")
                (with-current-buffer response
                  (setq-local url-max-redirections 0))
                (setq emacos-assist-web--stream-response response
                      emacos-assist-web--stream-process process
                      emacos-assist-web--stream-header-timer
                      (run-at-time
                       emacos-assist-web-request-timeout nil
                       (lambda ()
                         (when (and (buffer-live-p buffer)
                                    (with-current-buffer buffer
                                      (and (= generation emacos-assist-web--stream-generation)
                                           (buffer-live-p emacos-assist-web--stream-response)
                                           (with-current-buffer emacos-assist-web--stream-response
                                             (not (and (boundp 'url-http-end-of-headers)
                                                       url-http-end-of-headers))))))
                           (emacos-assist-web--stream-interrupted
                            buffer "Assist observation timed out")))))
                (let* ((url-filter (process-filter process))
                       (event-filter
                        (emacos-assist-web--event-filter url-filter buffer generation)))
                  (set-process-filter
                   process
                   (emacos-assist-web--guarded-filter
                    event-filter
                    (lambda (active problem)
                      (if (and (buffer-live-p buffer)
                               (with-current-buffer buffer
                                 (and (= generation emacos-assist-web--stream-generation)
                                      (eq active emacos-assist-web--stream-process))))
                          (emacos-assist-web--stream-interrupted buffer problem)
                        (when (process-live-p active) (delete-process active))))
                    t)))
                (let ((url-sentinel (process-sentinel process)))
                  (set-process-sentinel
                   process
                   (lambda (ended _event)
                     (when (functionp url-sentinel) (funcall url-sentinel ended _event))
                     (when (and (not (process-live-p ended)) (buffer-live-p buffer))
                       (with-current-buffer buffer
                         (when (and (= generation emacos-assist-web--stream-generation)
                                    (eq ended emacos-assist-web--stream-process))
                           (emacos-assist-web--stream-interrupted
                            buffer "observation disconnected")))))))))
          (error
           (emacos-assist-web--stream-interrupted buffer
                                                  (error-message-string error))))))))

(defun emacos-assist-web-normalize-title (title)
  "Return TITLE with only an initial emoji run and following whitespace removed."
  (let ((index 0) (length (length title)))
    (while (and (< index length)
                (emacos-assist-web--leading-emoji-p (aref title index)))
      (setq index (1+ index)))
    (when (> index 0)
      (while (and (< index length) (memq (aref title index) '(?\  ?\t ?\n)))
        (setq index (1+ index))))
    (substring title index)))

(defun emacos-assist-web--thread-label (thread &optional suffix)
  "Display THREAD in the requested thread-buffer format with optional SUFFIX."
  (format "*assist %s - %s%s*"
          (alist-get 'description thread)
          (or (alist-get 'repo_label thread) "No repository")
          (or suffix "")))

(defun emacos-assist-web--completion-records ()
  "Return completion records with identity kept separate from display text."
  (let ((counts (make-hash-table :test #'equal)))
    (dolist (thread emacos-assist-web--catalog)
      (let ((label (emacos-assist-web--thread-label thread)))
        (puthash label (1+ (gethash label counts 0)) counts)))
    (mapcar
     (lambda (thread)
       (let* ((label (emacos-assist-web--thread-label thread))
              (identity-label
               (if (> (gethash label counts) 1)
                   (let* ((thread-id
                           (emacos-assist-web--require-id (alist-get 'id thread)))
                          (suffix-start (max 0 (- (length thread-id) 6))))
                     (emacos-assist-web--thread-label
                      thread (format " [%s]" (substring thread-id suffix-start))))
                 label))
              (state (or (alist-get 'status thread) "unknown"))
              (display (format "%s [%s%s]" identity-label state
                               (if emacos-assist-web--catalog-stale ", cached" ""))))
         (list :display display :thread thread
               :search (downcase (concat (emacos-assist-web-normalize-title
                                          (alist-get 'description thread))
                                         " " (alist-get 'description thread)
                                         " " (or (alist-get 'repo_label thread) "")
                                         " " state)))))
     emacos-assist-web--catalog)))

(defun emacos-assist-web--completion-table (records)
  "Build a completion table from RECORDS with normalized-title matching."
  (lambda (string predicate action)
    (let* ((query (downcase string))
           (matches (cl-loop for record in records
                             when (string-match-p (regexp-quote query)
                                                  (plist-get record :search))
                             collect (plist-get record :display))))
      (cond
       ((eq action 'metadata) '(metadata (category . emacos-assist-web-thread)))
       ((or (eq action t) (eq action 'all-completions))
        (if predicate (seq-filter predicate matches) matches))
       ((eq action 'test-completion) (member string matches))
       ((or (null action) (eq action 'try-completion))
        (and (= (length matches) 1) (car matches)))
       (t (complete-with-action action matches string predicate))))))

(defun emacos-assist-web--record-for-display (display records)
  "Return from RECORDS the completion record selected by DISPLAY."
  (seq-find (lambda (record) (equal display (plist-get record :display))) records))

(defun emacos-assist-web--show-notice (name text)
  "Show a small visible non-blocking notice buffer named NAME with TEXT."
  (let ((buffer (get-buffer-create name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (special-mode)
        (erase-buffer)
        (insert text "\n")))
    (switch-to-buffer buffer)
    buffer))

(defun emacos-assist-web--prompt-start ()
  "Return the editable region's start in the current web-thread buffer."
  (save-excursion
    (goto-char (point-max))
    (when (search-backward emacos-assist-web--prompt nil t)
      (+ (point) (length emacos-assist-web--prompt)))))

(defun emacos-assist-web--input ()
  "Return current user input from the web-thread prompt."
  (let ((start (emacos-assist-web--prompt-start)))
    (and start (string-trim (buffer-substring-no-properties start (point-max))))))

(defun emacos-assist-web--write-prompt ()
  "Append the one editable prompt after a rendered transcript."
  (let ((before (point)))
    (insert emacos-assist-web--prompt)
    (add-text-properties before (point)
                         '(read-only t front-sticky t rear-nonsticky t))))

(defun emacos-assist-web--insert-assistant (message)
  "Insert visible assistant MESSAGE text without later-step object links."
  (insert (alist-get 'text message)))

(defun emacos-assist-web--render (snapshot &optional stale)
  "Render SNAPSHOT in the current remote-thread buffer, marked STALE if needed."
  (let ((inhibit-read-only t)
        (inhibit-modification-hooks t)
        (thread (alist-get 'thread snapshot))
        (draft (emacos-assist-web--input)))
    (let ((returned-id (emacos-assist-web--require-id (alist-get 'id thread))))
      (when (and emacos-assist-web--thread-id
                 (not (equal returned-id emacos-assist-web--thread-id)))
        (error "Assist Web snapshot identity does not match this buffer"))
      (setq emacos-assist-web--thread-id returned-id))
    (setq
     emacos-assist-web--snapshot snapshot)
    (erase-buffer)
    (let ((transcript-start (point)))
      (insert (format "%s%s\n"
                      (emacos-assist-web--thread-label
                       `((description . ,(alist-get 'description thread))
                         (repo_label . ,(alist-get 'repo_label (alist-get 'workspace thread)))))
                      (if stale " [cached]" "")))
      (setq emacos-assist-web--status-start (copy-marker (point) nil))
      (insert (format "[%s%s]" (or emacos-assist-web--stream-status
                                   (alist-get 'status thread))
                      (if-let ((error (alist-get 'error thread)))
                          (concat ": " error) "")))
      (setq emacos-assist-web--status-end (copy-marker (point) nil))
      (insert "\n\n")
      (dolist (message (alist-get 'messages snapshot))
        (insert (if (equal (alist-get 'role message) "user") "you> " "bot> "))
        (if (equal (alist-get 'role message) "assistant")
            (emacos-assist-web--insert-assistant message)
          (insert (alist-get 'text message)))
        (insert "\n\n"))
      (add-text-properties transcript-start (point)
                           '(read-only t front-sticky t rear-nonsticky t))
      (emacos-assist-web--write-prompt)
      (if draft (insert draft) (emacos-assist-web--restore-draft))
      (goto-char (point-max))
      (setq buffer-read-only nil)
      (set-buffer-modified-p nil)
      (emacos-assist-web--save-draft))))

(defun emacos-assist-web--snapshot-cache-name (tid)
  "Return the bounded per-thread snapshot cache filename for TID."
  (concat "threads/" (emacos-assist-web--require-id tid) ".json"))

(defun emacos-assist-web--draft-cache-name ()
  "Return the private cache name for this thread or local draft buffer."
  (when-let ((identity (or (and emacos-assist-web--thread-id
                                (emacos-assist-web--require-id
                                 emacos-assist-web--thread-id))
                           (and emacos-assist-web--draft-id
                                (emacos-assist-web--require-id
                                 emacos-assist-web--draft-id)))))
    (concat "drafts/" identity ".json")))

(defun emacos-assist-web--save-draft ()
  "Persist the current editable tail and retry identity, if this buffer has one."
  (when-let ((name (emacos-assist-web--draft-cache-name)))
    (emacos-assist-web--write-cache
     name `((text . ,(or (emacos-assist-web--input) ""))
            (pending_key . ,emacos-assist-web--pending-key)
            (submitted_text . ,emacos-assist-web--submitted-text)
            (repo_key . ,emacos-assist-web--draft-repository)
            (harness . ,emacos-assist-web--draft-harness)))))

(defun emacos-assist-web--after-change (&rest _)
  "Debounce local draft persistence after a user edit."
  (when (and (derived-mode-p 'emacos-assist-web-mode)
             (not inhibit-modification-hooks))
    (when (and (not emacos-assist-web--in-flight)
               emacos-assist-web--pending-key
               (not (equal (emacos-assist-web--input)
                           emacos-assist-web--submitted-text)))
      (setq emacos-assist-web--pending-key nil
            emacos-assist-web--submitted-text nil))
    (when (timerp emacos-assist-web--draft-save-timer)
      (cancel-timer emacos-assist-web--draft-save-timer))
    (setq emacos-assist-web--draft-save-timer
          (run-with-idle-timer
           0.5 nil
           (lambda (buffer)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (setq emacos-assist-web--draft-save-timer nil)
                 (emacos-assist-web--save-draft))))
           (current-buffer)))))

(defun emacos-assist-web--restore-draft ()
  "Restore this thread's unsent local tail after rendering its remote snapshot."
  (when-let* ((name (emacos-assist-web--draft-cache-name))
              (draft (emacos-assist-web--read-cache name)))
    (let ((key (alist-get 'pending_key draft))
          (submitted (alist-get 'submitted_text draft))
          (text (alist-get 'text draft)))
      (if (and (stringp key)
               (string-match-p emacos-assist-web--idempotency-regexp key)
               (stringp submitted))
          (setq emacos-assist-web--pending-key key
                emacos-assist-web--submitted-text submitted)
        (setq emacos-assist-web--pending-key nil
              emacos-assist-web--submitted-text nil))
      (when (stringp text) (insert text)))))

(defun emacos-assist-web--show-thread (thread)
  "Create or select THREAD's dedicated buffer and fetch its canonical snapshot."
  (let* ((name (emacos-assist-web--thread-label thread))
         (tid (emacos-assist-web--require-id (alist-get 'id thread)))
         ;; The human label remains in the rendered header.  The opaque suffix
         ;; makes the Emacs buffer identity one-to-one even for duplicate titles.
         (buffer (get-buffer-create (format "%s <%s>" name tid))))
    (with-current-buffer buffer
      (unless (derived-mode-p 'emacos-assist-web-mode)
        (emacos-assist-web-mode))
      (setq emacos-assist-web--thread-id tid)
      (when-let ((cached (emacos-assist-web--read-cache
                          (emacos-assist-web--snapshot-cache-name tid))))
        (condition-case nil
            (emacos-assist-web--render cached t)
          (error nil)))
      (when (zerop (buffer-size))
        (let ((inhibit-read-only t) (inhibit-modification-hooks t))
          (insert "Loading Assist thread…\n"))))
    (switch-to-buffer buffer)
    (emacos-assist-web-refresh-thread buffer)))

(defun emacos-assist-web-open-thread ()
  "Choose and open one cached Assist Web thread without a network wait."
  (interactive)
  (emacos-assist-web--load-catalog)
  (if (not emacos-assist-web--catalog)
      (progn
        (emacos-assist-web--show-notice
         "*assist Threads*" "Loading Assist threads…")
        (emacos-assist-web-refresh-threads))
    (let* ((records (emacos-assist-web--completion-records))
           (choice (completing-read "Assist thread: "
                                    (emacos-assist-web--completion-table records)
                                    nil t))
           (record (emacos-assist-web--record-for-display choice records)))
      (when record (emacos-assist-web--show-thread (plist-get record :thread))))))

(defun emacos-assist-web-refresh-threads ()
  "Refresh the thread chooser cache asynchronously."
  (interactive)
  (let ((notice (get-buffer "*assist Threads*")))
    (emacos-assist-web--request
     "GET" "threads" nil
     (lambda (value error)
       (if error
           (progn
             (when (buffer-live-p notice)
               (with-current-buffer notice
                 (let ((inhibit-read-only t))
                   (erase-buffer)
                   (insert "Assist threads could not be loaded.\n"
                           "Reconnect, then use C-c C-a r to retry.\n"))))
             (message "Thread refresh failed: %s" error))
         (setq emacos-assist-web--catalog (alist-get 'threads value))
         (setq emacos-assist-web--catalog-stale nil)
         (emacos-assist-web--write-cache emacos-assist-web--catalog-file value)
         (when (buffer-live-p notice)
           (with-current-buffer notice
             (let ((inhibit-read-only t))
               (erase-buffer)
               (insert "Assist threads are ready.\nUse C-c C-a t to choose one.\n"))))
         (message "Threads updated. Open Threads to choose one."))))))

(defun emacos-assist-web--load-catalog ()
  "Load catalog cache once at mode startup."
  (unless emacos-assist-web--catalog
    (when-let ((cached (emacos-assist-web--read-cache emacos-assist-web--catalog-file)))
      (setq emacos-assist-web--catalog (alist-get 'threads cached)
            emacos-assist-web--catalog-stale t))))

(defun emacos-assist-web-refresh-thread (&optional buffer)
  "Fetch and render BUFFER's canonical thread snapshot asynchronously."
  (interactive)
  (let ((buffer (or buffer (current-buffer))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when emacos-assist-web--thread-id
          (let ((tid (emacos-assist-web--require-id emacos-assist-web--thread-id))
                (generation (cl-incf emacos-assist-web--refresh-generation)))
            (emacos-assist-web--request
             "GET" (concat "threads/" tid) nil
             (lambda (value error)
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (when (= generation emacos-assist-web--refresh-generation)
                     (if error
                         (message "Thread refresh failed: %s" error)
                       (condition-case problem
                           (progn
                             (unless (equal tid
                                            (emacos-assist-web--require-id
                                             (alist-get 'id (alist-get 'thread value))))
                               (error "Assist Web snapshot identity does not match request"))
                             (emacos-assist-web--write-cache
                              (emacos-assist-web--snapshot-cache-name tid) value)
                             (emacos-assist-web--render value))
                         (error
                          (message "Thread refresh rejected: %s"
                                   (error-message-string problem))))))))))))))))

(defun emacos-assist-web-load-older ()
  "Load one older bounded page of this thread's canonical visible history."
  (interactive)
  (if (not emacos-assist-web--thread-id)
      (message "This draft has no history")
    (let* ((tid (emacos-assist-web--require-id emacos-assist-web--thread-id))
           (name (emacos-assist-web--snapshot-cache-name tid))
           (cached (or emacos-assist-web--snapshot
                       (emacos-assist-web--read-cache name)))
           (before (and cached (alist-get 'next_before cached)))
           (buffer (current-buffer))
           (generation (cl-incf emacos-assist-web--refresh-generation)))
      (if (not before)
          (message "No older messages are available")
        (emacos-assist-web--request
         "GET" (format "threads/%s/history?before=%s" tid (url-hexify-string before)) nil
         (lambda (page error)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (when (and (= generation emacos-assist-web--refresh-generation)
                          (equal before (alist-get 'next_before
                                                   (or emacos-assist-web--snapshot cached))))
                 (if error
                     (message "Older history failed: %s" error)
                   (let ((updated (copy-tree (or emacos-assist-web--snapshot cached))))
                     (setf (alist-get 'messages updated)
                           (append (alist-get 'messages page)
                                   (alist-get 'messages updated))
                           (alist-get 'has_older_messages updated)
                           (alist-get 'has_older_messages page)
                           (alist-get 'next_before updated)
                           (alist-get 'next_before page))
                     (emacos-assist-web--write-cache name updated)
                     (emacos-assist-web--render updated))))))))))))

(defun emacos-assist-web--new-idempotency-key ()
  "Mint one opaque retry key; it is persisted in the buffer while pending."
  (concat "emacsos-" (md5 (format "%s-%s-%s" (float-time) (random) (emacs-pid)))))

(defun emacos-assist-web-send ()
  "Send this buffer's prompt to its canonical web thread exactly once."
  (interactive)
  (let ((text (or emacos-assist-web--submitted-text
                  (emacos-assist-web--input))))
    (cond
     ((not (derived-mode-p 'emacos-assist-web-mode))
      (message "Open an Assist Web thread before sending"))
     ((or (not (stringp text)) (string-empty-p text)) (message "Nothing to send"))
     (emacos-assist-web--in-flight (message "A web-thread request is already running"))
     ((and emacos-assist-web--active-buffer
           (not (eq emacos-assist-web--active-buffer (current-buffer))))
      (message "Another Assist Web request is still being observed"))
     (t
      (let ((generation (cl-incf emacos-assist-web--send-generation)))
	(setq emacos-assist-web--in-flight t
              emacos-assist-web--active-buffer (current-buffer)
              emacos-assist-web--pending-key (or emacos-assist-web--pending-key
						 (emacos-assist-web--new-idempotency-key))
              emacos-assist-web--submitted-text text
              ;; Until POST returns there is no current run to cancel.  Keeping a
              ;; completed prior run here lets Abort target the wrong operation.
              emacos-assist-web--run-id nil)
	(emacos-assist-web--save-draft)
	(let ((buffer (current-buffer))
              (key (emacos-assist-web--require-idempotency-key
                    emacos-assist-web--pending-key))
              (path nil) (payload nil))
          (if emacos-assist-web--thread-id
              (setq path (concat "threads/" (emacos-assist-web--require-id
                                             emacos-assist-web--thread-id)
				 "/messages")
                    payload `((message . ,text)))
            (setq path "threads"
                  payload `((message . ,text)
                            (repo_key . ,emacos-assist-web--draft-repository)
                            (harness . ,(or emacos-assist-web--draft-harness "deepagents")))))
          (emacos-assist-web--request
           "POST" path payload
           (lambda (value error)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
		 (when (and (= generation emacos-assist-web--send-generation)
                            emacos-assist-web--in-flight
                            (equal key emacos-assist-web--pending-key))
                   (if error
                       (progn
			 (setq emacos-assist-web--in-flight nil)
			 (when (eq emacos-assist-web--active-buffer buffer)
                           (setq emacos-assist-web--active-buffer nil))
			 (message "Send failed. Retry keeps the same message: %s" error))
                     (condition-case problem
			 (let ((thread-id
				(emacos-assist-web--require-id
				 (alist-get 'thread_id value)))
                               (run-id
				(emacos-assist-web--require-id
				 (alist-get 'run_id value))))
                           (setq emacos-assist-web--thread-id thread-id
				 emacos-assist-web--run-id run-id)
                           (if (alist-get 'replayed value)
                               (emacos-assist-web-refresh-thread buffer)
                             (emacos-assist-web--append-pending text))
                           (emacos-assist-web--save-draft)
                           (emacos-assist-web--observe-run buffer))
                       (error
			(setq emacos-assist-web--in-flight nil)
			(when (eq emacos-assist-web--active-buffer buffer)
                          (setq emacos-assist-web--active-buffer nil))
			(message "Send response rejected. Retry is safe: %s"
				 (error-message-string problem)))))))))
           `(("Idempotency-Key" . ,key)))))))))

(defun emacos-assist-web--append-pending (text)
  "Commit sent TEXT to this transcript while preserving a newly typed draft."
  (let ((draft (emacos-assist-web--input))
        (prompt-start (emacos-assist-web--prompt-start))
        (inhibit-read-only t))
    (when prompt-start
      (delete-region prompt-start (point-max))
      (let ((start (point)))
        (insert "\nyou> " text "\n\nbot> [waiting for Assist]\n")
        (add-text-properties start (point)
                             '(read-only t front-sticky t rear-nonsticky t)))
      (emacos-assist-web--write-prompt)
      (when (and draft (not (equal draft text))) (insert draft))
      (goto-char (point-max)))))

(defun emacos-assist-web-abort ()
  "Abort an unclaimed run, or honestly detach if Assist has already started it."
  (interactive)
  (if (not (and emacos-assist-web--thread-id emacos-assist-web--run-id
                emacos-assist-web--in-flight))
      (message (if emacos-assist-web--in-flight
                   "Assist is still accepting this message"
                 "No Assist run is being observed"))
    (let ((buffer (current-buffer))
          (path (format "threads/%s/runs/%s"
                        (emacos-assist-web--require-id emacos-assist-web--thread-id)
                        (emacos-assist-web--require-id emacos-assist-web--run-id))))
      ;; Detach before the cancellation request: a network outage must not hold
      ;; the one active-run slot hostage.  Assist remains canonical either way.
      (emacos-assist-web--stream-cleanup)
      (message "Stopped watching this Assist run")
      (emacos-assist-web--request
       "DELETE" path nil
       (lambda (_value error)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (if error
                 (message "Assist had already started; stopped watching it")
               (message "Queued Assist run cancelled"))
             (emacos-assist-web-refresh-thread buffer))))))))

(defun emacos-assist-web--new-thread-from-catalog (cache)
  "Choose a repository and harness from CACHE, then open a local draft."
  (let* ((repositories (alist-get 'repositories cache))
         (labels (mapcar (lambda (repo) (alist-get 'label repo)) repositories))
         (selected (and labels (completing-read "Repository: " labels nil t nil nil (car labels))))
         (repo (seq-find (lambda (item) (equal selected (alist-get 'label item))) repositories))
         (harnesses (alist-get 'harnesses cache))
         (harness-labels (mapcar (lambda (harness) (alist-get 'label harness)) harnesses))
         (selected-harness
          (and harness-labels
               (completing-read "Harness: " harness-labels nil t nil nil (car harness-labels))))
         (harness (seq-find (lambda (item)
                              (equal selected-harness (alist-get 'label item))) harnesses))
         (buffer (generate-new-buffer "*assist New thread*")))
    (if (not (and repo harness))
        (progn (kill-buffer buffer)
               (message "Refresh thread catalog before creating a thread"))
      (with-current-buffer buffer
        (emacos-assist-web-mode)
        (setq emacos-assist-web--draft-id (emacos-assist-web--new-idempotency-key)
              emacos-assist-web--draft-repository (alist-get 'repo_key repo)
              emacos-assist-web--draft-harness (alist-get 'key harness))
        (let ((inhibit-read-only t))
          (insert (format "*assist New thread - %s*\n[%s local draft]\n\n"
                          selected selected-harness))
          (emacos-assist-web--write-prompt)))
      (switch-to-buffer buffer))))

(defun emacos-assist-web-new-thread ()
  "Create a local draft, fetching repository choices on first use if needed."
  (interactive)
  (let ((cache (emacos-assist-web--read-cache emacos-assist-web--catalog-file)))
    (if (and (alist-get 'repositories cache) (alist-get 'harnesses cache))
        (emacos-assist-web--new-thread-from-catalog cache)
      (message "Fetching repositories for a new Assist thread…")
      (emacos-assist-web--request
       "GET" "threads" nil
       (lambda (value error)
         (if error
             (message "Cannot create a thread until repository choices load: %s" error)
           (setq emacos-assist-web--catalog (alist-get 'threads value))
           (setq emacos-assist-web--catalog-stale nil)
           (emacos-assist-web--write-cache emacos-assist-web--catalog-file value)
           (emacos-assist-web--new-thread-from-catalog value)))))))

(define-derived-mode emacos-assist-web-mode text-mode "Assist Web"
  "Major mode for a canonical Assist Web thread or unsent local draft."
  (variable-pitch-mode 1)
  (setq-local truncate-lines nil)
  (add-hook 'after-change-functions #'emacos-assist-web--after-change nil t)
  (add-hook 'kill-buffer-hook #'emacos-assist-web--buffer-killed nil t))

;; C-c C-a is this package's user-reserved command prefix.  Every non-object
;; action is also reachable through M-x; the touch UI does not grow a parallel
;; command-button surface.
(defvar emacos-assist-web-command-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "t") #'emacos-assist-web-open-thread)
    (define-key map (kbd "n") #'emacos-assist-web-new-thread)
    (define-key map (kbd "r") #'emacos-assist-web-refresh-threads)
    (define-key map (kbd "s") #'emacos-assist-web-send)
    (define-key map (kbd "o") #'emacos-assist-web-load-older)
    (define-key map (kbd "a") #'emacos-assist-web-abort)
    map)
  "Prefix bindings for Assist Web commands.")

(global-set-key (kbd "C-c C-a") emacos-assist-web-command-map)

(emacos-assist-web--load-catalog)

(provide 'assist-web)
;;; assist-web.el ends here
