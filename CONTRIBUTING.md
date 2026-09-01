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

## Ownership and Contributions

The original work and code authored by the project maintainer remain the maintainer's work and are not transferred to contributors by submitting a pull request.

Contributors retain authorship of their own original contributions, subject to the repository's MIT License and the rights granted by that license. By submitting a contribution, the contributor grants the project the permissions required to use, modify, distribute, and sublicense that contribution as part of the project under the applicable license.

Contributors must not claim ownership of code they did not author. Likewise, the maintainer must not claim authorship of a contributor's original work.

## Significant Contributions

If a contribution represents substantial work, a major feature, a major refactor, or a significant security/architecture change, please notify the maintainer explicitly in the pull request description.

For substantial contributions, include:

- a short description of what you built;
- the parts of the project you authored or substantially changed;
- the approximate scope of the work;
- any important design or security decisions;
- any relevant tests or benchmarks.

The maintainer may acknowledge substantial contributors in project documentation or release notes when appropriate.

## Security

Report security issues privately where possible. Never commit credentials, tokens, private keys, personal network logs, or generated runtime state.
