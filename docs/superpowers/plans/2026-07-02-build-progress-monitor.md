# Build Progress Monitor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Launch the GrapheneOS build in an independent hidden WSL process while the invoking PowerShell terminal displays live phase, percentage, action counts, elapsed time, and approximate time remaining.

**Architecture:** A pure PowerShell parser converts structured Ninja status lines and phase-marker files into display snapshots. `gos-build.sh` emits deterministic Ninja progress and explicit start/failure markers. The Windows orchestrator launches `wsl.exe` with the build in its foreground, then independently monitors files through `\\wsl.localhost\Ubuntu` so closing the monitor cannot kill the build.

**Tech Stack:** PowerShell 7/Windows PowerShell 5-compatible functions, Bash, Android Soong/Ninja, WSL2, dependency-free test scripts.

**Repository note:** this repository folder has no `.git` directory. Do not initialize one without user approval. Commit steps are replaced with explicit changed-file checkpoints.

---

## File Structure

- Create `scripts/build-progress.ps1`: pure parsing, phase selection, ETA calculation, and terminal formatting.
- Create `tests/build-progress.tests.ps1`: dependency-free unit tests for PowerShell progress logic.
- Create `tests/gos-build-progress.test.sh`: isolated fake-build tests for Bash markers, Ninja status, and logged mode.
- Create `tests/orchestrator-contract.tests.ps1`: safe contract checks for independent launch and monitor wiring without starting the real Android build.
- Modify `scripts/gos-build.sh`: deterministic Ninja output, marker lifecycle, testable export path, and `all-logged` mode.
- Modify `scripts/build-grapheneos-emulator.ps1`: deploy current Bash script, launch persistent hidden WSL process, implement live monitor, and improve `-Status`.
- Modify `data/GRAPHENEOS_EMULATOR_PLAN.md` (local-only plan doc): document live progress, approximate ETA, `Ctrl+C` behavior, and reliable launch mechanism.

### Task 1: Pure PowerShell progress parser

**Files:**
- Create: `tests/build-progress.tests.ps1`
- Create: `scripts/build-progress.ps1`

- [ ] **Step 1: Write the failing parser tests**

Create `tests/build-progress.tests.ps1` with a tiny assertion harness. If the production helper does not exist yet, define null-returning test stubs so the first run fails on behavior rather than a missing-file error.

```powershell
$ErrorActionPreference = 'Stop'
$helper = Join-Path $PSScriptRoot '..\scripts\build-progress.ps1'
if (Test-Path $helper) {
  . $helper
} else {
  function ConvertFrom-NinjaProgress { param([string[]]$LogLines) $null }
  function Get-BuildProgressSnapshot {
    param([hashtable]$Markers, [string[]]$LogLines, [Nullable[bool]]$ProcessRunning, [DateTimeOffset]$Now)
    $null
  }
  function Format-BuildProgress { param($Snapshot) '' }
}

function Assert-Equal($Expected, $Actual, [string]$Message) {
  if ($Expected -ne $Actual) {
    throw "$Message`nExpected: $Expected`nActual:   $Actual"
  }
}

$parsed = ConvertFrom-NinjaProgress -LogLines @(
  'unrelated compiler output',
  '[ 42% 12345/29100] target C++: libfoo <= foo.cpp'
)
Assert-Equal 42 $parsed.Percent 'parses Ninja percentage'
Assert-Equal 12345 $parsed.Finished 'parses finished actions'
Assert-Equal 29100 $parsed.Total 'parses total actions'

$started = [DateTimeOffset]::FromUnixTimeSeconds(1000)
$now = [DateTimeOffset]::FromUnixTimeSeconds(4600)
$snapshot = Get-BuildProgressSnapshot `
  -Markers @{ 'sync.done' = ''; 'build.started' = '1000' } `
  -LogLines @('[ 25% 25/100] compile') `
  -Now $now
Assert-Equal 'Building' $snapshot.Phase 'selects build phase'
Assert-Equal ([TimeSpan]::FromHours(1)) $snapshot.Elapsed 'calculates elapsed time'
Assert-Equal ([TimeSpan]::FromHours(3)) $snapshot.Remaining 'calculates proportional ETA'

$early = Get-BuildProgressSnapshot `
  -Markers @{ 'build.started' = '1000' } `
  -LogLines @('[ 1% 1/100] compile') `
  -Now ([DateTimeOffset]::FromUnixTimeSeconds(1030))
Assert-Equal $null $early.Remaining 'suppresses unstable early ETA'

Assert-Equal 'Complete' (Get-BuildProgressSnapshot -Markers @{ 'package.done' = '' } -LogLines @()).Phase 'package marker wins'
Assert-Equal 'Failed' (Get-BuildProgressSnapshot -Markers @{ 'build.failed' = '4600' } -LogLines @()).Phase 'failure marker wins'
Assert-Equal 'Stopped' (Get-BuildProgressSnapshot -Markers @{ 'build.started' = '1000' } -LogLines @() -ProcessRunning $false).Phase 'stale build is stopped'

$line = Format-BuildProgress -Snapshot $snapshot
if ($line -notmatch 'BUILD' -or $line -notmatch '25%' -or $line -notmatch 'ETA ~03:00:00') {
  throw "formatted line missing required fields: $line"
}

Write-Output 'PASS build-progress tests'
```

- [ ] **Step 2: Run the tests and verify RED**

Run:

```powershell
pwsh -NoProfile -File .\tests\build-progress.tests.ps1
```

Expected: nonzero exit with `parses Ninja percentage`, because the test stub returns `$null`.

- [ ] **Step 3: Implement the minimal parser**

Create `scripts/build-progress.ps1` with these public functions and no side effects:

```powershell
function ConvertFrom-NinjaProgress {
  [CmdletBinding()]
  param([string[]]$LogLines)

  for ($i = $LogLines.Count - 1; $i -ge 0; $i--) {
    if ($LogLines[$i] -match '\[\s*(?<percent>\d+)%\s+(?<finished>\d+)\/(?<total>\d+)\]') {
      return [pscustomobject]@{
        Percent  = [int]$Matches.percent
        Finished = [long]$Matches.finished
        Total    = [long]$Matches.total
      }
    }
  }
  return $null
}

function Get-BuildProgressSnapshot {
  [CmdletBinding()]
  param(
    [hashtable]$Markers,
    [string[]]$LogLines,
    [Nullable[bool]]$ProcessRunning = $null,
    [DateTimeOffset]$Now = [DateTimeOffset]::Now
  )

  $phase = if ($Markers.ContainsKey('package.done')) { 'Complete' }
    elseif ($Markers.ContainsKey('build.failed')) { 'Failed' }
    elseif ($Markers.ContainsKey('build.done')) { 'Packaging' }
    elseif ($Markers.ContainsKey('build.started') -and $ProcessRunning -eq $false) { 'Stopped' }
    elseif ($Markers.ContainsKey('build.started')) { 'Building' }
    elseif ($Markers.ContainsKey('sync.done')) { 'Starting' }
    else { 'Syncing' }

  $progress = ConvertFrom-NinjaProgress -LogLines $LogLines
  $elapsed = $null
  $remaining = $null
  if ($Markers.ContainsKey('build.started')) {
    $epoch = 0L
    if ([long]::TryParse($Markers['build.started'].Trim(), [ref]$epoch)) {
      $elapsed = $Now - [DateTimeOffset]::FromUnixTimeSeconds($epoch)
    }
  }
  if ($progress -and $elapsed -and $elapsed.TotalSeconds -ge 60 -and $progress.Percent -ge 1 -and $progress.Finished -gt 0) {
    $remainingSeconds = $elapsed.TotalSeconds * ($progress.Total - $progress.Finished) / $progress.Finished
    $remaining = [TimeSpan]::FromSeconds([math]::Max(0, [math]::Round($remainingSeconds)))
  }

  [pscustomobject]@{
    Phase     = $phase
    Percent   = if ($phase -eq 'Complete') { 100 } elseif ($progress) { $progress.Percent } else { $null }
    Finished  = if ($progress) { $progress.Finished } else { $null }
    Total     = if ($progress) { $progress.Total } else { $null }
    Elapsed   = $elapsed
    Remaining = $remaining
  }
}

function Format-BuildDuration($Duration) {
  if ($null -eq $Duration) { return '--:--:--' }
  return '{0:00}:{1:00}:{2:00}' -f [math]::Floor($Duration.TotalHours), $Duration.Minutes, $Duration.Seconds
}

function Format-BuildProgress {
  [CmdletBinding()]
  param($Snapshot)

  $percent = if ($null -eq $Snapshot.Percent) { 0 } else { [int]$Snapshot.Percent }
  $filled = [math]::Min(20, [math]::Floor($percent / 5))
  $bar = ('#' * $filled).PadRight(20, '-')
  $count = if ($null -eq $Snapshot.Total) { '--/--' } else { '{0:N0}/{1:N0}' -f $Snapshot.Finished, $Snapshot.Total }
  $eta = if ($Snapshot.Remaining) { 'ETA ~' + (Format-BuildDuration $Snapshot.Remaining) } else { 'ETA calculating' }
  '{0,-8} [{1}] {2,3}%  {3}  elapsed {4}  {5}' -f $Snapshot.Phase.ToUpperInvariant(), $bar, $percent, $count, (Format-BuildDuration $Snapshot.Elapsed), $eta
}
```

- [ ] **Step 4: Run the tests and verify GREEN**

Run:

```powershell
pwsh -NoProfile -File .\tests\build-progress.tests.ps1
```

Expected: `PASS build-progress tests` and exit 0.

- [ ] **Step 5: Record the checkpoint**

Changed files: `scripts/build-progress.ps1`, `tests/build-progress.tests.ps1`. Git commit unavailable because this workspace is not a repository.

### Task 2: Bash progress and marker contract

**Files:**
- Create: `tests/gos-build-progress.test.sh`
- Modify: `scripts/gos-build.sh:17,49-69,96-101`

- [ ] **Step 1: Write the failing isolated Bash test**

Create `tests/gos-build-progress.test.sh`. It builds only a temporary fake tree and never invokes the Android build.

```bash
#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/gos-build.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }
prepare(){
  rm -rf "$TMP/home"
  mkdir -p "$TMP/home/android/grapheneos/build" "$TMP/home/android/state" "$TMP/home/android/out/system"
  touch "$TMP/home/android/state/sync.done" "$TMP/home/android/out/system.img"
  cat > "$TMP/home/android/grapheneos/build/envsetup.sh" <<'EOF'
lunch(){ return 0; }
export ANDROID_PRODUCT_OUT="$HOME/android/out"
m(){
  printf '%s\n' "$NINJA_STATUS" > "$HOME/ninja-status.txt"
  printf '[ 25%% 1/4] fake compile\n'
  return "${FAKE_M_EXIT:-0}"
}
EOF
}

prepare
HOME="$TMP/home" EXPORT_DIR="$TMP/export" bash "$SCRIPT" build >/dev/null
test -s "$TMP/home/android/state/build.started" || fail 'missing build.started'
test -f "$TMP/home/android/state/build.done" || fail 'missing build.done'
test ! -f "$TMP/home/android/state/build.failed" || fail 'unexpected build.failed'
grep -F '[%p %f/%t]' "$TMP/home/ninja-status.txt" >/dev/null || fail 'NINJA_STATUS not structured'

prepare
if HOME="$TMP/home" EXPORT_DIR="$TMP/export" FAKE_M_EXIT=1 bash "$SCRIPT" build >/dev/null 2>&1; then
  fail 'failed m returned success'
fi
test -s "$TMP/home/android/state/build.failed" || fail 'missing build.failed'
test ! -f "$TMP/home/android/state/build.done" || fail 'failed build wrote build.done'

prepare
HOME="$TMP/home" EXPORT_DIR="$TMP/export" bash "$SCRIPT" all-logged
test -f "$TMP/home/android/state/package.done" || fail 'all-logged did not package'
grep -F 'build: COMPLETE' "$TMP/home/android/logs/build.log" >/dev/null || fail 'build.log missing completion'

echo 'PASS gos-build progress tests'
```

- [ ] **Step 2: Run the Bash test and verify RED**

Run:

```powershell
wsl -d Ubuntu -- bash /mnt/c/<path-to-repo>/tests/gos-build-progress.test.sh
```

Expected: nonzero exit with `missing build.started`.

- [ ] **Step 3: Implement marker lifecycle and structured Ninja output**

In `scripts/gos-build.sh`, make the export directory test-overridable without changing its default:

```bash
EXPORT_DIR="${EXPORT_DIR:-/mnt/c/Android/grapheneos-emulator/sysdir}"
```

Add a failure helper:

```bash
mark_build_failed(){ date +%s > "$STATE_DIR/build.failed"; }
```

In `phase_build`, after the sync precondition and before environment setup, add:

```bash
rm -f "$STATE_DIR/build.failed"
date +%s > "$STATE_DIR/build.started"
export NINJA_STATUS='[%p %f/%t] '
```

Every build-phase failure path must call `mark_build_failed` before returning. Use these exact forms:

```bash
cd "$GOS_DIR" || { mark_build_failed; log "build: source tree missing"; return 1; }
source build/envsetup.sh || { mark_build_failed; log "build: envsetup failed"; return 1; }
[ -n "$chosen" ] || { mark_build_failed; log "build: no valid lunch target in: ${LUNCH_CANDIDATES[*]}"; return 1; }
if ! m; then mark_build_failed; log "build: 'm' FAILED"; return 1; fi
```

Keep the existing `build.done` behavior on success.

- [ ] **Step 4: Add the foreground logged mode**

Extend usage and the command case:

```bash
# Usage: gos-build.sh {sync|build|package|all|all-logged}
```

```bash
all-logged)
  : > "$LOG_DIR/build.log"
  exec >> "$LOG_DIR/build.log" 2>&1
  phase_sync && phase_build && phase_package
  ;;
```

This mode remains in the foreground until all phases finish; the Windows-owned `wsl.exe` supplies reliable independence.

- [ ] **Step 5: Run the Bash test and verify GREEN**

Run:

```powershell
wsl -d Ubuntu -- bash /mnt/c/<path-to-repo>/tests/gos-build-progress.test.sh
wsl -d Ubuntu -- bash -n /mnt/c/<path-to-repo>/scripts/gos-build.sh
```

Expected: `PASS gos-build progress tests`; syntax check exits 0.

- [ ] **Step 6: Record the checkpoint**

Changed files: `scripts/gos-build.sh`, `tests/gos-build-progress.test.sh`. Git commit unavailable.

### Task 3: Independent WSL launch and terminal monitor

**Files:**
- Create: `tests/orchestrator-contract.tests.ps1`
- Modify: `scripts/build-grapheneos-emulator.ps1:1-15,25-38,69-84`

- [ ] **Step 1: Write the failing orchestration contract test**

Create `tests/orchestrator-contract.tests.ps1`:

```powershell
$ErrorActionPreference = 'Stop'
$path = Join-Path $PSScriptRoot '..\scripts\build-grapheneos-emulator.ps1'
$source = Get-Content -Raw $path

function Require([bool]$Condition, [string]$Message) {
  if (-not $Condition) { throw $Message }
}

Require ($source -match "build-progress\.ps1") 'orchestrator does not load progress helper'
Require ($source -match 'function Get-WslBuildSnapshot') 'snapshot function missing'
Require ($source -match 'function Show-BuildMonitor') 'monitor function missing'
Require ($source -match '(?s)Start-Process.+wsl\.exe') 'independent wsl.exe launch missing'
Require ($source -match 'all-logged') 'logged foreground mode not launched'
Require ($source -notmatch 'setsid') 'unreliable setsid launch still present'
Require ($source -match 'Show-BuildMonitor -BuildProcess') 'default command does not enter monitor'

Write-Output 'PASS orchestrator contract tests'
```

- [ ] **Step 2: Run the orchestration test and verify RED**

Run:

```powershell
pwsh -NoProfile -File .\tests\orchestrator-contract.tests.ps1
```

Expected: nonzero exit with `orchestrator does not load progress helper`.

- [ ] **Step 3: Load the helper and implement WSL snapshot reads**

Immediately after the parameter block, load the helper:

```powershell
. (Join-Path $PSScriptRoot 'build-progress.ps1')
```

Add a snapshot function that reads marker contents and the last 250 build-log lines through the WSL UNC path:

```powershell
function Get-WslBuildSnapshot {
  param([Nullable[bool]]$ProcessRunning = $null)

  if ($null -eq $ProcessRunning) {
    wsl.exe -d $Distro -- pgrep -f '[g]os-build.sh all-logged' | Out-Null
    $ProcessRunning = ($LASTEXITCODE -eq 0)
  }
  $androidRoot = ('\\wsl$\' + $Distro + '\home\<user>\android')
  $stateDir = Join-Path $androidRoot 'state'
  $markers = @{}
  foreach ($name in 'sync.done','build.started','build.done','build.failed','package.done') {
    $path = Join-Path $stateDir $name
    if (Test-Path $path) {
      $value = Get-Content -Raw $path -ErrorAction SilentlyContinue
      $markers[$name] = if ($null -eq $value) { '' } else { $value.Trim() }
    }
  }
  $buildLog = Join-Path $androidRoot 'logs\build.log'
  $lines = if (Test-Path $buildLog) { @(Get-Content $buildLog -Tail 250) } else { @() }
  Get-BuildProgressSnapshot -Markers $markers -LogLines $lines -ProcessRunning $ProcessRunning
}
```

- [ ] **Step 4: Implement one-shot and continuous display**

Replace the old `-Status` branch with a formatted snapshot plus the existing diagnostic tails:

```powershell
if ($Status) {
  Write-Host (Format-BuildProgress -Snapshot (Get-WslBuildSnapshot))
  wsl.exe -d $Distro -- bash -lc 'echo; echo "== build.log (tail) =="; tail -n 25 ~/android/logs/build.log 2>/dev/null; echo; echo "== tree size / disk =="; du -sh ~/android/grapheneos 2>/dev/null; df -h ~ | tail -1'
  return
}
```

Add the monitor loop:

```powershell
function Show-BuildMonitor {
  param([System.Diagnostics.Process]$BuildProcess)

  Say 'monitoring every 5s; Ctrl+C exits monitor only—the hidden build continues'
  $lastPhase = ''
  while ($true) {
    $BuildProcess.Refresh()
    $snapshot = Get-WslBuildSnapshot -ProcessRunning (-not $BuildProcess.HasExited)
    if ($snapshot.Phase -ne $lastPhase) {
      if ($lastPhase) { Write-Host }
      Say "phase: $($snapshot.Phase)"
      $lastPhase = $snapshot.Phase
    }
    Write-Host ("`r" + (Format-BuildProgress -Snapshot $snapshot).PadRight(110)) -NoNewline

    if ($snapshot.Phase -eq 'Complete') { Write-Host; Say "package complete: $SysDir"; return }
    if ($snapshot.Phase -in 'Failed','Stopped') { Write-Host; throw 'GrapheneOS build stopped or failed; run -Status for log tail' }

    if ($BuildProcess.HasExited) {
      Write-Host
      throw "build process exited with code $($BuildProcess.ExitCode) before package.done"
    }
    Start-Sleep -Seconds 5
  }
}
```

No `finally` block may stop `$BuildProcess`; this is what preserves the build after `Ctrl+C`.

- [ ] **Step 5: Deploy the current Bash script safely**

Before `.wslconfig` changes and shutdown, install the workspace version into WSL:

```powershell
$localBuildScript = Join-Path $PSScriptRoot 'gos-build.sh'
$wslBuildScript = (& wsl.exe -d $Distro -- wslpath -a $localBuildScript | Select-Object -First 1).Trim()
if ($LASTEXITCODE -ne 0 -or -not $wslBuildScript) { throw 'could not translate gos-build.sh path for WSL' }
wsl.exe -d $Distro -- install -m 0755 -- $wslBuildScript /home/<user>/android/gos-build.sh
if ($LASTEXITCODE -ne 0) { throw 'could not deploy gos-build.sh into WSL' }
Say 'deployed current gos-build.sh'
```

- [ ] **Step 6: Replace unreliable detach with independent launch and monitor**

Replace the `setsid` command at the bottom with:

```powershell
Say 'launching independent hidden WSL build process'
$buildProcess = Start-Process `
  -WindowStyle Hidden `
  -FilePath 'wsl.exe' `
  -ArgumentList @('-d', $Distro, '--', 'bash', '/home/<user>/android/gos-build.sh', 'all-logged') `
  -PassThru
Say "started build host pid=$($buildProcess.Id); sysdir target: $SysDir"
Show-BuildMonitor -BuildProcess $buildProcess
```

At the start of the default path, before deploying files or changing `.wslconfig`, use `wsl.exe -d $Distro -- pgrep -f '[g]os-build.sh all-logged'`; if it returns success, do not shut WSL down or start a duplicate, and instruct the user to use `-Status`.

- [ ] **Step 7: Run contract and syntax tests and verify GREEN**

Run:

```powershell
pwsh -NoProfile -File .\tests\orchestrator-contract.tests.ps1
pwsh -NoProfile -Command '$e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path ".\scripts\build-grapheneos-emulator.ps1"),[ref]$null,[ref]$e); if($e){$e; exit 1}'
```

Expected: `PASS orchestrator contract tests`; parser exits 0 with no errors.

- [ ] **Step 8: Exercise safe status mode only**

Run:

```powershell
pwsh -NoProfile -File .\scripts\build-grapheneos-emulator.ps1 -Status
```

Expected: one formatted `COMPLETE` snapshot from the existing `package.done` marker, or `STARTING` if the build has not started. Do not run the default command during automated verification because that launches the real multi-hour build.

- [ ] **Step 9: Record the checkpoint**

Changed files: `scripts/build-grapheneos-emulator.ps1`, `tests/orchestrator-contract.tests.ps1`. Git commit unavailable.

### Task 4: Documentation and full verification

**Files:**
- Modify: `data/GRAPHENEOS_EMULATOR_PLAN.md:105-125` (local-only plan doc)

- [ ] **Step 1: Update operator documentation**

Replace claims about `setsid` detachment with the independent hidden `wsl.exe` mechanism. Document:

```text
- Default command launches the build in an independent hidden WSL host and monitors it every 5 seconds.
- The terminal shows phase, Ninja percent/actions, elapsed time, and approximate ETA.
- Ctrl+C closes only the monitor; the build continues.
- Re-run with -Status for a one-shot snapshot and recent logs.
- ETA is proportional and may move because Ninja actions have unequal cost.
```

- [ ] **Step 2: Run every automated test**

Run:

```powershell
pwsh -NoProfile -File .\tests\build-progress.tests.ps1
pwsh -NoProfile -File .\tests\orchestrator-contract.tests.ps1
wsl -d Ubuntu -- bash /mnt/c/<path-to-repo>/tests/gos-build-progress.test.sh
```

Expected: three `PASS` lines and all commands exit 0.

- [ ] **Step 3: Run syntax and line-ending verification**

Run:

```powershell
pwsh -NoProfile -Command '$e=$null; [void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path ".\scripts\build-grapheneos-emulator.ps1"),[ref]$null,[ref]$e); if($e){$e; exit 1}'
wsl -d Ubuntu -- bash -n /mnt/c/<path-to-repo>/scripts/gos-build.sh
pwsh -NoProfile -Command '$bad=Get-ChildItem scripts,tests -File | Where-Object { (Get-Content -Raw $_.FullName).Contains("`r`n") }; if($bad){$bad.FullName; exit 1}'
```

Expected: all commands exit 0; no CRLF files reported.

- [ ] **Step 4: Re-read every changed file**

Check the two production scripts, helper, three tests, and documentation against the acceptance criteria. Confirm no command in verification launched the real build or changed `.wslconfig`.

- [ ] **Step 5: Final checkpoint**

List all changed files and verification results. Do not claim the real GrapheneOS build succeeded; this plan verifies monitoring and launch behavior without starting the multi-hour build. Git commit remains unavailable unless the user separately requests repository initialization.
