# Phone client against the reusable real Assist fixture

Start the standalone fixture from an Assist checkout, then run its direct smoke:

```sh
python tests/e2e/start.py --logs /tmp/assist-fixture-new --seconds 1800
python tests/e2e/smoke.py --fixture /tmp/assist-fixture-new/fixture.json
```

While that launcher remains running, run from the EmacsOS checkout:

```sh
python tests/phone-assist-e2e/run.py --fixture /tmp/assist-fixture-new/fixture.json --logs /tmp/phone-client-new
```

Run the client promptly after the smoke. Its 1200-second total budget includes
the build; its owned container stays alive for that full budget. Emacs action
subprocesses use the remaining total budget, while individual event waits keep
their 45-second limits. Private fixture-control requests bypass inherited proxies. The paired
1800-second fixture lifetime leaves time for the smoke and client startup.

The driver builds only an Emacs/Git/SSH client image and joins the fixture's exact
internal network. It loads production `assist-web.el` and `assist-web-git.el`.
The server is independently reusable; no Emacs source is needed to start it.
See Assist's `tests/e2e/README.md` for the real backend, privileged private daemon,
synthetic assets, source selection, bounds and teardown. This checks protocol and
lifecycle, not sandbox security or small-model behavior. A browser is not tested.

The nine sequential scenarios use a fresh synthetic Git-backed thread:

1. `Write server.txt hello-server`: create through the actual client; require a
   successful Run, server Git publication and matching client checkout/file.
2. Reopen that thread, explicitly commit/push `phone.txt`, then `Read phone.txt`;
   require the next server turn to read the pushed contents.
3. Leave `server.txt` dirty, then `Write other.txt next-server`; require original
   local bytes/index and an actionable pending-refresh notice, then restore/refresh.
   Require successful Git recovery, matching tips and the published `other.txt` bytes.
4. `Hold publication`: push `during.txt` while real inference waits, then release;
   require an exceptional result branch, explicitly merge/push it and
   `Read server-during.txt`; require both histories/files and a successful read.
5. Remove private Git remotes configuration; require the real error, restore it
   and require refresh recovery.
6. In one resident buffer, replace its token, Refresh, require canonical denial
   and an increased auth epoch; restore the token and Refresh the same buffer.
   Require a newly rendered canonical snapshot and a new successful Git receipt.
7. In one resident buffer, send `Hold observer`, close the entry's actual SSE
   process and await its production sentinel's accepted-unobserved state. Release
   inference, require exact Run GET success, then interactive Refresh with result
   visible and the queue cleared. This does not reproduce an open stalled SSE.
8. Send `Hold restart`, durably accept `Accepted before restart`, kill only the
   fixture's real server PID and restart its container/private daemon. Require
   original accepted Run/work identity, release the hold and observe exactly one
   transcript message and success.
9. Dispatch a hidden child with `Hold child`, then accept `Queued user message`.
   Require the actual reset queue to finish, the exact parent Run still held,
   the child owner lease intact, its exact registered Docker generation still running,
   and no reset retry/error.
   Release the child; require the queued user to finish before exactly one
   task-completion handoff. After the real reset queue settles, require a direct
   native Docker census of all sandbox-labelled containers in the private daemon
   to be empty, including unregistered leftovers. Save the terminal census receipt.
   The driver never calls or replaces reset workers.

Receipts, selected source hashes and last real state remain in `--logs`.
The driver removes only its labelled client, including anonymous volumes; the
launcher owns server/Git containers, daemon volume, network and temporary
credentials. SIGINT/SIGTERM or a failed scenario still perform bounded cleanup.
Assertions must remain enabled; optimized Python refuses before any resources.
The source-only build images remain cached. Run fast driver regressions with
`make test-phone-assist-e2e-harness`; the normal `make test-elisp` includes them.

## HITL-only panel

Add `--hitl-only` to the existing driver command to run the shared approval panel
instead of the nine Git/reset scenarios. Both normal phone loading and the actual
`assist-desktop.el` loader exercise the same production client functions. Every
supported kind is reviewed through its visible canonical discovery action and
confirmed with two taps. Mail flows retain and reconcile their original stopped
Run using the actual header's Review action: Refresh checks that exact stopped
Run and deliberately retains the preceding canonical snapshot until completion.
Fresh independent requests use the rendered thread review button. Receipts name
which visible control was activated. Every flow preserves an unsent draft. Independent network/download
requests must be visible with ordinary Run status ready. The server fixture uses
fresh synthetic requests and records fake effects; no real user data, provider
operation or network grant is used. Exact receipts are saved with the normal
client results. This panel is protocol/lifecycle evidence, not model, sandbox
security or physical-device acceptance.
