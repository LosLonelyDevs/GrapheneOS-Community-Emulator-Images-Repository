# Build provenance and integrity validation

## What the release can prove

The repository creates a verifiable chain:

1. The upstream GrapheneOS manifest tag is verified using GrapheneOS's published SSH allowed-signers file.
2. The exact manifest commit is recorded.
3. The automation repository commit and build properties are recorded.
4. A headless emulator boots the sysdir and passes the required runtime checks.
5. Every file in that exact boot-tested sysdir is SHA-256 hashed.
6. Packaging refuses to continue if any file differs from the boot-validation manifest.
7. The release ZIP and every numbered part receive published SHA-256 hashes.

This proves that the published bytes match the bytes boot-tested by this project and ties the build recipe to exact upstream and automation revisions.

## What it cannot prove

GrapheneOS does not publish an official SDK emulator binary for byte-for-byte comparison. A checksum alone cannot prove that a local compiler or build host was trustworthy, and an attacker able to replace both an asset and its checksum can defeat an unsigned checksum.

Stronger future releases should:

- build in a public, reviewed workflow where practical;
- preserve a resolved `repo manifest -r` from the source tree at build time;
- publish build date/number inputs needed for reproducibility;
- have an independent party reproduce the build and compare files other than expected signing differences;
- sign the checksum file or generate a transparent artifact attestation.

GitHub artifact attestations can bind artifacts to a repository, workflow, commit, and triggering event through Sigstore. They are most meaningful when the artifact is built inside that workflow rather than merely uploaded after a local build. See [GitHub's artifact attestation documentation](https://docs.github.com/en/actions/concepts/security/artifact-attestations).

## Consumer verification

First verify each downloaded part against `SHA256SUMS.txt`. Join the parts, verify the complete ZIP, extract it, then verify the sysdir:

```bash
cd extracted-release
sha256sum -c SYSDIR-MANIFEST-SHA256.txt
```

On PowerShell:

```powershell
Get-Content .\SYSDIR-MANIFEST-SHA256.txt | ForEach-Object {
  if ($_ -match '^([0-9a-f]{64})  (.+)$') {
    $actual = (Get-FileHash -LiteralPath $Matches[2] -Algorithm SHA256).Hash.ToLower()
    if ($actual -ne $Matches[1]) { throw "hash mismatch: $($Matches[2])" }
  }
}
```

The official GrapheneOS source-verification procedure is documented in its [stable release build instructions](https://grapheneos.org/build#stable-release).
