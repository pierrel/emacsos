;;; test-assist-web.el --- Tests for the Assist Web client -*- lexical-binding: t -*-

(require 'ert)
(require 'assist-web)

(ert-deftest test-assist-web-normalize-title-strips-only-leading-pictographs ()
  (should (equal (emacos-assist-web-normalize-title "🧪  Release #42")
                 "Release #42"))
  ;; Symbols that carry meaning are not pictographs and must keep matching.
  (should (equal (emacos-assist-web-normalize-title "#urgent fix") "#urgent fix"))
  (should (equal (emacos-assist-web-normalize-title "!important") "!important")))

(ert-deftest test-assist-web-completion-matches-normalized-title-and-keeps-identity ()
  (let* ((emacos-assist-web--catalog
          '(((id . "thread-1") (description . "🧪 Release check")
             (repo_label . "Assist"))))
         (records (emacos-assist-web--completion-records))
         (table (emacos-assist-web--completion-table records))
         (matches (all-completions "release" table)))
    (should (equal matches '("*assist 🧪 Release check - Assist*")))
    (should (equal (alist-get 'id (plist-get (car records) :thread)) "thread-1"))))

(ert-deftest test-assist-web-local-file-is-contained-in-workspace ()
  (let ((workspace (make-temp-file "assist-web-workspace-" t)))
    (unwind-protect
        (with-temp-buffer
          (setq emacos-assist-web--workspace workspace)
          (should (equal (emacos-assist-web--safe-local-file "notes.md")
                         (expand-file-name "notes.md" workspace)))
          (should-not (emacos-assist-web--safe-local-file "../outside"))
          (should-not (emacos-assist-web--safe-local-file "/etc/passwd")))
      (delete-directory workspace t))))

(ert-deftest test-assist-web-snapshot-cache-creates-its-nested-directory ()
  (let ((emacos-assist-web-cache-directory (make-temp-file "assist-web-cache-" t)))
    (unwind-protect
        (progn
          (emacos-assist-web--write-cache "threads/thread-1.json" '((messages . nil)))
          (should (file-exists-p
                   (expand-file-name "threads/thread-1.json" emacos-assist-web-cache-directory)))
          (should (= (logand (file-modes emacos-assist-web-cache-directory) #o777) #o700)))
      (delete-directory emacos-assist-web-cache-directory t))))

(ert-deftest test-assist-web-event-parser-delivers-a-complete-sse-record ()
  (let ((target (generate-new-buffer " *assist-web-target*"))
        (source (generate-new-buffer " *assist-web-source*"))
        seen)
    (unwind-protect
        (progn
          (with-current-buffer source
            (insert "event: terminal\ndata: {}\n\n")
            (setq-local url-http-end-of-headers (copy-marker (point-min)))
            (setq emacos-assist-web--stream-buffer target)
            (cl-letf
                (((symbol-function 'emacos-assist-web--dispatch-event)
                  (lambda (event data)
                    (setq seen (list event data)))))
              (emacos-assist-web--drain-events)))
          (should (equal seen '("terminal" "{}"))))
      (kill-buffer target)
      (kill-buffer source))))

(ert-deftest test-assist-web-render-preserves-a-next-draft ()
  (let ((emacos-assist-web-cache-directory (make-temp-file "assist-web-render-" t))
        (snapshot '((thread . ((id . "thread-1") (description . "Thread")
                               (status . "ready")
                               (workspace . ((repo_label . "Assist") (branch . "assist/x")))))
                    (messages . (((id . "m-1") (role . "assistant") (text . "old")))))))
    (unwind-protect
        (with-temp-buffer
          (emacos-assist-web-mode)
          (emacos-assist-web--render snapshot)
          (insert "next draft")
          (emacos-assist-web--render snapshot)
          (should (equal (emacos-assist-web--input) "next draft")))
      (delete-directory emacos-assist-web-cache-directory t))))

(ert-deftest test-assist-web-new-draft-has-no-server-thread-before-send ()
  (let ((cache '((repositories . (((repo_key . "repo-key") (label . "Assist"))))
                 (harnesses . (((key . "deepagents") (label . "Deep Agents")))))))
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
              (should (equal emacos-assist-web--draft-repository "repo-key"))
              (should (equal emacos-assist-web--draft-harness "deepagents")))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(ert-deftest test-assist-web-workspace-snapshot-keeps-the-server-branch-name ()
  (let* ((emacos-assist-web-cache-directory (make-temp-file "assist-web-cache-" t))
         (source (make-temp-file "assist-web-source-" t))
         (archive (make-temp-file "assist-web-archive-" nil ".tar.gz"))
         (done nil) workspace problem)
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "notes.md" source) (insert "hello"))
          (should (eq 0 (call-process "tar" nil nil nil "-czf" archive "-C" source ".")))
          (emacos-assist-web--extract-workspace-async
           archive "thread-1" "assist/demo"
           (lambda (result error) (setq workspace result problem error done t)))
          (dotimes (_ 100)
            (unless done (accept-process-output nil 0.05)))
          (should done)
          (should-not problem)
          (should (equal (with-temp-buffer
                           (insert-file-contents (expand-file-name "notes.md" workspace))
                           (buffer-string))
                         "hello"))
          (when (executable-find "git")
            (should (equal (string-trim (with-temp-buffer
                                          (call-process "git" nil t nil "-C" workspace
                                                        "branch" "--show-current")
                                          (buffer-string)))
                           "assist/demo"))))
      (when (file-exists-p archive) (delete-file archive))
      (when (file-directory-p source) (delete-directory source t))
      (when (file-directory-p emacos-assist-web-cache-directory)
        (delete-directory emacos-assist-web-cache-directory t)))))

(provide 'test-assist-web)
;;; test-assist-web.el ends here
