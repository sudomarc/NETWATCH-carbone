#!/bin/bash
# netwatch-android — Network monitor for Android (Termux, no root)
# Usage: netwatch-android <cmd> [args]
#
# Scan + identify only. Block/throttle/reset need root (iptables/tc) —
# not available on stock Android. See README "Android (Termux)" section.

SCRIPT_NAME=$(basename "$0")
CONFIG_DIR="${NETWATCH_CONFIG:-$HOME/.netwatch}"
BLOCK_FILE="$CONFIG_DIR/blocked_macs"
THROTTLE_FILE="$CONFIG_DIR/throttled_macs"
SCAN_LOG="$CONFIG_DIR/scan_history.log"
SUBNET=""
GATEWAY=""
IFACE=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

# ─── Utilities ────────────────────────────────────────────────────────────────

log()     { mkdir -p "$CONFIG_DIR"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$SCAN_LOG"; }
info()    { echo -e "${BLUE}[•]${NC} $*"; }
ok()      { echo -e "${GREEN}[✓]${NC} $*"; }
warn()    { echo -e "${YELLOW}[!]${NC} $*"; }
err()     { echo -e "${RED}[✗]${NC} $*" >&2; }
die()     { err "$*"; exit 1; }

no_root() {
    err "$* requires root (iptables/tc). Not available on stock Android."
    warn "If you root this device later, use netwatch.sh (Linux version) instead."
    return 1
}

check_deps() {
    local missing=()
    for dep in nmap ip awk; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        die "Missing dependencies: ${missing[*]}. Install: pkg install ${missing[*]/ip/iproute2}"
    fi
    command -v curl &>/dev/null || warn "curl not found (optional, used for online vendor lookup). pkg install curl"
    command -v dig  &>/dev/null || warn "dig not found (optional, used for rDNS). pkg install dnsutils"
}

# ─── Network Detection ────────────────────────────────────────────────────────

detect_network() {
    GATEWAY=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')
    [[ -z "$GATEWAY" ]] && die "No default gateway found. Are you connected to Wi-Fi?"

    IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    [[ -z "$IFACE" ]] && die "No default interface found."

    local ip
    ip=$(ip addr show "$IFACE" 2>/dev/null | awk '/inet / {print $2; exit}')
    [[ -z "$ip" ]] && die "No local IP on interface $IFACE."

    SUBNET="$(echo "${ip%/*}" | cut -d'.' -f1-3).0/24"

    info "Interface: $IFACE | Subnet: $SUBNET | Gateway: $GATEWAY"
}

# ─── Vendor Lookup ────────────────────────────────────────────────────────────

vendor() {
    local mac="${1^^}"
    local oui
    oui=$(echo "$mac" | cut -d':' -f1-3)

    case "$oui" in
        00:1A:2B|00:50:56|00:0C:29|00:05:69) echo "VMware" ;;
        00:1C:42)                              echo "Parallels" ;;
        00:03:93|A4:4C:C8|00:26:9E|00:0D:93|3C:07:54|A8:86:DD) echo "Apple" ;;
        00:1E:58|00:1F:3A|00:21:5C|14:18:77) echo "Dell" ;;
        00:1A:A0|00:1E:4C|00:24:E8|30:8D:99) echo "HP" ;;
        00:25:90|00:1B:21|00:1D:09|8C:EC:4B) echo "Intel" ;;
        00:16:E9|00:18:7D|00:1F:33|F8:7B:20) echo "Cisco" ;;
        20:CF:30|2C:B0:5D|64:B4:73)          echo "Xiaomi" ;;
        00:1F:82|D4:61:9D|00:E0:FC)          echo "Huawei" ;;
        A4:77:33|AC:CF:85|40:B0:34|B4:79:A7) echo "Samsung" ;;
        AC:22:0B|B8:5A:73|F0:F6:1C|04:D9:F5) echo "Asus" ;;
        18:B4:30|FC:D7:33|48:45:20|54:AF:97) echo "TP-Link" ;;
        00:26:B6|00:27:0E|9C:5C:8E|20:4E:7F) echo "Netgear" ;;
        B8:27:EB|DC:A6:32|E4:5F:01)          echo "Raspberry Pi" ;;
        00:15:5D)                              echo "Hyper-V" ;;
        *)                                     echo "Unknown" ;;
    esac
}

# ─── Validation ───────────────────────────────────────────────────────────────

is_valid_mac() { [[ "${1^^}" =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]]; }
normalize_mac() { echo "${1^^}"; }

# ─── Scan ─────────────────────────────────────────────────────────────────────

scan() {
    local format="${1:-table}"
    info "Scanning $SUBNET ..."
    mkdir -p "$CONFIG_DIR"

    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/netwatch_XXXX.tmp")

    # No root -> force unprivileged connect/ICMP-DGRAM mode (no raw ARP scan)
    nmap -sn --unprivileged "$SUBNET" \
        --max-retries 2 \
        --host-timeout 8s \
        -oG - 2>/dev/null \
        | awk '/^Host:/ && /Up/' > "$tmp"

    local count=0
    local -a results=()

    while read -r line; do
        local ip
        ip=$(awk '{print $2}' <<< "$line")
        [[ "$ip" == "$GATEWAY" ]] && continue

        local mac
        mac=$(ip neigh show "$ip" 2>/dev/null | awk 'NR==1 {print $5}')
        [[ -z "$mac" || "$mac" == "FAILED" || "$mac" == "INCOMPLETE" ]] && mac="--"

        local hostname="-"
        if command -v dig &>/dev/null; then
            hostname=$(timeout 1 dig +short +time=1 -x "$ip" 2>/dev/null | head -1 | sed 's/\.$//')
            [[ -z "$hostname" ]] && hostname="-"
        fi

        local v="-"
        [[ "$mac" != "--" ]] && v=$(vendor "$mac")

        results+=("$ip|$mac|$hostname|$v|-|-")
        ((count++))
    done < "$tmp"

    case "$format" in
        json)
            echo "["
            local first=true
            for r in "${results[@]}"; do
                IFS='|' read -r rip rmac rhost rv _ _ <<< "$r"
                $first || echo ","
                first=false
                printf '  {"ip":"%s","mac":"%s","hostname":"%s","vendor":"%s"}' "$rip" "$rmac" "$rhost" "$rv"
            done
            echo ""; echo "]"
            ;;
        csv)
            echo "ip,mac,hostname,vendor"
            for r in "${results[@]}"; do
                IFS='|' read -r rip rmac rhost rv _ _ <<< "$r"
                echo "$rip,$rmac,$rhost,$rv"
            done
            ;;
        raw)
            for r in "${results[@]}"; do echo "$r"; done
            ;;
        *)
            echo ""
            printf "${BOLD}%-3s %-16s %-18s %-22s %-12s${NC}\n" "#" "IP" "MAC" "Hostname" "Vendor"
            printf '%s\n' "$(printf '─%.0s' {1..75})"
            local idx=1
            for r in "${results[@]}"; do
                IFS='|' read -r rip rmac rhost rv _ _ <<< "$r"
                printf "%-3s %-16s %-18s %-22s %-12s\n" "$idx" "$rip" "$rmac" "${rhost:0:22}" "${rv:0:12}"
                ((idx++))
            done
            echo ""
            ok "$count device(s) found."
            ;;
    esac

    log "scan: $count devices on $SUBNET"
    rm -f "$tmp"
}

# ─── Monitor ───────────────────────────────────────────────────────────────

monitor() {
    local interval="${1:-30}"
    [[ ! "$interval" =~ ^[0-9]+$ ]] && die "Interval must be a number (seconds)."
    info "Monitor mode: scanning every ${interval}s. Press Ctrl+C to stop."
    while true; do
        clear
        echo -e "${BOLD}${CYAN}== NETWATCH (Android) — $(date '+%H:%M:%S') ==${NC}"
        scan table
        sleep "$interval"
    done
}

# ─── List (kept for parity — always empty without root) ──────────────────────

list() {
    echo -e "\n${BOLD}${YELLOW}Note:${NC} block/throttle disabled on this device (no root)."
    echo -e "${BOLD}Blocked MACs:${NC}  (none — feature unavailable)"
    echo -e "${BOLD}Throttled MACs:${NC} (none — feature unavailable)\n"
}

# ─── Export ───────────────────────────────────────────────────────────────────

export_scan() {
    local fmt="${1:-csv}"
    local outfile="$CONFIG_DIR/export_$(date '+%Y%m%d_%H%M%S').$fmt"
    mkdir -p "$CONFIG_DIR"
    detect_network
    info "Exporting scan as $fmt → $outfile"
    scan "$fmt" > "$outfile"
    ok "Saved to $outfile"
}

# ─── Identify ─────────────────────────────────────────────────────────────────

identify() {
    local target="$1"
    [[ -z "$target" ]] && die "Usage: $SCRIPT_NAME identify <ip|mac>"

    local ip mac
    if is_valid_mac "$target"; then
        mac=$(normalize_mac "$target")
        ip=$(ip neigh show 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1)
        [[ -z "$ip" ]] && die "Cannot find IP for MAC $mac in ARP cache. Run 'scan' first."
    else
        ip="$target"
        mac=$(ip neigh show "$ip" 2>/dev/null | awk 'NR==1 {print $5}')
    fi

    echo ""
    echo -e "${BOLD}${CYAN}$(printf '─%.0s' {1..50})${NC}"
    echo -e "${BOLD}  Device Profile: $ip${NC}"
    echo -e "${CYAN}$(printf '─%.0s' {1..50})${NC}"

    echo -e "\n${BOLD}[1/4] Basic Identity${NC}"
    echo "  IP Address : $ip"
    echo "  MAC Address: ${mac:---}"

    local rdns="(none)"
    if command -v dig &>/dev/null; then
        rdns=$(dig +short +time=2 -x "$ip" 2>/dev/null | head -1 | sed 's/\.$//')
        [[ -z "$rdns" ]] && rdns="(none)"
    fi
    echo "  rDNS       : $rdns"

    echo -e "\n${BOLD}[2/4] Hardware Vendor${NC}"
    local oui_vendor=""
    if [[ "$mac" != "--" && -n "$mac" ]]; then
        local oui_query="${mac:0:8}"
        if command -v curl &>/dev/null; then
            oui_vendor=$(curl -sf --max-time 3 "https://api.macvendors.com/${oui_query}" 2>/dev/null || true)
            [[ "$oui_vendor" == *"errors"* || "$oui_vendor" == *"Not Found"* ]] && oui_vendor=""
        fi
        [[ -z "$oui_vendor" ]] && oui_vendor=$(vendor "$mac")
    fi
    echo "  OUI Vendor : ${oui_vendor:-(unknown)}"

    echo -e "\n${BOLD}[3/4] Open Ports & Services${NC}"
    echo "  (unprivileged connect scan, no OS detection without root — may take ~20s)"
    local nmap_out
    nmap_out=$(nmap -sV --unprivileged --version-intensity 3 \
        --max-retries 1 --host-timeout 25s -T4 "$ip" 2>/dev/null)
    local ports
    ports=$(echo "$nmap_out" | awk '/^[0-9]+\/tcp/{printf "  %-25s %s %s\n",$1,$3,$NF}')
    if [[ -n "$ports" ]]; then
        printf "  %-25s %-10s %s\n" "PORT" "STATE" "SERVICE/VERSION"
        echo   "  $(printf '─%.0s' {1..55})"
        echo "$ports"
    else
        echo "  (no open TCP ports detected)"
    fi

    echo -e "\n${BOLD}[4/4] OS Fingerprint${NC}"
    echo "  (requires root for nmap -O — not available on stock Android)"

    echo ""
    echo -e "${CYAN}$(printf '─%.0s' {1..50})${NC}"
    echo -e "  Note: block/throttle need root — not available here."
    echo -e "${CYAN}$(printf '─%.0s' {1..50})${NC}"
    echo ""
    log "identify: $ip ($mac)"
}

# ─── Disabled commands (need root) ───────────────────────────────────────────

block()      { no_root "block"; }
unblock()    { no_root "unblock"; }
throttle()   { no_root "throttle"; }
unthrottle() { no_root "unthrottle"; }
reset()      { no_root "reset"; }

# ─── Interactive Menu ─────────────────────────────────────────────────────────

menu() {
    check_deps
    detect_network

    local -a DEVICES=()

    _menu_scan() {
        info "Scanning network..."
        DEVICES=()
        while IFS= read -r line; do DEVICES+=("$line"); done < <(scan raw 2>/dev/null)
    }

    _menu_print_devices() {
        if [[ ${#DEVICES[@]} -eq 0 ]]; then
            warn "No devices found. Run a scan first."
            return 1
        fi
        echo ""
        printf "${BOLD}%-4s %-16s %-18s %-20s %-12s${NC}\n" "#" "IP" "MAC" "Hostname" "Vendor"
        printf '%s\n' "$(printf '─%.0s' {1..72})"
        local idx=1
        for r in "${DEVICES[@]}"; do
            IFS='|' read -r rip rmac rhost rv _ _ <<< "$r"
            printf "%-4s %-16s %-18s %-20s %-12s\n" "$idx" "$rip" "$rmac" "${rhost:0:20}" "${rv:0:12}"
            ((idx++))
        done
        echo ""
    }

    _menu_pick_device() {
        local prompt="${1:-Select a device}"
        _menu_print_devices || return 1
        local choice
        while true; do
            read -rp "$(echo -e "${CYAN}$prompt [1-${#DEVICES[@]}] or 0 to cancel: ${NC}")" choice
            [[ "$choice" == "0" ]] && return 1
            if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#DEVICES[@]} )); then
                SELECTED_DEVICE="${DEVICES[$((choice-1))]}"
                return 0
            fi
            warn "Invalid choice."
        done
    }

    _menu_header() {
        clear
        echo -e "${BOLD}${CYAN}NETWATCH — Android (Termux, no root)${NC}"
        echo -e "  ${BOLD}Interface:${NC} $IFACE   ${BOLD}Subnet:${NC} $SUBNET   ${BOLD}Gateway:${NC} $GATEWAY"
        echo -e "  ${BOLD}Devices found:${NC} ${#DEVICES[@]}   ${BOLD}Time:${NC} $(date '+%H:%M:%S')"
        echo -e "  $(printf '─%.0s' {1..60})"
        echo ""
    }

    info "Running initial scan..."
    _menu_scan

    while true; do
        _menu_header
        echo -e "  ${BOLD}MAIN MENU${NC}"
        echo ""
        echo -e "  ${CYAN}[1]${NC} Scan network"
        echo -e "  ${CYAN}[2]${NC} Show devices"
        echo -e "  ${CYAN}[3]${NC} Identify / probe a device"
        echo -e "  ${CYAN}[8]${NC} Monitor mode"
        echo -e "  ${CYAN}[9]${NC} Export scan"
        echo -e "  ${YELLOW}[4-7,R]${NC} Block/throttle/reset — ${RED}disabled, needs root${NC}"
        echo -e "  ${CYAN}[Q]${NC} Quit"
        echo ""
        read -rp "$(echo -e "  ${BOLD}Choice: ${NC}")" choice

        case "${choice,,}" in
            1) _menu_scan; ok "${#DEVICES[@]} device(s) found. Press Enter."; read -r ;;
            2) clear; _menu_print_devices; read -rp "Press Enter..." _ ;;
            3)
                if _menu_pick_device "Select device to identify"; then
                    IFS='|' read -r rip _ <<< "$SELECTED_DEVICE"
                    identify "$rip"
                    read -rp "Press Enter..." _
                fi
                ;;
            8)
                local interval
                read -rp "$(echo -e "${CYAN}Refresh interval in seconds [30]: ${NC}")" interval
                [[ -z "$interval" ]] && interval=30
                monitor "$interval"
                ;;
            9)
                echo -e "${CYAN}[1]${NC} CSV   ${CYAN}[2]${NC} JSON"
                read -rp "$(echo -e "${CYAN}Format [1]: ${NC}")" fmt_choice
                case "$fmt_choice" in 2) export_scan json ;; *) export_scan csv ;; esac
                read -rp "Press Enter..." _
                ;;
            4|5|6|7|r) no_root "this action"; read -rp "Press Enter..." _ ;;
            q) echo -e "\n${GREEN}Goodbye!${NC}\n"; exit 0 ;;
            *) warn "Unknown option."; sleep 1 ;;
        esac
    done
}

# ─── Argument Parsing ─────────────────────────────────────────────────────────

CMD="${1:-menu}"
shift || true

case "$CMD" in
    menu) menu ;;
    scan) check_deps; detect_network; scan "${1:-table}" ;;
    monitor) check_deps; detect_network; monitor "${1:-30}" ;;
    identify|info|probe) check_deps; detect_network; identify "$1" ;;
    list) list ;;
    export) check_deps; export_scan "${1:-csv}" ;;
    block) no_root "block" ;;
    unblock) no_root "unblock" ;;
    throttle) no_root "throttle" ;;
    unthrottle) no_root "unthrottle" ;;
    reset) no_root "reset" ;;
    help|-h|--help)
        cat <<EOF

${BOLD}netwatch-android${NC} — Network monitor for Termux (no root)

${BOLD}Usage:${NC} $SCRIPT_NAME <command> [args]

${BOLD}Commands:${NC}
  menu                    Interactive menu (default)
  scan [table|json|csv]   Scan local network
  monitor [interval]      Auto-refresh every N seconds (default: 30)
  identify <ip|mac>        Fingerprint a device (ports, vendor, rDNS)
  list                    Show blocked/throttled status (n/a, no root)
  export [csv|json]       Export scan to $CONFIG_DIR/
  help                    Show this help

${BOLD}Disabled (need root):${NC} block, unblock, throttle, unthrottle, reset

${BOLD}Setup:${NC}
  pkg install nmap iproute2 dnsutils curl
  chmod +x netwatch-android.sh
  ./netwatch-android.sh

${BOLD}Config:${NC} $CONFIG_DIR
EOF
        ;;
    *)
        err "Unknown command: $CMD"
        echo "Run '$SCRIPT_NAME help' for usage."
        exit 1
        ;;
esac
