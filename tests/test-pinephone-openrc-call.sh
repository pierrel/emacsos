#!/bin/sh

set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

docker run --rm --network none -i \
    -v "$repo_dir/deploy/pinephone/openrc-call-root:/helper:ro" \
    debian:stable-slim /bin/sh -s <<'CONTAINER'
set -eu

printf '%s\n' '#!/bin/sh' \
    'printf "%s\n" "$*" >>/tmp/mmcli-log' \
    'case " $* " in' \
    '  " -L ") printf "%s\n" "/org/freedesktop/ModemManager1/Modem/7" ;;' \
    '  *"--voice-create-call=number="*) printf "%s\n" "created /org/freedesktop/ModemManager1/Call/11" ;;' \
    '  *" --start ") [ ! -e /tmp/fail-start ] || { printf "%s\n" rejected >&2; exit 3; } ;;' \
    '  *" --accept ") ;;' \
    '  *" --voice-hangup-all ") ;;' \
    '  *" --hangup ") [ ! -e /tmp/fail-hangup ] || { printf "%s\n" cleanup-rejected >&2; exit 4; } ;;' \
    'esac' >/usr/bin/mmcli
chmod 0755 /usr/bin/mmcli
printf '%s\n' '#!/bin/sh' \
    'printf "%s\n" "$*" >>/tmp/gdbus-log' \
    'case " $* " in' \
    '  *" org.freedesktop.DBus.GetNameOwner "*) if [ -e /tmp/change-owner ] && [ -e /tmp/call-created ]; then printf "%s\n" ":1.99"; else printf "%s\n" ":1.42"; fi ;;' \
    '  *" org.freedesktop.ModemManager1.Modem.Voice.CreateCall "*) touch /tmp/call-created; printf "%s\n" "(objectpath '\''/org/freedesktop/ModemManager1/Call/11'\'',)" ;;' \
    '  *" org.freedesktop.ModemManager1.Call.Start "*) [ ! -e /tmp/fail-start-empty ] || exit 3; [ ! -e /tmp/fail-start ] || { printf "%s\n" rejected >&2; exit 3; } ;;' \
    '  *" org.freedesktop.ModemManager1.Call.Hangup "*) [ ! -e /tmp/fail-hangup-empty ] || exit 4; [ ! -e /tmp/fail-hangup ] || { printf "%s\n" cleanup-rejected >&2; exit 4; } ;;' \
    '  *" org.freedesktop.ModemManager1.Call.Accept "*) [ ! -e /tmp/fail-answer ] || { printf "%s\n" answer-rejected >&2; exit 5; } ;;' \
    'esac' >/usr/bin/gdbus
chmod 0755 /usr/bin/gdbus

dial_output=$(/bin/sh /helper dial :1.42 +14155550123)
[ "$(printf '%s\n' "$dial_output" | sed -n '1p')" = \
    'created-call-path: /org/freedesktop/ModemManager1/Call/11' ]
[ "$(printf '%s\n' "$dial_output" | sed -n '2p')" = \
    'dialing: /org/freedesktop/ModemManager1/Call/11' ]
grep -F -- "--dest :1.42 --object-path /org/freedesktop/ModemManager1/Modem/7 --method org.freedesktop.ModemManager1.Modem.Voice.CreateCall {'number': <'+14155550123'>}" /tmp/gdbus-log >/dev/null
grep -F -- '--dest :1.42 --object-path /org/freedesktop/ModemManager1/Call/11 --method org.freedesktop.ModemManager1.Call.Start' /tmp/gdbus-log >/dev/null

answer_output=$(/bin/sh /helper answer :1.42 /org/freedesktop/ModemManager1/Call/11)
[ "$(printf '%s\n' "$answer_output" | sed -n '1p')" = \
    'answering-call-path: /org/freedesktop/ModemManager1/Call/11' ]
[ "$(printf '%s\n' "$answer_output" | sed -n '2p')" = 'answered: call active' ]
grep -F -- '--dest :1.42 --object-path /org/freedesktop/ModemManager1/Call/11 --method org.freedesktop.ModemManager1.Call.Accept' /tmp/gdbus-log >/dev/null
[ "$(/bin/sh /helper hangup :1.42 /org/freedesktop/ModemManager1/Call/11)" = \
    'hung-up: call ended' ]
grep -F -- '--dest :1.42 --object-path /org/freedesktop/ModemManager1/Call/11 --method org.freedesktop.ModemManager1.Call.Hangup' /tmp/gdbus-log >/dev/null
[ "$(/bin/sh /helper hangup)" = 'hung-up: all calls ended' ]
mv /usr/bin/gdbus /usr/bin/gdbus.unavailable
[ "$(/bin/sh /helper hangup)" = 'hung-up: all calls ended' ]
mv /usr/bin/gdbus.unavailable /usr/bin/gdbus

before=$(wc -l </tmp/mmcli-log)
for command in \
    '/bin/sh /helper dial :1.42 Ana' \
    '/bin/sh /helper dial :1.42 1234' \
    '/bin/sh /helper dial invalid +14155550123' \
    '/bin/sh /helper answer :1.42 /org/freedesktop/ModemManager1/Call/1/../../x' \
    '/bin/sh /helper hangup :1.42 /org/freedesktop/ModemManager1/Call/1/../../x' \
    '/bin/sh /helper hangup extra' \
    '/bin/sh /helper shell'; do
    if sh -c "$command" >/tmp/rejected 2>&1; then
        printf 'unsafe command accepted: %s\n' "$command" >&2
        exit 1
    fi
    grep -F 'error:' /tmp/rejected >/dev/null
done
[ "$(wc -l </tmp/mmcli-log)" -eq "$before" ]

touch /tmp/fail-answer
if /bin/sh /helper answer :1.42 /org/freedesktop/ModemManager1/Call/11 \
        >/tmp/answer-uncertain 2>&1; then
    printf '%s\n' 'uncertain answer was accepted' >&2
    exit 1
fi
grep -Fx 'answering-call-path: /org/freedesktop/ModemManager1/Call/11' \
    /tmp/answer-uncertain >/dev/null
grep -Fx 'error: uncertain-answer-call-path=/org/freedesktop/ModemManager1/Call/11; could not confirm answer: answer-rejected ' \
    /tmp/answer-uncertain >/dev/null
rm -f /tmp/fail-answer

bad_number=$(printf '12345\n67890')
if /bin/sh /helper dial :1.42 "$bad_number" >/tmp/rejected 2>&1; then
    printf '%s\n' 'newline-bearing number was accepted' >&2
    exit 1
fi
bad_path=$(printf '/org/freedesktop/ModemManager1/Call/1\n2')
if /bin/sh /helper answer :1.42 "$bad_path" >/tmp/rejected 2>&1; then
    printf '%s\n' 'newline-bearing call path was accepted' >&2
    exit 1
fi
[ "$(wc -l </tmp/mmcli-log)" -eq "$before" ]

touch /tmp/fail-start
if /bin/sh /helper dial :1.42 +14155550123 >/tmp/start-failure 2>&1; then
    printf '%s\n' 'failed call start was accepted' >&2
    exit 1
fi
grep -Fx 'error: call-path=/org/freedesktop/ModemManager1/Call/11; could not start call: rejected ' \
    /tmp/start-failure >/dev/null
grep -F -- '--dest :1.42 --object-path /org/freedesktop/ModemManager1/Call/11 --method org.freedesktop.ModemManager1.Call.Hangup' \
    /tmp/gdbus-log >/dev/null
rm -f /tmp/fail-start

touch /tmp/fail-start /tmp/fail-hangup
if /bin/sh /helper dial :1.42 +14155550123 >/tmp/uncertain 2>&1; then
    printf '%s\n' 'uncertain call cleanup was accepted' >&2
    exit 1
fi
grep -Fx 'error: uncertain-call-path=/org/freedesktop/ModemManager1/Call/11; could not start call: rejected ; cleanup failed: cleanup-rejected ' \
    /tmp/uncertain >/dev/null
rm -f /tmp/fail-start /tmp/fail-hangup

touch /tmp/fail-start-empty /tmp/fail-hangup-empty
if /bin/sh /helper dial :1.42 +14155550123 >/tmp/empty-diagnostic 2>&1; then
    printf '%s\n' 'output-free call failure was accepted' >&2
    exit 1
fi
grep -Fx 'error: uncertain-call-path=/org/freedesktop/ModemManager1/Call/11; could not start call: gdbus exited 3; cleanup failed: gdbus exited 4' \
    /tmp/empty-diagnostic >/dev/null
rm -f /tmp/fail-start-empty /tmp/fail-hangup-empty

rm -f /tmp/call-created
touch /tmp/change-owner
if /bin/sh /helper dial :1.42 +14155550123 >/tmp/owner-changed 2>&1; then
    printf '%s\n' 'post-create owner change was accepted' >&2
    exit 1
fi
grep -Fx 'created-call-path: /org/freedesktop/ModemManager1/Call/11' \
    /tmp/owner-changed >/dev/null
grep -Fx 'error: call-path=/org/freedesktop/ModemManager1/Call/11; ModemManager owner changed' \
    /tmp/owner-changed >/dev/null
rm -f /tmp/change-owner /tmp/call-created

flock /run/emacsos-openrc-call.lock sleep 4 &
holder=$!
sleep 0.1
if /bin/sh /helper hangup >/tmp/locked 2>&1; then
    printf '%s\n' 'concurrent call mutation was accepted' >&2
    exit 1
fi
grep -F 'another call operation is running' /tmp/locked >/dev/null
wait "$holder"

printf '%s\n' 'PinePhone call helper: OK'
CONTAINER
