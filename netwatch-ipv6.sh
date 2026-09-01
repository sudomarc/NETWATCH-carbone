#!/usr/bin/env bash
# netwatch-ipv6 — Linux IPv6 discovery and gateway control helper
# Usage: netwatch-ipv6.sh <command> [args]

set -u

CONFIG_DIR="${NETWATCH_CONFIG:-$HOME/.config/netwatch}"
BLOCK_FILE="$CONFIG_DIR/blocked_ipv6"
DRY_RUN=false
IFACE=""
GLOBAL_IPV6=""
PREFIX_LEN=""
GATEWAY_IPV6=""

info(){ printf '[+] %s\n' "$*"; }
ok(){ printf '[✓] %s\n' "$*"; }
warn(){ printf '[!] %s\n' "$*" >&2; }
die(){ printf '[x] %s\n' "$*" >&2; exit 1; }
require_root(){ [[ ${EUID:-1} -eq 0 ]] || die 'This command requires root. Run with sudo.'; }

valid_ipv6(){
    [[ -n "$1" ]] || return 1
    python3 - "$1" <<'PY'
import ipaddress, sys
try:
    ipaddress.IPv6Address(sys.argv[1])
except Exception:
    raise SystemExit(1)
PY
}

check_deps(){
    local missing=()
    for dep in ip nmap awk; do
        command -v "$dep" >/dev/null 2>&1 || missing+=("$dep")
    done
    if (( ${#missing[@]} )); then die "Missing dependencies: ${missing[*]}"; fi
    if [[ "$1" == control ]] && ! command -v ip6tables >/dev/null 2>&1; then die 'ip6tables is required for IPv6 blocking.'; fi
}

detect_ipv6(){
    IFACE=$(ip -6 route show default 2>/dev/null | awk 'NR==1 {print $5; exit}')
    [[ -n "$IFACE" ]] || die 'No IPv6 default route/interface found.'
    local addr
    addr=$(ip -6 addr show dev "$IFACE" scope global 2>/dev/null | awk '/inet6/ && $2 !~ /^fe80:/ {print $2; exit}')
    [[ -n "$addr" ]] || die "No global IPv6 address found on $IFACE."
    GLOBAL_IPV6="${addr%%/*}"
    PREFIX_LEN="${addr##*/}"
    GATEWAY_IPV6=$(ip -6 route show default dev "$IFACE" 2>/dev/null | awk '/default/ {print $3; exit}')
    info "Interface: $IFACE | IPv6: $addr${GATEWAY_IPV6:+ | Gateway: $GATEWAY_IPV6}"
}

scan(){
    local format="${1:-table}"
    detect_ipv6
    info "Discovering IPv6 neighbors on $IFACE ..."
    if command -v ping >/dev/null 2>&1; then ping -6 -c 1 -W 2 -I "$IFACE" ff02::1 >/dev/null 2>&1 || true; fi
    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/netwatch6_XXXXXX") || die 'Cannot create temporary file.'
    trap 'rm -f -- "$tmp"' EXIT
    ip -6 neigh show dev "$IFACE" 2>/dev/null | awk '$1 ~ /^[0-9a-fA-F:]+$/ && $2 != "FAILED" && $2 != "INCOMPLETE" {print}' > "$tmp"
    case "$format" in
        json) printf '[\n'; local first=true; while read -r ipaddr _ state _ mac _; do [[ -z "$ipaddr" ]] && continue; $first || printf ',\n'; first=false; printf '  {"ipv6":"%s","mac":"%s","state":"%s"}' "$ipaddr" "${mac:---}" "${state:--}"; done < "$tmp"; printf '\n]\n' ;;
        csv) printf 'ipv6,mac,state\n'; while read -r ipaddr _ state _ mac _; do [[ -z "$ipaddr" ]] && continue; printf '"%s","%s","%s"\n' "$ipaddr" "${mac:---}" "${state:--}"; done < "$tmp" ;;
        *) printf '%-42s %-20s %s\n' 'IPv6 Address' 'MAC' 'State'; printf '%s\n' '--------------------------------------------------------------------------------'; while read -r ipaddr _ state _ mac _; do [[ -z "$ipaddr" ]] && continue; printf '%-42s %-20s %s\n' "$ipaddr" "${mac:---}" "${state:--}"; done < "$tmp" ;;
    esac
}

identify(){
    local target="${1:-}"
    [[ -n "$target" ]] || die 'Usage: netwatch-ipv6.sh identify <ipv6>'
    valid_ipv6 "$target" || die "Invalid IPv6 address: '$target'"
    command -v nmap >/dev/null 2>&1 || die 'nmap is required for IPv6 identification.'
    info "Probing IPv6 target $target ..."
    nmap -6 -sV -O --osscan-guess --max-retries 1 --host-timeout 30s -T4 "$target"
}

block(){
    require_root
    local target="${1:-}"
    [[ -n "$target" ]] || die 'Usage: netwatch-ipv6.sh block <ipv6>'
    valid_ipv6 "$target" || die "Invalid IPv6 address: '$target'"
    detect_ipv6
    [[ "$target" != "$GATEWAY_IPV6" ]] || die 'Refusing to block the default IPv6 gateway.'
    [[ "$(cat /proc/sys/net/ipv6/conf/all/forwarding 2>/dev/null || printf 0)" == 1 ]] || die 'IPv6 blocking requires this Linux host to be the IPv6 router/gateway (forwarding=1).'
    mkdir -p "$CONFIG_DIR"
    if $DRY_RUN; then warn "[DRY-RUN] ip6tables would add DROP rules for $target"; return 0; fi
    ip6tables -N NETWATCH6_BLOCK 2>/dev/null || true
    ip6tables -C FORWARD -j NETWATCH6_BLOCK 2>/dev/null || ip6tables -I FORWARD 1 -j NETWATCH6_BLOCK || die 'Failed to attach NETWATCH6_BLOCK.'
    ip6tables -C NETWATCH6_BLOCK -s "$target" -j DROP 2>/dev/null || ip6tables -A NETWATCH6_BLOCK -s "$target" -j DROP || die 'Failed to add IPv6 source block.'
    ip6tables -C NETWATCH6_BLOCK -d "$target" -j DROP 2>/dev/null || ip6tables -A NETWATCH6_BLOCK -d "$target" -j DROP || die 'Failed to add IPv6 destination block.'
    grep -Fqx -- "$target" "$BLOCK_FILE" 2>/dev/null || printf '%s\n' "$target" >> "$BLOCK_FILE"
    ok "IPv6 block added for $target"
}

unblock(){
    require_root
    local target="${1:-}"
    [[ -n "$target" ]] || die 'Usage: netwatch-ipv6.sh unblock <ipv6>'
    valid_ipv6 "$target" || die "Invalid IPv6 address: '$target'"
    if $DRY_RUN; then warn "[DRY-RUN] ip6tables would remove DROP rules for $target"; return 0; fi
    ip6tables -D NETWATCH6_BLOCK -s "$target" -j DROP 2>/dev/null || true
    ip6tables -D NETWATCH6_BLOCK -d "$target" -j DROP 2>/dev/null || true
    [[ -f "$BLOCK_FILE" ]] && sed -i "|^${target}$|d" "$BLOCK_FILE" 2>/dev/null || true
    ok "IPv6 block removed for $target"
}

show_help(){
    cat <<'EOF'
netwatch-ipv6 — Linux IPv6 discovery and gateway control helper

Usage:
  netwatch-ipv6.sh scan [table|json|csv]
  netwatch-ipv6.sh identify <ipv6>
  netwatch-ipv6.sh block <ipv6>
  netwatch-ipv6.sh unblock <ipv6>

Flags:
  --dry-run    Preview control changes without modifying ip6tables

Notes:
  IPv6 discovery is link-local and uses the active Linux IPv6 interface.
  Blocking is gateway/router-only and requires IPv6 forwarding.
EOF
}

args=()
for arg in "$@"; do
    case "$arg" in
        --dry-run) DRY_RUN=true ;;
        *) args+=("$arg") ;;
    esac
done
set -- "${args[@]+"${args[@]}"}"
CMD="${1:-help}"
shift || true
case "$CMD" in
    scan) check_deps scan; scan "${1:-table}" ;;
    identify) check_deps identify; identify "${1:-}" ;;
    block) check_deps control; block "${1:-}" ;;
    unblock) check_deps control; unblock "${1:-}" ;;
    help|-h|--help) show_help ;;
    *) die "Unknown command: $CMD. Run '$0 help'." ;;
esac
