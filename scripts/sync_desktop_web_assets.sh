#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SOURCE_ROOT="${1:-/Users/wangke/Workspace/AndroidProjects/XMNote/web/src/main/assets/out}"
DESTINATION_ROOT="${REPOSITORY_ROOT}/Packages/XMNoteWeb/Sources/XMNoteWeb/Resources/DesktopWebSite"
EXPECTED_FILE_COUNT="50"
EXPECTED_TOTAL_BYTES="4047547"
EXPECTED_AGGREGATE_SHA256="d29dc4834e22e62dce01900d17e408bf3de8b369c2f0388143c7feff673d4a40"

if [[ ! -d "${SOURCE_ROOT}" || ! -f "${SOURCE_ROOT}/index.html" ]]; then
    echo "网页制品源目录无效：${SOURCE_ROOT}" >&2
    exit 1
fi

source_file_count="$(find "${SOURCE_ROOT}" -type f | wc -l | tr -d ' ')"
source_total_bytes="$(find "${SOURCE_ROOT}" -type f -exec stat -f '%z' {} + | awk '{ total += $1 } END { print total + 0 }')"
source_aggregate_sha256="$(cd "${SOURCE_ROOT}" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{ print $1 }')"

if [[ "${source_file_count}" != "${EXPECTED_FILE_COUNT}" ]]; then
    echo "网页制品文件数不匹配：期望 ${EXPECTED_FILE_COUNT}，实际 ${source_file_count}" >&2
    exit 1
fi

if [[ "${source_total_bytes}" != "${EXPECTED_TOTAL_BYTES}" ]]; then
    echo "网页制品总字节数不匹配：期望 ${EXPECTED_TOTAL_BYTES}，实际 ${source_total_bytes}" >&2
    exit 1
fi

if [[ "${source_aggregate_sha256}" != "${EXPECTED_AGGREGATE_SHA256}" ]]; then
    echo "网页制品聚合 SHA-256 不匹配：${source_aggregate_sha256}" >&2
    exit 1
fi

if [[ -e "${DESTINATION_ROOT}" ]]; then
    destination_aggregate_sha256="$(cd "${DESTINATION_ROOT}" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{ print $1 }')"
    if [[ "${destination_aggregate_sha256}" == "${EXPECTED_AGGREGATE_SHA256}" ]]; then
        echo "DesktopWebSite 已与冻结制品一致，无需同步。"
        exit 0
    fi
    echo "目标目录已存在且内容不同；为避免覆盖已跟踪资源，脚本未做修改：${DESTINATION_ROOT}" >&2
    exit 1
fi

mkdir -p "$(dirname "${DESTINATION_ROOT}")"
cp -R "${SOURCE_ROOT}" "${DESTINATION_ROOT}"
echo "已同步冻结网页制品到 ${DESTINATION_ROOT}"
