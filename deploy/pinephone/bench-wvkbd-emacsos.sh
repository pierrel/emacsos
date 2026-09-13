#!/bin/sh
# Run the pinned AArch64 glide benchmark without touching the live keyboard.
set -eu

phone_host=${PINEPHONE_HOST:?set PINEPHONE_HOST to the SSH profile}
benchmark=${1:?pass the AArch64 bench-glide artifact}
[ "$#" -eq 1 ] || { printf '%s\n' 'expected one benchmark path' >&2; exit 1; }
[ -f "$benchmark" ] && [ ! -L "$benchmark" ] && [ -x "$benchmark" ] || {
    printf '%s\n' 'benchmark must be a regular executable' >&2; exit 1;
}
[ "$(stat -c '%s' "$benchmark")" -le 16777216 ] || {
    printf '%s\n' 'benchmark exceeds the transfer bound' >&2; exit 1;
}
file "$benchmark" | grep -Eq 'ELF 64-bit LSB (pie )?executable, ARM aarch64' || {
    printf '%s\n' 'benchmark is not an AArch64 ELF executable' >&2; exit 1;
}
readelf -l "$benchmark" |
    grep -F 'Requesting program interpreter: /lib/ld-musl-aarch64.so.1' >/dev/null || {
    printf '%s\n' 'benchmark does not use the AArch64 musl interpreter' >&2; exit 1;
}
expected=$(sha256sum "$benchmark"); expected=${expected%% *}
set -- -o User=user -o BatchMode=yes -o PreferredAuthentications=publickey \
    -o PubkeyAuthentication=yes -o PasswordAuthentication=no \
    -o KbdInteractiveAuthentication=no -o ConnectTimeout=10
stage=
cleanup() {
    [ -z "$stage" ] || ssh -T "$@" "$phone_host" "rm -f -- '$stage'" \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT HUP INT TERM
stage=$(ssh -T "$@" "$phone_host" \
    'umask 077; install -d -m 0700 /home/user/.cache; mktemp /home/user/.cache/wvkbd-bench.XXXXXX')
printf '%s\n' "$stage" | grep -Eq '^/home/user/\.cache/wvkbd-bench\.[A-Za-z0-9]{6}$' || {
    printf '%s\n' 'phone returned an unsafe benchmark path' >&2; exit 1;
}
scp -q "$@" "$benchmark" "$phone_host:$stage"
ssh -T "$@" "$phone_host" "chmod 0700 '$stage' && test \"\$(sha256sum '$stage' | awk '{print \$1}')\" = '$expected' && file '$stage' | grep -Eq 'ELF 64-bit LSB (pie )?executable, ARM aarch64.*interpreter /lib/ld-musl-aarch64.so.1' && timeout 60 '$stage' --max-us 50000"
