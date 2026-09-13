;;; openrc-init.el --- PinePhone EmacsOS bootstrap  -*- lexical-binding: t; -*-

;; Assist-first PinePhone session with application lifecycle commands.

(require 'json)

(setq inhibit-startup-screen t
      inhibit-startup-message t
      initial-scratch-message nil
      inhibit-startup-echo-area-message "emacsos-lab"
      ring-bell-function #'ignore
      use-dialog-box nil)

(add-hook 'emacs-startup-hook (lambda () (message nil)))

(dolist (mode '(menu-bar-mode tool-bar-mode scroll-bar-mode))
  (when (fboundp mode)
    (funcall mode -1)))

(defvar emacsos-pinephone-firefox-process nil
  "Firefox process started from the PinePhone EmacsOS session.")

(defvar emacsos-pinephone-waydroid-process nil
  "Waydroid process started from the PinePhone EmacsOS session.")

(defconst emacsos-pinephone-waydroid-config "/var/lib/waydroid/waydroid.cfg"
  "File created when the Android images have been initialized.")

(defconst emacsos-pinephone-cell-connection "emacsos-cellular"
  "NetworkManager profile managed by the PinePhone network helper.")

(require 'subr-x)

(defun emacsos-pinephone-firefox-finished (process _event)
  "Report when the tracked Firefox PROCESS has finished."
  (when (and (eq process emacsos-pinephone-firefox-process)
             (memq (process-status process) '(exit signal)))
    (setq emacsos-pinephone-firefox-process nil)
    (message "Firefox is closed.")))

(defun emacsos-firefox-start ()
  "Start Firefox or focus its existing window."
  (interactive)
  (if (and emacsos-pinephone-firefox-process
           (process-live-p emacsos-pinephone-firefox-process))
      (progn
        (message "Switching to Firefox...")
        (if (let ((status
                   (call-process "/usr/bin/timeout" nil nil nil
                                 "-s" "TERM" "-k" "1" "3"
                                 "/usr/bin/swaymsg" "-s" (getenv "SWAYSOCK")
                                 "[app_id=\"firefox\"] focus")))
              (and (integerp status) (zerop status)))
            (message "Firefox is open.")
          (message "Firefox window is not ready.")))
    (message "Starting Firefox...")
    (setq emacsos-pinephone-firefox-process
          (condition-case nil
              (start-process "emacsos-firefox" nil "/usr/bin/firefox"
                             "--new-instance" "about:blank")
            (file-error nil)))
    (if emacsos-pinephone-firefox-process
        (progn
          (set-process-query-on-exit-flag emacsos-pinephone-firefox-process nil)
          (set-process-sentinel emacsos-pinephone-firefox-process
                                #'emacsos-pinephone-firefox-finished))
      (message "Firefox could not start."))))

(defun emacsos-firefox-quit ()
  "Quit the Firefox process started by this Emacs session."
  (interactive)
  (if (and emacsos-pinephone-firefox-process
           (process-live-p emacsos-pinephone-firefox-process))
      (condition-case nil
          (progn
            (signal-process emacsos-pinephone-firefox-process 'SIGTERM)
            (message "Closing Firefox..."))
        (error
         (setq emacsos-pinephone-firefox-process nil)
         (message "Firefox is not open.")))
    (message "Firefox is not open.")))

(defun emacsos-pinephone-waydroid-finished (process _event)
  "Show the result when the tracked Waydroid PROCESS finishes."
  (when (and (eq process emacsos-pinephone-waydroid-process)
             (memq (process-status process) '(exit signal)))
    (setq emacsos-pinephone-waydroid-process nil)
    (if (zerop (process-exit-status process))
        (message "Android is stopped.")
      (message "Android failed to start. Check /var/lib/waydroid/waydroid.log."))))

(defun emacsos-pinephone-waydroid-stop-finished (process _event)
  "Report when the Waydroid stop PROCESS finishes."
  (when (memq (process-status process) '(exit signal))
    (if (zerop (process-exit-status process))
        (message "Android is stopped.")
      (message "Android did not stop cleanly."))))

(defun emacsos-android-start ()
  "Start Waydroid or focus its existing full-screen window."
  (interactive)
  (cond
   ((not (file-exists-p emacsos-pinephone-waydroid-config))
    (message "Android images are not installed."))
   ((and emacsos-pinephone-waydroid-process
         (process-live-p emacsos-pinephone-waydroid-process))
    (message "Switching to Android...")
    (if (let ((status
               (call-process "/usr/bin/timeout" nil nil nil
                             "-s" "TERM" "-k" "1" "3"
                             "/usr/bin/swaymsg" "-s" (getenv "SWAYSOCK")
                             "[app_id=\"Waydroid\"] focus")))
          (and (integerp status) (zerop status)))
        (message "Android is open.")
      (message "Android window is not ready.")))
   (t
    (message "Starting Android. The first start can take two minutes...")
    (setq emacsos-pinephone-waydroid-process
          (condition-case nil
              (start-process "emacsos-waydroid" nil "/usr/bin/waydroid"
                             "show-full-ui")
            (file-error nil)))
    (if emacsos-pinephone-waydroid-process
        (progn
          (set-process-query-on-exit-flag emacsos-pinephone-waydroid-process nil)
          (set-process-sentinel emacsos-pinephone-waydroid-process
                                #'emacsos-pinephone-waydroid-finished))
      (message "Android could not start.")))))

(defun emacsos-android-quit ()
  "Stop the Waydroid session and its Android container."
  (interactive)
  (message "Stopping Android...")
  (let ((process (start-process "emacsos-waydroid-stop" nil
                                "/usr/bin/waydroid" "session" "stop")))
    (set-process-query-on-exit-flag process nil)
    (set-process-sentinel process
                          #'emacsos-pinephone-waydroid-stop-finished)))

(defun emacsos-pinephone-record-synthetic-input ()
  "Insert the fixed marker used by the automated input smoke."
  (interactive)
  (goto-char (point-max))
  (insert "[synthetic-input]\n"))

(global-set-key [f12] #'emacsos-pinephone-record-synthetic-input)
(global-set-key [WakeUp] #'ignore)

(add-to-list 'default-frame-alist '(fullscreen . maximized))
(add-to-list 'default-frame-alist '(font . "Monospace-14"))

(defun emacsos-pinephone-enforce-frame-layout ()
  "Keep the Emacs frame inside the space reserved above wvkbd.
Agent config is shared with devices that legitimately use `fullboth'.  On the
PinePhone that frame state hides Emacs content behind the external layer-shell
keyboard, so the platform restores its maximized layout after
every agent-config load."
  (set-frame-parameter nil 'fullscreen 'maximized))

(defvar emacsos-agent-config-applied-function
  (symbol-function 'emacsos-pinephone-enforce-frame-layout)
  "Platform function run after each persistent agent-config load attempt.")

(defun emacsos-pinephone-load-agent-config (file)
  "Attempt to load agent config FILE, then restore the PinePhone layout."
  (let ((finalizer emacsos-agent-config-applied-function))
    (unwind-protect
        (when (file-readable-p file)
          (condition-case err
              (load file nil 'nomessage)
            (t (message "emacsos: saved agent config failed: %s"
                        (error-message-string err)))))
      (condition-case err
          (funcall finalizer)
        (t (message "emacsos: platform config finalizer failed: %s"
                    (error-message-string err))))
      (condition-case err
          (setq emacsos-agent-config-applied-function finalizer)
        (t (message "emacsos: platform finalizer restore failed: %s"
                    (error-message-string err)))))))

(defvar emacsos-call--call-owner nil
  "Unique owner of the tracked call or pathless recovery state.")

(defun emacsos-pinephone-sms-result (status success)
  "Return the strict terminal SMS STATUS, or conservative unknown."
  (cond
   ((and success (string= status "sent")) "sent")
   ((and (not success)
         (string-match-p
          "\\`not-sent:\\(?:input-timeout\\|invalid-input\\|busy\\|no-modem\\|multiple-modems\\|no-service\\|dbus-unavailable\\|time-limit\\)\\'"
          status))
    status)
   ((and (not success)
         (string-match-p
          "\\`unknown:\\(?:create-failed\\|send-failed\\|time-limit\\|dbus-unavailable\\)\\'"
          status))
    status)
   (t "unknown:dbus-unavailable")))

(defun emacsos-pinephone-sms-finished
    (process _event completion stderr-buffer)
  "Report terminal SMS PROCESS status through COMPLETION and clean buffers."
  (when (memq (process-status process) '(exit signal))
    (let* ((buffer (process-buffer process))
           (raw-status (if (buffer-live-p buffer)
                           (with-current-buffer buffer (buffer-string))
                         ""))
           (status (if (string-match "\\`\\([^\n]*\\)\n\\'" raw-status)
                       (match-string 1 raw-status)
                     ""))
           (result (emacsos-pinephone-sms-result
                    status (zerop (process-exit-status process)))))
      (unwind-protect
          (condition-case err
              (funcall completion result)
            (error
             (message "emacsos-sms: completion failed: %s"
                      (error-message-string err))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (when (buffer-live-p stderr-buffer) (kill-buffer stderr-buffer))))))

(defun emacsos-pinephone-sms-operation (number body completion)
  "Send NUMBER and BODY to the fixed root helper through bounded stdin."
  (let ((buffer (generate-new-buffer " *emacsos-sms*"))
        (stderr-buffer (generate-new-buffer " *emacsos-sms-stderr*"))
        process)
    (condition-case nil
        (progn
          (setq process
                (make-process
                 :name "emacsos-sms"
                 :buffer buffer
                 :stderr stderr-buffer
                 :command '("/usr/bin/doas" "-n"
                            "/usr/local/sbin/emacsos-openrc-sms")
                 :connection-type 'pipe
                 :coding 'utf-8-unix
                 :noquery t
                 :sentinel (lambda (proc event)
                             (emacsos-pinephone-sms-finished
                              proc event completion stderr-buffer))))
          (process-send-string
           process
           (json-encode `((number . ,number) (text . ,body))))
          (process-send-eof process)
          "pending: SMS requested")
      (error
       (when (process-live-p process) (delete-process process))
       (when (buffer-live-p buffer) (kill-buffer buffer))
       (when (buffer-live-p stderr-buffer) (kill-buffer stderr-buffer))
       "unknown:dbus-unavailable"))))

(defun emacsos-pinephone-call-result (operation status success)
  "Normalize helper STATUS, preserving uncertain dial and answer identity."
  (let ((lines (split-string status "\n" t "[ \t\r]+"))
        created answering terminal)
    (dolist (line lines)
      (when (string-match
             "\\`created-call-path: \\(/org/freedesktop/ModemManager1/Call/[0-9]+\\)\\'"
             line)
        (setq created (match-string 1 line)))
      (when (string-match
             "\\`answering-call-path: \\(/org/freedesktop/ModemManager1/Call/[0-9]+\\)\\'"
             line)
        (setq answering (match-string 1 line)))
      (when (pcase operation
              ('dial
               (or (string-match-p
                    "\\`dialing: /org/freedesktop/ModemManager1/Call/[0-9]+\\'"
                    line)
                   (string-prefix-p "error:" line)))
              ('answer (or (string-prefix-p "answered:" line)
                           (string-prefix-p "error:" line)))
              ('hangup (or (string-prefix-p "hung-up:" line)
                           (string-prefix-p "error:" line))))
        (setq terminal line)))
    (cond
     ((and terminal
           (eq operation 'dial)
           created
           (string-prefix-p "error:" terminal)
           (not (string-match-p
                 "\\`error: \\(uncertain-\\)?call-path=/org/freedesktop/ModemManager1/Call/[0-9]+;"
                 terminal)))
      (format "error: uncertain-call-path=%s; %s"
              created
              (string-trim (substring terminal (length "error:")))))
     (terminal terminal)
     ((and (eq operation 'dial) created)
      (format (concat "error: uncertain-call-path=%s; "
                      "dial helper terminated before final status")
              created))
     ((and (eq operation 'answer) answering)
      (format (concat "error: uncertain-answer-call-path=%s; "
                      "answer helper terminated before final status")
              answering))
     ((and success (eq operation 'dial))
      "error: uncertain-call; dial helper completed without call identity")
     ((and success (eq operation 'answer)) "answered: call active")
     ((and success (eq operation 'hangup)) "hung-up: call ended")
     ((eq operation 'answer)
      "error: uncertain-answer; answer helper failed without final status")
     (success (format "%s completed" operation))
     ((string-empty-p status) (format "error: %s helper failed" operation))
     (t
      (let ((detail (replace-regexp-in-string
                     "[\r\n\t ]+" " " (string-trim status))))
        (concat "error: "
                (if (string-empty-p detail)
                    (format "%s helper failed" operation)
                  (truncate-string-to-width detail 4096 nil nil "…"))))))))

(defun emacsos-pinephone-call-finished
    (process _event operation completion)
  "Report terminal PROCESS status through COMPLETION or a user message."
  (when (memq (process-status process) '(exit signal))
    (let* ((buffer (process-buffer process))
           (status (if (buffer-live-p buffer)
                       (with-current-buffer buffer (string-trim (buffer-string)))
                     ""))
           (success (zerop (process-exit-status process)))
           (result (emacsos-pinephone-call-result operation status success)))
      (unwind-protect
          (if completion
              (condition-case err
                  (funcall completion result)
                (error
                 (message "emacsos-call: completion failed: %s"
                          (error-message-string err))))
            (if success
                (message "%s" result)
              (when (memq operation '(dial answer))
                (emacsos-call--audio nil))
              (when (eq operation 'answer)
                (emacsos-call--dismiss))
              (message "emacsos-call: %s" result)))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(defun emacsos-pinephone-call-operation
    (operation owner value &optional completion)
  "Start call OPERATION for OWNER and VALUE; report via COMPLETION or messages."
  (let* ((buffer (generate-new-buffer " *emacsos-call*"))
         (args (append (list "-n" "/usr/local/sbin/emacsos-openrc-call"
                             (symbol-name operation))
                       (and owner (list owner))
                       (and value (list value)))))
    (condition-case err
        (if (and (or (memq operation '(dial answer))
                     (and (eq operation 'hangup) value))
                 (not owner))
            (progn
              (kill-buffer buffer)
              "error: ModemManager owner unavailable")
          (progn
          (make-process
           :name (format "emacsos-call-%s" operation)
           :buffer buffer
           :command (cons "/usr/bin/doas" args)
           :noquery t
           :sentinel (lambda (proc event)
                       (emacsos-pinephone-call-finished
                        proc event operation completion)))
          (pcase operation
            ('dial "pending: dial requested")
            ('answer "pending: answer requested")
            ('hangup "pending: hangup requested")
            (_ "error: unsupported call operation"))))
      (error
       (when (buffer-live-p buffer) (kill-buffer buffer))
       (format "error: call helper failed: %s" (error-message-string err))))))

(defvar emacsos-pinephone-call-audio-process nil
  "The one serialized callaudiocli process, including pending sentinel work.")
(defvar emacsos-pinephone-call-audio-desired nil
  "Latest requested call-audio state while a transition is running.")

(defun emacsos-pinephone-call-audio-finished (process _event requested)
  "Finish serialized audio PROCESS for REQUESTED and apply the latest state."
  (when (memq (process-status process) '(exit signal))
    (let ((buffer (process-buffer process)))
      (unwind-protect
          (unless (zerop (process-exit-status process))
            (message "emacsos-call: audio routing failed: %s"
                     (if (buffer-live-p buffer)
                         (with-current-buffer buffer
                           (string-trim (buffer-string)))
                       "no diagnostic output")))
        (when (buffer-live-p buffer) (kill-buffer buffer))))
    (when (eq process emacsos-pinephone-call-audio-process)
      (setq emacsos-pinephone-call-audio-process nil)
      (unless (eq requested emacsos-pinephone-call-audio-desired)
        (emacsos-pinephone-call-audio-start
         emacsos-pinephone-call-audio-desired)))))

(defun emacsos-pinephone-call-audio-start (active)
  "Start the one asynchronous audio transition to ACTIVE."
  (let ((buffer (generate-new-buffer " *emacsos-call-audio*")))
    (condition-case err
        (setq emacsos-pinephone-call-audio-process
              (make-process
               :name "emacsos-call-audio"
               :buffer buffer
               :command (list "/usr/bin/timeout" "-s" "TERM" "-k" "1" "5"
                              "/usr/bin/callaudiocli" "-m"
                              (if active "1" "0"))
               :noquery t
               :sentinel (lambda (process event)
                           (emacsos-pinephone-call-audio-finished
                            process event active))))
      (error
       (when (buffer-live-p buffer) (kill-buffer buffer))
       (signal (car err) (cdr err))))))

(defun emacsos-pinephone-call-audio (active)
  "Select call audio when ACTIVE, serializing and coalescing transitions."
  (setq emacsos-pinephone-call-audio-desired (and active t))
  (unless emacsos-pinephone-call-audio-process
    (emacsos-pinephone-call-audio-start
     emacsos-pinephone-call-audio-desired)))

(defvar emacsos-pinephone-wake-process nil
  "The one outstanding fixed display-wake helper, if any.")

(defun emacsos-pinephone-wake-display ()
  "Wake the display and re-arm idle blanking without blocking ModemManager."
  (unless (process-live-p emacsos-pinephone-wake-process)
    (let ((process
           (start-process "emacsos-call-wake" nil
                          "/usr/local/share/emacsos-openrc/session-power" "wake")))
      (setq emacsos-pinephone-wake-process process)
      (set-process-query-on-exit-flag process nil)
      (set-process-sentinel
       process
       (lambda (finished _event)
         (when (and (eq finished emacsos-pinephone-wake-process)
                    (memq (process-status finished) '(exit signal)))
           (setq emacsos-pinephone-wake-process nil)))))))

(defun emacsos-pinephone-network-command (arguments)
  "Translate NetworkManager ARGUMENTS into the fixed root-helper command."
  (let ((prefix '("/usr/bin/doas" "-n"
                  "/usr/local/sbin/emacsos-openrc-network")))
    (pcase arguments
      (`("radio" "wifi" ,state)
       (unless (member state '("on" "off"))
         (error "invalid Wi-Fi state"))
       (append prefix (list "wifi" state)))
      (`("con" ,state ,name)
       (cond
        ((and (member state '("up" "down"))
              (string= name emacsos-pinephone-cell-connection))
         (append prefix (list "cell" state)))
        ((string= state "up") (append prefix (list "saved" name)))
        (t (error "unsupported connection action"))))
      (`("dev" "wifi" "connect" ,ssid)
       (append prefix (list "open" ssid)))
      (_ (error "unsupported network action")))))

(defvar emacsos-pinephone-keyboard-hidden nil
  "Non-nil after this Emacs instance has hidden wvkbd.")

(defvar emacsos-pinephone-wvkbd-pid
  (let ((pid (getenv "EMACSOS_WVKBD_PID")))
    (and pid (string-match-p "\\`[1-9][0-9]*\\'" pid) pid))
  "Current session's directly supervised wvkbd process ID, or nil.")

(defun emacsos-pinephone-valid-wvkbd-pid-p (pid)
  "Return non-nil when PID is the expected isolated keyboard process."
  (let* ((default-directory "/")
         (attributes (and pid (process-attributes (string-to-number pid)))))
    (and (equal (alist-get 'comm attributes) "wvkbd-emacsos")
         (equal (alist-get 'user attributes) "emacsos-lab"))))

(defun emacsos-pinephone-find-wvkbd-pid ()
  "Return the one exact supervised wvkbd PID, or nil."
  (let ((default-directory "/"))
    (with-temp-buffer
      (when (zerop (call-process "/usr/bin/pgrep" nil t nil
                                "-u" "emacsos-lab" "-f"
                                "^/usr/local/bin/wvkbd-emacsos --mod-swipe -H 300 -L 300$"))
        (let ((pids (split-string (buffer-string) "\n" t)))
          (and (= (length pids) 1) (car pids)))))))

(defun emacsos-pinephone-signal-keyboard (signal)
  "Send SIGNAL to this session's supervised wvkbd process.
Refresh a missing or stale PID only from one exact isolated keyboard process."
  (let ((pid emacsos-pinephone-wvkbd-pid))
    (unless (emacsos-pinephone-valid-wvkbd-pid-p pid)
      (setq pid (emacsos-pinephone-find-wvkbd-pid))
      (unless (emacsos-pinephone-valid-wvkbd-pid-p pid)
        (user-error "Keyboard control is unavailable"))
      (setq emacsos-pinephone-wvkbd-pid pid))
    (signal-process (string-to-number pid) signal)))

(defun emacsos-pinephone-toggle-keyboard ()
  "Hide the compositor keyboard, or show it again when it is hidden."
  (interactive)
  (if emacsos-pinephone-keyboard-hidden
      (progn
        (emacsos-pinephone-signal-keyboard 'SIGUSR2)
        (setq emacsos-pinephone-keyboard-hidden nil))
    (emacsos-pinephone-signal-keyboard 'SIGUSR1)
    (setq emacsos-pinephone-keyboard-hidden t))
  (force-mode-line-update t))

(defconst emacsos-pinephone-keyboard-mode-line-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] #'emacsos-pinephone-toggle-keyboard)
    map)
  "Keymap for the visible PinePhone keyboard control.")

(defun emacsos-pinephone-keyboard-mode-line-string ()
  "Return the touch control for the compositor keyboard in the modeline."
  (propertize (if emacsos-pinephone-keyboard-hidden "  kbd show" "  kbd hide")
              'local-map emacsos-pinephone-keyboard-mode-line-map
              'mouse-face 'mode-line-highlight
              'help-echo "Tap to hide or show the keyboard"))

(setq emacsos-platform-mode-line-segments
      '((:eval (emacsos-pinephone-keyboard-mode-line-string))))

(when (display-graphic-p)
  (add-to-list 'load-path "/usr/local/share/emacsos-openrc")
  (setq emacsos-use-internal-keyboard nil
        emacsos-control-window-percent 35
        emacsos-initial-buffer-function #'emacsos--chat-buffer
        emacsos-net-cell-connection emacsos-pinephone-cell-connection
        emacsos-net-command-function #'emacsos-pinephone-network-command
        emacsos-chat-auth-file
        "/var/lib/emacsos-lab/.emacs.d/server/emacsos-openrc"
        emacsos-call-operation-function #'emacsos-pinephone-call-operation
        emacsos-call-audio-function #'emacsos-pinephone-call-audio
        emacsos-call-wake-function #'emacsos-pinephone-wake-display
        emacsos-sms-operation-function #'emacsos-pinephone-sms-operation
        emacsos-call-control-gap-lines 1)
  (let ((url-file "/etc/emacsos-openrc/chat-url"))
    (setq emacsos-chat-server-url
          (if (file-readable-p url-file)
              (with-temp-buffer
                (insert-file-contents url-file)
                (string-trim (buffer-string)))
            "http://localhost:8765/chat")))
  (let ((url-file "/etc/emacsos-openrc/assist-web-url"))
    (setq emacsos-assist-web-api-url
          (if (file-readable-p url-file)
              (with-temp-buffer
                (insert-file-contents url-file)
                (string-trim (buffer-string)))
            "https://assist.invalid/api/v1/phone")))
  (setq emacsos-assist-web-ca-file "/etc/emacsos-openrc/assist-web-ca.pem")
  (defvar emacsos-agent-file "/var/lib/emacsos-lab/.emacs.d/emacsos/agent.el"
    "Persistent agent configuration applied by Assist.")
  (require 'server)
  (setq server-use-tcp t
        server-host "0.0.0.0"
        server-port 8766
        server-name "emacsos-openrc")
  (server-start)
  (set-face-attribute 'default nil :height 140)
  (require 'os)
  (define-key emacsos-command-map (kbd "k") #'emacsos-pinephone-toggle-keyboard)
  (define-key emacsos-command-map (kbd "b") #'emacsos-firefox-start)
  (define-key emacsos-command-map (kbd "a") #'emacsos-android-start)
  (load "/usr/local/share/emacsos-openrc/dtach-shell-init.el" nil nil t)
  (emacsos-pinephone-load-agent-config emacsos-agent-file))

(provide 'emacsos-pinephone-openrc-init)
;;; openrc-init.el ends here
