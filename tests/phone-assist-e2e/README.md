# Phone / Assist container E2E

From the EmacsOS checkout with the matching Assist checkout alongside it:

```sh
python3 tests/phone-assist-e2e/run.py --logs /tmp/phone-assist-e2e-results
```

Choose a new results directory for each run. Requires Docker, Python 3.10+,
Git, OpenSSL and OpenSSH on the host. The first build downloads the image's
system dependencies and Assist runtime packages constrained by Assist's
requirements plus the harness pins in `requirements.txt`. Build time is capped at ten
minutes, execution at five minutes, and individual client waits at 45 seconds.
No local model or phone hardware is used. Python optimization (`-O` or
`PYTHONOPTIMIZE`) is rejected before resources are created because it disables
the acceptance assertions.

Run the lightweight privacy and cleanup regressions without Docker using
`make test-phone-assist-e2e-harness`; this is also a prerequisite of `test-elisp`.

The harness runs four disposable containers on its own internal network:
headless Emacs, Assist, Git/SSH, and a credential-free shell simulator. It
publishes no host ports, mounts no host checkout or Docker socket, and uses
fresh repositories, separate client/server SSH keys, pinned host keys, a test
CA and a synthetic phone API token. The source snapshot copies tracked files
and the named harness files, excluding environment files and Git metadata.
The shell simulator receives only the disposable thread volume.

This runs actual `assist-web.el` HTTPS/SSE transport and queue recovery,
`assist-web-git.el` and its helper, ordinary client commit/push, Assist HTTP
admission, durable Runs, initialization/resume workers, Thread/LangGraph/SQLite,
and the Git lifecycle. A test-only Assist adapter at
`tests/phone_e2e_server.py` supplies a deterministic graph output node and its ready-model probe, and
adapts shell operations and generation scans to the simulator. It does not
prove model behavior, the production Docker/browser security implementation,
or physical-phone behavior. These are explicit capability/lifecycle tests.

Coverage:

- New and existing thread checkout, server publication and terminal refresh.
- Explicit client edit/commit/push followed by a server turn reading the edit.
- Dirty client file and index preservation with a Git status notice.
- Client push during execution, result-branch publication, explicit local
  reconciliation and a subsequent successful turn.
- Private Git setup failure and recovery; canonical auth denial then successful
  authorization in the same resident Emacs buffer.
- A resident client losing its real SSE observer, then explicitly refreshing the
  completed Run to retrieve its result and clear the queue.
- A second client with an independent cache durably accepting a queued Run
  before a forced server kill, then verifying that it executes once after restart.
- A hidden child owning the parent workspace while a parent user message is
  queued. The test waits for a real reset-worker deferral before releasing the
  child, then requires the user turn before exactly one task-result handoff.

The child test intentionally fails against Assist versions with the missing-wake
bug. To test an exact integration source without changing the harness branch:

```sh
python3 tests/phone-assist-e2e/run.py \
  --assist-source /path/to/checked-assist-composition \
  --assist-adapter ../assist/tests/phone_e2e_server.py \
  --logs /tmp/phone-assist-e2e-composition-results
```

`source.json` records the selected Git heads and copied file hashes. `build.log`,
client receipts, last observed state, container logs and `results.json` remain in the chosen results directory;
credentials are deleted. Runtime containers, the thread volume and the network
are removed on exit or interruption. The uniquely tagged test image remains
as a build cache and can be removed by its exact tag after testing.
