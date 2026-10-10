;;; assist-web-git.el --- Ordinary local Git checkouts for Assist threads -*- lexical-binding: t -*-
;;; Commentary:
;; A thread selects one user-owned checkout.  Git refs and local worktree status,
;; not a client sync journal, determine what can be fast-forwarded.
;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(declare-function emacsos-assist-web-git--metadata-from-snapshot "assist-web")
(declare-function emacsos-assist-web--canonical-authorized "assist-web")
(declare-function emacsos-assist-web--valid-id-p "assist-web")
(declare-function emacsos-assist-web--thread-header "assist-web")
(declare-function magit-diff-range "magit-diff")
(declare-function magit-status-setup-buffer "magit-status")
(defvar emacsos-assist-web--denied)
(defvar emacsos-assist-web--snapshot)
(defvar emacsos-assist-web--thread-id)

(defgroup emacsos-assist-web-git nil
  "Local, editable Git checkouts for canonical Assist threads."
  :group 'emacsos-assist-web)

(defcustom emacsos-assist-web-git-workspace-directory (expand-file-name "~/assist")
  "User-owned root of persistent Assist thread checkouts."
  :type 'directory :group 'emacsos-assist-web-git)

(defcustom emacsos-assist-web-git-legacy-directory
  (expand-file-name "~/.cache/emacsos/assist-git")
  "Old checkouts are left here until the user explicitly migrates them."
  :type 'directory :group 'emacsos-assist-web-git)

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

(defvar emacsos-assist-web-git-thread-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c d") #'emacsos-assist-web-git-diff)
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

(defun emacsos-assist-web-git-local-directory ()
  "Return the current thread's existing local Git directory, or nil.
This is a query only; it never fetches, edits or creates a checkout."
  (let ((path (and emacsos-assist-web-git--metadata
                   (emacsos-assist-web-git--checkout-path
                    emacsos-assist-web-git--metadata))))
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
      (emacsos-assist-web-git--cancel)
      (setq emacsos-assist-web-git--result nil
            emacsos-assist-web-git--last-reminded-oid nil
            emacsos-assist-web-git--last-notice nil)
      (cl-incf emacsos-assist-web-git--epoch))
    (setq emacsos-assist-web-git--metadata metadata
          emacsos-assist-web-git--unavailable (plist-get metadata :sync-error)
          emacsos-assist-web-git--retry-after-denial nil)
    (emacsos-assist-web-git--sync-keys)
    (when-let ((notice (plist-get metadata :publication-notice)))
      (unless (equal notice emacsos-assist-web-git--last-notice)
        (setq emacsos-assist-web-git--last-notice notice)
        (message "%s" notice)))
    (emacsos-assist-web-git--update-headers)
    (or changed retry-after-denial)))

(defun emacsos-assist-web-git--invalidate (reason)
  "Cancel the old Git request and mark it unavailable for REASON."
  (cl-incf emacsos-assist-web-git--epoch)
  (when (eq emacsos-assist-web--denied t)
    (setq emacsos-assist-web-git--retry-after-denial t))
  (emacsos-assist-web-git--cancel)
  (setq emacsos-assist-web-git--unavailable reason)
  (emacsos-assist-web-git--update-headers))

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
  "Stop only this buffer's background Git request."
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
                   (not emacsos-assist-web-git--unavailable))
          (emacsos-assist-web-git--enqueue emacsos-assist-web-git--metadata))
        (when (and (not (eq emacsos-assist-web--denied t))
                 (= epoch emacsos-assist-web-git--epoch)
                 (equal (plist-get metadata :tid)
                        (plist-get emacsos-assist-web-git--metadata :tid))
                 (equal (plist-get metadata :repo-key)
                        (plist-get emacsos-assist-web-git--metadata :repo-key))
                 (equal (plist-get metadata :branch)
                        (plist-get emacsos-assist-web-git--metadata :branch)))
        (condition-case nil
            (let* ((response (and (= status 0)
                                  (json-parse-string output :object-type 'alist
                                                     :null-object nil :false-object nil)))
                   (ok (eq (alist-get 'ok response) t))
                   (path (alist-get 'checkout_path response)))
              (unless (and ok (stringp path)
                           (equal path (emacsos-assist-web-git--checkout-path metadata)))
                (error "Git helper did not confirm this checkout"))
              (setq emacsos-assist-web-git--unavailable
                    (plist-get emacsos-assist-web-git--metadata :sync-error))
              (if (equal action "migrate")
                  (progn
                    (message "Bound legacy checkout moved intact; refreshing its Git status")
                    (emacsos-assist-web-git-refresh))
                (setq emacsos-assist-web-git--result response)
                (let ((pending (alist-get 'pending response))
                      (remote (alist-get 'thread_oid response)))
                  (when (and pending
                             (or manual
                                 (and (string-match-p "local edits are unchanged" pending)
                                      (not (equal remote emacsos-assist-web-git--last-reminded-oid)))))
                    (setq emacsos-assist-web-git--last-reminded-oid remote)
                    (message "%s" pending))))
              (emacsos-assist-web-git--update-headers))
          (error
           (setq emacsos-assist-web-git--unavailable
                 "checkout update unavailable; local work preserved")
           (emacsos-assist-web-git--update-headers))))))))

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

(defun emacsos-assist-web-git-diff ()
  "Open Magit for the actual checkout, including local edits when dirty."
  (interactive)
  (let ((directory (emacsos-assist-web-git-local-directory)))
    (unless directory (user-error "Local Git checkout unavailable; Refresh first"))
    (let ((default-directory directory))
      (if (alist-get 'dirty emacsos-assist-web-git--result)
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

(defun emacsos-assist-web-git-choose-workspace ()
  "Explicitly move this thread's bound legacy checkout without discarding work."
  (interactive)
  (unless (plist-get emacsos-assist-web-git--metadata :branch)
    (user-error "No published thread branch is available"))
  (let ((roots (list (file-name-as-directory
                      (expand-file-name "checkouts" emacsos-assist-web-git-legacy-directory))
                     (file-name-as-directory
                      (expand-file-name emacsos-assist-web-git-workspace-directory)))))
    (when (cl-some (lambda (buffer)
                     (with-current-buffer buffer
                       (and buffer-file-name
                            (cl-some (lambda (root)
                                       (string-prefix-p root
                                                        (expand-file-name buffer-file-name)))
                                     roots))))
                   (buffer-list))
      (user-error "Close buffers visiting Assist checkout files before moving it")))
  (when (y-or-n-p "Move this thread's exact bound legacy checkout to ~/assist, keeping all files? ")
    (emacsos-assist-web-git--enqueue emacsos-assist-web-git--metadata t "migrate")))

(provide 'assist-web-git)
;;; assist-web-git.el ends here
