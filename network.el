;;; network.el --- EmacsOS network status + control -*- lexical-binding: t -*-

;; Glanceable cell/wifi status in the modeline, tappable to a `*network*'
;; control page (toggle cell/wifi, pick a wifi network).  Companion to
;; os.el (which `require's this and wires the global mode-line-format).
;;
;; Reads run through ModemManager/NetworkManager CLIs (`nmcli'/`mmcli'),
;; ALWAYS asynchronously: one `make-process' gathers every read in a
;; single shell pipeline, a sentinel parses the blob into `emacsos-net--state',
;; and the `:eval' modeline segment + the page repaint from that cached
;; state.  Nothing on the redisplay/tap path blocks the main loop (the
;; project's prime directive — see docs/2026-05-17-streaming-responses.org).
;;
;; Connecting to a NEW *secured* wifi network needs a protected credential
;; entry flow, which is not implemented yet.  Saved/open networks connect now;
;; a new secured network degrades to a clear note rather than a leaky prompt.
;; `emacsos-net--connect-kind' is the single seam where that lands later.

(require 'cl-lib)
(require 'seq)

;; Defined in os.el (which `require's this file).  Resolved at call time.
(declare-function emacsos--btn "os")
(declare-function emacsos--target "os")
(defvar emacsos--btn-label-scale)  ; label font :height; owned by os.el (vpad gives the button its tap-target height separately)

(defcustom emacsos-net-refresh-interval 30
  "Seconds between background network-status refreshes.
Kept slow because modem status polling costs power and the result is
glanceable, not real-time."
  :type 'integer
  :group 'emacsos)

(defconst emacsos-net--buffer-name "*network*")

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

;;; State

(cl-defstruct emacsos-net-state
  "Cached snapshot of network status, refreshed asynchronously."
  (wifi-on 'unknown)        ; t / nil / 'unknown (radio)
  (active-iface 'none)      ; 'wifi | 'cell | 'none — what carries the default route
  ssid                      ; current wifi SSID string, or nil
  signal                    ; 0-100 signal of the active iface, or nil
  (wifi-list nil)           ; list of plists (:ssid :signal :security :in-use :saved)
  (cell-provisioned nil)    ; t once the named GSM connection exists
  (cell-on nil)             ; t while that NetworkManager profile is active
  (cell-state "")           ; mmcli modem state: "registered" / "searching" / "" ...
  (stamp 0.0))              ; float-time of the snapshot

(defvar emacsos-net--state (make-emacsos-net-state)
  "The latest `emacsos-net-state', updated by the refresh sentinel.")

(defvar emacsos-net--proc nil
  "Live status-reader process, or nil.  Single-flight guard: a refresh
no-ops while this is live, so concurrent reads cannot stack on the phone.")

(defun emacsos-net--ensure-state-shape ()
  "Reset cached network state when hot reload changes its struct layout."
  (unless (condition-case nil
              (progn (emacsos-net-state-stamp emacsos-net--state) t)
            (error nil))
    (setq emacsos-net--state (make-emacsos-net-state))))

(defun emacsos-net--discard-reader ()
  "Discard an in-flight status read and its output buffer."
  (when emacsos-net--proc
    (let ((proc emacsos-net--proc))
      (setq emacsos-net--proc nil)
      (set-process-sentinel proc #'ignore)
      (when (process-live-p proc)
        (delete-process proc))
      (when (buffer-live-p (process-buffer proc))
        (kill-buffer (process-buffer proc))))))

;; `defvar' preserves old state and processes when this file is hot-reloaded.
(emacsos-net--ensure-state-shape)
(emacsos-net--discard-reader)

(defvar emacsos-net--timer nil
  "Repeat timer driving background refresh.  Guarded so a hot-reload of
this file (the agent-customization workflow) doesn't stack timers.")

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

(defun emacsos-net--parse (blob)
  "Parse the reader's delimited BLOB into a fresh `emacsos-net-state'.
Robust to missing/empty sections (no modem, no service, wifi off)."
  (let* ((radio (car (emacsos-net--section blob "RADIO")))
         (rfields (and radio (emacsos-net--split-terse radio)))
         (wifi-on (cond ((null rfields) 'unknown)
                        ((string= (car rfields) "enabled") t)
                        (t nil)))
         ;; default route device: wl* -> wifi, ww* -> cell
         (route (car (emacsos-net--section blob "ROUTE")))
         (active-iface (cond ((null route) 'none)
                             ((string-match-p "\\bdev wl" route) 'wifi)
                             ((string-match-p "\\bdev ww" route) 'cell)
                             (t 'none)))
         ;; saved profiles + cellular profile activity, from `con show'
         (saved nil) (cell-provisioned nil) (cell-on nil))
    (dolist (l (emacsos-net--section blob "CONS"))
      (let* ((f (emacsos-net--split-terse l))
             (name (nth 0 f))
             (type (nth 1 f))
             (device (nth 2 f)))
        (when (and (string= name emacsos-net-cell-connection)
                   (string= type "gsm"))
          (setq cell-provisioned t
                cell-on (and device
                             (not (string-empty-p device))
                             (not (string= device "--")))))
        (when (string= type "802-11-wireless") (push name saved))))
    ;; wifi networks from `dev wifi'
    (let (wifi-list cur-ssid cur-signal)
      (dolist (l (emacsos-net--section blob "WIFI"))
        (let* ((f (emacsos-net--split-terse l))
               (in-use (string= (nth 0 f) "yes"))
               (ssid (nth 1 f))
               (sig (and (nth 2 f) (string-to-number (nth 2 f))))
               (sec (or (nth 3 f) "")))
          (when (and ssid (not (string-empty-p ssid)))
            (when in-use (setq cur-ssid ssid cur-signal sig))
            (push (list :ssid ssid :signal sig :security sec
                        :in-use in-use
                        :saved (and (member ssid saved) t))
                  wifi-list))))
      ;; cell registration/signal from mmcli key=value
      (let (cell-state cell-signal)
        (dolist (l (emacsos-net--section blob "CELL"))
          (let ((f (emacsos-net--split-terse-kv l)))
            (when f
              (cond
               ((string-match-p "\\.state$" (car f)) (setq cell-state (cdr f)))
               ((string-match-p "signal-quality\\.value$" (car f))
                (unless (string-empty-p (cdr f))
                  (setq cell-signal (string-to-number (cdr f)))))))))
        (make-emacsos-net-state
         :wifi-on wifi-on
         :active-iface active-iface
         :ssid cur-ssid
         :signal (cond ((eq active-iface 'wifi) cur-signal)
                       ((eq active-iface 'cell) cell-signal)
                       (t nil))
         :wifi-list (nreverse wifi-list)
         :cell-provisioned cell-provisioned
         :cell-on cell-on
         :cell-state (or cell-state "")
         :stamp (float-time))))))

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
`saved' (NM has a profile — no password), `open' (no security — no
password), or `needs-password' (new secured network — blocked until the
network page gains password entry; see the file header)."
  (cond ((plist-get net :saved) 'saved)
        ((let ((s (plist-get net :security))) (or (null s) (string-empty-p s))) 'open)
        (t 'needs-password)))

;;; Async refresh

(defun emacsos-net--reader-script ()
  "Shell script gathering every read into one delimited blob.
One process, one sentinel — simpler and lighter than chaining readers.
The asynchronous mmcli attempt suppresses errors when no modem is present."
  (concat
   "echo @@RADIO; nmcli -t -f WIFI radio 2>/dev/null; "
   "echo @@ROUTE; ip -4 route show default 2>/dev/null; "
   "echo @@CONS;  nmcli -t -f NAME,TYPE,DEVICE con show 2>/dev/null; "
   "echo @@WIFI;  nmcli -t -f ACTIVE,SSID,SIGNAL,SECURITY dev wifi 2>/dev/null; "
   "echo @@CELL;  mmcli -m any --output-keyvalue 2>/dev/null; "
   "echo @@END"))

(defun emacsos-net--refresh ()
  "Kick off a background status read (no-op if one is already running)."
  (interactive)
  (when (or (null emacsos-net--proc) (not (process-live-p emacsos-net--proc)))
    (let ((buf (generate-new-buffer " *emacsos-net-read*")))
      (condition-case err
          (setq emacsos-net--proc
                (make-process
                 :name "emacsos-net-read"
                 :buffer buf
                 :command (list "sh" "-c" (emacsos-net--reader-script))
                 :noquery t
                 :sentinel #'emacsos-net--reader-sentinel))
        (error
         (kill-buffer buf)
         (message "emacsos-net: cannot read network status: %s"
                  (error-message-string err)))))))

(defun emacsos-net--reader-sentinel (proc _event)
  "On reader exit (ANY terminal state), parse and refresh the UI.
Clears the single-flight guard unconditionally so a dead reader can't
wedge all future refreshes."
  (when (memq (process-status proc) '(exit signal))
    (let ((buf (process-buffer proc)))
      (unwind-protect
          (when (and (eq proc emacsos-net--proc)
                     (buffer-live-p buf))
            (let ((blob (with-current-buffer buf (buffer-string))))
              (setq emacsos-net--state (emacsos-net--parse blob))
              (force-mode-line-update t)
              (emacsos-net--render-if-shown)))
        (when (eq proc emacsos-net--proc)
          (setq emacsos-net--proc nil))
        (when (buffer-live-p buf) (kill-buffer buf))))))

;;; Control actions

(defun emacsos-net--action (args)
  "Run an `nmcli' command (ARGS, a list of strings) async, then refresh.
The post-action refresh is delayed ~1.5s so nmcli has time to settle."
  (let (buffer)
    (condition-case err
        (let ((command (if emacsos-net-command-function
                           (funcall emacsos-net-command-function args)
                         (cons "nmcli" args))))
          (setq buffer (generate-new-buffer " *emacsos-net-act*"))
        (make-process
         :name "emacsos-net-act"
         :buffer buffer
         :command command
         :noquery t
         :sentinel (lambda (p _e)
                     (when (memq (process-status p) '(exit signal))
                       (when (buffer-live-p (process-buffer p))
                         (kill-buffer (process-buffer p)))
                       (run-with-timer 1.5 nil #'emacsos-net--refresh-after-action)))))
      (error
       (when (buffer-live-p buffer) (kill-buffer buffer))
       (message "emacsos-net: cannot change network: %s"
                (error-message-string err))))))

(defun emacsos-net--refresh-after-action ()
  "Replace any pre-action status read with a fresh one."
  (emacsos-net--discard-reader)
  (emacsos-net--refresh))

(defun emacsos-net-toggle-wifi ()
  "Toggle the wifi radio."
  (interactive)
  (emacsos-net--action
   (list "radio" "wifi"
         (if (eq (emacsos-net-state-wifi-on emacsos-net--state) t) "off" "on"))))

(defun emacsos-net-toggle-cell ()
  "Bring the cellular connection up or down.
Only meaningful once `make cellular-bringup' has created the connection."
  (interactive)
  (if (emacsos-net-state-cell-provisioned emacsos-net--state)
      (emacsos-net--action
       (list "con" (if (emacsos-net-state-cell-on emacsos-net--state)
                       "down" "up")
             emacsos-net-cell-connection))
    (message "Cellular not set up yet — run `make cellular-bringup APN=...'")))

(defun emacsos-net-connect (ssid)
  "Connect to wifi network SSID, honouring the connect-kind seam."
  (let ((net (seq-find (lambda (n) (string= (plist-get n :ssid) ssid))
                       (emacsos-net-state-wifi-list emacsos-net--state))))
    (pcase (and net (emacsos-net--connect-kind net))
      ('saved (emacsos-net--action (list "con" "up" ssid)))
      ('open  (emacsos-net--action (list "dev" "wifi" "connect" ssid)))
      ('needs-password
       ;; Deferred: this page has no credential-entry flow yet.
       (message "%s needs a password — number keys coming soon" ssid))
      (_ (message "Unknown network: %s" ssid)))))

;;; The *network* control page

(defun emacsos-net--render ()
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
                                  (format "on — %s" (emacsos-net-state-ssid st))
                                "on"))
                          ('nil "off")
                          (_ "?"))))
        (emacsos--btn (if (eq (emacsos-net-state-wifi-on st) t) " Wifi off " " Wifi on ")
                     #'emacsos-net-toggle-wifi nil emacsos--btn-label-scale)
        (insert "\n\n")
        ;; Cell
        (if (emacsos-net-state-cell-provisioned st)
            (progn
              (insert (format "Cell: %s%s\n"
                              (if (emacsos-net-state-cell-on st) "on" "off")
                              (let ((s (emacsos-net-state-cell-state st)))
                                (if (string-empty-p s) "" (format " (%s)" s)))))
              (emacsos--btn (if (emacsos-net-state-cell-on st)
                               " Cell off " " Cell on ")
                           #'emacsos-net-toggle-cell nil emacsos--btn-label-scale))
          (insert "Cell: not set up (run cellular bring-up)"))
        (insert "\n\n")
        ;; Wifi networks
        (insert "Networks:\n")
        (if (null (emacsos-net-state-wifi-list st))
            (insert "  (none found — Refresh)\n")
          (dolist (net (emacsos-net-state-wifi-list st))
            (let* ((ssid (plist-get net :ssid))
                   (sig (plist-get net :signal))
                   (kind (emacsos-net--connect-kind net))
                   (mark (cond ((plist-get net :in-use) "* ")
                               ((eq kind 'needs-password) "[lock] ")
                               (t "")))
                   (label (format " %s%s  %s%% " mark ssid (or sig "?"))))
              (emacsos--btn label #'emacsos-net-connect ssid emacsos--btn-label-scale)
              (insert "\n"))))
        (when (seq-some (lambda (n) (eq (emacsos-net--connect-kind n) 'needs-password))
                        (emacsos-net-state-wifi-list st))
          (insert "\nNew secured networks need credential entry — coming soon.\n")))
      (setq buffer-read-only t)
      (setq-local cursor-type nil)
      (goto-char (point-min)))
    buf))

(defun emacsos-net--shown-p ()
  "Non-nil if `*network*' is the current top (editing) buffer."
  (let* ((w (and (fboundp 'emacsos--target) (emacsos--target)))
         (b (and w (window-buffer w))))
    (and b (eq b (get-buffer emacsos-net--buffer-name)))))

(defun emacsos-net--render-if-shown ()
  "Repaint the page only when it is on top (called from the refresh sentinel)."
  (when (emacsos-net--shown-p) (emacsos-net--render)))

(defun emacsos-net-show ()
  "Show the `*network*' control page in the top window and refresh it."
  (interactive)
  (emacsos-net--ensure-timer)
  (emacsos-net--render)
  (let* ((buf (get-buffer emacsos-net--buffer-name))
         (w (and (fboundp 'emacsos--target) (emacsos--target))))
    (when (and w (not (eq (window-buffer w) buf)))
      (set-window-buffer w buf)))
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
