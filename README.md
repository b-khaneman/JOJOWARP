# JOJOWARP

Selective **Cloudflare WARP** for **`geosite:google-deepmind`** (Gemini / Flow / NotebookLM / Jules / …) on a Kharej Ubuntu VPS.

Default path: **only Google AI host `/32`s** via WARP — not the entire Google IP space (that killed ping).

Repo: https://github.com/b-khaneman/JOJOWARP  
Support: [@B_khaneman](https://t.me/B_khaneman)  
Version: **1.3.4** · License: MIT

---

## Install

On the **Kharej** server that is the panel egress:

```bash
curl -fsSL "https://raw.githubusercontent.com/b-khaneman/JOJOWARP/main/install.sh?v=1.3.4" | sudo bash
```

If GitHub is filtered:

```bash
curl -fsSL "https://cdn.jsdelivr.net/gh/b-khaneman/JOJOWARP@v1.3.4/install.sh" | sudo bash
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
| Panel / tunnel / your CDN | Direct |
| Cloudflare edge **blocks** | Direct |
| `geosite:google-deepmind` (Gemini / Flow / NotebookLM / …) | WARP (`/32` only) |
| Rest of Google / YouTube / GCP | Direct (not the whole goog.json table) |

WireGuard uses `Table = off` — **no default-route steal**.

**IPv6:** if WARP has no v6, AI v6 prefixes are blackholed / REJECT'd so Happy Eyeballs uses IPv4 via WARP.

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

Default: **`google`** = `geosite:google-deepmind`

```bash
sudo bash install.sh --mode google     # recommended
sudo bash install.sh --mode ai         # DeepMind + ChatGPT/Claude/…
sudo bash install.sh --mode full
```

| Mode | What goes via WARP |
|------|--------------------|
| `google` | Official DeepMind geosite hosts resolved to `/32` (low ping) |
| `ai` | DeepMind + ChatGPT / Claude / Copilot / other AI hostnames |
| `full` | `ai` + AWS CloudFront prefixes |

Do **not** set `AI_WARP_GOOGLE_CIDRS=1` unless you accept high ping (dumps all Google IP ranges).

### Panel routing (Xray / sing-box)

On the **client inbound** routing, send Google AI through the Kharej outbound (this VPS):

```json
{
  "type": "field",
  "domain": ["geosite:google-deepmind"],
  "outboundTag": "PROXY"
}
```

sing-box equivalent: `rule_set` / `geosite-google-deepmind` → the same proxy outbound.

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
curl -fsSL "https://raw.githubusercontent.com/b-khaneman/JOJOWARP/main/install.sh?v=1.3.4" | sudo bash -s -- --fresh
```

---

## Instagram Music (optional — off by default)

Routing Meta/Instagram through WARP **raises ping** on the panel and usually **does not** unlock Reels music on the phone (IG checks the device/SIM/account region, not only VPS IP).

Left as an explicit opt-in:

```bash
export AI_WARP_IG_MUSIC=1
sudo jojowarp refresh
```

For music that stays blocked, use a residential VPN **on the phone**, not WARP on the VPS.

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
| Gemini still blocked | panel must send `geosite:google-deepmind` to this Kharej outbound; `jojowarp status` DeepMind path via aiwarp |
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
