#!/bin/sh

set -eu
PATH=/usr/bin:/usr/sbin:/bin:/sbin
LC_ALL=C
CDPATH=
export PATH LC_ALL CDPATH
umask 077

usage() {
    printf 'usage: %s SOURCE_IMG OUTPUT_IMG PUBLIC_KEY WIFI_SSID_FILE WIFI_PSK_FILE PRIVATE_DIR\n' "$0" >&2
    exit 2
}

[ "$#" -eq 6 ] || usage
source_image=$1
output_image=$2
public_key=$3
wifi_ssid_file=$4
wifi_psk_file=$5
private_dir=$6

repo_dir=$(cd -- "$(dirname -- "$0")/../.." && pwd)
deploy_dir=$repo_dir/deploy/pinephone

for path in "$source_image" "$public_key" "$wifi_ssid_file" "$wifi_psk_file"; do
    [ -f "$path" ] && [ ! -L "$path" ] || {
        printf 'required regular file: %s\n' "$path" >&2
        exit 1
    }
done
ssh-keygen -lf "$public_key" >/dev/null
[ ! -e "$output_image" ] || {
    printf 'refusing to overwrite: %s\n' "$output_image" >&2
    exit 1
}

case $output_image in
    *.img) ;;
    *) printf 'output must end in .img\n' >&2; exit 1 ;;
esac

install -d -m 0700 "$private_dir"
host_key=$private_dir/ssh_host_ed25519_key
wifi_profile=$private_dir/recovery-wifi.nmconnection

if [ ! -f "$host_key" ]; then
    ssh-keygen -q -t ed25519 -N '' -C '' -f "$host_key"
fi
chmod 0600 "$host_key"
chmod 0644 "$host_key.pub"

wifi_ssid=$(cat "$wifi_ssid_file")
wifi_psk=$(cat "$wifi_psk_file")
[ -n "$wifi_ssid" ] && [ -n "$wifi_psk" ] || {
    printf 'WiFi SSID and PSK must be non-empty single lines\n' >&2
    exit 1
}
case $wifi_ssid$wifi_psk in
    *'
'*|*'\r'*) printf 'WiFi values must be single lines\n' >&2; exit 1 ;;
esac
ssid_length=${#wifi_ssid}
psk_length=${#wifi_psk}
[ "$ssid_length" -le 32 ] && [ "$psk_length" -ge 8 ] && [ "$psk_length" -le 63 ] || {
    printf 'WiFi SSID or WPA passphrase length is invalid\n' >&2
    exit 1
}

{
    while IFS= read -r line || [ -n "$line" ]; do
        case $line in
            '@@WIFI_SSID@@') printf '%s\n' "$wifi_ssid" ;;
            '@@WIFI_PSK@@') printf '%s\n' "$wifi_psk" ;;
            ssid=@@WIFI_SSID@@) printf 'ssid=%s\n' "$wifi_ssid" ;;
            psk=@@WIFI_PSK@@) printf 'psk=%s\n' "$wifi_psk" ;;
            *) printf '%s\n' "$line" ;;
        esac
    done < "$deploy_dir/diagnostic-wifi.nmconnection.in"
} > "$wifi_profile"
chmod 0600 "$wifi_profile"

partition_starts=$(sfdisk -d "$source_image" |
    sed -n 's/.*start=[[:space:]]*\([0-9][0-9]*\).*/\1/p')
# Intentional: make the two newline-separated starts positional parameters.
# shellcheck disable=SC2086
set -- $partition_starts
[ "$#" -eq 2 ] || {
    printf 'expected exactly two image partitions\n' >&2
    exit 1
}
boot_offset=$(($1 * 512))
root_offset=$(($2 * 512))

work_image=$output_image.incomplete.$$
[ ! -e "$work_image" ] || {
    printf 'refusing to overwrite incomplete build: %s\n' "$work_image" >&2
    exit 1
}
cp --reflink=auto -- "$source_image" "$work_image"
chmod 0600 "$work_image"

docker run --rm --privileged \
    -e BOOT_OFFSET="$boot_offset" \
    -e ROOT_OFFSET="$root_offset" \
    -v "$work_image:/work/phone.img" \
    -v "$deploy_dir:/assets:ro" \
    -v "$public_key:/private/authorized_key:ro" \
    -v "$private_dir:/private/build:ro" \
    alpine:edge /bin/sh -eu -c '
        root=/mnt/phone
        root_loop=
        boot_loop=
        cleanup() {
            sync
            umount "$root/boot" 2>/dev/null || true
            umount "$root" 2>/dev/null || true
            [ -z "$boot_loop" ] || losetup -d "$boot_loop" 2>/dev/null || true
            [ -z "$root_loop" ] || losetup -d "$root_loop" 2>/dev/null || true
        }
        trap cleanup EXIT HUP INT TERM
        root_loop=$(losetup -f)
        losetup -o "$ROOT_OFFSET" "$root_loop" /work/phone.img
        boot_loop=$(losetup -f)
        losetup -o "$BOOT_OFFSET" "$boot_loop" /work/phone.img
        mkdir -p "$root"
        mount "$root_loop" "$root"
        mount "$boot_loop" "$root/boot"

        install -D -m 0755 /assets/diagnostic-recovery-network \
            "$root/usr/local/sbin/emacsos-recovery-network"
        install -D -m 0755 /assets/diagnostic-recovery-network.initd \
            "$root/etc/init.d/emacsos-recovery-network"
        install -D -m 0600 /assets/diagnostic-usb.nmconnection \
            "$root/etc/NetworkManager/system-connections/USB_Networking.nmconnection"
        install -D -m 0600 /private/build/recovery-wifi.nmconnection \
            "$root/etc/NetworkManager/system-connections/emacsos-recovery-wifi.nmconnection"
        install -D -m 0644 /assets/diagnostic-sshd.conf \
            "$root/etc/ssh/sshd_config.d/10-emacsos-recovery.conf"
        install -D -m 0440 /assets/diagnostic-sudoers \
            "$root/etc/sudoers.d/90-emacsos-recovery"
        install -D -m 0440 /assets/diagnostic-doas.conf \
            "$root/etc/doas.d/90-emacsos-recovery.conf"
        install -D -m 0600 /private/build/ssh_host_ed25519_key \
            "$root/etc/ssh/ssh_host_ed25519_key"
        install -D -m 0644 /private/build/ssh_host_ed25519_key.pub \
            "$root/etc/ssh/ssh_host_ed25519_key.pub"
        install -D -m 0600 /private/authorized_key \
            "$root/home/user/.ssh/authorized_keys"
        chown -R 10000:10000 "$root/home/user/.ssh"
        chmod 0700 "$root/home/user/.ssh"

        printf "%s\n" \
            "rc_need=\"emacsos-recovery-network\"" \
            "sshd_disable_keygen=\"yes\"" \
            > "$root/etc/conf.d/sshd"
        chmod 0644 "$root/etc/conf.d/sshd"
        ln -snf /etc/init.d/emacsos-recovery-network \
            "$root/etc/runlevels/boot/emacsos-recovery-network"
        rm -f "$root/etc/runlevels/default/sshd"
        ln -snf /etc/init.d/sshd "$root/etc/runlevels/boot/sshd"
        rm -f "$root/etc/runlevels/default/eg25-manager"
        ln -snf /etc/init.d/syslog "$root/etc/runlevels/boot/syslog"
        ln -snf /etc/init.d/klogd "$root/etc/runlevels/boot/klogd"
        sync
    '

mv -- "$work_image" "$output_image"
printf 'baked image: %s\n' "$output_image"
printf 'SSH host key: '
ssh-keygen -lf "$host_key.pub"
