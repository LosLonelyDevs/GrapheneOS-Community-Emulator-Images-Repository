#!/usr/bin/env bash
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for script in "$REPO_ROOT"/install/*.sh; do
  bash -n "$script"
done

TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
BUNDLE="$TEST_ROOT/bundle"
SDK="$TEST_ROOT/sdk"
mkdir -p "$BUNDLE/install" "$BUNDLE/sysdir" "$SDK/emulator" "$SDK/platform-tools"
cp "$REPO_ROOT"/install/*.sh "$BUNDLE/install/"

for file in \
  system.img vendor.img super.img ramdisk.img userdata.img kernel-ranchu \
  encryptionkey.img advancedFeatures.ini VerifiedBootParams.textproto \
  kernel_cmdline.txt source.properties; do
  : > "$BUNDLE/sysdir/$file"
done

cat > "$SDK/emulator/emulator" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = "-list-avds" ]; then
  printf 'Test_AVD\n'
  exit 0
fi
printf '%s\n' "$@" > "${FAKE_EMULATOR_ARGS:?}"
EOF
chmod +x "$SDK/emulator/emulator"
cat > "$SDK/platform-tools/adb" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$SDK/platform-tools/adb"

ANDROID_SDK_ROOT="$SDK" "$BUNDLE/install/setup-linux.sh" Test_AVD >/dev/null
[ "$(cat "$BUNDLE/.grapheneos-community-emulator-avd")" = "Test_AVD" ]

FAKE_EMULATOR_ARGS="$TEST_ROOT/args.txt" ANDROID_SDK_ROOT="$SDK" \
  "$BUNDLE/install/launch-linux.sh" -- -no-window -no-audio

grep -Fx -- '-avd' "$TEST_ROOT/args.txt" >/dev/null
grep -Fx -- 'Test_AVD' "$TEST_ROOT/args.txt" >/dev/null
grep -Fx -- '-sysdir' "$TEST_ROOT/args.txt" >/dev/null
grep -Fx -- "$BUNDLE/sysdir" "$TEST_ROOT/args.txt" >/dev/null
grep -Fx -- '-no-window' "$TEST_ROOT/args.txt" >/dev/null

printf 'PASS install script tests\n'
