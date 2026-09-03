#!/bin/sh

set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
deploy_dir=$repo_dir/deploy/pinephone

sh -n "$deploy_dir/openrc-session" \
    "$deploy_dir/openrc-session-power" \
    "$deploy_dir/openrc-process-group" \
    "$deploy_dir/openrc-suspend-root" \
    "$deploy_dir/openrc-boot-mode" \
    "$deploy_dir/openrc-install-root" \
    "$deploy_dir/openrc-bootstrap-root" \
    "$deploy_dir/install-openrc-session.sh" \
    "$deploy_dir/emacsos-ui.initd" \
    "$deploy_dir/waydroid-container-wrapper"

(cd "$deploy_dir" && sha256sum -c openrc-manifest.sha256)
manifest_hash=$(sha256sum "$deploy_dir/openrc-manifest.sha256")
manifest_hash=${manifest_hash%% *}
grep -F "manifest_hash=$manifest_hash" "$deploy_dir/openrc-install-root" >/dev/null
expected='emacsos-ui.initd
openrc-boot-mode
openrc-init.el
openrc-process-group
openrc-session
openrc-session-power
openrc-suspend-root
openrc-sway.config
waydroid-container-wrapper
waydroid-container.conf
waydroid-container.service'
actual=$(cut -d' ' -f3 "$deploy_dir/openrc-manifest.sha256" | sort)
[ "$actual" = "$expected" ]

grep -F 'supervisor=supervise-daemon' "$deploy_dir/emacsos-ui.initd" >/dev/null
grep -F 'command_user=emacsos-lab' "$deploy_dir/emacsos-ui.initd" >/dev/null
grep -F 'XDG_RUNTIME_DIR=/run/emacsos-ui' "$deploy_dir/emacsos-ui.initd" >/dev/null
grep -F 'WLR_BACKENDS=drm,libinput' "$deploy_dir/emacsos-ui.initd" >/dev/null
grep -F 'NO_AT_BRIDGE=1' "$deploy_dir/emacsos-ui.initd" >/dev/null
grep -F 'need localmount seatd cgroups' "$deploy_dir/emacsos-ui.initd" >/dev/null
grep -F 'cgroup=/sys/fs/cgroup/openrc.emacsos-ui' \
    "$deploy_dir/emacsos-ui.initd" >/dev/null
grep -F 'grep -Fx "$$" "$cgroup/cgroup.procs"' \
    "$deploy_dir/emacsos-ui.initd" >/dev/null
grep -F 'input_file=/dev/null' "$deploy_dir/emacsos-ui.initd" >/dev/null
grep -F 'respawn_delay=2' "$deploy_dir/emacsos-ui.initd" >/dev/null
grep -F 'respawn_max=3' "$deploy_dir/emacsos-ui.initd" >/dev/null
grep -F 'respawn_period=60' "$deploy_dir/emacsos-ui.initd" >/dev/null
grep -F 'retry="TERM/20/KILL/5"' "$deploy_dir/emacsos-ui.initd" >/dev/null
grep -F 'group=/sys/fs/cgroup/openrc.emacsos-ui' "$deploy_dir/emacsos-ui.initd" >/dev/null
grep -F 'printf '\''%s\n'\'' "$$" >"$parent/cgroup.procs"' \
    "$deploy_dir/emacsos-ui.initd" >/dev/null
grep -F 'printf '\''%s\n'\'' 1 >"$group/cgroup.kill"' \
    "$deploy_dir/emacsos-ui.initd" >/dev/null
grep -F 'populated 0' "$deploy_dir/emacsos-ui.initd" >/dev/null
move_line=$(grep -nF 'printf '\''%s\n'\'' "$$" >"$parent/cgroup.procs"' \
    "$deploy_dir/emacsos-ui.initd")
move_line=${move_line%%:*}
kill_line=$(grep -nF 'printf '\''%s\n'\'' 1 >"$group/cgroup.kill"' \
    "$deploy_dir/emacsos-ui.initd")
kill_line=${kill_line%%:*}
[ "$move_line" -lt "$kill_line" ]
grep -F '/run/emacsos-openrc-proof' "$deploy_dir/emacsos-ui.initd" >/dev/null
grep -F 'printf '\''%s\n'\'' audio emacsos-lab seat video' "$deploy_dir/emacsos-ui.initd" >/dev/null
if grep -F '/usr/bin/dbus-run-session' "$deploy_dir/emacsos-ui.initd" >/dev/null; then
    printf '%s\n' 'OpenRC service unexpectedly wraps the session D-Bus' >&2
    exit 1
fi

grep -F '[ "$runtime" = /run/emacsos-ui ]' "$deploy_dir/openrc-session" >/dev/null
grep -F '[ -S /run/seatd.sock ]' "$deploy_dir/openrc-session" >/dev/null
grep -F "fail 'multiple Wayland sockets appeared'" "$deploy_dir/openrc-session" >/dev/null
grep -F "fail 'multiple Sway sockets appeared'" "$deploy_dir/openrc-session" >/dev/null
grep -F 'probe_sway get_inputs' "$deploy_dir/openrc-session" >/dev/null
grep -F 'timeout -s TERM -k 1 3 swaymsg' "$deploy_dir/openrc-session" >/dev/null
grep -F 'timeout -s TERM -k 1 3 emacsclient' "$deploy_dir/openrc-session" >/dev/null
grep -F 'Goodix Capacitive TouchScreen' "$deploy_dir/openrc-session" >/dev/null
grep -F '/usr/bin/wvkbd-mobintl -H 300 -L 300' "$deploy_dir/openrc-session" >/dev/null
grep -F '/usr/bin/pipewire-pulse &' "$deploy_dir/openrc-session" >/dev/null
grep -F -- '--dest=org.freedesktop.DBus /org/freedesktop/DBus' \
    "$deploy_dir/openrc-session" >/dev/null
grep -F 'org.freedesktop.DBus.NameHasOwner string:id.waydro.Container' \
    "$deploy_dir/openrc-session" >/dev/null
grep -F 'waydroid session stop' "$deploy_dir/openrc-session" >/dev/null
grep -F 'killall -q at-spi-bus-launcher at-spi2-registryd' \
    "$deploy_dir/openrc-session" >/dev/null
grep -F '/usr/bin/dbus-daemon --session --nofork --nopidfile --print-address=3' \
    "$deploy_dir/openrc-session" >/dev/null
grep -F 'PulseAudio-compatible socket did not appear' "$deploy_dir/openrc-session" >/dev/null
grep -F 'printf '\''%s\n'\'' ready >"$runtime/.ready.tmp"' "$deploy_dir/openrc-session" >/dev/null
grep -F 'mv -- "$runtime/.ready.tmp" "$runtime/ready"' "$deploy_dir/openrc-session" >/dev/null
grep -F 'rm -f -- "$sway_socket"' "$deploy_dir/openrc-session" >/dev/null
grep -F 'rm -f -- "$wayland_socket" "${wayland_socket}.lock"' "$deploy_dir/openrc-session" >/dev/null
if grep -F '/run/user/' "$deploy_dir/openrc-session" \
        "$deploy_dir/emacsos-ui.initd" >/dev/null; then
    printf '%s\n' 'OpenRC session unexpectedly uses a login runtime' >&2
    exit 1
fi
grep -F 'timeout -s TERM -k 1 3 swaymsg' "$deploy_dir/openrc-session-power" >/dev/null
grep -F '/usr/bin/swayidle -w' "$deploy_dir/openrc-session" >/dev/null
grep -F '"$root/process-group" /usr/bin/swayidle -w' \
    "$deploy_dir/openrc-session" >/dev/null
grep -F '/usr/bin/setsid "$@" &' "$deploy_dir/openrc-process-group" >/dev/null
grep -F 'kill -TERM "-$leader"' "$deploy_dir/openrc-process-group" >/dev/null
grep -F 'while group_has_process' "$deploy_dir/openrc-process-group" >/dev/null
grep -F 'timeout 60 "$root/session-power idle-blank"' "$deploy_dir/openrc-session" >/dev/null
grep -F 'timeout 180 "$root/session-power suspend"' "$deploy_dir/openrc-session" >/dev/null
grep -F 'press|idle-blank|wake|suspend' "$deploy_dir/openrc-session-power" >/dev/null
grep -F 'flock -w 2 -x 9' "$deploy_dir/openrc-session-power" >/dev/null
grep -F 'doas -n /usr/local/sbin/emacsos-openrc-suspend' \
    "$deploy_dir/openrc-session-power" >/dev/null
grep -F 'power=/sys/power' "$deploy_dir/openrc-suspend-root" >/dev/null
grep -F "grep -F '[deep]' \"\$power/mem_sleep\"" \
    "$deploy_dir/openrc-suspend-root" >/dev/null
grep -F 'printf '\''%s\n'\'' "$wakeup_count" >"$power/wakeup_count"' \
    "$deploy_dir/openrc-suspend-root" >/dev/null
grep -F 'printf '\''%s\n'\'' mem >"$power/state"' \
    "$deploy_dir/openrc-suspend-root" >/dev/null
if grep -F '${POWER' "$deploy_dir/openrc-suspend-root" >/dev/null; then
    printf '%s\n' 'root suspend helper accepts a power-path override' >&2
    exit 1
fi
if grep -E 'after-resume|before-sleep|[[:space:]]resume[[:space:]]' \
        "$deploy_dir/openrc-session" >/dev/null; then
    printf '%s\n' 'swayidle has a competing wake callback' >&2
    exit 1
fi

grep -F "line='tty1::respawn:/sbin/getty 38400 tty1'" "$deploy_dir/openrc-boot-mode" >/dev/null
grep -F "marker='# emacsos-openrc owns tty1'" "$deploy_dir/openrc-boot-mode" >/dev/null
grep -F 'case $1 in initialize|ui|console|status)' "$deploy_dir/openrc-boot-mode" >/dev/null
grep -F 'current inittab matches neither saved state' "$deploy_dir/openrc-boot-mode" >/dev/null
grep -F 'rc-service emacsos-ui stop' "$deploy_dir/openrc-boot-mode" >/dev/null
grep -F 'rc-update del emacsos-ui default' "$deploy_dir/openrc-boot-mode" >/dev/null
grep -F 'replace_inittab "$state/inittab.original"' "$deploy_dir/openrc-boot-mode" >/dev/null
grep -F 'restart_ui_on_rollback=1' "$deploy_dir/openrc-boot-mode" >/dev/null
grep -F "fail 'lab account group set is unsafe'" "$deploy_dir/openrc-boot-mode" >/dev/null

grep -F '[ "${SUDO_USER-}" = user ]' "$deploy_dir/openrc-install-root" >/dev/null
grep -F 'unexpected staged file' "$deploy_dir/openrc-install-root" >/dev/null
grep -F 'mutating=1' "$deploy_dir/openrc-install-root" >/dev/null
grep -F "fail 'lab account group set is unsafe'" "$deploy_dir/openrc-install-root" >/dev/null
grep -F '/run/emacsos-openrc-proof' "$deploy_dir/openrc-install-root" >/dev/null
grep -F 'apk add --simulate "$@"' "$deploy_dir/openrc-install-root" >/dev/null
grep -F 'permit nopass emacsos-lab as root cmd /usr/local/sbin/emacsos-openrc-suspend args' \
    "$deploy_dir/openrc-install-root" >/dev/null
grep -F 'rc-service emacsos-ui start' "$deploy_dir/openrc-install-root" >/dev/null
grep -F '/usr/local/sbin/emacsos-openrc-boot-mode initialize' "$deploy_dir/openrc-install-root" >/dev/null
grep -F 'expected=@@ADMIN_SHA256@@' "$deploy_dir/openrc-bootstrap-root" >/dev/null
grep -F 'timeout -s TERM -k 1 10 sh -c' "$deploy_dir/openrc-bootstrap-root" >/dev/null
grep -F 'timeout -s TERM -k 1 10 sh -c' "$deploy_dir/openrc-install-root" >/dev/null
if grep -F 'cp -P' "$deploy_dir/openrc-bootstrap-root" \
        "$deploy_dir/openrc-install-root" >/dev/null; then
    printf '%s\n' 'installer follows staged symlinks' >&2
    exit 1
fi
grep -F 'phone_host=${PINEPHONE_HOST:?' "$deploy_dir/install-openrc-session.sh" >/dev/null
grep -F 'PasswordAuthentication=no' "$deploy_dir/install-openrc-session.sh" >/dev/null

grep -F 'Exec=/usr/local/libexec/emacsos-waydroid-container' \
    "$deploy_dir/waydroid-container.service" >/dev/null
grep -F '<deny send_destination="id.waydro.Container"/>' \
    "$deploy_dir/waydroid-container.conf" >/dev/null
grep -F '<policy user="emacsos-lab">' \
    "$deploy_dir/waydroid-container.conf" >/dev/null
grep -F '/usr/bin/waydroid -w container start &' \
    "$deploy_dir/waydroid-container-wrapper" >/dev/null
grep -F '/usr/bin/waydroid -w container stop' \
    "$deploy_dir/waydroid-container-wrapper" >/dev/null
grep -F "expected=\$(printf '%s\\n' python3 /usr/bin/waydroid show-full-ui)" \
    "$deploy_dir/waydroid-container-wrapper" >/dev/null

grep -F 'output DSI-1 mode 720x1440@60Hz scale 2' "$deploy_dir/openrc-sway.config" >/dev/null
grep -F 'input type:touch map_to_output DSI-1' "$deploy_dir/openrc-sway.config" >/dev/null
grep -F 'bindsym Mod1+Tab focus next' "$deploy_dir/openrc-sway.config" >/dev/null
grep -F 'bindsym XF86PowerOff exec $power press' "$deploy_dir/openrc-sway.config" >/dev/null
if grep -F 'exec $power toggle' "$deploy_dir/openrc-sway.config" >/dev/null; then
    printf '%s\n' 'power key still uses a racy toggle' >&2
    exit 1
fi
grep -F 'for_window [app_id="firefox"] focus' "$deploy_dir/openrc-sway.config" >/dev/null

grep -F '"--new-instance" "about:blank"' "$deploy_dir/openrc-init.el" >/dev/null
if grep -Eq '/home/|192\.168\.' \
        "$deploy_dir/openrc-init.el" \
        "$deploy_dir/openrc-session" \
        "$deploy_dir/openrc-session-power" \
        "$deploy_dir/openrc-process-group" \
        "$deploy_dir/openrc-suspend-root" \
        "$deploy_dir/openrc-sway.config" \
        "$deploy_dir/emacsos-ui.initd"; then
    printf '%s\n' 'OpenRC payload contains operator-specific data' >&2
    exit 1
fi
