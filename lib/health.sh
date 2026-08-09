#!/usr/bin/env bash
# Health checks + watchdog actions
# shellcheck shell=bash

ai_iface_up() {
  ip link show "${AI_WARP_IFACE}" >/dev/null 2>&1
}

# Handshake is OK if unix timestamp is within the last 3 minutes.
ai_handshake_ok() {
  local hs now age
  hs="$(wg show "${AI_WARP_IFACE}" latest-handshakes 2>/dev/null | awk 'NF>=2 {print $NF; exit}')"
  if [[ -z "$hs" || "$hs" == "0" ]]; then
    return 1
  fi
  now="$(date +%s)"
  age=$((now - hs))
  (( age >= 0 && age < 180 ))
}

ai_google_routed() {
  ip route get 8.8.8.8 2>/dev/null | grep -q "dev ${AI_WARP_IFACE}"
}

# Leak = host has global IPv6 and Google v6 still exits via a non-WARP iface.
ai_google_v6_leaking() {
  ai_host_has_global_ipv6 || return 1
  local out
  out="$(ip -6 route get 2001:4860:4860::8888 2>/dev/null || true)"
  [[ -n "$out" ]] || return 1
  echo "$out" | grep -q "dev ${AI_WARP_IFACE}" && return 1
  echo "$out" | grep -Eiq 'unreachable|prohibit|blackhole' && return 1
  if command -v ip6tables >/dev/null 2>&1 && ip6tables -L AIWARP6 >/dev/null 2>&1; then
    return 1
  fi
  echo "$out" | grep -Eq 'dev (eth|ens|enp|eno)' && return 0
  return 1
}

ai_healthcheck() {
  local rc=0
  echo "=== ${AI_WARP_NAME} health ==="
  echo "version : ${AI_WARP_VERSION}"
  echo "iface   : ${AI_WARP_IFACE}"
  echo "mode    : $(cat "${AI_WARP_MODE_FILE}" 2>/dev/null || echo —)"
  echo "conf    : ${AI_WARP_WG_CONF}"
  echo "endpoint: $(cat "${AI_WARP_ENDPOINT_FILE}" 2>/dev/null || echo —)"
  echo

  if ai_iface_up; then
    ai_log "interface: UP"
  else
    ai_err "interface: DOWN"
    rc=1
  fi

  if systemctl is-active --quiet "wg-quick@${AI_WARP_IFACE}" 2>/dev/null; then
    ai_log "systemd wg-quick@${AI_WARP_IFACE}: active"
  else
    ai_warn "systemd wg-quick@${AI_WARP_IFACE}: inactive"
    if ! ai_iface_up; then
      rc=1
    fi
  fi

  if systemctl is-active --quiet ai-warp-watchdog.timer 2>/dev/null; then
    ai_log "watchdog timer: active"
  else
    ai_warn "watchdog timer: inactive"
  fi

  echo
  if ai_iface_up; then
    wg show "${AI_WARP_IFACE}" 2>/dev/null || true
  fi
  echo
  echo "--- sample routes ---"
  ip route get 8.8.8.8 2>/dev/null || true
  ip route get 142.250.0.1 2>/dev/null || true
  if ai_have ip; then
    ip -6 route get 2001:4860:4860::8888 2>/dev/null || true
  fi
  echo

  if ai_handshake_ok; then
    ai_log "handshake: OK (<3m)"
  else
    ai_warn "handshake: missing/stale"
    rc=1
  fi

  if ai_google_routed; then
    ai_log "Google path via ${AI_WARP_IFACE}: OK"
  else
    ai_warn "Google path NOT via ${AI_WARP_IFACE}"
    rc=1
  fi

  if ai_google_v6_leaking; then
    ai_warn "IPv6 Google path leaks via eth (not WARP) — run: sudo jojowarp refresh"
    rc=1
  elif ai_host_has_global_ipv6; then
    ai_log "IPv6 AI leak: blocked (unreachable or via ${AI_WARP_IFACE})"
  fi

  if ai_warp_trace_on; then
    ai_log "cloudflare trace: warp=on"
  else
    ai_warn "cloudflare trace: warp≠on"
    rc=1
  fi

  echo
  ai_sticky_status || true
  echo
  if [[ -f "${AI_WARP_CIDR_FILE}" ]]; then
    echo "IPv4 CIDRs routed: $(wc -l <"${AI_WARP_CIDR_FILE}" | tr -d ' ')"
  fi
  if [[ -f "${AI_WARP_CIDR6_FILE}" ]]; then
    echo "IPv6 CIDRs routed: $(wc -l <"${AI_WARP_CIDR6_FILE}" | tr -d ' ')"
  fi
  return "$rc"
}

ai_restart_tunnel_quiet() {
  wg-quick down "${AI_WARP_IFACE}" 2>/dev/null || true
  if systemctl list-units >/dev/null 2>&1; then
    systemctl restart "wg-quick@${AI_WARP_IFACE}" 2>/dev/null \
      || wg-quick up "${AI_WARP_IFACE}" 2>/dev/null || true
  else
    wg-quick up "${AI_WARP_IFACE}" 2>/dev/null || true
  fi
}

ai_watchdog_tick() {
  local new_ep

  if ! ai_iface_up || ! ai_handshake_ok; then
    logger -t ai-warp "watchdog: tunnel unhealthy — restarting"
    ai_restart_tunnel_quiet
    sleep 3
  fi

  if ai_iface_up && ! ai_handshake_ok; then
    new_ep="$(ai_rotate_endpoint)"
    logger -t ai-warp "watchdog: rotating WARP endpoint → ${new_ep}"
    ai_set_wg_endpoint "$new_ep" || true
    ai_restart_tunnel_quiet
    sleep 3
  fi

  if ai_iface_up && ! ai_google_routed; then
    logger -t ai-warp "watchdog: routes missing — re-applying"
    "${AI_WARP_SHARE}/scripts/routes.sh" up 2>/dev/null || true
  fi

  if ai_iface_up && ! ai_warp_trace_on; then
    logger -t ai-warp "watchdog: warp≠on — restarting tunnel"
    ai_restart_tunnel_quiet
    sleep 2
    "${AI_WARP_SHARE}/scripts/routes.sh" up 2>/dev/null || true
  fi

  ai_sticky_save >/dev/null 2>&1 || true
}
