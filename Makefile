.PHONY: start start-server local-connect-server local-deploy server setup-server test-server test-simulation

local-connect-server:
	ssh -t phone emacsclient -f server -t

local-deploy:
	scp os.el phone:/tmp/os.el
	ssh phone emacsclient -f server -e '"(progn (load-file \"/tmp/os.el\") (emacos--render-page))"'

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

$(SERVER_STAMP): server/requirements.txt
	python3 -m venv $(SERVER_VENV)
	$(SERVER_VENV)/bin/python -m pip install --upgrade pip
	$(SERVER_VENV)/bin/python -m pip install -r server/requirements.txt
	touch $@

setup-server: $(SERVER_STAMP)

server: $(SERVER_STAMP)
	cd server && .venv/bin/python -m uvicorn emacsos_server.app:app \
	  --host 0.0.0.0 --port $${EMACSOS_SERVER_PORT:-8765} --reload

test-server: $(SERVER_STAMP)
	cd server && .venv/bin/python -m pytest tests/ -v

# End-to-end simulation: spins up a dockerized emacs daemon as the
# "phone", starts emacsos-server, fires a /chat request, verifies the
# (message ...) side effect actually landed in the daemon's *Messages*
# buffer.  Requires docker and emacsclient on the host.
test-simulation: $(SERVER_STAMP)
	cd server && PATH="$(CURDIR)/$(SERVER_VENV)/bin:$$PATH" bash simulation/run.sh
