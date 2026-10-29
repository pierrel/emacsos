;;; assist-web.el --- Assist Web threads in EmacsOS -*- lexical-binding: t -*-
;;; Commentary:

;; This is deliberately separate from emacsos-assist.el.  A .assist file is a
;; phone-local conversation owned by emacsos-server; this mode is a client of
;; Assist Web's canonical thread/run state on phone and desktop.

;;; Code:

(defun emacsos-assist-web--run-gated-p ()
  "Return whether this thread has unverified server Run authority."
  (let ((tid emacsos-assist-web--thread-id))
    (and tid
         (seq-some
          (lambda (buffer)
            (with-current-buffer buffer
              (and (equal emacsos-assist-web--thread-id tid)
                   (or emacsos-assist-web--run-outcome-uncertain
                       emacsos-assist-web--stopped-reobserve))))
          (buffer-list)))))


(require 'cl-lib)
(require 'imenu)
(require 'chat)
(require 'assist-web-git)
(require 'json)
(require 'seq)
(require 'subr-x)
(require 'ucs-normalize)
(require 'url)
(require 'url-http)
(require 'url-cache)
(require 'url-util)
(require 'wid-edit)

(declare-function emacsos--render-page "os")
(declare-function emacsos--fit-pixel-width "os" (text pixels &optional face))
(defvar url-http-content-type)
(defvar url-http-end-of-headers)
(defvar url-http-open-connections)
(defvar url-http-response-status)
(defvar url-http-attempt-keepalives)
(defvar gnutls-trustfiles)
(defvar emacsos-assist-web-approval-mode-map)

(defvar-local emacsos-assist-web--lifecycle-notice nil
  "General Run/recovery warning, independent of fetched Git state.")

(defun emacsos-assist-web--update-lifecycle-headers ()
  "Redisplay the Assist header without changing Git freshness or requests."
  (force-mode-line-update t))

(defun emacsos-assist-web--lifecycle-warning (reason)
  "Show general Run/recovery REASON without invalidating a Git checkout."
  (setq emacsos-assist-web--lifecycle-notice reason)
  (emacsos-assist-web--update-lifecycle-headers))

(defvar-local emacsos-assist-web--asset-directory nil)
(defvar-local emacsos-assist-web--asset-generation 0)
(defvar-local emacsos-assist-web--asset-refresh-pending nil)
(defvar emacsos-assist-web--asset-render-accepted nil
  "Dynamic completion marker for a canonical request that actually rendered.")

(defvar-local emacsos-assist-web--auth-epoch 0)
(defvar emacsos-assist-web--current-canonical-get-owner nil
  "Request-start owner dynamically bound around a canonical GET callback.")

(defvar-local emacsos-assist-web--thread-denial-floor 0
  "Last definitive thread denial epoch superseding earlier exact Run reads.")

(defvar-local emacsos-assist-web--denied nil)

(defvar-local emacsos-assist-web--thread-denial-status nil
  "Definitive canonical thread HTTP status, independent of cleanup messages.")

(defvar-local emacsos-assist-web--run-outcome-uncertain nil
  "Outstanding (thread, Run, epoch) denial or superseded-read fences.
Exact post-denial Run verification plus durable canonical acceptance removes
one record; definitive thread denial preserves it for later reauthorization.")

(defvar-local emacsos-assist-web--run-recheck-needed nil
  "Auth epoch of one pending auth-only thread GET after exact Run denial.")

(defvar-local emacsos-assist-web--busy-check nil
  "One post-save active-Run thread check, owned by its exact receipt.")

(defvar-local emacsos-assist-web--stopped-reobserve nil
  "Local projection of a Run stopped by SSE end, disconnect, approval, or repair.
It also fences an exact active Run's T check and terminal Run's R2 commit.")


(defvar emacsos-assist-web--thread-safety (make-hash-table :test 'equal)
  "In-process safety records keyed by exact authenticated thread ID.")


(defvar-local emacsos-assist-web--thread-safety-tid nil
  "Exact thread ID whose shared safety record the local kill hook updates.")


(defun emacsos-assist-web--thread-safety-enroll (record tid buffer)
  "Enroll exact TID BUFFER in RECORD and apply an existing stop fence."
  (unless (memq buffer (plist-get record :buffers))
    (push buffer (plist-get record :buffers))
    (with-current-buffer buffer
      (setq-local emacsos-assist-web--thread-safety-tid tid)
      (add-hook 'kill-buffer-hook
                #'emacsos-assist-web--thread-safety-buffer-killed nil t))))


(defun emacsos-assist-web--thread-safety-buffer-killed ()
  "Enroll still-open same-thread peers before this buffer's safety exit."
  (let ((inhibit-quit t)
        (tid emacsos-assist-web--thread-safety-tid))
    (when-let ((record (and tid
                           (gethash tid emacsos-assist-web--thread-safety))))
      (dolist (buffer (buffer-list))
        (when (and (not (eq buffer (current-buffer)))
                   (buffer-live-p buffer)
                   (equal (buffer-local-value
                           'emacsos-assist-web--thread-id buffer) tid))
          (emacsos-assist-web--thread-safety-enroll record tid buffer))))))


(defun emacsos-assist-web--thread-safety-record (tid &optional create)
  "Return TID's live shared safety record, creating it when CREATE is non-nil.
Scan live same-thread peers before pruning a dead owner: a later kill hook
may open one after the owner's own hook ran but before the kill completed.
An observed thread denial survives closing every view until reauthorization."
  ;; Keep an in-flight approval attempt even when its preview is recreated.
  (when tid
    (let ((record (gethash tid emacsos-assist-web--thread-safety)))
      (when record
        (unless (plist-member record :approval-generation)
          (nconc record (list :approval-generation 0)))
        (unless (plist-member record :approval-pending)
          (nconc record (list :approval-pending nil)))
        (unless (plist-member record :git-request-order)
          (nconc record (list :git-request-order 0 :git-auth-floor 0)))
        (setf (plist-get record :buffers)
              (seq-filter #'buffer-live-p (plist-get record :buffers)))
        (dolist (buffer (buffer-list))
          (when (and (buffer-live-p buffer)
                     (equal (buffer-local-value
                             'emacsos-assist-web--thread-id buffer) tid))
            (emacsos-assist-web--thread-safety-enroll
             record tid buffer)))
        (unless (or (plist-get record :buffers) (plist-get record :denial)
                    (plist-get record :approval-pending))
          (remhash tid emacsos-assist-web--thread-safety)
          (setq record nil)))
      (when (and create (not record))
        (setq record (list :buffers nil :denial nil :approval-generation 0
                           :approval-pending nil :git-request-order 0
                           :git-auth-floor 0))
        (puthash tid record emacsos-assist-web--thread-safety)
        (dolist (buffer (buffer-list))
          (when (and (buffer-live-p buffer)
                     (equal (buffer-local-value
                             'emacsos-assist-web--thread-id buffer) tid))
            (emacsos-assist-web--thread-safety-enroll
             record tid buffer))))
      record)))


(defun emacsos-assist-web--padded-action (label command)
  "Return a 40-pixel touch action LABEL invoking COMMAND."
  (let* ((map (make-sparse-keymap))
         (edge (propertize " " 'mouse-face 'highlight 'local-map map
                           'display '(space :width (20) :height (40)))))
    (define-key map [header-line mouse-1] command)
    (concat edge (propertize (format "[%s]" label)
                             'mouse-face 'highlight 'local-map map)
            edge)))


(defun emacsos-assist-web--lifecycle-header ()
  "Offer server authority recovery and display actions, not local queue states."
  (cond
   ((eq emacsos-assist-web--denied 'run)
    (concat (emacsos-assist-web--run-refresh-link) (emacsos-assist-web--details-link)))
   (emacsos-assist-web--denied
    (emacsos-assist-web--status-action
     (if (eql emacsos-assist-web--thread-denial-status 404) "Thread unavailable" "Reauthorize")))
   ((emacsos-assist-web--run-gated-p)
    (concat (emacsos-assist-web--run-refresh-link) (emacsos-assist-web--details-link)))
   (emacsos-assist-web--display-recovery
    (emacsos-assist-web--padded-action "Refresh display" #'emacsos-assist-web-refresh-thread))
   (emacsos-assist-web--lifecycle-notice
    (emacsos-assist-web--run-refresh-link emacsos-assist-web--lifecycle-notice))))

(defun emacsos-assist-web--thread-header ()
  "Keep Run details and Git Status/Merge actions reachable on the phone."
  (let* ((run (emacsos-assist-web--lifecycle-header))
         (status-link (emacsos-assist-web--padded-action
                       "Status" #'emacsos-assist-web-git-status))
         (merge-link (emacsos-assist-web--padded-action
                      "Merge" #'emacsos-assist-web-git-merge))
         (actions (concat status-link merge-link))
         (remaining (max 0 (- (window-body-width) (string-width actions)))))
    (concat actions
            (when run
              (let* ((details (emacsos-assist-web--details-link))
                     (detail-start (and (>= remaining (string-width details))
                                        (string-suffix-p details run)
                                        (- (length run) (length details)))))
                (if detail-start
                    (concat (truncate-string-to-width
                             (substring run 0 detail-start)
                             (- remaining (string-width details)))
                            (substring run detail-start))
                  (truncate-string-to-width run remaining)))))))

(defvar-local emacsos-assist-web--display-details-thread nil)


(defun emacsos-assist-web-display-details ()
  "Explain a committed canonical history whose display failed."
  (interactive)
  (unless (bound-and-true-p emacsos-assist-web--display-recovery)
    (user-error "No canonical display recovery is pending"))
  (let ((thread (current-buffer))
        (view (generate-new-buffer " *Assist Web saved history*")))
    (with-current-buffer view
      (insert "Canonical history was saved. Any exact Run retirement was saved.\n\n"
              "The phone could not display the result. Refresh retries "
              "presentation; it does not resend or reobserve a retired Run.\n\n"
              "Press q to return, then Refresh.\n")
      (special-mode)
      (visual-line-mode 1)
      (setq-local emacsos-assist-web--display-details-thread thread)
      (local-set-key (kbd "q") #'emacsos-assist-web-display-details-back))
    (switch-to-buffer view)))


(defun emacsos-assist-web-display-details-back ()
  "Return from a Run or saved-history explanation to its thread."
  (interactive)
  (let ((thread emacsos-assist-web--display-details-thread)
        (view (current-buffer)))
    (when (buffer-live-p thread)
      (switch-to-buffer thread))
    (kill-buffer view)))


(defun emacsos-assist-web--show-display-recovery ()
  "Expose the independent saved-history header in every thread window."
  (dolist (window (get-buffer-window-list (current-buffer) nil t))
    (emacsos-assist-web-git--clear-feedback window))
  (force-mode-line-update t))


(defun emacsos-assist-web--canonical-start
    (&optional _durable owner _outcomes _observed-outcomes)
  "Return a caller diagnostic trigger without Git freshness state."
  (and owner (list :owner owner)))


(defun emacsos-assist-web--canonical-failed (_token &optional _reason)
  "Leave Git state unchanged when a chat canonical GET fails.")


(defun emacsos-assist-web--r2-finished (_owner _committed)
  "Retry a deferred Run access check after chat reconciliation."
  (emacsos-assist-web--maybe-run-recheck))


(defun emacsos-assist-web--details-link (&optional command)
  "Return a 40-pixel-high, at least 40-pixel-wide link invoking COMMAND."
  (emacsos-assist-web--padded-action
   "?" (or command #'emacsos-assist-web-status-details)))


(defun emacsos-assist-web--status-action (label)
  "Return compact LABEL and a clickable explanation affordance."
  (concat label (emacsos-assist-web--details-link)))


(defun emacsos-assist-web--run-refresh-link (&optional label)
  "Return a compact LABEL action for rechecking an exact Run."
  (propertize (or label "Run status; Refresh") 'mouse-face 'highlight
              'local-map
              (let ((map (make-sparse-keymap)))
                (define-key map [header-line mouse-1]
                  #'emacsos-assist-web-refresh-thread)
                map)))


(defun emacsos-assist-web-status-details ()
  "Show current server authority or local display status without recovery queues."
  (interactive)
  (let ((reason (or emacsos-assist-web--lifecycle-notice
                    (and emacsos-assist-web--denied "Access is unavailable; refresh to reauthorize")
                    "Accepted work belongs to the server. Refresh the thread for its current history.")))
    (message "%s" reason)))


(defun emacsos-assist-web-details ()
  "Open the active recovery/access explanation or saved-history details."
  (interactive)
  (if (or (bound-and-true-p emacsos-assist-web--reconcile-recovery-paused)
          emacsos-assist-web--denied
          (emacsos-assist-web--run-gated-p)
          emacsos-assist-web--stopped-reobserve
          (bound-and-true-p emacsos-assist-web--manual-recovery-required))
      (emacsos-assist-web-status-details)
    (if emacsos-assist-web--display-recovery
        (emacsos-assist-web-display-details)
      (emacsos-assist-web-git-thread-details))))


(defun emacsos-assist-web--thread-denial-reason ()
  "Return the stable visible reason for this buffer's thread denial."
  (if (eql emacsos-assist-web--thread-denial-status 404)
      "thread unavailable (404); reopen and Retry"
    (format "thread access denied (%d); reauthorize and Retry"
            emacsos-assist-web--thread-denial-status)))


(defun emacsos-assist-web--canonical-denied-local (status)
  "Latch canonical HTTP STATUS denial before fallible presentation."
  (setq emacsos-assist-web--asset-refresh-pending nil)
  (cl-incf emacsos-assist-web--asset-generation)
  (cl-incf emacsos-assist-web--auth-epoch)
  (setq emacsos-assist-web--thread-denial-floor
        emacsos-assist-web--auth-epoch)
  (setq emacsos-assist-web--denied t
        emacsos-assist-web--thread-denial-status status
        emacsos-assist-web--run-recheck-needed nil)
  (setq emacsos-assist-web--lifecycle-notice
        (emacsos-assist-web--thread-denial-reason)))


(defun emacsos-assist-web--canonical-denied (status)
  "Fence every live buffer for this thread after definitive HTTP STATUS.
Close approval previews after latching denial on every peer."
  (let* ((tid emacsos-assist-web--thread-id)
         (source (current-buffer))
         targets)
    ;; The safety latch reaches every same-T buffer before any release,
    ;; cancellation, header, or echo-area operation can signal.
    (let ((inhibit-quit t))
      (when tid
        (let ((record (emacsos-assist-web--thread-safety-record tid t)))
          (setf (plist-get record :denial) status)))
      (emacsos-assist-web--canonical-denied-local status)
      (setq targets (list source))
      (dolist (buffer (buffer-list))
        (when (and tid (not (eq buffer source))
                   (equal (buffer-local-value
                           'emacsos-assist-web--thread-id buffer) tid))
          (push buffer targets)))
      (dolist (buffer targets)
        (unless (eq buffer source)
          (with-current-buffer buffer
            (emacsos-assist-web--canonical-denied-local status))))
      (dolist (buffer targets)
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (condition-case nil
                (emacsos-assist-web-git--invalidate
                 emacsos-assist-web--lifecycle-notice)
              ((error quit) nil))
            (when (derived-mode-p 'emacsos-assist-web-approval-mode)
              (kill-buffer buffer))))))
    (when (buffer-live-p source)
      (with-current-buffer source
        (condition-case nil
            (message "Thread Git: %s" emacsos-assist-web--lifecycle-notice)
          ((error quit) nil))))))


(defun emacsos-assist-web--run-record (tid run-id)
  "Return the outstanding safety record for exact TID and RUN-ID."
  (seq-find (lambda (record)
              (and (equal (plist-get record :tid) tid)
                   (equal (plist-get record :run-id) run-id)))
            emacsos-assist-web--run-outcome-uncertain))


(defun emacsos-assist-web--claim-orphaned-run-gate (tid run-id)
  "Claim a dead owner's TID/RUN-ID gate for this exact saved Run receipt.
Only this buffer's observed server Run can claim the gate."
  (when (and (equal tid emacsos-assist-web--thread-id)
             emacsos-assist-web--pending-accepted-p
             (equal run-id emacsos-assist-web--run-id))
  (let ((local (emacsos-assist-web--run-record tid run-id)))
    (unless (and local (buffer-live-p (plist-get local :origin)))
    (let ((origin (and local (plist-get local :origin))))
      (dolist (buffer (buffer-list))
        (when (and (not origin) (not (eq buffer (current-buffer))))
          (with-current-buffer buffer
            (when-let ((record (emacsos-assist-web--run-record tid run-id)))
              (when (and (plist-get record :origin)
                         (not (buffer-live-p (plist-get record :origin))))
                (setq origin (plist-get record :origin)))))))
      (when origin
        (let ((new-owner (current-buffer))
              (epoch (cl-incf emacsos-assist-web--auth-epoch)))
          (if local
              (setf (plist-get local :epoch) epoch
                    (plist-get local :origin) new-owner)
            (push (list :tid tid :run-id run-id :epoch epoch
                        :origin new-owner)
                  emacsos-assist-web--run-outcome-uncertain))
          (setq emacsos-assist-web--denied 'run)
          (emacsos-assist-web--lifecycle-warning
           "Run status unavailable; Refresh thread")
          (dolist (buffer (buffer-list))
            (with-current-buffer buffer
              (dolist (record emacsos-assist-web--run-outcome-uncertain)
                (when (and (eq (plist-get record :origin) origin)
                           (equal (plist-get record :tid) tid)
                           (equal (plist-get record :run-id) run-id))
                  (setf (plist-get record :origin) new-owner))))))))))))


(defun emacsos-assist-web--run-recheck-start (tid run-id)
  "Make a superseding exact TID/RUN-ID read noncurrent until it commits."
  (unless (emacsos-assist-web--run-record tid run-id)
    (push (list :tid tid :run-id run-id
                :epoch emacsos-assist-web--auth-epoch)
          emacsos-assist-web--run-outcome-uncertain))
  (setq emacsos-assist-web--lifecycle-notice
        "Run recheck pending; Refresh")
  (emacsos-assist-web--update-lifecycle-headers))


(defun emacsos-assist-web--run-read-superseded-p (tid run-id start-epoch)
  "Whether a later thread or Run denial superseded TID/RUN-ID's GET."
  (or (and (> emacsos-assist-web--thread-denial-floor 0)
           (or (not (integerp start-epoch))
               (< start-epoch emacsos-assist-web--thread-denial-floor)))
      (when-let ((record (emacsos-assist-web--run-record tid run-id)))
        (or (not (integerp start-epoch))
            (< start-epoch (plist-get record :epoch))))))


(defun emacsos-assist-web--run-access-uncertain (status run-id)
  "Fence exact RUN-ID after HTTP STATUS, preserving stronger thread denial."
  (let* ((thread (current-buffer))
         (tid emacsos-assist-web--thread-id)
         (strong (eq emacsos-assist-web--denied t))
         (epoch (cl-incf emacsos-assist-web--auth-epoch)))
    (setq emacsos-assist-web--run-outcome-uncertain
          (cons (list :tid tid :run-id run-id :epoch epoch
                      :origin thread)
                (seq-remove (lambda (record)
                              (and (equal (plist-get record :tid) tid)
                                   (equal (plist-get record :run-id) run-id)))
                            emacsos-assist-web--run-outcome-uncertain)))
    ;; Canonical ownership may temporarily span source and destination buffers.
    ;; Their thread views and in-flight requests must share this exact denial.
    (dolist (other (buffer-list))
      (when (and (not (eq other thread))
                 (with-current-buffer other
                   (and (derived-mode-p 'emacsos-assist-web-mode)
                        (equal emacsos-assist-web--thread-id tid))))
        (with-current-buffer other
          (let ((other-epoch (cl-incf emacsos-assist-web--auth-epoch)))
            (push (list :tid tid :run-id run-id :epoch other-epoch
                        :origin thread)
                  emacsos-assist-web--run-outcome-uncertain)
            (unless (eq emacsos-assist-web--denied t)
              (setq emacsos-assist-web--denied 'run)
              (condition-case nil
                  (emacsos-assist-web--lifecycle-warning
                   (format "Run status unavailable (%d); Refresh thread" status))
                ((error quit) nil)))))))
    (unless strong
      (setq emacsos-assist-web--denied 'run
            emacsos-assist-web--run-recheck-needed epoch)
      (emacsos-assist-web--lifecycle-warning
       (format "Run status unavailable (%d); Refresh thread" status))
      ;; One newer thread GET determines access, not the Run outcome.
      (run-at-time
       0 nil
       (lambda ()
         (when (buffer-live-p thread)
           (with-current-buffer thread
             (emacsos-assist-web--maybe-run-recheck))))))))


(defun emacsos-assist-web--maybe-run-recheck ()
  "Start one auth-only thread GET after an exact Run access fence."
  (when-let ((epoch emacsos-assist-web--run-recheck-needed))
    (cond
     ((or (not (eq emacsos-assist-web--denied 'run))
          (/= epoch emacsos-assist-web--auth-epoch))
      (setq emacsos-assist-web--run-recheck-needed nil))
     ((bound-and-true-p emacsos-assist-web--reconcile-recovery-paused)
      (setq emacsos-assist-web--run-recheck-needed nil)
      (emacsos-assist-web--lifecycle-warning
       "local recovery could not be saved; restart to recover"))
     ((bound-and-true-p emacsos-assist-web--reconcile-generation) nil)
     (t
      (setq emacsos-assist-web--run-recheck-needed nil)
      (let ((thread (current-buffer))
            (tid emacsos-assist-web--thread-id)
            (manual (bound-and-true-p emacsos-assist-web--manual-recovery-required)))
        (condition-case nil
            ;; This authenticates thread scope only.  It never renders,
            ;; caches or projects Git metadata.
            (emacsos-assist-web--request
             "GET" (concat "threads/" (emacsos-assist-web--require-id tid)) nil
             (lambda (value problem)
               (when (and (buffer-live-p thread) (not problem))
                 (with-current-buffer thread
                   (when (and (equal tid emacsos-assist-web--thread-id)
                              (eql epoch emacsos-assist-web--auth-epoch)
                              (eq emacsos-assist-web--denied 'run)
                              (eq manual
                                  (and (bound-and-true-p
                                        emacsos-assist-web--manual-recovery-required)
                                       t))
                              (not (bound-and-true-p
                                    emacsos-assist-web--reconcile-recovery-paused)))
                     (condition-case nil
                         (progn
                           (emacsos-assist-web--require-snapshot value tid)
                           (emacsos-assist-web--snapshot-active-p value)
                           (emacsos-assist-web--canonical-authorized epoch))
                       (error nil)))))))
          (error (emacsos-assist-web--canonical-uncertain))))))))


(defun emacsos-assist-web--canonical-uncertain ()
  "Show a failed chat-owned refresh without changing independent Git state."
  (unless emacsos-assist-web--denied
    (emacsos-assist-web--lifecycle-warning
     "canonical refresh unavailable; existing chat only; Retry")))


(defun emacsos-assist-web--canonical-authorized (start-epoch)
  "Record validated canonical GET begun at START-EPOCH and clear denial.
An auth-only GET leaves exact Run outcome uncertain."
  (when (eql start-epoch emacsos-assist-web--auth-epoch)
    (let* ((tid emacsos-assist-web--thread-id)
           (record (emacsos-assist-web--thread-safety-record tid))
           (thread-denial (or (eq emacsos-assist-web--denied t)
                              (plist-get record :denial))))
      (when (and record emacsos-assist-web--current-canonical-get-owner
                 (eq record (car emacsos-assist-web--current-canonical-get-owner)))
        (setf (plist-get record :git-auth-floor)
              (max (plist-get record :git-auth-floor)
                   (cdr emacsos-assist-web--current-canonical-get-owner))))
      (when (or emacsos-assist-web--denied (plist-get record :denial))
        (setq emacsos-assist-web--denied nil
              emacsos-assist-web--thread-denial-status nil
              emacsos-assist-web--run-recheck-needed nil)
        (when thread-denial
          (when record (setf (plist-get record :denial) nil))
          (dolist (buffer (buffer-list))
            (unless (eq buffer (current-buffer))
              (with-current-buffer buffer
                (when (and (derived-mode-p 'emacsos-assist-web-mode)
                           (equal emacsos-assist-web--thread-id tid)
                           (eq emacsos-assist-web--denied t))
                  (setq emacsos-assist-web--denied nil
                        emacsos-assist-web--thread-denial-status nil)
                  (condition-case nil
                      (emacsos-assist-web--update-lifecycle-headers)
                    ((error quit) nil)))))))
        (emacsos-assist-web--update-lifecycle-headers)))))


(defun emacsos-assist-web--run-status-confirmed (tid run-id start-epoch)
  "Clear TID/RUN-ID's warning only after post-denial durable acceptance.
The caller owns both the exact Run GET and subsequent canonical commit."
  (let ((inhibit-quit t))
    (when-let ((record (emacsos-assist-web--run-record tid run-id)))
    (when (and (or (not (plist-get record :origin))
                   (eq (plist-get record :origin) (current-buffer)))
               (integerp start-epoch)
               (>= start-epoch emacsos-assist-web--thread-denial-floor)
               (<= (plist-get record :epoch) start-epoch))
      (let ((origin (current-buffer)))
        (setq emacsos-assist-web--run-outcome-uncertain
              (delq record emacsos-assist-web--run-outcome-uncertain))
        (when (and (equal tid (plist-get emacsos-assist-web--busy-check :tid))
                   (equal run-id (plist-get emacsos-assist-web--busy-check
                                            :run-id)))
          (setq emacsos-assist-web--busy-check nil))
        (dolist (other (buffer-list))
          (when (and (not (eq other origin))
                     (with-current-buffer other
                       (and (derived-mode-p 'emacsos-assist-web-mode)
                            (equal emacsos-assist-web--thread-id tid))))
            (with-current-buffer other
              (setq emacsos-assist-web--run-outcome-uncertain
                    (seq-remove
                     (lambda (candidate)
                       (and (eq (plist-get candidate :origin) origin)
                            (equal (plist-get candidate :tid) tid)
                            (equal (plist-get candidate :run-id) run-id)))
                     emacsos-assist-web--run-outcome-uncertain))
              (when (and (eq emacsos-assist-web--denied 'run)
                         (not emacsos-assist-web--run-outcome-uncertain))
                (setq emacsos-assist-web--denied nil))
              (condition-case nil
                  (emacsos-assist-web--update-lifecycle-headers)
                ((error quit) nil))))))
      ;; Presentation must not interrupt an already durable Run retirement.
      (condition-case nil
          (emacsos-assist-web--update-lifecycle-headers)
        ((error quit) nil))))))


(defun emacsos-assist-web--retire-stopped-reobserve (tid run-id)
  "Retire a transient observer warning after verified server Run authority."
  (when (and (equal tid (plist-get emacsos-assist-web--stopped-reobserve :tid))
             (equal run-id (plist-get emacsos-assist-web--stopped-reobserve :run-id)))
    (setq emacsos-assist-web--stopped-reobserve nil)
    (emacsos-assist-web--update-lifecycle-headers)))











(defun emacsos-assist-web--busy-check-owner-p (token)
  "Return whether TOKEN still names this buffer's observed server Run."
  (and (equal (plist-get token :tid) emacsos-assist-web--thread-id)
       emacsos-assist-web--pending-accepted-p
       (equal (plist-get token :run-id) emacsos-assist-web--run-id)
       (eql (plist-get token :send-generation) emacsos-assist-web--send-generation)
       (eql (plist-get token :terminal-generation) emacsos-assist-web--run-check-generation)))


(defun emacsos-assist-web--busy-check-start (token)
  "Start one bounded post-save canonical T read for TOKEN."
  (when (and (eq token emacsos-assist-web--busy-check)
             (not (plist-get token :in-flight))
             (emacsos-assist-web--busy-check-owner-p token))
    (setf (plist-get token :in-flight) t
          (plist-get token :serial) (1+ (or (plist-get token :serial) 0)))
    (let ((thread (current-buffer))
          (serial (plist-get token :serial))
          (tid (plist-get token :tid))
          (run-id (plist-get token :run-id))
          (run-start (plist-get token :run-start))
          (auth-start emacsos-assist-web--auth-epoch)
          (git-selection-start emacsos-assist-web-git--epoch)
          (refresh (cl-incf emacsos-assist-web--refresh-generation))
          (canonical-token (emacsos-assist-web--canonical-start t)))
      (emacsos-assist-web--request
       "GET" (concat "threads/" (emacsos-assist-web--require-id tid)) nil
       (lambda (snapshot problem)
         (when (buffer-live-p thread)
           (with-current-buffer thread
             (when (and (eq token emacsos-assist-web--busy-check)
                        (eql serial (plist-get token :serial)))
               (setf (plist-get token :in-flight) nil)
               (if (or problem
                       (not (emacsos-assist-web--busy-check-owner-p token))
                       (not (eql refresh emacsos-assist-web--refresh-generation))
                       (not (eql auth-start emacsos-assist-web--auth-epoch))
                       (emacsos-assist-web--run-read-superseded-p
                        tid run-id run-start))
                   (unless emacsos-assist-web--denied
                     (setq emacsos-assist-web--lifecycle-notice
                           "Run status; Refresh retries canonical check")
                     (emacsos-assist-web--canonical-failed
                      canonical-token "Run status; Refresh retries canonical check"))
                 (condition-case nil
                     (let* ((_ (emacsos-assist-web--require-snapshot snapshot tid))
                            (busy (emacsos-assist-web--snapshot-active-p snapshot)))
                       (unless busy (error "exact Run still needs terminal reconciliation"))
                       (cond
                        ((not (emacsos-assist-web--try-write-cache
                               (emacsos-assist-web--snapshot-cache-name tid)
                               snapshot))
                         (setq emacsos-assist-web--lifecycle-notice
                               "canonical cache unavailable; Refresh")
                         (emacsos-assist-web--canonical-failed
                          canonical-token "canonical cache unavailable; Refresh"))
                        (t
                           (setq emacsos-assist-web--snapshot snapshot)
                           (emacsos-assist-web--canonical-authorized
                            auth-start)
                           (emacsos-assist-web--run-status-confirmed
                            tid run-id run-start)
                           ;; Git selection may have changed independently.
                           ;; That cannot prevent this durable Run acceptance.
                           (when (= git-selection-start emacsos-assist-web-git--epoch)
                             (emacsos-assist-web--git-note-safely
                              snapshot nil auth-start canonical-token))
                           (setf (plist-get token :t-accepted) t)
                           (emacsos-assist-web--finish-active-join))))
                   ((error quit)
                    (emacsos-assist-web--lifecycle-warning
                     "Run status or Git projection unavailable; Retry")
                    (emacsos-assist-web--canonical-failed
                     canonical-token "Run status; Refresh retries canonical check"))))
               (emacsos-assist-web--update-lifecycle-headers)))))))))


(defun emacsos-assist-web--confirm-active-run (tid run-id start-epoch)
  "Recheck canonical authority after a verified active server Run read."
  (when (emacsos-assist-web--run-record tid run-id)
    (let ((token (list :tid tid :run-id run-id :run-start start-epoch
                       :send-generation emacsos-assist-web--send-generation
                       :terminal-generation emacsos-assist-web--run-check-generation
                       :t-accepted nil :in-flight nil :serial 0)))
      (setq emacsos-assist-web--busy-check token)
      (emacsos-assist-web--busy-check-start token))))


(defun emacsos-assist-web--finish-active-join ()
  "Release the current verified Run's canonical authority check."
  (when (and emacsos-assist-web--busy-check
             (plist-get emacsos-assist-web--busy-check :t-accepted)
             (emacsos-assist-web--busy-check-owner-p emacsos-assist-web--busy-check))
    (setq emacsos-assist-web--busy-check nil)
    (when (equal emacsos-assist-web--lifecycle-notice "Run canonical check pending")
      (setq emacsos-assist-web--lifecycle-notice nil))
    (emacsos-assist-web--update-lifecycle-headers)))


(defun emacsos-assist-web--retry-busy-check ()
  "Retry or join this active exact Run's post-save T check, if any."
  (when-let ((token emacsos-assist-web--busy-check))
    (when (emacsos-assist-web--busy-check-owner-p token)
      (if (plist-get token :t-accepted)
          (message "Run observer connecting; result will appear here")
        (if (plist-get token :in-flight)
          (message "Run canonical check in progress; result will appear here")
          (emacsos-assist-web--busy-check-start token)))
      t)))


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
  "Private local cache for Assist Web catalogs, snapshots, and drafts."
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


(defvar-local emacsos-assist-web--run-check-generation 0
  "Serial for exact observed Run authority checks.")


(defvar-local emacsos-assist-web--prompt-refusal nil
  "Fixed local refusal for the current unchanged editable draft.")





(defvar-local emacsos-assist-web--thread-id nil)
(defvar-local emacsos-assist-web--canonical-buffer-name-p nil
  "Non-nil when this buffer follows canonical thread titles.")
(defvar-local emacsos-assist-web--draft-repository nil)
(defvar-local emacsos-assist-web--draft-harness nil)
(defvar-local emacsos-assist-web--run-id nil)
(defvar-local emacsos-assist-web--http-draft nil
  "One submitted text/key tuple until HTTP acceptance is durably saved.
A failed or interrupted request retains its key for an explicit unchanged retry.")

(defvar-local emacsos-assist-web--pending-key nil)
(defvar-local emacsos-assist-web--in-flight nil)

(defvar-local emacsos-assist-web--snapshot nil)
(defvar-local emacsos-assist-web--approval-source nil)
(defvar-local emacsos-assist-web--approval nil)
(defvar-local emacsos-assist-web--approval-edited nil)
(defvar-local emacsos-assist-web--approval-armed nil)
(defvar-local emacsos-assist-web--approval-armed-window nil)
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







(defun emacsos-assist-web--cache-path (&optional name)
  "Return the cache path for NAME without changing the filesystem."
  (expand-file-name (or name emacsos-assist-web--catalog-file)
                    emacsos-assist-web-cache-directory))

(defun emacsos-assist-web--write-cache (name value &optional encoded-value)
  "Atomically save VALUE as JSON cache NAME.
ENCODED-VALUE, when supplied, is the exact precomputed JSON to install."
  (let ((encoded (or encoded-value (json-encode value)))
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

(defun emacsos-assist-web--try-write-cache (name value &optional encoded-value)
  "Write cache NAME as VALUE, returning nil after a visible local failure.
ENCODED-VALUE is passed through as the exact precomputed JSON when supplied."
  (condition-case error
      (progn
        (if encoded-value
            (emacsos-assist-web--write-cache name value encoded-value)
          (emacsos-assist-web--write-cache name value))
        t)
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
                      entry '(id description search_description repo_label status
                               unread urgent unmerged)))
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
                 (or (not (assq 'approval_count thread))
                     (and (integerp (alist-get 'approval_count thread))
                          (>= (alist-get 'approval_count thread) 0)))
                 (memq (alist-get 'approval_results thread) '(nil t))
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

Ready threads select their actual checkout.  Busy threads use the bound thread
branch and show a warning that the remote may change after the turn.  Git checks
the selected ref format before the fetch begins."
  (let* ((thread (alist-get 'thread snapshot))
         (workspace (alist-get 'workspace thread))
         (tid (emacsos-assist-web--require-id (alist-get 'id thread)))
         (status (alist-get 'status thread))
         (repo-key (alist-get 'repo_key workspace))
         (actual-branch (alist-get 'branch workspace))
         (head (alist-get 'revision workspace))
         (bound-branch (alist-get 'thread_branch workspace))
         (sync-error (alist-get 'sync_error workspace))
         (publication-notice (alist-get 'publication_notice thread)))
    (unless (or (null repo-key)
                (and (stringp repo-key)
                     (string-match-p
                      emacsos-assist-web--git-repo-key-regexp repo-key)))
      (error "Assist Web returned an invalid Git repository key"))
    (unless (or (null head)
                (and (stringp head)
                     (string-match-p emacsos-assist-web--git-oid-regexp head)))
      (error "Assist Web returned an invalid Git object ID"))
    (when (and bound-branch
               (not (and (stringp bound-branch)
                         (<= (string-bytes bound-branch) 240)
                         (not (member bound-branch '("main" "HEAD")))
                         (not (string-match-p "[[:cntrl:]]" bound-branch)))))
      (error "Assist Web returned an invalid bound Git branch"))
    (unless (or (null sync-error)
                (and (stringp sync-error)
                     (<= (string-bytes sync-error) 256)
                     (not (string-match-p "[[:cntrl:]]" sync-error))))
      (error "Assist Web returned an invalid Git status"))
    (unless (or (null publication-notice)
                (and (stringp publication-notice)
                     (<= (string-bytes publication-notice) 512)
                     (not (string-match-p "[[:cntrl:]]" publication-notice))))
      (error "Assist Web returned an invalid Git publication notice"))
    (let* ((ready (equal status "ready"))
           (branch (if ready actual-branch (or bound-branch actual-branch))))
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
            :status status
            :repo-label (alist-get 'repo_label workspace)
            :sync-error sync-error
            :publication-notice publication-notice
            :thread-label (alist-get 'description thread)
            :actual-branch (and ready actual-branch)
            :head head))))

(defun emacsos-assist-web-git--note-snapshot
    (snapshot &optional successful-run-id auth-start-epoch _reconcile-token _terminal-run-id)
  "Select Git metadata from SNAPSHOT; refresh on new identity or SUCCESSFUL-RUN-ID.
AUTH-START-EPOCH is the canonical authorization fence.  The canonical chat
snapshot remains independent of optional Git availability."
  (condition-case nil
      (let ((metadata (emacsos-assist-web-git--metadata-from-snapshot snapshot)))
        (emacsos-assist-web--canonical-authorized auth-start-epoch)
        (unless (eq emacsos-assist-web--denied t)
          (let ((new-checkout (emacsos-assist-web-git--note metadata)))
            (when (and (plist-get metadata :branch)
                       (or new-checkout successful-run-id))
              (emacsos-assist-web-git-refresh)))))
    (error
     (unless (eq emacsos-assist-web--denied t)
       (condition-case nil
           (emacsos-assist-web-git--invalidate "Git state unavailable")
         ((error quit) nil))))))

(defun emacsos-assist-web--git-note-safely (&rest args)
  "Project optional Git state from ARGS without undoing committed chat state."
  (condition-case nil
      (apply #'emacsos-assist-web-git--note-snapshot args)
    ((error quit)
     (unless (eq emacsos-assist-web--denied t)
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
object, retaining that status as `http_status' so callers can classify a
bounded structured response.  ARRAY-TYPE
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
  (let ((response-limit emacsos-assist-web-max-response-bytes)
        (received 0) (header "") (header-complete nil) (failed nil)
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
                     (> received response-limit))
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
                             (> received response-limit))
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
  "Capture the current observed server Run before its exact GET starts."
  (when (and (equal method "GET") (stringp path)
             (string-match "\\`threads/\\([^/]+\\)/runs/\\([^/]+\\)\\'" path))
    (let ((tid (match-string 1 path)) (run-id (match-string 2 path)))
      (when (and (equal tid emacsos-assist-web--thread-id)
                 emacsos-assist-web--pending-accepted-p
                 (equal run-id emacsos-assist-web--run-id))
        (emacsos-assist-web--claim-orphaned-run-gate tid run-id)
        (list :buffer (current-buffer) :tid tid :run-id run-id
              :send-generation emacsos-assist-web--send-generation
              :terminal-generation emacsos-assist-web--run-check-generation
              :auth-start emacsos-assist-web--auth-epoch)))))

(defun emacsos-assist-web--run-http-owner-current-p (owner tid run-id)
  "Return whether OWNER still holds exact TID/RUN-ID authority at the header."
  (and owner (eq (plist-get owner :buffer) (current-buffer))
       (equal (plist-get owner :tid) tid) (equal (plist-get owner :run-id) run-id)
       (equal emacsos-assist-web--thread-id tid)
       (>= (plist-get owner :auth-start) emacsos-assist-web--thread-denial-floor)
       emacsos-assist-web--pending-accepted-p
       (equal run-id emacsos-assist-web--run-id)
       (eql (plist-get owner :send-generation) emacsos-assist-web--send-generation)
       (eql (plist-get owner :terminal-generation) emacsos-assist-web--run-check-generation)))

(defun emacsos-assist-web--http-access-status
    (origin method path status &optional early-failure run-owner request-tid git-get-owner)
  "Classify ORIGIN's thread, approval, Run GET or read-receipt access failure.
METHOD and PATH identify the exact endpoint, including the thread Git GET.
STATUS is read before JSON
parsing, so a malformed denial body cannot hide a 401, 403, or 404.
EARLY-FAILURE applies only to the canonical thread GET.  Approval GETs
classify only definitive 401, 403, or 404 access denials.
RUN-OWNER prevents a retired or superseded exact Run GET from relatching Run denial.
REQUEST-TID is the trusted origin thread captured before an async request; it
lets a definitive denial fence a live same-T peer if ORIGIN was killed.
GIT-GET-OWNER binds a Git GET to shared thread request-start order. A
definitive denial wins unless a later-started canonical GET validated access.
Return non-nil when the access notification completed or the exact Run
status is safely ignored as stale; nil permits a bounded later retry."
  (when (and (or (equal method "GET")
                 (and (equal method "POST")
                      (memq status '(401 403))
                      (stringp path)
                      (string-match-p "\\`threads/[^/]+/open\\'" path)))
             (or (memq status '(401 403 404)) early-failure)
             (stringp path)
             (or (not git-get-owner)
                 (when-let ((record (emacsos-assist-web--thread-safety-record
                                     request-tid)))
                   (and (eq (car git-get-owner) record)
                        (> (cdr git-get-owner)
                           (plist-get record :git-auth-floor))))))
    (condition-case nil
        (let ((thread-get (or (and (equal method "POST")
                                      (string-match "\\`threads/\\([^/]+\\)/open\\'" path))
                             (and (memq status '(401 403))
                                      (string-match "\\`threads/\\([^/]+\\)/assets\\(?:\\?.*\\)?\\'" path))
                            (string-match
                           (if (memq status '(401 403 404))
                               "\\`threads/\\([^/]+\\)\\(?:/approvals?\\|/git\\)?\\'"
                             "\\`threads/\\([^/]+\\)\\'") path)))
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
                    (emacsos-assist-web--run-access-uncertain status run-id)
                    t)
                   (run-id t)
                   ((memq status '(401 403 404))
                    (emacsos-assist-web--canonical-denied status)
                    t)
                   (t (emacsos-assist-web--canonical-uncertain)
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

(defconst emacsos-assist-web--asset-max-bytes (* 1024 1024)
  "Maximum bytes in one disposable asset, independent of JSON response limits.")
(defconst emacsos-assist-web--asset-max-files 16
  "Maximum most-recent referenced assets checked and cached per thread buffer.")

(defun emacsos-assist-web--asset-path (path)
  "Normalize a public logical asset PATH, retaining its root namespace."
  (when (and (stringp path) (<= (length path) 4096)
             (not (string-match-p "[[:cntrl:]\\\\:]" path)))
    (let* ((logical (if (string-prefix-p "/" path) path (concat "/workspace/" path)))
           (parts (split-string (substring logical 1) "/")))
      (when (and (member (car parts) '("workspace" "user" "tmp")) (cdr parts)
                 (cl-every (lambda (part) (and (not (string-empty-p part))
                                              (not (string-prefix-p "." part)))) parts))
        logical))))

(defun emacsos-assist-web--asset-directory-p ()
  "Return non-nil only for this buffer's existing local cache directory."
  (and emacsos-assist-web--asset-directory
       (not (file-remote-p emacsos-assist-web--asset-directory))
       (not (file-symlink-p emacsos-assist-web--asset-directory))
       (file-directory-p emacsos-assist-web--asset-directory)))

(defun emacsos-assist-web--asset-file (path &optional create)
  "Return the private cache name for PATH, optionally creating its directory."
  (when-let ((logical (emacsos-assist-web--asset-path path)))
    (when (and emacsos-assist-web--thread-id
               (emacsos-assist-web--valid-id-p emacsos-assist-web--thread-id))
      (when (and create (or (not emacsos-assist-web--asset-directory)
                            (and (not (file-symlink-p emacsos-assist-web--asset-directory))
                                 (not (file-exists-p emacsos-assist-web--asset-directory)))))
        (setq emacsos-assist-web--asset-directory (make-temp-file "emacsos-assets-" t)))
      (when (emacsos-assist-web--asset-directory-p)
        (let ((extension (if (string-match "\\.\\([A-Za-z0-9]\\{1,16\\}\\)\\'" logical)
                             (downcase (match-string 1 logical)) "bin")))
          (expand-file-name
           (concat (secure-hash 'sha256 (concat emacsos-assist-web--thread-id "\0" logical))
                   "." extension) emacsos-assist-web--asset-directory))))))

(defun emacsos-assist-web--asset-local-file (path)
  "Return an existing bounded, regular cached PATH without requesting anything."
  (when-let ((file (emacsos-assist-web--asset-file path)))
    (let ((attributes (file-attributes file)))
      (and attributes (null (file-attribute-type attributes)) (file-regular-p file)
           (<= (file-attribute-size attributes) emacsos-assist-web--asset-max-bytes) file))))

(defun emacsos-assist-web--asset-bytes (file)
  "Read at most one asset of regular FILE; reject links and growth beyond cap."
  (when file
    (let ((attributes (file-attributes file)))
      (when (and attributes (null (file-attribute-type attributes)) (file-regular-p file)
                 (<= (file-attribute-size attributes) emacsos-assist-web--asset-max-bytes))
        (with-temp-buffer
          (set-buffer-multibyte nil)
          (insert-file-contents-literally file nil 0 (1+ emacsos-assist-web--asset-max-bytes))
          (when (<= (buffer-size) emacsos-assist-web--asset-max-bytes) (buffer-string)))))))

(defun emacsos-assist-web--asset-view-file (file)
  "Show a read-only literal snapshot of cached FILE without visiting it."
  (let ((data (emacsos-assist-web--asset-bytes file))
        (buffer (get-buffer-create (concat "*Assist cached " (file-name-nondirectory file) "*"))))
    (unless data (user-error "Cached file unavailable; refresh thread"))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (set-buffer-multibyte t)
        (insert (decode-coding-string data 'utf-8)))
      (fundamental-mode)
      (setq buffer-read-only t)
      (set-buffer-modified-p nil)
      (goto-char (point-min)))
    (pop-to-buffer buffer)))

(defun emacsos-assist-web--asset-header (name end)
  "Read one unambiguous HTTP header NAME before END in the response buffer."
  (save-excursion
    (goto-char (point-min))
    (let ((case-fold-search t) value)
      (while (re-search-forward (concat "^" (regexp-quote name) ":[ \t]*\\([^\r\n]*\\)") end t)
        (when value (error "Duplicate asset response header"))
        (setq value (string-trim (match-string-no-properties 1))))
      value)))

(defun emacsos-assist-web--asset-response (buffer)
  "Decode bounded identity bytes or a 304 validator from HTTP response BUFFER."
  (with-current-buffer buffer
    (unless (and (memq url-http-response-status '(200 304))
                 (markerp url-http-end-of-headers))
      (error "Asset request failed (%s)" url-http-response-status))
    (let* ((start (1+ (marker-position url-http-end-of-headers)))
           (etag (emacsos-assist-web--asset-header "ETag" start))
           (declared (emacsos-assist-web--asset-header "Content-Length" start))
           (data (encode-coding-string (buffer-substring-no-properties start (point-max)) 'raw-text)))
      (unless (and etag (string-match-p "\\`\"[0-9a-f]\\{64\\}\"\\'" etag)
                   (<= (length data) emacsos-assist-web--asset-max-bytes)
                   (or (not declared)
                       (and (string-match-p "\\`[0-9]\\{1,7\\}\\'" declared)
                            (= (string-to-number declared) (length data)))))
        (error "Invalid or incomplete asset response"))
      (if (= url-http-response-status 304)
          (unless (zerop (length data)) (error "Unexpected 304 asset body"))
        (unless (and (string-prefix-p "application/octet-stream" (or url-http-content-type ""))
                     (equal etag (concat "\"" (secure-hash 'sha256 data) "\"")))
          (error "Asset bytes do not match their validator")))
      (list :status url-http-response-status :etag etag :data data))))

(defun emacsos-assist-web--asset-cleanup ()
  "Discard this buffer's disposable cache; never touch its editable workspace."
  (cl-incf emacsos-assist-web--asset-generation)
  (setq emacsos-assist-web--asset-refresh-pending nil)
  (when (emacsos-assist-web--asset-directory-p)
    (delete-directory emacsos-assist-web--asset-directory t))
  (setq emacsos-assist-web--asset-directory nil))

(defun emacsos-assist-web--asset-references ()
  "Return the latest bounded unique native file-fence paths in this transcript.
The existing 256 KiB presentation eligibility remains unchanged; maps are excluded."
  (let ((position (point-min)) (end (or (emacsos-assist-web--prompt-start) (point-max))) paths)
    (while (< position end)
      (when (get-text-property position 'emacsos-conversation-file-render)
        (when-let ((logical (emacsos-assist-web--asset-path
                            (cadr (get-text-property position 'emacsos-conversation-object)))))
          (push logical paths)))
      (setq position (next-single-property-change
                      position 'emacsos-conversation-file-render nil end)))
    (seq-take (delete-dups paths) emacsos-assist-web--asset-max-files)))

(defun emacsos-assist-web--refresh-assets ()
  "Check referenced files once in the user's refresh flow, never in rendering.
Editable workspace files win. Complete downloads atomically replace disposable
cache bytes; failure keeps an existing complete copy. No retries are scheduled."
  (let* ((origin (current-buffer)) (tid emacsos-assist-web--thread-id)
         (generation emacsos-assist-web--asset-generation)
         (send-generation emacsos-assist-web--send-generation)
         (auth-epoch emacsos-assist-web--auth-epoch)
         (paths (cl-remove-if (lambda (path)
                                (condition-case nil (emacsos-conversation--workspace-file path) (error nil)))
                              (emacsos-assist-web--asset-references)))
         (names (mapcar (lambda (path) (emacsos-assist-web--asset-file path t)) paths))
         (failures 0))
    (when (emacsos-assist-web--asset-directory-p)
      (dolist (file (directory-files emacsos-assist-web--asset-directory t "\\`[0-9a-f]\\{64\\}\\."))
        (unless (member file names) (delete-file file))))
    (cl-labels
        ((current-p ()
           (and (buffer-live-p origin)
                (with-current-buffer origin
                  (and (equal tid emacsos-assist-web--thread-id)
                       (= generation emacsos-assist-web--asset-generation)
                       (= send-generation emacsos-assist-web--send-generation)
                       (= auth-epoch emacsos-assist-web--auth-epoch)
                       (not emacsos-assist-web--denied)))))
         (next (remaining)
           (when (current-p)
             (with-current-buffer origin
               (if (not remaining)
                   (progn
                     (emacsos-conversation--refresh-file-displays)
                     (when paths
                       (message (if (zerop failures) "Referenced files refreshed"
                                  "Some files unavailable; complete cached copies retained"))))
                 (let* ((path (car remaining))
                        (file (emacsos-assist-web--asset-file path))
                        (old (condition-case nil (emacsos-assist-web--asset-bytes file) (error nil)))
                        (validator (and old (concat "\"" (secure-hash 'sha256 old) "\""))))
                   (emacsos-assist-web--request
                    "GET" (format "threads/%s/assets?path=%s" tid (url-hexify-string path)) nil
                    (lambda (response problem)
                      (when (current-p)
                        (with-current-buffer origin
                          (condition-case nil
                              (if problem (cl-incf failures)
                                (if (= (plist-get response :status) 304)
                                    (let ((now (emacsos-assist-web--asset-bytes file)))
                                      (unless (and validator now
                                                   (equal validator (plist-get response :etag))
                                                   (equal validator (concat "\"" (secure-hash 'sha256 now) "\"")))
                                        (cl-incf failures)))
                                  (let ((destination (emacsos-assist-web--asset-file path)) temporary)
                                    (unless (and destination (equal destination file))
                                      (error "Asset cache no longer available"))
                                    (unwind-protect
                                        (progn
                                          (setq temporary (make-temp-file (concat emacsos-assist-web--asset-directory "/download-")))
                                          (let ((coding-system-for-write 'no-conversion))
                                            (write-region (plist-get response :data) nil temporary nil 'silent))
                                          (rename-file temporary destination t))
                                      (when (and temporary (file-exists-p temporary)) (delete-file temporary))))))
                            (error (cl-incf failures)))
                          (next (cdr remaining)))))
                    (when validator (list (cons "If-None-Match" validator))) nil nil nil nil t)))))))
      (next paths))))

(defun emacsos-assist-web--request
    (method path payload callback &optional headers allow-status array-type object-type
            git-typed-error raw-response)
  "Send METHOD to PATH with optional JSON PAYLOAD and HEADERS.

Invoke CALLBACK with (VALUE ERROR).  Report network and parsing failures as
ERROR rather than raising them from url-http's asynchronous callback.  Pass
ALLOW-STATUS only for a bounded structured non-2xx response the caller owns.
ARRAY-TYPE defaults to `list' and OBJECT-TYPE defaults to `alist'.
GIT-TYPED-ERROR opts only this caller into a bounded (:kind :status :text)
error instead of the legacy string.  A Git probe's nondiagnostic failure
does not downgrade a separate chat-accepted Git observation.
RAW-RESPONSE reads bounded asset bytes/validators instead of JSON."
  (let* ((emacsos-assist-web-max-response-bytes
          (if raw-response (+ emacsos-assist-web--asset-max-bytes emacsos-assist-web-max-header-bytes)
            emacsos-assist-web-max-response-bytes))
        (run-owner (emacsos-assist-web--run-http-owner method path))
        (request-tid (and (member method '("GET" "POST"))
                          emacsos-assist-web--thread-id))
        (canonical-thread-get
         (and (equal method "GET")
              emacsos-assist-web--thread-id
              (equal path (concat "threads/" emacsos-assist-web--thread-id))))
        (asset-intent (and canonical-thread-get emacsos-assist-web--asset-refresh-pending))
        (asset-refresh-generation emacsos-assist-web--refresh-generation)
        (git-thread-get
         (and git-typed-error (equal method "GET") request-tid
              (equal path (concat "threads/" request-tid "/git"))))
        (git-access-record
         (when (or canonical-thread-get git-thread-get)
           (emacsos-assist-web--thread-safety-record request-tid t)))
        (request-order
         (when git-access-record
           (cl-incf (plist-get git-access-record :git-request-order))))
        (git-get-owner (when git-thread-get (cons git-access-record request-order)))
        (canonical-get-owner
         (when canonical-thread-get (cons git-access-record request-order)))
        token token-error)
    (when canonical-thread-get (setq emacsos-assist-web--asset-refresh-pending nil))
    (condition-case error
        (setq token (emacsos-assist-web--read-token))
      ((error quit) (setq token-error (error-message-string error))))
    (if token-error
        (progn
          (emacsos-assist-web--http-access-status
           (current-buffer) method path nil (not git-typed-error) run-owner)
          (funcall callback nil
                   (if git-typed-error
                       (emacsos-assist-web--git-request-error
                        nil 'credentials)
                     token-error)))
      (if (not (emacsos-assist-web--safe-token-p token))
        (progn
          (emacsos-assist-web--http-access-status
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
            (emacsos-assist-web--http-access-status
             (current-buffer) method path nil (not git-typed-error) run-owner)
            (funcall callback nil
                     (if git-typed-error
                         (emacsos-assist-web--git-request-error
                          nil 'transport 'busy)
                       "Too many Assist Web requests are already running")))
        (let* ((url-request-method method)
               (url-request-extra-headers
                ;; url-http concatenates these with the UTF-8 body.  Even
                ;; multibyte ASCII from token/cache files would promote its
                ;; bytes to characters and expose the request in an error.
                (mapcar (lambda (header)
                          (cons (encode-coding-string (car header) 'utf-8)
                                (encode-coding-string (cdr header) 'utf-8)))
                        (append `(("Authorization" . ,(concat "Bearer " token))
                                  ("Accept" . ,(if raw-response "application/octet-stream" "application/json")))
                                (when payload '(("Content-Type" . "application/json")))
                                headers)))
               (url-request-data
		(and payload (encode-coding-string (json-encode payload) 'utf-8)))
               (url nil)
               (origin (current-buffer))
               (observed-http-status nil)
               (git-failure-notified nil)
               (asset-displayed nil)
               (finished nil)
               response process timer)
          (cl-labels
              ((finish (value problem &optional status kind detail)
		 (unless finished
                   ;; A failed canonical GET must classify access denial
                   ;; before completion becomes irreversible. Raw status
                   ;; notification may have been interrupted before latching.
                   (let ((inhibit-quit t))
                     (when (and problem (not git-failure-notified))
                       (setq git-failure-notified
                             (condition-case nil
                                 (emacsos-assist-web--http-access-status
                                  origin method path status (not git-typed-error)
                                  run-owner request-tid git-get-owner)
                               ((error quit) nil)))
                       (when (and (not git-failure-notified)
                                  canonical-thread-get
                                  (not git-typed-error)
                                  (buffer-live-p origin)
                                  (equal request-tid
                                         (buffer-local-value
                                          'emacsos-assist-web--thread-id origin)))
                         (with-current-buffer origin
                           (emacsos-assist-web--canonical-uncertain))))
                     (setq finished t)
                     (when (timerp timer) (cancel-timer timer))
                     (setq emacsos-assist-web--requests
			   (delq response emacsos-assist-web--requests))
                     (let ((emacsos-assist-web--asset-render-accepted
                            (and asset-intent
                                 (lambda ()
                                   (when (eq (current-buffer) origin)
                                     (setq asset-displayed t)))))
                           (emacsos-assist-web--current-canonical-get-owner
                            canonical-get-owner))
                       (funcall callback value
                                (if (and git-typed-error problem)
                                    (emacsos-assist-web--git-request-error
                                     status (or kind 'transport) detail)
                                  problem)))
                     (when (and asset-displayed value (not problem) (buffer-live-p origin))
                       (with-current-buffer origin
                         (when (and (= asset-refresh-generation emacsos-assist-web--refresh-generation)
                                    (equal (nth 0 asset-intent) emacsos-assist-web--thread-id)
                                    (= (nth 1 asset-intent) emacsos-assist-web--send-generation)
                                    (= (nth 2 asset-intent) emacsos-assist-web--asset-generation)
                                    (not emacsos-assist-web--denied))
                           (emacsos-assist-web--refresh-assets))))))))
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
                                               (emacsos-assist-web--http-access-status
                                                origin method path status nil
                                                run-owner request-tid git-get-owner)
                                             ((error quit) nil)))))
                               ;; url-http marks complete 4xx/5xx responses as errors.
                               (if (and (plist-get transport-status :error)
                                        (not (and raw-response (eql status 304)))
                                        (not (and allow-status
                                                  (integerp status)
                                                  (<= 400 status 599)
                                                  (equal (plist-get transport-status :error)
                                                         (list 'error 'http status)))))
				   (setq problem "Assist Web connection unavailable")
				 (condition-case parse-error
				     (setq value
                                           (if raw-response
                                               (emacsos-assist-web--asset-response response-buffer)
                                             (emacsos-assist-web--response-json
                                              response-buffer allow-status array-type object-type)))
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
                        (if raw-response
                            (lambda (active bytes)
                              ;; url-http otherwise expands every 304 through
                              ;; its disk cache even with caching disabled.
                              ;; Our validator refers only to the private cache.
                              (cl-letf (((symbol-function 'url-cache-extract) #'ignore))
                                (funcall url-filter active bytes)))
                          url-filter)
			(lambda (active problem)
			  (unless git-failure-notified
                            (setq git-failure-notified
                                  (emacsos-assist-web--http-access-status
                                   origin method path observed-http-status
                                   (not git-typed-error) run-owner
                                   request-tid git-get-owner)))
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
                                        (emacsos-assist-web--http-access-status
                                         origin method path status nil run-owner
                                         request-tid git-get-owner)))
                            ;; A non-denial status is parsed later.  It is
                            ;; not evidence that malformed JSON or transport
                            ;; failure proves thread access denial.
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
    (setq emacsos-assist-web--requests (delq response emacsos-assist-web--requests))
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
        ;; until the Run GET and canonical cache commit.
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
      (message "%s. Refresh checks server history; no message was resent."
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

(defun emacsos-assist-web--drain-events (target generation decoded-end)
  "Consume decoded SSE through DECODED-END for TARGET’s current observer.

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
                           (= generation emacsos-assist-web--stream-generation)))
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
                         (= generation emacsos-assist-web--stream-generation)))
              (emacsos-assist-web--stream-interrupted
               target "Assist event is too large")))
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
  (let ((token (condition-case nil (emacsos-assist-web--read-token)
                 (error nil))))
    (if (or (not (emacsos-assist-web--safe-token-p token))
            (>= (length emacsos-assist-web--requests)
                emacsos-assist-web-max-concurrent-requests))
        (emacsos-assist-web--stream-interrupted
         buffer (if (emacsos-assist-web--safe-token-p token)
                    "Too many Assist Web requests are already running"
                  "token missing or invalid"))
      (with-current-buffer buffer
        (emacsos-assist-web--sync-active-surface)
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
                (push response emacsos-assist-web--requests)
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

(defvar emacsos-assist-web--undo-output-buffer nil
  "Buffer whose outer presentation update owns undo rebasing.")
(defvar-local emacsos-assist-web--pending-input-undo nil
  "Native pending undo spine captured after this buffer's undo command.")
(defvar-local emacsos-assist-web--input-history-id nil
  "Canonical user message currently recalled, or nil at the present draft.")
(defvar-local emacsos-assist-web--input-history-draft nil
  "Unfinished input retained while browsing canonical input history.")

(defun emacsos-assist-web--remember-input-undo ()
  "Remember ownership of native undo, including a detached regional spine."
  (setq emacsos-assist-web--pending-input-undo
        (and (eq this-command 'undo) pending-undo-list)))

(defun emacsos-assist-web--shift-input-undo (shift)
  "Translate native undo positions by SHIFT, retaining shared list identities."
  (unless (zerop shift)
    (let ((work (list buffer-undo-list)) (seen (make-hash-table :test 'eq)))
      (when (and (consp emacsos-assist-web--pending-input-undo)
                 (eq emacsos-assist-web--pending-input-undo pending-undo-list))
        (push pending-undo-list work))
      (while work
        (let ((tail (pop work)))
          (while (and (consp tail) (not (gethash tail seen)))
            (puthash tail t seen)
            ;; Native redo links use these exact spines as hash keys/values.
            (when-let ((equivalent (gethash tail undo-equiv-table)))
              (push equivalent work))
            (setcar tail
                    (pcase (car tail)
                      (`(apply ,(and delta (pred integerp)) ,(and start (pred integerp))
                               ,(and end (pred integerp)) ,function . ,arguments)
                       `(apply ,delta ,(+ start shift) ,(+ end shift)
                               ,function ,@arguments))
                      (entry (undo-adjust-elt entry (list (cons 0 (- shift)))))))
            (setq tail (cdr tail))))))))

(defun emacsos-assist-web--preserve-input-undo (function &rest arguments)
  "Run FUNCTION with ARGUMENTS, excluding presentation edits from input undo.
Retain and rebase native undo when the input survives unchanged.  An internal
input replacement starts a new compose history; rejected operations that roll
back their input retain the original history at the outermost boundary."
  (if (or (not (derived-mode-p 'emacsos-assist-web-mode))
          (eq emacsos-assist-web--undo-output-buffer (current-buffer)))
      (apply function arguments)
    (let ((emacsos-assist-web--undo-output-buffer (current-buffer))
          (start (emacsos-assist-web--prompt-start))
          (input (emacsos-assist-web--input))
          (undo buffer-undo-list))
      (setq buffer-undo-list t)
      (unwind-protect
          (apply function arguments)
        (when (buffer-live-p emacsos-assist-web--undo-output-buffer)
          (with-current-buffer emacsos-assist-web--undo-output-buffer
            (setq buffer-undo-list undo)
            (if (and start (emacsos-assist-web--prompt-start)
                     (equal input (emacsos-assist-web--input)))
                (emacsos-assist-web--shift-input-undo
                 (- (emacsos-assist-web--prompt-start) start))
              (setq buffer-undo-list (and (eq undo t) t)
                    emacsos-assist-web--pending-input-undo nil
                    emacsos-assist-web--input-history-id nil
                    emacsos-assist-web--input-history-draft nil))))))))

(defun emacsos-assist-web--input-history-move (count)
  "Recall COUNT older canonical user messages; negative COUNT moves newer."
  (unless (zerop count)
    (let* ((start (or (emacsos-assist-web--prompt-start)
                      (user-error "No editable Assist input")))
           (messages (reverse
                      (seq-filter (lambda (message)
                                    (equal (alist-get 'role message) "user"))
                                  (alist-get 'messages emacsos-assist-web--snapshot))))
           (position (and emacsos-assist-web--input-history-id
                          (cl-position emacsos-assist-web--input-history-id messages
                                       :key (lambda (message) (alist-get 'id message))
                                       :test #'equal)))
           (target (+ (or position
                          (if (and emacsos-assist-web--input-history-id (< count 0))
                              0 -1)) count)))
      (unless (<= -1 target (1- (length messages)))
        (user-error (if (> count 0) "No earlier loaded input" "No newer input")))
      ;; Claim/recovery checks must precede both text and history-state changes.
      (let* ((draft (if emacsos-assist-web--input-history-id
                        emacsos-assist-web--input-history-draft
                      (emacsos-assist-web--input)))
             (message (and (>= target 0) (nth target messages)))
             (text (if message (alist-get 'text message) draft)))
        (undo-boundary)
        (atomic-change-group
          (goto-char start)
          (delete-region start (point-max))
          (insert text))
        (undo-boundary)
        (setq emacsos-assist-web--input-history-id (alist-get 'id message)
              emacsos-assist-web--input-history-draft (and message draft))))))

(defun emacsos-assist-web-previous-input (count)
  "Recall COUNT older loaded user messages, preserving the unfinished draft."
  (interactive "p")
  (emacsos-assist-web--input-history-move count))

(defun emacsos-assist-web-next-input (count)
  "Recall COUNT newer inputs, returning to the unfinished draft at the present."
  (interactive "p")
  (emacsos-assist-web--input-history-move (- count)))

(defun emacsos-assist-web--imenu-index ()
  "Index loaded canonical messages by role and short text at current positions."
  (let ((position (point-min)) (starts (make-hash-table :test 'equal))
        (ordinal 0) index)
    (while (< position (point-max))
      (when-let ((id (get-text-property position 'emacsos-assist-web-message-id)))
        (unless (gethash id starts) (puthash id position starts)))
      (setq position (next-single-property-change
                      position 'emacsos-assist-web-message-id nil (point-max))))
    (dolist (message (alist-get 'messages emacsos-assist-web--snapshot))
      (when-let ((start (gethash (alist-get 'id message) starts)))
        (push (cons (format "%d %s: %s" (cl-incf ordinal)
                            (alist-get 'role message)
                            (truncate-string-to-width
                             (replace-regexp-in-string
                              "[[:space:]]+" " " (alist-get 'text message))
                             60 nil nil "…"))
                    (copy-marker start))
              index)))
    (nreverse index)))

(defun emacsos-assist-web--replace-input (text)
  "Replace editable input after the prompt with TEXT without firing draft hooks."
  (when-let ((start (emacsos-assist-web--prompt-start)))
    (let ((inhibit-read-only t)
          (inhibit-modification-hooks t))
      (delete-region start (point-max))
      (goto-char start)
      (insert text))))

(defun emacsos-assist-web--write-prompt ()
  "Append the hidden protected prefix and a boundary above editable input."
  (let ((before (point)))
    ;; Install before the prompt itself, then follow later status/action
    ;; insertions at that boundary rather than deleting their entry on Send.
    (setq emacsos-assist-web--prompt-marker (copy-marker before nil))
    (insert emacsos-assist-web--prompt)
    (set-marker-insertion-type emacsos-assist-web--prompt-marker t)
    ;; A prompt field keeps ordinary line motion out of the protected prefix.
    (add-text-properties before (point)
                         '(read-only t field prompt front-sticky t rear-nonsticky t))
    (with-silent-modifications
      (emacsos-conversation--separator before t)
      (put-text-property (1+ before) (point) 'display "")
      (remove-text-properties before (point)
                              '(line-prefix nil wrap-prefix nil font-lock-face nil)))
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
  "Capture point, mark, and the one displayed phone window before a redraw."
  (when (and (markerp emacsos-assist-web--input-marker)
             (marker-buffer emacsos-assist-web--input-marker))
    (let ((window (get-buffer-window (current-buffer))))
      (list :point (emacsos-assist-web--anchor-at (point))
            :mark (and (mark t) (emacsos-assist-web--anchor-at (mark t)))
            :mark-active mark-active
            :window window
            :window-point (and window
                               (emacsos-assist-web--anchor-at
                                (window-point window)))
            :window-start (and window
                               (emacsos-assist-web--anchor-at
                                (window-start window)))))))

(defun emacsos-assist-web--restore-render-state (state)
  "Restore logical point, mark, and phone viewport from STATE after a redraw."
  (if (not state)
      (goto-char (point-max))
    (let ((window (plist-get state :window)))
      (when (plist-get state :mark)
        (set-mark (emacsos-assist-web--resolve-anchor (plist-get state :mark)))
        (setq mark-active (plist-get state :mark-active)))
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

(defun emacsos-assist-web--ack-thread-read (tid revision)
  "Acknowledge TID's rendered snapshot REVISION through POST /open.
A failed receipt leaves rendering intact.  The server conditionally clears
notifications only while their read-receipt identity still matches.
Nil REVISION sends an empty body for legacy unconditional acknowledgment."
  (condition-case nil
      (emacsos-assist-web--request
       "POST" (format "threads/%s/open" (emacsos-assist-web--require-id tid))
       (when revision `((revision . ,revision))) #'ignore)
    (error nil)))

(defun emacsos-assist-web--ack-rendered-thread (snapshot)
  "Acknowledge a settled SNAPSHOT rendered in a visible thread window.
Hidden, cached and failed views do not acknowledge unread notifications."
  (when (and (get-buffer-window (current-buffer) 'visible)
             (member (alist-get 'status (alist-get 'thread snapshot))
                     emacsos-assist-web--settled-snapshot-statuses))
    (emacsos-assist-web--ack-thread-read
     emacsos-assist-web--thread-id
     (alist-get 'revision (alist-get 'thread snapshot)))))

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
    (let* ((thread (alist-get 'thread snapshot))
           (thread-label
            (emacsos-assist-web--thread-label
             `((description . ,(alist-get 'description thread))
               (repo_label . ,(alist-get
                               'repo_label (alist-get 'workspace thread))))))
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
            emacsos-assist-web--pending-rendered-p nil
            imenu--index-alist nil)
      (when (or emacsos-assist-web--canonical-buffer-name-p
                (equal (buffer-name) "*assist New thread*")
                (equal (buffer-name)
                       (format "*assist Thread <%s>*"
                               emacsos-assist-web--thread-id)))
        (setq emacsos-assist-web--canonical-buffer-name-p t)
        (rename-buffer
         (format "%s <%s>" thread-label emacsos-assist-web--thread-id) t))
      (emacsos-assist-web-git--sync-keys)
      (emacsos-assist-web--set-workspace-directory)
      (emacsos-conversation--flush-images)
      (erase-buffer)
      (let ((transcript-start (point)))
        (insert (format "%s%s\n" thread-label (if stale " [cached]" "")))
        (setq emacsos-assist-web--status-start (copy-marker (point) nil))
        (insert (format "[%s%s]" (or emacsos-assist-web--stream-status
                                     (alist-get 'status thread))
                        (if-let ((error (alist-get 'error thread)))
                            (concat ": " error) "")))
        (setq emacsos-assist-web--status-end (copy-marker (point) nil))
        (insert "\n\n")
        (when (or (equal (alist-get 'status thread) "awaiting_approval")
                  (and (integerp (alist-get 'approval_count thread))
                       (> (alist-get 'approval_count thread) 0))
                  (eq (alist-get 'approval_results thread) t))
          (let ((source (current-buffer)))
            (insert-text-button
             (if (or (equal (alist-get 'status thread) "awaiting_approval")
                     (> (or (alist-get 'approval_count thread) 0) 0))
                 "Review pending action" "Approvals and results") 'follow-link t
             'action (lambda (_) (emacsos-assist-web-review-approval source)))
            (insert "\n\n")))
        (let ((emacsos-conversation--image-work-budget (cons (* 1024 1024) 16))
              (emacsos-conversation--image-cache (make-hash-table :test 'equal))
              (emacsos--chat-presentation-max-bytes
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
                (let ((assistant-start (+ (point) 2)))
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
        (when (equal (alist-get 'status thread) "error")
          (insert (propertize
                   (concat "Thread error: "
                           (or (alist-get 'error thread) "Run failed.") "\n\n")
                   'face 'error)))
        (add-text-properties transcript-start (point)
                             '(read-only t front-sticky t rear-nonsticky t))
        (emacsos-assist-web--write-prompt)
        (if draft (insert draft) (emacsos-assist-web--restore-draft))
        (emacsos-assist-web--restore-render-state render-state)
        (setq buffer-read-only nil)
        (set-buffer-modified-p nil)
        (prog1 (emacsos-assist-web--save-draft)
          (when emacsos-assist-web--asset-render-accepted
            (funcall emacsos-assist-web--asset-render-accepted)))))))

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

(defun emacsos-assist-web--draft-target ()
  "Return this draft's actual existing-thread or new-thread destination."
  (or emacsos-assist-web--thread-id
      (list emacsos-assist-web--draft-id emacsos-assist-web--draft-repository
            (or emacsos-assist-web--draft-harness "deepagents"))))

(defun emacsos-assist-web--save-draft (&optional text)
  "Save editable TEXT and the one HTTP retry identity, never accepted Runs."
  (if-let ((name (emacsos-assist-web--draft-cache-name)))
      (emacsos-assist-web--try-write-cache
       name `((text . ,(or text (emacsos-assist-web--input) ""))
              (pending_key . ,(plist-get emacsos-assist-web--http-draft :key))
              (submitted_text . ,(plist-get emacsos-assist-web--http-draft :text))
              (pending_target . ,(plist-get emacsos-assist-web--http-draft :target))
              (repo_key . ,emacsos-assist-web--draft-repository)
              (harness . ,emacsos-assist-web--draft-harness)))
    t))

(defun emacsos-assist-web--after-change (&rest _)
  "Debounce editable draft saving without changing an in-flight request."
  (when (and (derived-mode-p 'emacsos-assist-web-mode)
             (not inhibit-modification-hooks))
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



(defun emacsos-assist-web--restore-draft ()
  "Restore editable text and an unchanged HTTP retry without starting work.
Import unsent older local queue/follow-up text into the editable draft.  Accepted
Runs remain server history and are never re-submitted from a saved client FIFO."
  (when-let* ((name (emacsos-assist-web--draft-cache-name))
              (draft (emacsos-assist-web--read-cache name)))
    (let* ((text (alist-get 'text draft))
           (legacy (or (assq 'queue draft) (assq 'follow_ups draft)
                       (assq 'pending_accepted draft)))
           (key (alist-get 'pending_key draft))
           (submitted (alist-get 'submitted_text draft))
           (parts (append
                   (when (assq 'queue draft)
                     (delq nil
                           (mapcar (lambda (entry)
                                     (when (member (alist-get 'state entry)
                                                   '("queued" "posting" "acceptance-unknown"
                                                     "retryable-rejected" "recovered-head"))
                                       (alist-get 'text entry)))
                                   (alist-get 'queue draft))))
                   (mapcar (lambda (entry) (alist-get 'text entry))
                           (alist-get 'follow_ups draft))
                   (list (alist-get 'recovery_draft draft)
                         (unless (and (not (assq 'queue draft))
                                      (alist-get 'pending_accepted draft)
                                      (equal text submitted))
                           text)))))
      (when-let ((unconfirmed
                  (seq-find (lambda (entry)
                              (member (alist-get 'state entry)
                                      '("posting" "acceptance-unknown" "retryable-rejected")))
                            (alist-get 'queue draft))))
        (setq key (alist-get 'key unconfirmed)
              submitted (alist-get 'text unconfirmed)))
      (when (and (not (alist-get 'pending_accepted draft))
                 (stringp key)
                 (string-match-p emacsos-assist-web--idempotency-regexp key)
                 (stringp submitted))
        (setq emacsos-assist-web--http-draft (list :key key :text submitted
                                            :target (if (assq 'pending_target draft)
                                                        (alist-get 'pending_target draft)
                                                      (or emacsos-assist-web--thread-id
                                                          (list emacsos-assist-web--draft-id
                                                                (alist-get 'repo_key draft)
                                                                (or (alist-get 'harness draft)
                                                                    "deepagents"))))))
        (when (and legacy (not (member submitted parts)))
          (push submitted parts)))
      (unless emacsos-assist-web--draft-repository
        (setq emacsos-assist-web--draft-repository (alist-get 'repo_key draft)))
      (unless emacsos-assist-web--draft-harness
        (setq emacsos-assist-web--draft-harness (alist-get 'harness draft)))
      (emacsos-assist-web--replace-input
       (string-join (seq-filter (lambda (part) (and (stringp part) (not (string-empty-p part))))
                                parts)
                    "\n\n")))))

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
                                             (emacsos-assist-web--state-pill thread)))
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

(defun emacsos-assist-web--state-pill (thread)
  "Return THREAD's status token using the web list's precedence.
Busy beats error, urgent, unread, and unmerged, in that order.  Otherwise
return the raw stage.  Indicator tokens are fixed literals.
The wire's unmerged field is true, false, or null (unavailable/not checked).
Only true draws an indicator; legacy string yes is also accepted."
  (let ((status (alist-get 'status thread))
        (unmerged (alist-get 'unmerged thread)))
    (cond
     ((member status
              '("queued" "cloning" "starting_sandbox" "processing"
                "paused" "initializing"))
      "🔄")
     ((equal status "error")
      "🛑")
     ((alist-get 'urgent thread)
      "⚠️")
     ((alist-get 'unread thread)
      "📬")
     ((or (equal unmerged "yes") (eq unmerged t))
      "🔀")
     (t status))))

(defun emacsos-assist-web--fit-list-line (text width)
  "Fit TEXT into WIDTH frame columns with a visible truncation marker.
The graphical phone measures proportional text against the same pixel budget."
  (if (and (bound-and-true-p emacsos-proportional-button-labels)
           (display-graphic-p))
      (emacsos--fit-pixel-width text (* width (frame-char-width)))
    (truncate-string-to-width text width nil nil "…")))

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
    ;; Canonical refresh acknowledges only successfully
    ;; rendered settled snapshots; cached views and read-only probes do not.
    ;; Opening can fetch the branch while cached files remain usable.
    (with-current-buffer buffer
      (when (and emacsos-assist-web--snapshot
                 (not (emacsos-assist-web-git--gate-reason t)))
        (condition-case nil
            (let ((metadata
                   (emacsos-assist-web-git--metadata-from-snapshot
                    emacsos-assist-web--snapshot)))
              (emacsos-assist-web-git--note metadata)
              (emacsos-assist-web-git--enqueue metadata nil))
          (error nil))))
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
      (message "Refreshing threads…")
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

(defun emacsos-assist-web--refresh-observed-run (buffer)
  "Verify BUFFER's transient observed Run before canonical history retirement.
This reads server truth once; it neither persists accepted Runs nor retries a send."
  (with-current-buffer buffer
    (let* ((tid emacsos-assist-web--thread-id)
           (run-id emacsos-assist-web--run-id)
           (serial (cl-incf emacsos-assist-web--run-check-generation))
           (auth-start (progn (emacsos-assist-web--run-recheck-start tid run-id)
                              emacsos-assist-web--auth-epoch)))
      (emacsos-assist-web--request
       "GET" (format "threads/%s/runs/%s" (emacsos-assist-web--require-id tid)
                     (emacsos-assist-web--require-id run-id)) nil
       (lambda (value problem)
         (when (buffer-live-p buffer)
           (with-current-buffer buffer
             (when (and (equal tid emacsos-assist-web--thread-id)
                        (equal run-id emacsos-assist-web--run-id)
                        (= serial emacsos-assist-web--run-check-generation))
               (condition-case nil
                   (if problem (error "Observed Run unavailable")
                     (let ((status (emacsos-assist-web--exact-run-status value tid run-id)))
                       (when (emacsos-assist-web--run-read-superseded-p tid run-id auth-start)
                         (error "Observed Run authority changed"))
                       (emacsos-assist-web-refresh-thread buffer run-id status auth-start)))
                 (error (emacsos-assist-web--set-unverified-status
                         "Run status unavailable or invalid; Refresh retries, no message resent")))))))))))

(defun emacsos-assist-web-refresh-thread
    (&optional buffer completed-run-id verified-outcome verified-start-epoch explicit)
  "Fetch and render BUFFER's canonical thread snapshot asynchronously.

COMPLETED-RUN-ID is retired only with its exact VERIFIED-OUTCOME;
VERIFIED-START-EPOCH fences later Run access denial.  EXPLICIT is the user’s
Refresh action and replaces only this view’s transient observer."
  (interactive (list nil nil nil nil t))
  (let ((buffer (or buffer (current-buffer))))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (when explicit
          (setq emacsos-assist-web--asset-refresh-pending
                (list emacsos-assist-web--thread-id emacsos-assist-web--send-generation
                      (cl-incf emacsos-assist-web--asset-generation)))
          (emacsos-assist-web--stream-cleanup t t))
        (if (and emacsos-assist-web--thread-id emacsos-assist-web--run-id
                 emacsos-assist-web--pending-accepted-p (not verified-outcome))
            (emacsos-assist-web--refresh-observed-run buffer)
          (when emacsos-assist-web--thread-id
          (let ((tid (emacsos-assist-web--require-id emacsos-assist-web--thread-id))
                (generation (cl-incf emacsos-assist-web--refresh-generation))
                (send-generation emacsos-assist-web--send-generation)
                (git-auth-start-epoch emacsos-assist-web--auth-epoch)
                (git-reconcile-token
                 (emacsos-assist-web--canonical-start))
                (handled nil))
            (message "Refreshing thread…")
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
                           (emacsos-assist-web--canonical-failed
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
                                                  emacsos-assist-web--auth-epoch)))
                               (error "thread access changed during exact Run reconciliation"))
                             (when (and completed-run-id verified-start-epoch
                                        (emacsos-assist-web--run-read-superseded-p
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
                                                (emacsos-assist-web--save-draft)))
                                   (error "exact Run retirement could not be saved"))
                                 ;; Canonical history and editable text are saved before retiring
                                 ;; this transient observer; no accepted Run is stored in drafts.
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
                                   (emacsos-assist-web--run-status-confirmed
                                    tid completed-run-id verified-start-epoch)))
                               (when busy
                                 (setq emacsos-assist-web--stream-status nil))
                               (when (and cached busy completed-run-id
                                          (integerp verified-start-epoch)
                                          (not retiring))
                                 (emacsos-assist-web--canonical-authorized
                                  git-auth-start-epoch)
                                 (emacsos-assist-web--run-status-confirmed
                                  tid completed-run-id verified-start-epoch))
                               (when retiring
                                 (emacsos-assist-web--git-note-safely
                                  value (and (equal verified-outcome "success")
                                             completed-run-id)
                                  git-auth-start-epoch git-reconcile-token completed-run-id))
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
                                       (force-mode-line-update t)
                                       (message (if cached "Thread refreshed"
                                                  "Thread refreshed; local cache write failed"))
                                       (emacsos-assist-web--ack-rendered-thread value)
                                       (when (and cached completed-run-id
                                                  (member verified-outcome '("pending" "running" "transitioning"))
                                                  (not emacsos-assist-web--in-flight)
                                                  (not emacsos-assist-web--denied))
                                         (unless emacsos-assist-web--pending-rendered-p
                                           (emacsos-assist-web--append-pending
                                            emacsos-assist-web--submitted-text))
                                         (setq emacsos-assist-web--in-flight t)
                                         (emacsos-assist-web--observe-run buffer)))
                                     (unless (or retiring cached)
                                       (emacsos-assist-web--git-note-safely
                                        value nil git-auth-start-epoch
                                        git-reconcile-token)))
                                 ((error quit)
                                  (if (or retiring cached)
                                      (condition-case nil
                                          (progn
                                            (setq emacsos-assist-web--display-recovery t)
                                            (emacsos-assist-web--show-display-recovery)
                                            (emacsos-assist-web--set-status
                                             "Saved; Refresh to display")
                                            (message "Saved; Refresh to display"))
                                        ((error quit)
                                         (message "Saved; Refresh to display")))
                                    (signal (car display-problem)
                                            (cdr display-problem)))))
                               ))
                           (error
                          (emacsos-assist-web--canonical-failed
                           git-reconcile-token)
                          (if emacsos-assist-web--pending-accepted-p
                              (emacsos-assist-web--set-unverified-status
                               "refresh rejected; C-c C-a g retries")
                            (emacsos-assist-web--set-status
                             (if emacsos-assist-web--snapshot
                                 "refresh rejected; cached; C-c C-a g retries"
                               "refresh rejected; C-c C-a g retries")))
                          (message "Thread refresh rejected: %s"
                                   (error-message-string problem)))))))))))))))))

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



(defun emacsos-assist-web--message-fits-p (text &optional existing-thread-id)
  "Return non-nil when TEXT fits the server's ordinary message body limits."
  (and (<= (length text) 64000)
       (<= (string-bytes (json-encode
                         (if existing-thread-id `((message . ,text))
                           `((message . ,text)
                             (repo_key . ,emacsos-assist-web--draft-repository)
                             (harness . ,(or emacsos-assist-web--draft-harness "deepagents"))))))
           66000)))

(defun emacsos-assist-web-send ()
  "Submit editable text through the server's ordinary busy-thread admission.
Keep only a pending HTTP identity.  Failures restore editable text for explicit
retry; accepted Runs and scheduling belong to the server, not a client FIFO."
  (interactive)
  (if (not (derived-mode-p 'emacsos-assist-web-mode))
      (message "Open an Assist Web thread before sending")
    (let ((text (emacsos-assist-web--input)))
    (cond
     ((eq emacsos--assist-active-surface 'chat)
      (message "Another local chat response is active; editable draft retained"))
     ((plist-get emacsos-assist-web--http-draft :posting)
      (message "Waiting for HTTP acceptance; editable draft retained"))
     ((string-empty-p (string-trim text)) (message "Nothing to send"))
     ((not (emacsos-assist-web--message-fits-p text emacsos-assist-web--thread-id))
      (emacsos-assist-web--set-status "Message too large; editable draft retained"))
     (t
      (let* ((old emacsos-assist-web--http-draft)
             (target (emacsos-assist-web--draft-target))
             (same (and old (equal text (plist-get old :text))
                        (equal target (plist-get old :target))))
             (request (list :text text :target target
                            :key (if same (plist-get old :key)
                                   (emacsos-assist-web--new-idempotency-key))
                            :posting t))
             (thread-id emacsos-assist-web--thread-id)
             (buffer (current-buffer))
             (source-cache (emacsos-assist-web--draft-cache-name)))
        (setq emacsos-assist-web--http-draft request)
        (if (not (condition-case nil (emacsos-assist-web--save-draft)
                   ((error quit) nil)))
            (progn
              (setf (plist-get request :posting) nil)
              (setq emacsos-assist-web--http-draft old)
              (message "Not submitted; local draft could not be saved"))
          (cl-incf emacsos-assist-web--refresh-generation)
          (message (if (and old (not same))
                       "Sending as a new request; earlier acceptance may be unknown"
                     "Sending; awaiting HTTP acceptance"))
          (condition-case nil
(emacsos-assist-web--request
           "POST" (if thread-id (format "threads/%s/messages" (emacsos-assist-web--require-id thread-id))
                    "threads")
           (if thread-id `((message . ,text))
             `((message . ,text) (repo_key . ,emacsos-assist-web--draft-repository)
               (harness . ,(or emacsos-assist-web--draft-harness "deepagents"))))
           (lambda (value error)
             (when (buffer-live-p buffer)
               (with-current-buffer buffer
                 (when (eq request emacsos-assist-web--http-draft)
                   (setf (plist-get request :posting) nil)
                   (when (equal target (emacsos-assist-web--draft-target))
                   (let ((tid (alist-get 'thread_id value))
                         (run-id (alist-get 'run_id value)))
                     (if (or error (not (emacsos-assist-web--valid-id-p tid))
                             (not (emacsos-assist-web--valid-id-p run-id))
                             (and thread-id (not (equal tid thread-id)))
                             (not (equal target (emacsos-assist-web--draft-target))))
                         (progn
                           (unless (string-prefix-p text (emacsos-assist-web--input))
                             (emacsos-assist-web--replace-input
                              (concat text "\n\n" (emacsos-assist-web--input))))
                           (emacsos-assist-web--save-draft)
                           (emacsos-assist-web--set-status
                            (if (integerp (alist-get 'http_status value))
                                (format "Send rejected (HTTP %d); text retained; retry explicitly"
                                        (alist-get 'http_status value))
                              "Send failed; connection or acceptance unconfirmed. Text retained; retry explicitly")))
                       (if-let ((existing (and (not thread-id)
                                               (emacsos-assist-web--thread-buffer tid))))
                           ;; A timed-out creation may already be open from the catalog.
                           ;; Keep that canonical owner and its editable draft untouched.
                           (let ((tail (string-remove-prefix text (emacsos-assist-web--input))))
                             (if (not (let ((emacsos-assist-web--http-draft nil))
                                        (emacsos-assist-web--save-draft tail)))
                                 (emacsos-assist-web--set-status
                                  "Server accepted; local draft save failed; retry identity retained")
                               (setq emacsos-assist-web--http-draft nil)
                               (emacsos-assist-web--replace-input tail)
                               (emacsos-assist-web--set-status
                                "Message accepted; additional text remains a separate local draft")
                               (display-buffer existing)
                               (message "Accepted thread already open; unsent text retained in %s"
                                        (buffer-name buffer))))
                         (progn
                       (cl-incf emacsos-assist-web--refresh-generation)
                       (unless thread-id
                         (setq emacsos-assist-web--thread-id tid
                               emacsos-assist-web--draft-id nil)
                         (setf (plist-get request :target) tid))
                       (let ((tail (string-remove-prefix text (emacsos-assist-web--input))))
                         (if (not (let ((emacsos-assist-web--http-draft nil))
                                    (emacsos-assist-web--save-draft tail)))
                             (emacsos-assist-web--set-status
                              "Server accepted; local draft save failed. Unchanged retry keeps its key")
                           (setq emacsos-assist-web--http-draft nil)
                           (emacsos-assist-web--replace-input tail)
                           (when (and (not thread-id) source-cache)
                             (emacsos-assist-web--delete-cache source-cache))))
                       (if emacsos-assist-web--in-flight
                           ;; Keep the current response display.  Later accepted Runs
                           ;; are already in canonical server history, not a local FIFO.
                           (emacsos-assist-web--set-status "Message accepted; current response continues")
                         (cl-incf emacsos-assist-web--send-generation)
                         (setq emacsos-assist-web--run-id run-id
                               emacsos-assist-web--pending-key (plist-get request :key)
                               emacsos-assist-web--submitted-text text
                               emacsos-assist-web--pending-accepted-p t
                               emacsos-assist-web--in-flight t)
                         (emacsos-assist-web--append-pending text)
                         (emacsos-assist-web--observe-run buffer)))))))))))
           `(("Idempotency-Key" . ,(plist-get request :key))) t)
((error quit)
 (when (eq request emacsos-assist-web--http-draft)
  (setf (plist-get request :posting) nil)
  (emacsos-assist-web--set-status
   "Send interrupted; text retained; retry unchanged to check acceptance")))))))))))

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

(defun emacsos-assist-web--set-workspace-directory ()
  "Use this thread's existing checkout, or home when unavailable."
  (setq default-directory
        (or (condition-case nil
                (emacsos-assist-web-git-local-directory)
              (error nil))
            (expand-file-name "~/"))))

(defun emacsos-assist-web-find-file (&optional file)
  "Visit FILE without interpreting file or directory local settings.
Assist buffers select their checkout or home first; other buffers retain their
directory.  FILE is not confined to that directory.  With nil FILE, use the
ordinary interactive `find-file' prompt and navigation."
  (interactive)
  (when (derived-mode-p 'emacsos-assist-web-mode)
    (emacsos-assist-web--set-workspace-directory))
  (let ((enable-local-variables nil)
        (enable-local-eval nil)
        (enable-dir-local-variables nil))
    (if file
        (find-file file)
      (call-interactively #'find-file))))

(defun emacsos-assist-web-refresh-context ()
  "Refresh a thread and its local Git checkout, or refresh the thread catalog."
  (interactive)
  (if (and (derived-mode-p 'emacsos-assist-web-mode)
           emacsos-assist-web--thread-id)
      (progn
        (call-interactively #'emacsos-assist-web-refresh-thread)
        ;; The checkout may have been removed since this buffer selected it.
        (let ((default-directory (expand-file-name "~/")))
          (call-interactively #'emacsos-assist-web-git-refresh)))
    (call-interactively #'emacsos-assist-web-refresh-threads)))

(defun emacsos-assist-web--move-message (forward)
  "Move to a message boundary or the compose input when FORWARD is non-nil."
  (let ((input (emacsos-assist-web--prompt-start))
        (position (point-min)) starts)
    (while (< position (or input (point-max)))
      (when (get-text-property position 'emacsos-conversation-message-start)
        (push position starts))
      (setq position (next-single-property-change
                      position 'emacsos-conversation-message-start nil
                      (or input (point-max)))))
    (setq starts (nreverse starts))
    (when (and input forward)
      (setq starts (append starts (list input))))
    (when-let ((target (if forward
                          (seq-find (lambda (start) (> start (point))) starts)
                        (car (last (seq-filter
                                    (lambda (start) (< start (point))) starts))))))
      (goto-char target))))

(defun emacsos-assist-web-previous-message ()
  "Move to the previous message boundary without changing or sending input."
  (interactive)
  (emacsos-assist-web--move-message nil))

(defun emacsos-assist-web-next-message ()
  "Move to the next message, ending at editable input without wrapping."
  (interactive)
  (emacsos-assist-web--move-message t))



(defun emacsos-assist-web--sync-active-surface ()
  "Reflect live response observation without reserving other thread sends."
  (unless (eq emacsos--assist-active-surface 'chat)
    (setq emacsos--assist-active-surface
          (and (seq-some (lambda (buffer)
                           (buffer-local-value 'emacsos-assist-web--in-flight buffer))
                         (buffer-list))
               'web))))

(defun emacsos-assist-web-save-draft ()
  "Save this thread's editable text without submitting it."
  (interactive)
  (unless (derived-mode-p 'emacsos-assist-web-mode)
    (user-error "Open an Assist Web thread before saving its draft"))
  (unless (emacsos-assist-web--save-draft)
    (user-error "Draft could not be saved locally"))
  (set-buffer-modified-p nil)
  (message "Draft saved"))

(define-derived-mode emacsos-assist-web-mode text-mode "Assist Web"
  "Major mode for a canonical Assist Web thread or unsent local draft."
  (emacsos-assist-web--set-workspace-directory)
  (emacsos--chat-enable-presentation)
  (setq-local imenu-create-index-function #'emacsos-assist-web--imenu-index)
  (emacsos-conversation-install-actions
   '((send . emacsos-assist-web-send)
     (abort . emacsos-assist-web-abort)
     (refresh . emacsos-assist-web-refresh-thread)
     (older . emacsos-assist-web-load-older)
     (open-object . emacsos-conversation--open-object)
     (catalog . emacsos-assist-web-refresh-threads)))
  (add-hook 'after-change-functions #'emacsos-assist-web--after-change nil t)
  (add-hook 'post-command-hook #'emacsos-assist-web-git--sync-keys nil t)
  (add-hook 'post-command-hook #'emacsos-assist-web--remember-input-undo nil t)
  (add-hook 'kill-buffer-hook #'emacsos-assist-web-git--teardown nil t)
  (add-hook 'kill-buffer-hook #'emacsos-assist-web--buffer-killed nil t)
  (add-hook 'kill-buffer-hook #'emacsos-assist-web--asset-cleanup nil t))

(define-key emacsos-assist-web-mode-map (kbd "C-x C-s") #'emacsos-assist-web-save-draft)

(define-key emacsos-assist-web-mode-map (kbd "M-p")
            #'emacsos-assist-web-previous-input)
(define-key emacsos-assist-web-mode-map (kbd "M-n")
            #'emacsos-assist-web-next-input)

(define-key emacsos-assist-web-mode-map (kbd "C-x C-f")
            #'emacsos-assist-web-find-file)

(define-key emacsos-assist-web-mode-map (kbd "C-c b")
            #'emacsos-assist-web-previous-message)
(define-key emacsos-assist-web-mode-map (kbd "C-c f")
            #'emacsos-assist-web-next-message)

(define-key emacsos-assist-web-mode-map (kbd "RET")
            #'emacsos-conversation-activate-or-newline)

(defun emacsos-assist-web--retire-active-streams-after-reload ()
  "Close obsolete observation callbacks without submitting any message."
  (dolist (buffer (buffer-list))
    (when (and (buffer-live-p buffer)
               (with-current-buffer buffer
                 (derived-mode-p 'emacsos-assist-web-mode)))
      (with-current-buffer buffer
        (when emacsos-assist-web--stream-process
          (emacsos-assist-web--stream-cleanup t t))))))

;; Reloading this file invalidates callbacks created by its previous function
;; definitions.  Retire active stream callbacks before advancing the catalog
;; generation; ordinary in-flight request callbacks release their refresh claim
;; when they observe that generation change.
(emacsos-assist-web--retire-active-streams-after-reload)
(cl-incf emacsos-assist-web--catalog-generation)
(emacsos-assist-web--cancel-pending-new-thread)
(emacsos-assist-web--load-catalog)

(defun emacsos-assist-web--require-email-approval (value tid)
  "Validate the complete bounded approval response VALUE for TID."
  (unless (and (emacsos-assist-web--object-p value)
               (equal (alist-get 'thread_id value) tid)
               (<= (string-bytes (json-encode value)) (* 512 1024)))
    (error "Invalid Assist approval response"))
  (when-let ((proposal (alist-get 'proposal value)))
    (let* ((kind (alist-get 'kind proposal))
           (action (alist-get 'action proposal))
           (args (alist-get 'args action))
           (messages (alist-get 'messages proposal)))
      (unless (and (emacsos-assist-web--object-p proposal)
                   (member kind '("send_email" "email_archive" "email_delete"))
                   (emacsos-assist-web--object-p action)
                   (equal kind (alist-get 'name action))
                   (emacsos-assist-web--object-p args)
                   (stringp (alist-get 'token proposal))
                   (string-match-p "\\`[A-Za-z0-9_-]\\{16,128\\}\\'"
                                   (alist-get 'token proposal)))
        (error "Invalid Assist approval proposal"))
      (if (equal kind "send_email")
          (progn
            (dolist (text (list (alist-get 'from proposal) (alist-get 'cc proposal)
                                (alist-get 'to args) (alist-get 'subject args)))
              (unless (emacsos-conversation-valid-text-p text)
                (error "Invalid Assist email header")))
            (unless (emacsos-assist-web--valid-message-text-p
                     (and (stringp (alist-get 'body args))
                          (emacsos-assist-web--canonical-message-text (alist-get 'body args))))
              (error "Invalid Assist email body")))
        (unless (or (and (stringp (alist-get 'error proposal))
                         (not (string-empty-p (alist-get 'error proposal)))
                         (emacsos-assist-web--valid-message-text-p (alist-get 'error proposal))
                         (null messages))
                    (and (listp messages) messages (<= (length messages) 100)
                         (equal (alist-get 'message_ids args)
                                (mapcar (lambda (message) (alist-get 'id message)) messages))))
          (error "Invalid Assist mailbox preview"))
        (dolist (message messages)
          (let ((id (alist-get 'id message)))
            (unless (and (emacsos-assist-web--object-p message)
                         (stringp id) (<= 1 (length id) 512)
                         (not (member id '("." "..")))
                         (not (string-match-p "[\0-\37\177/\\\\\uD800-\uDFFF]" id)))
              (error "Invalid Assist mailbox message identity")))
          (dolist (field '(from to date subject))
            (unless (emacsos-conversation-valid-text-p (alist-get field message))
              (error "Invalid Assist mailbox header")))
          (unless (emacsos-assist-web--valid-message-text-p
                   (and (stringp (alist-get 'body message))
                        (emacsos-assist-web--canonical-message-text (alist-get 'body message))))
            (error "Invalid Assist mailbox body"))))))
  (alist-get 'proposal value))

(defun emacsos-assist-web--require-approval (value tid)
  "Validate one complete approval VALUE belonging to thread TID."
  (let* ((proposal (alist-get 'proposal value))
         (kind (alist-get 'kind proposal)))
    (cond
     ((equal (alist-get 'state proposal) "unavailable")
      (unless (and (equal (alist-get 'thread_id value) tid)
                   (member kind '("send_email" "email_archive" "email_delete"))
                   (emacsos-assist-web--valid-message-text-p (alist-get 'error proposal))
                   (null (alist-get 'decisions proposal)))
        (error "Invalid unavailable approval"))
      proposal)
     ((or (null proposal) (member kind '("send_email" "email_archive" "email_delete")))
      (emacsos-assist-web--require-email-approval value tid))
     (t
      (unless (and (emacsos-assist-web--object-p value)
                   (equal (alist-get 'thread_id value) tid)
                   (<= (string-bytes (json-encode value)) (* 512 1024))
                   (emacsos-assist-web--object-p proposal)
                   (stringp (alist-get 'token proposal))
                   (string-match-p "\\`[A-Za-z0-9_-]\\{16,128\\}\\'" (alist-get 'token proposal))
                   (member (alist-get 'state proposal) '("pending" "accepted" "approved" "declined" "importing" "ready" "failed" "expired"))
                   (listp (alist-get 'decisions proposal)))
        (error "Invalid Assist approval response"))
      (pcase kind
        ("send_reply"
         (setq proposal (copy-tree proposal))
         (let ((args (alist-get 'args (alist-get 'action proposal))))
           (when (stringp (alist-get 'text args))
             (setf (alist-get 'text args)
                   (emacsos-assist-web--canonical-message-text (alist-get 'text args)))))
         (unless (and (emacsos-conversation-valid-text-p (alist-get 'sender proposal))
                      (equal (alist-get 'name (alist-get 'action proposal)) "send_reply")
                      (emacsos-assist-web--valid-message-text-p
                       (alist-get 'text (alist-get 'args (alist-get 'action proposal)))))
           (error "Invalid reply preview")))
        ("egress"
         (unless (and (emacsos-conversation-valid-text-p (alist-get 'host proposal))
                      (<= 1 (length (alist-get 'host proposal)) 253)
                      (integerp (alist-get 'port proposal))
                      (<= 1 (alist-get 'port proposal) 65535)
                      (emacsos-assist-web--valid-message-text-p (alist-get 'task proposal))
                      (emacsos-assist-web--valid-message-text-p (alist-get 'main_task proposal))
                      (emacsos-conversation-valid-text-p (alist-get 'lifetime proposal)))
           (error "Invalid network preview")))
        ("geo_download"
         (unless (and (emacsos-conversation-valid-text-p (alist-get 'slug proposal))
                      (emacsos-conversation-valid-text-p (alist-get 'display_name proposal))
                      (emacsos-assist-web--valid-message-text-p (alist-get 'warning proposal))
                      (or (null (alist-get 'size_bytes proposal))
                          (and (integerp (alist-get 'size_bytes proposal))
                               (>= (alist-get 'size_bytes proposal) 0))))
           (error "Invalid download preview")))
        (_ (error "Unsupported Assist approval kind")))
      (let ((pending (cond ((equal kind "egress") '("hour" "always" "decline"))
                           ((equal kind "send_reply") '("approve" "edit" "reject"))
                           (t '("approve" "reject"))))
            (decisions (alist-get 'decisions proposal)))
        (unless (if (equal (alist-get 'state proposal) "pending")
                    (and (seq-every-p #'stringp decisions)
                         (equal (sort (copy-sequence decisions) #'string<)
                                (sort (copy-sequence pending) #'string<)))
                  (or (and (equal kind "egress")
                           (equal (alist-get 'state proposal) "approved")
                           (equal decisions '("revoke")))
                      (null decisions)))
          (error "Invalid Assist approval decisions")))
      proposal))))

(defun emacsos-assist-web--approval-response (value tid)
  "Validate supported proposals in VALUE for TID, retaining legacy replies.
Desktop Assist leaves phone SMS proposals for review on the phone."
  (if (assq 'proposals value)
      (progn
        (unless (and (equal (alist-get 'thread_id value) tid)
                     (listp (alist-get 'proposals value))
                     (<= (string-bytes (json-encode value)) (* 512 1024)))
          (error "Invalid Assist approvals collection"))
        (mapcar (lambda (proposal)
                  (emacsos-assist-web--require-approval
                   `((thread_id . ,tid) (proposal . ,proposal)) tid))
                (seq-remove
                 (lambda (proposal)
                   (and (featurep 'assist-desktop)
                        (emacsos-assist-web--object-p proposal)
                        (equal (alist-get 'kind proposal) "send_sms")))
                 (alist-get 'proposals value))))
    (when-let ((proposal (emacsos-assist-web--require-approval value tid)))
      (list proposal))))

(defun emacsos-assist-web--approval-choose (source tid proposals)
  "Show PROPOSALS for thread TID in the native UI associated with SOURCE."
  (let ((buffer (get-buffer-create (format "*assist Approval %s*" tid))))
    (with-current-buffer buffer
      (emacsos-assist-web-approval-mode)
      (setq emacsos-assist-web--thread-id tid
            emacsos-assist-web--approval-source source
            emacsos-assist-web--approval nil)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Approvals and results\n\n")
        (dolist (proposal proposals)
          (let ((current proposal))
            (insert-text-button
             (format "%s: %s [%s]" (alist-get 'kind current)
                     (or (alist-get 'host current) (alist-get 'display_name current)
                         (alist-get 'sender current) "Email")
                     (or (alist-get 'state current) "pending"))
             'follow-link t
             'action (lambda (_)
                       (with-current-buffer buffer
                         (setq emacsos-assist-web--approval current
                               emacsos-assist-web--approval-edited nil)
                         (emacsos-assist-web--render-approval))))
          (insert "\n\n")))))
    (switch-to-buffer buffer)))

(defun emacsos-assist-web-review-approval (&optional source)
  "Fetch a complete proposal, ordered across SOURCE's same-thread peers."
  (interactive)
  (setq source (or source (current-buffer)))
  (when (buffer-live-p source)
    (let* ((tid (buffer-local-value 'emacsos-assist-web--thread-id source))
           (old-preview (get-buffer (format "*assist Approval %s*" tid)))
           (old-proposal (and (buffer-live-p old-preview)
                              (buffer-local-value 'emacsos-assist-web--approval old-preview)))
           (auth-start (buffer-local-value 'emacsos-assist-web--auth-epoch source))
           (record (emacsos-assist-web--thread-safety-record tid t))
           (generation (cl-incf (plist-get record :approval-generation))))
      (emacsos-assist-web--require-id tid)
      (emacsos-assist-web--request
       "GET" (format "threads/%s/approvals" tid) nil
       (lambda (value error)
         (when (and (buffer-live-p source)
                    (eql auth-start (buffer-local-value 'emacsos-assist-web--auth-epoch source))
                    (not (buffer-local-value 'emacsos-assist-web--denied source))
                    (eq record (emacsos-assist-web--thread-safety-record tid))
                    (= generation (plist-get record :approval-generation))
                    (equal tid (buffer-local-value 'emacsos-assist-web--thread-id source)))
           (if error
               (message "Approval unavailable: %s" error)
             (condition-case problem
                 (if-let ((proposals (emacsos-assist-web--approval-response value tid)))
                     (if (> (length proposals) 1)
                         (emacsos-assist-web--approval-choose source tid proposals)
                       (let ((proposal (car proposals)))
                     (let ((buffer (get-buffer-create (format "*assist Approval %s*" tid))))
                       (with-current-buffer buffer
                         (emacsos-assist-web-approval-mode)
                         (setq emacsos-assist-web--thread-id tid
                               emacsos-assist-web--approval-source source
                               emacsos-assist-web--approval proposal)
                         (emacsos-assist-web--render-approval))
                       (switch-to-buffer buffer))))
                   (when (and (buffer-live-p old-preview)
                              (or (null old-proposal)
                                  (eq old-proposal
                                      (buffer-local-value 'emacsos-assist-web--approval old-preview))))
                     (kill-buffer old-preview))
                   (emacsos-assist-web-refresh-thread source)
                   (message "This thread has no supported pending approval"))
               (error (message "%s" (error-message-string problem)))))))))))

(defun emacsos-assist-web--approval-disarm ()
  "Cancel the armed decision unless this command continues its confirming tap."
  (when emacsos-assist-web--approval-armed
    (let* ((inhibit-read-only t)
           (button (car emacsos-assist-web--approval-armed))
           (mouse-event (mouse-event-p last-input-event))
           (event-window (and mouse-event (posn-window (event-end last-input-event))))
           (position (if mouse-event
                         (posn-point (event-end last-input-event))
                       (point))))
      (unless (and (eq (if mouse-event event-window (selected-window))
                       emacsos-assist-web--approval-armed-window)
                   (or (eq this-command 'push-button)
                       (and (eq this-command 'mouse-drag-region)
                            (eq (car-safe last-input-event) 'down-mouse-1)))
                   (integerp position)
                   (or (not mouse-event)
                       (and (windowp event-window)
                            (eq (window-buffer event-window) (current-buffer))))
                   (<= (button-start button) position)
                   (< position (button-end button)))
        (button-put button 'display nil)
        (setq emacsos-assist-web--approval-armed nil
              emacsos-assist-web--approval-armed-window nil)))))

(defun emacsos-assist-web--approval-button (label decision)
  "Insert a two-tap LABEL button for DECISION on the exact displayed proposal."
  (let ((buffer (current-buffer)))
    (insert-text-button
     label 'follow-link t
     'action
     (lambda (button)
       (when (buffer-live-p buffer)
         (with-current-buffer buffer
           (let ((inhibit-read-only t))
             (unless (plist-get (emacsos-assist-web--thread-safety-record
                                 emacsos-assist-web--thread-id) :approval-pending)
               (if (and (equal (cdr emacsos-assist-web--approval-armed) decision)
                        (eq (selected-window) emacsos-assist-web--approval-armed-window))
                   (progn
                     (setq emacsos-assist-web--approval-armed nil)
                     (emacsos-assist-web--submit-approval decision))
		 (when emacsos-assist-web--approval-armed
                   (button-put (car emacsos-assist-web--approval-armed) 'display nil))
		 (setq emacsos-assist-web--approval-armed (cons button decision)
                       emacsos-assist-web--approval-armed-window (selected-window))
		 (button-put button 'display (concat "Confirm " label "?")))))))))
    (insert "\n\n")))

(defun emacsos-assist-web--render-approval ()
  "Render the exact proposal through the same phone and desktop controls."
  (if (and (not (equal (alist-get 'state emacsos-assist-web--approval) "unavailable"))
           (member (alist-get 'kind emacsos-assist-web--approval)
                   '("send_email" "email_archive" "email_delete")))
      (emacsos-assist-web--render-email-approval)
    (let* ((inhibit-read-only t)
           (proposal emacsos-assist-web--approval)
           (kind (alist-get 'kind proposal))
           (pending (equal (alist-get 'state proposal) "pending"))
           (buffer (current-buffer)))
      (remove-hook 'before-change-functions #'widget-before-change t)
      (remove-hook 'after-change-functions #'widget-after-change t)
      (remove-overlays)
      (use-local-map emacsos-assist-web-approval-mode-map)
      (erase-buffer)
      (setq emacsos-assist-web--approval-armed nil)
      (insert-text-button "Back to thread" 'follow-link t
                          'action (lambda (_)
                                    (when (buffer-live-p emacsos-assist-web--approval-source)
                                      (switch-to-buffer emacsos-assist-web--approval-source))))
      (insert "\n\nState: " (alist-get 'state proposal) "\n\n")
      (when (equal (alist-get 'state proposal) "unavailable")
        (insert (alist-get 'error proposal) "\n\n"))
      (pcase kind
        ("egress"
         (insert (format "Network access: %s:%s\nFor this thread only.\n\n"
                         (alist-get 'host proposal) (alist-get 'port proposal))
                 "Agent's stated reason (not verified):\n" (alist-get 'task proposal) "\n")
         (unless (string-empty-p (alist-get 'main_task proposal))
           (insert "Main agent's reason (not verified):\n" (alist-get 'main_task proposal) "\n"))
         (when (string-match-p "\\(?:\\`\\|\\.\\)xn--" (alist-get 'host proposal))
           (insert "\nInternationalized domain shown as punycode; verify the site.\n"))
         (insert "\nApproving opens this exact host and port. HTTPS is encrypted; plain HTTP is not. "
                 "The agent resumes after all pending requests are resolved.\n\n")
         (if pending
             (progn
               (emacsos-assist-web--approval-button "Allow for 1 hour" "hour")
               (emacsos-assist-web--approval-button "Allow for this thread" "always")
               (emacsos-assist-web--approval-button "Decline" "decline"))
           (insert (alist-get 'lifetime proposal) "\n\n")
           (when (member "revoke" (alist-get 'decisions proposal))
             (emacsos-assist-web--approval-button "Revoke access" "revoke"))))
        ("geo_download"
         (insert "Download: " (alist-get 'display_name proposal) "\n"
                 "Region: " (alist-get 'slug proposal) "\n"
                 (if-let ((size (alist-get 'size_bytes proposal)))
                     (format "Size: %s bytes\n" size) "Size unknown\n")
                 (alist-get 'warning proposal) "\n\n")
         (when pending
           (emacsos-assist-web--approval-button "Approve download" "approve")
           (emacsos-assist-web--approval-button "Decline" "reject")))
        ("send_reply"
         (insert "Reply to: " (alist-get 'sender proposal) "\n\n"
                 (or (alist-get 'text emacsos-assist-web--approval-edited)
                     (alist-get 'text (alist-get 'args (alist-get 'action proposal))))
                 "\n\n")
         (when pending
           (emacsos-assist-web--approval-button
            (if emacsos-assist-web--approval-edited "Send edited reply" "Approve and send")
            (if emacsos-assist-web--approval-edited "edit" "approve"))
           (insert-text-button "Edit reply" 'follow-link t
                               'action (lambda (_) (emacsos-assist-web--edit-reply)))
           (insert "\n\n")
           (emacsos-assist-web--approval-button "Reject" "reject"))))
      (insert-text-button "Refresh proposals" 'follow-link t
                          'action (lambda (_)
                                    (with-current-buffer buffer
                                      (emacsos-assist-web-review-approval emacsos-assist-web--approval-source))))
      (insert "\n")
      (goto-char (point-min)))))

(defun emacsos-assist-web--edit-reply ()
  "Edit the complete reply and return to review without submitting it."
  (when (plist-get (emacsos-assist-web--thread-safety-record
                   emacsos-assist-web--thread-id) :approval-pending)
    (user-error "A decision is awaiting confirmation"))
  (let ((inhibit-read-only t) (buffer (current-buffer)))
    (erase-buffer)
    (remove-overlays)
    (setq emacsos-assist-web--approval-armed nil)
    (insert "Edit reply\n\n")
    (let ((text (widget-create
                 'text :format "%v\n"
                 :value (or (alist-get 'text emacsos-assist-web--approval-edited)
                            (alist-get 'text (alist-get 'args (alist-get 'action emacsos-assist-web--approval)))))))
      (widget-create
       'push-button :notify
       (lambda (&rest _)
         (with-current-buffer buffer
           (let ((value (emacsos-assist-web--canonical-message-text (widget-value text))))
             (if (and (emacsos-assist-web--valid-message-text-p value)
                      (not (string-empty-p (string-trim value)))
                      (<= (string-bytes (encode-coding-string value 'utf-8)) 65536))
                 (progn
                   (setq emacsos-assist-web--approval-edited `((text . ,value)))
                   (setq buffer-read-only t)
                   (emacsos-assist-web--render-approval))
               (message "Reply must contain text and fit 65536 UTF-8 bytes")))))
       "Review edited reply")
      (insert "\n\n")
      (widget-create 'push-button :notify
                     (lambda (&rest _)
                       (with-current-buffer buffer
                         (setq buffer-read-only t)
                         (emacsos-assist-web--render-approval))) "Cancel edit")
      (widget-setup)
      (use-local-map widget-keymap)
      (setq buffer-read-only nil)
      (goto-char (widget-field-start text)))))

(defun emacsos-assist-web--approval-ack-p (value tid proposal)
  "Validate receipt VALUE for thread TID and reviewed PROPOSAL."
  (and (emacsos-assist-web--object-p value)
       (equal (alist-get 'thread_id value) tid)
       (if (member (alist-get 'kind proposal) '("egress" "geo_download"))
           (and (equal (alist-get 'kind value) (alist-get 'kind proposal))
                (equal (alist-get 'token value) (alist-get 'token proposal))
                (member (alist-get 'status value) '("approved" "declined" "importing" "ready" "failed" "revoked")))
         (emacsos-assist-web--valid-id-p (alist-get 'run_id value)))))

(defun emacsos-assist-web--render-email-approval ()
  "Show every field and body before offering an exact proposal decision."
  (let ((inhibit-read-only t)
        (inhibit-modification-hooks t)
        (proposal emacsos-assist-web--approval)
        (buffer (current-buffer)))
    (remove-hook 'before-change-functions #'widget-before-change t)
    (remove-hook 'after-change-functions #'widget-after-change t)
    (remove-overlays)
    (use-local-map emacsos-assist-web-approval-mode-map)
    (erase-buffer)
    (setq emacsos-assist-web--approval-armed nil)
    (insert-text-button
     "Back to thread" 'follow-link t
     'action (lambda (_)
               (when (buffer-live-p emacsos-assist-web--approval-source)
                 (switch-to-buffer emacsos-assist-web--approval-source))))
    (insert "\n\n")
    (if (equal (alist-get 'kind proposal) "send_email")
        (let ((args (or emacsos-assist-web--approval-edited
                        (alist-get 'args (alist-get 'action proposal)))))
          (insert "Email awaiting approval\n\n"
                  "From: " (alist-get 'from proposal) "\n"
                  "To: " (alist-get 'to args) "\n"
                  "Cc: " (alist-get 'cc proposal) "\n"
                  "Subject: " (alist-get 'subject args) "\n\n"
                  (emacsos-assist-web--canonical-message-text (alist-get 'body args))
                  "\n\n")
          (emacsos-assist-web--approval-button
           (if emacsos-assist-web--approval-edited "Send edited email" "Approve and send")
           (if emacsos-assist-web--approval-edited "edit" "approve"))
          (insert-text-button "Edit email" 'follow-link t
                              'action (lambda (_) (emacsos-assist-web--edit-approval)))
          (insert "\n\n"))
      (insert (if (equal (alist-get 'kind proposal) "email_delete")
                  "Move these messages to Trash\n\n"
                "Archive these messages\n\n"))
      (when-let ((error (alist-get 'error proposal)))
        (unless (string-empty-p error)
          (insert "Complete preview unavailable: " error "\nReject this proposal and try again.\n\n")))
      (dolist (mail (alist-get 'messages proposal))
        (dolist (field '(id from to date subject))
          (insert (capitalize (symbol-name field)) ": " (alist-get field mail) "\n"))
        (insert "\n" (emacsos-assist-web--canonical-message-text (alist-get 'body mail))
                "\n\n")
        (let ((url (concat "https://mail.google.com/mail/u/0/#all/"
                           (url-hexify-string (alist-get 'id mail)))))
          (insert-text-button "Open email" 'follow-link t
                              'action (lambda (_) (browse-url url))))
        (insert "\n\n"))
      (when (and (alist-get 'messages proposal)
                 (or (null (alist-get 'error proposal))
                     (string-empty-p (alist-get 'error proposal))))
        (emacsos-assist-web--approval-button "Approve" "approve")))
    (emacsos-assist-web--approval-button "Reject" "reject")
    (insert-text-button
     "Refresh proposal" 'follow-link t
     'action (lambda (_)
               (with-current-buffer buffer
                 (emacsos-assist-web-review-approval emacsos-assist-web--approval-source))))
    (insert "\n")
    (goto-char (point-min))))

(defun emacsos-assist-web--edit-approval ()
  "Edit recipient, subject and body, then return to review before sending."
  (when (plist-get (emacsos-assist-web--thread-safety-record
                   emacsos-assist-web--thread-id) :approval-pending)
    (user-error "A decision is awaiting confirmation"))
  (let* ((inhibit-read-only t)
         (buffer (current-buffer))
         (args (or emacsos-assist-web--approval-edited
                   (alist-get 'args (alist-get 'action emacsos-assist-web--approval)))))
    (erase-buffer)
    (remove-overlays)
    (setq emacsos-assist-web--approval-armed nil)
    (insert "Edit email\n\n")
    (let ((to (widget-create 'editable-field :format "To: %v\n" :value (alist-get 'to args)))
          (subject (widget-create 'editable-field :format "Subject: %v\n"
                                  :value (alist-get 'subject args)))
          (body (widget-create 'text :format "Body:\n%v\n"
                               :value (emacsos-assist-web--canonical-message-text
                                       (alist-get 'body args)))))
      (widget-create
       'push-button :notify
       (lambda (&rest _)
         (with-current-buffer buffer
           (let ((edited `((to . ,(widget-value to)) (subject . ,(widget-value subject))
                           (body . ,(widget-value body)))))
             (cond
              ((not (seq-every-p (lambda (field)
                               (if (eq (car field) 'body)
                                   (emacsos-assist-web--valid-message-text-p (cdr field))
                                 (emacsos-conversation-valid-text-p (cdr field)))) edited))
               (message "Email contains unsupported display controls"))
              ((or (> (length (alist-get 'to edited)) 320)
                   (> (length (alist-get 'subject edited)) 998)
                   (> (length (alist-get 'body edited)) (* 64 1024))
                   (> (string-bytes (encode-coding-string (alist-get 'subject edited) 'utf-8)) 998)
                   (> (string-bytes (encode-coding-string (alist-get 'body edited) 'utf-8)) (* 64 1024))
                   (> (string-bytes
                       (encode-coding-string
                        (json-encode
                         (append `((kind . "send_email") (decision . "edit")
                                   (token . ,(alist-get 'token emacsos-assist-web--approval)))
                                 edited)) 'utf-8))
                      (* 512 1024)))
               (message (concat "Email exceeds approval limits: To 320 characters, "
                                "subject 998/body 65536 UTF-8 bytes; request 512 KiB")))
              (t
                   (setq emacsos-assist-web--approval-edited edited)
                   (remove-overlays)
                   (setq buffer-read-only t)
                   (emacsos-assist-web--render-approval))))))
       "Review edited email")
      (insert "\n\n")
      (widget-create 'push-button :notify
                     (lambda (&rest _)
                       (with-current-buffer buffer
                         (remove-overlays)
                         (setq buffer-read-only t)
                         (emacsos-assist-web--render-approval))) "Cancel edit")
      (widget-setup)
      (use-local-map widget-keymap)
      (setq buffer-read-only nil)
      (goto-char (widget-field-start to)))))

(defun emacsos-assist-web--submit-approval (decision)
  "Submit DECISION and reconcile accepted work after any preview refresh."
  (let* ((buffer (current-buffer))
         (tid emacsos-assist-web--thread-id)
         (source emacsos-assist-web--approval-source)
         (record (emacsos-assist-web--thread-safety-record tid t))
         (proposal emacsos-assist-web--approval)
         (attempt (list (alist-get 'kind proposal) (alist-get 'token proposal) decision))
         (payload `((kind . ,(alist-get 'kind proposal))
                    (token . ,(alist-get 'token proposal)) (decision . ,decision))))
    (when (equal decision "edit")
      (setq payload (append payload emacsos-assist-web--approval-edited)))
    (when (plist-get record :approval-pending)
      (user-error "A decision is awaiting confirmation"))
    (setf (plist-get record :approval-pending) attempt)
    (message "Submitting approval decision…")
    (emacsos-assist-web--request
     "POST" (format "threads/%s/approval" tid) payload
     (lambda (value error)
       (when (eq attempt (plist-get record :approval-pending))
         (setf (plist-get record :approval-pending) nil))
       (cond
        ((and (not error) (emacsos-assist-web--approval-ack-p value tid proposal)
              (eq record (emacsos-assist-web--thread-safety-record tid))
              (not (plist-get record :denial)))
         (let ((owners (seq-filter
                        (lambda (owner)
                          (and (buffer-live-p owner)
                               (with-current-buffer owner
                                 (derived-mode-p 'emacsos-assist-web-mode))))
                        (plist-get record :buffers))))
           (when record (cl-incf (plist-get record :approval-generation)))
           (dolist (owner owners)
             (when (buffer-live-p owner)
               (emacsos-assist-web-refresh-thread owner)))
           (when (buffer-live-p source)
             (switch-to-buffer source)
             (unless (memq source owners)
               (emacsos-assist-web-refresh-thread source)))
           (let ((preview (or (get-buffer (format "*assist Approval %s*" tid)) buffer)))
             (when (buffer-live-p preview)
               (with-current-buffer preview
                 (when (or (null emacsos-assist-web--approval)
                           (and (equal (alist-get 'kind proposal) (alist-get 'kind emacsos-assist-web--approval))
                                (equal (alist-get 'token proposal) (alist-get 'token emacsos-assist-web--approval))))
                   (kill-buffer preview)))))
           (message "Approval decision accepted")))
        (t
         (when (eq record (emacsos-assist-web--thread-safety-record tid))
           (cl-incf (plist-get record :approval-generation)))
         (let ((preview (or (get-buffer (format "*assist Approval %s*" tid)) buffer)))
           (when (buffer-live-p preview)
            (with-current-buffer preview
             (when (or (null emacsos-assist-web--approval)
                       (and (equal (alist-get 'kind proposal) (alist-get 'kind emacsos-assist-web--approval))
                            (equal (alist-get 'token proposal) (alist-get 'token emacsos-assist-web--approval))))
                   ;; The request may have been accepted. A fresh server preview
                   ;; is required before exposing any decision buttons again.
                   (let ((inhibit-read-only t))
                     (erase-buffer)
                     (insert "Decision not confirmed. Refresh to inspect current state.\n\n")
                     (insert-text-button
                      "Refresh proposal" 'follow-link t
                      'action (lambda (_)
				(emacsos-assist-web-review-approval
				 emacsos-assist-web--approval-source))))
                   (message "Approval decision not confirmed: %s"
                            (or error "invalid acknowledgment"))))))))))))

(define-derived-mode emacsos-assist-web-approval-mode special-mode "Assist Approval"
  "Review a complete pending Assist action using explicit two-tap decisions."
  (visual-line-mode 1)
  (setq-local truncate-lines nil word-wrap t)
  (add-hook 'pre-command-hook #'emacsos-assist-web--approval-disarm nil t))

;; These are presentation/restore boundaries, including complete rollback paths.
;; Nested writers share the outer input comparison and native undo transaction.
(dolist (function '(emacsos-assist-web--render
                    emacsos-conversation-replace-marked
                    emacsos-assist-web--write-prompt
                    emacsos-assist-web--replace-input
                    emacsos-assist-web--restore-draft
                    emacsos-assist-web--append-pending
                    ))
  (advice-add function :around #'emacsos-assist-web--preserve-input-undo))

(provide 'assist-web)
;;; assist-web.el ends here
