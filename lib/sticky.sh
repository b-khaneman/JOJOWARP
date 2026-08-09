#!/usr/bin/env bash
# Sticky / stable egress IP helpers for JOJOWARP
# shellcheck shell=bash

ai_warp_egress_ip() {
  local ip=""
  if ip link show "${AI_WARP_IFACE}" >/dev/null 2>&1; then
    ip="$(
      curl -4 -fsS --max-time 8 --interface "${AI_WARP_IFACE}" \
        https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
        | awk -F= '/^ip=/{print $2; exit}'
    )"
    [[ -z "$ip" ]] && ip="$(curl -4 -fsS --max-time 8 --interface "${AI_WARP_IFACE}" https://api.ipify.org 2>/dev/null || true)"
    [[ -z "$ip" ]] && ip="$(curl -4 -fsS --max-time 8 --interface "${AI_WARP_IFACE}" https://ifconfig.me 2>/dev/null || true)"
  fi
  if [[ -z "$ip" ]]; then
    ip="$(
      curl -4 -fsS --max-time 8 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
        | awk -F= '/^ip=/{print $2; exit}'
    )"
  fi
  echo "$ip"
}

ai_warp_trace_on() {
  ip link show "${AI_WARP_IFACE}" >/dev/null 2>&1 || return 1
  curl -4 -fsS --max-time 8 --interface "${AI_WARP_IFACE}" \
    https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
    | grep -qx 'warp=on'
}

ai_sticky_save() {
  local ip force="${1:-}"
  ip="$(ai_warp_egress_ip)"
  if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    umask 077
    echo "$ip" >"${AI_WARP_LAST_IP}"
    if [[ "$force" == "force" || ! -s "${AI_WARP_STICKY_IP}" ]]; then
      echo "$ip" >"${AI_WARP_STICKY_IP}"
      ai_log "Sticky IP locked: ${ip}"
    fi
    echo "$ip"
    return 0
  fi
  ai_warn "Could not detect WARP egress IP."
  return 1
}

ai_sticky_status() {
  local sticky last current
  sticky="$(cat "${AI_WARP_STICKY_IP}" 2>/dev/null || true)"
  last="$(cat "${AI_WARP_LAST_IP}" 2>/dev/null || true)"
  current="$(ai_warp_egress_ip || true)"

  echo "sticky : ${sticky:-—}"
  echo "last   : ${last:-—}"
  echo "current: ${current:-—}"

  if ai_warp_trace_on; then
    ai_log "WARP trace: warp=on"
  else
    ai_warn "WARP trace: warp≠on (tunnel may not be carrying traffic)"
  fi

  if [[ -n "$sticky" && -n "$current" && "$sticky" == "$current" ]]; then
    ai_log "Egress IP is STABLE (matches sticky lock)."
    return 0
  elif [[ -n "$sticky" && -n "$current" ]]; then
    ai_warn "Egress IP changed: sticky=${sticky} current=${current}"
    ai_warn "Free WARP may rotate IPs. Account identity stays the same."
    return 1
  fi
  return 0
}

ai_sticky_relock() {
  ai_sticky_save force
}
