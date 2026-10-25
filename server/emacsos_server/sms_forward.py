#!/usr/bin/env python3
"""Unprivileged phone SMS transport, supervised by the existing UI session.

The fixed doas helper journals every local and HTTP send before modem effects.
This bridge only hands durable receipts to Assist and acknowledges exact status
versions after server durability. It never repeats an SMS to repair history.
"""
from __future__ import annotations

import hmac
import io
import ipaddress
from pathlib import Path
from urllib.parse import urlsplit
import json
import logging
import os
import re
import subprocess
import threading
import time
from http.server import BaseHTTPRequestHandler, HTTPServer

import requests

logger = logging.getLogger("sms_forward")

SECRET = os.getenv("ASSIST_SMS_SECRET")
INBOUND_URL = os.getenv("ASSIST_SMS_INBOUND_URL")      # assist's https://…/inbound/sms
OUTBOUND_PORT = int(os.getenv("ASSIST_SMS_FORWARD_PORT", "8767"))
BIND_HOST = os.getenv("ASSIST_SMS_BIND", "127.0.0.1")
POLL_INTERVAL = 20
HTTP_TIMEOUT = (5, 15)
VERIFY_TLS = os.getenv("ASSIST_SMS_CA", "true")
if VERIFY_TLS.lower() == "true":
    VERIFY_TLS = True
_MAX_BODY = 32 * 1024
_ID = re.compile(r"[A-Za-z0-9_-]{1,128}\Z")


def helper(payload, timeout=70):
    """Use the installed fixed helper; no shell, secrets or body in argv."""
    result = subprocess.run(
        ["/usr/bin/doas", "-n", "/usr/local/sbin/emacsos-openrc-sms"],
        input=json.dumps(payload, ensure_ascii=False), capture_output=True,
        text=True, timeout=timeout)
    if len(result.stdout.encode()) > 2 * 1024 * 1024:
        raise ValueError("helper output exceeds bound")
    return result


def send_sms(to, text, message_id, occurred_at):
    result = helper({"number": to, "text": text, "message_id": message_id, "occurred_at": occurred_at})
    line = result.stdout.strip()
    if line == "sent" and result.returncode == 0:
        return "sent"
    if line.startswith("not-sent:") and result.returncode != 0:
        return "not_sent"
    return "unknown"


def sync_once():
    """Retry archive handoff only. Incoming modem history stays available to UI."""
    receipts = json.loads(helper({"operation": "receipts"}, timeout=35).stdout)["receipts"]
    if not isinstance(receipts, list) or len(receipts) > 20:
        raise ValueError("invalid receipts")
    for row in receipts:
        incoming = row["direction"] == "incoming"
        url = INBOUND_URL if incoming else INBOUND_URL.rsplit("/inbound/sms", 1)[0] + "/sms/receipts"
        body = {"message_id": row["id"], "text": row["text"], "occurred_at": row["occurred_at"]}
        if incoming:
            body["sender"] = row["number"]
        else:
            body.update(number=row["number"], status=row["status"])
        response = requests.post(url, json=body, headers={"X-Assist-SMS-Secret": SECRET},
                                 timeout=HTTP_TIMEOUT, verify=VERIFY_TLS, allow_redirects=False)
        if response.status_code != 200:
            continue
        accepted = response.json()
        if incoming and accepted.get("status") not in {"accepted", "duplicate"}:
            continue
        if not incoming and (accepted.get("message_id") != row["id"] or accepted.get("status") != row["status"]):
            continue
        helper({"operation": "ack", "message_id": row["id"], "status": row["status"]}, timeout=35)


def poll_loop():
    while True:
        try:
            sync_once()
        except Exception:
            # No number/body, endpoint or exception text in logs.
            logger.warning("SMS receipt handoff incomplete; journal retained")
        time.sleep(POLL_INTERVAL)


class _DeadlineReader(io.RawIOBase):
    """Shrink every underlying socket read to one absolute request deadline."""

    def __init__(self, raw, connection, deadline):
        super().__init__()
        self.raw, self.connection, self.deadline = raw, connection, deadline

    def readable(self):
        return True

    def readinto(self, buffer):
        remaining = self.deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("SMS request deadline")
        self.connection.settimeout(remaining)
        return self.raw.readinto(buffer)

    def close(self):
        self.raw.close()
        super().close()


class _Handler(BaseHTTPRequestHandler):
    # One bounded HTTP worker avoids an unbounded thread per remote connection.
    timeout = 10

    def setup(self):
        super().setup()
        self.rfile.close()
        raw = self.connection.makefile("rb", buffering=0)
        self.rfile = io.BufferedReader(_DeadlineReader(raw, self.connection, time.monotonic() + 10))

    def do_POST(self) -> None:  # noqa: N802 (http.server API)
        if self.path != "/outbound/sms/v1":
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
        # A negative length must be rejected too — read(-1) would read until EOF, bypassing
        # the cap (unbounded read = memory/CPU pressure).
        if length < 0:
            return self._json(400, {"error": "bad Content-Length"})
        if length > _MAX_BODY:
            return self._json(413, {"error": "request too large"})
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, json.JSONDecodeError):
            return self._json(400, {"error": "invalid JSON"})
        if not isinstance(body, dict) or set(body) != {"message_id", "to", "text", "occurred_at"}:
            return self._json(400, {"error": "invalid shape"})
        mid = body["message_id"]
        if not isinstance(mid, str) or not _ID.fullmatch(mid):
            return self._json(400, {"error": "invalid identity"})
        to, text = body.get("to"), body.get("text")
        if not (isinstance(to, str) and to.strip() and isinstance(text, str) and text):
            return self._json(400, {"error": "to and text must be non-empty strings"})
        self.connection.settimeout(5)
        try:
            status = send_sms(to, text, mid, body["occurred_at"])
        except Exception:
            status = "unknown"
        return self._json(200, {"message_id": mid, "status": status})

    def _json(self, code: int, obj: dict) -> None:
        data = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def log_message(self, *args) -> None:  # noqa: A003 — quiet the default stderr access log
        pass


def load_phone_config():
    """Load a fixed private UI-owned config; never execute configuration as shell."""
    global SECRET, INBOUND_URL, BIND_HOST, OUTBOUND_PORT, VERIFY_TLS
    path = Path("/var/lib/emacsos-lab/.config/emacsos/sms.json")
    if path.is_symlink():
        raise ValueError("unsafe SMS configuration")
    info = path.stat()
    if info.st_uid != os.geteuid() or info.st_mode & 0o077:
        raise ValueError("unsafe SMS configuration")
    with path.open("rb") as source:
        raw = source.read(8193)
    if len(raw) > 8192:
        raise ValueError("oversized SMS configuration")
    value = json.loads(raw)
    if not isinstance(value, dict) or set(value) != {"secret", "inbound_url", "bind", "port", "ca"}:
        raise ValueError("invalid SMS configuration")
    if not all(isinstance(value[k], str) and value[k] for k in ("secret", "inbound_url", "bind", "ca")):
        raise ValueError("invalid SMS configuration")
    url = urlsplit(value["inbound_url"])
    if url.scheme != "https" or not url.hostname or url.username or url.password or url.query or url.fragment or url.path != "/inbound/sms":
        raise ValueError("invalid SMS endpoint")
    address = ipaddress.ip_address(value["bind"])
    if address.version != 4 or address.is_unspecified or address.is_multicast or not (address.is_private or address.is_loopback):
        raise ValueError("SMS listener requires an explicit private IPv4 interface")
    if not isinstance(value["port"], int) or isinstance(value["port"], bool) or not 1024 <= value["port"] <= 65535:
        raise ValueError("invalid SMS port")
    if not value["ca"].startswith("/"):
        raise ValueError("SMS requires an installed CA file")
    SECRET, INBOUND_URL, BIND_HOST, OUTBOUND_PORT, VERIFY_TLS = (value[k] for k in ("secret", "inbound_url", "bind", "port", "ca"))


def publish_transport_state(state):
    """Publish a controlled phone-local availability observation, without message data."""
    path = Path("/run/emacsos-ui/sms-status")
    temporary = path.with_suffix(".tmp")
    temporary.write_text(state + "\n", encoding="ascii")
    temporary.replace(path)


def serve():
    """Wait for a configured interface without restarting the graphical session."""
    while True:
        try:
            server = HTTPServer((BIND_HOST, OUTBOUND_PORT), _Handler)
        except OSError:
            publish_transport_state("SMS transport is waiting for its network interface or port.")
            time.sleep(POLL_INTERVAL)
            continue
        with server:
            publish_transport_state("SMS transport is running. Server receipt handoff may be offline.")
            server.serve_forever()


def main() -> None:
    logging.basicConfig(level=logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s %(message)s")
    if os.geteuid() == 0:
        raise SystemExit("SMS bridge must run as the UI user")
    load_phone_config()
    if SECRET and INBOUND_URL:
        threading.Thread(target=poll_loop, name="sms-poll", daemon=True).start()
    else:
        logger.warning("sms-forward inbound DISABLED: set ASSIST_SMS_SECRET + "
                       "ASSIST_SMS_INBOUND_URL to enable")
    logger.info("sms-forward outbound listening on %s:%d", BIND_HOST, OUTBOUND_PORT)
    serve()


if __name__ == "__main__":
    main()
