import SwiftUI

/**
 * [INPUT]: 依赖 RepositoryContainer 注入首页仓储，依赖 ReadingDashboardViewModel 驱动首页状态，依赖 ReadingHeatmapWidgetView 复用热力图卡，依赖外层回调打开书籍详情与阅读计时
 * [OUTPUT]: 对外提供 ReadingDashboardView（在读首页真实内容容器）
 * [POS]: Reading 模块首页入口，整合热力图、趋势卡、目标卡、继续阅读、最近在读与年度摘要
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
/// ReadingDashboardView 是在读首页真实内容页，负责组装热力图、趋势卡、目标卡、阅读计时入口和年度摘要等主流程区块。
struct ReadingDashboardView: View {
    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.scenePhase) private var scenePhase

    @State private var viewModel: ReadingDashboardViewModel?
    @State private var isYearSummaryPresented = false
    @State private var bootstrapLoadingGate = LoadingGate()

    let onAddBook: () -> Void
    let onOpenReadCalendar: (Date) -> Void
    let onOpenBookDetail: (Int64) -> Void
    let onStartReading: (Int64) -> Void
    let readingTimerZoomConfigurationFactory: ReadingTimerZoomConfigurationFactory?

    /// 注入首页对外回调，保证页面壳层不直接依赖具体导航实现。
    init(
        onAddBook: @escaping () -> Void = {},
        onOpenReadCalendar: @escaping (Date) -> Void = { _ in },
        onOpenBookDetail: @escaping (Int64) -> Void = { _ in },
        onStartReading: @escaping (Int64) -> Void = { _ in },
        readingTimerZoomConfigurationFactory: ReadingTimerZoomConfigurationFactory? = nil
    ) {
        self.onAddBook = onAddBook
        self.onOpenReadCalendar = onOpenReadCalendar
        self.onOpenBookDetail = onOpenBookDetail
        self.onStartReading = onStartReading
        self.readingTimerZoomConfigurationFactory = readingTimerZoomConfigurationFactory
    }

    var body: some View {
        ZStack {
            if let viewModel {
                ReadingDashboardContent(
                    viewModel: viewModel,
                    onAddBook: onAddBook,
                    onOpenReadCalendar: onOpenReadCalendar,
                    onOpenBookDetail: onOpenBookDetail,
                    onStartReading: onStartReading,
                    readingTimerZoomConfigurationFactory: readingTimerZoomConfigurationFactory,
                    isYearSummaryPresented: $isYearSummaryPresented
                )
            } else {
                Color.surfacePage.ignoresSafeArea()
                if bootstrapLoadingGate.isVisible {
                    LoadingStateView("正在准备在读首页…", style: .card)
                }
            }
        }
        .task {
            guard viewModel == nil else { return }
            bootstrapLoadingGate.update(intent: .read)
            let newViewModel = ReadingDashboardViewModel(repository: repositories.readingDashboardRepository)
            newViewModel.startObservationIfNeeded()
            viewModel = newViewModel
            bootstrapLoadingGate.update(intent: .none)
        }
        .onChange(of: scenePhase) { _, newValue in
            guard newValue == .active else { return }
            viewModel?.refreshIfNeeded()
        }
        .onDisappear {
            bootstrapLoadingGate.hideImmediately()
        }
    }
}

/// ReadingDashboardContent 承接首页滚动区的内容编排，隔离外层依赖注入与内部状态渲染。
private struct ReadingDashboardContent: View {
    @Bindable var viewModel: ReadingDashboardViewModel
    let onAddBook: () -> Void
    let onOpenReadCalendar: (Date) -> Void
    let onOpenBookDetail: (Int64) -> Void
    let onStartReading: (Int64) -> Void
    let readingTimerZoomConfigurationFactory: ReadingTimerZoomConfigurationFactory?
    @Binding var isYearSummaryPresented: Bool
    @State private var readLoadingGate = LoadingGate()

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.base) {
                ReadingHeatmapWidgetView(onOpenReadCalendar: onOpenReadCalendar)

                if let errorMessage = viewModel.errorMessage {
                    ReadingDashboardInlineBanner(
                        message: errorMessage,
                        actionTitle: "关闭",
                        onAction: { viewModel.errorMessage = nil }
                    )
                }

                ReadingTrendMetricsSection(metrics: viewModel.trendMetrics)

                ReadingFeatureCardsSection(
                    dailyGoal: viewModel.dailyGoal,
                    resumeBook: viewModel.resumeBook,
                    isLoading: readLoadingGate.isVisible,
                    onEditDailyGoal: { viewModel.presentDailyGoalEditor() },
                    onResumeTap: {
                        if let resumeBook = viewModel.resumeBook {
                            onStartReading(resumeBook.id)
                        } else {
                            onAddBook()
                        }
                    },
                    readingTimerZoomConfiguration: viewModel.resumeBook.flatMap { resumeBook in
                        readingTimerZoomConfigurationFactory?(
                            AnyHashable("reading-timer-resume-\(resumeBook.id)"),
                            .book(resumeBook.id)
                        )
                    }
                )

                ReadingRecentBooksCard(
                    books: viewModel.recentBooks,
                    isLoading: readLoadingGate.isVisible,
                    onBookTap: onOpenBookDetail
                )

                if let yearSummary = viewModel.yearSummary {
                    ReadingYearSummaryCard(
                        summary: yearSummary,
                        onOpenSummary: { isYearSummaryPresented = true },
                        onEditGoal: { viewModel.presentYearlyGoalEditor() },
                        onBookTap: onOpenBookDetail
                    )
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.top, Spacing.half)
            .padding(.bottom, Spacing.section)
        }
        .scrollIndicators(.hidden)
        .sheet(isPresented: $isYearSummaryPresented) {
            if let yearSummary = viewModel.yearSummary {
                ReadingYearSummarySheet(
                    summary: yearSummary,
                    onBookTap: onOpenBookDetail,
                    onEditGoal: { viewModel.presentYearlyGoalEditor() }
                )
            }
        }
        .sheet(item: Binding(
            get: { viewModel.goalEditorMode.map(ReadingGoalEditorSheet.Item.init(mode:)) },
            set: { item in
                if let item {
                    viewModel.goalEditorMode = item.mode
                } else {
                    viewModel.dismissGoalEditor()
                }
            }
        )) { item in
            ReadingGoalEditorSheet(
                item: item,
                value: $viewModel.draftGoalValue,
                isSaving: viewModel.isSavingGoal,
                onConfirm: {
                    Task { await viewModel.saveGoal() }
                },
                onCancel: { viewModel.dismissGoalEditor() }
            )
        }
        .onAppear {
            syncReadLoadingVisibility()
        }
        .onChange(of: viewModel.isLoading) { _, _ in
            syncReadLoadingVisibility()
        }
        .onDisappear {
            readLoadingGate.hideImmediately()
        }
    }

    private func syncReadLoadingVisibility() {
        readLoadingGate.update(intent: viewModel.isLoading ? .read : .none)
    }
}

#Preview {
    ReadingDashboardView()
        .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
}
