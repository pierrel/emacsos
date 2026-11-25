# Virtual phone

Run real EmacsOS in a disposable Alpine/OpenRC/Sway guest through QEMU/KVM.
The physical and virtual targets consume `deploy/pinephone/openrc-runtime`:
shared Alpine dependencies, explicit application payload, fonts, configuration
and the same session startup, supervision and readiness probes. The existing
physical digest manifest verifies these public inputs. No personal phone data,
credentials, accounts, contacts or history enter the build.

## Prerequisites and clean build

Use Linux x86_64 with usable `/dev/kvm`, Docker, Git, Python 3 and OpenSSH client.
Install ImageMagick for PNG captures; PPM captures need no converter. Allow space
for a 3 GiB base, overlay and image layers. QEMU is supplied inside the Alpine
image. No host QEMU install, privileged container or physical device is needed.
`WVKBD_REPO_DIR` must contain the Git object pinned in
`deploy/pinephone/wvkbd-revision`; the build archives that object and compiles
its native architecture with the physical layout. Package installation needs
Internet access during build.

From a clean candidate checkout, choose a private state directory outside Git:

```sh
export WVKBD_REPO_DIR=/path/to/wvkbd
export VIRTUAL_PHONE_STATE=/path/to/private/virtual-phone-state
deploy/virtual-phone/build
deploy/virtual-phone/start
deploy/virtual-phone/operate ready
deploy/virtual-phone/operate screenshot "$VIRTUAL_PHONE_STATE/boot.png"
```

Use a separate state directory for each source context. The builder captures
only tracked checkout files, including current tracked edits, and the generated
test-only SSH public key. Keep the private key and captures outside Git.
The first start creates a disposable QCOW2 overlay; relaunch retains it.
The builder refuses to replace a base referenced by an existing overlay.

The guest has no external network. Its container uses `--network none`; QEMU's
restricted network permits container-local SSH only. Assist URLs point to guest
loopback port 9. The visible unavailable-Assist state is expected. No production
service, token or phone connection is used.

## Native operations

`operate` is a thin wrapper over SSH, native `wtype`, QMP, Docker and ImageMagick.
It reports failures and does not repair or silently replace a failing guest.
`ready` uses a total 60-second readiness budget for the physical session's
readiness marker. Failed or stalled SSH attempts can be followed by another
probe within that same deadline; each attempt is bounded to at most 15 seconds
and the remaining budget. The marker is
written after Sway exposes an Emacs window and its Emacs server responds.

```sh
# Ordinary key combinations and text, passed to wtype:
deploy/virtual-phone/operate keys -- -M alt -k x -m alt calendar -k Return
deploy/virtual-phone/operate keys -- -M alt -k x -m alt calendar-scroll-left -k Return
deploy/virtual-phone/operate screenshot "$VIRTUAL_PHONE_STATE/calendar.png"
# A real buffer transition, then text insertion and editing:
deploy/virtual-phone/operate keys -- -M alt -k x -m alt switch-to-buffer -k Return '*scratch*' -k Return
deploy/virtual-phone/operate text 'Virtual phone draft'
deploy/virtual-phone/operate keys -- -k BackSpace -k BackSpace -k BackSpace -k BackSpace -k BackSpace
deploy/virtual-phone/operate text 'edited'
deploy/virtual-phone/operate screenshot "$VIRTUAL_PHONE_STATE/edited.png"
# Pixel coordinates refer to the actual 720x1440 scanout:
deploy/virtual-phone/operate tap 220 690
deploy/virtual-phone/operate scroll down 3
deploy/virtual-phone/operate screenshot "$VIRTUAL_PHONE_STATE/after-input.png"
deploy/virtual-phone/operate diag
deploy/virtual-phone/operate logs > "$VIRTUAL_PHONE_STATE/diagnostics.log" 2>&1
```

Inspect each capture and wait for the visible transition before the next action.
A successful input command alone does not establish UI success. `keys` accepts
native wtype arguments; `text` treats its argument literally. Scrolling acts at
the current pointer location. Tap and wheel press/release use separate QMP
reports so libinput observes both edges. PPM output is also supported.

The graphical account's writable home is `/var/lib/emacsos-lab`. For synthetic
file tests, use an explicit path such as
`/var/lib/emacsos-lab/virtual-phone-state.txt` in the ordinary Emacs file prompt.
The SSH root account's `/root` is not writable by the graphical account, and
`/home/emacsos-lab` does not exist. A buffer's file prompt directory can differ
from the account home.

For additional harmless diagnostics, native SSH remains available:

```sh
cid=$(cat "$VIRTUAL_PHONE_STATE/container.id")
docker exec -i "$cid" ssh -T -i /out/id_ed25519 -p 2222 \
  -o BatchMode=yes -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
  root@127.0.0.1 'uname -a; rc-status; cat /sys/power/state'
```

QMP and VNC Unix sockets and `serial.log` are in the private state directory.
No host-wide listener or manually attached console is required. Emacs evaluation
can diagnose a problem but cannot replace visible ordinary-input acceptance.

## Stop, relaunch and clean reset

```sh
deploy/virtual-phone/operate stop       # guest poweroff; expect container exit 0
deploy/virtual-phone/start              # same overlay and saved synthetic files
deploy/virtual-phone/operate ready
deploy/virtual-phone/operate stop
deploy/virtual-phone/operate reset      # remove stopped overlay only
deploy/virtual-phone/start              # fresh base; prior synthetic files absent
deploy/virtual-phone/operate ready
```

`stop` bounds its SSH request to 15 seconds and its container-exit wait to
30 seconds, removes only its exited container, and preserves
the disk and evidence. `reset` refuses while `container.id` exists. After stop
and reset, `build` can provision a different candidate.
If shutdown or readiness fails, inspect logs and the actual container state.
There is no automatic fallback. An explicitly chosen `docker stop -t 10 "$cid"`
is abrupt and can lose unsynced writes; record it as a failure, inspect the exit,
then remove that exited container and its ID before reset. Never remove an
active guest's overlay or replace its backing base.

An earlier long-running guest reported SSH `sshd-session` I/O errors. The cause
is unresolved; short successful sessions do not establish long-lived disk
reliability. Report a recurrence with its serial/QEMU/guest logs and preserve the
state. Do not silently rebuild or change the acceptance scenario.

## Fidelity and acceptance

The guest uses Alpine 3.22 x86_64 and `linux-virt`; the phone uses aarch64,
postmarketOS v25.06 and its device kernel. Package revisions follow the configured
Alpine repositories at build time; compare `apk info -v`. Shared runtime packages
include Python D-Bus, Requests and PyYAML. The explicit hardware package group is
physical-only: Android, PinePhone audio and modem packages.
The VM adds kernel/boot, Mesa, image-building and QEMU packages. Its connector is
virtual, with the same 720x1440 geometry, scale 2 and keyboard allocation.

Firefox mobile UI policy uses the same native `mobile-config-firefox` package
named in the shared definition. Stock Alpine 3.22 has no such package, so the VM
uses a one-off tagged official postmarketOS v25.06 repository. The checked-in
public signing key comes from the [official v25.06 `postmarketos-keys` source](https://gitlab.postmarketos.org/postmarketOS/pmaports/-/raw/v25.06/main/postmarketos-keys/build.postmarketos.org.rsa.pub);
its SHA-256 is pinned in the shared definition. APK verifies the signed index
and package, then converts its world entry to an ordinary untagged dependency
without network access. The repository and extra key are not retained.
No unsigned install, distribution upgrade or second policy implementation is used.
The verified package is 4.6.0-r0, architecture-neutral CSS/JS/policy data with no
package dependencies. This matches the recorded v25.06 physical input; the
currently installed physical version has not been independently rechecked.

The shared session skips physical audio initialization, DSI/Goodix checks, power
monitoring and hardware services in the VM. It retains actual DBus, Sway, keyboard,
Emacs, readiness probes and display heartbeat. Native BusyBox init supervises a
private VM session group; bounded TERM/KILL cleanup supports the UI restart action.
The physical installer retains its existing root snapshot validation, rollback,
privilege rules and service mechanism. No hardware simulator is supplied.
Physical call/SMS/network/device helpers and privilege rules remain unsupported
in this VM; Controls and local SMS queries can report unavailable. Hardware
suspend, modem wake, calls, sensors and battery behavior require physical tests.

Before publishing phone code or review fixes, validate both its isolated clean
checkout and a clean composition with current deployed application code. Record
exact source identities, commands, expected/actual results, difficulties, logs
and outside-Git screenshots for all seven scenarios:

1. Build and boot the real graphical candidate from a clean checkout.
2. Capture and inspect its phone-sized screen headlessly.
3. Navigate existing buffers/views using ordinary keys, taps and scrolling.
4. Launch and operate an existing app or surface through the UI. Controls tap/scroll
   is one example; Calendar month navigation is another when its title is readable.
5. Enter and edit text through input and verify the visible result.
6. Stop/relaunch, then reset and prove prior synthetic state is absent.
7. Retrieve logs and run harmless diagnostics without an attached console.

A fresh tester uses this published workflow and reports failures without code
changes or silent workarounds. Boot alone, mocked UI, internal evaluation and
historical results do not satisfy a fresh acceptance run. The
[acceptance record](../../docs/virtual-phone-review.org) identifies the exact
previously tested source and Calendar limitation. Acceptance of the readiness
correction is pending a new independent run in both contexts.

Roadmap only: an isolated real Assist server with synthetic credentials/history
and end-to-end client/server validation. This target does not implement it.
