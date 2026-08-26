/**
 * [INPUT]: 依赖 RepositoryContainer、AppNavigationCoordinator、BookDetailViewModel、XMBookCover、XMRatingBar、XMStarredAppearance、InteractionMetrics 与外层书籍/阅读路由回调
 * [OUTPUT]: 对外提供首帧结构稳定的 BookDetailView 与 BookChapterNotesView，形成封面影像 Hero、可收起概览、搜索工具栏、持久化排序与四域内容常驻的单书工作台
 * [POS]: Book 模块单书内容工作台壳层，以共享 Chrome、独立内容滚动与单一更多菜单承接目录/书摘/相关/书评
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Observation
import SwiftUI
import UIKit
#if DEBUG
import os
#endif

/// 单本书内容工作台入口，负责创建状态源并保留外层导航 owner 提供的路由能力。
struct BookDetailView: View {
    let bookId: Int64
    let launchConfiguration: BookDetailLaunchConfiguration
    let onStartReading: (Int64) -> Void
    let onSupplementReading: (Int64) -> Void
    let onOpenReadingDetail: (Int64) -> Void
    let onOpenChapterNotes: (Int64, Int64, String) -> Void
    let onOpenBook: (Int64) -> Void
    let onOpenBookRoute: (BookRoute) -> Void
    let readingTimerZoomConfiguration: ReadingTimerZoomSourceConfiguration?

    @Environment(RepositoryContainer.self) private var repositories
    @Environment(AppNavigationCoordinator.self) private var navigationCoordinator
    @State private var tabChromeSuppressionToken = UUID()

    /// 注入当前书籍与外层路由回调，工作台自身不直接持有任一 Tab 的 NavigationPath。
    init(
        bookId: Int64,
        launchConfiguration: BookDetailLaunchConfiguration? = nil,
        onStartReading: @escaping (Int64) -> Void = { _ in },
        onSupplementReading: @escaping (Int64) -> Void = { _ in },
        onOpenReadingDetail: @escaping (Int64) -> Void = { _ in },
        onOpenChapterNotes: @escaping (Int64, Int64, String) -> Void = { _, _, _ in },
        onOpenBook: @escaping (Int64) -> Void = { _ in },
        readingTimerZoomConfiguration: ReadingTimerZoomSourceConfiguration? = nil,
        onOpenBookRoute: @escaping (BookRoute) -> Void = { _ in }
    ) {
        self.bookId = bookId
        self.launchConfiguration = launchConfiguration ?? .standard(bookID: bookId)
        self.onStartReading = onStartReading
        self.onSupplementReading = onSupplementReading
        self.onOpenReadingDetail = onOpenReadingDetail
        self.onOpenChapterNotes = onOpenChapterNotes
        self.onOpenBook = onOpenBook
        self.onOpenBookRoute = onOpenBookRoute
        self.readingTimerZoomConfiguration = readingTimerZoomConfiguration
    }

    var body: some View {
        BookDetailWorkspaceHost(
            bookId: bookId,
            launchConfiguration: launchConfiguration,
            repository: repositories.bookRepository,
            contentRepository: repositories.contentRepository,
            colorRepository: repositories.readCalendarColorRepository,
            onStartReading: onStartReading,
            onSupplementReading: onSupplementReading,
            onOpenReadingDetail: onOpenReadingDetail,
            onOpenChapterNotes: onOpenChapterNotes,
            onOpenBook: onOpenBook,
            onOpenBookRoute: onOpenBookRoute,
            readingTimerZoomConfiguration: readingTimerZoomConfiguration
        )
        .id(bookId)
        .accessibilityIdentifier("book.detail.\(bookId)")
        .background(Color.surfacePage.ignoresSafeArea())
        .toolbarVisibility(.hidden, for: .tabBar)
        .onAppear {
            navigationCoordinator.suppressTabChrome(for: tabChromeSuppressionToken)
        }
        .onDisappear {
            navigationCoordinator.restoreTabChrome(for: tabChromeSuppressionToken)
        }
    }
}

/// 在目标页首帧同步建立 ViewModel owner，避免数据观察与搜索工具栏在 push 过程中动态插入。
private struct BookDetailWorkspaceHost: View {
    let bookId: Int64
    let launchConfiguration: BookDetailLaunchConfiguration
    let onStartReading: (Int64) -> Void
    let onSupplementReading: (Int64) -> Void
    let onOpenReadingDetail: (Int64) -> Void
    let onOpenChapterNotes: (Int64, Int64, String) -> Void
    let onOpenBook: (Int64) -> Void
    let onOpenBookRoute: (BookRoute) -> Void
    let readingTimerZoomConfiguration: ReadingTimerZoomSourceConfiguration?

    @State private var viewModel: BookDetailViewModel

    /// 用环境提供的 Repository 构造页面唯一状态源；State 保证父视图刷新时不重建 owner。
    init(
        bookId: Int64,
        launchConfiguration: BookDetailLaunchConfiguration,
        repository: any BookDetailRepositoryProtocol,
        contentRepository: any ContentRepositoryProtocol,
        colorRepository: any ReadCalendarColorRepositoryProtocol,
        onStartReading: @escaping (Int64) -> Void,
        onSupplementReading: @escaping (Int64) -> Void,
        onOpenReadingDetail: @escaping (Int64) -> Void,
        onOpenChapterNotes: @escaping (Int64, Int64, String) -> Void,
        onOpenBook: @escaping (Int64) -> Void,
        onOpenBookRoute: @escaping (BookRoute) -> Void,
        readingTimerZoomConfiguration: ReadingTimerZoomSourceConfiguration?
    ) {
        self.bookId = bookId
        self.launchConfiguration = launchConfiguration
        self.onStartReading = onStartReading
        self.onSupplementReading = onSupplementReading
        self.onOpenReadingDetail = onOpenReadingDetail
        self.onOpenChapterNotes = onOpenChapterNotes
        self.onOpenBook = onOpenBook
        self.onOpenBookRoute = onOpenBookRoute
        self.readingTimerZoomConfiguration = readingTimerZoomConfiguration
        _viewModel = State(
            initialValue: BookDetailViewModel(
                bookId: bookId,
                repository: repository,
                contentRepository: contentRepository,
                colorRepository: colorRepository
            )
        )
    }

    var body: some View {
        BookWorkspaceContentView(
            bookId: bookId,
            launchConfiguration: launchConfiguration,
            viewModel: viewModel,
            onStartReading: onStartReading,
            onSupplementReading: onSupplementReading,
            onOpenReadingDetail: onOpenReadingDetail,
            onOpenChapterNotes: onOpenChapterNotes,
            onOpenBook: onOpenBook,
            onOpenBookRoute: onOpenBookRoute,
            readingTimerZoomConfiguration: readingTimerZoomConfiguration
        )
    }
}

// MARK: - Workspace

/// 目录域的本地可见范围，所有筛选都只作用于当前书籍真实章节。
/// 章节化书摘组，章节只负责内容归类，每条书摘保留独立内容表面。
private struct BookNoteGroup: Identifiable {
    let id: Int64
    let title: String
    let isStarred: Bool
    let notes: [NoteExcerpt]
}

/// 类别化相关内容组，保留 Android 全局分类与单书私有分类的原始顺序。
private struct BookRelatedGroup: Identifiable {
    let id: Int64
    let title: String
    let items: [BookRelatedExcerpt]
}

/// 保存单个内容域实测出的书籍头部高度，供封面取色氛围随滚动连续收起。
private struct BookWorkspaceHeaderAnchors: Equatable {
    var pinOffset: CGFloat = 0
}

/// 从系统滚动几何中提取渲染氛围所需的最小连续指标，避免把完整 ScrollGeometry 写入状态。
private struct BookWorkspaceScrollMetrics: Equatable, Sendable {
    var effectiveOffset: CGFloat = 0
    var viewportTop: CGFloat = 0
}

/// 隔离单个内容域的高频滚动指标，只有氛围背景订阅其变化，书摘列表不参与逐帧刷新。
@Observable
@MainActor
private final class BookWorkspaceScrollVisualState {
    var effectiveOffset: CGFloat = 0
    var viewportTop: CGFloat = 0

    /// 在主线程接收系统滚动回调；数值未变化时不写入，避免无效观察通知。
    func update(_ metrics: BookWorkspaceScrollMetrics) {
        if effectiveOffset != metrics.effectiveOffset {
            effectiveOffset = metrics.effectiveOffset
        }
        if viewportTop != metrics.viewportTop {
            viewportTop = metrics.viewportTop
        }
    }
}

/// 为四个常驻内容域保存稳定的视觉状态引用，切换 Tab 不会重建或串用滚动位置。
@MainActor
private final class BookWorkspaceScrollVisualStates {
    private let catalog = BookWorkspaceScrollVisualState()
    private let notes = BookWorkspaceScrollVisualState()
    private let related = BookWorkspaceScrollVisualState()
    private let reviews = BookWorkspaceScrollVisualState()

    /// 返回指定内容域唯一的视觉状态 owner。
    func state(for section: BookWorkspaceSection) -> BookWorkspaceScrollVisualState {
        switch section {
        case .catalog:
            return catalog
        case .notes:
            return notes
        case .related:
            return related
        case .reviews:
            return reviews
        }
    }
}

/// 从封面取色生成不透明页面画布，并以正文对比度为上限约束主题色强度。
struct BookWorkspaceThemePalette {
    let identifier: UInt64
    let canvasColor: Color
    let headerLeadingColor: Color
    let headerTrailingColor: Color

    /// 用封面色和当前外观的系统分组底色生成正文、文字侧 Header 与封面侧 Header 三档不透明背景。
    init(tintRGBAHex: UInt32?, colorScheme: ColorScheme) {
        let isDark = colorScheme == .dark
        let interfaceStyle: UIUserInterfaceStyle = isDark ? .dark : .light
        let traits = UITraitCollection(userInterfaceStyle: interfaceStyle)
        let resolvedBaseColor = UIColor.systemGroupedBackground.resolvedColor(with: traits)
        let base = RGBComponents(uiColor: resolvedBaseColor)
            ?? (isDark
                ? RGBComponents(red8: 0x1C, green8: 0x1C, blue8: 0x1E)
                : RGBComponents(red8: 0xF2, green8: 0xF2, blue8: 0xF7))
        let fallback = base.color
        let fallbackIdentifier = UInt64(isDark ? 1 : 0)

        guard let tintRGBAHex,
              tintRGBAHex != 0,
              tintRGBAHex & 0xFF > 0 else {
            identifier = fallbackIdentifier
            canvasColor = fallback
            headerLeadingColor = fallback
            headerTrailingColor = fallback
            return
        }

        let source = RGBComponents(rgbaHex: tintRGBAHex)
        guard source.saturation >= 0.12 else {
            identifier = fallbackIdentifier
            canvasColor = fallback
            headerLeadingColor = fallback
            headerTrailingColor = fallback
            return
        }

        let primaryText = isDark
            ? RGBComponents(red8: 0xC6, green8: 0xC8, blue8: 0xCB)
            : RGBComponents(red8: 0x33, green8: 0x33, blue8: 0x33)
        let secondaryText = isDark
            ? RGBComponents(red8: 0x8C, green8: 0x92, blue8: 0x9B)
            : RGBComponents(red8: 0x66, green8: 0x66, blue8: 0x66)
        let canvasSaturationDamping = Self.saturationDamping(
            for: source.saturation,
            maximumReduction: 0.25
        )
        let headerSaturationDamping = Self.saturationDamping(
            for: source.saturation,
            maximumReduction: 0.25
        )

        let canvas = Self.accessibleBlend(
            source: source,
            base: base,
            maximumStrength: (isDark ? 0.015 : 0.01) * canvasSaturationDamping,
            primaryText: primaryText,
            secondaryText: secondaryText
        )
        let headerLeading = Self.accessibleBlend(
            source: source,
            base: base,
            maximumStrength: 0.05 * headerSaturationDamping,
            primaryText: primaryText,
            secondaryText: secondaryText
        )
        let headerTrailing = Self.accessibleBlend(
            source: source,
            base: base,
            maximumStrength: 0.08 * headerSaturationDamping,
            primaryText: primaryText,
            secondaryText: secondaryText
        )

        identifier = (UInt64(tintRGBAHex) << 1) | UInt64(isDark ? 1 : 0)
        canvasColor = canvas.color
        headerLeadingColor = headerLeading.color
        headerTrailingColor = headerTrailing.color
    }

    /// 按区域控制高饱和封面色的抑制幅度，让 Hero 可辨识而正文保持克制。
    private static func saturationDamping(
        for saturation: Double,
        maximumReduction: Double
    ) -> Double {
        let normalizedHighSaturation = min(max((saturation - 0.55) / 0.45, 0), 1)
        return 1 - normalizedHighSaturation * maximumReduction
    }

    /// 在目标强度内寻找同时满足主要文字 7:1、次要文字 4.5:1 的最高主题色占比。
    private static func accessibleBlend(
        source: RGBComponents,
        base: RGBComponents,
        maximumStrength: Double,
        primaryText: RGBComponents,
        secondaryText: RGBComponents
    ) -> RGBComponents {
        var strength = maximumStrength
        while strength > 0 {
            let candidate = source.blended(over: base, strength: strength)
            if contrastRatio(primaryText, candidate) >= 7,
               contrastRatio(secondaryText, candidate) >= 4.5 {
                return candidate
            }
            strength -= 0.005
        }
        return base
    }

    /// 计算两种不透明 sRGB 颜色的 WCAG 对比度。
    private static func contrastRatio(_ lhs: RGBComponents, _ rhs: RGBComponents) -> Double {
        let lighter = max(lhs.relativeLuminance, rhs.relativeLuminance)
        let darker = min(lhs.relativeLuminance, rhs.relativeLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    /// 表达页面私有的不透明 sRGB 分量，并提供混色与亮度计算。
    private struct RGBComponents {
        let red: Double
        let green: Double
        let blue: Double

        /// 从 RGBA Hex 读取 RGB，来源 alpha 仅由外层用于有效性判断。
        init(rgbaHex: UInt32) {
            red = Double((rgbaHex >> 24) & 0xFF) / 255
            green = Double((rgbaHex >> 16) & 0xFF) / 255
            blue = Double((rgbaHex >> 8) & 0xFF) / 255
        }

        /// 从已按外观解析的 UIKit 语义色读取不透明 sRGB 分量。
        init?(uiColor: UIColor) {
            var red: CGFloat = 0
            var green: CGFloat = 0
            var blue: CGFloat = 0
            var alpha: CGFloat = 0
            guard uiColor.getRed(&red, green: &green, blue: &blue, alpha: &alpha) else {
                return nil
            }
            self.init(red: Double(red), green: Double(green), blue: Double(blue))
        }

        /// 从 0...1 浮点分量构造颜色。
        init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        /// 从 8bit 分量构造颜色，和现有文字语义令牌保持同源。
        init(red8: UInt8, green8: UInt8, blue8: UInt8) {
            self.init(
                red: Double(red8) / 255,
                green: Double(green8) / 255,
                blue: Double(blue8) / 255
            )
        }

        var color: Color {
            Color.xmSRGB(red: red, green: green, blue: blue, opacity: 1)
        }

        var saturation: Double {
            let maximum = max(red, green, blue)
            let minimum = min(red, green, blue)
            return maximum == 0 ? 0 : (maximum - minimum) / maximum
        }

        var relativeLuminance: Double {
            0.2126 * Self.linearized(red)
                + 0.7152 * Self.linearized(green)
                + 0.0722 * Self.linearized(blue)
        }

        /// 将封面色以指定占比预混入不透明系统底色。
        func blended(over base: RGBComponents, strength: Double) -> RGBComponents {
            let resolvedStrength = min(max(strength, 0), 1)
            return RGBComponents(
                red: red * resolvedStrength + base.red * (1 - resolvedStrength),
                green: green * resolvedStrength + base.green * (1 - resolvedStrength),
                blue: blue * resolvedStrength + base.blue * (1 - resolvedStrength)
            )
        }

        /// 将 sRGB 分量转换为线性亮度分量。
        private static func linearized(_ component: Double) -> Double {
            component <= 0.04045
                ? component / 12.92
                : pow((component + 0.055) / 1.055, 2.4)
        }
    }
}

/// 绘制贯穿全页的封面主题画布，滚动收起只使用位置变换。
private struct BookWorkspaceAtmosphere: View {
    let palette: BookWorkspaceThemePalette
    let headerHeight: CGFloat
    let visualState: BookWorkspaceScrollVisualState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let viewportTop = max(visualState.viewportTop, geometry.safeAreaInsets.top)
            let restingExtent = max(viewportTop + headerHeight, 1)
            let collapseDistance = min(max(visualState.effectiveOffset, 0), headerHeight)
            let overscrollDistance = max(-visualState.effectiveOffset, 0)
            let stretchScale = (restingExtent + overscrollDistance) / restingExtent

            ZStack(alignment: .top) {
                palette.canvasColor

                if headerHeight > 0 {
                    LinearGradient(
                        colors: [palette.headerLeadingColor, palette.headerTrailingColor],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .black, location: 0),
                                .init(color: .black, location: 0.42),
                                .init(color: .black.opacity(0.25), location: 0.72),
                                .init(color: .clear, location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: restingExtent)
                    .scaleEffect(x: 1, y: stretchScale, anchor: .top)
                    .offset(y: -collapseDistance)
                }
            }
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.18),
                value: palette.identifier
            )
        }
        .ignoresSafeArea(.container, edges: .top)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// 单书工作台删除确认请求；使用稳定业务主键避免弹窗期间列表刷新错删其他内容。
private enum BookWorkspaceDeletionRequest: Identifiable {
    case related(BookRelatedExcerpt)
    case review(BookReviewExcerpt)

    var id: String {
        switch self {
        case .related(let item): "related-\(item.id)"
        case .review(let item): "review-\(item.id)"
        }
    }
}

/// 单书四域工作台主体；四个滚动容器常驻，保证切换后恢复各自滚动位置。
private struct BookWorkspaceContentView: View {
#if DEBUG
    private static let notesLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "xmnote",
        category: "BookWorkspaceNotes"
    )
#endif

    let bookId: Int64
    let launchConfiguration: BookDetailLaunchConfiguration
    @Bindable var viewModel: BookDetailViewModel
    let onStartReading: (Int64) -> Void
    let onSupplementReading: (Int64) -> Void
    let onOpenReadingDetail: (Int64) -> Void
    let onOpenChapterNotes: (Int64, Int64, String) -> Void
    let onOpenBook: (Int64) -> Void
    let onOpenBookRoute: (BookRoute) -> Void
    let readingTimerZoomConfiguration: ReadingTimerZoomSourceConfiguration?

    @Environment(AppNavigationCoordinator.self) private var navigationCoordinator
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedSection: BookWorkspaceSection
    @State private var presentationStore = BookWorkspacePresentationStore()
    @State private var searchQueries: [BookWorkspaceSection: String] = [:]
    @State private var isSearchPresented = false
    @State private var catalogFilter = CatalogFilter.all
    @State private var notesWithIdeasOnly = false
    @State private var selectedRelatedCategoryID: Int64?
    @State private var expandedChapterIDs: Set<Int64> = []
    @State private var showsRelatedCategoryPicker = false
    @State private var isRatingSheetPresented = false
    @State private var relatedBookDraft: RelatedBookRelationDraft?
    @State private var pendingDeletion: BookWorkspaceDeletionRequest?
    @State private var relationLoadErrorMessage: String?
    @State private var isBookHeaderFullyCollapsed = false
    @State private var readLoadingGate = LoadingGate()
    @State private var notesLoadingGate = LoadingGate()
    @State private var hasAppliedCatalogFocus = false
#if DEBUG
    @State private var debugIdentifier = UUID().uuidString
    @State private var debugInputRevision = 0
#endif

    private enum Layout {
        static let linkedCoverWidth: CGFloat = 48
        static let chapterIndent: CGFloat = 18
    }

    /// 以路由首帧参数初始化唯一选中域；指定章节入口不会先渲染书摘页再切换目录。
    init(
        bookId: Int64,
        launchConfiguration: BookDetailLaunchConfiguration,
        viewModel: BookDetailViewModel,
        onStartReading: @escaping (Int64) -> Void,
        onSupplementReading: @escaping (Int64) -> Void,
        onOpenReadingDetail: @escaping (Int64) -> Void,
        onOpenChapterNotes: @escaping (Int64, Int64, String) -> Void,
        onOpenBook: @escaping (Int64) -> Void,
        onOpenBookRoute: @escaping (BookRoute) -> Void,
        readingTimerZoomConfiguration: ReadingTimerZoomSourceConfiguration?
    ) {
        self.bookId = bookId
        self.launchConfiguration = launchConfiguration
        self.viewModel = viewModel
        self.onStartReading = onStartReading
        self.onSupplementReading = onSupplementReading
        self.onOpenReadingDetail = onOpenReadingDetail
        self.onOpenChapterNotes = onOpenChapterNotes
        self.onOpenBook = onOpenBook
        self.onOpenBookRoute = onOpenBookRoute
        self.readingTimerZoomConfiguration = readingTimerZoomConfiguration
        _selectedSection = State(initialValue: launchConfiguration.initialSection)
    }

    var body: some View {
        let currentPresentationInput = presentationInput

        Group {
            if let book = viewModel.book {
                workspace(book)
            } else if readLoadingGate.isVisible {
                LoadingStateView("正在加载书籍内容…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.clear
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(Color.surfacePage, for: .navigationBar)
        .toolbarBackgroundVisibility(.hidden, for: .navigationBar)
        .toolbarColorScheme(colorScheme, for: .navigationBar)
        .tint(Color.iconPrimary)
        .searchable(
            text: activeSearchQuery,
            isPresented: $isSearchPresented,
            placement: .toolbar,
            prompt: searchPrompt
        )
        .searchToolbarBehavior(.automatic)
        .toolbar {
            workspaceNavigationTitle
            toolbarActions
            workspaceToolbar
        }
        .sheet(isPresented: $showsRelatedCategoryPicker) {
            relatedCategoryPicker
        }
        .sheet(isPresented: $isRatingSheetPresented) {
            if let book = viewModel.book {
                XMBookRatingSheet(bookTitle: book.name, initialScore: book.score) { score in
                    try await viewModel.updateBookRating(score: score)
                }
            }
        }
        .sheet(item: $relatedBookDraft) { draft in
            RelatedBookRelationEditorSheet(
                draft: draft,
                isSaving: viewModel.isWorkspaceWriting,
                onSave: viewModel.saveRelatedBookRelationDraft
            )
        }
        .xmSystemAlert(item: $pendingDeletion) { request in
            deletionDescriptor(for: request)
        }
        .xmSystemAlert(
            isPresented: workspaceActionErrorBinding,
            descriptor: workspaceActionErrorDescriptor
        )
        .xmSystemAlert(
            isPresented: $relationLoadErrorMessage.isPresented(),
            descriptor: relationLoadErrorDescriptor
        )
        .onAppear {
            viewModel.startObservation()
            syncReadLoadingVisibility()
            syncNotesLoadingVisibility()
        }
        .onChange(of: viewModel.book == nil) { _, isBookUnavailable in
            syncReadLoadingVisibility()
            if isBookUnavailable {
                isBookHeaderFullyCollapsed = false
            }
        }
        .onChange(of: isSearchPresented) { wasPresented, isPresented in
            guard wasPresented, !isPresented else { return }
            searchQueries.removeAll()
        }
        .onChange(of: viewModel.notesLoadState, initial: true) { _, _ in
            syncNotesLoadingVisibility()
        }
        .onChange(of: viewModel.book?.chapters.map(\.id) ?? []) { _, ids in
            applyInitialCatalogExpansion(chapterIDs: ids)
        }
        .task(id: currentPresentationInput) {
            guard !Task.isCancelled else { return }
            guard let input = currentPresentationInput else { return }
#if DEBUG
            debugInputRevision &+= 1
            Self.notesLogger.debug(
                "[book.workspace.notes.input.delivered] host=\(debugIdentifier, privacy: .public) bookID=\(input.book.id) state=\(input.notesLoadState.rawValue, privacy: .public) count=\(input.notes.count) loadingVisible=\(input.isNotesLoadingFeedbackVisible) revision=\(debugInputRevision)"
            )
#endif
            presentationStore.update(with: input)
        }
        .onDisappear {
            viewModel.stopObservation()
            presentationStore.stop()
            readLoadingGate.hideImmediately()
            notesLoadingGate.hideImmediately()
            isSearchPresented = false
            searchQueries.removeAll()
        }
    }

    /// 常驻工具栏主标题，仅在书籍概览完全收起且搜索未展开时淡入，避免条件插入导致导航栏重排。
    @ToolbarContentBuilder
    private var workspaceNavigationTitle: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            Text(viewModel.book?.name ?? "")
                .font(AppTypography.headline)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
                .opacity(isWorkspaceNavigationTitleVisible ? 1 : 0)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 0.16),
                    value: isWorkspaceNavigationTitleVisible
                )
                .accessibilityHidden(!isWorkspaceNavigationTitleVisible)
                .accessibilityAddTraits(.isHeader)
        }
    }

    /// 收敛标题显隐条件；搜索展开时让位给系统搜索框，关闭后按当前折叠状态恢复。
    private var isWorkspaceNavigationTitleVisible: Bool {
        isBookHeaderFullyCollapsed && !isSearchPresented && viewModel.book != nil
    }

    @ToolbarContentBuilder
    private var toolbarActions: some ToolbarContent {
        ToolbarItem(placement: .topBarTrailing) {
            Menu {
                Button("开始阅读计时", systemImage: "timer") {
                    onStartReading(bookId)
                }

                currentSectionMenuContent

                Divider()

                Button("查看阅读详情", systemImage: "chart.xyaxis.line") {
                    onOpenReadingDetail(bookId)
                }

                Button("补录阅读", systemImage: "plus.circle") {
                    onSupplementReading(bookId)
                }

                Divider()

                Button("编辑书籍", systemImage: "pencil") {
                    editBook()
                }
            } label: {
                neutralToolbarIcon("ellipsis", accessibilityLabel: "更多书籍操作")
            }
            .disabled(viewModel.book == nil)
            .xmToolbarNeutralTint()
        }
    }

    /// 使用系统默认搜索项与独立创作项组成平台自适应工具栏，Liquid Glass 和分组形态完全交给系统。
    @ToolbarContentBuilder
    private var workspaceToolbar: some ToolbarContent {
        DefaultToolbarItem(kind: .search, placement: workspaceToolbarPlacement)

        if showsPrimaryAction {
            ToolbarSpacer(.fixed, placement: workspaceToolbarPlacement)
            ToolbarItem(placement: workspaceToolbarPlacement) {
                primaryActionButton
            }
        }
    }

    @ViewBuilder
    private var currentSectionMenuContent: some View {
        switch selectedSection {
        case .catalog:
            Section("目录") {
                Picker("目录范围", selection: $catalogFilter) {
                    ForEach(CatalogFilter.allCases, id: \.self) { option in
                        Text(option.title).tag(option)
                    }
                }

                Picker("目录排序", selection: sortSelection(for: .chapters)) {
                    ForEach(BookContentSortRule.allowedRules(for: .chapters), id: \.self) { option in
                        Text(option.title(for: .chapters)).tag(option)
                    }
                }
                .disabled(viewModel.isWorkspaceWriting)

                Button("全部展开", systemImage: "rectangle.expand.vertical") {
                    expandedChapterIDs = Set(viewModel.book?.chapters.map(\.id) ?? [])
                }
                Button("全部收起", systemImage: "rectangle.compress.vertical") {
                    expandedChapterIDs.removeAll()
                }
                Button("管理目录", systemImage: "list.bullet.rectangle") {
                    guard let book = viewModel.book else { return }
                    onOpenBookRoute(
                        .chapterManager(
                            bookID: bookId,
                            bookName: book.name,
                            doubanID: book.doubanID,
                            focusChapterID: nil
                        )
                    )
                }
            }
        case .notes:
            Section("书摘") {
                Picker("书摘排序", selection: sortSelection(for: .notes)) {
                    ForEach(BookContentSortRule.allowedRules(for: .notes), id: \.self) { option in
                        Text(option.title(for: .notes)).tag(option)
                    }
                }
                .disabled(viewModel.isWorkspaceWriting)

                Toggle("只看有想法", isOn: $notesWithIdeasOnly)
            }
        case .related:
            Section("相关") {
                Menu("相关分类", systemImage: "square.grid.2x2") {
                    Button("全部分类") {
                        selectedRelatedCategoryID = nil
                    }

                    ForEach(viewModel.relatedCategories) { category in
                        Button {
                            selectedRelatedCategoryID = category.id
                        } label: {
                            if selectedRelatedCategoryID == category.id {
                                Label(category.title, systemImage: "checkmark")
                            } else {
                                Text(category.title)
                            }
                        }
                    }
                }

                Picker("相关排序", selection: sortSelection(for: .related)) {
                    ForEach(BookContentSortRule.allowedRules(for: .related), id: \.self) { option in
                        Text(option.title(for: .related)).tag(option)
                    }
                }
                .disabled(viewModel.isWorkspaceWriting)
            }
        case .reviews:
            Section("书评") {
                Picker("书评排序", selection: sortSelection(for: .reviews)) {
                    ForEach(BookContentSortRule.allowedRules(for: .reviews), id: \.self) { option in
                        Text(option.title(for: .reviews)).tag(option)
                    }
                }
                .disabled(viewModel.isWorkspaceWriting)
            }
        }
    }

    /// 把菜单选择直接映射到 Repository 持久化规则；数据库观察确认后刷新选中态与列表顺序。
    private func sortSelection(for type: BookContentSortType) -> Binding<BookContentSortRule> {
        Binding(
            get: { viewModel.workspace.sortPreferences.rule(for: type) },
            set: { viewModel.updateContentSort(type: type, rule: $0) }
        )
    }

    /// 为系统导航栏动作提供直接的中性前景，避免 Menu 标签重新继承应用级品牌 tint。
    private func neutralToolbarIcon(_ systemName: String, accessibilityLabel: String) -> some View {
        Image(systemName: systemName)
            .symbolRenderingMode(.monochrome)
            .foregroundStyle(Color.iconPrimary)
            .accessibilityLabel(accessibilityLabel)
    }

    /// 组合唯一固定书籍头部、固定 Tab 与四个常驻纯内容页。
    private func workspace(_ book: BookDetail) -> some View {
        let coordinator = navigationCoordinator
        let notesKeyword = searchQuery(.notes)
        let relatedKeyword = searchQuery(.related)
        let reviewsKeyword = searchQuery(.reviews)

        return BookWorkspaceCollectionView(
                book: book,
                snapshots: Dictionary(
                    uniqueKeysWithValues: BookWorkspaceSection.allCases.map {
                        ($0, presentationStore.snapshot(for: $0))
                    }
                ),
                committedSection: selectedSection,
                notesCount: workspaceNotesCount(for: book),
                notesLoadState: viewModel.notesLoadState,
                reduceMotion: reduceMotion,
                colorScheme: colorScheme,
                dynamicTypeSize: dynamicTypeSize,
                verticalSizeClass: verticalSizeClass,
                canvasColor: Color.surfacePage,
                contentSurfaceColor: Color.surfaceCard,
                appearanceID: workspaceAppearanceID,
                catalogFocusPlan: launchConfiguration.catalogFocusPlan(chapters: book.chapters),
                onSectionCommit: commitSection,
                onBookHeaderFullyCollapsedChange: updateBookHeaderCollapseState,
                onOpenReadingDetail: {
                    onOpenReadingDetail(bookId)
                },
                onEditBook: editBook,
                onEditRating: {
                    isRatingSheetPresented = true
                },
                onToggleChapter: toggleChapterExpansion,
                onOpenChapter: { chapter in
                    onOpenChapterNotes(bookId, chapter.id, chapter.title)
                },
                onOpenNote: { note in
                    coordinator.present(
                        .contentViewer(
                            source: .bookNotes(bookId: bookId),
                            initialItemID: .note(note.id),
                            keyword: notesKeyword
                        )
                    )
                },
                onEditNote: { note in
                    coordinator.present(.noteEditor(mode: .edit(noteId: note.id), seed: nil))
                },
                onOpenRelated: { item in
                    if item.linkedBookID > 0 {
                        if item.isLinkedBookPlaceholder {
                            coordinator.presentBookEditor(
                                mode: .editRelatedPlaceholder(
                                    bookId: item.linkedBookID,
                                    sourceBookId: bookId
                                )
                            )
                        } else {
                            onOpenBook(item.linkedBookID)
                        }
                    } else {
                        coordinator.present(
                            .contentViewer(
                                source: .bookRelated(bookId: bookId),
                                initialItemID: .relevant(item.id),
                                keyword: relatedKeyword
                            )
                        )
                    }
                },
                onEditRelated: editRelated,
                onDeleteRelated: { item in
                    pendingDeletion = .related(item)
                },
                onOpenReview: { item in
                    coordinator.present(
                        .contentViewer(
                            source: .bookReviews(bookId: bookId),
                            initialItemID: .review(item.id),
                            keyword: reviewsKeyword
                        )
                    )
                },
                onEditReview: { item in
                    coordinator.present(.reviewEditor(.edit(reviewID: item.id)))
                },
                onDeleteReview: { item in
                    pendingDeletion = .review(item)
                }
            )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .background(Color.surfacePage.ignoresSafeArea())
    }

    /// 接收原生 Pager 最终落定域；拖动中途不会提前切换搜索、菜单或底部操作语义。
    private func commitSection(_ section: BookWorkspaceSection) {
        guard selectedSection != section else { return }
        selectedSection = section
    }

    /// 只接收 Header 完全收起边界的离散变化，避免连续滚动偏移进入 SwiftUI 状态树。
    private func updateBookHeaderCollapseState(_ isFullyCollapsed: Bool) {
        guard isBookHeaderFullyCollapsed != isFullyCollapsed else { return }
        isBookHeaderFullyCollapsed = isFullyCollapsed
    }

    /// 普通入口沿用全展开；指定章节入口只展开目标祖先，避免无关分支改变首帧位置。
    private func applyInitialCatalogExpansion(chapterIDs: [Int64]) {
        guard !hasAppliedCatalogFocus, !chapterIDs.isEmpty, let book = viewModel.book else { return }
        hasAppliedCatalogFocus = true
        if let plan = launchConfiguration.catalogFocusPlan(chapters: book.chapters) {
            catalogFilter = .all
            expandedChapterIDs = plan.expandedAncestorIDs
        } else if expandedChapterIDs.isEmpty {
            expandedChapterIDs = Set(chapterIDs)
        }
    }

    @ViewBuilder
    private func workspaceContent(_ book: BookDetail, section: BookWorkspaceSection) -> some View {
        switch section {
        case .notes:
            notesWorkspaceContent(book)
        case .catalog, .related, .reviews:
            sectionContent(book, section: section)
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.top, Spacing.section)
                .safeAreaPadding(.bottom, Spacing.double)
        }
    }

    @ViewBuilder
    private func sectionContent(_ book: BookDetail, section: BookWorkspaceSection) -> some View {
        switch section {
        case .catalog:
            catalogContent(book)
        case .notes:
            EmptyView()
        case .related:
            relatedContent
        case .reviews:
            reviewsContent
        }
    }

    /// 渲染树状目录；父章展开状态决定子章可见性，点击章节 Push 到章节书摘页。
    private func catalogContent(_ book: BookDetail) -> some View {
        let chapters = visibleChapters(from: filteredChapters(book.chapters))
        return Group {
            if chapters.isEmpty {
                contentUnavailable(
                    role: searchQuery(.catalog).isEmpty ? .empty : .noResults,
                    title: searchQuery(.catalog).isEmpty ? "暂无目录" : "没有匹配的目录",
                    systemImage: "list.bullet.indent",
                    description: "目录同步或创建后会显示在这里"
                )
            } else {
                VStack(spacing: Spacing.none) {
                    ForEach(Array(chapters.enumerated()), id: \.element.id) { index, chapter in
                        catalogRow(chapter, allChapters: book.chapters)
                        if index < chapters.count - 1 {
                            Divider()
                                .padding(.leading, Spacing.contentEdge + CGFloat(max(0, chapter.level - 1)) * Layout.chapterIndent)
                        }
                    }
                }
                .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
            }
        }
    }

    /// 渲染单条目录，收藏与书摘数量保持弱辅助层级。
    private func catalogRow(_ chapter: BookDetailChapter, allChapters: [BookDetailChapter]) -> some View {
        let hasChildren = allChapters.contains { $0.parentID == chapter.id }
        return HStack(spacing: Spacing.cozy) {
            if hasChildren {
                Button {
                    toggleChapterExpansion(chapter.id)
                } label: {
                    Image(systemName: expandedChapterIDs.contains(chapter.id) ? "chevron.down" : "chevron.right")
                        .font(AppTypography.captionSemibold)
                        .foregroundStyle(Color.textSecondary)
                        .frame(
                            width: Spacing.double,
                            height: InteractionMetrics.minimumTouchTarget
                        )
                }
                .buttonStyle(.plain)
                .accessibilityLabel(expandedChapterIDs.contains(chapter.id) ? "收起章节" : "展开章节")
            } else {
                Color.clear.frame(width: Spacing.double)
            }

            Button {
                onOpenChapterNotes(bookId, chapter.id, chapter.title)
            } label: {
                HStack(spacing: Spacing.cozy) {
                    VStack(alignment: .leading, spacing: Spacing.compact) {
                        Text(chapter.title)
                            .font(AppTypography.body)
                            .foregroundStyle(Color.textPrimary)
                            .multilineTextAlignment(.leading)

                        if chapter.noteCount > 0 {
                            Text("\(chapter.noteCount) 条书摘")
                                .font(AppTypography.caption)
                                .foregroundStyle(Color.textSecondary)
                        }
                    }

                    Spacer(minLength: Spacing.base)

                    if chapter.isStarred {
                        Image(systemName: "star.fill")
                            .foregroundStyle(XMStarredAppearance.foreground)
                            .accessibilityLabel("已收藏")
                    }

                    Image(systemName: "chevron.right")
                        .font(AppTypography.captionSemibold)
                        .foregroundStyle(Color.textHint)
                }
                .frame(minHeight: InteractionMetrics.minimumTouchTarget)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.leading, Spacing.contentEdge + CGFloat(max(0, chapter.level - 1)) * Layout.chapterIndent)
        .padding(.trailing, Spacing.contentEdge)
        .padding(.vertical, Spacing.compact)
    }

    /// 切换父章展开状态；只影响目录结构，不重排真实章节。
    private func toggleChapterExpansion(_ chapterID: Int64) {
        if expandedChapterIDs.contains(chapterID) {
            expandedChapterIDs.remove(chapterID)
        } else {
            expandedChapterIDs.insert(chapterID)
        }
    }

    /// 应用目录文本与真实中频筛选条件。
    private func filteredChapters(_ chapters: [BookDetailChapter]) -> [BookDetailChapter] {
        let keyword = normalizedSearchQuery(.catalog)
        return chapters.filter { chapter in
            let matchesKeyword = keyword.isEmpty || chapter.title.localizedCaseInsensitiveContains(keyword)
            let matchesFilter: Bool
            switch catalogFilter {
            case .all:
                matchesFilter = true
            case .starred:
                matchesFilter = chapter.isStarred
            case .withNotes:
                matchesFilter = chapter.noteCount > 0
            }
            return matchesKeyword && matchesFilter
        }
    }

    /// 根据父子关系与展开集合生成目录可见序列，孤立章节仍作为根层展示。
    private func visibleChapters(from chapters: [BookDetailChapter]) -> [BookDetailChapter] {
        let ids = Set(chapters.map(\.id))
        let roots = chapters.filter { $0.parentID == 0 || !ids.contains($0.parentID) }
        var result: [BookDetailChapter] = []

        func appendTree(_ chapter: BookDetailChapter) {
            result.append(chapter)
            guard expandedChapterIDs.contains(chapter.id) else { return }
            chapters
                .filter { $0.parentID == chapter.id }
                .sorted { lhs, rhs in
                    lhs.order == rhs.order ? lhs.id < rhs.id : lhs.order < rhs.order
                }
                .forEach(appendTree)
        }

        roots
            .sorted { lhs, rhs in
                lhs.order == rhs.order ? lhs.id < rhs.id : lhs.order < rhs.order
            }
            .forEach(appendTree)
        return result
    }

    /// 在顶层懒加载结构中输出章节 Section，使系统粘性头与逐行回收同时成立。
    @ViewBuilder
    private func notesWorkspaceContent(_ book: BookDetail) -> some View {
        let groups = noteGroups(for: book)
        if groups.isEmpty {
            contentUnavailable(
                role: normalizedSearchQuery(.notes).isEmpty ? .empty : .noResults,
                title: normalizedSearchQuery(.notes).isEmpty ? "还没有书摘" : "没有匹配的书摘",
                systemImage: "text.quote",
                description: "记录一句触动你的内容，稍后会按章节整理在这里"
            )
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.top, Spacing.section)
            .safeAreaPadding(.bottom, Spacing.double)
        } else if isNotesTimeSorted, let group = groups.first {
            BookWorkspaceChapterHeader(
                title: group.title,
                count: group.notes.count,
                isStarred: false,
                canvasColor: Color.surfacePage,
                canvasPaletteID: workspaceAppearanceID,
                reduceMotion: reduceMotion
            )
            .padding(.top, Spacing.section)

            noteRows(group.notes)

            Color.clear.frame(height: Spacing.double)
        } else {
            Color.clear.frame(height: Spacing.section)

            ForEach(groups) { group in
                Section {
                    noteRows(group.notes)
                } header: {
                    BookWorkspaceChapterHeader(
                        title: group.title,
                        count: group.notes.count,
                        isStarred: group.isStarred,
                        canvasColor: Color.surfacePage,
                        canvasPaletteID: workspaceAppearanceID,
                        reduceMotion: reduceMotion
                    )
                } footer: {
                    Color.clear.frame(height: Spacing.section)
                }
            }

            Color.clear.frame(height: Spacing.double)
        }
    }

    /// 将每条书摘直接输出为独立懒加载卡片，通过留白建立条目与章节层级。
    @ViewBuilder
    private func noteRows(_ notes: [NoteExcerpt]) -> some View {
        ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
            BookWorkspaceStatefulNoteItem(
                row: BookWorkspaceNoteRow(note: note, footerText: note.footerText),
                state: presentationStore.rowState(for: note.id),
                surfaceColor: Color.surfaceCard,
                onOpen: { openNote(note) },
                onEdit: { editNote(note) }
            )
            .padding(.top, index == .zero ? Spacing.cozy : Spacing.base)
        }
    }

    /// 应用搜索和筛选后按章节深度优先阅读顺序分组；失效章节统一收敛到“未指定章节”。
    private func noteGroups(for book: BookDetail) -> [BookNoteGroup] {
        let keyword = normalizedSearchQuery(.notes)
        let items = viewModel.notes.filter { note in
            let matchesKeyword = keyword.isEmpty
                || note.searchableContentText.localizedCaseInsensitiveContains(keyword)
                || note.searchableIdeaText.localizedCaseInsensitiveContains(keyword)
                || note.chapterTitle.localizedCaseInsensitiveContains(keyword)
                || note.tagNames.contains { $0.localizedCaseInsensitiveContains(keyword) }
            return matchesKeyword && (!notesWithIdeasOnly || note.hasSourceIdea)
        }

        if isNotesTimeSorted {
            guard !items.isEmpty else { return [] }
            return [
                BookNoteGroup(
                    id: -1,
                    title: notesSort.title(for: .notes),
                    isStarred: false,
                    notes: items
                )
            ]
        }

        let chapterByID = Dictionary(uniqueKeysWithValues: book.chapters.map { ($0.id, $0) })
        let validChapterIDs = Set(chapterByID.keys)
        let readingOrder = chapterReadingOrder(book.chapters)
        let grouped = Dictionary(grouping: items) { note in
            validChapterIDs.contains(note.chapterID) ? note.chapterID : 0
        }
        return grouped.map { chapterID, notes in
            let chapter = chapterByID[chapterID]
            return BookNoteGroup(
                id: chapterID,
                title: chapter?.title ?? "未指定章节",
                isStarred: chapter?.isStarred ?? false,
                notes: notes.sorted { lhs, rhs in
                    lhs.createdDate == rhs.createdDate ? lhs.id > rhs.id : lhs.createdDate > rhs.createdDate
                }
            )
        }
        .sorted { lhs, rhs in
            if lhs.id == 0 { return false }
            if rhs.id == 0 { return true }
            let leftOrder = readingOrder[lhs.id] ?? Int.max
            let rightOrder = readingOrder[rhs.id] ?? Int.max
            return leftOrder == rightOrder ? lhs.id < rhs.id : leftOrder < rightOrder
        }
    }

    /// 根据父子关系生成稳定深度优先顺序，孤立章节仍按根章节加入结果。
    private func chapterReadingOrder(_ chapters: [BookDetailChapter]) -> [Int64: Int] {
        let chapterIDs = Set(chapters.map(\.id))
        let roots = chapters.filter { $0.parentID == 0 || !chapterIDs.contains($0.parentID) }
        let childrenByParent = Dictionary(grouping: chapters) { $0.parentID }
        var result: [Int64: Int] = [:]
        var nextIndex = 0

        func appendTree(_ chapter: BookDetailChapter) {
            guard result[chapter.id] == nil else { return }
            result[chapter.id] = nextIndex
            nextIndex += 1
            childrenByParent[chapter.id, default: []]
                .sorted(by: chapterComesBefore)
                .forEach(appendTree)
        }

        roots.sorted(by: chapterComesBefore).forEach(appendTree)
        chapters.sorted(by: chapterComesBefore).forEach(appendTree)
        return result
    }

    /// 使用章节原始排序值与 ID 生成稳定同级顺序。
    private func chapterComesBefore(_ lhs: BookDetailChapter, _ rhs: BookDetailChapter) -> Bool {
        lhs.order == rhs.order ? lhs.id < rhs.id : lhs.order < rhs.order
    }

    /// 打开当前书摘在单书查看范围中的完整内容。
    private func openNote(_ note: NoteExcerpt) {
        navigationCoordinator.present(
            .contentViewer(
                source: .bookNotes(bookId: bookId),
                initialItemID: .note(note.id),
                keyword: searchQuery(.notes)
            )
        )
    }

    /// 复用既有编辑器链路编辑当前书摘，不在列表层复制写入逻辑。
    private func editNote(_ note: NoteExcerpt) {
        navigationCoordinator.present(
            .noteEditor(mode: .edit(noteId: note.id), seed: nil)
        )
    }

    /// 渲染按类别分组的相关内容，普通内容进入 viewer，关联书籍继续进入目标书工作台。
    private var relatedContent: some View {
        let groups = relatedGroups
        return Group {
            if groups.isEmpty {
                contentUnavailable(
                    role: normalizedSearchQuery(.related).isEmpty ? .empty : .noResults,
                    title: normalizedSearchQuery(.related).isEmpty ? "还没有相关内容" : "没有匹配的相关内容",
                    systemImage: "link",
                    description: "把文章、观点或关联书籍整理到当前书中"
                )
            } else {
                LazyVStack(alignment: .leading, spacing: Spacing.section) {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: Spacing.none) {
                            HStack {
                                Text(group.title)
                                    .font(AppTypography.headline)
                                    .foregroundStyle(Color.textPrimary)
                                Spacer(minLength: Spacing.base)
                                Text("\(group.items.count)")
                                    .font(AppTypography.caption)
                                    .foregroundStyle(Color.textHint)
                            }
                            .padding(.horizontal, Spacing.contentEdge)
                            .padding(.vertical, Spacing.base)

                            Divider()

                            ForEach(Array(group.items.enumerated()), id: \.element.id) { index, item in
                                relatedRow(item)
                                if index < group.items.count - 1 {
                                    Divider().padding(.leading, Spacing.contentEdge)
                                }
                            }
                        }
                        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
                    }
                }
            }
        }
    }

    private var relatedGroups: [BookRelatedGroup] {
        let keyword = normalizedSearchQuery(.related)
        let items = viewModel.related.filter { item in
            let matchesCategory = selectedRelatedCategoryID == nil || item.categoryID == selectedRelatedCategoryID
            let matchesKeyword = keyword.isEmpty
                || item.title.localizedCaseInsensitiveContains(keyword)
                || item.contentPlainText.localizedCaseInsensitiveContains(keyword)
                || item.linkedBookTitle.localizedCaseInsensitiveContains(keyword)
                || item.linkedBookAuthor.localizedCaseInsensitiveContains(keyword)
            return matchesCategory && matchesKeyword
        }
        let grouped = Dictionary(grouping: items) { $0.categoryID }
        let orderByID = Dictionary(uniqueKeysWithValues: viewModel.relatedCategories.map { ($0.id, $0.order) })
        return grouped.map { categoryID, children in
            BookRelatedGroup(
                id: categoryID,
                title: children.first?.categoryTitle.isEmpty == false ? (children.first?.categoryTitle ?? "") : "未分类",
                items: children
            )
        }
        .sorted { lhs, rhs in
            let leftOrder = orderByID[lhs.id] ?? Int64.max
            let rightOrder = orderByID[rhs.id] ?? Int64.max
            return leftOrder == rightOrder ? lhs.id < rhs.id : leftOrder < rightOrder
        }
    }

    /// 渲染普通相关内容或关联书籍两类真实记录。
    private func relatedRow(_ item: BookRelatedExcerpt, dateText: String? = nil) -> some View {
        Button {
            if item.linkedBookID > 0 {
                onOpenBook(item.linkedBookID)
            } else {
                navigationCoordinator.present(
                    .contentViewer(
                        source: .bookRelated(bookId: bookId),
                        initialItemID: .relevant(item.id),
                        keyword: searchQuery(.related)
                    )
                )
            }
        } label: {
            if item.linkedBookID > 0 {
                HStack(spacing: Spacing.base) {
                    XMBookCover.fixedWidth(
                        Layout.linkedCoverWidth,
                        urlString: item.linkedBookCover,
                        cornerRadius: CornerRadius.inlaySmall,
                        border: .init(color: .surfaceBorderSubtle, width: StrokeWidth.hairline),
                        placeholderIconSize: .small
                    )

                    VStack(alignment: .leading, spacing: Spacing.compact) {
                        Text(item.linkedBookTitle.isEmpty ? "关联书籍" : item.linkedBookTitle)
                            .font(AppTypography.bodyMedium)
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(2)
                        if !item.linkedBookAuthor.isEmpty {
                            Text(item.linkedBookAuthor)
                                .font(AppTypography.footnote)
                                .foregroundStyle(Color.textSecondary)
                                .lineLimit(1)
                        }
                    }

                    Spacer(minLength: Spacing.base)
                    Image(systemName: "chevron.right")
                        .font(AppTypography.captionSemibold)
                        .foregroundStyle(Color.textHint)
                }
                .padding(Spacing.contentEdge)
            } else {
                VStack(alignment: .leading, spacing: Spacing.cozy) {
                    if !item.title.isEmpty {
                        Text(item.title)
                            .font(AppTypography.bodyMedium)
                            .foregroundStyle(Color.textPrimary)
                            .lineLimit(2)
                    }
                    if !item.contentPlainText.isEmpty {
                        Text(item.contentPlainText)
                            .font(AppTypography.subheadline)
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(4)
                            .multilineTextAlignment(.leading)
                    }
                    HStack {
                        if !item.url.isEmpty {
                            Label("链接", systemImage: "link")
                        }
                        Spacer(minLength: Spacing.base)
                        Text(dateText ?? formattedDate(item.createdDate))
                    }
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.contentEdge)
            }
        }
        .buttonStyle(.plain)
    }

    /// 渲染标题优先、正文摘要次之的书评列表，不使用重复大卡片。
    private var reviewsContent: some View {
        let items = filteredReviews
        return Group {
            if items.isEmpty {
                contentUnavailable(
                    role: normalizedSearchQuery(.reviews).isEmpty ? .empty : .noResults,
                    title: normalizedSearchQuery(.reviews).isEmpty ? "还没有书评" : "没有匹配的书评",
                    systemImage: "text.bubble",
                    description: "写下对整本书的判断、收获与推荐理由"
                )
            } else {
                VStack(spacing: Spacing.none) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        reviewRow(item)
                        if index < items.count - 1 {
                            Divider().padding(.leading, Spacing.contentEdge)
                        }
                    }
                }
                .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
            }
        }
    }

    private var filteredReviews: [BookReviewExcerpt] {
        let keyword = normalizedSearchQuery(.reviews)
        return viewModel.reviews.filter { item in
                keyword.isEmpty
                    || item.title.localizedCaseInsensitiveContains(keyword)
                    || item.contentPlainText.localizedCaseInsensitiveContains(keyword)
            }
    }

    /// 渲染书评标题、正文摘要与时间，点击进入同书书评查看器。
    private func reviewRow(_ item: BookReviewExcerpt, dateText: String? = nil) -> some View {
        Button {
            navigationCoordinator.present(
                .contentViewer(
                    source: .bookReviews(bookId: bookId),
                    initialItemID: .review(item.id),
                    keyword: searchQuery(.reviews)
                )
            )
        } label: {
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                Text(item.title.isEmpty ? "书评" : item.title)
                    .font(AppTypography.headline)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if !item.contentPlainText.isEmpty {
                    Text(item.contentPlainText)
                        .font(AppTypography.subheadline)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(5)
                        .multilineTextAlignment(.leading)
                }

                Text(dateText ?? formattedDate(item.createdDate))
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.contentEdge)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// 使用通用紧凑状态生成一致的局部空态，不在列表内追加装饰性大插画。
    private func contentUnavailable(
        role: XMStateRole,
        title: String,
        systemImage: String,
        description: String
    ) -> some View {
        XMCompactStateView(
            role: role,
            title: title,
            message: description,
            systemImage: systemImage
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.double)
    }

    /// 返回指定内容域的原始搜索文本。
    private func searchQuery(_ section: BookWorkspaceSection) -> String {
        searchQueries[section, default: ""]
    }

    /// 将系统搜索框绑定到当前内容域；切换域时系统控件身份不变，只更新查询 owner。
    private var activeSearchQuery: Binding<String> {
        Binding(
            get: { searchQueries[selectedSection, default: ""] },
            set: { searchQueries[selectedSection] = $0 }
        )
    }

    /// 明确搜索所覆盖的当前内容域，避免统一的“搜索”提示产生范围歧义。
    private var searchPrompt: Text {
        switch selectedSection {
        case .catalog:
            Text("搜索本书目录")
        case .notes:
            Text("搜索本书书摘")
        case .related:
            Text("搜索本书相关")
        case .reviews:
            Text("搜索本书书评")
        }
    }

    /// iPhone 使用符合 iOS 26 人体工学的底部搜索；iPad 保持系统顶部工具栏表达。
    private var workspaceToolbarPlacement: ToolbarItemPlacement {
        UIDevice.current.userInterfaceIdiom == .phone ? .bottomBar : .topBarTrailing
    }

    /// 返回去除首尾空白的搜索文本，避免只输入空格时进入伪筛选态。
    private func normalizedSearchQuery(_ section: BookWorkspaceSection) -> String {
        searchQuery(section).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 汇总值语义展示输入，Store 会继续按域比较并只重建发生变化的快照。
    private var presentationInput: BookWorkspacePresentationInput? {
        let book = viewModel.book
        let notes = viewModel.notes
        let notesLoadState = viewModel.notesLoadState
        let relatedCategories = viewModel.relatedCategories
        let related = viewModel.related
        let reviews = viewModel.reviews
        let isNotesLoadingFeedbackVisible = notesLoadingGate.isVisible
        guard let book else { return nil }
        return BookWorkspacePresentationInput(
            book: book,
            notes: notes,
            notesLoadState: notesLoadState,
            isNotesLoadingFeedbackVisible: isNotesLoadingFeedbackVisible,
            relatedCategories: relatedCategories,
            related: related,
            reviews: reviews,
            catalogQuery: searchQuery(.catalog),
            notesQuery: searchQuery(.notes),
            relatedQuery: searchQuery(.related),
            reviewsQuery: searchQuery(.reviews),
            catalogFilter: catalogFilter,
            catalogSort: catalogSort,
            notesSort: notesSort,
            notesWithIdeasOnly: notesWithIdeasOnly,
            selectedRelatedCategoryID: selectedRelatedCategoryID,
            relatedSort: relatedSort,
            reviewSort: reviewSort,
            expandedChapterIDs: expandedChapterIDs
        )
    }

    private var notesSort: BookContentSortRule {
        viewModel.workspace.sortPreferences.notes
    }

    private var catalogSort: BookContentSortRule {
        viewModel.workspace.sortPreferences.chapters
    }

    private var relatedSort: BookContentSortRule {
        viewModel.workspace.sortPreferences.related
    }

    private var reviewSort: BookContentSortRule {
        viewModel.workspace.sortPreferences.reviews
    }

    private var isNotesTimeSorted: Bool {
        notesSort == .createdDateAscending || notesSort == .createdDateDescending
    }

    /// 加载完成后使用书摘列表的数量，加载期间保留详情查询的预期数量。
    private func workspaceNotesCount(for book: BookDetail) -> Int {
        switch viewModel.notesLoadState {
        case .loaded:
            return viewModel.loadedNotesCount ?? viewModel.notes.count
        case .loading, .failed:
            return book.noteCount
        }
    }

    /// 根据当前内容域触发唯一主操作，目录域不会构建按钮。
    private var primaryActionButton: some View {
        Button(primaryActionTitle, systemImage: "square.and.pencil", action: performPrimaryAction)
            .labelStyle(.iconOnly)
            .tint(Color.iconPrimary)
            .disabled(viewModel.book == nil)
            .accessibilityHint("为当前书籍新增\(selectedSection.title)内容")
    }

    private var showsPrimaryAction: Bool {
        selectedSection != .catalog
    }

    private var primaryActionTitle: LocalizedStringKey {
        switch selectedSection {
        case .catalog:
            return ""
        case .notes:
            return "记书摘"
        case .related:
            return "记相关"
        case .reviews:
            return "写书评"
        }
    }

    /// 将主操作映射到真实创建链路；相关内容在多个分类时先用 Sheet 补充必需参数。
    private func performPrimaryAction() {
        switch selectedSection {
        case .catalog:
            return
        case .notes:
            navigationCoordinator.present(
                .noteEditor(
                    mode: .create,
                    seed: NoteEditorSeed(
                        bookId: bookId,
                        chapterId: nil,
                        contentHTML: "",
                        ideaHTML: ""
                    )
                )
            )
        case .related:
            if viewModel.relatedCategories.count == 1,
               let category = viewModel.relatedCategories.first {
                createRelated(in: category)
            } else {
                showsRelatedCategoryPicker = true
            }
        case .reviews:
            navigationCoordinator.present(.reviewEditor(.create(bookID: bookId)))
        }
    }

    /// 打开已补齐书籍与分类参数的相关内容创建任务。
    private func createRelated(in category: BookRelatedCategory) {
        showsRelatedCategoryPicker = false
        navigationCoordinator.present(
            .relevantEditor(.create(bookID: bookId, categoryID: category.id))
        )
    }

    /// 普通相关内容进入富文本编辑器；相关书籍关系先读取草稿，再呈现可替换目标书的 Sheet。
    private func editRelated(_ item: BookRelatedExcerpt) {
        if item.linkedBookID == 0 {
            navigationCoordinator.present(.relevantEditor(.edit(contentID: item.id)))
            return
        }
        Task {
            do {
                relatedBookDraft = try await viewModel.fetchRelatedBookRelationDraft(relationID: item.id)
                if relatedBookDraft == nil {
                    relationLoadErrorMessage = "关联书籍已不存在"
                }
            } catch is CancellationError {
                return
            } catch {
                relationLoadErrorMessage = "关联信息加载失败：\(error.localizedDescription)"
            }
        }
    }

    /// 中心确认仅负责收集删除意图，实际写入统一走 ViewModel 与 Android 软删除事务。
    private func deletionDescriptor(for request: BookWorkspaceDeletionRequest) -> XMSystemAlertDescriptor {
        let title: String
        let message: String
        let action: () -> Void
        switch request {
        case .related(let item):
            title = item.linkedBookID > 0 ? "移除这本相关书？" : "删除这条相关内容？"
            message = "内容会从当前列表移除，并同步保留删除状态。"
            action = { viewModel.deleteRelatedRelation(relationID: item.id) }
        case .review(let item):
            title = "删除这篇书评？"
            message = "书评和附图会从当前列表移除，并同步保留删除状态。"
            action = { viewModel.deleteReview(reviewID: item.id) }
        }
        return XMSystemAlertDescriptor(
            title: title,
            message: message,
            actions: [
                XMSystemAlertAction(title: "取消", role: .cancel) { },
                XMSystemAlertAction(title: "删除", role: .destructive, handler: action)
            ]
        )
    }

    private var workspaceActionErrorBinding: Binding<Bool> {
        Binding(
            get: { viewModel.workspaceActionErrorMessage != nil },
            set: { isPresented in
                if !isPresented { viewModel.consumeWorkspaceActionError() }
            }
        )
    }

    private var workspaceActionErrorDescriptor: XMSystemAlertDescriptor? {
        guard let message = viewModel.workspaceActionErrorMessage else { return nil }
        return XMSystemAlertDescriptor(
            title: "操作未完成",
            message: message,
            actions: [
                XMSystemAlertAction(title: "好", role: .cancel) {
                    viewModel.consumeWorkspaceActionError()
                }
            ]
        )
    }

    private var relationLoadErrorDescriptor: XMSystemAlertDescriptor? {
        guard let message = relationLoadErrorMessage else { return nil }
        return XMSystemAlertDescriptor(
            title: "无法编辑关联书籍",
            message: message,
            actions: [
                XMSystemAlertAction(title: "好", role: .cancel) {
                    relationLoadErrorMessage = nil
                }
            ]
        )
    }

    /// 使用系统 Sheet 承接创建前分类选择，避免把必需参数隐藏进编辑页之后。
    private var relatedCategoryPicker: some View {
        NavigationStack {
            Group {
                if viewModel.relatedCategories.isEmpty {
                    XMContentStateView(
                        role: .empty,
                        title: "暂无可用分类",
                        message: "请先在 Android 端或后续分类管理能力中创建相关分类",
                        systemImage: "square.grid.2x2"
                    )
                } else {
                    List(viewModel.relatedCategories) { category in
                        Button {
                            createRelated(in: category)
                        } label: {
                            HStack {
                                Text(category.title)
                                    .foregroundStyle(Color.textPrimary)
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .foregroundStyle(Color.textHint)
                            }
                        }
                    }
                }
            }
            .navigationTitle("选择相关分类")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") {
                        showsRelatedCategoryPicker = false
                    }
                }
            }
        }
        .presentationDetents([.medium])
    }

    /// 打开当前书籍编辑任务；保存后观察流会自动刷新头部与统计。
    private func editBook() {
        navigationCoordinator.present(.bookEditor(.edit(bookId: bookId)))
    }

    /// 同步读取加载门闩，避免本地数据库快速命中时出现加载闪烁。
    private func syncReadLoadingVisibility() {
        readLoadingGate.update(intent: viewModel.book == nil ? .read : .none)
    }

    /// 仅在书摘观察流真实等待超过读取阈值时展示加载行，快速本地首值保持静默。
    private func syncNotesLoadingVisibility() {
        notesLoadingGate.update(
            intent: viewModel.notesLoadState == .loading ? .read : .none
        )
    }

    /// 为中性内容表面的深浅外观提供稳定刷新身份，不再与封面取色耦合。
    private var workspaceAppearanceID: UInt64 {
        UInt64(colorScheme == .dark ? 1 : 0)
    }

    /// 将 Android 毫秒时间戳转换为列表级日期文案。
    private func formattedDate(_ timestamp: Int64) -> String {
        guard timestamp > 0 else { return "" }
        let date = Date(timeIntervalSince1970: Double(timestamp) / 1000)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}

// MARK: - Reading Detail

/// 第二层阅读详情页，集中展示书籍资料与阅读行为概览，不重复承载四域内容管理。
struct BookChapterNotesView: View {
    let bookId: Int64
    let chapterId: Int64
    let title: String

    @Environment(RepositoryContainer.self) private var repositories
    @Environment(AppNavigationCoordinator.self) private var navigationCoordinator
    @State private var viewModel: BookDetailViewModel?
    @State private var loadingGate = LoadingGate()
    @State private var tabChromeSuppressionToken = UUID()

    var body: some View {
        Group {
            if let viewModel {
                let notes = viewModel.notes.filter { $0.chapterID == chapterId }
                if notes.isEmpty {
                    XMContentStateView(
                        role: .empty,
                        title: "本章暂无书摘",
                        message: "从阅读中记录的内容会出现在这里",
                        systemImage: "text.quote"
                    )
                } else {
                    ScrollView {
                        LazyVStack(spacing: Spacing.none) {
                            ForEach(Array(notes.enumerated()), id: \.element.id) { index, note in
                                chapterNoteRow(note)
                                if index < notes.count - 1 {
                                    Divider().padding(.leading, Spacing.contentEdge)
                                }
                            }
                        }
                        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
                        .padding(Spacing.screenEdge)
                        .safeAreaPadding(.bottom, Spacing.double)
                    }
                    .scrollEdgeEffectStyle(.soft, for: .top)
                }
            } else if loadingGate.isVisible {
                LoadingStateView("正在加载章节书摘…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                Color.surfacePage
            }
        }
        .background(Color.surfacePage)
        .toolbarVisibility(.hidden, for: .tabBar)
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            navigationCoordinator.suppressTabChrome(for: tabChromeSuppressionToken)
            viewModel?.startObservation()
        }
        .task {
            guard viewModel == nil else { return }
            loadingGate.update(intent: .read)
            let newViewModel = BookDetailViewModel(
                bookId: bookId,
                repository: repositories.bookRepository,
                contentRepository: repositories.contentRepository,
                colorRepository: repositories.readCalendarColorRepository
            )
            viewModel = newViewModel
            loadingGate.update(intent: .none)
            newViewModel.startObservation()
        }
        .onChange(of: viewModel == nil) { _, isMissing in
            loadingGate.update(intent: isMissing ? .read : .none)
        }
        .onDisappear {
            viewModel?.stopObservation()
            navigationCoordinator.restoreTabChrome(for: tabChromeSuppressionToken)
            loadingGate.hideImmediately()
        }
    }

    /// 渲染单章书摘行，正文与想法继续遵循全局书摘排版令牌。
    private func chapterNoteRow(_ note: NoteExcerpt) -> some View {
        Button {
            navigationCoordinator.present(
                .contentViewer(
                    source: .bookNotes(bookId: bookId),
                    initialItemID: .note(note.id),
                    keyword: ""
                )
            )
        } label: {
            VStack(alignment: .leading, spacing: Spacing.none) {
                if note.hasSourceContent {
                    CollapsedRichTextPreview(
                        html: note.content,
                        baseFont: ReadingContentTypography.uiBody,
                        textColor: UIColor.xmResolved(Color.textPrimary),
                        lineSpacing: ReadingContentTypography.bodyLineSpacing,
                        maxLines: 6
                    )
                }

                if note.hasSourceIdea {
                    HStack(alignment: .top, spacing: Spacing.base) {
                        RoundedRectangle(cornerRadius: CornerRadius.inlayHairline, style: .continuous)
                            .fill(Color.textHint.opacity(0.6))
                            .frame(width: Spacing.micro)
                        CollapsedRichTextPreview(
                            html: note.idea,
                            baseFont: ReadingContentTypography.uiAnnotation,
                            textColor: UIColor.xmResolved(Color.textSecondary),
                            lineSpacing: ReadingContentTypography.annotationLineSpacing,
                            maxLines: 4
                        )
                    }
                    .padding(.top, Spacing.base)
                }

                if !note.footerText.isEmpty {
                    Text(note.footerText)
                        .font(ReadingContentTypography.metadata)
                        .foregroundStyle(Color.textSecondary)
                        .padding(.top, Spacing.base)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Spacing.contentEdge)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    NavigationStack {
        BookDetailView(bookId: 1)
    }
    .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
    .environment(AppNavigationCoordinator())
}
