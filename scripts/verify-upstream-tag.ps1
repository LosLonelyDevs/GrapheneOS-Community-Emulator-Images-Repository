[CmdletBinding()]
param(
  [Parameter(Mandatory)]
  [ValidatePattern('^[0-9]{10}$')]
  [string]$Tag,
  [string]$OutputRoot = $(if ($env:GRAPHENEOS_EMULATOR_ROOT) { $env:GRAPHENEOS_EMULATOR_ROOT } else { 'C:\Android\grapheneos-emulator' }),
  [string]$OutputPath
)

$ErrorActionPreference = 'Stop'
$OutputPath = if ($OutputPath) { $OutputPath } else { Join-Path $OutputRoot 'state\upstream-tag-verification.json' }
$tempRoot = Join-Path ([IO.Path]::GetTempPath()) ('grapheneos-tag-' + [guid]::NewGuid().ToString('N'))
$allowedSigners = Join-Path $tempRoot 'allowed_signers'

try {
  New-Item -ItemType Directory -Path $tempRoot | Out-Null
  Invoke-WebRequest -UseBasicParsing -Uri 'https://grapheneos.org/allowed_signers' -OutFile $allowedSigners
  & git -C $tempRoot init --quiet
  if ($LASTEXITCODE -ne 0) { throw 'git init failed' }
  & git -C $tempRoot remote add origin 'https://github.com/GrapheneOS/platform_manifest.git'
  if ($LASTEXITCODE -ne 0) { throw 'git remote add failed' }
  & git -C $tempRoot fetch --quiet --depth=1 origin "refs/tags/${Tag}:refs/tags/${Tag}"
  if ($LASTEXITCODE -ne 0) { throw "unable to fetch GrapheneOS tag $Tag" }
  & git -C $tempRoot config gpg.ssh.allowedSignersFile $allowedSigners
  if ($LASTEXITCODE -ne 0) { throw 'unable to configure GrapheneOS allowed signers' }

  $previousErrorPreference = $ErrorActionPreference
  $ErrorActionPreference = 'Continue'
  $verificationOutput = @(& git -C $tempRoot verify-tag $Tag 2>&1 |
    ForEach-Object { $_.ToString() })
  $verificationExitCode = $LASTEXITCODE
  $ErrorActionPreference = $previousErrorPreference
  if ($verificationExitCode -ne 0) {
    throw "GrapheneOS tag signature verification failed: $($verificationOutput -join '; ')"
  }
  $commit = (& git -C $tempRoot rev-list -n 1 $Tag).Trim()
  if ($LASTEXITCODE -ne 0 -or $commit -notmatch '^[0-9a-f]{40}$') {
    throw 'unable to resolve the verified GrapheneOS manifest commit'
  }

  $report = [pscustomobject]@{
    Verified = $true
    Tag = $Tag
    ManifestCommit = $commit
    VerifiedAt = (Get-Date).ToString('o')
    AllowedSignersUrl = 'https://grapheneos.org/allowed_signers'
    ManifestRepository = 'https://github.com/GrapheneOS/platform_manifest.git'
    VerificationCommand = "git verify-tag $Tag"
    GitOutput = $verificationOutput
  }
  New-Item -ItemType Directory -Force -Path (Split-Path -Parent $OutputPath) | Out-Null
  $report | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath $OutputPath -Encoding utf8
  $report | ConvertTo-Json -Depth 3
} finally {
  if (Test-Path -LiteralPath $tempRoot) {
    Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
  }
}
