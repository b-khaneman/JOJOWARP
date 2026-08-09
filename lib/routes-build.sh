#!/usr/bin/env bash
# Build allowed-ips.txt (+ IPv6) from Google CIDRs + resolved AI domains.
# CDN-safe: never hijack Cloudflare *blocks* (panel CDN stays direct).
# /32 and /128 host routes (even if on CF anycast) are kept — required for ChatGPT etc.
# shellcheck shell=bash

ai_google_fallback_cidrs() {
  cat <<'EOF'
8.8.8.0/24
8.8.4.0/24
8.34.208.0/20
8.35.192.0/21
34.64.0.0/11
34.96.0.0/12
34.112.0.0/12
34.128.0.0/10
35.184.0.0/13
35.192.0.0/14
35.196.0.0/15
35.198.0.0/16
35.199.0.0/17
35.200.0.0/13
35.208.0.0/12
35.224.0.0/12
35.240.0.0/13
64.233.160.0/19
66.102.0.0/20
66.249.64.0/19
70.32.128.0/19
72.14.192.0/18
74.125.0.0/16
108.177.0.0/17
142.250.0.0/15
172.217.0.0/16
172.253.0.0/16
173.194.0.0/16
192.178.0.0/15
199.36.154.0/23
199.36.156.0/24
207.223.160.0/20
208.81.188.0/22
209.85.128.0/17
216.58.192.0/19
216.239.32.0/19
EOF
}

ai_google_fallback_cidrs6() {
  cat <<'EOF'
2001:4860::/32
2404:6800::/32
2404:f340::/32
2600:1900::/28
2607:f8b0::/32
2620:0:1000::/40
2800:3f0::/32
2a00:1450::/32
2c0f:fb50::/32
EOF
}

ai_fetch_google_cidrs() {
  local family="${1:-v4}" json tmp query
  json="$(mktemp)"
  if curl -fsSL --connect-timeout 10 --max-time 45 \
      https://www.gstatic.com/ipranges/goog.json -o "$json" 2>/dev/null; then
    if [[ "$family" == v6 ]]; then
      query='.prefixes[]?.ipv6Prefix // empty'
    else
      query='.prefixes[]?.ipv4Prefix // empty'
    fi
    tmp="$(jq -r "$query" "$json" 2>/dev/null | grep -E '^[0-9a-fA-F:.]+/[0-9]+$' || true)"
    if [[ -n "$tmp" ]]; then
      printf '%s\n' "$tmp"
      rm -f "$json"
      return 0
    fi
  fi
  rm -f "$json"
  if [[ "$family" == v6 ]]; then
    ai_warn "goog.json IPv6 unreachable — using built-in Google IPv6 fallback."
    ai_google_fallback_cidrs6
  else
    ai_warn "goog.json unreachable — using built-in Google CIDR fallback."
    ai_google_fallback_cidrs
  fi
}

# Resolve A/AAAA via public DNS first (uncensored), then system resolver.
ai_dig_at() {
  local type="$1" host="$2" ns="$3"
  dig +short +time=2 +tries=1 "$type" "$host" "@${ns}" 2>/dev/null \
    | grep -E '^[0-9a-fA-F:.]+$' | grep -v '\.$' || true
}

ai_is_ipv4() {
  [[ "$1" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

ai_is_ipv6() {
  [[ "$1" == *:* ]] && [[ "$1" != */* ]]
}

ai_lookup_host_v4() {
  local host="$1" ip ns found=0
  if ai_have dig; then
    for ns in 1.1.1.1 8.8.8.8 9.9.9.9; do
      found=0
      while IFS= read -r ip; do
        if ai_is_ipv4 "$ip"; then
          echo "$ip"
          found=1
        fi
      done < <(ai_dig_at A "$host" "$ns")
      if (( found )); then
        return 0
      fi
    done
  fi
  if ai_have getent; then
    while IFS= read -r ip; do
      ai_is_ipv4 "$ip" && echo "$ip"
    done < <(getent ahostsv4 "$host" 2>/dev/null | awk '{print $1}')
  fi
}

ai_lookup_host_v6() {
  local host="$1" ip ns found=0
  if ai_have dig; then
    for ns in 1.1.1.1 8.8.8.8 9.9.9.9; do
      found=0
      while IFS= read -r ip; do
        if ai_is_ipv6 "$ip"; then
          echo "$ip"
          found=1
        fi
      done < <(ai_dig_at AAAA "$host" "$ns")
      if (( found )); then
        return 0
      fi
    done
  fi
  if ai_have getent; then
    while IFS= read -r ip; do
      ai_is_ipv6 "$ip" && echo "$ip"
    done < <(getent ahostsv6 "$host" 2>/dev/null | awk '{print $1}')
  fi
}

ai_iter_domain_hosts() {
  local domains_file="$1" host
  [[ -f "$domains_file" ]] || return 0
  while IFS= read -r host || [[ -n "$host" ]]; do
    host="${host%%#*}"
    host="${host//[[:space:]]/}"
    [[ -z "$host" ]] && continue
    printf '%s\n' "$host"
  done <"$domains_file"
}

ai_resolve_domains_v4() {
  local domains_file="${1:-$AI_WARP_DOMAINS}" host ip
  while IFS= read -r host; do
    [[ -z "$host" ]] && continue
    while IFS= read -r ip; do
      ai_is_ipv4 "$ip" && echo "${ip}/32"
    done < <(ai_lookup_host_v4 "$host" | sort -u)
  done < <(ai_iter_domain_hosts "$domains_file") || true
}

ai_resolve_domains_v6() {
  local domains_file="${1:-$AI_WARP_DOMAINS}" host ip
  while IFS= read -r host; do
    [[ -z "$host" ]] && continue
    while IFS= read -r ip; do
      ai_is_ipv6 "$ip" && echo "${ip}/128"
    done < <(ai_lookup_host_v6 "$host" | sort -u)
  done < <(ai_iter_domain_hosts "$domains_file") || true
}

ai_cloudflare_blocks() {
  local family="${1:-v4}" cache url
  if [[ "$family" == v6 ]]; then
    cache="${AI_WARP_STATE}/cloudflare-ips-v6.txt"
    url="https://www.cloudflare.com/ips-v6"
  else
    cache="${AI_WARP_STATE}/cloudflare-ips-v4.txt"
    url="https://www.cloudflare.com/ips-v4"
  fi
  if [[ ! -s "$cache" ]] || [[ $(( $(date +%s) - $(stat -c %Y "$cache" 2>/dev/null || echo 0) )) -gt 86400 ]]; then
    curl -fsSL --connect-timeout 10 --max-time 30 "$url" -o "$cache" 2>/dev/null || true
  fi
  if [[ -s "$cache" ]]; then
    grep -E '^[0-9a-fA-F:.]+/[0-9]+$' "$cache" || true
    return 0
  fi
  if [[ "$family" == v6 ]]; then
    cat <<'EOF'
2400:cb00::/32
2606:4700::/32
2803:f800::/32
2405:b500::/32
2405:8100::/32
2a06:98c0::/29
2c0f:f248::/32
EOF
  else
    cat <<'EOF'
103.21.244.0/22
103.22.200.0/22
103.31.4.0/22
104.16.0.0/13
104.24.0.0/14
108.162.192.0/18
131.0.72.0/22
141.101.64.0/18
162.158.0.0/15
172.64.0.0/13
173.245.48.0/20
188.114.96.0/20
190.93.240.0/20
197.234.240.0/22
198.41.128.0/17
EOF
  fi
}

# WARP engage ranges — must never be routed into the tunnel (loop).
# Do NOT blanket-drop 162.159.0.0/16: ChatGPT/Claude /32s may live there.
ai_is_warp_engage_v4() {
  local cidr="$1" ip="${1%/*}"
  case "$cidr" in
    162.159.192.*|162.159.193.*|162.159.195.*) return 0 ;;
  esac
  case "$ip" in
    162.159.192.*|162.159.193.*|162.159.195.*) return 0 ;;
  esac
  return 1
}

ai_filter_cdn_safe_v4() {
  local infile="$1" outfile="$2"
  local cf_tmp own_ip cidr
  cf_tmp="$(mktemp)"
  ai_cloudflare_blocks v4 >"$cf_tmp"

  own_ip="$(
    ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src"){print $(i+1); exit}}'
  )"

  : >"$outfile"
  while IFS= read -r cidr; do
    [[ -z "$cidr" ]] && continue
    [[ "$cidr" =~ ^(10\.|127\.|169\.254\.|172\.(1[6-9]|2[0-9]|3[0-1])\.|192\.168\.) ]] && continue
    ai_is_warp_engage_v4 "$cidr" && continue
    if [[ -n "$own_ip" && "$cidr" == "${own_ip}/32" ]]; then
      continue
    fi
    if [[ "$cidr" != */32 ]] && grep -Fxq "$cidr" "$cf_tmp" 2>/dev/null; then
      continue
    fi
    echo "$cidr" >>"$outfile"
  done <"$infile"

  rm -f "$cf_tmp"
  sort -u -o "$outfile" "$outfile"
}

ai_filter_cdn_safe_v6() {
  local infile="$1" outfile="$2"
  local cf_tmp cidr
  cf_tmp="$(mktemp)"
  ai_cloudflare_blocks v6 >"$cf_tmp"

  : >"$outfile"
  while IFS= read -r cidr; do
    [[ -z "$cidr" ]] && continue
    [[ "$cidr" =~ ^(::1/|fe80:|fc[0-9a-fA-F]{2}:|fd[0-9a-fA-F]{2}:) ]] && continue
    if [[ "$cidr" != */128 ]] && grep -Fxq "$cidr" "$cf_tmp" 2>/dev/null; then
      continue
    fi
    echo "$cidr" >>"$outfile"
  done <"$infile"

  rm -f "$cf_tmp"
  sort -u -o "$outfile" "$outfile"
}

ai_meta_fallback_cidrs() {
  # Meta / Facebook / Instagram (AS32934) — OPTIONAL only (AI_WARP_IG_MUSIC=1).
  # Do NOT enable by default: large prefixes inflate the route table and raise ping.
  cat <<'EOF'
31.13.64.0/18
57.144.0.0/14
129.134.0.0/16
157.240.0.0/16
173.252.64.0/18
179.60.192.0/22
185.60.216.0/22
EOF
}

ai_meta_fallback_cidrs6() {
  cat <<'EOF'
2a03:2880::/32
EOF
}

ai_seed_meta_cidrs() {
  local family="${1:-v4}"
  ai_warn "IG Music opt-in: seeding Meta ranges (may increase latency)…"
  if [[ "$family" == v6 ]]; then
    ai_meta_fallback_cidrs6
  else
    ai_meta_fallback_cidrs
  fi
}

ai_google_domain_filter() {
  grep -Ei 'google|gstatic|googleapis|android|gradle|labs\.google|deepmind|gemini|notebooklm|aistudio|recaptcha|geller|aisandbox|alkali|flow|withgoogle' \
    "$1" 2>/dev/null || cat "$1"
}

ai_build_cidr_list() {
  local mode="${1:-ai}"
  local tmp4 tmp6 filtered4 filtered6 gtmp count4 count6 igfile
  tmp4="$(mktemp)"
  tmp6="$(mktemp)"
  filtered4="$(mktemp)"
  filtered6="$(mktemp)"

  ai_info "Building selective route list (mode=${mode})…"
  install -d -m700 "${AI_WARP_STATE}"

  case "$mode" in
    ai|google|full)
      ai_fetch_google_cidrs v4 >>"$tmp4" || true
      ai_fetch_google_cidrs v6 >>"$tmp6" || true
      ;;
    *)
      ai_fail "Unknown mode: $mode"
      ;;
  esac

  if [[ "$mode" == "ai" || "$mode" == "full" ]]; then
    ai_info "Resolving AI domains (Gemini, Flow, ChatGPT, Claude, …)…"
    ai_resolve_domains_v4 "${AI_WARP_DOMAINS}" >>"$tmp4" || true
    ai_resolve_domains_v6 "${AI_WARP_DOMAINS}" >>"$tmp6" || true
  elif [[ "$mode" == "google" ]]; then
    gtmp="$(mktemp)"
    ai_google_domain_filter "${AI_WARP_DOMAINS}" >"$gtmp"
    ai_info "Resolving Google / Flow / Android domains…"
    ai_resolve_domains_v4 "$gtmp" >>"$tmp4" || true
    ai_resolve_domains_v6 "$gtmp" >>"$tmp6" || true
    rm -f "$gtmp"
  fi

  # Instagram Music is OFF by default — enabling Meta AS routes hurts panel latency.
  if [[ "${AI_WARP_IG_MUSIC:-0}" == "1" && ( "$mode" == "ai" || "$mode" == "full" ) ]]; then
    igfile="${AI_WARP_SHARE}/conf/ig-music-domains.txt"
    [[ -f "$igfile" ]] || igfile="${AI_WARP_SHARE_LIB:-}/conf/ig-music-domains.txt"
    [[ -f /etc/ai-warp/ig-music-domains.txt ]] && igfile="/etc/ai-warp/ig-music-domains.txt"
    if [[ -f "$igfile" ]]; then
      ai_info "IG Music opt-in: resolving ${igfile}…"
      ai_resolve_domains_v4 "$igfile" >>"$tmp4" || true
      ai_resolve_domains_v6 "$igfile" >>"$tmp6" || true
    fi
    ai_seed_meta_cidrs v4 >>"$tmp4" || true
    ai_seed_meta_cidrs v6 >>"$tmp6" || true
  fi

  if [[ "$mode" == "full" ]]; then
    ai_info "Fetching AWS CloudFront prefixes…"
    local cloud
    cloud="$(mktemp)"
    if curl -fsSL --connect-timeout 10 --max-time 60 \
        https://ip-ranges.amazonaws.com/ip-ranges.json -o "$cloud"; then
      jq -r '.prefixes[] | select(.service=="CLOUDFRONT") | .ip_prefix' "$cloud" \
        2>/dev/null | grep -E '^[0-9./]+$' >>"$tmp4" || true
      jq -r '.ipv6_prefixes[]? | select(.service=="CLOUDFRONT") | .ipv6_prefix' "$cloud" \
        2>/dev/null | grep -E '^[0-9a-fA-F:./]+$' >>"$tmp6" || true
    fi
    rm -f "$cloud"
  fi

  grep -E '^[0-9.]+/[0-9]+$' "$tmp4" | sort -u >"${tmp4}.clean" || true
  grep -E '^[0-9a-fA-F:]+/[0-9]+$' "$tmp6" | sort -u >"${tmp6}.clean" || true
  ai_filter_cdn_safe_v4 "${tmp4}.clean" "$filtered4"
  ai_filter_cdn_safe_v6 "${tmp6}.clean" "$filtered6"

  grep -q '^8\.8\.8\.0/24$' "$filtered4" || echo '8.8.8.0/24' >>"$filtered4"
  grep -q '^8\.8\.4\.0/24$' "$filtered4" || echo '8.8.4.0/24' >>"$filtered4"
  sort -u -o "$filtered4" "$filtered4"
  sort -u -o "$filtered6" "$filtered6"

  cp -f "$filtered4" "${AI_WARP_CIDR_FILE}"
  cp -f "$filtered6" "${AI_WARP_CIDR6_FILE}"
  rm -f "$tmp4" "$tmp6" "${tmp4}.clean" "${tmp6}.clean" "$filtered4" "$filtered6"

  count4="$(wc -l <"${AI_WARP_CIDR_FILE}" | tr -d ' ')"
  count6="$(wc -l <"${AI_WARP_CIDR6_FILE}" | tr -d ' ')"
  if (( count4 < 5 )); then
    ai_warn "IPv4 CIDR list small ($count4) — seeding Google fallback."
    ai_google_fallback_cidrs >"${AI_WARP_CIDR_FILE}"
    count4="$(wc -l <"${AI_WARP_CIDR_FILE}" | tr -d ' ')"
  fi
  (( count4 >= 5 )) || ai_fail "Could not build IPv4 route list."
  echo "$mode" >"${AI_WARP_MODE_FILE}"
  ai_log "Route targets: ${count4} IPv4 + ${count6} IPv6 (Cloudflare CDN blocks excluded)"
}
