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
case $1 in
    -t)
        [ ! -e /tmp/nmcli-list-fail ] || exit 1
        [ ! -e /tmp/nmcli-list-hang ] || {
            printf '%s\n' "$$" >/tmp/nmcli-list-pid
            sleep 30
        }
        for profile in /tmp/profile-emacsos-wifi-attempt-*; do
            [ -e "$profile" ] || continue
            printf '%s:%s\n' "$(cat "$profile")" "${profile#/tmp/profile-}"
        done
        ;;
    --ask)
        shift
        profile_name=${6-}
        [ "$5" = name ] &&
            printf '%s\n' "$profile_name" | grep -E '^emacsos-wifi-attempt-[0-9a-f]{32}$' >/dev/null
        [ "$(find /tmp -maxdepth 1 -name 'profile-emacsos-wifi-attempt-*' | wc -l)" -eq 0 ]
        if [ ! -e /tmp/nmcli-no-profile ]; then
            profile_count=$(cat /tmp/profile-count 2>/dev/null || printf 0)
            profile_count=$((profile_count + 1))
            printf '%s\n' "$profile_count" >/tmp/profile-count
            printf '01234567-89ab-cdef-0123-%012x\n' "$profile_count" \
                >"/tmp/profile-$profile_name"
        fi
        IFS= read -r password
        printf '%s\n' "$password" >>/tmp/nmcli-stdin
        [ ! -e /tmp/nmcli-hang ] || {
            printf '%s\n' "$$" >/tmp/nmcli-pid
            sleep 30
        }
        [ ! -e /tmp/nmcli-fail ]
        ;;
    -g)
        profile_name=$6
        [ ! -e /tmp/nmcli-lookup-fail ] || exit 1
        [ -e "/tmp/profile-$profile_name" ] || exit 10
        cat "/tmp/profile-$profile_name"
        ;;
    con)
        case $2 in
            delete)
                [ "$3" = uuid ]
                [ ! -e /tmp/nmcli-delete-fail ] || exit 1
                shift 3
                for profile_uuid in "$@"; do
                    profile=$(grep -l -Fx "$profile_uuid" /tmp/profile-emacsos-wifi-attempt-*)
                    [ -n "$profile" ] && [ "$(printf '%s\n' "$profile" | wc -l)" -eq 1 ]
                    rm -f -- "$profile"
                done
                ;;
            modify)
                [ "$3" = uuid ] && [ "$5" = connection.id ]
                [ ! -e /tmp/nmcli-modify-fail ] || exit 1
                profile=$(grep -l -Fx "$4" /tmp/profile-emacsos-wifi-attempt-*)
                [ -n "$profile" ] && [ "$(printf '%s\n' "$profile" | wc -l)" -eq 1 ]
                rm -f -- "$profile"
                ;;
            *) exit 2 ;;
        esac
        ;;
    *) exit 2 ;;
esac
NMCLI
chmod 0755 /usr/bin/nmcli

valid_request='{"ssid":"Cafe network","password":"Exact password"}'
stale_name=emacsos-wifi-attempt-00000000000000000000000000000000
stale_uuid=fedcba98-7654-3210-fedc-ba9876543210
printf '%s\n' "$stale_uuid" >"/tmp/profile-$stale_name"
printf '%s' "$valid_request" | /usr/bin/python3 -I /helper >/tmp/result
grep -Fx connected /tmp/result >/dev/null
grep -Fx -- '-t -f UUID,NAME con show' /tmp/nmcli-argv >/dev/null
grep -Fx "con delete uuid $stale_uuid" /tmp/nmcli-argv >/dev/null
grep -E '^--ask dev wifi connect Cafe network name emacsos-wifi-attempt-[0-9a-f]{32}$' \
    /tmp/nmcli-argv >/dev/null
grep -Fx 'con modify uuid 01234567-89ab-cdef-0123-000000000001 connection.id Cafe network' \
    /tmp/nmcli-argv >/dev/null
grep -Fx 'Exact password' /tmp/nmcli-stdin >/dev/null
if grep -F 'Exact password' /tmp/nmcli-argv >/dev/null; then
    printf '%s\n' 'password leaked into nmcli argv' >&2
    exit 1
fi

printf '%s' '{"ssid":"Cafe;$(touch pwned)","password":"safe"}' | \
    /usr/bin/python3 -I /helper >/tmp/result
grep -Fx 'connected' /tmp/result >/dev/null
[ ! -e pwned ]
grep -E '^--ask dev wifi connect Cafe;\$\(touch pwned\) name emacsos-wifi-attempt-[0-9a-f]{32}$' \
    /tmp/nmcli-argv >/dev/null
grep -Fx 'con modify uuid 01234567-89ab-cdef-0123-000000000002 connection.id Cafe;$(touch pwned)' \
    /tmp/nmcli-argv >/dev/null

touch /tmp/nmcli-fail
if printf '%s' "$valid_request" | /usr/bin/python3 -I /helper >/tmp/result; then
    printf '%s\n' 'nmcli failure reported success' >&2
    exit 1
fi
grep -Fx 'not-connected:failed' /tmp/result >/dev/null
[ "$(find /tmp -maxdepth 1 -name 'profile-emacsos-wifi-attempt-*' | wc -l)" -eq 0 ]
grep -E '^-g UUID con show id emacsos-wifi-attempt-[0-9a-f]{32}$' \
    /tmp/nmcli-argv >/dev/null
grep -Fx 'con delete uuid 01234567-89ab-cdef-0123-000000000003' \
    /tmp/nmcli-argv >/dev/null
rm -f /tmp/nmcli-fail

printf '%s' "$valid_request" | /usr/bin/python3 -I /helper >/tmp/result
grep -Fx connected /tmp/result >/dev/null
[ "$(grep -c '^--ask dev wifi connect Cafe network name ' /tmp/nmcli-argv)" -eq 3 ]

touch /tmp/nmcli-fail /tmp/nmcli-no-profile
if printf '%s' "$valid_request" | /usr/bin/python3 -I /helper >/tmp/result; then
    printf '%s\n' 'nmcli failure without a profile reported success' >&2
    exit 1
fi
grep -Fx 'not-connected:failed' /tmp/result >/dev/null
rm -f /tmp/nmcli-no-profile

touch /tmp/nmcli-lookup-fail
if printf '%s' "$valid_request" | /usr/bin/python3 -I /helper >/tmp/result; then
    printf '%s\n' 'failed profile lookup reported success' >&2
    exit 1
fi
grep -Fx 'not-connected:unavailable' /tmp/result >/dev/null
rm -f /tmp/nmcli-lookup-fail /tmp/profile-emacsos-wifi-attempt-*

touch /tmp/nmcli-delete-fail
if printf '%s' "$valid_request" | /usr/bin/python3 -I /helper >/tmp/result; then
    printf '%s\n' 'failed profile cleanup reported success' >&2
    exit 1
fi
grep -Fx 'not-connected:unavailable' /tmp/result >/dev/null
rm -f /tmp/nmcli-fail /tmp/nmcli-delete-fail /tmp/profile-emacsos-wifi-attempt-* \
    /tmp/profile-count

touch /tmp/nmcli-modify-fail
if printf '%s' "$valid_request" | /usr/bin/python3 -I /helper >/tmp/result; then
    printf '%s\n' 'failed successful-profile publication reported success' >&2
    exit 1
fi
grep -Fx 'not-connected:unavailable' /tmp/result >/dev/null
[ "$(find /tmp -maxdepth 1 -name 'profile-emacsos-wifi-attempt-*' | wc -l)" -eq 1 ]
rm -f /tmp/nmcli-modify-fail /tmp/profile-emacsos-wifi-attempt-* /tmp/profile-count

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
grep -Fx 'not-connected:failed' /tmp/terminated-result >/dev/null
[ "$(find /tmp -maxdepth 1 -name 'profile-emacsos-wifi-attempt-*' | wc -l)" -eq 0 ]
rm -f /tmp/nmcli-hang
printf '%s' "$valid_request" | /usr/bin/python3 -I /helper >/tmp/result
grep -Fx connected /tmp/result >/dev/null

touch /tmp/nmcli-list-fail
if printf '%s' "$valid_request" | /usr/bin/python3 -I /helper >/tmp/result; then
    printf '%s\n' 'failed pending-profile listing reported success' >&2
    exit 1
fi
grep -Fx 'not-connected:unavailable' /tmp/result >/dev/null
rm -f /tmp/nmcli-list-fail

for profile_count in $(seq 1 65); do
    profile_name=$(printf 'emacsos-wifi-attempt-%032x' "$profile_count")
    printf 'fedcba98-7654-3210-fedc-%012x\n' "$profile_count" \
        >"/tmp/profile-$profile_name"
done
if printf '%s' "$valid_request" | /usr/bin/python3 -I /helper >/tmp/result; then
    printf '%s\n' 'unbounded pending-profile set was accepted' >&2
    exit 1
fi
grep -Fx 'not-connected:unavailable' /tmp/result >/dev/null
rm -f /tmp/profile-emacsos-wifi-attempt-*

ask_count=$(grep -c '^--ask ' /tmp/nmcli-argv)
touch /tmp/nmcli-list-hang
/usr/bin/python3 -I /helper </tmp/request >/tmp/terminated-before-connect &
helper=$!
while [ ! -s /tmp/nmcli-list-pid ]; do sleep 0.01; done
kill -TERM "$helper"
if wait "$helper"; then
    printf '%s\n' 'terminated preflight helper reported success' >&2
    exit 1
fi
grep -Fx 'not-connected:unavailable' /tmp/terminated-before-connect >/dev/null
[ "$(grep -c '^--ask ' /tmp/nmcli-argv)" -eq "$ask_count" ]
rm -f /tmp/nmcli-list-pid

/usr/bin/python3 -I /helper </tmp/request >/tmp/killed-during-preflight &
helper=$!
while [ ! -s /tmp/nmcli-list-pid ]; do sleep 0.01; done
nmcli_pid=$(cat /tmp/nmcli-list-pid)
kill -KILL "$helper"
wait "$helper" 2>/dev/null || true
if printf '%s' "$valid_request" | /usr/bin/python3 -I /helper >/tmp/result; then
    printf '%s\n' 'orphaned NetworkManager child released the mutation lock' >&2
    exit 1
fi
grep -Fx 'not-connected:busy' /tmp/result >/dev/null
/usr/bin/python3 - "$nmcli_pid" <<'PY'
import os
import signal
import sys
os.killpg(int(sys.argv[1]), signal.SIGKILL)
PY
rm -f /tmp/nmcli-list-hang /tmp/nmcli-list-pid

printf '%s\n' 'PinePhone Wi-Fi credential helper: OK'
CONTAINER
