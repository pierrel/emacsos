#!/usr/bin/env bash
# server-add-peer.sh — append a peer to /etc/wireguard/wg0.conf on the WG
# server (the home dev box, listening UDP 51821 on both v4 and v6 endpoints)
# and live-reload via `wg syncconf` *without* dropping existing peers'
# handshakes.  Idempotent — a peer whose pubkey is already in the conf is
# skipped, and `wg syncconf` is a no-op when the running state already
# matches the desired state.
#
# Run on the WG SERVER (this dev box).  Required env (passed via the
# `wg-add-peer` Make target, never committed to a tracked file):
#   PEER_PUBKEY    — the new peer's WG public key (from its own keypair).
#   PEER_WG_IP     — the wg-subnet IP to assign the peer, e.g. 10.0.0.X/32.
#   PEER_LABEL     — short human label for the comment line (e.g. "phone").
#
# See docs/2026-05-31-wireguard-away-phone.org for the larger setup runbook.

set -euo pipefail

PEER_PUBKEY="${PEER_PUBKEY:?PEER_PUBKEY is required (set via Make var)}"
PEER_WG_IP="${PEER_WG_IP:?PEER_WG_IP is required (e.g. 10.0.0.X/32)}"
PEER_LABEL="${PEER_LABEL:-new peer}"
WG_CONF='/etc/wireguard/wg0.conf'

# --- safety guard: refuse to run anywhere that isn't the WG server -----------
if ! sudo test -f "$WG_CONF"; then
  cat >&2 <<MSG
ERROR: $WG_CONF not found on this host.

server-add-peer.sh edits the WG SERVER's config and reloads its wg0 interface.
It will NOT work on a client peer (the phone, a laptop) — those only have
their own private conf, not the server's.  Run this on the dev box that runs
the WG listener.
MSG
  exit 2
fi
if ! ip link show wg0 >/dev/null 2>&1; then
  echo "ERROR: wg0 interface not present — is this really the WG server?" >&2
  exit 2
fi

# --- 1) idempotency: skip if the pubkey is already in the conf ---------------
if sudo grep -qF "$PEER_PUBKEY" "$WG_CONF"; then
  echo "[skip] peer $PEER_LABEL ($PEER_PUBKEY) already in $WG_CONF"
else
  echo "[add]  appending peer $PEER_LABEL ($PEER_WG_IP) to $WG_CONF"
  sudo tee -a "$WG_CONF" >/dev/null <<PEER

[Peer]
# $PEER_LABEL — added $(date -Is)
PublicKey = $PEER_PUBKEY
AllowedIPs = $PEER_WG_IP
PEER
fi

# --- 2) live-reload wg0 (preserves other peers' handshakes) ------------------
# `wg syncconf` reads the desired state and applies the delta to the running
# interface, leaving existing peers untouched.  Much safer than `wg-quick
# down/up`, which would drop every peer including the operator's laptop.
echo "[reload] wg syncconf wg0"
sudo bash -c 'wg syncconf wg0 <(wg-quick strip wg0)'

# --- 3) verify ---------------------------------------------------------------
echo "[verify] wg show wg0 — new peer block:"
sudo wg show wg0 | grep -A 3 "$PEER_PUBKEY" || echo "       (peer not shown — investigate before declaring success)"
