#!/usr/bin/env bash
# netwatch-router — vendor-neutral router integration bridge
# This helper does not assume a specific router vendor or CLI.
# It uses the administrator's SSH target and explicitly supplied command.

set -u
ROUTER_HOST="${NETWATCH_ROUTER_HOST:-}"
ROUTER_USER="${NETWATCH_ROUTER_USER:-}"
ROUTER_PORT="${NETWATCH_ROUTER_PORT:-22}"
ROUTER_KEY="${NETWATCH_ROUTER_KEY:-}"
err(){ printf '[x] %s\n' "$*" >&2; }
ok(){ printf '[✓] %s\n' "$*"; }
die(){ err "$*"; exit 1; }
usage(){ cat <<'EOF'
netwatch-router — generic SSH router integration bridge

Environment:
  NETWATCH_ROUTER_HOST   Router hostname or IP
  NETWATCH_ROUTER_USER   SSH username
  NETWATCH_ROUTER_PORT   SSH port (default: 22)
  NETWATCH_ROUTER_KEY    Optional private-key path

Usage:
  netwatch-router.sh check
  netwatch-router.sh exec <router-command> [args...]
  netwatch-router.sh apply <local-script>

The bridge intentionally does not embed vendor-specific syntax. The command
passed to `exec` is sent as separate SSH arguments, avoiding an intermediate
local shell. `apply` sends a local script to the router's stdin and executes
it with the router's configured shell.
EOF
}
require_config(){
    [[ -n "$ROUTER_HOST" ]] || die 'NETWATCH_ROUTER_HOST is not set.'
    [[ -n "$ROUTER_USER" ]] || die 'NETWATCH_ROUTER_USER is not set.'
    [[ "$ROUTER_PORT" =~ ^[0-9]+$ ]] || die 'NETWATCH_ROUTER_PORT must be numeric.'
    command -v ssh >/dev/null 2>&1 || die 'ssh is required.'
}
ssh_base=(ssh -o BatchMode=yes -o ConnectTimeout=8 -p "$ROUTER_PORT")
[[ -n "$ROUTER_KEY" ]] && ssh_base+=( -i "$ROUTER_KEY" )
check(){ require_config; "${ssh_base[@]}" "${ROUTER_USER}@${ROUTER_HOST}" 'printf router-connection-ok' >/dev/null || die 'Router SSH connection failed.'; ok 'Router SSH connection is available.'; }
exec_remote(){ require_config; [[ $# -gt 0 ]] || die 'Usage: netwatch-router.sh exec <router-command> [args...]'; "${ssh_base[@]}" "${ROUTER_USER}@${ROUTER_HOST}" "$@"; }
apply(){ require_config; local script="${1:-}"; [[ -n "$script" ]] || die 'Usage: netwatch-router.sh apply <local-script>'; [[ -f "$script" ]] || die "Script not found: $script"; "${ssh_base[@]}" "${ROUTER_USER}@${ROUTER_HOST}" 'sh -s' < "$script"; }
case "${1:-help}" in
    check) check ;;
    exec) shift; exec_remote "$@" ;;
    apply) shift; apply "${1:-}" ;;
    help|-h|--help) usage ;;
    *) die "Unknown command: $1. Run '$0 help'." ;;
esac
