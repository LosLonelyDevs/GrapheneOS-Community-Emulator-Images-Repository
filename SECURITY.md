# Security policy

GrapheneOS Community Emulator Images Repository is independent community development tooling. Its emulator images do not provide the hardware-backed security guarantees of a supported physical GrapheneOS device.

## Reporting a vulnerability

Open a private GitHub security advisory for vulnerabilities in this repository's scripts, packaging, checksum verification, or release process. Do not open a public issue containing exploit details or secrets.

For vulnerabilities in GrapheneOS itself, use the reporting process published by the GrapheneOS project: <https://grapheneos.org/contact#security>.

## Release trust model

- Releases are community-built artifacts, not official GrapheneOS releases.
- Verify the release asset with the published `SHA256SUMS.txt` before extraction.
- Check `BUILD-METADATA.txt` for the exact upstream tag, manifest revision, automation revision, build fingerprint, and validation timestamp.
- Treat the emulator as a disposable development environment. Do not store production secrets in it.
