"""Unit tests for env-var config loading."""
from __future__ import annotations

import pytest

from emacsos_server.config import Config, ConfigError


def test_default_port(monkeypatch):
    monkeypatch.delenv("EMACSOS_SERVER_PORT", raising=False)
    assert Config.from_env().port == 8765


def test_custom_port(monkeypatch):
    monkeypatch.setenv("EMACSOS_SERVER_PORT", "12345")
    assert Config.from_env().port == 12345


def test_default_config_dir_under_home(monkeypatch):
    monkeypatch.delenv("EMACSOS_CONFIG_DIR", raising=False)
    cd = Config.from_env().config_dir
    # Default is computed from $HOME, never a literal path in source.
    assert cd.endswith("/.config/emacsos/config-repo")


def test_custom_config_dir(monkeypatch):
    monkeypatch.setenv("EMACSOS_CONFIG_DIR", "/tmp/my-config-repo")
    assert Config.from_env().config_dir == "/tmp/my-config-repo"


def test_default_state_dir_under_home(monkeypatch):
    monkeypatch.delenv("EMACSOS_STATE_DIR", raising=False)
    sd = Config.from_env().state_dir
    # Default is computed from $HOME (XDG state), never a literal path.
    assert sd.endswith("/.local/state/emacsos")


def test_custom_state_dir(monkeypatch):
    monkeypatch.setenv("EMACSOS_STATE_DIR", "/tmp/my-state")
    assert Config.from_env().state_dir == "/tmp/my-state"


def test_non_numeric_port_raises_with_clear_message(monkeypatch):
    monkeypatch.setenv("EMACSOS_SERVER_PORT", "not-a-number")
    with pytest.raises(ConfigError) as ex:
        Config.from_env()
    assert "must be an integer" in str(ex.value)


def test_port_out_of_range_raises(monkeypatch):
    monkeypatch.setenv("EMACSOS_SERVER_PORT", "999999")
    with pytest.raises(ConfigError) as ex:
        Config.from_env()
    assert "out of range" in str(ex.value)


def test_port_zero_rejected(monkeypatch):
    monkeypatch.setenv("EMACSOS_SERVER_PORT", "0")
    with pytest.raises(ConfigError):
        Config.from_env()
