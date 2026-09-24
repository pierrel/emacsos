;;; test-assist-web-git.el --- Thread Git selection tests -*- lexical-binding: t -*-

(require 'ert)
(require 'assist-web)

(defconst test-assist-web-git--key "aaaaaaaaaaaaaaaaaaaa")
(defconst test-assist-web-git--head
  "1111111111111111111111111111111111111111")
(defconst test-assist-web-git--published
  "2222222222222222222222222222222222222222")
(defvar test-assist-web-git--executed nil)

(defun test-assist-web-git--snapshot (status branch &optional published-branch)
  "Make an authenticated-style STATUS snapshot with BRANCH and PUBLISHED-BRANCH."
  `((thread . ((id . "thread-1") (description . "Thread")
                (status . ,status)
                (workspace . ((repo_label . "Same label")
                              (repo_key . ,test-assist-web-git--key)
                              (branch . ,branch)
                              (revision . ,test-assist-web-git--head)
                              (published_branch . ,published-branch)
                              (published_revision . ,(and published-branch
                                                          test-assist-web-git--published))))))
    (messages . nil)))

(ert-deftest test-assist-web-git-ready-selects-actual-checkout ()
  (let ((metadata (emacsos-assist-web-git--metadata-from-snapshot
                   (test-assist-web-git--snapshot "ready" "topic/new"
                                                  "topic/old"))))
    (should (equal (plist-get metadata :branch) "topic/new"))
    (should (equal (plist-get metadata :expected)
                   test-assist-web-git--head))
    (should (emacsos-assist-web-git--usable metadata))))

(ert-deftest test-assist-web-git-busy-selects-published-pair-through-main ()
  (let* ((metadata (emacsos-assist-web-git--metadata-from-snapshot
                    (test-assist-web-git--snapshot "processing" "main"
                                                   "topic/old")))
         (same-pair (copy-sequence metadata)))
    (should (equal (plist-get metadata :branch) "topic/old"))
    (should (equal (plist-get metadata :expected)
                   test-assist-web-git--published))
    (setf (plist-get same-pair :head) test-assist-web-git--published)
    (should (equal (emacsos-assist-web-git--request-key metadata)
                   (emacsos-assist-web-git--request-key same-pair)))))

(ert-deftest test-assist-web-git-null-and-half-published-pair ()
  (let ((empty (emacsos-assist-web-git--metadata-from-snapshot
                (test-assist-web-git--snapshot "processing" "main"))))
    (should-not (emacsos-assist-web-git--usable empty)))
  (let ((broken (test-assist-web-git--snapshot "processing" "main")))
    (setf (alist-get 'published_revision
                    (alist-get 'workspace (alist-get 'thread broken)))
          test-assist-web-git--published)
    (should-error (emacsos-assist-web-git--metadata-from-snapshot broken))))

(ert-deftest test-assist-web-git-rejects-bad-repository-identity ()
  (let ((snapshot (test-assist-web-git--snapshot "ready" "topic/one")))
    (setf (alist-get 'repo_key
                    (alist-get 'workspace (alist-get 'thread snapshot)))
          "same-label")
    (should-error (emacsos-assist-web-git--metadata-from-snapshot snapshot))))

(ert-deftest test-assist-web-git-detached-head-is-not-a-branch-selection ()
  (let* ((snapshot (test-assist-web-git--snapshot "ready" "HEAD"))
         (metadata (emacsos-assist-web-git--metadata-from-snapshot snapshot)))
    (should-not (emacsos-assist-web-git--usable metadata))
    (with-temp-buffer
      (emacsos-assist-web-git--note-snapshot snapshot)
      (should (equal emacsos-assist-web-git--unavailable
                     "detached HEAD; Git unavailable"))
      (emacsos-assist-web-git--enqueue metadata nil)
      (should (equal emacsos-assist-web-git--unavailable
                     "detached HEAD; Git unavailable"))))
  (let ((snapshot (test-assist-web-git--snapshot
                   "processing" "main" "HEAD")))
    (should-error (emacsos-assist-web-git--metadata-from-snapshot snapshot))))

(ert-deftest test-assist-web-git-invalid-projection-clears-currentness ()
  (with-temp-buffer
    (let* ((valid (test-assist-web-git--snapshot "ready" "topic/one"))
           (broken (copy-tree valid))
           (metadata (emacsos-assist-web-git--metadata-from-snapshot valid))
           (generation (make-emacsos-assist-web-git-generation
                        :metadata metadata :state 'current)))
      (setf (alist-get 'published_revision
                      (alist-get 'workspace (alist-get 'thread broken)))
            test-assist-web-git--published)
      (setq-local emacsos-assist-web-git--metadata metadata
                  emacsos-assist-web-git--current generation)
      (emacsos-assist-web-git--note-snapshot broken)
      (should-not emacsos-assist-web-git--metadata)
      (should (equal emacsos-assist-web-git--unavailable
                     "Git state unavailable"))
      (should (equal (emacsos-assist-web-git--view-state
                      generation (current-buffer)) "stale")))))

(ert-deftest test-assist-web-git-invalid-authenticated-probe-fences-current ()
  "Malformed authenticated 200 projection is a shared safety failure."
  (save-window-excursion
    (let* ((thread (generate-new-buffer " *git-invalid-probe*"))
           (window (selected-window))
           (metadata (test-assist-web-git--metadata
                      "ready" "topic/old" test-assist-web-git--head))
           (generation (make-emacsos-assist-web-git-generation
                        :metadata metadata :state 'current))
           (intent (list :action 'files :buffer thread :window window :serial 1)))
      (unwind-protect
          (progn
            (set-window-buffer window thread)
            (set-window-parameter window 'assist-web-git-intent 1)
            (with-current-buffer thread
              (emacsos-assist-web-mode)
              (setq-local emacsos-assist-web--thread-id "thread-1"
                          emacsos-assist-web-git--metadata metadata
                          emacsos-assist-web-git--current generation)
              (emacsos-assist-web-git--route-probe
               intent nil '(canonical . "invalid snapshot")
               emacsos-assist-web-git--epoch)
              (should-not emacsos-assist-web-git--metadata)
              (should (eq (emacsos-assist-web-git-generation-state generation)
                          'cached))
              (should (equal emacsos-assist-web-git--unavailable
                             "Git state unavailable"))
              (should (= (window-parameter window 'assist-web-git-intent) 2))))
        (set-window-parameter window 'assist-web-git-intent nil)
        (kill-buffer thread)))))

(ert-deftest test-assist-web-git-run-404-fences-current-until-thread-get ()
  "A missing exact Run is not yet proof the thread vanished, but blocks Git."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let* ((metadata (test-assist-web-git--metadata
                      "ready" "topic/old" test-assist-web-git--head))
           (generation (make-emacsos-assist-web-git-generation
                        :metadata metadata :state 'current))
           (start-epoch 0))
      (setq-local emacsos-assist-web--thread-id "thread-1"
                  emacsos-assist-web--run-id "run-a"
                  emacsos-assist-web--pending-accepted-p t
                  emacsos-assist-web-git--metadata metadata
                  emacsos-assist-web-git--current generation)
      (emacsos-assist-web--git-http-status
       (current-buffer) "GET" "threads/thread-1/runs/run-a" 404 nil
       (emacsos-assist-web--run-http-owner
        "GET" "threads/thread-1/runs/run-a"))
      (should (eq emacsos-assist-web-git--denied 'run))
      (should (eq (emacsos-assist-web-git-generation-state generation)
                  'cached))
      (should-not emacsos-assist-web-git--metadata)
      (should (string-match-p "Run status unavailable"
                              emacsos-assist-web-git--unavailable))
      (should (equal (substring-no-properties
                     (emacsos-assist-web-git--thread-header))
                     "Run status; Refresh [?] "))
      (should-not (string-match-p "reauthorize\\|thread unavailable"
                                  (emacsos-assist-web-git--view-state
                                   generation (current-buffer))))
      (emacsos-assist-web-git-status-details)
      (should (string-match-p "does not prove the thread is gone"
                              (buffer-string)))
      (emacsos-assist-web-git-display-details-back)
      (setq start-epoch emacsos-assist-web-git--auth-epoch)
      (emacsos-assist-web-git--canonical-authorized start-epoch)
      (should-not emacsos-assist-web-git--denied)
      ;; Reauthorization alone never promotes the old generation.
      (should (eq (emacsos-assist-web-git-generation-state generation)
                  'cached)))))

(ert-deftest test-assist-web-git-retired-run-late-404-cannot-relatch ()
  "An old exact R denial header after durable retirement is not authority."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq-local emacsos-assist-web--thread-id "thread-1"
                emacsos-assist-web--run-id "run-a"
                emacsos-assist-web--pending-accepted-p t)
    (let ((owner (emacsos-assist-web--run-http-owner
                  "GET" "threads/thread-1/runs/run-a")))
      (should owner)
      (setq emacsos-assist-web--run-id nil
            emacsos-assist-web--pending-accepted-p nil)
      (emacsos-assist-web--git-http-status
       (current-buffer) "GET" "threads/thread-1/runs/run-a" 404 nil owner)
      (should-not emacsos-assist-web-git--denied)
      (should-not emacsos-assist-web-git--run-outcome-uncertain)
      (should (= emacsos-assist-web-git--auth-epoch 0)))))

(ert-deftest test-assist-web-git-pre-thread-denial-run-404-cannot-relatch ()
  "A still-resident R's pre-T403 GET cannot undo later T reauthorization."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq-local emacsos-assist-web--thread-id "thread-1"
                emacsos-assist-web--run-id "run-a"
                emacsos-assist-web--pending-accepted-p t)
    (let ((owner (emacsos-assist-web--run-http-owner
                  "GET" "threads/thread-1/runs/run-a")))
      (emacsos-assist-web-git--canonical-denied 403)
      (emacsos-assist-web-git--canonical-authorized
       emacsos-assist-web-git--auth-epoch)
      (let ((epoch emacsos-assist-web-git--auth-epoch))
        (emacsos-assist-web--git-http-status
         (current-buffer) "GET" "threads/thread-1/runs/run-a" 404 nil owner)
        (should (= emacsos-assist-web-git--auth-epoch epoch))
        (should-not emacsos-assist-web-git--denied)
        (should-not emacsos-assist-web-git--run-outcome-uncertain)))))

(ert-deftest test-assist-web-git-superseded-queue-run-404-is-ignored ()
  "An older queue GET header cannot fence the newer exact R generation."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq-local emacsos-assist-web--thread-id "thread-1")
    (let ((entry (emacsos-assist-web--entry
                  "fixture" 'accepted-unobserved "exact-key")))
      (setf (plist-get entry :run-id) "run-a"
            (plist-get entry :reobserve-in-flight) t
            (plist-get entry :reobserve-generation) 1)
      (setq emacsos-assist-web--queue (list entry))
      (let ((owner (emacsos-assist-web--run-http-owner
                    "GET" "threads/thread-1/runs/run-a")))
        (setf (plist-get entry :reobserve-generation) 2)
        (emacsos-assist-web--git-http-status
         (current-buffer) "GET" "threads/thread-1/runs/run-a" 404 nil
         owner)
        (should-not emacsos-assist-web-git--denied)
        (should-not emacsos-assist-web-git--run-outcome-uncertain)
        (should (= emacsos-assist-web-git--auth-epoch 0))
        (emacsos-assist-web--git-http-status
         (current-buffer) "GET" "threads/thread-1/runs/run-a" 404 nil
         (emacsos-assist-web--run-http-owner
          "GET" "threads/thread-1/runs/run-a"))
        (should (eq emacsos-assist-web-git--denied 'run))))))

(ert-deftest test-assist-web-git-newer-run-get-failure-keeps-old-current-ineligible ()
  "B supersedes A before A's late 404; B failure leaves a visible fence."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let* ((entry (emacsos-assist-web--entry
                   "fixture" 'accepted-unobserved "exact-key"))
           (metadata (test-assist-web-git--metadata
                      "ready" "topic/old" test-assist-web-git--head))
           (generation (make-emacsos-assist-web-git-generation
                        :metadata metadata :state 'current))
           (old-owner nil)
           newer-callback)
      (setf (plist-get entry :run-id) "run-a"
            (plist-get entry :reobserve-generation) 1)
      (setq-local emacsos-assist-web--thread-id "thread-1"
                  emacsos-assist-web-git-thread-mode t
                  emacsos-assist-web--queue (list entry)
                  emacsos-assist-web-git--metadata metadata
                  emacsos-assist-web-git--current generation)
      (setf (plist-get entry :reobserve-in-flight) t)
      (setq old-owner (emacsos-assist-web--run-http-owner
                       "GET" "threads/thread-1/runs/run-a"))
      (setf (plist-get entry :reobserve-in-flight) nil)
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload done &rest _)
                   (setq newer-callback done))))
        (emacsos-assist-web--reobserve-entry entry))
      (should newer-callback)
      (should (eq (emacsos-assist-web-git-generation-state generation)
                  'cached))
      (emacsos-assist-web--git-http-status
       (current-buffer) "GET" "threads/thread-1/runs/run-a" 404 nil old-owner)
      (should-not emacsos-assist-web-git--denied)
      (funcall newer-callback nil "offline")
      (should (emacsos-assist-web-git--run-record "thread-1" "run-a"))
      (should (string-match-p "Run status; Refresh"
                              (substring-no-properties
                               (emacsos-assist-web-git--thread-header)))))))

(ert-deftest test-assist-web-git-run-denial-starts-one-chat-owned-recheck ()
  "A Run 404 schedules one auth-only canonical thread GET."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq-local emacsos-assist-web--thread-id "thread-1")
    (let (scheduled requests)
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (_seconds _repeat callback &rest _)
                   (push callback scheduled)))
                ((symbol-function 'emacsos-assist-web--request)
                 (lambda (method path _payload callback &rest _)
                   (push (list method path callback) requests))))
        (emacsos-assist-web-git--run-access-uncertain 404 "run-1")
        (should (= (length scheduled) 1))
        (should (= emacsos-assist-web-git--auth-epoch 1))
        (funcall (car scheduled))
        (should (= (length requests) 1))
        (should (equal (cadar requests) "threads/thread-1"))
        (funcall (caddar requests)
                 (test-assist-web-git--snapshot "ready" "topic/one") nil)
        (should-not emacsos-assist-web-git--denied)
        (should emacsos-assist-web-git--run-outcome-uncertain)
        (should-not emacsos-assist-web-git--metadata)
        (funcall (car scheduled))
        (should (= (length requests) 1))))))

(ert-deftest test-assist-web-git-later-run-denial-outranks-earlier-recheck ()
  "Only a canonical GET begun after the latest distinct Run denial may clear it."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq-local emacsos-assist-web--thread-id "thread-1")
    (let (scheduled requests)
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (_seconds _repeat callback &rest _)
                   (push callback scheduled)))
                ((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload callback &rest _)
                   (push callback requests))))
        (emacsos-assist-web-git--run-access-uncertain 404 "run-1")
        (let ((older emacsos-assist-web-git--auth-epoch))
          (funcall (car scheduled))
          (emacsos-assist-web-git--run-access-uncertain 403 "run-1")
          (should (= emacsos-assist-web-git--auth-epoch (1+ older)))
          (funcall (car scheduled))
          (should (= (length requests) 2))
          (funcall (cadr requests)
                   (test-assist-web-git--snapshot "ready" "topic/one") nil)
          (should (eq emacsos-assist-web-git--denied 'run))
          (funcall (car requests)
                   (test-assist-web-git--snapshot "ready" "topic/one") nil)
          (should-not emacsos-assist-web-git--denied))))))

(ert-deftest test-assist-web-git-run-denial-cannot-weaken-thread-denial ()
  "A definitive thread 403 remains latched after a later Run 404."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq-local emacsos-assist-web--thread-id "thread-1")
    (emacsos-assist-web-git--canonical-denied 403)
    (let ((epoch emacsos-assist-web-git--auth-epoch))
      (emacsos-assist-web-git--run-access-uncertain 404 "run-1")
      (should (eq emacsos-assist-web-git--denied t))
      (should (= emacsos-assist-web-git--auth-epoch (1+ epoch)))
      (should (emacsos-assist-web-git--run-record "thread-1" "run-1"))
      (should-not emacsos-assist-web-git--run-recheck-needed))))

(ert-deftest test-assist-web-git-run-clearance-needs-exact-id-and-newer-read ()
  "B or an older A response cannot discharge A's outstanding denial."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq-local emacsos-assist-web--thread-id "thread-1")
    (cl-letf (((symbol-function 'run-at-time) (lambda (&rest _) nil)))
      (emacsos-assist-web-git--run-access-uncertain 404 "run-a"))
    (let ((epoch emacsos-assist-web-git--auth-epoch))
      (emacsos-assist-web-git--canonical-authorized epoch)
      (emacsos-assist-web-git--run-status-confirmed
       "thread-1" "run-b" epoch)
      (should (emacsos-assist-web-git--run-record "thread-1" "run-a"))
      (emacsos-assist-web-git--run-status-confirmed
       "thread-1" "run-a" (1- epoch))
      (should (emacsos-assist-web-git--run-record "thread-1" "run-a"))
      (emacsos-assist-web-git--run-status-confirmed
       "thread-1" "run-a" epoch)
      (should-not emacsos-assist-web-git--run-outcome-uncertain))))

(ert-deftest test-assist-web-git-thread-reauthorization-keeps-run-denial ()
  "A definitive thread denial and later 200 never erase exact Run A."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq-local emacsos-assist-web--thread-id "thread-1")
    (emacsos-assist-web-git--canonical-denied 403)
    (emacsos-assist-web-git--run-access-uncertain 404 "run-a")
    (let ((epoch emacsos-assist-web-git--auth-epoch))
      (should (eq emacsos-assist-web-git--denied t))
      (should (emacsos-assist-web-git--run-record "thread-1" "run-a"))
      (emacsos-assist-web-git--canonical-authorized epoch)
      (should-not emacsos-assist-web-git--denied)
      (should (emacsos-assist-web-git--run-record "thread-1" "run-a"))
      (should (string-match-p "Thread access was confirmed"
                              (let ((emacsos-assist-web-git--display-details-thread
                                     nil))
                                (save-window-excursion
                                  (emacsos-assist-web-git-status-details)
                                  (prog1 (buffer-string)
                                    (emacsos-assist-web-git-display-details-back)))))))))

(ert-deftest test-assist-web-git-durable-run-clear-survives-header-quit ()
  "A postcommit header C-g cannot abort exact Run clearance or its caller."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq-local emacsos-assist-web--thread-id "thread-1")
    (cl-letf (((symbol-function 'run-at-time) (lambda (&rest _) nil)))
      (emacsos-assist-web-git--run-access-uncertain 404 "run-a"))
    (let ((epoch emacsos-assist-web-git--auth-epoch)
          continued
          (lookup (symbol-function 'emacsos-assist-web-git--run-record)))
      (cl-letf (((symbol-function 'emacsos-assist-web-git--run-record)
                 (lambda (&rest args)
                   (should inhibit-quit)
                   (apply lookup args)))
                ((symbol-function 'emacsos-assist-web-git--update-headers)
                 (lambda () (signal 'quit nil))))
        (emacsos-assist-web-git--run-status-confirmed
         "thread-1" "run-a" epoch)
        (setq continued t))
      (should continued)
      (should-not emacsos-assist-web-git--run-outcome-uncertain))))

(ert-deftest test-assist-web-git-active-run-needs-saved-status-and-newer-busy-t ()
  "An active Run opens no Git gate until its saved state and fresh busy T GET."
  (dolist (saved '(t nil))
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (let ((entry (emacsos-assist-web--entry
                    "fixture" 'accepted-unobserved "exact-key"))
            requests)
        (setf (plist-get entry :run-id) "run-a")
        (setq-local emacsos-assist-web--thread-id "thread-1"
                    emacsos-assist-web--queue (list entry))
        (cl-letf (((symbol-function 'run-at-time) (lambda (&rest _) nil))
                  ((symbol-function 'emacsos-assist-web--request)
                   (lambda (_method path _payload done &rest _)
                     (push (cons path done) requests)))
                  ((symbol-function 'emacsos-assist-web--save-draft)
                   (lambda () saved))
                  ((symbol-function 'emacsos-assist-web--try-write-cache)
                   (lambda (&rest _) t))
                  ((symbol-function 'emacsos-assist-web--start-observation)
                   (lambda (&rest _) nil))
                  ((symbol-function 'emacsos-assist-web-git--begin) #'ignore))
          (emacsos-assist-web-git--run-access-uncertain 404 "run-a")
          (emacsos-assist-web-git--canonical-authorized
           emacsos-assist-web-git--auth-epoch)
          (emacsos-assist-web--reobserve-entry entry)
          (should (= (length requests) 1))
          (funcall (cdar requests)
                   '((id . "run-a") (thread_id . "thread-1")
                     (status . "running")) nil)
          (should emacsos-assist-web-git--run-outcome-uncertain)
          (if saved
              (progn
                (should (= (length requests) 2))
                (should (equal (caar requests) "threads/thread-1"))
                (funcall (cdar requests)
                         (test-assist-web-git--snapshot
                          "processing" "main" "topic/old") nil)
                ;; The first changed-key read predates its own barrier.
                (should (= (length requests) 3))
                (should emacsos-assist-web-git--run-outcome-uncertain)
                (funcall (cdar requests)
                         (test-assist-web-git--snapshot
                          "processing" "main" "topic/old") nil)
                (should-not emacsos-assist-web-git--run-outcome-uncertain)
                (should (equal (plist-get emacsos-assist-web-git--metadata
                                               :status)
                               "processing")))
            (should (= (length requests) 1))
            (should emacsos-assist-web-git--run-outcome-uncertain)))))))

(ert-deftest test-assist-web-git-active-run-clearance-preserves-manual-gate ()
  "A fresh busy T clears Run denial, not restored-Run manual recovery."
  (dolist (manual '(nil t))
    (save-window-excursion
      (with-temp-buffer
        (emacsos-assist-web-mode)
        (setq-local emacsos-assist-web--thread-id "thread-1"
                    emacsos-assist-web--run-id "run-a"
                    emacsos-assist-web--pending-accepted-p t
                    emacsos-assist-web-git-thread-mode t
                    emacsos-assist-web--manual-recovery-required manual)
        (let ((window (selected-window))
              (original-intent (window-parameter (selected-window)
                                                 'assist-web-git-intent))
              requests command-read)
          (unwind-protect
          (cl-letf (((symbol-function 'run-at-time) (lambda (&rest _) nil))
                    ((symbol-function 'emacsos-assist-web--request)
                     (lambda (_method path _payload callback &rest _)
                       (push (cons path callback) requests)))
                    ((symbol-function 'emacsos-assist-web--try-write-cache)
                     (lambda (&rest _) t))
                    ((symbol-function 'emacsos-assist-web-git--begin) #'ignore))
            (emacsos-assist-web-git--run-access-uncertain 404 "run-a")
            (emacsos-assist-web-git--canonical-authorized
             emacsos-assist-web-git--auth-epoch)
            (emacsos-assist-web-git--confirm-active-run
             "thread-1" "run-a" emacsos-assist-web-git--auth-epoch)
            (should (= (length requests) 1))
            (funcall (cdar requests)
                     (test-assist-web-git--snapshot
                      "processing" "main" "topic/old") nil)
            (should (= (length requests) 2))
            (funcall (cdar requests)
                     (test-assist-web-git--snapshot
                      "processing" "main" "topic/old") nil)
            (should-not emacsos-assist-web-git--run-outcome-uncertain)
            (should (eq emacsos-assist-web--manual-recovery-required manual))
            (cl-letf (((symbol-function 'emacsos-assist-web-git--read-metadata)
                       (lambda (&rest _) (setq command-read t))))
              (if manual
                  (should-error (emacsos-assist-web-git--command 'files)
                                :type 'user-error)
                (emacsos-assist-web-git--command 'files)))
            (should (eq command-read (not manual))))
            (set-window-parameter window 'assist-web-git-intent
                                  original-intent)))))))

(ert-deftest test-assist-web-git-active-run-key-change-cache-failure-needs-r3 ()
  "A changed busy key downgrades old Git before cache and needs a later T read."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let ((entry (emacsos-assist-web--entry
                  "fixture" 'accepted-unobserved "exact-key"))
          (requests nil)
          (cache-ok nil))
      (setf (plist-get entry :run-id) "run-a"
            (plist-get entry :reobserve-generation) 1)
      (setq-local emacsos-assist-web--thread-id "thread-1"
                  emacsos-assist-web--queue (list entry))
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload done &rest _)
                   (push done requests)))
                ((symbol-function 'emacsos-assist-web--try-write-cache)
                 (lambda (&rest _) cache-ok))
                ((symbol-function 'emacsos-assist-web-git--begin) #'ignore))
        (emacsos-assist-web-git--run-access-uncertain 404 "run-a")
        (emacsos-assist-web-git--canonical-authorized
         emacsos-assist-web-git--auth-epoch)
        (emacsos-assist-web-git--confirm-active-run
         "thread-1" "run-a" emacsos-assist-web-git--auth-epoch entry)
        (should (= (length requests) 1))
        (funcall (car requests)
                 (test-assist-web-git--snapshot
                  "processing" "main" "topic/new") nil)
        (should (= (length requests) 1))
        (should (eq (plist-get emacsos-assist-web-git--busy-check :stage) 'r3))
        (should emacsos-assist-web-git--run-outcome-uncertain)
        (setq cache-ok t)
        (emacsos-assist-web-git--retry-busy-check)
        (should (= (length requests) 2))
        (funcall (car requests)
                 (test-assist-web-git--snapshot
                  "processing" "main" "topic/new") nil)
        (should-not emacsos-assist-web-git--run-outcome-uncertain)))))

(ert-deftest test-assist-web-git-active-run-t-failure-releases-pending-cause ()
  "A failed post-save T read cannot strand a pending diagnostic action."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let ((entry (emacsos-assist-web--entry
                  "fixture" 'accepted-unobserved "exact-key"))
          canonical)
      (setf (plist-get entry :run-id) "run-a"
            (plist-get entry :reobserve-generation) 1)
      (setq-local emacsos-assist-web--thread-id "thread-1"
                  emacsos-assist-web--queue (list entry)
                  emacsos-assist-web-git--pending
                  (list :key '("old") :epoch 0 :request nil
                        :requires-durable t :intents nil))
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload done &rest _)
                   (setq canonical done))))
        (emacsos-assist-web-git--run-access-uncertain 404 "run-a")
        (emacsos-assist-web-git--canonical-authorized
         emacsos-assist-web-git--auth-epoch)
        (setq emacsos-assist-web-git--pending
              (list :key '("old") :epoch emacsos-assist-web-git--epoch
                    :request nil :requires-durable t :intents nil))
        (emacsos-assist-web-git--confirm-active-run
         "thread-1" "run-a" emacsos-assist-web-git--auth-epoch entry)
        (should canonical)
        (should (plist-get emacsos-assist-web-git--pending :request))
        (funcall canonical nil '(:kind timeout :text "timed out"))
        (should-not emacsos-assist-web-git--pending)
        (should emacsos-assist-web-git--busy-check)
        (should emacsos-assist-web-git--run-outcome-uncertain)))))

(ert-deftest test-assist-web-git-active-run-busy-t-owner-turnover-is-inert ()
  "A terminalized queue owner cannot accept its older active busy-T response."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let ((entry (emacsos-assist-web--entry
                  "fixture" 'accepted-unobserved "exact-key"))
          requests noted)
      (setf (plist-get entry :run-id) "run-a"
            (plist-get entry :reobserve-generation) 1)
      (setq-local emacsos-assist-web--thread-id "thread-1"
                  emacsos-assist-web--queue (list entry))
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload done &rest _)
                   (push done requests)))
                ((symbol-function 'emacsos-assist-web--git-note-safely)
                 (lambda (&rest _) (setq noted t))))
        (emacsos-assist-web-git--run-access-uncertain 404 "run-a")
        (emacsos-assist-web-git--canonical-authorized
         emacsos-assist-web-git--auth-epoch)
        (emacsos-assist-web-git--confirm-active-run
         "thread-1" "run-a" emacsos-assist-web-git--auth-epoch entry)
        (should (= (length requests) 1))
        (should (emacsos-assist-web-git--retry-busy-check))
        (should (= (length requests) 1))
        (setf (plist-get entry :state) 'terminal-unreconciled)
        (funcall (car requests)
                 (test-assist-web-git--snapshot
                  "processing" "main" "topic/old") nil)
        (should-not noted)
        (should emacsos-assist-web-git--run-outcome-uncertain)
        (should-not emacsos-assist-web--snapshot)))))

(ert-deftest test-assist-web-git-active-run-r3-failure-retries-t-only ()
  "A failed post-barrier R3 retries one T read without repeating exact Run."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let ((entry (emacsos-assist-web--entry
                  "fixture" 'accepted-unobserved "exact-key"))
          requests)
      (setf (plist-get entry :run-id) "run-a"
            (plist-get entry :reobserve-generation) 1)
      (setq-local emacsos-assist-web--thread-id "thread-1"
                  emacsos-assist-web--queue (list entry))
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method path _payload done &rest _)
                   (push (cons path done) requests)))
                ((symbol-function 'emacsos-assist-web--try-write-cache)
                 (lambda (&rest _) t))
                ((symbol-function 'emacsos-assist-web-git--begin) #'ignore))
        (emacsos-assist-web-git--run-access-uncertain 404 "run-a")
        (emacsos-assist-web-git--canonical-authorized
         emacsos-assist-web-git--auth-epoch)
        (emacsos-assist-web-git--confirm-active-run
         "thread-1" "run-a" emacsos-assist-web-git--auth-epoch entry)
        (funcall (cdar requests)
                 (test-assist-web-git--snapshot
                  "processing" "main" "topic/new") nil)
        (should (= (length requests) 2))
        (funcall (cdar requests) nil '(:kind timeout :text "timed out"))
        (should emacsos-assist-web-git--run-outcome-uncertain)
        (should-not emacsos-assist-web--snapshot)
        (emacsos-assist-web-git--retry-busy-check)
        (should (= (length requests) 3))
        (should (seq-every-p (lambda (item)
                               (equal (car item) "threads/thread-1"))
                             requests))
        (funcall (cdar requests)
                 (test-assist-web-git--snapshot
                  "processing" "main" "topic/new") nil)
        (should-not emacsos-assist-web-git--run-outcome-uncertain)))))

(ert-deftest test-assist-web-git-active-run-r3-third-key-needs-newer-read ()
  "R3 cannot certify a third key first discovered by that same R3 read."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let ((entry (emacsos-assist-web--entry
                  "fixture" 'accepted-unobserved "exact-key"))
          requests)
      (setf (plist-get entry :run-id) "run-a"
            (plist-get entry :reobserve-generation) 1)
      (setq-local emacsos-assist-web--thread-id "thread-1"
                  emacsos-assist-web--queue (list entry))
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload done &rest _)
                   (push done requests)))
                ((symbol-function 'emacsos-assist-web--try-write-cache)
                 (lambda (&rest _) t))
                ((symbol-function 'emacsos-assist-web-git--begin) #'ignore))
        (emacsos-assist-web-git--run-access-uncertain 404 "run-a")
        (emacsos-assist-web-git--canonical-authorized
         emacsos-assist-web-git--auth-epoch)
        (emacsos-assist-web-git--confirm-active-run
         "thread-1" "run-a" emacsos-assist-web-git--auth-epoch entry)
        (funcall (car requests)
                 (test-assist-web-git--snapshot
                  "processing" "main" "topic/two") nil)
        (should (= (length requests) 2))
        (funcall (car requests)
                 (test-assist-web-git--snapshot
                  "processing" "main" "topic/three") nil)
        (should (= (length requests) 2))
        (should emacsos-assist-web-git--run-outcome-uncertain)
        (should-not emacsos-assist-web--snapshot)
        (emacsos-assist-web-git--retry-busy-check)
        (should (= (length requests) 3))
        (funcall (car requests)
                 (test-assist-web-git--snapshot
                  "processing" "main" "topic/three") nil)
        (should-not emacsos-assist-web-git--run-outcome-uncertain)))))

(ert-deftest test-assist-web-git-active-run-postcache-git-quit-invalidates ()
  "A postcommit Git C-g leaves the verified Run retired but Git noncurrent."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let ((entry (emacsos-assist-web--entry
                  "fixture" 'accepted-unobserved "exact-key"))
          requests (quit-once t))
      (setf (plist-get entry :run-id) "run-a"
            (plist-get entry :reobserve-generation) 1)
      (setq-local emacsos-assist-web--thread-id "thread-1"
                  emacsos-assist-web--queue (list entry)
                  emacsos-assist-web-git--current
                  (make-emacsos-assist-web-git-generation
                   :id "old" :state 'current))
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload done &rest _)
                   (push done requests)))
                ((symbol-function 'emacsos-assist-web--try-write-cache)
                 (lambda (&rest _) t))
                ((symbol-function 'emacsos-assist-web-git--canonical-accepted)
                 (lambda (&rest _)
                   (when quit-once
                     (setq quit-once nil)
                     (signal 'quit nil)))))
        (emacsos-assist-web-git--run-access-uncertain 404 "run-a")
        (emacsos-assist-web-git--canonical-authorized
         emacsos-assist-web-git--auth-epoch)
        (emacsos-assist-web-git--confirm-active-run
         "thread-1" "run-a" emacsos-assist-web-git--auth-epoch entry)
        (funcall (car requests)
                 (test-assist-web-git--snapshot
                  "processing" "main" "topic/old") nil)
        (should (= (length requests) 2))
        (funcall (car requests)
                 (test-assist-web-git--snapshot
                  "processing" "main" "topic/old") nil)
        (should-not emacsos-assist-web-git--run-outcome-uncertain)
        (should-not emacsos-assist-web-git--busy-check)
        (should-not emacsos-assist-web-git--metadata)
        (should (eq (emacsos-assist-web-git-generation-state
                     emacsos-assist-web-git--current) 'cached))))))

(ert-deftest test-assist-web-git-active-run-r3-routes-waiting-window ()
  "Durable R3 clears the exact Run gate before routing a live file intent."
  (save-window-excursion
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (let* ((thread (current-buffer))
             (window (selected-window))
             (entry (emacsos-assist-web--entry
                     "fixture" 'accepted-unobserved "exact-key"))
             (intent (list :action 'files :buffer thread :window window :serial 1))
             requests routed)
        (set-window-buffer window thread)
        (set-window-parameter window 'assist-web-git-intent 1)
        (setf (plist-get entry :run-id) "run-a"
              (plist-get entry :reobserve-generation) 1)
        (setq-local emacsos-assist-web--thread-id "thread-1"
                    emacsos-assist-web--queue (list entry))
        (unwind-protect
            (cl-letf (((symbol-function 'run-at-time) (lambda (&rest _) nil))
                      ((symbol-function 'emacsos-assist-web--request)
                       (lambda (_method _path _payload done &rest _)
                         (push done requests)))
                      ((symbol-function 'emacsos-assist-web--try-write-cache)
                       (lambda (&rest _) t))
                      ((symbol-function 'emacsos-assist-web-git--enqueue)
                       (lambda (_metadata offered) (push offered routed))))
              (emacsos-assist-web-git--run-access-uncertain 404 "run-a")
              (emacsos-assist-web-git--canonical-authorized
               emacsos-assist-web-git--auth-epoch)
              (setq emacsos-assist-web-git--pending
                    (list :key '("old") :epoch emacsos-assist-web-git--epoch
                          :request nil :requires-durable t
                          :intents (list intent)))
              (emacsos-assist-web-git--confirm-active-run
               "thread-1" "run-a" emacsos-assist-web-git--auth-epoch entry)
              (funcall (car requests)
                       (test-assist-web-git--snapshot
                        "processing" "main" "topic/new") nil)
              (should-not routed)
              (funcall (car requests)
                       (test-assist-web-git--snapshot
                        "processing" "main" "topic/new") nil)
              (should (equal routed (list intent)))
              (should-not emacsos-assist-web-git--run-outcome-uncertain))
          (set-window-parameter window 'assist-web-git-intent nil))))))

(ert-deftest test-assist-web-git-old-run-get-cannot-clear-newer-denial ()
  "A's old successful GET is inert after a newer A denial and T reauth."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let ((entry (emacsos-assist-web--entry
                  "fixture" 'accepted-unobserved "exact-key"))
          old-run canonical)
      (setf (plist-get entry :run-id) "run-a")
      (setq-local emacsos-assist-web--thread-id "thread-1"
                  emacsos-assist-web--queue (list entry))
      (cl-letf (((symbol-function 'run-at-time) (lambda (&rest _) nil))
                ((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method path _payload done &rest _)
                   (if (string-match-p "/runs/" path)
                       (setq old-run done)
                     (setq canonical done)))))
        (emacsos-assist-web--reobserve-entry entry)
        (emacsos-assist-web-git--run-access-uncertain 404 "run-a")
        (emacsos-assist-web-git--canonical-authorized
         emacsos-assist-web-git--auth-epoch)
        (funcall old-run
                 '((id . "run-a") (thread_id . "thread-1")
                   (status . "running")) nil)
        (should-not canonical)
        (should (emacsos-assist-web-git--run-record "thread-1" "run-a"))
        (should (eq (emacsos-assist-web--entry-state entry)
                    'accepted-unobserved))))))

(ert-deftest test-assist-web-git-thread-denial-supersedes-old-run-get ()
  "A pre-403 exact A response stays inert even after a newer T 200."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let ((entry (emacsos-assist-web--entry
                  "fixture" 'accepted-unobserved "exact-key"))
          old-run newer-run)
      (setf (plist-get entry :run-id) "run-a")
      (setq-local emacsos-assist-web--thread-id "thread-1"
                  emacsos-assist-web--queue (list entry))
      (cl-letf (((symbol-function 'run-at-time) (lambda (&rest _) nil))
                ((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method path _payload done &rest _)
                   (when (string-match-p "/runs/" path)
                     (if old-run (setq newer-run done)
                       (setq old-run done))))))
        (emacsos-assist-web-git--run-access-uncertain 404 "run-a")
        (emacsos-assist-web-git--canonical-authorized
         emacsos-assist-web-git--auth-epoch)
        (emacsos-assist-web--reobserve-entry entry)
        (emacsos-assist-web-git--canonical-denied 403)
        (emacsos-assist-web-git--canonical-authorized
         emacsos-assist-web-git--auth-epoch)
        (funcall old-run
                 '((id . "run-a") (thread_id . "thread-1")
                   (status . "success")) nil)
        (should (emacsos-assist-web-git--run-record "thread-1" "run-a"))
        (should (eq (emacsos-assist-web--entry-state entry)
                    'accepted-unobserved))
        (emacsos-assist-web--reobserve-entry entry)
        (should newer-run)
        (should-not (emacsos-assist-web-git--run-read-superseded-p
                     "thread-1" "run-a" emacsos-assist-web-git--auth-epoch))))))

(ert-deftest test-assist-web-git-active-run-ready-t-cannot-clear-gate ()
  "An active exact Run contradicted by ready T stays unavailable."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let ((entry (emacsos-assist-web--entry
                  "fixture" 'accepted-unobserved "exact-key"))
          requests)
      (setf (plist-get entry :run-id) "run-a")
      (setq-local emacsos-assist-web--thread-id "thread-1"
                  emacsos-assist-web--queue (list entry))
      (cl-letf (((symbol-function 'run-at-time) (lambda (&rest _) nil))
                ((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method path _payload done &rest _)
                   (push (cons path done) requests)))
                ((symbol-function 'emacsos-assist-web--save-draft)
                 (lambda () t))
                ((symbol-function 'emacsos-assist-web--start-observation)
                 (lambda (&rest _) nil)))
        (emacsos-assist-web-git--run-access-uncertain 404 "run-a")
        (emacsos-assist-web-git--canonical-authorized
         emacsos-assist-web-git--auth-epoch)
        (emacsos-assist-web--reobserve-entry entry)
        (funcall (cdar requests)
                 '((id . "run-a") (thread_id . "thread-1")
                   (status . "running")) nil)
        (should (= (length requests) 2))
        (funcall (cdar requests)
                 (test-assist-web-git--snapshot "ready" "topic/one") nil)
        (should (emacsos-assist-web-git--run-record "thread-1" "run-a"))
        (should-not emacsos-assist-web-git--metadata)))))

(ert-deftest test-assist-web-git-active-run-t-read-cannot-replace-newer-chat ()
  "A post-save busy T result cannot replace a later accepted ready snapshot."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let ((entry (emacsos-assist-web--entry
                  "fixture" 'accepted-unobserved "exact-key"))
          requests)
      (setf (plist-get entry :run-id) "run-a"
            (plist-get entry :reobserve-generation) 1)
      (setq-local emacsos-assist-web--thread-id "thread-1"
                  emacsos-assist-web--queue (list entry))
      (cl-letf (((symbol-function 'run-at-time) (lambda (&rest _) nil))
                ((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method path _payload callback &rest _)
                   (push (cons path callback) requests)))
                ((symbol-function 'emacsos-assist-web--try-write-cache)
                 (lambda (&rest _) t)))
        (emacsos-assist-web-git--run-access-uncertain 404 "run-a")
        (emacsos-assist-web-git--canonical-authorized
         emacsos-assist-web-git--auth-epoch)
        (emacsos-assist-web-git--confirm-active-run
         "thread-1" "run-a" emacsos-assist-web-git--auth-epoch entry)
        (emacsos-assist-web-git--note
         (emacsos-assist-web-git--metadata-from-snapshot
          (test-assist-web-git--snapshot "ready" "topic/new")))
        (funcall (cdar requests)
                 (test-assist-web-git--snapshot
                  "processing" "main" "topic/old") nil)
        (should (equal (plist-get emacsos-assist-web-git--metadata :branch)
                       "topic/new"))
        (should (emacsos-assist-web-git--run-record "thread-1" "run-a"))))))

(ert-deftest test-assist-web-git-manual-stop-outranks-old-run-warning ()
  "After thread reauth, stopped manual recovery shows its actionable reason."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq-local emacsos-assist-web--thread-id "thread-1"
                emacsos-assist-web--manual-recovery-required t
                emacsos-assist-web--manual-recovery-reason 'approval
                emacsos-assist-web-git--run-outcome-uncertain
                (list (list :tid "thread-1" :run-id "run-a" :epoch 1)))
    (should (string-match-p "Approval pending; Refresh"
                            (substring-no-properties
                             (emacsos-assist-web-git--thread-header))))))

(ert-deftest test-assist-web-git-manual-sse-terminal-active-stops-with-details ()
  "A recovered Run's terminal SSE followed by active GET never loops SSE."
  (dolist (status '("running" "awaiting_approval"))
    (save-window-excursion
      (with-temp-buffer
        (emacsos-assist-web-mode)
        (emacsos-assist-web--write-prompt)
        (let ((entry (emacsos-assist-web--entry
                      "fixture" 'observing "exact-key"))
              exact-run)
          (setf (plist-get entry :run-id) "run-a")
          (setq-local emacsos-assist-web--thread-id "thread-1"
                      emacsos-assist-web--queue (list entry)
                      emacsos-assist-web--stream-entry entry
                      emacsos-assist-web--manual-recovery-required t
                      emacsos-assist-web--manual-recovery-active t)
          (cl-letf (((symbol-function 'emacsos-assist-web--save-draft)
                     (lambda () t))
                    ((symbol-function 'emacsos-assist-web--request)
                     (lambda (_method path _payload done &rest _)
                       (should (string-match-p "/runs/" path))
                       (setq exact-run done)))
                    ((symbol-function 'emacsos-assist-web--start-observation)
                     (lambda (&rest _) (ert-fail "SSE reattached"))))
            (emacsos-assist-web--stream-finish (current-buffer))
            (should exact-run)
            (funcall exact-run
                     `((id . "run-a") (thread_id . "thread-1")
                       (status . ,status)) nil)
            (should-not emacsos-assist-web--manual-recovery-active)
            (should emacsos-assist-web--manual-recovery-required)
            (should (eq (emacsos-assist-web--entry-state entry)
                        'accepted-unobserved))
            (should (plist-get entry :requires-reobserve))
            (should (equal (substring-no-properties
                            (emacsos-assist-web-git--thread-header))
                           (if (equal status "awaiting_approval")
                               "Approval pending; Refresh [?] "
                             "Run changed; Refresh [?] ")))
            (emacsos-assist-web-git-details)
            (should (string-match-p
                     (if (equal status "awaiting_approval")
                         "Approve it first" "will not reattach")
                     (buffer-string)))
            (emacsos-assist-web-git-display-details-back)
            (when (equal status "awaiting_approval")
              (emacsos-assist-web-refresh-thread)
              (funcall exact-run
                       '((id . "run-a") (thread_id . "thread-1")
                         (status . "awaiting_approval")) nil)
              (should-not emacsos-assist-web--manual-recovery-active)
              (should (eq emacsos-assist-web--manual-recovery-reason
                          'approval)))))))))

(ert-deftest test-assist-web-git-ordinary-sse-terminal-active-stops-noncurrent ()
  "An ordinary ended SSE with active Run stops and downgrades old current."
  (dolist (status '("running" "awaiting_approval"))
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (let ((entry (emacsos-assist-web--entry
                    "fixture" 'observing "exact-key"))
            exact-run)
        (setf (plist-get entry :run-id) "run-a"
              (plist-get entry :reobserve-generation) 1)
        (setq-local emacsos-assist-web--thread-id "thread-1"
                    emacsos-assist-web--queue (list entry)
                    emacsos-assist-web--stream-entry entry
                    emacsos-assist-web-git--metadata
                    (emacsos-assist-web-git--metadata-from-snapshot
                     (test-assist-web-git--snapshot
                      "ready" "topic/old" "topic/old"))
                    emacsos-assist-web-git--current
                    (make-emacsos-assist-web-git-generation
                     :id "old" :state 'current))
        (cl-letf (((symbol-function 'emacsos-assist-web--save-draft)
                   (lambda () t))
                  ((symbol-function 'emacsos-assist-web--request)
                   (lambda (_method path _payload done &rest _)
                     (should (string-match-p "/runs/" path))
                     (setq exact-run done)))
                  ((symbol-function 'emacsos-assist-web--start-observation)
                   (lambda (&rest _) (ert-fail "SSE reattached"))))
          (emacsos-assist-web--stream-finish (current-buffer))
          (should exact-run)
          (funcall exact-run
                   `((id . "run-a") (thread_id . "thread-1")
                     (status . ,status)) nil)
          (should (eq (emacsos-assist-web--entry-state entry)
                      'accepted-unobserved))
          (should (plist-get entry :requires-reobserve))
          (should emacsos-assist-web-git--stopped-reobserve)
          (should (eq (emacsos-assist-web-git-generation-state
                       emacsos-assist-web-git--current) 'cached))
          (should (string-match-p
                   "Run changed; Refresh"
                   (substring-no-properties
                    (emacsos-assist-web-git--thread-header)))))))))

(ert-deftest test-assist-web-git-ordinary-sse-close-active-stops-no-reattach ()
  "A disconnected observer and contradictory Run need an explicit later pass."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (emacsos-assist-web--write-prompt)
    (let ((entry (emacsos-assist-web--entry
                  "fixture" 'observing "exact-key"))
          exact-run)
      (setf (plist-get entry :run-id) "run-a"
            (plist-get entry :epoch) 1
            (plist-get entry :reobserve-generation) 1)
      (setq-local emacsos-assist-web--thread-id "thread-1"
                  emacsos-assist-web--queue (list entry)
                  emacsos-assist-web--stream-entry entry)
      (cl-letf (((symbol-function 'emacsos-assist-web--save-draft)
                 (lambda () t))
                ((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method path _payload done &rest _)
                   (should (string-match-p "/runs/" path))
                   (setq exact-run done)))
                ((symbol-function 'emacsos-assist-web--start-observation)
                 (lambda (&rest _) (ert-fail "SSE reattached"))))
        (emacsos-assist-web--entry-observation-interrupted
         entry 1 "observation disconnected")
        (should emacsos-assist-web-git--stopped-reobserve)
        (should (equal emacsos-assist-web--post-sse-run-id "run-a"))
        (emacsos-assist-web-refresh-thread)
        (should exact-run)
        (funcall exact-run
                 '((id . "run-a") (thread_id . "thread-1")
                   (status . "running")) nil)
        (should (plist-get entry :requires-reobserve))
        (should emacsos-assist-web-git--stopped-reobserve)
        (should-not emacsos-assist-web--stream-entry)))))

(ert-deftest test-assist-web-git-stopped-run-needs-new-r-and-canonical-r3 ()
  "Only a later exact Run and post-conflict canonical T clear a stopped marker."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let ((entry (emacsos-assist-web--entry
                  "fixture" 'accepted-unobserved "exact-key"))
          exact-run canonical)
      (setf (plist-get entry :run-id) "run-a"
            (plist-get entry :reobserve-generation) 1)
      (setq-local emacsos-assist-web--thread-id "thread-1"
                  emacsos-assist-web--queue (list entry)
                  emacsos-assist-web-git--metadata
                  (emacsos-assist-web-git--metadata-from-snapshot
                   (test-assist-web-git--snapshot
                    "ready" "topic/old" "topic/old")))
      (cl-letf (((symbol-function 'emacsos-assist-web--save-draft)
                 (lambda () t))
                ((symbol-function 'emacsos-assist-web--try-write-cache)
                 (lambda (&rest _) t))
                ((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method path _payload done &rest _)
                   (if (string-match-p "/runs/" path)
                       (setq exact-run done)
                     (push done canonical))))
                ((symbol-function 'emacsos-assist-web--start-observation)
                 #'ignore)
                ((symbol-function 'emacsos-assist-web-git--begin)
                 #'ignore))
        (emacsos-assist-web-git--stop-reobserve entry)
        (emacsos-assist-web--reobserve-entry entry)
        (should exact-run)
        (funcall exact-run
                 '((id . "run-a") (thread_id . "thread-1")
                   (status . "running")) nil)
        (should (= (length canonical) 1))
        (should emacsos-assist-web-git--stopped-reobserve)
        (funcall (car canonical)
                 (test-assist-web-git--snapshot
                  "processing" "main" "topic/old") nil)
        (should (= (length canonical) 2))
        (should emacsos-assist-web-git--stopped-reobserve)
        (funcall (car canonical)
                 (test-assist-web-git--snapshot
                  "processing" "main" "topic/old") nil)
        (should-not emacsos-assist-web-git--stopped-reobserve)))))

(ert-deftest test-assist-web-git-run-denial-fences-same-thread-destination ()
  "A source exact Run denial makes another live T buffer's Git noncurrent."
  (with-temp-buffer
    (let ((source (current-buffer)))
      (emacsos-assist-web-mode)
      (setq-local emacsos-assist-web--thread-id "thread-1"
                  emacsos-assist-web--run-id "run-a"
                  emacsos-assist-web--pending-accepted-p t)
      (with-temp-buffer
        (emacsos-assist-web-mode)
        (setq-local emacsos-assist-web--thread-id "thread-1"
                    emacsos-assist-web-git-thread-mode t
                    emacsos-assist-web-git--current
                    (make-emacsos-assist-web-git-generation
                     :id "old" :state 'current))
        (let ((destination (current-buffer)))
          (cl-letf (((symbol-function 'run-at-time) (lambda (&rest _) nil)))
            (with-current-buffer source
              (emacsos-assist-web-git--run-access-uncertain 404 "run-a"))
            (with-current-buffer destination
              (should (emacsos-assist-web-git--run-record
                       "thread-1" "run-a"))
              (should (eq (emacsos-assist-web-git-generation-state
                           emacsos-assist-web-git--current) 'cached))
              (let ((epoch emacsos-assist-web-git--auth-epoch))
                (emacsos-assist-web-git--canonical-authorized epoch)
                (emacsos-assist-web-git--run-status-confirmed
                 "thread-1" "run-a" epoch))
              (should (emacsos-assist-web-git--run-record
                       "thread-1" "run-a"))
              (should-error (emacsos-assist-web-git--command 'files)
                            :type 'user-error))
            (with-current-buffer source
              (let ((epoch emacsos-assist-web-git--auth-epoch))
                (emacsos-assist-web-git--canonical-authorized epoch)
                (emacsos-assist-web-git--run-status-confirmed
                 "thread-1" "run-a" epoch)))
            (with-current-buffer destination
              (should-not (emacsos-assist-web-git--run-record
                           "thread-1" "run-a"))
              (should (eq (emacsos-assist-web-git-generation-state
                           emacsos-assist-web-git--current) 'cached)))))))))

(ert-deftest test-assist-web-git-thread-denial-fences-same-thread-buffers ()
  "A T-level 403 invalidates all live T buffers until a newer T acceptance."
  (with-temp-buffer
    (let ((source (current-buffer)))
      (emacsos-assist-web-mode)
      (setq-local emacsos-assist-web--thread-id "thread-1")
      (with-temp-buffer
        (emacsos-assist-web-mode)
        (setq-local emacsos-assist-web--thread-id "thread-1"
                    emacsos-assist-web-git-thread-mode t
                    emacsos-assist-web-git--current
                    (make-emacsos-assist-web-git-generation
                     :id "old" :state 'current))
        (let ((destination (current-buffer))
              old-start)
          (with-current-buffer source
            (setq old-start emacsos-assist-web-git--auth-epoch)
            (emacsos-assist-web-git--canonical-denied 403)
            (emacsos-assist-web-git--canonical-authorized old-start)
            (should (eq emacsos-assist-web-git--denied t)))
          (with-current-buffer destination
            (should (eq emacsos-assist-web-git--denied t))
            (should (eq (emacsos-assist-web-git-generation-state
                         emacsos-assist-web-git--current) 'cached))
            (should-error (emacsos-assist-web-git--command 'files)
                          :type 'user-error))
          (with-current-buffer source
            (emacsos-assist-web-git--canonical-authorized
             emacsos-assist-web-git--auth-epoch))
          (with-current-buffer destination
            (should-not emacsos-assist-web-git--denied)
            (should (eq (emacsos-assist-web-git-generation-state
                         emacsos-assist-web-git--current) 'cached))))))))

(ert-deftest test-assist-web-git-run-denial-survives-source-buffer-kill ()
  "A retained T buffer keeps the exact gate when its source buffer closes."
  (let ((emacsos-assist-web-cache-directory
         (make-temp-file "assist-web-run-gate-" t))
        (source (generate-new-buffer " *run-source*"))
        (destination (generate-new-buffer " *run-destination*"))
        (reopened (generate-new-buffer " *run-reopened*")))
    (unwind-protect
        (cl-letf (((symbol-function 'run-at-time) (lambda (&rest _) nil)))
          (with-current-buffer source
            (emacsos-assist-web-mode)
            (setq-local emacsos-assist-web--thread-id "thread-1"))
          (with-current-buffer destination
            (emacsos-assist-web-mode)
            (setq-local emacsos-assist-web--thread-id "thread-1"
                        emacsos-assist-web-git-thread-mode t))
          ;; The destination must already be live when the denial arrives.
          (with-current-buffer source
            (emacsos-assist-web-git--run-access-uncertain 404 "run-a"))
          (kill-buffer source)
          (with-current-buffer reopened
            (emacsos-assist-web-mode)
            (setq-local emacsos-assist-web--thread-id "thread-1"
                        emacsos-assist-web--run-id "run-a"
                        emacsos-assist-web--pending-accepted-p t
                        emacsos-assist-web-git-thread-mode t)
            (should (emacsos-assist-web-git--run-gated-p))
            (should-error (emacsos-assist-web-git--command 'files)
                          :type 'user-error)
            (let ((owner (emacsos-assist-web--run-http-owner
                          "GET" "threads/thread-1/runs/run-a")))
              (should (eq (plist-get owner :kind) 'legacy))
              (should (eq (plist-get
                           (emacsos-assist-web-git--run-record
                            "thread-1" "run-a") :origin)
                          reopened))
              ;; Only a later exact committed Run/canonical proof may call this.
              (emacsos-assist-web-git--canonical-authorized
               emacsos-assist-web-git--auth-epoch)
              (emacsos-assist-web-git--run-status-confirmed
               "thread-1" "run-a" (plist-get owner :auth-start))))
          (with-current-buffer destination
            (should-not (emacsos-assist-web-git--run-record
                         "thread-1" "run-a"))))
      (dolist (buffer (list source destination reopened))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest test-assist-web-git-orphaned-queue-run-claim-precedes-read-epoch ()
  "A restored exact Run GET starts after claiming its dead owner's gate."
  (let ((emacsos-assist-web-cache-directory
         (make-temp-file "assist-web-orphan-" t))
        (destination (generate-new-buffer " *orphan-destination*"))
        (reopened (generate-new-buffer " *orphan-source*"))
        (dead (generate-new-buffer " *orphan-dead*")))
    (unwind-protect
        (progn
          (kill-buffer dead)
          (with-current-buffer destination
            (emacsos-assist-web-mode)
            (setq-local emacsos-assist-web--thread-id "thread-1"
                        emacsos-assist-web-git--run-outcome-uncertain
                        (list (list :tid "thread-1" :run-id "run-a"
                                    :epoch 1 :origin dead))))
          (with-current-buffer reopened
            (emacsos-assist-web-mode)
            (let ((entry (emacsos-assist-web--entry
                          "fixture" 'accepted-unobserved "exact-key"))
                  run-get)
              (setf (plist-get entry :run-id) "run-a")
              (setq-local emacsos-assist-web--thread-id "thread-1"
                          emacsos-assist-web--queue (list entry))
              (cl-letf (((symbol-function 'emacsos-assist-web--request)
                         (lambda (_method path _payload done &rest _)
                           (when (string-match-p "/runs/" path)
                             (setq run-get done))))
                        ((symbol-function 'emacsos-assist-web--save-draft)
                         (lambda () t))
                        ((symbol-function 'emacsos-assist-web--start-observation)
                         #'ignore))
                (emacsos-assist-web--reobserve-entry entry)
                (should run-get)
                (should (eq (plist-get
                             (emacsos-assist-web-git--run-record
                              "thread-1" "run-a") :origin)
                            reopened))
                (funcall run-get
                         '((id . "run-a") (thread_id . "thread-1")
                           (status . "running")) nil)
                (should-not (plist-get entry :requires-reobserve))
                (should (equal (plist-get entry :run-read-start-epoch)
                               emacsos-assist-web-git--auth-epoch))))))
      (dolist (buffer (list destination reopened dead))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest test-assist-web-git-terminal-run-gate-waits-for-r2-commit ()
  "A terminal A GET leaves A gated through cache and queue retirement."
  (dolist (retirement-fails '(nil t new-denial))
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (let ((entry (emacsos-assist-web--entry
                    "fixture" 'accepted-unobserved "exact-key"))
            exact-run r2)
        (setf (plist-get entry :run-id) "run-a")
        (setq-local emacsos-assist-web--thread-id "thread-1"
                    emacsos-assist-web--queue (list entry))
        (cl-letf (((symbol-function 'run-at-time) (lambda (&rest _) nil))
                  ((symbol-function 'emacsos-assist-web--request)
                   (lambda (_method path _payload done &rest _)
                     (if (string-match-p "/runs/" path)
                         (setq exact-run done)
                       (setq r2 done))))
                  ((symbol-function 'emacsos-assist-web--save-draft)
                   (lambda () (not (and (eq retirement-fails t)
                                        (null emacsos-assist-web--queue)))))
                  ((symbol-function 'emacsos-assist-web--try-write-cache)
                   (lambda (&rest _) t))
                  ((symbol-function 'emacsos-assist-web--render)
                   (lambda (&rest _) nil))
                  ((symbol-function 'emacsos-assist-web-git--begin)
                   (lambda (&rest _) nil)))
          (emacsos-assist-web-git--run-access-uncertain 404 "run-a")
          (emacsos-assist-web-git--canonical-authorized
           emacsos-assist-web-git--auth-epoch)
          (emacsos-assist-web--reobserve-entry entry)
          (funcall exact-run
                   '((id . "run-a") (thread_id . "thread-1")
                     (status . "success")) nil)
          (should r2)
          (should (emacsos-assist-web-git--run-record "thread-1" "run-a"))
          (when (eq retirement-fails 'new-denial)
            (emacsos-assist-web-git--run-access-uncertain 403 "run-a"))
          (funcall r2
                   (test-assist-web-git--snapshot "ready" "topic/new") nil)
          (if retirement-fails
              (progn
                (should emacsos-assist-web--queue)
                (should (emacsos-assist-web-git--run-record
                         "thread-1" "run-a")))
            (should-not emacsos-assist-web--queue)
            (should-not emacsos-assist-web-git--run-outcome-uncertain)))))))

(ert-deftest test-assist-web-git-post-t-denial-terminal-without-r-record-retires ()
  "A post-403 exact terminal read can reach R2 without an R 404 record."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let ((entry (emacsos-assist-web--entry
                  "fixture" 'accepted-unobserved "exact-key"))
          exact-run r2)
      (setf (plist-get entry :run-id) "run-a")
      (setq-local emacsos-assist-web--thread-id "thread-1"
                  emacsos-assist-web--queue (list entry))
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method path _payload done &rest _)
                   (if (string-match-p "/runs/" path)
                       (setq exact-run done)
                     (setq r2 done))))
                ((symbol-function 'emacsos-assist-web--save-draft)
                 (lambda () t))
                ((symbol-function 'emacsos-assist-web--try-write-cache)
                 (lambda (&rest _) t))
                ((symbol-function 'emacsos-assist-web--render) #'ignore)
                ((symbol-function 'emacsos-assist-web-git--begin) #'ignore))
        (emacsos-assist-web-git--canonical-denied 403)
        (emacsos-assist-web-git--canonical-authorized
         emacsos-assist-web-git--auth-epoch)
        (should-not emacsos-assist-web-git--run-outcome-uncertain)
        (emacsos-assist-web--reobserve-entry entry)
        (funcall exact-run
                 '((id . "run-a") (thread_id . "thread-1")
                   (status . "success")) nil)
        (should (integerp (plist-get entry :run-read-start-epoch)))
        (should r2)
        (funcall r2 (test-assist-web-git--snapshot
                     "ready" "topic/new") nil)
        (should-not emacsos-assist-web--queue)
        (should-not emacsos-assist-web-git--denied)))))

(ert-deftest test-assist-web-git-legacy-terminal-gate-waits-for-draft-retirement ()
  "Legacy exact success cannot clear A before its canonical draft commit."
  (dolist (retirement-fails '(nil t))
    (let ((emacsos-assist-web-cache-directory
           (make-temp-file "assist-git-legacy-run-gate-" t)))
      (unwind-protect
          (with-temp-buffer
            (emacsos-assist-web-mode)
            (emacsos-assist-web--write-prompt)
            (setq-local emacsos-assist-web--thread-id "thread-1"
                        emacsos-assist-web--run-id "run-a"
                        emacsos-assist-web--pending-key
                        "emacsos-0123456789abcdef0123456789abcdef"
                        emacsos-assist-web--submitted-text "hello"
                        emacsos-assist-web--pending-accepted-p t)
            (should (emacsos-assist-web--save-draft))
            (let ((real-save
                   (symbol-function 'emacsos-assist-web--legacy-save-draft))
                  run-callback chat-callback)
              (cl-letf (((symbol-function 'run-at-time)
                         (lambda (&rest _) nil))
                        ((symbol-function 'emacsos-assist-web--request)
                         (lambda (_method path _payload done &rest _)
                           (if (string-match-p "/runs/" path)
                               (setq run-callback done)
                             (setq chat-callback done))))
                        ((symbol-function 'emacsos-assist-web--try-write-cache)
                         (lambda (&rest _) t))
                        ((symbol-function 'emacsos-assist-web--legacy-save-draft)
                         (lambda ()
                           (if (and retirement-fails
                                    (not emacsos-assist-web--run-id))
                               nil
                             (funcall real-save))))
                        ((symbol-function 'emacsos-assist-web--render)
                         (lambda (&rest _) nil))
                        ((symbol-function 'emacsos-assist-web-git--begin)
                         (lambda (&rest _) nil)))
                (emacsos-assist-web-git--run-access-uncertain 404 "run-a")
                (emacsos-assist-web-git--canonical-authorized
                 emacsos-assist-web-git--auth-epoch)
                (emacsos-assist-web--legacy-terminal-probe
                 (current-buffer) "run-a")
                (funcall run-callback
                         '((id . "run-a") (thread_id . "thread-1")
                           (status . "success")) nil)
                (should (emacsos-assist-web-git--run-record
                         "thread-1" "run-a"))
                (funcall chat-callback
                         (test-assist-web-git--snapshot
                          "ready" "topic/new") nil)
                (if retirement-fails
                    (progn
                      (should (equal emacsos-assist-web--run-id "run-a"))
                      (should (emacsos-assist-web-git--run-record
                               "thread-1" "run-a")))
                  (should-not emacsos-assist-web--run-id)
                  (should-not emacsos-assist-web-git--run-outcome-uncertain)))))
        (delete-directory emacsos-assist-web-cache-directory t)))))

(ert-deftest test-assist-web-git-unknown-legacy-run-status-keeps-gate ()
  "An authenticated but unknown exact Run status cannot clear A."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq-local emacsos-assist-web--thread-id "thread-1"
                emacsos-assist-web--run-id "run-a"
                emacsos-assist-web--pending-accepted-p t)
    (let (run-callback chat-requested)
      (cl-letf (((symbol-function 'run-at-time) (lambda (&rest _) nil))
                ((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method path _payload done &rest _)
                   (if (string-match-p "/runs/" path)
                       (setq run-callback done)
                     (setq chat-requested t)))))
        (emacsos-assist-web-git--run-access-uncertain 404 "run-a")
        (emacsos-assist-web-git--canonical-authorized
         emacsos-assist-web-git--auth-epoch)
        (emacsos-assist-web--legacy-terminal-probe (current-buffer) "run-a")
        (funcall run-callback
                 '((id . "run-a") (thread_id . "thread-1")
                   (status . "unexpected")) nil)
        (should-not chat-requested)
        (should (emacsos-assist-web-git--run-record
                 "thread-1" "run-a"))))))

(ert-deftest test-assist-web-git-legacy-active-run-save-failure-blocks-t-get ()
  "A legacy active status must save its exact R receipt before fresh T GET."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq-local emacsos-assist-web--thread-id "thread-1"
                emacsos-assist-web--run-id "run-a"
                emacsos-assist-web--pending-accepted-p t
                emacsos-assist-web--pending-key
                "emacsos-0123456789abcdef0123456789abcdef"
                emacsos-assist-web--submitted-text "hello"
                emacsos-assist-web-git-thread-mode t)
    (let (run-callback chat-requested)
      (cl-letf (((symbol-function 'run-at-time) (lambda (&rest _) nil))
                ((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method path _payload done &rest _)
                   (if (string-match-p "/runs/" path)
                       (setq run-callback done)
                     (setq chat-requested t))))
                ((symbol-function 'emacsos-assist-web--legacy-save-draft)
                 (lambda () nil)))
        (emacsos-assist-web-git--run-access-uncertain 404 "run-a")
        (emacsos-assist-web-git--canonical-authorized
         emacsos-assist-web-git--auth-epoch)
        (emacsos-assist-web--legacy-terminal-probe (current-buffer) "run-a")
        (funcall run-callback
                 '((id . "run-a") (thread_id . "thread-1")
                   (status . "running")) nil)
        (should-not chat-requested)
        (should (emacsos-assist-web-git--run-record "thread-1" "run-a"))
        (should-error (emacsos-assist-web-git--command 'files)
                      :type 'user-error)))))

(ert-deftest test-assist-web-git-manual-run-404-recheck-is-auth-only ()
  "A Run denial permits one thread-auth GET, not manual recovery work."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let ((entry (emacsos-assist-web--entry
                  "fixture" 'terminal-unreconciled "exact-key"))
          scheduled requests)
      (setf (plist-get entry :run-id) "run-1"
            (plist-get entry :requires-reobserve) t)
      (setq-local emacsos-assist-web--thread-id "thread-1"
                  emacsos-assist-web--manual-recovery-required t
                  emacsos-assist-web--queue (list entry))
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (_seconds _repeat callback &rest _)
                   (push callback scheduled)))
                ((symbol-function 'emacsos-assist-web--request)
                 (lambda (method path _payload callback &rest _)
                   (push (list method path callback) requests)))
                ((symbol-function 'emacsos-assist-web--render)
                 (lambda (&rest _) (ert-fail "auth-only GET rendered")))
                ((symbol-function 'emacsos-assist-web--save-draft)
                 (lambda (&rest _) (ert-fail "auth-only GET saved draft")))
                ((symbol-function 'emacsos-assist-web--try-write-cache)
                 (lambda (&rest _) (ert-fail "auth-only GET saved chat")))
                ((symbol-function 'emacsos-assist-web-git--begin)
                 (lambda (&rest _) (ert-fail "auth-only GET fetched Git"))))
        ;; Reopening a gated buffer does not start an automatic request.
        (emacsos-assist-web-git--maybe-run-recheck)
        (should-not requests)
        ;; The prior user-initiated exact Run GET received 404.
        (emacsos-assist-web-git--run-access-uncertain 404 "run-1")
        (funcall (car scheduled))
        (should (= (length requests) 1))
        (should (equal (cadar requests) "threads/thread-1"))
        (funcall (caddar requests)
                 (test-assist-web-git--snapshot "ready" "topic/one") nil)
        (should-not emacsos-assist-web-git--denied)
        (should emacsos-assist-web-git--run-outcome-uncertain)
        (should emacsos-assist-web--manual-recovery-required)
        (should (eq (emacsos-assist-web--entry-state entry)
                    'terminal-unreconciled))
        (should-not emacsos-assist-web-git--metadata)
          (should (string-prefix-p "Run recovery pending; Refresh"
                                   (emacsos-assist-web-git--thread-header)))
        ;; A second explicit Refresh is the first renewed exact Run read.
        (emacsos-assist-web-refresh-thread)
        (should (= (length requests) 2))
        (should (equal (cadar requests)
                       "threads/thread-1/runs/run-1"))))))

(ert-deftest test-assist-web-git-run-denial-during-r2-defers-one-recheck ()
  "A pre-denial R2 cannot clear the fence; teardown starts one newer GET."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq-local emacsos-assist-web--thread-id "thread-1"
                emacsos-assist-web--reconcile-generation 7)
    (let (scheduled requests)
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (_seconds _repeat callback &rest _)
                   (push callback scheduled)))
                ((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload callback &rest _)
                   (push callback requests))))
        (emacsos-assist-web-git--run-access-uncertain 404 "run-1")
        (funcall (car scheduled))
        (should-not requests)
        (emacsos-assist-web-git--canonical-authorized 0)
        (should (eq emacsos-assist-web-git--denied 'run))
        (setq emacsos-assist-web--reconcile-generation nil)
        (emacsos-assist-web-git--r2-finished 7 t)
        (emacsos-assist-web-git--r2-finished 7 t)
        (should (= (length requests) 1))
        (should-not emacsos-assist-web-git--run-recheck-needed)))))

(ert-deftest test-assist-web-git-run-recheck-pauses-with-failed-recovery ()
  "A failed local recovery discards deferred transport and shows restart."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq-local emacsos-assist-web--thread-id "thread-1"
                emacsos-assist-web--reconcile-generation 7)
    (let (scheduled)
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (_seconds _repeat callback &rest _)
                   (push callback scheduled)))
                ((symbol-function 'emacsos-assist-web--legacy-refresh-thread)
                 (lambda (&rest _) (ert-fail "recheck during recovery pause"))))
        (emacsos-assist-web-git--run-access-uncertain 404 "run-1")
        (setq-local emacsos-assist-web--reconcile-recovery-paused t
                    emacsos-assist-web--reconcile-generation nil)
        (funcall (car scheduled))
        (should-not emacsos-assist-web-git--run-recheck-needed)
        (should (string-match-p "restart to recover"
                                emacsos-assist-web-git--unavailable))
        (should (string-match-p "Restart to recover"
                                (emacsos-assist-web-git--thread-header)))))))

(ert-deftest test-assist-web-git-recovery-gate-drains-active-probe-intent ()
  "An older probe callback cannot defer a window intent past a recovery gate."
  (save-window-excursion
    (let* ((thread (generate-new-buffer " *git-gated-probe*"))
           (window (selected-window))
           (original-serial (or (window-parameter
                                 (selected-window) 'assist-web-git-intent) 0))
           callback)
      (unwind-protect
          (progn
            (set-window-buffer window thread)
            (with-current-buffer thread
              (emacsos-assist-web-mode)
              (setq-local emacsos-assist-web--thread-id "thread-1")
              (emacsos-assist-web-git--sync-keys)
              (cl-letf (((symbol-function 'emacsos-assist-web-git--read-metadata)
                         (lambda (_thread done) (setq callback done))))
                (emacsos-assist-web-git--command 'files)
                (should (= (length emacsos-assist-web-git--active-probes) 1))
                (emacsos-assist-web--manual-recovery-activate)
                (should-not emacsos-assist-web-git--active-probes)
                (should (= (window-parameter window 'assist-web-git-intent)
                           (+ original-serial 2)))
                (funcall callback
                         (test-assist-web-git--metadata
                          "ready" "topic/old" test-assist-web-git--head)
                         nil)
                (should-not emacsos-assist-web-git--deferred-probes)
                (should-not emacsos-assist-web-git--request))))
        (kill-buffer thread)))))

(ert-deftest test-assist-web-git-explicit-refresh-keeps-peer-fetch-intent ()
  "W1 Refresh does not discard W2's live intent on a shared fetch."
  (save-window-excursion
    (let* ((thread (generate-new-buffer " *git-refresh-peer*"))
           (first (selected-window))
           (second (split-window-right))
           (metadata (test-assist-web-git--metadata
                      "ready" "topic/old" test-assist-web-git--head))
           (peer (list :action 'diff :buffer thread :window second :serial 1))
           (request (list :id "stage" :epoch 0 :metadata metadata
                          :intents (list peer)))
           callback)
      (unwind-protect
          (progn
            (set-window-buffer first thread)
            (set-window-buffer second thread)
            (set-window-parameter second 'assist-web-git-intent 1)
            (with-current-buffer thread
              (emacsos-assist-web-mode)
              (setq-local emacsos-assist-web--thread-id "thread-1"
                          emacsos-assist-web-git--metadata metadata
                          emacsos-assist-web-git--request request)
              (emacsos-assist-web-git--sync-keys))
            (cl-letf (((symbol-function 'emacsos-assist-web-git--read-metadata)
                       (lambda (_thread done) (setq callback done))))
              (with-selected-window first
                (with-current-buffer thread
                  (emacsos-assist-web-git-refresh)))
              (should (eq (with-current-buffer thread
                            emacsos-assist-web-git--request)
                          request))
              (funcall callback metadata nil)
              (with-current-buffer thread
                (should (memq peer (plist-get request :intents)))
                (should (emacsos-assist-web-git--intent-live-p peer)))))
        (kill-buffer thread)))))

(ert-deftest test-assist-web-git-chooser-quit-does-not-drop-peer-promotion ()
  "A W1 C-g is local to W1; W2 still receives the verified generation."
  (save-window-excursion
    (let* ((root (make-temp-file "assist-git-quit-" t))
           (emacsos-assist-web-git-cache-directory root)
           (thread (generate-new-buffer " *git-quit-peer*"))
           (first (selected-window))
           (second (split-window-right))
           (metadata (test-assist-web-git--metadata
                      "ready" "topic/old" test-assist-web-git--head))
           (id "stage-a")
           (first-intent (list :action 'files :buffer thread
                               :window first :serial 1))
           (second-intent (list :action 'diff :buffer thread
                                :window second :serial 1))
           (request (list :id id :epoch 0 :metadata metadata
                          :verified-epoch 0
                          :intents (list first-intent second-intent)))
           opened)
      (unwind-protect
          (progn
            (make-directory (expand-file-name (concat "staging/" id) root) t)
            (make-directory (expand-file-name "generations" root) t)
            (set-window-buffer first thread)
            (set-window-buffer second thread)
            (set-window-parameter first 'assist-web-git-intent 1)
            (set-window-parameter second 'assist-web-git-intent 1)
            (with-current-buffer thread
              (emacsos-assist-web-mode)
              (setq-local emacsos-assist-web--thread-id "thread-1"
                          emacsos-assist-web-git--metadata metadata
                          emacsos-assist-web-git--request request)
              (cl-letf (((symbol-function 'emacsos-assist-web-git--open)
                         (lambda (intent _generation)
                           (if (eq intent first-intent)
                               (signal 'quit nil)
                             (setq opened intent)))))
                (emacsos-assist-web-git--promote
                 request (list :thread_oid test-assist-web-git--head
                               :main_oid test-assist-web-git--published)))
              (should (eq opened second-intent))
              (should emacsos-assist-web-git--current)))
        (set-window-parameter first 'assist-web-git-intent nil)
        (set-window-parameter second 'assist-web-git-intent nil)
        (kill-buffer thread)
        (delete-directory root t)))))

(ert-deftest test-assist-web-git-invalid-projection-does-not-reject-chat-refresh ()
  (let ((broken (test-assist-web-git--snapshot "ready" "topic/one"))
        rendered)
    (setf (alist-get 'published_revision
                    (alist-get 'workspace (alist-get 'thread broken)))
          test-assist-web-git--published)
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq-local emacsos-assist-web--thread-id "thread-1")
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload callback &rest _)
                   (funcall callback broken nil)))
                ((symbol-function 'emacsos-assist-web--try-write-cache)
                 (lambda (&rest _) t))
                ((symbol-function 'emacsos-assist-web--render)
                 (lambda (snapshot &rest _) (setq rendered snapshot))))
        (emacsos-assist-web--legacy-refresh-thread (current-buffer))
        (should (eq rendered broken))
        (should-not emacsos-assist-web-git--metadata)
        (should (equal emacsos-assist-web-git--unavailable
                       "Git state unavailable"))))))

(ert-deftest test-assist-web-git-invalid-projection-does-not-block-reconciliation ()
  (let ((broken (test-assist-web-git--snapshot "ready" "topic/one"))
        rendered)
    (setf (alist-get 'published_revision
                    (alist-get 'workspace (alist-get 'thread broken)))
          test-assist-web-git--published)
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq-local emacsos-assist-web--thread-id "thread-1"
                  emacsos-assist-web--queue
                  (list (emacsos-assist-web--entry
                         "fixture" 'reconciling "exact-key")))
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload callback &rest _)
                   (funcall callback broken nil)))
                ((symbol-function 'emacsos-assist-web--try-write-cache)
                 (lambda (&rest _) t))
                ((symbol-function 'emacsos-assist-web--save-draft)
                 (lambda () t))
                ((symbol-function 'emacsos-assist-web--render)
                 (lambda (snapshot &rest _) (setq rendered snapshot)))
                ((symbol-function 'emacsos-assist-web--sync-active-surface)
                 #'ignore))
        (emacsos-assist-web--reconcile-queue)
        (should (eq rendered broken))
        (should-not emacsos-assist-web--queue)
        (should-not emacsos-assist-web-git--metadata)))))

(ert-deftest test-assist-web-git-state-update-error-does-not-reject-chat-refresh ()
  (let ((snapshot (test-assist-web-git--snapshot "ready" "topic/one"))
        rendered)
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq-local emacsos-assist-web--thread-id "thread-1")
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload callback &rest _)
                   (funcall callback snapshot nil)))
                ((symbol-function 'emacsos-assist-web-git--note)
                 (lambda (&rest _) (error "Git state update failed")))
                ((symbol-function 'emacsos-assist-web--try-write-cache)
                 (lambda (&rest _) t))
                ((symbol-function 'emacsos-assist-web--render)
                 (lambda (value &rest _) (setq rendered value))))
        (emacsos-assist-web--legacy-refresh-thread (current-buffer))
        (should (eq rendered snapshot))
        (should-not emacsos-assist-web-git--metadata)
        (should (equal emacsos-assist-web-git--unavailable
                       "Git state unavailable"))))))

(ert-deftest test-assist-web-git-state-update-error-does-not-retain-queue ()
  (let ((snapshot (test-assist-web-git--snapshot "ready" "topic/one"))
        rendered)
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq-local emacsos-assist-web--thread-id "thread-1"
                  emacsos-assist-web--queue
                  (list (emacsos-assist-web--entry
                         "fixture" 'reconciling "exact-key")))
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload callback &rest _)
                   (funcall callback snapshot nil)))
                ((symbol-function 'emacsos-assist-web-git--note)
                 (lambda (&rest _) (error "Git state update failed")))
                ((symbol-function 'emacsos-assist-web--try-write-cache)
                 (lambda (&rest _) t))
                ((symbol-function 'emacsos-assist-web--save-draft)
                 (lambda () t))
                ((symbol-function 'emacsos-assist-web--render)
                 (lambda (value &rest _) (setq rendered value)))
                ((symbol-function 'emacsos-assist-web--sync-active-surface)
                 #'ignore))
        (emacsos-assist-web--reconcile-queue)
        (should (eq rendered snapshot))
        (should-not emacsos-assist-web--queue)
        (should (equal emacsos-assist-web-git--unavailable
                       "Git state unavailable"))))))

(ert-deftest test-assist-web-git-unknown-status-still-rejects-reconciliation ()
  (let ((snapshot (test-assist-web-git--snapshot "future-state" "topic/one"))
        rendered cached)
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq-local emacsos-assist-web--thread-id "thread-1"
                  emacsos-assist-web--queue
                  (list (emacsos-assist-web--entry
                         "fixture" 'reconciling "exact-key")))
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload callback &rest _)
                   (funcall callback snapshot nil)))
                ((symbol-function 'emacsos-assist-web--try-write-cache)
                 (lambda (&rest _) (setq cached t)))
                ((symbol-function 'emacsos-assist-web--render)
                 (lambda (&rest _) (setq rendered t)))
                ((symbol-function 'emacsos-assist-web--save-draft)
                 (lambda () t)))
        (emacsos-assist-web--reconcile-queue)
        (should-not rendered)
        (should-not cached)
        (should (eq (plist-get (car emacsos-assist-web--queue) :state)
                    'terminal-unreconciled))))))

(ert-deftest test-assist-web-git-helper-refusal-is-not-success ()
  (let ((result (emacsos-assist-web-git--parse-helper-result
                 "{\"ok\":false,\"reason\":\"no configured Git remote\"}")))
    (should-not (plist-get result :ok))
    (should (equal (plist-get result :reason)
                   "no configured Git remote"))))

(ert-deftest test-assist-web-git-keys-are-canonical-thread-local ()
  (let ((previous (lookup-key global-map (kbd "C-c d"))))
    (unwind-protect
        (progn
          (global-set-key (kbd "C-c d") #'dtach-shell)
          (with-temp-buffer
            (emacsos-assist-web-mode)
            (setq-local emacsos-assist-web--thread-id nil)
            (emacsos-assist-web-git--sync-keys)
            (should-not emacsos-assist-web-git-thread-mode)
            (should (eq (key-binding (kbd "C-c d")) #'dtach-shell))
            (setq-local emacsos-assist-web--thread-id "thread-1")
            (emacsos-assist-web-git--sync-keys)
            (should emacsos-assist-web-git-thread-mode)
            (should (eq (key-binding (kbd "C-x C-f"))
                        #'emacsos-assist-web-git-find-file))
            (should (eq (key-binding (kbd "C-c d"))
                        #'emacsos-assist-web-git-diff))
            (setq-local emacsos-assist-web--thread-id nil)
            (emacsos-assist-web-git--sync-keys)
            (should-not emacsos-assist-web-git-thread-mode)
            (should (eq (key-binding (kbd "C-c d")) #'dtach-shell))))
      (define-key global-map (kbd "C-c d") previous))))

(ert-deftest test-assist-web-git-file-view-ignores-repository-local-code ()
  (let* ((root (make-temp-file "assist-git-view-" t))
         (file (expand-file-name "malicious.txt" root))
         (test-assist-web-git--executed nil)
         (thread (current-buffer))
         (generation
          (make-emacsos-assist-web-git-generation
           :path root :oid test-assist-web-git--head)))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name ".dir-locals.el" root)
            (insert "((nil . ((eval . (setq test-assist-web-git--executed t)))))"))
          (with-temp-file file
            (insert "-*- eval: (setq test-assist-web-git--executed t) -*-\n"
                    "worktree content\n"))
          (let ((view (emacsos-assist-web-git--literal-file-view
                       file root thread generation)))
            (unwind-protect
                (with-current-buffer view
                  (should buffer-read-only)
                  (should-not buffer-file-name)
                  (should (string-match-p "worktree content" (buffer-string)))
                  (should-not test-assist-web-git--executed))
              (kill-buffer view))))
      (delete-directory root t))))

(ert-deftest test-assist-web-git-file-read-is-bounded-after-size-precheck ()
  (let* ((root (make-temp-file "assist-git-read-bound-" t))
         (file (expand-file-name "growing.txt" root))
         (generation (make-emacsos-assist-web-git-generation
                      :path root :oid test-assist-web-git--head))
         read-end)
    (unwind-protect
        (progn
          (with-temp-file file (insert "small at precheck"))
          (cl-letf (((symbol-function 'insert-file-contents-literally)
                     (lambda (_path _visit _start end &rest _)
                       (setq read-end end)
                       (insert (make-string
                                (1+ emacsos-assist-web-git--file-view-limit) ?x)))))
            (should (equal (cadr (should-error
                                 (emacsos-assist-web-git--literal-file-view
                                  file root (current-buffer) generation)))
                           "Git file exceeds 1 MiB display limit")))
          (should (= read-end (1+ emacsos-assist-web-git--file-view-limit))))
      (delete-directory root t))))

(ert-deftest test-assist-web-git-file-view-rejects-internals-symlinks-and-large-file ()
  (let* ((root (make-temp-file "assist-git-file-bound-" t))
         (git-dir (expand-file-name ".git/objects" root))
         (internal (expand-file-name "object" git-dir))
         (large (expand-file-name "large.txt" root))
         (small (expand-file-name "small.txt" root))
         (linked (expand-file-name "linked.txt" root))
         (nested (expand-file-name "nested" root))
         (linked-dir (expand-file-name "linked-dir" root))
         (generation (make-emacsos-assist-web-git-generation
                      :path root :oid test-assist-web-git--head)))
    (unwind-protect
        (progn
          (make-directory git-dir t)
          (with-temp-file internal (insert "not a worktree file"))
          (with-temp-file large
            (insert (make-string (1+ emacsos-assist-web-git--file-view-limit)
                                 ?x)))
          (make-directory nested)
          (with-temp-file small (insert "small"))
          (with-temp-file (expand-file-name "file.txt" nested)
            (insert "nested"))
          (make-symbolic-link small linked)
          (make-symbolic-link nested linked-dir)
          (should (equal (cadr (should-error
                               (emacsos-assist-web-git--literal-file-view
                                internal root (current-buffer) generation)))
                         "Git internals are not browseable"))
          (should (equal (cadr (should-error
                               (emacsos-assist-web-git--literal-file-view
                                large root (current-buffer) generation)))
                         "Git file exceeds 1 MiB display limit"))
          (should (equal (cadr (should-error
                               (emacsos-assist-web-git--literal-file-view
                                linked root (current-buffer) generation)))
                         "Git symbolic-link paths cannot be opened"))
          (should (equal (cadr (should-error
                               (emacsos-assist-web-git--literal-file-view
                                (expand-file-name "file.txt" linked-dir)
                                root (current-buffer) generation)))
                         "Git symbolic-link paths cannot be opened")))
      (delete-directory root t))))

(ert-deftest test-assist-web-git-command-probe-failure-is-intent-local ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq-local emacsos-assist-web--thread-id "thread-1")
    (emacsos-assist-web-git--sync-keys)
    (let* ((metadata (test-assist-web-git--metadata
                      "ready" "topic/one" test-assist-web-git--head))
           (generation (make-emacsos-assist-web-git-generation
                        :metadata metadata :state 'current)))
      (setq-local emacsos-assist-web-git--metadata metadata
                  emacsos-assist-web-git--current generation)
      (cl-letf (((symbol-function 'emacsos-assist-web-git--read-metadata)
                 (lambda (_thread callback) (funcall callback nil "offline"))))
        (emacsos-assist-web-git--command 'files))
      (should (eq (emacsos-assist-web-git-generation-state generation)
                  'current))
      (should (string-match-p " current" (emacsos-assist-web-git--thread-header)))
      (let ((thread (current-buffer)))
        (with-temp-buffer
          (setq-local emacsos-assist-web-git--view-thread thread
                      emacsos-assist-web-git--view-generation generation)
          (should (string-match-p " current"
                                  (emacsos-assist-web-git--view-header)))))
      (cl-letf (((symbol-function 'emacsos-assist-web-git--read-metadata)
                 (lambda (_thread callback)
                   (funcall callback nil '(git . "bad Git fields")))))
        (emacsos-assist-web-git--command 'files))
      (should (eq emacsos-assist-web-git--metadata metadata))
      (should-not emacsos-assist-web-git--unavailable)
      (cl-letf (((symbol-function 'emacsos-assist-web-git--read-metadata)
                 (lambda (_thread callback)
                   (funcall callback nil '(canonical . "bad thread status")))))
        (emacsos-assist-web-git--command 'files))
      (should (eq emacsos-assist-web-git--metadata metadata))
      (should (eq (emacsos-assist-web-git-generation-state generation)
                  'current)))))

(ert-deftest test-assist-web-git-command-denial-cannot-retain-current ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq-local emacsos-assist-web--thread-id "thread-1")
    (emacsos-assist-web-git--sync-keys)
    (let* ((metadata (test-assist-web-git--metadata
                      "ready" "topic/one" test-assist-web-git--head))
           (generation (make-emacsos-assist-web-git-generation
                        :metadata metadata :state 'current)))
      (setq-local emacsos-assist-web-git--metadata metadata
                  emacsos-assist-web-git--current generation)
      (cl-letf (((symbol-function 'emacsos-assist-web--read-token)
                 (lambda () "token"))
                ((symbol-function 'run-at-time) (lambda (&rest _) nil))
                ((symbol-function 'url-retrieve)
                 (lambda (_url callback &rest _)
                   (let ((response (generate-new-buffer " *git-denial-test*")))
                     (with-current-buffer response
                       (insert "denied")
                       (setq-local url-http-response-status 403
                                   url-http-content-type "text/plain"
                                   url-http-end-of-headers (copy-marker (point-min)))
                       (funcall callback nil))
                     response))))
        (emacsos-assist-web-git--command 'files))
      (should-not emacsos-assist-web-git--metadata)
      (should emacsos-assist-web-git--denied)
      (should (= emacsos-assist-web-git--auth-epoch 1))
      (should (equal emacsos-assist-web-git--unavailable
                     "thread access denied (403); reauthorize and Retry"))
      (should-not (string-match-p " current"
                                  (emacsos-assist-web-git--thread-header))))))

(ert-deftest test-assist-web-git-busy-thread-404-keeps-denial-reason ()
  "A busy-check callback cannot replace a raw definitive T404 reason."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let ((entry (emacsos-assist-web--entry
                  "fixture" 'accepted-unobserved "exact-key")))
      (setf (plist-get entry :run-id) "run-a"
            (plist-get entry :reobserve-generation) 1)
      (setq-local emacsos-assist-web--thread-id "thread-1"
                  emacsos-assist-web--queue (list entry))
      (cl-letf (((symbol-function 'emacsos-assist-web--read-token)
                 (lambda () "token"))
                ((symbol-function 'run-at-time) (lambda (&rest _) nil))
                ((symbol-function 'url-retrieve)
                 (lambda (_url callback &rest _)
                   (let ((response (generate-new-buffer " *git-busy-404*")))
                     (with-current-buffer response
                       (insert "denied")
                       (setq-local url-http-response-status 404
                                   url-http-content-type "text/plain"
                                   url-http-end-of-headers
                                   (copy-marker (point-min)))
                       (funcall callback nil))
                     response))))
        (emacsos-assist-web-git--run-access-uncertain 404 "run-a")
        (emacsos-assist-web-git--canonical-authorized
         emacsos-assist-web-git--auth-epoch)
        (emacsos-assist-web-git--confirm-active-run
         "thread-1" "run-a" emacsos-assist-web-git--auth-epoch entry))
      (should (eq emacsos-assist-web-git--denied t))
      (should (equal emacsos-assist-web-git--unavailable
                     "thread unavailable (404); reopen and Retry"))
      (should (string-prefix-p
               "Thread unavailable"
               (substring-no-properties
                (emacsos-assist-web-git--thread-header)))))))

(ert-deftest test-assist-web-git-thread-denial-fences-peer-before-source-quit ()
  "A source UI quit cannot leave another same-T buffer current."
  (let ((source (generate-new-buffer " *git-denial-source*"))
        (peer (generate-new-buffer " *git-denial-peer*"))
        cancelled)
    (unwind-protect
        (progn
          (dolist (buffer (list source peer))
            (with-current-buffer buffer
              (emacsos-assist-web-mode)
              (let ((metadata (test-assist-web-git--metadata
                               "ready" "topic/one"
                               test-assist-web-git--head)))
                (setq-local emacsos-assist-web--thread-id "thread-1"
                            emacsos-assist-web-git--metadata metadata
                            emacsos-assist-web-git--current
                            (make-emacsos-assist-web-git-generation
                             :metadata metadata :state 'current)))))
          (cl-letf (((symbol-function 'emacsos-assist-web-git--release-intents)
                     (lambda (&rest _)
                       (when (eq (current-buffer) source)
                         (signal 'quit nil))))
                    ((symbol-function 'emacsos-assist-web-git--cancel)
                     (lambda () (push (current-buffer) cancelled))))
            (with-current-buffer source
              (emacsos-assist-web-git--canonical-denied 403)))
          (should (memq source cancelled))
          (should (memq peer cancelled))
          (with-current-buffer peer
            (should (eq emacsos-assist-web-git--denied t))
            (should-not emacsos-assist-web-git--metadata)
            (should (eq (emacsos-assist-web-git-generation-state
                         emacsos-assist-web-git--current) 'cached))
            (should-not (string= (emacsos-assist-web-git--view-state
                                  emacsos-assist-web-git--current peer)
                                 "current"))))
          (with-current-buffer source
            (should (eq emacsos-assist-web-git--denied t))
            (should-not emacsos-assist-web-git--metadata)))
      (kill-buffer source)
      (kill-buffer peer)))

(ert-deftest test-assist-web-git-thread-denial-defers-quit-in-peer-discovery ()
  "An input quit during same-T discovery cannot leave the peer current."
  (let ((source (generate-new-buffer " *git-discovery-source*"))
        (peer (generate-new-buffer " *git-discovery-peer*"))
        (reader (symbol-function 'buffer-local-value)))
    (unwind-protect
        (progn
          (dolist (buffer (list source peer))
            (with-current-buffer buffer
              (emacsos-assist-web-mode)
              (setq-local emacsos-assist-web--thread-id "thread-1"
                          emacsos-assist-web-git--current
                          (make-emacsos-assist-web-git-generation
                           :state 'current))))
          (cl-letf (((symbol-function 'buffer-local-value)
                     (lambda (symbol buffer)
                       (when (eq buffer peer) (setq quit-flag t))
                       (funcall reader symbol buffer))))
            (with-current-buffer source
              (let ((inhibit-quit t))
                (emacsos-assist-web-git--canonical-denied 403)
                (setq quit-flag nil))))
          (with-current-buffer peer
            (should (eq emacsos-assist-web-git--denied t))
            (should (eq (emacsos-assist-web-git-generation-state
                         emacsos-assist-web-git--current) 'cached))))
      (setq quit-flag nil)
      (kill-buffer source)
      (kill-buffer peer))))

(ert-deftest test-assist-web-git-thread-404-survives-cleanup-failure ()
  "An async cleanup failure cannot replace a definitive T404 reason."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq-local emacsos-assist-web--thread-id "thread-1")
    (let ((once t))
      (cl-letf (((symbol-function 'emacsos-assist-web-git--cancel)
                 (lambda ()
                   (when once
                     (setq once nil)
                     (emacsos-assist-web-git--cleanup-failed)))))
        (emacsos-assist-web-git--canonical-denied 404))
      (should (eq emacsos-assist-web-git--denied t))
      (should (eql emacsos-assist-web-git--thread-denial-status 404))
      (should (equal emacsos-assist-web-git--unavailable
                     "thread unavailable (404); reopen and Retry"))
      (should (string-prefix-p
               "Thread unavailable"
               (substring-no-properties
                (emacsos-assist-web-git--thread-header)))))))

(ert-deftest test-assist-web-git-denial-requires-new-accepted-chat-get ()
  (with-temp-buffer
    (let* ((snapshot (test-assist-web-git--snapshot "ready" "topic/one"))
           (metadata (emacsos-assist-web-git--metadata-from-snapshot snapshot))
           (generation (make-emacsos-assist-web-git-generation
                        :metadata metadata :state 'current)))
      (setq-local emacsos-assist-web-git--metadata metadata
                  emacsos-assist-web-git--current generation)
      (emacsos-assist-web-git--canonical-denied 404)
      (should emacsos-assist-web-git--denied)
      (should (equal emacsos-assist-web-git--unavailable
                     "thread unavailable (404); reopen and Retry"))
      ;; A pre-denial canonical response and a Git-only probe are not authority.
      (emacsos-assist-web-git--note-snapshot snapshot nil 0)
      (should emacsos-assist-web-git--denied)
      (should-not emacsos-assist-web-git--metadata)
      (emacsos-assist-web-git--note-snapshot
       snapshot nil emacsos-assist-web-git--auth-epoch)
      (should-not emacsos-assist-web-git--denied)
      (should (equal emacsos-assist-web-git--metadata metadata))
      (should (eq (emacsos-assist-web-git-generation-state generation)
                  'cached))
      (should-not (equal (emacsos-assist-web-git--view-state
                          generation (current-buffer)) "current")))))

(ert-deftest test-assist-web-git-restart-and-denial-have-short-details ()
  "Small-window feedback exposes a safe action and wrapped explanation."
  (save-window-excursion
    (let* ((thread (generate-new-buffer " *git-gate-details*"))
           (window (selected-window))
           (intent (list :action 'files :buffer thread :window window :serial 1)))
      (unwind-protect
          (progn
            (set-window-buffer window thread)
            (set-window-parameter window 'assist-web-git-intent 1)
            (with-current-buffer thread
              (emacsos-assist-web-mode)
              (setq-local emacsos-assist-web--thread-id "thread-1"
                          emacsos-assist-web--reconcile-recovery-paused t)
              (emacsos-assist-web-git--release-intents
               (list intent) "local recovery could not be saved; restart to recover" t)
              (should (= (length emacsos-assist-web-git--feedback-windows) 1))
              (let ((header (emacsos-assist-web-git--thread-header))
                    (feedback (eval (cadr (window-parameter
                                           window 'assist-web-git-feedback)) t)))
                (should (equal (substring-no-properties header)
                               "Restart to recover [?] "))
                (should (equal (substring-no-properties feedback)
                               "Restart to recover [?] "))
                (should-not (string-match-p "Retry" feedback))
                (should (equal (get-text-property (- (length header) 5)
                                                  'display header)
                               '(space :width (20) :height (40))))
                (should (equal (get-text-property (1- (length header))
                                                  'display header)
                               '(space :width (20) :height (40))))
                (should (get-text-property (1- (length header))
                                           'local-map header)))
              (should (eq (lookup-key emacsos-assist-web-git-thread-mode-map
                                      (kbd "C-c ?"))
                          #'emacsos-assist-web-git-details))
              (emacsos-assist-web-git-details)
              (should (string-match-p "Restart Emacs" (buffer-string)))
              (should visual-line-mode)
              (emacsos-assist-web-git-display-details-back)
              (setq-local emacsos-assist-web--reconcile-recovery-paused nil)
              (set-window-parameter window 'assist-web-git-intent 2)
              (setq-local emacsos-assist-web-git--active-probes
                          (list (list :action 'files :buffer thread
                                      :window window :serial 2)))
              (emacsos-assist-web-git--canonical-denied 403)
              (should (= (length emacsos-assist-web-git--feedback-windows) 1))
              (should (equal (substring-no-properties
                              (emacsos-assist-web-git--thread-header))
                             "Reauthorize [?] "))
              (should (string-match-p "Reauthorize"
                                      (eval (cadr (window-parameter
                                                   window 'assist-web-git-feedback)) t)))
              (emacsos-assist-web-git-details)
              (should (string-match-p "Reauthorize Assist" (buffer-string)))
              (emacsos-assist-web-git-display-details-back)
              (emacsos-assist-web-git--clear-feedback window)
              (should-not emacsos-assist-web-git--feedback-windows)))
        (set-window-parameter window 'assist-web-git-intent nil)
        (kill-buffer thread)))))

(ert-deftest test-assist-web-git-denial-releases-two-fetch-intents ()
  (save-window-excursion
    (let* ((thread (generate-new-buffer " *git-two-intents*"))
           (first (selected-window))
           (second (split-window-right)))
      (unwind-protect
          (progn
            (set-window-buffer first thread)
            (set-window-buffer second thread)
            (set-window-parameter first 'assist-web-git-intent 1)
            (set-window-parameter second 'assist-web-git-intent 2)
            (with-current-buffer thread
              (emacsos-assist-web-mode)
              (setq-local emacsos-assist-web-git--request
                          (list :id "stage" :process nil
                                :intents (list (list :buffer thread :window first
                                                     :serial 1 :action 'files)
                                               (list :buffer thread :window second
                                                     :serial 2 :action 'diff))))
              (cl-letf (((symbol-function 'emacsos-assist-web-git--cleanup)
                         (lambda (_id _kind callback) (funcall callback t))))
                (emacsos-assist-web-git--canonical-denied 403))
              (should-not emacsos-assist-web-git--request))
            (should (= (window-parameter first 'assist-web-git-intent) 2))
            (should (= (window-parameter second 'assist-web-git-intent) 3)))
        (kill-buffer thread)))))

(ert-deftest test-assist-web-git-chat-accepts-after-best-effort-cache-failure ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq-local emacsos-assist-web--thread-id "thread-1")
    (emacsos-assist-web-git--canonical-denied 403)
    (let ((snapshot (test-assist-web-git--snapshot "ready" "topic/one"))
          rendered)
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload callback &rest _)
                   (funcall callback snapshot nil)))
                ((symbol-function 'emacsos-assist-web--try-write-cache)
                 (lambda (&rest _) nil))
                ((symbol-function 'emacsos-assist-web--render)
                 (lambda (value &rest _) (setq rendered value))))
        (emacsos-assist-web-refresh-thread))
      (should (eq rendered snapshot))
      (should-not emacsos-assist-web-git--denied)
      (should (equal (plist-get emacsos-assist-web-git--metadata :branch)
                     "topic/one")))))

(ert-deftest test-assist-web-git-saved-chat-clears-denial-before-render-failure ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq-local emacsos-assist-web--thread-id "thread-1")
    (emacsos-assist-web-git--canonical-denied 403)
    (let ((snapshot (test-assist-web-git--snapshot "ready" "topic/one")))
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload callback &rest _)
                   (funcall callback snapshot nil)))
                ((symbol-function 'emacsos-assist-web--try-write-cache)
                 (lambda (&rest _) t))
                ((symbol-function 'emacsos-assist-web--render)
                 (lambda (&rest _) (error "render rejected"))))
        (emacsos-assist-web-refresh-thread))
      (should-not emacsos-assist-web-git--denied)
      (should (equal (plist-get emacsos-assist-web-git--metadata :branch)
                     "topic/one"))
      (should emacsos-assist-web--display-recovery))))

(ert-deftest test-assist-web-git-unsaved-unrendered-chat-keeps-denial ()
  "Neither a failed cache write nor a failed render accepts a chat GET."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq-local emacsos-assist-web--thread-id "thread-1")
    (emacsos-assist-web-git--canonical-denied 403)
    (cl-letf (((symbol-function 'emacsos-assist-web--request)
               (lambda (_method _path _payload callback &rest _)
                 (funcall callback
                          (test-assist-web-git--snapshot "ready" "topic/one") nil)))
              ((symbol-function 'emacsos-assist-web--try-write-cache)
               (lambda (&rest _) nil))
              ((symbol-function 'emacsos-assist-web--render)
               (lambda (&rest _) (error "render rejected"))))
      (emacsos-assist-web-refresh-thread))
    (should emacsos-assist-web-git--denied)
    (should-not emacsos-assist-web-git--metadata)))

(ert-deftest test-assist-web-git-queue-does-not-accept-before-durable-retirement ()
  (dolist (failure '(cache retirement))
    (with-temp-buffer
      (emacsos-assist-web-mode)
      (setq-local emacsos-assist-web--thread-id "thread-1"
                  emacsos-assist-web--queue
                  (list (emacsos-assist-web--entry
                         "fixture" 'reconciling "exact-key")))
      (emacsos-assist-web-git--canonical-denied 403)
      (let ((snapshot (test-assist-web-git--snapshot "ready" "topic/one"))
            rendered)
        (cl-letf (((symbol-function 'emacsos-assist-web--request)
                   (lambda (_method _path _payload callback &rest _)
                     (funcall callback snapshot nil)))
                  ((symbol-function 'emacsos-assist-web--try-write-cache)
                   (lambda (&rest _) (not (eq failure 'cache))))
                  ((symbol-function 'emacsos-assist-web--save-draft)
                   (lambda () (not (eq failure 'retirement))))
                  ((symbol-function 'emacsos-assist-web--render)
                   (lambda (&rest _) (setq rendered t))))
          (emacsos-assist-web--reconcile-queue))
        (should-not rendered)
        (should emacsos-assist-web-git--denied)
        (should-not emacsos-assist-web-git--metadata)))))

(ert-deftest test-assist-web-git-raw-size-denial-latches-once ()
  (let ((emacsos-assist-web-max-response-bytes 90)
        (header "HTTP/1.1 403 Forbidden\r\nContent-Type: text/plain\r\n\r\n"))
    (dolist (chunks (list (list (concat header (make-string 100 ?x)))
                          (list header (make-string 100 ?x))
                          (list "HTTP/1.1 103 Early Hints\r\n\r\n"
                                (concat header (make-string 100 ?x)))))
      (with-temp-buffer
        (setq-local emacsos-assist-web--thread-id "thread-1")
        (let ((response (generate-new-buffer " *git-raw-denial*"))
              filter problem)
          (unwind-protect
              (cl-letf (((symbol-function 'emacsos-assist-web--read-token)
                         (lambda () "token"))
                        ((symbol-function 'url-retrieve)
                         (lambda (&rest _) response))
                        ((symbol-function 'run-at-time)
                         (lambda (&rest _) nil))
                        ((symbol-function 'get-buffer-process)
                         (lambda (_buffer) 'fake-git-http))
                        ((symbol-function 'process-live-p)
                         (lambda (_process) t))
                        ((symbol-function 'process-filter)
                         (lambda (_process) #'ignore))
                        ((symbol-function 'set-process-filter)
                         (lambda (_process fn) (when fn (setq filter fn))))
                        ((symbol-function 'set-process-sentinel)
                         (lambda (&rest _) nil))
                        ((symbol-function 'delete-process)
                         (lambda (&rest _) nil))
                        ((symbol-function 'process-buffer)
                         (lambda (_process) response))
                        ((symbol-function 'emacsos-assist-web--kill-buffer-later)
                         (lambda (_buffer) nil)))
                (emacsos-assist-web--request
                 "GET" "threads/thread-1" nil
                 (lambda (_value error) (setq problem error))
                 nil nil nil nil t)
                (should filter)
                (dolist (chunk chunks)
                  (funcall filter 'fake-git-http chunk))
                (should emacsos-assist-web-git--denied)
                (should (= emacsos-assist-web-git--auth-epoch 1))
                (should (eq (plist-get problem :kind) 'http))
                (should (= (plist-get problem :status) 403)))
            (when (buffer-live-p response) (kill-buffer response))))))))

(ert-deftest test-assist-web-git-early-unknown-failure-downgrades-current ()
  (with-temp-buffer
    (setq-local emacsos-assist-web--thread-id "thread-1")
    (let* ((metadata (test-assist-web-git--metadata
                      "ready" "topic/one" test-assist-web-git--head))
           (generation (make-emacsos-assist-web-git-generation
                        :metadata metadata :state 'current)))
      (setq-local emacsos-assist-web-git--metadata metadata
                  emacsos-assist-web-git--current generation)
      (emacsos-assist-web--git-http-status
       (current-buffer) "GET" "threads/thread-1" 200 t)
      (should (eq emacsos-assist-web-git--metadata metadata))
      (should-not emacsos-assist-web-git--denied)
      (should (eq (emacsos-assist-web-git-generation-state generation)
                  'cached))
      (should-not (equal (emacsos-assist-web-git--view-state
                          generation (current-buffer)) "current")))))

(ert-deftest test-assist-web-git-canonical-timeout-downgrades-current ()
  (with-temp-buffer
    (setq-local emacsos-assist-web--thread-id "thread-1")
    (let* ((metadata (test-assist-web-git--metadata
                      "ready" "topic/one" test-assist-web-git--head))
           (generation (make-emacsos-assist-web-git-generation
                        :metadata metadata :state 'current))
           (request (list :id "stage" :metadata metadata))
           (response (generate-new-buffer " *git-canonical-timeout*"))
           timer problem)
      (setq-local emacsos-assist-web-git--metadata metadata
                  emacsos-assist-web-git--current generation
                  emacsos-assist-web-git--request request)
      (unwind-protect
          (cl-letf (((symbol-function 'emacsos-assist-web--read-token)
                     (lambda () "token"))
                    ((symbol-function 'url-retrieve)
                     (lambda (&rest _) response))
                    ((symbol-function 'run-at-time)
                     (lambda (_delay _repeat callback) (setq timer callback))))
            (emacsos-assist-web--request
             "GET" "threads/thread-1" nil
             (lambda (_value error) (setq problem error)))
            (funcall timer)
            (should (equal problem "Assist Web request timed out"))
            (should (eq emacsos-assist-web-git--metadata metadata))
            (should (eq emacsos-assist-web-git--request request))
            (should (eq (emacsos-assist-web-git-generation-state generation)
                        'cached)))
        (when (buffer-live-p response) (kill-buffer response))))))

(ert-deftest test-assist-web-git-first-canonical-timeout-says-no-mirror ()
  (with-temp-buffer
    (emacsos-assist-web-git--canonical-uncertain)
    (should (equal emacsos-assist-web-git--unavailable
                   "canonical refresh unavailable; no mirror; Retry"))
    (should-not emacsos-assist-web-git--current)))

(ert-deftest test-assist-web-git-canonical-tls-and-local-busy-downgrade ()
  (dolist (failure '(tls busy))
    (with-temp-buffer
      (setq-local emacsos-assist-web--thread-id "thread-1")
      (let* ((metadata (test-assist-web-git--metadata
                        "ready" "topic/one" test-assist-web-git--head))
             (generation (make-emacsos-assist-web-git-generation
                          :metadata metadata :state 'current))
             (request (list :id "stage" :metadata metadata))
             (emacsos-assist-web--requests (and (eq failure 'busy)
                                                  '(one two)))
             (emacsos-assist-web-max-concurrent-requests 2)
             problem)
        (setq-local emacsos-assist-web-git--metadata metadata
                    emacsos-assist-web-git--current generation
                    emacsos-assist-web-git--request request)
        (cl-letf (((symbol-function 'emacsos-assist-web--read-token)
                   (lambda () "token"))
                  ((symbol-function 'run-at-time)
                   (lambda (&rest _) nil))
                  ((symbol-function 'url-retrieve)
                   (lambda (_url callback &rest _)
                     (let ((response (generate-new-buffer " *git-canonical-tls*")))
                       (with-current-buffer response
                         (funcall callback
                                  '(:error (tls "bad certificate"))))
                       response))))
          (emacsos-assist-web--request
           "GET" "threads/thread-1" nil
           (lambda (_value error) (setq problem error))))
        (should (equal problem
                       (if (eq failure 'tls)
                           "Assist Web connection unavailable"
                         "Too many Assist Web requests are already running")))
        (should (eq emacsos-assist-web-git--metadata metadata))
        (should (eq emacsos-assist-web-git--request request))
        (should (eq (emacsos-assist-web-git-generation-state generation)
                    'cached))))))

(ert-deftest test-assist-web-git-probe-failure-preserves-other-window-fetch ()
  (dolist (failure '(busy tls timeout))
    (save-window-excursion
      (let* ((thread (generate-new-buffer " *git-probe-owner*"))
             (first (selected-window))
             (second (split-window-right))
             (emacsos-assist-web--requests (and (eq failure 'busy)
                                                '(one two)))
             (emacsos-assist-web-max-concurrent-requests 2)
             (cache (make-temp-file "git-probe-owner-cache-" t))
             response timer)
        (unwind-protect
            (progn
              (emacsos-assist-web-git--clear-feedback first)
              (emacsos-assist-web-git--clear-feedback second)
              (set-window-buffer first thread)
              (set-window-buffer second thread)
              (set-window-parameter first 'assist-web-git-intent 1)
              (with-current-buffer thread
                (emacsos-assist-web-mode)
                (setq-local emacsos-assist-web--thread-id "thread-1")
                (emacsos-assist-web-git--sync-keys)
                (let ((metadata (test-assist-web-git--metadata
                                 "ready" "topic/one" test-assist-web-git--head)))
                  (setq-local
                   emacsos-assist-web-git--metadata metadata
                   emacsos-assist-web-git--request
                   (list :id "stage" :epoch 0 :metadata metadata :process nil
                         :verified-epoch 0 :final-attempts 1
                         :intents
                         (list (list :buffer thread :window first :serial 1
                                     :action 'files))))))
              (cl-letf (((symbol-function 'emacsos-assist-web--read-token)
                         (lambda () "token"))
                        ((symbol-function 'run-at-time)
                         (lambda (_delay _repeat callback)
                           (setq timer callback)))
                        ((symbol-function 'url-retrieve)
                         (lambda (_url callback &rest _)
                           (setq response (generate-new-buffer
                                           " *git-probe-response*"))
                           (when (eq failure 'tls)
                             (with-current-buffer response
                               (funcall callback
                                        '(:error (tls "bad certificate")))))
                           response)))
                (with-selected-window second
                  (emacsos-assist-web-git--command 'files))
                (when (eq failure 'timeout) (funcall timer)))
              (with-current-buffer thread
                (should (equal (plist-get emacsos-assist-web-git--metadata
                                         :branch)
                               "topic/one"))
                (should (equal (plist-get emacsos-assist-web-git--request :id)
                               "stage"))
                (should-not (window-parameter first 'assist-web-git-feedback))
                (should (window-parameter second 'assist-web-git-feedback))
                (make-directory (expand-file-name "staging/stage" cache) t)
                (make-directory (expand-file-name "generations" cache) t)
                (let ((emacsos-assist-web-git-cache-directory cache))
                  (cl-letf (((symbol-function 'emacsos-assist-web-git--open)
                             #'ignore))
                    (emacsos-assist-web-git--promote
                     emacsos-assist-web-git--request
                     (list :thread_oid test-assist-web-git--head
                           :main_oid test-assist-web-git--published))))
                (should-not emacsos-assist-web-git--unavailable)
                (should (string-match-p
                         " current" (emacsos-assist-web-git--thread-header))))
              (should (= (window-parameter first 'assist-web-git-intent) 1))
              (should (= (window-parameter second 'assist-web-git-intent) 2)))
          (when (buffer-live-p response) (kill-buffer response))
          (kill-buffer thread)
          (delete-directory cache t))))))

(ert-deftest test-assist-web-git-metadata-error-tags-separate-thread-and-workspace ()
  (with-temp-buffer
    (setq-local emacsos-assist-web--thread-id "thread-1")
    (let ((snapshot (test-assist-web-git--snapshot "future-state" "topic/one"))
          problem)
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload callback &rest _)
                   (funcall callback snapshot nil))))
        (emacsos-assist-web-git--read-metadata
         (current-buffer) (lambda (_metadata error) (setq problem error))))
      (should (eq (car problem) 'canonical)))
    (let ((snapshot (test-assist-web-git--snapshot "ready" "topic/one"))
          problem)
      (setf (alist-get 'published_revision
                      (alist-get 'workspace (alist-get 'thread snapshot)))
            test-assist-web-git--published)
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload callback &rest _)
                   (funcall callback snapshot nil))))
        (emacsos-assist-web-git--read-metadata
         (current-buffer) (lambda (_metadata error) (setq problem error))))
      (should (eq (car problem) 'git)))))

(ert-deftest test-assist-web-git-dedicated-window-refusal-releases-file-pin ()
  (let* ((root (make-temp-file "assist-git-window-" t))
         (file (expand-file-name "file.txt" root))
         (window (selected-window))
         (original (window-buffer window))
         (dedicated (window-dedicated-p window))
         (thread (generate-new-buffer " *assist-git-window-thread*"))
         (generation (make-emacsos-assist-web-git-generation
                      :path root :oid test-assist-web-git--head))
         (intent (list :action 'files :buffer thread :window window :serial 1)))
    (unwind-protect
        (progn
          (with-temp-file file (insert "worktree content"))
          (set-window-dedicated-p window nil)
          (set-window-buffer window thread)
          (set-window-parameter window 'assist-web-git-intent 1)
          (set-window-dedicated-p window t)
          (cl-letf (((symbol-function 'read-file-name)
                     (lambda (&rest _) file)))
            (should-error (emacsos-assist-web-git--open intent generation)))
          (should (eq (window-buffer window) thread))
          (should-not (emacsos-assist-web-git-generation-views generation)))
      (set-window-dedicated-p window nil)
      (set-window-buffer window original)
      (set-window-dedicated-p window dedicated)
      (set-window-parameter window 'assist-web-git-intent nil)
      (kill-buffer thread)
      (delete-directory root t))))

(ert-deftest test-assist-web-git-active-file-chooser-cannot-open-after-denial ()
  (let* ((root (make-temp-file "assist-git-chooser-denial-" t))
         (file (expand-file-name "file.txt" root))
         (window (selected-window))
         (original (window-buffer window))
         (thread (generate-new-buffer " *assist-git-chooser-thread*"))
         (generation (make-emacsos-assist-web-git-generation
                      :path root :oid test-assist-web-git--head))
         (intent (list :action 'files :buffer thread :window window :serial 1)))
    (unwind-protect
        (progn
          (with-temp-file file (insert "worktree content"))
          (set-window-buffer window thread)
          (set-window-parameter window 'assist-web-git-intent 1)
          (cl-letf (((symbol-function 'read-file-name)
                     (lambda (&rest _)
                       (with-current-buffer thread
                         (emacsos-assist-web-git--canonical-denied 403))
                       file)))
            (should-error (emacsos-assist-web-git--open intent generation)))
          (should-not (emacsos-assist-web-git-generation-views generation))
          (with-current-buffer thread
            (should emacsos-assist-web-git--denied)))
      (set-window-buffer window original)
      (set-window-parameter window 'assist-web-git-intent nil)
      (kill-buffer thread)
      (delete-directory root t))))

(ert-deftest test-assist-web-git-active-file-chooser-cannot-open-during-run-recovery ()
  "A recovery gate raised inside the chooser invalidates its selected file."
  (let* ((root (make-temp-file "assist-git-chooser-recovery-" t))
         (file (expand-file-name "file.txt" root))
         (window (selected-window))
         (original (window-buffer window))
         (thread (generate-new-buffer " *assist-git-recovery-thread*"))
         (generation (make-emacsos-assist-web-git-generation
                      :path root :oid test-assist-web-git--head))
         (intent (list :action 'files :buffer thread :window window :serial 1)))
    (unwind-protect
        (progn
          (with-temp-file file (insert "worktree content"))
          (set-window-buffer window thread)
          (set-window-parameter window 'assist-web-git-intent 1)
          (with-current-buffer thread (emacsos-assist-web-mode))
          (cl-letf (((symbol-function 'read-file-name)
                     (lambda (&rest _)
                       (with-current-buffer thread
                         (emacsos-assist-web--manual-recovery-activate))
                       file)))
            (should-error (emacsos-assist-web-git--open intent generation)))
          (should-not (emacsos-assist-web-git-generation-views generation))
          (with-current-buffer thread
            (should emacsos-assist-web--manual-recovery-required)))
      (set-window-buffer window original)
      (set-window-parameter window 'assist-web-git-intent nil)
      (kill-buffer thread)
      (delete-directory root t))))

(ert-deftest test-assist-web-git-superseded-command-probe-cannot-restore-current ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq-local emacsos-assist-web--thread-id "thread-1")
    (emacsos-assist-web-git--sync-keys)
    (let ((old (test-assist-web-git--metadata
                "ready" "topic/old" test-assist-web-git--head))
          (new (test-assist-web-git--metadata
                "ready" "topic/new" test-assist-web-git--published))
          callback enqueued)
      (cl-letf (((symbol-function 'emacsos-assist-web-git--read-metadata)
                 (lambda (_thread done) (setq callback done)))
                ((symbol-function 'emacsos-assist-web-git--enqueue)
                 (lambda (&rest _) (setq enqueued t))))
        (emacsos-assist-web-git--command 'files)
        (emacsos-assist-web-git--note new)
        (funcall callback old nil)
        (should (equal emacsos-assist-web-git--metadata new))
        (should-not enqueued)
        (emacsos-assist-web-git--command 'files)
        (emacsos-assist-web-git--invalidate "invalid Git workspace metadata")
        (funcall callback old nil)
        (should-not emacsos-assist-web-git--metadata)
        (should-not enqueued)))))

(ert-deftest test-assist-web-git-chat-advance-transfers-live-probe-intent ()
  (save-window-excursion
    (let ((thread (generate-new-buffer " *git-live-probe*"))
          (window (selected-window))
          callback enqueued)
      (unwind-protect
          (progn
            (set-window-buffer window thread)
            (with-current-buffer thread
              (emacsos-assist-web-mode)
              (setq-local emacsos-assist-web--thread-id "thread-1")
              (emacsos-assist-web-git--sync-keys)
              (cl-letf (((symbol-function 'emacsos-assist-web-git--read-metadata)
                         (lambda (_thread done) (setq callback done)))
                        ((symbol-function 'emacsos-assist-web-git--enqueue)
                         (lambda (metadata intent)
                           (setq enqueued (list metadata intent)))))
                (emacsos-assist-web-git--command 'files)
                (should (= (window-parameter window 'assist-web-git-intent)
                           1))
                (emacsos-assist-web-git--note
                 (test-assist-web-git--metadata
                  "ready" "topic/new" test-assist-web-git--published))
                (funcall callback
                         (test-assist-web-git--metadata
                          "ready" "topic/old" test-assist-web-git--head)
                         nil)
                (should (= (window-parameter window 'assist-web-git-intent)
                           1))
                (should (equal (plist-get (car enqueued) :branch)
                               "topic/new"))
                (should (eq (plist-get (cadr enqueued) :window) window)))))
        (kill-buffer thread)))))

(ert-deftest test-assist-web-git-newer-started-command-wins-reverse-completion ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq-local emacsos-assist-web--thread-id "thread-1")
    (emacsos-assist-web-git--sync-keys)
    (let* ((old (test-assist-web-git--metadata
                 "ready" "topic/old" test-assist-web-git--head))
           (new (test-assist-web-git--metadata
                 "ready" "topic/new" test-assist-web-git--published))
           (generation (make-emacsos-assist-web-git-generation
                        :metadata old :state 'current))
           callbacks enqueued)
      (setq-local emacsos-assist-web-git--metadata old
                  emacsos-assist-web-git--current generation)
      (cl-letf (((symbol-function 'emacsos-assist-web-git--read-metadata)
                 (lambda (_thread done) (push done callbacks)))
                ((symbol-function 'emacsos-assist-web-git--intent-live-p)
                 (lambda (intent)
                   (eql (plist-get intent :serial)
                        (window-parameter (plist-get intent :window)
                                          'assist-web-git-intent))))
                ((symbol-function 'emacsos-assist-web-refresh-thread)
                 #'ignore)
                ((symbol-function 'emacsos-assist-web-git--enqueue)
                 (lambda (metadata intent)
                   (setq enqueued (list metadata intent)))))
        (emacsos-assist-web-git--command 'files)
        (emacsos-assist-web-git--command 'diff)
        (let ((newer (car callbacks))
              (older (cadr callbacks)))
          (funcall older old nil)
          (funcall older nil "offline")
          (should (eq (emacsos-assist-web-git-generation-state generation)
                      'current))
          (should (equal emacsos-assist-web-git--metadata old))
          (should-not enqueued)
          (funcall newer new nil)
          (should (equal emacsos-assist-web-git--metadata old))
          (should (equal (plist-get emacsos-assist-web-git--pending :key)
                         (emacsos-assist-web-git--request-key new)))
          (should-not enqueued))))))

(ert-deftest test-assist-web-git-two-window-conflict-commits-one-r2 ()
  (save-window-excursion
    (let* ((thread (generate-new-buffer " *git-two-window-r2*"))
           (first (selected-window))
           (second (split-window-right))
           (old (test-assist-web-git--metadata
                 "ready" "topic/old" test-assist-web-git--head))
           (new (test-assist-web-git--metadata
                 "ready" "topic/new" test-assist-web-git--head))
           probes canonical (starts 0))
      (unwind-protect
          (progn
            (set-window-buffer first thread)
            (set-window-buffer second thread)
            (with-current-buffer thread
              (emacsos-assist-web-mode)
              (setq-local emacsos-assist-web--thread-id "thread-1"
                          emacsos-assist-web-git--metadata old)
              (emacsos-assist-web-git--sync-keys))
            (cl-letf (((symbol-function 'emacsos-assist-web-git--read-metadata)
                       (lambda (_thread done) (push done probes)))
                      ((symbol-function 'emacsos-assist-web--request)
                       (lambda (_method _path _payload done &rest _)
                         (setq canonical done)))
                      ((symbol-function 'emacsos-assist-web--try-write-cache)
                       (lambda (&rest _) t))
                      ((symbol-function 'emacsos-assist-web--render) #'ignore)
                      ((symbol-function 'emacsos-assist-web-git--begin)
                       (lambda (metadata intents)
                         (cl-incf starts)
                         (setq emacsos-assist-web-git--request
                               (list :metadata metadata :intents intents)))))
              (with-selected-window first
                (with-current-buffer thread
                  (emacsos-assist-web-git--command 'files)))
              (funcall (car probes) new nil)
              (with-selected-window second
                (with-current-buffer thread
                  (emacsos-assist-web-git--command 'diff)))
              (with-current-buffer thread
                (should emacsos-assist-web-git--pending)
                (should (equal emacsos-assist-web-git--metadata old))
                (should (= starts 0)))
              (funcall (car probes) old nil)
              (with-current-buffer thread
                (should (= (length (plist-get
                                    emacsos-assist-web-git--pending :intents))
                           2)))
              (funcall canonical
                       (test-assist-web-git--snapshot "ready" "topic/new") nil)
              (with-current-buffer thread
                (should-not emacsos-assist-web-git--pending)
                (should (= starts 1))
                (should (equal (plist-get emacsos-assist-web-git--metadata
                                         :branch)
                               "topic/new"))
                (should (= (length (plist-get
                                    emacsos-assist-web-git--request :intents))
                           2)))))
        (kill-buffer thread)))))

(ert-deftest test-assist-web-git-late-probe-conflict-requires-post-r2-r3 ()
  "A diagnostic branch change after R2 starts needs one later canonical GET."
  (save-window-excursion
    (let* ((thread (generate-new-buffer " *git-late-r2-probe*"))
           (window (selected-window))
           (second (split-window-right))
           (old (test-assist-web-git--metadata
                 "ready" "topic/old" test-assist-web-git--head))
           (new (test-assist-web-git--metadata
                 "ready" "topic/new" test-assist-web-git--head))
           (entry (emacsos-assist-web--entry "done" 'reconciling "key-r2"))
           r2 r3 fetched)
      (unwind-protect
          (progn
            (set-window-buffer window thread)
            (set-window-buffer second thread)
            (set-window-parameter window 'assist-web-git-intent 1)
            (set-window-parameter second 'assist-web-git-intent 1)
            (setf (plist-get entry :run-id) "run-r2"
                  (plist-get entry :verified-outcome) "success")
            (with-current-buffer thread
              (emacsos-assist-web-mode)
              (setq-local emacsos-assist-web--thread-id "thread-1"
                          emacsos-assist-web--queue (list entry)
                          emacsos-assist-web-git--metadata old)
              (cl-letf (((symbol-function 'emacsos-assist-web--request)
                         (lambda (_method _path _payload done &rest _)
                           (if r2 (setq r3 done) (setq r2 done))))
                        ((symbol-function 'emacsos-assist-web--try-write-cache)
                         (lambda (&rest _) t))
                        ((symbol-function 'emacsos-assist-web--save-draft)
                         (lambda () t))
                        ((symbol-function 'emacsos-assist-web--render) #'ignore)
                        ((symbol-function 'emacsos-assist-web-git--begin)
                         (lambda (metadata intents)
                           (setq emacsos-assist-web-git--request
                                 (list :id "post-r2" :epoch emacsos-assist-web-git--epoch
                                       :metadata metadata :intents intents
                                       :cause-at-start
                                       emacsos-assist-web-git--success-watermark))
                           (setq fetched (list metadata intents)))))
                (emacsos-assist-web--reconcile-queue)
                (should r2)
                (emacsos-assist-web-git--route-probe
                 (list :action 'files :buffer thread :window window :serial 1)
                 new nil emacsos-assist-web-git--epoch)
                (should emacsos-assist-web-git--r2-waiting)
                (let ((barrier-epoch emacsos-assist-web-git--epoch))
                  ;; A later old-key C2 diagnostic joins, never fetches H1.
                  (emacsos-assist-web-git--route-probe
                   (list :action 'diff :buffer thread :window second :serial 1)
                   old nil barrier-epoch)
                  (should (= emacsos-assist-web-git--epoch barrier-epoch)))
                (should (= (length (plist-get
                                    emacsos-assist-web-git--r2-waiting :intents))
                           2))
                (should-not fetched)
                (funcall r2 (test-assist-web-git--snapshot
                             "ready" "topic/old") nil)
                (should r3)
                (should-not fetched)
                (should emacsos-assist-web-git--pending)
                (funcall r3 (test-assist-web-git--snapshot
                             "ready" "topic/new") nil)
                (should fetched)
                (should (equal (plist-get (car fetched) :branch) "topic/new"))
                (should (= (length (plist-get
                                    emacsos-assist-web-git--request :intents))
                           2))
                (should-not emacsos-assist-web-git--r2-waiting))))
        (set-window-parameter window 'assist-web-git-intent nil)
        (set-window-parameter second 'assist-web-git-intent nil)
        (kill-buffer thread)))))

(ert-deftest test-assist-web-git-late-final-conflict-keeps-window-intent ()
  "A newer final-read branch cannot be settled by already-started R2."
  (save-window-excursion
    (let* ((thread (generate-new-buffer " *git-late-r2-final*"))
           (window (selected-window))
           (old (test-assist-web-git--metadata
                 "ready" "topic/old" test-assist-web-git--head))
           (new (test-assist-web-git--metadata
                 "ready" "topic/new" test-assist-web-git--head))
           (entry (emacsos-assist-web--entry "done" 'reconciling "key-r2"))
           (intent (list :action 'diff :buffer thread :window window :serial 1))
           (request (list :id "stage-r2" :epoch 0 :metadata old
                          :intents (list intent)))
           r2 r3 final fetched)
      (unwind-protect
          (progn
            (set-window-buffer window thread)
            (set-window-parameter window 'assist-web-git-intent 1)
            (setf (plist-get entry :run-id) "run-r2"
                  (plist-get entry :verified-outcome) "success")
            (with-current-buffer thread
              (emacsos-assist-web-mode)
              (setq-local emacsos-assist-web--thread-id "thread-1"
                          emacsos-assist-web--queue (list entry)
                          emacsos-assist-web-git--metadata old
                          emacsos-assist-web-git--request request)
              (cl-letf (((symbol-function 'emacsos-assist-web--request)
                         (lambda (_method _path _payload done &rest _)
                           (if r2 (setq r3 done) (setq r2 done))))
                        ((symbol-function 'emacsos-assist-web-git--read-metadata)
                         (lambda (_thread done) (setq final done)))
                        ((symbol-function 'emacsos-assist-web-git--cleanup)
                         (lambda (_id _kind done) (funcall done t)))
                        ((symbol-function 'emacsos-assist-web--try-write-cache)
                         (lambda (&rest _) t))
                        ((symbol-function 'emacsos-assist-web--save-draft)
                         (lambda () t))
                        ((symbol-function 'emacsos-assist-web--render) #'ignore)
                        ((symbol-function 'emacsos-assist-web-git--begin)
                         (lambda (metadata intents)
                           (setq fetched (list metadata intents)))))
                (emacsos-assist-web--reconcile-queue)
                (emacsos-assist-web-git--final-check
                 request (list :thread_oid test-assist-web-git--head))
                (should final)
                (funcall final new nil)
                (should emacsos-assist-web-git--r2-waiting)
                (should-not fetched)
                (funcall r2 (test-assist-web-git--snapshot
                             "ready" "topic/old") nil)
                (should r3)
                (should-not fetched)
                (funcall r3 (test-assist-web-git--snapshot
                             "ready" "topic/new") nil)
                (should (equal (cadr fetched) (list intent))))))
        (set-window-parameter window 'assist-web-git-intent nil)
        (kill-buffer thread)))))

(ert-deftest test-assist-web-git-late-r2-failure-releases-window ()
  "Neither failed R2 nor failed post-barrier R3 can strand its window."
  (dolist (failed-step '(r2 r3))
    (save-window-excursion
      (let* ((thread (generate-new-buffer " *git-late-r2-fail*"))
             (window (selected-window))
             (old (test-assist-web-git--metadata
                   "ready" "topic/old" test-assist-web-git--head))
             (new (test-assist-web-git--metadata
                   "ready" "topic/new" test-assist-web-git--head))
             (entry (emacsos-assist-web--entry "done" 'reconciling "key-r2"))
             r2 r3 fetched)
        (unwind-protect
            (progn
              (set-window-buffer window thread)
              (set-window-parameter window 'assist-web-git-intent 1)
              (setf (plist-get entry :run-id) "run-r2"
                    (plist-get entry :verified-outcome) "success")
              (with-current-buffer thread
                (emacsos-assist-web-mode)
                (setq-local emacsos-assist-web--thread-id "thread-1"
                            emacsos-assist-web--queue (list entry)
                            emacsos-assist-web-git--metadata old)
                (cl-letf (((symbol-function 'emacsos-assist-web--request)
                           (lambda (_method _path _payload done &rest _)
                             (if r2 (setq r3 done) (setq r2 done))))
                          ((symbol-function 'emacsos-assist-web--try-write-cache)
                           (lambda (&rest _) t))
                          ((symbol-function 'emacsos-assist-web--save-draft)
                           (lambda () t))
                          ((symbol-function 'emacsos-assist-web--render) #'ignore)
                          ((symbol-function 'emacsos-assist-web-git--begin)
                           (lambda (&rest _) (setq fetched t))))
                  (emacsos-assist-web--reconcile-queue)
                  (emacsos-assist-web-git--route-probe
                   (list :action 'files :buffer thread :window window :serial 1)
                   new nil emacsos-assist-web-git--epoch)
                  (if (eq failed-step 'r2)
                      (funcall r2 nil "offline")
                    (funcall r2 (test-assist-web-git--snapshot
                                 "ready" "topic/old") nil)
                    (should r3)
                    (funcall r3 nil "offline"))
                  (should-not fetched)
                  (should-not emacsos-assist-web-git--r2-waiting)
                  (should-not emacsos-assist-web-git--pending)
                  (should (> (window-parameter window 'assist-web-git-intent)
                             1)))))
          (set-window-parameter window 'assist-web-git-intent nil)
          (kill-buffer thread))))))

(ert-deftest test-assist-web-git-stale-r2-releases-only-its-late-intent ()
  "A superseded R2 cannot leave its diagnostic window waiting forever."
  (save-window-excursion
    (let* ((thread (generate-new-buffer " *git-stale-r2-intent*"))
           (window (selected-window))
           (old (test-assist-web-git--metadata
                 "ready" "topic/old" test-assist-web-git--head))
           (new (test-assist-web-git--metadata
                 "ready" "topic/new" test-assist-web-git--head))
           (entry (emacsos-assist-web--entry "done" 'reconciling "key-r2"))
           r2 (requests 0))
      (unwind-protect
          (progn
            (set-window-buffer window thread)
            (set-window-parameter window 'assist-web-git-intent 1)
            (setf (plist-get entry :run-id) "run-r2"
                  (plist-get entry :verified-outcome) "success")
            (with-current-buffer thread
              (emacsos-assist-web-mode)
              (setq-local emacsos-assist-web--thread-id "thread-1"
                          emacsos-assist-web--queue (list entry)
                          emacsos-assist-web-git--metadata old)
              (cl-letf (((symbol-function 'emacsos-assist-web--request)
                         (lambda (_method _path _payload done &rest _)
                           (cl-incf requests)
                           (setq r2 done))))
                (emacsos-assist-web--reconcile-queue)
                (emacsos-assist-web-git--route-probe
                 (list :action 'files :buffer thread :window window :serial 1)
                 new nil emacsos-assist-web-git--epoch)
                (should emacsos-assist-web-git--r2-waiting)
                (setq emacsos-assist-web--reconcile-generation 999)
                (funcall r2 (test-assist-web-git--snapshot
                             "ready" "topic/old") nil)
                (should-not emacsos-assist-web-git--r2-waiting)
                (should (= requests 1))
                (should (= (window-parameter window 'assist-web-git-intent) 2)))))
        (set-window-parameter window 'assist-web-git-intent nil)
        (kill-buffer thread)))))

(ert-deftest test-assist-web-git-new-conflict-supersedes-old-canonical-r1 ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq-local emacsos-assist-web--thread-id "thread-1")
    (let* ((old (test-assist-web-git--metadata
                 "ready" "topic/old" test-assist-web-git--head))
           (middle (test-assist-web-git--metadata
                    "ready" "topic/middle" test-assist-web-git--head))
           (new (test-assist-web-git--metadata
                 "ready" "topic/new" test-assist-web-git--head))
           callbacks (starts 0))
      (setq-local emacsos-assist-web-git--metadata old)
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload done &rest _)
                   (push done callbacks)))
                ((symbol-function 'emacsos-assist-web--try-write-cache)
                 (lambda (&rest _) t))
                ((symbol-function 'emacsos-assist-web--render) #'ignore)
                ((symbol-function 'emacsos-assist-web-git--begin)
                 (lambda (&rest _) (cl-incf starts))))
        (emacsos-assist-web-git--conflict middle nil)
        (let ((r1 (car callbacks)))
          (emacsos-assist-web-git--conflict new nil)
          (let ((r2 (car callbacks)))
            (should (= (length callbacks) 2))
            (funcall r1
                     (test-assist-web-git--snapshot "ready" "topic/middle")
                     nil)
            (should (equal emacsos-assist-web-git--metadata old))
            (should (equal (plist-get emacsos-assist-web-git--pending :key)
                           (emacsos-assist-web-git--request-key new)))
            (funcall r2
                     (test-assist-web-git--snapshot "ready" "topic/new") nil)
            (should-not emacsos-assist-web-git--pending)
            (should (equal (plist-get emacsos-assist-web-git--metadata
                                     :branch)
                           "topic/new"))
            (should (= starts 1))))))))

(ert-deftest test-assist-web-git-older-final-mismatch-cannot-replace-new-probe ()
  (save-window-excursion
    (let* ((thread (generate-new-buffer " *git-stale-final*"))
           (first (selected-window))
           (second (split-window-right))
           (old (test-assist-web-git--metadata
                 "ready" "topic/old" test-assist-web-git--head))
           (middle (test-assist-web-git--metadata
                    "ready" "topic/middle" test-assist-web-git--head))
           (new (test-assist-web-git--metadata
                 "ready" "topic/new" test-assist-web-git--head))
           (request (list :id "stage" :epoch 0 :metadata old :process nil
                          :intents nil))
           final-callback command-callback canonical promoted started)
      (unwind-protect
          (progn
            (set-window-buffer first thread)
            (set-window-buffer second thread)
            (set-window-parameter first 'assist-web-git-intent 1)
            (with-current-buffer thread
              (emacsos-assist-web-mode)
              (setq-local emacsos-assist-web--thread-id "thread-1"
                          emacsos-assist-web-git--metadata old
                          emacsos-assist-web-git--request request)
              (emacsos-assist-web-git--sync-keys)
              (emacsos-assist-web-git--request-put
               request :intents
               (list (list :action 'files :buffer thread
                           :window first :serial 1))))
            (cl-letf (((symbol-function 'emacsos-assist-web-git--read-metadata)
                       (lambda (_thread done)
                         (if final-callback
                             (setq command-callback done)
                           (setq final-callback done))))
                      ((symbol-function 'emacsos-assist-web-git--cleanup)
                       (lambda (_id _kind done) (funcall done t)))
                      ((symbol-function 'emacsos-assist-web--request)
                       (lambda (_method _path _payload done &rest _)
                         (setq canonical done)))
                      ((symbol-function 'emacsos-assist-web--try-write-cache)
                       (lambda (&rest _) t))
                      ((symbol-function 'emacsos-assist-web--render) #'ignore)
                      ((symbol-function 'emacsos-assist-web-git--promote)
                       (lambda (&rest _) (setq promoted t)))
                      ((symbol-function 'emacsos-assist-web-git--begin)
                       (lambda (metadata intents)
                         (setq started t
                               emacsos-assist-web-git--request
                               (list :metadata metadata :intents intents)))))
              (with-current-buffer thread
                (emacsos-assist-web-git--final-check
                 request (list :thread_oid test-assist-web-git--head)))
              (with-selected-window second
                (with-current-buffer thread
                  (emacsos-assist-web-git--command 'diff)))
              (funcall final-callback middle nil)
              (with-current-buffer thread
                (should-not emacsos-assist-web-git--pending)
                (should (equal emacsos-assist-web-git--metadata old))
                (should-not promoted))
              (funcall command-callback new nil)
              (with-current-buffer thread
                (should (equal (plist-get emacsos-assist-web-git--pending :key)
                               (emacsos-assist-web-git--request-key new)))
                (should (= (length (plist-get
                                    emacsos-assist-web-git--pending :intents))
                           2))
                (should-not promoted))
              (funcall canonical
                       (test-assist-web-git--snapshot "ready" "topic/new") nil)
              (should started)
              (with-current-buffer thread
                (should (= (length (plist-get
                                    emacsos-assist-web-git--request :intents))
                           2)))))
        (kill-buffer thread)))))

(ert-deftest test-assist-web-git-queue-r2-failure-does-not-promote ()
  (dolist (failure '(cache retirement))
    (save-window-excursion
      (let* ((thread (generate-new-buffer " *git-queue-r2-failure*"))
             (first (selected-window))
             (second (split-window-right))
             (old (test-assist-web-git--metadata
                   "ready" "topic/old" test-assist-web-git--head))
             (new (test-assist-web-git--metadata
                   "ready" "topic/new" test-assist-web-git--head))
             canonical started)
        (unwind-protect
            (progn
              (set-window-buffer first thread)
              (set-window-buffer second thread)
              (set-window-parameter first 'assist-web-git-intent 1)
              (set-window-parameter second 'assist-web-git-intent 1)
              (with-current-buffer thread
                (emacsos-assist-web-mode)
                (setq-local
                 emacsos-assist-web--thread-id "thread-1"
                 emacsos-assist-web--queue
                 (list (emacsos-assist-web--entry
                        "fixture" 'reconciling "exact-key"))
                 emacsos-assist-web-git--metadata old
                 emacsos-assist-web-git--epoch 1
                 emacsos-assist-web-git--pending
                 (list :key (emacsos-assist-web-git--request-key new)
                       :epoch 1 :request nil :requires-durable t
                       :intents
                       (list (list :action 'files :buffer thread
                                   :window first :serial 1)
                             (list :action 'diff :buffer thread
                                   :window second :serial 1)))))
              (cl-letf (((symbol-function 'emacsos-assist-web--request)
                         (lambda (_method _path _payload done &rest _)
                           (setq canonical done)))
                        ((symbol-function 'emacsos-assist-web--try-write-cache)
                         (lambda (&rest _) (eq failure 'retirement)))
                        ((symbol-function 'emacsos-assist-web--save-draft)
                         (lambda () (eq failure 'cache)))
                        ((symbol-function 'emacsos-assist-web-git--begin)
                         (lambda (&rest _) (setq started t))))
                (with-current-buffer thread
                  (emacsos-assist-web--reconcile-queue))
                (funcall canonical
                         (test-assist-web-git--snapshot "ready" "topic/new")
                         nil))
              (with-current-buffer thread
                (should-not started)
                (should-not emacsos-assist-web-git--pending)
                (should-not emacsos-assist-web-git--metadata)
                (should (eq (and emacsos-assist-web--reconcile-recovery-paused t)
                            (eq failure 'retirement)))
                (should (= (window-parameter first 'assist-web-git-intent) 2))
                (should (= (window-parameter second 'assist-web-git-intent) 2))
                (dolist (window (list first second))
                  (let ((header (window-parameter
                                 window 'assist-web-git-feedback)))
                    (should header)
                    (should (string-match-p
                             (if (eq failure 'retirement)
                                 (regexp-quote "Restart to recover [?]")
                               "Run recovery pending.*Refresh")
                             (eval (cadr header) t)))))))
          (kill-buffer thread))))))

(ert-deftest test-assist-web-git-manual-refresh-joins-queue-r2 ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let ((entry (emacsos-assist-web--entry
                  "fixture" 'reconciling "exact-key"))
          callbacks fetched rendered)
      (setf (plist-get entry :run-id) "run-1"
            (plist-get entry :verified-outcome) "success")
      (setq-local emacsos-assist-web--thread-id "thread-1"
                  emacsos-assist-web--queue (list entry))
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload done &rest _)
                   (push done callbacks)))
                ((symbol-function 'emacsos-assist-web--try-write-cache)
                 (lambda (&rest _) t))
                ((symbol-function 'emacsos-assist-web--save-draft)
                 (lambda () t))
                ((symbol-function 'emacsos-assist-web--render)
                 (lambda (value &rest _) (setq rendered value)))
                ((symbol-function 'emacsos-assist-web-git--begin)
                 (lambda (&rest _) (setq fetched t))))
        (emacsos-assist-web--reconcile-queue)
        (let ((generation emacsos-assist-web--refresh-generation))
          (emacsos-assist-web-refresh-thread (current-buffer))
          (should (= generation emacsos-assist-web--refresh-generation))
          (should (= (length callbacks) 1)))
        (let ((snapshot (test-assist-web-git--snapshot
                         "ready" "topic/one")))
          (funcall (car callbacks) snapshot nil)
          (should (eq rendered snapshot))
          (should-not emacsos-assist-web--queue)
          (should-not emacsos-assist-web--reconcile-generation)
          (should fetched))))))

(ert-deftest test-assist-web-git-postcommit-display-failure-keeps-retirement ()
  (dolist (failure '(render surface quit))
    (save-window-excursion
      (let* ((thread (generate-new-buffer " *git-postcommit-display*"))
             (window (selected-window))
             (entry (emacsos-assist-web--entry
                     "fixture" 'reconciling "exact-key"))
             (old (test-assist-web-git--metadata
                   "ready" "topic/old" test-assist-web-git--head))
             (generation (make-emacsos-assist-web-git-generation
                          :metadata old :state 'current))
             (snapshot (test-assist-web-git--snapshot
                        "ready" "topic/new"))
             callbacks saved fetched)
        (setf (plist-get entry :run-id) "run-1"
              (plist-get entry :verified-outcome) "success")
        (unwind-protect
            (progn
              (set-window-buffer window thread)
              (with-current-buffer thread
                (emacsos-assist-web-mode)
                (setq-local emacsos-assist-web--thread-id "thread-1"
                            emacsos-assist-web--queue (list entry)
                            emacsos-assist-web--manual-recovery-required t
                            emacsos-assist-web--manual-recovery-active t
                            emacsos-assist-web-git--metadata old
                            emacsos-assist-web-git--current generation)
                (emacsos-assist-web-git--sync-keys)
                (cl-letf (((symbol-function 'emacsos-assist-web--request)
                           (lambda (_method path _payload done &rest _)
                             (push (cons path done) callbacks)))
                          ((symbol-function 'emacsos-assist-web--try-write-cache)
                           (lambda (&rest _) t))
                          ((symbol-function 'emacsos-assist-web--save-draft)
                           (lambda ()
                             (setq saved (null emacsos-assist-web--queue))
                             t))
                          ((symbol-function 'emacsos-assist-web--render)
                           (lambda (&rest _)
                             (when (eq failure 'quit)
                               (signal 'quit nil))
                             (when (eq failure 'render)
                               (setq emacsos-assist-web--status-start nil
                                     emacsos-assist-web--status-end nil)
                               (error "render failed"))))
                          ((symbol-function 'emacsos-assist-web--sync-active-surface)
                           (lambda ()
                             (when (eq failure 'surface)
                               (error "surface failed"))))
                          ((symbol-function 'emacsos-assist-web-git--begin)
                           (lambda (&rest _) (setq fetched t))))
                  (emacsos-assist-web--reconcile-queue)
                  (funcall (cdar callbacks) snapshot nil)
                  (should saved)
                  (should-not emacsos-assist-web--queue)
                  (should-not emacsos-assist-web--manual-recovery-required)
                  (should-not emacsos-assist-web--manual-recovery-active)
                  (should (eq emacsos-assist-web--snapshot snapshot))
                  (should emacsos-assist-web--display-recovery)
                  (should (equal (plist-get emacsos-assist-web-git--metadata
                                           :branch)
                                 "topic/new"))
                  (should-not (equal
                               (emacsos-assist-web-git--view-state
                                generation thread)
                               "current"))
                  (should fetched)
                  (should (string-prefix-p
                           "Saved; Refresh"
                           (emacsos-assist-web-git--thread-header)))
                  (let ((header (emacsos-assist-web-git--thread-header)))
                    (should (equal (get-text-property (- (length header) 5)
                                                      'display header)
                                   '(space :width (20) :height (40))))
                    (should (equal (get-text-property (1- (length header))
                                                      'display header)
                                   '(space :width (20) :height (40))))
                    (should (eq (lookup-key
                                 emacsos-assist-web-git-thread-mode-map
                                 (kbd "C-c ?"))
                                #'emacsos-assist-web-git-details)))
                  (emacsos-assist-web-git-details)
                  (should (string-match-p
                           "exact Run retirement was saved"
                           (buffer-string)))
                  (emacsos-assist-web-git-display-details-back)
                  (should (eq (window-buffer window) thread))
                  (emacsos-assist-web-refresh-thread thread)
                  (should (= (length callbacks) 2))
                  (should-not (string-match-p
                               "/runs/"
                               (caar callbacks))))))
          (when (buffer-live-p thread) (kill-buffer thread)))))))

(ert-deftest test-assist-web-git-postcommit-note-quit-keeps-retirement ()
  "Optional Git projection quit cannot undo a durably retired queue Run."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let ((entry (emacsos-assist-web--entry
                  "fixture" 'reconciling "exact-key"))
          callback)
      (setf (plist-get entry :run-id) "run-1"
            (plist-get entry :verified-outcome) "success")
      (setq-local emacsos-assist-web--thread-id "thread-1"
                  emacsos-assist-web--queue (list entry))
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload done &rest _)
                   (setq callback done)))
                ((symbol-function 'emacsos-assist-web--try-write-cache)
                 (lambda (&rest _) t))
                ((symbol-function 'emacsos-assist-web--save-draft)
                 (lambda () t))
                ((symbol-function 'emacsos-assist-web-git--note-snapshot)
                 (lambda (&rest _) (signal 'quit nil)))
                ((symbol-function 'emacsos-assist-web--render)
                 (lambda (&rest _) nil)))
        (emacsos-assist-web--reconcile-queue)
        (funcall callback
                 (test-assist-web-git--snapshot "ready" "topic/new") nil)
        (should-not emacsos-assist-web--queue)
        (should-not emacsos-assist-web--reconcile-generation)
        (should-not emacsos-assist-web-git--metadata)
        (should (string-match-p "Git state unavailable"
                                emacsos-assist-web-git--unavailable))))))

(ert-deftest test-assist-web-git-postcommit-stopped-clear-quit-keeps-retirement ()
  "A C-g while clearing stopped currentness cannot resurrect a retired Run."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let ((entry (emacsos-assist-web--entry
                  "fixture" 'reconciling "exact-key"))
          callback)
      (setf (plist-get entry :run-id) "run-1"
            (plist-get entry :verified-outcome) "success")
      (setq-local emacsos-assist-web--thread-id "thread-1"
                  emacsos-assist-web--queue (list entry)
                  emacsos-assist-web-git--stopped-reobserve
                  (list :tid "thread-1" :run-id "run-1" :entry entry))
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload done &rest _)
                   (setq callback done)))
                ((symbol-function 'emacsos-assist-web--try-write-cache)
                 (lambda (&rest _) t))
                ((symbol-function 'emacsos-assist-web--save-draft)
                 (lambda () t))
                ((symbol-function 'emacsos-assist-web-git--update-headers)
                 (lambda () (signal 'quit nil)))
                ((symbol-function 'emacsos-assist-web--render)
                 (lambda (&rest _) nil)))
        (emacsos-assist-web--reconcile-queue)
        (funcall callback
                 (test-assist-web-git--snapshot "ready" "topic/new") nil)
        (should-not emacsos-assist-web--queue)
        (should-not emacsos-assist-web-git--stopped-reobserve)))))

(ert-deftest test-assist-web-git-r2-exact-failure-preserves-unchanged-current ()
  "A failed Run is not a freshness event or a reason to erase verified H1."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let* ((metadata (test-assist-web-git--metadata
                      "ready" "topic/old" test-assist-web-git--head))
           (generation (make-emacsos-assist-web-git-generation
                        :metadata metadata :state 'current))
           (entry (emacsos-assist-web--entry "F" 'reconciling "key-f"))
           fetched)
      (setf (plist-get entry :run-id) "run-f"
            (plist-get entry :verified-outcome) "error")
      (setq-local emacsos-assist-web--thread-id "thread-1"
                  emacsos-assist-web--queue (list entry)
                  emacsos-assist-web-git--metadata metadata
                  emacsos-assist-web-git--current generation)
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload done &rest _)
                   (funcall done
                            (test-assist-web-git--snapshot "ready" "topic/old")
                            nil)))
                ((symbol-function 'emacsos-assist-web--try-write-cache)
                 (lambda (&rest _) t))
                ((symbol-function 'emacsos-assist-web--save-draft)
                 (lambda () t))
                ((symbol-function 'emacsos-assist-web--render) #'ignore)
                ((symbol-function 'emacsos-assist-web-git--begin)
                 (lambda (&rest _) (setq fetched t))))
        (emacsos-assist-web--reconcile-queue))
      (should-not fetched)
      (should-not emacsos-assist-web--queue)
      (should (eq (emacsos-assist-web-git-generation-state generation)
                  'current)))))

(ert-deftest test-assist-web-git-r2-mixed-outcomes-fetches-on-success ()
  "A mixed terminal batch emits one success refresh, not one per Run."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let ((success (emacsos-assist-web--entry "S" 'reconciling "key-s"))
          (failure (emacsos-assist-web--entry "F" 'reconciling "key-f"))
          (fetched 0))
      (setf (plist-get success :run-id) "run-s"
            (plist-get success :verified-outcome) "success"
            (plist-get failure :run-id) "run-f"
            (plist-get failure :verified-outcome) "error")
      (setq-local emacsos-assist-web--thread-id "thread-1"
                  emacsos-assist-web--queue (list success failure))
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload done &rest _)
                   (funcall done
                            (test-assist-web-git--snapshot "ready" "topic/new")
                            nil)))
                ((symbol-function 'emacsos-assist-web--try-write-cache)
                 (lambda (&rest _) t))
                ((symbol-function 'emacsos-assist-web--save-draft)
                 (lambda () t))
                ((symbol-function 'emacsos-assist-web--render) #'ignore)
                ((symbol-function 'emacsos-assist-web-git--begin)
                 (lambda (&rest _) (cl-incf fetched))))
        (emacsos-assist-web--reconcile-queue))
      (should (= fetched 1))
      (should-not emacsos-assist-web--queue))))

(ert-deftest test-assist-web-git-noop-success-supersedes-pre-cause-fetch ()
  "An active H1 fetch cannot satisfy S even when S publishes the same H1."
  (save-window-excursion
    (let* ((thread (generate-new-buffer " *git-post-cause*"))
           (first (selected-window))
           (second (split-window-right))
           (metadata (test-assist-web-git--metadata
                      "ready" "topic/old" test-assist-web-git--head))
           (generation (make-emacsos-assist-web-git-generation
                        :metadata metadata :state 'current))
           (i1 (list :action 'files :buffer thread :window first :serial 1))
           (i2 (list :action 'diff :buffer thread :window second :serial 1))
           (request (list :id "pre-s" :epoch 0 :metadata metadata
                          :cause-at-start 0 :intents (list i1 i2)))
           (entry (emacsos-assist-web--entry "S" 'reconciling "key-s"))
           cleanup successor)
      (unwind-protect
          (progn
            (set-window-buffer first thread)
            (set-window-buffer second thread)
            (set-window-parameter first 'assist-web-git-intent 1)
            (set-window-parameter second 'assist-web-git-intent 1)
            (setf (plist-get entry :run-id) "run-s"
                  (plist-get entry :verified-outcome) "success")
            (with-current-buffer thread
              (emacsos-assist-web-mode)
              (setq-local emacsos-assist-web--thread-id "thread-1"
                          emacsos-assist-web--queue (list entry)
                          emacsos-assist-web-git--metadata metadata
                          emacsos-assist-web-git--current generation
                          emacsos-assist-web-git--request request)
              (cl-letf (((symbol-function 'emacsos-assist-web--request)
                         (lambda (_method _path _payload done &rest _)
                           (funcall done
                                    (test-assist-web-git--snapshot
                                     "ready" "topic/old") nil)))
                        ((symbol-function 'emacsos-assist-web--try-write-cache)
                         (lambda (&rest _) t))
                        ((symbol-function 'emacsos-assist-web--save-draft)
                         (lambda () t))
                        ((symbol-function 'emacsos-assist-web--render) #'ignore)
                        ((symbol-function 'emacsos-assist-web-git--cleanup)
                         (lambda (_id _kind done) (setq cleanup done)))
                        ((symbol-function 'emacsos-assist-web-git--begin)
                         (lambda (next intents)
                           (setq successor (list next intents)))))
                (emacsos-assist-web--reconcile-queue)
                (should (= emacsos-assist-web-git--success-watermark 1))
                (should (eq (emacsos-assist-web-git-generation-state generation)
                            'cached))
                (should-not cleanup)
                (should-not successor)
                (should (eq emacsos-assist-web-git--request request))
                (should-not (plist-get request :intents))
                (should (equal (cadr emacsos-assist-web-git--next)
                               (list i1 i2)))
                ;; The older same-key transfer is allowed to finish; only
                ;; its final cleanup makes the post-success fetch eligible.
                (emacsos-assist-web-git--finish-obsolete request)
                (should cleanup)
                (funcall cleanup t)
                (should (equal (emacsos-assist-web-git--request-key
                                (car successor))
                               (emacsos-assist-web-git--request-key
                                metadata)))
                (should (equal (cadr successor) (list i1 i2))))))
        (kill-buffer thread)))))

(ert-deftest test-assist-web-git-pre-cause-final-cannot-install ()
  "An already verified final read cannot install after a newer Run success."
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let* ((metadata (test-assist-web-git--metadata
                      "ready" "topic/old" test-assist-web-git--head))
           (request (list :id "stage-before-success" :epoch 0
                          :verified-epoch 0 :cause-at-start 0
                          :metadata metadata :intents nil))
           successor)
      (setq-local emacsos-assist-web-git--metadata metadata
                  emacsos-assist-web-git--request request
                  emacsos-assist-web-git--next (list metadata nil)
                  emacsos-assist-web-git--success-watermark 1)
      (cl-letf (((symbol-function 'emacsos-assist-web-git--cleanup)
                 (lambda (_id _kind done) (funcall done t)))
                ((symbol-function 'emacsos-assist-web-git--begin)
                 (lambda (next intents)
                   (setq successor (list next intents)))))
        (emacsos-assist-web-git--promote
         request (list :thread_oid test-assist-web-git--head
                       :main_oid test-assist-web-git--head)))
      (should successor)
      (should-not emacsos-assist-web-git--current)
      (should-not emacsos-assist-web-git--request))))

(ert-deftest test-assist-web-git-successor-cleanup-failure-releases-windows ()
  "Both cancel and stale-helper cleanup failures release moved W1/W2 intents."
  (dolist (path '(cancel stale-helper))
    (save-window-excursion
      (let* ((thread (generate-new-buffer " *git-successor-cleanup*"))
             (first (selected-window))
             (second (split-window-right))
             (metadata (test-assist-web-git--metadata
                        "ready" "topic/old" test-assist-web-git--head))
             (i1 (list :action 'files :buffer thread :window first :serial 1))
             (i2 (list :action 'diff :buffer thread :window second :serial 1))
             helper cleanup)
        (unwind-protect
            (progn
              (set-window-buffer first thread)
              (set-window-buffer second thread)
              (set-window-parameter first 'assist-web-git-intent 1)
              (set-window-parameter second 'assist-web-git-intent 1)
              (with-current-buffer thread
                (emacsos-assist-web-mode)
                (setq-local emacsos-assist-web--thread-id "thread-1"
                            emacsos-assist-web-git--metadata metadata)
                (cl-letf (((symbol-function 'emacsos-assist-web-git--spawn)
                           (lambda (_payload done)
                             (setq helper done)
                             nil))
                          ((symbol-function 'emacsos-assist-web-git--cleanup)
                           (lambda (_id _kind done) (setq cleanup done))))
                  (emacsos-assist-web-git--begin metadata nil)
                  (setq emacsos-assist-web-git--next
                        (list metadata (list i1 i2)))
                  (if (eq path 'cancel)
                      (emacsos-assist-web-git--cancel)
                    (setq emacsos-assist-web-git--canceling
                          (plist-get emacsos-assist-web-git--request :id)
                          emacsos-assist-web-git--request nil)
                    (funcall helper (list :ok nil :reason "cancelled")))
                  (should cleanup)
                  (funcall cleanup nil)
                  (should-not emacsos-assist-web-git--next)
                  (should (= (window-parameter first 'assist-web-git-intent) 2))
                  (should (= (window-parameter second 'assist-web-git-intent) 2))
                  (should (string-match-p "mirror cleanup failed"
                                          emacsos-assist-web-git--unavailable)))))
          (set-window-parameter first 'assist-web-git-intent nil)
          (set-window-parameter second 'assist-web-git-intent nil)
          (kill-buffer thread))))))

(ert-deftest test-assist-web-git-post-cause-successor-waits-for-old-helper ()
  "A no-op success leaves its older fetch alive but not promotable."
  (save-window-excursion
    (let* ((thread (generate-new-buffer " *git-natural-successor*"))
           (first (selected-window))
           (second (split-window-right))
           (metadata (test-assist-web-git--metadata
                      "ready" "topic/old" test-assist-web-git--head))
           (i1 (list :action 'files :buffer thread :window first :serial 1))
           (i2 (list :action 'diff :buffer thread :window second :serial 1))
           callbacks cleanup)
      (unwind-protect
          (progn
            (set-window-buffer first thread)
            (set-window-buffer second thread)
            (set-window-parameter first 'assist-web-git-intent 1)
            (set-window-parameter second 'assist-web-git-intent 1)
            (with-current-buffer thread
              (emacsos-assist-web-mode)
              (setq-local emacsos-assist-web--thread-id "thread-1"
                          emacsos-assist-web-git--metadata metadata)
              (cl-letf (((symbol-function 'emacsos-assist-web-git--spawn)
                         (lambda (_payload done) (push done callbacks) nil))
                        ((symbol-function 'emacsos-assist-web-git--cleanup)
                         (lambda (_id _kind done) (setq cleanup done)))
                        ((symbol-function 'emacsos-assist-web-git--final-check)
                         (lambda (&rest _) (ert-fail "old final read ran"))))
                (emacsos-assist-web-git--begin metadata (list i1))
                (let ((old-request emacsos-assist-web-git--request)
                      (old-helper (car callbacks)))
                  (setq emacsos-assist-web-git--success-watermark 1)
                  (emacsos-assist-web-git--enqueue metadata i2)
                  (should (eq old-request emacsos-assist-web-git--request))
                  (should (= (length callbacks) 1))
                  (should-not (plist-get old-request :intents))
                  (should (equal (cadr emacsos-assist-web-git--next)
                                 (list i1 i2)))
                  (funcall old-helper (list :ok t))
                  (should cleanup)
                  (should (= (length callbacks) 1))
                  (funcall cleanup t)
                  (should (= (length callbacks) 2))
                  (should (= (plist-get emacsos-assist-web-git--request
                                         :cause-at-start) 1))
                  (should (equal (plist-get emacsos-assist-web-git--request
                                            :intents)
                                 (list i1 i2)))))))
        (set-window-parameter first 'assist-web-git-intent nil)
        (set-window-parameter second 'assist-web-git-intent nil)
        (kill-buffer thread)))))

(ert-deftest test-assist-web-git-post-cause-successor-after-old-helper-failure ()
  "A failed pre-cause helper still cleans before starting the successor."
  (dolist (cleanup-ok '(t nil))
    (save-window-excursion
      (let* ((thread (generate-new-buffer " *git-failed-successor*"))
             (first (selected-window))
             (second (split-window-right))
             (metadata (test-assist-web-git--metadata
                        "ready" "topic/old" test-assist-web-git--head))
             (i1 (list :action 'files :buffer thread :window first :serial 1))
             (i2 (list :action 'diff :buffer thread :window second :serial 1))
             helpers cleanup)
        (unwind-protect
            (progn
              (set-window-buffer first thread)
              (set-window-buffer second thread)
              (set-window-parameter first 'assist-web-git-intent 1)
              (set-window-parameter second 'assist-web-git-intent 1)
              (with-current-buffer thread
                (emacsos-assist-web-mode)
                (setq-local emacsos-assist-web--thread-id "thread-1"
                            emacsos-assist-web-git--metadata metadata)
                (cl-letf (((symbol-function 'emacsos-assist-web-git--spawn)
                           (lambda (_payload done) (push done helpers) nil))
                          ((symbol-function 'emacsos-assist-web-git--cleanup)
                           (lambda (_id _kind done) (setq cleanup done))))
                  (emacsos-assist-web-git--begin metadata (list i1))
                  (funcall (car helpers) (list :ok nil :reason "fetch failed"))
                  (should cleanup)
                  (setq emacsos-assist-web-git--success-watermark 1)
                  (emacsos-assist-web-git--enqueue metadata i2)
                  (should (equal (cadr emacsos-assist-web-git--next)
                                 (list i1 i2)))
                  (funcall cleanup cleanup-ok)
                  (if cleanup-ok
                      (progn
                        (should (= (length helpers) 2))
                        (should-not emacsos-assist-web-git--next)
                        (should (equal
                                 (plist-get emacsos-assist-web-git--request
                                            :intents)
                                 (list i1 i2))))
                    (should-not emacsos-assist-web-git--next)
                    (should (= (window-parameter first 'assist-web-git-intent)
                               2))
                    (should (= (window-parameter second 'assist-web-git-intent)
                               2))
                    (should (string-match-p "mirror cleanup failed"
                                            emacsos-assist-web-git--unavailable))))))
          (set-window-parameter first 'assist-web-git-intent nil)
          (set-window-parameter second 'assist-web-git-intent nil)
          (kill-buffer thread))))))

(ert-deftest test-assist-web-git-failed-helper-cleanup-launch-error-releases-both ()
  "A synchronous cleanup launch error cannot strand successor intents."
  (save-window-excursion
    (let* ((thread (generate-new-buffer " *git-cleanup-launch*"))
           (first (selected-window))
           (second (split-window-right))
           (metadata (test-assist-web-git--metadata
                      "ready" "topic/old" test-assist-web-git--head))
           (i1 (list :action 'files :buffer thread :window first :serial 1))
           (i2 (list :action 'diff :buffer thread :window second :serial 1))
           helper (cleanup-calls 0))
      (unwind-protect
          (progn
            (set-window-buffer first thread)
            (set-window-buffer second thread)
            (set-window-parameter first 'assist-web-git-intent 1)
            (set-window-parameter second 'assist-web-git-intent 1)
            (with-current-buffer thread
              (emacsos-assist-web-mode)
              (setq-local emacsos-assist-web--thread-id "thread-1"
                          emacsos-assist-web-git--metadata metadata)
              (cl-letf (((symbol-function 'emacsos-assist-web-git--spawn)
                         (lambda (_payload done) (setq helper done) nil))
                        ((symbol-function 'emacsos-assist-web-git--cleanup)
                         (lambda (&rest _)
                           ;; Model an exact success accepted while cleanup
                           ;; launch is in progress, then a failed spawn.
                           (cl-incf cleanup-calls)
                           (when (= cleanup-calls 1)
                             (setq emacsos-assist-web-git--success-watermark 1)
                             (emacsos-assist-web-git--enqueue metadata i2))
                           (error "cleanup launch failed"))))
                (emacsos-assist-web-git--begin metadata (list i1))
                (funcall helper (list :ok nil :reason "fetch failed"))
                (should-not emacsos-assist-web-git--next)
                (should (= (window-parameter first 'assist-web-git-intent)
                           2))
                (should (= (window-parameter second 'assist-web-git-intent)
                           2))
                (should (string-match-p "mirror cleanup failed"
                                        emacsos-assist-web-git--unavailable)))))
        (set-window-parameter first 'assist-web-git-intent nil)
        (set-window-parameter second 'assist-web-git-intent nil)
        (kill-buffer thread)))))

(ert-deftest test-assist-web-git-stale-r2-reobserves-before-r3 ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let ((entry (emacsos-assist-web--entry
                  "fixture" 'reconciling "exact-key"))
          r2 ordinary exact-run r3 fetched)
      (setf (plist-get entry :run-id) "run-1")
      (setq-local emacsos-assist-web--thread-id "thread-1"
                  emacsos-assist-web--queue (list entry))
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method path _payload done &rest _)
                   (cond
                    ((string-match-p "/runs/" path) (setq exact-run done))
                    ((not r2) (setq r2 done))
                    ((not ordinary) (setq ordinary done))
                    (t (setq r3 done)))))
                ((symbol-function 'emacsos-assist-web--try-write-cache)
                 (lambda (&rest _) t))
                ((symbol-function 'emacsos-assist-web--save-draft)
                 (lambda () t))
                ((symbol-function 'emacsos-assist-web--render) #'ignore)
                ((symbol-function 'emacsos-assist-web--pump-posts) #'ignore)
                ((symbol-function 'emacsos-assist-web-git--begin)
                 (lambda (&rest _) (setq fetched t))))
        (emacsos-assist-web--reconcile-queue)
        ;; A different legitimate chat path may supersede the shared
        ;; generation even though manual Refresh now joins R2.
        (emacsos-assist-web--legacy-refresh-thread (current-buffer))
        (funcall ordinary
                 (test-assist-web-git--snapshot "ready" "topic/new") nil)
        (funcall r2 (test-assist-web-git--snapshot "ready" "topic/old") nil)
        (should (eq (plist-get entry :state) 'terminal-unreconciled))
        (should (plist-get entry :requires-reobserve))
        (should-not fetched)
        (should-not r3)
        (emacsos-assist-web-refresh-thread (current-buffer))
        (should exact-run)
        (should-not r3)
        (funcall exact-run '((id . "run-1") (thread_id . "thread-1")
                             (status . "success")) nil)
        (should r3)
        (let ((owner (plist-get entry :reconcile-owner)))
          (should (eq (plist-get entry :state) 'reconciling))
          ;; A late duplicate R2 callback cannot restore R3's owner.
          (funcall r2 (test-assist-web-git--snapshot "ready" "topic/old") nil)
          (should (eq (plist-get entry :reconcile-owner) owner))
          (should (eq (plist-get entry :state) 'reconciling)))
        (funcall r3
                 (test-assist-web-git--snapshot "ready" "topic/new") nil)
        (should-not emacsos-assist-web--queue)
        (should-not emacsos-assist-web--manual-recovery-required)
        (should fetched)))))

(ert-deftest test-assist-web-git-stale-r2-cannot-restore-reclaimed-owner ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let* ((entry (emacsos-assist-web--entry
                   "fixture" 'reconciling "exact-key"))
           (old-owner 1)
           (new-owner 2)
           saved)
      (setf (plist-get entry :reconcile-owner) new-owner)
      (setq-local emacsos-assist-web--queue (list entry))
      (cl-letf (((symbol-function 'emacsos-assist-web--save-draft)
                 (lambda () (setq saved t))))
        (should-not
         (emacsos-assist-web--restore-reconciliation
          (list entry) old-owner "stale; Retry"))
        (should-not saved)
        (should (eq (plist-get entry :state) 'reconciling))
        (should (eql (plist-get entry :reconcile-owner) new-owner))))))

(ert-deftest test-assist-web-git-stale-r2-save-failure-blocks-r3 ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (let* ((entry (emacsos-assist-web--entry
                   "fixture" 'reconciling "exact-key"))
           (owner 1)
           requested)
      (setf (plist-get entry :run-id) "run-1"
            (plist-get entry :reconcile-owner) owner)
      (setq-local emacsos-assist-web--thread-id "thread-1"
                  emacsos-assist-web--queue (list entry))
      (cl-letf (((symbol-function 'emacsos-assist-web--save-draft)
                 (lambda () nil))
                ((symbol-function 'emacsos-assist-web--request)
                 (lambda (&rest _) (setq requested t))))
        (emacsos-assist-web--restore-reconciliation
         (list entry) owner "stale; Retry")
        (emacsos-assist-web--reconcile-when-settled)
        (should-not requested)
        (should emacsos-assist-web--reconcile-recovery-paused)
        (should (eq (plist-get entry :state) 'terminal-unreconciled))
        (should (plist-get entry :requires-reobserve))))))

(ert-deftest test-assist-web-git-joined-refresh-failure-releases-intent ()
  (save-window-excursion
    (let ((thread (generate-new-buffer " *git-r2-joined-failure*"))
          (window (selected-window))
          callback)
      (unwind-protect
          (progn
            (set-window-buffer window thread)
            (with-current-buffer thread
              (emacsos-assist-web-mode)
              (let ((entry (emacsos-assist-web--entry
                            "fixture" 'reconciling "exact-key")))
                (setq-local emacsos-assist-web--thread-id "thread-1"
                            emacsos-assist-web--queue (list entry)
                            emacsos-assist-web-git--epoch 1
                            emacsos-assist-web-git--pending
                            (list :key '(changed) :epoch 1 :request nil
                                  :requires-durable t
                                  :intents
                                  (list (list :action 'files :buffer thread
                                              :window window :serial 1))))
                (set-window-parameter window 'assist-web-git-intent 1)
                (cl-letf (((symbol-function 'emacsos-assist-web--request)
                           (lambda (_method _path _payload done &rest _)
                             (setq callback done)))
                          ((symbol-function 'emacsos-assist-web--save-draft)
                           (lambda () t)))
                  (emacsos-assist-web--reconcile-queue)
                  (emacsos-assist-web-refresh-thread thread)
                  (funcall callback nil "network unavailable"))
                (should-not emacsos-assist-web--reconcile-generation)
                (should-not emacsos-assist-web-git--pending)
                (should (eq (plist-get entry :state) 'terminal-unreconciled))
                (should (plist-get entry :requires-reobserve))
                (should (= (window-parameter window 'assist-web-git-intent)
                           2))
                (should (window-parameter window 'assist-web-git-feedback)))))
        (kill-buffer thread)))))

(ert-deftest test-assist-web-git-joined-r2-error-unsaved-needs-restart ()
  (save-window-excursion
    (let ((thread (generate-new-buffer " *git-r2-restart*"))
          (window (selected-window))
          callback (requests 0))
      (unwind-protect
          (progn
            (set-window-buffer window thread)
            (with-current-buffer thread
              (emacsos-assist-web-mode)
              (let ((entry (emacsos-assist-web--entry
                            "fixture" 'reconciling "exact-key")))
                (setf (plist-get entry :run-id) "run-1")
                (setq-local emacsos-assist-web--thread-id "thread-1"
                            emacsos-assist-web--queue (list entry)
                            emacsos-assist-web-git--epoch 1
                            emacsos-assist-web-git--pending
                            (list :key '(changed) :epoch 1 :request nil
                                  :requires-durable t
                                  :intents
                                  (list (list :action 'files :buffer thread
                                              :window window :serial 1))))
                (set-window-parameter window 'assist-web-git-intent 1)
                (cl-letf (((symbol-function 'emacsos-assist-web--request)
                           (lambda (_method _path _payload done &rest _)
                             (cl-incf requests)
                             (setq callback done)))
                          ((symbol-function 'emacsos-assist-web--save-draft)
                           (lambda () nil)))
                  (emacsos-assist-web--reconcile-queue)
                  (emacsos-assist-web-refresh-thread thread)
                  (should (= requests 1))
                  (funcall callback nil "network unavailable")
                  (should emacsos-assist-web--reconcile-recovery-paused)
                  (should (string-match-p
                           "restart to recover"
                           emacsos-assist-web-git--unavailable))
                  (emacsos-assist-web-refresh-thread thread)
                  (should (= requests 1)))
                (should-not emacsos-assist-web-git--pending)
                (should (eq (plist-get entry :state) 'terminal-unreconciled))
                (should (window-parameter window 'assist-web-git-feedback)))))
        (kill-buffer thread)))))

(ert-deftest test-assist-web-git-accepted-chat-refresh-outranks-newer-probe ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq-local emacsos-assist-web--thread-id "thread-1")
    (emacsos-assist-web-git--sync-keys)
    (let ((snapshot (test-assist-web-git--snapshot "ready" "topic/old"))
          (new (test-assist-web-git--metadata
                "ready" "topic/new" test-assist-web-git--published))
          refresh-callback rendered)
      (cl-letf (((symbol-function 'emacsos-assist-web--request)
                 (lambda (_method _path _payload done &rest _)
                   (setq refresh-callback done)))
                ((symbol-function 'emacsos-assist-web-git--read-metadata)
                 (lambda (_thread done) (funcall done new nil)))
                ((symbol-function 'emacsos-assist-web-git--enqueue) #'ignore)
                ((symbol-function 'emacsos-assist-web--try-write-cache)
                 (lambda (&rest _) t))
                ((symbol-function 'emacsos-assist-web--render)
                 (lambda (value &rest _) (setq rendered value))))
        (emacsos-assist-web--legacy-refresh-thread (current-buffer))
        (emacsos-assist-web-git--command 'files)
        (funcall refresh-callback snapshot nil)
        (should (equal (plist-get emacsos-assist-web-git--metadata :branch)
                       "topic/old"))
        (should (eq rendered snapshot))))))

(ert-deftest test-assist-web-git-view-refusal-after-promotion-keeps-generation ()
  (let* ((cache (make-temp-file "assist-git-promote-" t))
         (generation-id (make-string 32 ?c))
         (stage (expand-file-name (concat "staging/" generation-id) cache))
         (path (expand-file-name (concat "generations/" generation-id) cache))
         (intent (list :action 'files))
         (metadata (test-assist-web-git--metadata
                    "ready" "topic/one" test-assist-web-git--head))
         (request (list :id generation-id :epoch 0 :metadata metadata
                        :verified-epoch 0 :final-attempts 1
                        :intents (list intent)))
         opened)
    (unwind-protect
        (with-temp-buffer
          (make-directory stage t)
          (make-directory (expand-file-name "generations" cache))
          (let ((emacsos-assist-web-git-cache-directory cache))
            (nconc intent (list :buffer (current-buffer)
                                :window (selected-window) :serial 1))
            (setq-local emacsos-assist-web-git--metadata metadata
                        emacsos-assist-web-git--request request)
            (cl-letf (((symbol-function 'emacsos-assist-web-git--intent-live-p)
                       (lambda (_) t))
                      ((symbol-function 'emacsos-assist-web-git--open)
                       (lambda (&rest _) (setq opened t)
                         (error "file is above display limit"))))
              (emacsos-assist-web-git--promote
               request (list :thread_oid test-assist-web-git--head
                             :main_oid test-assist-web-git--published)))
            (should opened)
            (should-not emacsos-assist-web-git--request)
            (should (equal (emacsos-assist-web-git-generation-path
                            emacsos-assist-web-git--current) path))
            (should (file-directory-p path))
            (should-not (file-exists-p stage))))
      (emacsos-assist-web-git--clear-feedback (selected-window))
      (delete-directory cache t))))

(ert-deftest test-assist-web-git-chat-failure-during-cleanup-rechecks-final ()
  (let* ((cache (make-temp-file "assist-git-recheck-" t))
         (id (make-string 32 ?d))
         (stage (expand-file-name (concat "staging/" id) cache))
         (metadata (test-assist-web-git--metadata
                    "ready" "topic/one" test-assist-web-git--head))
         (prior (make-emacsos-assist-web-git-generation
                 :id (make-string 32 ?p) :metadata metadata :state 'cached))
         (current (make-emacsos-assist-web-git-generation
                   :id (make-string 32 ?c) :metadata metadata :state 'current))
         (request (list :id id :epoch 0 :metadata metadata :intents nil
                        :verified-epoch 0 :final-attempts 1))
         cleanup-callback final-callback)
    (unwind-protect
        (with-temp-buffer
          (make-directory stage t)
          (make-directory (expand-file-name "generations" cache))
          (let ((emacsos-assist-web-git-cache-directory cache))
            (setq-local emacsos-assist-web--thread-id "thread-1"
                        emacsos-assist-web-git--metadata metadata
                        emacsos-assist-web-git--request request
                        emacsos-assist-web-git--previous prior
                        emacsos-assist-web-git--current current)
            (cl-letf (((symbol-function 'emacsos-assist-web-git--cleanup)
                       (lambda (_generation _kind callback)
                         (setq cleanup-callback callback)))
                      ((symbol-function 'emacsos-assist-web-git--read-metadata)
                       (lambda (_thread callback)
                         (setq final-callback callback))))
              (emacsos-assist-web-git--promote
               request (list :thread_oid test-assist-web-git--head
                             :main_oid test-assist-web-git--published))
              (should cleanup-callback)
              (emacsos-assist-web-git--canonical-uncertain)
              (should (eq (emacsos-assist-web-git-generation-state current)
                          'cached))
              (funcall cleanup-callback t)
              (should final-callback)
              (should (eq emacsos-assist-web-git--current current))
              (should (file-directory-p stage))
              (funcall final-callback metadata nil)
              (should-not emacsos-assist-web-git--request)
              (should (eq (emacsos-assist-web-git-generation-state
                           emacsos-assist-web-git--current)
                          'current))
              (should (file-directory-p
                       (emacsos-assist-web-git-generation-path
                        emacsos-assist-web-git--current))))))
      (delete-directory cache t))))

(defun test-assist-web-git--metadata (status branch oid)
  "Return a selected STATUS, BRANCH, OID tuple for race tests."
  (list :tid "thread-1" :repo-key test-assist-web-git--key
        :status status :branch branch :expected oid
        :actual-branch (and (equal status "ready") branch)
        :head oid))

(ert-deftest test-assist-web-git-final-check-rejects-external-advance ()
  (with-temp-buffer
    (let* ((metadata (test-assist-web-git--metadata
                      "ready" "topic/one" test-assist-web-git--head))
           (request (list :id (make-string 32 ?a) :epoch 0
                          :metadata metadata))
           cleaned promoted failure)
      (setq-local emacsos-assist-web-git--metadata metadata
                  emacsos-assist-web-git--request request)
      (cl-letf (((symbol-function 'emacsos-assist-web-git--read-metadata)
                 (lambda (_thread callback) (funcall callback metadata nil)))
                ((symbol-function 'emacsos-assist-web-git--cleanup)
                 (lambda (_id _kind callback)
                   (setq cleaned t) (funcall callback t)))
                ((symbol-function 'emacsos-assist-web-git--promote)
                 (lambda (&rest _) (setq promoted t)))
                ((symbol-function 'emacsos-assist-web-git--failed)
                 (lambda (_request reason) (setq failure reason))))
        (emacsos-assist-web-git--final-check
         request (list :thread_oid test-assist-web-git--published))
        (should cleaned)
        (should-not promoted)
        (should (string-match-p "remote update pending" failure))))))

(ert-deftest test-assist-web-git-final-check-conflict-needs-canonical-read ()
  (with-temp-buffer
    (let* ((old (test-assist-web-git--metadata
                 "ready" "topic/old" test-assist-web-git--head))
           (new (test-assist-web-git--metadata
                 "ready" "topic/new" test-assist-web-git--published))
           (request (list :id (make-string 32 ?a) :epoch 0
                          :metadata old :intents nil))
           cleaned promoted refreshed)
      (setq-local emacsos-assist-web-git--metadata old
                  emacsos-assist-web-git--request request)
      (cl-letf (((symbol-function 'emacsos-assist-web-git--read-metadata)
                 (lambda (_thread callback) (funcall callback new nil)))
                ((symbol-function 'emacsos-assist-web-git--cleanup)
                 (lambda (_id _kind callback)
                   (setq cleaned t) (funcall callback t)))
                ((symbol-function 'emacsos-assist-web-refresh-thread)
                 (lambda (&rest _) (setq refreshed t)))
                ((symbol-function 'emacsos-assist-web-git--promote)
                 (lambda (&rest _) (setq promoted t))))
        (emacsos-assist-web-git--final-check
         request (list :thread_oid test-assist-web-git--head))
        (should cleaned)
        (should-not promoted)
        (should refreshed)
        (should (equal emacsos-assist-web-git--metadata old))
        (should (equal (plist-get emacsos-assist-web-git--pending :key)
                       (emacsos-assist-web-git--request-key new)))))))

(ert-deftest test-assist-web-git-superseded-final-check-cannot-promote ()
  (with-temp-buffer
    (let* ((metadata (test-assist-web-git--metadata
                      "ready" "topic/one" test-assist-web-git--head))
           (old (list :id (make-string 32 ?a) :epoch 0 :metadata metadata))
           (new (list :id (make-string 32 ?b) :epoch 1 :metadata metadata))
           cleaned promoted)
      (setq-local emacsos-assist-web-git--metadata metadata
                  emacsos-assist-web-git--request new
                  emacsos-assist-web-git--epoch 1)
      (cl-letf (((symbol-function 'emacsos-assist-web-git--read-metadata)
                 (lambda (_thread callback) (funcall callback metadata nil)))
                ((symbol-function 'emacsos-assist-web-git--cleanup)
                 (lambda (_id _kind callback)
                   (setq cleaned t) (funcall callback t)))
                ((symbol-function 'emacsos-assist-web-git--promote)
                 (lambda (&rest _) (setq promoted t))))
        (emacsos-assist-web-git--final-check
         old (list :thread_oid test-assist-web-git--head))
        (should cleaned)
        (should-not promoted)
        (should (eq emacsos-assist-web-git--request new))))))

(ert-deftest test-assist-web-git-helper-timeout-does-not-open-cache ()
  (with-temp-buffer
    (let* ((metadata (test-assist-web-git--metadata
                      "processing" "topic/old" test-assist-web-git--published))
           (generation (make-emacsos-assist-web-git-generation
                        :metadata metadata :state 'busy))
           (window (selected-window))
           (intent (list :action 'files :buffer (current-buffer)
                         :window window :serial 1))
           (request (list :metadata metadata :intents (list intent)))
           opened)
      (set-window-buffer window (current-buffer))
      (set-window-parameter window 'assist-web-git-intent 1)
      (setq-local emacsos-assist-web-git--current generation
                  emacsos-assist-web-git--request request
                  emacsos-assist-web-git--metadata metadata)
      (cl-letf (((symbol-function 'emacsos-assist-web-git--open)
                 (lambda (&rest _) (setq opened t))))
        (emacsos-assist-web-git--failed request "Git operation timed out")
        (should-not opened)
        (should (eq (emacsos-assist-web-git-generation-state generation)
                    'cached))
        (setq opened nil)
        (setq-local emacsos-assist-web-git--request request
                    emacsos-assist-web-git--metadata
                    (test-assist-web-git--metadata
                     "processing" "topic/new" test-assist-web-git--published))
        (emacsos-assist-web-git--failed request "Git operation timed out")
        (should-not opened)))))

(ert-deftest test-assist-web-git-post-denial-reauth-needs-new-generation ()
  (let ((root (make-temp-file "assist-git-reauth-" t))
        (window (selected-window))
        (original (window-buffer (selected-window))))
    (unwind-protect
        (with-temp-buffer
          (let* ((thread (current-buffer))
                 (snapshot (test-assist-web-git--snapshot "ready" "topic/one"))
                 (metadata (emacsos-assist-web-git--metadata-from-snapshot
                            snapshot))
                 (generation (make-emacsos-assist-web-git-generation
                              :path root :metadata metadata :state 'current
                              :auth-epoch 0))
                 (intent (list :action 'files :buffer thread :window window
                               :serial 1))
                 (request (list :metadata metadata :intents (list intent)))
                 opened)
            (set-window-buffer window thread)
            (set-window-parameter window 'assist-web-git-intent 1)
            (setq-local emacsos-assist-web-git--metadata metadata
                        emacsos-assist-web-git--current generation)
            (emacsos-assist-web-git--canonical-denied 403)
            (emacsos-assist-web-git--note-snapshot
             snapshot nil emacsos-assist-web-git--auth-epoch)
            (should-not emacsos-assist-web-git--denied)
            (setq-local emacsos-assist-web-git--request request)
            (cl-letf (((symbol-function 'emacsos-assist-web-git--open)
                       (lambda (&rest _) (setq opened t))))
              (emacsos-assist-web-git--failed
               request "Git operation timed out"))
            (should-not opened)
            (set-window-parameter window 'assist-web-git-intent 1)
            (cl-letf (((symbol-function 'read-file-name)
                       (lambda (&rest _) (setq opened t) "irrelevant")))
              (should-error (emacsos-assist-web-git--open
                             intent generation)))
            (should-not opened)))
      (set-window-buffer window original)
      (set-window-parameter window 'assist-web-git-intent nil)
      (delete-directory root t))))

(ert-deftest test-assist-web-git-pinned-prior-is-not-deleted ()
  (with-temp-buffer
    (let* ((metadata (test-assist-web-git--metadata
                      "ready" "topic/new" test-assist-web-git--head))
           (request (list :id (make-string 32 ?a) :epoch 0 :metadata metadata))
           (view (generate-new-buffer " *pinned mirror view*"))
           (prior (make-emacsos-assist-web-git-generation
                   :id (make-string 32 ?b) :views (list view)))
           deleted failure)
      (unwind-protect
          (progn
            (setq-local emacsos-assist-web-git--metadata metadata
                        emacsos-assist-web-git--request request
                        emacsos-assist-web-git--previous prior)
            (cl-letf (((symbol-function 'emacsos-assist-web-git--cleanup)
                       (lambda (_id kind callback)
                         (when (equal kind "generations") (setq deleted t))
                         (funcall callback t)))
                      ((symbol-function 'emacsos-assist-web-git--failed)
                       (lambda (_request reason) (setq failure reason))))
              (emacsos-assist-web-git--promote
               request (list :thread_oid test-assist-web-git--head))
              (should-not deleted)
              (should (equal failure "close old view to refresh"))))
        (kill-buffer view)))))

(provide 'test-assist-web-git)
;;; test-assist-web-git.el ends here
