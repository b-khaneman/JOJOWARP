#!/usr/bin/env bash
# wgcf account + WireGuard profile management
# Each install binds a unique Cloudflare WARP identity to THIS host.
# Copied account.toml from another VPS is rejected → fresh register.
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

# Stable fingerprint for THIS machine (not shared across VPS clones intentionally).
ai_host_fingerprint() {
  local mid disk host product
  mid="$(cat /etc/machine-id 2>/dev/null || cat /var/lib/dbus/machine-id 2>/dev/null || true)"
  [[ -n "$mid" ]] || mid="$(hostname -f 2>/dev/null || hostname || echo unknown-host)"
  disk="$(lsblk -ndo UUID "$(findmnt -no SOURCE / 2>/dev/null | head -1)" 2>/dev/null | head -1 || true)"
  [[ -n "$disk" ]] || disk="$(cat /sys/class/dmi/id/product_uuid 2>/dev/null | tr -d '[:space:]' || true)"
  product="$(cat /sys/class/dmi/id/product_serial 2>/dev/null | tr -d '[:space:]' || true)"
  host="$(hostname -s 2>/dev/null || echo host)"
  printf '%s\n' "${mid}|${disk}|${product}|${host}" | sha256sum 2>/dev/null | awk '{print $1}' \
    || printf '%s\n' "${mid}|${disk}|${product}|${host}" | md5sum | awk '{print $1}'
}

ai_new_install_id() {
  if ai_have openssl; then
    openssl rand -hex 16
  elif [[ -r /dev/urandom ]]; then
    head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n'
  else
    date +%s%N
  fi
}

# wgcf writes TOML with single quotes: device_id = 'uuid'
ai_toml_scalar() {
  local key="$1" file="${2:-${AI_WARP_ACCOUNT}}" line val
  [[ -s "$file" ]] || return 0
  line="$(grep -E "^[[:space:]]*${key}[[:space:]]*=" "$file" 2>/dev/null | head -1 || true)"
  [[ -n "$line" ]] || return 0
  val="${line#*=}"
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  val="${val#\'}"
  val="${val%\'}"
  val="${val#\"}"
  val="${val%\"}"
  printf '%s' "$val"
}

ai_account_device_id() {
  ai_toml_scalar device_id "${AI_WARP_ACCOUNT}"
}

ai_account_private_key() {
  ai_toml_scalar private_key "${AI_WARP_ACCOUNT}"
}

# Reject empty / truncated / obviously shared placeholder accounts.
ai_account_looks_valid() {
  local did pk
  [[ -s "${AI_WARP_ACCOUNT}" ]] || return 1
  did="$(ai_account_device_id)"
  pk="$(ai_account_private_key)"
  [[ "$did" =~ ^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$ ]] || return 1
  [[ ${#pk} -ge 40 ]] || return 1
  return 0
}

ai_bind_account_to_host() {
  local fp iid did
  umask 077
  fp="$(ai_host_fingerprint)"
  iid="$(ai_new_install_id)"
  did="$(ai_account_device_id)"
  printf '%s\n' "$fp" >"${AI_WARP_HOST_BIND}"
  printf '%s\n' "$iid" >"${AI_WARP_INSTALL_ID}"
  chmod 600 "${AI_WARP_HOST_BIND}" "${AI_WARP_INSTALL_ID}" "${AI_WARP_ACCOUNT}" 2>/dev/null || true
  ai_log "Unique WARP identity bound to this host"
  ai_info "install-id : ${iid}"
  [[ -n "$did" ]] && ai_info "device-id  : ${did}"
}

# 0 = safe to reuse on this host; 1 = must register fresh.
ai_account_reusable_here() {
  local fp stored
  [[ "${AI_WARP_FRESH:-0}" == "1" ]] && return 1
  ai_account_looks_valid || return 1

  # Explicit keep: adopt unbound legacy account onto this host once.
  if [[ "${AI_WARP_KEEP_ACCOUNT:-0}" == "1" && ! -s "${AI_WARP_HOST_BIND}" ]]; then
    ai_bind_account_to_host
    return 0
  fi

  [[ -s "${AI_WARP_HOST_BIND}" ]] || return 1
  fp="$(ai_host_fingerprint)"
  stored="$(tr -d '[:space:]' <"${AI_WARP_HOST_BIND}")"
  [[ -n "$fp" && "$fp" == "$stored" ]] || return 1
  return 0
}

ai_wipe_warp_identity() {
  rm -f "${AI_WARP_ACCOUNT}" "${AI_WARP_PROFILE}" \
    "${AI_WARP_STATE}/wgcf-account.toml" "${AI_WARP_STATE}/wgcf-profile.conf" \
    "${AI_WARP_HOST_BIND}" "${AI_WARP_INSTALL_ID}" \
    "${AI_WARP_STICKY_IP}" "${AI_WARP_LAST_IP}" 2>/dev/null || true
}

ai_register_warp() {
  install -d -m700 "${AI_WARP_STATE}"
  install -d -m755 "${AI_WARP_WG_DIR}"
  umask 077

  if ai_account_reusable_here; then
    ai_log "Reusing WARP account for THIS host only (stable identity)."
    ai_info "device-id  : $(ai_account_device_id)"
    ai_info "install-id : $(tr -d '[:space:]' <"${AI_WARP_INSTALL_ID}" 2>/dev/null || echo —)"
  else
    if [[ -s "${AI_WARP_ACCOUNT}" ]]; then
      if [[ "${AI_WARP_FRESH:-0}" == "1" ]]; then
        ai_warn "AI_WARP_FRESH=1 — discarding old account, registering a new unique identity…"
      else
        ai_warn "Existing WARP account is missing host-bind or belongs to another machine — registering a NEW unique account…"
      fi
      ai_wipe_warp_identity
    fi

    ai_info "Registering a unique Cloudflare WARP account for this server…"
    if ! (
      cd "${AI_WARP_STATE}"
      # Never reuse cwd leftovers from a copied tree
      rm -f wgcf-account.toml wgcf-profile.conf
      "${AI_WARP_WGCF}" register --accept-tos
    ); then
      ai_fail "WARP registration failed. Ensure api.cloudflareclient.com is reachable from this Kharej server."
    fi
    [[ -s "${AI_WARP_ACCOUNT}" ]] || ai_fail "WARP registration failed (no account file)."
    ai_account_looks_valid || ai_fail "WARP account file looks invalid/corrupt."
    ai_bind_account_to_host
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
  chmod 600 "${AI_WARP_ACCOUNT}" "${AI_WARP_PROFILE}" 2>/dev/null || true
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

  # Default IPv4-only. Opt-in WARP IPv6 with AI_WARP_IPV6=1 (fails on hosts with disable_ipv6=1).
  if [[ "${AI_WARP_IPV6:-0}" == "1" ]] && [[ -n "${AI_WARP_ADDRESS_V6:-}" ]] && ai_host_ipv6_enabled; then
    addr_line="${AI_WARP_ADDRESS_V4}, ${AI_WARP_ADDRESS_V6}"
    allowed="0.0.0.0/0, ::/0"
    note="IPv4+IPv6"
  else
    addr_line="${AI_WARP_ADDRESS_V4}"
    allowed="0.0.0.0/0"
    note="IPv4-only"
    if [[ "${AI_WARP_IPV6:-0}" == "1" ]]; then
      ai_warn "AI_WARP_IPV6=1 requested but host IPv6 is unusable — falling back to IPv4-only."
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
