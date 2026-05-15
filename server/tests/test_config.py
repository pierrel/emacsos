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
