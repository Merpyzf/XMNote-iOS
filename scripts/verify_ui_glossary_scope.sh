#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GLOSSARY_FILE="$ROOT_DIR/docs/architecture/术语对照表.md"
WHITELIST_FILE="$ROOT_DIR/docs/architecture/UI核心组件白名单.md"

if [[ ! -f "$GLOSSARY_FILE" ]]; then
    echo "ERROR: 未找到术语表文件: $GLOSSARY_FILE"
    exit 1
fi

if [[ ! -f "$WHITELIST_FILE" ]]; then
    echo "ERROR: 未找到 UI 白名单文件: $WHITELIST_FILE"
    exit 1
fi

tmp_glossary_map="$(mktemp)"
tmp_utility_views="$(mktemp)"
tmp_whitelist_paths="$(mktemp)"
tmp_whitelist_views="$(mktemp)"

cleanup() {
    rm -f "$tmp_glossary_map" "$tmp_utility_views" "$tmp_whitelist_paths" "$tmp_whitelist_views"
}
trap cleanup EXIT

awk -F'|' '
    /^\|/ {
        english = $4
        category = $8
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", english)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", category)
        if (english != "" && english != "英文术语" && english != "---") {
            print english "\t" category
        }
    }
' "$GLOSSARY_FILE" | sort -u > "$tmp_glossary_map"

grep -rn -E '^\s*(public\s+|internal\s+|open\s+)?(final\s+)?(struct|class)\s+[A-Za-z_][A-Za-z0-9_]*\s*.*:\s*.*View' \
    --include='*.swift' \
    "$ROOT_DIR/xmnote/UIComponents" \
| awk '{
    line = $0
    sub(/.*struct[[:space:]]+/, "", line)
    sub(/.*class[[:space:]]+/, "", line)
    match(line, /^[A-Za-z_][A-Za-z0-9_]*/)
    type = substr(line, RSTART, RLENGTH)
    match($0, /^[^:]+/)
    file = substr($0, RSTART, RLENGTH)
    if (type != "") print type "\t" file
}' \
| sort -u > "$tmp_utility_views"

sed -n 's/^- \(xmnote\/[^[:space:]]*\.swift\)$/\1/p' "$WHITELIST_FILE" > "$tmp_whitelist_paths"

if [[ ! -s "$tmp_whitelist_paths" ]]; then
    echo "ERROR: UI 白名单为空或格式不正确: $WHITELIST_FILE"
    exit 1
fi

missing=0

while IFS= read -r relative_path; do
    [[ -z "${relative_path:-}" ]] && continue
    absolute_path="$ROOT_DIR/$relative_path"
    if [[ ! -f "$absolute_path" ]]; then
        echo "BROKEN_WHITELIST_PATH: $relative_path"
        missing=1
        continue
    fi

    type_name="$(
        grep -n -E '^\s*(public\s+|internal\s+|open\s+)?(final\s+)?(struct|class)\s+[A-Za-z_][A-Za-z0-9_]*\s*.*:\s*.*View' \
            "$absolute_path" \
        | head -n 1 \
        | awk '{
            line = $0
            sub(/.*struct[[:space:]]+/, "", line)
            sub(/.*class[[:space:]]+/, "", line)
            match(line, /^[A-Za-z_][A-Za-z0-9_]*/)
            print substr(line, RSTART, RLENGTH)
        }'
    )"

    if [[ -z "${type_name:-}" ]]; then
        echo "UNRESOLVED_WHITELIST_VIEW: $relative_path"
        missing=1
        continue
    fi

    printf '%s\t%s\n' "$type_name" "$relative_path" >> "$tmp_whitelist_views"
done < "$tmp_whitelist_paths"

if [[ ! -s "$tmp_whitelist_views" ]]; then
    echo "ERROR: 未从白名单解析出任何核心页面组件。"
    exit 1
fi

sort -u -o "$tmp_whitelist_views" "$tmp_whitelist_views"

while IFS=$'\t' read -r type_name source_path; do
    [[ -z "${type_name:-}" ]] && continue
    category="$(awk -F'\t' -v t="$type_name" '$1 == t { print $2; exit }' "$tmp_glossary_map")"
    if [[ -z "${category:-}" ]]; then
        echo "MISSING_UI_GLOSSARY: $type_name ($source_path)"
        missing=1
        continue
    fi
    if [[ "$category" != "UI-复用" ]]; then
        echo "INVALID_UI_CATEGORY: $type_name ($source_path) expected=UI-复用 actual=$category"
        missing=1
    fi
done < "$tmp_utility_views"

while IFS=$'\t' read -r type_name source_path; do
    [[ -z "${type_name:-}" ]] && continue
    category="$(awk -F'\t' -v t="$type_name" '$1 == t { print $2; exit }' "$tmp_glossary_map")"
    if [[ -z "${category:-}" ]]; then
        echo "MISSING_CORE_UI_GLOSSARY: $type_name ($source_path)"
        missing=1
        continue
    fi
    if [[ "$category" != "UI-核心页面" ]]; then
        echo "INVALID_CORE_UI_CATEGORY: $type_name ($source_path) expected=UI-核心页面 actual=$category"
        missing=1
    fi
done < "$tmp_whitelist_views"

if [[ "$missing" -ne 0 ]]; then
    echo "FAIL: UI 术语范围校验失败，请同步更新 docs/architecture/术语对照表.md 与 UI 白名单。"
    exit 1
fi

utility_count="$(wc -l < "$tmp_utility_views" | tr -d ' ')"
core_count="$(wc -l < "$tmp_whitelist_views" | tr -d ' ')"
echo "OK: UI 术语范围校验通过（复用组件 $utility_count 个，核心页面组件 $core_count 个）。"
