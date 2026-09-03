#!/bin/sh

set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

docker run --rm --network none -i \
    -v "$repo_dir/deploy/pinephone:/source:ro" \
    -v "$repo_dir:/repo:ro" \
    alpine:3.22 /bin/sh -s <<'CONTAINER'
set -eu

addgroup -S user
adduser -S -D -H -h /home/user -s /bin/sh -G user user
install -d -o user -g user -m 0700 /home/user /home/user/.cache \
    /home/user/.cache/emacsos-openrc-stage
for name in openrc-manifest.sha256 openrc-init.el openrc-sway.config \
    openrc-session openrc-session-power openrc-process-group openrc-suspend-root \
    openrc-call-root openrc-network-root openrc-chat-url openrc-emacs-server.nft \
    emacsos-ui.initd openrc-boot-mode waydroid-container.service \
    waydroid-container.conf \
    waydroid-container-wrapper; do
    install -o user -g user -m 0600 "/source/$name" \
        "/home/user/.cache/emacsos-openrc-stage/$name"
done
for name in os.el chat.el emacos-assist.el network.el phone-call.el; do
    install -o user -g user -m 0600 "/repo/$name" \
        "/home/user/.cache/emacsos-openrc-stage/$name"
done

printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "apk $*" >>/tmp/apk-log' 'exit 0' \
    >/usr/bin/apk
printf '%s\n' '#!/bin/sh' \
    'printf "%s\\n" "rc-service $*" >>/tmp/rc-service-log' \
    'if [ "$1 $2" = "seatd status" ]; then' \
    '  [ -e /tmp/seatd-running ]; exit $?' \
    'elif [ "$1 $2" = "seatd start" ]; then' \
    '  touch /tmp/seatd-running' \
    'elif [ "$1 $2" = "seatd stop" ]; then' \
    '  rm -f /tmp/seatd-running' \
    'elif [ "$1 $2" = "eg25-manager status" ]; then' \
    '  [ -e /tmp/eg25-manager-running ]; exit $?' \
    'elif [ "$1 $2" = "eg25-manager start" ]; then' \
    '  touch /tmp/eg25-manager-running' \
    'elif [ "$1 $2" = "eg25-manager stop" ]; then' \
    '  rm -f /tmp/eg25-manager-running' \
    'elif [ "$1 $2" = "modemmanager status" ]; then' \
    '  [ -e /tmp/modemmanager-running ]; exit $?' \
    'elif [ "$1 $2" = "modemmanager start" ]; then' \
    '  [ ! -e /tmp/fail-modemmanager ] || exit 1' \
    '  touch /tmp/modemmanager-running' \
    'elif [ "$1 $2" = "modemmanager stop" ]; then' \
    '  rm -f /tmp/modemmanager-running' \
    'elif [ "$1 $2" = "emacsos-ui status" ]; then' \
    '  [ -e /tmp/emacsos-ui-running ]; exit $?' \
    'elif [ "$1 $2" = "emacsos-ui start" ]; then' \
    '  [ ! -e /tmp/fail-ui ] || exit 1' \
    '  if [ -e /tmp/fail-ui-once ]; then' \
    '    rm -f /tmp/fail-ui-once' \
    '    exit 1' \
    '  fi' \
    '  if [ -e /tmp/fail-ui-once-and-leak ]; then' \
    '    rm -f /tmp/fail-ui-once-and-leak' \
    '    touch /tmp/leave-lab-process-on-stop' \
    '    exit 1' \
    '  fi' \
    '  if [ -s /tmp/fail-ui-count ]; then' \
    '    count=$(cat /tmp/fail-ui-count)' \
    '    count=$((count - 1))' \
    '    printf "%s\\n" "$count" >/tmp/fail-ui-count' \
    '    [ "$count" -le 0 ] && rm -f /tmp/fail-ui-count' \
    '    exit 1' \
    '  fi' \
    '  if [ -e /tmp/fail-ui-stuck ]; then' \
    "    su emacsos-lab -s /bin/sh -c 'exec sleep 300' &" \
    '    sleep 0.1' \
    '    exit 1' \
    '  fi' \
    '  install -d -o emacsos-lab -g emacsos-lab -m 0700 /run/emacsos-ui' \
    '  install -o emacsos-lab -g emacsos-lab -m 0600 /dev/null /run/emacsos-ui/ready' \
    '  printf "%s\\n" ready >/run/emacsos-ui/ready' \
    '  touch /tmp/emacsos-ui-running' \
    'elif [ "$1 $2" = "emacsos-ui stop" ]; then' \
    '  [ ! -e /tmp/fail-ui-stuck ] || exit 1' \
    '  [ ! -e /tmp/fail-ui-stop ] || exit 1' \
    '  rm -rf /run/emacsos-ui' \
    '  rm -f /tmp/emacsos-ui-running' \
    '  if [ -e /tmp/leave-lab-process-on-stop ]; then' \
    '    rm -f /tmp/leave-lab-process-on-stop' \
    "    su emacsos-lab -s /bin/sh -c 'exec sleep 300' &" \
    '    sleep 0.1' \
    '    exit 1' \
    '  fi' \
    'fi' \
    'exit 0' >/usr/bin/rc-service
printf '%s\n' '#!/bin/sh' \
    'printf "%s\\n" "rc-update $*" >>/tmp/rc-update-log' \
    'case "$1 $2 $3" in' \
    '  "add seatd default") touch /tmp/seatd-enabled ;;' \
    '  "del seatd default") rm -f /tmp/seatd-enabled ;;' \
    '  "add emacsos-ui default") touch /tmp/emacsos-ui-enabled ;;' \
    '  "del emacsos-ui default") rm -f /tmp/emacsos-ui-enabled ;;' \
    '  "add eg25-manager default") touch /tmp/eg25-manager-enabled ;;' \
    '  "del eg25-manager default") rm -f /tmp/eg25-manager-enabled ;;' \
    '  "add modemmanager default") touch /tmp/modemmanager-enabled ;;' \
    '  "del modemmanager default") rm -f /tmp/modemmanager-enabled ;;' \
    '  "show default ")' \
    '    for service in seatd emacsos-ui eg25-manager modemmanager; do' \
    '      [ ! -e "/tmp/$service-enabled" ] ||' \
    '        printf "%s\\n" " $service | default"' \
    '    done' \
    '    ;;' \
    'esac' \
    'exit 0' >/usr/bin/rc-update
printf '%s\n' '#!/bin/sh' \
    'for arg do last=$arg; done' \
    'if [ "$last" = /run/seatd.sock ]; then' \
    '  printf "%s\\n" root:seat:770:socket' \
    'else' \
    '  /bin/busybox stat "$@" | sed "s/:regular empty file$/:regular file/"' \
    'fi' >/usr/bin/stat
chmod 0755 /usr/bin/apk /usr/bin/rc-service /usr/bin/rc-update /usr/bin/stat
rm -f /usr/bin/timeout
printf '%s\n' \
    '#!/bin/sh' \
    'while [ "$#" -gt 0 ]; do' \
    '  case $1 in -s|-k) shift 2 ;; [0-9]*) shift; break ;; *) break ;; esac' \
    'done' \
    'exec "$@"' >/usr/bin/timeout
chmod 0755 /usr/bin/timeout

for group in seat video audio; do
    getent group "$group" >/dev/null || addgroup -S "$group"
done
for executable in dbus-run-session pipewire pipewire-pulse wireplumber waydroid \
    alsaucm callaudiocli mmcli; do
    install -m 0755 /bin/true "/usr/bin/$executable"
done
install -d -o root -g root -m 0750 /etc/doas.d
install -d -o root -g root -m 0755 /etc/init.d /usr/local/sbin
install -d -o root -g root -m 0755 /etc/nftables.d
printf '%s\n' 'table inet filter { chain input { type filter hook input priority 0; policy drop; } }' \
    >/etc/nftables.nft
printf '%s\n' '#!/bin/sh' 'exit 0' >/usr/sbin/nft
chmod 0755 /usr/sbin/nft
for executable in swayidle doas setsid; do
    install -m 0755 /bin/true "/usr/bin/$executable"
done
printf '%s\n' '#!/bin/sh' 'exit 0' >/usr/bin/doas
chmod 0755 /usr/bin/doas
printf '%s\n' \
    '::sysinit:/sbin/openrc sysinit' \
    'tty1::respawn:/sbin/getty 38400 tty1' \
    'tty2::respawn:/sbin/getty 38400 tty2' >/etc/inittab
chown root:root /etc/inittab
chmod 0644 /etc/inittab

touch /tmp/fail-ui
if DEPLOY_CLIENT_IP=198.51.100.10 SUDO_USER=user \
    /bin/sh /source/openrc-install-root >/dev/null 2>&1; then
    printf '%s\n' 'injected UI failure was accepted' >&2
    exit 1
fi
[ ! -e /etc/init.d/emacsos-ui ]
[ ! -e /usr/local/share/emacsos-openrc ]
[ ! -e /usr/local/sbin/emacsos-openrc-boot-mode ]
[ ! -e /usr/local/sbin/emacsos-openrc-suspend ]
[ ! -e /usr/local/sbin/emacsos-openrc-call ]
[ ! -e /usr/local/sbin/emacsos-openrc-network ]
[ ! -e /etc/emacsos-openrc ]
[ ! -e /etc/nftables.d/49-emacsos-callback.nft ]
[ ! -e /usr/local/share/dbus-1/system-services/id.waydro.Container.service ]
[ ! -e /etc/dbus-1/system.d/99-emacsos-waydroid.conf ]
[ ! -e /usr/local/libexec/emacsos-waydroid-container ]
[ ! -e /etc/doas.d/95-emacsos-ui-suspend.conf ]
[ ! -e /var/lib/emacsos-openrc-state ]
if getent passwd emacsos-lab >/dev/null; then
    printf '%s\n' 'failed install retained the lab user' >&2
    exit 1
fi
if getent group emacsos-lab >/dev/null; then
    printf '%s\n' 'failed install retained the lab group' >&2
    exit 1
fi
[ ! -e /var/lib/emacsos-lab ]
[ "$(grep -Fxc 'tty1::respawn:/sbin/getty 38400 tty1' /etc/inittab)" -eq 1 ]
rm -f /tmp/fail-ui

touch /tmp/fail-ui-stuck
if DEPLOY_CLIENT_IP=198.51.100.10 SUDO_USER=user \
    /bin/sh /source/openrc-install-root >/dev/null 2>/tmp/stuck-error; then
    printf '%s\n' 'injected unquiesced UI failure was accepted' >&2
    exit 1
fi
grep -F 'rollback preserved UI recovery files because processes remain' \
    /tmp/stuck-error >/dev/null
[ -x /etc/init.d/emacsos-ui ]
[ -x /usr/local/share/emacsos-openrc/session ]
[ -x /usr/local/sbin/emacsos-openrc-suspend ]
[ -x /usr/local/sbin/emacsos-openrc-call ]
[ -x /usr/local/sbin/emacsos-openrc-network ]
[ -f /etc/emacsos-openrc/chat-url ]
[ -f /etc/nftables.d/49-emacsos-callback.nft ]
[ -f /usr/local/share/emacsos-openrc/os.el ]
[ -f /usr/local/share/emacsos-openrc/chat.el ]
[ -f /etc/doas.d/95-emacsos-ui-suspend.conf ]
getent passwd emacsos-lab >/dev/null
pgrep -u "$(id -u emacsos-lab)" >/dev/null

pkill -u "$(id -u emacsos-lab)"
rm -f /tmp/fail-ui-stuck
rc-service emacsos-ui stop >/dev/null
rm -rf /var/lib/emacsos-openrc-state /usr/local/share/emacsos-openrc \
    /var/lib/emacsos-lab /etc/emacsos-openrc
rm -f /etc/init.d/emacsos-ui \
    /etc/dbus-1/system.d/99-emacsos-waydroid.conf \
    /usr/local/share/dbus-1/system-services/id.waydro.Container.service \
    /usr/local/libexec/emacsos-waydroid-container \
    /usr/local/sbin/emacsos-openrc-call \
    /usr/local/sbin/emacsos-openrc-network \
    /usr/local/sbin/emacsos-openrc-suspend \
    /usr/local/sbin/emacsos-openrc-boot-mode \
    /etc/nftables.d/49-emacsos-callback.nft \
    /etc/doas.d/95-emacsos-ui-suspend.conf
deluser emacsos-lab
delgroup emacsos-lab 2>/dev/null || true

touch /tmp/fail-modemmanager
if DEPLOY_CLIENT_IP=198.51.100.10 SUDO_USER=user \
    /bin/sh /source/openrc-install-root >/dev/null 2>&1; then
    printf '%s\n' 'injected modem failure was accepted' >&2
    exit 1
fi
[ ! -e /tmp/eg25-manager-enabled ]
[ ! -e /tmp/eg25-manager-running ]
[ ! -e /tmp/modemmanager-enabled ]
[ ! -e /tmp/modemmanager-running ]
[ ! -e /etc/init.d/emacsos-ui ]
[ ! -e /usr/local/share/emacsos-openrc ]
[ ! -e /var/lib/emacsos-openrc-state ]
[ "$(grep -Fxc 'tty1::respawn:/sbin/getty 38400 tty1' /etc/inittab)" -eq 1 ]
if getent passwd emacsos-lab >/dev/null; then
    printf '%s\n' 'failed modem install retained the lab user' >&2
    exit 1
fi
rm -f /tmp/fail-modemmanager

if DEPLOY_CLIENT_IP=not-an-address SUDO_USER=user \
    /bin/sh /source/openrc-install-root >/dev/null 2>&1; then
    printf '%s\n' 'invalid deployment client address was accepted' >&2
    exit 1
fi
DEPLOY_CLIENT_IP=198.51.100.10 SUDO_USER=user \
    /bin/sh /source/openrc-install-root
[ "$(/usr/local/sbin/emacsos-openrc-boot-mode status)" = ui ]
[ -x /usr/local/share/emacsos-openrc/session ]
[ -x /usr/local/share/emacsos-openrc/process-group ]
[ -x /usr/local/sbin/emacsos-openrc-suspend ]
[ -x /etc/init.d/emacsos-ui ]
[ "$(id -Gn emacsos-lab | tr ' ' '\n' | grep -Exc 'audio|seat|video')" -eq 3 ]
grep -F 'apk add --simulate sway swayidle emacs-pgtk grim wtype wvkbd seatd seatd-openrc firefox mobile-config-firefox waydroid pipewire-pulse alsa-ucm-conf coreutils doas flock util-linux-misc eg25-manager modemmanager modemmanager-openrc mobile-broadband-provider-info pinephone-callaudiod alsa-utils' \
    /tmp/apk-log >/dev/null
grep -F 'rc-service emacsos-ui start' /tmp/rc-service-log >/dev/null
grep -F 'rc-service eg25-manager start' /tmp/rc-service-log >/dev/null
grep -F 'rc-service modemmanager start' /tmp/rc-service-log >/dev/null
grep -F 'rc-update add emacsos-ui default' /tmp/rc-update-log >/dev/null
grep -F 'rc-update add eg25-manager default' /tmp/rc-update-log >/dev/null
grep -F 'rc-update add modemmanager default' /tmp/rc-update-log >/dev/null
if DEPLOY_CLIENT_IP=198.51.100.10 SUDO_USER=user \
    /bin/sh /source/openrc-install-root >/dev/null 2>&1; then
    printf '%s\n' 'second fresh-only install was accepted' >&2
    exit 1
fi
[ "$(/usr/local/sbin/emacsos-openrc-boot-mode status)" = ui ]
[ -x /usr/local/share/emacsos-openrc/session ]
[ -x /usr/local/share/emacsos-openrc/process-group ]
[ -x /usr/local/sbin/emacsos-openrc-suspend ]
[ -x /etc/init.d/emacsos-ui ]
[ -f /usr/local/share/dbus-1/system-services/id.waydro.Container.service ]
[ -f /etc/dbus-1/system.d/99-emacsos-waydroid.conf ]
[ -x /usr/local/libexec/emacsos-waydroid-container ]
[ "$(cat /etc/doas.d/95-emacsos-ui-suspend.conf)" = \
    "$(printf '%s\n' \
        'permit nopass emacsos-lab as root cmd /usr/local/sbin/emacsos-openrc-suspend args' \
        'permit nopass emacsos-lab as root cmd /usr/local/sbin/emacsos-openrc-call' \
        'permit nopass emacsos-lab as root cmd /usr/local/sbin/emacsos-openrc-network')" ]
[ "$(stat -c '%U:%G:%a:%h:%F' /etc/doas.d/95-emacsos-ui-suspend.conf)" = \
    'root:root:600:1:regular file' ]
[ "$(cat /etc/emacsos-openrc/chat-url)" = \
    'http://198.51.100.10:8765/chat' ]
grep -F 'ip saddr 198.51.100.10 tcp dport 8766' \
    /etc/nftables.d/49-emacsos-callback.nft >/dev/null
grep -F 'iifname "wg0" tcp dport 8766' \
    /etc/nftables.d/49-emacsos-callback.nft >/dev/null
grep -F 'tcp dport 8766 drop' \
    /etc/nftables.d/49-emacsos-callback.nft >/dev/null
if grep -F '@DEPLOY_CLIENT_IP@' /etc/emacsos-openrc/chat-url \
    /etc/nftables.d/49-emacsos-callback.nft >/dev/null; then
    printf '%s\n' 'installed deployment template retained its placeholder' >&2
    exit 1
fi

cp -a /home/user/.cache/emacsos-openrc-stage \
    /home/user/.cache/emacsos-openrc-update
printf '%s\n' old-sway >/usr/local/share/emacsos-openrc/sway.config
printf '%s\n' old-power >/usr/local/share/emacsos-openrc/session-power
chmod 0755 /usr/local/share/emacsos-openrc/session-power
rm -rf /etc/emacsos-openrc
mv /etc/nftables.d/49-emacsos-callback.nft \
    /etc/nftables.d/95-emacsos-callback.nft
rm -f /usr/local/share/emacsos-openrc/os.el \
    /usr/local/share/emacsos-openrc/chat.el \
    /usr/local/share/emacsos-openrc/emacos-assist.el \
    /usr/local/share/emacsos-openrc/network.el \
    /usr/local/share/emacsos-openrc/phone-call.el \
    /usr/local/sbin/emacsos-openrc-call \
    /usr/local/sbin/emacsos-openrc-network
DEPLOY_CLIENT_IP=198.51.100.10 SUDO_USER=user \
    /bin/sh /source/openrc-update-root
[ -f /run/emacsos-ui/ready ]
[ -f /etc/emacsos-openrc/chat-url ]
cmp -s /source/openrc-init.el /usr/local/share/emacsos-openrc/init.el
cmp -s /source/openrc-sway.config \
    /usr/local/share/emacsos-openrc/sway.config
cmp -s /source/openrc-session-power \
    /usr/local/share/emacsos-openrc/session-power
grep -F 'ip saddr 198.51.100.10 tcp dport 8766' \
    /etc/nftables.d/49-emacsos-callback.nft >/dev/null
[ ! -e /etc/nftables.d/95-emacsos-callback.nft ]

printf '%s\n' old-session >/usr/local/share/emacsos-openrc/session
printf '%s\n' old-sway-after >/usr/local/share/emacsos-openrc/sway.config
printf '%s\n' old-power-after >/usr/local/share/emacsos-openrc/session-power
chmod 0755 /usr/local/share/emacsos-openrc/session
chmod 0755 /usr/local/share/emacsos-openrc/session-power
touch /tmp/fail-ui-once
if DEPLOY_CLIENT_IP=198.51.100.10 SUDO_USER=user \
    /bin/sh /source/openrc-update-root >/dev/null 2>&1; then
    printf '%s\n' 'injected update failure was accepted' >&2
    exit 1
fi
[ "$(cat /usr/local/share/emacsos-openrc/session)" = old-session ]
[ "$(cat /usr/local/share/emacsos-openrc/sway.config)" = old-sway-after ]
[ "$(cat /usr/local/share/emacsos-openrc/session-power)" = old-power-after ]
[ -f /run/emacsos-ui/ready ]

printf '%s\n' old-session-stop >/usr/local/share/emacsos-openrc/session
touch /tmp/fail-ui-once-and-leak
if DEPLOY_CLIENT_IP=198.51.100.10 SUDO_USER=user \
    /bin/sh /source/openrc-update-root >/tmp/update-stop.out 2>&1; then
    printf '%s\n' 'unquiesced update rollback was accepted' >&2
    exit 1
fi
grep -F 'rollback refused while UI remains active' /tmp/update-stop.out >/dev/null
grep -F 'rollback backup retained at /var/tmp/emacsos-openrc-backup.' \
    /tmp/update-stop.out >/dev/null
cmp -s /source/openrc-session /usr/local/share/emacsos-openrc/session
[ "$(find /var/tmp -maxdepth 1 -type d -name 'emacsos-openrc-backup.*' | wc -l)" -eq 1 ]
pkill -u "$(id -u emacsos-lab)"
rm -rf -- /var/tmp/emacsos-openrc-backup.*

printf '%s\n' old-session-start >/usr/local/share/emacsos-openrc/session
printf '%s\n' 2 >/tmp/fail-ui-count
if DEPLOY_CLIENT_IP=198.51.100.10 SUDO_USER=user \
    /bin/sh /source/openrc-update-root >/tmp/update-start.out 2>&1; then
    printf '%s\n' 'failed rollback restart was accepted' >&2
    exit 1
fi
grep -F 'rollback UI failed to start' /tmp/update-start.out >/dev/null
grep -F 'rollback backup retained at /var/tmp/emacsos-openrc-backup.' \
    /tmp/update-start.out >/dev/null
[ "$(cat /usr/local/share/emacsos-openrc/session)" = old-session-start ]
[ ! -e /tmp/emacsos-ui-running ]
[ "$(find /var/tmp -maxdepth 1 -type d -name 'emacsos-openrc-backup.*' | wc -l)" -eq 1 ]
rm -rf -- /var/tmp/emacsos-openrc-backup.*
CONTAINER

printf '%s\n' 'OpenRC installer transaction: OK'
