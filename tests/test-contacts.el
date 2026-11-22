;;; test-contacts.el --- Contacts rendering -*- lexical-binding: t; -*-
(require 'ert)
(require 'phone-sms-chat)

(defun test-contacts--wait ()
  (let ((deadline (+ (float-time) 5)))
    (while (and emacsos-contacts--process (< (float-time) deadline))
      (accept-process-output nil 0.05)))
  (should-not emacsos-contacts--process))

(ert-deftest contacts-render-real-yaml-and-refresh-with-exact-identity ()
  (let* ((file (make-temp-file "contacts" nil ".yaml"))
         (emacsos-contacts-file file)
         (emacsos-contacts--labels (make-hash-table :test #'equal))
         (emacsos-contacts--process nil)
         (emacsos-contacts--notice nil)
         (emacsos-sms-chat--records nil)
         (emacsos-sms-chat--refresh-state nil)
         (emacsos-sms-chat--notice nil)
         (buffer (generate-new-buffer "test contacts")))
    (unwind-protect
        (progn
          (with-temp-file file
            (insert "contacts:\n- name: Alex Example\n  phones: [\"+12025550123\"]\n"))
          (with-current-buffer buffer
            (emacsos-sms-chat-mode)
            (setq emacsos-sms-chat--number "+12025550123")
            (emacsos-sms-chat--render)
            (goto-char (point-max))
            (insert " exact draft ")
            (backward-char 2))
          (emacsos-contacts-refresh)
          (test-contacts--wait)
          (should-not emacsos-contacts--notice)
          (with-current-buffer buffer
            (should (string-match-p (regexp-quote "SMS Alex Example (+12025550123)") (buffer-string)))
            (should (equal (emacsos-sms-chat--draft) " exact draft "))
            (should (equal emacsos-sms-chat--number "+12025550123")))
          ;; A local replacement is also what a successful manual pull produces.
          (with-temp-file file
            (insert "contacts:\n- name: Updated Example\n  phones: [\"+12025550123\"]\n"))
          (emacsos-contacts-refresh)
          (test-contacts--wait)
          (with-current-buffer buffer
            (should (string-match-p "Updated Example" (buffer-string)))
            (should (equal (emacsos-sms-chat--draft) " exact draft "))
            (should (equal emacsos-sms-chat--number "+12025550123")))
          (with-temp-file file
            (insert "contacts:\n- name: One\n  phones: [\"+12025550123\"]\n- name: Two\n  phones: [\"+12025550123\"]\n"))
          (emacsos-contacts-refresh)
          (test-contacts--wait)
          (with-current-buffer buffer
            (should (string-prefix-p "SMS +12025550123\n" (buffer-string))))
          (with-temp-file file (insert "contacts: ["))
          (emacsos-contacts-refresh)
          (test-contacts--wait)
          (should emacsos-contacts--notice)
          (should (equal (emacsos-sms-chat--display-correspondent "+12025550123") "+12025550123")))
      (when (process-live-p emacsos-contacts--process) (delete-process emacsos-contacts--process))
      (kill-buffer buffer)
      (delete-file file))))

(ert-deftest contacts-catalog-keeps-numbers-and-labels-inert ()
  (let ((emacsos-contacts--labels (make-hash-table :test #'equal))
        (emacsos-contacts--notice nil)
        (emacsos-sms-chat--refresh-state nil)
        (emacsos-sms-chat--records
         (list (make-emacsos-sms-chat-record :number "+12025550123")
               (make-emacsos-sms-chat-record :number "+12025550124"))))
    (puthash "+12025550123" (concat "(delete-file x)\n" (string #x202e)) emacsos-contacts--labels)
    (with-temp-buffer
      (emacsos-sms-chat--render-catalog)
      (goto-char (point-min))
      (search-forward "delete-file")
      (let ((button (button-at (point))))
        (should button)
        (should (equal (button-get button 'emacsos-sms-number) "+12025550123")))
      (should (string-match-p (regexp-quote "\\u{000A}\\u{202E}") (buffer-string)))
      (should (string-match-p "+12025550124" (buffer-string)))
      (should (equal (emacsos-sms-chat--conversation-buffer-name "+12025550123")
                     "*SMS conversation: +12025550123*")))))

(ert-deftest contacts-disable-and-launch-failure-remove-visible-stale-labels ()
  (dolist (configured '(nil "/synthetic/contacts.yaml"))
    (let ((emacsos-contacts-file configured)
          (emacsos-contacts--labels (make-hash-table :test #'equal))
          (emacsos-contacts--process nil)
          (emacsos-contacts--notice nil)
          (emacsos-sms-chat--refresh nil)
          (emacsos-sms-chat--refresh-state nil)
          (emacsos-sms-chat--notice nil)
          (emacsos-sms-chat--records nil)
          (buffer (generate-new-buffer "test contacts failure")))
      (unwind-protect
          (progn
            (puthash "+12025550123" "Old Name" emacsos-contacts--labels)
            (with-current-buffer buffer
              (emacsos-sms-chat-mode)
              (setq emacsos-sms-chat--number "+12025550123")
              (emacsos-sms-chat--render))
            (cl-letf (((symbol-function 'make-process)
                       (lambda (&rest _) (error "Synthetic launch failure"))))
              (emacsos-sms-chat-refresh))
            (with-current-buffer buffer
              (should-not (string-match-p "Old Name" (buffer-string)))
              (when configured
                (should (string-match-p "Contacts unavailable" (buffer-string)))))
            (should-not emacsos-contacts--process))
        (kill-buffer buffer)))))
