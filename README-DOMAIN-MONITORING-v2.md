# Domain Monitoring

NETWATCH includes an optional Linux-only domain-observation helper.

```bash
sudo ./netwatch-domains.sh
```

It observes conventional DNS queries visible on the selected interface and reports the source address and queried domain. It is passive and does not decrypt HTTPS, reconstruct exact URLs, or bypass encrypted DNS.

Required: Bash, `tcpdump`, `iproute2`, and root privileges for packet capture in normal configurations.

See `docs/DOMAIN-MONITORING.md` for details.
