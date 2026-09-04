function ConvertTo-WslPath {
  [CmdletBinding()]
  param([Parameter(Mandatory)][string]$WindowsPath)

  $fullPath = [IO.Path]::GetFullPath($WindowsPath)
  if ($fullPath -notmatch '^(?<drive>[A-Za-z]):\\(?<rest>.*)$') {
    throw "WSL path conversion requires a drive-qualified Windows path: $WindowsPath"
  }

  $drive = $Matches.drive.ToLowerInvariant()
  $rest = $Matches.rest.Replace('\', '/')
  return "/mnt/$drive/$rest"
}

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
    [hashtable]$Markers = @{},
    [string[]]$LogLines = @(),
    [Nullable[bool]]$ProcessRunning = $null,
    [DateTimeOffset]$Now = [DateTimeOffset]::Now
  )

  $phase = if ($Markers.ContainsKey('package.done')) { 'Complete' }
    elseif ($Markers.ContainsKey('build.failed') -and $ProcessRunning -ne $true) { 'Failed' }
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
    $startedValue = [string]$Markers['build.started']
    if ([long]::TryParse($startedValue.Trim(), [ref]$epoch)) {
      $elapsed = $Now - [DateTimeOffset]::FromUnixTimeSeconds($epoch)
    }
  }

  if ($progress -and $elapsed -and $elapsed.TotalSeconds -ge 60 -and $progress.Percent -ge 1 -and $progress.Finished -gt 0) {
    $remainingSeconds = $elapsed.TotalSeconds * ($progress.Total - $progress.Finished) / $progress.Finished
    $remaining = [TimeSpan]::FromSeconds([math]::Max(0, [math]::Round($remainingSeconds)))
  }

  return [pscustomobject]@{
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
  $label = switch ($Snapshot.Phase) {
    'Building' { 'BUILD' }
    'Packaging' { 'PACKAGE' }
    default { $Snapshot.Phase.ToUpperInvariant() }
  }
  $eta = if ($Snapshot.Phase -eq 'Complete') { 'ETA done' }
    elseif ($Snapshot.Phase -in 'Failed','Stopped') { 'ETA unavailable' }
    elseif ($Snapshot.Remaining) { 'ETA ~' + (Format-BuildDuration $Snapshot.Remaining) }
    else { 'ETA calculating' }

  return '{0,-8} [{1}] {2,3}%  {3}  elapsed {4}  {5}' -f $label, $bar, $percent, $count, (Format-BuildDuration $Snapshot.Elapsed), $eta
}
