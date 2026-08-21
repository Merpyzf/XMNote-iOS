#!/bin/zsh
set -euo pipefail
SCRIPT_DIR="${0:A:h}"
source "$SCRIPT_DIR/lib.zsh"
ensure_task_env
ensure_task_simulator

: "${IOS_APP_NAME:?set IOS_APP_NAME in parallel-ios.conf for ai-run}"
: "${IOS_BUNDLE_ID:?set IOS_BUNDLE_ID in parallel-ios.conf for ai-run}"

"$SCRIPT_DIR/build.zsh"
xcrun simctl bootstatus "$SIMULATOR_UDID" -b

APP_PATH="$DERIVED_DATA_PATH/Build/Products/${IOS_CONFIGURATION}-iphonesimulator/$IOS_APP_NAME"
[[ -d "$APP_PATH" ]] || die "built app not found at $APP_PATH"

xcrun simctl terminate "$SIMULATOR_UDID" "$IOS_BUNDLE_ID" >/dev/null 2>&1 || true
xcrun simctl install "$SIMULATOR_UDID" "$APP_PATH"
xcrun simctl launch "$SIMULATOR_UDID" "$IOS_BUNDLE_ID"

print -r -- "Launched $IOS_BUNDLE_ID on $SIMULATOR_NAME ($SIMULATOR_UDID)"
