#!/bin/sh

set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

source_dir=${POWER_TEST_SOURCE_DIR:-$repo_dir/deploy/pinephone}

docker run --rm --network none --cap-add BLOCK_SUSPEND --cap-add SYS_PTRACE -i \
    -v "$source_dir/openrc-session-power:/source/session-power:ro" \
    -v "$source_dir/openrc-suspend-root:/source/suspend-root:ro" \
    -v "$source_dir/openrc-process-group:/source/process-group:ro" \
    python:3.13-alpine /bin/sh -s <<'CONTAINER'
set -eu

addgroup -S emacsos-lab
adduser -S -D -H -h /var/lib/emacsos-lab -s /sbin/nologin \
    -G emacsos-lab emacsos-lab
install -d -o emacsos-lab -g emacsos-lab -m 0700 \
    /run/emacsos-ui /var/lib/emacsos-lab /usr/local/share/emacsos-openrc
cp /source/session-power /tmp/session-power.test
install -o root -g root -m 0755 /tmp/session-power.test \
    /usr/local/share/emacsos-openrc/session-power
install -o root -g root -m 0755 /source/process-group \
    /usr/local/share/emacsos-openrc/process-group
sed -e 's|^power=/sys/power$|power=/tmp/power|' \
    -e 's|^power_key=.*$|power_key=/tmp/power-key/wakeup|' \
    -e 's|^axp_power_key=.*$|axp_power_key=/tmp/axp-power-key/wakeup|' \
    -e 's|^modem=.*$|modem=/tmp/modem|' \
    /source/suspend-root >/tmp/suspend-root.test
chmod 0755 /tmp/suspend-root.test
ln -s /usr/local/bin/python3 /usr/bin/python3

mv /usr/bin/flock /usr/bin/flock.real
printf '%s\n' \
    '#!/bin/sh' \
    '[ "$1" = -w ] && shift 2' \
    'exec /bin/busybox flock "$@"' >/usr/bin/flock
chmod 0755 /usr/bin/flock
rm -f /usr/bin/timeout
printf '%s\n' \
    '#!/bin/sh' \
    'case $* in *"/tmp/power/wakeup_count"*) exec /bin/busybox timeout "$@" ;; esac' \
    'while [ "$#" -gt 0 ]; do' \
    '  case $1 in -s|-k) shift 2 ;; [0-9]*) shift; break ;; *) break ;; esac' \
    'done' \
    'exec "$@"' >/usr/bin/timeout
chmod 0755 /usr/bin/timeout
cat >/usr/bin/doas <<'CLIENT'
#!/usr/bin/python3
import json, socket, sys
assert sys.argv[1:3] == ['-n', '/usr/local/sbin/emacsos-openrc-suspend']
assert sys.argv[3:] in ([], ['wake'], ['press'])
sock = socket.socket(socket.AF_UNIX)
sock.connect('/tmp/root-helper.sock')
sock.sendall(json.dumps(sys.argv[3:]).encode())
sock.shutdown(socket.SHUT_WR)
result = json.loads(sock.makefile().read())
sys.stdout.write(result['stdout'])
sys.stderr.write(result['stderr'])
sys.exit(result['code'])
CLIENT
chmod 0755 /usr/bin/doas
cat >/tmp/root-helper.py <<'BROKER'
import json, os, socket, subprocess, threading
from pathlib import Path

def serve(client):
    try:
        action = json.loads(client.recv(128))
        assert action in ([], ['wake'], ['press'])
        if not action and not Path('/tmp/admission-phase').exists():
            with open('/tmp/doas.log', 'a') as log:
                log.write('/usr/local/sbin/emacsos-openrc-suspend\n')
            result = {'code': int(Path('/tmp/suspend-status').read_text()), 'stdout': '', 'stderr': ''}
        else:
            process = subprocess.run(['/tmp/suspend-root.test', *action], capture_output=True, text=True)
            result = {'code': process.returncode, 'stdout': process.stdout, 'stderr': process.stderr}
        client.sendall(json.dumps(result).encode())
    finally:
        client.close()
server = socket.socket(socket.AF_UNIX)
server.bind('/tmp/root-helper.sock')
os.chmod('/tmp/root-helper.sock', 0o666)
server.listen()
while True:
    client, _ = server.accept()
    threading.Thread(target=serve, args=(client,), daemon=True).start()
BROKER
python3 /tmp/root-helper.py &
broker_pid=$!
printf '%s\n' \
    '#!/bin/sh' \
    'printf "%s\n" "$*" >>/tmp/swaymsg.log' \
    'case $* in' \
    '  *"output DSI-1 power off")' \
    '    if [ -e /tmp/block-sway ]; then' \
    '      touch /tmp/sway-reached' \
    '      read answer </tmp/sway-continue' \
    '    fi ;;' \
    'esac' \
    'case $* in' \
    '  "-s /run/emacsos-ui/sway-ipc.test.sock output DSI-1 power on"|"-s /run/emacsos-ui/sway-ipc.test.sock output DSI-1 power off"|"-s /run/emacsos-ui/sway-ipc.test.sock input type:touch events enabled"|"-s /run/emacsos-ui/sway-ipc.test.sock input type:touch events disabled") exit 0 ;;' \
    '  *) exit 1 ;;' \
    'esac' >/usr/bin/swaymsg
chmod 0755 /usr/bin/swaymsg
printf '%s\n' \
    '#!/bin/sh' \
    '[ "${WAYLAND_DISPLAY-}" = wayland-test ] || exit 64' \
    '[ "$*" = "-k F24" ] || exit 64' \
    'printf "%s\n" "$*" >>/tmp/wtype.log' \
    'if [ -e /tmp/block-wtype ]; then' \
    '  touch /tmp/wtype-reached' \
    '  read answer </tmp/wtype-continue' \
    'fi' >/usr/bin/wtype
chmod 0755 /usr/bin/wtype

su -s /bin/sh emacsos-lab -c \
    'python3 -c "import socket,time; a=socket.socket(socket.AF_UNIX); a.bind('\''/run/emacsos-ui/sway-ipc.test.sock'\''); b=socket.socket(socket.AF_UNIX); b.bind('\''/run/emacsos-ui/wayland-test'\''); time.sleep(90)"' &
socket_pid=$!
trap 'kill "$socket_pid" "$broker_pid" 2>/dev/null || true' EXIT
attempt=0
while [ ! -S /tmp/root-helper.sock ] ||
      [ ! -S /run/emacsos-ui/sway-ipc.test.sock ] ||
      [ ! -S /run/emacsos-ui/wayland-test ]; do
    [ "$attempt" -lt 20 ]
    attempt=$((attempt + 1))
    sleep 0.05
done

as_lab() {
    su -s /bin/sh emacsos-lab -c \
        "/usr/local/share/emacsos-openrc/session-power $*"
}

install -d -m 0755 /tmp/external-power
printf '%s\n' 0 >/tmp/external-power/online

mkfifo -m 0600 /run/emacsos-ui/power-events
chown emacsos-lab:emacsos-lab /run/emacsos-ui/power-events
su -s /bin/sh emacsos-lab -c \
    'exec /usr/local/share/emacsos-openrc/process-group /usr/local/share/emacsos-openrc/session-power monitor' &
power_pid=$!
trap 'kill "$socket_pid" "$power_pid" "$broker_pid" 2>/dev/null || true' EXIT
as_lab wake
[ "$(cat /run/emacsos-ui/power-state)" = active ]
[ "$(sed -n '1p' /tmp/swaymsg.log)" = \
    '-s /run/emacsos-ui/sway-ipc.test.sock output DSI-1 power on' ]
[ "$(sed -n '2p' /tmp/swaymsg.log)" = \
    '-s /run/emacsos-ui/sway-ipc.test.sock input type:touch events enabled' ]
[ "$(sed -n '1p' /tmp/wtype.log)" = '-k F24' ]

mkfifo /tmp/wtype-continue
touch /tmp/block-wtype
as_lab wake &
blocking_wake_pid=$!
attempt=0
while [ ! -e /tmp/wtype-reached ]; do
    [ "$attempt" -lt 20 ]
    attempt=$((attempt + 1))
    sleep 0.05
done
if as_lab idle-blank >/tmp/stale-idle.out 2>&1; then
    printf '%s\n' 'stale idle callback waited behind wake' >&2
    exit 1
fi
grep -F 'power transition is busy' /tmp/stale-idle.out >/dev/null
printf '%s\n' continue >/tmp/wtype-continue
wait "$blocking_wake_pid"
[ "$(cat /run/emacsos-ui/power-state)" = active ]
rm -f /tmp/block-wtype /tmp/wtype-continue /tmp/wtype-reached

as_lab press
[ "$(cat /run/emacsos-ui/power-state)" = blank ]
[ "$(sed -n '5p' /tmp/swaymsg.log)" = \
    '-s /run/emacsos-ui/sway-ipc.test.sock input type:touch events disabled' ]
[ "$(sed -n '6p' /tmp/swaymsg.log)" = \
    '-s /run/emacsos-ui/sway-ipc.test.sock output DSI-1 power off' ]

# Manual blanking owns its timer immediately. Generic seat resume, repeated
# idle callbacks and volume activity cannot authorize display wake.
printf '%s\n' 0 >/tmp/suspend-status
generation=$(cat /run/emacsos-ui/power-generation)
before=$(wc -l </tmp/swaymsg.log)
as_lab resume
as_lab idle-blank
[ "$(wc -l </tmp/swaymsg.log)" -eq "$before" ]
[ "$(cat /run/emacsos-ui/power-state)" = blank ]
[ "$(cat /run/emacsos-ui/power-generation)" = "$generation" ]
as_lab suspend "$generation"
[ "$(cat /tmp/doas.log)" = /usr/local/sbin/emacsos-openrc-suspend ]
rm -f /tmp/doas.log

# Suspend failure must remain dark instead of waking the phone unattended.
printf '%s\n' 1 >/tmp/suspend-status
if as_lab suspend "$generation"; then
    printf '%s\n' 'failed suspend was reported as successful' >&2
    exit 1
fi
[ "$(cat /run/emacsos-ui/power-state)" = blank ]
[ "$(wc -l </tmp/swaymsg.log)" -eq "$before" ]
printf '%s\n' 0 >/tmp/suspend-status
rm -f /tmp/doas.log

# A deadline from an older dark period cannot suspend a newly blanked screen.
as_lab wake
as_lab press
as_lab suspend "$generation"
[ ! -e /tmp/doas.log ]
as_lab resume
[ "$(cat /run/emacsos-ui/power-state)" = blank ]
as_lab press
[ "$(cat /run/emacsos-ui/power-state)" = active ]

# Exercise the actual timed reader with a shortened test-only deadline. It
# fires after manual and idle blanking, re-arms after an irrelevant kernel
# resume, and cancels on explicit call/SMS wake without lighting the panel.
kill "$power_pid"
wait "$power_pid" 2>/dev/null || true
sed 's/read -r -t 120 /read -r -t 0.4 /' \
    /source/session-power >/tmp/session-power.fast
chmod 0755 /tmp/session-power.fast
su -s /bin/sh emacsos-lab -c \
    'exec /usr/local/share/emacsos-openrc/process-group /tmp/session-power.fast monitor' &
power_pid=$!
as_lab wake
as_lab press
sleep 0.1
as_lab resume
as_lab idle-blank
sleep 0.15
[ ! -e /tmp/doas.log ]
sleep 0.25
[ "$(wc -l </tmp/doas.log)" -eq 1 ]
[ "$(cat /run/emacsos-ui/power-state)" = blank ]
sleep 0.4
[ "$(wc -l </tmp/doas.log)" -ge 2 ]
as_lab wake
rm -f /tmp/doas.log
sleep 0.5
[ ! -e /tmp/doas.log ]
as_lab idle-blank
sleep 0.5
[ "$(wc -l </tmp/doas.log)" -eq 1 ]
as_lab press
rm -f /tmp/doas.log
kill "$power_pid"
wait "$power_pid" 2>/dev/null || true
su -s /bin/sh emacsos-lab -c \
    'exec /usr/local/share/emacsos-openrc/process-group /usr/local/share/emacsos-openrc/session-power monitor' &
power_pid=$!
as_lab wake

mkfifo /tmp/sway-continue
touch /tmp/block-sway
as_lab idle-blank &
slow_idle_pid=$!
attempt=0
while [ ! -e /tmp/sway-reached ]; do
    [ "$attempt" -lt 20 ]
    attempt=$((attempt + 1))
    sleep 0.05
done
as_lab wake &
waiting_wake_pid=$!
sleep 2.2
kill -0 "$waiting_wake_pid"
printf '%s\n' continue >/tmp/sway-continue
wait "$slow_idle_pid"
wait "$waiting_wake_pid"
[ "$(cat /run/emacsos-ui/power-state)" = active ]
rm -f /tmp/block-sway /tmp/sway-continue /tmp/sway-reached

printf '%s\n' blanking >/run/emacsos-ui/power-state
chown emacsos-lab:emacsos-lab /run/emacsos-ui/power-state
as_lab idle-blank
[ "$(cat /run/emacsos-ui/power-state)" = active ]

if as_lab unknown >/tmp/unknown.out 2>&1; then
    printf '%s\n' 'unknown power action was accepted' >&2
    exit 1
fi
grep -F 'unknown action' /tmp/unknown.out >/dev/null

su -s /bin/sh emacsos-lab -c \
    'python3 -c "import socket,time; s=socket.socket(socket.AF_UNIX); s.bind('\''/run/emacsos-ui/sway-ipc.extra.sock'\''); time.sleep(90)"' &
extra_socket_pid=$!
attempt=0
while [ ! -S /run/emacsos-ui/sway-ipc.extra.sock ]; do
    [ "$attempt" -lt 20 ]
    attempt=$((attempt + 1))
    sleep 0.05
done
if as_lab wake >/tmp/ambiguous.out 2>&1; then
    printf '%s\n' 'ambiguous Sway socket was accepted' >&2
    exit 1
fi
grep -F 'ambiguous Sway socket' /tmp/ambiguous.out >/dev/null
kill "$extra_socket_pid"
wait "$extra_socket_pid" 2>/dev/null || true
rm -f /run/emacsos-ui/sway-ipc.extra.sock

su -s /bin/sh emacsos-lab -c \
    'python3 -c "import socket,time; s=socket.socket(socket.AF_UNIX); s.bind('\''/run/emacsos-ui/wayland-extra'\''); time.sleep(90)"' &
extra_wayland_pid=$!
attempt=0
while [ ! -S /run/emacsos-ui/wayland-extra ]; do
    [ "$attempt" -lt 20 ]
    attempt=$((attempt + 1))
    sleep 0.05
done
if as_lab wake >/tmp/ambiguous-wayland.out 2>&1; then
    printf '%s\n' 'ambiguous Wayland socket was accepted' >&2
    exit 1
fi
grep -F 'ambiguous Wayland socket' /tmp/ambiguous-wayland.out >/dev/null
kill "$extra_wayland_pid"
wait "$extra_wayland_pid" 2>/dev/null || true
rm -f /run/emacsos-ui/wayland-extra

install -d -m 0755 /tmp/power /tmp/power-key /tmp/axp-power-key /tmp/modem/power
printf '%s\n' 's2idle [deep]' >/tmp/power/mem_sleep
printf '%s\n' 1 >/tmp/power/sync_on_suspend
printf '%s\n' 41 >/tmp/power/wakeup_count
: >/tmp/power/state
printf '%s\n' disabled >/tmp/power-key/wakeup
printf '%s\n' disabled >/tmp/axp-power-key/wakeup
printf '%s\n' 2c7c >/tmp/modem/idVendor
printf '%s\n' 0125 >/tmp/modem/idProduct
printf '%s\n' disabled >/tmp/modem/power/wakeup
/tmp/suspend-root.test
[ "$(cat /tmp/power/state)" = mem ]
[ "$(cat /tmp/power-key/wakeup)" = enabled ]
[ "$(cat /tmp/axp-power-key/wakeup)" = enabled ]
[ "$(cat /tmp/modem/power/wakeup)" = enabled ]
if /tmp/suspend-root.test unexpected >/tmp/root-arg.out 2>&1; then
    printf '%s\n' 'root suspend helper accepted an argument' >&2
    exit 1
fi
grep -F 'unknown guarded action' /tmp/root-arg.out >/dev/null
printf '%s\n' dead >/tmp/modem/idProduct
if /tmp/suspend-root.test >/tmp/root-modem.out 2>&1; then
    printf '%s\n' 'root suspend helper accepted an unexpected modem' >&2
    exit 1
fi
grep -F 'expected EG25 modem is absent' /tmp/root-modem.out >/dev/null

# Exercise admission with real kernel guard FDs, helper code and display locks.
# Sway/wtype and doas transport are fixtures. The PM counter/state handshake is
# modeled because ordinary files cannot reject writes on kernel wake events.
printf '%s\n' 0125 >/tmp/modem/idProduct
cat >/tmp/kernel-pm-model.py <<'MODEL'
import os, re, sys, time
from pathlib import Path

def sources():
    active = set()
    for info in Path('/proc').glob('[0-9]*/fdinfo/11'):
        try:
            registration = info.read_text()
            event = info.with_name('10').read_text()
        except OSError:
            continue
        watch = re.search(r'tfd:\s*10\s+events:\s*([0-9a-f]+)', registration)
        if (watch and int(watch[1], 16) & (1 << 29)
                and re.search(r'eventfd-count:\s*1\s*$', event, re.M)):
            active.add(re.search(r'eventfd-id:\s*(\d+)', event)[1])
    return active

operation = sys.argv[1]
if operation == 'sources':
    print(' '.join(sorted(sources())))
elif operation == 'read':
    # Kernel wakeup_count waits for active sources to finish. The production
    # timeout must interrupt this read while wake waits for the display lock.
    while sources():
        time.sleep(0.01)
    print(Path('/tmp/power/wakeup_count').read_text().strip())
elif operation == 'accept':
    if sources():
        sys.exit(1)
elif operation == 'submit':
    if sources():
        sys.exit(1)
    Path('/tmp/power/state').write_text('mem\n')
else:
    raise AssertionError(operation)
MODEL
python3 - <<'FIXTURE'
import re
from pathlib import Path
p = Path('/tmp/suspend-root.test')
s = p.read_text()
barrier = '''
admission_barrier() {
    [ "$(cat /tmp/admission-phase)" = "$1" ] || return 0
    touch /tmp/admission-reached
    read answer </tmp/admission-continue
}
'''
s = s.replace('wakeup_count=$(', 'admission_barrier before-read\nwakeup_count=$(', 1)
# Preserve whether the source has the bounded read. This makes the same
# fixture expose the unfixed HEAD, without patching the tested lock or guard.
bounded = "wakeup_count=$(timeout -s TERM -k 1 2 sed" in s
read = '/usr/bin/python3 /tmp/kernel-pm-model.py read /tmp/power/wakeup_count'
if bounded:
    read = 'timeout -s TERM -k 1 2 ' + read + ' 9>&-'
s = re.sub(r'^wakeup_count=.*$', 'wakeup_count=$(' + read + ') || exit 75', s, flags=re.M)
s = re.sub(r'^printf .* >"\$power/wakeup_count" \|\| exit 75$',
           'admission_barrier before-accept\n/usr/bin/python3 /tmp/kernel-pm-model.py accept "$wakeup_count" || exit 75',
           s, flags=re.M)
s = s.replace('if ! printf \'%s\\n\' mem >"$power/state"; then',
              'admission_barrier before-mem\nif ! /usr/bin/python3 /tmp/kernel-pm-model.py submit; then')
s = re.sub(r'^    new_wakeup_count=.*$',
           '    new_wakeup_count=$(' + read + ') || exit 75', s, flags=re.M)
p.write_text(s.replace('set -eu', 'set -eu' + barrier, 1))
p = Path('/usr/bin/flock')
s = p.read_text().replace('[ "$1" = -w ]',
    '[ "$1" != -x ] || [ ! -e /tmp/admission-phase ] || touch /tmp/admission-wake-at-lock\n[ "$1" = -w ]', 1)
p.write_text(s)
p = Path('/usr/bin/wtype')
s = p.read_text().replace('  touch /tmp/wtype-reached', '  echo "$PPID" >/tmp/wtype-power-pid\n  touch /tmp/wtype-reached')
s = s.replace('[ "${WAYLAND_DISPLAY-}"', '[ ! -e /tmp/fail-wtype ] || exit 1\n[ "${WAYLAND_DISPLAY-}"', 1)
p.write_text(s)
FIXTURE

wait_file() {
    attempt=0
    while [ ! -e "$1" ]; do
        [ "$attempt" -lt 100 ] || exit 1
        attempt=$((attempt + 1))
        sleep 0.02
    done
}
for phase in before-read before-accept before-mem; do
    as_lab wake
    as_lab press
    : >/tmp/power/state
    printf '%s\n' 42 >/tmp/power/wakeup_count
    printf '%s\n' "$phase" >/tmp/admission-phase
    mkfifo /tmp/admission-continue
    generation=$(cat /run/emacsos-ui/power-generation)
    as_lab suspend "$generation" &
    admission_suspend_pid=$!
    wait_file /tmp/admission-reached
    as_lab wake &
    admission_wake_pid=$!
    wait_file /tmp/admission-wake-at-lock
    if flock -n /run/emacsos-ui/power-state.lock true; then
        printf '%s\n' 'admission fixture lost the display lock' >&2
        exit 1
    fi
    [ "$(cat /run/emacsos-ui/power-state)" = blank ]
    printf '%s\n' continue >/tmp/admission-continue
    wait "$admission_suspend_pid"
    wait "$admission_wake_pid"
    if [ -s /tmp/power/state ]; then
        printf 'explicit wake was lost at admission phase %s\n' "$phase" >&2
        exit 1
    fi
    [ "$(cat /run/emacsos-ui/power-state)" = active ]
    [ -z "$(python3 /tmp/kernel-pm-model.py sources)" ]
    rm -f /tmp/admission-phase /tmp/admission-reached \
        /tmp/admission-wake-at-lock /tmp/admission-continue
    printf 'Kernel-guarded admission %s: OK\n' "$phase"
done

# Two requests own independent objects. KILL of the first display owner must
# not drop its descendant's guard or the second request's guard. Their final
# FD closes must release both sources, without any root cleanup state.
mkfifo /tmp/wtype-continue
touch /tmp/block-wtype
as_lab wake &
first_wake_pid=$!
wait_file /tmp/wtype-reached
first_power_pid=$(cat /tmp/wtype-power-pid)
first_source=$(python3 /tmp/kernel-pm-model.py sources)
[ -n "$first_source" ]
as_lab wake &
second_wake_pid=$!
attempt=0
while [ "$(python3 /tmp/kernel-pm-model.py sources | wc -w)" -ne 2 ]; do
    [ "$attempt" -lt 100 ]
    attempt=$((attempt + 1))
    sleep 0.02
done
kill -KILL "$first_power_pid"
[ "$(python3 /tmp/kernel-pm-model.py sources | wc -w)" -eq 2 ]
rm -f /tmp/wtype-reached
printf '%s\n' continue >/tmp/wtype-continue
if wait "$first_wake_pid"; then
    printf '%s\n' 'KILL of guarded display owner was reported as success' >&2
    exit 1
fi
wait_file /tmp/wtype-reached
remaining_source=$(python3 /tmp/kernel-pm-model.py sources)
[ -n "$remaining_source" ] && [ "$remaining_source" != "$first_source" ]
[ "$(printf '%s\n' "$remaining_source" | wc -w)" -eq 1 ]
rm -f /tmp/block-wtype
printf '%s\n' continue >/tmp/wtype-continue
wait "$second_wake_pid"
[ "$(cat /run/emacsos-ui/power-state)" = active ]
[ -z "$(python3 /tmp/kernel-pm-model.py sources)" ]
rm -f /tmp/wtype-continue /tmp/wtype-reached /tmp/wtype-power-pid

touch /tmp/fail-wtype
if as_lab wake; then
    printf '%s\n' 'failed guarded display transition was reported as success' >&2
    exit 1
fi
[ -z "$(python3 /tmp/kernel-pm-model.py sources)" ]
rm -f /tmp/fail-wtype
as_lab wake
if as_lab guarded-wake >/tmp/missing-guard.out 2>&1; then
    printf '%s\n' 'internal display wake accepted absent kernel guard' >&2
    exit 1
fi
printf '%s\n' 'Kernel guard overlap, parent death and failure cleanup: OK'

printf '%s\n' \
    '#!/bin/sh' \
    'trap "exit 0" HUP INT TERM' \
    'sh -c '\''trap "exit 0" HUP INT TERM; echo $$ >/tmp/group-grandchild.pid; while :; do sleep 1; done'\'' &' \
    'echo $$ >/tmp/group-child.pid' \
    'wait' >/tmp/group-tree
chmod 0755 /tmp/group-tree
su -s /bin/sh emacsos-lab -c \
    'exec /usr/local/share/emacsos-openrc/process-group /tmp/group-tree' \
    >/tmp/group-wrapper.out 2>&1 &
group_wrapper_pid=$!
attempt=0
while [ ! -s /tmp/group-child.pid ] || [ ! -s /tmp/group-grandchild.pid ]; do
    [ "$attempt" -lt 20 ]
    attempt=$((attempt + 1))
    sleep 0.05
done
group_child_pid=$(cat /tmp/group-child.pid)
group_grandchild_pid=$(cat /tmp/group-grandchild.pid)
kill -TERM "$group_wrapper_pid"
wait "$group_wrapper_pid" 2>/dev/null || true
[ ! -e "/proc/$group_child_pid" ]
[ ! -e "/proc/$group_grandchild_pid" ]

printf '%s\n' 'OpenRC display state machine: OK'
CONTAINER
