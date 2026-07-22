#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
ASSET_ROOT="${REPOSITORY_ROOT}/Packages/XMNoteWeb/Sources/XMNoteWeb/Resources/DesktopWebSite"
MANIFEST_PATH="${REPOSITORY_ROOT}/Packages/XMNoteWeb/DesktopWebSite.manifest"
EXPECTED_BUILD_ID="rdCQYAj0PCXtuEWsOIDdh"
EXPECTED_WEB_VERSION="1.0.1"
EXPECTED_FILE_COUNT="50"
EXPECTED_TOTAL_BYTES="4047547"
EXPECTED_AGGREGATE_SHA256="d29dc4834e22e62dce01900d17e408bf3de8b369c2f0388143c7feff673d4a40"

if [[ ! -d "${ASSET_ROOT}" || ! -f "${ASSET_ROOT}/index.html" ]]; then
    echo "缺少 DesktopWebSite 或 index.html" >&2
    exit 1
fi

file_count="$(find "${ASSET_ROOT}" -type f | wc -l | tr -d ' ')"
total_bytes="$(find "${ASSET_ROOT}" -type f -exec stat -f '%z' {} + | awk '{ total += $1 } END { print total + 0 }')"
aggregate_sha256="$(cd "${ASSET_ROOT}" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256 | shasum -a 256 | awk '{ print $1 }')"

[[ "${file_count}" == "${EXPECTED_FILE_COUNT}" ]] || { echo "文件数不匹配：${file_count}" >&2; exit 1; }
[[ "${total_bytes}" == "${EXPECTED_TOTAL_BYTES}" ]] || { echo "总字节数不匹配：${total_bytes}" >&2; exit 1; }
[[ "${aggregate_sha256}" == "${EXPECTED_AGGREGATE_SHA256}" ]] || { echo "聚合 SHA-256 不匹配：${aggregate_sha256}" >&2; exit 1; }
rg -q "${EXPECTED_BUILD_ID}" "${ASSET_ROOT}/index.html" || { echo "Build ID 不匹配" >&2; exit 1; }
rg -q "v${EXPECTED_WEB_VERSION}" "${ASSET_ROOT}" || { echo "网页版本不匹配" >&2; exit 1; }

if [[ ! -f "${MANIFEST_PATH}" ]]; then
    echo "缺少制品 manifest：${MANIFEST_PATH}" >&2
    exit 1
fi

rg -q "^build_id=${EXPECTED_BUILD_ID}$" "${MANIFEST_PATH}" || { echo "manifest Build ID 不匹配" >&2; exit 1; }
rg -q "^web_version=${EXPECTED_WEB_VERSION}$" "${MANIFEST_PATH}" || { echo "manifest 网页版本不匹配" >&2; exit 1; }
rg -q "^file_count=${EXPECTED_FILE_COUNT}$" "${MANIFEST_PATH}" || { echo "manifest 文件数不匹配" >&2; exit 1; }
rg -q "^total_bytes=${EXPECTED_TOTAL_BYTES}$" "${MANIFEST_PATH}" || { echo "manifest 总字节数不匹配" >&2; exit 1; }
rg -q "^aggregate_sha256=${EXPECTED_AGGREGATE_SHA256}$" "${MANIFEST_PATH}" || { echo "manifest 聚合 SHA-256 不匹配" >&2; exit 1; }

cmp -s \
    <(sed -n '/^files_sha256:$/,$p' "${MANIFEST_PATH}" | tail -n +2) \
    <(cd "${ASSET_ROOT}" && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 shasum -a 256) \
    || { echo "逐文件哈希与 manifest 不一致" >&2; exit 1; }

echo "DesktopWebSite 校验通过：${file_count} 个文件，${total_bytes} 字节，${aggregate_sha256}"
