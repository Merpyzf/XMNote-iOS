#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/xmnote.xcodeproj"
SCHEME="xmnote"
DESTINATION="${LINT_DESTINATION:-}"

if [[ -z "$DESTINATION" ]]; then
    # 默认跟随当前 booted 模拟器；多台 booted 时使用 simctl 输出中的第一台。
    BOOTED_SIMULATOR_ID="$(
        xcrun simctl list devices booted |
            sed -nE 's/.*\(([0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12})\) \(Booted\).*/\1/p' |
            head -n 1
    )"

    if [[ -z "$BOOTED_SIMULATOR_ID" ]]; then
        echo "ERROR: 未找到已启动的 iOS 模拟器，请先启动一个模拟器或设置 LINT_DESTINATION。"
        exit 1
    fi

    DESTINATION="platform=iOS Simulator,id=${BOOTED_SIMULATOR_ID}"
fi

if [[ ! -d "$PROJECT_PATH" ]]; then
    echo "ERROR: 未找到工程文件: $PROJECT_PATH"
    exit 1
fi

log_file="$(mktemp)"
trap 'rm -f "$log_file"' EXIT

set +e
xcodebuild -project "$PROJECT_PATH" -scheme "$SCHEME" -destination "$DESTINATION" clean build >"$log_file" 2>&1
build_status=$?
set -e

# 仅关注仓库源码文件中的 warning/error，忽略 xcodebuild 工具噪声。
source_issues="$( (rg -n "warning:|error:" "$log_file" || true) | rg "$ROOT_DIR/(xmnote|xmnoteTests|xmnoteUITests)/" || true )"

if [[ -n "$source_issues" ]]; then
    echo "FAIL: 发现源码告警或错误"
    echo "$source_issues"
    exit 1
fi

if [[ "$build_status" -ne 0 ]]; then
    echo "FAIL: 构建失败（未命中源码 warning/error 过滤条件），请检查完整日志。"
    tail -n 120 "$log_file"
    exit "$build_status"
fi

echo "OK: 源码 lint 警告检查通过（仅系统工具噪声已忽略）。"
