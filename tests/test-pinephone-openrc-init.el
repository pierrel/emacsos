;;; test-pinephone-openrc-init.el --- PinePhone OpenRC bootstrap tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(load-file (expand-file-name "../deploy/pinephone/openrc-init.el"
                             (file-name-directory load-file-name)))
(require 'os)

(ert-deftest emacsos-openrc-lifecycle-actions-are-commands ()
  (dolist (command '(emacsos-firefox-start
                     emacsos-firefox-quit
                     emacsos-android-start
                     emacsos-android-quit))
    (should (commandp command))))

(ert-deftest emacsos-openrc-fixed-input-marker-is-inserted ()
  (with-temp-buffer
    (emacsos-pinephone-record-synthetic-input)
    (goto-char (point-min))
    (should (search-forward "[synthetic-input]" nil t))))

(ert-deftest emacsos-openrc-wakeup-event-is-silent ()
  (should (eq (lookup-key global-map [WakeUp]) #'ignore)))

(ert-deftest emacsos-openrc-keyboard-toggle-signals-validated-wvkbd ()
  (let ((emacsos-pinephone-wvkbd-pid "42")
        (emacsos-pinephone-keyboard-hidden nil)
        signal)
    (cl-letf (((symbol-function 'process-attributes)
               (lambda (_) '((comm . "wvkbd-emacsos") (user . "emacsos-lab"))))
              ((symbol-function 'signal-process)
               (lambda (pid value) (setq signal (list pid value))))
              ((symbol-function 'force-mode-line-update) #'ignore))
      (emacsos-pinephone-toggle-keyboard)
      (should (equal signal '(42 SIGUSR1)))
      (should emacsos-pinephone-keyboard-hidden)
      (emacsos-pinephone-toggle-keyboard)
      (should (equal signal '(42 SIGUSR2)))
      (should-not emacsos-pinephone-keyboard-hidden))))

(ert-deftest emacsos-openrc-keyboard-toggle-rejects-an-unexpected-process ()
  (let ((emacsos-pinephone-wvkbd-pid "42")
        called)
    (cl-letf (((symbol-function 'emacsos-pinephone-valid-wvkbd-pid-p)
               (lambda (_) nil))
              ((symbol-function 'emacsos-pinephone-find-wvkbd-pid)
               (lambda () nil))
              ((symbol-function 'signal-process)
               (lambda (&rest _) (setq called t))))
      (should-error (emacsos-pinephone-toggle-keyboard) :type 'user-error)
      (should-not called))))

(ert-deftest emacsos-openrc-keyboard-toggle-rejects-a-missing-pid ()
  (let ((emacsos-pinephone-wvkbd-pid nil)
        called)
    (cl-letf (((symbol-function 'call-process) (lambda (&rest _) 1))
              ((symbol-function 'signal-process)
               (lambda (&rest _) (setq called t))))
      (should-error (emacsos-pinephone-toggle-keyboard) :type 'user-error)
      (should-not called))))

(ert-deftest emacsos-openrc-keyboard-toggle-recovers-a-stale-pid ()
  (let ((emacsos-pinephone-wvkbd-pid "42")
        signal)
    (cl-letf (((symbol-function 'emacsos-pinephone-valid-wvkbd-pid-p)
               (lambda (pid) (equal pid "43")))
              ((symbol-function 'emacsos-pinephone-find-wvkbd-pid)
               (lambda () "43"))
              ((symbol-function 'signal-process)
               (lambda (pid value) (setq signal (list pid value))))
              ((symbol-function 'force-mode-line-update) #'ignore))
      (emacsos-pinephone-toggle-keyboard)
      (should (equal signal '(43 SIGUSR1)))
      (should (equal emacsos-pinephone-wvkbd-pid "43")))))

(ert-deftest emacsos-openrc-keyboard-finds-one-supervised-pid ()
  (let (directory command)
    (let ((default-directory "/ssh:thinky:"))
      (cl-letf (((symbol-function 'call-process)
                 (lambda (program _infile _destination _display &rest args)
                   (setq directory default-directory)
                   (setq command (cons program args))
                   (insert "43\n")
                   0)))
        (should (equal (emacsos-pinephone-find-wvkbd-pid) "43"))))
    (should (equal directory "/"))
    (should (equal command
                   '("/usr/bin/pgrep" "-u" "emacsos-lab" "-f"
                     "^/usr/local/bin/wvkbd-emacsos --mod-swipe -H 300 -L 300$")))))

(ert-deftest emacsos-openrc-keyboard-validates-pid-locally ()
  (let (directory)
    (let ((default-directory "/ssh:thinky:"))
      (cl-letf (((symbol-function 'process-attributes)
                 (lambda (_)
                   (setq directory default-directory)
                   '((comm . "wvkbd-emacsos") (user . "emacsos-lab")))))
        (should (emacsos-pinephone-valid-wvkbd-pid-p "43"))))
    (should (equal directory "/"))))

(ert-deftest emacsos-openrc-keyboard-rejects-stock-process ()
  (cl-letf (((symbol-function 'process-attributes)
             (lambda (_)
               '((comm . "wvkbd-mobintl") (user . "emacsos-lab")))))
    (should-not (emacsos-pinephone-valid-wvkbd-pid-p "43"))))

(ert-deftest emacsos-openrc-controls-mode-line-is-compact-and-tappable ()
  (let* ((text (emacsos-pinephone-controls-mode-line-string))
         (face (get-text-property 0 'face text))
         (line-width (plist-get (plist-get face :box) :line-width)))
    (should (equal (substring-no-properties text) " Controls "))
    (should (eq (lookup-key (get-text-property 0 'local-map text)
                            [mode-line mouse-1])
                #'emacsos-controls-show))
    (should (= (plist-get face :height) 0.8))
    (should (= (cdr line-width) emacsos--btn-vpad))))

(ert-deftest emacsos-openrc-controls-replaces-primary-network-segment ()
  (should (equal emacsos-platform-primary-mode-line-segment
                 '(:eval (emacsos-pinephone-controls-mode-line-string))))
  (should-not emacsos-platform-mode-line-segments))

(ert-deftest emacsos-openrc-controls-subscribes-to-network-state-changes ()
  (should (memq #'emacsos-pinephone-controls--render-if-shown
                emacsos-net-state-change-functions)))

(ert-deftest emacsos-openrc-device-snapshot-parser-is-strict ()
  (should (equal (emacsos-pinephone-controls--parse-snapshot
                  "brightness:50\nflashlight:on\n")
                 '(50 . on)))
  (should-not (emacsos-pinephone-controls--parse-snapshot
               "brightness:0\nflashlight:on\n"))
  (should-not (emacsos-pinephone-controls--parse-snapshot
               "brightness:50\nflashlight:on\nextra\n")))

(ert-deftest emacsos-openrc-device-setter-uses-fixed-privileged-helper ()
  (let ((emacsos-pinephone-controls-device-operation nil)
        seen)
    (cl-letf (((symbol-function 'generate-new-buffer)
               (lambda (&rest _) (get-buffer-create " *test-device*")))
              ((symbol-function 'make-process)
               (lambda (&rest args) (setq seen args) 'device-process))
              ((symbol-function 'run-with-timer) (lambda (&rest _) 'timer))
              ((symbol-function 'emacsos-pinephone-controls--render-if-shown)
               #'ignore))
      (should (equal (emacsos-controls-set-brightness 75)
                     "pending: brightness 75")))
    (should (equal (plist-get seen :command)
                   '("/usr/bin/doas" "-n"
                     "/usr/local/sbin/emacsos-openrc-device"
                     "brightness" "75")))
    (when (get-buffer " *test-device*") (kill-buffer " *test-device*"))))

(ert-deftest emacsos-openrc-device-setters-reject-open-ended-values ()
  (should-error (emacsos-controls-set-brightness 0) :type 'user-error)
  (should-error (emacsos-controls-set-brightness 80) :type 'user-error)
  (should-error (emacsos-controls-set-flashlight 'toggle) :type 'user-error))

(ert-deftest emacsos-openrc-device-setters-interactively-read-explicit-states ()
  (let (seen)
    (cl-letf (((symbol-function 'completing-read)
               (lambda (prompt &rest _)
                 (if (string-prefix-p "Brightness" prompt) "75" "off")))
              ((symbol-function 'emacsos-pinephone-controls--start-device)
               (lambda (row arguments) (push (list row arguments) seen))))
      (call-interactively #'emacsos-controls-set-brightness)
      (call-interactively #'emacsos-controls-set-flashlight))
    (should (equal (nreverse seen)
                   '((brightness ("brightness" "75"))
                     (flashlight ("flashlight" "off")))))))

(ert-deftest emacsos-openrc-device-timeout-hides-retry-until-process-stops ()
  (let ((buffer (generate-new-buffer " *test-device-timeout*"))
        (emacsos-pinephone-controls-device-operation
         '(:process device-process :timer timer :row status))
        (emacsos-pinephone-controls-device-error nil)
        detached)
    (unwind-protect
        (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
                  ((symbol-function 'process-buffer) (lambda (_) buffer))
                  ((symbol-function 'set-process-buffer)
                   (lambda (process replacement)
                     (setq detached (list process replacement))))
                  ((symbol-function 'emacsos-pinephone-controls--render-if-shown)
                   #'ignore))
          (emacsos-pinephone-controls--device-timeout 'device-process)
          (should (equal (emacsos-pinephone-controls--status 'brightness)
                         "Still stopping..."))
          (should (equal detached '(device-process nil)))
          (should-not (emacsos-pinephone-controls--device-actions 'brightness)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest emacsos-openrc-device-timeout-detaches-without-killing-process ()
  (let* ((buffer (generate-new-buffer " *test-live-device-timeout*"))
         (process (make-process :name "test-live-device-timeout"
                                :buffer buffer
                                :command '("sh" "-c" "sleep 5")
                                :noquery t))
         (emacsos-pinephone-controls-device-operation
          (list :process process :timer nil :row 'status)))
    (unwind-protect
        (cl-letf (((symbol-function 'emacsos-pinephone-controls--render-if-shown)
                   #'ignore))
          (emacsos-pinephone-controls--device-timeout process)
          (should-not (buffer-live-p buffer))
          (should-not (process-buffer process))
          (should (process-live-p process)))
      (when (process-live-p process) (delete-process process))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest emacsos-openrc-stale-device-sentinel-cannot-replace-newer-state ()
  (let ((buffer (generate-new-buffer " *test-stale-device*"))
        (emacsos-pinephone-controls-brightness 25)
        (emacsos-pinephone-controls-device-operation
         '(:process new-process :timer new-timer :row brightness)))
    (with-current-buffer buffer
      (insert "brightness:100\nflashlight:on\n"))
    (cl-letf (((symbol-function 'process-status) (lambda (_) 'exit))
              ((symbol-function 'process-exit-status) (lambda (_) 0))
              ((symbol-function 'process-buffer) (lambda (_) buffer)))
      (emacsos-pinephone-controls--device-finished 'old-process))
    (should (= emacsos-pinephone-controls-brightness 25))
    (should (eq (plist-get emacsos-pinephone-controls-device-operation :process)
                'new-process))
    (should-not (buffer-live-p buffer))))

(ert-deftest emacsos-openrc-device-success-updates-both-verified-values ()
  (let ((buffer (generate-new-buffer " *test-device-success*"))
        (emacsos-pinephone-controls-brightness nil)
        (emacsos-pinephone-controls-flashlight nil)
        (emacsos-pinephone-controls-device-error "old")
        (emacsos-pinephone-controls-device-operation
         '(:process device-process :timer timer :row status)))
    (with-current-buffer buffer
      (insert "brightness:75\nflashlight:off\n"))
    (cl-letf (((symbol-function 'process-status) (lambda (_) 'exit))
              ((symbol-function 'process-exit-status) (lambda (_) 0))
              ((symbol-function 'process-buffer) (lambda (_) buffer))
              ((symbol-function 'timerp) (lambda (_) t))
              ((symbol-function 'cancel-timer) #'ignore)
              ((symbol-function 'emacsos-pinephone-controls--render-if-shown)
               #'ignore))
      (emacsos-pinephone-controls--device-finished 'device-process))
    (should (= emacsos-pinephone-controls-brightness 75))
    (should (eq emacsos-pinephone-controls-flashlight 'off))
    (should-not emacsos-pinephone-controls-device-operation)
    (should-not emacsos-pinephone-controls-device-error)
    (should-not (buffer-live-p buffer))))

(ert-deftest emacsos-openrc-device-failure-invalidates-both-device-rows ()
  (let ((buffer (generate-new-buffer " *test-device-failure*"))
        (emacsos-pinephone-controls-brightness 50)
        (emacsos-pinephone-controls-flashlight 'off)
        (emacsos-pinephone-controls-device-error nil)
        (emacsos-pinephone-controls-device-operation
         '(:process device-process :timer nil :row brightness)))
    (with-current-buffer buffer
      (insert "emacsos-openrc-device: flashlight value is invalid\n"))
    (cl-letf (((symbol-function 'process-status) (lambda (_) 'exit))
              ((symbol-function 'process-exit-status) (lambda (_) 1))
              ((symbol-function 'process-buffer) (lambda (_) buffer))
              ((symbol-function 'emacsos-pinephone-controls--render-if-shown)
               #'ignore))
      (emacsos-pinephone-controls--device-finished 'device-process))
    (should-not emacsos-pinephone-controls-brightness)
    (should-not emacsos-pinephone-controls-flashlight)
    (should (string-prefix-p
             "emacsos-openrc-device: flashlight value"
             emacsos-pinephone-controls-device-error))
    (should (<= (string-width emacsos-pinephone-controls-device-error) 48))
    (should (equal (emacsos-pinephone-controls--device-actions 'brightness)
                   '(("Retry" emacsos-pinephone-controls--refresh-device nil))))
    (should (equal (emacsos-pinephone-controls--device-actions 'flashlight)
                   '(("Retry" emacsos-pinephone-controls--refresh-device nil))))
    (should-not (buffer-live-p buffer))))

(ert-deftest emacsos-openrc-controls-render-is-seven-nonwrapping-lines ()
  (let ((emacsos-net--state
         (make-emacsos-net-state :valid t :wifi-on t :ssid "A very long SSID"
                                :cell-provisioned t :cell-on t))
        (emacsos-pinephone-controls-brightness 50)
        (emacsos-pinephone-controls-flashlight 'off)
        (emacsos-pinephone-controls-device-operation nil)
        (emacsos-pinephone-controls-device-error nil))
    (unwind-protect
        (with-current-buffer (emacsos-pinephone-controls--render)
          (should (= (line-number-at-pos (point-max)) 8))
          (should truncate-lines)
          (should-not mode-line-format)
          (dolist (label '("Controls" "WiFi" "Modem" "Light" "Torch"
                           "Keys" "Done"))
            (goto-char (point-min))
            (should (search-forward label nil t))))
      (when (get-buffer emacsos-pinephone-controls-buffer-name)
        (kill-buffer emacsos-pinephone-controls-buffer-name)))))

(ert-deftest emacsos-openrc-controls-wifi-actions-compose-with-chooser ()
  (let ((emacsos-net--state
         (make-emacsos-net-state :valid t :wifi-on t :ssid "HomeNet"))
        (emacsos-pinephone-controls-brightness 50)
        (emacsos-pinephone-controls-flashlight 'off)
        (emacsos-pinephone-controls-device-operation nil)
        (emacsos-pinephone-controls-device-error nil)
        return-function)
    (unwind-protect
        (progn
          (with-current-buffer (emacsos-pinephone-controls--render)
            (let ((text (buffer-string)))
              (should (string-match-p "Off" text))
              (should (string-match-p "Networks" text))))
          (cl-letf (((symbol-function 'emacsos-net-show)
                     (lambda (&optional return)
                       (setq return-function return))))
            (emacsos-pinephone-controls-networks))
          (should (eq return-function #'emacsos-controls-show)))
      (when (get-buffer emacsos-pinephone-controls-buffer-name)
        (kill-buffer emacsos-pinephone-controls-buffer-name)))))

(ert-deftest emacsos-openrc-controls-statuses-distinguish-unavailable ()
  (let ((emacsos-net--state
         (make-emacsos-net-state :valid nil :error "reader failed"))
        (emacsos-pinephone-controls-device-operation nil)
        (emacsos-pinephone-controls-device-error "helper failed"))
    (should (equal (emacsos-pinephone-controls--status 'wifi)
                   "Unavailable: reader failed"))
    (should (equal (emacsos-pinephone-controls--status 'cell)
                   "Unavailable: reader failed"))
    (should (equal (emacsos-pinephone-controls--status 'brightness)
                   "Unavailable: helper failed"))
    (should (equal (emacsos-pinephone-controls--status 'flashlight)
                   "Unavailable: helper failed"))))

(ert-deftest emacsos-openrc-controls-initial-network-check-has-no-retry ()
  (let ((emacsos-net--state (make-emacsos-net-state :valid nil :error nil))
        (emacsos-pinephone-controls-brightness 50)
        (emacsos-pinephone-controls-flashlight 'off)
        (emacsos-pinephone-controls-device-operation nil)
        (emacsos-pinephone-controls-device-error nil))
    (unwind-protect
        (with-current-buffer (emacsos-pinephone-controls--render)
          (should (string-match-p "Modem Checking" (buffer-string)))
          (should-not (string-match-p "Retry" (buffer-string))))
      (when (get-buffer emacsos-pinephone-controls-buffer-name)
        (kill-buffer emacsos-pinephone-controls-buffer-name)))))

(ert-deftest emacsos-openrc-controls-brightness-reserves-two-actions ()
  (with-temp-buffer
    (emacsos-pinephone-controls--insert-row
     "Light" "abcdefghijklmnopqrstuvwxyz"
     '(("Dim" ignore nil)) 2)
    (should (equal (buffer-substring-no-properties (point-min) (point-max))
                   "Light abcdefghijklmnopq…   Dim  \n"))))

(ert-deftest emacsos-openrc-controls-pending-row-keeps-button-height ()
  (with-temp-buffer
    (emacsos-pinephone-controls--insert-row "Modem" "Turning on..." nil)
    (should (= (get-text-property (point-min) 'line-height)
               (+ (frame-char-height) (* 2 emacsos--btn-vpad))))))

(ert-deftest emacsos-openrc-controls-zero-width-drops-status ()
  (should (equal (emacsos-pinephone-controls--bounded "Unavailable" 0) "")))

(ert-deftest emacsos-openrc-controls-done-button-invokes-live-command ()
  (let ((emacsos-net--state (make-emacsos-net-state :valid t))
        (emacsos-pinephone-controls-brightness 50)
        (emacsos-pinephone-controls-flashlight 'off)
        invoked)
    (unwind-protect
        (with-current-buffer (emacsos-pinephone-controls--render)
          (goto-char (point-min))
          (search-forward "Done")
          (cl-letf (((symbol-function 'emacsos-pinephone-controls-done)
                     (lambda () (setq invoked t))))
            (button-activate (button-at (1- (point)))))
          (should invoked))
      (when (get-buffer emacsos-pinephone-controls-buffer-name)
        (kill-buffer emacsos-pinephone-controls-buffer-name)))))

(ert-deftest emacsos-openrc-controls-reentry-retains-original-parent ()
  (let ((parent (get-buffer-create " *controls-parent*"))
        (controls (get-buffer-create emacsos-pinephone-controls-buffer-name))
        (emacsos-pinephone-controls-parent-buffer nil)
        (emacsos-pinephone-controls-active nil))
    (unwind-protect
        (cl-letf (((symbol-function 'emacsos--target)
                   (lambda () (selected-window)))
                  ((symbol-function 'emacsos-pinephone-controls--render)
                   (lambda () controls))
                  ((symbol-function 'emacsos-net--ensure-timer) #'ignore)
                  ((symbol-function 'emacsos-net--refresh) #'ignore)
                  ((symbol-function
                    'emacsos-pinephone-controls--refresh-device) #'ignore))
          (set-window-buffer (selected-window) parent)
          (emacsos-controls-show)
          (should (eq emacsos-pinephone-controls-parent-buffer parent))
          (set-window-buffer (selected-window) (get-buffer-create " *chooser*"))
          (emacsos-controls-show)
          (should (eq emacsos-pinephone-controls-parent-buffer parent)))
      (set-window-buffer (selected-window) (get-buffer-create "*scratch*"))
      (kill-buffer parent)
      (when (get-buffer " *chooser*") (kill-buffer " *chooser*"))
      (kill-buffer controls))))

(ert-deftest emacsos-openrc-controls-first-render-uses-target-window ()
  (let ((parent (generate-new-buffer " *controls-width-parent*"))
        (controls (get-buffer-create emacsos-pinephone-controls-buffer-name))
        (emacsos-net--state (make-emacsos-net-state :valid nil :error nil))
        (emacsos-pinephone-controls-brightness 50)
        (emacsos-pinephone-controls-device-error nil)
        (emacsos-pinephone-controls-active nil)
        visible-window
        (network-refreshes 0)
        (device-refreshes 0))
    (unwind-protect
        (cl-letf (((symbol-function 'emacsos--target)
                   (lambda () (selected-window)))
                  ((symbol-function 'emacsos-pinephone-controls--render)
                   (lambda ()
                     (setq visible-window (get-buffer-window controls))
                     controls))
                  ((symbol-function 'emacsos-net--ensure-timer) #'ignore)
                  ((symbol-function 'emacsos-net--refresh)
                   (lambda () (cl-incf network-refreshes)))
                  ((symbol-function 'emacsos-pinephone-controls--refresh-device)
                   (lambda () (cl-incf device-refreshes))))
          (set-window-buffer (selected-window) parent)
          (emacsos-controls-show)
          (should (eq visible-window (selected-window)))
          (should (= network-refreshes 1))
          (should (= device-refreshes 1))
          (setf (emacsos-net-state-valid emacsos-net--state) t)
          (setq emacsos-pinephone-controls-device-error "failed")
          (emacsos-controls-show)
          (should (= network-refreshes 2))
          (should (= device-refreshes 1))
          (setf (emacsos-net-state-valid emacsos-net--state) nil
                (emacsos-net-state-error emacsos-net--state) "reader failed")
          (emacsos-controls-show)
          (should (= network-refreshes 2))
          (should (= device-refreshes 1))
          (emacsos-net--retry)
          (should (= network-refreshes 3))
          (should-not (emacsos-net-state-error emacsos-net--state)))
      (set-window-buffer (selected-window) (get-buffer-create "*scratch*"))
      (kill-buffer parent)
      (kill-buffer controls))))

(ert-deftest emacsos-openrc-cell-off-remains-visibly-pending ()
  (let ((emacsos-net--state
         (make-emacsos-net-state :valid t :cell-provisioned t :cell-on t))
        (emacsos-net--cell-operation nil)
        callback)
    (cl-letf (((symbol-function 'emacsos-net--action)
               (lambda (_args completion)
                 (setq callback completion)
                 'process))
              ((symbol-function 'emacsos-pinephone-controls--render-if-shown)
               #'ignore)
              ((symbol-function 'emacsos-net--render-if-shown) #'ignore)
              ((symbol-function 'force-mode-line-update) #'ignore))
      (emacsos-pinephone-controls--cell-off)
      (should (eq (emacsos-net-state-cell-pending emacsos-net--state) 'off))
      (should (equal (emacsos-pinephone-controls--status 'cell)
                     "Turning off..."))
      (funcall callback t "ok")
      (should-not (emacsos-net-state-cell-pending emacsos-net--state))
      (should-not (emacsos-net-state-cell-on emacsos-net--state)))))

(ert-deftest emacsos-openrc-frame-layout-finalizer-maximizes-frame ()
  (let (seen)
    (cl-letf (((symbol-function 'set-frame-parameter)
               (lambda (frame parameter value)
                 (setq seen (list frame parameter value)))))
      (emacsos-pinephone-enforce-frame-layout)
      (should (equal seen '(nil fullscreen maximized))))))

(ert-deftest emacsos-openrc-registers-frame-layout-finalizer ()
  (should (eq (symbol-function 'emacsos-pinephone-enforce-frame-layout)
              emacsos-agent-config-applied-function)))

(ert-deftest emacsos-openrc-agent-config-finalizer-survives-config-mutation ()
  (let ((file (make-temp-file "emacsos-agent-" nil ".el"))
        (emacsos-agent-config-applied-function
         (symbol-function 'emacsos-pinephone-enforce-frame-layout))
        seen)
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "(setq emacsos-agent-config-applied-function #'ignore)\n"))
          (cl-letf (((symbol-function 'set-frame-parameter)
                     (lambda (frame parameter value)
                       (setq seen (list frame parameter value)))))
            (emacsos-pinephone-load-agent-config file))
          (should (equal seen '(nil fullscreen maximized)))
          (should (eq emacsos-agent-config-applied-function
                      (symbol-function
                       'emacsos-pinephone-enforce-frame-layout))))
      (delete-file file))))

(ert-deftest emacsos-openrc-agent-config-finalizer-runs-after-quit ()
  (let ((file (make-temp-file "emacsos-agent-" nil ".el"))
        finalized)
    (let ((emacsos-agent-config-applied-function
           (lambda () (setq finalized t))))
      (unwind-protect
          (progn
            (with-temp-file file
              (insert "(signal 'quit nil)\n"))
            (emacsos-pinephone-load-agent-config file)
            (should finalized))
        (delete-file file)))))

(ert-deftest emacsos-openrc-call-operation-uses-only-fixed-helper ()
  (let (seen)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args) (setq seen args) 'process))
              ((symbol-function 'emacsos-call--modem-manager-owner)
               (lambda () ":1.42")))
      (should (string-prefix-p
               "pending:"
               (emacsos-pinephone-call-operation
                'dial ":1.bound" "+14155550123")))
      (should (equal (plist-get seen :command)
                     '("/usr/bin/doas" "-n"
                       "/usr/local/sbin/emacsos-openrc-call"
                       "dial" ":1.bound" "+14155550123"))))))

(ert-deftest emacsos-openrc-answer-and-hangup-are-asynchronous ()
  "Starting a helper is pending; only its sentinel delivers terminal success."
  (dolist (case '((answer "/org/freedesktop/ModemManager1/Call/4"
                          "pending: answer requested")
                  (hangup "/org/freedesktop/ModemManager1/Call/4"
                          "pending: hangup requested")))
    (let (seen
          (emacsos-call--call-owner ":1.42"))
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest args) (setq seen args) 'process))
                ((symbol-function 'emacsos-call--modem-manager-owner)
                 (lambda () ":1.42")))
        (should (equal
                 (emacsos-pinephone-call-operation
                  (nth 0 case) ":1.42" (nth 1 case) #'ignore)
                 (nth 2 case)))
        (should (equal
                 (plist-get seen :command)
                 (append
                  '("/usr/bin/doas" "-n"
                    "/usr/local/sbin/emacsos-openrc-call")
                  (list (symbol-name (nth 0 case)))
                  (and (memq (nth 0 case) '(answer hangup)) '(":1.42"))
                  (and (nth 1 case) (list (nth 1 case))))))
        (should (functionp (plist-get seen :sentinel)))))))

(ert-deftest emacsos-openrc-pathless-hangup-uses-global-recovery-operation ()
  (let (seen)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args) (setq seen args) 'process)))
      (should (equal (emacsos-pinephone-call-operation
                      'hangup nil nil #'ignore)
                     "pending: hangup requested"))
      (should (equal (plist-get seen :command)
                     '("/usr/bin/doas" "-n"
                       "/usr/local/sbin/emacsos-openrc-call" "hangup"))))))

(ert-deftest emacsos-openrc-call-finished-delivers-terminal-result ()
  (let ((buffer (generate-new-buffer " *test-call-result*"))
        delivered)
    (with-current-buffer buffer
      (insert "created-call-path: /org/freedesktop/ModemManager1/Call/12\n"
              "dialing: /org/freedesktop/ModemManager1/Call/12\n"))
    (cl-letf (((symbol-function 'process-status) (lambda (_) 'exit))
              ((symbol-function 'process-buffer) (lambda (_) buffer))
              ((symbol-function 'process-exit-status) (lambda (_) 0)))
      (emacsos-pinephone-call-finished
       'process "finished" 'dial (lambda (status) (setq delivered status))))
    (should (equal delivered
                   "dialing: /org/freedesktop/ModemManager1/Call/12"))
    (should-not (buffer-live-p buffer))))

(ert-deftest emacsos-openrc-abnormal-dial-retains-uncertain-call-path ()
  "A helper death after call creation cannot become a passive failure."
  (let ((buffer (generate-new-buffer " *test-call-interrupted*"))
        delivered)
    (with-current-buffer buffer
      (insert "created-call-path: /org/freedesktop/ModemManager1/Call/12\n"))
    (cl-letf (((symbol-function 'process-status) (lambda (_) 'signal))
              ((symbol-function 'process-buffer) (lambda (_) buffer))
              ((symbol-function 'process-exit-status) (lambda (_) 15)))
      (emacsos-pinephone-call-finished
       'process "killed" 'dial (lambda (status) (setq delivered status))))
    (should (equal delivered
                   (concat
                    "error: uncertain-call-path="
                    "/org/freedesktop/ModemManager1/Call/12; "
                    "dial helper terminated before final status")))
    (should-not (buffer-live-p buffer))))

(ert-deftest emacsos-openrc-success-with-missing-output-stays-canonical ()
  (should
   (equal
    (emacsos-pinephone-call-result
     'dial
     (concat "created-call-path: /org/freedesktop/ModemManager1/Call/12\n"
             "error: ModemManager owner changed")
     nil)
    (concat "error: uncertain-call-path="
            "/org/freedesktop/ModemManager1/Call/12; "
            "ModemManager owner changed")))
  (should (equal (emacsos-pinephone-call-result 'answer "" t)
                 "answered: call active"))
  (should (equal (emacsos-pinephone-call-result 'hangup "" t)
                 "hung-up: call ended"))
  (should (equal
           (emacsos-pinephone-call-result 'dial "" t)
           "error: uncertain-call; dial helper completed without call identity")))

(ert-deftest emacsos-openrc-abnormal-answer-retains-uncertain-call-path ()
  (should
   (equal
    (emacsos-pinephone-call-result
     'answer
     "answering-call-path: /org/freedesktop/ModemManager1/Call/12"
     nil)
    (concat "error: uncertain-answer-call-path="
            "/org/freedesktop/ModemManager1/Call/12; "
            "answer helper terminated before final status")))
  (should (equal
           (emacsos-pinephone-call-result 'answer "" nil)
           "error: uncertain-answer; answer helper failed without final status")))

(ert-deftest emacsos-openrc-call-finished-prefixes-helper-failure ()
  (let ((buffer (generate-new-buffer " *test-call-error*"))
        delivered)
    (with-current-buffer buffer (insert "modem rejected"))
    (cl-letf (((symbol-function 'process-status) (lambda (_) 'exit))
              ((symbol-function 'process-buffer) (lambda (_) buffer))
              ((symbol-function 'process-exit-status) (lambda (_) 1)))
      (emacsos-pinephone-call-finished
       'process "failed" 'dial (lambda (status) (setq delivered status))))
    (should (equal delivered "error: modem rejected"))
    (should-not (buffer-live-p buffer))))

(ert-deftest emacsos-openrc-call-operation-cleans-buffer-after-launch-failure ()
  (let ((before (buffer-list)))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _) (error "cannot launch"))))
      (should (string-prefix-p
               "error: call helper failed:"
               (emacsos-pinephone-call-operation 'hangup nil nil)))
      (should (equal (buffer-list) before)))))

(ert-deftest emacsos-openrc-call-operation-needs-stable-owner-before-launch ()
  (let ((before (buffer-list)) launched)
    (cl-letf (((symbol-function 'emacsos-call--modem-manager-owner)
               (lambda () ":1.fallback"))
              ((symbol-function 'make-process)
               (lambda (&rest _) (setq launched t))))
      (should (equal
               (emacsos-pinephone-call-operation
                'dial nil "+14155550123")
               "error: ModemManager owner unavailable"))
      (should-not launched)
      (should (equal (buffer-list) before)))))

(ert-deftest emacsos-openrc-call-audio-is-bounded-and-asynchronous ()
  (let (seen
        (emacsos-pinephone-call-audio-process nil)
        (emacsos-pinephone-call-audio-desired nil))
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args) (setq seen args) 'process)))
      (emacsos-pinephone-call-audio t)
      (should (equal (plist-get seen :command)
                     '("/usr/bin/timeout" "-s" "TERM" "-k" "1" "5"
                       "/usr/bin/callaudiocli" "-m" "1")))
      (should (functionp (plist-get seen :sentinel))))))

(ert-deftest emacsos-openrc-call-audio-coalesces-to-latest-state ()
  "A stale enable cannot finish after a requested normal-audio transition."
  (let ((emacsos-pinephone-call-audio-process nil)
        (emacsos-pinephone-call-audio-desired nil)
        starts)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args)
                 (push args starts)
                 (if (= (length starts) 1) 'first 'second)))
              ((symbol-function 'process-status) (lambda (_) 'exit))
              ((symbol-function 'process-buffer)
               (lambda (process)
                 (plist-get (if (eq process 'first) (car (last starts))
                              (car starts))
                            :buffer)))
              ((symbol-function 'process-exit-status) (lambda (_) 0)))
      (emacsos-pinephone-call-audio t)
      (emacsos-pinephone-call-audio nil)
      (should (= (length starts) 1))
      (funcall (plist-get (car starts) :sentinel) 'first "finished")
      (should (= (length starts) 2))
      (should (equal (car (last (plist-get (car starts) :command))) "0"))
      (should (eq emacsos-pinephone-call-audio-process 'second)))))

(ert-deftest emacsos-openrc-wake-display-is-asynchronous ()
  (let ((emacsos-pinephone-wake-process nil) started noquery sentinel)
    (cl-letf (((symbol-function 'start-process)
               (lambda (&rest args) (setq started args) 'process))
              ((symbol-function 'process-live-p) (lambda (_) nil))
              ((symbol-function 'set-process-query-on-exit-flag)
               (lambda (_process value) (setq noquery (not value))))
              ((symbol-function 'set-process-sentinel)
               (lambda (_process value) (setq sentinel value))))
      (emacsos-pinephone-wake-display)
      (should (equal started
                     '("emacsos-call-wake" nil
                       "/usr/local/share/emacsos-openrc/session-power" "wake")))
      (should noquery)
      (should (functionp sentinel)))))

(ert-deftest emacsos-openrc-wake-display-coalesces-an-outstanding-helper ()
  (let ((emacsos-pinephone-wake-process 'running) started)
    (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
              ((symbol-function 'start-process)
               (lambda (&rest _) (setq started t))))
      (emacsos-pinephone-wake-display)
      (should-not started))))

(ert-deftest emacsos-openrc-network-command-allows-only-ui-actions ()
  (should (equal
           (emacsos-pinephone-network-command '("radio" "wifi" "off"))
           '("/usr/bin/doas" "-n" "/usr/local/sbin/emacsos-openrc-network"
             "wifi" "off")))
  (should (equal
           (emacsos-pinephone-network-command
            '("con" "up" "emacsos-cellular"))
           '("/usr/bin/doas" "-n" "/usr/local/sbin/emacsos-openrc-network"
             "cell" "up")))
  (should-error
   (emacsos-pinephone-network-command '("general" "permissions")))
  (should-error
   (emacsos-pinephone-network-command '("con" "up" "profile-name")))
  (should-error
   (emacsos-pinephone-network-command '("dev" "wifi" "connect" "SSID"))))

(ert-deftest emacsos-openrc-wifi-operation-keeps-password-off-argv ()
  (let (seen-command seen-input eof)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args)
                 (setq seen-command (plist-get args :command))
                 'wifi-process))
              ((symbol-function 'process-send-string)
               (lambda (_process value)
                 (setq seen-input (copy-sequence value))))
              ((symbol-function 'process-send-eof)
               (lambda (_process) (setq eof t))))
      (should (equal
               (emacsos-pinephone-wifi-operation
                'secured "Cafe network" "Exact password" #'ignore)
               "pending: Wi-Fi connection requested"))
      (should (equal seen-command
                     '("/usr/bin/doas" "-n"
                       "/usr/local/sbin/emacsos-openrc-wifi-connect")))
      (should-not (member "Cafe network" seen-command))
      (should-not (member "Exact password" seen-command))
      (let* ((json-object-type 'alist)
             (payload (json-read-from-string seen-input)))
        (should (equal (alist-get 'ssid payload) "Cafe network"))
        (should (equal (alist-get 'password payload) "Exact password")))
      (should eof))))

(ert-deftest emacsos-openrc-wifi-saved-operation-uses-fixed-helper ()
  (let (seen-command sent)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args)
                 (setq seen-command (plist-get args :command))
                 'wifi-process))
              ((symbol-function 'process-send-string)
               (lambda (&rest _) (setq sent t)))
              ((symbol-function 'process-send-eof) #'ignore))
      (should (equal
               (emacsos-pinephone-wifi-operation
                'saved "11111111-2222-3333-4444-555555555555" nil #'ignore)
               "pending: Wi-Fi connection requested"))
      (should (equal seen-command
                     '("/usr/bin/doas" "-n"
                       "/usr/local/sbin/emacsos-openrc-network" "saved"
                       "11111111-2222-3333-4444-555555555555")))
      (should-not sent))))

(ert-deftest emacsos-openrc-wifi-result-is-strict ()
  (should (equal (emacsos-pinephone-wifi-result "connected\n" t)
                 "connected"))
  (should (equal (emacsos-pinephone-wifi-result
                  "not-connected:busy\n" nil)
                 "not-connected:busy"))
  (dolist (case '(("connected\n" nil) ("connected" t)
                  ("connected\nextra\n" t) ("invented\n" nil)))
    (should (equal (emacsos-pinephone-wifi-result (car case) (cadr case))
                   "not-connected:failed"))))

(ert-deftest emacsos-openrc-wifi-finished-delivers-one-finite-result ()
  (dolist (case '(("connected\n" 0 "connected")
                  ("not-connected:busy\n" 1 "not-connected:busy")
                  ("connected\nextra\n" 0 "not-connected:failed")
                  ("connected\n" 1 "not-connected:failed")))
    (let ((buffer (generate-new-buffer " *test-wifi-result*"))
          (stderr-buffer (generate-new-buffer " *test-wifi-stderr*"))
          delivered)
      (with-current-buffer buffer (insert (nth 0 case)))
      (cl-letf (((symbol-function 'process-status) (lambda (_) 'exit))
                ((symbol-function 'process-buffer) (lambda (_) buffer))
                ((symbol-function 'process-exit-status)
                 (lambda (_) (nth 1 case))))
        (emacsos-pinephone-wifi-finished
         'process "finished" (lambda (result) (setq delivered result))
         stderr-buffer))
      (should (equal delivered (nth 2 case)))
      (should-not (buffer-live-p buffer))
      (should-not (buffer-live-p stderr-buffer)))))

(ert-deftest emacsos-openrc-firefox-nonterminal-sentinel-keeps-tracking ()
  (let ((emacsos-pinephone-firefox-process 'tracked))
    (cl-letf (((symbol-function 'process-status) (lambda (_process) 'run)))
      (emacsos-pinephone-firefox-finished 'tracked "changed"))
    (should (eq emacsos-pinephone-firefox-process 'tracked))))

(ert-deftest emacsos-openrc-old-firefox-sentinel-keeps-new-process ()
  (let ((emacsos-pinephone-firefox-process 'new))
    (cl-letf (((symbol-function 'process-status) (lambda (_process) 'exit)))
      (emacsos-pinephone-firefox-finished 'old "finished")
      (should (eq emacsos-pinephone-firefox-process 'new)))))

(ert-deftest emacsos-openrc-firefox-focus-failure-is-visible ()
  (let ((emacsos-pinephone-firefox-process 'tracked)
        (process-environment (copy-sequence process-environment))
        call-arguments
        message-text)
    (setenv "SWAYSOCK" "/run/user/1000/sway.sock")
    (cl-letf (((symbol-function 'process-live-p) (lambda (_process) t))
              ((symbol-function 'call-process)
               (lambda (&rest args)
                 (setq call-arguments args)
                 "killed by signal 15"))
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (setq message-text (apply #'format format-string args)))))
      (emacsos-firefox-start)
      (should (equal call-arguments
                     '("/usr/bin/timeout" nil nil nil
                       "-s" "TERM" "-k" "1" "3"
                       "/usr/bin/swaymsg" "-s"
                       "/run/user/1000/sway.sock"
                       "[app_id=\"firefox\"] focus")))
      (should (equal message-text "Firefox window is not ready.")))))

(ert-deftest emacsos-openrc-firefox-quit-targets-only-live-tracked-process ()
  (let ((emacsos-pinephone-firefox-process 'tracked)
        signaled message-text)
    (cl-letf (((symbol-function 'process-live-p) (lambda (_process) t))
              ((symbol-function 'signal-process)
               (lambda (process signal) (setq signaled (list process signal))))
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (setq message-text (apply #'format format-string args)))))
      (emacsos-firefox-quit)
      (should (equal signaled '(tracked SIGTERM)))
      (should (equal message-text "Closing Firefox...")))))

(ert-deftest emacsos-openrc-firefox-quit-without-process-is-harmless ()
  (let ((emacsos-pinephone-firefox-process nil)
        signaled message-text)
    (cl-letf (((symbol-function 'signal-process)
               (lambda (process signal) (setq signaled (list process signal))))
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (setq message-text (apply #'format format-string args)))))
      (emacsos-firefox-quit)
      (should-not signaled)
      (should (equal message-text "Firefox is not open.")))))

(ert-deftest emacsos-openrc-firefox-quit-tolerates-an-exit-race ()
  (let ((emacsos-pinephone-firefox-process 'tracked)
        message-text)
    (cl-letf (((symbol-function 'process-live-p) (lambda (_process) t))
              ((symbol-function 'signal-process)
               (lambda (_process _signal) (error "already exited")))
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (setq message-text (apply #'format format-string args)))))
      (emacsos-firefox-quit)
      (should-not emacsos-pinephone-firefox-process)
      (should (equal message-text "Firefox is not open.")))))

(ert-deftest emacsos-openrc-firefox-launch-failure-is-visible ()
  (let (message-text)
    (cl-letf (((symbol-function 'start-process)
               (lambda (&rest _arguments) (signal 'file-error nil)))
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (setq message-text (apply #'format format-string args)))))
      (emacsos-firefox-start)
      (should-not emacsos-pinephone-firefox-process)
      (should (equal message-text "Firefox could not start.")))))

(ert-deftest emacsos-openrc-waydroid-nonterminal-sentinel-keeps-tracking ()
  (let ((emacsos-pinephone-waydroid-process 'tracked))
    (cl-letf (((symbol-function 'process-status) (lambda (_process) 'run)))
      (emacsos-pinephone-waydroid-finished 'tracked "changed"))
    (should (eq emacsos-pinephone-waydroid-process 'tracked))))

(ert-deftest emacsos-openrc-old-waydroid-sentinel-keeps-new-process ()
  (let ((emacsos-pinephone-waydroid-process 'new))
    (cl-letf (((symbol-function 'process-status) (lambda (_process) 'exit)))
      (emacsos-pinephone-waydroid-finished 'old "finished")
      (should (eq emacsos-pinephone-waydroid-process 'new)))))

(ert-deftest emacsos-openrc-waydroid-focus-failure-is-visible ()
  (let ((emacsos-pinephone-waydroid-process 'tracked)
        (emacsos-pinephone-waydroid-config "/etc/passwd")
        (process-environment (copy-sequence process-environment))
        call-arguments
        message-text)
    (setenv "SWAYSOCK" "/run/user/1000/sway.sock")
    (cl-letf (((symbol-function 'process-live-p) (lambda (_process) t))
              ((symbol-function 'call-process)
               (lambda (&rest args)
                 (setq call-arguments args)
                 1))
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (setq message-text (apply #'format format-string args)))))
      (emacsos-android-start)
      (should (equal call-arguments
                     '("/usr/bin/timeout" nil nil nil
                       "-s" "TERM" "-k" "1" "3"
                       "/usr/bin/swaymsg" "-s"
                       "/run/user/1000/sway.sock"
                       "[app_id=\"Waydroid\"] focus")))
      (should (equal message-text "Android window is not ready.")))))

(ert-deftest emacsos-openrc-waydroid-reports-missing-images-without-starting ()
  (let (started message-text)
    (cl-letf (((symbol-function 'file-exists-p) (lambda (_path) nil))
              ((symbol-function 'start-process)
               (lambda (&rest _arguments) (setq started t)))
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (setq message-text (apply #'format format-string args)))))
      (emacsos-android-start)
      (should-not started)
      (should (equal message-text "Android images are not installed.")))))

(ert-deftest emacsos-openrc-waydroid-launch-failure-is-visible ()
  (let ((emacsos-pinephone-waydroid-config "/etc/passwd")
        message-text)
    (cl-letf (((symbol-function 'file-exists-p) (lambda (_path) t))
              ((symbol-function 'start-process)
               (lambda (&rest _arguments) (signal 'file-error nil)))
              ((symbol-function 'message)
               (lambda (format-string &rest args)
                 (setq message-text (apply #'format format-string args)))))
      (emacsos-android-start)
      (should-not emacsos-pinephone-waydroid-process)
      (should (equal message-text "Android could not start.")))))

(ert-deftest emacsos-openrc-sms-operation-uses-fixed-argv-and-stdin ()
  (let (seen-command seen-input eof)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args)
                 (setq seen-command (plist-get args :command))
                 'sms-process))
              ((symbol-function 'process-send-string)
               (lambda (_process text) (setq seen-input text)))
              ((symbol-function 'process-send-eof)
               (lambda (_process) (setq eof t))))
      (should (equal
               (emacsos-pinephone-sms-operation
                "+14155550123" "Exact “message”" #'ignore)
               "pending: SMS requested"))
      (should (equal seen-command
                     '("/usr/bin/doas" "-n"
                       "/usr/local/sbin/emacsos-openrc-sms")))
      (should-not (member "+14155550123" seen-command))
      (should-not (member "Exact “message”" seen-command))
      (let* ((json-object-type 'alist)
             (payload (json-read-from-string seen-input)))
        (should (equal (alist-get 'number payload) "+14155550123"))
        (should (equal (alist-get 'text payload) "Exact “message”")))
      (should eof))))

(ert-deftest emacsos-openrc-sms-result-is-strict-and-conservative ()
  (should (equal (emacsos-pinephone-sms-result "sent" t) "sent"))
  (should (equal (emacsos-pinephone-sms-result "not-sent:busy" nil)
                 "not-sent:busy"))
  (should (equal (emacsos-pinephone-sms-result "not-sent:time-limit" nil)
                 "not-sent:time-limit"))
  (should (equal (emacsos-pinephone-sms-result "unknown:send-failed" nil)
                 "unknown:send-failed"))
  (dolist (case '(("sent" nil) ("sent\nextra" t)
                  ("not-sent:invented" nil) ("" nil)))
    (should (equal (emacsos-pinephone-sms-result (car case) (cadr case))
                   "unknown:dbus-unavailable"))))

(ert-deftest emacsos-openrc-sms-finished-requires-one-exact-result-line ()
  (dolist (case '(("sent\n" 0 "sent")
                  (" sent\n" 0 "unknown:dbus-unavailable")
                  ("sent\n\n" 0 "unknown:dbus-unavailable")
                  ("sent" 0 "unknown:dbus-unavailable")
                  ("not-sent:busy\n" 1 "not-sent:busy")))
    (let ((buffer (generate-new-buffer " *test-sms-result*"))
          (stderr-buffer (generate-new-buffer " *test-sms-stderr*"))
          delivered)
      (with-current-buffer buffer (insert (nth 0 case)))
      (cl-letf (((symbol-function 'process-status) (lambda (_) 'exit))
                ((symbol-function 'process-buffer) (lambda (_) buffer))
                ((symbol-function 'process-exit-status)
                 (lambda (_) (nth 1 case))))
        (emacsos-pinephone-sms-finished
         'process "finished" (lambda (status) (setq delivered status))
         stderr-buffer))
      (should (equal delivered (nth 2 case)))
      (should-not (buffer-live-p buffer))
      (should-not (buffer-live-p stderr-buffer)))))

(ert-run-tests-batch-and-exit)
;;; test-pinephone-openrc-init.el ends here
