#!/usr/bin/env bash
# cell-test.sh — bot-friendly cellular cutover test.  Launch it detached
# (nohup ... &), wait ~30s for the full cycle, then read the log.
#
# How the bot uses it (see ~/playground/cellular.md for the elisp form):
#   1. (shell-command-to-string
#         "nohup bash ~/playground/cell-test.sh > /dev/null 2>&1 < /dev/null &")
#   2. wait ~30s
#   3. (shell-command-to-string "cat ~/playground/cell-test.out")
#
# Uses `nmcli connection down/up preconfigured` (NOT `radio wifi off/on`):
# `radio wifi off/on` uses rfkill, and systemd-rfkill PERSISTS the blocked
# state across reboots — a phone rebooted mid-cycle (or after an aborted
# run) would come back with wifi soft-blocked and unreachable. `connection
# down` has no such persistence; reboot recovers cleanly via the
# preconfigured wifi's autoconnect.

set -u
LOG=~/playground/cell-test.out
wifi_down=0
recovery_pid=

arm_recovery() {
  command -v setsid >/dev/null 2>&1 || return 1
  setsid sh -c 'sleep 30; sudo -n nmcli connection up preconfigured' \
    </dev/null >/dev/null 2>&1 &
  recovery_pid=$!
  kill -0 "$recovery_pid"
}

disarm_recovery() {
  if [ -n "$recovery_pid" ]; then
    kill "$recovery_pid" 2>/dev/null || true
    wait "$recovery_pid" 2>/dev/null || true
    recovery_pid=
  fi
}

restore_wifi() {
  if (( wifi_down == 1 )); then
    if sudo nmcli connection up preconfigured; then
      wifi_down=0
      disarm_recovery
    fi
  fi
}

trap restore_wifi EXIT
trap 'exit 1' HUP INT TERM
exec > "$LOG" 2>&1

echo "=== cell-test.sh started: $(date -Is) ==="
echo
# Safety: the bot's eval_elisp call backgrounded us via `&` and the
# response packet is still in flight back to the home server over wifi.
# Give that response time to flush before dropping wifi.
echo "(holding 3s so the bot's eval_elisp response can flush back over wifi)"
sleep 3
echo
echo "--- step 1: activate the cellular fallback ---"
if ! sudo nmcli connection up emacsos-cellular; then
  echo "cell up: FAILED"
  echo "=== cell-test.sh finished: $(date -Is) ==="
  exit 1
fi
echo "cell up: OK"
echo
echo "--- step 2: deactivate the wifi connection ---"
if ! arm_recovery; then
  echo "timed wifi recovery: FAILED"
  exit 1
fi
echo "timed wifi recovery: ARMED"
wifi_down=1
if sudo nmcli connection down preconfigured; then
  echo "wifi down: OK"
else
  echo "wifi down: FAILED"
  exit 1
fi
sleep 3   # let NM re-point the default route via wwan0
echo
echo "--- step 3: validate over cellular ---"
bash ~/playground/cell-validate.sh
v=$?
echo "(cell-validate exit code: $v)"
echo
echo "--- step 4: reactivate the wifi connection ---"
if sudo nmcli connection up preconfigured; then
  wifi_down=0
  disarm_recovery
  echo "wifi up: OK"
else
  echo "wifi up: FAILED"
fi
sleep 5   # let wifi re-associate
echo
echo "=== cell-test.sh finished: $(date -Is) ==="
