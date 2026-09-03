;;; test-network.el --- Tests for network.el status/control -*- lexical-binding: t -*-

;; Covers the PURE pieces of the network surface: the terse-line splitter
;; (escaped colons/backslashes), the mmcli key=value splitter, the blob
;; parser (-> `emacos-net-state'), the modeline formatter + tap props, the
;; connect-kind seam, the dynamic command set, the page render, and the
;; single-flight refresh guard.  Real nmcli/mmcli execution, the radio
;; toggles, and the modeline tap are validated on the live phone, not here.
;;
;; Fixtures use placeholder SSIDs and IP-free route lines (the parser only
;; reads `dev wl*' / `dev ww*'), per the no-operator-values rule.

(require 'ert)
(require 'cl-lib)
(require 'os)  ; pulls in network.el + emacos--btn for the render test

;;; Sample reader blobs

(defconst test-net--blob-wifi
  (concat "@@RADIO\nenabled\n"
          "@@ROUTE\ndefault dev wlan0 scope global metric 600\n"
          "@@CONS\nHomeNet:802-11-wireless\nemacsos-cellular:gsm\n"
          "@@WIFI\nyes:HomeNet:82:WPA2\nno:CoffeeShop:54:WPA2\nno:OpenNet:40:\n"
          "@@CELL\nmodem.generic.state : registered\n"
          "modem.generic.signal-quality.value : 60\n@@END\n")
  "Wifi is the active interface; cell is provisioned.")

(defconst test-net--blob-cell
  (concat "@@RADIO\ndisabled\n"
          "@@ROUTE\ndefault dev wwan0 scope global metric 700\n"
          "@@CONS\nemacsos-cellular:gsm\n"
          "@@WIFI\n"
          "@@CELL\nmodem.generic.state : connected\n"
          "modem.generic.signal-quality.value : 45\n@@END\n")
  "Cell is the active interface; wifi radio off.")

(defconst test-net--blob-none
  (concat "@@RADIO\nenabled\n"
          "@@ROUTE\n"
          "@@CONS\nSomeWifi:802-11-wireless\n"
          "@@WIFI\nno:SomeWifi:30:WPA2\n"
          "@@CELL\n@@END\n")
  "No default route; cell not provisioned.")

;;; Terse splitting

(ert-deftest test-net-split-plain ()
  (should (equal (emacos-net--split-terse "yes:HomeNet:82:WPA2")
                 '("yes" "HomeNet" "82" "WPA2"))))

(ert-deftest test-net-split-escaped-colon ()
  ;; literal: no:My\:SSID:40  — the \: is one colon inside the SSID
  (should (equal (emacos-net--split-terse "no:My\\:SSID:40")
                 '("no" "My:SSID" "40"))))

(ert-deftest test-net-split-escaped-backslash ()
  ;; literal: a\\b:c  — \\ is one backslash inside the value
  (should (equal (emacos-net--split-terse "a\\\\b:c")
                 '("a\\b" "c"))))

(ert-deftest test-net-kv-splits ()
  (should (equal (emacos-net--split-terse-kv
                  "modem.generic.state               : registered")
                 '("modem.generic.state" . "registered"))))

(ert-deftest test-net-kv-no-separator-is-nil ()
  (should (null (emacos-net--split-terse-kv "no separator here"))))

;;; Blob parsing

(ert-deftest test-net-parse-wifi-active ()
  (let ((st (emacos-net--parse test-net--blob-wifi)))
    (should (eq (emacos-net-state-active-iface st) 'wifi))
    (should (eq (emacos-net-state-wifi-on st) t))
    (should (equal (emacos-net-state-ssid st) "HomeNet"))
    (should (= (emacos-net-state-signal st) 82))
    (should (emacos-net-state-cell-provisioned st))
    (should (= (length (emacos-net-state-wifi-list st)) 3))))

(ert-deftest test-net-cell-profile-is-configurable ()
  (let ((emacos-net-cell-connection "carrier-profile"))
    (should
     (emacos-net-state-cell-provisioned
      (emacos-net--parse
       (concat "@@RADIO\nenabled\n@@ROUTE\n@@CONS\n"
               "carrier-profile:gsm\n@@WIFI\n@@CELL\n@@END\n"))))))

(ert-deftest test-net-reader-route-command-is-busybox-compatible ()
  (let ((script (emacos-net--reader-script)))
    (should (string-match-p "ip -4 route show default" script))
    (should-not (string-match-p "ip -o -4" script))))

(ert-deftest test-net-parse-cell-active ()
  (let ((st (emacos-net--parse test-net--blob-cell)))
    (should (eq (emacos-net-state-active-iface st) 'cell))
    (should (null (emacos-net-state-wifi-on st)))
    (should (= (emacos-net-state-signal st) 45))
    (should (equal (emacos-net-state-cell-state st) "connected"))
    (should (emacos-net-state-cell-provisioned st))))

(ert-deftest test-net-parse-no-net-unprovisioned ()
  (let ((st (emacos-net--parse test-net--blob-none)))
    (should (eq (emacos-net-state-active-iface st) 'none))
    (should (null (emacos-net-state-signal st)))
    (should (null (emacos-net-state-cell-provisioned st)))
    (should (= (length (emacos-net-state-wifi-list st)) 1))))

;;; connect-kind seam

(ert-deftest test-net-connect-kind ()
  (should (eq (emacos-net--connect-kind '(:ssid "A" :saved t :security "WPA2")) 'saved))
  (should (eq (emacos-net--connect-kind '(:ssid "B" :saved nil :security ""))   'open))
  (should (eq (emacos-net--connect-kind '(:ssid "C" :saved nil :security nil))  'open))
  (should (eq (emacos-net--connect-kind '(:ssid "D" :saved nil :security "WPA2"))
              'needs-password)))

(ert-deftest test-net-parse-classifies-list ()
  (let* ((st (emacos-net--parse test-net--blob-wifi))
         (by (lambda (s) (seq-find (lambda (n) (string= (plist-get n :ssid) s))
                                   (emacos-net-state-wifi-list st)))))
    (should (eq (emacos-net--connect-kind (funcall by "HomeNet")) 'saved))
    (should (eq (emacos-net--connect-kind (funcall by "OpenNet")) 'open))
    (should (eq (emacos-net--connect-kind (funcall by "CoffeeShop")) 'needs-password))))

;;; Modeline formatter

(ert-deftest test-net-segment-text ()
  (should (equal (emacos-net--segment-text
                  (make-emacos-net-state :active-iface 'wifi :signal 82)) "wifi 82%"))
  (should (equal (emacos-net--segment-text
                  (make-emacos-net-state :active-iface 'cell :signal 45)) "lte 45%"))
  (should (equal (emacos-net--segment-text
                  (make-emacos-net-state :active-iface 'none)) "no net")))

(ert-deftest test-net-mode-line-string-is-tappable ()
  (let* ((emacos-net--state (make-emacos-net-state :active-iface 'wifi :signal 82))
         (s (emacos-net-mode-line-string)))
    (should (equal (substring-no-properties s) "wifi 82%"))
    (should (get-text-property 0 'local-map s))
    (should (eq (get-text-property 0 'mouse-face s) 'mode-line-highlight))))

;;; Dynamic command set

(ert-deftest test-net-command-set-flips-with-state ()
  (let ((emacos-net--state
         (make-emacos-net-state :wifi-on t :active-iface 'cell :cell-provisioned t)))
    (should (assoc "Wifi off" (emacos-net--command-set)))
    (should (assoc "Cell off" (emacos-net--command-set))))
  (let ((emacos-net--state
         (make-emacos-net-state :wifi-on nil :active-iface 'none :cell-provisioned t)))
    (should (assoc "Wifi on" (emacos-net--command-set)))
    (should (assoc "Cell on" (emacos-net--command-set)))))

(ert-deftest test-net-command-set-entries-are-interactive ()
  "Command-band entries run via `emacos--run-command' -> `call-interactively',
so each must be `commandp' or the keyboard band errors on tap."
  (dolist (entry (emacos-net--command-set))
    (should (commandp (cdr entry)))))

;;; Page render

(ert-deftest test-net-render-shows-toggles-list-and-note ()
  (let ((emacos-net--state (emacos-net--parse test-net--blob-wifi)))
    (unwind-protect
        (let ((s (with-current-buffer (emacos-net--render) (buffer-string))))
          (should (string-match-p "Wifi off" s))   ; wifi on -> toggle says "off"
          (should (string-match-p "HomeNet" s))     ; the active network
          (should (string-match-p "OpenNet" s))     ; an open network
          ;; a new secured network present -> the deferral note shows
          (should (string-match-p "credential entry" s)))
      (when (get-buffer emacos-net--buffer-name)
        (kill-buffer emacos-net--buffer-name)))))

(ert-deftest test-net-render-unprovisioned-cell-has-no-toggle ()
  (let ((emacos-net--state (emacos-net--parse test-net--blob-none)))
    (unwind-protect
        (let ((s (with-current-buffer (emacos-net--render) (buffer-string))))
          (should (string-match-p "not set up" s)))
      (when (get-buffer emacos-net--buffer-name)
        (kill-buffer emacos-net--buffer-name)))))

;;; Single-flight refresh guard

(ert-deftest test-net-refresh-noop-when-reader-live ()
  (let ((emacos-net--proc 'fake)
        (spawned nil))
    (cl-letf (((symbol-function 'process-live-p) (lambda (_) t))
              ((symbol-function 'make-process)
               (lambda (&rest _) (setq spawned t) 'p)))
      (emacos-net--refresh)
      (should-not spawned))))

(ert-deftest test-net-action-translator-failure-does-not-leak-buffer ()
  (let ((before (buffer-list))
        (emacos-net-command-function (lambda (_) (error "rejected"))))
    (emacos-net--action '("unsupported"))
    (should (equal (buffer-list) before))))

(provide 'test-network)
;;; test-network.el ends here
