# Current status and cleanup

Date: 2026-09-05

## Public project status

- Windows + WSL source-build orchestration is complete.
- QEMU-specific image packaging is complete.
- The retained proof-of-concept sysdir boots as Android 17 / `sdk_phone64_x86_64-userdebug`.
- GrapheneOS and Vanadium packages were observed on the running emulator.
- The exact boot-tested sysdir has a per-file SHA-256 manifest.
- GrapheneOS tag `2026062800` and manifest commit `ad69afb5ac59ea130ac092e778b37ae2b7158df7` are recorded and signature-verified.
- A local release ZIP, numbered parts, checksums, provenance, validation report, and join instructions have been generated and independently checked.
- The repository and release remain unpublished until the owner explicitly approves a push and upload.

Machine-specific build history, storage locations, host configuration, and cleanup measurements belong in the ignored `data/` journal—not this public document.

## External output layout

By default, generated output is kept outside the Git checkout:

```text
C:\Android\grapheneos-emulator\
  logs\
  release\
  state\
  sysdir\
```

These are generic tool defaults, not paths copied from a contributor profile. Do not add generated images, archives, logs, AVD data, source checkouts, or machine-specific state to Git.

## Safe cleanup

- Keep `sysdir\` while you need the compiled emulator image.
- Keep `release\` while you need the locally verified release assets.
- Use `build-grapheneos-emulator.ps1 -Reclaim` only when intentionally removing the WSL source/build tree.
- Stop active emulator and WSL processes before disk compaction.
- Prefer `wsl --manage <distro> --set-sparse true` where supported.
- Never use `wsl --unregister <distro>` for ordinary cleanup; it deletes the entire distribution.

The build orchestrator records enough state to restore the prior `.wslconfig`. Review that restoration state before manually deleting build logs or state markers.

## Pre-publish gate

Before asking for approval to publish:

1. Run all tests listed in `AGENTS.md`.
2. Parse every PowerShell and shell script.
3. Confirm `git status --short` contains only intended public changes.
4. Scan every tracked file for credentials, private keys, usernames, hostnames, IP addresses, and profile-specific paths.
5. Confirm images, archives, logs, AVD data, and the ignored `data/` journal are not tracked.
6. Recompute release checksums and prove the numbered parts reproduce the complete ZIP.
7. Inspect screenshots and release metadata for personal information.
8. Obtain explicit owner approval before any push, release creation, or asset upload.
