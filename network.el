;;; network.el --- EmacsOS network status + control -*- lexical-binding: t -*-

;; Glanceable cell/wifi status in the modeline, tappable to a `*network*'
;; control page (toggle cell/wifi, pick a wifi network).  Companion to
;; os.el (which `require's this and wires the global mode-line-format).
;;
;; Reads run through ModemManager/NetworkManager CLIs (`nmcli'/`mmcli'),
;; ALWAYS asynchronously: one `make-process' gathers every read in a
;; single shell pipeline, a sentinel parses the blob into `emacos-net--state',
;; and the `:eval' modeline segment + the page repaint from that cached
;; state.  Nothing on the redisplay/tap path blocks the main loop (the
;; project's prime directive — see docs/2026-05-17-streaming-responses.org).
;;
;; Connecting to a NEW *secured* wifi network needs a WPA password, which
;; needs digits on the T9 keyboard — the "Numbers + symbols on the keyboard"
;; roadmap item, not yet done.  So saved/open networks connect now; a new
;; secured network degrades to a clear note rather than a half-built prompt.
;; `emacos-net--connect-kind' is the single seam where that lands later.

(require 'cl-lib)
(require 'seq)

;; Defined in os.el (which `require's this file).  Resolved at call time.
(declare-function emacos--btn "os")
(declare-function emacos--target "os")
(declare-function emacos--render-page "os")

(defcustom emacos-net-refresh-interval 30
  "Seconds between background network-status refreshes.
Kept slow on purpose: `mmcli --signal-get' wakes the modem, and the
status is glanceable, not real-time.  The Zero W is single-core ARM11."
  :type 'integer
  :group 'emacsos)

(defconst emacos-net--buffer-name "*network*")

(defconst emacos-net--cell-con "emacsos-cellular"
  "NetworkManager connection name the cellular bring-up creates.
Must match CON_NAME in deploy/cellular-bringup.sh.")

;;; State

(cl-defstruct emacos-net-state
  "Cached snapshot of network status, refreshed asynchronously."
  (wifi-on 'unknown)        ; t / nil / 'unknown (radio)
  (active-iface 'none)      ; 'wifi | 'cell | 'none — what carries the default route
  ssid                      ; current wifi SSID string, or nil
  signal                    ; 0-100 signal of the active iface, or nil
  (wifi-list nil)           ; list of plists (:ssid :signal :security :in-use :saved)
  (cell-provisioned nil)    ; t once the emacsos-cellular connection exists
  (cell-state "")           ; mmcli modem state: "registered" / "searching" / "" ...
  (stamp 0.0))              ; float-time of the snapshot

(defvar emacos-net--state (make-emacos-net-state)
  "The latest `emacos-net-state', updated by the refresh sentinel.")

(defvar emacos-net--proc nil
  "Live status-reader process, or nil.  Single-flight guard: a refresh
no-ops while this is live, so concurrent reads can't stack on the Zero W.")

(defvar emacos-net--timer nil
  "Repeat timer driving background refresh.  Guarded so a hot-reload of
this file (the agent-customization workflow) doesn't stack timers.")

;;; Terse-output parsing (pure)

(defun emacos-net--split-terse (line)
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

(defun emacos-net--section (blob name)
  "Return the lines of section NAME from BLOB, a string the reader builds
with \"@@<NAME>\" marker lines between each command's output."
  (let ((lines (split-string blob "\n"))
        (want (concat "@@" name)) (in nil) (out nil))
    (dolist (l lines)
      (cond
       ((string-prefix-p "@@" l) (setq in (string= l want)))
       ((and in (not (string-empty-p l))) (push l out))))
    (nreverse out)))

(defun emacos-net--parse (blob)
  "Parse the reader's delimited BLOB into a fresh `emacos-net-state'.
Robust to missing/empty sections (no modem, no service, wifi off)."
  (let* ((radio (car (emacos-net--section blob "RADIO")))
         (rfields (and radio (emacos-net--split-terse radio)))
         (wifi-on (cond ((null rfields) 'unknown)
                        ((string= (car rfields) "enabled") t)
                        (t nil)))
         ;; default route device: wl* -> wifi, ww* -> cell
         (route (car (emacos-net--section blob "ROUTE")))
         (active-iface (cond ((null route) 'none)
                             ((string-match-p "\\bdev wl" route) 'wifi)
                             ((string-match-p "\\bdev ww" route) 'cell)
                             (t 'none)))
         ;; saved profiles + cell-provisioned, from `con show'
         (saved nil) (cell-provisioned nil))
    (dolist (l (emacos-net--section blob "CONS"))
      (let* ((f (emacos-net--split-terse l)) (name (nth 0 f)) (type (nth 1 f)))
        (when (string= name emacos-net--cell-con) (setq cell-provisioned t))
        (when (string= type "802-11-wireless") (push name saved))))
    ;; wifi networks from `dev wifi'
    (let (wifi-list cur-ssid cur-signal)
      (dolist (l (emacos-net--section blob "WIFI"))
        (let* ((f (emacos-net--split-terse l))
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
        (dolist (l (emacos-net--section blob "CELL"))
          (let ((f (emacos-net--split-terse-kv l)))
            (when f
              (cond
               ((string-match-p "\\.state$" (car f)) (setq cell-state (cdr f)))
               ((string-match-p "signal-quality\\.value$" (car f))
                (setq cell-signal (string-to-number (cdr f))))))))
        (make-emacos-net-state
         :wifi-on wifi-on
         :active-iface active-iface
         :ssid cur-ssid
         :signal (cond ((eq active-iface 'wifi) cur-signal)
                       ((eq active-iface 'cell) cell-signal)
                       (t nil))
         :wifi-list (nreverse wifi-list)
         :cell-provisioned cell-provisioned
         :cell-state (or cell-state "")
         :stamp (float-time))))))

(defun emacos-net--split-terse-kv (line)
  "Split an mmcli `--output-keyvalue' LINE \"key : value\" into (KEY . VALUE).
Returns nil for a line without the \" : \" separator."
  (when (string-match "\\`\\(.*?\\) *: *\\(.*\\)\\'" line)
    (cons (match-string 1 line) (match-string 2 line))))

;;; Modeline segment (pure: state -> propertized string)

(defun emacos-net--segment-text (st)
  "Return the bare status text for state ST (no text properties)."
  (pcase (emacos-net-state-active-iface st)
    ('wifi (format "wifi %s%%" (or (emacos-net-state-signal st) "?")))
    ('cell (format "lte %s%%"  (or (emacos-net-state-signal st) "?")))
    (_     "no net")))

(defun emacos-net-mode-line-string ()
  "Modeline segment: a tappable cell/wifi status string.
Wrapped so a redisplay-time error can never brick the modeline."
  (condition-case nil
      (propertize (emacos-net--segment-text emacos-net--state)
                  'local-map (let ((m (make-sparse-keymap)))
                               (define-key m [mode-line mouse-1] #'emacos-net-show)
                               m)
                  'mouse-face 'mode-line-highlight
                  'help-echo "Network — tap for controls")
    (error "net?")))

;;; Connect-kind seam

(defun emacos-net--connect-kind (net)
  "Classify wifi NET (a `wifi-list' plist) for connecting:
`saved' (NM has a profile — no password), `open' (no security — no
password), or `needs-password' (new secured network — blocked until the
Numbers keyboard item lands; see the file header)."
  (cond ((plist-get net :saved) 'saved)
        ((let ((s (plist-get net :security))) (or (null s) (string-empty-p s))) 'open)
        (t 'needs-password)))

;;; Async refresh

(defun emacos-net--reader-script ()
  "Shell script gathering every read into one delimited blob.
One process, one sentinel — simpler and lighter than chaining readers.
mmcli is queried only if a modem is present, to avoid waking it needlessly."
  (concat
   "echo @@RADIO; nmcli -t -f WIFI radio 2>/dev/null; "
   "echo @@ROUTE; ip -o -4 route show default 2>/dev/null; "
   "echo @@CONS;  nmcli -t -f NAME,TYPE con show 2>/dev/null; "
   "echo @@WIFI;  nmcli -t -f ACTIVE,SSID,SIGNAL,SECURITY dev wifi 2>/dev/null; "
   "echo @@CELL;  mmcli -m any --output-keyvalue 2>/dev/null; "
   "echo @@END"))

(defun emacos-net--refresh ()
  "Kick off a background status read (no-op if one is already running)."
  (when (or (null emacos-net--proc) (not (process-live-p emacos-net--proc)))
    (let ((buf (generate-new-buffer " *emacos-net-read*")))
      (condition-case err
          (setq emacos-net--proc
                (make-process
                 :name "emacos-net-read"
                 :buffer buf
                 :command (list "sh" "-c" (emacos-net--reader-script))
                 :noquery t
                 :sentinel #'emacos-net--reader-sentinel))
        (error
         (kill-buffer buf)
         (message "emacos-net: cannot read network status: %s"
                  (error-message-string err)))))))

(defun emacos-net--reader-sentinel (proc _event)
  "On reader exit (ANY terminal state), parse and refresh the UI.
Clears the single-flight guard unconditionally so a dead reader can't
wedge all future refreshes."
  (when (memq (process-status proc) '(exit signal))
    (let ((buf (process-buffer proc)))
      (unwind-protect
          (when (buffer-live-p buf)
            (let ((blob (with-current-buffer buf (buffer-string))))
              (setq emacos-net--state (emacos-net--parse blob))
              (force-mode-line-update t)
              (emacos-net--render-if-shown)))
        (setq emacos-net--proc nil)
        (when (buffer-live-p buf) (kill-buffer buf))))))

;;; Control actions

(defun emacos-net--action (args)
  "Run an `nmcli' command (ARGS, a list of strings) async, then refresh.
The post-action refresh is delayed ~1.5s so nmcli has time to settle."
  (make-process
   :name "emacos-net-act"
   :buffer (generate-new-buffer " *emacos-net-act*")
   :command (cons "nmcli" args)
   :noquery t
   :sentinel (lambda (p _e)
               (when (memq (process-status p) '(exit signal))
                 (when (buffer-live-p (process-buffer p))
                   (kill-buffer (process-buffer p)))
                 (run-with-timer 1.5 nil #'emacos-net--refresh)))))

(defun emacos-net-toggle-wifi ()
  "Toggle the wifi radio."
  (emacos-net--action
   (list "radio" "wifi"
         (if (eq (emacos-net-state-wifi-on emacos-net--state) t) "off" "on"))))

(defun emacos-net-toggle-cell ()
  "Bring the cellular connection up or down.
Only meaningful once `make cellular-bringup' has created the connection."
  (if (emacos-net-state-cell-provisioned emacos-net--state)
      (emacos-net--action
       (list "con" (if (eq (emacos-net-state-active-iface emacos-net--state) 'cell)
                       "down" "up")
             emacos-net--cell-con))
    (message "Cellular not set up yet — run `make cellular-bringup APN=...'")))

(defun emacos-net-connect (ssid)
  "Connect to wifi network SSID, honouring the connect-kind seam."
  (let ((net (seq-find (lambda (n) (string= (plist-get n :ssid) ssid))
                       (emacos-net-state-wifi-list emacos-net--state))))
    (pcase (and net (emacos-net--connect-kind net))
      ('saved (emacos-net--action (list "con" "up" ssid)))
      ('open  (emacos-net--action (list "dev" "wifi" "connect" ssid)))
      ('needs-password
       ;; Deferred: a WPA password needs the number keyboard (not yet built).
       (message "%s needs a password — number keys coming soon" ssid))
      (_ (message "Unknown network: %s" ssid)))))

;;; The *network* control page

(defun emacos-net--render ()
  "Render the `*network*' control page from `emacos-net--state'."
  (let ((buf (get-buffer-create emacos-net--buffer-name))
        (st emacos-net--state))
    (with-current-buffer buf
      (let ((inhibit-read-only t))
        (erase-buffer)
        (insert "Network\n\n")
        ;; Wifi
        (insert (format "Wifi: %s\n"
                        (pcase (emacos-net-state-wifi-on st)
                          ('t (if (emacos-net-state-ssid st)
                                  (format "on — %s" (emacos-net-state-ssid st))
                                "on"))
                          ('nil "off")
                          (_ "?"))))
        (emacos--btn (if (eq (emacos-net-state-wifi-on st) t) " Wifi off " " Wifi on ")
                     #'emacos-net-toggle-wifi nil 1.75)
        (insert "\n\n")
        ;; Cell
        (if (emacos-net-state-cell-provisioned st)
            (progn
              (insert (format "Cell: %s%s\n"
                              (if (eq (emacos-net-state-active-iface st) 'cell) "on" "off")
                              (let ((s (emacos-net-state-cell-state st)))
                                (if (string-empty-p s) "" (format " (%s)" s)))))
              (emacos--btn (if (eq (emacos-net-state-active-iface st) 'cell)
                               " Cell off " " Cell on ")
                           #'emacos-net-toggle-cell nil 1.75))
          (insert "Cell: not set up (run cellular bring-up)"))
        (insert "\n\n")
        ;; Wifi networks
        (insert "Networks:\n")
        (if (null (emacos-net-state-wifi-list st))
            (insert "  (none found — Refresh)\n")
          (dolist (net (emacos-net-state-wifi-list st))
            (let* ((ssid (plist-get net :ssid))
                   (sig (plist-get net :signal))
                   (kind (emacos-net--connect-kind net))
                   (mark (cond ((plist-get net :in-use) "* ")
                               ((eq kind 'needs-password) "[lock] ")
                               (t "")))
                   (label (format " %s%s  %s%% " mark ssid (or sig "?"))))
              (emacos--btn label #'emacos-net-connect ssid 1.75)
              (insert "\n"))))
        (when (seq-some (lambda (n) (eq (emacos-net--connect-kind n) 'needs-password))
                        (emacos-net-state-wifi-list st))
          (insert "\nSecured networks need the number keyboard — coming soon.\n")))
      (setq buffer-read-only t)
      (setq-local cursor-type nil)
      (goto-char (point-min)))
    buf))

(defun emacos-net--shown-p ()
  "Non-nil if `*network*' is the current top (editing) buffer."
  (let* ((w (and (fboundp 'emacos--target) (emacos--target)))
         (b (and w (window-buffer w))))
    (and b (eq b (get-buffer emacos-net--buffer-name)))))

(defun emacos-net--render-if-shown ()
  "Repaint the page only when it is on top (called from the refresh sentinel)."
  (when (emacos-net--shown-p) (emacos-net--render)))

(defun emacos-net--command-set ()
  "Dynamic command set for the `*network*' page (feeds the keyboard band).
Labels flip with state, so this is derived fresh each render."
  (list (cons (if (eq (emacos-net-state-wifi-on emacos-net--state) t) "Wifi off" "Wifi on")
              #'emacos-net-toggle-wifi)
        (cons (if (eq (emacos-net-state-active-iface emacos-net--state) 'cell)
                  "Cell off" "Cell on")
              #'emacos-net-toggle-cell)
        (cons "Refresh" #'emacos-net--refresh)))

(defun emacos-net-show ()
  "Show the `*network*' control page in the top window and refresh it."
  (interactive)
  (emacos-net--ensure-timer)
  (emacos-net--render)
  (let* ((buf (get-buffer emacos-net--buffer-name))
         (w (and (fboundp 'emacos--target) (emacos--target))))
    (when (and w (not (eq (window-buffer w) buf)))
      (set-window-buffer w buf)))
  (emacos-net--refresh))

;;; Timer lifecycle (hot-reload safe)

(defun emacos-net--ensure-timer ()
  "Arm the background refresh timer once (lazy; survives hot-reload)."
  (unless (timerp emacos-net--timer)
    (setq emacos-net--timer
          (run-with-timer emacos-net-refresh-interval emacos-net-refresh-interval
                          #'emacos-net--refresh))))

(provide 'network)
;;; network.el ends here
