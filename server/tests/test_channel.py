"""Tests for the emacs-modifying channel: the `eval_elisp` tool, the
PhoneContext dataclass, and the `_redact` helper.  Phone-side I/O
(call_emacs → subprocess) is mocked; we're testing the tool's wiring
to RunnableConfig and its error-string contract."""
from __future__ import annotations

from unittest.mock import patch

from emacsos_server.apply import ApplyResult
from emacsos_server.channel import (
    EMACS_TOOLS,
    PHONE_CONTEXT_KEY,
    PhoneContext,
    _redact,
    apply_config,
    eval_elisp,
    get_config,
)
from emacsos_server.config_repo import ConfigRepo, ConfigRepoError


_CTX = PhoneContext(auth_contents="0.0.0.0:1234 555\nsecret\n",
                    phone_host="10.0.0.42")


def _invoke(code: str, ctx: PhoneContext | None = _CTX) -> str:
    """Invoke the @tool through its standard StructuredTool wrapper so
    we exercise the same path the agent uses, including RunnableConfig
    extraction."""
    cfg = {"configurable": {PHONE_CONTEXT_KEY: ctx}} if ctx is not None else {}
    return eval_elisp.invoke({"code": code}, config=cfg)


# --- happy path -------------------------------------------------------------

def test_eval_elisp_returns_emacsclient_stdout_on_success():
    with patch("emacsos_server.channel.phone_mod.call_emacs",
               return_value=(True, "3")) as ce:
        result = _invoke("(+ 1 2)")
    assert result == "3"
    args, kwargs = ce.call_args
    # call_emacs signature: (auth_contents, phone_host, code, ...).
    assert args[0] == _CTX.auth_contents
    assert args[1] == _CTX.phone_host
    assert args[2] == "(+ 1 2)"
    # Timeout is hardcoded — see channel.EVAL_TIMEOUT_SECONDS.
    assert kwargs["timeout"] == 15.0


# --- error contract ---------------------------------------------------------

def test_eval_elisp_returns_error_prefix_on_elisp_failure():
    """`(void-variable foo)` and friends: emacsclient exits non-zero,
    call_emacs returns (False, stderr).  Tool surfaces as
    `error: <msg>` — NO no-retry hint, since this is a legitimate
    error the agent might recover from by trying a different expr."""
    with patch("emacsos_server.channel.phone_mod.call_emacs",
               return_value=(False, "Symbol's value as variable is void: foo")):
        result = _invoke("foo")
    assert result.startswith("error: ")
    assert "void" in result.lower()
    assert "do not retry" not in result


def test_eval_elisp_unreachable_phone_adds_no_retry_hint():
    """Timeouts / network failures / unparseable auth / binary missing
    get the explicit no-retry hint in the result string itself so a
    future skill / system prompt doesn't have to enforce no-retry
    policy."""
    with patch("emacsos_server.channel.phone_mod.call_emacs",
               return_value=(False, "emacsclient timed out after 15.0s")):
        result = _invoke("(while t)")
    assert result.startswith("error: phone unreachable")
    assert "do not retry" in result


def test_eval_elisp_connection_refused_treated_as_unreachable():
    """The case we just saw on real hardware: server is up but
    request.client.host can't reach the emacs daemon (phone off,
    wrong IP, port-forward dropped).  emacsclient prefixes its own
    errors with `emacsclient:` — discriminator from elisp errors."""
    with patch("emacsos_server.channel.phone_mod.call_emacs",
               return_value=(False, "emacsclient: connect: Connection refused")):
        result = _invoke("(+ 1 2)")
    assert result.startswith("error: phone unreachable")
    assert "do not retry" in result


def test_eval_elisp_unparseable_auth_treated_as_unreachable():
    with patch("emacsos_server.channel.phone_mod.call_emacs",
               return_value=(False, "auth file: must have header + secret lines")):
        result = _invoke("(buffer-name)")
    assert "phone unreachable" in result
    assert "do not retry" in result


def test_eval_elisp_binary_missing_treated_as_unreachable():
    with patch("emacsos_server.channel.phone_mod.call_emacs",
               return_value=(False, "emacsclient binary not found: emacsclient")):
        result = _invoke("(buffer-name)")
    assert "phone unreachable" in result
    assert "do not retry" in result


def test_eval_elisp_os_error_treated_as_unreachable():
    """call_emacs's OSError branch returns `str(e)` which starts with
    `[Errno N]` for typical OS errors.  Channel must recognise this
    as infrastructure failure, not an elisp semantic error."""
    with patch("emacsos_server.channel.phone_mod.call_emacs",
               return_value=(False, "[Errno 13] Permission denied")):
        result = _invoke("(buffer-name)")
    assert "phone unreachable" in result
    assert "do not retry" in result


def test_eval_elisp_empty_stderr_exit_code_treated_as_unreachable():
    """call_emacs's empty-stderr fallback is `f'exit {N}'`.  Channel
    must NOT mis-classify that as an elisp error and let the agent
    retry against a host that just returned a non-zero exit."""
    with patch("emacsos_server.channel.phone_mod.call_emacs",
               return_value=(False, "exit 1")):
        result = _invoke("(buffer-name)")
    assert "phone unreachable" in result
    assert "do not retry" in result


def test_eval_elisp_subprocess_exception_surfaces_as_error():
    with patch("emacsos_server.channel.phone_mod.call_emacs",
               side_effect=OSError("[Errno 24] Too many open files")):
        result = _invoke("(buffer-name)")
    assert result.startswith("error: OSError")
    assert "Too many open files" in result


# --- _redact ----------------------------------------------------------------

def test_redact_replaces_lines_with_secret_substrings():
    src = (
        "(progn\n"
        "  (setq my-password \"hunter2\")\n"
        "  (message \"hi\"))"
    )
    out = _redact(src)
    assert "hunter2" not in out
    assert "<redacted>" in out
    # Non-secret lines preserved.
    assert "(message" in out


def test_redact_handles_no_secrets():
    src = "(+ 1 2)"
    assert _redact(src) == src


# --- apply_config -----------------------------------------------------------

def _apply(elisp, summary, tmp_path, ctx=_CTX, apply_result=None):
    """Invoke apply_config with apply_to_phone mocked and ConfigRepo
    pointed at a tmp repo, so we exercise the commit-if-reached
    orchestration without a real phone.  Returns (result_string, repo)."""
    repo = ConfigRepo(str(tmp_path / "repo"))
    # Pre-init so `repo.current()` works in assertions even on the
    # no-commit paths (unreachable / too_large return before ensure()).
    # apply_config's own ensure() is idempotent on the reached paths.
    repo.ensure()
    cfg = {"configurable": {PHONE_CONTEXT_KEY: ctx}} if ctx is not None else {}
    with patch("emacsos_server.channel.apply_mod.apply_to_phone",
               return_value=apply_result), \
         patch("emacsos_server.channel.ConfigRepo", lambda _dir: repo):
        out = apply_config.invoke(
            {"elisp": elisp, "summary": summary}, config=cfg)
    return out, repo


def test_apply_config_applied_commits_and_reports_version(tmp_path):
    out, repo = _apply("(setq x 1)", "set x", tmp_path,
                       apply_result=ApplyResult("applied", "ok: loaded"))
    assert out.startswith("applied:")
    assert "set x" in out
    # Committed: the body round-trips from the repo's current version.
    assert repo.current().body == "(setq x 1)"


def test_apply_config_sends_rendered_file_to_phone(tmp_path):
    """The phone must receive the SAME rendered file git commits — with
    the lexical-binding cookie — not the bare body."""
    from emacsos_server.config_repo import render
    repo = ConfigRepo(str(tmp_path / "repo"))
    repo.ensure()
    cfg = {"configurable": {PHONE_CONTEXT_KEY: _CTX}}
    with patch("emacsos_server.channel.apply_mod.apply_to_phone",
               return_value=ApplyResult("applied", "ok: loaded")) as m, \
         patch("emacsos_server.channel.ConfigRepo", lambda _d: repo):
        apply_config.invoke({"elisp": "(setq x 1)", "summary": "s"}, config=cfg)
    sent = m.call_args.args[1]
    assert "lexical-binding: t" in sent
    assert sent == render("(setq x 1)")  # byte-identical to what git stores


def test_apply_config_load_error_is_applied_but_broken_and_commits(tmp_path):
    out, repo = _apply(
        "(foo)", "call foo", tmp_path,
        apply_result=ApplyResult("load_error", "load-error: (void-function foo)"))
    assert out.startswith("applied-but-broken:")
    assert "void-function" in out
    # A broken config that reached the phone is still recorded (it IS
    # the phone's current config), so rollback has a prior to revert to.
    assert repo.current().body == "(foo)"


def test_apply_config_unreachable_does_not_commit(tmp_path):
    out, repo = _apply(
        "(setq x 1)", "set x", tmp_path,
        apply_result=ApplyResult("unreachable", "emacsclient: connection refused"))
    assert out.startswith("error: phone unreachable")
    assert "do not retry" in out
    # Nothing committed beyond the scaffold — no phantom version.
    assert repo.current().body == ""


def test_apply_config_too_large_does_not_commit(tmp_path):
    out, repo = _apply(
        "(setq x 1)", "set x", tmp_path,
        apply_result=ApplyResult("too_large", "config is 200000 bytes; max 100000"))
    assert out.startswith("error: config too large")
    assert repo.current().body == ""


def test_apply_config_commit_failure_is_unrecorded(tmp_path):
    """Phone loaded it but git failed: honest `applied-but-unrecorded`,
    NOT a clean `applied:` (it has no commit to roll back to)."""
    repo = ConfigRepo(str(tmp_path / "repo"))
    repo.ensure()
    cfg = {"configurable": {PHONE_CONTEXT_KEY: _CTX}}
    with patch("emacsos_server.channel.apply_mod.apply_to_phone",
               return_value=ApplyResult("applied", "ok: loaded")), \
         patch("emacsos_server.channel.ConfigRepo", lambda _dir: repo), \
         patch.object(repo, "write_and_commit", side_effect=OSError("disk full")):
        out = apply_config.invoke({"elisp": "(setq x 1)", "summary": "s"},
                                  config=cfg)
    assert out.startswith("applied-but-unrecorded:")
    assert "disk full" in out
    # Must NOT masquerade as a clean apply (which would offer a bad rollback).
    assert not out.startswith("applied:")


def test_apply_config_missing_context_is_server_bug_error(tmp_path):
    out, _repo = _apply("(setq x 1)", "set x", tmp_path, ctx=None,
                        apply_result=ApplyResult("applied", "ok: loaded"))
    assert out.startswith("error: phone context not set")


# --- get_config --------------------------------------------------------------

def _committed(tmp_path, body=None, summary="s"):
    """A tmp ConfigRepo, optionally with one applied (committed) body."""
    repo = ConfigRepo(str(tmp_path / "repo"))
    repo.ensure()
    if body is not None:
        repo.write_and_commit(body, summary)
    return repo


def _get_config(repo):
    """Invoke get_config with ConfigRepo pointed at REPO.  No config / phone
    context is passed — get_config must work without one (it reads the
    server-side repo, not the phone)."""
    with patch("emacsos_server.channel.ConfigRepo", lambda _dir: repo):
        return get_config.invoke({})


def test_get_config_returns_committed_body(tmp_path):
    repo = _committed(tmp_path, body="(setq x 1)")
    assert _get_config(repo) == "(setq x 1)"


def test_get_config_empty_repo_reports_empty_not_error(tmp_path):
    """Fresh/scaffold repo: current().body == "".  The agent must be able to
    tell "nothing saved" from a read failure, so it's `empty:` — and NOT
    `error:` (which would wrongly mean "do not retry / surface to user")."""
    repo = _committed(tmp_path)  # scaffold only, no apply
    out = _get_config(repo)
    assert out.startswith("empty:")
    assert not out.startswith("error:")


def test_get_config_read_failure_is_error_string(tmp_path):
    """A git/fs failure surfaces as `error: ...` (mirrors the eval_elisp /
    apply_config convention), not an uncaught exception that crashes the
    stream."""
    repo = _committed(tmp_path, body="(setq x 1)")
    with patch.object(repo, "current", side_effect=ConfigRepoError("boom")):
        out = _get_config(repo)
    assert out.startswith("error: could not read current config")
    assert "boom" in out


def test_get_config_takes_no_args_and_needs_no_phone_context(tmp_path):
    """Design asymmetry with its siblings: get_config reads the server-side
    repo, so it exposes NO model-visible args and needs no PhoneContext.
    Invoking with an empty payload + no config returns the real body, never
    the `phone context not set` server-bug string."""
    assert get_config.args == {}
    repo = _committed(tmp_path, body="(setq x 1)")
    out = _get_config(repo)
    assert out == "(setq x 1)"
    assert "phone context not set" not in out


# --- EMACS_TOOLS exported list ---------------------------------------------

def test_emacs_tools_includes_eval_elisp():
    assert eval_elisp in EMACS_TOOLS


def test_emacs_tools_includes_apply_config():
    assert apply_config in EMACS_TOOLS


def test_emacs_tools_includes_get_config():
    assert get_config in EMACS_TOOLS
