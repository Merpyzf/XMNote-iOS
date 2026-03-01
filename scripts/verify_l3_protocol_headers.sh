#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TARGET_DIR="$ROOT_DIR/xmnote"
PROTOCOL_LINE="[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md"

if [[ ! -d "$TARGET_DIR" ]]; then
    echo "ERROR: 未找到目标目录: $TARGET_DIR"
    exit 1
fi

missing=0
checked=0

while IFS= read -r swift_file; do
    [[ -z "${swift_file:-}" ]] && continue
    checked=$((checked + 1))
    if ! grep -Fq "$PROTOCOL_LINE" "$swift_file"; then
        rel="${swift_file#$ROOT_DIR/}"
        echo "MISSING_L3_PROTOCOL_HEADER: $rel"
        missing=1
    fi
done < <(find "$TARGET_DIR" -type f -name '*.swift' | sort)

if [[ "$missing" -ne 0 ]]; then
    echo "FAIL: L3 头部协议校验失败，请补齐缺失文件的 INPUT/OUTPUT/POS/PROTOCOL 注释。"
    exit 1
fi

echo "OK: L3 头部协议校验通过（扫描 $checked 个 Swift 文件）。"
