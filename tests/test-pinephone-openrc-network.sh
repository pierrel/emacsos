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
    'case $* in' \
    '  "-g connection.type con show uuid 11111111-2222-3333-4444-555555555555")' \
    '    printf "%s\n" 802-11-wireless ;;' \
    '  "-g connection.type con show uuid aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")' \
    '    printf "%s\n" 802-3-ethernet ;;' \
    'esac' \
    >/usr/bin/nmcli
chmod 0755 /usr/bin/nmcli

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

printf '%s\n' 'PinePhone network helper: OK'
CONTAINER
