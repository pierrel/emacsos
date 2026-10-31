;;; phone-assist-notifications.el --- Consume reasoned Assist phone alerts -*- lexical-binding: t; -*-
(require 'assist-web)
(require 'phone-notifications)

(defvar emacsos-phone-notifications--owner nil)
(defvar emacsos-phone-notifications--timer nil)

(defun emacsos-phone-notifications--valid-alert-p (alert)
  "Accept only bounded identifiers and a display-safe reason from Assist."
  (let ((id (alist-get 'id alert)) (reason (alist-get 'reason alert)))
    (and (emacsos-assist-web--valid-id-p (alist-get 'thread_id alert))
         (stringp id) (string-match-p "\\`[0-9a-f]\\{32\\}\\'" id)
         (emacsos-notifications-valid-reason-p reason))))

(defun emacsos-phone-notifications--consume (alerts owner)
  "Handle ALERTS serially for the current poll OWNER, then release it."
  (when (eq owner emacsos-phone-notifications--owner)
    (if (null alerts)
        (setq emacsos-phone-notifications--owner nil)
      (condition-case nil
          (let* ((alert (car alerts))
                 (tid (alist-get 'thread_id alert))
                 (id (alist-get 'id alert))
                 (reason (alist-get 'reason alert))
                 (name (format "phone-notifications/%s.json" tid))
                 (previous (emacsos-assist-web--read-cache name)))
            ;; An unreadable existing receipt is not evidence of a new alert.
            (when (and (file-exists-p (emacsos-assist-web--cache-path name))
                       (not (and (stringp (alist-get 'id previous))
                                 (string-match-p "\\`[0-9a-f]\\{32\\}\\'" (alist-get 'id previous)))))
              (error "Phone alert receipt unavailable"))
            (unless (equal (alist-get 'id previous) id)
              (emacsos-notifications--record 'assist reason "recorded" id)
              (unless (emacsos-assist-web--try-write-cache name `((id . ,id)))
                (error "Phone alert receipt could not be saved"))
              ;; The durable per-thread receipt owns at-most-once attempts;
              ;; the bounded display journal is not deduplication authority.
              (emacsos-notifications-feedback 'assist reason id))
            (emacsos-assist-web--request
             "POST" (format "notifications/%s/%s/ack" tid id) nil
             (lambda (_value _problem)
               ;; A failed ACK is retried by a later poll, without another buzz.
               (emacsos-phone-notifications--consume (cdr alerts) owner))))
        (error
         (message "Assist phone alert unavailable; no unrecorded vibration requested.")
         (emacsos-phone-notifications--consume (cdr alerts) owner))))))

(defun emacsos-phone-notifications--buffer-killed ()
  "Release the poll owner when its hidden request buffer is retired."
  (setq emacsos-phone-notifications--owner nil))

(defun emacsos-phone-notifications-poll ()
  "Read pending Assist alerts without overlapping poll/ACK callbacks."
  (interactive)
  (unless emacsos-phone-notifications--owner
    (let ((owner (list 'poll))
          (buffer (get-buffer-create " *Assist phone notifications*")))
      (setq emacsos-phone-notifications--owner owner)
      (with-current-buffer buffer
        (add-hook 'kill-buffer-hook #'emacsos-phone-notifications--buffer-killed nil t)
        (condition-case nil
            (emacsos-assist-web--request
             "GET" "notifications" nil
             (lambda (value problem)
               (when (eq owner emacsos-phone-notifications--owner)
                 (condition-case nil
                     (let ((alerts (alist-get 'notifications value)))
                       (if (or problem (not (listp alerts)) (> (length alerts) 16)
                               (not (seq-every-p #'emacsos-phone-notifications--valid-alert-p alerts)))
                           (error "Invalid phone alert response")
                         (emacsos-phone-notifications--consume alerts owner)))
                   (error
                    (when (eq owner emacsos-phone-notifications--owner)
                      (setq emacsos-phone-notifications--owner nil))
                    (message "Assist phone alerts unavailable."))))))
          (error (setq emacsos-phone-notifications--owner nil)
                 (message "Assist phone alerts unavailable.")))))))

(defun emacsos-phone-notifications-start ()
  "Start the phone UI's single bounded attention poller."
  (unless (timerp emacsos-phone-notifications--timer)
    (setq emacsos-phone-notifications--timer
          (run-at-time 0 30 #'emacsos-phone-notifications-poll))))

(provide 'phone-assist-notifications)
;;; phone-assist-notifications.el ends here
