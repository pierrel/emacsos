#!/usr/bin/env bash
# hangup.sh — end the current voice call via the SIM7600 modem.
# Runs ON THE PHONE; invoked by the call skill through eval_elisp.
# v1 hangs up ALL calls (only one call at a time today). Prints "hung-up:"
# or "error: <reason>".
set -uo pipefail
run() { if sudo -n true 2>/dev/null; then sudo "$@"; else "$@"; fi; }
m=$(mmcli -L 2>/dev/null | grep -oE '/Modem/[0-9]+' | head -1 | grep -oE '[0-9]+$')
[ -n "$m" ] || { echo "error: no modem found"; exit 3; }
if run mmcli -m "$m" --voice-hangup-all >/dev/null 2>&1; then
  echo "hung-up: all calls ended"
else
  echo "error: hangup failed"; exit 5
fi
