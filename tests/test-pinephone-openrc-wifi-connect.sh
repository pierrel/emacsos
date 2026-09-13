#!/bin/sh

set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

docker run --rm --network none -i \
    -v "$repo_dir/deploy/pinephone/openrc-wifi-connect-root:/helper:ro" \
    python:3.13-alpine /bin/sh -s <<'CONTAINER'
set -eu

ln -s /usr/local/bin/python3 /usr/bin/python3

cat >/usr/bin/nmcli <<'NMCLI'
#!/bin/sh
printf '%s\n' "$*" >>/tmp/nmcli-argv
IFS= read -r password
printf '%s\n' "$password" >>/tmp/nmcli-stdin
[ ! -e /tmp/nmcli-hang ] || {
    printf '%s\n' "$$" >/tmp/nmcli-pid
    sleep 30
}
[ ! -e /tmp/nmcli-fail ]
NMCLI
chmod 0755 /usr/bin/nmcli

valid_request='{"ssid":"Cafe network","password":"Exact password"}'
printf '%s' "$valid_request" | /usr/bin/python3 -I /helper >/tmp/result
grep -Fx connected /tmp/result >/dev/null
grep -Fx -- '--ask dev wifi connect Cafe network' /tmp/nmcli-argv >/dev/null
grep -Fx 'Exact password' /tmp/nmcli-stdin >/dev/null
if grep -F 'Exact password' /tmp/nmcli-argv >/dev/null; then
    printf '%s\n' 'password leaked into nmcli argv' >&2
    exit 1
fi

printf '%s' '{"ssid":"Cafe;$(touch pwned)","password":"safe"}' | \
    /usr/bin/python3 -I /helper >/tmp/result
grep -Fx 'connected' /tmp/result >/dev/null
[ ! -e pwned ]
grep -Fx -- '--ask dev wifi connect Cafe;$(touch pwned)' \
    /tmp/nmcli-argv >/dev/null

touch /tmp/nmcli-fail
if printf '%s' "$valid_request" | /usr/bin/python3 -I /helper >/tmp/result; then
    printf '%s\n' 'nmcli failure reported success' >&2
    exit 1
fi
grep -Fx 'not-connected:failed' /tmp/result >/dev/null
rm -f /tmp/nmcli-fail

for request in \
    '{}' \
    '{"ssid":"Cafe network","password":""}' \
    '{"ssid":"Cafe\tnetwork","password":"secret"}' \
    '{"ssid":"Cafe\u0080network","password":"secret"}' \
    '{"ssid":"Cafe\u202enetwork","password":"secret"}' \
    '{"ssid":"Cafe\nnetwork","password":"secret"}' \
    '{"ssid":"Cafe network","password":"bad\nsecret"}' \
    '{"ssid":"123456789012345678901234567890123","password":"secret"}' \
    '{"ssid":"Cafe network","password":"secret","extra":true}' \
    'not-json'; do
    if printf '%s' "$request" | /usr/bin/python3 -I /helper >/tmp/result; then
        printf 'invalid request accepted: %s\n' "$request" >&2
        exit 1
    fi
    grep -Fx 'not-connected:invalid-input' /tmp/result >/dev/null
done

if head -c 1025 /dev/zero | /usr/bin/python3 -I /helper >/tmp/result; then
    printf '%s\n' 'oversized request was accepted' >&2
    exit 1
fi
grep -Fx 'not-connected:invalid-input' /tmp/result >/dev/null

if printf '%s' "$valid_request" | /usr/bin/python3 -I /helper extra >/tmp/result; then
    printf '%s\n' 'helper accepted argv' >&2
    exit 1
fi
grep -Fx 'not-connected:invalid-input' /tmp/result >/dev/null

{ sleep 1; printf '%s' "$valid_request"; } | \
    /usr/bin/python3 -I /helper >/tmp/slow-result &
slow_reader=$!
sleep 0.1
if printf '%s' "$valid_request" | /usr/bin/python3 -I /helper >/tmp/result; then
    printf '%s\n' 'concurrent slow input was accepted' >&2
    exit 1
fi
grep -Fx 'not-connected:busy' /tmp/result >/dev/null
wait "$slow_reader"
grep -Fx connected /tmp/slow-result >/dev/null

/usr/bin/python3 - <<'PY' &
import fcntl
import time
with open("/run/emacsos-openrc-network.lock", "a+b") as lock:
    fcntl.flock(lock, fcntl.LOCK_EX)
    time.sleep(2)
PY
holder=$!
sleep 0.1
if printf '%s' '{"ssid":"Cafe network","password":"secret"}' | \
        /usr/bin/python3 -I /helper >/tmp/result; then
    printf '%s\n' 'concurrent network mutation was accepted' >&2
    exit 1
fi
grep -Fx 'not-connected:busy' /tmp/result >/dev/null
wait "$holder"

touch /tmp/nmcli-hang
printf '%s' "$valid_request" >/tmp/request
/usr/bin/python3 -I /helper </tmp/request >/tmp/terminated-result &
helper=$!
sleep 0.2
nmcli_pid=$(cat /tmp/nmcli-pid)
kill -TERM "$helper"
if wait "$helper"; then
    printf '%s\n' 'terminated helper reported success' >&2
    exit 1
fi
if kill -0 "$nmcli_pid" 2>/dev/null; then
    printf '%s\n' 'terminated helper left nmcli running' >&2
    exit 1
fi
rm -f /tmp/nmcli-hang
printf '%s' "$valid_request" | /usr/bin/python3 -I /helper >/tmp/result
grep -Fx connected /tmp/result >/dev/null

printf '%s\n' 'PinePhone Wi-Fi credential helper: OK'
CONTAINER
