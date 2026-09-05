$ErrorActionPreference = 'Stop'
$root = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).Path

function Assert-True {
  param([bool]$Condition, [string]$Message)
  if (-not $Condition) { throw $Message }
}

function Read-RepoFile([string]$RelativePath) {
  Get-Content -LiteralPath (Join-Path $root $RelativePath) -Raw
}

$gitignore = Read-RepoFile '.gitignore'
foreach ($pattern in @(
  'data/', '.agents/', '.codex/', '.claude/',
  '*.img', '*.zip', '*.key', '*.jks', '*.pem', '.env', 'local.properties'
)) {
  Assert-True ($gitignore.Contains($pattern)) ".gitignore missing: $pattern"
}

$readme = Read-RepoFile 'README.md'
Assert-True ($readme.StartsWith('# GrapheneOS Community Emulator Images Repository')) 'README title is incorrect'
foreach ($requiredText in @(
  'independent community project',
  'not affiliated with or endorsed by GrapheneOS',
  'setup-windows.ps1',
  'setup-linux.sh',
  'setup-macos.sh',
  'Build provenance and integrity validation',
  'GNU General Public License v3.0',
  'Licensing boundary',
  'does not relicense',
  'Android Studio compatibility',
  'Creating a new image',
  'docs/create-new-emulator-image.md',
  'grapheneos-emulator-home.png',
  'grapheneos-exploit-protection.png'
)) {
  Assert-True ($readme.Contains($requiredText)) "README missing: $requiredText"
}

$agents = Read-RepoFile 'AGENTS.md'
foreach ($requiredText in @(
  'Consume a prebuilt bundle',
  'Package a release',
  'Build from source',
  'Create a new image for a current or future GrapheneOS version',
  'Critical image contract',
  'Git and release safety'
)) {
  Assert-True ($agents.Contains($requiredText)) "AGENTS.md missing: $requiredText"
}

$newImageGuide = Read-RepoFile 'docs/create-new-emulator-image.md'
foreach ($requiredText in @(
  'Choose and verify the upstream tag',
  '-GrapheneOsTag',
  'GRAPHENEOS_TAG',
  'retained build state',
  'Run the repository checks',
  'Package and independently verify',
  'copy-paste commands',
  'Do not push or publish'
)) {
  Assert-True ($newImageGuide.Contains($requiredText)) "new-image guide missing: $requiredText"
}

$cloudBuildWorkflow = Read-RepoFile '.github/workflows/build-emulator.yml'
foreach ($requiredText in @(
  'workflow_dispatch:',
  'grapheneos-cloud-builder',
  'scripts/verify-upstream-tag.ps1',
  'scripts/build-grapheneos-emulator.ps1',
  '-NoConfig',
  '-NoLaunch',
  'scripts/package-grapheneos-emulator-release.ps1',
  'actions/upload-artifact@v4'
)) {
  Assert-True ($cloudBuildWorkflow.Contains($requiredText)) "cloud build workflow missing: $requiredText"
}
Assert-True ($cloudBuildWorkflow -notmatch '(?m)^\s+(push|pull_request|schedule):') 'cloud build workflow must remain manual-only'
Assert-True ($cloudBuildWorkflow -notmatch '(?i)gh\s+release|softprops/action-gh-release') 'cloud build workflow must not publish releases'

$license = Read-RepoFile 'LICENSE'
Assert-True ($license.Contains('GNU GENERAL PUBLIC LICENSE')) 'LICENSE is not GNU GPL'
Assert-True ($license.Contains('Version 3, 29 June 2007')) 'LICENSE is not GNU GPL v3.0'

foreach ($script in Get-ChildItem -LiteralPath $root -Filter '*.ps1' -File -Recurse |
  Where-Object { $_.FullName -notmatch '[\\/]data[\\/]' }) {
  $errors = $null
  $tokens = $null
  [void][Management.Automation.Language.Parser]::ParseFile(
    $script.FullName,
    [ref]$tokens,
    [ref]$errors
  )
  Assert-True ($errors.Count -eq 0) "PowerShell parse failed: $($script.FullName): $($errors -join '; ')"
}

$packager = Read-RepoFile 'scripts/package-grapheneos-emulator-release.ps1'
foreach ($requiredText in @(
  'GrapheneOS manifest commit',
  'Automation commit',
  'validated-sysdir-SHA256.txt',
  'upstream-tag-verification.json',
  'BOOT-VALIDATION.json',
  'UPSTREAM-TAG-VERIFICATION.json',
  '$upstreamProof.Tag',
  'Split-ReleaseFile',
  'source.properties',
  "sourceProperties['GrapheneOS.Tag']",
  "sourceProperties['GrapheneOS.ManifestCommit']",
  'GRAPHENEOS_EMULATOR_ROOT',
  'Join-Path $OutputRoot'
)) {
  Assert-True ($packager.Contains($requiredText)) "packager missing contract: $requiredText"
}

$publicFiles = Get-ChildItem -LiteralPath $root -File -Recurse |
  Where-Object {
    $_.FullName -notmatch '[\\/](?:\.git|\.agents|\.codex|data)[\\/]' -and
    $_.Extension -in @('.md', '.ps1', '.sh', '.yml', '.yaml', '.txt')
  }
foreach ($file in $publicFiles) {
  $content = Get-Content -LiteralPath $file.FullName -Raw
  $windowsUserRoot = 'C:' + '\Users\'
  $linuxHomeRoot = '/' + 'home/'
  $privateWindowsPath = [regex]::Escape($windowsUserRoot) + '(?!<you>|Sample User|example-user)[^\\/\s`"]+'
  $privateLinuxPath = '(?<![$A-Za-z0-9_.-])' + [regex]::Escape($linuxHomeRoot) + '(?!<user>|example-user|runner)[^/\s`"]+'
  Assert-True ($content -notmatch $privateWindowsPath) "identifying Windows path found: $($file.FullName)"
  Assert-True ($content -notmatch $privateLinuxPath) "identifying Linux path found: $($file.FullName)"
  Assert-True ($content -notmatch 'DESKTOP-[A-Z0-9]+') "identifying hostname found: $($file.FullName)"
}

'PASS repository contract tests'
