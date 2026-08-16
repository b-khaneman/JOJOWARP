# Changelog

## 1.3.5 — 2026-08-17

### Changed
- **Zero panel config (default):** mode `google` now also routes minimal Gemini companions (`accounts.google.com`, OAuth, gstatic, recaptcha) as `/32`s so login/UI works when all client traffic already exits this Kharej VPS — no Pasarguard geosite rule required.
- DNS lookup merges A/AAAA from multiple resolvers for fuller `/32` coverage.

## 1.3.4 — 2026-08-16

### Fixed
- **Install abort after successful `wgcf register`:** account TOML uses single quotes (`device_id = '…'`). The validator only stripped `"`, treated a good account as corrupt, and never brought the tunnel up.
- Health no longer errors when `canary-ip` / `canary-ip6` are missing (incomplete install).

## 1.3.3 — 2026-08-16

### Fixed
- **Install crash:** extra `}` in `lib/health.sh` (`ai_watchdog_tick`) caused `syntax error near unexpected token '}'`.

## 1.3.2 — 2026-08-16

### Fixed (debug pass)
- **Stale routes:** `refresh` used to overwrite the CIDR file *before* `routes down`, so old goog.json / 8.8.8.8 routes stayed in the kernel. Now down first; `up` also flushes every non-kernel route on `aiwarp`.
- **Watchdog restart loop:** `warp≠on` no longer bounces the tunnel every 2 minutes (Cloudflare is not in DeepMind routes).
- **ip6tables vs WARP v6:** REJECT chain only when the host has no WARP IPv6 (otherwise it blocked the tunnel).
- **Stale geosite cache:** fallback uses the packaged list, not an old `/etc/ai-warp/google-deepmind.txt` with extra Google hosts.
- **iface UP check:** require operstate up, not merely that the link exists.
- Health `warp≠on` is informational, not a failure.

## 1.3.1 — 2026-08-16

### Fixed
- **Strict geosite:google-deepmind only:** dropped companion hosts (`accounts.google.com`, `www.googleapis.com`, `gstatic`, Recaptcha) that were sending normal Google traffic into WARP.
- **No Google DNS hijack:** removed forced `8.8.8.0/24` / `8.8.4.0/24` routes.
- **No bulk Google IPv6:** removed `2001:4860::/32` (and friends) unreachable + ip6tables REJECT that broke Happy Eyeballs / YouTube v6.
- Health/watchdog canary is a resolved DeepMind `/32`, not 8.8.8.8.
- On refresh, leftover routes from 1.2.x are deleted.

## 1.3.0 — 2026-08-16

### Changed
- **Default mode is `google`:** routes **`geosite:google-deepmind`** (Gemini, Flow, NotebookLM, Jules, AI Studio, …) via WARP.
- **No more default goog.json dump.** Entire Google/GCP CIDRs were the main ping killer. Host `/32`s only.
- Live fetch of v2fly `data/google-deepmind` on each refresh, with bundled fallback.

### Panel
- Document Xray rule: `geosite:google-deepmind` → Kharej/WARP outbound.

## 1.2.7 — 2026-08-09

### Fixed
- **High ping / unstable configs:** Meta/Instagram AS32934 bulk routes removed from the default path (they flooded the routing table and pushed panel traffic through WARP).
- Instagram Music is **opt-in only** (`AI_WARP_IG_MUSIC=1`) — mobile IG music often still fails without a phone-side residential VPN.

## 1.2.6 — 2026-08-09

### Added
- **Instagram Music unlock:** Meta/Instagram/Facebook hosts + AS32934 CIDR seed, plus Spotify/Apple Music preview endpoints used by the IG music catalog.
- Default `ai` mode now routes IG Music geo-checks via WARP (phone/client must egress through this Kharej VPS).

## 1.2.5 — 2026-08-09

### Added
- **Unique per-server WARP identity:** each install registers its own Cloudflare `device_id`.
- **Host bind:** account is tied to machine fingerprint; copied accounts from another VPS are rejected and replaced.
- `--fresh` / `AI_WARP_FRESH=1` forces a brand-new account + sticky re-lock.
- `AI_WARP_KEEP_ACCOUNT=1` adopts a legacy unbound account onto this host.

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
