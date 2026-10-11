;;; test-phone-typography.el --- Native graphical typography checks -*- lexical-binding: t; -*-
;; Run through test-phone-typography.sh in an isolated graphical Emacs.
(condition-case err
    (progn
      (require 'ert)
      (require 'cl-lib)
      (require 'json)
      (setq emacsos-use-internal-keyboard nil)
      (require 'os)
      (remove-hook 'window-setup-hook #'emacsos--init)

      ;; Evaluate selected typography and Controls row functions without phone services.
      (with-temp-buffer
	(insert-file-contents "deploy/pinephone/openrc-init.el")
	(goto-char (point-min))
	(condition-case nil
	    (while t
              (let ((form (read (current-buffer))))
		(when (and (eq (car-safe form) 'defun)
			   (memq (cadr form) '(emacsos-pinephone-apply-typography
					       emacsos-pinephone-buffer-typography
					       emacsos-pinephone-display-typography
                                               emacsos-pinephone-controls--bounded
                                               emacsos-pinephone-controls--insert-row)))
		  (eval form t))))
	  (end-of-file nil)))

      (menu-bar-mode -1)
      (tool-bar-mode -1)
      (scroll-bar-mode -1)
      (setq frame-resize-pixelwise t)
      (emacsos-pinephone-apply-typography)
      ;; X11 adds 16 fringe pixels and two border pixels to this text-area size.
(set-frame-size (selected-frame) 342 718 t)

      (defun typography-test-font-family (position &optional window)
	"Return the real graphical font family at POSITION."
	(let ((window (or window (selected-window))))
	  (with-current-buffer (window-buffer window)
	    (format "%s" (font-get (font-at position window) :family)))))

      (ert-deftest phone-typography-prose-code-and-mode-line-fonts ()
	(let ((buffer (generate-new-buffer " *typography*")))
	  (unwind-protect
              (progn
		(switch-to-buffer buffer)
		(insert "Inter prose\n")
		(insert (propertize "fixed-width code\n" 'face 'emacsos-chat-code-face))
		(redisplay t)
		(should (equal (typography-test-font-family 1) "Inter"))
		(should (equal (typography-test-font-family 13) "JetBrains Mono"))
		(emacs-lisp-mode)
		(redisplay t)
		(should (equal (typography-test-font-family 1) "JetBrains Mono"))
		(fundamental-mode)
		(redisplay t)
		(should (equal (typography-test-font-family 1) "Inter"))
		(emacs-lisp-mode)
		(should (equal (face-attribute 'mode-line :family) "Inter"))
		(should (equal (face-attribute 'mode-line-inactive :family) "Inter"))
		;; Reapplying startup defaults does not duplicate hooks or lose code.
		(emacsos-pinephone-apply-typography)
		(should (= 1 (cl-count #'emacsos-pinephone-buffer-typography
                                       after-change-major-mode-hook)))
		(redisplay t)
		(should (equal (typography-test-font-family 1) "JetBrains Mono")))
	    (kill-buffer buffer))))

      (ert-deftest phone-typography-color-customization-keeps-real-fonts ()
        (let* ((faces '(variable-pitch mode-line mode-line-inactive header-line default fixed-pitch))
               (before (mapcar (lambda (face)
                                 (list face (face-attribute face :family nil)
                                       (face-attribute face :height nil)
                                       (face-attribute face :foreground nil)
                                       (get face 'customized-face) (get face 'saved-face))) faces))
               (buffer (generate-new-buffer " *typography-color*")))
          (unwind-protect
              (progn
                (dolist (face faces)
                  (custom-set-faces (list face '((t (:foreground "red"))))))
                (emacsos-pinephone-apply-typography)
                (switch-to-buffer buffer)
                (insert "Inter prose\n" (propertize "Fixed code" 'face 'emacsos-chat-code-face))
                (redisplay t)
                (should (equal (typography-test-font-family 1) "Inter"))
                (should (equal (typography-test-font-family 13) "JetBrains Mono"))
                (dolist (face faces)
                  (should (equal (face-attribute face :family nil)
                                 (if (memq face '(default fixed-pitch)) "JetBrains Mono" "Inter")))
                  (should (equal (face-attribute face :foreground nil) "red")))
                (custom-set-faces '(variable-pitch ((t (:family "JetBrains Mono"))))
                                  '(default ((t (:height 180)))))
                (face-spec-set 'variable-pitch '((t (:family "JetBrains Mono"))) 'saved-face)
                (face-spec-set 'default '((t (:height 180))) 'saved-face)
                (dolist (face '(variable-pitch default))
                  (face-spec-set face '((t (:foreground "red"))) 'customized-face))
                (redisplay t)
                ;; Native font sizes can round; preserve the realized user height.
                (let ((height (face-attribute 'default :height nil)))
                  (emacsos-pinephone-apply-typography)
                  (redisplay t)
                  (should (equal (typography-test-font-family 1) "JetBrains Mono"))
                  (should (= (face-attribute 'default :height nil) height))))
            (kill-buffer buffer)
            (dolist (snapshot before)
              (let ((face (car snapshot)))
                (put face 'customized-face (nth 4 snapshot)) (put face 'saved-face (nth 5 snapshot))
                (set-face-attribute face nil :family (nth 1 snapshot) :height (nth 2 snapshot)
                                    :foreground (nth 3 snapshot)))))))

      (ert-deftest phone-typography-nonselected-ui-buffer-and-startup-sweep ()
	(let ((prose (generate-new-buffer " *typography-nonselected*"))
              (code (generate-new-buffer " *typography-selected*")))
	  (unwind-protect
              (progn
		(with-current-buffer prose (insert "Existing UI prose"))
		(with-current-buffer code (insert "Code") (emacs-lisp-mode))
		(switch-to-buffer code)
		(let ((other (split-window-right)))
		  (set-window-buffer other prose)
		  (redisplay t)
		  (should (equal (typography-test-font-family 1 other) "Inter"))
		  (should (equal (typography-test-font-family 1) "JetBrains Mono"))
		  (with-current-buffer prose (buffer-face-mode -1))
		  (emacsos-pinephone-apply-typography)
		  (redisplay t)
		  (should (equal (typography-test-font-family 1 other) "Inter")))
		(delete-other-windows))
	    (kill-buffer prose)
	    (kill-buffer code))))

      (ert-deftest phone-typography-action-rows-fit-and-padding-is-clickable ()
	(let ((buffer (generate-new-buffer " *typography-buttons*"))
              activated)
	  (unwind-protect
              (progn
		(switch-to-buffer buffer)
		(let ((width (window-body-width)))
		  (dolist (labels '(("QUIT" "Refresh" "Send")
				    ("MMMMMMMMMMMMMMMMMMMMMMMM" "M-x" "ABORT")
				    ("Confirm answer?")
				    ("WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW")))
		    (erase-buffer)
		    (let* ((count (length labels))
			   (unit (emacsos--unit-width width emacsos--btn-gap
						      count (1- count))))
                      (dolist (label labels)
			(unless (= (point) (point-min))
			  (insert (propertize " " 'display
                                              `(space :width ,emacsos--btn-gap))))
			(emacsos--btn (emacsos--center label unit)
				      (lambda () (setq activated t))
				      nil emacsos--btn-label-scale))
                      (insert "\n")
                      (goto-char (point-min))
                      (redisplay t)
                      (should (<= (car (window-text-pixel-size
					nil (point-min) (1- (point-max)) 10000))
				  (window-body-width nil t)))
                      (vertical-motion 1)
                      (should (>= (point) (1- (point-max))))
                      (should (equal (typography-test-font-family 2) "Inter"))
                      ;; Padding shares the button's action and complete hit target.
                      (goto-char (point-min))
                      (should (button-at (point)))
                      (button-activate (button-at (point)))
                      (should activated)
                      (setq activated nil))))
		(erase-buffer)
		(insert (emacsos-assist-web--fit-list-line
			 "WWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWWW"
			 (window-body-width)))
		(redisplay t)
		(should (<= (car (window-text-pixel-size nil nil nil 10000))
			    (window-body-width nil t))))
	    (kill-buffer buffer))))

      (ert-deftest phone-typography-long-titles-have-bounded-measurement ()
	(let ((original (symbol-function 'string-pixel-width))
              (calls 0)
              fitted)
	  (cl-letf (((symbol-function 'string-pixel-width)
		     (lambda (text)
                       (setq calls (1+ calls))
                       (funcall original text))))
		   (setq fitted (emacsos--fit-pixel-width (make-string 512 ?W) 40)))
	  (should (<= calls 16))
	  (should (<= (string-pixel-width (propertize fitted 'face 'variable-pitch))
                      40))
	  (should (string-suffix-p "…" fitted))))

      (ert-deftest phone-typography-controls-wide-status-keeps-actions-visible ()
        (let ((buffer (generate-new-buffer " *typography-controls*")))
          (unwind-protect
              (progn
                (switch-to-buffer buffer)
                (setq-local truncate-lines t)
                (emacsos-pinephone-controls--insert-row
                 "WiFi" (make-string 32 ?W)
                 '(("Off" ignore nil) ("Networks" ignore nil)) 2)
                (goto-char (point-min))
                (redisplay t)
                (should (equal (typography-test-font-family 1) "Inter"))
                (should (<= (car (window-text-pixel-size
                                 nil (point-min) (1- (point-max)) 10000))
                            (window-body-width nil t)))
                (let* ((off (next-button (point-min) t))
                       (networks (and off (next-button (button-end off)))))
                  (should off)
                  (should networks)
                  ;; The existing seven-cell action budget may abbreviate Networks.
                  (should (string-match-p "Off" (button-label off)))
                  (should (string-match-p "Net" (button-label networks)))
                  (should (equal (typography-test-font-family (button-start networks))
                                 "Inter"))))
            (kill-buffer buffer))))

      (ert-deftest phone-typography-armed-key-highlights-actual-letter ()
        (let ((buffer (generate-new-buffer " *typography-armed*")))
          (unwind-protect
              (progn
                (switch-to-buffer buffer)
                (dolist (case '(("m" 0) ("qw" 1) ("ertyui" 5)))
                  (erase-buffer)
                  (let* ((group (car case))
                         (index (cadr case))
                         (emacsos--modifier 'C)
                         (emacsos--armed-tap (list :group group :index index)))
                    (cl-letf (((symbol-function 'emacsos--active-layout)
                               (lambda () (list (list group))))
                              ((symbol-function 'emacsos--bound-groups)
                               (lambda (&rest _) (list (list group))))
                              ((symbol-function 'emacsos--target)
                               (lambda () (selected-window))))
                      (emacsos--render-keyboard))
                    (goto-char (point-min))
                    (should (search-forward group nil t))
                    (let ((position (+ (- (point) (length group)) index)))
                      (should (string-match-p
                               "yellow" (format "%S" (get-text-property position 'face))))))
                  (redisplay t)))
            (kill-buffer buffer))))

      (let* ((result (ert-run-tests-batch t))
	     (failed (ert-stats-completed-unexpected result)))
	(with-temp-file "/proof/inter-native-result.json"
	  (insert (json-encode `((graphical . ,(display-graphic-p))
				 (frame_pixels . [,(frame-pixel-width)
						  ,(frame-pixel-height)])
				 (body_width_pixels . ,(window-body-width nil t))
				 (frame_char_width . ,(frame-char-width))
				 (tests . ,(ert-stats-total result))
				 (failed . ,failed)))))
	(with-temp-file "/proof/emacs-messages.log"
	  (insert (with-current-buffer "*Messages*" (buffer-string))))
	(kill-emacs (if (= failed 0) 0 1)))

      )
  (error
   (with-temp-file "/proof/emacs-error.txt"
     (insert (error-message-string err)))
   (kill-emacs 1)))
