# netwatch 🔍

A Bash-based network monitoring and management tool for Linux. Designed for home lab admins, sysadmins, and administrators who need visibility and controlled network operations on systems they own or are authorized to manage.

> **⚠️ Legal notice:** Use netwatch only on networks and systems you own or have explicit permission to administer.

## Features

- **Network scanner** — Discover active devices on the detected IPv4 subnet with IP, MAC, hostname, and vendor information.
- **Device identification** — Inspect a device for reverse DNS, vendor information, open TCP services, and OS hints when privileges permit.
- **Bandwidth throttling** — Apply Linux Traffic Control (`tc`) rules where the host is an appropriate gateway/router.
- **Device blocking** — Apply Netwatch-owned `iptables` rules where the host is an IPv4 gateway/router.
- **Monitor mode** — Repeatedly scan the detected network.
- **Export** — Save scan results as CSV or JSON.
- **Interactive menu** — Run the main interface without remembering command syntax.
- **Dry-run mode** — Preview system-changing operations without applying them.

## Requirements

Required for discovery and inspection:

- `bash`
- `nmap`
- `ip` / `iproute2`
- `awk`

Required only for specific control operations:

- `iptables` — block/unblock/reset
- `tc` — throttle/unthrottle

Optional:

- `curl` or `wget` — read-only update checking
- `dig` — reverse DNS fallback
- `avahi-utils` — optional mDNS tooling outside the core scan path
- `samba-common-bin` — optional NetBIOS tooling outside the core scan path

Debian/Ubuntu example:

```bash
sudo apt install bash nmap iproute2 iptables curl dnsutils
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
| `menu` | Launch the interactive TUI |
| `scan [table\|json\|csv]` | Scan the detected connected IPv4 subnet |
| `monitor [interval]` | Re-scan repeatedly; interval is bounded for safety |
| `identify <ip\|mac>` | Inspect a device |
| `block <ip\|mac>` | Block a device from a gateway host |
| `unblock <ip\|mac>` | Remove a Netwatch-owned block |
| `throttle <mac> <speed>` | Apply a Netwatch-owned bandwidth limit |
| `unthrottle <mac>` | Remove a Netwatch-owned bandwidth limit |
| `list` | Show stored Netwatch state |
| `export [csv\|json]` | Export a scan |
| `reset` | Remove only Netwatch-owned firewall/QoS state |
| `update` | Check whether a newer version is available |
| `help` | Show help |

### Flags

| Flag | Description |
|---|---|
| `--dry-run` | Preview system-changing operations without applying them |
| `--persistent` | Compatibility flag retained for CLI compatibility; does not overwrite system-wide firewall persistence files |

### Examples

```bash
sudo netwatch scan
sudo netwatch export json
sudo netwatch identify 192.168.1.42
sudo netwatch --dry-run block 192.168.1.50
sudo netwatch throttle AA:BB:CC:DD:EE:FF 1mbit
sudo netwatch unthrottle AA:BB:CC:DD:EE:FF
sudo netwatch monitor 10
sudo netwatch update
```

## Network and control model

Netwatch uses the Linux kernel routing table to determine the active IPv4 interface, gateway, and connected prefix. It does not invent a `/24` fallback when the connected prefix cannot be determined safely.

`block` is gateway/router-only. The current implementation does not perform ARP spoofing. Blocking another LAN device from an ordinary client machine is refused.

`throttle` uses Linux `tc` and Netwatch-owned firewall marks/classes. Netwatch must not replace an unrelated root qdisc or silently claim that a failed QoS operation succeeded.

`reset` removes only Netwatch-owned state. It must not flush the machine's global `INPUT`, `FORWARD`, or `PREROUTING` chains and must not delete unrelated QoS configuration.

## Update model

The updater performs a **read-only version check**. It does not automatically download, replace, or execute a remote script.

A detected update should be reviewed and installed from a trusted Git commit or tag rather than treating an unsigned raw HTTP payload as authenticated executable code.

## Configuration and state

Default state directory:

```text
~/.config/netwatch/
```

Override it with `NETWATCH_CONFIG`.

Typical files:

| File | Purpose |
|---|---|
| `blocked_macs` | Stored blocked MAC addresses |
| `blocked_ips` | Stored blocked IPv4 addresses |
| `throttled_macs` | Stored throttle entries |
| `scan_history.log` | Timestamped activity log |
| `export_*.csv/json` | Generated scan exports |

Runtime state should not be committed to the repository.

## Vendor information

Vendor names are OUI-based guesses and are intentionally incomplete. A displayed vendor must not be interpreted as authoritative hardware identity.

## Security

Netwatch is a privileged network administration tool. Validate targets before control operations, use `--dry-run` before destructive changes, and operate only on authorized networks.

## License

MIT — see [LICENSE](LICENSE).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).
