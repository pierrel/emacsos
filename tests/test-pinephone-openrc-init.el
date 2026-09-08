;;; test-pinephone-openrc-init.el --- PinePhone OpenRC bootstrap tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(load-file (expand-file-name "../deploy/pinephone/openrc-init.el"
                             (file-name-directory load-file-name)))

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
               (lambda (_) '((comm . "wvkbd-emacos") (user . "emacsos-lab"))))
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
                     "^/usr/local/bin/wvkbd-emacos --mod-swipe -H 300 -L 300$")))))

(ert-deftest emacsos-openrc-keyboard-validates-pid-locally ()
  (let (directory)
    (let ((default-directory "/ssh:thinky:"))
      (cl-letf (((symbol-function 'process-attributes)
                 (lambda (_)
                   (setq directory default-directory)
                   '((comm . "wvkbd-emacos") (user . "emacsos-lab")))))
        (should (emacsos-pinephone-valid-wvkbd-pid-p "43"))))
    (should (equal directory "/"))))

(ert-deftest emacsos-openrc-keyboard-rejects-stock-process ()
  (cl-letf (((symbol-function 'process-attributes)
             (lambda (_)
               '((comm . "wvkbd-mobintl") (user . "emacsos-lab")))))
    (should-not (emacsos-pinephone-valid-wvkbd-pid-p "43"))))

(ert-deftest emacsos-openrc-keyboard-mode-line-label-tracks-state ()
  (let ((emacsos-pinephone-keyboard-hidden nil))
    (should (equal (substring-no-properties
                    (emacsos-pinephone-keyboard-mode-line-string))
                   "  kbd hide"))
    (setq emacsos-pinephone-keyboard-hidden t)
    (should (equal (substring-no-properties
                    (emacsos-pinephone-keyboard-mode-line-string))
                   "  kbd show"))))

(ert-deftest emacsos-openrc-frame-layout-finalizer-maximizes-frame ()
  (let (seen)
    (cl-letf (((symbol-function 'set-frame-parameter)
               (lambda (frame parameter value)
                 (setq seen (list frame parameter value)))))
      (emacsos-pinephone-enforce-frame-layout)
      (should (equal seen '(nil fullscreen maximized))))))

(ert-deftest emacsos-openrc-registers-frame-layout-finalizer ()
  (should (eq (symbol-function 'emacsos-pinephone-enforce-frame-layout)
              emacos-agent-config-applied-function)))

(ert-deftest emacsos-openrc-agent-config-finalizer-survives-config-mutation ()
  (let ((file (make-temp-file "emacsos-agent-" nil ".el"))
        (emacos-agent-config-applied-function
         (symbol-function 'emacsos-pinephone-enforce-frame-layout))
        seen)
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "(setq emacos-agent-config-applied-function #'ignore)\n"))
          (cl-letf (((symbol-function 'set-frame-parameter)
                     (lambda (frame parameter value)
                       (setq seen (list frame parameter value)))))
            (emacsos-pinephone-load-agent-config file))
          (should (equal seen '(nil fullscreen maximized)))
          (should (eq emacos-agent-config-applied-function
                      (symbol-function
                       'emacsos-pinephone-enforce-frame-layout))))
      (delete-file file))))

(ert-deftest emacsos-openrc-agent-config-finalizer-runs-after-quit ()
  (let ((file (make-temp-file "emacsos-agent-" nil ".el"))
        finalized)
    (let ((emacos-agent-config-applied-function
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
              ((symbol-function 'emacos-call--modem-manager-owner)
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
          (emacos-call--call-owner ":1.42"))
      (cl-letf (((symbol-function 'make-process)
                 (lambda (&rest args) (setq seen args) 'process))
                ((symbol-function 'emacos-call--modem-manager-owner)
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
    (cl-letf (((symbol-function 'emacos-call--modem-manager-owner)
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
   (emacsos-pinephone-network-command '("general" "permissions"))))

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
