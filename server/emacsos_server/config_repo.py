"""Git-backed config repo emacsos-server owns end-to-end.

A single file =agent.el= lives in a git repo at ``config_dir``.  The
agent never touches git; the server commits each applied config and
navigates history for rollback.  The server applies FIRST and commits
only when the phone was reached, so HEAD-of-repo tracks what's actually
on the phone.  The one exception is a commit FAILURE after a successful
apply (`applied-but-unrecorded` in channel.py): the phone then has a
config git doesn't, and that change isn't rollback-able from history.

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

# Commit message of the empty-config bootstrap commit.  Not a user-applied
# version — config_history filters it out so the agent isn't offered "restore
# to the scaffold" as a version.
SCAFFOLD_SUMMARY = "scaffold: empty agent config"

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


def render(body: str) -> str:
    """The canonical agent.el file content for BODY: header (carrying the
    `lexical-binding: t` cookie) + body + `(provide 'agent)` footer.  This
    is the SINGLE source of the file the phone loads AND the file git
    commits — apply writes `render(body)` to the phone, git stores
    `render(body)`, so the two never diverge and the phone always loads
    with lexical-binding (closures behave as in the committed file)."""
    return _HEADER + body.strip("\n") + _FOOTER


def _extract_body(full: str) -> str:
    """Inverse of `render`: pull the agent body back out of agent.el."""
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
        """Idempotent: bring the repo to a clean, usable state.
        - No `.git`: init + scaffold the first commit.
        - `.git` but zero commits (manual `git init` / partial init):
          scaffold so `current()`/`rollback()` have a HEAD.
        - Otherwise: hard-reset index + working tree to HEAD.  This drops
          any staged or dirty state from a prior interrupted write — which
          would otherwise make `git revert` fail with "local changes would
          be overwritten" — and restores `agent.el` if it was deleted out
          of band.  The repo is server-owned; there's no legitimate
          uncommitted work between operations to lose."""
        if not os.path.isdir(os.path.join(self.repo_dir, ".git")):
            os.makedirs(self.repo_dir, exist_ok=True)
            self._git("init", "-q")
            self._scaffold()
            log.info("Initialized config repo at %s", self.repo_dir)
        elif self._commit_count() == 0:
            self._scaffold()
            log.warning("Scaffolded commit-less repo at %s", self.repo_dir)
        else:
            # Use _git (raises ConfigRepoError on failure) — a failed
            # hard reset means a genuinely broken repo, and the callers
            # (apply_config, _do_rollback) catch it into a structured
            # error rather than continuing on a partially-reset repo.
            self._git("reset", "--hard", "-q", "HEAD")
            # Defensive: a hard reset restores tracked files, so agent.el
            # is back unless HEAD genuinely lacks it (shouldn't happen
            # post-scaffold) — scaffold if so.
            if not os.path.isfile(self.agent_path):
                self._scaffold()
                log.warning("Recovered missing agent file in %s", self.repo_dir)

    def _scaffold(self) -> None:
        """Write the empty-config scaffold file and commit it."""
        with open(self.agent_path, "w") as f:
            f.write(render(""))
        self._git("add", AGENT_FILE)
        self._git(*_GIT_IDENTITY, "commit", "-q", "-m", SCAFFOLD_SUMMARY)

    def write_and_commit(self, body: str, summary: str) -> str:
        """Replace agent.el's body, commit, return the commit sha."""
        self.ensure()
        with open(self.agent_path, "w") as f:
            f.write(render(body))
        self._git("add", AGENT_FILE)
        # If the staged tree is identical to HEAD, do NOT create an empty
        # commit: an empty commit later breaks `git revert` ("revert is
        # now empty" aborts).  Re-applying an identical config is a clean
        # no-op — return the existing HEAD sha.
        no_diff = subprocess.run(
            ["git", "-C", self.repo_dir, "diff", "--cached", "--quiet"],
            capture_output=True,
        ).returncode == 0
        if not no_diff:
            self._git(*_GIT_IDENTITY, "commit", "-q", "-m", summary)
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

    def body_at(self, ref: str) -> str:
        """The agent body committed at REF (e.g. a sha from `history()`), with
        the header/footer stripped — ready to re-apply for a restore-to-version.
        Raises ConfigRepoError if REF is unknown or has no agent file there."""
        self.ensure()
        full = self._git("show", f"{ref}:{AGENT_FILE}").stdout
        return _extract_body(full)

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
