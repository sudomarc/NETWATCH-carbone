# netwatch 🔍

A Bash-based network monitoring and management tool for Linux. Designed for home lab admins, sysadmins, and anyone who wants visibility and control over their own local network.

> **⚠️ Legal Notice:** This tool is intended for use **only on networks you own or have explicit permission to manage**. Unauthorized use on networks you don't control is illegal under computer fraud and network interference laws in most jurisdictions.

---

## Features

- **Network scanner** — Discover all active devices on your subnet with IP, MAC, hostname, and vendor info
- **Device identification** — Deep-fingerprint a device: open ports, OS guess, mDNS services, NetBIOS name
- **Bandwidth throttling** — Limit a device's bandwidth using Linux Traffic Control (`tc` + `htb`)
- **Device blocking** — Block a device from the network via `iptables` (router/gateway mode only)
- **Monitor mode** — Auto-refreshing live view of your network
- **Export** — Save scan results as CSV or JSON
- **Interactive menu** — Full TUI with no flags required; just run `sudo netwatch`
- **Dry-run mode** — Preview changes before applying with `--dry-run`
- **Persistent rules** — Optionally save `iptables` rules across reboots with `--persistent`

---

## Requirements

| Dependency | Purpose |
|---|---|
| `nmap` | Network scanning |
| `iptables` | Firewall-based device blocking (router mode) |
| `ip` / `iproute2` | Interface and ARP table management |
| `tc` (iproute2) | Bandwidth throttling |
| `awk` | Text processing |

Optional:
- `avahi-utils` — mDNS/Bonjour service discovery in `identify`
- `samba-common-bin` — NetBIOS name lookup in `identify`
- `ipcalc` — More accurate subnet detection
- `dig` — Reverse DNS in `identify`

Install on Debian/Ubuntu:
```bash
sudo apt install nmap iproute2 iptables avahi-utils samba-common-bin ipcalc dnsutils
```

---

## Installation

```bash
git clone https://github.com/YOUR_USERNAME/netwatch.git
cd netwatch
chmod +x netwatch.sh
sudo ./netwatch.sh          # launch interactive menu
```

Optionally install system-wide:
```bash
sudo cp netwatch.sh /usr/local/bin/netwatch
sudo netwatch
```

---

## Usage

```
netwatch [--dry-run] [--persistent] <command> [args]
```

### Commands

| Command | Description |
|---|---|
| `menu` | Launch interactive TUI (default) |
| `scan [table\|json\|csv]` | Scan the local subnet |
| `monitor [interval]` | Auto-refresh every N seconds (default: 30) |
| `identify <ip\|mac>` | Deep-fingerprint a device |
| `block <ip\|mac>` | Block a device (requires root + router mode) |
| `unblock <ip\|mac>` | Remove a block |
| `throttle <mac> <speed>` | Limit bandwidth (e.g. `512kbit`, `2mbit`) |
| `unthrottle <mac>` | Remove bandwidth limit |
| `list` | Show currently blocked/throttled MACs |
| `export [csv\|json]` | Export scan results to `~/.config/netwatch/` |
| `reset` | Clear all iptables rules and tc qdiscs |
| `help` | Show help |

### Flags

| Flag | Description |
|---|---|
| `--dry-run` | Preview changes without applying them |
| `--persistent` | Save iptables rules via `iptables-save` after block/unblock |

### Examples

```bash
# Interactive menu
sudo netwatch

# Scan and display devices
sudo netwatch scan

# Export scan as JSON
sudo netwatch export json

# Deep-probe a device
sudo netwatch identify 192.168.1.42

# Limit a device to 1 Mbit/s (your own router only)
sudo netwatch throttle AA:BB:CC:DD:EE:FF 1mbit

# Remove the throttle
sudo netwatch unthrottle AA:BB:CC:DD:EE:FF

# Preview a block without applying it
sudo netwatch --dry-run block 192.168.1.50

# Block and persist rule across reboots
sudo netwatch --persistent block AA:BB:CC:DD:EE:FF

# Monitor mode, refresh every 10 seconds
sudo netwatch monitor 10
```

---

## Configuration

All data is stored in `~/.config/netwatch/` (override with `NETWATCH_CONFIG` env var):

| File | Contents |
|---|---|
| `blocked_macs` | MACs currently blocked |
| `throttled_macs` | MACs with active bandwidth limits |
| `scan_history.log` | Timestamped log of all actions |
| `export_*.csv/json` | Exported scan results |

---

## How blocking and throttling work

**Blocking** uses `iptables` `FORWARD` rules and only has effect when the machine running `netwatch` is the network gateway (i.e. `net.ipv4.ip_forward=1`). It drops forwarded traffic to/from the target IP and MAC. It will not work if run from a regular LAN client that is not the router.

**Throttling** uses Linux Traffic Control (`tc`) with an HTB qdisc. It marks packets from a target MAC using `iptables mangle` and shapes them to the specified rate. This also requires running on the gateway interface.

---

## Scan output fields

| Field | Description |
|---|---|
| IP | Device IP address |
| MAC | Hardware address (from ARP cache) |
| Hostname | Reverse DNS / mDNS name |
| Vendor | OUI-based hardware vendor guess |
| Blocked | `BLOCKED` if an active rule exists |
| Throttled | Active speed limit, if any |

---

## License

MIT — see [LICENSE](LICENSE)

## Contributing

PRs welcome. See [CONTRIBUTING.md](CONTRIBUTING.md).
