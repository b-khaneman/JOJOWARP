#!/usr/bin/env bash
# JOJOWARP uninstaller
set -euo pipefail
(( EUID == 0 )) || { echo "Run as root: sudo bash uninstall.sh" >&2; exit 1; }

if command -v jojowarp >/dev/null 2>&1; then
  jojowarp uninstall "$@"
elif command -v ai-warp >/dev/null 2>&1; then
  ai-warp uninstall "$@"
else
  systemctl disable --now ai-warp-watchdog.timer 2>/dev/null || true
  systemctl disable --now ai-warp-refresh.timer 2>/dev/null || true
  systemctl disable --now wg-quick@aiwarp 2>/dev/null || true
  /usr/local/share/ai-warp/scripts/routes.sh down 2>/dev/null || true
  wg-quick down aiwarp 2>/dev/null || true
  rm -f /etc/wireguard/aiwarp.conf
  rm -f /etc/systemd/system/ai-warp-watchdog.service
  rm -f /etc/systemd/system/ai-warp-watchdog.timer
  rm -f /etc/systemd/system/ai-warp-refresh.service
  rm -f /etc/systemd/system/ai-warp-refresh.timer
  rm -f /etc/systemd/system/ai-warp.service
  systemctl daemon-reload 2>/dev/null || true
  rm -rf /usr/local/share/ai-warp /usr/local/bin/ai-warp /usr/local/bin/jojowarp
  [[ "${1:-}" == "--purge" ]] && rm -rf /etc/ai-warp
  echo "JOJOWARP removed."
fi
