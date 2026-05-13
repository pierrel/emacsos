"""Server configuration loaded from environment variables."""
from __future__ import annotations

import os
from dataclasses import dataclass


@dataclass(frozen=True)
class Config:
    port: int
    emacsclient: str

    @classmethod
    def from_env(cls) -> "Config":
        return cls(
            port=int(os.environ.get("EMACSOS_SERVER_PORT", "8765")),
            emacsclient=os.environ.get("EMACSOS_EMACSCLIENT", "emacsclient"),
        )
