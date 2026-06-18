#!/usr/bin/env bash
# place_call.sh <+E164-number> — place a voice call via the SIM7600 modem.
#
# Runs ON THE PHONE (mmcli lives there). The call skill invokes this through
# eval_elisp, e.g.  (shell-command-to-string "bash ~/.emacs.d/emacsos/place_call.sh '+15551230001'")
#
# Encapsulates the validated dial recipe + its one hard pitfall: mmcli
# SEGFAULTS on a truncated call object path, so we extract and pass the FULL
# /org/.../Call/N path from --voice-create-call's output, never reconstruct it.
# See docs/2026-06-18-call-audio.org.
#
# Prints exactly one line:  "dialing: <call-path>"  on success, or
# "error: <reason>" on failure. Exit 0 only on a successful dial.
set -uo pipefail

num="${1:-}"
[ -n "$num" ] || { echo "error: usage: place_call.sh <+E164>"; exit 2; }
# Accept an optional leading + then 5-15 digits; reject anything else so a
# stray name/letter can never reach mmcli.
if ! printf '%s' "$num" | grep -qE '^\+?[0-9]{5,15}$'; then
  echo "error: invalid number: $num"; exit 2
fi

# mmcli call control needs root via polkit when there is no login session
# (we run under the emacs daemon). Use passwordless sudo if available.
run() { if sudo -n true 2>/dev/null; then sudo "$@"; else "$@"; fi; }

m=$(mmcli -L 2>/dev/null | grep -oE '/Modem/[0-9]+' | head -1 | grep -oE '[0-9]+$')
[ -n "$m" ] || { echo "error: no modem found"; exit 3; }

create=$(run mmcli -m "$m" --voice-create-call="number=$num" 2>&1)
path=$(printf '%s' "$create" | grep -oE '/org/freedesktop/ModemManager1/Call/[0-9]+' | head -1)
[ -n "$path" ] || { echo "error: could not create call: $create"; exit 4; }

if ! run mmcli -o "$path" --start >/dev/null 2>&1; then
  run mmcli -o "$path" --hangup >/dev/null 2>&1
  echo "error: dial failed (modem not registered?) for $path"; exit 5
fi

echo "dialing: $path"
