#!/bin/sh
# Build the pinned EmacsOS wvkbd revision for the PinePhone.

set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
source_dir=${WVKBD_REPO_DIR:?set WVKBD_REPO_DIR to the wvkbd checkout}
output_dir=${WVKBD_BUILD_DIR:?set WVKBD_BUILD_DIR to the artifact directory}
revision_file=$repo_dir/deploy/pinephone/wvkbd-revision
image='alpine:3.22@sha256:14358309a308569c32bdc37e2e0e9694be33a9d99e68afb0f5ff33cc1f695dce'
v016=29639c28d5d5b6761eea5108ad4673e07f259edc

fail() {
    printf 'wvkbd-build: %s\n' "$1" >&2
    exit 1
}

verify_dynamic_contract() {
    path=$1
    label=$2
    shift 2
    dynamic=$(readelf -d "$path") || fail "$label dynamic section is unreadable"
    if printf '%s\n' "$dynamic" | grep -Eq '\((RPATH|RUNPATH)\)'; then
        fail "$label contains a runtime library search path"
    fi
    needed=$(printf '%s\n' "$dynamic" |
        sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' | LC_ALL=C sort)
    expected=$(printf '%s\n' "$@" | LC_ALL=C sort)
    [ "$needed" = "$expected" ] || fail "$label has unexpected dynamic dependencies"
}

[ "$#" -eq 0 ] || fail 'arguments are not accepted'
[ -d "$source_dir" ] && [ ! -L "$source_dir" ] ||
    fail 'WVKBD_REPO_DIR must be a directory, not a symlink'
source_dir=$(CDPATH='' cd -- "$source_dir" && pwd)
git -C "$source_dir" rev-parse --is-inside-work-tree 2>/dev/null |
    grep -Fx true >/dev/null || fail 'WVKBD_REPO_DIR is not a Git worktree'
[ -f "$revision_file" ] && [ ! -L "$revision_file" ] ||
    fail 'wvkbd revision file is unavailable'
expected=$(sed -n '1p' "$revision_file")
[ "$(wc -l <"$revision_file")" -eq 1 ] &&
    printf '%s\n' "$expected" | grep -Eq '^[0-9a-f]{40}$' ||
    fail 'wvkbd revision file is invalid'
actual=$(git -C "$source_dir" rev-parse HEAD)
[ "$actual" = "$expected" ] || fail 'wvkbd checkout is not at the pinned revision'
git -C "$source_dir" merge-base --is-ancestor "$v016" HEAD ||
    fail 'pinned wvkbd revision is not based on v0.16'
[ -z "$(git -C "$source_dir" status --porcelain --untracked-files=normal)" ] ||
    fail 'wvkbd checkout is dirty'

mkdir -p -- "$output_dir"
[ -d "$output_dir" ] && [ ! -L "$output_dir" ] ||
    fail 'WVKBD_BUILD_DIR must be a directory, not a symlink'
output_dir=$(CDPATH='' cd -- "$output_dir" && pwd)
output=$output_dir/wvkbd-emacsos
benchmark=$output_dir/bench-glide
notice=$output_dir/wordninja.txt
archive=$(mktemp "$output_dir/.wvkbd-archive.XXXXXX")
cleanup() { rm -f -- "$archive"; }
trap cleanup EXIT HUP INT TERM
git -C "$source_dir" archive --format=tar "$expected" >"$archive"

command -v docker >/dev/null 2>&1 || fail 'docker is required'
if ! docker run --rm --platform linux/arm64 "$image" /bin/true; then
    printf '%s\n' \
        'wvkbd-build: arm64 container preflight failed; verify Docker access and image availability' \
        'wvkbd-build: on a non-arm64 host, install binfmt once with:' \
        '  docker run --privileged --rm tonistiigi/binfmt --install arm64' \
        >&2
    exit 1
fi

host_uid=$(id -u)
host_gid=$(id -g)
docker run --rm --platform linux/arm64 \
    --mount "type=bind,src=$archive,dst=/source.tar,readonly" \
    --mount "type=bind,src=$output_dir,dst=/out" \
    -e HOST_UID="$host_uid" -e HOST_GID="$host_gid" \
    "$image" /bin/sh -ec '
        # Fail closed if Alpine no longer offers this reviewed dependency set.
        apk add --no-cache \
            build-base=0.5-r3 \
            cairo-dev=1.18.4-r0 \
            pango-dev=1.56.3-r0 \
            wayland-dev=1.23.1-r3 \
            libxkbcommon-dev=1.8.1-r2 \
            scdoc=1.11.3-r0 >/dev/null
        mkdir /build
        tar -xf /source.tar -C /build
        make -C /build BIN=wvkbd-emacsos LAYOUT=mobintl
        make -C /build tests/bench-glide
        temporary=$(mktemp /out/.wvkbd-emacsos.XXXXXX)
        trap '\''rm -f -- "$temporary"'\'' EXIT HUP INT TERM
        install -o "$HOST_UID" -g "$HOST_GID" -m 0755 \
            /build/wvkbd-emacsos "$temporary"
        mv -f -- "$temporary" /out/wvkbd-emacsos
        install -o "$HOST_UID" -g "$HOST_GID" -m 0755 \
            /build/tests/bench-glide /out/bench-glide
        install -o "$HOST_UID" -g "$HOST_GID" -m 0644 \
            /build/THIRD_PARTY_LICENSES.md /out/wordninja.txt
        temporary=
    '

[ -f "$output" ] && [ ! -L "$output" ] && [ -x "$output" ] ||
    fail 'build did not produce the expected executable'
[ "$(stat -c '%s' "$output")" -le 16777216 ] ||
    fail 'artifact exceeds the 16 MiB install bound'
file "$output" | grep -Eq 'ELF 64-bit LSB (pie )?executable, ARM aarch64' ||
    fail 'artifact is not an AArch64 ELF executable'
readelf -l "$output" |
    grep -F 'Requesting program interpreter: /lib/ld-musl-aarch64.so.1' \
        >/dev/null || fail 'artifact does not use the AArch64 musl interpreter'
verify_dynamic_contract "$output" artifact \
    libc.musl-aarch64.so.1 libcairo.so.2 libpango-1.0.so.0 \
    libpangocairo-1.0.so.0 libwayland-client.so.0
[ -f "$benchmark" ] && [ ! -L "$benchmark" ] && [ -x "$benchmark" ] ||
    fail 'build did not produce the benchmark'
[ "$(stat -c '%s' "$benchmark")" -le 16777216 ] ||
    fail 'benchmark exceeds the 16 MiB transfer bound'
file "$benchmark" | grep -Eq 'ELF 64-bit LSB (pie )?executable, ARM aarch64' ||
    fail 'benchmark is not an AArch64 ELF executable'
readelf -l "$benchmark" |
    grep -F 'Requesting program interpreter: /lib/ld-musl-aarch64.so.1' \
        >/dev/null || fail 'benchmark does not use the AArch64 musl interpreter'
verify_dynamic_contract "$benchmark" benchmark libc.musl-aarch64.so.1
readelf --sym-base=10 -sW "$output" |
    awk -f "$repo_dir/deploy/pinephone/check-wvkbd-dictionary-symbols.awk" ||
    fail 'dictionary symbols exceed the 256 KiB bound'
[ -f "$notice" ] && [ ! -L "$notice" ] || fail 'build did not produce the notice'

sha256sum "$output"
