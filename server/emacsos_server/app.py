"""FastAPI app for the chat endpoint.

POST /chat: echoes the user's message, fires a single ``(message ...)``
on the phone via emacsclient to demonstrate the back-channel.  No LLM
in the loop yet; this is plumbing-only per the experiment plan in
docs/2026-05-13-first-e2e-experiment.org.
"""
from __future__ import annotations

import logging
from typing import Optional

from fastapi import FastAPI, Request
from pydantic import BaseModel

from .config import Config
from .phone import call_emacs

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
log = logging.getLogger("emacsos_server")

app = FastAPI(title="emacsos-server", version="0.0.1")
config = Config.from_env()


class PhoneAuth(BaseModel):
    auth_file: str


class ChatRequest(BaseModel):
    message: str
    phone: Optional[PhoneAuth] = None


class ChatResponse(BaseModel):
    text: str
    side_effect: Optional[str] = None


def _escape_elisp_string(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


@app.post("/chat", response_model=ChatResponse)
async def chat(req: ChatRequest, request: Request) -> ChatResponse:
    text = f"echo: {req.message}"
    side_effect: Optional[str] = None

    if req.phone is not None and request.client is not None:
        phone_host = request.client.host
        expr = f"(message {_escape_elisp_string('saw: ' + req.message)})"
        log.info("POST /chat msg=%r phone=%s", req.message, phone_host)
        ok, output = call_emacs(
            req.phone.auth_file,
            phone_host,
            expr,
            emacsclient=config.emacsclient,
        )
        if ok:
            side_effect = f"messaged the phone at {phone_host}"
        else:
            log.warning("emacsclient call failed: %s", output)
    else:
        log.info("POST /chat msg=%r (no phone auth; echo-only)", req.message)

    return ChatResponse(text=text, side_effect=side_effect)


def main() -> None:
    import uvicorn

    uvicorn.run(app, host="0.0.0.0", port=config.port)


if __name__ == "__main__":
    main()
