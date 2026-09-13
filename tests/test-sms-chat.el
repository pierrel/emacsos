;;; test-sms-chat.el --- Tests for native SMS conversations -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'phone-sms-chat)

(defvar test-sms-chat--window-buffer nil)
(defvar emacsos--btn-gap 1)
(defvar emacsos--btn-label-scale 1)

(defmacro test-sms-chat--with-state (&rest body)
  "Run BODY with isolated SMS conversation and process state."
  (declare (indent 0))
  `(let ((emacsos-sms-chat--records nil)
         (emacsos-sms-chat--revision 0)
         (emacsos-sms-chat--next-context 0)
         (emacsos-sms-chat--contexts (make-hash-table :test #'eql))
         (emacsos-sms-chat--notice nil)
         (emacsos-sms-chat--refresh-state nil)
         (emacsos-sms-chat--jobs (make-hash-table :test #'equal))
         (emacsos-sms-chat--queue nil)
         (emacsos-sms-chat--running 0)
         (emacsos-sms-chat--next-job-token 0)
         (emacsos-sms-chat--next-refresh-id 0)
         (emacsos-sms-chat--refresh nil)
         (emacsos-sms-chat--last-recovery 0.0)
         (emacsos-call--current-owner ":1.mm")
         (emacsos-call--owner-generation 3)
         (emacsos-sms--state nil)
         (emacsos-sms--number nil)
         (emacsos-sms--body nil)
         (emacsos-sms--context nil)
         (emacsos-sms--detail nil)
         (emacsos-sms--proposal-id nil)
         (emacsos-sms--next-proposal-id 0)
         (emacsos-sms--confirm-id nil)
         (emacsos-sms--confirm-timer nil)
         (emacsos-sms--previous-buffer nil)
         (emacsos-sms-lifecycle-functions
          (list #'emacsos-sms-chat--on-lifecycle))
         (test-sms-chat--window-buffer (get-buffer-create "test-sms-home")))
     (cl-letf (((symbol-function 'emacsos--target) (lambda () 'window))
               ((symbol-function 'window-buffer)
                (lambda (&rest _) test-sms-chat--window-buffer))
               ((symbol-function 'set-window-buffer)
                (lambda (_window buffer &rest _)
                  (setq test-sms-chat--window-buffer buffer)))
               ((symbol-function 'emacsos--render-page) #'ignore)
               ((symbol-function 'force-mode-line-update) #'ignore)
               ((symbol-function 'emacsos-sms--rerender) #'ignore)
               ((symbol-function 'run-at-time)
                (lambda (&rest _) 'test-sms-chat-timer))
               ((symbol-function 'timerp)
                (lambda (timer) (eq timer 'test-sms-chat-timer)))
               ((symbol-function 'cancel-timer) #'ignore))
       (unwind-protect
           (progn ,@body)
         (dolist (buffer (buffer-list))
           (when (or (string-prefix-p "*SMS " (buffer-name buffer))
                     (member (buffer-name buffer)
                             '("*SMS*" "*SMS conversations*" "test-sms-home")))
             (kill-buffer buffer)))))))

(defun test-sms-chat--snapshot (&optional state pdu body path)
  "Return one real-shape mmcli fixture."
  (format (concat "sms.dbus-path             : %s\n"
                  "sms.content.number        : +14155550123\n"
                  "sms.content.text          : %s\n"
                  "sms.properties.pdu-type   : %s\n"
                  "sms.properties.state      : %s\n")
          (or path "/org/freedesktop/ModemManager1/SMS/7")
          (or body "hello\\nworld: yes")
          (or pdu "deliver")
          (or state "received")))

(ert-deftest emacsos-sms-chat-strict-utf8-rejects-noncanonical-bytes ()
  (dolist (codepoint '(#x0 #x7f #x80 #x7ff #x800 #xd7ff
                       #xe000 #xffff #x10000 #x10ffff))
    (let ((character (char-to-string codepoint)))
      (should (equal (emacsos-sms-chat--strict-utf8
                      (encode-coding-string character 'utf-8 t))
                     character))))
  (dolist (bytes (list (unibyte-string #xff)
                       (unibyte-string #xc0 #x80)
                       (unibyte-string #xed #xa0 #x80)
                       (unibyte-string #xf4 #x90 #x80 #x80)
                       (unibyte-string #xe2 #x82)))
    (should-error (emacsos-sms-chat--strict-utf8 bytes))))

(ert-deftest emacsos-sms-chat-parser-pins-aligned-mmcli-and-inert-body ()
  (let ((snapshot (emacsos-sms-chat--parse-snapshot
                   (test-sms-chat--snapshot))))
    (should (equal (plist-get snapshot :body) "hello\nworld: yes"))
    (should (eq (plist-get snapshot :direction) 'incoming))
    (should (eq (plist-get snapshot :state) 'received)))
  (should-not
   (emacsos-sms-chat--parse-snapshot
    (concat (test-sms-chat--snapshot)
            "sms.properties.state : sent\n")))
  (should-not
   (emacsos-sms-chat--parse-snapshot
    (test-sms-chat--snapshot
     nil nil (concat "hello" (string ?\\) "qworld"))))
  (should-not
   (emacsos-sms-chat--parse-snapshot
    (replace-regexp-in-string "[ \t]+:" ":" (test-sms-chat--snapshot))))
  (should-not
   (emacsos-sms-chat--parse-snapshot
    (replace-regexp-in-string
     "sms.content.number"
     "\nsms.content.number"
     (test-sms-chat--snapshot))))
  (should-not
   (emacsos-sms-chat--parse-snapshot
    (concat (test-sms-chat--snapshot)
            "sms.properties.storage : unknown\n"
            "sms.properties.storage : unknown\n")))
  (should-not
   (emacsos-sms-chat--parse-snapshot
    (concat (test-sms-chat--snapshot)
            "sms.properties.storage : invalid\\qescape\n"))))

(ert-deftest emacsos-sms-chat-list-parser-distinguishes-empty-and-invalid ()
  (should (equal (emacsos-sms-chat--parse-list
                  "modem.messaging.sms.length : 0\n")
                 '(parsed)))
  (should
   (equal (emacsos-sms-chat--parse-list
           (concat "modem.messaging.sms.length : 1\n"
                   "modem.messaging.sms.value[1] : "
                   "/org/freedesktop/ModemManager1/SMS/8\n"))
          '(parsed "/org/freedesktop/ModemManager1/SMS/8")))
  (should-not (emacsos-sms-chat--parse-list
               "modem.messaging.sms.length : 2\n"))
  (should-not
   (emacsos-sms-chat--parse-list
    (concat "modem.messaging.sms.length : 2\n"
            "modem.messaging.sms.value[1] : "
            "/org/freedesktop/ModemManager1/SMS/8\n"
            "modem.messaging.sms.value[2] : "
            "/org/freedesktop/ModemManager1/SMS/8\n")))
  (should-not
   (emacsos-sms-chat--parse-list
    (concat "modem.messaging.sms.length : 2\n"
            "modem.messaging.sms.value[1] : "
            "/org/freedesktop/ModemManager1/SMS/8\n"
            "modem.messaging.sms.value[3] : "
            "/org/freedesktop/ModemManager1/SMS/9\n"))))

(ert-deftest emacsos-sms-chat-render-keeps-exact-draft-and-hostile-body-inert ()
  (test-sms-chat--with-state
    (emacsos-sms-chat--admit
     (make-emacsos-sms-chat-record
      :id "one" :number "+14155550123"
      :body (concat "[tap](https://bad)" (string #x202e) "\\u{202E}")
      :direction 'incoming :state 'received :origin 'modem
      :owner ":1.mm" :generation 3 :path "/org/freedesktop/ModemManager1/SMS/1"
      :revision 1 :unread t))
    (let ((buffer (emacsos-sms-chat-open "+14155550123")))
      (should (buffer-live-p buffer))
      (with-current-buffer buffer
        (goto-char (point-max))
        (insert "  exact draft  ")
        (backward-char 3)
        (let ((offset (- (point) emacsos-sms-chat--draft-marker)))
          (emacsos-sms-chat--render)
          (should (equal (emacsos-sms-chat--draft) "  exact draft  "))
          (should (= (- (point) emacsos-sms-chat--draft-marker) offset)))
        (goto-char (point-min))
        (search-forward "https://bad")
        (should-not (get-text-property (point) 'emacsos-conversation-url))
        (should-not
         (text-property-not-all (point-min) emacsos-sms-chat--draft-marker
                                'read-only t))
        (should (string-match-p "\\\\u{202E}\\\\\\\\u{202E}"
                                (buffer-string)))))))

(ert-deftest emacsos-sms-chat-render-bound-counts-visible-control-escapes ()
  (test-sms-chat--with-state
    (dotimes (index 3)
      (emacsos-sms-chat--admit
       (make-emacsos-sms-chat-record
        :id index :number "+14155550123" :body (make-string 4096 ?\t)
        :direction 'incoming :state 'received :origin 'modem)))
    (let ((records (emacsos-sms-chat--render-records "+14155550123")))
      (should (= (length records) 1))
      (should (= (emacsos-sms-chat-record-id (car records)) 2)))))

(ert-deftest emacsos-sms-chat-conversation-renders-refresh-feedback ()
  (test-sms-chat--with-state
    (setq emacsos-sms-chat--refresh-state "Refresh partial; tap to retry")
    (let ((buffer (emacsos-sms-chat-open "+14155550123")))
      (with-current-buffer buffer
        (goto-char (point-min))
        (should (search-forward emacsos-sms-chat--refresh-state nil t))))))

(ert-deftest emacsos-sms-chat-lifecycle-clears-only-unchanged-draft ()
  (test-sms-chat--with-state
    (let (completion)
      (setq emacsos-sms-operation-function
            (lambda (_number _body done)
              (setq completion done)
              "pending: SMS requested"))
      (let ((buffer (emacsos-sms-chat-open "+14155550123")))
        (with-current-buffer buffer
          (goto-char (point-max))
          (insert "original")
          (emacsos-sms-chat-send))
        (with-current-buffer buffer
          (delete-region emacsos-sms-chat--draft-marker (point-max))
          (insert "edited"))
        (emacsos-sms--send-tap)
        (emacsos-sms--post-command-disarm)
        (emacsos-sms--send-tap)
        (should (eq test-sms-chat--window-buffer buffer))
        (with-current-buffer buffer
          (should (equal (emacsos-sms-chat--draft) "edited")))
        (let ((record (car emacsos-sms-chat--records)))
          (should (eq (emacsos-sms-chat-record-state record) 'sending))
          (funcall completion "sent")
          (should (eq (emacsos-sms-chat-record-state record) 'sent)))))))

(ert-deftest emacsos-sms-chat-send-reserves-before-staging-transport ()
  (test-sms-chat--with-state
    (let* ((emacsos-sms-chat--max-records 1)
           (calls 0)
           (protected
            (make-emacsos-sms-chat-record
             :id 1 :number "+14155550123" :body "unknown"
             :direction 'outgoing :state 'unknown :origin 'local)))
      (setq emacsos-sms-chat--records (list protected))
      (let ((buffer (emacsos-sms-chat-open "+14155550124")))
        (with-current-buffer buffer
          (goto-char (point-max))
          (insert "new")
          (cl-letf (((symbol-function 'emacsos-send-message)
                     (lambda (&rest _)
                       (setq calls (1+ calls))
                       "confirmation-required: confirm on phone")))
            (should (equal (emacsos-sms-chat-send)
                           "error: SMS storage full")))))
      (should (= calls 0))
      (should (equal emacsos-sms-chat--records (list protected)))
      (should (emacsos-sms-chat--protected-p protected)))))

(ert-deftest emacsos-sms-chat-staging-error-restores-evicted-history ()
  (test-sms-chat--with-state
    (let* ((emacsos-sms-chat--max-records 1)
           (old
            (make-emacsos-sms-chat-record
             :id 1 :number "+14155550123" :body "old"
             :direction 'incoming :state 'received :origin 'modem)))
      (setq emacsos-sms-chat--records (list old))
      (let ((buffer (emacsos-sms-chat-open "+14155550124")))
        (with-current-buffer buffer
          (goto-char (point-max))
          (insert "new")
          (cl-letf (((symbol-function 'emacsos-send-message)
                     (lambda (&rest _) "error: message send already in progress")))
            (should (string-prefix-p "error:" (emacsos-sms-chat-send))))))
      (should (equal emacsos-sms-chat--records (list old)))
      (should (= (hash-table-count emacsos-sms-chat--contexts) 0)))))

(ert-deftest emacsos-sms-chat-eviction-protects-unknown-and-active ()
  (test-sms-chat--with-state
    (let ((emacsos-sms-chat--max-records 2))
      (dolist (record
               (list
                (make-emacsos-sms-chat-record
                 :id 1 :number "+14155550123" :body "unknown"
                 :direction 'outgoing :state 'unknown :origin 'local)
                (make-emacsos-sms-chat-record
                 :id 2 :number "+14155550123" :body "old"
                 :direction 'incoming :state 'received :origin 'modem)
                (make-emacsos-sms-chat-record
                 :id 3 :number "+14155550123" :body "new"
                 :direction 'incoming :state 'received :origin 'modem)))
        (emacsos-sms-chat--admit record))
      (should (equal (mapcar #'emacsos-sms-chat-record-id
                             emacsos-sms-chat--records)
                     '(1 3)))
      (should (emacsos-sms-chat--protected-p
               (car emacsos-sms-chat--records))))))

(ert-deftest emacsos-sms-chat-failed-admission-does-not-evict-prior-records ()
  (test-sms-chat--with-state
    (let* ((emacsos-sms-chat--max-records 2)
           (old (make-emacsos-sms-chat-record
                 :id 1 :number "+14155550123" :body "old"
                 :direction 'incoming :state 'received :origin 'modem))
           (protected (make-emacsos-sms-chat-record
                       :id 2 :number "+14155550123" :body "unknown"
                       :direction 'outgoing :state 'unknown :origin 'local))
           (too-large (make-emacsos-sms-chat-record
                       :id 3 :number "+14155550123"
                       :body (make-string (1+ emacsos-sms-chat--max-body-bytes) ?x)
                       :direction 'incoming :state 'received :origin 'modem)))
      (setq emacsos-sms-chat--records (list old protected))
      (should-not (emacsos-sms-chat--admit too-large))
      (should (equal emacsos-sms-chat--records (list old protected))))))

(ert-deftest emacsos-sms-chat-live-read-uses-fixed-argv-and-sets-badge ()
  (test-sms-chat--with-state
    (let (commands)
      (cl-letf (((symbol-function 'emacsos-sms-chat--spawn)
                 (lambda (args _limit callback)
                   (push args commands)
                   (funcall callback 'ok (test-sms-chat--snapshot))
                   nil)))
        (emacsos-sms-chat--on-added
         ":1.mm" 3 "/org/freedesktop/ModemManager1/SMS/7")
        (should (equal commands
                       '(("-s" "/org/freedesktop/ModemManager1/SMS/7"
                          "--output-keyvalue"))))
        (should (emacsos-sms-chat--newest-unread))
        (should (string-match-p "SMS" (emacsos-sms-chat-mode-line-string)))
        (emacsos-sms-chat-show-unread)
        (should-not (emacsos-sms-chat--newest-unread))))))

(ert-deftest emacsos-sms-chat-refresh-is-single-flight-and-merges-history ()
  (test-sms-chat--with-state
    (let (commands)
      (cl-letf (((symbol-function 'emacsos-sms-chat--spawn)
                 (lambda (args _limit callback)
                   (push args commands)
                   (if (equal (car args) "-m")
                       (funcall callback 'ok
                                (concat "modem.messaging.sms.length : 1\n"
                                        "modem.messaging.sms.value[1] : "
                                        "/org/freedesktop/ModemManager1/SMS/7\n"))
                     (funcall callback 'ok (test-sms-chat--snapshot)))
                   nil)))
        (emacsos-sms-chat-refresh)
        (should-not emacsos-sms-chat--refresh)
        (should (= (length commands) 2))
        (should (equal emacsos-sms-chat--refresh-state "Messages refreshed"))
        (should (= (length emacsos-sms-chat--records) 1))
        (should-not (emacsos-sms-chat-record-unread
                     (car emacsos-sms-chat--records)))))))

(ert-deftest emacsos-sms-chat-refresh-attaches-sole-sent-local-record ()
  (test-sms-chat--with-state
    (let* ((path "/org/freedesktop/ModemManager1/SMS/7")
           (record
            (make-emacsos-sms-chat-record
             :id 1 :number "+14155550123" :body "same"
             :direction 'outgoing :state 'sent :origin 'local)))
      (setq emacsos-sms-chat--records (list record))
      (should
       (eq record
           (emacsos-sms-chat--apply-snapshot
            (emacsos-sms-chat--parse-snapshot
             (test-sms-chat--snapshot "sent" "submit" "same" path))
            ":1.mm" 3 nil)))
      (should (equal (emacsos-sms-chat-record-path record) path))
      (should (eq (emacsos-sms-chat-record-origin record) 'local))
      (should (= (length emacsos-sms-chat--records) 1)))))

(ert-deftest emacsos-sms-chat-refresh-preserves-modem-list-order ()
  (test-sms-chat--with-state
    (let* ((path-7 "/org/freedesktop/ModemManager1/SMS/7")
           (path-8 "/org/freedesktop/ModemManager1/SMS/8")
           (refresh (make-emacsos-sms-chat-refresh
                     :owner ":1.mm" :generation 3 :cutoff 0
                     :paths (list path-7 path-8) :pending 2 :done t)))
      (setq emacsos-sms-chat--refresh refresh)
      ;; Complete in the opposite order from the modem list.
      (emacsos-sms-chat--refresh-consume
       refresh (emacsos-sms-chat--parse-snapshot
                (test-sms-chat--snapshot "received" "deliver" "later" path-8))
       nil)
      (emacsos-sms-chat--refresh-consume
       refresh (emacsos-sms-chat--parse-snapshot
                (test-sms-chat--snapshot "received" "deliver" "earlier" path-7))
       nil)
      (should (equal (mapcar #'emacsos-sms-chat-record-path
                             emacsos-sms-chat--records)
                     (list path-7 path-8))))))

(ert-deftest emacsos-sms-chat-refresh-coalesces-while-list-is-running ()
  (test-sms-chat--with-state
    (let (callbacks)
      (cl-letf (((symbol-function 'emacsos-sms-chat--spawn)
                 (lambda (_args _limit callback)
                   (push callback callbacks)
                   'pending-process)))
        (emacsos-sms-chat-refresh)
        (let ((refresh emacsos-sms-chat--refresh))
          (emacsos-sms-chat-refresh)
          (should (eq refresh emacsos-sms-chat--refresh))
          (should (= (length callbacks) 1))
          (should (= emacsos-sms-chat--running 1))
          (should (= (hash-table-count emacsos-sms-chat--jobs) 1)))))))

(ert-deftest emacsos-sms-chat-scheduler-caps-running-children ()
  (test-sms-chat--with-state
    (cl-letf (((symbol-function 'emacsos-sms-chat--spawn)
               (lambda (&rest _) 'pending-process)))
      (dotimes (index 6)
        (emacsos-sms-chat--on-added
         ":1.mm" 3
         (format "/org/freedesktop/ModemManager1/SMS/%d" (1+ index))))
      (should (= emacsos-sms-chat--running 4))
      (should (= (length emacsos-sms-chat--queue) 2))
      (should (= (hash-table-count emacsos-sms-chat--jobs) 6)))))

(ert-deftest emacsos-sms-chat-receiving-snapshot-retries-with-a-bound ()
  (test-sms-chat--with-state
    (let (scheduled)
      (cl-letf (((symbol-function 'run-at-time)
                 (lambda (_delay _repeat function &rest args)
                   (setq scheduled (cons function args))
                   'retry-timer))
                ((symbol-function 'emacsos-sms-chat--scheduler-pump) #'ignore))
        (let ((job (make-emacsos-sms-chat-job
                    :key '(3 "/org/freedesktop/ModemManager1/SMS/7")
                    :kind 'snapshot :owner ":1.mm" :generation 3
                    :path "/org/freedesktop/ModemManager1/SMS/7"
                    :live t :attempts 0 :state 'complete)))
          (puthash (emacsos-sms-chat-job-key job) job emacsos-sms-chat--jobs)
          (emacsos-sms-chat--snapshot-finished
           job 'ok (test-sms-chat--snapshot "receiving"))
          (should (= (emacsos-sms-chat-job-attempts job) 1))
          (should (eq (emacsos-sms-chat-job-state job) 'waiting))
          (apply (car scheduled) (cdr scheduled))
          (should (eq (emacsos-sms-chat-job-state job) 'queued))
          (should (equal emacsos-sms-chat--queue (list job))))))))

(ert-deftest emacsos-sms-chat-live-receiving-exhaustion-requests-recovery ()
  (test-sms-chat--with-state
    (let ((recoveries 0)
          (job (make-emacsos-sms-chat-job
                :key '(3 "/org/freedesktop/ModemManager1/SMS/7")
                :kind 'snapshot :owner ":1.mm" :generation 3
                :path "/org/freedesktop/ModemManager1/SMS/7"
                :live t :attempts 5 :state 'complete)))
      (puthash (emacsos-sms-chat-job-key job) job emacsos-sms-chat--jobs)
      (cl-letf (((symbol-function 'emacsos-sms-chat--request-recovery-refresh)
                 (lambda () (setq recoveries (1+ recoveries)))))
        (emacsos-sms-chat--snapshot-finished
         job 'ok (test-sms-chat--snapshot "receiving"))
        (should (= recoveries 1))))))

(ert-deftest emacsos-sms-chat-full-queue-coalesces-pending-redraw ()
  (test-sms-chat--with-state
    (let ((renders 0))
      (cl-letf (((symbol-function 'emacsos-sms-chat--enqueue-snapshot)
                 (lambda (&rest _) nil))
                ((symbol-function 'emacsos-sms-chat--rerender-all)
                 (lambda () (setq renders (1+ renders)))))
        (dotimes (index 100)
          (emacsos-sms-chat--on-added
           ":1.mm" 3
           (format "/org/freedesktop/ModemManager1/SMS/%d" index)))
        (should (= renders 1))
        (should (equal emacsos-sms-chat--notice
                       "New SMS pending; tap Refresh"))))))

(ert-deftest emacsos-sms-chat-owner-change-cancels-work-and-protects-send ()
  (test-sms-chat--with-state
    (let (callbacks)
      (cl-letf (((symbol-function 'emacsos-sms-chat--spawn)
                 (lambda (_args _limit callback)
                   (push callback callbacks)
                   'pending-process))
                ((symbol-function 'process-live-p)
                 (lambda (process) (eq process 'pending-process)))
                ((symbol-function 'delete-process) #'ignore))
        (dotimes (index 5)
          (emacsos-sms-chat--on-added
           ":1.mm" 3
           (format "/org/freedesktop/ModemManager1/SMS/%d" (1+ index))))
        (emacsos-sms-chat--admit
         (make-emacsos-sms-chat-record
          :id 9 :number "+14155550123" :body "sent?"
          :direction 'outgoing :state 'sending :origin 'local
          :owner ":1.mm" :generation 3))
        (setq emacsos-call--current-owner ":1.new"
              emacsos-call--owner-generation 4)
        (emacsos-sms-chat--on-owner-changed ":1.mm" ":1.new" 4)
        (should-not emacsos-sms-chat--queue)
        (should (= (hash-table-count emacsos-sms-chat--jobs) 0))
        (let ((record (car emacsos-sms-chat--records)))
          (should (eq (emacsos-sms-chat-record-state record) 'unknown))
          (should (emacsos-sms-chat--protected-p record)))
        (dolist (callback callbacks)
          (funcall callback 'error ""))
        (should (= emacsos-sms-chat--running 0))))))

(ert-deftest emacsos-sms-chat-owner-change-wins-over-delayed-send-terminal ()
  (test-sms-chat--with-state
    (let ((record
           (make-emacsos-sms-chat-record
            :id 9 :number "+14155550123" :body "sent?"
            :direction 'outgoing :state 'sending :origin 'local
            :owner ":1.mm" :generation 3)))
      (emacsos-sms-chat--admit record)
      (setq emacsos-call--current-owner ":1.new"
            emacsos-call--owner-generation 4)
      (emacsos-sms-chat--on-owner-changed ":1.mm" ":1.new" 4)
      (emacsos-sms-chat--on-lifecycle
       '(:event terminal :proposal-id 9 :state sent :context 1))
      (should (eq (emacsos-sms-chat-record-state record) 'unknown))
      (should (emacsos-sms-chat--protected-p record)))))

(ert-deftest emacsos-sms-chat-refresh-deadline-detaches-and-allows-retry ()
  (test-sms-chat--with-state
    (let (deleted)
      (cl-letf (((symbol-function 'emacsos-sms-chat--spawn)
                 (lambda (&rest _) 'pending-process))
                ((symbol-function 'process-live-p)
                 (lambda (process) (eq process 'pending-process)))
                ((symbol-function 'delete-process)
                 (lambda (process) (push process deleted))))
      (emacsos-sms-chat-refresh)
      (let ((expired emacsos-sms-chat--refresh))
        (emacsos-sms-chat--refresh-deadline expired)
        (should-not emacsos-sms-chat--refresh)
        (should (equal deleted '(pending-process)))
        (maphash
         (lambda (_key job)
           (should-not (memq expired (emacsos-sms-chat-job-refreshes job))))
         emacsos-sms-chat--jobs)
        (emacsos-sms-chat-refresh)
        (should emacsos-sms-chat--refresh)
          (should-not (eq expired emacsos-sms-chat--refresh)))))))

(ert-deftest emacsos-sms-chat-partial-refresh-preserves-prior-history ()
  (test-sms-chat--with-state
    (let ((old (make-emacsos-sms-chat-record
                :id "old" :number "+14155550123" :body "prior"
                :direction 'incoming :state 'received :origin 'modem
                :owner ":1.mm" :generation 3 :path
                "/org/freedesktop/ModemManager1/SMS/1"
                :revision 1))
          (refresh (make-emacsos-sms-chat-refresh
                    :owner ":1.mm" :generation 3 :cutoff 1 :pending 0
                    :done t :failures t)))
      (setq emacsos-sms-chat--records (list old)
            emacsos-sms-chat--refresh refresh)
      (emacsos-sms-chat--refresh-commit refresh)
      (should (memq old emacsos-sms-chat--records)))))

(ert-deftest emacsos-sms-chat-complete-refresh-rolls-back-on-admission-failure ()
  (test-sms-chat--with-state
    (let* ((emacsos-sms-chat--max-records 1)
           (protected (make-emacsos-sms-chat-record
                       :id 1 :number "+14155550123" :body "unknown"
                       :direction 'outgoing :state 'unknown :origin 'local))
           (path "/org/freedesktop/ModemManager1/SMS/7")
           (refresh (make-emacsos-sms-chat-refresh
                     :owner ":1.mm" :generation 3 :cutoff 0 :paths (list path)
                     :pending 0 :done t
                     :results (list (emacsos-sms-chat--parse-snapshot
                                     (test-sms-chat--snapshot))))))
      (setq emacsos-sms-chat--records (list protected)
            emacsos-sms-chat--refresh refresh)
      (emacsos-sms-chat--refresh-commit refresh)
      (should (equal (mapcar #'emacsos-sms-chat-record-id
                             emacsos-sms-chat--records)
                     '(1)))
      (should (emacsos-sms-chat-refresh-failures refresh))
      (should (equal emacsos-sms-chat--notice
                     "SMS storage full; acknowledge pending status")))))

(ert-deftest emacsos-sms-chat-refresh-rollback-preserves-proposal-identity ()
  (test-sms-chat--with-state
    (let* ((emacsos-sms-chat--max-records 1)
           (proposal
            (make-emacsos-sms-chat-record
             :id 9 :number "+14155550123" :body "pending"
             :direction 'outgoing :state 'proposed :origin 'local))
           (refresh
            (make-emacsos-sms-chat-refresh
             :owner ":1.mm" :generation 3 :cutoff 0
             :paths '("/org/freedesktop/ModemManager1/SMS/7")
             :pending 0 :done t
             :results (list (emacsos-sms-chat--parse-snapshot
                             (test-sms-chat--snapshot))))))
      (setq emacsos-sms-chat--records (list proposal)
            emacsos-sms-chat--refresh refresh)
      (puthash 1 (list :record proposal) emacsos-sms-chat--contexts)
      (emacsos-sms-chat--refresh-commit refresh)
      (should (eq (car emacsos-sms-chat--records) proposal))
      (emacsos-sms-chat--on-lifecycle
       '(:event discarded :proposal-id 9 :context 1))
      (should-not emacsos-sms-chat--records))))

(ert-deftest emacsos-sms-chat-partial-refresh-updates-old-modem-state ()
  (test-sms-chat--with-state
    (let* ((path "/org/freedesktop/ModemManager1/SMS/7")
           (record
            (make-emacsos-sms-chat-record
             :id path :number "+14155550123" :body "same"
             :direction 'outgoing :state 'sending :origin 'modem
             :owner ":1.mm" :generation 3 :path path :revision 1))
           (refresh
            (make-emacsos-sms-chat-refresh
             :owner ":1.mm" :generation 3 :cutoff 1 :paths (list path)
             :pending 0 :done t :failures t
             :results (list (emacsos-sms-chat--parse-snapshot
                             (test-sms-chat--snapshot
                              "sent" "submit" "same" path))))))
      (setq emacsos-sms-chat--records (list record)
            emacsos-sms-chat--revision 1
            emacsos-sms-chat--refresh refresh)
      (emacsos-sms-chat--refresh-commit refresh)
      (should (eq (car emacsos-sms-chat--records) record))
      (should (eq (emacsos-sms-chat-record-state record) 'sent)))))

(ert-deftest emacsos-sms-chat-unavailable-ui-does-not-create-buffers ()
  (test-sms-chat--with-state
    (cl-letf (((symbol-function 'emacsos--target) (lambda () nil)))
      (emacsos-sms-chat-open "+14155550123")
      (should-not (get-buffer "*SMS +14155550123*"))
      (emacsos-sms-chat-catalog)
      (should-not (get-buffer "*SMS conversations*")))))

(ert-deftest emacsos-sms-chat-catalog-button-opens-its-conversation ()
  (test-sms-chat--with-state
    (emacsos-sms-chat--admit
     (make-emacsos-sms-chat-record
      :id 1 :number "+14155550123" :body "hello"
      :direction 'incoming :state 'received :origin 'modem))
    (let ((catalog (emacsos-sms-chat-catalog)))
      (with-current-buffer catalog
        (goto-char (point-min))
        (search-forward "+14155550123")
        (button-activate (button-at (1- (point)))))
      (should (equal (buffer-name test-sms-chat--window-buffer)
                     "*SMS +14155550123*")))))

(ert-deftest emacsos-sms-chat-utility-rows-are-target-aware-and-touchable ()
  (test-sms-chat--with-state
    (let ((conversation (emacsos-sms-chat-open "+14155550123"))
          (emacsos--btn-gap 1)
          (emacsos--btn-label-scale 1))
      (cl-letf (((symbol-function 'emacsos--center)
                 (lambda (label _width) label))
                ((symbol-function 'emacsos--btn)
                 (lambda (label &rest _) (insert label)))
                ((symbol-function 'emacsos--unit-width)
                 (lambda (width gap units gaps)
                   (max 1 (/ (- width (* gaps gap)) units)))))
        (emacsos-sms-chat--admit
         (make-emacsos-sms-chat-record
          :id 1 :number "+14155550123" :body "maybe"
          :direction 'outgoing :state 'unknown :origin 'local))
        (setq test-sms-chat--window-buffer conversation)
        (with-temp-buffer
          (emacsos-sms-chat--utility-row)
          (let ((text (buffer-string)))
            (should (string-match-p "QUIT" text))
            (should (string-match-p "Refresh" text))
            (should (string-match-p "ACK" text))
            (should-not (string-match-p "Send" text))))
        (with-temp-buffer
          (emacsos-sms-chat--catalog-utility-row)
          (let ((text (buffer-string)))
            (should (string-match-p "QUIT" text))
            (should (string-match-p "Refresh" text))
            (should (string-match-p "New" text))))))))

(ert-deftest emacsos-sms-chat-state-redraw-refreshes-ack-utility-action ()
  (test-sms-chat--with-state
    (let* ((conversation (emacsos-sms-chat-open "+14155550123"))
           (record
            (make-emacsos-sms-chat-record
             :id 1 :number "+14155550123" :body "maybe"
             :direction 'outgoing :state 'unknown :origin 'local))
           rows)
      (setq emacsos-sms-chat--records (list record)
            test-sms-chat--window-buffer conversation)
      (cl-letf (((symbol-function 'emacsos--center)
                 (lambda (label _width) label))
                ((symbol-function 'emacsos--btn)
                 (lambda (label &rest _) (insert label)))
                ((symbol-function 'emacsos--unit-width)
                 (lambda (&rest _) 5))
                ((symbol-function 'emacsos--render-page)
                 (lambda ()
                   (with-temp-buffer
                     (emacsos-sms-chat--utility-row)
                     (push (buffer-string) rows)))))
        (emacsos-sms-chat--rerender-all)
        (with-current-buffer conversation
          (emacsos-sms-chat-acknowledge))
        (setq rows (nreverse rows))
        (should (string-match-p "ACK" (car rows)))
        (should (string-match-p "Send" (cadr rows)))))))

(provide 'test-sms-chat)
;;; test-sms-chat.el ends here
