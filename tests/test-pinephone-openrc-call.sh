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
    '  *" --hangup ") ;;' \
    'esac' >/usr/bin/mmcli
chmod 0755 /usr/bin/mmcli

[ "$(/bin/sh /helper dial +14155550123)" = \
    'dialing: /org/freedesktop/ModemManager1/Call/11' ]
grep -Fx -- '-m 7 --voice-create-call=number=+14155550123' /tmp/mmcli-log >/dev/null
grep -Fx -- '-o /org/freedesktop/ModemManager1/Call/11 --start' /tmp/mmcli-log >/dev/null

[ "$(/bin/sh /helper answer /org/freedesktop/ModemManager1/Call/11)" = \
    'answered: call active' ]
grep -Fx -- '-o /org/freedesktop/ModemManager1/Call/11 --accept' /tmp/mmcli-log >/dev/null
[ "$(/bin/sh /helper hangup)" = 'hung-up: all calls ended' ]

before=$(wc -l </tmp/mmcli-log)
for command in \
    '/bin/sh /helper dial Ana' \
    '/bin/sh /helper dial 1234' \
    '/bin/sh /helper dial +14155550123 extra' \
    '/bin/sh /helper answer /org/freedesktop/ModemManager1/Call/1/../../x' \
    '/bin/sh /helper hangup extra' \
    '/bin/sh /helper shell'; do
    if sh -c "$command" >/tmp/rejected 2>&1; then
        printf 'unsafe command accepted: %s\n' "$command" >&2
        exit 1
    fi
    grep -F 'error:' /tmp/rejected >/dev/null
done
[ "$(wc -l </tmp/mmcli-log)" -eq "$before" ]

bad_number=$(printf '12345\n67890')
if /bin/sh /helper dial "$bad_number" >/tmp/rejected 2>&1; then
    printf '%s\n' 'newline-bearing number was accepted' >&2
    exit 1
fi
bad_path=$(printf '/org/freedesktop/ModemManager1/Call/1\n2')
if /bin/sh /helper answer "$bad_path" >/tmp/rejected 2>&1; then
    printf '%s\n' 'newline-bearing call path was accepted' >&2
    exit 1
fi
[ "$(wc -l </tmp/mmcli-log)" -eq "$before" ]

touch /tmp/fail-start
if /bin/sh /helper dial +14155550123 >/tmp/start-failure 2>&1; then
    printf '%s\n' 'failed call start was accepted' >&2
    exit 1
fi
grep -F 'could not start call: rejected' /tmp/start-failure >/dev/null
grep -Fx -- '-o /org/freedesktop/ModemManager1/Call/11 --hangup' \
    /tmp/mmcli-log >/dev/null
rm -f /tmp/fail-start

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
