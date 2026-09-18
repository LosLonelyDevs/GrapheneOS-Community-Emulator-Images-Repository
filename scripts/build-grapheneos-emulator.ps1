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
  [Parameter(ParameterSetName='Start')][int]$MinFreeGB = 300,
  [Parameter(ParameterSetName='Start')][int]$MinFreeResumeGB = 150,
  [Parameter(ParameterSetName='Start')][switch]$SkipSpaceCheck,
  [Parameter(ParameterSetName='Start')][switch]$NoConfig,
  [Parameter(ParameterSetName='Start')][switch]$NoLaunch,
  [Parameter(ParameterSetName='Status')][switch]$Status,
  [Parameter(ParameterSetName='Validate')][switch]$Validate,
  [Parameter(ParameterSetName='Reclaim')][switch]$Reclaim,
  [Parameter(ParameterSetName='Finalize')][switch]$Finalize,
  [Parameter(ParameterSetName='Restore')][switch]$Restore,
  [Parameter(ParameterSetName='Restore')][switch]$Force,
  [Parameter(ParameterSetName='Restore')][switch]$Compact,
  [Parameter(ParameterSetName='Restore')][switch]$DisableSparse
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
  param(
    [string]$ConfigPath,
    [bool]$HadOriginal,
    [string]$BackupPath,
    $StandbyTimeoutAcBefore = $null,
    [bool]$SparseEnabledByBuild = $false
  )
  $state = [ordered]@{
    ConfigPath             = $ConfigPath
    HadOriginal            = $HadOriginal
    BackupPath             = $BackupPath
    StandbyTimeoutAcBefore = $StandbyTimeoutAcBefore
    SparseEnabledByBuild   = $SparseEnabledByBuild
    Created                = (Get-Date).ToString('o')
  }
  [IO.File]::WriteAllText($WslRestoreState, ($state | ConvertTo-Json -Compress))
}

function Get-WslConfigRestoreState {
  if (-not (Test-Path $WslRestoreState)) { return $null }
  try { return (Get-Content -Raw $WslRestoreState | ConvertFrom-Json) } catch { return $null }
}

function Merge-WslConfigRestoreState {
  # Adds fields to an existing restore state without inventing one, so a
  # -NoConfig resume never claims ownership of a .wslconfig it did not write.
  param([hashtable]$Fields)
  $state = Get-WslConfigRestoreState
  if (-not $state) { return $false }
  foreach ($name in $Fields.Keys) {
    $state | Add-Member -NotePropertyName $name -NotePropertyValue $Fields[$name] -Force
  }
  [IO.File]::WriteAllText($WslRestoreState, ($state | ConvertTo-Json -Compress))
  return $true
}

# ---- host resource accounting (no hardcoded volumes, profiles, or install paths) ----

function Get-WslDistroImagePath {
  # Resolve the distro's backing virtual disk from the WSL registry rather than
  # assuming any particular install location.
  $lxss = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Lxss'
  if (-not (Test-Path $lxss)) { return $null }
  foreach ($key in (Get-ChildItem $lxss -ErrorAction SilentlyContinue)) {
    $props = Get-ItemProperty -LiteralPath $key.PSPath -ErrorAction SilentlyContinue
    if (-not $props -or $props.DistributionName -ne $Distro) { continue }
    $base = ($props.BasePath -replace '^\\\\\?\\', '')
    if (-not $base -or -not (Test-Path -LiteralPath $base)) { continue }
    $image = Get-ChildItem -LiteralPath $base -Filter '*.vhdx' -ErrorAction SilentlyContinue |
      Sort-Object Length -Descending | Select-Object -First 1
    if ($image) { return $image.FullName }
  }
  return $null
}

function Get-WslImageSizeGB {
  $image = Get-WslDistroImagePath
  if (-not $image -or -not (Test-Path -LiteralPath $image)) { return $null }
  return [math]::Round((Get-Item -LiteralPath $image).Length / 1GB, 1)
}

function Get-HostFreeGB {
  param([string]$PathOnVolume)
  $qualifier = $null
  foreach ($candidate in @($PathOnVolume, $OutputRoot, $env:USERPROFILE)) {
    if (-not $candidate) { continue }
    try { $qualifier = Split-Path -Qualifier $candidate -ErrorAction Stop } catch { $qualifier = $null }
    if ($qualifier) { break }
  }
  if (-not $qualifier) { return $null }
  $drive = Get-PSDrive -Name $qualifier.TrimEnd(':') -ErrorAction SilentlyContinue
  if (-not $drive) { return $null }
  return [math]::Round($drive.Free / 1GB, 1)
}

function Get-WslDfGB {
  # Returns @{ UsedGB; FreeGB } for the filesystem holding the WSL home.
  $lines = @(wsl.exe -d $Distro -- sh -c 'df -Pk "$HOME"')
  if ($LASTEXITCODE -ne 0 -or $lines.Count -lt 2) { return $null }
  $fields = @(($lines[-1] -split '\s+') | Where-Object { $_ })
  if ($fields.Count -lt 4) { return $null }
  return @{
    UsedGB = [math]::Round(([double]$fields[2]) / 1MB, 1)
    FreeGB = [math]::Round(([double]$fields[3]) / 1MB, 1)
  }
}

function Get-WslFreeGB {
  $df = Get-WslDfGB
  if (-not $df) { return $null }
  return $df.FreeGB
}

function Test-WslSyncComplete {
  wsl.exe -d $Distro -- test -f "$(Get-WslHome)/android/state/sync.done" *> $null
  return ($LASTEXITCODE -eq 0)
}

function Assert-FreeSpaceForBuild {
  if ($SkipSpaceCheck) { Say 'space: precheck skipped by request (-SkipSpaceCheck)'; return }
  $resuming = Test-WslSyncComplete
  $required = if ($resuming) { $MinFreeResumeGB } else { $MinFreeGB }
  $stage    = if ($resuming) { 'resume (source already synced)' } else { 'full sync + build' }
  $wslFree  = Get-WslFreeGB
  $image    = Get-WslDistroImagePath
  $hostFree = Get-HostFreeGB -PathOnVolume $image

  Say ("space: {0} needs {1} GB free" -f $stage, $required)
  Say ("space: WSL filesystem free {0}; host volume free {1}" -f
    $(if ($null -ne $wslFree) { "$wslFree GB" } else { 'unknown' }),
    $(if ($null -ne $hostFree) { "$hostFree GB" } else { 'unknown' }))

  $problems = @()
  if ($null -eq $wslFree)  { Say 'space: warn: could not read WSL free space' }
  elseif ($wslFree -lt $required) { $problems += "the WSL filesystem has $wslFree GB free but needs $required GB" }
  if ($null -eq $hostFree) { Say 'space: warn: could not read host free space' }
  elseif ($hostFree -lt $required) { $problems += "the host volume backing the WSL disk has $hostFree GB free but needs $required GB" }

  if ($problems.Count) {
    throw ("insufficient disk space for a GrapheneOS build: " + ($problems -join '; ') +
      ". Free space and retry, lower the bar with -MinFreeGB/-MinFreeResumeGB, or bypass with -SkipSpaceCheck.")
  }
  Say 'space: precheck PASS'
}

# ---- host power state (the build dies if the machine sleeps) ----

function Get-HostStandbyTimeoutAc {
  $lines = @(& powercfg /q SCHEME_CURRENT SUB_SLEEP STANDBYIDLE 2>$null)
  $hit = $lines | Select-String -Pattern 'Current AC Power Setting Index:\s*(0x[0-9a-fA-F]+)' | Select-Object -First 1
  if (-not $hit) { return $null }
  return [Convert]::ToInt32($hit.Matches[0].Groups[1].Value, 16)
}

function Disable-HostSleep {
  $before = Get-HostStandbyTimeoutAc
  if ($null -eq $before) { Say 'power: warn: could not read the AC sleep timeout; leaving it alone'; return $null }
  if ($before -eq 0) { Say 'power: AC sleep-on-idle already disabled'; return $before }
  & powercfg /change standby-timeout-ac 0 | Out-Null
  Say "power: AC sleep-on-idle disabled for the build (was $([int][math]::Round($before / 60)) min)"
  return $before
}

function Restore-HostSleep {
  param($PreviousSeconds)
  if ($null -eq $PreviousSeconds) { Say 'power: no prior AC sleep timeout recorded; leaving it as is'; return }
  $minutes = [int][math]::Round(([double]$PreviousSeconds) / 60)
  & powercfg /change standby-timeout-ac $minutes | Out-Null
  Say "power: AC sleep-on-idle restored to $minutes min"
}

# ---- full host restore ----

function Test-ScheduledBuildTask {
  param([string]$Name)
  & schtasks /query /tn $Name *> $null
  return ($LASTEXITCODE -eq 0)
}

function Compress-WslDiskImage {
  param([string]$ImagePath)
  if (-not $ImagePath) { Say 'restore: no WSL disk image found; skipping compaction'; return }
  $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
  $elevated = ([Security.Principal.WindowsPrincipal]$identity).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $elevated) {
    Say 'restore: image compaction needs an elevated session; skipping'
    Say "restore: to compact manually, run diskpart as administrator: select vdisk file=`"$ImagePath`" / attach vdisk readonly / compact vdisk / detach vdisk"
    return
  }
  $script = @("select vdisk file=`"$ImagePath`"", 'attach vdisk readonly', 'compact vdisk', 'detach vdisk', 'exit') -join "`r`n"
  $scriptPath = Join-Path ([IO.Path]::GetTempPath()) ("wsl-compact-$([guid]::NewGuid().ToString('N')).txt")
  try {
    [IO.File]::WriteAllText($scriptPath, $script)
    & diskpart /s $scriptPath | Out-Null
    Say 'restore: WSL disk image compacted'
  } catch {
    Say "restore: warn: compaction failed ($_)"
  } finally {
    Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
  }
}

function Invoke-HostRestore {
  param([switch]$Apply, [switch]$CompactImage, [switch]$TurnOffSparse)

  if (Test-WslBuildRunning) {
    throw 'a GrapheneOS build is still running; let it finish or stop it before restoring the host'
  }

  $state       = Get-WslConfigRestoreState
  $wslHomePath = Get-WslHome
  $buildRoot   = "$wslHomePath/android"
  $image       = Get-WslDistroImagePath
  $imageBefore = Get-WslImageSizeGB
  $hostBefore  = Get-HostFreeGB -PathOnVolume $image
  $taskName    = "GrapheneOS-Build-$GrapheneOsTag"
  $taskPresent = Test-ScheduledBuildTask -Name $taskName

  $plan = @()
  if ($state -and $state.HadOriginal) { $plan += "restore .wslconfig from the recorded backup" }
  elseif ($state) { $plan += 'remove the generated .wslconfig' }
  else { $plan += 'no .wslconfig restore state found; skip .wslconfig restore' }
  if ($state -and $null -ne $state.StandbyTimeoutAcBefore) {
    $plan += "restore AC sleep-on-idle to $([int][math]::Round(([double]$state.StandbyTimeoutAcBefore) / 60)) min"
  }
  $plan += "delete the WSL build tree at $buildRoot (source, out/, markers, logs)"
  if ($taskPresent) { $plan += "delete scheduled task $taskName" }
  if ($TurnOffSparse) { $plan += 'disable sparse mode on the WSL disk' }
  if ($CompactImage) { $plan += 'compact the WSL disk image' }
  $plan += 'shut WSL down so the RAM/CPU allocation and freed blocks are released'

  Say ("restore: WSL disk image {0}" -f $(if ($image) { $image } else { '<not found>' }))
  Say ("restore: image size before {0}; host volume free before {1}" -f
    $(if ($null -ne $imageBefore) { "$imageBefore GB" } else { 'unknown' }),
    $(if ($null -ne $hostBefore) { "$hostBefore GB" } else { 'unknown' }))
  foreach ($step in $plan) { Say "restore: plan - $step" }

  if (-not $Apply) {
    Say 'restore: DRY RUN only; nothing was changed. Re-run with -Force to apply.'
    return
  }

  Restore-WslConfig
  if ($state -and $null -ne $state.StandbyTimeoutAcBefore) { Restore-HostSleep -PreviousSeconds $state.StandbyTimeoutAcBefore }

  Say "restore: deleting the WSL build tree at $buildRoot"
  wsl.exe -d $Distro -- rm -rf "$buildRoot"
  if ($LASTEXITCODE -ne 0) { Say 'restore: warn: could not fully delete the WSL build tree' }

  if ($taskPresent) {
    & schtasks /delete /tn $taskName /f *> $null
    Say "restore: scheduled task $taskName deleted"
  }

  if ($TurnOffSparse) {
    try { wsl.exe --manage $Distro --set-sparse false | Out-Null; Say 'restore: sparse mode disabled' }
    catch { Say "restore: warn: could not disable sparse mode ($_)" }
  }

  wsl.exe --shutdown
  Say 'restore: WSL shut down'

  if ($CompactImage) { Compress-WslDiskImage -ImagePath $image }

  $imageAfter = Get-WslImageSizeGB
  $hostAfter  = Get-HostFreeGB -PathOnVolume $image
  Say ("restore: image size after {0}; host volume free after {1}" -f
    $(if ($null -ne $imageAfter) { "$imageAfter GB" } else { 'unknown' }),
    $(if ($null -ne $hostAfter) { "$hostAfter GB" } else { 'unknown' }))
  if ($null -ne $hostBefore -and $null -ne $hostAfter) {
    Say ("restore: host volume reclaimed {0} GB" -f [math]::Round($hostAfter - $hostBefore, 1))
  }
  # A shrinking image is not proof the space came back. Compare what the image
  # still occupies on the host against what the filesystem inside it actually
  # uses: the difference is allocated-but-unused blocks sparse has not released.
  $df = Get-WslDfGB
  if ($null -ne $imageAfter -and $df) {
    $stranded = [math]::Round($imageAfter - $df.UsedGB, 1)
    Say ("restore: disk image {0} GB holds {1} GB of data; {2} GB still allocated to the image" -f
      $imageAfter, $df.UsedGB, $stranded)
    if ($stranded -gt 20) {
      Say 'restore: INCOMPLETE - the host has not got that space back yet. Sparse mode releases blocks lazily.'
      if (-not $CompactImage) {
        Say 'restore: re-run with -Compact from an ELEVATED session to force it:'
        Say ("restore:   .\scripts\build-grapheneos-emulator.ps1 -Restore -Force -Compact -GrapheneOsTag {0} -OutputRoot {1}" -f $GrapheneOsTag, $OutputRoot)
      } else {
        Say 'restore: compaction ran but space is still held; check that no process has the disk image open.'
      }
    } else {
      Say 'restore: host disk fully returned'
    }
  }
  Say 'restore: COMPLETE'
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
  param([switch]$RestoreResources, [switch]$SkipLaunch)
  $validated = $false
  $restoreState = Get-WslConfigRestoreState
  try {
    Invoke-HeadlessValidation
    $validated = $true
  } finally {
    if ($RestoreResources) {
      Restore-WslConfig
      if ($restoreState -and $null -ne $restoreState.StandbyTimeoutAcBefore) {
        Restore-HostSleep -PreviousSeconds $restoreState.StandbyTimeoutAcBefore
      }
    }
  }
  if ($validated) {
    if ($SkipLaunch) {
      Say 'post-build automation: visible emulator launch skipped'
    } else {
      Start-GrapheneOsEmulator
    }
    [IO.File]::WriteAllText((Join-Path $StateDir 'finalize.done'), (Get-Date).ToString('o'))
    Say 'post-build automation: COMPLETE'
  }
}

if ($Validate) { Invoke-HeadlessValidation; return }
if ($Finalize) { Invoke-PostBuild -RestoreResources; return }

# ---- Restore: return the host to its pre-build state ----
if ($Restore) {
  Invoke-HostRestore -Apply:$Force -CompactImage:$Compact -TurnOffSparse:$DisableSparse
  return
}

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

Assert-FreeSpaceForBuild
$standbyBefore = Disable-HostSleep

if(-not $NoConfig){
  $cfg = "$env:USERPROFILE\.wslconfig"
  $hadOriginalConfig = Test-Path $cfg
  $backupPath = ''
  if($hadOriginalConfig){
    $backupPath = "$cfg.bak-$Stamp"
    Copy-Item $cfg $backupPath -Force
    Say "backed up .wslconfig -> $backupPath"
  }
  Save-WslConfigRestoreState -ConfigPath $cfg -HadOriginal $hadOriginalConfig -BackupPath $backupPath -StandbyTimeoutAcBefore $standbyBefore
  $body = "[wsl2]`nnestedVirtualization=false`nlocalhostForwarding=true`nmemory=${MemoryGB}GB`nprocessors=24`nswap=${SwapGB}GB`n"
  [IO.File]::WriteAllText($cfg, $body)
  Say "wrote .wslconfig (memory=${MemoryGB}GB, swap=${SwapGB}GB)"
  wsl.exe --shutdown; Say "wsl --shutdown"; Start-Sleep -Seconds 6
  try {
    wsl.exe --manage $Distro --set-sparse true | Out-Null
    Say "sparse mode enabled (reversible disk)"
    Merge-WslConfigRestoreState -Fields @{ SparseEnabledByBuild = $true } | Out-Null
  }
  catch { Say "warn: could not enable sparse mode ($_)" }
} else {
  if (-not (Merge-WslConfigRestoreState -Fields @{ StandbyTimeoutAcBefore = $standbyBefore })) {
    Say 'power: no restore state exists to record the prior sleep timeout into; restore it by hand'
  }
}
Say "launching independent hidden WSL build process for GrapheneOS tag $GrapheneOsTag"
$buildProcess = Start-Process `
  -WindowStyle Hidden `
  -FilePath 'wsl.exe' `
  -ArgumentList @('-d', $Distro, '--', 'env', "GRAPHENEOS_TAG=$GrapheneOsTag", "EXPORT_DIR=$wslExportDir", 'bash', "$(Get-WslHome)/android/gos-build.sh", 'all-logged') `
  -PassThru
Say "started build host pid=$($buildProcess.Id); sysdir target: $SysDir"
Show-BuildMonitor -BuildProcess $buildProcess
Invoke-PostBuild -RestoreResources:(-not $NoConfig) -SkipLaunch:$NoLaunch
