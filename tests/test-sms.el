;;; test-sms.el --- Tests for confirmed outbound SMS -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'phone-sms)
(defvar emacos--btn-label-scale 0.8)
(defvar test-sms--window-buffer nil)

(defmacro test-sms--with-ui (&rest body)
  "Run BODY with one fake phone target and isolated global SMS state."
  (declare (indent 0))
  `(let ((test-sms--window-buffer (get-buffer-create "test-sms-home"))
         (emacos-sms--state nil)
         (emacos-sms--number nil)
         (emacos-sms--body nil)
         (emacos-sms--detail nil)
         (emacos-sms--previous-buffer nil)
         (emacos-sms--next-proposal-id 0)
         (emacos-sms--proposal-id nil)
         (emacos-sms--confirm-id nil)
         (emacos-sms--confirm-timer nil)
         (emacos-sms--skip-next-post-command-disarm nil)
         (emacos-sms-operation-function nil))
     (cl-letf (((symbol-function 'emacos--target) (lambda () 'window))
               ((symbol-function 'window-buffer)
                (lambda (&rest _) test-sms--window-buffer))
               ((symbol-function 'set-window-buffer)
                (lambda (_window buffer &rest _)
                  (setq test-sms--window-buffer buffer)))
               ((symbol-function 'emacos-sms--rerender) #'ignore)
               ((symbol-function 'run-at-time)
                (lambda (&rest _) 'test-sms-timer))
               ((symbol-function 'timerp)
                (lambda (value) (eq value 'test-sms-timer)))
               ((symbol-function 'cancel-timer) #'ignore))
       (unwind-protect
           (progn ,@body)
         (dolist (name '("test-sms-home" "*SMS*"))
           (when (get-buffer name) (kill-buffer name)))))))

(ert-deftest emacos-sms-stages-exact-message-without-sending ()
  (test-sms--with-ui
    (let ((emacos-sms-operation-function
           (lambda (&rest _) (error "must not send while staging"))))
      (should (equal (emacos-send-message "+14155550123" "Hi “Ana” 👋")
                     "confirmation-required: confirm on phone"))
      (should (eq emacos-sms--state 'proposed))
      (should (equal emacos-sms--number "+14155550123"))
      (should (equal emacos-sms--body "Hi “Ana” 👋"))
      (with-current-buffer "*SMS*"
        (should (string-match-p "Hi “Ana” 👋" (buffer-string)))))))

(ert-deftest emacos-sms-rejects-invalid-input ()
  (test-sms--with-ui
    (should (string-prefix-p "error:" (emacos-send-message "Ana" "hi")))
    (should (string-prefix-p "error:" (emacos-send-message "+14155550123" "")))
    (should (string-prefix-p
             "error:"
             (emacos-send-message "+14155550123"
                                  (make-string 4097 ?a))))
    (should-not emacos-sms--state)))

(ert-deftest emacos-sms-interactive-validation-error-is-visible ()
  (test-sms--with-ui
    (let ((answers '("Ana" "hi")) shown)
      (cl-letf (((symbol-function 'read-string)
                 (lambda (&rest _) (pop answers)))
                ((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (setq shown (apply #'format format-string args)))))
        (should (equal (call-interactively #'emacos-send-message)
                       "error: invalid number"))
        (should (equal shown "error: invalid number"))))))

(ert-deftest emacos-sms-preview-exposes-control-characters ()
  (test-sms--with-ui
    (emacos-send-message
     "+14155550123"
     (concat "left\tline\n" (string #x202e #x200c) "right"))
    (with-current-buffer "*SMS*"
      (let ((text (buffer-string)))
        (should (string-match-p
                 (regexp-quote "left\\u{0009}line\\u{000A}\\u{202E}\\u{200C}right")
                 text))
        (should-not
         (string-match-p "[\t\n]"
                         (substring text (string-match "left" text))))))))

(ert-deftest emacos-sms-preview-cannot-collide-with-literal-escape-text ()
  (should-not
   (equal (emacos-sms--preview-body "\\u{202E}")
          (emacos-sms--preview-body (string #x202e))))
  (should (equal (emacos-sms--preview-body "\\u{202E}")
                 "\\\\u{202E}"))
  (should (equal (emacos-sms--preview-body (string #x202e))
                 "\\u{202E}")))

(ert-deftest emacos-sms-two-taps-send-once ()
  (test-sms--with-ui
    (let (requests completion)
      (setq emacos-sms-operation-function
            (lambda (number body done)
              (push (list number body) requests)
              (setq completion done)
              "pending: SMS requested"))
      (emacos-send-message "+14155550123" "exact text")
      (emacos-sms--send-tap)
      (should-not requests)
      (emacos-sms--post-command-disarm)
      (emacos-sms--send-tap)
      (should (equal requests '(("+14155550123" "exact text"))))
      (should (eq emacos-sms--state 'sending))
      (funcall completion "sent")
      (should (eq emacos-sms--state 'sent))
      (with-current-buffer "*SMS*"
        (should (string-match-p "Modem accepted" (buffer-string)))))))

(ert-deftest emacos-sms-unrelated-command-disarms ()
  (test-sms--with-ui
    (emacos-send-message "+14155550123" "hi")
    (emacos-sms--send-tap)
    (emacos-sms--post-command-disarm) ; skip the arming command itself
    (emacos-sms--post-command-disarm) ; next command disarms
    (should-not emacos-sms--confirm-id)
    (should (eq emacos-sms--state 'proposed))))

(ert-deftest emacos-sms-confirmation-expires ()
  (test-sms--with-ui
    (emacos-send-message "+14155550123" "hi")
    (emacos-sms--send-tap)
    (let ((proposal-id emacos-sms--proposal-id))
      (emacos-sms--expire-confirm proposal-id)
      (should-not emacos-sms--confirm-id)
      (should (eq emacos-sms--state 'proposed)))))

(ert-deftest emacos-sms-restage-invalidates-first-tap ()
  (test-sms--with-ui
    (emacos-send-message "+14155550123" "first")
    (emacos-sms--send-tap)
    (let ((old emacos-sms--proposal-id))
      (emacos-send-message "+14155550124" "second")
      (should (> emacos-sms--proposal-id old))
      (should-not emacos-sms--confirm-id)
      (should (equal emacos-sms--body "second")))))

(ert-deftest emacos-sms-hidden-proposal-cannot-confirm ()
  (test-sms--with-ui
    (emacos-send-message "+14155550123" "hi")
    (emacos-sms--send-tap)
    (setq test-sms--window-buffer (get-buffer-create "elsewhere"))
    (emacos-sms--send-tap)
    (should-not emacos-sms--confirm-id)
    (should (eq emacos-sms--state 'proposed))
    (kill-buffer "elsewhere")))

(ert-deftest emacos-sms-leave-and-return-requires-two-new-taps ()
  (test-sms--with-ui
    (let (requests)
      (setq emacos-sms-operation-function
            (lambda (number body _done)
              (push (list number body) requests)
              "pending: SMS requested"))
      (emacos-send-message "+14155550123" "hi")
      (emacos-sms--send-tap)
      (emacos-sms--post-command-disarm)
      (let ((sms-buffer test-sms--window-buffer)
            (elsewhere (get-buffer-create "test-sms-interruption")))
        (setq test-sms--window-buffer elsewhere)
        (emacos-sms--window-buffer-changed)
        (should-not emacos-sms--confirm-id)
        (setq test-sms--window-buffer sms-buffer)
        (emacos-sms--send-tap)
        (should emacos-sms--confirm-id)
        (should-not requests)
        (kill-buffer elsewhere)))))

(ert-deftest emacos-sms-killed-proposal-is-cancelled ()
  (test-sms--with-ui
    (emacos-send-message "+14155550123" "hi")
    (emacos-sms--send-tap)
    (kill-buffer "*SMS*")
    (should-not emacos-sms--state)
    (should-not emacos-sms--confirm-id)))

(ert-deftest emacos-sms-cancel-and-done-restore-previous-buffer ()
  (test-sms--with-ui
    (let ((home test-sms--window-buffer))
      (emacos-send-message "+14155550123" "cancel me")
      (emacos-sms--cancel)
      (should (eq test-sms--window-buffer home))
      (setq emacos-sms-operation-function
            (lambda (_number _body _done) "sent"))
      (emacos-send-message "+14155550123" "send me")
      (emacos-sms--send-tap)
      (emacos-sms--post-command-disarm)
      (emacos-sms--send-tap)
      (should (eq emacos-sms--state 'sent))
      (emacos-sms--dismiss)
      (should (eq test-sms--window-buffer home))
      (should-not emacos-sms--state))))

(ert-deftest emacos-sms-restage-restores-the-current-origin-buffer ()
  (test-sms--with-ui
    (let ((second-origin (get-buffer-create "test-sms-second-origin")))
      (unwind-protect
          (progn
            (emacos-send-message "+14155550123" "first")
            (setq emacos-sms--state 'sent
                  test-sms--window-buffer second-origin)
            (emacos-send-message "+14155550124" "second")
            (emacos-sms--cancel)
            (should (eq test-sms--window-buffer second-origin)))
        (when (buffer-live-p second-origin) (kill-buffer second-origin))))))

(ert-deftest emacos-sms-stale-completion-cannot-change-new-result ()
  (test-sms--with-ui
    (let (first-completion)
      (setq emacos-sms-operation-function
            (lambda (_number _body done)
              (setq first-completion done)
              "pending: SMS requested"))
      (emacos-send-message "+14155550123" "hi")
      (emacos-sms--send-tap)
      (emacos-sms--post-command-disarm)
      (emacos-sms--send-tap)
      (funcall first-completion "not-sent:no-modem")
      (should (eq emacos-sms--state 'failed))
      (let ((old-id emacos-sms--proposal-id))
        (emacos-send-message "+14155550124" "new")
        (funcall first-completion "sent")
        (should (> emacos-sms--proposal-id old-id))
        (should (eq emacos-sms--state 'proposed))))))

(ert-deftest emacos-sms-unknown-result-must-be-dismissed-before-restaging ()
  (test-sms--with-ui
    (emacos-send-message "+14155550123" "uncertain")
    (setq emacos-sms--state 'unknown
          emacos-sms--detail "Reason: send-failed")
    (let ((proposal-id emacos-sms--proposal-id))
      (should (equal
               (emacos-send-message "+14155550124" "new")
               "error: dismiss unknown message status before staging another message"))
      (should (equal emacos-sms--proposal-id proposal-id))
      (should (equal emacos-sms--body "uncertain"))
      (should (equal emacos-sms--detail "Reason: send-failed")))))

(ert-deftest emacos-sms-hidden-completion-does-not-steal-target ()
  (test-sms--with-ui
    (let (completion)
      (setq emacos-sms-operation-function
            (lambda (_number _body done)
              (setq completion done)
              "pending: SMS requested"))
      (emacos-send-message "+14155550123" "hi")
      (emacos-sms--send-tap)
      (emacos-sms--post-command-disarm)
      (emacos-sms--send-tap)
      (let ((elsewhere (get-buffer-create "elsewhere")))
        (setq test-sms--window-buffer elsewhere)
        (funcall completion "sent")
        (should (eq test-sms--window-buffer elsewhere))
        (should (eq emacos-sms--state 'sent))
        (should (string-match-p "SMS" (emacos-sms-mode-line-string)))
        (with-current-buffer "*SMS*"
          (should (string-prefix-p "Sent" (buffer-string))))
        (emacos-sms-show-status)
        (should (eq test-sms--window-buffer (get-buffer "*SMS*")))
        (emacos-sms--dismiss)
        (should (eq test-sms--window-buffer elsewhere))
        (kill-buffer elsewhere)))))

(ert-deftest emacos-sms-mode-line-badge-is-phone-global ()
  (test-sms--with-ui
    (should (equal (emacos-sms-mode-line-string) ""))
    (emacos-send-message "+14155550123" "hi")
    (should (equal (emacos-sms-mode-line-string) ""))
    (setq test-sms--window-buffer (get-buffer-create "chat-like-buffer"))
    (should (string-match-p "SMS" (emacos-sms-mode-line-string)))
    (let ((binding (lookup-key emacos-sms--mode-line-keymap
                               [mode-line mouse-1])))
      (should (eq binding #'emacos-sms-show-status)))
    (kill-buffer "chat-like-buffer")))

(ert-deftest emacos-sms-invalid-terminal-result-is-unknown ()
  (test-sms--with-ui
    (let (completion)
      (setq emacos-sms-operation-function
            (lambda (_number _body done)
              (setq completion done)
              "pending: SMS requested"))
      (emacos-send-message "+14155550123" "hi")
      (emacos-sms--send-tap)
      (emacos-sms--post-command-disarm)
      (emacos-sms--send-tap)
      (funcall completion "sent\nextra")
      (should (eq emacos-sms--state 'unknown)))))

(provide 'test-sms)
;;; test-sms.el ends here
