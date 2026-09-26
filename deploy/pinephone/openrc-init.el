;;; openrc-init.el --- PinePhone EmacsOS bootstrap  -*- lexical-binding: t; -*-

;; Assist-first PinePhone session with application lifecycle commands.

(require 'cl-lib)
(require 'json)

;; -Q skips Alpine's site startup.  Expose only the distro Magit/dependency
;; directories, without loading site startup, user init or package autoloads.
(dolist (directory '("/usr/share/emacs/site-lisp"
                     "/usr/share/emacs/site-lisp/compat"
                     "/usr/share/emacs/site-lisp/magit"))
  (add-to-list 'load-path directory))

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
       (if (and (member state '("up" "down"))
                (string= name emacsos-pinephone-cell-connection))
           (append prefix (list "cell" state))
         (error "unsupported connection action")))
      (_ (error "unsupported network action")))))

(defun emacsos-pinephone-wifi-result (status success)
  "Return the strict terminal Wi-Fi STATUS, or conservative failure."
  (if (and (string-match "\\`\\([^\n]*\\)\n\\'" status)
           (member (match-string 1 status)
                   '("connected"
                     "not-connected:invalid-input"
                     "not-connected:busy"
                     "not-connected:failed"
                     "not-connected:unavailable"
                     "unknown:time-limit")))
      (let ((result (match-string 1 status)))
        (if (eq success (string= result "connected"))
            result
          "not-connected:failed"))
    "not-connected:failed"))

(defun emacsos-pinephone-wifi-finished
    (process _event completion stderr-buffer)
  "Report terminal Wi-Fi PROCESS status through COMPLETION and clean buffers."
  (when (memq (process-status process) '(exit signal))
    (let* ((buffer (process-buffer process))
           (status (if (buffer-live-p buffer)
                       (with-current-buffer buffer (buffer-string))
                     ""))
           (result (emacsos-pinephone-wifi-result
                    status (zerop (process-exit-status process)))))
      (unwind-protect
          (condition-case err
              (funcall completion result)
            (error
             (message "emacsos-net: completion failed: %s"
                      (error-message-string err))))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (when (buffer-live-p stderr-buffer) (kill-buffer stderr-buffer))))))

(defun emacsos-pinephone-wifi-operation (kind target password completion)
  "Connect KIND and TARGET, sending PASSWORD only to the credential helper."
  (let ((buffer (generate-new-buffer " *emacsos-wifi*"))
        (stderr-buffer (generate-new-buffer " *emacsos-wifi-stderr*"))
        process command request sentinel finished)
    (pcase kind
      ('saved
       (setq command (list "/usr/bin/doas" "-n"
                           "/usr/local/sbin/emacsos-openrc-network"
                           "saved" target)))
      ('open
       (setq command (list "/usr/bin/doas" "-n"
                           "/usr/local/sbin/emacsos-openrc-network"
                           "open" target)))
      ('secured
       (setq command '("/usr/bin/doas" "-n"
                       "/usr/local/sbin/emacsos-openrc-wifi-connect")
             request (json-encode `((ssid . ,target)
                                    (password . ,password)))))
      (_
       (kill-buffer buffer)
       (kill-buffer stderr-buffer)
       (setq command nil)))
    (if (null command)
        "not-connected:invalid-input"
      (setq sentinel
            (lambda (proc event)
              (when (and (not finished)
                         (memq (process-status proc) '(exit signal)))
                (setq finished t)
                (accept-process-output proc 0)
                (emacsos-pinephone-wifi-finished
                 proc event completion stderr-buffer))))
      (unwind-protect
          (condition-case nil
              (progn
                (setq process
                      (make-process
                       :name "emacsos-wifi"
                       :buffer buffer
                       :stderr stderr-buffer
                       :command command
                       :connection-type 'pipe
                       :coding 'utf-8-unix
                       :noquery t
                       :sentinel #'ignore))
                (let ((write-failed
                       (condition-case nil
                           (progn
                             (when request
                               (process-send-string process request))
                             (process-send-eof process)
                             nil)
                         (error t))))
                  (set-process-sentinel process sentinel)
                  (when (memq (process-status process) '(exit signal))
                    (run-at-time 0 nil sentinel process "finished"))
                  (when (and write-failed (process-live-p process))
                    (delete-process process)))
                "pending: Wi-Fi connection requested")
            (error
             (when (process-live-p process) (delete-process process))
             (when (buffer-live-p buffer) (kill-buffer buffer))
             (when (buffer-live-p stderr-buffer) (kill-buffer stderr-buffer))
             "not-connected:unavailable"))
        (when request (clear-string request))))))

(defvar emacsos-pinephone-keyboard-hidden nil
  "Non-nil after this Emacs instance has hidden wvkbd.")

(defvar emacsos-pinephone-wvkbd-pid
  (let ((pid (getenv "EMACSOS_WVKBD_PID")))
    (and pid (string-match-p "\\`[1-9][0-9]*\\'" pid) pid))
  "Current session's directly supervised wvkbd process ID, or nil.")

(defun emacsos-pinephone-valid-wvkbd-pid-p (pid)
  "Return non-nil when PID is the expected isolated keyboard process."
  (let* ((default-directory "/")
         (numeric (and pid (string-match-p "\\`[1-9][0-9]*\\'" pid)
                       (string-to-number pid)))
         (attributes (and numeric (process-attributes numeric)))
         (root (and numeric (format "/proc/%d" numeric))))
    (and (equal (alist-get 'comm attributes) "wvkbd-emacsos")
         (equal (alist-get 'user attributes) "emacsos-lab")
         (equal (file-symlink-p (concat root "/exe"))
                "/usr/local/bin/wvkbd-emacsos")
         (condition-case nil
             (with-temp-buffer
               (insert-file-contents-literally (concat root "/cmdline"))
               (member (buffer-string)
                       (list
                        (concat "/usr/local/bin/wvkbd-emacsos\0"
                                "--mod-swipe\0" "-H\0" "300\0"
                                "-L\0" "300\0")
                        (concat "/usr/local/bin/wvkbd-emacsos\0"
                                "--mod-swipe\0" "-H\0" "300\0"
                                "-L\0" "300\0"
                                "--glide-learning-fd\0" "3\0"))))
           (file-error nil)))))

(defun emacsos-pinephone-find-wvkbd-pid ()
  "Return the one exact supervised wvkbd PID, or nil."
  (let ((default-directory "/"))
    (with-temp-buffer
      (when (zerop (call-process "/usr/bin/pgrep" nil t nil
                                "-u" "emacsos-lab" "-f"
                                "^/usr/local/bin/wvkbd-emacsos --mod-swipe -H 300 -L 300( --glide-learning-fd 3)?$"))
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

(defun emacsos-pinephone--ui-session-parent-p (pid)
  "Return non-nil when PID is this user's exact OpenRC UI session shell."
  (let* ((default-directory "/")
         (attributes (and (integerp pid) (process-attributes pid)))
         (cmdline (and attributes (format "/proc/%d/cmdline" pid))))
    (and (equal (alist-get 'user attributes) "emacsos-lab")
         (condition-case nil
             (with-temp-buffer
               (insert-file-contents-literally cmdline)
               (equal (buffer-string)
                      (concat "/bin/sh\0"
                              "/usr/local/share/emacsos-openrc/session\0")))
           (file-error nil)))))

;;;###autoload
(defun emacsos-pinephone-restart-ui-session ()
  "Restart the supervised phone UI after refusing unsaved file buffers."
  (interactive)
  (when (cl-some (lambda (buffer)
                   (with-current-buffer buffer
                     (and buffer-file-name (buffer-modified-p))))
                 (buffer-list))
    (user-error "Save or discard modified file buffers before restarting the UI"))
  (let* ((attributes (process-attributes (emacs-pid)))
         (parent (alist-get 'ppid attributes)))
    (unless (emacsos-pinephone--ui-session-parent-p parent)
      (user-error "The supervised UI session is unavailable"))
    (message "Restarting the phone UI; transient buffers will close...")
    (signal-process parent 'SIGTERM)))

(defun emacsos-pinephone-toggle-keyboard ()
  "Hide the compositor keyboard, or show it again when it is hidden."
  (interactive)
  (if emacsos-pinephone-keyboard-hidden
      (progn
        (emacsos-pinephone-signal-keyboard 'SIGUSR2)
        (setq emacsos-pinephone-keyboard-hidden nil))
    (emacsos-pinephone-signal-keyboard 'SIGUSR1)
    (setq emacsos-pinephone-keyboard-hidden t))
  (force-mode-line-update t)
  (when (fboundp 'emacsos-pinephone-controls--render-if-shown)
    (emacsos-pinephone-controls--render-if-shown)))

(defconst emacsos-pinephone-controls-buffer-name "*controls*"
  "PinePhone device-controls buffer.")

(defvar emacsos-pinephone-controls-parent-buffer nil
  "Content buffer restored by the Controls Done action.")

(defvar emacsos-pinephone-controls-active nil
  "Non-nil after Controls opens and until its Done action runs.")

(defvar emacsos-pinephone-controls-brightness nil
  "Last verified brightness percentage, or nil before a valid snapshot.")

(defvar emacsos-pinephone-controls-flashlight nil
  "Last verified flashlight state, `on', `off', or nil.")

(defvar emacsos-pinephone-controls-device-error nil
  "Bounded aggregate device-helper failure detail, or nil.")

(defvar emacsos-pinephone-controls-device-operation nil
  "Current device operation plist, or nil.")

(defun emacsos-pinephone-controls--bounded (text &optional width)
  "Return TEXT as one line clipped to WIDTH display columns."
  (let ((width (or width 48)))
    (if (zerop width)
        ""
      (truncate-string-to-width
       (replace-regexp-in-string "[\n\r\t]+" " " (or text ""))
       width nil nil "…"))))

(defun emacsos-pinephone-controls--unavailable (detail)
  "Return the explicit unavailable status for DETAIL."
  (concat "Unavailable: " detail))

(defun emacsos-pinephone-controls--shown-p ()
  "Return non-nil when the controls buffer is the top content buffer."
  (let* ((window (and (fboundp 'emacsos--target) (emacsos--target)))
         (buffer (and window (window-buffer window))))
    (and buffer (eq buffer (get-buffer emacsos-pinephone-controls-buffer-name)))))

(defun emacsos-pinephone-controls--render-if-shown ()
  "Repaint Controls when it is the visible content buffer."
  (when (emacsos-pinephone-controls--shown-p)
    (emacsos-pinephone-controls--render)))

(add-hook 'emacsos-net-state-change-functions
          #'emacsos-pinephone-controls--render-if-shown)

(defun emacsos-pinephone-controls--parse-snapshot (text)
  "Parse strict device-helper snapshot TEXT, returning (BRIGHTNESS . TORCH)."
  (when (string-match
         "\\`brightness:\\(25\\|50\\|75\\|100\\)\nflashlight:\\(on\\|off\\)\n?\\'"
         text)
    (cons (string-to-number (match-string 1 text))
          (intern (match-string 2 text)))))

(defun emacsos-pinephone-controls--device-command (arguments)
  "Return the fixed privileged helper command for ARGUMENTS."
  (append '("/usr/bin/doas" "-n"
            "/usr/local/sbin/emacsos-openrc-device")
          arguments))

(defun emacsos-pinephone-controls--set-device-error (detail)
  "Invalidate both device rows and record bounded failure DETAIL."
  (setq emacsos-pinephone-controls-brightness nil
        emacsos-pinephone-controls-flashlight nil
        emacsos-pinephone-controls-device-error
        (emacsos-pinephone-controls--bounded detail)))

(defun emacsos-pinephone-controls--device-finished (process)
  "Consume terminal PROCESS, ignoring stale completion."
  (when (memq (process-status process) '(exit signal))
    (let ((buffer (process-buffer process)))
      (unwind-protect
          (let ((operation emacsos-pinephone-controls-device-operation))
            (when (and operation
                       (eq process (plist-get operation :process)))
              (when (timerp (plist-get operation :timer))
                (cancel-timer (plist-get operation :timer)))
              (let* ((timed-out-detail
                      (and (plist-get operation :timed-out)
                           "device control timed out"))
                     (output (if (buffer-live-p buffer)
                                 (with-current-buffer buffer (buffer-string))
                               ""))
                     (snapshot (and (eq (process-status process) 'exit)
                                    (zerop (process-exit-status process))
                                    (emacsos-pinephone-controls--parse-snapshot
                                     output))))
                (setq emacsos-pinephone-controls-device-operation nil)
                (if snapshot
                    (setq emacsos-pinephone-controls-brightness (car snapshot)
                          emacsos-pinephone-controls-flashlight (cdr snapshot)
                          emacsos-pinephone-controls-device-error nil)
                  (emacsos-pinephone-controls--set-device-error
                   (or timed-out-detail
                       (and (not (string-empty-p output)) output)
                       (format "device helper exited %s"
                               (process-exit-status process)))))
                (emacsos-pinephone-controls--render-if-shown))))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(defun emacsos-pinephone-controls--device-timeout (process)
  "Make a still-live PROCESS visibly non-retryable."
  (let ((operation emacsos-pinephone-controls-device-operation))
    (when (and operation
               (eq process (plist-get operation :process))
               (process-live-p process))
      (when (buffer-live-p (process-buffer process))
        (let ((buffer (process-buffer process)))
          (set-process-buffer process nil)
          (kill-buffer buffer)))
      (setq emacsos-pinephone-controls-device-operation
            (plist-put operation :timed-out t))
      (emacsos-pinephone-controls--set-device-error
       "device control timed out")
      (emacsos-pinephone-controls--render-if-shown))))

(defun emacsos-pinephone-controls--start-device (row arguments)
  "Start one fixed device helper operation for ROW with ARGUMENTS."
  (if (and emacsos-pinephone-controls-device-operation
           (process-live-p
            (plist-get emacsos-pinephone-controls-device-operation :process)))
      "error: another device operation is still running"
    (let ((buffer (generate-new-buffer " *emacsos-device-control*"))
          process timer)
      (setq emacsos-pinephone-controls-device-error nil)
      (condition-case err
          (progn
            (setq process
                  (make-process
                   :name "emacsos-device-control"
                   :buffer buffer
                   :command (emacsos-pinephone-controls--device-command arguments)
                   :noquery t
                   :sentinel
                   (lambda (finished _event)
                     (emacsos-pinephone-controls--device-finished finished))))
            (setq timer
                  (run-with-timer
                   7 nil #'emacsos-pinephone-controls--device-timeout
                   process)
                  emacsos-pinephone-controls-device-operation
                  (list :process process :timer timer :row row
                        :arguments arguments))
            (emacsos-pinephone-controls--render-if-shown)
            (format "pending: %s" (string-join arguments " ")))
        (error
         (when (buffer-live-p buffer) (kill-buffer buffer))
         (let ((detail (error-message-string err)))
           (setq emacsos-pinephone-controls-device-operation nil)
           (emacsos-pinephone-controls--set-device-error detail)
           (emacsos-pinephone-controls--render-if-shown)
           (concat "error: " detail)))))))

(defun emacsos-pinephone-controls--refresh-device ()
  "Refresh brightness and flashlight from one asynchronous snapshot."
  (interactive)
  (emacsos-pinephone-controls--start-device 'status '("status")))

(defun emacsos-controls-set-brightness (percent)
  "Set PinePhone display brightness to fixed PERCENT asynchronously."
  (interactive
   (list (string-to-number
          (completing-read "Brightness: " '("25" "50" "75" "100") nil t))))
  (unless (memq percent '(25 50 75 100))
    (user-error "Brightness must be 25, 50, 75, or 100"))
  (emacsos-pinephone-controls--start-device
   'brightness (list "brightness" (number-to-string percent))))

(defun emacsos-controls-set-flashlight (state)
  "Set PinePhone flashlight to explicit STATE, `on' or `off'."
  (interactive
   (list (intern (completing-read "Flashlight: " '("on" "off") nil t))))
  (unless (memq state '(on off))
    (user-error "Flashlight state must be on or off"))
  (emacsos-pinephone-controls--start-device
   'flashlight (list "flashlight" (symbol-name state))))

(defun emacsos-pinephone-controls--cell-off ()
  "Turn cellular data off from the Controls row."
  (emacsos-net-set-cell nil))

(defun emacsos-pinephone-controls--wifi-off ()
  "Turn Wi-Fi off from the Controls row."
  (emacsos-net-set-wifi nil))

(defun emacsos-pinephone-controls-networks ()
  "Open the bounded network chooser and return its Done action to Controls."
  (interactive)
  (emacsos-net-show #'emacsos-controls-show))

(defun emacsos-pinephone-controls--status (row)
  "Return display status for Controls ROW."
  (let ((operation emacsos-pinephone-controls-device-operation))
    (pcase row
      ('wifi
       (cond
        ((eq (emacsos-net-state-wifi-pending emacsos-net--state) 'on)
         "Turning on...")
        ((eq (emacsos-net-state-wifi-pending emacsos-net--state) 'off)
         "Turning off...")
        ((not (emacsos-net-state-valid emacsos-net--state))
         (if (emacsos-net-state-error emacsos-net--state)
             (emacsos-pinephone-controls--unavailable
              (emacsos-net-state-error emacsos-net--state))
           "Checking..."))
        ((emacsos-net-state-wifi-error emacsos-net--state)
         (emacsos-net-state-wifi-error emacsos-net--state))
        ((not (eq (emacsos-net-state-wifi-on emacsos-net--state) t)) "off")
        (t (or (emacsos-net-state-ssid emacsos-net--state) "on"))))
      ('cell
       (cond
        ((eq (emacsos-net-state-cell-pending emacsos-net--state) 'on)
         "Turning on...")
        ((eq (emacsos-net-state-cell-pending emacsos-net--state) 'off)
         "Turning off...")
        ((not (emacsos-net-state-valid emacsos-net--state))
         (if (emacsos-net-state-error emacsos-net--state)
             (emacsos-pinephone-controls--unavailable
              (emacsos-net-state-error emacsos-net--state))
           "Checking..."))
        ((not (emacsos-net-state-cell-provisioned emacsos-net--state)) "Not set up")
        ((emacsos-net-state-cell-error emacsos-net--state)
         (emacsos-net-state-cell-error emacsos-net--state))
        (t (concat (if (emacsos-net-state-cell-on emacsos-net--state) "on" "off")
                   (let ((detail (emacsos-net-state-cell-state emacsos-net--state)))
                     (if (string-empty-p detail) "" (format " %s" detail)))))))
      ('brightness
       (cond
        ((and operation
              (memq (plist-get operation :row) (list row 'status))
              (plist-get operation :timed-out)) "Still stopping...")
        ((and operation (memq (plist-get operation :row) (list row 'status)))
         (if (eq (plist-get operation :row) 'status) "Checking..." "Changing..."))
        (emacsos-pinephone-controls-device-error
         (emacsos-pinephone-controls--unavailable
          emacsos-pinephone-controls-device-error))
        (emacsos-pinephone-controls-brightness
         (format "%s%%" emacsos-pinephone-controls-brightness))
        (t "Checking...")))
      ('flashlight
       (cond
        ((and operation
              (memq (plist-get operation :row) (list row 'status))
              (plist-get operation :timed-out)) "Still stopping...")
        ((and operation (memq (plist-get operation :row) (list row 'status)))
         (cond
          ((eq (plist-get operation :row) 'status) "Checking...")
          ((equal (plist-get operation :arguments) '("flashlight" "on"))
           "Turning on...")
          (t "Turning off...")))
        (emacsos-pinephone-controls-device-error
         (emacsos-pinephone-controls--unavailable
          emacsos-pinephone-controls-device-error))
        (emacsos-pinephone-controls-flashlight
         (symbol-name emacsos-pinephone-controls-flashlight))
        (t "Checking...")))
      ('keyboard (if emacsos-pinephone-keyboard-hidden "hidden" "shown")))))

(defun emacsos-pinephone-controls--insert-row
    (label status actions &optional reserved-actions)
  "Insert one fixed-height Controls row with LABEL, STATUS, and ACTIONS.
Each ACTION is (TEXT FUNCTION ARG); an omitted ARG calls FUNCTION without one.
RESERVED-ACTIONS keeps the status width stable when some actions are absent."
  (let* ((window (get-buffer-window (current-buffer)))
         (width (if window (window-body-width window) 40))
         (action-width 7)
         (action-space (* (max (length actions) (or reserved-actions 0))
                          (1+ action-width)))
         (status-width (max 0 (- width (string-width label) action-space 1)))
         (row-height (+ (frame-char-height) (* 2 emacsos--btn-vpad))))
    (insert (propertize label 'line-height row-height)
            " " (emacsos-pinephone-controls--bounded status status-width))
    (dolist (action actions)
      (insert " ")
      (emacsos--btn (emacsos--center (nth 0 action) action-width)
                   (nth 1 action) (nth 2 action) emacsos--btn-label-scale))
    (insert "\n")))

(defun emacsos-pinephone-controls--device-actions (row)
  "Return actions for device ROW in the current verified state."
  (let ((operation emacsos-pinephone-controls-device-operation))
    (cond
     (operation nil)
     (emacsos-pinephone-controls-device-error
      '(("Retry" emacsos-pinephone-controls--refresh-device nil)))
     ((eq row 'brightness)
      (when emacsos-pinephone-controls-brightness
        (let* ((levels '(25 50 75 100))
               (position (cl-position emacsos-pinephone-controls-brightness levels))
               (lower (and position (> position 0) (nth (1- position) levels)))
               (higher (and position (< position 3) (nth (1+ position) levels))))
          (append (and lower `(("Dim" emacsos-controls-set-brightness ,lower)))
                  (and higher `(("Bright" emacsos-controls-set-brightness ,higher)))))))
     ((eq row 'flashlight)
      (and emacsos-pinephone-controls-flashlight
           (if (eq emacsos-pinephone-controls-flashlight 'on)
               '(("Off" emacsos-controls-set-flashlight off))
             '(("On" emacsos-controls-set-flashlight on))))))))

(defun emacsos-pinephone-controls--render ()
  "Render the fixed seven-line PinePhone Controls surface."
  (let ((buffer (get-buffer-create emacsos-pinephone-controls-buffer-name)))
    (with-current-buffer buffer
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Controls\n")
        (let ((wifi-actions
               (cond
                ((emacsos-net-state-wifi-pending emacsos-net--state) nil)
                ((and (not (emacsos-net-state-valid emacsos-net--state))
                      (emacsos-net-state-error emacsos-net--state))
                 '(("Retry" emacsos-net--retry nil)))
                ((not (emacsos-net-state-valid emacsos-net--state)) nil)
                ((eq (emacsos-net-state-wifi-on emacsos-net--state) t)
                 '(("Off" emacsos-pinephone-controls--wifi-off nil)
                   ("Networks" emacsos-pinephone-controls-networks nil)))
                (t '(("On" emacsos-net-set-wifi t))))))
          (emacsos-pinephone-controls--insert-row
           "WiFi" (emacsos-pinephone-controls--status 'wifi) wifi-actions 2))
        (let ((cell-actions
               (cond
                ((emacsos-net-state-cell-pending emacsos-net--state) nil)
                ((and (not (emacsos-net-state-valid emacsos-net--state))
                      (emacsos-net-state-error emacsos-net--state))
                 '(("Retry" emacsos-net--retry nil)))
                ((not (emacsos-net-state-cell-provisioned emacsos-net--state)) nil)
                ((emacsos-net-state-cell-on emacsos-net--state)
                 '(("Off" emacsos-pinephone-controls--cell-off nil)))
                (t '(("On" emacsos-net-set-cell t))))))
          (emacsos-pinephone-controls--insert-row
           "Modem" (emacsos-pinephone-controls--status 'cell) cell-actions))
        (emacsos-pinephone-controls--insert-row
         "Light" (emacsos-pinephone-controls--status 'brightness)
         (emacsos-pinephone-controls--device-actions 'brightness) 2)
        (emacsos-pinephone-controls--insert-row
         "Torch" (emacsos-pinephone-controls--status 'flashlight)
         (emacsos-pinephone-controls--device-actions 'flashlight))
        (emacsos-pinephone-controls--insert-row
         "Keys" (emacsos-pinephone-controls--status 'keyboard)
         (list (list (if emacsos-pinephone-keyboard-hidden "Show" "Hide")
                     #'emacsos-pinephone-toggle-keyboard nil)))
        (emacsos--btn (emacsos--center "Done" 12)
                     #'emacsos-pinephone-controls-done nil
                     emacsos--btn-label-scale)
        (insert "\n"))
      (setq buffer-read-only t)
      (setq-local cursor-type nil)
      (setq-local truncate-lines t)
      (setq-local mode-line-format nil)
      (goto-char (point-min)))
    buffer))

(defun emacsos-pinephone-controls-done ()
  "Restore the content buffer saved when Controls first opened."
  (interactive)
  (let ((window (and (fboundp 'emacsos--target) (emacsos--target))))
    (setq emacsos-pinephone-controls-active nil)
    (when window
      (set-window-buffer
       window
       (if (buffer-live-p emacsos-pinephone-controls-parent-buffer)
           emacsos-pinephone-controls-parent-buffer
         (funcall emacsos-initial-buffer-function))))))

(defun emacsos-controls-show ()
  "Show the PinePhone Controls buffer and refresh available state."
  (interactive)
  (let* ((window (and (fboundp 'emacsos--target) (emacsos--target)))
         (controls (get-buffer-create emacsos-pinephone-controls-buffer-name))
         (current (and window (window-buffer window))))
    (when (and current
               (not emacsos-pinephone-controls-active)
               (not (eq current controls)))
      (setq emacsos-pinephone-controls-parent-buffer current))
    (setq emacsos-pinephone-controls-active t)
    (when window (set-window-buffer window controls))
    (emacsos-pinephone-controls--render)
    (emacsos-net--ensure-timer)
    (unless (emacsos-net-state-error emacsos-net--state) (emacsos-net--refresh))
    (unless (or emacsos-pinephone-controls-device-operation
                emacsos-pinephone-controls-device-error)
      (emacsos-pinephone-controls--refresh-device))
    "shown: controls"))

(defconst emacsos-pinephone-controls-mode-line-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] #'emacsos-controls-show)
    map)
  "Keymap for the PinePhone Controls entry.")

(defun emacsos-pinephone-controls-mode-line-string ()
  "Return the compact PinePhone Controls modeline entry."
  (propertize " Controls "
              'local-map emacsos-pinephone-controls-mode-line-map
              'mouse-face 'mode-line-highlight
              'face `(:height 0.8
                      :box (:line-width (3 . ,emacsos--btn-vpad)
                            :style released-button))
              'help-echo "Open phone controls"))

(setq emacsos-platform-primary-mode-line-segment
      '(:eval (emacsos-pinephone-controls-mode-line-string))
      emacsos-platform-mode-line-segments nil)

(when (display-graphic-p)
  (add-to-list 'load-path "/usr/local/share/emacsos-openrc")
  (setq emacsos-use-internal-keyboard nil
        emacsos-control-window-percent 35
        emacsos-initial-buffer-function #'emacsos--chat-buffer
        emacsos-net-cell-connection emacsos-pinephone-cell-connection
        emacsos-net-command-function #'emacsos-pinephone-network-command
        emacsos-net-connection-function #'emacsos-pinephone-wifi-operation
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
  (require 'swipe-learning)
  (define-key emacsos-command-map (kbd "k") #'emacsos-pinephone-toggle-keyboard)
  (define-key emacsos-command-map (kbd "b") #'emacsos-firefox-start)
  (define-key emacsos-command-map (kbd "a") #'emacsos-android-start)
  (load "/usr/local/share/emacsos-openrc/dtach-shell-init.el" nil nil t)
  (emacsos-pinephone-load-agent-config emacsos-agent-file))

(provide 'emacsos-pinephone-openrc-init)
;;; openrc-init.el ends here
