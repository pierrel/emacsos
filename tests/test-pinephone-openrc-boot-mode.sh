#!/bin/sh

set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)

docker run --rm --network none -i \
    -v "$repo_dir/deploy/pinephone/openrc-boot-mode:/source/openrc-boot-mode:ro" \
    alpine:3.22 /bin/sh -s <<'CONTAINER'
set -eu

printf '%s\n' '#!/bin/sh' 'printf "%s\\n" "rc-service $*" >>/tmp/rc-log' 'exit 0' \
    >/usr/bin/rc-service
printf '%s\n' '#!/bin/sh' \
    'printf "%s\\n" "rc-update $*" >>/tmp/rc-log' \
    'if [ -e /tmp/block-del ] && [ "$1 $2 $3" = "del emacsos-ui default" ]; then printf reached >/tmp/reached; read answer </tmp/continue; fi' \
    'case "$1 $2 $3" in' \
    '  "add emacsos-ui default") touch /tmp/ui-enabled ;;' \
    '  "del emacsos-ui default") rm -f /tmp/ui-enabled ;;' \
    '  "show default ") [ ! -e /tmp/ui-enabled ] || printf "%s\\n" " emacsos-ui | default" ;;' \
    'esac' \
    'exit 0' >/usr/bin/rc-update
chmod 0755 /usr/bin/rc-service /usr/bin/rc-update
printf '%s\n' '#!/bin/sh' \
    'count=$(cat /tmp/sync-count 2>/dev/null || printf 0)' \
    'count=$((count + 1))' \
    'printf "%s\\n" "$count" >/tmp/sync-count' \
    'if [ -f /tmp/fail-sync-at ] && [ "$count" -eq "$(cat /tmp/fail-sync-at)" ]; then exit 1; fi' \
    'exit 0' >/usr/bin/sync
chmod 0755 /usr/bin/sync
printf '%s\n' '#!/bin/sh' \
    '/bin/busybox stat "$@" | sed "s/:regular empty file$/:regular file/"' \
    >/usr/bin/stat
chmod 0755 /usr/bin/stat

for group in seat video audio; do
    getent group "$group" >/dev/null || addgroup -S "$group"
done
addgroup -S emacsos-lab
adduser -S -D -H -h /var/lib/emacsos-lab -s /sbin/nologin \
    -G emacsos-lab emacsos-lab
addgroup emacsos-lab seat
addgroup emacsos-lab video
addgroup emacsos-lab audio

install -d -o root -g root -m 0755 /usr/local/share/emacsos-openrc \
    /usr/local/sbin /etc/init.d
install -d -o root -g root -m 0750 /etc/doas.d
install -o root -g root -m 0755 /dev/null /usr/local/share/emacsos-openrc/session
install -o root -g root -m 0755 /dev/null \
    /usr/local/share/emacsos-openrc/process-group
install -o root -g root -m 0755 /dev/null /etc/init.d/emacsos-ui
printf '%s\n' \
    'permit nopass emacsos-lab as root cmd /usr/local/sbin/emacsos-openrc-call' \
    'permit nopass emacsos-lab as root cmd /usr/local/sbin/emacsos-openrc-network' \
    >/etc/doas.d/95-emacsos-ui.conf
chown root:root /etc/doas.d/95-emacsos-ui.conf
chmod 0600 /etc/doas.d/95-emacsos-ui.conf
install -o root -g root -m 0755 /source/openrc-boot-mode \
    /usr/local/sbin/emacsos-openrc-boot-mode
printf '%s\n' \
    '::sysinit:/sbin/openrc sysinit' \
    'tty1::respawn:/sbin/getty 38400 tty1' \
    'tty2::respawn:/sbin/getty 38400 tty2' >/etc/inittab
chown root:root /etc/inittab
chmod 0644 /etc/inittab

install -o root -g root -m 0755 /dev/null \
    /usr/local/sbin/emacsos-openrc-suspend
if /usr/local/sbin/emacsos-openrc-boot-mode initialize >/tmp/legacy.out 2>&1; then
    printf '%s\n' 'boot mode accepted a legacy suspend helper' >&2
    exit 1
fi
grep -F 'legacy suspend helper is installed' /tmp/legacy.out >/dev/null
rm -f /usr/local/sbin/emacsos-openrc-suspend

/usr/local/sbin/emacsos-openrc-boot-mode initialize
[ "$(/usr/local/sbin/emacsos-openrc-boot-mode status)" = ui ]
[ "$(grep -Fxc '# emacsos-openrc owns tty1' /etc/inittab)" -eq 1 ]
[ "$(grep -Fxc 'tty2::respawn:/sbin/getty 38400 tty2' /etc/inittab)" -eq 1 ]
rm -f /tmp/ui-enabled
if /usr/local/sbin/emacsos-openrc-boot-mode status >/dev/null 2>&1; then
    printf '%s\n' 'runlevel mismatch was accepted' >&2
    exit 1
fi
touch /tmp/ui-enabled

mv /usr/local/share/emacsos-openrc/session /tmp/session
/usr/local/sbin/emacsos-openrc-boot-mode console
[ "$(/usr/local/sbin/emacsos-openrc-boot-mode status)" = console ]
[ "$(grep -Fxc 'tty1::respawn:/sbin/getty 38400 tty1' /etc/inittab)" -eq 1 ]
mv /tmp/session /usr/local/share/emacsos-openrc/session

printf '%s\n' 0 >/tmp/sync-count
printf '%s\n' 2 >/tmp/fail-sync-at
if /usr/local/sbin/emacsos-openrc-boot-mode ui >/dev/null 2>&1; then
    printf '%s\n' 'post-rename sync failure was accepted' >&2
    exit 1
fi
[ "$(/usr/local/sbin/emacsos-openrc-boot-mode status)" = console ]
rm -f /tmp/fail-sync-at

/usr/local/sbin/emacsos-openrc-boot-mode ui
[ "$(/usr/local/sbin/emacsos-openrc-boot-mode status)" = ui ]

install -o root -g root -m 0644 \
    /var/lib/emacsos-openrc-state/inittab.original /etc/inittab
/usr/local/sbin/emacsos-openrc-boot-mode console
[ "$(/usr/local/sbin/emacsos-openrc-boot-mode status)" = console ]

install -o root -g root -m 0644 \
    /var/lib/emacsos-openrc-state/inittab.installed /etc/inittab
/usr/local/sbin/emacsos-openrc-boot-mode ui
[ "$(/usr/local/sbin/emacsos-openrc-boot-mode status)" = ui ]
grep -F 'rc-update del emacsos-ui default' /tmp/rc-log >/dev/null
grep -F 'rc-update add emacsos-ui default' /tmp/rc-log >/dev/null

addgroup emacsos-lab disk
if /usr/local/sbin/emacsos-openrc-boot-mode ui >/tmp/unsafe-group.out 2>&1; then
    printf '%s\n' 'unsafe supplementary group was accepted' >&2
    exit 1
fi
grep -F 'lab account group set is unsafe' /tmp/unsafe-group.out >/dev/null
delgroup emacsos-lab disk
[ "$(/usr/local/sbin/emacsos-openrc-boot-mode status)" = ui ]

mkfifo /tmp/reached /tmp/continue
touch /tmp/block-del
cat /tmp/reached >/dev/null &
watcher=$!
/usr/local/sbin/emacsos-openrc-boot-mode console >/tmp/concurrent-console.out &
console_pid=$!
wait "$watcher"
if /usr/local/sbin/emacsos-openrc-boot-mode ui >/tmp/concurrent-ui.out 2>&1; then
    printf '%s\n' 'concurrent selector was accepted' >&2
    exit 1
fi
grep -F 'install or update is busy' /tmp/concurrent-ui.out >/dev/null
rm -f /tmp/block-del
printf go >/tmp/continue
wait "$console_pid"
[ "$(/usr/local/sbin/emacsos-openrc-boot-mode status)" = console ]
/usr/local/sbin/emacsos-openrc-boot-mode ui
[ "$(/usr/local/sbin/emacsos-openrc-boot-mode status)" = ui ]

printf '%s\n' '# tamper' >>/etc/inittab
if /usr/local/sbin/emacsos-openrc-boot-mode status >/dev/null 2>&1; then
    printf '%s\n' 'tampered inittab was accepted' >&2
    exit 1
fi
CONTAINER

printf '%s\n' 'OpenRC boot-mode round trip: OK'
