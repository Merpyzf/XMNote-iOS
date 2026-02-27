#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GLOSSARY_FILE="$ROOT_DIR/docs/architecture/术语对照表.md"

if [[ ! -f "$GLOSSARY_FILE" ]]; then
    echo "ERROR: 未找到术语表文件: $GLOSSARY_FILE"
    exit 1
fi

tmp_glossary_terms="$(mktemp)"
tmp_core_types="$(mktemp)"

cleanup() {
    rm -f "$tmp_glossary_terms" "$tmp_core_types"
}
trap cleanup EXIT

awk -F'|' '
    /^\|/ {
        english = $4
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", english)
        if (english != "" && english != "英文术语" && english != "---") {
            print english
        }
    }
' "$GLOSSARY_FILE" | sort -u > "$tmp_glossary_terms"

CORE_DIRS=(
    "$ROOT_DIR/xmnote/ViewModels"
    "$ROOT_DIR/xmnote/Domain"
    "$ROOT_DIR/xmnote/Data"
    "$ROOT_DIR/xmnote/Infra"
    "$ROOT_DIR/xmnote/Services"
    "$ROOT_DIR/xmnote/Database"
)

grep -rn -E '^\s*(public\s+|internal\s+|open\s+)?(final\s+)?(class|struct|protocol|enum)\s+[A-Za-z_][A-Za-z0-9_]*' \
    --include='*.swift' \
    "${CORE_DIRS[@]}" \
| awk '
    function is_core_type(name) {
        if (name ~ /(ViewModel|Repository|RepositoryProtocol|Service|Client|Manager|Container|DataSource|Payload|Input)$/) {
            return 1
        }
        return name == "AppDatabase" \
            || name == "DatabaseManager" \
            || name == "NetworkError" \
            || name == "ObservationStream"
    }
    {
        # 提取文件路径（第一个冒号前）
        match($0, /^[^:]+/)
        file = substr($0, RSTART, RLENGTH)
        # 提取类型名：去掉关键字前的所有内容，取关键字后第一个词
        line = $0
        sub(/.*class[[:space:]]+/, "", line)
        sub(/.*struct[[:space:]]+/, "", line)
        sub(/.*protocol[[:space:]]+/, "", line)
        sub(/.*enum[[:space:]]+/, "", line)
        # 取第一个标识符
        match(line, /^[A-Za-z_][A-Za-z0-9_]*/)
        type = substr(line, RSTART, RLENGTH)
        if (type != "" && is_core_type(type) && !seen[type]++) {
            print type "\t" file
        }
    }
' | sort -u > "$tmp_core_types"

if [[ ! -s "$tmp_core_types" ]]; then
    echo "ERROR: 未扫描到核心类型，请检查目录或正则规则。"
    exit 1
fi

missing=0
while IFS=$'\t' read -r type_name file_path; do
    [[ -z "${type_name:-}" ]] && continue
    if ! grep -Fxq "$type_name" "$tmp_glossary_terms"; then
        echo "MISSING_GLOSSARY: $type_name ($file_path)"
        missing=1
    fi
done < "$tmp_core_types"

if [[ "$missing" -ne 0 ]]; then
    echo "FAIL: 术语表存在缺失，请补齐 docs/architecture/术语对照表.md。"
    exit 1
fi

core_count="$(wc -l < "$tmp_core_types" | tr -d ' ')"
echo "OK: 术语表核心类型校验通过（$core_count 个核心类型）。"
