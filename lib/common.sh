#!/usr/bin/env bash
# JOJOWARP common helpers — sourced by other scripts. Do not execute directly.
# shellcheck shell=bash

if [[ -n "${AI_WARP_COMMON_LOADED:-}" ]]; then
  return 0 2>/dev/null || true
fi
AI_WARP_COMMON_LOADED=1

readonly AI_WARP_NAME="JOJOWARP"
readonly AI_WARP_IFACE="aiwarp"
readonly AI_WARP_TABLE="51821"
readonly AI_WARP_ENDPOINT_FALLBACK="162.159.192.1"
readonly AI_WARP_ENDPOINT_HOST="engage.cloudflareclient.com"
readonly AI_WARP_ENDPOINT_PORT="2408"
readonly AI_WARP_MTU="1280"
readonly AI_WARP_KEEPALIVE="25"

readonly AI_WARP_PREFIX="/usr/local"
readonly AI_WARP_BIN="${AI_WARP_PREFIX}/bin/ai-warp"
readonly AI_WARP_SHARE="${AI_WARP_PREFIX}/share/ai-warp"
readonly AI_WARP_STATE="/etc/ai-warp"
readonly AI_WARP_WG_DIR="/etc/wireguard"
readonly AI_WARP_WG_CONF="${AI_WARP_WG_DIR}/${AI_WARP_IFACE}.conf"
readonly AI_WARP_ACCOUNT="${AI_WARP_STATE}/wgcf-account.toml"
readonly AI_WARP_PROFILE="${AI_WARP_STATE}/wgcf-profile.conf"
readonly AI_WARP_MODE_FILE="${AI_WARP_STATE}/mode"
readonly AI_WARP_CIDR_FILE="${AI_WARP_STATE}/allowed-ips.txt"
readonly AI_WARP_CIDR6_FILE="${AI_WARP_STATE}/allowed-ips-v6.txt"
readonly AI_WARP_ENDPOINT_FILE="${AI_WARP_STATE}/endpoint"
readonly AI_WARP_STICKY_IP="${AI_WARP_STATE}/sticky-ip"
readonly AI_WARP_LAST_IP="${AI_WARP_STATE}/last-ip"
readonly AI_WARP_HOST_BIND="${AI_WARP_STATE}/host-bind"
readonly AI_WARP_INSTALL_ID="${AI_WARP_STATE}/install-id"
readonly AI_WARP_WGCF="${AI_WARP_PREFIX}/bin/wgcf"
readonly AI_WARP_SUPPORT="@B_khaneman"
readonly AI_WARP_REPO_URL="https://github.com/b-khaneman/JOJOWARP"

if [[ -f "${AI_WARP_SHARE}/VERSION" ]]; then
  AI_WARP_VERSION="$(tr -d '[:space:]' <"${AI_WARP_SHARE}/VERSION")"
elif [[ -f "${AI_WARP_SHARE_LIB:-}/VERSION" ]]; then
  AI_WARP_VERSION="$(tr -d '[:space:]' <"${AI_WARP_SHARE_LIB}/VERSION")"
else
  AI_WARP_VERSION="${AI_WARP_VERSION_PIN:-1.2.5}"
fi
readonly AI_WARP_VERSION

if [[ -f "${AI_WARP_STATE}/ai-domains.txt" ]]; then
  AI_WARP_DOMAINS="${AI_WARP_STATE}/ai-domains.txt"
elif [[ -f "${AI_WARP_SHARE}/conf/ai-domains.txt" ]]; then
  AI_WARP_DOMAINS="${AI_WARP_SHARE}/conf/ai-domains.txt"
else
  AI_WARP_DOMAINS="${AI_WARP_SHARE_LIB:-.}/conf/ai-domains.txt"
fi

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

ai_log()  { echo -e "${GREEN}[+]${NC} $*"; }
ai_warn() { echo -e "${YELLOW}[!]${NC} $*"; }
ai_err()  { echo -e "${RED}[!]${NC} $*" >&2; }
ai_info() { echo -e "${CYAN}[*]${NC} $*"; }
ai_fail() { ai_err "$*"; exit 1; }

ai_need_root() {
  (( EUID == 0 )) || ai_fail "Run as root: sudo ai-warp …"
}

ai_have() { command -v "$1" >/dev/null 2>&1; }

ai_arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64 ;;
    aarch64|arm64) echo arm64 ;;
    armv7l|armhf) echo armv7 ;;
    *) ai_fail "Unsupported arch: $(uname -m)" ;;
  esac
}

# True only if new interfaces can actually get an IPv6 address.
# Many VPS images (Hetzner etc.) set disable_ipv6=1 — wg-quick then aborts.
ai_host_ipv6_enabled() {
  local all def
  [[ -e /proc/net/if_inet6 ]] || return 1
  all="$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null || echo 1)"
  def="$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null || echo 1)"
  [[ "$all" == "0" && "$def" == "0" ]]
}

ai_host_has_global_ipv6() {
  ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'
}

ai_wireguard_supported() {
  if [[ -d /sys/module/wireguard ]]; then
    return 0
  fi
  if ai_have lsmod && lsmod 2>/dev/null | grep -q '^wireguard'; then
    return 0
  fi
  if ip link add dev aiwarpprobe type wireguard >/dev/null 2>&1; then
    ip link del dev aiwarpprobe >/dev/null 2>&1 || true
    return 0
  fi
  return 1
}

ai_banner() {
  cat <<EOF
${BOLD}${CYAN}
    ___    ____      _       _____  ____  ____
   /   |  /  _/     | |     / /   |/ __ \/ __ \\
  / /| |  / /_______| | /| / / /| / /_/ / /_/ /
 / ___ |_/ /_______/| |/ |/ / ___ / _, _/ ____/
/_/  |_/___/        |__/|__/_/  |_/_/ |_/_/
${NC}
  ${BOLD}${AI_WARP_NAME}${NC} v${AI_WARP_VERSION}  —  Cloudflare WARP AI Unlock
  ${AI_WARP_REPO_URL}
  Support: ${AI_WARP_SUPPORT}
EOF
}
