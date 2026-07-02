"""sms-forward — the phone's SMS<->assist bridge.

One process owns all SMS I/O with the modem (via ``mmcli``), both directions:
- inbound: a poll thread reads received SMS, forwards each to assist's ``/inbound/sms``
  (content-hash ``message_id``), and deletes it from the modem store only on a definitive
  response (2xx accepted/duplicate, or 400 rejected) — so a text that arrives while assist
  is down is retried, never lost (the modem store is the durable queue).
- outbound: ``POST /outbound/sms`` (called by assist when the user approves a reply)
  ``mmcli``-sends the message.

Kept OFF the emacsos-server (agent) process: SMS I/O changes for modem/cellular reasons, the
agent for agent reasons. Runs as its own systemd unit. Auth: the shared ``ASSIST_SMS_SECRET``
(``hmac.compare_digest``), fail-closed.
"""
from __future__ import annotations

import hashlib
import hmac
import logging
import os
import re
import subprocess
import threading
import time

import requests
from fastapi import FastAPI, Header, HTTPException
from pydantic import BaseModel

logger = logging.getLogger("sms_forward")

SECRET = os.getenv("ASSIST_SMS_SECRET")
INBOUND_URL = os.getenv("ASSIST_SMS_INBOUND_URL")      # assist's https://…/inbound/sms
POLL_INTERVAL = float(os.getenv("ASSIST_SMS_POLL_INTERVAL", "20"))
HTTP_TIMEOUT = float(os.getenv("ASSIST_SMS_HTTP_TIMEOUT", "15"))

_SMS_PATH = re.compile(r"/SMS/(\d+)")
_MODEM_PATH = re.compile(r"/Modem/(\d+)")


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


def read_sms(idx: str) -> dict:
    return parse_sms(_mmcli("-s", idx, "--output-keyvalue").stdout)


def delete_sms(modem: str, idx: str) -> None:
    _mmcli("-m", modem, f"--messaging-delete-sms={idx}")


def message_id(sender: str, timestamp: str, text: str) -> str:
    """Content-derived id — stable across reads, unlike the reused modem SMS index."""
    return hashlib.sha256(f"{sender}\x00{timestamp}\x00{text}".encode()).hexdigest()


def _forward_one(modem: str, idx: str) -> None:
    kv = read_sms(idx)
    sender = kv.get("sms.content.number", "")
    text = kv.get("sms.content.text", "")
    ts = kv.get("sms.properties.timestamp", "")
    state = kv.get("sms.properties.state", "")
    # Only received messages; skip our own sent/draft records.
    if state in ("sent", "sending", "draft"):
        return
    if not (sender and text):
        logger.warning("deleting unparseable/empty SMS %s (state=%s)", idx, state)
        delete_sms(modem, idx)          # poison record — fail fast so it can't wedge the head
        return
    mid = message_id(sender, ts, text)
    try:
        r = requests.post(INBOUND_URL, json={"message_id": mid, "sender": sender, "text": text},
                          headers={"X-Assist-SMS-Secret": SECRET}, timeout=HTTP_TIMEOUT)
    except requests.RequestException as e:
        logger.warning("inbound POST failed for %s (retain, retry next poll): %s", idx, e)
        return
    if r.status_code in (200, 400):     # accepted/duplicate, or definitively rejected -> delete
        delete_sms(modem, idx)
    else:                                # 401/503/5xx -> transient, keep it for the next poll
        logger.warning("inbound POST returned %s for %s (retain, retry)", r.status_code, idx)


def _poll_loop() -> None:
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


app = FastAPI()


@app.on_event("startup")
def _start_poll() -> None:
    if not (SECRET and INBOUND_URL):
        logger.warning("sms-forward inbound DISABLED: set ASSIST_SMS_SECRET + "
                       "ASSIST_SMS_INBOUND_URL to enable")
        return
    threading.Thread(target=_poll_loop, name="sms-poll", daemon=True).start()


class _Outbound(BaseModel):
    to: str
    text: str


@app.post("/outbound/sms")
def outbound_sms(payload: _Outbound, x_assist_sms_secret: str | None = Header(default=None)):
    """Send an approved reply via the modem. Called by assist on approval."""
    if not SECRET:
        raise HTTPException(status_code=503, detail="outbound SMS not configured")
    if not (x_assist_sms_secret and hmac.compare_digest(x_assist_sms_secret, SECRET)):
        raise HTTPException(status_code=401, detail="bad or missing secret")
    modem = modem_index()
    if modem is None:
        raise HTTPException(status_code=503, detail="no modem")
    # mmcli parses text='…' itself; a literal single-quote in the body would break that
    # parse. Replies are user-approved plain text, so fold ' to a typographic ’ (v1 residual).
    safe_text = payload.text.replace("'", "’")
    create = _mmcli("-m", modem,
                    f"--messaging-create-sms=text='{safe_text}',number='{payload.to}'")
    m = _SMS_PATH.search(create.stdout)
    if not m:
        raise HTTPException(status_code=500, detail=f"could not create SMS: {create.stderr.strip()}")
    sms_idx = m.group(1)
    send = _mmcli("-s", sms_idx, "--send", timeout=30)
    if send.returncode != 0:
        raise HTTPException(status_code=502, detail=f"send failed: {send.stderr.strip()}")
    delete_sms(modem, sms_idx)          # clean up the sent record
    return {"status": "sent"}
