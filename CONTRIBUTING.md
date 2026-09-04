# Contributing

Contributions to the build, validation, packaging, setup, and documentation tooling are welcome.

## Before opening a pull request

1. Keep the project visibly independent from GrapheneOS.
2. Do not add compiled images, source trees, logs, credentials, hostnames, usernames, or machine-specific paths.
3. Preserve the QEMU-specific image packaging contract.
4. Add or update tests for behavior changes.
5. Run the commands listed in `AGENTS.md`.

Full Android builds are not expected for ordinary documentation or tooling pull requests. If a change affects sysdir contents, emulator launch flags, or validation, describe the real boot evidence used.

By contributing, you agree to license your contribution under GNU GPL v3.0 to the extent you own it. Third-party material must retain compatible licensing and attribution.
