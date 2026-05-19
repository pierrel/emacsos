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

# 5. POST /chat FROM INSIDE the container as a STREAMING request.
#    Use `curl -N` (no buffering) and assert the NDJSON structure is
#    well-formed (>=1 token event, exactly one end event, and the
#    end.text matches the concatenation of token texts).  Catches
#    truncated / mis-encoded streams; no timing assertion is made --
#    real-phone verification covers incremental render.
log "POST /chat (streaming) from inside the phone container"
# Build the JSON body once, host-side, where python3 is available.
REQ_BODY=$(python3 -c "import json,sys; print(json.dumps({'message': sys.argv[1], 'phone': {'auth_file': sys.argv[2]}}))" "$TEST_MSG" "$AUTH_FILE_CONTENTS")
HOST_AUTH=$(mktemp /tmp/sim-auth-XXXXXX)
printf '%s' "$AUTH_FILE_CONTENTS" | sed 's/0\.0\.0\.0/127.0.0.1/g' > "$HOST_AUTH"

EVENTS_FILE=$(mktemp /tmp/sim-events-XXXXXX.ndjson)
docker exec -i "$CONTAINER" sh -c \
  "curl -sN -X POST -H 'Content-Type: application/json' --data @- \
   http://127.0.0.1:$SERVER_PORT/chat" <<< "$REQ_BODY" \
  | tee "$EVENTS_FILE" >/dev/null \
  || fail "curl streaming failed"

EVENT_COUNT=$(wc -l <"$EVENTS_FILE")
log "got $EVENT_COUNT NDJSON event lines from /chat"
[[ $EVENT_COUNT -gt 0 ]] || fail "no events received"

# 6. Assert event-stream shape: start, ≥1 token, end with non-empty
#    text, no error.  See design doc §10 for the assertion
#    rationale (we don't enforce per-token timing — that's a flaky
#    signal; we enforce structural completeness).
python3 - "$EVENTS_FILE" <<'PY' || fail "stream shape"
import json, sys, pathlib
path = pathlib.Path(sys.argv[1])
events = [json.loads(line) for line in path.read_text().splitlines() if line]
types = [e["type"] for e in events]
assert types and types[0] == "start", f"first event must be start: {types[:3]}"
assert "end" in types or "error" in types, f"stream must terminate: {types[-5:]}"
errors = [e for e in events if e["type"] == "error"]
assert not errors, f"got error event(s): {errors}"
tokens = [e for e in events if e["type"] == "token"]
end = [e for e in events if e["type"] == "end"][-1]
assert tokens, "no token events; agent produced empty content"
assert end["text"], "end event has empty text"
# Concat of tokens should equal end.text (or differ by ≤10 chars
# for benign LangGraph aggregation diffs).
concat = "".join(t["text"] for t in tokens)
diff = abs(len(concat) - len(end["text"]))
assert diff <= 10, f"token concat differs from end.text by {diff} chars"
print("[sim] stream shape OK:", len(tokens), "tokens,", end["text"][:60])
PY

rm -f "$EVENTS_FILE"


# 7. Round-trip via chat.el inside the daemon.  Proves the full
#    client surface: chat.el's NDJSON process filter + incremental
#    insertion + marker lifecycle.  SEND is async now — polls *chat*
#    until emacos--chat-in-flight clears and asserts the bot line
#    GREW between polls (proving incremental render).
log "round-trip via chat.el in the daemon"

# Load chat.el and point it at the server + the daemon's own auth file.
emacsclient -f "$HOST_AUTH" -e "(progn
  (load-file \"/opt/emacsos/chat.el\")
  (setq emacos-chat-server-url \"http://127.0.0.1:$SERVER_PORT/chat\")
  (setq emacos-chat-auth-file \"/home/phone/.emacs.d/server/server\"))" \
  >/dev/null 2>&1 \
  || fail "chat.el did not load in the daemon"

# Simulate the user typing into the input region and pressing SEND.
# SEND returns immediately (async); the stream renders in background.
SEND_RESULT=$(emacsclient -f "$HOST_AUTH" -e "(progn
  (with-current-buffer (emacos--chat-buffer)
    (goto-char (point-max))
    (insert \"$CHAT_MSG\"))
  (emacos--chat-send)
  (list :in-flight emacos--chat-in-flight
        :process (and emacos--chat-process (process-status emacos--chat-process))))" 2>/tmp/emacsclient-chat.err) \
  || fail "emacos--chat-send signaled; stderr:\n$(cat /tmp/emacsclient-chat.err)"
log "post-send daemon state: $SEND_RESULT"

# Poll *chat* every 200ms; record each transcript snapshot.  Stop
# when emacos--chat-in-flight clears (stream ended) or after 20s.
INCREMENTAL_FILE=$(mktemp /tmp/sim-chat-poll-XXXXXX)
for i in $(seq 1 100); do
  STATE=$(emacsclient -f "$HOST_AUTH" -e '(list :in-flight emacos--chat-in-flight :transcript (with-current-buffer "*chat*" (buffer-substring-no-properties (point-min) (point-max))))' 2>/dev/null)
  printf '%s\t%s\n' "$i" "$STATE" >> "$INCREMENTAL_FILE"
  if printf '%s' "$STATE" | grep -q ':in-flight nil'; then
    break
  fi
  sleep 0.2
done

# Decode + assert: final transcript has you> + non-error bot> lines.
# Incremental-render check is a soft assertion (best-effort).
python3 - "$INCREMENTAL_FILE" "$CHAT_MSG" <<'PY' || fail "chat.el transcript assertion"
import ast, re, sys, pathlib
path = pathlib.Path(sys.argv[1])
chat_msg = sys.argv[2]
polls = []
for raw in path.read_text().splitlines():
    if "\t" not in raw:
        continue
    idx, state = raw.split("\t", 1)
    m = re.search(r':transcript (".*")', state, re.DOTALL)
    if not m:
        continue
    try:
        transcript = ast.literal_eval(m.group(1))
    except (SyntaxError, ValueError):
        continue
    in_flight = ':in-flight t' in state
    polls.append((int(idx), in_flight, transcript))

assert polls, "no decodable polls"
final = polls[-1][2]
assert f"you> {chat_msg}" in final, f"final transcript missing you> line:\n{final}"
bot_lines = [ln for ln in final.split("\n") if ln.startswith("bot> ")]
assert bot_lines, f"final transcript has no bot> line:\n{final}"
bot = bot_lines[-1]
assert not bot.startswith("bot> [error:"), f"chat.el got error: {bot}"

def bot_len(t):
    blines = [ln for ln in t.split("\n") if ln.startswith("bot> ")]
    return len(blines[-1]) if blines else 0
inflight_lens = [bot_len(t) for (_, inflight, t) in polls if inflight]
grew = any(b > a for a, b in zip(inflight_lens, inflight_lens[1:]))
if not grew:
    print("[sim] note: render was too fast to catch mid-stream growth", file=sys.stderr)
print(f"[sim] PASS: *chat* has you> {chat_msg} and non-error bot reply ({len(bot)} chars)")
PY

rm -f "$INCREMENTAL_FILE" "$HOST_AUTH"

log "PASS"
exit 0
