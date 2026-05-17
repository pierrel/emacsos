# "Phone" simulator: a minimal emacs daemon with the same TCP-server
# configuration EmacsOS uses on the phone (server-use-tcp t, host 0.0.0.0,
# fixed port 12345).  Runs as uid 1000 -- no root inside the container.
#
# os.el + chat.el are baked in at /opt/emacsos so the round-trip step
# in run.sh can `(load-file ...)` them into the daemon via emacsclient.
FROM debian:12-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends emacs-nox ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*

# Bake in the EmacsOS modules.  Built from the repo root with the
# simulation directory as -f context so we can COPY ../../*.el; see
# run.sh for the build command.
COPY os.el chat.el /opt/emacsos/

RUN useradd --create-home --uid 1000 phone
USER phone
WORKDIR /home/phone

# --batch + (server-start) + accept-process-output keeps the daemon
# responsive without --daemon's user-init ordering quirks: we set the
# TCP vars BEFORE server-start, then block forever processing socket
# events.
CMD ["emacs", "-Q", "--batch", \
     "--eval", "(setq server-use-tcp t server-host \"0.0.0.0\" server-port 12345)", \
     "--eval", "(server-start)", \
     "--eval", "(while t (accept-process-output nil 1))"]
