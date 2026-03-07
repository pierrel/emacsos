.PHONY: start start-server local-connect-server local-deploy

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
