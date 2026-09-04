[CmdletBinding()]
param(
  [string]$OutputRoot = $(if ($env:GRAPHENEOS_EMULATOR_ROOT) { $env:GRAPHENEOS_EMULATOR_ROOT } else { 'C:\Android\grapheneos-emulator' }),
  [string]$SysDir,
  [string]$ReleaseRoot,
  [string]$GrapheneOsTag,
  [string]$GrapheneOsManifestRevision,
  [string]$AutomationRevision,
  [string]$RepositoryUrl,
  [string]$ValidationMarker,
  [string]$ValidationManifest,
  [string]$ValidationReport,
  [string]$UpstreamVerification,
  [string]$Name,
  [ValidateRange(100, 1950)]
  [int]$PartSizeMB = 1900,
  [switch]$NoSplit,
  [switch]$Force
)

$ErrorActionPreference = 'Stop'
$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path
$SysDir = if ($SysDir) { $SysDir } else { Join-Path $OutputRoot 'sysdir' }
$ReleaseRoot = if ($ReleaseRoot) { $ReleaseRoot } else { Join-Path $OutputRoot 'release' }
$stateRoot = Join-Path $OutputRoot 'state'
$ValidationMarker = if ($ValidationMarker) { $ValidationMarker } else { Join-Path $stateRoot 'validate.done' }
$ValidationManifest = if ($ValidationManifest) { $ValidationManifest } else { Join-Path $stateRoot 'validated-sysdir-SHA256.txt' }
$ValidationReport = if ($ValidationReport) { $ValidationReport } else { Join-Path $stateRoot 'validation.json' }
$UpstreamVerification = if ($UpstreamVerification) { $UpstreamVerification } else { Join-Path $stateRoot 'upstream-tag-verification.json' }

function Say([string]$Message) {
  '[{0}] {1}' -f (Get-Date -Format 'HH:mm:ss'), $Message
}

function Require-File([string]$Path) {
  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "missing required file: $Path"
  }
}

function Get-BuildProperty {
  param(
    [hashtable]$Properties,
    [Parameter(Mandatory)][string[]]$Names
  )
  foreach ($propertyName in $Names) {
    if ($Properties.ContainsKey($propertyName) -and $Properties[$propertyName]) {
      return $Properties[$propertyName]
    }
  }
  return $null
}

function Split-ReleaseFile {
  param(
    [Parameter(Mandatory)][string]$Path,
    [Parameter(Mandatory)][long]$PartBytes
  )

  $parts = [Collections.Generic.List[string]]::new()
  $buffer = [byte[]]::new(8MB)
  $source = [IO.File]::OpenRead($Path)
  try {
    $partNumber = 1
    while ($source.Position -lt $source.Length) {
      $partPath = '{0}.part{1}' -f $Path, $partNumber
      $parts.Add($partPath)
      $destination = [IO.File]::Open($partPath, [IO.FileMode]::Create, [IO.FileAccess]::Write)
      try {
        $remaining = [Math]::Min($PartBytes, $source.Length - $source.Position)
        while ($remaining -gt 0) {
          $requested = [int][Math]::Min($buffer.Length, $remaining)
          $read = $source.Read($buffer, 0, $requested)
          if ($read -le 0) { throw "unexpected end of file while splitting $Path" }
          $destination.Write($buffer, 0, $read)
          $remaining -= $read
        }
      } finally {
        $destination.Dispose()
      }
      $partNumber++
    }
  } finally {
    $source.Dispose()
  }
  return $parts.ToArray()
}

$required = @(
  'system.img',
  'vendor.img',
  'super.img',
  'ramdisk.img',
  'userdata.img',
  'kernel-ranchu',
  'encryptionkey.img',
  'advancedFeatures.ini',
  'VerifiedBootParams.textproto',
  'kernel_cmdline.txt',
  'source.properties',
  'build.prop'
)

if (-not (Test-Path -LiteralPath $SysDir -PathType Container)) {
  throw "sysdir not found: $SysDir"
}
$SysDir = (Resolve-Path -LiteralPath $SysDir).Path.TrimEnd('\', '/')
foreach ($file in $required) {
  Require-File (Join-Path $SysDir $file)
}
Require-File $ValidationMarker
Require-File $ValidationManifest
Require-File $ValidationReport
Require-File $UpstreamVerification
Require-File (Join-Path $repoRoot 'LICENSE')

$upstreamProof = Get-Content -LiteralPath $UpstreamVerification -Raw | ConvertFrom-Json
if (-not $GrapheneOsTag) {
  $GrapheneOsTag = [string]$upstreamProof.Tag
}
if ($GrapheneOsTag -notmatch '^[0-9]{10}$') {
  throw "invalid GrapheneOS tag: $GrapheneOsTag"
}

if (-not $GrapheneOsManifestRevision) {
  Say "resolving GrapheneOS manifest tag $GrapheneOsTag"
  $refs = @(& git ls-remote 'https://github.com/GrapheneOS/platform_manifest.git' "refs/tags/$GrapheneOsTag" "refs/tags/$GrapheneOsTag^{}")
  if ($LASTEXITCODE -ne 0) { throw 'git ls-remote failed for the GrapheneOS manifest' }
  $peeled = $refs | Where-Object { $_ -match '\^\{\}$' } | Select-Object -First 1
  $selected = if ($peeled) { $peeled } else { $refs | Select-Object -First 1 }
  $GrapheneOsManifestRevision = ($selected -split '\s+')[0]
}
if ($GrapheneOsManifestRevision -notmatch '^[0-9a-fA-F]{40}$') {
  throw "invalid GrapheneOS manifest revision: $GrapheneOsManifestRevision"
}
$GrapheneOsManifestRevision = $GrapheneOsManifestRevision.ToLowerInvariant()

$sourceProperties = @{}
foreach ($line in Get-Content -LiteralPath (Join-Path $SysDir 'source.properties')) {
  if ($line -match '^(?<name>[^#=]+)=(?<value>.*)$') {
    $sourceProperties[$Matches.name.Trim()] = $Matches.value.Trim()
  }
}
if ($sourceProperties['GrapheneOS.Tag'] -ne $GrapheneOsTag) {
  throw "sysdir source.properties tag mismatch: $($sourceProperties['GrapheneOS.Tag'])"
}
if ($sourceProperties['GrapheneOS.ManifestCommit'] -ne $GrapheneOsManifestRevision) {
  throw "sysdir source.properties manifest mismatch: $($sourceProperties['GrapheneOS.ManifestCommit'])"
}

if (-not $upstreamProof.Verified) {
  throw 'upstream tag verification report is not successful'
}
if ($upstreamProof.Tag -ne $GrapheneOsTag) {
  throw "upstream verification tag mismatch: $($upstreamProof.Tag)"
}
if ([string]$upstreamProof.ManifestCommit -notmatch '^[0-9a-fA-F]{40}$' -or
    $upstreamProof.ManifestCommit.ToLowerInvariant() -ne $GrapheneOsManifestRevision) {
  throw "upstream verification commit mismatch: $($upstreamProof.ManifestCommit)"
}

if (-not $AutomationRevision) {
  $AutomationRevision = (& git -C $repoRoot rev-parse HEAD 2>$null).Trim()
  if ($LASTEXITCODE -ne 0) {
    throw 'automation repository has no commit; commit the public files before packaging'
  }
}
if ($AutomationRevision -notmatch '^[0-9a-fA-F]{40}$') {
  throw "invalid automation revision: $AutomationRevision"
}
$AutomationRevision = $AutomationRevision.ToLowerInvariant()

$trackedChanges = @(& git -C $repoRoot status --porcelain --untracked-files=no)
if ($LASTEXITCODE -ne 0) { throw 'unable to inspect automation repository status' }
if ($trackedChanges.Count -gt 0) {
  throw 'automation repository has uncommitted tracked changes; commit them before packaging'
}

if (-not $RepositoryUrl) {
  $RepositoryUrl = (& git -C $repoRoot remote get-url origin 2>$null | Select-Object -First 1)
  if ($RepositoryUrl) {
    $RepositoryUrl = $RepositoryUrl.Trim()
    if ($RepositoryUrl -match '^git@github\.com:(.+?)(?:\.git)?$') {
      $RepositoryUrl = "https://github.com/$($Matches[1])"
    }
  } else {
    $RepositoryUrl = 'not configured at packaging time'
  }
}

$validationText = (Get-Content -LiteralPath $ValidationMarker -Raw).Trim()
$validationTime = [DateTimeOffset]::MinValue
if (-not [DateTimeOffset]::TryParse($validationText, [ref]$validationTime)) {
  throw "validation marker does not contain an ISO timestamp: $ValidationMarker"
}
$latestSysDirWrite = Get-ChildItem -LiteralPath $SysDir -File -Recurse |
  Sort-Object LastWriteTimeUtc -Descending |
  Select-Object -First 1
if ($validationTime.UtcDateTime -lt $latestSysDirWrite.LastWriteTimeUtc) {
  throw "validation is stale: rerun build-grapheneos-emulator.ps1 -Validate after the latest sysdir change"
}

Say 'verifying the current sysdir against the boot-validation manifest'
$validatedHashes = @{}
foreach ($line in Get-Content -LiteralPath $ValidationManifest) {
  if ($line -notmatch '^(?<hash>[0-9a-fA-F]{64})  sysdir/(?<path>.+)$') {
    throw "invalid validation manifest line: $line"
  }
  $validatedHashes[$Matches['path']] = $Matches['hash'].ToLowerInvariant()
}
$currentManifestLines = [Collections.Generic.List[string]]::new()
$currentPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($file in Get-ChildItem -LiteralPath $SysDir -File -Recurse | Sort-Object FullName) {
  $relative = $file.FullName.Substring($SysDir.Length).TrimStart('\', '/').Replace('\', '/')
  $null = $currentPaths.Add($relative)
  if (-not $validatedHashes.ContainsKey($relative)) {
    throw "sysdir file was not boot-validated: $relative"
  }
  $hash = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
  if ($hash -ne $validatedHashes[$relative]) {
    throw "sysdir changed after boot validation: $relative"
  }
  $currentManifestLines.Add("$hash  sysdir/$relative")
}
foreach ($relative in $validatedHashes.Keys) {
  if (-not $currentPaths.Contains($relative)) {
    throw "boot-validated sysdir file is now missing: $relative"
  }
}
$validationManifestHash = (Get-FileHash -LiteralPath $ValidationManifest -Algorithm SHA256).Hash.ToLowerInvariant()

$properties = @{}
foreach ($line in Get-Content -LiteralPath (Join-Path $SysDir 'build.prop')) {
  if ($line -match '^(?<name>[^#=]+)=(?<value>.*)$') {
    $properties[$Matches['name']] = $Matches['value']
  }
}
$androidVersion = Get-BuildProperty $properties @('ro.system.build.version.release', 'ro.build.version.release')
$apiLevel = Get-BuildProperty $properties @('ro.system.build.version.sdk', 'ro.build.version.sdk')
$securityPatch = Get-BuildProperty $properties @('ro.build.version.security_patch', 'ro.system.build.version.security_patch')
$buildId = Get-BuildProperty $properties @('ro.system.build.id', 'ro.build.id')
$fingerprint = Get-BuildProperty $properties @('ro.system.build.fingerprint', 'ro.build.fingerprint')
foreach ($pair in @{
  AndroidVersion = $androidVersion
  ApiLevel = $apiLevel
  SecurityPatch = $securityPatch
  BuildId = $buildId
  Fingerprint = $fingerprint
}.GetEnumerator()) {
  if (-not $pair.Value) { throw "build.prop is missing $($pair.Key)" }
}

if (-not $Name) {
  $Name = "grapheneos-community-emulator-sdk_phone64_x86_64-$GrapheneOsTag-poc1"
}
if ($Name -notmatch '^[A-Za-z0-9._-]+$') {
  throw 'release name may contain only letters, numbers, dot, underscore, and dash'
}

New-Item -ItemType Directory -Force -Path $ReleaseRoot | Out-Null
$stage = Join-Path $ReleaseRoot $Name
$stageSysDir = Join-Path $stage 'sysdir'
$stageInstall = Join-Path $stage 'install'
$zip = Join-Path $ReleaseRoot "$Name.zip"
$sha = Join-Path $ReleaseRoot "$Name-SHA256SUMS.txt"
$joinInstructions = Join-Path $ReleaseRoot "$Name-JOIN-INSTRUCTIONS.txt"
$manifest = Join-Path $stage 'SYSDIR-MANIFEST-SHA256.txt'

$existing = @($stage, $zip, $sha, $joinInstructions)
$existing += @(Get-ChildItem -LiteralPath $ReleaseRoot -Filter "$Name.zip.part*" -File -ErrorAction SilentlyContinue |
  ForEach-Object FullName)
if ($existing | Where-Object { Test-Path -LiteralPath $_ }) {
  if (-not $Force) {
    throw "release already exists; rerun with -Force or a different -Name: $Name"
  }
  foreach ($path in $existing | Select-Object -Unique) {
    Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction SilentlyContinue
  }
}

New-Item -ItemType Directory -Force -Path $stageSysDir | Out-Null
New-Item -ItemType Directory -Force -Path $stageInstall | Out-Null

Say "staging sysdir hardlinks: $stageSysDir"
$sourceRoot = (Resolve-Path -LiteralPath $SysDir).Path
foreach ($src in Get-ChildItem -LiteralPath $sourceRoot -File -Recurse) {
  $relative = $src.FullName.Substring($sourceRoot.Length).TrimStart('\', '/')
  $dest = Join-Path $stageSysDir $relative
  $destParent = Split-Path -Parent $dest
  New-Item -ItemType Directory -Force -Path $destParent | Out-Null
  try {
    New-Item -ItemType HardLink -Path $dest -Target $src.FullName | Out-Null
  } catch {
    Copy-Item -LiteralPath $src.FullName -Destination $dest -Force
  }
}

Say 'staging cross-platform setup and launch scripts'
$installRoot = Join-Path $repoRoot 'install'
foreach ($src in Get-ChildItem -LiteralPath $installRoot -File -Recurse) {
  $relative = $src.FullName.Substring($installRoot.Length).TrimStart('\', '/')
  $dest = Join-Path $stageInstall $relative
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
  Copy-Item -LiteralPath $src.FullName -Destination $dest -Force
}
Copy-Item -LiteralPath (Join-Path $repoRoot 'LICENSE') -Destination (Join-Path $stage 'LICENSE') -Force
Copy-Item -LiteralPath $ValidationReport -Destination (Join-Path $stage 'BOOT-VALIDATION.json') -Force
Copy-Item -LiteralPath $UpstreamVerification -Destination (Join-Path $stage 'UPSTREAM-TAG-VERIFICATION.json') -Force

$sysBytes = (Get-ChildItem -LiteralPath $stageSysDir -File -Recurse | Measure-Object Length -Sum).Sum
$packagedAt = Get-Date
$metadata = @"
Project: GrapheneOS Community Emulator Images Repository
Artifact status: community-built, unofficial, development-only
Target: sdk_phone64_x86_64-userdebug
Architecture: x86_64
GrapheneOS tag: $GrapheneOsTag
GrapheneOS manifest commit: $GrapheneOsManifestRevision
GrapheneOS manifest URL: https://github.com/GrapheneOS/platform_manifest/tree/$GrapheneOsTag
GrapheneOS tag signature verified: $($upstreamProof.Verified)
GrapheneOS tag verified timestamp: $($upstreamProof.VerifiedAt)
Automation commit: $AutomationRevision
Automation repository: $RepositoryUrl
Android version: $androidVersion
Android API level: $apiLevel
Android security patch: $securityPatch
Build ID: $buildId
Build fingerprint: $fingerprint
Validation timestamp: $($validationTime.ToString('o'))
Validated sysdir manifest SHA-256: $validationManifestHash
Packaged timestamp: $($packagedAt.ToString('o'))
Sysdir size bytes: $sysBytes
Official GrapheneOS release: no

This artifact was compiled from GrapheneOS sources by an independent community
project. It is not affiliated with or endorsed by the GrapheneOS project.
The SDK emulator target is for local development and app testing. It does not
provide the production security properties of a supported physical Pixel.
"@

$bundleReadme = @"
GrapheneOS Community Emulator Images Repository
========================================

Community-built GrapheneOS SDK emulator image for local development.
Unofficial. Not affiliated with or endorsed by the GrapheneOS project.

1. Create or reuse a normal x86-64 phone AVD in Android Studio.
2. Windows:
     pwsh -NoProfile -File .\install\setup-windows.ps1 -AvdName <name>
     pwsh -NoProfile -File .\install\launch-windows.ps1
3. Linux x86-64:
     chmod +x install/*.sh
     ./install/setup-linux.sh <name>
     ./install/launch-linux.sh
4. Intel macOS:
     chmod +x install/*.sh
     ./install/setup-macos.sh <name>
     ./install/launch-macos.sh

Windows x86-64 is validated. Linux x86-64 and Intel macOS are experimental.
Apple silicon and other ARM64 hosts are not supported by this x86-64 image.

See BUILD-METADATA.txt for exact source and validation provenance.
Verify sysdir files with SYSDIR-MANIFEST-SHA256.txt.
"@

$thirdParty = @"
This repository's original tooling and documentation are licensed under
GNU GPL v3.0 to the extent their contributors own them.

The bundled Android and GrapheneOS binaries contain many independently licensed
upstream components. Those components retain their respective licenses; the
repository GPL license does not replace them.

GrapheneOS is a trademark of the GrapheneOS project. This is an independent,
community-built development artifact and is not affiliated with or endorsed by
the GrapheneOS project.
"@

[IO.File]::WriteAllText((Join-Path $stage 'README.txt'), ($bundleReadme.Trim() + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $stage 'BUILD-METADATA.txt'), ($metadata.Trim() + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
[IO.File]::WriteAllText((Join-Path $stage 'THIRD-PARTY-NOTICES.txt'), ($thirdParty.Trim() + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))

Say 'writing the verified sysdir manifest'
[IO.File]::WriteAllText($manifest, (($currentManifestLines -join [Environment]::NewLine) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))

Say "creating zip: $zip"
$bsdTar = Join-Path $env:SystemRoot 'System32\tar.exe'
if (Test-Path -LiteralPath $bsdTar) {
  & $bsdTar -a -cf $zip -C $ReleaseRoot $Name
  if ($LASTEXITCODE -ne 0) { throw "tar.exe failed with exit code $LASTEXITCODE" }
} else {
  Compress-Archive -Path (Join-Path $stage '*') -DestinationPath $zip -CompressionLevel Optimal
}

$parts = @()
$zipInfo = Get-Item -LiteralPath $zip
if (-not $NoSplit -and $zipInfo.Length -gt ($PartSizeMB * 1MB)) {
  Say "splitting zip into $PartSizeMB MiB release assets"
  $parts = @(Split-ReleaseFile -Path $zip -PartBytes ($PartSizeMB * 1MB))
  $partNames = $parts | ForEach-Object { Split-Path -Leaf $_ }
  $windowsParts = $partNames -join '+'
  $unixParts = $partNames -join ' '
  $joinText = @"
Join the numbered parts in this directory before extracting.

Windows:
  cmd /c copy /b "$windowsParts" "$($zipInfo.Name)"

Linux or macOS:
  cat $unixParts > "$($zipInfo.Name)"

Verify the complete ZIP against $(Split-Path -Leaf $sha), then extract it.
"@
  [IO.File]::WriteAllText($joinInstructions, ($joinText.Trim() + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))
}

Say 'hashing release assets'
$hashTargets = @($zip) + $parts
$hashLines = foreach ($path in $hashTargets) {
  $hash = Get-FileHash -LiteralPath $path -Algorithm SHA256
  "$($hash.Hash.ToLower())  $(Split-Path -Leaf $path)"
}
[IO.File]::WriteAllText($sha, (($hashLines -join [Environment]::NewLine) + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))

[pscustomobject]@{
  Stage = $stage
  Zip = $zip
  Parts = $parts
  Sha256 = $sha
  JoinInstructions = if ($parts.Count -gt 0) { $joinInstructions } else { $null }
  GrapheneOsTag = $GrapheneOsTag
  GrapheneOsManifestRevision = $GrapheneOsManifestRevision
  AutomationRevision = $AutomationRevision
  ValidationTimestamp = $validationTime.ToString('o')
  ZipGB = [math]::Round($zipInfo.Length / 1GB, 2)
  SysDirGB = [math]::Round($sysBytes / 1GB, 2)
} | ConvertTo-Json -Compress
