#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
START_MARKER="<!-- AUTO_SYNC_MODULES_START -->"
END_MARKER="<!-- AUTO_SYNC_MODULES_END -->"

TARGET_FILES=(
    "$ROOT_DIR/AGENTS.md"
    "$ROOT_DIR/CLAUDE.md"
)

MODE="apply"
if [[ "${1:-}" == "--check" ]]; then
    MODE="check"
fi

tmp_generated="$(mktemp)"

cleanup() {
    rm -f "$tmp_generated"
}
trap cleanup EXIT

generate_module_block() {
    {
        echo "$START_MARKER"
        echo "- 由 \`scripts/sync_arch_docs.sh\` 自动维护，请勿手工修改。"
        find "$ROOT_DIR/xmnote" -mindepth 1 -maxdepth 1 -type d \
            ! -name "*.xcassets" \
            | sed "s#^$ROOT_DIR/xmnote/##" \
            | sort \
            | while IFS= read -r module; do
                [[ -z "${module:-}" ]] && continue
                echo "- \`xmnote/$module\`"
            done
        echo "$END_MARKER"
    } > "$tmp_generated"
}

extract_block() {
    local file="$1"
    sed -n "/$START_MARKER/,/$END_MARKER/p" "$file"
}

ensure_markers_exist() {
    local file="$1"
    if ! grep -Fq "$START_MARKER" "$file"; then
        echo "ERROR: $file 缺少起始标记 $START_MARKER"
        exit 1
    fi
    if ! grep -Fq "$END_MARKER" "$file"; then
        echo "ERROR: $file 缺少结束标记 $END_MARKER"
        exit 1
    fi
}

apply_block() {
    local file="$1"
    local tmp_file
    tmp_file="$(mktemp)"
    awk -v start="$START_MARKER" -v end="$END_MARKER" -v block="$tmp_generated" '
        BEGIN {
            while ((getline line < block) > 0) {
                generated[++n] = line
            }
        }
        {
            if (index($0, start)) {
                for (i = 1; i <= n; i++) {
                    print generated[i]
                }
                skipping = 1
                next
            }
            if (skipping && index($0, end)) {
                skipping = 0
                next
            }
            if (!skipping) {
                print $0
            }
        }
    ' "$file" > "$tmp_file"
    mv "$tmp_file" "$file"
}

generate_module_block

failed=0
for file in "${TARGET_FILES[@]}"; do
    ensure_markers_exist "$file"
    if [[ "$MODE" == "check" ]]; then
        current_block="$(mktemp)"
        extract_block "$file" > "$current_block"
        if ! cmp -s "$tmp_generated" "$current_block"; then
            echo "OUT_OF_SYNC: $file"
            failed=1
        fi
        rm -f "$current_block"
    else
        apply_block "$file"
        echo "SYNCED: $file"
    fi
done

if [[ "$MODE" == "check" ]]; then
    if [[ "$failed" -ne 0 ]]; then
        echo "FAIL: 架构文档模块清单未同步，请执行 bash scripts/sync_arch_docs.sh"
        exit 1
    fi
    echo "OK: 架构文档模块清单已同步。"
fi
