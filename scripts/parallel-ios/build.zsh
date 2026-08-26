#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
"$SCRIPT_DIR/prepare.zsh"
source "$SCRIPT_DIR/lib.zsh"
load_task_env
set_package_args
ensure_task_dirs
verify_shared_package_fingerprint
common_build_args
acquire_build_slot

note "checking changed Swift source against design-system rules"
PYTHONDONTWRITEBYTECODE=1 python3 "$WORKTREE_PATH/scripts/design-system/ds.py" lint --changed

RESULT_BUNDLE="$(result_bundle_path Build)"
note "building $IOS_SCHEME with task-local DerivedData"
xcodebuild \
  "${COMMON_BUILD_ARGS[@]}" \
  -destination 'generic/platform=iOS Simulator' \
  -resultBundlePath "$RESULT_BUNDLE" \
  build

print -r -- "Build result: $RESULT_BUNDLE"
