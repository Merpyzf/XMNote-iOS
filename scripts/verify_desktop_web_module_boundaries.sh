#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPOSITORY_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
PACKAGE_ROOT="${REPOSITORY_ROOT}/Packages/XMNoteWeb"
SOURCE_ROOT="${PACKAGE_ROOT}/Sources/XMNoteWeb"

if [[ ! -f "${PACKAGE_ROOT}/Package.swift" || ! -d "${SOURCE_ROOT}" ]]; then
    echo "缺少 XMNoteWeb Package 或源码目录" >&2
    exit 1
fi

forbidden_source_pattern='(^|[[:space:]])import[[:space:]]+(SwiftUI|UIKit|GRDB)([[:space:]]|$)|\b(AppDatabase|DatabaseManager|RepositoryContainer)\b'
if rg -n --glob '*.swift' "${forbidden_source_pattern}" "${SOURCE_ROOT}"; then
    echo "XMNoteWeb 引用了禁止的 UI、数据库或 App 业务依赖" >&2
    exit 1
fi

package_dependency_count="$(rg -c '\.package\(' "${PACKAGE_ROOT}/Package.swift")"
[[ "${package_dependency_count}" == "1" ]] \
    || { echo "XMNoteWeb 只能声明一个 Hummingbird 外部依赖" >&2; exit 1; }

rg -q 'https://github\.com/hummingbird-project/hummingbird\.git' "${PACKAGE_ROOT}/Package.swift" \
    || { echo "XMNoteWeb 缺少 Hummingbird 官方依赖" >&2; exit 1; }

rg -q 'exact:[[:space:]]*"2\.22\.0"' "${PACKAGE_ROOT}/Package.swift" \
    || { echo "XMNoteWeb 必须精确依赖 Hummingbird 2.22.0" >&2; exit 1; }

public_hummingbird_pattern='public[^{}]{0,800}\b(Router|Request|Response|Application|BasicRequestContext|ByteBuffer)\b[^{}]*\{'
if rg -n -U --pcre2 --glob '*.swift' "${public_hummingbird_pattern}" "${SOURCE_ROOT}"; then
    echo "XMNoteWeb 的 public API 泄漏了 Hummingbird 类型" >&2
    exit 1
fi

echo "XMNoteWeb 模块边界校验通过"
