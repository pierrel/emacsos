;;; assist-web-git.el --- Committed Assist thread Git views -*- lexical-binding: t -*-

;;; Commentary:
;; This module presents exact remote-verified thread Git generations in Emacs.

;;; Code:

(require 'cl-lib)
(require 'json)
(require 'subr-x)

(declare-function emacsos-assist-web--request "assist-web")
(declare-function emacsos-assist-web--require-snapshot "assist-web")
(declare-function emacsos-assist-web--snapshot-active-p "assist-web")
(declare-function emacsos-assist-web--require-id "assist-web")
(declare-function emacsos-assist-web--valid-id-p "assist-web")
(declare-function emacsos-assist-web-git--metadata-from-snapshot "assist-web")
(declare-function magit-diff-range "magit-diff")
(declare-function magit-section-forward "magit-section")
(declare-function magit-section-backward "magit-section")
(declare-function magit-section-toggle "magit-section")

(defgroup emacsos-assist-web-git nil
  "Committed Git views for canonical Assist Web threads."
  :group 'emacsos-assist-web)

(defcustom emacsos-assist-web-git-cache-directory
  (expand-file-name "~/.cache/emacsos/assist-git")
  "Private root for immutable thread Git generations."
  :type 'directory
  :group 'emacsos-assist-web-git)

(defcustom emacsos-assist-web-git-helper
  (expand-file-name "assist-web-git-helper.py"
                    (file-name-directory (or load-file-name buffer-file-name)))
  "Installed helper that performs bounded Git work outside Emacs's input loop."
  :type 'file
  :group 'emacsos-assist-web-git)

(defconst emacsos-assist-web-git--file-view-limit (* 1024 1024)
  "Largest mirror worktree file opened synchronously in a view.")

(cl-defstruct emacsos-assist-web-git-generation
  id path metadata oid main state views)

(defvar-local emacsos-assist-web-git--metadata nil)
(defvar-local emacsos-assist-web-git--current nil)
(defvar-local emacsos-assist-web-git--previous nil)
(defvar-local emacsos-assist-web-git--request nil)
(defvar-local emacsos-assist-web-git--next nil)
(defvar-local emacsos-assist-web-git--canceling nil)
(defvar-local emacsos-assist-web-git--epoch 0)
(defvar-local emacsos-assist-web-git--intent-serial 0)
(defvar-local emacsos-assist-web-git--unavailable nil)
(defvar-local emacsos-assist-web-git--view-thread nil)
(defvar-local emacsos-assist-web-git--view-generation nil)
(defvar-local emacsos-assist-web-git--chooser-thread nil)
(defvar-local emacsos-assist-web-git--chooser-generation nil)

(defvar emacsos-assist-web-git-view-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c b") #'emacsos-assist-web-git-back)
    (define-key map (kbd "C-c s") #'emacsos-assist-web-git-show-sha)
    (define-key map (kbd "C-c r") #'emacsos-assist-web-git-close-old-view)
    map))

(defvar emacsos-assist-web-git-magit-map
  (let ((map (make-sparse-keymap)))
    (define-key map [t] #'emacsos-assist-web-git--deny-mutation)
    (dolist (pair '(("q" . emacsos-assist-web-git-back)
                    ("C-c b" . emacsos-assist-web-git-back)
                    ("C-c s" . emacsos-assist-web-git-show-sha)
                    ("C-c r" . emacsos-assist-web-git-close-old-view)
                    ("TAB" . magit-section-toggle)
                    ("RET" . magit-section-toggle)
                    ("n" . magit-section-forward)
                    ("p" . magit-section-backward)
                    ("j" . next-line)
                    ("k" . previous-line)
                    ("SPC" . scroll-up-command)
                    ("DEL" . scroll-down-command)
                    ("<down>" . next-line)
                    ("<up>" . previous-line)))
      (define-key map (kbd (car pair)) (cdr pair)))
    map))

(defvar emacsos-assist-web-git-thread-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-x C-f") #'emacsos-assist-web-git-find-file)
    (define-key map (kbd "C-c d") #'emacsos-assist-web-git-diff)
    (define-key map (kbd "C-c g") #'emacsos-assist-web-git-refresh)
    map))

(define-minor-mode emacsos-assist-web-git-thread-mode
  "Provide Git keys only in a validated canonical Assist thread buffer."
  :init-value nil :lighter nil :keymap emacsos-assist-web-git-thread-mode-map)

(defun emacsos-assist-web-git--sync-keys ()
  "Install Git keys only while this buffer has a canonical thread identity."
  (when (derived-mode-p 'emacsos-assist-web-mode)
    (let ((canonical
           (emacsos-assist-web--valid-id-p emacsos-assist-web--thread-id)))
      (unless (eq (not (null canonical))
                  (not (null emacsos-assist-web-git-thread-mode)))
        (emacsos-assist-web-git-thread-mode (if canonical 1 -1)))
      (setq-local header-line-format
                  (when canonical
                    '(:eval (emacsos-assist-web-git--thread-header)))))))

(defun emacsos-assist-web-git--id ()
  "Return a fresh, path-safe generation identifier."
  (substring (secure-hash 'sha256
                          (format "%s:%s:%s:%s"
                                  (float-time) (emacs-pid)
                                  (random most-positive-fixnum)
                                  (cl-incf emacsos-assist-web-git--intent-serial)))
             0 32))

(defun emacsos-assist-web-git--same-identity (left right)
  "Return non-nil when LEFT and RIGHT select one authenticated commit."
  (and left right
       (equal (plist-get left :tid) (plist-get right :tid))
       (equal (plist-get left :repo-key) (plist-get right :repo-key))
       (equal (plist-get left :branch) (plist-get right :branch))
       (equal (plist-get left :expected) (plist-get right :expected))))

(defun emacsos-assist-web-git--request-key (metadata)
  "Return METADATA fields that define one fetch and freshness class."
  (and metadata
       (list (plist-get metadata :tid)
             (plist-get metadata :repo-key)
             (plist-get metadata :branch)
             (plist-get metadata :expected)
             (plist-get metadata :status)
             (and (equal (plist-get metadata :status) "ready")
                  (plist-get metadata :actual-branch))
             (and (equal (plist-get metadata :status) "ready")
                  (plist-get metadata :head)))))

(defun emacsos-assist-web-git--usable (metadata)
  "Return whether METADATA names a non-main canonical Git branch."
  (and metadata
       (plist-get metadata :repo-key)
       (plist-get metadata :branch)
       (not (equal (plist-get metadata :branch) "main"))
       (plist-get metadata :expected)))

(defun emacsos-assist-web-git--short (oid)
  "Return a compact OID label."
  (if (stringp oid) (substring oid 0 (min 8 (length oid))) "--------"))

(defun emacsos-assist-web-git--view-state (generation thread)
  "Return live state for GENERATION as seen from THREAD."
  (if (not (buffer-live-p thread))
      "stale"
    (with-current-buffer thread
      (let ((latest emacsos-assist-web-git--metadata))
        (cond
         ((not (emacsos-assist-web-git--same-identity
                latest (emacsos-assist-web-git-generation-metadata generation)))
          "stale")
         ((not (eq generation emacsos-assist-web-git--current)) "stale")
         ((not (equal (emacsos-assist-web-git--request-key latest)
                      (emacsos-assist-web-git--request-key
                       (emacsos-assist-web-git-generation-metadata generation))))
          "cached / remote update pending")
         ((eq (emacsos-assist-web-git-generation-state generation) 'current)
          "current")
         ((eq (emacsos-assist-web-git-generation-state generation) 'busy)
          "fetched remote, unverified against server HEAD; may change")
         (t "cached / remote update pending"))))))

(defun emacsos-assist-web-git--view-header ()
  "Build the compact, live header for a pinned file or Magit buffer."
  (let* ((generation emacsos-assist-web-git--view-generation)
         (thread emacsos-assist-web-git--view-thread)
         (state (emacsos-assist-web-git--view-state generation thread))
         (old (and (buffer-live-p thread)
                   (with-current-buffer thread
                     (eq generation emacsos-assist-web-git--previous))))
         (action (if old " [Close old]" " [Back]"))
         (command (if old #'emacsos-assist-web-git-close-old-view
                    #'emacsos-assist-web-git-back)))
    (concat
     (format "Git %s %s" (emacsos-assist-web-git--short
                          (emacsos-assist-web-git-generation-oid generation))
             state)
     (propertize action 'mouse-face 'highlight
                 'local-map (let ((map (make-sparse-keymap)))
                              (define-key map [header-line mouse-1] command)
                              map)))))

(defun emacsos-assist-web-git--chooser-header ()
  "Show the selected SHA and latest freshness while choosing a mirror file."
  (format "Git %s %s"
          (emacsos-assist-web-git--short
           (emacsos-assist-web-git-generation-oid
            emacsos-assist-web-git--chooser-generation))
          (emacsos-assist-web-git--view-state
           emacsos-assist-web-git--chooser-generation
           emacsos-assist-web-git--chooser-thread)))

(defun emacsos-assist-web-git--thread-header ()
  "Return a compact, actionable mirror state for the thread header."
  (let* ((generation emacsos-assist-web-git--current)
         (state (cond
                 ((not (emacsos-assist-web-git--usable
                        emacsos-assist-web-git--metadata))
                  (or emacsos-assist-web-git--unavailable "unavailable"))
                 (emacsos-assist-web-git--request "fetching")
                 ((and generation
                       (not (emacsos-assist-web-git--same-identity
                             emacsos-assist-web-git--metadata
                             (emacsos-assist-web-git-generation-metadata
                              generation))))
                  "remote pending")
                 (generation
                  (emacsos-assist-web-git--view-state
                   generation (current-buffer)))
                 (t (or emacsos-assist-web-git--unavailable "remote pending")))))
    (concat
     (format "Git %s %s" (if generation
                            (emacsos-assist-web-git--short
                             (emacsos-assist-web-git-generation-oid generation))
                          "--------")
             state)
     (propertize " [Refresh]" 'mouse-face 'highlight
                 'local-map (let ((map (make-sparse-keymap)))
                              (define-key map [header-line mouse-1]
                                #'emacsos-assist-web-git-refresh)
                              map)))))

(defun emacsos-assist-web-git--update-headers ()
  "Refresh state labels in this thread and every pinned mirror view."
  (force-mode-line-update t)
  (dolist (generation (list emacsos-assist-web-git--current
                            emacsos-assist-web-git--previous))
    (when generation
      (setf (emacsos-assist-web-git-generation-views generation)
            (cl-remove-if-not #'buffer-live-p
                              (emacsos-assist-web-git-generation-views generation)))
      (dolist (view (emacsos-assist-web-git-generation-views generation))
        (with-current-buffer view (force-mode-line-update t))))))

(defun emacsos-assist-web-git--parse-helper-result (output)
  "Return a safe result from bounded helper OUTPUT."
  (let ((result (condition-case nil
                    (json-parse-string output :object-type 'plist
                                       :false-object nil :null-object nil)
                  (error nil))))
    (if (eq (plist-get result :ok) t)
        result
      (list :ok nil :reason
            (or (plist-get result :reason)
                "Git mirror operation failed")))))

(defun emacsos-assist-web-git--spawn (request callback)
  "Run helper REQUEST asynchronously and call CALLBACK with its bounded result."
  (let* ((output "")
         (finished nil)
         (process
          (make-process
           :name "assist-thread-git" :buffer nil :noquery t
           :connection-type 'pipe
           :command (list "setsid" "timeout" "--kill-after=2" "90"
                          "python3" emacsos-assist-web-git-helper)
           :filter (lambda (process chunk)
                     (if (> (+ (length output) (length chunk)) 4096)
                         (progn
                           (process-put process :oversize t)
                           (emacsos-assist-web-git--terminate process))
                       (setq output (concat output chunk))))
           :sentinel
           (lambda (process _event)
             (when (and (not finished) (memq (process-status process) '(exit signal)))
               (setq finished t)
               (funcall callback
                        (if (and (= (process-exit-status process) 0)
                                 (not (process-get process :oversize))
                                 (<= (length output) 4096))
                            (emacsos-assist-web-git--parse-helper-result output)
                          (list :ok nil :reason
                                "Git mirror operation failed"))))))))
    (process-send-string process (json-encode request))
    (process-send-eof process)
    process))

(defun emacsos-assist-web-git--terminate (process)
  "Terminate PROCESS and its Git/SSH process group."
  (when (process-live-p process)
    (condition-case nil
        (signal-process (- (process-id process)) 'SIGTERM)
      (error (delete-process process)))))

(defun emacsos-assist-web-git--cleanup (generation kind callback)
  "Delete one private GENERATION of KIND off-loop, then call CALLBACK."
  (emacsos-assist-web-git--spawn
   `((action . "cleanup")
     (cache_root . ,emacsos-assist-web-git-cache-directory)
     (generation . ,generation)
     (kind . ,kind))
   (lambda (result)
     (funcall callback (plist-get result :ok)))))

(defun emacsos-assist-web-git--cancel ()
  "Cancel this buffer's active request and clean its staging generation."
  (when-let ((request emacsos-assist-web-git--request))
    (setq emacsos-assist-web-git--request nil
          emacsos-assist-web-git--canceling (plist-get request :id))
    (let ((process (plist-get request :process))
          (thread (current-buffer)))
      (if (process-live-p process)
          (progn
            (process-put process :cancelled t)
            (emacsos-assist-web-git--terminate process))
        (emacsos-assist-web-git--cleanup
         (plist-get request :id) "staging"
         (lambda (ok)
           (when (buffer-live-p thread)
             (with-current-buffer thread
               (when (equal emacsos-assist-web-git--canceling
                            (plist-get request :id))
                 (setq emacsos-assist-web-git--canceling nil)
                 (if ok
                     (emacsos-assist-web-git--run-next)
                   (setq emacsos-assist-web-git--next nil
                         emacsos-assist-web-git--unavailable
                         "mirror cleanup failed; restart Emacs before retry")))))))))))

(defun emacsos-assist-web-git--run-next ()
  "Start a queued successor only after the prior stage has been cleaned."
  (when-let ((next (and (not emacsos-assist-web-git--canceling)
                       emacsos-assist-web-git--next)))
    (setq emacsos-assist-web-git--next nil)
    (apply #'emacsos-assist-web-git--begin next)))

(defun emacsos-assist-web-git--note (metadata &optional terminal)
  "Accept validated METADATA and refresh after a TERMINAL turn."
  (let ((changed (not (equal (emacsos-assist-web-git--request-key metadata)
                             (emacsos-assist-web-git--request-key
                              emacsos-assist-web-git--metadata)))))
    (setq emacsos-assist-web-git--metadata metadata)
    (when changed
      (setq emacsos-assist-web-git--unavailable nil)
      (cl-incf emacsos-assist-web-git--epoch))
    (when (and emacsos-assist-web-git--request
               (not (equal (emacsos-assist-web-git--request-key metadata)
                           (emacsos-assist-web-git--request-key
                            (plist-get emacsos-assist-web-git--request
                                       :metadata)))))
      (emacsos-assist-web-git--cancel)))
  (emacsos-assist-web-git--update-headers)
  (when (and terminal (emacsos-assist-web-git--usable metadata))
    (emacsos-assist-web-git--enqueue metadata nil)))

(defun emacsos-assist-web-git--invalidate (reason)
  "Make Git freshness unavailable for REASON without changing chat state."
  (setq emacsos-assist-web-git--metadata nil
        emacsos-assist-web-git--unavailable reason
        emacsos-assist-web-git--next nil)
  (cl-incf emacsos-assist-web-git--epoch)
  (condition-case nil (emacsos-assist-web-git--cancel) (error nil))
  (condition-case nil (emacsos-assist-web-git--update-headers) (error nil)))

(defun emacsos-assist-web-git--problem-text (problem)
  "Return the safe display text from PROBLEM."
  (if (consp problem) (cdr problem) problem))

(defun emacsos-assist-web-git--read-metadata (thread callback)
  "Read THREAD's authenticated canonical metadata and call CALLBACK."
  (with-current-buffer thread
    (let ((tid (emacsos-assist-web--require-id emacsos-assist-web--thread-id)))
      (emacsos-assist-web--request
       "GET" (concat "threads/" tid) nil
       (lambda (value problem)
         (when (buffer-live-p thread)
           (with-current-buffer thread
             (if problem
                 (funcall callback nil problem)
               (let ((result
                      (condition-case error
                          (progn
                            (emacsos-assist-web--require-snapshot value tid)
                            (emacsos-assist-web--snapshot-active-p value)
                            (cons 'valid
                                  (emacsos-assist-web-git--metadata-from-snapshot
                                   value)))
                        (error (cons 'invalid (error-message-string error))))))
                 (if (eq (car result) 'valid)
                     (funcall callback (cdr result) nil)
                   (funcall callback nil result)))))))))))

(defun emacsos-assist-web-git--intent-live-p (intent)
  "Return non-nil while INTENT still owns its original thread window."
  (let ((buffer (plist-get intent :buffer))
        (window (plist-get intent :window)))
    (and (buffer-live-p buffer) (window-live-p window)
         (eq (window-buffer window) buffer)
         (eql (window-parameter window 'assist-web-git-intent)
              (plist-get intent :serial)))))

(defun emacsos-assist-web-git--enqueue (metadata intent)
  "Join or start one METADATA refresh, retaining optional UI INTENT."
  (let ((request emacsos-assist-web-git--request))
    (cond
     ((not (emacsos-assist-web-git--usable metadata))
      (setq emacsos-assist-web-git--unavailable
            "no repository, detached HEAD, or main checkout")
      (emacsos-assist-web-git--update-headers)
      (when intent (message "Thread Git is unavailable: %s"
                            emacsos-assist-web-git--unavailable)))
     ((and request
           (equal (emacsos-assist-web-git--request-key
                   (plist-get request :metadata))
                  (emacsos-assist-web-git--request-key metadata)))
      (when intent
        (setf (plist-get request :intents)
              (append (plist-get request :intents) (list intent)))))
     (emacsos-assist-web-git--canceling
      (setq emacsos-assist-web-git--next
            (list metadata (append (cadr emacsos-assist-web-git--next)
                                   (and intent (list intent))))))
     (request
      (setq emacsos-assist-web-git--next
            (list metadata (and intent (list intent))))
      (emacsos-assist-web-git--cancel))
     (t (emacsos-assist-web-git--begin metadata
                                      (and intent (list intent)))))))

(defun emacsos-assist-web-git--begin (metadata intents)
  "Begin one exact METADATA fetch with accumulated INTENTS."
  (let* ((thread (current-buffer))
         (id (emacsos-assist-web-git--id))
         (epoch emacsos-assist-web-git--epoch)
         (request (list :id id :epoch epoch :metadata metadata
                        :intents intents)))
    (setq emacsos-assist-web-git--request request
          emacsos-assist-web-git--unavailable nil)
    (emacsos-assist-web-git--update-headers)
    (condition-case error
        (let ((process
               (emacsos-assist-web-git--spawn
                `((action . "refresh")
                  (cache_root . ,emacsos-assist-web-git-cache-directory)
                  (generation . ,id)
                  (repo_key . ,(plist-get metadata :repo-key))
                  (branch . ,(plist-get metadata :branch))
                  (expected_oid . ,(plist-get metadata :expected)))
                (lambda (result)
                  (if (not (buffer-live-p thread))
                      (emacsos-assist-web-git--cleanup id "staging" #'ignore)
                    (with-current-buffer thread
                      (cond
                       ((or (not (eq request emacsos-assist-web-git--request))
                            (/= epoch emacsos-assist-web-git--epoch))
                        (emacsos-assist-web-git--cleanup
                         id "staging"
                         (lambda (ok)
                           (when (buffer-live-p thread)
                             (with-current-buffer thread
                               (when (equal emacsos-assist-web-git--canceling id)
                                 (setq emacsos-assist-web-git--canceling nil)
                                 (if ok
                                     (emacsos-assist-web-git--run-next)
                                   (setq emacsos-assist-web-git--next nil
                                         emacsos-assist-web-git--unavailable
                                         "mirror cleanup failed; restart Emacs before retry"))))))))
                       ((plist-get result :ok)
                        (emacsos-assist-web-git--final-check request result))
                       (t
                        (emacsos-assist-web-git--cleanup
                         id "staging"
                         (lambda (_ok)
                           (when (buffer-live-p thread)
                             (with-current-buffer thread
                               (emacsos-assist-web-git--failed
                                request (plist-get result :reason)))))))))))))))
          (setf (plist-get request :process) process))
      (error
       (emacsos-assist-web-git--failed
        request (error-message-string error)))))

(defun emacsos-assist-web-git--failed (request reason)
  "Preserve the last good view after REQUEST fails with safe REASON."
  (when (eq request emacsos-assist-web-git--request)
    (setq emacsos-assist-web-git--request nil
          emacsos-assist-web-git--unavailable reason)
    (when (and emacsos-assist-web-git--current
               (emacsos-assist-web-git--same-identity
                emacsos-assist-web-git--metadata
                (emacsos-assist-web-git-generation-metadata
                 emacsos-assist-web-git--current)))
      (setf (emacsos-assist-web-git-generation-state
             emacsos-assist-web-git--current) 'cached))
    (emacsos-assist-web-git--update-headers)
    (dolist (intent (plist-get request :intents))
      (when (emacsos-assist-web-git--intent-live-p intent)
        (if (and (equal reason "Git operation timed out")
                 (eq (plist-get intent :action) 'files)
                 emacsos-assist-web-git--current
                 (emacsos-assist-web-git--same-identity
                  emacsos-assist-web-git--metadata
                  (emacsos-assist-web-git-generation-metadata
                   emacsos-assist-web-git--current)))
            (emacsos-assist-web-git--open
             intent emacsos-assist-web-git--current)
          (message "Thread Git: %s; Refresh to retry" reason))))))

(defun emacsos-assist-web-git--final-check (request result)
  "Reread canonical metadata for REQUEST before promoting RESULT."
  (let ((thread (current-buffer)))
    (emacsos-assist-web-git--read-metadata
     thread
     (lambda (metadata problem)
       (when (buffer-live-p thread)
         (with-current-buffer thread
           (cond
            ((not (eq request emacsos-assist-web-git--request))
             (emacsos-assist-web-git--cleanup
              (plist-get request :id) "staging" #'ignore))
            (problem
             (emacsos-assist-web-git--cleanup
              (plist-get request :id) "staging" #'ignore)
             (emacsos-assist-web-git--failed
              request (emacsos-assist-web-git--problem-text problem)))
            ((not (equal (emacsos-assist-web-git--request-key metadata)
                         (emacsos-assist-web-git--request-key
                          (plist-get request :metadata))))
             (let ((intents (plist-get request :intents)))
               (setq emacsos-assist-web-git--request nil)
               (emacsos-assist-web-git--note metadata)
               (emacsos-assist-web-git--cleanup
                (plist-get request :id) "staging"
                (lambda (ok)
                  (when (and ok (buffer-live-p thread))
                    (with-current-buffer thread
                      (if intents
                          (dolist (intent intents)
                            (emacsos-assist-web-git--enqueue
                             metadata intent))
                        (emacsos-assist-web-git--enqueue metadata nil))))))))
            ((or (/= (plist-get request :epoch)
                     emacsos-assist-web-git--epoch)
                 (not (equal (emacsos-assist-web-git--request-key metadata)
                             (emacsos-assist-web-git--request-key
                              emacsos-assist-web-git--metadata))))
             (emacsos-assist-web-git--cleanup
              (plist-get request :id) "staging" #'ignore))
            ((not (equal (plist-get metadata :expected)
                         (plist-get result :thread_oid)))
             (emacsos-assist-web-git--cleanup
              (plist-get request :id) "staging" #'ignore)
             (emacsos-assist-web-git--failed
              request "remote update pending: branch SHA differs from authenticated published or current revision"))
            (t (emacsos-assist-web-git--promote request result)))))))))

(defun emacsos-assist-web-git--promote (request result)
  "Install REQUEST's validated staged RESULT as an immutable Git generation."
  (let* ((prior emacsos-assist-web-git--previous)
         (thread (current-buffer)))
    (if (and prior
             (cl-some #'buffer-live-p
                      (emacsos-assist-web-git-generation-views prior)))
        (progn
          (emacsos-assist-web-git--cleanup
           (plist-get request :id) "staging" #'ignore)
          (emacsos-assist-web-git--failed
           request "close old view to refresh"))
      (cl-labels
          ((install ()
             (when (and (buffer-live-p thread)
                        (eq request emacsos-assist-web-git--request)
                        (= (plist-get request :epoch)
                           emacsos-assist-web-git--epoch))
               (let* ((id (plist-get request :id))
                      (root emacsos-assist-web-git-cache-directory)
                      (path (expand-file-name (concat "generations/" id) root))
                      (stage (expand-file-name (concat "staging/" id) root))
                      (state (if (equal (plist-get
                                         (plist-get request :metadata) :status)
                                        "ready")
                                 'current 'busy))
                      (generation
                       (make-emacsos-assist-web-git-generation
                        :id id :path path
                        :metadata (plist-get request :metadata)
                        :oid (plist-get result :thread_oid)
                        :main (plist-get result :main_oid)
                        :state state))
                      (installed nil))
                 (condition-case error
                     (progn
                       (with-temp-file (expand-file-name "assist-git-manifest.json"
                                                         stage)
                         (insert (json-encode
                                  `((repo_key . ,(plist-get
                                                  (plist-get request :metadata)
                                                  :repo-key))
                                    (branch . ,(plist-get
                                                (plist-get request :metadata)
                                                :branch))
                                    (snapshot_head . ,(plist-get
                                                       (plist-get request :metadata)
                                                       :head))
                                    (thread_oid . ,(plist-get result :thread_oid))
                                    (main_oid . ,(plist-get result :main_oid))
                                    (freshness . ,(symbol-name state))))))
                       (rename-file stage path)
                       (setq emacsos-assist-web-git--previous
                             emacsos-assist-web-git--current
                             emacsos-assist-web-git--current generation
                             emacsos-assist-web-git--request nil
                             installed t))
                   (error
                    (emacsos-assist-web-git--cleanup id "staging" #'ignore)
                    (emacsos-assist-web-git--failed
                     request (error-message-string error))))
                 (when installed
                   (condition-case nil
                       (emacsos-assist-web-git--update-headers)
                     (error nil))
                   (dolist (intent (plist-get request :intents))
                     (when (emacsos-assist-web-git--intent-live-p intent)
                       (condition-case error
                           (emacsos-assist-web-git--open intent generation)
                         (error
                          (message "Thread Git view unavailable: %s"
                                   (error-message-string error)))))))))))
        (if prior
            (emacsos-assist-web-git--cleanup
             (emacsos-assist-web-git-generation-id prior) "generations"
             (lambda (ok)
               (when (buffer-live-p thread)
                 (with-current-buffer thread
                   (if ok
                       (progn (setq emacsos-assist-web-git--previous nil)
                              (install))
                     (emacsos-assist-web-git--failed
                      request "old mirror generation could not be removed"))))))
          (install))))))

(defun emacsos-assist-web-git--command (action)
  "Request a current snapshot, then perform ACTION in the originating window."
  (unless (and emacsos-assist-web-git-thread-mode
               emacsos-assist-web--thread-id)
    (user-error "Git views require a canonical Assist thread"))
  (let* ((thread (current-buffer))
         (window (selected-window))
         (serial (1+ (or (window-parameter window 'assist-web-git-intent) 0)))
         (intent (list :action action :buffer thread :window window
                       :serial serial)))
    (set-window-parameter window 'assist-web-git-intent serial)
    (message "Refreshing thread Git…")
    (emacsos-assist-web-git--read-metadata
     thread
     (lambda (metadata problem)
       (when (buffer-live-p thread)
         (with-current-buffer thread
           (if problem
               (progn
                 (if (consp problem)
                     (emacsos-assist-web-git--invalidate
                      "invalid authenticated Git metadata")
                   (when emacsos-assist-web-git--current
                     (setf (emacsos-assist-web-git-generation-state
                            emacsos-assist-web-git--current) 'cached))
                   (setq emacsos-assist-web-git--unavailable
                         "metadata refresh failed; cached")
                   (emacsos-assist-web-git--update-headers))
                 (message "Thread Git metadata unavailable: %s"
                          (emacsos-assist-web-git--problem-text problem)))
             (emacsos-assist-web-git--note metadata)
             (emacsos-assist-web-git--enqueue metadata intent))))))))

(defun emacsos-assist-web-git-find-file ()
  "Browse committed files from this canonical Assist thread's Git branch."
  (interactive)
  (emacsos-assist-web-git--command 'files))

(defun emacsos-assist-web-git-diff ()
  "Open a view-only Magit diff against fetched remote main."
  (interactive)
  (emacsos-assist-web-git--command 'diff))

(defun emacsos-assist-web-git-refresh ()
  "Explicitly retry the thread Git fetch and update its visible state."
  (interactive)
  (when emacsos-assist-web-git--request
    (setq emacsos-assist-web-git--next nil)
    (emacsos-assist-web-git--cancel))
  (emacsos-assist-web-git--command 'refresh))

(defun emacsos-assist-web-git--literal-file-view (file root thread generation)
  "Return a read-only FILE from ROOT for THREAD and GENERATION.
Do not interpret repository-local code."
  (let ((resolved (file-truename file))
        (cursor (expand-file-name file))
        (base (expand-file-name root))
        (symlink nil))
    (while (and (not symlink)
                (not (equal cursor base))
                (file-in-directory-p cursor base))
      (setq symlink (file-symlink-p cursor)
            cursor (directory-file-name (file-name-directory cursor))))
    (unless (and (file-regular-p resolved)
                 (not symlink)
                 (not (file-symlink-p base))
                 (file-in-directory-p resolved (file-truename root))
                 (not (file-in-directory-p
                       resolved (file-truename (expand-file-name ".git" root))))
                 (<= (file-attribute-size (file-attributes resolved))
                     emacsos-assist-web-git--file-view-limit))
      (error "Git worktree file is outside the display limit")))
  (let* ((relative (file-relative-name file root))
         (view (generate-new-buffer
                (format "*Git %s %s*"
                        (emacsos-assist-web-git--short
                         (emacsos-assist-web-git-generation-oid generation))
                        relative))))
    (condition-case error
        (with-current-buffer view
          (setq default-directory (file-name-as-directory root))
          (insert-file-contents-literally file)
          (setq buffer-read-only t)
          (emacsos-assist-web-git--pin view thread generation)
          (use-local-map (make-composed-keymap
                          emacsos-assist-web-git-view-map
                          (current-local-map)))
          view)
      (error
       (kill-buffer view)
       (signal (car error) (cdr error))))))

(defun emacsos-assist-web-git--open (intent generation)
  "Complete INTENT against pinned GENERATION in its originating window."
  (let* ((window (plist-get intent :window))
         (thread (plist-get intent :buffer))
         (root (emacsos-assist-web-git-generation-path generation))
         (default-directory (file-name-as-directory root)))
    (when (emacsos-assist-web-git--intent-live-p intent)
      (pcase (plist-get intent :action)
        ('files
         (let* ((prompt (format "Git %s %s file: "
                                (emacsos-assist-web-git--short
                                 (emacsos-assist-web-git-generation-oid generation))
                                (emacsos-assist-web-git--view-state
                                 generation thread)))
                (choice
                 (let ((minibuffer-setup-hook
                        (cons (lambda ()
                                (setq-local
                                 emacsos-assist-web-git--chooser-thread thread
                                 emacsos-assist-web-git--chooser-generation
                                 generation
                                 header-line-format
                                 '(:eval (emacsos-assist-web-git--chooser-header))))
                              minibuffer-setup-hook)))
                   (read-file-name prompt default-directory nil t))))
           (when (emacsos-assist-web-git--intent-live-p intent)
             (let ((view (emacsos-assist-web-git--literal-file-view
                          choice root thread generation)))
               (set-window-buffer window view)))))
        ('diff
         (if (not (require 'magit nil t))
             (message "Magit is not installed on this phone")
           (with-selected-window window
             (let ((default-directory (file-name-as-directory root)))
               (magit-diff-range "main...HEAD")
               (delete-other-windows window)
               (let ((view (window-buffer window)))
                 (with-current-buffer view
                   (setq-local overriding-local-map
                               emacsos-assist-web-git-magit-map)
                   (emacsos-assist-web-git--pin view thread generation))
                 (message "Diff: fetched remote main %s...thread %s"
                          (emacsos-assist-web-git--short
                           (emacsos-assist-web-git-generation-main generation))
                          (emacsos-assist-web-git--short
                           (emacsos-assist-web-git-generation-oid generation))))))))
        ('refresh (message "Thread Git refreshed at %s"
                           (emacsos-assist-web-git-generation-oid generation)))))))

(defun emacsos-assist-web-git--pin (view thread generation)
  "Pin VIEW to immutable GENERATION and THREAD until VIEW is closed."
  (with-current-buffer view
    (setq-local emacsos-assist-web-git--view-thread thread
                emacsos-assist-web-git--view-generation generation
                header-line-format '(:eval (emacsos-assist-web-git--view-header)))
    (add-hook 'kill-buffer-hook #'emacsos-assist-web-git--view-killed nil t))
  (cl-pushnew view (emacsos-assist-web-git-generation-views generation)))

(defun emacsos-assist-web-git--view-killed ()
  "Release this view's generation pin."
  (when emacsos-assist-web-git--view-generation
    (setf (emacsos-assist-web-git-generation-views
           emacsos-assist-web-git--view-generation)
          (delq (current-buffer)
                (emacsos-assist-web-git-generation-views
                 emacsos-assist-web-git--view-generation)))))

(defun emacsos-assist-web-git-back ()
  "Return from a mirror file or Magit diff to its originating thread."
  (interactive)
  (let ((thread emacsos-assist-web-git--view-thread))
    (if (buffer-live-p thread)
        (switch-to-buffer thread)
      (message "The originating Assist thread is closed"))))

(defun emacsos-assist-web-git-close-old-view ()
  "Close a pinned older view so a pending refresh can be retried."
  (interactive)
  (if (not (and (buffer-live-p emacsos-assist-web-git--view-thread)
                (with-current-buffer emacsos-assist-web-git--view-thread
                  (eq emacsos-assist-web-git--view-generation
                      emacsos-assist-web-git--previous))))
      (message "This is not an older pinned Git view")
    (let ((thread emacsos-assist-web-git--view-thread)
          (view (current-buffer)))
      (switch-to-buffer thread)
      (kill-buffer view)
      (with-current-buffer thread
        (emacsos-assist-web-git-refresh)))))

(defun emacsos-assist-web-git-show-sha ()
  "Display full pinned branch and fetched-main Git object IDs."
  (interactive)
  (let ((generation emacsos-assist-web-git--view-generation))
    (if generation
        (message "thread %s; fetched remote main %s"
                 (emacsos-assist-web-git-generation-oid generation)
                 (emacsos-assist-web-git-generation-main generation))
      (message "No pinned Git generation"))))

(defun emacsos-assist-web-git--deny-mutation ()
  "Refuse commands outside the view-only Magit navigation surface."
  (interactive)
  (message "This Git mirror is view only"))

(defun emacsos-assist-web-git--teardown ()
  "Cancel this thread buffer's fetch without affecting pinned views."
  (setq emacsos-assist-web-git--next nil)
  (emacsos-assist-web-git--cancel))

(provide 'assist-web-git)
;;; assist-web-git.el ends here
