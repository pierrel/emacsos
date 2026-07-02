"""Unit tests for the sms-forward bridge — the mmcli parse + the forward/delete-on-ack
logic, with mmcli and the HTTP POST mocked (no modem, no network)."""
from types import SimpleNamespace
from unittest import mock

import emacsos_server.sms_forward as sf


def _cp(stdout="", returncode=0, stderr=""):
    return SimpleNamespace(stdout=stdout, returncode=returncode, stderr=stderr)


def test_parse_sms_keyvalue():
    kv = sf.parse_sms(
        "  sms.content.number    : +15551234567\n"
        "  sms.content.text      : hey are you around?\n"
        "  sms.properties.state  : received\n")
    assert kv["sms.content.number"] == "+15551234567"
    assert kv["sms.content.text"] == "hey are you around?"
    assert kv["sms.properties.state"] == "received"


def test_message_id_stable_and_content_derived():
    a = sf.message_id("+1555", "2026-07-02T05:00:00", "hi")
    b = sf.message_id("+1555", "2026-07-02T05:00:00", "hi")
    c = sf.message_id("+1555", "2026-07-02T05:00:00", "different")
    assert a == b and a != c and len(a) == 64


def test_forward_deletes_on_200(monkeypatch):
    monkeypatch.setattr(sf, "SECRET", "s")
    monkeypatch.setattr(sf, "INBOUND_URL", "http://assist/inbound/sms")
    monkeypatch.setattr(sf, "read_sms", lambda idx: {
        "sms.content.number": "+1555", "sms.content.text": "hi",
        "sms.properties.timestamp": "t", "sms.properties.state": "received"})
    deleted = []
    monkeypatch.setattr(sf, "delete_sms", lambda modem, idx: deleted.append(idx))
    monkeypatch.setattr(sf.requests, "post", lambda *a, **k: SimpleNamespace(status_code=200))
    sf._forward_one("0", "7")
    assert deleted == ["7"]                 # accepted -> deleted


def test_forward_retains_on_503(monkeypatch):
    monkeypatch.setattr(sf, "SECRET", "s")
    monkeypatch.setattr(sf, "INBOUND_URL", "http://assist/inbound/sms")
    monkeypatch.setattr(sf, "read_sms", lambda idx: {
        "sms.content.number": "+1555", "sms.content.text": "hi",
        "sms.properties.state": "received"})
    deleted = []
    monkeypatch.setattr(sf, "delete_sms", lambda modem, idx: deleted.append(idx))
    monkeypatch.setattr(sf.requests, "post", lambda *a, **k: SimpleNamespace(status_code=503))
    sf._forward_one("0", "7")
    assert deleted == []                    # transient -> retained for retry


def test_forward_skips_and_deletes_empty_poison(monkeypatch):
    monkeypatch.setattr(sf, "SECRET", "s")
    monkeypatch.setattr(sf, "INBOUND_URL", "http://assist/inbound/sms")
    monkeypatch.setattr(sf, "read_sms", lambda idx: {"sms.properties.state": "received"})  # no text
    deleted, posted = [], []
    monkeypatch.setattr(sf, "delete_sms", lambda modem, idx: deleted.append(idx))
    monkeypatch.setattr(sf.requests, "post", lambda *a, **k: posted.append(1))
    sf._forward_one("0", "9")
    assert deleted == ["9"] and posted == []  # poison record deleted, never POSTed


def test_forward_ignores_our_sent_records(monkeypatch):
    monkeypatch.setattr(sf, "read_sms", lambda idx: {
        "sms.content.number": "+1555", "sms.content.text": "our reply",
        "sms.properties.state": "sent"})
    deleted, posted = [], []
    monkeypatch.setattr(sf, "delete_sms", lambda modem, idx: deleted.append(idx))
    monkeypatch.setattr(sf.requests, "post", lambda *a, **k: posted.append(1))
    sf._forward_one("0", "3")
    assert posted == [] and deleted == []     # a sent record is left alone


def test_forward_retains_on_read_failure(monkeypatch):
    monkeypatch.setattr(sf, "SECRET", "s")
    monkeypatch.setattr(sf, "INBOUND_URL", "http://assist/inbound/sms")
    monkeypatch.setattr(sf, "read_sms", lambda idx: None)   # transient mmcli read failure
    deleted, posted = [], []
    monkeypatch.setattr(sf, "delete_sms", lambda modem, idx: deleted.append(idx))
    monkeypatch.setattr(sf.requests, "post", lambda *a, **k: posted.append(1))
    sf._forward_one("0", "5")
    assert deleted == [] and posted == []       # not read → retained, never posted or deleted


def test_read_sms_returns_none_on_mmcli_failure(monkeypatch):
    monkeypatch.setattr(sf, "_mmcli", lambda *a, **k: _cp(stdout="", returncode=1))
    assert sf.read_sms("3") is None             # nonzero rc / empty -> None (transient)


def test_forward_deletes_on_any_2xx(monkeypatch):
    monkeypatch.setattr(sf, "SECRET", "s")
    monkeypatch.setattr(sf, "INBOUND_URL", "http://assist/inbound/sms")
    monkeypatch.setattr(sf, "read_sms", lambda idx: {
        "sms.content.number": "+1555", "sms.content.text": "hi", "sms.properties.state": "received"})
    deleted = []
    monkeypatch.setattr(sf, "delete_sms", lambda modem, idx: deleted.append(idx))
    monkeypatch.setattr(sf.requests, "post", lambda *a, **k: SimpleNamespace(status_code=204))
    sf._forward_one("0", "7")
    assert deleted == ["7"]                     # 204 (a 2xx) acks -> delete, not retry-forever
