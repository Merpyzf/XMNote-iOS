#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="$ROOT_DIR/xmnote"

check_no_match() {
    local pattern="$1"
    local description="$2"
    local result
    result="$(rg -n "$pattern" "$TARGET_DIR" --glob '*.swift' || true)"
    if [[ -n "$result" ]]; then
        echo "FAIL: $description"
        echo "$result"
        exit 1
    fi
}

# 1) 禁止硬编码 cornerRadius 数值
check_no_match "cornerRadius:\\s*[0-9]+(\\.[0-9]+)?" "发现硬编码 cornerRadius 数值，请改为 CornerRadius token。"

# 2) 禁止 RoundedRectangle 圆角不声明 .continuous 风格
non_continuous="$(
    rg -n "RoundedRectangle\\(cornerRadius:" "$TARGET_DIR" --glob '*.swift' \
    | rg -v "style:\\s*\\.continuous" \
    || true
)"
if [[ -n "$non_continuous" ]]; then
    echo "FAIL: 发现未显式使用 .continuous 的 RoundedRectangle。"
    echo "$non_continuous"
    exit 1
fi

# 3) 禁止 UIKit layer.cornerRadius 使用数值
check_no_match "layer\\.cornerRadius\\s*=\\s*([0-9]+(\\.[0-9]+)?|.*\\?\\s*[0-9]+(\\.[0-9]+)?\\s*:\\s*[0-9]+(\\.[0-9]+)?)" "发现 UIKit layer.cornerRadius 硬编码数值，请改为 CornerRadius token。"

echo "OK: 圆角 token 规范校验通过。"
