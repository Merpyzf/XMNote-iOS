#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/xmnote"
STATE_PRESENTATION_DIR="xmnote/UIComponents/Feedback/StatePresentation"
LOADING_STATE_FILE="xmnote/UIComponents/Feedback/LoadingStateView.swift"
CONTENT_STATE_FILE="$STATE_PRESENTATION_DIR/XMContentStateView.swift"
CATALOG_FILE="$STATE_PRESENTATION_DIR/StatePresentationCatalogPreview.swift"
DEBUG_TEST_FILE="xmnote/Views/Debug/StatePresentationTestView.swift"
DEBUG_CENTER_FILE="xmnote/Views/Debug/DebugCenterView.swift"
GLOSSARY_FILE="docs/architecture/术语对照表.md"
COMPONENT_REGISTRY_FILE="docs/architecture/UI组件文档清单.md"
COMPONENT_GUIDE_FILE="docs/component-guides/XMStatePresentation使用说明.md"
has_error=0

if [[ ! -d "$SOURCE_DIR" ]]; then
    echo "ERROR: 未找到应用源码目录: $SOURCE_DIR"
    exit 1
fi

legacy_state_names=(
    EmptyStateView
    BookshelfContextualEmptyStateView
    BookSearchStatusCard
    BookCollectionCoverSearchStatusCard
    GlobalSearchInlineEmptyView
    GlobalSearchPlaceholderView
    GlobalSearchErrorView
    ReadingDashboardInlineBanner
    ReadCalendarInlineErrorBanner
    NoteHomeFailureView
    ReadingTimerUnavailableState
    CollectionListPlaceholderView
    NoteReviewPlaceholderView
    TimelinePlaceholderView
    StatisticsPlaceholderView
)

# 这些类型保留自己的容器或领域职责；视觉必须继续委托给通用状态组件，或属于计划明确排除的骨架/工作流状态。
state_view_allowlist=(
    "xmnote/ContentView.swift|DatabaseInitializationFailureView|根数据库初始化失败，属于应用启动阻断态"
    "xmnote/Views/Book/Components/ReadingStatusTimeline.swift|ReadingStatusTimelineEmptyView|阅读状态时间线的领域内嵌布局"
    "xmnote/Views/Book/BookScanPlaceholderView.swift|BookScanPlaceholderView|扫码工作流占位页，不表达数据空态"
    "xmnote/Views/Book/Components/BookCollectionVisualComponents.swift|BookCollectionEmptyBooksRow|书单卡片行布局适配器，内部复用 XMCompactStateView"
    "xmnote/Views/Book/Components/BookWorkspaceCollectionView.swift|BookWorkspaceCollectionEmptyRow|UICollectionView 空行布局适配器，内部复用 XMContentStateView"
    "xmnote/Views/Book/Components/BookshelfLoadingSkeletonView.swift|BookshelfLoadingSkeletonView|书架容器专属骨架"
    "xmnote/Views/Book/Components/BookshelfLoadingSkeletonView.swift|BookshelfLoadingListRow|书架容器专属骨架行"
    "xmnote/Views/Book/Sheets/BookshelfBatchEditSheets.swift|BookshelfBatchNamedOptionLoadingRow|批量编辑菜单行的局部读取反馈"
    "xmnote/Views/Book/Sheets/BookshelfBatchEditSheets.swift|BookshelfBatchNamedOptionPlaceholderRow|批量编辑菜单行占位骨架"
    "xmnote/Views/Book/Sheets/BookshelfBatchEditSheets.swift|BookshelfBatchNamedOptionLoadErrorRow|批量编辑菜单行的业务错误与重试"
    "xmnote/Views/Book/Sheets/BookshelfBatchEditSheets.swift|BookshelfBatchNamedOptionEmptyRow|批量编辑菜单行的领域空值"
    "xmnote/Views/Book/Sheets/BookshelfBatchEditSheets.swift|BookshelfBatchEmptyHint|批量编辑表单内的领域提示"
    "xmnote/Views/Personal/Components/TagManagementCollectionView.swift|TagManagementCollectionEmptyStateView|UICollectionView 背景适配器，内部复用 XMContentStateView"
)

is_allowed_state_view() {
    local candidate_path="$1"
    local candidate_type="$2"
    local entry
    local allowed_path
    local allowed_type
    local reason

    for entry in "${state_view_allowlist[@]}"; do
        IFS='|' read -r allowed_path allowed_type reason <<< "$entry"
        if [[ "$candidate_path" == "$allowed_path" && "$candidate_type" == "$allowed_type" ]]; then
            return 0
        fi
    done
    return 1
}

# 公共状态视觉类型采用可自动发现的统一命名：XM…StateView / XM…StatusBanner；
# LoadingStateView 为已存在的兼容名称。新增类型必须同时满足目录、文档、目录样例和双生产消费者约束。
while IFS=: read -r absolute_path line_number declaration; do
    [[ -z "${absolute_path:-}" ]] && continue

    if [[ "$declaration" =~ struct[[:space:]]+([A-Za-z0-9_]+) ]]; then
        type_name="${BASH_REMATCH[1]}"
    else
        continue
    fi

    if ! rg -q "\\b${type_name}[[:space:]]*\\(" "$ROOT_DIR/$CATALOG_FILE"; then
        echo "STATE_COMPONENT_MISSING_CATALOG_SAMPLE: $type_name catalog=$CATALOG_FILE"
        has_error=1
    fi

    if ! rg -q "[|][[:space:]]*${type_name}[[:space:]]*[|]" "$ROOT_DIR/$GLOSSARY_FILE"; then
        echo "STATE_COMPONENT_MISSING_GLOSSARY: $type_name glossary=$GLOSSARY_FILE"
        has_error=1
    fi

    if ! rg -q "[|][[:space:]]*${type_name}[[:space:]]*[|]" "$ROOT_DIR/$COMPONENT_REGISTRY_FILE"; then
        echo "STATE_COMPONENT_MISSING_REGISTRY: $type_name registry=$COMPONENT_REGISTRY_FILE"
        has_error=1
    fi

    if ! rg -q '^\|[[:space:]]*`'"${type_name}"'`[[:space:]]*\|[[:space:]]*`xmnote/[^`]+\.swift`[[:space:]]*\|[[:space:]]*`xmnote/[^`]+\.swift`[[:space:]]*\|' \
        "$ROOT_DIR/$COMPONENT_GUIDE_FILE"; then
        echo "STATE_COMPONENT_MISSING_CONSUMER_EVIDENCE: $type_name guide=$COMPONENT_GUIDE_FILE"
        has_error=1
    fi

    consumer_files="$({
        rg -l --glob '*.swift' "\\b${type_name}[[:space:]]*\\(" "$SOURCE_DIR" || true
    } | while IFS= read -r consumer_path; do
        [[ -z "$consumer_path" ]] && continue
        relative_consumer_path="${consumer_path#$ROOT_DIR/}"
        case "$relative_consumer_path" in
            "$STATE_PRESENTATION_DIR"/*|"$LOADING_STATE_FILE"|xmnote/Views/Debug/*|*/Vendor/*)
                continue
                ;;
        esac
        echo "$relative_consumer_path"
    done | sort -u)"
    consumer_count="$(printf '%s\n' "$consumer_files" | awk 'NF { count += 1 } END { print count + 0 }')"

    if (( consumer_count < 2 )); then
        echo "STATE_COMPONENT_INSUFFICIENT_PRODUCTION_CONSUMERS: $type_name count=$consumer_count"
        if [[ -n "$consumer_files" ]]; then
            printf '  consumer: %s\n' $consumer_files
        fi
        has_error=1
    fi
done < <(
    rg -n --glob '*.swift' \
        '^[[:space:]]*((public|internal|package|nonisolated)[[:space:]]+)*struct[[:space:]]+(XM[A-Za-z0-9_]*(StateView|StatusBanner)|LoadingStateView)[[:space:]]*:[[:space:]]*View' \
        "$ROOT_DIR/$STATE_PRESENTATION_DIR" "$ROOT_DIR/$LOADING_STATE_FILE" || true
)

if [[ ! -f "$ROOT_DIR/$DEBUG_TEST_FILE" ]] \
    || ! rg -q '\bStatePresentationCatalogView[[:space:]]*\(' "$ROOT_DIR/$DEBUG_TEST_FILE"; then
    echo "STATE_CATALOG_MISSING_DEBUG_HOST: test=$DEBUG_TEST_FILE"
    has_error=1
fi

if ! rg -q '\bStatePresentationTestView[[:space:]]*\(' "$ROOT_DIR/$DEBUG_CENTER_FILE"; then
    echo "STATE_CATALOG_MISSING_DEBUG_CENTER_ENTRY: center=$DEBUG_CENTER_FILE"
    has_error=1
fi

if ! rg -q '\bLoadPhaseHost[[:space:]]*\(' "$ROOT_DIR/$CATALOG_FILE"; then
    echo "STATE_CATALOG_MISSING_PHASE_HOST_SAMPLE: catalog=$CATALOG_FILE"
    has_error=1
fi

while IFS=: read -r absolute_path line_number declaration; do
    [[ -z "${absolute_path:-}" ]] && continue
    relative_path="${absolute_path#$ROOT_DIR/}"
    case "$relative_path" in
        xmnote/Views/Debug/*|*/Vendor/*)
            continue
            ;;
    esac
    if [[ "$relative_path" == "$CONTENT_STATE_FILE" ]]; then
        continue
    fi
    echo "DIRECT_CONTENT_UNAVAILABLE_VIEW: $relative_path:$line_number"
    has_error=1
done < <(
    rg -n --glob '*.swift' '\bContentUnavailableView[[:space:]]*[({]' "$SOURCE_DIR" || true
)

for legacy_name in "${legacy_state_names[@]}"; do
    while IFS=: read -r absolute_path line_number declaration; do
        [[ -z "${absolute_path:-}" ]] && continue
        relative_path="${absolute_path#$ROOT_DIR/}"
        case "$relative_path" in
            xmnote/Views/Debug/*|*/Vendor/*)
                continue
                ;;
        esac
        echo "LEGACY_STATE_PRESENTATION: $relative_path:$line_number name=$legacy_name"
        has_error=1
    done < <(
        rg -n --glob '*.swift' "\\b${legacy_name}\\b" "$SOURCE_DIR" || true
    )
done

while IFS=: read -r absolute_path line_number declaration; do
    [[ -z "${absolute_path:-}" ]] && continue
    relative_path="${absolute_path#$ROOT_DIR/}"

    case "$relative_path" in
        "$STATE_PRESENTATION_DIR"/*|"$LOADING_STATE_FILE"|xmnote/ViewModels/*|xmnote/Views/Debug/*|*/Vendor/*)
            continue
            ;;
    esac

    if [[ "$declaration" =~ struct[[:space:]]+([A-Za-z0-9_]+) ]]; then
        type_name="${BASH_REMATCH[1]}"
    else
        continue
    fi

    if is_allowed_state_view "$relative_path" "$type_name"; then
        continue
    fi

    echo "UNREVIEWED_STATE_VIEW: $relative_path:$line_number type=$type_name"
    has_error=1
done < <(
    rg -n --glob '*.swift' \
        '^[[:space:]]*((private|fileprivate|internal|public|nonisolated)[[:space:]]+)*struct[[:space:]]+[A-Za-z0-9_]*(Empty|Error|Failure|Unavailable|Placeholder|Loading)[A-Za-z0-9_]*(View|Row|Hint)\b' \
        "$SOURCE_DIR" || true
)

if (( has_error != 0 )); then
    echo "FAIL: 通用状态展示校验失败；请复用 StatePresentation，或补齐测试目录、文档登记、双生产消费者和带原因例外。"
    exit 1
fi

echo "OK: 通用状态展示已收敛，公共视觉均具备测试样例、文档登记和至少两个生产消费者。"
