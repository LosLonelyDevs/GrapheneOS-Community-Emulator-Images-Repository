#!/usr/bin/env bash
set -euo pipefail
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common-unix.sh"
gos_emu_setup Linux "${1:-GrapheneOS_Base}"
