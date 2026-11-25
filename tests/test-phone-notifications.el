;;; test-phone-notifications.el --- Local reason journal checks -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'phone-notifications)
(defmacro notifications-test-journal (&rest body)
  `(let* ((directory (make-temp-file "notifications-test-" t))
          (emacsos-notifications-file (expand-file-name "state/notifications.jsonl" directory))
          (emacsos-notifications--unavailable nil)
          (emacsos-notifications--unread nil))
     (unwind-protect (progn ,@body) (delete-directory directory t))))

(ert-deftest notifications-persist-and-view-through-real-command-key ()
  (notifications-test-journal
   (require 'os)
   (let ((id (emacsos-notifications-record 'sms "Raw modem event; novelty unverified")))
     (should (stringp id))
     (should (= (file-modes emacsos-notifications-file) #o600))
     (should (equal (alist-get 'reason (car (emacsos-notifications--rows)))
                    "Raw modem event; novelty unverified")))
   (should (eq (key-binding (kbd "C-c e n")) #'emacsos-notifications-show))
   (save-window-excursion
     (call-interactively (lookup-key emacsos-command-map (kbd "n")))
     (should (eq major-mode 'special-mode))
     (should buffer-read-only)
     (should (= (point) (point-min)))
     (emacsos-notifications-record 'system "Synthetic refresh reason")
     (revert-buffer t t)
     (should (string-match-p "Synthetic refresh reason" (buffer-string)))
     (should (string-match-p "Raw modem event" (buffer-string))))))

(ert-deftest notifications-require-reason-and-suppress-effect-on-storage-failure ()
  (notifications-test-journal
   (let (client-attempted)
     (cl-letf (((symbol-function 'make-process)
                (lambda (&rest _) (setq client-attempted t) nil)))
       (should-not (emacsos-notifications-feedback 'sms ""))
       (should-not client-attempted)
       (cl-letf (((symbol-function 'rename-file) (lambda (&rest _) (error "Disk failure"))))
         (should-not (emacsos-notifications-feedback 'call "Incoming call")))
       (should-not client-attempted)))))

(ert-deftest notifications-each-request-precedes-client-and-reports-failure ()
  (notifications-test-journal
   (let (args props timer)
     (cl-letf (((symbol-function 'make-process)
                (lambda (&rest value)
                  (should (equal (alist-get 'event (car (last (emacsos-notifications--rows))))
                                 "vibration-requested"))
                  (setq args value) 'fake))
               ((symbol-function 'process-put) (lambda (_ key value) (setf (alist-get key props) value)))
               ((symbol-function 'process-get) (lambda (_ key) (alist-get key props)))
               ((symbol-function 'run-at-time) (lambda (_ _ fn) (setq timer fn) nil))
               ((symbol-function 'process-status) (lambda (_) 'exit))
               ((symbol-function 'process-exit-status) (lambda (_) 1)))
       (let ((id (emacsos-notifications-record 'call "Incoming call")))
         (emacsos-notifications-feedback 'call "Incoming call pulse" id)
         (funcall (plist-get args :sentinel) 'fake "finished")
         (should (equal (alist-get 'event (car (last (emacsos-notifications--rows)))) "client-failed"))
         (emacsos-notifications-feedback 'call "Incoming call pulse" id)
         (with-current-buffer (plist-get args :buffer) (insert "No feedback found"))
         (cl-letf (((symbol-function 'process-exit-status) (lambda (_) 0)))
           (funcall (plist-get args :sentinel) 'fake "finished"))
         (let ((rows (emacsos-notifications--rows)))
           (should (= 1 (cl-count "recorded" rows :key (lambda (row) (alist-get 'event row)) :test #'equal)))
           (should (= 2 (cl-count "vibration-requested" rows :key (lambda (row) (alist-get 'event row)) :test #'equal)))
           (should (equal (alist-get 'event (car (last rows))) "client-no-effect"))))))))

(ert-deftest notifications-stop-still-stops-if-journal-fails ()
  (let (stopped)
    (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
              ((symbol-function 'process-put) (lambda (&rest _) nil))
              ((symbol-function 'process-get) (lambda (&rest _) '(call "Incoming call" "test")))
              ((symbol-function 'emacsos-notifications--record) (lambda (&rest _) (error "Disk failure")))
              ((symbol-function 'delete-process) (lambda (_) (setq stopped t))))
      (emacsos-notifications-stop-feedback 'fake)
      (should stopped))))

(ert-deftest notifications-bounded-journal-retains-newest ()
  (notifications-test-journal
   (let ((emacsos-notifications--limit 2))
     (dotimes (i 3) (emacsos-notifications-record 'sms (format "Synthetic reason %d" i)))
     (let ((rows (emacsos-notifications--rows)))
       (should (= 2 (length rows)))
       (should (equal (alist-get 'reason (car rows)) "Synthetic reason 1"))))))

(ert-deftest notifications-refuse-symlink-storage ()
  (notifications-test-journal
   (let ((target (expand-file-name "target" directory)))
     (write-region "private" nil target nil 'silent)
     (make-directory (file-name-directory emacsos-notifications-file) t)
     (make-symbolic-link target emacsos-notifications-file)
     (should-error (emacsos-notifications-record 'sms "Synthetic reason"))
     (should (equal (with-temp-buffer (insert-file-contents target) (buffer-string)) "private")))))

(ert-deftest notifications-byte-budget-evicts-old-multibyte-rows ()
  (notifications-test-journal
   (let* ((emacsos-notifications--bytes 1200)
          (reason (make-string 200 #x1f600))
          (old (emacsos-notifications-record 'system reason)))
     (emacsos-notifications-record 'system reason)
     (emacsos-notifications-record 'sms "Synthetic incoming event")
     (let ((rows (emacsos-notifications--rows)))
       (should-not (cl-find old rows :key (lambda (row) (alist-get 'id row)) :test #'equal))
       (should (equal (alist-get 'reason (car (last rows))) "Synthetic incoming event")))
     (should (<= (file-attribute-size (file-attributes emacsos-notifications-file)) 1200)))))

(ert-deftest notifications-oversized-new-row-preserves-existing-journal ()
  (notifications-test-journal
   (emacsos-notifications-record 'system "Synthetic existing entry")
   (let ((before (with-temp-buffer (insert-file-contents emacsos-notifications-file) (buffer-string)))
         (emacsos-notifications--bytes 400))
     (should-error (emacsos-notifications-record 'system (make-string 200 #x1f600)))
     (should (equal before (with-temp-buffer (insert-file-contents emacsos-notifications-file) (buffer-string)))))))

(ert-deftest notifications-logical-view-badge-shortcut-and-tap ()
  "One reason/time per identity survives reload, then opening clears attention."
  (notifications-test-journal
   (require 'os)
   (emacsos-notifications--record 'assist "Synthetic deadline" "recorded" "one")
   (emacsos-notifications--record 'assist "Synthetic feedback" "vibration-requested" "one")
   (emacsos-notifications--record 'assist "Synthetic deadline" "recorded" "one")
   (should (member '(:eval (emacsos-notifications-mode-line-string))
                   (emacsos--mode-line-format)))
   (should-not (member '(:eval (emacsos-sms-mode-line-string))
                       (emacsos--mode-line-format)))
   ;; A fresh UI process derives unread state from the same durable journal.
   (setq emacsos-notifications--unread nil)
   (emacsos-notifications--initialize)
   (let ((badge (emacsos-notifications-mode-line-string)))
     (should (string-match-p "Notifications" badge))
     (should-not (string-match-p "SMS" badge))
     (save-window-excursion
       (call-interactively
        (lookup-key (get-text-property 0 'local-map badge) [mode-line mouse-1]))
       (should (eq major-mode 'special-mode))
       (should buffer-read-only)
       (goto-char (point-min))
       (should (= 1 (how-many "Synthetic deadline")))
       (should (re-search-forward "[0-9]\\{4\\}-[0-9]\\{2\\}-[0-9]\\{2\\}T" nil t))
       (should-not (string-match-p "vibration-requested\\|Synthetic feedback" (buffer-string)))))
   (should (equal (emacsos-notifications-mode-line-string) ""))
   (emacsos-notifications--record 'assist "Synthetic failed client" "client-failed" "one")
   (should (equal (emacsos-notifications-mode-line-string) ""))
   (emacsos-notifications--initialize)
   (should (equal (emacsos-notifications-mode-line-string) ""))
   (emacsos-notifications-record 'call "Synthetic incoming call")
   (should (string-match-p "Notifications" (emacsos-notifications-mode-line-string)))
   (save-window-excursion
     (call-interactively (key-binding (kbd "C-c e n"))))
   (should (equal (emacsos-notifications-mode-line-string) ""))))

(ert-deftest notifications-opening-preserves-an-arrival-after-the-snapshot ()
  "Opening cannot mark a newly arrived but undisplayed alert read."
  (notifications-test-journal
   (emacsos-notifications-record 'sms "Synthetic first alert")
   (let ((show (symbol-function 'pop-to-buffer)))
     (save-window-excursion
       (cl-letf (((symbol-function 'pop-to-buffer)
                  (lambda (&rest args)
                    (emacsos-notifications-record 'assist "Synthetic later alert")
                    (apply show args))))
         (emacsos-notifications-show))
       (should-not (string-match-p "Synthetic later alert" (buffer-string)))))
   (should (string-match-p "Notifications" (emacsos-notifications-mode-line-string)))
   (save-window-excursion (emacsos-notifications-show))
   (should (equal (emacsos-notifications-mode-line-string) ""))))

(ert-deftest notifications-outgoing-sms-retains-status-without-alerting ()
  "A hidden outgoing result has no generic badge, journal alert or success notice."
  (notifications-test-journal
   (require 'phone-sms)
   (let ((emacsos-sms--state 'sending)
         (emacsos-sms--proposal-id "synthetic-outgoing")
         (emacsos-sms-lifecycle-functions (list #'emacsos-sms--notification))
         notice)
     (cl-letf (((symbol-function 'emacsos-sms--visible-p) (lambda () nil))
               ((symbol-function 'emacsos-sms--render) #'ignore)
               ((symbol-function 'message) (lambda (&rest args) (setq notice args))))
       (emacsos-sms--finished "synthetic-outgoing" "sent"))
     (should (eq emacsos-sms--state 'sent))
     (should (equal emacsos-sms--detail "Modem accepted the message."))
     (should-not notice)
     (should-not (emacsos-notifications--rows))
     (should (equal (emacsos-notifications-mode-line-string) "")))))

(ert-deftest notifications-read-ack-failure-keeps-attention ()
  "A failed durable read acknowledgment leaves the alert and indicator intact."
  (notifications-test-journal
   (emacsos-notifications-record 'assist "Synthetic pending alert")
   (save-window-excursion
     (cl-letf (((symbol-function 'rename-file) (lambda (&rest _) (error "Synthetic disk failure"))))
       (should-error (emacsos-notifications-show))))
   (should (string-match-p "Notifications" (emacsos-notifications-mode-line-string)))
   (should-not (alist-get 'seen (car (emacsos-notifications--rows))))))

(ert-deftest notifications-modeline-does-not-reread-the-journal ()
  "Redisplay uses the committed unread cache rather than repeated disk reads."
  (notifications-test-journal
   (emacsos-notifications-record 'assist "Synthetic cached alert")
   (cl-letf (((symbol-function 'emacsos-notifications--rows)
              (lambda () (ert-fail "modeline reread the journal"))))
     (dotimes (_ 3)
       (should (string-match-p "Notifications" (emacsos-notifications-mode-line-string)))))))

(ert-deftest notifications-outgoing-failure-and-unknown-need-generic-attention ()
  "Terminal failures and uncertainty alert without leaking recipient or body."
  (require 'phone-sms)
  (dolist (outcome '(("not-sent:send-failed" . "not sent")
                     ("unknown:send-failed" . "unknown.*do not resend")))
    (notifications-test-journal
     (let ((emacsos-sms--state 'sending)
           (emacsos-sms-lifecycle-functions (list #'emacsos-sms--notification))
           (emacsos-sms--proposal-id "synthetic-result")
           (emacsos-sms--number "+15555550123")
           (emacsos-sms--body "Synthetic private content"))
       (cl-letf (((symbol-function 'emacsos-sms--visible-p) (lambda () nil))
                 ((symbol-function 'emacsos-sms--render) #'ignore))
         (emacsos-sms--finished "synthetic-result" (car outcome)))
       (let ((alerts (emacsos-notifications--alerts (emacsos-notifications--rows))))
         (should (= 1 (length alerts)))
         (should (string-match-p (cdr outcome) (alist-get 'reason (car alerts))))
         (should-not (string-match-p (regexp-opt '("15555550123" "private content"))
                                     (alist-get 'reason (car alerts)))))
       (should (string-match-p "Notifications" (emacsos-notifications-mode-line-string)))))))

(ert-deftest notifications-journal-failure-stays-visible-without-redisplay-io ()
  "A cached storage error is visible and never retried by redisplay."
  (notifications-test-journal
   (cl-letf (((symbol-function 'rename-file) (lambda (&rest _) (error "Synthetic disk failure"))))
     (should-error (emacsos-notifications-record 'system "Synthetic alert")))
   (let ((reads 0))
     (cl-letf (((symbol-function 'emacsos-notifications--rows)
                (lambda () (cl-incf reads) (error "Must not retry"))))
       (dotimes (_ 3)
         (should (string-match-p "Notifications unavailable"
                                 (emacsos-notifications-mode-line-string)))))
     (should (zerop reads)))))

(ert-deftest notifications-retained-identity-is-a-capacity-and-write-noop ()
  "Retries retain bytes, original metadata and read state without using capacity."
  (notifications-test-journal
   (let ((emacsos-notifications--limit 2))
     (emacsos-notifications--record 'assist "Synthetic original" "recorded" "retained")
     (emacsos-notifications--record 'call "Synthetic second" "recorded" "second")
     (save-window-excursion (emacsos-notifications-show))
     (let ((before (with-temp-buffer
                     (insert-file-contents emacsos-notifications-file) (buffer-string)))
           (write (symbol-function 'emacsos-notifications--write-rows))
           (writes 0))
       (cl-letf (((symbol-function 'emacsos-notifications--write-rows)
                  (lambda (rows) (cl-incf writes) (funcall write rows))))
         (dotimes (_ 10)
           (emacsos-notifications--record 'assist "Synthetic changed retry" "recorded" "retained")))
       (should (zerop writes))
       (should (equal before (with-temp-buffer
                               (insert-file-contents emacsos-notifications-file) (buffer-string))))
       (should (= 2 (length (emacsos-notifications--rows))))
       (should-not emacsos-notifications--unread))
     ;; Genuinely new alerts can evict an old identity; this is not a forever claim.
     (emacsos-notifications--record 'system "Synthetic third" "recorded" "third")
     (emacsos-notifications--record 'assist "Synthetic after eviction" "recorded" "retained")
     (should (equal (alist-get 'reason (car (last (emacsos-notifications--rows))))
                    "Synthetic after eviction")))))

(ert-deftest notifications-startup-error-is-visible-without-redisplay-work ()
  "Startup caches parse/projection failure without redisplay reads or messages."
  (dolist (corrupt '("synthetic invalid json\n" "42\n"))
    (notifications-test-journal
     (make-directory (file-name-directory emacsos-notifications-file) t)
     (write-region corrupt nil emacsos-notifications-file nil 'silent)
     (emacsos-notifications--initialize)
     (let ((reads 0) (messages 0))
       (cl-letf (((symbol-function 'insert-file-contents)
                  (lambda (&rest _) (cl-incf reads) (ert-fail "Redisplay attempted I/O")))
                 ((symbol-function 'message) (lambda (&rest _) (cl-incf messages))))
         (dotimes (_ 10)
           (should (string-match-p "Notifications unavailable"
                                   (emacsos-notifications-mode-line-string)))))
       (should (zerop reads))
       (should (zerop messages))))))

(ert-deftest notifications-live-corrupt-row-caches-failure-for-every-reader ()
  "Corruption discovered by open or record also reaches the visible error cache."
  (dolist (operation '(open record))
    (notifications-test-journal
     (emacsos-notifications-record 'system "Synthetic initial alert")
     (write-region "42\n" nil emacsos-notifications-file nil 'silent)
     (should-error
      (if (eq operation 'open)
          (save-window-excursion (emacsos-notifications-show))
        (emacsos-notifications-record 'system "Synthetic later alert")))
     (should (string-match-p "Notifications unavailable"
                             (emacsos-notifications-mode-line-string))))))
