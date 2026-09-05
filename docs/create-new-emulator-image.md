# Create a new GrapheneOS emulator image

This is the maintainer runbook for building a new `sdk_phone64_x86_64` image from a current or future GrapheneOS release. It covers source selection through a release candidate. The result is an unofficial, community-built development image; it does not provide production Pixel security properties and is not endorsed by GrapheneOS.

The automated source build currently requires a Windows x86-64 host with Ubuntu on WSL2. It is a multi-hour, storage-heavy operation. Do not start it merely to change documentation, packaging, or screenshots.

## 1. Choose and verify the upstream tag

Select a stable ten-digit release tag from the official GrapheneOS releases and build documentation. Do not guess a tag or use an unverified branch head.

```powershell
$Tag = 'YYYYMMDDNN' # replace with the real ten-digit tag
$OutputRoot = Join-Path 'C:\Android' "grapheneos-emulator-$Tag"
.\scripts\verify-upstream-tag.ps1 -Tag $Tag -OutputRoot $OutputRoot
```

The verification script fetches GrapheneOS's current allowed-signers file, verifies the manifest tag signature, resolves its exact commit, and writes `state\upstream-tag-verification.json` below the external output root. Stop if verification fails.

Official references:

- https://grapheneos.org/releases
- https://grapheneos.org/build

## 2. Check retained build state

Build markers under `~/android/state` belong to one GrapheneOS tag. Check the recorded tag before starting:

```powershell
wsl -d Ubuntu -- bash -lc 'printf "retained tag: "; cat ~/android/state/grapheneos_tag.txt 2>/dev/null || echo none'
```

- Same tag: a stopped build may be resumed.
- No state: start normally.
- Different tag, or markers with no recorded tag: do not reuse them. The build script rejects this condition so a future build cannot silently package an older source tree.

For a different tag, use a separate WSL distro or archive the old WSL build root before starting. This recoverable command renames it rather than deleting it:

```powershell
wsl -d Ubuntu -- bash -lc 'stamp=$(date +%Y%m%d-%H%M%S); mv "$HOME/android" "$HOME/android-archive-$stamp"'
```

Confirm sufficient free space before preserving a large archive. `-Reclaim` deletes only `~/android/grapheneos/out`; it does not reset the source checkout or tag markers. Any permanent source/state deletion must be deliberate and must target verified paths.

## 3. Build the selected tag

Pass the tag explicitly. The environment variable is supported for automation, but the parameter is clearer in a human terminal:

```powershell
.\scripts\build-grapheneos-emulator.ps1 -GrapheneOsTag $Tag -OutputRoot $OutputRoot
```

Equivalent environment override:

```powershell
$env:GRAPHENEOS_TAG = $Tag
$env:GRAPHENEOS_EMULATOR_ROOT = $OutputRoot
.\scripts\build-grapheneos-emulator.ps1
```

The orchestrator syncs the exact manifest tag, builds in the WSL ext4 filesystem, prefers the QEMU-specific partition images, exports the sysdir outside Git, validates it, restores the prior WSL resource configuration, and launches the result. Never build the source tree under `/mnt/c`.

Monitor or resume post-build work without starting another build:

```powershell
.\scripts\build-grapheneos-emulator.ps1 -Status -OutputRoot $OutputRoot
.\scripts\build-grapheneos-emulator.ps1 -Finalize -OutputRoot $OutputRoot
.\scripts\build-grapheneos-emulator.ps1 -Validate -OutputRoot $OutputRoot
```

If a future GrapheneOS release changes the product target or required emulator files, stop and update the candidate targets, packaging contract, tests, and documentation together. Never fall back from `system-qemu.img`, `vendor-qemu.img`, or `ramdisk-qemu.img` without proving the replacement boots correctly.

### Optional manual cloud build

The repository includes `.github/workflows/build-emulator.yml` for a manually dispatched build on a dedicated cloud machine. It is intentionally not connected to `push`, `pull_request`, or a schedule.

The runner must be a separately provisioned Windows x86-64 cloud VM carrying the labels `self-hosted`, `Windows`, `X64`, and `grapheneos-cloud-builder`. It needs WSL2 with Ubuntu, hardware virtualization, Android SDK emulator tools, at least 32 GiB RAM, and enough fast storage for the source and build output. Do not assign the `grapheneos-cloud-builder` label to a personal workstation.

From the repository's **Actions** tab, select **Build GrapheneOS emulator image**, choose **Run workflow**, enter the verified ten-digit tag, and run it from `main`. The job verifies the upstream tag, runs the existing build and boot-validation gates without opening a visible emulator, packages the release candidate, and uploads the numbered parts, checksums, and join instructions as a temporary workflow artifact. It does not create a Git tag or GitHub Release.

## 4. Validate the exact sysdir

Validation must be newer than every packaged sysdir file. It must prove:

- ADB reaches state `device` and `sys.boot_completed=1`.
- `ro.build.flavor` is `sdk_phone64_x86_64-userdebug`.
- GrapheneOS and Vanadium packages are present.
- Emulator kernel output has no `Kernel panic - not syncing`.

Run `-Validate` again after any sysdir file changes. Keep the resulting validation JSON, per-file SHA-256 manifest, logs, upstream verification, tag, and manifest commit under the external output root.

## 5. Run the repository checks

These checks do not rebuild the operating system:

```powershell
pwsh -NoProfile -File .\tests\build-progress.tests.ps1
pwsh -NoProfile -File .\tests\orchestrator-contract.tests.ps1
pwsh -NoProfile -File .\tests\repository-contract.tests.ps1
wsl -d Ubuntu -- bash tests/gos-build-progress.test.sh
wsl -d Ubuntu -- bash tests/install-scripts.test.sh
```

Also parse every changed PowerShell script, run `bash -n` on every changed shell script, inspect `git status --short`, and scan public/staged content for credentials, usernames, hostnames, identifying paths, private keys, local AVD data, and large compiled artifacts.

## 6. Prepare the automation revision

The release packager requires a real, clean Git commit so every artifact identifies the exact automation used. Review the diff first, stage only explicit public paths, and never stage `data/`, `.agents/`, `.codex/`, source checkouts, logs, images, ZIPs, credentials, or machine-local configuration.

Use the repository's configured Git identity. Do not add AI attribution. A local commit does not authorize a push.

## 7. Package and independently verify

Use the upstream tag in both the metadata and release name. The first release for an upstream build uses the exact ten-digit tag; only a corrected repository-only repackaging of unchanged OS bytes adds an `-rN` suffix.

```powershell
$Name = "grapheneos-community-emulator-sdk_phone64_x86_64-$Tag"
.\scripts\package-grapheneos-emulator-release.ps1 -GrapheneOsTag $Tag -Name $Name -OutputRoot $OutputRoot
```

Packaging must fail if provenance, validation freshness, the clean automation revision, required boot files, or metadata do not agree. It writes a full ZIP, numbered parts when needed, `SHA256SUMS.txt`, and `JOIN-INSTRUCTIONS.txt`.

Before publishing:

1. Verify every numbered part against `SHA256SUMS.txt`.
2. Rejoin the parts using `JOIN-INSTRUCTIONS.txt`.
3. Verify the reconstructed ZIP hash.
4. Inspect the ZIP file list and embedded metadata.
5. Confirm the embedded upstream tag, manifest commit, automation commit, validation time, target, Android/API/security-patch data, license boundary, and development-only warning.
6. Extract to a temporary directory, run the consumer setup/launch flow, and confirm Android Studio sees the running emulator through ADB.

Hashes prove the release bytes match the bytes this project validated; they do not make the build official or prove reproducibility against an official GrapheneOS emulator binary. See [provenance.md](provenance.md).

## 8. Final privacy and release review

Use only screenshots from a freshly wiped disposable AVD with no accounts, personal apps, notifications, clipboard content, or identifying metadata. Confirm the release contains no host paths, usernames, hostnames, credentials, keys, logs, source trees, or generated AVD data.

The release body must state that the project is independent and unendorsed, development-only, which upstream tag and manifest commit were used, what was validated, and which hosts were tested. It must also include copy-paste commands for verifying every part, joining the ZIP, verifying the complete ZIP, and extracting it; do not make users download instructions just to understand the process. GPL-3.0 applies only to repository-owned material; bundled Android, GrapheneOS, and other third-party components retain their upstream licenses.

Do not push or publish a Git commit, tag, GitHub Release, or release asset without the repository owner's explicit approval for that external action.
