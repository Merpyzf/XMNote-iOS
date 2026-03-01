#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GLOSSARY_FILE="$ROOT_DIR/docs/architecture/术语对照表.md"

if [[ ! -f "$GLOSSARY_FILE" ]]; then
    echo "ERROR: 未找到术语表文件: $GLOSSARY_FILE"
    exit 1
fi

tmp_path_category_map="$(mktemp)"
tmp_view_components="$(mktemp)"
tmp_view_sheets="$(mktemp)"

cleanup() {
    rm -f "$tmp_path_category_map" "$tmp_view_components" "$tmp_view_sheets"
}
trap cleanup EXIT

awk -F'|' '
    function trim(s) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
        return s
    }
    /^\|/ {
        source = trim($7)
        category = trim($8)

        if (source == "" || source == "代码锚点" || source ~ /^-+$/) {
            next
        }
        if (category == "" || category == "类别" || category ~ /^-+$/) {
            next
        }
        print source "\t" category
    }
' "$GLOSSARY_FILE" | sort -u > "$tmp_path_category_map"

find "$ROOT_DIR/xmnote/Views" -type f -path "*/Components/*.swift" \
    | sed "s#^$ROOT_DIR/##" \
    | sort -u > "$tmp_view_components"

find "$ROOT_DIR/xmnote/Views" -type f -path "*/Sheets/*.swift" \
    | sed "s#^$ROOT_DIR/##" \
    | sort -u > "$tmp_view_sheets"

missing=0

# 校验页面私有子视图：必须在术语表中，且类别为 UI-页面私有
while IFS= read -r relative_path; do
    [[ -z "${relative_path:-}" ]] && continue
    category="$(awk -F'\t' -v p="$relative_path" '$1 == p { print $2; exit }' "$tmp_path_category_map")"
    if [[ -z "${category:-}" ]]; then
        echo "MISSING_LOCAL_UI_GLOSSARY: $relative_path"
        missing=1
        continue
    fi
    if [[ "$category" != "UI-页面私有" ]]; then
        echo "INVALID_LOCAL_UI_CATEGORY: $relative_path expected=UI-页面私有 actual=$category"
        missing=1
    fi
done < "$tmp_view_components"

# 校验业务 Sheet：必须包含 L3 协议语句
protocol_line="[PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md"
while IFS= read -r relative_path; do
    [[ -z "${relative_path:-}" ]] && continue
    absolute_path="$ROOT_DIR/$relative_path"
    if ! grep -Fq "$protocol_line" "$absolute_path"; then
        echo "MISSING_SHEET_PROTOCOL_HEADER: $relative_path"
        missing=1
    fi
done < "$tmp_view_sheets"

# 防止页面壳层误放入 UIComponents（以 ReadCalendar 页面族为硬约束）
misplaced_read_calendar_pages="$(find "$ROOT_DIR/xmnote/UIComponents" -type f -name 'ReadCalendar*View.swift' | wc -l | tr -d ' ')"
if [[ "${misplaced_read_calendar_pages:-0}" != "0" ]]; then
    find "$ROOT_DIR/xmnote/UIComponents" -type f -name 'ReadCalendar*View.swift' | sed "s#^$ROOT_DIR/##" | while IFS= read -r path; do
        echo "MISPLACED_PAGE_SHELL_IN_UICOMPONENTS: $path"
    done
    missing=1
fi

if [[ "$missing" -ne 0 ]]; then
    echo "FAIL: 页面组件目录边界校验失败，请修复页面壳层/页面私有子视图/业务 Sheet 的归位问题。"
    exit 1
fi

component_count="$(wc -l < "$tmp_view_components" | tr -d ' ')"
sheet_count="$(wc -l < "$tmp_view_sheets" | tr -d ' ')"
echo "OK: 页面组件目录边界校验通过（页面私有子视图 $component_count 个，业务 Sheet $sheet_count 个）。"
