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
         (emacsos-sms-chat--refresh nil)
         (emacsos-sms-chat--refresh-again nil)
         (emacsos-call--current-owner ":1.mm")
         (emacsos-call--owner-generation 3)
         (emacsos-sms--state nil)
         (emacsos-sms--number nil)
         (emacsos-sms--body nil)
         (emacsos-sms--context nil)
         (emacsos-sms--detail nil)
         (emacsos-sms--proposal-id nil)
         (emacsos-sms--attempt-id nil)
         (emacsos-sms-chat--history-loaded nil)
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





(ert-deftest emacsos-sms-chat-unavailable-ui-does-not-create-buffers ()
  (test-sms-chat--with-state
    (cl-letf (((symbol-function 'emacsos--target) (lambda () nil)))
      (emacsos-sms-chat-open "+14155550123")
      (should-not (get-buffer "*SMS conversation: +14155550123*"))
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
                     "*SMS conversation: +14155550123*")))))

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

(ert-deftest emacsos-sms-chat-direct-send-cannot-open-a-synthetic-object ()
  (test-sms-chat--with-state
    (let ((buffer (emacsos-sms-chat-open "+14155550123")) sent browsed)
      (with-current-buffer buffer
        (goto-char (point-min))
        (let ((inhibit-read-only t))
          (put-text-property (point-min) (min (point-max) (1+ (point-min)))
                             'emacsos-conversation-url "https://example.test"))
        (cl-letf (((symbol-function 'emacsos-sms-chat-send)
                   (lambda () (interactive) (setq sent (current-buffer))))
                  ((symbol-function 'browse-url)
                   (lambda (&rest _) (setq browsed t))))
          (call-interactively (key-binding (kbd "C-<return>")))
          (call-interactively (key-binding (kbd "C-c C-o")))))
      (should (eq sent buffer))
      (should-not browsed)
      (with-current-buffer buffer
        (should-not (alist-get 'open-object emacsos-conversation-actions))))))

(provide 'test-sms-chat)
;;; test-sms-chat.el ends here

(defun test-sms-chat--history-row (id direction status &optional number body)
  "Return a synthetic archive row."
  `((id . ,id) (direction . ,direction) (status . ,status)
    (number . ,(or number "+14155550123")) (text . ,(or body "same"))
    (occurred_at . "2026-01-01T00:00:00+00:00")))

(ert-deftest emacsos-sms-chat-archive-empty-is-distinct-from-invalid ()
  (test-sms-chat--with-state
    (let ((old (make-emacsos-sms-chat-record :id "old" :origin 'archive :state 'received)))
      (setq emacsos-sms-chat--records (list old))
      (should-error (emacsos-sms-chat--apply-history nil))
      (should (eq old (car emacsos-sms-chat--records)))
      (emacsos-sms-chat--apply-history '((messages) (truncated)))
      (should-not emacsos-sms-chat--records))))

(ert-deftest emacsos-sms-chat-archive-validates-whole-batch-before-mutation ()
  (test-sms-chat--with-state
    (let ((old (make-emacsos-sms-chat-record :id "one" :origin 'local :state 'sent)))
      (setq emacsos-sms-chat--records (list old))
      (should-error (emacsos-sms-chat--apply-history
                     `((messages . (,(test-sms-chat--history-row "one" "outgoing" "unknown")
                                    ((id . "invalid")))) (truncated))))
      (should (eq (emacsos-sms-chat-record-state old) 'sent)))))

(ert-deftest emacsos-sms-chat-archive-does-not-terminalize-owned-send ()
  (test-sms-chat--with-state
    (setq emacsos-sms--state 'sending emacsos-sms--attempt-id "exact")
    (emacsos-sms-chat--apply-history
     `((messages . (,(test-sms-chat--history-row "exact" "outgoing" "unknown"))) (truncated)))
    (let ((record (car emacsos-sms-chat--records)))
      (should (eq (emacsos-sms-chat-record-state record) 'sending))
      (emacsos-sms-chat--on-lifecycle '(:event terminal :proposal-id "ui" :message-id "exact" :state sent))
      (should (eq (emacsos-sms-chat-record-state record) 'sent)))))

(ert-deftest emacsos-sms-chat-archive-identical-sends-use-distinct-identities ()
  (test-sms-chat--with-state
    (emacsos-sms-chat--apply-history
     `((messages . (,(test-sms-chat--history-row "first" "outgoing" "sent")
                    ,(test-sms-chat--history-row "second" "outgoing" "sent"))) (truncated)))
    (should (equal (mapcar #'emacsos-sms-chat-record-id emacsos-sms-chat--records)
                   '("first" "second")))))

(ert-deftest emacsos-sms-chat-archive-failed-send-has-explicit-status ()
  (test-sms-chat--with-state
    (emacsos-sms-chat--apply-history
     `((messages . (,(test-sms-chat--history-row "failed" "outgoing" "not_sent"))) (truncated)))
    (should (equal (emacsos-sms-chat--status-suffix (car emacsos-sms-chat--records)) " [not sent]"))))

(ert-deftest emacsos-sms-chat-archive-rollback-retains-object-and-all-fields ()
  (test-sms-chat--with-state
    (let* ((old (make-emacsos-sms-chat-record :id "one" :origin 'local :state 'sent :unread t :acknowledged t))
           (saved (copy-emacsos-sms-chat-record old)))
      (setq emacsos-sms-chat--records (list old))
      (cl-letf (((symbol-function 'emacsos-sms-chat--trim) (lambda () nil)))
        (emacsos-sms-chat--apply-history
         `((messages . (,(test-sms-chat--history-row "one" "outgoing" "unknown"))) (truncated))))
      (should (eq (car emacsos-sms-chat--records) old))
      (should (equal old saved))
      (should-not emacsos-sms-chat--history-loaded))))

(ert-deftest emacsos-sms-chat-archive-preserves-unread-and-user-ack ()
  (test-sms-chat--with-state
    (let ((old (make-emacsos-sms-chat-record :id "one" :number "+14155550123" :body "same" :direction 'outgoing :origin 'local :state 'unknown :unread t :acknowledged t)))
      (setq emacsos-sms-chat--records (list old))
      (emacsos-sms-chat--apply-history
       `((messages . (,(test-sms-chat--history-row "one" "outgoing" "unknown"))) (truncated)))
      (should (emacsos-sms-chat-record-unread old))
      (should (emacsos-sms-chat-record-acknowledged old)))))

(ert-deftest emacsos-sms-chat-archive-alphanumeric-sender-is-view-only ()
  (test-sms-chat--with-state
    (emacsos-sms-chat--apply-history
     `((messages . (,(test-sms-chat--history-row "service" "incoming" "received" "Service" "notice"))) (truncated)))
    (should (emacsos-sms-chat-open "Service"))
    (should (string-match-p "notice" (with-current-buffer test-sms-chat--window-buffer (buffer-string))))
    (with-current-buffer test-sms-chat--window-buffer
      (goto-char (point-max)) (insert "reply")
      (emacsos-sms-chat-send))
    (should-not emacsos-sms--state)))

(ert-deftest emacsos-sms-chat-archive-correspondent-controls-are-inert ()
  (test-sms-chat--with-state
    (emacsos-sms-chat--apply-history
     `((messages . (,(test-sms-chat--history-row "service" "incoming" "received" "Service\n[Send]"))) (truncated)))
    (should (emacsos-sms-chat-open "Service\n[Send]"))
    (let ((text (with-current-buffer test-sms-chat--window-buffer (buffer-string))))
      (should (string-match-p (regexp-quote "Service\\u{000A}") text))
      (should-not (string-match-p "Service\n\\[Send\\]" text)))))

(ert-deftest emacsos-sms-chat-archive-bidi-correspondent-is-escaped ()
  (test-sms-chat--with-state
    (let ((sender (concat "Service" (string #x202e #x2066))))
      (emacsos-sms-chat--apply-history
       `((messages . (,(test-sms-chat--history-row "bidi" "incoming" "received" sender))) (truncated)))
      (emacsos-sms-chat-open sender)
      (let ((text (with-current-buffer test-sms-chat--window-buffer (buffer-string))))
        (should (string-match-p (regexp-quote "\\u{202E}\\u{2066}") text))
        (should-not (string-match-p (string #x202e) text))))))

(ert-deftest emacsos-sms-chat-archive-new-unread-is-not-reasserted-after-read ()
  (test-sms-chat--with-state
    (emacsos-sms-chat--apply-history '((messages) (truncated)))
    (let ((value `((messages . (,(test-sms-chat--history-row "new" "incoming" "received"))) (truncated))))
      (emacsos-sms-chat--apply-history value)
      (should (emacsos-sms-chat-record-unread (car emacsos-sms-chat--records)))
      (emacsos-sms-chat-open "+14155550123")
      (emacsos-sms-chat--apply-history value)
      (should-not (emacsos-sms-chat-record-unread (car emacsos-sms-chat--records))))))

(ert-deftest emacsos-sms-chat-delayed-archive-does-not-regress-terminal-result ()
  (test-sms-chat--with-state
    (dolist (terminal '(sent failed))
      (let ((record (make-emacsos-sms-chat-record
                     :id "exact" :number "+14155550123" :body "same"
                     :origin 'local :direction 'outgoing :state 'sending))
            (old-snapshot `((messages . (,(test-sms-chat--history-row "exact" "outgoing" "unknown"))) (truncated))))
        (setq emacsos-sms-chat--records (list record)
              emacsos-sms--state terminal)
        (emacsos-sms-chat--on-lifecycle
         (list :event 'terminal :message-id "exact" :proposal-id "ui" :state terminal))
        (emacsos-sms-chat--apply-history old-snapshot)
        (should (eq (emacsos-sms-chat-record-state record) terminal))))))

(ert-deftest emacsos-sms-chat-archive-reader-is-fixed-single-flight-and-stale-safe ()
  (test-sms-chat--with-state
    (let ((emacsos-call--current-owner nil) processes buffers arguments requests
          (real-status (symbol-function 'process-status)) first)
      (unwind-protect
          (cl-letf (((symbol-function 'make-process)
                     (lambda (&rest args)
                       (push args arguments)
                       (push (plist-get args :buffer) buffers)
                       (let ((p (make-pipe-process :name "test-archive-reader"
                                                  :buffer (plist-get args :buffer) :noquery t)))
                         (push p processes) p)))
                    ((symbol-function 'process-send-string)
                     (lambda (_ text) (push text requests)))
                    ((symbol-function 'process-send-eof) #'ignore))
            (emacsos-sms-chat-refresh)
            (setq first emacsos-sms-chat--refresh)
            (emacsos-sms-chat-refresh)
            (should (= (length processes) 1))
            (should (equal (plist-get (car arguments) :command)
                           '("/usr/bin/doas" "-n" "/usr/local/sbin/emacsos-openrc-sms")))
            (should (equal requests '("{\"operation\":\"history\"}")))
            (with-current-buffer (process-buffer first)
              (insert "{\"messages\":[],\"truncated\":false}"))
            (cl-letf (((symbol-function 'process-status)
                       (lambda (p) (if (eq p first) 'exit (funcall real-status p))))
                      ((symbol-function 'process-exit-status) (lambda (_) 0)))
              (emacsos-sms-chat--history-finished first "finished"))
            ;; A capture request during the first read is serviced once after it.
            (should (= (length processes) 2))
            (should-not (eq first emacsos-sms-chat--refresh))
            (let ((current emacsos-sms-chat--refresh))
              (emacsos-sms-chat--history-finished first "duplicate completion")
              (should (eq current emacsos-sms-chat--refresh))))
        (setq emacsos-sms-chat--refresh nil emacsos-sms-chat--refresh-again nil)
        (dolist (p processes) (set-process-sentinel p #'ignore) (delete-process p))
        (dolist (b buffers) (when (buffer-live-p b) (kill-buffer b)))))))

(ert-deftest emacsos-sms-chat-archive-read-failure-keeps-history-and-allows-retry ()
  (test-sms-chat--with-state
    (let* ((old (make-emacsos-sms-chat-record :id "old" :number "+14155550123"
                                             :body "saved" :origin 'archive :state 'received))
           (buffer (generate-new-buffer " *archive failure*"))
           (process (make-pipe-process :name "test-archive-failure" :buffer buffer :noquery t)))
      (unwind-protect
          (progn
            (setq emacsos-sms-chat--records (list old) emacsos-sms-chat--refresh process)
            (cl-letf (((symbol-function 'process-status) (lambda (_) 'exit))
                      ((symbol-function 'process-exit-status) (lambda (_) 1)))
              (emacsos-sms-chat--history-finished process "failed"))
            (should-not emacsos-sms-chat--refresh)
            (should (eq old (car emacsos-sms-chat--records)))
            (should (equal emacsos-sms-chat--refresh-state "Local history unavailable; tap Refresh")))
        (set-process-sentinel process #'ignore) (delete-process process)
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(ert-deftest emacsos-sms-chat-empty-correspondent-remains-viewable ()
  (test-sms-chat--with-state
    (emacsos-sms-chat--apply-history
     `((messages . (,(test-sms-chat--history-row "empty" "incoming" "received" "" "notice"))) (truncated)))
    (emacsos-sms-chat-catalog)
    (should (string-match-p "no sender" (with-current-buffer test-sms-chat--window-buffer (buffer-string))))
    (should (emacsos-sms-chat-open ""))
    (should (string-match-p "notice" (with-current-buffer test-sms-chat--window-buffer (buffer-string))))))

(ert-deftest emacsos-sms-chat-direct-terminal-precedes-first-history ()
  (test-sms-chat--with-state
    (dolist (terminal '(sent failed))
      (setq emacsos-sms-chat--records nil
            emacsos-sms--attempt-id "direct"
            emacsos-sms--state terminal)
      (emacsos-sms-chat--apply-history
       `((messages . (,(test-sms-chat--history-row "direct" "outgoing" "unknown"))) (truncated)))
      (should (eq (emacsos-sms-chat-record-state (car emacsos-sms-chat--records)) terminal)))))

(ert-deftest emacsos-sms-chat-historical-unknown-resolves-without-ui-callback ()
  (test-sms-chat--with-state
    (emacsos-sms-chat--apply-history
     `((messages . (,(test-sms-chat--history-row "external" "outgoing" "unknown"))) (truncated)))
    (let ((record (car emacsos-sms-chat--records)))
      (emacsos-sms-chat--apply-history
       `((messages . (,(test-sms-chat--history-row "external" "outgoing" "sent"))) (truncated)))
      (should (eq (emacsos-sms-chat-record-state record) 'sent))
      ;; A real UI-owned Unknown still requires explicit acknowledgment.
      (setq emacsos-sms--attempt-id "external" emacsos-sms--state 'unknown)
      (setf (emacsos-sms-chat-record-state record) 'unknown)
      (emacsos-sms-chat--apply-history
       `((messages . (,(test-sms-chat--history-row "external" "outgoing" "sent"))) (truncated)))
      (should (eq (emacsos-sms-chat-record-state record) 'unknown)))))

(ert-deftest emacsos-sms-chat-correspondent-cannot-alias-catalog-draft ()
  (test-sms-chat--with-state
    (let* ((catalog (emacsos-sms-chat-catalog))
           (conversation (emacsos-sms-chat-open "conversations")))
      (should-not (eq catalog conversation))
      (with-current-buffer conversation
        (goto-char (point-max)) (insert "editable fixture")
        (emacsos-sms-chat--rerender-all)
        (should (derived-mode-p 'emacsos-sms-chat-mode))
        (should (equal (emacsos-sms-chat--draft) "editable fixture")))
      (with-current-buffer catalog
        (should (derived-mode-p 'emacsos-sms-chat-catalog-mode))))))

(ert-deftest emacsos-sms-chat-old-empty-reader-keeps-new-terminal-result ()
  (test-sms-chat--with-state
    (dolist (terminal '(sent failed))
      (let ((real-status (symbol-function 'process-status)) process buffer)
        (unwind-protect
            (cl-letf (((symbol-function 'make-process)
                       (lambda (&rest args)
                         (setq buffer (plist-get args :buffer)
                               process (make-pipe-process :name "old-history" :buffer buffer :noquery t))))
                      ((symbol-function 'process-send-string) #'ignore)
                      ((symbol-function 'process-send-eof) #'ignore))
              (setq emacsos-sms-chat--records nil)
              (emacsos-sms-chat-refresh)
              (let ((record (make-emacsos-sms-chat-record
                             :id "new-attempt" :number "+14155550123" :body "new fixture"
                             :direction 'outgoing :origin 'local :state 'sending
                             :revision (emacsos-sms-chat--next-revision))))
                (setq emacsos-sms-chat--records (list record))
                (emacsos-sms-chat--on-lifecycle
                 (list :event 'terminal :message-id "new-attempt" :state terminal))
                (with-current-buffer buffer (insert "{\"messages\":[],\"truncated\":false}"))
                (cl-letf (((symbol-function 'process-status)
                           (lambda (p) (if (eq p process) 'exit (funcall real-status p))))
                          ((symbol-function 'process-exit-status) (lambda (_) 0)))
                  (emacsos-sms-chat--history-finished process "finished"))
                (should (eq (car emacsos-sms-chat--records) record))
                (should (eq (emacsos-sms-chat-record-state record) terminal))
                ;; A fresh bounded page remains authoritative after this cutoff.
                (emacsos-sms-chat--apply-history '((messages) (truncated))
                                                 emacsos-sms-chat--revision)
                (should-not emacsos-sms-chat--records)))
          (setq emacsos-sms-chat--refresh nil)
          (when process (set-process-sentinel process #'ignore) (delete-process process))
          (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(defun test-sms-chat--recordless-terminal-after-action (action &optional full)
  "Check ACTION and optional FULL model cannot lose a direct terminal result."
  (test-sms-chat--with-state
    (dolist (terminal '(sent failed))
      (let ((emacsos-sms-operation-function
             (lambda (_number _body completion)
               (funcall completion (if (eq terminal 'sent) "sent" "not-sent:busy"))
               "pending: synthetic"))
            (real-status (symbol-function 'process-status)) processes buffers)
        (setq emacsos-sms-chat--records nil emacsos-sms--state nil)
        (when full
          (dotimes (index 100)
            (push (make-emacsos-sms-chat-record :id (format "old%d" index)
                   :number "+14155550123" :body "prior unknown" :direction 'outgoing
                   :origin 'local :state 'unknown) emacsos-sms-chat--records)))
        (unwind-protect
            (cl-letf (((symbol-function 'emacsos-sms--show) (lambda () t))
                      ((symbol-function 'emacsos-sms--visible-p) (lambda () t))
                      ((symbol-function 'make-process)
                       (lambda (&rest args)
                         (let ((buffer (plist-get args :buffer)))
                           (push buffer buffers)
                           (push (make-pipe-process :name "recordless-reader" :buffer buffer
                                                    :noquery t) processes)
                           (car processes))))
                      ((symbol-function 'process-send-string) #'ignore)
                      ((symbol-function 'process-send-eof) #'ignore))
              (emacsos-sms-chat-refresh)
              (let ((old-reader emacsos-sms-chat--refresh))
                (emacsos-send-message "+14155550123" "terminal fixture")
                (let ((identity emacsos-sms--attempt-id))
                  (emacsos-sms--start-send)
                  (should (eq emacsos-sms--state terminal))
                  (if (eq action 'done)
                      (emacsos-sms--dismiss)
                    (emacsos-send-message "+14155550123" "next editable fixture"))
                  (when full
                    (let ((emacsos-sms-chat--number "+14155550123"))
                      (emacsos-sms-chat-acknowledge)))
                  (with-current-buffer (process-buffer old-reader)
                    (insert (json-encode
                             `((messages . [,(test-sms-chat--history-row
                                               identity "outgoing" "unknown"
                                               "+14155550123" "terminal fixture")]) (truncated)))))
                  (cl-letf (((symbol-function 'process-status)
                             (lambda (p) (if (eq p old-reader) 'exit (funcall real-status p))))
                            ((symbol-function 'process-exit-status) (lambda (_) 0)))
                    (emacsos-sms-chat--history-finished old-reader "finished"))
                  (should-not (emacsos-sms-chat--find-id identity))
                  (should (= (length processes) 2))
                  (let ((fresh emacsos-sms-chat--refresh))
                    (with-current-buffer (process-buffer fresh)
                      (insert (json-encode
                               `((messages . [,(test-sms-chat--history-row
                                                 identity "outgoing" (if (eq terminal 'sent) "sent" "not_sent")
                                                 "+14155550123" "terminal fixture")]) (truncated)))))
                    (cl-letf (((symbol-function 'process-status)
                               (lambda (p) (if (eq p fresh) 'exit (funcall real-status p))))
                              ((symbol-function 'process-exit-status) (lambda (_) 0)))
                      (emacsos-sms-chat--history-finished fresh "finished")))
                  (should (eq (emacsos-sms-chat-record-state
                               (emacsos-sms-chat--find-id identity)) terminal))
                  (should (<= (length emacsos-sms-chat--records) 100)))))
          (setq emacsos-sms-chat--refresh nil emacsos-sms-chat--refresh-again nil)
          (dolist (p processes) (set-process-sentinel p #'ignore) (delete-process p))
          (dolist (b buffers) (when (buffer-live-p b) (kill-buffer b))))))))

(ert-deftest emacsos-sms-chat-done-keeps-recordless-terminal-before-old-history ()
  (test-sms-chat--recordless-terminal-after-action 'done))

(ert-deftest emacsos-sms-chat-restaging-keeps-recordless-terminal-before-old-history ()
  (test-sms-chat--recordless-terminal-after-action 'restage))

(ert-deftest emacsos-sms-chat-full-model-recordless-terminal-does-not-regress ()
  (test-sms-chat--recordless-terminal-after-action 'done t))
