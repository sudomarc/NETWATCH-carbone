# Contributing to netwatch

Thanks for contributing to netwatch.

## Scope

netwatch is a Linux-only Bash project. Keep the repository focused on `netwatch.sh` and Linux tooling.

## Getting Started

1. Fork the repository.
2. Create a feature branch: `git checkout -b feature/my-feature`.
3. Make your changes.
4. Run `bash -n netwatch.sh` and relevant functional tests.
5. Run ShellCheck when available.
6. Submit a pull request with a clear description of the change and validation performed.

## Guidelines

- Keep it Bash; do not rewrite the project in another language.
- Preserve the single-file Linux implementation unless a structural change is technically justified.
- Test `--dry-run` before changes involving block, throttle, or reset.
- Document new commands in both `help` and `README.md`.
- Do not add Android, Termux, Windows, or PowerShell implementations.
- Do not add features designed to attack or disrupt networks without authorization.

## Security

Report security issues privately where possible. Never commit credentials, tokens, private keys, personal network logs, or generated runtime state.
