#!/bin/sh

set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

docker run --rm --network none -i \
    -v "$repo_dir/deploy/pinephone/openrc-network-root:/helper:ro" \
    python:3.13-alpine /bin/sh -s <<'CONTAINER'
set -eu

ln -s /usr/local/bin/python3 /usr/bin/python3

printf '%s\n' '#!/bin/sh' \
    'printf "%s\n" "$*" >>/tmp/nmcli-log' \
    'if [ -f /tmp/nmcli-cell-up-fails ] && [ "$*" = "con up emacsos-cellular" ]; then' \
    '  exit 1' \
    'fi' \
    'case $* in' \
    '  "-g connection.type con show uuid 11111111-2222-3333-4444-555555555555")' \
    '    printf "%s\n" 802-11-wireless ;;' \
    '  "-g connection.type con show uuid aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")' \
    '    printf "%s\n" 802-3-ethernet ;;' \
    'esac' \
    >/usr/bin/nmcli
chmod 0755 /usr/bin/nmcli

printf '%s\n' '#!/bin/sh' \
    'if [ -f /tmp/mmcli-fails ]; then' \
    '  exit 1' \
    'elif [ -f /tmp/mmcli-times-out ]; then' \
    '  exit 137' \
    'elif [ -f /tmp/mmcli-unrecognized ]; then' \
    '  printf "%s\n" "unexpected modem output"' \
    'elif [ -f /tmp/mmcli-valid-mixed ]; then' \
    '  printf "%s\n" "/org/freedesktop/ModemManager1/Modem/0 [Quectel] EG25-G" "unexpected trailing output"' \
    'elif [ -f /tmp/mmcli-mixed ]; then' \
    '  printf "%s\n" "No modems were found" "unexpected trailing output"' \
    'elif [ -f /tmp/modem-missing ]; then' \
    '  printf "%s\n" "No modems were found"' \
    'else' \
    '  printf "%s\n" "/org/freedesktop/ModemManager1/Modem/0 [Quectel] EG25-G"' \
    'fi' \
    >/usr/bin/mmcli
chmod 0755 /usr/bin/mmcli

printf '%s\n' '#!/bin/sh' \
    'printf "%s\n" "$*" >>/tmp/rc-service-log' \
    'case $* in' \
    '  "modemmanager restart")' \
    '    if [ -f /tmp/restart-killed ]; then' \
    '      touch /tmp/modem-service-stopped' \
    '      exit 137' \
    '    fi' \
    '    [ ! -f /tmp/restart-fails ] || exit 1' \
    '    rm -f /tmp/modem-missing' \
    '    [ ! -f /tmp/restart-leaves-timeout ] || touch /tmp/mmcli-times-out ;;' \
    '  "modemmanager start") rm -f /tmp/modem-service-stopped ;;' \
    '  *) exit 64 ;;' \
    'esac' \
    >/sbin/rc-service
chmod 0755 /sbin/rc-service

/bin/sh /helper wifi off
/bin/sh /helper cell up
/bin/sh /helper saved 11111111-2222-3333-4444-555555555555
/bin/sh /helper open 'Cafe network'
/bin/sh /helper open "$(printf 'Caf\303\251')"
grep -Fx 'radio wifi off' /tmp/nmcli-log >/dev/null
grep -Fx 'con up emacsos-cellular' /tmp/nmcli-log >/dev/null
grep -Fx -- '-g connection.type con show uuid 11111111-2222-3333-4444-555555555555' /tmp/nmcli-log >/dev/null
grep -Fx 'con up uuid 11111111-2222-3333-4444-555555555555' /tmp/nmcli-log >/dev/null
grep -Fx 'dev wifi connect Cafe network' /tmp/nmcli-log >/dev/null
grep -Fx "dev wifi connect $(printf 'Caf\303\251')" /tmp/nmcli-log >/dev/null
[ ! -e /tmp/rc-service-log ]

touch /tmp/modem-missing
/bin/sh /helper cell down
[ ! -e /tmp/rc-service-log ]
/bin/sh /helper cell up
grep -Fx 'modemmanager restart' /tmp/rc-service-log >/dev/null
grep -Fx 'con down emacsos-cellular' /tmp/nmcli-log >/dev/null
[ "$(grep -Fxc 'con up emacsos-cellular' /tmp/nmcli-log)" -eq 2 ]

rm -f /tmp/rc-service-log
touch /tmp/mmcli-fails
if /bin/sh /helper cell up >/tmp/probe-failed 2>&1; then
    printf '%s\n' 'failed modem probe was accepted' >&2
    exit 1
fi
grep -Fx 'not-connected:failed' /tmp/probe-failed >/dev/null
[ ! -e /tmp/rc-service-log ]
rm -f /tmp/mmcli-fails

touch /tmp/mmcli-unrecognized
if /bin/sh /helper cell up >/tmp/probe-unrecognized 2>&1; then
    printf '%s\n' 'unrecognized modem probe was accepted' >&2
    exit 1
fi
grep -Fx 'not-connected:failed' /tmp/probe-unrecognized >/dev/null
[ ! -e /tmp/rc-service-log ]
rm -f /tmp/mmcli-unrecognized

touch /tmp/mmcli-mixed
if /bin/sh /helper cell up >/tmp/probe-mixed 2>&1; then
    printf '%s\n' 'mixed modem probe was accepted' >&2
    exit 1
fi
grep -Fx 'not-connected:failed' /tmp/probe-mixed >/dev/null
[ ! -e /tmp/rc-service-log ]
rm -f /tmp/mmcli-mixed

touch /tmp/mmcli-valid-mixed
if /bin/sh /helper cell up >/tmp/probe-valid-mixed 2>&1; then
    printf '%s\n' 'valid modem plus unrecognized output was accepted' >&2
    exit 1
fi
grep -Fx 'not-connected:failed' /tmp/probe-valid-mixed >/dev/null
[ ! -e /tmp/rc-service-log ]
rm -f /tmp/mmcli-valid-mixed

touch /tmp/modem-missing /tmp/restart-fails
if /bin/sh /helper cell up >/tmp/recovery-failed 2>&1; then
    printf '%s\n' 'failed ModemManager recovery was accepted' >&2
    exit 1
fi
grep -Fx 'not-connected:failed' /tmp/recovery-failed >/dev/null
grep -Fx 'modemmanager start' /tmp/rc-service-log >/dev/null
rm -f /tmp/modem-missing /tmp/restart-fails /tmp/rc-service-log

touch /tmp/modem-missing /tmp/restart-killed
if /bin/sh /helper cell up >/tmp/restart-killed-result 2>&1; then
    printf '%s\n' 'killed ModemManager restart was accepted' >&2
    exit 1
fi
grep -Fx 'unknown:time-limit' /tmp/restart-killed-result >/dev/null
grep -Fx 'modemmanager restart' /tmp/rc-service-log >/dev/null
grep -Fx 'modemmanager start' /tmp/rc-service-log >/dev/null
[ ! -e /tmp/modem-service-stopped ]
rm -f /tmp/modem-missing /tmp/restart-killed /tmp/rc-service-log

touch /tmp/modem-missing /tmp/nmcli-cell-up-fails
if /bin/sh /helper cell up >/tmp/activation-failed 2>&1; then
    printf '%s\n' 'failed cellular activation was accepted' >&2
    exit 1
fi
grep -Fx 'not-connected:failed' /tmp/activation-failed >/dev/null
grep -Fx 'modemmanager restart' /tmp/rc-service-log >/dev/null
grep -Fx 'modemmanager start' /tmp/rc-service-log >/dev/null
rm -f /tmp/nmcli-cell-up-fails /tmp/rc-service-log

printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" >>/tmp/sleep-log' \
    >/usr/bin/sleep
chmod 0755 /usr/bin/sleep
touch /tmp/modem-missing /tmp/restart-leaves-timeout
if /bin/sh /helper cell up >/tmp/post-restart-timeout 2>&1; then
    printf '%s\n' 'post-restart modem timeouts were accepted' >&2
    exit 1
fi
grep -Fx 'not-connected:failed' /tmp/post-restart-timeout >/dev/null
[ "$(wc -l </tmp/sleep-log)" -eq 9 ]
grep -Fx 'modemmanager start' /tmp/rc-service-log >/dev/null
rm -f /usr/bin/sleep /tmp/mmcli-times-out /tmp/restart-leaves-timeout \
    /tmp/rc-service-log /tmp/sleep-log

if /bin/sh /helper saved aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee >/tmp/rejected 2>&1; then
    printf '%s\n' 'saved non-Wi-Fi profile was accepted' >&2
    exit 1
fi
grep -Fx 'not-connected:failed' /tmp/rejected >/dev/null
if grep -Fx 'con up uuid aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee' /tmp/nmcli-log >/dev/null; then
    printf '%s\n' 'saved non-Wi-Fi profile was activated' >&2
    exit 1
fi

before=$(wc -l </tmp/nmcli-log)
for command in \
    '/bin/sh /helper wifi maybe' \
    '/bin/sh /helper wifi off extra' \
    '/bin/sh /helper cell erase' \
    '/bin/sh /helper saved' \
    '/bin/sh /helper saved not-a-uuid' \
    '/bin/sh /helper open a b' \
    '/bin/sh /helper shell'; do
    if sh -c "$command" >/tmp/rejected 2>&1; then
        printf 'unsafe command accepted: %s\n' "$command" >&2
        exit 1
    fi
    grep -E '^not-connected:|^unknown:' /tmp/rejected >/dev/null
done
bad_name=$(printf 'first\nsecond')
if /bin/sh /helper open "$bad_name" >/tmp/rejected 2>&1; then
    printf '%s\n' 'newline-bearing SSID was accepted' >&2
    exit 1
fi

for bad_name in \
    "$(printf 'Cafe\t')" \
    "$(printf 'Cafe\302\200')" \
    "$(printf 'Cafe\342\200\256')" \
    "$(printf 'Cafe\200')" \
    "$(printf 'Cafe\300\257')" \
    "$(printf 'Cafe\302')" \
    "$(printf 'Cafe\377')"; do
    if /bin/sh /helper open "$bad_name" >/tmp/rejected 2>&1; then
        printf '%s\n' 'invalid SSID was accepted' >&2
        exit 1
    fi
    grep -Fx 'not-connected:invalid-input' /tmp/rejected >/dev/null
done
[ "$(wc -l </tmp/nmcli-log)" -eq "$before" ]

flock /run/emacsos-openrc-network.lock sleep 2 &
holder=$!
sleep 0.1
if /bin/sh /helper wifi on >/tmp/locked 2>&1; then
    printf '%s\n' 'concurrent network mutation was accepted' >&2
    exit 1
fi
grep -Fx 'not-connected:busy' /tmp/locked >/dev/null
wait "$holder"

rm -f /usr/bin/timeout
printf '%s\n' '#!/bin/sh' 'exit 137' >/usr/bin/timeout
chmod 0755 /usr/bin/timeout
if /bin/sh /helper wifi on >/tmp/killed-timeout 2>&1; then
    printf '%s\n' 'killed timeout was accepted' >&2
    exit 1
fi
grep -Fx 'unknown:time-limit' /tmp/killed-timeout >/dev/null

rm -f /tmp/rc-service-log
if /bin/sh /helper cell up >/tmp/modem-killed-timeout 2>&1; then
    printf '%s\n' 'timed-out modem probe was accepted' >&2
    exit 1
fi
grep -Fx 'unknown:time-limit' /tmp/modem-killed-timeout >/dev/null
[ ! -e /tmp/rc-service-log ]

printf '%s\n' 'PinePhone network helper: OK'
CONTAINER
