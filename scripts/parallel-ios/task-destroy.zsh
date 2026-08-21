#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/lib.zsh"

REQUESTED_TASK="${1:-}"
if [[ -r "$REPO_ROOT/.parallel-ios-env" ]]; then
  load_task_env
  [[ -z "$REQUESTED_TASK" || "$REQUESTED_TASK" == "$TASK_ID" ]] || die "current worktree is task $TASK_ID, not $REQUESTED_TASK"
elif [[ -n "$REQUESTED_TASK" ]]; then
  ENV_PATH="$(task_env_path "$REQUESTED_TASK")"
  [[ -r "$ENV_PATH" ]] || die "task state not found: $ENV_PATH"
  source "$ENV_PATH"
  : "${TASK_ID:?invalid task environment}"
  : "${TASK_STATE:?invalid task environment}"
  : "${WORKTREE_PATH:?invalid task environment}"
  : "${SIMULATOR_UDID:?invalid task environment}"
  BRANCH_NAME="${BRANCH_NAME:-unknown}"
  [[ "$TASK_ID" == "$REQUESTED_TASK" ]] || die "task state id mismatch"
  [[ "${TASK_STATE:A}" == "${STATE_ROOT:A}/tasks/$TASK_ID" ]] || die "task state is outside the configured state root"
else
  die "run this from a managed task worktree, or pass TASK=<id> from the main worktree"
fi

[[ "${WORKTREE_PATH:A}" != "${MAIN_REPO_ROOT:A}" ]] || die "refusing to remove the main worktree"

CLEANUP_POLICY="${IOS_TASK_CLEANUP_POLICY:-delete}"
case "$CLEANUP_POLICY" in
  delete|trash|keep) ;;
  *) die "IOS_TASK_CLEANUP_POLICY must be delete, trash, or keep" ;;
esac

if [[ -d "$WORKTREE_PATH" ]]; then
  if [[ -n "$(git -C "$WORKTREE_PATH" status --porcelain)" ]]; then
    die "worktree has uncommitted or untracked changes; commit, stash, or remove them before cleanup"
  fi
  cd "$MAIN_REPO_ROOT"
  git worktree remove "$WORKTREE_PATH"
else
  note "worktree is already absent; continuing resource cleanup"
fi

if simulator_exists "$SIMULATOR_UDID"; then
  note "shutting down and deleting only simulator $SIMULATOR_UDID"
  xcrun simctl shutdown "$SIMULATOR_UDID" >/dev/null 2>&1 || true
  xcrun simctl delete "$SIMULATOR_UDID"
fi
simulator_exists "$SIMULATOR_UDID" && die "simulator still exists; task state was retained so cleanup can be retried"

case "$CLEANUP_POLICY" in
  delete)
    [[ "${TASK_STATE:A}" == "${STATE_ROOT:A}/tasks/$TASK_ID" ]] || die "refusing to delete unexpected task state path"
    rm -rf -- "$TASK_STATE"
    STATE_MESSAGE="Task-local state, including DerivedData and Results, was deleted."
    ;;
  trash)
    mkdir -p "$STATE_ROOT/trash"
    TRASH_PATH="$STATE_ROOT/trash/$TASK_ID-$(date +%Y%m%d-%H%M%S)"
    mv "$TASK_STATE" "$TRASH_PATH"
    STATE_MESSAGE="Task-local build state was moved to $TRASH_PATH"
    ;;
  keep)
    STATE_MESSAGE="Task-local build state was retained at $TASK_STATE"
    ;;
esac

print -r -- "Removed worktree and dedicated simulator."
print -r -- "$STATE_MESSAGE"
print -r -- "Shared package downloads and Xcode CAS were retained."
print -r -- "Branch $BRANCH_NAME, if present, was retained. Delete it separately only after merge."
