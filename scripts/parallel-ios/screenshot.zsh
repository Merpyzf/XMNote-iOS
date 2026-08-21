#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/lib.zsh"
ensure_task_env
ensure_task_simulator

xcrun simctl bootstatus "$SIMULATOR_UDID" -b
OUTPUT="${1:-}"
[[ -n "$OUTPUT" ]] || OUTPUT="$RESULTS_PATH/Screenshot-$(date +%Y%m%d-%H%M%S).png"
[[ "$OUTPUT" == /* ]] || OUTPUT="$REPO_ROOT/$OUTPUT"
mkdir -p "${OUTPUT:h}"
xcrun simctl io "$SIMULATOR_UDID" screenshot "$OUTPUT"
print -r -- "$OUTPUT"
