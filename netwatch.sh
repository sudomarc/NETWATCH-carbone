#!/bin/bash
# netwatch — Network monitor & control tool
# Usage: netwatch <cmd> [args]

VERSION="1.3.0"
SCRIPT_NAME="$(basename "$0")"
CONFIG_DIR="${NETWATCH_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/netwatch}"
BLOCK_FILE="$CONFIG_DIR/blocked_macs"
BLOCK_IP_FILE="$CONFIG_DIR/blocked_ips"
THROTTLE_FILE="$CONFIG_DIR/throttled_macs"
SCAN_LOG="$CONFIG_DIR/scan_history.log"
SUBNET=""
GATEWAY=""
IFACE=""
DRY_RUN=false
PERSISTENT=false
TMP_FILE=""

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info(){ printf '%b[.]%b %s\n' "$BLUE" "$NC" "$*"; }
ok(){ printf '%b[OK]%b %s\n' "$GREEN" "$NC" "$*"; }
warn(){ printf '%b[!]%b %s\n' "$YELLOW" "$NC" "$*" >&2; }
err(){ printf '%b[X]%b %s\n' "$RED" "$NC" "$*" >&2; }
die(){ err "$*"; exit 1; }
command_exists(){ command -v "$1" >/dev/null 2>&1; }
log(){ mkdir -p "$CONFIG_DIR" || return 1; printf '[%s] %s\n' "$(date '+%F %T')" "$*" >>"$SCAN_LOG"; }
cleanup(){ [[ -n "$TMP_FILE" && -f "$TMP_FILE" ]] && rm -f -- "$TMP_FILE"; }
trap cleanup EXIT INT TERM

require_root(){ ((EUID==0)) || die "This command requires root. Run with sudo."; }
require_deps(){ local d missing=(); for d in "$@"; do command_exists "$d" || missing+=("$d"); done; ((${#missing[@]}==0)) || die "Missing dependencies: ${missing[*]}"; }

is_valid_ipv4(){
  local IFS=. parts x
  read -r -a parts <<<"$1"
  [[ ${#parts[@]} -eq 4 ]] || return 1
  for x in "${parts[@]}"; do [[ "$x" =~ ^[0-9]+$ && "$x" -le 255 ]] || return 1; done
}
is_valid_mac(){ [[ "${1^^}" =~ ^([0-9A-F]{2}:){5}[0-9A-F]{2}$ ]]; }
normalize_mac(){ printf '%s\n' "${1^^}"; }
is_valid_speed(){
  local n u
  [[ "$1" =~ ^([1-9][0-9]{0,8})(kbit|mbit|gbit|kbps|mbps)$ ]] || return 1
  n=${BASH_REMATCH[1]}; u=${BASH_REMATCH[2]}
  case "$u" in
    kbit|kbps) ((n<=1000000)) ;;
    mbit|mbps) ((n<=1000)) ;;
    gbit) ((n<=1)) ;;
  esac
}
version_gt(){
  local a b i va vb
  [[ "$1" =~ ^[0-9]+(\.[0-9]+){0,2}$ && "$2" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || return 2
  IFS=. read -r -a a <<<"$1"; IFS=. read -r -a b <<<"$2"
  for ((i=0;i<3;i++)); do
    va="${a[i]:-0}"; vb="${b[i]:-0}"
    ((10#$va>10#$vb)) && return 0
    ((10#$va<10#$vb)) && return 1
  done
  return 1
}
json_escape(){
  printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r/\\r/g'
}
csv_escape(){ local s="$1"; s=${s//"/""}; printf '"%s"' "$s"; }

check_deps(){
  case "$1" in
    scan|monitor|export|identify) require_deps nmap ip awk ;;
    block|unblock) require_deps ip iptables awk ;;
    throttle|unthrottle) require_deps ip iptables tc awk ;;
    reset) require_deps iptables tc ;;
    menu) return 0 ;;
    *) return 2 ;;
  esac
}

check_update(){
  local body remote
  if command_exists curl; then
    body=$(curl -fsSL --max-time 5 'https://raw.githubusercontent.com/sudomarc/NETWATCH-carbone/main/netwatch.sh') || { warn 'Update check failed.'; return 1; }
  elif command_exists wget; then
    body=$(wget -qO- --timeout=5 'https://raw.githubusercontent.com/sudomarc/NETWATCH-carbone/main/netwatch.sh') || { warn 'Update check failed.'; return 1; }
  else
    warn 'curl/wget unavailable; update check skipped.'
    return 1
  fi
  remote=$(printf '%s\n' "$body" | awk -F'"' '/^VERSION=/{print $2; exit}')
  [[ "$remote" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || { err 'Invalid remote version; rejected.'; return 1; }
  if version_gt "$remote" "$VERSION"; then
    warn "Update available: v$remote (current v$VERSION). Install from a reviewed Git commit/tag manually."
    return 0
  fi
  ok "Up to date: v$VERSION"
  return 1
}
apply_update(){
  check_update || return 1
  warn 'Automatic self-update is disabled for supply-chain safety.'
  return 1
}
auto_check_update(){ :; }

detect_network(){
  local ipaddr network
  GATEWAY=$(ip -4 route show default 2>/dev/null | awk 'NR==1{print $3}')
  IFACE=$(ip -4 route show default 2>/dev/null | awk 'NR==1{print $5}')
  [[ -n "$GATEWAY" && -n "$IFACE" ]] || die 'No default IPv4 route found.'
  ipaddr=$(ip -4 -o addr show dev "$IFACE" scope global 2>/dev/null | awk 'NR==1{print $4}')
  [[ "$ipaddr" == */* ]] || die "No global IPv4 address on $IFACE."
  network=$(ip -4 route show dev "$IFACE" proto kernel scope link 2>/dev/null | awk -v host="${ipaddr%/*}" '$1 ~ /\// {for(i=1;i<=NF;i++) if($i=="src" && $(i+1)==host){print $1; exit}}')
  [[ -n "$network" ]] || die 'Unable to determine the connected prefix safely; refusing to assume /24.'
  SUBNET="$network"
  info "Interface: $IFACE | Subnet: $SUBNET | Gateway: $GATEWAY"
}

vendor(){ case "${1^^}" in
  00:1A:2B*|00:50:56*|00:0C:29*|00:05:69*) echo VMware;; 00:1C:42*) echo Parallels;;
  00:03:93*|A4:4C:C8*|00:26:9E*|00:0D:93*|3C:07:54*|A8:86:DD*) echo Apple;;
  00:1E:58*|00:1F:3A*|00:21:5C*|14:18:77*) echo Dell;; 00:1A:A0*|00:1E:4C*|00:24:E8*|30:8D:99*) echo HP;;
  00:25:90*|00:1B:21*|00:1D:09*|8C:EC:4B*) echo Intel;; 00:16:E9*|00:18:7D*|00:1F:33*|F8:7B:20*) echo Cisco;;
  20:CF:30*|2C:B0:5D*|64:B4:73*) echo Xiaomi;; 00:1F:82*|D4:61:9D*|00:E0:FC*) echo Huawei;;
  A4:77:33*|AC:CF:85*|40:B0:34*|B4:79:A7*) echo Samsung;; AC:22:0B*|B8:5A:73*|F0:F6:1C*|04:D9:F5*) echo Asus;;
  18:B4:30*|FC:D7:33*|48:45:20*|54:AF:97*) echo TP-Link;; 00:26:B6*|00:27:0E*|9C:5C:8E*|20:4E:7F*) echo Netgear;;
  B8:27:EB*|DC:A6:32*|E4:5F:01*) echo Raspberry-Pi;; 00:15:5D*) echo Hyper-V;; *) echo Unknown;; esac; }

resolve_target(){
  local target="$1" ip mac
  is_valid_mac "$target" || is_valid_ipv4 "$target" || die 'Target must be a valid IPv4 address or MAC address.'
  if is_valid_mac "$target"; then
    mac=$(normalize_mac "$target")
    ip=$(ip neigh show dev "$IFACE" 2>/dev/null | awk -v m="$mac" 'toupper($5)==m{print $1; exit}')
  else
    ip="$target"
    mac=$(ip neigh show dev "$IFACE" "$ip" 2>/dev/null | awk 'NR==1 && $5 ~ /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/{print toupper($5); exit}')
  fi
  [[ -n "$ip" ]] || die 'Target is not present in the current neighbor table.'
  printf '%s|%s\n' "$ip" "${mac:---}"
}

scan(){
  local format="${1:-table}" line ip mac host v blocked throttled count=0 first=true
  [[ "$format" == table || "$format" == json || "$format" == csv || "$format" == raw ]] || die 'Format must be table, json, csv, or raw.'
  [[ -n "$SUBNET" ]] || detect_network
  check_deps scan
  TMP_FILE=$(mktemp "${TMPDIR:-/tmp}/netwatch.XXXXXX") || die 'Unable to create temporary file.'
  nmap -sn "$SUBNET" --max-retries 2 --host-timeout 8s -oG - >"$TMP_FILE" 2>/dev/null || die 'nmap scan failed.'
  case "$format" in json) echo '[';; csv) echo 'ip,mac,hostname,vendor,blocked,throttled';; esac
  while IFS= read -r line; do
    [[ "$line" =~ ^Host:\ ([^[:space:]]+).*Status:\ Up ]] || continue
    ip="${BASH_REMATCH[1]}"
    [[ "$ip" == "$GATEWAY" ]] && continue
    mac=$(ip neigh show "$ip" 2>/dev/null | awk 'NR==1 && $5 ~ /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/{print toupper($5); exit}')
    [[ -n "$mac" ]] || mac=--
    host=$(getent hosts "$ip" 2>/dev/null | awk 'NR==1{print $2}') || true
    [[ -n "$host" ]] || host=-
    v=-; [[ "$mac" != -- ]] && v=$(vendor "$mac")
    blocked=-; [[ "$mac" != -- && -f "$BLOCK_FILE" ]] && grep -Fqi -x -- "$mac" "$BLOCK_FILE" 2>/dev/null && blocked=BLOCKED
    throttled=-; [[ "$mac" != -- && -f "$THROTTLE_FILE" ]] && throttled=$(awk -F'|' -v m="$mac" 'toupper($1)==m{print $2; exit}' "$THROTTLE_FILE"); [[ -n "$throttled" ]] || throttled=-
    ((count++))
    case "$format" in
      json) $first || echo ','; first=false; printf '  {"ip":"%s","mac":"%s","hostname":"%s","vendor":"%s","blocked":"%s","throttled":"%s"}' "$(json_escape "$ip")" "$(json_escape "$mac")" "$(json_escape "$host")" "$(json_escape "$v")" "$(json_escape "$blocked")" "$(json_escape "$throttled")";;
      csv) printf '%s,%s,%s,%s,%s,%s\n' "$(csv_escape "$ip")" "$(csv_escape "$mac")" "$(csv_escape "$host")" "$(csv_escape "$v")" "$(csv_escape "$blocked")" "$(csv_escape "$throttled")";;
      raw) printf '%s|%s|%s|%s|%s|%s\n' "$ip" "$mac" "$host" "$v" "$blocked" "$throttled";;
      table) printf '%-16s %-18s %-22s %-12s %-10s %-10s\n' "$ip" "$mac" "${host:0:22}" "${v:0:12}" "$blocked" "$throttled";;
    esac
  done <"$TMP_FILE"
  [[ "$format" == json ]] && printf '\n]\n'; [[ "$format" == table ]] && ok "$count device(s) found."
  log "scan: $count devices on $SUBNET"
  rm -f -- "$TMP_FILE"; TMP_FILE=""
}

block(){
  require_root; check_deps block; [[ -n "$IFACE" ]] || detect_network; local pair ip mac
  pair=$(resolve_target "$1"); IFS='|' read -r ip mac <<<"$pair"
  [[ "$ip" != "$GATEWAY" ]] || die 'Refusing to block the default gateway.'
  [[ "$(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null)" == 1 ]] || die 'This host is not an IPv4 gateway/router. No ARP spoofing is performed.'
  $DRY_RUN && { warn "[DRY-RUN] Would add NETWATCH_BLOCK rules for $ip${mac:+ / $mac}."; return 0; }
  mkdir -p "$CONFIG_DIR" || die 'Cannot create config directory.'
  iptables -N NETWATCH_BLOCK 2>/dev/null || true
  iptables -C FORWARD -j NETWATCH_BLOCK 2>/dev/null || iptables -I FORWARD 1 -j NETWATCH_BLOCK || die 'Failed to attach Netwatch firewall chain.'
  iptables -C NETWATCH_BLOCK -s "$ip" -j DROP 2>/dev/null || iptables -A NETWATCH_BLOCK -s "$ip" -j DROP || die 'Failed to add source block.'
  iptables -C NETWATCH_BLOCK -d "$ip" -j DROP 2>/dev/null || iptables -A NETWATCH_BLOCK -d "$ip" -j DROP || die 'Failed to add destination block.'
  [[ "$mac" == -- ]] || iptables -C NETWATCH_BLOCK -m mac --mac-source "$mac" -j DROP 2>/dev/null || iptables -A NETWATCH_BLOCK -m mac --mac-source "$mac" -j DROP || die 'Failed to add MAC block.'
  grep -Fqi -x -- "$ip" "$BLOCK_IP_FILE" 2>/dev/null || printf '%s\n' "$ip" >>"$BLOCK_IP_FILE"
  [[ "$mac" == -- ]] || { grep -Fqi -x -- "$mac" "$BLOCK_FILE" 2>/dev/null || printf '%s\n' "$mac" >>"$BLOCK_FILE"; }
  log "block: $ip ($mac)"; ok "Blocked $ip via Netwatch-owned firewall rules."
}

unblock(){
  require_root; check_deps unblock; [[ -n "$IFACE" ]] || detect_network; local pair ip mac
  pair=$(resolve_target "$1"); IFS='|' read -r ip mac <<<"$pair"
  $DRY_RUN && { warn "[DRY-RUN] Would remove NETWATCH_BLOCK rules for $ip${mac:+ / $mac}."; return 0; }
  iptables -D NETWATCH_BLOCK -s "$ip" -j DROP 2>/dev/null || true
  iptables -D NETWATCH_BLOCK -d "$ip" -j DROP 2>/dev/null || true
  [[ "$mac" == -- ]] || iptables -D NETWATCH_BLOCK -m mac --mac-source "$mac" -j DROP 2>/dev/null || true
  [[ -f "$BLOCK_FILE" ]] && sed -i -F -x "/${mac}/d" "$BLOCK_FILE" 2>/dev/null || true
  [[ -f "$BLOCK_IP_FILE" ]] && sed -i -F -x "/${ip}/d" "$BLOCK_IP_FILE" 2>/dev/null || true
  log "unblock: $ip ($mac)"; ok "Unblocked $ip."
}

throttle(){
  require_root; check_deps throttle; [[ -n "$IFACE" ]] || detect_network
  local mac="$1" speed="$2"
  is_valid_mac "$mac" || die "Invalid MAC: '$mac'"
  is_valid_speed "$speed" || die "Invalid speed '$speed'. Examples: 512kbit, 1mbit"
  [[ "$GATEWAY" != "" ]] || detect_network
  ip -4 route show dev "$IFACE" proto kernel scope link | grep -qw 'htb' >/dev/null 2>&1 && :
  $DRY_RUN && { warn "[DRY-RUN] Would configure Netwatch-owned HTB throttle for $mac at $speed on $IFACE."; return 0; }
  local mark
  mark=$((16#${mac//:/} % 60000 + 100))
  if ! tc qdisc show dev "$IFACE" 2>/dev/null | grep -q 'htb'; then
    die "Refusing to replace the existing root qdisc. Configure a compatible HTB root qdisc first."
  fi
  iptables -t mangle -C PREROUTING -m mac --mac-source "${mac^^}" -j MARK --set-mark "$mark" 2>/dev/null || iptables -t mangle -A PREROUTING -m mac --mac-source "${mac^^}" -j MARK --set-mark "$mark" || die 'Failed to add traffic mark.'
  tc class add dev "$IFACE" parent 1: classid "1:$mark" htb rate "$speed" ceil "$speed" 2>/dev/null || die 'Failed to add HTB class.'
  tc filter add dev "$IFACE" parent 1: protocol ip prio "$mark" handle "$mark" fw classid "1:$mark" 2>/dev/null || die 'Failed to add HTB filter.'
  mkdir -p "$CONFIG_DIR" || die 'Cannot create config directory.'
  grep -Fqi -x -- "$mac" "$THROTTLE_FILE" 2>/dev/null && sed -i -F -x "/${mac}.*/d" "$THROTTLE_FILE" 2>/dev/null || true
  printf '%s|%s|%s\n' "${mac^^}" "$speed" "$mark" >>"$THROTTLE_FILE"
  log "throttle: ${mac^^} -> $speed"; ok "Throttled ${mac^^} to $speed."
}

unthrottle(){
  require_root; check_deps unthrottle; [[ -n "$IFACE" ]] || detect_network
  local mac="${1^^}" entry mark
  is_valid_mac "$mac" || die "Invalid MAC: '$1'"
  entry=$(grep -F -i -m1 "^${mac}|" "$THROTTLE_FILE" 2>/dev/null || true)
  mark=$(awk -F'|' 'NF>=3{print $3; exit}' <<<"$entry")
  $DRY_RUN && { warn "[DRY-RUN] Would remove Netwatch-owned throttle for $mac."; return 0; }
  [[ -z "$mark" ]] || tc filter del dev "$IFACE" parent 1: protocol ip prio "$mark" 2>/dev/null || true
  [[ -z "$mark" ]] || tc class del dev "$IFACE" parent 1: classid "1:$mark" 2>/dev/null || true
  iptables -t mangle -D PREROUTING -m mac --mac-source "$mac" -j MARK --set-mark "$mark" 2>/dev/null || true
  [[ -f "$THROTTLE_FILE" ]] && awk -F'|' -v m="$mac" 'toupper($1)!=m' "$THROTTLE_FILE" >"${THROTTLE_FILE}.tmp" && mv -- "${THROTTLE_FILE}.tmp" "$THROTTLE_FILE"
  log "unthrottle: $mac"; ok "Unthrottled $mac."
}

list(){
  echo -e "\n${BOLD}${RED}Blocked MACs:${NC}"
  [[ -f "$BLOCK_FILE" && -s "$BLOCK_FILE" ]] && cat -n "$BLOCK_FILE" || echo '  (none)'
  echo -e "\n${BOLD}${YELLOW}Throttled MACs:${NC}"
  [[ -f "$THROTTLE_FILE" && -s "$THROTTLE_FILE" ]] || { echo '  (none)'; echo; return 0; }
  printf '  %-3s %-20s %-10s\n' '#' 'MAC' 'Speed'
  local i=1 mac speed _
  while IFS='|' read -r mac speed _; do printf '  %-3s %-20s %-10s\n' "$i" "$mac" "$speed"; ((i++)); done <"$THROTTLE_FILE"
  echo
}

export_scan(){
  local fmt="${1:-csv}"
  [[ "$fmt" == csv || "$fmt" == json ]] || die 'Export format must be csv or json.'
  mkdir -p "$CONFIG_DIR" || die 'Cannot create config directory.'
  detect_network
  local outfile="$CONFIG_DIR/export_$(date '+%Y%m%d_%H%M%S').$fmt"
  info "Exporting scan as $fmt -> $outfile"
  scan "$fmt" >"$outfile" || { rm -f -- "$outfile"; die 'Export failed.'; }
  ok "Saved to $outfile"
}

identify(){
  local target="$1" pair ip mac rdns oui_vendor nmap_out ports os_guess
  [[ -n "$target" ]] || die "Usage: $SCRIPT_NAME identify <ip|mac>"
  detect_network
  pair=$(resolve_target "$target"); IFS='|' read -r ip mac <<<"$pair"
  echo -e "\n${BOLD}${CYAN}Device Profile: $ip${NC}"
  echo "  MAC Address: $mac"
  rdns=$(getent hosts "$ip" 2>/dev/null | awk 'NR==1{print $2}') || true
  echo "  rDNS       : ${rdns:-(none)}"
  oui_vendor='Unknown'
  [[ "$mac" != -- ]] && oui_vendor=$(vendor "$mac")
  echo "  Vendor     : $oui_vendor"
  if command_exists dig && [[ -n "$ip" ]]; then
    rdns=$(dig +short +time=2 -x "$ip" 2>/dev/null | head -1 | sed 's/\.$//')
    [[ -n "$rdns" ]] && echo "  rDNS       : $rdns"
  fi
  nmap_out=$(nmap -sV -O --osscan-guess --max-retries 1 --host-timeout 30s -T4 "$ip" 2>/dev/null) || true
  ports=$(printf '%s\n' "$nmap_out" | awk '/^[0-9]+\/tcp/{print "  " $0}')
  echo -e "\nOpen TCP ports:"
  [[ -n "$ports" ]] && printf '%s\n' "$ports" || echo '  (none detected)'
  os_guess=$(printf '%s\n' "$nmap_out" | grep -E '^(Running:|OS details:)' | head -3)
  echo -e "\nOS hint:"
  [[ -n "$os_guess" ]] && printf '  %s\n' "$os_guess" || echo '  (insufficient data)'
  log "identify: $ip ($mac)"
}

reset(){
  require_root; check_deps reset
  $DRY_RUN && { warn '[DRY-RUN] Would remove only Netwatch-owned firewall/QoS state.'; return 0; }
  if command_exists iptables; then
    while iptables -C FORWARD -j NETWATCH_BLOCK 2>/dev/null; do iptables -D FORWARD -j NETWATCH_BLOCK || break; done
    if iptables -nL NETWATCH_BLOCK >/dev/null 2>&1; then iptables -F NETWATCH_BLOCK; iptables -X NETWATCH_BLOCK; fi
    iptables -t mangle -F NETWATCH_QOS 2>/dev/null || true
    iptables -t mangle -X NETWATCH_QOS 2>/dev/null || true
  fi
  if command_exists tc && [[ -n "$IFACE" ]]; then
    while read -r _ mark _; do [[ "$mark" =~ ^[0-9]+$ ]] || continue; tc filter del dev "$IFACE" parent 1: handle "$mark" fw 2>/dev/null || true; tc class del dev "$IFACE" parent 1: classid "1:$mark" 2>/dev/null || true; done < <(awk -F'|' 'NF>=3{print $1,$3}' "$THROTTLE_FILE" 2>/dev/null || true)
  fi
  rm -f -- "$BLOCK_FILE" "$BLOCK_IP_FILE" "$THROTTLE_FILE"
  log 'reset: Netwatch-owned state cleared'
  ok 'Netwatch-owned rules and state cleared; unrelated firewall/QoS configuration preserved.'
}

menu(){
  check_deps menu
  detect_network
  local choice interval fmt
  while true; do
    clear
    echo -e "${BOLD}${CYAN}NETWATCH — Linux${NC}"
    echo "Interface: $IFACE | Subnet: $SUBNET | Gateway: $GATEWAY"
    echo
    echo '[1] Scan  [2] Identify  [3] Block  [4] Unblock'
    echo '[5] Throttle  [6] Unthrottle  [7] List'
    echo '[8] Monitor  [9] Export  [R] Reset  [U] Update  [Q] Quit'
    echo
    read -r -p 'Choice: ' choice || exit 0
    case "${choice,,}" in
      1) scan table; read -r -p 'Press Enter...' _ ;;
      2) read -r -p 'Target IP/MAC: ' target; identify "$target"; read -r -p 'Press Enter...' _ ;;
      3) read -r -p 'Target IP/MAC: ' target; block "$target"; read -r -p 'Press Enter...' _ ;;
      4) read -r -p 'Target IP/MAC: ' target; unblock "$target"; read -r -p 'Press Enter...' _ ;;
      5) read -r -p 'MAC: ' target; read -r -p 'Speed: ' speed; throttle "$target" "$speed"; read -r -p 'Press Enter...' _ ;;
      6) read -r -p 'MAC: ' target; unthrottle "$target"; read -r -p 'Press Enter...' _ ;;
      7) list; read -r -p 'Press Enter...' _ ;;
      8) read -r -p 'Interval [30]: ' interval; [[ -n "$interval" ]] || interval=30; [[ "$interval" =~ ^[1-9][0-9]*$ && "$interval" -le 3600 ]] || { warn 'Interval must be between 1 and 3600 seconds.'; sleep 1; continue; }; while true; do clear; scan table; sleep "$interval"; done ;;
      9) read -r -p 'Format [csv/json]: ' fmt; [[ -n "$fmt" ]] || fmt=csv; export_scan "$fmt"; read -r -p 'Press Enter...' _ ;;
      r) reset; read -r -p 'Press Enter...' _ ;;
      u) check_update; read -r -p 'Press Enter...' _ ;;
      q) exit 0 ;;
      *) warn 'Unknown option.'; sleep 1 ;;
    esac
  done
}

args=()
for arg in "$@"; do
  case "$arg" in
    --dry-run) DRY_RUN=true ;;
    --persistent) PERSISTENT=true ;;
    *) args+=("$arg") ;;
  esac
done
set -- "${args[@]+"${args[@]}"}"
CMD="${1:-menu}"
shift || true

case "$CMD" in
  menu) menu ;;
  scan) check_deps scan; detect_network; scan "${1:-table}" ;;
  monitor) check_deps monitor; detect_network; interval="${1:-30}"; [[ "$interval" =~ ^[1-9][0-9]*$ && "$interval" -le 3600 ]] || die 'Interval must be between 1 and 3600 seconds.'; while true; do scan table; sleep "$interval"; done ;;
  block) check_deps block; detect_network; block "$1" ;;
  unblock) check_deps unblock; detect_network; unblock "$1" ;;
  throttle) check_deps throttle; detect_network; throttle "$1" "$2" ;;
  unthrottle) check_deps unthrottle; detect_network; unthrottle "$1" ;;
  list) list ;;
  identify|info|probe) check_deps identify; identify "$1" ;;
  export) check_deps export; export_scan "${1:-csv}" ;;
  reset) check_deps reset; detect_network; reset ;;
  update) check_update || true ;;
  help|-h|--help)
    cat <<EOF
netwatch — Linux network monitor & gateway control

Usage: $SCRIPT_NAME [--dry-run] [--persistent] <command> [args]

Commands:
  menu
  scan [table|json|csv]
  monitor [1..3600]
  identify <ip|mac>
  block <ip|mac>       Gateway/router only
  unblock <ip|mac>
  throttle <mac> <speed>
  unthrottle <mac>
  list
  export [csv|json]
  reset                 Netwatch-owned rules/state only
  update                Read-only update check
  help

Flags:
  --dry-run
  --persistent         Compatibility flag; no system-wide persistence file is overwritten.
EOF
    ;;
  *) die "Unknown command: $CMD. Run '$SCRIPT_NAME help'." ;;
esac
