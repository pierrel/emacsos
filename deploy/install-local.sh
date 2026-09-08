#!/bin/sh
set -eu

if [ -z "${LOCAL_EMACSOS_DIR:-}" ]; then
  echo 'LOCAL_EMACSOS_DIR must not be empty' >&2
  exit 1
fi

repo=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
install -d -- "$LOCAL_EMACSOS_DIR"
install -m 0644 -- "$repo/chat.el" "$repo/assist-web.el" \
  "$LOCAL_EMACSOS_DIR/"

printf 'Installed the Assist thread client in %s.\n' "$LOCAL_EMACSOS_DIR"
echo 'Credentials, certificates, and Emacs configuration were not changed.'
echo 'After copying your credentials, add the installation directory to load-path.'
echo 'Set emacos-assist-web-api-url to your HTTPS Assist phone API endpoint.'
echo '(setq emacos-assist-web-token-file "~/.config/emacsos/assist-web-token")'
echo '(setq emacos-assist-web-ca-file "~/.config/emacsos/assist-web-ca.pem")'
echo '(require '\''assist-web)'
