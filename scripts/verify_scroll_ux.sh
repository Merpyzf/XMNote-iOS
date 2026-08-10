#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/xmnote"
APP_ENTRY="$SOURCE_DIR/xmnoteApp.swift"
has_error=0

if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "ERROR: 未找到应用源码目录: $SOURCE_DIR"
    exit 1
fi

if rg -n --glob '*.swift' -F '.scrollBounceBehavior(.basedOnSize' "$SOURCE_DIR"; then
    echo "ERROR: 应用自有滚动容器禁止使用 .scrollBounceBehavior(.basedOnSize)。"
    has_error=1
fi

if rg -n --glob '*.swift' \
    -e 'alwaysBounceVertical[[:space:]]*=[[:space:]]*false' \
    -e 'alwaysBounceHorizontal[[:space:]]*=[[:space:]]*false' \
    -e '\.bounces[[:space:]]*=[[:space:]]*false' \
    "$SOURCE_DIR" \
    -g '!Vendor/**'; then
    echo "ERROR: 应用自有滚动容器禁止显式关闭回弹；Vendor 目录除外。"
    has_error=1
fi

if ! rg -U -q \
    '\.scrollBounceBehavior\([[:space:]]*\.always,[[:space:]]*axes:[[:space:]]*\[[[:space:]]*\.vertical,[[:space:]]*\.horizontal[[:space:]]*\][[:space:]]*\)' \
    "$APP_ENTRY"; then
    echo "ERROR: 应用根视图缺少纵向与横向的全局 .scrollBounceBehavior(.always) 策略。"
    has_error=1
fi

if (( has_error != 0 )); then
    exit 1
fi

echo "OK: 全局短内容回弹策略存在，未发现 .basedOnSize 或应用自有显式关闭回弹设置。"
