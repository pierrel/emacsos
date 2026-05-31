#!/usr/bin/env bash
# cell-validate.sh — deterministically check that the internet is reachable.
# Prints [PASS]/[FAIL] per axis (DNS, IPv4, IPv6) + a final OVERALL line.
# Exit 0 if "DNS works AND at least one of IPv4/IPv6 reaches a public host."
# Designed to be invoked by the bot via:
#   (shell-command-to-string "bash ~/playground/cell-validate.sh")
# so the output is grep-able and the exit code is meaningful.

set -u
TIMEOUT=5
declare -i dns_ok=0 v4_ok=0 v6_ok=0

# Default route + carrier (informational; not part of PASS/FAIL).
route=$(ip -o -4 route show default 2>/dev/null | head -1)
[ -z "$route" ] && route=$(ip -o -6 route show default 2>/dev/null | head -1)
iface=$(printf '%s' "$route" | sed -n 's#.* dev \([a-zA-Z0-9]*\).*#\1#p')
case "$iface" in
  wl*) carrier=wifi ;;
  ww*) carrier=cell ;;
  "")  carrier=none ;;
  *)   carrier="$iface" ;;
esac
echo "[INFO] default route via: ${iface:-none} (${carrier})"

if getent ahosts example.com >/dev/null 2>&1; then
  echo "[PASS] DNS: example.com resolves"; dns_ok=1
else
  echo "[FAIL] DNS: example.com does not resolve"
fi

if curl -sS --max-time "$TIMEOUT" -4 -o /dev/null https://1.1.1.1/ 2>/dev/null; then
  echo "[PASS] IPv4: https://1.1.1.1 reachable"; v4_ok=1
else
  echo "[FAIL] IPv4: https://1.1.1.1 not reachable (T-Mobile cellular is IPv6-only without CLAT)"
fi

if curl -sS --max-time "$TIMEOUT" -6 -o /dev/null "https://[2606:4700:4700::1111]/" 2>/dev/null; then
  echo "[PASS] IPv6: https://[2606:4700:4700::1111] reachable"; v6_ok=1
else
  echo "[FAIL] IPv6: https://[2606:4700:4700::1111] not reachable"
fi

if (( dns_ok == 1 && (v4_ok == 1 || v6_ok == 1) )); then
  echo "OVERALL: PASS  (carrier=${carrier}; v4=${v4_ok}; v6=${v6_ok}; dns=ok)"
  exit 0
else
  echo "OVERALL: FAIL  (carrier=${carrier}; v4=${v4_ok}; v6=${v6_ok}; dns=${dns_ok})"
  exit 1
fi
