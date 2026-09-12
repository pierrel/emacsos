#!/bin/sh
# Transfer and install the reviewed keyboard without replacing the stock package.

set -eu
umask 077

phone_host=${PINEPHONE_HOST:?set PINEPHONE_HOST to the SSH profile}
artifact=${1:?pass the wvkbd-emacsos artifact}
[ "$#" -eq 1 ] || { printf '%s\n' 'expected one artifact path' >&2; exit 1; }
notice=$(dirname -- "$artifact")/wordninja.txt
[ -f "$artifact" ] && [ ! -L "$artifact" ] && [ -x "$artifact" ] || {
    printf '%s\n' 'artifact must be a regular executable' >&2
    exit 1
}
[ "$(stat -c '%s' "$artifact")" -le 16777216 ] || {
    printf '%s\n' 'artifact is too large' >&2
    exit 1
}
file "$artifact" | grep -Eq 'ELF 64-bit LSB (pie )?executable, ARM aarch64' || {
    printf '%s\n' 'artifact is not an AArch64 ELF executable' >&2
    exit 1
}
readelf -l "$artifact" |
    grep -F 'Requesting program interpreter: /lib/ld-musl-aarch64.so.1' \
        >/dev/null || {
    printf '%s\n' 'artifact does not use the AArch64 musl interpreter' >&2
    exit 1
}
expected=$(sha256sum "$artifact")
expected=${expected%% *}
[ -f "$notice" ] && [ ! -L "$notice" ] && [ "$(stat -c '%s' "$notice")" -le 1048576 ] || {
    printf '%s\n' 'reviewed wordninja notice must be a bounded regular file' >&2
    exit 1
}
notice_expected=$(sha256sum "$notice")
notice_expected=${notice_expected%% *}
repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
root_helper=$repo_dir/deploy/pinephone/install-wvkbd-emacsos-root
stage=
notice_stage=

set -- -o User=user -o BatchMode=yes -o PreferredAuthentications=publickey \
    -o PubkeyAuthentication=yes -o PasswordAuthentication=no \
    -o KbdInteractiveAuthentication=no -o GSSAPIAuthentication=no \
    -o HostbasedAuthentication=no -o ConnectTimeout=10 \
    -o ServerAliveInterval=5 -o ServerAliveCountMax=3

cleanup() {
    [ -z "$stage" ] || ssh -T "$@" "$phone_host" "rm -f -- '$stage'" \
        >/dev/null 2>&1 || true
    [ -z "$notice_stage" ] || ssh -T "$@" "$phone_host" "rm -f -- '$notice_stage'" \
        >/dev/null 2>&1 || true
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

stage=$(ssh -T "$@" "$phone_host" \
    'umask 077; install -d -m 0700 /home/user/.cache; mktemp /home/user/.cache/wvkbd-emacsos.XXXXXX')
printf '%s\n' "$stage" |
    grep -Eq '^/home/user/\.cache/wvkbd-emacsos\.[A-Za-z0-9]{6}$' || {
    printf '%s\n' 'phone returned an unsafe staging path' >&2
    exit 1
}
notice_stage=$(ssh -T "$@" "$phone_host" \
    'umask 077; mktemp /home/user/.cache/wvkbd-notice.XXXXXX')
printf '%s\n' "$notice_stage" |
    grep -Eq '^/home/user/\.cache/wvkbd-notice\.[A-Za-z0-9]{6}$' || {
    printf '%s\n' 'phone returned an unsafe notice staging path' >&2
    exit 1
}
scp -q "$@" "$artifact" "$phone_host:$stage"
scp -q "$@" "$notice" "$phone_host:$notice_stage"
ssh -T "$@" "$phone_host" "chmod 0600 '$stage'"
ssh -T "$@" "$phone_host" "chmod 0600 '$notice_stage'"
ssh -T "$@" "$phone_host" \
    "exec sudo -n /usr/bin/env SUDO_USER=user WVKBD_STAGE='$stage' WVKBD_SHA256='$expected' WVKBD_NOTICE_STAGE='$notice_stage' WVKBD_NOTICE_SHA256='$notice_expected' /bin/sh" \
    <"$root_helper"

printf 'Installed %s as /usr/local/bin/wvkbd-emacsos; stock /usr/bin/wvkbd-mobintl is unchanged.\n' \
    "$expected"
