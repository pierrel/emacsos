;;; phone-sms.el --- confirmed outbound SMS primitives -*- lexical-binding: t; -*-

;; `emacsos-send-message' stages one exact number/body proposal.  The ordinary
;; UI path requires two consecutive local Send taps before its platform
;; transport runs.  Recipient lookup and intent interpretation belong to the
;; agent's sms skill, not this deterministic layer.

(require 'subr-x)

(defconst emacsos-sms--number-re "\\`\\+?[0-9]\\{5,15\\}\\'"
  "A concrete SMS number: optional leading + then 5-15 digits.")

(defconst emacsos-sms--max-body-bytes 4096
  "Maximum UTF-8 byte length accepted by the SMS primitive.")

(defconst emacsos-sms--confirm-timeout-seconds 15
  "Seconds allowed between the two Send taps.")

(defconst emacsos-sms--terminal-code-re
  "\\`\\(?:input-timeout\\|invalid-input\\|busy\\|no-modem\\|multiple-modems\\|no-service\\|dbus-unavailable\\|create-failed\\|send-failed\\|time-limit\\)\\'"
  "Finite error-code grammar emitted by the PinePhone helper.")

(defcustom emacsos-sms-operation-function nil
  "Optional platform SMS function called as (FUNCTION NUMBER BODY COMPLETION).
It normally returns \"pending: ...\" after starting asynchronous work and
calls COMPLETION once with `sent', `not-sent:CODE', or `unknown:CODE'.  A
failure to start may instead return one of those terminal results directly."
  :type '(choice (const :tag "Unavailable" nil) function)
  :group 'emacsos)

(declare-function emacsos--btn "os")
(declare-function emacsos--center "os")
(declare-function emacsos--render-page "os")
(declare-function emacsos--target "os")
(defvar emacsos--btn-label-scale)
(defvar emacsos--confirm-disarm-functions)
(defvar-local emacsos--keyboard-plane nil)

(defconst emacsos-sms--buffer-name "*SMS*")
(defvar emacsos-sms--state nil
  "Phone-global SMS state: nil, proposed, sending, sent, failed, or unknown.")
(defvar emacsos-sms--number nil)
(defvar emacsos-sms--body nil)
(defvar emacsos-sms--detail nil)
(defvar emacsos-sms--previous-buffer nil)
(defvar emacsos-sms--next-proposal-id 0)
(defvar emacsos-sms--proposal-id nil)
(defvar emacsos-sms--confirm-id nil)
(defvar emacsos-sms--confirm-timer nil)
(defvar emacsos-sms--skip-next-post-command-disarm nil)
(defvar emacsos-sms--dismissing nil)

(defun emacsos-sms--body-bytes (body)
  "Return BODY's exact UTF-8 byte length."
  (string-bytes (encode-coding-string body 'utf-8 t)))

(defun emacsos-sms--valid-body-p (body)
  "Return non-nil when BODY meets the deterministic transport contract."
  (and (stringp body)
       (not (string-empty-p body))
       (not (string-match-p "\0" body))
       (<= (emacsos-sms--body-bytes body) emacsos-sms--max-body-bytes)))

(defun emacsos-sms--escaped-char-p (char)
  "Return non-nil when CHAR must be made visible in the proposal preview."
  (or (< char 32)
      (<= 127 char 159)
      (eq (get-char-code-property char 'general-category) 'Cf)))

(defun emacsos-sms--preview-body (body)
  "Render BODY faithfully while exposing invisible control characters."
  (mapconcat (lambda (char)
               (cond
                ((eq char ?\\) "\\\\")
                ((emacsos-sms--escaped-char-p char)
                 (format "\\u{%04X}" char))
                (t (char-to-string char))))
             body ""))

(defun emacsos-sms--rerender ()
  "Re-render the phone control plane when available."
  (when (fboundp 'emacsos--render-page) (emacsos--render-page)))

(defun emacsos-sms--plane-button (label action &optional bg)
  "Insert one full-width SMS control LABEL invoking ACTION with optional BG."
  (let* ((window (get-buffer-window (current-buffer)))
         (width (max 6 (- (if window (window-body-width window) 20) 2))))
    (emacsos--btn (emacsos--center label width) action nil
                 emacsos--btn-label-scale bg)
    (insert "\n")))

(defun emacsos-sms--plane-proposed ()
  "Render Cancel and two-tap Send controls."
  (insert "\n")
  (emacsos-sms--plane-button "Cancel" #'emacsos-sms--cancel)
  (insert "\n")
  (emacsos-sms--plane-button
   (if emacsos-sms--confirm-id "Confirm send?" "Send")
   #'emacsos-sms--send-tap
   (and emacsos-sms--confirm-id "firebrick4")))

(defun emacsos-sms--plane-sending ()
  "Render the non-interactive sending state."
  (insert "\n\n  Sending…\n"))

(defun emacsos-sms--plane-terminal ()
  "Render the sole terminal-state control."
  (insert "\n")
  (emacsos-sms--plane-button "Done" #'emacsos-sms--dismiss))

(defun emacsos-sms--render ()
  "Render the current phone-global SMS proposal or result."
  (let ((buffer (get-buffer-create emacsos-sms--buffer-name)))
    (with-current-buffer buffer
      (add-hook 'kill-buffer-hook #'emacsos-sms--buffer-killed nil t)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (pcase emacsos-sms--state
                  ('proposed "Send message?\n")
                  ('sending "Sending…\n")
                  ('sent "Sent\n")
                  ('failed "Not sent\n")
                  ('unknown "Status unknown — do not resend\n")
                  (_ "Message\n"))
                "\nTo: " (or emacsos-sms--number "") "\n\n"
                (emacsos-sms--preview-body (or emacsos-sms--body "")))
        (when emacsos-sms--detail
          (insert "\n\n" emacsos-sms--detail))
        (goto-char (point-min)))
      (setq buffer-read-only t)
      (visual-line-mode 1)
      (setq-local truncate-lines nil
                  word-wrap t
                  emacsos--keyboard-plane
                  (pcase emacsos-sms--state
                    ('proposed #'emacsos-sms--plane-proposed)
                    ('sending #'emacsos-sms--plane-sending)
                    (_ #'emacsos-sms--plane-terminal))))
    buffer))

(defun emacsos-sms--capture-previous (window)
  "Capture WINDOW's current non-SMS buffer as the dismissal target."
  (let ((current (window-buffer window)))
    (unless (eq current (get-buffer emacsos-sms--buffer-name))
      (setq emacsos-sms--previous-buffer current))))

(defun emacsos-sms--show ()
  "Show the current SMS view; return its target window or nil."
  (let ((window (and (fboundp 'emacsos--target) (emacsos--target))))
    (when window
      (emacsos-sms--capture-previous window)
      (set-window-buffer window (emacsos-sms--render))
      (emacsos-sms--rerender)
      window)))

(defun emacsos-sms-show-status ()
  "Show the current SMS proposal/result and return Done to the current buffer."
  (interactive)
  (if (not emacsos-sms--state)
      (message "No message status")
    (let ((window (and (fboundp 'emacsos--target) (emacsos--target))))
      (if (not window)
          (message "SMS UI unavailable")
        (unless (eq (window-buffer window) (get-buffer emacsos-sms--buffer-name))
          (setq emacsos-sms--previous-buffer (window-buffer window)))
        (set-window-buffer window (emacsos-sms--render))
        (emacsos-sms--rerender)))))

(defconst emacsos-sms--mode-line-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] #'emacsos-sms-show-status)
    map)
  "Keymap for the phone-global SMS status badge.")

(defun emacsos-sms-mode-line-string ()
  "Return a tappable SMS badge while an active SMS screen is hidden."
  (condition-case nil
      (if (and emacsos-sms--state
               (not (emacsos-sms--visible-p)))
          (concat " " (propertize "● SMS"
                                  'local-map emacsos-sms--mode-line-keymap
                                  'mouse-face 'mode-line-highlight
                                  'help-echo "Tap to view message status"))
        "")
    (error "")))

(defun emacsos-sms--visible-p ()
  "Return non-nil when the SMS buffer owns the phone's target window."
  (let ((window (and (fboundp 'emacsos--target) (emacsos--target))))
    (and window (eq (window-buffer window) (get-buffer emacsos-sms--buffer-name)))))

(defun emacsos-sms--cancel-confirm-timer ()
  "Cancel the active confirmation timer."
  (when (timerp emacsos-sms--confirm-timer)
    (cancel-timer emacsos-sms--confirm-timer))
  (setq emacsos-sms--confirm-timer nil))

(defun emacsos-sms--clear-confirm (&optional rerender)
  "Clear the armed Send state and optionally RERENDER the proposal."
  (emacsos-sms--cancel-confirm-timer)
  (setq emacsos-sms--confirm-id nil
        emacsos-sms--skip-next-post-command-disarm nil)
  (when (and rerender (eq emacsos-sms--state 'proposed))
    (emacsos-sms--rerender)))

(defun emacsos-sms--expire-confirm (proposal-id)
  "Expire confirmation if it still belongs to PROPOSAL-ID."
  (when (and (eq emacsos-sms--state 'proposed)
             (equal proposal-id emacsos-sms--proposal-id)
             (equal proposal-id emacsos-sms--confirm-id))
    (setq emacsos-sms--confirm-timer nil
          emacsos-sms--confirm-id nil
          emacsos-sms--skip-next-post-command-disarm nil)
    (emacsos-sms--rerender)))

(defun emacsos-sms--arm ()
  "Arm the visible current proposal for one next local Send tap."
  (emacsos-sms--cancel-confirm-timer)
  (setq emacsos-sms--confirm-id emacsos-sms--proposal-id
        emacsos-sms--skip-next-post-command-disarm t
        emacsos-sms--confirm-timer
        (run-at-time emacsos-sms--confirm-timeout-seconds nil
                     #'emacsos-sms--expire-confirm emacsos-sms--proposal-id))
  (emacsos-sms--rerender))

(defun emacsos-sms--parse-result (status)
  "Return (STATE . DETAIL) for platform STATUS."
  (cond
   ((equal status "sent") '(sent . "Modem accepted the message."))
   ((and (stringp status)
         (string-match "\\`not-sent:\\(.+\\)\\'" status)
         (string-match-p emacsos-sms--terminal-code-re (match-string 1 status)))
    (cons 'failed (format "Reason: %s" (match-string 1 status))))
   ((and (stringp status)
         (string-match "\\`unknown:\\(.+\\)\\'" status)
         (string-match-p emacsos-sms--terminal-code-re (match-string 1 status)))
    (cons 'unknown (format "Reason: %s" (match-string 1 status))))
   (t '(unknown . "The helper returned no valid terminal result."))))

(defun emacsos-sms--finished (proposal-id status)
  "Apply terminal STATUS only if PROPOSAL-ID still owns sending state."
  (when (and (eq emacsos-sms--state 'sending)
             (equal proposal-id emacsos-sms--proposal-id))
    (let ((visible (emacsos-sms--visible-p)))
      (pcase-let ((`(,state . ,detail) (emacsos-sms--parse-result status)))
        (setq emacsos-sms--state state
              emacsos-sms--detail detail))
      (if visible
          (emacsos-sms--show)
        (emacsos-sms--render)
        (message "SMS status updated; tap the SMS badge to view")))))

(defun emacsos-sms--start-send ()
  "Consume confirmation and start the exact current proposal once."
  (let ((proposal-id emacsos-sms--proposal-id)
        (number emacsos-sms--number)
        (body emacsos-sms--body))
    (emacsos-sms--clear-confirm)
    (setq emacsos-sms--state 'sending
          emacsos-sms--detail nil)
    (emacsos-sms--show)
    (let* ((finish (lambda (status)
                     (emacsos-sms--finished proposal-id status)))
           (status
            (if emacsos-sms-operation-function
                (condition-case nil
                    (funcall emacsos-sms-operation-function number body finish)
                  (error "unknown:dbus-unavailable"))
              "not-sent:dbus-unavailable")))
      (unless (and (stringp status) (string-prefix-p "pending:" status))
        (funcall finish status)))))

(defun emacsos-sms--send-tap ()
  "Arm or confirm Send for the one visible proposal."
  (cond
   ((not (and (eq emacsos-sms--state 'proposed)
              emacsos-sms--proposal-id
              (emacsos-sms--visible-p)))
    (emacsos-sms--clear-confirm t)
    (message "emacsos-sms: proposal is no longer visible"))
   ((equal emacsos-sms--confirm-id emacsos-sms--proposal-id)
    (emacsos-sms--start-send))
   (t (emacsos-sms--arm))))

(defun emacsos-sms--cancel ()
  "Cancel the current unsent proposal."
  (when (eq emacsos-sms--state 'proposed) (emacsos-sms--dismiss)))

(defun emacsos-sms--buffer-killed ()
  "Clear an unsent proposal if its authorization view is killed."
  (unless emacsos-sms--dismissing
    (when (eq emacsos-sms--state 'proposed)
      (emacsos-sms--clear-confirm)
      (setq emacsos-sms--state nil
            emacsos-sms--number nil
            emacsos-sms--body nil
            emacsos-sms--proposal-id nil
            emacsos-sms--previous-buffer nil))))

(defun emacsos-sms--dismiss ()
  "Dismiss a proposal/result and restore the previous top buffer."
  (interactive)
  (unless (eq emacsos-sms--state 'sending)
    (emacsos-sms--clear-confirm)
    (let ((window (and (fboundp 'emacsos--target) (emacsos--target)))
          (previous (if (buffer-live-p emacsos-sms--previous-buffer)
                        emacsos-sms--previous-buffer
                      (get-buffer-create "*scratch*"))))
      (setq emacsos-sms--state nil
            emacsos-sms--number nil
            emacsos-sms--body nil
            emacsos-sms--detail nil
            emacsos-sms--proposal-id nil
            emacsos-sms--previous-buffer nil)
      (when (and window (eq (window-buffer window)
                            (get-buffer emacsos-sms--buffer-name)))
        (set-window-buffer window previous))
      (when (get-buffer emacsos-sms--buffer-name)
        (let ((emacsos-sms--dismissing t))
          (kill-buffer emacsos-sms--buffer-name)))
      (emacsos-sms--rerender))))

;;;###autoload
(defun emacsos-send-message (number body)
  "Stage an exact outbound SMS to NUMBER containing BODY; never send it.
Interactively prompt for both values, then show the immutable local proposal."
  (interactive (list (read-string "SMS number (+E164): ")
                     (read-string "Message: ")))
  ;; Any restage attempt invalidates an existing arm before validation.
  (when (eq emacsos-sms--state 'proposed) (emacsos-sms--clear-confirm t))
  (let ((result
         (cond
          ((not (and (stringp number)
                     (string-match-p emacsos-sms--number-re number)))
           "error: invalid number")
          ((not (emacsos-sms--valid-body-p body))
           "error: invalid message body")
          ((eq emacsos-sms--state 'sending)
           "error: message send already in progress")
          ((eq emacsos-sms--state 'unknown)
           "error: dismiss unknown message status before staging another message")
          (t
           (setq emacsos-sms--next-proposal-id (1+ emacsos-sms--next-proposal-id)
                 emacsos-sms--proposal-id emacsos-sms--next-proposal-id
                 emacsos-sms--state 'proposed
                 emacsos-sms--number number
                 emacsos-sms--body body
                 emacsos-sms--detail nil)
           (if (emacsos-sms--show)
               "confirmation-required: confirm on phone"
             (emacsos-sms--dismiss)
             "error: SMS UI unavailable")))))
    (when (string-prefix-p "error:" result)
      (message "%s" result))
    result))

(defun emacsos-sms--post-command-disarm ()
  "Disarm Send after the first arming command or any unrelated command."
  (when emacsos-sms--confirm-id
    (if emacsos-sms--skip-next-post-command-disarm
        (setq emacsos-sms--skip-next-post-command-disarm nil)
      (emacsos-sms--clear-confirm t))))

(defun emacsos-sms--window-buffer-changed (&rest _)
  "Disarm Send as soon as the proposal loses the phone target window."
  (when (and emacsos-sms--confirm-id (not (emacsos-sms--visible-p)))
    (emacsos-sms--clear-confirm t)))

(defun emacsos-sms--maybe-disarm (action arg)
  "Disarm unless ACTION and ARG identify the confirming Send button."
  (unless (and (eq action #'emacsos-sms--send-tap) (null arg))
    (emacsos-sms--clear-confirm t)))

(add-hook 'post-command-hook #'emacsos-sms--post-command-disarm)
(add-hook 'window-buffer-change-functions #'emacsos-sms--window-buffer-changed)
(add-hook 'emacsos--confirm-disarm-functions #'emacsos-sms--maybe-disarm)

(provide 'phone-sms)
;;; phone-sms.el ends here
