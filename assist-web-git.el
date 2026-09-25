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
(defvar-local emacsos-assist-web-git--thread-denial-floor 0
  "Last definitive thread denial epoch superseding earlier exact Run reads.")
(defvar-local emacsos-assist-web-git--denied nil)
(defvar-local emacsos-assist-web-git--thread-denial-status nil
  "Definitive canonical thread HTTP status, independent of cleanup messages.")
(defvar-local emacsos-assist-web-git--run-outcome-uncertain nil
  "Outstanding (thread, Run, epoch) denial or superseded-read fences.
Exact post-denial Run verification plus durable canonical acceptance removes
one record; definitive thread denial preserves it for later reauthorization.")
(defvar-local emacsos-assist-web-git--run-recheck-needed nil
  "Auth epoch of one pending auth-only thread GET after exact Run denial.")
(defvar-local emacsos-assist-web-git--busy-check nil
  "One post-save active-Run thread check, owned by its exact receipt.")
(defvar-local emacsos-assist-web-git--stopped-reobserve nil
  "Local projection of a Run stopped by SSE end, disconnect, approval, or repair.
It also fences an exact active Run's T check and terminal Run's R2 commit.")

(defvar emacsos-assist-web-git--thread-safety (make-hash-table :test 'equal)
  "In-process safety records keyed by exact authenticated thread ID.")

(defvar-local emacsos-assist-web-git--thread-safety-tid nil
  "Exact thread ID whose shared safety record the local kill hook updates.")

(defun emacsos-assist-web-git--thread-safety-enroll (record tid buffer)
  "Enroll exact TID BUFFER in RECORD and apply an existing stop fence."
  (unless (memq buffer (plist-get record :buffers))
    (push buffer (plist-get record :buffers))
    (with-current-buffer buffer
      (setq-local emacsos-assist-web-git--thread-safety-tid tid)
      (add-hook 'kill-buffer-hook
                #'emacsos-assist-web-git--thread-safety-buffer-killed nil t)
      (when (plist-get record :stops)
        (cl-incf emacsos-assist-web-git--epoch)
        (when emacsos-assist-web-git--current
          (setf (emacsos-assist-web-git-generation-state
                 emacsos-assist-web-git--current) 'cached))))))

(defun emacsos-assist-web-git--thread-safety-buffer-killed ()
  "Enroll still-open same-thread peers before this buffer's safety exit."
  (let ((inhibit-quit t)
        (tid emacsos-assist-web-git--thread-safety-tid))
    (when-let ((record (and tid
                           (gethash tid emacsos-assist-web-git--thread-safety))))
      (dolist (buffer (buffer-list))
        (when (and (not (eq buffer (current-buffer)))
                   (buffer-live-p buffer)
                   (equal (buffer-local-value
                           'emacsos-assist-web--thread-id buffer) tid))
          (emacsos-assist-web-git--thread-safety-enroll record tid buffer))))))

(defun emacsos-assist-web-git--thread-safety-record (tid &optional create)
  "Return TID's live shared safety record, creating it when CREATE is non-nil.
Scan live same-thread peers before pruning a dead owner: a later kill hook
may open one after the owner's own hook ran but before the kill completed."
  (when tid
    (let ((record (gethash tid emacsos-assist-web-git--thread-safety)))
      (when record
        (setf (plist-get record :buffers)
              (seq-filter #'buffer-live-p (plist-get record :buffers)))
        (dolist (buffer (buffer-list))
          (when (and (buffer-live-p buffer)
                     (equal (buffer-local-value
                             'emacsos-assist-web--thread-id buffer) tid))
            (emacsos-assist-web-git--thread-safety-enroll
             record tid buffer)))
        (unless (plist-get record :buffers)
          (remhash tid emacsos-assist-web-git--thread-safety)
          (setq record nil)))
      (when (and create (not record))
        (setq record (list :buffers nil :stops nil))
        (puthash tid record emacsos-assist-web-git--thread-safety)
        (dolist (buffer (buffer-list))
          (when (and (buffer-live-p buffer)
                     (equal (buffer-local-value
                             'emacsos-assist-web--thread-id buffer) tid))
            (emacsos-assist-web-git--thread-safety-enroll
             record tid buffer))))
      record)))

(defun emacsos-assist-web-git--shared-stop (tid run-id)
  "Return the in-process stopped owner of exact TID/RUN-ID, if any."
  (seq-find (lambda (stop) (equal (plist-get stop :run-id) run-id))
            (plist-get (emacsos-assist-web-git--thread-safety-record tid)
                       :stops)))

(defun emacsos-assist-web-git--owned-stops ()
  "Return stops whose exact queue receipt this buffer durably saves."
  (seq-filter (lambda (stop)
                (or (eq (plist-get stop :owner) (current-buffer))
                    (memq (plist-get stop :entry) emacsos-assist-web--queue)))
              (plist-get (gethash emacsos-assist-web--thread-id
                                  emacsos-assist-web-git--thread-safety)
                         :stops)))

(defun emacsos-assist-web-git--shared-stop-clear (tid run-id entry)
  "Clear only ENTRY's durably resolved exact TID/RUN-ID stop."
  (when-let* ((record (emacsos-assist-web-git--thread-safety-record tid))
              (stop (emacsos-assist-web-git--shared-stop tid run-id)))
    (when (and (eq (plist-get stop :entry) entry)
               (eq (plist-get stop :owner) (current-buffer))
               (equal (plist-get stop :key) (plist-get entry :key)))
      (setf (plist-get record :stops)
            (delq stop (plist-get record :stops))))))

(defun emacsos-assist-web-git--saved-stop-entry (draft tid stop)
  "Return DRAFT's unique queue entry matching TID and STOP, or nil.
The saved exact key, Run, and ended-observer provenance must all agree."
  (when (and (listp draft)
             (= (seq-count (lambda (pair) (eq (car-safe pair) 'thread_id))
                           draft) 1)
             (equal (alist-get 'thread_id draft) tid)
             (= (seq-count (lambda (pair) (eq (car-safe pair) 'queue))
                           draft) 1)
             (listp (alist-get 'queue draft)))
    (let* ((matches (seq-filter
                     (lambda (saved)
                       (and (listp saved)
                            (equal (alist-get 'run_id saved)
                                   (plist-get stop :run-id))
                            (equal (alist-get 'key saved)
                                   (plist-get stop :key))))
                     (alist-get 'queue draft)))
           (saved (car matches))
           (old (plist-get stop :entry)))
      (when (and (= (length matches) 1)
                 (seq-every-p
                  (lambda (field)
                    (= (seq-count (lambda (pair)
                                    (eq (car-safe pair) field)) saved) 1))
                  '(key run_id state observer_end_kind
                    observer_end_generation observer_end_checked
                    approval_stopped))
                 (eq saved (nth (or (plist-get stop :ordinal) 0)
                                (alist-get 'queue draft)))
                 (equal (alist-get 'text saved) (plist-get old :text))
                 (equal (alist-get 'queue draft)
                        (mapcar #'emacsos-assist-web--entry-cache-value
                                (plist-get stop :queue-entries)))
                 (member (alist-get 'state saved)
                         '("accepted-unobserved" "observing"
                           "terminal-unreconciled" "reconciling"))
                 (equal (alist-get 'observer_end_kind saved)
                        (and (plist-get old :observer-end-kind)
                             (symbol-name (plist-get old :observer-end-kind))))
                 (equal (alist-get 'observer_end_generation saved)
                        (plist-get old :observer-end-generation))
                 (equal (and (alist-get 'observer_end_checked saved) t)
                        (and (plist-get old :observer-end-checked) t))
                 (equal (and (alist-get 'approval_stopped saved) t)
                        (and (plist-get old :approval-stopped) t)))
        saved))))

(defun emacsos-assist-web-git--read-stop-cache (name)
  "Read bounded regular JSON cache NAME and its exact byte digest."
  (let ((path (emacsos-assist-web--cache-path name)))
    (when (and (file-regular-p path) (not (file-symlink-p path)))
      (with-temp-buffer
        (insert-file-contents-literally
         path nil 0 (1+ emacsos-assist-web-max-cache-bytes))
        (when (<= (buffer-size) emacsos-assist-web-max-cache-bytes)
          (let ((digest (secure-hash 'sha256 (current-buffer))))
            (decode-coding-region (point-min) (point-max) 'utf-8)
            (list :digest digest
                  :draft (json-parse-buffer :object-type 'alist
                                            :array-type 'list
                                            :null-object nil
                                            :false-object nil))))))))

(defun emacsos-assist-web-git--shared-stop-cache-status (tid stop)
  "Classify STOP's exact image as canonical, SOURCE-only, conflict or repair."
  (let* ((canonical (concat "drafts/" (emacsos-assist-web--require-id tid)
                            ".json"))
         (canonical-path (emacsos-assist-web--cache-path canonical))
         (source "drafts/new-thread.json")
         (source-path (emacsos-assist-web--cache-path source))
         (canonical-image (and (file-exists-p canonical-path)
                               (emacsos-assist-web-git--read-stop-cache canonical)))
         (canonical-draft (plist-get canonical-image :draft)))
    (cond
     ((and (equal (plist-get stop :draft-name) canonical)
           (stringp (plist-get stop :draft-digest))
           (equal (plist-get canonical-image :digest)
                  (plist-get stop :draft-digest))
           (emacsos-assist-web-git--saved-stop-entry canonical-draft tid stop))
      'canonical)
     ((and (equal (plist-get stop :draft-name) source)
           (stringp (plist-get stop :draft-digest))
           (file-exists-p source-path)
           (let ((image (emacsos-assist-web-git--read-stop-cache source)))
             (and (equal (plist-get image :digest)
                         (plist-get stop :draft-digest))
                  (emacsos-assist-web-git--saved-stop-entry
                   (plist-get image :draft) tid stop))))
      (cond
       ((not (file-exists-p canonical-path)) 'source-adoption)
       ((not (listp canonical-draft)) 'repair)
       ((and (equal (alist-get 'thread_id canonical-draft) tid)
             (equal (alist-get 'text canonical-draft) "")
             (null (alist-get 'queue canonical-draft))
             (null (alist-get 'recovery_draft canonical-draft))
             (null (alist-get 'collision canonical-draft)))
        'source-adoption)
       (t 'source-conflict)))
     (t 'repair))))

(defun emacsos-assist-web-git--claim-shared-stop (tid entry)
  "Permit exact TID/ENTRY Run GET only with no stop or its validated owner."
  (let* ((run-id (plist-get entry :run-id))
         (stop (emacsos-assist-web-git--shared-stop tid run-id))
         (owner (plist-get stop :owner)))
    (cond
     ((null stop) t)
     ((and (eq owner (current-buffer))
           (eq (plist-get stop :entry) entry)) t)
     ((buffer-live-p owner)
      (setf (plist-get stop :recovery) 'other-owner)
      nil)
     (t nil))))

(defun emacsos-assist-web-git--shared-recovery-state ()
  "Return the strongest pending shared-stop action for this thread."
  (when-let* ((tid emacsos-assist-web--thread-id)
              (record (emacsos-assist-web-git--thread-safety-record tid)))
    (let ((states (mapcar (lambda (stop) (plist-get stop :recovery))
                          (plist-get record :stops))))
      (cond ((memq 'repair states) 'repair)
            ((memq 'source-conflict states) 'source-conflict)
            ((memq 'source-adoption states) 'source-adoption)
            ((memq 'other-owner states) 'other-owner)))))

(defun emacsos-assist-web-git--shared-stop-blocked (stop state notice)
  "Keep STOP gated with visible STATE and NOTICE after a refused claim."
  (setf (plist-get stop :recovery) state)
  (condition-case nil (emacsos-assist-web-git--update-headers)
    ((error quit) nil))
  (message "%s" notice)
  'blocked)

(defun emacsos-assist-web-git--empty-claim-peer-p ()
  "Whether this canonical view has no mutable state a passive claim could replace."
  (and (null emacsos-assist-web--queue)
       (emacsos-assist-web-git--claim-peer-idle-p)))

(defun emacsos-assist-web-git--claim-peer-idle-p ()
  "Whether this canonical view has no editable or active transport conflict."
  (and (not emacsos-assist-web--post-entry)
       (not emacsos-assist-web--stream-entry)
       (not emacsos-assist-web--in-flight)
       (not emacsos-assist-web--recovery-draft)
       (not emacsos-assist-web--draft-id)
       (not emacsos-assist-web--pending-accepted-p)
       (not emacsos-assist-web--run-id)
       (not emacsos-assist-web--pending-key)
       (not emacsos-assist-web--submitted-text)
       (not emacsos-assist-web--follow-ups)
       (not emacsos-assist-web--manual-recovery-required)
       (not emacsos-assist-web--manual-recovery-active)
       (not emacsos-assist-web--reconcile-recovery-paused)
       (let ((input (emacsos-assist-web--input)))
         (or (null input) (string-empty-p input)))))

(defun emacsos-assist-web-git--resident-claim-peer-p (tid stop)
  "Whether this idle peer owns the saved FIFO queue through STOP."
  (and (emacsos-assist-web-git--claim-peer-idle-p)
       (equal (plist-get (nth (or (plist-get stop :ordinal) 0)
                              emacsos-assist-web--queue) :run-id)
              (plist-get stop :run-id))
       (emacsos-assist-web-git--stop-predecessors-settled-p
        stop emacsos-assist-web--queue)
       (let* ((name (concat "drafts/" (emacsos-assist-web--require-id tid)
                            ".json"))
              (image (emacsos-assist-web-git--read-stop-cache name))
              (draft (plist-get image :draft)))
         (and (equal (plist-get image :digest)
                     (plist-get stop :draft-digest))
              (emacsos-assist-web-git--saved-stop-entry draft tid stop)
              (equal (alist-get 'queue draft)
                     (mapcar #'emacsos-assist-web--entry-cache-value
                             emacsos-assist-web--queue))))))

(defun emacsos-assist-web-git--stop-predecessors-settled-p (stop queue)
  "Whether every QUEUE entry before STOP has a durably verified terminal Run."
  (let ((ordinal (or (plist-get stop :ordinal) 0)))
    (and (< ordinal (length queue))
         (seq-every-p
          (lambda (entry)
            (and (eq (plist-get entry :state) 'terminal-unreconciled)
                 (member (plist-get entry :verified-outcome)
                         '("success" "error" "timeout" "interrupted"
                           "cancelled"))))
          (seq-take queue ordinal)))))

(defun emacsos-assist-web-git--stage-stop-draft (tid draft)
  "Validate and normalize DRAFT off the canonical peer without transport.
Return detached queue state, or nil; no target buffer state is changed."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq-local emacsos-assist-web--thread-id tid)
    (cl-letf (((symbol-function 'emacsos-assist-web--read-cache)
               (lambda (&rest _) draft))
              ((symbol-function 'emacsos-assist-web--save-draft)
               (lambda (&rest _) t))
              ((symbol-function 'emacsos-assist-web--entry-render) #'ignore)
              ((symbol-function 'emacsos-assist-web--render-recovery-draft-action)
               #'ignore))
      (emacsos-assist-web--restore-draft t))
    (when (and emacsos-assist-web--queue-model-p
               emacsos-assist-web--queue
               (not emacsos-assist-web--passive-recovery-invalid-p)
               (= (length emacsos-assist-web--queue)
                  (length (alist-get 'queue draft))))
      (list :queue emacsos-assist-web--queue
            :text (alist-get 'text draft)
            :recovery-draft emacsos-assist-web--recovery-draft
            :collision emacsos-assist-web--collision-p
            :values (mapcar #'emacsos-assist-web--entry-cache-value
                            emacsos-assist-web--queue)))))

(defun emacsos-assist-web-git--install-staged-stop (tid stop stage &optional resident)
  "Install validated STAGE and transfer dead STOP to this TID peer.
RESIDENT means the exact saved queue was already passively restored here."
  (let ((queue (plist-get stage :queue))
        (owner (plist-get stop :owner))
        (record (gethash tid emacsos-assist-web-git--thread-safety)))
    (when (and record (memq stop (plist-get record :stops))
               (not (buffer-live-p owner))
               (if resident
                   (and (emacsos-assist-web-git--claim-peer-idle-p)
                        (equal queue emacsos-assist-web--queue)
                        (equal (plist-get stage :values)
                               (mapcar #'emacsos-assist-web--entry-cache-value
                                       emacsos-assist-web--queue)))
                 (emacsos-assist-web-git--empty-claim-peer-p))
               (emacsos-assist-web-git--stop-predecessors-settled-p stop queue)
               (equal (plist-get (nth (or (plist-get stop :ordinal) 0)
                                      queue) :run-id)
                       (plist-get stop :run-id)))
      (let ((inhibit-quit t)
            (entry (nth (or (plist-get stop :ordinal) 0) queue)))
        (unless resident
          (setq emacsos-assist-web--queue queue
                emacsos-assist-web--queue-model-p t
                emacsos-assist-web--collision-p (plist-get stage :collision)
                emacsos-assist-web--recovery-draft
                (plist-get stage :recovery-draft)))
        (setf (plist-get stop :owner) (current-buffer)
              (plist-get stop :entry) entry
              (plist-get stop :recovery) nil)
        (setq emacsos-assist-web-git--stopped-reobserve
              (list :entry entry :tid tid :run-id (plist-get stop :run-id)
                    :generation (1- (or (plist-get entry
                                                    :reobserve-generation) 0))
                    :kind (plist-get stop :kind)))
        entry))))

(defun emacsos-assist-web-git--render-installed-stop (stage)
  "Present STAGE after its exact queue and stop ownership are committed."
  (condition-case nil
      (let ((inhibit-modification-hooks t)
            (text (plist-get stage :text)))
        (when (and (stringp text) (not (string-empty-p text)))
          (goto-char (point-max))
          (insert text))
        (dolist (entry (plist-get stage :queue))
          (emacsos-assist-web--entry-render entry))
        (emacsos-assist-web--render-recovery-draft-action)
        (emacsos-assist-web-git--update-headers)
        t)
    ((error quit)
     (setq emacsos-assist-web--reconcile-recovery-paused t)
     (condition-case nil
         (emacsos-assist-web--set-status
          "saved Run recovery needs restart; presentation failed")
       ((error quit) nil))
     nil)))

(defun emacsos-assist-web-git--claim-dormant-canonical (tid stop)
  "Prepare exact canonical receipt off-buffer, then claim dead STOP once."
  (condition-case nil
      (let* ((name (concat "drafts/" (emacsos-assist-web--require-id tid)
                           ".json"))
             (image (emacsos-assist-web-git--read-stop-cache name))
             (draft (plist-get image :draft))
             (resident (emacsos-assist-web-git--resident-claim-peer-p tid stop))
             (stage (if resident
                        (list :queue emacsos-assist-web--queue
                              :values (mapcar #'emacsos-assist-web--entry-cache-value
                                              emacsos-assist-web--queue))
                      (emacsos-assist-web-git--stage-stop-draft tid draft)))
             (normalized (and stage
                              (not (equal (plist-get stage :values)
                                          (alist-get 'queue draft)))))
             (prospective (and normalized (copy-tree draft)))
             (encoded (when normalized
                        (setf (alist-get 'queue prospective)
                              (plist-get stage :values))
                        (json-encode prospective)))
             (digest (if encoded (secure-hash 'sha256 encoded)
                       (plist-get image :digest)))
             (record (gethash tid emacsos-assist-web-git--thread-safety))
             (owner (plist-get stop :owner)))
        (if (not (and stage
                      (equal (plist-get image :digest)
                             (plist-get stop :draft-digest))
                      (equal (plist-get stop :draft-name) name)
                      (emacsos-assist-web-git--saved-stop-entry draft tid stop)
                      (or resident (emacsos-assist-web-git--empty-claim-peer-p))
                      (not (buffer-live-p owner))))
            (emacsos-assist-web-git--shared-stop-blocked
             stop 'repair "Run recovery needs repair; saved receipt changed")
          (let ((entry nil) (saved t))
            (let ((inhibit-quit t))
              (when normalized
                (setq saved (emacsos-assist-web--try-write-cache
                             name prospective encoded)))
              (when saved
                (dolist (candidate (plist-get record :stops))
                  (when (and (eq (plist-get candidate :owner) owner)
                             (equal (plist-get candidate :draft-name) name))
                    (setf (plist-get candidate :draft-digest) digest
                          (plist-get candidate :queue-entries)
                          (plist-get stage :queue)
                          (plist-get candidate :entry)
                          (nth (or (plist-get candidate :ordinal) 0)
                               (plist-get stage :queue)))))
                (setq entry (emacsos-assist-web-git--install-staged-stop
                             tid stop stage resident))
                (when (and entry
                           (seq-some
                            (lambda (candidate)
                              (eq (plist-get candidate :state)
                                  'terminal-unreconciled))
                            (plist-get stage :queue)))
                  (setq emacsos-assist-web--manual-recovery-required t))))
            (cond
             ((not saved)
              (emacsos-assist-web-git--shared-stop-blocked
               stop 'repair "Run recovery needs repair; normalized receipt was not saved"))
             ((not entry)
              (emacsos-assist-web-git--shared-stop-blocked
               stop 'repair "Run recovery changed during claim; Refresh"))
             ((or resident (emacsos-assist-web-git--render-installed-stop stage))
              entry)
             (t 'blocked)))))
    ((error quit)
     (emacsos-assist-web-git--shared-stop-blocked
      stop 'repair "Run recovery needs repair; passive import failed"))))

(defun emacsos-assist-web-git--shared-stop-refresh ()
  "Return a claimed dormant entry, `blocked', or nil on explicit Refresh.
An empty canonical peer stages the named receipt before one exact Run GET.
This never imports a SOURCE-only precommit receipt."
  (when-let* ((tid emacsos-assist-web--thread-id)
              (record (emacsos-assist-web-git--thread-safety-record tid))
              (stops (plist-get record :stops))
              (stop (seq-find
                     (lambda (candidate)
                       (not (and (eq (plist-get candidate :owner)
                                     (current-buffer))
                                 (eq (plist-get (plist-get candidate :entry)
                                                :state)
                                     'terminal-unreconciled)
                                 (plist-get (plist-get candidate :entry)
                                            :verified-outcome)
                                 (stringp (plist-get candidate :draft-digest)))))
                     (sort (copy-sequence stops)
                           (lambda (a b)
                             (< (or (plist-get a :ordinal) 0)
                                (or (plist-get b :ordinal) 0)))))))
    (unless (eq (plist-get stop :owner) (current-buffer))
      (if (buffer-live-p (plist-get stop :owner))
          (emacsos-assist-web-git--shared-stop-blocked
           stop 'other-owner "Run recovery is active in another thread view")
        (let ((status (condition-case nil
                          (emacsos-assist-web-git--shared-stop-cache-status
                           tid stop)
                        ((error quit) 'repair))))
          (pcase status
            ('canonical
             (if (or (emacsos-assist-web-git--empty-claim-peer-p)
                     (emacsos-assist-web-git--resident-claim-peer-p tid stop))
                 (emacsos-assist-web-git--claim-dormant-canonical tid stop)
               (emacsos-assist-web-git--shared-stop-blocked
                stop 'repair "Run recovery needs repair; local state conflicts")))
            ('source-adoption
             (emacsos-assist-web-git--shared-stop-blocked
              stop status "Source adoption pending; open saved New thread draft"))
            ('source-conflict
             (emacsos-assist-web-git--shared-stop-blocked
              stop status "Draft conflict; resolve saved source and destination"))
            (_
             (emacsos-assist-web-git--shared-stop-blocked
              stop 'repair "Run recovery needs repair; saved receipt unavailable"))))))))

(defun emacsos-assist-web-git--operator-repair-p ()
  "Return non-nil while an exact saved Run requires operator repair."
  (or (eq (plist-get emacsos-assist-web-git--stopped-reobserve :kind)
          'operator-repair)
      (seq-some (lambda (entry)
                  (and (eq (plist-get entry :observer-end-kind)
                           'operator-repair)
                       (plist-get entry :requires-reobserve)
                       (not (plist-get entry :approval-stopped))))
                (bound-and-true-p emacsos-assist-web--queue))))

(defun emacsos-assist-web-git--approval-stopped-p ()
  "Return whether stopped approval is the current visible recovery action.
Its durable flag remains set during a later active Run/T/observer join."
  (or (eq (plist-get emacsos-assist-web-git--stopped-reobserve :kind)
          'approval)
      (and (not emacsos-assist-web-git--stopped-reobserve)
           (seq-some (lambda (entry)
                       (and (plist-get entry :approval-stopped)
                            (plist-get entry :requires-reobserve)))
                     (bound-and-true-p emacsos-assist-web--queue)))))
(defvar-local emacsos-assist-web-git--intent-serial 0)
(defvar-local emacsos-assist-web-git--unavailable nil)
(defvar-local emacsos-assist-web-git--feedback-windows nil)
(defvar-local emacsos-assist-web-git--view-thread nil)
(defvar-local emacsos-assist-web-git--view-generation nil)
(defvar-local emacsos-assist-web-git--chooser-thread nil)
(defvar-local emacsos-assist-web-git--chooser-generation nil)
(defvar-local emacsos-assist-web-git--chooser-exit nil
  "One mutable exit cell shared with the synchronous file chooser.")
(defvar-local emacsos-assist-web-git--details-generation nil)
(defvar-local emacsos-assist-web-git--details-thread nil)
(defvar-local emacsos-assist-web-git--details-origin nil)
(defvar-local emacsos-assist-web-git--details-chooser-snapshot nil)

(defvar emacsos-assist-web-git-view-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c b") #'emacsos-assist-web-git-back)
    (define-key map (kbd "C-c s") #'emacsos-assist-web-git-show-sha)
    (define-key map (kbd "C-c r") #'emacsos-assist-web-git-close-old-view)
    (define-key map (kbd "C-c ?") #'emacsos-assist-web-git-view-details)
    map))

(defvar emacsos-assist-web-git-magit-map
  (let ((map (make-sparse-keymap)))
    (define-key map [t] #'emacsos-assist-web-git--deny-mutation)
    (dolist (pair '(("q" . emacsos-assist-web-git-back)
                    ("C-c b" . emacsos-assist-web-git-back)
                    ("C-c s" . emacsos-assist-web-git-show-sha)
                    ("C-c r" . emacsos-assist-web-git-close-old-view)
                    ("C-c ?" . emacsos-assist-web-git-view-details)
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
    (define-key map (kbd "C-c ?") #'emacsos-assist-web-git-details)
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
  "Set an existing KEY on mutable REQUEST without replacing its identity."
  (setf (plist-get request key) value)
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

(defun emacsos-assist-web-git--run-gated-p ()
  "Whether this thread has a shared stop or live exact Run gate.
A shared stop may outlive its original buffer pending exact durable recovery."
  (let* ((tid emacsos-assist-web--thread-id)
         (record (emacsos-assist-web-git--thread-safety-record tid)))
    (and tid
         (or (plist-get record :stops)
             (seq-some
          (lambda (buffer)
            (with-current-buffer buffer
              (and (equal emacsos-assist-web--thread-id tid)
                   (or emacsos-assist-web-git--run-outcome-uncertain
                       emacsos-assist-web-git--stopped-reobserve
                       (seq-some (lambda (entry)
                                   (and (plist-get entry :requires-reobserve)
                                        (memq (plist-get entry :state)
                                              '(accepted-unobserved
                                                terminal-unreconciled))))
                                 (bound-and-true-p emacsos-assist-web--queue))))))
          (if record (plist-get record :buffers) (buffer-list)))))))

(defun emacsos-assist-web-git--gate-reason ()
  "Return the strongest current refusal for a fresh Git action, or nil."
  (cond
   ((bound-and-true-p emacsos-assist-web--reconcile-recovery-paused)
    "local recovery could not be saved; restart to recover")
   ((eq emacsos-assist-web-git--denied t)
    (if (eql emacsos-assist-web-git--thread-denial-status 404)
        "Thread unavailable; reopen from the thread list"
      "Thread Git access denied; reauthorize and Retry"))
   ((eq emacsos-assist-web-git--denied 'run)
    "Run status unavailable; Refresh thread")
   ((eq (emacsos-assist-web-git--shared-recovery-state) 'repair)
    "Run recovery needs repair; inspect Details")
   ((eq (emacsos-assist-web-git--shared-recovery-state) 'source-adoption)
    "Source adoption pending; Retry adoption before Refresh")
   ((eq (emacsos-assist-web-git--shared-recovery-state) 'source-conflict)
    "Draft conflict; resolve source and destination before Refresh")
   ((eq (emacsos-assist-web-git--shared-recovery-state) 'other-owner)
    "Run recovery is active in another thread view")
   ((emacsos-assist-web-git--operator-repair-p)
    "Operator repair required before Refresh")
   ((emacsos-assist-web-git--approval-stopped-p)
    "Approval pending; approve first, then Refresh")
   ((and (bound-and-true-p emacsos-assist-web--manual-recovery-required)
         (bound-and-true-p emacsos-assist-web--manual-recovery-active)
         (bound-and-true-p emacsos-assist-web--stream-entry))
    (if (plist-get emacsos-assist-web--stream-entry :stream-admitted)
        "Run active; observing; result will appear here"
      "Run observer connecting; result will appear here"))
   ((bound-and-true-p emacsos-assist-web--manual-recovery-required)
    "Run recovery pending; Refresh")
   ((eq (plist-get emacsos-assist-web-git--stopped-reobserve :kind)
        'active-check)
    (if (plist-get emacsos-assist-web-git--busy-check :t-accepted)
        "Run observer connecting; result will appear here"
      "Run status saved; canonical thread check pending"))
   ((eq (plist-get emacsos-assist-web-git--stopped-reobserve :kind)
        'terminal-verified)
    "Run outcome saved; canonical reconciliation pending")
   ((emacsos-assist-web-git--run-gated-p)
    "Run status unavailable; Refresh thread")))

(defun emacsos-assist-web-git--view-state (generation thread)
  "Return live state for GENERATION as seen from THREAD."
  (if (not (buffer-live-p thread))
      "stale"
    (with-current-buffer thread
      (let ((latest emacsos-assist-web-git--metadata))
        (cond
         ((eq emacsos-assist-web-git--denied 'run)
          "unavailable; exact Run status needs Refresh")
         (emacsos-assist-web-git--denied "unavailable; reauthorize and Retry")
         ((not (emacsos-assist-web-git--same-identity
                latest (emacsos-assist-web-git-generation-metadata generation)))
          "stale")
         ((not (eq generation emacsos-assist-web-git--current)) "stale")
         ((bound-and-true-p emacsos-assist-web--manual-recovery-required)
          "cached / Run recovery pending")
         (emacsos-assist-web-git--stopped-reobserve
          (concat "cached / "
                  (emacsos-assist-web-git--stopped-label)))
         ((emacsos-assist-web-git--run-gated-p)
          "unavailable; exact Run status needs Refresh")
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
  "Build a pinned-view header with Back/Close and Details before state."
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
     (format "Git %s" (emacsos-assist-web-git--short
                        (emacsos-assist-web-git-generation-oid generation)))
     (propertize action 'mouse-face 'highlight
                 'local-map (let ((map (make-sparse-keymap)))
                              (define-key map [header-line mouse-1] command)
                              map))
     (emacsos-assist-web-git--details-link
      #'emacsos-assist-web-git-view-details)
     " " (emacsos-assist-web-git--short-state state))))

(defun emacsos-assist-web-git--short-state (state)
  "Return a phone-width status code for full explanation STATE."
  (cond ((string-prefix-p "current" state) "current")
        ((string-prefix-p "fetched remote" state) "remote")
        ((string-prefix-p "cached" state) "cached")
        ((string-prefix-p "unavailable" state) "unavailable")
        (t "stale")))

(defun emacsos-assist-web-git--chooser-header ()
  "Show a short chooser state with touch and keyboard exit actions."
  (concat
   (format "Git %s"
           (emacsos-assist-web-git--short
            (emacsos-assist-web-git-generation-oid
             emacsos-assist-web-git--chooser-generation)))
   (emacsos-assist-web-git--padded-action
    "Back" #'emacsos-assist-web-git-chooser-back)
   (emacsos-assist-web-git--details-link
    #'emacsos-assist-web-git-chooser-details)
   " " (emacsos-assist-web-git--short-state
         (emacsos-assist-web-git--view-state
          emacsos-assist-web-git--chooser-generation
          emacsos-assist-web-git--chooser-thread))))

(defun emacsos-assist-web-git--padded-action (label command)
  "Return a 40-pixel touch action LABEL invoking COMMAND."
  (let* ((map (make-sparse-keymap))
         (edge (propertize " " 'mouse-face 'highlight 'local-map map
                           'display '(space :width (20) :height (40)))))
    (define-key map [header-line mouse-1] command)
    (concat edge (propertize (format "[%s]" label)
                             'mouse-face 'highlight 'local-map map)
            edge)))

(defun emacsos-assist-web-git-chooser-back ()
  "Leave this file chooser and return to its canonical thread."
  (interactive)
  (when emacsos-assist-web-git--chooser-exit
    (setcar emacsos-assist-web-git--chooser-exit 'back))
  (abort-recursive-edit))

(defun emacsos-assist-web-git-chooser-details ()
  "Leave this chooser for immutable commit Details without selecting a file."
  (interactive)
  (when emacsos-assist-web-git--chooser-exit
    (setcar emacsos-assist-web-git--chooser-exit
            (list 'details
                  (emacsos-assist-web-git--view-state
                   emacsos-assist-web-git--chooser-generation
                   emacsos-assist-web-git--chooser-thread)
                  (and (buffer-live-p emacsos-assist-web-git--chooser-thread)
                       (with-current-buffer emacsos-assist-web-git--chooser-thread
                         emacsos-assist-web-git--metadata)))))
  (abort-recursive-edit))

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
     ((eq emacsos-assist-web-git--denied 'run)
      (concat (emacsos-assist-web-git--run-refresh-link)
              (emacsos-assist-web-git--details-link)))
     (emacsos-assist-web-git--denied
      (emacsos-assist-web-git--status-action
       (if (eql emacsos-assist-web-git--thread-denial-status 404)
           "Thread unavailable" "Reauthorize")))
     ((eq (emacsos-assist-web-git--shared-recovery-state) 'repair)
      (emacsos-assist-web-git--status-action "Repair needed"))
     ((eq (emacsos-assist-web-git--shared-recovery-state) 'source-adoption)
      (emacsos-assist-web-git--status-action "Source adoption pending"))
     ((eq (emacsos-assist-web-git--shared-recovery-state) 'source-conflict)
      (emacsos-assist-web-git--status-action "Draft conflict"))
     ((eq (emacsos-assist-web-git--shared-recovery-state) 'other-owner)
      (emacsos-assist-web-git--status-action "Run recovery in another view"))
     ((emacsos-assist-web-git--operator-repair-p)
      (emacsos-assist-web-git--status-action "Operator repair"))
     ((emacsos-assist-web-git--approval-stopped-p)
      (emacsos-assist-web-git--status-action "Approval needed"))
     ((and manual
           (bound-and-true-p emacsos-assist-web--manual-recovery-active)
           (bound-and-true-p emacsos-assist-web--stream-entry))
      (emacsos-assist-web-git--status-action
       (if (plist-get emacsos-assist-web--stream-entry :stream-admitted)
           "Run active; observing" "Run observer connecting")))
     (manual
      (concat
       (emacsos-assist-web-git--run-refresh-link
        (pcase (bound-and-true-p emacsos-assist-web--manual-recovery-reason)
          ('approval "Approval pending; Refresh")
          ('changed "Run changed; Refresh")
          (_ "Run recovery pending; Refresh")))
       (emacsos-assist-web-git--details-link)))
     (emacsos-assist-web-git--stopped-reobserve
      (concat (emacsos-assist-web-git--run-refresh-link
               (emacsos-assist-web-git--stopped-label))
              (emacsos-assist-web-git--details-link)))
     ((emacsos-assist-web-git--run-gated-p)
      (concat (emacsos-assist-web-git--run-refresh-link)
              (emacsos-assist-web-git--details-link)))
     ((and display-failed (not paused))
        (concat
         (propertize "Saved; Refresh" 'mouse-face 'highlight
                     'local-map (let ((map (make-sparse-keymap)))
                                  (define-key map [header-line mouse-1]
                                    #'emacsos-assist-web-refresh-thread)
                                  map))
         (emacsos-assist-web-git--details-link
          #'emacsos-assist-web-git-display-details)))
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
      (insert "Canonical history was saved. Any exact Run retirement was saved.\n\n"
              "The phone could not display the result. Refresh retries "
              "presentation; it does not resend or reobserve a retired Run.\n\n"
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
                   (emacsos-assist-web-git--cleanup-failed)))))))))))

(defun emacsos-assist-web-git--cleanup-failed ()
  "Release every Git action after an old staging directory cannot be cleaned."
  (emacsos-assist-web-git--invalidate
   "mirror cleanup failed; restart Emacs before retry"))

(defun emacsos-assist-web-git--finish-obsolete (request)
  "Clean REQUEST without opening it, then start its post-cause successor."
  (let ((thread (current-buffer)))
    (condition-case nil
        (emacsos-assist-web-git--cleanup
         (plist-get request :id) "staging"
         (lambda (ok)
           (when (buffer-live-p thread)
             (with-current-buffer thread
               (when (eq request emacsos-assist-web-git--request)
                 (setq emacsos-assist-web-git--request nil)
                 (if ok
                     (emacsos-assist-web-git--run-next)
                   (emacsos-assist-web-git--cleanup-failed)))))))
      (error
       (when (eq request emacsos-assist-web-git--request)
         (setq emacsos-assist-web-git--request nil)
         (emacsos-assist-web-git--cleanup-failed))))))

(defun emacsos-assist-web-git--run-next ()
  "Start a queued successor only after the prior stage has been cleaned."
  (when-let ((next (and (not emacsos-assist-web-git--pending)
                       (not emacsos-assist-web-git--canceling)
                       (not emacsos-assist-web-git--request)
                       emacsos-assist-web-git--next)))
    (setq emacsos-assist-web-git--next nil)
    (apply #'emacsos-assist-web-git--begin next)))

(defun emacsos-assist-web-git--note (metadata)
  "Accept canonical METADATA and update the current Git view."
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
  (emacsos-assist-web-git--update-headers))

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
    (metadata legacy-success-run-id token)
  "Apply chat-accepted METADATA, resolving an eligible TOKEN after commit.
LEGACY-SUCCESS-RUN-ID is an exact successful Run durably retired by the
queue-free compatibility path."
  (let* ((queue-owner (plist-get token :queue-owner))
         (pending-token (if queue-owner (plist-get token :pending) token))
         (queue-eligible
          (and queue-owner
               (eql queue-owner emacsos-assist-web--reconcile-generation)
               (not emacsos-assist-web-git--denied)))
         (success-ids
          (append
           (and legacy-success-run-id (list legacy-success-run-id))
           (and queue-eligible
                (delete-dups
                 (mapcar #'car
                         (seq-filter (lambda (cause)
                                       (equal (cdr cause) "success"))
                                     (plist-get token :outcomes)))))))
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
    (emacsos-assist-web-git--note metadata)
    (when eligible
      (setq emacsos-assist-web-git--pending nil)
      (if (emacsos-assist-web-git--usable metadata)
          (if intents
              (dolist (intent intents)
                (emacsos-assist-web-git--enqueue metadata intent))
            (emacsos-assist-web-git--enqueue metadata nil))
        (emacsos-assist-web-git--release-intents
         intents "no published thread branch; Retry")))
    (when (and success-ids
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
          (t "canonical reconciliation failed; Retry"))))))
  (emacsos-assist-web-git--maybe-run-recheck))

(defun emacsos-assist-web-git--conflict-during-r2 (metadata intent)
  "Hold diagnostic METADATA and INTENT for one post-R2 canonical R3."
  (let* ((prior emacsos-assist-web-git--r2-waiting)
         (intents (emacsos-assist-web-git--live-intents
                   (plist-get prior :intents)
                   (plist-get emacsos-assist-web-git--pending :intents)
                   (plist-get emacsos-assist-web-git--request :intents)
                   (cadr emacsos-assist-web-git--next)
                   (and intent (list intent)))))
    (if prior
        ;; R2's pre-barrier GET cannot settle either diagnostic.  A later
        ;; old-key probe is not authority to replace the first conflict.
        (progn
          (emacsos-assist-web-git--request-put
           prior :owner emacsos-assist-web--reconcile-generation)
          (emacsos-assist-web-git--request-put prior :intents intents))
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
      (emacsos-assist-web-git--update-headers))))

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
  "Make Git freshness unavailable for REASON without changing chat state.
A definitive thread denial keeps its endpoint-specific reason instead."
  (when (eq emacsos-assist-web-git--denied t)
    (setq reason (emacsos-assist-web-git--thread-denial-reason)))
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
    (cl-incf emacsos-assist-web-git--observation)
    (cl-incf emacsos-assist-web-git--epoch)
    (condition-case nil (emacsos-assist-web-git--cancel) ((error quit) nil))
    (condition-case nil
        (emacsos-assist-web-git--release-intents intents reason)
      ((error quit) nil)))
  (condition-case nil (emacsos-assist-web-git--update-headers)
    ((error quit) nil)))

(defun emacsos-assist-web-git--release-intents (intents reason &optional quiet)
  "End live INTENTS and attempt window feedback; message unless QUIET."
  (let (released)
    (dolist (intent intents)
      (condition-case nil
          (when (emacsos-assist-web-git--intent-live-p intent)
            (setq released t)
            ;; The action is finished even if constructing its feedback fails.
            ;; A later callback must not find a still-live busy window token.
            (set-window-parameter (plist-get intent :window)
                                  'assist-web-git-intent
                                  (1+ (plist-get intent :serial)))
            (let* ((window (plist-get intent :window))
             (thread (plist-get intent :buffer))
             (restart (string-match-p "restart to recover" reason))
             (run-status (string-match-p "\\`Run status unavailable" reason))
             (missing (string-match-p "thread unavailable (404)" reason))
             (denial (or missing
                         (string-match-p
                          "thread access denied\\|reauthorize" reason)))
             (manual (string-match-p "Run recovery pending" reason))
             (label (cond (restart "Restart to recover")
                          (run-status (emacsos-assist-web-git--run-refresh-link))
                          (missing "Thread unavailable")
                          (denial "Reauthorize")
                          (manual "Run recovery pending")
                          ((string-match-p "pending\\|changed" reason)
                           "Git pending")
                          (t "Git unavailable")))
             (retry (if (or restart denial run-status) ""
                      (propertize
                       (if manual " [Refresh]" " [Retry]")
                       'mouse-face 'highlight
                       'local-map
                       (let ((map (make-sparse-keymap)))
                         (define-key map [header-line mouse-1]
                           (if manual #'emacsos-assist-web-refresh-thread
                             #'emacsos-assist-web-git-refresh))
                         map))))
             (details (if (or restart denial run-status)
                          (emacsos-assist-web-git--details-link)
                        ""))
             (header `(:eval (if (eq (current-buffer) ,thread)
                                 ,(concat label retry details)
                               header-line-format))))
        (set-window-parameter window 'assist-web-git-feedback header)
        (set-window-parameter window 'header-line-format header)
        (setq emacsos-assist-web-git--feedback-windows
              (assq-delete-all window emacsos-assist-web-git--feedback-windows))
        (push (cons window header) emacsos-assist-web-git--feedback-windows)
              (force-mode-line-update t)))
        ((error quit) nil)))
    (when (and released (not quiet))
      (message "Thread Git: %s" reason))))

(defun emacsos-assist-web-git--details-link (&optional command)
  "Return a 40-pixel-high, at least 40-pixel-wide link invoking COMMAND."
  (emacsos-assist-web-git--padded-action
   "?" (or command #'emacsos-assist-web-git-status-details)))

(defun emacsos-assist-web-git--status-action (label)
  "Return compact LABEL and a clickable explanation affordance."
  (concat label (emacsos-assist-web-git--details-link)))

(defun emacsos-assist-web-git--run-refresh-link (&optional label)
  "Return a compact LABEL action for rechecking an exact Run."
  (propertize (or label "Run status; Refresh") 'mouse-face 'highlight
              'local-map
              (let ((map (make-sparse-keymap)))
                (define-key map [header-line mouse-1]
                  #'emacsos-assist-web-refresh-thread)
                map)))

(defun emacsos-assist-web-git-status-details ()
  "Explain a Git recovery or access gate without offering an unsafe Retry."
  (interactive)
  (let* ((thread (current-buffer))
         (paused (bound-and-true-p emacsos-assist-web--reconcile-recovery-paused))
         (reason (cond
                  (paused
                   "The local Run reconciliation record could not be saved. Git is paused. Restart Emacs, reopen this thread, then use Refresh to recover the exact Run. Do not retry Git in this session.")
                  ((eq emacsos-assist-web-git--denied 'run)
                   "The exact Run status could not be verified. This does not prove the thread is gone. A thread access check is pending; then Refresh the exact Run before opening Git. Existing views are noncurrent.")
                  ((and emacsos-assist-web-git--denied
                        (eql emacsos-assist-web-git--thread-denial-status 404))
                   "This thread is unavailable. Reopen it from the Assist thread list after checking access. Existing Git views are noncurrent; do not use them as the thread's latest state.")
                  (emacsos-assist-web-git--denied
                   "Assist denied access to this thread. Reauthorize Assist, reopen the thread, and then Retry. Existing Git views are noncurrent.")
                  ((eq (emacsos-assist-web-git--shared-recovery-state) 'repair)
                   "The named exact Run receipt is missing, invalid, or conflicts with this thread view. Repair the saved draft before Refresh; this Refresh sent neither another Run GET nor a POST. Git remains noncurrent.")
                  ((eq (emacsos-assist-web-git--shared-recovery-state)
                       'source-adoption)
                   "A valid accepted New thread draft still owns this Run. Reopen that saved New thread draft and Retry its no-POST adoption into this canonical thread first, then separately Refresh its exact Run. Git remains noncurrent.")
                  ((eq (emacsos-assist-web-git--shared-recovery-state)
                       'source-conflict)
                   "Both saved New thread and canonical drafts hold mutable state. Use the existing Draft conflict recovery; this recovery attempt sent neither another Run GET nor a POST. Git remains noncurrent.")
                  ((eq (emacsos-assist-web-git--shared-recovery-state)
                       'other-owner)
                   "Another live thread view still owns the saved exact Run. This view did not send another Run GET. Return to the owning view or wait for its result; Git remains noncurrent.")
                  ((emacsos-assist-web-git--operator-repair-p)
                   "The exact Run observer reported a server-side failure. Ask the operator to repair Assist first. Then Refresh to check this Run. Existing Git views are noncurrent.")
                  ((emacsos-assist-web-git--approval-stopped-p)
                   "Approve this Run in Assist first, then Refresh to recheck. Refresh before approval cannot resume observation. Existing Git views are noncurrent; no observer reattaches automatically.")
                  ((and (bound-and-true-p
                         emacsos-assist-web--manual-recovery-active)
                        (bound-and-true-p emacsos-assist-web--stream-entry))
                   (if (plist-get emacsos-assist-web--stream-entry
                                  :stream-admitted)
                       "This exact recovered Run is being observed. Its result will appear here; extra Refresh taps start no request. Press q to return."
                     "The recovered Run observer is connecting. Its headers have not been admitted yet. Extra Refresh taps start no request; the result will appear here."))
                  ((eq (bound-and-true-p emacsos-assist-web--manual-recovery-reason)
                       'approval)
                   "The exact Run is awaiting approval after its stream ended. Approve it first, then Refresh to check the exact Run again. This pass stopped; it will not reattach automatically. Press q to return.")
                  ((eq (bound-and-true-p emacsos-assist-web--manual-recovery-reason)
                       'changed)
                   "The Run was still active after its stream ended. The observation may have changed. Refresh to make one new exact Run check; this pass will not reattach automatically. Press q to return.")
                  (emacsos-assist-web-git--stopped-reobserve
                   (let ((entry (plist-get emacsos-assist-web-git--stopped-reobserve
                                           :entry)))
                     (pcase (plist-get emacsos-assist-web-git--stopped-reobserve :kind)
                     ('disconnect "The Run observation ended or could not connect before its exact outcome was known. The old Git view is noncurrent. Refresh to check this Run; a running Run may attach a new observer.")
                     ('operator-repair "The Run observer reported a server-side failure. Ask the operator to repair Assist, then Refresh to check this exact Run. The old Git view is noncurrent.")
                     ('active-check
                      (if (plist-get emacsos-assist-web-git--busy-check :t-accepted)
                          "The exact Run is active and its canonical thread state was accepted. Its observer is connecting; Git remains noncurrent until admission."
                        "The exact Run is active and its status was saved. Its canonical thread check is still pending; Refresh joins or retries that check. Git remains noncurrent."))
                     ('approval "The exact Run is awaiting approval. Approve it first, then Refresh to check its status. The old Git view is noncurrent; this observer will not reattach automatically.")
                     (_ (cond
                         ((and entry (not (plist-get entry :observer-end-checked))
                               (plist-get entry :verified-outcome))
                          "The exact terminal Run outcome was saved. Canonical reconciliation is pending; the old Git view remains noncurrent.")
                         ((and entry (not (plist-get entry :observer-end-checked))
                               (plist-get entry :reobserve-in-flight))
                          "The stream ended. An exact Run status check is pending; its outcome is not yet verified. The old Git view remains noncurrent.")
                         ((and entry (not (plist-get entry :observer-end-checked)))
                          "The exact Run status check did not complete. Refresh to retry; the old Git view remains noncurrent.")
                         (t "The stream ended but the exact Run was still active. The old Git view is noncurrent. Refresh to check this Run; this observer will not reattach automatically."))))))
                  ((emacsos-assist-web-git--run-gated-p)
                   "The exact Run and canonical thread state still need verification. Refresh the Assist thread to check that Run before opening Git. Existing views are noncurrent.")
                  (t "Git state needs a fresh canonical thread check. Refresh before opening another view.")))
         (view (generate-new-buffer " *Assist Web Git status*")))
    (with-current-buffer view
      (insert reason "\n\nPress q to return.\n")
      (special-mode)
      (visual-line-mode 1)
      (setq-local emacsos-assist-web-git--display-details-thread thread)
      (local-set-key (kbd "q") #'emacsos-assist-web-git-display-details-back))
    (switch-to-buffer view)))

(defun emacsos-assist-web-git-details ()
  "Open the active recovery/access explanation or saved-history details."
  (interactive)
  (if (or (bound-and-true-p emacsos-assist-web--reconcile-recovery-paused)
          emacsos-assist-web-git--denied
          (emacsos-assist-web-git--run-gated-p)
          emacsos-assist-web-git--stopped-reobserve
          (bound-and-true-p emacsos-assist-web--manual-recovery-required))
      (emacsos-assist-web-git-status-details)
    (emacsos-assist-web-git-display-details)))

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

(defun emacsos-assist-web-git--thread-denial-reason ()
  "Return the stable visible reason for this buffer's thread denial."
  (if (eql emacsos-assist-web-git--thread-denial-status 404)
      "thread unavailable (404); reopen and Retry"
    (format "thread access denied (%d); reauthorize and Retry"
            emacsos-assist-web-git--thread-denial-status)))

(defun emacsos-assist-web-git--canonical-denied-local (status)
  "Latch canonical HTTP STATUS denial before fallible presentation."
  (cl-incf emacsos-assist-web-git--auth-epoch)
  (setq emacsos-assist-web-git--thread-denial-floor
        emacsos-assist-web-git--auth-epoch)
  (setq emacsos-assist-web-git--denied t
        emacsos-assist-web-git--thread-denial-status status
        emacsos-assist-web-git--run-recheck-needed nil)
  (cl-incf emacsos-assist-web-git--observation)
  (cl-incf emacsos-assist-web-git--epoch)
  (when emacsos-assist-web-git--current
    (setf (emacsos-assist-web-git-generation-state
           emacsos-assist-web-git--current) 'cached))
  (setq emacsos-assist-web-git--metadata nil
        emacsos-assist-web-git--unavailable
        (emacsos-assist-web-git--thread-denial-reason)))

(defun emacsos-assist-web-git--canonical-denied (status)
  "Fence every live buffer for this thread after definitive HTTP STATUS."
  (let* ((tid emacsos-assist-web--thread-id)
         (source (current-buffer))
         targets)
    ;; The safety latch reaches every same-T buffer before any release,
    ;; cancellation, header, or echo-area operation can signal.
    (let ((inhibit-quit t))
      (emacsos-assist-web-git--canonical-denied-local status)
      (setq targets (list source))
      (dolist (buffer (buffer-list))
        (when (and tid (not (eq buffer source))
                   (equal (buffer-local-value
                           'emacsos-assist-web--thread-id buffer) tid))
          (push buffer targets)))
      (dolist (buffer targets)
        (unless (eq buffer source)
          (with-current-buffer buffer
            (emacsos-assist-web-git--canonical-denied-local status))))
      (dolist (buffer targets)
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (condition-case nil
                (emacsos-assist-web-git--invalidate
                 emacsos-assist-web-git--unavailable)
              ((error quit) nil))))))
    (when (buffer-live-p source)
      (with-current-buffer source
        (condition-case nil
            (message "Thread Git: %s" emacsos-assist-web-git--unavailable)
          ((error quit) nil))))))

(defun emacsos-assist-web-git--run-record (tid run-id)
  "Return the outstanding safety record for exact TID and RUN-ID."
  (seq-find (lambda (record)
              (and (equal (plist-get record :tid) tid)
                   (equal (plist-get record :run-id) run-id)))
            emacsos-assist-web-git--run-outcome-uncertain))

(defun emacsos-assist-web-git--claim-orphaned-run-gate (tid run-id)
  "Claim a dead owner's TID/RUN-ID gate for this exact saved Run receipt.
Only a resident queue entry or accepted legacy receipt may claim the gate."
  (when (and (equal tid emacsos-assist-web--thread-id)
             (or (seq-some (lambda (entry)
                             (equal run-id (plist-get entry :run-id)))
                           emacsos-assist-web--queue)
                 (and emacsos-assist-web--pending-accepted-p
                      (equal run-id emacsos-assist-web--run-id))))
  (let ((local (emacsos-assist-web-git--run-record tid run-id)))
    (unless (and local (buffer-live-p (plist-get local :origin)))
    (let ((origin (and local (plist-get local :origin))))
      (dolist (buffer (buffer-list))
        (when (and (not origin) (not (eq buffer (current-buffer))))
          (with-current-buffer buffer
            (when-let ((record (emacsos-assist-web-git--run-record tid run-id)))
              (when (and (plist-get record :origin)
                         (not (buffer-live-p (plist-get record :origin))))
                (setq origin (plist-get record :origin)))))))
      (when origin
        (let ((new-owner (current-buffer))
              (epoch (cl-incf emacsos-assist-web-git--auth-epoch)))
          (if local
              (setf (plist-get local :epoch) epoch
                    (plist-get local :origin) new-owner)
            (push (list :tid tid :run-id run-id :epoch epoch
                        :origin new-owner)
                  emacsos-assist-web-git--run-outcome-uncertain))
          (setq emacsos-assist-web-git--denied 'run)
          (emacsos-assist-web-git--invalidate
           "Run status unavailable; Refresh thread")
          (dolist (buffer (buffer-list))
            (with-current-buffer buffer
              (dolist (record emacsos-assist-web-git--run-outcome-uncertain)
                (when (and (eq (plist-get record :origin) origin)
                           (equal (plist-get record :tid) tid)
                           (equal (plist-get record :run-id) run-id))
                  (setf (plist-get record :origin) new-owner))))))))))))

(defun emacsos-assist-web-git--run-recheck-start (tid run-id)
  "Make a superseding exact TID/RUN-ID read noncurrent until it commits."
  (unless (emacsos-assist-web-git--run-record tid run-id)
    (push (list :tid tid :run-id run-id
                :epoch emacsos-assist-web-git--auth-epoch)
          emacsos-assist-web-git--run-outcome-uncertain))
  (when emacsos-assist-web-git--current
    (setf (emacsos-assist-web-git-generation-state
           emacsos-assist-web-git--current) 'cached))
  (setq emacsos-assist-web-git--unavailable
        "Run recheck pending; Refresh")
  (emacsos-assist-web-git--update-headers))

(defun emacsos-assist-web-git--run-read-superseded-p (tid run-id start-epoch)
  "Whether a later thread or Run denial superseded TID/RUN-ID's GET."
  (or (and (> emacsos-assist-web-git--thread-denial-floor 0)
           (or (not (integerp start-epoch))
               (< start-epoch emacsos-assist-web-git--thread-denial-floor)))
      (when-let ((record (emacsos-assist-web-git--run-record tid run-id)))
        (or (not (integerp start-epoch))
            (< start-epoch (plist-get record :epoch))))))

(defun emacsos-assist-web-git--run-access-uncertain (status run-id)
  "Fence Git for exact RUN-ID after HTTP STATUS, preserving stronger denial."
  (let* ((thread (current-buffer))
         (tid emacsos-assist-web--thread-id)
         (strong (eq emacsos-assist-web-git--denied t))
         (epoch (cl-incf emacsos-assist-web-git--auth-epoch)))
    (setq emacsos-assist-web-git--run-outcome-uncertain
          (cons (list :tid tid :run-id run-id :epoch epoch
                      :origin thread)
                (seq-remove (lambda (record)
                              (and (equal (plist-get record :tid) tid)
                                   (equal (plist-get record :run-id) run-id)))
                            emacsos-assist-web-git--run-outcome-uncertain)))
    ;; Canonical ownership may temporarily span source and destination buffers.
    ;; Their pinned views and in-flight fetches must share this exact denial.
    (dolist (other (buffer-list))
      (when (and (not (eq other thread))
                 (with-current-buffer other
                   (and (derived-mode-p 'emacsos-assist-web-mode)
                        (equal emacsos-assist-web--thread-id tid))))
        (with-current-buffer other
          (let ((other-epoch (cl-incf emacsos-assist-web-git--auth-epoch)))
            (push (list :tid tid :run-id run-id :epoch other-epoch
                        :origin thread)
                  emacsos-assist-web-git--run-outcome-uncertain)
            (unless (eq emacsos-assist-web-git--denied t)
              (setq emacsos-assist-web-git--denied 'run)
              (condition-case nil
                  (emacsos-assist-web-git--invalidate
                   (format "Run status unavailable (%d); Refresh thread" status))
                ((error quit) nil)))))))
    (unless strong
      (setq emacsos-assist-web-git--denied 'run
            emacsos-assist-web-git--run-recheck-needed epoch)
      (emacsos-assist-web-git--invalidate
       (format "Run status unavailable (%d); Refresh thread" status))
      ;; One newer thread GET determines access, not the Run outcome.
      (run-at-time
       0 nil
       (lambda ()
         (when (buffer-live-p thread)
           (with-current-buffer thread
             (emacsos-assist-web-git--maybe-run-recheck))))))))

(defun emacsos-assist-web-git--maybe-run-recheck ()
  "Start one auth-only thread GET after an exact Run access fence."
  (when-let ((epoch emacsos-assist-web-git--run-recheck-needed))
    (cond
     ((or (not (eq emacsos-assist-web-git--denied 'run))
          (/= epoch emacsos-assist-web-git--auth-epoch))
      (setq emacsos-assist-web-git--run-recheck-needed nil))
     ((bound-and-true-p emacsos-assist-web--reconcile-recovery-paused)
      (setq emacsos-assist-web-git--run-recheck-needed nil)
      (emacsos-assist-web-git--invalidate
       "local recovery could not be saved; restart to recover"))
     ((bound-and-true-p emacsos-assist-web--reconcile-generation) nil)
     (t
      (setq emacsos-assist-web-git--run-recheck-needed nil)
      (let ((thread (current-buffer))
            (tid emacsos-assist-web--thread-id)
            (manual (bound-and-true-p emacsos-assist-web--manual-recovery-required)))
        (condition-case nil
            ;; This authenticates thread scope only.  It never renders,
            ;; caches, retires a queue entry, or projects Git metadata.
            (emacsos-assist-web--request
             "GET" (concat "threads/" (emacsos-assist-web--require-id tid)) nil
             (lambda (value problem)
               (when (and (buffer-live-p thread) (not problem))
                 (with-current-buffer thread
                   (when (and (equal tid emacsos-assist-web--thread-id)
                              (eql epoch emacsos-assist-web-git--auth-epoch)
                              (eq emacsos-assist-web-git--denied 'run)
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
                           (emacsos-assist-web-git--canonical-authorized epoch))
                       (error nil)))))))
          (error (emacsos-assist-web-git--canonical-uncertain))))))))

(defun emacsos-assist-web-git--canonical-uncertain ()
  "Downgrade freshness after a failed chat-owned canonical refresh attempt."
  (unless emacsos-assist-web-git--denied
    (let ((intents (plist-get emacsos-assist-web-git--pending :intents)))
      (let ((inhibit-quit t))
        (when emacsos-assist-web-git--current
          (setf (emacsos-assist-web-git-generation-state
                 emacsos-assist-web-git--current) 'cached))
        (cl-incf emacsos-assist-web-git--epoch)
        (setq emacsos-assist-web-git--pending nil)
        ;; An earlier final read cannot install after this failed chat check.
        (when emacsos-assist-web-git--request
          (emacsos-assist-web-git--request-put
           emacsos-assist-web-git--request :epoch emacsos-assist-web-git--epoch))
        (setq emacsos-assist-web-git--unavailable
              (if emacsos-assist-web-git--current
                  "canonical refresh unavailable; existing views only; Retry"
                "canonical refresh unavailable; no mirror; Retry")))
      ;; The safety latch precedes fallible window and echo-area feedback.
      (when intents
        (condition-case nil
            (emacsos-assist-web-git--release-intents
             intents "canonical refresh unavailable; pending; Retry")
          ((error quit) nil)))
      (condition-case nil (emacsos-assist-web-git--update-headers)
        ((error quit) nil)))))

(defun emacsos-assist-web-git--canonical-authorized (start-epoch)
  "Clear thread denial after validated canonical GET begun at START-EPOCH.
An auth-only GET leaves exact Run outcome uncertain."
  (when (and emacsos-assist-web-git--denied
             (eql start-epoch emacsos-assist-web-git--auth-epoch))
    (let ((thread-denial (eq emacsos-assist-web-git--denied t))
          (tid emacsos-assist-web--thread-id))
    (setq emacsos-assist-web-git--denied nil
          emacsos-assist-web-git--thread-denial-status nil
          emacsos-assist-web-git--run-recheck-needed nil)
    (when thread-denial
      (dolist (buffer (buffer-list))
        (unless (eq buffer (current-buffer))
          (with-current-buffer buffer
            (when (and (derived-mode-p 'emacsos-assist-web-mode)
                       (equal emacsos-assist-web--thread-id tid)
                       (eq emacsos-assist-web-git--denied t))
              (setq emacsos-assist-web-git--denied nil
                    emacsos-assist-web-git--thread-denial-status nil)
              (condition-case nil
                  (emacsos-assist-web-git--update-headers)
                ((error quit) nil)))))))
    (dolist (item (copy-sequence emacsos-assist-web-git--feedback-windows))
      (when (window-live-p (car item))
        (emacsos-assist-web-git--clear-feedback (car item))))
    (emacsos-assist-web-git--update-headers))))

(defun emacsos-assist-web-git--run-status-confirmed (tid run-id start-epoch)
  "Clear TID/RUN-ID's warning only after post-denial durable acceptance.
The caller owns both the exact Run GET and subsequent canonical commit."
  (let ((inhibit-quit t))
    (when-let ((record (emacsos-assist-web-git--run-record tid run-id)))
    (when (and (or (not (plist-get record :origin))
                   (eq (plist-get record :origin) (current-buffer)))
               (integerp start-epoch)
               (>= start-epoch emacsos-assist-web-git--thread-denial-floor)
               (<= (plist-get record :epoch) start-epoch))
      (let ((origin (current-buffer)))
        (setq emacsos-assist-web-git--run-outcome-uncertain
              (delq record emacsos-assist-web-git--run-outcome-uncertain))
        (when (and (equal tid (plist-get emacsos-assist-web-git--busy-check :tid))
                   (equal run-id (plist-get emacsos-assist-web-git--busy-check
                                            :run-id)))
          (setq emacsos-assist-web-git--busy-check nil))
        (dolist (other (buffer-list))
          (when (and (not (eq other origin))
                     (with-current-buffer other
                       (and (derived-mode-p 'emacsos-assist-web-mode)
                            (equal emacsos-assist-web--thread-id tid))))
            (with-current-buffer other
              (setq emacsos-assist-web-git--run-outcome-uncertain
                    (seq-remove
                     (lambda (candidate)
                       (and (eq (plist-get candidate :origin) origin)
                            (equal (plist-get candidate :tid) tid)
                            (equal (plist-get candidate :run-id) run-id)))
                     emacsos-assist-web-git--run-outcome-uncertain))
              (when (and (eq emacsos-assist-web-git--denied 'run)
                         (not emacsos-assist-web-git--run-outcome-uncertain))
                (setq emacsos-assist-web-git--denied nil))
              (condition-case nil
                  (emacsos-assist-web-git--update-headers)
                ((error quit) nil))))))
      ;; Presentation must not interrupt an already durable Run retirement.
      (condition-case nil
          (emacsos-assist-web-git--update-headers)
        ((error quit) nil))))))

(defun emacsos-assist-web-git--retire-stopped-reobserve (tid run-id)
  "Clear a stopped observer only after exact TID/RUN-ID durable retirement."
  (let ((inhibit-quit t))
    (when-let ((stop (emacsos-assist-web-git--shared-stop tid run-id)))
      (emacsos-assist-web-git--shared-stop-clear
       tid run-id (plist-get stop :entry)))
    (when (and (equal tid (plist-get emacsos-assist-web-git--stopped-reobserve :tid))
               (equal run-id
                      (plist-get emacsos-assist-web-git--stopped-reobserve :run-id)))
      (setq emacsos-assist-web-git--stopped-reobserve nil)
      (condition-case nil
          (emacsos-assist-web-git--update-headers)
        ((error quit) nil)))))

(defun emacsos-assist-web-git--stop-reobserve
    (entry &optional kind preserve-generation)
  "Make ENTRY's stopped Run KIND noncurrent until committed Run/T recheck.
PRESERVE-GENERATION keeps the older stop floor during its exact recheck."
  (let ((inhibit-quit t))
    ;; A disconnect or a newer exact status supersedes any earlier T join.
    ;; Its callback must not clear this newly established stop.
    (setq emacsos-assist-web-git--busy-check nil)
    (setq emacsos-assist-web-git--stopped-reobserve
          (list :entry entry :tid emacsos-assist-web--thread-id
                :run-id (plist-get entry :run-id)
                :generation (if preserve-generation
                                (if (eq entry
                                        (plist-get emacsos-assist-web-git--stopped-reobserve
                                                   :entry))
                                    (plist-get emacsos-assist-web-git--stopped-reobserve
                                               :generation)
                                  (1- (or (plist-get entry :reobserve-generation) 0)))
                              (plist-get entry :reobserve-generation))
                :kind kind))
    (when-let* ((tid emacsos-assist-web--thread-id)
                (run-id (plist-get entry :run-id))
                (record (emacsos-assist-web-git--thread-safety-record
                         tid t)))
      (let ((prior (seq-find
                    (lambda (candidate)
                      (equal (plist-get candidate :run-id) run-id))
                    (plist-get record :stops))))
        (setf (plist-get record :stops)
              (cons (list :run-id run-id :entry entry :owner (current-buffer)
                          :key (plist-get entry :key) :kind kind
                          :ordinal (or (cl-position entry emacsos-assist-web--queue)
                                       0)
                          :queue-entries (copy-sequence emacsos-assist-web--queue)
                          :draft-name (plist-get prior :draft-name)
                          :draft-digest (plist-get prior :draft-digest)
                          :recovery nil)
                    (seq-remove (lambda (stop)
                                  (equal (plist-get stop :run-id) run-id))
                                (plist-get record :stops)))))
      ;; The shared record is authoritative even if one peer's presentation
      ;; later signals.  Every pre-stop final/fetch sees its old local epoch.
      (dolist (buffer (plist-get record :buffers))
        (when (and (buffer-live-p buffer)
                   (not (eq buffer (current-buffer))))
          (with-current-buffer buffer
            (cl-incf emacsos-assist-web-git--epoch)
            (when emacsos-assist-web-git--current
              (setf (emacsos-assist-web-git-generation-state
                     emacsos-assist-web-git--current) 'cached))))))
    (cl-incf emacsos-assist-web-git--epoch)
    (when emacsos-assist-web-git--current
      (setf (emacsos-assist-web-git-generation-state
             emacsos-assist-web-git--current) 'cached))
    (setq emacsos-assist-web-git--unavailable
          (emacsos-assist-web-git--stopped-label)))
  (condition-case nil (emacsos-assist-web-git--update-headers)
    ((error quit) nil)))

(defun emacsos-assist-web-git--stopped-label ()
  "Return the short, evidence-specific stopped-observer label."
  (let ((entry (plist-get emacsos-assist-web-git--stopped-reobserve :entry)))
    (pcase (plist-get emacsos-assist-web-git--stopped-reobserve :kind)
    ('disconnect "Observation unavailable; Refresh")
    ('operator-repair "Operator repair")
    ('active-check
     (if (plist-get emacsos-assist-web-git--busy-check :t-accepted)
         "Run observer connecting"
       "Run canonical check pending"))
    ('terminal-verified "Run reconciling")
    ('approval "Approval pending; Refresh")
    (_ (cond
        ((and entry (not (plist-get entry :observer-end-checked))
              (plist-get entry :verified-outcome))
         "Run reconciling")
        ((and entry (not (plist-get entry :observer-end-checked))
              (plist-get entry :reobserve-in-flight))
         "Run checking")
        ((and entry (not (plist-get entry :observer-end-checked)))
         "Run check failed; Refresh")
        (t "Run changed; Refresh"))))))

(defun emacsos-assist-web-git--stopped-reobserve-owner-p (entry)
  "Whether ENTRY is a fresh exact recheck of the stopped observer."
  (let ((marker emacsos-assist-web-git--stopped-reobserve))
    (and marker (eq entry (plist-get marker :entry))
         (equal (plist-get entry :run-id) (plist-get marker :run-id))
         (> (or (plist-get entry :reobserve-generation) 0)
            (or (plist-get marker :generation) 0)))))

(defun emacsos-assist-web-git--busy-check-owner-p (token)
  "Whether TOKEN still belongs to a live active exact Run receipt."
  (let ((entry (plist-get token :entry))
        (run-id (plist-get token :run-id)))
    (and (equal (plist-get token :tid) emacsos-assist-web--thread-id)
         (if entry
             (and (memq entry emacsos-assist-web--queue)
                  (equal run-id (plist-get entry :run-id))
                  (eql (plist-get token :generation)
                       (plist-get entry :reobserve-generation))
                  (memq (plist-get entry :state)
                        '(accepted-unobserved observing)))
           (and emacsos-assist-web--pending-accepted-p
                (equal run-id emacsos-assist-web--run-id)
                (eql (plist-get token :send-generation)
                     emacsos-assist-web--send-generation)
                (eql (plist-get token :terminal-generation)
                     emacsos-assist-web--legacy-terminal-generation))))))

(defun emacsos-assist-web-git--busy-check-start (token)
  "Start one bounded post-save canonical T read for TOKEN."
  (when (and (eq token emacsos-assist-web-git--busy-check)
             (not (plist-get token :in-flight))
             (emacsos-assist-web-git--busy-check-owner-p token))
    (when (eq (plist-get token :stage) 'r3)
      (setf (plist-get token :post-barrier) t))
    (setf (plist-get token :in-flight) t
          (plist-get token :serial) (1+ (or (plist-get token :serial) 0)))
    (let ((thread (current-buffer))
          (serial (plist-get token :serial))
          (tid (plist-get token :tid))
          (run-id (plist-get token :run-id))
          (run-start (plist-get token :run-start))
          (auth-start emacsos-assist-web-git--auth-epoch)
          (refresh (cl-incf emacsos-assist-web--refresh-generation))
          (canonical-token (emacsos-assist-web-git--canonical-start t)))
      (emacsos-assist-web--request
       "GET" (concat "threads/" (emacsos-assist-web--require-id tid)) nil
       (lambda (snapshot problem)
         (when (buffer-live-p thread)
           (with-current-buffer thread
             (when (and (eq token emacsos-assist-web-git--busy-check)
                        (eql serial (plist-get token :serial)))
               (setf (plist-get token :in-flight) nil)
               (if (or problem
                       (not (emacsos-assist-web-git--busy-check-owner-p token))
                       (not (eql refresh emacsos-assist-web--refresh-generation))
                       (not (eql auth-start emacsos-assist-web-git--auth-epoch))
                       (emacsos-assist-web-git--run-read-superseded-p
                        tid run-id run-start))
                   (unless emacsos-assist-web-git--denied
                     (setq emacsos-assist-web-git--unavailable
                           "Run status; Refresh retries canonical check")
                     (emacsos-assist-web-git--canonical-failed
                      canonical-token "Run status; Refresh retries canonical check"))
                 (condition-case nil
                     (let* ((_ (emacsos-assist-web--require-snapshot snapshot tid))
                            (busy (emacsos-assist-web--snapshot-active-p snapshot))
                            (metadata (emacsos-assist-web-git--metadata-from-snapshot
                                       snapshot))
                            (key (emacsos-assist-web-git--request-key metadata))
                            (changed
                             (not (equal
                                   key
                                   (emacsos-assist-web-git--request-key
                                    emacsos-assist-web-git--metadata))))
                            (drift (and (eq (plist-get token :stage) 'r3)
                                        (plist-get token :post-barrier)
                                        (not (equal key
                                                    (plist-get token
                                                               :candidate-key))))))
                       (unless busy (error "exact Run still needs terminal reconciliation"))
                       (when drift
                         ;; R3 began after H2's barrier, not after this newly
                         ;; observed H3.  Never let it certify its own change.
                         (cl-incf emacsos-assist-web-git--epoch)
                         (when emacsos-assist-web-git--current
                           (setf (emacsos-assist-web-git-generation-state
                                  emacsos-assist-web-git--current) 'cached))
                         (setf (plist-get token :candidate-key) key
                               (plist-get token :post-barrier) nil)
                         (setq emacsos-assist-web-git--unavailable
                               "repository changed again; Refresh"))
                       (when (and changed (not (eq (plist-get token :stage) 'r3)))
                         ;; This read predates the key-conflict barrier.  It
                         ;; cannot resolve its own conflict or open Git.
                         (cl-incf emacsos-assist-web-git--epoch)
                         (when emacsos-assist-web-git--current
                           (setf (emacsos-assist-web-git-generation-state
                                  emacsos-assist-web-git--current) 'cached))
                         (setq emacsos-assist-web-git--unavailable
                               "repository changed; checking canonical state")
                         (setf (plist-get token :stage) 'r3
                               (plist-get token :candidate-key) key)
                         (emacsos-assist-web-git--update-headers))
                       (cond
                        (drift
                         (emacsos-assist-web-git--canonical-failed
                          canonical-token "repository changed again; Refresh"))
                        ((and changed (eq (plist-get token :stage) 'r3)
                              (not (plist-get token :post-barrier)))
                         (setf (plist-get token :post-barrier) t)
                         (emacsos-assist-web-git--busy-check-start token))
                        ((not (emacsos-assist-web--try-write-cache
                               (emacsos-assist-web--snapshot-cache-name tid)
                               snapshot))
                         (setq emacsos-assist-web-git--unavailable
                               "canonical cache unavailable; Refresh")
                         (emacsos-assist-web-git--canonical-failed
                          canonical-token "canonical cache unavailable; Refresh"))
                        (t
                           (setq emacsos-assist-web--snapshot snapshot)
                           (emacsos-assist-web-git--canonical-authorized
                            auth-start)
                           (emacsos-assist-web-git--run-status-confirmed
                            tid run-id run-start)
                           (emacsos-assist-web-git--canonical-accepted
                            metadata nil canonical-token)
                           (setf (plist-get token :t-accepted) t)
                           (emacsos-assist-web-git--finish-active-join
                            (plist-get token :entry)))))
                   ((error quit)
                    (emacsos-assist-web-git--invalidate
                     "Run status or Git projection unavailable; Retry")
                    (emacsos-assist-web-git--canonical-failed
                     canonical-token "Run status; Refresh retries canonical check"))))
               (emacsos-assist-web-git--update-headers)))))))))

(defun emacsos-assist-web-git--confirm-active-run
    (tid run-id start-epoch &optional entry)
  "After a durable active RUN-ID read, reconcile one nonready TID snapshot.
ENTRY is a stopped queue owner, or nil for a legacy accepted receipt.
A queue ENTRY requires admitted HTTP 200 SSE headers before opening Git.
A durable approval stop is cleared only after the joined observer is saved."
  (when (or (emacsos-assist-web-git--run-record tid run-id)
            (and entry
                 (emacsos-assist-web-git--stopped-reobserve-owner-p entry)))
    (let ((token (list :tid tid :run-id run-id :run-start start-epoch
                       :entry entry
                       :generation (and entry
                                        (plist-get entry :reobserve-generation))
                       :send-generation emacsos-assist-web--send-generation
                       :terminal-generation
                       emacsos-assist-web--legacy-terminal-generation
                       :t-accepted nil
                       :stage 'initial :post-barrier nil :candidate-key nil
                       :in-flight nil :serial 0)))
      (setq emacsos-assist-web-git--busy-check token)
      (emacsos-assist-web-git--busy-check-start token))))

(defun emacsos-assist-web-git--finish-active-join (entry)
  "Release ENTRY's active Run fence after canonical T acceptance.
A stopped queue ENTRY also needs admitted SSE headers.  Its old stop reason
is durably superseded before the opening gate is removed."
  (let ((token emacsos-assist-web-git--busy-check))
    (when (and token (eq entry (plist-get token :entry))
               (plist-get token :t-accepted)
               (emacsos-assist-web-git--busy-check-owner-p token)
               (or (not entry)
                   (and (eq entry emacsos-assist-web--stream-entry)
                        (process-live-p (plist-get entry :stream-process))
                        (buffer-live-p (plist-get entry :stream-response))
                        (plist-get entry :stream-admitted)
                        (> (or (plist-get entry :stream-generation) 0)
                           (or (plist-get entry :observer-end-generation) 0)))))
      (let ((inhibit-quit t))
        (let ((saved
               (if (and entry
                        (emacsos-assist-web-git--stopped-reobserve-owner-p
                         entry))
                   (let ((old-kind (plist-get entry :observer-end-kind))
                         (old-generation
                          (plist-get entry :observer-end-generation))
                         (old-checked (plist-get entry :observer-end-checked))
                         (old-approval (plist-get entry :approval-stopped)))
                     ;; A crash ends this newly admitted observer.  Its old
                     ;; operator-repair/approval reason is no longer true,
                     ;; but its generation fence must survive the restart.
                     (setf (plist-get entry :approval-stopped) nil
                           (plist-get entry :observer-end-kind) 'disconnect
                           (plist-get entry :observer-end-generation)
                           (plist-get entry :stream-generation)
                           (plist-get entry :observer-end-checked) nil)
                     (if (condition-case nil
                             (emacsos-assist-web--save-draft)
                           ((error quit) nil))
                         t
                       (setf (plist-get entry :approval-stopped) old-approval
                             (plist-get entry :observer-end-kind) old-kind
                             (plist-get entry :observer-end-generation)
                             old-generation
                             (plist-get entry :observer-end-checked)
                             old-checked)
                       nil))
                 t)))
          (if saved
              (progn
                (when (and entry
                           (emacsos-assist-web-git--stopped-reobserve-owner-p
                            entry))
                  (emacsos-assist-web-git--shared-stop-clear
                   (plist-get token :tid) (plist-get token :run-id) entry)
                  (setq emacsos-assist-web-git--stopped-reobserve nil))
                (setq emacsos-assist-web-git--busy-check nil)
                (when (equal emacsos-assist-web-git--unavailable
                             "Run canonical check pending")
                  (setq emacsos-assist-web-git--unavailable nil)))
            (setq emacsos-assist-web--reconcile-recovery-paused t)
            (condition-case nil
                (emacsos-assist-web-git--invalidate
                 "local observer recovery could not be saved; restart to recover")
              ((error quit) nil)))))
      (condition-case nil (emacsos-assist-web-git--update-headers)
        ((error quit) nil)))))

(defun emacsos-assist-web-git--retry-busy-check ()
  "Retry or join this active exact Run's post-save T check, if any."
  (when-let ((token emacsos-assist-web-git--busy-check))
    (when (emacsos-assist-web-git--busy-check-owner-p token)
      (if (plist-get token :t-accepted)
          (message "Run observer connecting; result will appear here")
        (if (plist-get token :in-flight)
          (message "Run canonical check in progress; result will appear here")
          (emacsos-assist-web-git--busy-check-start token)))
      t)))

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
     ((emacsos-assist-web-git--run-gated-p)
      (when intent
        (emacsos-assist-web-git--release-intents
         (list intent) "Run status unavailable; Refresh thread")))
     (emacsos-assist-web-git--r2-waiting
      (when intent
        (emacsos-assist-web-git--request-put
         emacsos-assist-web-git--r2-waiting :intents
         (emacsos-assist-web-git--live-intents
          (plist-get emacsos-assist-web-git--r2-waiting :intents)
          (list intent)))))
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
            (setf (plist-get request :intents) nil))
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
                                   (emacsos-assist-web-git--cleanup-failed))))))))
                       ((< (or (plist-get request :cause-at-start) 0)
                           emacsos-assist-web-git--success-watermark)
                        (emacsos-assist-web-git--finish-obsolete request))
                       ((plist-get result :ok)
                        (emacsos-assist-web-git--final-check request result))
                       (t
                        (condition-case nil
                            (emacsos-assist-web-git--cleanup
                             id "staging"
                             (lambda (ok)
                               (when (buffer-live-p thread)
                                 (with-current-buffer thread
                                   (if ok
                                       (emacsos-assist-web-git--failed
                                        request (plist-get result :reason))
                                     (emacsos-assist-web-git--cleanup-failed))))))
                          ((error quit)
                           (emacsos-assist-web-git--cleanup-failed)))))))))))
          (emacsos-assist-web-git--request-put request :process process))
      (error
       (emacsos-assist-web-git--failed
        request (error-message-string error))))))

(defun emacsos-assist-web-git--failed (request reason)
  "Preserve the last good view after REQUEST fails with safe REASON."
  (when (eq request emacsos-assist-web-git--request)
    (setq emacsos-assist-web-git--request nil)
    (if (and emacsos-assist-web-git--next
             (< (or (plist-get request :cause-at-start) 0)
                emacsos-assist-web-git--success-watermark))
        (emacsos-assist-web-git--run-next)
      (setq emacsos-assist-web-git--unavailable reason)
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
       (format "%s; Refresh to retry" reason)))))

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
            ((< (or (plist-get request :cause-at-start) 0)
                emacsos-assist-web-git--success-watermark)
             (emacsos-assist-web-git--finish-obsolete request))
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
                        (not emacsos-assist-web-git--r2-waiting)
                        (not emacsos-assist-web-git--denied)
                        (not (emacsos-assist-web-git--run-gated-p))
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
                   (emacsos-assist-web-git--finish-obsolete request)
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
                      (state (if (and (not emacsos-assist-web-git--stopped-reobserve)
                                      (equal (plist-get
                                              (plist-get request :metadata) :status)
                                             "ready"))
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
     ((or emacsos-assist-web-git--denied
          (emacsos-assist-web-git--run-gated-p))
      (emacsos-assist-web-git--release-intents
       (list intent)
       (if (or (eq emacsos-assist-web-git--denied 'run)
               (emacsos-assist-web-git--run-gated-p))
           "Run status unavailable; Refresh thread"
         "thread access unavailable; reauthorize and Retry")))
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
     (emacsos-assist-web-git--r2-waiting
      (emacsos-assist-web-git--conflict-during-r2 metadata intent))
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
  (when-let ((reason (emacsos-assist-web-git--gate-reason)))
    (user-error "%s" reason))
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
      (when-let ((reason (with-current-buffer thread
                          (emacsos-assist-web-git--gate-reason))))
        (user-error "%s" reason))
      (when (with-current-buffer thread emacsos-assist-web-git--pending)
        (user-error "Thread Git repository change pending; Retry"))
      (when (with-current-buffer thread emacsos-assist-web-git--r2-waiting)
        (user-error "Thread Git canonical reconciliation pending; Retry"))
      (when (with-current-buffer thread
              (and (> emacsos-assist-web-git--auth-epoch 0)
                   (not (eql emacsos-assist-web-git--auth-epoch
                             (emacsos-assist-web-git-generation-auth-epoch
                              generation)))))
        (user-error "Thread Git mirror predates authorization; Retry"))
      (pcase (plist-get intent :action)
        ('files
         (let* ((prompt (format "Git %s file: "
                                (emacsos-assist-web-git--short
                                 (emacsos-assist-web-git-generation-oid generation))))
                (exit (list nil))
                chooser-buffer
                (choice
                 (unwind-protect
                     (let ((minibuffer-setup-hook
                            (cons (lambda ()
                                    ;; This hook is dynamically visible to a
                                    ;; nested minibuffer.  Only the original
                                    ;; chooser may own its pin and exit tag.
                                    (unless chooser-buffer
                                      (setq chooser-buffer (current-buffer))
                                      (use-local-map
                                       (copy-keymap
                                        (or (current-local-map)
                                            (make-sparse-keymap))))
                                      (setq-local
                                       emacsos-assist-web-git--chooser-thread thread
                                       emacsos-assist-web-git--chooser-generation
                                       generation
                                       emacsos-assist-web-git--chooser-exit exit
                                       header-line-format
                                       '(:eval (emacsos-assist-web-git--chooser-header)))
                                      (local-set-key (kbd "C-c ?")
                                                     #'emacsos-assist-web-git-chooser-details)
                                      (local-set-key (kbd "C-c b")
                                                     #'emacsos-assist-web-git-chooser-back)
                                      (cl-pushnew chooser-buffer
                                                  (emacsos-assist-web-git-generation-views
                                                   generation))))
                                  minibuffer-setup-hook)))
                       (condition-case nil
                           (read-file-name prompt default-directory nil t)
                         (quit nil)))
                   (setf (emacsos-assist-web-git-generation-views generation)
                         (delq chooser-buffer
                               (emacsos-assist-web-git-generation-views generation))))))
           (cond
            ((eq (car exit) 'back)
             (when (emacsos-assist-web-git--intent-live-p intent)
               (set-window-parameter window 'assist-web-git-intent
                                     (1+ (plist-get intent :serial)))
               (emacsos-assist-web-git--clear-feedback window)
               (set-window-buffer window thread))
             (message "File selection cancelled; C-x C-f to retry"))
            ((eq (caar exit) 'details)
             (when (emacsos-assist-web-git--intent-live-p intent)
               (set-window-parameter window 'assist-web-git-intent
                                     (1+ (plist-get intent :serial)))
               (emacsos-assist-web-git--clear-feedback window)
               (with-selected-window window
                 (emacsos-assist-web-git--show-view-details
                  generation thread thread (cdar exit)))))
            ((not choice)
             (signal 'quit nil))
            ((emacsos-assist-web-git--intent-live-p intent)
             (unless (with-current-buffer thread
                       (and (not emacsos-assist-web-git--denied)
                            (not (emacsos-assist-web-git--run-gated-p))
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
                  (signal (car error) (cdr error)))))))))
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

(defun emacsos-assist-web-git-view-details ()
  "Explain this pinned view's immutable fetch and live freshness state."
  (interactive)
  (let* ((generation emacsos-assist-web-git--view-generation)
         (thread emacsos-assist-web-git--view-thread))
    (unless generation (user-error "This is not a pinned Git view"))
    (emacsos-assist-web-git--show-view-details
     generation thread (current-buffer) nil)))

(defun emacsos-assist-web-git--view-details-header ()
  "Return live pinned state or chooser snapshot, with a Back action."
  (let* ((generation emacsos-assist-web-git--details-generation)
         (thread emacsos-assist-web-git--details-thread)
         (snapshot emacsos-assist-web-git--details-chooser-snapshot)
         (state (unless snapshot
                  (emacsos-assist-web-git--view-state generation thread))))
    (concat (format "Git %s %s"
                    (emacsos-assist-web-git--short
                     (emacsos-assist-web-git-generation-oid generation))
                    (if snapshot "snapshot"
                      (emacsos-assist-web-git--short-state state)))
            (emacsos-assist-web-git--padded-action
             "Back" #'emacsos-assist-web-git-view-details-back))))

(defun emacsos-assist-web-git-view-details-back ()
  "Return to the exact pinned view, or thread after chooser Details."
  (interactive)
  (let ((origin emacsos-assist-web-git--details-origin))
    (if (buffer-live-p origin)
        (switch-to-buffer origin)
      (message "The originating view is closed"))))

(defun emacsos-assist-web-git--show-view-details
    (generation thread origin chooser-snapshot)
  "Show GENERATION provenance with Back to ORIGIN.
CHOOSER-SNAPSHOT is immutable state and selection saved at chooser exit;
otherwise the header follows THREAD's live state while the pinned view stays."
  (let* ((metadata (emacsos-assist-web-git-generation-metadata generation))
         (selected (or (cadr chooser-snapshot)
                       (and (buffer-live-p thread)
                            (with-current-buffer thread
                              emacsos-assist-web-git--metadata))))
         (selected-fetched
          (and (buffer-live-p thread) selected
               (with-current-buffer thread
                 (and emacsos-assist-web-git--current
                      (emacsos-assist-web-git--same-identity
                       selected
                       (emacsos-assist-web-git-generation-metadata
                        emacsos-assist-web-git--current))))))
         (view (generate-new-buffer " *Assist Web Git view details*")))
    (with-current-buffer view
      (insert (format "Fetched thread commit: %s\nFetched remote main base: %s\nFetched branch: %s\n"
                      (emacsos-assist-web-git-generation-oid generation)
                      (or (emacsos-assist-web-git-generation-main generation)
                          "unavailable")
                      (or (plist-get metadata :branch) "unavailable")))
      (when selected
        (insert (format "\nSelected branch %s: %s\nSelected expected commit %s: %s\n"
                        (if chooser-snapshot "at chooser exit" "when Details opened")
                        (or (plist-get selected :branch) "unavailable")
                        (if chooser-snapshot "at chooser exit" "when Details opened")
                        (or (plist-get selected :expected) "unavailable")))
        (unless (emacsos-assist-web-git--same-identity metadata selected)
          (insert (if selected-fetched
                      "The newer selection has already been fetched; this pinned fetch is historical.\n"
                    "The selection differs from this pinned fetch. Return to the thread for its live fetch state.\n"))))
      (when (not (equal (plist-get metadata :status) "ready"))
        (insert "\nThis is a last-published committed revision, not proof of the server's current working HEAD.")
        (when (member (plist-get metadata :status)
                      '("queued" "initializing" "cloning" "starting_sandbox"
                        "processing" "running" "pending" "transitioning"))
          (insert " It may change after the active turn."))
        (insert "\n"))
      (if chooser-snapshot
          (insert (format "\nChooser state at exit: %s (not live). File selection ended for Details. No file was selected; typed but unselected input was discarded. Back returns to the thread; C-x C-f starts a new chooser.\n"
                          (car chooser-snapshot)))
        (insert "\nThe header shows live freshness; this text records fetch-time provenance. Back returns to the pinned file or diff.\n"))
      (special-mode)
      (visual-line-mode 1)
      (setq-local emacsos-assist-web-git--details-generation generation
                  emacsos-assist-web-git--details-thread thread
                  emacsos-assist-web-git--details-origin origin
                  emacsos-assist-web-git--details-chooser-snapshot
                  chooser-snapshot
                  header-line-format
                  '(:eval (emacsos-assist-web-git--view-details-header)))
      (local-set-key (kbd "q") #'emacsos-assist-web-git-view-details-back)
      (local-set-key (kbd "C-c b") #'emacsos-assist-web-git-view-details-back))
    (switch-to-buffer view)))

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
