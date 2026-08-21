#!/usr/bin/env bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$REPOSITORY_ROOT/xmnote.xcodeproj"
SCHEME="xmnote"
SIMULATOR_NAME="XMNote · 38f4 · highlight-import"

SIMULATOR_ID="$({
    xcrun simctl list devices booted |
        sed -nE "s/^[[:space:]]*${SIMULATOR_NAME//./\\.} \(([0-9A-F-]+)\) \(Booted\).*/\1/p" |
        head -n 1
} || true)"

if [[ -z "$SIMULATOR_ID" ]]; then
    echo "ERROR: 未找到已启动的 38f4 专用模拟器：$SIMULATOR_NAME"
    exit 1
fi

xcrun simctl bootstatus "$SIMULATOR_ID" -b

if rg -n "数据导入" "$REPOSITORY_ROOT/xmnote"; then
    echo "ERROR: 仍存在用户可见或代码内的旧名称「数据导入」"
    exit 1
fi

"$REPOSITORY_ROOT/scripts/import_alignment/run_android_oracle.sh"

xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
    CODE_SIGNING_ALLOWED=NO \
    -only-testing:xmnoteTests/ImportParserParityTests \
    -only-testing:xmnoteTests/NoteImportAlignmentTests \
    -only-testing:xmnoteTests/WereadImportAlignmentTests \
    -only-testing:xmnoteTests/KindleImportGatewayTests \
    test

xcodebuild \
    -project "$PROJECT_PATH" \
    -scheme "$SCHEME" \
    -destination "platform=iOS Simulator,id=$SIMULATOR_ID" \
    CODE_SIGNING_ALLOWED=NO \
    build

echo "OK: Android 源码闭包、Oracle/Golden、关键流程测试与 38f4 模拟器构建全部通过。"
