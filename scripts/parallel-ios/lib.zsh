#!/bin/zsh
set -euo pipefail

die() {
  print -u2 -- "parallel-ios: $*"
  exit 1
}

note() {
  print -u2 -- "parallel-ios: $*"
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "missing command: $1"
}

require_command git
require_command rg
require_command xcodebuild
require_command xcrun
require_command shasum

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" || die "run this inside a Git worktree"
MAIN_REPO_ROOT="$(git -C "$REPO_ROOT" worktree list --porcelain | sed -n 's/^worktree //p' | head -1)"
[[ -n "$MAIN_REPO_ROOT" ]] || die "could not locate the main worktree"

CONFIG_PATH="${PARALLEL_IOS_CONFIG:-$REPO_ROOT/parallel-ios.conf}"
[[ -r "$CONFIG_PATH" ]] || die "missing $CONFIG_PATH (copy parallel-ios.conf.example and edit it)"
source "$CONFIG_PATH"

: "${IOS_CONTAINER_TYPE:?set IOS_CONTAINER_TYPE in parallel-ios.conf}"
: "${IOS_CONTAINER_PATH:?set IOS_CONTAINER_PATH in parallel-ios.conf}"
: "${IOS_SCHEME:?set IOS_SCHEME in parallel-ios.conf}"
: "${IOS_CONFIGURATION:?set IOS_CONFIGURATION in parallel-ios.conf}"
: "${XCODE_DEVELOPER_DIR:?set XCODE_DEVELOPER_DIR in parallel-ios.conf}"

STATE_ROOT="${PARALLEL_STATE_ROOT:-${MAIN_REPO_ROOT}.parallel-ios-state}"
WORKTREE_PARENT="${PARALLEL_WORKTREE_PARENT:-$STATE_ROOT/worktrees}"
SHARED_ROOT="$STATE_ROOT/shared"
LOCK_ROOT="$STATE_ROOT/locks"
BUILD_SLOT_ROOT="$LOCK_ROOT/build-slots"

export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"

case "$IOS_CONTAINER_TYPE" in
  workspace)
    XCODE_CONTAINER_ARGS=(-workspace "$REPO_ROOT/$IOS_CONTAINER_PATH")
    ;;
  project)
    XCODE_CONTAINER_ARGS=(-project "$REPO_ROOT/$IOS_CONTAINER_PATH")
    ;;
  *)
    die "IOS_CONTAINER_TYPE must be workspace or project"
    ;;
esac

[[ -e "$REPO_ROOT/$IOS_CONTAINER_PATH" ]] || die "container not found: $REPO_ROOT/$IOS_CONTAINER_PATH"

load_task_env() {
  local env_link="$REPO_ROOT/.parallel-ios-env"
  [[ -r "$env_link" ]] || die "this worktree is not initialized; run make -f Makefile.parallel-ios ai-task-init"
  source "$env_link"
  : "${TASK_ID:?invalid task environment}"
  : "${TASK_STATE:?invalid task environment}"
  : "${WORKTREE_PATH:?invalid task environment}"
  : "${DERIVED_DATA_PATH:?invalid task environment}"
  : "${RESULTS_PATH:?invalid task environment}"
  : "${SIMULATOR_UDID:?invalid task environment}"
  BRANCH_NAME="${BRANCH_NAME:-$(git -C "$REPO_ROOT" branch --show-current)}"
  local expected_state="${STATE_ROOT:A}/tasks/$TASK_ID"
  [[ "${TASK_STATE:A}" == "$expected_state" ]] || die "task state is outside the configured state root"
  [[ "${DERIVED_DATA_PATH:A}" == "$expected_state/DerivedData" ]] || die "invalid DerivedData path in task environment"
  [[ "${RESULTS_PATH:A}" == "$expected_state/Results" ]] || die "invalid Results path in task environment"
  [[ "${env_link:A}" == "$expected_state/env.zsh" ]] || die "task environment link points to an unexpected file"
  [[ "${WORKTREE_PATH:A}" == "${REPO_ROOT:A}" ]] || die "task environment belongs to another worktree: $WORKTREE_PATH"
}

ensure_task_env() {
  if [[ ! -r "$REPO_ROOT/.parallel-ios-env" ]]; then
    [[ "${REPO_ROOT:A}" != "${MAIN_REPO_ROOT:A}" ]] || die "the main worktree is not auto-managed; create or enter a task worktree first"
    note "initializing this existing worktree and allocating its dedicated simulator"
    "$SCRIPT_DIR/task-init.zsh"
  fi
  load_task_env
}

task_env_path() {
  local task_id="$1"
  [[ "$task_id" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "invalid TASK id: $task_id"
  print -r -- "$STATE_ROOT/tasks/$task_id/env.zsh"
}

simulator_exists() {
  local udid="$1"
  xcrun simctl list devices -j | grep -Fq "$udid"
}

create_task_simulator() {
  local task_id="$1"
  local sim_name="${IOS_SIMULATOR_NAME_PREFIX:-AI}-${MAIN_REPO_ROOT:t}-$task_id"
  local udid
  if [[ -n "${SIM_TEMPLATE_UDID:-}" ]]; then
    simulator_exists "$SIM_TEMPLATE_UDID" || die "template simulator not found: $SIM_TEMPLATE_UDID"
    udid="$(xcrun simctl clone "$SIM_TEMPLATE_UDID" "$sim_name")"
  else
    : "${SIM_DEVICE_TYPE_ID:?set SIM_DEVICE_TYPE_ID in parallel-ios.conf}"
    : "${SIM_RUNTIME_ID:?set SIM_RUNTIME_ID in parallel-ios.conf}"
    udid="$(xcrun simctl create "$sim_name" "$SIM_DEVICE_TYPE_ID" "$SIM_RUNTIME_ID")"
  fi
  [[ -n "$udid" ]] || die "simctl did not return a simulator UDID"
  print -r -- "$sim_name|$udid"
}

write_task_env() {
  local env_path="$TASK_STATE/env.zsh"
  {
    print -r -- "TASK_ID=${(q)TASK_ID}"
    print -r -- "TASK_STATE=${(q)TASK_STATE}"
    print -r -- "WORKTREE_PATH=${(q)WORKTREE_PATH}"
    print -r -- "DERIVED_DATA_PATH=${(q)DERIVED_DATA_PATH}"
    print -r -- "RESULTS_PATH=${(q)RESULTS_PATH}"
    print -r -- "SIMULATOR_UDID=${(q)SIMULATOR_UDID}"
    print -r -- "SIMULATOR_NAME=${(q)SIMULATOR_NAME}"
    print -r -- "BRANCH_NAME=${(q)BRANCH_NAME}"
  } > "$env_path"
}

ensure_task_simulator() {
  simulator_exists "$SIMULATOR_UDID" && return 0
  note "recorded simulator is missing; allocating a replacement for $TASK_ID"
  local created
  created="$(create_task_simulator "$TASK_ID")"
  SIMULATOR_NAME="${created%%|*}"
  SIMULATOR_UDID="${created#*|}"
  if ! write_task_env; then
    xcrun simctl delete "$SIMULATOR_UDID" >/dev/null 2>&1 || true
    die "failed to record replacement simulator"
  fi
}

set_package_args() {
  PACKAGE_CACHE_PATH="$SHARED_ROOT/PackageCache"
  case "${IOS_PACKAGE_MODE:-isolated}" in
    isolated)
      CLONED_SOURCE_PACKAGES_PATH="$TASK_STATE/SourcePackages"
      ;;
    shared-locked)
      CLONED_SOURCE_PACKAGES_PATH="$SHARED_ROOT/SourcePackages"
      ;;
    *)
      die "IOS_PACKAGE_MODE must be isolated or shared-locked"
      ;;
  esac
  PACKAGE_ARGS=(
    -clonedSourcePackagesDirPath "$CLONED_SOURCE_PACKAGES_PATH"
    -packageCachePath "$PACKAGE_CACHE_PATH"
  )
}

ensure_task_dirs() {
  mkdir -p "$DERIVED_DATA_PATH" "$RESULTS_PATH" "$PACKAGE_CACHE_PATH" "$CLONED_SOURCE_PACKAGES_PATH" "$BUILD_SLOT_ROOT"
}

package_fingerprint() {
  {
    git -C "$REPO_ROOT" ls-files -z -- '*Package.resolved' |
      while IFS= read -r -d '' file; do
        print -rn -- "$file\0"
        shasum -a 256 "$REPO_ROOT/$file" | awk '{print $1}'
        print -rn -- "\0"
      done
  } | shasum -a 256 | awk '{print $1}'
}

verify_shared_package_fingerprint() {
  [[ "${IOS_PACKAGE_MODE:-isolated}" == "shared-locked" ]] || return 0
  local marker="$SHARED_ROOT/SourcePackages.package-fingerprint"
  [[ -r "$marker" ]] || die "shared SourcePackages is not prepared; run make ai-resolve"
  local expected="$(<"$marker")"
  local actual="$(package_fingerprint)"
  [[ "$expected" == "$actual" ]] || die "Package.resolved differs from shared SourcePackages; use isolated mode or pause builds and run make ai-resolve"
}

configure_audited_macro_validation() {
  local trusted_identity="equatable"
  local trusted_revision="597c2bb34af0c51331eb3b5e705f942d8ee20daa"
  local trusted_checkout="$CLONED_SOURCE_PACKAGES_PATH/checkouts/$trusted_identity"
  local trusted_manifest="$trusted_checkout/Package.swift"
  local macro_manifests=()
  local manifest

  for manifest in "$CLONED_SOURCE_PACKAGES_PATH"/checkouts/*/Package*.swift(N); do
    rg -q '^[[:space:]]*\.macro\(' "$manifest" && macro_manifests+=("$manifest")
  done

  if (( ${#macro_manifests[@]} == 0 )); then
    MACRO_VALIDATION_ARGS=()
    return 0
  fi

  (( ${#macro_manifests[@]} == 1 )) || die "unreviewed Swift package macros detected; audit Package.resolved before building"
  [[ "${macro_manifests[1]:A}" == "${trusted_manifest:A}" ]] || die "unreviewed Swift package macro detected: ${macro_manifests[1]}"
  [[ -d "$trusted_checkout/.git" ]] || die "trusted macro checkout is missing Git metadata: $trusted_checkout"

  local actual_revision="$(git -C "$trusted_checkout" rev-parse HEAD 2>/dev/null)"
  [[ "$actual_revision" == "$trusted_revision" ]] || die "trusted macro revision changed: expected $trusted_revision, got $actual_revision"
  [[ -z "$(git -C "$trusted_checkout" status --porcelain)" ]] || die "trusted macro checkout contains local modifications"

  # xcodebuild 无法持久化 Xcode UI 的单宏授权。仅在上述唯一宏来源和提交均通过审计后，
  # 为当前非交互构建跳过授权提示；Package.resolved 或宏源码变化都会在这里先失败。
  MACRO_VALIDATION_ARGS=(-skipMacroValidation)
}

clear_stale_lock() {
  local lock_dir="$1"
  local pid_file="$lock_dir/pid"
  [[ -d "$lock_dir" && -r "$pid_file" ]] || return 1
  local owner_pid="$(<"$pid_file")"
  if [[ "$owner_pid" == <-> ]] && ! kill -0 "$owner_pid" 2>/dev/null; then
    rm -f "$pid_file"
    rmdir "$lock_dir" 2>/dev/null || true
    return 0
  fi
  return 1
}

wait_for_maintenance() {
  local maintenance="$LOCK_ROOT/maintenance"
  while [[ -d "$maintenance" ]]; do
    clear_stale_lock "$maintenance" || true
    [[ -d "$maintenance" ]] || break
    note "package maintenance is active; waiting"
    sleep 1
  done
}

release_build_slot() {
  [[ -n "${BUILD_SLOT:-}" ]] || return 0
  rm -f "$BUILD_SLOT/pid"
  rmdir "$BUILD_SLOT" 2>/dev/null || true
  BUILD_SLOT=""
}

acquire_build_slot() {
  local limit="${TOP_LEVEL_BUILD_LIMIT:-2}"
  [[ "$limit" == <-> && "$limit" -ge 1 ]] || die "TOP_LEVEL_BUILD_LIMIT must be a positive integer"
  mkdir -p "$BUILD_SLOT_ROOT"

  while true; do
    wait_for_maintenance
    local index slot
    for (( index=1; index<=limit; index++ )); do
      slot="$BUILD_SLOT_ROOT/slot-$index"
      clear_stale_lock "$slot" || true
      if mkdir "$slot" 2>/dev/null; then
        print -r -- "$$" > "$slot/pid"
        BUILD_SLOT="$slot"
        if [[ -d "$LOCK_ROOT/maintenance" ]]; then
          release_build_slot
          break
        fi
        trap 'release_build_slot' EXIT INT TERM
        note "using top-level build slot $index/$limit"
        return 0
      fi
    done
    sleep 1
  done
}

acquire_exclusive_lock() {
  local lock_dir="$1"
  mkdir -p "${lock_dir:h}"
  while true; do
    clear_stale_lock "$lock_dir" || true
    if mkdir "$lock_dir" 2>/dev/null; then
      print -r -- "$$" > "$lock_dir/pid"
      EXCLUSIVE_LOCK="$lock_dir"
      trap 'release_exclusive_lock' EXIT INT TERM
      return 0
    fi
    note "waiting for lock ${lock_dir:t}"
    sleep 1
  done
}

release_exclusive_lock() {
  [[ -n "${EXCLUSIVE_LOCK:-}" ]] || return 0
  rm -f "$EXCLUSIVE_LOCK/pid"
  rmdir "$EXCLUSIVE_LOCK" 2>/dev/null || true
  EXCLUSIVE_LOCK=""
}

acquire_package_maintenance() {
  acquire_exclusive_lock "$LOCK_ROOT/maintenance"
  mkdir -p "$BUILD_SLOT_ROOT"
  while true; do
    local active=("$BUILD_SLOT_ROOT"/slot-*(N))
    local slot
    for slot in "${active[@]}"; do
      clear_stale_lock "$slot" || true
    done
    active=("$BUILD_SLOT_ROOT"/slot-*(N))
    (( ${#active[@]} == 0 )) && return 0
    note "waiting for ${#active[@]} active build(s) before shared package maintenance"
    sleep 1
  done
}

result_bundle_path() {
  local kind="$1"
  print -r -- "$RESULTS_PATH/${kind}-$(date +%Y%m%d-%H%M%S)-$$.xcresult"
}

common_build_args() {
  configure_audited_macro_validation
  COMMON_BUILD_ARGS=(
    "${XCODE_CONTAINER_ARGS[@]}"
    -scheme "$IOS_SCHEME"
    -configuration "$IOS_CONFIGURATION"
    -derivedDataPath "$DERIVED_DATA_PATH"
    "${PACKAGE_ARGS[@]}"
    -onlyUsePackageVersionsFromResolvedFile
    -skipPackageUpdates
    "${MACRO_VALIDATION_ARGS[@]}"
    -jobs "${XCODEBUILD_JOBS:-4}"
    "COMPILATION_CACHE_ENABLE_CACHING=${IOS_COMPILATION_CACHE:-YES}"
    "COMPILATION_CACHE_ENABLE_DIAGNOSTIC_REMARKS=${IOS_COMPILATION_CACHE_DIAGNOSTICS:-NO}"
  )
}
