import SwiftUI

/**
 * [INPUT]: 依赖 RepositoryContainer/AppState 注入统计、取色仓储与会员限制开关，依赖 ReadCalendarViewModel 提供月历状态与事件布局数据
 * [OUTPUT]: 对外提供 ReadCalendarView（挂载内容页、透传统计过滤设置、提供语义化日历设置菜单并映射领域层年度同期摘要）
 * [POS]: Reading 模块核心页面入口，承接导航与数据加载，具体日历 UI 由业务内壳层组件负责（含设置入口与显示模式切换）
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 阅读日历页面入口，负责创建 ViewModel、挂载设置态并衔接内容壳层。
struct ReadCalendarView: View {
    let onOpenRoute: (ReadCalendarRoute) -> Void
    let onOpenPremium: () -> Void
    @Environment(RepositoryContainer.self) private var repositories
    @Environment(AppState.self) private var appState
    @Environment(SceneStateStore.self) private var sceneStateStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var viewModel: ReadCalendarViewModel
    @State private var pagerSelectionTask: Task<Void, Never>?
    @State private var yearSelectionTask: Task<Void, Never>?
    @State private var displayMode: ReadCalendarContentView.DisplayMode = .bookCover
    @State private var settings: ReadCalendarSettings
    @State private var settingsRefreshTask: Task<Void, Never>?
    @State private var lifecycleRefreshTask: Task<Void, Never>?
    @State private var isSettingsPresented = false
    @State private var isCheckInPresented = false
    @State private var isCheckInSaving = false
    @State private var isPremiumMonthAlertPresented = false
    @State private var isBookCoverFullscreenPresented = false
    @State private var didBootstrapFromScene = false
    @State private var canPersistSceneSnapshot = false

    /// 注入初始日期并创建阅读日历页面入口。
    init(
        date: Date?,
        onOpenRoute: @escaping (ReadCalendarRoute) -> Void = { _ in },
        onOpenPremium: @escaping () -> Void = { }
    ) {
        self.onOpenRoute = onOpenRoute
        self.onOpenPremium = onOpenPremium
        let s = ReadCalendarSettings()
        _settings = State(initialValue: s)
        _viewModel = State(initialValue: ReadCalendarViewModel(initialDate: date, settings: s))
    }

    var body: some View {
        ZStack {
            Color.surfacePage.ignoresSafeArea()

            ReadCalendarContentView(
                props: contentProps,
                monthPageProvider: { monthStart in
                    makeContentMonthPage(
                        for: monthStart,
                        todayStart: Calendar.current.startOfDay(for: Date())
                    )
                },
                onDisplayModeChanged: { mode in
                    displayMode = mode
                    guard mode == .heatmap else { return }
                    yearSelectionTask?.cancel()
                    yearSelectionTask = Task {
                        await viewModel.prepareHeatmapYearIfNeeded(
                            using: repositories.readCalendarRepository,
                            colorRepository: repositories.readCalendarColorRepository
                        )
                    }
                },
                onPagerSelectionChanged: { monthStart in
                    handleRequestedMonth(monthStart)
                },
                onYearSelectionChanged: { year in
                    yearSelectionTask?.cancel()
                    yearSelectionTask = Task {
                        await viewModel.handleYearSelectionChange(
                            to: year,
                            using: repositories.readCalendarRepository,
                            colorRepository: repositories.readCalendarColorRepository
                        )
                    }
                },
                onSelectDate: { date in
                    viewModel.selectDate(date)
                },
                onOpenDay: { date in
                    onOpenRoute(.daily(date: date))
                },
                onLockedMonthSelected: { _ in
                    guard appState.shouldEnforcePremiumRestrictions else { return }
                    if settings.isHapticsEnabled {
                        ReadCalendarHaptics.selection()
                    }
                    isPremiumMonthAlertPresented = true
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
        .toolbarBackground(Color.surfacePage, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button {
                        isCheckInPresented = true
                    } label: {
                        Label("今天打卡", systemImage: "checkmark.circle")
                    }
                    Button {
                        onOpenRoute(.share(
                            monthStart: viewModel.pagerSelection,
                            initialType: shareTypeForDisplayMode
                        ))
                    } label: {
                        Label("分享日历", systemImage: "square.and.arrow.up")
                    }
                    Button {
                        isSettingsPresented = true
                    } label: {
                        Label("日历设置", systemImage: "slider.horizontal.3")
                    }
                } label: {
                    Label("更多", systemImage: "ellipsis")
                        .labelStyle(.iconOnly)
                }
                .xmToolbarNeutralTint()
                .accessibilityLabel("阅读日历操作")
            }
        }
        .sheet(isPresented: $isSettingsPresented) {
            ReadCalendarSettingsSheet(settings: settings)
        }
        .sheet(isPresented: $isCheckInPresented) {
            ReadCalendarCheckInSheet(
                date: Date(),
                initialBook: todayInitialBook,
                isSaving: isCheckInSaving,
                onSave: { bookID, amount in
                    try await saveTodayCheckIn(bookID: bookID, amount: amount)
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .xmSystemAlert(
            isPresented: $isPremiumMonthAlertPresented,
            descriptor: XMSystemAlertDescriptor(
                title: "查看更早的阅读日历",
                message: "免费版可查看最近 6 个自然月，会员可访问全部历史阅读记录。",
                actions: [
                    XMSystemAlertAction(title: "取消", role: .cancel) { },
                    XMSystemAlertAction(title: "了解会员") { onOpenPremium() }
                ]
            )
        )
        .onChange(of: settings.excludedEventTypes) { _, _ in
            scheduleSettingsRefresh()
        }
        .onChange(of: settings.dayEventCount) { _, _ in
            viewModel.applyLaneLimitChange()
        }
        .task(id: sceneStateStore.isRestored) {
            guard sceneStateStore.isRestored else { return }
            guard !didBootstrapFromScene else { return }
            didBootstrapFromScene = true
            canPersistSceneSnapshot = false
            if let snapshot = sceneStateStore.snapshot.reading.readCalendar {
                viewModel.applySceneSnapshot(snapshot)
                displayMode = snapshot.displayMode
            }
            viewModel.updateAccessBoundary(minimumAccessibleMonthStart: minimumAccessibleMonthStart)
            if isPremiumMonthLocked(viewModel.pagerSelection) {
                let calendar = Calendar.current
                viewModel.pagerSelection = calendar.date(
                    from: calendar.dateComponents([.year, .month], from: Date())
                ) ?? Date()
                isPremiumMonthAlertPresented = true
            }
            await viewModel.loadIfNeeded(
                using: repositories.readCalendarRepository,
                colorRepository: repositories.readCalendarColorRepository
            )
            canPersistSceneSnapshot = true
            syncSceneSnapshot()
        }
        // pagerSelection 变更在 @MainActor 上串行执行，cancel → 新 Task 无竞态；
        // ViewModel 内部 per-monthKey ticket 机制保证过期请求被丢弃。
        .onChange(of: viewModel.pagerSelection) { _, monthStart in
            pagerSelectionTask?.cancel()
            pagerSelectionTask = Task {
                await viewModel.handlePagerSelectionChange(
                    to: monthStart,
                    using: repositories.readCalendarRepository,
                    colorRepository: repositories.readCalendarColorRepository
                )

                guard !Task.isCancelled else { return }
                guard displayMode == .heatmap else { return }

                await viewModel.prepareHeatmapYearIfNeeded(
                    using: repositories.readCalendarRepository,
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
            lifecycleRefreshTask?.cancel()
            lifecycleRefreshTask = nil
            viewModel.cancelAsyncTasks()
        }
        .onAppear {
            syncSceneSnapshot()
            guard canPersistSceneSnapshot else { return }
            scheduleLifecycleRefresh()
        }
        .onChange(of: scenePhase) { _, phase in
            handleScenePhaseChange(phase)
        }
        .onChange(of: viewModel.pagerSelection) { _, _ in
            syncSceneSnapshot()
        }
        .onChange(of: viewModel.selectedDate) { _, _ in
            syncSceneSnapshot()
        }
        .onChange(of: viewModel.selectedYear) { _, _ in
            syncSceneSnapshot()
        }
        .onChange(of: displayMode) { _, _ in
            syncSceneSnapshot()
        }
        .onChange(of: appState.shouldEnforcePremiumRestrictions) { _, shouldEnforce in
            if !shouldEnforce {
                isPremiumMonthAlertPresented = false
            }
            viewModel.updateAccessBoundary(minimumAccessibleMonthStart: minimumAccessibleMonthStart)
            scheduleSettingsRefresh()
        }
    }
}

// MARK: - Settings Refresh

private extension ReadCalendarView {
    /// 回到前台后失效并刷新当前范围；未完成现场恢复时忽略生命周期回调。
    func handleScenePhaseChange(_ phase: ScenePhase) {
        guard phase == .active, canPersistSceneSnapshot else { return }
        scheduleLifecycleRefresh()
    }

    /// 在分页写入前执行免费月份边界判断，拒绝后保持原页现场不变。
    func handleRequestedMonth(_ monthStart: Date) {
        guard !isPremiumMonthLocked(monthStart) else {
            isPremiumMonthAlertPresented = true
            return
        }
        viewModel.pagerSelection = monthStart
    }

    /// 免费版只开放当前自然月及向前连续五个月。
    func isPremiumMonthLocked(_ date: Date) -> Bool {
        guard let minimumAccessibleMonthStart else { return false }
        let calendar = Calendar.current
        let normalized = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        return normalized < minimumAccessibleMonthStart
    }

    /// 免费版当前自然月及向前五个月可访问；会员不设置历史下界。
    var minimumAccessibleMonthStart: Date? {
        guard appState.shouldEnforcePremiumRestrictions else { return nil }
        let calendar = Calendar.current
        let current = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
        return calendar.date(byAdding: .month, value: -5, to: current) ?? current
    }

    /// 写入今天的打卡后跳到本月并强制刷新，确保网格、摘要和后续详情口径同步。
    func saveTodayCheckIn(bookID: Int64, amount: Int) async throws {
        guard !isCheckInSaving else { return }
        isCheckInSaving = true
        defer { isCheckInSaving = false }
        try await repositories.readCalendarRepository.saveCheckIn(
            ReadCalendarCheckInDraft(
                recordID: nil,
                bookID: bookID,
                amount: amount,
                date: Date()
            )
        )
        let calendar = Calendar.current
        let currentMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: Date())) ?? Date()
        viewModel.pagerSelection = currentMonth
        await viewModel.handlePagerSelectionChange(
            to: currentMonth,
            using: repositories.readCalendarRepository,
            colorRepository: repositories.readCalendarColorRepository
        )
        await viewModel.retryDisplayedMonth(
            using: repositories.readCalendarRepository,
            colorRepository: repositories.readCalendarColorRepository
        )
        if displayMode == .heatmap {
            await viewModel.prepareHeatmapYearIfNeeded(
                using: repositories.readCalendarRepository,
                colorRepository: repositories.readCalendarColorRepository
            )
        }
    }

    var todayInitialBook: ReadCalendarDayBook? {
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let month = calendar.date(from: calendar.dateComponents([.year, .month], from: today)) ?? today
        return viewModel.monthState(for: month).dayMap[today]?.books.first
    }

    var shareTypeForDisplayMode: ReadCalendarShareType {
        switch displayMode {
        case .heatmap: .yearHeatmap
        case .activityEvent: .monthEvent
        case .bookCover: .monthCover
        }
    }

    func syncSceneSnapshot() {
        guard canPersistSceneSnapshot else { return }
        sceneStateStore.updateReadCalendar(
            ReadCalendarSceneSnapshot(
                pagerSelection: viewModel.pagerSelection,
                selectedDate: viewModel.selectedDate,
                displayMode: displayMode,
                selectedYear: viewModel.selectedYear
            )
        )
    }

    /// 防抖触发设置变更刷新，避免频繁切换开关导致重复重载。
    func scheduleSettingsRefresh() {
        settingsRefreshTask?.cancel()
        settingsRefreshTask = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await viewModel.applySettingsChange(
                using: repositories.readCalendarRepository,
                colorRepository: repositories.readCalendarColorRepository
            )
            guard !Task.isCancelled, displayMode == .heatmap else { return }
            await viewModel.prepareHeatmapYearIfNeeded(
                using: repositories.readCalendarRepository,
                colorRepository: repositories.readCalendarColorRepository
            )
        }
    }

    /// 页面重新可见或 App 回到前台时刷新当前范围，并同步使年度派生数据重新计算。
    func scheduleLifecycleRefresh() {
        viewModel.updateAccessBoundary(minimumAccessibleMonthStart: minimumAccessibleMonthStart)
        lifecycleRefreshTask?.cancel()
        lifecycleRefreshTask = Task {
            await viewModel.refreshVisibleRange(
                using: repositories.readCalendarRepository,
                colorRepository: repositories.readCalendarColorRepository
            )
            viewModel.updateAccessBoundary(minimumAccessibleMonthStart: minimumAccessibleMonthStart)
            guard !Task.isCancelled, displayMode == .heatmap else { return }
            await viewModel.refreshHeatmapYear(
                using: repositories.readCalendarRepository,
                colorRepository: repositories.readCalendarColorRepository
            )
        }
    }
}

// MARK: - Props Mapping

private extension ReadCalendarView {
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
            summaryFilterState: .init(
                excludeReadTime: settings.excludeReadTiming,
                excludeNote: settings.excludeNote,
                excludeReadDone: settings.excludeReadDone
            ),
            doneMarkerStyle: settings.doneMarkerStyle,
            doneEmojiAssetName: settings.doneEmojiAssetName,
            rootContentState: mapRootContentState(viewModel.rootContentState),
            errorMessage: viewModel.errorMessage,
            heatmapYearMonthPages: heatmapYearPages,
            selectedYearLoadState: mapYearLoadState(viewModel.yearLoadState(for: viewModel.selectedYear)),
            selectedYearErrorMessage: selectedYearSummary.errorMessage,
            yearSummary: mapYearSummary(selectedYearSummary)
        )
    }

    var heatmapYearMonths: [Date] {
        viewModel.monthStartsForYear(viewModel.selectedYear)
    }

    /// 把 ViewModel 月状态转换为 ContentView 可渲染的页面模型。
    func makeContentMonthPage(for monthStart: Date, todayStart: Date) -> ReadCalendarContentView.MonthPage {
        let state = viewModel.monthState(for: monthStart)
        let isLocked = viewModel.isMonthLocked(monthStart)
        let visibleDayMap = isLocked ? [:] : state.dayMap

        let weeks = state.weeks.map { week in
            ReadCalendarMonthGrid.WeekData(
                weekStart: week.weekStart,
                days: week.days,
                segments: isLocked ? [] : week.segments.map(mapEventSegment)
            )
        }

        return ReadCalendarContentView.MonthPage(
            monthStart: state.monthStart,
            weeks: weeks,
            dayMap: visibleDayMap,
            readingDurationTopBooks: isLocked ? [] : state.readingDurationTopBooks,
            summary: isLocked ? .empty : state.summary,
            rankingBarColorsByBookId: isLocked ? [:] : state.rankingBarColorsByBookId,
            selectedDate: viewModel.selectedDate,
            todayStart: todayStart,
            laneLimit: viewModel.laneLimit,
            isLocked: isLocked,
            isDayMapEmpty: visibleDayMap.isEmpty,
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

    /// 组装年度总结弹层数据，直接透传领域层已按同期边界计算的同比指标。
    func mapYearSummary(_ state: ReadCalendarViewModel.YearSummaryState) -> ReadCalendarContentView.YearSummarySheetData {
        return ReadCalendarContentView.YearSummarySheetData(
            year: state.year,
            activeDays: state.activeDays,
            totalReadSeconds: state.totalReadSeconds,
            noteCount: state.noteCount,
            finishedBookCount: state.finishedBookCount,
            activeDaysDelta: state.activeDaysDelta,
            readSecondsDelta: state.readSecondsDelta,
            noteCountDelta: state.noteCountDelta,
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
                    using: repositories.readCalendarRepository,
                    colorRepository: repositories.readCalendarColorRepository
                )
            } else if displayMode == .heatmap {
                await viewModel.handleYearSelectionChange(
                    to: viewModel.selectedYear,
                    using: repositories.readCalendarRepository,
                    colorRepository: repositories.readCalendarColorRepository
                )
            } else {
                await viewModel.retryDisplayedMonth(
                    using: repositories.readCalendarRepository,
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
            .environment(AppState())
    }
}
