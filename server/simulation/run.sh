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
CHAT_MSG="hi from chat.el"

# Smoke requires ASSIST_MODEL_URL — the server always runs assist
# now (echo fallback removed per PR #6 review).  Fail fast with a
# clear message rather than starting a server that errors on
# every /chat.
if [[ -z "${ASSIST_MODEL_URL:-}" ]]; then
    echo "[sim] FAIL: ASSIST_MODEL_URL must be set" >&2
    echo "[sim]       e.g. ASSIST_MODEL_URL=http://0.0.0.0:8000/v1 make smoke" >&2
    exit 2
fi

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
log "starting emacsos-server on :$SERVER_PORT (model=$ASSIST_MODEL_URL)"
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

# 6. Assert response shape: real agent reply (not an error, not an
#    echo-prefixed echo from some pre-removal fallback path).
echo "$RESPONSE" | TEST_MSG="$TEST_MSG" python3 -c "
import json, os, sys
r = json.load(sys.stdin)
msg = os.environ['TEST_MSG']
assert r['text'] != f'echo: {msg}', f'got echo response (echo path should be gone): {r!r}'
assert r['text'], f'empty text: {r!r}'
assert not r['text'].startswith('[error:'), f'agent errored: {r!r}'
assert r['side_effect'] is not None, f'side_effect missing: {r!r}'
print('[sim] response shape OK')
" || fail "response shape"

# 7. Independent verification: poll *Messages* on the daemon until
#    the (message ...) the server fired lands.  The back-channel
#    runs as a FastAPI BackgroundTask AFTER the response, so the
#    flash may not be there the instant curl returns.  Poll for
#    up to 5 seconds.  Flash always has the 'agent:' prefix since
#    the echo fallback was removed.
log "verifying via independent emacsclient call against the daemon"
HOST_AUTH=$(mktemp /tmp/sim-auth-XXXXXX)
printf '%s' "$AUTH_FILE_CONTENTS" | sed 's/0\.0\.0\.0/127.0.0.1/g' > "$HOST_AUTH"

EXPECTED_PREFIX="agent:"
MESSAGES=""
for _ in $(seq 1 10); do
    MESSAGES=$(emacsclient -f "$HOST_AUTH" -e '(with-current-buffer "*Messages*" (buffer-string))' 2>/tmp/emacsclient.err) || true
    if printf '%s' "$MESSAGES" | grep -q "$EXPECTED_PREFIX"; then
        break
    fi
    sleep 0.5
done
if printf '%s' "$MESSAGES" | grep -q "$EXPECTED_PREFIX"; then
    log "PASS: '*Messages*' contains '$EXPECTED_PREFIX'"
else
    log "messages buffer: $MESSAGES"
    fail "'*Messages*' did not contain '$EXPECTED_PREFIX' after 5s polling"
fi

# 8. Round-trip via chat.el inside the daemon.  The curl path above
#    proves the server in isolation; this path proves the full client
#    surface (chat.el + url-retrieve-synchronously + the request shape
#    the elisp actually produces) by driving (emacos--chat-send)
#    against the daemon and reading back *chat*.
log "round-trip via chat.el in the daemon"

# Clear *Messages* first so the back-channel side-effect check below
# doesn't match the 'agent:' flash from step 7.
emacsclient -f "$HOST_AUTH" -e '(with-current-buffer "*Messages*" (let ((inhibit-read-only t)) (erase-buffer)))' \
  >/dev/null 2>&1 || fail "could not clear *Messages*"

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
# emacsclient prints elisp strings in prin1 form (literal \n chars,
# not actual newlines), so parse with Python which decodes properly.
CHAT_TRANSCRIPT=$(emacsclient -f "$HOST_AUTH" \
  -e "(with-current-buffer \"*chat*\" (buffer-substring-no-properties (point-min) (point-max)))" \
  2>/tmp/emacsclient-chat.err)
[[ $? -eq 0 ]] \
  || fail "emacsclient could not read *chat*; stderr:\n$(cat /tmp/emacsclient-chat.err)"

printf '%s' "$CHAT_TRANSCRIPT" \
  | CHAT_MSG="$CHAT_MSG" python3 -c '
import ast, os, sys
raw = sys.stdin.read().strip()
# emacsclient outputs a prin1-escaped string literal;
# ast.literal_eval turns "\"a\\nb\"" into "a\nb".
try:
    transcript = ast.literal_eval(raw)
except (SyntaxError, ValueError) as e:
    print(f"could not decode transcript: {e!r}", file=sys.stderr)
    print(f"raw: {raw!r}", file=sys.stderr)
    sys.exit(1)
chat_msg = os.environ["CHAT_MSG"]

if f"you> {chat_msg}" not in transcript:
    print(f"*chat* transcript missing you> line:\n{transcript}", file=sys.stderr)
    sys.exit(2)

bot_lines = [ln for ln in transcript.split("\n") if ln.startswith("bot> ")]
if not bot_lines:
    print(f"*chat* transcript has no bot> line:\n{transcript}", file=sys.stderr)
    sys.exit(3)
bot = bot_lines[-1]
if bot.startswith("bot> [error:"):
    print(f"got error in chat.el round trip: {bot}", file=sys.stderr)
    sys.exit(4)
print(f"[sim] PASS: *chat* has you> {chat_msg} and bot reply: {bot[:80]}")
' || fail "*chat* transcript assertion (see stderr above)"

# Independent side-effect check: poll *Messages* for the 'agent:'
# flash.  We cleared *Messages* before sending, so any 'agent:'
# match is unambiguously from THIS round trip (addresses the
# step-7-residue race that the pre-clear-less version had).
CHAT_EXPECTED="agent:"
MESSAGES2=""
for _ in $(seq 1 10); do
    MESSAGES2=$(emacsclient -f "$HOST_AUTH" -e '(with-current-buffer "*Messages*" (buffer-string))' 2>/tmp/emacsclient.err) || true
    if printf '%s' "$MESSAGES2" | grep -q "$CHAT_EXPECTED"; then
        break
    fi
    sleep 0.5
done
if printf '%s' "$MESSAGES2" | grep -q "$CHAT_EXPECTED"; then
    log "PASS: '*Messages*' contains '$CHAT_EXPECTED' (chat.el path)"
else
    log "messages buffer: $MESSAGES2"
    fail "'*Messages*' did not contain '$CHAT_EXPECTED' after chat.el SEND (5s polling)"
fi

log "PASS"
exit 0
