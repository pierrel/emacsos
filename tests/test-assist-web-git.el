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
                    "committed content\n"))
          (let ((view (emacsos-assist-web-git--literal-file-view
                       file root thread generation)))
            (unwind-protect
                (with-current-buffer view
                  (should buffer-read-only)
                  (should-not buffer-file-name)
                  (should (string-match-p "committed content" (buffer-string)))
                  (should-not test-assist-web-git--executed))
              (kill-buffer view))))
      (delete-directory root t))))

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

(ert-deftest test-assist-web-git-final-check-retries-new-ready-branch ()
  (with-temp-buffer
    (let* ((old (test-assist-web-git--metadata
                 "ready" "topic/old" test-assist-web-git--head))
           (new (test-assist-web-git--metadata
                 "ready" "topic/new" test-assist-web-git--published))
           (request (list :id (make-string 32 ?a) :epoch 0
                          :metadata old :intents nil))
           cleaned promoted retried)
      (setq-local emacsos-assist-web-git--metadata old
                  emacsos-assist-web-git--request request)
      (cl-letf (((symbol-function 'emacsos-assist-web-git--read-metadata)
                 (lambda (_thread callback) (funcall callback new nil)))
                ((symbol-function 'emacsos-assist-web-git--cleanup)
                 (lambda (_id _kind callback)
                   (setq cleaned t) (funcall callback t)))
                ((symbol-function 'emacsos-assist-web-git--enqueue)
                 (lambda (metadata _intent) (setq retried metadata)))
                ((symbol-function 'emacsos-assist-web-git--promote)
                 (lambda (&rest _) (setq promoted t))))
        (emacsos-assist-web-git--final-check
         request (list :thread_oid test-assist-web-git--head))
        (should cleaned)
        (should-not promoted)
        (should (equal retried new))))))

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

(ert-deftest test-assist-web-git-network-cache-only-for-exact-pair ()
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
        (should opened)
        (should (eq (emacsos-assist-web-git-generation-state generation)
                    'cached))
        (setq opened nil)
        (setq-local emacsos-assist-web-git--request request
                    emacsos-assist-web-git--metadata
                    (test-assist-web-git--metadata
                     "processing" "topic/new" test-assist-web-git--published))
        (emacsos-assist-web-git--failed request "Git operation timed out")
        (should-not opened)))))

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
