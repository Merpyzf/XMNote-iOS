#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/lib.zsh"

TASK_ID="${1:-}"
[[ "$TASK_ID" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "TASK must contain lowercase letters, digits, and single hyphens"
(( ${#TASK_ID} <= 48 )) || die "TASK must be 48 characters or fewer"

BASE_REF="${2:-}"
[[ -n "$BASE_REF" ]] || BASE_REF="$(git -C "$REPO_ROOT" rev-parse HEAD)"

TASK_STATE="$STATE_ROOT/tasks/$TASK_ID"
WORKTREE_PATH="$WORKTREE_PARENT/$TASK_ID"
BRANCH_NAME="${IOS_TASK_BRANCH_PREFIX:-codex/}$TASK_ID"
git check-ref-format --branch "$BRANCH_NAME" >/dev/null 2>&1 || die "invalid task branch name: $BRANCH_NAME"
[[ ! -e "$TASK_STATE" ]] || die "task state already exists: $TASK_STATE"
[[ ! -e "$WORKTREE_PATH" ]] || die "worktree path already exists: $WORKTREE_PATH"

mkdir -p "$STATE_ROOT/tasks" "$WORKTREE_PARENT"
git -C "$MAIN_REPO_ROOT" worktree add -b "$BRANCH_NAME" "$WORKTREE_PATH" "$BASE_REF"

SIMULATOR_UDID=""
cleanup_failed_create() {
  local exit_code=$?
  (( exit_code == 0 )) && return 0
  note "task creation failed; rolling back newly created resources"
  [[ -n "$SIMULATOR_UDID" ]] && xcrun simctl delete "$SIMULATOR_UDID" >/dev/null 2>&1 || true
  [[ -L "$WORKTREE_PATH/.parallel-ios-env" ]] && rm -f "$WORKTREE_PATH/.parallel-ios-env"
  git -C "$MAIN_REPO_ROOT" worktree remove "$WORKTREE_PATH" >/dev/null 2>&1 || true
  [[ "${TASK_STATE:A}" == "${STATE_ROOT:A}/tasks/$TASK_ID" ]] && rm -rf -- "$TASK_STATE"
  note "branch $BRANCH_NAME was retained for manual inspection"
  return $exit_code
}
trap cleanup_failed_create EXIT

CREATED_SIM="$(create_task_simulator "$TASK_ID")"
SIMULATOR_NAME="${CREATED_SIM%%|*}"
SIMULATOR_UDID="${CREATED_SIM#*|}"

mkdir -p "$TASK_STATE/DerivedData" "$TASK_STATE/Results"
ENV_PATH="$TASK_STATE/env.zsh"
DERIVED_DATA_PATH="$TASK_STATE/DerivedData"
RESULTS_PATH="$TASK_STATE/Results"
write_task_env
ln -s "$ENV_PATH" "$WORKTREE_PATH/.parallel-ios-env"

trap - EXIT
print -r -- "Created task:       $TASK_ID"
print -r -- "Branch:             $BRANCH_NAME"
print -r -- "Worktree:           $WORKTREE_PATH"
print -r -- "Simulator:          $SIMULATOR_NAME ($SIMULATOR_UDID)"
print -r -- "DerivedData:        $TASK_STATE/DerivedData"
print -r -- "Next: cd ${(q)WORKTREE_PATH} && make -f Makefile.parallel-ios ai-run"
