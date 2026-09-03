#!/usr/bin/env bash
set -u

# NETWATCH domain observer
# Linux-only, passive DNS visibility helper.
# Requires root for packet capture in typical configurations.

SCRIPT_NAME="netwatch-domains"
DEFAULT_IFACE=""
INTERVAL=10
JSON=false

usage() {
    cat <<'EOF'
Usage:
  netwatch-domains.sh [options]

Options:
  -i, --interface IFACE   Capture on interface IFACE
  -n, --interval SEC      Refresh interval (default: 10)
      --json              Emit JSON snapshots
  -h, --help              Show this help

Examples:
  sudo ./netwatch-domains.sh
  sudo ./netwatch-domains.sh -i eth0
  sudo ./netwatch-domains.sh --json

Notes:
  This module observes DNS traffic visible on the selected Linux interface.
  It does not claim to reconstruct exact URLs or encrypted DNS activity.
EOF
}

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "Error: required command '$1' is not installed." >&2
        return 1
    }
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -i|--interface)
            [[ $# -ge 2 ]] || { echo "Missing interface." >&2; exit 2; }
            DEFAULT_IFACE="$2"
            shift 2
            ;;
        -n|--interval)
            [[ $# -ge 2 ]] || { echo "Missing interval." >&2; exit 2; }
            INTERVAL="$2"
            shift 2
            ;;
        --json)
            JSON=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Unknown option: $1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

[[ $EUID -eq 0 ]] || {
    echo "Error: run as root (for example: sudo ./netwatch-domains.sh)." >&2
    exit 1
}

need_cmd tcpdump || exit 1
need_cmd ip || exit 1

if [[ -z "$DEFAULT_IFACE" ]]; then
    DEFAULT_IFACE=$(ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
fi

[[ -n "$DEFAULT_IFACE" ]] || {
    echo "Error: could not determine the active interface." >&2
    exit 1
}

ip link show "$DEFAULT_IFACE" >/dev/null 2>&1 || {
    echo "Error: interface '$DEFAULT_IFACE' does not exist." >&2
    exit 1
}

printf '%s\n' "NETWATCH — DOMAIN OBSERVER"
printf 'Interface: %s | Refresh: %ss\n' "$DEFAULT_IFACE" "$INTERVAL"
printf '%s\n\n' 'Press Ctrl+C to stop.'

# Maintain a best-effort table in a temp file. tcpdump output is intentionally
# parsed conservatively: only conventional DNS query packets are recorded.
TMP=$(mktemp)
trap 'rm -f "$TMP"' EXIT INT TERM

# tcpdump line format for DNS queries: source.port > dns.server.domain: ID ... A? example.com.
# -l makes stdout line-buffered so records appear immediately.
tcpdump -ni "$DEFAULT_IFACE" -l -tttt -q 'udp port 53 or tcp port 53' 2>/dev/null |
awk -v interval="$INTERVAL" -v json="$JSON" '
function trimdot(s) { sub(/\.$/, "", s); return s }
function emit_table(  k,n,parts,ts) {
    if (json == "1") {
        printf "{\"timestamp\":\"%s\",\"interface\":\"%s\",\"events\":[", strftime("%Y-%m-%dT%H:%M:%S%z"), iface
        sep=""
        for (k in seen) {
            split(k, parts, "|")
            printf "%s{\"source\":\"%s\",\"domain\":\"%s\"}", sep, parts[1], parts[2]
            sep="," 
        }
        printf "]}\n"
        delete seen
        next_emit=now+interval
        return
    }
    print ""
    printf "%-19s %-18s %s\n", "LAST SEEN", "SOURCE", "DOMAIN"
    print "---------------------------------------------------------------"
    for (k in latest) {
        split(k, parts, "|")
        printf "%-19s %-18s %s\n", latest[k], parts[1], parts[2]
    }
    next_emit=now+interval
}
BEGIN { now=systime(); next_emit=now+interval; iface="" }
{
    # tcpdump -tttt starts with timestamp, followed by source and destination.
    # Find the first token containing :53 and retain the source address.
    src=$2
    gsub(/\.[0-9]+$/, "", src)
    # Common tcpdump DNS query line has a token like A? domain. near the end.
    domain=""
    for (i=1; i<=NF; i++) {
        if ($i ~ /^(A|AAAA|CNAME|MX|TXT|PTR)\?$/ && (i+1)<=NF) {
            domain=$(i+1)
            break
        }
        if ($i ~ /^A\?$/ && (i+1)<=NF) { domain=$(i+1); break }
    }
    if (domain == "") next
    gsub(/[^A-Za-z0-9_.:-]/, "", domain)
    domain=trimdot(domain)
    if (domain == "") next
    key=src "|" domain
    latest[key]=strftime("%Y-%m-%d %H:%M:%S")
    seen[key]=1
    now=systime()
    if (now >= next_emit) emit_table()
}
END { if (length(latest)>0) emit_table() }
' iface="$DEFAULT_IFACE"
