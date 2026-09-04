[CmdletBinding()]
param(
  [string]$AvdName,
  [string]$BundleRoot,
  [string]$SysDir,
  [string]$SdkRoot,
  [Parameter(ValueFromRemainingArguments)]
  [string[]]$EmulatorArguments
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common-windows.ps1')

if (-not $BundleRoot) {
  $BundleRoot = Split-Path -Parent $PSScriptRoot
}
if (-not $SysDir) {
  $SysDir = Join-Path $BundleRoot 'sysdir'
}
if (-not $AvdName) {
  $configPath = Join-Path $BundleRoot '.grapheneos-community-emulator-avd'
  if (Test-Path -LiteralPath $configPath -PathType Leaf) {
    $AvdName = (Get-Content -LiteralPath $configPath -TotalCount 1).Trim()
  }
}
if (-not $AvdName) {
  $AvdName = 'GrapheneOS_Base'
}

Assert-GrapheneOsEmulatorWindowsX64
$tools = Get-GrapheneOsEmulatorSdkTools -SdkRoot $SdkRoot
Assert-GrapheneOsEmulatorSysDir -SysDir $SysDir
Assert-GrapheneOsEmulatorAvd -Emulator $tools.Emulator -AvdName $AvdName

& $tools.Emulator -avd $AvdName -sysdir $SysDir -no-snapshot -gpu auto @EmulatorArguments
exit $LASTEXITCODE
