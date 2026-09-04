# Post-Build Automation Design

## Objective

Extend the default GrapheneOS emulator pipeline beyond `package.done`: validate a clean headless boot, restore the user's pre-build WSL resource configuration, shut WSL down, and launch the validated emulator visibly. Keep all source and build output unless the user explicitly runs `-Reclaim`.

## Pipeline

1. Existing sync, build, and package phases complete.
2. Launch `GrapheneOS_Base` headlessly on a dedicated emulator serial using the packaged sysdir.
3. Wait for `sys.boot_completed=1`; fail on timeout or premature emulator exit.
4. Record build properties, matching GrapheneOS packages, crash logcat, and emulator stdout/stderr.
5. Stop the headless validation emulator.
6. Restore the exact `.wslconfig` backup created before the build, or remove the generated config if none existed; run `wsl --shutdown`.
7. Launch `GrapheneOS_Base` visibly with the packaged sysdir and persistent data produced by validation.

## Recovery and Idempotence

Add `-Finalize` for packages that already exist. It runs validation, resource restoration, and visible launch without rebuilding. Default execution calls the same finalization function after the monitor reaches `package.done`.

Before overwriting `.wslconfig`, persist restoration metadata under `C:\Android\grapheneos-emulator\logs`. On validation failure, resource restoration still runs, but the visible emulator is not launched. `-NoConfig` default runs do not restore resources they did not change; explicit `-Finalize` uses the latest recorded or timestamped backup to recover an interrupted prior run.

## Validation

Use a fixed serial (`emulator-5584`) to avoid acting on unrelated devices. Require successful boot completion within 15 minutes. Capture properties and package matches to the orchestrator log, and store emulator output plus crash logcat in the Windows log directory.

## Non-Goals

- Never delete the source tree or build output automatically.
- Never invoke `-Reclaim` implicitly.
- Do not modify the user's other AVDs.

## Acceptance Criteria

- Default pipeline automatically validates, restores resources, and launches the GUI after packaging.
- `-Finalize` performs the same post-build chain for the already completed package.
- WSL configuration is restored even if validation fails.
- GUI launch occurs only after a successful boot validation.
- All post-build logs are written under `C:\Android\grapheneos-emulator\logs`.
- Existing parser, Bash, syntax, and contract tests pass.
