# JOJOWARP

Selective **Cloudflare WARP** unlock for **Gemini / Google Flow / ChatGPT / Claude / Instagram Music / …** on a Kharej (Ubuntu) VPS.

One command. Zero prompts. Panel tunnel + Cloudflare CDN stay untouched.

Repo: https://github.com/b-khaneman/JOJOWARP  
Support: [@B_khaneman](https://t.me/B_khaneman)  
Version: **1.2.6** · License: MIT

---

## Install

On the **Kharej** server that is the panel egress:

```bash
curl -fsSL "https://raw.githubusercontent.com/b-khaneman/JOJOWARP/main/install.sh?v=1.2.6" | sudo bash
```

If GitHub is filtered (may be cached — prefer GitHub raw when possible):

```bash
curl -fsSL "https://cdn.jsdelivr.net/gh/b-khaneman/JOJOWARP@v1.2.6/install.sh" | sudo bash
```

Local clone:

```bash
sudo bash install.sh
```

This installs packages, registers a persistent WARP account, builds AI routes (IPv4 + IPv6), starts WireGuard, and enables watchdog + refresh timers.

---

## How it works

| Traffic | Path |
|---------|------|
| Panel / tunnel / your CDN | Direct (unchanged) |
| Cloudflare edge **blocks** | Direct (not hijacked) |
| Gemini / Flow / Google AI | WARP |
| ChatGPT / Claude / Copilot / … | WARP (`/32` + `/128` host routes, even on CF anycast) |
| Instagram Music / Reels audio | WARP (Meta AS32934 + IG/FB hosts) |

WireGuard uses `Table = off` — **no default-route steal**. Only listed AI destinations leave via WARP.

**IPv6:** if WARP gives you a v6 address, AI v6 prefixes go through the tunnel. If not, those prefixes are blackholed so Happy Eyeballs falls back to IPv4 via WARP (no IPv6 leak).

---

## Commands

```bash
jojowarp status
jojowarp ip
jojowarp ip --relock
jojowarp refresh
jojowarp restart
jojowarp uninstall --purge
```

(`ai-warp` is the same binary.)

---

## Modes

Default: all AIs (`ai`)

```bash
sudo bash install.sh --mode google
sudo bash install.sh --mode full
sudo bash install.sh --menu
sudo bash install.sh --files-only
```

| Mode | What goes via WARP |
|------|--------------------|
| `ai` | Google AI ranges + resolved AI domains (recommended) |
| `google` | Google / Gemini / Flow / Android Studio only |
| `full` | AI + AWS CloudFront prefixes |

---

## Unique identity (per server)

Every install calls Cloudflare and creates a **new WARP device** (`device_id`) for that VPS.

- Account files are **never** shipped in the GitHub repo.
- Identity is bound to a **host fingerprint** (`/etc/ai-warp/host-bind`).
- Copying `wgcf-account.toml` to another server is **rejected** → that server registers its own new account.
- Same-server reinstall keeps the same identity (sticky IP).
- Force a brand-new identity anytime:

```bash
sudo jojowarp install --fresh
# or:
curl -fsSL "https://raw.githubusercontent.com/b-khaneman/JOJOWARP/main/install.sh?v=1.2.6" | sudo bash -s -- --fresh
```

---

## WARP+

Optional paid license (more stable egress):

```bash
export AI_WARP_LICENSE=xxxx-xxxx-xxxx-xxxx
sudo bash install.sh
```

Keep the same account across reinstalls on the **same** host automatically.  
To wipe identity: `sudo jojowarp uninstall --purge` or install with `--fresh`.

Reinstall without overwriting `/etc/ai-warp/ai-domains.txt`:

```bash
export AI_WARP_KEEP_DOMAINS=1
sudo bash install.sh
```

Adopt a legacy unbound account on this host (rare):

```bash
export AI_WARP_KEEP_ACCOUNT=1
sudo bash install.sh
```

---

## Requirements

- Ubuntu/Debian (or RHEL-like with dnf/yum)
- Root / sudo
- KVM or modern LXC with kernel WireGuard (**not** OpenVZ without the module)
- Outbound access to Cloudflare (`api.cloudflareclient.com`, `engage.cloudflareclient.com`)

---

## Uninstall

```bash
sudo jojowarp uninstall          # keep WARP account
sudo jojowarp uninstall --purge  # wipe account + state
# or:
curl -fsSL https://raw.githubusercontent.com/b-khaneman/JOJOWARP/main/uninstall.sh | sudo bash -s -- --purge
```

---

## Troubleshooting

| Symptom | Check |
|---------|--------|
| `interface: DOWN` | `sudo jojowarp restart` then `sudo jojowarp status` |
| handshake stale | watchdog rotates WARP endpoint automatically; or `sudo jojowarp restart` |
| `warp≠on` | kernel WireGuard + UDP/2408 to `162.159.192.0/24` |
| Gemini still blocked | confirm Kharej install; `ip route get 8.8.8.8` must show `dev aiwarp` |
| ChatGPT still blocked | `sudo jojowarp refresh` (host `/32`s change); IPv6 leak is handled automatically |
| `IPv6 is disabled on this device` | fixed in 1.2.2 — tunnel is IPv4-only by default; re-run install from GitHub raw |
| installer says 1.2.x but `jojowarp N نصب شد` is older | CDN cache; use the `?v=` GitHub raw URL in Install |
| registration failed | server must reach `api.cloudflareclient.com` (install on Kharej, not inside Iran) |

Logs: `journalctl -u wg-quick@aiwarp -u ai-warp-watchdog.service -u ai-warp-refresh.service`

---

## Notes

- Safe alongside JojoNet / Xray / Hysteria and Cloudflare orange-cloud.
- Free WARP may rotate egress IPs; account identity stays on disk under `/etc/ai-warp`.
- Domain list: `/etc/ai-warp/ai-domains.txt` — edit, then `sudo jojowarp refresh`.
