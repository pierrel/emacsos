.PHONY: start start-server local-connect-server local-deploy phone-install cellular-bringup install-modem-at-ports wg-add-peer wg-phone-bringup playground-install server setup-server test-server test-elisp test-pinephone-scripts pinephone-openrc-install pinephone-openrc-ui pinephone-openrc-console smoke install-server-service deploy-sms-forward deploy-call-bridge

PINEPHONE_HOST ?= phoney
export PINEPHONE_HOST

local-connect-server:
	ssh -t $(PINEPHONE_HOST) emacsclient -f server -t

test-pinephone-scripts:
	tests/test-pinephone-diagnostic-recovery.sh
	tests/test-pinephone-openrc-deploy.sh
	tests/test-pinephone-openrc-boot-mode.sh
	tests/test-pinephone-openrc-installer.sh
	tests/test-pinephone-openrc-call.sh
	tests/test-pinephone-openrc-network.sh
	tests/test-pinephone-openrc-power.sh
	emacs -Q --batch -L . -l tests/test-pinephone-openrc-init.el

pinephone-openrc-install: test-pinephone-scripts
	deploy/pinephone/install-openrc-session.sh

pinephone-openrc-ui:
	ssh $(PINEPHONE_HOST) sudo -n /usr/local/sbin/emacsos-openrc-boot-mode ui
	@echo 'Reboot the phone to enter the minimal UI.'

pinephone-openrc-console:
	ssh $(PINEPHONE_HOST) sudo -n /usr/local/sbin/emacsos-openrc-boot-mode console
	@echo 'Reboot the phone to restore the tty1 console.'

# === Phone deployment ===
#
# Two targets:
#
#   phone-install   First-time setup, chat/Assist endpoint changes, and
#                   Assist token rotation.  Persists across reboots:
#                   .el files + emacsos-init.el snippet land in
#                   ~/.emacs.d/.  After the first run, add the
#                   printed (load-file ...) line to the phone's own
#                   init.el ONCE.
#
#   local-deploy    Hot-reload only.  scp's the .el files to the
#                   persistent location and re-loads them into the
#                   running emacs daemon.  Use during dev iteration
#                   when you don't want to bounce the phone's emacs.
#
# Both targets write to ~/.emacs.d/emacsos/ so a hot-reload survives
# the next reboot too (until you change emacsos-init.el — then
# re-run phone-install).

PHONE_EMACSOS_DIR ?= ~/.emacs.d/emacsos
PHONE_INIT_SNIPPET ?= ~/.emacs.d/emacsos-init.el
# Default to this dev box's first global-scope IPv4.  Override at
# install time, e.g.:
#   make phone-install DEV_BOX_URL=http://dev.lan:8765/chat
DEV_BOX_URL ?= http://$(shell ip -4 -o addr show scope global 2>/dev/null | awk '{print $$4}' | cut -d/ -f1 | head -1):8765/chat
ASSIST_WEB_API_URL ?= https://assist.invalid/api/v1/phone
ASSIST_WEB_TOKEN_FILE ?= $(HOME)/.config/assist/phone-api-token
phone-install:
	@case "$(ASSIST_WEB_API_URL)" in https://assist.invalid/*) \
	  echo "error: set ASSIST_WEB_API_URL to the real HTTPS phone API" >&2; exit 1;; \
	  https://*) ;; \
	  *) echo "error: ASSIST_WEB_API_URL must use HTTPS" >&2; exit 1;; \
	esac
	@[ -f "$(ASSIST_WEB_TOKEN_FILE)" ] && [ ! -L "$(ASSIST_WEB_TOKEN_FILE)" ] || { \
	  echo "error: missing regular ASSIST_WEB_TOKEN_FILE" >&2; exit 1; }
	@LC_ALL=C awk 'NR == 1 && length($$0) >= 1 && length($$0) <= 512 && \
	  $$0 !~ /[^A-Za-z0-9._~-]/ { ok = 1 } \
	  END { exit !(NR == 1 && ok) }' "$(ASSIST_WEB_TOKEN_FILE)" || { \
	  echo "error: ASSIST_WEB_TOKEN_FILE must contain one safe token" >&2; exit 1; }
	@echo "→ Installing to phone:$(PHONE_EMACSOS_DIR)"
	@echo "  chat URL: $(DEV_BOX_URL)"
	@echo "  Assist Web API: $(ASSIST_WEB_API_URL)"
	ssh $(PINEPHONE_HOST) "umask 077; mkdir -p $(PHONE_EMACSOS_DIR) ~/.config/emacsos"
	scp os.el chat.el assist-web.el emacos-assist.el network.el phone-call.el $(PINEPHONE_HOST):$(PHONE_EMACSOS_DIR)/
	scp "$(ASSIST_WEB_TOKEN_FILE)" $(PINEPHONE_HOST):~/.config/emacsos/assist-web-token
	ssh $(PINEPHONE_HOST) "chmod 0600 ~/.config/emacsos/assist-web-token"
	sed -e "s|@@CHAT_URL@@|$(DEV_BOX_URL)|g" \
	    -e "s|@@ASSIST_WEB_API_URL@@|$(ASSIST_WEB_API_URL)|g" deploy/emacsos-init.el.in \
	  | ssh $(PINEPHONE_HOST) "cat > $(PHONE_INIT_SNIPPET)"
	@echo
	@echo "✓ Installed.  If this is the first run, add ONE line to phone's init.el:"
	@echo "    (load-file \"$(PHONE_INIT_SNIPPET)\")"
	@echo "  then bounce the phone's emacs (or run \`make local-deploy\` to hot-reload now)."

local-deploy:
	ssh $(PINEPHONE_HOST) mkdir -p $(PHONE_EMACSOS_DIR)
	scp os.el chat.el assist-web.el emacos-assist.el network.el phone-call.el $(PINEPHONE_HOST):$(PHONE_EMACSOS_DIR)/
	# Also (load-file) the init snippet if phone-install has been
	# run -- the snippet re-applies both chat and Assist Web API URLs,
	# which their reloaded defcustoms would otherwise reset.  Conditional
	# so a fresh phone still gets a working code reload.
	ssh $(PINEPHONE_HOST) emacsclient -f server -e '"(progn (load-file \"$(PHONE_EMACSOS_DIR)/chat.el\") (load-file \"$(PHONE_EMACSOS_DIR)/emacos-assist.el\") (load-file \"$(PHONE_EMACSOS_DIR)/assist-web.el\") (load-file \"$(PHONE_EMACSOS_DIR)/network.el\") (load-file \"$(PHONE_EMACSOS_DIR)/phone-call.el\") (load-file \"$(PHONE_EMACSOS_DIR)/os.el\") (when (file-exists-p \"$(PHONE_INIT_SNIPPET)\") (load-file \"$(PHONE_INIT_SNIPPET)\")) (emacos--render-page))"'

# Provision the SIM7600G-H 4G HAT for cellular DATA on the phone.  See
# docs/2026-05-26-cellular-data-connectivity.org.  APN is carrier-specific
# and is NOT committed — pass it on the command line:
#   make cellular-bringup APN=<your-carrier-apn>
# If your carrier needs PAP/CHAP auth, put `APN_USER=...` and `APN_PASS=...`
# (one KEY=VALUE per line) in an UNTRACKED file and point APN_AUTH_FILE at
# it; the script reads all params on stdin, so credentials never touch the
# process table or a tracked file:
#   make cellular-bringup APN=<apn> APN_AUTH_FILE=~/.emacsos-apn-auth
PHONE_DEPLOY_TMP ?= /tmp/cellular-bringup.sh
APN ?=
APN_AUTH_FILE ?=

cellular-bringup:
	@[ -n "$(APN)" ] || { echo "error: APN is required, e.g. make cellular-bringup APN=internet"; exit 1; }
	scp deploy/cellular-bringup.sh phone:$(PHONE_DEPLOY_TMP)
	@{ printf 'APN=%s\n' '$(APN)'; \
	   if [ -n '$(APN_AUTH_FILE)' ]; then cat '$(APN_AUTH_FILE)'; fi; \
	 } | ssh phone "sudo bash $(PHONE_DEPLOY_TMP); rc=\$$?; rm -f $(PHONE_DEPLOY_TMP); exit \$$rc"

# One-time: hand both SIM7600 AT ports to emacsos.  The call bridge uses the
# primary ttyUSB2 because that is the hardware-validated CPCMREG path; the human
# call UI keeps ttyUSB3.  ModemManager keeps QMI + GPS, so call detection and
# data remain on cdc-wdm0.  Re-run only if the rule changes.
MODEM_AT_HOST ?= phone
install-modem-at-ports:
	scp deploy/99-emacos-free-at-ports.rules $(MODEM_AT_HOST):/tmp/99-emacos-free-at-ports.rules
	ssh $(MODEM_AT_HOST) "sudo mv /tmp/99-emacos-free-at-ports.rules /etc/udev/rules.d/ \
	  && sudo rm -f /etc/udev/rules.d/99-emacos-free-ttyusb3.rules \
	  && sudo udevadm control --reload-rules \
	  && sudo udevadm trigger --action=change /dev/ttyUSB2 /dev/ttyUSB3 \
	  && sudo systemctl restart ModemManager"
	@echo "✓ ttyUSB2 + ttyUSB3 freed for emacsos AT voice; ModemManager restarted"

# === WireGuard for the away phone ===
# See docs/2026-05-31-wireguard-away-phone.org for the full setup runbook.
#
# Order (one-time, per phone):
#   1) make wg-phone-bringup SERVER_PUBKEY=... WG_ENDPOINT='[v6]:51821' \
#        WG_ADDR=10.0.0.X/32 WG_ALLOWED_IPS='<wg-subnet>, <server-lan-ip>/32'
#      (installs wg on the phone, generates a keypair, writes wg0.conf,
#       brings up; prints the phone's public key at the end.)
#   2) make wg-add-peer PEER_PUBKEY=<phone-pubkey> PEER_WG_IP=10.0.0.X/32 \
#        PEER_LABEL=phone
#      (appends the peer on the dev box's wg server and live-reloads.)
#
# Both targets require sudo (server-side: prompts locally; phone-side:
# passwordless sudo on the Pi).  Secrets flow via env / stdin, NEVER argv.

WG_DEPLOY_TMP ?= /tmp/wg-phone-bringup.sh
SERVER_PUBKEY ?=
WG_ENDPOINT ?=
WG_ADDR ?=
WG_ALLOWED_IPS ?=
PEER_LABEL ?= phone
PEER_PUBKEY ?=
PEER_WG_IP ?=

wg-phone-bringup:
	@[ -n "$(SERVER_PUBKEY)" ] || { echo "error: SERVER_PUBKEY is required"; exit 1; }
	@[ -n "$(WG_ENDPOINT)" ]   || { echo "error: WG_ENDPOINT is required (e.g. '[<server-v6>]:51821')"; exit 1; }
	@[ -n "$(WG_ADDR)" ]       || { echo "error: WG_ADDR is required (e.g. 10.0.0.X/32)"; exit 1; }
	@[ -n "$(WG_ALLOWED_IPS)" ]|| { echo "error: WG_ALLOWED_IPS is required"; exit 1; }
	scp deploy/wireguard/phone-bringup.sh phone:$(WG_DEPLOY_TMP)
	@{ printf 'SERVER_PUBKEY=%s\n' '$(SERVER_PUBKEY)'; \
	   printf 'WG_ENDPOINT=%s\n'   '$(WG_ENDPOINT)';   \
	   printf 'WG_ADDR=%s\n'       '$(WG_ADDR)';       \
	   printf 'WG_ALLOWED_IPS=%s\n' '$(WG_ALLOWED_IPS)'; \
	   printf 'PEER_LABEL=%s\n'    '$(PEER_LABEL)';    \
	 } | ssh phone "sudo bash $(WG_DEPLOY_TMP); rc=\$$?; rm -f $(WG_DEPLOY_TMP); exit \$$rc"

# Local (server-side) — invokes sudo via the user's shell, prompts for password.
wg-add-peer:
	@[ -n "$(PEER_PUBKEY)" ] || { echo "error: PEER_PUBKEY is required (the new peer's wg pubkey)"; exit 1; }
	@[ -n "$(PEER_WG_IP)" ]  || { echo "error: PEER_WG_IP is required (e.g. 10.0.0.X/32)"; exit 1; }
	PEER_PUBKEY='$(PEER_PUBKEY)' PEER_WG_IP='$(PEER_WG_IP)' PEER_LABEL='$(PEER_LABEL)' \
	  bash deploy/wireguard/server-add-peer.sh

# === Playground (bot-facing scripts on the phone) ===
# Pushes deploy/playground/*.sh + cellular.md to ~/playground/ on the phone.
# Idempotent — re-run any time you change one of those files in the repo.
PHONE_PLAYGROUND_DIR ?= ~/playground

playground-install:
	ssh phone "mkdir -p $(PHONE_PLAYGROUND_DIR)"
	scp deploy/playground/cell-validate.sh deploy/playground/cell-test.sh deploy/playground/cellular.md \
	  phone:$(PHONE_PLAYGROUND_DIR)/
	ssh phone "chmod +x $(PHONE_PLAYGROUND_DIR)/cell-validate.sh $(PHONE_PLAYGROUND_DIR)/cell-test.sh"
	@echo "✓ playground files installed to phone:$(PHONE_PLAYGROUND_DIR)/"

test-elisp:
	emacs -Q --batch -L . -L tests -l tests/test-chat.el -l tests/test-os.el -l tests/test-emacos-assist.el -l tests/test-assist-web.el -l tests/test-network.el -l tests/test-call.el -f ert-run-tests-batch-and-exit

start:
	emacs -Q --load "$(CURDIR)/os.el" \
	  --eval '(set-frame-size (selected-frame) 320 240 t)'

start-server:
	emacs -Q --load "$(CURDIR)/os.el" \
	  --eval '(set-frame-size (selected-frame) 320 240 t)' \
	  --eval '(setq server-use-tcp t server-host "0.0.0.0")' \
	  --eval '(server-start)'

# emacsos-server: HTTP gateway between the phone and the assist agent.
# server/.venv/ is auto-created on first run; subsequent invocations
# reuse it.  Delete server/.venv/ to force a clean reinstall.
SERVER_VENV := server/.venv
SERVER_STAMP := $(SERVER_VENV)/.installed

# Install assist editably with its requirements.txt as a pip constraints
# file: assist declares its runtime deps in pyproject.toml, and the
# constraints file pins the versions of those deps (and their transitive
# closure) without pulling in assist's dev tooling (pytest, ipython,
# pylint, flake8 etc).  Override the location with
# `ASSIST_REPO_DIR=/path/to/assist` if your checkout isn't at the default
# sibling path.
ASSIST_REPO_DIR ?= $(CURDIR)/../assist

# Stamp depends on assist's pyproject.toml + requirements.txt so a
# dep bump upstream triggers a re-install (without it, `pip install -e`
# would silently reuse a stale wheel cache against the new pyproject).
$(SERVER_STAMP): server/requirements.txt $(ASSIST_REPO_DIR)/requirements.txt $(ASSIST_REPO_DIR)/pyproject.toml
	python3 -m venv $(SERVER_VENV)
	$(SERVER_VENV)/bin/python -m pip install --upgrade pip
	$(SERVER_VENV)/bin/python -m pip install \
	  -e $(ASSIST_REPO_DIR) \
	  -r server/requirements.txt \
	  -c $(ASSIST_REPO_DIR)/requirements.txt
	touch $@

setup-server: $(SERVER_STAMP)

server: $(SERVER_STAMP)
	cd server && .venv/bin/python -m uvicorn emacsos_server.app:app \
	  --host 0.0.0.0 --port $${EMACSOS_SERVER_PORT:-8765} --reload

# Install the emacsos server as a systemd unit (the persistent equivalent
# of `make server`, mirroring assist's assist-web.service).  Substitutes
# operator user/paths into deploy/emacsos-server.service.in at install time
# so nothing host-specific is committed.  Runs as your user, enabled on
# boot, restart-on-failure, started after llamacpp.  Needs interactive sudo
# (writes /etc/systemd/system and enables the unit).  Point EMACSOS_ENV_FILE
# at the env that defines ASSIST_MODEL_URL (defaults to the assist .dev.env).
EMACSOS_SERVER_PORT ?= 8765
EMACSOS_ENV_FILE ?= $(ASSIST_REPO_DIR)/.dev.env
install-server-service: $(SERVER_STAMP)
	sed -e 's|@@USER@@|$(shell id -un)|g' \
	    -e 's|@@SERVER_DIR@@|$(CURDIR)/server|g' \
	    -e 's|@@ENV_FILE@@|$(EMACSOS_ENV_FILE)|g' \
	    -e 's|@@PORT@@|$(EMACSOS_SERVER_PORT)|g' \
	    deploy/emacsos-server.service.in \
	  | sudo tee /etc/systemd/system/emacsos-server.service >/dev/null
	sudo systemctl daemon-reload
	sudo systemctl enable --now emacsos-server.service
	@echo "✓ emacsos-server.service installed + enabled + started on :$(EMACSOS_SERVER_PORT)"

# Deploy the sms-forward bridge TO THE PHONE (where the modem is). The phone has no repo/
# venv, so this scp's the single script (stdlib + requests, preinstalled on the phone) + an env file + the unit, then enables it.
# Secrets flow via stdin (never argv on the phone). Required:
#   make deploy-sms-forward ASSIST_SMS_SECRET=<shared> ASSIST_SMS_INBOUND_URL=https://<thinky-wg>:5050/inbound/sms
EMACSOS_SMS_FORWARD_PORT ?= 8766
SMS_FWD_HOST ?= phone-wg
SMS_FWD_DIR ?= .local/sms-forward
SMS_FWD_ENV ?= .config/sms-forward.env
ASSIST_SMS_SECRET ?=
ASSIST_SMS_INBOUND_URL ?=

deploy-sms-forward:
	@[ -n "$(ASSIST_SMS_SECRET)" ]      || { echo "error: ASSIST_SMS_SECRET is required"; exit 1; }
	@[ -n "$(ASSIST_SMS_INBOUND_URL)" ] || { echo "error: ASSIST_SMS_INBOUND_URL is required (assist's /inbound/sms)"; exit 1; }
	ssh $(SMS_FWD_HOST) "mkdir -p $(SMS_FWD_DIR) .config"
	scp server/emacsos_server/sms_forward.py $(SMS_FWD_HOST):$(SMS_FWD_DIR)/sms_forward.py
	@{ printf 'ASSIST_SMS_SECRET=%s\n'       '$(ASSIST_SMS_SECRET)';      \
	   printf 'ASSIST_SMS_INBOUND_URL=%s\n'  '$(ASSIST_SMS_INBOUND_URL)'; \
	   printf 'ASSIST_SMS_FORWARD_PORT=%s\n' '$(EMACSOS_SMS_FORWARD_PORT)'; \
	 } | ssh $(SMS_FWD_HOST) "umask 077; cat > $(SMS_FWD_ENV)"
	@H=$$(ssh $(SMS_FWD_HOST) 'echo $$HOME'); \
	 sed -e "s|@@ENV_FILE@@|$$H/$(SMS_FWD_ENV)|g" \
	     -e "s|@@SCRIPT_PATH@@|$$H/$(SMS_FWD_DIR)/sms_forward.py|g" \
	     deploy/sms-forward.service.in \
	   | ssh $(SMS_FWD_HOST) "sudo tee /etc/systemd/system/sms-forward.service >/dev/null"
	ssh $(SMS_FWD_HOST) "sudo systemctl daemon-reload && sudo systemctl enable sms-forward.service && sudo systemctl restart sms-forward.service"
	@echo "✓ sms-forward deployed to $(SMS_FWD_HOST) on :$(EMACSOS_SMS_FORWARD_PORT)"

# Installs and restarts the configured bridge. The shared secret is read from a
# local 0600 file, streamed over stdin, and atomically installed as the phone's
# 0600 environment file; it never appears in a Make argument, process list, or
# tracked file.
VOICE_BRIDGE_HOST ?= phone-wg
VOICE_BRIDGE_DIR ?= .local/call-bridge
VOICE_BRIDGE_ENV ?= .config/call-bridge.env
ASSIST_VOICE_URL ?=
ASSIST_VOICE_SECRET_FILE ?=

deploy-call-bridge:
	@[ -n "$(ASSIST_VOICE_URL)" ] || { echo "error: ASSIST_VOICE_URL is required"; exit 1; }
	@[ -n "$(ASSIST_VOICE_SECRET_FILE)" ] || { echo "error: ASSIST_VOICE_SECRET_FILE is required"; exit 1; }
	@test -r "$(ASSIST_VOICE_SECRET_FILE)" || { echo "error: secret file is unreadable"; exit 1; }
	ssh $(VOICE_BRIDGE_HOST) "mkdir -p $(VOICE_BRIDGE_DIR) .config && python3 -m venv $(VOICE_BRIDGE_DIR)/venv && $(VOICE_BRIDGE_DIR)/venv/bin/pip install pyserial websockets dbus-fast"
	scp server/emacsos_server/call_bridge.py $(VOICE_BRIDGE_HOST):$(VOICE_BRIDGE_DIR)/call_bridge.py
	@{ printf 'ASSIST_VOICE_URL=%s\n' '$(ASSIST_VOICE_URL)'; \
	   printf 'ASSIST_VOICE_SECRET='; cat "$(ASSIST_VOICE_SECRET_FILE)" || exit 1; printf '\n'; \
	   printf '%s\n' '__ASSIST_VOICE_ENV_COMPLETE__'; \
	 } | ssh $(VOICE_BRIDGE_HOST) 'set -eu; umask 077; wire=$$(mktemp "$(VOICE_BRIDGE_ENV).wire.XXXXXX"); tmp=$$(mktemp "$(VOICE_BRIDGE_ENV).tmp.XXXXXX") || { rm -f "$$wire"; exit 1; }; cleanup() { rm -f "$$wire" "$$tmp"; }; trap cleanup 0 1 2 15; cat > "$$wire"; [ "$$(tail -n 1 "$$wire")" = __ASSIST_VOICE_ENV_COMPLETE__ ]; head -n -1 "$$wire" > "$$tmp"; chmod 600 "$$tmp"; mv -f "$$tmp" "$(VOICE_BRIDGE_ENV)"; rm -f "$$wire"; trap - 0 1 2 15'
	@H=$$(ssh $(VOICE_BRIDGE_HOST) 'echo $$HOME'); U=$$(ssh $(VOICE_BRIDGE_HOST) 'id -un'); \
	 sed -e "s|@@USER@@|$$U|g" -e "s|@@ENV_FILE@@|$$H/$(VOICE_BRIDGE_ENV)|g" \
	     -e "s|@@VENV@@|$$H/$(VOICE_BRIDGE_DIR)/venv|g" \
	     -e "s|@@SCRIPT_PATH@@|$$H/$(VOICE_BRIDGE_DIR)/call_bridge.py|g" \
	     deploy/call-bridge.service.in | ssh $(VOICE_BRIDGE_HOST) "sudo tee /etc/systemd/system/call-bridge.service >/dev/null"
	ssh $(VOICE_BRIDGE_HOST) "sudo systemctl daemon-reload && sudo systemctl enable call-bridge.service && sudo systemctl restart call-bridge.service"
	@echo "✓ call bridge deployed to $(VOICE_BRIDGE_HOST)"

test-server: $(SERVER_STAMP)
	cd server && .venv/bin/python -m pytest tests/ -v

# Smoke test for the full round trip: spins up a dockerized emacs
# daemon as the "phone", starts emacsos-server, fires a /chat
# request from inside the container, verifies the (message ...) side
# effect actually landed in the daemon's *Messages* buffer.  Run this
# after any change that touches the server, the phone driver, the
# chat page on the phone, or the wire protocol -- and extend
# server/simulation/run.sh as new capabilities (LLM, skills,
# rollback, etc.) come online so the assertion grows with what the
# server can do.  Requires docker and emacsclient on the host.
smoke: $(SERVER_STAMP)
	cd server && PATH="$(CURDIR)/$(SERVER_VENV)/bin:$$PATH" bash simulation/run.sh
