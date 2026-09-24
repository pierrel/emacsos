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
                  (list (list :key "exact-key" :state 'reconciling)))
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
                  (list (list :key "exact-key" :state 'reconciling)))
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
                  (list (list :key "exact-key" :state 'reconciling)))
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

(ert-deftest test-assist-web-git-command-probe-failure-downgrades-freshness ()
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
                  'cached))
      (should-not (string-match-p " current" (emacsos-assist-web-git--thread-header)))
      (cl-letf (((symbol-function 'emacsos-assist-web-git--read-metadata)
                 (lambda (_thread callback)
                   (funcall callback nil '(git . "bad Git fields")))))
        (emacsos-assist-web-git--command 'files))
      (should-not emacsos-assist-web-git--metadata)
      (should (equal emacsos-assist-web-git--unavailable
                     "invalid Git workspace metadata"))
      (cl-letf (((symbol-function 'emacsos-assist-web-git--read-metadata)
                 (lambda (_thread callback)
                   (funcall callback nil '(canonical . "bad thread status")))))
        (emacsos-assist-web-git--command 'files))
      (should (equal emacsos-assist-web-git--unavailable
                     "invalid authenticated thread snapshot")))))

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
      (cl-letf (((symbol-function 'emacsos-assist-web-git--read-metadata)
                 (lambda (_thread callback)
                   (funcall callback nil
                            '(:kind http :status 403
                              :text "Assist Web request failed (403)")))))
        (emacsos-assist-web-git--command 'files))
      (should-not emacsos-assist-web-git--metadata)
      (should (equal emacsos-assist-web-git--unavailable
                     "thread access denied (403); Git unavailable"))
      (should-not (string-match-p " current"
                                  (emacsos-assist-web-git--thread-header))))))

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
          (should (equal emacsos-assist-web-git--metadata new))
          (should (equal (car enqueued) new))
          (should (eq (plist-get (cadr enqueued) :action) 'diff)))))))

(ert-deftest test-assist-web-git-old-chat-refresh-cannot-overwrite-newer-git-probe ()
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
        (should (equal emacsos-assist-web-git--metadata new))
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
                        :intents (list intent)))
         opened)
    (unwind-protect
        (with-temp-buffer
          (make-directory stage t)
          (make-directory (expand-file-name "generations" cache))
          (let ((emacsos-assist-web-git-cache-directory cache))
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
