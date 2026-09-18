# AGENTS.md

Instructions for coding agents working in GrapheneOS Community Emulator Images Repository.

## Project identity

GrapheneOS Community Emulator Images Repository builds, validates, packages, and launches community-built SDK emulator images compiled from official GrapheneOS sources.

- This is an independent project, not an official GrapheneOS repository. Every public surface must say so prominently.
- Do not use the GrapheneOS logo or present releases as endorsed.
- Use the GrapheneOS name only for factual upstream attribution.
- Emulator targets are development-only and do not provide production Pixel security properties.

## Start here

1. Read this file before changing the repository.
2. Read `README.md` for the public user flow.
3. Read `docs/project-design.md` for naming, release channels, and platform policy.
4. Read `docs/create-new-emulator-image.md` before building a new upstream version.
5. Read `docs/build-and-share-compiled-grapheneos-emulator.md` before packaging or publishing.
6. If `data/GRAPHENEOS_EMULATOR_PLAN.md` exists, it is the owner's ignored machine journal. Read it before machine-specific work and update its tracker/log after meaningful local build or release steps. Public clones will not contain it.

Preserve unrelated worktree changes. Never expose contents from `data/`, `.agents/`, `.codex/`, credentials, signing material, local paths, hostnames, or usernames in commits or releases.

## User workflows

### Consume a prebuilt bundle

Users extract a release ZIP, create or reuse a normal x86-64 phone AVD, and run the platform setup script:

```powershell
pwsh -NoProfile -File .\install\setup-windows.ps1 -AvdName GrapheneOS_Base
pwsh -NoProfile -File .\install\launch-windows.ps1
```

```bash
./install/setup-linux.sh GrapheneOS_Base
./install/launch-linux.sh

./install/setup-macos.sh GrapheneOS_Base
./install/launch-macos.sh
```

Windows x86-64 is validated. Linux x86-64 and Intel macOS are experimental until exercised on real hosts. Reject ARM64 hosts for the x86-64 artifact with a clear error.

### Validate the retained Windows sysdir

```powershell
.\scripts\build-grapheneos-emulator.ps1 -Validate
```

Pass criteria:

- ADB state is `device`.
- `sys.boot_completed=1`.
- `ro.build.flavor=sdk_phone64_x86_64-userdebug`.
- GrapheneOS and Vanadium packages are present.
- Emulator kernel output contains no `Kernel panic - not syncing`.

Validation uses dedicated serial `emulator-5584`, `-wipe-data`, and `-no-snapshot`. Save emulator output and the validation marker under the external output root.

### Package a release

```powershell
.\scripts\package-grapheneos-emulator-release.ps1
```

Packaging must fail unless:

- the sysdir has every required boot file plus `source.properties`;
- validation is newer than every sysdir file;
- the GrapheneOS tag and exact manifest commit are known;
- the automation repository has a clean, real commit;
- embedded metadata contains build fingerprint, Android/API/security-patch values, validation time, upstream provenance, automation revision, and the development-only warning.

The packager includes `install/`, writes a per-file manifest, creates the ZIP, splits oversized ZIPs, writes join instructions, and hashes the complete ZIP plus all numbered parts.

### Build from source

Do not start a multi-hour rebuild for documentation, packaging, or existing-image work. Build only when the user explicitly asks for a new OS build.

From Windows PowerShell:

```powershell
.\scripts\build-grapheneos-emulator.ps1
.\scripts\build-grapheneos-emulator.ps1 -Status
.\scripts\build-grapheneos-emulator.ps1 -Finalize
.\scripts\build-grapheneos-emulator.ps1 -Reclaim
.\scripts\build-grapheneos-emulator.ps1 -Restore
.\scripts\build-grapheneos-emulator.ps1 -NoConfig
```

The Windows orchestrator deploys `scripts/gos-build.sh` into Ubuntu WSL, builds in the WSL ext4 filesystem, exports the sysdir, validates it, restores `.wslconfig`, and launches the visible AVD. Build output never belongs under `/mnt/c`.

### Host resource safety and restore

A build borrows hundreds of gigabytes of disk, most of the host RAM and every CPU thread, and the sleep-on-idle setting. Treat all of it as borrowed, and give it back.

Before a build, the orchestrator fails closed on insufficient disk. Do not paper over that failure:

- `-MinFreeGB` (default 300) gates a full sync + build; `-MinFreeResumeGB` (default 150) gates a resume where `sync.done` already exists.
- The precheck measures the WSL filesystem and the host volume backing the WSL disk, discovered from the registry — never assume a drive letter or install path.
- `-SkipSpaceCheck` exists for deliberate override only. Never pass it to get past a failing precheck without the owner saying so.
- Sleep-on-idle is disabled for the build and the prior timeout is recorded in `state\wslconfig-restore.json`. A machine that sleeps mid-build kills the build host.

After a build, `-Restore` returns the host to its pre-build state: original `.wslconfig`, prior sleep timeout, the entire WSL build tree deleted, any `GrapheneOS-Build-<tag>` scheduled task removed, WSL shut down, then the disk image and host volume re-measured so the reclaimed space is reported rather than assumed.

- `-Restore` is a dry run that prints its plan; it only acts with `-Force`. Keep it that way.
- It refuses to run while a build is running.
- `-Compact` compacts the disk image and needs an elevated session; `-DisableSparse` turns sparse mode back off. Sparse state cannot be read back from WSL, so it is left enabled by default rather than guessed.
- Use `-Reclaim` instead when the source checkout is intentionally being kept for a rebuild.
- Move the sysdir and any release assets out of the WSL filesystem before restoring.
- Never delete `state\wslconfig-restore.json` while a build is in flight; it is the only record of what must be put back.

Never run the orchestrator as an agent-owned background task. A harness that kills its own task under memory pressure takes the hidden WSL build host with it. Launch long builds from Task Scheduler so the process is owned outside the agent, then poll with short-lived `-Status` calls.

The manual `.github/workflows/build-emulator.yml` path is for a separately provisioned large Windows x86-64 cloud runner labeled `grapheneos-cloud-builder`. It never runs automatically and never publishes a release. Do not dispatch it without explicit owner authorization for a new multi-hour build, and never assign its custom label to the owner's personal workstation.

### Create a new image for a current or future GrapheneOS version

Follow `docs/create-new-emulator-image.md` as the human-facing source of truth, then apply this agent checklist:

1. Confirm the owner explicitly requested a new multi-hour OS build. Documentation, packaging, existing-image, and audit requests do not authorize one.
2. Select a stable ten-digit tag from official GrapheneOS release information. Run `scripts/verify-upstream-tag.ps1 -Tag <tag>` and stop on signature failure.
3. Inspect `~/android/state/grapheneos_tag.txt` and all phase markers. Resume only when the recorded tag equals the requested tag. Never reuse, rewrite, or delete mismatched or ambiguous retained build state without explicit owner direction; use a separate distro or recoverable archive when possible.
4. Start with `scripts/build-grapheneos-emulator.ps1 -GrapheneOsTag <tag>`. The orchestrator propagates `GRAPHENEOS_TAG` into WSL. Never remove the tag mismatch guard or skip `repo init` for a new sync.
5. Monitor with `-Status`. After the build, run `-Finalize` or `-Validate`. Any sysdir mutation invalidates prior boot proof and requires validation again.
6. Run every applicable repository test and parser. Review public content for secrets, identity data, local paths, hostnames, logs, source trees, AVD data, and compiled artifacts. Update the ignored machine journal without exposing it.
7. Review and commit only explicit public paths so the automation revision is real and clean. Package with `-GrapheneOsTag <tag>` and an upstream-tagged release name. Never use `git add .` for release preparation.
8. Verify part hashes, reconstruct and verify the ZIP, inspect embedded provenance, and smoke-test the extracted consumer flow. Put copy-paste commands for verifying the parts, joining them, verifying the complete ZIP, and extracting it directly in the release notes. Use only freshly wiped, non-personal screenshots.
9. Stop before any push, tag, GitHub Release, or asset upload. Obtain explicit owner approval for each external publishing action.
10. Once the sysdir and release assets are safely outside the WSL filesystem, return the borrowed host resources. Show the owner the `-Restore` dry-run plan first, apply it with `-Force` only after they agree, and report the reclaimed space the command measured.

## Architecture

- `scripts/build-grapheneos-emulator.ps1`: Windows orchestration, progress, validation, resource restoration, and visible launch.
- `scripts/gos-build.sh`: idempotent WSL phases `sync -> build -> package`, coordinated through markers under `~/android/state`.
- `scripts/build-progress.ps1`: pure progress parsing and state functions.
- `scripts/package-grapheneos-emulator-release.ps1`: provenance-aware release staging, hashing, splitting, and join instructions.
- `install/`: cross-platform consumer setup and launch scripts shipped in release bundles.

## Critical image contract

The package phase must prefer:

- `system-qemu.img` as `system.img`
- `vendor-qemu.img` as `vendor.img`
- `ramdisk-qemu.img` as `ramdisk.img`

These carry the emulator block-device/GPT layout needed by first-stage init. Generic images can cause a guest kernel panic. Do not weaken the tests guarding this behavior.

## Output boundaries

Compiled artifacts live outside Git:

```text
C:\Android\grapheneos-emulator\sysdir
C:\Android\grapheneos-emulator\logs
C:\Android\grapheneos-emulator\state
C:\Android\grapheneos-emulator\release
```

Never commit `*.img`, release archives, source checkouts, `.repo/`, `out/`, build logs, or generated local AVD configuration. GitHub Releases hold compiled artifacts.

## Tests

Run every applicable test before declaring work complete:

```powershell
pwsh -NoProfile -File .\tests\build-progress.tests.ps1
pwsh -NoProfile -File .\tests\orchestrator-contract.tests.ps1
pwsh -NoProfile -File .\tests\repository-contract.tests.ps1
wsl -d Ubuntu -- bash tests/gos-build-progress.test.sh
wsl -d Ubuntu -- bash tests/install-scripts.test.sh
```

Also parse every changed PowerShell script and run `bash -n` on every changed shell script. A prior passing boot marker is not proof after sysdir contents change; run `-Validate` again.

## Git and release safety

- Check `git status --short` before and after edits.
- Stage explicit public paths; do not use `git add .` while ignored/local files are being audited.
- Use the user's configured Git identity. Do not add AI attribution.
- Scan staged content for credentials and identifying paths before committing.
- Keep repository licensing separate from bundled third-party licensing. Repository-owned material is GPL-3.0 to the extent contributors own it; Android/GrapheneOS binaries retain upstream licenses.
- Never create a GitHub repository, push, or publish a release unless the user explicitly authorizes that external action.
