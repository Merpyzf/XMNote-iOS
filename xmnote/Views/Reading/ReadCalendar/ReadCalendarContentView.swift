/**
 * [INPUT]: 依赖 CalendarMonthStepperBar/ReadCalendarMonthGrid/ReadCalendarCoverFanStack/ReadCalendarSelectedDaySummaryBar 页面私有组件、ReadCalendarDay/ReadCalendarMonthlyDurationBook 领域模型、ReadCalendarTheme、ReadCalendarTextStyle 与 DesignTokens
 * [OUTPUT]: 对外提供 ReadCalendarContentView（含短内容回弹的月/年视图、事件模式选中日摘要、统计设置过滤态、同期摘要弹层、年度热力图、书封浮层与按模式区分的日期交互）
 * [POS]: ReadCalendar 业务页面壳层组件，负责日历主内容组合、选中日安全区摘要、封面全量展开、日期选择/详情导航分流与业务内弹层触发
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 阅读日历主界面组件，组织月/年切换、日历网格和总结弹层入口。
struct ReadCalendarContentView: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    /// DisplayMode 表示日历内容展示方式（热力图/活动事件/封面）。
    enum DisplayMode: String, CaseIterable, Hashable, Codable {
        case heatmap
        case activityEvent
        case bookCover

        var title: String {
            switch self {
            case .heatmap:
                return "热力图"
            case .activityEvent:
                return "活动事件"
            case .bookCover:
                return "书籍封面"
            }
        }

        /// 返回顶部模式切换器使用的稳定图标，由系统选中底板表达当前状态。
        var iconName: String {
            switch self {
            case .heatmap:
                return "square.grid.3x3"
            case .activityEvent:
                return "list.bullet.rectangle"
            case .bookCover:
                return "books.vertical"
            }
        }
    }

    /// RootContentState 表示页面根状态（加载/空态/有内容）。
    enum RootContentState: Hashable {
        case loading
        case empty
        case content
    }

    /// MonthLoadState 表示单月分页的加载状态。
    enum MonthLoadState: Hashable {
        case idle
        case loading
        case loaded
        case failed
    }

    /// YearLoadState 表示年度聚合视图的加载状态。
    enum YearLoadState: Hashable {
        case idle
        case loading
        case loaded
        case failed
    }

    /// SummaryFilterState 表示统计 Sheet 需要明示的三类日历隐藏设置。
    struct SummaryFilterState: Hashable {
        let excludeReadTime: Bool
        let excludeNote: Bool
        let excludeReadDone: Bool

        static let none = SummaryFilterState(
            excludeReadTime: false,
            excludeNote: false,
            excludeReadDone: false
        )
    }

    /// SheetDestination 统一管理总结与年月选择器，避免同一宿主上的多个 Sheet 竞争展示。
    private enum SheetDestination: String, Identifiable {
        case monthSummary
        case yearSummary
        case yearMonthPicker
        case yearPicker

        var id: String { rawValue }
    }

    /// MonthPage 封装单月渲染快照，聚合周网格、日数据、排行与摘要。
    struct MonthPage: Identifiable, Hashable {
        let monthStart: Date
        let weeks: [ReadCalendarMonthGrid.WeekData]
        let dayMap: [Date: ReadCalendarDay]
        let readingDurationTopBooks: [ReadCalendarMonthlyDurationBook]
        let summary: ReadCalendarMonthSummary
        let rankingBarColorsByBookId: [Int64: ReadCalendarSegmentColor]
        let selectedDate: Date?
        let todayStart: Date
        let laneLimit: Int
        let isLocked: Bool
        let isDayMapEmpty: Bool
        let loadState: MonthLoadState
        let errorMessage: String?

        var id: Date { monthStart }

        var isLoading: Bool {
            loadState == .loading
        }

        var isPlaceholder: Bool {
            loadState == .idle
                && errorMessage == nil
                && dayMap.isEmpty
                && readingDurationTopBooks.isEmpty
                && summary == .empty
        }

        /// 把当日业务数据映射为网格单元载荷（热度、读完标记与选中态）。
        func payload(for date: Date) -> ReadCalendarMonthGrid.DayPayload {
            let cal = Calendar.current
            let normalized = cal.startOfDay(for: date)
            let dayData = dayMap[normalized]
            let bookCount = dayData?.books.count ?? 0

            return ReadCalendarMonthGrid.DayPayload(
                bookCount: bookCount,
                isReadDoneDay: dayData?.isReadDoneDay == true,
                heatmapLevel: dayData?.heatmapLevel ?? .none,
                overflowCount: max(0, bookCount - laneLimit),
                isToday: cal.isDate(normalized, inSameDayAs: todayStart),
                isSelected: selectedDate.map { cal.isDate(normalized, inSameDayAs: $0) } ?? false,
                isFuture: normalized > todayStart
            )
        }
    }

    /// Props 汇总页面渲染所需输入，解耦 View 与 ViewModel 的状态边界。
    struct Props: Hashable {
        let monthTitle: String
        let yearTitle: String
        let availableMonths: [Date]
        let availableYears: [Int]
        let pagerSelection: Date
        let selectedYear: Int
        let displayMode: DisplayMode
        let laneLimit: Int
        let isHapticsEnabled: Bool
        let summaryFilterState: SummaryFilterState
        let doneMarkerStyle: ReadCalendarDoneMarkerStyle
        let doneEmojiAssetName: String
        let rootContentState: RootContentState
        let errorMessage: String?
        let heatmapYearMonthPages: [MonthPage]
        let selectedYearLoadState: YearLoadState
        let selectedYearErrorMessage: String?
        let yearSummary: YearSummarySheetData
    }

    /// MonthSummarySheetData 定义月总结弹层的数据载荷。
    struct MonthSummarySheetData: Identifiable, Hashable {
        let monthStart: Date
        let monthSummary: ReadCalendarMonthSummary
        let durationTopBooks: [ReadCalendarMonthlyDurationBook]
        let rankingBarColorsByBookId: [Int64: ReadCalendarSegmentColor]
        let hasDurationRankingFallback: Bool
        let loadState: MonthLoadState

        var id: Date { monthStart }

        var hasActivity: Bool {
            monthSummary.activeDays > 0
        }
    }

    /// YearSummaryMonthContribution 描述某月在年度里的活跃与时长贡献。
    struct YearSummaryMonthContribution: Identifiable, Hashable {
        let monthStart: Date
        let activeDays: Int
        let totalReadSeconds: Int

        var id: Date { monthStart }
    }

    /// YearSummarySheetData 定义年度总结弹层的数据载荷。
    struct YearSummarySheetData: Identifiable, Hashable {
        let year: Int
        let activeDays: Int
        let totalReadSeconds: Int
        let noteCount: Int
        let finishedBookCount: Int
        let activeDaysDelta: Int?
        let readSecondsDelta: Int?
        let noteCountDelta: Int?
        let topBooks: [ReadCalendarMonthlyDurationBook]
        // 年度 TOP 条颜色，按 bookId 透传给 Sheet，保持与月度总结一致的封面取色体验。
        let rankingBarColorsByBookId: [Int64: ReadCalendarSegmentColor]
        let monthContributions: [YearSummaryMonthContribution]
        let isLoading: Bool
        let errorMessage: String?

        var id: Int { year }
    }

    /// BookCoverFullscreenPayload 定义封面全屏浮层的数据快照。
    struct BookCoverFullscreenPayload: Identifiable, Hashable {
        let date: Date
        let items: [ReadCalendarCoverFanStack.Item]
        let readDoneBookCount: Int
        let stackStyle: ReadCalendarCoverFanStack.Style
        let stackedVisibleCount: Int
        let stackedSeed: ReadCalendarCoverFanStack.LayoutSeed
        let transitionSession: ReadCalendarCoverTransitionSession

        var id: Date { date }
    }

    private enum Layout {
        static let topControlTopPadding: CGFloat = 10
        static let topControlBottomPadding: CGFloat = 14
        static let topControlBackgroundOpacity: CGFloat = 1
        static let topControlLayerZIndex: Double = 12
        static let contentLayerZIndex: Double = 0
        static let displayModeTransitionDuration: CGFloat = 0.24
        static let horizontalPagerProgrammaticDuration: CGFloat = 0.24
        static let weekdayHeaderHeight: CGFloat = 32
        static let pageMinHeight: CGFloat = 252
        static let calendarInnerTopPadding: CGFloat = Spacing.cozy
        static let calendarInnerBottomPadding: CGFloat = 0
        static let contentBleedBottomInset: CGFloat = 0
        static let interactiveBottomInset: CGFloat = 0
        static let headerToGridSpacing: CGFloat = Spacing.half
        static let gridTopInset: CGFloat = 2
        static let summarySheetCompactRatio: CGFloat = 0.48
        static let summaryFloatingButtonTrailing: CGFloat = Spacing.screenEdge
        static let summaryFloatingButtonBottomBase: CGFloat = Spacing.base
        static let summaryFloatingButtonShowResponse: CGFloat = 0.34
        static let summaryFloatingButtonShowDamping: CGFloat = 0.82
        static let summaryFloatingButtonHideDuration: CGFloat = 0.18
        static let summaryFloatingButtonShowScaleFrom: CGFloat = 0.92
        static let summaryFloatingButtonHideScaleTo: CGFloat = 0.96
        static let summaryFloatingButtonShowOffsetY: CGFloat = 10
        static let summaryFloatingButtonHideOffsetY: CGFloat = 6
        static let summaryFloatingButtonIdleHideDelay: TimeInterval = 7
        static let summaryFloatingButtonInitialVisibleProtection: TimeInterval = 5
        static let summaryFloatingButtonPostDismissProtection: TimeInterval = 3
        static let summaryFloatingButtonPostInteractionProtection: TimeInterval = 1.5
        static let summaryFloatingButtonScrollInteractionProtection: TimeInterval = 2
        static let summaryFloatingButtonInteractionThrottle: TimeInterval = 0.25
        static let yearHeatmapGridSpacing: CGFloat = Spacing.base
        static let yearHeatmapMonthCardSpacing: CGFloat = Spacing.half
        static let yearHeatmapMonthCardPadding: CGFloat = Spacing.contentEdge
        static let yearHeatmapMonthCardTitleHeight: CGFloat = 20
        static let yearHeatmapCompactWeekCount = 6
        static let yearHeatmapLoadingCellSpacing: CGFloat = 3
        static let yearHeatmapMonthCardCornerRadius: CGFloat = CornerRadius.containerMedium
        static let yearHeatmapErrorBannerHorizontalInset: CGFloat = Spacing.screenEdge
        static let yearHeatmapErrorBannerBottomInset: CGFloat = Spacing.base
        static let yearSummarySheetCompactRatio: CGFloat = 0.54
        static let bookCoverFullscreenOverlayZIndex: Double = 40
        static let coverEntryCuePeakDuration: CGFloat = 0.16
        static let coverEntryCueFadeDuration: CGFloat = 0.22
        static let coverEntryCueHoldNanoseconds: UInt64 = 220_000_000
        static let coverEntryCueCleanupNanoseconds: UInt64 = 280_000_000
        static let bookCoverGridCoordinateSpaceName = "read-calendar-book-cover-grid-space"
        static let coverComponentVisibleLimit = 5
        static let coverBusinessCollapsedLimit = 5
    }

    /// 阅读日历自身的结构动效语义；仅服务本组件，不上升为全局 Motion token。
    private enum Motion {
        static let errorState = Animation.spring(response: 0.38, dampingFraction: 0.86)
        static let summarySelection = Animation.snappy(duration: 0.3)
        static let summaryMonthSync = Animation.snappy(duration: 0.24)
        static let summaryFloatingButtonShow = Animation.spring(
            response: Layout.summaryFloatingButtonShowResponse,
            dampingFraction: Layout.summaryFloatingButtonShowDamping
        )
        static let summaryFloatingButtonHide = Animation.easeOut(
            duration: Layout.summaryFloatingButtonHideDuration
        )
        static let heatmapYearLayout = Animation.snappy(duration: 0.24)
        static let pageLoading = Animation.smooth(duration: 0.24)
        static let reducedPageLoading = Animation.easeOut(duration: 0.12)
        static let dateSelection = Animation.smooth(duration: 0.22)
        static let summaryPresentation = Animation.snappy(duration: 0.28)
    }

    let props: Props
    let monthPageProvider: (Date) -> MonthPage
    let onDisplayModeChanged: (DisplayMode) -> Void
    let onPagerSelectionChanged: (Date) -> Void
    let onYearSelectionChanged: (Int) -> Void
    let onSelectDate: (Date?) -> Void
    let onOpenDay: (Date) -> Void
    let onLockedMonthSelected: (Date) -> Void
    let onRetry: () -> Void
    let onBookCoverFullscreenPresentationChanged: (Bool) -> Void
    @State private var activeSheetDestination: SheetDestination?
    @State private var lastPresentedSheetDestination: SheetDestination?
    @State private var summarySheetMonthStart: Date?
    @State private var pendingYearMonthPickerSelection: Date?
    @State private var pendingYearPickerSelection: Int?

    // MARK: - Summary Floating Button State
    @State private var isSummaryFloatingButtonVisible = false
    @State private var summaryFloatingButtonAutoHideTask: Task<Void, Never>?
    @State private var summaryFloatingButtonInteractionToken: UInt64 = 0
    @State private var summaryFloatingButtonHideNotBefore: Date = .distantPast
    @State private var summaryFloatingButtonLastInteractionAt: Date = .distantPast
    @State private var hasAppliedSummaryFloatingButtonInitialPolicy = false
    @State private var summaryFloatingButtonHiddenScale: CGFloat = Layout.summaryFloatingButtonShowScaleFrom
    @State private var summaryFloatingButtonHiddenOffsetY: CGFloat = Layout.summaryFloatingButtonShowOffsetY
    @State private var bookCoverFullscreenPayload: BookCoverFullscreenPayload?
    @State private var bookCoverStackFramesByDate: [Date: CGRect] = [:]
    @State private var coverEntryCueDate: Date?
    @State private var coverEntryCueProgress: CGFloat = 0
    @State private var coverEntryCueTask: Task<Void, Never>?
    @State private var topControlBarFrameInGlobal: CGRect = .zero
    @State private var lastLoggedTopControlBarFrameForDebug: CGRect = .zero
    @State private var lastLoggedCalendarViewportSignatureForDebug = ""
    @State private var rootLoadingGate = LoadingGate()
    @State private var heatmapYearLoadingGate = LoadingGate()

    var body: some View {
        bodyContainer
    }
}

/// ReadCalendarTopControlBarFramePreferenceKey 回传顶部控制栏在全局坐标系中的 frame。
private struct ReadCalendarTopControlBarFramePreferenceKey: PreferenceKey {
    static var defaultValue: CGRect = .zero

    /// 合并顶部控制栏最新 frame，忽略零值占位，保证后续沉浸偏移动画基于真实位置。
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        guard next != .zero else { return }
        value = next
    }
}

// MARK: - Subviews

private extension ReadCalendarContentView {
    var isBookCoverFullscreenPresented: Bool {
        bookCoverFullscreenPayload != nil
    }

    var bodyContainer: some View {
        baseCalendarStack
            .safeAreaBar(edge: .bottom, spacing: Spacing.none) {
                if let selectedActivityDaySummary {
                    ReadCalendarSelectedDaySummaryBar(
                        summary: selectedActivityDaySummary,
                        onOpenDetail: {
                            onOpenDay(selectedActivityDaySummary.date)
                        }
                    )
                    .padding(.horizontal, Spacing.screenEdge)
                    .padding(.vertical, Spacing.half)
                    .transition(selectedDaySummaryTransition)
                }
            }
            .animation(selectedDaySummaryAnimation, value: selectedActivityDaySummary)
            .animation(accessibilityReduceMotion ? nil : Motion.errorState, value: props.errorMessage)
            .onAppear {
                onBookCoverFullscreenPresentationChanged(isBookCoverFullscreenPresented)
                syncRootLoadingVisibility()
                syncHeatmapYearLoadingVisibility()
                if props.rootContentState == .content {
                    applySummaryFloatingButtonInitialPolicyIfNeeded()
                }
            }
            .onChange(of: isBookCoverFullscreenPresented) { _, isPresented in
                onBookCoverFullscreenPresentationChanged(isPresented)
            }
            .onChange(of: props.rootContentState) { _, state in
                syncRootLoadingVisibility()
                switch state {
                case .content:
                    applySummaryFloatingButtonInitialPolicyIfNeeded()
                case .loading, .empty:
                    hideSummaryFloatingButtonImmediately()
                    closeBookCoverFullscreen(animated: false)
                }
            }
            .onChange(of: props.pagerSelection) { _, monthStart in
                syncSummarySheetMonthIfNeeded(monthStart: monthStart)
                markSummaryFloatingButtonInteraction(
                    protectedFor: Layout.summaryFloatingButtonScrollInteractionProtection
                )
                bookCoverStackFramesByDate = [:]
                closeBookCoverFullscreen(animated: false)
            }
            .onChange(of: activeSelectedDate) { _, _ in
                markSummaryFloatingButtonInteraction()
            }
            .onChange(of: props.displayMode) { _, mode in
                markSummaryFloatingButtonInteraction()
                if mode != .heatmap, activeSheetDestination == .yearSummary {
                    activeSheetDestination = nil
                }
                if mode != .bookCover {
                    bookCoverStackFramesByDate = [:]
                    closeBookCoverFullscreen()
                }
            }
            .onChange(of: props.selectedYear) { _, _ in
                guard props.displayMode == .heatmap else { return }
                syncHeatmapYearLoadingVisibility()
                markSummaryFloatingButtonInteraction(
                    protectedFor: Layout.summaryFloatingButtonScrollInteractionProtection
                )
            }
            .onChange(of: props.selectedYearLoadState) { _, _ in
                syncHeatmapYearLoadingVisibility()
            }
            .onDisappear {
                summaryFloatingButtonAutoHideTask?.cancel()
                summaryFloatingButtonAutoHideTask = nil
                rootLoadingGate.hideImmediately()
                heatmapYearLoadingGate.hideImmediately()
                bookCoverStackFramesByDate = [:]
                closeBookCoverFullscreen(animated: false)
                pendingYearMonthPickerSelection = nil
                pendingYearPickerSelection = nil
                cancelCoverEntryCue()
                onBookCoverFullscreenPresentationChanged(false)
            }
            .onPreferenceChange(ReadCalendarTopControlBarFramePreferenceKey.self) { frame in
                topControlBarFrameInGlobal = frame
                logTopControlBarFrameIfNeeded(frame)
            }
            .overlay {
                bookCoverFullscreenOverlay
            }
            .sheet(item: $activeSheetDestination, onDismiss: handleSheetDismiss) { destination in
                sheetContent(destination)
                    .onAppear {
                        lastPresentedSheetDestination = destination
                    }
            }
    }

    /// 在调试模式下输出顶部控制栏 frame，辅助排查沉浸滚动与全屏浮层的锚点问题。
    func logTopControlBarFrameIfNeeded(_ frame: CGRect) {
#if DEBUG
        let normalized = CGRect(
            x: frame.origin.x.rounded(),
            y: frame.origin.y.rounded(),
            width: frame.size.width.rounded(),
            height: frame.size.height.rounded()
        )
        guard normalized != lastLoggedTopControlBarFrameForDebug else { return }
        lastLoggedTopControlBarFrameForDebug = normalized
        print(
            "[ReadCalendar][TopControlBarFrame] x=\(Int(normalized.minX)) y=\(Int(normalized.minY)) w=\(Int(normalized.width)) h=\(Int(normalized.height)) maxY=\(Int(normalized.maxY))"
        )
#endif
    }

    /// 在调试模式下输出日历视口高度和安全区，辅助间距审计与布局压缩排查。
    func logCalendarViewportIfNeeded(contentHeight: CGFloat, viewportSafeBottom: CGFloat) {
#if DEBUG
        let signature = "contentH=\(Int(contentHeight.rounded())) safeBottom=\(Int(viewportSafeBottom.rounded()))"
        guard signature != lastLoggedCalendarViewportSignatureForDebug else { return }
        lastLoggedCalendarViewportSignatureForDebug = signature
        print("[ReadCalendar][CalendarViewport] \(signature)")
#endif
    }
    
    var baseCalendarStack: some View {
        VStack(spacing: Spacing.none) {
            ReadCalendarTopControlBar(
                monthTitle: props.monthTitle,
                yearTitle: props.yearTitle,
                pagerSelection: props.pagerSelection,
                selectedYear: props.selectedYear,
                displayMode: props.displayMode,
                onDisplayModeChanged: onDisplayModeChanged,
                onMonthPickerRequested: {
                    pendingYearMonthPickerSelection = nil
                    activeSheetDestination = .yearMonthPicker
                },
                onYearPickerRequested: {
                    pendingYearPickerSelection = nil
                    activeSheetDestination = .yearPicker
                }
            )
            .padding(.top, Layout.topControlTopPadding)
            .padding(.bottom, Layout.topControlBottomPadding)
            .background {
                Color.surfacePage.opacity(Layout.topControlBackgroundOpacity)
            }
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .preference(
                            key: ReadCalendarTopControlBarFramePreferenceKey.self,
                            value: proxy.frame(in: .global)
                        )
                }
            }
            // 保证底部沉浸滚动时，顶部控制区始终位于最上层。
            .zIndex(Layout.topControlLayerZIndex)

            integratedCalendarContainer
                .zIndex(Layout.contentLayerZIndex)

            if let errorMessage = props.errorMessage,
               props.rootContentState == .content {
                ReadCalendarInlineErrorBanner(message: errorMessage, onRetry: onRetry)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
    }

    @ViewBuilder
    var bookCoverFullscreenOverlay: some View {
        if let payload = bookCoverFullscreenPayload {
            ReadCalendarBookCoverFullscreenOverlay(
                payload: payload,
                isHapticsEnabled: props.isHapticsEnabled,
                doneMarkerStyle: props.doneMarkerStyle,
                doneEmojiAssetName: props.doneEmojiAssetName,
                topControlBarFrameInGlobal: topControlBarFrameInGlobal,
                onClose: { closeBookCoverFullscreen() },
                onOpenDaily: {
                    closeBookCoverFullscreen(animated: false)
                    onOpenDay(payload.date)
                }
            )
            .zIndex(Layout.bookCoverFullscreenOverlayZIndex)
            .transition(.opacity)
        }
    }

    var monthSummarySheetContent: some View {
        ReadCalendarMonthSummarySheet(
            sheet: presentedSummarySheetData,
            availableMonths: props.availableMonths,
            filterState: props.summaryFilterState,
            onSwitchMonth: { monthStart in
                switchSummarySheetMonth(to: monthStart)
            }
        )
        .presentationDetents([.fraction(Layout.summarySheetCompactRatio), .large])
        .presentationDragIndicator(.visible)
        // 宿主层使用中等强度系统材质，保证玻璃效果可感知且半/全展开一致。
        .presentationBackground(.regularMaterial)
    }

    var yearSummarySheetContent: some View {
        ReadCalendarYearSummarySheet(
            sheet: props.yearSummary,
            availableYears: props.availableYears,
            filterState: props.summaryFilterState,
            onSwitchYear: { year in
                performMotion(Motion.summarySelection) {
                    onYearSelectionChanged(year)
                }
            },
            onSelectMonth: { monthStart in
                performMotion(Motion.summarySelection) {
                    onPagerSelectionChanged(monthStart)
                }
                openMonthSummaryAfterAuxSheetDismiss(monthStart: monthStart)
            },
            onRetry: onRetry
        )
        .presentationDetents([.fraction(Layout.yearSummarySheetCompactRatio), .large])
        .presentationDragIndicator(.visible)
        // 宿主层使用中等强度系统材质，保证玻璃效果可感知且半/全展开一致。
        .presentationBackground(.regularMaterial)
    }

    var yearMonthPickerSheetContent: some View {
        XMYearMonthPickerSheet(
            availableMonths: props.availableMonths,
            selectedMonth: props.pagerSelection,
            currentMonth: Self.monthStart(of: Date(), using: Calendar.current),
            calendar: Calendar.current,
            onSelectMonth: { monthStart in
                pendingYearMonthPickerSelection = Self.monthStart(of: monthStart, using: Calendar.current)
            },
            onCancel: {
                pendingYearMonthPickerSelection = nil
            }
        )
        .presentationDetents([.height(XMYearMonthPickerSheet.preferredPresentationHeight(for: dynamicTypeSize, mode: .yearMonth))])
        .presentationDragIndicator(.hidden)
        .presentationBackground(.regularMaterial)
    }

    var yearPickerSheetContent: some View {
        XMYearMonthPickerSheet(
            availableYears: props.availableYears,
            selectedYear: props.selectedYear,
            currentYear: Calendar.current.component(.year, from: Date()),
            calendar: Calendar.current,
            onSelectYear: { year in
                pendingYearPickerSelection = year
            },
            onCancel: {
                pendingYearPickerSelection = nil
            }
        )
        .presentationDetents([.height(XMYearMonthPickerSheet.preferredPresentationHeight(for: dynamicTypeSize, mode: .year))])
        .presentationDragIndicator(.hidden)
        .presentationBackground(.regularMaterial)
    }

    @ViewBuilder
    private func sheetContent(_ destination: SheetDestination) -> some View {
        switch destination {
        case .monthSummary:
            monthSummarySheetContent
        case .yearSummary:
            yearSummarySheetContent
        case .yearMonthPicker:
            yearMonthPickerSheetContent
        case .yearPicker:
            yearPickerSheetContent
        }
    }

    /// 按实际关闭的 Sheet 执行提交或现场恢复，避免选择器与总结弹层互相清理状态。
    func handleSheetDismiss() {
        let dismissedDestination = lastPresentedSheetDestination
        lastPresentedSheetDestination = nil
        switch dismissedDestination {
        case .monthSummary:
            summarySheetMonthStart = nil
            markSummaryFloatingButtonInteraction(
                protectedFor: Layout.summaryFloatingButtonPostDismissProtection,
                force: true
            )
        case .yearSummary:
            markSummaryFloatingButtonInteraction(
                protectedFor: Layout.summaryFloatingButtonPostDismissProtection,
                force: true
            )
        case .yearMonthPicker:
            commitPendingYearMonthPickerSelection()
        case .yearPicker:
            commitPendingYearPickerSelection()
        case nil:
            break
        }
    }

    var isHeatmapMode: Bool {
        props.displayMode == .heatmap
    }

    var isSummarySheetPresented: Bool {
        activeSheetDestination == .monthSummary
    }

    var isYearSummarySheetPresented: Bool {
        activeSheetDestination == .yearSummary
    }

    var shouldMountSummaryFloatingButton: Bool {
        props.rootContentState == .content
            && !isSummarySheetPresented
            && !isYearSummarySheetPresented
            && !isBookCoverFullscreenPresented
            && selectedActivityDaySummary == nil
    }

    var shouldShowSummaryFloatingButton: Bool {
        shouldMountSummaryFloatingButton
    }

    var activeMonthPage: MonthPage? {
        monthPageStateIfLoaded(for: props.pagerSelection)
    }

    var activeSelectedDate: Date? {
        activeMonthPage?.selectedDate
    }

    /// 仅为事件模式当前月份的有效选中日构建摘要，避免切月或切模式后残留错误信息。
    var selectedActivityDaySummary: ReadCalendarSelectedDaySummary? {
        guard props.rootContentState == .content,
              props.displayMode == .activityEvent,
              let page = activeMonthPage,
              !page.isLocked,
              let selectedDate = page.selectedDate else {
            return nil
        }

        let calendar = Calendar.current
        let normalizedDate = calendar.startOfDay(for: selectedDate)
        guard normalizedDate <= page.todayStart,
              calendar.isDate(normalizedDate, equalTo: page.monthStart, toGranularity: .month) else {
            return nil
        }
        return ReadCalendarSelectedDaySummary.make(
            date: normalizedDate,
            day: page.dayMap[normalizedDate]
        )
    }

    var selectedDaySummaryTransition: AnyTransition {
        accessibilityReduceMotion
            ? .opacity
            : .move(edge: .bottom).combined(with: .opacity)
    }

    var selectedDaySummaryAnimation: Animation? {
        accessibilityReduceMotion
            ? .easeOut(duration: 0.16)
            : .snappy(duration: 0.26)
    }

    var heatmapYearMonthPages: [MonthPage] {
        // 源数据由 monthStartsForYear 按自然月序构建，无需额外排序
        props.heatmapYearMonthPages
    }

    var isCurrentYearHeatmapLoading: Bool {
        let hasLoadedMonth = heatmapYearMonthPages.contains { $0.loadState == .loaded }
        return props.selectedYearLoadState == .loading && !hasLoadedMonth
    }

    var summaryFloatingButtonIconName: String {
        "chart.bar.xaxis"
    }

    var summaryFloatingButtonAccessibilityLabel: String {
        isHeatmapMode ? "打开年度阅读总结" : "打开月度阅读总结"
    }

    var presentedSummarySheetData: MonthSummarySheetData {
        let monthStart = summarySheetMonthStart ?? props.pagerSelection
        return summarySheetData(for: monthStart)
    }

    /// Sheet 完全关闭后再同步分页选择，避免年月选择层与主日历分页动画叠加。
    func commitPendingYearMonthPickerSelection() {
        guard let monthStart = pendingYearMonthPickerSelection else { return }
        pendingYearMonthPickerSelection = nil
        let normalizedMonth = Self.monthStart(of: monthStart, using: Calendar.current)
        guard normalizedMonth != props.pagerSelection else { return }
        performMotion(Motion.summarySelection) {
            onPagerSelectionChanged(normalizedMonth)
        }
    }

    /// Sheet 完全关闭后再同步年份选择，避免年份选择层与年度热力图切换叠加。
    func commitPendingYearPickerSelection() {
        guard let year = pendingYearPickerSelection else { return }
        pendingYearPickerSelection = nil
        guard year != props.selectedYear else { return }
        performMotion(Motion.summarySelection) {
            onYearSelectionChanged(year)
        }
    }

    /// 将日期归一到月份首日，作为阅读日历分页选择的稳定 key。
    static func monthStart(of date: Date, using calendar: Calendar) -> Date {
        let normalized = calendar.startOfDay(for: date)
        let components = calendar.dateComponents([.year, .month], from: normalized)
        let start = calendar.date(from: DateComponents(year: components.year, month: components.month, day: 1)) ?? normalized
        return calendar.startOfDay(for: start)
    }

    /// 读取已加载月份页面状态，避免未命中时误用占位数据。
    func monthPageStateIfLoaded(for monthStart: Date) -> MonthPage? {
        let page = monthPageProvider(monthStart)
        return page.isPlaceholder ? nil : page
    }

    /// 为单月预构建日期 -> 封面条目映射，避免日格渲染期间重复排序与对象创建。
    func buildCoverItemsByDate(for page: MonthPage) -> [Date: [ReadCalendarCoverFanStack.Item]] {
        var result: [Date: [ReadCalendarCoverFanStack.Item]] = [:]
        result.reserveCapacity(page.dayMap.count)
        for (date, dayData) in page.dayMap where !dayData.books.isEmpty {
            // 与 Android 同源：仓储已按 lastEventTime 降序、firstEventTime 降序、bookId 升序稳定排列。
            result[date] = dayData.books.prefix(120).enumerated().map { index, book in
                ReadCalendarCoverFanStack.Item(
                    id: "\(book.id)_\(book.firstEventTime)_\(index)",
                    coverURL: book.coverURL
                )
            }
        }
        return result
    }

    /// 读取指定日期的封面条目，统一做 startOfDay 归一化避免 key 漂移。
    func coverItems(for date: Date, in coverItemsByDate: [Date: [ReadCalendarCoverFanStack.Item]]) -> [ReadCalendarCoverFanStack.Item] {
        let normalized = Calendar.current.startOfDay(for: date)
        return coverItemsByDate[normalized] ?? []
    }

    /// 返回书籍封面模式样式：与封面堆叠测试页保持一致的参数基线。
    func bookCoverStyle(for _: Int) -> ReadCalendarCoverFanStack.Style {
        return ReadCalendarCoverFanStack.Style(
            secondaryRotation: -8,
            tertiaryRotation: -15,
            secondaryOffsetXRatio: -0.34,
            tertiaryOffsetXRatio: -0.66,
            secondaryOffsetYRatio: -0.03,
            tertiaryOffsetYRatio: 0.14,
            shadowOpacity: 0.28,
            shadowRadius: 7,
            shadowX: 0.5,
            shadowY: 5,
            collapsedVisibleCount: Layout.coverBusinessCollapsedLimit,
            jitterDegree: 1.8,
            jitterOffsetRatio: 0.05,
            fullscreenMaxRotation: 14
        )
    }

    /// 打开书籍封面全屏浮层。
    func openBookCoverFullscreen(
        for date: Date,
        coverItemsByDate: [Date: [ReadCalendarCoverFanStack.Item]],
        readDoneBookCount: Int
    ) {
        let items = coverItems(for: date, in: coverItemsByDate)
        guard !items.isEmpty else { return }
        let normalized = Calendar.current.startOfDay(for: date)
        triggerCoverEntryCue(for: normalized)
        let style = bookCoverStyle(for: items.count)
        let sourceFrame = bookCoverStackFramesByDate[normalized]
        let stackedVisibleCount = min(
            max(1, items.count),
            max(1, min(style.collapsedVisibleCount, 14))
        )
        let payload = BookCoverFullscreenPayload(
            date: normalized,
            items: items,
            readDoneBookCount: max(0, readDoneBookCount),
            stackStyle: style,
            stackedVisibleCount: stackedVisibleCount,
            stackedSeed: ReadCalendarCoverFanStack.makeLayoutSeed(
                date: normalized,
                items: Array(items.prefix(14)),
                mode: .collapsed
            ),
            transitionSession: ReadCalendarCoverTransitionSession(
                sourceStackFrame: sourceFrame,
                sourceCoverSize: ReadCalendarMonthGrid.sourceCoverSize
            )
        )
        bookCoverFullscreenPayload = payload
    }

    /// 关闭书籍封面全屏浮层。
    func closeBookCoverFullscreen(animated: Bool = true) {
        guard bookCoverFullscreenPayload != nil else { return }
        if animated {
            withAnimation(.easeOut(duration: 0.16)) {
                bookCoverFullscreenPayload = nil
            }
        } else {
            bookCoverFullscreenPayload = nil
        }
        cancelCoverEntryCue()
    }

    /// 触发日格源位聚焦提示，给用户保留“我从哪一天进入” 的空间锚点。
    func triggerCoverEntryCue(for date: Date) {
        coverEntryCueTask?.cancel()
        coverEntryCueDate = date
        coverEntryCueProgress = 0
        withAnimation(.easeOut(duration: Layout.coverEntryCuePeakDuration)) {
            coverEntryCueProgress = 1
        }
        coverEntryCueTask = Task {
            do {
                try await Task.sleep(nanoseconds: Layout.coverEntryCueHoldNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                withAnimation(.easeOut(duration: Layout.coverEntryCueFadeDuration)) {
                    coverEntryCueProgress = 0
                }
            }
            do {
                try await Task.sleep(nanoseconds: Layout.coverEntryCueCleanupNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                coverEntryCueDate = nil
            }
        }
    }

    /// 清理源位提示状态，避免切月/切模式后遗留高亮。
    func cancelCoverEntryCue() {
        coverEntryCueTask?.cancel()
        coverEntryCueTask = nil
        coverEntryCueDate = nil
        coverEntryCueProgress = 0
    }

    /// 根据当前模式切换总结弹层与悬浮按钮状态，保持交互路径一致。
    func openSummaryManually() {
        if isHeatmapMode {
            openYearSummaryManually()
            return
        }
        openMonthSummaryManually()
    }

    /// 根据当前模式切换总结弹层与悬浮按钮状态，保持交互路径一致。
    func openMonthSummaryManually() {
        let normalizedMonthStart = Calendar.current.startOfDay(for: props.pagerSelection)
        summarySheetMonthStart = normalizedMonthStart
        isSummaryFloatingButtonVisible = false
        activeSheetDestination = .monthSummary
        summaryFloatingButtonAutoHideTask?.cancel()
        summaryFloatingButtonAutoHideTask = nil
    }

    /// 根据当前模式切换总结弹层与悬浮按钮状态，保持交互路径一致。
    func openYearSummaryManually() {
        isSummaryFloatingButtonVisible = false
        activeSheetDestination = .yearSummary
        summaryFloatingButtonAutoHideTask?.cancel()
        summaryFloatingButtonAutoHideTask = nil
    }

    /// 更新总结悬浮按钮的可见性策略与交互保护窗口。
    func applySummaryFloatingButtonInitialPolicyIfNeeded() {
        if !hasAppliedSummaryFloatingButtonInitialPolicy {
            hasAppliedSummaryFloatingButtonInitialPolicy = true
            markSummaryFloatingButtonInteraction(
                protectedFor: Layout.summaryFloatingButtonInitialVisibleProtection,
                force: true
            )
            return
        }
        markSummaryFloatingButtonInteraction(force: true)
    }

    /// 根据当前模式切换总结弹层与悬浮按钮状态，保持交互路径一致。
    func hideSummaryFloatingButtonImmediately() {
        summaryFloatingButtonAutoHideTask?.cancel()
        summaryFloatingButtonAutoHideTask = nil
        guard isSummaryFloatingButtonVisible else { return }
        summaryFloatingButtonHiddenScale = Layout.summaryFloatingButtonHideScaleTo
        summaryFloatingButtonHiddenOffsetY = Layout.summaryFloatingButtonHideOffsetY
        withAnimation(.easeOut(duration: Layout.summaryFloatingButtonHideDuration)) {
            isSummaryFloatingButtonVisible = false
        }
    }

    /// 更新总结悬浮按钮的可见性策略与交互保护窗口。
    func markSummaryFloatingButtonInteraction(
        protectedFor: TimeInterval = Layout.summaryFloatingButtonPostInteractionProtection,
        force: Bool = false
    ) {
        guard props.rootContentState == .content,
              !isSummarySheetPresented,
              !isYearSummarySheetPresented else {
            return
        }

        let now = Date()
        if !force,
           isSummaryFloatingButtonVisible,
           now.timeIntervalSince(summaryFloatingButtonLastInteractionAt) < Layout.summaryFloatingButtonInteractionThrottle {
            return
        }

        summaryFloatingButtonLastInteractionAt = now
        summaryFloatingButtonHideNotBefore = now.addingTimeInterval(protectedFor)
        summaryFloatingButtonInteractionToken &+= 1

        if !isSummaryFloatingButtonVisible {
            summaryFloatingButtonHiddenScale = Layout.summaryFloatingButtonShowScaleFrom
            summaryFloatingButtonHiddenOffsetY = Layout.summaryFloatingButtonShowOffsetY
            performMotion(Motion.summaryFloatingButtonShow) {
                isSummaryFloatingButtonVisible = true
            }
        }

        scheduleSummaryFloatingButtonAutoHide(for: summaryFloatingButtonInteractionToken)
    }

    /// 安排悬浮总结按钮自动隐藏任务，避免按钮长期遮挡日历内容。
    func scheduleSummaryFloatingButtonAutoHide(for token: UInt64) {
        summaryFloatingButtonAutoHideTask?.cancel()
        let fireDate = max(
            summaryFloatingButtonHideNotBefore,
            Date().addingTimeInterval(Layout.summaryFloatingButtonIdleHideDelay)
        )
        let sleepSeconds = max(0, fireDate.timeIntervalSinceNow)

        summaryFloatingButtonAutoHideTask = Task {
            try? await Task.sleep(for: .seconds(sleepSeconds))
            guard !Task.isCancelled else { return }

            await MainActor.run {
                guard token == summaryFloatingButtonInteractionToken else { return }
                guard props.rootContentState == .content,
                      !isSummarySheetPresented,
                      !isYearSummarySheetPresented,
                      isSummaryFloatingButtonVisible else {
                    return
                }

                summaryFloatingButtonHiddenScale = Layout.summaryFloatingButtonHideScaleTo
                summaryFloatingButtonHiddenOffsetY = Layout.summaryFloatingButtonHideOffsetY
                performMotion(Motion.summaryFloatingButtonHide) {
                    isSummaryFloatingButtonVisible = false
                }
            }
        }
    }

    /// 当月份切换后同步摘要弹层目标月份，避免弹层内容与主分页错位。
    func syncSummarySheetMonthIfNeeded(monthStart: Date) {
        guard isSummarySheetPresented else { return }
        let normalizedMonthStart = Calendar.current.startOfDay(for: monthStart)
        guard summarySheetMonthStart != normalizedMonthStart else { return }
        performMotion(Motion.summaryMonthSync) {
            summarySheetMonthStart = normalizedMonthStart
        }
    }

    /// 更新总结悬浮按钮的可见性策略与交互保护窗口。
    func switchSummarySheetMonth(to monthStart: Date) {
        let normalizedMonthStart = Calendar.current.startOfDay(for: monthStart)
        guard normalizedMonthStart != props.pagerSelection else { return }
        performMotion(Motion.summarySelection) {
            onPagerSelectionChanged(normalizedMonthStart)
            summarySheetMonthStart = normalizedMonthStart
        }
    }

    /// 按指定月份生成摘要弹层需要的完整数据快照。
    func summarySheetData(for monthStart: Date) -> MonthSummarySheetData {
        let normalizedMonthStart = Calendar.current.startOfDay(for: monthStart)
        let page = monthPageProvider(normalizedMonthStart)
        return buildMonthSummary(from: page)
    }

    /// 以 Repository 月快照为唯一指标来源，并按当前/历史月份规则补齐同期环比。
    func buildMonthSummary(from page: MonthPage) -> MonthSummarySheetData {
        let calendar = Calendar.current
        let monthStart = Self.monthStart(of: page.monthStart, using: calendar)
        let previousSnapshot = previousMonthComparisonSnapshot(for: monthStart)
        let summary = page.loadState == .loaded
            ? page.summary.applyingComparison(previousSnapshot)
            : page.summary.applyingComparison(nil)
        let hasDurationRankingFallback = page.readingDurationTopBooks.contains { book in
            page.rankingBarColorsByBookId[book.bookId]?.state == .failed
        }

        return MonthSummarySheetData(
            monthStart: monthStart,
            monthSummary: summary,
            durationTopBooks: page.readingDurationTopBooks,
            rankingBarColorsByBookId: page.rankingBarColorsByBookId,
            hasDurationRankingFallback: hasDurationRankingFallback,
            loadState: page.loadState
        )
    }

    /// 读取完整上月或上月同期快照；未加载、失败或无有效行为时不生成伪造环比。
    func previousMonthComparisonSnapshot(for monthStart: Date) -> ReadCalendarSummaryComparisonSnapshot? {
        let calendar = Calendar.current
        guard let previousMonth = calendar.date(byAdding: .month, value: -1, to: monthStart) else {
            return nil
        }
        let normalizedPreviousMonth = Self.monthStart(of: previousMonth, using: calendar)
        let previousPage = monthPageProvider(normalizedPreviousMonth)
        guard previousPage.loadState == .loaded, !previousPage.isLocked else {
            return nil
        }
        let cutoff = ReadCalendarSummaryComparison.previousMonthCutoff(
            selectedMonthStart: monthStart,
            calendar: calendar
        )
        let snapshot = ReadCalendarSummaryComparisonSnapshot.make(
            days: previousPage.dayMap,
            through: cutoff,
            calendar: calendar
        )
        return snapshot.hasActivity ? snapshot : nil
    }

    var integratedCalendarContainer: some View {
        GeometryReader { proxy in
            let headerHeight = shouldShowWeekdayHeader ? Layout.weekdayHeaderHeight : 0
            let spacing = shouldShowWeekdayHeader ? Layout.headerToGridSpacing : 0
            let viewportSafeBottom = max(0, proxy.safeAreaInsets.bottom)
            let contentHeight = max(0, proxy.size.height - headerHeight - spacing)

            VStack(spacing: spacing) {
                if shouldShowWeekdayHeader {
                    ReadCalendarWeekdayHeader(minHeight: Layout.weekdayHeaderHeight)
                        .frame(height: Layout.weekdayHeaderHeight)
                        .background(Color.surfacePage)
                        .zIndex(1)
                }

                contentContainer()
                    .frame(height: contentHeight, alignment: .top)
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
            .onAppear {
                logCalendarViewportIfNeeded(contentHeight: contentHeight, viewportSafeBottom: viewportSafeBottom)
            }
            .onChange(of: contentHeight) { _, _ in
                logCalendarViewportIfNeeded(contentHeight: contentHeight, viewportSafeBottom: viewportSafeBottom)
            }
            .onChange(of: viewportSafeBottom) { _, _ in
                logCalendarViewportIfNeeded(contentHeight: contentHeight, viewportSafeBottom: viewportSafeBottom)
            }
        }
        .padding(.top, Layout.calendarInnerTopPadding)
        .padding(.bottom, Layout.calendarInnerBottomPadding + interactiveBottomInset)
        .animation(displayModeTransitionAnimation, value: props.displayMode)
    }

    /// 根据根状态切换加载、空态和内容区，并承载悬浮总结按钮。
    func contentContainer() -> some View {
        ZStack(alignment: .top) {
            switch props.rootContentState {
            case .loading:
                Group {
                    if rootLoadingGate.isVisible {
                        LoadingStateView("正在加载阅读日历…")
                    } else {
                        Color.clear
                    }
                }
                .frame(maxWidth: .infinity, minHeight: Layout.pageMinHeight, alignment: .center)
                .transition(.opacity.combined(with: .scale(scale: 0.98)))
            case .empty:
                emptyState
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            case .content:
                activeContent
                    .transition(.opacity.combined(with: .scale(scale: 0.98)))
            }
        }
        .padding(.top, shouldShowWeekdayHeader ? Layout.gridTopInset : Spacing.none)
        .frame(maxWidth: .infinity, alignment: .top)
        .overlay {
            GeometryReader { proxy in
                if shouldMountSummaryFloatingButton {
                    ReadCalendarSummaryFloatingButton(
                        iconSystemName: summaryFloatingButtonIconName,
                        accessibilityLabel: summaryFloatingButtonAccessibilityLabel,
                        action: openSummaryManually
                    )
                    .padding(.trailing, Layout.summaryFloatingButtonTrailing)
                    .padding(.bottom, floatingButtonBottomPadding(safeAreaBottom: proxy.safeAreaInsets.bottom))
                    .opacity(shouldShowSummaryFloatingButton ? 1 : 0)
                    .scaleEffect(shouldShowSummaryFloatingButton ? 1 : summaryFloatingButtonHiddenScale)
                    .offset(y: shouldShowSummaryFloatingButton ? 0 : summaryFloatingButtonHiddenOffsetY)
                    .allowsHitTesting(shouldShowSummaryFloatingButton)
                    .accessibilityHidden(!shouldShowSummaryFloatingButton)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
        }
    }

    @ViewBuilder
    var activeContent: some View {
        if isHeatmapMode {
            heatmapYearContent
                .transition(.opacity)
        } else {
            calendarPager
                .transition(.opacity)
        }
    }

    var displayModeTransitionAnimation: Animation? {
        accessibilityReduceMotion ? nil : .smooth(duration: Layout.displayModeTransitionDuration)
    }

    var shouldShowWeekdayHeader: Bool {
        props.displayMode != .heatmap
    }

    var interactiveBottomInset: CGFloat {
        Layout.interactiveBottomInset
    }

    var immersiveScrollTailInset: CGFloat {
        Layout.contentBleedBottomInset
    }

    /// 结合安全区计算悬浮按钮底部留白，避免与系统手势区冲突。
    func floatingButtonBottomPadding(safeAreaBottom: CGFloat) -> CGFloat {
        let resolvedSafeAreaBottom = max(safeAreaBottom, Spacing.contentEdge)
        return Layout.summaryFloatingButtonBottomBase + resolvedSafeAreaBottom
    }

    var pagerSelection: Binding<Date?> {
        Binding(
            get: { props.pagerSelection },
            set: { newValue in
                guard let newValue else { return }
                let normalized = Calendar.current.startOfDay(for: newValue)
                guard normalized != props.pagerSelection else { return }
                onPagerSelectionChanged(normalized)
            }
        )
    }

    var calendarPager: some View {
        HorizontalPagingHost(
            ids: props.availableMonths,
            selection: pagerSelection,
            windowAnchorID: props.pagerSelection,
            windowing: .radius(3),
            programmaticScrollAnimation: .snappy(duration: Layout.horizontalPagerProgrammaticDuration)
        ) { monthStart in
            monthPage(for: monthStart)
        }
    }

    @ViewBuilder
    var heatmapYearContent: some View {
        if isCurrentYearHeatmapLoading {
            Group {
                if heatmapYearLoadingGate.isVisible {
                    LoadingStateView("正在整理年度热力图…")
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, minHeight: Layout.pageMinHeight, alignment: .center)
        } else {
            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: Layout.yearHeatmapGridSpacing) {
                    if let selectedYearErrorMessage = props.selectedYearErrorMessage,
                       props.selectedYearLoadState == .failed {
                        ReadCalendarInlineErrorBanner(
                            message: selectedYearErrorMessage,
                            onRetry: onRetry
                        )
                        .padding(.horizontal, Layout.yearHeatmapErrorBannerHorizontalInset)
                        .padding(.bottom, Layout.yearHeatmapErrorBannerBottomInset)
                    }

                    let columns = [
                        GridItem(.flexible(), spacing: Layout.yearHeatmapGridSpacing),
                        GridItem(.flexible(), spacing: Layout.yearHeatmapGridSpacing)
                    ]
                    LazyVGrid(columns: columns, spacing: Layout.yearHeatmapGridSpacing) {
                        ForEach(heatmapYearMonthPages) { page in
                            yearHeatmapMonthCard(for: page)
                        }
                    }
                    .padding(.horizontal, Spacing.screenEdge)
                }
                .padding(.bottom, immersiveScrollTailInset)
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .onScrollPhaseChange { _, phase in
                guard phase.isScrolling else { return }
                markSummaryFloatingButtonInteraction(
                    protectedFor: Layout.summaryFloatingButtonScrollInteractionProtection
                )
            }
            .scrollBounceBehavior(.always)
            .readCalendarBottomImmersiveStyle()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .animation(accessibilityReduceMotion ? nil : Motion.heatmapYearLayout, value: props.selectedYear)
        }
    }

    /// 渲染年度热力图中的单月卡片，并提供点击进入月总结的入口。
    func yearHeatmapMonthCard(for page: MonthPage) -> some View {
        let monthTitle = yearHeatmapMonthTitle(page.monthStart)
        let isFutureMonth = page.monthStart > Self.monthStart(of: page.todayStart, using: Calendar.current)
        return Button {
            if page.isLocked {
                onLockedMonthSelected(page.monthStart)
            } else if !isFutureMonth {
                openMonthSummaryFromYearCard(for: page.monthStart)
            }
        } label: {
            VStack(alignment: .leading, spacing: Layout.yearHeatmapMonthCardSpacing) {
                Text(monthTitle)
                    .font(ReadCalendarTextStyle.yearHeatmapMonthTitleFont)
                    .foregroundStyle(Color.textPrimary)
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .frame(height: Layout.yearHeatmapMonthCardTitleHeight, alignment: .topLeading)

                if page.isLoading && page.isDayMapEmpty {
                    yearHeatmapLoadingGrid
                } else {
                    ReadCalendarMonthGrid(
                        weeks: yearCompactWeeks(for: page),
                        laneLimit: props.laneLimit,
                        displayMode: .heatmapYearCompact,
                        selectedDate: nil,
                        isHapticsEnabled: false,
                        doneMarkerStyle: props.doneMarkerStyle,
                        doneEmojiAssetName: props.doneEmojiAssetName,
                        dayPayloadProvider: { date in
                            page.payload(for: date)
                        },
                        onSelectDay: { _ in }
                    )
                    .frame(maxWidth: .infinity, alignment: .top)
                }
            }
            .padding(Layout.yearHeatmapMonthCardPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .background(
                RoundedRectangle(
                    cornerRadius: Layout.yearHeatmapMonthCardCornerRadius,
                    style: .continuous
                )
                .fill(Color.surfaceNested)
            )
            .opacity(page.isLocked ? 0.56 : 1)
            .overlay {
                if page.isLocked {
                    Image(systemName: "lock.fill")
                        .font(AppTypography.callout)
                        .foregroundStyle(Color.textSecondary)
                        .accessibilityHidden(true)
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(isFutureMonth)
        .accessibilityLabel(page.isLocked ? "\(monthTitle)，会员可查看" : monthTitle)
    }

    /// 渲染单月分页内容（加载态、日历网格与滚动交互）。
    func monthPage(for monthStart: Date) -> some View {
        let pageState = monthPageProvider(monthStart)

        return ScrollView(.vertical, showsIndicators: false) {
            ZStack(alignment: .top) {
                if pageState.isLoading && pageState.isDayMapEmpty {
                    LoadingStateView()
                        .frame(maxWidth: .infinity, minHeight: Layout.pageMinHeight, alignment: .center)
                        .transition(.opacity)
                } else {
                    calendarWeeks(for: pageState, allowsDateSelection: true)
                        .frame(maxWidth: .infinity, alignment: .top)
                        .transition(
                            accessibilityReduceMotion
                                ? .opacity
                                : .opacity.combined(with: .scale(scale: 0.99))
                        )
                }
            }
            .padding(.bottom, immersiveScrollTailInset)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .scrollClipDisabled(false)
        .onScrollPhaseChange { _, phase in
            guard phase.isScrolling else { return }
            markSummaryFloatingButtonInteraction(
                protectedFor: Layout.summaryFloatingButtonScrollInteractionProtection
            )
        }
        .scrollBounceBehavior(.always)
        .readCalendarBottomImmersiveStyle()
        .animation(
            accessibilityReduceMotion ? Motion.reducedPageLoading : Motion.pageLoading,
            value: pageState.loadState
        )
    }

    private func syncRootLoadingVisibility() {
        let intent: LoadingIntent = props.rootContentState == .loading ? .read : .none
        rootLoadingGate.update(intent: intent)
    }

    private func syncHeatmapYearLoadingVisibility() {
        let intent: LoadingIntent = isCurrentYearHeatmapLoading ? .read : .none
        heatmapYearLoadingGate.update(intent: intent)
    }

    /// 渲染单月周网格，并处理日期选中/取消选中交互。
    func calendarWeeks(for page: MonthPage, allowsDateSelection: Bool) -> some View {
        let coverItemsByDate = props.displayMode == .bookCover
            ? buildCoverItemsByDate(for: page)
            : [:]
        return ReadCalendarMonthGrid(
            weeks: page.weeks,
            laneLimit: props.laneLimit,
            displayMode: allowsDateSelection ? mapGridDisplayMode(props.displayMode) : .heatmap,
            selectedDate: allowsDateSelection ? page.selectedDate : nil,
            isHapticsEnabled: allowsDateSelection ? props.isHapticsEnabled : false,
            doneMarkerStyle: props.doneMarkerStyle,
            doneEmojiAssetName: props.doneEmojiAssetName,
            dayPayloadProvider: { date in
                page.payload(for: date)
            },
            coverItemsProvider: { date in
                coverItems(for: date, in: coverItemsByDate)
            },
            bookCoverStyleProvider: { date in
                bookCoverStyle(for: coverItems(for: date, in: coverItemsByDate).count)
            },
            coverComponentVisibleLimit: Layout.coverComponentVisibleLimit,
            coverBusinessVisibleLimit: Layout.coverBusinessCollapsedLimit,
            coverEntryCueDate: coverEntryCueDate,
            coverEntryCueProgress: coverEntryCueProgress,
            frameCoordinateSpaceName: Layout.bookCoverGridCoordinateSpaceName,
            onBookCoverStackFramesChange: { frames in
                guard allowsDateSelection else { return }
                let normalizedFrames = frames.reduce(into: [Date: CGRect]()) { partialResult, pair in
                    let normalizedDate = Calendar.current.startOfDay(for: pair.key)
                    partialResult[normalizedDate] = pair.value
                }
                bookCoverStackFramesByDate = normalizedFrames
            },
            onOpenBookCoverFullscreen: { date in
                guard allowsDateSelection else { return }
                let normalizedDate = Calendar.current.startOfDay(for: date)
                let readDoneBookCount = page.dayMap[normalizedDate]?
                    .books
                    .filter(\.isReadDoneOnThisDay)
                    .count ?? 0
                openBookCoverFullscreen(
                    for: normalizedDate,
                    coverItemsByDate: coverItemsByDate,
                    readDoneBookCount: readDoneBookCount
                )
            },
            onOpenDay: { date in
                guard allowsDateSelection else { return }
                onOpenDay(Calendar.current.startOfDay(for: date))
            },
            onReadDoneEventSelected: { date in
                guard allowsDateSelection else { return }
                markSummaryFloatingButtonInteraction()
                let normalizedDate = Calendar.current.startOfDay(for: date)
                toggleDateSelection(normalizedDate, currentSelection: page.selectedDate)
            },
            onSelectDay: { date in
                guard allowsDateSelection else { return }
                markSummaryFloatingButtonInteraction()
                let normalizedDate = Calendar.current.startOfDay(for: date)
                toggleDateSelection(normalizedDate, currentSelection: page.selectedDate)
            }
        )
        .coordinateSpace(name: Layout.bookCoverGridCoordinateSpaceName)
    }

    /// 切换当前日期聚焦；活动事件模式依赖该状态突出经过所选日期的事件条。
    func toggleDateSelection(_ date: Date, currentSelection: Date?) {
        performMotion(Motion.dateSelection) {
            if let currentSelection,
               Calendar.current.isDate(currentSelection, inSameDayAs: date) {
                onSelectDate(nil)
            } else {
                onSelectDate(date)
            }
        }
    }

    var emptyState: some View {
        VStack(spacing: Spacing.base) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Color.appTint.opacity(0.8))

            if let errorMessage = props.errorMessage {
                Text(errorMessage)
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Color.feedbackWarning)
                    .multilineTextAlignment(.center)

                Button("重试", action: onRetry)
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.appTint)
            } else {
                Text(isHeatmapMode ? "暂无可展示的年度数据" : "暂无可展示的阅读月份")
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity, minHeight: Layout.pageMinHeight)
    }

    /// 将内容展示模式映射为网格组件可识别的显示模式。
    func mapGridDisplayMode(_ mode: DisplayMode) -> ReadCalendarMonthGrid.DisplayMode {
        switch mode {
        case .heatmap:
            return .heatmap
        case .activityEvent:
            return .activityEvent
        case .bookCover:
            return .bookCover
        }
    }

    /// 根据当前模式切换总结弹层与悬浮按钮状态，保持交互路径一致。
    func openMonthSummaryFromYearCard(for monthStart: Date) {
        let normalized = Calendar.current.startOfDay(for: monthStart)
        performMotion(Motion.summaryPresentation) {
            onPagerSelectionChanged(normalized)
        }
        summarySheetMonthStart = normalized
        isSummaryFloatingButtonVisible = false
        activeSheetDestination = .monthSummary
        summaryFloatingButtonAutoHideTask?.cancel()
        summaryFloatingButtonAutoHideTask = nil
    }

    /// 在正常模式保持原有时序，在 Reduce Motion 下立即提交结构状态。
    func performMotion(_ animation: Animation, updates: () -> Void) {
        if accessibilityReduceMotion {
            updates()
        } else {
            withAnimation(animation, updates)
        }
    }

    /// 根据当前模式切换总结弹层与悬浮按钮状态，保持交互路径一致。
    func openMonthSummaryAfterAuxSheetDismiss(monthStart: Date) {
        let normalized = Calendar.current.startOfDay(for: monthStart)
        summarySheetMonthStart = normalized
        activeSheetDestination = nil
        Task {
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled, activeSheetDestination != .yearSummary else { return }
            activeSheetDestination = .monthSummary
        }
    }

    /// 格式化年度热力图月卡标题（X月）。
    func yearHeatmapMonthTitle(_ monthStart: Date) -> String {
        let month = Calendar.current.component(.month, from: monthStart)
        return "\(month)月"
    }

    /// 将月周数据裁剪并补齐为紧凑周数组，适配年度月卡空间。
    func yearCompactWeeks(for page: MonthPage) -> [ReadCalendarMonthGrid.WeekData] {
        var weeks = Array(page.weeks.prefix(Layout.yearHeatmapCompactWeekCount))
        let emptyDays = Array<Date?>(repeating: nil, count: 7)
        let cal = Calendar.current
        if weeks.isEmpty {
            weeks.append(
                ReadCalendarMonthGrid.WeekData(
                    weekStart: cal.startOfDay(for: page.monthStart),
                    days: emptyDays,
                    segments: []
                )
            )
        }
        var cursor = weeks.last?.weekStart ?? cal.startOfDay(for: page.monthStart)

        while weeks.count < Layout.yearHeatmapCompactWeekCount {
            cursor = cal.date(byAdding: .day, value: 7, to: cursor).map { cal.startOfDay(for: $0) } ?? cursor
            weeks.append(
                ReadCalendarMonthGrid.WeekData(
                    weekStart: cursor,
                    days: emptyDays,
                    segments: []
                )
            )
        }

        return weeks
    }

    var yearHeatmapLoadingGrid: some View {
        VStack(spacing: Spacing.compact) {
            ForEach(0..<Layout.yearHeatmapCompactWeekCount, id: \.self) { _ in
                HStack(spacing: Layout.yearHeatmapLoadingCellSpacing) {
                    ForEach(0..<7, id: \.self) { _ in
                        RoundedRectangle(cornerRadius: CornerRadius.inlayTiny, style: .continuous)
                            .fill(ReadCalendarTheme.selectionFill.opacity(0.42))
                            .frame(maxWidth: .infinity)
                            .aspectRatio(1, contentMode: .fit)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

}

private struct ReadCalendarBookCoverFullscreenOverlay: View {
    private enum LayoutPhaseSource {
        case automatic
        case manual
    }

    private enum PhaseTransitionDirection {
        case toGrid
    }

    private enum DismissSource {
        case dragGesture
        case backdropTap
        case closeButton
    }

    private struct LayoutDebugSnapshot: Equatable {
        let overlayMinY: Int
        let screenHeight: Int
        let safeTop: Int
        let relativeSafeTop: Int
        let safeBottom: Int
        let topControlMaxY: Int
        let headerTopInset: Int
        let topChromeHeight: Int
        let rawBottomChromeHeight: Int
        let stageBottomChromeHeight: Int
        let availableStageHeight: Int
        let panelHeight: Int
        let fittedPanelHeight: Int
        let phase: String
        let stackedBaselineState: String
        let showHint: Bool
        let showToggle: Bool
    }

    private struct StackedLayoutBaselineSignature: Equatable {
        let overlayWidth: Int
        let overlayHeight: Int
        let overlayMinY: Int
        let safeTop: Int
        let safeBottom: Int
        let topControlMaxY: Int
    }

    private struct StackedLayoutBaseline: Equatable {
        let signature: StackedLayoutBaselineSignature
        let panelHeight: CGFloat
        let fittedPanelHeight: CGFloat
        let panelInnerSize: CGSize
        let coverSize: CGSize
        let stageBottomChromeHeight: CGFloat
    }

    private struct StagePanelLayoutMetrics {
        let panelHeight: CGFloat
        let fittedPanelHeight: CGFloat
        let panelInnerSize: CGSize
        let coverSize: CGSize
        let usesStackedBaseline: Bool
    }

    private struct StackedBaselineCaptureSnapshot: Equatable {
        let signature: StackedLayoutBaselineSignature
        let phase: ReadCalendarCoverFullscreenDeckStage.Phase
        let panelHeight: Int
        let fittedPanelHeight: Int
        let panelInnerWidth: Int
        let panelInnerHeight: Int
        let coverWidth: Int
        let coverHeight: Int
        let stageBottomChromeHeight: Int
    }

    private enum Layout {
        static let backdropMaxOpacity: CGFloat = 0.58
        static let backdropMaterialOpacity: CGFloat = 0.26
        static let dismissDragThreshold: CGFloat = 108
        static let closeButtonOpacity: CGFloat = 0.86
        static let closeButtonHitSize: CGFloat = InteractionMetrics.minimumTouchTarget
        static let autoGridDelayNanoseconds: UInt64 = 520_000_000
        static let switchToGridResponse: CGFloat = 0.36
        static let switchToGridDamping: CGFloat = 0.84
        static let switchToStackResponse: CGFloat = 0.30
        static let switchToStackDamping: CGFloat = 0.86
        static let panelShadowBaseOpacity: CGFloat = 0.028
        static let panelShadowExtraOpacity: CGFloat = 0.022
        static let panelShadowBaseRadius: CGFloat = 10
        static let panelShadowExtraRadius: CGFloat = 4
        static let panelShadowYOffset: CGFloat = 3
        static let hintShadowOpacity: CGFloat = 0.45
        static let hintShadowRadius: CGFloat = 2
        static let hintShadowYOffset: CGFloat = 1
        static let previewLimit = 12
        static let switchSettleNanoseconds: UInt64 = 430_000_000
        static let toggleButtonHorizontalPadding: CGFloat = 16
        static let toggleButtonVerticalPadding: CGFloat = 10
        static let toggleButtonBottomInsetExtra: CGFloat = 6
        static let toggleButtonBackgroundOpacity: CGFloat = 0.26
        static let toggleButtonStrokeOpacity: CGFloat = 0.18
        static let toggleButtonShadowOpacity: CGFloat = 0.14
        static let toggleButtonShadowRadius: CGFloat = 14
        static let toggleButtonEstimatedHeight: CGFloat = 42
        static let headerTopSafeAreaInset: CGFloat = 8
        static let headerTopMaxInset: CGFloat = 132
        static let headerToTopControlGap: CGFloat = 6
        static let headerUpwardAdjustment: CGFloat = Spacing.base
        static let headerHorizontalInset: CGFloat = Spacing.screenEdge
        static let headerBottomGap: CGFloat = Spacing.base
        static let headerActionVisualHeight: CGFloat = 28
        static let headerActionHorizontalPadding: CGFloat = Spacing.cozy
        static let stageBottomInsetExtra: CGFloat = 12
        static let stageToBottomChromeSpacing: CGFloat = Spacing.base
        static let stageUpwardMaxOffset: CGFloat = Spacing.double
        static let countHintEstimatedHeight: CGFloat = 20
        static let bottomChromeSpacing: CGFloat = Spacing.half
        static let stageMinHeight: CGFloat = 240
    }

    let payload: ReadCalendarContentView.BookCoverFullscreenPayload
    let isHapticsEnabled: Bool
    let doneMarkerStyle: ReadCalendarDoneMarkerStyle
    let doneEmojiAssetName: String
    let topControlBarFrameInGlobal: CGRect
    let onClose: () -> Void
    let onOpenDaily: () -> Void

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var dragOffsetY: CGFloat = 0
    @State private var layoutPhase: ReadCalendarCoverFullscreenDeckStage.Phase = .stacked
    @State private var phaseToken = 0
    @State private var hasAutoTransitioned = false
    @State private var hasCollapsedBackToStack = false
    @State private var autoGridTask: Task<Void, Never>?
    @State private var transitionPhase: ReadCalendarCoverTransitionPhase = .idle
    @State private var transitionProgress: CGFloat = 0
    @State private var transitionTask: Task<Void, Never>?
    @State private var closeTask: Task<Void, Never>?
    @State private var isClosing = false
    @State private var phaseTransitionDirection: PhaseTransitionDirection?
    @State private var phaseTransitionTask: Task<Void, Never>?
    @State private var isDeferringGridConstraint = false
    @State private var stageFrameInGlobal: CGRect = .zero
    @State private var lastLayoutDebugSnapshot: LayoutDebugSnapshot?
    @State private var stackedLayoutBaseline: StackedLayoutBaseline?
    @State private var lastReusedStackedBaselineSignature: StackedLayoutBaselineSignature?
    @State private var hapticPlayer: ReadCalendarOverlayHapticPlayer?

    var isAnimated: Bool { true }

    var motionSpec: ReadCalendarCoverTransitionSpec {
        accessibilityReduceMotion ? .reduceMotion : .immersiveElegant
    }

    var transitionChannels: ReadCalendarCoverTransitionChannels {
        ReadCalendarCoverTransitionRuntime.channels(
            phase: transitionPhase,
            progress: transitionProgress,
            spec: motionSpec
        )
    }

    var stageScale: CGFloat {
        ReadCalendarCoverTransitionRuntime.panelScale(
            phase: transitionPhase,
            progress: transitionProgress,
            spec: motionSpec
        )
    }

    var stageOffsetY: CGFloat {
        ReadCalendarCoverTransitionRuntime.panelOffsetY(
            phase: transitionPhase,
            progress: transitionProgress,
            spec: motionSpec
        ) + dragOffsetY
    }

    var shouldEnableGridPhase: Bool {
        payload.items.count > 1
    }

    var shouldAutoExpandToGridPhase: Bool {
        shouldEnableGridPhase
    }

    var shouldShowCountHint: Bool {
        shouldEnableGridPhase && layoutPhase == .grid
    }

    var shouldShowToggleButton: Bool {
        guard shouldEnableGridPhase else { return false }
        if layoutPhase == .grid {
            return true
        }
        return hasCollapsedBackToStack
    }

    var shouldConstrainStagePanel: Bool {
        layoutPhase == .grid
            && !isDeferringGridConstraint
            && phaseTransitionDirection != .toGrid
    }

    var headerEstimatedHeight: CGFloat {
        if dynamicTypeSize >= .accessibility5 {
            return 236
        }
        if dynamicTypeSize >= .accessibility4 {
            return 196
        }
        return dynamicTypeSize.isAccessibilitySize ? 132 : 72
    }

    var sourceCoverAspectRatio: CGFloat {
        let sourceSize = payload.transitionSession.sourceCoverSize
        guard sourceSize.width > 0, sourceSize.height > 0 else {
            return XMBookCover.heightToWidthAspectRatio
        }
        return sourceSize.height / sourceSize.width
    }

    var body: some View {
        GeometryReader { proxy in
            let overlayFrameInGlobal = proxy.frame(in: .global)
            let baselineSignature = makeStackedLayoutBaselineSignature(
                overlayFrameInGlobal: overlayFrameInGlobal,
                size: proxy.size,
                safeAreaInsets: proxy.safeAreaInsets
            )
            let stackedBaseline = stackedLayoutBaselineIfValid(for: baselineSignature)
            let livePanelHeight = resolvedPanelHeight(
                in: proxy.size,
                canScrollGrid: shouldEnableGridPhase
            )
            let headerTopInset = resolvedHeaderTopInset(
                safeAreaTop: proxy.safeAreaInsets.top,
                overlayFrameInGlobal: overlayFrameInGlobal
            )
            let toggleBottomInset = max(
                Spacing.base,
                proxy.safeAreaInsets.bottom + Layout.toggleButtonBottomInsetExtra + Layout.stageBottomInsetExtra
            )
            let topChromeHeight = headerTopInset + headerEstimatedHeight + Layout.headerBottomGap
            let countHintHeight = shouldShowCountHint ? Layout.countHintEstimatedHeight : 0
            let toggleButtonHeight = shouldShowToggleButton ? Layout.toggleButtonEstimatedHeight : 0
            let bottomChromeSpacing = (shouldShowCountHint && shouldShowToggleButton)
                ? Layout.bottomChromeSpacing
                : 0
            let bottomChromeContentHeight = countHintHeight
                + toggleButtonHeight
                + bottomChromeSpacing
            let stageToBottomChromeSpacing = bottomChromeContentHeight > 0
                ? Layout.stageToBottomChromeSpacing
                : 0
            let rawBottomChromeHeight = toggleBottomInset
                + bottomChromeContentHeight
                + stageToBottomChromeSpacing
            let stageBottomChromeHeight = resolvedStageBottomChromeHeight(
                rawBottomChromeHeight: rawBottomChromeHeight,
                stackedBaseline: stackedBaseline
            )
            let availableStageHeight = max(
                Layout.stageMinHeight,
                proxy.size.height - topChromeHeight - stageBottomChromeHeight
            )
            let liveFittedPanelHeight = min(livePanelHeight, availableStageHeight)
            let livePanelInnerSize = CGSize(
                width: max(0, proxy.size.width - Spacing.screenEdge * 2 - Spacing.double * 2),
                height: max(0, liveFittedPanelHeight - Spacing.base * 2)
            )
            let liveCoverSize = resolvedCoverSize(in: livePanelInnerSize)
            let stageLayout = resolvedStagePanelLayoutMetrics(
                stackedBaseline: stackedBaseline,
                livePanelHeight: livePanelHeight,
                liveFittedPanelHeight: liveFittedPanelHeight,
                livePanelInnerSize: livePanelInnerSize,
                liveCoverSize: liveCoverSize
            )
            let stageUpwardOffset = min(
                Layout.stageUpwardMaxOffset,
                max(0, stageLayout.panelHeight - stageLayout.fittedPanelHeight)
            )
            let baselineCaptureSnapshot = makeStackedBaselineCaptureSnapshot(
                signature: baselineSignature,
                phase: layoutPhase,
                panelHeight: livePanelHeight,
                fittedPanelHeight: liveFittedPanelHeight,
                panelInnerSize: livePanelInnerSize,
                coverSize: liveCoverSize,
                stageBottomChromeHeight: stageBottomChromeHeight
            )
            let debugSnapshot = makeLayoutDebugSnapshot(
                overlayFrameInGlobal: overlayFrameInGlobal,
                size: proxy.size,
                safeAreaInsets: proxy.safeAreaInsets,
                headerTopInset: headerTopInset,
                topChromeHeight: topChromeHeight,
                rawBottomChromeHeight: rawBottomChromeHeight,
                stageBottomChromeHeight: stageBottomChromeHeight,
                availableStageHeight: availableStageHeight,
                panelHeight: stageLayout.panelHeight,
                fittedPanelHeight: stageLayout.fittedPanelHeight,
                usesStackedBaseline: stageLayout.usesStackedBaseline
            )

            ZStack(alignment: .top) {
                backdrop

                heroGhostLayer(
                    coverSize: stageLayout.coverSize,
                    overlayGlobalFrame: overlayFrameInGlobal
                )
                .opacity(Double(transitionChannels.ghostOpacity))

                VStack(spacing: Spacing.none) {
                    Color.clear
                        .frame(height: topChromeHeight)

                    Spacer(minLength: 0)

                    VStack(spacing: stageToBottomChromeSpacing) {
                        stageDeckPanel(
                            coverSize: stageLayout.coverSize,
                            panelInnerSize: stageLayout.panelInnerSize
                        )
                        .frame(height: stageLayout.fittedPanelHeight)
                        .padding(.horizontal, Spacing.screenEdge)
                        .background {
                            GeometryReader { stageProxy in
                                let frame = stageProxy.frame(in: .global)
                                Color.clear
                                    .onAppear {
                                        stageFrameInGlobal = frame
                                    }
                                    .onChange(of: frame) { _, newValue in
                                        stageFrameInGlobal = newValue
                                    }
                            }
                        }
                        .shadow(
                            color: Color.black.opacity(
                                shouldConstrainStagePanel
                                    ? (
                                        Layout.panelShadowBaseOpacity
                                        + Layout.panelShadowExtraOpacity * transitionChannels.deckOpacity
                                    )
                                    : 0
                            ),
                            radius: shouldConstrainStagePanel
                                ? (
                                    Layout.panelShadowBaseRadius
                                        + Layout.panelShadowExtraRadius * transitionChannels.deckOpacity
                                )
                                : 0,
                            x: 0,
                            y: Layout.panelShadowYOffset
                        )
                        .opacity(Double(transitionChannels.deckOpacity))
                        .scaleEffect(stageScale)

                        if bottomChromeContentHeight > 0 {
                            bottomChrome
                        }
                    }
                    .offset(y: stageOffsetY - stageUpwardOffset)

                    Spacer(minLength: 0)

                    Color.clear
                        .frame(height: toggleBottomInset)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                header
                    .padding(.horizontal, Layout.headerHorizontalInset)
                    .padding(.top, headerTopInset)
                    .opacity(Double(transitionChannels.chromeOpacity))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                Color.clear
                    .onAppear {
                        syncStackedLayoutBaselineIfNeeded(using: baselineCaptureSnapshot)
                        logStackedBaselineReuseIfNeeded(
                            signature: baselineSignature,
                            usesStackedBaseline: stageLayout.usesStackedBaseline
                        )
                        logLayoutSnapshotIfNeeded(debugSnapshot)
                    }
                    .onChange(of: baselineCaptureSnapshot) { _, newValue in
                        syncStackedLayoutBaselineIfNeeded(using: newValue)
                    }
                    .onChange(of: debugSnapshot) { _, newValue in
                        logStackedBaselineReuseIfNeeded(
                            signature: baselineSignature,
                            usesStackedBaseline: newValue.stackedBaselineState == "reused"
                        )
                        logLayoutSnapshotIfNeeded(newValue)
                    }
            }
            .contentShape(Rectangle())
            .gesture(dismissDragGesture)
            .onAppear {
                handleAppear()
            }
            .onDisappear {
                cancelAutoGridTransition()
                cancelCloseTask()
                cancelPhaseTransitionTask()
                cancelTransitionTask()
                isClosing = false
                hapticPlayer?.shutdown()
                hapticPlayer = nil
            }
        }
    }

    /// 渲染可轻点关闭且不进入 VoiceOver 焦点序列的全屏背景；关闭按钮提供显式无障碍入口。
    private var backdrop: some View {
        ZStack {
            Color.black.opacity(Layout.backdropMaxOpacity * transitionChannels.backdropOpacity)
            Rectangle()
                .fill(.ultraThinMaterial)
                .opacity(Layout.backdropMaterialOpacity * transitionChannels.backdropOpacity)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
        .onTapGesture {
            dismiss(source: .backdropTap)
        }
    }

    var phaseHintText: String {
        "当日共 \(payload.items.count) 本"
    }

    var toggleButton: some View {
        let isStacked = layoutPhase == .stacked
        return Button {
            toggleLayoutPhase()
        } label: {
            HStack(spacing: Spacing.half) {
                Image(systemName: isStacked ? "square.grid.2x2" : "square.stack.3d.down.right.fill")
                    .font(.system(size: 13, weight: .semibold))
                Text(isStacked ? "展开" : "收起")
                    .font(AppTypography.subheadlineSemibold)
            }
            .foregroundStyle(Color.white.opacity(0.95))
            .padding(.horizontal, Layout.toggleButtonHorizontalPadding)
            .padding(.vertical, Layout.toggleButtonVerticalPadding)
            .background(
                Color.black.opacity(Layout.toggleButtonBackgroundOpacity),
                in: Capsule()
            )
            .overlay {
                Capsule()
                    .stroke(Color.white.opacity(Layout.toggleButtonStrokeOpacity), lineWidth: StrokeWidth.hairline)
            }
            .shadow(color: Color.black.opacity(Layout.toggleButtonShadowOpacity), radius: Layout.toggleButtonShadowRadius, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(isStacked ? "展开封面列表" : "收起封面列表")
    }

    var header: some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            VStack(alignment: .leading, spacing: Spacing.half) {
                dateMetadata
                headerActions
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                dismiss(source: .closeButton)
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(AppTypography.title3Semibold)
                    .foregroundStyle(Color.white.opacity(Layout.closeButtonOpacity))
                    .frame(
                        width: Layout.closeButtonHitSize,
                        height: Layout.closeButtonHitSize
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("关闭当日书籍封面全屏浮层")
        }
    }

    var dateMetadata: some View {
        ViewThatFits(in: .horizontal) {
            Text("\(formattedDate(payload.date)) \(formattedWeekday(payload.date))")
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)

            VStack(alignment: .leading, spacing: Spacing.tiny) {
                Text(formattedDate(payload.date))
                Text(formattedWeekday(payload.date))
            }
        }
        .font(AppTypography.headline)
        .foregroundStyle(Color.white.opacity(0.96))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(formattedDate(payload.date))，\(formattedWeekday(payload.date))")
    }

    var headerActions: some View {
        HStack(spacing: Spacing.compact) {
            if payload.readDoneBookCount > 0 {
                ReadCalendarDoneMarkerButton(
                    markerStyle: doneMarkerStyle,
                    emojiAssetName: doneEmojiAssetName,
                    readDoneBookCount: payload.readDoneBookCount,
                    isHapticsEnabled: isHapticsEnabled
                )
            }

            Button(action: onOpenDaily) {
                HStack(spacing: Spacing.tiny) {
                    Text("查看当日阅读")
                        .font(AppTypography.caption)
                    Image(systemName: "chevron.right")
                        .font(AppTypography.caption2)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(Color.white.opacity(0.72))
                .padding(.horizontal, Layout.headerActionHorizontalPadding)
                .frame(minHeight: Layout.headerActionVisualHeight)
                .background(Color.white.opacity(0.08), in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(
                            Color.white.opacity(0.12),
                            lineWidth: StrokeWidth.hairline
                        )
                }
                .frame(minHeight: Layout.closeButtonHitSize)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint("打开当日阅读详情")
        }
    }

    var bottomChrome: some View {
        VStack(spacing: Layout.bottomChromeSpacing) {
            if shouldShowCountHint {
                Text("当日共 \(payload.items.count) 本")
                    .font(AppTypography.footnoteSemibold)
                    .foregroundStyle(Color.white.opacity(0.9))
                    .shadow(
                        color: Color.black.opacity(Layout.hintShadowOpacity),
                        radius: Layout.hintShadowRadius,
                        x: 0,
                        y: Layout.hintShadowYOffset
                    )
            }

            if shouldShowToggleButton {
                toggleButton
            }
        }
        .opacity(Double(transitionChannels.chromeOpacity))
    }

    @ViewBuilder
    /// 把全屏封面舞台包装成独立面板层，供外层统一控制过渡和遮罩。
    func stageDeckPanel(
        coverSize: CGSize,
        panelInnerSize: CGSize
    ) -> some View {
        fullscreenDeckStage(
            coverSize: coverSize,
            panelInnerSize: panelInnerSize
        )
    }

    var dismissDragGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .onChanged { value in
                guard value.translation.height > 0 else { return }
                dragOffsetY = value.translation.height * 0.6
            }
            .onEnded { value in
                if value.translation.height > Layout.dismissDragThreshold {
                    dismiss(source: .dragGesture)
                    return
                }
                withAnimation(.spring(response: 0.26, dampingFraction: 0.82)) {
                    dragOffsetY = 0
                }
            }
    }

    private func makeLayoutDebugSnapshot(
        overlayFrameInGlobal: CGRect,
        size: CGSize,
        safeAreaInsets: EdgeInsets,
        headerTopInset: CGFloat,
        topChromeHeight: CGFloat,
        rawBottomChromeHeight: CGFloat,
        stageBottomChromeHeight: CGFloat,
        availableStageHeight: CGFloat,
        panelHeight: CGFloat,
        fittedPanelHeight: CGFloat,
        usesStackedBaseline: Bool
    ) -> LayoutDebugSnapshot {
        let relativeSafeTop = max(0, safeAreaInsets.top - overlayFrameInGlobal.minY)
        return LayoutDebugSnapshot(
            overlayMinY: Int(overlayFrameInGlobal.minY.rounded()),
            screenHeight: Int(size.height.rounded()),
            safeTop: Int(safeAreaInsets.top.rounded()),
            relativeSafeTop: Int(relativeSafeTop.rounded()),
            safeBottom: Int(safeAreaInsets.bottom.rounded()),
            topControlMaxY: Int(topControlBarFrameInGlobal.maxY.rounded()),
            headerTopInset: Int(headerTopInset.rounded()),
            topChromeHeight: Int(topChromeHeight.rounded()),
            rawBottomChromeHeight: Int(rawBottomChromeHeight.rounded()),
            stageBottomChromeHeight: Int(stageBottomChromeHeight.rounded()),
            availableStageHeight: Int(availableStageHeight.rounded()),
            panelHeight: Int(panelHeight.rounded()),
            fittedPanelHeight: Int(fittedPanelHeight.rounded()),
            phase: layoutPhase == .stacked ? "stacked" : "grid",
            stackedBaselineState: usesStackedBaseline ? "reused" : "live",
            showHint: shouldShowCountHint,
            showToggle: shouldShowToggleButton
        )
    }

    private func logLayoutSnapshotIfNeeded(_ snapshot: LayoutDebugSnapshot) {
#if DEBUG
        guard snapshot != lastLayoutDebugSnapshot else { return }
        lastLayoutDebugSnapshot = snapshot
        print(
            "[ReadCalendar][OverlayLayout] phase=\(snapshot.phase) overlayMinY=\(snapshot.overlayMinY) screenH=\(snapshot.screenHeight) safeTop=\(snapshot.safeTop) relativeSafeTop=\(snapshot.relativeSafeTop) safeBottom=\(snapshot.safeBottom) topControlMaxY=\(snapshot.topControlMaxY) headerTop=\(snapshot.headerTopInset) topChrome=\(snapshot.topChromeHeight) rawBottomChrome=\(snapshot.rawBottomChromeHeight) stageBottomChrome=\(snapshot.stageBottomChromeHeight) availableStage=\(snapshot.availableStageHeight) panel=\(snapshot.panelHeight) fittedPanel=\(snapshot.fittedPanelHeight) stackedBaseline=\(snapshot.stackedBaselineState) hint=\(snapshot.showHint) toggle=\(snapshot.showToggle)"
        )
#endif
    }

    /// 依据顶部控制栏底边锚点计算日期/关闭栏顶部 inset，确保其贴近模式切换控件下方。
    func resolvedHeaderTopInset(
        safeAreaTop: CGFloat,
        overlayFrameInGlobal: CGRect
    ) -> CGFloat {
        let relativeSafeTop = max(0, safeAreaTop - overlayFrameInGlobal.minY)
        let minInset = max(
            Spacing.base,
            relativeSafeTop + Layout.headerTopSafeAreaInset
        )
        guard topControlBarFrameInGlobal != .zero else {
            return minInset
        }
        let anchoredInset = topControlBarFrameInGlobal.maxY
            - overlayFrameInGlobal.minY
            + Layout.headerToTopControlGap
            - Layout.headerUpwardAdjustment
        return min(
            Layout.headerTopMaxInset,
            max(minInset, anchoredInset)
        )
    }

    /// 根据当前舞台可用空间和源封面宽高比计算全屏封面尺寸。
    func resolvedCoverSize(in panelInnerSize: CGSize) -> CGSize {
        return ReadCalendarCoverFullscreenDeckStage.resolveAdaptiveCoverSize(
            containerSize: panelInnerSize,
            visibleCount: payload.stackedVisibleCount,
            sourceAspectRatio: sourceCoverAspectRatio
        )
    }

    /// 依据屏幕高度和滚动能力计算全屏封面面板高度，避免堆叠态与网格态相互挤压。
    func resolvedPanelHeight(in size: CGSize, canScrollGrid: Bool) -> CGFloat {
        let lowerBound: CGFloat = canScrollGrid ? 360 : 340
        let upperBound = max(lowerBound, size.height * (canScrollGrid ? 0.82 : 0.78))
        let preferred = size.height * (canScrollGrid ? 0.74 : 0.66)
        return min(max(preferred, lowerBound), upperBound)
    }

    private func makeStackedLayoutBaselineSignature(
        overlayFrameInGlobal: CGRect,
        size: CGSize,
        safeAreaInsets: EdgeInsets
    ) -> StackedLayoutBaselineSignature {
        StackedLayoutBaselineSignature(
            overlayWidth: Int(size.width.rounded()),
            overlayHeight: Int(size.height.rounded()),
            overlayMinY: Int(overlayFrameInGlobal.minY.rounded()),
            safeTop: Int(safeAreaInsets.top.rounded()),
            safeBottom: Int(safeAreaInsets.bottom.rounded()),
            topControlMaxY: Int(topControlBarFrameInGlobal.maxY.rounded())
        )
    }

    private func stackedLayoutBaselineIfValid(
        for signature: StackedLayoutBaselineSignature
    ) -> StackedLayoutBaseline? {
        guard let baseline = stackedLayoutBaseline else { return nil }
        guard baseline.signature == signature else { return nil }
        return baseline
    }

    private func resolvedStageBottomChromeHeight(
        rawBottomChromeHeight: CGFloat,
        stackedBaseline: StackedLayoutBaseline?
    ) -> CGFloat {
        guard layoutPhase == .stacked, let stackedBaseline else {
            return rawBottomChromeHeight
        }
        return stackedBaseline.stageBottomChromeHeight
    }

    private func resolvedStagePanelLayoutMetrics(
        stackedBaseline: StackedLayoutBaseline?,
        livePanelHeight: CGFloat,
        liveFittedPanelHeight: CGFloat,
        livePanelInnerSize: CGSize,
        liveCoverSize: CGSize
    ) -> StagePanelLayoutMetrics {
        guard layoutPhase == .stacked, let stackedBaseline else {
            return StagePanelLayoutMetrics(
                panelHeight: livePanelHeight,
                fittedPanelHeight: liveFittedPanelHeight,
                panelInnerSize: livePanelInnerSize,
                coverSize: liveCoverSize,
                usesStackedBaseline: false
            )
        }
        return StagePanelLayoutMetrics(
            panelHeight: stackedBaseline.panelHeight,
            fittedPanelHeight: stackedBaseline.fittedPanelHeight,
            panelInnerSize: stackedBaseline.panelInnerSize,
            coverSize: stackedBaseline.coverSize,
            usesStackedBaseline: true
        )
    }

    private func makeStackedBaselineCaptureSnapshot(
        signature: StackedLayoutBaselineSignature,
        phase: ReadCalendarCoverFullscreenDeckStage.Phase,
        panelHeight: CGFloat,
        fittedPanelHeight: CGFloat,
        panelInnerSize: CGSize,
        coverSize: CGSize,
        stageBottomChromeHeight: CGFloat
    ) -> StackedBaselineCaptureSnapshot {
        StackedBaselineCaptureSnapshot(
            signature: signature,
            phase: phase,
            panelHeight: Int(panelHeight.rounded()),
            fittedPanelHeight: Int(fittedPanelHeight.rounded()),
            panelInnerWidth: Int(panelInnerSize.width.rounded()),
            panelInnerHeight: Int(panelInnerSize.height.rounded()),
            coverWidth: Int(coverSize.width.rounded()),
            coverHeight: Int(coverSize.height.rounded()),
            stageBottomChromeHeight: Int(stageBottomChromeHeight.rounded())
        )
    }

    private func syncStackedLayoutBaselineIfNeeded(
        using snapshot: StackedBaselineCaptureSnapshot
    ) {
#if DEBUG
        if let currentBaseline = stackedLayoutBaseline,
           currentBaseline.signature != snapshot.signature {
            print(
                "[ReadCalendar][StackedBaseline] reset from=\(describeStackedLayoutBaselineSignature(currentBaseline.signature)) to=\(describeStackedLayoutBaselineSignature(snapshot.signature))"
            )
            stackedLayoutBaseline = nil
            lastReusedStackedBaselineSignature = nil
        }
#else
        if let currentBaseline = stackedLayoutBaseline,
           currentBaseline.signature != snapshot.signature {
            stackedLayoutBaseline = nil
            lastReusedStackedBaselineSignature = nil
        }
#endif

        guard snapshot.phase == .stacked else { return }
        guard stackedLayoutBaseline == nil else { return }

        let captured = StackedLayoutBaseline(
            signature: snapshot.signature,
            panelHeight: CGFloat(snapshot.panelHeight),
            fittedPanelHeight: CGFloat(snapshot.fittedPanelHeight),
            panelInnerSize: CGSize(
                width: CGFloat(snapshot.panelInnerWidth),
                height: CGFloat(snapshot.panelInnerHeight)
            ),
            coverSize: CGSize(
                width: CGFloat(snapshot.coverWidth),
                height: CGFloat(snapshot.coverHeight)
            ),
            stageBottomChromeHeight: CGFloat(snapshot.stageBottomChromeHeight)
        )
        stackedLayoutBaseline = captured
        lastReusedStackedBaselineSignature = nil
#if DEBUG
        print(
            "[ReadCalendar][StackedBaseline] captured signature=\(describeStackedLayoutBaselineSignature(snapshot.signature)) fittedPanel=\(snapshot.fittedPanelHeight) coverW=\(snapshot.coverWidth)"
        )
#endif
    }

    private func logStackedBaselineReuseIfNeeded(
        signature: StackedLayoutBaselineSignature,
        usesStackedBaseline: Bool
    ) {
#if DEBUG
        guard usesStackedBaseline else { return }
        guard lastReusedStackedBaselineSignature != signature else { return }
        lastReusedStackedBaselineSignature = signature
        print(
            "[ReadCalendar][StackedBaseline] reused signature=\(describeStackedLayoutBaselineSignature(signature))"
        )
#endif
    }

    private func describeStackedLayoutBaselineSignature(
        _ signature: StackedLayoutBaselineSignature
    ) -> String {
        "w\(signature.overlayWidth)-h\(signature.overlayHeight)-minY\(signature.overlayMinY)-safeTop\(signature.safeTop)-safeBottom\(signature.safeBottom)-topMaxY\(signature.topControlMaxY)"
    }

    @ViewBuilder
    /// 构建全屏封面舞台主体，并注入当前阶段、布局算法和栅格策略。
    func fullscreenDeckStage(
        coverSize: CGSize,
        panelInnerSize: CGSize
    ) -> some View {
        let deckContainer = ReadCalendarCoverFullscreenDeckStage(
            items: payload.items,
            style: payload.stackStyle,
            coverSize: coverSize,
            containerSize: panelInnerSize,
            phase: layoutPhase,
            phaseToken: phaseToken,
            isAnimated: isAnimated,
            layoutSeed: payload.stackedSeed,
            stackedVisibleCount: payload.stackedVisibleCount,
            previewLimit: Layout.previewLimit,
            shouldClipGrid: shouldConstrainStagePanel,
            matchedTransitionStyle: .staggered,
            stackedLayoutAlgorithm: .editorialDeskScatter,
            coverSizingMode: .panelAwareBalanced,
            sourceCoverAspectRatio: sourceCoverAspectRatio,
            gridColumnLayoutMode: .fixed(count: 3, degradeForSmallItemCount: true)
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Spacing.double)
        .padding(.vertical, Spacing.base)
        deckContainer
    }

    /// 处理浮层首次出现：初始化阶段、触发触感并启动自动切换任务。
    func handleAppear() {
        let player = ReadCalendarOverlayHapticPlayer()
        hapticPlayer = player
        player.playOpenHaptic(isHapticsEnabled: isHapticsEnabled, reduceMotion: accessibilityReduceMotion)
        layoutPhase = .stacked
        hasAutoTransitioned = false
        hasCollapsedBackToStack = false
        isClosing = false
        cancelPhaseTransitionTask()
        startEnterTransition()
    }

    /// 在书籍数量超过阈值时，延迟自动切到列表态，提升可浏览性。
    func scheduleAutoGridTransitionIfNeeded() {
        cancelAutoGridTransition()
        guard transitionPhase == .steady else { return }
        guard shouldAutoExpandToGridPhase else { return }
        autoGridTask = Task {
            do {
                try await Task.sleep(nanoseconds: Layout.autoGridDelayNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard !isClosing else { return }
                guard !hasAutoTransitioned else { return }
                switchLayoutPhase(to: .grid, source: .automatic)
            }
        }
    }

    /// 取消自动切换任务，避免浮层关闭后任务回调污染当前状态。
    func cancelAutoGridTransition() {
        autoGridTask?.cancel()
        autoGridTask = nil
    }

    /// 取消关闭延迟任务，避免重复触发 onClose 导致状态竞争。
    func cancelCloseTask() {
        closeTask?.cancel()
        closeTask = nil
    }

    /// 手动切换堆叠态与列表态，用于过渡评估与对比观察。
    func toggleLayoutPhase() {
        let target: ReadCalendarCoverFullscreenDeckStage.Phase = layoutPhase == .stacked ? .grid : .stacked
        switchLayoutPhase(to: target, source: .manual)
    }

    /// 执行阶段切换动画，自动与手动切换统一走同一条状态机路径。
    private func switchLayoutPhase(
        to target: ReadCalendarCoverFullscreenDeckStage.Phase,
        source: LayoutPhaseSource
    ) {
        guard layoutPhase != target else { return }
        if source == .manual {
            cancelAutoGridTransition()
        }
        hasAutoTransitioned = true
        cancelPhaseTransitionTask(resetState: false)
        if target == .grid {
            hapticPlayer?.playExpandHaptic(isHapticsEnabled: isHapticsEnabled, reduceMotion: accessibilityReduceMotion)
            hasCollapsedBackToStack = false
            if isAnimated {
                phaseTransitionDirection = .toGrid
                isDeferringGridConstraint = true
            } else {
                phaseTransitionDirection = nil
                isDeferringGridConstraint = false
            }
        } else {
            hapticPlayer?.playCollapseHaptic(isHapticsEnabled: isHapticsEnabled, reduceMotion: accessibilityReduceMotion)
            hasCollapsedBackToStack = true
            phaseTransitionDirection = nil
            isDeferringGridConstraint = false
        }
        guard isAnimated else {
            layoutPhase = target
            phaseToken += 1
            return
        }
        let animationResponse = target == .grid
            ? Layout.switchToGridResponse
            : Layout.switchToStackResponse
        let animationDamping = target == .grid
            ? Layout.switchToGridDamping
            : Layout.switchToStackDamping
        withAnimation(
            .spring(
                response: animationResponse,
                dampingFraction: animationDamping
            )
        ) {
            layoutPhase = target
            phaseToken += 1
        }
        if target == .grid {
            schedulePhaseTransitionSettle()
        }
    }

    /// 在阶段切换后延迟收束过渡状态，避免动画尚未结束时过早恢复约束。
    func schedulePhaseTransitionSettle() {
        phaseTransitionTask = Task {
            do {
                try await Task.sleep(nanoseconds: Layout.switchSettleNanoseconds)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                phaseTransitionDirection = nil
                isDeferringGridConstraint = false
                phaseTransitionTask = nil
            }
        }
    }

    /// 取消阶段切换收束任务，并按需重置过渡方向和约束延迟状态。
    func cancelPhaseTransitionTask(resetState: Bool = true) {
        phaseTransitionTask?.cancel()
        phaseTransitionTask = nil
        guard resetState else { return }
        phaseTransitionDirection = nil
        isDeferringGridConstraint = false
    }

    @ViewBuilder
    /// 渲染封面从日历堆栈飞入全屏舞台的 ghost 图层，补齐真实源位和目标位之间的连续感。
    func heroGhostLayer(
        coverSize: CGSize,
        overlayGlobalFrame: CGRect
    ) -> some View {
        let sourceSize = payload.transitionSession.sourceCoverSize
        let hasValidSourceSize = sourceSize.width > 0 && sourceSize.height > 0
        let hasValidStageFrame = stageFrameInGlobal.width > 0 && stageFrameInGlobal.height > 0
        if hasValidSourceSize,
           hasValidStageFrame,
           let sourceFrame = payload.transitionSession.sourceStackFrame,
           sourceFrame.width > 0,
           sourceFrame.height > 0 {
            let travel = ReadCalendarCoverTransitionRuntime.ghostTravelProgress(
                phase: transitionPhase,
                progress: transitionProgress
            )
            let sourceCenterGlobal = CGPoint(x: sourceFrame.midX, y: sourceFrame.midY)
            let targetCenterGlobal = CGPoint(x: stageFrameInGlobal.midX, y: stageFrameInGlobal.midY)
            let currentCenterGlobal = CGPoint(
                x: lerp(sourceCenterGlobal.x, targetCenterGlobal.x, travel),
                y: lerp(sourceCenterGlobal.y, targetCenterGlobal.y, travel)
            )
            let localCenter = CGPoint(
                x: currentCenterGlobal.x - overlayGlobalFrame.minX,
                y: currentCenterGlobal.y - overlayGlobalFrame.minY
            )
            let targetScale = max(1, coverSize.width / max(1, sourceSize.width))
            let scale = lerp(1, targetScale, travel)

            ReadCalendarCoverFanStack(
                items: payload.items,
                maxVisibleCount: payload.stackedVisibleCount,
                coverSize: sourceSize,
                isAnimated: false,
                style: payload.stackStyle,
                presentationMode: .collapsed,
                layoutSeed: payload.stackedSeed
            )
            .frame(
                width: sourceSize.width * 4.2,
                height: sourceSize.height * 4.2,
                alignment: .center
            )
            .scaleEffect(scale)
            .position(localCenter)
            .allowsHitTesting(false)
        }
    }

    /// 将日期格式化为封面全屏详情使用的“月日”文案。
    func formattedDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "M月d日"
        return formatter.string(from: date)
    }

    /// 将日期转换为中文星期文案，供全屏封面详情展示。
    func formattedWeekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }

    private func dismiss(source: DismissSource) {
        guard !isClosing else { return }
        cancelAutoGridTransition()
        cancelTransitionTask()
        cancelCloseTask()
        cancelPhaseTransitionTask()
        if source == .dragGesture {
            dragOffsetY = max(0, dragOffsetY)
        } else {
            withAnimation(.smooth(duration: 0.2)) {
                dragOffsetY = 0
            }
        }
        isClosing = true
        runDismissTransition(source: source)
    }

    private func runDismissTransition(source _: DismissSource) {
        transitionPhase = .exiting
        guard isAnimated else {
            isClosing = false
            onClose()
            return
        }
        withAnimation(.linear(duration: motionSpec.closeDuration)) {
            transitionProgress = 0
        }
        closeTask = Task {
            do {
                try await Task.sleep(nanoseconds: nanoseconds(from: motionSpec.closeDuration))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                isClosing = false
                onClose()
            }
        }
    }

    /// 启动封面全屏入场过渡，并在动画结束后衔接自动回网格流程。
    func startEnterTransition() {
        cancelTransitionTask()
        transitionPhase = .entering
        transitionProgress = 0
        guard isAnimated else {
            transitionProgress = 1
            transitionPhase = .steady
            scheduleAutoGridTransitionIfNeeded()
            return
        }
        withAnimation(.linear(duration: motionSpec.openDuration)) {
            transitionProgress = 1
        }
        transitionTask = Task {
            do {
                try await Task.sleep(nanoseconds: nanoseconds(from: motionSpec.openDuration))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            await MainActor.run {
                transitionPhase = .steady
                transitionTask = nil
                scheduleAutoGridTransitionIfNeeded()
            }
        }
    }

    /// 取消当前入场过渡任务，避免重复切换时残留旧动画回调。
    func cancelTransitionTask() {
        transitionTask?.cancel()
        transitionTask = nil
    }

    /// 将秒数转换为 `Task.sleep` 需要的纳秒值，并对负值做安全钳制。
    func nanoseconds(from seconds: Double) -> UInt64 {
        UInt64(max(0, seconds) * 1_000_000_000)
    }

    /// 在两个标量之间做线性插值，统一封面过渡中的比例计算。
    func lerp(_ min: CGFloat, _ max: CGFloat, _ progress: CGFloat) -> CGFloat {
        min + (max - min) * progress
    }
}

private extension View {
    /// 预留底部沉浸样式扩展点；当前不应用模糊与边缘特效。
    func readCalendarBottomImmersiveStyle() -> some View {
        self
    }
}

#Preview {
    ReadCalendarContentView(
        props: .init(
            monthTitle: "2026年2月",
            yearTitle: "2026年",
            availableMonths: [Calendar.current.startOfDay(for: Date())],
            availableYears: [2026],
            pagerSelection: Calendar.current.startOfDay(for: Date()),
            selectedYear: 2026,
            displayMode: .activityEvent,
            laneLimit: 4,
            isHapticsEnabled: true,
            summaryFilterState: .none,
            doneMarkerStyle: .emoji,
            doneEmojiAssetName: ReadCalendarSettings.defaultDoneEmojiAssetName,
            rootContentState: .loading,
            errorMessage: nil,
            heatmapYearMonthPages: [],
            selectedYearLoadState: .idle,
            selectedYearErrorMessage: nil,
            yearSummary: .init(
                year: 2026,
                activeDays: 0,
                totalReadSeconds: 0,
                noteCount: 0,
                finishedBookCount: 0,
                activeDaysDelta: nil,
                readSecondsDelta: nil,
                noteCountDelta: nil,
                topBooks: [],
                rankingBarColorsByBookId: [:],
                monthContributions: [],
                isLoading: false,
                errorMessage: nil
            )
        ),
        monthPageProvider: { monthStart in
            ReadCalendarContentView.MonthPage(
                monthStart: monthStart,
                weeks: [],
                dayMap: [:],
                readingDurationTopBooks: [],
                summary: .empty,
                rankingBarColorsByBookId: [:],
                selectedDate: nil,
                todayStart: Calendar.current.startOfDay(for: Date()),
                laneLimit: 4,
                isLocked: false,
                isDayMapEmpty: true,
                loadState: .idle,
                errorMessage: nil
            )
        },
        onDisplayModeChanged: { _ in },
        onPagerSelectionChanged: { _ in },
        onYearSelectionChanged: { _ in },
        onSelectDate: { _ in },
        onOpenDay: { _ in },
        onLockedMonthSelected: { _ in },
        onRetry: {},
        onBookCoverFullscreenPresentationChanged: { _ in }
    )
    .padding(.horizontal, Spacing.screenEdge)
    .padding(.bottom, Spacing.base)
    .background(Color.surfacePage)
}
