#!/usr/bin/env bash
# Smoke /chat from the phone side: read the local emacs auth file,
# embed its contents in the request body, POST to emacsos-server,
# print the response.
#
# Usage:
#   ./scripts/chat-from-phone.sh [server-url] [message]
#
# Defaults:
#   server-url = $EMACSOS_SERVER_URL  (or http://localhost:8765)
#   message    = "hello from phone"
#
# Requires:
#   - Emacs running with (server-start) + server-use-tcp t so
#     ~/.emacs.d/server/server exists.  `make start-server` does this.
#   - emacsos-server running on the dev box.  `make server` does this.
#   - python3 + curl on this machine.

set -uo pipefail

SERVER_URL="${1:-${EMACSOS_SERVER_URL:-http://localhost:8765}}"
MESSAGE="${2:-hello from phone}"
AUTH_FILE="$HOME/.emacs.d/server/server"

if [[ ! -f "$AUTH_FILE" ]]; then
    echo "ERROR: no auth file at $AUTH_FILE" >&2
    echo "Start the phone's emacs server first: make start-server" >&2
    exit 1
fi

# Reachability check before we bother building the payload.
if ! curl -s -o /dev/null --max-time 3 "$SERVER_URL/docs"; then
    echo "ERROR: $SERVER_URL is not reachable" >&2
    echo "Is \`make server\` running on the dev box at this address?" >&2
    exit 2
fi

echo "-> POST $SERVER_URL/chat"
echo "   message: $MESSAGE"

# Build the JSON body via python so message + auth-file contents are
# escaped correctly even if they contain quotes/backslashes/newlines.
BODY=$(python3 -c "
import json, pathlib, sys
auth = pathlib.Path(sys.argv[1]).read_text()
print(json.dumps({'message': sys.argv[2], 'phone': {'auth_file': auth}}))
" "$AUTH_FILE" "$MESSAGE")

RESPONSE=$(curl -s -X POST "$SERVER_URL/chat" \
    -H 'Content-Type: application/json' \
    -d "$BODY")

echo "<- response: $RESPONSE"
echo

echo "$RESPONSE" | python3 -c "
import json, sys
r = json.load(sys.stdin)
print(f'   text:        {r[\"text\"]}')
print(f'   side_effect: {r[\"side_effect\"]}')
if r.get('side_effect') is None:
    print()
    print('WARNING: side_effect is null -- the server could not reach the phone')
    print('via emacsclient.  Check the server logs for an emacsclient error.')
    sys.exit(3)
print()
print('You should see a minibuffer flash on this phone reading:')
print(f'  saw: {r[\"text\"][len(\"echo: \"):]}')
"
