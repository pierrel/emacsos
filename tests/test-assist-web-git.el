;;; test-assist-web-git.el --- Ordinary thread checkout behavior -*- lexical-binding: t -*-

(require 'ert)
(require 'cl-lib)
(require 'assist-web-git)
(require 'assist-web)

(defconst test-assist-web-git--metadata
  '(:tid "thread-1" :repo-key "aaaaaaaaaaaaaaaaaaaa"
    :branch "assist/thread" :status "ready"))

(ert-deftest test-assist-web-git-phone-header-keeps-both-touch-actions-visible ()
  "Narrow phone headers put Status and Merge before variable Run text."
  (with-temp-buffer
    (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 40))
              ((symbol-function 'emacsos-assist-web-git--thread-header)
               (lambda () "Git branch and long published commit")))
      (dolist (run '(nil "Run active [?] "))
        (cl-letf (((symbol-function 'emacsos-assist-web--lifecycle-header)
                   (lambda () run)))
          (let* ((header (emacsos-assist-web--thread-header))
                 (merge (string-match "\\[Merge\\]" header)))
            (should (string-match "\\[Status\\]" header))
            (should merge)
            (should (<= (string-width (substring header 0 (+ merge 7))) 40))))))))

(ert-deftest test-assist-web-git-pending-merge-keeps-outcome-buffer ()
  "Do not lose the in-flight POST callback by killing its status buffer."
  (let ((view (generate-new-buffer " *assist-git-pending-view*")))
    (unwind-protect
        (with-current-buffer view
          (special-mode)
          (add-hook 'kill-buffer-query-functions
                    #'emacsos-assist-web-git--status-may-kill-p nil t)
          (setq-local emacsos-assist-web-git--status-pending t)
          (should-not (kill-buffer view))
          (should (buffer-live-p view))
          (setq emacsos-assist-web-git--status-pending nil)
          (should (kill-buffer view)))
      (when (buffer-live-p view) (kill-buffer view)))))

(ert-deftest test-assist-web-git-helper-uses-desktop-python-path ()
  "Find Python in Emacs exec-path, including a graphical desktop install."
  (with-temp-buffer
    (let (command)
      (cl-letf (((symbol-function 'executable-find)
                 (lambda (name) (and (equal name "python3") "/tools/python3")))
                ((symbol-function 'make-process)
                 (lambda (&rest options)
                   (setq command (plist-get options :command))
                   'test-process))
                ((symbol-function 'process-send-string) #'ignore)
                ((symbol-function 'process-send-eof) #'ignore))
        (setq emacsos-assist-web-git--epoch 1)
        (emacsos-assist-web-git--enqueue test-assist-web-git--metadata)
        (should (equal command (list "/tools/python3" emacsos-assist-web-git-helper)))))))

(ert-deftest test-assist-web-git-status-shows-factual-mismatch-and-stale-state ()
  (with-temp-buffer
    (special-mode)
    (setq-local emacsos-assist-web-git--status-server
                '((branch . "assist/server")
                  (published_revision . "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
                  (state . "available") (observed_at . "2026-10-18T15:00:00+00:00")))
    (setq-local emacsos-assist-web-git--status-local
                '((branch . "other")
                  (local_oid . "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
                  (observed_at . "2026-10-18T15:00:01+00:00")))
    (setq-local emacsos-assist-web-git--status-fresh t)
    (emacsos-assist-web-git--status-render)
    (should (string-match-p "different branch or commit" (buffer-string)))
    (should (string-match-p "Local observation: at .*may now be stale" (buffer-string)))
    (should (string-match-p "Unsaved buffers, staged, uncommitted, untracked"
                            (buffer-string)))
    (setq-local emacsos-assist-web-git--status-fresh nil)
    (emacsos-assist-web-git--status-render)
    (should (string-match-p "stale/unavailable" (buffer-string)))
    (should-not (string-match-p "Confirm SERVER Merge" (buffer-string)))))

(ert-deftest test-assist-web-git-local-probe-failure-still-observes-server ()
  (let ((source (generate-new-buffer " *assist-git-probe-source*"))
        (view (generate-new-buffer " *assist-git-probe-view*"))
        requested)
    (unwind-protect
        (progn
          (with-current-buffer source
            (setq-local emacsos-assist-web--thread-id "thread-1"
                        emacsos-assist-web-git--metadata test-assist-web-git--metadata
                        emacsos-assist-web--denied nil))
          (with-current-buffer view
            (special-mode)
            (setq-local emacsos-assist-web-git--status-source source
                        emacsos-assist-web-git--status-identity
                        '("thread-1" . "aaaaaaaaaaaaaaaaaaaa"))
            (cl-letf (((symbol-function 'emacsos-assist-web-git--status-inspect-local)
                       (lambda (&rest _) (error "Python unavailable")))
                      ((symbol-function 'emacsos-assist-web--request)
                       (lambda (method path _body callback &rest _)
                         (setq requested (list method path))
                         (funcall callback nil '(:kind transport)))))
              (emacsos-assist-web-git--status-refresh))
            (should (equal requested '("GET" "threads/thread-1/git")))
            (should (eq emacsos-assist-web-git--status-local-state 'unavailable))
            (should (string-match-p "Local observation: unavailable" (buffer-string)))))
      (kill-buffer view)
      (kill-buffer source))))

(ert-deftest test-assist-web-git-unrelated-tap-disarms-and-pending-blocks-refresh ()
  (let ((source (generate-new-buffer " *assist-git-arm-source*"))
        (view (generate-new-buffer " *assist-git-arm-view*")))
    (unwind-protect
        (progn
          (with-current-buffer source
            (setq-local emacsos-assist-web--thread-id "thread-1"
                        emacsos-assist-web-git--metadata test-assist-web-git--metadata
                        emacsos-assist-web--denied nil))
          (with-current-buffer view
            (special-mode)
            (setq-local emacsos-assist-web-git--status-source source
                        emacsos-assist-web-git--status-identity
                        '("thread-1" . "aaaaaaaaaaaaaaaaaaaa")
                        emacsos-assist-web-git--status-fresh t
                        emacsos-assist-web-git--status-server
                        '((branch . "assist/server") (state . "available")
                          (published_revision . "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")))
            (emacsos-assist-web-git--status-arm)
            (let ((this-command 'mouse-drag-region)
                  (last-input-event '(down-mouse-1)))
              (cl-letf (((symbol-function 'emacsos-assist-web-git--confirm-target-p)
                         (lambda () t)))
                (emacsos-assist-web-git--merge-pre-command)))
            (should emacsos-assist-web-git--status-armed)
            (let ((this-command 'push-button))
              (goto-char (point-min))
              (emacsos-assist-web-git--merge-pre-command))
            (should-not emacsos-assist-web-git--status-armed)
            (should-not (string-match-p "Confirm SERVER" (buffer-string)))
            (setq emacsos-assist-web-git--status-pending t)
            (should-error (emacsos-assist-web-git--status-refresh) :type 'user-error)))
      (emacsos-assist-web-git--disarm-status)
      (kill-buffer view)
      (kill-buffer source))))

(ert-deftest test-assist-web-git-merge-uses-server-target-not-local-head ()
  (let ((source (generate-new-buffer " *assist-git-source*"))
        (view (generate-new-buffer " *assist-git-view*"))
        request
        (remote-outcome "merged")
        (remote-status 200))
    (unwind-protect
        (progn
          (with-current-buffer source
            (setq-local emacsos-assist-web--thread-id "thread-1"
                        emacsos-assist-web-git--metadata test-assist-web-git--metadata
                        emacsos-assist-web--denied nil))
          (with-current-buffer view
            (special-mode)
            (setq-local emacsos-assist-web-git--status-source source
                        emacsos-assist-web-git--status-identity
                        '("thread-1" . "aaaaaaaaaaaaaaaaaaaa")
                        emacsos-assist-web-git--status-fresh t
                        emacsos-assist-web-git--status-server
                        '((thread_id . "thread-1")
                          (repo_key . "aaaaaaaaaaaaaaaaaaaa")
                          (branch . "assist/server")
                          (published_revision . "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
                          (state . "available"))
                        emacsos-assist-web-git--status-local
                        '((branch . "other")
                          (local_oid . "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")))
            (cl-letf (((symbol-function 'emacsos-assist-web--request)
                       (lambda (method path body callback &optional headers &rest _)
                         (setq request (list method path body headers))
                         (funcall callback `((http_status . ,remote-status)
                                             (outcome . ,remote-outcome)) nil))))
              (emacsos-assist-web-git--status-arm)
              (should (string-match-p "Confirm SERVER Merge & Push" (buffer-string)))
              (should (= (point) (point-min)))
              (should (< (string-match "Unsaved buffers" (buffer-string))
                         (string-match "Confirm SERVER" (buffer-string))))
              (emacsos-assist-web-git--status-confirm))
            (should (equal request
                           '("POST" "threads/thread-1/merge" nil
                             (("X-Assist-Expected-Commit" . "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")))))
            (should (string-match-p "succeeded" (buffer-string)))
            (setq remote-outcome "stale"
                  remote-status 409
                  emacsos-assist-web-git--status-fresh t)
            (cl-letf (((symbol-function 'emacsos-assist-web--request)
                       (lambda (_method _path _body callback &rest _)
                         (funcall callback `((http_status . ,remote-status)
                                             (outcome . ,remote-outcome)) nil))))
              (emacsos-assist-web-git--status-arm)
              (emacsos-assist-web-git--status-confirm))
            (should (string-match-p "commit changed" (buffer-string)))
            (setq remote-outcome "merged"
                  remote-status 500
                  emacsos-assist-web-git--status-fresh t)
            (cl-letf (((symbol-function 'emacsos-assist-web--request)
                       (lambda (_method _path _body callback &rest _)
                         (funcall callback `((http_status . ,remote-status)
                                             (outcome . ,remote-outcome)) nil))))
              (emacsos-assist-web-git--status-arm)
              (emacsos-assist-web-git--status-confirm))
            (should-not (string-match-p "succeeded" (buffer-string)))))
      (emacsos-assist-web-git--disarm-status)
      (kill-buffer view)
      (kill-buffer source))))

(ert-deftest test-assist-web-git-canonical-thread-keys-preserve-file-opener ()
  (with-temp-buffer
      (emacsos-assist-web-mode)
      ;; Isolate the fallback contract from an optional composed file opener.
      (use-local-map (copy-keymap (current-local-map)))
      (define-key (current-local-map) (kbd "C-x C-f") nil)
      (setq-local emacsos-assist-web-git--fallback-file-opener nil)
      (setq-local emacsos-assist-web--thread-id (make-string 32 ?a))
      (emacsos-assist-web-git--sync-keys)
      (should (eq (key-binding (kbd "C-c d")) #'emacsos-assist-web-git-diff))
      (should (eq (key-binding (kbd "C-c g")) #'emacsos-assist-web-git-refresh))
      (should (eq (key-binding (kbd "C-x C-f")) #'emacsos-assist-web-git-find-file))
      (setq-local emacsos-assist-web--thread-id nil)
      (emacsos-assist-web-git--sync-keys)
      (should (eq (key-binding (kbd "C-x C-f")) #'find-file))
      (should-not emacsos-assist-web-git-thread-mode)))

(ert-deftest test-assist-web-git-draft-keeps-ordinary-file-opener ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (use-local-map (copy-keymap (current-local-map)))
    (define-key (current-local-map) (kbd "C-x C-f") nil)
    (emacsos-assist-web-git--sync-keys)
    (should (eq (key-binding (kbd "C-x C-f")) #'find-file))
    (should-not emacsos-assist-web-git-thread-mode)))

(ert-deftest test-assist-web-git-composed-file-opener-takes-priority ()
  (with-temp-buffer
          (emacsos-assist-web-mode)
          (define-key (current-local-map) (kbd "C-x C-f")
                      #'emacsos-assist-web-find-file)
          (setq-local emacsos-assist-web--thread-id (make-string 32 ?a))
          (emacsos-assist-web-git--sync-keys)
          (should (eq (key-binding (kbd "C-x C-f")) #'emacsos-assist-web-find-file))
          (should (eq (key-binding (kbd "C-c d")) #'emacsos-assist-web-git-diff))))

(ert-deftest test-assist-web-git-later-composed-opener-survives-id-loss ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (setq-local emacsos-assist-web--thread-id (make-string 32 ?a))
    (emacsos-assist-web-git--sync-keys)
    (define-key (current-local-map) (kbd "C-x C-f")
                #'emacsos-assist-web-find-file)
    (setq-local emacsos-assist-web--thread-id nil)
    (emacsos-assist-web-git--sync-keys)
    (should (eq (key-binding (kbd "C-x C-f")) #'emacsos-assist-web-find-file))))

(ert-deftest test-assist-web-git-directory-is-a-query-not-a-sync ()
  (let* ((root (make-temp-file "assist-web-git-" t))
         (emacsos-assist-web-git-workspace-directory root)
         (thread (generate-new-buffer " *assist-git-directory*")))
    (unwind-protect
        (with-current-buffer thread
          (setq emacsos-assist-web-git--metadata test-assist-web-git--metadata)
          (let ((path (emacsos-assist-web-git--checkout-path
                       emacsos-assist-web-git--metadata)))
            (should-not (emacsos-assist-web-git-local-directory))
            (should-not (file-exists-p path))
            (make-directory (expand-file-name ".git" path) t)
            (should (equal (emacsos-assist-web-git-local-directory)
                           (file-name-as-directory path)))))
      (kill-buffer thread)
      (delete-directory root t))))

(ert-deftest test-assist-web-git-refresh-sends-only-selected-ref ()
  (with-temp-buffer
    (setq emacsos-assist-web-git--metadata test-assist-web-git--metadata)
    (let (selected manual)
      (cl-letf (((symbol-function 'emacsos-assist-web-git--enqueue)
                 (lambda (metadata &optional explicit)
                   (setq selected metadata manual explicit))))
        (emacsos-assist-web-git-refresh)
        (should (equal (plist-get selected :branch) "assist/thread"))
        (should manual)))))

(ert-deftest test-assist-web-git-diff-uses-actual-local-status ()
  (with-temp-buffer
    (let ((emacsos-assist-web-git--result '((dirty . nil)))
          (live-status "?? draft.txt")
          (status nil) (range nil))
      (cl-letf (((symbol-function 'emacsos-assist-web-git-local-directory)
                 (lambda () "/tmp/checkout/"))
                ((symbol-function 'magit-status-setup-buffer)
                 (lambda (directory) (setq status directory)))
                ((symbol-function 'magit-diff-range)
                 (lambda (revision) (setq range revision)))
                ((symbol-function 'process-file)
                 (lambda (&rest _)
                   (when live-status (insert live-status))
                   0))
                ((symbol-function 'require) (lambda (&rest _) t)))
        (emacsos-assist-web-git-diff)
        (should (equal status "/tmp/checkout/"))
        (should-not range)
        (setq emacsos-assist-web-git--result '((dirty . t))
              live-status nil status nil)
        (emacsos-assist-web-git-diff)
        (should (equal range "refs/remotes/origin/main...HEAD"))
        (should-not status)))))

(ert-deftest test-assist-web-git-diff-refuses-unknown-local-status ()
  (with-temp-buffer
    (cl-letf (((symbol-function 'emacsos-assist-web-git-local-directory)
               (lambda () "/tmp/checkout/"))
              ((symbol-function 'process-file) (lambda (&rest _) 1)))
      (should-error (emacsos-assist-web-git-diff) :type 'user-error))))

(ert-deftest test-assist-web-git-legacy-cache-setting-still-selects-request-root ()
  (with-temp-buffer
    (let ((emacsos-assist-web-git-cache-directory "/tmp/custom-legacy")
          request)
      (cl-letf (((symbol-function 'executable-find) (lambda (_) "/tools/python3"))
                ((symbol-function 'make-process) (lambda (&rest _) 'test-process))
                ((symbol-function 'process-send-string)
                 (lambda (_process payload) (setq request (json-parse-string payload))))
                ((symbol-function 'process-send-eof) #'ignore))
        (emacsos-assist-web-git--enqueue test-assist-web-git--metadata)
        (should (equal (gethash "legacy_root" request) "/tmp/custom-legacy"))))))

(ert-deftest test-assist-web-git-migration-sees-directory-and-symlink-buffers ()
  (let* ((root (make-temp-file "assist-web-git-buffer-" t))
         (checkout (expand-file-name "checkouts/old" root))
         (alias (expand-file-name "alias" root))
         (view (generate-new-buffer " *assist-git-magit-view*")))
    (unwind-protect
        (progn
          (make-directory checkout t)
          (make-symbolic-link checkout alias)
          (with-current-buffer view
            (setq default-directory (file-name-as-directory alias)))
          (should (emacsos-assist-web-git--open-checkout-buffer-p
                   (list (expand-file-name "checkouts" root)))))
      (kill-buffer view)
      (delete-directory root t))))

(ert-deftest test-assist-web-git-migration-ignores-caller-and-remote-buffer ()
  (let* ((root (make-temp-file "assist-web-git-buffer-" t))
         (remote (generate-new-buffer " *assist-git-remote-view*")))
    (unwind-protect
        (with-temp-buffer
          (setq default-directory (file-name-as-directory root))
          (with-current-buffer remote
            (setq default-directory "/ssh:example.test:/home/user/"))
          (should-not (emacsos-assist-web-git--open-checkout-buffer-p (list root))))
      (kill-buffer remote)
      (delete-directory root t))))

(ert-deftest test-assist-web-git-stale-helper-cannot-select-another-thread ()
  (with-temp-buffer
    (let ((old test-assist-web-git--metadata)
          (emacsos-assist-web-git--metadata
           '(:tid "thread-2" :repo-key "aaaaaaaaaaaaaaaaaaaa"
             :branch "assist/thread")))
      (emacsos-assist-web-git--receive
       (current-buffer) old 0
       "{\"ok\":true,\"checkout_path\":\"/tmp/other\"}" 0 nil)
      (should-not emacsos-assist-web-git--result)
      (should-not emacsos-assist-web-git--unavailable))))

(ert-deftest test-assist-web-git-bound-legacy-receipt-keeps-old-workspace ()
  (let* ((root (make-temp-file "assist-git-legacy-" t))
         (old (expand-file-name "life/old-thread" root))
         (emacsos-assist-web-git-workspace-directory root))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" old) t)
          (with-temp-buffer
            (setq emacsos-assist-web-git--metadata test-assist-web-git--metadata)
            (emacsos-assist-web-git--receive
             (current-buffer) test-assist-web-git--metadata 0
             (json-serialize `((ok . t) (legacy . t) (checkout_path . ,old))) 0 t)
            (should (equal (emacsos-assist-web-git-local-directory)
                           (file-name-as-directory old)))
            (should-not emacsos-assist-web-git--unavailable)))
      (delete-directory root t))))

(ert-deftest test-assist-web-git-legacy-receipt-outside-selected-roots-is-rejected ()
  (let* ((root (make-temp-file "assist-git-selected-" t))
         (outside (make-temp-file "assist-git-outside-" t))
         (emacsos-assist-web-git-workspace-directory root))
    (unwind-protect
        (progn
          (make-directory (expand-file-name ".git" outside))
          (with-temp-buffer
            (setq emacsos-assist-web-git--metadata test-assist-web-git--metadata)
            (emacsos-assist-web-git--receive
             (current-buffer) test-assist-web-git--metadata 0
             (json-serialize `((ok . t) (legacy . t) (checkout_path . ,outside))) 0 t)
            (should-not emacsos-assist-web-git--result)
            (should (equal emacsos-assist-web-git--unavailable
                           "checkout update unavailable; local work preserved"))))
      (delete-directory root t)
      (delete-directory outside t))))

(ert-deftest test-assist-web-git-manual-refusal-shows-bounded-reason ()
  (with-temp-buffer
    (setq emacsos-assist-web-git--metadata test-assist-web-git--metadata)
    (emacsos-assist-web-git--receive
     (current-buffer) test-assist-web-git--metadata 0
     "{\"ok\":false,\"error\":\"Bound legacy checkout is missing\"}" 0 t)
    (should (equal emacsos-assist-web-git--unavailable
                   "Bound legacy checkout is missing"))
    (should-not emacsos-assist-web-git--result)))

(ert-deftest test-assist-web-git-stale-epoch-cannot-clear-new-request ()
  (with-temp-buffer
    (setq emacsos-assist-web-git--metadata test-assist-web-git--metadata
          emacsos-assist-web-git--epoch 2
          emacsos-assist-web-git--process 'new-request)
    (emacsos-assist-web-git--receive
     (current-buffer) test-assist-web-git--metadata 1
     "{\"ok\":true}" 0 nil)
    (should (eq emacsos-assist-web-git--process 'new-request))
    (should-not emacsos-assist-web-git--result)))

(ert-deftest test-assist-web-git-denial-cancels-request-and-stale-receipt ()
  (with-temp-buffer
    (let ((emacsos-assist-web-git--metadata test-assist-web-git--metadata)
          (emacsos-assist-web-git--epoch 2)
          (emacsos-assist-web-git--process 'old-request)
          (emacsos-assist-web--denied t)
          cancelled)
      (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                ((symbol-function 'signal-process)
                 (lambda (process signal)
                   (should (eq signal 'SIGTERM))
                   (setq cancelled process))))
        (emacsos-assist-web-git--invalidate "authentication denied"))
      (should (eq cancelled 'old-request))
      (should (eq emacsos-assist-web-git--process 'old-request))
      (should (= emacsos-assist-web-git--epoch 3))
      (emacsos-assist-web-git--receive
       (current-buffer) test-assist-web-git--metadata 2
       "{\"ok\":true}" 0 nil)
      (should (equal emacsos-assist-web-git--unavailable "authentication denied"))
      (should-not emacsos-assist-web-git--result))))

(ert-deftest test-assist-web-git-changed-thread-waits-for-old-helper-exit ()
  (with-temp-buffer
    (let ((emacsos-assist-web-git--metadata test-assist-web-git--metadata)
          (emacsos-assist-web-git--process 'old-request)
          (emacsos-assist-web--denied nil)
          (next '(:tid "thread-2" :repo-key "aaaaaaaaaaaaaaaaaaaa"
                   :branch "assist/thread-2"))
          stopped resumed)
      (cl-letf (((symbol-function 'process-live-p)
                 (lambda (process) (eq process 'old-request)))
                ((symbol-function 'signal-process)
                 (lambda (process signal)
                   (setq stopped (list process signal))))
                ((symbol-function 'emacsos-assist-web-git--enqueue)
                 (lambda (metadata &rest _) (setq resumed metadata))))
        (should (emacsos-assist-web-git--note next))
        (should (equal stopped '(old-request SIGTERM)))
        (should (eq emacsos-assist-web-git--process 'old-request))
        (emacsos-assist-web-git--receive
         (current-buffer) test-assist-web-git--metadata 0 "" 143 nil nil 'old-request)
        (should-not emacsos-assist-web-git--process)
        (should (equal resumed next))
        (should-not emacsos-assist-web-git--result)))))

(ert-deftest test-assist-web-git-denial-refuses-manual-refresh ()
  (with-temp-buffer
    (let ((emacsos-assist-web--denied t)
          (emacsos-assist-web-git--metadata test-assist-web-git--metadata))
      (should-error (emacsos-assist-web-git-refresh) :type 'user-error)
      (should-not emacsos-assist-web-git--process))))

(ert-deftest test-assist-web-git-server-hold-survives-helper-receipt ()
  (with-temp-buffer
    (let* ((emacsos-assist-web--denied nil)
           (metadata (append test-assist-web-git--metadata
                             '(:sync-error "Server Git needs reconciliation")))
           (emacsos-assist-web-git--metadata metadata)
           (emacsos-assist-web-git--epoch 1)
           (emacsos-assist-web-git-workspace-directory "/tmp"))
      (emacsos-assist-web-git--receive
       (current-buffer) metadata 1
       (json-serialize `((ok . t)
                         (checkout_path . ,(emacsos-assist-web-git--checkout-path metadata))))
       0 nil)
      (should (equal emacsos-assist-web-git--unavailable
                     "Server Git needs reconciliation")))))

(ert-deftest test-assist-web-git-first-open-and-success-fetch-once-each ()
  (with-temp-buffer
    (let ((snapshot '((thread . ((id . "thread-1") (status . "ready")
                                  (workspace . ((repo_key . "aaaaaaaaaaaaaaaaaaaa")
                                                (branch . "assist/thread")))))))
          (emacsos-assist-web--denied nil)
          (fetches 0))
      (cl-letf (((symbol-function 'emacsos-assist-web--canonical-authorized) #'ignore)
                ((symbol-function 'emacsos-assist-web-git-refresh)
                 (lambda () (cl-incf fetches))))
        (emacsos-assist-web-git--note-snapshot snapshot)
        (emacsos-assist-web-git--note-snapshot snapshot)
        (emacsos-assist-web-git--note-snapshot snapshot "run-1")
        (should (= fetches 2))))))

(ert-deftest test-assist-web-git-reauthorization-retries-once-after-denial ()
  (with-temp-buffer
    (let ((snapshot '((thread . ((id . "thread-1") (status . "ready")
                                  (workspace . ((repo_key . "aaaaaaaaaaaaaaaaaaaa")
                                                (branch . "assist/thread")))))))
          (emacsos-assist-web--denied nil)
          (fetches 0))
      (cl-letf (((symbol-function 'emacsos-assist-web--canonical-authorized) #'ignore)
                ((symbol-function 'emacsos-assist-web-git-refresh)
                 (lambda () (cl-incf fetches))))
        (emacsos-assist-web-git--note-snapshot snapshot)
        (setq emacsos-assist-web--denied t)
        (emacsos-assist-web-git--invalidate "authentication denied")
        (setq emacsos-assist-web--denied nil)
        (emacsos-assist-web-git--note-snapshot snapshot)
        (emacsos-assist-web-git--note-snapshot snapshot)
        (should (= fetches 2))))))

(provide 'test-assist-web-git)
;;; test-assist-web-git.el ends here
