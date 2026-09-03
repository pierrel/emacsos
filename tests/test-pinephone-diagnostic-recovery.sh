#!/bin/sh

set -eu
CDPATH=
export CDPATH

repo_dir=$(cd -- "$(dirname -- "$0")/.." && pwd)
deploy_dir=$repo_dir/deploy/pinephone

sh -n "$deploy_dir/bake-diagnostic-image.sh"
sh -n "$deploy_dir/diagnostic-recovery-network"
sh -n "$deploy_dir/diagnostic-recovery-network.initd"

grep -Fx 'AuthenticationMethods publickey' "$deploy_dir/diagnostic-sshd.conf" >/dev/null
grep -Fx 'PasswordAuthentication no' "$deploy_dir/diagnostic-sshd.conf" >/dev/null
grep -Fx 'KbdInteractiveAuthentication no' "$deploy_dir/diagnostic-sshd.conf" >/dev/null
grep -Fx 'PermitRootLogin no' "$deploy_dir/diagnostic-sshd.conf" >/dev/null
grep -Fx 'AllowUsers user' "$deploy_dir/diagnostic-sshd.conf" >/dev/null
grep -Fx 'user ALL=(ALL:ALL) NOPASSWD: ALL' "$deploy_dir/diagnostic-sudoers" >/dev/null
grep -Fx 'permit nopass keepenv user as root' \
    "$deploy_dir/diagnostic-doas.conf" >/dev/null
grep -Fx 'address1=172.16.42.1/24' "$deploy_dir/diagnostic-usb.nmconnection" >/dev/null
grep -Fx 'interface-name=usb0' "$deploy_dir/diagnostic-usb.nmconnection" >/dev/null
grep -Fx 'cloned-mac-address=permanent' \
    "$deploy_dir/diagnostic-wifi.nmconnection.in" >/dev/null
grep -Fx 'autoconnect-retries=0' \
    "$deploy_dir/diagnostic-wifi.nmconnection.in" >/dev/null
grep -F 'before networkmanager sshd' "$deploy_dir/diagnostic-recovery-network.initd" >/dev/null
# A failed privileged bake may leave an explicitly incomplete file, never a
# final-looking output image.
# shellcheck disable=SC2016
grep -F 'work_image=$output_image.incomplete.$$' \
    "$deploy_dir/bake-diagnostic-image.sh" >/dev/null
# shellcheck disable=SC2016
grep -F 'mv -- "$work_image" "$output_image"' \
    "$deploy_dir/bake-diagnostic-image.sh" >/dev/null
# shellcheck disable=SC2016
grep -F 'ip address add "$address" dev "$interface"' \
    "$deploy_dir/diagnostic-recovery-network" >/dev/null

docker run --rm --privileged \
    -v "$deploy_dir/diagnostic-recovery-network:/test/recovery:ro" \
    alpine:edge /bin/sh -eu -c '
        ip link add usb0 type dummy
        /test/recovery
        ip -4 -o address show dev usb0 | grep -F "172.16.42.1/24" >/dev/null
        test "$(cat /run/emacsos-recovery/usb-address)" = "172.16.42.1/24"
    '

printf '%s\n' 'diagnostic recovery configuration: OK'
