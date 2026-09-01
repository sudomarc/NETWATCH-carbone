# netwatch 🔍

A Bash-based network monitoring and management tool for Linux. Designed for home lab admins, sysadmins, and administrators who need visibility and controlled network operations on systems they own or are authorized to manage.

> **⚠️ Legal notice:** Use netwatch only on networks and systems you own or have explicit permission to administer.

## Platform

**Linux only.** Android/Termux and Windows/PowerShell are not supported by this repository.

## Features

- **Network scanner** — Discover active devices on the detected IPv4 subnet with IP, MAC, hostname, and vendor information.
- **Device identification** — Inspect reverse DNS, hardware vendor, mDNS/Bonjour services, NetBIOS/SMB name, open TCP services, service versions, and OS fingerprinting when available.
- **Bandwidth throttling** — Limit a device's bandwidth using Linux Traffic Control (`tc` + `htb`) on a compatible gateway/router setup.
- **Device blocking** — Block a device using `iptables` on a Linux IPv4 gateway/router and optionally use `arpspoof` when installed.
- **Monitor mode** — Auto-refreshing live network view.
- **Export** — Save scan results as CSV or JSON.
- **Interactive menu** — Operate netwatch without memorizing CLI syntax.
- **Dry-run mode** — Preview changes before applying them.

## Requirements

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

Debian/Ubuntu example:

```bash
sudo apt install bash nmap iproute2 iptables dsniff curl ipcalc dnsutils
```

## Installation

```bash
git clone https://github.com/sudomarc/NETWATCH-carbone.git
cd NETWATCH-carbone
chmod +x netwatch.sh
sudo ./netwatch.sh
```

## Usage

```text
netwatch [--dry-run] [--persistent] <command> [args]
```

### Commands

| Command | Description |
|---|---|
| `menu` | Launch interactive TUI |
| `scan [table|json|csv]` | Scan the detected local IPv4 subnet |
| `monitor [interval]` | Auto-refresh every N seconds |
| `identify <ip|mac>` | Deep device identification, services, and OS fingerprinting |
| `block <ip|mac>` | Block a device from a Linux IPv4 gateway/router; may use ARP spoofing |
| `unblock <ip|mac>` | Remove a block and stop associated ARP spoofing |
| `throttle <mac> <speed>` | Limit bandwidth from the Linux gateway |
| `unthrottle <mac>` | Remove a bandwidth limit |
| `list` | Show blocked/throttled state |
| `export [csv|json]` | Export scan results |
| `reset` | Clear firewall/QoS rules and local Netwatch state |
| `update` | Check for a newer version and apply the available update |
| `help` | Show help |

## Network model

Netwatch is a Linux network administration utility. Blocking and throttling are gateway/router operations. The host must be appropriately positioned in the traffic path, and IPv4 forwarding is required for gateway blocking.

The scan refreshes stale neighbor entries before MAC lookup. Device identification uses Nmap service/version detection and OS fingerprinting, with optional local discovery helpers. Vendor information is best-effort based on the built-in OUI table and optional online lookup.

## Configuration

Default configuration directory:

```text
~/.config/netwatch/
```

Override it with `NETWATCH_CONFIG`.

Typical files include:

- `blocked_macs`
- `blocked_ips`
- `throttled_macs`
- `scan_history.log`
- generated exports
- Netwatch ARP-spoof PID files

## License

MIT — see [LICENSE](LICENSE).

## Contributing

This is a Linux-only Bash project. Do not add Android, Termux, Windows, or PowerShell implementations.
