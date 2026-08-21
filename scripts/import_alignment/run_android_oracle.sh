#!/bin/bash
set -euo pipefail

REPOSITORY_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ANDROID_ROOT="${XMNOTE_ANDROID_ROOT:-/Users/wangke/Workspace/AndroidProjects/XMNote}"
FIXTURE_ROOT="$REPOSITORY_ROOT/xmnoteTests/Fixtures/ImportParity/v2"
ORACLE_OUTPUT="$(mktemp -d /tmp/xmnote-import-oracle.XXXXXX)"

python3 "$REPOSITORY_ROOT/scripts/import_alignment/verify_android_source_closure.py" \
    --android-root "$ANDROID_ROOT"

env \
    IMPORT_ALIGNMENT_ORACLE_SOURCE="$REPOSITORY_ROOT/scripts/import_alignment/android-oracle" \
    IMPORT_ALIGNMENT_FIXTURE_ROOT="$FIXTURE_ROOT" \
    IMPORT_ALIGNMENT_ORACLE_OUTPUT="$ORACLE_OUTPUT" \
    TZ=Asia/Shanghai \
    LANG=zh_CN.UTF-8 \
    "$ANDROID_ROOT/gradlew" \
    -p "$ANDROID_ROOT" \
    -I "$REPOSITORY_ROOT/scripts/import_alignment/android-oracle.init.gradle" \
    :data:testDebugUnitTest \
    --rerun-tasks \
    --tests com.merpyzf.data.helper.note_parse_helper.AndroidImportOracleTest \
    --max-workers=4 \
    --priority=low

python3 "$REPOSITORY_ROOT/scripts/import_alignment/compare_android_oracle.py" "$ORACLE_OUTPUT"
echo "Android Oracle 临时输出保留在: $ORACLE_OUTPUT"
