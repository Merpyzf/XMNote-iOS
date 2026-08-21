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

ACTION="${1:-test}"
case "$ACTION" in
  test|build-for-testing|test-without-building) ;;
  *) die "test action must be test, build-for-testing, or test-without-building" ;;
esac

acquire_build_slot
xcrun simctl bootstatus "$SIMULATOR_UDID" -b
RESULT_BUNDLE="$(result_bundle_path Test)"
TEST_FILTER_ARGS=()
if [[ -n "${ONLY_TESTING:-}" ]]; then
  TEST_FILTER_ARGS=(-only-testing "$ONLY_TESTING")
fi

xcodebuild \
  "${COMMON_BUILD_ARGS[@]}" \
  -destination "platform=iOS Simulator,id=$SIMULATOR_UDID" \
  -parallel-testing-enabled "${IOS_PARALLEL_TESTING:-NO}" \
  -maximum-concurrent-test-simulator-destinations "${IOS_TEST_SIMULATOR_LIMIT:-1}" \
  "${TEST_FILTER_ARGS[@]}" \
  -resultBundlePath "$RESULT_BUNDLE" \
  "$ACTION"

print -r -- "Test result: $RESULT_BUNDLE"
