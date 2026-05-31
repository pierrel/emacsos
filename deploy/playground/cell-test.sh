#!/usr/bin/env bash
# cell-test.sh — bot-friendly cellular cutover test.  Deactivating the wifi
# connection in the middle severs the server->phone path, so the bot must
# launch this DETACHED (nohup ... &), wait ~30s for the full cycle, then
# read the log.
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
{
  echo "=== cell-test.sh started: $(date -Is) ==="
  echo
  # Safety: the bot's eval_elisp call backgrounded us via `&` and the
  # response packet is still in flight back to the home server over wifi.
  # Sleep before dropping wifi so the response is guaranteed flushed.
  echo "(holding 3s so the bot's eval_elisp response can flush back over wifi)"
  sleep 3
  echo
  echo "--- step 1: deactivate the wifi connection ---"
  sudo nmcli connection down preconfigured && echo "wifi down: OK" || echo "wifi down: FAILED"
  sleep 3   # let NM re-point the default route via wwan0
  echo
  echo "--- step 2: validate over cellular ---"
  bash ~/playground/cell-validate.sh
  v=$?
  echo "(cell-validate exit code: $v)"
  echo
  echo "--- step 3: reactivate the wifi connection ---"
  sudo nmcli connection up preconfigured && echo "wifi up: OK" || echo "wifi up: FAILED"
  sleep 5   # let wifi re-associate
  echo
  echo "=== cell-test.sh finished: $(date -Is) ==="
} > "$LOG" 2>&1
