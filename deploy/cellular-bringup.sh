#!/usr/bin/env bash
# cellular-bringup.sh — provision a SIM7600G-H 4G HAT for cellular DATA on
# the emacsos phone.  Run ON THE PHONE, as root.  The `cellular-bringup`
# Makefile target pushes this here and runs it; you normally don't invoke
# it by hand.  See docs/2026-05-26-cellular-data-connectivity.org.
#
# Division of labour: ModemManager owns the MODEM (registration, signal,
# the data bearer — and, later, SMS/voice); NetworkManager owns the
# CONNECTION + route/failover policy and activates the bearer through MM.
# We drive both via their CLIs (nmcli/mmcli) — never hand-rolled AT.
#
# Parameters arrive as KEY=VALUE lines on STDIN — never argv/env, so a
# carrier password can't leak into the phone's process table:
#     APN=<carrier-apn>      (required)
#     APN_USER=<user>        (optional — only if the carrier needs PAP/CHAP)
#     APN_PASS=<pass>        (optional)
#
# Idempotent: re-running converges the NM connection + failover policy to
# the desired state (add-or-modify, write-if-absent).  Deliberately does
# NOT: touch wwan0/qmi/raw_ip (that is ModemManager's job on the QMI path,
# and poking it manually reintroduces a boot-ordering race), compile a
# vendor driver, or run raw AT.  The qmicli break-glass path and the
# one-time `AT+CNMP=38` LTE fallback live in the doc's runbook as manual
# steps, not here — they are operator-judgement, not re-runnable config.

set -uo pipefail

CON_NAME="emacsos-cellular"
CONNECTIVITY_CONF="/etc/NetworkManager/conf.d/20-emacsos-connectivity.conf"
# Base metrics decide the winner only when BOTH links have connectivity
# (i.e. "prefer wifi at home").  Failover itself is driven by the
# connectivity check (step 5), which adds +20000 to a link that fails its
# probe — that swing, not this gap, is what flips the default route.
WIFI_METRIC=100
CELL_METRIC=700

die()  { echo "cellular-bringup: error: $*" >&2; exit 1; }
note() { echo "cellular-bringup: $*"; }

# --- read KEY=VALUE params from stdin -------------------------------------
APN=""; APN_USER=""; APN_PASS=""
# `|| [ -n "$key" ]` so a final line with no trailing newline (e.g. an
# APN_AUTH_FILE ending without one) is still processed, not silently dropped.
while IFS='=' read -r key val || [ -n "$key" ]; do
  case "$key" in
    APN)      APN=$val ;;
    APN_USER) APN_USER=$val ;;
    APN_PASS) APN_PASS=$val ;;
    "")       : ;;  # blank line
    *)        note "ignoring unknown parameter: $key" ;;
  esac
done

[ -n "$APN" ]        || die "APN is required (pipe 'APN=<carrier-apn>' on stdin)"
[ "$(id -u)" -eq 0 ] || die "must run as root (NetworkManager/ModemManager config)"
command -v nmcli >/dev/null 2>&1 || die "nmcli not found — install network-manager"
command -v mmcli >/dev/null 2>&1 || die "mmcli not found — install modemmanager"

# --- 1. modem present, in QMI mode (in-kernel qmi_wwan, NOT RNDIS) --------
if ! lsmod | grep -q '^qmi_wwan'; then
  note "WARN: qmi_wwan not loaded — the HAT may be in RNDIS mode (which fights"
  note "      NetworkManager) or absent.  See the runbook's 'QMI vs RNDIS' note."
fi

# --- 2. ModemManager enumerates the modem? --------------------------------
# "No modem" is treated as a hard stop, not an auto-fallback: the modem may
# still be enumerating (retry in a few seconds), or MM may have failed to
# bind it (a known Bookworm risk) — in which case the qmicli break-glass
# path in the runbook applies, and this NM-based failover does NOT.
MODEM_IDX=$(mmcli -L 2>/dev/null | sed -n 's#.*/Modem/\([0-9][0-9]*\).*#\1#p' | head -1)
[ -n "$MODEM_IDX" ] || die "ModemManager sees no modem (mmcli -L is empty).
      Retry shortly (modem may still be enumerating).  If it never appears,
      use the qmicli break-glass path in the doc's runbook — NM failover does
      not apply on that path."
note "modem present at ModemManager index $MODEM_IDX"

# --- 3. NetworkManager gsm connection (add-or-modify; idempotent) ---------
# `ifname '*'` binds the ModemManager-discovered modem (its control plane is
# /dev/cdc-wdm0); NM/MM pick the wwan data netdev themselves.  Do NOT pin
# `ifname wwan0` — a gsm connection binds the modem, not the netdev.
CON_ARGS=(
  gsm.apn "$APN"
  connection.autoconnect yes
  connection.autoconnect-priority 10
  ipv4.route-metric "$CELL_METRIC"
  ipv6.route-metric "$CELL_METRIC"
)
if nmcli -t -f NAME con show | grep -qx "$CON_NAME"; then
  note "connection '$CON_NAME' exists — updating"
  nmcli con modify "$CON_NAME" "${CON_ARGS[@]}" || die "nmcli con modify failed"
else
  note "creating connection '$CON_NAME'"
  nmcli con add type gsm ifname '*' con-name "$CON_NAME" "${CON_ARGS[@]}" \
    || die "nmcli con add failed"
fi

# Carrier auth only when supplied (most consumer/MVNO SIMs need none).
if [ -n "$APN_USER" ] || [ -n "$APN_PASS" ]; then
  note "setting carrier auth (operator supplied)"
  nmcli con modify "$CON_NAME" gsm.username "$APN_USER" gsm.password "$APN_PASS" \
    || die "nmcli con modify (auth) failed"
fi

# --- 4. prefer wifi at home (lower metric than cell) ----------------------
# TYPE first so the (colon-free) type is the reliably-split field and the
# connection NAME is the remainder.  A wifi profile whose NAME contains a
# literal colon (rare) keeps nmcli's `\:` escaping and won't match the
# modify — it just keeps its default metric (non-fatal; the connectivity
# check still drives failover).
while IFS=: read -r ctype name; do
  [ "$ctype" = "802-11-wireless" ] || continue
  if nmcli con modify "$name" ipv4.route-metric "$WIFI_METRIC" 2>/dev/null; then
    note "wifi '$name' route-metric -> $WIFI_METRIC"
  fi
done < <(nmcli -t -f TYPE,NAME con show)

# --- 5. connectivity check (drives failover both directions) --------------
# Write-if-absent: a re-run is a no-op, and we never clobber an operator edit.
if [ -f "$CONNECTIVITY_CONF" ]; then
  note "$CONNECTIVITY_CONF already present — leaving as-is"
else
  note "writing $CONNECTIVITY_CONF"
  cat > "$CONNECTIVITY_CONF" <<'EOF'
# emacsos: enable NetworkManager connectivity checking so a wifi link that
# is associated-but-dead (captive portal / dead gateway) has its default
# route demoted (+20000) and the cellular route takes over — restored
# automatically when wifi regains real connectivity.  Adjust uri/response
# per distro if NM reports limited connectivity on a healthy link.
[connectivity]
uri=http://network-test.debian.org/nm
interval=300
EOF
  nmcli general reload 2>/dev/null || systemctl reload NetworkManager 2>/dev/null || true
fi

# --- 6. LTE preference (idempotent; persists in modem NVRAM) --------------
# mmcli is the idiomatic lever.  If it won't stick on this firmware, the
# runbook has the one-time raw `AT+CNMP=38` fallback (run with MM stopped so
# it isn't fighting MM for the AT port).  3G is being sunset in many markets.
if mmcli -m "$MODEM_IDX" --set-current-modes='4g' >/dev/null 2>&1 \
   || mmcli -m "$MODEM_IDX" --set-current-capabilities='lte' >/dev/null 2>&1; then
  note "LTE preference set on modem $MODEM_IDX"
else
  note "WARN: could not set LTE mode via mmcli — see runbook's AT+CNMP=38 fallback"
fi

# --- 7. bring up + report end state ---------------------------------------
# `con up` reactivates so a re-run's modified metrics/APN take effect on the
# running connection, not just the stored profile.
nmcli con up "$CON_NAME" >/dev/null 2>&1 \
  || note "WARN: 'nmcli con up $CON_NAME' did not complete (modem may still be registering)"

note "----- end state -----"
nmcli -t -f NAME,TYPE,DEVICE con show --active 2>/dev/null | sed 's/^/cellular-bringup:   active /'
ip route 2>/dev/null | sed 's/^/cellular-bringup:   route  /'
note "done.  Verify failover with wifi off — see the doc's runbook."
