;;; phone-sms-chat.el --- native bounded SMS conversations -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'button)
(require 'json)
(require 'chat)
(require 'phone-sms)
(require 'phone-call)

(declare-function emacsos--btn "os")
(declare-function emacsos--center "os")
(declare-function emacsos--render-page "os")
(declare-function emacsos--target "os")
(declare-function emacsos--tap-quit "os")
(declare-function emacsos--unit-width "os")
(declare-function emacsos--run-command "os")
(defvar emacsos--btn-gap)
(defvar emacsos--btn-label-scale)
(defvar emacsos--keyboard-utility-row)

(defconst emacsos-sms-chat--max-records 100)
(defconst emacsos-sms-chat--max-body-bytes (* 128 1024))
(defconst emacsos-sms-chat--conversation-records 40)
(defconst emacsos-sms-chat--conversation-body-bytes (* 64 1024))
(defconst emacsos-sms-chat--catalog-buffer "*SMS conversations*")

(cl-defstruct emacsos-sms-chat-record
  id number body direction state origin owner generation path revision
  unread acknowledged)

(defun emacsos-sms-chat--restore-record (record saved)
  "Restore every field of RECORD from its SAVED copy."
  (cl-replace record saved))

(defvar emacsos-sms-chat--records nil
  "Global SMS records ordered oldest first.")
(defvar emacsos-sms-chat--revision 0)
(defvar emacsos-sms-chat--next-context 0)
(defvar emacsos-sms-chat--contexts (make-hash-table :test #'eql))
(defvar emacsos-sms-chat--notice nil)
(defvar emacsos-sms-chat--refresh-state nil)

(defvar emacsos-sms-chat--refresh nil "Current bounded archive reader process.")
(defvar emacsos-sms-chat--refresh-again nil "Coalesced request made while a reader is active.")
(defvar emacsos-sms-chat--history-loaded nil "Non-nil after the first local history read.")

(defvar-local emacsos-sms-chat--number nil)
(defvar-local emacsos-sms-chat--draft-marker nil)

(defun emacsos-sms-chat--valid-number-p (number)
  "Return non-nil when NUMBER is accepted by the SMS primitive."
  (and (stringp number)
       (string-match-p emacsos-sms--number-re number)))

(defun emacsos-sms-chat--valid-correspondent-p (number)
  "Accept a bounded archive correspondent for viewing, not for sending."
  (and (stringp number) (not (string-match-p "\0" number))
       (<= (string-bytes number) 128)))

(defun emacsos-sms-chat--display-correspondent (number)
  "Reuse inert body escaping, making correspondent newlines visible too."
  (string-replace "\n" "\\u{000A}" (emacsos-sms-chat--display-body number)))

(defun emacsos-sms-chat--next-revision ()
  "Return the next phone-global SMS model revision."
  (setq emacsos-sms-chat--revision (1+ emacsos-sms-chat--revision)))

(defun emacsos-sms-chat--protected-p (record)
  "Return non-nil when RECORD cannot be safely evicted."
  (and (eq (emacsos-sms-chat-record-origin record) 'local)
       (or (memq (emacsos-sms-chat-record-state record) '(proposed sending))
           (and (eq (emacsos-sms-chat-record-state record) 'unknown)
                (not (emacsos-sms-chat-record-acknowledged record))))))

(defun emacsos-sms-chat--total-body-bytes ()
  "Return exact body bytes retained by the global model."
  (cl-loop for record in emacsos-sms-chat--records
           sum (emacsos-sms--body-bytes
                (emacsos-sms-chat-record-body record))))

(defun emacsos-sms-chat--over-budget-p ()
  "Return non-nil when the global model exceeds either hard bound."
  (or (> (length emacsos-sms-chat--records) emacsos-sms-chat--max-records)
      (> (emacsos-sms-chat--total-body-bytes)
         emacsos-sms-chat--max-body-bytes)))

(defun emacsos-sms-chat--trim ()
  "Evict oldest unprotected records until the global model is bounded."
  (while (and (emacsos-sms-chat--over-budget-p)
              (seq-find (lambda (record)
                          (not (emacsos-sms-chat--protected-p record)))
                        emacsos-sms-chat--records))
    (let ((victim (seq-find (lambda (record)
                              (not (emacsos-sms-chat--protected-p record)))
                            emacsos-sms-chat--records)))
      (setq emacsos-sms-chat--records
            (delq victim emacsos-sms-chat--records))))
  (not (emacsos-sms-chat--over-budget-p)))

(defun emacsos-sms-chat--conversation-buffer-name (number)
  "Return the canonical conversation buffer name for validated NUMBER."
  (format "*SMS conversation: %s*" (emacsos-sms-chat--display-correspondent number)))

(defun emacsos-sms-chat--conversation-buffers ()
  "Return all live SMS conversation buffers."
  (seq-filter
   (lambda (buffer)
     (with-current-buffer buffer
       (derived-mode-p 'emacsos-sms-chat-mode)))
   (buffer-list)))

(defun emacsos-sms-chat--rerender-all ()
  "Rerender every live SMS surface without stealing the target window."
  (dolist (buffer (emacsos-sms-chat--conversation-buffers))
    (with-current-buffer buffer (emacsos-sms-chat--render)))
  (when-let ((catalog (get-buffer emacsos-sms-chat--catalog-buffer)))
    (with-current-buffer catalog (emacsos-sms-chat--render-catalog)))
  (when (fboundp 'force-mode-line-update) (force-mode-line-update t))
  (when (fboundp 'emacsos--render-page) (emacsos--render-page)))

(defun emacsos-sms-chat--admit (record &optional quiet)
  "Add RECORD if hard bounds can be restored; return RECORD or nil.
When QUIET is non-nil, leave rerendering to the caller."
  (let ((saved emacsos-sms-chat--records))
    (setq emacsos-sms-chat--records
          (append emacsos-sms-chat--records (list record)))
    (if (and (emacsos-sms-chat--trim)
             (memq record emacsos-sms-chat--records))
        (progn (unless quiet (emacsos-sms-chat--rerender-all)) record)
      (setq emacsos-sms-chat--records saved
            emacsos-sms-chat--notice "SMS storage full; acknowledge pending status")
      (unless quiet (emacsos-sms-chat--rerender-all))
      nil)))

(defun emacsos-sms-chat--records-for (number)
  "Return records for NUMBER in chronological order."
  (seq-filter (lambda (record)
                (equal number (emacsos-sms-chat-record-number record)))
              emacsos-sms-chat--records))

(defun emacsos-sms-chat--render-records (number)
  "Return the newest bounded records for NUMBER in chronological order."
  (let ((records
         (reverse
          (seq-remove
           (lambda (record)
             (eq (emacsos-sms-chat-record-state record) 'proposed))
           (emacsos-sms-chat--records-for number))))
        (count 0) (bytes 0) selected)
    (while (and records (< count emacsos-sms-chat--conversation-records))
      (let* ((record (pop records))
             (size
              (+ 5
                 (emacsos-sms--body-bytes
                  (emacsos-sms-chat--display-body
                   (emacsos-sms-chat-record-body record)))
                 (emacsos-sms--body-bytes
                  (emacsos-sms-chat--status-suffix record))
                 2)))
        (if (> (+ bytes size) emacsos-sms-chat--conversation-body-bytes)
            (setq records nil)
          (push record selected)
          (setq count (1+ count) bytes (+ bytes size)))))
    selected))

(defun emacsos-sms-chat--draft ()
  "Return the exact current draft, or the empty string."
  (if (and (markerp emacsos-sms-chat--draft-marker)
           (marker-position emacsos-sms-chat--draft-marker))
      (buffer-substring-no-properties emacsos-sms-chat--draft-marker (point-max))
    ""))

(defun emacsos-sms-chat--display-body (body)
  "Return an unambiguous inert display form of exact BODY."
  (mapconcat
   (lambda (character)
     (cond
      ((eq character ?\n) "\n")
      ((eq character ?\\) "\\\\")
      ((or (< character 32)
           (<= 127 character 159)
           (eq (get-char-code-property character 'general-category) 'Cf))
       (format "\\u{%04X}" character))
      (t (char-to-string character))))
   body ""))

(defun emacsos-sms-chat--status-suffix (record)
  "Return compact status text for RECORD."
  (pcase (emacsos-sms-chat-record-state record)
    ('sending " [sending]")
    ('sent " [sent]")
    ('failed " [not sent]")
    ('unknown (if (emacsos-sms-chat-record-acknowledged record)
                  " [unknown, acknowledged]"
                " [unknown; do not resend]"))
    (_ "")))

(defun emacsos-sms-chat--save-view ()
  "Return exact draft and point offset for the current conversation buffer."
  (let* ((draft (emacsos-sms-chat--draft))
         (start (and (markerp emacsos-sms-chat--draft-marker)
                     (marker-position emacsos-sms-chat--draft-marker)))
         (offset (if start (max 0 (- (point) start)) 0)))
    (list draft offset)))

(defun emacsos-sms-chat--render ()
  "Render the current conversation while preserving its exact draft and point."
  (when (emacsos-sms-chat--valid-correspondent-p emacsos-sms-chat--number)
    (pcase-let ((`(,draft ,offset) (emacsos-sms-chat--save-view)))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "SMS %s\n" (if (string-empty-p emacsos-sms-chat--number) "[no sender]"
                                  (emacsos-sms-chat--display-correspondent emacsos-sms-chat--number))))
        (when emacsos-sms-chat--refresh-state
          (insert emacsos-sms-chat--refresh-state "\n"))
        (when emacsos-sms-chat--notice
          (insert emacsos-sms-chat--notice "\n"))
        (insert "\n")
        (dolist (record (emacsos-sms-chat--render-records
                         emacsos-sms-chat--number))
          (emacsos-conversation-insert-inert-message
           (if (eq (emacsos-sms-chat-record-direction record) 'outgoing)
               'user 'assistant)
           (concat (emacsos-sms-chat--display-body
                    (emacsos-sms-chat-record-body record))
                   (emacsos-sms-chat--status-suffix record)
                   "\n\n")))
        (let ((prompt-start (point)))
          (insert "> ")
          (add-text-properties prompt-start (point)
                               '(read-only t front-sticky t rear-nonsticky t)))
        (setq emacsos-sms-chat--draft-marker (copy-marker (point) nil))
        (add-text-properties
         (point-min) emacsos-sms-chat--draft-marker
         '(read-only t front-sticky t rear-nonsticky t))
        (insert draft)
        (goto-char (min (point-max)
                        (+ (marker-position emacsos-sms-chat--draft-marker)
                           offset)))))))

(defun emacsos-sms-chat--unknown-record ()
  "Return the newest unacknowledged local unknown in this conversation."
  (car (last
        (seq-filter
         (lambda (record)
           (and (eq (emacsos-sms-chat-record-origin record) 'local)
                (eq (emacsos-sms-chat-record-state record) 'unknown)
                (not (emacsos-sms-chat-record-acknowledged record))))
         (emacsos-sms-chat--records-for emacsos-sms-chat--number)))))

(defun emacsos-sms-chat-acknowledge ()
  "Acknowledge the exact visible unknown record without modem I/O."
  (interactive)
  (if-let ((record (emacsos-sms-chat--unknown-record)))
      (if (and (eq emacsos-sms--state 'unknown)
               (equal emacsos-sms--attempt-id
                      (emacsos-sms-chat-record-id record)))
          (emacsos-sms-acknowledge)
        (setf (emacsos-sms-chat-record-acknowledged record) t
              (emacsos-sms-chat-record-revision record)
              (emacsos-sms-chat--next-revision))
        (emacsos-sms-chat--trim)
        (emacsos-sms-chat--rerender-all))
    (message "No unknown SMS status to acknowledge")))

(defun emacsos-sms-chat-send ()
  "Stage the exact current draft through the existing SMS primitive."
  (interactive)
  (let ((body (emacsos-sms-chat--draft)))
    (if (not (emacsos-sms-chat--valid-number-p emacsos-sms-chat--number))
        (message "This sender cannot receive a reply")
      (if (string-empty-p body)
        (message "Message is empty")
      (let* ((context (setq emacsos-sms-chat--next-context
                            (1+ emacsos-sms-chat--next-context)))
             (record
              (make-emacsos-sms-chat-record
               :number (copy-sequence emacsos-sms-chat--number)
               :body (copy-sequence body) :direction 'outgoing
               :state 'proposed :origin 'local
               :revision (emacsos-sms-chat--next-revision)))
             (saved-records emacsos-sms-chat--records)
             (saved-notice emacsos-sms-chat--notice))
        (if (not (emacsos-sms-chat--admit record t))
            (progn
              (emacsos-sms-chat--rerender-all)
              (message "SMS storage full; acknowledge pending status")
              "error: SMS storage full")
          (puthash context
                   (list :buffer (current-buffer)
                         :number emacsos-sms-chat--number
                         :body (copy-sequence body) :record record)
                   emacsos-sms-chat--contexts)
          (let ((result
                 (emacsos-send-message emacsos-sms-chat--number body context)))
            (when (string-prefix-p "error:" result)
              (remhash context emacsos-sms-chat--contexts)
              (setq emacsos-sms-chat--records saved-records
                    emacsos-sms-chat--notice saved-notice)
              (emacsos-sms-chat--rerender-all))
            result)))))))

(defun emacsos-sms-chat--render-utility-row (final-label final-command)
  "Render QUIT, Refresh, and FINAL-LABEL invoking FINAL-COMMAND."
  (let* ((window (get-buffer-window (current-buffer)))
         (width (if window (window-body-width window) 20))
         (unit (emacsos--unit-width width emacsos--btn-gap 3 2)))
    (emacsos--btn (emacsos--center "QUIT" unit)
                 #'emacsos--tap-quit nil emacsos--btn-label-scale)
    (insert " ")
    (put-text-property (1- (point)) (point) 'display
                       `(space :width ,emacsos--btn-gap))
    (emacsos--btn (emacsos--center "Refresh" unit)
                 #'emacsos--run-command #'emacsos-sms-chat-refresh
                 emacsos--btn-label-scale)
    (insert " ")
    (put-text-property (1- (point)) (point) 'display
                       `(space :width ,emacsos--btn-gap))
    (emacsos--btn (emacsos--center final-label unit)
                 #'emacsos--run-command final-command
                 emacsos--btn-label-scale "dodger blue")
    (insert "\n")))

(defun emacsos-sms-chat--utility-row ()
  "Render QUIT, Refresh, and Send or ACK for an SMS conversation."
  (let* ((target (and (fboundp 'emacsos--target) (emacsos--target)))
         (target-buffer (and target (window-buffer target)))
         (ack (and (buffer-live-p target-buffer)
                   (with-current-buffer target-buffer
                     (and (derived-mode-p 'emacsos-sms-chat-mode)
                          (emacsos-sms-chat--unknown-record))))))
    (emacsos-sms-chat--render-utility-row
     (if ack "ACK" "Send")
     (if ack #'emacsos-sms-chat-acknowledge #'emacsos-sms-chat-send))))

(defun emacsos-sms-chat--catalog-utility-row ()
  "Render QUIT, Refresh, and New for the SMS catalog."
  (emacsos-sms-chat--render-utility-row "New" #'emacsos-sms-chat-open))

(define-derived-mode emacsos-sms-chat-mode fundamental-mode "SMS"
  "Major mode for one native SMS conversation."
  (visual-line-mode 1)
  (setq-local truncate-lines nil
              word-wrap t
              emacsos--keyboard-utility-row #'emacsos-sms-chat--utility-row)
  (emacsos-conversation-install-actions
   '((send . emacsos-sms-chat-send)
     (refresh . emacsos-sms-chat-refresh))))

(defun emacsos-sms-chat-open (number)
  "Open the native SMS conversation for validated NUMBER."
  (interactive (list (read-string "SMS number (+E164): ")))
  (if (not (emacsos-sms-chat--valid-correspondent-p number))
      (message "Invalid SMS number")
    (let ((window (and (fboundp 'emacsos--target) (emacsos--target))))
      (if (not window)
          (message "SMS UI unavailable")
        (let ((buffer (get-buffer-create
                       (emacsos-sms-chat--conversation-buffer-name number))))
          (with-current-buffer buffer
            (unless (derived-mode-p 'emacsos-sms-chat-mode)
              (emacsos-sms-chat-mode))
            (setq emacsos-sms-chat--number number)
            (emacsos-sms-chat--render))
          (set-window-buffer window buffer)
          (dolist (record (emacsos-sms-chat--records-for number))
            (setf (emacsos-sms-chat-record-unread record) nil))
          (when (fboundp 'emacsos--render-page) (emacsos--render-page))
          (force-mode-line-update t)
          buffer)))))

(defun emacsos-sms-chat--catalog-numbers ()
  "Return known validated numbers, newest activity first."
  (let (numbers)
    (dolist (record (reverse emacsos-sms-chat--records))
      (let ((number (emacsos-sms-chat-record-number record)))
        (when (and (emacsos-sms-chat--valid-correspondent-p number)
                   (not (member number numbers)))
          (setq numbers (append numbers (list number))))))
    numbers))

(defun emacsos-sms-chat--open-button (button)
  "Open the validated SMS number stored on BUTTON."
  (let ((number (button-get button 'emacsos-sms-number)))
    (when (emacsos-sms-chat--valid-correspondent-p number)
      (emacsos-sms-chat-open number))))

(defun emacsos-sms-chat--render-catalog ()
  "Render the SMS conversation catalog from bounded local state."
  (let ((inhibit-read-only t))
    (erase-buffer)
    (insert "SMS conversations\n")
    (when emacsos-sms-chat--refresh-state
      (insert (format "%s\n" emacsos-sms-chat--refresh-state)))
    (insert "\n")
    (let ((numbers (emacsos-sms-chat--catalog-numbers)))
      (if numbers
          (dolist (number numbers)
            (insert-text-button (if (string-empty-p number) "[no sender]"
                                (emacsos-sms-chat--display-correspondent number))
                                'follow-link t
                                'emacsos-sms-number number
                                'action #'emacsos-sms-chat--open-button)
            (insert "\n\n"))
        (insert "No messages yet. Tap Refresh.\n")))
    (goto-char (point-min))
    (setq buffer-read-only t)))

(define-derived-mode emacsos-sms-chat-catalog-mode special-mode "SMS-Catalog"
  "Major mode for the bounded SMS conversation catalog."
  (setq-local emacsos--keyboard-utility-row
              #'emacsos-sms-chat--catalog-utility-row))

(defun emacsos-sms-chat-catalog ()
  "Open the native SMS conversation catalog."
  (interactive)
  (let ((window (and (fboundp 'emacsos--target) (emacsos--target))))
    (if (not window)
        (message "SMS UI unavailable")
      (let ((buffer (get-buffer-create emacsos-sms-chat--catalog-buffer)))
        (with-current-buffer buffer
          (unless (derived-mode-p 'emacsos-sms-chat-catalog-mode)
            (emacsos-sms-chat-catalog-mode))
          (emacsos-sms-chat--render-catalog))
        (set-window-buffer window buffer)
        (when (fboundp 'emacsos--render-page) (emacsos--render-page))
        buffer))))

(defun emacsos-sms-chat--newest-unread ()
  "Return the newest unread inbound record."
  (car (last (seq-filter
              (lambda (record)
                (and (eq (emacsos-sms-chat-record-direction record) 'incoming)
                     (emacsos-sms-chat-record-unread record)))
              emacsos-sms-chat--records))))

(defun emacsos-sms-chat-show-unread ()
  "Open the conversation containing the newest unread SMS."
  (interactive)
  (if-let ((record (emacsos-sms-chat--newest-unread)))
      (emacsos-sms-chat-open (emacsos-sms-chat-record-number record))
    (emacsos-sms-chat-catalog)))

(defconst emacsos-sms-chat--mode-line-map
  (let ((map (make-sparse-keymap)))
    (define-key map [mode-line mouse-1] #'emacsos-sms-chat-show-unread)
    map))

(defun emacsos-sms-chat-mode-line-string ()
  "Return a tappable badge exactly while an unread inbound SMS exists."
  (if (emacsos-sms-chat--newest-unread)
      (concat " " (propertize "● SMS"
                              'local-map emacsos-sms-chat--mode-line-map
                              'mouse-face 'mode-line-highlight
                              'help-echo "Tap to read new message"))
    ""))

(defun emacsos-sms-chat--find-id (proposal-id)
  "Return the retained record with durable PROPOSAL-ID."
  (seq-find (lambda (record)
              (equal proposal-id (emacsos-sms-chat-record-id record)))
            emacsos-sms-chat--records))

(defun emacsos-sms-chat--apply-history (value &optional revision)
  "Merge local VALUE, preserving UI ownership and edits newer than REVISION."
  (let ((rows (alist-get 'messages value))
        (saved-records emacsos-sms-chat--records)
        (saved-values (mapcar (lambda (r) (cons r (copy-emacsos-sms-chat-record r)))
                              emacsos-sms-chat--records)) incoming)
    (unless (and (listp value) (= (length value) 2) (assq 'messages value) (assq 'truncated value) (listp rows) (<= (length rows) 100)) (error "Invalid archive"))
    (dolist (row rows)
      (let ((id (alist-get 'id row)) (number (alist-get 'number row))
            (body (alist-get 'text row)) (direction (alist-get 'direction row))
            (status (alist-get 'status row)))
        (unless (and (stringp id) (string-match-p "\\`[A-Za-z0-9_-]\\{1,128\\}\\'" id)
                     (emacsos-sms-chat--valid-correspondent-p number)
                     (stringp body) (not (string-match-p "\0" body))
                     (or (and (equal direction "incoming") (equal status "received"))
                         (and (equal direction "outgoing") (member status '("sent" "not_sent" "unknown")))))
          (error "Invalid archive record"))))
    (dolist (row rows)
      (let ((id (alist-get 'id row)) (number (alist-get 'number row))
            (body (alist-get 'text row)) (direction (alist-get 'direction row))
            (status (alist-get 'status row)))
        (let* ((existing (emacsos-sms-chat--find-id id))
               (record (or existing (make-emacsos-sms-chat-record
                                     :id id :number number :body body
                                     :direction (intern direction)
                                     :origin (if (equal direction "outgoing") 'local 'archive)
                                     :unread (and emacsos-sms-chat--history-loaded
                                                  (equal direction "incoming"))))))
          (cond
           ((and (memq emacsos-sms--state '(sending sent failed unknown))
                 (equal id emacsos-sms--attempt-id))
            (setf (emacsos-sms-chat-record-state record) emacsos-sms--state))
           ;; A reader may have captured the write-ahead unknown before the
           ;; existing terminal callback completed. Never regress that result.
           ((and existing (equal status "unknown")
                 (memq (emacsos-sms-chat-record-state existing) '(sent failed))))
           ;; Eviction protection does not freeze an unowned historical
           ;; Unknown when the same durable journal attempt becomes terminal.
           ((or (and existing
                     (eq (emacsos-sms-chat-record-state existing) 'unknown)
                     (member status '("sent" "not_sent")))
                (not (and existing (emacsos-sms-chat--protected-p existing))))
            (setf (emacsos-sms-chat-record-state record)
                  (if (equal status "not_sent") 'failed (intern status)))))
          (push record incoming))))
    ;; Preserve lifecycle-owned records and changes made after this reader
    ;; started. A later fresh page can replace ordinary completed records.
    (dolist (record emacsos-sms-chat--records)
      (when (and (or (emacsos-sms-chat--protected-p record)
                     (and (integerp revision)
                          (integerp (emacsos-sms-chat-record-revision record))
                          (> (emacsos-sms-chat-record-revision record) revision)))
                 (not (memq record incoming)))
        (push record incoming)))
    (setq emacsos-sms-chat--records (nreverse incoming))
    (if (emacsos-sms-chat--trim)
        (setq emacsos-sms-chat--history-loaded t
              emacsos-sms-chat--refresh-state
              (if (alist-get 'truncated value) "Local history (bounded view)" "Local history refreshed"))
      (dolist (saved saved-values)
        (emacsos-sms-chat--restore-record (car saved) (cdr saved)))
      (setq emacsos-sms-chat--records saved-records
            emacsos-sms-chat--refresh-state "Local view full; acknowledge pending status"))
    (emacsos-sms-chat--rerender-all)))

(defun emacsos-sms-chat--history-finished (process _event)
  "Consume only the current archive PROCESS; no modem ownership is required."
  (when (and (eq process emacsos-sms-chat--refresh)
             (memq (process-status process) '(exit signal)))
    (setq emacsos-sms-chat--refresh nil)
    (let ((buffer (process-buffer process)))
      (unwind-protect
          (condition-case nil
              (progn
                (unless (and (zerop (process-exit-status process))
                             (not (process-get process 'overflow)))
                  (error "Archive read failed"))
                ;; A recordless terminal event invalidates an older page; its
                ;; ordinary completion starts the already-coalesced fresh read.
                (when (integerp (process-get process 'revision))
                  (emacsos-sms-chat--apply-history
                   (with-current-buffer buffer
                     (json-parse-string (buffer-string) :object-type 'alist
                                        :array-type 'list :false-object nil :null-object nil))
                   (process-get process 'revision))))
            (error
             (setq emacsos-sms-chat--refresh-state "Local history unavailable; tap Refresh")
             (emacsos-sms-chat--rerender-all)))
        (when (buffer-live-p buffer) (kill-buffer buffer)))
      (when emacsos-sms-chat--refresh-again
        (setq emacsos-sms-chat--refresh-again nil)
        (emacsos-sms-chat-refresh)))))

(defun emacsos-sms-chat-refresh ()
  "Read the durable local SMS archive asynchronously, including offline."
  (interactive)
  (if emacsos-sms-chat--refresh
      (setq emacsos-sms-chat--refresh-again t)
    (let ((buffer (generate-new-buffer " *SMS archive*"))
          (revision emacsos-sms-chat--revision) process)
      (condition-case nil
          (progn
            (setq process
                  (make-process
                   :name "emacsos-sms-history" :buffer buffer :noquery t
                   :connection-type 'pipe :coding 'utf-8-unix :sentinel #'ignore
                   :command '("/usr/bin/doas" "-n" "/usr/local/sbin/emacsos-openrc-sms")
                   :filter (lambda (proc text)
                             (when (buffer-live-p (process-buffer proc))
                               (let ((size (+ (or (process-get proc 'bytes) 0) (string-bytes text))))
                                 (process-put proc 'bytes size)
                                 (if (> size (* 128 1024))
                                     (progn (process-put proc 'overflow t) (delete-process proc))
                                   (with-current-buffer (process-buffer proc) (insert text))))))))
            (process-put process 'revision revision)
            (setq emacsos-sms-chat--refresh process
                  emacsos-sms-chat--refresh-state "Reading local history...")
            (process-send-string process "{\"operation\":\"history\"}")
            (process-send-eof process)
            (set-process-sentinel process #'emacsos-sms-chat--history-finished)
            (when (memq (process-status process) '(exit signal))
              (run-at-time 0 nil #'emacsos-sms-chat--history-finished process "finished"))
            (run-at-time 5 nil (lambda () (when (process-live-p process) (delete-process process)))))
        (error
         (setq emacsos-sms-chat--refresh nil
               emacsos-sms-chat--refresh-state "Local history unavailable; tap Refresh")
         (when (process-live-p process) (delete-process process))
         (when (buffer-live-p buffer) (kill-buffer buffer)))))))

(defun emacsos-sms-chat--on-lifecycle (event)
  "Join immutable outbound lifecycle EVENT into conversation state."
  (let* ((kind (plist-get event :event))
         (context (plist-get event :context))
         (mapping (and (integerp context)
                       (gethash context emacsos-sms-chat--contexts)))
         (proposal-id (plist-get event :proposal-id))
         (record-id (or (plist-get event :message-id) (plist-get event :proposal-id))))
    (pcase kind
      ('staged
       (when mapping
         (when-let ((record (plist-get mapping :record)))
           (setf (emacsos-sms-chat-record-id record) proposal-id))
         (setf (plist-get mapping :proposal-id) proposal-id)
         (puthash context mapping emacsos-sms-chat--contexts)))
      ('discarded
       (when mapping
         (when-let ((record (plist-get mapping :record)))
           (setq emacsos-sms-chat--records
                 (delq record emacsos-sms-chat--records)))
         (remhash context emacsos-sms-chat--contexts)
         (emacsos-sms-chat--rerender-all)))
      ('sending
       (when mapping
         (when-let ((record (plist-get mapping :record)))
           (when (eq (emacsos-sms-chat-record-state record) 'proposed)
             (setf (emacsos-sms-chat-record-id record) proposal-id
                   (emacsos-sms-chat-record-state record) 'sending
                   (emacsos-sms-chat-record-owner record)
                   emacsos-call--current-owner
                   (emacsos-sms-chat-record-generation record)
                   emacsos-call--owner-generation
                   (emacsos-sms-chat-record-revision record)
                   (emacsos-sms-chat--next-revision))
             (let ((buffer (plist-get mapping :buffer))
                   (body (plist-get mapping :body)))
               (when (buffer-live-p buffer)
                 (with-current-buffer buffer
                   (when (equal (emacsos-sms-chat--draft) body)
                     (delete-region emacsos-sms-chat--draft-marker (point-max))))
                 (when-let ((window (and (fboundp 'emacsos--target)
                                         (emacsos--target))))
                   (set-window-buffer window buffer))))
             (emacsos-sms-chat--rerender-all)))))
      ('terminal
       ;; Direct/server-linked sends need not reserve a native record. Do not
       ;; let their pre-commit page recreate Unknown after Done or restaging.
       (when (and emacsos-sms-chat--refresh
                  (not (emacsos-sms-chat--find-id record-id)))
         (process-put emacsos-sms-chat--refresh 'revision nil)
         (setq emacsos-sms-chat--refresh-again t))
       (when-let ((record (emacsos-sms-chat--find-id record-id)))
         (when (eq (emacsos-sms-chat-record-state record) 'sending)
           (setf (emacsos-sms-chat-record-state record) (plist-get event :state)
                 (emacsos-sms-chat-record-revision record)
                 (emacsos-sms-chat--next-revision))
           (emacsos-sms-chat--rerender-all)))
       (when mapping (remhash context emacsos-sms-chat--contexts)))
      ('acknowledged
       (when-let ((record (emacsos-sms-chat--find-id record-id)))
         (setf (emacsos-sms-chat-record-acknowledged record) t
               (emacsos-sms-chat-record-revision record)
               (emacsos-sms-chat--next-revision))
         (emacsos-sms-chat--trim)
         (emacsos-sms-chat--rerender-all))))))

(defun emacsos-sms-chat--on-owner-changed (old-owner _new-owner _generation)
  "Keep archive history; only active local sends depend on OLD-OWNER."
  (dolist (record emacsos-sms-chat--records)
    (when (and (eq (emacsos-sms-chat-record-state record) 'sending)
               (equal (emacsos-sms-chat-record-owner record) old-owner))
      (setf (emacsos-sms-chat-record-state record) 'unknown
            (emacsos-sms-chat-record-acknowledged record) nil)))
  (emacsos-sms-chat-refresh))

(add-hook 'emacsos-sms-lifecycle-functions #'emacsos-sms-chat--on-lifecycle)
(add-hook 'emacsos-call-owner-changed-functions #'emacsos-sms-chat--on-owner-changed)

(provide 'phone-sms-chat)
;;; phone-sms-chat.el ends here
