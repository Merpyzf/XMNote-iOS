#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY_FILE="$ROOT_DIR/docs/architecture/UI组件文档清单.md"
WHITELIST_FILE="$ROOT_DIR/docs/architecture/UI核心组件白名单.md"

if [[ ! -f "$REGISTRY_FILE" ]]; then
    echo "ERROR: 未找到 UI 组件文档清单: $REGISTRY_FILE"
    exit 1
fi

if [[ ! -f "$WHITELIST_FILE" ]]; then
    echo "ERROR: 未找到 UI 核心组件白名单: $WHITELIST_FILE"
    exit 1
fi

tmp_entries="$(mktemp)"
tmp_whitelist="$(mktemp)"
tmp_registry_sources="$(mktemp)"
cleanup() {
    rm -f "$tmp_entries" "$tmp_whitelist" "$tmp_registry_sources"
}
trap cleanup EXIT

awk -F'|' '
    function trim(s) {
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", s)
        return s
    }
    /^\|/ {
        component = trim($2)
        source = trim($4)
        guide = trim($5)

        if (component == "" || component == "组件名" || component ~ /^-+$/) {
            next
        }

        if (source == "" || guide == "") {
            printf("INVALID_ROW\t%d\t%s\n", NR, component)
            next
        }

        printf("%s\t%s\t%s\n", component, source, guide)
    }
' "$REGISTRY_FILE" > "$tmp_entries"

if [[ ! -s "$tmp_entries" ]]; then
    echo "ERROR: UI 组件文档清单为空或格式不正确: $REGISTRY_FILE"
    exit 1
fi

sed -n 's/^- \(xmnote\/[^[:space:]]*\.swift\)$/\1/p' "$WHITELIST_FILE" | sort -u > "$tmp_whitelist"

if [[ ! -s "$tmp_whitelist" ]]; then
    echo "ERROR: UI 核心组件白名单为空或格式不正确: $WHITELIST_FILE"
    exit 1
fi

missing=0
entry_count=0

# shellcheck disable=SC2034
declare -A checked_docs=()

while IFS=$'\t' read -r component source guide; do
    [[ -z "${component:-}" ]] && continue
    entry_count=$((entry_count + 1))

    if [[ "$component" == "INVALID_ROW" ]]; then
        echo "INVALID_REGISTRY_ROW: line=$source component=$guide"
        missing=1
        continue
    fi

    source_file="$ROOT_DIR/$source"
    guide_file="$ROOT_DIR/$guide"
    echo "$source" >> "$tmp_registry_sources"

    if [[ ! -f "$source_file" ]]; then
        echo "MISSING_COMPONENT_SOURCE: $component ($source)"
        missing=1
    fi

    if [[ ! -f "$guide_file" ]]; then
        echo "MISSING_COMPONENT_GUIDE: $component ($guide)"
        missing=1
        continue
    fi

    if [[ -n "${checked_docs[$guide]+x}" ]]; then
        continue
    fi

    for required in "快速接入" "参数说明" "示例" "常见问题"; do
        if ! grep -qE "^[#]{2,3}[[:space:]].*${required}" "$guide_file"; then
            echo "GUIDE_MISSING_SECTION: $component ($guide) missing=${required}"
            missing=1
        fi
    done

    checked_docs[$guide]=1
done < "$tmp_entries"

sort -u -o "$tmp_registry_sources" "$tmp_registry_sources"

while IFS= read -r source_path; do
    [[ -z "${source_path:-}" ]] && continue
    if ! grep -Fxq "$source_path" "$tmp_registry_sources"; then
        echo "MISSING_WHITELIST_COMPONENT_GUIDE: $source_path"
        missing=1
    fi
done < "$tmp_whitelist"

while IFS= read -r source_path; do
    [[ -z "${source_path:-}" ]] && continue
    if [[ "$source_path" == xmnote/Views/* ]] && ! grep -Fxq "$source_path" "$tmp_whitelist"; then
        echo "UNREGISTERED_VIEW_CORE_COMPONENT: $source_path"
        missing=1
    fi
done < "$tmp_registry_sources"

if [[ "$missing" -ne 0 ]]; then
    echo "FAIL: UI 组件使用文档校验失败，请补齐清单与组件使用说明。"
    exit 1
fi

guide_count="${#checked_docs[@]}"
echo "OK: UI 组件使用文档校验通过（组件 $entry_count 个，文档 $guide_count 份）。"
