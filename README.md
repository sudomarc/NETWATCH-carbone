# netwatch 🔍

A Bash-based network monitoring and management toolkit for Linux. Designed for home lab admins, sysadmins, and administrators who need visibility and controlled network operations on systems they own or are authorized to manage.

> **⚠️ Legal notice:** Use netwatch only on networks and systems you own or have explicit permission to administer.

## Platform

**Linux only.** Android/Termux and Windows/PowerShell are not supported by this repository.

## Features

- **Network scanner** — Discover active devices on the detected local IPv4 subnet with IP, MAC, hostname, and vendor information.
- **Device identification** — Inspect a device for reverse DNS, vendor information, open TCP services, and OS hints when privileges permit.
- **IPv6 discovery and control** — Discover on-link IPv6 neighbors, identify IPv6 hosts with Nmap, and block IPv6 traffic from an authorized Linux gateway/router with `ip6tables`.
- **Bandwidth throttling** — Limit a device's bandwidth using Linux Traffic Control (`tc` + `htb`) on a compatible gateway/router setup.
- **Device blocking** — Block a device using `iptables` in a gateway/router setup. When `arpspoof` is installed, the Linux gateway block path also uses ARP spoofing against the target and gateway.
- **Router integration bridge** — Connect to vendor-specific routers over SSH and run administrator-supplied router commands or scripts without embedding a fake universal router CLI into netwatch.
- **Monitor mode** — Auto-refreshing live network view.
- **Export** — Save scan results as CSV or JSON.
- **Interactive menu** — Operate netwatch without memorizing CLI syntax.
- **Dry-run mode** — Preview supported changes before applying them.

## Requirements

### Core netwatch

Required:

- Bash
- `nmap`
- `ip` / `iproute2`
- `iptables`
- `tc` / `iproute2`
- `awk`

Optional:

- `arpspoof` (`dsniff`) — ARP-based gateway blocking assistance
- `curl` or `wget` — update checks
- `ipcalc` — subnet detection helper
- `dig` — reverse DNS
- `avahi-utils` — optional mDNS tooling
- `samba-common-bin` — optional NetBIOS tooling

### IPv6 helper

`netwatch-ipv6.sh` additionally uses:

- `python3` — strict IPv6 address validation
- `ip6tables` — IPv6 gateway blocking
- `ping` — on-link all-nodes discovery when available
- `nmap` — IPv6 identification

### Router bridge

`netwatch-router.sh` uses:

- OpenSSH client (`ssh`)

Debian/Ubuntu example:

```bash
sudo apt install bash nmap iproute2 iptables dsniff curl ipcalc dnsutils python3 openssh-client
```

## Installation

```bash
git clone https://github.com/sudomarc/NETWATCH-carbone.git
cd NETWATCH-carbone
chmod +x netwatch.sh netwatch-ipv6.sh netwatch-router.sh
sudo ./netwatch.sh
```

## Usage

### Core IPv4 tool

```text
netwatch [--dry-run] [--persistent] <command> [args]
```

### IPv6 helper

```bash
sudo ./netwatch-ipv6.sh scan
sudo ./netwatch-ipv6.sh scan json
sudo ./netwatch-ipv6.sh identify 2001:db8::10
sudo ./netwatch-ipv6.sh --dry-run block 2001:db8::10
sudo ./netwatch-ipv6.sh block 2001:db8::10
sudo ./netwatch-ipv6.sh unblock 2001:db8::10
```

IPv6 scanning is based on the active Linux IPv6 interface and its neighbor table; it does not attempt to brute-force an entire `/64` address space.

### Router integration bridge

The router bridge is intentionally vendor-neutral. Router vendors expose incompatible CLIs/APIs, so netwatch does not pretend that one command syntax can safely configure every router.

Configure the SSH target with environment variables:

```bash
export NETWATCH_ROUTER_HOST=192.168.1.1
export NETWATCH_ROUTER_USER=admin
export NETWATCH_ROUTER_PORT=22
export NETWATCH_ROUTER_KEY="$HOME/.ssh/router_ed25519"
```

Check connectivity:

```bash
./netwatch-router.sh check
```

Execute an administrator-supplied router command:

```bash
./netwatch-router.sh exec show ipv6 interface
```

Apply a local router configuration script:

```bash
./netwatch-router.sh apply ./router-config.sh
```

The bridge does not select or invent vendor-specific commands. The supplied command/script is the administrator's responsibility for the target router.

## Commands

| Command | Description |
|---|---|
| `menu` | Launch interactive TUI |
| `scan [table\|json\|csv]` | Scan the detected local IPv4 subnet |
| `monitor [interval]` | Auto-refresh every N seconds |
| `identify <ip\|mac>` | Inspect a device |
| `block <ip\|mac>` | Block a device from the Linux gateway |
| `unblock <ip\|mac>` | Remove a block and stop associated ARP spoofing |
| `throttle <mac> <speed>` | Limit bandwidth from the Linux gateway |
| `unthrottle <mac>` | Remove a bandwidth limit |
| `list` | Show blocked/throttled state |
| `export [csv\|json]` | Export scan results |
| `reset` | Clear Netwatch control state |
| `update` | Check for a newer version |
| `help` | Show help |

## Network model

Netwatch is a Linux network administration utility. IPv4 blocking and throttling are gateway/router functions; running the tool on an ordinary client does not make that machine the network gateway.

The IPv4 scan refreshes stale neighbor entries before reading MAC addresses. The IPv4 blocking path is restricted to a Linux gateway/router and may use `arpspoof` when that tool is installed. `unblock` stops the Netwatch-tracked ARP spoofing processes and restores the gateway's ARP announcement when possible.

IPv6 control is provided by `netwatch-ipv6.sh` and is also gateway/router-only. It uses `ip6tables` and Linux IPv6 forwarding and refuses to block the configured default IPv6 gateway.

Do not use network-control commands on networks or devices you are not authorized to administer.

## Configuration

Default configuration directory:

```text
~/.config/netwatch/
```

Override it with `NETWATCH_CONFIG`.

Typical files include:

- `blocked_macs`
- `throttled_macs`
- `scan_history.log`
- `blocked_ipv6`
- generated `export_*.csv` / `export_*.json`
- ARP-spoof PID files for active gateway blocks

Runtime state is excluded from version control.

## Vendor information

Vendor information is based on a limited OUI mapping and optional `macvendors.com` lookup. It should be treated as best-effort identification, not authoritative hardware identification.

## License

MIT — see [LICENSE](LICENSE).

## Contributing

This is a Linux-only Bash project. See [CONTRIBUTING.md](CONTRIBUTING.md).
