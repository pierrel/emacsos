"""Server configuration loaded from environment variables."""
from __future__ import annotations

import os
from dataclasses import dataclass


class ConfigError(SystemExit):
    """Raised on startup when env-var config is invalid.

    Inherits SystemExit so an uncaught instance terminates uvicorn with
    a clean, single-line error instead of a traceback.
    """


@dataclass(frozen=True)
class Config:
    port: int
    emacsclient: str
    config_dir: str
    state_dir: str

    @classmethod
    def from_env(cls) -> "Config":
        raw_port = os.environ.get("EMACSOS_SERVER_PORT", "8765")
        try:
            port = int(raw_port)
        except ValueError:
            raise ConfigError(
                f"EMACSOS_SERVER_PORT must be an integer; got {raw_port!r}"
            )
        if not 1 <= port <= 65535:
            raise ConfigError(
                f"EMACSOS_SERVER_PORT out of range (1..65535): {port}"
            )
        # The git-backed config repo emacsos-server owns (one agent.el).
        # Default computed at runtime from $HOME so no literal operator
        # path lands in source (CLAUDE.md no-real-local-paths rule).
        default_config_dir = os.path.join(
            os.path.expanduser("~"), ".config", "emacsos", "config-repo"
        )
        # Persistent conversation state (the threads.db checkpointer + the
        # per-conversation working dir).  XDG state dir by default, computed
        # at runtime from $HOME so no literal operator path lands in source.
        default_state_dir = os.path.join(
            os.path.expanduser("~"), ".local", "state", "emacsos"
        )
        return cls(
            port=port,
            emacsclient=os.environ.get("EMACSOS_EMACSCLIENT", "emacsclient"),
            config_dir=os.environ.get("EMACSOS_CONFIG_DIR", default_config_dir),
            state_dir=os.environ.get("EMACSOS_STATE_DIR", default_state_dir),
        )
