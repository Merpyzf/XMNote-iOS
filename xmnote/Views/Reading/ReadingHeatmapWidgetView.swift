import SwiftUI

/**
 * [INPUT]: 依赖 ReadingHeatmapWidgetViewModel 状态编排，依赖 RepositoryContainer 注入统计仓储，依赖 HeatmapChart 与 LoadingStateView 组件
 * [OUTPUT]: 对外提供 ReadingHeatmapWidgetView、ReadingHeatmapWidgetCard 与共享布局常量
 * [POS]: 在读页顶部核心组件，统一生产态与首页加载壳层的热力图几何、帮助说明和日期点击回调
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
/// ReadingHeatmapWidgetLayout 统一生产热力图与首页加载壳层的外部几何，避免启动期维护近似高度。
enum ReadingHeatmapWidgetLayout {
    static let cardCornerRadius = CornerRadius.containerLarge
    static let contentInset: CGFloat = Spacing.base
    static let infoVisualSize: CGFloat = 24
    static let infoVisualSlotSize: CGFloat = 32
    static let infoHitSize: CGFloat = InteractionMetrics.minimumTouchTarget
    static let infoInset: CGFloat = 3
}

/// ReadingHeatmapWidgetCard 负责热力图卡的纯展示结构，让加载壳层与生产页面共享同一几何 owner。
struct ReadingHeatmapWidgetCard: View {
    let days: [Date: HeatmapDay]
    let earliestDate: Date?
    let latestDate: Date?
    let statisticsDataType: HeatmapStatisticsDataType
    let errorMessage: String?
    let isLoadingIndicatorVisible: Bool
    let onOpenReadCalendar: (Date) -> Void
    let onOpenHelp: () -> Void
    let onRetry: () -> Void

    var body: some View {
        CardContainer(
            cornerRadius: ReadingHeatmapWidgetLayout.cardCornerRadius,
            showsBorder: false
        ) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: Spacing.none) {
                    HeatmapChart(
                        days: days,
                        earliestDate: earliestDate,
                        latestDate: latestDate,
                        statisticsDataType: statisticsDataType,
                        style: .readingCard
                    ) { day in
                        onOpenReadCalendar(day.id)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, ReadingHeatmapWidgetLayout.contentInset)
                    .padding(.vertical, ReadingHeatmapWidgetLayout.contentInset)

                    if let errorMessage {
                        HStack(spacing: Spacing.half) {
                            Text(errorMessage)
                                .font(AppTypography.caption)
                                .foregroundStyle(Color.feedbackWarning)
                                .lineLimit(1)

                            Spacer(minLength: 0)

                            Button("重试", action: onRetry)
                                .font(AppTypography.caption)
                                .foregroundStyle(Color.appTint)
                        }
                        .padding(.horizontal, ReadingHeatmapWidgetLayout.contentInset)
                        .padding(.bottom, ReadingHeatmapWidgetLayout.contentInset)
                    }
                }

                Button(action: onOpenHelp) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.textHint.opacity(0.82))
                        .frame(
                            width: ReadingHeatmapWidgetLayout.infoVisualSize,
                            height: ReadingHeatmapWidgetLayout.infoVisualSize
                        )
                        .frame(
                            width: ReadingHeatmapWidgetLayout.infoVisualSlotSize,
                            height: ReadingHeatmapWidgetLayout.infoVisualSlotSize
                        )
                        .frame(
                            width: ReadingHeatmapWidgetLayout.infoHitSize,
                            height: ReadingHeatmapWidgetLayout.infoHitSize,
                            alignment: .topTrailing
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.top, ReadingHeatmapWidgetLayout.infoInset)
                .padding(.trailing, ReadingHeatmapWidgetLayout.infoInset)
                .accessibilityLabel("热力图说明")

                if isLoadingIndicatorVisible {
                    LoadingStateView(style: .inline)
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
        }
    }
}

/// ReadingHeatmapWidgetView 是在读首页顶部热力图卡，负责展示最近阅读活跃度并承接进入阅读日历的入口。
struct ReadingHeatmapWidgetView: View {

    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.scenePhase) private var scenePhase

    @State private var viewModel = ReadingHeatmapWidgetViewModel()
    @State private var isHelpPresented = false
    @State private var helpSheetHeight: CGFloat = 300
    @State private var readLoadingGate = LoadingGate()

    let onOpenReadCalendar: (Date) -> Void

    var body: some View {
        ReadingHeatmapWidgetCard(
            days: viewModel.days,
            earliestDate: viewModel.earliestDate,
            latestDate: viewModel.latestDate,
            statisticsDataType: viewModel.statisticsDataType,
            errorMessage: viewModel.errorMessage,
            isLoadingIndicatorVisible: viewModel.isLoading && readLoadingGate.isVisible,
            onOpenReadCalendar: onOpenReadCalendar,
            onOpenHelp: { isHelpPresented = true },
            onRetry: {
                Task {
                    await viewModel.loadHeatmap(using: repositories.statisticsRepository)
                }
            }
        )
        .task {
            await viewModel.loadHeatmap(using: repositories.statisticsRepository)
        }
        .onChange(of: scenePhase) { _, newValue in
            guard newValue == .active else { return }
            Task {
                await viewModel.refreshIfDayChanged(using: repositories.statisticsRepository)
            }
        }
        .sheet(isPresented: $isHelpPresented) {
            HeatmapHelpSheetView()
                .onPreferenceChange(SheetHeightKey.self) { helpSheetHeight = $0 }
                .presentationDetents([.height(helpSheetHeight)])
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
