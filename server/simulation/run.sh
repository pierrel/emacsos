#!/usr/bin/env bash
# Full round-trip smoke test with a containerized emacs daemon
# standing in for the phone.  Wired into `make smoke`.  Extend the
# assertions here as new capabilities (LLM, skills, rollback, etc.)
# land so the smoke grows with what the server can do.
#
# Flow:
#   1. Build the phone-simulator image.
#   2. Start the container with --network=host so its emacs daemon
#      binds to the host's 127.0.0.1:12345 -- shared loopback is the
#      cleanest topology for a single-host simulation.
#   3. Start emacsos-server on port 8765 in the background.
#   4. Read the auth file from the running daemon (docker exec).
#   5. From inside the container, POST /chat to the server with the
#      auth-file contents in the request body -- the production
#      shape from the design doc.
#   6. Assert the response has side_effect != null (the server's
#      emacsclient call to the daemon succeeded).
#   7. Independently, run emacsclient against the daemon to read its
#      *Messages* buffer and confirm the "saw: <msg>" line actually
#      landed.  This is the load-bearing verification -- response
#      shape alone could be a green light without a real side effect.
#
# Everything runs as the invoking host user; the container also runs
# unprivileged (uid 1000 inside).  No sudo, no privileged ports.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SERVER_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_DIR="$(cd "$SERVER_DIR/.." && pwd)"

IMAGE="emacsos-phone-sim"
CONTAINER="emacsos-phone-sim-$$"
PHONE_PORT=12345
SERVER_PORT=8765
TEST_MSG="hello from simulation"

# Track resources for cleanup.
SERVER_PID=""
HOST_AUTH=""

log() { printf '[sim] %s\n' "$*"; }
fail() { printf '[sim] FAIL: %s\n' "$*" >&2; exit 1; }

cleanup() {
    log "cleaning up"
    [[ -n "$SERVER_PID" ]] && kill "$SERVER_PID" 2>/dev/null && wait "$SERVER_PID" 2>/dev/null
    docker rm -f "$CONTAINER" >/dev/null 2>&1
    [[ -n "$HOST_AUTH" && -f "$HOST_AUTH" ]] && rm -f "$HOST_AUTH"
}
trap cleanup EXIT

# 1. Build phone image.  Build context = repo root so the Dockerfile
# can COPY os.el + chat.el (baked into the daemon for the round-trip
# step below).
log "building $IMAGE"
docker build -q -t "$IMAGE" -f "$SCRIPT_DIR/Dockerfile" "$REPO_DIR" >/dev/null \
    || fail "image build"

# 2. Start phone container (host network so 127.0.0.1:12345 is shared).
log "starting phone container ($CONTAINER) with --network=host"
docker run -d --rm --name "$CONTAINER" --network=host "$IMAGE" >/dev/null \
    || fail "container start"

# Wait for the daemon to write its auth file.  server-start is
# synchronous so the file appears as soon as init finishes.
for _ in $(seq 1 20); do
    if docker exec "$CONTAINER" test -f /home/phone/.emacs.d/server/server 2>/dev/null; then
        break
    fi
    sleep 0.5
done
docker exec "$CONTAINER" test -f /home/phone/.emacs.d/server/server \
    || fail "daemon never wrote auth file"

# Confirm TCP port is up.
for _ in $(seq 1 20); do
    if curl -s -o /dev/null --max-time 1 "telnet://127.0.0.1:$PHONE_PORT" 2>/dev/null \
       || (echo > "/dev/tcp/127.0.0.1/$PHONE_PORT") 2>/dev/null; then
        break
    fi
    sleep 0.5
done
(echo > "/dev/tcp/127.0.0.1/$PHONE_PORT") 2>/dev/null \
    || fail "daemon TCP port $PHONE_PORT not reachable"

# 3. Start emacsos-server.
log "starting emacsos-server on :$SERVER_PORT"
(
    cd "$SERVER_DIR" \
    && EMACSOS_SERVER_PORT="$SERVER_PORT" \
       PYTHONPATH=. \
       python -m uvicorn emacsos_server.app:app \
       --host 127.0.0.1 --port "$SERVER_PORT" --log-level warning
) >/tmp/emacsos-server.log 2>&1 &
SERVER_PID=$!

for _ in $(seq 1 20); do
    if curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$SERVER_PORT/docs"; then
        break
    fi
    sleep 0.5
done
curl -s -o /dev/null --max-time 1 "http://127.0.0.1:$SERVER_PORT/docs" \
    || fail "server never came up; logs:\n$(cat /tmp/emacsos-server.log)"

# 4. Read the phone's auth file (still inside the container; the
#    host filesystem never sees it directly, mirroring production
#    where the auth file lives on the phone).
AUTH_FILE_CONTENTS=$(docker exec "$CONTAINER" cat /home/phone/.emacs.d/server/server)
[[ -n "$AUTH_FILE_CONTENTS" ]] || fail "auth file empty"
log "got auth file from phone (${#AUTH_FILE_CONTENTS} bytes)"

# 5. POST /chat FROM INSIDE the container, so request.client.host
#    is the phone's reachable address (127.0.0.1 under host-network).
#    This is the production request shape: phone reads its own auth
#    file and embeds the contents.
log "POST /chat from inside the phone container"
RESPONSE=$(docker exec "$CONTAINER" sh -c "curl -s -X POST \
    -H 'Content-Type: application/json' \
    -d \"\$(cat <<'JSON'
{\"message\": \"$TEST_MSG\", \"phone\": {\"auth_file\": $(python3 -c 'import json,sys;print(json.dumps(sys.argv[1]))' "$AUTH_FILE_CONTENTS")}}
JSON
)\" \
    http://127.0.0.1:$SERVER_PORT/chat")

[[ -n "$RESPONSE" ]] || fail "no response from /chat"
log "response: $RESPONSE"

# 6. Assert response shape.
echo "$RESPONSE" | python3 -c "
import json, sys
r = json.load(sys.stdin)
assert r['text'] == 'echo: $TEST_MSG', f\"text mismatch: {r!r}\"
assert r['side_effect'] is not None, f\"side_effect was null -- emacsclient call failed: {r!r}\"
print('[sim] response shape OK')
" || fail "response shape"

# 7. Independent verification: read *Messages* from the daemon and
#    confirm the (message ...) the server fired actually landed.
log "verifying via independent emacsclient call against the daemon"
HOST_AUTH=$(mktemp /tmp/sim-auth-XXXXXX)
printf '%s' "$AUTH_FILE_CONTENTS" | sed 's/0\.0\.0\.0/127.0.0.1/g' > "$HOST_AUTH"
MESSAGES=$(emacsclient -f "$HOST_AUTH" -e '(with-current-buffer "*Messages*" (buffer-string))' 2>/tmp/emacsclient.err)
EMACSCLIENT_RC=$?

[[ $EMACSCLIENT_RC -eq 0 ]] || fail "emacsclient exited $EMACSCLIENT_RC; stderr:\n$(cat /tmp/emacsclient.err)"

if printf '%s' "$MESSAGES" | grep -q "saw: $TEST_MSG"; then
    log "PASS: '*Messages*' contains 'saw: $TEST_MSG'"
else
    log "messages buffer: $MESSAGES"
    fail "'*Messages*' did not contain 'saw: $TEST_MSG'"
fi

# 8. Round-trip via chat.el inside the daemon.  The curl path above
#    proves the server in isolation; this path proves the full client
#    surface (chat.el + url-retrieve-synchronously + the request shape
#    the elisp actually produces) by driving (emacos--chat-send)
#    against the daemon and reading back *chat*.
CHAT_MSG="hello via chat.el"
log "round-trip via chat.el in the daemon"

# Load chat.el and point it at the server + the daemon's own auth file.
emacsclient -f "$HOST_AUTH" -e "(progn
  (load-file \"/opt/emacsos/chat.el\")
  (setq emacos-chat-server-url \"http://127.0.0.1:$SERVER_PORT/chat\")
  (setq emacos-chat-auth-file \"/home/phone/.emacs.d/server/server\"))" \
  >/dev/null 2>&1 \
  || fail "chat.el did not load in the daemon"

# Simulate the user tapping into the input region and pressing SEND.
emacsclient -f "$HOST_AUTH" -e "(progn
  (with-current-buffer (emacos--chat-buffer)
    (goto-char (point-max))
    (insert \"$CHAT_MSG\"))
  (emacos--chat-send))" >/dev/null 2>/tmp/emacsclient-chat.err \
  || fail "emacos--chat-send signaled; stderr:\n$(cat /tmp/emacsclient-chat.err)"

# Read back the transcript and assert both you> and bot> lines landed.
CHAT_TRANSCRIPT=$(emacsclient -f "$HOST_AUTH" \
  -e "(with-current-buffer \"*chat*\" (buffer-substring-no-properties (point-min) (point-max)))" \
  2>/tmp/emacsclient-chat.err)
[[ $? -eq 0 ]] \
  || fail "emacsclient could not read *chat*; stderr:\n$(cat /tmp/emacsclient-chat.err)"

if printf '%s' "$CHAT_TRANSCRIPT" | grep -q "you> $CHAT_MSG" \
   && printf '%s' "$CHAT_TRANSCRIPT" | grep -q "bot> echo: $CHAT_MSG"; then
    log "PASS: *chat* contains 'you> $CHAT_MSG' and 'bot> echo: $CHAT_MSG'"
else
    log "*chat* transcript: $CHAT_TRANSCRIPT"
    fail "*chat* missing expected you>/bot> lines"
fi

# Independent side-effect check (same shape as step 7): the server
# fires (message "saw: <text>") via emacsclient against the daemon.
# Since we drove the request through chat.el this time, the message
# the server processed is the bare chat input -- so we look for
# 'saw: <CHAT_MSG>' in *Messages*.
MESSAGES2=$(emacsclient -f "$HOST_AUTH" -e '(with-current-buffer "*Messages*" (buffer-string))' 2>/tmp/emacsclient.err)
if printf '%s' "$MESSAGES2" | grep -q "saw: $CHAT_MSG"; then
    log "PASS: '*Messages*' contains 'saw: $CHAT_MSG' (chat.el path)"
else
    log "messages buffer: $MESSAGES2"
    fail "'*Messages*' did not contain 'saw: $CHAT_MSG' after chat.el SEND"
fi

log "PASS"
exit 0
