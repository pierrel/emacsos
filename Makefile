.PHONY: start start-server local-connect-server local-deploy server test-server test-simulation

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
# Setup once: pip install -r server/requirements.txt
server:
	cd server && python -m uvicorn emacsos_server.app:app \
	  --host 0.0.0.0 --port $${EMACSOS_SERVER_PORT:-8765} --reload

test-server:
	cd server && python -m pytest tests/ -v

# End-to-end simulation: spins up a dockerized emacs daemon as the
# "phone", starts emacsos-server, fires a /chat request, verifies the
# (message ...) side effect actually landed in the daemon's *Messages*
# buffer.  Requires docker, emacsclient on host.
test-simulation:
	cd server && bash simulation/run.sh
