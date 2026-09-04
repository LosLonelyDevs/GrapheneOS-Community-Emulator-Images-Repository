#!/usr/bin/env bash
# =============================================================================
# GrapheneOS emulator build orchestrator (WSL side)
# Usage:  gos-build.sh {sync|build|package|all|all-logged}
# Idempotent & resumable: each phase writes a marker in $STATE_DIR and is
# skipped if already complete. Safe to re-run for the same tag after interruption.
# Deployed to: ~/android/gos-build.sh   (authoritative copy in repo scripts/)
# =============================================================================
set -uo pipefail

# ---- configuration ----------------------------------------------------------
TAG="${GRAPHENEOS_TAG:-2026062800}"                            # Override for a new upstream release
MANIFEST_URL="https://github.com/GrapheneOS/platform_manifest.git"
GOS_DIR="$HOME/android/grapheneos"
LOG_DIR="$HOME/android/logs"
STATE_DIR="$HOME/android/state"
EXPORT_DIR="${EXPORT_DIR:-/mnt/c/Android/grapheneos-emulator/sysdir}" # Windows -sysdir target
SYNC_JOBS="8"

# Candidate lunch targets; first that validates wins. Pinned exactly after
# the first sync (verify with: source build/envsetup.sh && lunch).
LUNCH_CANDIDATES=(
  "sdk_phone64_x86_64-cur-userdebug"
  "sdk_phone64_x86_64-trunk_staging-userdebug"
  "sdk_phone64_x86_64-userdebug"
)

mkdir -p "$LOG_DIR" "$STATE_DIR"
log(){ echo "[$(date '+%F %T')] $*"; }
mark_build_failed(){ date +%s > "$STATE_DIR/build.failed"; }

if [[ ! "$TAG" =~ ^[0-9]{10}$ ]]; then
  log "config: GRAPHENEOS_TAG must be a 10-digit GrapheneOS release tag (got: $TAG)"
  exit 2
fi

assert_state_matches_tag(){
  local tag_file="$STATE_DIR/grapheneos_tag.txt"
  local marker recorded
  local has_state=0
  for marker in sync.done build.started build.done build.failed package.done; do
    if [ -e "$STATE_DIR/$marker" ]; then has_state=1; break; fi
  done

  if [ -f "$tag_file" ]; then
    recorded="$(tr -d '\r\n' < "$tag_file")"
    if [ "$recorded" != "$TAG" ]; then
      log "state: requested tag $TAG does not match retained build state for $recorded"
      log "state: use a separate WSL build home or intentionally remove the old source/state before changing tags"
      return 1
    fi
  elif [ "$has_state" -eq 1 ]; then
    log "state: retained phase markers have no grapheneos_tag.txt; refusing ambiguous reuse for tag $TAG"
    log "state: use a separate WSL build home or intentionally remove the old source/state before continuing"
    return 1
  fi
}

# ---- phase: source download -------------------------------------------------
phase_sync(){
  if [ -f "$STATE_DIR/sync.done" ]; then log "sync: already complete (skip)"; return 0; fi
  mkdir -p "$GOS_DIR"; cd "$GOS_DIR" || return 1
  git config --global color.ui false 2>/dev/null || true      # avoid repo init color prompt
  log "sync: repo init @ tag $TAG"
  repo init -u "$MANIFEST_URL" -b "refs/tags/$TAG" || { log "sync: repo init FAILED"; return 1; }
  local tries=0
  until repo sync -j"$SYNC_JOBS"; do
    tries=$((tries+1))
    if [ "$tries" -ge 6 ]; then log "sync: FAILED after $tries attempts"; return 1; fi
    log "sync: repo sync failed; retry $tries/6 in 30s"; sleep 30
  done
  printf '%s\n' "$TAG" > "$STATE_DIR/grapheneos_tag.txt"
  git -C "$GOS_DIR/.repo/manifests" rev-parse HEAD > "$STATE_DIR/grapheneos_manifest_revision.txt"
  touch "$STATE_DIR/sync.done"; log "sync: COMPLETE"
}

# ---- phase: build -----------------------------------------------------------
phase_build(){
  if [ -f "$STATE_DIR/build.done" ]; then log "build: already complete (skip)"; return 0; fi
  if [ ! -f "$STATE_DIR/sync.done" ]; then log "build: cannot start, sync not done"; return 1; fi
  rm -f "$STATE_DIR/build.failed"
  date +%s > "$STATE_DIR/build.started"
  export NINJA_STATUS='[%p %f/%t] '
  cd "$GOS_DIR" || { mark_build_failed; log "build: source tree missing"; return 1; }
  export PATH="$PATH:/sbin:/usr/sbin:/usr/local/sbin"
  export LC_ALL=C.UTF-8
  # shellcheck disable=SC1091
  source build/envsetup.sh || { mark_build_failed; log "build: envsetup failed"; return 1; }
  local chosen="" t
  for t in "${LUNCH_CANDIDATES[@]}"; do
    if lunch "$t" >/dev/null 2>&1; then chosen="$t"; break; fi
  done
  if [ -z "$chosen" ]; then mark_build_failed; log "build: no valid lunch target in: ${LUNCH_CANDIDATES[*]}"; return 1; fi
  log "build: lunch $chosen"
  echo "$chosen" > "$STATE_DIR/lunch_target.txt"
  log "build: running 'm' (this is the multi-hour, RAM-heavy phase)…"
  if ! m; then mark_build_failed; log "build: 'm' FAILED"; return 1; fi
  echo "${ANDROID_PRODUCT_OUT:-}" > "$STATE_DIR/product_out.txt"
  touch "$STATE_DIR/build.done"; log "build: COMPLETE -> ${ANDROID_PRODUCT_OUT:-?}"
}

# ---- phase: package sysdir for Windows --------------------------------------
phase_package(){
  local OUT manifest_revision
  OUT="$(cat "$STATE_DIR/product_out.txt" 2>/dev/null)"
  manifest_revision="$(tr -d '\r\n' < "$STATE_DIR/grapheneos_manifest_revision.txt" 2>/dev/null)"
  if [ -z "$OUT" ] || [ ! -d "$OUT" ]; then log "package: no product_out; build first"; return 1; fi
  if [[ ! "$manifest_revision" =~ ^[0-9a-f]{40}$ ]]; then log "package: missing or invalid manifest revision"; return 1; fi
  mkdir -p "$EXPORT_DIR/data"
  copy_first(){ local dest="$1"; shift; local s; for s in "$@"; do
      if [ -f "$s" ]; then cp -f "$s" "$EXPORT_DIR/$dest"; log "package: copied $(basename "$s") -> $dest"; return 0; fi
    done; log "package: (absent) $dest  [tried: $*]"; return 0; }
  # AOSP may emit split partitions OR a single super.img — copy whatever exists.
  # Emulator-specific images contain the GPT/block-device layout required by
  # first-stage init (including super/vbmeta). Generic partition images do not.
  copy_first system.img    "$OUT/system-qemu.img"  "$OUT/system.img"
  copy_first vendor.img    "$OUT/vendor-qemu.img"  "$OUT/vendor.img"
  copy_first super.img     "$OUT/super.img"
  copy_first ramdisk.img   "$OUT/ramdisk-qemu.img" "$OUT/ramdisk.img"
  copy_first userdata.img  "$OUT/userdata.img"
  copy_first kernel-ranchu "$OUT/kernel-ranchu" "$OUT/kernel-ranchu-64"
  local f
  for f in encryptionkey.img advancedFeatures.ini VerifiedBootParams.textproto kernel_cmdline.txt source.properties; do
    [ -f "$OUT/$f" ] && { cp -f "$OUT/$f" "$EXPORT_DIR/$f"; log "package: copied $f"; }
  done
  [ -f "$OUT/system/build.prop" ] && cp -f "$OUT/system/build.prop" "$EXPORT_DIR/build.prop"
  if [ ! -f "$EXPORT_DIR/source.properties" ]; then
    local api_level android_version
    api_level="$(sed -n 's/^ro.system.build.version.sdk=//p' "$EXPORT_DIR/build.prop" | head -n 1)"
    android_version="$(sed -n 's/^ro.system.build.version.release=//p' "$EXPORT_DIR/build.prop" | head -n 1)"
    cat > "$EXPORT_DIR/source.properties" <<EOF
Pkg.Desc=Community-built GrapheneOS SDK emulator sysdir
Pkg.Revision=1
AndroidVersion.ApiLevel=${api_level:-0}
AndroidVersion.CodeName=
AndroidVersion.ExtensionLevel=0
SystemImage.Abi=x86_64
SystemImage.TagId=default
SystemImage.TagDisplay=GrapheneOS SDK Emulator
GrapheneOS.Tag=$TAG
GrapheneOS.ManifestCommit=$manifest_revision
GrapheneOS.AndroidVersion=${android_version:-unknown}
EOF
    log "package: generated source.properties"
  fi
  sed -i '/^GrapheneOS\.Tag=/d; /^GrapheneOS\.ManifestCommit=/d' "$EXPORT_DIR/source.properties"
  printf 'GrapheneOS.Tag=%s\nGrapheneOS.ManifestCommit=%s\n' "$TAG" "$manifest_revision" >> "$EXPORT_DIR/source.properties"
  ls -lah "$EXPORT_DIR" | tee "$STATE_DIR/package_listing.txt"
  touch "$STATE_DIR/package.done"; log "package: COMPLETE -> $EXPORT_DIR"
}

# ---- dispatch ---------------------------------------------------------------
case "${1:-all}" in
  sync)    assert_state_matches_tag && phase_sync ;;
  build)   assert_state_matches_tag && phase_build ;;
  package) assert_state_matches_tag && phase_package ;;
  all)     assert_state_matches_tag && phase_sync && phase_build && phase_package ;;
  all-logged)
    : > "$LOG_DIR/build.log"
    exec >> "$LOG_DIR/build.log" 2>&1
    assert_state_matches_tag && phase_sync && phase_build && phase_package
    ;;
  *) echo "usage: $0 {sync|build|package|all|all-logged}"; exit 2 ;;
esac
