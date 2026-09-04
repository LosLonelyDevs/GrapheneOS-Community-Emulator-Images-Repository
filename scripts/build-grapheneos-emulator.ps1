<#
  GrapheneOS emulator build — Windows orchestrator (overnight, unattended)

  Default (no switch): apply WSL RAM/swap config + sparse mode, launch an
    independent build+package process, then show live progress and ETA.
  -Status   : show one progress snapshot plus recent logs and disk usage.
  -Validate : headless boot smoke test against the packaged sysdir.
  -Finalize : validate, restore WSL resources, and launch the emulator.
  -Reclaim  : delete build output and let sparse reclaim C: disk.
  -NoConfig : skip .wslconfig changes (use current WSL RAM).

  Examples:
    powershell -ExecutionPolicy Bypass -File build-grapheneos-emulator.ps1
    powershell -ExecutionPolicy Bypass -File build-grapheneos-emulator.ps1 -Status
    powershell -ExecutionPolicy Bypass -File build-grapheneos-emulator.ps1 -Validate
#>
[CmdletBinding(DefaultParameterSetName='Start')]
param(
  [Parameter(ParameterSetName='Start')][int]$MemoryGB = 26,
  [Parameter(ParameterSetName='Start')][int]$SwapGB   = 64,
  [string]$Distro = $(if ($env:GRAPHENEOS_WSL_DISTRO) { $env:GRAPHENEOS_WSL_DISTRO } else { 'Ubuntu' }),
  [string]$AndroidSdkRoot = $(if ($env:ANDROID_SDK_ROOT) { $env:ANDROID_SDK_ROOT } elseif ($env:ANDROID_HOME) { $env:ANDROID_HOME } else { Join-Path $env:LOCALAPPDATA 'Android\Sdk' }),
  [string]$OutputRoot = $(if ($env:GRAPHENEOS_EMULATOR_ROOT) { $env:GRAPHENEOS_EMULATOR_ROOT } else { 'C:\Android\grapheneos-emulator' }),
  [ValidatePattern('^[0-9]{10}$')][string]$GrapheneOsTag = $(if ($env:GRAPHENEOS_TAG) { $env:GRAPHENEOS_TAG } else { '2026062800' }),
  [Parameter(ParameterSetName='Start')][switch]$NoConfig,
  [Parameter(ParameterSetName='Status')][switch]$Status,
  [Parameter(ParameterSetName='Validate')][switch]$Validate,
  [Parameter(ParameterSetName='Reclaim')][switch]$Reclaim,
  [Parameter(ParameterSetName='Finalize')][switch]$Finalize
)
. (Join-Path $PSScriptRoot 'build-progress.ps1')

$ErrorActionPreference = 'Stop'
$Sdk = $AndroidSdkRoot
$SysDir = Join-Path $OutputRoot 'sysdir'
$LogDir = Join-Path $OutputRoot 'logs'
$StateDir = Join-Path $OutputRoot 'state'
$WslRestoreState = Join-Path $StateDir 'wslconfig-restore.json'
New-Item -ItemType Directory -Force -Path $LogDir,$StateDir | Out-Null
$Stamp  = Get-Date -Format 'yyyyMMdd-HHmmss'
function Say($m){ $l = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $m; Write-Host $l; Add-Content "$LogDir\orchestrator.log" $l }

$script:WslHome = $null
function Get-WslHome {
  if (-not $script:WslHome) {
    $resolved = ((wsl.exe -d $Distro -- sh -c 'printf %s "$HOME"') -join '').Trim()
    if ($LASTEXITCODE -ne 0 -or -not $resolved) { throw "could not resolve the WSL home directory for distro $Distro" }
    $script:WslHome = $resolved
  }
  return $script:WslHome
}

function Test-WslBuildRunning {
  wsl.exe -d $Distro -- pgrep -f '[g]os-build.sh all-logged' | Out-Null
  return ($LASTEXITCODE -eq 0)
}

function Get-WslBuildSnapshot {
  param([Nullable[bool]]$ProcessRunning = $null)

  if ($null -eq $ProcessRunning) {
    $ProcessRunning = Test-WslBuildRunning
  }

  $androidRoot = '\\wsl$\' + $Distro + (Get-WslHome).Replace('/', '\') + '\android'
  $stateDir = Join-Path $androidRoot 'state'
  $markers = @{}
  foreach ($name in 'sync.done','build.started','build.done','build.failed','package.done') {
    $path = Join-Path $stateDir $name
    if (Test-Path -LiteralPath $path -ErrorAction SilentlyContinue) {
      $markers[$name] = [IO.File]::ReadAllText($path).Trim()
    }
  }

  $buildLog = Join-Path $androidRoot 'logs\build.log'
  $lines = if (Test-Path -LiteralPath $buildLog -ErrorAction SilentlyContinue) {
    @(Get-Content -LiteralPath $buildLog -Tail 250)
  } else {
    @()
  }

  return Get-BuildProgressSnapshot -Markers $markers -LogLines $lines -ProcessRunning $ProcessRunning
}

function Show-BuildLogTail {
  wsl.exe -d $Distro -- tail -n 25 "$(Get-WslHome)/android/logs/build.log" 2>$null
}

function Show-BuildMonitor {
  param([System.Diagnostics.Process]$BuildProcess)

  Say 'monitoring every 5s; Ctrl+C exits monitor only—the hidden build continues'
  $lastPhase = ''
  while ($true) {
    $running = $null
    if ($BuildProcess) {
      $BuildProcess.Refresh()
      $running = -not $BuildProcess.HasExited
    }
    $snapshot = Get-WslBuildSnapshot -ProcessRunning $running

    if ($snapshot.Phase -ne $lastPhase) {
      if ($lastPhase) { Write-Host }
      Say "phase: $($snapshot.Phase)"
      $lastPhase = $snapshot.Phase
    }
    Write-Host ("`r" + (Format-BuildProgress -Snapshot $snapshot).PadRight(120)) -NoNewline

    if ($snapshot.Phase -eq 'Complete') {
      Write-Host
      Say "package complete: $SysDir"
      return
    }
    if ($snapshot.Phase -in 'Failed','Stopped') {
      Write-Host
      Show-BuildLogTail
      throw 'GrapheneOS build stopped or failed'
    }
    if ($BuildProcess -and $BuildProcess.HasExited) {
      Write-Host
      Show-BuildLogTail
      throw "build process exited with code $($BuildProcess.ExitCode) before package.done"
    }

    Start-Sleep -Seconds 5
  }
}

# ---- Status ----
if($Status){
  Write-Host (Format-BuildProgress -Snapshot (Get-WslBuildSnapshot))
  wsl.exe -d $Distro -- bash -lc 'echo; echo "== build.log (tail) =="; tail -n 25 ~/android/logs/build.log 2>/dev/null; echo; echo "== disk =="; df -h ~ | tail -1'
  return
}

# ---- Post-build validation, resource restoration, and launch ----
function Invoke-HeadlessValidation {
  $emu = "$Sdk\emulator\emulator.exe"
  $adb = "$Sdk\platform-tools\adb.exe"
  $serial = 'emulator-5584'
  $validationMarker = Join-Path $StateDir 'validate.done'
  $validationManifest = Join-Path $StateDir 'validated-sysdir-SHA256.txt'
  $validationReport = Join-Path $StateDir 'validation.json'
  if (-not (Test-Path $emu) -or -not (Test-Path $adb)) { throw 'Android emulator or adb is missing' }
  if (-not (Test-Path "$SysDir\system.img") -and -not (Test-Path "$SysDir\super.img")) {
    throw "No system.img/super.img in $SysDir — run build+package first."
  }

  Remove-Item -LiteralPath $validationMarker, $validationManifest, $validationReport -Force -ErrorAction SilentlyContinue
  & $adb -s $serial emu kill 2>$null | Out-Null
  $args = @('-avd','GrapheneOS_Base','-sysdir',$SysDir,'-wipe-data','-no-snapshot','-no-window','-gpu','swiftshader_indirect','-no-audio','-show-kernel','-port','5584')
  $stdoutLog = Join-Path $LogDir "emu-validate-$Stamp.out.log"
  $stderrLog = Join-Path $LogDir "emu-validate-$Stamp.err.log"
  Say "validate: launching headless emulator serial=$serial"
  $process = Start-Process $emu -ArgumentList $args -PassThru -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog
  $booted = $false
  $flavor = $null
  $release = $null
  $systemName = $null
  $packages = $null
  try {
    for ($i = 0; $i -lt 90; $i++) {
      $process.Refresh()
      if ($process.HasExited) { throw "validation emulator exited with code $($process.ExitCode)" }
      if ((Test-Path $stdoutLog) -and
          (Select-String -LiteralPath $stdoutLog -SimpleMatch 'Kernel panic - not syncing' -Quiet)) {
        throw "validation guest kernel panicked; inspect $stdoutLog"
      }
      $boot = (& $adb -s $serial shell getprop sys.boot_completed 2>$null | Select-Object -First 1)
      if ($boot -and $boot.Trim() -eq '1') { $booted = $true; break }
      Start-Sleep -Seconds 10
    }
    if (-not $booted) { throw 'validation emulator did not finish booting within 15 minutes' }

    $flavor = ((& $adb -s $serial shell getprop ro.build.flavor 2>$null) -join '').Trim()
    $release = ((& $adb -s $serial shell getprop ro.build.version.release 2>$null) -join '').Trim()
    $systemName = ((& $adb -s $serial shell getprop ro.product.system.name 2>$null) -join '').Trim()
    $packages = ((& $adb -s $serial shell pm list packages 2>$null) | Select-String 'graphene|vanadium|gmscompat') -join '; '
    $crashLog = (& $adb -s $serial logcat -b crash -d 2>$null) -join [Environment]::NewLine
    [IO.File]::WriteAllText((Join-Path $LogDir "emu-validate-$Stamp.crash.log"), $crashLog)
    Say "validate: ro.build.flavor=$flavor"
    Say "validate: ro.build.version.release=$release"
    Say "validate: ro.product.system.name=$systemName"
    Say "validate: GOS packages=$packages"
    if ($flavor -ne 'sdk_phone64_x86_64-userdebug') {
      throw "validation reported unexpected build flavor: $flavor"
    }
    if (-not $release) {
      throw 'validation reported an empty Android release'
    }
    if ($packages -notmatch 'app\.vanadium') {
      throw 'validation did not find a Vanadium package'
    }
    if ((Test-Path $stdoutLog) -and
        (Select-String -LiteralPath $stdoutLog -SimpleMatch 'Kernel panic - not syncing' -Quiet)) {
      throw "validation guest kernel panicked; inspect $stdoutLog"
    }
  } finally {
    & $adb -s $serial emu kill 2>$null | Out-Null
    if ($process -and -not $process.HasExited) {
      $process.WaitForExit(5000) | Out-Null
      if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue }
    }
  }

  Say 'validate: hashing the exact boot-tested sysdir'
  $manifestLines = Get-ChildItem -LiteralPath $SysDir -File -Recurse |
    Sort-Object FullName |
    ForEach-Object {
      $hash = Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256
      $relative = $_.FullName.Substring($SysDir.Length).TrimStart('\', '/').Replace('\', '/')
      "$($hash.Hash.ToLower())  sysdir/$relative"
    }
  [IO.File]::WriteAllText(
    $validationManifest,
    (($manifestLines -join [Environment]::NewLine) + [Environment]::NewLine),
    [Text.UTF8Encoding]::new($false)
  )
  $validatedAt = Get-Date
  $manifestHash = (Get-FileHash -LiteralPath $validationManifest -Algorithm SHA256).Hash.ToLower()
  [pscustomobject]@{
    ValidatedAt = $validatedAt.ToString('o')
    Serial = $serial
    BootCompleted = 1
    BuildFlavor = $flavor
    AndroidRelease = $release
    ProductSystemName = $systemName
    GrapheneOsPackages = $packages
    SysDirManifest = (Split-Path -Leaf $validationManifest)
    SysDirManifestSha256 = $manifestHash
    EmulatorStdout = (Split-Path -Leaf $stdoutLog)
    EmulatorStderr = (Split-Path -Leaf $stderrLog)
  } | ConvertTo-Json -Depth 3 |
    Set-Content -LiteralPath $validationReport -Encoding utf8
  [IO.File]::WriteAllText($validationMarker, $validatedAt.ToString('o'))
  Say "validate: PASS; sysdir manifest sha256=$manifestHash"
}

function Save-WslConfigRestoreState {
  param([string]$ConfigPath, [bool]$HadOriginal, [string]$BackupPath)
  $state = [ordered]@{ ConfigPath=$ConfigPath; HadOriginal=$HadOriginal; BackupPath=$BackupPath; Created=(Get-Date).ToString('o') }
  [IO.File]::WriteAllText($WslRestoreState, ($state | ConvertTo-Json -Compress))
}

function Restore-WslConfig {
  $state = $null
  if (Test-Path $WslRestoreState) {
    $state = Get-Content -Raw $WslRestoreState | ConvertFrom-Json
  } else {
    $latest = Get-ChildItem "$env:USERPROFILE\.wslconfig.bak-*" -ErrorAction SilentlyContinue | Sort-Object Name -Descending | Select-Object -First 1
    if ($latest) { $state = [pscustomobject]@{ ConfigPath="$env:USERPROFILE\.wslconfig"; HadOriginal=$true; BackupPath=$latest.FullName } }
  }
  if (-not $state) { Say 'restore: no WSL config restore state found'; return }

  if ($state.HadOriginal -and (Test-Path $state.BackupPath)) {
    Copy-Item $state.BackupPath $state.ConfigPath -Force
    Say "restore: .wslconfig restored from $($state.BackupPath)"
  } elseif (-not $state.HadOriginal -and (Test-Path $state.ConfigPath)) {
    Remove-Item $state.ConfigPath -Force
    Say 'restore: generated .wslconfig removed'
  } else {
    throw 'restore: original .wslconfig backup is missing'
  }
  Remove-Item $WslRestoreState -Force -ErrorAction SilentlyContinue
  wsl.exe --shutdown
  Say 'restore: WSL shut down; build RAM/CPU/swap allocation released'
}

function Start-GrapheneOsEmulator {
  $emu = "$Sdk\emulator\emulator.exe"
  $stdoutLog = Join-Path $LogDir "emu-gui-$Stamp.out.log"
  $stderrLog = Join-Path $LogDir "emu-gui-$Stamp.err.log"
  $args = @('-avd','GrapheneOS_Base','-sysdir',$SysDir,'-no-snapshot','-gpu','auto')
  $process = Start-Process $emu -ArgumentList $args -PassThru -RedirectStandardOutput $stdoutLog -RedirectStandardError $stderrLog
  [IO.File]::WriteAllText((Join-Path $StateDir 'gui.pid'), [string]$process.Id)
  Say "launch: visible GrapheneOS emulator pid=$($process.Id)"
}

function Invoke-PostBuild {
  param([switch]$RestoreResources)
  $validated = $false
  try {
    Invoke-HeadlessValidation
    $validated = $true
  } finally {
    if ($RestoreResources) { Restore-WslConfig }
  }
  if ($validated) {
    Start-GrapheneOsEmulator
    [IO.File]::WriteAllText((Join-Path $StateDir 'finalize.done'), (Get-Date).ToString('o'))
    Say 'post-build automation: COMPLETE'
  }
}

if ($Validate) { Invoke-HeadlessValidation; return }
if ($Finalize) { Invoke-PostBuild -RestoreResources; return }

# ---- Reclaim ----
if($Reclaim){
  Say "reclaim: deleting ~/android/grapheneos/out and shutting down WSL"
  wsl.exe -d $Distro -- bash -lc 'rm -rf ~/android/grapheneos/out; echo "out/ removed"'
  wsl.exe --shutdown
  Say "reclaim: sparse mode will release freed blocks. For full compaction: diskpart > select vdisk file=<ext4.vhdx> > attach vdisk readonly > compact vdisk > detach vdisk"
  return
}

# ---- Default: Start and monitor overnight build ----
if (Test-WslBuildRunning) {
  Say 'a GrapheneOS build is already running; refusing to launch a duplicate'
  Write-Host (Format-BuildProgress -Snapshot (Get-WslBuildSnapshot -ProcessRunning $true))
  Say 'use -Status for later snapshots'
  return
}

$localBuildScript = (Resolve-Path (Join-Path $PSScriptRoot 'gos-build.sh')).Path
$wslBuildScript = ConvertTo-WslPath $localBuildScript
if (-not $wslBuildScript) { throw 'could not translate gos-build.sh path for WSL' }
$wslExportDir = ConvertTo-WslPath $SysDir
if (-not $wslExportDir) { throw 'could not translate the sysdir output path for WSL' }
wsl.exe -d $Distro -- install -D -m 0755 -- $wslBuildScript "$(Get-WslHome)/android/gos-build.sh"
if ($LASTEXITCODE -ne 0) { throw 'could not deploy gos-build.sh into WSL' }
Say 'deployed current gos-build.sh'

if(-not $NoConfig){
  $cfg = "$env:USERPROFILE\.wslconfig"
  $hadOriginalConfig = Test-Path $cfg
  $backupPath = ''
  if($hadOriginalConfig){
    $backupPath = "$cfg.bak-$Stamp"
    Copy-Item $cfg $backupPath -Force
    Say "backed up .wslconfig -> $backupPath"
  }
  Save-WslConfigRestoreState -ConfigPath $cfg -HadOriginal $hadOriginalConfig -BackupPath $backupPath
  $body = "[wsl2]`nnestedVirtualization=false`nlocalhostForwarding=true`nmemory=${MemoryGB}GB`nprocessors=24`nswap=${SwapGB}GB`n"
  [IO.File]::WriteAllText($cfg, $body)
  Say "wrote .wslconfig (memory=${MemoryGB}GB, swap=${SwapGB}GB)"
  wsl.exe --shutdown; Say "wsl --shutdown"; Start-Sleep -Seconds 6
  try { wsl.exe --manage $Distro --set-sparse true | Out-Null; Say "sparse mode enabled (reversible disk)" }
  catch { Say "warn: could not enable sparse mode ($_)" }
}
Say "launching independent hidden WSL build process for GrapheneOS tag $GrapheneOsTag"
$buildProcess = Start-Process `
  -WindowStyle Hidden `
  -FilePath 'wsl.exe' `
  -ArgumentList @('-d', $Distro, '--', 'env', "GRAPHENEOS_TAG=$GrapheneOsTag", "EXPORT_DIR=$wslExportDir", 'bash', "$(Get-WslHome)/android/gos-build.sh", 'all-logged') `
  -PassThru
Say "started build host pid=$($buildProcess.Id); sysdir target: $SysDir"
Show-BuildMonitor -BuildProcess $buildProcess
Invoke-PostBuild -RestoreResources:(-not $NoConfig)
