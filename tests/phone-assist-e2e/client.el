;;; client.el --- Actual phone client against the isolated E2E server -*- lexical-binding: t; -*-
;;; Commentary:
;; Test control supplies user actions; HTTPS, SSE, canonical refresh and Git remain real.
;;; Code:
(require 'assist-web)
(setq emacsos-assist-web-api-url (concat (getenv "ASSIST_E2E_URL") "/api/v1/phone")
      emacsos-assist-web-ca-file "/secrets/ca.crt"
      url-proxy-services nil)

(defvar phone-e2e-stage nil)

(defun phone-e2e-wait (predicate)
  "Wait at most 45 seconds for PREDICATE while processing actual client events."
  (let ((deadline (+ (float-time) 45)) finished)
    (while (and (not (setq finished (funcall predicate))) (< (float-time) deadline))
      (accept-process-output nil 0.05)
      (set-buffer (window-buffer (selected-window))))
    (unless finished
      (error "E2E client deadline: stage=%s buffer=%s snapshot=%s requests=%s git-process=%s posting=%s observing=%s"
             phone-e2e-stage (buffer-name) (and emacsos-assist-web--snapshot t)
             (length emacsos-assist-web--requests) emacsos-assist-web-git--process
             (plist-get emacsos-assist-web--http-draft :posting) emacsos-assist-web--in-flight))))

(defun phone-e2e-request (method path &optional body)
  "Make a real client METHOD request to PATH with BODY and await its receipt."
  (let (finished value failure)
    (emacsos-assist-web--request
     method path body
     (lambda (result problem) (setq value result failure problem finished t)))
    (phone-e2e-wait (lambda () finished))
    (when failure (error "%s" failure))
    value))

(defun phone-e2e-open (tid)
  "Open TID through the production thread command and wait for canonical state."
  (emacsos-assist-web--show-thread `((id . ,tid) (description . "E2E thread") (repo_label . "domain")))
  (set-buffer (window-buffer (selected-window)))
  (phone-e2e-wait (lambda () emacsos-assist-web--snapshot)))

(defun phone-e2e-result ()
  "Return observable client state without private credentials."
  `((thread_id . ,emacsos-assist-web--thread-id)
    (checkout . ,(emacsos-assist-web-git-local-directory))
    (git . ,emacsos-assist-web-git--result)
    (git_error . ,emacsos-assist-web-git--unavailable)
    (denied . ,(eq emacsos-assist-web--denied t))
    (text . ,(buffer-string))))

(defun phone-e2e-auth-recovery ()
  "Deny then reauthorize one resident buffer through real canonical requests."
  (let ((buffer (current-buffer))
        (initial-epoch emacsos-assist-web--auth-epoch) old-git-result)
    (phone-e2e-wait (lambda () (and (not emacsos-assist-web--requests)
                                  (not emacsos-assist-web-git--process)
                                  emacsos-assist-web-git--result)))
    (setq old-git-result emacsos-assist-web-git--result)
    (with-temp-file emacsos-assist-web-token-file (insert "invalid"))
    (emacsos-assist-web-refresh-thread)
    (phone-e2e-wait (lambda () (eq emacsos-assist-web--denied t)))
    (let ((denied-epoch emacsos-assist-web--auth-epoch))
      (phone-e2e-wait (lambda () (not emacsos-assist-web--requests)))
      (copy-file "/secrets/token" emacsos-assist-web-token-file t)
      (let ((old-snapshot emacsos-assist-web--snapshot))
        (call-interactively #'emacsos-assist-web-refresh-thread)
        (phone-e2e-wait
         (lambda () (and (not (eq old-snapshot emacsos-assist-web--snapshot))
                         (not emacsos-assist-web--requests)
                         (not emacsos-assist-web--denied)
                         emacsos-assist-web-git--result
                         (not (eq old-git-result emacsos-assist-web-git--result))
                         (not emacsos-assist-web-git--process)
                         (not emacsos-assist-web-git--unavailable)))))
      `((auth_denied_seen . t) (canonical_refreshed . t) (git_refreshed . t)
        (auth_initial_epoch . ,initial-epoch)
        (auth_denied_epoch . ,denied-epoch)
        (same_buffer . ,(eq buffer (current-buffer)))))))

(defun phone-e2e-observer-recovery (text)
  "Lose the real observer then Refresh its terminal Run in the same buffer."
  (let ((buffer (current-buffer)))
    (emacsos-assist-web--replace-input text)
    (emacsos-assist-web-send)
    (setq phone-e2e-stage "wait-live-observer")
    (phone-e2e-wait
     (lambda () (and emacsos-assist-web--in-flight
                     (process-live-p emacsos-assist-web--stream-process))))
    (let ((run-id emacsos-assist-web--run-id))
      (setq phone-e2e-stage "close-observer")
      (delete-process emacsos-assist-web--stream-process)
      (phone-e2e-wait
       (lambda () (and (equal emacsos-assist-web--run-id run-id)
                       (not emacsos-assist-web--stream-process))))
      (setq phone-e2e-stage "release-exact-model-hold")
      (phone-e2e-wait
       (lambda ()
         (let ((tid emacsos-assist-web--thread-id))
           (with-temp-buffer
             (let ((status (call-process
                 "python" nil '(t t) nil "-c"
                 "import json,os,ssl,sys,urllib.request; from pathlib import Path; h={'Authorization':'Bearer '+Path('/secrets/token').read_text().strip(),'Content-Type':'application/json'}; c=ssl.create_default_context(cafile='/secrets/ca.crt'); u=os.environ['ASSIST_E2E_URL']; v=urllib.request.urlopen(urllib.request.Request(u+'/__e2e/state/'+sys.argv[1],headers=h),context=c,timeout=5); sys.exit(1) if 'Hold observer' not in json.load(v)['holds'] else None; r=urllib.request.urlopen(urllib.request.Request(u+'/__e2e/release',data=json.dumps({'text':'Hold observer'}).encode(),headers=h),context=c,timeout=5); r.close()"
                 tid)))
               (when (and (not (zerop status)) (> (buffer-size) 0))
                 (error "Fixture hold release failed: %s" (buffer-string)))
               (zerop status))))))
      (setq phone-e2e-stage "wait-exact-run-success")
      (phone-e2e-wait
       (lambda () (equal (alist-get 'status (phone-e2e-request
                    "GET" (format "threads/%s/runs/%s" emacsos-assist-web--thread-id run-id)))
                         "success")))
      (setq phone-e2e-stage "refresh-terminal-run")
      (call-interactively #'emacsos-assist-web-refresh-thread)
      (phone-e2e-wait (lambda () (and (not emacsos-assist-web--http-draft)
                                     (not emacsos-assist-web--requests)
                                     (not emacsos-assist-web--run-id)
                                     (not emacsos-assist-web--pending-accepted-p)
                                     (not emacsos-assist-web--in-flight))))
      `((observer_lost . t) (observer_retired . t)
        (same_buffer . ,(eq buffer (current-buffer)))))))

(defun phone-e2e-button (predicate)
  "Find an actual native button whose label satisfies PREDICATE."
  (let ((button (next-button (point-min) t)) found)
    (while (and button (not found))
      (if (funcall predicate (button-label button))
          (setq found button)
        (setq button (next-button (button-end button)))))
    (or found (error "Expected native approval control is absent"))))

(defun phone-e2e-require-preview (text expected)
  "Require fixture EXPECTED fields in rendered TEXT before any confirmation."
  (unless (and (consp expected) (seq-every-p #'stringp expected))
    (error "Approval fixture omitted its expected preview fields"))
  (dolist (field expected)
    (unless (string-match-p (regexp-quote field) text)
      (error "Approval preview missing fixture field: %s" field))))

(defun phone-e2e-approval (kind &optional expected)
  "Verify fixture EXPECTED fields and confirm KIND through the real shared client."
  (let ((source (current-buffer)) preview text original-run discovery)
    (phone-e2e-wait (lambda () (and emacsos-assist-web--snapshot
                                   (not emacsos-assist-web--requests))))
    (when (member kind '("send_email" "email_archive" "email_delete"))
      (emacsos-assist-web--replace-input (concat "Synthetic approval:" kind))
      (emacsos-assist-web-send)
      (phone-e2e-wait (lambda () emacsos-assist-web--run-id))
      (setq original-run emacsos-assist-web--run-id)
      (phone-e2e-wait (lambda () (not emacsos-assist-web--in-flight)))
      (unless original-run (error "Stopped approval lost its original Run receipt"))
      (emacsos-assist-web-refresh-thread)
      (phone-e2e-wait (lambda () (not emacsos-assist-web--requests))))
    (when (member kind '("egress" "geo_download"))
      (unless (equal (alist-get 'status (alist-get 'thread emacsos-assist-web--snapshot)) "ready")
        (error "Independent approval fixture did not reach ready Run state")))
    (emacsos-assist-web--replace-input "Synthetic unsent draft")
    (setq discovery "thread-review")
    (button-activate (phone-e2e-button (lambda (label) (equal label "Review pending action"))))
    (phone-e2e-wait
     (lambda () (and (setq preview (get-buffer (format "*assist Approval %s*"
                                                      (buffer-local-value 'emacsos-assist-web--thread-id source))))
                     (not (buffer-local-value 'emacsos-assist-web--requests source)))))
    (with-current-buffer preview
      (unless emacsos-assist-web--approval
        (button-activate
         (phone-e2e-button (lambda (label)
                             (and (string-prefix-p (concat kind ":") label)
                                  (string-suffix-p "[pending]" label))))))
      (unless (equal (alist-get 'kind emacsos-assist-web--approval) kind)
        (error "Wrong approval kind opened"))
      (setq text (buffer-string))
      (phone-e2e-require-preview text expected)
      (let* ((label (cond ((equal kind "egress") "Allow for 1 hour")
                          ((equal kind "geo_download") "Approve download")
                          ((member kind '("send_email" "send_reply")) "Approve and send")
                          (t "Approve")))
             (button (phone-e2e-button (lambda (value) (equal value label)))))
        (button-activate button)
        (when (plist-get (emacsos-assist-web--thread-safety-record emacsos-assist-web--thread-id)
                         :approval-pending)
          (error "First tap submitted a decision"))
        (button-activate button)))
    (phone-e2e-wait (lambda () (and (not (buffer-live-p preview))
                                   (not (buffer-local-value 'emacsos-assist-web--requests source)))))
    (set-buffer source)
    (when original-run
      (phone-e2e-wait (lambda () (and (not emacsos-assist-web--http-draft)
                                     (not emacsos-assist-web--in-flight)
                                     (not emacsos-assist-web--run-id)
                                     (not emacsos-assist-web--pending-accepted-p)
                                     (not emacsos-assist-web--requests))))
      (unless (equal (alist-get 'status
                               (phone-e2e-request "GET" (format "threads/%s/runs/%s"
                                                               emacsos-assist-web--thread-id original-run)))
                     "success")
        (error "Original stopped Run did not reconcile to success")))
    (unless (equal (emacsos-assist-web--input) "Synthetic unsent draft")
      (error "Approval lost the unsent draft"))
    `((approval_kind . ,kind) (approval_preview . ,text) (preview_fields_verified . t)
      (two_taps . t) (draft_preserved . t) (discovery_used . t) (discovery_control . ,discovery)
      (original_run . ,original-run) (original_run_reconciled . ,(and original-run t)))))

(defun phone-e2e-main (action tid text &optional expected-json)
  "Run user ACTION on TID with TEXT and fixture EXPECTED-JSON; print its receipt."
  (condition-case problem
      (let (recovery)
        (when (equal action "approval-desktop")
          (load "/src/emacsos/assist-desktop.el" nil t))
        (when (equal action "accepted-fresh")
          (setq emacsos-assist-web-cache-directory
                (make-temp-file "/home/test/e2e-client-cache-" t)
                action "accepted"))
        (cond
         ((equal action "new")
          (let* ((catalog (phone-e2e-request "GET" "threads"))
                 (repo (car (alist-get 'repositories catalog)))
                 (buffer (get-buffer-create "*assist New thread*")))
            (with-current-buffer buffer
              (emacsos-assist-web-mode)
              (setq emacsos-assist-web--draft-id "new-thread"
                    emacsos-assist-web--draft-repository (alist-get 'repo_key repo)
                    emacsos-assist-web--draft-harness "deepagents")
              (emacsos-assist-web--write-prompt))
            (switch-to-buffer buffer)))
         ((equal action "denied")
          (condition-case nil (phone-e2e-open tid) (error nil))
          (phone-e2e-wait (lambda () (eq emacsos-assist-web--denied t))))
         (t (phone-e2e-open tid)))
        (cond
         ((equal action "auth-recovery") (setq recovery (phone-e2e-auth-recovery)))
         ((equal action "observer-recovery") (setq recovery (phone-e2e-observer-recovery text)))
         ((member action '("approval" "approval-desktop"))
          (setq recovery (phone-e2e-approval text
                           (and expected-json (json-parse-string expected-json :array-type 'list :null-object nil))))))
        (when (member action '("new" "send" "accepted"))
          (emacsos-assist-web--replace-input text)
          (emacsos-assist-web-send)
          (if (equal action "accepted")
              (phone-e2e-wait
               (lambda ()
                 (and (not emacsos-assist-web--http-draft)
                      emacsos-assist-web--run-id)))
            (phone-e2e-wait
             (lambda () (and (not emacsos-assist-web--http-draft)
                             (not emacsos-assist-web--in-flight)
                             emacsos-assist-web--thread-id)))))
        (when (member action '("new" "send" "refresh"))
          (emacsos-assist-web-refresh-thread)
          (phone-e2e-wait (lambda () (not emacsos-assist-web--requests)))
          (phone-e2e-wait (lambda () (not emacsos-assist-web-git--process)))
          (when (plist-get emacsos-assist-web-git--metadata :branch)
            (emacsos-assist-web-git-refresh)
            (phone-e2e-wait (lambda () (not emacsos-assist-web-git--process)))))
        (princ (concat "E2E_JSON:" (json-encode (append recovery (phone-e2e-result))) "\n")))
    (error
     (when (get-buffer "*Messages*")
       (princ (with-current-buffer "*Messages*" (buffer-string))))
     (princ (concat "E2E_JSON:" (json-encode `((error . ,(error-message-string problem)))) "\n"))
     (kill-emacs 1))))
(provide 'phone-e2e-client)
;;; client.el ends here
