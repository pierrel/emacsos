;;; test-network.el --- Tests for network.el status/control -*- lexical-binding: t -*-

;; Covers the testable pieces of the network surface: the terse-line splitter
;; (escaped colons/backslashes), the mmcli key=value splitter, the blob
;; parser (-> `emacsos-net-state'), the modeline formatter + tap props, the
;; connection state machine, cellular-profile activity and toggle direction,
;; dynamic command set, page render, single-flight refresh guard, and local
;; reader-process teardown.  Real nmcli/mmcli network operations, the radio
;; toggles, and the modeline tap are validated on the live phone, not here.
;;
;; Fixtures use placeholder SSIDs and IP-free route lines (the parser only
;; reads `dev wl*' / `dev ww*'), per the no-operator-values rule.

(require 'ert)
(require 'cl-lib)
(require 'os)  ; pulls in network.el + emacsos--btn for the render test

;;; Sample reader blobs

(defconst test-net--blob-wifi
  (concat "@@RADIO\nenabled\n"
          "@@ROUTE\ndefault dev wlan0 scope global metric 600\n"
          "@@CONS\ngsm:cdc-wdm0\n"
          "@@SAVED\n11111111-2222-3333-4444-555555555555:486f6d654e6574\n"
          "@@SAVED-OK\nyes\n"
          "@@WIFI\nyes:486f6d654e6574:82:WPA2\n"
          "no:436f6666656553686f70:54:WPA2\n"
          "no:4f70656e4e6574:40:--\n"
          "@@CELL\nmodem.generic.state : registered\n"
          "modem.generic.signal-quality.value : 60\n@@END\n")
  "Wifi owns the default route; the cellular profile is also active.")

(defconst test-net--blob-cell
  (concat "@@RADIO\ndisabled\n"
          "@@ROUTE\ndefault dev wwan0 scope global metric 700\n"
          "@@CONS\ngsm:wwan0\n"
          "@@SAVED\n@@SAVED-OK\nyes\n"
          "@@WIFI\n"
          "@@CELL\nmodem.generic.state : connected\n"
          "modem.generic.signal-quality.value : 45\n@@END\n")
  "Cell is the active interface; wifi radio off.")

(defconst test-net--blob-none
  (concat "@@RADIO\nenabled\n"
          "@@ROUTE\n"
          "@@CONS\n:\n"
          "@@SAVED\n@@SAVED-OK\nyes\n"
          "@@WIFI\nno:536f6d6557696669:30:WPA2\n"
          "@@CELL\n@@END\n")
  "No default route; cell not provisioned.")

;;; Terse splitting

(ert-deftest test-net-split-plain ()
  (should (equal (emacsos-net--split-terse "yes:HomeNet:82:WPA2")
                 '("yes" "HomeNet" "82" "WPA2"))))

(ert-deftest test-net-split-escaped-colon ()
  ;; literal: no:My\:SSID:40  — the \: is one colon inside the SSID
  (should (equal (emacsos-net--split-terse "no:My\\:SSID:40")
                 '("no" "My:SSID" "40"))))

(ert-deftest test-net-split-escaped-backslash ()
  ;; literal: a\\b:c  — \\ is one backslash inside the value
  (should (equal (emacsos-net--split-terse "a\\\\b:c")
                 '("a\\b" "c"))))

(ert-deftest test-net-kv-splits ()
  (should (equal (emacsos-net--split-terse-kv
                  "modem.generic.state               : registered")
                 '("modem.generic.state" . "registered"))))

(ert-deftest test-net-kv-no-separator-is-nil ()
  (should (null (emacsos-net--split-terse-kv "no separator here"))))

;;; Blob parsing

(ert-deftest test-net-parse-wifi-active ()
  (let ((st (emacsos-net--parse test-net--blob-wifi)))
    (should (emacsos-net-state-valid st))
    (should (eq (emacsos-net-state-active-iface st) 'wifi))
    (should (eq (emacsos-net-state-wifi-on st) t))
    (should (equal (emacsos-net-state-ssid st) "HomeNet"))
    (should (= (emacsos-net-state-signal st) 82))
    (should (emacsos-net-state-cell-provisioned st))
    (should (emacsos-net-state-cell-on st))
    (should (= (length (emacsos-net-state-wifi-list st)) 3))))

(ert-deftest test-net-cell-profile-state-parses-without-its-untrusted-name ()
  (let ((st (emacsos-net--parse
             (concat "@@RADIO\nenabled\n@@ROUTE\n@@CONS\n"
                     "gsm:wwan0\n@@SAVED\n"
                     "@@SAVED-OK\nyes\n@@WIFI\n@@CELL\n@@END\n"))))
    (should (emacsos-net-state-cell-provisioned st))
    (should (emacsos-net-state-cell-on st))))

(ert-deftest test-net-cell-profile-can-be-provisioned-but-inactive ()
  (let ((st (emacsos-net--parse
             (concat "@@RADIO\nenabled\n@@ROUTE\n@@CONS\n"
                     "gsm:--\n@@SAVED\n"
                     "@@SAVED-OK\nyes\n@@WIFI\n@@CELL\n@@END\n"))))
    (should (emacsos-net-state-cell-provisioned st))
    (should-not (emacsos-net-state-cell-on st))))

(ert-deftest test-net-non-gsm-profile-does-not-count-as-cell ()
  (let ((st (emacsos-net--parse
             (concat "@@RADIO\nenabled\n@@ROUTE\n@@CONS\n"
                     "802-11-wireless:wlan0\n@@SAVED\n"
                     "@@SAVED-OK\nyes\n"
                     "@@WIFI\nyes:656d61636f732d63656c6c756c6172:70:\n"
                     "@@CELL\n@@END\n"))))
    (should-not (emacsos-net-state-cell-provisioned st))
    (should-not (emacsos-net-state-cell-on st))))

(ert-deftest test-net-reader-route-command-is-busybox-compatible ()
  (let ((script (emacsos-net--reader-script)))
    (should (string-match-p
             "read_command() { \\\"\\$@\\\" & child=\\$!;" script))
    (should (string-match-p
             "kill -KILL \\\"\\$child\\\".*wait \\\"\\$child\\\"" script))
    (should (string-match-p "read_command ip -4 route show default" script))
    (should (string-match-p
             "read_command nmcli -e no -t -g connection.type con show id \\\"\\$1\\\""
             script))
    (should (string-match-p
             "read_command nmcli -e no -t -g 802-11-wireless.ssid con show uuid"
             script))
    (should (string-match-p
             (regexp-quote "pending_file=$3")
             script))
    (should (string-match-p
             (regexp-quote
              "cmp -s \"$pending_before_file\" \"$pending_after_file\"")
             script))
    (should (string-match-p
             (regexp-quote
              "[ -n \"$pending_uuid\" ] && [ \"$pending_uuid\" = \"$uuid\" ]")
             script))
    (should (string-match-p
             "read -r uuid type || \\[ -n \\\"\\$uuid\\$type\\\" \\]" script))
    (should (string-match-p
             "read_command nmcli -t -f ACTIVE,SSID-HEX,SIGNAL,SECURITY" script))
    (should (string-match-p
             "read_command mmcli -m any --output-keyvalue" script))
    (should (string-match-p "reader_dir=\\$2" script))
    (should (string-match-p ": >\\\"\\$reader_file\\\"" script))
    (should-not (string-match-p "reader_file=\\$(mktemp)" script))
    (should (string-match-p "@@SAVED-FAILED" script))
    (should-not (string-match-p "ip -o -4" script))))

(ert-deftest test-net-reader-rejects-profile-snapshot-across-marker-generation ()
  (let* ((directory (make-temp-file "test-net-marker-race-" t))
         (reader-directory (make-temp-file "test-net-marker-reader-" t))
         (marker (expand-file-name "pending" directory))
         (nmcli (expand-file-name "nmcli" directory))
         (ip (expand-file-name "ip" directory))
         (mmcli (expand-file-name "mmcli" directory))
         (uuid "11111111-2222-3333-4444-555555555555")
         (process-environment
          (cons (concat "TEST_NET_PENDING=" marker)
                (cons (concat "PATH=" directory ":" (getenv "PATH"))
                      process-environment))))
    (unwind-protect
        (progn
          (with-temp-file marker
            (insert "1:name:emacsos-wifi-attempt-00000000000000000000000000000000\n"))
          (with-temp-file nmcli
            (insert
             "#!/bin/sh\n"
             "case $* in\n"
             "  '-t -f WIFI radio') echo enabled ;;\n"
             "  '-e no -t -g connection.type con show id emacsos-cellular') echo gsm ;;\n"
             "  '-e no -t -g GENERAL.DEVICES con show id emacsos-cellular') echo -- ;;\n"
             "  '-t -f UUID,TYPE con show') printf '2:idle\\n' >\"$TEST_NET_PENDING\"; echo '"
             uuid ":802-11-wireless' ;;\n"
             "  '-e no -t -g UUID con show id emacsos-wifi-attempt-00000000000000000000000000000000') echo " uuid " ;;\n"
             "  '-e no -t -g 802-11-wireless.ssid con show uuid " uuid "') echo Cafe ;;\n"
             "  '-t -f ACTIVE,SSID-HEX,SIGNAL,SECURITY dev wifi') : ;;\n"
             "  *) exit 1 ;;\n"
             "esac\n"))
          (with-temp-file ip (insert "#!/bin/sh\nexit 0\n"))
          (with-temp-file mmcli (insert "#!/bin/sh\nexit 0\n"))
          (mapc (lambda (file) (set-file-modes file #o755))
                (list nmcli ip mmcli))
          (with-temp-buffer
            (should (= 0 (call-process
                          "/bin/sh" nil t nil "-c"
                          (emacsos-net--reader-script)
                          "emacsos-net-read" emacsos-net-cell-connection
                          reader-directory marker)))
            (let ((blob (buffer-string)))
              (should (string-match-p "@@SAVED-FAILED\nyes" blob))
              (should-not (emacsos-net-state-saved-known
                           (emacsos-net--parse blob))))))
      (delete-directory reader-directory t)
      (delete-directory directory t))))

(ert-deftest test-net-reader-resolves-name-marker-once-after-snapshot ()
  (dolist (owned-present '(t nil))
    (let* ((directory (make-temp-file "test-net-marker-owner-" t))
           (reader-directory (make-temp-file "test-net-marker-reader-" t))
           (marker (expand-file-name "pending" directory))
           (calls (expand-file-name "calls" directory))
           (listed (expand-file-name "listed" directory))
           (nmcli (expand-file-name "nmcli" directory))
           (ip (expand-file-name "ip" directory))
           (mmcli (expand-file-name "mmcli" directory))
           (attempt "emacsos-wifi-attempt-00000000000000000000000000000000")
           (owned-uuid "11111111-2222-3333-4444-555555555555")
           (saved-uuid "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")
           (process-environment
            (cons (concat "TEST_NET_CALLS=" calls)
                  (cons (concat "TEST_NET_LISTED=" listed)
                        (cons (concat "PATH=" directory ":" (getenv "PATH"))
                              process-environment)))))
      (unwind-protect
          (progn
            (with-temp-file marker (insert "1:name:" attempt "\n"))
            (with-temp-file nmcli
              (insert
               "#!/bin/sh\n"
               "printf '%s\\n' \"$*\" >>\"$TEST_NET_CALLS\"\n"
               "case $* in\n"
               "  '-t -f WIFI radio') echo enabled ;;\n"
               "  '-e no -t -g connection.type con show id emacsos-cellular') echo gsm ;;\n"
               "  '-e no -t -g GENERAL.DEVICES con show id emacsos-cellular') echo -- ;;\n"
               "  '-e no -t -g UUID con show id " attempt "') "
               "[ -e \"$TEST_NET_LISTED\" ] || exit 9; "
               (if owned-present
                   (concat "echo " owned-uuid " ;;\n")
                 "exit 10 ;;\n")
               "  '-t -f UUID,TYPE con show') touch \"$TEST_NET_LISTED\"; "
               (if owned-present
                   (concat "echo '" owned-uuid ":802-11-wireless'; ")
                 "")
               "echo '" saved-uuid ":802-11-wireless' ;;\n"
               "  '-e no -t -g 802-11-wireless.ssid con show uuid "
               saved-uuid "') echo Cafe ;;\n"
               "  '-t -f ACTIVE,SSID-HEX,SIGNAL,SECURITY dev wifi') : ;;\n"
               "  *) exit 1 ;;\n"
               "esac\n"))
            (with-temp-file ip (insert "#!/bin/sh\nexit 0\n"))
            (with-temp-file mmcli (insert "#!/bin/sh\nexit 0\n"))
            (mapc (lambda (file) (set-file-modes file #o755))
                  (list nmcli ip mmcli))
            (with-temp-buffer
              (should (= 0 (call-process
                            "/bin/sh" nil t nil "-c"
                            (emacsos-net--reader-script)
                            "emacsos-net-read" emacsos-net-cell-connection
                            reader-directory marker)))
              (let ((blob (buffer-string)))
                (should (emacsos-net-state-saved-known
                         (emacsos-net--parse blob)))
                (should (string-match-p (regexp-quote saved-uuid) blob))
                (should-not (string-match-p (regexp-quote owned-uuid) blob))))
            (with-temp-buffer
              (insert-file-contents calls)
              (should (= 1 (how-many (concat "^-e no -t -g UUID con show id "
                                              (regexp-quote attempt) "$"))))
              (should-not (search-forward "connection.id con show uuid" nil t))))
        (delete-directory reader-directory t)
        (delete-directory directory t)))))

(ert-deftest test-net-reader-rejects-noncanonical-marker-records ()
  (dolist (record '("1:idle:\n" "01:idle\n"))
    (let* ((directory (make-temp-file "test-net-marker-invalid-" t))
           (reader-directory (make-temp-file "test-net-marker-reader-" t))
           (marker (expand-file-name "pending" directory))
           (process-environment
            (cons (concat "PATH=" directory ":" (getenv "PATH"))
                  process-environment)))
      (unwind-protect
          (progn
            (with-temp-file marker (insert record))
            (let ((nmcli (expand-file-name "nmcli" directory)))
              (with-temp-file nmcli
                (insert
                 "#!/bin/sh\n"
                 "case $* in\n"
                 "  '-t -f WIFI radio') echo enabled ;;\n"
                 "  '-e no -t -g connection.type con show id emacsos-cellular') echo gsm ;;\n"
                 "  '-e no -t -g GENERAL.DEVICES con show id emacsos-cellular') echo -- ;;\n"
                 "  '-t -f UUID,TYPE con show') : ;;\n"
                 "  '-t -f ACTIVE,SSID-HEX,SIGNAL,SECURITY dev wifi') : ;;\n"
                 "  *) exit 1 ;;\n"
                 "esac\n"))
              (set-file-modes nmcli #o755))
            (dolist (name '("ip" "mmcli"))
              (let ((tool (expand-file-name name directory)))
                (with-temp-file tool (insert "#!/bin/sh\nexit 0\n"))
                (set-file-modes tool #o755)))
            (with-temp-buffer
              (should (= 0 (call-process
                            "/bin/sh" nil t nil "-c"
                            (emacsos-net--reader-script)
                            "emacsos-net-read" emacsos-net-cell-connection
                            reader-directory marker)))
              (let ((blob (buffer-string)))
                (should (string-match-p "@@SAVED-FAILED\nyes" blob))
                (should-not (emacsos-net-state-saved-known
                             (emacsos-net--parse blob))))))
        (delete-directory reader-directory t)
        (delete-directory directory t)))))

(ert-deftest test-net-ssid-hex-rejects-controls-and-invalid-utf8 ()
  (should (equal (emacsos-net--decode-ssid-hex "436166c3a9") "Café"))
  (should-not (emacsos-net--decode-ssid-hex "09"))
  (should-not (emacsos-net--decode-ssid-hex "0a"))
  (should-not (emacsos-net--decode-ssid-hex "0d"))
  (should-not (emacsos-net--decode-ssid-hex "7f"))
  (should-not (emacsos-net--decode-ssid-hex "c280"))
  (should-not (emacsos-net--decode-ssid-hex "e280ae"))
  (should-not (emacsos-net--decode-ssid-hex "ff"))
  (should-not (emacsos-net--decode-ssid-hex "not-hex")))

(ert-deftest test-net-invalid-saved-record-fails-closed ()
  (dolist (record '("11111111-2222-3333-4444-555555555555:ff"
                    "not-a-uuid:43616665"))
    (let ((st (emacsos-net--parse
               (concat "@@RADIO\nenabled\n@@ROUTE\n@@CONS\n:\n"
                       "@@SAVED\n" record "\n@@SAVED-OK\nyes\n"
                       "@@WIFI\nno:43616665:50:WPA2\n"
                       "@@CELL\n@@END\n"))))
      (should-not (emacsos-net-state-saved-known st))
      (should-not (plist-get (car (emacsos-net-state-wifi-list st))
                             :saved-uuid)))))

(ert-deftest test-net-duplicate-saved-ssid-is-not-arbitrarily-selected ()
  (let* ((st (emacsos-net--parse
              (concat "@@RADIO\nenabled\n@@ROUTE\n@@CONS\n:\n"
                      "@@SAVED\n"
                      "11111111-2222-3333-4444-555555555555:43616665\n"
                      "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee:43616665\n"
                      "@@SAVED-OK\nyes\n"
                      "@@WIFI\nno:43616665:50:WPA2\n@@CELL\n@@END\n")))
         (network (car (emacsos-net-state-wifi-list st))))
    (should (emacsos-net-state-saved-known st))
    (should-not (plist-get network :saved-uuid))
    (should (eq (emacsos-net--connect-kind network) 'needs-password))))

(ert-deftest test-net-duplicate-visible-ssid-collapses-and-conflict-fails-closed ()
  (let* ((st (emacsos-net--parse
              (concat "@@RADIO\nenabled\n@@ROUTE\n@@CONS\n:\n"
                      "@@SAVED\n@@SAVED-OK\nyes\n@@WIFI\n"
                      "no:43616665:40:WPA2\n"
                      "no:43616665:80:--\n@@CELL\n@@END\n")))
         (networks (emacsos-net-state-wifi-list st))
         (network (car networks)))
    (should (= (length networks) 1))
    (should (equal (plist-get network :ssid) "Cafe"))
    (should (= (plist-get network :signal) 80))
    (should (eq (emacsos-net--connect-kind network)
                'unsupported-security))))

(ert-deftest test-net-parse-cell-active ()
  (let ((st (emacsos-net--parse test-net--blob-cell)))
    (should (eq (emacsos-net-state-active-iface st) 'cell))
    (should (null (emacsos-net-state-wifi-on st)))
    (should (= (emacsos-net-state-signal st) 45))
    (should (equal (emacsos-net-state-cell-state st) "connected"))
    (should (emacsos-net-state-cell-provisioned st))
    (should (emacsos-net-state-cell-on st))))

(ert-deftest test-net-parse-rejects-malformed-cell-signal ()
  (dolist (signal '("bogus" "-1" "101"))
    (should-error
     (emacsos-net--parse
      (concat "@@RADIO\ndisabled\n@@ROUTE\ndefault via 10.0.0.1 dev wwan0\n"
              "@@CONS\ngsm:wwan0\n@@WIFI\n@@CELL\n"
              "modem.generic.signal-quality.value : " signal "\n@@END\n"))))
  (dolist (case '(("" nil) ("0" 0) ("100" 100)))
    (let ((state
           (emacsos-net--parse
            (concat "@@RADIO\ndisabled\n@@ROUTE\ndefault via 10.0.0.1 dev wwan0\n"
                    "@@CONS\ngsm:wwan0\n@@WIFI\n@@CELL\n"
                    "modem.generic.signal-quality.value : " (car case)
                    "\n@@END\n"))))
      (should (equal (emacsos-net-state-signal state) (cadr case))))))

(ert-deftest test-net-parse-no-net-unprovisioned ()
  (let ((st (emacsos-net--parse test-net--blob-none)))
    (should (eq (emacsos-net-state-active-iface st) 'none))
    (should (null (emacsos-net-state-signal st)))
    (should (null (emacsos-net-state-cell-provisioned st)))
    (should (null (emacsos-net-state-cell-on st)))
    (should (= (length (emacsos-net-state-wifi-list st)) 1))))

(ert-deftest test-net-hot-reload-resets-stale-struct-shape ()
  (let ((emacsos-net--state
         (record 'emacsos-net-state 'unknown 'none nil nil nil nil "" 0.0)))
    (should (emacsos-net-state-p emacsos-net--state))
    (emacsos-net--ensure-state-shape)
    (should (= (emacsos-net-state-stamp emacsos-net--state) 0.0))
    (should-not (emacsos-net-state-cell-on emacsos-net--state))))

(ert-deftest test-net-hot-reload-preserves-pending-connection-owner ()
  (let ((emacsos-net--state (make-emacsos-net-state))
        (emacsos-net--proc nil)
        (emacsos-net--connection-pending
         '(:id 7 :ssid "CoffeeShop" :kind needs-password))
        (emacsos-net--connection-result nil)
        (emacsos-net--connection-result-timer nil))
    (load (expand-file-name "network.el" default-directory) nil t)
    (should (equal emacsos-net--connection-pending
                   '(:id 7 :ssid "CoffeeShop" :kind needs-password)))))

;;; connect-kind seam

(ert-deftest test-net-connect-kind ()
  (should (eq (emacsos-net--connect-kind '(:ssid "A" :saved-uuid "uuid" :security "WPA2")) 'saved))
  (should (eq (emacsos-net--connect-kind '(:ssid "B" :security "")) 'open))
  (should (eq (emacsos-net--connect-kind '(:ssid "C" :security nil)) 'open))
  (should (eq (emacsos-net--connect-kind '(:ssid "C2" :security "--")) 'open))
  (should (eq (emacsos-net--connect-kind '(:ssid "D" :security "WPA2"))
              'needs-password))
  (should (eq (emacsos-net--connect-kind '(:ssid "E" :security "WPA2 802.1X"))
              'unsupported-security)))

(ert-deftest test-net-parse-classifies-list ()
  (let* ((st (emacsos-net--parse test-net--blob-wifi))
         (by (lambda (s) (seq-find (lambda (n) (string= (plist-get n :ssid) s))
                                   (emacsos-net-state-wifi-list st)))))
    (should (eq (emacsos-net--connect-kind (funcall by "HomeNet")) 'saved))
    (should (equal (plist-get (funcall by "HomeNet") :saved-uuid)
                   "11111111-2222-3333-4444-555555555555"))
    (should (eq (emacsos-net--connect-kind (funcall by "OpenNet")) 'open))
    (should (eq (emacsos-net--connect-kind (funcall by "CoffeeShop")) 'needs-password))))

(ert-deftest test-net-incomplete-saved-enumeration-disables-connect ()
  (let* ((emacsos-net--state
          (emacsos-net--parse
           (concat "@@RADIO\nenabled\n@@ROUTE\n@@CONS\n@@SAVED\n"
                   "@@SAVED-FAILED\nyes\n@@SAVED-OK\nyes\n"
                   "@@WIFI\nno:436f6666656553686f70:54:WPA2\n"
                   "@@CELL\n@@END\n")))
         (prompted nil)
         (called nil))
    (should-not (emacsos-net-state-saved-known emacsos-net--state))
    (cl-letf (((symbol-function 'read-passwd) (lambda (&rest _) (setq prompted t)))
              ((symbol-function 'emacsos-net--render-if-shown) #'ignore)
              ((symbol-function 'run-with-timer) (lambda (&rest _) 'timer)))
      (let ((emacsos-net-connection-function (lambda (&rest _) (setq called t))))
        (should (equal (emacsos-net-connect "CoffeeShop")
                       "not-connected:unavailable"))
        (should-not prompted)
        (should-not called)))))

;;; Modeline formatter

(ert-deftest test-net-segment-text ()
  (should (equal (emacsos-net--segment-text
                  (make-emacsos-net-state :active-iface 'wifi :signal 82)) "wifi 82%"))
  (should (equal (emacsos-net--segment-text
                  (make-emacsos-net-state :active-iface 'cell :signal 45)) "lte 45%"))
  (should (equal (emacsos-net--segment-text
                  (make-emacsos-net-state :active-iface 'none)) "no net")))

(ert-deftest test-net-mode-line-string-is-tappable ()
  (let* ((emacsos-net--state (make-emacsos-net-state :active-iface 'wifi :signal 82))
         (s (emacsos-net-mode-line-string)))
    (should (equal (substring-no-properties s) "wifi 82%"))
    (should (get-text-property 0 'local-map s))
    (should (eq (get-text-property 0 'mouse-face s) 'mode-line-highlight))))

(ert-deftest test-net-cell-toggle-follows-profile-activity-not-default-route ()
  (let ((seen nil))
    (cl-letf (((symbol-function 'emacsos-net--action)
               (lambda (args &optional _completion) (setq seen args))))
      (let ((emacsos-net--state
             (make-emacsos-net-state :active-iface 'wifi
                                    :cell-provisioned t :cell-on t :valid t))
            (emacsos-net--cell-operation nil))
        (emacsos-net-toggle-cell)
        (should (equal seen '("con" "down" "emacsos-cellular"))))
      (let ((emacsos-net--state
             (make-emacsos-net-state :active-iface 'wifi
                                    :cell-provisioned t :cell-on nil :valid t))
            (emacsos-net--cell-operation nil))
        (emacsos-net-toggle-cell)
        (should (equal seen '("con" "up" "emacsos-cellular")))))))

(ert-deftest test-net-explicit-cell-setter-rejects-invalid-snapshot ()
  (let ((emacsos-net--state (make-emacsos-net-state :valid nil))
        delivered)
    (should (equal (emacsos-net-set-cell t
                                       (lambda (ok detail)
                                         (setq delivered (list ok detail))))
                   "error: cellular status is unavailable"))
    (should (equal delivered '(nil "cellular status is unavailable")))))

(ert-deftest test-net-explicit-cell-setter-rejects-non-boolean-state ()
  (let ((emacsos-net--state
         (make-emacsos-net-state :valid t :cell-provisioned t)))
    (should-error (emacsos-net-set-cell 'toggle) :type 'user-error)))

(ert-deftest test-net-cell-setter-does-not-report-pending-after-launch-failure ()
  (let ((emacsos-net--state
         (make-emacsos-net-state :valid t :cell-provisioned t))
        (emacsos-net--cell-operation nil)
        (emacsos-net-command-function (lambda (_) (error "rejected")))
        delivered)
    (should (equal (emacsos-net-set-cell
                    t (lambda (ok detail) (setq delivered (list ok detail))))
                   "error: network action could not start"))
    (should (equal delivered '(nil "rejected")))
    (should-not (emacsos-net-state-cell-pending emacsos-net--state))
    (should (equal (emacsos-net-state-cell-error emacsos-net--state) "rejected"))))

(ert-deftest test-net-cell-setter-records-terminal-state-without-caller-callback ()
  (let ((emacsos-net--state
         (make-emacsos-net-state :valid t :cell-provisioned t :cell-on nil))
        (emacsos-net--cell-operation nil)
        action-completion)
    (cl-letf (((symbol-function 'emacsos-net--action)
               (lambda (_args completion)
                 (setq action-completion completion)
                 'process))
              ((symbol-function 'emacsos-net--notify-state-change) #'ignore))
      (should (equal (emacsos-net-set-cell t)
                     "pending: cellular data turning on"))
      (should (eq (emacsos-net-state-cell-pending emacsos-net--state) 'on))
      (funcall action-completion t "ok")
      (should-not (emacsos-net-state-cell-pending emacsos-net--state))
      (should (emacsos-net-state-cell-on emacsos-net--state))
      (should-not (emacsos-net-state-cell-error emacsos-net--state))
      (funcall action-completion nil "modem rejected")
      (should (emacsos-net-state-cell-on emacsos-net--state))
      (should-not (emacsos-net-state-cell-error emacsos-net--state)))))

(ert-deftest test-net-cell-setter-failure-restores-pre-action-state ()
  (let ((emacsos-net--state
         (make-emacsos-net-state :valid t :cell-provisioned t :cell-on nil))
        (emacsos-net--cell-operation nil)
        action-completion)
    (cl-letf (((symbol-function 'emacsos-net--action)
               (lambda (_args completion)
                 (setq action-completion completion)
                 'process))
              ((symbol-function 'emacsos-net--notify-state-change) #'ignore))
      (emacsos-net-set-cell t)
      (setf (emacsos-net-state-cell-on emacsos-net--state) t)
      (funcall action-completion nil "modem rejected")
      (should-not (emacsos-net-state-cell-pending emacsos-net--state))
      (should-not (emacsos-net-state-cell-on emacsos-net--state))
      (should (equal (emacsos-net-state-cell-error emacsos-net--state)
                     "modem rejected")))))

(ert-deftest test-net-cell-setter-rejects-overlapping-operation ()
  (let ((emacsos-net--state
         (make-emacsos-net-state :valid t :cell-provisioned t :cell-on nil))
        (emacsos-net--cell-operation nil)
        first-completion second-result)
    (cl-letf (((symbol-function 'emacsos-net--action)
               (lambda (_args completion)
                 (setq first-completion completion)
                 'process))
              ((symbol-function 'emacsos-net--notify-state-change) #'ignore))
      (should (equal (emacsos-net-set-cell t)
                     "pending: cellular data turning on"))
      (should (equal
               (emacsos-net-set-cell
                nil (lambda (success detail)
                      (setq second-result (list success detail))))
               "error: cellular operation is already running"))
      (should (equal second-result
                     '(nil "cellular operation is already running")))
      (should (eq (emacsos-net-state-cell-pending emacsos-net--state) 'on))
      (funcall first-completion t "ok")
      (should-not emacsos-net--cell-operation)
      (should-not (emacsos-net-state-cell-pending emacsos-net--state))
      (should (emacsos-net-state-cell-on emacsos-net--state)))))

(ert-deftest test-net-cell-setter-interactively-reads-explicit-state ()
  (let ((emacsos-net--state
         (make-emacsos-net-state :valid t :cell-provisioned t :cell-on t))
        (emacsos-net--cell-operation nil)
        seen)
    (cl-letf (((symbol-function 'completing-read) (lambda (&rest _) "off"))
              ((symbol-function 'emacsos-net--action)
               (lambda (args _completion) (setq seen args) 'process))
              ((symbol-function 'emacsos-net--notify-state-change) #'ignore))
      (call-interactively #'emacsos-net-set-cell))
    (should (equal seen '("con" "down" "emacsos-cellular")))))

(ert-deftest test-net-state-change-notifies-platform-consumers ()
  (let ((emacsos-net-state-change-functions nil)
        notified)
    (add-hook 'emacsos-net-state-change-functions
              (lambda () (setq notified t)))
    (cl-letf (((symbol-function 'force-mode-line-update) #'ignore)
              ((symbol-function 'emacsos-net--render-if-shown) #'ignore))
      (emacsos-net--notify-state-change))
    (should notified)))

(ert-deftest test-net-parse-rejects-unrecognized-radio-output ()
  (should-error
   (emacsos-net--parse
    "@@RADIO\nmaybe\n@@ROUTE\n@@CONS\n@@WIFI\n@@CELL\n@@END\n")))

(ert-deftest test-net-parse-rejects-malformed-networkmanager-records ()
  (should-error
   (emacsos-net--parse
    "@@RADIO\nenabled\n@@ROUTE\n@@CONS\nmissing-fields\n@@WIFI\n@@CELL\n@@END\n"))
  (should-error
   (emacsos-net--parse
    "@@RADIO\nenabled\n@@ROUTE\n@@CONS\n@@WIFI\nyes:OnlyTwoFields\n@@CELL\n@@END\n")))

(ert-deftest test-net-malformed-terminal-snapshot-becomes-unavailable ()
  (let ((buffer (generate-new-buffer " *test-malformed-net*"))
        (emacsos-net--state (make-emacsos-net-state :valid t :cell-on t))
        (emacsos-net--proc 'reader))
    (with-current-buffer buffer
      (insert "@@RADIO\nmaybe\n@@ROUTE\n@@CONS\n@@WIFI\n@@CELL\n@@END\n"))
    (cl-letf (((symbol-function 'process-status) (lambda (_) 'exit))
              ((symbol-function 'process-exit-status) (lambda (_) 0))
              ((symbol-function 'process-buffer) (lambda (_) buffer))
              ((symbol-function 'process-get) (lambda (&rest _) nil))
              ((symbol-function 'force-mode-line-update) #'ignore)
              ((symbol-function 'emacsos-net--render-if-shown) #'ignore))
      (emacsos-net--reader-sentinel 'reader "finished"))
    (should-not (emacsos-net-state-valid emacsos-net--state))
    (should (emacsos-net-state-cell-on emacsos-net--state))
    (should (string-match-p "invalid Wi-Fi" (emacsos-net-state-error emacsos-net--state)))
    (should-not emacsos-net--proc)
    (should-not (buffer-live-p buffer))))

(ert-deftest test-net-overflowed-reader-never-parses-partial-output ()
  (let ((buffer (generate-new-buffer " *test-overflowed-net*"))
        (emacsos-net--state (make-emacsos-net-state :valid t :cell-on t))
        (emacsos-net--proc 'reader))
    (with-current-buffer buffer (insert test-net--blob-wifi))
    (cl-letf (((symbol-function 'process-status) (lambda (_) 'exit))
              ((symbol-function 'process-exit-status) (lambda (_) 0))
              ((symbol-function 'process-buffer) (lambda (_) buffer))
              ((symbol-function 'process-get)
               (lambda (_proc key) (eq key 'emacsos-net-overflow)))
              ((symbol-function 'force-mode-line-update) #'ignore)
              ((symbol-function 'emacsos-net--render-if-shown) #'ignore))
      (emacsos-net--reader-sentinel 'reader "finished"))
    (should-not (emacsos-net-state-valid emacsos-net--state))
    (should (emacsos-net-state-cell-on emacsos-net--state))
    (should (equal (emacsos-net-state-error emacsos-net--state)
                   "network status response is too large"))
    (should-not emacsos-net--proc)
    (should-not (buffer-live-p buffer))))

(ert-deftest test-net-refresh-preserves-cell-action-state ()
  (let ((buffer (generate-new-buffer " *test-net-cell-error*"))
        (emacsos-net--state
         (make-emacsos-net-state :valid t :cell-error "modem rejected"
                                :cell-pending 'off))
        (emacsos-net--proc 'reader))
    (with-current-buffer buffer
      (insert "@@RADIO\ndisabled\n@@ROUTE\n@@CONS\n@@WIFI\n@@CELL\n@@END\n"))
    (cl-letf (((symbol-function 'process-status) (lambda (_) 'exit))
              ((symbol-function 'process-exit-status) (lambda (_) 0))
              ((symbol-function 'process-buffer) (lambda (_) buffer))
              ((symbol-function 'process-get) (lambda (&rest _) nil))
              ((symbol-function 'force-mode-line-update) #'ignore)
              ((symbol-function 'emacsos-net--render-if-shown) #'ignore))
      (emacsos-net--reader-sentinel 'reader "finished"))
    (should (emacsos-net-state-valid emacsos-net--state))
    (should (equal (emacsos-net-state-cell-error emacsos-net--state)
                   "modem rejected"))
    (should (eq (emacsos-net-state-cell-pending emacsos-net--state) 'off))
    (should-not emacsos-net--proc)
    (should-not (buffer-live-p buffer))))

(ert-deftest test-net-action-destroys-buffer-and-old-reader-before-completion ()
  (let ((emacsos-net--proc 'old-reader)
        (emacsos-net--settle-generation 0)
        (emacsos-net--settle-pending nil)
        sentinel delivered action-buffer deleted scheduled command coding filter)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args)
                 (setq sentinel (plist-get args :sentinel)
                       action-buffer (plist-get args :buffer)
                       command (plist-get args :command)
                       coding (plist-get args :coding)
                       filter (plist-get args :filter))
                 'action-process))
              ((symbol-function 'process-status) (lambda (_) 'exit))
              ((symbol-function 'process-live-p) (lambda (_) t))
              ((symbol-function 'process-id) (lambda (_) 123))
              ((symbol-function 'signal-process) #'ignore)
              ((symbol-function 'process-exit-status) (lambda (_) 0))
              ((symbol-function 'process-buffer)
               (lambda (process)
                 (and (eq process 'action-process) action-buffer)))
              ((symbol-function 'process-get) (lambda (&rest _) nil))
              ((symbol-function 'set-process-sentinel) #'ignore)
              ((symbol-function 'delete-process)
               (lambda (process) (setq deleted process)))
              ((symbol-function 'run-with-timer)
               (lambda (_seconds _repeat function &rest args)
                 (setq scheduled (cons function args)))))
      (emacsos-net--action '("radio" "wifi" "on")
                          (lambda (ok detail)
                            (setq delivered
                                  (list ok detail
                                        (buffer-live-p action-buffer)
                                        emacsos-net--proc))))
      (with-current-buffer action-buffer (insert "enabled\n"))
      (funcall sentinel 'action-process "finished")
      (funcall sentinel 'action-process "finished again"))
    (should (equal delivered '(t "enabled" nil nil)))
    (should (equal command
                   '("/usr/bin/timeout" "-s" "TERM" "-k" "1" "8"
                     "nmcli" "radio" "wifi" "on")))
    (should (eq coding 'binary))
    (should (eq filter #'emacsos-net--action-filter))
    (should (eq deleted 'old-reader))
    (should (equal scheduled '(emacsos-net--refresh-after-action 1)))
    (should (= emacsos-net--settle-pending 1))))

(ert-deftest test-net-action-filter-bounds-cumulative-output ()
  (let ((buffer (generate-new-buffer " *test-net-action-filter*"))
        (properties nil)
        (emacsos-net--max-action-bytes 4)
        signaled deleted)
    (unwind-protect
        (cl-letf (((symbol-function 'process-get)
                   (lambda (_proc key) (alist-get key properties)))
                  ((symbol-function 'process-put)
                   (lambda (_proc key value)
                     (setf (alist-get key properties) value)))
                  ((symbol-function 'process-buffer) (lambda (_) buffer))
                  ((symbol-function 'process-live-p) (lambda (_) t))
                  ((symbol-function 'process-id) (lambda (_) 123))
                  ((symbol-function 'signal-process)
                   (lambda (pid signal) (setq signaled (list pid signal))))
                  ((symbol-function 'delete-process)
                   (lambda (proc) (setq deleted proc))))
          (emacsos-net--action-filter 'action "abc\n")
          (should (equal (with-current-buffer buffer (buffer-string)) "abc\n"))
          (emacsos-net--action-filter 'action "x")
          (should (alist-get 'emacsos-net-action-overflow properties))
          (should (equal signaled '(-123 SIGKILL)))
          (should (eq deleted 'action))
          (should (equal (with-current-buffer buffer (buffer-string)) "abc\n")))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest test-net-action-timeout-clears-wifi-pending-exactly-once ()
  (let ((emacsos-net--state
         (make-emacsos-net-state :valid t :wifi-on nil))
        (emacsos-net--wifi-operation nil)
        (emacsos-net--settle-generation 0)
        (emacsos-net--settle-pending nil)
        sentinel action-buffer delivered)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args)
                 (setq sentinel (plist-get args :sentinel)
                       action-buffer (plist-get args :buffer))
                 'action-process))
              ((symbol-function 'process-status) (lambda (_) 'exit))
              ((symbol-function 'process-exit-status) (lambda (_) 124))
              ((symbol-function 'process-buffer) (lambda (_) action-buffer))
              ((symbol-function 'process-get) (lambda (&rest _) nil))
              ((symbol-function 'emacsos-net--discard-reader) #'ignore)
              ((symbol-function 'emacsos-net--notify-state-change) #'ignore)
              ((symbol-function 'run-with-timer) (lambda (&rest _) 'timer)))
      (should (equal
               (emacsos-net-set-wifi
                t (lambda (success detail)
                    (push (list success detail) delivered)))
               "pending: Wi-Fi turning on"))
      (should (eq (emacsos-net-state-wifi-pending emacsos-net--state) 'on))
      (funcall sentinel 'action-process "finished")
      (funcall sentinel 'action-process "finished again"))
    (should (equal delivered '((nil "network action timed out"))))
    (should-not emacsos-net--wifi-operation)
    (should-not (emacsos-net-state-wifi-pending emacsos-net--state))
    (should-not (emacsos-net-state-wifi-on emacsos-net--state))
    (should (equal (emacsos-net-state-wifi-error emacsos-net--state)
                   "network action timed out"))
    (should-not (buffer-live-p action-buffer))))

(ert-deftest test-net-post-action-refresh-replaces-settle-window-reader ()
  (let ((emacsos-net--proc 'intervening-reader)
        (emacsos-net--settle-pending 2)
        deleted refreshed)
    (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
              ((symbol-function 'process-id) (lambda (_) 123))
              ((symbol-function 'signal-process) #'ignore)
              ((symbol-function 'set-process-sentinel) #'ignore)
              ((symbol-function 'delete-process)
               (lambda (process) (setq deleted process)))
              ((symbol-function 'process-buffer) (lambda (_) nil))
              ((symbol-function 'emacsos-net--refresh)
               (lambda () (setq refreshed t))))
      (emacsos-net--refresh-after-action 2))
    (should (eq deleted 'intervening-reader))
    (should refreshed)
    (should-not emacsos-net--settle-pending)
    (should-not emacsos-net--proc)))

(ert-deftest test-net-refresh-noop-during-action-settle ()
  (let ((emacsos-net--proc nil)
        (emacsos-net--settle-pending 3)
        spawned)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest _) (setq spawned t))))
      (emacsos-net--refresh))
    (should-not spawned)
    (should (= emacsos-net--settle-pending 3))))

(ert-deftest test-net-stale-action-refresh-keeps-current-settle-guard ()
  (let ((emacsos-net--proc nil)
        (emacsos-net--settle-pending 4)
        refreshed)
    (cl-letf (((symbol-function 'emacsos-net--refresh)
               (lambda () (setq refreshed t))))
      (emacsos-net--refresh-after-action 3))
    (should-not refreshed)
    (should (= emacsos-net--settle-pending 4))))

;;; Page render

(ert-deftest test-net-render-shows-toggles-list-and-refresh ()
  (let ((emacsos-net--state (emacsos-net--parse test-net--blob-wifi)))
    (unwind-protect
        (let ((s (with-current-buffer (emacsos-net--render) (buffer-string))))
          (should (string-match-p "Wifi off" s))   ; wifi on -> toggle says "off"
          (should (string-match-p "Cell: on (registered)" s))
          (should (string-match-p "Cell off" s))
          (should (string-match-p "HomeNet" s))     ; the active network
          (should (string-match-p "OpenNet" s))     ; an open network
          (should (string-match-p "Refresh" s))
          (should-not (string-match-p "credential entry" s)))
      (when (get-buffer emacsos-net--buffer-name)
        (kill-buffer emacsos-net--buffer-name)))))

(ert-deftest test-net-render-unprovisioned-cell-has-no-toggle ()
  (let ((emacsos-net--state (emacsos-net--parse test-net--blob-none)))
    (unwind-protect
        (let ((s (with-current-buffer (emacsos-net--render) (buffer-string))))
          (should (string-match-p "not set up" s)))
      (when (get-buffer emacsos-net--buffer-name)
        (kill-buffer emacsos-net--buffer-name)))))

(ert-deftest test-net-phone-render-is-bounded-and-paginated ()
  (let* ((networks
          (cl-loop for index from 1 to 6
                   collect (list :ssid (format "Network-%s-with-a-long-name" index)
                                 :signal 50 :security "" :saved-uuid nil)))
         (emacsos-net--state
          (make-emacsos-net-state :valid t :wifi-on t :saved-known t
                                  :wifi-list networks))
         (emacsos-net-return-function #'ignore)
         (emacsos-net--page 0))
    (unwind-protect
        (progn
          (with-current-buffer (emacsos-net--render)
            (let ((text (buffer-string)))
              (should (= (line-number-at-pos (point-max)) 8))
              (should truncate-lines)
              (should-not mode-line-format)
              (should (string-match-p "Done" text))
              (should (string-match-p "Network-4" text))
              (should-not (string-match-p "Network-5" text))
              (should (string-match-p "Next" text))))
          (emacsos-net--change-page 1)
          (with-current-buffer emacsos-net--buffer-name
            (let ((text (buffer-string)))
              (should (string-match-p "Network-5" text))
              (should (string-match-p "Previous" text))
              (should-not (string-match-p "Next" text)))))
      (when (get-buffer emacsos-net--buffer-name)
        (kill-buffer emacsos-net--buffer-name)))))

(ert-deftest test-net-phone-done-returns-once ()
  (let ((emacsos-net-return-function nil)
        (emacsos-net--page 1)
        (returns 0))
    (setq emacsos-net-return-function (lambda () (cl-incf returns)))
    (emacsos-net-done)
    (emacsos-net-done)
    (should (= returns 1))
    (should-not emacsos-net-return-function)
    (should (= emacsos-net--page 0))))

(ert-deftest test-net-phone-render-hides-stale-networks-when-invalid ()
  (let ((emacsos-net--state
         (make-emacsos-net-state
          :valid nil :error "reader failed" :saved-known t
          :wifi-list '((:ssid "StaleNet" :signal 50 :security ""))))
        (emacsos-net-return-function #'ignore))
    (unwind-protect
        (with-current-buffer (emacsos-net--render)
          (should (string-match-p "Networks unavailable" (buffer-string)))
          (should-not (string-match-p "StaleNet" (buffer-string))))
      (when (get-buffer emacsos-net--buffer-name)
        (kill-buffer emacsos-net--buffer-name)))))

(ert-deftest test-net-phone-empty-rows-reserve-button-height ()
  (let ((emacsos-net--state
         (make-emacsos-net-state :valid t :saved-known t :wifi-list nil))
        (emacsos-net-return-function #'ignore)
        (expected (+ (frame-char-height) (* 2 emacsos--btn-vpad))))
    (unwind-protect
        (with-current-buffer (emacsos-net--render)
          (goto-char (point-min))
          (forward-line 2)
          (should (= (get-text-property (point) 'line-height) expected))
          (forward-line 4)
          (should (= (get-text-property (point) 'line-height) expected)))
      (when (get-buffer emacsos-net--buffer-name)
        (kill-buffer emacsos-net--buffer-name)))))

(ert-deftest test-net-full-render-clears-phone-buffer-locals ()
  (let ((emacsos-net--state
         (make-emacsos-net-state :valid t :saved-known t :wifi-list nil))
        (emacsos-net-return-function #'ignore))
    (unwind-protect
        (progn
          (emacsos-net--render)
          (setq emacsos-net-return-function nil)
          (with-current-buffer (emacsos-net--render)
            (should-not (local-variable-p 'truncate-lines))
            (should-not (local-variable-p 'mode-line-format))))
      (when (get-buffer emacsos-net--buffer-name)
        (kill-buffer emacsos-net--buffer-name)))))

(ert-deftest test-net-explicit-wifi-setter-owns-pending-state ()
  (let ((emacsos-net--state (make-emacsos-net-state :valid t :wifi-on nil))
        (emacsos-net--wifi-operation nil)
        action-args action-completion)
    (cl-letf (((symbol-function 'emacsos-net--action)
               (lambda (args completion)
                 (setq action-args args action-completion completion)
                 t))
              ((symbol-function 'emacsos-net--notify-state-change) #'ignore))
      (should (equal (emacsos-net-set-wifi t) "pending: Wi-Fi turning on"))
      (should (equal action-args '("radio" "wifi" "on")))
      (should (eq (emacsos-net-state-wifi-pending emacsos-net--state) 'on))
      (should (string-prefix-p "error:" (emacsos-net-set-wifi nil)))
      (funcall action-completion t "enabled")
      (should (eq (emacsos-net-state-wifi-on emacsos-net--state) t))
      (should-not (emacsos-net-state-wifi-pending emacsos-net--state))
      (should-not emacsos-net--wifi-operation))))

;;; Single-flight refresh guard

(ert-deftest test-net-refresh-noop-when-reader-live ()
  (let ((emacsos-net--proc 'fake)
        (spawned nil))
    (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
              ((symbol-function 'make-process)
               (lambda (&rest _) (setq spawned t) 'p)))
      (emacsos-net--refresh)
      (should-not spawned))))

(ert-deftest test-net-reader-has-whole-process-timeout ()
  (let ((emacsos-net--proc nil)
        (emacsos-net--settle-pending nil)
        command coding filter buffer reader-directory)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest args)
                 (setq command (plist-get args :command)
                       coding (plist-get args :coding)
                       filter (plist-get args :filter)
                       buffer (plist-get args :buffer))
                 'reader))
              ((symbol-function 'process-put) #'ignore)
              ((symbol-function 'emacsos-net--render-if-shown) #'ignore))
      (unwind-protect
          (progn
            (emacsos-net--refresh)
            (setq reader-directory (car (last command 2)))
            (should (equal (seq-take command 7)
                           '("/usr/bin/timeout" "-s" "TERM" "-k" "1" "8" "sh")))
            (should (equal (seq-take (last command 4) 2)
                           '("emacsos-net-read" "emacsos-cellular")))
            (should (equal (car (last command))
                           "/var/lib/emacsos-openrc-wifi-pending"))
            (should (eq coding 'binary))
            (should (eq filter #'emacsos-net--reader-filter))
            (should (file-directory-p reader-directory)))
        (when (buffer-live-p buffer) (kill-buffer buffer))
        (when (and reader-directory (file-exists-p reader-directory))
          (delete-directory reader-directory t))))))

(ert-deftest test-net-reader-filter-bounds-cumulative-bytes ()
  (let ((buffer (generate-new-buffer " *test-net-filter*"))
        (properties nil)
        (emacsos-net--max-reader-bytes 4)
        (emacsos-net--max-reader-lines 10)
        signaled deleted)
    (unwind-protect
        (cl-letf (((symbol-function 'process-get)
                   (lambda (_proc key) (alist-get key properties)))
                  ((symbol-function 'process-put)
                   (lambda (_proc key value)
                     (setf (alist-get key properties) value)))
                  ((symbol-function 'process-buffer) (lambda (_) buffer))
                  ((symbol-function 'process-live-p) (lambda (_) t))
                  ((symbol-function 'process-id) (lambda (_) 123))
                  ((symbol-function 'signal-process)
                   (lambda (pid signal) (setq signaled (list pid signal))))
                  ((symbol-function 'delete-process)
                   (lambda (proc) (setq deleted proc))))
          (emacsos-net--reader-filter 'reader "abc\n")
          (should (equal (with-current-buffer buffer (buffer-string)) "abc\n"))
          (should (= (alist-get 'emacsos-net-bytes properties) 4))
          (emacsos-net--reader-filter 'reader "x")
          (should (alist-get 'emacsos-net-overflow properties))
          (should (equal signaled '(-123 SIGKILL)))
          (should (eq deleted 'reader))
          (should (equal (with-current-buffer buffer (buffer-string)) "abc\n")))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

(ert-deftest test-net-reader-filter-bounds-record-lines ()
  (let ((buffer (generate-new-buffer " *test-net-lines*"))
        (properties nil)
        (emacsos-net--max-reader-bytes 100)
        (emacsos-net--max-reader-lines 1))
    (unwind-protect
        (cl-letf (((symbol-function 'process-get)
                   (lambda (_proc key) (alist-get key properties)))
                  ((symbol-function 'process-put)
                   (lambda (_proc key value)
                     (setf (alist-get key properties) value)))
                  ((symbol-function 'process-buffer) (lambda (_) buffer))
                  ((symbol-function 'process-live-p) (lambda (_) nil)))
          (emacsos-net--reader-filter 'reader "first\nsecond\n")
          (should (alist-get 'emacsos-net-overflow properties))
          (should (string-empty-p
                   (with-current-buffer buffer (buffer-string)))))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))

;;; Connection attempts

(ert-deftest test-net-saved-connect-uses-profile-uuid ()
  (let ((emacsos-net--state (emacsos-net--parse test-net--blob-wifi))
        (emacsos-net--connection-pending nil)
        seen)
    (cl-letf (((symbol-function 'emacsos-net--render-if-shown) #'ignore)
              ((symbol-function 'run-with-timer) (lambda (&rest _) 'timer)))
      (let ((emacsos-net-connection-function
             (lambda (kind target password _completion)
               (setq seen (list kind target password))
               "connected")))
        (should (equal (emacsos-net-connect "HomeNet") "connected"))
        (should (equal seen '(saved "11111111-2222-3333-4444-555555555555" nil)))
        (should (string-match-p "Connected to HomeNet"
                                (plist-get emacsos-net--connection-result :text)))))))

(ert-deftest test-net-secured-connect-masks-and-clears-password ()
  (let ((emacsos-net--state (emacsos-net--parse test-net--blob-wifi))
        (emacsos-net--connection-pending nil)
        passed copied)
    (cl-letf (((symbol-function 'read-passwd)
               (lambda (&rest _) (copy-sequence "secret")))
              ((symbol-function 'emacsos-net--render-if-shown) #'ignore))
      (let ((emacsos-net-connection-function
             (lambda (kind target password _completion)
               (setq passed password copied (copy-sequence password))
               emacsos-net--connection-pending-result)))
        (should (equal (emacsos-net-connect "CoffeeShop")
                       emacsos-net--connection-pending-result))
        (should (equal copied "secret"))
        (should (equal passed (make-string 6 0)))
        (should (eq (plist-get emacsos-net--connection-pending :kind)
                    'needs-password))))))

(ert-deftest test-net-secured-prompt-owns-attempt ()
  (let ((emacsos-net--state (emacsos-net--parse test-net--blob-wifi))
        (emacsos-net--connection-pending nil)
        busy-result
        (transport-calls 0))
    (cl-letf (((symbol-function 'read-passwd)
               (lambda (&rest _)
                 (setq busy-result (emacsos-net-connect "OpenNet"))
                 (copy-sequence "secret")))
              ((symbol-function 'emacsos-net--render-if-shown) #'ignore))
      (let ((emacsos-net-connection-function
             (lambda (_kind _target _password _completion)
               (cl-incf transport-calls)
               emacsos-net--connection-pending-result)))
        (should (equal (emacsos-net-connect "CoffeeShop")
                       emacsos-net--connection-pending-result))
        (should (equal busy-result "not-connected:busy"))
        (should (= transport-calls 1))
        (should (equal (plist-get emacsos-net--connection-pending :ssid)
                       "CoffeeShop"))))))

(ert-deftest test-net-cancelled-password-prompt-releases-attempt ()
  (let ((emacsos-net--state (emacsos-net--parse test-net--blob-wifi))
        (emacsos-net--connection-pending nil))
    (cl-letf (((symbol-function 'read-passwd)
               (lambda (&rest _) (signal 'quit nil)))
              ((symbol-function 'emacsos-net--render-if-shown) #'ignore))
      (condition-case nil
          (progn
            (emacsos-net-connect "CoffeeShop")
            (ert-fail "password prompt cancellation did not quit"))
        (quit nil))
      (should-not emacsos-net--connection-pending))))

(ert-deftest test-net-stale-completion-cannot-finish-new-attempt ()
  (let ((emacsos-net--state (emacsos-net--parse test-net--blob-wifi))
        (emacsos-net--connection-pending nil)
        completions)
    (cl-letf (((symbol-function 'emacsos-net--render-if-shown) #'ignore))
      (let ((emacsos-net-connection-function
             (lambda (_kind _target _password completion)
               (push completion completions)
               emacsos-net--connection-pending-result)))
        (emacsos-net-connect "OpenNet")
        (setq emacsos-net--connection-pending nil)
        (emacsos-net-connect "OpenNet")
        (funcall (cadr completions) "connected")
        (should emacsos-net--connection-pending)
        (should-not emacsos-net--connection-result)))))

(ert-deftest test-net-direct-terminal-needs-no-completion ()
  (let ((emacsos-net--state (emacsos-net--parse test-net--blob-wifi))
        (emacsos-net--connection-pending nil)
        delays)
    (cl-letf (((symbol-function 'emacsos-net--render-if-shown) #'ignore)
              ((symbol-function 'run-with-timer)
               (lambda (delay &rest _) (push delay delays) 'timer)))
      (let ((emacsos-net-connection-function
             (lambda (_kind _target _password _completion)
               "not-connected:failed")))
        (emacsos-net-connect "OpenNet")
        (should-not emacsos-net--connection-pending)
        (should (equal (plist-get emacsos-net--connection-result :text)
                       "Couldn’t connect. Try again."))
        (should (member 8 delays))))))

(ert-deftest test-net-display-ssid-escapes-controls ()
  (should (equal (emacsos-net--display-ssid "evil\nssid\t")
                 "evil\\nssid\\11")))

(ert-deftest test-net-invalid-ssid-returns-finite-result ()
  (let ((emacsos-net--connection-pending nil))
    (cl-letf (((symbol-function 'emacsos-net--render-if-shown) #'ignore)
              ((symbol-function 'run-with-timer) (lambda (&rest _) 'timer)))
      (should (equal (emacsos-net-connect nil)
                     "not-connected:invalid-input"))
      (should-not emacsos-net--connection-pending))))

(ert-deftest test-net-result-expiry-is-attempt-owned ()
  (let ((emacsos-net--connection-result '(:id 2 :text "new"))
        (emacsos-net--connection-result-timer 'timer))
    (cl-letf (((symbol-function 'emacsos-net--render-if-shown) #'ignore))
      (emacsos-net--expire-result 1)
      (should emacsos-net--connection-result)
      (emacsos-net--expire-result 2)
      (should-not emacsos-net--connection-result)
      (should-not emacsos-net--connection-result-timer))))

(ert-deftest test-net-discard-neutralizes-terminated-reader-sentinel ()
  (let ((emacsos-net--proc 'terminated-reader)
        (sentinel nil))
    (cl-letf (((symbol-function 'process-live-p) (lambda (_) nil))
              ((symbol-function 'set-process-sentinel)
               (lambda (p fn) (setq sentinel (cons p fn))))
              ((symbol-function 'process-buffer) (lambda (_) nil)))
      (emacsos-net--discard-reader)
      (should (eq (car sentinel) 'terminated-reader))
      (should (eq (cdr sentinel) #'ignore))
      (should-not emacsos-net--proc))))

(ert-deftest test-net-discard-kills-live-reader-process-group ()
  (let ((emacsos-net--proc 'live-reader)
        signaled deleted)
    (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
              ((symbol-function 'process-id) (lambda (_) 123))
              ((symbol-function 'signal-process)
               (lambda (pid signal) (setq signaled (list pid signal))))
              ((symbol-function 'delete-process)
               (lambda (process) (setq deleted process)))
              ((symbol-function 'set-process-sentinel) #'ignore)
              ((symbol-function 'process-buffer) (lambda (_) nil)))
      (emacsos-net--discard-reader)
      (should (equal signaled '(-123 SIGKILL)))
      (should (eq deleted 'live-reader))
      (should-not emacsos-net--proc))))

(ert-deftest test-net-discard-reaps-real-reader-descendant ()
  (let* ((directory (make-temp-file "test-net-reader-" t))
         (reader-directory (make-temp-file "test-net-reader-tmp-" t))
         (nmcli (expand-file-name "nmcli" directory))
         (pid-file (expand-file-name "child.pid" directory))
         (process-environment
          (cons (concat "TEST_NET_CHILD_PID=" pid-file)
                (cons (concat "PATH=" directory ":" (getenv "PATH"))
                      process-environment)))
         (buffer (generate-new-buffer " *test-net-real-reader*"))
         child-pid)
    (unwind-protect
        (progn
          (with-temp-file nmcli
            (insert "#!/bin/sh\nprintf '%s\\n' \"$$\" >\"$TEST_NET_CHILD_PID\"\nsleep 30\n"))
          (set-file-modes nmcli #o755)
          (setq emacsos-net--proc
                (make-process
                 :name "test-net-real-reader"
                 :buffer buffer
                 :command (list "/usr/bin/timeout" "-s" "TERM" "-k" "1" "8"
                                "sh" "-c"
                                (emacsos-net--reader-script)
                                "emacsos-net-read" emacsos-net-cell-connection
                                reader-directory
                                "/var/lib/emacsos-openrc-wifi-pending")
                 :noquery t))
          (process-put emacsos-net--proc 'emacsos-net-temp-directory
                       reader-directory)
          (let ((deadline (+ (float-time) 2)))
            (while (and (not (file-exists-p pid-file))
                        (< (float-time) deadline))
              (accept-process-output emacsos-net--proc 0.05)))
          (should (file-exists-p pid-file))
          (setq child-pid
                (string-to-number
                 (string-trim
                  (with-temp-buffer
                    (insert-file-contents pid-file)
                    (buffer-string)))))
          (emacsos-net--discard-reader)
          (let ((deadline (+ (float-time) 2)))
            (while (and (process-attributes child-pid)
                        (< (float-time) deadline))
              (sleep-for 0.05)))
          (should-not (process-attributes child-pid))
          (should-not (file-exists-p reader-directory)))
      (when emacsos-net--proc (emacsos-net--discard-reader))
      (when (buffer-live-p buffer) (kill-buffer buffer))
      (when (file-exists-p reader-directory)
        (delete-directory reader-directory t))
      (delete-directory directory t))))

(ert-deftest test-net-obsolete-reader-sentinel-keeps-replacement-guard ()
  (let ((emacsos-net--proc 'replacement-reader))
    (cl-letf (((symbol-function 'process-status) (lambda (_) 'exit))
              ((symbol-function 'process-buffer) (lambda (_) nil)))
      (emacsos-net--reader-sentinel 'obsolete-reader "finished")
      (should (eq emacsos-net--proc 'replacement-reader)))))

(ert-deftest test-net-failed-reader-retains-last-valid-state ()
  (let* ((old-state (make-emacsos-net-state :active-iface 'wifi :ssid "Old"))
         (emacsos-net--state old-state)
         (emacsos-net--proc 'reader)
         (buffer (generate-new-buffer " *test-net-failed-read*"))
         (renders 0))
    (with-current-buffer buffer (insert test-net--blob-none))
    (cl-letf (((symbol-function 'process-status) (lambda (_) 'exit))
              ((symbol-function 'process-exit-status) (lambda (_) 124))
              ((symbol-function 'process-buffer) (lambda (_) buffer))
              ((symbol-function 'process-get) (lambda (&rest _) nil))
              ((symbol-function 'emacsos-net--render-if-shown)
               (lambda () (cl-incf renders))))
      (emacsos-net--reader-sentinel 'reader "finished")
      (should-not emacsos-net--proc)
      (should-not (eq emacsos-net--state old-state))
      (should (eq (emacsos-net-state-active-iface emacsos-net--state) 'wifi))
      (should (equal (emacsos-net-state-ssid emacsos-net--state) "Old"))
      (should-not (emacsos-net-state-valid emacsos-net--state))
      (should (equal (emacsos-net-state-error emacsos-net--state)
                     "network reader exited 124"))
      (should (= renders 1))
      (should-not (buffer-live-p buffer)))))

(ert-deftest test-net-action-translator-failure-does-not-leak-buffer ()
  (let ((before (buffer-list))
        (emacsos-net-command-function (lambda (_) (error "rejected"))))
    (emacsos-net--action '("unsupported"))
    (should (equal (buffer-list) before))))

(provide 'test-network)
;;; test-network.el ends here
