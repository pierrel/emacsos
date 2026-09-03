;;; test-pinephone-openrc-init.el --- Tests for the minimal OpenRC home -*- lexical-binding: t; -*-

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
