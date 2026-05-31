# Cellular cutover — instructions for the assistant bot

Use this when the user asks to switch the phone between **home wifi** and
**cellular** (T-Mobile), e.g. "go on cell," "back to wifi," "test cellular."

## Background

The phone has two networks: home wifi (`wlan0`) and cellular (`wwan0`,
T-Mobile, provisioned by `make cellular-bringup`). The cellular connection
(`emacsos-cellular`) stays **activated all the time**; which interface
carries internet traffic is decided by the **default route**. By design
wifi has the lower NetworkManager route metric (100 vs cell's 700), so at
home wifi always wins. To "use cell" you *deactivate the wifi connection*;
to come back you reactivate it. Don't bring the cellular *connection*
itself up or down — only toggle the wifi connection.

## Switch the phone to **cellular only**

Run on the phone:

    (shell-command-to-string "sudo nmcli connection down preconfigured")

The wifi connection deactivates (the radio stays on, just disassociated);
the default route flips to `wwan0` within a second since cellular is
already the next-priority route.

## Switch the phone **back to wifi**

    (shell-command-to-string "sudo nmcli connection up preconfigured")

Wifi re-associates with the saved home network; the default route returns
to `wlan0` within a second.

## Verify the internet works (after either switch)

    (shell-command-to-string "bash ~/playground/cell-validate.sh")

The script prints `[PASS]`/`[FAIL]` per axis (DNS, IPv4, IPv6) and a final
`OVERALL: PASS` or `OVERALL: FAIL` line, with the current default-route
interface in the `[INFO]` line. Exit code 0 = working.

## Nuances (so normal behaviour doesn't look like a bug)

- **T-Mobile cellular is IPv6-only.** On `wwan0` the IPv4 reach to
  `1.1.1.1` will fail unless `clatd` (464XLAT) is installed; the IPv6 reach
  passes. The validator's PASS criterion is "DNS + at least one of v4/v6,"
  so this still passes on cellular.
- **WireGuard over T-Mobile cellular is broken right now.** The home wg
  endpoint is IPv4-only and T-Mobile assigns v6-only, so a cutover that
  *stays* on cellular strands the phone from the home server. The
  bot-driven `cell-test.sh` below is safe because it restores wifi within
  ~15s, before any wg handshake times out. **Don't let the user ask for a
  stay-on-cellular switch** until the wg endpoint has an IPv6 (AAAA)
  reachable path.
- **Why `connection down/up`, NOT `radio wifi off/on`?** `radio wifi
  off/on` uses **rfkill**, and `systemd-rfkill` *persists* the blocked
  state across reboots — a phone rebooted while in "cellular mode" comes
  back with wifi soft-blocked and unreachable until something manually
  unblocks it. `connection down` has no such persistence; reboot recovers
  cleanly via `connection.autoconnect=yes` on the preconfigured wifi.
- **Do NOT touch the cellular connection.** `nmcli con down
  emacsos-cellular` would defeat the design — only toggle wifi.
- **If sudo prompts for a password**, the toggle commands hang.
  Passwordless sudo for `nmcli` is required; ask the user to configure it
  if needed.

## Quick diagnostics (if something looks wrong)

- `nmcli -t -f NAME,TYPE,DEVICE con show --active` — which connections are up.
- `ip -o route show default` — which interface owns the default route.
- `mmcli -m any` — modem state (should be `registered`).

The full bring-up runbook is in `docs/2026-05-26-cellular-data-connectivity.org`
in the emacsos repo (not on the phone).

## Fully bot-driven cutover test (fire-and-forget, then read the log)

The cutover itself severs the server->phone path (`emacsclient` can't reach
the phone while wifi is down and cell is the only route, until wg-over-v6
is in place), so the bot must run the test **detached** on the phone —
fire it, wait for the cycle to complete, then read the log after wifi is
back.

Fire (the `nohup ... &` detaches it so the eval_elisp call returns
immediately, even though the shell command's children keep running):

    (shell-command-to-string
      "nohup bash ~/playground/cell-test.sh > /dev/null 2>&1 < /dev/null &")

Wait ~30 seconds for the cutover + validate + restore cycle to complete
(use `sleep-for` or just tell the user "I'll re-check in 30 seconds"),
then read the log:

    (shell-command-to-string "cat ~/playground/cell-test.out")

The log shows: `wifi down: OK / FAILED`; the full `cell-validate.sh` output
with `[INFO] default route via: wwan0 (cell)` proving cellular was actually
the path during the validate; `wifi up: OK / FAILED`; and a final
timestamp. A good run has `OVERALL: PASS` from cell-validate AND both
`wifi down: OK` and `wifi up: OK`.
