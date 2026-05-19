"""Emacs-modifying channel — the tool the agent uses to call back into
the user's phone emacs during a /chat turn.

Wire shape:
- `_stream_turn` (`app.py`) parses the per-request phone identity
  (auth file contents + the request's reachable client host) into a
  `PhoneContext` and passes it through to `Thread` as
  `extra_config={"configurable": {"phone_context": <ctx>}}`.
- Langgraph carries that config into every tool invocation; the
  `eval_elisp` tool reads `config["configurable"]["phone_context"]`
  to find which phone to call.
- `eval_elisp` shells out via `phone.call_emacs(auth, host, code,
  timeout=EVAL_TIMEOUT_SECONDS)`; the result is returned as a string.
- On failure the return string is prefixed with `error:` and (for
  unreachable / timeout) carries an explicit `(do not retry — surface
  to user)` hint so a downstream skill / system prompt doesn't have to
  enforce no-retry policy itself.

Design doc: ../../docs/2026-05-18-emacs-modifying-channel.org.
"""
from __future__ import annotations

import logging
import re
from dataclasses import dataclass

from langchain_core.runnables import RunnableConfig
from langchain_core.tools import tool

from . import phone as phone_mod
from .config import Config

log = logging.getLogger(__name__)

# Hard upper bound on a single elisp eval.  Generous enough for
# (load-file "...") on a moderately-sized config but bounded enough
# that `(while t)` and friends return as a timeout error rather than
# pinning a worker thread for the rest of the stream.  Not env-
# tunable — if you find yourself wanting to tweak it, the agent is
# probably misbehaving and the right fix is upstream.
EVAL_TIMEOUT_SECONDS = 15.0

# Config-key under `RunnableConfig.configurable` where _stream_turn
# stashes the phone identity for this request.
PHONE_CONTEXT_KEY = "phone_context"

# Substring redaction for the elisp-eval log line.  We log the expr
# the agent sent (so we can debug why a call returned what it did),
# but if the expr happens to contain a secret the user pasted into
# chat we want it scrubbed before it lands in the log file.
_REDACT_RE = re.compile(
    r"(password|secret|api[_-]?key|token|authinfo)",
    re.IGNORECASE,
)


@dataclass(frozen=True)
class PhoneContext:
    """Identity of the phone making this /chat request.

    `auth_contents` is the raw `~/.emacs.d/server/server` file the phone
    POSTs in the request body.  `phone_host` is what we substitute for
    the (untrusted) host field in that file — comes from FastAPI's
    `request.client.host`, the real source address of the TCP socket.

    No `emacsclient` field here: that's server-wide config and lives
    on `Config` (read directly by the tool).
    """
    auth_contents: str
    phone_host: str


def _redact(s: str) -> str:
    """Substring-replace lines mentioning known-secret-shaped words.
    Conservative: matches anywhere on the line, replaces the whole
    line with `<redacted>` rather than trying to surgically remove
    just the secret value.  False positives (a benign expr mentioning
    "password" as a string literal) get redacted from logs — that's
    the right side of the trade-off."""
    return "\n".join(
        "<redacted>" if _REDACT_RE.search(line) else line
        for line in s.splitlines()
    ) or s


@tool
def eval_elisp(code: str, config: RunnableConfig) -> str:
    """Evaluate elisp on the user's emacs and return the result as a
    string.  Use this to inspect or modify the user's emacs state —
    open buffers, set variables, load files, query the environment.

    The result is the value's printed representation as emacsclient -e
    prints it (close to `prin1-to-string` but with trailing whitespace
    stripped: strings come back wrapped in quotes, multi-line values
    have literal newlines, `nil` is the bare token `nil`).

    On failure the return string is prefixed with `error:` — for
    example `error: phone unreachable: ... (do not retry — surface to
    user)` or `error: (void-variable foo)`.  When you see `error:`,
    do not retry the same call; either try a different approach or
    tell the user.
    """
    cfg = (config or {}).get("configurable") or {}
    ctx = cfg.get(PHONE_CONTEXT_KEY)
    if not isinstance(ctx, PhoneContext):
        # The contract is that _stream_turn always sets this for /chat
        # turns; reaching here means a non-/chat caller (eg. a test
        # forgot to set it).  Don't crash the stream — return an error
        # the agent can reason about.
        return ("error: phone context not set (server bug — channel "
                "tool invoked outside a /chat turn)")

    log.info("eval_elisp on %s: %s", ctx.phone_host, _redact(code))
    try:
        ok, output = phone_mod.call_emacs(
            ctx.auth_contents,
            ctx.phone_host,
            code,
            emacsclient=Config.from_env().emacsclient,
            timeout=EVAL_TIMEOUT_SECONDS,
        )
    except Exception as e:  # noqa: BLE001 — surface any failure as a tool-result string
        log.exception("eval_elisp raised")
        return f"error: {type(e).__name__}: {e}"
    if ok:
        return output
    # Distinguish phone-unreachable (network/auth/timeout/binary
    # missing) from the elisp itself signalling an error.  call_emacs
    # returns False for both, but the message shape lets us split:
    # emacsclient prefixes its own errors with `emacsclient:` (eg.
    # "emacsclient: connect: Connection refused"); elisp evaluation
    # errors arrive without that prefix.  All unreachable-shaped
    # failures get the explicit no-retry hint baked in so a future
    # skill doesn't have to enforce no-retry from the system prompt.
    is_unreachable = (
        output.startswith("emacsclient:")
        or "timed out" in output
        or "auth file" in output
        or "binary not found" in output
    )
    if is_unreachable:
        return f"error: phone unreachable: {output} (do not retry — surface to user)"
    return f"error: {output}"


# The exported set of tools emacsos-server adds to every /chat agent
# via `Thread(..., extra_tools=EMACS_TOOLS)`.  One tool today; the
# list shape is so a future second tool (eg. a structured one if the
# agent's free-form elisp composition turns out to need scaffolding)
# can land without touching app.py's wiring.
EMACS_TOOLS = [eval_elisp]
