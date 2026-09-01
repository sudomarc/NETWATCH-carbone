# netwatch 🔍

A Bash-based network monitoring and management tool for Linux. Designed for home lab admins, sysadmins, and administrators who need visibility and controlled network operations on systems they own or are authorized to manage.

> **⚠️ Legal notice:** Use netwatch only on networks and systems you own or have explicit permission to administer.

## Platform

**Linux only.** Android/Termux and Windows/PowerShell are not supported by this repository.

## Features

- **Network scanner** — Discover active devices on the detected IPv4 subnet with IP, MAC, hostname, and vendor information.
- **Device identification** — Inspect a device for reverse DNS, vendor information, open TCP services, and OS hints when privileges permit.
- **Bandwidth throttling** — Limit a device's bandwidth using Linux Traffic Control (`tc` + `htb`) on a compatible gateway/router setup.
- **Device blocking** — Block a device using `iptables` in a gateway/router setup.
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

- `curl` or `wget` — update checks
- `ipcalc` — subnet detection helper
- `dig` — reverse DNS
- `avahi-utils` — optional mDNS tooling
- `samba-common-bin` — optional NetBIOS tooling

Debian/Ubuntu example:

```bash
sudo apt install bash nmap iproute2 iptables curl ipcalc dnsutils
```

## Installation

```bash
git clone https://github.com/sudomarc/NETWATCH-carbone.git
cd NETWATCH-carbone
chmod +x netwatch.sh
sudo ./netwatch.sh
```

Optional system-wide installation:

```bash
sudo cp netwatch.sh /usr/local/bin/netwatch
sudo netwatch
```

## Usage

```text
netwatch [--dry-run] [--persistent] <command> [args]
```

### Commands

| Command | Description |
|---|---|
| `menu` | Launch interactive TUI |
| `scan [table\|json\|csv]` | Scan the detected local subnet |
| `monitor [interval]` | Auto-refresh every N seconds |
| `identify <ip\|mac>` | Inspect a device |
| `block <ip\|mac>` | Block a device |
| `unblock <ip\|mac>` | Remove a block |
| `throttle <mac> <speed>` | Limit bandwidth |
| `unthrottle <mac>` | Remove a bandwidth limit |
| `list` | Show blocked/throttled state |
| `export [csv\|json]` | Export scan results |
| `reset` | Clear Netwatch control state |
| `update` | Check for a newer version |
| `help` | Show help |

### Examples

```bash
sudo netwatch scan
sudo netwatch identify 192.168.1.42
sudo netwatch export json
sudo netwatch monitor 10
sudo netwatch --dry-run block 192.168.1.50
sudo netwatch throttle AA:BB:CC:DD:EE:FF 1mbit
```

## Network model

Netwatch is a Linux network administration utility. Blocking and throttling are gateway/router functions; running the tool on an ordinary client does not make that machine the network gateway.

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
- generated `export_*.csv` / `export_*.json`

Runtime state is excluded from version control.

## Vendor information

Vendor information is based on a limited OUI mapping and should be treated as a best-effort guess, not authoritative hardware identification.

## License

MIT — see [LICENSE](LICENSE).

## Contributing

This is a Linux-only Bash project. See [CONTRIBUTING.md](CONTRIBUTING.md).
