.PHONY: start

start:
	emacs -Q --load "$(CURDIR)/os.el" \
	  --eval '(set-frame-size (selected-frame) 320 240 t)'
