;;; assist-web-git.el --- Editable thread checkouts and committed diffs -*- lexical-binding: t -*-
;;; Commentary:
;; This module maintains editable thread checkouts and captured fetch metadata.
;; File views read bounded local worktree paths, not verified committed blobs.

;;; Code:

(require 'cl-lib)
(require 'button)
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
(defvar magit-pre-call-git-hook nil)
(defvar magit-pre-start-git-hook nil)
(declare-function magit-section-toggle "magit-section")

(defgroup emacsos-assist-web-git nil
  "Editable checkouts and captured committed diffs for canonical Assist threads."
  :group 'emacsos-assist-web)

(defcustom emacsos-assist-web-git-cache-directory
  (expand-file-name "~/.cache/emacsos/assist-git")
  "Private metadata root, also containing existing legacy checkouts.
Legacy checkouts stay here until explicitly moved; new workspaces use
`emacsos-assist-web-git-workspace-directory'."
  :type 'directory
  :group 'emacsos-assist-web-git)

(defcustom emacsos-assist-web-git-workspace-directory
  (expand-file-name "~/assist")
  "Root of new user workspaces with frozen readable repository/thread names."
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
  id path metadata oid remote main state views auth-epoch dirty pending)

(defvar-local emacsos-assist-web-git--metadata nil)
(defvar-local emacsos-assist-web-git--current nil)
(defvar-local emacsos-assist-web-git--previous nil)
(defvar-local emacsos-assist-web-git--safe-file-view nil
  "Non-nil when this file visit was initialized without repository-local code.")
(defvar emacsos-assist-web-git--checkout-operations (make-hash-table :test 'equal)
  "In-app advancement/initialization reservations until the helper finishes.")

(defvar-local emacsos-assist-web-git--workspace-choices nil)
(defvar-local emacsos-assist-web-git--workspace-choice nil)

(defun emacsos-assist-web-git--workspace-identity (metadata)
  "Return the stable repository/thread identity, independent of names and ref."
  (secure-hash 'sha256
               (encode-coding-string
                (format "%s\n%s" (plist-get metadata :repo-key)
                        (plist-get metadata :tid)) 'utf-8-unix)))

(defun emacsos-assist-web-git--workspace-slug (value fallback)
  "Return one bounded readable component from VALUE, or FALLBACK."
  (if (not (and (stringp value) (<= (string-bytes value) 4096))) fallback
    (let ((slug (string-trim
                 (replace-regexp-in-string "[^a-z0-9]+" "-" (downcase value))
                 "-+" "-+")))
      (setq slug (string-trim-right (substring slug 0 (min 48 (length slug))) "-+"))
      (if (string-empty-p slug) fallback slug))))

(defun emacsos-assist-web-git--new-checkout-path (metadata)
  "Return the proposed new path; a published binding freezes it permanently."
  (expand-file-name
   (concat (emacsos-assist-web-git--workspace-slug (plist-get metadata :repo-label) "repo")
           "/" (emacsos-assist-web-git--workspace-slug (plist-get metadata :thread-label) "thread")
           "-" (substring (emacsos-assist-web-git--workspace-identity metadata) 0 12))
   emacsos-assist-web-git-workspace-directory))

(defun emacsos-assist-web-git--read-route (route)
  "Read one private bounded ROUTE without invoking Git or reading credentials."
  (let ((attributes (file-attributes route)))
    (unless (and (file-regular-p route) (not (file-symlink-p route))
                 (equal (expand-file-name route) (file-truename route))
                 (eql (file-attribute-user-id attributes) (user-uid))
                 (= (nth 1 attributes) 1) (= (file-modes route) #o600)
                 (<= (file-attribute-size attributes) 2048))
      (user-error "Workspace binding unavailable; local files preserved")))
  (with-temp-buffer
    (insert-file-contents route nil 0 2048)
    (json-parse-buffer :object-type 'plist :array-type 'list
                       :null-object nil :false-object :json-false)))

(defun emacsos-assist-web-git--unique-legacy-binding (route legacy)
  "Refuse another bounded private route claiming this LEGACY workspace."
  (when (file-directory-p (file-name-directory route))
    (let ((routes (directory-files (file-name-directory route) t "\\.json\\'" t 10001)))
      (when (> (length routes) 10000)
        (user-error "Workspace binding inventory exceeds its limit"))
      (dolist (other routes)
        (unless (equal other route)
          (when (equal (plist-get (emacsos-assist-web-git--read-route other) :legacy) legacy)
            (user-error "Workspace has ambiguous thread ownership; local files preserved")))))))

(defun emacsos-assist-web-git--route-path (metadata)
  "Return METADATA's bounded private frozen binding, without starting a process."
  (let ((route (expand-file-name
                (concat "routes/" (emacsos-assist-web-git--workspace-identity metadata) ".json")
                emacsos-assist-web-git-cache-directory)))
    (when (or (file-exists-p route) (file-symlink-p route))
      (let* ((record (emacsos-assist-web-git--read-route route))
             (legacy (plist-get record :legacy))
             (relative (plist-get record :relative)))
        (when (equal (plist-get record :initialized) "moving")
          (user-error "Workspace move interrupted; use Move workspace to resume"))
        (unless (and (equal (plist-get record :repo_key) (plist-get metadata :repo-key))
                     (equal (plist-get record :thread_id) (plist-get metadata :tid)))
          (user-error "Workspace binding identity is invalid"))
        (unless (or (memq (plist-get record :initialized) '(t :json-false))
                    (equal (plist-get record :initialized) "installing"))
          (user-error "Workspace binding initialization is invalid"))
        (cond
         ((and (null relative) (stringp legacy)
               (string-match-p "\\`[0-9a-f]\\{64\\}\\'" legacy))
          (emacsos-assist-web-git--unique-legacy-binding route legacy)
          (expand-file-name (concat "checkouts/" legacy) emacsos-assist-web-git-cache-directory))
         ((and (null legacy) (stringp relative)
               (string-match-p "\\`[a-z0-9][a-z0-9-]\\{0,47\\}/[a-z0-9][a-z0-9-]\\{0,47\\}-[0-9a-f]\\{12\\}\\'" relative)
               (string-suffix-p (concat "-" (substring (emacsos-assist-web-git--workspace-identity metadata) 0 12)) relative))
          (expand-file-name relative emacsos-assist-web-git-workspace-directory))
         (t (user-error "Workspace binding path is invalid")))))))

(defun emacsos-assist-web-git--selected-workspace-choice (metadata)
  "Return an explicit local choice only for this exact stable METADATA identity."
  (when (equal (car emacsos-assist-web-git--workspace-choice)
               (emacsos-assist-web-git--workspace-identity metadata))
    (cdr emacsos-assist-web-git--workspace-choice)))

(defun emacsos-assist-web-git--legacy-checkout-path (metadata)
  "Return METADATA's exact old branch-hashed checkout path, without moving it."
  (expand-file-name
   (concat "checkouts/"
           (secure-hash 'sha256
                        (encode-coding-string
                         (format "%s\n%s\n%s" (plist-get metadata :repo-key)
                                 (plist-get metadata :tid) (plist-get metadata :branch))
                         'utf-8-unix)))
   emacsos-assist-web-git-cache-directory))

(defun emacsos-assist-web-git--checkout-path (metadata)
  "Resolve the existing frozen/legacy workspace, or propose a genuinely new path."
  (or (emacsos-assist-web-git--route-path metadata)
      (let* ((legacy (emacsos-assist-web-git--legacy-checkout-path metadata))
             (choice (emacsos-assist-web-git--selected-workspace-choice metadata))
             (existing (cond
                        ((file-exists-p legacy) legacy)
                        ((and choice (not (equal choice "new")))
                         (expand-file-name (concat "checkouts/" choice) emacsos-assist-web-git-cache-directory)))))
        (if existing
            (progn
              (emacsos-assist-web-git--unique-legacy-binding
               (expand-file-name (concat "routes/" (emacsos-assist-web-git--workspace-identity metadata) ".json")
                                 emacsos-assist-web-git-cache-directory)
               (file-name-nondirectory existing))
              existing)
          (emacsos-assist-web-git--new-checkout-path metadata)))))

(defun emacsos-assist-web-git--in-checkout-p (file root)
  "Whether local FILE belongs under the managed ROOT without filesystem I/O."
  (and (stringp file) (not (file-remote-p file))
       (string-prefix-p (file-name-as-directory (expand-file-name root))
                        (expand-file-name file))))

(defun emacsos-assist-web-git--modified-checkout-p (root)
  "Whether an unsaved visiting buffer belongs to ROOT."
  (and (stringp root)
  (seq-some (lambda (buffer)
              (with-current-buffer buffer
                (and (buffer-modified-p)
                     (emacsos-assist-web-git--in-checkout-p buffer-file-name root))))
            (buffer-list))))

(defun emacsos-assist-web-git--advance-checkout-p (root)
  "Whether ROOT has neither unsaved edits nor a live in-app Git operation."
  (and (not (gethash root emacsos-assist-web-git--checkout-operations))
       (not (emacsos-assist-web-git--modified-checkout-p root))
       (not (seq-some
             (lambda (process)
               (and (process-live-p process)
                    (or (equal (process-get process 'default-dir)
                               (file-name-as-directory root))
                        (when (buffer-live-p (process-buffer process))
                          (with-current-buffer (process-buffer process)
                            (emacsos-assist-web-git--in-checkout-p
                             default-directory root))))))
             (process-list)))))

(defun emacsos-assist-web-git--checkout-write-guard (&rest _)
  "Keep edits, saves and manual Magit out of advancement or staging promotion."
  (let ((file (or buffer-file-name default-directory)) blocked)
    (emacsos-assist-web-git--guard-initial-visit file)
    (maphash (lambda (root token)
               (when (and (or (plist-get token :advance)
                              (equal root (plist-get token :initial-stage)))
                          (or (equal (expand-file-name file)
                                     (file-name-as-directory root))
                              (emacsos-assist-web-git--in-checkout-p file root)))
                 (setq blocked t)))
             emacsos-assist-web-git--checkout-operations)
    (when blocked (user-error "Thread Git is updating; retry after it finishes"))))

(defun emacsos-assist-web-git--protect-checkout-buffer (request)
  "Make this visiting buffer read-only until REQUEST releases its checkout."
  (when (and (plist-get request :advance)
             (emacsos-assist-web-git--in-checkout-p
              buffer-file-name (plist-get request :checkout)))
    (unless (assq (current-buffer) (plist-get request :protected-buffers))
      (emacsos-assist-web-git--request-put
       request :protected-buffers
       (cons (cons (current-buffer) buffer-read-only)
             (plist-get request :protected-buffers))))
    (setq buffer-read-only t)))

(defun emacsos-assist-web-git--protect-new-file ()
  "Protect a newly visiting file if its checkout already has an admitted update."
  (maphash (lambda (_root request)
             (emacsos-assist-web-git--protect-checkout-buffer request))
           emacsos-assist-web-git--checkout-operations))

(add-hook 'find-file-hook #'emacsos-assist-web-git--protect-new-file)
(add-hook 'before-save-hook #'emacsos-assist-web-git--checkout-write-guard)

(defun emacsos-assist-web-git--guard-initial-visit (file &rest _)
  "Keep new file/directory consumers out of staging while it can be promoted."
  (let ((file (if (consp file) (car file) file)))
    (when (and (stringp file) (not (file-remote-p file)))
      (let ((real (file-truename file)))
        (maphash
         (lambda (root request)
           (when (and (equal root (plist-get request :initial-stage))
                      (or (equal (directory-file-name real) root)
                          (emacsos-assist-web-git--in-checkout-p real root)))
             (user-error "Thread Git is initializing; retry after it finishes")))
         emacsos-assist-web-git--checkout-operations)))))

(advice-add 'find-file-noselect :before #'emacsos-assist-web-git--guard-initial-visit)
(advice-add 'dired-noselect :before #'emacsos-assist-web-git--guard-initial-visit)
(defun emacsos-assist-web-git--manual-git-uncertain ()
  "Drop live currentness before ordinary Magit can change a managed checkout."
  (let ((directory default-directory))
    (dolist (buffer (buffer-list))
      (with-current-buffer buffer
        (when-let ((root (and emacsos-assist-web-git--current
                             (emacsos-assist-web-git-generation-path
                              emacsos-assist-web-git--current))))
          (when (or (equal (directory-file-name directory) root)
                    (emacsos-assist-web-git--in-checkout-p directory root))
            (setf (emacsos-assist-web-git-generation-state
                   emacsos-assist-web-git--current) 'cached)
            (emacsos-assist-web-git--update-headers)))))))

(with-eval-after-load 'magit-process
  (add-hook 'magit-pre-call-git-hook #'emacsos-assist-web-git--checkout-write-guard)
  (add-hook 'magit-pre-start-git-hook #'emacsos-assist-web-git--checkout-write-guard)
  (add-hook 'magit-pre-call-git-hook #'emacsos-assist-web-git--manual-git-uncertain t)
  (add-hook 'magit-pre-start-git-hook #'emacsos-assist-web-git--manual-git-uncertain t))

(defun emacsos-assist-web-git--release-checkout (request)
  "Release only REQUEST's own advancement and initialization reservations."
  (let ((root (plist-get request :checkout)))
    (when (eq request (gethash root emacsos-assist-web-git--checkout-operations))
      (remhash root emacsos-assist-web-git--checkout-operations)
      (when (eq request (gethash (plist-get request :initial-stage)
                                emacsos-assist-web-git--checkout-operations))
        (remhash (plist-get request :initial-stage) emacsos-assist-web-git--checkout-operations))
      (when (eq request (gethash (plist-get request :workspace-key)
                                emacsos-assist-web-git--checkout-operations))
        (remhash (plist-get request :workspace-key) emacsos-assist-web-git--checkout-operations))
      (dolist (entry (plist-get request :protected-buffers))
        (when (buffer-live-p (car entry))
          (with-current-buffer (car entry)
            (setq buffer-read-only (cdr entry)))))
      (emacsos-assist-web-git--request-put request :protected-buffers nil)
      ;; A terminal event in another view may have queued a post-fetch update.
      (catch 'started
        (dolist (buffer (buffer-list))
          (with-current-buffer buffer
            (when (and (not emacsos-assist-web-git--request)
                       (not emacsos-assist-web-git--canceling)
                       emacsos-assist-web-git--next
                       (or (equal root
                                  (emacsos-assist-web-git--checkout-path
                                   (car emacsos-assist-web-git--next)))
                           (equal (plist-get request :workspace-key)
                                  (concat "thread:" (emacsos-assist-web-git--workspace-identity
                                                     (car emacsos-assist-web-git--next))))))
              (emacsos-assist-web-git--run-next)
              (throw 'started t))))))))

(defun emacsos-assist-web-git--reload-checkout-files (root)
  "Reload clean bounded visiting files in ROOT after Git finishes.
Modified buffers are never reverted. Repository local eval remains disabled."
  (dolist (buffer (buffer-list))
    (with-current-buffer buffer
      (when (and (emacsos-assist-web-git--in-checkout-p buffer-file-name root)
                 (not (buffer-modified-p))
                 (file-regular-p buffer-file-name)
                 (<= (file-attribute-size (file-attributes buffer-file-name))
                     emacsos-assist-web-git--file-view-limit))
        (let ((inhibit-modification-hooks t)
              (enable-local-variables nil) (enable-local-eval nil)
              (enable-dir-local-variables nil))
          (condition-case nil (revert-buffer t t t) (error nil))
          (when-let ((request (gethash root emacsos-assist-web-git--checkout-operations)))
            (emacsos-assist-web-git--protect-checkout-buffer request)))))))

(defun emacsos-assist-web-git--file-disk-guard (&rest _)
  "Keep an out-of-date managed file from reaching an untappable save confirm."
  (when (and buffer-file-name (not (verify-visited-file-modtime (current-buffer))))
    (user-error "Git changed this file; reopen it or save your edit as a copy")))

(defun emacsos-assist-web-git--file-edited (&rest _)
  "Downgrade a managed file's live Git claim immediately on an unsaved edit."
  (when emacsos-assist-web-git--view-generation
    (setf (emacsos-assist-web-git-generation-state
           emacsos-assist-web-git--view-generation) 'edited)
    (when (buffer-live-p emacsos-assist-web-git--view-thread)
      (with-current-buffer emacsos-assist-web-git--view-thread
        (when emacsos-assist-web-git--current
          (setf (emacsos-assist-web-git-generation-state
                 emacsos-assist-web-git--current) 'edited))
        (emacsos-assist-web-git--update-headers)))))
(defvar-local emacsos-assist-web-git--request nil)
(defvar-local emacsos-assist-web-git--next nil)
(defvar-local emacsos-assist-web-git--canceling nil)
(defvar-local emacsos-assist-web-git--epoch 0)
(defvar-local emacsos-assist-web-git--observation 0
  "Serial of the newest diagnostic Git metadata probe.")
(defvar-local emacsos-assist-web-git--deferred-probes nil)
(defvar-local emacsos-assist-web-git--active-probes nil
  "Live window intents awaiting their own metadata GET callback.")
(defvar-local emacsos-assist-web-git--latest-probe-result nil)
(defvar-local emacsos-assist-web-git--intent-serial 0)
(defvar-local emacsos-assist-web-git--unavailable nil)
(defvar-local emacsos-assist-web-git--feedback-windows nil)
(defvar-local emacsos-assist-web-git--view-thread nil)
(defvar-local emacsos-assist-web-git--view-generation nil)
(defvar-local emacsos-assist-web-git--view-diff-oid nil
  "Exact remote thread OID used by this committed Magit diff, if any.")
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


(defvar emacsos-assist-web-git-thread-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-x C-f") #'emacsos-assist-web-git-find-file)
    (define-key map (kbd "C-c d") #'emacsos-assist-web-git-diff)
    (define-key map (kbd "C-c g") #'emacsos-assist-web-git-refresh)
    (define-key map (kbd "C-c ?") #'emacsos-assist-web-details)
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
                    '(:eval (emacsos-assist-web--thread-header)))))))

(defun emacsos-assist-web-git--id ()
  "Return a fresh, path-safe generation identifier."
  (substring (secure-hash 'sha256
                          (format "%s:%s:%s:%s"
                                  (float-time) (emacs-pid)
                                  (random most-positive-fixnum)
                                  (cl-incf emacsos-assist-web-git--intent-serial)))
             0 32))

(defun emacsos-assist-web-git--same-identity (left right)
  "Return non-nil when LEFT and RIGHT select one authenticated branch."
  (and left right
       (equal (plist-get left :tid) (plist-get right :tid))
       (equal (plist-get left :repo-key) (plist-get right :repo-key))
       (equal (plist-get left :branch) (plist-get right :branch))))

(defun emacsos-assist-web-git--request-key (metadata)
  "Return METADATA fields that select one remote thread branch."
  (and metadata
       (list (plist-get metadata :tid)
             (plist-get metadata :repo-key)
             (plist-get metadata :branch))))

(defun emacsos-assist-web-git--request-put (request key value)
  "Set KEY on nonempty mutable REQUEST without replacing its identity."
  (if (plist-member request key)
      (setf (plist-get request key) value)
    (nconc request (list key value)))
  request)

(defun emacsos-assist-web-git--usable (metadata)
  "Return whether METADATA names a non-main canonical Git branch."
  (and metadata
       (plist-get metadata :repo-key)
       (plist-get metadata :branch)
       (not (equal (plist-get metadata :branch) "main"))))

(defun emacsos-assist-web-git--short (oid)
  "Return a compact OID label."
  (if (stringp oid) (substring oid 0 (min 8 (length oid))) "--------"))

(defun emacsos-assist-web-git--gate-reason (&optional _remote-view)
  "Refuse Git only on definitive thread access denial, not Run recovery."
  (when (or (eq emacsos-assist-web--denied t)
            (plist-get (emacsos-assist-web--thread-safety-record
                        emacsos-assist-web--thread-id) :denial))
    "Thread access unavailable; reopen and Retry"))

(defun emacsos-assist-web-git--view-state (generation thread)
  "Describe captured Git provenance without blocking committed busy views."
  (if (not (buffer-live-p thread))
      "cached / thread closed"
    (with-current-buffer thread
      (cond
       ((eq emacsos-assist-web--denied t) "unavailable; reauthorize and Retry")
       ((or (eq (emacsos-assist-web-git-generation-state generation) 'edited)
            (emacsos-assist-web-git--modified-checkout-p
             (emacsos-assist-web-git-generation-path generation)))
        (concat "edited / local work preserved"
                (when (not (equal (plist-get emacsos-assist-web-git--metadata :status) "ready"))
                  "; may change after this turn")))
       ((not (eq generation emacsos-assist-web-git--current))
        (if (emacsos-assist-web-git-generation-oid generation)
            "cached / pinned earlier fetch"
          "cached / earlier local view"))
       ((and emacsos-assist-web-git--metadata
             (not (equal (plist-get emacsos-assist-web-git--metadata :branch)
                    (plist-get (emacsos-assist-web-git-generation-metadata generation)
                               :branch))))
        "cached / thread branch changed")
       ((and (plist-get (emacsos-assist-web-git-generation-metadata generation) :local-branch)
             (not (equal (plist-get (emacsos-assist-web-git-generation-metadata generation) :local-branch)
                         (plist-get emacsos-assist-web-git--metadata :branch))))
        "cached / local branch preserved; thread update pending")
       ((eq (emacsos-assist-web-git-generation-state generation) 'cached)
        (concat "cached / local checkout; not synced for browsing"
                (unless (equal (plist-get
                                (or emacsos-assist-web-git--metadata
                                    (emacsos-assist-web-git-generation-metadata generation))
                                :status) "ready")
                  "; may change after this turn")))
       ((eq (emacsos-assist-web-git-generation-state generation) 'current)
        (concat "local matches last fetched remote"
                (unless (equal (plist-get emacsos-assist-web-git--metadata :status) "ready")
                  "; may change after this turn")))
       ((emacsos-assist-web-git-generation-pending generation)
        (concat "fetched remote latest; "
                (emacsos-assist-web-git-generation-pending generation)
                (unless (equal (plist-get emacsos-assist-web-git--metadata :status) "ready")
                  "; may change after this turn")))
       ((not (equal (plist-get emacsos-assist-web-git--metadata :status) "ready"))
        "fetched remote latest; may change after this turn")
       (t "fetched remote latest; local update pending")))))

(defun emacsos-assist-web-git--thread-header ()
  "Return only fetched/local Git state and its independent refresh action."
  (let* ((generation emacsos-assist-web-git--current)
         (state (cond
                 ((emacsos-assist-web-git--gate-reason) "unavailable")
                 (emacsos-assist-web-git--request "fetching")
                 (generation (emacsos-assist-web-git--view-state generation (current-buffer)))
                 (t (or emacsos-assist-web-git--unavailable "remote pending")))))
    (concat "Git " (propertize
                    (truncate-string-to-width
                     state (max 4 (- (min 40 (window-body-width))
                                     (if emacsos-assist-web-git--workspace-choices 29 19))))
                    'help-echo state)
            (propertize (if emacsos-assist-web-git--workspace-choices
                            " [Choose workspace]" " [Refresh]")
                        'mouse-face 'highlight
                        'local-map (let ((map (make-sparse-keymap)))
                                     (define-key map [header-line mouse-1]
                                       (if emacsos-assist-web-git--workspace-choices
                                           #'emacsos-assist-web-git-choose-workspace
                                         #'emacsos-assist-web-git-refresh))
                                     map))
            (emacsos-assist-web--details-link #'emacsos-assist-web-git-thread-details))))

(defun emacsos-assist-web-git--legacy-route (metadata)
  "Return METADATA's bound legacy route, including an interrupted move."
  (when (emacsos-assist-web-git--usable metadata)
    (let ((route (expand-file-name
                  (concat "routes/" (emacsos-assist-web-git--workspace-identity metadata) ".json")
                  emacsos-assist-web-git-cache-directory)))
      (when (file-exists-p route)
        (let ((record (emacsos-assist-web-git--read-route route)))
          (when (and (equal (plist-get record :repo_key) (plist-get metadata :repo-key))
                     (equal (plist-get record :thread_id) (plist-get metadata :tid))
                     (stringp (plist-get record :legacy))
                     (string-match-p "\\`[0-9a-f]\\{64\\}\\'" (plist-get record :legacy))
                     (member (plist-get record :initialized) '(t "moving")))
            record))))))

(defun emacsos-assist-web-git-thread-details ()
  "Show full independent Git state, including an initial or failed refresh."
  (interactive)
  (let ((thread (current-buffer))
        (state (if emacsos-assist-web-git--current
                   (emacsos-assist-web-git--view-state
                    emacsos-assist-web-git--current (current-buffer))
                 "No local checkout verified"))
        (failure emacsos-assist-web-git--unavailable)
        (fetching emacsos-assist-web-git--request)
        (choices emacsos-assist-web-git--workspace-choices)
        (view (generate-new-buffer " *Assist Git status*")))
    (with-current-buffer view
      (insert "Git: " state "\n\n")
      (when fetching (insert "A background fetch is in progress.\n\n"))
      (when failure (insert "Last refresh: " failure "\n\n"))
      (insert "Browsing does not sync. Git Refresh fetches the selected remote branch; unsafe local advancement stays pending. Local work is preserved.\n\n")
      (when (and (buffer-live-p thread)
                 (with-current-buffer thread
                   (emacsos-assist-web-git--legacy-route emacsos-assist-web-git--metadata)))
        (insert-text-button "Move cached checkout to ~/assist"
                            'follow-link t 'thread thread
                            'action #'emacsos-assist-web-git--offer-workspace-move)
        (insert "\n\n"))
      (when choices (insert "Return to the thread and tap Git to choose an existing workspace in place, or explicitly choose New.\n\n"))
      (special-mode)
      (visual-line-mode 1)
      (setq-local emacsos-assist-web-git--details-origin thread
                  header-line-format
                  (emacsos-assist-web--padded-action
                   "Back" #'emacsos-assist-web-git-view-details-back))
      (local-set-key (kbd "q") #'emacsos-assist-web-git-view-details-back))
    (switch-to-buffer view)))

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
                        (or emacsos-assist-web-git--view-diff-oid
                            (emacsos-assist-web-git-generation-oid generation))))
     (propertize action 'mouse-face 'highlight
                 'local-map (let ((map (make-sparse-keymap)))
                              (define-key map [header-line mouse-1] command)
                              map))
     (emacsos-assist-web--details-link
      #'emacsos-assist-web-git-view-details)
     " " (emacsos-assist-web-git--short-state state))))

(defun emacsos-assist-web-git--short-state (state)
  "Return a phone-width status code for full explanation STATE."
  (cond ((string-match-p "local branch preserved" state) "other branch")
        ((string-match-p "may change after this turn" state) "busy; may change")
        ((string-prefix-p "local matches last fetched remote" state) "local=remote")
        ((string-prefix-p "edited" state) "edited")
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
   (emacsos-assist-web--padded-action
    "Back" #'emacsos-assist-web-git-chooser-back)
   (emacsos-assist-web--details-link
    #'emacsos-assist-web-git-chooser-details)
   " " (emacsos-assist-web-git--short-state
         (emacsos-assist-web-git--view-state
          emacsos-assist-web-git--chooser-generation
          emacsos-assist-web-git--chooser-thread))))

(defun emacsos-assist-web-git-chooser-back ()
  "Leave this file chooser and return to its canonical thread."
  (interactive)
  (when emacsos-assist-web-git--chooser-exit
    (setcar emacsos-assist-web-git--chooser-exit 'back))
  (abort-recursive-edit))

(defun emacsos-assist-web-git-chooser-details ()
  "Leave this chooser for captured checkout Details without selecting a file."
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
                                       :array-type 'list
                                       :false-object nil :null-object nil)
                  (error nil))))
    (if (eq (plist-get result :ok) t)
        result
      (let ((safe (list :ok nil :reason
                        (if (stringp (plist-get result :reason))
                            (plist-get result :reason)
                          "Git helper response invalid")))
            (choices (plist-get result :workspace_choices)))
        (when (and (listp choices) choices (<= (length choices) 16)
                   (cl-every (lambda (choice)
                               (and (listp choice) (stringp (plist-get choice :identity))
                                    (string-match-p "\\`[0-9a-f]\\{64\\}\\'" (plist-get choice :identity))
                                    (stringp (plist-get choice :branch))
                                    (<= (length (plist-get choice :branch)) 48)
                                    (string-match-p "\\`[A-Za-z0-9._/?-]*\\'" (plist-get choice :branch))))
                             choices))
          (setq safe (plist-put safe :workspace_choices choices)))
        safe))))

(defun emacsos-assist-web-git--spawn (request callback)
  "Run helper REQUEST asynchronously and call CALLBACK with its bounded result."
  (let* ((output "")
         (finished nil)
         (process
          (make-process
           :name "assist-thread-git" :buffer nil :noquery t
           :connection-type 'pipe
           :command (list "timeout" "--kill-after=2" "90"
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
                                (cond
                                 ((process-get process :oversize)
                                  "Git helper output too large")
                                 ((eq (process-status process) 'signal)
                                  "Git helper terminated")
                                 ((/= (process-exit-status process) 0)
                                  (format "Git helper exited (%d)"
                                          (process-exit-status process)))
                                 (t "Git helper response invalid"))))))))))
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
  "Cancel this buffer's active request without deleting its persistent checkout."
  (when-let ((request emacsos-assist-web-git--request))
    (setq emacsos-assist-web-git--request nil
          emacsos-assist-web-git--canceling (plist-get request :id))
    (let ((process (plist-get request :process))
          (thread (current-buffer)))
      (if (process-live-p process)
          (progn
            (process-put process :cancelled t)
            (emacsos-assist-web-git--terminate process))
        (emacsos-assist-web-git--release-checkout request)
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
  "Release Git actions after a legacy cache cleanup action fails."
  (emacsos-assist-web-git--invalidate
   "mirror cleanup failed; restart Emacs before retry"))

(defun emacsos-assist-web-git--run-next ()
  "Start a queued successor after the prior request finishes."
  (when-let ((next (and (not emacsos-assist-web-git--canceling)
                       (not emacsos-assist-web-git--request)
                       emacsos-assist-web-git--next)))
    (setq emacsos-assist-web-git--next nil)
    (apply #'emacsos-assist-web-git--begin next)))

(defun emacsos-assist-web-git--note (metadata)
  "Accept selected METADATA and update the current Git view."
  (let ((changed (not (equal (emacsos-assist-web-git--request-key metadata)
                             (emacsos-assist-web-git--request-key
                              emacsos-assist-web-git--metadata)))))
    (setq emacsos-assist-web-git--metadata metadata)
    (when emacsos-assist-web-git--current
      (setf (emacsos-assist-web-git-generation-state
             emacsos-assist-web-git--current) 'cached))
    (when changed
      (setq emacsos-assist-web-git--unavailable nil)
      (cl-incf emacsos-assist-web-git--epoch))
    (when (and emacsos-assist-web-git--request
               (not (equal (emacsos-assist-web-git--request-key metadata)
                           (emacsos-assist-web-git--request-key
                            (plist-get emacsos-assist-web-git--request
                                       :metadata)))))
      (setq emacsos-assist-web-git--next
            (list metadata
                  (emacsos-assist-web-git--live-intents
                   (plist-get emacsos-assist-web-git--request :intents)
                   (cadr emacsos-assist-web-git--next))))
      (emacsos-assist-web-git--cancel)))
    (when (and emacsos-assist-web-git--next
               (not (equal (emacsos-assist-web-git--request-key
                            (car emacsos-assist-web-git--next))
                           (emacsos-assist-web-git--request-key metadata))))
      (setcar emacsos-assist-web-git--next metadata))
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

(defun emacsos-assist-web-git--canonical-accepted
    (metadata legacy-success-run-id token &optional legacy-terminal-run-id)
  "Observe chat-accepted METADATA and fetch after a terminal turn.
An ordinary GET confirming an already-fetched opening selection needs no
second fetch.  Run arguments identify the trigger, not Git freshness."
  (let ((same-selection
         (or (and emacsos-assist-web-git--request
                  (equal (emacsos-assist-web-git--request-key metadata)
                         (emacsos-assist-web-git--request-key
                          (plist-get emacsos-assist-web-git--request :metadata))))
             (emacsos-assist-web-git--same-identity
              metadata
              (and emacsos-assist-web-git--current
                   (emacsos-assist-web-git-generation-metadata
                    emacsos-assist-web-git--current)))))
        (terminal (or legacy-success-run-id legacy-terminal-run-id
                      (and (listp token) (plist-get token :queue-owner))))
        (was-unavailable emacsos-assist-web-git--unavailable))
    (emacsos-assist-web-git--note metadata)
    (when (or terminal (not same-selection) was-unavailable)
      (emacsos-assist-web-git--enqueue metadata nil))))

(defun emacsos-assist-web-git--invalidate (reason)
  "Make Git freshness unavailable for REASON without changing chat state.
A definitive thread denial keeps its endpoint-specific reason instead."
  (when (eq emacsos-assist-web--denied t)
    (setq reason (emacsos-assist-web--thread-denial-reason)))
  (let ((intents (emacsos-assist-web-git--live-intents
                  (plist-get emacsos-assist-web-git--request :intents)
                  (cadr emacsos-assist-web-git--next)
                  emacsos-assist-web-git--active-probes
                  (mapcar #'car emacsos-assist-web-git--deferred-probes))))
    (setq emacsos-assist-web-git--metadata nil
          emacsos-assist-web-git--unavailable reason
          emacsos-assist-web-git--next nil
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
             (missing (string-match-p "thread unavailable (404)" reason))
             (denial (or missing
                         (string-match-p
                          "thread access denied\\|reauthorize" reason)))
             (label (cond (restart "Restart to recover")
                          (missing "Thread unavailable")
                          (denial "Reauthorize")
                          ((string-match-p "pending\\|changed" reason)
                           "Git pending")
                          (t "Git unavailable")))
             (retry (if (or restart denial) ""
                      (propertize
                       " [Retry]"
                       'mouse-face 'highlight
                       'local-map
                       (let ((map (make-sparse-keymap)))
                         (define-key map [header-line mouse-1]
                           #'emacsos-assist-web-git-refresh)
                         map))))
             (details (if (or restart denial)
                          (emacsos-assist-web--details-link)
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

(defun emacsos-assist-web-git--enqueue (metadata intent &optional terminal)
  "Queue a fresh METADATA fetch, retaining optional UI INTENT."
  (ignore terminal)
  (let ((request emacsos-assist-web-git--request))
    (cond
     ((not (emacsos-assist-web-git--usable metadata))
      (setq emacsos-assist-web-git--unavailable
            (if (equal (plist-get metadata :actual-branch) "HEAD")
                "detached HEAD; Git unavailable"
              (or (plist-get metadata :sync-error)
                  "no repository or thread branch")))
      (emacsos-assist-web-git--update-headers)
      (when intent
        (emacsos-assist-web-git--release-intents
         (list intent) emacsos-assist-web-git--unavailable)))
     ((and request
           (equal (emacsos-assist-web-git--request-key
                   (plist-get request :metadata))
                  (emacsos-assist-web-git--request-key metadata)))
      ;; A terminal update may arrive after this fetch began.  It needs its
      ;; own fetch, even when the branch selector has not changed.
      (setq emacsos-assist-web-git--next
            (list metadata
                  (emacsos-assist-web-git--live-intents
                   (cadr emacsos-assist-web-git--next)
                   (and intent (list intent))))))
     (emacsos-assist-web-git--canceling
      (setq emacsos-assist-web-git--next
            (list metadata (append (cadr emacsos-assist-web-git--next)
                                   (and intent (list intent))))))
     (request
      (setq emacsos-assist-web-git--next
            (list metadata (and intent (list intent))))
      (emacsos-assist-web-git--cancel))
     (t
      (emacsos-assist-web-git--begin metadata (and intent (list intent)))))))

(defun emacsos-assist-web-git--begin (metadata intents)
  "Begin METADATA fetch, releasing INTENTS if its frozen binding is unavailable."
  (condition-case nil
      (emacsos-assist-web-git--begin-workspace metadata intents)
    ((error quit)
     (setq emacsos-assist-web-git--unavailable
           "workspace binding unavailable; local files preserved")
     (emacsos-assist-web-git--release-intents
      intents emacsos-assist-web-git--unavailable)
     (emacsos-assist-web-git--update-headers))))

(defun emacsos-assist-web-git--begin-workspace (metadata intents)
  "Begin one exact METADATA fetch with accumulated INTENTS."
  (let* ((thread (current-buffer))
         (id (emacsos-assist-web-git--id))
         (request (list :id id :metadata metadata
                        :intents intents :process nil
                        :workspace-key (concat "thread:" (emacsos-assist-web-git--workspace-identity metadata))
                        :checkout (emacsos-assist-web-git--checkout-path metadata)))
         (root (plist-get request :checkout))
         (stage (expand-file-name
                 (concat "." (file-name-nondirectory root) ".initial")
                 (file-name-directory root)))
         (initialize (not (emacsos-assist-web-git--move-busy-buffer-p stage thread)))
         (advance (emacsos-assist-web-git--advance-checkout-p root)))
    (if (or (gethash root emacsos-assist-web-git--checkout-operations)
            (gethash (plist-get request :workspace-key) emacsos-assist-web-git--checkout-operations))
        (setq emacsos-assist-web-git--next
              (list metadata (emacsos-assist-web-git--live-intents
                              intents (cadr emacsos-assist-web-git--next))))
    (emacsos-assist-web-git--request-put request :advance advance)
    (emacsos-assist-web-git--request-put request :initial-stage stage)
    (setq emacsos-assist-web-git--request request
          emacsos-assist-web-git--unavailable nil)
    (emacsos-assist-web-git--update-headers)
    (condition-case error
        (progn
        (puthash root request emacsos-assist-web-git--checkout-operations)
        (when initialize
          (puthash stage request emacsos-assist-web-git--checkout-operations))
        (puthash (plist-get request :workspace-key) request emacsos-assist-web-git--checkout-operations)
        (when advance
          (dolist (buffer (buffer-list))
            (with-current-buffer buffer
              (emacsos-assist-web-git--protect-checkout-buffer request))))
        (let ((process
               (emacsos-assist-web-git--spawn
                `((action . "sync")
                  (cache_root . ,emacsos-assist-web-git-cache-directory)
                  (workspace_root . ,emacsos-assist-web-git-workspace-directory)
                  (checkout_path . ,root)
                  (workspace_choice . ,(emacsos-assist-web-git--selected-workspace-choice metadata))
                  (repo_label . ,(emacsos-assist-web-git--workspace-slug (plist-get metadata :repo-label) "repo"))
                  (thread_label . ,(emacsos-assist-web-git--workspace-slug (plist-get metadata :thread-label) "thread"))
                  (generation . ,id)
                  (thread_id . ,(plist-get metadata :tid))
                  (allow_ff . ,(if advance t :json-false))
                  (allow_initialization . ,(if initialize t :json-false))
                  (repo_key . ,(plist-get metadata :repo-key))
                  (branch . ,(plist-get metadata :branch)))
                (lambda (result)
                  (when (and advance (plist-get result :ok))
                    (condition-case nil
                        (emacsos-assist-web-git--reload-checkout-files root)
                      ((error quit) nil)))
                  (unless (and (plist-get result :ok)
                               (buffer-live-p thread)
                               (with-current-buffer thread
                                 (eq request emacsos-assist-web-git--request)))
                    (emacsos-assist-web-git--release-checkout request))
                  (if (not (buffer-live-p thread))
                      (emacsos-assist-web-git--cleanup id "staging" #'ignore)
                    (with-current-buffer thread
                      (cond
                       ((not (eq request emacsos-assist-web-git--request))
                        (emacsos-assist-web-git--release-checkout request)
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
                       ((not (equal (emacsos-assist-web-git--request-key
                                     (plist-get request :metadata))
                                    (emacsos-assist-web-git--request-key
                                     emacsos-assist-web-git--metadata)))
                        (emacsos-assist-web-git--failed
                         request "thread branch changed during Git sync"))
                       ((plist-get result :ok)
                        (emacsos-assist-web-git--promote request result))
                       (t
                        (condition-case nil
                            (emacsos-assist-web-git--cleanup
                             id "staging"
                             (lambda (ok)
                               (when (buffer-live-p thread)
                                 (with-current-buffer thread
                                   (if ok
                                       (emacsos-assist-web-git--failed
                                       request (plist-get result :reason) result)
                                     (emacsos-assist-web-git--cleanup-failed))))))
                          ((error quit)
                           (emacsos-assist-web-git--cleanup-failed)))))))))))
          (emacsos-assist-web-git--request-put request :process process)))
      ((error quit)
       (emacsos-assist-web-git--release-checkout request)
       (emacsos-assist-web-git--failed
        request (error-message-string error)))))))

(defun emacsos-assist-web-git--failed (request reason &optional result)
  "Preserve the last good view after REQUEST fails with safe REASON."
  (emacsos-assist-web-git--release-checkout request)
  (when (eq request emacsos-assist-web-git--request)
    (setq emacsos-assist-web-git--request nil)
    (setq emacsos-assist-web-git--unavailable reason)
    (setq emacsos-assist-web-git--workspace-choices (plist-get result :workspace_choices))
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
     (format "%s; Refresh to retry" reason))
    (emacsos-assist-web-git--run-next)))

(defun emacsos-assist-web-git--promote (request result)
  "Accept RESULT or release REQUEST's reservation when its binding is invalid."
  (condition-case nil
      (emacsos-assist-web-git--promote-workspace request result)
    ((error quit)
     (emacsos-assist-web-git--failed
      request "workspace binding unavailable; local files preserved"))))

(defun emacsos-assist-web-git--promote-workspace (request result)
  "Accept REQUEST's persistent checkout RESULT without deleting user work."
  (when (eq request emacsos-assist-web-git--request)
    (let* ((metadata (plist-get request :metadata))
           (path (emacsos-assist-web-git--checkout-path metadata))
           (local (plist-get result :local_oid))
           (remote (plist-get result :thread_oid))
           (main (plist-get result :main_oid))
           (thread (current-buffer)))
      (if (not (and (equal path (plist-get result :checkout_path))
                    (stringp (plist-get result :actual_branch))
                    (not (member (plist-get result :actual_branch) '("main" "HEAD")))
                    (seq-every-p
                     (lambda (oid) (and (stringp oid)
                                        (string-match-p
                                         emacsos-assist-web--git-oid-regexp oid)))
                     (list local remote main))))
          (emacsos-assist-web-git--failed
           request "local checkout is not the selected thread branch; inspect Magit")
        (let* ((edited (or (plist-get result :dirty)
                           (emacsos-assist-web-git--modified-checkout-p path)))
               (current (and (not edited) (not (plist-get result :pending))
                             (equal (plist-get result :actual_branch) (plist-get metadata :branch))
                             (equal local remote)))
               (generation
                (make-emacsos-assist-web-git-generation
                 :id (plist-get request :id) :path path
                 :metadata (plist-put (copy-sequence metadata) :local-branch (plist-get result :actual_branch))
                 :oid local :remote remote :main main
                 :dirty edited :pending (plist-get result :pending)
                 :state (cond (current 'current) (edited 'edited) (t 'busy))
                 :auth-epoch emacsos-assist-web--thread-denial-floor)))
          (setq emacsos-assist-web-git--previous emacsos-assist-web-git--current
                emacsos-assist-web-git--current generation
                emacsos-assist-web-git--request nil
                emacsos-assist-web-git--workspace-choices nil
                emacsos-assist-web-git--workspace-choice nil
                emacsos-assist-web-git--unavailable nil)
          (dolist (buffer (buffer-list))
            (with-current-buffer buffer
              (when (and (emacsos-assist-web-git--in-checkout-p buffer-file-name path)
                         (not (buffer-modified-p))
                         (verify-visited-file-modtime buffer))
                (emacsos-assist-web-git--pin buffer thread generation))))
          (emacsos-assist-web-git--release-checkout request)
          (emacsos-assist-web-git--update-headers)
          (dolist (intent (plist-get request :intents))
            (when (emacsos-assist-web-git--intent-live-p intent)
              (emacsos-assist-web-git--clear-feedback (plist-get intent :window))
              (condition-case problem
                  (emacsos-assist-web-git--open intent generation)
                ((error quit)
                 (emacsos-assist-web-git--release-intents
                  (list intent)
                  (cond
                   ((eq (car problem) 'quit) "view cancelled; Retry")
                   ((and (eq (car problem) 'user-error)
                         (member (cadr problem)
                                 '("Git file already has an ordinary visit; close it before browsing here"
                                   "Git buffer exceeds 1 MiB display limit")))
                    (cadr problem))
                   (t "Git view unavailable; Retry")))))))
          (emacsos-assist-web-git--run-next))))))

(defun emacsos-assist-web-git--route-probe (intent metadata problem start-epoch)
  "Route authenticated Git metadata without changing chat or Run ownership."
  (when (emacsos-assist-web-git--intent-live-p intent)
    (cond
     ((or (eq emacsos-assist-web--denied t)
          (and (listp problem) (eq (plist-get problem :kind) 'http)
               (memq (plist-get problem :status) '(401 403 404))))
      (emacsos-assist-web-git--release-intents
       (list intent) "thread access unavailable; reopen and Retry"))
     ((and (consp problem) (memq (car problem) '(canonical git)))
      (emacsos-assist-web-git--invalidate "Git metadata unavailable")
      (emacsos-assist-web-git--release-intents (list intent) "Git metadata unavailable; Retry"))
     (problem
      (setq emacsos-assist-web-git--unavailable "metadata unavailable; Retry")
      (when emacsos-assist-web-git--current
        (setf (emacsos-assist-web-git-generation-state
               emacsos-assist-web-git--current) 'cached))
      (emacsos-assist-web-git--update-headers)
      (emacsos-assist-web-git--release-intents
       (list intent) "metadata unavailable; Retry"))
     ((/= start-epoch emacsos-assist-web-git--epoch)
      (emacsos-assist-web-git--enqueue emacsos-assist-web-git--metadata intent))
     (t
      (emacsos-assist-web-git--note metadata)
      (emacsos-assist-web-git--enqueue metadata intent)))))

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

(defun emacsos-assist-web-git--refresh-command (action)
  "Probe metadata, then perform ACTION in its originating thread window."
  (unless (and emacsos-assist-web-git-thread-mode
               emacsos-assist-web--thread-id)
    (user-error "Git views require a canonical Assist thread"))
  (when-let ((reason (emacsos-assist-web-git--gate-reason t)))
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

(defun emacsos-assist-web-git--check-local-branch (root metadata)
  "Return ROOT's existing non-main local branch for authenticated METADATA.
This only reads local metadata; it does not invoke Git or synchronize files."
  (let ((head (and root (expand-file-name ".git/HEAD" root))))
    (unless (and root (file-directory-p root) (not (file-symlink-p root))
                 (equal (directory-file-name (expand-file-name root))
                        (directory-file-name (file-truename root)))
                 (file-directory-p (expand-file-name ".git" root))
                 (not (file-symlink-p (expand-file-name ".git" root)))
                 (file-regular-p head) (not (file-symlink-p head))
                 (<= (file-attribute-size (file-attributes head)) 512))
      (user-error "No local thread checkout; use Git Refresh to initialize"))
    (let ((branch (with-temp-buffer
                    (insert-file-contents-literally head nil 0 512)
                    (let ((value (string-trim (buffer-string))))
                      (when (string-match "\\`ref: refs/heads/\\([^[:cntrl:]]+\\)\\'" value)
                        (match-string 1 value))))))
      (unless (and branch (<= (string-bytes branch) 240)
                   (not (member branch '("main" "HEAD")))
                   (emacsos-assist-web-git--usable metadata))
        (user-error "Local checkout is not on a thread branch; inspect Magit"))
      branch)))

(defun emacsos-assist-web-git--command (action)
  "Browse local files/Magit without fetching; Refresh explicitly requests sync."
  (if (eq action 'refresh)
      (emacsos-assist-web-git--refresh-command action)
    (unless (and emacsos-assist-web-git-thread-mode emacsos-assist-web--thread-id)
      (user-error "Git views require a canonical Assist thread"))
    (when-let ((reason (emacsos-assist-web-git--gate-reason t)))
      (user-error "%s" reason))
    (let* ((prior emacsos-assist-web-git--current)
           (metadata (or (and prior
                              (or (null emacsos-assist-web-git--metadata)
                                  (equal (plist-get emacsos-assist-web-git--metadata :repo-key)
                                         (plist-get (emacsos-assist-web-git-generation-metadata prior) :repo-key)))
                              (emacsos-assist-web-git-generation-metadata prior))
                         emacsos-assist-web-git--metadata
                         (and emacsos-assist-web--snapshot
                              (emacsos-assist-web-git--metadata-from-snapshot
                               emacsos-assist-web--snapshot))))
           (root (and (emacsos-assist-web-git--usable metadata)
                      (equal emacsos-assist-web--thread-id (plist-get metadata :tid))
                      (or (null emacsos-assist-web-git--metadata)
                          (equal (plist-get metadata :repo-key)
                                 (plist-get emacsos-assist-web-git--metadata :repo-key)))
                      (emacsos-assist-web-git--checkout-path metadata))))
      (setq metadata (plist-put (copy-sequence metadata) :local-branch
                                (emacsos-assist-web-git--check-local-branch root metadata)))
      (let* ((window (selected-window))
             (serial (1+ (or (window-parameter window 'assist-web-git-intent) 0)))
             (generation (make-emacsos-assist-web-git-generation
                          :path root :metadata metadata :state 'cached
                          :auth-epoch emacsos-assist-web--thread-denial-floor))
             (intent (list :action action :buffer (current-buffer) :window window
                           :serial serial :local t)))
        (setq emacsos-assist-web-git--previous prior
              emacsos-assist-web-git--current generation)
        (set-window-parameter window 'assist-web-git-intent serial)
        (emacsos-assist-web-git--clear-feedback window)
        (emacsos-assist-web-git--open intent generation)))))

(defun emacsos-assist-web-git-find-file ()
  "Browse the existing editable thread checkout immediately, without syncing."
  (interactive)
  (emacsos-assist-web-git--command 'files))

(defun emacsos-assist-web-git-diff ()
  "Open ordinary Magit on local HEAD against cached remote main, without syncing."
  (interactive)
  (emacsos-assist-web-git--command 'diff))

(defun emacsos-assist-web-git-refresh ()
  "Explicitly retry the thread Git fetch and update its visible state."
  (interactive)
  (emacsos-assist-web-git--command 'refresh))

(defun emacsos-assist-web-git--move-busy-buffer-p (root thread)
  "Whether a live buffer or its working directory still uses ROOT."
  (cl-some
   (lambda (buffer)
     (unless (eq buffer thread)
       (with-current-buffer buffer
         (or (and buffer-file-name
                  (or (equal (expand-file-name buffer-file-name) root)
                      (emacsos-assist-web-git--in-checkout-p buffer-file-name root)))
             (and buffer-file-truename
                  (not (file-remote-p buffer-file-truename))
                  (emacsos-assist-web-git--in-checkout-p buffer-file-truename root))
             (and default-directory
                  (or (equal (directory-file-name (expand-file-name default-directory)) root)
                      (emacsos-assist-web-git--in-checkout-p default-directory root)
                      (and (not (file-remote-p default-directory))
                           (condition-case nil
                               (let ((real (file-truename default-directory)))
                                 (or (equal (directory-file-name real) root)
                                     (emacsos-assist-web-git--in-checkout-p real root)))
                             (file-error nil)))))
             (and emacsos-assist-web-git--view-generation
                  (equal (emacsos-assist-web-git-generation-path
                          emacsos-assist-web-git--view-generation) root))))))
   (buffer-list)))

(defun emacsos-assist-web-git--move-workspace (button)
  "Perform BUTTON's explicitly confirmed, same-filesystem move without Git sync."
  (let ((thread (button-get button 'thread))
        (identity (button-get button 'identity))
        (confirmation (current-buffer)))
    (unless (buffer-live-p thread) (user-error "Thread view closed"))
    (with-current-buffer thread
      (when-let ((reason (emacsos-assist-web-git--gate-reason)))
        (user-error "%s" reason))
      (let* ((metadata emacsos-assist-web-git--metadata)
             (record (emacsos-assist-web-git--legacy-route metadata))
             (root (and record (expand-file-name
                                (concat "checkouts/" (plist-get record :legacy))
                                emacsos-assist-web-git-cache-directory))))
        (unless (and root (equal identity (emacsos-assist-web-git--workspace-identity metadata))
                     (not emacsos-assist-web-git--request)
                     (not (gethash root emacsos-assist-web-git--checkout-operations))
                     (not (gethash (concat "thread:" identity)
                                   emacsos-assist-web-git--checkout-operations)))
          (user-error "Workspace changed or Git is busy; retry Move workspace"))
        (when (emacsos-assist-web-git--move-busy-buffer-p root thread)
          (user-error "Close local files and Magit views before moving; edits preserved"))
        ;; This explicit, bounded operation blocks the Emacs event loop so a
        ;; local view cannot open the old path between the buffer check and rename.
        (let* ((payload `((action . "migrate")
                          (repo_key . ,(plist-get metadata :repo-key))
                          (thread_id . ,(plist-get metadata :tid))
                          (cache_root . ,emacsos-assist-web-git-cache-directory)
                          (workspace_root . ,emacsos-assist-web-git-workspace-directory)
                          (checkout_path . ,root)
                          (repo_label . ,(plist-get metadata :repo-label))
                          (thread_label . ,(plist-get metadata :thread-label))))
               (result (with-temp-buffer
                         (insert (json-encode payload))
                         (let ((code (call-process-region
                                      (point-min) (point-max) "timeout" t t nil
                                      "--kill-after=1" "8" "python3"
                                      emacsos-assist-web-git-helper)))
                           (unless (and (integerp code) (= code 0)
                                        (<= (buffer-size) 4096))
                             (user-error "Workspace move unavailable; local files preserved")))
                         (emacsos-assist-web-git--parse-helper-result (buffer-string)))))
          (unless (plist-get result :ok)
            (user-error "%s" (or (plist-get result :reason)
                                  "Workspace move unavailable; local files preserved")))
          (unless (equal (plist-get result :checkout_path)
                         (emacsos-assist-web-git--route-path metadata))
            (user-error "Workspace move binding unavailable; local files preserved"))
          (setq emacsos-assist-web-git--current nil
                emacsos-assist-web-git--previous nil
                emacsos-assist-web-git--unavailable
                "Workspace moved to ~/assist; browse locally or Refresh")
          (emacsos-assist-web-git--update-headers))))
    (switch-to-buffer thread)
    (when (buffer-live-p confirmation) (kill-buffer confirmation))
    (message "Workspace moved as-is to ~/assist; no Git fetch or file rewrite")))

(defun emacsos-assist-web-git--offer-workspace-move (button)
  "Show a second explicit tap for BUTTON's legacy workspace move."
  (let* ((thread (button-get button 'thread))
         (identity (and (buffer-live-p thread)
                        (with-current-buffer thread
                          (and emacsos-assist-web-git--metadata
                               (emacsos-assist-web-git--workspace-identity
                                emacsos-assist-web-git--metadata)))))
         (view (generate-new-buffer " *Assist Git move workspace*")))
    (unless identity (user-error "Thread repository unavailable"))
    (with-current-buffer view
      (insert "Move this cached checkout as-is into ~/assist?\n\nGit history, local edits, staged and untracked files stay in the same directory inode. This does not fetch or switch branches. Close local file and Magit views first.\n\n")
      (insert-text-button "Move workspace now"
                          'follow-link t 'thread thread 'identity identity
                          'action #'emacsos-assist-web-git--move-workspace)
      (insert "\n\nq: keep it in place\n")
      (special-mode)
      (visual-line-mode 1)
      (setq-local emacsos-assist-web-git--details-thread thread
                  emacsos-assist-web-git--details-origin thread)
      (local-set-key (kbd "q") #'emacsos-assist-web-git-view-details-back))
    (switch-to-buffer view)))

(defun emacsos-assist-web-git--bind-workspace-choice (button)
  "Apply BUTTON's explicit local choice to its still-authenticated thread."
  (let ((thread (button-get button 'thread))
        (identity (button-get button 'identity))
        (choice (button-get button 'choice))
        (view (current-buffer)))
    (unless (buffer-live-p thread) (user-error "Thread view closed"))
    (with-current-buffer thread
      (when-let ((reason (emacsos-assist-web-git--gate-reason))) (user-error "%s" reason))
      (unless (and (emacsos-assist-web-git--usable emacsos-assist-web-git--metadata)
                   (equal identity (emacsos-assist-web-git--workspace-identity emacsos-assist-web-git--metadata)))
        (user-error "Thread repository changed; Refresh again"))
      (setq emacsos-assist-web-git--workspace-choice (cons identity choice))
      (emacsos-assist-web-git--enqueue emacsos-assist-web-git--metadata nil))
    (switch-to-buffer thread)
    (kill-buffer view)))

(defun emacsos-assist-web-git-choose-workspace ()
  "Choose an ambiguous legacy workspace in place, or explicitly start a new one."
  (interactive)
  (when-let ((reason (emacsos-assist-web-git--gate-reason))) (user-error "%s" reason))
  (unless (and emacsos-assist-web-git--workspace-choices
               (emacsos-assist-web-git--usable emacsos-assist-web-git--metadata))
    (user-error "No workspace choice pending; use Git Refresh"))
  (let ((thread (current-buffer))
        (choices emacsos-assist-web-git--workspace-choices)
        (identity (emacsos-assist-web-git--workspace-identity emacsos-assist-web-git--metadata))
        (view (generate-new-buffer " *Assist workspaces*")))
    (with-current-buffer view
      (insert "Existing workspace: choose in place. Nothing is moved or replaced.\n\n")
      (dolist (choice (seq-take choices 16))
        (let ((key (plist-get choice :identity)) (branch (plist-get choice :branch)))
          (when (and (stringp key) (string-match-p "\\`[0-9a-f]\\{64\\}\\'" key)
                     (stringp branch) (<= (length branch) 48)
                     (not (string-match-p "[[:cntrl:]]" branch)))
            (insert-text-button (format "Bind %s (%s)" branch (substring key 0 12))
                                'follow-link t
                                'thread thread 'identity identity 'choice key
                                'action #'emacsos-assist-web-git--bind-workspace-choice)
            (insert "\n\n"))))
      (insert-text-button "New workspace (leave all existing files in place)"
                          'follow-link t
                          'thread thread 'identity identity 'choice "new"
                          'action #'emacsos-assist-web-git--bind-workspace-choice)
      (insert "\n\nq: back without choosing\n")
      (special-mode)
      (visual-line-mode 1)
      (setq-local emacsos-assist-web-git--details-thread thread)
      (local-set-key (kbd "q")
                     (lambda () (interactive)
                       (let ((origin emacsos-assist-web-git--details-thread) (view (current-buffer)))
                         (when (buffer-live-p origin) (switch-to-buffer origin))
                         (kill-buffer view)))))
    (switch-to-buffer view)))

(defun emacsos-assist-web-git--literal-file-view (file root thread generation)
  "Return a bounded editable visiting FILE from ROOT for THREAD and GENERATION.
Read a bounded worktree path, not a verified committed blob.  Do not
interpret repository-local code.  Reject ordinary existing visits rather than
discarding their edits or reusing their repository-local settings."
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
  (let* ((enable-local-variables nil)
         (enable-local-eval nil)
         (enable-dir-local-variables nil)
         (existing (get-file-buffer file))
         (_ (when existing
              (with-current-buffer existing
                (unless emacsos-assist-web-git--safe-file-view
                  (user-error "Git file already has an ordinary visit; close it before browsing here"))
                (when (> (buffer-size) emacsos-assist-web-git--file-view-limit)
                  (user-error "Git buffer exceeds 1 MiB display limit")))))
         (view (or existing (generate-new-buffer (file-name-nondirectory file)))))
    (unless existing
      (condition-case problem
          (with-current-buffer view
            (insert-file-contents file nil 0
                                  (1+ emacsos-assist-web-git--file-view-limit))
            (when (> (buffer-size) emacsos-assist-web-git--file-view-limit)
              (error "Git file exceeds 1 MiB display limit"))
            (set-visited-file-name file t)
            (set-visited-file-modtime)
            (normal-mode t)
            (setq-local emacsos-assist-web-git--safe-file-view t)
            (set-buffer-modified-p nil))
        ((error quit)
         (kill-buffer view)
         (signal (car problem) (cdr problem)))))
    (with-current-buffer view
      (add-hook 'after-change-functions #'emacsos-assist-web-git--file-edited nil t)
      (add-hook 'before-change-functions #'emacsos-assist-web-git--file-disk-guard nil t)
      (add-hook 'before-save-hook #'emacsos-assist-web-git--file-disk-guard nil t)
      (local-set-key (kbd "C-c b") #'emacsos-assist-web-git-back)
      (emacsos-assist-web-git--pin view thread generation))
    view))

(defun emacsos-assist-web-git--open (intent generation)
  "Complete INTENT against pinned GENERATION in its originating window."
  (let* ((window (plist-get intent :window))
         (thread (plist-get intent :buffer))
         (root (emacsos-assist-web-git-generation-path generation))
         (default-directory (file-name-as-directory root))
         (auth-epoch (with-current-buffer thread
                       emacsos-assist-web--thread-denial-floor)))
    (when (emacsos-assist-web-git--intent-live-p intent)
      (when-let ((reason (with-current-buffer thread
                          (emacsos-assist-web-git--gate-reason t))))
        (user-error "%s" reason))
      (when (with-current-buffer thread
              (and (> emacsos-assist-web--thread-denial-floor 0)
                   (not (eql emacsos-assist-web--thread-denial-floor
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
             (when (and (not (plist-get intent :local))
                        (gethash root emacsos-assist-web-git--checkout-operations))
               (user-error "Thread Git is updating; retry file selection"))
             (unless (with-current-buffer thread
                       (and (not (eq emacsos-assist-web--denied t))
                            (= auth-epoch emacsos-assist-web--thread-denial-floor)
                            (or (not (plist-get intent :local))
                                (and (equal emacsos-assist-web--thread-id
                                            (plist-get (emacsos-assist-web-git-generation-metadata generation) :tid))
                                     (or (null emacsos-assist-web-git--metadata)
                                         (equal (plist-get emacsos-assist-web-git--metadata :repo-key)
                                                (plist-get (emacsos-assist-web-git-generation-metadata generation) :repo-key)))))
                            (equal root (emacsos-assist-web-git--checkout-path
                                         (if (plist-get intent :local)
                                             (emacsos-assist-web-git-generation-metadata generation)
                                           emacsos-assist-web-git--metadata)))))
               (user-error "Thread Git repository changed; Retry"))
             (when (plist-get intent :local)
               (emacsos-assist-web-git--check-local-branch
                root (emacsos-assist-web-git-generation-metadata generation)))
             (let ((view (emacsos-assist-web-git--literal-file-view
                          choice root thread generation)))
               (when-let ((request (gethash root emacsos-assist-web-git--checkout-operations)))
                 (with-current-buffer view
                   (emacsos-assist-web-git--protect-checkout-buffer request)))
               (condition-case error
                   (set-window-buffer window view)
                 (error
                  (kill-buffer view)
                  (signal (car error) (cdr error)))))))))
        ('diff
         (if (not (require 'magit nil t))
             (message "Magit is not installed on this phone")
           (with-selected-window window
             (let ((default-directory (file-name-as-directory root))
                   ;; Opening this fixed read-only diff is allowed during a
                   ;; background update. Ordinary later Magit writes retain
                   ;; their normal checkout reservation guard.
                   (magit-pre-call-git-hook
                    (if (plist-get intent :local)
                        (remq #'emacsos-assist-web-git--checkout-write-guard
                              magit-pre-call-git-hook)
                      magit-pre-call-git-hook))
                   (magit-pre-start-git-hook
                    (if (plist-get intent :local)
                        (remq #'emacsos-assist-web-git--checkout-write-guard
                              magit-pre-start-git-hook)
                      magit-pre-start-git-hook)))
               (magit-diff-range
                (if (plist-get intent :local)
                    "refs/remotes/origin/main...HEAD"
                  (concat (emacsos-assist-web-git-generation-main generation)
                        "..."
                        (or (emacsos-assist-web-git-generation-remote generation)
                            (emacsos-assist-web-git-generation-oid generation)))))
               (delete-other-windows window)
               (let ((view (window-buffer window)))
                 (with-current-buffer view
                   (setq-local emacsos-assist-web-git--view-diff-oid
                               (or (emacsos-assist-web-git-generation-remote generation)
                                   (emacsos-assist-web-git-generation-oid generation)))
                   (emacsos-assist-web-git--pin view thread generation))
                 (if (plist-get intent :local)
                     (let* ((seen (emacsos-assist-web-git-generation-metadata generation))
                            (actual (plist-get seen :local-branch))
                            (selected (with-current-buffer thread
                                        (plist-get (or emacsos-assist-web-git--metadata seen)
                                                   :branch))))
                       (if (equal actual selected)
                           (message "Diff: cached remote/main...local thread HEAD; no sync")
                         (message "Diff: local %s, selected thread %s pending; no sync"
                                  actual selected)))
                   (message "Diff: fetched remote main %s...thread %s"
                          (emacsos-assist-web-git--short
                           (emacsos-assist-web-git-generation-main generation))
                          (emacsos-assist-web-git--short
                           (or (emacsos-assist-web-git-generation-remote generation)
                               (emacsos-assist-web-git-generation-oid generation))))))))))
        ('refresh (message "Thread Git refreshed at %s"
                           (emacsos-assist-web-git-generation-oid generation)))))))

(defun emacsos-assist-web-git--pin (view thread generation)
  "Associate VIEW with GENERATION and THREAD until closed or repinned after sync."
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
            (emacsos-assist-web--padded-action
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
                      (or (emacsos-assist-web-git-generation-remote
                           emacsos-assist-web-git--current)
                          (emacsos-assist-web-git-generation-oid
                           emacsos-assist-web-git--current))
                      (emacsos-assist-web-git--same-identity
                       selected
                       (emacsos-assist-web-git-generation-metadata
                        emacsos-assist-web-git--current))))))
         (view (generate-new-buffer " *Assist Web Git view details*")))
    (with-current-buffer view
      (insert (format "Local checkout HEAD: %s\nFetched remote thread tip: %s\nFetched remote main base: %s\nCheckout selection branch: %s\nActual local branch: %s\n"
                      (or (emacsos-assist-web-git-generation-oid generation)
                          "not read for local browsing")
                      (or (emacsos-assist-web-git-generation-remote generation)
                          "unavailable")
                      (or (emacsos-assist-web-git-generation-main generation)
                          "unavailable")
                      (or (plist-get metadata :branch) "unavailable")
                      (or (plist-get metadata :local-branch) "unavailable")))
      (when (eq (emacsos-assist-web-git-generation-state generation) 'cached)
        (insert "\nLocal cached checkout; browsing performed no fetch. Magit compares cached remote/main against local HEAD.\n"))
      (when selected
        (insert (format "\nSelected branch %s: %s\n"
                        (if chooser-snapshot "at chooser exit" "when Details opened")
                        (or (plist-get selected :branch) "unavailable")))
        (unless (emacsos-assist-web-git--same-identity metadata selected)
          (insert (if selected-fetched
                      "The newer selection has already been fetched; this pinned view is historical.\n"
                    "The selection differs from this pinned view. Return to the thread for its live state.\n"))))
      (when (not (equal (plist-get metadata :status) "ready"))
        (insert (if (emacsos-assist-web-git-generation-remote generation)
                    "\nThis is the last fetched remote tip, not a promise about Assist's local revision."
                  "\nThis is a cached local checkout; its remote tip has not been refreshed."))
        (when (member (plist-get metadata :status)
                      '("queued" "initializing" "cloning" "starting_sandbox"
                        "processing" "running" "pending" "transitioning"))
          (insert " It may change after the active turn."))
        (insert "\n"))
      (if chooser-snapshot
          (insert (format "\nChooser state at exit: %s (not live). File selection ended for Details. No file was selected; typed but unselected input was discarded. Back returns to the thread; C-x C-f starts a new chooser.\n"
                          (car chooser-snapshot)))
        (insert "\nThe header shows live freshness; this text records captured checkout provenance. Back returns to the pinned file or diff.\n"))
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
  "Close a pinned older view and request another fetch."
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
