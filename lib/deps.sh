#!/usr/bin/env bash
# Dependency installer for JOJOWARP — noninteractive & resilient
# shellcheck shell=bash

ai_apt_update() {
  local i
  for i in 1 2 3; do
    if apt-get update -qq; then
      return 0
    fi
    ai_warn "apt-get update failed (try $i/3) — retrying…"
    sleep 2
  done
  ai_warn "apt-get update failed — continuing with existing indexes."
  return 0
}

ai_apt_install() {
  local pkgs=("$@")
  export DEBIAN_FRONTEND=noninteractive
  export NEEDRESTART_MODE=a
  export UCF_FORCE_CONFFOLD=1

  if apt-get install -y -qq \
      -o Dpkg::Options::="--force-confdef" \
      -o Dpkg::Options::="--force-confold" \
      "${pkgs[@]}"; then
    return 0
  fi

  ai_warn "Batch apt install failed — trying packages one by one…"
  local p
  for p in "${pkgs[@]}"; do
    apt-get install -y -qq \
      -o Dpkg::Options::="--force-confdef" \
      -o Dpkg::Options::="--force-confold" \
      "$p" 2>/dev/null || apt-get install -y "$p" || ai_warn "optional/skip: $p"
  done
  return 0
}

ai_install_deps() {
  ai_info "Installing system packages (automatic)…"
  export DEBIAN_FRONTEND=noninteractive

  if ai_have apt-get; then
    ai_apt_update
    ai_apt_install \
      curl wget jq ca-certificates iproute2 iptables dnsutils \
      wireguard wireguard-tools
    apt-get install -y -qq resolvconf 2>/dev/null || true
    apt-get install -y -qq openresolv 2>/dev/null || true
  elif ai_have dnf; then
    dnf -y install curl wget jq iproute iptables bind-utils wireguard-tools || true
  elif ai_have yum; then
    yum -y install curl wget jq iproute iptables bind-utils wireguard-tools || true
  else
    ai_fail "Unsupported distro (need Ubuntu/Debian apt, or dnf/yum)."
  fi

  modprobe wireguard 2>/dev/null || true
  if ! ai_wireguard_supported; then
    ai_fail "Kernel WireGuard is not available (OpenVZ/old kernel?). Use KVM or modern LXC."
  fi
  if ! ai_have wg || ! ai_have wg-quick; then
    ai_fail "wireguard-tools missing after install."
  fi
  if ! ai_have jq; then
    ai_fail "jq missing after install."
  fi
  if ! ai_have curl; then
    ai_fail "curl missing after install."
  fi

  ai_log "Dependencies ready."
}

ai_wgcf_is_elf() {
  local f="$1" magic
  [[ -s "$f" ]] || return 1
  magic="$(head -c 4 "$f" 2>/dev/null | od -An -tx1 | tr -d ' \n' | tr 'A-F' 'a-f')"
  [[ "$magic" == "7f454c46" ]]
}

ai_install_wgcf() {
  local arch ver url tmp mirrors pin sz
  if [[ -x "${AI_WARP_WGCF}" ]]; then
    if "${AI_WARP_WGCF}" --help >/dev/null 2>&1 || "${AI_WARP_WGCF}" 2>&1 | head -1 | grep -qi wgcf; then
      ai_log "wgcf already present: ${AI_WARP_WGCF}"
      return 0
    fi
    ai_warn "Existing wgcf binary looks broken — re-downloading."
    rm -f "${AI_WARP_WGCF}"
  fi

  arch="$(ai_arch)"
  ai_info "Downloading wgcf (linux_${arch})…"

  ver="$(
    curl -fsSL --connect-timeout 10 --max-time 30 \
      https://api.github.com/repos/ViRb3/wgcf/releases/latest 2>/dev/null \
      | jq -r '.tag_name // empty' || true
  )"
  ver="${ver#v}"
  pin="2.2.32"
  [[ -n "$ver" ]] || ver="$pin"

  mirrors=(
    "https://github.com/ViRb3/wgcf/releases/download/v${ver}/wgcf_${ver}_linux_${arch}"
    "https://ghproxy.net/https://github.com/ViRb3/wgcf/releases/download/v${ver}/wgcf_${ver}_linux_${arch}"
    "https://mirror.ghproxy.com/https://github.com/ViRb3/wgcf/releases/download/v${ver}/wgcf_${ver}_linux_${arch}"
    "https://github.com/ViRb3/wgcf/releases/download/v${pin}/wgcf_${pin}_linux_${arch}"
    "https://ghproxy.net/https://github.com/ViRb3/wgcf/releases/download/v${pin}/wgcf_${pin}_linux_${arch}"
  )

  tmp="$(mktemp /tmp/wgcf.XXXXXX)"
  for url in "${mirrors[@]}"; do
    ai_info "Trying: $url"
    if curl -fsSL --connect-timeout 12 --max-time 120 --retry 2 \
        "$url" -o "$tmp" && ai_wgcf_is_elf "$tmp"; then
      sz="$(wc -c <"$tmp" | tr -d ' ')"
      if (( sz > 500000 )); then
        install -m755 "$tmp" "${AI_WARP_WGCF}"
        rm -f "$tmp"
        ai_log "wgcf installed (${sz} bytes)"
        return 0
      fi
    fi
  done
  rm -f "$tmp"
  ai_fail "Failed to download wgcf (all mirrors)."
}
