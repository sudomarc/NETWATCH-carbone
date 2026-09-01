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

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

version_gt(){ local a b i va vb; [[ "$1" =~ ^[0-9]+(\.[0-9]+){0,2}$ && "$2" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || return 2; IFS=. read -r -a a <<< "$1"; IFS=. read -r -a b <<< "$2"; for ((i=0;i<3;i++)); do va="${a[i]:-0}"; vb="${b[i]:-0}"; ((10#$va>10#$vb))&&return 0; ((10#$va<10#$vb))&&return 1; done; return 1; }
log(){ mkdir -p "$CONFIG_DIR"; echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$SCAN_LOG"; }
info(){ echo -e "${BLUE}[•]${NC} $*"; }; ok(){ echo -e "${GREEN}[✓]${NC} $*"; }; warn(){ echo -e "${YELLOW}[!]${NC} $*"; }; err(){ echo -e "${RED}[✗]${NC} $*" >&2; }; die(){ err "$*"; exit 1; }
require(){ [[ "$EUID" -eq 0 ]] || die "This command requires root. Run with sudo."; }
cleanup(){ :; }; trap cleanup EXIT
check_deps(){ local missing=(); for dep in nmap iptables ip awk tc; do command -v "$dep" &>/dev/null || missing+=("$dep"); done; [[ ${#missing[@]} -gt 0 ]] && die "Missing dependencies: ${missing[*]}"; }
check_update(){ local silent="${1:-false}" remote_version=""; if command -v curl &>/dev/null; then remote_version=$(curl -sSL --max-time 8 "$UPDATE_URL" 2>/dev/null | grep '^VERSION=' | head -n1 | cut -d'"' -f2); elif command -v wget &>/dev/null; then remote_version=$(wget -qO- --timeout=8 "$UPDATE_URL" 2>/dev/null | grep '^VERSION=' | head -n1 | cut -d'"' -f2); else $silent || err 'Neither curl nor wget is installed. Cannot check for updates.'; return 1; fi; [[ -z "$remote_version" ]] && { $silent || err 'Failed to fetch remote version information.'; return 1; }; if version_gt "$remote_version" "$VERSION"; then $silent || ok "A new version is available: v$remote_version (current v$VERSION)"; return 0; else $silent || ok "netwatch is up-to-date (v$VERSION)."; return 1; fi; }
apply_update(){ check_update || return 0; warn 'Automatic self-update is intentionally disabled; review and install releases manually.'; return 1; }
auto_check_update(){ :; }
detect_network(){ GATEWAY=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}'); [[ -z "$GATEWAY" ]] && die 'No default gateway found.'; IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}'); [[ -z "$IFACE" ]] && die 'No default interface found.'; local ip; ip=$(ip addr show "$IFACE" 2>/dev/null | awk '/inet / {print $2; exit}'); [[ -z "$ip" ]] && die "No local IP on interface $IFACE."; local prefix="${ip#*/}" base; if command -v ipcalc &>/dev/null; then base=$(ipcalc -n "$ip" 2>/dev/null | awk -F= '/^NETWORK/ {print $2}'); fi; [[ -n "$base" ]] && SUBNET="$base/$prefix" || SUBNET="$(echo "${ip%/*}" | cut -d'.' -f1-3).0/24"; info "Interface: $IFACE | Subnet: $SUBNET | Gateway: $GATEWAY"; }
vendor(){ local oui; oui=$(echo "${1^^}" | cut -d':' -f1-3); case "$oui" in 00:1A:2B|00:50:56|00:0C:29|00:05:69) echo VMware;; 00:1C:42) echo Parallels;; 00:03:93|A4:4C:C8|00:26:9E|00:0D:93|3C:07:54|A8:86:DD) echo Apple;; 00:1E:58|00:1F:3A|00:21:5C|14:18:77) echo Dell;; 00:1A:A0|00:1E:4C|00:24:E8|30:8D:99) echo HP;; 00:25:90|00:1B:21|00:1D:09|8C:EC:4B) echo Intel;; 00:16:E9|00:18:7D|00:1F:33|F8:7B:20) echo Cisco;; 20:CF:30|2C:B0:5D|64:B4:73) echo Xiaomi;; A4:77:33|AC:CF:85|40:B0:34|B4:79:A7) echo Samsung;; B8:27:EB|DC:A6:32|E4:5F:01) echo Raspberry Pi;; *) echo Unknown;; esac; }
is_valid_mac(){ [[ "${1^^}" =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]]; }; is_valid_speed(){ [[ "$1" =~ ^[0-9]+(kbit|mbit|gbit|kbps|mbps)$ ]]; }; normalize_mac(){ echo "${1^^}"; }
scan(){ local format="${1:-table}"; info "Scanning $SUBNET ..."; mkdir -p "$CONFIG_DIR"; local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/netwatch_XXXXXX") || die 'Cannot create temporary file.'; nmap -sn -PR "$SUBNET" --max-retries 2 --host-timeout 8s -oG - 2>/dev/null | awk '/^Host:/ && /Up/' > "$tmp" || die 'nmap scan failed.'; local count=0; while read -r line; do local ip; ip=$(awk '{print $2}' <<< "$line"); [[ "$ip" == "$GATEWAY" ]] && continue; local mac; mac=$(ip neigh show "$ip" 2>/dev/null | awk 'NR==1 {print $5}'); [[ -z "$mac" || "$mac" == FAILED || "$mac" == INCOMPLETE ]] && mac='--'; local hostname; hostname=$(getent hosts "$ip" 2>/dev/null | awk 'NR==1 {print $2}'); [[ -n "$hostname" ]] || hostname='-'; local v='-'; [[ "$mac" != '--' ]] && v=$(vendor "$mac"); ((count++)); case "$format" in json) printf '%s\n' "{\"ip\":\"$ip\",\"mac\":\"$mac\",\"hostname\":\"$hostname\",\"vendor\":\"$v\"}";; csv) printf '"%s","%s","%s","%s"\n' "$ip" "$mac" "$hostname" "$v";; raw) printf '%s|%s|%s|%s|-|-\n' "$ip" "$mac" "$hostname" "$v";; *) printf '%-16s %-18s %-22s %-12s\n' "$ip" "$mac" "${hostname:0:22}" "${v:0:12}";; esac; done < "$tmp"; rm -f -- "$tmp"; [[ "$format" == table ]] && ok "$count device(s) found."; log "scan: $count devices on $SUBNET"; }
monitor(){ local interval="${1:-30}"; [[ "$interval" =~ ^[1-9][0-9]*$ && "$interval" -le 3600 ]] || die 'Interval must be between 1 and 3600 seconds.'; while true; do clear; detect_network; scan table; sleep "$interval"; done; }
block(){ require; local target="$1"; [[ -n "$target" ]] || die "Usage: $SCRIPT_NAME block <ip|mac>"; warn 'Block is Linux gateway/router functionality and must be evaluated against the current firewall configuration.'; $DRY_RUN && { warn '[DRY-RUN] no firewall changes made.'; return 0; }; die 'Blocking is disabled in this stabilized build until Netwatch-owned firewall rules are implemented safely.'; }
unblock(){ require; local target="$1"; [[ -n "$target" ]] || die "Usage: $SCRIPT_NAME unblock <ip|mac>"; warn 'Unblock is disabled in this stabilized build until Netwatch-owned firewall rules are implemented safely.'; }
throttle(){ require; local mac="$1" speed="$2"; is_valid_mac "$mac" || die "Invalid MAC: '$mac'"; is_valid_speed "$speed" || die "Invalid speed '$speed'."; warn 'Throttle is disabled in this stabilized build until Netwatch-owned QoS rules are implemented safely.'; }
unthrottle(){ require; local mac="$1"; is_valid_mac "$mac" || die "Invalid MAC: '$mac'"; warn 'Unthrottle is disabled in this stabilized build until Netwatch-owned QoS rules are implemented safely.'; }
list(){ echo 'Blocked MACs:'; [[ -f "$BLOCK_FILE" ]] && cat "$BLOCK_FILE" || echo '  (none)'; echo; echo 'Throttled MACs:'; [[ -f "$THROTTLE_FILE" ]] && cat "$THROTTLE_FILE" || echo '  (none)'; }
export_scan(){ local fmt="${1:-csv}"; [[ "$fmt" == csv || "$fmt" == json ]] || die 'Export format must be csv or json.'; mkdir -p "$CONFIG_DIR"; detect_network; local outfile="$CONFIG_DIR/export_$(date '+%Y%m%d_%H%M%S').$fmt"; scan "$fmt" > "$outfile" || die 'Export failed.'; ok "Saved to $outfile"; }
identify(){ local target="$1"; [[ -n "$target" ]] || die "Usage: $SCRIPT_NAME identify <ip|mac>"; detect_network; if is_valid_mac "$target"; then ip=$(ip neigh show 2>/dev/null | grep -i "$target" | awk '{print $1}' | head -1); else ip="$target"; fi; [[ -n "$ip" ]] || die 'Target not found.'; echo "Device Profile: $ip"; nmap -sV -O --osscan-guess --max-retries 1 --host-timeout 30s -T4 "$ip" 2>/dev/null || true; log "identify: $ip"; }
reset(){ require; warn 'Reset is disabled until Netwatch-owned firewall/QoS state is implemented safely.'; $DRY_RUN && warn '[DRY-RUN] no changes made.'; return 1; }
menu(){ check_deps; detect_network; while true; do echo; echo 'NETWATCH — Linux'; echo '1) Scan  2) Identify  3) Block  4) Unblock  5) Throttle  6) Unthrottle  7) List  8) Monitor  9) Export  R) Reset  U) Update  Q) Quit'; read -r -p 'Choice: ' choice || exit 0; case "${choice,,}" in 1) scan table;; 2) read -r -p 'Target: ' t; identify "$t";; 3) read -r -p 'Target: ' t; block "$t";; 4) read -r -p 'Target: ' t; unblock "$t";; 5) read -r -p 'MAC: ' t; read -r -p 'Speed: ' s; throttle "$t" "$s";; 6) read -r -p 'MAC: ' t; unthrottle "$t";; 7) list;; 8) read -r -p 'Interval [30]: ' i; monitor "${i:-30}";; 9) read -r -p 'Format [csv/json]: ' f; export_scan "${f:-csv}";; r) reset;; u) check_update;; q) exit 0;; *) warn 'Unknown option.';; esac; done; }
args=(); for arg in "$@"; do case "$arg" in --dry-run) DRY_RUN=true;; --persistent) PERSISTENT=true;; *) args+=("$arg");; esac; done
set -- "${args[@]+"${args[@]}"}"; CMD="${1:-menu}"; shift || true
case "$CMD" in menu) menu;; update) apply_update;; scan) check_deps; detect_network; scan "${1:-table}";; monitor) check_deps; detect_network; monitor "${1:-30}";; block) check_deps; detect_network; block "$1";; unblock) check_deps; detect_network; unblock "$1";; throttle) check_deps; detect_network; throttle "$1" "$2";; unthrottle) check_deps; detect_network; unthrottle "$1";; list) list;; identify|info|probe) check_deps; identify "$1";; export) check_deps; export_scan "${1:-csv}";; reset) check_deps; detect_network; reset;; help|-h|--help) cat <<EOF
netwatch — Linux network monitor & control
Usage: $SCRIPT_NAME [--dry-run] [--persistent] <command> [args]
Commands: menu scan monitor identify block unblock throttle unthrottle list export reset update help
EOF
;; *) die "Unknown command: $CMD. Run '$SCRIPT_NAME help'.";; esac
