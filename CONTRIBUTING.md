# Contributing to netwatch

Thanks for your interest! Here's how to contribute.

## Getting Started

1. Fork the repo
2. Create a feature branch: `git checkout -b feature/my-feature`
3. Make your changes
4. Test on a real Linux machine (ideally a gateway/router)
5. Submit a pull request with a clear description

## Guidelines

- Keep it Bash — no Python/Go rewrites please; the goal is a zero-install single-file script
- Test with `--dry-run` before submitting changes to block/throttle/reset logic
- Document any new commands in both the `help` case and `README.md`
- Keep the single-file structure; don't split into multiple scripts

## Ideas for contribution

- Extend the vendor OUI table with more prefixes
- Add IPv6 support
- Improve OS fingerprinting hints in `identify`
- Add a `watch` mode that alerts on new/unknown devices
- Shell completion scripts (bash/zsh)

## Ethical use reminder

All contributions must be scoped to legitimate network administration use cases on networks the user owns or controls. PRs that add features designed to attack or disrupt networks without authorization will not be accepted.
