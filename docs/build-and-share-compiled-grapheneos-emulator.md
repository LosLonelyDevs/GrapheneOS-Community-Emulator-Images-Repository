# Build and share the compiled GrapheneOS emulator image

This guide is for sharing a compiled GrapheneOS emulator image for local Android development.

For selecting and building a current or future upstream version, start with [Create a new GrapheneOS emulator image](create-new-emulator-image.md).

It is not an official GrapheneOS release. Label published artifacts as unofficial, development-only emulator builds.

Official reference: https://grapheneos.org/build

## What to share

Share the packaged emulator sysdir as a release artifact, not as committed git files.

Required artifact:

```text
sysdir/
  system.img
  vendor.img
  super.img
  ramdisk.img
  userdata.img
  kernel-ranchu
  encryptionkey.img
  advancedFeatures.ini
  VerifiedBootParams.textproto
  kernel_cmdline.txt
```

The package step must prefer QEMU-specific images:

- `system-qemu.img` copied as `system.img`
- `vendor-qemu.img` copied as `vendor.img`
- `ramdisk-qemu.img` copied as `ramdisk.img`

Using the generic images can boot-panic during first-stage init because the emulator expects the QEMU/GPT block-device layout.

## Local build flow

From this repo:

```powershell
$Tag = 'YYYYMMDDNN' # replace with a verified ten-digit GrapheneOS release tag
.\scripts\build-grapheneos-emulator.ps1 -GrapheneOsTag $Tag
```

Useful modes:

```powershell
.\scripts\build-grapheneos-emulator.ps1 -Validate
.\scripts\build-grapheneos-emulator.ps1 -Finalize
.\scripts\build-grapheneos-emulator.ps1 -NoConfig
```

Default output:

```text
C:\Android\grapheneos-emulator\sysdir
C:\Android\grapheneos-emulator\logs
C:\Android\grapheneos-emulator\state
```

## Release package layout

The packager creates a directory and matching ZIP named like:

```text
grapheneos-community-emulator-sdk_phone64_x86_64-<tag>-poc1/
  BUILD-METADATA.txt
  LICENSE
  README.txt
  THIRD-PARTY-NOTICES.txt
  UPSTREAM-TAG-VERIFICATION.json
  BOOT-VALIDATION.json
  SYSDIR-MANIFEST-SHA256.txt
  install/
  sysdir/
    source.properties
    ...boot images...
```

It also writes `SHA256SUMS.txt`, numbered ZIP parts when the archive exceeds the release-asset limit,
and exact join instructions. Compiled images and archives stay outside Git under
`C:\Android\grapheneos-emulator\release`.

## Package commands

First validate the exact sysdir and verify its upstream tag:

```powershell
.\scripts\build-grapheneos-emulator.ps1 -Validate
.\scripts\verify-upstream-tag.ps1 -Tag $Tag
```

Then package from a clean, committed automation revision:

```powershell
.\scripts\package-grapheneos-emulator-release.ps1 -GrapheneOsTag $Tag
```

The packager stops if the sysdir has changed since validation, required metadata is absent, the
upstream tag was not verified, or tracked repository files are dirty.

## GitHub publishing model

Commit only source, documentation, tests, and installer scripts. Never commit `sysdir/`, `.repo/`,
`out/`, `*.img`, archives, logs, or machine-local configuration. Put the numbered ZIP parts,
`SHA256SUMS.txt`, and join instructions on a GitHub Release only after explicit owner approval.

Keep the complete ZIP locally for verification; it is normally too large to upload as one asset.
Consumers verify every downloaded part, join the parts, verify the complete ZIP, then extract it.
The generated `JOIN-INSTRUCTIONS.txt` contains exact commands for Windows and Unix-like systems.

## User install instructions

Users need Android Studio or the Android SDK command-line tools, the Android Emulator, and an x86-64
phone AVD. After extracting the release, use the bundled platform script:

```powershell
.\install\setup-windows.ps1
.\install\launch-windows.ps1
```

```bash
./install/setup-linux.sh
./install/launch-linux.sh
```

Intel macOS uses `setup-macos.sh` and `launch-macos.sh`. Apple Silicon cannot run this x86-64 image
natively; a future ARM64 emulator target must be built separately.

## Validation before release

`-Validate` must prove ADB connectivity, `sys.boot_completed=1`, the exact
`sdk_phone64_x86_64-userdebug` flavor, Vanadium presence, and absence of a guest kernel panic. It then
hashes every file in the exact boot-tested sysdir and writes the report and manifest under the local
state directory.

See [provenance.md](provenance.md) for what these hashes prove—and what they cannot prove.

## Safety and naming

- Do not call the artifact an official GrapheneOS build or imply endorsement.
- Do not imply production-device security properties.
- Do not ship private signing keys or identifying build-host data.
- Prefer stable, signature-verified GrapheneOS tags for public artifacts.
- Publish exact source, automation revision, validation report, and checksums.
- Keep GrapheneOS trademark use factual and pair it with a prominent unofficial-project notice.
