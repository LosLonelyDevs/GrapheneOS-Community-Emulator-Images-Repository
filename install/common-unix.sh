#!/usr/bin/env bash

set -euo pipefail

gos_emu_die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

gos_emu_bundle_root() {
  cd "$(dirname "${BASH_SOURCE[0]}")/.." >/dev/null 2>&1
  pwd
}

gos_emu_require_host() {
  local expected_os="$1"
  local actual_os arch
  actual_os="$(uname -s)"
  arch="$(uname -m)"

  [ "$actual_os" = "$expected_os" ] ||
    gos_emu_die "this script targets $expected_os; detected $actual_os"
  case "$arch" in
    x86_64|amd64) ;;
    *) gos_emu_die "this release requires an x86-64 host; detected $arch" ;;
  esac

  if [ "$actual_os" = "Darwin" ] &&
     [ "$(sysctl -n hw.optional.arm64 2>/dev/null || printf '0')" = "1" ]; then
    gos_emu_die "Apple silicon is not supported by this x86-64 emulator image"
  fi
}

gos_emu_find_sdk_root() {
  local candidate
  for candidate in \
    "${ANDROID_SDK_ROOT:-}" \
    "${ANDROID_HOME:-}" \
    "$HOME/Android/Sdk" \
    "$HOME/Android/sdk" \
    "$HOME/Library/Android/sdk"; do
    [ -n "$candidate" ] || continue
    if [ -x "$candidate/emulator/emulator" ] && [ -x "$candidate/platform-tools/adb" ]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  gos_emu_die "Android SDK emulator and platform-tools not found; set ANDROID_SDK_ROOT"
}

gos_emu_assert_sysdir() {
  local sysdir="$1"
  local file
  [ -d "$sysdir" ] || gos_emu_die "sysdir not found: $sysdir"
  for file in \
    system.img vendor.img super.img ramdisk.img userdata.img kernel-ranchu \
    encryptionkey.img advancedFeatures.ini VerifiedBootParams.textproto \
    kernel_cmdline.txt source.properties; do
    [ -f "$sysdir/$file" ] || gos_emu_die "missing required sysdir file: $file"
  done
}

gos_emu_assert_avd() {
  local emulator_bin="$1"
  local avd_name="$2"
  "$emulator_bin" -list-avds | awk -v wanted="$avd_name" '$0 == wanted { found=1 } END { exit !found }' ||
    gos_emu_die "AVD '$avd_name' not found; create a normal x86-64 phone AVD in Android Studio"
}

gos_emu_setup() {
  local expected_os="$1"
  local avd_name="${2:-GrapheneOS_Base}"
  local bundle_root sysdir sdk_root emulator_bin config_file

  gos_emu_require_host "$expected_os"
  case "$avd_name" in
    ''|*[!A-Za-z0-9._-]*) gos_emu_die "AVD name may contain only letters, numbers, dot, underscore, and dash" ;;
  esac

  bundle_root="$(gos_emu_bundle_root)"
  sysdir="${GRAPHENEOS_EMULATOR_SYSDIR:-$bundle_root/sysdir}"
  sdk_root="$(gos_emu_find_sdk_root)"
  emulator_bin="$sdk_root/emulator/emulator"
  config_file="$bundle_root/.grapheneos-community-emulator-avd"

  gos_emu_assert_sysdir "$sysdir"
  gos_emu_assert_avd "$emulator_bin" "$avd_name"
  printf '%s\n' "$avd_name" > "$config_file"

  printf 'setup complete\n'
  printf '  bundle: %s\n' "$bundle_root"
  printf '  sysdir: %s\n' "$sysdir"
  printf '  sdk: %s\n' "$sdk_root"
  printf '  avd: %s\n' "$avd_name"
}

gos_emu_launch() {
  local expected_os="$1"
  shift
  local bundle_root sysdir sdk_root emulator_bin config_file avd_name

  gos_emu_require_host "$expected_os"
  bundle_root="$(gos_emu_bundle_root)"
  sysdir="${GRAPHENEOS_EMULATOR_SYSDIR:-$bundle_root/sysdir}"
  sdk_root="$(gos_emu_find_sdk_root)"
  emulator_bin="$sdk_root/emulator/emulator"
  config_file="$bundle_root/.grapheneos-community-emulator-avd"
  avd_name="${GRAPHENEOS_EMULATOR_AVD:-}"

  if [ -z "$avd_name" ] && [ -f "$config_file" ]; then
    IFS= read -r avd_name < "$config_file"
  fi
  avd_name="${avd_name:-GrapheneOS_Base}"
  case "$avd_name" in
    ''|*[!A-Za-z0-9._-]*) gos_emu_die "invalid saved AVD name; rerun the platform setup script" ;;
  esac

  gos_emu_assert_sysdir "$sysdir"
  gos_emu_assert_avd "$emulator_bin" "$avd_name"
  if [ "${1:-}" = "--" ]; then shift; fi
  exec "$emulator_bin" -avd "$avd_name" -sysdir "$sysdir" -no-snapshot -gpu auto "$@"
}
