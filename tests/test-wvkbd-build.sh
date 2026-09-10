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
dictionary_symbols=$repo_dir/deploy/pinephone/check-wvkbd-dictionary-symbols.awk
printf '%s\n' \
    '1: 0 163647 OBJECT LOCAL DEFAULT 1 glide_word_bytes' \
    '2: 0 5408 OBJECT LOCAL DEFAULT 1 glide_buckets' |
    awk -f "$dictionary_symbols"
if printf '%s\n' \
    '1: 0 300000 OBJECT LOCAL DEFAULT 1 glide_word_bytes' \
    '2: 0 5408 OBJECT LOCAL DEFAULT 1 glide_buckets' |
    awk -f "$dictionary_symbols"; then
    printf '%s\n' 'oversized dictionary symbols were accepted' >&2
    exit 1
fi
grep -F 'readelf --sym-base=10 -sW "$output"' \
    "$repo_dir/deploy/pinephone/build-wvkbd-emacos.sh" >/dev/null
grep -F 'version=2' "$transaction" >/dev/null
grep -F 'phase=%s' "$transaction" >/dev/null
grep -F 'prior_notice=%s' "$transaction" >/dev/null
grep -F 'boot_id=%s' "$transaction" >/dev/null
grep -F 'owner_pid=%s' "$transaction" >/dev/null
grep -F 'owner_start=%s' "$transaction" >/dev/null
grep -F 'prepare-start' "$transaction" >/dev/null
grep -F 'verify-start' "$transaction" >/dev/null
grep -F 'verify-current' "$transaction" >/dev/null
if grep -F 'EMACSOS_WVKBD_CANDIDATE_SHA256' "$transaction" >/dev/null; then
    printf '%s\n' 'candidate activation is still environment-authorized' >&2
    exit 1
fi
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
        sed "s|service_cgroup=/sys/fs/cgroup/openrc.emacsos-ui|service_cgroup=/tmp/openrc.emacsos-ui|" /transaction >/transaction-base
        install -m 0755 /transaction-base /usr/local/sbin/emacsos-wvkbd-transaction
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
            "/usr/local/sbin/emacsos-wvkbd-transaction verify-start" >/etc/init.d/emacsos-ui
        chmod 0755 /etc/init.d/emacsos-ui
        cat >/usr/sbin/rc-service <<"EOF"
#!/bin/sh
cgroup=/tmp/openrc.emacsos-ui
case $2 in
 status) [ -f /run/emacsos-ui/service ] ;;
 start|restart) for fd in 7 8 9; do case $(readlink "/proc/$$/fd/$fd" 2>/dev/null || true) in /run/wvkbd-emacos-install.lock|/run/emacsos-openrc-install.lock|/run/emacsos-openrc-boot-mode.lock) exit 1 ;; esac; done; /usr/local/sbin/emacsos-wvkbd-transaction prepare-start || exit 1; mkdir -p /run/emacsos-ui "$cgroup"; rm -f /run/emacsos-ui/ready /run/emacsos-ui/service /tmp/startpost-session-verified; [ -f /run/emacsos-ui/pid ] && kill "$(cat /run/emacsos-ui/pid)" 2>/dev/null || true; su -s /bin/sh emacsos-lab -c "/usr/local/bin/wvkbd-emacos --mod-swipe -H 300 -L 300 >/dev/null 2>&1 & echo \$!" >/run/emacsos-ui/pid; chown emacsos-lab:emacsos-lab /run/emacsos-ui/pid; cat /run/emacsos-ui/pid >"$cgroup/cgroup.procs"; printf "populated 1\\n" >"$cgroup/cgroup.events"; : >"$cgroup/cgroup.kill"; printf "ready\\n" >/run/emacsos-ui/ready; chown emacsos-lab:emacsos-lab /run/emacsos-ui/ready; chmod 0600 /run/emacsos-ui/ready; [ ! -e /run/emacsos-ui/service ]; /usr/local/sbin/emacsos-wvkbd-transaction verify-start || exit 1; : >/tmp/startpost-session-verified; [ ! -e /tmp/suppress-service-marker ] || { rm -f /tmp/suppress-service-marker; exit 0; }; : >/run/emacsos-ui/service ;;
 stop) [ -f /run/emacsos-ui/pid ] && kill "$(cat /run/emacsos-ui/pid)" 2>/dev/null || true; printf "populated 0\\n" >"$cgroup/cgroup.events"; : >"$cgroup/cgroup.procs"; rm -f /run/emacsos-ui/service /run/emacsos-ui/ready ;;
esac
EOF
        chmod 0755 /usr/sbin/rc-service
        /usr/sbin/rc-service emacsos-ui start
        [ -e /tmp/startpost-session-verified ]
        new=$(sha256sum /home/user/.cache/wvkbd-emacos.ABC123 | awk "{print \$1}")
        notice=$(sha256sum /home/user/.cache/wvkbd-notice.ABC123 | awk "{print \$1}")
        SUDO_USER=user WVKBD_STAGE=/home/user/.cache/wvkbd-emacos.ABC123 WVKBD_SHA256=$new WVKBD_NOTICE_STAGE=/home/user/.cache/wvkbd-notice.ABC123 WVKBD_NOTICE_SHA256=$notice /usr/local/sbin/emacsos-wvkbd-transaction activate
        [ ! -e /var/lib/emacsos-wvkbd-transaction/state ]
        [ "$(sha256sum /usr/local/bin/wvkbd-emacos | awk "{print \$1}")" = "$new" ]
        # The updater proof has no state behavior and accepts only the exact
        # keyboard PID declared by the OpenRC cgroup.
        mkdir -p /tmp/openrc.emacsos-ui
        : >/tmp/openrc.emacsos-ui/cgroup.events
        : >/tmp/openrc.emacsos-ui/cgroup.kill
        : >/tmp/openrc.emacsos-ui/cgroup.procs
        cat /run/emacsos-ui/pid >/tmp/openrc.emacsos-ui/cgroup.procs
        rm -f /usr/local/bin/wvkbd-emacos
        if /usr/local/sbin/emacsos-wvkbd-transaction verify-current 2>/dev/null; then exit 1; fi
        install -o root -g root -m 0755 /home/user/.cache/wvkbd-emacos.ABC123 /usr/local/bin/wvkbd-emacos
        install -o root -g root -m 0755 /bin/true /usr/local/bin/wvkbd-emacos
        if /usr/local/sbin/emacsos-wvkbd-transaction verify-current 2>/dev/null; then exit 1; fi
        install -o root -g root -m 0755 /home/user/.cache/wvkbd-emacos.ABC123 /usr/local/bin/wvkbd-emacos
        : >/tmp/openrc.emacsos-ui/cgroup.procs
        if /usr/local/sbin/emacsos-wvkbd-transaction verify-current 2>/dev/null; then exit 1; fi
        cat /run/emacsos-ui/pid >/tmp/openrc.emacsos-ui/cgroup.procs
        printf "ready\000" >/run/emacsos-ui/ready
        if /usr/local/sbin/emacsos-wvkbd-transaction verify-current 2>/dev/null; then exit 1; fi
        printf "ready\n" >/run/emacsos-ui/ready
        /usr/local/sbin/emacsos-wvkbd-transaction verify-current
        su -s /bin/sh emacsos-lab -c "sleep 300 & echo \$!" >/tmp/non-keyboard-pid
        cat /run/emacsos-ui/pid /tmp/non-keyboard-pid >/tmp/openrc.emacsos-ui/cgroup.procs
        /usr/local/sbin/emacsos-wvkbd-transaction verify-current
        kill "$(cat /tmp/non-keyboard-pid)"
        cat /run/emacsos-ui/pid >/tmp/openrc.emacsos-ui/cgroup.procs
        # A crash just after commit can meet a stopped service: pre-start must
        # retain only the verified target, clear the marker, then start once.
        /usr/sbin/rc-service emacsos-ui stop
        printf "version=2\\nphase=committed\\nold_sha=%s\\nnew_sha=%s\\nprior_notice=0\\nboot_id=-\\nowner_pid=0\\nowner_start=0\\n" "$new" "$new" >/var/lib/emacsos-wvkbd-transaction/state
        chmod 0600 /var/lib/emacsos-wvkbd-transaction/state
        /usr/local/sbin/emacsos-wvkbd-transaction prepare-start
        [ ! -e /var/lib/emacsos-wvkbd-transaction/state ]
        /usr/sbin/rc-service emacsos-ui start
        # Committed v1 never uses residual backups, but preflight must reject
        # unsafe ones before a caller can clear the durable marker.
        for corrupt in mode link hardlink; do
            /usr/sbin/rc-service emacsos-ui stop
            rm -rf /var/lib/emacsos-wvkbd-transaction
            install -d -o root -g root -m 0700 /var/lib/emacsos-wvkbd-transaction
            install -m 0755 /home/user/.cache/wvkbd-emacos.ABC123 /usr/local/bin/wvkbd-emacos
            printf "version=1\\nphase=committed\\nold_sha=%s\\nnew_sha=%s\\nprior_notice_present=0\\n" "$old" "$new" >/var/lib/emacsos-wvkbd-transaction/state
            chmod 0600 /var/lib/emacsos-wvkbd-transaction/state
            printf inert >/var/lib/emacsos-wvkbd-transaction/previous
            chmod 0600 /var/lib/emacsos-wvkbd-transaction/previous
            case $corrupt in
                mode) chmod 0644 /var/lib/emacsos-wvkbd-transaction/previous ;;
                link) rm -f /var/lib/emacsos-wvkbd-transaction/previous; ln -s /tmp/nope /var/lib/emacsos-wvkbd-transaction/previous ;;
                hardlink) ln /var/lib/emacsos-wvkbd-transaction/previous /var/lib/emacsos-wvkbd-transaction/candidate ;;
            esac
            if /usr/local/sbin/emacsos-wvkbd-transaction validate-upgrade 2>/dev/null; then exit 1; fi
            grep -Fx 'phase=committed' /var/lib/emacsos-wvkbd-transaction/state
        done
        # Each malformed-v1 case deliberately stopped the fake service.  Reset
        # that isolated fixture before exercising the independent v2 session
        # proof below, which requires a live keyboard PID in its cgroup.
        rm -rf /var/lib/emacsos-wvkbd-transaction
        /usr/sbin/rc-service emacsos-ui start
        # The transaction post-start proof still rejects a missing cgroup PID
        # and two matching PIDs inside it.
        printf "version=2\\nphase=committed\\nold_sha=%s\\nnew_sha=%s\\nprior_notice=0\\nboot_id=-\\nowner_pid=0\\nowner_start=0\\n" "$new" "$new" >/var/lib/emacsos-wvkbd-transaction/state
        chmod 0600 /var/lib/emacsos-wvkbd-transaction/state
        : >/tmp/openrc.emacsos-ui/cgroup.procs
        if /usr/local/sbin/emacsos-wvkbd-transaction verify-start 2>/dev/null; then exit 1; fi
        cat /run/emacsos-ui/pid >/tmp/openrc.emacsos-ui/cgroup.procs
        /usr/local/sbin/emacsos-wvkbd-transaction verify-start
        su -s /bin/sh emacsos-lab -c "/usr/local/bin/wvkbd-emacos --mod-swipe -H 300 -L 300 >/dev/null 2>&1 & echo \$!" >/tmp/extra-keyboard-pid
        cat /run/emacsos-ui/pid /tmp/extra-keyboard-pid >/tmp/openrc.emacsos-ui/cgroup.procs
        printf "version=2\\nphase=committed\\nold_sha=%s\\nnew_sha=%s\\nprior_notice=0\\nboot_id=-\\nowner_pid=0\\nowner_start=0\\n" "$new" "$new" >/var/lib/emacsos-wvkbd-transaction/state
        chmod 0600 /var/lib/emacsos-wvkbd-transaction/state
        if /usr/local/sbin/emacsos-wvkbd-transaction verify-start 2>/dev/null; then exit 1; fi
        kill "$(cat /tmp/extra-keyboard-pid)"
        cat /run/emacsos-ui/pid >/tmp/openrc.emacsos-ui/cgroup.procs
        /usr/local/sbin/emacsos-wvkbd-transaction verify-start
        # A candidate whose start hook succeeds while OpenRC never marks the
        # service started must roll back through the full old service gate.
        cc -s -o /home/user/.cache/wvkbd-emacos.DEF456 /tmp/keyboard.c
        printf notice-two >/home/user/.cache/wvkbd-notice.DEF456
        chown user:user /home/user/.cache/wvkbd-emacos.DEF456 /home/user/.cache/wvkbd-notice.DEF456
        chmod 0600 /home/user/.cache/wvkbd-emacos.DEF456 /home/user/.cache/wvkbd-notice.DEF456
        third=$(sha256sum /home/user/.cache/wvkbd-emacos.DEF456 | awk "{print \$1}")
        third_notice=$(sha256sum /home/user/.cache/wvkbd-notice.DEF456 | awk "{print \$1}")
        touch /tmp/suppress-service-marker
        if SUDO_USER=user WVKBD_STAGE=/home/user/.cache/wvkbd-emacos.DEF456 WVKBD_SHA256=$third WVKBD_NOTICE_STAGE=/home/user/.cache/wvkbd-notice.DEF456 WVKBD_NOTICE_SHA256=$third_notice /usr/local/sbin/emacsos-wvkbd-transaction activate; then exit 1; fi
        [ "$(sha256sum /usr/local/bin/wvkbd-emacos | awk "{print \$1}")" = "$new" ]
        [ ! -e /var/lib/emacsos-wvkbd-transaction/state ]
        /usr/sbin/rc-service emacsos-ui status
        /usr/local/sbin/emacsos-wvkbd-transaction verify-start
        # A reboot with a durable pending candidate restores the old target;
        # the start hook then clears only that restored-old state after the
        # in-cgroup session proof, without candidate authorization.
        cp /home/user/.cache/wvkbd-emacos.DEF456 /usr/local/bin/wvkbd-emacos
        cp /usr/local/bin/wvkbd-emacos /tmp/pending-candidate
        cp /home/user/.cache/wvkbd-emacos.ABC123 /var/lib/emacsos-wvkbd-transaction/previous
        chmod 0600 /var/lib/emacsos-wvkbd-transaction/previous
        chown root:root /var/lib/emacsos-wvkbd-transaction/previous
        printf "version=2\\nphase=pending\\nold_sha=%s\\nnew_sha=%s\\nprior_notice=1\\nboot_id=-\\nowner_pid=0\\nowner_start=0\\n" "$new" "$third" >/var/lib/emacsos-wvkbd-transaction/state
        chmod 0600 /var/lib/emacsos-wvkbd-transaction/state
        chown root:root /var/lib/emacsos-wvkbd-transaction/state
        cp /usr/local/share/licenses/wvkbd-emacos/wordninja.txt /var/lib/emacsos-wvkbd-transaction/previous-notice
        chmod 0600 /var/lib/emacsos-wvkbd-transaction/previous-notice
        chown root:root /var/lib/emacsos-wvkbd-transaction/previous-notice
        /usr/local/sbin/emacsos-wvkbd-transaction prepare-start
        [ "$(sha256sum /usr/local/bin/wvkbd-emacos | awk "{print \$1}")" = "$new" ]
        /usr/sbin/rc-service emacsos-ui restart
        [ ! -e /var/lib/emacsos-wvkbd-transaction/state ]
        /usr/sbin/rc-service emacsos-ui status
        # Only this activation shell and this boot may carry a candidate from
        # armed to testing. A stale generation or another boot rolls back
        # before the old target is restored.
        install -d -m 0700 /var/lib/emacsos-wvkbd-transaction
        cp /usr/local/bin/wvkbd-emacos /var/lib/emacsos-wvkbd-transaction/previous
        chmod 0600 /var/lib/emacsos-wvkbd-transaction/previous
        owner=$$
        owner_start=$(cut -d" " -f22 /proc/$$/stat)
        boot=$(cat /proc/sys/kernel/random/boot_id)
        printf "version=2\\nphase=armed\\nold_sha=%s\\nnew_sha=%s\\nprior_notice=0\\nboot_id=%s\\nowner_pid=%s\\nowner_start=%s\\n" "$new" "$new" "$boot" "$owner" "$owner_start" >/var/lib/emacsos-wvkbd-transaction/state
        chmod 0600 /var/lib/emacsos-wvkbd-transaction/state
        /usr/local/sbin/emacsos-wvkbd-transaction prepare-start
        grep -Fx "phase=testing" /var/lib/emacsos-wvkbd-transaction/state
        /usr/local/sbin/emacsos-wvkbd-transaction verify-start
        grep -Fx "phase=testing" /var/lib/emacsos-wvkbd-transaction/state
        sed -i "s/^owner_start=.*/owner_start=999999999/" /var/lib/emacsos-wvkbd-transaction/state
        /usr/local/sbin/emacsos-wvkbd-transaction prepare-start
        grep -Fx "phase=rollback" /var/lib/emacsos-wvkbd-transaction/state
        /usr/sbin/rc-service emacsos-ui restart
        [ ! -e /var/lib/emacsos-wvkbd-transaction/state ]
        cp /usr/local/bin/wvkbd-emacos /var/lib/emacsos-wvkbd-transaction/previous
        chmod 0600 /var/lib/emacsos-wvkbd-transaction/previous
        printf "version=2\\nphase=armed\\nold_sha=%s\\nnew_sha=%s\\nprior_notice=0\\nboot_id=00000000-0000-0000-0000-000000000000\\nowner_pid=%s\\nowner_start=%s\\n" "$new" "$new" "$owner" "$owner_start" >/var/lib/emacsos-wvkbd-transaction/state
        chmod 0600 /var/lib/emacsos-wvkbd-transaction/state
        /usr/local/sbin/emacsos-wvkbd-transaction prepare-start
        grep -Fx "phase=rollback" /var/lib/emacsos-wvkbd-transaction/state
        /usr/sbin/rc-service emacsos-ui restart
        [ ! -e /var/lib/emacsos-wvkbd-transaction/state ]
        # Canonical v1 recovery is deliberately independent of the removed
        # candidate environment authorization. Pending states always restore
        # old, retain their exact durable marker until the old session gate,
        # and tolerate inert candidate snapshots with arbitrary contents.
        for prior in 0 1; do
            for installed in old new; do
                /usr/sbin/rc-service emacsos-ui stop
                rm -rf /var/lib/emacsos-wvkbd-transaction
                install -d -o root -g root -m 0700 /var/lib/emacsos-wvkbd-transaction
                cc -s -o /usr/local/bin/wvkbd-emacos /tmp/keyboard.c
                chmod 0755 /usr/local/bin/wvkbd-emacos
                old=$(sha256sum /usr/local/bin/wvkbd-emacos | awk "{print \$1}")
                cp /usr/local/bin/wvkbd-emacos /var/lib/emacsos-wvkbd-transaction/previous
                chown root:root /var/lib/emacsos-wvkbd-transaction/previous
                chmod 0600 /var/lib/emacsos-wvkbd-transaction/previous
                if [ "$prior" = 1 ]; then
                    install -d -m 0755 /usr/local/share/licenses/wvkbd-emacos
                    printf old-notice >/usr/local/share/licenses/wvkbd-emacos/wordninja.txt
                    cp /usr/local/share/licenses/wvkbd-emacos/wordninja.txt /var/lib/emacsos-wvkbd-transaction/previous-notice
                    chown root:root /var/lib/emacsos-wvkbd-transaction/previous-notice
                    chmod 0600 /var/lib/emacsos-wvkbd-transaction/previous-notice
                else
                    rm -f /usr/local/share/licenses/wvkbd-emacos/wordninja.txt
                fi
                printf inert >/var/lib/emacsos-wvkbd-transaction/candidate
                chmod 0600 /var/lib/emacsos-wvkbd-transaction/candidate
                chown root:root /var/lib/emacsos-wvkbd-transaction/candidate
                printf "version=1\\nphase=pending\\nold_sha=%s\\nnew_sha=%s\\nprior_notice_present=%s\\n" "$old" "$new" "$prior" >/var/lib/emacsos-wvkbd-transaction/state
                chown root:root /var/lib/emacsos-wvkbd-transaction/state
                chmod 0600 /var/lib/emacsos-wvkbd-transaction/state
                if [ "$installed" = new ]; then install -m 0755 /home/user/.cache/wvkbd-emacos.ABC123 /usr/local/bin/wvkbd-emacos; fi
                EMACSOS_WVKBD_CANDIDATE_SHA256="$new" /usr/local/sbin/emacsos-wvkbd-transaction prepare-start
                [ "$(sha256sum /usr/local/bin/wvkbd-emacos | awk "{print \$1}")" = "$old" ]
                cmp -s /var/lib/emacsos-wvkbd-transaction/state - <<EOF
version=1
phase=pending
old_sha=$old
new_sha=$new
prior_notice_present=$prior
EOF
                /usr/sbin/rc-service emacsos-ui start
                [ ! -e /var/lib/emacsos-wvkbd-transaction/state ]
            done
        done
        # A pre-bootstrap init script calls the old finalize-start action. The
        # compat helper must route it through state-aware v1 verification so
        # the old session proof clears the marker and inert artifacts.
        /usr/sbin/rc-service emacsos-ui stop
        rm -rf /var/lib/emacsos-wvkbd-transaction
        install -d -o root -g root -m 0700 /var/lib/emacsos-wvkbd-transaction
        cc -s -o /usr/local/bin/wvkbd-emacos /tmp/keyboard.c
        chmod 0755 /usr/local/bin/wvkbd-emacos
        old=$(sha256sum /usr/local/bin/wvkbd-emacos | awk "{print \$1}")
        cp /usr/local/bin/wvkbd-emacos /var/lib/emacsos-wvkbd-transaction/previous
        chmod 0600 /var/lib/emacsos-wvkbd-transaction/previous
        printf inert >/var/lib/emacsos-wvkbd-transaction/candidate
        chmod 0600 /var/lib/emacsos-wvkbd-transaction/candidate
        printf "version=1\\nphase=pending\\nold_sha=%s\\nnew_sha=%s\\nprior_notice_present=0\\n" "$old" "$new" >/var/lib/emacsos-wvkbd-transaction/state
        chmod 0600 /var/lib/emacsos-wvkbd-transaction/state
        /usr/sbin/rc-service emacsos-ui start
        cp /usr/local/bin/wvkbd-emacos /var/lib/emacsos-wvkbd-transaction/previous
        chmod 0600 /var/lib/emacsos-wvkbd-transaction/previous
        printf inert >/var/lib/emacsos-wvkbd-transaction/candidate
        chmod 0600 /var/lib/emacsos-wvkbd-transaction/candidate
        printf "version=1\\nphase=pending\\nold_sha=%s\\nnew_sha=%s\\nprior_notice_present=0\\n" "$old" "$new" >/var/lib/emacsos-wvkbd-transaction/state
        chmod 0600 /var/lib/emacsos-wvkbd-transaction/state
        /usr/local/sbin/emacsos-wvkbd-transaction finalize-start
        [ ! -e /var/lib/emacsos-wvkbd-transaction/state ]
        [ ! -e /var/lib/emacsos-wvkbd-transaction/previous ]
        [ ! -e /var/lib/emacsos-wvkbd-transaction/candidate ]
        # A stopped committed v1 state retains only the new target and finishes
        # without demanding a session that cannot exist before start.
        /usr/sbin/rc-service emacsos-ui stop
        rm -rf /var/lib/emacsos-wvkbd-transaction
        install -d -o root -g root -m 0700 /var/lib/emacsos-wvkbd-transaction
        install -m 0755 /home/user/.cache/wvkbd-emacos.ABC123 /usr/local/bin/wvkbd-emacos
        printf "version=1\\nphase=committed\\nold_sha=%s\\nnew_sha=%s\\nprior_notice_present=0\\n" "$old" "$new" >/var/lib/emacsos-wvkbd-transaction/state
        chown root:root /var/lib/emacsos-wvkbd-transaction/state
        chmod 0600 /var/lib/emacsos-wvkbd-transaction/state
        /usr/local/sbin/emacsos-wvkbd-transaction prepare-start
        [ ! -e /var/lib/emacsos-wvkbd-transaction/state ]
        /usr/sbin/rc-service emacsos-ui start
        # A committed v1 marker may never bless old or unknown targets.
        for target_case in old unknown; do
            /usr/sbin/rc-service emacsos-ui stop
            rm -rf /var/lib/emacsos-wvkbd-transaction
            install -d -o root -g root -m 0700 /var/lib/emacsos-wvkbd-transaction
            case $target_case in old) cc -s -o /usr/local/bin/wvkbd-emacos /tmp/keyboard.c; chmod 0755 /usr/local/bin/wvkbd-emacos ;; unknown) install -m 0755 /bin/true /usr/local/bin/wvkbd-emacos ;; esac
            printf "version=1\\nphase=committed\\nold_sha=%s\\nnew_sha=%s\\nprior_notice_present=0\\n" "$old" "$new" >/var/lib/emacsos-wvkbd-transaction/state
            chown root:root /var/lib/emacsos-wvkbd-transaction/state
            chmod 0600 /var/lib/emacsos-wvkbd-transaction/state
            if /usr/local/sbin/emacsos-wvkbd-transaction prepare-start 2>/dev/null; then exit 1; fi
        done
        mkdir -p /var/lib/emacsos-wvkbd-transaction
        printf "version=2\nphase=pending\nold_sha=%064d\nnew_sha=%s\nprior_notice=0\nboot_id=-\nowner_pid=0\nowner_start=0\n" 0 "$new" >/var/lib/emacsos-wvkbd-transaction/state
        cp /usr/local/bin/wvkbd-emacos /var/lib/emacsos-wvkbd-transaction/previous
        chmod 0600 /var/lib/emacsos-wvkbd-transaction/state /var/lib/emacsos-wvkbd-transaction/previous
        chown root:root /var/lib/emacsos-wvkbd-transaction/state /var/lib/emacsos-wvkbd-transaction/previous
        if /usr/local/sbin/emacsos-wvkbd-transaction prepare-start 2>/dev/null; then exit 1; fi
        rm -f /var/lib/emacsos-wvkbd-transaction/state /var/lib/emacsos-wvkbd-transaction/previous
        sed "s|checkpoint() { :; }|checkpoint() { if [ \"\${WVKBD_TEST_KILL_AT-}\" = \"\$1\" ]; then kill -KILL \"\$\$\"; fi; return 0; }|" /transaction-base >/transaction-test
        chmod 0755 /transaction-test
        for point in before-pending after-pending after-notice-install \
            temporary-/usr/local/bin/wvkbd-emacos renamed-/usr/local/bin/wvkbd-emacos \
            installed-/usr/local/bin/wvkbd-emacos after-candidate-rename \
            before-candidate-restart during-candidate-restart after-candidate-restart \
            session-cgroup session-ready-metadata session-ready-content session-keyboard session-proc-exe \
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
                /transaction-test verify-start
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
            printf "version=2\nphase=pending\nold_sha=%s\nnew_sha=%s\nprior_notice=0\nboot_id=-\nowner_pid=0\nowner_start=0\n" "$old" "$new" >/var/lib/emacsos-wvkbd-transaction/state
            chmod 0600 /var/lib/emacsos-wvkbd-transaction/state
            case $corrupt in
                state-dir) chmod 0755 /var/lib/emacsos-wvkbd-transaction ;;
                state-mode) chmod 0644 /var/lib/emacsos-wvkbd-transaction/state ;;
                state-link) rm -f /var/lib/emacsos-wvkbd-transaction/state; ln -s /tmp/nope /var/lib/emacsos-wvkbd-transaction/state ;;
                state-type) rm -f /var/lib/emacsos-wvkbd-transaction/state; mkdir /var/lib/emacsos-wvkbd-transaction/state ;;
                state-size) dd if=/dev/zero bs=513 count=1 of=/var/lib/emacsos-wvkbd-transaction/state status=none ;;
                state-fields) printf "version=2\nphase=broken\nold_sha=%s\nnew_sha=%s\nprior_notice=0\nboot_id=-\nowner_pid=0\nowner_start=0\n" "$old" "$new" >/var/lib/emacsos-wvkbd-transaction/state ;;
                legacy-v1) printf "version=1\nphase=pending\nold_sha=%s\nnew_sha=%s\nprior_notice_present=0\n" "$old" "$new" >/var/lib/emacsos-wvkbd-transaction/state ;;
                previous-digest) printf bad >/var/lib/emacsos-wvkbd-transaction/previous ;;
                previous-link) rm -f /var/lib/emacsos-wvkbd-transaction/previous; ln -s /tmp/nope /var/lib/emacsos-wvkbd-transaction/previous ;;
                notice-metadata) printf "version=2\nphase=pending\nold_sha=%s\nnew_sha=%s\nprior_notice=1\nboot_id=-\nowner_pid=0\nowner_start=0\n" "$old" "$new" >/var/lib/emacsos-wvkbd-transaction/state; printf old-notice >/var/lib/emacsos-wvkbd-transaction/previous-notice; chmod 0644 /var/lib/emacsos-wvkbd-transaction/previous-notice ;;
            esac
            if /usr/local/sbin/emacsos-wvkbd-transaction prepare-start 2>/dev/null; then exit 1; fi
            [ ! -e /tmp/emacsos-ui-running ]
        done
        kill "$(cat /run/emacsos-ui/pid)" 2>/dev/null || true
    '

printf '%s\n' 'wvkbd build and atomic side-by-side install checks passed'
