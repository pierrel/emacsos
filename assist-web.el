;;; assist-web.el --- Assist Web threads in EmacsOS -*- lexical-binding: t -*-
;;; Commentary:

;; This is deliberately separate from emacsos-assist.el.  A .assist file is a
;; phone-local conversation owned by emacsos-server; this mode is a client of
;; Assist Web's canonical thread/run state.

;;; Code:

(require 'cl-lib)
(require 'chat)
(require 'assist-web-git)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'ucs-normalize)
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

(defcustom emacsos-assist-web-max-stream-chunk-bytes (* 1024 1024)
  "Maximum bytes in one raw callback or one declared decoded HTTP chunk."
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
  "Maximum simultaneous bounded requests and pre-header SSE handshakes."
  :type 'integer
  :group 'emacsos-assist-web)

(defconst emacsos-assist-web--prompt "\n> ")
(defconst emacsos-assist-web--catalog-file "threads.json")
(defconst emacsos-assist-web--thread-list-buffer-name "*assist Threads*")
(defconst emacsos-assist-web--max-catalog-items 500
  "Maximum entries accepted in each Assist catalog section.")
(defconst emacsos-assist-web--max-catalog-text-bytes 512
  "Maximum UTF-8 bytes accepted in one Assist display metadata field.")
(defconst emacsos-assist-web--max-message-bytes (* 256 1024)
  "Maximum UTF-8 bytes accepted in one canonical thread message.")
(defconst emacsos-assist-web--max-snapshot-messages 500
  "Maximum messages accepted in one snapshot or loaded-history state.")
(defconst emacsos-assist-web--max-snapshot-transcript-bytes (* 1024 1024)
  "Maximum message-text bytes accepted in one snapshot or history state.")
(defconst emacsos-assist-web--max-rendered-messages 1000
  "Maximum messages retained when a recent page preserves loaded history.")
(defconst emacsos-assist-web--max-rendered-transcript-bytes (* 2 1024 1024)
  "Maximum message-text bytes retained across recent and loaded history.")
(defconst emacsos-assist-web--active-snapshot-statuses
  '("queued" "processing" "paused" "initializing" "cloning"
    "starting_sandbox" "pending" "running" "transitioning"
    "awaiting_approval")
  "Snapshot statuses that prove work is still active.")
(defconst emacsos-assist-web--settled-snapshot-statuses '("ready" "error")
  "Snapshot statuses that may settle an accepted local submission.")
(defconst emacsos-assist-web--list-ordinal-width 5
  "Columns reserved for a trusted thread-list collision ordinal.")
(defconst emacsos-assist-web--id-regexp "\\`[A-Za-z0-9][A-Za-z0-9._-]\\{0,127\\}\\'")
(defconst emacsos-assist-web--record-id-regexp
  "\\`[A-Za-z0-9_-]\\{1,242\\}\\'")
(defconst emacsos-assist-web--idempotency-regexp "\\`emacsos-[0-9a-f]\\{32\\}\\'")
(defconst emacsos-assist-web--git-repo-key-regexp "\\`[0-9a-f]\\{20\\}\\'")
(defconst emacsos-assist-web--git-oid-regexp
  "\\`\\(?:[0-9a-f]\\{40\\}\\|[0-9a-f]\\{64\\}\\)\\'")
(defconst emacsos-assist-web--subdivision-flags
  (mapcar
   (lambda (tag)
     (concat (string #x1f3f4)
             (apply #'string (mapcar (lambda (character) (+ #xe0000 character)) tag))
             (string #xe007f)))
   '("gbeng" "gbsct" "gbwls"))
  "The only RGI subdivision flags accepted in Assist transcript text.")
(defvar emacsos-assist-web--catalog nil)
(defvar emacsos-assist-web--catalog-state nil
  "Current catalog state.
The value is nil, `current', `cached', `refresh-failed', or
`cache-write-failed'.")
(defvar emacsos-assist-web--catalog-refreshing-p nil)
(defvar emacsos-assist-web--catalog-generation 0)
(defvar emacsos-assist-web--new-thread-pending-p nil)
(defvar emacsos-assist-web--requests nil)
(defvar-local emacsos-assist-web--queue nil
  "Ordered resident submission records for this canonical thread buffer.")
(defvar-local emacsos-assist-web--queue-model-p nil
  "Non-nil once this buffer has entered the entry-owned queue model.")
(defvar-local emacsos-assist-web--legacy-terminal-generation 0
  "Serial for queue-free exact Run checks before canonical retirement.")
(defvar-local emacsos-assist-web--post-entry nil
  "The one entry whose POST acknowledgement is in flight in this buffer.")
(defvar-local emacsos-assist-web--stream-entry nil
  "The one entry whose SSE observer is active in this buffer.")
(defvar-local emacsos-assist-web--prompt-refusal nil
  "Fixed local refusal for the current unchanged editable draft.")
(defvar-local emacsos-assist-web--collision-p nil
  "Non-nil while an adopted queue must contract before new sends.")
(defvar-local emacsos-assist-web--passive-recovery-invalid-p nil
  "Non-nil when provisional canonical recovery must fail closed.")
(defvar-local emacsos-assist-web--recovery-draft nil
  "A bounded source draft retained during canonical-buffer adoption.")
(defvar-local emacsos-assist-web--recovery-action-marker nil
  "Marker for the one visible action that restores a retained source draft.")
(defvar-local emacsos-assist-web--recovery-action-start nil
  "Start marker for the one visible action that restores a retained source draft.")
(defvar-local emacsos-assist-web--thread-id nil)
(defvar-local emacsos-assist-web--draft-repository nil)
(defvar-local emacsos-assist-web--draft-harness nil)
(defvar-local emacsos-assist-web--run-id nil)
(defvar-local emacsos-assist-web--pending-key nil)
(defvar-local emacsos-assist-web--in-flight nil)
(defvar-local emacsos-assist-web--follow-ups nil
  "Ordered, locally durable follow-ups behind this buffer's active request.")
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
(defvar-local emacsos-assist-web--reconcile-generation nil
  "Shared refresh generation owned by an in-flight queue retirement GET.")
(defvar-local emacsos-assist-web--reconcile-recovery-paused nil
  "Non-nil when failed queue restoration requires a fresh Emacs session.")
(defvar-local emacsos-assist-web--manual-recovery-required nil
  "Non-nil when a restored terminal Run needs explicit exact verification.")
(defvar-local emacsos-assist-web--manual-recovery-active nil
  "Non-nil during the one recovery pass begun by explicit Refresh.")
(defvar-local emacsos-assist-web--manual-recovery-reason nil
  "Short stopped-pass reason for the phone header and Details action.")
(defvar-local emacsos-assist-web--display-recovery nil
  "Non-nil after canonical history commits but its presentation fails.")
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
(defvar-local emacsos-assist-web--stream-raw-bytes nil)
(defvar-local emacsos-assist-web--stream-undecided-suffix nil)

(defun emacsos-assist-web--follow-up-value (text key)
  "Return the durable queue value for TEXT and its immutable KEY."
  `((text . ,text) (key . ,key)))

(defun emacsos-assist-web--queue-follow-up (text)
  "Durably queue TEXT behind this buffer's active request.

The normal resident bound is the active request plus one follow-up."
  (cond
   ((consp emacsos-assist-web--follow-ups)
    (emacsos-assist-web--set-status "queue full; message remains in draft")
    nil)
   ((or (> (length text) 64000)
        (> (string-bytes (json-encode `((message . ,text)))) 66000))
    (emacsos-assist-web--set-status "message too large; message remains in draft")
    nil)
   (t
    (let ((key (emacsos-assist-web--new-idempotency-key)))
      (setq emacsos-assist-web--follow-ups
            (list (emacsos-assist-web--follow-up-value text key)))
      (if (emacsos-assist-web--save-draft)
          (progn
            (emacsos-assist-web--replace-input "")
            (emacsos-assist-web--set-status "follow-up queued")
            t)
        (setq emacsos-assist-web--follow-ups nil)
        (emacsos-assist-web--set-status "not sent; local draft could not be saved")
        nil)))))

(defun emacsos-assist-web--start-follow-up ()
  "Durably claim the oldest legacy follow-up and attempt its saved-key send."
  (when-let* ((next (car emacsos-assist-web--follow-ups))
              (text (alist-get 'text next))
              (key (alist-get 'key next)))
    (if (let ((emacsos-assist-web--follow-ups
               (cdr emacsos-assist-web--follow-ups))
              (emacsos-assist-web--pending-key key)
              (emacsos-assist-web--submitted-text text)
              (emacsos-assist-web--pending-accepted-p nil)
              (emacsos-assist-web--run-id nil))
          (emacsos-assist-web--legacy-save-draft))
        (progn
          (setq emacsos-assist-web--follow-ups (cdr emacsos-assist-web--follow-ups))
          (setq emacsos-assist-web--pending-key key
                emacsos-assist-web--submitted-text text
                emacsos-assist-web--pending-accepted-p nil
                emacsos-assist-web--run-id nil
                emacsos-assist-web--pending-rendered-p nil)
          (emacsos-assist-web--legacy-send)
          (when (and (not emacsos-assist-web--in-flight)
                     (equal emacsos-assist-web--pending-key key))
            (emacsos-assist-web--set-status
             "follow-up ready; Send retries"))
          t)
      (emacsos-assist-web--set-status
       "follow-up ready; Send retries after local save failure"))))

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

(defun emacsos-assist-web--read-cache (name &optional array-type object-type)
  "Return parsed JSON cache NAME, or nil when no valid cache exists.
ARRAY-TYPE defaults to `list' and OBJECT-TYPE defaults to `alist'."
  (condition-case nil
      (let ((path (emacsos-assist-web--cache-path name)))
        (when (and (file-readable-p path)
                   (<= (file-attribute-size (file-attributes path))
                       emacsos-assist-web-max-cache-bytes))
          (with-temp-buffer
            (insert-file-contents path)
            (json-parse-buffer :object-type (or object-type 'alist)
                               :array-type (or array-type 'list)
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

(defun emacsos-assist-web--valid-catalog-text-p (value)
  "Return non-nil for bounded, single-line catalog or snapshot display VALUE."
  (and (stringp value)
       (<= (string-bytes value) emacsos-assist-web--max-catalog-text-bytes)
       (emacsos-conversation-valid-text-p value)))

(defun emacsos-assist-web--canonical-message-text (value)
  "Canonicalize line endings in transcript VALUE without changing other text."
  (string-replace "\r" "\n" (string-replace "\r\n" "\n" value)))

(defun emacsos-assist-web--message-validation-text (value)
  "Return VALUE with only complete allowed subdivision flags masked for validation."
  (dolist (flag emacsos-assist-web--subdivision-flags value)
    (setq value (string-replace flag (string #x1f3f4) value))))

(defun emacsos-assist-web--valid-message-text-p (value)
  "Return non-nil for canonical multiline transcript VALUE without spoofing controls."
  (and (stringp value)
       (emacsos-conversation-valid-text-p
        (emacsos-assist-web--message-validation-text value) t)))

(defun emacsos-assist-web--isolate-display-text (text)
  "Return server-supplied TEXT inside trusted bidirectional isolates."
  (concat (string #x2068) text (string #x2069)))

(defun emacsos-assist-web--collision-key-text (text)
  "Return normalized TEXT with admitted zero-width emoji marks removed."
  (ucs-normalize-NFC-string
   (string-replace (string #x200d) ""
                   (string-replace (string #xfe0f) "" text))))

(defun emacsos-assist-web--catalog-entry (value fields)
  "Return wire catalog object VALUE normalized to symbol FIELDS."
  (when (hash-table-p value)
    (mapcar (lambda (field)
              (cons field (gethash (symbol-name field) value)))
            fields)))

(defun emacsos-assist-web--require-catalog (value)
  "Validate wire catalog VALUE and return its arrays normalized to lists."
  (unless (hash-table-p value)
    (error "Assist Web returned an invalid catalog"))
  (let ((wire-threads (gethash "threads" value))
        (wire-repositories (gethash "repositories" value))
        (wire-harnesses (gethash "harnesses" value)))
    (unless (and (vectorp wire-threads)
                 (vectorp wire-repositories)
                 (vectorp wire-harnesses)
                 (cl-every
                  (lambda (items)
                    (<= (length items) emacsos-assist-web--max-catalog-items))
                  (list wire-threads wire-repositories wire-harnesses)))
      (error "Assist Web returned an invalid catalog"))
    (let ((threads
           (mapcar (lambda (entry)
                     (emacsos-assist-web--catalog-entry
                      entry '(id description search_description repo_label status)))
                   (append wire-threads nil)))
          (repositories
           (mapcar (lambda (entry)
                     (emacsos-assist-web--catalog-entry entry '(repo_key label)))
                   (append wire-repositories nil)))
          (harnesses
           (mapcar (lambda (entry)
                     (emacsos-assist-web--catalog-entry entry '(key label)))
                   (append wire-harnesses nil)))
          (seen (make-hash-table :test #'equal)))
      (cl-labels
          ((require-choices
            (choices key-field noun)
            (clrhash seen)
            (dolist (choice choices)
              (let ((key (and (emacsos-assist-web--object-p choice)
                              (alist-get key-field choice))))
                (unless (and (emacsos-assist-web--valid-id-p key)
                             (not (gethash key seen))
                             (emacsos-assist-web--valid-catalog-text-p
                              (alist-get 'label choice)))
                  (error "Assist Web returned an invalid %s choice" noun))
                (puthash key t seen)))))
        (dolist (thread threads)
          (let ((id (and (emacsos-assist-web--object-p thread)
                         (alist-get 'id thread))))
            (unless (and (emacsos-assist-web--valid-id-p id)
                         (not (gethash id seen))
                         (emacsos-assist-web--valid-catalog-text-p
                          (alist-get 'description thread))
                         (emacsos-assist-web--valid-catalog-text-p
                          (alist-get 'search_description thread))
                         (emacsos-assist-web--valid-catalog-text-p
                          (alist-get 'repo_label thread))
                         (emacsos-assist-web--valid-catalog-text-p
                          (alist-get 'status thread)))
              (error "Assist Web returned an invalid thread catalog entry"))
            (puthash id t seen)))
        (require-choices repositories 'repo_key "repository")
        (require-choices harnesses 'key "harness"))
      `((threads . ,threads)
        (repositories . ,repositories)
        (harnesses . ,harnesses)))))

(defun emacsos-assist-web--require-transcript-limits
    (messages max-messages max-bytes)
  "Require raw MESSAGES to fit MAX-MESSAGES, MAX-BYTES, and message caps."
  (let ((remaining messages)
        (count 0)
        (total 0))
    (while (consp remaining)
      (setq count (1+ count))
      (when (> count max-messages)
        (error "Assist Web thread transcript is too large"))
      (let* ((message (car remaining))
             (text (and (emacsos-assist-web--object-p message)
                        (alist-get 'text message))))
        (unless (stringp text)
          (error "Assist Web returned an invalid thread message"))
        (let ((bytes (string-bytes text)))
          (when (> bytes emacsos-assist-web--max-message-bytes)
            (error "Assist Web thread message is too large"))
          (setq total (+ total bytes))
          (when (> total max-bytes)
            (error "Assist Web thread transcript is too large"))))
      (setq remaining (cdr remaining)))
    (unless (null remaining)
      (error "Assist Web returned an invalid thread transcript"))))

(defun emacsos-assist-web--canonicalize-transcript (messages max-bytes)
  "Return canonical copies of MESSAGES within MAX-BYTES."
  (let ((canonical nil)
        (total 0))
    (dolist (message messages (nreverse canonical))
      (let* ((text (emacsos-assist-web--canonical-message-text
                    (alist-get 'text message)))
             (bytes (string-bytes text)))
        (unless (emacsos-assist-web--valid-message-text-p text)
          (error "Assist Web returned an invalid thread message"))
        (when (> bytes emacsos-assist-web--max-message-bytes)
          (error "Assist Web thread message is too large"))
        (setq total (+ total bytes))
        (when (> total max-bytes)
          (error "Assist Web thread transcript is too large"))
        (let ((copy (copy-tree message)))
          (setf (alist-get 'text copy) text)
          (push copy canonical))))))

(defun emacsos-assist-web--require-snapshot
    (value &optional expected-thread-id max-messages max-bytes)
  "Return validated snapshot VALUE for EXPECTED-THREAD-ID when supplied.
MAX-MESSAGES and MAX-BYTES override the ordinary wire-snapshot limits."
  (let ((thread (and (emacsos-assist-web--object-p value)
                     (alist-get 'thread value)))
        (messages (and (emacsos-assist-web--object-p value)
                       (alist-get 'messages value))))
    (unless (and (emacsos-assist-web--object-p thread)
                 (assq 'messages value)
                 (emacsos-assist-web--valid-id-p (alist-get 'id thread))
                 (emacsos-assist-web--valid-catalog-text-p
                  (alist-get 'description thread))
                 (emacsos-assist-web--valid-catalog-text-p
                  (alist-get 'status thread))
                 (let ((remote-error (alist-get 'error thread)))
                   (or (null remote-error)
                       (emacsos-assist-web--valid-catalog-text-p remote-error)))
                 (emacsos-assist-web--object-p (alist-get 'workspace thread))
                 (emacsos-assist-web--valid-catalog-text-p
                  (alist-get 'repo_label (alist-get 'workspace thread))))
      (error "Assist Web returned an invalid thread snapshot"))
    (when (and expected-thread-id
               (not (equal expected-thread-id (alist-get 'id thread))))
      (error "Assist Web snapshot identity does not match request"))
    (let ((limit-messages (or max-messages emacsos-assist-web--max-snapshot-messages))
          (limit-bytes (or max-bytes emacsos-assist-web--max-snapshot-transcript-bytes)))
      (emacsos-assist-web--require-transcript-limits messages limit-messages limit-bytes)
      (setq messages
            (emacsos-assist-web--canonicalize-transcript
             messages limit-bytes)))
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
    ;; Retain only the message schema this client consumes.  Remote extensions
    ;; cannot accumulate across otherwise bounded history pages.
    (setq messages
          (mapcar
           (lambda (message)
             `((id . ,(alist-get 'id message))
               (role . ,(alist-get 'role message))
               (text . ,(alist-get 'text message))
               (state . ,(alist-get 'state message))))
           messages))
    (setf (alist-get 'messages value) messages)
    (when-let ((cursor (alist-get 'next_before value)))
      (emacsos-assist-web--require-record-id cursor))
    value))

(defun emacsos-assist-web-git--metadata-from-snapshot (snapshot)
  "Select the authenticated committed ref from validated SNAPSHOT.

Ready threads select their actual checkout; all other statuses select only the
atomic last-published pair.  Git itself checks the selected ref format before
the fetch begins."
  (let* ((thread (alist-get 'thread snapshot))
         (workspace (alist-get 'workspace thread))
         (tid (emacsos-assist-web--require-id (alist-get 'id thread)))
         (status (alist-get 'status thread))
         (repo-key (alist-get 'repo_key workspace))
         (actual-branch (alist-get 'branch workspace))
         (head (alist-get 'revision workspace))
         (published-branch (alist-get 'published_branch workspace))
         (published-revision (alist-get 'published_revision workspace)))
    (unless (or (null repo-key)
                (and (stringp repo-key)
                     (string-match-p
                      emacsos-assist-web--git-repo-key-regexp repo-key)))
      (error "Assist Web returned an invalid Git repository key"))
    (dolist (oid (list head published-revision))
      (unless (or (null oid)
                  (and (stringp oid)
                       (string-match-p emacsos-assist-web--git-oid-regexp oid)))
        (error "Assist Web returned an invalid Git object ID")))
    (unless (or (and (null published-branch)
                     (null published-revision))
                (and (stringp published-branch)
                     (stringp published-revision)))
      (error "Assist Web returned an incomplete published Git ref"))
    (when (equal published-branch "HEAD")
      (error "Assist Web returned detached HEAD as a published Git ref"))
    (let* ((ready (equal status "ready"))
           (branch (if ready actual-branch published-branch))
           (expected (if ready head published-revision)))
      (when (and branch
                 (not (and (stringp branch)
                           (<= (string-bytes branch) 240)
                           (not (string-match-p "[[:cntrl:]]" branch)))))
        (error "Assist Web returned an invalid Git branch"))
      (list :tid tid :repo-key repo-key
            :branch (and (stringp branch)
                         (not (equal branch "main"))
                         (not (equal branch "HEAD"))
                         branch)
            :expected expected :status status
            :actual-branch (and ready actual-branch)
            :head head))))

(defun emacsos-assist-web-git--note-snapshot
    (snapshot &optional legacy-success-run-id auth-start-epoch reconcile-token)
  "Update optional Git state from validated SNAPSHOT without rejecting chat.
LEGACY-SUCCESS-RUN-ID is an exact successful Run retired by the legacy path.
AUTH-START-EPOCH permits only a post-denial accepted canonical GET to clear
the Git denial latch.  RECONCILE-TOKEN identifies an eligible committed
post-conflict canonical read."
  (condition-case nil
      (let ((metadata (emacsos-assist-web-git--metadata-from-snapshot snapshot)))
        (emacsos-assist-web-git--canonical-authorized auth-start-epoch)
        (unless emacsos-assist-web-git--denied
          (emacsos-assist-web-git--canonical-accepted
           metadata legacy-success-run-id reconcile-token)
          (when (equal (plist-get metadata :actual-branch) "HEAD")
            (setq emacsos-assist-web-git--unavailable
                  "detached HEAD; Git unavailable")
            (emacsos-assist-web-git--update-headers))))
    (error
     (unless emacsos-assist-web-git--denied
       (condition-case nil
           (emacsos-assist-web-git--invalidate "Git state unavailable")
         ((error quit) nil))))))

(defun emacsos-assist-web--git-note-safely (&rest args)
  "Project optional Git state from ARGS without undoing committed chat state."
  (condition-case nil
      (apply #'emacsos-assist-web-git--note-snapshot args)
    ((error quit)
     (unless emacsos-assist-web-git--denied
       (condition-case nil
           (emacsos-assist-web-git--invalidate "Git state unavailable")
         ((error quit) nil))))))

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

(defun emacsos-assist-web--snapshot-active-p (snapshot)
  "Return non-nil when SNAPSHOT is active, or reject an unknown status.

An unknown bounded display string is not proof that an accepted Run settled."
  (let ((status (alist-get 'status (alist-get 'thread snapshot))))
    (cond
     ((member status emacsos-assist-web--active-snapshot-statuses) t)
     ((member status emacsos-assist-web--settled-snapshot-statuses) nil)
     (t (error "Assist Web returned an unknown thread status")))))

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

(defun emacsos-assist-web--sse-content-type-p (value)
  "Return whether VALUE is the supported SSE media type.
Only an optional UTF-8 charset parameter may follow the exact subtype."
  (and (stringp value)
       (string-match-p
        "\\`text/event-stream\\(?:[ \t]*;[ \t]*charset=\\(?:utf-8\\|\\\"utf-8\\\"\\)\\)?[ \t]*\\'"
        (downcase value))))

(defun emacsos-assist-web--response-json
    (buffer &optional allow-status array-type object-type)
  "Return BUFFER's JSON value or signal a useful local error.
When ALLOW-STATUS is non-nil, require an integer HTTP status and a top-level
object, retaining that status as `http_status' so the submission adapter can
classify a bounded structured refusal without exposing its detail.  ARRAY-TYPE
defaults to `list' and OBJECT-TYPE defaults to `alist'."
  (with-current-buffer buffer
    (let ((status url-http-response-status)
          (start (and (boundp 'url-http-end-of-headers) url-http-end-of-headers)))
      (unless (and (integerp status)
                   (or (<= 200 status 299)
                       (and allow-status (<= 400 status 599))))
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
      (let ((value (json-parse-buffer :object-type (or object-type 'alist)
                                      :array-type (or array-type 'list)
                                      :null-object nil :false-object nil)))
        (skip-chars-forward " \t\r\n")
        (unless (eobp)
          (error "Assist Web returned an unexpected response body"))
        (if allow-status (cons (cons 'http_status status) value) value)))))

(defun emacsos-assist-web--exact-run-status (value tid run-id)
  "Return one known exact Run status for VALUE matching TID and RUN-ID.
Duplicate identity/status fields are invalid even when the first copy matches."
  (unless (and (listp value)
               (cl-every #'consp value)
               (= (cl-count 'id value :key #'car) 1)
               (= (cl-count 'thread_id value :key #'car) 1)
               (= (cl-count 'status value :key #'car) 1)
               (equal (alist-get 'id value) run-id)
               (equal (alist-get 'thread_id value) tid)
               (member (alist-get 'status value)
                       '("pending" "running" "transitioning"
                         "awaiting_approval" "success" "error" "timeout"
                         "interrupted" "cancelled")))
    (error "invalid exact Run response"))
  (alist-get 'status value))

(defun emacsos-assist-web--range-bytes (start end)
  "Return the byte length of the current buffer between START and END."
  (- (position-bytes end) (position-bytes start)))

(defun emacsos-assist-web--pending-transport-bytes (process)
  "Return opaque HTTP framing bytes retained for PROCESS's next decode step."
  (let ((response (and process (process-buffer process))))
    (if (not (buffer-live-p response))
        0
      (with-current-buffer response
        (if (not (and (boundp 'url-http-end-of-headers)
                      (markerp url-http-end-of-headers)))
            0
          (let* ((body-start (min (point-max)
                                  (1+ (marker-position url-http-end-of-headers))))
                 (decoded-end
                  (if (and (boundp 'url-http-transfer-encoding)
                           (equal url-http-transfer-encoding "chunked"))
                      (if (and (boundp 'url-http-chunked-start)
                               (markerp url-http-chunked-start)
                               (boundp 'url-http-chunked-length)
                               (integerp url-http-chunked-length))
                          (min (point-max)
                               (+ (marker-position url-http-chunked-start)
                                  url-http-chunked-length))
                        body-start)
                    ;; A fixed-length body is decoded as it arrives.  Its
                    ;; declared total is checked separately by the event
                    ;; filter, so none of these bytes are pending framing.
                    (point-max))))
            (emacsos-assist-web--range-bytes decoded-end (point-max))))))))

(defun emacsos-assist-web--guarded-filter
    (url-filter fail &optional streaming status-observer)
  "Wrap URL-FILTER with raw HTTP bounds, invoking FAIL with a safe message.

STREAMING permits an unbounded body only for a valid 200 SSE response; it
bounds every other response and each raw transport callback before URL-FILTER
retains it.  Decoded SSE records are bounded by the event filter.  Headers and
encoded responses are rejected before URL-FILTER can redirect or decompress
them.  STATUS-OBSERVER sees a bounded raw status prefix before any refusal;
nil or a signal leaves that status unacknowledged for a later bounded retry."
  (let ((received 0) (header "") (header-complete nil) (failed nil)
        (status-prefix "") (status-seen nil)
        (bounded-body (not streaming)))
    (lambda (process bytes)
      (unless failed
        (when (and status-observer (not status-seen)
                   (< (length status-prefix)
                      emacsos-assist-web-max-header-bytes))
          (setq status-prefix
                (concat status-prefix
                        (substring bytes 0 (min (length bytes)
                                                (- emacsos-assist-web-max-header-bytes
                                                   (length status-prefix))))))
          (let ((scan t))
            (while (and scan (not status-seen)
                        (string-match
                         "\\`HTTP/[0-9.]+[ \t]+\\([0-9][0-9][0-9]\\)[ \t\r\n]"
                         status-prefix))
              (let ((status (string-to-number
                             (match-string 1 status-prefix))))
                (if (and (<= 100 status) (< status 200))
                    (if-let ((end (string-match "\r?\n\r?\n" status-prefix)))
                        (setq status-prefix
                              (substring status-prefix (match-end 0)))
                      (setq scan nil))
                  (when (condition-case nil
                            (funcall status-observer status)
                          ((error quit) nil))
                    (setq status-seen t))
                  (setq scan nil))))))
        (when (and streaming
                   (> (string-bytes bytes)
                      emacsos-assist-web-max-stream-chunk-bytes))
          (setq failed t)
          (funcall fail process "Assist stream transport chunk is too large"))
        (unless failed
          (setq received (+ received (string-bytes bytes)))
          (when (and bounded-body
                     (> received emacsos-assist-web-max-response-bytes))
            (setq failed t)
            (funcall fail process "Assist Web response is too large"))
          (unless (or failed header-complete)
            (setq header (concat header bytes))
            (let ((header-end (string-match "\r?\n\r?\n" header)))
              (cond
               (header-end
                (let ((headers-only (substring header 0 (match-end 0))))
                  (cond
                   ((> (string-bytes headers-only)
                       emacsos-assist-web-max-header-bytes)
                    (setq failed t)
                    (funcall fail process
                             "Assist Web response headers are too large"))
                   ((string-match-p "\r?\n[ \t]" headers-only)
                    ;; Stock `url-http' includes obsolete continuation lines
                    ;; in its parsed field value.
                    ;; Reject them before our line-oriented admission checks
                    ;; can disagree with the decoder about transfer coding.
                    (setq failed t)
                    (funcall fail process
                             "Assist Web folded response headers are not accepted"))
                   (t
                    (setq header-complete t
                          bounded-body
                          (not (and streaming
                                    (string-match-p
                                     "\\`HTTP/[0-9.]+[ \\t]+200\\(?:[ \\t]\\|\\r?\\n\\)"
                                     headers-only)
                                    (let ((case-fold-search t))
                                      (string-match-p
                                       "\\(?:\\`\\|[\r\n]\\)Content-Type[ \t]*:[ \t]*text/event-stream\\(?:[; \t\r\n]\\|\\'\\)"
                                       headers-only)))))
                    (let ((case-fold-search t)
                          (position 0)
                          (transfer-count 0))
                      (while (and (not failed)
                                  (string-match
                                   "\\(?:\\`\\|[\r\n]\\)Content-Encoding[ \t]*:[ \t]*\\([^\r\n]*\\)"
                                   headers-only position))
                        (unless (equal (downcase
                                        (string-trim
                                         (match-string 1 headers-only)))
                                       "identity")
                          (setq failed t)
                          (funcall fail process
                                   "Assist Web encoded responses are not accepted"))
                        (setq position (match-end 0)))
                      (setq position 0)
                      (while (and (not failed)
                                  (string-match
                                   "\\(?:\\`\\|[\r\n]\\)Transfer-Encoding[ \t]*:[ \t]*\\([^\r\n]*\\)"
                                   headers-only position))
                        (cl-incf transfer-count)
                        (unless (and (= transfer-count 1)
                                     (equal (downcase
                                             (string-trim
                                              (match-string 1 headers-only)))
                                            "chunked"))
                          (setq failed t)
                          (funcall fail process
                                   "Assist Web transfer encoding is not accepted"))
                        (setq position (match-end 0))))))
                  (setq header nil)
                  (when (and (not failed) bounded-body
                             (> received emacsos-assist-web-max-response-bytes))
                    (setq failed t)
                    (funcall fail process "Assist Web response is too large"))))
               ((> (string-bytes header) emacsos-assist-web-max-header-bytes)
                (setq failed t)
                (funcall fail process
                         "Assist Web response headers are too large")))))
          (when (and (not failed) (functionp url-filter))
            (if (and streaming (not bounded-body))
                ;; Feed stock `url-http' bounded opaque slices.  Between
                ;; slices, cap bytes it has retained as incomplete transport
                ;; framing; this never parses chunk syntax outside url-http.
                (let ((offset 0)
                      (total (length bytes)))
                  (while (and (not failed) (< offset total))
                    (let* ((pending
                            (emacsos-assist-web--pending-transport-bytes process))
                           (allowance
                            (- emacsos-assist-web-max-header-bytes pending)))
                      (if (<= allowance 0)
                          (progn
                            (setq failed t)
                            (funcall fail process
                                     "Assist stream transport framing is too large"))
                        (let ((end (min total (+ offset allowance))))
                          (funcall url-filter process (substring bytes offset end))
                          (setq offset end))))))
              (funcall url-filter process bytes))))))))

(defun emacsos-assist-web--run-http-owner (method path)
  "Capture the exact resident Run owner of a GET before HTTP starts."
  (when (and (equal method "GET")
             (stringp path)
             (string-match "\\`threads/\\([^/]+\\)/runs/\\([^/]+\\)\\'" path))
    (let ((tid (match-string 1 path))
          (run-id (match-string 2 path)))
      (when (equal tid emacsos-assist-web--thread-id)
        (if-let ((entry (seq-find
                         (lambda (candidate)
                           (and (equal run-id (plist-get candidate :run-id))
                                (plist-get candidate :reobserve-in-flight)))
                         emacsos-assist-web--queue)))
            (progn
              (emacsos-assist-web-git--claim-orphaned-run-gate tid run-id)
              (list :kind 'queue :buffer (current-buffer) :tid tid :run-id run-id
                    :entry entry :generation
                    (plist-get entry :reobserve-generation)
                    :auth-start emacsos-assist-web-git--auth-epoch))
          (when (and emacsos-assist-web--pending-accepted-p
                     (equal run-id emacsos-assist-web--run-id))
            (emacsos-assist-web-git--claim-orphaned-run-gate tid run-id)
            (list :kind 'legacy :buffer (current-buffer) :tid tid :run-id run-id
                  :send-generation emacsos-assist-web--send-generation
                  :terminal-generation
                  emacsos-assist-web--legacy-terminal-generation
                  :auth-start emacsos-assist-web-git--auth-epoch)))))))

(defun emacsos-assist-web--run-http-owner-current-p (owner tid run-id)
  "Whether OWNER still holds the exact TID/RUN-ID at the HTTP header."
  (and owner
       (eq (plist-get owner :buffer) (current-buffer))
       (equal (plist-get owner :tid) tid)
       (equal (plist-get owner :run-id) run-id)
       (equal emacsos-assist-web--thread-id tid)
       (>= (plist-get owner :auth-start)
           emacsos-assist-web-git--thread-denial-floor)
       (pcase (plist-get owner :kind)
         ('queue
          (let ((entry (plist-get owner :entry)))
            (and (memq entry emacsos-assist-web--queue)
                 (equal run-id (plist-get entry :run-id))
                 (plist-get entry :reobserve-in-flight)
                 (eql (plist-get owner :generation)
                      (plist-get entry :reobserve-generation)))))
         ('legacy
          (and emacsos-assist-web--pending-accepted-p
               (equal run-id emacsos-assist-web--run-id)
               (eql (plist-get owner :send-generation)
                    emacsos-assist-web--send-generation)
               (eql (plist-get owner :terminal-generation)
                    emacsos-assist-web--legacy-terminal-generation))))))

(defun emacsos-assist-web--git-http-status
    (origin method path status &optional early-failure run-owner request-tid)
  "Tell ORIGIN's optional Git projection about thread or Run GET failure.
METHOD and PATH identify the exact endpoint.  STATUS is read before JSON
parsing, so a malformed denial body cannot hide a 401, 403, or 404.
EARLY-FAILURE belongs only to a chat-owned canonical request; a Git probe's
nondiagnostic failure must not invalidate another window's accepted state.
RUN-OWNER prevents a retired or superseded exact Run GET from relatching Git.
REQUEST-TID is the trusted origin thread captured before an async T GET; it
lets a definitive denial fence a live same-T peer if ORIGIN was killed.
Return non-nil when the Git safety notification completed or the exact Run
status is safely ignored as stale; nil permits a bounded later retry."
  (when (and (equal method "GET")
             (or (memq status '(401 403 404)) early-failure)
             (stringp path))
    (condition-case nil
        (let ((thread-get (string-match "\\`threads/\\([^/]+\\)\\'" path))
              (tid nil)
              (run-id nil))
          (if thread-get
              (setq tid (match-string 1 path))
            (when (and (memq status '(401 403 404))
                       (string-match "\\`threads/\\([^/]+\\)/runs/\\([^/]+\\)\\'" path))
              (setq tid (match-string 1 path)
                    run-id (match-string 2 path))))
          (let ((target
                 (cond
                  ((buffer-live-p origin) origin)
                  ((and (not run-id) (memq status '(401 403 404))
                        (equal tid request-tid))
                   (seq-find
                    (lambda (buffer)
                      (equal (buffer-local-value
                              'emacsos-assist-web--thread-id buffer) tid))
                    (buffer-list))))))
            (when target
              (with-current-buffer target
                (when (and tid (equal tid emacsos-assist-web--thread-id))
                  (cond
                   ((and run-id
                         (emacsos-assist-web--run-http-owner-current-p
                          run-owner tid run-id))
                    (emacsos-assist-web-git--run-access-uncertain status run-id)
                    t)
                   (run-id t)
                   ((memq status '(401 403 404))
                    (emacsos-assist-web-git--canonical-denied status)
                    t)
                   (t (emacsos-assist-web-git--canonical-uncertain)
                      t)))))))
      ((error quit) nil))))

(defun emacsos-assist-web--git-request-error (status kind &optional detail)
  "Return a bounded typed Git error for STATUS, KIND and local DETAIL.
The ordinary chat callback continues to receive its original error string."
  (list :kind (cond ((and (integerp status) (<= 400 status 599)) 'http)
                    ((memq detail '(busy timeout trust)) detail)
                    (t kind))
        :status (and (integerp status) status)
        :text (cond
               ((and (integerp status) (<= 400 status 599))
                (format "Assist Web request failed (%d)" status))
               ((eq kind 'credentials) "Assist Web credentials unavailable")
               ((eq kind 'parse) "Assist Web response invalid")
               ((eq detail 'busy) "Assist Web request budget is busy")
               ((eq detail 'timeout) "Assist Web request timed out")
               ((eq detail 'trust) "Assist Web TLS/trust failed")
               (t "Assist Web connection unavailable"))))

(defun emacsos-assist-web--request
    (method path payload callback &optional headers allow-status array-type object-type
            git-typed-error)
  "Send METHOD to PATH with optional JSON PAYLOAD and HEADERS.

Invoke CALLBACK with (VALUE ERROR).  Report network and parsing failures as
ERROR rather than raising them from url-http's asynchronous callback.  Pass
ALLOW-STATUS only for a bounded structured non-2xx response the caller owns.
ARRAY-TYPE defaults to `list' and OBJECT-TYPE defaults to `alist'.
GIT-TYPED-ERROR opts only this caller into a bounded (:kind :status :text)
error instead of the legacy string.  A Git probe's nondiagnostic failure
does not downgrade a separate chat-accepted Git observation."
  (let ((run-owner (emacsos-assist-web--run-http-owner method path))
        (request-tid (and (equal method "GET") emacsos-assist-web--thread-id))
        (canonical-thread-get
         (and (equal method "GET")
              emacsos-assist-web--thread-id
              (equal path (concat "threads/" emacsos-assist-web--thread-id))))
        token token-error)
    (condition-case error
        (setq token (emacsos-assist-web--read-token))
      ((error quit) (setq token-error (error-message-string error))))
    (if token-error
        (progn
          (emacsos-assist-web--git-http-status
           (current-buffer) method path nil (not git-typed-error) run-owner)
          (funcall callback nil
                   (if git-typed-error
                       (emacsos-assist-web--git-request-error
                        nil 'credentials)
                     token-error)))
      (if (not (emacsos-assist-web--safe-token-p token))
        (progn
          (emacsos-assist-web--git-http-status
           (current-buffer) method path nil (not git-typed-error) run-owner)
          (funcall callback nil
                   (if git-typed-error
                       (emacsos-assist-web--git-request-error
                        nil 'credentials)
                     "Assist Web token is missing or invalid")))
      ;; Invalid endpoints are a local, deterministic rejection.  Report one
      ;; even if unrelated requests presently consume the transport budget.
      (if (and (>= (length emacsos-assist-web--requests)
                  emacsos-assist-web-max-concurrent-requests)
               (condition-case nil
                   (progn (emacsos-assist-web--endpoint path) t)
                 (error nil)))
          (progn
            (emacsos-assist-web--git-http-status
             (current-buffer) method path nil (not git-typed-error) run-owner)
            (funcall callback nil
                     (if git-typed-error
                         (emacsos-assist-web--git-request-error
                          nil 'transport 'busy)
                       "Too many Assist Web requests are already running")))
        (let* ((url-request-method method)
               (url-request-extra-headers
		(append `(("Authorization" . ,(concat "Bearer " token))
                          ("Accept" . "application/json"))
			(when payload '(("Content-Type" . "application/json")))
			headers))
               (url-request-data
		(and payload (encode-coding-string (json-encode payload) 'utf-8)))
               (url nil)
               (origin (current-buffer))
               (observed-http-status nil)
               (git-failure-notified nil)
               (finished nil)
               response process timer)
          (cl-labels
              ((finish (value problem &optional status kind detail)
		 (unless finished
                   ;; A failed canonical GET must fence old Git currentness
                   ;; before completion becomes irreversible.  Raw status
                   ;; notification may have been interrupted before latching.
                   (let ((inhibit-quit t))
                     (when (and problem (not git-failure-notified))
                       (setq git-failure-notified
                             (condition-case nil
                                 (emacsos-assist-web--git-http-status
                                  origin method path status (not git-typed-error)
                                  run-owner request-tid)
                               ((error quit) nil)))
                       (when (and (not git-failure-notified)
                                  canonical-thread-get
                                  (not git-typed-error)
                                  (buffer-live-p origin)
                                  (equal request-tid
                                         (buffer-local-value
                                          'emacsos-assist-web--thread-id origin)))
                         (with-current-buffer origin
                           (emacsos-assist-web-git--canonical-uncertain))))
                     (setq finished t)
                     (when (timerp timer) (cancel-timer timer))
                     (setq emacsos-assist-web--requests
			   (delq response emacsos-assist-web--requests))
                     (funcall callback value
                              (if (and git-typed-error problem)
                                  (emacsos-assist-web--git-request-error
                                   status (or kind 'transport) detail)
                                problem))))))
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
                           (lambda (transport-status)
                             (let ((response-buffer (current-buffer))
                                   value problem
                                         (status (and (boundp 'url-http-response-status)
                                                      url-http-response-status)))
                               (unless (and (eql observed-http-status status)
                                            git-failure-notified)
                                 (setq git-failure-notified
                                       (or git-failure-notified
                                           (condition-case nil
                                               (emacsos-assist-web--git-http-status
                                                origin method path status nil
                                                run-owner request-tid)
                                             ((error quit) nil)))))
			       (if (plist-get transport-status :error)
				   (setq problem "Assist Web connection unavailable")
				 (condition-case parse-error
				     (setq value
					   (emacsos-assist-web--response-json
					    response-buffer allow-status
					    array-type object-type))
				   ((error quit)
				    (setq problem
					  (error-message-string parse-error)))))
			       ;; Buffer hooks are optional presentation cleanup.  Even if
			       ;; one signals, finish must fence a failed canonical read and
			       ;; deliver its callback exactly once.
		       (condition-case cleanup-error
			   (kill-buffer response-buffer)
			 ((error quit)
			  (setq value nil
				problem (error-message-string cleanup-error))))
                               (when (buffer-live-p response-buffer)
                                 (emacsos-assist-web--kill-internal-response
                                  response-buffer))
                               (when (buffer-live-p response-buffer)
                                 (setq value nil
                                       problem "Assist Web response cleanup failed"))
			       (finish value problem status
                                       (if (plist-get transport-status :error)
                                           'transport 'parse)
                                       (when (memq
                                              (car-safe
                                               (plist-get transport-status :error))
                                              '(tls gnutls-error))
                                         'trust))))
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
                             ;; Response hooks are not part of the request
                             ;; outcome.  A C-g there must still deliver the
                             ;; timeout to the exact Run owner once.
                             (let ((inhibit-quit t))
                               (emacsos-assist-web--close-internal-process process)
                               (emacsos-assist-web--kill-internal-response response))
                             (finish nil "Assist Web request timed out"
                                     nil 'transport 'timeout)))))
		  (when (process-live-p process)
                    (let ((url-filter (process-filter process)))
                      (set-process-filter
                       process
                       (emacsos-assist-web--guarded-filter
			url-filter
			(lambda (active problem)
			  (unless git-failure-notified
                            (setq git-failure-notified
                                  (emacsos-assist-web--git-http-status
                                   origin method path observed-http-status
                                   (not git-typed-error) run-owner
                                   request-tid)))
			  (set-process-filter active nil)
			  (set-process-sentinel active nil)
			  (when (process-live-p active) (delete-process active))
			  (when (buffer-live-p (process-buffer active))
                            (emacsos-assist-web--kill-buffer-later
                             (process-buffer active)))
			  (finish nil problem observed-http-status 'transport))
                        nil
                        (lambda (status)
                          (setq observed-http-status status)
                          (if (memq status '(401 403 404))
                              (setq git-failure-notified
                                    (or git-failure-notified
                                        (emacsos-assist-web--git-http-status
                                         origin method path status nil run-owner
                                         request-tid)))
                            ;; A non-denial status is parsed later.  It is
                            ;; not evidence that malformed JSON or transport
                            ;; failure has already downgraded Git freshness.
                            t)))))))
              ((error quit)
               (let ((inhibit-quit t))
                 (emacsos-assist-web--close-internal-process process)
                 (emacsos-assist-web--kill-internal-response response))
               (finish nil (error-message-string error)))))))))))

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
                 (emacsos-assist-web--kill-internal-response candidate))
               buffer))

(defun emacsos-assist-web--kill-internal-response (buffer)
  "Close internal HTTP BUFFER even if one cleanup hook faults."
  (when (buffer-live-p buffer)
    (let ((inhibit-quit t))
      (condition-case nil (kill-buffer buffer)
        ((error quit) nil))
      (when (buffer-live-p buffer)
        (with-current-buffer buffer
          ;; Only this internal response has already failed its ordinary
          ;; cleanup.  Do not let a repeatedly signaling hook leak it.
          (let ((kill-buffer-hook nil)
                (kill-buffer-query-functions nil))
            (condition-case nil (kill-buffer buffer)
              ((error quit) nil))))))))

(defun emacsos-assist-web--close-internal-process (process)
  "Detach and close an exact owned HTTP PROCESS despite cleanup errors."
  (when (condition-case nil (process-live-p process)
          ((error quit) nil))
    (condition-case nil (set-process-filter process nil)
      ((error quit) nil))
    (condition-case nil (set-process-sentinel process nil)
      ((error quit) nil))
    (condition-case nil (delete-process process)
      ((error quit) nil))))

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
          emacsos-assist-web--stream-raw-bytes nil
          emacsos-assist-web--stream-undecided-suffix nil
          emacsos-assist-web--in-flight nil)
    (emacsos-assist-web--sync-active-surface)
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

(defun emacsos-assist-web--stream-finish
    (buffer &optional run-still-active verified-outcome verified-start-epoch)
  "Finish BUFFER's event observation and request its canonical transcript.

When RUN-STILL-ACTIVE is non-nil, do not label the accepted Run as completed;
the canonical snapshot must retain its durable identity.  VERIFIED-OUTCOME
and VERIFIED-START-EPOCH come only from an exact Run GET, never from an SSE
terminal event."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((completed-run-id
             (unless run-still-active emacsos-assist-web--run-id)))
        ;; A terminal SSE is not the answer.  Keep the marker-scoped text raw
        ;; until the canonical snapshot has replaced this provisional region.
        (emacsos-assist-web--stream-cleanup t t)
        ;; The Run's terminal SSE is not its exact outcome.  Keep its receipt
        ;; (and any follow-up) until the Run GET and canonical cache commit.
        (emacsos-assist-web--set-status "reconciling")
        (emacsos-assist-web--save-draft)
        (emacsos-assist-web-refresh-thread
         buffer (or completed-run-id
                    (and verified-outcome emacsos-assist-web--run-id))
         verified-outcome verified-start-epoch)))))

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
      (message "%s. C-c C-r refreshes; Send retries the same message."
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
  (let* ((inhibit-quit t)
        (unavailable
         (condition-case nil
             (and (buffer-live-p response)
                  (emacsos-assist-web--run-store-unavailable-response-p response))
           ((error quit) nil))))
    ;; url-http may run its final callback inside the last filter invocation.
    ;; Defer cleanup so an error event in that callback remains authoritative.
    (condition-case nil
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
         target generation unavailable)
      ((error quit)
       (when (and (buffer-live-p target)
                  (with-current-buffer target
                    (= generation emacsos-assist-web--stream-generation)))
         (emacsos-assist-web--stream-interrupted
          target "observation disconnected"))))))

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
            (let* ((status (json-parse-string data :object-type 'alist))
                   (text (alist-get 'status status)))
              (if (and (listp status)
                       (= (cl-count 'status status :key #'car) 1)
                       (emacsos-conversation-valid-status-p text))
                  (emacsos-assist-web--set-status text)
                (emacsos-assist-web--stream-interrupted
                 target "invalid Assist status")))
          (error (emacsos-assist-web--stream-interrupted
                  target "invalid Assist status"))))
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
       ((equal event "terminal")
        (condition-case nil
            (emacsos-assist-web--finish-stream-tail target)
          (error (emacsos-assist-web--stream-interrupted target "invalid Assist delta"))))
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
  (unless (integerp attempt) (error "Invalid stream attempt"))
  (setq emacsos-assist-web--stream-attempt attempt
        emacsos-assist-web--stream-index 0
        emacsos-assist-web--stream-raw-bytes 0
        emacsos-assist-web--stream-undecided-suffix "")
  (when (and (markerp emacsos-assist-web--assistant-start)
             (markerp emacsos-assist-web--assistant-end))
    (set-marker emacsos-assist-web--assistant-end
                (emacsos-conversation-reset-assistant
                 emacsos-assist-web--assistant-start emacsos-assist-web--assistant-end))))

(defun emacsos-assist-web--undecided-stream-suffix (text)
  "Return TEXT's longest proper CRLF or allowed-flag prefix suffix."
  (let ((suffix ""))
    (dolist (candidate (cons "\r\n" emacsos-assist-web--subdivision-flags))
      (dotimes (length (1- (length candidate)))
        (let ((prefix (substring candidate 0 (1+ length))))
          (when (and (> (length prefix) (length suffix))
                     (string-suffix-p prefix text))
            (setq suffix prefix)))))
    suffix))

(defun emacsos-assist-web--stream-decidable-text (text)
  "Return canonical decidable text and raw undecided suffix from TEXT."
  (let* ((suffix (emacsos-assist-web--undecided-stream-suffix text))
         (decidable (substring text 0 (- (length text) (length suffix))))
         (canonical (emacsos-assist-web--canonical-message-text decidable)))
    (unless (emacsos-assist-web--valid-message-text-p canonical)
      (error "Invalid Assist delta"))
    (cons canonical suffix)))

(defun emacsos-assist-web--append-rendered-delta (text)
  "Append validated canonical TEXT at the current provisional assistant marker."
  (unless (and (markerp emacsos-assist-web--assistant-end)
               (marker-buffer emacsos-assist-web--assistant-end))
    (error "Invalid Assist delta"))
  (set-marker emacsos-assist-web--assistant-end
              (emacsos-conversation-append-delta
               emacsos-assist-web--assistant-end text)))

(defun emacsos-assist-web--append-delta (attempt index text)
  "Append the next raw bounded TEXT delta for ATTEMPT/INDEX atomically."
  (unless (and (integerp attempt) (integerp index) (stringp text)
               (<= (string-bytes text) (* 16 1024)))
    (error "Invalid Assist delta"))
  (cond
   ((not (integerp emacsos-assist-web--stream-attempt))
    (emacsos-assist-web--stream-interrupted
     (current-buffer) "Assist stream is missing its reset; refresh to reconcile"))
   ((< attempt emacsos-assist-web--stream-attempt) nil)
   ((or (not (equal attempt emacsos-assist-web--stream-attempt))
        (/= index (1+ emacsos-assist-web--stream-index)))
    (emacsos-assist-web--stream-interrupted
     (current-buffer) "Assist stream has a gap; refresh to reconcile"))
   ((and (local-variable-p 'emacsos-assist-web--stream-raw-bytes (current-buffer))
         (local-variable-p 'emacsos-assist-web--stream-undecided-suffix (current-buffer))
         (integerp emacsos-assist-web--stream-raw-bytes)
         (stringp emacsos-assist-web--stream-undecided-suffix))
    (let ((total (+ emacsos-assist-web--stream-raw-bytes (string-bytes text))))
      (when (> total emacsos-assist-web--max-message-bytes)
        (error "Invalid Assist delta"))
      (pcase-let ((`(,canonical . ,suffix)
                   (emacsos-assist-web--stream-decidable-text
                    (concat emacsos-assist-web--stream-undecided-suffix text))))
        (emacsos-assist-web--append-rendered-delta canonical)
        (setq emacsos-assist-web--stream-index index
              emacsos-assist-web--stream-raw-bytes total
              emacsos-assist-web--stream-undecided-suffix suffix)
        (emacsos-assist-web--set-status "working"))))
   (t
    (emacsos-assist-web--stream-interrupted
     (current-buffer) "Assist stream is missing its reset; refresh to reconcile"))))

(defun emacsos-assist-web--finish-stream-tail (target)
  "Flush TARGET's one safe pending stream suffix before canonical reconciliation."
  (with-current-buffer target
    (let ((suffix emacsos-assist-web--stream-undecided-suffix))
      (cond
       ((or (null suffix) (string-empty-p suffix))
        (emacsos-assist-web--stream-finish target))
       ((equal suffix "\r")
        (emacsos-assist-web--append-rendered-delta "\n")
        (setq emacsos-assist-web--stream-undecided-suffix "")
        (emacsos-assist-web--stream-finish target))
       ((equal suffix (string #x1f3f4))
        (emacsos-assist-web--append-rendered-delta suffix)
        (setq emacsos-assist-web--stream-undecided-suffix "")
        (emacsos-assist-web--stream-finish target))
       (t (error "Invalid Assist delta"))))))

(defun emacsos-assist-web--decoded-end ()
  "Return the response-buffer end known to contain decoded entity bytes."
  (if (and (boundp 'url-http-transfer-encoding)
           (equal url-http-transfer-encoding "chunked"))
      (when (and (boundp 'url-http-chunked-start)
                 (markerp url-http-chunked-start)
                 (boundp 'url-http-chunked-length)
                 (integerp url-http-chunked-length))
        (min (point-max)
             (+ (marker-position url-http-chunked-start)
                url-http-chunked-length)))
    (point-max)))

(defun emacsos-assist-web--drain-events (target generation decoded-end &optional entry)
  "Consume decoded SSE through DECODED-END for TARGET and optional exact ENTRY.

The current response buffer remains owned by `url-http'.  Parsing stops at its
decoder-confirmed entity boundary, and pruning preserves every byte still
addressed by the stock chunk decoder."
  (let* ((header-end (marker-position url-http-end-of-headers))
         (body-start (min (point-max) (1+ header-end))))
    (unless (and (markerp emacsos-assist-web--stream-body-marker)
                 (eq (marker-buffer emacsos-assist-web--stream-body-marker)
                     (current-buffer))
                 (markerp emacsos-assist-web--stream-scan-marker)
                 (eq (marker-buffer emacsos-assist-web--stream-scan-marker)
                     (current-buffer)))
      (let ((legacy-start
             (and (markerp emacsos-assist-web--stream-body-marker)
                  (eq (marker-buffer emacsos-assist-web--stream-body-marker)
                      (current-buffer))
                  (marker-position emacsos-assist-web--stream-body-marker))))
        (setq-local emacsos-assist-web--stream-body-marker
                    (copy-marker (max body-start (or legacy-start body-start)) nil)
                    emacsos-assist-web--stream-scan-marker
                    (copy-marker (max body-start (or legacy-start body-start)) nil)
                    emacsos-assist-web--stream-unconsumed-bytes 0)))
    (let* ((marker emacsos-assist-web--stream-body-marker)
           (scan-marker emacsos-assist-web--stream-scan-marker)
           (start (marker-position marker))
           (end (max start (or decoded-end start)))
           (too-large nil))
      (goto-char (min end (marker-position scan-marker)))
      (while (and (not too-large)
                  (re-search-forward "\r?\n\r?\n" end t))
        (let* ((record-end (point))
               (delimiter-start (match-beginning 0))
               (event nil)
               (data nil))
          (if (> (emacsos-assist-web--range-bytes start delimiter-start)
                 emacsos-assist-web-max-event-bytes)
              (setq too-large t)
            (let ((record
                   (buffer-substring-no-properties start delimiter-start)))
              (dolist (line (split-string record "\r?\n" t))
                (cond
                 ((string-prefix-p "event: " line) (setq event (substring line 7)))
                 ((string-prefix-p "data: " line) (setq data (substring line 6)))))
              (when (and event (buffer-live-p target)
                         (with-current-buffer target
                           (if entry
                               (and (eq entry emacsos-assist-web--stream-entry)
                                    (emacsos-assist-web--entry-callback-current-p
                                     entry generation))
                             (= generation emacsos-assist-web--stream-generation))))
                (emacsos-assist-web--dispatch-event target event (or data "")))
              (setq start record-end)
              (set-marker marker start)
              (set-marker scan-marker start)))))
      (setq emacsos-assist-web--stream-unconsumed-bytes
            (emacsos-assist-web--range-bytes start end))
      (when (> emacsos-assist-web--stream-unconsumed-bytes
               emacsos-assist-web-max-event-bytes)
        (setq too-large t))
      (if too-large
          (progn
            (set-marker marker end)
            (set-marker scan-marker end)
            (setq emacsos-assist-web--stream-unconsumed-bytes 0)
            (when (and (buffer-live-p target)
                       (with-current-buffer target
                         (if entry
                             (and (eq entry emacsos-assist-web--stream-entry)
                                  (emacsos-assist-web--entry-callback-current-p
                                   entry generation))
                           (= generation emacsos-assist-web--stream-generation))))
              (if entry
                  (emacsos-assist-web--entry-observation-interrupted
                   entry generation "Assist event is too large")
                (emacsos-assist-web--stream-interrupted
                 target "Assist event is too large"))))
        ;; A delimiter can span callbacks.  Rescan only its final three bytes.
        (set-marker scan-marker (max start (- end 3))))
      ;; Discard only bytes neither the parser nor stock decoder can address.
      ;; An incomplete event may span chunks, and the active chunk plus a
      ;; split final terminator must remain at their exact stock positions.
      (let ((prune-end
             (cond
              ((and (boundp 'url-http-transfer-encoding)
                    (equal url-http-transfer-encoding "chunked"))
               (if (and (not (and (boundp 'url-http-chunked-last-crlf-missing)
                                  url-http-chunked-last-crlf-missing))
                        (boundp 'url-http-chunked-start)
                        (markerp url-http-chunked-start))
                   (min (marker-position marker)
                        (marker-position url-http-chunked-start))
                 body-start))
              ((and (boundp 'url-http-content-length)
                    (integerp url-http-content-length))
               body-start)
              (t (marker-position marker)))))
        (when (> prune-end body-start)
          (delete-region body-start prune-end))))))

(defun emacsos-assist-web--event-filter (url-filter target generation)
  "Wrap URL-FILTER and dispatch SSE records to TARGET for GENERATION."
  (lambda (process bytes)
    (condition-case problem
      ;; The stock filter may detach PROCESS from its buffer on the final
      ;; chunk.  Retain the response so its terminal event is not lost.
      (let ((response (process-buffer process)))
      (when (functionp url-filter) (funcall url-filter process bytes))
      (when (buffer-live-p response)
        (with-current-buffer response
          (when (and (boundp 'url-http-end-of-headers) url-http-end-of-headers)
            (if (not (and (integerp url-http-response-status)
                          (<= 200 url-http-response-status 299)
                          (emacsos-assist-web--sse-content-type-p
                           url-http-content-type)))
                (when (and (buffer-live-p target)
                         (with-current-buffer target
                           (= generation emacsos-assist-web--stream-generation)))
                  ;; A 503 body can distinguish unavailable durable observation
                  ;; only after url-http has received it all.  Its completion
                  ;; callback below preserves the accepted identity and reports
                  ;; operator repair rather than a generic retry.
                  (unless (eql url-http-response-status 503)
                    (emacsos-assist-web--stream-interrupted
                     target "Assist observation was rejected")))
              (when (and (buffer-live-p target)
                         (with-current-buffer target
                           (= generation emacsos-assist-web--stream-generation)))
                (with-current-buffer target
                  (when (timerp emacsos-assist-web--stream-header-timer)
                    (cancel-timer emacsos-assist-web--stream-header-timer)
                    (setq emacsos-assist-web--stream-header-timer nil))))
              (let* ((decoded-end (emacsos-assist-web--decoded-end))
                     (body-start
                      (min (point-max)
                           (1+ (marker-position url-http-end-of-headers))))
                     (pending-bytes
                      (emacsos-assist-web--range-bytes
                       (or decoded-end body-start) (point-max))))
                (cond
                 ((and (boundp 'url-http-content-length)
                       (integerp url-http-content-length)
                       (or (< url-http-content-length 0)
                           (> url-http-content-length
                              emacsos-assist-web-max-response-bytes)))
                  (emacsos-assist-web--stream-interrupted
                   target "Assist stream response is too large"))
                 ((and (boundp 'url-http-transfer-encoding)
                       (equal url-http-transfer-encoding "chunked")
                       (boundp 'url-http-chunked-length)
                       (integerp url-http-chunked-length)
                       (> url-http-chunked-length
                          emacsos-assist-web-max-stream-chunk-bytes))
                  (emacsos-assist-web--stream-interrupted
                   target "Assist stream transport chunk is too large"))
                 ((> pending-bytes emacsos-assist-web-max-header-bytes)
                  (emacsos-assist-web--stream-interrupted
                   target "Assist stream transport framing is too large"))
                 (t
                  (emacsos-assist-web--drain-events
                   target generation decoded-end)))))))))
      ((error quit)
       (when (and (buffer-live-p target)
                  (with-current-buffer target
                    (= generation emacsos-assist-web--stream-generation)))
         (emacsos-assist-web--stream-interrupted
          target (error-message-string problem)))))))

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
          (alist-get 'repo_label thread)
          (or suffix "")))

(defun emacsos-assist-web--catalog-threads ()
  "Return the threads from the authoritative in-memory catalog."
  (alist-get 'threads emacsos-assist-web--catalog))

(defun emacsos-assist-web--completion-records ()
  "Return completion records with identity kept separate from display text."
  (let* ((threads (emacsos-assist-web--catalog-threads))
         (ids (sort (mapcar (lambda (thread) (alist-get 'id thread)) threads)
                    #'string<)))
    (mapcar
     (lambda (thread)
       (let* ((state (alist-get 'status thread))
              (base (format "%s [%s%s]"
                            (emacsos-assist-web--thread-label thread)
                            state
                            (if (memq emacsos-assist-web--catalog-state
                                      '(cached refresh-failed))
                                ", cached" "")))
              (ordinal (1+ (cl-position (alist-get 'id thread) ids
                                        :test #'equal))))
         (list :display
               (format "#%d  %s" ordinal
                       (emacsos-assist-web--isolate-display-text base))
               :thread thread
               :search (downcase (concat (alist-get 'search_description thread)
                                         " " (alist-get 'description thread)
                                         " " (alist-get 'repo_label thread)
                                         " " state)))))
     threads)))

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
  "Return unambiguous completion records for ITEMS using IDENTITY-KEY."
  (let ((identities
         (sort (mapcar (lambda (item) (alist-get identity-key item)) items)
               #'string<)))
    (mapcar
     (lambda (item)
       (let* ((label (alist-get 'label item))
              (identity (alist-get identity-key item))
              (ordinal (1+ (cl-position identity identities :test #'equal))))
         (list :display
               (format "#%d  %s" ordinal
                       (emacsos-assist-web--isolate-display-text label))
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
    ;; Install before the prompt itself, then follow later status/action
    ;; insertions at that boundary rather than deleting their entry on Send.
    (setq emacsos-assist-web--prompt-marker (copy-marker before nil))
    (insert emacsos-assist-web--prompt)
    (set-marker-insertion-type emacsos-assist-web--prompt-marker t)
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
    (let* ((fresh-by-id (make-hash-table :test #'equal))
          (older nil)
          (old-only-p nil)
          (dropped nil)
          (fresh-messages (alist-get 'messages fresh))
          (remaining-count (- emacsos-assist-web--max-rendered-messages
                              (length fresh-messages)))
          (remaining-bytes
           (- emacsos-assist-web--max-rendered-transcript-bytes
              (cl-loop for message in fresh-messages
                       sum (string-bytes (alist-get 'text message)))))
          (retained nil)
          (result (copy-tree fresh)))
      (dolist (message fresh-messages)
        (puthash (alist-get 'id message) message fresh-by-id))
      (dolist (message (alist-get 'messages previous))
        (unless (gethash (alist-get 'id message) fresh-by-id)
          (setq old-only-p t)
          (push message older)))
      ;; OLDER is newest-first here.  Keep the newest contiguous suffix that
      ;; fits before FRESH, so a growing thread evicts the oldest loaded rows.
      (while older
        (let* ((message (pop older))
               (bytes (string-bytes (alist-get 'text message))))
          (if (and (> remaining-count 0) (>= remaining-bytes bytes))
              (progn
                (push message retained)
                (setq remaining-count (1- remaining-count)
                      remaining-bytes (- remaining-bytes bytes)))
            ;; Older rows cannot be retained across this gap.
            (setq dropped t
                  older nil))))
      (setf (alist-get 'messages result)
            (append retained fresh-messages))
      (when old-only-p
        (setf (alist-get 'has_older_messages result)
              (alist-get 'has_older_messages previous)
              (alist-get 'next_before result)
              (alist-get 'next_before previous)))
      (when (or dropped
                (zerop remaining-count)
                (zerop remaining-bytes))
        (setf (alist-get 'has_older_messages result) nil
              (alist-get 'next_before result) nil))
      result)))

(defun emacsos-assist-web--render (snapshot &optional stale)
  "Render SNAPSHOT in the current remote-thread buffer, marked STALE if needed."
  (let ((inhibit-read-only t)
        (inhibit-modification-hooks t)
        (draft (emacsos-assist-web--input))
        (render-state (emacsos-assist-web--capture-render-state)))
    (emacsos-assist-web--require-snapshot
     snapshot emacsos-assist-web--thread-id
     emacsos-assist-web--max-rendered-messages
     emacsos-assist-web--max-rendered-transcript-bytes)
    (let ((previous emacsos-assist-web--snapshot))
      (when previous
        (condition-case nil
            (emacsos-assist-web--require-snapshot
             previous emacsos-assist-web--thread-id
             emacsos-assist-web--max-rendered-messages
             emacsos-assist-web--max-rendered-transcript-bytes)
          (error (setq previous nil))))
      (setq snapshot
            (emacsos-assist-web--retain-loaded-history snapshot previous)))
    (emacsos-assist-web--require-transcript-limits
     (alist-get 'messages snapshot)
     emacsos-assist-web--max-rendered-messages
     emacsos-assist-web--max-rendered-transcript-bytes)
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
      (emacsos-assist-web-git--sync-keys)
      (erase-buffer)
      ;; Queue markers belonged to the erased presentation, never to this
      ;; canonical snapshot.  Rebuild remaining provisional entries below.
      (dolist (entry emacsos-assist-web--queue)
        (setf (plist-get entry :rendered) nil
              (plist-get entry :user-start) nil
              (plist-get entry :assistant-start) nil
              (plist-get entry :assistant-end) nil))
      (setq emacsos-assist-web--recovery-action-marker nil)
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
        (if emacsos-assist-web--queue
            (progn
              (when draft (insert draft))
              (emacsos-assist-web--rerender-queue))
          (if draft (insert draft) (emacsos-assist-web--restore-draft)))
        (emacsos-assist-web--restore-render-state render-state)
        (setq buffer-read-only nil)
        (set-buffer-modified-p nil)
        (emacsos-assist-web--save-draft)))))

(defun emacsos-assist-web--snapshot-cache-name (tid)
  "Return the bounded per-thread snapshot cache filename for TID."
  (concat "threads/" (emacsos-assist-web--require-id tid) ".json"))

(defun emacsos-assist-web--draft-cache-name ()
  "Return the private cache name for this thread or local draft buffer."
  (when-let ((identity (or (and emacsos-assist-web--draft-id
                                (emacsos-assist-web--require-id
                                 emacsos-assist-web--draft-id))
                           (and emacsos-assist-web--thread-id
                                (emacsos-assist-web--require-id
                                 emacsos-assist-web--thread-id)))))
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
              (follow_ups . ,emacsos-assist-web--follow-ups)
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
      (if (eq emacsos--assist-active-surface 'chat)
          ;; A recovered durable retry may wait, but it must never steal the
          ;; phone-wide stream owner from an open local or canonical chat.
          (emacsos-assist-web--set-unverified-status
           "another conversation is active; Send re-observes")
        (let* ((tid (emacsos-assist-web--require-id emacsos-assist-web--thread-id))
               (run-id (emacsos-assist-web--require-id emacsos-assist-web--run-id))
               (generation (cl-incf emacsos-assist-web--send-generation))
               (run-auth-start
                (progn
                  (emacsos-assist-web-git--claim-orphaned-run-gate tid run-id)
                  emacsos-assist-web-git--auth-epoch)))
      (setq emacsos-assist-web--in-flight t
            emacsos--assist-active-surface 'web)
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
                   (let ((status (emacsos-assist-web--exact-run-status
                                  value tid run-id)))
                     (when (emacsos-assist-web-git--run-read-superseded-p
                            tid run-id run-auth-start)
                       (error "newer exact Run denial; Refresh retries status"))
                     (cond
                      ((member status '("pending" "running" "transitioning"))
                       (unless emacsos-assist-web--pending-rendered-p
                         (emacsos-assist-web--append-pending
                          emacsos-assist-web--submitted-text))
                       (emacsos-assist-web--set-status status)
                       (if (emacsos-assist-web--save-draft)
                           (progn
                             (emacsos-assist-web-git--confirm-active-run
                              tid run-id run-auth-start)
                             (emacsos-assist-web--observe-run buffer))
                         (emacsos-assist-web--set-unverified-status
                          "local Run status could not be saved; Refresh retries")))
                      ((equal status "awaiting_approval")
                       ;; It ends this observer but remains a durable Run until
                       ;; the canonical refresh has made its approval state visible.
                       (if (emacsos-assist-web--save-draft)
                           (emacsos-assist-web--stream-finish
                            buffer t status run-auth-start)
                         (emacsos-assist-web--set-unverified-status
                          "local Run status could not be saved; Refresh retries")))
                      ((member status '("success" "error" "timeout" "interrupted"
                                       "cancelled"))
                       (emacsos-assist-web-refresh-thread
                        buffer run-id status run-auth-start))
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
  "Restore legacy nonqueue local state before its exact Run is observed."
  (when-let* ((name (emacsos-assist-web--draft-cache-name))
              (draft (emacsos-assist-web--read-cache name)))
    (let ((key (alist-get 'pending_key draft))
          (submitted (alist-get 'submitted_text draft))
          (run-id (alist-get 'run_id draft))
          (follow-ups (alist-get 'follow_ups draft))
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
      (setq emacsos-assist-web--follow-ups
            (if (and (listp follow-ups)
                     (<= (length follow-ups) 1)
                     (seq-every-p
                      (lambda (entry)
                        (let ((queued-text (alist-get 'text entry))
                              (queued-key (alist-get 'key entry)))
                          (and (stringp queued-text)
                               (stringp queued-key)
                               (string-match-p emacsos-assist-web--idempotency-regexp
                                               queued-key))))
                      follow-ups))
                follow-ups
              nil))
      (if emacsos-assist-web--pending-accepted-p
          (progn
            (if emacsos-assist-web--run-id
                (emacsos-assist-web--resume-accepted-run)
              (unless emacsos-assist-web--pending-rendered-p
                (emacsos-assist-web--append-pending submitted))
              (emacsos-assist-web--set-status
               "observation interrupted; C-c C-r refreshes"))
            ;; A crash can leave the accepted submission in the saved editable
            ;; tail even though the provisional rendering is restored above.
            (when (and (stringp text)
                       (not (equal text submitted)))
              (insert text)))
        (when (and emacsos-assist-web--pending-key
                   emacsos-assist-web--submitted-text)
          (unless emacsos-assist-web--pending-rendered-p
            (emacsos-assist-web--append-pending
             emacsos-assist-web--submitted-text))
          (emacsos-assist-web--set-status "unsent message ready; Send retries"))
        (when (stringp text) (insert text))))))

(defun emacsos-assist-web--thread-for-id (id)
  "Return the current catalog thread identified by ID."
  (seq-find (lambda (thread) (equal (alist-get 'id thread) id))
            (emacsos-assist-web--catalog-threads)))

(defun emacsos-assist-web--list-records (width)
  "Return list records fitted to WIDTH with deterministic collision ordinals."
  (let* ((groups (make-hash-table :test #'equal))
         (records
          (mapcar
           (lambda (thread)
             (let* ((description (emacsos-assist-web--fit-list-line
                                  (alist-get 'description thread) width))
                    (metadata-source (format "%s · %s"
                                             (alist-get 'repo_label thread)
                                             (alist-get 'status thread)))
                    (metadata (emacsos-assist-web--fit-list-line
                               metadata-source
                               (max 0 (- width
                                         emacsos-assist-web--list-ordinal-width))))
                    (key (list
                          (emacsos-assist-web--fit-list-line
                           (emacsos-assist-web--collision-key-text
                            (alist-get 'description thread)) width)
                          (emacsos-assist-web--fit-list-line
                           (emacsos-assist-web--collision-key-text metadata-source)
                           (max 0 (- width
                                     emacsos-assist-web--list-ordinal-width))))))
               (list :thread thread :description description
                     :metadata metadata :key key)))
           (emacsos-assist-web--catalog-threads))))
    (dolist (record records)
      (let ((key (plist-get record :key))
            (id (alist-get 'id (plist-get record :thread))))
        (puthash key (cons id (gethash key groups)) groups)))
    (mapcar
     (lambda (record)
       (let* ((ids (sort (copy-sequence
                          (gethash (plist-get record :key) groups))
                         #'string<))
              (ordinal (and (cdr ids)
                            (1+ (cl-position
                                 (alist-get 'id (plist-get record :thread)) ids
                                            :test #'equal)))))
         (plist-put record :ordinal ordinal)))
     records)))

(defun emacsos-assist-web--list-width ()
  "Return a usable text width for the native thread list."
  (max 12
       (if-let ((window (get-buffer-window (current-buffer) t)))
           (window-body-width window)
         40)))

(defun emacsos-assist-web--fit-list-line (text width)
  "Fit TEXT into WIDTH columns with a visible truncation marker."
  (truncate-string-to-width text width nil nil "…"))

(defun emacsos-assist-web--thread-row-position (id)
  "Return the first native list position whose stored thread ID equals ID."
  (let ((position (point-min))
        found)
    (while (and (< position (point-max)) (not found))
      (if (equal (get-text-property
                  position 'emacsos-assist-web-thread-id)
                 id)
          (setq found position)
        (setq position
              (next-single-property-change
               position 'emacsos-assist-web-thread-id nil (point-max)))))
    found))

(defvar emacsos-assist-web--thread-row-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'emacsos-assist-web-list-activate)
    map)
  "Keymap on one trusted native thread-list row.")

(defvar emacsos-assist-web--thread-refresh-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mouse-1] #'emacsos-assist-web-refresh-threads)
    (define-key map (kbd "RET") #'emacsos-assist-web-refresh-threads)
    map)
  "Keymap on the native thread-list refresh row.")

(defun emacsos-assist-web--insert-refresh-row (label)
  "Insert a touch-sized catalog refresh row displaying LABEL."
  (let ((start (point)))
    (insert (format "  %s  \n\n" label))
    (add-text-properties
     start (point)
     (list 'emacsos-assist-web-list-action 'refresh
           'keymap emacsos-assist-web--thread-refresh-map
           'mouse-face 'highlight
           'face 'button
           'help-echo "Refresh Assist threads"
           'rear-nonsticky t))))

(defun emacsos-assist-web--insert-thread-row (record)
  "Insert one fitted, touch-sized thread-list RECORD."
  (let* ((thread (plist-get record :thread))
         (ordinal (plist-get record :ordinal))
         (suffix (format " %4s" (if ordinal (format "#%d" ordinal) "")))
         (start (point)))
    (insert (emacsos-assist-web--isolate-display-text
             (plist-get record :description))
            "\n"
            (emacsos-assist-web--isolate-display-text
             (plist-get record :metadata))
            suffix "\n")
    (add-text-properties
     start (point)
     (list 'emacsos-assist-web-thread-id (alist-get 'id thread)
           'keymap emacsos-assist-web--thread-row-map
           'mouse-face 'highlight
           'help-echo "Open this Assist thread"
           'rear-nonsticky t))))

(defun emacsos-assist-web--render-thread-list ()
  "Render the authoritative catalog in the native thread-list buffer."
  (when-let ((buffer (get-buffer emacsos-assist-web--thread-list-buffer-name)))
    (with-current-buffer buffer
      (let ((selected (get-text-property (point) 'emacsos-assist-web-thread-id))
            (inhibit-read-only t)
            (width (emacsos-assist-web--list-width)))
        (erase-buffer)
        (cond
         ((null emacsos-assist-web--catalog)
          (insert (if (eq emacsos-assist-web--catalog-state 'refresh-failed)
                      "Assist threads could not be loaded.\n\n"
                    "Loading Assist threads…\n\n"))
          (emacsos-assist-web--insert-refresh-row
           (if (eq emacsos-assist-web--catalog-state 'refresh-failed)
               "Retry" "Refreshing…")))
         (t
          (insert (cond
                   (emacsos-assist-web--catalog-refreshing-p
                    "Assist threads: refreshing…\n\n")
                   ((eq emacsos-assist-web--catalog-state 'refresh-failed)
                    "Assist threads: refresh failed\n\n")
                   ((eq emacsos-assist-web--catalog-state 'cache-write-failed)
                    "Assist threads: current; cache write failed\n\n")
                   ((eq emacsos-assist-web--catalog-state 'cached)
                    "Assist threads: cached\n\n")
                   (t "Assist threads\n\n")))
          (emacsos-assist-web--insert-refresh-row
           (if (memq emacsos-assist-web--catalog-state
                     '(refresh-failed cache-write-failed))
               "Retry" "Refresh"))
          (if-let ((records (emacsos-assist-web--list-records width)))
              (dolist (record records)
                (emacsos-assist-web--insert-thread-row record))
          (insert "No Assist threads yet. Use C-c a n to create one.\n"))))
        (goto-char
         (or (and selected
                  (emacsos-assist-web--thread-row-position selected))
             (text-property-not-all (point-min) (point-max)
                                    'emacsos-assist-web-thread-id nil)
             (text-property-not-all (point-min) (point-max)
                                    'emacsos-assist-web-list-action nil)
             (point-min)))))))

(defun emacsos-assist-web-list-activate (&optional event)
  "Open the exact native thread-list row at point or EVENT."
  (interactive (list last-input-event))
  (when (mouse-event-p event) (mouse-set-point event))
  (if-let* ((id (get-text-property (point) 'emacsos-assist-web-thread-id))
            (thread (emacsos-assist-web--thread-for-id id)))
      (emacsos-assist-web--show-thread thread)
    (message "No Assist thread at point")))

(defvar emacsos-assist-web-thread-list-mode-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map special-mode-map)
    (define-key map (kbd "RET") #'emacsos-assist-web-list-activate)
    (define-key map (kbd "g") #'emacsos-assist-web-refresh-threads)
    map)
  "Keymap for `emacsos-assist-web-thread-list-mode'.")

(define-derived-mode emacsos-assist-web-thread-list-mode special-mode "Assist Threads"
  "Major mode for the native Assist thread list."
  (setq-local truncate-lines t
              bidi-paragraph-direction 'left-to-right))

(defun emacsos-assist-web-show-thread-list ()
  "Show the native Assist thread list and refresh it asynchronously."
  (interactive)
  (let ((buffer (get-buffer-create emacsos-assist-web--thread-list-buffer-name)))
    (with-current-buffer buffer
      (unless (derived-mode-p 'emacsos-assist-web-thread-list-mode)
        (emacsos-assist-web-thread-list-mode)))
    (switch-to-buffer buffer)
    (if emacsos-assist-web--catalog-refreshing-p
        (emacsos-assist-web--render-thread-list)
      (emacsos-assist-web-refresh-threads))))

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
  "Choose and open one cataloged Assist Web thread without a network wait."
  (interactive)
  (let ((records (and emacsos-assist-web--catalog
                      (emacsos-assist-web--completion-records))))
    (if (null records)
      (emacsos-assist-web-show-thread-list)
      (emacsos-assist-web-refresh-threads)
      (let* ((choice (completing-read
                      "Assist thread: "
                      (emacsos-assist-web--completion-table records) nil t))
             (record (emacsos-assist-web--record-for-display choice records))
             (id (and record
                      (alist-get 'id (plist-get record :thread))))
             (thread (and id (emacsos-assist-web--thread-for-id id))))
        (when record
          (if thread
              (emacsos-assist-web--show-thread thread)
            (message "That Assist thread is no longer available")))))))

(defun emacsos-assist-web--catalog-refresh-failed (problem rejected)
  "Finish a failed catalog refresh with PROBLEM.
REJECTED is non-nil when a response failed validation."
  (setq emacsos-assist-web--catalog-refreshing-p nil
        emacsos-assist-web--catalog-state 'refresh-failed)
  (emacsos-assist-web--cancel-pending-new-thread)
  (emacsos-assist-web--render-thread-list)
  (force-mode-line-update t)
  (message (if rejected "Thread refresh rejected: %s"
             "Thread refresh failed: %s")
           problem))

(defun emacsos-assist-web--cancel-pending-new-thread ()
  "Clear pending new-thread intent and its active minibuffer exit hook."
  (setq emacsos-assist-web--new-thread-pending-p nil)
  (when-let ((window (active-minibuffer-window)))
    (with-current-buffer (window-buffer window)
      (remove-hook 'minibuffer-exit-hook
                   #'emacsos-assist-web--resume-new-thread-after-minibuffer t))))

(defun emacsos-assist-web--resume-new-thread-after-minibuffer ()
  "Resume one pending new-thread chooser after the minibuffer exits."
  (remove-hook 'minibuffer-exit-hook
               #'emacsos-assist-web--resume-new-thread-after-minibuffer t)
  (run-at-time 0 nil #'emacsos-assist-web--open-pending-new-thread))

(defun emacsos-assist-web--open-pending-new-thread ()
  "Open the coalesced new-thread chooser when no minibuffer is active."
  (when (and emacsos-assist-web--new-thread-pending-p
             emacsos-assist-web--catalog)
    (let ((repositories (alist-get 'repositories emacsos-assist-web--catalog))
          (harnesses (alist-get 'harnesses emacsos-assist-web--catalog)))
      (cond
       ((null repositories)
        (emacsos-assist-web--cancel-pending-new-thread)
        (message "No Assist repositories are available"))
       ((null harnesses)
        (emacsos-assist-web--cancel-pending-new-thread)
        (message "No Assist harnesses are available"))
       ((active-minibuffer-window)
        (let ((window (active-minibuffer-window)))
          (with-current-buffer (window-buffer window)
            (add-hook 'minibuffer-exit-hook
                      #'emacsos-assist-web--resume-new-thread-after-minibuffer
                      nil t))))
       (t
        (setq emacsos-assist-web--new-thread-pending-p nil)
        (condition-case problem
            (emacsos-assist-web--new-thread-from-catalog
             emacsos-assist-web--catalog)
          (error
           (message "Cannot create a thread from the catalog: %s"
                    (error-message-string problem)))))))))

(defun emacsos-assist-web-refresh-threads ()
  "Refresh the one shared Assist catalog asynchronously."
  (interactive)
  (unless emacsos-assist-web--catalog-refreshing-p
    (let ((generation emacsos-assist-web--catalog-generation))
      (setq emacsos-assist-web--catalog-refreshing-p t)
      (emacsos-assist-web--render-thread-list)
      (force-mode-line-update t)
      (emacsos-assist-web--request
       "GET" "threads" nil
       (lambda (value error)
         (if (/= generation emacsos-assist-web--catalog-generation)
             (progn
               (setq emacsos-assist-web--catalog-refreshing-p nil)
               (emacsos-assist-web--render-thread-list)
               (force-mode-line-update t))
           (if error
               (emacsos-assist-web--catalog-refresh-failed error nil)
             (condition-case problem
                 (let* ((catalog (emacsos-assist-web--require-catalog value))
                        (cached
                         ;; VALUE retains vector array identity so empty arrays
                         ;; are serialized as [] rather than JSON null.
                         (emacsos-assist-web--try-write-cache
                          emacsos-assist-web--catalog-file value)))
                   (setq emacsos-assist-web--catalog catalog
                         emacsos-assist-web--catalog-refreshing-p nil
                         emacsos-assist-web--catalog-state
                         (if cached 'current 'cache-write-failed))
                   (emacsos-assist-web--render-thread-list)
                   (force-mode-line-update t)
                   (message (if cached "Threads updated"
                              "Threads updated; local cache write failed"))
                   (emacsos-assist-web--open-pending-new-thread))
               (error
                (emacsos-assist-web--catalog-refresh-failed
                 (error-message-string problem) t))))))
       nil nil 'array 'hash-table))))

(defun emacsos-assist-web--read-catalog-cache ()
  "Return the validated local catalog cache, or nil when absent or invalid."
  (when-let ((cached
              (emacsos-assist-web--read-cache
               emacsos-assist-web--catalog-file 'array 'hash-table)))
    (condition-case nil
        (emacsos-assist-web--require-catalog cached)
      (error nil))))

(defun emacsos-assist-web--load-catalog ()
  "Load the catalog cache at package initialization or repair a legacy shape."
  (unless (and (listp emacsos-assist-web--catalog)
               (assq 'threads emacsos-assist-web--catalog))
    (setq emacsos-assist-web--catalog nil
          emacsos-assist-web--catalog-state nil)
    (when-let ((cached (emacsos-assist-web--read-catalog-cache)))
      (setq emacsos-assist-web--catalog cached
            emacsos-assist-web--catalog-state 'cached))))

(defun emacsos-assist-web-refresh-thread
    (&optional buffer completed-run-id verified-outcome verified-start-epoch)
  "Fetch and render BUFFER's canonical thread snapshot asynchronously.

COMPLETED-RUN-ID is retired only with its exact VERIFIED-OUTCOME;
VERIFIED-START-EPOCH fences later Run access denial."
  (interactive)
  (let ((buffer (or buffer (current-buffer))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when emacsos-assist-web--thread-id
          (let ((tid (emacsos-assist-web--require-id emacsos-assist-web--thread-id))
                (generation (cl-incf emacsos-assist-web--refresh-generation))
                (send-generation emacsos-assist-web--send-generation)
                (git-auth-start-epoch emacsos-assist-web-git--auth-epoch)
                (git-reconcile-token
                 (emacsos-assist-web-git--canonical-start))
                (handled nil))
            (emacsos-assist-web--request
             "GET" (concat "threads/" tid) nil
             (lambda (value error)
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (when (and (not handled)
                              (= generation emacsos-assist-web--refresh-generation)
                              (= send-generation emacsos-assist-web--send-generation))
                     (setq handled t)
                     (if error
                         (progn
                           (emacsos-assist-web-git--canonical-failed
                            git-reconcile-token)
                           ;; Preserve the visible pending turn and editable tail.
                           ;; Re-rendering an older snapshot here would erase work
                           ;; that Assist has already accepted.
                           (if emacsos-assist-web--pending-accepted-p
                               (emacsos-assist-web--set-unverified-status
                                "refresh failed; C-c C-r retries")
                             (emacsos-assist-web--set-status
                              (if emacsos-assist-web--snapshot
                                  "refresh failed; cached; C-c C-r retries"
                                "refresh failed; C-c C-r retries")))
                           (message "Thread refresh failed: %s" error))
                       (condition-case problem
                           (progn
                             (emacsos-assist-web--require-snapshot value tid)
                             (when (and completed-run-id verified-start-epoch
                                        (not (eql git-auth-start-epoch
                                                  emacsos-assist-web-git--auth-epoch)))
                               (error "thread access changed during exact Run reconciliation"))
                             (when (and completed-run-id verified-start-epoch
                                        (emacsos-assist-web-git--run-read-superseded-p
                                         tid completed-run-id verified-start-epoch))
                               (error "newer exact Run denial; Refresh retries status"))
                             (let* ((busy
                                     (emacsos-assist-web--snapshot-active-p value))
                                    (retiring
                                     (and (member verified-outcome
                                                  '("success" "error" "timeout"
                                                    "interrupted" "cancelled"))
                                          completed-run-id
                                          (equal completed-run-id
                                                 emacsos-assist-web--run-id)
                                          emacsos-assist-web--pending-accepted-p))
                                    (cached
                                     (emacsos-assist-web--try-write-cache
                                      (emacsos-assist-web--snapshot-cache-name tid)
                                      value)))
                               (when retiring
                                 (unless (and cached
                                              (let ((emacsos-assist-web--pending-key nil)
                                                    (emacsos-assist-web--submitted-text nil)
                                                    (emacsos-assist-web--pending-accepted-p nil)
                                                    (emacsos-assist-web--run-id nil))
                                                (emacsos-assist-web--legacy-save-draft)))
                                   (error "exact Run retirement could not be saved"))
                                 ;; Both writes committed before live receipt retirement.
                                 (when emacsos-assist-web--in-flight
                                   (condition-case nil
                                       (emacsos-assist-web--stream-cleanup nil t)
                                     ((error quit) nil)))
                                 (setq emacsos-assist-web--stream-status nil
                                       emacsos-assist-web--pending-key nil
                                       emacsos-assist-web--submitted-text nil
                                       emacsos-assist-web--pending-accepted-p nil
                                       emacsos-assist-web--run-id nil)
                                 (when (integerp verified-start-epoch)
                                   (emacsos-assist-web-git--run-status-confirmed
                                    tid completed-run-id verified-start-epoch)))
                               (when busy
                                 (setq emacsos-assist-web--stream-status nil))
                               (when (and cached busy completed-run-id
                                          (integerp verified-start-epoch)
                                          (not retiring))
                                 (emacsos-assist-web-git--canonical-authorized
                                  git-auth-start-epoch)
                                 (emacsos-assist-web-git--run-status-confirmed
                                  tid completed-run-id verified-start-epoch))
                               (when retiring
                                 (emacsos-assist-web--git-note-safely
                                  value (and (equal verified-outcome "success")
                                             completed-run-id)
                                  git-auth-start-epoch git-reconcile-token))
                               (when (and cached (not retiring))
                                 (emacsos-assist-web--git-note-safely
                                  value nil git-auth-start-epoch
                                  git-reconcile-token))
                               ;; While this buffer owns a live observer, the
                               ;; existing provisional markers remain the only
                               ;; safe insertion target.  Cache a still-busy
                               ;; snapshot but leave that rendered region intact;
                               ;; a terminal refresh performs the reconciliation.
                               (condition-case display-problem
                                   (progn
                                     (unless (and busy emacsos-assist-web--in-flight)
                                       (emacsos-assist-web--render value)
                                       (setq emacsos-assist-web--display-recovery nil)
                                       (force-mode-line-update t))
                                     (unless (or retiring cached)
                                       (emacsos-assist-web--git-note-safely
                                        value nil git-auth-start-epoch
                                        git-reconcile-token)))
                                 ((error quit)
                                  (if (or retiring cached)
                                      (condition-case nil
                                          (progn
                                            (setq emacsos-assist-web--display-recovery t)
                                            (emacsos-assist-web-git--show-display-recovery)
                                            (emacsos-assist-web--set-status
                                             "Saved; Refresh to display"))
                                        ((error quit)
                                         (message "Saved; Refresh to display")))
                                    (signal (car display-problem)
                                            (cdr display-problem)))))
                               (when (and retiring emacsos-assist-web--follow-ups)
                                 (condition-case nil
                                     (emacsos-assist-web--start-follow-up)
                                   ((error quit)
                                    (condition-case nil
                                        (emacsos-assist-web--set-status
                                         "Run saved; Send retries follow-up")
                                      ((error quit)
                                       (message
                                        "Run saved; Send retries follow-up"))))))))
                           (error
                          (emacsos-assist-web-git--canonical-failed
                           git-reconcile-token)
                          (if emacsos-assist-web--pending-accepted-p
                              (emacsos-assist-web--set-unverified-status
                               "refresh rejected; C-c C-a g retries")
                            (emacsos-assist-web--set-status
                             (if emacsos-assist-web--snapshot
                                 "refresh rejected; cached; C-c C-a g retries"
                               "refresh rejected; C-c C-a g retries")))
                          (message "Thread refresh rejected: %s"
                                   (error-message-string problem))))))))))))))))

(defun emacsos-assist-web-load-older ()
  "Load one older bounded page of this thread's canonical visible history."
  (interactive)
  (if (not emacsos-assist-web--thread-id)
      (message "This draft has no history")
    (let* ((tid (emacsos-assist-web--require-id emacsos-assist-web--thread-id))
           (name (emacsos-assist-web--snapshot-cache-name tid))
           (raw-cached (or emacsos-assist-web--snapshot
                           (emacsos-assist-web--read-cache name)))
           (cached
            (condition-case nil
                (when raw-cached
                  (emacsos-assist-web--require-snapshot
                   raw-cached tid
                   emacsos-assist-web--max-rendered-messages
                   emacsos-assist-web--max-rendered-transcript-bytes))
              (error nil)))
           (before (and cached (alist-get 'next_before cached)))
           (buffer (current-buffer))
           (generation (cl-incf emacsos-assist-web--refresh-generation)))
      (when (and raw-cached (not cached)
                 (eq raw-cached emacsos-assist-web--snapshot))
        (setq emacsos-assist-web--snapshot nil))
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
                         (let* ((messages
                                 (append (alist-get 'messages page)
                                         (alist-get 'messages updated)))
                                (count (length messages))
                                (bytes
                                 (cl-loop for message in messages
                                          sum (string-bytes
                                               (alist-get 'text message))))
                                (over-cap
                                 (or (> count
                                        emacsos-assist-web--max-rendered-messages)
                                     (> bytes
                                        emacsos-assist-web--max-rendered-transcript-bytes)))
                                (at-cap
                                 (or (>= count
                                         emacsos-assist-web--max-rendered-messages)
                                     (>= bytes
                                         emacsos-assist-web--max-rendered-transcript-bytes))))
                           (unless over-cap
                             (setf (alist-get 'messages updated) messages))
                           (setf
                               (alist-get 'has_older_messages updated)
                               (and (not over-cap) (not at-cap)
                                    (alist-get 'has_older_messages page))
                               (alist-get 'next_before updated)
                               (and (not over-cap) (not at-cap)
                                    (alist-get 'next_before page))))
                         (emacsos-assist-web--render updated))
                     (error
                      (emacsos-assist-web--set-status
                       (if (or emacsos-assist-web--snapshot cached)
                           "older history rejected; cached; C-c C-a l retries"
                         "older history rejected; C-c C-a l retries"))
                      (message "Older history rejected: %s"
                               (error-message-string problem))))))))))))))

(defun emacsos-assist-web--new-idempotency-key ()
  "Mint one opaque retry key; it is persisted in the buffer while pending."
  (concat "emacsos-" (md5 (format "%s-%s-%s" (float-time) (random) (emacs-pid)))))

(defun emacsos-assist-web--release-send (buffer status)
  "Release BUFFER's send reservation, show STATUS, and persist retry state."
  (setq emacsos-assist-web--in-flight nil)
  (emacsos-assist-web--sync-active-surface)
  (emacsos-assist-web--set-status status)
  (emacsos-assist-web--save-draft))

(defun emacsos-assist-web-send ()
  "Send this buffer's prompt to its canonical web thread exactly once."
  (interactive)
  (emacsos-assist-web--sync-active-surface)
  (let ((text (or emacsos-assist-web--submitted-text
                  (emacsos-assist-web--input))))
    (cond
     ((not (derived-mode-p 'emacsos-assist-web-mode))
      (message "Open an Assist Web thread before sending"))
     ((or (not (stringp text)) (string-empty-p (string-trim text)))
      (message "Nothing to send"))
     ((eq emacsos--assist-active-surface 'chat)
      (message "Another Assist request is still running"))
     (emacsos-assist-web--in-flight
      (emacsos-assist-web--queue-follow-up text))
     (t
      (let* ((generation (cl-incf emacsos-assist-web--send-generation))
             (buffer (current-buffer))
             (existing-thread-id emacsos-assist-web--thread-id))
        ;; Any older snapshot callback describes the transcript before this send.
        (cl-incf emacsos-assist-web--refresh-generation)
        (setq emacsos-assist-web--in-flight t
              emacsos--assist-active-surface 'web
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
                                     (emacsos-assist-web--sync-active-surface)
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

(defun emacsos-assist-web--new-thread-from-catalog (catalog)
  "Open the existing draft, or choose from CATALOG and revalidate current IDs."
  (if-let ((existing (get-buffer "*assist New thread*")))
      (switch-to-buffer existing)
    (let ((repositories (alist-get 'repositories catalog))
          (harnesses (alist-get 'harnesses catalog)))
      (cond
       ((null repositories) (user-error "No Assist repositories are available"))
       ((null harnesses) (user-error "No Assist harnesses are available")))
      (let* ((saved (emacsos-assist-web--read-cache "drafts/new-thread.json"))
             (saved-repo-key (alist-get 'repo_key saved))
             (saved-harness-key (alist-get 'harness saved))
             (repo-record (emacsos-assist-web--select-labeled-item
                           "Repository: " repositories 'repo_key saved-repo-key))
             (harness-record (emacsos-assist-web--select-labeled-item
                              "Harness: " harnesses 'key saved-harness-key))
             (repo-key (and repo-record
                            (alist-get 'repo_key (plist-get repo-record :item))))
             (harness-key (and harness-record
                               (alist-get 'key (plist-get harness-record :item))))
             (current-repositories
              (alist-get 'repositories emacsos-assist-web--catalog))
             (current-harnesses (alist-get 'harnesses emacsos-assist-web--catalog))
             (current-repo-record
              (and repo-key
                   (seq-find
                    (lambda (record)
                      (equal repo-key
                             (alist-get 'repo_key (plist-get record :item))))
                    (emacsos-assist-web--labeled-records
                     current-repositories 'repo_key))))
             (current-harness-record
              (and harness-key
                   (seq-find
                    (lambda (record)
                      (equal harness-key
                             (alist-get 'key (plist-get record :item))))
                    (emacsos-assist-web--labeled-records current-harnesses 'key)))))
        (cond
         ((null current-repositories)
          (message "No Assist repositories are available"))
         ((null current-harnesses)
          (message "No Assist harnesses are available"))
         ((not (and current-repo-record current-harness-record))
          (message "Selected Assist workspace is no longer available"))
         (t
          (let* ((repo (plist-get current-repo-record :item))
                 (harness (plist-get current-harness-record :item))
                 (selected (plist-get current-repo-record :display))
                 (selected-harness (plist-get current-harness-record :display))
                 (buffer (get-buffer-create "*assist New thread*")))
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
            ;; Recovery can promote and retire this local draft.  Its adoption
            ;; already selects the canonical destination in that case.
            (when (buffer-live-p buffer)
              (switch-to-buffer buffer)))))))))

(defun emacsos-assist-web-new-thread ()
  "Refresh the catalog and open a draft now or when usable choices arrive."
  (interactive)
  (setq emacsos-assist-web--new-thread-pending-p t)
  (cond
   ((and (alist-get 'repositories emacsos-assist-web--catalog)
         (alist-get 'harnesses emacsos-assist-web--catalog))
    (emacsos-assist-web-refresh-threads)
    ;; A request setup error can fail synchronously and clear the intent before
    ;; the still-usable cached chooser opens.  A synchronous success already
    ;; opened or deferred it, or confirmed that no current choices remain.
    (when (and (not emacsos-assist-web--new-thread-pending-p)
               (not (active-minibuffer-window))
               (eq emacsos-assist-web--catalog-state 'refresh-failed))
      (setq emacsos-assist-web--new-thread-pending-p t))
    (emacsos-assist-web--open-pending-new-thread))
   ((and emacsos-assist-web--catalog
         (not (memq emacsos-assist-web--catalog-state
                    '(cached refresh-failed))))
    (emacsos-assist-web-refresh-threads)
    (emacsos-assist-web--open-pending-new-thread))
   (t
    (message "Fetching repositories for a new Assist thread…")
    (emacsos-assist-web-refresh-threads))))

(define-derived-mode emacsos-assist-web-mode text-mode "Assist Web"
  "Major mode for a canonical Assist Web thread or unsent local draft."
  (variable-pitch-mode 1)
  (emacsos--chat-enable-presentation)
  (emacsos-conversation-install-actions
   '((send . emacsos-assist-web-send)
     (abort . emacsos-assist-web-abort)
     (refresh . emacsos-assist-web-refresh-thread)
     (older . emacsos-assist-web-load-older)
     (open-object . emacsos-conversation--open-object)
     (catalog . emacsos-assist-web-refresh-threads)))
  (add-hook 'after-change-functions #'emacsos-assist-web--after-change nil t)
  (add-hook 'post-command-hook #'emacsos-assist-web-git--sync-keys nil t)
  (add-hook 'kill-buffer-hook #'emacsos-assist-web-git--teardown nil t)
  (add-hook 'kill-buffer-hook #'emacsos-assist-web--buffer-killed nil t))

(define-key emacsos-assist-web-mode-map (kbd "RET")
            #'emacsos-conversation-activate-or-newline)

(defalias 'emacsos-assist-web--legacy-restore-draft
  (symbol-function 'emacsos-assist-web--restore-draft))
(defalias 'emacsos-assist-web--legacy-refresh-thread
  (symbol-function 'emacsos-assist-web-refresh-thread))
(defalias 'emacsos-assist-web--legacy-save-draft
  (symbol-function 'emacsos-assist-web--save-draft))
(defalias 'emacsos-assist-web--legacy-send
  (symbol-function 'emacsos-assist-web-send))
(defalias 'emacsos-assist-web--legacy-stream-cleanup
  (symbol-function 'emacsos-assist-web--stream-cleanup))
(defalias 'emacsos-assist-web--legacy-event-filter
  (symbol-function 'emacsos-assist-web--event-filter))
(defalias 'emacsos-assist-web--legacy-dispatch-event
  (symbol-function 'emacsos-assist-web--dispatch-event))
(defalias 'emacsos-assist-web--legacy-abort
  (symbol-function 'emacsos-assist-web-abort))
(defalias 'emacsos-assist-web--legacy-stream-finish
  (symbol-function 'emacsos-assist-web--stream-finish))

(defun emacsos-assist-web--legacy-compatibility-p ()
  "Return non-nil only before this buffer has entered queue ownership.

The old no-queue renderer and refresh path remain available for a buffer opened
under earlier code.  Once an entry is resident, delayed callbacks remain queue
callbacks even after reconciliation leaves the resident list empty."
  (not emacsos-assist-web--queue-model-p))

;; A submission is deliberately an ordinary plist.  It is copied into the
;; cache without markers or processes, so durable state cannot accidentally
;; retain a buffer object or claim that a transport survived Emacs.
(defconst emacsos-assist-web--entry-states
  '(recovered-head queued posting acceptance-unknown retryable-rejected rejected
    identity-conflict accepted-unobserved observing terminal-unreconciled reconciling))

(defun emacsos-assist-web--entry (text &optional state key)
  "Create one locally owned submission record for TEXT."
  (list :text text :state (or state 'queued) :key key
        :epoch 0 :run-id nil :live-text nil :rendered nil
        :recovered-ready nil
        :stream-process nil :stream-response nil :stream-header-timer nil
        :stream-generation 0 :stream-admitted nil :handshake-token nil
        :reobserve-generation 0 :reobserve-in-flight nil
        :observer-end-kind nil :observer-end-generation nil
        :observer-end-checked nil :approval-stopped nil
        :reconcile-owner nil
        :cancellation-generation 0
        :requires-reobserve nil
        :verified-outcome nil
        :user-start nil :assistant-start nil :assistant-end nil
        :action-start nil :action-end nil
        :stream-attempt nil :stream-index 0
        :stream-raw-bytes 0 :stream-undecided-suffix ""))

(defun emacsos-assist-web--entry-state (entry)
  "Return ENTRY's explicit resident state."
  (plist-get entry :state))

(defun emacsos-assist-web--entry-active-p (entry)
  "Return non-nil when ENTRY owns a live local transport."
  (memq (emacsos-assist-web--entry-state entry) '(posting observing)))

(defun emacsos-assist-web--queue-entry (key)
  "Return the resident entry named by immutable idempotency KEY."
  (seq-find (lambda (entry) (equal key (plist-get entry :key)))
            emacsos-assist-web--queue))

(defun emacsos-assist-web--entry-callback-current-p (entry epoch)
  "Return non-nil only while ENTRY still owns callback EPOCH in this buffer.

Callbacks retain both immutable key and per-entry epoch.  This makes a removed,
adopted, or retried entry inert before any parser marker or cleanup state is
consulted; selected-buffer state is never a fallback owner."
  (and entry
       (equal (plist-get entry :key)
              (plist-get (emacsos-assist-web--queue-entry
                          (plist-get entry :key)) :key))
       (= epoch (plist-get entry :epoch))))

(defun emacsos-assist-web--queue-head ()
  "Return this buffer's oldest resident entry."
  (car emacsos-assist-web--queue))

(defun emacsos-assist-web--queue-count-limit ()
  "Return the ordinary resident queue limit."
  2)

(defun emacsos-assist-web--queue-transport-active-p ()
  "Return non-nil when this buffer has a POST or SSE in progress."
  (or emacsos-assist-web--post-entry emacsos-assist-web--stream-entry
      (seq-some #'emacsos-assist-web--entry-active-p emacsos-assist-web--queue)))

(defun emacsos-assist-web--web-active-p ()
  "Return non-nil when any canonical buffer owns a POST or observer."
  (seq-some
   (lambda (buffer)
     (and (buffer-live-p buffer)
          (with-current-buffer buffer
            (and (derived-mode-p 'emacsos-assist-web-mode)
                 (if emacsos-assist-web--queue-model-p
                     (emacsos-assist-web--queue-transport-active-p)
                   emacsos-assist-web--in-flight)))))
   (buffer-list)))

(defun emacsos-assist-web--sync-active-surface ()
  "Publish aggregate web activity without giving one web buffer global ownership."
  (cond
   ((eq emacsos--assist-active-surface 'chat) nil)
   ((emacsos-assist-web--web-active-p)
    (setq emacsos--assist-active-surface 'web))
   (t (setq emacsos--assist-active-surface nil))))

(defun emacsos-assist-web--entry-cache-value (entry)
  "Return ENTRY's portable, bounded cache representation."
  `((text . ,(plist-get entry :text))
    (key . ,(plist-get entry :key))
    (state . ,(symbol-name (emacsos-assist-web--entry-state entry)))
    (run_id . ,(plist-get entry :run-id))
    (observer_end_kind . ,(when-let ((kind (plist-get entry :observer-end-kind)))
                            (symbol-name kind)))
    (observer_end_generation . ,(plist-get entry :observer-end-generation))
    (observer_end_checked . ,(and (plist-get entry :observer-end-checked) t))
    (approval_stopped . ,(and (plist-get entry :approval-stopped) t))
    (recovered_ready . ,(and (plist-get entry :recovered-ready) t))
    (live_text . ,(and (plist-get entry :live-text) t))))

(defun emacsos-assist-web--queue-cache-value (&optional queue text recovery-draft)
  "Return the full persisted record for QUEUE and editable TEXT."
  `((text . ,(or text (emacsos-assist-web--input) ""))
    (thread_id . ,emacsos-assist-web--thread-id)
    (queue . ,(mapcar #'emacsos-assist-web--entry-cache-value
                       (or queue emacsos-assist-web--queue)))
    (recovery_draft . ,(or recovery-draft emacsos-assist-web--recovery-draft))
    (collision . ,(and emacsos-assist-web--collision-p t))
    (repo_key . ,emacsos-assist-web--draft-repository)
    (harness . ,emacsos-assist-web--draft-harness)))

(defun emacsos-assist-web--queue-cache-fits-p (queue text &optional recovery-draft)
  "Return non-nil when QUEUE plus TEXT fits one private cache record."
  (<= (string-bytes (json-encode
                      (emacsos-assist-web--queue-cache-value
                       queue text recovery-draft)))
      emacsos-assist-web-max-cache-bytes))

(defun emacsos-assist-web--entry-post-payload (entry)
  "Return ENTRY's exact POST body from the currently durable thread identity."
  (if emacsos-assist-web--thread-id
      `((message . ,(plist-get entry :text)))
    `((message . ,(plist-get entry :text))
      (repo_key . ,emacsos-assist-web--draft-repository)
      (harness . ,(or emacsos-assist-web--draft-harness "deepagents")))))

(defun emacsos-assist-web--save-draft ()
  "Persist queue or legacy state before transport unless recovery is invalid.

An invalid passive recovery retains its original cache unchanged until explicit
repair; reload also preserves and re-enters that fail-closed state, including
when the provisional buffer is killed."
  (if emacsos-assist-web--passive-recovery-invalid-p
      t
    (if (emacsos-assist-web--legacy-compatibility-p)
        (emacsos-assist-web--legacy-save-draft)
    (if-let ((name (emacsos-assist-web--draft-cache-name)))
        (and (emacsos-assist-web--queue-cache-fits-p emacsos-assist-web--queue
                                                     (emacsos-assist-web--input))
             (emacsos-assist-web--try-write-cache
              name (emacsos-assist-web--queue-cache-value)))
      t))))

(defun emacsos-assist-web--entry-set-assistant-status (entry status)
  "Replace ENTRY's provisional assistant body with fixed STATUS."
  (emacsos-assist-web--entry-clear-actions entry)
  (when (and (markerp (plist-get entry :assistant-start))
             (markerp (plist-get entry :assistant-end)))
    (set-marker (plist-get entry :assistant-end)
                (emacsos-conversation-replace-marked
                 (plist-get entry :assistant-start) (plist-get entry :assistant-end)
                 (format "[%s]\n" status)))))

(defun emacsos-assist-web--entry-replace-empty-assistant-status (entry status)
  "Replace ENTRY's empty or queued provisional body with fixed STATUS."
  (when (and (markerp (plist-get entry :assistant-start))
             (markerp (plist-get entry :assistant-end)))
    (let ((body (buffer-substring-no-properties
                 (plist-get entry :assistant-start) (plist-get entry :assistant-end))))
      (when (member body '("" "[queued]\n" "[working; live text unavailable]\n"))
        (emacsos-assist-web--entry-set-assistant-status entry status)))))

(defun emacsos-assist-web--entry-append-pending (entry)
  "Render ENTRY with fresh markers while preserving the editable draft tail."
  (let* ((input-start (emacsos-assist-web--prompt-start))
         (draft (emacsos-assist-web--input))
         (input-offset (and input-start (>= (point) input-start)
                            (- (point) input-start)))
         (prompt-start (and (markerp emacsos-assist-web--prompt-marker)
                            (marker-position emacsos-assist-web--prompt-marker)))
         (inhibit-read-only t))
    (when prompt-start
      (delete-region prompt-start (point-max))
      (emacsos-assist-web--entry-insert-before entry (point))
      (goto-char (point-max))
      (emacsos-assist-web--write-prompt)
      (when (and draft (not (equal draft (plist-get entry :text)))) (insert draft))
      (if input-offset
          (goto-char (min (point-max)
                          (+ (emacsos-assist-web--prompt-start) input-offset)))
        (goto-char (point-max))))))

(defun emacsos-assist-web--entry-insert-before (entry position)
  "Render ENTRY at destination POSITION without touching another entry's markers."
  (save-excursion
    (let ((inhibit-read-only t) (start nil) body-start)
      (goto-char position)
      (setq start (point))
      (insert "you> ")
      (setq body-start (point))
      (insert (plist-get entry :text))
      (setf (plist-get entry :user-start) (copy-marker start))
      (emacsos-conversation-commit-user start body-start (point))
      (insert "\n\nbot> ")
      (setq body-start (point))
      (insert "[queued]\n")
      (pcase-let ((`(,assistant-start . ,assistant-end)
                   (emacsos-conversation-begin-assistant body-start (point))))
        (setf (plist-get entry :assistant-start) assistant-start
              (plist-get entry :assistant-end) assistant-end))
      (emacsos--chat-present-message start body-start (point) 'assistant)
      (add-text-properties start (point) '(read-only t front-sticky t rear-nonsticky t))
      (setf (plist-get entry :rendered) t)
      (point))))

(defun emacsos-assist-web--entry-add-action (entry label action)
  "Append LABEL for ENTRY, invoking ACTION only through that captured entry."
  (when (and (markerp (plist-get entry :assistant-end))
             (marker-buffer (plist-get entry :assistant-end)))
    (let ((buffer (current-buffer)) (key (plist-get entry :key)))
      (save-excursion
        (goto-char (or (and (markerp (plist-get entry :action-end))
                            (marker-buffer (plist-get entry :action-end))
                            (plist-get entry :action-end))
                       (plist-get entry :assistant-end)))
        (let ((inhibit-read-only t) (inhibit-modification-hooks t))
          (unless (and (markerp (plist-get entry :action-start))
                       (marker-buffer (plist-get entry :action-start)))
            (setf (plist-get entry :action-start) (copy-marker (point))))
          (insert-text-button label 'follow-link t
                              'action (lambda (_)
                                        (when (buffer-live-p buffer)
                                          (with-current-buffer buffer
                                            (funcall action key))))
                              'help-echo label)
          (insert "\n")
          (setf (plist-get entry :action-end) (copy-marker (point))))))))

(defun emacsos-assist-web--clear-action-range (start end)
  "Safely remove the rendered action range from START through END."
  (when (and (markerp start) (markerp end)
             (marker-buffer start) (eq (marker-buffer start) (marker-buffer end)))
    (let ((inhibit-read-only t) (inhibit-modification-hooks t))
      (delete-region start end))))

(defun emacsos-assist-web--entry-clear-actions (entry)
  "Remove ENTRY's rendered action buttons without disturbing its message body."
  (emacsos-assist-web--clear-action-range
   (plist-get entry :action-start) (plist-get entry :action-end))
  (setf (plist-get entry :action-start) nil
        (plist-get entry :action-end) nil))

(defun emacsos-assist-web--clear-recovery-draft-action ()
  "Remove the retained-source Restore Draft action, if it is still rendered."
  (let ((start emacsos-assist-web--recovery-action-start)
        (end emacsos-assist-web--recovery-action-marker))
    (emacsos-assist-web--clear-action-range start end)
    (setq emacsos-assist-web--recovery-action-start nil
          emacsos-assist-web--recovery-action-marker nil)))

(defun emacsos-assist-web--restore-recovery-draft (_)
  "Restore the retained source draft only into an empty destination prompt."
  (when emacsos-assist-web--recovery-draft
    (if (not (string-empty-p (string-trim (emacsos-assist-web--input))))
        (emacsos-assist-web--set-prompt-refusal
         "source draft is preserved; destination draft remains editable")
      (let ((recovered emacsos-assist-web--recovery-draft))
        (setq emacsos-assist-web--recovery-draft nil)
        (emacsos-assist-web--replace-input recovered)
        (if (emacsos-assist-web--save-draft)
            (emacsos-assist-web--clear-recovery-draft-action)
          (setq emacsos-assist-web--recovery-draft recovered)
          (emacsos-assist-web--replace-input "")
          (emacsos-assist-web--set-prompt-refusal
           "source draft is preserved; local recovery could not be saved"))))))

(defun emacsos-assist-web--render-recovery-draft-action ()
  "Render the one retained-source Restore Draft action before the prompt."
  (when (and emacsos-assist-web--recovery-draft
             (not (and (markerp emacsos-assist-web--recovery-action-marker)
                       (marker-buffer emacsos-assist-web--recovery-action-marker))))
    (when-let ((prompt (and (markerp emacsos-assist-web--prompt-marker)
                            (marker-buffer emacsos-assist-web--prompt-marker)
                            (marker-position emacsos-assist-web--prompt-marker))))
      (let ((inhibit-read-only t) (inhibit-modification-hooks t))
        (goto-char prompt)
        (setq emacsos-assist-web--recovery-action-start (copy-marker (point)))
        (insert "[source draft saved: ")
        (insert-text-button "Restore Draft" 'follow-link t
                            'action #'emacsos-assist-web--restore-recovery-draft
                            'help-echo "Restore Draft")
        (insert "]\n")
        (setq emacsos-assist-web--recovery-action-marker (copy-marker (point)))
        (set-marker emacsos-assist-web--prompt-marker (point))))))

(defun emacsos-assist-web--entry-render (entry)
  "Insert ENTRY's own provisional user and assistant regions once."
  (unless (plist-get entry :rendered)
    (emacsos-assist-web--entry-append-pending entry)
    (pcase (emacsos-assist-web--entry-state entry)
      ('recovered-head
       (emacsos-assist-web--entry-status entry "recovered draft; tap Restore Draft")
       (emacsos-assist-web--entry-add-action
        entry "Restore Draft" #'emacsos-assist-web--restore-create-entry))
      ('rejected
       (emacsos-assist-web--entry-status entry "submission rejected; tap Dismiss")
       (emacsos-assist-web--entry-add-action
        entry "Dismiss" #'emacsos-assist-web--dismiss-entry)
       (unless emacsos-assist-web--thread-id
         (emacsos-assist-web--entry-add-action
          entry "Reset Draft" #'emacsos-assist-web--reset-create-entry))))))

(defun emacsos-assist-web--rerender-queue ()
  "Rebuild every provisional entry in durable queue order, preserving the tail."
  (let* ((draft (emacsos-assist-web--input))
         (starts (delq nil
                       (mapcar (lambda (entry)
                                 (let ((marker (plist-get entry :user-start)))
                                   (and (markerp marker) (marker-buffer marker) marker)))
                               emacsos-assist-web--queue))))
    (when starts
      (let ((inhibit-read-only t) (inhibit-modification-hooks t))
        (dolist (entry emacsos-assist-web--queue)
          (emacsos-assist-web--entry-clear-actions entry))
        (emacsos-assist-web--clear-recovery-draft-action)
        (delete-region (apply #'min (mapcar #'marker-position starts)) (point-max))
        (emacsos-assist-web--write-prompt)))
    (dolist (entry emacsos-assist-web--queue)
      (setf (plist-get entry :rendered) nil
            (plist-get entry :user-start) nil
            (plist-get entry :assistant-start) nil
            (plist-get entry :assistant-end) nil
            (plist-get entry :action-start) nil
            (plist-get entry :action-end) nil)
      (emacsos-assist-web--entry-render entry))
    (emacsos-assist-web--replace-input draft)
    (emacsos-assist-web--render-recovery-draft-action)))

(defun emacsos-assist-web--discard-entry-render (entry draft point-offset)
  "Remove unpersisted ENTRY and restore exact editable DRAFT/POINT-OFFSET."
  (when (and (plist-get entry :rendered)
             (markerp (plist-get entry :user-start))
             (marker-buffer (plist-get entry :user-start)))
    (emacsos-assist-web--entry-clear-actions entry)
    (let ((inhibit-read-only t) (inhibit-modification-hooks t))
      (delete-region (plist-get entry :user-start) (point-max))
      (emacsos-assist-web--write-prompt)
      (emacsos-assist-web--replace-input draft)
      (goto-char (min (point-max)
                       (+ (emacsos-assist-web--prompt-start) point-offset)))))
  (setf (plist-get entry :rendered) nil
        (plist-get entry :user-start) nil
        (plist-get entry :assistant-start) nil
        (plist-get entry :assistant-end) nil
        (plist-get entry :action-start) nil
        (plist-get entry :action-end) nil))

(defun emacsos-assist-web--entry-remove-render (entry)
  "Remove only ENTRY's provisional region while preserving following FIFO work."
  (when-let ((start (and (markerp (plist-get entry :user-start))
                         (marker-buffer (plist-get entry :user-start))
                         (marker-position (plist-get entry :user-start)))))
    ;; This changes following marker positions, so find FIFO's boundary only
    ;; after deleting the entry's own action range.
    (emacsos-assist-web--entry-clear-actions entry)
    (let ((end (or (seq-some (lambda (candidate)
                               (let ((marker (plist-get candidate :user-start)))
                                 (and (markerp marker) (marker-buffer marker)
                                      (> (marker-position marker) start)
                                      (marker-position marker))))
                             emacsos-assist-web--queue)
                   (and (markerp emacsos-assist-web--prompt-marker)
                        (marker-buffer emacsos-assist-web--prompt-marker)
                        (marker-position emacsos-assist-web--prompt-marker)))))
      (when end
        (let ((inhibit-read-only t) (inhibit-modification-hooks t))
          (delete-region start end)))))
  (setf (plist-get entry :rendered) nil
        (plist-get entry :user-start) nil
        (plist-get entry :assistant-start) nil
        (plist-get entry :assistant-end) nil
        (plist-get entry :action-start) nil
        (plist-get entry :action-end) nil))

(defun emacsos-assist-web--set-prompt-refusal (status)
  "Show fixed STATUS for the unchanged draft without sharing async status state."
  (setq emacsos-assist-web--prompt-refusal
        (cons (emacsos-assist-web--input) status))
  (emacsos-assist-web--set-status status))

(defun emacsos-assist-web--clear-prompt-refusal-if-changed ()
  "Clear a refusal only after its exact retained draft changes."
  (when (and emacsos-assist-web--prompt-refusal
             (not (equal (car emacsos-assist-web--prompt-refusal)
                         (emacsos-assist-web--input))))
    (setq emacsos-assist-web--prompt-refusal nil)))

(defun emacsos-assist-web--admit-text-p (text)
  "Check cheap local limits for TEXT before constructing an entry or region."
  (cond
   ((not (emacsos-assist-web--message-fits-p text emacsos-assist-web--thread-id))
    (emacsos-assist-web--set-prompt-refusal
     "message too large; message remains in draft") nil)
   (emacsos-assist-web--collision-p
    (emacsos-assist-web--set-prompt-refusal
     "submission identity conflict; message remains in draft") nil)
   ((>= (length emacsos-assist-web--queue)
        (emacsos-assist-web--queue-count-limit))
    (emacsos-assist-web--set-prompt-refusal "queue full; message remains in draft") nil)
   (t t)))

(defun emacsos-assist-web--enqueue-text (text)
  "Durably enqueue TEXT, or restore its exact editable draft on failure."
  (let* ((draft (emacsos-assist-web--input))
         (point-offset (max 0 (- (point) (or (emacsos-assist-web--prompt-start)
                                               (point-min)))))
         (entry (emacsos-assist-web--entry text 'queued nil)))
    ;; Validate the actual endpoint body, then a byte-identical prospective
    ;; cache key, before minting an identity or rendering a provisional region.
    (json-encode (emacsos-assist-web--entry-post-payload entry))
    (let ((prospective (copy-tree entry)))
      (setf (plist-get prospective :key)
            "emacsos-00000000000000000000000000000000")
      (if (not (emacsos-assist-web--queue-cache-fits-p
                (append emacsos-assist-web--queue (list prospective)) ""))
        (progn
          (emacsos-assist-web--set-prompt-refusal
           "local cache full; message remains in draft")
          nil)
      (setf (plist-get entry :key) (emacsos-assist-web--new-idempotency-key))
      (let ((candidate (append emacsos-assist-web--queue (list entry))))
      (setq emacsos-assist-web--queue candidate
            emacsos-assist-web--queue-model-p t)
      (cl-incf emacsos-assist-web--refresh-generation)
      (emacsos-assist-web--entry-render entry)
      (emacsos-assist-web--replace-input "")
      (if (emacsos-assist-web--save-draft)
          entry
        (setq emacsos-assist-web--queue
              (delq entry emacsos-assist-web--queue))
        (emacsos-assist-web--discard-entry-render entry draft point-offset)
        (emacsos-assist-web--set-prompt-refusal
         "local cache full; message remains in draft")
        nil))))))

(defun emacsos-assist-web--post-classification (value error)
  "Classify VALUE/ERROR without exposing server-controlled detail text."
  (cond
   ((equal error "Assist Web token is missing or invalid") 'retryable-rejected)
   (error 'acceptance-unknown)
   ((and (alist-get 'thread_id value) (alist-get 'run_id value)) 'accepted)
   ((= (or (alist-get 'http_status value) 0) 429) 'retryable-rejected)
   ((and (= (or (alist-get 'http_status value) 0) 503)
         (equal (alist-get 'detail value) "run-store-unavailable"))
    'retryable-rejected)
   ((and (= (or (alist-get 'http_status value) 0) 409)
         (member (alist-get 'detail value)
                 '("Resolve the pending approval first" "pending approval")))
    'retryable-rejected)
   ((or (member (alist-get 'http_status value) '(413 422))
        (and (= (or (alist-get 'http_status value) 0) 409)
             (equal (alist-get 'detail value) "Thread harness is unavailable")))
    'rejected)
   ((and (= (or (alist-get 'http_status value) 0) 409)
         (member (alist-get 'detail value)
                 '("Idempotency-Key conflicts with prior message"
                   "Phone draft conflicts with an existing thread")))
    'identity-conflict)
   (t 'acceptance-unknown)))

(defun emacsos-assist-web--entry-status (entry status)
  "Render fixed STATUS in ENTRY's own provisional assistant region."
  (emacsos-assist-web--entry-set-assistant-status entry status))

(defun emacsos-assist-web--abort-receipt-status (entry status)
  "Report unconfirmed abort STATUS without replacing ENTRY's live evidence."
  (if (eq entry emacsos-assist-web--stream-entry)
      (emacsos-assist-web--set-status status)
    (emacsos-assist-web--entry-status entry status)))

(defun emacsos-assist-web--entry-reset-assistant (entry attempt)
  "Reset ENTRY's exact assistant region for integer stream ATTEMPT."
  (unless (integerp attempt) (error "invalid stream attempt"))
  (emacsos-assist-web--entry-clear-actions entry)
  (setf (plist-get entry :stream-attempt) attempt
        (plist-get entry :stream-index) 0
        (plist-get entry :stream-raw-bytes) 0
        (plist-get entry :stream-undecided-suffix) "")
  (when (and (markerp (plist-get entry :assistant-start))
             (markerp (plist-get entry :assistant-end)))
    (set-marker (plist-get entry :assistant-end)
                (emacsos-conversation-reset-assistant
                 (plist-get entry :assistant-start) (plist-get entry :assistant-end)))))

(defun emacsos-assist-web--entry-append-rendered-delta (entry text)
  "Append canonical TEXT only inside ENTRY's owned assistant marker range."
  (unless (and (markerp (plist-get entry :assistant-end))
               (marker-buffer (plist-get entry :assistant-end)))
    (error "invalid Assist delta"))
  ;; A terminal action is outside the assistant body.  Remove it before
  ;; extending the body marker so resumed entry-owned text cannot enter it.
  (emacsos-assist-web--entry-clear-actions entry)
  (set-marker (plist-get entry :assistant-end)
              (emacsos-conversation-append-delta
               (plist-get entry :assistant-end) text)))

(defun emacsos-assist-web--entry-append-delta (entry attempt index text)
  "Append one validated SSE delta to ENTRY's exact marker range."
  (unless (and (integerp attempt) (integerp index) (stringp text)
               (<= (string-bytes text) (* 16 1024)))
    (error "invalid Assist delta"))
  (cond
   ((not (integerp (plist-get entry :stream-attempt)))
    (error "Assist stream is missing its reset"))
   ((< attempt (plist-get entry :stream-attempt)) nil)
   ((or (/= attempt (plist-get entry :stream-attempt))
        (/= index (1+ (or (plist-get entry :stream-index) 0))))
    (error "Assist stream has a gap"))
   ((and (markerp (plist-get entry :assistant-start))
         (markerp (plist-get entry :assistant-end))
         (marker-buffer (plist-get entry :assistant-end)))
    (let ((total (+ (or (plist-get entry :stream-raw-bytes) 0)
                    (string-bytes text))))
      (when (> total emacsos-assist-web--max-message-bytes)
        (error "invalid Assist delta"))
      (pcase-let ((`(,canonical . ,suffix)
                   (emacsos-assist-web--stream-decidable-text
                    (concat (or (plist-get entry :stream-undecided-suffix) "") text))))
        (emacsos-assist-web--entry-append-rendered-delta entry canonical)
        (setf (plist-get entry :stream-index) index
              (plist-get entry :stream-raw-bytes) total
              (plist-get entry :stream-undecided-suffix) suffix))
      (emacsos-assist-web--set-status "working")))))

(defun emacsos-assist-web--entry-finish-stream-tail (target entry epoch)
  "Fence ENTRY at EPOCH, then flush its safe suffix before Run reconciliation."
  (when (emacsos-assist-web--entry-current-in-buffer-p target entry epoch)
    (with-current-buffer target
      (let ((inhibit-quit t)
            (suffix (plist-get entry :stream-undecided-suffix)))
        ;; A terminal SSE is evidence of an ended observer even when its
        ;; optional provisional text suffix cannot be displayed.  Do not
        ;; reinterpret a renderer failure as a network disconnect.
        (when (and emacsos-assist-web--thread-id (plist-get entry :run-id))
          (emacsos-assist-web-git--stop-reobserve entry 'terminal-sse))
        (condition-case nil
            (cond
             ((equal suffix "\r")
              (emacsos-assist-web--entry-append-rendered-delta entry "\n"))
             ((equal suffix (string #x1f3f4))
              (emacsos-assist-web--entry-append-rendered-delta entry suffix)))
          ((error quit) nil))
        (setf (plist-get entry :stream-undecided-suffix) "")
        (emacsos-assist-web--stream-finish target)))))

(defun emacsos-assist-web--dispatch-event (target event data)
  "Dispatch SSE EVENT only to TARGET's exact observed queue entry."
  (when (buffer-live-p target)
    (with-current-buffer target
      (if-let ((entry emacsos-assist-web--stream-entry))
          (condition-case problem
              (cond
             ((equal event "status")
              (let* ((status (json-parse-string data :object-type 'alist))
                     (text (alist-get 'status status)))
                (unless (and (listp status)
                             (= (cl-count 'status status :key #'car) 1)
                             (emacsos-conversation-valid-status-p text))
                  (error "invalid Assist status"))
                (emacsos-assist-web--set-status text)))
             ((equal event "assistant-reset")
              (emacsos-assist-web--entry-reset-assistant
               entry (alist-get 'attempt (json-parse-string data :object-type 'alist))))
             ((equal event "assistant-delta")
              (let ((value (json-parse-string data :object-type 'alist)))
                (emacsos-assist-web--entry-append-delta
                 entry (alist-get 'attempt value) (alist-get 'index value)
                 (alist-get 'text value))))
             ((equal event "assistant-truncated")
              (emacsos-assist-web--entry-replace-empty-assistant-status
               entry "live text truncated; waiting for final")
             (emacsos-assist-web--set-status "live text truncated; waiting for final"))
             ((equal event "terminal")
              (emacsos-assist-web--entry-finish-stream-tail
               target entry (plist-get entry :epoch)))
             ((equal event "error")
              (let ((detail (alist-get 'detail
                                       (json-parse-string data :object-type 'alist))))
                (emacsos-assist-web--entry-observation-interrupted
                 entry (plist-get entry :epoch)
                 (if (equal detail "run-store-unavailable")
                     "observation unavailable; operator repair required"
                   "observation interrupted"))))
             ;; Queue transport recognizes only entry-owned payloads here.
             ;; A late singleton closure cannot choose a region.
             (t nil))
            ((error quit)
             (emacsos-assist-web--entry-observation-interrupted
              entry (plist-get entry :epoch) (error-message-string problem))))
        (when (and (not entry)
                   (emacsos-assist-web--legacy-compatibility-p))
          (emacsos-assist-web--legacy-dispatch-event target event data))))))

(defun emacsos-assist-web--release-handshake (entry)
  "Release ENTRY's pre-header request token exactly once."
  (when-let ((token (plist-get entry :handshake-token)))
    (setq emacsos-assist-web--requests
          (delq token emacsos-assist-web--requests))
    (setf (plist-get entry :handshake-token) nil)))

(defun emacsos-assist-web--cleanup-handshake (entry epoch)
  "Release ENTRY's handshake only when its captured EPOCH still owns it.

Every pre-header exit uses this small primitive.  A delayed callback from an
older observer cannot consume the token reserved by a later retry of ENTRY."
  (when (and entry (= epoch (plist-get entry :epoch)))
    (emacsos-assist-web--release-handshake entry)))

(defun emacsos-assist-web--stream-cleanup (&optional keep-pending no-render)
  "Clean up the current entry's stream and its pre-header budget token."
  (if (emacsos-assist-web--legacy-compatibility-p)
      (emacsos-assist-web--legacy-stream-cleanup keep-pending no-render)
    (when-let ((entry emacsos-assist-web--stream-entry))
      (let ((process (plist-get entry :stream-process))
            (response (plist-get entry :stream-response))
            (timer (plist-get entry :stream-header-timer)))
        ;; Queue transport is entry-owned.  Do not let a terminal/abort path
        ;; re-enter the legacy singleton cleanup merely because a buffer also
        ;; has old nonqueue locals from before recovery.
        (when (timerp timer) (cancel-timer timer))
        (setf (plist-get entry :stream-process) nil
              (plist-get entry :stream-response) nil
              (plist-get entry :stream-header-timer) nil
              (plist-get entry :stream-admitted) nil
              (plist-get entry :stream-raw-bytes) nil
              (plist-get entry :stream-undecided-suffix) nil)
        (setq emacsos-assist-web--stream-entry nil)
        (emacsos-assist-web--entry-clear-actions entry)
        (emacsos-assist-web--release-handshake entry)
        (when (process-live-p process) (delete-process process))
        (when (buffer-live-p response)
          (emacsos-assist-web--kill-buffer-later response))))))

(defun emacsos-assist-web--buffer-killed ()
  "Persist recoverable queue state and release every entry-owned token.

No request token may outlive its buffer: a killed buffer has no callback which
could release a pre-header SSE reservation later."
  (when (timerp emacsos-assist-web--draft-save-timer)
    (cancel-timer emacsos-assist-web--draft-save-timer))
  (if (not emacsos-assist-web--queue)
      (unwind-protect
          (emacsos-assist-web--save-draft)
        (emacsos-assist-web--stream-cleanup t t))
    (unwind-protect
        (emacsos-assist-web--save-draft)
      (dolist (entry emacsos-assist-web--queue)
        (emacsos-assist-web--release-handshake entry))
      ;; Use the public cleanup wrapper so a killed queue owner releases the
      ;; exact observer before the legacy transport state is discarded.
      (emacsos-assist-web--stream-cleanup t t)
      (setq emacsos-assist-web--post-entry nil)))
  (emacsos-assist-web--sync-active-surface))

(defun emacsos-assist-web--start-post (entry)
  "Asynchronously submit ENTRY, serializing only acknowledgement callbacks."
  (when (and entry (not emacsos-assist-web--post-entry)
             (memq (emacsos-assist-web--entry-state entry)
                   '(queued acceptance-unknown retryable-rejected recovered-head))
             (or (not (eq (emacsos-assist-web--entry-state entry) 'recovered-head))
                 (plist-get entry :recovered-ready)))
    (unless (plist-get entry :key)
      (setf (plist-get entry :key) (emacsos-assist-web--new-idempotency-key)))
    (setf (plist-get entry :state) 'posting
          (plist-get entry :epoch) (1+ (plist-get entry :epoch)))
    (setq emacsos-assist-web--post-entry entry)
    (emacsos-assist-web--entry-render entry)
    (if (not (emacsos-assist-web--save-draft))
        (progn
          (setf (plist-get entry :state) 'retryable-rejected)
          (setq emacsos-assist-web--post-entry nil)
          (emacsos-assist-web--entry-status entry "not sent; local cache write failed"))
      (let* ((buffer (current-buffer))
             (key (plist-get entry :key))
             (epoch (plist-get entry :epoch))
             (existing-thread-id emacsos-assist-web--thread-id)
             (path (if existing-thread-id
                       (format "threads/%s/messages"
                               (emacsos-assist-web--require-id existing-thread-id))
                     "threads"))
             (payload (emacsos-assist-web--entry-post-payload entry)))
        (emacsos-assist-web--sync-active-surface)
        (emacsos-assist-web--request
         "POST" path payload
         (lambda (value error)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (let ((current (emacsos-assist-web--queue-entry key)))
                 (when (and current (= epoch (plist-get current :epoch))
                            (eq current emacsos-assist-web--post-entry))
                   (setq emacsos-assist-web--post-entry nil)
                   (pcase (emacsos-assist-web--post-classification value error)
                     ('accepted
                      (let (accepted-run-id)
                        (condition-case problem
                            (let ((thread-id (emacsos-assist-web--require-id
                                              (alist-get 'thread_id value)))
                                  (run-id (emacsos-assist-web--require-id
                                           (alist-get 'run_id value))))
                              ;; Keep validated acceptance separate from the
                              ;; fallible adoption/cache work below.  Its
                              ;; recovery must retain this exact Run.
                              (setq accepted-run-id run-id)
                            (let ((canonical
                                   (and (not existing-thread-id)
                                        (emacsos-assist-web--thread-buffer thread-id))))
                            (if (and emacsos-assist-web--thread-id
                                     (not (equal thread-id emacsos-assist-web--thread-id)))
                                (error "Assist Web send changed thread identity")
                              (setf (plist-get current :run-id) run-id
                                    (plist-get current :live-text)
                                    (and (alist-get 'live_text value) t)
                                    (plist-get current :state) 'accepted-unobserved
                                    ;; Adoption retains C1's observer.  Mark S1
                                    ;; before the merge so a C1 terminal cannot
                                    ;; start S1 SSE before its exact Run GET.
                                    (plist-get current :requires-reobserve)
                                    (and canonical (not (eq canonical buffer))))
                              (let ((owner buffer) adopted)
                                ;; Source retains the returned thread identity
                                ;; in its own draft record until adoption commits,
                                ;; so a rollback can exact-GET this Run.
                                (if (and canonical (not (eq canonical buffer)))
                                    (if (emacsos-assist-web--adopt-canonical-buffer
                                         buffer canonical current run-id)
                                        (setq owner canonical
                                              adopted t)
                                      ;; Adoption has unwound the canonical
                                      ;; buffer before returning.  Reinstate
                                      ;; the receipt in SOURCE's resident list
                                      ;; so the next action is exact Run GET,
                                      ;; never a second POST.
                                      (with-current-buffer buffer
                                        (setf (plist-get current :run-id) run-id
                                              (plist-get current :state)
                                              'accepted-unobserved)
                                        (setq emacsos-assist-web--queue
                                              (mapcar (lambda (entry)
                                                        (if (equal key (plist-get entry :key))
                                                            current
                                                          entry))
                                                      emacsos-assist-web--queue))
                                        (emacsos-assist-web--entry-status
                                         current "accepted; canonical adoption needs recovery")))
                                  (setq emacsos-assist-web--thread-id thread-id
                                        emacsos-assist-web--draft-id nil)
                                  (unless (emacsos-assist-web--save-draft)
                                    (error "accepted; local recovery could not be saved"))
                                  ;; The canonical thread record is durable now;
                                  ;; retire the unowned new-thread draft before
                                  ;; starting an observer which might outlive it.
                                  (when (and (not existing-thread-id)
                                             (not (emacsos-assist-web--delete-cache
                                                   "drafts/new-thread.json")))
                                    (error "accepted; local draft could not be retired")))
                                (when (buffer-live-p owner)
                                  (with-current-buffer owner
                                    ;; S1 has changed controllers.  Confirm its
                                    ;; exact persisted Run before C1 can yield
                                    ;; the observer slot to it.
                                    (if (or adopted canonical)
                                        (emacsos-assist-web--reobserve-entry current)
                                      (emacsos-assist-web--start-observation current))
                                    (emacsos-assist-web--pump-posts)))))))
                          (error
                           ;; The POST response already proved this exact Run.
                           ;; An adoption/cache failure must never erase that
                           ;; proof and turn a later retry into another POST.
                           (when accepted-run-id
                             (setf (plist-get current :run-id) accepted-run-id))
                           (setf (plist-get current :state)
                                 (if (plist-get current :run-id)
                                     'accepted-unobserved
                                   'acceptance-unknown))
                           (emacsos-assist-web--entry-status
                            current (if (plist-get current :run-id)
                                        "accepted; canonical adoption needs recovery"
                                      "acceptance unknown; Send retries safely"))
                           (emacsos-assist-web--save-draft)))))
                     ('retryable-rejected
                      (setf (plist-get current :state) 'retryable-rejected)
                      (emacsos-assist-web--entry-status
                       current "submission unavailable; Send retries")
                      (emacsos-assist-web--save-draft))
                     ('rejected
                      (setf (plist-get current :state) 'rejected)
                      (emacsos-assist-web--entry-status
                       current "submission rejected; tap Dismiss")
                      (emacsos-assist-web--entry-add-action
                       current "Dismiss" #'emacsos-assist-web--dismiss-entry)
                      (when (not existing-thread-id)
                        (emacsos-assist-web--entry-add-action
                         current "Reset Draft" #'emacsos-assist-web--reset-create-entry))
                      (when (emacsos-assist-web--save-draft)
                        (emacsos-assist-web--pump-posts)))
                     ('identity-conflict
                      (setf (plist-get current :state) 'identity-conflict)
                      (emacsos-assist-web--entry-status
                       current "submission identity conflict; repair required")
                      (emacsos-assist-web--save-draft))
                     (_
                      (setf (plist-get current :state) 'acceptance-unknown)
                      (emacsos-assist-web--entry-status
                       current "acceptance unknown; Send retries safely")
                      (emacsos-assist-web--save-draft)))
                   (emacsos-assist-web--sync-active-surface))))))
         `(("Idempotency-Key" . ,key)) t)))))

(defun emacsos-assist-web--pump-posts ()
  "Start the oldest admissible POST without bypassing an admission barrier."
  (unless (or emacsos-assist-web--passive-recovery-invalid-p
              emacsos-assist-web--reconcile-recovery-paused
              emacsos-assist-web--manual-recovery-required
              emacsos-assist-web--post-entry)
    (let ((entry (seq-find (lambda (candidate)
                             (memq (emacsos-assist-web--entry-state candidate)
                                   '(queued acceptance-unknown retryable-rejected recovered-head)))
                           emacsos-assist-web--queue)))
      (when entry
        (if (or (catch 'unsettled-predecessor
                  (dolist (candidate emacsos-assist-web--queue)
                    (if (eq candidate entry)
                        (throw 'unsettled-predecessor nil)
                      (unless (or (eq (emacsos-assist-web--entry-state candidate)
                                      'rejected)
                                  (and (eq (emacsos-assist-web--entry-state candidate)
                                           'terminal-unreconciled)
                                       (plist-get candidate :verified-outcome)
                                       (not (plist-get candidate :requires-reobserve))))
                        (throw 'unsettled-predecessor t)))))
                (and (not emacsos-assist-web--thread-id)
                     (not (eq entry (emacsos-assist-web--queue-head))))
                (and (eq (emacsos-assist-web--entry-state entry) 'recovered-head)
                     (not (plist-get entry :recovered-ready)))
                (and (not (eq entry (emacsos-assist-web--queue-head)))
                     (memq (emacsos-assist-web--entry-state
                            (emacsos-assist-web--queue-head))
                           '(acceptance-unknown retryable-rejected identity-conflict))) )
            nil
          (emacsos-assist-web--start-post entry))))))

(defun emacsos-assist-web--start-observation (entry)
  "Start ENTRY's exact Run observation when this buffer owns no observer."
  (when (and entry (not emacsos-assist-web--stream-entry)
             (eq (emacsos-assist-web--entry-state entry) 'accepted-unobserved))
    (emacsos-assist-web--entry-clear-actions entry)
    (if (eq emacsos--assist-active-surface 'chat)
        (emacsos-assist-web--entry-status entry
                                           "another conversation is active; Refresh retries")
      (if (>= (length emacsos-assist-web--requests)
              emacsos-assist-web-max-concurrent-requests)
          (emacsos-assist-web--entry-status
           entry "accepted; observation handshake capacity full; Refresh retries")
        (let ((token (list (current-buffer) (plist-get entry :key))))
          (push token emacsos-assist-web--requests)
          (setf (plist-get entry :handshake-token) token
                (plist-get entry :state) 'observing
                (plist-get entry :stream-admitted) nil
                (plist-get entry :epoch) (1+ (plist-get entry :epoch)))
          (setq emacsos-assist-web--stream-entry entry)
          (if (condition-case nil (emacsos-assist-web--save-draft)
                ((error quit) nil))
              (progn
                ;; Launch the owned SSE before optional UI can signal.  A
                ;; prelaunch failure must retire its token and rearm Refresh.
                (condition-case problem
                    (emacsos-assist-web--observe-entry entry)
                  ((error quit)
                   (emacsos-assist-web--entry-observation-interrupted
                    entry (plist-get entry :epoch)
                    (error-message-string problem))))
                (when (eq entry emacsos-assist-web--stream-entry)
                  (condition-case nil
                      (progn
                        (emacsos-assist-web--sync-active-surface)
                        (emacsos-assist-web--entry-add-action
                         entry "Abort/Detach" #'emacsos-assist-web--abort-entry))
                    ((error quit) nil))))
            ;; No observer may outlive an unpersisted observing claim.
            (emacsos-assist-web--release-handshake entry)
            (setf (plist-get entry :state) 'accepted-unobserved)
            (setq emacsos-assist-web--stream-entry nil)
            (emacsos-assist-web--entry-status
             entry "accepted; local recovery could not be saved")))))))

(defun emacsos-assist-web--entry-observation-interrupted (entry epoch status)
  "Stop and save ENTRY's observer at EPOCH, or pause recovery."
  (when (and (emacsos-assist-web--entry-callback-current-p entry epoch)
             (eq entry emacsos-assist-web--stream-entry)
             (eq (emacsos-assist-web--entry-state entry) 'observing))
    (let ((inhibit-quit t)
          (kind (if (member status
                            '("observation unavailable; operator repair required"
                              "Assist observation was rejected"))
                    'operator-repair 'disconnect)))
      ;; Fence before any mutable end state, cleanup, or provisional render.
      (when (and emacsos-assist-web--thread-id (plist-get entry :run-id))
        (emacsos-assist-web-git--stop-reobserve entry kind)
        (setf (plist-get entry :observer-end-kind) kind
              (plist-get entry :observer-end-generation) epoch
              (plist-get entry :observer-end-checked) nil))
      (when-let ((timer (plist-get entry :stream-header-timer)))
        (when (timerp timer) (cancel-timer timer)))
      (let ((process (plist-get entry :stream-process))
            (response (plist-get entry :stream-response)))
        ;; Clear exact ownership before tearing transport down: its sentinel
        ;; can run synchronously and must see an inert stale callback.
        (setf (plist-get entry :stream-process) nil
              (plist-get entry :stream-response) nil
              (plist-get entry :stream-header-timer) nil
              (plist-get entry :stream-admitted) nil
              (plist-get entry :stream-raw-bytes) nil
              (plist-get entry :stream-undecided-suffix) nil
              (plist-get entry :state) 'accepted-unobserved
              (plist-get entry :requires-reobserve) t)
        (setq emacsos-assist-web--stream-entry nil)
        (condition-case nil
            (when (process-live-p process) (delete-process process))
          ((error quit) nil))
        ;; A filter may retire this entry from inside RESPONSE.  Let url-http
        ;; complete its final marker update before reclaiming that buffer.
        (when (buffer-live-p response)
          (condition-case nil
              (emacsos-assist-web--kill-buffer-later response)
            ((error quit) nil))))
      (emacsos-assist-web--cleanup-handshake entry epoch)
      (if emacsos-assist-web--manual-recovery-active
          (emacsos-assist-web--manual-recovery-rearm
           entry "observation disconnected")
        (unless (condition-case nil (emacsos-assist-web--save-draft)
                  ((error quit) nil))
          (setq emacsos-assist-web--reconcile-recovery-paused t)
          (emacsos-assist-web-git--invalidate
           "local observation could not be saved; restart to recover"))))
    ;; Provisional text and status are presentation; their hooks cannot undo
    ;; the persisted interruption or leave this observer occupying the slot.
    (condition-case nil
        (if emacsos-assist-web--reconcile-recovery-paused
            (emacsos-assist-web--entry-status
             entry "local observation could not be saved; restart to recover")
          (emacsos-assist-web--entry-replace-empty-assistant-status entry status)
          (if (eq (plist-get entry :observer-end-kind) 'operator-repair)
              (emacsos-assist-web--set-status
               "unverified; operator repair; then Refresh")
            (emacsos-assist-web--set-unverified-status status))
          (emacsos-assist-web--sync-active-surface))
      ((error quit) nil))))

(defun emacsos-assist-web--interrupt-entry-in-buffer (target entry epoch status)
  "Apply ENTRY/EPOCH interruption only while TARGET remains its owner."
  (when (buffer-live-p target)
    (with-current-buffer target
      (emacsos-assist-web--entry-observation-interrupted entry epoch status))))

(defun emacsos-assist-web--entry-current-in-buffer-p (target entry epoch)
  "Return non-nil only when TARGET still owns ENTRY at exact EPOCH."
  (and (buffer-live-p target)
       (with-current-buffer target
         (and (eq entry emacsos-assist-web--stream-entry)
              (emacsos-assist-web--entry-callback-current-p entry epoch)))))

(defun emacsos-assist-web--entry-finish-observation-response (target entry epoch response)
  "Settle exact ENTRY/EPOCH when RESPONSE ends without a terminal event."
  (let* ((inhibit-quit t)
        (unavailable
         (condition-case nil
             (and (buffer-live-p response)
                  (emacsos-assist-web--run-store-unavailable-response-p response))
           ((error quit) nil))))
    ;; Full URL completion wins over the 503 body deadline.  Its deferred
    ;; classifier still lets the event filter dispatch a final terminal.
    (when (emacsos-assist-web--entry-current-in-buffer-p target entry epoch)
      (with-current-buffer target
        (when-let ((timer (plist-get entry :stream-header-timer)))
          (when (timerp timer) (cancel-timer timer))
          (setf (plist-get entry :stream-header-timer) nil))))
    ;; url-http runs this from its final filter call.  Defer so that filter can
    ;; still dispatch a final terminal or error event first.
    (condition-case nil
        (run-at-time
         0 nil
         (lambda (expected expected-epoch store-unavailable)
           (when (emacsos-assist-web--entry-current-in-buffer-p
                  target expected expected-epoch)
             (emacsos-assist-web--interrupt-entry-in-buffer
              target expected expected-epoch
              (if store-unavailable
                  "observation unavailable; operator repair required"
                "observation disconnected"))))
         entry epoch unavailable)
      ((error quit)
       (when (emacsos-assist-web--entry-current-in-buffer-p target entry epoch)
         (emacsos-assist-web--interrupt-entry-in-buffer
          target entry epoch "observation disconnected"))))))

(defun emacsos-assist-web--entry-stream-sentinel (url-sentinel target entry epoch)
  "Preserve URL-SENTINEL and retire only the captured ENTRY/EPOCH on close."
  (lambda (ended event)
    (if (functionp url-sentinel)
        ;; url-retrieve's sentinel schedules the final response completion;
        ;; it must remain the sole owner so a generic disconnect cannot race
        ;; a terminal event or sanitized 503 classification.
        (condition-case nil
            (funcall url-sentinel ended event)
          ((error quit)
           (emacsos-assist-web--entry-finish-observation-response
            target entry epoch (process-buffer ended))))
      (when (and (not (process-live-p ended))
                 (emacsos-assist-web--entry-current-in-buffer-p target entry epoch)
                 (eq ended (plist-get entry :stream-process)))
        (emacsos-assist-web--interrupt-entry-in-buffer
         target entry epoch "observation disconnected")))))

(defun emacsos-assist-web--entry-event-filter (url-filter target entry epoch)
  "Wrap URL-FILTER and parse SSE only for captured ENTRY/EPOCH.

The parser's response-local markers and ENTRY's render markers remain scoped to
this one transport.  No late callback can select a successor from globals."
  (lambda (process bytes)
    (condition-case problem
      (let ((response (process-buffer process)))
      (when (functionp url-filter) (funcall url-filter process bytes))
      (when (and (buffer-live-p response)
                 (emacsos-assist-web--entry-current-in-buffer-p target entry epoch))
        (with-current-buffer response
          (when (and (boundp 'url-http-end-of-headers) url-http-end-of-headers)
            (if (not (and (eql url-http-response-status 200)
                          (emacsos-assist-web--sse-content-type-p
                           url-http-content-type)))
                ;; Keep the sanitized 503 body until its URL completion
                ;; callback classifies durable-observation unavailability.
                (unless (eql url-http-response-status 503)
                  (emacsos-assist-web--interrupt-entry-in-buffer
                   target entry epoch "Assist observation was rejected"))
              (with-current-buffer target
                (when-let ((timer (plist-get entry :stream-header-timer)))
                  (when (timerp timer) (cancel-timer timer))
                  (setf (plist-get entry :stream-header-timer) nil)))
              ;; Header admission hands the slot back before parsing a long
              ;; stream.  Releasing twice is harmless and generation-guarded.
              (with-current-buffer target
                (emacsos-assist-web--cleanup-handshake entry epoch))
              (let* ((decoded-end (emacsos-assist-web--decoded-end))
                     (body-start (min (point-max)
                                      (1+ (marker-position url-http-end-of-headers))))
                     (pending-bytes (emacsos-assist-web--range-bytes
                                     (or decoded-end body-start) (point-max))))
                (cond
                 ((and (boundp 'url-http-content-length)
                       (integerp url-http-content-length)
                       (or (< url-http-content-length 0)
                           (> url-http-content-length emacsos-assist-web-max-response-bytes)))
                  (emacsos-assist-web--interrupt-entry-in-buffer
                   target entry epoch "Assist stream response is too large"))
                 ((and (boundp 'url-http-transfer-encoding)
                       (equal url-http-transfer-encoding "chunked")
                       (boundp 'url-http-chunked-length)
                       (integerp url-http-chunked-length)
                       (> url-http-chunked-length emacsos-assist-web-max-stream-chunk-bytes))
                  (emacsos-assist-web--interrupt-entry-in-buffer
                   target entry epoch "Assist stream transport chunk is too large"))
                 ((> pending-bytes emacsos-assist-web-max-header-bytes)
                  (emacsos-assist-web--interrupt-entry-in-buffer
                   target entry epoch "Assist stream transport framing is too large"))
                 (t
                  (emacsos-assist-web--drain-events target epoch decoded-end entry)
                  (when (and (emacsos-assist-web--entry-current-in-buffer-p
                              target entry epoch)
                             (eq process (plist-get entry :stream-process)))
                    (with-current-buffer target
                      (setf (plist-get entry :stream-admitted) t)
                      (emacsos-assist-web-git--finish-active-join entry)))))))))))
      ((error quit)
       (emacsos-assist-web--interrupt-entry-in-buffer
        target entry epoch (error-message-string problem))))))

(defun emacsos-assist-web--observe-entry (entry)
  "Open ENTRY's SSE with entry-owned process, response, timer, and epoch."
  (let* ((buffer (current-buffer))
         (epoch (plist-get entry :epoch))
         (token (condition-case nil
                    (emacsos-assist-web--read-token)
                  ((error quit) nil)))
         response process)
    (if (not (emacsos-assist-web--safe-token-p token))
        (emacsos-assist-web--entry-observation-interrupted entry epoch
                                                            "token missing or invalid")
      (condition-case problem
          (let* ((url-request-method "GET")
                 (url-request-extra-headers `(("Authorization" . ,(concat "Bearer " token))
                                              ("Accept" . "text/event-stream")))
                 (url (emacsos-assist-web--endpoint
                       (format "threads/%s/runs/%s/events"
                               (emacsos-assist-web--require-id emacsos-assist-web--thread-id)
                               (emacsos-assist-web--require-id (plist-get entry :run-id)))))
                 )
            ;; Transfer acquired response/process ownership without a quit
            ;; gap.  The interruption path can then close both exact handles.
            (let ((inhibit-quit t)
                  (url-mime-encoding-string "identity")
                  (url-debug nil)
                  (url-automatic-caching nil)
                  (url-http-attempt-keepalives nil)
                  (gnutls-trustfiles (emacsos-assist-web--trustfiles)))
              (emacsos-assist-web--close-idle-origin-connections)
              (setq response
                    (url-retrieve
                     url
                     (lambda (_status)
                       (emacsos-assist-web--entry-finish-observation-response
                        buffer entry epoch (current-buffer)))
                     nil t t))
              (setf (plist-get entry :stream-response) response
                    (plist-get entry :stream-generation) epoch)
              (setq process (and (buffer-live-p response)
                                 (get-buffer-process response)))
              (setf (plist-get entry :stream-process) process))
            (unless process (error "observation unavailable"))
            (with-current-buffer response
              (setq-local url-max-redirections 0
                          url-http-no-retry t
                          url-debug nil
                          url-automatic-caching nil))
            ;; Keep url-http's stock decoding/filtering in front of our exact
            ;; entry filter.  The wrapper captures ENTRY/EPOCH, so delayed
            ;; bytes cannot select another queue record.
            (let ((stock-filter (process-filter process)))
              (set-process-filter
               process
               (emacsos-assist-web--guarded-filter
                (emacsos-assist-web--entry-event-filter stock-filter buffer entry epoch)
                (lambda (active problem)
                  (if (and (emacsos-assist-web--entry-current-in-buffer-p buffer entry epoch)
                           (eq active (plist-get entry :stream-process)))
                      (emacsos-assist-web--interrupt-entry-in-buffer buffer entry epoch problem)
                    (when (process-live-p active) (delete-process active))))
                t)))
            (set-process-sentinel
             process
              (emacsos-assist-web--entry-stream-sentinel
              (process-sentinel process) buffer entry epoch))
            (setf (plist-get entry :stream-header-timer)
                  (run-at-time emacsos-assist-web-request-timeout nil
                               (lambda ()
                                 (when (and (emacsos-assist-web--entry-current-in-buffer-p buffer entry epoch)
                                            (plist-get entry :stream-header-timer)
                                            (buffer-live-p (plist-get entry :stream-response))
                                            (with-current-buffer (plist-get entry :stream-response)
                                              (or (not (and (boundp 'url-http-end-of-headers)
                                                            url-http-end-of-headers))
                                                  ;; A 503 is not an admitted
                                                  ;; long-lived SSE.  Bound its
                                                  ;; JSON error-body completion.
                                                  (eql url-http-response-status 503))))
                                   (emacsos-assist-web--interrupt-entry-in-buffer
                                    buffer entry epoch "Assist observation timed out"))))))
        ((error quit)
         ;; A response may exist even if process lookup signaled before its
         ;; handle was stored.  Reclaim the process attached to that exact
         ;; response, not an unrelated observer's process.
         (when (and (buffer-live-p response)
                    (not (plist-get entry :stream-process)))
           (setf (plist-get entry :stream-process)
                 (seq-find (lambda (candidate)
                             (eq (process-buffer candidate) response))
                           (process-list))))
         (emacsos-assist-web--entry-observation-interrupted
          entry epoch (error-message-string problem)))))))

(defun emacsos-assist-web--event-filter (url-filter target generation)
  "Bind legacy SSE parsing to its captured queue entry, never selected buffer state."
  (let ((entry (and (buffer-live-p target)
                    (with-current-buffer target emacsos-assist-web--stream-entry))))
    (if (not entry)
        ;; A queue owner without an exact observed entry has already retired or
        ;; superseded this callback.  It must not fall back into singleton
        ;; parser state merely because bytes arrived late.
        (if (and (buffer-live-p target)
                 (with-current-buffer target
                   (emacsos-assist-web--legacy-compatibility-p)))
            (emacsos-assist-web--legacy-event-filter url-filter target generation)
          (lambda (&rest _) nil))
      (emacsos-assist-web--entry-event-filter url-filter target entry
                                               (plist-get entry :epoch)))))

(defun emacsos-assist-web--stream-finish
    (buffer &optional run-still-active verified-outcome verified-start-epoch)
  "Fence and save the queue observer's provisional terminal SSE before a Run GET.
If the owner transition cannot be saved and cleaned, pause local recovery.
For a legacy observer, forward VERIFIED-OUTCOME and its authenticated
VERIFIED-START-EPOCH from an exact Run GET."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (let ((entry emacsos-assist-web--stream-entry))
        (if (not entry)
            (when (emacsos-assist-web--legacy-compatibility-p)
              (emacsos-assist-web--legacy-stream-finish
               buffer run-still-active verified-outcome
               verified-start-epoch))
          (let (complete)
            (let ((inhibit-quit t))
              ;; The exact owner is fenced before end-state mutations.  The
              ;; unwind path closes the slot and pauses if save or cleanup
              ;; does not complete, including a deferred C-g.
              (unwind-protect
                  (progn
                    (when (and emacsos-assist-web--thread-id
                               (plist-get entry :run-id))
                      (emacsos-assist-web-git--stop-reobserve
                       entry 'terminal-sse))
                    (unless run-still-active
                      (setf (plist-get entry :state) 'terminal-unreconciled
                            (plist-get entry :verified-outcome) nil
                            (plist-get entry :observer-end-kind) 'terminal-sse
                            (plist-get entry :observer-end-generation)
                            (plist-get entry :stream-generation)
                            (plist-get entry :observer-end-checked) nil))
                    (when (emacsos-assist-web--save-draft)
                      (emacsos-assist-web--stream-cleanup t t)
                      (setq complete t)))
                (unless complete
                  (let ((inhibit-quit t) (quit-flag nil))
                    (setq emacsos-assist-web--reconcile-recovery-paused t
                          emacsos-assist-web--manual-recovery-active nil)
                    (condition-case nil
                        (emacsos-assist-web--stream-cleanup t t)
                      ((error quit) nil))
                    (condition-case nil
                        (emacsos-assist-web-git--invalidate
                         "local recovery could not be saved; restart to recover")
                      ((error quit) nil)))))
              (when complete
                ;; A's exact Run GET owns admission of B.  No presentation
                ;; hook may strand this saved terminal receipt before GET.
                (condition-case nil
                    (progn
                      (emacsos-assist-web--reobserve-entry entry)
                      (emacsos-assist-web--reconcile-when-settled))
                  ((error quit)
                   (setf (plist-get entry :requires-reobserve) t)
                   (unless (condition-case nil (emacsos-assist-web--save-draft)
                             ((error quit) nil))
                     (setq emacsos-assist-web--reconcile-recovery-paused t))))))
            (condition-case nil
                (if complete
                    (emacsos-assist-web--sync-active-surface)
                  (emacsos-assist-web--entry-status
                   entry "terminal observed; local recovery could not be saved"))
              ((error quit) nil))))))))

(defun emacsos-assist-web--start-next-observation (&optional continue-recovery)
  "Observe the next Run or stream.
Only CONTINUE-RECOVERY may chain another recovered terminal Run's exact GET;
restoring the cache itself waits for an explicit Refresh.  A terminal SSE
immediately starts its own exact Run GET; a disconnected or stopped accepted
observer instead waits for explicit Refresh."
  (unless (or emacsos-assist-web--stream-entry
              emacsos-assist-web--reconcile-recovery-paused
              (and emacsos-assist-web--manual-recovery-required
                   (not continue-recovery)))
    (when-let ((entry (seq-find (lambda (candidate)
                                  (or (eq (emacsos-assist-web--entry-state candidate)
                                          'accepted-unobserved)
                                      (and continue-recovery
                                           (eq (emacsos-assist-web--entry-state candidate)
                                               'terminal-unreconciled)
                                           (plist-get candidate :requires-reobserve))))
                                emacsos-assist-web--queue)))
      ;; An ended observer's accepted receipt owns the FIFO slot, but only
      ;; the next explicit Refresh may recheck it.  Do not skip it to B.
      (unless (and (eq (emacsos-assist-web--entry-state entry)
                       'accepted-unobserved)
                   (or (memq (plist-get entry :observer-end-kind)
                             '(disconnect operator-repair))
                       (plist-get entry :observer-end-checked)
                       (plist-get entry :approval-stopped)))
        (if (plist-get entry :requires-reobserve)
            (emacsos-assist-web--reobserve-entry entry)
          (emacsos-assist-web--start-observation entry))))))

(defun emacsos-assist-web--reconcile-when-settled ()
  "Start one entry-owned canonical reconciliation after all Runs terminate."
  (when (and emacsos-assist-web--queue
             (not emacsos-assist-web--reconcile-recovery-paused)
             (or (not emacsos-assist-web--manual-recovery-required)
                 emacsos-assist-web--manual-recovery-active)
             (not emacsos-assist-web--reconcile-generation)
             (seq-every-p (lambda (entry)
                            (memq (emacsos-assist-web--entry-state entry)
                                  '(terminal-unreconciled rejected)))
                          emacsos-assist-web--queue))
    (if-let ((unverified
              (seq-find (lambda (entry)
                          (and (eq (emacsos-assist-web--entry-state entry)
                                   'terminal-unreconciled)
                               (not (plist-get entry :verified-outcome))))
                        emacsos-assist-web--queue)))
        (emacsos-assist-web--reobserve-entry unverified)
      (when (seq-every-p (lambda (entry)
                           (not (plist-get entry :requires-reobserve)))
                         emacsos-assist-web--queue)
        (let ((terminals (seq-filter (lambda (entry)
                                       (eq (emacsos-assist-web--entry-state entry)
                                           'terminal-unreconciled))
                                     emacsos-assist-web--queue)))
          (dolist (entry terminals)
            (setf (plist-get entry :state) 'reconciling))
          (if (emacsos-assist-web--save-draft)
              (emacsos-assist-web--reconcile-queue)
            ;; A failed transition never leaves an in-memory reconciling claim
            ;; that was not durably recorded.  The next explicit retry starts from
            ;; the exact terminal records and preserves their FIFO order.
            (dolist (entry terminals)
              (setf (plist-get entry :state) 'terminal-unreconciled
                    (plist-get entry :requires-reobserve) t
                    (plist-get entry :verified-outcome) nil)
              (emacsos-assist-web--entry-status
               entry "terminal; local recovery could not be saved; Refresh retries"))
            (when emacsos-assist-web--manual-recovery-active
              (setq emacsos-assist-web--manual-recovery-active nil)
              (emacsos-assist-web--set-status
               "Run recovery pending; Refresh (local Run state could not be saved)"))))))))

(defun emacsos-assist-web--restore-reconciliation (entries owner reason)
  "Restore resident ENTRIES still owned by OWNER after failure for REASON.
Every restored Run needs a new exact status read before another retirement."
  (let ((restored (seq-filter
                   (lambda (entry)
                     (and entry
                          (eq entry
                              (emacsos-assist-web--queue-entry
                               (plist-get entry :key)))
                          (eq (emacsos-assist-web--entry-state entry)
                              'reconciling)
                          (eql (plist-get entry :reconcile-owner) owner)))
                   entries)))
    (dolist (entry restored)
      (setf (plist-get entry :state) 'terminal-unreconciled
            (plist-get entry :requires-reobserve) t
            (plist-get entry :verified-outcome) nil
            (plist-get entry :reconcile-owner) nil)
      (emacsos-assist-web--entry-status entry reason))
    (when restored
      (if (condition-case nil (emacsos-assist-web--save-draft)
            (error nil))
          (emacsos-assist-web--manual-recovery-activate)
        (setq emacsos-assist-web--reconcile-recovery-paused t)
        (emacsos-assist-web-git--invalidate
         "local recovery could not be saved; restart to recover")
        (dolist (entry restored)
          (emacsos-assist-web--entry-status
           entry "local recovery could not be saved; restart to recover"))))
    restored))

(defun emacsos-assist-web--manual-recovery-activate ()
  "Fence Git until restored terminal Runs pass an explicit exact recovery."
  (unless emacsos-assist-web--manual-recovery-required
    (setq emacsos-assist-web--manual-recovery-required t)
    (emacsos-assist-web-git--invalidate "Run recovery pending; Refresh"))
  (setq emacsos-assist-web--manual-recovery-active nil
        emacsos-assist-web--manual-recovery-reason nil)
  (unless emacsos-assist-web--reconcile-recovery-paused
    (emacsos-assist-web--set-status "Run recovery pending; Refresh")))

(defun emacsos-assist-web--manual-recovery-next ()
  "Return the first recovery queue entry needing an exact Run read."
  (seq-find (lambda (entry)
              (and (memq (emacsos-assist-web--entry-state entry)
                         '(accepted-unobserved terminal-unreconciled))
                   (plist-get entry :requires-reobserve)))
            emacsos-assist-web--queue))

(defun emacsos-assist-web--manual-recovery-stop (entry reason &optional kind)
  "Stop this explicit recovery pass at ENTRY with REASON and header KIND."
  (let ((active emacsos-assist-web--manual-recovery-active))
    ;; A rendering hook must not leave Refresh believing the pass is active.
    (let ((inhibit-quit t))
      (when active
        (setq emacsos-assist-web--manual-recovery-active nil
              emacsos-assist-web--manual-recovery-reason kind)))
    (condition-case nil
        (progn
          (emacsos-assist-web--entry-status entry reason)
          (when active
            (emacsos-assist-web--set-status
             (pcase kind
               ('approval "Approval pending; Refresh [?]")
               ('changed "Run changed; Refresh [?]")
               (_ (format "Run recovery pending; Refresh (%s)" reason))))
            (emacsos-assist-web-git--update-headers)))
      ((error quit) nil))))

(defun emacsos-assist-web--manual-recovery-rearm (entry reason &optional kind)
  "Persist ENTRY for a later exact Run read with REASON and KIND, or pause."
  (setf (plist-get entry :requires-reobserve) t
        (plist-get entry :verified-outcome) nil)
  (if (condition-case nil (emacsos-assist-web--save-draft)
        ((error quit) nil))
      (emacsos-assist-web--manual-recovery-stop entry reason kind)
    (setq emacsos-assist-web--reconcile-recovery-paused t
          emacsos-assist-web--manual-recovery-active nil)
    (emacsos-assist-web-git--invalidate
     "local recovery could not be saved; restart to recover")
    (emacsos-assist-web--set-status
     "local recovery could not be saved; restart to recover")))

(defun emacsos-assist-web--reconcile-queue ()
  "Fetch canonical history and retire only the exact reconciling entries.

The snapshot cache is written before queue retirement; a failed cache or queue
write leaves provisional records for a new exact Run read.  A failed durable
restoration pauses this buffer until restart."
  (when (and emacsos-assist-web--thread-id
             (not emacsos-assist-web--reconcile-recovery-paused)
             (not emacsos-assist-web--reconcile-generation))
    (let* ((buffer (current-buffer))
           (thread-id emacsos-assist-web--thread-id)
           (generation (cl-incf emacsos-assist-web--refresh-generation))
           (owner generation)
           (git-auth-start-epoch emacsos-assist-web-git--auth-epoch)
           (entries (seq-filter (lambda (entry)
                                  (eq (emacsos-assist-web--entry-state entry)
                                      'reconciling))
                                emacsos-assist-web--queue))
           (git-reconcile-token
            (emacsos-assist-web-git--canonical-start
             t owner
             (mapcar (lambda (entry)
                       (cons (plist-get entry :run-id)
                             (plist-get entry :verified-outcome)))
                     entries)))
           (keys (mapcar (lambda (entry) (plist-get entry :key)) entries))
           committed)
      (setq emacsos-assist-web--reconcile-generation generation)
      (dolist (entry entries)
        (setf (plist-get entry :reconcile-owner) owner))
      (emacsos-assist-web--request
       "GET" (format "threads/%s" (emacsos-assist-web--require-id thread-id)) nil
       (lambda (value error)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (unless (eql generation emacsos-assist-web--reconcile-generation)
                 ;; A later owner cannot discharge this R2's diagnostic wait.
                 (emacsos-assist-web-git--r2-finished owner nil))
               (when (eql generation emacsos-assist-web--reconcile-generation)
               (unwind-protect
                   (let ((current (mapcar #'emacsos-assist-web--queue-entry keys)))
                 (if (and (= generation emacsos-assist-web--refresh-generation)
                          (seq-every-p #'identity current)
                          (seq-every-p
                           (lambda (entry)
                             (and (eq (emacsos-assist-web--entry-state entry)
                                      'reconciling)
                                  (eql (plist-get entry :reconcile-owner) owner)))
                           current))
                   (if error
                       (progn
                         (emacsos-assist-web--restore-reconciliation
                          current owner "unverified; Refresh retries")
                         (emacsos-assist-web-git--canonical-failed
                          git-reconcile-token
                          (when emacsos-assist-web--reconcile-recovery-paused
                            "local recovery could not be saved; restart to recover")))
                     (progn
                       (condition-case problem
                           (progn
                             (emacsos-assist-web--require-snapshot value thread-id)
                             (emacsos-assist-web--snapshot-active-p value)
                             (unless (eql git-auth-start-epoch
                                          emacsos-assist-web-git--auth-epoch)
                               (error "thread access changed during exact Run reconciliation"))
                             (when (seq-some
                                    (lambda (entry)
                                      (emacsos-assist-web-git--run-read-superseded-p
                                       thread-id (plist-get entry :run-id)
                                       (plist-get entry :run-read-start-epoch)))
                                    current)
                               (error "exact Run denial requires a newer status read"))
                             (unless (emacsos-assist-web--try-write-cache
                                      (emacsos-assist-web--snapshot-cache-name thread-id) value)
                               (error "canonical snapshot could not be saved"))
                             (let ((retired (seq-remove
                                             (lambda (entry) (memq entry current))
                                             emacsos-assist-web--queue)))
                               ;; The prospective queue is saved before the
                               ;; live owner changes.  Presentation is later.
                               (let ((emacsos-assist-web--queue retired)
                                     (emacsos-assist-web--collision-p
                                      (and emacsos-assist-web--collision-p
                                           (>= (length retired) 2))))
                                 (unless (emacsos-assist-web--save-draft)
                                   (error "reconciled queue could not be saved")))
                               (setq emacsos-assist-web--queue retired
                                     emacsos-assist-web--snapshot value
                                     committed t)
                               (when (< (length retired) 2)
                                 (setq emacsos-assist-web--collision-p nil))))
                         (error
                          (emacsos-assist-web--restore-reconciliation
                           current owner "unverified; Refresh retries")
                          (emacsos-assist-web-git--canonical-failed
                           git-reconcile-token
                           (when emacsos-assist-web--reconcile-recovery-paused
                             "local recovery could not be saved; restart to recover"))))
                       (when committed
                         (when emacsos-assist-web--manual-recovery-required
                           (setq emacsos-assist-web--manual-recovery-required nil
                                 emacsos-assist-web--manual-recovery-active nil
                                 emacsos-assist-web--manual-recovery-reason nil))
                         (dolist (entry current)
                           (when (integerp
                                  (plist-get entry :run-read-start-epoch))
                             (emacsos-assist-web-git--run-status-confirmed
                              thread-id (plist-get entry :run-id)
                              (plist-get entry :run-read-start-epoch)))
                           (emacsos-assist-web-git--retire-stopped-reobserve
                            thread-id (plist-get entry :run-id)))
                         (emacsos-assist-web--git-note-safely
                          value nil git-auth-start-epoch git-reconcile-token)
                         (condition-case nil
                             (progn
                               (emacsos-assist-web--render value)
                               (emacsos-assist-web--sync-active-surface)
                               (setq emacsos-assist-web--display-recovery nil))
                           ((error quit)
                            (setq emacsos-assist-web--display-recovery t
                                  emacsos-assist-web--stream-status
                                  "Saved; Refresh to display")
                            (condition-case nil
                                (emacsos-assist-web-git--show-display-recovery)
                              ((error quit) nil))
                            (message
                             "Canonical history saved; display failed; Refresh to retry"))))))))
                   (unwind-protect
                       (unless committed
                         (when (emacsos-assist-web--restore-reconciliation
                                (mapcar #'emacsos-assist-web--queue-entry keys) owner
                                "reconciliation superseded; Refresh retries")
                           (emacsos-assist-web-git--canonical-failed
                            git-reconcile-token
                            (when emacsos-assist-web--reconcile-recovery-paused
                              "local recovery could not be saved; restart to recover"))))
                     (when (eql generation emacsos-assist-web--reconcile-generation)
                       (setq emacsos-assist-web--reconcile-generation nil)
                       (emacsos-assist-web-git--r2-finished owner committed))))))))))))

(defun emacsos-assist-web--entry-run-read-committed (entry start-epoch)
  "Remember ENTRY's exact Run read without replacing its identity.
The start epoch proves freshness after any earlier definitive thread denial."
  (unless (plist-member entry :run-read-start-epoch)
    (setcdr (last entry) (list :run-read-start-epoch nil)))
  (setf (plist-get entry :run-read-start-epoch) start-epoch))

(defun emacsos-assist-web--reobserve-entry (entry)
  "Query ENTRY's exact Run before reopening its stream or retiring its queue."
  (when (and entry emacsos-assist-web--thread-id (plist-get entry :run-id)
             (not emacsos-assist-web--reconcile-recovery-paused)
             (not (plist-get entry :reobserve-in-flight)))
    (let* ((buffer (current-buffer)) (key (plist-get entry :key))
          (run-id (plist-get entry :run-id))
          (end-checked (plist-get entry :observer-end-checked))
          (tid emacsos-assist-web--thread-id)
          (run-auth-start
           (progn
             (emacsos-assist-web-git--claim-orphaned-run-gate tid run-id)
             emacsos-assist-web-git--auth-epoch))
          (generation (1+ (plist-get entry :reobserve-generation)))
          preflight-failed)
      ;; The Git safety latch can signal during header presentation.  Do not
      ;; claim a live exact GET until that fallible preflight has returned.
      (when (and (> generation 1) emacsos-assist-web-git-thread-mode)
        (setq preflight-failed
              (not (condition-case nil
                       (progn
                         (emacsos-assist-web-git--run-recheck-start tid run-id)
                         t)
                     ((error quit) nil)))))
      (when preflight-failed
        (setf (plist-get entry :requires-reobserve) t)
        (if emacsos-assist-web--manual-recovery-active
            (emacsos-assist-web--manual-recovery-rearm
             entry "Run recheck unavailable; Refresh")
          (unless (condition-case nil (emacsos-assist-web--save-draft)
                    ((error quit) nil))
            (setq emacsos-assist-web--reconcile-recovery-paused t)
            (emacsos-assist-web-git--invalidate
             "local Run recheck could not be saved; restart to recover"))
          (condition-case nil
              (emacsos-assist-web--entry-status
               entry (if emacsos-assist-web--reconcile-recovery-paused
                         "local Run recheck could not be saved; restart to recover"
                       "Run recheck unavailable; Refresh"))
            ((error quit) nil))))
      (unless preflight-failed
        (setf (plist-get entry :reobserve-generation) generation
              (plist-get entry :reobserve-in-flight) t)
      (emacsos-assist-web--request
       "GET" (format "threads/%s/runs/%s"
                      (emacsos-assist-web--require-id emacsos-assist-web--thread-id)
                      (emacsos-assist-web--require-id run-id)) nil
       (lambda (value error)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (when-let ((current (emacsos-assist-web--queue-entry key)))
               (when (and (eq current entry)
                          (= generation (plist-get current :reobserve-generation))
                          (equal run-id (plist-get current :run-id)))
                 (setf (plist-get current :reobserve-in-flight) nil)
                 (if error
                   (emacsos-assist-web--manual-recovery-rearm
                    current "exact Run status unavailable")
                 (let ((status
                        (condition-case nil
                            (emacsos-assist-web--exact-run-status
                             value tid run-id)
                          (error nil))))
                   (cond
                    ((emacsos-assist-web-git--run-read-superseded-p
                      tid run-id run-auth-start)
                     (emacsos-assist-web--manual-recovery-stop
                      current "newer Run denial; Refresh retries exact status"))
                    ((and (or (equal status "awaiting_approval")
                              (and (eq (plist-get current :observer-end-kind)
                                       'terminal-sse)
                                   (not (plist-get current :observer-end-checked))))
                          (member status
                                  '("pending" "running" "transitioning"
                                    "awaiting_approval")))
                     ;; The first exact read after terminal SSE stops on a
                     ;; contradiction.  Approval always stops, including on
                     ;; repeated explicit Refresh; neither starts an SSE loop.
                     (setf (plist-get current :state) 'accepted-unobserved
                           (plist-get current :requires-reobserve) t
                           (plist-get current :observer-end-checked)
                           (and (eq (plist-get current :observer-end-kind)
                                    'terminal-sse) t)
                           (plist-get current :approval-stopped)
                           (equal status "awaiting_approval"))
                     (emacsos-assist-web-git--stop-reobserve
                      current (if (equal status "awaiting_approval")
                                  'approval 'terminal-sse))
                     (if emacsos-assist-web--manual-recovery-active
                         (emacsos-assist-web--manual-recovery-rearm
                          current
                          (if (equal status "awaiting_approval")
                              "approve the Run, then Refresh"
                            "Run changed after its stream ended; Refresh retries")
                          (if (equal status "awaiting_approval")
                              'approval 'changed))
                       (if (emacsos-assist-web--save-draft)
                           (progn
                             (emacsos-assist-web--entry-status
                              current
                              (if (equal status "awaiting_approval")
                                  "Approval pending; Refresh [?]"
                                "Run changed; Refresh [?]")))
                         (setf (plist-get current :observer-end-checked)
                               end-checked
                               (plist-get current :approval-stopped)
                               (and (equal status "awaiting_approval") t))
                         (setq emacsos-assist-web--reconcile-recovery-paused t)
                         (emacsos-assist-web-git--invalidate
                          "local Run status could not be saved; restart to recover")
                         (emacsos-assist-web--entry-status
                          current "local Run status could not be saved; restart to recover"))))
                    ((member status '("pending" "running" "transitioning" "awaiting_approval"))
                     (let ((previous (emacsos-assist-web--entry-state current))
                           (approval-stopped (plist-get current :approval-stopped)))
                       (setf (plist-get current :state) 'accepted-unobserved
                             (plist-get current :requires-reobserve) nil
                             (plist-get current :verified-outcome) nil)
                       (if (emacsos-assist-web--save-draft)
                           (progn
                             (emacsos-assist-web--entry-run-read-committed
                              current run-auth-start)
                             (emacsos-assist-web-git--stop-reobserve
                              current 'active-check t)
                             (emacsos-assist-web-git--confirm-active-run
                              tid run-id run-auth-start current)
                             (condition-case nil
                                 (emacsos-assist-web--start-observation current)
                               (error nil)
                               (quit nil))
                             (emacsos-assist-web-git--finish-active-join
                              current)
                             (when (and emacsos-assist-web--manual-recovery-active
                                        (not (and (process-live-p
                                                   (plist-get current :stream-process))
                                                  (buffer-live-p
                                                   (plist-get current :stream-response)))))
                               (if (and (eq current emacsos-assist-web--stream-entry)
                                        (eq (emacsos-assist-web--entry-state current)
                                            'observing))
                                   (emacsos-assist-web--entry-observation-interrupted
                                    current (plist-get current :epoch)
                                    "observation unavailable")
                                 (emacsos-assist-web--manual-recovery-rearm
                                  current "observation unavailable"))))
                         (setf (plist-get current :state) previous
                               (plist-get current :requires-reobserve) t
                               (plist-get current :approval-stopped)
                               approval-stopped)
                         (setq emacsos-assist-web--reconcile-recovery-paused t
                               emacsos-assist-web--manual-recovery-active nil)
                         (emacsos-assist-web-git--invalidate
                          "local Run status could not be saved; restart to recover")
                         (emacsos-assist-web--entry-status
                          current "local Run status could not be saved; restart to recover"))))
                    ((member status '("success" "error" "timeout" "interrupted"
                                             "cancelled"))
                     (let ((previous (emacsos-assist-web--entry-state current))
                           (approval-stopped (plist-get current :approval-stopped)))
                       (setf (plist-get current :state) 'terminal-unreconciled
                             (plist-get current :requires-reobserve) nil
                             (plist-get current :approval-stopped) nil
                             (plist-get current :verified-outcome) nil)
                     (if (emacsos-assist-web--save-draft)
                         (progn
                           (setf (plist-get current :verified-outcome) status)
                           (emacsos-assist-web--entry-run-read-committed
                            current run-auth-start)
                           (emacsos-assist-web-git--stop-reobserve
                            current 'terminal-verified t)
                           (emacsos-assist-web--start-next-observation t)
                           (emacsos-assist-web--pump-posts)
                           (emacsos-assist-web--reconcile-when-settled))
                         ;; A failed save cannot advance this pass or retire a
                         ;; Run.  The next explicit Refresh repeats its GET.
                         (setf (plist-get current :state) previous
                               (plist-get current :requires-reobserve) t
                               (plist-get current :approval-stopped)
                               approval-stopped
                               (plist-get current :verified-outcome) nil)
                         (setq emacsos-assist-web--reconcile-recovery-paused t
                               emacsos-assist-web--manual-recovery-active nil)
                         (emacsos-assist-web-git--invalidate
                          "local Run status could not be saved; restart to recover")
                         (emacsos-assist-web--entry-status
                          current "local Run status could not be saved; restart to recover"))))
                    (t (emacsos-assist-web--manual-recovery-stop
                        current "exact Run status invalid")))))))))))))))

(defun emacsos-assist-web--legacy-terminal-probe (buffer run-id)
  "Check BUFFER's exact legacy RUN-ID before canonical reconciliation."
  (with-current-buffer buffer
    (let* ((tid (emacsos-assist-web--require-id emacsos-assist-web--thread-id))
           (run-id (emacsos-assist-web--require-id run-id))
           (run-auth-start
            (progn
              (emacsos-assist-web-git--claim-orphaned-run-gate tid run-id)
              emacsos-assist-web-git--auth-epoch))
           (generation (cl-incf emacsos-assist-web--legacy-terminal-generation))
           (handled nil))
      (when (and (> generation 1) emacsos-assist-web-git-thread-mode)
        (emacsos-assist-web-git--run-recheck-start tid run-id))
      (emacsos-assist-web--request
       "GET" (format "threads/%s/runs/%s" tid run-id) nil
       (lambda (value error)
         (when (and (not handled) (buffer-live-p buffer))
           (with-current-buffer buffer
             (when (and (= generation emacsos-assist-web--legacy-terminal-generation)
                        (equal run-id emacsos-assist-web--run-id)
                        emacsos-assist-web--pending-accepted-p)
               (setq handled t)
               (if error
                   (emacsos-assist-web--set-unverified-status
                    "exact Run status unavailable; Refresh retries")
                 (condition-case nil
                     (let ((status (emacsos-assist-web--exact-run-status
                                    value tid run-id)))
                       (when (emacsos-assist-web-git--run-read-superseded-p
                              tid run-id run-auth-start)
                         (error "newer exact Run denial"))
                       (if (and (member status
                                        '("pending" "running" "transitioning"
                                          "awaiting_approval"))
                                (not (condition-case nil
                                         (emacsos-assist-web--legacy-save-draft)
                                       (error nil))))
                           (emacsos-assist-web--set-unverified-status
                            "local Run status could not be saved; Refresh retries")
                         (emacsos-assist-web--legacy-refresh-thread
                          buffer run-id status run-auth-start)))
                   (error
                    (emacsos-assist-web--set-unverified-status
                     "exact Run response invalid; Refresh retries"))))))))))))

(defun emacsos-assist-web-refresh-thread
    (&optional buffer completed-run-id verified-outcome verified-start-epoch)
  "Refresh exact queue state first, or verify a legacy Run before chat history.
COMPLETED-RUN-ID, VERIFIED-OUTCOME, and VERIFIED-START-EPOCH come only from
an exact Run GET; the epoch fences later Run access denial."
  (interactive)
  (let ((buffer (or buffer (current-buffer))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (let* ((head (emacsos-assist-web--queue-head))
               (recovery (emacsos-assist-web--manual-recovery-next)))
          (cond
           (emacsos-assist-web--passive-recovery-invalid-p
            (message "Canonical recovery needs repair; cached state is preserved"))
           (emacsos-assist-web--reconcile-recovery-paused
            (message "local recovery could not be saved; restart to recover"))
           (emacsos-assist-web--reconcile-generation
            (message "Canonical reconciliation in progress; result will appear here"))
           (emacsos-assist-web--manual-recovery-required
            (unless emacsos-assist-web--manual-recovery-active
              (setq emacsos-assist-web--manual-recovery-active t
                    emacsos-assist-web--manual-recovery-reason nil)
              (emacsos-assist-web--set-status "Run recovery checking exact status")
              (if recovery
                  (emacsos-assist-web--reobserve-entry recovery)
                (emacsos-assist-web--reconcile-when-settled))))
           (emacsos-assist-web--stream-entry
            ;; A live observer can follow a terminal queue head.  Its markers
            ;; still belong to the entry-owned stream, never legacy rendering.
            (if emacsos-assist-web--manual-recovery-active
                (message "Run active; observing; result will appear here")
              (unless (emacsos-assist-web-git--retry-busy-check)
                (message "Run active; observing; result will appear here"))))
           ((and head (memq (emacsos-assist-web--entry-state head)
                            '(acceptance-unknown retryable-rejected)))
            (emacsos-assist-web--start-post head))
           ((and head (eq (emacsos-assist-web--entry-state head)
                           'accepted-unobserved))
            (emacsos-assist-web--reobserve-entry head))
           ((and head (eq (emacsos-assist-web--entry-state head)
                           'terminal-unreconciled))
            ;; A verified terminal predecessor may leave an accepted B whose
            ;; observation handshake was refused.  Refresh retries B first;
            ;; reconciliation cannot start until B itself has terminated.
            (if-let ((next
                      (catch 'refreshable
                        (dolist (entry emacsos-assist-web--queue)
                          (pcase (emacsos-assist-web--entry-state entry)
                            ('rejected nil)
                            ('terminal-unreconciled
                             (unless (and (plist-get entry :verified-outcome)
                                          (not (plist-get entry :requires-reobserve)))
                               (throw 'refreshable nil)))
                            ('accepted-unobserved
                             (throw 'refreshable entry))
                            (_ (throw 'refreshable nil)))))))
                (if (or (plist-get next :requires-reobserve)
                        (plist-get next :observer-end-kind)
                        (plist-get next :approval-stopped))
                    (emacsos-assist-web--reobserve-entry next)
                  (emacsos-assist-web--start-observation next))
              (emacsos-assist-web--reconcile-when-settled)))
           ((and head (eq (emacsos-assist-web--entry-state head)
                           'identity-conflict))
            (message "Submission identity conflict; repair required"))
           ((and (emacsos-assist-web--legacy-compatibility-p)
                 emacsos-assist-web--pending-accepted-p
                 emacsos-assist-web--run-id)
            (if verified-outcome
                         (emacsos-assist-web--legacy-refresh-thread
                          buffer completed-run-id verified-outcome
                          verified-start-epoch)
              (emacsos-assist-web--legacy-terminal-probe
               buffer emacsos-assist-web--run-id)))
           ((and (emacsos-assist-web--legacy-compatibility-p)
                 (not emacsos-assist-web--pending-key)
                 (not emacsos-assist-web--run-id)
                 emacsos-assist-web--follow-ups)
            (emacsos-assist-web--start-follow-up))
           (t (emacsos-assist-web--legacy-refresh-thread buffer completed-run-id))))))))

(defun emacsos-assist-web--abort-entry (key)
  "Detach the exact accepted entry named by KEY without reposting it."
  (when-let ((entry (emacsos-assist-web--queue-entry key)))
    (when (and emacsos-assist-web--thread-id (plist-get entry :run-id))
      ;; A queue restored by older code predates cancellation generation.  Add
      ;; its zero value in place so TARGET remains the resident entry captured
      ;; by the DELETE callback.
      (unless (plist-member entry :cancellation-generation)
        (setcdr (last entry) (list :cancellation-generation 0)))
      (let* ((buffer (current-buffer)) (run-id (plist-get entry :run-id))
             (target entry)
             (cancellation-generation
              (1+ (or (plist-get entry :cancellation-generation) 0))))
        (setf (plist-get entry :cancellation-generation) cancellation-generation)
        ;; A delayed exact-Run GET predating this DELETE must not reopen an
        ;; observer after the cancellation receipt makes this entry terminal.
        (cl-incf (plist-get entry :reobserve-generation))
        (setf (plist-get entry :reobserve-in-flight) nil)
        (when (eq entry emacsos-assist-web--stream-entry)
          (emacsos-assist-web--stream-cleanup t)
          (setf (plist-get entry :state) 'accepted-unobserved)
          (emacsos-assist-web--entry-clear-actions entry)
          (emacsos-assist-web--sync-active-surface))
        (when (emacsos-assist-web--save-draft)
          (emacsos-assist-web--request
         "DELETE" (format "threads/%s/runs/%s"
                           (emacsos-assist-web--require-id emacsos-assist-web--thread-id)
                           (emacsos-assist-web--require-id run-id)) nil
         (lambda (value error)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (let ((current (emacsos-assist-web--queue-entry key)))
                 (when (and (eq current target)
                            (equal run-id (plist-get current :run-id))
                            (= cancellation-generation
                               (plist-get current :cancellation-generation)))
                 (cond
                  (error (emacsos-assist-web--abort-receipt-status
                          current "stopped watching; cancellation unconfirmed"))
                  ((equal (cons (alist-get 'http_status value)
                                (alist-get 'outcome value))
                          '(200 . "cancelled"))
                   ;; Refresh may have started a new exact-Run GET after this
                   ;; cancellation began.  A confirmed terminal receipt wins:
                   ;; make that in-flight callback inert before recording it.
                   (when (eq current emacsos-assist-web--stream-entry)
                     (emacsos-assist-web--stream-cleanup t))
                   (cl-incf (plist-get current :reobserve-generation))
                   (setf (plist-get current :reobserve-in-flight) nil)
                   (setf (plist-get current :state) 'terminal-unreconciled)
                   (setf (plist-get current :verified-outcome) nil)
                   ;; The terminal state has retired this buffer's transport.
                   ;; Recompute the aggregate slot before reconciliation, which
                   ;; may run an arbitrary refresh callback.
                   (emacsos-assist-web--sync-active-surface)
                   (if (emacsos-assist-web--save-draft)
                       (emacsos-assist-web--reconcile-when-settled)
                     (setf (plist-get current :state) 'accepted-unobserved)
                     (emacsos-assist-web--entry-status
                      current "cancelled; local recovery could not be saved")))
                  ((member (alist-get 'outcome value) '("running" "transitioning"))
                   (emacsos-assist-web--abort-receipt-status
                    current (format "stopped watching; Assist is %s"
                                    (alist-get 'outcome value))))
                  (t (emacsos-assist-web--abort-receipt-status
                      current "stopped watching; cancellation unconfirmed")))
                 (emacsos-assist-web--save-draft)))))) nil t))))))

(defun emacsos-assist-web-abort ()
  "Abort a posting entry or detach the exact currently observed Run."
  (interactive)
  (if-let ((entry emacsos-assist-web--stream-entry))
      (emacsos-assist-web--abort-entry (plist-get entry :key))
    (if-let ((entry emacsos-assist-web--post-entry))
        (progn
          ;; POST may have reached Assist even though this client will never
          ;; inspect its callback.  Keep the immutable tuple, invalidate that
          ;; callback, and make the next Send replay the same key.
          (cl-incf (plist-get entry :epoch))
          (setf (plist-get entry :state) 'acceptance-unknown)
          (setq emacsos-assist-web--post-entry nil)
          (emacsos-assist-web--entry-status
           entry "stopped waiting; acceptance unknown; Send retries safely")
          (emacsos-assist-web--save-draft)
          (emacsos-assist-web--sync-active-surface)
          (message "Stopped waiting for acceptance; Send reuses this exact message"))
      (if (emacsos-assist-web--legacy-compatibility-p)
          (emacsos-assist-web--legacy-abort)
        (message "No Assist run is being observed")))))

(defun emacsos-assist-web--dismiss-entry (key)
  "Dismiss only the rejected entry addressed by KEY."
  (interactive "sDismiss submission key: ")
  (when-let ((entry (emacsos-assist-web--queue-entry key)))
    (when (eq (emacsos-assist-web--entry-state entry) 'rejected)
      (let* ((original emacsos-assist-web--queue)
             (original-collision emacsos-assist-web--collision-p)
             (remaining (delq entry (copy-sequence original))))
        ;; Save the exact post-dismiss queue and its derived collision state
        ;; together.  A failed write restores both resident facts verbatim.
        (setq emacsos-assist-web--queue remaining
              emacsos-assist-web--collision-p
              (and original-collision (>= (length remaining) 2)))
        (if (emacsos-assist-web--save-draft)
            (progn
              (emacsos-assist-web--entry-remove-render entry)
              (emacsos-assist-web--pump-posts))
          (setq emacsos-assist-web--queue original
                emacsos-assist-web--collision-p original-collision))))))

(defun emacsos-assist-web--restore-create-entry (key)
  "Make recovered pre-canonical KEY eligible for one explicit create POST."
  (when-let ((entry (emacsos-assist-web--queue-entry key)))
    (when (and (not emacsos-assist-web--thread-id)
               (eq (emacsos-assist-web--entry-state entry) 'recovered-head))
      (setf (plist-get entry :recovered-ready) t)
      ;; The action lies after the assistant region.  Delete it before writing
      ;; the ready status, otherwise the old action range can swallow that text.
      (emacsos-assist-web--entry-clear-actions entry)
      (emacsos-assist-web--entry-status entry "ready to create; tap Send")
      (unless (emacsos-assist-web--save-draft)
        (setf (plist-get entry :recovered-ready) nil)
        (emacsos-assist-web--entry-status entry "recovered draft; tap Restore Draft")
        (emacsos-assist-web--entry-add-action
         entry "Restore Draft" #'emacsos-assist-web--restore-create-entry)))))

(defun emacsos-assist-web--reset-create-entry (key)
  "Reset rejected pre-canonical KEY without silently promoting its follower."
  (when (and (not emacsos-assist-web--thread-id)
             (equal key (plist-get (emacsos-assist-web--queue-head) :key)))
    (let ((head (emacsos-assist-web--queue-head))
          (follower (cadr emacsos-assist-web--queue)))
      (when (eq (emacsos-assist-web--entry-state head) 'rejected)
        (setq emacsos-assist-web--queue (and follower (list follower)))
        (when follower
          (cl-incf (plist-get follower :epoch))
          (setf (plist-get follower :key) nil
                (plist-get follower :run-id) nil
                (plist-get follower :state) 'recovered-head
                (plist-get follower :recovered-ready) nil)
          (emacsos-assist-web--entry-status
           follower "recovered draft; tap Restore Draft")
          (emacsos-assist-web--entry-add-action
           follower "Restore Draft" #'emacsos-assist-web--restore-create-entry))
        (emacsos-assist-web--save-draft)))))

(defconst emacsos-assist-web--entry-progress-rank
  '((recovered-head . 0) (queued . 1) (posting . 2)
    (acceptance-unknown . 3) (retryable-rejected . 3) (rejected . 3)
    (identity-conflict . 4) (accepted-unobserved . 5) (observing . 6)
    (terminal-unreconciled . 7) (reconciling . 8)))

(defun emacsos-assist-web--more-advanced-entry (left right)
  "Return the more durably established of same-key LEFT and RIGHT.

The caller has already established that both records carry the same immutable
key and submitted text.  A disagreement about a returned Run is never a
tie-break: it is evidence that local recovery is unsafe."
  (let ((left-run (plist-get left :run-id))
        (right-run (plist-get right :run-id)))
    (when (and left-run right-run (not (equal left-run right-run)))
      (user-error "canonical adoption found conflicting Run identities"))
    (if (>= (alist-get (emacsos-assist-web--entry-state left)
                       emacsos-assist-web--entry-progress-rank)
            (alist-get (emacsos-assist-web--entry-state right)
                       emacsos-assist-web--entry-progress-rank))
        left
      right)))

(defun emacsos-assist-web--adoption-merge (source destination)
  "Return SOURCE and DESTINATION entries in the one recoverable server order.

Source Runs necessarily precede the independently discovered destination queue;
unadmitted source followers must remain after it.  Dedupe only immutable keys,
never submitted text, and fail closed before either buffer changes."
  (let ((sequence
         (append (seq-filter (lambda (entry) (plist-get entry :run-id)) source)
                 destination
                 (seq-remove (lambda (entry) (plist-get entry :run-id)) source)))
        merged)
    (dolist (entry sequence)
      (let ((key (plist-get entry :key)))
        (if (not key)
            (setq merged (append merged (list entry)))
          (if-let ((previous
                    (seq-find (lambda (candidate)
                                (equal key (plist-get candidate :key)))
                              merged)))
              (progn
                (unless (equal (plist-get previous :text)
                               (plist-get entry :text))
                  (user-error "canonical adoption found conflicting submission text"))
                (setcar (member previous merged)
                        (emacsos-assist-web--more-advanced-entry previous entry)))
            (setq merged (append merged (list entry)))))))
    (when (> (length merged) 4)
      (user-error "canonical adoption needs bounded local recovery"))
    merged))

(defun emacsos-assist-web--message-fits-p (text &optional existing-thread-id)
  "Return non-nil when TEXT fits its actual current message endpoint body."
  (and (<= (length text) 64000)
       (<= (string-bytes
            (json-encode
             (if existing-thread-id
                 `((message . ,text))
               `((message . ,text)
                 (repo_key . ,emacsos-assist-web--draft-repository)
                 (harness . ,(or emacsos-assist-web--draft-harness "deepagents"))))))
           66000)))

(defun emacsos-assist-web--adopt-canonical-buffer
    (source destination &optional accepted-entry accepted-run-id)
  "Move SOURCE's acknowledged queue into DESTINATION as one recoverable owner.

The destination stays the controller: its prompt and any live observer survive.
SOURCE remains durable until the complete destination record is durable, then
its old cache is retired.  ACCEPTED-ENTRY is SOURCE's just-received
POST receipt when adoption is called from its acknowledgement callback;
ACCEPTED-RUN-ID is its already validated Run identity."
  (unless (eq source destination)
    (let ((source-queue (with-current-buffer source emacsos-assist-web--queue))
          (source-input (with-current-buffer source (emacsos-assist-web--input))))
      (let ((failure
             (catch 'emacsos-assist-web--adoption-failed
               (with-current-buffer destination
        (let* ((destination-thread-id emacsos-assist-web--thread-id)
               (destination-queue emacsos-assist-web--queue)
               (destination-input (emacsos-assist-web--input))
               (merged (emacsos-assist-web--adoption-merge source-queue destination-queue))
               (collision (> (length merged) 2))
               (destination-collision emacsos-assist-web--collision-p)
               (destination-recovery-draft emacsos-assist-web--recovery-draft))
          (when (and (not (string-empty-p (string-trim source-input)))
                     (or emacsos-assist-web--recovery-draft
                         (not (emacsos-assist-web--message-fits-p source-input))))
            (user-error "canonical adoption needs bounded local recovery"))
          (when (not (emacsos-assist-web--queue-cache-fits-p
                      merged destination-input
                      (unless (string-empty-p (string-trim source-input))
                        source-input)))
            (user-error "canonical adoption needs bounded local recovery"))
          (with-current-buffer source
            ;; Keep the source's cache identity but persist its canonical
            ;; thread before the destination write.  A rollback can then make
            ;; exact Run progress without another POST.
            (setq emacsos-assist-web--thread-id
                  destination-thread-id)
            (when accepted-entry
              (when accepted-run-id
                (setf (plist-get accepted-entry :run-id) accepted-run-id
                      (plist-get accepted-entry :state) 'accepted-unobserved))
              (unless (emacsos-assist-web--save-draft)
                (user-error "canonical adoption could not preserve its source receipt"))))
          ;; Save the prospective destination through its real buffer-local
          ;; state rather than dynamically binding a special buffer-local.
          ;; The latter would hide SOURCE's real queue while persisting its
          ;; durable retry after a failed destination write.
          (setq emacsos-assist-web--queue merged
                emacsos-assist-web--collision-p collision
                emacsos-assist-web--recovery-draft
                (unless (string-empty-p (string-trim source-input)) source-input))
          (unless (emacsos-assist-web--save-draft)
              ;; The destination write is not durable.  Restore its live
              ;; state while the source cache remains its durable owner.
              (setq emacsos-assist-web--queue destination-queue
                    emacsos-assist-web--collision-p destination-collision
                    emacsos-assist-web--recovery-draft destination-recovery-draft)
              (throw 'emacsos-assist-web--adoption-failed
                      (if (with-current-buffer source
                           (when accepted-entry
                             (when accepted-run-id
                               (setf (plist-get accepted-entry :run-id)
                                     accepted-run-id
                                     (plist-get accepted-entry :state)
                                     'accepted-unobserved))
                             (when-let ((resident
                                         (emacsos-assist-web--queue-entry
                                          (plist-get accepted-entry :key))))
                               (setcar (member resident emacsos-assist-web--queue)
                                       accepted-entry)))
                           (emacsos-assist-web--save-draft))
                         "canonical adoption could not be persisted"
                       "canonical adoption could not restore its source cache")))
          ;; The destination now has a durable complete merge while the source
          ;; cache still survives a crash.  Retire that old source only now.
          (unless (emacsos-assist-web--delete-cache "drafts/new-thread.json")
            (setq emacsos-assist-web--queue destination-queue
                  emacsos-assist-web--collision-p destination-collision
                  emacsos-assist-web--recovery-draft destination-recovery-draft)
            (throw 'emacsos-assist-web--adoption-failed
                    (if (emacsos-assist-web--save-draft)
                        "canonical adoption could not retire its source cache"
                      "canonical adoption has dual durable recovery records")))
          ;; Source callbacks become inert only after the destination cache
          ;; holds the complete merge.  Do not close the destination observer:
          ;; it may already own C1, which is still authoritative for its stream.
          (dolist (entry source-queue)
            (cl-incf (plist-get entry :epoch)))
          (setq emacsos-assist-web--queue merged
                emacsos-assist-web--queue-model-p t
                emacsos-assist-web--collision-p collision
                emacsos-assist-web--recovery-draft
                (unless (string-empty-p (string-trim source-input)) source-input))
          (let* ((source-entries (seq-filter (lambda (entry) (memq entry merged))
                                              source-queue))
                 (returned (seq-filter (lambda (entry) (plist-get entry :run-id))
                                       source-entries))
                 (unreturned (seq-remove (lambda (entry) (plist-get entry :run-id))
                                          source-entries))
                 (anchor (seq-find (lambda (entry)
                                     (and (memq entry destination-queue)
                                          (markerp (plist-get entry :user-start))
                                          (eq (marker-buffer (plist-get entry :user-start))
                                              (current-buffer))))
                                   destination-queue)))
            ;; Source markers belong to the source buffer and are never valid
            ;; insertion coordinates in DESTINATION.  Keep every destination
            ;; region, including a live C1 assistant range, in place.
            (dolist (entry source-entries)
              (setf (plist-get entry :rendered) nil
                    (plist-get entry :user-start) nil
                    (plist-get entry :assistant-start) nil
                    (plist-get entry :assistant-end) nil
                    (plist-get entry :epoch) (1+ (plist-get entry :epoch))))
            (let ((position (if anchor (marker-position (plist-get anchor :user-start))
                              (emacsos-assist-web--prompt-start))))
              (dolist (entry returned)
                (setq position (emacsos-assist-web--entry-insert-before entry position))
                ;; Without a destination provisional region, the old prompt
                ;; follows the inserted source record and remains the tail.
                (unless anchor
                  (set-marker emacsos-assist-web--prompt-marker position)
                  (set-marker emacsos-assist-web--input-marker position))))
            ;; A destination restored from cache may have no presentation yet;
            ;; render only those entries, never redraw a live destination one.
            (dolist (entry destination-queue)
              (unless (plist-get entry :rendered)
                (emacsos-assist-web--entry-render entry)))
            (dolist (entry unreturned)
              (emacsos-assist-web--entry-render entry)))
          (with-current-buffer source
            (setq emacsos-assist-web--queue nil
                  emacsos-assist-web--post-entry nil
                  emacsos-assist-web--stream-entry nil)
            ;; Do not let the killed source re-save the now-retired draft.
            (remove-hook 'kill-buffer-hook #'emacsos-assist-web--buffer-killed t)
            nil))))))
        (if failure
            ;; SOURCE remains the durable accepted owner.  Its exact Run is
            ;; refreshed by its recovery path; do not start a second callback here.
            (progn
              (with-current-buffer source
                (when accepted-entry
                  (when accepted-run-id
                    (setf (plist-get accepted-entry :run-id) accepted-run-id
                          (plist-get accepted-entry :state)
                          'accepted-unobserved))
                  (setq emacsos-assist-web--queue
                        (mapcar (lambda (entry)
                                  (if (equal (plist-get entry :key)
                                             (plist-get accepted-entry :key))
                                      accepted-entry
                                    entry))
                                emacsos-assist-web--queue))
                  (emacsos-assist-web--entry-status
                   accepted-entry "accepted; canonical adoption needs recovery")))
              nil)
          (kill-buffer source)
          (switch-to-buffer destination)
          destination)))))

(defun emacsos-assist-web-send ()
  "Queue a canonical submission without globally serializing web thread buffers."
  (interactive)
  (cond
   ((not (derived-mode-p 'emacsos-assist-web-mode))
    (message "Open an Assist Web thread before sending"))
   ((eq emacsos--assist-active-surface 'chat)
    (message "Another Assist request is still running"))
   (emacsos-assist-web--passive-recovery-invalid-p
    (emacsos-assist-web--set-prompt-refusal
     "canonical recovery needs repair; cached state is preserved"))
   (emacsos-assist-web--reconcile-recovery-paused
    (emacsos-assist-web--set-prompt-refusal
     "local recovery could not be saved; restart to recover"))
   ((and (not emacsos-assist-web--queue-model-p)
         emacsos-assist-web--in-flight)
    (emacsos-assist-web--set-prompt-refusal
     "current Assist Web request is still running; message remains in draft"))
   ((and (emacsos-assist-web--legacy-compatibility-p)
         emacsos-assist-web--pending-key
         emacsos-assist-web--submitted-text
         (not emacsos-assist-web--pending-accepted-p))
    (emacsos-assist-web--legacy-send))
   ((and (emacsos-assist-web--legacy-compatibility-p)
         emacsos-assist-web--follow-ups
         (not emacsos-assist-web--pending-key))
    (emacsos-assist-web--start-follow-up))
   ((eq (emacsos-assist-web--entry-state (emacsos-assist-web--queue-head))
        'identity-conflict)
    (message "Submission identity conflict; repair required"))
   ((eq (emacsos-assist-web--entry-state (emacsos-assist-web--queue-head))
        'recovered-head)
    (if (plist-get (emacsos-assist-web--queue-head) :recovered-ready)
        (emacsos-assist-web--start-post (emacsos-assist-web--queue-head))
      (message "Tap Restore Draft before sending the recovered create")))
   ((let ((head (emacsos-assist-web--queue-head)))
      (and head (memq (emacsos-assist-web--entry-state head)
                      '(acceptance-unknown retryable-rejected))))
    (let ((text (emacsos-assist-web--input)))
      (when (and (not (string-empty-p (string-trim text)))
                 (emacsos-assist-web--admit-text-p text))
        (emacsos-assist-web--enqueue-text text))
      (emacsos-assist-web--start-post (emacsos-assist-web--queue-head))))
   (t
    (let ((text (emacsos-assist-web--input)))
      (if (string-empty-p (string-trim text))
          (message "Nothing to send")
        (when (emacsos-assist-web--admit-text-p text)
          (when (emacsos-assist-web--enqueue-text text)
            (emacsos-assist-web--pump-posts))))))))

(defun emacsos-assist-web--restore-canonical-buffer (thread-id)
  "Return THREAD-ID's live canonical recovery buffer, restoring its cache."
  (or (seq-find
       (lambda (buffer)
         (with-current-buffer buffer
           (and (derived-mode-p 'emacsos-assist-web-mode)
                (not emacsos-assist-web--draft-id)
                (equal emacsos-assist-web--thread-id thread-id))))
       (buffer-list))
      (let ((buffer (generate-new-buffer
                     (format "*assist recovered <%s>*" thread-id))))
        (with-current-buffer buffer
          (emacsos-assist-web-mode)
          (setq emacsos-assist-web--thread-id thread-id)
          (let ((inhibit-read-only t) (inhibit-modification-hooks t))
            (insert (format "*assist recovered <%s>*\n" thread-id))
            (setq emacsos-assist-web--status-start (copy-marker (point) nil))
            (insert "[recovering]")
            (setq emacsos-assist-web--status-end (copy-marker (point) nil))
            (insert "\n\n")
            (emacsos-assist-web--write-prompt)
            ;; Do not transport a provisional canonical queue before SOURCE
            ;; has either merged into it or remained the durable owner.
            (emacsos-assist-web--restore-draft t)))
        buffer)))

(defun emacsos-assist-web--restore-passive-legacy-accepted (draft)
  "Normalize DRAFT's accepted Run and optional bounded follow-up queue passively."
  (let ((key (alist-get 'pending_key draft))
        (text (alist-get 'text draft))
        (submitted (alist-get 'submitted_text draft))
        (run-id (alist-get 'run_id draft))
        (follow-ups (alist-get 'follow_ups draft)))
    (when (and (alist-get 'pending_accepted draft)
               (stringp key)
               (string-match-p emacsos-assist-web--idempotency-regexp key)
               (stringp submitted)
               (stringp run-id)
               (string-match-p emacsos-assist-web--record-id-regexp run-id)
               (emacsos-assist-web--message-fits-p
                submitted emacsos-assist-web--thread-id)
               (or (null follow-ups)
                   (and (listp follow-ups) (= (length follow-ups) 1)
                        (let ((follow-up (car follow-ups)))
                          (and (stringp (alist-get 'text follow-up))
                               (stringp (alist-get 'key follow-up))
                               (string-match-p emacsos-assist-web--idempotency-regexp
                                               (alist-get 'key follow-up))
                               (emacsos-assist-web--message-fits-p
                                (alist-get 'text follow-up)
                                emacsos-assist-web--thread-id))))))
      (let ((entry (emacsos-assist-web--entry submitted 'accepted-unobserved key))
            (follow-up (car follow-ups)))
        (setf (plist-get entry :run-id) run-id
              (plist-get entry :requires-reobserve) t)
        (setq emacsos-assist-web--queue
              (append (list entry)
                      (when follow-up
                        (list (emacsos-assist-web--entry
                               (alist-get 'text follow-up) 'queued
                               (alist-get 'key follow-up)))))
              emacsos-assist-web--queue-model-p t)
        (emacsos-assist-web--entry-render entry)
        (when (and (stringp text) (not (equal text submitted)))
          (insert text))
        t))))

(defun emacsos-assist-web--restore-draft (&optional passive-transport)
  "Restore queue state before exact transport, unless PASSIVE-TRANSPORT defers it."
  (when-let* ((name (emacsos-assist-web--draft-cache-name))
              (draft (emacsos-assist-web--read-cache name)))
    (let ((entries (alist-get 'queue draft))
          (text (alist-get 'text draft)) changed)
      (if (not entries)
          (if passive-transport
              (unless (emacsos-assist-web--restore-passive-legacy-accepted draft)
                (setq emacsos-assist-web--passive-recovery-invalid-p t)
                (emacsos-assist-web--set-prompt-refusal
                 "local canonical recovery needs repair; cached state is preserved"))
            (funcall #'emacsos-assist-web--legacy-restore-draft))
        (let* ((cached-thread-id (alist-get 'thread_id draft))
               (repo-key (alist-get 'repo_key draft))
               (harness (alist-get 'harness draft))
               (recovery-draft (alist-get 'recovery_draft draft))
               (collision (alist-get 'collision draft))
               (valid-outer
                (and (listp entries) (<= 1 (length entries) 4)
                     (stringp text)
                     (or (null cached-thread-id)
                         (and (stringp cached-thread-id)
                              (string-match-p emacsos-assist-web--record-id-regexp
                                              cached-thread-id)))
                     (or (null recovery-draft) (stringp recovery-draft))
                     (memq collision '(nil t))
                     ;; A new-thread POST must retain the exact selected body.
                     (or emacsos-assist-web--thread-id
                         (and (stringp repo-key)
                              (string-match-p emacsos-assist-web--record-id-regexp repo-key)
                              (stringp harness)
                              (string-match-p emacsos-assist-web--record-id-regexp harness))))))
          (if (not valid-outer)
              (progn
                (when (stringp text) (insert text))
                (emacsos-assist-web--set-prompt-refusal
                 "local recovery record is invalid; message remains in draft"))
            (let ((emacsos-assist-web--draft-repository repo-key)
                  (emacsos-assist-web--draft-harness harness)
                  restored)
              (when cached-thread-id
                (setq emacsos-assist-web--thread-id cached-thread-id))
              (setq restored
                    (mapcar
                     (lambda (value)
                       (let* ((state (intern-soft (alist-get 'state value)))
                              (key (alist-get 'key value))
                              (body (alist-get 'text value))
                              (run-id (alist-get 'run_id value))
                              (end-kind (alist-get 'observer_end_kind value))
                              (end-generation (alist-get 'observer_end_generation value))
                              (end-checked (alist-get 'observer_end_checked value))
                              (approval-stopped (alist-get 'approval_stopped value))
                              (live-text (alist-get 'live_text value))
                              (recovered-ready (alist-get 'recovered_ready value)))
                         (when (and (listp value)
                                    (memq state emacsos-assist-web--entry-states)
                                    (stringp body)
                                    (emacsos-assist-web--message-fits-p
                                     body emacsos-assist-web--thread-id)
                                    (memq live-text '(nil t))
                                    (memq recovered-ready '(nil t))
                                    (memq approval-stopped '(nil t))
                                    (or (and (null end-kind)
                                             (null end-generation)
                                             (null end-checked))
                                        (and (member end-kind
                                                     '("terminal-sse" "disconnect"
                                                       "operator-repair"))
                                             (natnump end-generation)
                                             (memq end-checked '(nil t))
                                             run-id))
                                    (or (eq state 'recovered-head)
                                        (and (stringp key)
                                             (string-match-p emacsos-assist-web--idempotency-regexp key)))
                                    (or (null run-id)
                                        (and (stringp run-id)
                                             (string-match-p emacsos-assist-web--record-id-regexp run-id)))
                                    (or (not (memq state '(accepted-unobserved observing
                                                            terminal-unreconciled reconciling)))
                                        run-id))
                           (let ((entry (emacsos-assist-web--entry body state key)))
                             (setf (plist-get entry :run-id) run-id
                                   ;; The first observer after reopen must be
                                   ;; newer than the durable ended observer.
                                   (plist-get entry :epoch)
                                   (or end-generation 0)
                                   (plist-get entry :observer-end-kind)
                                   (and end-kind (intern end-kind))
                                   (plist-get entry :observer-end-generation)
                                   end-generation
                                   (plist-get entry :observer-end-checked)
                                   end-checked
                                   (plist-get entry :approval-stopped)
                                   approval-stopped
                                   (plist-get entry :live-text) live-text
                                   (plist-get entry :recovered-ready) recovered-ready)
                             (pcase state
                               ('posting (setf (plist-get entry :state) 'acceptance-unknown)
                                         (setq changed t))
                               ('observing (setf (plist-get entry :state) 'accepted-unobserved)
                                           (setq changed t))
                               ('reconciling (setf (plist-get entry :state) 'terminal-unreconciled)
                                             (setq changed t)))
                             (when (memq (plist-get entry :state)
                                         '(accepted-unobserved terminal-unreconciled))
                               (setf (plist-get entry :requires-reobserve) t))
                             entry))))
                     entries))
              (if (or (memq nil restored)
                      (not (= (length (delete-dups (mapcar (lambda (entry)
                                                            (plist-get entry :key))
                                                          restored)))
                              (length restored)))
                      (not (if collision
                               (and (>= (length restored) 2)
                                    (<= (length restored) 4))
                             (<= (length restored) 2)))
                      (not (emacsos-assist-web--queue-cache-fits-p
                            restored text recovery-draft)))
                  (progn
                    (when (stringp text) (insert text))
                    (emacsos-assist-web--set-prompt-refusal
                     "local recovery record is invalid; message remains in draft"))
                (setq emacsos-assist-web--queue restored
                      emacsos-assist-web--queue-model-p t
                      emacsos-assist-web--collision-p collision
                      emacsos-assist-web--recovery-draft recovery-draft)
                (when (stringp text) (insert text))
                (dolist (entry emacsos-assist-web--queue)
                  (emacsos-assist-web--entry-render entry))
                (emacsos-assist-web--render-recovery-draft-action)
                (when (seq-some
                       (lambda (entry)
                         (eq (emacsos-assist-web--entry-state entry)
                             'terminal-unreconciled))
                       restored)
                  (emacsos-assist-web--manual-recovery-activate))
                ;; A normalized transport state is recovery truth only after it reaches
                ;; disk.  A failed write leaves this buffer visible but starts no retry,
                ;; GET, or SSE that could outlive the old cached claim.
                (when changed
                  (unless (emacsos-assist-web--save-draft)
                    (setq changed 'persistence-failed)
                    (when emacsos-assist-web--manual-recovery-required
                      (setq emacsos-assist-web--reconcile-recovery-paused t)
                      (emacsos-assist-web-git--invalidate
                       "local recovery could not be saved; restart to recover")
                      (emacsos-assist-web--set-status
                       "local recovery could not be saved; restart to recover"))))
                (unless (or passive-transport
                            (eq changed 'persistence-failed)
                            emacsos-assist-web--manual-recovery-required
                            (eq emacsos--assist-active-surface 'chat))
                  (let* ((source (current-buffer))
                         (thread-id emacsos-assist-web--thread-id)
                         (canonical
                          (and emacsos-assist-web--draft-id thread-id
                               (emacsos-assist-web--restore-canonical-buffer
                                thread-id))))
                    (if canonical
                        (if (with-current-buffer canonical
                              emacsos-assist-web--passive-recovery-invalid-p)
                            (progn
                              (setq emacsos-assist-web--passive-recovery-invalid-p t)
                              (emacsos-assist-web--set-prompt-refusal
                               "canonical recovery needs repair; local state is preserved"))
                          (if (emacsos-assist-web--adopt-canonical-buffer
                             source canonical)
                            (with-current-buffer canonical
                              (emacsos-assist-web--start-next-observation)
                              (emacsos-assist-web--reconcile-when-settled))
                            ;; The source stayed authoritative.  Its restored
                            ;; receipt must exact-GET, never reopen SSE directly.
                            (dolist (entry emacsos-assist-web--queue)
                              (when (and (eq (emacsos-assist-web--entry-state entry)
                                             'accepted-unobserved)
                                         (not (memq (plist-get entry :observer-end-kind)
                                                    '(disconnect operator-repair))))
                                (emacsos-assist-web--reobserve-entry entry)))))
                      (emacsos-assist-web--pump-posts)
                      (emacsos-assist-web--start-next-observation)
                      (emacsos-assist-web--reconcile-when-settled))))))))))))

(defun emacsos-assist-web--after-change (&rest _)
  "Persist edits without clearing a queue entry merely because its draft changed."
  (when (and (derived-mode-p 'emacsos-assist-web-mode)
             (not inhibit-modification-hooks))
    ;; Only a buffer that never adopted queue ownership can replace its legacy
    ;; cached retry with an edited draft.
    (when (and (not emacsos-assist-web--queue-model-p)
               (null emacsos-assist-web--queue)
               (not emacsos-assist-web--in-flight)
               emacsos-assist-web--pending-key
               (not (equal (emacsos-assist-web--input)
                           emacsos-assist-web--submitted-text)))
      (setq emacsos-assist-web--pending-key nil
            emacsos-assist-web--submitted-text nil
            emacsos-assist-web--pending-accepted-p nil
            emacsos-assist-web--run-id nil
            emacsos-assist-web--pending-rendered-p nil
            emacsos-assist-web--stream-status nil))
    (emacsos-assist-web--clear-prompt-refusal-if-changed)
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

(defun emacsos-assist-web--retire-active-streams-after-reload ()
  "Retire pre-reload observers without letting queue state reach singletons."
  (dolist (buffer (buffer-list))
    (when (and (buffer-live-p buffer)
               (with-current-buffer buffer
                 (derived-mode-p 'emacsos-assist-web-mode)))
      (with-current-buffer buffer
        (if emacsos-assist-web--queue
            (if-let ((entry emacsos-assist-web--stream-entry))
                (emacsos-assist-web--entry-observation-interrupted
                 entry (plist-get entry :epoch)
                 "Assist code reloaded; refresh observation")
              ;; A malformed/recovered queue cannot retain a pre-header token
              ;; after its callbacks were discarded by reload.
              (dolist (entry emacsos-assist-web--queue)
                (emacsos-assist-web--release-handshake entry)))
          (when emacsos-assist-web--stream-process
            (emacsos-assist-web--stream-interrupted
             buffer "Assist code reloaded; refresh observation")))))))

;; Reloading this file invalidates callbacks created by its previous function
;; definitions.  Retire active stream callbacks before advancing the catalog
;; generation; ordinary in-flight request callbacks release their refresh claim
;; when they observe that generation change.
(emacsos-assist-web--retire-active-streams-after-reload)
(cl-incf emacsos-assist-web--catalog-generation)
(emacsos-assist-web--cancel-pending-new-thread)
(emacsos-assist-web--load-catalog)

(provide 'assist-web)
;;; assist-web.el ends here
