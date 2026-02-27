import SwiftUI

/**
 * [INPUT]: 依赖 ReadingHeatmapWidgetViewModel 状态编排，依赖 RepositoryContainer 注入统计仓储，依赖 HeatmapChart 组件
 * [OUTPUT]: 对外提供 ReadingHeatmapWidgetView（在读页热力图小组件）
 * [POS]: 在读页顶部核心组件，承载热力图展示、帮助说明与日期点击回调
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct ReadingHeatmapWidgetView: View {
    private enum HeatmapWidgetLayout {
        static let cardCornerRadius: CGFloat = 18
        static let contentInset: CGFloat = 12
        static let infoVisualSize: CGFloat = 24
        static let infoHitSize: CGFloat = 32
        static let infoInset: CGFloat = 3
    }

    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.scenePhase) private var scenePhase

    @State private var viewModel = ReadingHeatmapWidgetViewModel()
    @State private var isHelpPresented = false
    @State private var helpSheetHeight: CGFloat = 300

    let onOpenReadCalendar: (Date) -> Void

    var body: some View {
        CardContainer(
            cornerRadius: HeatmapWidgetLayout.cardCornerRadius,
            showsBorder: false
        ) {
            ZStack(alignment: .topTrailing) {
                VStack(spacing: 0) {
                    HeatmapChart(
                        days: viewModel.days,
                        earliestDate: viewModel.earliestDate,
                        latestDate: viewModel.latestDate,
                        statisticsDataType: viewModel.statisticsDataType,
                        style: .readingCard
                    ) { day in
                        onOpenReadCalendar(day.id)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, HeatmapWidgetLayout.contentInset)
                    .padding(.vertical, HeatmapWidgetLayout.contentInset)

                    if let errorMessage = viewModel.errorMessage {
                        HStack(spacing: Spacing.half) {
                            Text(errorMessage)
                                .font(.caption)
                                .foregroundStyle(Color.feedbackWarning)
                                .lineLimit(1)

                            Spacer(minLength: 0)

                            Button("重试") {
                                Task {
                                    await viewModel.loadHeatmap(using: repositories.statisticsRepository)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(Color.brand)
                        }
                        .padding(.horizontal, HeatmapWidgetLayout.contentInset)
                        .padding(.bottom, HeatmapWidgetLayout.contentInset)
                    }
                }

                Button {
                    isHelpPresented = true
                } label: {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.textHint.opacity(0.82))
                        .frame(
                            width: HeatmapWidgetLayout.infoVisualSize,
                            height: HeatmapWidgetLayout.infoVisualSize
                        )
                }
                .buttonStyle(.plain)
                .frame(width: HeatmapWidgetLayout.infoHitSize, height: HeatmapWidgetLayout.infoHitSize)
                .contentShape(Rectangle())
                .padding(.top, HeatmapWidgetLayout.infoInset)
                .padding(.trailing, HeatmapWidgetLayout.infoInset)
                .accessibilityLabel("热力图说明")

                if viewModel.isLoading {
                    ProgressView()
                        .controlSize(.small)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
        }
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
    }
}
