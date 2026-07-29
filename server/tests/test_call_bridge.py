"""Deterministic tests for the phone-side voice PCM core."""
from __future__ import annotations

import asyncio
import json

import pytest

from emacsos_server.call_bridge import (
    FRAME_BYTES, SILENCE, BridgeSession, DownlinkQueue, JitterBuffer, PcmPump,
    RingWatcher, SerialCallControl, VoiceConfig, WsLink,
)


class FakeModem:
    def __init__(self, frames: list[bytes]) -> None:
        self.frames = iter(frames)
        self.written: list[bytes] = []

    def read_frame(self) -> bytes:
        return next(self.frames)

    def write_frame(self, frame: bytes) -> None:
        self.written.append(frame)


def test_pump_reads_then_writes_one_exact_frame_with_silence_on_underrun():
    downlink = DownlinkQueue()
    modem = FakeModem([b"d" * FRAME_BYTES])
    pump = PcmPump(modem, JitterBuffer(), downlink)

    pump.run_once()

    assert downlink.get() == b"d" * FRAME_BYTES
    assert modem.written == [SILENCE]
    assert pump.stats.frames == 1
    assert pump.stats.underruns == 1


def test_pump_uses_tts_then_flushes_it_without_changing_modem_cadence():
    uplink = JitterBuffer()
    tts = b"t" * FRAME_BYTES
    uplink.push(tts)
    modem = FakeModem([b"a" * FRAME_BYTES, b"b" * FRAME_BYTES])
    pump = PcmPump(modem, uplink, DownlinkQueue())

    pump.run_once()
    uplink.clear()                         # server flush_uplink
    pump.run_once()

    assert modem.written == [tts, SILENCE]
    assert pump.stats == pump.stats.__class__(frames=2, underruns=1)


@pytest.mark.parametrize("frame", [b"", b"x" * (FRAME_BYTES - 1)])
def test_bad_frame_is_rejected_before_any_modem_write(frame):
    modem = FakeModem([frame])
    pump = PcmPump(modem, JitterBuffer(), DownlinkQueue())

    with pytest.raises(ValueError, match="640"):
        pump.run_once()
    assert modem.written == []


def test_jitter_buffer_drops_oldest_tts_at_its_fixed_bound():
    buffer = JitterBuffer(depth=2)
    buffer.push(b"1" * FRAME_BYTES)
    buffer.push(b"2" * FRAME_BYTES)
    buffer.push(b"3" * FRAME_BYTES)

    assert buffer.pop() == b"2" * FRAME_BYTES
    assert buffer.pop() == b"3" * FRAME_BYTES


def test_voice_config_requires_wss_and_a_secret():
    with pytest.raises(ValueError, match="wss"):
        VoiceConfig.from_environ({"ASSIST_VOICE_URL": "ws://assist/call", "ASSIST_VOICE_SECRET": "s"})
    with pytest.raises(ValueError, match="SECRET"):
        VoiceConfig.from_environ({"ASSIST_VOICE_URL": "wss://assist/call"})
    assert VoiceConfig.from_environ({
        "ASSIST_VOICE_URL": "wss://assist/call", "ASSIST_VOICE_SECRET": "s",
    }).url == "wss://assist/call"


def test_session_never_answers_when_server_hangs_up_at_ring():
    class Control:
        def answer(self):
            raise AssertionError("bridge must wait for server answer")

        def start_pcm(self):
            raise AssertionError("bridge must not start PCM")

        def stop_pcm(self):
            raise AssertionError("bridge must not stop PCM")

        def hangup(self):
            raise AssertionError("server declined before bridge ownership")

        def close(self):
            closed.append(True)

    class Link:
        def __init__(self):
            import queue
            self.events = queue.Queue()
            self.events.put({"type": "hangup"})
            self.opened = self.closed = False

        def open(self, call_id, caller):
            self.opened = (call_id, caller)

        def controls(self):
            return self.events

        def run_receiver(self):
            pass

        def run_sender(self):
            pass

        def close(self, cause):
            self.closed = cause

    closed = []
    link = Link()
    session = BridgeSession(Control(), link, JitterBuffer(), DownlinkQueue())

    assert session.run("call-1", "+15555550100") == "server"
    assert link.opened == ("call-1", "+15555550100")
    assert link.closed == "server"
    assert closed == [True]


def test_session_notifies_assist_only_after_modem_audio_is_ready():
    class Control:
        def __init__(self):
            self.calls = []

        def answer(self):
            self.calls.append("answer")

        def start_pcm(self):
            self.calls.append("start_pcm")
            return FakeModem([b"m" * FRAME_BYTES])

        def stop_pcm(self):
            self.calls.append("stop_pcm")

        def hangup(self):
            self.calls.append("hangup")

        def close(self):
            self.calls.append("close")

    class Link:
        def __init__(self):
            import queue
            self.events = queue.Queue()
            self.events.put({"type": "answer"})
            self.answered_call = None

        def open(self, call_id, caller):
            pass

        def answered(self, call_id):
            self.answered_call = call_id
            self.events.put({"type": "hangup"})

        def controls(self):
            return self.events

        def run_receiver(self):
            pass

        def run_sender(self):
            pass

        def close(self, cause):
            pass

    control, link = Control(), Link()

    assert BridgeSession(control, link, JitterBuffer(), DownlinkQueue()).run(
        "call-1", "+15555550100") == "server"
    assert link.answered_call == "call-1"
    assert control.calls == ["answer", "start_pcm", "stop_pcm", "hangup", "close"]


def test_pump_failure_requests_session_hangup():
    class FailingModem:
        def read_frame(self):
            raise RuntimeError("lost PCM")

        def write_frame(self, frame):
            raise AssertionError("no uplink write after a failed read")

    failed = []
    PcmPump(FailingModem(), JitterBuffer(), DownlinkQueue(),
            lambda: failed.append(True)).run()

    assert failed == [True]


def test_link_sends_answered_after_the_server_admits_the_call():
    class Socket:
        def __init__(self):
            self.sent = []

        def send(self, message):
            self.sent.append(message)

        def recv(self):
            raise AssertionError("receiver is not part of this contract")

        def close(self):
            pass

    socket = Socket()
    config = VoiceConfig("wss://assist/call", "secret")
    link = WsLink(config, JitterBuffer(), DownlinkQueue(), lambda _config: socket)

    link.open("call-1", "+15555550100")
    link.answered("call-1")
    link.close("remote")

    assert [json.loads(message) for message in socket.sent] == [
        {"type": "ring", "call_id": "call-1", "caller": "+15555550100"},
        {"type": "answered", "call_id": "call-1"},
        {"type": "call_end", "cause": "remote"},
    ]


def test_ring_watcher_ignores_a_second_call_before_dbus_io():
    class Variant:
        def __init__(self, value):
            self.value = value

    class Props:
        async def call_get_all(self, _interface):
            return {"Direction": Variant(1), "Number": Variant("+15555550100")}

    class Call:
        def get_interface(self, _name):
            return Props()

    class Bus:
        def __init__(self):
            self.started = asyncio.Event()
            self.release = asyncio.Event()
            self.introspections = 0

        async def introspect(self, _service, _path):
            self.introspections += 1
            self.started.set()
            await self.release.wait()
            return object()

        def get_proxy_object(self, _service, _path, _intro):
            return Call()

    async def exercise():
        watcher = RingWatcher(VoiceConfig("wss://assist/call", "secret"))
        sessions = []
        watcher._run_session = lambda *args: sessions.append(args[-2:])
        bus = Bus()
        first = asyncio.create_task(watcher._handle_call(bus, "/call/first"))
        await bus.started.wait()
        await watcher._handle_call(bus, "/call/second")
        bus.release.set()
        await first
        return bus.introspections, sessions

    introspections, sessions = asyncio.run(exercise())

    assert introspections == 1
    assert len(sessions) == 1


def test_session_continues_teardown_after_pcm_stop_failure():
    class Control:
        def __init__(self):
            self.calls = []

        def answer(self):
            self.calls.append("answer")

        def start_pcm(self):
            self.calls.append("start_pcm")
            return FakeModem([b"m" * FRAME_BYTES])

        def stop_pcm(self):
            self.calls.append("stop_pcm")
            raise RuntimeError("modem already ended")

        def hangup(self):
            self.calls.append("hangup")

        def close(self):
            self.calls.append("close")

    class Link:
        def __init__(self):
            import queue
            self.events = queue.Queue()
            self.events.put({"type": "answer"})
            self.closed = None

        def open(self, call_id, caller):
            pass

        def answered(self, call_id):
            self.events.put({"type": "hangup"})

        def controls(self):
            return self.events

        def run_receiver(self):
            pass

        def run_sender(self):
            pass

        def close(self, cause):
            self.closed = cause

    control, link = Control(), Link()

    BridgeSession(control, link, JitterBuffer(), DownlinkQueue()).run(
        "call-1", "+15555550100")

    assert control.calls == ["answer", "start_pcm", "stop_pcm", "hangup", "close"]
    assert link.closed == "server"


def test_session_hangs_up_cleanly_when_pcm_setup_fails():
    class Control:
        def __init__(self):
            self.calls = []

        def answer(self):
            self.calls.append("answer")

        def start_pcm(self):
            self.calls.append("start_pcm")
            raise RuntimeError("gain rejected")

        def stop_pcm(self):
            raise AssertionError("PCM never started")

        def hangup(self):
            self.calls.append("hangup")

        def close(self):
            self.calls.append("close")

    class Link:
        def __init__(self):
            import queue
            self.events = queue.Queue()
            self.events.put({"type": "answer"})
            self.closed = None

        def open(self, call_id, caller):
            pass

        def answered(self, call_id):
            raise AssertionError("Assist must not start PIN flow without PCM")

        def controls(self):
            return self.events

        def run_receiver(self):
            pass

        def run_sender(self):
            pass

        def close(self, cause):
            self.closed = cause

    control, link = Control(), Link()

    assert BridgeSession(control, link, JitterBuffer(), DownlinkQueue()).run(
        "call-1", "+15555550100") == "pcm_setup"
    assert control.calls == ["answer", "start_pcm", "hangup", "close"]
    assert link.closed == "pcm_setup"


def test_session_hangs_up_when_modem_answer_fails_after_server_admission():
    class Control:
        def __init__(self):
            self.calls = []

        def answer(self):
            self.calls.append("answer")
            raise RuntimeError("call never became active")

        def start_pcm(self):
            raise AssertionError("PCM must not start")

        def stop_pcm(self):
            raise AssertionError("PCM must not stop")

        def hangup(self):
            self.calls.append("hangup")

        def close(self):
            self.calls.append("close")

    class Link:
        def __init__(self):
            import queue
            self.events = queue.Queue()
            self.events.put({"type": "answer"})
            self.closed = None

        def open(self, call_id, caller):
            pass

        def controls(self):
            return self.events

        def run_receiver(self):
            pass

        def run_sender(self):
            pass

        def close(self, cause):
            self.closed = cause

    control, link = Control(), Link()

    with pytest.raises(RuntimeError, match="never became active"):
        BridgeSession(control, link, JitterBuffer(), DownlinkQueue()).run(
            "call-1", "+15555550100")
    assert control.calls == ["answer", "hangup", "close"]
    assert link.closed == "server"


def test_serial_control_owns_at_then_pcm_in_the_validated_order():
    class Port:
        def __init__(self, reads=()):
            self.reads = list(reads)
            self.writes = []
            self.closed = False

        def write(self, value):
            self.writes.append(value)

        def read(self, _size):
            return self.reads.pop(0) if self.reads else b""

        def close(self):
            self.closed = True

    at = Port([
        b"\r\nOK\r\n",
        b"\r\n+CLCC: 1,1,0,0,0\r\n\r\nOK\r\n",
        *[b"\r\nOK\r\n"] * 5,
    ])
    pcm = Port([b"p" * 100, b"p" * (FRAME_BYTES - 100)])
    ports = iter([at, pcm])
    control = SerialCallControl(serial_factory=lambda *args, **kwargs: next(ports))

    control.answer()
    audio = control.start_pcm()
    assert audio.read_frame() == b"p" * FRAME_BYTES
    audio.write_frame(SILENCE)
    control.stop_pcm()
    control.hangup()
    control.close()

    assert at.writes == [
        b"ATA\r", b"AT+CLCC\r", b"AT+CLVL=5\r", b"AT+COUTGAIN=8\r", b"AT+CPCMREG=1\r",
        b"AT+CPCMREG=0,1\r", b"AT+CHUP\r",
    ]
    assert pcm.writes == [SILENCE]
    assert at.closed and pcm.closed


def test_serial_control_disables_pcm_if_its_device_cannot_open():
    class Port:
        def __init__(self):
            self.writes = []

        def write(self, value):
            self.writes.append(value)

        def read(self, _size):
            return b"\r\nOK\r\n"

        def close(self):
            pass

    at = Port()
    calls = 0

    def serial_factory(*_args, **_kwargs):
        nonlocal calls
        calls += 1
        if calls == 1:
            return at
        raise OSError("ttyUSB4 unavailable")

    control = SerialCallControl(serial_factory=serial_factory)

    with pytest.raises(OSError, match="ttyUSB4"):
        control.start_pcm()

    assert at.writes == [
        b"AT+CLVL=5\r", b"AT+COUTGAIN=8\r", b"AT+CPCMREG=1\r",
        b"AT+CPCMREG=0,1\r",
    ]
