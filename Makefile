.PHONY: start start-server local-connect-server local-deploy phone-install cellular-bringup install-modem-at-port wg-add-peer wg-phone-bringup playground-install server setup-server test-server test-elisp smoke install-server-service

local-connect-server:
	ssh -t phone emacsclient -f server -t

# === Phone deployment ===
#
# Two targets:
#
#   phone-install   First-time setup AND any time the chat URL or
#                   init snippet changes.  Persists across reboots:
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

phone-install:
	@echo "→ Installing to phone:$(PHONE_EMACSOS_DIR)"
	@echo "  chat URL: $(DEV_BOX_URL)"
	ssh phone "mkdir -p $(PHONE_EMACSOS_DIR)"
	scp os.el chat.el emacos-assist.el network.el phone-call.el phone:$(PHONE_EMACSOS_DIR)/
	sed "s|@@CHAT_URL@@|$(DEV_BOX_URL)|g" deploy/emacsos-init.el.in \
	  | ssh phone "cat > $(PHONE_INIT_SNIPPET)"
	@echo
	@echo "✓ Installed.  If this is the first run, add ONE line to phone's init.el:"
	@echo "    (load-file \"$(PHONE_INIT_SNIPPET)\")"
	@echo "  then bounce the phone's emacs (or run \`make local-deploy\` to hot-reload now)."

local-deploy:
	ssh phone mkdir -p $(PHONE_EMACSOS_DIR)
	scp os.el chat.el emacos-assist.el network.el phone-call.el phone:$(PHONE_EMACSOS_DIR)/
	# Also (load-file) the init snippet if phone-install has been
	# run -- the snippet re-applies (setq emacos-chat-server-url ...)
	# which would otherwise be reset back to the defcustom default
	# when chat.el is reloaded.  Conditional so a fresh phone (no
	# phone-install yet) still gets a working code reload.
	ssh phone emacsclient -f server -e '"(progn (load-file \"$(PHONE_EMACSOS_DIR)/chat.el\") (load-file \"$(PHONE_EMACSOS_DIR)/emacos-assist.el\") (load-file \"$(PHONE_EMACSOS_DIR)/network.el\") (load-file \"$(PHONE_EMACSOS_DIR)/phone-call.el\") (load-file \"$(PHONE_EMACSOS_DIR)/os.el\") (when (file-exists-p \"$(PHONE_INIT_SNIPPET)\") (load-file \"$(PHONE_INIT_SNIPPET)\")) (emacos--render-page))"'

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

# One-time: hand the SIM7600 secondary AT port (ttyUSB3) to emacsos for raw-AT
# voice (incoming answer + later call audio).  ModemManager keeps QMI + GPS +
# the primary AT port, so detection and data are unaffected.  Re-run only if
# the rule changes.  See docs/2026-06-18-inbound-answering.org.
install-modem-at-port:
	scp deploy/99-emacos-free-ttyusb3.rules phone:/tmp/99-emacos-free-ttyusb3.rules
	ssh phone "sudo mv /tmp/99-emacos-free-ttyusb3.rules /etc/udev/rules.d/ \
	  && sudo udevadm control --reload-rules \
	  && sudo udevadm trigger --action=change /dev/ttyUSB3 \
	  && sudo systemctl restart ModemManager"
	@echo "✓ ttyUSB3 freed for emacsos AT voice; ModemManager restarted"

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
	emacs -Q --batch -L . -L tests -l tests/test-chat.el -l tests/test-os.el -l tests/test-emacos-assist.el -l tests/test-network.el -l tests/test-call.el -f ert-run-tests-batch-and-exit

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
