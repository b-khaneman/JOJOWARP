#!/usr/bin/env bash
# Apply / remove JOJOWARP kernel routes (wg-quick PostUp/PostDown)
set -euo pipefail

IFACE="${AI_WARP_IFACE:-aiwarp}"
CIDR_FILE="${AI_WARP_CIDR_FILE:-/etc/ai-warp/allowed-ips.txt}"
CIDR6_FILE="${AI_WARP_CIDR6_FILE:-/etc/ai-warp/allowed-ips-v6.txt}"
TABLE="${AI_WARP_TABLE:-51821}"
CHAIN="AIWARP6"

action="${1:-up}"

host_has_global_ipv6() {
  ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'
}

iface_has_v6() {
  ip -6 addr show dev "$IFACE" scope global 2>/dev/null | grep -q 'inet6'
}

iter_v6_cidrs() {
  local cidr
  if [[ -s "$CIDR6_FILE" ]]; then
    while IFS= read -r cidr; do
      [[ -z "$cidr" ]] && continue
      printf '%s\n' "$cidr"
    done <"$CIDR6_FILE"
  fi
  # Canaries — Google AI / DNS (cover Hetzner static defaults)
  printf '%s\n' \
    '2001:4860::/32' \
    '2607:f8b0::/32' \
    '2404:6800::/32' \
    '2404:f340::/32' \
    '2a00:1450::/32' \
    '2600:1900::/28' \
    '2620:0:1000::/40' \
    '2800:3f0::/32' \
    '2c0f:fb50::/32'
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

# ip6tables beats Hetzner source-based / proto-static IPv6 defaults.
ensure_ip6_chain() {
  command -v ip6tables >/dev/null 2>&1 || return 1
  ip6tables -N "$CHAIN" 2>/dev/null || ip6tables -F "$CHAIN" 2>/dev/null || return 1
  ip6tables -C OUTPUT -j "$CHAIN" 2>/dev/null || ip6tables -I OUTPUT -j "$CHAIN"
  ip6tables -C FORWARD -j "$CHAIN" 2>/dev/null || ip6tables -I FORWARD -j "$CHAIN"
  return 0
}

flush_ip6_chain() {
  command -v ip6tables >/dev/null 2>&1 || return 0
  ip6tables -F "$CHAIN" 2>/dev/null || true
  ip6tables -D OUTPUT -j "$CHAIN" 2>/dev/null || true
  ip6tables -D FORWARD -j "$CHAIN" 2>/dev/null || true
  ip6tables -X "$CHAIN" 2>/dev/null || true
}

add_v6_filter() {
  local cidr ok=0 fail=0
  ensure_ip6_chain || { echo "ai-warp ip6tables: unavailable"; return 0; }
  while IFS= read -r cidr; do
    [[ -z "$cidr" ]] && continue
    if ip6tables -A "$CHAIN" -d "$cidr" -j REJECT --reject-with icmp6-addr-unreachable 2>/dev/null; then
      ok=$((ok + 1))
    else
      fail=$((fail + 1))
    fi
  done < <(iter_v6_cidrs | sort -u)
  echo "ai-warp ip6tables v6 reject: ok=${ok} fail=${fail}"
}

add_v6() {
  if ! host_has_global_ipv6 && ! iface_has_v6; then
    echo "ai-warp routes v6: skipped (no global IPv6 on host)"
    return 0
  fi

  local cidr ok=0 fail=0 mode="via-warp"
  if iface_has_v6; then
    sysctl -w "net.ipv6.conf.${IFACE}.disable_ipv6=0" >/dev/null 2>&1 || true
    ip -6 route replace default dev "$IFACE" table "$TABLE" metric 1 2>/dev/null \
      || ip -6 route add default dev "$IFACE" table "$TABLE" metric 1 2>/dev/null \
      || true
    while IFS= read -r cidr; do
      [[ -z "$cidr" ]] && continue
      if ip -6 route replace "$cidr" dev "$IFACE" metric 1 2>/dev/null \
        || ip -6 route add "$cidr" dev "$IFACE" metric 1 2>/dev/null; then
        ok=$((ok + 1))
      else
        fail=$((fail + 1))
      fi
    done < <(iter_v6_cidrs | sort -u)
  else
    mode="unreachable"
    while IFS= read -r cidr; do
      [[ -z "$cidr" ]] && continue
      if ip -6 route replace unreachable "$cidr" metric 1 2>/dev/null \
        || ip -6 route add unreachable "$cidr" metric 1 2>/dev/null; then
        ok=$((ok + 1))
      else
        fail=$((fail + 1))
      fi
    done < <(iter_v6_cidrs | sort -u)
  fi
  echo "ai-warp routes v6 (${mode}): ok=${ok} fail=${fail}"
  add_v6_filter
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
  local cidr
  while IFS= read -r cidr; do
    [[ -z "$cidr" ]] && continue
    ip -6 route del "$cidr" dev "$IFACE" 2>/dev/null || true
    ip -6 route del unreachable "$cidr" 2>/dev/null || true
  done < <(iter_v6_cidrs | sort -u)
  ip -6 route flush table "$TABLE" 2>/dev/null || true
  flush_ip6_chain
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
