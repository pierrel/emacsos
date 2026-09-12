#!/bin/sh

set -eu

repo_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
temporary=$(mktemp -d)
daemon_name="emacsos-local-deploy-$$"
fake_bin=$temporary/bin
deployed=$temporary/deployed
log=$temporary/deploy.log

cleanup() {
    emacsclient -s "$daemon_name" --eval '(kill-emacs)' >/dev/null 2>&1 || true
    rm -rf -- "$temporary"
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$fake_bin" "$deployed"

cat >"$temporary/legacy.el" <<'EOF'
(defvar emacos-command-map (make-sparse-keymap))
(defun emacos--chat-show-top-buffer () nil)
EOF

emacs -Q --daemon="$daemon_name" -l "$temporary/legacy.el"
old_pid=$(emacsclient -s "$daemon_name" --eval '(emacs-pid)' | tr -d '"')
legacy_state='(list (boundp (quote emacos-command-map))
                    (fboundp (quote emacos--chat-show-top-buffer)))'
[ "$(emacsclient -s "$daemon_name" --eval "$legacy_state")" = '(t t)' ]

cat >"$fake_bin/openrc-update" <<'EOF'
#!/bin/sh
set -eu

for source in os.el chat.el assist-web.el emacsos-assist.el network.el \
    phone-call.el phone-sms.el; do
    cp -- "$EMACSOS_TEST_REPO_DIR/$source" "$EMACSOS_TEST_DEPLOY_DIR/"
done
emacsclient -s "$EMACSOS_TEST_DAEMON" --eval '(kill-emacs)' >/dev/null
emacs -Q --daemon="$EMACSOS_TEST_DAEMON" -L "$EMACSOS_TEST_DEPLOY_DIR" \
    -l "$EMACSOS_TEST_DEPLOY_DIR/os.el"
printf '%s\n' 'atomic OpenRC update and restart' >>"$EMACSOS_TEST_LOG"
EOF
chmod 0755 "$fake_bin/openrc-update"

make -s -n -C "$repo_dir" local-deploy | \
    grep -Fx 'deploy/pinephone/update-openrc-session.sh' >/dev/null
EMACSOS_TEST_DAEMON="$daemon_name" \
EMACSOS_TEST_DEPLOY_DIR="$deployed" \
EMACSOS_TEST_REPO_DIR="$repo_dir" \
EMACSOS_TEST_LOG="$log" \
"$fake_bin/openrc-update"

new_pid=$(emacsclient -s "$daemon_name" --eval '(emacs-pid)' | tr -d '"')
[ "$old_pid" != "$new_pid" ]
current_state='(list (intern-soft "emacos-command-map")
                     (intern-soft "emacos--chat-show-top-buffer")
                     (boundp (quote emacsos-command-map))
                     (fboundp (quote emacsos-command-mode)))'
[ "$(emacsclient -s "$daemon_name" --eval "$current_state")" = '(nil nil t t)' ]
grep -F 'atomic OpenRC update and restart' "$log" >/dev/null

printf '%s\n' 'local deploy restart tests passed'
