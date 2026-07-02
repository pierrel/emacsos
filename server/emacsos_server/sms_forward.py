#!/usr/bin/env python3
"""sms-forward — the phone's SMS<->assist bridge.

Runs ON THE PHONE (where the modem / ModemManager live). Deliberately stdlib + ``requests``
only (no FastAPI/uvicorn) so it deploys to the Pi Zero as a single file against the system
Python — no venv. One process owns all SMS I/O with the modem via ``mmcli``, both directions:

- inbound: a poll thread reads received SMS, forwards each to assist's ``/inbound/sms``
  (content-hash ``message_id``), and deletes it from the modem store only on a definitive
  response (2xx accepted/duplicate, or 400 rejected) — a text that arrives while assist is
  down is retried, never lost (the modem store is the durable queue).
- outbound: ``POST /outbound/sms`` (called by assist when the user approves a reply)
  ``mmcli``-sends the message.

Auth both directions: the shared ``ASSIST_SMS_SECRET`` (``hmac.compare_digest``), fail-closed.
"""
from __future__ import annotations

import hashlib
import hmac
import json
import logging
import os
import re
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import requests

logger = logging.getLogger("sms_forward")

SECRET = os.getenv("ASSIST_SMS_SECRET")
INBOUND_URL = os.getenv("ASSIST_SMS_INBOUND_URL")      # assist's https://…/inbound/sms
OUTBOUND_PORT = int(os.getenv("ASSIST_SMS_FORWARD_PORT", "8766"))
# Bind address for the outbound endpoint. Defaults to all interfaces; set to the WireGuard
# interface IP to reduce exposure (this daemon runs as root).
BIND_HOST = os.getenv("ASSIST_SMS_BIND", "0.0.0.0")
POLL_INTERVAL = float(os.getenv("ASSIST_SMS_POLL_INTERVAL", "20"))
HTTP_TIMEOUT = float(os.getenv("ASSIST_SMS_HTTP_TIMEOUT", "15"))
# assist-web serves a mkcert cert on :5050 (for browser geolocation); this machine-to-machine
# POST rides the WireGuard tunnel (already encrypted) + carries the shared secret, so skip
# cert verification rather than ship the mkcert CA to the phone. Override to "true" if trusted.
VERIFY_TLS = os.getenv("ASSIST_SMS_VERIFY_TLS", "false").lower() in ("1", "true", "yes")
if not VERIFY_TLS:
    import urllib3
    urllib3.disable_warnings(urllib3.exceptions.InsecureRequestWarning)

_SMS_PATH = re.compile(r"/SMS/(\d+)")
_MODEM_PATH = re.compile(r"/Modem/(\d+)")
_MAX_BODY = 64 * 1024   # an SMS reply is tiny; cap the outbound request body


def _mmcli(*args: str, timeout: float = 15) -> subprocess.CompletedProcess:
    return subprocess.run(["mmcli", *args], capture_output=True, text=True, timeout=timeout)


def modem_index() -> str | None:
    """The current modem index — re-queried each poll (indices reset on re-enumeration)."""
    try:
        m = _MODEM_PATH.search(_mmcli("-L").stdout)
    except Exception:
        return None
    return m.group(1) if m else None


def list_sms(modem: str) -> list[str]:
    return _SMS_PATH.findall(_mmcli("-m", modem, "--messaging-list-sms").stdout)


def parse_sms(keyvalue: str) -> dict:
    """Parse ``mmcli -s <n> --output-keyvalue`` (``key : value`` lines) into a flat dict."""
    kv: dict[str, str] = {}
    for line in keyvalue.splitlines():
        if ":" in line:
            k, _, v = line.partition(":")
            kv[k.strip()] = v.strip()
    return kv


def read_sms(idx: str) -> dict | None:
    """Read one SMS. Returns None on a transient mmcli read failure (nonzero rc / empty
    output) so the caller RETAINS the SMS for retry rather than mistaking it for a poison
    record and deleting it (message loss)."""
    r = _mmcli("-s", idx, "--output-keyvalue")
    if r.returncode != 0 or not r.stdout.strip():
        return None
    return parse_sms(r.stdout)


def delete_sms(modem: str, idx: str) -> None:
    r = _mmcli("-m", modem, f"--messaging-delete-sms={idx}")
    if r.returncode != 0:
        # A failed delete leaves the SMS in the store → it'll be re-forwarded (assist dedups
        # by message_id) or, for a sent record, re-listed; log so a duplicate-causing failure
        # is detectable.
        logger.warning("failed to delete SMS %s: %s", idx, r.stderr.strip())


def message_id(sender: str, timestamp: str, text: str) -> str:
    """Content-derived id — stable across reads, unlike the reused modem SMS index."""
    return hashlib.sha256(f"{sender}\x00{timestamp}\x00{text}".encode()).hexdigest()


def send_sms(to: str, text: str) -> None:
    """mmcli-create + send an SMS (raises RuntimeError on any step failure)."""
    # Defensive bound on the recipient (assist validates too): it's folded into mmcli's
    # number='…' arg, so a crafted value must not break out of it.
    if not re.fullmatch(r"[+0-9A-Za-z]{1,20}", to or ""):
        raise RuntimeError(f"refusing to send to a malformed number: {to!r}")
    modem = modem_index()
    if modem is None:
        raise RuntimeError("no modem")
    # mmcli parses text='…' itself; a literal single-quote in the body would break that
    # parse. Replies are user-approved plain text, so fold ' to a typographic ’ (v1 residual).
    safe_text = text.replace("'", "’")
    create = _mmcli("-m", modem, f"--messaging-create-sms=text='{safe_text}',number='{to}'")
    m = _SMS_PATH.search(create.stdout)
    if create.returncode != 0 or not m:
        raise RuntimeError(f"could not create SMS: {create.stderr.strip() or create.stdout.strip()}")
    sms_idx = m.group(1)
    try:
        send = _mmcli("-s", sms_idx, "--send", timeout=30)
        if send.returncode != 0:
            raise RuntimeError(f"send failed: {send.stderr.strip()}")
    finally:
        delete_sms(modem, sms_idx)      # clean up the record whether the send succeeded or not


def _forward_one(modem: str, idx: str) -> None:
    kv = read_sms(idx)
    if kv is None:
        logger.warning("could not read SMS %s (transient); retaining for retry", idx)
        return                          # transient read failure — keep it, retry next poll
    sender = kv.get("sms.content.number", "")
    text = kv.get("sms.content.text", "")
    ts = kv.get("sms.properties.timestamp", "")
    state = kv.get("sms.properties.state", "")
    if state in ("sent", "sending", "draft"):
        return                          # our own sent/draft records
    if not (sender and text):
        logger.warning("deleting unparseable/empty SMS %s (state=%s)", idx, state)
        delete_sms(modem, idx)          # poison record — fail fast so it can't wedge the head
        return
    mid = message_id(sender, ts, text)
    try:
        r = requests.post(INBOUND_URL, json={"message_id": mid, "sender": sender, "text": text},
                          headers={"X-Assist-SMS-Secret": SECRET}, timeout=HTTP_TIMEOUT,
                          verify=VERIFY_TLS)
    except requests.RequestException as e:
        logger.warning("inbound POST failed for %s (retain, retry next poll): %s", idx, e)
        return
    if 200 <= r.status_code < 300 or r.status_code == 400:
        delete_sms(modem, idx)          # any 2xx (accepted/duplicate) or definitive 400 -> delete
    else:                                # 401/503/5xx -> transient, keep it for the next poll
        logger.warning("inbound POST returned %s for %s (retain, retry)", r.status_code, idx)


def poll_loop() -> None:
    logger.info("sms-forward poll loop started (interval=%ss)", POLL_INTERVAL)
    while True:
        try:
            modem = modem_index()
            if modem is None:
                logger.debug("no modem enumerated this tick")
            else:
                for idx in list_sms(modem):
                    _forward_one(modem, idx)
        except Exception:
            logger.exception("sms poll tick failed")
        time.sleep(POLL_INTERVAL)


class _Handler(BaseHTTPRequestHandler):
    # Per-connection socket timeout — a slow client (slowloris) can't hold a ThreadingHTTPServer
    # worker open indefinitely; the read raises and the connection is dropped.
    timeout = 15

    def do_POST(self) -> None:  # noqa: N802 (http.server API)
        if self.path.rstrip("/") != "/outbound/sms":
            return self._json(404, {"error": "not found"})
        if not SECRET:
            return self._json(503, {"error": "outbound SMS not configured"})
        provided = self.headers.get("X-Assist-SMS-Secret")
        if not (provided and hmac.compare_digest(provided, SECRET)):
            return self._json(401, {"error": "bad or missing secret"})
        try:
            length = int(self.headers.get("Content-Length", 0))
        except ValueError:
            return self._json(400, {"error": "bad Content-Length"})
        # This daemon runs as root and binds 0.0.0.0; an SMS reply is tiny, so cap the body
        # to reject a client sending a huge Content-Length (memory/CPU pressure).
        if length > _MAX_BODY:
            return self._json(413, {"error": "request too large"})
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, json.JSONDecodeError):
            return self._json(400, {"error": "invalid JSON"})
        to, text = body.get("to"), body.get("text")
        if not (isinstance(to, str) and to.strip() and isinstance(text, str) and text):
            return self._json(400, {"error": "to and text must be non-empty strings"})
        try:
            send_sms(to, text)
        except Exception as e:  # noqa: BLE001 — surface any mmcli failure as 502
            logger.warning("outbound send to %s failed: %s", to, e)
            return self._json(502, {"error": str(e)})
        return self._json(200, {"status": "sent"})

    def _json(self, code: int, obj: dict) -> None:
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args) -> None:  # noqa: A003 — quiet the default stderr access log
        pass


def main() -> None:
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s %(message)s")
    if SECRET and INBOUND_URL:
        threading.Thread(target=poll_loop, name="sms-poll", daemon=True).start()
    else:
        logger.warning("sms-forward inbound DISABLED: set ASSIST_SMS_SECRET + "
                       "ASSIST_SMS_INBOUND_URL to enable")
    logger.info("sms-forward outbound listening on %s:%d", BIND_HOST, OUTBOUND_PORT)
    ThreadingHTTPServer((BIND_HOST, OUTBOUND_PORT), _Handler).serve_forever()


if __name__ == "__main__":
    main()
