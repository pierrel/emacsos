#!/bin/sh

set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

source_dir=${POWER_TEST_SOURCE_DIR:-$repo_dir/deploy/pinephone}

docker run --rm --network none --cap-add BLOCK_SUSPEND --cap-add SYS_PTRACE -i \
    -v "$source_dir/openrc-session-power:/source/session-power:ro" \
    -v "$source_dir/openrc-suspend-root:/source/suspend-root:ro" \
    -v "$repo_dir/deploy/pinephone/openrc-power-monitor:/source/power-monitor:ro" \
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
    -e 's|^modem_controller=.*$|modem_controller=/tmp/modem-controller|' \
    -e 's|/sys/class/power_supply|/tmp/power-supplies|g' \
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
rm -f /usr/bin/logger
printf '%s\n' '#!/bin/sh' 'printf "%s\n" "$*" >>/tmp/root-error.log' >/usr/bin/logger
chmod 0755 /usr/bin/logger
cat >/usr/bin/doas <<'CLIENT'
#!/usr/bin/python3
import array, json, os, socket, sys
assert sys.argv[1:3] == ['-n', '/usr/local/sbin/emacsos-openrc-suspend']
assert sys.argv[3:] in ([], ['wake'], ['press'], ['monitor'])
sock = socket.socket(socket.AF_UNIX)
sock.connect('/tmp/root-helper.sock')
fds = array.array('i', [0, 1, 2]) if not sys.argv[3:] else array.array('i')
sock.sendmsg([json.dumps(sys.argv[3:]).encode()],
             [(socket.SOL_SOCKET, socket.SCM_RIGHTS, fds)] if fds else [])
sock.shutdown(socket.SHUT_WR)
result = json.loads(sock.makefile().read())
if sys.argv[3:]:
    sys.stdout.write(result['stdout'])
    sys.stderr.write(result['stderr'])
sys.exit(result['code'])
CLIENT
chmod 0755 /usr/bin/doas
cat >/tmp/root-helper.py <<'BROKER'
import array, json, os, socket, subprocess, threading
from pathlib import Path

def serve(client):
    fds = array.array('i')
    try:
        data, ancillary, _, _ = client.recvmsg(128, socket.CMSG_SPACE(3 * fds.itemsize))
        action = json.loads(data)
        assert action in ([], ['wake'], ['press'], ['monitor'])
        for level, kind, value in ancillary:
            assert (level, kind) == (socket.SOL_SOCKET, socket.SCM_RIGHTS)
            fds.frombytes(value)
        if not action and not Path('/tmp/admission-phase').exists() and not Path('/tmp/power-policy-test').exists():
            with open('/tmp/doas.log', 'a') as log:
                log.write('/usr/local/sbin/emacsos-openrc-suspend\n')
            result = {'code': int(Path('/tmp/suspend-status').read_text()), 'stdout': '', 'stderr': ''}
        else:
            if action:
                process = subprocess.Popen(['/tmp/suspend-root.test', *action],
                                           stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            else:
                assert len(fds) == 3
                process = subprocess.Popen(['/tmp/suspend-root.test'],
                                           stdin=fds[0], stdout=fds[1], stderr=fds[2])
            # Once spawned only the actual owners retain the epoll/input FDs.
            for fd in fds:
                os.close(fd)
            fds = array.array('i')
            stdout, stderr = process.communicate()
            result = {'code': process.returncode, 'stdout': stdout or '', 'stderr': stderr or ''}
            if not action and Path('/tmp/power-policy-test').exists():
                import time
                with open('/tmp/power-policy-attempts', 'a') as log:
                    log.write(json.dumps({'code': process.returncode, 'at': time.clock_gettime(time.CLOCK_BOOTTIME)}) + '\n')
        client.sendall(json.dumps(result).encode())
    finally:
        for fd in fds:
            os.close(fd)
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
    su -s /bin/sh emacsos-lab -c "/usr/local/share/emacsos-openrc/session-power $*"
}

python3 - <<'MONITOR_FIXTURE'
from pathlib import Path
p = Path('/usr/local/share/emacsos-openrc/power-monitor')
s = Path('/source/power-monitor').read_text()
a = s.index('def verify_input('); b = s.index('\ndef verify_guard()', a)
s = s[:a] + "def verify_input(fd, name, key):\n    assert stat.S_ISFIFO(os.fstat(fd).st_mode)\n\n" + s[b:]
a = s.index('    found = set()'); b = s.index('    os.dup2(guard.fileno(), 4', a)
s = s[:a] + "    for fd in INPUTS:\n        source = os.open('/tmp/wake-input-' + str(fd), os.O_RDWR | os.O_NONBLOCK)\n        os.dup2(source, fd, inheritable=True)\n        os.close(source)\n        guard.register(fd, select.EPOLLIN | WAKEUP)\n" + s[b:]
s = s.replace("SUSPEND = '/usr/local/sbin/emacsos-openrc-suspend'", "SUSPEND = '/tmp/suspend-root.test'")
p.write_text(s); p.chmod(0o755)
MONITOR_FIXTURE
mkfifo /tmp/wake-input-3 /tmp/wake-input-5
python3 /usr/local/share/emacsos-openrc/power-monitor monitor >/tmp/monitor-ready &
power_pid=$!
trap 'kill "$socket_pid" "$power_pid" "$broker_pid" 2>/dev/null || true' EXIT
attempt=0
while ! grep -Fx ready /tmp/monitor-ready >/dev/null; do
    [ "$attempt" -lt 30 ]; attempt=$((attempt+1)); sleep .05
done
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

# Generic seat resume and repeated idle cannot light a manual blank.
generation=$(cat /run/emacsos-ui/power-generation)
before=$(wc -l </tmp/swaymsg.log)
as_lab resume
as_lab idle-blank
[ "$(wc -l </tmp/swaymsg.log)" -eq "$before" ]
[ "$(cat /run/emacsos-ui/power-state)" = blank ]
[ "$(cat /run/emacsos-ui/power-generation)" = "$generation" ]
as_lab press
[ "$(cat /run/emacsos-ui/power-state)" = active ]
    python3 - "$power_pid" <<'DROP'
from pathlib import Path
import sys
fields=dict(line.split(':',1) for line in Path('/proc/'+sys.argv[1]+'/status').read_text().splitlines() if ':' in line)
assert len(set(fields['Uid'].split())) == 1 and int(fields['Uid'].split()[0]) != 0
assert len(set(fields['Gid'].split())) == 1 and int(fields['Gid'].split()[0]) != 0
assert all(int(fields[name],16)==0 for name in ('CapEff','CapPrm','CapAmb'))
DROP

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

# Native release/repeat packets do not wake, while overflow recovers safely.
as_lab press
python3 - <<'PACKETS'
import os,struct
fd=os.open('/tmp/wake-input-5',os.O_RDWR|os.O_NONBLOCK)
os.write(fd,b''.join(struct.pack('@llHHi',0,0,1,143,value) for value in (0,2)))
os.close(fd)
PACKETS
sleep 0.1
[ "$(cat /run/emacsos-ui/power-state)" = blank ]
python3 - <<'PACKETS'
import os,struct
fd=os.open('/tmp/wake-input-3',os.O_RDWR|os.O_NONBLOCK)
os.write(fd,b''.join(struct.pack('@llHHi',0,0,*event) for event in ((0,3,0),(1,116,1),(0,0,0))))
os.close(fd)
PACKETS
attempt=0
while [ "$(cat /run/emacsos-ui/power-state)" != active ]; do
    [ "$attempt" -lt 100 ]; attempt=$((attempt + 1)); sleep 0.02
done
# Freeze before both inputs arrive so they form one batch; RI wins after press.
kill -STOP "$power_pid"
python3 - <<'PACKETS'
import os,struct
for fdno,key in ((3,116),(5,143)):
    fd=os.open('/tmp/wake-input-'+str(fdno),os.O_RDWR|os.O_NONBLOCK)
    os.write(fd,struct.pack('@llHHi',0,0,1,key,1));os.close(fd)
PACKETS
start_lines=$(wc -l </tmp/swaymsg.log)
kill -CONT "$power_pid"
attempt=0
while [ "$(wc -l </tmp/swaymsg.log)" -lt "$((start_lines + 4))" ] ||
      [ "$(cat /run/emacsos-ui/power-state)" != active ]; do
    [ "$attempt" -lt 100 ]; attempt=$((attempt + 1)); sleep 0.02
done
[ "$(cat /run/emacsos-ui/power-state)" = active ]
printf '%s\n' 'Typed input, overflow recovery and simultaneous power/RI order: OK'

cat >/tmp/kernel-pm-model.py <<'MODEL'
import array, fcntl, os, re, sys, time
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
    # Real EPOLLWAKEUP registrations on fixture input queues. FIONREAD
    # observes queued packets without consuming the worker's private input.
    for info in Path('/proc').glob('[0-9]*/fdinfo/4'):
        try:
            registration = info.read_text()
            for target in (3, 5):
                watch = re.search(r'tfd:\s*' + str(target) + r'\s+events:\s*([0-9a-f]+)', registration)
                if not watch or not int(watch[1], 16) & (1 << 29):
                    continue
                fd = os.open(str(info.parent.parent / 'fd' / str(target)), os.O_RDONLY | os.O_NONBLOCK)
                try:
                    pending = array.array('i', [0])
                    fcntl.ioctl(fd, 0x541b, pending, True)
                    if pending[0]:
                        active.add('input-' + str(os.fstat(fd).st_ino))
                finally:
                    os.close(fd)
        except OSError:
            continue
    return active

operation = sys.argv[1]
if operation == 'sources':
    print(' '.join(sorted(sources())))
else:
    raise AssertionError(operation)
MODEL
python3 - <<'FIXTURE'
from pathlib import Path
p=Path('/usr/bin/wtype');s=p.read_text()
s=s.replace('  touch /tmp/wtype-reached', '  echo "$PPID" >/tmp/wtype-power-pid\n  touch /tmp/wtype-reached')
s=s.replace('[ "${WAYLAND_DISPLAY-}"', '[ ! -e /tmp/fail-wtype ] || exit 1\n[ "${WAYLAND_DISPLAY-}"', 1)
p.write_text(s)
FIXTURE
wait_file() {
    attempt=0
    while [ ! -e "$1" ]; do
        [ "$attempt" -lt 100 ]; attempt=$((attempt+1)); sleep .02
    done
}
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
