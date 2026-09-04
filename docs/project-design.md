# Project design and naming

## Recommended identity

- Project name: **GrapheneOS Community Emulator Images Repository**
- GitHub repository: `LosLonelyDevs/GrapheneOS-Community-Emulator-Images-Repository`
- Short description: **Community-built GrapheneOS SDK emulator images.**
- Short description: `Community-built GrapheneOS SDK emulator images.`
- Release prefix: `grapheneos-community-emulator-sdk_phone64_x86_64`

The name is intentionally literal and searchable. Every public surface must pair it with a prominent `Unofficial / community-built / not endorsed` label so it cannot reasonably be mistaken for an official GrapheneOS repository.

## Why this shape

Research found no established community repository dedicated to distributing GrapheneOS SDK emulator prebuilts. The closest useful comparisons were:

- [android-lineage-emulator](https://github.com/SamuraiArtem/android-lineage-emulator): separate Windows/Linux assets, direct prerequisites, screenshots, and short run instructions.
- [Android Emulator Container Scripts](https://github.com/google/android-emulator-container-scripts): explicit host requirements, one-command quick starts, troubleshooting, and a clean separation between image acquisition and runtime tooling.
- [SecurePatchedEmulator](https://github.com/cxxsheng/SecurePatchedEmulator): exact AOSP source/build provenance for security-patched emulator images.
- [robotnix](https://github.com/nix-community/robotnix): reproducibility, clear project status, and prominent warnings about development or test-key builds.
- [rootAVD](https://github.com/newbit1/rootAVD): memorable utility naming and task-oriented documentation.

The resulting design keeps the expensive build pipeline separate from the small cross-platform consumer experience.

## Repository layers

1. `scripts/`: Windows/WSL source sync, build, validation, and release packaging.
2. `install/`: small Windows, Linux, and macOS setup/launch scripts shipped inside every release.
3. `tests/`: pure unit and contract tests; no full Android build required.
4. `docs/`: provenance, publishing, cleanup, troubleshooting, and design rationale.
5. GitHub Releases: compiled sysdir parts, checksums, and join instructions. Compiled images never enter Git history.

## Release channels

- `poc-*`: manually validated proof-of-concept builds. May use an older upstream tag, which must be obvious in the release title and metadata.
- `vYYYYMMDD.N`: maintained builds from a current stable upstream tag.

Every release must identify the upstream tag and manifest commit independently from the repository release version.

## Required release assets

- `...zip.part1`, `...zip.part2`, and any additional numbered parts.
- `...-SHA256SUMS.txt` covering the complete ZIP and every part.
- `...-JOIN-INSTRUCTIONS.txt` with Windows and Unix commands.
- A release body containing platform support, validation results, provenance, and the development-only warning.

The ZIP contains `sysdir/`, platform setup/launch scripts, `README.txt`, `BUILD-METADATA.txt`, and a per-file sysdir SHA-256 manifest.

## Platform support policy

- Windows x86-64: supported and validated first.
- Linux x86-64: setup and launcher supplied; mark experimental until exercised on a real Linux host.
- macOS Intel: setup and launcher supplied; mark experimental until exercised on a real Intel Mac.
- macOS Apple silicon and Windows/Linux ARM64: unsupported by this x86-64 guest artifact. Fail early instead of silently using slow or incompatible emulation.

## Trademark boundary

The GrapheneOS name and logo are GrapheneOS project trademarks. This project uses a distinct name and no GrapheneOS logo. Documentation must always state that artifacts are community-built, unofficial, unendorsed, and intended only for local development. See the official [GrapheneOS trademark guidance](https://grapheneos.org/faq#trademark).
