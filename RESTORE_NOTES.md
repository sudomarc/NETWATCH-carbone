# Linux capability restoration

This branch restores the full Linux `netwatch.sh` implementation from the pre-stabilization Linux version.

Restored behavior includes:

- hardware vendor identification through the built-in OUI map and optional `macvendors.com` lookup;
- Nmap service/version scanning and OS fingerprinting in `identify`;
- active bandwidth throttling/unthrottling with `tc` and `iptables` marking;
- the original reset behavior;
- scan-time stale neighbor refresh;
- hostname lookup through the existing Bash subprocess path;
- gateway/router blocking with optional `arpspoof` and PID tracking.

Android/Termux and Windows/PowerShell remain removed from the repository.

Note: this restoration matches the requested Linux feature set. IPv6 network control and generic configuration of arbitrary non-Linux router hardware were not present in the verifiable pre-stabilization Git history and are therefore not claimed as restored by this branch.
