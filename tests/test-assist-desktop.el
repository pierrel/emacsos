;;; test-assist-desktop.el --- Clean desktop entry checks -*- lexical-binding: t -*-

(require 'ert)
(require 'cl-lib)

(defconst test-assist-desktop--global-map (copy-keymap global-map))
(defconst test-assist-desktop--themes custom-enabled-themes)
(defconst test-assist-desktop--processes (process-list))

;; No -L or phone bootstrap: exercise the same standalone file users load.
(load (expand-file-name "../assist-desktop.el"
                        (file-name-directory (or load-file-name buffer-file-name)))
      nil t)

(ert-deftest test-assist-desktop-load-is-client-only ()
  (dolist (feature '(assist-desktop assist-web assist-web-git chat))
    (should (featurep feature)))
  (dolist (feature '(os emacsos-assist network phone-call phone-sms phone-sms-chat))
    (should-not (featurep feature)))
  (should (equal global-map test-assist-desktop--global-map))
  (should (equal custom-enabled-themes test-assist-desktop--themes))
  (should (equal (process-list) test-assist-desktop--processes))
  (should (file-regular-p emacsos-assist-web-git-helper)))

(ert-deftest test-assist-desktop-prefix-opens-list-from-ordinary-buffer ()
  "The phone's canonical Assist shortcuts also work outside desktop chat buffers."
  (let ((emacsos-assist-web--catalog nil)
        (emacsos-assist-web--catalog-state nil)
        (emacsos-assist-web--catalog-refreshing-p nil)
        requested)
    (unwind-protect
        (save-window-excursion
          (with-temp-buffer
            (dolist (binding '(("l" . emacsos-assist-web-show-thread-list)
                               ("t" . emacsos-assist-web-open-thread)
                               ("n" . emacsos-assist-web-new-thread)
                               ("r" . emacsos-assist-web-refresh-threads)))
              (should (eq (key-binding (kbd (concat "C-c a " (car binding))))
                          (cdr binding))))
            (cl-letf (((symbol-function 'emacsos-assist-web--request)
                       (lambda (method path _body callback &rest _args)
                         (setq requested (list method path))
                         (funcall callback nil "Offline shortcut test"))))
              (call-interactively (key-binding (kbd "C-c a l")))
              (should (derived-mode-p 'emacsos-assist-web-thread-list-mode))
              (should (equal requested '("GET" "threads"))))))
      (when-let ((buffer (get-buffer emacsos-assist-web--thread-list-buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest test-assist-desktop-prefix-preserves-unrelated-user-keys ()
  "Desktop shortcuts leave user maps intact and can be disabled."
  (let* ((original (current-global-map))
         (user-map (copy-keymap original))
         (loader (locate-library "assist-desktop")))
    (unwind-protect
        (progn
          (define-key user-map (kbd "C-c a x") #'ignore)
          (define-key user-map (kbd "C-c z") #'forward-char)
          (define-key user-map (kbd "C-c a l") #'backward-char)
          (use-global-map user-map)
          (let ((before (copy-keymap user-map)))
            (load loader nil t)
            (should (equal user-map before)))
          (with-temp-buffer
            (should (eq (key-binding (kbd "C-c a l")) #'emacsos-assist-web-show-thread-list))
            (should (eq (key-binding (kbd "C-c a x")) #'ignore)))
          (emacsos-desktop-assist-mode -1)
          (should (eq (key-binding (kbd "C-c a l")) #'backward-char))
          (should (eq (key-binding (kbd "C-c z")) #'forward-char)))
      (use-global-map original)
      (when (fboundp 'emacsos-desktop-assist-mode)
        (emacsos-desktop-assist-mode 1)))))

(ert-deftest test-assist-desktop-load-reads-preconfigured-catalog ()
  (let ((cache (make-temp-file "assist-desktop-cache-" t))
        (loader (locate-library "assist-desktop")))
    (unwind-protect
        (progn
          (with-temp-file (expand-file-name "threads.json" cache)
            (insert "{\"threads\":[],\"repositories\":[],\"harnesses\":[]}"))
          (set-file-modes (expand-file-name "threads.json" cache) #o600)
          (with-temp-buffer
            (should
             (= 0 (call-process
                   (expand-file-name invocation-name invocation-directory)
                   nil (current-buffer) nil "-Q" "--batch"
                   "--eval" (format "(setq emacsos-assist-web-cache-directory %S)" cache)
                   "--load" loader
                   "--eval"
                   "(unless (and (eq emacsos-assist-web--catalog-state 'cached) (assq 'threads emacsos-assist-web--catalog)) (kill-emacs 1))")))))
      (delete-directory cache t))))

(ert-deftest test-assist-desktop-entry-displays-refresh-failure ()
  (let ((emacsos-assist-web--catalog nil)
        (emacsos-assist-web--catalog-state nil)
        (emacsos-assist-web--catalog-refreshing-p nil)
        (emacsos-assist-web--new-thread-pending-p nil)
        requested)
    (unwind-protect
        (save-window-excursion
          (cl-letf (((symbol-function 'emacsos-assist-web--request)
                     (lambda (method path _body callback &rest _args)
                       (setq requested (list method path))
                       (funcall callback nil "Offline test"))))
            (call-interactively #'emacsos-desktop-assist)
            (should (derived-mode-p 'emacsos-assist-web-thread-list-mode))
            (should (equal requested '("GET" "threads")))
            (should (eq emacsos-assist-web--catalog-state 'refresh-failed))
            (should (string-match-p "Retry" (buffer-string)))
            (should (eq (key-binding (kbd "g"))
                        #'emacsos-assist-web-refresh-threads))))
      (when-let ((buffer (get-buffer emacsos-assist-web--thread-list-buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest test-assist-desktop-empty-list-new-thread-shortcut ()
  (let ((emacsos-assist-web--catalog nil)
        (emacsos-assist-web--catalog-state nil)
        (emacsos-assist-web--catalog-refreshing-p nil)
        (emacsos-assist-web--new-thread-pending-p nil)
        (catalog (make-hash-table :test #'equal))
        started)
    (dolist (field '("threads" "repositories" "harnesses"))
      (puthash field [] catalog))
    (unwind-protect
        (save-window-excursion
          (cl-letf (((symbol-function 'emacsos-assist-web--request)
                     (lambda (_method _path _body callback &rest _args)
                       (funcall callback catalog nil)))
                    ((symbol-function 'emacsos-assist-web--try-write-cache)
                     (lambda (&rest _args) t))
                    ((symbol-function 'emacsos-assist-web-new-thread)
                     (lambda () (interactive) (setq started t))))
            (call-interactively #'emacsos-desktop-assist)
            (should (string-match-p "Use C-c a n" (buffer-string)))
            (should (eq (key-binding (kbd "C-c a n"))
                        #'emacsos-assist-web-new-thread))
            (call-interactively (key-binding (kbd "C-c a n")))
            (should started)))
      (when-let ((buffer (get-buffer emacsos-assist-web--thread-list-buffer-name)))
        (kill-buffer buffer)))))

(ert-deftest test-assist-desktop-conversation-and-git-keys ()
  (with-temp-buffer
    (emacsos-assist-web-mode)
    (should (eq (key-binding (kbd "C-<return>")) #'emacsos-conversation-send))
    (should (eq (alist-get 'send emacsos-conversation-actions)
                #'emacsos-assist-web-send))
    (should (eq (key-binding (kbd "C-x C-f")) #'emacsos-assist-web-find-file))
    (setq-local emacsos-assist-web--thread-id (make-string 32 ?a))
    (emacsos-assist-web-git--sync-keys)
    (should (eq (key-binding (kbd "C-x C-f")) #'emacsos-assist-web-find-file))
    (should (eq (key-binding (kbd "C-c d")) #'emacsos-assist-web-git-diff))
    (should (eq (key-binding (kbd "C-c g")) #'emacsos-assist-web-git-refresh))))

(provide 'test-assist-desktop)
;;; test-assist-desktop.el ends here
