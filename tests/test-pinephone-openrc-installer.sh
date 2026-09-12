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
for name in openrc-manifest.sha256 openrc-init.el dtach-shell.el dtach-shell-init.el openrc-sway.config \
    openrc-session openrc-session-power openrc-process-group openrc-suspend-root \
    wvkbd-transaction-root \
    openrc-call-root openrc-sms-root openrc-network-root openrc-chat-url openrc-assist-web-url \
    openrc-emacs-server.nft \
    emacsos-ui.initd openrc-boot-mode waydroid-container.service \
    waydroid-container.conf \
    waydroid-container-wrapper; do
    install -o user -g user -m 0600 "/source/$name" \
        "/home/user/.cache/emacsos-openrc-stage/$name"
done
for name in os.el chat.el assist-web.el emacsos-assist.el network.el phone-call.el phone-sms.el \
    EMACSOS-COMMANDS.org; do
    install -o user -g user -m 0600 "/repo/$name" \
        "/home/user/.cache/emacsos-openrc-stage/$name"
done
printf '%s\n' test-assist-web-token \
    >/home/user/.cache/emacsos-openrc-stage/assist-web-token
chown user:user /home/user/.cache/emacsos-openrc-stage/assist-web-token
chmod 0600 /home/user/.cache/emacsos-openrc-stage/assist-web-token
printf '%s\n' '-----BEGIN CERTIFICATE-----' dGVzdA== \
    '-----END CERTIFICATE-----' \
    >/home/user/.cache/emacsos-openrc-stage/assist-web-ca.pem
chown user:user /home/user/.cache/emacsos-openrc-stage/assist-web-ca.pem
chmod 0600 /home/user/.cache/emacsos-openrc-stage/assist-web-ca.pem

printf '%s\n' '#!/bin/sh' \
    'printf "%s\\n" "apk $*" >>/tmp/apk-log' \
    'printf "%s\\n" "apk $*" >>/tmp/transaction-log' \
    'if [ -e /tmp/block-apk ]; then trap "exit 143" TERM; while :; do sleep 1; done; fi' \
    'if [ "${1-}" = add ]; then for package do [ "$package" != py3-dbus ] || touch /tmp/py3-dbus-present; done; fi' \
    'exit 0' \
    >/usr/bin/apk
printf '%s\n' '#!/bin/sh' \
    'printf "%s\\n" "rc-service $*" >>/tmp/rc-service-log' \
    'printf "%s\\n" "rc-service $*" >>/tmp/transaction-log' \
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
    '  for fd in 6 7 8 9; do case $(readlink "/proc/$$/fd/$fd" 2>/dev/null || true) in /run/wvkbd-emacos-install.lock|/run/wvkbd-emacsos-install.lock|/run/emacsos-openrc-install.lock|/run/emacsos-openrc-boot-mode.lock) exit 1 ;; esac; done' \
    '  [ ! -e /tmp/fail-ui ] || exit 1' \
    '  if [ "$(cat /usr/local/share/emacsos-openrc/session)" = legacy-session ]; then' \
    '    /usr/local/sbin/emacsos-wvkbd-transaction verify-current || exit 1' \
    '  fi' \
    '  if [ -e /tmp/require-new-keyboard ]; then' \
    '    [ -x /usr/local/bin/wvkbd-emacsos ] || exit 1' \
    '    [ -f /usr/local/share/licenses/wvkbd-emacsos/wordninja.txt ] || exit 1' \
    '    /usr/local/bin/wvkbd-emacsos --mod-swipe -H 300 -L 300 || exit 1' \
    '    rm -f /tmp/require-new-keyboard' \
    '  fi' \
    '  if [ -e /tmp/race-command-reference ]; then' \
    '    rm -f /tmp/race-command-reference' \
    '    printf "%s\\n" raced-user-file >/var/lib/emacsos-lab/EMACSOS-COMMANDS.org' \
    '    chown emacsos-lab:emacsos-lab /var/lib/emacsos-lab/EMACSOS-COMMANDS.org' \
    '    chmod 0600 /var/lib/emacsos-lab/EMACSOS-COMMANDS.org' \
    '  fi' \
    '  if [ -e /tmp/race-command-reference-directory ]; then' \
    '    rm -f /tmp/race-command-reference-directory' \
    '    rm -f /var/lib/emacsos-lab/EMACSOS-COMMANDS.org' \
    '    mkdir /var/lib/emacsos-lab/EMACSOS-COMMANDS.org' \
    '    chown emacsos-lab:emacsos-lab /var/lib/emacsos-lab/EMACSOS-COMMANDS.org' \
    '    exit 1' \
    '  fi' \
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
    '  [ ! -e /tmp/status3-cgroup ] || { rm -f /tmp/emacsos-ui-running /tmp/status3-cgroup; exit 1; }' \
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
    'if [ -e /tmp/block-apk ] && [ "${1-}" = apk ]; then' \
    '  "$@" &' \
    '  child=$!' \
    '  sleep 0.1' \
    '  kill -TERM "$child" 2>/dev/null || true' \
    '  sleep 0.1' \
    '  kill -KILL "$child" 2>/dev/null || true' \
    '  wait "$child" 2>/dev/null || true' \
    '  exit 124' \
    'fi' \
    'exec "$@"' >/usr/bin/timeout
chmod 0755 /usr/bin/timeout

# The real state-free keyboard proof is exercised against a real ELF in
# test-wvkbd-build.sh. This updater fixture proves that every ordinary start
# calls that proof and rejects its missing, wrong, and out-of-cgroup failures.
grep -F '/usr/local/sbin/emacsos-wvkbd-transaction verify-current >/dev/null 2>&1' \
    /source/openrc-update-root >/dev/null
sed \
    -e 's|service_cgroup=/sys/fs/cgroup/openrc.emacsos-ui|service_cgroup=/tmp/openrc.emacsos-ui|' \
    -e 's|/usr/local/sbin/emacsos-wvkbd-transaction verify-current|/usr/local/sbin/test-wvkbd-proof|' \
    -e 's/\[ "$attempt" -lt 150 \]/[ "$attempt" -lt 1 ]/' \
    -e 's|printf '\''%s\\n'\'' 1 >"$service_cgroup/cgroup.kill"|: >"$service_cgroup/cgroup.procs"; printf '\''populated 0\\n'\'' >"$service_cgroup/cgroup.events"|' \
    /source/openrc-update-root >/tmp/openrc-update-root
chmod 0755 /tmp/openrc-update-root
awk '
    { print }
    /^    bootstrap_tmp=\$\(mktemp / { print "    sleep 30" }
' /tmp/openrc-update-root >/tmp/openrc-update-bootstrap-signal
chmod 0755 /tmp/openrc-update-bootstrap-signal

for group in seat video audio; do
    getent group "$group" >/dev/null || addgroup -S "$group"
done
for executable in dbus-run-session pipewire pipewire-pulse wireplumber waydroid \
    alsaucm callaudiocli mmcli gdbus; do
    install -m 0755 /bin/true "/usr/bin/$executable"
done
printf '%s\n' '#!/bin/sh' \
    'if [ "${1-}" = -I ] && [ "${2-}" = -c ] && [ "${3-}" = "import dbus" ]; then' \
    '  [ -e /tmp/py3-dbus-present ]' \
    '  exit $?' \
    'fi' \
    'if [ "${1-}" = - ] && [ "$#" -eq 4 ]; then' \
    '  source=$2 destination=$3 maximum=$4' \
    '  [ -f "$source" ] && [ ! -L "$source" ] || exit 1' \
    '  [ "$(/bin/busybox stat -c "%U:%G:%a:%h:%F" "$source")" = user:user:600:1:"regular file" ] || exit 1' \
    '  [ "$(/bin/busybox stat -c "%s" "$source")" -le "$maximum" ] || exit 1' \
    '  /bin/cat -- "$source" >"$destination"' \
    '  chown root:root "$destination"' \
    '  chmod 0600 "$destination"' \
    '  exit 0' \
    'fi' \
    'case ${2-} in' \
    '  *EMACSOS-COMMANDS.org*) exec /bin/cat /var/lib/emacsos-lab/EMACSOS-COMMANDS.org ;;' \
    '  *) exit 0 ;;' \
    'esac' >/usr/bin/python3
chmod 0755 /usr/bin/python3
install -d -o root -g root -m 0750 /etc/doas.d
install -d -o root -g root -m 0755 /etc/init.d /usr/local/sbin
printf '%s\n' '#!/bin/sh' \
    'if [ -s /tmp/wvkbd-proof-case ]; then' \
    '  case $(cat /tmp/wvkbd-proof-case) in' \
    '    missing|wrong|out-of-cgroup)' \
    '      cat /tmp/wvkbd-proof-case >>/tmp/wvkbd-proof-log' \
    '      rm -f /tmp/wvkbd-proof-case' \
    '      exit 1' \
    '      ;;' \
    '  esac' \
    'fi' \
    'exit 0' >/usr/local/sbin/test-wvkbd-proof
chmod 0755 /usr/local/sbin/test-wvkbd-proof
install -d -o root -g root -m 0755 /etc/nftables.d
printf '%s\n' 'table inet filter { chain input { type filter hook input priority 0; policy drop; } }' \
    >/etc/nftables.nft
printf '%s\n' '#!/bin/sh' 'exit 0' >/usr/sbin/nft
chmod 0755 /usr/sbin/nft
for executable in swayidle doas setsid; do
    install -m 0755 /bin/true "/usr/bin/$executable"
done
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" /' >/usr/bin/findmnt
chmod 0755 /usr/bin/findmnt
printf '%s\n' '#!/bin/sh' 'exit 0' >/usr/bin/doas
chmod 0755 /usr/bin/doas
printf '%s\n' \
    '::sysinit:/sbin/openrc sysinit' \
    'tty1::respawn:/sbin/getty 38400 tty1' \
    'tty2::respawn:/sbin/getty 38400 tty2' >/etc/inittab
chown root:root /etc/inittab
chmod 0644 /etc/inittab

touch /tmp/fail-ui
if DEPLOY_CLIENT_IP=198.51.100.10 ASSIST_WEB_SERVER_IP=203.0.113.8 SUDO_USER=user \
    /bin/sh /source/openrc-install-root >/dev/null 2>&1; then
    printf '%s\n' 'injected UI failure was accepted' >&2
    exit 1
fi
[ ! -e /etc/init.d/emacsos-ui ]
[ ! -e /usr/local/share/emacsos-openrc ]
[ ! -e /usr/local/sbin/emacsos-openrc-boot-mode ]
[ ! -e /usr/local/sbin/emacsos-openrc-suspend ]
[ ! -e /usr/local/sbin/emacsos-openrc-call ]
[ ! -e /usr/local/sbin/emacsos-openrc-sms ]
[ ! -e /usr/local/sbin/emacsos-openrc-network ]
[ ! -e /etc/emacsos-openrc ]
[ ! -e /etc/nftables.d/49-emacsos-callback.nft ]
[ ! -e /usr/local/share/dbus-1/system-services/id.waydro.Container.service ]
[ ! -e /etc/dbus-1/system.d/99-emacsos-waydroid.conf ]
[ ! -e /usr/local/libexec/emacsos-waydroid-container ]
[ ! -e /etc/doas.d/95-emacsos-ui.conf ]
[ ! -e /var/lib/emacsos-openrc-state ]
[ ! -e /var/lib/emacsos-lab/EMACSOS-COMMANDS.org ]
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
if DEPLOY_CLIENT_IP=198.51.100.10 ASSIST_WEB_SERVER_IP=203.0.113.8 SUDO_USER=user \
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
[ -x /usr/local/sbin/emacsos-openrc-sms ]
[ -x /usr/local/sbin/emacsos-openrc-network ]
[ -f /etc/emacsos-openrc/chat-url ]
[ -f /etc/nftables.d/49-emacsos-callback.nft ]
[ -f /usr/local/share/emacsos-openrc/os.el ]
[ -f /usr/local/share/emacsos-openrc/chat.el ]
[ -f /usr/local/share/emacsos-openrc/dtach-shell.el ]
[ -f /usr/local/share/emacsos-openrc/dtach-shell-init.el ]
[ -f /etc/doas.d/95-emacsos-ui.conf ]
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
    /usr/local/sbin/emacsos-openrc-suspend \
    /usr/local/sbin/emacsos-openrc-call \
    /usr/local/sbin/emacsos-openrc-sms \
    /usr/local/sbin/emacsos-openrc-network \
    /usr/local/sbin/emacsos-openrc-boot-mode \
    /etc/nftables.d/49-emacsos-callback.nft \
    /etc/doas.d/95-emacsos-ui.conf
deluser emacsos-lab
delgroup emacsos-lab 2>/dev/null || true

touch /tmp/fail-modemmanager
if DEPLOY_CLIENT_IP=198.51.100.10 ASSIST_WEB_SERVER_IP=203.0.113.8 SUDO_USER=user \
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

touch /tmp/race-command-reference
if DEPLOY_CLIENT_IP=198.51.100.10 ASSIST_WEB_SERVER_IP=203.0.113.8 SUDO_USER=user \
    /bin/sh /source/openrc-install-root >/dev/null 2>&1; then
    printf '%s\n' 'fresh install overwrote a raced command reference' >&2
    exit 1
fi
[ ! -e /usr/local/share/emacsos-openrc ]
if getent passwd emacsos-lab >/dev/null; then
    printf '%s\n' 'raced reference install retained the lab user' >&2
    exit 1
fi
[ ! -e /var/lib/emacsos-lab ]

if DEPLOY_CLIENT_IP=not-an-address ASSIST_WEB_SERVER_IP=203.0.113.8 SUDO_USER=user \
    /bin/sh /source/openrc-install-root >/dev/null 2>&1; then
    printf '%s\n' 'invalid deployment client address was accepted' >&2
    exit 1
fi
DEPLOY_CLIENT_IP=198.51.100.10 ASSIST_WEB_SERVER_IP=203.0.113.8 SUDO_USER=user \
    /bin/sh /source/openrc-install-root
[ "$(/usr/local/sbin/emacsos-openrc-boot-mode status)" = ui ]
[ -x /usr/local/share/emacsos-openrc/session ]
[ -x /usr/local/share/emacsos-openrc/process-group ]
[ -x /usr/local/sbin/emacsos-openrc-suspend ]
[ -x /etc/init.d/emacsos-ui ]
[ "$(id -Gn emacsos-lab | tr ' ' '\n' | grep -Exc 'audio|seat|video')" -eq 3 ]
grep -F 'apk add --simulate sway swayidle emacs-pgtk emacs-vterm openssh-client-default grim wtype wvkbd seatd seatd-openrc firefox mobile-config-firefox waydroid pipewire-pulse alsa-ucm-conf coreutils doas flock util-linux-misc eg25-manager modemmanager modemmanager-openrc mobile-broadband-provider-info pinephone-callaudiod alsa-utils' \
    /tmp/apk-log >/dev/null
grep -F 'rc-service emacsos-ui start' /tmp/rc-service-log >/dev/null
grep -F 'rc-service eg25-manager start' /tmp/rc-service-log >/dev/null
grep -F 'rc-service modemmanager start' /tmp/rc-service-log >/dev/null
grep -F 'rc-update add emacsos-ui default' /tmp/rc-update-log >/dev/null
grep -F 'rc-update add eg25-manager default' /tmp/rc-update-log >/dev/null
grep -F 'rc-update add modemmanager default' /tmp/rc-update-log >/dev/null
if DEPLOY_CLIENT_IP=198.51.100.10 ASSIST_WEB_SERVER_IP=203.0.113.8 SUDO_USER=user \
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
[ "$(cat /etc/doas.d/95-emacsos-ui.conf)" = \
    "$(printf '%s\n' \
        'permit nopass emacsos-lab as root cmd /usr/local/sbin/emacsos-openrc-suspend args' \
        'permit nopass nolog emacsos-lab as root cmd /usr/local/sbin/emacsos-openrc-call' \
        'permit nopass nolog emacsos-lab as root cmd /usr/local/sbin/emacsos-openrc-sms args' \
        'permit nopass emacsos-lab as root cmd /usr/local/sbin/emacsos-openrc-network')" ]
[ "$(stat -c '%U:%G:%a:%h:%F' /etc/doas.d/95-emacsos-ui.conf)" = \
    'root:root:600:1:regular file' ]
[ "$(cat /etc/emacsos-openrc/chat-url)" = \
    'http://198.51.100.10:8765/chat' ]
[ "$(cat /etc/emacsos-openrc/assist-web-url)" = \
    'https://203.0.113.8:5050/api/v1/phone' ]
[ "$(cat /etc/emacsos-openrc/assist-web-ca.pem)" = \
    "$(printf '%s\n' '-----BEGIN CERTIFICATE-----' dGVzdA== '-----END CERTIFICATE-----')" ]
[ "$(stat -c '%U:%G:%a:%h:%F' /etc/emacsos-openrc/assist-web-ca.pem)" = \
    'root:root:644:1:regular file' ]
[ "$(cat /var/lib/emacsos-lab/.config/emacsos/assist-web-token)" = \
    test-assist-web-token ]
[ "$(stat -c '%U:%G:%a:%h:%F' \
    /var/lib/emacsos-lab/.config/emacsos/assist-web-token)" = \
    'emacsos-lab:emacsos-lab:600:1:regular file' ]
cmp -s /repo/EMACSOS-COMMANDS.org /var/lib/emacsos-lab/EMACSOS-COMMANDS.org
[ "$(stat -c '%U:%G:%a:%h:%F' /var/lib/emacsos-lab/EMACSOS-COMMANDS.org)" = \
    'emacsos-lab:emacsos-lab:600:1:regular file' ]
grep -F 'ip saddr 198.51.100.10 tcp dport 8766' \
    /etc/nftables.d/49-emacsos-callback.nft >/dev/null
grep -F 'iifname "wg0" tcp dport 8766' \
    /etc/nftables.d/49-emacsos-callback.nft >/dev/null
grep -F 'tcp dport 8766 drop' \
    /etc/nftables.d/49-emacsos-callback.nft >/dev/null
if grep -F '@DEPLOY_CLIENT_IP@' /etc/emacsos-openrc/chat-url \
    /etc/emacsos-openrc/assist-web-url \
    /etc/nftables.d/49-emacsos-callback.nft >/dev/null; then
    printf '%s\n' 'installed deployment template retained its placeholder' >&2
    exit 1
fi
if grep -F '@ASSIST_WEB_SERVER_IP@' /etc/emacsos-openrc/assist-web-url >/dev/null; then
    printf '%s\n' 'installed Assist URL retained its server placeholder' >&2
    exit 1
fi

printf '%s\n' '#!/bin/sh' \
    '[ "$*" = "--mod-swipe -H 300 -L 300" ]' \
    '[ "$(cat /usr/local/share/licenses/wvkbd-emacsos/wordninja.txt)" = new-notice ]' \
    'printf "%s\\n" "$*" >>/tmp/wvkbd-command-log' \
    >/home/user/.cache/emacsos-openrc-stage/wvkbd-emacsos
printf '%s\n' new-notice \
    >/home/user/.cache/emacsos-openrc-stage/wvkbd-notice
chown user:user /home/user/.cache/emacsos-openrc-stage/wvkbd-emacsos \
    /home/user/.cache/emacsos-openrc-stage/wvkbd-notice
chmod 0600 /home/user/.cache/emacsos-openrc-stage/wvkbd-emacsos \
    /home/user/.cache/emacsos-openrc-stage/wvkbd-notice
cp -a /home/user/.cache/emacsos-openrc-stage \
    /home/user/.cache/emacsos-openrc-update
touch /tmp/require-new-keyboard
install -o root -g root -m 0755 /bin/true \
    /usr/local/sbin/emacsos-openrc-suspend
printf '%s\n' \
    'permit nopass emacsos-lab as root cmd /usr/local/sbin/emacsos-openrc-suspend args' \
    >/etc/doas.d/95-emacsos-ui-suspend.conf
chown root:root /etc/doas.d/95-emacsos-ui-suspend.conf
chmod 0600 /etc/doas.d/95-emacsos-ui-suspend.conf
printf '%s\n' old-sway >/usr/local/share/emacsos-openrc/sway.config
printf '%s\n' old-power >/usr/local/share/emacsos-openrc/session-power
chmod 0755 /usr/local/share/emacsos-openrc/session-power
rm -rf /etc/emacsos-openrc
mv /etc/nftables.d/49-emacsos-callback.nft \
    /etc/nftables.d/95-emacsos-callback.nft
rm -f /usr/local/share/emacsos-openrc/os.el \
    /usr/local/share/emacsos-openrc/chat.el \
    /usr/local/share/emacsos-openrc/assist-web.el \
    /usr/local/share/emacsos-openrc/emacsos-assist.el \
    /usr/local/share/emacsos-openrc/network.el \
    /usr/local/share/emacsos-openrc/phone-call.el \
    /usr/local/share/emacsos-openrc/phone-sms.el \
    /usr/local/sbin/emacsos-openrc-call \
    /usr/local/sbin/emacsos-openrc-sms \
    /usr/local/sbin/emacsos-openrc-network
install -d -o root -g root -m 0755 /usr/local/share/licenses/wvkbd-emacos
printf '%s\n' legacy-keyboard >/usr/local/bin/wvkbd-emacos
chown root:root /usr/local/bin/wvkbd-emacos
chmod 0755 /usr/local/bin/wvkbd-emacos
printf '%s\n' legacy-notice >/usr/local/share/licenses/wvkbd-emacos/wordninja.txt
chown root:root /usr/local/share/licenses/wvkbd-emacos/wordninja.txt
chmod 0644 /usr/local/share/licenses/wvkbd-emacos/wordninja.txt
printf '%s\n' legacy-assist >/usr/local/share/emacsos-openrc/emacos-assist.el
chown root:root /usr/local/share/emacsos-openrc/emacos-assist.el
chmod 0644 /usr/local/share/emacsos-openrc/emacos-assist.el
printf '%s\n' '#!/bin/sh' \
    'case "$1" in validate-upgrade|normalize-upgrade|verify-current) exit 0 ;; *) exit 1 ;; esac' \
    >/usr/local/sbin/emacsos-wvkbd-transaction
chown root:root /usr/local/sbin/emacsos-wvkbd-transaction
chmod 0755 /usr/local/sbin/emacsos-wvkbd-transaction
printf '%s\n' legacy-session >/usr/local/share/emacsos-openrc/session
chmod 0755 /usr/local/share/emacsos-openrc/session
touch /tmp/fail-ui-once
if DEPLOY_CLIENT_IP=198.51.100.10 ASSIST_WEB_SERVER_IP=203.0.113.8 SUDO_USER=user \
    /bin/sh /tmp/openrc-update-root >/dev/null 2>&1; then
    printf '%s\n' 'injected legacy migration failure was accepted' >&2
    exit 1
fi
[ -x /usr/local/sbin/emacsos-openrc-suspend ]
[ ! -e /etc/doas.d/95-emacsos-ui-suspend.conf ]
[ -f /etc/doas.d/95-emacsos-ui.conf ]
[ -f /run/emacsos-ui/ready ]
[ "$(cat /usr/local/bin/wvkbd-emacos)" = legacy-keyboard ]
[ "$(cat /usr/local/share/licenses/wvkbd-emacos/wordninja.txt)" = legacy-notice ]
[ "$(cat /usr/local/share/emacsos-openrc/emacos-assist.el)" = legacy-assist ]
[ "$(cat /usr/local/share/emacsos-openrc/session)" = legacy-session ]
grep -F 'verify-current) exit 0' /usr/local/sbin/emacsos-wvkbd-transaction >/dev/null
[ ! -e /usr/local/bin/wvkbd-emacsos ]
[ ! -e /usr/local/share/licenses/wvkbd-emacsos/wordninja.txt ]

rm -f /tmp/wvkbd-command-log
touch /tmp/require-new-keyboard
DEPLOY_CLIENT_IP=198.51.100.10 ASSIST_WEB_SERVER_IP=203.0.113.8 SUDO_USER=user \
    /bin/sh /tmp/openrc-update-root
[ -f /run/emacsos-ui/ready ]
[ -x /usr/local/bin/wvkbd-emacsos ]
[ "$(cat /usr/local/share/licenses/wvkbd-emacsos/wordninja.txt)" = new-notice ]
grep -Fx -- '--mod-swipe -H 300 -L 300' /tmp/wvkbd-command-log >/dev/null
[ ! -e /usr/local/bin/wvkbd-emacos ]
[ ! -e /usr/local/share/licenses/wvkbd-emacos/wordninja.txt ]
[ ! -e /usr/local/share/emacsos-openrc/emacos-assist.el ]

# Runtime cleanup must fail closed when mount metadata cannot be read.  Exercise
# the actual updater function without mutating the live fixture directory.
sed -n '/^safe_runtime() {$/,/^}$/p' /tmp/openrc-update-root >/tmp/safe-runtime
printf '%s\n' '#!/bin/sh' 'exit 1' >/usr/bin/findmnt
if ( . /tmp/safe-runtime; safe_runtime ); then
    printf '%s\n' 'runtime safety accepted a failed findmnt query' >&2
    exit 1
fi
for unsafe_mount in /run/emacsos-ui /run/emacsos-ui/nested; do
    printf '%s\n' '#!/bin/sh' "printf '%s\\n' / '$unsafe_mount'" >/usr/bin/findmnt
    if ( . /tmp/safe-runtime; safe_runtime ); then
        printf '%s\n' 'runtime safety accepted a session-tree mount' >&2
        exit 1
    fi
done
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" /' >/usr/bin/findmnt
( . /tmp/safe-runtime; safe_runtime )

sed -n '/^runtime_safe_to_remove() {$/,/^}$/p' \
    /source/emacsos-ui.initd >/tmp/runtime-safe-to-remove
printf '%s\n' '#!/bin/sh' 'exit 1' >/usr/bin/findmnt
if ( . /tmp/runtime-safe-to-remove; runtime_safe_to_remove /run/emacsos-ui ); then
    printf '%s\n' 'service runtime safety accepted a failed findmnt query' >&2
    exit 1
fi
for unsafe_mount in /run/emacsos-ui /run/emacsos-ui/nested; do
    printf '%s\n' '#!/bin/sh' "printf '%s\\n' / '$unsafe_mount'" >/usr/bin/findmnt
    if ( . /tmp/runtime-safe-to-remove; runtime_safe_to_remove /run/emacsos-ui ); then
        printf '%s\n' 'service runtime safety accepted a session-tree mount' >&2
        exit 1
    fi
done
printf '%s\n' '#!/bin/sh' 'printf "%s\\n" /' >/usr/bin/findmnt
( . /tmp/runtime-safe-to-remove; runtime_safe_to_remove /run/emacsos-ui )

[ -f /etc/emacsos-openrc/chat-url ]
[ -f /etc/emacsos-openrc/assist-web-url ]
cmp -s /repo/assist-web.el /usr/local/share/emacsos-openrc/assist-web.el
cmp -s /source/openrc-init.el /usr/local/share/emacsos-openrc/init.el
cmp -s /source/openrc-sway.config \
    /usr/local/share/emacsos-openrc/sway.config
cmp -s /source/openrc-session-power \
    /usr/local/share/emacsos-openrc/session-power
grep -F 'ip saddr 198.51.100.10 tcp dport 8766' \
    /etc/nftables.d/49-emacsos-callback.nft >/dev/null
[ ! -e /etc/nftables.d/95-emacsos-callback.nft ]
[ -x /usr/local/sbin/emacsos-openrc-suspend ]
[ ! -e /etc/doas.d/95-emacsos-ui-suspend.conf ]

# A signal after same-directory mktemp but before installation must use the
# updater's outer cleanup without stopping the UI or leaving a root temp.
if find /usr/local/sbin -maxdepth 1 -name '.emacsos-wvkbd-transaction.*' \
    -print -quit | grep -q .; then
    printf '%s\n' 'unexpected preexisting compatibility-helper temporary' >&2
    exit 1
fi
: >/tmp/rc-service-log
DEPLOY_CLIENT_IP=198.51.100.10 ASSIST_WEB_SERVER_IP=203.0.113.8 SUDO_USER=user \
    /bin/sh /tmp/openrc-update-bootstrap-signal >/tmp/update-bootstrap-signal.out 2>&1 &
bootstrap_pid=$!
attempt=0
while [ "$attempt" -lt 50 ]; do
    if find /usr/local/sbin -maxdepth 1 -name '.emacsos-wvkbd-transaction.*' \
        -print -quit | grep -q .; then
        break
    fi
    attempt=$((attempt + 1))
    sleep 0.1
done
if [ "$attempt" -eq 50 ]; then
    kill -TERM "$bootstrap_pid" 2>/dev/null || true
    wait "$bootstrap_pid" 2>/dev/null || true
    printf '%s\n' 'bootstrap signal fixture did not reach its temporary file' >&2
    exit 1
fi
kill -TERM "$bootstrap_pid"
if wait "$bootstrap_pid"; then
    printf '%s\n' 'interrupted bootstrap unexpectedly succeeded' >&2
    exit 1
fi
if find /usr/local/sbin -maxdepth 1 -name '.emacsos-wvkbd-transaction.*' \
    -print -quit | grep -q .; then
    printf '%s\n' 'interrupted bootstrap left a compatibility-helper temporary' >&2
    exit 1
fi
if grep -F 'rc-service emacsos-ui stop' /tmp/rc-service-log >/dev/null; then
    printf '%s\n' 'interrupted bootstrap stopped the UI' >&2
    exit 1
fi

# Every existing file that the update might later snapshot is checked before
# the forward-only compatibility-helper replacement or any UI stop.  Exercise
# the per-user token and reference as well as an ordinary root backup source.
assert_preflight_rejection() {
    label=$1
    helper_before=$(sha256sum /usr/local/sbin/emacsos-wvkbd-transaction)
    : >/tmp/rc-service-log
    if DEPLOY_CLIENT_IP=198.51.100.10 ASSIST_WEB_SERVER_IP=203.0.113.8 SUDO_USER=user \
        /bin/sh /tmp/openrc-update-root >/tmp/update-preflight.out 2>&1; then
        printf '%s\n' "updater accepted unsafe $label" >&2
        exit 1
    fi
    [ "$(sha256sum /usr/local/sbin/emacsos-wvkbd-transaction)" = "$helper_before" ]
    if grep -F 'rc-service emacsos-ui stop' /tmp/rc-service-log >/dev/null; then
        printf '%s\n' "unsafe $label stopped the UI before rejection" >&2
        exit 1
    fi
}

# The update-only keyboard inputs retain the installer helper's strict staged
# file contract before this transaction stops the UI or changes any payload.
restore_keyboard_stage() {
    install -o user -g user -m 0600 \
        /home/user/.cache/emacsos-openrc-stage/wvkbd-emacsos \
        /home/user/.cache/emacsos-openrc-update/wvkbd-emacsos
    install -o user -g user -m 0600 \
        /home/user/.cache/emacsos-openrc-stage/wvkbd-notice \
        /home/user/.cache/emacsos-openrc-update/wvkbd-notice
}
rm -f /home/user/.cache/emacsos-openrc-update/wvkbd-emacsos
ln -s /bin/true /home/user/.cache/emacsos-openrc-update/wvkbd-emacsos
assert_preflight_rejection staged-keyboard-symlink
restore_keyboard_stage
chown root:root /home/user/.cache/emacsos-openrc-update/wvkbd-emacsos
assert_preflight_rejection staged-keyboard-owner
chown user:user /home/user/.cache/emacsos-openrc-update/wvkbd-emacsos
chmod 0644 /home/user/.cache/emacsos-openrc-update/wvkbd-emacsos
assert_preflight_rejection staged-keyboard-mode
restore_keyboard_stage

chmod 0644 /var/lib/emacsos-lab/.config/emacsos/assist-web-token
assert_preflight_rejection token
chmod 0600 /var/lib/emacsos-lab/.config/emacsos/assist-web-token

chmod 0644 /var/lib/emacsos-lab/EMACSOS-COMMANDS.org
assert_preflight_rejection command-reference
chmod 0600 /var/lib/emacsos-lab/EMACSOS-COMMANDS.org

rm -f /usr/local/share/emacsos-openrc/os.el
ln -s /repo/os.el /usr/local/share/emacsos-openrc/os.el
assert_preflight_rejection backup-source
install -o root -g root -m 0644 /repo/os.el /usr/local/share/emacsos-openrc/os.el
for unsafe_mode in 0664 0646; do
    chmod "$unsafe_mode" /usr/local/share/emacsos-openrc/os.el
    assert_preflight_rejection "backup-source-mode-$unsafe_mode"
done
chmod 0644 /usr/local/share/emacsos-openrc/os.el

# The one-generation bridge accepts only the exact old root-owned paths.
# Reject each unsafe old installation before changing the helper or stopping UI.
install -d -o root -g root -m 0755 /usr/local/share/licenses/wvkbd-emacos
install -o root -g root -m 0755 /bin/true /usr/local/bin/wvkbd-emacos
install -o root -g root -m 0644 /dev/null \
    /usr/local/share/licenses/wvkbd-emacos/wordninja.txt
rm -f /usr/local/bin/wvkbd-emacos
ln -s /bin/true /usr/local/bin/wvkbd-emacos
assert_preflight_rejection legacy-keyboard-symlink
rm -f /usr/local/bin/wvkbd-emacos
install -o root -g root -m 0755 /bin/true /usr/local/bin/wvkbd-emacos
chown user:user /usr/local/bin/wvkbd-emacos
assert_preflight_rejection legacy-keyboard-owner
chown root:root /usr/local/bin/wvkbd-emacos
chmod 0700 /usr/local/bin/wvkbd-emacos
assert_preflight_rejection legacy-keyboard-mode
chmod 0755 /usr/local/bin/wvkbd-emacos

# An unfinished durable keyboard state belongs to recovery, not this rename.
install -d -o root -g root -m 0700 /var/lib/emacsos-wvkbd-transaction
printf '%s\n' unfinished >/var/lib/emacsos-wvkbd-transaction/state
chown root:root /var/lib/emacsos-wvkbd-transaction/state
chmod 0600 /var/lib/emacsos-wvkbd-transaction/state
assert_preflight_rejection unfinished-keyboard-transaction
rm -f /var/lib/emacsos-wvkbd-transaction/state
rmdir /var/lib/emacsos-wvkbd-transaction
rm -f /usr/local/bin/wvkbd-emacos \
    /usr/local/share/licenses/wvkbd-emacos/wordninja.txt
rmdir /usr/local/share/licenses/wvkbd-emacos

printf '%s\n' old-session >/usr/local/share/emacsos-openrc/session
printf '%s\n' old-sway-after >/usr/local/share/emacsos-openrc/sway.config
printf '%s\n' old-power-after >/usr/local/share/emacsos-openrc/session-power
printf '%s\n' old-initd >/etc/init.d/emacsos-ui
chmod 0755 /etc/init.d/emacsos-ui
printf '%s\n' old-reference >/var/lib/emacsos-lab/EMACSOS-COMMANDS.org
chown emacsos-lab:emacsos-lab /var/lib/emacsos-lab/EMACSOS-COMMANDS.org
chmod 0600 /var/lib/emacsos-lab/EMACSOS-COMMANDS.org
chmod 0755 /usr/local/share/emacsos-openrc/session
chmod 0755 /usr/local/share/emacsos-openrc/session-power
touch /tmp/fail-ui-once
if DEPLOY_CLIENT_IP=198.51.100.10 ASSIST_WEB_SERVER_IP=203.0.113.8 SUDO_USER=user \
    /bin/sh /tmp/openrc-update-root >/dev/null 2>&1; then
    printf '%s\n' 'injected update failure was accepted' >&2
    exit 1
fi
[ "$(cat /usr/local/share/emacsos-openrc/session)" = old-session ]
[ "$(cat /usr/local/share/emacsos-openrc/sway.config)" = old-sway-after ]
[ "$(cat /usr/local/share/emacsos-openrc/session-power)" = old-power-after ]
[ "$(cat /etc/init.d/emacsos-ui)" = old-initd ]
[ "$(cat /var/lib/emacsos-lab/EMACSOS-COMMANDS.org)" = old-reference ]
[ "$(stat -c '%U:%G:%a:%h:%F' /var/lib/emacsos-lab/EMACSOS-COMMANDS.org)" = \
    'emacsos-lab:emacsos-lab:600:1:regular file' ]
[ -f /run/emacsos-ui/ready ]

DEPLOY_CLIENT_IP=198.51.100.10 ASSIST_WEB_SERVER_IP=203.0.113.8 SUDO_USER=user \
    /bin/sh /tmp/openrc-update-root
cmp -s /source/emacsos-ui.initd /etc/init.d/emacsos-ui
[ "$(stat -c '%U:%G:%a:%h:%F' /etc/init.d/emacsos-ui)" = \
    'root:root:755:1:regular file' ]
grep -F '/usr/local/sbin/emacsos-wvkbd-transaction prepare-start || return 1' \
    /etc/init.d/emacsos-ui >/dev/null
grep -F '/usr/local/sbin/emacsos-wvkbd-transaction verify-start' \
    /etc/init.d/emacsos-ui >/dev/null

# Reproduce the live failure boundary: OpenRC reports status 3 while the exact
# UI cgroup is populated.  The updater must stop normally, reconcile that one
# validated cgroup, remove only the validated runtime directory, and perform
# one ordinary start that ends with one default-runlevel entry.
mkdir -p /tmp/openrc.emacsos-ui
: >/tmp/openrc.emacsos-ui/cgroup.procs
printf '%s\n' 'populated 1' >/tmp/openrc.emacsos-ui/cgroup.events
: >/tmp/openrc.emacsos-ui/cgroup.kill
install -d -o emacsos-lab -g emacsos-lab -m 0700 /run/emacsos-ui
install -o emacsos-lab -g emacsos-lab -m 0600 /dev/null /run/emacsos-ui/ready
printf '%s\n' ready >/run/emacsos-ui/ready
touch /tmp/emacsos-ui-running /tmp/status3-cgroup
starts_before=$(grep -Fc 'rc-service emacsos-ui start' /tmp/rc-service-log || true)
DEPLOY_CLIENT_IP=198.51.100.10 ASSIST_WEB_SERVER_IP=203.0.113.8 SUDO_USER=user \
    /bin/sh /tmp/openrc-update-root
[ "$(grep -Fc 'rc-service emacsos-ui start' /tmp/rc-service-log)" = \
    "$((starts_before + 1))" ]
grep -Fx 'populated 0' /tmp/openrc.emacsos-ui/cgroup.events >/dev/null
[ ! -s /tmp/openrc.emacsos-ui/cgroup.procs ]
[ -f /run/emacsos-ui/ready ]
[ "$(rc-update show default | awk '$1 == "emacsos-ui" && $2 == "|" && $3 == "default" { count++ } END { print count + 0 }')" = 1 ]

# Python can already exist without its D-Bus binding on an upgrade.  Installing
# and proving that binding must precede the UI stop, and no apk may run after.
[ -x /usr/bin/python3 ]
rm -f /tmp/py3-dbus-present
: >/tmp/apk-log
: >/tmp/rc-service-log
: >/tmp/transaction-log
DEPLOY_CLIENT_IP=198.51.100.10 ASSIST_WEB_SERVER_IP=203.0.113.8 SUDO_USER=user \
    /bin/sh /tmp/openrc-update-root
[ -e /tmp/py3-dbus-present ]
dbus_install_line=$(grep -nFx 'apk add py3-dbus' /tmp/transaction-log | cut -d: -f1)
ui_stop_line=$(grep -nFx 'rc-service emacsos-ui stop' /tmp/transaction-log | cut -d: -f1)
[ "$dbus_install_line" -lt "$ui_stop_line" ]
if sed -n "$((ui_stop_line + 1)),\$p" /tmp/transaction-log | grep -q '^apk '; then
    printf '%s\n' 'updater ran apk after stopping the UI' >&2
    exit 1
fi

# A stalled package manager must time out while the UI still runs.  The updater
# has its locks, so this protects both the visible session and later updates.
: >/tmp/rc-service-log
: >/tmp/transaction-log
touch /tmp/block-apk
if DEPLOY_CLIENT_IP=198.51.100.10 ASSIST_WEB_SERVER_IP=203.0.113.8 SUDO_USER=user \
    /bin/sh /tmp/openrc-update-root >/tmp/update-apk-timeout.out 2>&1; then
    printf '%s\n' 'blocked apk was accepted' >&2
    exit 1
fi
rm -f /tmp/block-apk
grep -F 'apk add --simulate py3-dbus' /tmp/transaction-log >/dev/null
if grep -F 'rc-service emacsos-ui stop' /tmp/transaction-log >/dev/null; then
    printf '%s\n' 'blocked apk stopped the UI' >&2
    exit 1
fi
[ -f /run/emacsos-ui/ready ]

# The updater's ordinary post-start verification must reject each state-free
# keyboard-proof failure. The test proof fails once so rollback can start the
# restored UI and the next case remains independent.
for proof in missing wrong out-of-cgroup; do
    printf '%s\n' "$proof" >/tmp/wvkbd-proof-case
    if DEPLOY_CLIENT_IP=198.51.100.10 ASSIST_WEB_SERVER_IP=203.0.113.8 SUDO_USER=user \
        /bin/sh /tmp/openrc-update-root >/tmp/update-proof.out 2>&1; then
        printf '%s\n' "updater accepted $proof keyboard proof" >&2
        exit 1
    fi
    grep -Fx "$proof" /tmp/wvkbd-proof-log >/dev/null
    grep -F 'updated UI did not become ready' /tmp/update-proof.out >/dev/null
    [ -f /run/emacsos-ui/ready ]
done

printf '%s\n' old-reference-directory-race >/var/lib/emacsos-lab/EMACSOS-COMMANDS.org
chown emacsos-lab:emacsos-lab /var/lib/emacsos-lab/EMACSOS-COMMANDS.org
chmod 0600 /var/lib/emacsos-lab/EMACSOS-COMMANDS.org
touch /tmp/race-command-reference-directory
if DEPLOY_CLIENT_IP=198.51.100.10 ASSIST_WEB_SERVER_IP=203.0.113.8 SUDO_USER=user \
    /bin/sh /tmp/openrc-update-root >/tmp/update-reference-race.out 2>&1; then
    printf '%s\n' 'raced reference rollback was accepted' >&2
    exit 1
fi
grep -F 'command reference rollback failed' /tmp/update-reference-race.out >/dev/null
grep -F 'rollback backup retained at /var/tmp/emacsos-openrc-backup.' \
    /tmp/update-reference-race.out >/dev/null
[ -d /var/lib/emacsos-lab/EMACSOS-COMMANDS.org ]
[ -f /run/emacsos-ui/ready ]
rm -rf /var/lib/emacsos-lab/EMACSOS-COMMANDS.org /var/tmp/emacsos-openrc-backup.*
install -o emacsos-lab -g emacsos-lab -m 0600 /repo/EMACSOS-COMMANDS.org \
    /var/lib/emacsos-lab/EMACSOS-COMMANDS.org

printf '%s\n' old-session-stop >/usr/local/share/emacsos-openrc/session
touch /tmp/fail-ui-once-and-leak
if DEPLOY_CLIENT_IP=198.51.100.10 ASSIST_WEB_SERVER_IP=203.0.113.8 SUDO_USER=user \
    /bin/sh /tmp/openrc-update-root >/tmp/update-stop.out 2>&1; then
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
if DEPLOY_CLIENT_IP=198.51.100.10 ASSIST_WEB_SERVER_IP=203.0.113.8 SUDO_USER=user \
    /bin/sh /tmp/openrc-update-root >/tmp/update-start.out 2>&1; then
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
