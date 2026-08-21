#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/lib.zsh"
ensure_task_env
ensure_task_simulator
set_package_args

MARKER="$TASK_STATE/package-fingerprint"
CURRENT_FINGERPRINT="$(package_fingerprint)"
if [[ "${IOS_PACKAGE_MODE:-isolated}" == "shared-locked" ]]; then
  SHARED_MARKER="$SHARED_ROOT/SourcePackages.package-fingerprint"
  if [[ -r "$SHARED_MARKER" && -d "$CLONED_SOURCE_PACKAGES_PATH" ]]; then
    [[ "$(<"$SHARED_MARKER")" == "$CURRENT_FINGERPRINT" ]] || die "Package.resolved changed in shared-locked mode; pause peer builds and run make -f Makefile.parallel-ios ai-resolve explicitly"
    print -r -- "$CURRENT_FINGERPRINT" > "$MARKER"
    print -r -- "Task environment is ready from locked shared packages: $TASK_ID"
    exit 0
  fi
elif [[ -r "$MARKER" && "$(<"$MARKER")" == "$CURRENT_FINGERPRINT" && -d "$CLONED_SOURCE_PACKAGES_PATH" ]]; then
  print -r -- "Task environment is ready: $TASK_ID"
  exit 0
fi

note "package state is missing or stale; resolving before the first build"
"$SCRIPT_DIR/resolve-packages.zsh"
