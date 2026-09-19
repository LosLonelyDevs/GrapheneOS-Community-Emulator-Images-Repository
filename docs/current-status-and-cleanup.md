# Current status and cleanup

Date: 2026-09-18

## Public project status

- Windows + WSL source-build orchestration is complete.
- QEMU-specific image packaging is complete.
- The retained release sysdir boots as Android 17 / API 37 / `sdk_phone64_x86_64-userdebug` on x86-64, boot-validated on Windows x86-64 on 2026-09-18.
- GrapheneOS and Vanadium packages were observed on the running emulator, and the emulator produced no guest kernel panic.
- The exact boot-tested sysdir is 12 files totalling 6.18 GB and has a per-file SHA-256 manifest, itself hashing to `33e2ed8e6bcdafc9676d83f67fa209cac8c217f0470121f998bb9d46d7e7601b`.
- GrapheneOS tag `2026091000` and manifest commit `ac9f2fdf0badebea2f6ac6c3e93b125aba02116a` are recorded and signature-verified against the published ED25519 key for `contact@grapheneos.org`.
- The `2026091000` image is packaged and published as the current release: a split ZIP, checksums, provenance, validation report, and join instructions were generated, then independently verified by recomputing every digest and proving a streamed rejoin of the numbered parts reproduces the complete ZIP hash exactly.
- The earlier `2026062800` release remains available and went through the same verification.
- Publishing happened only after the owner explicitly approved the push and upload. Every future push, tag, release, and asset upload needs the same explicit approval.

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

A build borrows hundreds of gigabytes of disk, most of the host RAM and every CPU thread through a generated `.wslconfig`, and the sleep-on-idle setting. `-Restore` returns all of it in one command.

```powershell
# dry run: prints the plan and the measured sizes, changes nothing
.\scripts\build-grapheneos-emulator.ps1 -Restore -GrapheneOsTag <tag> -OutputRoot <root>

# apply it
.\scripts\build-grapheneos-emulator.ps1 -Restore -Force -GrapheneOsTag <tag> -OutputRoot <root>
```

It restores the original `.wslconfig` from the backup recorded at launch, restores the prior sleep timeout, deletes the whole WSL build tree, removes a `GrapheneOS-Build-<tag>` scheduled task if one exists, shuts WSL down, and then re-measures the disk image and host volume to report how much space actually came back. Add `-Compact` to compact the disk image from an elevated session, or `-DisableSparse` to turn sparse mode back off.

Restore refuses to run while a build is still running, and it is a dry run unless `-Force` is passed. Both are deliberate: the destructive step deletes a multi-hour source checkout.

Narrower options and standing rules:

- Keep `sysdir\` while you need the compiled emulator image, and `release\` while you need the locally verified release assets. Move anything you want to keep out of the WSL filesystem before restoring.
- Use `-Reclaim` instead of `-Restore` when you intend to keep the source checkout for a rebuild; it deletes only `~/android/grapheneos/out`.
- Stop active emulator and WSL processes before disk compaction.
- Prefer `wsl --manage <distro> --set-sparse true` where supported. WSL exposes no way to read the previous value, so `-Restore` leaves sparse mode enabled unless you ask for `-DisableSparse`.
- Never use `wsl --unregister <distro>` for ordinary cleanup; it deletes the entire distribution.

The orchestrator records the restoration state in `state\wslconfig-restore.json` under the output root. Review it before manually deleting build logs or state markers — losing it costs you the automatic `.wslconfig` and sleep-timeout restore.

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
