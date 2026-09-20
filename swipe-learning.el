;;; swipe-learning.el --- Private swipe evidence controls -*- lexical-binding: t; -*-

;; The module is intentionally not loaded until PinePhone integration installs
;; the collector and its session transport.

(require 'button)
(require 'cl-lib)
(require 'json)

(defconst emacsos-swipe-learning--buffer-name "*Swipe Learning*")
(defconst emacsos-swipe-learning--helper
  "/usr/local/share/emacsos-openrc/swipe-learning-collector.py")

(defvar emacsos-swipe-learning--operation 0)
(defvar emacsos-swipe-learning--process nil)
(defvar emacsos-swipe-learning--buffer nil)
(defvar-local emacsos-swipe-learning--erase-armed nil)
(defvar-local emacsos-swipe-learning--skip-disarm nil)

(define-derived-mode emacsos-swipe-learning-mode special-mode "Swipe-Learning"
  "Mode for inspecting and managing private swipe-learning evidence.")

(defun emacsos-swipe-learning--status-buffer ()
  "Return the live package-owned swipe-learning status buffer."
  (unless (buffer-live-p emacsos-swipe-learning--buffer)
    (setq emacsos-swipe-learning--buffer
          (generate-new-buffer emacsos-swipe-learning--buffer-name)))
  emacsos-swipe-learning--buffer)

(defun emacsos-swipe-learning--display (text)
  "Show TEXT in the package-owned swipe-learning status buffer."
  (let ((buffer (emacsos-swipe-learning--status-buffer)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert text)
        (unless (bolp) (insert "\n"))
        (goto-char (point-min))
        (emacsos-swipe-learning-mode)))
    (pop-to-buffer buffer)))

(defun emacsos-swipe-learning--finish (process _event operation success)
  "Render PROCESS result for OPERATION; call SUCCESS on valid JSON.
Ignore callbacks from an older operation."
  (when (memq (process-status process) '(exit signal))
    (let* ((buffer (process-buffer process))
           (status (process-exit-status process))
           (text (if (buffer-live-p buffer)
                     (with-current-buffer buffer (buffer-string))
                   "")))
      (when (buffer-live-p buffer)
        (kill-buffer buffer))
      (when (= operation emacsos-swipe-learning--operation)
        (setq emacsos-swipe-learning--process nil)
        (if (= status 0)
            (condition-case nil
                (let ((value (json-parse-string
                              text :object-type 'alist :array-type 'list)))
                  (if success
                      (funcall success value text)
                    (emacsos-swipe-learning--display text)))
              (error (emacsos-swipe-learning--display
                      "Swipe learning returned malformed output.")))
          (emacsos-swipe-learning--display
           (format "Swipe learning failed: %s" (string-trim text))))))))

(defun emacsos-swipe-learning--run (command progress &optional success)
  "Run fixed helper COMMAND asynchronously after displaying PROGRESS.
COMMAND is a string or a list of fixed argument strings.  On success,
call SUCCESS with the parsed JSON value and its original text."
  (if (process-live-p emacsos-swipe-learning--process)
      (emacsos-swipe-learning--display "A learning operation is already in progress.")
    (cl-incf emacsos-swipe-learning--operation)
    (let* ((operation emacsos-swipe-learning--operation)
           (output (generate-new-buffer " *swipe-learning-output*")))
      (emacsos-swipe-learning--display progress)
      (condition-case error-data
          (setq emacsos-swipe-learning--process
                (make-process
                 :name "emacsos-swipe-learning"
                 :buffer output
                 :command (cons emacsos-swipe-learning--helper
                                (if (listp command) command (list command)))
                 :noquery t
                 :connection-type 'pipe
                 :sentinel (lambda (process event)
                             (emacsos-swipe-learning--finish
                              process event operation success))))
        (error
         (kill-buffer output)
         (setq emacsos-swipe-learning--process nil)
         (emacsos-swipe-learning--display
          (format "Swipe learning could not start: %s"
                  (error-message-string error-data))))))))

;;;###autoload
(defun emacsos-swipe-learning-enable ()
  "Record opt-in for a future private swipe collector session."
  (interactive)
  (emacsos-swipe-learning--run
   "enable" "Enabling learning..."
   (lambda (_value _text)
     (let ((buffer (emacsos-swipe-learning--status-buffer)))
       (with-current-buffer buffer
         (let ((inhibit-read-only t))
           (erase-buffer)
           (insert "Armed for next UI session.\n\n")
           (insert-text-button "Restart the phone UI now"
                               'action (lambda (_button)
                                         (call-interactively
                                          #'emacsos-pinephone-restart-ui-session))
                               'follow-link t)
           (insert "\n\nSwipe traces and candidate words stay local. "
                   "Surrounding application text is not captured, and "
                   "learning does not change current suggestions.\n")
           (goto-char (point-min))
           (emacsos-swipe-learning-mode)))
       (pop-to-buffer buffer)))))

;;;###autoload
(defun emacsos-swipe-learning-disable ()
  "Disable private swipe evidence."
  (interactive)
  (emacsos-swipe-learning--run "disable" "Disabling learning..."))

;;;###autoload
(defun emacsos-swipe-learning-show (&optional page)
  "Show PAGE of bounded private swipe evidence and all outcome counts."
  (interactive "P")
  (let ((number (if page (prefix-numeric-value page) 0)))
    (when (< number 0)
      (user-error "Learning page must be nonnegative"))
    (emacsos-swipe-learning--run
     (list "--page" (number-to-string number) "show")
     "Loading learning data...")))

;;;###autoload
(defun emacsos-swipe-learning-export ()
  "Create a private deterministic swipe-evidence snapshot."
  (interactive)
  (emacsos-swipe-learning--run "export" "Exporting..."))

(defun emacsos-swipe-learning--confirm-erase (_button)
  "Erase capture data after the in-buffer second tap on _BUTTON."
  (setq emacsos-swipe-learning--erase-armed nil
        emacsos-swipe-learning--skip-disarm nil)
  (emacsos-swipe-learning--run "erase" "Erasing..."))

(defun emacsos-swipe-learning--render-erase-button ()
  "Render the first, unarmed erase action in the current buffer."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert "Erase all captured swipe-learning data?\n\n")
    (insert-text-button "Erase learning data"
                        'action #'emacsos-swipe-learning--arm-erase
                        'follow-link t)
    (insert "\n")
    (goto-char (point-min))))

(defun emacsos-swipe-learning--disarm-erase ()
  "Disarm erase and restore its first-tap action."
  (when emacsos-swipe-learning--erase-armed
    (setq emacsos-swipe-learning--erase-armed nil
          emacsos-swipe-learning--skip-disarm nil)
    (emacsos-swipe-learning--render-erase-button)))

(defun emacsos-swipe-learning--post-command-disarm ()
  "Keep the arming command, then disarm erase after another command."
  (when emacsos-swipe-learning--erase-armed
    (if emacsos-swipe-learning--skip-disarm
        (setq emacsos-swipe-learning--skip-disarm nil)
      (emacsos-swipe-learning--disarm-erase))))

(defun emacsos-swipe-learning--window-buffer-changed (&rest _)
  "Disarm erase when its buffer is no longer visible."
  (let ((buffer (and (buffer-live-p emacsos-swipe-learning--buffer)
                     emacsos-swipe-learning--buffer)))
    (when (and (buffer-live-p buffer) (not (get-buffer-window buffer t)))
      (with-current-buffer buffer
        (emacsos-swipe-learning--disarm-erase)))))

(defun emacsos-swipe-learning--arm-erase (_button)
  "Relabel the visible erase action for its required second tap."
  (let ((buffer (and (buffer-live-p emacsos-swipe-learning--buffer)
                     emacsos-swipe-learning--buffer)))
    (when buffer
      (with-current-buffer buffer
        (setq emacsos-swipe-learning--erase-armed t
              emacsos-swipe-learning--skip-disarm t)
        (let ((inhibit-read-only t))
          (erase-buffer)
          (insert "Erase all captured swipe-learning data?\n\n")
          (insert-text-button "Confirm erase"
                              'action #'emacsos-swipe-learning--confirm-erase
                              'follow-link t)
          (insert "\n")
          (goto-char (point-min)))))))

;;;###autoload
(defun emacsos-swipe-learning-erase ()
  "Check eligibility, then arm an in-buffer second tap for evidence erase."
  (interactive)
  (emacsos-swipe-learning--run
   "erase-ready" "Checking erase eligibility..."
   (lambda (_value _text)
     (let ((buffer (emacsos-swipe-learning--status-buffer)))
       (with-current-buffer buffer
         (emacsos-swipe-learning-mode)
         (setq emacsos-swipe-learning--erase-armed nil
               emacsos-swipe-learning--skip-disarm nil)
         (emacsos-swipe-learning--render-erase-button))
       (pop-to-buffer buffer)))))

(add-hook 'post-command-hook #'emacsos-swipe-learning--post-command-disarm)
(add-hook 'window-buffer-change-functions
          #'emacsos-swipe-learning--window-buffer-changed)

(provide 'swipe-learning)
;;; swipe-learning.el ends here
