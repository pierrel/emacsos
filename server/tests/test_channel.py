"""Tests for the emacs-modifying channel: the `eval_elisp` tool, the
PhoneContext dataclass, and the `_redact` helper.  Phone-side I/O
(call_emacs → subprocess) is mocked; we're testing the tool's wiring
to RunnableConfig and its error-string contract."""
from __future__ import annotations

from unittest.mock import patch

from emacsos_server.channel import (
    EMACS_TOOLS,
    PHONE_CONTEXT_KEY,
    PhoneContext,
    _redact,
    eval_elisp,
)


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


# --- EMACS_TOOLS exported list ---------------------------------------------

def test_emacs_tools_includes_eval_elisp():
    assert eval_elisp in EMACS_TOOLS
