#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/lib.zsh"
ensure_task_env
ensure_task_simulator
set_package_args
ensure_task_dirs

if [[ "${IOS_PACKAGE_MODE:-isolated}" == "shared-locked" ]]; then
  acquire_package_maintenance
else
  acquire_exclusive_lock "$LOCK_ROOT/package-resolution"
fi

note "resolving packages into $CLONED_SOURCE_PACKAGES_PATH"
xcodebuild \
  "${XCODE_CONTAINER_ARGS[@]}" \
  -resolvePackageDependencies \
  "${PACKAGE_ARGS[@]}"

if [[ "${IOS_PACKAGE_MODE:-isolated}" == "shared-locked" ]]; then
  package_fingerprint > "$SHARED_ROOT/SourcePackages.package-fingerprint"
fi
package_fingerprint > "$TASK_STATE/package-fingerprint"

print -r -- "Package resolution complete."
