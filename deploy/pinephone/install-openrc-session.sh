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
token_file=${ASSIST_WEB_TOKEN_FILE:-$HOME/.config/assist/phone-api-token}
ca_file=${ASSIST_WEB_CA_FILE:-$HOME/.local/share/mkcert/rootCA.pem}
assist_web_server_ip=${ASSIST_WEB_SERVER_IP:?set ASSIST_WEB_SERVER_IP to the certificate-covered Assist address}

[ -f "$token_file" ] && [ ! -L "$token_file" ] &&
    LC_ALL=C awk 'NR == 1 && length($0) >= 1 && length($0) <= 512 && $0 !~ /[^A-Za-z0-9._~-]/ { ok = 1 } END { exit !(NR == 1 && ok) }' \
        "$token_file" || {
    printf '%s\n' 'Assist Web token file must contain one safe token' >&2
    exit 1
}
[ -f "$ca_file" ] && [ ! -L "$ca_file" ] &&
    [ "$(stat -c '%s' "$ca_file")" -le 65536 ] &&
    openssl x509 -in "$ca_file" -outform PEM 2>/dev/null | cmp -s - "$ca_file" || {
    printf '%s\n' 'ASSIST_WEB_CA_FILE must be one bounded X.509 certificate' >&2
    exit 1
}
case $assist_web_server_ip in
    ''|*[!0-9.]*) printf '%s\n' 'ASSIST_WEB_SERVER_IP must be an IPv4 address' >&2; exit 1 ;;
esac

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
    "$deploy_dir/dtach-shell.el" \
    "$deploy_dir/dtach-shell-init.el" \
    "$deploy_dir/openrc-sway.config" \
    "$deploy_dir/openrc-session" \
    "$deploy_dir/openrc-session-power" \
    "$deploy_dir/openrc-process-group" \
    "$deploy_dir/openrc-suspend-root" \
    "$deploy_dir/openrc-call-root" \
    "$deploy_dir/openrc-network-root" \
    "$deploy_dir/openrc-chat-url" \
    "$deploy_dir/openrc-assist-web-url" \
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
    "$repo_dir/assist-web.el" \
    "$repo_dir/emacos-assist.el" \
    "$repo_dir/network.el" \
    "$repo_dir/phone-call.el" \
    "$phone_host:$stage/"
scp -q "$@" "$token_file" "$phone_host:$stage/assist-web-token"
scp -q "$@" "$ca_file" "$phone_host:$stage/assist-web-ca.pem"
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
    "deploy_client_ip=\${SSH_CONNECTION%% *}; exec sudo -n /usr/bin/env SUDO_USER=user DEPLOY_CLIENT_IP=\"\$deploy_client_ip\" ASSIST_WEB_SERVER_IP='$assist_web_server_ip' /bin/sh" \
    <"$bootstrap_local"
rm -f -- "$bootstrap_local"
bootstrap_local=

if ! ssh -T "$@" "$phone_host" "rm -rf -- '$stage' '$bootstrap'"; then
    printf '%s\n' 'warning: install passed but remote staging cleanup failed' >&2
fi
printf '%s\n' 'Install passed. Reboot the phone to enter the minimal UI.'
