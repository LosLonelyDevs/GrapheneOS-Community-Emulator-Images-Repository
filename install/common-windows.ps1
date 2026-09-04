$ErrorActionPreference = 'Stop'

$script:GrapheneOsEmulatorRequiredFiles = @(
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
  'source.properties'
)

function Assert-GrapheneOsEmulatorWindowsX64 {
  $architecture = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
  if ($architecture -ne [System.Runtime.InteropServices.Architecture]::X64) {
    throw "This release requires an x86-64 Windows host; detected $architecture."
  }
}

function Get-GrapheneOsEmulatorSdkTools {
  param([string]$SdkRoot)

  $candidates = @($SdkRoot, $env:ANDROID_SDK_ROOT, $env:ANDROID_HOME)
  if ($env:LOCALAPPDATA) {
    $candidates += (Join-Path $env:LOCALAPPDATA 'Android\Sdk')
  }

  foreach ($candidate in $candidates | Where-Object { $_ } | Select-Object -Unique) {
    $emulator = Join-Path $candidate 'emulator\emulator.exe'
    $adb = Join-Path $candidate 'platform-tools\adb.exe'
    if ((Test-Path -LiteralPath $emulator -PathType Leaf) -and
        (Test-Path -LiteralPath $adb -PathType Leaf)) {
      return [pscustomobject]@{
        Root = (Resolve-Path -LiteralPath $candidate).Path
        Emulator = (Resolve-Path -LiteralPath $emulator).Path
        Adb = (Resolve-Path -LiteralPath $adb).Path
      }
    }
  }

  throw 'Android SDK emulator and platform-tools not found. Pass -SdkRoot or set ANDROID_SDK_ROOT.'
}

function Assert-GrapheneOsEmulatorSysDir {
  param([Parameter(Mandatory)][string]$SysDir)

  if (-not (Test-Path -LiteralPath $SysDir -PathType Container)) {
    throw "sysdir not found: $SysDir"
  }
  foreach ($file in $script:GrapheneOsEmulatorRequiredFiles) {
    $path = Join-Path $SysDir $file
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
      throw "missing required sysdir file: $file"
    }
  }
}

function Assert-GrapheneOsEmulatorAvd {
  param(
    [Parameter(Mandatory)][string]$Emulator,
    [Parameter(Mandatory)][string]$AvdName
  )

  if ($AvdName -notmatch '^[A-Za-z0-9._-]+$') {
    throw 'AVD name may contain only letters, numbers, dot, underscore, and dash.'
  }
  $avds = @(& $Emulator -list-avds)
  if ($LASTEXITCODE -ne 0) {
    throw "emulator -list-avds failed with exit code $LASTEXITCODE"
  }
  if ($AvdName -notin $avds) {
    throw "AVD '$AvdName' not found. Create a normal x86-64 phone AVD in Android Studio."
  }
}
