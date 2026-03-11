import SwiftUI

/**
 * [INPUT]: 依赖 RepositoryContainer 注入统计与取色仓储，依赖 ReadCalendarViewModel 提供月历状态与事件布局数据
 * [OUTPUT]: 对外提供 ReadCalendarView（阅读日历页面壳层，负责挂载 ReadCalendarContentView）
 * [POS]: Reading 模块核心页面入口，承接导航与数据加载，具体日历 UI 由业务内壳层组件负责（含设置入口与显示模式切换）
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 阅读日历页面入口，负责创建 ViewModel、挂载设置态并衔接内容壳层。
struct ReadCalendarView: View {
    @Environment(RepositoryContainer.self) private var repositories
    @State private var viewModel: ReadCalendarViewModel
    @State private var pagerSelectionTask: Task<Void, Never>?
    @State private var yearSelectionTask: Task<Void, Never>?
    @State private var displayMode: ReadCalendarContentView.DisplayMode = .activityEvent
    @State private var settings: ReadCalendarSettings
    @State private var settingsRefreshTask: Task<Void, Never>?
    @State private var isSettingsPresented = false
    @State private var settingsSheetHeight: CGFloat = 0
    @State private var isBookCoverFullscreenPresented = false

    /// 注入初始日期并创建阅读日历页面入口。
    init(date: Date?) {
        let s = ReadCalendarSettings()
        _settings = State(initialValue: s)
        _viewModel = State(initialValue: ReadCalendarViewModel(initialDate: date, settings: s))
    }

    var body: some View {
        ZStack {
            Color.windowBackground.ignoresSafeArea()

            ReadCalendarContentView(
                props: contentProps,
                onDisplayModeChanged: { mode in
                    displayMode = mode
                    guard mode == .heatmap else { return }
                    yearSelectionTask?.cancel()
                    yearSelectionTask = Task {
                        await viewModel.prepareHeatmapYearIfNeeded(
                            using: repositories.statisticsRepository,
                            colorRepository: repositories.readCalendarColorRepository
                        )
                    }
                },
                onPagerSelectionChanged: { monthStart in
                    viewModel.pagerSelection = monthStart
                },
                onYearSelectionChanged: { year in
                    yearSelectionTask?.cancel()
                    yearSelectionTask = Task {
                        await viewModel.handleYearSelectionChange(
                            to: year,
                            using: repositories.statisticsRepository,
                            colorRepository: repositories.readCalendarColorRepository
                        )
                    }
                },
                onSelectDate: { date in
                    viewModel.selectDate(date)
                },
                onRetry: {
                    retryCurrentContext()
                },
                onBookCoverFullscreenPresentationChanged: { isPresented in
                    isBookCoverFullscreenPresented = isPresented
                }
            )
        }
        .navigationTitle("阅读日历")
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(isBookCoverFullscreenPresented ? .hidden : .visible, for: .navigationBar)
        .toolbarBackground(Color.windowBackground, for: .navigationBar)
        .tint(Color.readCalendarTopAction)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isSettingsPresented = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.readCalendarTopAction)
                }
                .accessibilityLabel("阅读日历设置")
            }
        }
        .sheet(isPresented: $isSettingsPresented) {
            ReadCalendarSettingsSheet(settings: settings)
                .onPreferenceChange(SheetHeightKey.self) { settingsSheetHeight = $0 }
                .presentationDetents([.height(settingsSheetHeight)])
        }
        .onChange(of: settings.excludedEventTypes) { _, _ in
            scheduleSettingsRefresh()
        }
        .onChange(of: settings.dayEventCount) { _, _ in
            viewModel.applyLaneLimitChange()
        }
        .task {
            await viewModel.loadIfNeeded(
                using: repositories.statisticsRepository,
                colorRepository: repositories.readCalendarColorRepository
            )
        }
        // pagerSelection 变更在 @MainActor 上串行执行，cancel → 新 Task 无竞态；
        // ViewModel 内部 per-monthKey ticket 机制保证过期请求被丢弃。
        .onChange(of: viewModel.pagerSelection) { _, monthStart in
            pagerSelectionTask?.cancel()
            pagerSelectionTask = Task {
                await viewModel.handlePagerSelectionChange(
                    to: monthStart,
                    using: repositories.statisticsRepository,
                    colorRepository: repositories.readCalendarColorRepository
                )

                guard !Task.isCancelled else { return }
                guard displayMode == .heatmap else { return }

                await viewModel.prepareHeatmapYearIfNeeded(
                    using: repositories.statisticsRepository,
                    colorRepository: repositories.readCalendarColorRepository
                )
            }
        }
        .onDisappear {
            pagerSelectionTask?.cancel()
            pagerSelectionTask = nil
            yearSelectionTask?.cancel()
            yearSelectionTask = nil
            settingsRefreshTask?.cancel()
            settingsRefreshTask = nil
            viewModel.cancelAsyncTasks()
        }
    }
}

// MARK: - Settings Refresh

private extension ReadCalendarView {
    /// 防抖触发设置变更刷新，避免频繁切换开关导致重复重载。
    func scheduleSettingsRefresh() {
        settingsRefreshTask?.cancel()
        settingsRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await viewModel.applySettingsChange(
                using: repositories.statisticsRepository,
                colorRepository: repositories.readCalendarColorRepository
            )
        }
    }
}

// MARK: - Props Mapping

private extension ReadCalendarView {
    var pagerWindowRadius: Int { 3 }

    var contentProps: ReadCalendarContentView.Props {
        // 每次 body 求值时重新计算 todayStart，确保跨午夜后"今天"标记实时更新。
        // 代价是每次 body 求值多一次 Calendar.startOfDay 调用，但日历页刷新频率较低，可接受。
        let todayStart = Calendar.current.startOfDay(for: Date())
        let selectedYearSummary = viewModel.yearSummaryState(for: viewModel.selectedYear)
        let heatmapYearPages = displayMode == .heatmap
            ? heatmapYearMonths.map { monthStart in
                makeContentMonthPage(for: monthStart, todayStart: todayStart)
            }
            : []
        return ReadCalendarContentView.Props(
            monthTitle: viewModel.monthTitle,
            yearTitle: viewModel.yearTitle,
            availableMonths: viewModel.availableMonths,
            availableYears: viewModel.availableYears,
            pagerSelection: viewModel.pagerSelection,
            selectedYear: viewModel.selectedYear,
            displayMode: displayMode,
            laneLimit: viewModel.laneLimit,
            isHapticsEnabled: settings.isHapticsEnabled,
            isStreakHintEnabled: settings.isStreakHintEnabled,
            rootContentState: mapRootContentState(viewModel.rootContentState),
            errorMessage: viewModel.errorMessage,
            monthPages: visibleMonthWindow.map { monthStart in
                makeContentMonthPage(for: monthStart, todayStart: todayStart)
            },
            heatmapYearMonthPages: heatmapYearPages,
            selectedYearLoadState: mapYearLoadState(viewModel.yearLoadState(for: viewModel.selectedYear)),
            selectedYearErrorMessage: selectedYearSummary.errorMessage,
            yearSummary: mapYearSummary(selectedYearSummary)
        )
    }

    var visibleMonthWindow: [Date] {
        let months = viewModel.availableMonths
        guard !months.isEmpty else { return [] }

        let anchorIndex: Int = {
            if let idx = months.firstIndex(of: viewModel.pagerSelection) { return idx }
            if let idx = months.firstIndex(of: viewModel.displayedMonthStart) { return idx }
            assertionFailure("visibleMonthWindow: pagerSelection 与 displayedMonthStart 均不在 availableMonths 中")
            #if DEBUG
            print("[ReadCalendar] visibleMonthWindow fallback: pagerSelection=\(viewModel.pagerSelection), displayedMonthStart=\(viewModel.displayedMonthStart), months.count=\(months.count)")
            #endif
            return 0
        }()
        let lower = max(0, anchorIndex - pagerWindowRadius)
        let upper = min(months.count - 1, anchorIndex + pagerWindowRadius)
        return Array(months[lower...upper])
    }

    var heatmapYearMonths: [Date] {
        viewModel.monthStartsForYear(viewModel.selectedYear)
    }

    /// 把 ViewModel 月状态转换为 ContentView 可渲染的页面模型。
    func makeContentMonthPage(for monthStart: Date, todayStart: Date) -> ReadCalendarContentView.MonthPage {
        let state = viewModel.monthState(for: monthStart)

        let weeks = state.weeks.map { week in
            ReadCalendarMonthGrid.WeekData(
                weekStart: week.weekStart,
                days: week.days,
                segments: week.segments.map(mapEventSegment)
            )
        }

        return ReadCalendarContentView.MonthPage(
            monthStart: state.monthStart,
            weeks: weeks,
            dayMap: state.dayMap,
            readingDurationTopBooks: state.readingDurationTopBooks,
            summary: state.summary,
            rankingBarColorsByBookId: state.rankingBarColorsByBookId,
            selectedDate: viewModel.selectedDate,
            todayStart: todayStart,
            laneLimit: viewModel.laneLimit,
            isDayMapEmpty: state.dayMap.isEmpty,
            loadState: mapMonthLoadState(state.loadState),
            errorMessage: state.errorMessage
        )
    }

    /// 将领域层事件段模型转换为月网格组件可渲染的事件段数据。
    func mapEventSegment(_ segment: ReadCalendarEventSegment) -> ReadCalendarMonthGrid.EventSegment {
        ReadCalendarMonthGrid.EventSegment(
            bookId: segment.bookId,
            bookName: segment.bookName,
            weekStart: segment.weekStart,
            segmentStartDate: segment.segmentStartDate,
            segmentEndDate: segment.segmentEndDate,
            laneIndex: segment.laneIndex,
            continuesFromPrevWeek: segment.continuesFromPrevWeek,
            continuesToNextWeek: segment.continuesToNextWeek,
            showsReadDoneBadge: segment.showsReadDoneBadge,
            color: mapSegmentColor(segment.color)
        )
    }

    /// 将领域层颜色模型转换为月网格颜色模型。
    func mapSegmentColor(_ color: ReadCalendarSegmentColor) -> ReadCalendarMonthGrid.EventColor {
        let state: ReadCalendarMonthGrid.EventColorState
        switch color.state {
        case .pending:
            state = .pending
        case .resolved:
            state = .resolved
        case .failed:
            state = .failed
        }

        return ReadCalendarMonthGrid.EventColor(
            state: state,
            backgroundRGBAHex: color.backgroundRGBAHex,
            textRGBAHex: color.textRGBAHex
        )
    }

    /// 将 ViewModel 根状态映射为内容组件根状态。
    func mapRootContentState(_ state: ReadCalendarViewModel.RootContentState) -> ReadCalendarContentView.RootContentState {
        switch state {
        case .loading:
            return .loading
        case .empty:
            return .empty
        case .content:
            return .content
        }
    }

    /// 将 ViewModel 月份加载状态映射为内容组件加载状态。
    func mapMonthLoadState(_ state: ReadCalendarViewModel.MonthLoadState) -> ReadCalendarContentView.MonthLoadState {
        switch state {
        case .idle:
            return .idle
        case .loading:
            return .loading
        case .loaded:
            return .loaded
        case .failed:
            return .failed
        }
    }

    /// 将 ViewModel 年度加载状态映射为内容组件加载状态。
    func mapYearLoadState(_ state: ReadCalendarViewModel.YearLoadState) -> ReadCalendarContentView.YearLoadState {
        switch state {
        case .idle:
            return .idle
        case .loading:
            return .loading
        case .loaded:
            return .loaded
        case .failed:
            return .failed
        }
    }

    /// 组装年度总结弹层数据，并补齐与上一年的同比指标。
    func mapYearSummary(_ state: ReadCalendarViewModel.YearSummaryState) -> ReadCalendarContentView.YearSummarySheetData {
        let previousYear = state.year - 1
        let previousSummary: ReadCalendarViewModel.YearSummaryState? = {
            guard viewModel.availableYears.contains(previousYear) else { return nil }
            guard viewModel.yearLoadState(for: previousYear) == .loaded else { return nil }
            return viewModel.yearSummaryState(for: previousYear)
        }()

        return ReadCalendarContentView.YearSummarySheetData(
            year: state.year,
            activeDays: state.activeDays,
            totalReadSeconds: state.totalReadSeconds,
            noteCount: state.noteCount,
            finishedBookCount: state.finishedBookCount,
            activeDaysDelta: previousSummary.map { state.activeDays - $0.activeDays },
            readSecondsDelta: previousSummary.map { state.totalReadSeconds - $0.totalReadSeconds },
            noteCountDelta: previousSummary.map { state.noteCount - $0.noteCount },
            topBooks: state.topBooks,
            rankingBarColorsByBookId: state.rankingBarColorsByBookId,
            monthContributions: state.monthContributions.map { item in
                ReadCalendarContentView.YearSummaryMonthContribution(
                    monthStart: item.monthStart,
                    activeDays: item.activeDays,
                    totalReadSeconds: item.totalReadSeconds
                )
            },
            isLoading: state.isLoading,
            errorMessage: state.errorMessage
        )
    }

    /// 按当前上下文执行重试：空态全量重载，年度模式重试年度数据，月模式重试当前月份。
    func retryCurrentContext() {
        Task {
            if viewModel.availableMonths.isEmpty {
                await viewModel.reload(
                    using: repositories.statisticsRepository,
                    colorRepository: repositories.readCalendarColorRepository
                )
            } else if displayMode == .heatmap {
                await viewModel.handleYearSelectionChange(
                    to: viewModel.selectedYear,
                    using: repositories.statisticsRepository,
                    colorRepository: repositories.readCalendarColorRepository
                )
            } else {
                await viewModel.retryDisplayedMonth(
                    using: repositories.statisticsRepository,
                    colorRepository: repositories.readCalendarColorRepository
                )
            }
        }
    }
}

#Preview {
    NavigationStack {
        ReadCalendarView(date: Date())
            .environment(RepositoryContainer(databaseManager: try! DatabaseManager()))
    }
}
