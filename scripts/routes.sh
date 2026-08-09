#!/usr/bin/env bash
# Apply / remove JOJOWARP kernel routes (wg-quick PostUp/PostDown)
set -euo pipefail

IFACE="${AI_WARP_IFACE:-aiwarp}"
CIDR_FILE="${AI_WARP_CIDR_FILE:-/etc/ai-warp/allowed-ips.txt}"
CIDR6_FILE="${AI_WARP_CIDR6_FILE:-/etc/ai-warp/allowed-ips-v6.txt}"
TABLE="${AI_WARP_TABLE:-51821}"

action="${1:-up}"

host_ipv6_enabled() {
  local all def
  [[ -e /proc/net/if_inet6 ]] || return 1
  all="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 1)"
  def="$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || echo 1)"
  [[ "$all" == "0" && "$def" == "0" ]]
}

iface_has_v6() {
  host_ipv6_enabled || return 1
  ip -6 addr show dev "$IFACE" scope global >/dev/null 2>&1 \
    && ip -6 addr show dev "$IFACE" scope global | grep -q 'inet6'
}

add_v4() {
  [[ -f "$CIDR_FILE" ]] || { echo "missing $CIDR_FILE" >&2; exit 1; }
  ip link show "$IFACE" >/dev/null

  sysctl -w "net.ipv4.conf.${IFACE}.rp_filter=0" >/dev/null 2>&1 || true

  ip route replace default dev "$IFACE" table "$TABLE" 2>/dev/null \
    || ip route add default dev "$IFACE" table "$TABLE" 2>/dev/null \
    || true

  local cidr ok=0 fail=0
  while IFS= read -r cidr; do
    [[ -z "$cidr" ]] && continue
    if ip route replace "$cidr" dev "$IFACE" 2>/dev/null \
      || ip route add "$cidr" dev "$IFACE" 2>/dev/null; then
      ok=$((ok + 1))
    else
      fail=$((fail + 1))
    fi
  done <"$CIDR_FILE"
  echo "ai-warp routes v4: ok=${ok} fail=${fail}"
}

add_v6() {
  if ! host_ipv6_enabled; then
    echo "ai-warp routes v6: skipped (IPv6 disabled on host)"
    return 0
  fi
  [[ -s "$CIDR6_FILE" ]] || return 0

  local cidr ok=0 fail=0 mode="via-warp"
  if iface_has_v6; then
    sysctl -w "net.ipv6.conf.${IFACE}.disable_ipv6=0" >/dev/null 2>&1 || true
    ip -6 route replace default dev "$IFACE" table "$TABLE" 2>/dev/null \
      || ip -6 route add default dev "$IFACE" table "$TABLE" 2>/dev/null \
      || true
    while IFS= read -r cidr; do
      [[ -z "$cidr" ]] && continue
      if ip -6 route replace "$cidr" dev "$IFACE" 2>/dev/null \
        || ip -6 route add "$cidr" dev "$IFACE" 2>/dev/null; then
        ok=$((ok + 1))
      else
        fail=$((fail + 1))
      fi
    done <"$CIDR6_FILE"
  else
    # No WARP IPv6 — blackhole so Happy Eyeballs falls back to IPv4 via WARP.
    mode="unreachable"
    while IFS= read -r cidr; do
      [[ -z "$cidr" ]] && continue
      if ip -6 route replace unreachable "$cidr" 2>/dev/null \
        || ip -6 route add unreachable "$cidr" 2>/dev/null; then
        ok=$((ok + 1))
      else
        fail=$((fail + 1))
      fi
    done <"$CIDR6_FILE"
  fi
  echo "ai-warp routes v6 (${mode}): ok=${ok} fail=${fail}"
}

del_v4() {
  local cidr
  if [[ -f "$CIDR_FILE" ]]; then
    while IFS= read -r cidr; do
      [[ -z "$cidr" ]] && continue
      ip route del "$cidr" dev "$IFACE" 2>/dev/null || true
    done <"$CIDR_FILE"
  fi
  ip route flush table "$TABLE" 2>/dev/null || true
}

del_v6() {
  host_ipv6_enabled || return 0
  local cidr
  if [[ -f "$CIDR6_FILE" ]]; then
    while IFS= read -r cidr; do
      [[ -z "$cidr" ]] && continue
      ip -6 route del "$cidr" dev "$IFACE" 2>/dev/null || true
      ip -6 route del unreachable "$cidr" 2>/dev/null || true
    done <"$CIDR6_FILE"
  fi
  ip -6 route flush table "$TABLE" 2>/dev/null || true
}

case "$action" in
  up)
    add_v4
    add_v6
    ;;
  down)
    del_v4
    del_v6
    ;;
  *)
    echo "usage: $0 up|down" >&2
    exit 1
    ;;
esac
