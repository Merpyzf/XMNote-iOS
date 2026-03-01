import SwiftUI

/**
 * [INPUT]: 依赖 RepositoryContainer 注入统计与取色仓储，依赖 ReadCalendarViewModel 提供月历状态与事件布局数据
 * [OUTPUT]: 对外提供 ReadCalendarView（阅读日历页面壳层，负责挂载可复用 ReadCalendarPanel）
 * [POS]: Reading 模块核心页面入口，承接导航与数据加载，具体日历 UI 由 UIComponents 组件负责（含设置入口与显示模式切换）
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct ReadCalendarView: View {
    @Environment(RepositoryContainer.self) private var repositories
    @State private var viewModel: ReadCalendarViewModel
    @State private var pagerSelectionTask: Task<Void, Never>?
    @State private var displayMode: ReadCalendarPanel.DisplayMode = .activityEvent
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

            ReadCalendarPanel(
                props: panelProps,
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

// MARK: - Settings Sheet

private struct ReadCalendarSettingsSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var settings: ReadCalendarSettings
    @State private var showInvalidCloseAlert = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: Spacing.double) {
                titleSection
                    .padding(.trailing, 44)
                eventTogglesSection
                feedbackSection
                dayEventCountSection
            }
            .padding(Spacing.double)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: SheetHeightKey.self, value: proxy.size.height)
                }
            )

            closeButton
        }
        .interactiveDismissDisabled(!settings.isReadBehaviorRuleValid)
        .alert("无法关闭设置", isPresented: $showInvalidCloseAlert) {
            Button("我知道了", role: .cancel) {}
        } message: {
            Text("判定阅读行为的规则至少要选一个")
        }
    }

    // MARK: - Close

    private var closeButton: some View {
        Button {
            guard settings.isReadBehaviorRuleValid else {
                showInvalidCloseAlert = true
                return
            }
            dismiss()
        } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .padding(.top, Spacing.double)
        .padding(.trailing, Spacing.double)
    }

    // MARK: - Title

    private var titleSection: some View {
        Text("阅读日历设置")
            .font(.title3.weight(.semibold))
    }

    // MARK: - Event Toggles

    private var eventTogglesSection: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text("阅读事件")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.textSecondary)

            Toggle("阅读计时（含补录）", isOn: Binding(
                get: { !settings.excludeReadTiming },
                set: { settings.excludeReadTiming = !$0 }
            ))

            Toggle("笔记记录", isOn: Binding(
                get: { !settings.excludeNoteRecord },
                set: { settings.excludeNoteRecord = !$0 }
            ))

            Toggle("阅读打卡", isOn: Binding(
                get: { !settings.excludeCheckIn },
                set: { settings.excludeCheckIn = !$0 }
            ))

            if !settings.isReadBehaviorRuleValid {
                Text("判定阅读行为的规则至少要选一个")
                    .font(.footnote)
                    .foregroundStyle(Color.feedbackError)
            }
        }
        .tint(.brand)
    }

    // MARK: - Day Event Count

    private var feedbackSection: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text("交互反馈")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.textSecondary)

            Toggle("触感反馈", isOn: $settings.isHapticsEnabled)

            Toggle("连续阅读提示", isOn: $settings.isStreakHintEnabled)
        }
        .tint(.brand)
    }

    private var dayEventCountSection: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text("每日展示书籍数量")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Color.textSecondary)

            HStack(spacing: Spacing.half) {
                ForEach(Array(ReadCalendarSettings.dayEventCountRange), id: \.self) { count in
                    dayCountChip(count, isSelected: count == settings.dayEventCount)
                }
            }
        }
    }

    private func dayCountChip(_ count: Int, isSelected: Bool) -> some View {
        Button {
            withAnimation(.snappy) { settings.dayEventCount = count }
        } label: {
            Text("\(count)")
                .font(.subheadline.weight(isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .white : Color.textPrimary)
                .frame(width: 36, height: 36)
                .background(isSelected ? Color.brand : Color.bgSecondary, in: Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(count) 本")
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
    var panelProps: ReadCalendarPanel.Props {
        let todayStart = Calendar.current.startOfDay(for: Date())
        return ReadCalendarPanel.Props(
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
                makePanelMonthPage(for: monthStart, todayStart: todayStart)
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

    func makePanelMonthPage(for monthStart: Date, todayStart: Date) -> ReadCalendarPanel.MonthPage {
        let state = viewModel.monthState(for: monthStart)

        let weeks = state.weeks.map { week in
            ReadCalendarMonthGrid.WeekData(
                weekStart: week.weekStart,
                days: week.days,
                segments: week.segments.map(mapEventSegment)
            )
        }

        return ReadCalendarPanel.MonthPage(
            monthStart: state.monthStart,
            weeks: weeks,
            dayMap: state.dayMap,
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
