;;; phone-sms.el --- confirmed outbound SMS primitives -*- lexical-binding: t; -*-

;; `emacos-send-message' stages one exact number/body proposal.  The ordinary
;; UI path requires two consecutive local Send taps before its platform
;; transport runs.  Recipient lookup and intent interpretation belong to the
;; agent's sms skill, not this deterministic layer.

(require 'subr-x)

(defconst emacos-sms--number-re "\\`\\+?[0-9]\\{5,15\\}\\'"
  "A concrete SMS number: optional leading + then 5-15 digits.")

(defconst emacos-sms--max-body-bytes 4096
  "Maximum UTF-8 byte length accepted by the SMS primitive.")

(defconst emacos-sms--confirm-timeout-seconds 15
  "Seconds allowed between the two Send taps.")

(defconst emacos-sms--terminal-code-re
  "\\`\\(?:input-timeout\\|invalid-input\\|busy\\|no-modem\\|multiple-modems\\|dbus-unavailable\\|create-failed\\|send-failed\\|time-limit\\)\\'"
  "Finite error-code grammar emitted by the PinePhone helper.")

(defcustom emacos-sms-operation-function nil
  "Optional platform SMS function called as (FUNCTION NUMBER BODY COMPLETION).
It normally returns \"pending: ...\" after starting asynchronous work and
calls COMPLETION once with `sent', `not-sent:CODE', or `unknown:CODE'.  A
failure to start may instead return one of those terminal results directly."
  :type '(choice (const :tag "Unavailable" nil) function)
  :group 'emacsos)

(declare-function emacos--btn "os")
(declare-function emacos--center "os")
(declare-function emacos--render-page "os")
(declare-function emacos--target "os")
(defvar emacos--btn-label-scale)
(defvar emacos--confirm-disarm-functions)
(defvar-local emacos--keyboard-plane nil)

(defconst emacos-sms--buffer-name "*SMS*")
(defvar emacos-sms--state nil
  "Phone-global SMS state: nil, proposed, sending, sent, failed, or unknown.")
(defvar emacos-sms--number nil)
(defvar emacos-sms--body nil)
(defvar emacos-sms--detail nil)
(defvar emacos-sms--previous-buffer nil)
(defvar emacos-sms--next-proposal-id 0)
(defvar emacos-sms--proposal-id nil)
(defvar emacos-sms--confirm-id nil)
(defvar emacos-sms--confirm-timer nil)
(defvar emacos-sms--skip-next-post-command-disarm nil)
(defvar emacos-sms--dismissing nil)

(defun emacos-sms--body-bytes (body)
  "Return BODY's exact UTF-8 byte length."
  (string-bytes (encode-coding-string body 'utf-8 t)))

(defun emacos-sms--valid-body-p (body)
  "Return non-nil when BODY meets the deterministic transport contract."
  (and (stringp body)
       (not (string-empty-p body))
       (not (string-match-p "\0" body))
       (<= (emacos-sms--body-bytes body) emacos-sms--max-body-bytes)))

(defun emacos-sms--escaped-char-p (char)
  "Return non-nil when CHAR must be made visible in the proposal preview."
  (or (< char 32)
      (<= 127 char 159)
      (eq (get-char-code-property char 'general-category) 'Cf)))

(defun emacos-sms--preview-body (body)
  "Render BODY faithfully while exposing invisible control characters."
  (mapconcat (lambda (char)
               (cond
                ((eq char ?\\) "\\\\")
                ((emacos-sms--escaped-char-p char)
                 (format "\\u{%04X}" char))
                (t (char-to-string char))))
             body ""))

(defun emacos-sms--rerender ()
  "Re-render the phone control plane when available."
  (when (fboundp 'emacos--render-page) (emacos--render-page)))

(defun emacos-sms--plane-button (label action &optional bg)
  "Insert one full-width SMS control LABEL invoking ACTION with optional BG."
  (let* ((window (get-buffer-window (current-buffer)))
         (width (max 6 (- (if window (window-body-width window) 20) 2))))
    (emacos--btn (emacos--center label width) action nil
                 emacos--btn-label-scale bg)
    (insert "\n")))

(defun emacos-sms--plane-proposed ()
  "Render Cancel and two-tap Send controls."
  (insert "\n")
  (emacos-sms--plane-button "Cancel" #'emacos-sms--cancel)
  (insert "\n")
  (emacos-sms--plane-button
   (if emacos-sms--confirm-id "Confirm send?" "Send")
   #'emacos-sms--send-tap
   (and emacos-sms--confirm-id "firebrick4")))

(defun emacos-sms--plane-sending ()
  "Render the non-interactive sending state."
  (insert "\n\n  Sending…\n"))

(defun emacos-sms--plane-terminal ()
  "Render the sole terminal-state control."
  (insert "\n")
  (emacos-sms--plane-button "Done" #'emacos-sms--dismiss))

(defun emacos-sms--render ()
  "Render the current phone-global SMS proposal or result."
  (let ((buffer (get-buffer-create emacos-sms--buffer-name)))
    (with-current-buffer buffer
      (add-hook 'kill-buffer-hook #'emacos-sms--buffer-killed nil t)
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (pcase emacos-sms--state
                  ('proposed "Send message?\n")
                  ('sending "Sending…\n")
                  ('sent "Sent\n")
                  ('failed "Not sent\n")
                  ('unknown "Status unknown — do not resend\n")
                  (_ "Message\n"))
                "\nTo: " (or emacos-sms--number "") "\n\n"
                (emacos-sms--preview-body (or emacos-sms--body "")))
        (when emacos-sms--detail
          (insert "\n\n" emacos-sms--detail))
        (goto-char (point-min)))
      (setq buffer-read-only t)
      (visual-line-mode 1)
      (setq-local truncate-lines nil
                  word-wrap t
                  emacos--keyboard-plane
                  (pcase emacos-sms--state
                    ('proposed #'emacos-sms--plane-proposed)
                    ('sending #'emacos-sms--plane-sending)
                    (_ #'emacos-sms--plane-terminal))))
    buffer))

(defun emacos-sms--capture-previous (window)
  "Capture WINDOW's current non-SMS buffer as the dismissal target."
  (let ((current (window-buffer window)))
    (unless (eq current (get-buffer emacos-sms--buffer-name))
      (setq emacos-sms--previous-buffer current))))

(defun emacos-sms--show ()
  "Show the current SMS view; return its target window or nil."
  (let ((window (and (fboundp 'emacos--target) (emacos--target))))
    (when window
      (emacos-sms--capture-previous window)
      (set-window-buffer window (emacos-sms--render))
      (emacos-sms--rerender)
      window)))

(defun emacos-sms-show-status ()
  "Show the current SMS proposal/result and return Done to the current buffer."
  (interactive)
  (if (not emacos-sms--state)
      (message "No message status")
    (let ((window (and (fboundp 'emacos--target) (emacos--target))))
      (if (not window)
          (message "SMS UI unavailable")
        (unless (eq (window-buffer window) (get-buffer emacos-sms--buffer-name))
          (setq emacos-sms--previous-buffer (window-buffer window)))
        (set-window-buffer window (emacos-sms--render))
        (emacos-sms--rerender)))))

(defconst emacos-sms--mode-line-keymap
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] #'emacos-sms-show-status)
    map)
  "Keymap for the phone-global SMS status badge.")

(defun emacos-sms-mode-line-string ()
  "Return a tappable SMS badge while an active SMS screen is hidden."
  (condition-case nil
      (if (and emacos-sms--state
               (not (emacos-sms--visible-p)))
          (concat " " (propertize "● SMS"
                                  'local-map emacos-sms--mode-line-keymap
                                  'mouse-face 'mode-line-highlight
                                  'help-echo "Tap to view message status"))
        "")
    (error "")))

(defun emacos-sms--visible-p ()
  "Return non-nil when the SMS buffer owns the phone's target window."
  (let ((window (and (fboundp 'emacos--target) (emacos--target))))
    (and window (eq (window-buffer window) (get-buffer emacos-sms--buffer-name)))))

(defun emacos-sms--cancel-confirm-timer ()
  "Cancel the active confirmation timer."
  (when (timerp emacos-sms--confirm-timer)
    (cancel-timer emacos-sms--confirm-timer))
  (setq emacos-sms--confirm-timer nil))

(defun emacos-sms--clear-confirm (&optional rerender)
  "Clear the armed Send state and optionally RERENDER the proposal."
  (emacos-sms--cancel-confirm-timer)
  (setq emacos-sms--confirm-id nil
        emacos-sms--skip-next-post-command-disarm nil)
  (when (and rerender (eq emacos-sms--state 'proposed))
    (emacos-sms--rerender)))

(defun emacos-sms--expire-confirm (proposal-id)
  "Expire confirmation if it still belongs to PROPOSAL-ID."
  (when (and (eq emacos-sms--state 'proposed)
             (equal proposal-id emacos-sms--proposal-id)
             (equal proposal-id emacos-sms--confirm-id))
    (setq emacos-sms--confirm-timer nil
          emacos-sms--confirm-id nil
          emacos-sms--skip-next-post-command-disarm nil)
    (emacos-sms--rerender)))

(defun emacos-sms--arm ()
  "Arm the visible current proposal for one next local Send tap."
  (emacos-sms--cancel-confirm-timer)
  (setq emacos-sms--confirm-id emacos-sms--proposal-id
        emacos-sms--skip-next-post-command-disarm t
        emacos-sms--confirm-timer
        (run-at-time emacos-sms--confirm-timeout-seconds nil
                     #'emacos-sms--expire-confirm emacos-sms--proposal-id))
  (emacos-sms--rerender))

(defun emacos-sms--parse-result (status)
  "Return (STATE . DETAIL) for platform STATUS."
  (cond
   ((equal status "sent") '(sent . "Modem accepted the message."))
   ((and (stringp status)
         (string-match "\\`not-sent:\\(.+\\)\\'" status)
         (string-match-p emacos-sms--terminal-code-re (match-string 1 status)))
    (cons 'failed (format "Reason: %s" (match-string 1 status))))
   ((and (stringp status)
         (string-match "\\`unknown:\\(.+\\)\\'" status)
         (string-match-p emacos-sms--terminal-code-re (match-string 1 status)))
    (cons 'unknown (format "Reason: %s" (match-string 1 status))))
   (t '(unknown . "The helper returned no valid terminal result."))))

(defun emacos-sms--finished (proposal-id status)
  "Apply terminal STATUS only if PROPOSAL-ID still owns sending state."
  (when (and (eq emacos-sms--state 'sending)
             (equal proposal-id emacos-sms--proposal-id))
    (let ((visible (emacos-sms--visible-p)))
      (pcase-let ((`(,state . ,detail) (emacos-sms--parse-result status)))
        (setq emacos-sms--state state
              emacos-sms--detail detail))
      (if visible
          (emacos-sms--show)
        (emacos-sms--render)
        (message "SMS status updated; tap the SMS badge to view")))))

(defun emacos-sms--start-send ()
  "Consume confirmation and start the exact current proposal once."
  (let ((proposal-id emacos-sms--proposal-id)
        (number emacos-sms--number)
        (body emacos-sms--body))
    (emacos-sms--clear-confirm)
    (setq emacos-sms--state 'sending
          emacos-sms--detail nil)
    (emacos-sms--show)
    (let* ((finish (lambda (status)
                     (emacos-sms--finished proposal-id status)))
           (status
            (if emacos-sms-operation-function
                (condition-case nil
                    (funcall emacos-sms-operation-function number body finish)
                  (error "unknown:dbus-unavailable"))
              "not-sent:dbus-unavailable")))
      (unless (and (stringp status) (string-prefix-p "pending:" status))
        (funcall finish status)))))

(defun emacos-sms--send-tap ()
  "Arm or confirm Send for the one visible proposal."
  (cond
   ((not (and (eq emacos-sms--state 'proposed)
              emacos-sms--proposal-id
              (emacos-sms--visible-p)))
    (emacos-sms--clear-confirm t)
    (message "emacos-sms: proposal is no longer visible"))
   ((equal emacos-sms--confirm-id emacos-sms--proposal-id)
    (emacos-sms--start-send))
   (t (emacos-sms--arm))))

(defun emacos-sms--cancel ()
  "Cancel the current unsent proposal."
  (when (eq emacos-sms--state 'proposed) (emacos-sms--dismiss)))

(defun emacos-sms--buffer-killed ()
  "Clear an unsent proposal if its authorization view is killed."
  (unless emacos-sms--dismissing
    (when (eq emacos-sms--state 'proposed)
      (emacos-sms--clear-confirm)
      (setq emacos-sms--state nil
            emacos-sms--number nil
            emacos-sms--body nil
            emacos-sms--proposal-id nil
            emacos-sms--previous-buffer nil))))

(defun emacos-sms--dismiss ()
  "Dismiss a proposal/result and restore the previous top buffer."
  (interactive)
  (unless (eq emacos-sms--state 'sending)
    (emacos-sms--clear-confirm)
    (let ((window (and (fboundp 'emacos--target) (emacos--target)))
          (previous (if (buffer-live-p emacos-sms--previous-buffer)
                        emacos-sms--previous-buffer
                      (get-buffer-create "*scratch*"))))
      (setq emacos-sms--state nil
            emacos-sms--number nil
            emacos-sms--body nil
            emacos-sms--detail nil
            emacos-sms--proposal-id nil
            emacos-sms--previous-buffer nil)
      (when (and window (eq (window-buffer window)
                            (get-buffer emacos-sms--buffer-name)))
        (set-window-buffer window previous))
      (when (get-buffer emacos-sms--buffer-name)
        (let ((emacos-sms--dismissing t))
          (kill-buffer emacos-sms--buffer-name)))
      (emacos-sms--rerender))))

;;;###autoload
(defun emacos-send-message (number body)
  "Stage an exact outbound SMS to NUMBER containing BODY; never send it.
Interactively prompt for both values, then show the immutable local proposal."
  (interactive (list (read-string "SMS number (+E164): ")
                     (read-string "Message: ")))
  ;; Any restage attempt invalidates an existing arm before validation.
  (when (eq emacos-sms--state 'proposed) (emacos-sms--clear-confirm t))
  (let ((result
         (cond
          ((not (and (stringp number)
                     (string-match-p emacos-sms--number-re number)))
           "error: invalid number")
          ((not (emacos-sms--valid-body-p body))
           "error: invalid message body")
          ((eq emacos-sms--state 'sending)
           "error: message send already in progress")
          ((eq emacos-sms--state 'unknown)
           "error: dismiss unknown message status before staging another message")
          (t
           (setq emacos-sms--next-proposal-id (1+ emacos-sms--next-proposal-id)
                 emacos-sms--proposal-id emacos-sms--next-proposal-id
                 emacos-sms--state 'proposed
                 emacos-sms--number number
                 emacos-sms--body body
                 emacos-sms--detail nil)
           (if (emacos-sms--show)
               "confirmation-required: confirm on phone"
             (emacos-sms--dismiss)
             "error: SMS UI unavailable")))))
    (when (string-prefix-p "error:" result)
      (message "%s" result))
    result))

(defun emacos-sms--post-command-disarm ()
  "Disarm Send after the first arming command or any unrelated command."
  (when emacos-sms--confirm-id
    (if emacos-sms--skip-next-post-command-disarm
        (setq emacos-sms--skip-next-post-command-disarm nil)
      (emacos-sms--clear-confirm t))))

(defun emacos-sms--window-buffer-changed (&rest _)
  "Disarm Send as soon as the proposal loses the phone target window."
  (when (and emacos-sms--confirm-id (not (emacos-sms--visible-p)))
    (emacos-sms--clear-confirm t)))

(defun emacos-sms--maybe-disarm (action arg)
  "Disarm unless ACTION and ARG identify the confirming Send button."
  (unless (and (eq action #'emacos-sms--send-tap) (null arg))
    (emacos-sms--clear-confirm t)))

(add-hook 'post-command-hook #'emacos-sms--post-command-disarm)
(add-hook 'window-buffer-change-functions #'emacos-sms--window-buffer-changed)
(add-hook 'emacos--confirm-disarm-functions #'emacos-sms--maybe-disarm)

(provide 'phone-sms)
;;; phone-sms.el ends here
