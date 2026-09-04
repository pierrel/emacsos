;;; assist-web.el --- Assist Web threads in EmacsOS -*- lexical-binding: t -*-

;; This is deliberately separate from emacos-assist.el.  A .assist file is a
;; phone-local conversation owned by emacsos-server; this mode is a client of
;; Assist Web's canonical thread/run/workspace state.

(require 'cl-lib)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'url)
(require 'url-http)

(declare-function emacos--render-page "os")
(declare-function emacos--chat-input-start "chat")

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
  "Private on-phone cache for Assist Web snapshots and workspace mirrors."
  :type 'directory
  :group 'emacos-assist-web)

(defconst emacos-assist-web--prompt "\n> ")
(defconst emacos-assist-web--catalog-file "threads.json")
(defconst emacos-assist-web--id-regexp "\\`[A-Za-z0-9][A-Za-z0-9._-]\\{0,127\\}\\'")
(defvar emacos-assist-web--catalog nil)
(defvar emacos-assist-web--active-request nil)
(defvar emacos-assist-web--stream-process nil)
(defvar emacos-assist-web--stream-buffer nil)
(defvar emacos-assist-web--active-buffer nil)

(defvar-local emacos-assist-web--thread-id nil)
(defvar-local emacos-assist-web--draft-repository nil)
(defvar-local emacos-assist-web--draft-harness nil)
(defvar-local emacos-assist-web--workspace nil)
(defvar-local emacos-assist-web--workspace-branch nil)
(defvar-local emacos-assist-web--workspace-revision nil)
(defvar-local emacos-assist-web--run-id nil)
(defvar-local emacos-assist-web--pending-key nil)
(defvar-local emacos-assist-web--in-flight nil)
(defvar-local emacos-assist-web--stream-body-marker nil)
(defvar-local emacos-assist-web--stream-event nil)
(defvar-local emacos-assist-web--stream-data nil)
(defvar-local emacos-assist-web--submitted-text nil)
(defvar-local emacos-assist-web--draft-id nil)
(defvar-local emacos-assist-web--draft-save-timer nil)

(defun emacos-assist-web--cache-path (&optional name)
  "Return cache path NAME, creating the private cache root when needed."
  (make-directory emacos-assist-web-cache-directory t)
  (set-file-modes emacos-assist-web-cache-directory #o700)
  (expand-file-name (or name emacos-assist-web--catalog-file)
                    emacos-assist-web-cache-directory))

(defun emacos-assist-web--write-cache (name value)
  "Atomically save VALUE as JSON cache NAME."
  (let ((path (emacos-assist-web--cache-path name))
        (temporary nil))
    (make-directory (file-name-directory path) t)
    (set-file-modes (file-name-directory path) #o700)
    (setq temporary (make-temp-file (concat path ".") nil ".tmp"))
    (unwind-protect
        (progn
          (with-temp-file temporary
            (insert (json-encode value)))
          (set-file-modes temporary #o600)
          (rename-file temporary path t)
          (setq temporary nil))
      (when (and temporary (file-exists-p temporary))
        (delete-file temporary)))))

(defun emacos-assist-web--read-cache (name)
  "Return parsed JSON cache NAME, or nil when no valid cache exists."
  (condition-case nil
      (let ((path (emacos-assist-web--cache-path name)))
        (when (file-readable-p path)
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

(defun emacos-assist-web--request (method path payload callback &optional headers)
  "Issue one async authenticated JSON request and invoke CALLBACK.

CALLBACK receives (VALUE ERROR).  Network and parsing failures are reported as
ERROR rather than raised from url-http's asynchronous callback."
  (let ((token (emacos-assist-web--read-token)))
    (if (not (and token (not (string-empty-p token))))
        (funcall callback nil "Assist Web token is missing")
      (let* ((url-request-method method)
             (url-request-extra-headers
              (append `(("Authorization" . ,(concat "Bearer " token))
                        ("Accept" . "application/json"))
                      (when payload '(("Content-Type" . "application/json")))
                      headers))
             (url-request-data
              (and payload (encode-coding-string (json-encode payload) 'utf-8)))
             (url (emacos-assist-web--endpoint path)))
        (condition-case error
            (url-retrieve
             url
             (lambda (_status)
               (let (value problem)
                 (unwind-protect
                     (condition-case parse-error
                         (setq value
                               (emacos-assist-web--response-json (current-buffer)))
                       (error (setq problem (error-message-string parse-error))))
                   (kill-buffer (current-buffer)))
                 (funcall callback value problem)))
             nil t t)
          (error (funcall callback nil (error-message-string error))))))))

(defun emacos-assist-web--leading-emoji-p (character)
  "Non-nil for the pictographic code points ignored at a title's start."
  (or (and (>= character #x1f000) (<= character #x1faff))
      (and (>= character #x2600) (<= character #x27bf))
      (member character '(#x200d #xfe0e #xfe0f))))

(defun emacos-assist-web--stream-cleanup ()
  "Detach this buffer from the one currently observed server event stream."
  (when (process-live-p emacos-assist-web--stream-process)
    (delete-process emacos-assist-web--stream-process))
  (setq emacos-assist-web--stream-process nil
        emacos-assist-web--stream-buffer nil)
  (setq emacos-assist-web--in-flight nil
        emacos-assist-web--stream-body-marker nil
        emacos-assist-web--stream-event nil
        emacos-assist-web--stream-data nil)
  (when (eq emacos-assist-web--active-buffer (current-buffer))
    (setq emacos-assist-web--active-buffer nil))
  (when (fboundp 'emacos--render-page) (emacos--render-page)))

(defun emacos-assist-web--stream-finish (buffer)
  "Finish BUFFER's event observation and refresh its canonical transcript."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (emacos-assist-web--stream-cleanup)
      (setq emacos-assist-web--pending-key nil
            emacos-assist-web--submitted-text nil)
      (emacos-assist-web-refresh-thread buffer))))

(defun emacos-assist-web--dispatch-event (event data)
  "Handle one bounded SSE EVENT with JSON DATA in the stream buffer."
  (cond
   ((equal event "status")
    (condition-case nil
        (let ((status (json-parse-string data :object-type 'alist)))
          (message "Assist: %s" (alist-get 'status status)))
      (error nil)))
   ((equal event "terminal")
    (emacos-assist-web--stream-finish (current-buffer)))
   ((equal event "error")
    (message "Assist event stream ended: %s" data)
    (emacos-assist-web--stream-finish (current-buffer)))))

(defun emacos-assist-web--drain-events ()
  "Consume complete SSE records appended by url-http to this response buffer."
  (unless (markerp emacos-assist-web--stream-body-marker)
    (setq-local emacos-assist-web--stream-body-marker
                (copy-marker (marker-position url-http-end-of-headers) nil)))
  (let* ((start (marker-position emacos-assist-web--stream-body-marker))
         (raw (buffer-substring-no-properties start (point-max)))
         (offset 0))
    ;; A complete SSE record ends in a blank line.  Do not consume a partial
    ;; record: url-http can split any byte sequence across process callbacks.
    (while (string-match "\n\n" raw offset)
      (let ((event nil)
            (data nil)
            (record (substring raw offset (match-beginning 0))))
        (dolist (line (split-string record "\n" t))
          (cond
           ((string-prefix-p "event: " line) (setq event (substring line 7)))
           ((string-prefix-p "data: " line) (setq data (substring line 6)))))
        (when (and event (buffer-live-p emacos-assist-web--stream-buffer))
          (with-current-buffer emacos-assist-web--stream-buffer
            (emacos-assist-web--dispatch-event event (or data ""))))
        (setq offset (match-end 0))))
    (when (> offset 0)
      (set-marker emacos-assist-web--stream-body-marker (+ start offset)))))

(defun emacos-assist-web--event-filter (url-filter)
  "Wrap URL-FILTER and drain emitted SSE records without blocking redisplay."
  (lambda (process bytes)
    (when (functionp url-filter) (funcall url-filter process bytes))
    (let ((response (process-buffer process)))
      (when (buffer-live-p response)
        (with-current-buffer response
          (when (and (boundp 'url-http-end-of-headers) url-http-end-of-headers
                     (buffer-live-p emacos-assist-web--stream-buffer))
            (emacos-assist-web--drain-events)))))))

(defun emacos-assist-web--observe-run (buffer)
  "Open BUFFER's bounded authenticated SSE status stream for its current run."
  (let ((token (emacos-assist-web--read-token)))
    (if (not (and token (not (string-empty-p token))))
        (message "Assist Web token is missing")
      (let* ((url-request-method "GET")
             (url-request-extra-headers `(("Authorization" . ,(concat "Bearer " token))))
             (response (url-retrieve
                        (emacos-assist-web--endpoint
                         (format "threads/%s/runs/%s/events"
                                 emacos-assist-web--thread-id emacos-assist-web--run-id))
                        #'ignore nil t t))
             (process (and (buffer-live-p response) (get-buffer-process response))))
        (if (not process)
            (progn
              (emacos-assist-web--stream-cleanup)
              (message "Could not start Assist event stream. Refresh to see its result."))
          (progn
            (setq emacos-assist-web--stream-buffer buffer
                  emacos-assist-web--stream-process process)
            (set-process-filter process
                                (emacos-assist-web--event-filter (process-filter process)))
            (let ((url-sentinel (process-sentinel process)))
              (set-process-sentinel
               process
               (lambda (ended event)
                 (when (functionp url-sentinel) (funcall url-sentinel ended event))
                 (when (and (not (process-live-p ended))
                            (eq ended emacos-assist-web--stream-process)
                            (buffer-live-p emacos-assist-web--stream-buffer))
                   (with-current-buffer emacos-assist-web--stream-buffer
                     (emacos-assist-web--stream-cleanup)
                     (message "Assist observation ended. Refresh to see its result."))))))))))))

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
  "Display THREAD in Pierre's requested thread-buffer format."
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
              (display (if (> (gethash label counts) 1)
                           (emacos-assist-web--thread-label
                            thread (format " [%s]" (substring (alist-get 'id thread) -6)))
                         label)))
         (list :display display :thread thread
               :search (downcase (concat (emacos-assist-web-normalize-title
                                           (alist-get 'description thread))
                                          " " (alist-get 'description thread)
                                          " " (or (alist-get 'repo_label thread) ""))))))
     emacos-assist-web--catalog)))

(defun emacos-assist-web--completion-table (records)
  "Build a completion table that matches normalized titles but returns display text."
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
  "Return the completion record selected by DISPLAY."
  (seq-find (lambda (record) (equal display (plist-get record :display))) records))

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

(defun emacos-assist-web--safe-local-file (path)
  "Return PATH under this buffer's workspace mirror, or nil on escape."
  (when (and emacos-assist-web--workspace (stringp path)
             (not (string-prefix-p "/" path))
             (not (string-match-p "\\(?:\\`\\|/\\)\\.\\.\\(?:/\\|\\'\\)" path)))
    (let* ((root (file-truename (file-name-as-directory emacos-assist-web--workspace)))
           (candidate (expand-file-name path root)))
      (when (file-in-directory-p candidate root) candidate))))

(defun emacos-assist-web--workspace-path (tid)
  "Return the owned local mirror directory for safe thread id TID."
  (unless (and (stringp tid) (string-match-p emacos-assist-web--id-regexp tid))
    (error "Invalid Assist Web thread id"))
  (let ((root (emacos-assist-web--cache-path "workspaces/")))
    (make-directory root t)
    (expand-file-name tid root)))

(defun emacos-assist-web--workspace-ready (tid)
  "Return non-nil when TID's local snapshot workspace has been populated."
  (file-exists-p (expand-file-name ".emacos-assist-web-snapshot"
                                   (emacos-assist-web--workspace-path tid))))

(defun emacos-assist-web--publish-workspace-stage (stage tid branch)
  "Publish unpacked STAGE as TID's local snapshot on local BRANCH.

STAGE is already completely unpacked.  The caller retains it if publishing
fails, so the previous usable snapshot stays intact until this point."
  (let ((workspace (emacos-assist-web--workspace-path tid)))
    ;; This is a cache, never the user’s source checkout.  `workspace' is
    ;; constructed from a validated thread id under our private root.
    (when (file-directory-p workspace) (delete-directory workspace t))
    (rename-file stage workspace)
    (when (executable-find "git")
      (unless (eq 0 (call-process "git" nil nil nil "init" "-q" "-b"
                                  (or branch "assist-web-snapshot") workspace))
        (error "Could not initialize local workspace snapshot"))
      (call-process "git" nil nil nil "-C" workspace "add" "-A")
      (call-process "git" nil nil nil "-C" workspace "-c" "user.name=Assist Web"
                    "-c" "user.email=assist-web@localhost" "commit" "-q"
                    "--allow-empty" "-m" "Assist Web workspace snapshot"))
    (with-temp-file (expand-file-name ".emacos-assist-web-snapshot" workspace)
      (insert "This directory is an Assist Web read-only snapshot.\n"))
    workspace))

(defun emacos-assist-web--extract-workspace-async (archive tid branch callback)
  "Unpack ARCHIVE off the UI path, then call CALLBACK with (WORKSPACE ERROR)."
  (let* ((workspace (emacos-assist-web--workspace-path tid))
         (root (file-name-directory (directory-file-name workspace)))
         (stage (make-temp-file (expand-file-name ".workspace-" root) t))
         (log (generate-new-buffer " *assist-web-tar*")))
    (make-process
     :name "assist-web-workspace-unpack" :buffer log :noquery t
     :command (list "tar" "-xzf" archive "-C" stage)
     :sentinel
     (lambda (process _event)
       (when (memq (process-status process) '(exit signal))
         (let (result problem)
           (unwind-protect
               (condition-case err
                   (if (and (eq (process-status process) 'exit)
                            (zerop (process-exit-status process)))
                       (setq result (emacos-assist-web--publish-workspace-stage stage tid branch)
                             stage nil)
                     (error "Could not unpack Assist Web workspace"))
                 (error (setq problem (error-message-string err))))
             (when (file-directory-p stage) (delete-directory stage t))
             (when (file-exists-p archive) (delete-file archive))
             (when (buffer-live-p log) (kill-buffer log)))
           (funcall callback result problem)))))))

(defun emacos-assist-web-sync-workspace (&optional open-after open-path)
  "Refresh this buffer's local worktree snapshot without blocking Emacs."
  (interactive)
  (if (not emacos-assist-web--thread-id)
      (message "Send this draft first")
    (let* ((tid emacos-assist-web--thread-id)
           (workspace (emacos-assist-web--workspace-path tid))
           (archive (make-temp-file "emacos-assist-web-workspace-" nil ".tar.gz"))
           (buffer (current-buffer)))
      (let ((token (emacos-assist-web--read-token)))
        (if (not (and token (not (string-empty-p token))))
            (progn (delete-file archive) (message "Assist Web token is missing"))
          (let ((url-request-method "GET")
                (url-request-extra-headers
                 `(("Authorization" . ,(concat "Bearer " token)))))
            (url-retrieve
             (emacos-assist-web--endpoint (concat "threads/" tid "/workspace/archive"))
             (lambda (_status)
               (let ((problem nil))
                 (unwind-protect
                     (condition-case err
                         (progn
                           (unless (and url-http-response-status
                                        (<= 200 url-http-response-status 299))
                             (error "Workspace download failed (%s)" url-http-response-status))
                           (write-region url-http-end-of-headers (point-max) archive nil 'silent)
                           (unless (and (> (nth 7 (file-attributes archive)) 0)
                                        (<= (nth 7 (file-attributes archive)) (* 33 1024 1024)))
                             (error "Workspace archive is invalid"))
                           (emacos-assist-web--extract-workspace-async
                            archive tid emacos-assist-web--workspace-branch
                            (lambda (updated extraction-error)
                              (if extraction-error
                                  (message "Workspace sync failed: %s" extraction-error)
                                (when (buffer-live-p buffer)
                                  (with-current-buffer buffer
                                    (setq emacos-assist-web--workspace updated
                                          default-directory updated)))
                                (if open-path
                                    (emacos-assist-web--open-file open-path)
                                  (when open-after
                                    (emacos-assist-web--open-workspace updated)))
                                (message "Workspace snapshot updated"))))
                           (setq archive nil))
                       (error (setq problem (error-message-string err))))
                   (when (and archive (file-exists-p archive)) (delete-file archive))
                   (kill-buffer (current-buffer)))
                 (when problem (message "Workspace sync failed: %s" problem))))
             nil t t)))))))

(defun emacos-assist-web--open-file (path)
  "Open a server-supplied workspace PATH only inside this thread's mirror."
  (interactive)
  (let ((file (emacos-assist-web--safe-local-file path)))
    (if (and file (file-readable-p file))
        (progn (find-file file) (view-mode 1))
      (if emacos-assist-web--thread-id
          (progn
            (message "Fetching workspace before opening %s" path)
            (emacos-assist-web-sync-workspace nil path))
        (message "File is not in this thread's local workspace: %s" path)))))

(defun emacos-assist-web--read-only-workspace-command ()
  "Refuse an edit to an Assist Web workspace snapshot."
  (interactive)
  (user-error "Assist Web workspace snapshots are read-only"))

(defun emacos-assist-web--open-workspace (workspace)
  "Open read-only dired rooted at the local snapshot WORKSPACE."
  (dired workspace)
  (setq-local emacos-assist-web--workspace-read-only t)
  (dolist (command '(dired-do-rename dired-do-delete dired-do-copy dired-create-directory))
    (local-set-key (vector 'remap command) #'emacos-assist-web--read-only-workspace-command)))

(defun emacos-assist-web--insert-assistant (message)
  "Insert one assistant MESSAGE, turning only structured file references into links."
  (let* ((text (alist-get 'text message))
         (references (alist-get 'file_refs message))
         (offset 0)
         (response-id (alist-get 'id message))
         (response-start (point)))
    (dolist (reference references)
      (let* ((path (alist-get 'path reference))
             (match (and path (string-match (regexp-quote path) text offset))))
        (when match
          (insert (substring text offset match))
          (let ((start (point)))
            (insert path)
            (add-text-properties
             start (point)
             `(mouse-face highlight help-echo "Open workspace file"
                          keymap ,(let ((map (make-sparse-keymap)))
                                    (define-key map [mouse-1]
                                      (lambda () (interactive) (emacos-assist-web--open-file path)))
                                    map)))
          (setq offset (match-end 0)))))
    (insert (substring text offset))
    (add-text-properties response-start (point)
                         `(emacos-assist-web-response-id ,response-id)))))

(defun emacos-assist-web--render (snapshot &optional stale)
  "Render SNAPSHOT in the current dedicated remote-thread buffer."
  (let ((inhibit-read-only t)
        (inhibit-modification-hooks t)
        (thread (alist-get 'thread snapshot))
        (draft (emacos-assist-web--input)))
    (setq emacos-assist-web--thread-id (alist-get 'id thread)
          emacos-assist-web--workspace
          (emacos-assist-web--workspace-path emacos-assist-web--thread-id)
          emacos-assist-web--workspace-branch
          (alist-get 'branch (alist-get 'workspace thread))
          emacos-assist-web--workspace-revision
          (alist-get 'revision (alist-get 'workspace thread))
          default-directory emacos-assist-web--workspace)
    (make-directory emacos-assist-web--workspace t)
    (erase-buffer)
    (let ((transcript-start (point)))
    (insert (format "%s%s\n"
                    (emacos-assist-web--thread-label
                     `((description . ,(alist-get 'description thread))
                       (repo_label . ,(alist-get 'repo_label (alist-get 'workspace thread)))))
                    (if stale " [cached]" "")))
    (insert (format "[%s%s]\n\n" (alist-get 'status thread)
                    (if-let ((error (alist-get 'error thread)))
                        (concat ": " error) "")))
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
  (concat "threads/" tid ".json"))

(defun emacos-assist-web--draft-cache-name ()
  "Return the private cache name for this thread or local draft buffer."
  (when-let ((identity (or emacos-assist-web--thread-id emacos-assist-web--draft-id)))
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
    (setq emacos-assist-web--pending-key (alist-get 'pending_key draft)
          emacos-assist-web--submitted-text (alist-get 'submitted_text draft))
    (when-let ((text (alist-get 'text draft)))
      (insert text))))

(defun emacos-assist-web--show-thread (thread)
  "Create or select THREAD's dedicated buffer and fetch its canonical snapshot."
  (let* ((name (emacos-assist-web--thread-label thread))
         (tid (alist-get 'id thread))
         ;; The human label remains in the rendered header.  The opaque suffix
         ;; makes the Emacs buffer identity one-to-one even for duplicate titles.
         (buffer (get-buffer-create (format "%s <%s>" name tid))))
    (with-current-buffer buffer
      (emacos-assist-web-mode)
      (setq emacos-assist-web--thread-id tid)
      (when-let ((cached (emacos-assist-web--read-cache
                          (emacos-assist-web--snapshot-cache-name tid))))
        (emacos-assist-web--render cached t)))
    (switch-to-buffer buffer)
    (emacos-assist-web-refresh-thread buffer)))

(defun emacos-assist-web-open-thread ()
  "Choose and open one cached Assist Web thread without a network wait."
  (interactive)
  (emacos-assist-web--load-catalog)
  (if (not emacos-assist-web--catalog)
      (progn
        (message "No cached threads. Tap Refresh Threads, then reopen.")
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
  (emacos-assist-web--request
   "GET" "threads" nil
   (lambda (value error)
     (if error
         (message "Thread refresh failed: %s" error)
       (setq emacos-assist-web--catalog (alist-get 'threads value))
       (emacos-assist-web--write-cache emacos-assist-web--catalog-file value)
       (message "Threads updated. Open Threads to choose one.")))))

(defun emacos-assist-web--load-catalog ()
  "Load catalog cache once at mode startup."
  (unless emacos-assist-web--catalog
    (when-let ((cached (emacos-assist-web--read-cache emacos-assist-web--catalog-file)))
      (setq emacos-assist-web--catalog (alist-get 'threads cached)))))

(defun emacos-assist-web-refresh-thread (&optional buffer)
  "Fetch and render BUFFER's canonical thread snapshot asynchronously."
  (interactive)
  (let ((buffer (or buffer (current-buffer))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when emacos-assist-web--thread-id
          (let ((tid emacos-assist-web--thread-id))
            (emacos-assist-web--request
             "GET" (concat "threads/" tid) nil
             (lambda (value error)
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (if error
                       (message "Thread refresh failed: %s" error)
                     (emacos-assist-web--write-cache
                      (emacos-assist-web--snapshot-cache-name tid) value)
                     (emacos-assist-web--render value))))))))))))

(defun emacos-assist-web-load-older ()
  "Load one older bounded page of this thread's canonical visible history."
  (interactive)
  (if (not emacos-assist-web--thread-id)
      (message "This draft has no history")
    (let* ((tid emacos-assist-web--thread-id)
           (name (emacos-assist-web--snapshot-cache-name tid))
           (cached (emacos-assist-web--read-cache name))
           (before (and cached (alist-get 'next_before cached)))
           (buffer (current-buffer)))
      (if (not before)
          (message "No older messages are available")
        (emacos-assist-web--request
         "GET" (format "threads/%s/history?before=%s" tid before) nil
         (lambda (page error)
           (when (buffer-live-p buffer)
             (with-current-buffer buffer
               (if error
                   (message "Older history failed: %s" error)
                 (setf (alist-get 'messages cached)
                       (append (alist-get 'messages page) (alist-get 'messages cached))
                       (alist-get 'has_older_messages cached) (alist-get 'has_older_messages page)
                       (alist-get 'next_before cached) (alist-get 'next_before page))
                 (emacos-assist-web--write-cache name cached)
                 (emacos-assist-web--render cached))))))))))

(defun emacos-assist-web--new-idempotency-key ()
  "Mint one opaque retry key; it is persisted in the buffer while pending."
  (concat "emacsos-" (md5 (format "%s-%s-%s" (float-time) (random) (emacs-pid)))))

(defun emacos-assist-web-send ()
  "Send this buffer's prompt to its canonical web thread exactly once."
  (interactive)
  (let ((text (or emacos-assist-web--submitted-text
                  (emacos-assist-web--input))))
    (cond
     ((string-empty-p text) (message "Nothing to send"))
     (emacos-assist-web--in-flight (message "A web-thread request is already running"))
     ((and emacos-assist-web--active-buffer
           (not (eq emacos-assist-web--active-buffer (current-buffer))))
      (message "Another Assist Web request is still being observed"))
     (t
      (setq emacos-assist-web--in-flight t
            emacos-assist-web--active-buffer (current-buffer)
            emacos-assist-web--pending-key (or emacos-assist-web--pending-key
                                               (emacos-assist-web--new-idempotency-key))
            emacos-assist-web--submitted-text text)
      (emacos-assist-web--save-draft)
      (let ((buffer (current-buffer))
            (key emacos-assist-web--pending-key)
            (path nil) (payload nil))
        (if emacos-assist-web--thread-id
            (setq path (concat "threads/" emacos-assist-web--thread-id "/messages")
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
               (if error
                   (progn (setq emacos-assist-web--in-flight nil)
                          (when (eq emacos-assist-web--active-buffer buffer)
                            (setq emacos-assist-web--active-buffer nil))
                          (message "Send failed. Retry keeps the same message: %s" error))
                 (setq emacos-assist-web--thread-id (alist-get 'thread_id value)
                       emacos-assist-web--run-id (alist-get 'run_id value))
                 (emacos-assist-web--append-pending text)
                 (emacos-assist-web--save-draft)
                 (emacos-assist-web--observe-run buffer)))))
         `(("Idempotency-Key" . ,key))))))))

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
      (message "No Assist run is being observed")
    (let ((buffer (current-buffer))
          (path (format "threads/%s/runs/%s"
                        emacos-assist-web--thread-id emacos-assist-web--run-id)))
      (emacos-assist-web--request
       "DELETE" path nil
       (lambda (_value error)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (emacos-assist-web--stream-cleanup)
             (if error
                 (message "Assist had already started; stopped watching it")
               (message "Queued Assist run cancelled"))
             (emacos-assist-web-refresh-thread buffer))))))))

(defun emacos-assist-web-new-thread ()
  "Open a local draft which becomes a web thread only on its first Send."
  (interactive)
  (emacos-assist-web--load-catalog)
  (let* ((cache (emacos-assist-web--read-cache emacos-assist-web--catalog-file))
         (repositories (alist-get 'repositories cache))
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

(defun emacos-assist-web-show-diff ()
  "Fetch the authoritative thread diff into an Emacs diff buffer."
  (interactive)
  (if (not emacos-assist-web--thread-id)
      (message "Send this draft first")
    (let ((tid emacos-assist-web--thread-id))
      (emacos-assist-web--request
       "GET" (concat "threads/" tid "/diff") nil
       (lambda (value error)
         (if error
             (message "Diff failed: %s" error)
           (let ((buffer (get-buffer-create (format "*assist diff %s*" tid))))
             (with-current-buffer buffer
               (let ((inhibit-read-only t))
                 (erase-buffer)
                 (dolist (file (alist-get 'files value)) (insert (alist-get 'diff file) "\n"))
                 (diff-mode)
                 (setq buffer-read-only t)))
             (switch-to-buffer buffer))))))))

(defun emacos-assist-web-show-pins ()
  "Show this thread's durable server-owned response pins."
  (interactive)
  (if (not emacos-assist-web--thread-id)
      (message "This draft has no pins yet")
    (let ((tid emacos-assist-web--thread-id))
      (emacos-assist-web--request
       "GET" (concat "threads/" tid "/pins") nil
       (lambda (value error)
         (if error
             (message "Pins failed: %s" error)
           (let ((buffer (get-buffer-create (format "*assist pins %s*" tid))))
             (with-current-buffer buffer
               (special-mode)
               (let ((inhibit-read-only t))
                 (erase-buffer)
                 (dolist (pin (alist-get 'pins value))
                   (insert (format "[%s]\n%s\n\n" (alist-get 'created_at pin)
                                   (alist-get 'text pin))))))
             (switch-to-buffer buffer))))))))

(defun emacos-assist-web-pin-response ()
  "Pin the finalized assistant response at point."
  (interactive)
  (let ((response-id (get-text-property (point) 'emacos-assist-web-response-id)))
    (if (not response-id)
        (message "Put point in an assistant response to pin it")
      (emacos-assist-web--request
       "POST" (format "threads/%s/pins" emacos-assist-web--thread-id)
       `((response_id . ,response-id))
       (lambda (_value error)
         (message "%s" (if error (concat "Pin failed: " error) "Pinned response")))))))

(defun emacos-assist-web-show-files ()
  "Open the local workspace mirror, refreshing it when first requested."
  (interactive)
  (if (and emacos-assist-web--thread-id
           (emacos-assist-web--workspace-ready emacos-assist-web--thread-id))
      (emacos-assist-web--open-workspace emacos-assist-web--workspace)
    (emacos-assist-web-sync-workspace t)))

(defun emacos-assist-web--command-set ()
  "Compact command band for a canonical web-thread buffer."
  (if emacos-assist-web--in-flight
      (list (cons "ABORT" #'emacos-assist-web-abort)
            (cons "Refresh" #'emacos-assist-web-refresh-thread)
            (cons "Diff" #'emacos-assist-web-show-diff))
    (list (cons "Refresh" #'emacos-assist-web-refresh-thread)
          (cons "Files" #'emacos-assist-web-show-files)
          (cons "Sync files" #'emacos-assist-web-sync-workspace)
          (cons "Older" #'emacos-assist-web-load-older)
          (cons "Diff" #'emacos-assist-web-show-diff)
          (cons "Pins" #'emacos-assist-web-show-pins)
          (cons "Pin" #'emacos-assist-web-pin-response)
          (cons "New thread" #'emacos-assist-web-new-thread))))

(define-derived-mode emacos-assist-web-mode text-mode "Assist Web"
  "Major mode for an existing canonical Assist Web thread."
  (variable-pitch-mode 1)
  (setq-local truncate-lines nil)
  (add-hook 'after-change-functions #'emacos-assist-web--after-change nil t))

(global-set-key (kbd "C-t") #'emacos-assist-web-open-thread)

(emacos-assist-web--load-catalog)

(provide 'assist-web)
;;; assist-web.el ends here
