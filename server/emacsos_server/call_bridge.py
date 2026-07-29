"""Phone-side, modem-clocked PCM bridge for Assist voice calls.

The bridge deliberately contains no speech or conversation logic.  Its one
load-bearing operation reads a frame from the SIM7600 and immediately writes a
same-sized uplink frame, using silence when Assist has no TTS ready.  Keeping
that operation in one thread prevents the modem's full-duplex serial PCM from
desynchronising.
"""
from __future__ import annotations

from collections import deque
from dataclasses import dataclass
import asyncio
import json
import logging
import os
import queue
import re
import threading
import time
import uuid
from typing import Any, Callable, Protocol


SAMPLES_PER_FRAME = 320
FRAME_BYTES = SAMPLES_PER_FRAME * 2
SILENCE = b"\0" * FRAME_BYTES
UPLINK_DEPTH = 12
DOWNLINK_DEPTH = 12
logger = logging.getLogger(__name__)
_ACTIVE_CALL = re.compile(rb"^\+CLCC:\s*\d+\s*,\s*\d+\s*,\s*0\s*,", re.MULTILINE)


class ModemAudio(Protocol):
    """The exact-frame serial PCM surface owned by one bridge session."""

    def read_frame(self) -> bytes: ...

    def write_frame(self, frame: bytes) -> None: ...


@dataclass(frozen=True)
class VoiceConfig:
    """The bridge's two non-device inputs, deliberately loaded at startup."""

    url: str
    secret: str

    @classmethod
    def from_environ(cls, environ: dict[str, str] | None = None) -> "VoiceConfig":
        values = os.environ if environ is None else environ
        url = values.get("ASSIST_VOICE_URL", "")
        secret = values.get("ASSIST_VOICE_SECRET", "")
        if not url.startswith("wss://"):
            raise ValueError("ASSIST_VOICE_URL must use wss://")
        if not secret:
            raise ValueError("ASSIST_VOICE_SECRET is required")
        return cls(url, secret)


class WebSocket(Protocol):
    """The tiny synchronous surface used by the bridge transport."""

    def send(self, message: str | bytes) -> None: ...

    def recv(self) -> str | bytes: ...

    def close(self) -> None: ...


class CallControl(Protocol):
    """The raw-AT operations that have authority over one answered call."""

    def answer(self) -> None: ...

    def start_pcm(self) -> ModemAudio: ...

    def stop_pcm(self) -> None: ...

    def hangup(self) -> None: ...

    def close(self) -> None: ...


class SerialCallControl:
    """SIM7600 raw-AT control plus its exact-frame serial PCM endpoint."""

    def __init__(self, at_path: str = "/dev/ttyUSB3",
                 pcm_path: str = "/dev/ttyUSB4",
                 serial_factory: Callable[..., Any] | None = None) -> None:
        if serial_factory is None:
            from serial import Serial
            serial_factory = Serial
        self._serial_factory = serial_factory
        self._at = serial_factory(at_path, 115200, timeout=0.1,
                                  write_timeout=1, exclusive=True)
        self._pcm_path = pcm_path
        self._pcm: Any | None = None

    def _command(self, command: str, timeout: float = 2) -> bytes:
        self._at.write((command + "\r").encode("ascii"))
        deadline = time.monotonic() + timeout
        response = bytearray()
        while time.monotonic() < deadline and len(response) < 4096:
            response.extend(self._at.read(256))
            if b"\r\nOK\r\n" in response:
                return bytes(response)
            if b"\r\nERROR\r\n" in response:
                break
        raise RuntimeError(f"SIM7600 rejected {command}")

    def answer(self) -> None:
        self._command("ATA")
        deadline = time.monotonic() + 3
        while time.monotonic() < deadline:
            response = self._command("AT+CLCC", timeout=0.5)
            if _ACTIVE_CALL.search(response):
                return
            time.sleep(0.05)
        raise RuntimeError("SIM7600 did not activate answered call")

    def start_pcm(self) -> ModemAudio:
        self._command("AT+CLVL=5")
        self._command("AT+COUTGAIN=8")
        self._command("AT+CPCMREG=1")
        try:
            self._pcm = self._serial_factory(
                self._pcm_path, 115200, timeout=None, write_timeout=1,
                exclusive=True)
        except Exception:
            self._command("AT+CPCMREG=0,1")
            raise
        return self

    def read_frame(self) -> bytes:
        assert self._pcm is not None
        frame = bytearray()
        while len(frame) < FRAME_BYTES:
            chunk = self._pcm.read(FRAME_BYTES - len(frame))
            if not chunk:
                raise RuntimeError("SIM7600 PCM stream ended")
            frame.extend(chunk)
        return bytes(frame)

    def write_frame(self, frame: bytes) -> None:
        assert self._pcm is not None
        self._pcm.write(frame)

    def stop_pcm(self) -> None:
        if self._pcm is not None:
            self._pcm.close()
            self._pcm = None
        self._command("AT+CPCMREG=0,1")

    def hangup(self) -> None:
        self._command("AT+CHUP")

    def close(self) -> None:
        if self._pcm is not None:
            self._pcm.close()
        self._at.close()


class JitterBuffer:
    """Small bounded queue of server TTS frames; underruns become silence."""

    def __init__(self, depth: int = UPLINK_DEPTH) -> None:
        self._depth = depth
        self._frames: deque[bytes] = deque()
        self._lock = threading.Lock()

    def push(self, frame: bytes) -> None:
        if len(frame) != FRAME_BYTES:
            raise ValueError("TTS frame must be exactly 640 bytes")
        with self._lock:
            if len(self._frames) == self._depth:
                self._frames.popleft()
            self._frames.append(frame)

    def pop(self) -> bytes:
        with self._lock:
            return self._frames.popleft() if self._frames else SILENCE

    def clear(self) -> None:
        with self._lock:
            self._frames.clear()


class DownlinkQueue:
    """Bounded pump-to-WebSocket queue that cannot stall modem PCM."""

    def __init__(self, depth: int = DOWNLINK_DEPTH) -> None:
        self._frames: queue.Queue[bytes] = queue.Queue(depth)

    def put(self, frame: bytes) -> None:
        if len(frame) != FRAME_BYTES:
            raise ValueError("modem frame must be exactly 640 bytes")
        try:
            self._frames.put_nowait(frame)
        except queue.Full:
            try:
                self._frames.get_nowait()
            except queue.Empty:  # another consumer won the race
                pass
            self._frames.put_nowait(frame)

    def get(self, timeout: float | None = None) -> bytes:
        return self._frames.get(timeout=timeout)


@dataclass(frozen=True)
class PumpStats:
    """Monotonic counters emitted by the bridge at the call boundary."""

    frames: int = 0
    underruns: int = 0


class PcmPump:
    """Read one modem frame, queue it, then immediately write one uplink frame."""

    def __init__(self, modem: ModemAudio, uplink: JitterBuffer,
                 downlink: DownlinkQueue,
                 on_failure: Callable[[], None] | None = None) -> None:
        self._modem = modem
        self._uplink = uplink
        self._downlink = downlink
        self._on_failure = on_failure
        self._stopped = threading.Event()
        self._stats = PumpStats()

    @property
    def stats(self) -> PumpStats:
        return self._stats

    def stop(self) -> None:
        self._stopped.set()

    def run_once(self) -> None:
        """Perform the only valid modem PCM cadence step."""
        frame = self._modem.read_frame()
        if len(frame) != FRAME_BYTES:
            raise ValueError("SIM7600 PCM frame must be exactly 640 bytes")
        self._downlink.put(frame)
        uplink = self._uplink.pop()
        self._modem.write_frame(uplink)
        self._stats = PumpStats(
            frames=self._stats.frames + 1,
            underruns=self._stats.underruns + (uplink == SILENCE),
        )

    def run(self) -> None:
        try:
            while not self._stopped.is_set():
                self.run_once()
        except Exception:
            logger.exception("SIM7600 PCM pump failed")
            if self._on_failure is not None:
                self._on_failure()


class WsLink:
    """Per-call WSS transport that keeps network backpressure off the pump."""

    def __init__(self, config: VoiceConfig, uplink: JitterBuffer,
                 downlink: DownlinkQueue,
                 connect: Callable[[VoiceConfig], WebSocket] | None = None) -> None:
        self._config = config
        self._uplink = uplink
        self._downlink = downlink
        self._connect = connect or self._default_connect
        self._socket: WebSocket | None = None
        self._controls: queue.Queue[dict[str, Any]] = queue.Queue()
        self._stopped = threading.Event()

    @staticmethod
    def _default_connect(config: VoiceConfig) -> WebSocket:
        from websockets.sync.client import connect

        return connect(config.url, additional_headers={
            "Authorization": f"Bearer {config.secret}",
        }, max_size=4096)

    def open(self, call_id: str, caller: str) -> None:
        self._socket = self._connect(self._config)
        self._send_control({"type": "ring", "call_id": call_id, "caller": caller})

    def answered(self, call_id: str) -> None:
        self._send_control({"type": "answered", "call_id": call_id})

    def _send_control(self, control: dict[str, Any]) -> None:
        assert self._socket is not None
        self._socket.send(json.dumps(control, separators=(",", ":")))

    def controls(self) -> queue.Queue[dict[str, Any]]:
        return self._controls

    def run_receiver(self) -> None:
        """Receive server control/TTS; this is the only producer of uplink audio."""
        assert self._socket is not None
        try:
            while not self._stopped.is_set():
                message = self._socket.recv()
                if isinstance(message, bytes):
                    self._uplink.push(message)
                    continue
                try:
                    control = json.loads(message)
                except json.JSONDecodeError:
                    continue
                if type(control) is dict and type(control.get("type")) is str:
                    if control["type"] == "flush_uplink":
                        self._uplink.clear()
                    elif control["type"] in {"answer", "hangup"}:
                        self._controls.put(control)
        except Exception:
            self._controls.put({"type": "hangup"})

    def run_sender(self) -> None:
        """Drain modem audio separately so a stalled WSS write cannot block PCM."""
        assert self._socket is not None
        try:
            while not self._stopped.is_set():
                try:
                    frame = self._downlink.get(timeout=0.1)
                except queue.Empty:
                    continue
                self._socket.send(frame)
        except Exception:
            self._controls.put({"type": "hangup"})

    def close(self, cause: str) -> None:
        if self._socket is None:
            return
        try:
            self._send_control({"type": "call_end", "cause": cause})
        except Exception:
            logger.debug("WSS call_end failed", exc_info=True)
        finally:
            self._stopped.set()
            try:
                self._socket.close()
            except Exception:
                logger.debug("WSS close failed", exc_info=True)


class BridgeSession:
    """One inbound call's control ordering, independent of serial/D-Bus details."""

    def __init__(self, control: CallControl, link: WsLink,
                 uplink: JitterBuffer, downlink: DownlinkQueue) -> None:
        self._control = control
        self._link = link
        self._uplink = uplink
        self._downlink = downlink

    def run(self, call_id: str, caller: str) -> str:
        """Wait for server admission, then run the balanced pump until hangup."""
        self._link.open(call_id, caller)
        receiver = threading.Thread(target=self._link.run_receiver, daemon=True)
        sender = threading.Thread(target=self._link.run_sender, daemon=True)
        receiver.start()
        sender.start()
        pump: PcmPump | None = None
        pump_thread: threading.Thread | None = None
        answered = False
        pcm_started = False
        cause = "server"
        try:
            while True:
                control = self._link.controls().get()
                if control["type"] == "hangup":
                    return cause
                answered = True
                self._control.answer()
                try:
                    pump = PcmPump(
                        self._control.start_pcm(), self._uplink, self._downlink,
                        lambda: self._link.controls().put({"type": "hangup"}),
                    )
                    pcm_started = True
                except Exception:
                    cause = "pcm_setup"
                    logger.exception("SIM7600 PCM setup failed")
                    return cause
                pump_thread = threading.Thread(target=pump.run, daemon=True)
                pump_thread.start()
                self._link.answered(call_id)
                break
            while True:
                control = self._link.controls().get()
                if control["type"] == "hangup":
                    return cause
        finally:
            if pump is not None:
                pump.stop()
            if pump_thread is not None:
                pump_thread.join(timeout=2)
            try:
                if pcm_started:
                    try:
                        self._control.stop_pcm()
                    except Exception:
                        logger.exception("SIM7600 PCM stop failed")
                if answered:
                    try:
                        self._control.hangup()
                    except Exception:
                        logger.exception("SIM7600 hangup failed")
            finally:
                try:
                    self._control.close()
                except Exception:
                    logger.exception("SIM7600 close failed")
                self._link.close(cause)


class RingWatcher:
    """ModemManager's incoming-call signal, with one bridge session at a time."""

    def __init__(self, config: VoiceConfig,
                 control_factory: Callable[[], CallControl] = SerialCallControl) -> None:
        self._config = config
        self._control_factory = control_factory
        self._active = asyncio.Lock()
        self._boot_id = uuid.uuid4().hex
        self._calls = 0

    async def _handle_call(self, bus: Any, path: str) -> None:
        if self._active.locked():
            logger.warning("ignoring second incoming call while bridge is active")
            return
        async with self._active:
            intro = await bus.introspect("org.freedesktop.ModemManager1", path)
            call = bus.get_proxy_object("org.freedesktop.ModemManager1", path, intro)
            props = call.get_interface("org.freedesktop.DBus.Properties")
            values = await props.call_get_all("org.freedesktop.ModemManager1.Call")
            direction = values.get("Direction")
            number = values.get("Number")
            # ModemManager's MMCallDirection is 1 for incoming, as the existing
            # phone-call.el watcher already proves on this modem.
            if direction is None or direction.value != 1:
                return
            caller = number.value if number is not None else None
            if not isinstance(caller, str) or len(caller) > 32:
                logger.warning("ignoring incoming call with invalid caller id")
                return
            self._calls += 1
            call_id = f"{self._boot_id}-{self._calls}"
            uplink, downlink = JitterBuffer(), DownlinkQueue()
            link = WsLink(self._config, uplink, downlink)
            await asyncio.to_thread(self._run_session, link, uplink, downlink,
                                    call_id, caller)

    def _run_session(self, link: WsLink, uplink: JitterBuffer,
                     downlink: DownlinkQueue, call_id: str, caller: str) -> None:
        BridgeSession(self._control_factory(), link, uplink, downlink).run(
            call_id, caller)

    async def run(self) -> None:
        from dbus_fast import BusType
        from dbus_fast.aio import MessageBus

        bus = await MessageBus(bus_type=BusType.SYSTEM).connect()
        path = "/org/freedesktop/ModemManager1/Modem/0"
        intro = await bus.introspect("org.freedesktop.ModemManager1", path)
        modem = bus.get_proxy_object("org.freedesktop.ModemManager1", path, intro)
        voice = modem.get_interface("org.freedesktop.ModemManager1.Modem.Voice")
        voice.on_call_added(lambda call: asyncio.create_task(self._handle_call(bus, call)))
        await asyncio.Future()


def main() -> None:
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s %(message)s")
    asyncio.run(RingWatcher(VoiceConfig.from_environ()).run())


if __name__ == "__main__":
    main()
