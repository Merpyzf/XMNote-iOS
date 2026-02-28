import SwiftUI

/**
 * [INPUT]: 依赖 RepositoryContainer 注入统计与取色仓储，依赖 ReadCalendarViewModel 提供月历状态与事件布局数据
 * [OUTPUT]: 对外提供 ReadCalendarView（阅读日历页面壳层，负责挂载可复用 ReadCalendarPanel）
 * [POS]: Reading 模块核心页面入口，承接导航与数据加载，具体日历 UI 由 UIComponents 组件负责（含事件条颜色状态映射）
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct ReadCalendarView: View {
    @Environment(RepositoryContainer.self) private var repositories
    @State private var viewModel: ReadCalendarViewModel
    @State private var pagerSelectionTask: Task<Void, Never>?

    init(date: Date?) {
        _viewModel = State(initialValue: ReadCalendarViewModel(initialDate: date))
    }

    var body: some View {
        ZStack {
            Color.windowBackground.ignoresSafeArea()

            ReadCalendarPanel(
                props: panelProps,
                onStepMonth: { offset in
                    viewModel.stepPager(offset: offset)
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
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.base)
        }
        .navigationTitle("阅读日历")
        .navigationBarTitleDisplayMode(.inline)
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
            viewModel.cancelAsyncTasks()
        }
    }
}

// MARK: - Props Mapping

private extension ReadCalendarView {
    var panelProps: ReadCalendarPanel.Props {
        ReadCalendarPanel.Props(
            monthTitle: viewModel.monthTitle,
            availableMonths: viewModel.availableMonths,
            pagerSelection: viewModel.pagerSelection,
            laneLimit: viewModel.laneLimit,
            rootContentState: mapRootContentState(viewModel.rootContentState),
            errorMessage: viewModel.errorMessage,
            monthPages: viewModel.availableMonths.map(makePanelMonthPage),
            canGoPrevMonth: viewModel.canGoPrevMonth,
            canGoNextMonth: viewModel.canGoNextMonth
        )
    }

    func makePanelMonthPage(for monthStart: Date) -> ReadCalendarPanel.MonthPage {
        let state = viewModel.monthState(for: monthStart)

        let weeks = state.weeks.map { week in
            ReadCalendarMonthGrid.WeekData(
                weekStart: week.weekStart,
                days: week.days,
                segments: week.segments.map(mapEventSegment)
            )
        }

        var dayPayloads: [Date: ReadCalendarPanel.DayPayload] = [:]
        dayPayloads.reserveCapacity(state.weeks.count * 7)

        for day in state.weeks.flatMap(\.days).compactMap({ $0 }) {
            let normalized = Calendar.current.startOfDay(for: day)
            let dayData = state.dayMap[normalized]
            let bookCount = dayData?.books.count ?? 0

            dayPayloads[normalized] = ReadCalendarPanel.DayPayload(
                isReadDoneDay: dayData?.isReadDoneDay == true,
                overflowCount: max(0, bookCount - viewModel.laneLimit),
                isToday: viewModel.isToday(normalized),
                isSelected: viewModel.isSelected(normalized),
                isFuture: viewModel.isFutureDate(normalized)
            )
        }

        return ReadCalendarPanel.MonthPage(
            monthStart: state.monthStart,
            weeks: weeks,
            dayPayloads: dayPayloads,
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

    func mapRootContentState(_ state: ReadCalendarViewModel.RootContentState) -> ReadCalendarPanel.RootContentState {
        switch state {
        case .loading:
            return .loading
        case .empty:
            return .empty
        case .content:
            return .content
        }
    }

    func mapMonthLoadState(_ state: ReadCalendarViewModel.MonthLoadState) -> ReadCalendarPanel.MonthLoadState {
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
