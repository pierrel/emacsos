"""Deterministic tests for the phone-side voice PCM core."""
from __future__ import annotations

import pytest

from emacsos_server.call_bridge import (
    FRAME_BYTES, SILENCE, BridgeSession, DownlinkQueue, JitterBuffer, PcmPump,
    SerialCallControl, VoiceConfig,
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

    link = Link()
    session = BridgeSession(Control(), link, JitterBuffer(), DownlinkQueue())

    assert session.run("call-1", "+15555550100") == "server"
    assert link.opened == ("call-1", "+15555550100")
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

    at = Port([b"\r\nOK\r\n"] * 6)
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
        b"ATA\r", b"AT+CLVL=5\r", b"AT+COUTGAIN=8\r", b"AT+CPCMREG=1\r",
        b"AT+CPCMREG=0,1\r", b"AT+CHUP\r",
    ]
    assert pcm.writes == [SILENCE]
    assert at.closed and pcm.closed
