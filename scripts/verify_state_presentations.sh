#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE_DIR="$ROOT_DIR/xmnote"
STATE_PRESENTATION_DIR="xmnote/UIComponents/Feedback/StatePresentation"
LOADING_STATE_FILE="xmnote/UIComponents/Feedback/LoadingStateView.swift"
CONTENT_STATE_FILE="$STATE_PRESENTATION_DIR/XMContentStateView.swift"
COMPACT_STATE_FILE="$STATE_PRESENTATION_DIR/XMCompactStateView.swift"
INLINE_BANNER_FILE="$STATE_PRESENTATION_DIR/XMInlineStatusBanner.swift"
STATE_ROLE_FILE="$STATE_PRESENTATION_DIR/XMStateRole.swift"
STATE_TOKENS_FILE="xmnote/Utilities/DesignSystem/StatePresentationTokens.swift"
SEMANTIC_COLORS_FILE="xmnote/Utilities/DesignSystem/SemanticColors.swift"
ATTACHMENT_STRIP_FILE="xmnote/UIComponents/Media/Attachments/XMAttachmentUploadStrip.swift"
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

if rg -q '\b(quietPageTitle|quietCompactTitle|emptyTitle|compactTitle|usesEmptyTitle)\b' \
    "$ROOT_DIR/$STATE_TOKENS_FILE" "$ROOT_DIR/$STATE_PRESENTATION_DIR"; then
    echo "STATE_TITLE_LEGACY_TOKEN: 所有公共状态必须共用 StatePresentationTypography.title"
    has_error=1
fi

if ! rg -q 'static let title[[:space:]]*=[[:space:]]*AppTypography\.body([[:space:]]|$)' \
    "$ROOT_DIR/$STATE_TOKENS_FILE"; then
    echo "STATE_TITLE_TOKEN_MISMATCH: token=$STATE_TOKENS_FILE expected=AppTypography.body"
    has_error=1
fi

if rg -q '\bcompactAction\b' "$ROOT_DIR/$STATE_TOKENS_FILE" "$ROOT_DIR/$STATE_PRESENTATION_DIR"; then
    echo "STATE_ACTION_LEGACY_TOKEN: 页面与局部状态动作必须共用 StatePresentationTypography.action"
    has_error=1
fi

if ! rg -q 'static let action[[:space:]]*=[[:space:]]*AppTypography\.subheadline([[:space:]]|$)' \
    "$ROOT_DIR/$STATE_TOKENS_FILE"; then
    echo "STATE_ACTION_TOKEN_MISMATCH: token=$STATE_TOKENS_FILE expected=AppTypography.subheadline"
    has_error=1
fi

for component_file in "$CONTENT_STATE_FILE" "$COMPACT_STATE_FILE"; do
    if ! rg -q 'StatePresentationTypography\.title' "$ROOT_DIR/$component_file"; then
        echo "STATE_TITLE_COMPONENT_MISSING: component=$component_file"
        has_error=1
    fi

    if ! rg -q 'StatePresentationTypography\.action' "$ROOT_DIR/$component_file"; then
        echo "STATE_ACTION_COMPONENT_MISSING: component=$component_file"
        has_error=1
    fi
done

# 页面与局部居中状态使用同一 32pt owner，并相对 body 以相同曲线响应 Dynamic Type。
for component_file in "$CONTENT_STATE_FILE" "$COMPACT_STATE_FILE"; do
    if ! rg -U -q '@ScaledMetric\(relativeTo:[[:space:]]*\.body\)[\s\S]{0,120}centeredIconSize' \
        "$ROOT_DIR/$component_file"; then
        echo "STATE_CENTERED_ICON_SCALE_MISMATCH: component=$component_file expected=relativeTo.body"
        has_error=1
    fi
done

if ! rg -q 'static let centeredIconSize[^=]*=[[:space:]]*32' "$ROOT_DIR/$STATE_TOKENS_FILE" \
    || ! rg -q 'static let cardIconSize[^=]*=[[:space:]]*18' "$ROOT_DIR/$STATE_TOKENS_FILE" \
    || ! rg -q 'static let bannerIconSize[^=]*=[[:space:]]*16' "$ROOT_DIR/$STATE_TOKENS_FILE"; then
    echo "STATE_ICON_METRICS_MISMATCH: expected centered=32 card=18 banner=16"
    has_error=1
fi

# Liquid Glass 只属于导航与浮动功能层；状态正文保持内容层，并使用系统原生按钮层级。
if rg -q --glob '*.swift' '\.(glass|glassProminent)\b|\.glassEffect[[:space:]]*\(' \
    "$ROOT_DIR/$STATE_PRESENTATION_DIR"; then
    echo "STATE_CONTENT_LIQUID_GLASS_FORBIDDEN: 状态正文不得直接使用 Liquid Glass API"
    has_error=1
fi

if rg -q --glob '*.swift' '\.buttonStyle\([[:space:]]*\.bordered(Prominent)?[[:space:]]*\)' \
    "$ROOT_DIR/$STATE_PRESENTATION_DIR"; then
    echo "STATE_VISIBLE_ACTION_BACKGROUND_FORBIDDEN: 状态内动作不得使用 bordered 或 borderedProminent"
    has_error=1
fi

for component_file in "$CONTENT_STATE_FILE" "$COMPACT_STATE_FILE" "$INLINE_BANNER_FILE"; do
    if ! rg -q '\.xmMinimumHitTarget[[:space:]]*\(' "$ROOT_DIR/$component_file"; then
        echo "STATE_MINIMUM_HIT_TARGET_MISSING: component=$component_file"
        has_error=1
    fi

    if rg -U -q 'XMStateActionLabel[\s\S]{0,160}\.frame\(\s*minHeight:\s*InteractionMetrics\.minimumTouchTarget' \
        "$ROOT_DIR/$component_file"; then
        echo "STATE_VISIBLE_ACTION_HEIGHT_FORBIDDEN: component=$component_file"
        has_error=1
    fi

    if ! rg -q '\.buttonStyle\([[:space:]]*\.borderless[[:space:]]*\)' "$ROOT_DIR/$component_file"; then
        echo "STATE_TEXT_ACTION_STYLE_MISSING: component=$component_file expected=borderless"
        has_error=1
    fi

    if ! rg -q '\.tint\(Color\.stateActionForeground\)' "$ROOT_DIR/$component_file"; then
        echo "STATE_ACTION_FOREGROUND_MISMATCH: component=$component_file expected=stateActionForeground"
        has_error=1
    fi

    if rg -q '\.tint\(Color\.(appTint|feedbackError)\)' "$ROOT_DIR/$component_file"; then
        echo "STATE_ACTION_LOW_CONTRAST_FOREGROUND: component=$component_file"
        has_error=1
    fi
done

if ! rg -q 'static let stateActionForeground[[:space:]]*=' "$ROOT_DIR/$SEMANTIC_COLORS_FILE"; then
    echo "STATE_ACTION_FOREGROUND_TOKEN_MISSING: token=$SEMANTIC_COLORS_FILE"
    has_error=1
fi

if ! rg -q 'retryConfiguration\.baseForegroundColor[[:space:]]*=[[:space:]]*UIColor\.xmResolved\(Color\.stateActionForeground\)' \
    "$ROOT_DIR/$ATTACHMENT_STRIP_FILE"; then
    echo "ATTACHMENT_RETRY_FOREGROUND_MISMATCH: component=$ATTACHMENT_STRIP_FILE"
    has_error=1
fi

if rg -q '\bLabel[[:space:]]*\(' "$ROOT_DIR/$CONTENT_STATE_FILE"; then
    echo "STATE_SYSTEM_LABEL_TYPOGRAPHY_FORBIDDEN: XMContentStateView 四种角色必须共用自定义排版"
    has_error=1
fi

if rg -U -q 'XMStateAction\([\s\S]{0,180}systemImage:' "$SOURCE_DIR"; then
    echo "STATE_ACTION_ICON_FORBIDDEN: 状态内动作必须使用可独立表达的纯文字标签"
    has_error=1
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

# 已完成语义审计的 owner 使用窄范围契约，避免用文件名或高度猜测所有页面层级。
state_level_contracts=(
    'xmnote/Views/Book/BookCollectionListView.swift|书单列表空状态|private func emptyState\(title: String\)[\s\S]{0,180}XMContentStateView'
    'xmnote/Views/Note/NoteCollectionView.swift|笔记首页首次失败|case \.error:\s*XMContentStateView'
    'xmnote/Views/Note/NoteReviewView.swift|笔记回顾首次失败|switch viewModel\.contentState[\s\S]{0,900}case \.failure:\s*XMContentStateView'
    'xmnote/Views/Note/Sheets/NoteEditorChapterPickerSheet.swift|章节选择普通空状态|XMCompactStateView\(\s*role: \.empty,\s*title: "暂无章节"'
    'xmnote/Views/Note/Sheets/NoteEditorChapterPickerSheet.swift|章节选择搜索无结果|XMCompactStateView\(\s*role: \.noResults,\s*title: "没有匹配的章节"'
    'xmnote/Views/Book/Components/BookshelfDefaultCollectionView.swift|默认书架搜索无结果|class BookshelfDefaultSearchEmptyCell[\s\S]{0,900}XMContentStateView'
    'xmnote/Views/Book/Components/BookshelfAggregateCollectionView.swift|聚合书架搜索无结果|class BookshelfAggregateSearchEmptyCell[\s\S]{0,900}XMContentStateView'
    'xmnote/Views/Personal/Backup/Sheets/BackupHistorySheetView.swift|备份历史空状态|if viewModel\.backupList\.isEmpty\s*\{\s*XMContentStateView'
    'xmnote/Views/Reading/Sheets/ReadingYearSummarySheet.swift|年度已读空状态|if summary\.books\.isEmpty\s*\{\s*XMContentStateView'
    'xmnote/Views/Content/Sheets/ContentViewerTagSheet.swift|标签查看空状态|if tags\.isEmpty\s*\{\s*XMContentStateView'
    'xmnote/Views/Reading/ReadCalendar/ReadCalendarContentView.swift|阅读日历根状态|var emptyState: some View\s*\{\s*XMContentStateView'
    'xmnote/Views/Note/NoteReviewView.swift|笔记回顾范围修正|XMContentStateView\(\s*role: \.noResults,[\s\S]{0,220}action: XMStateAction\("调整范围"'
    'xmnote/Views/Book/BookSearchView.swift|书籍搜索站点验证|private func fanqieRecoveryCard[\s\S]{0,520}XMCompactStateView\([\s\S]{0,420}role: \.instruction[\s\S]{0,420}style: \.card'
    'xmnote/Views/Note/NoteDetailView.swift|笔记内容失效|title: "笔记不存在或已删除",\s*systemImage: "questionmark\.circle"'
    'xmnote/Views/Content/RelevantDetailView.swift|相关内容失效|title: "相关内容不存在或已删除",\s*systemImage: "questionmark\.circle"'
    'xmnote/Views/Content/ReviewDetailView.swift|书评内容失效|title: "书评不存在或已删除",\s*systemImage: "questionmark\.circle"'
    'xmnote/Views/Book/BookReadingDetailView.swift|书籍内容失效|title: "书籍不存在或已删除",\s*systemImage: "questionmark\.circle"'
)

for entry in "${state_level_contracts[@]}"; do
    IFS='|' read -r contract_path contract_owner contract_pattern <<< "$entry"
    if ! rg -U -q "$contract_pattern" "$ROOT_DIR/$contract_path"; then
        echo "STATE_LEVEL_CONTRACT_MISMATCH: $contract_path owner=$contract_owner"
        has_error=1
    fi
done

# 页面已有顶部新增入口时，空态不得再次创建同名状态动作。
duplicate_state_action_contracts=(
    'xmnote/Views/Book/ChapterManagerView.swift|目录管理顶部已有新增入口|XMStateAction\("新增章节"'
    'xmnote/Views/Personal/Backup/WebDAVServerListView.swift|备份服务器顶部已有新增入口|XMStateAction\("新增服务器"'
)

for entry in "${duplicate_state_action_contracts[@]}"; do
    IFS='|' read -r contract_path contract_owner contract_pattern <<< "$entry"
    if rg -q "$contract_pattern" "$ROOT_DIR/$contract_path"; then
        echo "STATE_DUPLICATE_ENTRY_ACTION: $contract_path owner=$contract_owner"
        has_error=1
    fi
done

# 这些类型保留自己的容器或领域职责；视觉必须继续委托给通用状态组件，或属于计划明确排除的骨架/工作流状态。
state_view_allowlist=(
    "xmnote/ContentView.swift|DatabaseInitializationFailureView|根数据库初始化失败，属于应用启动阻断态"
    "xmnote/Views/Book/Components/ReadingStatusTimeline.swift|ReadingStatusTimelineEmptyView|阅读状态时间线的领域内嵌布局"
    "xmnote/Views/Book/BookScanPlaceholderView.swift|BookScanPlaceholderView|扫码工作流占位页，不表达数据空态"
    "xmnote/Views/Book/Components/BookCollectionVisualComponents.swift|BookCollectionEmptyBooksRow|书单卡片行布局适配器，内部复用 XMCompactStateView"
    "xmnote/Views/Book/Components/BookWorkspaceCollectionView.swift|BookWorkspaceCollectionEmptyRow|UICollectionView 状态行布局适配器，内部复用公共状态与加载组件"
    "xmnote/Views/Book/Components/BookshelfLoadingSkeletonView.swift|BookshelfLoadingSkeletonView|书架容器专属骨架"
    "xmnote/Views/Book/Components/BookshelfLoadingSkeletonView.swift|BookshelfLoadingListRow|书架容器专属骨架行"
    "xmnote/Views/Book/Sheets/BookshelfBatchEditSheets.swift|BookshelfBatchNamedOptionLoadingRow|批量编辑菜单行的局部读取反馈"
    "xmnote/Views/Book/Sheets/BookshelfBatchEditSheets.swift|BookshelfBatchNamedOptionPlaceholderRow|批量编辑菜单行占位骨架"
    "xmnote/Views/Book/Sheets/BookshelfBatchEditSheets.swift|BookshelfBatchNamedOptionLoadErrorRow|批量编辑菜单行的业务错误与重试"
    "xmnote/Views/Book/Sheets/BookshelfBatchEditSheets.swift|BookshelfBatchNamedOptionEmptyRow|批量编辑菜单行的领域空值"
    "xmnote/Views/Book/Sheets/BookshelfBatchEditSheets.swift|BookshelfBatchEmptyHint|批量编辑表单内的领域提示"
    "xmnote/Views/Personal/Components/TagManagementCollectionView.swift|TagManagementCollectionEmptyStateView|UICollectionView 背景适配器，内部复用 XMContentStateView"
    "xmnote/Views/Content/Sheets/AIInteractionSheets.swift|AIAutoTagGenerationFailureView|AI 流式生成保留部分 Markdown 与重新生成业务流程"
    "xmnote/Views/Content/Sheets/AIInteractionSheets.swift|AIAutoTagEmptyStateView|AI 标签生成无建议时保留 Sheet 上下文与重新生成路径"
    "xmnote/Views/Note/Components/NotePhotoOCRFlowView.swift|OCRCameraUnavailableStateView|OCR 深色取景器权限与相册回退业务状态"
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

if ! rg -q 'isEnabled:[[:space:]]*false' "$ROOT_DIR/$CATALOG_FILE"; then
    echo "STATE_CATALOG_MISSING_DISABLED_ACTION: catalog=$CATALOG_FILE"
    has_error=1
fi

if ! rg -q '内容已失效' "$ROOT_DIR/$CATALOG_FILE" \
    || ! rg -q '首次读取失败' "$ROOT_DIR/$CATALOG_FILE"; then
    echo "STATE_CATALOG_MISSING_MISSING_FAILURE_COMPARISON: catalog=$CATALOG_FILE"
    has_error=1
fi

if ! rg -q 'case \.fullFailure' "$ROOT_DIR/$DEBUG_TEST_FILE" \
    || ! rg -q 'case \.partialFailure' "$ROOT_DIR/$DEBUG_TEST_FILE"; then
    echo "STATE_CATALOG_MISSING_FULL_RETAINED_FAILURE: test=$DEBUG_TEST_FILE"
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

# 公共状态调用点只接受事实、必要原因和真实动作，阻止模板化解释重新进入生产与验收目录。
while IFS=: read -r absolute_path line_number copy_line; do
    [[ -z "${absolute_path:-}" ]] && continue
    if ! rg -q '\b(XMContentStateView|XMCompactStateView|XMInlineStatusBanner)[[:space:]]*\(' "$absolute_path"; then
        continue
    fi
    relative_path="${absolute_path#$ROOT_DIR/}"
    echo "STATE_COPY_AI_SLOP: $relative_path:$line_number copy=$copy_line"
    has_error=1
done < <(
    rg -n --glob '*.swift' \
        '会显示在这里|会出现在这里|换个关键词再试|当前暂无|开启[^"”]{0,12}之旅|轻松|尽情探索|数据库连接已中断|数据库暂时不可用|服务器暂时不可用' \
        "$SOURCE_DIR" || true
)

if (( has_error != 0 )); then
    echo "FAIL: 通用状态展示校验失败；请复用 StatePresentation，或补齐测试目录、文档登记、双生产消费者和带原因例外。"
    exit 1
fi

echo "OK: 通用状态展示已收敛，公共视觉均具备测试样例、文档登记和至少两个生产消费者。"
