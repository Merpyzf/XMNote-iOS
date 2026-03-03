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
tmp_sheet_named_files="$(mktemp)"

cleanup() {
    rm -f "$tmp_path_category_map" "$tmp_view_components" "$tmp_view_sheets" "$tmp_sheet_named_files"
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

find "$ROOT_DIR/xmnote/Views" -type f -name "*Sheet*.swift" \
    | sed "s#^$ROOT_DIR/##" \
    | sort -u > "$tmp_sheet_named_files"

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

# 校验业务 Sheet：命名含 Sheet 的文件必须放在 Sheets 目录
while IFS= read -r relative_path; do
    [[ -z "${relative_path:-}" ]] && continue
    if [[ "$relative_path" != *"/Sheets/"* ]]; then
        suggested_dir="$(echo "$relative_path" | sed -E 's#(.*/)[^/]+$#\1Sheets/#')"
        echo "MISPLACED_SHEET_FILE: $relative_path expected_dir=$suggested_dir"
        missing=1
    fi
done < "$tmp_sheet_named_files"

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

# 防止 Feature 私有组件误放入 UIComponents（当前以 ReadCalendar 私有组件为硬约束）
readonly feature_private_component_allowlist=(
    # 如未来确认跨模块复用，可在此添加白名单路径（相对仓库根目录）
    # "xmnote/UIComponents/Foundation/SomeSharedCalendarComponent.swift"
)

is_in_allowlist() {
    local candidate="$1"
    for allowed in "${feature_private_component_allowlist[@]}"; do
        if [[ "$candidate" == "$allowed" ]]; then
            return 0
        fi
    done
    return 1
}

while IFS= read -r absolute_path; do
    [[ -z "${absolute_path:-}" ]] && continue
    relative_path="${absolute_path#$ROOT_DIR/}"
    if is_in_allowlist "$relative_path"; then
        continue
    fi
    echo "MISPLACED_FEATURE_PRIVATE_COMPONENT_IN_UICOMPONENTS: $relative_path expected_dir=xmnote/Views/Reading/ReadCalendar/Components/"
    missing=1
done < <(
    find "$ROOT_DIR/xmnote/UIComponents" -type f \( \
        -name 'ReadCalendar*.swift' -o \
        -name 'CalendarMonthStepperBar.swift' -o \
        -name 'ReadCalendarMonthGrid.swift' \
    \)
)

if [[ "$missing" -ne 0 ]]; then
    echo "FAIL: 页面组件目录边界校验失败，请修复页面壳层/页面私有子视图/业务 Sheet 的归位问题。"
    exit 1
fi

component_count="$(wc -l < "$tmp_view_components" | tr -d ' ')"
sheet_count="$(wc -l < "$tmp_view_sheets" | tr -d ' ')"
sheet_named_count="$(wc -l < "$tmp_sheet_named_files" | tr -d ' ')"
echo "OK: 页面组件目录边界校验通过（页面私有子视图 $component_count 个，业务 Sheet 目录文件 $sheet_count 个，命名含 Sheet 文件 $sheet_named_count 个）。"
