import SwiftUI

/**
 * [INPUT]: 依赖 RepositoryContainer 注入统计与取色仓储，依赖 ReadCalendarViewModel 提供月历状态与事件布局数据
 * [OUTPUT]: 对外提供 ReadCalendarView（阅读日历页面壳层，负责挂载 ReadCalendarContentView）
 * [POS]: Reading 模块核心页面入口，承接导航与数据加载，具体日历 UI 由业务内壳层组件负责（含设置入口与显示模式切换）
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct ReadCalendarView: View {
    @Environment(RepositoryContainer.self) private var repositories
    @State private var viewModel: ReadCalendarViewModel
    @State private var pagerSelectionTask: Task<Void, Never>?
    @State private var displayMode: ReadCalendarContentView.DisplayMode = .activityEvent
    @State private var settings: ReadCalendarSettings
    @State private var settingsRefreshTask: Task<Void, Never>?
    @State private var isSettingsPresented = false
    @State private var settingsSheetHeight: CGFloat = 0

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
                },
                onPagerSelectionChanged: { monthStart in
                    viewModel.pagerSelection = monthStart
                },
                onSelectDate: { date in
                    viewModel.selectDate(date)
                },
                onRetry: {
                    retryCurrentContext()
                }
            )
            .padding(.bottom, Spacing.base)
        }
        .navigationTitle("阅读日历")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button { isSettingsPresented = true } label: {
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.readCalendarSubtleText)
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
        .onChange(of: viewModel.pagerSelection) { _, monthStart in
            pagerSelectionTask?.cancel()
            pagerSelectionTask = Task {
                await viewModel.handlePagerSelectionChange(
                    to: monthStart,
                    using: repositories.statisticsRepository,
                    colorRepository: repositories.readCalendarColorRepository
                )
            }
        }
        .onDisappear {
            pagerSelectionTask?.cancel()
            pagerSelectionTask = nil
            settingsRefreshTask?.cancel()
            settingsRefreshTask = nil
            viewModel.cancelAsyncTasks()
        }
    }
}

// MARK: - Settings Refresh

private extension ReadCalendarView {
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
    var contentProps: ReadCalendarContentView.Props {
        let todayStart = Calendar.current.startOfDay(for: Date())
        return ReadCalendarContentView.Props(
            monthTitle: viewModel.monthTitle,
            availableMonths: viewModel.availableMonths,
            pagerSelection: viewModel.pagerSelection,
            displayMode: displayMode,
            laneLimit: viewModel.laneLimit,
            isHapticsEnabled: settings.isHapticsEnabled,
            isStreakHintEnabled: settings.isStreakHintEnabled,
            rootContentState: mapRootContentState(viewModel.rootContentState),
            errorMessage: viewModel.errorMessage,
            monthPages: visibleMonthWindow.map { monthStart in
                makeContentMonthPage(for: monthStart, todayStart: todayStart)
            }
        )
    }

    var visibleMonthWindow: [Date] {
        let months = viewModel.availableMonths
        guard !months.isEmpty else { return [] }

        let anchorIndex: Int = {
            if let idx = months.firstIndex(of: viewModel.pagerSelection) { return idx }
            if let idx = months.firstIndex(of: viewModel.displayedMonthStart) { return idx }
            assertionFailure("visibleMonthWindow: pagerSelection 与 displayedMonthStart 均不在 availableMonths 中")
            return 0
        }()
        let lower = max(0, anchorIndex - 1)
        let upper = min(months.count - 1, anchorIndex + 1)
        return Array(months[lower...upper])
    }

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

    func retryCurrentContext() {
        Task {
            if viewModel.availableMonths.isEmpty {
                await viewModel.reload(
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
