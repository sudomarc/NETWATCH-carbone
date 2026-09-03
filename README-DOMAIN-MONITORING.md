# Domain Monitoring

NETWATCH includes an optional Linux-only domain-observation helper.

```bash
sudo ./netwatch-domains.sh
```

It observes conventional DNS queries visible on the selected interface and reports the source address and queried domain. It is intentionally passive and does not decrypt HTTPS or bypass encrypted DNS.

Required tools:

- Bash
- `tcpdump`
- `iproute2`
- root privileges for packet capture

For details, see `docs/DOMAIN-MONITORING.md`.
