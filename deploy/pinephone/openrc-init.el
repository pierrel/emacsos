;;; openrc-init.el --- PinePhone EmacsOS bootstrap  -*- lexical-binding: t; -*-

;; Assist-first PinePhone session with an optional synthetic lab status page.

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

(defconst emacsos-pinephone-openrc-buffer "*EmacsOS*"
  "Editable PinePhone lab status buffer.")

(defvar emacsos-pinephone-firefox-process nil
  "Firefox process started from the PinePhone EmacsOS session.")

(defvar emacsos-pinephone-firefox-status-marker nil
  "Marker at the start of the Firefox status shown on the home screen.")

(defvar emacsos-pinephone-waydroid-process nil
  "Waydroid process started from the PinePhone EmacsOS session.")

(defvar emacsos-pinephone-waydroid-status-marker nil
  "Marker at the start of the Waydroid status shown on the home screen.")

(defconst emacsos-pinephone-waydroid-config "/var/lib/waydroid/waydroid.cfg"
  "File created when the Android images have been initialized.")

(defconst emacsos-pinephone-cell-connection "emacsos-cellular"
  "NetworkManager profile managed by the PinePhone network helper.")

(require 'button)
(require 'subr-x)

(defvar emacsos-pinephone-button-map
  (let ((map (make-sparse-keymap)))
    (set-keymap-parent map button-map)
    (define-key map [mouse-1] #'push-button)
    map))

(defun emacsos-pinephone-set-status (marker text)
  "Replace the visible status at MARKER with TEXT."
  (when (and (markerp marker) (marker-buffer marker))
    (with-current-buffer (marker-buffer marker)
      (save-excursion
        (goto-char marker)
        (delete-region (line-beginning-position) (line-end-position))
        (insert text)))))

(defun emacsos-pinephone-firefox-finished (process _event)
  "Show when the tracked Firefox PROCESS has finished."
  (when (and (eq process emacsos-pinephone-firefox-process)
             (memq (process-status process) '(exit signal)))
    (setq emacsos-pinephone-firefox-process nil)
    (emacsos-pinephone-set-status
     emacsos-pinephone-firefox-status-marker "Firefox is closed.")))

(defun emacsos-pinephone-open-firefox ()
  "Start the lab Firefox profile or focus its existing window."
  (interactive)
  (if (and emacsos-pinephone-firefox-process
           (process-live-p emacsos-pinephone-firefox-process))
      (progn
        (emacsos-pinephone-set-status
         emacsos-pinephone-firefox-status-marker "Switching to Firefox...")
        (if (zerop (call-process "/usr/bin/swaymsg" nil nil nil
                                 "-s" (getenv "SWAYSOCK")
                                 "[app_id=\"firefox\"] focus"))
            (emacsos-pinephone-set-status
             emacsos-pinephone-firefox-status-marker "Firefox is open.")
          (emacsos-pinephone-set-status
           emacsos-pinephone-firefox-status-marker
           "Firefox window is not ready.")))
    (emacsos-pinephone-set-status
     emacsos-pinephone-firefox-status-marker "Starting Firefox...")
    (redisplay t)
    (setq emacsos-pinephone-firefox-process
          (start-process "emacsos-firefox" nil "/usr/bin/firefox"
                         "--new-instance" "about:blank"))
    (set-process-query-on-exit-flag emacsos-pinephone-firefox-process nil)
    (set-process-sentinel emacsos-pinephone-firefox-process
                          #'emacsos-pinephone-firefox-finished)))

(defun emacsos-pinephone-waydroid-finished (process _event)
  "Show the result when the tracked Waydroid PROCESS finishes."
  (when (and (eq process emacsos-pinephone-waydroid-process)
             (memq (process-status process) '(exit signal)))
    (setq emacsos-pinephone-waydroid-process nil)
    (if (zerop (process-exit-status process))
        (emacsos-pinephone-set-status
         emacsos-pinephone-waydroid-status-marker "Android is stopped.")
      (emacsos-pinephone-set-status
       emacsos-pinephone-waydroid-status-marker
       "Android failed to start. Check /var/lib/waydroid/waydroid.log."))))

(defun emacsos-pinephone-waydroid-output (process output)
  "Update the home when Waydroid PROCESS emits readiness in OUTPUT."
  (let ((text (concat (or (process-get process 'emacsos-output-tail) "")
                      output)))
    (when (and (eq process emacsos-pinephone-waydroid-process)
               (string-match-p "Android with user 0 is ready" text))
      (emacsos-pinephone-set-status
       emacsos-pinephone-waydroid-status-marker "Android is open."))
    (process-put process 'emacsos-output-tail
                 (substring text (max 0 (- (length text) 64))))))

(defun emacsos-pinephone-waydroid-stop-finished (process _event)
  "Update the home when the Waydroid stop PROCESS finishes."
  (when (memq (process-status process) '(exit signal))
    (if (zerop (process-exit-status process))
        (emacsos-pinephone-set-status
         emacsos-pinephone-waydroid-status-marker "Android is stopped.")
      (emacsos-pinephone-set-status
       emacsos-pinephone-waydroid-status-marker
       "Android did not stop cleanly."))))

(defun emacsos-pinephone-open-waydroid ()
  "Start Waydroid or focus its existing full-screen window."
  (interactive)
  (cond
   ((not (file-exists-p emacsos-pinephone-waydroid-config))
    (emacsos-pinephone-set-status
     emacsos-pinephone-waydroid-status-marker
     "Android images are not installed."))
   ((and emacsos-pinephone-waydroid-process
         (process-live-p emacsos-pinephone-waydroid-process))
    (emacsos-pinephone-set-status
     emacsos-pinephone-waydroid-status-marker "Switching to Android...")
    (if (zerop (call-process "/usr/bin/swaymsg" nil nil nil
                             "-s" (getenv "SWAYSOCK")
                             "[app_id=\"Waydroid\"] focus"))
        (emacsos-pinephone-set-status
         emacsos-pinephone-waydroid-status-marker "Android is open.")
      (emacsos-pinephone-set-status
       emacsos-pinephone-waydroid-status-marker
       "Android window is not ready.")))
   (t
    (emacsos-pinephone-set-status
     emacsos-pinephone-waydroid-status-marker
     "Starting Android. The first start can take two minutes...")
    (redisplay t)
    (setq emacsos-pinephone-waydroid-process
          (start-process "emacsos-waydroid" nil "/usr/bin/waydroid"
                         "show-full-ui"))
    (set-process-query-on-exit-flag emacsos-pinephone-waydroid-process nil)
    (set-process-filter emacsos-pinephone-waydroid-process
                        #'emacsos-pinephone-waydroid-output)
    (set-process-sentinel emacsos-pinephone-waydroid-process
                          #'emacsos-pinephone-waydroid-finished))))

(defun emacsos-pinephone-stop-waydroid ()
  "Stop the Waydroid session and its Android container."
  (interactive)
  (emacsos-pinephone-set-status
   emacsos-pinephone-waydroid-status-marker "Stopping Android...")
  (let ((process (start-process "emacsos-waydroid-stop" nil
                                "/usr/bin/waydroid" "session" "stop")))
    (set-process-query-on-exit-flag process nil)
    (set-process-sentinel process
                          #'emacsos-pinephone-waydroid-stop-finished)))

(defun emacsos-pinephone-insert-button (label action)
  "Insert a touch-operable button named LABEL that invokes ACTION."
  (insert-text-button label
                      'action (lambda (_button) (funcall action))
                      'follow-link t
                      'keymap emacsos-pinephone-button-map
                      'face '(:box (:line-width 4 :style released-button)
                                   :height 1.25 :weight bold)))

(defun emacsos-pinephone-openrc-home ()
  "Show the minimal editable PinePhone home."
  (interactive)
  (let ((buffer (get-buffer-create emacsos-pinephone-openrc-buffer)))
    (with-current-buffer buffer
      (unless (> (buffer-size) 0)
        (insert "EmacsOS\n\n")
        (insert "The minimal PinePhone session is running.\n")
        (insert "Tap the keyboard below and type here.\n\n")
        (emacsos-pinephone-insert-button "  Open Firefox  "
                                         #'emacsos-pinephone-open-firefox)
        (insert "\n\n")
        (setq emacsos-pinephone-firefox-status-marker (point-marker))
        (insert "Firefox is closed.\n\n")
        (emacsos-pinephone-insert-button "  Open Android  "
                                         #'emacsos-pinephone-open-waydroid)
        (insert "\n\n")
        (emacsos-pinephone-insert-button "  Stop Android  "
                                         #'emacsos-pinephone-stop-waydroid)
        (insert "\n\n")
        (setq emacsos-pinephone-waydroid-status-marker (point-marker))
        (insert "Android is stopped.\n\nAlt+Tab returns here.\n\n"))
      (text-mode)
      (visual-line-mode 1)
      (setq-local truncate-lines nil
                  word-wrap t
                  mode-line-format nil)
      (goto-char (point-min)))
    (switch-to-buffer buffer)
    (goto-char (point-min))
    (set-window-start (selected-window) (point-min))
    buffer))

(defun emacsos-pinephone-record-synthetic-input ()
  "Insert the fixed marker used by the automated input smoke."
  (interactive)
  (goto-char (point-max))
  (insert "[synthetic-input]\n"))

(global-set-key [f12] #'emacsos-pinephone-record-synthetic-input)
(global-set-key [WakeUp] #'ignore)

(add-to-list 'default-frame-alist '(fullscreen . maximized))
(add-to-list 'default-frame-alist '(font . "Monospace-14"))

(defun emacsos-pinephone-call-finished (process _event operation)
  "Report terminal PROCESS output for OPERATION and restore audio on failure."
  (when (memq (process-status process) '(exit signal))
    (let* ((buffer (process-buffer process))
           (status (if (buffer-live-p buffer)
                       (with-current-buffer buffer (string-trim (buffer-string)))
                     "")))
      (unwind-protect
          (if (zerop (process-exit-status process))
              (message "%s" (if (string-empty-p status)
                                 (format "%s completed" operation)
                               status))
            (when (memq operation '(dial answer))
              (emacos-call--audio nil))
            (when (eq operation 'answer)
              (emacos-call--dismiss))
            (message "emacos-call: %s"
                     (if (string-empty-p status)
                         (format "%s helper failed" operation)
                       status)))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(defun emacsos-pinephone-call-operation (operation value)
  "Start validated PinePhone call OPERATION for VALUE without blocking Emacs."
  (let* ((buffer (generate-new-buffer " *emacsos-call*"))
         (args (append (list "-n" "/usr/local/sbin/emacsos-openrc-call"
                             (symbol-name operation))
                       (and value (list value)))))
    (condition-case err
        (progn
          (make-process
           :name (format "emacsos-call-%s" operation)
           :buffer buffer
           :command (cons "/usr/bin/doas" args)
           :noquery t
           :sentinel (lambda (proc event)
                       (emacsos-pinephone-call-finished
                        proc event operation)))
          (pcase operation
            ('dial "dialing: requested")
            ('answer "answered: requested")
            ('hangup "hung-up: requested")
            (_ "error: unsupported call operation")))
      (error
       (when (buffer-live-p buffer) (kill-buffer buffer))
       (format "error: call helper failed: %s" (error-message-string err))))))

(defun emacsos-pinephone-call-audio-finished (process _event)
  "Report a terminal call-audio PROCESS failure and release its buffer."
  (when (memq (process-status process) '(exit signal))
    (let ((buffer (process-buffer process)))
      (unwind-protect
          (unless (zerop (process-exit-status process))
            (message "emacos-call: audio routing failed: %s"
                     (if (buffer-live-p buffer)
                         (with-current-buffer buffer
                           (string-trim (buffer-string)))
                       "no diagnostic output")))
        (when (buffer-live-p buffer) (kill-buffer buffer))))))

(defun emacsos-pinephone-call-audio (active)
  "Select call audio when ACTIVE without blocking the Emacs event loop."
  (let ((buffer (generate-new-buffer " *emacsos-call-audio*")))
    (condition-case err
        (make-process
         :name "emacsos-call-audio"
         :buffer buffer
         :command (list "/usr/bin/timeout" "-s" "TERM" "-k" "1" "5"
                        "/usr/bin/callaudiocli" "-m" (if active "1" "0"))
         :noquery t
         :sentinel #'emacsos-pinephone-call-audio-finished)
      (error
       (when (buffer-live-p buffer) (kill-buffer buffer))
       (signal (car err) (cdr err))))))

(defun emacsos-pinephone-wake-display ()
  "Wake the display and re-arm idle blanking without blocking ModemManager."
  (let ((process
         (start-process "emacsos-call-wake" nil
                        "/usr/local/share/emacsos-openrc/session-power" "wake")))
    (set-process-query-on-exit-flag process nil)))

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

(when (display-graphic-p)
  (add-to-list 'load-path "/usr/local/share/emacsos-openrc")
  (setq emacos-use-internal-keyboard nil
        emacos-control-window-percent 35
        emacos-initial-buffer-function #'emacos--chat-buffer
        emacos-net-cell-connection emacsos-pinephone-cell-connection
        emacos-net-command-function #'emacsos-pinephone-network-command
        emacos-chat-auth-file
        "/var/lib/emacsos-lab/.emacs.d/server/emacsos-openrc"
        emacos-call-operation-function #'emacsos-pinephone-call-operation
        emacos-call-audio-function #'emacsos-pinephone-call-audio
        emacos-call-wake-function #'emacsos-pinephone-wake-display
        emacos-call-control-gap-lines 1)
  (let ((url-file "/etc/emacsos-openrc/chat-url"))
    (setq emacos-chat-server-url
          (if (file-readable-p url-file)
              (with-temp-buffer
                (insert-file-contents url-file)
                (string-trim (buffer-string)))
            "http://localhost:8765/chat")))
  (defvar emacos-agent-file "/var/lib/emacsos-lab/.emacs.d/emacsos/agent.el"
    "Persistent agent configuration applied by Assist.")
  (require 'server)
  (setq server-use-tcp t
        server-host "0.0.0.0"
        server-port 8766
        server-name "emacsos-openrc")
  (server-start)
  (set-face-attribute 'default nil :height 140)
  (require 'os)
  (setq emacos-global-commands
        (append '(("Firefox" . emacsos-pinephone-open-firefox)
                  ("Android" . emacsos-pinephone-open-waydroid)
                  ("Stop Android" . emacsos-pinephone-stop-waydroid)
                  ("Lab home" . emacsos-pinephone-openrc-home))
                emacos-global-commands))
  (when (file-readable-p emacos-agent-file)
    (condition-case err
        (load emacos-agent-file nil 'nomessage)
      (error (message "emacsos: saved agent config failed: %s"
                      (error-message-string err))))))

(provide 'emacsos-pinephone-openrc-init)
;;; openrc-init.el ends here
