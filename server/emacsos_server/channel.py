"""Emacs-modifying channel — the tool the agent uses to call back into
the user's phone emacs during a /chat turn.

Wire shape:
- `_stream_turn` (`app.py`) parses the per-request phone identity
  (auth file contents + the request's reachable client host) into a
  `PhoneContext` and passes it through to `Thread` as
  `configurable={"phone_context": <ctx>}`.
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

from . import apply as apply_mod
from . import phone as phone_mod
from .config import Config
from .config_repo import ConfigRepo, ConfigRepoError, render

log = logging.getLogger(__name__)

# Read once at module load — `app.py` follows the same pattern at the
# top of that module.  Config is server-wide and the `emacsclient`
# path doesn't vary per request, so we don't re-parse env on every
# tool invocation.
_CONFIG = Config.from_env()

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
    )


@tool
def eval_elisp(code: str, config: RunnableConfig) -> str:
    """Evaluate elisp on the user's emacs and return the result as a
    string.  Use this to inspect or modify the user's emacs state —
    open buffers, set variables, load files, query the environment.

    The result is whatever `emacsclient -e` prints on stdout, with
    surrounding whitespace stripped (strings include their surrounding
    quotes, embedded newlines come back escaped as `\\n`, `nil` is the
    bare token `nil`, multi-line list values appear on one line).

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
            emacsclient=_CONFIG.emacsclient,
            timeout=EVAL_TIMEOUT_SECONDS,
        )
    except Exception as e:  # noqa: BLE001 — surface any failure as a tool-result string
        log.exception("eval_elisp raised")
        return f"error: {type(e).__name__}: {e}"
    if ok:
        return output
    # Distinguish phone-unreachable (network/auth/timeout/binary) from
    # an elisp-level error the agent might recover from with a
    # different expression.  Classifier lives in phone.py next to
    # call_emacs (whose output shapes it reads).
    if phone_mod.is_unreachable(output):
        return f"error: phone unreachable: {output} (do not retry — surface to user)"
    return f"error: {output}"


@tool
def apply_config(elisp: str, summary: str, config: RunnableConfig) -> str:
    """Replace the user's emacs config with ELISP and load it live on
    their phone.

    Pass the COMPLETE config — this REPLACES the config file wholesale,
    it is NOT appended.  Whatever you leave out is GONE after the next
    restart, so include everything the config should contain, not only
    the line you're changing.  If the user already has config, call
    `get_config` first to read the saved body and build on it — don't
    reconstruct it from memory.

    SUMMARY is a short imperative description of the change (e.g. "make
    the cursor blue").  It becomes the git commit message and is shown
    to the user.

    Only call this AFTER you have verified the elisp works via
    `eval_elisp` — apply is for shipping a config you already know is
    good, not for experimenting.

    Returns one of:
    - `applied: ...` — committed and loaded cleanly.  The user gets a
      ROLLBACK affordance in the chat UI; tell them it's applied.
    - `applied-but-broken: ...` — committed as the new config but it
      errored while loading on the phone.  Tell the user and suggest
      rolling back; do NOT just retry the same elisp (it'll fail the
      same way) — send a corrected config or let them roll back.
    - `error: phone unreachable: ... (do not retry — surface to user)` —
      nothing was committed; the phone couldn't be reached.
    - `error: config too large: ...` — nothing was committed.
    - `applied-but-unrecorded: ...` — the config is LIVE on the phone
      but the server failed to record it in git, so it can't be rolled
      back from history.  Tell the user; do NOT retry (that would just
      re-apply the same live config).

    Match the FULL prefix up to the colon when reasoning about the
    result: `applied:` is clean; the `applied-but-*` variants are not.
    """
    cfg = (config or {}).get("configurable") or {}
    ctx = cfg.get(PHONE_CONTEXT_KEY)
    if not isinstance(ctx, PhoneContext):
        return ("error: phone context not set (server bug — channel "
                "tool invoked outside a /chat turn)")

    log.info("apply_config on %s: %s", ctx.phone_host, _redact(summary))
    # Apply FIRST, commit only if the phone actually received it: this
    # keeps the git repo == what's on the phone (no phantom commit for a
    # config the phone never saw).  A load_error still counts as
    # "received" — the phone wrote the file then errored loading it, so
    # it IS the phone's current config and belongs in history.
    #
    # Apply the RENDERED file (the same content git commits, via
    # config_repo.render) — NOT the bare elisp — so the phone's agent.el
    # carries the lexical-binding cookie + provide and matches git byte
    # for byte.  write_and_commit renders the same body identically.
    ar = apply_mod.apply_to_phone(ctx, render(elisp))
    if ar.status == "too_large":
        return f"error: config too large: {ar.detail}"
    if ar.status == "unreachable":
        return (f"error: phone unreachable: {ar.detail} "
                "(do not retry — surface to user)")

    try:
        repo = ConfigRepo(_CONFIG.config_dir)
        repo.ensure()
        sha = repo.write_and_commit(elisp, summary)
    except Exception as e:  # noqa: BLE001 — report as a tool-result string
        log.exception("apply_config: git commit failed")
        return (f"applied-but-unrecorded: loaded on the phone but the "
                f"server failed to record it in git ({e}); the change is "
                "live but cannot be rolled back from history")

    short = sha[:7]
    if ar.status == "applied":
        return (f"applied: {summary} (v{short}) — loaded cleanly on the "
                "phone; the user can roll back from the chat UI")
    # load_error: HEAD is the new (broken) config; rollback is the fix.
    return (f"applied-but-broken: {summary} (v{short}) — committed as the "
            f"new config but it errored while loading ({ar.detail}); roll "
            "back or send a corrected config")


@tool
def get_config() -> str:
    """Return the user's CURRENTLY SAVED emacs config — the elisp body that
    is committed and loads on the next restart.

    Call this BEFORE `apply_config` whenever you're changing a config the
    user already has: `apply_config` REPLACES the whole file, so you must
    restate everything that should stay.  This gives you the exact current
    body to build on — do NOT reconstruct it from what was said earlier in
    the conversation (that can be stale, or gone after a New chat).  Read
    it, fold in your change, and pass the result straight back to
    `apply_config`, which takes the same bare-body form this returns.

    This is the SAVED config, not the live running state — to check what
    emacs is actually doing right now, use `eval_elisp` instead.  The two
    can differ (e.g. a config that was applied but errored while loading).
    The saved config does not change within a turn unless you call
    `apply_config`, so one read is enough.

    Returns the bare elisp body; or `empty: ...` when nothing is saved yet;
    or `error: ...` if the saved config can't be read (tell the user rather
    than retrying).
    """
    # No RunnableConfig param: unlike eval_elisp/apply_config this never
    # reaches the phone — it reads the server-side git repo, a single
    # server-wide config_dir (not keyed per phone), so there is no phone
    # identity to thread through.
    try:
        # current() is self-healing BY DESIGN: it calls ensure(), which
        # scaffolds a fresh repo and hard-resets a dirty tree.  So this
        # "read" can create the scaffold commit / reset stray working state
        # — intentional (the repo is server-owned, no uncommitted work to
        # lose).  Don't "fix" this into a non-mutating read or the
        # fresh-repo path breaks.
        body = ConfigRepo(_CONFIG.config_dir).current().body
    except Exception as e:  # noqa: BLE001 — surface any failure as a tool-result string
        log.exception("get_config: read failed")
        return f"error: could not read current config: {type(e).__name__}: {e}"
    if not body.strip():
        # Empty both for a never-configured phone (scaffold body) and a
        # config the user emptied — current() can't tell them apart, so the
        # message states only what's true.  NOT `error:` (empty is a valid
        # state, and an `error:` prefix would tell the agent "do not retry /
        # surface to user", which is wrong here).
        return "empty: no saved config to build on"
    return body


def revert_head_and_apply(ctx: PhoneContext, repo: ConfigRepo) -> tuple[str, str]:
    """Undo the last apply: git-revert the config repo's HEAD, then load the
    resulting config on the phone.  Returns ``(status, detail)`` where status is
    ``"noop"`` (nothing to undo) or one of ``apply_to_phone``'s statuses.

    Shared by the ``/rollback`` endpoint (app.py) and the ``revert_config`` tool
    so the revert-then-apply path lives in one place.  May raise
    ``ConfigRepoError`` on a corrupt repo / revert conflict — callers convert it
    to a structured result."""
    result = repo.rollback()
    if not result.ok:
        return ("noop", result.detail)
    # Apply the RENDERED file (what git holds) so the phone's agent.el stays
    # byte-identical to the repo, with the lexical-binding cookie.
    ar = apply_mod.apply_to_phone(ctx, render(result.version.body))
    return (ar.status, ar.detail)


@tool
def config_history() -> str:
    """List recent saved config versions, newest first, so you can pick which
    one to revert to with `revert_config`.

    Use this when the user wants to undo more than just the last change — e.g.
    "go back to how it was before the modeline edits".  Each line is
    `<short-sha>  <summary>`; pass a short-sha as `revert_config`'s target.
    Read the saved history here rather than reconstructing it from the chat.

    Returns the lines; or `empty: ...` when nothing has been applied yet; or
    `error: ...` if history can't be read (tell the user rather than retrying).
    """
    try:
        versions = ConfigRepo(_CONFIG.config_dir).history(limit=10)
    except Exception as e:  # noqa: BLE001 — surface any failure as a tool-result string
        log.exception("config_history: read failed")
        return f"error: could not read config history: {type(e).__name__}: {e}"
    # The oldest commit is always the empty-config scaffold; with only that one,
    # nothing has been applied yet.
    if len(versions) <= 1:
        return "empty: no config has been applied yet"
    return "\n".join(f"{v.sha[:7]}  {v.summary}" for v in versions)


@tool
def revert_config(target: str = "", config: RunnableConfig = None) -> str:
    """Undo a config change and load the result live on the phone.

    - `target` empty (the default) undoes the LAST applied config — the common
      "undo that" / "never mind" case.
    - `target` = a short-sha from `config_history` restores THAT version's
      config (use when the user wants to go back further than the last change;
      call `config_history` first to find the sha — don't guess it).

    The revert is itself recorded in git, so it too can be undone.  Returns:
    - `reverted: ...` / `restored: ...` — done and loaded cleanly on the phone.
    - `nothing to roll back ...` — there was no prior apply to undo.
    - `reverted-but-broken:` / `restored-but-broken:` — loaded but it errored;
      send a corrected config or pick a different version.
    - `restored-but-unrecorded: ...` — a restored config is LIVE on the phone but
      the server failed to record it in git; tell the user, do NOT retry.
    - `error: phone unreachable: ... (do not retry — surface to user)`.
    - `error: ...` — e.g. an unknown target sha; tell the user, don't retry.
    """
    cfg = (config or {}).get("configurable") or {}
    ctx = cfg.get(PHONE_CONTEXT_KEY)
    if not isinstance(ctx, PhoneContext):
        return ("error: phone context not set (server bug — channel tool "
                "invoked outside a /chat turn)")
    repo = ConfigRepo(_CONFIG.config_dir)
    target = target.strip()
    verb = "reverted" if not target else "restored"
    try:
        repo.ensure()
        if not target:
            log.info("revert_config (undo last) on %s", ctx.phone_host)
            status, detail = revert_head_and_apply(ctx, repo)
            if status == "noop":
                return detail  # "nothing to roll back (no config applied yet)"
            body = None  # rollback() already committed the git revert
        else:
            log.info("revert_config (restore %s) on %s", target, ctx.phone_host)
            # Roll-forward: re-apply the old body as a new commit.  A true git
            # revert of a non-HEAD commit would conflict on the single
            # full-snapshot file, so restore = re-apply that version's content.
            body = repo.body_at(target)
            ar = apply_mod.apply_to_phone(ctx, render(body))
            status, detail = ar.status, ar.detail
    except ConfigRepoError as e:
        log.exception("revert_config failed")
        return f"error: {e} (do not retry — surface to user)"

    if status == "too_large":
        return f"error: config too large: {detail}"
    if status == "unreachable":
        return (f"error: phone unreachable: {detail} "
                "(do not retry — surface to user)")
    if body is not None:
        # Restore path: commit only after the phone received it (mirrors
        # apply_config); undo-last was already committed by rollback().
        try:
            repo.write_and_commit(body, f"restore config to {target[:7]}")
        except Exception as e:  # noqa: BLE001
            log.exception("revert_config: commit failed")
            # Reachable only on the restore path (undo-last is already committed
            # by rollback()), so the verb is always "restored".
            return ("restored-but-unrecorded: loaded on the phone but the server "
                    f"failed to record it in git ({e}); the change is live but "
                    "cannot be rolled back from history")
    if status == "applied":
        return (f"{verb}: loaded cleanly on the phone; the user can roll back "
                "from the chat UI")
    # load_error: the phone wrote+errored the file, so it IS the live config.
    return (f"{verb}-but-broken: loaded but it errored ({detail}); send a "
            "corrected config or pick a different version to restore")


# The exported set of tools emacsos-server adds to every /chat agent
# via `Thread(..., spec=AgentSpec(tools=EMACS_TOOLS))`.  `eval_elisp` inspects /
# experiments on the live phone; `get_config` reads the saved config body
# so the agent can restate-and-change without relying on conversation
# memory (the committed file is the source of truth post-/clear);
# `apply_config` ships a verified config to the phone with a git-backed,
# rollback-able commit; `config_history` + `revert_config` make rollback
# conversational (undo the last change, or restore an older version by sha).
#
# `apply_config` in particular must stay a TOP-LEVEL tool (not buried in a
# sub-agent's toolset): app.py derives the `applied` event by watching the
# top-level message stream for apply_config's ToolMessage.  Move it into
# a sub-agent and the result stops surfacing — the event silently never
# fires and the ROLLBACK button never appears.
EMACS_TOOLS = [eval_elisp, apply_config, get_config, config_history, revert_config]
