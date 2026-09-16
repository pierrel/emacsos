;;; phone-sms-chat.el --- native bounded SMS conversations -*- lexical-binding: t; -*-

(require 'cl-lib)
(require 'seq)
(require 'subr-x)
(require 'button)
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

(defconst emacsos-sms-chat--mmcli "/usr/bin/mmcli")
(defconst emacsos-sms-chat--snapshot-output-limit (* 16 1024))
(defconst emacsos-sms-chat--list-output-limit (* 64 1024))
(defconst emacsos-sms-chat--max-jobs 64)
(defconst emacsos-sms-chat--max-processes 4)
(defconst emacsos-sms-chat--max-list-paths 50)

(cl-defstruct emacsos-sms-chat-job
  key kind owner generation path live refreshes attempts token process timer
  state stale)
(cl-defstruct emacsos-sms-chat-refresh
  id owner generation cutoff paths pending results failures overflow deadline done terminal)

(defvar emacsos-sms-chat--jobs (make-hash-table :test #'equal))
(defvar emacsos-sms-chat--queue nil)
(defvar emacsos-sms-chat--running 0)
(defvar emacsos-sms-chat--next-job-token 0)
(defvar emacsos-sms-chat--next-refresh-id 0)
(defvar emacsos-sms-chat--refresh nil)
(defvar emacsos-sms-chat--last-recovery 0.0)

(defvar-local emacsos-sms-chat--number nil)
(defvar-local emacsos-sms-chat--draft-marker nil)

(defun emacsos-sms-chat--unibyte (string)
  "Return STRING encoded as raw unibyte data."
  (encode-coding-string string 'raw-text t))

(defconst emacsos-sms-chat--snapshot-keys
  '("sms.dbus-path" "sms.content.number" "sms.content.text"
    "sms.properties.pdu-type" "sms.properties.state"))

(defconst emacsos-sms-chat--ignored-snapshot-keys
  '("sms.content.data" "sms.content.part" "sms.content.cdma-teleservice-id"
    "sms.content.cdma-service-category" "sms.properties.smsc"
    "sms.properties.validity" "sms.properties.class" "sms.properties.storage"
    "sms.properties.delivery-report-request" "sms.properties.message-reference"
    "sms.properties.timestamp" "sms.properties.delivery-state"
    "sms.properties.discharge-timestamp"))

(defun emacsos-sms-chat--strict-utf8 (bytes)
  "Decode canonical UTF-8 BYTES, or signal an error."
  (let* ((raw (emacsos-sms-chat--unibyte bytes))
         (size (length raw))
         (index 0))
    (cl-labels ((continuation-p (offset low high)
                  (and (< (+ index offset) size)
                       (<= low (aref raw (+ index offset)) high))))
      (while (< index size)
        (let ((byte (aref raw index)))
          (setq index
                (+ index
                   (cond
                    ((<= byte #x7f) 1)
                    ((and (<= #xc2 byte #xdf)
                          (continuation-p 1 #x80 #xbf)) 2)
                    ((and (= byte #xe0)
                          (continuation-p 1 #xa0 #xbf)
                          (continuation-p 2 #x80 #xbf)) 3)
                    ((and (or (<= #xe1 byte #xec) (<= #xee byte #xef))
                          (continuation-p 1 #x80 #xbf)
                          (continuation-p 2 #x80 #xbf)) 3)
                    ((and (= byte #xed)
                          (continuation-p 1 #x80 #x9f)
                          (continuation-p 2 #x80 #xbf)) 3)
                    ((and (= byte #xf0)
                          (continuation-p 1 #x90 #xbf)
                          (continuation-p 2 #x80 #xbf)
                          (continuation-p 3 #x80 #xbf)) 4)
                    ((and (<= #xf1 byte #xf3)
                          (continuation-p 1 #x80 #xbf)
                          (continuation-p 2 #x80 #xbf)
                          (continuation-p 3 #x80 #xbf)) 4)
                    ((and (= byte #xf4)
                          (continuation-p 1 #x80 #x8f)
                          (continuation-p 2 #x80 #xbf)
                          (continuation-p 3 #x80 #xbf)) 4)
                    (t (error "Invalid UTF-8")))))))
    (decode-coding-string raw 'utf-8 t))))

(defun emacsos-sms-chat--glib-unescape (bytes)
  "Strictly decode GLib escapes in unibyte BYTES as UTF-8."
  (let ((index 0) (size (length bytes)) pieces)
    (while (< index size)
      (let ((byte (aref bytes index)))
        (if (/= byte ?\\)
            (progn (push (unibyte-string byte) pieces)
                   (setq index (1+ index)))
          (when (>= (1+ index) size) (error "Trailing escape"))
          (let* ((escaped (aref bytes (1+ index)))
                 (simple (cdr (assq escaped
                                    '((?\\ . ?\\) (?n . ?\n) (?r . ?\r)
                                      (?t . ?\t) (?b . ?\b) (?f . ?\f)
                                      (?v . ?\v) (?\" . ?\"))))))
            (cond
             (simple
              (push (unibyte-string simple) pieces)
              (setq index (+ index 2)))
             ((and (<= ?0 escaped) (<= escaped ?7)
                   (<= (+ index 4) size)
                   (string-match-p "\\`[0-7]\\{3\\}\\'"
                                   (substring bytes (1+ index) (+ index 4))))
              (push (unibyte-string
                     (string-to-number
                      (substring bytes (1+ index) (+ index 4)) 8))
                    pieces)
              (setq index (+ index 4)))
             (t (error "Invalid GLib escape")))))))
    (emacsos-sms-chat--strict-utf8 (apply #'concat (nreverse pieces)))))

(defun emacsos-sms-chat--parse-lines (blob allowed ignored)
  "Parse mmcli BLOB using finite ALLOWED and IGNORED key collections."
  (let* ((bytes (emacsos-sms-chat--unibyte blob))
         (payload (if (string-suffix-p "\n" bytes)
                      (substring bytes 0 -1)
                    bytes))
         (lines (unless (string-empty-p payload)
                  (split-string payload "\n" nil)))
         result seen)
    (when (member "" lines) (error "Blank physical line"))
    (dolist (line lines)
      (when (string-suffix-p "\r" line) (error "CR is not accepted"))
      (unless (string-match
               "\\`\\([A-Za-z0-9._-]+\\(?:\\[[0-9]+\\]\\)?\\)[ \t]+:[ \t]\\(.*\\)\\'"
               line)
        (error "Malformed key-value line"))
      (let ((key (match-string 1 line))
            (raw (match-string 2 line)))
        (when (member key seen) (error "Duplicate key"))
        (push key seen)
        (let ((value (emacsos-sms-chat--glib-unescape raw)))
          (cond
           ((member key allowed) (push (cons key value) result))
           ((member key ignored) nil)
           (t (error "Unknown key"))))))
    result))

(defun emacsos-sms-chat--parse-snapshot (blob)
  "Parse strict mmcli SMS BLOB into a normalized plist, or nil."
  (condition-case nil
      (let* ((fields (emacsos-sms-chat--parse-lines
                      blob emacsos-sms-chat--snapshot-keys
                      emacsos-sms-chat--ignored-snapshot-keys))
             (path (cdr (assoc "sms.dbus-path" fields)))
             (number (cdr (assoc "sms.content.number" fields)))
             (body (cdr (assoc "sms.content.text" fields)))
             (pdu (cdr (assoc "sms.properties.pdu-type" fields)))
             (state (cdr (assoc "sms.properties.state" fields)))
             (direction (cond ((equal pdu "deliver") 'incoming)
                              ((equal pdu "submit") 'outgoing))))
        (when (and (= (length fields) (length emacsos-sms-chat--snapshot-keys))
                   (emacsos-call--valid-sms-path-p path)
                   (emacsos-sms-chat--valid-number-p number)
                   (stringp body) (not (string-match-p "\0" body))
                   (<= (emacsos-sms--body-bytes body)
                       emacsos-sms--max-body-bytes)
                   direction
                   (member state (if (eq direction 'incoming)
                                     '("receiving" "received")
                                   '("stored" "sending" "sent"))))
          (list :path path :number number :body body :direction direction
                :state (intern state))))
    (error nil)))

(defun emacsos-sms-chat--parse-list (blob)
  "Parse strict mmcli SMS-list BLOB as (parsed . PATHS), or nil."
  (condition-case nil
      (let* ((bytes (emacsos-sms-chat--unibyte blob))
             (payload (if (string-suffix-p "\n" bytes)
                          (substring bytes 0 -1)
                        bytes))
             (lines (unless (string-empty-p payload)
                      (split-string payload "\n" nil)))
             paths indices declared seen)
        (when (member "" lines) (error "Blank physical line"))
        (dolist (line lines)
          (when (string-suffix-p "\r" line) (error "CR is not accepted"))
          (unless (string-match
                   "\\`\\(modem\\.messaging\\.sms\\.\\(?:length\\|value\\[[0-9]+\\]\\)\\)[ \t]+:[ \t]\\(.*\\)\\'"
                   line)
            (error "Malformed list line"))
          (let ((key (match-string 1 line))
                (value (emacsos-sms-chat--glib-unescape (match-string 2 line))))
            (when (member key seen) (error "Duplicate list key"))
            (push key seen)
            (if (equal key "modem.messaging.sms.length")
                (unless (string-match-p "\\`[0-9]\\{1,6\\}\\'" value)
                  (error "Invalid list length"))
              (unless (emacsos-call--valid-sms-path-p value)
                (error "Invalid SMS path"))
              (when (member value paths) (error "Duplicate SMS path"))
              (unless (string-match "\\[\\([0-9]\\{1,6\\}\\)\\]\\'" key)
                (error "Invalid SMS index"))
              (push (string-to-number (match-string 1 key)) indices)
              (push value paths))
            (when (equal key "modem.messaging.sms.length")
              (setq declared (string-to-number value)))))
        (setq paths (nreverse paths))
        (when (and declared
                   (= declared (length paths))
                   (equal (sort indices #'<)
                          (number-sequence 1 declared)))
          (cons 'parsed paths)))
    (error nil)))

(defun emacsos-sms-chat--process-filter (process chunk)
  "Accumulate bounded stdout CHUNK for PROCESS."
  (unless (process-get process 'emacsos-sms-chat-overflow)
    (let* ((old (or (process-get process 'emacsos-sms-chat-output)
                    (emacsos-sms-chat--unibyte "")))
           (new (concat old (emacsos-sms-chat--unibyte chunk)))
           (limit (process-get process 'emacsos-sms-chat-limit)))
      (if (> (length new) limit)
          (progn
            (process-put process 'emacsos-sms-chat-overflow t)
            (when (process-live-p process) (delete-process process)))
        (process-put process 'emacsos-sms-chat-output new)))))

(defun emacsos-sms-chat--process-timeout (process)
  "Kill still-live PROCESS and record its timeout."
  (when (process-live-p process)
    (process-put process 'emacsos-sms-chat-timeout t)
    (delete-process process)))

(defun emacsos-sms-chat--process-sentinel (process _event)
  "Finish one bounded PROCESS exactly once after process reap."
  (unless (or (process-live-p process)
              (process-get process 'emacsos-sms-chat-complete))
    (process-put process 'emacsos-sms-chat-complete t)
    (when-let ((timer (process-get process 'emacsos-sms-chat-timer)))
      (cancel-timer timer))
    (when-let ((stderr (process-get process 'emacsos-sms-chat-stderr)))
      (when (process-live-p stderr) (delete-process stderr)))
    (let ((callback (process-get process 'emacsos-sms-chat-callback))
          (status (cond ((process-get process 'emacsos-sms-chat-overflow) 'overflow)
                        ((process-get process 'emacsos-sms-chat-timeout) 'timeout)
                        ((zerop (process-exit-status process)) 'ok)
                        (t 'error))))
      (funcall callback status
               (or (process-get process 'emacsos-sms-chat-output)
                   (emacsos-sms-chat--unibyte ""))))))

(defun emacsos-sms-chat--spawn (args limit callback)
  "Run fixed mmcli ARGS with stdout LIMIT and terminal CALLBACK."
  (let (process stderr)
    (condition-case nil
        (progn
          (setq stderr
                (make-pipe-process
                 :name "emacsos-sms-chat-stderr" :noquery t
                 :filter (lambda (_process _chunk))))
          (setq process
                (make-process
                 :name "emacsos-sms-chat-mmcli"
                 :command (cons emacsos-sms-chat--mmcli args)
                 :connection-type 'pipe :coding 'binary :noquery t
                 :buffer nil :stderr stderr
                 :filter #'ignore
                 :sentinel #'ignore))
        (process-put process 'emacsos-sms-chat-limit limit)
        (process-put process 'emacsos-sms-chat-output
                     (emacsos-sms-chat--unibyte ""))
        (process-put process 'emacsos-sms-chat-callback callback)
        (process-put process 'emacsos-sms-chat-stderr stderr)
        (process-put process 'emacsos-sms-chat-timer
                     (run-at-time 2 nil #'emacsos-sms-chat--process-timeout process))
        (set-process-filter process #'emacsos-sms-chat--process-filter)
        (set-process-sentinel process #'emacsos-sms-chat--process-sentinel)
        (unless (process-live-p process)
          (emacsos-sms-chat--process-sentinel process "finished"))
        process)
      (error
       (when (and process (process-live-p process)) (delete-process process))
       (when (and stderr (process-live-p stderr)) (delete-process stderr))
       (funcall callback 'error (emacsos-sms-chat--unibyte ""))
       nil))))

(defun emacsos-sms-chat--valid-number-p (number)
  "Return non-nil when NUMBER is accepted by the SMS primitive."
  (and (stringp number)
       (string-match-p emacsos-sms--number-re number)))

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
  (format "*SMS %s*" number))

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
  (when (emacsos-sms-chat--valid-number-p emacsos-sms-chat--number)
    (pcase-let ((`(,draft ,offset) (emacsos-sms-chat--save-view)))
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert (format "SMS %s\n" emacsos-sms-chat--number))
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
               (equal emacsos-sms--proposal-id
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
            result))))))

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
  (if (not (emacsos-sms-chat--valid-number-p number))
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
        (when (and (emacsos-sms-chat--valid-number-p number)
                   (not (member number numbers)))
          (setq numbers (append numbers (list number))))))
    numbers))

(defun emacsos-sms-chat--open-button (button)
  "Open the validated SMS number stored on BUTTON."
  (let ((number (button-get button 'emacsos-sms-number)))
    (when (emacsos-sms-chat--valid-number-p number)
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
            (insert-text-button number
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
  "Return the local record with PROPOSAL-ID."
  (seq-find (lambda (record)
              (and (eq (emacsos-sms-chat-record-origin record) 'local)
                   (equal proposal-id (emacsos-sms-chat-record-id record))))
            emacsos-sms-chat--records))

(defun emacsos-sms-chat--find-path (path)
  "Return the retained record attached to modem PATH."
  (seq-find (lambda (record)
              (equal path (emacsos-sms-chat-record-path record)))
            emacsos-sms-chat--records))

(defun emacsos-sms-chat--apply-snapshot
    (snapshot owner generation unread &optional cutoff)
  "Merge SNAPSHOT from OWNER/GENERATION with UNREAD state.
Preserve records newer than CUTOFF when it is non-nil."
  (let* ((path (plist-get snapshot :path))
         (number (plist-get snapshot :number))
         (body (plist-get snapshot :body))
         (direction (plist-get snapshot :direction))
         (state (plist-get snapshot :state))
         (existing (emacsos-sms-chat--find-path path)))
    (cond
     (existing
      (when (and (eq (emacsos-sms-chat-record-origin existing) 'modem)
                 (equal owner (emacsos-sms-chat-record-owner existing))
                 (= generation (emacsos-sms-chat-record-generation existing))
                 (or (null cutoff)
                     (<= (emacsos-sms-chat-record-revision existing) cutoff)))
        (setf (emacsos-sms-chat-record-number existing) number
              (emacsos-sms-chat-record-body existing) body
              (emacsos-sms-chat-record-direction existing) direction
              (emacsos-sms-chat-record-state existing) state
              (emacsos-sms-chat-record-revision existing)
              (emacsos-sms-chat--next-revision)))
      (when (and (eq (emacsos-sms-chat-record-origin existing) 'local)
                 (equal owner (emacsos-sms-chat-record-owner existing))
                 (= generation (emacsos-sms-chat-record-generation existing))
                 (or (null cutoff)
                     (<= (emacsos-sms-chat-record-revision existing) cutoff))
                 (eq direction 'outgoing)
                 (equal number (emacsos-sms-chat-record-number existing))
                 (equal body (emacsos-sms-chat-record-body existing))
                 (eq state 'sent)
                 (eq (emacsos-sms-chat-record-state existing) 'sending))
        (setf (emacsos-sms-chat-record-state existing) 'sent
              (emacsos-sms-chat-record-revision existing)
              (emacsos-sms-chat--next-revision)))
      (when (and unread (eq direction 'incoming))
        (setf (emacsos-sms-chat-record-unread existing) t))
      existing)
     ((eq direction 'outgoing)
      (let* ((equivalent
              (lambda (record)
                (and (eq (emacsos-sms-chat-record-origin record) 'local)
                     (null (emacsos-sms-chat-record-path record))
                     (equal number (emacsos-sms-chat-record-number record))
                     (equal body (emacsos-sms-chat-record-body record))
                     (or (null cutoff)
                         (<= (emacsos-sms-chat-record-revision record)
                             cutoff)))))
             (matches
              (seq-filter
               (lambda (record)
                 (and (funcall equivalent record)
                      (memq (emacsos-sms-chat-record-state record)
                            '(sending sent))))
               emacsos-sms-chat--records)))
        (if (= (length matches) 1)
            (let ((record (car matches)))
              (setf (emacsos-sms-chat-record-owner record) owner
                    (emacsos-sms-chat-record-generation record) generation
                    (emacsos-sms-chat-record-path record) path
                    (emacsos-sms-chat-record-state record)
                    (if (eq state 'sent)
                        'sent
                      (emacsos-sms-chat-record-state record))
                    (emacsos-sms-chat-record-revision record)
                    (emacsos-sms-chat--next-revision))
              record)
          (emacsos-sms-chat--admit
           (make-emacsos-sms-chat-record
            :id path :number number :body body :direction direction :state state
            :origin 'modem :owner owner :generation generation :path path
            :revision (emacsos-sms-chat--next-revision))
           t))))
     (t
      (emacsos-sms-chat--admit
       (make-emacsos-sms-chat-record
        :id path :number number :body body :direction direction :state state
        :origin 'modem :owner owner :generation generation :path path
        :revision (emacsos-sms-chat--next-revision) :unread (and unread t))
       t)))))

(defun emacsos-sms-chat--refresh-terminal (refresh label)
  "Finish REFRESH once and expose terminal LABEL."
  (unless (emacsos-sms-chat-refresh-terminal refresh)
    (setf (emacsos-sms-chat-refresh-terminal refresh) t)
    (when-let ((timer (emacsos-sms-chat-refresh-deadline refresh)))
      (cancel-timer timer))
    (when (eq refresh emacsos-sms-chat--refresh)
      (setq emacsos-sms-chat--refresh nil
            emacsos-sms-chat--refresh-state label))
    (emacsos-sms-chat--rerender-all)))

(defun emacsos-sms-chat--refresh-commit (refresh)
  "Atomically merge completed REFRESH results when all consumers finish."
  (when (and (emacsos-sms-chat-refresh-done refresh)
             (zerop (emacsos-sms-chat-refresh-pending refresh))
             (not (emacsos-sms-chat-refresh-terminal refresh)))
    (let* ((owner (emacsos-sms-chat-refresh-owner refresh))
           (generation (emacsos-sms-chat-refresh-generation refresh))
           (cutoff (emacsos-sms-chat-refresh-cutoff refresh))
           (results (emacsos-sms-chat-refresh-results refresh))
           (ordered
            (delq nil
                  (mapcar
                   (lambda (path)
                     (seq-find (lambda (snapshot)
                                 (equal path (plist-get snapshot :path)))
                               results))
                   (emacsos-sms-chat-refresh-paths refresh)))))
      (if (not (and (equal owner emacsos-call--current-owner)
                    (= generation emacsos-call--owner-generation)))
          (emacsos-sms-chat--refresh-terminal refresh "Modem restarted; tap Refresh")
        (let ((complete (not (or (emacsos-sms-chat-refresh-overflow refresh)
                                 (emacsos-sms-chat-refresh-failures refresh))))
              (saved-records (copy-sequence emacsos-sms-chat--records))
              (saved-revision emacsos-sms-chat--revision)
              (saved-record-values
               (mapcar (lambda (record)
                         (cons record (copy-emacsos-sms-chat-record record)))
                       emacsos-sms-chat--records)))
          (when complete
            (setq emacsos-sms-chat--records
                  (seq-filter
                   (lambda (record)
                     (not (and (eq (emacsos-sms-chat-record-origin record) 'modem)
                               (equal owner (emacsos-sms-chat-record-owner record))
                               (<= (emacsos-sms-chat-record-revision record) cutoff))))
                   emacsos-sms-chat--records)))
          (dolist (snapshot ordered)
            (unless (emacsos-sms-chat--apply-snapshot
                     snapshot owner generation (plist-get snapshot :unread)
                     cutoff)
              (setf (emacsos-sms-chat-refresh-failures refresh) t)))
          (if (and complete (emacsos-sms-chat-refresh-failures refresh))
              (progn
                (dolist (saved saved-record-values)
                  (emacsos-sms-chat--restore-record (car saved) (cdr saved)))
                (setq emacsos-sms-chat--records saved-records
                      emacsos-sms-chat--revision saved-revision
                      emacsos-sms-chat--notice
                      "SMS storage full; acknowledge pending status"))
            (unless (emacsos-sms-chat-refresh-failures refresh)
              (setq emacsos-sms-chat--notice nil))))
        (emacsos-sms-chat--trim)
        (emacsos-sms-chat--refresh-terminal
         refresh
         (cond
          ((emacsos-sms-chat-refresh-overflow refresh) "Refresh overflow; partial history")
          ((emacsos-sms-chat-refresh-failures refresh) "Refresh partial; tap to retry")
          ((null ordered) "No messages")
          (t "Messages refreshed")))))))

(defun emacsos-sms-chat--refresh-consume (refresh snapshot failed)
  "Complete one REFRESH snapshot consumer with SNAPSHOT or FAILED."
  (unless (emacsos-sms-chat-refresh-terminal refresh)
    (when snapshot
      (push snapshot (emacsos-sms-chat-refresh-results refresh)))
    (when failed
      (setf (emacsos-sms-chat-refresh-failures refresh) t))
    (setf (emacsos-sms-chat-refresh-pending refresh)
          (max 0 (1- (emacsos-sms-chat-refresh-pending refresh))))
    (emacsos-sms-chat--refresh-commit refresh)))

(defun emacsos-sms-chat--job-finalize (job)
  "Remove JOB after its terminal result and finish refresh consumers."
  (remhash (emacsos-sms-chat-job-key job) emacsos-sms-chat--jobs)
  (dolist (refresh (emacsos-sms-chat-job-refreshes job))
    (emacsos-sms-chat--refresh-consume refresh nil t)))

(defun emacsos-sms-chat--job-retry (job delay)
  "Requeue JOB after bounded DELAY."
  (setf (emacsos-sms-chat-job-attempts job)
        (1+ (emacsos-sms-chat-job-attempts job))
        (emacsos-sms-chat-job-state job) 'waiting
        (emacsos-sms-chat-job-timer job)
        (run-at-time
         delay nil
         (lambda ()
           (setf (emacsos-sms-chat-job-timer job) nil)
           (if (and (not (emacsos-sms-chat-job-stale job))
                    (equal (emacsos-sms-chat-job-owner job)
                           emacsos-call--current-owner)
                    (= (emacsos-sms-chat-job-generation job)
                       emacsos-call--owner-generation))
               (progn
                 (setf (emacsos-sms-chat-job-state job) 'queued)
                 (setq emacsos-sms-chat--queue
                       (append emacsos-sms-chat--queue (list job)))
                 (emacsos-sms-chat--scheduler-pump))
             (emacsos-sms-chat--job-finalize job))))))

(defun emacsos-sms-chat--request-recovery-refresh ()
  "Request one rate-limited recovery refresh."
  (let ((now (float-time)))
    (when (and (> (- now emacsos-sms-chat--last-recovery) 10)
               (null emacsos-sms-chat--refresh))
      (setq emacsos-sms-chat--last-recovery now)
      (emacsos-sms-chat-refresh))))

(defun emacsos-sms-chat--snapshot-finished (job status output)
  "Apply one snapshot JOB terminal STATUS and bounded OUTPUT."
  (let* ((snapshot (and (eq status 'ok)
                        (emacsos-sms-chat--parse-snapshot output)))
         (refreshes (emacsos-sms-chat-job-refreshes job)))
    (when (and snapshot
               (or (not (equal (plist-get snapshot :path)
                               (emacsos-sms-chat-job-path job)))
                   (and (emacsos-sms-chat-job-live job)
                        (not (eq (plist-get snapshot :direction) 'incoming)))))
      (setq snapshot nil))
    (cond
     ((and snapshot (eq (plist-get snapshot :state) 'receiving)
           (< (emacsos-sms-chat-job-attempts job) 5))
      (emacsos-sms-chat--job-retry job 1))
     ((and (or (not snapshot) (eq (plist-get snapshot :state) 'receiving))
           (emacsos-sms-chat-job-live job)
           (< (emacsos-sms-chat-job-attempts job) 1))
      (emacsos-sms-chat--job-retry job 1))
     (t
      (when (and snapshot
                 (not (eq (plist-get snapshot :state) 'receiving))
                 (emacsos-sms-chat-job-live job)
                 (null refreshes))
        (emacsos-sms-chat--apply-snapshot
         snapshot (emacsos-sms-chat-job-owner job)
         (emacsos-sms-chat-job-generation job) t))
      (when (and snapshot
                 (not (eq (plist-get snapshot :state) 'receiving))
                 (emacsos-sms-chat-job-live job)
                 refreshes)
        (setq snapshot (plist-put (copy-sequence snapshot) :unread t)))
      (dolist (refresh refreshes)
        (emacsos-sms-chat--refresh-consume
         refresh
         (and snapshot
              (not (eq (plist-get snapshot :state) 'receiving))
              snapshot)
         (or (not snapshot)
             (eq (plist-get snapshot :state) 'receiving))))
      (setf (emacsos-sms-chat-job-refreshes job) nil)
      (remhash (emacsos-sms-chat-job-key job) emacsos-sms-chat--jobs)
      (when (and (emacsos-sms-chat-job-live job)
                 (or (not snapshot)
                     (eq (plist-get snapshot :state) 'receiving)))
        (emacsos-sms-chat--request-recovery-refresh))
      (emacsos-sms-chat--trim)
      (emacsos-sms-chat--rerender-all)))))

(defun emacsos-sms-chat--list-finished (job status output)
  "Fan out one refresh-list JOB terminal STATUS and bounded OUTPUT."
  (let* ((refresh (car (emacsos-sms-chat-job-refreshes job)))
         (parsed (and (eq status 'ok) (emacsos-sms-chat--parse-list output))))
    (remhash (emacsos-sms-chat-job-key job) emacsos-sms-chat--jobs)
    (when (and refresh (not (emacsos-sms-chat-refresh-terminal refresh)))
      (if (not parsed)
          (emacsos-sms-chat--refresh-terminal
           refresh (pcase status
                     ('timeout "Refresh timed out; tap to retry")
                     ('overflow "Refresh overflow; tap to retry")
                     (_ "Refresh unavailable; tap to retry")))
        (let ((paths (cdr parsed)))
          (when (> (length paths) emacsos-sms-chat--max-list-paths)
            (setf (emacsos-sms-chat-refresh-overflow refresh) t)
            (setq paths (seq-take paths emacsos-sms-chat--max-list-paths)))
          (setf (emacsos-sms-chat-refresh-paths refresh)
                (copy-sequence paths))
          (dolist (path paths)
            (unless (emacsos-sms-chat--enqueue-snapshot
                     (emacsos-sms-chat-refresh-owner refresh)
                     (emacsos-sms-chat-refresh-generation refresh)
                     path nil refresh)
              (setf (emacsos-sms-chat-refresh-failures refresh) t)))
          (setf (emacsos-sms-chat-refresh-done refresh) t)
          (emacsos-sms-chat--refresh-commit refresh))))))

(defun emacsos-sms-chat--job-complete (job token status output)
  "Release JOB slot for TOKEN and dispatch terminal STATUS/OUTPUT."
  (when (and (eq (emacsos-sms-chat-job-state job) 'running)
             (= token (emacsos-sms-chat-job-token job)))
    (setq emacsos-sms-chat--running (max 0 (1- emacsos-sms-chat--running)))
    (setf (emacsos-sms-chat-job-process job) nil
          (emacsos-sms-chat-job-state job) 'complete)
    (if (or (emacsos-sms-chat-job-stale job)
            (not (equal (emacsos-sms-chat-job-owner job)
                        emacsos-call--current-owner))
            (/= (emacsos-sms-chat-job-generation job)
                emacsos-call--owner-generation))
        (emacsos-sms-chat--job-finalize job)
      (if (eq (emacsos-sms-chat-job-kind job) 'list)
          (emacsos-sms-chat--list-finished job status output)
        (emacsos-sms-chat--snapshot-finished job status output)))
    (emacsos-sms-chat--scheduler-pump)))

(defun emacsos-sms-chat--start-job (job)
  "Start queued JOB in one scheduler slot."
  (let ((token (setq emacsos-sms-chat--next-job-token
                     (1+ emacsos-sms-chat--next-job-token))))
    (setf (emacsos-sms-chat-job-token job) token
          (emacsos-sms-chat-job-state job) 'running)
    (setq emacsos-sms-chat--running (1+ emacsos-sms-chat--running))
    (let ((process
           (if (eq (emacsos-sms-chat-job-kind job) 'list)
               (emacsos-sms-chat--spawn
                '("-m" "any" "--messaging-list-sms" "--output-keyvalue")
                emacsos-sms-chat--list-output-limit
                (lambda (status output)
                  (emacsos-sms-chat--job-complete job token status output)))
             (emacsos-sms-chat--spawn
              (list "-s" (emacsos-sms-chat-job-path job) "--output-keyvalue")
              emacsos-sms-chat--snapshot-output-limit
              (lambda (status output)
                (emacsos-sms-chat--job-complete job token status output))))))
      (when (eq (emacsos-sms-chat-job-state job) 'running)
        (setf (emacsos-sms-chat-job-process job) process)))))

(defun emacsos-sms-chat--scheduler-pump ()
  "Start bounded jobs: refresh list, its snapshots, live work, then FIFO."
  (while (and (< emacsos-sms-chat--running emacsos-sms-chat--max-processes)
              emacsos-sms-chat--queue)
    (let ((job (or (seq-find (lambda (candidate)
                               (eq (emacsos-sms-chat-job-kind candidate) 'list))
                             emacsos-sms-chat--queue)
                   (seq-find
                    (lambda (candidate)
                      (and emacsos-sms-chat--refresh
                           (memq emacsos-sms-chat--refresh
                                 (emacsos-sms-chat-job-refreshes candidate))))
                    emacsos-sms-chat--queue)
                   (seq-find #'emacsos-sms-chat-job-live
                             emacsos-sms-chat--queue)
                   (car emacsos-sms-chat--queue))))
      (setq emacsos-sms-chat--queue (delq job emacsos-sms-chat--queue))
      (emacsos-sms-chat--start-job job))))

(defun emacsos-sms-chat--enqueue-snapshot
    (owner generation path live &optional refresh)
  "Queue or promote OWNER/GENERATION/PATH for LIVE and optional REFRESH."
  (when (and (equal owner emacsos-call--current-owner)
             (= generation emacsos-call--owner-generation)
             (emacsos-call--valid-sms-path-p path))
    (let* ((key (list generation path))
           (job (gethash key emacsos-sms-chat--jobs)))
      (cond
       ((and job (emacsos-sms-chat-job-stale job)) nil)
       (job
        (when live (setf (emacsos-sms-chat-job-live job) t))
        (when (and refresh
                   (not (memq refresh (emacsos-sms-chat-job-refreshes job))))
          (push refresh (emacsos-sms-chat-job-refreshes job))
          (setf (emacsos-sms-chat-refresh-pending refresh)
                (1+ (emacsos-sms-chat-refresh-pending refresh))))
        t)
       ((>= (hash-table-count emacsos-sms-chat--jobs)
            emacsos-sms-chat--max-jobs)
        (when live (emacsos-sms-chat--request-recovery-refresh))
        nil)
       (t
        (setq job (make-emacsos-sms-chat-job
                   :key key :kind 'snapshot :owner owner :generation generation
                   :path (copy-sequence path) :live live
                   :refreshes (and refresh (list refresh)) :attempts 0
                   :state 'queued))
        (when refresh
          (setf (emacsos-sms-chat-refresh-pending refresh)
                (1+ (emacsos-sms-chat-refresh-pending refresh))))
        (puthash key job emacsos-sms-chat--jobs)
        (setq emacsos-sms-chat--queue
              (append emacsos-sms-chat--queue (list job)))
        (emacsos-sms-chat--scheduler-pump)
        t)))))

(defun emacsos-sms-chat--on-lifecycle (event)
  "Join immutable outbound lifecycle EVENT into conversation state."
  (let* ((kind (plist-get event :event))
         (context (plist-get event :context))
         (mapping (and (integerp context)
                       (gethash context emacsos-sms-chat--contexts)))
         (proposal-id (plist-get event :proposal-id)))
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
       (when-let ((record (emacsos-sms-chat--find-id proposal-id)))
         (when (eq (emacsos-sms-chat-record-state record) 'sending)
           (setf (emacsos-sms-chat-record-state record) (plist-get event :state)
                 (emacsos-sms-chat-record-revision record)
                 (emacsos-sms-chat--next-revision))
           (emacsos-sms-chat--rerender-all)))
       (when mapping (remhash context emacsos-sms-chat--contexts)))
      ('acknowledged
       (when-let ((record (emacsos-sms-chat--find-id proposal-id)))
         (setf (emacsos-sms-chat-record-acknowledged record) t
               (emacsos-sms-chat-record-revision record)
               (emacsos-sms-chat--next-revision))
         (emacsos-sms-chat--trim)
         (emacsos-sms-chat--rerender-all))))))

(defun emacsos-sms-chat--on-owner-changed (old-owner _new-owner _generation)
  "Invalidate modem state associated with OLD-OWNER."
  (when old-owner
    (setq emacsos-sms-chat--queue
          (seq-filter
           (lambda (job)
             (if (equal old-owner (emacsos-sms-chat-job-owner job))
                 (progn
                   (setf (emacsos-sms-chat-job-stale job) t)
                   (when-let ((timer (emacsos-sms-chat-job-timer job)))
                     (cancel-timer timer))
                   (remhash (emacsos-sms-chat-job-key job)
                            emacsos-sms-chat--jobs)
                   nil)
               t))
           emacsos-sms-chat--queue))
    (let (old-jobs)
      (maphash
       (lambda (key job)
         (when (equal old-owner (emacsos-sms-chat-job-owner job))
           (push (cons key job) old-jobs)))
       emacsos-sms-chat--jobs)
      (dolist (entry old-jobs)
        (let ((key (car entry)) (job (cdr entry)))
          (setf (emacsos-sms-chat-job-stale job) t
                (emacsos-sms-chat-job-refreshes job) nil)
          (when-let ((timer (emacsos-sms-chat-job-timer job)))
            (cancel-timer timer))
          (when-let ((process (emacsos-sms-chat-job-process job)))
            (when (process-live-p process) (delete-process process)))
          (remhash key emacsos-sms-chat--jobs))))
    (when emacsos-sms-chat--refresh
      (emacsos-sms-chat--refresh-terminal
       emacsos-sms-chat--refresh "Modem restarted; tap Refresh"))
    (dolist (record emacsos-sms-chat--records)
      (when (and (eq (emacsos-sms-chat-record-origin record) 'local)
                 (eq (emacsos-sms-chat-record-state record) 'sending)
                 (equal (emacsos-sms-chat-record-owner record) old-owner))
        (setf (emacsos-sms-chat-record-state record) 'unknown
              (emacsos-sms-chat-record-acknowledged record) nil
              (emacsos-sms-chat-record-revision record)
              (emacsos-sms-chat--next-revision))))
    (setq emacsos-sms-chat--records
          (seq-filter
           (lambda (record)
             (if (eq (emacsos-sms-chat-record-origin record) 'modem)
                 (not (equal (emacsos-sms-chat-record-owner record) old-owner))
               (when (equal (emacsos-sms-chat-record-owner record) old-owner)
                 (setf (emacsos-sms-chat-record-owner record) nil
                       (emacsos-sms-chat-record-generation record) nil
                       (emacsos-sms-chat-record-path record) nil))
               t))
           emacsos-sms-chat--records)
          emacsos-sms-chat--notice "Modem restarted; tap Refresh")
    (emacsos-sms-chat--rerender-all)))

(defun emacsos-sms-chat--refresh-deadline (refresh)
  "Detach timed-out REFRESH and cancel work with no remaining consumer."
  (unless (emacsos-sms-chat-refresh-terminal refresh)
    (let (orphans)
      (maphash
       (lambda (_key job)
         (setf (emacsos-sms-chat-job-refreshes job)
               (delq refresh (emacsos-sms-chat-job-refreshes job)))
         (when (and (not (emacsos-sms-chat-job-live job))
                    (null (emacsos-sms-chat-job-refreshes job)))
           (push job orphans)))
       emacsos-sms-chat--jobs)
      (dolist (job orphans)
        (setf (emacsos-sms-chat-job-stale job) t)
        (pcase (emacsos-sms-chat-job-state job)
          ('queued
           (setq emacsos-sms-chat--queue
                 (delq job emacsos-sms-chat--queue))
           (remhash (emacsos-sms-chat-job-key job) emacsos-sms-chat--jobs))
          ('waiting
           (when-let ((timer (emacsos-sms-chat-job-timer job)))
             (cancel-timer timer))
           (setf (emacsos-sms-chat-job-timer job) nil)
           (remhash (emacsos-sms-chat-job-key job) emacsos-sms-chat--jobs))
          ('running nil)
          (_ (remhash (emacsos-sms-chat-job-key job)
                      emacsos-sms-chat--jobs))))
      ;; Only reap running children after queued siblings are stale and gone;
      ;; a synchronous sentinel may pump the scheduler.
      (dolist (job orphans)
        (when (eq (emacsos-sms-chat-job-state job) 'running)
          (when-let ((process (emacsos-sms-chat-job-process job)))
            (when (process-live-p process) (delete-process process)))))
    (emacsos-sms-chat--refresh-terminal refresh "Refresh timed out; tap to retry"))))

(defun emacsos-sms-chat-refresh ()
  "Refresh modem history asynchronously."
  (interactive)
  (cond
   (emacsos-sms-chat--refresh
    (message "SMS history is already refreshing"))
   ((not (and emacsos-call--current-owner
              (emacsos-call--valid-owner-p emacsos-call--current-owner)))
    (setq emacsos-sms-chat--refresh-state "Modem unavailable; tap to retry")
    (emacsos-sms-chat--rerender-all))
   ((>= (hash-table-count emacsos-sms-chat--jobs) emacsos-sms-chat--max-jobs)
    (setq emacsos-sms-chat--refresh-state "Refresh busy; tap to retry")
    (emacsos-sms-chat--rerender-all))
   (t
    (let* ((id (setq emacsos-sms-chat--next-refresh-id
                     (1+ emacsos-sms-chat--next-refresh-id)))
           (refresh (make-emacsos-sms-chat-refresh
                     :id id :owner emacsos-call--current-owner
                     :generation emacsos-call--owner-generation
                     :cutoff emacsos-sms-chat--revision :pending 0)))
      (setf (emacsos-sms-chat-refresh-deadline refresh)
            (run-at-time 35 nil #'emacsos-sms-chat--refresh-deadline refresh))
      (setq emacsos-sms-chat--refresh refresh
            emacsos-sms-chat--refresh-state "Refreshing messages...")
      (let* ((key (list 'list emacsos-call--owner-generation id))
             (job (make-emacsos-sms-chat-job
                   :key key :kind 'list :owner emacsos-call--current-owner
                   :generation emacsos-call--owner-generation
                   :refreshes (list refresh) :attempts 0 :state 'queued)))
        (puthash key job emacsos-sms-chat--jobs)
        (setq emacsos-sms-chat--queue
              (append emacsos-sms-chat--queue (list job)))
        (emacsos-sms-chat--rerender-all)
        (emacsos-sms-chat--scheduler-pump))))))

(defun emacsos-sms-chat--on-added (owner generation path)
  "Queue one trusted live SMS PATH from OWNER/GENERATION."
  (unless (emacsos-sms-chat--enqueue-snapshot owner generation path t)
    (unless (equal emacsos-sms-chat--notice "New SMS pending; tap Refresh")
      (setq emacsos-sms-chat--notice "New SMS pending; tap Refresh")
      (emacsos-sms-chat--rerender-all))))

(add-hook 'emacsos-sms-lifecycle-functions #'emacsos-sms-chat--on-lifecycle)
(add-hook 'emacsos-call-owner-changed-functions #'emacsos-sms-chat--on-owner-changed)
(add-hook 'emacsos-call-sms-added-functions #'emacsos-sms-chat--on-added)

(provide 'phone-sms-chat)
;;; phone-sms-chat.el ends here
