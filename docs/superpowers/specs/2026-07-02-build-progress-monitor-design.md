# GrapheneOS Build Progress Monitor Design

## Objective

Make the default Windows build command launch the GrapheneOS build independently and then keep the invoking terminal open as a live monitor. The monitor reports phase, Ninja percentage, completed and total actions, elapsed time, and approximate time remaining. Pressing `Ctrl+C` stops monitoring without stopping the build.

## User Experience

The existing command remains unchanged:

```powershell
.\scripts\build-grapheneos-emulator.ps1
```

After WSL configuration and build launch, the terminal refreshes one status line every five seconds:

```text
BUILD  [########------------] 42%  12,345/29,100  elapsed 01:24:10  ETA ~01:56:20
```

Before Ninja emits measurable progress, the terminal shows the current phase and elapsed time with `ETA calculating`. Packaging and completion use explicit phase markers. `Ctrl+C` exits the monitor only; the independent hidden `wsl.exe` process continues the build.

`-Status` uses the same parser but prints one snapshot and exits. `-Validate`, `-Reclaim`, and `-NoConfig` retain their current behavior.

## Architecture

### Reliable build runner

Replace the current `setsid ... &` launch, which is documented as unreliable on this machine, with a hidden Windows `Start-Process` running `wsl.exe` for the entire foreground lifetime of `gos-build.sh`. The build is therefore owned by an independent Windows process rather than the monitor terminal.

The orchestrator deploys the workspace copy of `scripts/gos-build.sh` to `~/android/gos-build.sh` before restarting WSL. A new `all-logged` command redirects output to `~/android/logs/build.log` and runs sync, build, and package sequentially. This keeps `Start-Process` arguments simple and avoids fragile nested shell quoting.

### Structured Ninja progress

`gos-build.sh` exports a deterministic Ninja status format before invoking `m`:

```text
[%p %f/%t]
```

The build phase writes an epoch timestamp to `state/build.started`, removes stale failure state, retains the existing `build.done` marker, and writes `state/build.failed` if `m` exits unsuccessfully.

### Progress parser

Add `scripts/build-progress.ps1` containing pure functions that:

- Parse the latest structured Ninja line.
- Determine phase from `sync.done`, `build.started`, `build.done`, `build.failed`, and `package.done`.
- Calculate elapsed time from `build.started`.
- Estimate remaining time as `elapsed * (total - finished) / finished`.
- Suppress ETA until at least one percent and sixty seconds have elapsed.
- Format a fixed-width terminal status line.

ETA is explicitly approximate because Ninja actions vary greatly in duration. The output uses an `~` prefix and may move in either direction.

### Monitor loop

`build-grapheneos-emulator.ps1` dot-sources the parser and polls WSL every five seconds. Each poll retrieves markers and the last parsable Ninja status through the `\\wsl$` filesystem share, plus process state from the independent build host. The loop:

- Refreshes one console line during normal progress.
- Prints phase transitions on separate lines.
- Exits successfully when `package.done` exists.
- Prints the last 25 log lines and exits nonzero when `build.failed` exists or the hidden build process exits without completion.
- Leaves the build process untouched when monitoring is interrupted.

## Error Handling

- Deployment failure stops before WSL shutdown or build launch.
- A duplicate active build is detected and not launched again.
- Missing or malformed progress lines produce `ETA calculating`, not a parser failure.
- A stale `build.started` without a live build is reported as stopped or failed.
- Existing successful markers preserve idempotent behavior.
- The hidden build process ID is printed so users can correlate it with Task Manager or PowerShell.

## Testing

Add dependency-free PowerShell tests in `tests/build-progress.tests.ps1`. Tests dot-source `scripts/build-progress.ps1` and cover:

1. Parsing a valid Ninja percentage and action count.
2. Ignoring unrelated or malformed log lines.
3. ETA calculation with deterministic timestamps.
4. ETA suppression during the initial unstable period.
5. Formatting building, packaging, completed, and failed states.
6. Verifying `Ctrl+C` cannot terminate the independently launched WSL process by construction: the monitor receives only a process handle and never calls `Stop-Process` during cancellation.

Script syntax is checked with the PowerShell parser. Bash syntax is checked with `bash -n`. A dry-run parser fixture verifies representative log output without starting a real Android build.

## Deployment and Compatibility

The change modifies only build orchestration and monitoring. It does not alter GrapheneOS source, build targets, memory defaults, swap defaults, packaging paths, or validation behavior. The build remains resumable through existing phase markers.

## Acceptance Criteria

- Default invocation launches an independent build and immediately monitors it.
- Terminal shows phase, percentage, action counts, elapsed time, and approximate remaining time when Ninja data exists.
- `Ctrl+C` stops monitoring while the hidden WSL build remains alive.
- `-Status` prints the same progress information once.
- Completion and failure are detected without relying solely on log text.
- Parser tests, PowerShell syntax checks, and Bash syntax checks pass.
