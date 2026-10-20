;;; test-assist-web-git.el --- Ordinary thread checkout behavior -*- lexical-binding: t -*-

(require 'ert)
(require 'cl-lib)
(require 'assist-web-git)
(require 'assist-web)

(defconst test-assist-web-git--metadata
  '(:tid "thread-1" :repo-key "aaaaaaaaaaaaaaaaaaaa"
    :branch "assist/thread" :status "ready"))

(ert-deftest test-assist-web-git-phone-header-keeps-both-touch-actions-visible ()
  "Narrow phone headers preserve Status, Merge and a clickable Run action."
  (with-temp-buffer
    (cl-letf (((symbol-function 'window-body-width) (lambda (&rest _) 40))
              ((symbol-function 'emacsos-assist-web-git--thread-header)
               (lambda () "Git branch and long published commit")))
      (dolist (run (list nil (concat (emacsos-assist-web--padded-action
                                      "Review" #'emacsos-assist-web-review-approval)
                                   (emacsos-assist-web--details-link))))
        (cl-letf (((symbol-function 'emacsos-assist-web--lifecycle-header)
                   (lambda () run)))
          (let* ((header (emacsos-assist-web--thread-header))
                 (merge (string-match "\\[Merge\\]" header)))
            (should (string-match "\\[Status\\]" header))
            (should merge)
            (should (<= (string-width header) 40))
            (should-not (string-match "\\[Git\\]" header))
            (when run
              (let* ((review (string-match "\\[Review\\]" header))
                     (map (and review (get-text-property review 'local-map header))))
                (should review)
                (should (eq (lookup-key map [header-line mouse-1])
                            #'emacsos-assist-web-review-approval))))))))))

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

(ert-deftest test-assist-web-git-status-keeps-checkout-and-help-touch-controls ()
  "Compact headers lead to reachable checkout refresh and Git details."
  (let ((source (generate-new-buffer " *assist-git-controls-source*"))
        (view (generate-new-buffer " *assist-git-controls-view*"))
        actions)
    (unwind-protect
        (progn
          (with-current-buffer source
            (setq-local emacsos-assist-web--thread-id "thread-1"
                        emacsos-assist-web-git--metadata test-assist-web-git--metadata))
          (with-current-buffer view
            (special-mode)
            (setq-local emacsos-assist-web-git--status-source source
                        emacsos-assist-web-git--status-identity
                        '("thread-1" . "aaaaaaaaaaaaaaaaaaaa"))
            (emacsos-assist-web-git--status-render)
            (cl-letf (((symbol-function 'emacsos-assist-web-git-refresh)
                       (lambda () (push (cons 'refresh (current-buffer)) actions)))
                      ((symbol-function 'emacsos-assist-web-git-thread-details)
                       (lambda () (push (cons 'details (current-buffer)) actions))))
              (goto-char (point-min))
              (search-forward "Refresh checkout")
              (button-activate (button-at (1- (point))))
              (goto-char (point-min))
              (search-forward "Git details")
              (button-activate (button-at (1- (point)))))
            (should (equal actions (list (cons 'details source)
                                         (cons 'refresh source))))))
      (kill-buffer view)
      (kill-buffer source))))

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
                       (lambda (method path _body callback &rest options)
                         (setq requested (list method path options))
                         (funcall callback nil '(:kind transport)))))
              (emacsos-assist-web-git--status-refresh))
            (should (equal requested
                           '("GET" "threads/thread-1/git" (nil nil nil nil t))))
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
            (dolist (navigation '(scroll-up-command forward-button
                                backward-button next-line))
              (let ((this-command navigation))
                (emacsos-assist-web-git--merge-pre-command))
              (should emacsos-assist-web-git--status-armed))
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

(ert-deftest test-assist-web-git-armed-navigation-never-shortcut-confirms ()
  "Scroll or TAB may reveal Confirm, but the Merge shortcut cannot submit."
  (let ((source (generate-new-buffer " *assist-git-shortcut-source*"))
        (view (generate-new-buffer " *assist-git-shortcut-view*"))
        submitted)
    (unwind-protect
        (progn
          (with-current-buffer source
            (setq-local emacsos-assist-web--thread-id "thread-1"
                        emacsos-assist-web-git--metadata test-assist-web-git--metadata))
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
            (let ((this-command 'forward-button))
              (emacsos-assist-web-git--merge-pre-command))
            (forward-button 1)
            (should (eq (button-get (button-at (point)) 'action)
                        #'emacsos-assist-web-git--status-action))
            (goto-char (point-min))
            (cl-letf (((symbol-function 'emacsos-assist-web-git--status-confirm)
                       (lambda () (setq submitted t))))
              (emacsos-assist-web-git-merge))
            (should-not submitted)
            (should emacsos-assist-web-git--status-armed)
            (should (looking-at "Confirm branch:"))))
      (emacsos-assist-web-git--disarm-status)
      (kill-buffer view)
      (kill-buffer source))))

(ert-deftest test-assist-web-git-open-status-binds-tab-navigation ()
  "Status TAB navigation does not alter unrelated special-mode buffers."
  (let ((source (generate-new-buffer " *assist-git-tab-source*"))
        (view nil)
        (ordinary (generate-new-buffer " *assist-git-ordinary-special*"))
        (original-tab (lookup-key special-mode-map (kbd "TAB")))
        (original-backtab (lookup-key special-mode-map (kbd "<backtab>"))))
    (unwind-protect
        (progn
          (with-current-buffer source
            (setq-local emacsos-assist-web--thread-id "thread-tab"
                        emacsos-assist-web-git--metadata
                        '(:tid "thread-tab" :repo-key "aaaaaaaaaaaaaaaaaaaa"
                          :branch "assist/thread" :status "ready"))
            (cl-letf (((symbol-function 'emacsos-assist-web-git--status-refresh)
                       #'ignore)
                      ((symbol-function 'pop-to-buffer) #'ignore))
              (emacsos-assist-web-git--open-status)))
          (setq view (get-buffer "*Assist Git thread-tab*"))
          (should view)
          (with-current-buffer view
            (should (eq (key-binding (kbd "TAB")) #'forward-button))
            (should (eq (key-binding (kbd "<backtab>")) #'backward-button))
            (should-not (eq (current-local-map) special-mode-map)))
          (with-current-buffer ordinary
            (special-mode)
            (should (equal (lookup-key (current-local-map) (kbd "TAB"))
                           original-tab))
            (should (equal (lookup-key (current-local-map) (kbd "<backtab>"))
                           original-backtab))))
      (when (buffer-live-p view) (kill-buffer view))
      (kill-buffer ordinary)
      (kill-buffer source))))

(ert-deftest test-assist-web-git-disarm-keeps-other-button-target ()
  "An unrelated button click stays on that button after disarming."
  (let ((source (generate-new-buffer " *assist-git-target-source*"))
        (view (generate-new-buffer " *assist-git-target-view*"))
        refreshed)
    (unwind-protect
        (progn
          (with-current-buffer source
            (setq-local emacsos-assist-web--thread-id "thread-1"
                        emacsos-assist-web-git--metadata test-assist-web-git--metadata))
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
            (goto-char (point-min))
            (search-forward "Refresh checkout")
            (backward-char)
            (let ((this-command 'push-button))
              (emacsos-assist-web-git--merge-pre-command))
            (should-not emacsos-assist-web-git--status-armed)
            (cl-letf (((symbol-function 'emacsos-assist-web-git-refresh)
                       (lambda () (setq refreshed (current-buffer)))))
              (button-activate (button-at (point))))
            (should (eq refreshed source))))
      (emacsos-assist-web-git--disarm-status)
      (kill-buffer view)
      (kill-buffer source))))

(ert-deftest test-assist-web-git-denial-survives-new-request-and-dead-origin ()
  "A newer request is not authority; a live peer still receives denial."
  (let ((origin (generate-new-buffer " *assist-git-dead-origin*"))
        (peer (generate-new-buffer " *assist-git-dead-peer*"))
        owner)
    (unwind-protect
        (progn
          (dolist (buffer (list origin peer))
            (with-current-buffer buffer
              (setq-local emacsos-assist-web--thread-id "thread-auth-dead")))
          (with-current-buffer origin
            (let ((record (emacsos-assist-web--thread-safety-record
                           "thread-auth-dead" t)))
              (setq owner (cons record 1))))
          ;; Starting another Git GET, even one that fails locally, does not
          ;; establish new authorization or discard the first denial.
          (with-current-buffer peer
            (emacsos-assist-web--thread-safety-record "thread-auth-dead" t))
          (kill-buffer origin)
          (should (emacsos-assist-web--http-access-status
                   origin "GET" "threads/thread-auth-dead/git"
                   403 nil nil "thread-auth-dead" owner))
          (should (eq (buffer-local-value 'emacsos-assist-web--denied peer) t)))
      (when (buffer-live-p origin) (kill-buffer origin))
      (when (buffer-live-p peer) (kill-buffer peer)))))

(ert-deftest test-assist-web-git-reauthorization-supersedes-old-denial ()
  "Only a validated canonical reauthorization retires the old Git GET."
  (with-temp-buffer
    (setq-local emacsos-assist-web--thread-id "thread-auth-renew")
    (let* ((record (emacsos-assist-web--thread-safety-record
                    "thread-auth-renew" t))
           (owner (cons record 1))
           (emacsos-assist-web--current-canonical-get-owner (cons record 2)))
      (setf (plist-get record :denial) 403)
      (setq emacsos-assist-web--denied t)
      (emacsos-assist-web--canonical-authorized emacsos-assist-web--auth-epoch)
      (should-not (plist-get record :denial))
      (should-not (emacsos-assist-web--http-access-status
                   (current-buffer) "GET" "threads/thread-auth-renew/git"
                   403 nil nil "thread-auth-renew" owner))
      (should-not emacsos-assist-web--denied))))

(ert-deftest test-assist-web-git-new-canonical-success-supersedes-old-get ()
  "A validated canonical GET supersedes an old Git denial even if none landed."
  (with-temp-buffer
    (setq-local emacsos-assist-web--thread-id "thread-auth-rotate")
    (let* ((record (emacsos-assist-web--thread-safety-record
                    "thread-auth-rotate" t))
           (owner (cons record 1))
           (emacsos-assist-web--current-canonical-get-owner (cons record 2)))
      (emacsos-assist-web--canonical-authorized emacsos-assist-web--auth-epoch)
      (should-not (emacsos-assist-web--http-access-status
                   (current-buffer) "GET" "threads/thread-auth-rotate/git"
                   401 nil nil "thread-auth-rotate" owner))
      (should-not emacsos-assist-web--denied))))

(ert-deftest test-assist-web-git-newer-denial-survives-older-canonical-success ()
  "A canonical GET started first cannot retire a later Git GET denial."
  (with-temp-buffer
    (setq-local emacsos-assist-web--thread-id "thread-auth-later-denial")
    (let* ((record (emacsos-assist-web--thread-safety-record
                    "thread-auth-later-denial" t))
           (emacsos-assist-web--current-canonical-get-owner (cons record 1))
           (git-owner (cons record 2)))
      (emacsos-assist-web--canonical-authorized emacsos-assist-web--auth-epoch)
      (should (emacsos-assist-web--http-access-status
               (current-buffer) "GET" "threads/thread-auth-later-denial/git"
               403 nil nil "thread-auth-later-denial" git-owner))
      (should (eq emacsos-assist-web--denied t)))))

(ert-deftest test-assist-web-git-denied-get-fences-late-status-callback ()
  "A Git GET denial fences same-thread peers before a late success arrives."
  (let ((source (generate-new-buffer " *assist-git-auth-source*"))
        (peer (generate-new-buffer " *assist-git-auth-peer*"))
        (view (generate-new-buffer " *assist-git-auth-view*"))
        callback)
    (unwind-protect
        (progn
          (dolist (buffer (list source peer))
            (with-current-buffer buffer
              (setq-local emacsos-assist-web--thread-id "thread-auth-1"
                          emacsos-assist-web-git--metadata
                          '(:tid "thread-auth-1" :repo-key "aaaaaaaaaaaaaaaaaaaa"
                            :branch "assist/thread" :status "ready"))))
          (with-current-buffer view
            (special-mode)
            (setq-local emacsos-assist-web-git--status-source source
                        emacsos-assist-web-git--status-identity
                        '("thread-auth-1" . "aaaaaaaaaaaaaaaaaaaa"))
            (cl-letf (((symbol-function 'emacsos-assist-web-git--status-inspect-local)
                       #'ignore)
                      ((symbol-function 'emacsos-assist-web--request)
                       (lambda (_method _path _body fn &rest _) (setq callback fn))))
              (emacsos-assist-web-git--status-refresh))
            (should callback)
            (should (with-current-buffer source
                      (emacsos-assist-web--http-access-status
                       source "GET" "threads/thread-auth-1/git" 403)))
            (should (eq (buffer-local-value 'emacsos-assist-web--denied peer) t))
            (funcall callback
                     '((thread_id . "thread-auth-1")
                       (repo_key . "aaaaaaaaaaaaaaaaaaaa")
                       (branch . "assist/thread")
                       (published_revision . "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
                       (state . "available")
                       (observed_at . "2026-10-18T16:30:00+00:00")) nil)
            (should-not emacsos-assist-web-git--status-fresh)
            (should-not emacsos-assist-web-git--status-armed)
            (should (string-match-p "authorization changed" (buffer-string)))))
      (emacsos-assist-web-git--disarm-status)
      (dolist (buffer (list view peer source))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

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
              (should (looking-at "Confirm branch:"))
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
            (setq emacsos-assist-web-git--status-fresh t)
            (cl-letf (((symbol-function 'emacsos-assist-web--read-token)
                       (lambda () "token"))
                      ((symbol-function 'emacsos-assist-web--trustfiles)
                       (lambda () nil))
                      ((symbol-function 'run-at-time) (lambda (&rest _) nil))
                      ((symbol-function 'url-retrieve)
                       (lambda (_url callback &rest _)
                         (let ((response (generate-new-buffer " *git-merge-conflict*")))
                           (with-current-buffer response
                             (insert "HTTP/1.1 409 Conflict\r\nContent-Type: application/json\r\n\r\n")
                             (setq-local url-http-response-status 409
                                         url-http-content-type "application/json"
                                         url-http-end-of-headers (copy-marker (point)))
                             (insert "{\"outcome\":\"conflict\"}")
                             (funcall callback '(:error (error http 409))))
                           response))))
              (emacsos-assist-web-git--status-arm)
              (emacsos-assist-web-git--status-confirm))
            (should (string-match-p "Server merge conflicted" (buffer-string)))
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
      (should-not (lookup-key emacsos-assist-web-git-thread-mode-map
                              (kbd "C-c d")))
      (should-not (eq (key-binding (kbd "C-c d")) #'emacsos-assist-web-git-diff))
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
          (should-not (eq (key-binding (kbd "C-c d"))
                          #'emacsos-assist-web-git-diff))))

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
