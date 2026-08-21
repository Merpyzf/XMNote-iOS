#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/lib.zsh"

print -r -- "Repository:       $REPO_ROOT"
print -r -- "Main worktree:    $MAIN_REPO_ROOT"
print -r -- "State root:       $STATE_ROOT"
print -r -- "Container:        $IOS_CONTAINER_TYPE $IOS_CONTAINER_PATH"
print -r -- "Scheme:           $IOS_SCHEME"
print -r -- "Package mode:     ${IOS_PACKAGE_MODE:-isolated}"
print -r -- "Build limit/jobs: ${TOP_LEVEL_BUILD_LIMIT:-2}/${XCODEBUILD_JOBS:-4}"
print -r -- ""
xcodebuild -version

if xcrun simctl list devicetypes -j | grep -Fq "$SIM_DEVICE_TYPE_ID"; then
  print -r -- "Device type:      available ($SIM_DEVICE_TYPE_ID)"
else
  print -u2 -- "Device type:      MISSING ($SIM_DEVICE_TYPE_ID)"
fi

if xcrun simctl list runtimes -j | grep -Fq "$SIM_RUNTIME_ID"; then
  print -r -- "Runtime:          available ($SIM_RUNTIME_ID)"
else
  print -u2 -- "Runtime:          MISSING ($SIM_RUNTIME_ID)"
fi

TRACKED_RESOLVED="$(git -C "$REPO_ROOT" ls-files -- '*Package.resolved')"
if [[ -n "$TRACKED_RESOLVED" ]]; then
  print -r -- "Package.resolved: tracked"
else
  print -u2 -- "Package.resolved: none tracked; deterministic parallel resolution requires committing it"
fi

if [[ -d "$STATE_ROOT" ]]; then
  print -r -- "State disk usage: $(du -sh "$STATE_ROOT" | awk '{print $1}')"
fi

DEFAULT_CAS="${HOME}/Library/Developer/Xcode/CompilationCache.noindex"
if [[ -d "$DEFAULT_CAS" ]]; then
  print -r -- "Default CAS size: $(du -sh "$DEFAULT_CAS" | awk '{print $1}')"
fi

if [[ -r "$REPO_ROOT/.parallel-ios-env" ]]; then
  load_task_env
  print -r -- "Managed task:     $TASK_ID"
  print -r -- "Simulator:        $SIMULATOR_UDID"
  print -r -- "DerivedData:      $DERIVED_DATA_PATH"
fi

ORPHAN_COUNT=0
for TASK_ENV in "$STATE_ROOT"/tasks/*/env.zsh(N); do
  unset WORKTREE_PATH TASK_ID
  source "$TASK_ENV"
  if [[ ! -d "$WORKTREE_PATH" ]]; then
    print -u2 -- "Orphan task:       $TASK_ID (run ai-task-destroy TASK=$TASK_ID from main)"
    (( ORPHAN_COUNT++ )) || true
  fi
done
if (( ORPHAN_COUNT == 0 )); then
  print -r -- "Orphan tasks:      none"
fi
