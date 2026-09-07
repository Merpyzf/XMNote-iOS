#if DEBUG
import SwiftUI

/**
 * [INPUT]: 依赖 RepositoryContainer、DatabaseManager、AppTypography、Spacing、语义色、XMContentStateView 与测试详情页
 * [OUTPUT]: 对外提供按验证目标分组且可搜索的 DebugCenterView 测试目录
 * [POS]: Debug 测试目录页，由 PersonalView 经 AppRoute.debug 进入并延迟构造具体测试详情页
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct DebugCenterView: View {
    @State private var searchText = ""
    @Environment(RepositoryContainer.self) private var repositories
    @Environment(DatabaseManager.self) private var databaseManager

    private static let items: [DebugCenterItem] = [
        DebugCenterItem(
            category: .designFoundationAndFeedback,
            destination: .designSystemGallery,
            icon: "square.grid.2x2",
            title: "设计系统展厅",
            subtitle: "核心令牌、组件状态、适配环境与专项验收入口"
        ),
        DebugCenterItem(
            category: .designFoundationAndFeedback,
            destination: .sheetCatalog,
            icon: "rectangle.portrait.on.rectangle.portrait",
            title: "Sheet 样式校准",
            subtitle: "82 个生产调用、113 个生产目标与隔离生产数据逐项验收"
        ),
        DebugCenterItem(
            category: .readingAndContent,
            destination: .richTextEditor,
            icon: "textformat",
            title: "富文本编辑器",
            subtitle: "格式能力与 HTML 往返一致性"
        ),
        DebugCenterItem(
            category: .readingAndContent,
            destination: .fadeOverflowText,
            icon: "text.alignleft",
            title: "长文本披露",
            subtitle: "正式末行内联展开组件的主题、行数与富文本验收"
        ),
        DebugCenterItem(
            category: .readingAndContent,
            destination: .readingHeatmap,
            icon: "chart.dots.scatter",
            title: "阅读热力图",
            subtitle: "周热力图与 Android 阅读详情月历的渲染、定位和配色验收"
        ),
        DebugCenterItem(
            category: .readingAndContent,
            destination: .monthlyReadingChart,
            icon: "chart.bar.xaxis",
            title: "月度阅读图表",
            subtitle: "Android 同款展开/收起、全局比例与文本对齐验收"
        ),
        DebugCenterItem(
            category: .readingAndContent,
            destination: .readingStatusTimeline,
            icon: "clock.arrow.circlepath",
            title: "阅读历程组件",
            subtitle: "状态节点、时间间隔、动态字体与交互权限验收"
        ),
        DebugCenterItem(
            category: .designFoundationAndFeedback,
            destination: .statePresentation,
            icon: "rectangle.stack",
            title: "状态展示",
            subtitle: "真实生产场景、公共状态组件与业务专用状态的统一验收入口"
        ),
        DebugCenterItem(
            category: .designFoundationAndFeedback,
            destination: .systemAlert,
            icon: "rectangle.center.inset.filled.badge.plus",
            title: "System Alert",
            subtitle: "XMSystemAlert 基础设施、系统颜色语义与轻输入场景验证"
        ),
        DebugCenterItem(
            category: .designFoundationAndFeedback,
            destination: .toast,
            icon: "bubble.left.and.text.bubble.right",
            title: "Toast 提示",
            subtitle: "XMToast 统一入口、底部短驻留提示、状态与安全区验证"
        ),
        DebugCenterItem(
            category: .controlsAndInteraction,
            destination: .ratingBar,
            icon: "star.circle",
            title: "评分组件",
            subtitle: "Fluent 星形、半星步进、交互热区与浅深色验证"
        ),
        DebugCenterItem(
            category: .booksAndCovers,
            destination: .bookSelection,
            icon: "books.vertical",
            title: "书籍选择",
            subtitle: "单选、多选、已选管理、书单去重与异常状态矩阵"
        ),
        DebugCenterItem(
            category: .controlsAndInteraction,
            destination: .selectionMotion,
            icon: "checkmark.circle",
            title: "选择动效",
            subtitle: "SF Symbols 绘制出现/消失与自定义选择反馈验证"
        ),
        DebugCenterItem(
            category: .experimentsAndReproductions,
            destination: .appleMusicTransition,
            icon: "music.note.list",
            title: "Apple Music 转场",
            subtitle: "Bottom Accessory 液态玻璃退场的 XMNote 对照与纯系统框架归因"
        ),
        DebugCenterItem(
            category: .experimentsAndReproductions,
            destination: .noteReviewSingleCanvasTransition,
            icon: "rectangle.3.group.bubble.left",
            title: "单画布转场实验",
            subtitle: "固定数据验证二维单画布与瀑布流之间的共享纸张转场"
        ),
        DebugCenterItem(
            category: .controlsAndInteraction,
            destination: .scopeSelector,
            icon: "rectangle.split.3x1",
            title: "范围选择控件",
            subtitle: "2-5 项单选范围、数量、长文案、浅深色与玻璃样式验证"
        ),
        DebugCenterItem(
            category: .controlsAndInteraction,
            destination: .searchHistory,
            icon: "clock.arrow.circlepath",
            title: "搜索历史组件",
            subtitle: "空态、短词、长词、删除、清空、展开与 iOS 26 样式验证"
        ),
        DebugCenterItem(
            category: .experimentsAndReproductions,
            destination: .searchableSystemReproduction,
            icon: "magnifyingglass.circle",
            title: "Searchable 系统复现",
            subtitle: "iOS 26 Search Tab 焦点、呈现与延迟写入 text 的最小复现"
        ),
        DebugCenterItem(
            category: .designFoundationAndFeedback,
            destination: .scrollEdgeChrome,
            icon: "rectangle.portrait.and.arrow.right",
            title: "滚动边缘覆盖层",
            subtitle: "顶部/底部柔化、背景、强度、高度与深色模式验证"
        ),
        DebugCenterItem(
            category: .booksAndCovers,
            destination: .bookReorderSandbox,
            icon: "square.grid.3x3",
            title: "书架手动排序",
            subtitle: "LazyVGrid 拖拽、置顶边界、搜索禁用与模拟写入验证"
        ),
        DebugCenterItem(
            category: .mediaAndSystemCapabilities,
            destination: .imageLoading,
            icon: "photo.stack",
            title: "图片加载",
            subtitle: "静态图/GIF/失败链路与缓存来源观测"
        ),
        DebugCenterItem(
            category: .mediaAndSystemCapabilities,
            destination: .webHTMLFetch,
            icon: "globe.asia.australia.fill",
            title: "网页 HTML 抓取",
            subtitle: "WebView/HTTP 双通道、Cookie 复用与 DOM 探针验证"
        ),
        DebugCenterItem(
            category: .mediaAndSystemCapabilities,
            destination: .cameraTextCapture,
            icon: "text.viewfinder",
            title: "系统取词",
            subtitle: "系统键盘 OCR 按钮 + 可用性/语言列表验证"
        ),
        DebugCenterItem(
            category: .mediaAndSystemCapabilities,
            destination: .baiduOCR,
            icon: "doc.text.viewfinder",
            title: "百度 OCR",
            subtitle: "官方 SDK + 图片裁切 + 参数持久化 + 富文本回填验证"
        ),
        DebugCenterItem(
            category: .mediaAndSystemCapabilities,
            destination: .jxPhotoBrowser,
            icon: "rectangle.3.group",
            title: "JX 图片浏览器",
            subtitle: "UIKit 核心浏览器 + SwiftUI 缩略图墙 Zoom 转场验证"
        ),
        DebugCenterItem(
            category: .readingAndContent,
            destination: .readCalendarCoverStack,
            icon: "books.vertical",
            title: "阅读日历封面堆叠",
            subtitle: "扇形层级、阴影分离与网格溢出效果验证"
        ),
        DebugCenterItem(
            category: .readingAndContent,
            destination: .noteReviewPaging,
            icon: "rectangle.stack",
            title: "书摘回顾卡堆",
            subtitle: "BigUIPaging Core + XMNote 自定义卡堆动效与长文滚动仲裁"
        ),
        DebugCenterItem(
            category: .booksAndCovers,
            destination: .bookCoverStyle,
            icon: "book.closed",
            title: "书籍封面样式",
            subtitle: "薄厚边样式、尺寸降级阈值与浅深色对照验证"
        ),
        DebugCenterItem(
            category: .booksAndCovers,
            destination: .bookGroupCover,
            icon: "rectangle.stack",
            title: "书籍分组封面",
            subtitle: "书盒候选样式、多/单/空封面与列表行浅深色验证"
        ),
        DebugCenterItem(
            category: .booksAndCovers,
            destination: .bookCoverProgressBar,
            icon: "books.vertical.fill",
            title: "封面阅读进度条",
            subtitle: "玻璃轨道、尺寸适配与进度动画验证"
        ),
        DebugCenterItem(
            category: .booksAndCovers,
            destination: .bookCoverBadgeEffect,
            icon: "pin.square",
            title: "书封角标效果",
            subtitle: "置顶/数量毛玻璃参数与阅读状态纯色角标验证"
        ),
        DebugCenterItem(
            category: .experimentsAndReproductions,
            destination: .topBarActionStyleLab,
            icon: "slider.horizontal.2.square",
            title: "首页顶部胶囊",
            subtitle: "正式基线与 A/B/C 原生 Liquid Glass 候选的真实首页上下文对比"
        ),
        DebugCenterItem(
            category: .experimentsAndReproductions,
            destination: .liquidGlassLab,
            icon: "camera.filters",
            title: "iOS 26 Liquid Glass（液态玻璃）",
            subtitle: "图片背景文本、工具栏、参数预设、截图对比与 FPS 观测"
        ),
        DebugCenterItem(
            category: .designFoundationAndFeedback,
            destination: .systemColors,
            icon: "paintpalette",
            title: "系统颜色语义",
            subtitle: "按语义分组查看 iOS 系统颜色与真实案例用法"
        ),
        DebugCenterItem(
            category: .readingAndContent,
            destination: .timelineCards,
            icon: "timeline.selection",
            title: "时间线卡片",
            subtitle: "7 种事件卡片样式与时间线装饰器"
        ),
        DebugCenterItem(
            category: .readingAndContent,
            destination: .timelineCalendarHorizon,
            icon: "calendar.badge.clock",
            title: "时间线日历-Horizon",
            subtitle: "Vendor 源码集成 + 范围/选中/月切换/跳转/marker 渲染验证"
        ),
    ]

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var visibleSections: [DebugCenterSection] {
        DebugCenterCategory.allCases.compactMap { category in
            let categoryItems = Self.items.filter { $0.category == category }
            let visibleItems: [DebugCenterItem]

            if normalizedSearchText.isEmpty
                || category.title.localizedCaseInsensitiveContains(normalizedSearchText) {
                visibleItems = categoryItems
            } else {
                visibleItems = categoryItems.filter { item in
                    item.title.localizedCaseInsensitiveContains(normalizedSearchText)
                        || item.subtitle.localizedCaseInsensitiveContains(normalizedSearchText)
                }
            }

            guard !visibleItems.isEmpty else { return nil }
            return DebugCenterSection(category: category, items: visibleItems)
        }
    }

    var body: some View {
        List {
            ForEach(visibleSections) { section in
                Section(section.category.title) {
                    ForEach(section.items) { item in
                        NavigationLink {
                            destination(for: item.destination)
                        } label: {
                            DebugCenterRow(item: item)
                        }
                        .listRowBackground(Color.surfaceCard)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color.surfacePage)
        .overlay {
            if visibleSections.isEmpty {
                XMContentStateView(
                    role: .noResults,
                    title: "未找到测试项",
                    message: "没有与“\(normalizedSearchText)”匹配的分类、标题或说明。"
                )
            }
        }
        .searchable(
            text: $searchText,
            placement: .navigationBarDrawer(displayMode: .always),
            prompt: "搜索分类、测试项或说明"
        )
        .navigationTitle("测试中心")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func destination(for destination: DebugCenterDestination) -> some View {
        switch destination {
        case .designSystemGallery:
            DesignSystemGalleryView()
        case .sheetCatalog:
            SheetCatalogTestView(
                repositories: repositories,
                databaseManager: databaseManager
            )
        case .richTextEditor:
            RichTextTestView()
        case .fadeOverflowText:
            FadeOverflowTextTestView()
        case .readingHeatmap:
            HeatmapTestView()
        case .monthlyReadingChart:
            MonthlyReadingChartTestView()
        case .readingStatusTimeline:
            ReadingStatusTimelineTestView()
        case .statePresentation:
            StatePresentationTestView()
        case .systemAlert:
            SystemAlertTestView()
        case .toast:
            PopupViewToastTestView()
        case .ratingBar:
            RatingBarTestView()
        case .bookSelection:
            BookSelectionTestView()
        case .selectionMotion:
            SelectionMotionTestView()
        case .appleMusicTransition:
            AppleMusicTransitionLabView()
        case .noteReviewSingleCanvasTransition:
            NoteReviewSingleCanvasTransitionLabView(repository: repositories.noteRepository)
        case .scopeSelector:
            XMScopeSelectorTestView()
        case .searchHistory:
            SearchHistoryTestView()
        case .searchableSystemReproduction:
            SearchableSystemBugReproView()
        case .scrollEdgeChrome:
            XMScrollEdgeChromeTestView()
        case .bookReorderSandbox:
            BookReorderSandboxTestView()
        case .imageLoading:
            ImageLoadingTestView()
        case .webHTMLFetch:
            WebHTMLFetchTestView()
        case .cameraTextCapture:
            CameraTextCaptureTestView()
        case .baiduOCR:
            BaiduOCRTestView()
        case .jxPhotoBrowser:
            JXPhotoBrowserTestView()
        case .readCalendarCoverStack:
            ReadCalendarCoverStackTestView()
        case .noteReviewPaging:
            NoteReviewPagingTestView()
        case .bookCoverStyle:
            BookCoverStyleTestView()
        case .bookGroupCover:
            BookGroupCoverTestView()
        case .bookCoverProgressBar:
            BookCoverProgressBarTestView()
        case .bookCoverBadgeEffect:
            BookCoverBadgeEffectTestView()
        case .topBarActionStyleLab:
            TopBarActionStyleLabTestView()
        case .liquidGlassLab:
            LiquidGlassLabTestView()
        case .systemColors:
            SystemColorsTestView()
        case .timelineCards:
            TimelineCardsTestView()
        case .timelineCalendarHorizon:
            TimelineCalendarHorizonTestView()
        }
    }
}

private enum DebugCenterCategory: CaseIterable, Hashable, Identifiable {
    case designFoundationAndFeedback
    case controlsAndInteraction
    case readingAndContent
    case booksAndCovers
    case mediaAndSystemCapabilities
    case experimentsAndReproductions

    var id: Self { self }

    var title: String {
        switch self {
        case .designFoundationAndFeedback:
            "设计基础与反馈"
        case .controlsAndInteraction:
            "控件与交互"
        case .readingAndContent:
            "阅读与内容"
        case .booksAndCovers:
            "书籍与封面"
        case .mediaAndSystemCapabilities:
            "媒体与系统能力"
        case .experimentsAndReproductions:
            "实验与问题复现"
        }
    }
}

private enum DebugCenterDestination: Hashable {
    case designSystemGallery
    case sheetCatalog
    case richTextEditor
    case fadeOverflowText
    case readingHeatmap
    case monthlyReadingChart
    case readingStatusTimeline
    case statePresentation
    case systemAlert
    case toast
    case ratingBar
    case bookSelection
    case selectionMotion
    case appleMusicTransition
    case noteReviewSingleCanvasTransition
    case scopeSelector
    case searchHistory
    case searchableSystemReproduction
    case scrollEdgeChrome
    case bookReorderSandbox
    case imageLoading
    case webHTMLFetch
    case cameraTextCapture
    case baiduOCR
    case jxPhotoBrowser
    case readCalendarCoverStack
    case noteReviewPaging
    case bookCoverStyle
    case bookGroupCover
    case bookCoverProgressBar
    case bookCoverBadgeEffect
    case topBarActionStyleLab
    case liquidGlassLab
    case systemColors
    case timelineCards
    case timelineCalendarHorizon
}

private struct DebugCenterItem: Identifiable {
    let category: DebugCenterCategory
    let destination: DebugCenterDestination
    let icon: String
    let title: String
    let subtitle: String

    var id: DebugCenterDestination { destination }
}

private struct DebugCenterSection: Identifiable {
    let category: DebugCenterCategory
    let items: [DebugCenterItem]

    var id: DebugCenterCategory { category }
}

private struct DebugCenterRow: View {
    let item: DebugCenterItem

    @ScaledMetric(relativeTo: .body) private var iconColumnWidth: CGFloat = 24

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            Image(systemName: item.icon)
                .font(AppTypography.body)
                .foregroundStyle(Color.iconSecondary)
                .frame(width: iconColumnWidth)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text(item.title)
                    .font(AppTypography.bodyMedium)
                    .foregroundStyle(Color.textPrimary)

                Text(item.subtitle)
                    .font(AppTypography.footnote)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    let repositories = RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty()))
    NavigationStack {
        DebugCenterView()
    }
    .environment(repositories)
}
#endif
