#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$ROOT/scripts/gos-build.sh"
TMP="$(mktemp -d)"
DEFAULT_TAG="2026062800"
trap 'rm -rf "$TMP"' EXIT

fail(){ echo "FAIL: $*" >&2; exit 1; }

prepare(){
  rm -rf "$TMP/home" "$TMP/export"
  mkdir -p "$TMP/home/android/grapheneos/build" "$TMP/home/android/state" "$TMP/home/android/out/system"
  touch "$TMP/home/android/state/sync.done"
  printf '%s\n' "$DEFAULT_TAG" > "$TMP/home/android/state/grapheneos_tag.txt"
  printf '%040d\n' 0 > "$TMP/home/android/state/grapheneos_manifest_revision.txt"
  printf 'generic-system\n' > "$TMP/home/android/out/system.img"
  printf 'qemu-system\n' > "$TMP/home/android/out/system-qemu.img"
  printf 'generic-vendor\n' > "$TMP/home/android/out/vendor.img"
  printf 'qemu-vendor\n' > "$TMP/home/android/out/vendor-qemu.img"
  printf 'generic-ramdisk\n' > "$TMP/home/android/out/ramdisk.img"
  printf 'qemu-ramdisk\n' > "$TMP/home/android/out/ramdisk-qemu.img"
  printf 'kernel-options\n' > "$TMP/home/android/out/kernel_cmdline.txt"
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
printf '%s\n' '2026070100' > "$TMP/home/android/state/grapheneos_tag.txt"
if HOME="$TMP/home" EXPORT_DIR="$TMP/export" GRAPHENEOS_TAG="$DEFAULT_TAG" bash "$SCRIPT" all-logged >/dev/null 2>&1; then
  fail 'mismatched retained tag was accepted'
fi
grep -F 'does not match retained build state' "$TMP/home/android/logs/build.log" >/dev/null || fail 'mismatched tag was not logged'

prepare
rm "$TMP/home/android/state/grapheneos_tag.txt"
if HOME="$TMP/home" EXPORT_DIR="$TMP/export" GRAPHENEOS_TAG="$DEFAULT_TAG" bash "$SCRIPT" build >/dev/null 2>&1; then
  fail 'ambiguous marker state without a tag was accepted'
fi

if HOME="$TMP/home" EXPORT_DIR="$TMP/export" GRAPHENEOS_TAG='not-a-tag' bash "$SCRIPT" build >/dev/null 2>&1; then
  fail 'invalid tag format was accepted'
fi

grep -F 'TAG="${GRAPHENEOS_TAG:-2026062800}"' "$SCRIPT" >/dev/null || fail 'tag override contract missing'
grep -F 'repo init -u "$MANIFEST_URL" -b "refs/tags/$TAG"' "$SCRIPT" >/dev/null || fail 'tag-pinned repo init missing'
if grep -F 'if [ ! -d .repo ]; then' "$SCRIPT" >/dev/null; then
  fail 'repo init is still skipped for an existing checkout'
fi

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
grep -Fx 'qemu-system' "$TMP/export/system.img" >/dev/null || fail 'package did not prefer system-qemu.img'
grep -Fx 'qemu-vendor' "$TMP/export/vendor.img" >/dev/null || fail 'package did not prefer vendor-qemu.img'
grep -Fx 'qemu-ramdisk' "$TMP/export/ramdisk.img" >/dev/null || fail 'package did not prefer ramdisk-qemu.img'
cmp "$TMP/home/android/out/kernel_cmdline.txt" "$TMP/export/kernel_cmdline.txt" >/dev/null || fail 'package omitted kernel_cmdline.txt'
grep -Fx "GrapheneOS.Tag=$DEFAULT_TAG" "$TMP/export/source.properties" >/dev/null || fail 'source.properties tag missing'
grep -Fx 'GrapheneOS.ManifestCommit=0000000000000000000000000000000000000000' "$TMP/export/source.properties" >/dev/null || fail 'source.properties manifest missing'

echo 'PASS gos-build progress tests'
