import SwiftUI

/**
 * [INPUT]: 依赖 RepositoryContainer 注入首页仓储，依赖 ReadingDashboardViewModel 驱动原子快照，依赖 ReadingDashboardLoadingShell 保持首轮读取几何，依赖外层回调打开书籍详情与阅读计时
 * [OUTPUT]: 对外提供 ReadingDashboardView（在读首页稳定加载与真实内容容器）
 * [POS]: Reading 模块首页入口，在统一壳层内衔接热力图、趋势卡、目标卡、最近在读与年度摘要
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
/// ReadingDashboardView 是在读首页真实内容页，负责组装热力图、趋势卡、目标卡、阅读计时入口和年度摘要等主流程区块。
struct ReadingDashboardView: View {
    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    @State private var viewModel: ReadingDashboardViewModel?
    @State private var isYearSummaryPresented = false
    @State private var readLoadingGate = LoadingGate()

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
        Group {
            if let viewModel, let snapshot = viewModel.snapshot {
                ReadingDashboardContent(
                    viewModel: viewModel,
                    snapshot: snapshot,
                    onAddBook: onAddBook,
                    onOpenReadCalendar: onOpenReadCalendar,
                    onOpenBookDetail: onOpenBookDetail,
                    onStartReading: onStartReading,
                    readingTimerZoomConfigurationFactory: readingTimerZoomConfigurationFactory,
                    isYearSummaryPresented: $isYearSummaryPresented
                )
                .transition(.opacity)
            } else {
                ReadingDashboardLoadingShell(
                    isLoadingIndicatorVisible: readLoadingGate.isVisible,
                    errorMessage: viewModel?.errorMessage,
                    onRetry: retryInitialLoad
                )
                .transition(.opacity)
            }
        }
        .animation(contentTransitionAnimation, value: isContentReady)
        .overlay {
            if isContentReady && readLoadingGate.isVisible {
                ReadingDashboardLoadingIndicator()
            }
        }
        .task {
            guard viewModel == nil else { return }
            readLoadingGate.update(intent: .read)
            let newViewModel = ReadingDashboardViewModel(repository: repositories.readingDashboardRepository)
            viewModel = newViewModel
            newViewModel.startObservationIfNeeded()
            syncReadLoadingVisibility()
        }
        .onChange(of: scenePhase) { _, newValue in
            guard newValue == .active else { return }
            viewModel?.refreshIfNeeded()
        }
        .onChange(of: viewModel?.isLoading) { _, _ in
            syncReadLoadingVisibility()
        }
        .onDisappear {
            readLoadingGate.hideImmediately()
        }
    }

    private var isContentReady: Bool {
        viewModel?.snapshot != nil
    }

    private var contentTransitionAnimation: Animation? {
        accessibilityReduceMotion ? nil : .easeOut(duration: 0.12)
    }

    /// 根据首页首轮 observation 状态驱动读取门闩；门闩只控制 overlay，不参与页面排版。
    private func syncReadLoadingVisibility() {
        readLoadingGate.update(intent: viewModel?.isLoading == true ? .read : .none)
    }

    /// 在加载壳层原位重建首页 observation，失败提示与重试过程均不改变结构高度。
    private func retryInitialLoad() {
        guard let viewModel else { return }
        readLoadingGate.update(intent: .read)
        viewModel.retryInitialLoad()
    }
}

/// ReadingDashboardContent 承接首页滚动区的内容编排，隔离外层依赖注入与内部状态渲染。
private struct ReadingDashboardContent: View {
    @Bindable var viewModel: ReadingDashboardViewModel
    let snapshot: ReadingDashboardSnapshot
    let onAddBook: () -> Void
    let onOpenReadCalendar: (Date) -> Void
    let onOpenBookDetail: (Int64) -> Void
    let onStartReading: (Int64) -> Void
    let readingTimerZoomConfigurationFactory: ReadingTimerZoomConfigurationFactory?
    @Binding var isYearSummaryPresented: Bool

    var body: some View {
        ReadingDashboardScrollContainer {
            ReadingHeatmapWidgetView(onOpenReadCalendar: onOpenReadCalendar)

            if let errorMessage = viewModel.errorMessage {
                ReadingDashboardInlineBanner(
                    message: errorMessage,
                    actionTitle: "关闭",
                    onAction: { viewModel.errorMessage = nil }
                )
            }

            ReadingTrendMetricsSection(metrics: snapshot.trends)

            ReadingFeatureCardsSection(
                dailyGoal: snapshot.dailyGoal,
                resumeBook: snapshot.resumeBook,
                onEditDailyGoal: { viewModel.presentDailyGoalEditor() },
                onResumeTap: {
                    if let resumeBook = snapshot.resumeBook {
                        onStartReading(resumeBook.id)
                    } else {
                        onAddBook()
                    }
                },
                readingTimerZoomConfiguration: snapshot.resumeBook.flatMap { resumeBook in
                    readingTimerZoomConfigurationFactory?(
                        AnyHashable("reading-timer-resume-\(resumeBook.id)"),
                        .book(resumeBook.id)
                    )
                }
            )

            ReadingRecentBooksCard(
                books: snapshot.recentBooks,
                onBookTap: onOpenBookDetail
            )

            ReadingYearSummaryCard(
                summary: snapshot.yearSummary,
                onOpenSummary: { isYearSummaryPresented = true },
                onEditGoal: { viewModel.presentYearlyGoalEditor() },
                onBookTap: onOpenBookDetail
            )
        }
        .sheet(isPresented: $isYearSummaryPresented) {
            ReadingYearSummarySheet(
                summary: snapshot.yearSummary,
                onBookTap: onOpenBookDetail,
                onEditGoal: { viewModel.presentYearlyGoalEditor() }
            )
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
                errorMessage: viewModel.goalEditorErrorMessage,
                onConfirm: {
                    Task { await viewModel.saveGoal() }
                },
                onCancel: { viewModel.dismissGoalEditor() }
            )
        }
    }
}

#Preview {
    ReadingDashboardView()
        .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
}
