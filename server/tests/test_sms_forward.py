"""Synthetic journal-to-archive handoff and exact-send transport regressions."""
from types import SimpleNamespace
import json
import requests
import pytest
from emacsos_server import sms_forward as sf


def receipt(**values):
    return {'id': 'physical1', 'direction': 'incoming', 'number': '+15555550100',
            'text': '  exact "quote"\nline 👋  ', 'status': 'received',
            'occurred_at': '2026-10-24T20:00:00+00:00', **values}


@pytest.mark.parametrize('code,accepted', [(503, False), (400, False), (401, False), (200, True)])
def test_handoff_ack_only_after_server_durable_success(monkeypatch, code, accepted):
    row = receipt(); calls = []; posts = []
    def helper(payload, timeout=70):
        calls.append(payload)
        return SimpleNamespace(stdout=json.dumps({'receipts': [row]}))
    monkeypatch.setattr(sf, 'helper', helper)
    monkeypatch.setattr(sf, 'INBOUND_URL', 'https://server.invalid/inbound/sms')
    def post(url, **kwargs):
        posts.append((url, kwargs)); return SimpleNamespace(status_code=code, json=lambda: {'status': 'accepted'})
    monkeypatch.setattr(sf.requests, 'post', post)
    sf.sync_once()
    assert (len(calls) == 2) is accepted
    assert posts[0][1]['json']['text'] == row['text']
    assert posts[0][1]['allow_redirects'] is False
    if accepted:
        assert calls[1] == {'operation': 'ack', 'message_id': 'physical1', 'status': 'received'}


def test_outgoing_sync_never_calls_send_and_retries_same_receipt(monkeypatch):
    row = receipt(direction='outgoing', status='sent'); calls = []; posts = []
    monkeypatch.setattr(sf, 'helper', lambda payload, **kwargs: calls.append(payload) or SimpleNamespace(stdout=json.dumps({'receipts': [row]})))
    monkeypatch.setattr(sf, 'INBOUND_URL', 'https://server.invalid/inbound/sms')
    def lost(url, **kwargs):
        posts.append((url, kwargs['json'])); raise requests.Timeout('lost archive acknowledgment')
    monkeypatch.setattr(sf.requests, 'post', lost)
    for _ in range(2):
        with pytest.raises(requests.Timeout): sf.sync_once()
    assert [p[0] for p in posts] == ['https://server.invalid/sms/receipts'] * 2
    assert posts[0][1] == posts[1][1]
    assert calls == [{'operation': 'receipts'}] * 2


def test_send_preserves_exact_body_and_attempt_id(monkeypatch):
    sent = []
    monkeypatch.setattr(sf, 'helper', lambda payload, **kwargs: sent.append(payload) or SimpleNamespace(stdout='sent\n', returncode=0))
    assert sf.send_sms('+15555550100', '  exact "quote"\n👋 ', 'attempt1', '2026-10-24T20:00:00+00:00') == 'sent'
    assert sent == [{'number': '+15555550100', 'text': '  exact "quote"\n👋 ', 'message_id': 'attempt1', 'occurred_at': '2026-10-24T20:00:00+00:00'}]


@pytest.mark.parametrize('stdout,code,status', [('unknown:time-limit\n',1,'unknown'), ('not-sent:no-service\n',1,'not_sent'), ('garbage\n',0,'unknown'), ('sent\n',1,'unknown')])
def test_send_outcomes_are_conservative(monkeypatch, stdout, code, status):
    monkeypatch.setattr(sf, 'helper', lambda *args, **kwargs: SimpleNamespace(stdout=stdout, returncode=code))
    assert sf.send_sms('+15555550100', 'hi', 'attempt1', None) == status


def test_bind_not_ready_retries_without_dropping_receipts(monkeypatch):
    states = []; attempts = []
    class Serving(Exception): pass
    class Server:
        def __enter__(self): return self
        def __exit__(self, *args): pass
        def serve_forever(self): raise Serving()
    def server(*args):
        attempts.append(1)
        if len(attempts) == 1: raise OSError('interface not yet present')
        return Server()
    monkeypatch.setattr(sf, 'HTTPServer', server)
    monkeypatch.setattr(sf, 'publish_transport_state', states.append)
    monkeypatch.setattr(sf.time, 'sleep', lambda seconds: None)
    with pytest.raises(Serving): sf.serve()
    assert len(attempts) == 2
    assert 'waiting' in states[0] and 'running' in states[1]


def test_trickled_bytes_do_not_extend_absolute_request_deadline(monkeypatch):
    import io
    clock = iter([0.0, 4.0, 8.0, 12.0])
    monkeypatch.setattr(sf.time, 'monotonic', lambda: next(clock))
    timeouts = []
    class Raw(io.RawIOBase):
        def readinto(self, buffer): buffer[0] = ord('x'); return 1
    reader = sf._DeadlineReader(Raw(), SimpleNamespace(settimeout=timeouts.append), 10.0)
    stream = io.BufferedReader(reader, buffer_size=2)
    with pytest.raises(TimeoutError): stream.readline(100)
    assert timeouts == [10.0, 6.0, 2.0]


@pytest.mark.parametrize('address', ['::1', 'fd00::1'])
def test_ipv6_config_is_rejected_instead_of_endless_af_inet_bind(tmp_path, monkeypatch, address):
    path = tmp_path/'sms.json'
    path.write_text(json.dumps({'secret':'synthetic', 'inbound_url':'https://server.invalid/inbound/sms', 'bind':address, 'port':8767, 'ca':'/synthetic/ca.pem'}))
    path.chmod(0o600)
    monkeypatch.setattr(sf, 'Path', lambda value: path)
    with pytest.raises(ValueError, match='IPv4'): sf.load_phone_config()
