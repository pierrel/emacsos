#!/bin/sh

set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

docker run --rm --network none -i \
    -v "$repo_dir/deploy/pinephone/openrc-network-root:/helper:ro" \
    debian:stable-slim /bin/sh -s <<'CONTAINER'
set -eu

printf '%s\n' '#!/bin/sh' \
    'printf "%s\n" "$*" >>/tmp/nmcli-log' \
    'case $* in' \
    '  "-g connection.type con show id Home network")' \
    '    printf "%s\n" 802-11-wireless ;;' \
    '  "-g connection.type con show id Wired profile")' \
    '    printf "%s\n" 802-3-ethernet ;;' \
    'esac' \
    >/usr/bin/nmcli
chmod 0755 /usr/bin/nmcli

/bin/sh /helper wifi off
/bin/sh /helper cell up
/bin/sh /helper saved 'Home network'
/bin/sh /helper open 'Cafe network'
grep -Fx 'radio wifi off' /tmp/nmcli-log >/dev/null
grep -Fx 'con up emacsos-cellular' /tmp/nmcli-log >/dev/null
grep -Fx -- '-g connection.type con show id Home network' /tmp/nmcli-log >/dev/null
grep -Fx 'con up id Home network' /tmp/nmcli-log >/dev/null
grep -Fx 'dev wifi connect Cafe network' /tmp/nmcli-log >/dev/null

if /bin/sh /helper saved 'Wired profile' >/tmp/rejected 2>&1; then
    printf '%s\n' 'saved non-Wi-Fi profile was accepted' >&2
    exit 1
fi
grep -F 'error: saved connection is not Wi-Fi' /tmp/rejected >/dev/null
if grep -Fx 'con up id Wired profile' /tmp/nmcli-log >/dev/null; then
    printf '%s\n' 'saved non-Wi-Fi profile was activated' >&2
    exit 1
fi

before=$(wc -l </tmp/nmcli-log)
for command in \
    '/bin/sh /helper wifi maybe' \
    '/bin/sh /helper wifi off extra' \
    '/bin/sh /helper cell erase' \
    '/bin/sh /helper saved' \
    '/bin/sh /helper open a b' \
    '/bin/sh /helper shell'; do
    if sh -c "$command" >/tmp/rejected 2>&1; then
        printf 'unsafe command accepted: %s\n' "$command" >&2
        exit 1
    fi
    grep -F 'error:' /tmp/rejected >/dev/null
done
bad_name=$(printf 'first\nsecond')
if /bin/sh /helper open "$bad_name" >/tmp/rejected 2>&1; then
    printf '%s\n' 'newline-bearing SSID was accepted' >&2
    exit 1
fi
[ "$(wc -l </tmp/nmcli-log)" -eq "$before" ]

flock /run/emacsos-openrc-network.lock sleep 2 &
holder=$!
sleep 0.1
if /bin/sh /helper wifi on >/tmp/locked 2>&1; then
    printf '%s\n' 'concurrent network mutation was accepted' >&2
    exit 1
fi
grep -F 'another network operation is running' /tmp/locked >/dev/null
wait "$holder"

printf '%s\n' 'PinePhone network helper: OK'
CONTAINER
