;;; test-dtach-shell.el --- Native dtach command key tests -*- lexical-binding: t -*-
(require 'ert)
(require 'cl-lib)
(defvar vterm-mode-map)

(defconst dtach-test--source
  (expand-file-name "../deploy/pinephone/dtach-shell.el"
                    (file-name-directory load-file-name)))

(defmacro dtach-test--with-keymaps (&rest body)
  (declare (indent 0))
  `(let ((saved-global-map (current-global-map))
         (vterm-mode-map (make-sparse-keymap)))
     (unwind-protect
         (progn
           (use-global-map (copy-keymap saved-global-map))
           (load dtach-test--source nil t)
           ,@body)
       (use-global-map saved-global-map))))

(ert-deftest dtach-shell-uppercase-d-dispatches-reconnect-globally-and-locally ()
  (dtach-test--with-keymaps
    ;; The keyboard emits uppercase D, ASCII 68, after the C-c prefix.
    (let ((reconnect-events [3 68]) (chooser-events [3 100]) calls)
      (should (eq (key-binding reconnect-events) #'dtach-shell-reconnect))
      (should (eq (key-binding chooser-events) #'dtach-shell))
      (cl-letf (((symbol-function 'dtach-shell-reconnect)
                 (lambda () (interactive) (push 'reconnect calls)))
                ((symbol-function 'dtach-shell)
                 (lambda () (interactive) (push 'choose calls))))
        (execute-kbd-macro reconnect-events)
        (execute-kbd-macro chooser-events)
        ;; A local binding must win over vterm, rather than fall back globally.
        (define-key vterm-mode-map reconnect-events #'ignore)
        (let ((shared (copy-keymap vterm-mode-map)))
          (with-temp-buffer
            (save-window-excursion
              (switch-to-buffer (current-buffer))
              (use-local-map vterm-mode-map)
              (dtach-shell--install-buffer-keybindings)
              (should (eq (key-binding reconnect-events) #'dtach-shell-reconnect))
              (should (eq (key-binding chooser-events) #'dtach-shell))
              (execute-kbd-macro reconnect-events)
              (execute-kbd-macro chooser-events)))
          (should (equal vterm-mode-map shared))))
      (should (equal (reverse calls) '(reconnect choose reconnect choose))))))

(ert-deftest dtach-shell-clears-only-owned-legacy-vterm-bindings ()
  (dtach-test--with-keymaps
    (dolist (key (list [3 100] [3 68] (kbd "C-c S-d")))
      (define-key vterm-mode-map key #'dtach-shell-reconnect))
    (dtach-shell--clear-legacy-vterm-keybindings)
    (dolist (key (list [3 100] [3 68] (kbd "C-c S-d")))
      (should-not (lookup-key vterm-mode-map key)))
    (define-key vterm-mode-map [3 68] #'ignore)
    (dtach-shell--clear-legacy-vterm-keybindings)
    (should (eq (lookup-key vterm-mode-map [3 68]) #'ignore))))
