;;; test-pinephone-openrc-init.el --- PinePhone OpenRC bootstrap tests -*- lexical-binding: t; -*-

(require 'ert)
(require 'cl-lib)
(load-file (expand-file-name "../deploy/pinephone/openrc-init.el"
                             (file-name-directory load-file-name)))

(ert-deftest emacsos-openrc-home-is-editable-and-touchable ()
  (let ((buffer (emacsos-pinephone-openrc-home)))
    (unwind-protect
        (with-current-buffer buffer
          (should-not buffer-read-only)
          (should (= (point-min) (window-point (selected-window))))
          (goto-char (point-min))
          (should (search-forward "Open Firefox" nil t))
          (let ((button (button-at (1- (point)))))
            (should button)
            (should (eq (lookup-key (button-get button 'keymap) [mouse-1])
                        'push-button)))
          (should (search-forward "Firefox is closed." nil t))
          (should (search-forward "Open Android" nil t))
          (should (search-forward "Stop Android" nil t))
          (should (search-forward "Android is stopped." nil t)))
      (kill-buffer buffer))))

(ert-deftest emacsos-openrc-firefox-status-is-visible ()
  (let ((buffer (emacsos-pinephone-openrc-home)))
    (unwind-protect
        (progn
          (emacsos-pinephone-set-status
           emacsos-pinephone-firefox-status-marker "Starting Firefox...")
          (with-current-buffer buffer
            (goto-char (point-min))
            (should (search-forward "Starting Firefox..." nil t))
            (should-not (search-forward "Firefox is closed." nil t))))
      (kill-buffer buffer))))

(ert-deftest emacsos-openrc-fixed-input-marker-is-inserted ()
  (let ((buffer (emacsos-pinephone-openrc-home)))
    (unwind-protect
        (with-current-buffer buffer
          (emacsos-pinephone-record-synthetic-input)
          (goto-char (point-min))
          (should (search-forward "[synthetic-input]" nil t)))
      (kill-buffer buffer))))

(ert-deftest emacsos-openrc-wakeup-event-is-silent ()
  (should (eq (lookup-key global-map [WakeUp]) #'ignore)))

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
  (let (started noquery)
    (cl-letf (((symbol-function 'start-process)
               (lambda (&rest args) (setq started args) 'process))
              ((symbol-function 'set-process-query-on-exit-flag)
               (lambda (_process value) (setq noquery (not value)))))
      (emacsos-pinephone-wake-display)
      (should (equal started
                     '("emacsos-call-wake" nil
                       "/usr/local/share/emacsos-openrc/session-power" "wake")))
      (should noquery))))

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
  (let ((buffer (emacsos-pinephone-openrc-home))
        (emacsos-pinephone-firefox-process 'tracked))
    (unwind-protect
        (progn
          (emacsos-pinephone-set-status
           emacsos-pinephone-firefox-status-marker "Starting Firefox...")
          (cl-letf (((symbol-function 'process-status) (lambda (_process) 'run)))
            (emacsos-pinephone-firefox-finished 'tracked "changed"))
          (should (eq emacsos-pinephone-firefox-process 'tracked))
          (with-current-buffer buffer
            (goto-char (point-min))
            (should (search-forward "Starting Firefox..." nil t))))
      (kill-buffer buffer))))

(ert-deftest emacsos-openrc-old-firefox-sentinel-keeps-new-process ()
  (let ((buffer (emacsos-pinephone-openrc-home))
        (emacsos-pinephone-firefox-process 'new))
    (unwind-protect
        (cl-letf (((symbol-function 'process-status) (lambda (_process) 'exit)))
          (emacsos-pinephone-firefox-finished 'old "finished")
          (should (eq emacsos-pinephone-firefox-process 'new)))
      (kill-buffer buffer))))

(ert-deftest emacsos-openrc-firefox-focus-failure-is-visible ()
  (let ((buffer (emacsos-pinephone-openrc-home))
        (emacsos-pinephone-firefox-process 'tracked))
    (unwind-protect
        (cl-letf (((symbol-function 'process-live-p) (lambda (_process) t))
                  ((symbol-function 'call-process) (lambda (&rest _args) 1)))
          (emacsos-pinephone-open-firefox)
          (with-current-buffer buffer
            (goto-char (point-min))
            (should (search-forward "Firefox window is not ready." nil t))))
      (kill-buffer buffer))))

(ert-deftest emacsos-openrc-waydroid-readiness-can-span-output-chunks ()
  (let ((buffer (emacsos-pinephone-openrc-home))
        (emacsos-pinephone-waydroid-process 'tracked)
        (properties nil))
    (unwind-protect
        (cl-letf (((symbol-function 'process-get)
                   (lambda (_process property) (alist-get property properties)))
                  ((symbol-function 'process-put)
                   (lambda (_process property value)
                     (setf (alist-get property properties) value))))
          (emacsos-pinephone-waydroid-output 'tracked "Android with user ")
          (emacsos-pinephone-waydroid-output 'tracked "0 is ready\n")
          (with-current-buffer buffer
            (goto-char (point-min))
            (should (search-forward "Android is open." nil t))))
      (kill-buffer buffer))))

(ert-deftest emacsos-openrc-waydroid-nonterminal-sentinel-keeps-tracking ()
  (let ((buffer (emacsos-pinephone-openrc-home))
        (emacsos-pinephone-waydroid-process 'tracked))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'process-status) (lambda (_process) 'run)))
            (emacsos-pinephone-waydroid-finished 'tracked "changed"))
          (should (eq emacsos-pinephone-waydroid-process 'tracked)))
      (kill-buffer buffer))))

(ert-deftest emacsos-openrc-waydroid-focus-failure-is-visible ()
  (let ((buffer (emacsos-pinephone-openrc-home))
        (emacsos-pinephone-waydroid-process 'tracked)
        (emacsos-pinephone-waydroid-config "/etc/passwd"))
    (unwind-protect
        (cl-letf (((symbol-function 'process-live-p) (lambda (_process) t))
                  ((symbol-function 'call-process) (lambda (&rest _args) 1)))
          (emacsos-pinephone-open-waydroid)
          (with-current-buffer buffer
            (goto-char (point-min))
            (should (search-forward "Android window is not ready." nil t))))
      (kill-buffer buffer))))

(ert-deftest emacsos-openrc-waydroid-reports-missing-images-without-starting ()
  (let ((buffer (emacsos-pinephone-openrc-home))
        (started nil))
    (unwind-protect
        (cl-letf (((symbol-function 'file-exists-p) (lambda (_path) nil))
                  ((symbol-function 'start-process)
                   (lambda (&rest _arguments) (setq started t))))
          (emacsos-pinephone-open-waydroid)
          (should-not started)
          (with-current-buffer buffer
            (goto-char (point-min))
            (should (search-forward "Android images are not installed." nil t))))
      (kill-buffer buffer))))

(ert-run-tests-batch-and-exit)
;;; test-pinephone-openrc-init.el ends here
