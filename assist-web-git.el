;;; assist-web-git.el --- Committed Assist thread Git views -*- lexical-binding: t -*-

;;; Commentary:
;; This module presents fetched thread Git generations.  File views read
;; bounded local worktree paths, not verified committed blobs.

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
  id path metadata oid main state views auth-epoch)

(defvar-local emacsos-assist-web-git--metadata nil)
(defvar-local emacsos-assist-web-git--current nil)
(defvar-local emacsos-assist-web-git--previous nil)
(defvar-local emacsos-assist-web-git--request nil)
(defvar-local emacsos-assist-web-git--next nil)
(defvar-local emacsos-assist-web-git--canceling nil)
(defvar-local emacsos-assist-web-git--epoch 0)
(defvar-local emacsos-assist-web-git--success-watermark 0
  "Count of exact successful Run IDs durably retired by queue-owned R2.")
(defvar-local emacsos-assist-web-git--observation 0
  "Serial of the newest diagnostic Git metadata probe.")
(defvar-local emacsos-assist-web-git--deferred-probes nil)
(defvar-local emacsos-assist-web-git--active-probes nil
  "Live window intents awaiting their own metadata GET callback.")
(defvar-local emacsos-assist-web-git--latest-probe-result nil)
(defvar-local emacsos-assist-web-git--pending nil
  "One unresolved canonical reconciliation after a conflicting probe.")
(defvar-local emacsos-assist-web-git--r2-waiting nil
  "A later diagnostic conflict awaiting this queue R2 and then a new R3.")
(defvar-local emacsos-assist-web-git--auth-epoch 0)
(defvar-local emacsos-assist-web-git--denied nil)
(defvar-local emacsos-assist-web-git--intent-serial 0)
(defvar-local emacsos-assist-web-git--unavailable nil)
(defvar-local emacsos-assist-web-git--feedback-windows nil)
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
    (define-key map (kbd "C-c ?") #'emacsos-assist-web-git-display-details)
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
             (if (equal (plist-get metadata :status) "ready")
                 'ready 'nonready)
             (and (equal (plist-get metadata :status) "ready")
                  (plist-get metadata :actual-branch))
             (and (equal (plist-get metadata :status) "ready")
                  (plist-get metadata :head)))))

(defun emacsos-assist-web-git--request-put (request key value)
  "Set KEY to VALUE on mutable REQUEST without replacing its identity."
  (if (plist-member request key)
      (setf (plist-get request key) value)
    (nconc request (list key value)))
  request)

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
         (emacsos-assist-web-git--denied "unavailable; reauthorize and Retry")
         ((bound-and-true-p emacsos-assist-web--manual-recovery-required)
          "cached / Run recovery pending")
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
         (paused (bound-and-true-p emacsos-assist-web--reconcile-recovery-paused))
         (manual (bound-and-true-p emacsos-assist-web--manual-recovery-required))
         (display-failed (bound-and-true-p emacsos-assist-web--display-recovery))
         (state (cond
                 (emacsos-assist-web-git--denied
                  (or emacsos-assist-web-git--unavailable "unavailable"))
                 (paused "recovery paused; restart")
                 (emacsos-assist-web-git--pending "pending; Retry")
                 ((not (emacsos-assist-web-git--usable
                        emacsos-assist-web-git--metadata))
                  (or emacsos-assist-web-git--unavailable "unavailable"))
                 (emacsos-assist-web-git--request "fetching")
                 ((and emacsos-assist-web-git--unavailable
                       (string-prefix-p "metadata unavailable"
                                        emacsos-assist-web-git--unavailable))
                  emacsos-assist-web-git--unavailable)
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
    (cond
     (paused
      (emacsos-assist-web-git--status-action "Restart to recover"))
     (emacsos-assist-web-git--denied
      (emacsos-assist-web-git--status-action
       (if (string-match-p "404" (or emacsos-assist-web-git--unavailable ""))
           "Thread unavailable" "Reauthorize")))
     (manual
      (propertize "Run recovery pending; Refresh"
                  'mouse-face 'highlight
                  'local-map (let ((map (make-sparse-keymap)))
                               (define-key map [header-line mouse-1]
                                 #'emacsos-assist-web-refresh-thread)
                               map)))
     ((and display-failed (not paused))
        (concat
         (propertize "Saved; Refresh" 'mouse-face 'highlight
                     'local-map (let ((map (make-sparse-keymap)))
                                  (define-key map [header-line mouse-1]
                                    #'emacsos-assist-web-refresh-thread)
                                  map))
         (propertize " [Details]" 'mouse-face 'highlight
                     'local-map (let ((map (make-sparse-keymap)))
                                  (define-key map [header-line mouse-1]
                                    #'emacsos-assist-web-git-display-details)
                                  map))))
     (t
      (concat
       (format "Git %s %s" (if generation
                              (emacsos-assist-web-git--short
                               (emacsos-assist-web-git-generation-oid generation))
                            "--------")
               state)
       (if paused ""
         (propertize " [Refresh]" 'mouse-face 'highlight
                     'local-map (let ((map (make-sparse-keymap)))
                                  (define-key map [header-line mouse-1]
                                    #'emacsos-assist-web-git-refresh)
                                  map))))))))

(defvar-local emacsos-assist-web-git--display-details-thread nil)

(defun emacsos-assist-web-git-display-details ()
  "Explain a committed canonical history whose display failed."
  (interactive)
  (unless (bound-and-true-p emacsos-assist-web--display-recovery)
    (user-error "No canonical display recovery is pending"))
  (let ((thread (current-buffer))
        (view (generate-new-buffer " *Assist Web saved history*")))
    (with-current-buffer view
      (insert "Canonical history and Run retirement were saved.\n\n"
              "The phone could not display the result. Refresh retries "
              "presentation; it does not resend or reobserve the retired Run.\n\n"
              "Press q to return, then Refresh.\n")
      (special-mode)
      (visual-line-mode 1)
      (setq-local emacsos-assist-web-git--display-details-thread thread)
      (local-set-key (kbd "q") #'emacsos-assist-web-git-display-details-back))
    (switch-to-buffer view)))

(defun emacsos-assist-web-git-display-details-back ()
  "Return from a Git or saved-history explanation to its thread."
  (interactive)
  (let ((thread emacsos-assist-web-git--display-details-thread)
        (view (current-buffer)))
    (when (buffer-live-p thread)
      (switch-to-buffer thread))
    (kill-buffer view)))

(defun emacsos-assist-web-git--show-display-recovery ()
  "Expose the independent saved-history header in every thread window."
  (dolist (window (get-buffer-window-list (current-buffer) nil t))
    (emacsos-assist-web-git--clear-feedback window))
  (force-mode-line-update t))

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
  (when-let ((next (and (not emacsos-assist-web-git--pending)
                       (not emacsos-assist-web-git--canceling)
                       emacsos-assist-web-git--next)))
    (setq emacsos-assist-web-git--next nil)
    (apply #'emacsos-assist-web-git--begin next)))

(defun emacsos-assist-web-git--note (metadata &optional terminal)
  "Accept canonical METADATA and refresh after a TERMINAL turn."
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
      (if emacsos-assist-web-git--pending
          (progn
            (emacsos-assist-web-git--request-put
             emacsos-assist-web-git--pending :intents
             (emacsos-assist-web-git--live-intents
              (plist-get emacsos-assist-web-git--pending :intents)
              (plist-get emacsos-assist-web-git--request :intents)
              (cadr emacsos-assist-web-git--next)))
            (setq emacsos-assist-web-git--next nil))
        (setq emacsos-assist-web-git--next
              (list metadata
                    (append (plist-get emacsos-assist-web-git--request :intents)
                            (cadr emacsos-assist-web-git--next)))))
      (emacsos-assist-web-git--cancel)))
  (emacsos-assist-web-git--update-headers)
  (when (and terminal (not emacsos-assist-web-git--pending)
             (emacsos-assist-web-git--usable metadata))
    (emacsos-assist-web-git--enqueue metadata nil)))

(defun emacsos-assist-web-git--live-intents (&rest groups)
  "Return distinct live intents from GROUPS, preserving command order."
  (let (result)
    (dolist (group groups)
      (dolist (intent group)
        (when (and (emacsos-assist-web-git--intent-live-p intent)
                   (not (memq intent result)))
          (push intent result))))
    (nreverse result)))

(defun emacsos-assist-web-git--canonical-start
    (&optional durable queue-owner outcomes)
  "Claim a canonical GET, optionally owned by QUEUE-OWNER and OUTCOMES.
OUTCOMES are exact authenticated Run ID/status pairs verified before R2."
  (let ((pending-token
         (when (and emacsos-assist-web-git--pending
                    (or (not (plist-get emacsos-assist-web-git--pending
                                       :requires-durable))
                        durable))
           (let ((token (cons emacsos-assist-web-git--epoch nil)))
             (emacsos-assist-web-git--request-put
              emacsos-assist-web-git--pending :request token)
             token))))
    (if queue-owner
        (list :queue-owner queue-owner :epoch emacsos-assist-web-git--epoch
              :pending pending-token :outcomes outcomes)
      pending-token)))

(defun emacsos-assist-web-git--canonical-failed (token &optional reason)
  "End the pending reconciliation when TOKEN's GET did not commit.
REASON is the visible retry or restart explanation."
  (let ((pending-token (if (plist-get token :queue-owner)
                           (plist-get token :pending)
                         token)))
  (when (and pending-token emacsos-assist-web-git--pending
             (eq pending-token
                 (plist-get emacsos-assist-web-git--pending :request)))
    (let ((intents (plist-get emacsos-assist-web-git--pending :intents)))
      (setq emacsos-assist-web-git--pending nil
            emacsos-assist-web-git--unavailable
            (or reason "pending; Retry"))
      (emacsos-assist-web-git--release-intents
       intents (or reason "pending; Retry"))
      (emacsos-assist-web-git--update-headers)))))

(defun emacsos-assist-web-git--canonical-accepted
    (metadata terminal token)
  "Apply chat-accepted METADATA, resolving an eligible TOKEN after commit."
  (let* ((queue-owner (plist-get token :queue-owner))
         (pending-token (if queue-owner (plist-get token :pending) token))
         (queue-eligible
          (and queue-owner
               (eql queue-owner emacsos-assist-web--reconcile-generation)
               (not emacsos-assist-web-git--denied)))
         (success-ids
          (and queue-eligible
               (delete-dups
                (mapcar #'car
                        (seq-filter (lambda (cause)
                                      (equal (cdr cause) "success"))
                                    (plist-get token :outcomes))))))
         (pending emacsos-assist-web-git--pending)
         (eligible (and pending pending-token
                        (eq pending-token (plist-get pending :request))
                        (= (car pending-token) emacsos-assist-web-git--epoch)))
         (intents (and eligible (plist-get pending :intents))))
    (when success-ids
      ;; The owner/generation gate admits each R2 once.  Every exact Run ID
      ;; advances the cause watermark; one post-batch fetch can satisfy all.
      (cl-incf emacsos-assist-web-git--success-watermark
                (length success-ids))
      (when emacsos-assist-web-git--current
        (setf (emacsos-assist-web-git-generation-state
               emacsos-assist-web-git--current) 'cached)))
    (emacsos-assist-web-git--note metadata nil)
    (when eligible
      (setq emacsos-assist-web-git--pending nil)
      (if (emacsos-assist-web-git--usable metadata)
          (if intents
              (dolist (intent intents)
                (emacsos-assist-web-git--enqueue metadata intent))
            (emacsos-assist-web-git--enqueue metadata nil))
        (emacsos-assist-web-git--release-intents
         intents "no published thread branch; Retry")))
    (when (and (or terminal success-ids)
               (not emacsos-assist-web-git--r2-waiting)
               (not emacsos-assist-web-git--pending)
               (emacsos-assist-web-git--usable metadata))
      (emacsos-assist-web-git--enqueue metadata nil))))

(defun emacsos-assist-web-git--r2-finished (owner committed)
  "Complete OWNER's later diagnostic intents after its R2 COMMITTED or failed."
  (when (eql owner (plist-get emacsos-assist-web-git--r2-waiting :owner))
    (let ((waiting emacsos-assist-web-git--r2-waiting))
      (setq emacsos-assist-web-git--r2-waiting nil)
      (if committed
          (progn
            (setq emacsos-assist-web-git--pending
                  (list :key (plist-get waiting :key)
                        :epoch emacsos-assist-web-git--epoch
                        :request nil :requires-durable nil
                        :intents (plist-get waiting :intents)))
            ;; R2 began before the diagnostic conflict.  Only this new
            ;; post-barrier canonical GET may resolve its window intents.
            (emacsos-assist-web--legacy-refresh-thread (current-buffer)))
        (emacsos-assist-web-git--release-intents
         (plist-get waiting :intents)
         (cond
          ((bound-and-true-p emacsos-assist-web--reconcile-recovery-paused)
           "local recovery could not be saved; restart to recover")
          ((bound-and-true-p emacsos-assist-web--manual-recovery-required)
           "Run recovery pending; Refresh")
          (t "canonical reconciliation failed; Retry")))))))

(defun emacsos-assist-web-git--conflict-during-r2 (metadata intent)
  "Hold diagnostic METADATA and INTENT for one post-R2 canonical R3."
  (let* ((prior emacsos-assist-web-git--r2-waiting)
         (intents (emacsos-assist-web-git--live-intents
                   (plist-get prior :intents)
                   (plist-get emacsos-assist-web-git--pending :intents)
                   (plist-get emacsos-assist-web-git--request :intents)
                   (cadr emacsos-assist-web-git--next)
                   (and intent (list intent)))))
    (cl-incf emacsos-assist-web-git--epoch)
    (when emacsos-assist-web-git--current
      (setf (emacsos-assist-web-git-generation-state
             emacsos-assist-web-git--current) 'cached))
    (setq emacsos-assist-web-git--r2-waiting
          (list :owner emacsos-assist-web--reconcile-generation
                :key (emacsos-assist-web-git--request-key metadata)
                :intents intents)
          emacsos-assist-web-git--pending nil
          emacsos-assist-web-git--next nil
          emacsos-assist-web-git--unavailable "pending; Retry")
    (when emacsos-assist-web-git--request
      (emacsos-assist-web-git--cancel))
    (emacsos-assist-web-git--update-headers)))

(defun emacsos-assist-web-git--conflict (metadata intent)
  "Hold INTENT at a bounded canonical reconciliation for diagnostic METADATA."
  (if (bound-and-true-p emacsos-assist-web--reconcile-generation)
      (emacsos-assist-web-git--conflict-during-r2 metadata intent)
  (let* ((key (emacsos-assist-web-git--request-key metadata))
         (pending emacsos-assist-web-git--pending)
         (same (and pending
                    (equal key (plist-get pending :key))))
         (intents (emacsos-assist-web-git--live-intents
                   (plist-get pending :intents)
                   (plist-get emacsos-assist-web-git--request :intents)
                   (cadr emacsos-assist-web-git--next)
                   (and intent (list intent)))))
    (if same
        (emacsos-assist-web-git--request-put pending :intents intents)
      (cl-incf emacsos-assist-web-git--epoch)
      (when emacsos-assist-web-git--current
        (setf (emacsos-assist-web-git-generation-state
               emacsos-assist-web-git--current) 'cached))
      (setq emacsos-assist-web-git--pending
            (list :key key :epoch emacsos-assist-web-git--epoch
                  :request nil :intents intents
                  :requires-durable
                  (cl-some (lambda (entry)
                             (eq (emacsos-assist-web--entry-state entry)
                                 'reconciling))
                           emacsos-assist-web--queue))
            emacsos-assist-web-git--next nil
            emacsos-assist-web-git--unavailable "pending; Retry")
      (when emacsos-assist-web-git--request
        (emacsos-assist-web-git--cancel))
      (emacsos-assist-web-git--update-headers)
      (if (plist-get emacsos-assist-web-git--pending :requires-durable)
          (emacsos-assist-web--reconcile-queue)
        (emacsos-assist-web-refresh-thread (current-buffer)))))))

(defun emacsos-assist-web-git--invalidate (reason)
  "Make Git freshness unavailable for REASON without changing chat state."
  (let ((intents (emacsos-assist-web-git--live-intents
                  (plist-get emacsos-assist-web-git--request :intents)
                  (cadr emacsos-assist-web-git--next)
                  (plist-get emacsos-assist-web-git--pending :intents)
                  (plist-get emacsos-assist-web-git--r2-waiting :intents)
                  emacsos-assist-web-git--active-probes
                  (mapcar #'car emacsos-assist-web-git--deferred-probes))))
    (setq emacsos-assist-web-git--metadata nil
          emacsos-assist-web-git--unavailable reason
          emacsos-assist-web-git--next nil
          emacsos-assist-web-git--pending nil
          emacsos-assist-web-git--r2-waiting nil
          emacsos-assist-web-git--active-probes nil
          emacsos-assist-web-git--deferred-probes nil)
    (when emacsos-assist-web-git--current
      (setf (emacsos-assist-web-git-generation-state
             emacsos-assist-web-git--current) 'cached))
    (emacsos-assist-web-git--release-intents intents reason))
  (cl-incf emacsos-assist-web-git--observation)
  (cl-incf emacsos-assist-web-git--epoch)
  (condition-case nil (emacsos-assist-web-git--cancel) (error nil))
  (condition-case nil (emacsos-assist-web-git--update-headers) (error nil)))

(defun emacsos-assist-web-git--release-intents (intents reason &optional quiet)
  "Give each live INTENT a reason-specific window result; message unless QUIET."
  (let (released)
    (dolist (intent intents)
      (when (emacsos-assist-web-git--intent-live-p intent)
        (setq released t)
      (let* ((window (plist-get intent :window))
             (thread (plist-get intent :buffer))
             (restart (string-match-p "restart to recover" reason))
             (missing (string-match-p "thread unavailable (404)" reason))
             (denial (or missing
                         (string-match-p
                          "thread access denied\\|reauthorize" reason)))
             (manual (string-match-p "Run recovery pending" reason))
             (label (cond (restart "Restart to recover")
                          (missing "Thread unavailable")
                          (denial "Reauthorize")
                          (manual "Run recovery pending")
                          ((string-match-p "pending\\|changed" reason)
                           "Git pending")
                          (t "Git unavailable")))
             (retry (if (or restart denial) ""
                      (propertize
                       (if manual " [Refresh]" " [Retry]")
                       'mouse-face 'highlight
                       'local-map
                       (let ((map (make-sparse-keymap)))
                         (define-key map [header-line mouse-1]
                           (if manual #'emacsos-assist-web-refresh-thread
                             #'emacsos-assist-web-git-refresh))
                         map))))
             (details (if (or restart denial)
                          (emacsos-assist-web-git--details-link)
                        ""))
             (header `(:eval (if (eq (current-buffer) ,thread)
                                 ,(concat label retry details)
                               header-line-format))))
        (set-window-parameter window 'assist-web-git-intent
                              (1+ (plist-get intent :serial)))
        (set-window-parameter window 'assist-web-git-feedback header)
        (set-window-parameter window 'header-line-format header)
        (setq emacsos-assist-web-git--feedback-windows
              (assq-delete-all window emacsos-assist-web-git--feedback-windows))
        (push (cons window header) emacsos-assist-web-git--feedback-windows)
        (force-mode-line-update t))))
    (when (and released (not quiet))
      (message "Thread Git: %s" reason))))

(defun emacsos-assist-web-git--details-link ()
  "Return a short clickable explanation affordance."
  (propertize " [?]" 'mouse-face 'highlight
              'local-map
              (let ((map (make-sparse-keymap)))
                (define-key map [header-line mouse-1]
                  #'emacsos-assist-web-git-status-details)
                map)))

(defun emacsos-assist-web-git--status-action (label)
  "Return compact LABEL and a clickable explanation affordance."
  (concat label (emacsos-assist-web-git--details-link)))

(defun emacsos-assist-web-git-status-details ()
  "Explain a Git recovery or access gate without offering an unsafe Retry."
  (interactive)
  (let* ((thread (current-buffer))
         (paused (bound-and-true-p emacsos-assist-web--reconcile-recovery-paused))
         (reason (cond
                  (paused
                   "The local Run reconciliation record could not be saved. Git is paused. Restart Emacs, reopen this thread, then use Refresh to recover the exact Run. Do not retry Git in this session.")
                  ((and emacsos-assist-web-git--denied
                        (string-match-p "404" (or emacsos-assist-web-git--unavailable "")))
                   "This thread is unavailable. Reopen it from the Assist thread list after checking access. Existing Git views are noncurrent; do not use them as the thread's latest state.")
                  (emacsos-assist-web-git--denied
                   "Assist denied access to this thread. Reauthorize Assist, reopen the thread, and then Retry. Existing Git views are noncurrent.")
                  (t "Git state needs a fresh canonical thread check. Refresh before opening another view.")))
         (view (generate-new-buffer " *Assist Web Git status*")))
    (with-current-buffer view
      (insert reason "\n\nPress q to return.\n")
      (special-mode)
      (visual-line-mode 1)
      (setq-local emacsos-assist-web-git--display-details-thread thread)
      (local-set-key (kbd "q") #'emacsos-assist-web-git-display-details-back))
    (switch-to-buffer view)))

(defun emacsos-assist-web-git--clear-feedback (window)
  "Remove only the Git-owned feedback header from WINDOW."
  (let ((header (window-parameter window 'assist-web-git-feedback)))
    (when header
      (when (eq header (window-parameter window 'header-line-format))
        (set-window-parameter window 'header-line-format nil))
      (set-window-parameter window 'assist-web-git-feedback nil)
      (setq emacsos-assist-web-git--feedback-windows
            (assq-delete-all window emacsos-assist-web-git--feedback-windows))
      (force-mode-line-update t))))

(defun emacsos-assist-web-git--canonical-denied (status)
  "Latch canonical HTTP STATUS denial across old Git callbacks and views."
  (cl-incf emacsos-assist-web-git--auth-epoch)
  (setq emacsos-assist-web-git--denied t)
  (when emacsos-assist-web-git--current
    (setf (emacsos-assist-web-git-generation-state
           emacsos-assist-web-git--current) 'cached))
  (let ((reason (if (= status 404)
                    "thread unavailable (404); reopen and Retry"
                  (format "thread access denied (%d); reauthorize and Retry"
                          status))))
    (emacsos-assist-web-git--invalidate reason)
    (message "Thread Git: %s" reason)))

(defun emacsos-assist-web-git--run-access-uncertain (status)
  "Fence Git after exact Run GET receives STATUS before its body is parsed.
A later accepted canonical thread GET distinguishes a missing Run from denial."
  (cl-incf emacsos-assist-web-git--auth-epoch)
  (setq emacsos-assist-web-git--denied 'run)
  (emacsos-assist-web-git--invalidate
   (format "Run status unavailable (%d); Refresh thread" status)))

(defun emacsos-assist-web-git--canonical-uncertain ()
  "Downgrade freshness after a failed chat-owned canonical refresh attempt."
  (unless emacsos-assist-web-git--denied
    (cl-incf emacsos-assist-web-git--epoch)
    (when emacsos-assist-web-git--pending
      (let ((intents (plist-get emacsos-assist-web-git--pending :intents)))
        (setq emacsos-assist-web-git--pending nil)
        (emacsos-assist-web-git--release-intents
         intents "canonical refresh unavailable; pending; Retry")))
    ;; The Git transfer may finish, but any final read begun before this
    ;; failed refresh must be repeated before its staged tree is installed.
    (when emacsos-assist-web-git--request
      (emacsos-assist-web-git--request-put
       emacsos-assist-web-git--request :epoch emacsos-assist-web-git--epoch))
    (when emacsos-assist-web-git--current
      (setf (emacsos-assist-web-git-generation-state
             emacsos-assist-web-git--current) 'cached))
    (setq emacsos-assist-web-git--unavailable
          (if emacsos-assist-web-git--current
              "canonical refresh unavailable; existing views only; Retry"
            "canonical refresh unavailable; no mirror; Retry"))
    (emacsos-assist-web-git--update-headers)))

(defun emacsos-assist-web-git--canonical-authorized (start-epoch)
  "Clear a denial only after chat accepts a GET begun at START-EPOCH."
  (when (and emacsos-assist-web-git--denied
             (eql start-epoch emacsos-assist-web-git--auth-epoch))
    (setq emacsos-assist-web-git--denied nil)
    (emacsos-assist-web-git--update-headers)))

(defun emacsos-assist-web-git--problem-text (problem)
  "Return the safe display text from PROBLEM."
  (cond ((and (listp problem) (plist-get problem :text))
         (plist-get problem :text))
        ((consp problem) (cdr problem))
        (t problem)))

(defun emacsos-assist-web-git--read-metadata (thread callback)
  "Read THREAD's canonical and Git metadata and call CALLBACK.
Canonical snapshot errors and Git-only projection errors retain distinct tags."
  (with-current-buffer thread
    (let ((tid (emacsos-assist-web--require-id emacsos-assist-web--thread-id)))
      (emacsos-assist-web--request
       "GET" (concat "threads/" tid) nil
       (lambda (value problem)
         (when (buffer-live-p thread)
           (with-current-buffer thread
             (if problem
                 (funcall callback nil problem)
               (let ((canonical
                      (condition-case error
                          (progn
                            (emacsos-assist-web--require-snapshot value tid)
                            (emacsos-assist-web--snapshot-active-p value)
                            t)
                        (error (cons 'canonical (error-message-string error))))))
                 (if (consp canonical)
                     (funcall callback nil canonical)
                   (let ((result
                          (condition-case error
                              (cons 'valid
                                    (emacsos-assist-web-git--metadata-from-snapshot
                                     value))
                            (error (cons 'git (error-message-string error))))))
                     (if (eq (car result) 'valid)
                         (funcall callback (cdr result) nil)
                       (funcall callback nil result)))))))))
       nil nil nil nil t))))

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
     ((bound-and-true-p emacsos-assist-web--reconcile-recovery-paused)
      (when intent
        (emacsos-assist-web-git--release-intents
         (list intent)
         "local recovery could not be saved; restart to recover")))
     ((bound-and-true-p emacsos-assist-web--manual-recovery-required)
      (when intent
        (emacsos-assist-web-git--release-intents
         (list intent) "Run recovery pending; Refresh")))
     (emacsos-assist-web-git--pending
      (when intent
        (emacsos-assist-web-git--request-put
         emacsos-assist-web-git--pending :intents
         (emacsos-assist-web-git--live-intents
          (plist-get emacsos-assist-web-git--pending :intents)
          (list intent)))))
     ((not (emacsos-assist-web-git--usable metadata))
      (setq emacsos-assist-web-git--unavailable
            (if (equal (plist-get metadata :actual-branch) "HEAD")
                "detached HEAD; Git unavailable"
              "no repository or published thread branch"))
      (emacsos-assist-web-git--update-headers)
      (when intent
        (emacsos-assist-web-git--release-intents
         (list intent) emacsos-assist-web-git--unavailable)))
     ((and request
           (equal (emacsos-assist-web-git--request-key
                   (plist-get request :metadata))
                  (emacsos-assist-web-git--request-key metadata)))
      (if (< (or (plist-get request :cause-at-start) 0)
             emacsos-assist-web-git--success-watermark)
          (progn
            (setq emacsos-assist-web-git--next
                  (list metadata
                        (emacsos-assist-web-git--live-intents
                         (plist-get request :intents)
                         (and intent (list intent))
                         (cadr emacsos-assist-web-git--next))))
            (emacsos-assist-web-git--cancel))
        (when intent
          (setf (plist-get request :intents)
                (append (plist-get request :intents) (list intent))))))
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
                        :intents intents :process nil
                        :cause-at-start emacsos-assist-web-git--success-watermark
                        :final-attempts 0 :verified-epoch nil)))
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
                            (/= (plist-get request :epoch)
                                emacsos-assist-web-git--epoch))
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
                                request (plist-get result :reason))))))))))))))
          (emacsos-assist-web-git--request-put request :process process))
      (error
       (emacsos-assist-web-git--failed
        request (error-message-string error))))))

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
    (emacsos-assist-web-git--release-intents
     (plist-get request :intents)
     (format "%s; Refresh to retry" reason))))

(defun emacsos-assist-web-git--final-check (request result)
  "Reread canonical metadata for REQUEST before promoting RESULT."
  (let ((thread (current-buffer))
        (start-epoch emacsos-assist-web-git--epoch)
        (start-observation emacsos-assist-web-git--observation))
    (emacsos-assist-web-git--request-put
     request :final-attempts
     (1+ (or (plist-get request :final-attempts) 0)))
    (emacsos-assist-web-git--read-metadata
     thread
     (lambda (metadata problem)
       (when (buffer-live-p thread)
         (with-current-buffer thread
           (cond
            ((not (eq request emacsos-assist-web-git--request))
             (emacsos-assist-web-git--cleanup
              (plist-get request :id) "staging" #'ignore))
            ((/= start-epoch emacsos-assist-web-git--epoch)
             (if (< (plist-get request :final-attempts) 2)
                 (emacsos-assist-web-git--final-check request result)
               (emacsos-assist-web-git--cleanup
                (plist-get request :id) "staging" #'ignore)
               (emacsos-assist-web-git--failed
                request "canonical refresh changed during final verification")))
            (problem
             (emacsos-assist-web-git--cleanup
              (plist-get request :id) "staging" #'ignore)
             (emacsos-assist-web-git--failed
              request (emacsos-assist-web-git--problem-text problem)))
            ((not (equal (emacsos-assist-web-git--request-key metadata)
                         (emacsos-assist-web-git--request-key
                          (plist-get request :metadata))))
             (if (< start-observation emacsos-assist-web-git--observation)
                 (progn
                   ;; A command started after this final read.  Its diagnostic
                   ;; result, not this older mismatch, owns the next barrier.
                   (let ((latest emacsos-assist-web-git--latest-probe-result)
                         (intents (plist-get request :intents)))
                     (emacsos-assist-web-git--cancel)
                     (dolist (intent intents)
                       (if (and latest
                                (= (plist-get latest :serial)
                                   emacsos-assist-web-git--observation))
                           (emacsos-assist-web-git--route-probe
                            intent
                            (if (plist-get latest :problem)
                                emacsos-assist-web-git--metadata
                              (plist-get latest :metadata))
                            nil
                            (if (plist-get latest :problem)
                                emacsos-assist-web-git--epoch
                              (plist-get latest :start-epoch)))
                         (push (list intent emacsos-assist-web-git--metadata
                                     nil start-epoch)
                               emacsos-assist-web-git--deferred-probes)))))
               (emacsos-assist-web-git--conflict metadata nil)))
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
            (t
             (emacsos-assist-web-git--request-put
              request :verified-epoch start-epoch)
             (emacsos-assist-web-git--promote request result)))))))))

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
                        (not emacsos-assist-web-git--pending)
                        (not (bound-and-true-p
                              emacsos-assist-web--manual-recovery-required))
                        (not (bound-and-true-p
                              emacsos-assist-web--reconcile-recovery-paused))
                        (= (plist-get request :epoch)
                           emacsos-assist-web-git--epoch))
               (if (< (or (plist-get request :cause-at-start) 0)
                      emacsos-assist-web-git--success-watermark)
                   ;; A final read begun before an exact successful Run cannot
                   ;; install even if the branch and OID did not change.
                   (emacsos-assist-web-git--enqueue
                    emacsos-assist-web-git--metadata nil)
                 (if (not (eql (plist-get request :verified-epoch)
                               emacsos-assist-web-git--epoch))
                   (if (< (or (plist-get request :final-attempts) 0) 2)
                       (emacsos-assist-web-git--final-check request result)
                     (emacsos-assist-web-git--cleanup
                      (plist-get request :id) "staging" #'ignore)
                     (emacsos-assist-web-git--failed
                      request "canonical refresh changed during install"))
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
                        :state state
                        :auth-epoch emacsos-assist-web-git--auth-epoch))
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
                             emacsos-assist-web-git--unavailable nil
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
                       (emacsos-assist-web-git--clear-feedback
                        (plist-get intent :window))
                       (condition-case error
                           (emacsos-assist-web-git--open intent generation)
                         (error
                          (emacsos-assist-web-git--release-intents
                           (list intent)
                           (format "view unavailable: %s; Retry"
                                   (error-message-string error))))
                         (quit
                         (emacsos-assist-web-git--release-intents
                           (list intent) "view cancelled; Retry"))))))))))))
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

(defun emacsos-assist-web-git--route-probe
    (intent metadata problem start-epoch)
  "Route one diagnostic result without replacing chat-accepted Git state."
  (when (emacsos-assist-web-git--intent-live-p intent)
    (cond
     ((bound-and-true-p emacsos-assist-web--reconcile-recovery-paused)
      (emacsos-assist-web-git--release-intents
       (list intent) "local recovery could not be saved; restart to recover"))
     ((bound-and-true-p emacsos-assist-web--manual-recovery-required)
      (emacsos-assist-web-git--release-intents
       (list intent) "Run recovery pending; Refresh"))
     ((and (listp problem) (eq (plist-get problem :kind) 'http)
           (memq (plist-get problem :status) '(401 403 404)))
      ;; The shared request boundary already reported the specific denial.
      (emacsos-assist-web-git--release-intents
       (list intent) emacsos-assist-web-git--unavailable t))
     (emacsos-assist-web-git--denied
     (emacsos-assist-web-git--release-intents
       (list intent) "thread access unavailable; reauthorize and Retry"))
     ((and (consp problem) (memq (car problem) '(canonical git)))
      ;; A parsed authenticated 200 with invalid canonical/Git fields is not
      ;; an offline probe.  Its old mirror cannot remain marked current.
      (emacsos-assist-web-git--invalidate "Git state unavailable")
      (emacsos-assist-web-git--release-intents
       (list intent) "Git state unavailable; Retry"))
     (problem
      (message "Thread Git metadata unavailable: %s"
               (emacsos-assist-web-git--problem-text problem))
      (emacsos-assist-web-git--release-intents
       (list intent) "metadata unavailable; Retry" t))
     (emacsos-assist-web-git--pending
      (if (and (= start-epoch emacsos-assist-web-git--epoch)
               (not (equal (emacsos-assist-web-git--request-key metadata)
                           (emacsos-assist-web-git--request-key
                            emacsos-assist-web-git--metadata)))
               (not (equal (emacsos-assist-web-git--request-key metadata)
                           (plist-get emacsos-assist-web-git--pending :key))))
          (emacsos-assist-web-git--conflict metadata intent)
        (emacsos-assist-web-git--request-put
         emacsos-assist-web-git--pending :intents
         (emacsos-assist-web-git--live-intents
          (plist-get emacsos-assist-web-git--pending :intents)
          (list intent)))))
     ((/= start-epoch emacsos-assist-web-git--epoch)
      (if emacsos-assist-web-git--metadata
          (emacsos-assist-web-git--enqueue
           emacsos-assist-web-git--metadata intent)
        (emacsos-assist-web-git--release-intents
         (list intent) "thread state changed; Retry")))
     ((not (equal (emacsos-assist-web-git--request-key metadata)
                  (emacsos-assist-web-git--request-key
                   emacsos-assist-web-git--metadata)))
      (emacsos-assist-web-git--conflict metadata intent))
     (t (emacsos-assist-web-git--enqueue
         emacsos-assist-web-git--metadata intent)))))

(defun emacsos-assist-web-git--probe-complete
    (serial intent metadata problem start-epoch)
  "Complete SERIAL's diagnostic probe, retaining independent window INTENT."
  (cond
   ((not (emacsos-assist-web-git--intent-live-p intent)) nil)
   ((< serial emacsos-assist-web-git--observation)
    (let ((latest emacsos-assist-web-git--latest-probe-result))
      (if (and latest
               (= (plist-get latest :serial)
                  emacsos-assist-web-git--observation))
          (if (plist-get latest :problem)
              (emacsos-assist-web-git--route-probe
               intent metadata problem start-epoch)
            (emacsos-assist-web-git--route-probe
             intent (plist-get latest :metadata) nil
             (plist-get latest :start-epoch)))
        (push (list intent metadata problem start-epoch)
              emacsos-assist-web-git--deferred-probes))))
   (t
    (setq emacsos-assist-web-git--latest-probe-result
          (list :serial serial :metadata metadata :problem problem
                :start-epoch start-epoch))
    (emacsos-assist-web-git--route-probe
     intent metadata problem start-epoch)
    (let ((deferred (nreverse emacsos-assist-web-git--deferred-probes)))
      (setq emacsos-assist-web-git--deferred-probes nil)
      (dolist (record deferred)
        (emacsos-assist-web-git--route-probe
         (nth 0 record)
         (if problem (nth 1 record) metadata)
         (and problem (nth 2 record))
         (if problem (nth 3 record) start-epoch)))))))

(defun emacsos-assist-web-git--command (action)
  "Probe metadata, then perform ACTION in its originating thread window."
  (unless (and emacsos-assist-web-git-thread-mode
               emacsos-assist-web--thread-id)
    (user-error "Git views require a canonical Assist thread"))
  (when (bound-and-true-p emacsos-assist-web--reconcile-recovery-paused)
    (user-error "local recovery could not be saved; restart to recover"))
  (when (bound-and-true-p emacsos-assist-web--manual-recovery-required)
    (user-error "Run recovery pending; Refresh"))
  (let* ((thread (current-buffer))
         (window (selected-window))
         (serial (1+ (or (window-parameter window 'assist-web-git-intent) 0)))
         (observation (cl-incf emacsos-assist-web-git--observation))
         (start-epoch emacsos-assist-web-git--epoch)
         (intent (list :action action :buffer thread :window window
                       :serial serial)))
    (emacsos-assist-web-git--clear-feedback window)
    (set-window-parameter window 'assist-web-git-intent serial)
    (push intent emacsos-assist-web-git--active-probes)
    (message "Refreshing thread Git…")
    (emacsos-assist-web-git--read-metadata
     thread
     (lambda (metadata problem)
       (when (buffer-live-p thread)
         (with-current-buffer thread
           (setq emacsos-assist-web-git--active-probes
                 (delq intent emacsos-assist-web-git--active-probes))
           (emacsos-assist-web-git--probe-complete
            observation intent metadata problem start-epoch)))))))

(defun emacsos-assist-web-git-find-file ()
  "Browse bounded worktree files from this thread's fetched Git mirror."
  (interactive)
  (emacsos-assist-web-git--command 'files))

(defun emacsos-assist-web-git-diff ()
  "Open a view-only Magit diff against fetched remote main."
  (interactive)
  (emacsos-assist-web-git--command 'diff))

(defun emacsos-assist-web-git-refresh ()
  "Explicitly retry the thread Git fetch and update its visible state."
  (interactive)
  (when (bound-and-true-p emacsos-assist-web--reconcile-recovery-paused)
    (user-error "local recovery could not be saved; restart to recover"))
  (when (bound-and-true-p emacsos-assist-web--manual-recovery-required)
    (user-error "Run recovery pending; Refresh"))
  (emacsos-assist-web-git--command 'refresh))

(defun emacsos-assist-web-git--literal-file-view (file root thread generation)
  "Return a read-only FILE from ROOT for THREAD and GENERATION.
Read a bounded worktree path, not a verified committed blob.  Do not
interpret repository-local code."
  (let ((resolved (file-truename file))
        (cursor (expand-file-name file))
        (base (expand-file-name root))
        (symlink nil))
    (while (and (not symlink)
                (not (equal cursor base))
                (file-in-directory-p cursor base))
      (setq symlink (file-symlink-p cursor)
            cursor (directory-file-name (file-name-directory cursor))))
    (cond
     ((or symlink (file-symlink-p base))
      (error "Git symbolic-link paths cannot be opened"))
     ((not (file-in-directory-p resolved (file-truename root)))
      (error "Git file is outside this mirror"))
     ((file-in-directory-p
       resolved (file-truename (expand-file-name ".git" root)))
      (error "Git internals are not browseable"))
     ((not (file-regular-p resolved))
      (error "Git path is not a regular worktree file"))
     ((> (file-attribute-size (file-attributes resolved))
         emacsos-assist-web-git--file-view-limit)
      (error "Git file exceeds 1 MiB display limit"))))
  (let* ((relative (file-relative-name file root))
         (view (generate-new-buffer
                (format "*Git %s %s*"
                        (emacsos-assist-web-git--short
                         (emacsos-assist-web-git-generation-oid generation))
                        relative))))
    (condition-case error
        (with-current-buffer view
          (setq default-directory (file-name-as-directory root))
          (insert-file-contents-literally
           file nil 0 (1+ emacsos-assist-web-git--file-view-limit))
          (when (> (buffer-size) emacsos-assist-web-git--file-view-limit)
            (error "Git file exceeds 1 MiB display limit"))
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
         (default-directory (file-name-as-directory root))
         (auth-epoch (with-current-buffer thread
                       emacsos-assist-web-git--auth-epoch))
         (safety-epoch (with-current-buffer thread
                         emacsos-assist-web-git--epoch)))
    (when (emacsos-assist-web-git--intent-live-p intent)
      (when (with-current-buffer thread
              emacsos-assist-web--reconcile-recovery-paused)
        (user-error "local recovery could not be saved; restart to recover"))
      (when (with-current-buffer thread
              emacsos-assist-web--manual-recovery-required)
        (user-error "Run recovery pending; Refresh"))
      (when (with-current-buffer thread emacsos-assist-web-git--denied)
        (user-error "Thread Git access denied; reauthorize and Retry"))
      (when (with-current-buffer thread emacsos-assist-web-git--pending)
        (user-error "Thread Git repository change pending; Retry"))
      (when (with-current-buffer thread
              (and (> emacsos-assist-web-git--auth-epoch 0)
                   (not (eql emacsos-assist-web-git--auth-epoch
                             (emacsos-assist-web-git-generation-auth-epoch
                              generation)))))
        (user-error "Thread Git mirror predates authorization; Retry"))
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
             (unless (with-current-buffer thread
                       (and (not emacsos-assist-web-git--denied)
                            (not emacsos-assist-web-git--pending)
                            (not emacsos-assist-web--reconcile-recovery-paused)
                            (not emacsos-assist-web--manual-recovery-required)
                            (= auth-epoch emacsos-assist-web-git--auth-epoch)
                            (= safety-epoch emacsos-assist-web-git--epoch)))
               (user-error "Thread Git repository changed; Retry"))
             (let ((view (emacsos-assist-web-git--literal-file-view
                          choice root thread generation)))
               (condition-case error
                   (set-window-buffer window view)
                 (error
                  (kill-buffer view)
                  (signal (car error) (cdr error))))))))
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
  "Pin VIEW to GENERATION and THREAD until VIEW is closed."
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
  "Cancel this thread's fetch and remove its window feedback."
  (dolist (entry emacsos-assist-web-git--feedback-windows)
    (when (and (window-live-p (car entry))
               (eq (window-parameter (car entry) 'assist-web-git-feedback)
                   (cdr entry)))
      (emacsos-assist-web-git--clear-feedback (car entry))))
  (setq emacsos-assist-web-git--feedback-windows nil)
  (setq emacsos-assist-web-git--next nil)
  (emacsos-assist-web-git--cancel))

(provide 'assist-web-git)
;;; assist-web-git.el ends here
