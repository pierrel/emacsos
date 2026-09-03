#!/bin/sh

set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

docker run --rm --network none -i \
    -v "$repo_dir/deploy/pinephone/openrc-session-power:/source/session-power:ro" \
    -v "$repo_dir/deploy/pinephone/openrc-suspend-root:/source/suspend-root:ro" \
    -v "$repo_dir/deploy/pinephone/openrc-process-group:/source/process-group:ro" \
    python:3.13-alpine /bin/sh -s <<'CONTAINER'
set -eu

addgroup -S emacsos-lab
adduser -S -D -H -h /var/lib/emacsos-lab -s /sbin/nologin \
    -G emacsos-lab emacsos-lab
install -d -o emacsos-lab -g emacsos-lab -m 0700 \
    /run/emacsos-ui /var/lib/emacsos-lab /usr/local/share/emacsos-openrc
install -o root -g root -m 0755 /source/session-power \
    /usr/local/share/emacsos-openrc/session-power
install -o root -g root -m 0755 /source/process-group \
    /usr/local/share/emacsos-openrc/process-group
sed 's|^power=/sys/power$|power=/tmp/power|' /source/suspend-root \
    >/tmp/suspend-root.test
chmod 0755 /tmp/suspend-root.test

mv /usr/bin/flock /usr/bin/flock.real
printf '%s\n' \
    '#!/bin/sh' \
    '[ "$1" = -w ] && shift 2' \
    'exec /bin/busybox flock "$@"' >/usr/bin/flock
chmod 0755 /usr/bin/flock
rm -f /usr/bin/timeout
printf '%s\n' \
    '#!/bin/sh' \
    'while [ "$#" -gt 0 ]; do' \
    '  case $1 in -s|-k) shift 2 ;; [0-9]*) shift; break ;; *) break ;; esac' \
    'done' \
    'exec "$@"' >/usr/bin/timeout
chmod 0755 /usr/bin/timeout
printf '%s\n' \
    '#!/bin/sh' \
    '[ "$1" = -n ] || exit 64' \
    'shift' \
    '[ "$#" -eq 1 ] && [ "$1" = /usr/local/sbin/emacsos-openrc-suspend ] || exit 64' \
    'printf "%s\n" "$1" >>/tmp/doas.log' \
    'if [ -e /tmp/block-suspend ]; then' \
    '  touch /tmp/suspend-reached' \
    '  read answer </tmp/suspend-continue' \
    'fi' \
    'exit "$(cat /tmp/suspend-status)"' >/usr/bin/doas
chmod 0755 /usr/bin/doas

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
    'python3 -c "import socket,time; a=socket.socket(socket.AF_UNIX); a.bind('\''/run/emacsos-ui/sway-ipc.test.sock'\''); b=socket.socket(socket.AF_UNIX); b.bind('\''/run/emacsos-ui/wayland-test'\''); time.sleep(30)"' &
socket_pid=$!
trap 'kill "$socket_pid" 2>/dev/null || true' EXIT
attempt=0
while [ ! -S /run/emacsos-ui/sway-ipc.test.sock ] ||
      [ ! -S /run/emacsos-ui/wayland-test ]; do
    [ "$attempt" -lt 20 ]
    attempt=$((attempt + 1))
    sleep 0.05
done

as_lab() {
    su -s /bin/sh emacsos-lab -c \
        "/usr/local/share/emacsos-openrc/session-power $1"
}

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

before=$(wc -l </tmp/swaymsg.log)
as_lab idle-blank
[ "$(wc -l </tmp/swaymsg.log)" -eq "$before" ]

# A power key that resumes an idle-blanked seat launches both callbacks.  They
# must finish active regardless of which one owns the transition lock first.
mkfifo /tmp/wtype-continue
touch /tmp/block-wtype
as_lab resume &
resume_first_pid=$!
attempt=0
while [ ! -e /tmp/wtype-reached ]; do
    [ "$attempt" -lt 20 ]
    attempt=$((attempt + 1))
    sleep 0.05
done
as_lab press &
press_second_pid=$!
printf '%s\n' continue >/tmp/wtype-continue
wait "$resume_first_pid"
wait "$press_second_pid"
[ "$(cat /run/emacsos-ui/power-state)" = active ]
rm -f /tmp/block-wtype /tmp/wtype-continue /tmp/wtype-reached

as_lab press
as_lab idle-blank
mkfifo /tmp/wtype-continue
touch /tmp/block-wtype
as_lab press &
press_first_pid=$!
attempt=0
while [ ! -e /tmp/wtype-reached ]; do
    [ "$attempt" -lt 20 ]
    attempt=$((attempt + 1))
    sleep 0.05
done
as_lab resume &
resume_second_pid=$!
printf '%s\n' continue >/tmp/wtype-continue
wait "$press_first_pid"
wait "$resume_second_pid"
[ "$(cat /run/emacsos-ui/power-state)" = active ]
rm -f /tmp/block-wtype /tmp/wtype-continue /tmp/wtype-reached

# A volume key can produce resume without a power-key press.  Its Sway binding
# follows with explicit wake, which clears idle origin before a later press.
as_lab press
as_lab idle-blank
as_lab resume
[ "$(cat /run/emacsos-ui/power-state)" = active ]
as_lab wake
as_lab press
[ "$(cat /run/emacsos-ui/power-state)" = blank ]
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

as_lab press
[ "$(cat /run/emacsos-ui/power-state)" = blank ]

printf '%s\n' 0 >/tmp/suspend-status
as_lab suspend
[ "$(cat /run/emacsos-ui/power-state)" = blank ]
[ "$(sed -n '1p' /tmp/doas.log)" = \
    /usr/local/sbin/emacsos-openrc-suspend ]
as_lab press
[ "$(cat /run/emacsos-ui/power-state)" = active ]

as_lab press
printf '%s\n' 75 >/tmp/suspend-status
as_lab suspend
[ "$(cat /run/emacsos-ui/power-state)" = blank ]
as_lab press
[ "$(cat /run/emacsos-ui/power-state)" = active ]

as_lab press
printf '%s\n' 1 >/tmp/suspend-status
if as_lab suspend >/tmp/suspend-failure.out 2>&1; then
    printf '%s\n' 'root suspend failure was accepted' >&2
    exit 1
fi
[ "$(cat /run/emacsos-ui/power-state)" = active ]

as_lab press
printf '%s\n' 0 >/tmp/suspend-status
mkfifo /tmp/suspend-continue
touch /tmp/block-suspend
as_lab suspend &
blocking_suspend_pid=$!
attempt=0
while [ ! -e /tmp/suspend-reached ]; do
    [ "$attempt" -lt 20 ]
    attempt=$((attempt + 1))
    sleep 0.05
done
as_lab press &
waiting_press_pid=$!
sleep 2.2
kill -0 "$waiting_press_pid"
printf '%s\n' continue >/tmp/suspend-continue
wait "$blocking_suspend_pid"
wait "$waiting_press_pid"
[ "$(cat /run/emacsos-ui/power-state)" = active ]
rm -f /tmp/block-suspend /tmp/suspend-continue /tmp/suspend-reached

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
    'python3 -c "import socket,time; s=socket.socket(socket.AF_UNIX); s.bind('\''/run/emacsos-ui/sway-ipc.extra.sock'\''); time.sleep(30)"' &
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
    'python3 -c "import socket,time; s=socket.socket(socket.AF_UNIX); s.bind('\''/run/emacsos-ui/wayland-extra'\''); time.sleep(30)"' &
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

install -d -m 0755 /tmp/power
printf '%s\n' 's2idle [deep]' >/tmp/power/mem_sleep
printf '%s\n' 1 >/tmp/power/sync_on_suspend
printf '%s\n' 41 >/tmp/power/wakeup_count
: >/tmp/power/state
/tmp/suspend-root.test
[ "$(cat /tmp/power/wakeup_count)" = 41 ]
[ "$(cat /tmp/power/state)" = mem ]

rm -f /tmp/power/wakeup_count /tmp/power/state
mkfifo /tmp/power/wakeup_count
ln -s /dev/full /tmp/power/state
{
    printf '%s\n' 41 >/tmp/power/wakeup_count
    IFS= read -r handshake </tmp/power/wakeup_count
    [ "$handshake" = 41 ]
    printf '%s\n' 41 >/tmp/power/wakeup_count
} &
wakeup_controller_pid=$!
set +e
/tmp/suspend-root.test >/tmp/root-state-failure.out 2>&1
state_failure_status=$?
set -e
wait "$wakeup_controller_pid"
[ "$state_failure_status" -eq 1 ]

rm -f /tmp/power/wakeup_count
mkfifo /tmp/power/wakeup_count
{
    printf '%s\n' 41 >/tmp/power/wakeup_count
    IFS= read -r handshake </tmp/power/wakeup_count
    [ "$handshake" = 41 ]
    printf '%s\n' 42 >/tmp/power/wakeup_count
} &
wakeup_controller_pid=$!
set +e
/tmp/suspend-root.test >/tmp/root-state-race.out 2>&1
state_race_status=$?
set -e
wait "$wakeup_controller_pid"
[ "$state_race_status" -eq 75 ]

if /tmp/suspend-root.test unexpected >/tmp/root-arg.out 2>&1; then
    printf '%s\n' 'root suspend helper accepted an argument' >&2
    exit 1
fi
grep -F 'arguments are not accepted' /tmp/root-arg.out >/dev/null
if su -s /bin/sh emacsos-lab -c /tmp/suspend-root.test \
        >/tmp/root-user.out 2>&1; then
    printf '%s\n' 'root suspend helper accepted an unprivileged caller' >&2
    exit 1
fi
grep -F 'must run as root' /tmp/root-user.out >/dev/null

rm -f /tmp/power/wakeup_count /tmp/power/state
printf '%s\n' 41 >/tmp/power/wakeup_count
: >/tmp/power/state
printf '%s\n' '[s2idle] deep' >/tmp/power/mem_sleep
if /tmp/suspend-root.test >/tmp/root-s2idle.out 2>&1; then
    printf '%s\n' 'root suspend helper accepted s2idle' >&2
    exit 1
fi
grep -F 'deep suspend is not selected' /tmp/root-s2idle.out >/dev/null
printf '%s\n' 's2idle [deep]' >/tmp/power/mem_sleep

printf '%s\n' 0 >/tmp/power/sync_on_suspend
if /tmp/suspend-root.test >/tmp/root-sync.out 2>&1; then
    printf '%s\n' 'root suspend helper accepted disabled kernel syncing' >&2
    exit 1
fi
grep -F 'kernel suspend syncing is disabled' /tmp/root-sync.out >/dev/null
printf '%s\n' 1 >/tmp/power/sync_on_suspend

rm -f /tmp/power/state
mkfifo /tmp/power/state
/tmp/suspend-root.test &
suspend_pid=$!
sleep 0.1
if /tmp/suspend-root.test >/tmp/root-concurrent.out 2>&1; then
    printf '%s\n' 'concurrent root suspend was accepted' >&2
    exit 1
fi
grep -F 'suspend is already in progress' /tmp/root-concurrent.out >/dev/null
dd if=/tmp/power/state of=/tmp/state-write bs=4 count=1 status=none &
reader_pid=$!
wait "$suspend_pid"
wait "$reader_pid"
[ "$(cat /tmp/state-write)" = mem ]

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

printf '%s\n' 'OpenRC power state machine: OK'
CONTAINER
