#!/bin/sh

set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
deploy_dir=$repo_dir/deploy/pinephone

sh -n "$deploy_dir/openrc-session" \
    "$deploy_dir/openrc-session-power" \
    "$deploy_dir/openrc-process-group" \
    "$deploy_dir/openrc-call-root" \
    "$deploy_dir/openrc-network-root" \
    "$deploy_dir/openrc-boot-mode" \
    "$deploy_dir/openrc-install-root" \
    "$deploy_dir/openrc-update-root" \
    "$deploy_dir/openrc-bootstrap-root" \
    "$deploy_dir/install-openrc-session.sh" \
    "$deploy_dir/update-openrc-session.sh" \
    "$deploy_dir/emacsos-ui.initd" \
    "$deploy_dir/waydroid-container-wrapper"

manifest_stage=$(mktemp -d)
trap 'rm -rf -- "$manifest_stage"' EXIT HUP INT TERM
for name in openrc-init.el openrc-sway.config openrc-session \
    openrc-session-power openrc-process-group \
    openrc-call-root openrc-network-root openrc-chat-url openrc-emacs-server.nft \
    emacsos-ui.initd openrc-boot-mode waydroid-container.service \
    waydroid-container.conf waydroid-container-wrapper; do
    cp -- "$deploy_dir/$name" "$manifest_stage/$name"
done
for name in os.el chat.el emacos-assist.el network.el phone-call.el; do
    cp -- "$repo_dir/$name" "$manifest_stage/$name"
done
cp -- "$deploy_dir/openrc-manifest.sha256" "$manifest_stage/"
(cd "$manifest_stage" && sha256sum -c openrc-manifest.sha256)
manifest_hash=$(sha256sum "$deploy_dir/openrc-manifest.sha256")
manifest_hash=${manifest_hash%% *}
grep -F "manifest_hash=$manifest_hash" "$deploy_dir/openrc-install-root" >/dev/null
grep -F "manifest_hash=$manifest_hash" "$deploy_dir/openrc-update-root" >/dev/null
expected='chat.el
emacos-assist.el
emacsos-ui.initd
network.el
openrc-boot-mode
openrc-call-root
openrc-chat-url
openrc-emacs-server.nft
openrc-init.el
openrc-network-root
openrc-process-group
openrc-session
openrc-session-power
openrc-sway.config
os.el
phone-call.el
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
grep -F -- '--server-file=/var/lib/emacsos-lab/.emacs.d/server/emacsos-openrc' \
    "$deploy_dir/openrc-session" >/dev/null
grep -F 'rm -f -- "$runtime/failure"' \
    "$deploy_dir/openrc-session" >/dev/null
grep -F 'grep -Fx t "$probe_file"' "$deploy_dir/openrc-session" >/dev/null
grep -F 'Goodix Capacitive TouchScreen' "$deploy_dir/openrc-session" >/dev/null
grep -F '/usr/bin/wvkbd-mobintl -H 300 -L 300' "$deploy_dir/openrc-session" >/dev/null
grep -F 'emacos-call-control-gap-lines 1' "$deploy_dir/openrc-init.el" >/dev/null
grep -F 'timeout -s TERM -k 1 3 /usr/bin/wtype -k F24' \
    "$deploy_dir/openrc-session-power" >/dev/null
grep -F 'bindsym F24 nop' "$deploy_dir/openrc-sway.config" >/dev/null
grep -F '/usr/bin/pipewire-pulse &' "$deploy_dir/openrc-session" >/dev/null
grep -F '/usr/bin/alsaucm -c PinePhone set _fboot ""' \
    "$deploy_dir/openrc-session" >/dev/null
grep -F '/usr/bin/alsaucm -c PinePhone set _boot ""' \
    "$deploy_dir/openrc-session" >/dev/null
ucm_line=$(grep -nF '/usr/bin/alsaucm -c PinePhone set _boot ""' \
    "$deploy_dir/openrc-session")
ucm_line=${ucm_line%%:*}
pipewire_line=$(grep -nF '/usr/bin/pipewire &' "$deploy_dir/openrc-session")
pipewire_line=${pipewire_line%%:*}
[ "$ucm_line" -lt "$pipewire_line" ]
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
grep -F '>"$runtime/failure"' "$deploy_dir/openrc-session" >/dev/null
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
grep -F 'resume "$root/session-power resume"' "$deploy_dir/openrc-session" >/dev/null
if grep -E 'session-power suspend|/sys/power/(state|mem_sleep)|openrc-suspend' \
        "$deploy_dir/openrc-session" \
        "$deploy_dir/openrc-session-power" >/dev/null; then
    printf '%s\n' 'the unattended session retains a suspend path' >&2
    exit 1
fi
grep -F 'press|idle-blank|resume|wake)' \
    "$deploy_dir/openrc-session-power" >/dev/null
grep -F 'idle-blank) flock -n -x 9' "$deploy_dir/openrc-session-power" >/dev/null
grep -F 'timeout -s TERM -k 1 3 /usr/bin/wtype -k F24' \
    "$deploy_dir/openrc-session-power" >/dev/null
[ ! -e "$deploy_dir/openrc-suspend-root" ]
if grep -E 'after-resume|before-sleep' \
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
grep -F 'rc-service emacsos-ui start 8>&- 9>&-' \
    "$deploy_dir/openrc-boot-mode" >/dev/null
grep -F "fail 'lab account group set is unsafe'" "$deploy_dir/openrc-boot-mode" >/dev/null

grep -F '[ "${SUDO_USER-}" = user ]' "$deploy_dir/openrc-install-root" >/dev/null
grep -F 'unexpected staged file' "$deploy_dir/openrc-install-root" >/dev/null
grep -F 'mutating=1' "$deploy_dir/openrc-install-root" >/dev/null
grep -F "fail 'lab account group set is unsafe'" "$deploy_dir/openrc-install-root" >/dev/null
grep -F '/run/emacsos-openrc-proof' "$deploy_dir/openrc-install-root" >/dev/null
grep -F 'apk add --simulate "$@"' "$deploy_dir/openrc-install-root" >/dev/null
grep -F 'pinephone-callaudiod alsa-utils' \
    "$deploy_dir/openrc-install-root" >/dev/null
grep -F 'rc-update add eg25-manager default' \
    "$deploy_dir/openrc-install-root" >/dev/null
grep -F 'rc-update add modemmanager default' \
    "$deploy_dir/openrc-install-root" >/dev/null
grep -F 'timeout -s TERM -k 2 30 rc-service eg25-manager start' \
    "$deploy_dir/openrc-install-root" >/dev/null
grep -F 'timeout -s TERM -k 2 30 rc-service modemmanager start' \
    "$deploy_dir/openrc-install-root" >/dev/null
grep -F 'timeout -s TERM -k 2 30 rc-service eg25-manager stop' \
    "$deploy_dir/openrc-install-root" >/dev/null
grep -F 'timeout -s TERM -k 2 30 rc-service modemmanager stop' \
    "$deploy_dir/openrc-install-root" >/dev/null
grep -F 'permit nopass emacsos-lab as root cmd /usr/local/sbin/emacsos-openrc-call' \
    "$deploy_dir/openrc-install-root" >/dev/null
grep -F 'permit nopass emacsos-lab as root cmd /usr/local/sbin/emacsos-openrc-network' \
    "$deploy_dir/openrc-install-root" >/dev/null
grep -F "case \$digits in ''|*[!0-9]*)" "$deploy_dir/openrc-call-root" >/dev/null
grep -F "case \$call_id in ''|*[!0-9]*)" "$deploy_dir/openrc-call-root" >/dev/null
grep -F 'ulimit -f 128' "$deploy_dir/openrc-call-root" >/dev/null
grep -F 'timeout -s TERM -k 1 12 /usr/bin/mmcli' \
    "$deploy_dir/openrc-call-root" >/dev/null
grep -F 'flock -n -x 9' "$deploy_dir/openrc-call-root" >/dev/null
grep -F 'timeout -s TERM -k 1 20 /usr/bin/nmcli' \
    "$deploy_dir/openrc-network-root" >/dev/null
grep -F 'flock -n -x 9' "$deploy_dir/openrc-network-root" >/dev/null
grep -F 'rc-service emacsos-ui start' "$deploy_dir/openrc-install-root" >/dev/null
grep -F '/usr/local/sbin/emacsos-openrc-boot-mode initialize' "$deploy_dir/openrc-install-root" >/dev/null
grep -F 'expected=@@ADMIN_SHA256@@' "$deploy_dir/openrc-bootstrap-root" >/dev/null
grep -F 'timeout -s TERM -k 1 10 sh -c' "$deploy_dir/openrc-bootstrap-root" >/dev/null
grep -F 'timeout -s TERM -k 1 10 sh -c' "$deploy_dir/openrc-install-root" >/dev/null
grep -F "count=\$(grep -Fo '@DEPLOY_CLIENT_IP@'" \
    "$deploy_dir/openrc-install-root" "$deploy_dir/openrc-update-root" >/dev/null
grep -F 'deploy_client_ip=${SSH_CONNECTION%% *}' \
    "$deploy_dir/install-openrc-session.sh" \
    "$deploy_dir/update-openrc-session.sh" >/dev/null
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
grep -F 'bindsym XF86AudioRaiseVolume exec $power wake' \
    "$deploy_dir/openrc-sway.config" >/dev/null
grep -F 'bindsym XF86AudioLowerVolume exec $power wake' \
    "$deploy_dir/openrc-sway.config" >/dev/null
if grep -F 'exec $power toggle' "$deploy_dir/openrc-sway.config" >/dev/null; then
    printf '%s\n' 'power key still uses a racy toggle' >&2
    exit 1
fi
grep -F 'for_window [app_id="firefox"] focus' "$deploy_dir/openrc-sway.config" >/dev/null

grep -F '"--new-instance" "about:blank"' "$deploy_dir/openrc-init.el" >/dev/null
grep -F 'emacos-use-internal-keyboard nil' "$deploy_dir/openrc-init.el" >/dev/null
grep -F 'emacos-initial-buffer-function #'"'"'emacos--chat-buffer' \
    "$deploy_dir/openrc-init.el" >/dev/null
grep -F 'server-port 8766' "$deploy_dir/openrc-init.el" >/dev/null
grep -F 'make-process' "$deploy_dir/openrc-init.el" >/dev/null
if grep -Eq '/home/|192\.168\.' \
        "$deploy_dir/openrc-init.el" \
        "$deploy_dir/openrc-session" \
        "$deploy_dir/openrc-session-power" \
        "$deploy_dir/openrc-process-group" \
        "$deploy_dir/openrc-sway.config" \
        "$deploy_dir/openrc-chat-url" \
        "$deploy_dir/openrc-emacs-server.nft" \
        "$deploy_dir/emacsos-ui.initd"; then
    printf '%s\n' 'OpenRC payload contains operator-specific data' >&2
    exit 1
fi

grep -F '[ "${SUDO_USER-}" = user ]' "$deploy_dir/openrc-update-root" >/dev/null
grep -F 'flock -n -x 9' "$deploy_dir/openrc-update-root" >/dev/null
grep -F 'rc-service emacsos-ui start 8>&- 9>&-' "$deploy_dir/openrc-update-root" >/dev/null
grep -F 'timeout -s TERM -k 5 30 rc-service emacsos-ui stop 8>&- 9>&-' \
    "$deploy_dir/openrc-update-root" >/dev/null
grep -F 'timeout -s TERM -k 5 30 rc-service emacsos-ui start 8>&- 9>&-' \
    "$deploy_dir/openrc-update-root" >/dev/null
grep -F "grep -Fx 'populated 0'" "$deploy_dir/openrc-update-root" >/dev/null
grep -F 'pgrep -u "$lab_uid"' "$deploy_dir/openrc-update-root" >/dev/null
grep -F 'rollback refused while UI remains active' \
    "$deploy_dir/openrc-update-root" >/dev/null
grep -F '/etc/nftables.d/49-emacsos-callback.nft' \
    "$deploy_dir/openrc-install-root" "$deploy_dir/openrc-update-root" >/dev/null
grep -F 'rm -f -- /etc/nftables.d/95-emacsos-callback.nft' \
    "$deploy_dir/openrc-update-root" >/dev/null
grep -F 'tcp dport 8766 drop' "$deploy_dir/openrc-emacs-server.nft" >/dev/null
grep -F "manifest_hash=$manifest_hash" "$deploy_dir/openrc-update-root" >/dev/null
grep -F 'updated UI did not become ready: $detail' \
    "$deploy_dir/openrc-update-root" >/dev/null
grep -F 'restore_file openrc-session' "$deploy_dir/openrc-update-root" >/dev/null
grep -F 'sync -f /etc/doas.d' "$deploy_dir/openrc-update-root" >/dev/null
grep -F 'sync -f /usr/local/sbin' "$deploy_dir/openrc-update-root" >/dev/null
rule_remove_line=$(grep -nF \
    'rm -f -- /etc/doas.d/95-emacsos-ui-suspend.conf' \
    "$deploy_dir/openrc-update-root" | tail -1)
rule_remove_line=${rule_remove_line%%:*}
helper_remove_line=$(grep -nF \
    'rm -f -- /usr/local/sbin/emacsos-openrc-suspend' \
    "$deploy_dir/openrc-update-root" | tail -1)
helper_remove_line=${helper_remove_line%%:*}
doas_install_line=$(grep -nF \
    'mv -f -- "$doas_tmp" /etc/doas.d/95-emacsos-ui.conf' \
    "$deploy_dir/openrc-update-root")
doas_install_line=${doas_install_line%%:*}
boot_install_line=$(grep -nF \
    'mv -f -- "$boot_tmp" /usr/local/sbin/emacsos-openrc-boot-mode' \
    "$deploy_dir/openrc-update-root")
boot_install_line=${boot_install_line%%:*}
[ "$rule_remove_line" -lt "$helper_remove_line" ]
[ "$helper_remove_line" -lt "$doas_install_line" ]
[ "$doas_install_line" -lt "$boot_install_line" ]
grep -F '/usr/sbin/nft -f /etc/nftables.nft' \
    "$deploy_dir/openrc-update-root" >/dev/null
