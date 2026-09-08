#!/bin/sh

set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
wvkbd_dir=${WVKBD_REPO_DIR:?set WVKBD_REPO_DIR to the wvkbd checkout}
build_dir=$repo_dir/.build/wvkbd-test
artifact=$build_dir/wvkbd-emacos
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT HUP INT TERM

for script in \
    "$repo_dir/deploy/pinephone/build-wvkbd-emacos.sh" \
    "$repo_dir/deploy/pinephone/install-wvkbd-emacos.sh" \
    "$repo_dir/deploy/pinephone/install-wvkbd-emacos-root"
do
    sh -n "$script"
done
grep -Fx '1ac7c8642e0327dde653f109a69e477f53e04dc5' \
    "$repo_dir/deploy/pinephone/wvkbd-revision" >/dev/null
make_output=$(make -C "$wvkbd_dir" -n BIN=wvkbd-emacos LAYOUT=mobintl)
printf '%s\n' "$make_output" | grep -F ' -o wvkbd-emacos ' >/dev/null
grep -F 'target=/usr/local/bin/wvkbd-emacos' \
    "$repo_dir/deploy/pinephone/install-wvkbd-emacos-root" >/dev/null
if grep -F 'target=/usr/bin/wvkbd-mobintl' \
    "$repo_dir/deploy/pinephone/install-wvkbd-emacos-root" >/dev/null; then
    printf '%s\n' 'installer targets the packaged fallback' >&2
    exit 1
fi

if WVKBD_REPO_DIR=$scratch/missing WVKBD_BUILD_DIR=$scratch/output \
    "$repo_dir/deploy/pinephone/build-wvkbd-emacos.sh" 2>/dev/null; then
    printf '%s\n' 'missing source checkout was accepted' >&2
    exit 1
fi
git clone -q --no-hardlinks "$wvkbd_dir" "$scratch/wvkbd"
git -C "$scratch/wvkbd" checkout -q --detach v0.16
if WVKBD_REPO_DIR=$scratch/wvkbd WVKBD_BUILD_DIR=$scratch/output \
    "$repo_dir/deploy/pinephone/build-wvkbd-emacos.sh" 2>/dev/null; then
    printf '%s\n' 'wrong source revision was accepted' >&2
    exit 1
fi
git -C "$scratch/wvkbd" checkout -q --detach \
    1ac7c8642e0327dde653f109a69e477f53e04dc5
: >"$scratch/wvkbd/untracked"
if WVKBD_REPO_DIR=$scratch/wvkbd WVKBD_BUILD_DIR=$scratch/output \
    "$repo_dir/deploy/pinephone/build-wvkbd-emacos.sh" 2>/dev/null; then
    printf '%s\n' 'dirty source checkout was accepted' >&2
    exit 1
fi

WVKBD_BUILD_DIR=$build_dir "$repo_dir/deploy/pinephone/build-wvkbd-emacos.sh"
[ -f "$artifact" ] && [ -x "$artifact" ]
file "$artifact" | grep -F 'ARM aarch64' >/dev/null
readelf -l "$artifact" |
    grep -F 'Requesting program interpreter: /lib/ld-musl-aarch64.so.1' >/dev/null

docker run --rm \
    -v "$repo_dir/deploy/pinephone/install-wvkbd-emacos-root:/root-helper:ro" \
    -v "$artifact:/artifact:ro" alpine:3.22 /bin/sh -ec '
        adduser -D user
        install -d -o user -g user -m 0700 /home/user/.cache
        install -o user -g user -m 0600 /artifact \
            /home/user/.cache/wvkbd-emacos.ABC123
        digest=$(sha256sum /home/user/.cache/wvkbd-emacos.ABC123)
        digest=${digest%% *}
        install -m 0755 /bin/true /usr/local/bin/wvkbd-emacos
        original=$(sha256sum /usr/local/bin/wvkbd-emacos)
        original=${original%% *}
        if SUDO_USER=user \
            WVKBD_STAGE=/home/user/.cache/wvkbd-emacos.ABC123 \
            WVKBD_SHA256=$(printf "%064d" 0) /bin/sh /root-helper 2>/dev/null; then
            printf "%s\n" "installer accepted the wrong artifact digest" >&2
            exit 1
        fi
        [ "$(sha256sum /usr/local/bin/wvkbd-emacos)" = \
          "$original  /usr/local/bin/wvkbd-emacos" ]
        SUDO_USER=user \
        WVKBD_STAGE=/home/user/.cache/wvkbd-emacos.ABC123 \
        WVKBD_SHA256=$digest /bin/sh /root-helper
        [ -x /usr/local/bin/wvkbd-emacos ]
        [ "$(sha256sum /usr/local/bin/wvkbd-emacos)" = \
          "$digest  /usr/local/bin/wvkbd-emacos" ]
        [ ! -e /usr/bin/wvkbd-mobintl ]
    '

printf '%s\n' 'wvkbd build and atomic side-by-side install checks passed'
