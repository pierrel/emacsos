;;; assist-web-git.el --- Ordinary local Git checkouts for Assist threads -*- lexical-binding: t -*-
;;; Commentary:
;; A thread selects one user-owned checkout.  Git refs and local worktree status,
;; not a client sync journal, determine what can be fast-forwarded.
;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(declare-function emacsos-assist-web-git--metadata-from-snapshot "assist-web")
(declare-function emacsos-assist-web--legacy-refresh-thread "assist-web")
(declare-function emacsos-assist-web--canonical-authorized "assist-web")
(declare-function emacsos-assist-web--valid-id-p "assist-web")
(declare-function emacsos-assist-web--thread-header "assist-web")
(declare-function emacsos-assist-web--request "assist-web")
(declare-function magit-diff-range "magit-diff")
(declare-function magit-status-setup-buffer "magit-status")
(defvar emacsos-assist-web--denied)
(defvar emacsos-assist-web--snapshot)
(defvar emacsos-assist-web--thread-id)
(defvar emacsos-assist-web--git-oid-regexp)

(defgroup emacsos-assist-web-git nil
  "Local, editable Git checkouts for canonical Assist threads."
  :group 'emacsos-assist-web)

(defcustom emacsos-assist-web-git-workspace-directory (expand-file-name "~/assist")
  "User-owned root of persistent Assist thread checkouts."
  :type 'directory :group 'emacsos-assist-web-git)

(defcustom emacsos-assist-web-git-legacy-directory
  (if (boundp 'emacsos-assist-web-git-cache-directory)
      (symbol-value 'emacsos-assist-web-git-cache-directory)
    (expand-file-name "~/.cache/emacsos/assist-git"))
  "Old checkouts are left here until the user explicitly migrates them."
  :type 'directory :group 'emacsos-assist-web-git)

(define-obsolete-variable-alias 'emacsos-assist-web-git-cache-directory
  'emacsos-assist-web-git-legacy-directory "2026-10-10")

(defcustom emacsos-assist-web-git-helper
  (expand-file-name "assist-web-git-helper.py"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Bounded background Git helper with separately provisioned SSH credentials."
  :type 'file :group 'emacsos-assist-web-git)

(defvar-local emacsos-assist-web-git--metadata nil)
(defvar-local emacsos-assist-web-git--result nil)
(defvar-local emacsos-assist-web-git--process nil)
(defvar-local emacsos-assist-web-git--output "")
(defvar-local emacsos-assist-web-git--unavailable nil)
(defvar-local emacsos-assist-web-git--last-reminded-oid nil)
(defvar-local emacsos-assist-web-git--last-notice nil)
(defvar-local emacsos-assist-web-git--epoch 0)
(defvar-local emacsos-assist-web-git--retry-after-denial nil)
(defvar-local emacsos-assist-web-git--fallback-file-opener nil)
(defvar-local emacsos-assist-web-git--workspace-choices nil)
(defvar-local emacsos-assist-web-git--status-source nil)
(defvar-local emacsos-assist-web-git--status-identity nil)
(defvar-local emacsos-assist-web-git--status-server nil)
(defvar-local emacsos-assist-web-git--status-fresh nil)
(defvar-local emacsos-assist-web-git--status-observation-source nil)
(defvar-local emacsos-assist-web-git--status-auth-epoch nil)
(defvar-local emacsos-assist-web-git--status-local nil)
(defvar-local emacsos-assist-web-git--status-local-state 'unavailable)
(defvar-local emacsos-assist-web-git--status-error nil)
(defvar-local emacsos-assist-web-git--status-pending nil)
(defvar-local emacsos-assist-web-git--status-outcome nil)
(defvar-local emacsos-assist-web-git--status-generation 0)
(defvar-local emacsos-assist-web-git--status-prompt-after-refresh nil)
(defvar-local emacsos-assist-web-git--status-process nil)
(defvar-local emacsos-assist-web-git--post-merge-view nil)

(defvar emacsos-assist-web-git-thread-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c g") #'emacsos-assist-web-git-refresh)
    (define-key map (kbd "C-c ?") #'emacsos-assist-web-details)
    map))

(define-minor-mode emacsos-assist-web-git-thread-mode
  "Expose Git keys only in a validated Assist thread buffer."
  :init-value nil :lighter " Git" :keymap emacsos-assist-web-git-thread-mode-map)

(defun emacsos-assist-web-git--identity (metadata)
  "Return the stable checkout suffix for METADATA."
  (substring (secure-hash 'sha256
                          (format "%s\n%s" (plist-get metadata :repo-key)
                                  (plist-get metadata :tid))) 0 16))

(defun emacsos-assist-web-git--checkout-path (metadata)
  "Return the deterministic user-owned checkout path for METADATA."
  (let ((key (plist-get metadata :repo-key))
        (tid (plist-get metadata :tid)))
    (when (and (stringp key) (string-match-p "\\`[0-9a-f]\\{20\\}\\'" key)
               (stringp tid) (string-match-p "\\`[A-Za-z0-9_-]\\{1,128\\}\\'" tid))
      (expand-file-name (concat key "/" tid "-"
                              (emacsos-assist-web-git--identity metadata))
                        emacsos-assist-web-git-workspace-directory))))

(defun emacsos-assist-web-git--selected-path (metadata response)
  "Return the helper-confirmed checkout for METADATA and RESPONSE."
  (let ((path (alist-get 'checkout_path response))
        (canonical (emacsos-assist-web-git--checkout-path metadata)))
    (when (and (stringp path)
               (or (equal path canonical)
                   (and (eq (alist-get 'legacy response) t)
                        (file-name-absolute-p path)
                        (or (file-in-directory-p path
                                                 emacsos-assist-web-git-workspace-directory)
                            (file-in-directory-p path
                                                 (expand-file-name
                                                  "checkouts"
                                                  emacsos-assist-web-git-legacy-directory)))
                        (not (file-symlink-p path))
                        (file-directory-p path)
                        (file-directory-p (expand-file-name ".git" path))
                        (not (file-symlink-p (expand-file-name ".git" path))))))
      path)))

(defun emacsos-assist-web-git-local-directory ()
  "Return the current thread's existing local Git directory, or nil.
This is a query only; it never fetches, edits or creates a checkout."
  (let ((path (and emacsos-assist-web-git--metadata
                   (if emacsos-assist-web-git--result
                       (emacsos-assist-web-git--selected-path
                        emacsos-assist-web-git--metadata emacsos-assist-web-git--result)
                     (emacsos-assist-web-git--checkout-path
                      emacsos-assist-web-git--metadata)))))
    (when (and path (file-directory-p path)
               (not (file-symlink-p path))
               (file-directory-p (expand-file-name ".git" path))
               (not (file-symlink-p (expand-file-name ".git" path))))
      (file-name-as-directory path))))

(defun emacsos-assist-web-git--thread-header ()
  "Return a concise Git state for the current Assist thread."
  (let ((metadata emacsos-assist-web-git--metadata)
        (result emacsos-assist-web-git--result))
    (cond
     (emacsos-assist-web-git--unavailable
      (concat "Git: " emacsos-assist-web-git--unavailable))
     ((not (plist-get metadata :branch)) "Git: no published thread branch")
     ((not result) "Git: checkout pending")
     (t (format "Git: %s%s%s"
                (or (alist-get 'branch result) (plist-get metadata :branch))
                (if (alist-get 'dirty result) " • local edits" "")
                (if (or (alist-get 'pending result)
                        (plist-get metadata :publication-notice))
                    " • update pending" ""))))))

(defun emacsos-assist-web-git--update-headers ()
  "Redisplay the local Git state without changing the transcript."
  (force-mode-line-update t))

(defun emacsos-assist-web-git--cancel ()
  "Ask the helper to stop its Git child before starting another."
  (when (process-live-p emacsos-assist-web-git--process)
    (ignore-errors (signal-process emacsos-assist-web-git--process 'SIGTERM))))

(defun emacsos-assist-web-git--stop-merge-refresh ()
  "Report an interrupted post-merge refresh without retrying the merge."
  (when-let ((view emacsos-assist-web-git--post-merge-view))
    (setq emacsos-assist-web-git--post-merge-view nil)
    (when (buffer-live-p view)
      (with-current-buffer view
        (setq emacsos-assist-web-git--status-outcome
              "Merged and pushed; refresh interrupted; reopen the thread")
        (emacsos-assist-web-git--status-render)
        (message "%s" emacsos-assist-web-git--status-outcome)))))

(defun emacsos-assist-web-git--note (metadata)
  "Select authenticated METADATA; request a fetch on new identity or reauthorization."
  (let ((changed (not (equal
                       (list (plist-get metadata :tid) (plist-get metadata :repo-key)
                             (plist-get metadata :branch))
                       (list (plist-get emacsos-assist-web-git--metadata :tid)
                             (plist-get emacsos-assist-web-git--metadata :repo-key)
                             (plist-get emacsos-assist-web-git--metadata :branch)))))
        (retry-after-denial emacsos-assist-web-git--retry-after-denial))
    (when changed
      (emacsos-assist-web-git--stop-merge-refresh)
      (emacsos-assist-web-git--cancel)
      (setq emacsos-assist-web-git--result nil
            emacsos-assist-web-git--last-reminded-oid nil
            emacsos-assist-web-git--last-notice nil)
      (cl-incf emacsos-assist-web-git--epoch))
    (setq emacsos-assist-web-git--metadata metadata
          emacsos-assist-web-git--unavailable (plist-get metadata :sync-error)
          emacsos-assist-web-git--retry-after-denial nil)
    (when (plist-get metadata :sync-error)
      (emacsos-assist-web-git--stop-merge-refresh))
    (emacsos-assist-web-git--sync-keys)
    (when-let ((notice (plist-get metadata :publication-notice)))
      (unless (equal notice emacsos-assist-web-git--last-notice)
        (setq emacsos-assist-web-git--last-notice notice)
        (message "%s" notice)))
    (emacsos-assist-web-git--update-headers)
    (or changed retry-after-denial)))

(defun emacsos-assist-web-git--invalidate (reason)
  "Cancel this thread's Git request and show REASON in attached status views."
  (cl-incf emacsos-assist-web-git--epoch)
  (emacsos-assist-web-git--stop-merge-refresh)
  (when (eq emacsos-assist-web--denied t)
    (setq emacsos-assist-web-git--retry-after-denial t))
  (emacsos-assist-web-git--cancel)
  (setq emacsos-assist-web-git--unavailable reason)
  (emacsos-assist-web-git--update-headers)
  (let ((source (current-buffer)))
    (dolist (view (buffer-list))
      (when (and (eq (buffer-local-value 'emacsos-assist-web-git--status-source view)
                     source)
                 (buffer-local-value 'emacsos-assist-web-git--status-identity view))
        (with-current-buffer view
          (setq emacsos-assist-web-git--status-fresh nil
                emacsos-assist-web-git--status-error reason)
          (emacsos-assist-web-git--status-render))))))

(defun emacsos-assist-web-git--gate-reason (&optional _remote-view)
  "Return a bounded current Git unavailability reason, if any."
  emacsos-assist-web-git--unavailable)

(defun emacsos-assist-web-git--sync-keys ()
  "Enable Git keys for a canonical thread, preserving its file opener."
  (when (derived-mode-p 'emacsos-assist-web-mode)
    (let ((canonical (emacsos-assist-web--valid-id-p emacsos-assist-web--thread-id)))
      (cond
       ((and canonical (not emacsos-assist-web-git--fallback-file-opener))
        (let ((opener (lookup-key (current-local-map) (kbd "C-x C-f"))))
          (when (or (null opener) (integerp opener))
            (define-key (current-local-map) (kbd "C-x C-f")
                        #'emacsos-assist-web-git-find-file)
            (setq emacsos-assist-web-git--fallback-file-opener t))))
       ((and (not canonical) emacsos-assist-web-git--fallback-file-opener)
        (when (eq (lookup-key (current-local-map) (kbd "C-x C-f"))
                  #'emacsos-assist-web-git-find-file)
          (define-key (current-local-map) (kbd "C-x C-f") nil))
        (setq emacsos-assist-web-git--fallback-file-opener nil)))
      (unless (eq (not (null canonical))
                  (not (null emacsos-assist-web-git-thread-mode)))
        (emacsos-assist-web-git-thread-mode (if canonical 1 -1)))
      (setq-local header-line-format
                  (when canonical '(:eval (emacsos-assist-web--thread-header)))))))

(defun emacsos-assist-web-git--clear-feedback (_window)
  "Compatibility no-op; Git no longer owns a window intent overlay.")

(defun emacsos-assist-web-git--teardown ()
  "Stop this buffer's Git request and report any interrupted merge refresh."
  (emacsos-assist-web-git--stop-merge-refresh)
  (emacsos-assist-web-git--cancel))

(defun emacsos-assist-web-git--receive (buffer metadata epoch output status manual &optional action process)
  "Apply METADATA's bounded OUTPUT and STATUS only to BUFFER's matching EPOCH.
MANUAL permits a repeated reminder; ACTION identifies a legacy move.
PROCESS, when provided, must be the request this receipt completes."
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (or (not process) (eq process emacsos-assist-web-git--process))
        (when process (setq emacsos-assist-web-git--process nil))
        (when (and process (/= epoch emacsos-assist-web-git--epoch)
                   (not (eq emacsos-assist-web--denied t))
                   (plist-get emacsos-assist-web-git--metadata :branch)
                   (or emacsos-assist-web-git--post-merge-view
                       (not emacsos-assist-web-git--unavailable)))
          (emacsos-assist-web-git--enqueue emacsos-assist-web-git--metadata))
        (when (and (not (eq emacsos-assist-web--denied t))
                 (= epoch emacsos-assist-web-git--epoch)
                 (equal (plist-get metadata :tid)
                        (plist-get emacsos-assist-web-git--metadata :tid))
                 (equal (plist-get metadata :repo-key)
                        (plist-get emacsos-assist-web-git--metadata :repo-key))
                 (equal (plist-get metadata :branch)
                        (plist-get emacsos-assist-web-git--metadata :branch)))
          (let (sync-complete)
            (condition-case nil
                (let* ((response (and (= status 0)
                                      (json-parse-string output :object-type 'alist
                                                         :null-object nil :false-object nil)))
                       (ok (eq (alist-get 'ok response) t))
                       (path (emacsos-assist-web-git--selected-path metadata response))
                       (reason (alist-get 'error response)))
                  (if (not ok)
                      (progn
                        (setq emacsos-assist-web-git--unavailable
                              (if (and (stringp reason) (<= (length reason) 256)
                                       (string-match-p "\\`[[:print:]]+\\'" reason))
                                  reason
                                "checkout update unavailable; local work preserved"))
                        (when manual (message "%s" emacsos-assist-web-git--unavailable)))
                    (unless path (error "Git helper did not confirm this checkout"))
                    (setq emacsos-assist-web-git--unavailable
                          (plist-get emacsos-assist-web-git--metadata :sync-error))
                    (if (equal action "migrate")
                        (progn
                          (message "Bound legacy checkout moved intact; refreshing its Git status")
                          (emacsos-assist-web-git-refresh))
                      (setq emacsos-assist-web-git--result response
                            sync-complete (not (alist-get 'pending response)))
                      (let ((pending (alist-get 'pending response))
                            (remote (alist-get 'thread_oid response)))
                        (when (and pending
                                   (or manual
                                       (and (string-match-p "local edits are unchanged" pending)
                                            (not (equal remote emacsos-assist-web-git--last-reminded-oid)))))
                          (setq emacsos-assist-web-git--last-reminded-oid remote)
                          (message "%s" pending)))
                      (when (and manual (not (alist-get 'pending response)))
                        (message "Refresh complete"))))
                  (emacsos-assist-web-git--update-headers))
              (error
               (setq emacsos-assist-web-git--unavailable
                     "checkout update unavailable; local work preserved")
               (emacsos-assist-web-git--update-headers)))
            (when-let ((view emacsos-assist-web-git--post-merge-view))
              (setq emacsos-assist-web-git--post-merge-view nil)
              (when (buffer-live-p view)
                (with-current-buffer view
                  (emacsos-assist-web-git--finish-merge-refresh sync-complete))))))))))

(defun emacsos-assist-web-git--enqueue (metadata &optional manual action)
  "Run METADATA's background Git ACTION without blocking the editor.
MANUAL permits a repeated status reminder."
  (when (and (not (eq emacsos-assist-web--denied t))
             (plist-get metadata :branch)
             (not emacsos-assist-web-git--process))
    (let* ((buffer (current-buffer))
           (epoch emacsos-assist-web-git--epoch)
           (request `((action . ,(or action "sync"))
                      (repo_key . ,(plist-get metadata :repo-key))
                      (thread_id . ,(plist-get metadata :tid))
                      (branch . ,(plist-get metadata :branch))
                      (legacy_root . ,(expand-file-name
                                       emacsos-assist-web-git-legacy-directory))
                      (workspace_root . ,(expand-file-name
                                          emacsos-assist-web-git-workspace-directory))))
           (output "")
           (process (make-process
                     :name "assist-thread-git" :buffer nil :command
                     (list (or (executable-find "python3")
                               (user-error "Expose Python 3.10+ in Emacs exec-path"))
                           emacsos-assist-web-git-helper)
                     :connection-type 'pipe :noquery t
                     :filter (lambda (proc chunk)
                               (setq output (concat output chunk))
                               (when (> (string-bytes output) 8192)
                                 (ignore-errors (signal-process proc 'SIGTERM))))
                     :sentinel (lambda (proc _event)
                                 (when (memq (process-status proc) '(exit signal))
                                   (emacsos-assist-web-git--receive
                                    buffer metadata epoch output (process-exit-status proc)
                                    manual action proc))))))
      (setq emacsos-assist-web-git--process process)
      (when manual (message "Refreshing…"))
      (process-send-string process (concat (json-serialize request) "\n"))
      (process-send-eof process))))

(defun emacsos-assist-web-git-refresh ()
  "Fetch the published thread branch; fast-forward only a clean checkout."
  (interactive)
  (when (eq emacsos-assist-web--denied t)
    (user-error "Assist authorization is denied; refresh the canonical thread first"))
  (unless (plist-get emacsos-assist-web-git--metadata :branch)
    (user-error "No published thread branch is available"))
  (emacsos-assist-web-git--enqueue emacsos-assist-web-git--metadata t))

(defun emacsos-assist-web-git-find-file ()
  "Browse ordinary files from the current thread's local Git checkout."
  (interactive)
  (let ((directory (emacsos-assist-web-git-local-directory)))
    (unless directory (user-error "Local Git checkout unavailable; Refresh first"))
    (let ((default-directory directory))
      (call-interactively #'find-file))))

(defun emacsos-assist-web-git--local-edits-p ()
  "Query the selected checkout's current tracked and untracked file state."
  (with-temp-buffer
    (unless (eq 0 (process-file "git" nil t nil
                                "-c" "core.fsmonitor=false" "status" "--porcelain"
                                "--untracked-files=normal"))
      (user-error "Local Git status is unavailable"))
    (not (= (buffer-size) 0))))

(defun emacsos-assist-web-git-diff ()
  "Open Magit for the actual checkout, querying local edits at invocation."
  (interactive)
  (let ((directory (emacsos-assist-web-git-local-directory)))
    (unless directory (user-error "Local Git checkout unavailable; Refresh first"))
    (let ((default-directory directory))
      (if (emacsos-assist-web-git--local-edits-p)
          (progn (require 'magit-status)
                 (magit-status-setup-buffer directory))
        (require 'magit-diff)
        (magit-diff-range "refs/remotes/origin/main...HEAD")))))

(defun emacsos-assist-web-git-thread-details ()
  "Show the local checkout and the last observed actual Git status."
  (interactive)
  (message "%s%s • %s" (emacsos-assist-web-git--thread-header)
           (if-let ((directory (emacsos-assist-web-git-local-directory)))
               (concat " • " directory) " • Refresh to create checkout")
           (if-let ((status (alist-get 'status_short emacsos-assist-web-git--result)))
               (if (string-empty-p status) "clean"
                 (replace-regexp-in-string "\n" "; " status))
             "status not fetched")))

(defun emacsos-assist-web-git--open-checkout-buffer-p (roots)
  "Return non-nil when another open buffer is under a path in ROOTS."
  (let ((caller (current-buffer))
        (resolved (mapcar (lambda (root)
                            (file-name-as-directory (file-truename root))) roots)))
    (cl-some (lambda (buffer)
               (unless (eq buffer caller)
                 (with-current-buffer buffer
                   (cl-some (lambda (location)
                              (and location (not (file-remote-p location))
                                   (cl-some (lambda (root)
                                              (string-prefix-p root
                                                               (file-truename location)))
                                            resolved)))
                            (list buffer-file-name default-directory)))))
             (buffer-list))))

(defun emacsos-assist-web-git-choose-workspace ()
  "Explicitly move this thread's bound legacy checkout without discarding work."
  (interactive)
  (unless (plist-get emacsos-assist-web-git--metadata :branch)
    (user-error "No published thread branch is available"))
  (let ((roots (list (file-name-as-directory
                      (expand-file-name "checkouts" emacsos-assist-web-git-legacy-directory))
                     (file-name-as-directory
                      (expand-file-name emacsos-assist-web-git-workspace-directory)))))
    (when (emacsos-assist-web-git--open-checkout-buffer-p roots)
      (user-error "Close buffers using Assist checkouts before moving one")))
  (when (y-or-n-p "Move this thread's exact bound legacy checkout to ~/assist, keeping all files? ")
    (emacsos-assist-web-git--enqueue emacsos-assist-web-git--metadata t "migrate")))

(defun emacsos-assist-web-git--status-action (_button)
  "Confirm this view's freshly observed server merge in the minibuffer."
  (emacsos-assist-web-git--status-confirm))

(defconst emacsos-assist-web-git--merge-warning
  "SERVER Merge & Push uses only the published thread branch.\nUnsaved, staged, uncommitted, untracked, and locally\ncommitted-but-unpushed work is excluded. Save, commit\nand push it first. Success fetches Git and may fast-forward\na clean local checkout. Local edits are preserved.\n")

(defun emacsos-assist-web-git--status-valid-source-p ()
  "Whether this view still names its original authorized canonical thread."
  (and (buffer-live-p emacsos-assist-web-git--status-source)
       (let ((identity emacsos-assist-web-git--status-identity))
         (with-current-buffer emacsos-assist-web-git--status-source
           (and (not (eq emacsos-assist-web--denied t))
                (equal emacsos-assist-web--thread-id (car identity))
                (equal (plist-get emacsos-assist-web-git--metadata :repo-key)
                       (cdr identity)))))))

(defun emacsos-assist-web-git--status-observation-current-p ()
  "Whether the displayed Git facts retain their source authorization."
  (and emacsos-assist-web-git--status-fresh
       (eq emacsos-assist-web-git--status-observation-source
           emacsos-assist-web-git--status-source)
       (integerp emacsos-assist-web-git--status-auth-epoch)
       (emacsos-assist-web-git--status-valid-source-p)
       (let ((observed-epoch emacsos-assist-web-git--status-auth-epoch))
         (with-current-buffer emacsos-assist-web-git--status-source
           (eql observed-epoch emacsos-assist-web--auth-epoch)))))

(defun emacsos-assist-web-git--status-refresh-checkout (_button)
  "Refresh this status view's original local checkout, without merging."
  (unless (emacsos-assist-web-git--status-valid-source-p)
    (user-error "Open an authorized canonical Assist thread first"))
  (when emacsos-assist-web-git--status-pending
    (user-error "Wait for the server Merge & Push result"))
  (with-current-buffer emacsos-assist-web-git--status-source
    (emacsos-assist-web-git-refresh)))

(defun emacsos-assist-web-git--status-details (_button)
  "Show Git details for this status view's original canonical thread."
  (unless (emacsos-assist-web-git--status-valid-source-p)
    (user-error "Open an authorized canonical Assist thread first"))
  (with-current-buffer emacsos-assist-web-git--status-source
    (emacsos-assist-web-git-thread-details)))

(defun emacsos-assist-web-git--status-render ()
  "Render a touch-readable factual Git view without altering local work."
  (let ((inhibit-read-only t)
        (server emacsos-assist-web-git--status-server)
        (local emacsos-assist-web-git--status-local)
        (fresh (emacsos-assist-web-git--status-observation-current-p)))
    (erase-buffer)
    (insert "Assist Git status\n\n")
    (when emacsos-assist-web-git--status-outcome
      (insert emacsos-assist-web-git--status-outcome "\n\n"))
    (insert (format "Server branch: %s\n"
                    (or (alist-get 'branch server) "unavailable")))
    (insert (format "Published commit: %s\n"
                    (or (alist-get 'published_revision server)
                        (if (equal (alist-get 'state server) "unpublished")
                            "unpublished" "unavailable"))))
    (insert (format "Server observation: %s%s\n\n"
                    (if fresh "fresh" "stale/unavailable")
                    (if-let ((seen (alist-get 'observed_at server)))
                        (concat " at " seen) "")))
    (insert (format "Local checkout: %s\n"
                    (cond ((not local)
                           (if (eq emacsos-assist-web-git--status-local-state 'checking)
                               "checking" "unavailable"))
                          ((not (alist-get 'local_oid local)) "not available")
                          ((eq (alist-get 'detached local) t) "detached HEAD")
                          (t (or (alist-get 'branch local) "unavailable")))))
    (insert (format "Local commit: %s\n"
                    (or (alist-get 'local_oid local) "unavailable")))
    (insert (format "Local observation: %s\n\n"
                    (if-let ((seen (alist-get 'observed_at local)))
                        (concat "at " seen " (may now be stale)")
                      (if (eq emacsos-assist-web-git--status-local-state 'checking)
                          "checking" "unavailable; refresh to retry"))))
    (insert (format "Comparison: %s\n\n"
                    (if (and fresh
                             (alist-get 'published_revision server)
                             (alist-get 'local_oid local))
                        (if (and (equal (alist-get 'branch server)
                                        (alist-get 'branch local))
                                 (equal (alist-get 'published_revision server)
                                        (alist-get 'local_oid local)))
                            "same branch and commit" "different branch or commit")
                      "unavailable")))
    (when emacsos-assist-web-git--status-error
      (insert emacsos-assist-web-git--status-error "\n\n"))
    (unless emacsos-assist-web-git--status-pending
      (insert-text-button "Refresh facts"
                          'follow-link t
                          'action (lambda (_) (emacsos-assist-web-git--status-refresh)))
      (insert "  ")
      (insert-text-button "Refresh checkout"
                          'follow-link t
                          'action #'emacsos-assist-web-git--status-refresh-checkout))
    (insert "  ")
    (insert-text-button "Git details"
                        'follow-link t
                        'action #'emacsos-assist-web-git--status-details)
    (insert "\n\n")
    (insert emacsos-assist-web-git--merge-warning)
    (when (and fresh
               (equal (alist-get 'state server) "available")
               (not emacsos-assist-web-git--status-pending))
      (insert-text-button "  SERVER Merge & Push  "
                          'follow-link t
                          'action #'emacsos-assist-web-git--status-action))
    (goto-char (point-min))))

(defun emacsos-assist-web-git--status-confirm ()
  "Ask about the exact published commit, then submit one server merge."
  (let ((identity emacsos-assist-web-git--status-identity)
        (server emacsos-assist-web-git--status-server)
        (source emacsos-assist-web-git--status-source)
        (generation emacsos-assist-web-git--status-generation)
        (auth-epoch (when (buffer-live-p emacsos-assist-web-git--status-source)
                      (buffer-local-value 'emacsos-assist-web--auth-epoch
                                          emacsos-assist-web-git--status-source)))
        (view (current-buffer)))
    (when (and emacsos-assist-web-git--status-fresh
               (not (emacsos-assist-web-git--status-observation-current-p)))
      (setq emacsos-assist-web-git--status-fresh nil
            emacsos-assist-web-git--status-error
            "Thread authorization changed; refresh Git facts")
      (emacsos-assist-web-git--status-render))
    (unless (and (emacsos-assist-web-git--status-observation-current-p)
                 (not emacsos-assist-web-git--status-pending)
                 (equal (alist-get 'state server) "available")
                 (stringp (alist-get 'branch server))
                 (stringp (alist-get 'published_revision server)))
      (user-error "Refresh the exact server Git status before Merge & Push"))
    (if (not (condition-case nil
                 (y-or-n-p
                  (format "Merge SERVER %s @ %s?  Local unsaved/staged/uncommitted/untracked/unpushed work excluded? "
                          (alist-get 'branch server)
                          (alist-get 'published_revision server)))
               (quit nil)))
        (progn
          (setq emacsos-assist-web-git--status-outcome "Merge cancelled; nothing submitted")
          (emacsos-assist-web-git--status-render)
          (message "Merge cancelled"))
      (unless (and (emacsos-assist-web-git--status-observation-current-p)
                   (not emacsos-assist-web-git--status-pending)
                   (equal identity emacsos-assist-web-git--status-identity)
                   (equal server emacsos-assist-web-git--status-server)
                   (eq source emacsos-assist-web-git--status-source)
                   (= generation emacsos-assist-web-git--status-generation)
                   (with-current-buffer source
                     (eql auth-epoch emacsos-assist-web--auth-epoch)))
        (user-error "Server Git facts changed during confirmation; refresh first"))
      (setq emacsos-assist-web-git--status-pending t
            emacsos-assist-web-git--status-outcome "Merging…")
      (emacsos-assist-web-git--status-render)
      (message "Merging…")
      (with-current-buffer source
        (emacsos-assist-web--request
         "POST" (concat "threads/" (car identity) "/merge") nil
         (lambda (value error)
           (when (buffer-live-p view)
             (with-current-buffer view
               (when (equal identity emacsos-assist-web-git--status-identity)
                 (let ((merged (and (not error)
                                    (consp value) (proper-list-p value)
                                    (cl-every #'consp value)
                                    (= (cl-count 'http_status value :key #'car) 1)
                                    (= (cl-count 'outcome value :key #'car) 1)
                                    (eql (alist-get 'http_status value) 200)
                                    (equal (alist-get 'outcome value) "merged"))))
                   (setq emacsos-assist-web-git--status-pending nil
                         emacsos-assist-web-git--status-fresh nil
                         emacsos-assist-web-git--status-outcome
                         (cond
                          ((and (listp error)
                                (memq (plist-get error :kind) '(credentials busy)))
                           "Merge not submitted; check credentials or request budget")
                          ((and (listp error) (eq (plist-get error :kind) 'http))
                           "Server rejected Merge & Push; no success confirmed")
                          (error "Merge outcome unknown; inspect server before retry")
                          ((not (and (consp value) (proper-list-p value)
                                     (cl-every #'consp value)
                                     (= (cl-count 'http_status value :key #'car) 1)
                                     (= (cl-count 'outcome value :key #'car) 1)))
                           "Merge response invalid; inspect server before retry")
                          (merged "Merged and pushed")
                          ((and (eql (alist-get 'http_status value) 409)
                                (equal (alist-get 'outcome value) "conflict"))
                           "Server merge conflicted; resolve on the server or a Git client")
                          ((and (eql (alist-get 'http_status value) 409)
                                (equal (alist-get 'outcome value) "busy"))
                           "Server thread is busy; no merge was performed")
                          ((and (eql (alist-get 'http_status value) 409)
                                (equal (alist-get 'outcome value) "stale"))
                           "Published commit changed; refresh facts before merging")
                          ((and (integerp (alist-get 'http_status value))
                                (>= (alist-get 'http_status value) 400))
                           (format "Server Merge & Push failed (HTTP %d); no success confirmed"
                                   (alist-get 'http_status value)))
                          (t "Merge outcome unconfirmed; inspect server before retry")))
                   (emacsos-assist-web-git--status-render)
                   (message "%s" emacsos-assist-web-git--status-outcome)
                   (when merged
                     (emacsos-assist-web-git--refresh-after-merge source view)))))))
         `(("X-Assist-Expected-Commit" . ,(alist-get 'published_revision server)))
         t nil nil t)))))

(defun emacsos-assist-web-git--status-local-receive (view generation output status &optional completed)
  "Apply bounded local HEAD OUTPUT only to VIEW's current GENERATION.
COMPLETED receives whether the local observation succeeded."
  (when (buffer-live-p view)
    (with-current-buffer view
      (when (= generation emacsos-assist-web-git--status-generation)
        (setq emacsos-assist-web-git--status-process nil)
        (condition-case nil
            (let ((value (and (= status 0)
                              (json-parse-string output :object-type 'alist
                                                 :null-object nil :false-object nil))))
              (setq emacsos-assist-web-git--status-local
                    (and (listp value) (eq (alist-get 'ok value) t) value)
                    emacsos-assist-web-git--status-local-state
                    (if emacsos-assist-web-git--status-local 'observed 'unavailable)))
          (error (setq emacsos-assist-web-git--status-local nil
                       emacsos-assist-web-git--status-local-state 'unavailable)))
        (emacsos-assist-web-git--status-render)
        (when completed
          (funcall completed (eq emacsos-assist-web-git--status-local-state 'observed)))))))

(defun emacsos-assist-web-git--status-inspect-local (view generation metadata &optional completed)
  "Read METADATA's local HEAD for VIEW and GENERATION in a bounded helper.
COMPLETED receives whether the local observation succeeded."
  (let* ((output "")
        (process (make-process
                  :name "assist-git-head" :buffer nil :noquery t :connection-type 'pipe
                  :command (list (or (executable-find "python3")
                                     (user-error "Expose Python 3.10+ in Emacs exec-path"))
                                 emacsos-assist-web-git-helper)
                  :filter (lambda (proc chunk)
                            (setq output (concat output chunk))
                            (when (> (string-bytes output) 8192)
                              (ignore-errors (signal-process proc 'SIGTERM))))
                  :sentinel (lambda (proc _event)
                              (when (memq (process-status proc) '(exit signal))
                                (emacsos-assist-web-git--status-local-receive
                                 view generation output (process-exit-status proc)
                                 completed))))))
    (with-current-buffer view
      (setq emacsos-assist-web-git--status-process process))
    (process-send-string
     process (concat (json-serialize
                      `((action . "inspect")
                        (repo_key . ,(plist-get metadata :repo-key))
                        (thread_id . ,(plist-get metadata :tid))
                        (workspace_root . ,(expand-file-name
                                            emacsos-assist-web-git-workspace-directory))
                        (legacy_root . ,(expand-file-name
                                         emacsos-assist-web-git-legacy-directory)))) "\n"))
    (process-send-eof process)))

(defun emacsos-assist-web-git--status-cancel-local ()
  "Stop only this view's read-only local HEAD probe."
  (when (process-live-p emacsos-assist-web-git--status-process)
    (ignore-errors (signal-process emacsos-assist-web-git--status-process 'SIGTERM)))
  (setq emacsos-assist-web-git--status-process nil))

(defun emacsos-assist-web-git--status-may-kill-p ()
  "Keep an in-flight server merge attached to its outcome view."
  (if emacsos-assist-web-git--status-pending
      (progn (message "Wait for the server Merge & Push result") nil)
    t))

(defun emacsos-assist-web-git--status-refresh (&optional completed)
  "Get fresh server and local Git facts.
Call COMPLETED with server and local validity after both observations,
or report failure immediately if authorization changes."
  (interactive)
  (unless (emacsos-assist-web-git--status-valid-source-p)
    (user-error "Open an authorized canonical Assist thread first"))
  (when emacsos-assist-web-git--status-pending
    (user-error "Wait for the server Merge & Push result before refreshing"))
  (emacsos-assist-web-git--status-cancel-local)
  (cl-incf emacsos-assist-web-git--status-generation)
  (let* ((generation emacsos-assist-web-git--status-generation)
        (identity emacsos-assist-web-git--status-identity)
        (source emacsos-assist-web-git--status-source)
        (auth-epoch (with-current-buffer emacsos-assist-web-git--status-source
                      emacsos-assist-web--auth-epoch))
        (view (current-buffer))
        (metadata (with-current-buffer emacsos-assist-web-git--status-source
                    emacsos-assist-web-git--metadata))
        local-finished local-valid server-finished server-valid
        (report (lambda ()
                  (when (and completed local-finished server-finished)
                    (let ((callback completed))
                      (setq completed nil)
                      (when (and server-valid
                                 (or (/= generation emacsos-assist-web-git--status-generation)
                                     (not (eq source emacsos-assist-web-git--status-source))
                                     (not (emacsos-assist-web-git--status-observation-current-p))))
                        (setq server-valid nil local-valid nil
                              emacsos-assist-web-git--status-fresh nil
                              emacsos-assist-web-git--status-error
                              "Thread authorization changed; refresh Git facts")
                        (emacsos-assist-web-git--status-render))
                      (funcall callback server-valid local-valid))))))
    (setq emacsos-assist-web-git--status-fresh nil
          emacsos-assist-web-git--status-observation-source nil
          emacsos-assist-web-git--status-auth-epoch nil
          emacsos-assist-web-git--status-local nil
          emacsos-assist-web-git--status-local-state 'checking
          emacsos-assist-web-git--status-error nil)
    (emacsos-assist-web-git--status-render)
    (condition-case nil
        (emacsos-assist-web-git--status-inspect-local
         view generation metadata
         (lambda (valid)
           (setq local-finished t local-valid valid)
           (funcall report)))
      (error
       (emacsos-assist-web-git--status-cancel-local)
       (setq emacsos-assist-web-git--status-local-state 'unavailable
             local-finished t)
       (emacsos-assist-web-git--status-render)
       (funcall report)))
    (with-current-buffer source
      (emacsos-assist-web--request
       "GET" (concat "threads/" (car identity) "/git") nil
       (lambda (value error)
         (when (buffer-live-p view)
           (with-current-buffer view
             (when (and (= generation emacsos-assist-web-git--status-generation)
                        (equal identity emacsos-assist-web-git--status-identity))
               (if (not (and (emacsos-assist-web-git--status-valid-source-p)
                             (with-current-buffer source
                               (eql auth-epoch emacsos-assist-web--auth-epoch))))
                   (progn
                     (setq emacsos-assist-web-git--status-fresh nil
                           emacsos-assist-web-git--status-prompt-after-refresh nil
                           emacsos-assist-web-git--status-error
                           "Thread authorization changed; reopen before using Git facts")
                     (emacsos-assist-web-git--status-render)
                     (when completed
                       (let ((callback completed))
                         (setq completed nil)
                         (funcall callback nil nil))))
                 (let ((valid (and (not error)
                                 (consp value) (proper-list-p value)
                                 (cl-every #'consp value)
                                 (equal (alist-get 'thread_id value) (car identity))
                                 (equal (alist-get 'repo_key value) (cdr identity))
                                 (member (alist-get 'state value) '("available" "unpublished"))
                                 (stringp (alist-get 'branch value))
                                 (<= (string-bytes (alist-get 'branch value)) 240)
                                 (not (string-match-p "[[:cntrl:]]" (alist-get 'branch value)))
                                 (stringp (alist-get 'observed_at value))
                                 (<= (string-bytes (alist-get 'observed_at value)) 64)
                                 (or (not (equal (alist-get 'state value) "available"))
                                     (and (stringp (alist-get 'published_revision value))
                                          (string-match-p emacsos-assist-web--git-oid-regexp
                                                          (alist-get 'published_revision value)))))))
                 (setq emacsos-assist-web-git--status-fresh valid
                       emacsos-assist-web-git--status-error
                       (unless valid "Server Git facts unavailable; prior observation is stale"))
                 (when valid
                   (setq emacsos-assist-web-git--status-server value
                         emacsos-assist-web-git--status-observation-source source
                         emacsos-assist-web-git--status-auth-epoch auth-epoch))
                 (setq server-finished t server-valid (and valid t))
                 (let ((prompt (and valid
                                    emacsos-assist-web-git--status-prompt-after-refresh
                                    (equal (alist-get 'state value) "available"))))
                   (setq emacsos-assist-web-git--status-prompt-after-refresh nil)
                   (emacsos-assist-web-git--status-render)
                   (funcall report)
                   (when prompt (emacsos-assist-web-git--status-confirm)))))))))
       nil nil nil nil t))))

(defun emacsos-assist-web-git--finish-merge-refresh (checkout-complete)
  "Refresh Git facts after the merge's checkout fetch.
CHECKOUT-COMPLETE says whether the local checkout reached its thread tip."
  (condition-case nil
      (emacsos-assist-web-git--status-refresh
       (lambda (facts-complete local-complete)
         (setq emacsos-assist-web-git--status-outcome
               (cond
                ((not checkout-complete)
                 "Merged and pushed; checkout update incomplete; inspect local Git status")
                ((not facts-complete)
                 "Merged and pushed; Git facts unavailable; use Refresh facts")
                ((not local-complete)
                 "Merged and pushed; local status unavailable; use Refresh facts")
                (t "Merged and pushed; Git refresh complete")))
         (emacsos-assist-web-git--status-render)
         (message "%s" emacsos-assist-web-git--status-outcome)))
    (error
     (setq emacsos-assist-web-git--status-outcome
           "Merged and pushed; refresh unavailable; reopen the thread")
     (emacsos-assist-web-git--status-render)
     (message "%s" emacsos-assist-web-git--status-outcome))))

(defun emacsos-assist-web-git--refresh-after-merge (source view)
  "Refresh SOURCE's checkout after its verified server merge.
Observe its thread only when no message is queued; VIEW receives the outcome."
  (message "Refreshing…")
  (if (not (buffer-live-p source))
      (progn
        (setq emacsos-assist-web-git--status-outcome
              "Merged and pushed; reopen the thread to refresh")
        (emacsos-assist-web-git--status-render)
        (message "%s" emacsos-assist-web-git--status-outcome))
    (with-current-buffer source
      (setq emacsos-assist-web-git--post-merge-view view)
      (condition-case nil
          (progn
            ;; Legacy rendering cannot preserve a resident queue.  Leave it
            ;; untouched; the public Refresh command may POST its head.
            (unless (emacsos-assist-web--queue-head)
              (emacsos-assist-web--legacy-refresh-thread source))
            (unless (and (not (eq emacsos-assist-web--denied t))
                         (plist-get emacsos-assist-web-git--metadata :branch))
              (error "Git checkout refresh unavailable"))
            (if emacsos-assist-web-git--process
                (progn
                  (cl-incf emacsos-assist-web-git--epoch)
                  (emacsos-assist-web-git--cancel))
              (emacsos-assist-web-git--enqueue emacsos-assist-web-git--metadata)))
        (error
         (setq emacsos-assist-web-git--post-merge-view nil)
         (when (buffer-live-p view)
           (with-current-buffer view
             (emacsos-assist-web-git--finish-merge-refresh nil))))))))

(defun emacsos-assist-web-git--open-status (&optional merge)
  "Open the thread's factual Git view; MERGE requests a fresh prompt."
  (let* ((source (if (and (boundp 'emacsos-assist-web-git--status-source)
                          emacsos-assist-web-git--status-source)
                     emacsos-assist-web-git--status-source (current-buffer)))
         (metadata (with-current-buffer source emacsos-assist-web-git--metadata))
         (tid (plist-get metadata :tid))
         (repo (plist-get metadata :repo-key)))
    (unless (and (buffer-live-p source) (stringp tid) (stringp repo)
                 (with-current-buffer source
                   (and (equal tid emacsos-assist-web--thread-id)
                        (not (eq emacsos-assist-web--denied t)))))
      (user-error "Open an authorized canonical Assist Git thread first"))
    (let ((view (get-buffer-create (format "*Assist Git %s*" tid))))
      (with-current-buffer view
        (unless (derived-mode-p 'special-mode) (special-mode))
        (use-local-map (copy-keymap (current-local-map)))
        (local-set-key (kbd "TAB") #'forward-button)
        (local-set-key (kbd "<backtab>") #'backward-button)
        (add-hook 'kill-buffer-hook #'emacsos-assist-web-git--status-cancel-local nil t)
        (add-hook 'kill-buffer-query-functions
                  #'emacsos-assist-web-git--status-may-kill-p nil t)
        (if emacsos-assist-web-git--status-pending
            (unless (equal emacsos-assist-web-git--status-identity (cons tid repo))
              (user-error "Another thread's Merge & Push is still pending"))
          (unless (equal emacsos-assist-web-git--status-identity (cons tid repo))
            (setq emacsos-assist-web-git--status-server nil))
          (setq emacsos-assist-web-git--status-source source
                emacsos-assist-web-git--status-identity (cons tid repo)
                emacsos-assist-web-git--status-prompt-after-refresh merge)
          (emacsos-assist-web-git--status-refresh)))
      (pop-to-buffer view))))

(defun emacsos-assist-web-git-status ()
  "Show fresh server-published and read-only local Git facts."
  (interactive)
  (emacsos-assist-web-git--open-status))

(defun emacsos-assist-web-git-merge ()
  "Confirm one fresh server Merge and Push in the minibuffer."
  (interactive)
  (if (and emacsos-assist-web-git--status-source
           emacsos-assist-web-git--status-fresh)
      (emacsos-assist-web-git--status-confirm)
    (emacsos-assist-web-git--open-status t)))

(provide 'assist-web-git)
;;; assist-web-git.el ends here
