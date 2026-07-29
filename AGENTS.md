# emacsos — agent guide

EmacsOS is a malleable, agent-customizable, local-first OS built on Emacs for small
touchscreen devices (a Raspberry Pi Zero 2 W, 320×240 touchscreen, T9 keyboard). Two
surfaces: the **phone client** (elisp — `os.el` the shell/launcher, `chat.el` the `.assist`
chat mode, `network.el` the cell/wifi UI, plus the dockerized simulator under
`server/simulation/`) and **`emacsos-server`** (Python + FastAPI under `server/` —
`app.py` the phone↔agent gateway, `channel.py` the agent channel + `get_config` tool,
`apply.py`/`config.py`/`config_repo.py` the config-apply skill, `stream.py` token streaming).
The server *embeds an assist-style agent* — behaviour ultimately comes from the `assist`
package, driven through its `AgentSpec` embedder contract; emacsos adds the phone identity,
the config-apply skill, and the phone↔server channel.

Reach the phone via `ssh phone` (home LAN) / `ssh phone-wg` (WireGuard, away). Test with
`make test-elisp` (ERT) + `make test-server` (pytest) + `make smoke` (dockerized) + a **live
phone**. There is **no small-model eval harness** here — the live phone is the contract
(vs assist, where the eval is).

## Development workflow

Same three-phase **Design → Code → Review** as assist (see `../assist/AGENTS.md` "Development
workflow" and the global `~/.codex/AGENTS.md` loop) — using the shared lens checklists
`../.claude/agents/design-reviewer.md` + `../.claude/agents/code-reviewer.md`, run via
`codex exec`/`codex review` (Codex) or subagents (Claude). Emphasis shifts for emacsos:
- Design lenses lean on the **phone↔server wire protocol** shape (small + obvious) and the
  **320×240 / T9 / single-buffer UX** constraints; the threat-model lens stays HEAVY for any
  `mmcli`/root/SMS/network-listener surface (the `sms-forward` root daemon passed the local
  loop then took 7 Copilot rounds of real hardening — slowloris, body-cap + its negative-
  `Content-Length` bypass, bind exposure, injection).
- Code review adds elisp specifics (marker insertion-types, buffer-local vs global state,
  read-only text props) and server specifics (async/executor boundaries, lock pairing,
  generator cleanup).
- Applies to: `chat.el`, `os.el`, `network.el`, the wire protocol, `emacsos_server/app.py`,
  the simulator, deploy plumbing (`Makefile` `phone-install`/`local-deploy`, `deploy/`), and
  how assist is loaded.

## Branching / deploy / testing

Feature-branch off `main` only. Commit/push freely on branches; `main` commits need Pierre's
go-ahead. Prefer ff merges. **"Ready"** = the three phases done + `make test-elisp` +
`make test-server` pass + `make smoke` when the wire protocol or boot path changed. Phone
deploy from a feature branch is OK (`make phone-install`/`make local-deploy`) but only one
branch is on the phone at a time (`scp` overwrites). **Real-phone smoke after a boot-path
refactor** — unit tests don't catch entry-point regressions (the assist `manage.web` package
split crash-looped systemd until `__main__.py` was added; the principle applies to emacsos
boot too).

## Conventions

- **Layers: deterministic emacs primitives + an interpretive agent** (README "Layers"). Every
  device action is an emacs interactive command; the dividing line is *determinism*. Emacs
  commands are **deterministic primitives** — concrete arg in, same action out, no model in the
  loop (e.g. `(emacos-call "+1XXXXXXXXXX")` just dials). The **agent is the interpretive layer**:
  turning fuzzy intent ("call Ana") into a concrete primitive call — resolution, disambiguation,
  confirmation — is the agent's job and lives in a **skill**, never in the primitive. Build a
  feature as *a deterministic command (shared by user taps and agent elisp) + a skill that
  resolves intent down to that command's args*. Skills direct the agent to evaluate elisp; they
  don't add bespoke server tools. Agent-platform services that aren't device control (the model,
  conversation memory, config git-versioning/rollback) stay server-side.
- **No modal confirms on the phone.** `y-or-n-p` / `yes-or-no-p` / GUI dialogs can't be tapped on
  the 320×240 touchscreen — a confirm-via-modal *bricks* that action. Use the **in-row two-tap
  button** pattern (first tap relabels to "Confirm X?" + arms; second tap fires; any other tap
  cancels). Audit new keyboard commands for `y-or-n-p`/`yes-or-no-p`/`read-char`.
- **The phone is the user.** Every UI decision is on a 320×240 screen with a T9 keyboard — fewer
  buttons, larger hit targets, less text. When in doubt, test on the phone (or the simulator),
  not desktop intuition.
- **assist is a sibling checkout, not a PyPI package.** The `Makefile` installs it editably from
  `$(ASSIST_REPO_DIR)` (default `../assist`) with `pip install -e ../assist -c ../assist/requirements.txt`.
  Bump assist: `cd ../assist && git pull && cd ../emacsos && rm -rf server/.venv && make setup-server`.
- **No new docs unless asked** (a `docs/<date>-<slug>.org` for a *specific* non-trivial feature is
  fine — mirror the existing format). **No real local paths / IPs / family PII in tracked files** —
  operator specifics flow through Makefile vars (`PHONE_EMACSOS_DIR`, `PHONE_INIT_SNIPPET`,
  `DEV_BOX_URL`, `ASSIST_REPO_DIR`); `git ls-files | xargs grep -nE "/home/[a-z]+|192\.168\."`
  should return nothing.

## Live infra notes

- **Cellular + WireGuard (shipped).** Cellular bring-up via NetworkManager `gsm` (in-kernel
  `qmi_wwan` + ModemManager); on-device `network.el` UI; away-phone WireGuard (`make wg-phone-bringup`).
  Load-bearing pitfalls: the wg endpoint must be the dev box's **stable IPv6** (T-Mobile is v6-only);
  phone wg **MTU=1280** is mandatory; use `wg-quick down/up` (not `syncconf`) when the endpoint family
  changes; phone wg `AllowedIPs` includes `<server-lan-ip>/32` (so LAN ssh to the phone is broken by
  design when wg is up — use `ssh phone-wg`); rfkill persists across reboots.
- **SIM7600G-H telephony (validated, the voice-call P3 hardware path).** Voice calls work; 16 kHz PCM
  on `/dev/ttyUSB4` via `AT+CPCMREG=1`; the bridge owns primary `ttyUSB2` for raw AT/audio while the
  human UI retains secondary `ttyUSB3`; ModemManager keeps QMI call detection/data. Downlink validated;
  uplink + the audio bridge are net-new for P3. The board is a quad-core
  A53 (64-bit) — the "too weak for whisper" assumption was wrong.
- **Config-apply after `/clear`:** a `get_config()` tool (`channel.py`) returns
  `ConfigRepo.current().body` (committed config = next-restart source of truth) so the agent can read
  config after conversation memory is wiped; the skill mandates a `get_config` read before `apply_config`.
- **Voice-call assistant:** emacsos owns the **phone-side PCM bridge** (P3, hardware-gated — the
  `call_bridge.py` daemon: D-Bus ring watch, ATA/CHUP, the CPCMREG PCM pump). The receptionist,
  catalog, and all server-side voice/session responsibilities live in **assist** (see the meta
  `AGENTS.md` "Current state"); emacsos is the thin device client. Assist P1 Flow, Speech, and
  bounded Wire are merged/deployed (PRs #209/#211/#214);
  `session.py` is next, then the security/reconstruction gate. The current in-flight work remains
  assist-side; emacsos's implementation begins at P3 only after the fake-bridge contract is complete.
