import SwiftUI

/**
 * [INPUT]: 依赖 RepositoryContainer 注入首页仓储，依赖 ReadingDashboardViewModel 驱动首页状态，依赖 ReadingHeatmapWidgetView 复用热力图卡
 * [OUTPUT]: 对外提供 ReadingDashboardView（在读首页真实内容容器）
 * [POS]: Reading 模块首页入口，整合热力图、趋势卡、目标卡、继续阅读、最近在读与年度摘要
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct ReadingDashboardView: View {
    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.scenePhase) private var scenePhase

    @State private var viewModel: ReadingDashboardViewModel?
    @State private var isYearSummaryPresented = false

    let onAddBook: () -> Void
    let onOpenReadCalendar: (Date) -> Void
    let onOpenBookDetail: (Int64) -> Void

    init(
        onAddBook: @escaping () -> Void = {},
        onOpenReadCalendar: @escaping (Date) -> Void = { _ in },
        onOpenBookDetail: @escaping (Int64) -> Void = { _ in }
    ) {
        self.onAddBook = onAddBook
        self.onOpenReadCalendar = onOpenReadCalendar
        self.onOpenBookDetail = onOpenBookDetail
    }

    var body: some View {
        Group {
            if let viewModel {
                ReadingDashboardContent(
                    viewModel: viewModel,
                    onAddBook: onAddBook,
                    onOpenReadCalendar: onOpenReadCalendar,
                    onOpenBookDetail: onOpenBookDetail,
                    isYearSummaryPresented: $isYearSummaryPresented
                )
            } else {
                Color.clear
            }
        }
        .task {
            guard viewModel == nil else { return }
            let newViewModel = ReadingDashboardViewModel(repository: repositories.readingDashboardRepository)
            newViewModel.startObservationIfNeeded()
            viewModel = newViewModel
        }
        .onChange(of: scenePhase) { _, newValue in
            guard newValue == .active else { return }
            viewModel?.refreshIfNeeded()
        }
    }
}

private struct ReadingDashboardContent: View {
    @Bindable var viewModel: ReadingDashboardViewModel
    let onAddBook: () -> Void
    let onOpenReadCalendar: (Date) -> Void
    let onOpenBookDetail: (Int64) -> Void
    @Binding var isYearSummaryPresented: Bool

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
                    isLoading: viewModel.isLoading,
                    onEditDailyGoal: { viewModel.presentDailyGoalEditor() },
                    onResumeTap: {
                        if let resumeBook = viewModel.resumeBook {
                            onOpenBookDetail(resumeBook.id)
                        } else {
                            onAddBook()
                        }
                    }
                )

                ReadingRecentBooksCard(
                    books: viewModel.recentBooks,
                    isLoading: viewModel.isLoading,
                    onBookTap: onOpenBookDetail
                )

                if let yearSummary = viewModel.yearSummary {
                    ReadingYearSummaryCard(
                        summary: yearSummary,
                        onTap: { isYearSummaryPresented = true }
                    )
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.top, Spacing.half)
            .padding(.bottom, Spacing.section)
        }
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
    }
}

#Preview {
    ReadingDashboardView()
        .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
}
