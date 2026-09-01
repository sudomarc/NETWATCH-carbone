#!/bin/bash
# netwatch — Network monitor & control tool
# Usage: netwatch <cmd> [args]

VERSION="1.2"
UPDATE_URL="https://raw.githubusercontent.com/sudomarc/NETWATCH-carbone/main/netwatch.sh"
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

version_gt() {
    local ip1 ip2
    IFS='.' read -r -a ip1 <<< "$1"
    IFS='.' read -r -a ip2 <<< "$2"
    for ((i=${#ip1[@]}; i<3; i++)); do ip1[i]=0; done
    for ((i=${#ip2[@]}; i<3; i++)); do ip2[i]=0; done
    for ((i=0; i<3; i++)); do
        if ((10#${ip1[i]} > 10#${ip2[i]})); then return 0
        elif ((10#${ip1[i]} < 10#${ip2[i]})); then return 1
        fi
    done
    return 1
}

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

check_update() {
    local silent="${1:-false}"
    mkdir -p "$CONFIG_DIR"
    if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
        $silent || err "Neither curl nor wget is installed. Cannot check for updates."
        return 1
    fi
    local remote_version=""
    if $silent; then
        if command -v curl &>/dev/null; then
            remote_version=$(curl -sSL --max-time 3 "$UPDATE_URL" 2>/dev/null | grep "^VERSION=" | head -n1 | cut -d'"' -f2)
        else
            remote_version=$(wget -qO- --timeout=3 "$UPDATE_URL" 2>/dev/null | grep "^VERSION=" | head -n1 | cut -d'"' -f2)
        fi
    else
        info "Checking for updates..."
        if command -v curl &>/dev/null; then
            remote_version=$(curl -sSL --max-time 8 "$UPDATE_URL" 2>/dev/null | grep "^VERSION=" | head -n1 | cut -d'"' -f2)
        else
            remote_version=$(wget -qO- --timeout=8 "$UPDATE_URL" 2>/dev/null | grep "^VERSION=" | head -n1 | cut -d'"' -f2)
        fi
    fi
    if [[ -z "$remote_version" ]]; then
        $silent || err "Failed to fetch remote version information."
        return 1
    fi
    if version_gt "$remote_version" "$VERSION"; then
        if $silent; then
            echo -e "\n${YELLOW}[!] A new version of netwatch is available: v$remote_version (current: v$VERSION)${NC}"
            echo -e "${YELLOW}[!] Run '$SCRIPT_NAME update' or select 'U' in the menu to update.${NC}\n"
        else
            ok "A new version of netwatch is available: v$remote_version (current: v$VERSION)"
            return 0
        fi
    else
        $silent || ok "netwatch is up-to-date (v$VERSION)."
        return 1
    fi
}

apply_update() {
    if ! check_update false; then
        return 0
    fi
    local remote_version=""
    if command -v curl &>/dev/null; then
        remote_version=$(curl -sSL --max-time 8 "$UPDATE_URL" 2>/dev/null | grep "^VERSION=" | head -n1 | cut -d'"' -f2)
    else
        remote_version=$(wget -qO- --timeout=8 "$UPDATE_URL" 2>/dev/null | grep "^VERSION=" | head -n1 | cut -d'"' -f2)
    fi
    [[ -z "$remote_version" ]] && die "Error fetching remote version."
    local tmp_file
    tmp_file=$(mktemp "${TMPDIR:-/tmp}/netwatch_update_XXXXXX.sh")
    info "Downloading netwatch v$remote_version..."
    if command -v curl &>/dev/null; then
        curl -sSL --max-time 15 -o "$tmp_file" "$UPDATE_URL"
    else
        wget -qO "$tmp_file" --timeout=15 "$UPDATE_URL"
    fi
    if [[ ! -s "$tmp_file" ]]; then rm -f "$tmp_file"; die "Download failed or empty file."; fi
    if ! grep -q "^#!/bin/bash" "$tmp_file"; then rm -f "$tmp_file"; die "Downloaded file is invalid (missing shebang)."; fi
    local target_script="$0"
    local real_script
    real_script=$(readlink -f "$target_script" 2>/dev/null || realpath "$target_script" 2>/dev/null || echo "$target_script")
    if [[ ! -w "$real_script" ]]; then
        err "No write permissions to update '$real_script'."
        err "Please run with sudo: sudo $SCRIPT_NAME update"
        rm -f "$tmp_file"
        return 1
    fi
    info "Backing up current script to ${real_script}.bak..."
    cp "$real_script" "${real_script}.bak" || die "Failed to create backup."
    info "Applying update..."
    mv "$tmp_file" "$real_script" || { mv "${real_script}.bak" "$real_script"; die "Failed to replace the script file. Restored backup."; }
    chmod +x "$real_script"
    ok "Successfully updated netwatch to v$remote_version!"
    rm -f "${real_script}.bak"
    info "Restarting netwatch..."
    exec "$real_script" "$@"
}

auto_check_update() {
    local last_check=0
    if [[ -f "$CONFIG_DIR/.last_update_check" ]]; then last_check=$(cat "$CONFIG_DIR/.last_update_check" 2>/dev/null || echo 0); fi
    local now
    now=$(date +%s 2>/dev/null || echo 0)
    if (( now - last_check > 86400 )); then
        echo "$now" > "$CONFIG_DIR/.last_update_check" 2>/dev/null
        check_update true
    fi
}

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

vendor() { local mac="${1^^}"; local oui; oui=$(echo "$mac" | cut -d':' -f1-3); case "$oui" in 00:1A:2B|00:50:56|00:0C:29|00:05:69) echo VMware;; 00:1C:42) echo Parallels;; 00:03:93|A4:4C:C8|00:26:9E|00:0D:93|3C:07:54|A8:86:DD) echo Apple;; 00:1E:58|00:1F:3A|00:21:5C|14:18:77) echo Dell;; 00:1A:A0|00:1E:4C|00:24:E8|30:8D:99) echo HP;; 00:25:90|00:1B:21|00:1D:09|8C:EC:4B) echo Intel;; 00:16:E9|00:18:7D|00:1F:33|F8:7B:20) echo Cisco;; 20:CF:30|2C:B0:5D|64:B4:73) echo Xiaomi;; 00:1F:82|D4:61:9D|00:E0:FC) echo Huawei;; A4:77:33|AC:CF:85|40:B0:34|B4:79:A7) echo Samsung;; AC:22:0B|B8:5A:73|F0:F6:1C|04:D9:F5) echo Asus;; 18:B4:30|FC:D7:33|48:45:20|54:AF:97) echo TP-Link;; 00:26:B6|00:27:0E|9C:5C:8E|20:4E:7F) echo Netgear;; B8:27:EB|DC:A6:32|E4:5F:01) echo Raspberry Pi;; 00:15:5D) echo Hyper-V;; *) echo Unknown;; esac; }

is_valid_mac(){ [[ "${1^^}" =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]]; }
is_valid_speed(){ [[ "$1" =~ ^[0-9]+(kbit|mbit|gbit|kbps|mbps)$ ]]; }
normalize_mac(){ echo "${1^^}"; }

scan(){
  local format="${1:-table}"; info "Scanning $SUBNET ..."; mkdir -p "$CONFIG_DIR"; local tmp; tmp=$(mktemp /tmp/netwatch_XXXX.tmp)
  nmap -sn -PR "$SUBNET" --max-retries 2 --host-timeout 8s -oG - 2>/dev/null | awk '/^Host:/ && /Up/' > "$tmp"; ip neigh flush nud stale 2>/dev/null || true
  local count=0; local -a results=()
  while read -r line; do
    local ip; ip=$(awk '{print $2}' <<< "$line"); [[ "$ip" == "$GATEWAY" ]] && continue
    local mac; mac=$(ip neigh show "$ip" 2>/dev/null | awk 'NR==1 {print $5}'); [[ -z "$mac" || "$mac" == "FAILED" || "$mac" == "INCOMPLETE" ]] && mac="--"
    local hostname; hostname=$(timeout 1 bash -c "getent hosts $ip 2>/dev/null | awk '{print \$2}'" 2>/dev/null || echo "-"); [[ -z "$hostname" ]] && hostname="-"
    local v="-"; [[ "$mac" != "--" ]] && v=$(vendor "$mac")
    local blocked="-"; [[ "$mac" != "--" ]] && grep -qi "^$(normalize_mac "$mac")$" "$BLOCK_FILE" 2>/dev/null && blocked="BLOCKED"
    local throttled="-"; [[ "$mac" != "--" ]] && throttled=$(grep -i "^$(normalize_mac "$mac")|" "$THROTTLE_FILE" 2>/dev/null | cut -d'|' -f2); [[ -n "$throttled" ]] || throttled="-"
    results+=("$ip|$mac|$hostname|$v|$blocked|$throttled"); ((count++))
  done < "$tmp"
  case "$format" in
    json) echo "["; local first=true; for r in "${results[@]}"; do IFS='|' read -r rip rmac rhost rv rblock rthrottle <<< "$r"; $first || echo ","; first=false; printf '  {"ip":"%s","mac":"%s","hostname":"%s","vendor":"%s","blocked":"%s","throttled":"%s"}' "$rip" "$rmac" "$rhost" "$rv" "$rblock" "$rthrottle"; done; echo ""; echo "]" ;;
    csv) echo "ip,mac,hostname,vendor,blocked,throttled"; for r in "${results[@]}"; do echo "$r" | tr '|' ','; done ;;
    raw) for r in "${results[@]}"; do echo "$r"; done ;;
    *) echo ""; printf "${BOLD}%-3s %-16s %-18s %-22s %-12s %-10s %-10s${NC}\n" "#" "IP" "MAC" "Hostname" "Vendor" "Blocked" "Throttled"; printf '%s\n' "$(printf '─%.0s' {1..95})"; local idx=1; for r in "${results[@]}"; do IFS='|' read -r rip rmac rhost rv rblock rthrottle <<< "$r"; printf "%-3s %-16s %-18s %-22s %-12s %-10s %-10s\n" "$idx" "$rip" "$rmac" "${rhost:0:22}" "${rv:0:12}" "$rblock" "$rthrottle"; ((idx++)); done; echo ""; ok "$count device(s) found." ;;
  esac
  log "scan: $count devices on $SUBNET"; rm -f "$tmp"
}

monitor(){ local interval="${1:-30}"; [[ ! "$interval" =~ ^[0-9]+$ ]] && die "Interval must be a number (seconds)."; info "Monitor mode: scanning every ${interval}s. Press Ctrl+C to stop."; while true; do clear; scan table; sleep "$interval"; done; }

block(){
  require; local target="$1"; [[ -z "$target" ]] && die "Usage: $SCRIPT_NAME block <ip|mac>"; local ip mac
  if is_valid_mac "$target"; then mac=$(normalize_mac "$target"); ip=$(ip neigh show 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1); [[ -z "$ip" ]] && die "Cannot resolve IP for $mac. Run scan first."; else ip="$target"; mac=$(ip neigh show "$ip" 2>/dev/null | awk 'NR==1 {print $5}'); fi
  mkdir -p "$CONFIG_DIR"; [[ -z "$GATEWAY" ]] && detect_network
  local is_router=false; [[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" == "1" ]] && is_router=true
  if $is_router; then
    info "Router mode — blocking via iptables"
    if $DRY_RUN; then warn "[DRY-RUN] iptables DROP for $ip / $mac"; else iptables -A FORWARD -s "$ip" -j DROP 2>/dev/null || true; iptables -A FORWARD -d "$ip" -j DROP 2>/dev/null || true; [[ -n "$mac" ]] && { iptables -A INPUT -m mac --mac-source "$mac" -j DROP 2>/dev/null || true; iptables -A FORWARD -m mac --mac-source "$mac" -j DROP 2>/dev/null || true; }; fi
  fi
  if command -v arpspoof &>/dev/null; then
    info "ARP spoofing $ip (gateway: $GATEWAY)"
    if $DRY_RUN; then warn "[DRY-RUN] arpspoof -i $IFACE -t $ip $GATEWAY"; else sysctl -qw net.ipv4.ip_forward=1 2>/dev/null || true; local pidfile="$CONFIG_DIR/arp_${ip//./_}.pid"; arpspoof -i "$IFACE" -t "$ip" "$GATEWAY" &>/dev/null & echo $! > "$pidfile"; arpspoof -i "$IFACE" -t "$GATEWAY" "$ip" &>/dev/null & echo $! >> "$pidfile"; ok "ARP spoof active (PIDs in $pidfile)"; fi
  else warn "arpspoof not found. Install: sudo apt install dsniff"; fi
  if [[ -n "$mac" ]]; then grep -qi "^$mac$" "$BLOCK_FILE" 2>/dev/null || echo "$mac" >> "$BLOCK_FILE"; fi
  echo "$ip" >> "$CONFIG_DIR/blocked_ips" 2>/dev/null || true
  $PERSISTENT && _save_iptables; log "block: $ip ($mac)"; ok "Blocked: $ip${mac:+ ($mac)}"
}

unblock(){
  require; local target="$1"; [[ -z "$target" ]] && die "Usage: $SCRIPT_NAME unblock <ip|mac>"; local ip mac
  if is_valid_mac "$target"; then mac=$(normalize_mac "$target"); ip=$(ip neigh show 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1); else ip="$target"; mac=$(ip neigh show "$ip" 2>/dev/null | awk 'NR==1 {print $5}'); fi
  [[ -z "$GATEWAY" ]] && detect_network 2>/dev/null || true
  local pidfile="$CONFIG_DIR/arp_${ip//./_}.pid"; if [[ -f "$pidfile" ]]; then while read -r pid; do kill "$pid" 2>/dev/null || true; done < "$pidfile"; rm -f "$pidfile"; fi
  [[ -n "$ip" ]] && { iptables -D FORWARD -s "$ip" -j DROP 2>/dev/null || true; iptables -D FORWARD -d "$ip" -j DROP 2>/dev/null || true; }
  [[ -n "$mac" ]] && { iptables -D INPUT -m mac --mac-source "$mac" -j DROP 2>/dev/null || true; iptables -D FORWARD -m mac --mac-source "$mac" -j DROP 2>/dev/null || true; sed -i "/^${mac}$/Id" "$BLOCK_FILE" 2>/dev/null || true; }
  [[ -n "$ip" ]] && sed -i "/^${ip}$/d" "$CONFIG_DIR/blocked_ips" 2>/dev/null || true
  $PERSISTENT && _save_iptables; log "unblock: $ip ($mac)"; ok "Unblocked: $ip"
}

throttle(){
  require; local mac speed; mac=$(normalize_mac "$1"); speed="$2"; is_valid_mac "$mac" || die "Invalid MAC: '$1'"; is_valid_speed "$speed" || die "Invalid speed '$speed'. Examples: 512kbit, 2mbit"; [[ -z "$IFACE" ]] && detect_network
  local mark; mark=$(( 0x$(echo "$mac" | tr -d ':' | tail -c 4) % 65535 + 1 )); info "Throttling $mac → $speed (mark $mark) ..."
  if $DRY_RUN; then warn "[DRY RUN] Would set HTB rate $speed for $mac on $IFACE"; else iptables -t mangle -A PREROUTING -m mac --mac-source "$mac" -j MARK --set-mark "$mark" 2>/dev/null || true; tc qdisc show dev "$IFACE" 2>/dev/null | grep -q "htb" || tc qdisc add dev "$IFACE" root handle 1: htb default 0 2>/dev/null || true; tc class add dev "$IFACE" parent 1: classid "1:$mark" htb rate "$speed" ceil "$speed" 2>/dev/null || true; tc filter add dev "$IFACE" parent 1: protocol ip prio "$mark" handle "$mark" fw classid "1:$mark" 2>/dev/null || true; mkdir -p "$CONFIG_DIR"; grep -qi "^$mac|" "$THROTTLE_FILE" 2>/dev/null && sed -i "/^${mac}|/Id" "$THROTTLE_FILE"; echo "$mac|$speed|$mark" >> "$THROTTLE_FILE"; fi
  $PERSISTENT && _save_iptables; log "throttle: $mac → $speed"; ok "Throttled $mac to $speed"
}

unthrottle(){
  require; local mac; mac=$(normalize_mac "$1"); is_valid_mac "$mac" || die "Invalid MAC: '$1'"; [[ -z "$IFACE" ]] && detect_network; local entry mark; entry=$(grep -i "^$mac|" "$THROTTLE_FILE" 2>/dev/null | head -1); mark=$(awk -F'|' '{print $3}' <<< "$entry"); if $DRY_RUN; then warn "[DRY RUN] Would remove throttle rules for $mac"; else [[ -n "$mark" ]] && { iptables -t mangle -D PREROUTING -m mac --mac-source "$mac" -j MARK --set-mark "$mark" 2>/dev/null || true; tc class del dev "$IFACE" parent 1: classid "1:$mark" 2>/dev/null || true; tc filter del dev "$IFACE" parent 1: protocol ip prio "$mark" 2>/dev/null || true; }; sed -i "/^${mac}|/Id" "$THROTTLE_FILE" 2>/dev/null || true; fi; log "unthrottle: $mac"; ok "Unthrottled $mac"
}

list(){ echo -e "\n${BOLD}${RED}Blocked MACs:${NC}"; if [[ -f "$BLOCK_FILE" && -s "$BLOCK_FILE" ]]; then cat -n "$BLOCK_FILE"; else echo "  (none)"; fi; echo -e "\n${BOLD}${YELLOW}Throttled MACs:${NC}"; if [[ -f "$THROTTLE_FILE" && -s "$THROTTLE_FILE" ]]; then printf "  %-3s %-20s %-10s\n" "#" "MAC" "Speed"; local i=1; while IFS='|' read -r mac speed _; do printf "  %-3s %-20s %-10s\n" "$i" "$mac" "$speed"; ((i++)); done < "$THROTTLE_FILE"; else echo "  (none)"; fi; echo ""; }
export_scan(){ local fmt="${1:-csv}"; local outfile="$CONFIG_DIR/export_$(date '+%Y%m%d_%H%M%S').$fmt"; mkdir -p "$CONFIG_DIR"; detect_network; info "Exporting scan as $fmt → $outfile"; scan "$fmt" > "$outfile"; ok "Saved to $outfile"; }
identify(){ local target="$1"; [[ -z "$target" ]] && die "Usage: $SCRIPT_NAME identify <ip|mac>"; local ip mac; if is_valid_mac "$target"; then mac=$(normalize_mac "$target"); ip=$(ip neigh show 2>/dev/null | grep -i "$mac" | awk '{print $1}' | head -1); [[ -z "$ip" ]] && die "Cannot find IP for MAC $mac in ARP cache. Run 'scan' first."; else ip="$target"; mac=$(ip neigh show "$ip" 2>/dev/null | awk 'NR==1 {print $5}'); fi; echo "Device Profile: $ip"; echo "IP Address : $ip"; echo "MAC Address: ${mac:---}"; local rdns; rdns=$(dig +short +time=2 -x "$ip" 2>/dev/null | head -1 | sed 's/\.$//'); [[ -z "$rdns" ]] && rdns=$(getent hosts "$ip" 2>/dev/null | awk '{print $2}'); echo "rDNS: ${rdns:-(none)}"; local v="Unknown"; [[ "$mac" != "--" ]] && v=$(vendor "$mac"); echo "Vendor: $v"; nmap -sV -O --osscan-guess --version-intensity 5 --max-retries 1 --host-timeout 30s -T4 "$ip" 2>/dev/null; log "identify: $ip ($mac)"; }
reset(){ require; local iface="${IFACE:-$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')}"; warn "This will flush all INPUT/FORWARD iptables rules and TC qdiscs. Continue? [y/N]"; read -r yn; [[ "${yn,,}" != "y" ]] && { info "Aborted."; return 0; }; iptables -F INPUT 2>/dev/null || true; iptables -F FORWARD 2>/dev/null || true; iptables -t mangle -F PREROUTING 2>/dev/null || true; tc qdisc del dev "$iface" root 2>/dev/null || true; > "$BLOCK_FILE" 2>/dev/null || true; > "$THROTTLE_FILE" 2>/dev/null || true; log "reset: all rules cleared"; ok "All rules cleared."; }
_save_iptables(){ if command -v iptables-save &>/dev/null; then local rules_file="/etc/iptables/rules.v4"; mkdir -p "$(dirname "$rules_file")"; iptables-save | tee "$rules_file" > /dev/null; info "iptables rules saved to $rules_file"; else warn "--persistent: iptables-save not found. Install iptables-persistent."; fi; }
menu(){ check_deps; detect_network; auto_check_update; local choice; while true; do clear; echo -e "${BOLD}${CYAN}NETWATCH — Linux${NC}"; echo "Interface: $IFACE | Subnet: $SUBNET | Gateway: $GATEWAY"; echo; echo "[1] Scan [2] Devices [3] Identify [4] Block [5] Unblock"; echo "[6] Throttle [7] Unthrottle [8] Monitor [9] Export [L] List [R] Reset [U] Update [Q] Quit"; read -rp "Choice: " choice || exit 0; case "${choice,,}" in 1) scan table; read -rp "Press Enter..." _ ;; 2) clear; scan table; read -rp "Press Enter..." _ ;; 3) read -rp "Target IP/MAC: " target; identify "$target"; read -rp "Press Enter..." _ ;; 4) read -rp "Target IP/MAC: " target; block "$target"; read -rp "Press Enter..." _ ;; 5) read -rp "Target IP/MAC: " target; unblock "$target"; read -rp "Press Enter..." _ ;; 6) read -rp "MAC: " target; read -rp "Speed: " speed; throttle "$target" "$speed"; read -rp "Press Enter..." _ ;; 7) read -rp "MAC: " target; unthrottle "$target"; read -rp "Press Enter..." _ ;; 8) read -rp "Interval [30]: " interval; [[ -z "$interval" ]] && interval=30; monitor "$interval" ;; 9) read -rp "Format [csv/json]: " fmt; [[ -z "$fmt" ]] && fmt=csv; export_scan "$fmt"; read -rp "Press Enter..." _ ;; l) clear; list; read -rp "Press Enter..." _ ;; r) reset; read -rp "Press Enter..." _ ;; u) apply_update; read -rp "Press Enter..." _ ;; q) exit 0 ;; *) warn "Unknown option."; sleep 1 ;; esac; done; }
args=(); for arg in "$@"; do case "$arg" in --dry-run) DRY_RUN=true ;; --persistent) PERSISTENT=true ;; *) args+=("$arg") ;; esac; done
set -- "${args[@]+"${args[@]}"}"; CMD="${1:-menu}"; shift || true
case "$CMD" in menu) menu ;; update) apply_update ;; scan) check_deps; detect_network; scan "${1:-table}" ;; monitor) check_deps; detect_network; monitor "${1:-30}" ;; block) [[ -z "$1" ]] && die "Usage: $SCRIPT_NAME block <ip|mac>"; check_deps; detect_network; block "$1" ;; unblock) [[ -z "$1" ]] && die "Usage: $SCRIPT_NAME unblock <ip|mac>"; check_deps; detect_network; unblock "$1" ;; throttle) [[ -z "$1" || -z "$2" ]] && die "Usage: $SCRIPT_NAME throttle <mac> <speed>"; check_deps; detect_network; throttle "$1" "$2" ;; unthrottle) [[ -z "$1" ]] && die "Usage: $SCRIPT_NAME unthrottle <mac>"; check_deps; detect_network; unthrottle "$1" ;; list) list ;; identify|info|probe) check_deps; detect_network; identify "$1" ;; export) check_deps; export_scan "${1:-csv}" ;; reset) check_deps; detect_network; reset ;; help|-h|--help) cat <<EOF
netwatch — Linux network monitor & control

Usage: $SCRIPT_NAME [--dry-run] [--persistent] <command> [args]

Commands:
  menu, scan [table|json|csv], monitor [interval], identify <ip|mac>
  block <ip|mac>, unblock <ip|mac>, throttle <mac> <speed>
  unthrottle <mac>, list, export [csv|json], reset, update, help
EOF
;; *) die "Unknown command: $CMD. Run '$SCRIPT_NAME help'." ;; esac
