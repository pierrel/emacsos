"""Git-backed config repo emacsos-server owns end-to-end.

A single file =agent.el= lives in a git repo at ``config_dir``.  The
agent never touches git; the server commits each applied config and
navigates history for rollback.  HEAD-of-repo == currently-applied
config (the one documented exception is an unreachable apply, where
the commit lands but the phone never loaded it — see apply.py).

Pure git + filesystem; no langgraph/assist imports, so this is
unit-testable against a tmp repo with no mocks.  Design doc:
docs/2026-05-21-config-apply-rollback.org.
"""
from __future__ import annotations

import logging
import os
import subprocess
from dataclasses import dataclass

log = logging.getLogger(__name__)

AGENT_FILE = "agent.el"

# Header + footer wrap the agent-supplied body so agent.el is always a
# loadable feature even when the body is empty (scaffold) — and so the
# whole-file replace on each apply has stable bookends.
_HEADER = ";;; agent.el --- agent-managed emacsos config -*- lexical-binding: t -*-\n;;; Managed by emacsos-server; do not edit by hand.\n\n"
_FOOTER = "\n(provide 'agent)\n;;; agent.el ends here\n"

# Commit identity baked in so commits never depend on (or mutate) the
# operator's global git config.
_GIT_IDENTITY = [
    "-c", "user.email=emacsos@localhost",
    "-c", "user.name=emacsos-server",
]


class ConfigRepoError(RuntimeError):
    """A git/fs operation on the config repo failed."""


@dataclass(frozen=True)
class ConfigVersion:
    sha: str
    summary: str
    body: str  # the agent-supplied body (between header and footer)


@dataclass(frozen=True)
class RollbackResult:
    ok: bool
    detail: str
    version: ConfigVersion | None = None  # new HEAD after the revert


def _render(body: str) -> str:
    return _HEADER + body.strip("\n") + _FOOTER


def _extract_body(full: str) -> str:
    """Inverse of `_render`: pull the agent body back out of agent.el."""
    s = full
    if s.startswith(_HEADER):
        s = s[len(_HEADER):]
    if s.endswith(_FOOTER):
        s = s[: -len(_FOOTER)]
    return s.strip("\n")


class ConfigRepo:
    def __init__(self, repo_dir: str):
        self.repo_dir = repo_dir
        self.agent_path = os.path.join(repo_dir, AGENT_FILE)

    # --- git plumbing ---

    def _git(self, *args: str) -> subprocess.CompletedProcess:
        result = subprocess.run(
            ["git", "-C", self.repo_dir, *args],
            capture_output=True, text=True,
        )
        if result.returncode != 0:
            raise ConfigRepoError(
                f"git {' '.join(args)} failed: {result.stderr.strip() or result.stdout.strip()}"
            )
        return result

    def _commit_count(self) -> int:
        # rev-list --count HEAD; 0 if no commits / no HEAD yet.
        r = subprocess.run(
            ["git", "-C", self.repo_dir, "rev-list", "--count", "HEAD"],
            capture_output=True, text=True,
        )
        if r.returncode != 0:
            return 0
        try:
            return int(r.stdout.strip())
        except ValueError:
            return 0

    # --- lifecycle ---

    def ensure(self) -> None:
        """Idempotent: create the repo + scaffold commit if absent.
        Also resets any leftover staging so a prior interrupted commit
        doesn't poison the next one."""
        if not os.path.isdir(os.path.join(self.repo_dir, ".git")):
            os.makedirs(self.repo_dir, exist_ok=True)
            self._git("init", "-q")
            with open(self.agent_path, "w") as f:
                f.write(_render(""))
            self._git("add", AGENT_FILE)
            self._git(*_GIT_IDENTITY, "commit", "-q", "-m", "scaffold: empty agent config")
            log.info("Initialized config repo at %s", self.repo_dir)
        else:
            # Idempotent recovery: drop any staged-but-uncommitted state
            # so a later commit starts clean.
            subprocess.run(
                ["git", "-C", self.repo_dir, "reset", "-q"],
                capture_output=True, text=True,
            )

    def write_and_commit(self, body: str, summary: str) -> str:
        """Replace agent.el's body, commit, return the commit sha."""
        self.ensure()
        with open(self.agent_path, "w") as f:
            f.write(_render(body))
        self._git("add", AGENT_FILE)
        # Allow an empty diff to no-op gracefully (re-applying identical
        # config shouldn't error); --allow-empty keeps a version marker.
        self._git(*_GIT_IDENTITY, "commit", "-q", "--allow-empty", "-m", summary)
        return self._git("rev-parse", "HEAD").stdout.strip()

    def current(self) -> ConfigVersion:
        self.ensure()
        sha = self._git("rev-parse", "HEAD").stdout.strip()
        summary = self._git("log", "-1", "--format=%s").stdout.strip()
        with open(self.agent_path) as f:
            body = _extract_body(f.read())
        return ConfigVersion(sha=sha, summary=summary, body=body)

    def rollback(self) -> RollbackResult:
        """Revert the last apply (a NEW commit, so roll-forward stays
        possible).  Returns the new HEAD's version to re-apply."""
        self.ensure()
        # Need at least scaffold + one real apply to have something to
        # undo.  rev-list count: 1 == scaffold only.
        if self._commit_count() < 2:
            return RollbackResult(ok=False, detail="nothing to roll back (no config applied yet)")
        self._git(*_GIT_IDENTITY, "revert", "--no-edit", "HEAD")
        return RollbackResult(ok=True, detail="reverted last apply", version=self.current())

    def history(self, limit: int = 20) -> list[ConfigVersion]:
        """Recent versions, newest first (thin; underpins a future
        history-view affordance)."""
        self.ensure()
        out = self._git(
            "log", f"-{limit}", "--format=%H%x1f%s"
        ).stdout.strip()
        versions = []
        for line in out.splitlines():
            if "\x1f" not in line:
                continue
            sha, summary = line.split("\x1f", 1)
            versions.append(ConfigVersion(sha=sha, summary=summary, body=""))
        return versions
