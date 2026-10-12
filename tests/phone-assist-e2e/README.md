# Phone client against the reusable real Assist fixture

Start the standalone fixture from an Assist checkout, then run its direct smoke:

```sh
python tests/e2e/start.py --logs /tmp/assist-fixture-new --seconds 900
python tests/e2e/smoke.py --fixture /tmp/assist-fixture-new/fixture.json
```

While that launcher remains running, run from the EmacsOS checkout:

```sh
python tests/phone-assist-e2e/run.py --fixture /tmp/assist-fixture-new/fixture.json --logs /tmp/phone-client-new
```

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
4. `Hold publication`: push `during.txt` while real inference waits, then release;
   require an exceptional result branch, explicitly merge/push it and
   `Read server-during.txt`; require both histories/files and a successful read.
5. Remove private Git remotes configuration; require the real error, restore it
   and require refresh recovery.
6. In one resident buffer, replace its token, Refresh, require canonical denial
   and an increased auth epoch; restore the token and Refresh the same buffer.
   Require a newly rendered canonical snapshot and recovered Git state.
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
