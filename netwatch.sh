#!/bin/bash
# netwatch — Network monitor & control tool
# Usage: netwatch <cmd> [args]

SCRIPT_NAME=$(basename "$0")
CONFIG_DIR="${NETWATCH_CONFIG:-$HOME/.config/netwatch}"
BLOCK_FILE="$CONFIG_DIR/blocked_macs"
THROTTLE_FILE="$CONFIG_DIR/throttled_macs"
SCAN_LOG="$CONFIG_DIR/scan_history.log"
SUBNET=""
GATEWAY=""
IFACE=""
DRY_RUN=false
PERSISTENT=false

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
require() { [[ "$EUID" -eq 0 ]] || die "This command requires root. Run with sudo."; }

cleanup() { rm -f /tmp/netwatch_*.tmp 2>/dev/null; }
trap cleanup EXIT

check_deps() {
    local missing=()
    for dep in nmap iptables ip awk tc; do
        command -v "$dep" &>/dev/null || missing+=("$dep")
    done
    [[ ${#missing[@]} -gt 0 ]] && die "Missing dependencies: ${missing[*]}"
}

# ─── Network Detection ────────────────────────────────────────────────────────

detect_network() {
    GATEWAY=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')
    [[ -z "$GATEWAY" ]] && die "No default gateway found."

    IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    [[ -z "$IFACE" ]] && die "No default interface found."

    local ip
    ip=$(ip addr show "$IFACE" 2>/dev/null | awk '/inet / {print $2; exit}')
    [[ -z "$ip" ]] && die "No local IP on interface $IFACE."

    local prefix="${ip#*/}"
    local base
    base=$(ipcalc -n "$ip" 2>/dev/null | awk -F= '/^NETWORK/ {print $2}')
    if [[ -n "$base" ]]; then
        SUBNET="$base/$prefix"
    else
        SUBNET="$(echo "${ip%/*}" | cut -d'.' -f1-3).0/24"
    fi

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

is_valid_mac() {
    [[ "${1^^}" =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]]
}

is_valid_speed() {
    [[ "$1" =~ ^[0-9]+(kbit|mbit|gbit|kbps|mbps)$ ]]
}

normalize_mac() {
    echo "${1^^}"
}

# ─── Scan ─────────────────────────────────────────────────────────────────────

scan() {
    local format="${1:-table}"
    info "Scanning $SUBNET ..."

    mkdir -p "$CONFIG_DIR"
    local tmp
    tmp=$(mktemp /tmp/netwatch_XXXX.tmp)

    nmap -sn -PR "$SUBNET" \
        --max-retries 2 \
        --host-timeout 8s \
        -oG - 2>/dev/null \
        | awk '/^Host:/ && /Up/' > "$tmp"

    ip neigh flush nud stale 2>/dev/null || true

    local count=0
    local -a results=()

    while read -r line; do
        local ip
        ip=$(awk '{print $2}' <<< "$line")
        [[ "$ip" == "$GATEWAY" ]] && continue

        local mac
        mac=$(ip neigh show "$ip" 2>/dev/null | awk 'NR==1 {print $5}')
        [[ -z "$mac" || "$mac" == "FAILED" || "$mac" == "INCOMPLETE" ]] && mac="--"

        local hostname
        hostname=$(timeout 1 bash -c "getent hosts $ip 2>/dev/null | awk '{print \$2}'" 2>/dev/null || echo "-")
        [[ -z "$hostname" ]] && hostname="-"

        local v="-"
        [[ "$mac" != "--" ]] && v=$(vendor "$mac")

        local blocked="-"
        [[ "$mac" != "--" ]] && grep -qi "^$(normalize_mac "$mac")$" "$BLOCK_FILE" 2>/dev/null && blocked="BLOCKED"

        local throttled="-"
        if [[ "$mac" != "--" ]]; then
            local throttle_entry
            throttle_entry=$(grep -i "^$(normalize_mac "$mac")|" "$THROTTLE_FILE" 2>/dev/null | cut -d'|' -f2)
            [[ -n "$throttle_entry" ]] && throttled="$throttle_entry"
        fi

        results+=("$ip|$mac|$hostname|$v|$blocked|$throttled")
        ((count++))
    done < "$tmp"

    case "$format" in
        json)
            echo "["
            local first=true
            for r in "${results[@]}"; do
                IFS='|' read -r rip rmac rhost rv rblock rthrottle <<< "$r"
                $first || echo ","
                first=false
                printf '  {"ip":"%s","mac":"%s","hostname":"%s","vendor":"%s","blocked":"%s","throttled":"%s"}' \
                    "$rip" "$rmac" "$rhost" "$rv" "$rblock" "$rthrottle"
            done
            echo ""
            echo "]"
            ;;
        csv)
            echo "ip,mac,hostname,vendor,blocked,throttled"
            for r in "${results[@]}"; do
                echo "$r" | tr '|' ','
            done
            ;;
        raw)
            # For internal use by menu — returns pipe-separated lines
            for r in "${results[@]}"; do
                echo "$r"
            done
            ;;
        *)
            echo ""
            printf "${BOLD}%-3s %-16s %-18s %-22s %-12s %-10s %-10s${NC}\n" \
                "#" "IP" "MAC" "Hostname" "Vendor" "Blocked" "Throttled"
            printf '%s\n' "$(printf '─%.0s' {1..95})"

            local idx=1
            for r in "${results[@]}"; do
                IFS='|' read -r rip rmac rhost rv rblock rthrottle <<< "$r"
                local color=""
                [[ "$rblock" == "BLOCKED" ]] && color="$RED"
                [[ -n "$rthrottle" && "$rthrottle" != "-" ]] && color="$YELLOW"
                printf "${color}%-3s %-16s %-18s %-22s %-12s %-10s %-10s${NC}\n" \
                    "$idx" "$rip" "$rmac" "${rhost:0:22}" "${rv:0:12}" "$rblock" "$rthrottle"
                ((idx++))
            done
            echo ""
            ok "$count device(s) found."
            ;;
    esac

    log "scan: $count devices on $SUBNET"
    rm -f "$tmp"
}

# ─── Monitor Mode ─────────────────────────────────────────────────────────────

monitor() {
    local interval="${1:-30}"
    [[ ! "$interval" =~ ^[0-9]+$ ]] && die "Interval must be a number (seconds)."
    info "Monitor mode: scanning every ${interval}s. Press Ctrl+C to stop."
    while true; do
        clear
        echo -e "${BOLD}${CYAN}╔══════════════════════════════╗"
        echo -e "║   NETWATCH — $(date '+%H:%M:%S')      ║"
        echo -e "╚══════════════════════════════╝${NC}"
        scan table
        sleep "$interval"
    done
}

# ─── Block / Unblock ──────────────────────────────────────────────────────────

block() {
    require
    local target="$1"
    [[ -z "$target" ]] && die "Usage: $SCRIPT_NAME block <ip|mac>"

    local ip mac
    if is_valid_mac "$target"; then
        mac=$(normalize_mac "$target")
        ip=$(ip neigh show 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1)
        [[ -z "$ip" ]] && die "Cannot resolve IP for $mac. Run scan first."
    else
        ip="$target"
        mac=$(ip neigh show "$ip" 2>/dev/null | awk 'NR==1 {print $5}')
    fi

    mkdir -p "$CONFIG_DIR"
    [[ -z "$GATEWAY" ]] && detect_network

    local is_router=false
    [[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" == "1" ]] && is_router=true

    if $is_router; then
        info "Router mode — blocking via iptables"
        if $DRY_RUN; then
            warn "[DRY-RUN] iptables DROP for $ip / $mac"
        else
            iptables -A FORWARD -s "$ip" -j DROP 2>/dev/null || true
            iptables -A FORWARD -d "$ip" -j DROP 2>/dev/null || true
            [[ -n "$mac" ]] && {
                iptables -A INPUT   -m mac --mac-source "$mac" -j DROP 2>/dev/null || true
                iptables -A FORWARD -m mac --mac-source "$mac" -j DROP 2>/dev/null || true
            }
        fi
    fi

    if command -v arpspoof &>/dev/null; then
        info "ARP spoofing $ip (gateway: $GATEWAY)"
        if $DRY_RUN; then
            warn "[DRY-RUN] arpspoof -i $IFACE -t $ip $GATEWAY"
        else
            sysctl -qw net.ipv4.ip_forward=1 2>/dev/null || true
            local pidfile="$CONFIG_DIR/arp_${ip//./_}.pid"
            arpspoof -i "$IFACE" -t "$ip" "$GATEWAY" &>/dev/null &
            echo $! > "$pidfile"
            arpspoof -i "$IFACE" -t "$GATEWAY" "$ip" &>/dev/null &
            echo $! >> "$pidfile"
            ok "ARP spoof active (PIDs in $pidfile)"
        fi
    else
        warn "arpspoof not found. Install: sudo apt install dsniff"
    fi

    if [[ -n "$mac" ]]; then
        grep -qi "^$mac$" "$BLOCK_FILE" 2>/dev/null || echo "$mac" >> "$BLOCK_FILE"
    fi
    echo "$ip" >> "$CONFIG_DIR/blocked_ips" 2>/dev/null || true

    $PERSISTENT && _save_iptables

    log "block: $ip ($mac)"
    ok "Blocked: $ip${mac:+ ($mac)}"
}

unblock() {
    require
    local target="$1"
    [[ -z "$target" ]] && die "Usage: $SCRIPT_NAME unblock <ip|mac>"

    local ip mac
    if is_valid_mac "$target"; then
        mac=$(normalize_mac "$target")
        ip=$(ip neigh show 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1)
    else
        ip="$target"
        mac=$(ip neigh show "$ip" 2>/dev/null | awk 'NR==1 {print $5}')
    fi

    [[ -z "$GATEWAY" ]] && detect_network 2>/dev/null || true

    local pidfile="$CONFIG_DIR/arp_${ip//./_}.pid"
    if [[ -f "$pidfile" ]]; then
        info "Stopping ARP spoof for $ip ..."
        while read -r pid; do
            kill "$pid" 2>/dev/null || true
        done < "$pidfile"
        rm -f "$pidfile"
        if [[ -n "$GATEWAY" && -n "$IFACE" ]]; then
            arping -c 3 -U -I "$IFACE" "$GATEWAY" &>/dev/null 2>&1 || true
        fi
    fi

    [[ -n "$ip" ]] && {
        iptables -D FORWARD -s "$ip" -j DROP 2>/dev/null || true
        iptables -D FORWARD -d "$ip" -j DROP 2>/dev/null || true
    }
    [[ -n "$mac" ]] && {
        iptables -D INPUT   -m mac --mac-source "$mac" -j DROP 2>/dev/null || true
        iptables -D FORWARD -m mac --mac-source "$mac" -j DROP 2>/dev/null || true
        sed -i "/^${mac}$/Id" "$BLOCK_FILE" 2>/dev/null || true
    }
    [[ -n "$ip" ]] && sed -i "/^${ip}$/d" "$CONFIG_DIR/blocked_ips" 2>/dev/null || true

    $PERSISTENT && _save_iptables

    log "unblock: $ip ($mac)"
    ok "Unblocked: $ip"
}

# ─── Throttle / Unthrottle ────────────────────────────────────────────────────

throttle() {
    require
    local mac speed
    mac=$(normalize_mac "$1")
    speed="$2"

    is_valid_mac "$mac"     || die "Invalid MAC: '$1'"
    is_valid_speed "$speed" || die "Invalid speed '$speed'. Examples: 512kbit, 2mbit"

    [[ -z "$IFACE" ]] && detect_network

    local mark
    mark=$(( 0x$(echo "$mac" | tr -d ':' | tail -c 4) % 65535 + 1 ))

    info "Throttling $mac → $speed (mark $mark) ..."
    if $DRY_RUN; then
        warn "[DRY RUN] Would set HTB rate $speed for $mac on $IFACE"
    else
        iptables -t mangle -A PREROUTING -m mac --mac-source "$mac" -j MARK --set-mark "$mark" 2>/dev/null || true

        tc qdisc show dev "$IFACE" 2>/dev/null | grep -q "htb" || \
            tc qdisc add dev "$IFACE" root handle 1: htb default 0 2>/dev/null || true

        tc class  add dev "$IFACE" parent 1: classid "1:$mark" htb rate "$speed" ceil "$speed" 2>/dev/null || true
        tc filter add dev "$IFACE" parent 1: protocol ip prio "$mark" handle "$mark" fw classid "1:$mark" 2>/dev/null || true

        mkdir -p "$CONFIG_DIR"
        grep -qi "^$mac|" "$THROTTLE_FILE" 2>/dev/null \
            && sed -i "/^${mac}|/Id" "$THROTTLE_FILE"
        echo "$mac|$speed|$mark" >> "$THROTTLE_FILE"
    fi
    $PERSISTENT && _save_iptables
    log "throttle: $mac → $speed"
    ok "Throttled $mac to $speed"
}

unthrottle() {
    require
    local mac
    mac=$(normalize_mac "$1")
    is_valid_mac "$mac" || die "Invalid MAC: '$1'"

    [[ -z "$IFACE" ]] && detect_network

    local entry mark
    entry=$(grep -i "^$mac|" "$THROTTLE_FILE" 2>/dev/null | head -1)
    mark=$(awk -F'|' '{print $3}' <<< "$entry")

    if $DRY_RUN; then
        warn "[DRY RUN] Would remove throttle rules for $mac"
    else
        [[ -n "$mark" ]] && {
            iptables -t mangle -D PREROUTING -m mac --mac-source "$mac" -j MARK --set-mark "$mark" 2>/dev/null || true
            tc class  del dev "$IFACE" parent 1: classid "1:$mark" 2>/dev/null || true
            tc filter del dev "$IFACE" parent 1: protocol ip prio "$mark" 2>/dev/null || true
        }
        sed -i "/^${mac}|/Id" "$THROTTLE_FILE" 2>/dev/null || true
    fi
    log "unthrottle: $mac"
    ok "Unthrottled $mac"
}

# ─── List ─────────────────────────────────────────────────────────────────────

list() {
    echo -e "\n${BOLD}${RED}Blocked MACs:${NC}"
    if [[ -f "$BLOCK_FILE" && -s "$BLOCK_FILE" ]]; then
        cat -n "$BLOCK_FILE"
    else
        echo "  (none)"
    fi

    echo -e "\n${BOLD}${YELLOW}Throttled MACs:${NC}"
    if [[ -f "$THROTTLE_FILE" && -s "$THROTTLE_FILE" ]]; then
        printf "  %-3s %-20s %-10s\n" "#" "MAC" "Speed"
        local i=1
        while IFS='|' read -r mac speed _; do
            printf "  %-3s %-20s %-10s\n" "$i" "$mac" "$speed"
            ((i++))
        done < "$THROTTLE_FILE"
    else
        echo "  (none)"
    fi
    echo ""
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
    echo -e "${BOLD}${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BOLD}  Device Profile: $ip${NC}"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

    echo -e "\n${BOLD}[1/6] Basic Identity${NC}"
    echo "  IP Address : $ip"
    echo "  MAC Address: ${mac:---}"

    local rdns
    rdns=$(dig +short +time=2 -x "$ip" 2>/dev/null | head -1 | sed 's/\.$//')
    [[ -z "$rdns" ]] && rdns=$(getent hosts "$ip" 2>/dev/null | awk '{print $2}')
    echo "  rDNS       : ${rdns:-(none)}"

    echo -e "\n${BOLD}[2/6] Hardware Vendor${NC}"
    local oui_vendor=""
    if [[ "$mac" != "--" && -n "$mac" ]]; then
        local oui_query="${mac:0:8}"
        if command -v curl &>/dev/null; then
            oui_vendor=$(curl -sf --max-time 3 \
                "https://api.macvendors.com/${oui_query}" 2>/dev/null || true)
            [[ "$oui_vendor" == *"errors"* || "$oui_vendor" == *"Not Found"* ]] && oui_vendor=""
        fi
        [[ -z "$oui_vendor" ]] && oui_vendor=$(vendor "$mac")
    fi
    echo "  OUI Vendor : ${oui_vendor:-(unknown)}"

    echo -e "\n${BOLD}[3/6] mDNS / Bonjour Services${NC}"
    if command -v avahi-browse &>/dev/null; then
        local mdns_out
        mdns_out=$(timeout 5 avahi-browse -a -r -p --no-db-lookup 2>/dev/null \
            | grep -F "$ip" | awk -F';' '{print $5, $8}' | sort -u)
        if [[ -n "$mdns_out" ]]; then
            while read -r svc rest; do
                echo "  • $svc  →  $rest"
            done <<< "$mdns_out"
        else
            echo "  (no mDNS services detected)"
        fi
    else
        warn "  avahi-browse not found. Install: sudo apt install avahi-utils"
    fi

    echo -e "\n${BOLD}[4/6] NetBIOS / SMB Name${NC}"
    if command -v nmblookup &>/dev/null; then
        local nbt
        nbt=$(timeout 3 nmblookup -A "$ip" 2>/dev/null \
            | awk '/<00>/ && !/<GROUP>/ {print $1}' | head -1)
        echo "  NetBIOS    : ${nbt:-(none)}"
    else
        warn "  nmblookup not found. Install: sudo apt install samba-common-bin"
    fi

    echo -e "\n${BOLD}[5/6] Open Ports & Services${NC}"
    echo "  (scanning top 1000 ports + version detection, may take ~30s)"
    local nmap_out
    nmap_out=$(nmap -sV -O --osscan-guess \
        --version-intensity 5 \
        --max-retries 1 \
        --host-timeout 30s \
        -T4 "$ip" 2>/dev/null)

    local ports
    ports=$(echo "$nmap_out" | awk '/^[0-9]+\/tcp/{printf "  %-25s %s %s\n",$1,$3,$NF}')
    if [[ -n "$ports" ]]; then
        printf "  %-25s %-10s %s\n" "PORT" "STATE" "SERVICE/VERSION"
        echo   "  $(printf '─%.0s' {1..55})"
        echo "$ports"
    else
        echo "  (no open TCP ports detected)"
    fi

    echo -e "\n${BOLD}[6/6] OS Fingerprint${NC}"
    local os_guess
    os_guess=$(echo "$nmap_out" | grep -E "^OS:|Running:|OS details:" | head -3 | sed 's/^/  /')
    echo "${os_guess:-(insufficient data for OS detection)}"

    echo ""
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "  Tip: ${BOLD}netwatch block $mac${NC} to block this device"
    echo -e "${CYAN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""
    log "identify: $ip ($mac)"
}

# ─── Reset ────────────────────────────────────────────────────────────────────

reset() {
    require
    local iface="${IFACE:-$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')}"
    warn "This will flush all INPUT/FORWARD iptables rules and TC qdiscs. Continue? [y/N]"
    read -r yn
    [[ "${yn,,}" != "y" ]] && { info "Aborted."; return 0; }

    info "Resetting all rules ..."
    iptables -F INPUT   2>/dev/null || true
    iptables -F FORWARD 2>/dev/null || true
    iptables -t mangle -F PREROUTING 2>/dev/null || true
    tc qdisc del dev "$iface" root 2>/dev/null || true
    > "$BLOCK_FILE"    2>/dev/null || true
    > "$THROTTLE_FILE" 2>/dev/null || true
    log "reset: all rules cleared"
    ok "All rules cleared."
}

# ─── Persist iptables ─────────────────────────────────────────────────────────

_save_iptables() {
    if command -v iptables-save &>/dev/null; then
        local rules_file="/etc/iptables/rules.v4"
        mkdir -p "$(dirname "$rules_file")"
        iptables-save | tee "$rules_file" > /dev/null
        info "iptables rules saved to $rules_file"
    else
        warn "--persistent: iptables-save not found. Install iptables-persistent."
    fi
}

# ─── Interactive Menu ─────────────────────────────────────────────────────────

menu() {
    check_deps
    detect_network

    # Store scan results for reuse within the session
    local -a DEVICES=()

    _menu_scan() {
        info "Scanning network..."
        DEVICES=()
        while IFS= read -r line; do
            DEVICES+=("$line")
        done < <(scan raw 2>/dev/null)
    }

    _menu_print_devices() {
        if [[ ${#DEVICES[@]} -eq 0 ]]; then
            warn "No devices found. Run a scan first."
            return 1
        fi
        echo ""
        printf "${BOLD}%-4s %-16s %-18s %-20s %-12s %-10s %-10s${NC}\n" \
            "#" "IP" "MAC" "Hostname" "Vendor" "Blocked" "Throttled"
        printf '%s\n' "$(printf '─%.0s' {1..92})"
        local idx=1
        for r in "${DEVICES[@]}"; do
            IFS='|' read -r rip rmac rhost rv rblock rthrottle <<< "$r"
            local color=""
            [[ "$rblock" == "BLOCKED" ]] && color="$RED"
            [[ -n "$rthrottle" && "$rthrottle" != "-" ]] && color="$YELLOW"
            printf "${color}%-4s %-16s %-18s %-20s %-12s %-10s %-10s${NC}\n" \
                "$idx" "$rip" "$rmac" "${rhost:0:20}" "${rv:0:12}" "$rblock" "$rthrottle"
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
            warn "Invalid choice. Enter a number between 1 and ${#DEVICES[@]}."
        done
    }

    _menu_header() {
        clear
        echo -e "${BOLD}${CYAN}"
        echo "  ███╗   ██╗███████╗████████╗██╗    ██╗ █████╗ ████████╗ ██████╗██╗  ██╗"
        echo "  ████╗  ██║██╔════╝╚══██╔══╝██║    ██║██╔══██╗╚══██╔══╝██╔════╝██║  ██║"
        echo "  ██╔██╗ ██║█████╗     ██║   ██║ █╗ ██║███████║   ██║   ██║     ███████║"
        echo "  ██║╚██╗██║██╔══╝     ██║   ██║███╗██║██╔══██║   ██║   ██║     ██╔══██║"
        echo "  ██║ ╚████║███████╗   ██║   ╚███╔███╔╝██║  ██║   ██║   ╚██████╗██║  ██║"
        echo "  ╚═╝  ╚═══╝╚══════╝   ╚═╝    ╚══╝╚══╝ ╚═╝  ╚═╝   ╚═╝    ╚═════╝╚═╝  ╚═╝"
        echo -e "${NC}"
        echo -e "  ${BOLD}Interface:${NC} $IFACE   ${BOLD}Subnet:${NC} $SUBNET   ${BOLD}Gateway:${NC} $GATEWAY"
        echo -e "  ${BOLD}Devices found:${NC} ${#DEVICES[@]}   ${BOLD}Time:${NC} $(date '+%H:%M:%S')"
        echo -e "  $(printf '─%.0s' {1..70})"
        echo ""
    }

    _menu_main() {
        while true; do
            _menu_header
            echo -e "  ${BOLD}MAIN MENU${NC}"
            echo ""
            echo -e "  ${CYAN}[1]${NC} 🔍  Scan network"
            echo -e "  ${CYAN}[2]${NC} 📋  Show devices"
            echo -e "  ${CYAN}[3]${NC} 🔎  Identify / probe a device"
            echo -e "  ${CYAN}[4]${NC} 🚫  Block a device"
            echo -e "  ${CYAN}[5]${NC} ✅  Unblock a device"
            echo -e "  ${CYAN}[6]${NC} 🐢  Throttle a device"
            echo -e "  ${CYAN}[7]${NC} 🚀  Unthrottle a device"
            echo -e "  ${CYAN}[8]${NC} 📊  Monitor mode"
            echo -e "  ${CYAN}[9]${NC} 📂  Export scan"
            echo -e "  ${CYAN}[L]${NC} 📋  List blocked/throttled"
            echo -e "  ${CYAN}[R]${NC} 🔄  Reset all rules"
            echo -e "  ${CYAN}[Q]${NC} 👋  Quit"
            echo ""
            read -rp "$(echo -e "  ${BOLD}Choice: ${NC}")" choice

            case "${choice,,}" in
                1)
                    _menu_scan
                    ok "${#DEVICES[@]} device(s) found. Press Enter to continue."
                    read -r
                    ;;
                2)
                    clear
                    _menu_print_devices
                    read -rp "Press Enter to continue..." _
                    ;;
                3)
                    if _menu_pick_device "Select device to identify"; then
                        IFS='|' read -r rip rmac _ <<< "$SELECTED_DEVICE"
                        identify "$rip"
                        read -rp "Press Enter to continue..." _
                    fi
                    ;;
                4)
                    if [[ "$EUID" -ne 0 ]]; then
                        warn "Block requires root. Re-run with sudo."
                        read -rp "Press Enter..." _; continue
                    fi
                    if _menu_pick_device "Select device to BLOCK"; then
                        IFS='|' read -r rip rmac _ <<< "$SELECTED_DEVICE"
                        local target="${rmac:---}"
                        [[ "$target" == "--" ]] && target="$rip"
                        echo -e "${RED}Block $rip ($target)? [y/N]${NC}"
                        read -r yn
                        if [[ "${yn,,}" == "y" ]]; then
                            block "$target"
                            # Refresh scan to update status
                            _menu_scan
                        fi
                        read -rp "Press Enter to continue..." _
                    fi
                    ;;
                5)
                    if [[ "$EUID" -ne 0 ]]; then
                        warn "Unblock requires root. Re-run with sudo."
                        read -rp "Press Enter..." _; continue
                    fi
                    if _menu_pick_device "Select device to UNBLOCK"; then
                        IFS='|' read -r rip rmac _ <<< "$SELECTED_DEVICE"
                        local target="${rmac:---}"
                        [[ "$target" == "--" ]] && target="$rip"
                        unblock "$target"
                        _menu_scan
                        read -rp "Press Enter to continue..." _
                    fi
                    ;;
                6)
                    if [[ "$EUID" -ne 0 ]]; then
                        warn "Throttle requires root. Re-run with sudo."
                        read -rp "Press Enter..." _; continue
                    fi
                    if _menu_pick_device "Select device to THROTTLE"; then
                        IFS='|' read -r rip rmac _ <<< "$SELECTED_DEVICE"
                        if [[ "$rmac" == "--" || -z "$rmac" ]]; then
                            warn "Cannot throttle: MAC address unknown for $rip"
                            read -rp "Press Enter..." _; continue
                        fi
                        echo ""
                        echo -e "  ${BOLD}Speed examples:${NC} 512kbit, 1mbit, 2mbit, 5mbit"
                        read -rp "$(echo -e "  ${CYAN}Enter speed limit: ${NC}")" speed
                        if is_valid_speed "$speed"; then
                            throttle "$rmac" "$speed"
                            _menu_scan
                        else
                            warn "Invalid speed format."
                        fi
                        read -rp "Press Enter to continue..." _
                    fi
                    ;;
                7)
                    if [[ "$EUID" -ne 0 ]]; then
                        warn "Unthrottle requires root. Re-run with sudo."
                        read -rp "Press Enter..." _; continue
                    fi
                    if _menu_pick_device "Select device to UNTHROTTLE"; then
                        IFS='|' read -r rip rmac _ <<< "$SELECTED_DEVICE"
                        if [[ "$rmac" == "--" || -z "$rmac" ]]; then
                            warn "Cannot unthrottle: MAC address unknown."
                            read -rp "Press Enter..." _; continue
                        fi
                        unthrottle "$rmac"
                        _menu_scan
                        read -rp "Press Enter to continue..." _
                    fi
                    ;;
                8)
                    local interval
                    read -rp "$(echo -e "  ${CYAN}Refresh interval in seconds [30]: ${NC}")" interval
                    [[ -z "$interval" ]] && interval=30
                    monitor "$interval"
                    ;;
                9)
                    echo ""
                    echo -e "  ${CYAN}[1]${NC} CSV   ${CYAN}[2]${NC} JSON"
                    read -rp "$(echo -e "  ${CYAN}Format [1]: ${NC}")" fmt_choice
                    case "$fmt_choice" in
                        2) export_scan json ;;
                        *) export_scan csv  ;;
                    esac
                    read -rp "Press Enter to continue..." _
                    ;;
                l)
                    clear; list
                    read -rp "Press Enter to continue..." _
                    ;;
                r)
                    reset
                    _menu_scan
                    read -rp "Press Enter to continue..." _
                    ;;
                q)
                    echo -e "\n${GREEN}Goodbye!${NC}\n"
                    exit 0
                    ;;
                *)
                    warn "Unknown option. Try again."
                    sleep 1
                    ;;
            esac
        done
    }

    # Initial scan on menu launch
    info "Running initial scan..."
    _menu_scan
    _menu_main
}

# ─── Argument Parsing ─────────────────────────────────────────────────────────

args=()
for arg in "$@"; do
    case "$arg" in
        --dry-run)    DRY_RUN=true ;;
        --persistent) PERSISTENT=true ;;
        *)            args+=("$arg") ;;
    esac
done
set -- "${args[@]+"${args[@]}"}"

CMD="${1:-menu}"
shift || true

case "$CMD" in
    menu)
        menu
        ;;
    scan)
        check_deps; detect_network; scan "${1:-table}"
        ;;
    monitor)
        check_deps; detect_network; monitor "${1:-30}"
        ;;
    block)
        [[ -z "$1" ]] && die "Usage: $SCRIPT_NAME block <ip|mac>"
        check_deps; detect_network; block "$1"
        ;;
    unblock)
        [[ -z "$1" ]] && die "Usage: $SCRIPT_NAME unblock <ip|mac>"
        check_deps; detect_network; unblock "$1"
        ;;
    throttle)
        [[ -z "$1" || -z "$2" ]] && die "Usage: $SCRIPT_NAME throttle <mac> <speed>"
        check_deps; detect_network; throttle "$1" "$2"
        ;;
    unthrottle)
        [[ -z "$1" ]] && die "Usage: $SCRIPT_NAME unthrottle <mac>"
        check_deps; detect_network; unthrottle "$1"
        ;;
    list)
        list
        ;;
    identify|info|probe)
        check_deps; detect_network; identify "$1"
        ;;
    export)
        check_deps; export_scan "${1:-csv}"
        ;;
    reset)
        check_deps; detect_network; reset
        ;;
    help|-h|--help)
        cat <<EOF

${BOLD}netwatch${NC} — Network monitor & control

${BOLD}Usage:${NC} $SCRIPT_NAME [--dry-run] [--persistent] <command> [args]

${BOLD}Commands:${NC}
  menu                        Interactive menu (default)
  identify <ip|mac>           Deep fingerprint a device
  scan [table|json|csv]       Scan local network
  monitor [interval]          Auto-refresh every N seconds (default: 30)
  block <ip|mac>              Block a device
  unblock <ip|mac>            Remove block
  throttle <mac> <speed>      Limit bandwidth (e.g. 512kbit, 2mbit)
  unthrottle <mac>            Remove bandwidth limit
  list                        Show blocked/throttled MACs
  export [csv|json]           Export scan to $CONFIG_DIR/
  reset                       Clear all rules
  help                        Show this help

${BOLD}Flags:${NC}
  --dry-run                   Preview without applying changes
  --persistent                Save iptables rules after block/unblock

${BOLD}Examples:${NC}
  $SCRIPT_NAME                           # Launch interactive menu
  $SCRIPT_NAME scan
  $SCRIPT_NAME block AA:BB:CC:DD:EE:FF
  $SCRIPT_NAME throttle AA:BB:CC:DD:EE:FF 1mbit
  $SCRIPT_NAME --dry-run block 192.168.1.50

${BOLD}Config:${NC} $CONFIG_DIR
EOF
        ;;
    *)
        err "Unknown command: $CMD"
        echo "Run '$SCRIPT_NAME help' for usage."
        exit 1
        ;;
esac
