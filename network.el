;;; network.el --- EmacsOS network status + control -*- lexical-binding: t -*-

;; Glanceable cell/wifi status in the modeline, tappable to a `*network*'
;; control page (toggle cell/wifi, pick a wifi network).  Companion to
;; os.el (which `require's this and wires the global mode-line-format).
;;
;; Reads run through ModemManager/NetworkManager CLIs (`nmcli'/`mmcli'),
;; ALWAYS asynchronously: one `make-process' gathers every read in a
;; single shell script, a sentinel parses the blob into `emacsos-net--state',
;; and the `:eval' modeline segment + the page repaint from that cached
;; state.  Nothing on the redisplay/tap path blocks the main loop (the
;; project's prime directive — see docs/2026-05-17-streaming-responses.org).
;;
;; Connection attempts share one finite result contract.  New secured wifi
;; credentials stay in a masked minibuffer and a transient platform call;
;; cached state and rendered buffers never retain them.

(require 'cl-lib)
(require 'hex-util)
(require 'seq)
(require 'subr-x)

;; Defined in os.el (which `require's this file).  Resolved at call time.
(declare-function emacsos--btn "os")
(declare-function emacsos--center "os")
(declare-function emacsos--target "os")
(defvar emacsos--btn-label-scale)  ; label font :height; owned by os.el (vpad gives the button its tap-target height separately)
(defvar emacsos--btn-vpad)         ; vertical button padding; owned by os.el

(defcustom emacsos-net-refresh-interval 30
  "Seconds between background network-status refreshes.
Kept slow because modem status polling costs power and the result is
glanceable, not real-time."
  :type 'integer
  :group 'emacsos)

(defconst emacsos-net--buffer-name "*network*")
(defconst emacsos-net--max-reader-bytes (* 256 1024)
  "Maximum bytes accepted from one complete network-status reader.")
(defconst emacsos-net--max-reader-lines 2048
  "Maximum newline-terminated records accepted from one status reader.")
(defconst emacsos-net--max-action-bytes (* 16 1024)
  "Maximum bytes accepted from one network action.")

(defcustom emacsos-net-cell-connection "emacsos-cellular"
  "NetworkManager connection name used for cellular data."
  :type 'string
  :group 'emacsos)

(defcustom emacsos-net-command-function nil
  "Optional function translating nmcli ARGS into a process command list.
nil runs nmcli directly.  A platform can return a narrowly privileged helper
command while keeping network actions asynchronous."
  :type '(choice (const nil) function)
  :group 'emacsos)

(defcustom emacsos-net-connection-function nil
  "Optional asynchronous wifi connection function.
It receives KIND, TARGET, PASSWORD, and COMPLETION.  Returning the exact
pending token requires one later terminal COMPLETION; returning a terminal
token requires no completion.  PASSWORD is non-nil only for secured networks."
  :type '(choice (const nil) function)
  :group 'emacsos)

(defconst emacsos-net--connection-pending-result
  "pending: Wi-Fi connection requested")

(defconst emacsos-net--connection-terminal-results
  '("connected"
    "not-connected:invalid-input"
    "not-connected:busy"
    "not-connected:failed"
    "not-connected:unavailable"
    "unknown:time-limit"
    "not-connected:unsupported-security"
    "not-connected:network-not-found")
  "Complete finite grammar for terminal wifi connection results.")

;;; State

(cl-defstruct emacsos-net-state
  "Cached snapshot of network status, refreshed asynchronously."
  (wifi-on 'unknown)        ; t / nil / 'unknown (radio)
  (active-iface 'none)      ; 'wifi | 'cell | 'none — what carries the default route
  ssid                      ; current wifi SSID string, or nil
  signal                    ; 0-100 signal of the active iface, or nil
  (wifi-list nil)           ; one plist per SSID (:signal :security :in-use :saved-uuid)
  (saved-known nil)         ; t only after a complete saved-profile enumeration
  (cell-provisioned nil)    ; t once the named GSM connection exists
  (cell-on nil)             ; t while that NetworkManager profile is active
  (cell-state "")           ; mmcli modem state: "registered" / "searching" / "" ...
  (stamp 0.0)               ; float-time of the snapshot
  (valid nil)               ; t only after a complete successful reader pass
  error                     ; bounded reader launch/exit/parse failure, or nil
  wifi-error                ; Wi-Fi radio action launch/terminal failure, or nil
  wifi-pending              ; 'on / 'off while a Wi-Fi radio setter is pending
  cell-error                ; cellular action launch/terminal failure, or nil
  cell-pending)             ; 'on / 'off while a cellular setter is pending

(defvar emacsos-net--state (make-emacsos-net-state)
  "The latest `emacsos-net-state', updated by network readers and actions.")

(defvar emacsos-net-state-change-functions nil
  "Functions called after cached network state changes.")

(defvar emacsos-net--cell-operation nil
  "Current cellular setter completion identity, or nil.")

(defvar emacsos-net--wifi-operation nil
  "Current Wi-Fi radio setter completion identity, or nil.")

(defvar emacsos-net--action-processes nil
  "Network-action processes retained across reload for bounded teardown.")

(defvar emacsos-net--settle-generation 0
  "Monotonic identity for delayed post-action status refreshes.")

(defvar emacsos-net--settle-pending nil
  "Generation awaiting its delayed post-action status refresh, or nil.")

(defun emacsos-net--notify-state-change ()
  "Refresh consumers after cached network state changes."
  (force-mode-line-update t)
  (emacsos-net--render-if-shown)
  (run-hooks 'emacsos-net-state-change-functions))

(defvar emacsos-net--proc nil
  "Live status-reader process, or nil.  Single-flight guard: a refresh
no-ops while this is live, so concurrent reads cannot stack on the phone.")

(defun emacsos-net--cleanup-reader-temp (proc)
  "Remove the private temporary directory owned by reader PROC."
  (let ((directory (ignore-errors
                     (process-get proc 'emacsos-net-temp-directory))))
    (when (stringp directory)
      (ignore-errors (delete-directory directory t))
      (ignore-errors
        (process-put proc 'emacsos-net-temp-directory nil)))))

(defun emacsos-net--ensure-state-shape ()
  "Reset cached network state when hot reload changes its struct layout."
  (unless (condition-case nil
              (progn
                (emacsos-net-state-cell-pending emacsos-net--state)
                (emacsos-net-state-wifi-pending emacsos-net--state)
                t)
            (error nil))
    (setq emacsos-net--state (make-emacsos-net-state))))

(defun emacsos-net--kill-reader-process (proc)
  "Kill background PROC and its process group when it is still live."
  (when (process-live-p proc)
    (let ((pid (process-id proc)))
      (when (integerp pid)
        (ignore-errors (signal-process (- pid) 'SIGKILL))))
    (when (process-live-p proc)
      (delete-process proc))))

(defun emacsos-net--discard-reader ()
  "Discard an in-flight status read, output buffer, and private temp data."
  (when emacsos-net--proc
    (let ((proc emacsos-net--proc))
      (setq emacsos-net--proc nil)
      (set-process-sentinel proc #'ignore)
      (emacsos-net--kill-reader-process proc)
      (emacsos-net--cleanup-reader-temp proc)
      (when (buffer-live-p (process-buffer proc))
        (kill-buffer (process-buffer proc))))))

(defun emacsos-net--reader-filter (proc output)
  "Buffer bounded status OUTPUT from reader PROC, or terminate it on overflow."
  (unless (process-get proc 'emacsos-net-overflow)
    (let ((bytes (+ (or (process-get proc 'emacsos-net-bytes) 0)
                    (string-bytes output)))
          (lines (+ (or (process-get proc 'emacsos-net-lines) 0)
                    (cl-count ?\n output))))
      (if (or (> bytes emacsos-net--max-reader-bytes)
              (> lines emacsos-net--max-reader-lines))
          (progn
            (process-put proc 'emacsos-net-overflow t)
            (emacsos-net--kill-reader-process proc))
        (process-put proc 'emacsos-net-bytes bytes)
        (process-put proc 'emacsos-net-lines lines)
        (when-let ((buffer (process-buffer proc)))
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (goto-char (point-max))
              (insert output))))))))

(defun emacsos-net--action-filter (proc output)
  "Buffer bounded network-action OUTPUT from PROC, or terminate on overflow."
  (unless (process-get proc 'emacsos-net-action-overflow)
    (let ((bytes (+ (or (process-get proc 'emacsos-net-action-bytes) 0)
                    (string-bytes output))))
      (if (> bytes emacsos-net--max-action-bytes)
          (progn
            (process-put proc 'emacsos-net-action-overflow t)
            (emacsos-net--kill-reader-process proc))
        (process-put proc 'emacsos-net-action-bytes bytes)
        (when-let ((buffer (process-buffer proc)))
          (when (buffer-live-p buffer)
            (with-current-buffer buffer
              (goto-char (point-max))
              (insert output))))))))

(defun emacsos-net--discard-actions ()
  "Terminate tracked and pre-upgrade network actions, retaining sentinels."
  (let ((processes
         (delete-dups
          (append emacsos-net--action-processes
                  (seq-filter
                   (lambda (proc)
                     (string-match-p
                      "\\`emacsos-net-act\\(?:<[0-9]+>\\)?\\'"
                      (process-name proc)))
                   (process-list))))))
    (setq emacsos-net--action-processes nil)
    (dolist (proc processes)
      ;; The existing sentinel owns exactly-once completion and pending-state
      ;; release, including for an action launched by pre-upgrade code.
      (emacsos-net--kill-reader-process proc))))

;; `defvar' preserves old state and processes when this file is hot-reloaded.
(emacsos-net--ensure-state-shape)
(emacsos-net--discard-reader)
(emacsos-net--discard-actions)

(defvar emacsos-net--timer nil
  "Repeat timer driving background refresh.  Guarded so a hot-reload of
this file (the agent-customization workflow) doesn't stack timers.")

(defvar emacsos-net--connection-attempt-id 0
  "Monotonic owner ID for wifi connection presentation state.")

(defvar emacsos-net--connection-pending nil
  "Current connection owner plist (:id :ssid :kind), or nil.")

(defvar emacsos-net--connection-result nil
  "Visible terminal result plist (:id :text), or nil.")

(defvar emacsos-net--connection-result-timer nil
  "Timer which expires `emacsos-net--connection-result'.")

(defvar emacsos-net-return-function nil
  "Optional command used by the bounded phone chooser's Done action.")

(defvar emacsos-net--page 0
  "Zero-based page displayed by the bounded phone network chooser.")

(defconst emacsos-net--page-size 4)

;;; Terse-output parsing (pure)

(defun emacsos-net--split-terse (line)
  "Split an `nmcli -t' LINE on UNescaped colons, then un-escape.
nmcli escapes a literal colon in a value as \"\\:\" and a backslash as
\"\\\\\"; SSIDs can contain colons, so a naive split is wrong."
  (let ((fields nil) (cur "") (i 0) (n (length line)))
    (while (< i n)
      (let ((c (aref line i)))
        (cond
         ((and (eq c ?\\) (< (1+ i) n))
          (setq cur (concat cur (char-to-string (aref line (1+ i)))) i (+ i 2)))
         ((eq c ?:)
          (push cur fields) (setq cur "" i (1+ i)))
         (t (setq cur (concat cur (char-to-string c)) i (1+ i))))))
    (push cur fields)
    (nreverse fields)))

(defun emacsos-net--split-terse-kv (line)
  "Split an mmcli `--output-keyvalue' LINE \"key : value\" into (KEY . VALUE).
Returns nil for a line without the \" : \" separator."
  (when (string-match "\\`\\(.*?\\) *: *\\(.*\\)\\'" line)
    (cons (match-string 1 line) (match-string 2 line))))

(defun emacsos-net--section (blob name)
  "Return the lines of section NAME from BLOB, a string the reader builds
with \"@@<NAME>\" marker lines between each command's output."
  (let ((lines (split-string blob "\n"))
        (want (concat "@@" name)) (in nil) (out nil))
    (dolist (l lines)
      (cond
       ((string-prefix-p "@@" l) (setq in (string= l want)))
       ((and in (not (string-empty-p l))) (push l out))))
    (nreverse out)))

(defun emacsos-net--decode-ssid-hex (value)
  "Decode a bounded hexadecimal SSID VALUE, or return nil when unsafe."
  (when (and (stringp value)
             (string-match-p
              "\\`\\(?:[0-9A-Fa-f][0-9A-Fa-f]\\)\\{1,32\\}\\'" value))
    (let ((ssid (decode-coding-string (decode-hex-string value) 'utf-8)))
      (and (not (seq-some (lambda (char)
                            (eq (char-charset char) 'eight-bit))
                          ssid))
           (emacsos-net--valid-ssid-p ssid)
           ssid))))

(defun emacsos-net--valid-uuid-p (value)
  "Non-nil when VALUE is a canonical hexadecimal UUID string."
  (and (stringp value)
       (string-match-p
        "\\`[0-9A-Fa-f]\\{8\\}-[0-9A-Fa-f]\\{4\\}-[0-9A-Fa-f]\\{4\\}-[0-9A-Fa-f]\\{4\\}-[0-9A-Fa-f]\\{12\\}\\'"
        value)))

(defun emacsos-net--unique-saved-uuid (ssid records)
  "Return SSID's UUID only when RECORDS contains exactly one match."
  (let ((matches (seq-filter (lambda (record) (equal (car record) ssid))
                             records)))
    (and (= (length matches) 1) (cdar matches))))

(defun emacsos-net--coalesce-visible-network (current candidate)
  "Merge same-SSID CURRENT and CANDIDATE scan records deterministically.
Prefer the active record, then the stronger signal.  Conflicting security
modes fail closed as unsupported unless a saved UUID supplies the target."
  (let* ((current-security (or (plist-get current :security) ""))
         (candidate-security (or (plist-get candidate :security) ""))
         (same-security
          (or (equal current-security candidate-security)
              (and (member current-security '("" "--"))
                   (member candidate-security '("" "--")))))
         (preferred
          (cond
           ((plist-get candidate :in-use) candidate)
           ((plist-get current :in-use) current)
           ((> (or (plist-get candidate :signal) 0)
               (or (plist-get current :signal) 0))
            candidate)
           (t current)))
         (merged (copy-sequence preferred)))
    (unless same-security
      (setf (plist-get merged :security) "ambiguous"))
    merged))

(defun emacsos-net--parse (blob)
  "Parse the reader's delimited BLOB into a fresh `emacsos-net-state'.
The radio and NetworkManager records must use the complete finite grammar;
optional modem status may be absent.  Duplicate scan records collapse by SSID;
conflicting security modes fail closed unless a saved UUID supplies the
connection target."
  (let* ((radio (car (emacsos-net--section blob "RADIO")))
         (rfields (and radio (emacsos-net--split-terse radio)))
         (wifi-on (cond ((equal rfields '("enabled")) t)
                        ((equal rfields '("disabled")) nil)
                        (t (error "invalid Wi-Fi radio snapshot"))))
         ;; default route device: wl* -> wifi, ww* -> cell
         (route (car (emacsos-net--section blob "ROUTE")))
         (active-iface (cond ((null route) 'none)
                             ((string-match-p "\\bdev wl" route) 'wifi)
                             ((string-match-p "\\bdev ww" route) 'cell)
                             (t 'none)))
         ;; saved wifi UUIDs and actual SSIDs come from the dedicated section.
         (saved-records
          (mapcar
           (lambda (line)
             (let* ((fields (emacsos-net--split-terse line))
                    (uuid (and (= (length fields) 2) (nth 0 fields)))
                    (ssid (and uuid (emacsos-net--decode-ssid-hex
                                     (nth 1 fields)))))
               (and (emacsos-net--valid-uuid-p uuid)
                    ssid
                    (cons ssid uuid))))
           (emacsos-net--section blob "SAVED")))
         (saved (delq nil (copy-sequence saved-records)))
         (saved-known
          (and (equal (emacsos-net--section blob "SAVED-OK") '("yes"))
               (null (emacsos-net--section blob "SAVED-FAILED"))
               (cl-every #'identity saved-records)))
         (cell-provisioned nil) (cell-on nil))
    (dolist (l (emacsos-net--section blob "CONS"))
      (let* ((f (emacsos-net--split-terse l))
             (type (nth 0 f))
             (device (nth 1 f)))
        (unless (= (length f) 2)
          (error "invalid NetworkManager connection snapshot"))
        (when (string= type "gsm")
          (setq cell-provisioned t
                cell-on (and device
                             (not (string-empty-p device))
                             (not (string= device "--")))))))
    ;; wifi networks from `dev wifi'
    (let (wifi-list cur-ssid cur-signal)
      (dolist (l (emacsos-net--section blob "WIFI"))
        (let* ((f (emacsos-net--split-terse l))
               (active (nth 0 f))
               (signal-text (nth 2 f)))
          (unless (and (= (length f) 4)
                       (member active '("yes" "no"))
                       (stringp signal-text)
                       (string-match-p "\\`[0-9]+\\'" signal-text)
                       (<= (string-to-number signal-text) 100))
            (error "invalid NetworkManager Wi-Fi snapshot"))
          (let ((in-use (string= active "yes"))
                (ssid (emacsos-net--decode-ssid-hex (nth 1 f)))
                (sig (string-to-number signal-text))
                (sec (or (nth 3 f) "")))
            (when ssid
              (when in-use (setq cur-ssid ssid cur-signal sig))
              (let* ((candidate
                      (list :ssid ssid :signal sig :security sec
                            :in-use in-use
                            :saved-uuid
                            (emacsos-net--unique-saved-uuid ssid saved)))
                     (current
                      (seq-find (lambda (item)
                                  (string= (plist-get item :ssid) ssid))
                                wifi-list)))
                (if current
                    (setcar (memq current wifi-list)
                            (emacsos-net--coalesce-visible-network
                             current candidate))
                  (push candidate wifi-list)))))))
      ;; cell registration/signal from mmcli key=value
      (let (cell-state cell-signal)
        (dolist (l (emacsos-net--section blob "CELL"))
          (let ((f (emacsos-net--split-terse-kv l)))
            (when f
              (cond
               ((string-match-p "\\.state$" (car f)) (setq cell-state (cdr f)))
               ((string-match-p "signal-quality\\.value$" (car f))
                (let ((signal-text (cdr f)))
                  (unless (string-empty-p signal-text)
                    (unless (and (string-match-p "\\`[0-9]+\\'" signal-text)
                                 (<= (string-to-number signal-text) 100))
                      (error "invalid ModemManager signal snapshot"))
                    (setq cell-signal (string-to-number signal-text)))))))))
        (make-emacsos-net-state
         :wifi-on wifi-on
         :active-iface active-iface
         :ssid cur-ssid
         :signal (cond ((eq active-iface 'wifi) cur-signal)
                       ((eq active-iface 'cell) cell-signal)
                       (t nil))
         :wifi-list (nreverse wifi-list)
         :saved-known saved-known
         :cell-provisioned cell-provisioned
         :cell-on cell-on
         :cell-state (or cell-state "")
         :stamp (float-time)
         :valid t)))))

;;; Modeline segment (pure: state -> propertized string)

(defun emacsos-net--segment-text (st)
  "Return the bare status text for state ST (no text properties)."
  (pcase (emacsos-net-state-active-iface st)
    ('wifi (format "wifi %s%%" (or (emacsos-net-state-signal st) "?")))
    ('cell (format "lte %s%%"  (or (emacsos-net-state-signal st) "?")))
    (_     "no net")))

(defconst emacsos-net--mode-line-keymap
  (let ((m (make-sparse-keymap)))
    (define-key m [mode-line mouse-1] #'emacsos-net-show)
    m)
  "Keymap for the tappable modeline segment.  Built once (the segment's
`:eval' runs on every redisplay, so it must not allocate).")

(defun emacsos-net-mode-line-string ()
  "Modeline segment: a tappable cell/wifi status string.
Wrapped so a redisplay-time error can never brick the modeline."
  (condition-case nil
      (propertize (emacsos-net--segment-text emacsos-net--state)
                  'local-map emacsos-net--mode-line-keymap
                  'mouse-face 'mode-line-highlight
                  'help-echo "Network — tap for controls")
    (error "net?")))

;;; Connect-kind seam

(defun emacsos-net--connect-kind (net)
  "Classify wifi NET (a `wifi-list' plist) for connecting:
`saved' (NM has a profile UUID), `open', `needs-password' (visible WEP or
WPA-Personal), or `unsupported-security' (for example 802.1X)."
  (cond ((plist-get net :saved-uuid) 'saved)
        ((member (plist-get net :security) '(nil "" "--")) 'open)
        ((let ((case-fold-search t)
               (security (or (plist-get net :security) "")))
           (and (not (string-match-p "802[.-]1x" security))
                (string-match-p
                 "\\(?:\\`\\|[[:space:]]\\)\\(?:wep\\|wpa\\)" security)))
         'needs-password)
        (t 'unsupported-security)))

;;; Async refresh

(defun emacsos-net--reader-script ()
  "Shell script gathering every read into one delimited blob.
One Emacs process and sentinel own the reader.  Its TERM trap kills and reaps
the active system tool, so the outer deadline cannot leave a child behind.
Emacs owns and removes the private temp directory even after a forced kill.
The saved-profile snapshot is accepted only when the helper's durable,
monotonic ownership record is identical before and after enumeration.  SSID
bytes are hex-encoded before entering the line protocol."
  (concat
   "child=; reader_dir=$2; pending_file=$3; [ -d \"$reader_dir\" ] && [ -n \"$pending_file\" ] || exit 1; reader_file=$reader_dir/connections; saved_ssid_file=$reader_dir/saved-ssid; pending_before_file=$reader_dir/pending-before; pending_after_file=$reader_dir/pending-after; pending_generation=; pending_kind=; pending_value=; pending_extra=; pending_uuid=; pending_valid=yes; "
   "stop_child() { if [ -n \"$child\" ]; then kill -KILL \"$child\" 2>/dev/null || :; wait \"$child\" 2>/dev/null || :; child=; fi; }; "
   "cleanup() { stop_child; [ -z \"$reader_file\" ] || rm -f -- \"$reader_file\"; [ -z \"$saved_ssid_file\" ] || rm -f -- \"$saved_ssid_file\"; [ -z \"$pending_before_file\" ] || rm -f -- \"$pending_before_file\"; [ -z \"$pending_after_file\" ] || rm -f -- \"$pending_after_file\"; }; "
   "trap 'cleanup; exit 1' HUP INT TERM; trap cleanup EXIT; "
   "read_command() { \"$@\" & child=$!; if wait \"$child\"; then status=0; else status=$?; fi; child=; return \"$status\"; }; "
   "snapshot_marker() { marker_target=$1; if [ -e \"$pending_file\" ]; then read_command cat -- \"$pending_file\" >\"$marker_target\" 2>/dev/null || return 1; else printf '0:idle\\n' >\"$marker_target\" || return 1; fi; [ \"$(wc -c <\"$marker_target\")\" -le 128 ] && [ \"$(wc -l <\"$marker_target\")\" -eq 1 ]; }; "
   ": >\"$reader_file\" || exit 1; : >\"$saved_ssid_file\" || exit 1; "
   "if snapshot_marker \"$pending_before_file\" && grep -Eq '^(0|[1-9][0-9]*):(idle|name:emacsos-wifi-attempt-[0-9a-f]{32}|uuid:[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12})$' \"$pending_before_file\" && IFS=: read -r pending_generation pending_kind pending_value pending_extra <\"$pending_before_file\"; then "
   "case $pending_generation in ''|*[!0-9]*) pending_valid=no ;; esac; [ \"${#pending_generation}\" -le 19 ] || pending_valid=no; "
   "case $pending_kind in idle) [ -z \"$pending_value$pending_extra\" ] || pending_valid=no ;; name) [ -z \"$pending_extra\" ] && printf '%s\\n' \"$pending_value\" | grep -Eq '^emacsos-wifi-attempt-[0-9a-f]{32}$' || pending_valid=no ;; uuid) [ -z \"$pending_extra\" ] && printf '%s\\n' \"$pending_value\" | grep -Eq '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' || pending_valid=no ;; *) pending_valid=no ;; esac; "
   "else pending_valid=no; fi; "
   "if [ \"$pending_valid\" = yes ] && [ \"$pending_kind\" = uuid ]; then pending_uuid=$pending_value; fi; "
   "echo @@RADIO; read_command nmcli -t -f WIFI radio 2>/dev/null || :; "
   "echo @@ROUTE; read_command ip -4 route show default 2>/dev/null || :; "
   "echo @@CONS; "
   "cell_type=; if read_command nmcli -e no -t -g connection.type con show id \"$1\" >\"$reader_file\" 2>/dev/null; then IFS= read -r cell_type <\"$reader_file\" || :; fi; "
   "cell_device=; if read_command nmcli -e no -t -g GENERAL.DEVICES con show id \"$1\" >\"$reader_file\" 2>/dev/null; then IFS= read -r cell_device <\"$reader_file\" || :; fi; "
   "printf '%s:%s\\n' \"$cell_type\" \"$cell_device\"; "
   "echo @@SAVED; "
   "if read_command nmcli -t -f UUID,TYPE con show >\"$reader_file\" 2>/dev/null; then "
   "if [ \"$pending_valid\" = yes ] && [ \"$pending_kind\" = name ]; then pending_lookup_status=0; read_command nmcli -e no -t -g UUID con show id \"$pending_value\" >\"$saved_ssid_file\" 2>/dev/null || pending_lookup_status=$?; "
   "case $pending_lookup_status in 0) if [ \"$(wc -l <\"$saved_ssid_file\")\" -eq 1 ]; then IFS= read -r pending_uuid <\"$saved_ssid_file\" || :; printf '%s\\n' \"$pending_uuid\" | grep -Eq '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' || pending_valid=no; else pending_valid=no; fi ;; 10) [ ! -s \"$saved_ssid_file\" ] || pending_valid=no ;; *) pending_valid=no ;; esac; fi; "
   "if [ \"$pending_valid\" != yes ]; then echo @@SAVED-FAILED; echo yes; fi; "
   "while IFS=: read -r uuid type || [ -n \"$uuid$type\" ]; do "
   "[ \"$type\" = 802-11-wireless ] || continue; "
   "if [ -n \"$pending_uuid\" ] && [ \"$pending_uuid\" = \"$uuid\" ]; then continue; fi; "
   "if read_command nmcli -e no -t -g 802-11-wireless.ssid con show uuid \"$uuid\" >\"$saved_ssid_file\" 2>/dev/null; then "
   "ssid_hex=$(od -An -v -tx1 \"$saved_ssid_file\" | tr -d '[:space:]'); "
   "case $ssid_hex in *0a) ssid_hex=${ssid_hex%0a} ;; *) ssid_hex= ;; esac; "
   "if [ -n \"$ssid_hex\" ]; then printf '%s:%s\\n' \"$uuid\" \"$ssid_hex\"; "
   "else echo @@SAVED-FAILED; echo yes; fi; "
   "else echo @@SAVED-FAILED; echo yes; fi; done <\"$reader_file\"; "
   "else echo @@SAVED-FAILED; echo yes; fi; "
   "if ! snapshot_marker \"$pending_after_file\" || ! cmp -s \"$pending_before_file\" \"$pending_after_file\"; then echo @@SAVED-FAILED; echo yes; fi; "
   "echo @@SAVED-OK; echo yes; "
   "echo @@WIFI;  read_command nmcli -t -f ACTIVE,SSID-HEX,SIGNAL,SECURITY dev wifi 2>/dev/null || :; "
   "echo @@CELL;  read_command mmcli -m any --output-keyvalue 2>/dev/null || :; "
   "echo @@END"))

(defun emacsos-net--bounded-detail (text fallback)
  "Return one bounded display line from TEXT, or FALLBACK when it is empty."
  (let ((detail (string-trim
                 (replace-regexp-in-string "[\n\r\t]+" " " (or text "")))))
    (if (string-empty-p detail)
        fallback
      (substring detail 0 (min 256 (length detail))))))

(defun emacsos-net--record-reader-error (detail)
  "Mark the cached network snapshot invalid with bounded DETAIL."
  (let ((state (copy-emacsos-net-state emacsos-net--state)))
    (setf (emacsos-net-state-valid state) nil
          (emacsos-net-state-error state)
          (emacsos-net--bounded-detail detail "network status failed"))
    (setq emacsos-net--state state)
    (emacsos-net--notify-state-change)))

(defun emacsos-net--retry ()
  "Clear a cached reader error and retry its asynchronous snapshot."
  (let ((state (copy-emacsos-net-state emacsos-net--state)))
    (setf (emacsos-net-state-valid state) nil
          (emacsos-net-state-error state) nil)
    (setq emacsos-net--state state))
  (emacsos-net--notify-state-change)
  (emacsos-net--refresh))

(defun emacsos-net--refresh ()
  "Kick off a background status read when no reader or action settle is active."
  (interactive)
  (when (and (not emacsos-net--settle-pending)
             (or (null emacsos-net--proc)
                 (not (process-live-p emacsos-net--proc))))
    (let ((buf (generate-new-buffer " *emacsos-net-read*"))
          reader-directory)
      (condition-case err
          (progn
            (setq reader-directory (make-temp-file "emacsos-net-reader-" t))
            (setq emacsos-net--proc
                  (make-process
                   :name "emacsos-net-read"
                   :buffer buf
                   :command (list "/usr/bin/timeout" "-s" "TERM" "-k" "1" "8"
                                  "sh" "-c" (emacsos-net--reader-script)
                                  "emacsos-net-read" emacsos-net-cell-connection
                                  reader-directory
                                  "/var/lib/emacsos-openrc-wifi-pending")
                   :noquery t
                   :coding 'binary
                   :filter #'emacsos-net--reader-filter
                   :sentinel #'emacsos-net--reader-sentinel))
            (process-put emacsos-net--proc 'emacsos-net-temp-directory
                         reader-directory)
            (emacsos-net--render-if-shown))
        (error
         (when reader-directory
           (ignore-errors (delete-directory reader-directory t)))
         (kill-buffer buf)
         (let ((detail (error-message-string err)))
           (emacsos-net--record-reader-error detail)
           (message "emacsos-net: cannot read network status: %s" detail)))))))

(defun emacsos-net--reader-sentinel (proc _event)
  "On reader exit, accept only a successful, complete snapshot.
Clear the single-flight guard after every terminal state while retaining the
last valid snapshot after failure or timeout."
  (when (memq (process-status proc) '(exit signal))
    (let ((buf (process-buffer proc)))
      (unwind-protect
          (when (eq proc emacsos-net--proc)
            (let ((blob (if (buffer-live-p buf)
                            (with-current-buffer buf (buffer-string))
                          "")))
              (if (process-get proc 'emacsos-net-overflow)
                  (emacsos-net--record-reader-error
                   "network status response is too large")
                (if (and (eq (process-status proc) 'exit)
                       (zerop (process-exit-status proc))
                       (string-suffix-p "@@END\n" blob))
                  (condition-case err
                      (let ((state (emacsos-net--parse blob)))
                        (setf (emacsos-net-state-cell-error state)
                              (emacsos-net-state-cell-error emacsos-net--state)
                              (emacsos-net-state-cell-pending state)
                              (emacsos-net-state-cell-pending emacsos-net--state)
                              (emacsos-net-state-wifi-error state)
                              (emacsos-net-state-wifi-error emacsos-net--state)
                              (emacsos-net-state-wifi-pending state)
                              (emacsos-net-state-wifi-pending emacsos-net--state))
                        (setq emacsos-net--state state)
                        (emacsos-net--notify-state-change))
                    (error
                     (emacsos-net--record-reader-error
                      (error-message-string err))))
                  (emacsos-net--record-reader-error
                   (format "network reader exited %s"
                           (process-exit-status proc)))))))
        (emacsos-net--cleanup-reader-temp proc)
        (when (eq proc emacsos-net--proc)
          (setq emacsos-net--proc nil))
        (when (buffer-live-p buf) (kill-buffer buf))))))

;;; Control actions

(defun emacsos-net--action (args &optional completion)
  "Run an `nmcli' command ARGS asynchronously.
Call COMPLETION once as (SUCCESS DETAIL) after destroying the process buffer.
The post-action refresh is delayed ~1.5s so nmcli has time to settle."
  (let (buffer (completed nil))
    (condition-case err
        (let ((command (if emacsos-net-command-function
                           (funcall emacsos-net-command-function args)
                         (cons "nmcli" args))))
          (setq buffer (generate-new-buffer " *emacsos-net-act*"))
          (let ((process
                 (make-process
                  :name "emacsos-net-act"
                  :buffer buffer
                  :command (append
                            '("/usr/bin/timeout" "-s" "TERM" "-k" "1" "8")
                            command)
                  :coding 'binary
                  :filter #'emacsos-net--action-filter
                  :noquery t
                  :sentinel
                  (lambda (process _event)
                    (when (memq (process-status process) '(exit signal))
                      (setq emacsos-net--action-processes
                            (delq process emacsos-net--action-processes))
                      (when (not completed)
                        (setq completed t)
                        (let* ((status (process-exit-status process))
                               (overflow
                                (process-get
                                 process 'emacsos-net-action-overflow))
                               (success (and (not overflow)
                                             (eq (process-status process) 'exit)
                                             (zerop status)))
                               (process-buffer (process-buffer process))
                               (output (if (buffer-live-p process-buffer)
                                           (with-current-buffer process-buffer
                                             (buffer-string))
                                         ""))
                               (detail
                                (cond
                                 (overflow
                                  "network action response is too large")
                                 ((= status 124) "network action timed out")
                                 (t (emacsos-net--bounded-detail
                                     output
                                     (if success "ok"
                                       (format
                                        "network action exited %s" status)))))))
                          (when (buffer-live-p process-buffer)
                            (kill-buffer process-buffer))
                          (emacsos-net--discard-reader)
                          (setq emacsos-net--settle-generation
                                (1+ emacsos-net--settle-generation)
                                emacsos-net--settle-pending
                                emacsos-net--settle-generation)
                          (unwind-protect
                              (when completion
                                (funcall completion success detail))
                            (run-with-timer
                             1.5 nil #'emacsos-net--refresh-after-action
                             emacsos-net--settle-generation)))))))))
            (when (process-live-p process)
              (push process emacsos-net--action-processes))
            process))
      (error
       (when (buffer-live-p buffer) (kill-buffer buffer))
       (let ((detail (emacsos-net--bounded-detail
                      (error-message-string err)
                      "network action could not start")))
         (when completion (funcall completion nil detail))
         (message "emacsos-net: cannot change network: %s" detail)
         nil)))))

(defun emacsos-net--refresh-after-action (generation)
  "Refresh after action settle when GENERATION is still current."
  (when (eq generation emacsos-net--settle-pending)
    (setq emacsos-net--settle-pending nil)
    (emacsos-net--discard-reader)
    (emacsos-net--refresh)))

(defun emacsos-net-toggle-wifi ()
  "Toggle the Wi-Fi radio through its explicit setter."
  (interactive)
  (emacsos-net-set-wifi
   (not (eq (emacsos-net-state-wifi-on emacsos-net--state) t))))

(defun emacsos-net-set-wifi (enabled &optional completion)
  "Set the Wi-Fi radio to ENABLED asynchronously.
COMPLETION, when non-nil, receives (SUCCESS DETAIL) exactly once."
  (interactive
   (list (string= (completing-read "Wi-Fi: " '("on" "off") nil t) "on")))
  (unless (memq enabled '(nil t))
    (user-error "Wi-Fi state must be t or nil"))
  (cond
   ((not (emacsos-net-state-valid emacsos-net--state))
    (let ((detail "Wi-Fi status is unavailable"))
      (when completion (funcall completion nil detail))
      (concat "error: " detail)))
   (emacsos-net--wifi-operation
    (let ((detail "Wi-Fi operation is already running"))
      (when completion (funcall completion nil detail))
      (concat "error: " detail)))
   (t
    (let ((prior-wifi-on (emacsos-net-state-wifi-on emacsos-net--state))
          finished)
      (setq finished
            (lambda (success detail)
              (when (eq finished emacsos-net--wifi-operation)
                (setq emacsos-net--wifi-operation nil)
                (let ((state (copy-emacsos-net-state emacsos-net--state)))
                  (setf (emacsos-net-state-wifi-pending state) nil)
                  (if success
                      (setf (emacsos-net-state-wifi-on state) enabled
                            (emacsos-net-state-wifi-error state) nil)
                    (setf (emacsos-net-state-wifi-on state) prior-wifi-on
                          (emacsos-net-state-wifi-error state)
                          (emacsos-net--bounded-detail detail "Wi-Fi action failed")))
                  (setq emacsos-net--state state)
                  (emacsos-net--notify-state-change)))
              (when completion (funcall completion success detail))))
      (setq emacsos-net--wifi-operation finished)
      (let ((state (copy-emacsos-net-state emacsos-net--state)))
        (setf (emacsos-net-state-wifi-pending state) (if enabled 'on 'off)
              (emacsos-net-state-wifi-error state) nil)
        (setq emacsos-net--state state)
        (emacsos-net--notify-state-change))
      (if (emacsos-net--action
           (list "radio" "wifi" (if enabled "on" "off")) finished)
          (format "pending: Wi-Fi turning %s" (if enabled "on" "off"))
        (when (eq finished emacsos-net--wifi-operation)
          (setq emacsos-net--wifi-operation nil)
          (let ((state (copy-emacsos-net-state emacsos-net--state)))
            (setf (emacsos-net-state-wifi-pending state) nil
                  (emacsos-net-state-wifi-error state)
                  "network action could not start")
            (setq emacsos-net--state state)
            (emacsos-net--notify-state-change)))
        "error: network action could not start")))))

(defun emacsos-net-toggle-cell ()
  "Bring the cellular connection up or down.
Only meaningful once `make cellular-bringup' has created the connection."
  (interactive)
  (emacsos-net-set-cell (not (emacsos-net-state-cell-on emacsos-net--state))))

(defun emacsos-net-set-cell (enabled &optional completion)
  "Set the named cellular data profile to ENABLED asynchronously.
COMPLETION, when non-nil, receives (SUCCESS DETAIL) exactly once."
  (interactive
   (list (string= (completing-read "Cellular data: " '("on" "off") nil t)
                  "on")))
  (unless (memq enabled '(nil t))
    (user-error "Cellular data state must be t or nil"))
  (cond
   ((not (emacsos-net-state-valid emacsos-net--state))
    (let ((detail "cellular status is unavailable"))
      (when completion (funcall completion nil detail))
      (concat "error: " detail)))
   ((not (emacsos-net-state-cell-provisioned emacsos-net--state))
    (let ((detail "cellular data is not set up"))
      (when completion (funcall completion nil detail))
      (concat "error: " detail)))
   (emacsos-net--cell-operation
    (let ((detail "cellular operation is already running"))
      (when completion (funcall completion nil detail))
      (concat "error: " detail)))
   (t
    (let ((prior-cell-on (emacsos-net-state-cell-on emacsos-net--state))
          finished)
      (setq finished
            (lambda (success detail)
              (when (eq finished emacsos-net--cell-operation)
                (setq emacsos-net--cell-operation nil)
                (let ((state (copy-emacsos-net-state emacsos-net--state)))
                  (setf (emacsos-net-state-cell-pending state) nil)
                  (if success
                      (setf (emacsos-net-state-cell-on state) enabled
                            (emacsos-net-state-cell-error state) nil)
                    (setf (emacsos-net-state-cell-on state) prior-cell-on
                          (emacsos-net-state-cell-error state)
                          (emacsos-net--bounded-detail
                           detail "cellular action failed")))
                  (setq emacsos-net--state state)
                  (emacsos-net--notify-state-change)))
              (when completion (funcall completion success detail))))
      (setq emacsos-net--cell-operation finished)
      (let ((state (copy-emacsos-net-state emacsos-net--state)))
        (setf (emacsos-net-state-cell-pending state) (if enabled 'on 'off)
              (emacsos-net-state-cell-error state) nil)
        (setq emacsos-net--state state)
        (emacsos-net--notify-state-change))
      (if (emacsos-net--action
           (list "con" (if enabled "up" "down") emacsos-net-cell-connection)
           finished)
          (format "pending: cellular data turning %s" (if enabled "on" "off"))
        (when (eq finished emacsos-net--cell-operation)
          (setq emacsos-net--cell-operation nil)
          (let ((state (copy-emacsos-net-state emacsos-net--state)))
            (setf (emacsos-net-state-cell-pending state) nil
                  (emacsos-net-state-cell-error state)
                  "network action could not start")
            (setq emacsos-net--state state)
            (emacsos-net--notify-state-change)))
        "error: network action could not start")))))

(defun emacsos-net--display-ssid (ssid)
  "Return SSID as one safe display line with controls visibly escaped."
  (let* ((print-escape-newlines t)
         (print-escape-control-characters t)
         (printed (prin1-to-string (substring-no-properties ssid))))
    (substring printed 1 -1)))

(defun emacsos-net--terminal-result-p (result)
  "Non-nil when RESULT is in the declared terminal connection grammar."
  (and (stringp result)
       (member result emacsos-net--connection-terminal-results)))

(defun emacsos-net--result-text (ssid result)
  "Map terminal RESULT for SSID to bounded user-facing prose."
  (pcase result
    ("connected"
     (format "Connected to %s. If pages don’t load, open Firefox to sign in."
             (emacsos-net--display-ssid ssid)))
    ((or "not-connected:failed" "not-connected:invalid-input"
         "not-connected:busy")
     "Couldn’t connect. Try again.")
    ("not-connected:unavailable" "Wi-Fi controls unavailable.")
    ("unknown:time-limit"
     "Connection timed out. Check Wi-Fi status before trying again.")
    ("not-connected:unsupported-security"
     "Enterprise Wi-Fi isn’t supported yet.")
    ("not-connected:network-not-found"
     "Hidden networks aren’t supported yet.")
    (_ "Couldn’t connect. Try again.")))

(defun emacsos-net--expire-result (attempt-id)
  "Clear the visible result only when it still belongs to ATTEMPT-ID."
  (when (eq attempt-id (plist-get emacsos-net--connection-result :id))
    (setq emacsos-net--connection-result nil
          emacsos-net--connection-result-timer nil)
    (emacsos-net--render-if-shown)))

(defun emacsos-net--begin-connection (ssid kind)
  "Create and display one connection owner for SSID and KIND."
  (when (timerp emacsos-net--connection-result-timer)
    (cancel-timer emacsos-net--connection-result-timer))
  (setq emacsos-net--connection-result-timer nil
        emacsos-net--connection-result nil)
  (cl-incf emacsos-net--connection-attempt-id)
  (setq emacsos-net--connection-pending
        (list :id emacsos-net--connection-attempt-id :ssid ssid :kind kind))
  (emacsos-net--render-if-shown)
  emacsos-net--connection-attempt-id)

(defun emacsos-net--finish-connection (attempt-id result)
  "Finish ATTEMPT-ID once with normalized terminal RESULT."
  (when (eq attempt-id (plist-get emacsos-net--connection-pending :id))
    (let ((ssid (plist-get emacsos-net--connection-pending :ssid))
          generation)
      (setq emacsos-net--connection-pending nil
            emacsos-net--connection-result
            (list :id attempt-id :text (emacsos-net--result-text ssid result))
            emacsos-net--connection-result-timer
            (run-with-timer 8 nil #'emacsos-net--expire-result attempt-id))
      (emacsos-net--render-if-shown)
      (emacsos-net--discard-reader)
      (setq generation (1+ emacsos-net--settle-generation)
            emacsos-net--settle-generation generation
            emacsos-net--settle-pending generation)
      (run-with-timer 1.5 nil #'emacsos-net--refresh-after-action generation))))

(defun emacsos-net--release-connection (attempt-id)
  "Release ATTEMPT-ID without publishing a result."
  (when (eq attempt-id (plist-get emacsos-net--connection-pending :id))
    (setq emacsos-net--connection-pending nil)
    (emacsos-net--render-if-shown)))

(defun emacsos-net--valid-secret-p (value)
  "Non-nil when VALUE is a bounded one-line password for the helper."
  (and (stringp value)
       (> (string-bytes value) 0)
       (<= (string-bytes value) 256)
       (not (string-match-p "[\0\r\n]" value))))

(defun emacsos-net--valid-ssid-p (value)
  "Non-nil when VALUE is a bounded one-line visible-network identifier."
  (and (stringp value)
       (> (string-bytes value) 0)
       (<= (string-bytes value) 32)
       (not (seq-some (lambda (char)
                        (or (< char 32)
                            (<= 127 char 159)
                            (memq char '(#x061c #x200e #x200f))
                            (<= #x202a char #x202e)
                            (<= #x2066 char #x2069)))
                      value))))

(defun emacsos-net--start-connection (kind target password completion)
  "Invoke the platform connection hook with normalized failure behavior."
  (if (not emacsos-net-connection-function)
      "not-connected:unavailable"
    (condition-case nil
        (let ((result (funcall emacsos-net-connection-function
                               kind target password completion)))
          (if (or (equal result emacsos-net--connection-pending-result)
                  (emacsos-net--terminal-result-p result))
              result
            "not-connected:failed"))
      (error "not-connected:unavailable"))))

(defun emacsos-net-connect (ssid)
  "Connect to visible wifi network SSID through the finite platform contract."
  (interactive "sWi-Fi network: ")
  (if emacsos-net--connection-pending
      "not-connected:busy"
    (let* ((valid-ssid (emacsos-net--valid-ssid-p ssid))
           (net (and valid-ssid
                     (seq-find (lambda (item)
                                 (string= (plist-get item :ssid) ssid))
                               (emacsos-net-state-wifi-list
                                emacsos-net--state))))
           (kind (and net (emacsos-net--connect-kind net)))
           (operation-kind (pcase kind
                             ('saved 'saved)
                             ('open 'open)
                             ('needs-password 'secured)))
           (target (if (eq kind 'saved)
                       (plist-get net :saved-uuid)
                     ssid))
           (attempt-id (emacsos-net--begin-connection
                        (if (stringp ssid) ssid "") kind))
           (completion (lambda (result)
                         (when (emacsos-net--terminal-result-p result)
                           (emacsos-net--finish-connection attempt-id result))))
           password result completed)
      (unwind-protect
          (progn
            (when (and (emacsos-net-state-saved-known emacsos-net--state)
                       (eq kind 'needs-password))
              (setq password (read-passwd
                              (format "Password for %s: "
                                      (emacsos-net--display-ssid ssid)))))
            (setq result
                  (cond
                   ((not valid-ssid) "not-connected:invalid-input")
                   ((null net) "not-connected:network-not-found")
                   ((not (emacsos-net-state-saved-known emacsos-net--state))
                    "not-connected:unavailable")
                   ((eq kind 'unsupported-security)
                    "not-connected:unsupported-security")
                   ((and (eq kind 'needs-password)
                         (not (emacsos-net--valid-secret-p password)))
                    "not-connected:invalid-input")
                   (t (emacsos-net--start-connection
                       operation-kind target password completion))))
            (unless (equal result emacsos-net--connection-pending-result)
              (emacsos-net--finish-connection attempt-id result))
            (setq completed t)
            result)
        (when (stringp password)
          (clear-string password))
        (unless completed
          (emacsos-net--release-connection attempt-id))))))

;;; The *network* control page

(defun emacsos-net--render-full ()
  "Render the `*network*' control page from `emacsos-net--state'."
  (let ((buf (get-buffer-create emacsos-net--buffer-name))
        (st emacsos-net--state))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Network\n\n")
        ;; Wifi
        (insert (format "Wifi: %s\n"
                        (pcase (emacsos-net-state-wifi-on st)
                          ('t (if (emacsos-net-state-ssid st)
                                  (format "on — %s"
                                          (emacsos-net--display-ssid
                                           (emacsos-net-state-ssid st)))
                                "on"))
                          ('nil "off")
                          (_ "?"))))
        (emacsos--btn (if (eq (emacsos-net-state-wifi-on st) t) " Wifi off " " Wifi on ")
                     #'emacsos-net-toggle-wifi nil emacsos--btn-label-scale)
        (insert "\n\n")
        ;; Cell
        (if (not (emacsos-net-state-valid st))
            (insert "Cell: Checking...")
          (if (emacsos-net-state-cell-provisioned st)
            (progn
              (insert (format "Cell: %s%s\n"
                              (if (emacsos-net-state-cell-on st) "on" "off")
                              (let ((s (emacsos-net-state-cell-state st)))
                                (if (string-empty-p s) "" (format " (%s)" s)))))
              (emacsos--btn (if (emacsos-net-state-cell-on st)
                               " Cell off " " Cell on ")
                           #'emacsos-net-toggle-cell nil emacsos--btn-label-scale))
            (insert "Cell: not set up (run cellular bring-up)")))
        (insert "\n\n")
        ;; Wifi networks
        (insert "Networks:\n")
        (emacsos--btn (if (and emacsos-net--proc
                              (process-live-p emacsos-net--proc))
                         " Refreshing… "
                       " Refresh ")
                     #'emacsos-net--refresh nil emacsos--btn-label-scale)
        (insert "\n")
        (when emacsos-net--connection-pending
          (insert (format "Connecting to %s…\n"
                          (emacsos-net--display-ssid
                           (plist-get emacsos-net--connection-pending :ssid)))))
        (when emacsos-net--connection-result
          (insert (plist-get emacsos-net--connection-result :text) "\n"))
        (unless (emacsos-net-state-saved-known st)
          (insert "  Saved network status unavailable. Refresh.\n"))
        (if (null (emacsos-net-state-wifi-list st))
            (insert "  (none found)\n")
          (dolist (net (emacsos-net-state-wifi-list st))
            (let* ((ssid (plist-get net :ssid))
                   (sig (plist-get net :signal))
                   (kind (emacsos-net--connect-kind net))
                   (mark (cond ((plist-get net :in-use) "* ")
                               ((memq kind '(needs-password unsupported-security)) "[lock] ")
                               (t "")))
                   (label (format " %s%s  %s%% " mark
                                  (emacsos-net--display-ssid ssid)
                                  (or sig "?"))))
              (if (or emacsos-net--connection-pending
                      (not (emacsos-net-state-saved-known st)))
                  (insert label)
                (emacsos--btn label #'emacsos-net-connect ssid emacsos--btn-label-scale))
              (insert "\n")))))
      (setq buffer-read-only t)
      (setq-local cursor-type nil)
      (kill-local-variable 'truncate-lines)
      (kill-local-variable 'mode-line-format)
      (goto-char (point-min)))
    buf))

(defun emacsos-net--phone-line-width ()
  "Return the usable width for one bounded chooser row."
  (let ((window (get-buffer-window emacsos-net--buffer-name)))
    (max 7 (1- (if window (window-body-width window) 40)))))

(defun emacsos-net--phone-button (label action &optional argument width)
  "Insert one phone chooser button for LABEL, ACTION, and ARGUMENT.
WIDTH defaults to the full bounded chooser row."
  (let* ((button-width (or width (emacsos-net--phone-line-width)))
         (clipped (truncate-string-to-width label button-width nil nil "…")))
    (emacsos--btn (emacsos--center clipped button-width)
                  action argument emacsos--btn-label-scale)))

(defun emacsos-net--phone-empty-line (&optional text)
  "Insert a reserved phone chooser row containing optional TEXT."
  (insert (propertize (or text " ")
                      'line-height
                      (+ (frame-char-height) (* 2 emacsos--btn-vpad)))
          "\n"))

(defun emacsos-net--page-count ()
  "Return the bounded chooser's nonzero page count."
  (max 1 (ceiling (/ (float (length
                              (and (emacsos-net-state-valid emacsos-net--state)
                                   (emacsos-net-state-wifi-list
                                    emacsos-net--state))))
                     emacsos-net--page-size))))

(defun emacsos-net--change-page (delta)
  "Move DELTA pages within the bounded chooser."
  (setq emacsos-net--page
        (max 0 (min (+ emacsos-net--page delta)
                    (1- (emacsos-net--page-count)))))
  (emacsos-net--render))

(defun emacsos-net-done ()
  "Leave the bounded network chooser through its configured return command."
  (interactive)
  (let ((return-function emacsos-net-return-function))
    (setq emacsos-net-return-function nil
          emacsos-net--page 0)
    (when (functionp return-function)
      (funcall return-function))))

(defun emacsos-net--render-phone ()
  "Render the fixed seven-line phone network chooser."
  (let* ((buffer (get-buffer-create emacsos-net--buffer-name))
         (state emacsos-net--state)
         (networks (and (emacsos-net-state-valid state)
                        (emacsos-net-state-wifi-list state)))
         (pages (emacsos-net--page-count)))
    (setq emacsos-net--page (min emacsos-net--page (1- pages)))
    (with-current-buffer buffer
      (let* ((inhibit-read-only t)
             (start (* emacsos-net--page emacsos-net--page-size))
             (end (min (length networks) (+ start emacsos-net--page-size)))
             (visible (cl-subseq networks start end)))
        (erase-buffer)
        (insert (truncate-string-to-width
                 (cond
                  ((not (emacsos-net-state-valid state)) "Networks unavailable")
                  (emacsos-net--connection-pending
                   (format "Connecting to %s…"
                           (emacsos-net--display-ssid
                            (plist-get emacsos-net--connection-pending :ssid))))
                  (emacsos-net--connection-result
                   (plist-get emacsos-net--connection-result :text))
                  (t "Networks"))
                 (emacsos-net--phone-line-width) nil nil "…")
                "\n")
        (emacsos-net--phone-button "Done" #'emacsos-net-done)
        (insert "\n")
        (dotimes (index emacsos-net--page-size)
          (let ((network (nth index visible)))
            (if (not network)
                (emacsos-net--phone-empty-line
                 (and (= index 0) (null networks) "(none found)"))
              (let* ((ssid (plist-get network :ssid))
                     (signal (or (plist-get network :signal) "?"))
                     (kind (emacsos-net--connect-kind network))
                     (mark (cond ((plist-get network :in-use) "* ")
                                 ((memq kind '(needs-password unsupported-security)) "[lock] ")
                                 (t "")))
                     (label (format "%s%s  %s%%" mark
                                    (emacsos-net--display-ssid ssid) signal)))
                (if (or emacsos-net--connection-pending
                        (not (emacsos-net-state-saved-known state)))
                    (insert (truncate-string-to-width
                             label (emacsos-net--phone-line-width) nil nil "…"))
                  (emacsos-net--phone-button label #'emacsos-net-connect ssid)))
              (insert "\n"))))
        (if (> pages 1)
            (let* ((previous (> emacsos-net--page 0))
                   (next (< emacsos-net--page (1- pages)))
                   (width (if (and previous next)
                              (/ (1- (emacsos-net--phone-line-width)) 2)
                            (emacsos-net--phone-line-width))))
              (when previous
                (emacsos-net--phone-button "Previous" #'emacsos-net--change-page -1 width))
              (when (and previous next)
                (insert " "))
              (when next
                (emacsos-net--phone-button "Next" #'emacsos-net--change-page 1 width))
              (insert "\n"))
          (emacsos-net--phone-empty-line)))
      (setq buffer-read-only t)
      (setq-local cursor-type nil)
      (setq-local truncate-lines t)
      (setq-local mode-line-format nil)
      (goto-char (point-min)))
    buffer))

(defun emacsos-net--render ()
  "Render the generic network page or configured bounded phone chooser."
  (if emacsos-net-return-function
      (emacsos-net--render-phone)
    (emacsos-net--render-full)))

(defun emacsos-net--shown-p ()
  "Non-nil if `*network*' is the current top (editing) buffer."
  (let* ((w (and (fboundp 'emacsos--target) (emacsos--target)))
         (b (and w (window-buffer w))))
    (and b (eq b (get-buffer emacsos-net--buffer-name)))))

(defun emacsos-net--render-if-shown ()
  "Repaint the page only when it is on top."
  (when (emacsos-net--shown-p) (emacsos-net--render)))

(defun emacsos-net-show (&optional return-function)
  "Show the network page and refresh it.
RETURN-FUNCTION enables the bounded phone chooser and owns its Done action."
  (interactive)
  (setq emacsos-net-return-function return-function
        emacsos-net--page 0)
  (emacsos-net--ensure-timer)
  (let* ((buf (get-buffer-create emacsos-net--buffer-name))
         (w (and (fboundp 'emacsos--target) (emacsos--target))))
    (when (and w (not (eq (window-buffer w) buf)))
      (set-window-buffer w buf)))
  (emacsos-net--render)
  (emacsos-net--refresh))

;;; Timer lifecycle (hot-reload safe)

(defun emacsos-net--ensure-timer ()
  "Arm the background refresh timer once (lazy; survives hot-reload)."
  (unless (timerp emacsos-net--timer)
    (setq emacsos-net--timer
          (run-with-timer emacsos-net-refresh-interval emacsos-net-refresh-interval
                          #'emacsos-net--refresh))))

(provide 'network)
;;; network.el ends here
