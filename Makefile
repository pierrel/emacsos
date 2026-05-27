.PHONY: start start-server local-connect-server local-deploy phone-install server setup-server test-server test-elisp smoke

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
	scp os.el chat.el emacos-assist.el phone:$(PHONE_EMACSOS_DIR)/
	sed "s|@@CHAT_URL@@|$(DEV_BOX_URL)|g" deploy/emacsos-init.el.in \
	  | ssh phone "cat > $(PHONE_INIT_SNIPPET)"
	@echo
	@echo "✓ Installed.  If this is the first run, add ONE line to phone's init.el:"
	@echo "    (load-file \"$(PHONE_INIT_SNIPPET)\")"
	@echo "  then bounce the phone's emacs (or run \`make local-deploy\` to hot-reload now)."

local-deploy:
	ssh phone mkdir -p $(PHONE_EMACSOS_DIR)
	scp os.el chat.el emacos-assist.el phone:$(PHONE_EMACSOS_DIR)/
	# Also (load-file) the init snippet if phone-install has been
	# run -- the snippet re-applies (setq emacos-chat-server-url ...)
	# which would otherwise be reset back to the defcustom default
	# when chat.el is reloaded.  Conditional so a fresh phone (no
	# phone-install yet) still gets a working code reload.
	ssh phone emacsclient -f server -e '"(progn (load-file \"$(PHONE_EMACSOS_DIR)/chat.el\") (load-file \"$(PHONE_EMACSOS_DIR)/emacos-assist.el\") (load-file \"$(PHONE_EMACSOS_DIR)/os.el\") (when (file-exists-p \"$(PHONE_INIT_SNIPPET)\") (load-file \"$(PHONE_INIT_SNIPPET)\")) (emacos--render-page))"'

test-elisp:
	emacs -Q --batch -L . -L tests -l tests/test-chat.el -l tests/test-os.el -l tests/test-emacos-assist.el -f ert-run-tests-batch-and-exit

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
