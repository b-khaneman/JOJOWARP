#!/usr/bin/env bash
# wgcf account + WireGuard profile management
# shellcheck shell=bash

ai_discover_endpoint() {
  local ip resolver host="${AI_WARP_ENDPOINT_HOST}"
  if [[ -n "${AI_WARP_ENDPOINT_IP:-}" ]]; then
    echo "${AI_WARP_ENDPOINT_IP}"
    return 0
  fi
  if [[ -s "${AI_WARP_ENDPOINT_FILE}" ]]; then
    ip="$(tr -d '[:space:]' <"${AI_WARP_ENDPOINT_FILE}")"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$ip"
      return 0
    fi
  fi
  if ai_have dig; then
    for resolver in 1.1.1.1 8.8.8.8 9.9.9.9; do
      ip="$(dig +short +time=2 +tries=1 A "$host" "@${resolver}" 2>/dev/null | grep -E '^[0-9.]+$' | head -1)"
      if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ip"
        return 0
      fi
    done
  fi
  if ai_have getent; then
    ip="$(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1; exit}')"
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
      echo "$ip"
      return 0
    fi
  fi
  echo "${AI_WARP_ENDPOINT_FALLBACK}"
}

ai_rotate_endpoint() {
  local current candidates c
  current="$(tr -d '[:space:]' <"${AI_WARP_ENDPOINT_FILE}" 2>/dev/null || true)"
  candidates=(
    162.159.192.1
    162.159.193.1
    162.159.195.1
    162.159.192.2
    162.159.193.2
  )
  for c in "${candidates[@]}"; do
    if [[ "$c" != "$current" ]]; then
      echo "$c"
      return 0
    fi
  done
  echo "${AI_WARP_ENDPOINT_FALLBACK}"
}

ai_save_endpoint() {
  local ip="$1"
  umask 077
  install -d -m700 "${AI_WARP_STATE}"
  echo "$ip" >"${AI_WARP_ENDPOINT_FILE}"
}

ai_register_warp() {
  install -d -m700 "${AI_WARP_STATE}"
  install -d -m755 "${AI_WARP_WG_DIR}"

  if [[ -s "${AI_WARP_ACCOUNT}" ]]; then
    ai_log "Reusing persistent WARP account (stable identity)."
  else
    ai_info "Registering free Cloudflare WARP account…"
    if ! (
      cd "${AI_WARP_STATE}"
      "${AI_WARP_WGCF}" register --accept-tos
    ); then
      ai_fail "WARP registration failed. Ensure api.cloudflareclient.com is reachable from this Kharej server."
    fi
    [[ -s "${AI_WARP_ACCOUNT}" ]] || ai_fail "WARP registration failed (no account file)."
    ai_log "Account created and persisted at ${AI_WARP_ACCOUNT}"
  fi

  if [[ -n "${AI_WARP_LICENSE:-${JOJONET_WARP_LICENSE:-}}" ]]; then
    local lic="${AI_WARP_LICENSE:-${JOJONET_WARP_LICENSE}}"
    ai_info "Applying WARP+ license…"
    (
      cd "${AI_WARP_STATE}"
      "${AI_WARP_WGCF}" update --license-key "$lic" \
        || ai_warn "License update failed — continuing with free WARP."
    )
  fi

  ai_info "Generating WireGuard profile…"
  (
    cd "${AI_WARP_STATE}"
    "${AI_WARP_WGCF}" generate >/dev/null
    if [[ -f wgcf-profile.conf && ! -f "${AI_WARP_PROFILE}" ]]; then
      cp -f wgcf-profile.conf "${AI_WARP_PROFILE}"
    elif [[ -f wgcf-profile.conf ]]; then
      if ai_have realpath; then
        [[ "$(realpath -m wgcf-profile.conf)" == "$(realpath -m "${AI_WARP_PROFILE}")" ]] \
          || cp -f wgcf-profile.conf "${AI_WARP_PROFILE}"
      else
        cp -f wgcf-profile.conf "${AI_WARP_PROFILE}"
      fi
    fi
  )
  [[ -s "${AI_WARP_PROFILE}" ]] || ai_fail "Profile generation failed."
}

ai_extract_keys() {
  AI_WARP_PRIVATE_KEY="$(awk -F' = ' '/^PrivateKey/{print $2; exit}' "${AI_WARP_PROFILE}")"
  AI_WARP_PEER_KEY="$(awk -F' = ' '/^PublicKey/{print $2; exit}' "${AI_WARP_PROFILE}")"
  local addr
  addr="$(awk -F' = ' '/^Address/{print $2; exit}' "${AI_WARP_PROFILE}")"
  AI_WARP_ADDRESS_V4="$(echo "$addr" | tr ',' '\n' | awk '/\./ && $0 !~ /:/{gsub(/ /,""); print; exit}')"
  AI_WARP_ADDRESS_V6="$(echo "$addr" | tr ',' '\n' | awk '/:/{gsub(/ /,""); print; exit}')"
  [[ -n "${AI_WARP_PRIVATE_KEY}" && -n "${AI_WARP_PEER_KEY}" ]] \
    || ai_fail "Cannot read WireGuard keys from profile."
  [[ -n "${AI_WARP_ADDRESS_V4}" ]] || AI_WARP_ADDRESS_V4="172.16.0.2/32"
}

ai_write_wg_conf() {
  local endpoint addr_line allowed note
  ai_extract_keys
  endpoint="$(ai_discover_endpoint)"
  ai_save_endpoint "$endpoint"

  if [[ -n "${AI_WARP_ADDRESS_V6:-}" ]] && ai_host_ipv6_enabled; then
    addr_line="${AI_WARP_ADDRESS_V4}, ${AI_WARP_ADDRESS_V6}"
    allowed="0.0.0.0/0, ::/0"
    note="IPv4+IPv6"
  else
    addr_line="${AI_WARP_ADDRESS_V4}"
    allowed="0.0.0.0/0"
    note="IPv4-only"
    if [[ -n "${AI_WARP_ADDRESS_V6:-}" ]]; then
      ai_warn "Host IPv6 is disabled — WARP tunnel will be IPv4-only (OK for AI unlock)."
    fi
  fi

  umask 077
  cat >"${AI_WARP_WG_CONF}" <<EOF
# ${AI_WARP_NAME} v${AI_WARP_VERSION} — generated $(date -u +%Y-%m-%dT%H:%M:%SZ)
# Table=off → no default-route hijack. Selective AI routes via PostUp.
# Mode: ${note}

[Interface]
PrivateKey = ${AI_WARP_PRIVATE_KEY}
Address = ${addr_line}
MTU = ${AI_WARP_MTU}
Table = off
PostUp = ${AI_WARP_SHARE}/scripts/routes.sh up
PostDown = ${AI_WARP_SHARE}/scripts/routes.sh down

[Peer]
PublicKey = ${AI_WARP_PEER_KEY}
AllowedIPs = ${allowed}
Endpoint = ${endpoint}:${AI_WARP_ENDPOINT_PORT}
PersistentKeepalive = ${AI_WARP_KEEPALIVE}
EOF
  chmod 600 "${AI_WARP_WG_CONF}"
  ai_log "WireGuard config: ${AI_WARP_WG_CONF} (endpoint ${endpoint}, ${note})"
}

# If wg-quick aborted because IPv6 is off, rewrite Address/AllowedIPs to v4-only.
ai_strip_wg_ipv6() {
  [[ -f "${AI_WARP_WG_CONF}" ]] || return 1
  sed -i -E \
    -e 's/^(Address = [^,[:space:]]+),[[:space:]]*[^,[:space:]]+:.*$/\1/' \
    -e 's|^(AllowedIPs = )0\.0\.0\.0/0, ::/0$|\10.0.0.0/0|' \
    "${AI_WARP_WG_CONF}"
}

ai_set_wg_endpoint() {
  local ip="$1"
  [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  ai_save_endpoint "$ip"
  if [[ -f "${AI_WARP_WG_CONF}" ]]; then
    sed -i -E "s|^Endpoint = .*|Endpoint = ${ip}:${AI_WARP_ENDPOINT_PORT}|" "${AI_WARP_WG_CONF}"
  fi
}
