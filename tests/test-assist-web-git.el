;;; test-assist-web-git.el --- Ordinary thread checkout behavior -*- lexical-binding: t -*-

(require 'ert)
(require 'cl-lib)
(require 'assist-web-git)
(require 'assist-web)

(defconst test-assist-web-git--metadata
  '(:tid "thread-1" :repo-key "aaaaaaaaaaaaaaaaaaaa"
    :branch "assist/thread" :status "ready"))

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

(ert-deftest test-assist-web-git-canonical-thread-keys-preserve-file-opener ()
  (with-temp-buffer
      (emacsos-assist-web-mode)
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
    (let ((emacsos-assist-web-git--result '((dirty . t)))
          (status nil) (range nil))
      (cl-letf (((symbol-function 'emacsos-assist-web-git-local-directory)
                 (lambda () "/tmp/checkout/"))
                ((symbol-function 'magit-status-setup-buffer)
                 (lambda (directory) (setq status directory)))
                ((symbol-function 'magit-diff-range)
                 (lambda (revision) (setq range revision)))
                ((symbol-function 'require) (lambda (&rest _) t)))
        (emacsos-assist-web-git-diff)
        (should (equal status "/tmp/checkout/"))
        (should-not range)
        (setq emacsos-assist-web-git--result '((dirty . nil)) status nil)
        (emacsos-assist-web-git-diff)
        (should (equal range "refs/remotes/origin/main...HEAD"))
        (should-not status)))))

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
