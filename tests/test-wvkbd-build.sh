#!/bin/sh

set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
wvkbd_dir=${WVKBD_REPO_DIR:?set WVKBD_REPO_DIR to the wvkbd checkout}
build_dir=$repo_dir/.build/wvkbd-test
artifact=$build_dir/wvkbd-emacos
benchmark=$build_dir/bench-glide
scratch=$(mktemp -d)
trap 'rm -rf -- "$scratch"' EXIT HUP INT TERM
build_image=$(awk -F "'" '$1 == "image=" && NF == 3 { print $2 }' \
    "$repo_dir/deploy/pinephone/build-wvkbd-emacos.sh")
[ -n "$build_image" ] && [ "$(printf '%s\n' "$build_image" | wc -l)" -eq 1 ] || {
    printf '%s\n' 'could not read the pinned keyboard build image' >&2
    exit 1
}

assert_dynamic_contract() {
    path=$1
    shift
    dynamic=$(readelf -d "$path")
    if printf '%s\n' "$dynamic" | grep -Eq '\((RPATH|RUNPATH)\)'; then
        printf '%s\n' "$path contains a runtime library search path" >&2
        exit 1
    fi
    needed=$(printf '%s\n' "$dynamic" |
        sed -n 's/.*Shared library: \[\([^]]*\)\].*/\1/p' | LC_ALL=C sort)
    expected=$(printf '%s\n' "$@" | LC_ALL=C sort)
    [ "$needed" = "$expected" ] || {
        printf '%s\n' "$path has unexpected dynamic dependencies" >&2
        exit 1
    }
}

for script in \
    "$repo_dir/deploy/pinephone/build-wvkbd-emacos.sh" \
    "$repo_dir/deploy/pinephone/bench-wvkbd-emacos.sh" \
    "$repo_dir/deploy/pinephone/install-wvkbd-emacos.sh" \
    "$repo_dir/deploy/pinephone/install-wvkbd-emacos-root" \
    "$repo_dir/deploy/pinephone/wvkbd-transaction-root"
do
sh -n "$script"
done
make -s -n -C "$repo_dir" wvkbd-phone-bench PINEPHONE_HOST=phone-wg |
    grep -F 'bench-wvkbd-emacos.sh' >/dev/null
grep -F 'timeout 60' "$repo_dir/deploy/pinephone/bench-wvkbd-emacos.sh" >/dev/null
grep -F 'wvkbd-bench.XXXXXX' "$repo_dir/deploy/pinephone/bench-wvkbd-emacos.sh" >/dev/null
grep -F "&& file" "$repo_dir/deploy/pinephone/bench-wvkbd-emacos.sh" >/dev/null
transaction=$repo_dir/deploy/pinephone/wvkbd-transaction-root
grep -F 'version=1' "$transaction" >/dev/null
grep -F 'phase=%s' "$transaction" >/dev/null
grep -F 'prior_notice_present=%s' "$transaction" >/dev/null
grep -F 'prepare-start' "$transaction" >/dev/null
grep -F 'finalize-start' "$transaction" >/dev/null
grep -F 'EMACSOS_WVKBD_CANDIDATE_SHA256' "$transaction" >/dev/null
grep -F '/usr/local/share/licenses/wvkbd-emacos/wordninja.txt' "$transaction" >/dev/null
grep -F 'wvkbd-transaction-root' "$repo_dir/deploy/pinephone/openrc-manifest.sha256" >/dev/null
grep -F 'WVKBD_NOTICE_STAGE' "$repo_dir/deploy/pinephone/install-wvkbd-emacos.sh" >/dev/null
revision=$(cat "$repo_dir/deploy/pinephone/wvkbd-revision")
printf '%s\n' "$revision" | grep -Eq '^[0-9a-f]{40}$'
make_output=$(make -C "$wvkbd_dir" -n BIN=wvkbd-emacos LAYOUT=mobintl)
printf '%s\n' "$make_output" | grep -F ' -o wvkbd-emacos ' >/dev/null
grep -F 'target=/usr/local/bin/wvkbd-emacos' "$transaction" >/dev/null
if grep -F 'target=/usr/bin/wvkbd-mobintl' \
    "$transaction" >/dev/null; then
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
git -C "$scratch/wvkbd" checkout -q --detach "$revision"
: >"$scratch/wvkbd/untracked"
if WVKBD_REPO_DIR=$scratch/wvkbd WVKBD_BUILD_DIR=$scratch/output \
    "$repo_dir/deploy/pinephone/build-wvkbd-emacos.sh" 2>/dev/null; then
    printf '%s\n' 'dirty source checkout was accepted' >&2
    exit 1
fi

# The builder archives the pinned tree.  Ignored hostile build debris must not
# reach that archive or alter either installed artifact.
rm -f -- "$scratch/wvkbd/untracked"
WVKBD_REPO_DIR=$scratch/wvkbd WVKBD_BUILD_DIR=$scratch/archive-baseline \
    "$repo_dir/deploy/pinephone/build-wvkbd-emacos.sh" >/dev/null
baseline_keyboard=$(sha256sum "$scratch/archive-baseline/wvkbd-emacos" | awk '{print $1}')
baseline_benchmark=$(sha256sum "$scratch/archive-baseline/bench-glide" | awk '{print $1}')
printf '%s\n' hostile-config >"$scratch/wvkbd/config.h"
: >"$scratch/wvkbd/keyboard.o"
: >"$scratch/wvkbd/wvkbd"
printf '%s\n' generated-hostile.c >>"$scratch/wvkbd/.git/info/exclude"
printf '%s\n' hostile-source >"$scratch/wvkbd/generated-hostile.c"
WVKBD_REPO_DIR=$scratch/wvkbd WVKBD_BUILD_DIR=$scratch/archive-hostile \
    "$repo_dir/deploy/pinephone/build-wvkbd-emacos.sh" >/dev/null
[ "$(sha256sum "$scratch/archive-hostile/wvkbd-emacos" | awk '{print $1}')" = "$baseline_keyboard" ]
[ "$(sha256sum "$scratch/archive-hostile/bench-glide" | awk '{print $1}')" = "$baseline_benchmark" ]
cmp -s "$scratch/archive-hostile/wordninja.txt" "$scratch/archive-baseline/wordninja.txt"

WVKBD_BUILD_DIR=$build_dir "$repo_dir/deploy/pinephone/build-wvkbd-emacos.sh"
[ -f "$artifact" ] && [ -x "$artifact" ]
[ "$(stat -c '%s' "$artifact")" -le 16777216 ]
file "$artifact" | grep -F 'ARM aarch64' >/dev/null
readelf -l "$artifact" |
    grep -F 'Requesting program interpreter: /lib/ld-musl-aarch64.so.1' >/dev/null
assert_dynamic_contract "$artifact" \
    libc.musl-aarch64.so.1 libcairo.so.2 libpango-1.0.so.0 \
    libpangocairo-1.0.so.0 libwayland-client.so.0
[ -f "$benchmark" ] && [ -x "$benchmark" ]
[ "$(stat -c '%s' "$benchmark")" -le 16777216 ]
file "$benchmark" | grep -F 'ARM aarch64' >/dev/null
readelf -l "$benchmark" |
    grep -F 'Requesting program interpreter: /lib/ld-musl-aarch64.so.1' >/dev/null
assert_dynamic_contract "$benchmark" libc.musl-aarch64.so.1

notice=$build_dir/wordninja.txt
[ -f "$notice" ] && [ ! -L "$notice" ]
cmp -s "$notice" "$wvkbd_dir/THIRD_PARTY_LICENSES.md"
grep -F 'recovery helper is not installed safely' \
    "$repo_dir/deploy/pinephone/install-wvkbd-emacos-root" >/dev/null
grep -F 'OpenRC UI transaction hooks are not installed safely' \
    "$repo_dir/deploy/pinephone/install-wvkbd-emacos-root" >/dev/null
grep -F 'os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW' "$transaction" >/dev/null
grep -F 'candidate failed; old keyboard restored' "$transaction" >/dev/null
grep -F 'write_state committed' "$transaction" >/dev/null
grep -F 'normal_recovery' "$transaction" >/dev/null

# Exercise the fixed-path root helper in a disposable Alpine root.  The fake
# OpenRC command starts one exact-argv ELF and writes the normal readiness proof.
docker run --rm --cap-add SYS_PTRACE \
    -v "$transaction:/transaction:ro" \
    -v "$repo_dir/deploy/pinephone/install-wvkbd-emacos-root:/install-root:ro" \
    "$build_image" /bin/sh -ec '
        apk add --no-cache build-base shadow python3 >/dev/null
        adduser -D user; adduser -D emacsos-lab
        install -d -o user -g user -m 0700 /home/user/.cache
        install -d -o root -g root -m 0755 /usr/local/bin /usr/local/sbin /usr/sbin /etc/init.d
        cat >/tmp/keyboard.c <<"EOF"
#include <unistd.h>
int main(void) { for (;;) sleep(60); }
EOF
        cc -s -o /usr/local/bin/wvkbd-emacos /tmp/keyboard.c
        chmod 0755 /usr/local/bin/wvkbd-emacos
        old=$(sha256sum /usr/local/bin/wvkbd-emacos | awk "{print \$1}")
        cat >/tmp/new.c <<"EOF"
#include <unistd.h>
int main(void) { for (;;) sleep(61); }
EOF
        cc -s -o /home/user/.cache/wvkbd-emacos.ABC123 /tmp/new.c
        printf notice >/home/user/.cache/wvkbd-notice.ABC123
        chown user:user /home/user/.cache/wvkbd-*; chmod 0600 /home/user/.cache/wvkbd-*
        install -m 0755 /transaction /usr/local/sbin/emacsos-wvkbd-transaction
        install -m 0755 /install-root /usr/local/sbin/install-wvkbd-emacos
        for invalid in missing unsafe one-hook; do
            rm -f /etc/init.d/emacsos-ui
            case $invalid in
                missing) ;;
                unsafe) printf "#!/bin/sh\n" >/etc/init.d/emacsos-ui; chmod 0777 /etc/init.d/emacsos-ui ;;
                one-hook) printf "/usr/local/sbin/emacsos-wvkbd-transaction prepare-start || return 1\n" >/etc/init.d/emacsos-ui; chmod 0755 /etc/init.d/emacsos-ui ;;
            esac
            if SUDO_USER=user /usr/local/sbin/install-wvkbd-emacos >/dev/null 2>&1; then exit 1; fi
        done
        printf "%s\n%s\n" \
            "/usr/local/sbin/emacsos-wvkbd-transaction prepare-start || return 1" \
            "/usr/local/sbin/emacsos-wvkbd-transaction finalize-start" >/etc/init.d/emacsos-ui
        chmod 0755 /etc/init.d/emacsos-ui
        cat >/usr/sbin/rc-service <<"EOF"
#!/bin/sh
case $2 in
 status) [ -f /run/emacsos-ui/service ] ;;
 start|restart) mkdir -p /run/emacsos-ui; rm -f /run/emacsos-ui/ready; [ -f /run/emacsos-ui/pid ] && kill "$(cat /run/emacsos-ui/pid)" 2>/dev/null || true; su -s /bin/sh emacsos-lab -c "/usr/local/bin/wvkbd-emacos --mod-swipe -H 300 -L 300 >/dev/null 2>&1 & echo \$!" >/run/emacsos-ui/pid; chown emacsos-lab:emacsos-lab /run/emacsos-ui/pid; printf ready >/run/emacsos-ui/ready; chown emacsos-lab:emacsos-lab /run/emacsos-ui/ready; chmod 0600 /run/emacsos-ui/ready; : >/run/emacsos-ui/service ;;
 stop) [ -f /run/emacsos-ui/pid ] && kill "$(cat /run/emacsos-ui/pid)" 2>/dev/null || true; rm -f /run/emacsos-ui/service /run/emacsos-ui/ready ;;
esac
EOF
        chmod 0755 /usr/sbin/rc-service
        /usr/sbin/rc-service start
        new=$(sha256sum /home/user/.cache/wvkbd-emacos.ABC123 | awk "{print \$1}")
        notice=$(sha256sum /home/user/.cache/wvkbd-notice.ABC123 | awk "{print \$1}")
        SUDO_USER=user WVKBD_STAGE=/home/user/.cache/wvkbd-emacos.ABC123 WVKBD_SHA256=$new WVKBD_NOTICE_STAGE=/home/user/.cache/wvkbd-notice.ABC123 WVKBD_NOTICE_SHA256=$notice /usr/local/sbin/emacsos-wvkbd-transaction activate
        [ ! -e /var/lib/emacsos-wvkbd-transaction/state ]
        [ "$(sha256sum /usr/local/bin/wvkbd-emacos | awk "{print \$1}")" = "$new" ]
        mkdir -p /var/lib/emacsos-wvkbd-transaction
        printf "version=1\nphase=pending\nold_sha=%064d\nnew_sha=%s\nprior_notice_present=0\n" 0 "$new" >/var/lib/emacsos-wvkbd-transaction/state
        cp /usr/local/bin/wvkbd-emacos /var/lib/emacsos-wvkbd-transaction/previous
        chmod 0600 /var/lib/emacsos-wvkbd-transaction/state /var/lib/emacsos-wvkbd-transaction/previous
        chown root:root /var/lib/emacsos-wvkbd-transaction/state /var/lib/emacsos-wvkbd-transaction/previous
        if /usr/local/sbin/emacsos-wvkbd-transaction prepare-start 2>/dev/null; then exit 1; fi
        rm -f /var/lib/emacsos-wvkbd-transaction/state /var/lib/emacsos-wvkbd-transaction/previous
        sed "s|checkpoint() { :; }|checkpoint() { if [ \"\${WVKBD_TEST_KILL_AT-}\" = \"\$1\" ]; then kill -KILL \"\$\$\"; fi; return 0; }|" /transaction >/transaction-test
        chmod 0755 /transaction-test
        for point in before-pending after-pending after-notice-install \
            temporary-/usr/local/bin/wvkbd-emacos renamed-/usr/local/bin/wvkbd-emacos \
            installed-/usr/local/bin/wvkbd-emacos after-candidate-rename \
            before-candidate-restart during-candidate-restart after-candidate-restart \
            gate-status gate-ready-metadata gate-ready-content gate-process gate-proc-exe \
            after-candidate-gate after-committed cleanup-notice cleanup-previous cleanup-state; do
            for prior in present absent; do
                /usr/sbin/rc-service emacsos-ui stop
                rm -rf /var/lib/emacsos-wvkbd-transaction
                if [ "$prior" = present ]; then
                    install -d -m 0755 /usr/local/share/licenses/wvkbd-emacos
                    install -m 0644 /home/user/.cache/wvkbd-notice.ABC123 /usr/local/share/licenses/wvkbd-emacos/wordninja.txt
                else
                    rm -f /usr/local/share/licenses/wvkbd-emacos/wordninja.txt
                fi
                cc -s -o /usr/local/bin/wvkbd-emacos /tmp/keyboard.c
                chmod 0755 /usr/local/bin/wvkbd-emacos
                old=$(sha256sum /usr/local/bin/wvkbd-emacos | awk "{print \$1}")
                if SUDO_USER=user WVKBD_STAGE=/home/user/.cache/wvkbd-emacos.ABC123 WVKBD_SHA256=$new WVKBD_NOTICE_STAGE=/home/user/.cache/wvkbd-notice.ABC123 WVKBD_NOTICE_SHA256=$notice WVKBD_TEST_KILL_AT=$point /transaction-test activate; then exit 1; fi
                case $point in after-committed|cleanup-*) expected=$new ;; *) expected=$old ;; esac
                /transaction-test prepare-start
                [ "$(sha256sum /usr/local/bin/wvkbd-emacos | awk "{print \$1}")" = "$expected" ]
                /usr/sbin/rc-service emacsos-ui start
                /transaction-test finalize-start
                [ ! -e /var/lib/emacsos-wvkbd-transaction/state ]
                [ "$(sha256sum /usr/local/bin/wvkbd-emacos | awk "{print \$1}")" = "$expected" ]
                [ "$(for proc in /proc/[0-9]*; do [ "$(stat -c %U "$proc" 2>/dev/null || true)" = emacsos-lab ] || continue; actual=$(tr "\000" " " <"$proc/cmdline" | sed "s/ $//"); [ "$actual" = "/usr/local/bin/wvkbd-emacos --mod-swipe -H 300 -L 300" ] && printf x; done | wc -c)" -eq 1 ]
            done
        done
        for corrupt in state-dir state-mode state-link state-type state-size state-fields previous-digest previous-link notice-metadata; do
            /usr/sbin/rc-service emacsos-ui stop
            rm -rf /var/lib/emacsos-wvkbd-transaction
            cc -s -o /usr/local/bin/wvkbd-emacos /tmp/keyboard.c
            chmod 0755 /usr/local/bin/wvkbd-emacos
            old=$(sha256sum /usr/local/bin/wvkbd-emacos | awk "{print \$1}")
            install -d -m 0700 /var/lib/emacsos-wvkbd-transaction
            cp /usr/local/bin/wvkbd-emacos /var/lib/emacsos-wvkbd-transaction/previous
            chmod 0600 /var/lib/emacsos-wvkbd-transaction/previous
            printf "version=1\nphase=pending\nold_sha=%s\nnew_sha=%s\nprior_notice_present=0\n" "$old" "$new" >/var/lib/emacsos-wvkbd-transaction/state
            chmod 0600 /var/lib/emacsos-wvkbd-transaction/state
            case $corrupt in
                state-dir) chmod 0755 /var/lib/emacsos-wvkbd-transaction ;;
                state-mode) chmod 0644 /var/lib/emacsos-wvkbd-transaction/state ;;
                state-link) rm -f /var/lib/emacsos-wvkbd-transaction/state; ln -s /tmp/nope /var/lib/emacsos-wvkbd-transaction/state ;;
                state-type) rm -f /var/lib/emacsos-wvkbd-transaction/state; mkdir /var/lib/emacsos-wvkbd-transaction/state ;;
                state-size) dd if=/dev/zero bs=513 count=1 of=/var/lib/emacsos-wvkbd-transaction/state status=none ;;
                state-fields) printf "version=1\nphase=broken\nold_sha=%s\nnew_sha=%s\nprior_notice_present=0\n" "$old" "$new" >/var/lib/emacsos-wvkbd-transaction/state ;;
                previous-digest) printf bad >/var/lib/emacsos-wvkbd-transaction/previous ;;
                previous-link) rm -f /var/lib/emacsos-wvkbd-transaction/previous; ln -s /tmp/nope /var/lib/emacsos-wvkbd-transaction/previous ;;
                notice-metadata) printf "version=1\nphase=pending\nold_sha=%s\nnew_sha=%s\nprior_notice_present=1\n" "$old" "$new" >/var/lib/emacsos-wvkbd-transaction/state; printf old-notice >/var/lib/emacsos-wvkbd-transaction/previous-notice; chmod 0644 /var/lib/emacsos-wvkbd-transaction/previous-notice ;;
            esac
            if /usr/local/sbin/emacsos-wvkbd-transaction prepare-start 2>/dev/null; then exit 1; fi
            [ ! -e /tmp/emacsos-ui-running ]
        done
        kill "$(cat /run/emacsos-ui/pid)" 2>/dev/null || true
    '

printf '%s\n' 'wvkbd build and atomic side-by-side install checks passed'
