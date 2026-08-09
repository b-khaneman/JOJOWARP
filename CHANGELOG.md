# Changelog

## 1.2.4 — 2026-08-09

### Fixed
- **Hetzner IPv6 leak:** proto-static `via fe80::1` on eth0 was winning over unreachable routes. Now also REJECT AI v6 via `ip6tables` chain `AIWARP6` (OUTPUT+FORWARD), plus `metric 1` unreachable routes.
- `jojowarp update` pulls latest scripts from GitHub raw (bypasses CDN cache).

## 1.2.3 — 2026-08-09

### Fixed
- **IPv6 leak on dual-stack VPS:** eth0 can have IPv6 while WireGuard cannot. AI v6 prefixes are now `unreachable` so Happy Eyeballs falls back to IPv4 via WARP.

## 1.2.2 — 2026-08-09

### Fixed
- **Stale jsDelivr cache:** installer fetched old 1.2.0 libs while showing 1.2.1 banner. GitHub raw is first; package `VERSION` must match installer or it re-downloads.
- **WARP Address is IPv4-only by default** so `wg-quick` never dies on `disable_ipv6=1`. Opt-in: `AI_WARP_IPV6=1`.

## 1.2.1 — 2026-08-09

### Fixed
- **Host IPv6 disabled:** wg-quick no longer aborts on VPS images with `disable_ipv6=1` (e.g. Hetzner). Tunnel is IPv4-only automatically.
- **Installer trap:** `staging: unbound variable` after a failed install (`set -u` + `local` + EXIT trap).

## 1.2.0 — 2026-08-09

### Fixed
- **IPv6 leak:** AI sites preferring IPv6 no longer bypass WARP. v6 prefixes are routed via the tunnel, or blackholed so Happy Eyeballs uses IPv4 via WARP.
- **Handshake check:** use `wg latest-handshakes` and require a handshake younger than 3 minutes (stale handshakes no longer look healthy).
- **Tunnel start:** stop double `wg-quick up` + `systemctl restart` race; wait for iface + handshake.
- **DNS resolution:** `getent` no longer blocks `dig`; resolve via 1.1.1.1 / 8.8.8.8 / 9.9.9.9 then system resolver. AAAA included.
- **WARP engage filter:** no longer drop all `162.159.0.0/16` (that killed some ChatGPT/Claude `/32`s). Only engage ranges are excluded.
- **`rp_filter`:** disable only on the WARP interface, not globally.
- **Healthcheck:** systemd inactive is a warning if the interface is already up; `warp=on` trace is now a first-class check.
- **Reinstall:** sticky IP is preserved unless `--relock`.
- **Version skew:** installer / `VERSION` / runtime all report **1.2.0**.
- **wgcf download:** verify ELF magic; pin fallback to **2.2.32**.
- **Restart/uninstall:** fall back to `wg-quick` when systemd fails; tear down v4+v6 routes.

### Added
- WARP endpoint discovery (`engage.cloudflareclient.com`) with watchdog rotation on handshake failure.
- Kernel WireGuard probe (clear error on OpenVZ).
- `jojowarp doctor` alias for status.
- GitHub Actions: `bash -n` + ShellCheck.
- Cleaner domain list (deduped + Cursor / Sora / extra Google AI hosts).

## 1.1.1

- Initial public package layout (installer, watchdog, sticky IP, CDN-safe routes).
