#!/bin/sh

set -eu
PATH=/usr/bin:/usr/sbin:/bin:/sbin
LC_ALL=C
CDPATH=
export PATH LC_ALL CDPATH
umask 077

[ "$#" -eq 5 ] || {
    printf 'usage: %s IMAGE PUBLIC_KEY CLIENT_PRIVATE_KEY PRIVATE_DIR QEMU_AARCH64\n' "$0" >&2
    exit 2
}

image=$1
public_key=$2
client_private_key=$3
private_dir=$4
qemu_aarch64=$5

for path in "$image" "$public_key" "$client_private_key" \
    "$private_dir/recovery-wifi.nmconnection" \
    "$private_dir/ssh_host_ed25519_key" \
    "$private_dir/ssh_host_ed25519_key.pub" "$qemu_aarch64"; do
    [ -f "$path" ] && [ ! -L "$path" ] || {
        printf 'required regular file: %s\n' "$path" >&2
        exit 1
    }
done

repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
artifact_dir=$repo_dir/.artifacts/pinephone-image-verification
install -d -m 0700 "$artifact_dir"
test_image=$artifact_dir/arm-root-test.$$.img
[ ! -e "$test_image" ] || {
    printf 'remove stale private test image first: %s\n' "$test_image" >&2
    exit 1
}
cp --reflink=auto -- "$image" "$test_image"
chmod 0600 "$test_image"

partition_starts=$(sfdisk -d "$image" |
    sed -n 's/.*start=[[:space:]]*\([0-9][0-9]*\).*/\1/p')
# Intentional: make the two newline-separated starts positional parameters.
# shellcheck disable=SC2086
set -- $partition_starts
[ "$#" -eq 2 ]
boot_offset=$(($1 * 512))
root_offset=$(($2 * 512))

docker run --rm --privileged \
    -e BOOT_OFFSET="$boot_offset" \
    -e ROOT_OFFSET="$root_offset" \
    -v "$image:/work/final.img:ro" \
    -v "$test_image:/work/test.img" \
    -v "$public_key:/private/authorized_key:ro" \
    -v "$client_private_key:/private/client_key:ro" \
    -v "$private_dir:/private/build:ro" \
    -v "$qemu_aarch64:/private/qemu-aarch64:ro" \
    alpine:edge /bin/sh -eu -c '
        apk add --no-cache dbus doas networkmanager networkmanager-cli \
            networkmanager-wifi openssh-client openssh-server-pam sudo \
            >/dev/null 2>&1

        final_root_loop=
        final_boot_loop=
        test_root_loop=
        test_boot_loop=
        networkmanager_pid=
        native_sshd_pid=
        cleanup() {
            [ -z "$native_sshd_pid" ] || kill "$native_sshd_pid" 2>/dev/null || true
            [ -z "$networkmanager_pid" ] || kill "$networkmanager_pid" 2>/dev/null || true
            umount /mnt/test/proc 2>/dev/null || true
            umount /mnt/test/dev 2>/dev/null || true
            umount /mnt/test/boot 2>/dev/null || true
            umount /mnt/test 2>/dev/null || true
            umount /mnt/final/boot 2>/dev/null || true
            umount /mnt/final 2>/dev/null || true
            [ -z "$test_boot_loop" ] || losetup -d "$test_boot_loop" 2>/dev/null || true
            [ -z "$test_root_loop" ] || losetup -d "$test_root_loop" 2>/dev/null || true
            [ -z "$final_boot_loop" ] || losetup -d "$final_boot_loop" 2>/dev/null || true
            [ -z "$final_root_loop" ] || losetup -d "$final_root_loop" 2>/dev/null || true
        }
        trap cleanup EXIT HUP INT TERM

        final_root_loop=$(losetup -f)
        losetup -r -o "$ROOT_OFFSET" "$final_root_loop" /work/final.img
        final_boot_loop=$(losetup -f)
        losetup -r -o "$BOOT_OFFSET" "$final_boot_loop" /work/final.img
        test_root_loop=$(losetup -f)
        losetup -o "$ROOT_OFFSET" "$test_root_loop" /work/test.img
        test_boot_loop=$(losetup -f)
        losetup -o "$BOOT_OFFSET" "$test_boot_loop" /work/test.img
        mkdir -p /mnt/final /mnt/test
        mount -o ro "$final_root_loop" /mnt/final
        mount -o ro "$final_boot_loop" /mnt/final/boot
        mount "$test_root_loop" /mnt/test
        mount "$test_boot_loop" /mnt/test/boot

        root=/mnt/final
        test -x "$root/usr/local/sbin/emacsos-recovery-network"
        test -x "$root/etc/init.d/emacsos-recovery-network"
        test "$(readlink "$root/etc/runlevels/boot/emacsos-recovery-network")" = "/etc/init.d/emacsos-recovery-network"
        test "$(readlink "$root/etc/runlevels/boot/sshd")" = "/etc/init.d/sshd"
        test ! -e "$root/etc/runlevels/default/sshd"
        test ! -e "$root/etc/runlevels/default/eg25-manager"
        cmp /private/authorized_key "$root/home/user/.ssh/authorized_keys"
        cmp /private/build/recovery-wifi.nmconnection \
            "$root/etc/NetworkManager/system-connections/emacsos-recovery-wifi.nmconnection"
        cmp /private/build/ssh_host_ed25519_key "$root/etc/ssh/ssh_host_ed25519_key"
        cmp /private/build/ssh_host_ed25519_key.pub "$root/etc/ssh/ssh_host_ed25519_key.pub"
        test "$(stat -c %a "$root/etc/sudoers.d/90-emacsos-recovery")" = 440
        test "$(stat -c %a "$root/etc/doas.d/90-emacsos-recovery.conf")" = 440
        test "$(stat -c %a "$root/etc/ssh/ssh_host_ed25519_key")" = 600
        test "$(stat -c %a "$root/home/user/.ssh/authorized_keys")" = 600
        test "$(stat -c %u:%g "$root/home/user/.ssh/authorized_keys")" = 10000:10000
        grep -Fx "rc_need=\"emacsos-recovery-network\"" "$root/etc/conf.d/sshd" >/dev/null
        grep -Fx "sshd_disable_keygen=\"yes\"" "$root/etc/conf.d/sshd" >/dev/null
        grep -Fx "address1=172.16.42.1/24" \
            "$root/etc/NetworkManager/system-connections/USB_Networking.nmconnection" >/dev/null
        grep -Fx "PasswordAuthentication no" \
            "$root/etc/ssh/sshd_config.d/10-emacsos-recovery.conf" >/dev/null
        grep -Fx "user ALL=(ALL:ALL) NOPASSWD: ALL" \
            "$root/etc/sudoers.d/90-emacsos-recovery" >/dev/null
        grep -Fx "permit nopass keepenv user as root" \
            "$root/etc/doas.d/90-emacsos-recovery.conf" >/dev/null

        cp /private/qemu-aarch64 /mnt/test/usr/bin/qemu-aarch64-static
        chmod 0755 /mnt/test/usr/bin/qemu-aarch64-static
        mount -t proc proc /mnt/test/proc
        mount --bind /dev /mnt/test/dev
        chroot /mnt/test /usr/bin/qemu-aarch64-static \
            /usr/sbin/sshd.pam -t
        if [ -x /mnt/test/usr/bin/visudo ]; then
            chroot /mnt/test /usr/bin/qemu-aarch64-static \
                /usr/bin/visudo -cf /etc/sudoers >/dev/null
        fi
        if [ -x /mnt/test/usr/bin/doas ]; then
            chroot /mnt/test /usr/bin/qemu-aarch64-static \
                /usr/bin/doas -C /etc/doas.d/90-emacsos-recovery.conf
        fi
        chroot /mnt/test /usr/bin/qemu-aarch64-static \
            /sbin/rc-update show boot | grep -F "emacsos-recovery-network" >/dev/null
        chroot /mnt/test /usr/bin/qemu-aarch64-static \
            /sbin/rc-update show boot | grep -F "sshd" >/dev/null

        install -D -m 0600 \
            /mnt/final/etc/NetworkManager/system-connections/USB_Networking.nmconnection \
            /etc/NetworkManager/system-connections/usb.nmconnection
        install -D -m 0600 \
            /mnt/final/etc/NetworkManager/system-connections/emacsos-recovery-wifi.nmconnection \
            /etc/NetworkManager/system-connections/wifi.nmconnection
        mkdir -p /run/dbus
        dbus-daemon --system
        NetworkManager --no-daemon >/tmp/networkmanager.log 2>&1 &
        networkmanager_pid=$!
        attempt=0
        until nmcli general status >/dev/null 2>&1; do
            attempt=$((attempt + 1))
            [ "$attempt" -lt 50 ] || {
                cat /tmp/networkmanager.log >&2
                exit 1
            }
            sleep 0.1
        done
        nmcli connection reload
        nmcli -t -f NAME connection show | grep -Fx "EmacsOS recovery WiFi" >/dev/null
        nmcli -t -f NAME connection show | grep -Fx "USB Networking" >/dev/null
        test "$(nmcli -g 802-11-wireless.cloned-mac-address connection show \
            "EmacsOS recovery WiFi")" = "permanent"
        test "$(nmcli -g connection.autoconnect-retries connection show \
            "EmacsOS recovery WiFi")" = "0"
        test "$(nmcli -g ipv4.addresses connection show \
            83bd1823-feca-4c2b-9205-4b83dc792e1f)" = "172.16.42.1/24"

        adduser -D -u 10000 user
        install -d -m 0700 -o user -g user /home/user/.ssh
        install -m 0600 -o user -g user /private/authorized_key \
            /home/user/.ssh/authorized_keys
        install -m 0440 /mnt/final/etc/sudoers.d/90-emacsos-recovery \
            /etc/sudoers.d/90-emacsos-recovery
        install -D -m 0440 \
            /mnt/final/etc/doas.d/90-emacsos-recovery.conf \
            /etc/doas.d/90-emacsos-recovery.conf
        install -m 0600 /private/build/ssh_host_ed25519_key /tmp/host_key
        {
            printf "%s\n" \
                "Port 2222" \
                "ListenAddress 127.0.0.1" \
                "PidFile /tmp/native-sshd.pid" \
                "HostKey /tmp/host_key" \
                "AuthorizedKeysFile .ssh/authorized_keys" \
                "UsePAM yes"
            cat /mnt/final/etc/ssh/sshd_config.d/10-emacsos-recovery.conf
        } > /tmp/native-sshd.conf
        /usr/sbin/sshd.pam -t -f /tmp/native-sshd.conf
        /usr/sbin/sshd.pam -D -e -f /tmp/native-sshd.conf \
            >/tmp/native-sshd.log 2>&1 &
        native_sshd_pid=$!
        attempt=0
        while ! ssh -q -p 2222 -i /private/client_key \
            -o BatchMode=yes -o IdentitiesOnly=yes \
            -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
            user@127.0.0.1 "sudo -n id -u" > /tmp/sudo-result; do
            attempt=$((attempt + 1))
            [ "$attempt" -lt 20 ] || {
                cat /tmp/native-sshd.log >&2
                exit 1
            }
            sleep 0.1
        done
        test "$(cat /tmp/sudo-result)" = 0
        su user -c "doas -n id -u" > /tmp/doas-result
        test "$(cat /tmp/doas-result)" = 0
        printf "%s\n" "image auth and sudo smoke: OK"
    '

printf 'private ARM test copy retained at %s\n' "$test_image"
