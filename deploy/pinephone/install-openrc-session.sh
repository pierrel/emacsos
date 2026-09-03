#!/bin/sh
# Stage and install the reviewed v25.06/OpenRC PinePhone session.

set -eu
PATH=/usr/bin:/usr/sbin:/bin:/sbin
umask 077
export PATH

phone_host=${PINEPHONE_HOST:?set PINEPHONE_HOST to the SSH profile}
repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/../.." && pwd)
deploy_dir=$repo_dir/deploy/pinephone
stage=/home/user/.cache/emacsos-openrc-stage
bootstrap=/home/user/.cache/emacsos-openrc-bootstrap
bootstrap_local=

cleanup() {
    [ -z "$bootstrap_local" ] || rm -f -- "$bootstrap_local"
}
trap cleanup EXIT
trap 'exit 1' HUP INT TERM

set -- -o User=user -o BatchMode=yes -o PreferredAuthentications=publickey \
    -o PubkeyAuthentication=yes -o PasswordAuthentication=no \
    -o KbdInteractiveAuthentication=no -o GSSAPIAuthentication=no \
    -o HostbasedAuthentication=no -o ConnectTimeout=10 \
    -o ServerAliveInterval=5 -o ServerAliveCountMax=3

"$repo_dir/tests/test-pinephone-openrc-deploy.sh"

ssh -T "$@" "$phone_host" \
    "rm -rf -- '$stage' '$bootstrap' && install -d -m 0700 '$stage' '$bootstrap'"
scp -q "$@" \
    "$deploy_dir/openrc-manifest.sha256" \
    "$deploy_dir/openrc-init.el" \
    "$deploy_dir/openrc-sway.config" \
    "$deploy_dir/openrc-session" \
    "$deploy_dir/openrc-session-power" \
    "$deploy_dir/openrc-process-group" \
    "$deploy_dir/openrc-call-root" \
    "$deploy_dir/openrc-network-root" \
    "$deploy_dir/openrc-chat-url" \
    "$deploy_dir/openrc-emacs-server.nft" \
    "$deploy_dir/emacsos-ui.initd" \
    "$deploy_dir/openrc-boot-mode" \
    "$deploy_dir/waydroid-container.service" \
    "$deploy_dir/waydroid-container.conf" \
    "$deploy_dir/waydroid-container-wrapper" \
    "$phone_host:$stage/"
scp -q "$@" \
    "$repo_dir/os.el" \
    "$repo_dir/chat.el" \
    "$repo_dir/emacos-assist.el" \
    "$repo_dir/network.el" \
    "$repo_dir/phone-call.el" \
    "$phone_host:$stage/"
scp -q "$@" "$deploy_dir/openrc-install-root" "$phone_host:$bootstrap/"
ssh -T "$@" "$phone_host" \
    "chmod 0600 '$bootstrap/openrc-install-root' && chmod 0600 '$stage'/*"

admin_hash=$(sha256sum "$deploy_dir/openrc-install-root")
admin_hash=${admin_hash%% *}
bootstrap_local=$(mktemp)
sed "s/@@ADMIN_SHA256@@/$admin_hash/" "$deploy_dir/openrc-bootstrap-root" \
    >"$bootstrap_local"
if grep -F '@@ADMIN_SHA256@@' "$bootstrap_local" >/dev/null; then
    printf '%s\n' 'bootstrap helper hash substitution failed' >&2
    exit 1
fi
ssh -T "$@" "$phone_host" \
    'deploy_client_ip=${SSH_CONNECTION%% *}; exec sudo -n /usr/bin/env SUDO_USER=user DEPLOY_CLIENT_IP="$deploy_client_ip" /bin/sh' \
    <"$bootstrap_local"
rm -f -- "$bootstrap_local"
bootstrap_local=

if ! ssh -T "$@" "$phone_host" "rm -rf -- '$stage' '$bootstrap'"; then
    printf '%s\n' 'warning: install passed but remote staging cleanup failed' >&2
fi
printf '%s\n' 'Install passed. Reboot the phone to enter the minimal UI.'
