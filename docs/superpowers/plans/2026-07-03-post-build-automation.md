# Post-Build Automation Implementation Plan

**Goal:** Automate headless validation, WSL restoration, and visible emulator launch after packaging.

**Files:**

- Modify `scripts/build-grapheneos-emulator.ps1` for `-Finalize` and post-build functions.
- Modify `tests/orchestrator-contract.tests.ps1` with failing contracts before implementation.
- Update `data/GRAPHENEOS_EMULATOR_PLAN.md` (local-only plan doc) with the automated lifecycle.

## Task 1: RED contracts

- Add assertions for `-Finalize`, `Invoke-PostBuild`, fixed emulator serial, WSL restore state, visible launch, and default post-build invocation.
- Run the contract suite and confirm failure from missing behavior.

## Task 2: Post-build implementation

- Refactor existing validation into `Invoke-HeadlessValidation` with boot timeout, dedicated serial, log capture, and guaranteed cleanup.
- Add `Save-WslConfigRestoreState` and `Restore-WslConfig`.
- Add `Start-GrapheneOsEmulator` for visible launch.
- Add `Invoke-PostBuild` with `try/finally` restoration semantics.
- Wire default completion and `-Finalize` to the shared function.

## Task 3: Verification and current finalization

- Run contract, parser, Bash, PowerShell syntax, and LF checks.
- Run `-Finalize` against the current packaged images.
- Verify boot completion, captured properties/logs, restored `.wslconfig`, WSL shutdown, and visible emulator process.
- Update project documentation. Never run automatic reclamation.
