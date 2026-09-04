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

$convertedPath = if (Get-Command ConvertTo-WslPath -ErrorAction SilentlyContinue) {
  ConvertTo-WslPath 'C:\Users\Sample User\project\scripts\gos-build.sh'
} else {
  $null
}
Assert-Equal '/mnt/c/Users/Sample User/project/scripts/gos-build.sh' $convertedPath 'converts a Windows drive path without invoking wslpath'

$parsed = ConvertFrom-NinjaProgress -LogLines @(
  'unrelated compiler output',
  '[ 42% 12345/29100] target C++: libfoo <= foo.cpp'
)
Assert-Equal 42 $parsed.Percent 'parses Ninja percentage'
Assert-Equal 12345 $parsed.Finished 'parses finished actions'
Assert-Equal 29100 $parsed.Total 'parses total actions'

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
Assert-Equal 'Building' (Get-BuildProgressSnapshot -Markers @{ 'build.started' = '1000'; 'build.failed' = '900' } -LogLines @() -ProcessRunning $true).Phase 'live process ignores stale failure marker'
Assert-Equal 'Stopped' (Get-BuildProgressSnapshot -Markers @{ 'build.started' = '1000' } -LogLines @() -ProcessRunning $false).Phase 'stale build is stopped'

$line = Format-BuildProgress -Snapshot $snapshot
if ($line -notmatch 'BUILD' -or $line -notmatch '25%' -or $line -notmatch 'ETA ~03:00:00') {
  throw "formatted line missing required fields: $line"
}

Write-Output 'PASS build-progress tests'
