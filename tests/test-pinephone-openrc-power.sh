#!/bin/sh

set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

source_dir=${POWER_TEST_SOURCE_DIR:-$repo_dir/deploy/pinephone}

docker run --rm --network none --cap-add BLOCK_SUSPEND --cap-add SYS_PTRACE -i \
    -v "$source_dir/openrc-session-power:/source/session-power:ro" \
    -v "$source_dir/openrc-suspend-root:/source/suspend-root:ro" \
    -v "$repo_dir/deploy/pinephone/openrc-power-monitor:/source/power-monitor:ro" \
    -v "$repo_dir/deploy/pinephone/openrc-usage:/source/usage:ro" \
    -v "$source_dir/openrc-process-group:/source/process-group:ro" \
    python:3.13-alpine /bin/sh -s <<'CONTAINER'
set -eu
queue_guard=0
grep -F 'power-monitor handoff' /source/suspend-root >/dev/null && queue_guard=1

addgroup -S emacsos-lab
adduser -S -D -H -h /var/lib/emacsos-lab -s /sbin/nologin \
    -G emacsos-lab emacsos-lab
install -d -o emacsos-lab -g emacsos-lab -m 0700 \
    /run/emacsos-ui /var/lib/emacsos-lab /usr/local/share/emacsos-openrc
cp /source/session-power /tmp/session-power.test
install -o root -g root -m 0755 /tmp/session-power.test \
    /usr/local/share/emacsos-openrc/session-power
install -o root -g root -m 0755 /source/usage \
    /usr/local/share/emacsos-openrc/usage
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
    if [ "$1" = suspend ] && [ "$queue_guard" -eq 1 ]; then
        python3 /tmp/admit-as-lab.py "$power_pid" "$2"
    else
        su -s /bin/sh emacsos-lab -c \
            "/usr/local/share/emacsos-openrc/session-power $*"
    fi
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
s = s.replace('    verify_guard()\n    user =', "    verify_guard()\n    import array, socket\n    sock = socket.socket(socket.AF_UNIX)\n    sock.connect('/tmp/monitor-fds.sock')\n    sock.sendmsg([str(os.getpid()).encode()], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array('i', [3, 4, 5]))])\n    sock.close()\n    user =")
p.write_text(s); p.chmod(0o755)
MONITOR_FIXTURE
mkfifo /tmp/wake-input-3 /tmp/wake-input-5
cat >/tmp/monitor-fds.py <<'KEEPER'
import array, json, os, socket, subprocess, threading
fds = {}; lock = threading.Lock()
def serve(client):
    data, ancillary, _, _ = client.recvmsg(128, socket.CMSG_SPACE(12))
    with lock:
        if ancillary:
            received = array.array('i'); received.frombytes(ancillary[0][2])
            fds[int(data)] = received
        else:
            pid, action = json.loads(data)
            if action == 'release':
                for fd in fds.pop(pid): os.close(fd)
            else:
                source = fds[pid]
                client.sendmsg([b'fds'], [(socket.SOL_SOCKET, socket.SCM_RIGHTS, source)])
    client.close()
sock=socket.socket(socket.AF_UNIX); sock.bind('/tmp/monitor-fds.sock'); sock.listen()
while True:
    client,_=sock.accept(); threading.Thread(target=serve,args=(client,),daemon=True).start()
KEEPER
python3 /tmp/monitor-fds.py &
keeper_pid=$!
cat >/tmp/admit-as-lab.py <<'ADMIT'
import array, fcntl, json, os, pwd, socket, subprocess, sys
pid = int(sys.argv[1]); sock=socket.socket(socket.AF_UNIX); sock.connect('/tmp/monitor-fds.sock')
sock.sendall(json.dumps([pid, 'get']).encode())
_, ancillary, _, _ = sock.recvmsg(16, socket.CMSG_SPACE(12)); sock.close()
fds=array.array('i'); fds.frombytes(ancillary[0][2])
# Preserve fixed slots while avoiding collisions in received descriptor IDs.
copies=[fcntl.fcntl(fd, fcntl.F_DUPFD_CLOEXEC, 16) for fd in fds]
for fd in fds: os.close(fd)
for source,target in zip(copies,(3,4,5)): os.dup2(source,target,inheritable=True)
for fd in copies:
    if fd not in (3,4,5): os.close(fd)
user=pwd.getpwnam('emacsos-lab'); os.initgroups(user.pw_name,user.pw_gid)
os.setresgid(user.pw_gid,user.pw_gid,user.pw_gid); os.setresuid(user.pw_uid,user.pw_uid,user.pw_uid)
os.execv('/usr/local/share/emacsos-openrc/session-power',['session-power','suspend',sys.argv[2]])
ADMIT
install -d -m 0755 /tmp/external-power
printf '%s\n' 0 >/tmp/external-power/online
printf '%s\n' 0 >/tmp/external-power/present
install -d -m 0755 /tmp/external-power/power /tmp/power-supplies/axp20x-battery
ln -s /tmp/external-power /tmp/power-supplies/axp20x-usb
printf '%s\n' USB >/tmp/external-power/type
printf '%s\n' disabled >/tmp/external-power/power/wakeup
printf '%s\n' Battery >/tmp/power-supplies/axp20x-battery/type
printf '%s\n' 1 >/tmp/power-supplies/axp20x-battery/online
printf '%s\n' Discharging >/tmp/power-supplies/axp20x-battery/status
install -d -m 0755 /tmp/power /tmp/power-key /tmp/axp-power-key /tmp/modem-controller/usb1/1-1/power
printf '%s\n' 's2idle [deep]' >/tmp/power/mem_sleep
printf '%s\n' 1 >/tmp/power/sync_on_suspend
printf '%s\n' 41 >/tmp/power/wakeup_count
: >/tmp/power/state
printf '%s\n' disabled >/tmp/power-key/wakeup
printf '%s\n' disabled >/tmp/axp-power-key/wakeup
printf '%s\n' 2c7c >/tmp/modem-controller/usb1/1-1/idVendor
printf '%s\n' 0125 >/tmp/modem-controller/usb1/1-1/idProduct
printf '%s\n' disabled >/tmp/modem-controller/usb1/1-1/power/wakeup

mkfifo -m 0600 /run/emacsos-ui/power-events
chown emacsos-lab:emacsos-lab /run/emacsos-ui/power-events
if [ "$queue_guard" -eq 1 ]; then
    python3 /usr/local/share/emacsos-openrc/power-monitor monitor &
else
    su -s /bin/sh emacsos-lab -c 'exec /usr/local/share/emacsos-openrc/session-power monitor' &
fi
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
if [ "$queue_guard" -eq 1 ]; then
    sed 's/DELAY = 120/DELAY = 0.4/' \
        /usr/local/share/emacsos-openrc/power-monitor >/tmp/power-monitor.fast
    python3 /tmp/power-monitor.fast monitor &
else
    sed 's/read -r -t 120 /read -r -t 0.4 /' /source/session-power >/tmp/session-power.fast
    chmod 0755 /tmp/session-power.fast
    su -s /bin/sh emacsos-lab -c 'exec /tmp/session-power.fast monitor' &
fi
power_pid=$!
as_lab wake
as_lab press
sleep 0.1
as_lab resume
as_lab idle-blank
sleep 0.15
[ ! -e /tmp/doas.log ]
# Real telemetry writes add bounded work around each helper invocation; this
# test checks admission/rearming rather than Python startup speed.
sleep 0.75
[ "$(wc -l </tmp/doas.log)" -ge 1 ]
[ "$(cat /run/emacsos-ui/power-state)" = blank ]
sleep 1
[ "$(wc -l </tmp/doas.log)" -ge 2 ]
as_lab wake
rm -f /tmp/doas.log
sleep 0.5
[ ! -e /tmp/doas.log ]
as_lab idle-blank
sleep 1
[ "$(wc -l </tmp/doas.log)" -ge 1 ]
as_lab press
rm -f /tmp/doas.log

# External-power policy uses the REAL root helper, including its inherited
# guard objects. The usual no-argument status stub is disabled for these cases.
wait_policy_attempt() {
    attempt=0
    while [ ! -f /tmp/power-policy-attempts ]; do
        [ "$attempt" -lt 100 ]; attempt=$((attempt + 1)); sleep 0.02
    done
}
policy_code() {
    python3 -c 'import json; print(json.loads(open("/tmp/power-policy-attempts").readline())["code"])'
}
touch /tmp/power-policy-test
for status in Full Discharging; do
    printf '%s\n' "$status" >/tmp/power-supplies/axp20x-battery/status
    printf '%s\n' 1 >/tmp/external-power/online
printf '%s\n' 1 >/tmp/external-power/present
    as_lab wake
    rm -f /tmp/power-policy-attempts
    : >/tmp/power/state
    as_lab idle-blank
    generation=$(cat /run/emacsos-ui/power-generation)
    wait_policy_attempt
    if [ "$(policy_code)" -ne 77 ]; then
        printf 'Powered %s battery expected skip77; got%s, state=%s\n' \
            "$status" "$(policy_code)" "$(cat /tmp/power/state)" >&2
        exit 1
    fi
    [ ! -s /tmp/power/state ]
    [ "$(cat /run/emacsos-ui/power-state)" = blank ]
    [ "$(cat /run/emacsos-ui/power-generation)" = "$generation" ]
done
printf '%s\n' 'Powered blank stays dark and awake for Full/Discharging battery: OK'
as_lab wake
printf '%s\n' 0 >/tmp/external-power/online
printf '%s\n' 1 >/tmp/external-power/present
rm -f /tmp/power-policy-attempts
: >/tmp/power/state
as_lab press
wait_policy_attempt
[ "$(policy_code)" -eq 77 ]
[ ! -s /tmp/power/state ]
[ "$(cat /run/emacsos-ui/power-state)" = blank ]
printf '%s\n' 'USB present before ONLINE also exempts deep sleep: OK'


as_lab wake
printf '%s\n' 0 >/tmp/external-power/online
printf '%s\n' 0 >/tmp/external-power/present
rm -f /tmp/power-policy-attempts
: >/tmp/power/state
as_lab press
sleep 0.1
printf '%s\n' 1 >/tmp/external-power/online
printf '%s\n' 1 >/tmp/external-power/present
wait_policy_attempt
[ "$(policy_code)" -eq 77 ]
[ ! -s /tmp/power/state ]
[ "$(cat /run/emacsos-ui/power-state)" = blank ]
printf '%s\n' 'Plug during pending screen-off deadline vetoes sleep: OK'

# The powered attempt already elapsed; unplug uses the same armed retry and
# does not require another blank event or change its generation.
generation=$(cat /run/emacsos-ui/power-generation)
first_attempt=$(python3 -c 'import json; print(json.loads(open("/tmp/power-policy-attempts").readline())["at"])')
sleep 0.1
rm -f /tmp/power-policy-attempts
printf '%s\n' 0 >/tmp/external-power/online
printf '%s\n' 0 >/tmp/external-power/present
sleep 0.15
[ ! -e /tmp/power-policy-attempts ]
wait_policy_attempt
[ "$(policy_code)" -eq 0 ]
[ "$(cat /tmp/power/state)" = mem ]
[ "$(cat /run/emacsos-ui/power-state)" = blank ]
[ "$(cat /run/emacsos-ui/power-generation)" = "$generation" ]
python3 - "$first_attempt" <<'CADENCE'
import json,sys
second=json.loads(open('/tmp/power-policy-attempts').readline())['at']
assert .35 <= second-float(sys.argv[1]) < 1.5, 'powered attempt changed retry cadence'
CADENCE
printf '%s\n' 'Unplug already-dark phone resumes the armed retry: OK'

as_lab wake
printf '%s\n' 1 >/tmp/external-power/online
printf '%s\n' 1 >/tmp/external-power/present
rm -f /tmp/power-policy-attempts
: >/tmp/power/state
as_lab idle-blank
blank_started=$(python3 -c 'import time;print(time.clock_gettime(time.CLOCK_BOOTTIME))')
sleep 0.2
printf '%s\n' 0 >/tmp/external-power/online
printf '%s\n' 0 >/tmp/external-power/present
wait_policy_attempt
[ "$(policy_code)" -eq 0 ]
[ "$(cat /tmp/power/state)" = mem ]
python3 - "$blank_started" <<'DEADLINE'
import json,sys
attempt=json.loads(open('/tmp/power-policy-attempts').readline())['at']
assert .25 <= attempt-float(sys.argv[1]) < .58, 'unplug restarted the original blank deadline'
DEADLINE
as_lab wake
printf '%s\n' 'Unplug before deadline keeps its original remaining time: OK'

# The same internal controller/port must work under either boot bus number.
mv /tmp/modem-controller/usb1 /tmp/modem-controller/usb2
mv /tmp/modem-controller/usb2/1-1 /tmp/modem-controller/usb2/2-1
as_lab press
generation=$(cat /run/emacsos-ui/power-generation)
as_lab suspend "$generation"
[ "$(cat /tmp/power/state)" = mem ]
[ "$(cat /tmp/modem-controller/usb2/2-1/power/wakeup)" = enabled ]
as_lab wake
# Refuse multiple candidates within that controller rather than guessing.
mkdir -p /tmp/modem-controller/usb9/9-1
as_lab press
generation=$(cat /run/emacsos-ui/power-generation)
: >/tmp/power/state
if as_lab suspend "$generation"; then
    printf '%s\n' 'ambiguous internal modem port was accepted' >&2
    exit 1
fi
grep -F 'ambiguous internal modem port' /tmp/root-error.log >/dev/null
[ ! -s /tmp/power/state ]
as_lab wake
rmdir /tmp/modem-controller/usb9/9-1 /tmp/modem-controller/usb9
mv /tmp/modem-controller/usb2/2-1 /tmp/modem-controller/usb2/1-1
mv /tmp/modem-controller/usb2 /tmp/modem-controller/usb1
rm -f /tmp/power-policy-test /tmp/power-policy-attempts
printf '%s\n' 'Internal modem resolves across boot bus numbers and rejects ambiguity: OK'

if [ "$queue_guard" -eq 1 ]; then
    kill -STOP "$power_pid"
    as_lab press
    sleep 0.5
    [ ! -e /tmp/doas.log ]
    kill -CONT "$power_pid"
    attempt=0
    while [ ! -e /tmp/doas.log ]; do
        [ "$attempt" -lt 10 ]; attempt=$((attempt + 1)); sleep 0.02
    done
    as_lab wake
    rm -f /tmp/doas.log
    printf '%s\n' 'Delayed FIFO consumption preserves screen-off deadline: OK'
    # Reproduce the phone's missing-modem admission failure with the real
    # root helper. The same timed reader must retain its wake guard and PID.
    touch /tmp/power-policy-test
    rm -f /tmp/modem-controller/usb1/1-1/idProduct /tmp/power-policy-attempts
    : >/tmp/power/state
    before=$(wc -l </tmp/swaymsg.log)
    as_lab press
    generation=$(cat /run/emacsos-ui/power-generation)
    wait_policy_attempt
    [ "$(policy_code)" -eq 1 ]
    grep -F 'expected EG25 modem is absent' /tmp/root-error.log >/dev/null
    sleep 0.5
    kill -0 "$power_pid"
    [ "$(wc -l </tmp/power-policy-attempts)" -ge 2 ]
    [ ! -s /tmp/power/state ]
    [ "$(cat /run/emacsos-ui/power-state)" = blank ]
    [ "$(cat /run/emacsos-ui/power-generation)" = "$generation" ]
    [ "$(wc -l </tmp/swaymsg.log)" -eq $((before + 2)) ]
    printf '%s\n' 0125 >/tmp/modem-controller/usb1/1-1/idProduct
    rm -f /tmp/power-policy-attempts
    wait_policy_attempt
    [ "$(policy_code)" -eq 0 ]
    [ "$(cat /tmp/power/state)" = mem ]
    kill -0 "$power_pid"
    # The actual trusted power input still wakes the panel after the failure.
    python3 - <<'WAKE_AFTER_FAILURE'
import os,struct
fd=os.open('/tmp/wake-input-3',os.O_RDWR|os.O_NONBLOCK)
os.write(fd,struct.pack('@llHHi',0,0,1,116,1));os.close(fd)
WAKE_AFTER_FAILURE
    attempt=0
    while [ "$(cat /run/emacsos-ui/power-state)" != active ]; do
        [ "$attempt" -lt 100 ]; attempt=$((attempt + 1)); sleep 0.02
    done
    kill -0 "$power_pid"
    rm -f /tmp/power-policy-test /tmp/power-policy-attempts
    printf '%s\n' 'Failed suspend retains the reader, dark panel, retry and trusted wake: OK'
fi
kill "$power_pid" 2>/dev/null || true
wait "$power_pid" 2>/dev/null || true
if [ "$queue_guard" -eq 1 ]; then
    python3 /usr/local/share/emacsos-openrc/power-monitor monitor &
else
    su -s /bin/sh emacsos-lab -c 'exec /usr/local/share/emacsos-openrc/session-power monitor' &
fi
power_pid=$!
as_lab wake
if [ "$queue_guard" -eq 1 ]; then
    python3 - "$power_pid" <<'DROP'
from pathlib import Path
import sys
fields=dict(line.split(':',1) for line in Path('/proc/'+sys.argv[1]+'/status').read_text().splitlines() if ':' in line)
assert len(set(fields['Uid'].split())) == 1 and int(fields['Uid'].split()[0]) != 0
assert len(set(fields['Gid'].split())) == 1 and int(fields['Gid'].split()[0]) != 0
assert all(int(fields[name],16)==0 for name in ('CapEff','CapPrm','CapAmb'))
DROP
fi

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

if [ "$queue_guard" -eq 1 ]; then /tmp/suspend-root.test guarded-suspend; else /tmp/suspend-root.test; fi
[ "$(cat /tmp/power/state)" = mem ]
[ "$(cat /tmp/power-key/wakeup)" = enabled ]
[ "$(cat /tmp/axp-power-key/wakeup)" = enabled ]
[ "$(cat /tmp/modem-controller/usb1/1-1/power/wakeup)" = enabled ]
if /tmp/suspend-root.test unexpected >/tmp/root-arg.out 2>&1; then
    printf '%s\n' 'root suspend helper accepted an argument' >&2
    exit 1
fi
grep -F 'unknown guarded action' /tmp/root-arg.out >/dev/null
printf '%s\n' dead >/tmp/modem-controller/usb1/1-1/idProduct
root_action=
[ "$queue_guard" -ne 1 ] || root_action=guarded-suspend
if /tmp/suspend-root.test $root_action >/tmp/root-modem.out 2>&1; then
    printf '%s\n' 'root suspend helper accepted an unexpected modem' >&2
    exit 1
fi
grep -F 'expected EG25 modem is absent' /tmp/root-modem.out >/dev/null
grep -F 'emacsos-openrc-suspend expected EG25 modem is absent' /tmp/root-error.log >/dev/null

# Exercise admission with real kernel guard FDs, helper code and display locks.
# Sway/wtype and doas transport are fixtures. The PM counter/state handshake is
# modeled because ordinary files cannot reject writes on kernel wake events.
printf '%s\n' 0125 >/tmp/modem-controller/usb1/1-1/idProduct
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
elif operation == 'read':
    # Kernel wakeup_count waits for active sources to finish. The production
    # timeout must interrupt this read while wake waits for the display lock.
    while sources():
        time.sleep(0.01)
    print(Path('/tmp/power/wakeup_count').read_text().strip())
elif operation == 'accept':
    if sources() or Path('/tmp/power/wakeup_count').read_text().strip() != sys.argv[2]:
        sys.exit(1)
    Path('/tmp/accepted-wakeup-count').write_text(sys.argv[2])
elif operation == 'submit':
    if sources() or Path('/tmp/power/wakeup_count').read_text().strip() != Path('/tmp/accepted-wakeup-count').read_text():
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
    read = 'timeout -s TERM -k 1 2 ' + read + ' 3>&- 4>&- 5>&- 9>&-'
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

# A plug during admission vetoes sleep even if the first presence check read
# offline. A later completed USB IRQ must invalidate the accepted counter.
for phase in before-accept before-mem; do
    as_lab wake
    printf '%s\n' 0 >/tmp/external-power/online
printf '%s\n' 0 >/tmp/external-power/present
    as_lab press
    : >/tmp/power/state
    printf '%s\n' 42 >/tmp/power/wakeup_count
    printf '%s\n' "$phase" >/tmp/admission-phase
    mkfifo /tmp/admission-continue
    generation=$(cat /run/emacsos-ui/power-generation)
    as_lab suspend "$generation" &
    plug_suspend_pid=$!
    wait_file /tmp/admission-reached
    printf '%s\n' 1 >/tmp/external-power/online
printf '%s\n' 1 >/tmp/external-power/present
    # Before-mem is AFTER the second presence check. Model its completed IRQ
    # counter event; the kernel fence, not another timing check, must reject it.
    [ "$phase" != before-mem ] || printf '%s\n' 43 >/tmp/power/wakeup_count
    printf '%s\n' continue >/tmp/admission-continue
    wait "$plug_suspend_pid"
    [ ! -s /tmp/power/state ]
    [ "$(cat /run/emacsos-ui/power-state)" = blank ]
    printf '%s\n' 0 >/tmp/external-power/online
printf '%s\n' 0 >/tmp/external-power/present
    rm -f /tmp/admission-phase /tmp/admission-reached /tmp/admission-continue
    printf 'Plugged admission %s: OK\n' "$phase"
done

# The IRQ has already advanced the PM count but userspace has not read its
# packet. Freeze the actual worker before enqueue, rather than racing a wake
# callback against admission. A private queue must reject admission by itself.
as_lab wake
as_lab press
: >/tmp/power/state
printf '%s\n' 42 >/tmp/power/wakeup_count
printf '%s\n' before-read >/tmp/admission-phase
mkfifo /tmp/admission-continue
kill -STOP "$power_pid"
python3 - <<'IRQ'
import os, struct
fd=os.open('/tmp/wake-input-5', os.O_RDWR | os.O_NONBLOCK)
os.write(fd, struct.pack('@llHHi', 0, 0, 1, 143, 1)); os.close(fd)
IRQ
generation=$(cat /run/emacsos-ui/power-generation)
as_lab suspend "$generation" &
queued_suspend_pid=$!
wait_file /tmp/admission-reached
printf '%s\n' continue >/tmp/admission-continue
wait "$queued_suspend_pid"
if [ -s /tmp/power/state ]; then
    printf '%s\n' 'queued hardware wake was lost before callback activation' >&2
    exit 1
fi
[ "$(cat /run/emacsos-ui/power-state)" = blank ]
kill -CONT "$power_pid"
attempt=0
while [ "$(cat /run/emacsos-ui/power-state)" != active ]; do
    [ "$attempt" -lt 100 ]; attempt=$((attempt + 1)); sleep 0.02
done
rm -f /tmp/admission-phase /tmp/admission-reached /tmp/admission-continue
printf '%s\n' 'Queued hardware wake before callback activation: OK'

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

# A replacement open of the same fixture inode is a different client. The
# root handoff must reject it through MOD, even though fdinfo inode matches.
python3 - "$power_pid" <<'REPLACEMENT'
import array, json, os, socket, subprocess, sys
sock=socket.socket(socket.AF_UNIX);sock.connect('/tmp/monitor-fds.sock')
sock.sendall(json.dumps([int(sys.argv[1]),'get']).encode())
_,anc,_,_=sock.recvmsg(16,socket.CMSG_SPACE(12));sock.close()
fds=array.array('i');fds.frombytes(anc[0][2])
replacement=os.open('/tmp/wake-input-3',os.O_RDWR|os.O_NONBLOCK)
result=subprocess.run(['/usr/bin/python3','-I','/usr/local/share/emacsos-openrc/power-monitor','handoff'],
                      stdin=fds[1],stdout=replacement,stderr=fds[2])
assert result.returncode != 0, 'different input client passed the handoff'
for fd in [*fds,replacement]:os.close(fd)
REPLACEMENT
printf '%s\n' 'Same-inode replacement wake client rejected: OK'

# Retain pending input in the actual root admission owner after every lab
# owner and the fixture keeper have closed their references.
as_lab wake
as_lab press
: >/tmp/power/state
printf '%s\n' before-read >/tmp/admission-phase
mkfifo /tmp/admission-continue
kill -STOP "$power_pid"
python3 - <<'IRQ'
import os, struct
fd=os.open('/tmp/wake-input-5', os.O_RDWR | os.O_NONBLOCK)
os.write(fd, struct.pack('@llHHi', 0, 0, 1, 143, 1)); os.close(fd)
IRQ
generation=$(cat /run/emacsos-ui/power-generation)
as_lab suspend "$generation" &
queued_suspend_pid=$!
wait_file /tmp/admission-reached
python3 - "$power_pid" <<'RELEASE'
import json,socket,sys
s=socket.socket(socket.AF_UNIX);s.connect('/tmp/monitor-fds.sock')
s.sendall(json.dumps([int(sys.argv[1]),'release']).encode());s.recv(1);s.close()
RELEASE
kill -KILL "$power_pid"
wait "$power_pid" 2>/dev/null || true
[ -n "$(python3 /tmp/kernel-pm-model.py sources)" ]
printf '%s\n' continue >/tmp/admission-continue
wait "$queued_suspend_pid"
[ ! -s /tmp/power/state ]
[ -z "$(python3 /tmp/kernel-pm-model.py sources)" ]
rm -f /tmp/admission-phase /tmp/admission-reached /tmp/admission-continue
# evdev discards an unread client queue when its last owner closes. Drain the
# persistent FIFO endpoint so the next fixture client starts equally empty.
python3 - <<'DRAIN'
import os
fd=os.open('/tmp/wake-input-5', os.O_RDWR | os.O_NONBLOCK)
os.read(fd,4096);os.close(fd)
DRAIN
python3 /usr/local/share/emacsos-openrc/power-monitor monitor &
power_pid=$!
as_lab wake
printf '%s\n' 'Root admission retains queued input after worker KILL: OK'

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
