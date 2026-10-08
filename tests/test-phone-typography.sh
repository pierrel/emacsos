#!/bin/sh
# Verify real font selection and proportional rows in disposable X11 Emacs.
set -eu
repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
proof_dir=$(mktemp -d)
cleanup() {
    result=$?
    if [ "$result" -eq 0 ]; then
        rm -rf -- "$proof_dir"
    else
        printf 'Typography check evidence retained: %s\n' "$proof_dir" >&2
    fi
}
trap cleanup EXIT
# The container has no phone, credentials, production services or model access.
docker run --rm --label emacsos.typography-test -v "$repo_dir:/repo:ro" -v "$proof_dir:/proof" \
    alpine:3.22 /bin/sh -c '
    set -eu
    timeout -k 5 120 apk add --no-cache emacs-x11 xvfb fontconfig gsettings-desktop-schemas >/proof/packages.log 2>&1
    cd /repo
    mkfifo /proof/display-number
    Xvfb -displayfd 3 -screen 0 720x1440x24 -nolisten tcp -ac \
        3>/proof/display-number >/proof/xvfb.log 2>&1 &
    server_pid=$!
    trap "kill $server_pid 2>/dev/null || true" EXIT
    display=$(timeout -k 1 5 cat /proof/display-number)
    DISPLAY=:$display FONTCONFIG_FILE=/repo/deploy/pinephone/phone-fonts.conf \
        timeout -k 5 45 emacs -Q -L . --load tests/test-phone-typography.el
    ' || {
    for log in emacs-error.txt emacs-messages.log xvfb.log; do
        [ ! -f "$proof_dir/$log" ] || cat "$proof_dir/$log"
    done
    tail -5 "$proof_dir/packages.log"
    exit 1
}
cat "$proof_dir/inter-native-result.json"
