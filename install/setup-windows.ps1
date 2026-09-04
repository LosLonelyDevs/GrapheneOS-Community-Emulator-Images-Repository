[CmdletBinding()]
param(
  [string]$AvdName = 'GrapheneOS_Base',
  [string]$BundleRoot,
  [string]$SysDir,
  [string]$SdkRoot
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common-windows.ps1')

if (-not $BundleRoot) {
  $BundleRoot = Split-Path -Parent $PSScriptRoot
}
if (-not $SysDir) {
  $SysDir = Join-Path $BundleRoot 'sysdir'
}

Assert-GrapheneOsEmulatorWindowsX64
$tools = Get-GrapheneOsEmulatorSdkTools -SdkRoot $SdkRoot
Assert-GrapheneOsEmulatorSysDir -SysDir $SysDir
Assert-GrapheneOsEmulatorAvd -Emulator $tools.Emulator -AvdName $AvdName

$configPath = Join-Path $BundleRoot '.grapheneos-community-emulator-avd'
[IO.File]::WriteAllText($configPath, ($AvdName + [Environment]::NewLine), [Text.UTF8Encoding]::new($false))

'setup complete'
"  bundle: $((Resolve-Path -LiteralPath $BundleRoot).Path)"
"  sysdir: $((Resolve-Path -LiteralPath $SysDir).Path)"
"  sdk: $($tools.Root)"
"  avd: $AvdName"
