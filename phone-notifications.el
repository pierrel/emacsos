;;; phone-notifications.el --- Private reasons for phone feedback -*- lexical-binding: t; -*-
(require 'cl-lib)
(require 'json)
(require 'subr-x)

(defvar emacsos-notifications-file
  (expand-file-name "emacsos/notifications.jsonl"
                    (or (getenv "XDG_STATE_HOME") "~/.local/state/"))
  "Private local reason journal, independent of SMS/server configuration.")
(defconst emacsos-notifications--limit 256)
(defconst emacsos-notifications--bytes (* 128 1024))
(defvar emacsos-notifications--sequence 0)

(defun emacsos-notifications--rows ()
  "Read the bounded journal; refuse corrupt or redirected storage."
  (when (file-symlink-p emacsos-notifications-file)
    (error "Notification journal is a symlink"))
  (when (file-exists-p emacsos-notifications-file)
    (unless (and (file-regular-p emacsos-notifications-file)
                 (<= (file-attribute-size (file-attributes emacsos-notifications-file))
                     emacsos-notifications--bytes))
      (error "Notification journal is unavailable or too large"))
    (with-temp-buffer
      (insert-file-contents emacsos-notifications-file)
      (mapcar (lambda (line)
                (json-parse-string line :object-type 'alist :array-type 'list))
              (split-string (buffer-string) "\n" t)))))

(defun emacsos-notifications--record (source reason event id)
  "Persist a lifecycle EVENT with SOURCE, explicit REASON and correlation ID."
  (unless (and (symbolp source) (<= (length (symbol-name source)) 40)
               (not (string-match-p "[[:cntrl:]]" (symbol-name source))) (stringp reason)
               (not (string-empty-p (string-trim reason)))
               (<= (length reason) 200) (not (string-match-p "[[:cntrl:]]" reason)))
    (error "Notification source and reason are required"))
  (let* ((rows (emacsos-notifications--rows))
         (directory (file-name-directory emacsos-notifications-file))
         (row `((at . ,(format-time-string "%Y-%m-%dT%H:%M:%SZ" nil t))
                (id . ,id) (source . ,(symbol-name source))
                (event . ,event) (reason . ,reason)))
         temporary)
    (when (file-symlink-p (directory-file-name directory))
      (error "Notification directory is a symlink"))
    (make-directory directory t)
    (set-file-modes directory #o700)
    (setq rows (last (append rows (list row)) emacsos-notifications--limit))
    (unwind-protect
        (progn
          (setq temporary (make-temp-file (expand-file-name ".notifications-" directory)))
          (with-temp-buffer
            (dolist (item rows) (insert (json-encode item) "\n"))
            (when (> (string-bytes (buffer-string)) emacsos-notifications--bytes)
              (error "Notification journal exceeds its limit"))
            (write-region (point-min) (point-max) temporary nil 'silent))
          (set-file-modes temporary #o600)
          (rename-file temporary emacsos-notifications-file t)
          (setq temporary nil))
      (when temporary (delete-file temporary)))
    id))

(defun emacsos-notifications-record (source reason)
  "Record a notification with a generic REASON; return its local identity."
  (emacsos-notifications--record
   source reason "recorded"
   (format "%s-%d-%d" (format-time-string "%s%N") (emacs-pid)
           (cl-incf emacsos-notifications--sequence))))

(defun emacsos-notifications-feedback (source reason &optional id)
  "Record each finite feedback request before starting its client.
A recorded request is not proof of physical vibration. Client failures are
recorded separately. Storage failure suppresses the feedback request."
  (condition-case nil
      (let* ((id (or id (emacsos-notifications-record source reason)))
             (command (pcase source
                        ('sms '("message-new-sms" "1" "4" 5))
                        ('call '("phone-incoming-call" "2" "3" 4))
                        (_ (error "Unsupported feedback source"))))
             process output timer)
        (emacsos-notifications--record source reason "vibration-requested" id)
        (setq output (generate-new-buffer " *phone-feedback*"))
        (cl-labels ((failure (kind)
                      (condition-case nil
                          (emacsos-notifications--record source reason kind id)
                        (error (message "Notification outcome could not be saved.")))))
          (condition-case nil
              (setq process
                    (make-process
                     :name "emacsos-notification-feedback" :noquery t :buffer output
                     :command (list "/usr/bin/fbcli" (concat "--event=" (nth 0 command))
                                    "--profile=quiet" (concat "--timeout=" (nth 1 command))
                                    (concat "--watch=" (nth 2 command)))
                     :filter (lambda (_ text)
                               (when (buffer-live-p output)
                                 (with-current-buffer output
                                   (insert (substring text 0 (min (length text)
                                                                (max 0 (- 8192 (buffer-size)))))))))
                     :sentinel (lambda (client _event)
                                 (when (memq (process-status client) '(exit signal))
                                   (when (timerp timer) (cancel-timer timer))
                                   (unless (process-get client 'notification-stopped)
                                     (cond
                                      ((not (zerop (process-exit-status client)))
                                       (failure "client-failed"))
                                      ((and (buffer-live-p output)
                                            (with-current-buffer output
                                              (string-match-p "No feedback found" (buffer-string))))
                                       (failure "client-no-effect"))))
                                   (when (buffer-live-p output) (kill-buffer output))))))
            (error (failure "client-start-failed")
                   (when (buffer-live-p output) (kill-buffer output))))
          (when process
            (process-put process 'notification-reason (list source reason id))
            (setq timer
                  (run-at-time (nth 3 command) nil
                               (lambda ()
                                 (when (process-live-p process)
                                   (process-put process 'notification-stopped t)
                                   (failure "client-timeout")
                                   (delete-process process))))))
        process))
    (error (message "Notification could not be saved; vibration not requested.") nil)))

(defun emacsos-notifications-stop-feedback (process)
  "Stop an existing feedback PROCESS without reporting intentional stop as failure."
  (when (process-live-p process)
    (process-put process 'notification-stopped t)
    (when-let ((reason (process-get process 'notification-reason)))
      (condition-case nil
          (emacsos-notifications--record
           (nth 0 reason) (nth 1 reason) "client-stopped" (nth 2 reason))
        (error (message "Notification stop could not be saved."))))
    (delete-process process)))

(defun emacsos-notifications-show ()
  "Show private notification reasons and request outcomes in a read-only buffer."
  (interactive)
  (let ((rows (emacsos-notifications--rows))
        (buffer (get-buffer-create "*Phone notifications*")))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Phone notifications\n\nRecorded/requested does not prove physical vibration.\n\n")
        (if rows
            (dolist (row (reverse rows))
              (insert (format "%s  %s  %s\n  %s\n\n"
                              (alist-get 'at row) (alist-get 'source row)
                              (alist-get 'event row) (alist-get 'reason row))))
          (insert "No recorded notifications.\n")))
      (special-mode)
      (setq-local revert-buffer-function
                  (lambda (&rest _) (emacsos-notifications-show))))
    (pop-to-buffer buffer)))

(provide 'phone-notifications)
;;; phone-notifications.el ends here
