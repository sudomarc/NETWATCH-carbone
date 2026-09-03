#!/usr/bin/env bash
set -euo pipefail
iface=""
interval=10
json=0
usage(){ echo "Usage: $0 [-i IFACE] [-n SECONDS] [--json]"; }
while [[ $# -gt 0 ]]; do case "$1" in -i|--interface) iface="$2"; shift 2;; -n|--interval) interval="$2"; shift 2;; --json) json=1; shift;; -h|--help) usage; exit 0;; *) echo "Unknown option: $1" >&2; usage >&2; exit 2;; esac; done
[[ $EUID -eq 0 ]] || { echo "Run as root." >&2; exit 1; }
command -v tcpdump >/dev/null || { echo "tcpdump is required." >&2; exit 1; }
command -v ip >/dev/null || { echo "iproute2 is required." >&2; exit 1; }
if [[ -z "$iface" ]]; then iface=$(ip route get 1.1.1.1 | awk '/ dev / {for(i=1;i<=NF;i++) if($i=="dev"){print $(i+1); exit}}'); fi
[[ -n "$iface" ]] || { echo "No interface detected." >&2; exit 1; }
echo "NETWATCH — DOMAIN OBSERVER ($iface)"
echo "Observing conventional DNS on $iface; Ctrl+C to stop."
tcpdump -ni "$iface" -l 'udp port 53 or tcp port 53' 2>/dev/null | awk -v interval="$interval" -v json="$json" '
function clean(s){gsub(/[^[:alnum:].:_-]/,"",s); sub(/\.$/,"",s); return s}
function emit( k,p,sep){if(json){printf "{\"timestamp\":\"%s\",\"events\":[", strftime("%Y-%m-%dT%H:%M:%S%z"); sep=""; for(k in window){split(k,p,"|"); printf "%s{\"source\":\"%s\",\"domain\":\"%s\"}",sep,p[1],p[2]; sep=","}; print "]}"} else {print "\nLAST SEEN          SOURCE             DOMAIN"; print "---------------------------------------------------------------"; for(k in latest){split(k,p,"|"); printf "%-19s %-18s %s\n",latest[k],p[1],p[2]}}; delete window; next_emit=systime()+interval}
BEGIN{next_emit=systime()+interval}
{source=""; domain=""; for(i=1;i<=NF;i++){if(source=="" && $i ~ /^[0-9A-Fa-f:.]+\.[0-9]+$/){source=$i; sub(/\.[0-9]+$/,"",source)}; if($i ~ /^(A|AAAA|CNAME|MX|TXT|PTR)\?$/ && i<NF){domain=$(i+1); break}}; domain=clean(domain); if(source!="" && domain!=""){k=source "|" domain; latest[k]=strftime("%Y-%m-%d %H:%M:%S"); window[k]=1}; if(systime()>=next_emit) emit()}
END{if(length(window)||length(latest)) emit()}'
