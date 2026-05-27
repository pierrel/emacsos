"""Unit tests for EmacsBackend — the SandboxBackendProtocol whose shell is
the phone's emacs daemon.  The `eval_elisp` transport is mocked, so these
run without a phone: they pin execute()'s elisp construction + base64
decode, the working-dir/`.assist` guardrails, and that being a
SandboxBackendProtocol enables deepagents' execute tool.
"""

import base64

import pytest

from emacsos_server.emacs_backend import EmacsBackend


def _b64_quoted(text: str) -> str:
    """Mimic emacsclient printing a base64 string result: surrounded by
    double quotes, no internal escaping (base64 has none)."""
    return '"' + base64.b64encode(text.encode("utf-8")).decode("ascii") + '"'


def _make_eval(result_text="0\n", record=None, ok=True):
    def _eval(elisp):
        if record is not None:
            record.append(elisp)
        return (ok, _b64_quoted(result_text) if ok else result_text)
    return _eval


# --- execute() --------------------------------------------------------------

def test_execute_parses_exit_and_output():
    be = EmacsBackend("/home/pi/proj", _make_eval("0\nhello world"))
    r = be.execute("echo hello world")
    assert r.exit_code == 0
    assert r.output == "hello world"
    assert r.truncated is False


def test_execute_runs_in_workdir_via_elisp():
    rec = []
    be = EmacsBackend("/home/pi/proj", _make_eval("0\n", rec))
    be.execute("ls -la")
    assert len(rec) == 1
    elisp = rec[0]
    assert '"/home/pi/proj/"' in elisp          # default-directory
    assert "call-process-shell-command" in elisp
    assert "timeout --kill-after" in elisp       # bounded
    assert "base64-encode-string" in elisp       # clean transport


def test_execute_nonzero_exit():
    be = EmacsBackend("/w", _make_eval("2\noops"))
    r = be.execute("false")
    assert r.exit_code == 2
    assert r.output == "oops"


def test_execute_timeout_surfaces_guidance():
    be = EmacsBackend("/w", _make_eval("124\n"))
    r = be.execute("sleep 999")
    assert r.exit_code == 124
    assert "wall-clock limit" in r.output


def test_execute_transport_failure_is_a_result_not_a_raise():
    be = EmacsBackend("/w", lambda _e: (False, "phone unreachable"))
    r = be.execute("ls")
    assert r.exit_code == 1
    assert "phone unreachable" in r.output


def test_execute_eval_exception_is_caught():
    def boom(_e):
        raise RuntimeError("emacsclient exploded")
    be = EmacsBackend("/w", boom)
    r = be.execute("ls")
    assert r.exit_code == 1
    assert "emacsclient exploded" in r.output


def test_decode_handles_unquoted_payload():
    be = EmacsBackend("/w", _make_eval())
    # Some transports may strip the quotes already.
    assert be._decode(base64.b64encode(b"7\nbody").decode()) == (7, "body")


# --- guardrails (file tools only; execute is intentionally unconfined) ------

def test_resolve_prefixes_workdir():
    be = EmacsBackend("/home/pi/proj", _make_eval())
    assert be._resolve("/a.txt") == "/home/pi/proj/a.txt"
    assert be._resolve("a.txt") == "/home/pi/proj/a.txt"
    assert be._resolve("/home/pi/proj/x") == "/home/pi/proj/x"


def test_resolve_blocks_dotdot():
    be = EmacsBackend("/w", _make_eval())
    with pytest.raises(ValueError):
        be._resolve("../etc/passwd")
    with pytest.raises(ValueError):
        be._resolve("a/../../b")


def test_resolve_refuses_assist_paths():
    be = EmacsBackend("/w", _make_eval())
    with pytest.raises(ValueError):
        be._resolve("/chat.assist")
    with pytest.raises(ValueError):
        be.read("/foo.assist")     # the refusal reaches the file tools


# --- protocol lineage: SandboxBackendProtocol => execute tool enabled -------

def test_is_sandbox_backend_protocol_and_enables_execute():
    from deepagents.backends.protocol import SandboxBackendProtocol
    from deepagents.backends import CompositeBackend, StateBackend
    from deepagents.middleware.filesystem import supports_execution

    be = EmacsBackend("/w", _make_eval())
    assert isinstance(be, SandboxBackendProtocol)
    comp = CompositeBackend(default=be, routes={"/scratch/": StateBackend()})
    assert supports_execution(comp) is True


def test_file_tools_route_through_execute_with_resolved_path():
    rec = []
    be = EmacsBackend("/home/pi/proj", _make_eval("0\n", rec))
    # ls inherits from BaseSandbox and runs a shell command via execute;
    # we only assert the wiring (resolved path reaches the phone), not the
    # parse of an empty listing.  BaseSandbox embeds the path base64-encoded
    # inside a python3 scandir one-liner, so match against that form.
    try:
        be.ls("/sub")
    except Exception:
        pass
    assert rec, "ls should route through execute -> eval"
    resolved_b64 = base64.b64encode(b"/home/pi/proj/sub").decode("ascii")
    assert any(resolved_b64 in e for e in rec), (
        "the resolved working-dir path should reach BaseSandbox's command")
