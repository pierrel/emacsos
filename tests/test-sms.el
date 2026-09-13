;;; test-sms.el --- Tests for confirmed outbound SMS -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(require 'phone-sms)
(defvar emacsos--btn-label-scale 0.8)
(defvar test-sms--window-buffer nil)

(defmacro test-sms--with-ui (&rest body)
  "Run BODY with one fake phone target and isolated global SMS state."
  (declare (indent 0))
  `(let ((test-sms--window-buffer (get-buffer-create "test-sms-home"))
         (emacsos-sms--state nil)
         (emacsos-sms--number nil)
         (emacsos-sms--body nil)
         (emacsos-sms--detail nil)
         (emacsos-sms--previous-buffer nil)
         (emacsos-sms--next-proposal-id 0)
         (emacsos-sms--proposal-id nil)
         (emacsos-sms--confirm-id nil)
         (emacsos-sms--confirm-timer nil)
         (emacsos-sms--skip-next-post-command-disarm nil)
         (emacsos-sms-operation-function nil))
     (cl-letf (((symbol-function 'emacsos--target) (lambda () 'window))
               ((symbol-function 'window-buffer)
                (lambda (&rest _) test-sms--window-buffer))
               ((symbol-function 'set-window-buffer)
                (lambda (_window buffer &rest _)
                  (setq test-sms--window-buffer buffer)))
               ((symbol-function 'emacsos-sms--rerender) #'ignore)
               ((symbol-function 'run-at-time)
                (lambda (&rest _) 'test-sms-timer))
               ((symbol-function 'timerp)
                (lambda (value) (eq value 'test-sms-timer)))
               ((symbol-function 'cancel-timer) #'ignore))
       (unwind-protect
           (progn ,@body)
         (dolist (name '("test-sms-home" "*SMS*"))
           (when (get-buffer name) (kill-buffer name)))))))

(ert-deftest emacsos-sms-stages-exact-message-without-sending ()
  (test-sms--with-ui
    (let ((emacsos-sms-operation-function
           (lambda (&rest _) (error "must not send while staging"))))
      (should (equal (emacsos-send-message "+14155550123" "Hi “Ana” 👋")
                     "confirmation-required: confirm on phone"))
      (should (eq emacsos-sms--state 'proposed))
      (should (equal emacsos-sms--number "+14155550123"))
      (should (equal emacsos-sms--body "Hi “Ana” 👋"))
      (with-current-buffer "*SMS*"
        (should (string-match-p "Hi “Ana” 👋" (buffer-string)))))))

(ert-deftest emacsos-sms-rejects-invalid-input ()
  (test-sms--with-ui
    (should (string-prefix-p "error:" (emacsos-send-message "Ana" "hi")))
    (should (string-prefix-p "error:" (emacsos-send-message "+14155550123" "")))
    (should (string-prefix-p
             "error:"
             (emacsos-send-message "+14155550123"
                                  (make-string 4097 ?a))))
    (should-not emacsos-sms--state)))

(ert-deftest emacsos-sms-interactive-validation-error-is-visible ()
  (test-sms--with-ui
    (let ((answers '("Ana" "hi")) shown)
      (cl-letf (((symbol-function 'read-string)
                 (lambda (&rest _) (pop answers)))
                ((symbol-function 'message)
                 (lambda (format-string &rest args)
                   (setq shown (apply #'format format-string args)))))
        (should (equal (call-interactively #'emacsos-send-message)
                       "error: invalid number"))
        (should (equal shown "error: invalid number"))))))

(ert-deftest emacsos-sms-preview-exposes-control-characters ()
  (test-sms--with-ui
    (emacsos-send-message
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

(ert-deftest emacsos-sms-preview-cannot-collide-with-literal-escape-text ()
  (should-not
   (equal (emacsos-sms--preview-body "\\u{202E}")
          (emacsos-sms--preview-body (string #x202e))))
  (should (equal (emacsos-sms--preview-body "\\u{202E}")
                 "\\\\u{202E}"))
  (should (equal (emacsos-sms--preview-body (string #x202e))
                 "\\u{202E}")))

(ert-deftest emacsos-sms-two-taps-send-once ()
  (test-sms--with-ui
    (let (requests completion)
      (setq emacsos-sms-operation-function
            (lambda (number body done)
              (push (list number body) requests)
              (setq completion done)
              "pending: SMS requested"))
      (emacsos-send-message "+14155550123" "exact text")
      (emacsos-sms--send-tap)
      (should-not requests)
      (emacsos-sms--post-command-disarm)
      (emacsos-sms--send-tap)
      (should (equal requests '(("+14155550123" "exact text"))))
      (should (eq emacsos-sms--state 'sending))
      (funcall completion "sent")
      (should (eq emacsos-sms--state 'sent))
      (with-current-buffer "*SMS*"
        (should (string-match-p "Modem accepted" (buffer-string)))))))

(ert-deftest emacsos-sms-unrelated-command-disarms ()
  (test-sms--with-ui
    (emacsos-send-message "+14155550123" "hi")
    (emacsos-sms--send-tap)
    (emacsos-sms--post-command-disarm) ; skip the arming command itself
    (emacsos-sms--post-command-disarm) ; next command disarms
    (should-not emacsos-sms--confirm-id)
    (should (eq emacsos-sms--state 'proposed))))

(ert-deftest emacsos-sms-confirmation-expires ()
  (test-sms--with-ui
    (emacsos-send-message "+14155550123" "hi")
    (emacsos-sms--send-tap)
    (let ((proposal-id emacsos-sms--proposal-id))
      (emacsos-sms--expire-confirm proposal-id)
      (should-not emacsos-sms--confirm-id)
      (should (eq emacsos-sms--state 'proposed)))))

(ert-deftest emacsos-sms-restage-invalidates-first-tap ()
  (test-sms--with-ui
    (emacsos-send-message "+14155550123" "first")
    (emacsos-sms--send-tap)
    (let ((old emacsos-sms--proposal-id))
      (emacsos-send-message "+14155550124" "second")
      (should (> emacsos-sms--proposal-id old))
      (should-not emacsos-sms--confirm-id)
      (should (equal emacsos-sms--body "second")))))

(ert-deftest emacsos-sms-hidden-proposal-cannot-confirm ()
  (test-sms--with-ui
    (emacsos-send-message "+14155550123" "hi")
    (emacsos-sms--send-tap)
    (setq test-sms--window-buffer (get-buffer-create "elsewhere"))
    (emacsos-sms--send-tap)
    (should-not emacsos-sms--confirm-id)
    (should (eq emacsos-sms--state 'proposed))
    (kill-buffer "elsewhere")))

(ert-deftest emacsos-sms-leave-and-return-requires-two-new-taps ()
  (test-sms--with-ui
    (let (requests)
      (setq emacsos-sms-operation-function
            (lambda (number body _done)
              (push (list number body) requests)
              "pending: SMS requested"))
      (emacsos-send-message "+14155550123" "hi")
      (emacsos-sms--send-tap)
      (emacsos-sms--post-command-disarm)
      (let ((sms-buffer test-sms--window-buffer)
            (elsewhere (get-buffer-create "test-sms-interruption")))
        (setq test-sms--window-buffer elsewhere)
        (emacsos-sms--window-buffer-changed)
        (should-not emacsos-sms--confirm-id)
        (setq test-sms--window-buffer sms-buffer)
        (emacsos-sms--send-tap)
        (should emacsos-sms--confirm-id)
        (should-not requests)
        (kill-buffer elsewhere)))))

(ert-deftest emacsos-sms-killed-proposal-is-cancelled ()
  (test-sms--with-ui
    (emacsos-send-message "+14155550123" "hi")
    (emacsos-sms--send-tap)
    (kill-buffer "*SMS*")
    (should-not emacsos-sms--state)
    (should-not emacsos-sms--confirm-id)))

(ert-deftest emacsos-sms-cancel-and-done-restore-previous-buffer ()
  (test-sms--with-ui
    (let ((home test-sms--window-buffer))
      (emacsos-send-message "+14155550123" "cancel me")
      (emacsos-sms--cancel)
      (should (eq test-sms--window-buffer home))
      (setq emacsos-sms-operation-function
            (lambda (_number _body _done) "sent"))
      (emacsos-send-message "+14155550123" "send me")
      (emacsos-sms--send-tap)
      (emacsos-sms--post-command-disarm)
      (emacsos-sms--send-tap)
      (should (eq emacsos-sms--state 'sent))
      (emacsos-sms--dismiss)
      (should (eq test-sms--window-buffer home))
      (should-not emacsos-sms--state))))

(ert-deftest emacsos-sms-restage-restores-the-current-origin-buffer ()
  (test-sms--with-ui
    (let ((second-origin (get-buffer-create "test-sms-second-origin")))
      (unwind-protect
          (progn
            (emacsos-send-message "+14155550123" "first")
            (setq emacsos-sms--state 'sent
                  test-sms--window-buffer second-origin)
            (emacsos-send-message "+14155550124" "second")
            (emacsos-sms--cancel)
            (should (eq test-sms--window-buffer second-origin)))
        (when (buffer-live-p second-origin) (kill-buffer second-origin))))))

(ert-deftest emacsos-sms-stale-completion-cannot-change-new-result ()
  (test-sms--with-ui
    (let (first-completion)
      (setq emacsos-sms-operation-function
            (lambda (_number _body done)
              (setq first-completion done)
              "pending: SMS requested"))
      (emacsos-send-message "+14155550123" "hi")
      (emacsos-sms--send-tap)
      (emacsos-sms--post-command-disarm)
      (emacsos-sms--send-tap)
      (funcall first-completion "not-sent:no-modem")
      (should (eq emacsos-sms--state 'failed))
      (let ((old-id emacsos-sms--proposal-id))
        (emacsos-send-message "+14155550124" "new")
        (funcall first-completion "sent")
        (should (> emacsos-sms--proposal-id old-id))
        (should (eq emacsos-sms--state 'proposed))))))

(ert-deftest emacsos-sms-unknown-result-must-be-dismissed-before-restaging ()
  (test-sms--with-ui
    (emacsos-send-message "+14155550123" "uncertain")
    (setq emacsos-sms--state 'unknown
          emacsos-sms--detail "Reason: send-failed")
    (let ((proposal-id emacsos-sms--proposal-id))
      (should (equal
               (emacsos-send-message "+14155550124" "new")
               "error: dismiss unknown message status before staging another message"))
      (should (equal emacsos-sms--proposal-id proposal-id))
      (should (equal emacsos-sms--body "uncertain"))
      (should (equal emacsos-sms--detail "Reason: send-failed")))))

(ert-deftest emacsos-sms-hidden-completion-does-not-steal-target ()
  (test-sms--with-ui
    (let (completion)
      (setq emacsos-sms-operation-function
            (lambda (_number _body done)
              (setq completion done)
              "pending: SMS requested"))
      (emacsos-send-message "+14155550123" "hi")
      (emacsos-sms--send-tap)
      (emacsos-sms--post-command-disarm)
      (emacsos-sms--send-tap)
      (let ((elsewhere (get-buffer-create "elsewhere")))
        (setq test-sms--window-buffer elsewhere)
        (funcall completion "sent")
        (should (eq test-sms--window-buffer elsewhere))
        (should (eq emacsos-sms--state 'sent))
        (should (string-match-p "SMS" (emacsos-sms-mode-line-string)))
        (with-current-buffer "*SMS*"
          (should (string-prefix-p "Sent" (buffer-string))))
        (emacsos-sms-show-status)
        (should (eq test-sms--window-buffer (get-buffer "*SMS*")))
        (emacsos-sms--dismiss)
        (should (eq test-sms--window-buffer elsewhere))
        (kill-buffer elsewhere)))))

(ert-deftest emacsos-sms-mode-line-badge-is-phone-global ()
  (test-sms--with-ui
    (should (equal (emacsos-sms-mode-line-string) ""))
    (emacsos-send-message "+14155550123" "hi")
    (should (equal (emacsos-sms-mode-line-string) ""))
    (setq test-sms--window-buffer (get-buffer-create "chat-like-buffer"))
    (should (string-match-p "SMS" (emacsos-sms-mode-line-string)))
    (let ((binding (lookup-key emacsos-sms--mode-line-keymap
                               [mode-line mouse-1])))
      (should (eq binding #'emacsos-sms-show-status)))
    (kill-buffer "chat-like-buffer")))

(ert-deftest emacsos-sms-invalid-terminal-result-is-unknown ()
  (test-sms--with-ui
    (let (completion)
      (setq emacsos-sms-operation-function
            (lambda (_number _body done)
              (setq completion done)
              "pending: SMS requested"))
      (emacsos-send-message "+14155550123" "hi")
      (emacsos-sms--send-tap)
      (emacsos-sms--post-command-disarm)
      (emacsos-sms--send-tap)
      (funcall completion "sent\nextra")
      (should (eq emacsos-sms--state 'unknown)))))

(provide 'test-sms)
;;; test-sms.el ends here
