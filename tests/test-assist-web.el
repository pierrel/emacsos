;;; test-assist-web.el --- Tests for the Assist Web client -*- lexical-binding: t -*-

(require 'ert)
(require 'assist-web)

(defconst test-assist-web--snapshot
  '((thread . ((id . "thread-1") (description . "Thread")
               (status . "ready")
               (workspace . ((repo_label . "Assist")))))
    (messages . (((id . "m-1") (role . "assistant") (text . "old"))))
    (has_older_messages . t)
    (next_before . "cursor-1")))

(ert-deftest test-assist-web-normalize-title-strips-only-leading-pictographs ()
  (should (equal (emacos-assist-web-normalize-title "🧪  Release #42")
                 "Release #42"))
  (should (equal (emacos-assist-web-normalize-title "#urgent fix") "#urgent fix"))
  (should (equal (emacos-assist-web-normalize-title "!important") "!important")))

(ert-deftest test-assist-web-completion-matches-normalized-title-and-keeps-identity ()
  (let* ((emacos-assist-web--catalog
          '(((id . "thread-1") (description . "🧪 Release check")
             (repo_label . "Assist") (status . "ready"))))
         (records (emacos-assist-web--completion-records))
         (table (emacos-assist-web--completion-table records)))
    (should (equal (all-completions "release" table)
                   '("*assist 🧪 Release check - Assist* [ready]")))
    (should (equal (alist-get 'id (plist-get (car records) :thread)) "thread-1"))))

(ert-deftest test-assist-web-completion-marks-cached-source-and-state ()
  (let* ((emacos-assist-web--catalog-stale t)
         (emacos-assist-web--catalog
          '(((id . "thread-1") (description . "Thread")
             (repo_label . "Assist") (status . "running"))))
         (record (car (emacos-assist-web--completion-records))))
    (should (equal (plist-get record :display)
                   "*assist Thread - Assist* [running, cached]"))))

(ert-deftest test-assist-web-cache-rejects-an-oversized-record ()
  (let ((emacos-assist-web-cache-directory (make-temp-file "assist-web-cache-" t))
        (emacos-assist-web-max-cache-bytes 8))
    (unwind-protect
        (should-error (emacos-assist-web--write-cache "threads.json" '((x . "too long"))))
      (delete-directory emacos-assist-web-cache-directory t))))

(ert-deftest test-assist-web-rejects-an-untrusted-thread-id-before-it-reaches-cache-path ()
  (should-error (emacos-assist-web--snapshot-cache-name "../../outside"))
  (should (equal (emacos-assist-web--snapshot-cache-name "thread-1")
                 "threads/thread-1.json")))

(ert-deftest test-assist-web-event-parser-keeps-target-outside-response-buffer ()
  (let ((target (generate-new-buffer " *assist-web-target*"))
        (source (generate-new-buffer " *assist-web-source*"))
        seen)
    (unwind-protect
        (with-current-buffer source
          (insert "event: terminal\ndata: {}\n\n")
          (setq-local url-http-end-of-headers (copy-marker (point-min)))
          (cl-letf (((symbol-function 'emacos-assist-web--dispatch-event)
                     (lambda (actual-target event data)
                       (setq seen (list actual-target event data)))))
            (emacos-assist-web--drain-events target 0))
          (should (equal seen (list target "terminal" "{}"))))
      (when (buffer-live-p target) (kill-buffer target))
      (when (buffer-live-p source) (kill-buffer source)))))

(ert-deftest test-assist-web-terminal-event-keeps-response-buffer-alive-through-drain ()
  (let ((target (generate-new-buffer " *assist-web-target*"))
        (source (generate-new-buffer " *assist-web-source*")))
    (unwind-protect
        (progn
          (with-current-buffer target
            (emacos-assist-web-mode)
            (setq-local emacos-assist-web--stream-response source))
          (with-current-buffer source
            (insert "event: terminal\ndata: {}\n\n")
            (setq-local url-http-end-of-headers (copy-marker (point-min)))
            (emacos-assist-web--drain-events target 0))
          (should (buffer-live-p source)))
      (when (buffer-live-p target) (kill-buffer target))
      (when (buffer-live-p source) (kill-buffer source)))))

(ert-deftest test-assist-web-event-parser-bounds-each-record-not-whole-callback ()
  (let ((target (generate-new-buffer " *assist-web-target*"))
        (source (generate-new-buffer " *assist-web-source*"))
        (emacos-assist-web-max-event-bytes 32)
        seen)
    (unwind-protect
        (with-current-buffer source
          (insert "event: status\ndata: {}\n\nevent: status\ndata: {}\n\n")
          (setq-local url-http-end-of-headers (copy-marker (point-min)))
          (cl-letf (((symbol-function 'emacos-assist-web--dispatch-event)
                     (lambda (_target event _data) (push event seen))))
            (emacos-assist-web--drain-events target 0))
          (should (equal seen '("status" "status"))))
      (when (buffer-live-p target) (kill-buffer target))
      (when (buffer-live-p source) (kill-buffer source)))))

(ert-deftest test-assist-web-raw-filter-rejects-encoded-response-before-url-filter ()
  (let (forwarded rejected)
    (funcall
     (emacos-assist-web--guarded-filter
      (lambda (&rest _) (setq forwarded t))
      (lambda (_process problem) (setq rejected problem)))
     nil "HTTP/1.1 200 OK\r\nContent-Encoding: gzip\r\n\r\ncompressed")
    (should-not forwarded)
    (should (equal rejected "Assist Web encoded responses are not accepted"))))

(ert-deftest test-assist-web-json-request-disables-redirects-and-encoding ()
  (let ((emacos-assist-web--requests nil)
        (response (generate-new-buffer " *assist-web-request*"))
        encoding)
    (unwind-protect
        (cl-letf (((symbol-function 'emacos-assist-web--read-token)
                   (lambda () "token"))
                  ((symbol-function 'url-retrieve)
                   (lambda (&rest _)
                     (setq encoding url-mime-encoding-string)
                     response))
                  ((symbol-function 'run-at-time) (lambda (&rest _) nil)))
          (emacos-assist-web--request "GET" "threads" nil #'ignore)
          (with-current-buffer response
            (should (= url-max-redirections 0)))
          (should (equal encoding "identity")))
      (when (buffer-live-p response) (kill-buffer response)))))

(ert-deftest test-assist-web-json-request-has-a-global-concurrency-bound ()
  (let ((emacos-assist-web--requests '(one two))
        (emacos-assist-web-max-concurrent-requests 2)
        result)
    (cl-letf (((symbol-function 'emacos-assist-web--read-token)
               (lambda () "token")))
      (emacos-assist-web--request
       "GET" "threads" nil
       (lambda (value error) (setq result (list value error)))))
    (should (equal result
                   '(nil "Too many Assist Web requests are already running")))))

(ert-deftest test-assist-web-raw-filter-bounds-an-unterminated-header ()
  (let ((emacos-assist-web-max-header-bytes 8) forwarded rejected)
    (funcall
     (emacos-assist-web--guarded-filter
      (lambda (&rest _) (setq forwarded t))
      (lambda (_process problem) (setq rejected problem))
      t)
     nil "HTTP/1.1 200")
    (should-not forwarded)
    (should (equal rejected "Assist Web response headers are too large"))))

(ert-deftest test-assist-web-header-bound-does-not-count-same-chunk-body ()
  (let ((emacos-assist-web-max-header-bytes 32) forwarded rejected)
    (funcall
     (emacos-assist-web--guarded-filter
      (lambda (&rest _) (setq forwarded t))
      (lambda (_process problem) (setq rejected problem))
      t)
     nil (concat "HTTP/1.1 200 OK\r\n\r\n" (make-string 128 ?x)))
    (should forwarded)
    (should-not rejected)))

(ert-deftest test-assist-web-render-preserves-draft-and-updates-status-in-place ()
  (let ((emacos-assist-web-cache-directory (make-temp-file "assist-web-render-" t)))
    (unwind-protect
        (with-temp-buffer
          (emacos-assist-web-mode)
          (emacos-assist-web--render test-assist-web--snapshot t)
          (insert "next draft")
          (emacos-assist-web--set-status "running")
          (should (equal (emacos-assist-web--input) "next draft"))
          (should (string-match-p "\\[running\\]" (buffer-string)))
          (should (string-match-p "\\[cached\\]" (buffer-string))))
      (delete-directory emacos-assist-web-cache-directory t))))

(ert-deftest test-assist-web-render-rejects-a-mismatched-snapshot-identity ()
  (with-temp-buffer
    (emacos-assist-web-mode)
    (setq emacos-assist-web--thread-id "thread-1")
    (should-error
     (emacos-assist-web--render
      '((thread . ((id . "thread-2") (description . "Wrong")
                   (status . "ready") (workspace . nil)))
        (messages . nil))))))

(ert-deftest test-assist-web-invalid-cached-retry-key-is-not-restored ()
  (with-temp-buffer
    (emacos-assist-web-mode)
    (setq emacos-assist-web--thread-id "thread-1")
    (emacos-assist-web--write-prompt)
    (cl-letf (((symbol-function 'emacos-assist-web--read-cache)
               (lambda (&rest _)
                 '((text . "draft") (pending_key . "bad\r\nInjected: yes")
                   (submitted_text . "draft")))))
      (emacos-assist-web--restore-draft))
    (should-not emacos-assist-web--pending-key)
    (should-not emacos-assist-web--submitted-text)
    (should (equal (emacos-assist-web--input) "draft"))))

(ert-deftest test-assist-web-editing-after-a-failed-send-mints-a-new-retry-identity ()
  (with-temp-buffer
    (emacos-assist-web-mode)
    (setq emacos-assist-web--pending-key "old-key"
          emacos-assist-web--submitted-text "old")
    (emacos-assist-web--write-prompt)
    (insert "new")
    (emacos-assist-web--after-change)
    (should-not emacos-assist-web--pending-key)
    (should-not emacos-assist-web--submitted-text)))

(ert-deftest test-assist-web-interrupted-observation-retains-the-exact-retry ()
  (with-temp-buffer
    (emacos-assist-web-mode)
    (emacos-assist-web--write-prompt)
    (setq emacos-assist-web--pending-key "retry-key"
          emacos-assist-web--submitted-text "message"
          emacos-assist-web--in-flight t
          emacos-assist-web--active-buffer (current-buffer))
    (cl-letf (((symbol-function 'emacos-assist-web--save-draft) (lambda () nil)))
      (emacos-assist-web--stream-interrupted (current-buffer) "observation disconnected"))
    (should (equal emacos-assist-web--pending-key "retry-key"))
    (should (equal emacos-assist-web--submitted-text "message"))
    (should-not emacos-assist-web--in-flight)
    (should (equal emacos-assist-web--stream-status "observation disconnected"))))

(ert-deftest test-assist-web-history-merges-chronologically-and-keeps-page-cursor ()
  (let ((emacos-assist-web-cache-directory (make-temp-file "assist-web-history-" t))
        (written nil)
        (snapshot (copy-tree test-assist-web--snapshot))
        (page '((messages . (((id . "m-0") (role . "user") (text . "older"))))
                (has_older_messages . t) (next_before . "cursor-0"))))
    (unwind-protect
        (with-temp-buffer
          (emacos-assist-web-mode)
          (setq emacos-assist-web--thread-id "thread-1")
          (cl-letf (((symbol-function 'emacos-assist-web--read-cache)
                     (lambda (&rest _) snapshot))
                    ((symbol-function 'emacos-assist-web--write-cache)
                     (lambda (_name value) (setq written value)))
                    ((symbol-function 'emacos-assist-web--request)
                     (lambda (method path _payload callback &rest _)
                       (should (equal method "GET"))
                       (should (string-suffix-p "before=cursor-1" path))
                       (funcall callback page nil)))
                    ((symbol-function 'emacos-assist-web--render) (lambda (&rest _) nil)))
            (emacos-assist-web-load-older))
          (should (equal (mapcar (lambda (message) (alist-get 'id message))
                                 (alist-get 'messages written))
                         '("m-0" "m-1")))
          (should (equal (alist-get 'next_before written) "cursor-0")))
      (delete-directory emacos-assist-web-cache-directory t))))

(ert-deftest test-assist-web-newer-refresh-cannot-be-overwritten-by-an-older-response ()
  (let (callbacks written rendered)
    (with-temp-buffer
      (emacos-assist-web-mode)
      (setq emacos-assist-web--thread-id "thread-1")
      (cl-letf (((symbol-function 'emacos-assist-web--request)
                 (lambda (_method _path _payload callback &rest _)
                   (push callback callbacks)))
                ((symbol-function 'emacos-assist-web--write-cache)
                 (lambda (_name value) (setq written value)))
                ((symbol-function 'emacos-assist-web--render)
                 (lambda (value &rest _) (setq rendered value))))
        (emacos-assist-web-refresh-thread)
        (emacos-assist-web-refresh-thread)
        (let ((newer (pop callbacks))
              (older (pop callbacks)))
          (funcall newer test-assist-web--snapshot nil)
          (funcall older
                   '((thread . ((id . "thread-1") (description . "stale")))
                     (messages . nil))
                   nil)))
      (should (equal (alist-get 'description (alist-get 'thread written)) "Thread"))
      (should (equal written rendered)))))

(ert-deftest test-assist-web-reopening-thread-preserves-live-buffer-state ()
  (let* ((thread '((id . "thread-1") (description . "Thread")
                   (repo_label . "Assist") (status . "running")))
         (name (format "%s <thread-1>" (emacos-assist-web--thread-label thread))))
    (cl-letf (((symbol-function 'emacos-assist-web--read-cache) (lambda (&rest _) nil))
              ((symbol-function 'emacos-assist-web-refresh-thread) (lambda (&rest _) nil))
              ((symbol-function 'switch-to-buffer) (lambda (&rest _) nil)))
      (unwind-protect
          (progn
            (emacos-assist-web--show-thread thread)
            (with-current-buffer name
              (setq emacos-assist-web--in-flight t
                    emacos-assist-web--run-id "run-1"))
            (emacos-assist-web--show-thread thread)
            (with-current-buffer name
              (should emacos-assist-web--in-flight)
              (should (equal emacos-assist-web--run-id "run-1"))))
        (when (get-buffer name) (kill-buffer name))))))

(ert-deftest test-assist-web-killing-an-active-buffer-releases-the-global-run-slot ()
  (let ((emacos-assist-web--active-buffer nil)
        (buffer (generate-new-buffer " *assist-web-active*")))
    (with-current-buffer buffer
      (emacos-assist-web-mode)
      (setq-local emacos-assist-web--in-flight t)
      (setq emacos-assist-web--active-buffer buffer))
    (kill-buffer buffer)
    (should-not emacos-assist-web--active-buffer)))

(ert-deftest test-assist-web-new-draft-has-no-server-thread-before-send ()
  (let ((cache '((repositories . (((repo_key . "repo-key")
                                   (label . "Assist"))))
                 (harnesses . (((key . "deepagents")
				(label . "Deep Agents")))))))
    (cl-letf (((symbol-function 'emacos-assist-web--read-cache) (lambda (&rest _) cache))
              ((symbol-function 'completing-read)
               (lambda (prompt &rest _) (if (string-prefix-p "Harness" prompt)
                                            "Deep Agents" "Assist")))
              ((symbol-function 'switch-to-buffer) (lambda (&rest _) nil)))
      (emacos-assist-web-new-thread)
      (let ((buffer (get-buffer "*assist New thread*")))
        (unwind-protect
            (with-current-buffer buffer
              (should (derived-mode-p 'emacos-assist-web-mode))
              (should-not emacos-assist-web--thread-id)
              (should (equal emacos-assist-web--draft-repository "repo-key")))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest test-assist-web-new-thread-fetches-catalog-with-no-existing-thread ()
  (let ((catalog '((threads . nil)
                   (repositories . (((repo_key . "repo-key")
                                     (label . "Assist"))))
                   (harnesses . (((key . "deepagents")
                                  (label . "Deep Agents")))))))
    (cl-letf (((symbol-function 'emacos-assist-web--read-cache) (lambda (&rest _) nil))
              ((symbol-function 'emacos-assist-web--request)
               (lambda (method path _payload callback &rest _)
                 (should (equal method "GET"))
                 (should (equal path "threads"))
                 (funcall callback catalog nil)))
              ((symbol-function 'emacos-assist-web--write-cache) (lambda (&rest _) nil))
              ((symbol-function 'completing-read)
               (lambda (prompt &rest _) (if (string-prefix-p "Harness" prompt)
                                            "Deep Agents" "Assist")))
              ((symbol-function 'switch-to-buffer) (lambda (&rest _) nil)))
      (emacos-assist-web-new-thread)
      (let ((buffer (get-buffer "*assist New thread*")))
        (unwind-protect
            (with-current-buffer buffer
              (should (derived-mode-p 'emacos-assist-web-mode))
              (should (equal emacos-assist-web--draft-repository "repo-key")))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest test-assist-web-first-open-shows-visible-retryable-loading-failure ()
  (let ((emacos-assist-web--catalog nil))
    (cl-letf (((symbol-function 'emacos-assist-web--read-cache) (lambda (&rest _) nil))
              ((symbol-function 'emacos-assist-web--request)
               (lambda (_method _path _payload callback &rest _)
                 (funcall callback nil "offline"))))
      (emacos-assist-web-open-thread)
      (let ((buffer (get-buffer "*assist Threads*")))
        (unwind-protect
            (with-current-buffer buffer
              (should (string-match-p "could not be loaded" (buffer-string)))
              (should (string-match-p "C-c C-a r" (buffer-string))))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest test-assist-web-has-one-step-two-command-prefix ()
  (should (keymapp (lookup-key (current-global-map) (kbd "C-c C-a"))))
  (dolist (binding '(("C-c C-a t" . emacos-assist-web-open-thread)
                     ("C-c C-a n" . emacos-assist-web-new-thread)
                     ("C-c C-a r" . emacos-assist-web-refresh-threads)
                     ("C-c C-a s" . emacos-assist-web-send)
                     ("C-c C-a o" . emacos-assist-web-load-older)
                     ("C-c C-a a" . emacos-assist-web-abort)))
    (should (eq (key-binding (kbd (car binding))) (cdr binding))))
  (dolist (key '("C-c C-a d" "C-c C-a f" "C-c C-a p" "C-c C-a i"))
    (should-not (key-binding (kbd key)))))

(ert-deftest test-assist-web-abort-cleans-up-and-refreshes ()
  (with-temp-buffer
    (emacos-assist-web-mode)
    (setq emacos-assist-web--thread-id "thread-1"
          emacos-assist-web--run-id "run-1"
          emacos-assist-web--in-flight t)
    (let (request refreshed)
      (cl-letf (((symbol-function 'emacos-assist-web--request)
                 (lambda (method path _payload callback &rest _)
                   (setq request (list method path))
                   (funcall callback nil nil)))
                ((symbol-function 'emacos-assist-web-refresh-thread)
                 (lambda (&optional buffer) (setq refreshed buffer))))
        (emacos-assist-web-abort))
      (should (equal request '("DELETE" "threads/thread-1/runs/run-1")))
      (should (eq refreshed (current-buffer)))
      (should-not emacos-assist-web--in-flight))))

(ert-deftest test-assist-web-abort-during-post-cannot-target-an-old-run ()
  (with-temp-buffer
    (emacos-assist-web-mode)
    (setq emacos-assist-web--thread-id "thread-1"
          emacos-assist-web--run-id "old-run")
    (emacos-assist-web--write-prompt)
    (insert "hello")
    (let (requests)
      (cl-letf (((symbol-function 'emacos-assist-web--request)
                 (lambda (method path _payload _callback &rest _)
                   (push (list method path) requests)))
                ((symbol-function 'emacos-assist-web--save-draft) (lambda () nil)))
        (emacos-assist-web-send)
        (emacos-assist-web-abort))
      (should (equal requests '(("POST" "threads/thread-1/messages"))))
      (should-not emacos-assist-web--run-id)
      (should emacos-assist-web--in-flight))))

(ert-deftest test-assist-web-stale-post-callback-cannot-replace-a-newer-send ()
  (let ((emacos-assist-web--active-buffer nil))
    (with-temp-buffer
      (emacos-assist-web-mode)
      (setq emacos-assist-web--thread-id "thread-1")
      (emacos-assist-web--write-prompt)
      (insert "hello")
      (let (callbacks observed)
	(cl-letf (((symbol-function 'emacos-assist-web--request)
                   (lambda (_method _path _payload callback &rest _)
                     (setq callbacks (append callbacks (list callback)))))
                  ((symbol-function 'emacos-assist-web--save-draft) (lambda () nil))
                  ((symbol-function 'emacos-assist-web--observe-run)
                   (lambda (_buffer) (setq observed t))))
          (emacos-assist-web-send)
          (setq emacos-assist-web--in-flight nil
		emacos-assist-web--active-buffer nil)
          (emacos-assist-web-send)
          (funcall (car callbacks)
                   '((thread_id . "thread-1") (run_id . "stale-run")) nil)
          (should-not emacos-assist-web--run-id)
          (should-not observed)
          (funcall (cadr callbacks)
                   '((thread_id . "thread-1") (run_id . "current-run")) nil)
          (should (equal emacos-assist-web--run-id "current-run"))
          (should observed))))))

(ert-deftest test-assist-web-invalid-send-response-releases-active-slot-for-retry ()
  (let ((emacos-assist-web--active-buffer nil))
    (with-temp-buffer
      (emacos-assist-web-mode)
      (setq emacos-assist-web--thread-id "thread-1")
      (emacos-assist-web--write-prompt)
      (insert "hello")
      (let (callback)
        (cl-letf (((symbol-function 'emacos-assist-web--request)
                   (lambda (_method _path _payload cb &rest _) (setq callback cb)))
                  ((symbol-function 'emacos-assist-web--save-draft) (lambda () nil)))
          (emacos-assist-web-send)
          (funcall callback
                   '((thread_id . "../../wrong") (run_id . "run-1")) nil))
        (should-not emacos-assist-web--in-flight)
        (should-not emacos-assist-web--active-buffer)
        (should (equal emacos-assist-web--thread-id "thread-1"))
        (should-not emacos-assist-web--run-id)
        (should emacos-assist-web--pending-key)))))

(ert-deftest test-assist-web-global-send-outside-thread-is-a-safe-noop ()
  (with-temp-buffer
    (emacos-assist-web-send)
    (should-not emacos-assist-web--in-flight)))

(ert-deftest test-assist-web-replayed-send-does-not-duplicate-local-pending-text ()
  (with-temp-buffer
    (emacos-assist-web-mode)
    (setq emacos-assist-web--thread-id "thread-1"
          emacos-assist-web--pending-key
          "emacsos-0123456789abcdef0123456789abcdef"
          emacos-assist-web--submitted-text "hello")
    (emacos-assist-web--write-prompt)
    (emacos-assist-web--append-pending "hello")
    (let (callback refreshed observed)
      (cl-letf (((symbol-function 'emacos-assist-web--request)
                 (lambda (_method _path _payload cb &rest _) (setq callback cb)))
                ((symbol-function 'emacos-assist-web--save-draft) (lambda () nil))
                ((symbol-function 'emacos-assist-web-refresh-thread)
                 (lambda (&rest _) (setq refreshed t)))
                ((symbol-function 'emacos-assist-web--observe-run)
                 (lambda (&rest _) (setq observed t))))
        (emacos-assist-web-send)
        (funcall callback
                 '((thread_id . "thread-1") (run_id . "run-1") (replayed . t)) nil))
      (goto-char (point-min))
      (should (= (how-many "you> hello" (point-min) (point-max)) 1))
      (should refreshed)
      (should observed))))

(provide 'test-assist-web)
;;; test-assist-web.el ends here
