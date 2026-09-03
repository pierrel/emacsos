# Cellular cutover — instructions for the assistant bot

Use this when the user asks to switch the phone between **home wifi** and
**cellular** (T-Mobile), e.g. "go on cell," "back to wifi," "test cellular."

## Background

The phone has two networks: home wifi (`wlan0`) and cellular (`wwan0`,
T-Mobile, provisioned by `make cellular-bringup`). The cellular connection
(`emacsos-cellular`) normally stays activated; which interface carries
internet traffic is decided by the **default route**. By design wifi has the
lower NetworkManager route metric (100 vs cell's 700), so at home wifi wins.
Before disabling wifi, verify `emacsos-cellular` is active and bring it up if
needed. Never bring cellular down during a cutover.

## Switch the phone to **cellular only**

Run on the phone. The first command makes the fallback route available before
the second removes wifi:

    (shell-command-to-string
      "sudo nmcli connection up emacsos-cellular && sudo nmcli connection down preconfigured")

The wifi connection deactivates (the radio stays on, just disassociated);
the default route flips to `wwan0` within a second.

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
- **WireGuard works over T-Mobile IPv6.** The configured IPv6 endpoint and
  reduced tunnel MTU keep `phone-wg` reachable while cellular owns the route.
- **Why `connection down/up`, NOT `radio wifi off/on`?** `radio wifi
  off/on` uses **rfkill**, and `systemd-rfkill` *persists* the blocked
  state across reboots — a phone rebooted while in "cellular mode" comes
  back with wifi soft-blocked and unreachable until something manually
  unblocks it. `connection down` has no such persistence; reboot recovers
  cleanly via `connection.autoconnect=yes` on the preconfigured wifi.
- **Do not bring the cellular connection down during a cutover.** Bringing it
  up first is safe and prevents wifi removal from stranding the phone.
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

The detached test remains convenient because it completes and restores wifi
without holding an interactive command open. Before disabling wifi it starts a
separate-session 30-second recovery process; that process restores wifi even if
the test process is killed. WireGuard should remain reachable through the
cellular phase, so it can also be inspected over `phone-wg`.

Fire (the `nohup ... &` detaches it so the eval_elisp call returns
immediately, even though the shell command's children keep running):

    (shell-command-to-string
      "nohup bash ~/playground/cell-test.sh > /dev/null 2>&1 < /dev/null &")

Wait ~30 seconds for the cutover + validate + restore cycle to complete
(use `sleep-for` or just tell the user "I'll re-check in 30 seconds"),
then read the log:

    (shell-command-to-string "cat ~/playground/cell-test.out")

The log shows: `cell up: OK / FAILED`; `timed wifi recovery: ARMED / FAILED`;
`wifi down: OK / FAILED`; the full
`cell-validate.sh` output with `[INFO] default route via: wwan0 (cell)`
proving cellular was actually the path during the validate; `wifi up: OK /
FAILED`; and a final timestamp. A good run has `OVERALL: PASS` from
cell-validate and all transition lines report success.
