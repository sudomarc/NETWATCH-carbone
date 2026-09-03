# NETWATCH Domain Monitoring

`netwatch-domains.sh` is a Linux-only, passive DNS visibility helper for NETWATCH.

## What it does

It listens for conventional DNS traffic visible on a selected Linux interface and records the source address and queried domain. It is intended for networks the operator owns or is authorized to administer.

It does **not** decrypt HTTPS traffic, reconstruct exact URLs, or bypass encrypted DNS such as DNS-over-HTTPS or DNS-over-TLS. Domain coverage therefore depends on what DNS traffic is observable on the interface.

## Usage

```bash
sudo ./netwatch-domains.sh
sudo ./netwatch-domains.sh --interface eth0
sudo ./netwatch-domains.sh --interval 5
sudo ./netwatch-domains.sh --json
```

The interface defaults to the Linux route used for `1.1.1.1`.

## Requirements

- Bash
- `tcpdump`
- `ip` from iproute2
- root privileges for packet capture in normal configurations

## Scope

This helper intentionally remains separate from the core scanner. The core NETWATCH commands remain responsible for discovery, identification, control, and export; domain monitoring is observational only.
