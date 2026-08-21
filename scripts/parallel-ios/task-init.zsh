#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/lib.zsh"

[[ "${REPO_ROOT:A}" != "${MAIN_REPO_ROOT:A}" ]] || die "refusing to manage the main worktree; create or enter a separate worktree"

if [[ -r "$REPO_ROOT/.parallel-ios-env" ]]; then
  load_task_env
  ensure_task_simulator
  print -r -- "Already initialized: $TASK_ID"
  print -r -- "Simulator:          $SIMULATOR_NAME ($SIMULATOR_UDID)"
  exit 0
fi

TASK_ID="${1:-}"
if [[ -z "$TASK_ID" ]]; then
  CURRENT_BRANCH="$(git -C "$REPO_ROOT" branch --show-current)"
  if [[ -n "$CURRENT_BRANCH" ]]; then
    RAW_TASK_ID="$CURRENT_BRANCH"
  else
    # Codex-managed worktrees are commonly detached and share the same repository basename.
    # Preserve a readable parent identifier plus a stable path hash to avoid task collisions.
    WORKTREE_PARENT_SLUG="$(
      print -r -- "${REPO_ROOT:h:t}" |
        LC_ALL=C tr '[:upper:]_/' '[:lower:]--' |
        sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-//; s/-$//' |
        cut -c1-24
    )"
    [[ -n "$WORKTREE_PARENT_SLUG" ]] || WORKTREE_PARENT_SLUG="worktree"
    WORKTREE_PATH_HASH="$(print -rn -- "${REPO_ROOT:A}" | shasum -a 256 | cut -c1-8)"
    RAW_TASK_ID="detached-$WORKTREE_PARENT_SLUG-$WORKTREE_PATH_HASH"
  fi
  TASK_ID="$(print -r -- "$RAW_TASK_ID" | LC_ALL=C tr '[:upper:]_/' '[:lower:]--' | sed -E 's/[^a-z0-9-]+/-/g; s/-+/-/g; s/^-//; s/-$//' | cut -c1-48)"
fi
[[ "$TASK_ID" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]] || die "TASK must contain lowercase letters, digits, and single hyphens"
(( ${#TASK_ID} <= 48 )) || die "TASK must be 48 characters or fewer"

TASK_STATE="$STATE_ROOT/tasks/$TASK_ID"
WORKTREE_PATH="$REPO_ROOT"
BRANCH_NAME="$(git -C "$REPO_ROOT" branch --show-current)"
DERIVED_DATA_PATH="$TASK_STATE/DerivedData"
RESULTS_PATH="$TASK_STATE/Results"
ENV_PATH="$TASK_STATE/env.zsh"

if [[ -r "$ENV_PATH" ]]; then
  source "$ENV_PATH"
  [[ "${WORKTREE_PATH:A}" == "${REPO_ROOT:A}" ]] || die "TASK id '$TASK_ID' is already owned by $WORKTREE_PATH; pass a different TASK"
  ln -s "$ENV_PATH" "$REPO_ROOT/.parallel-ios-env"
  ensure_task_simulator
  print -r -- "Reattached task:    $TASK_ID"
  print -r -- "Simulator:          $SIMULATOR_NAME ($SIMULATOR_UDID)"
  exit 0
fi
[[ ! -e "$TASK_STATE" ]] || die "task state exists without a readable environment: $TASK_STATE"
[[ ! -e "$REPO_ROOT/.parallel-ios-env" && ! -L "$REPO_ROOT/.parallel-ios-env" ]] || die "unexpected .parallel-ios-env already exists"

mkdir -p "$TASK_STATE" "$DERIVED_DATA_PATH" "$RESULTS_PATH"
SIMULATOR_UDID=""
cleanup_failed_init() {
  local exit_code=$?
  (( exit_code == 0 )) && return 0
  note "task initialization failed; rolling back newly allocated resources"
  [[ -n "$SIMULATOR_UDID" ]] && xcrun simctl delete "$SIMULATOR_UDID" >/dev/null 2>&1 || true
  [[ -L "$REPO_ROOT/.parallel-ios-env" ]] && rm -f "$REPO_ROOT/.parallel-ios-env"
  [[ -d "$TASK_STATE" ]] && rm -rf "$TASK_STATE"
  return $exit_code
}
trap cleanup_failed_init EXIT

CREATED_SIM="$(create_task_simulator "$TASK_ID")"
SIMULATOR_NAME="${CREATED_SIM%%|*}"
SIMULATOR_UDID="${CREATED_SIM#*|}"
write_task_env
ln -s "$ENV_PATH" "$REPO_ROOT/.parallel-ios-env"

trap - EXIT
print -r -- "Initialized task:   $TASK_ID"
print -r -- "Worktree:           $WORKTREE_PATH"
print -r -- "Simulator:          $SIMULATOR_NAME ($SIMULATOR_UDID)"
print -r -- "DerivedData:        $DERIVED_DATA_PATH"
