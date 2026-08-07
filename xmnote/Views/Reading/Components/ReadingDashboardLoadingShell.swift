import SwiftUI

/**
 * [INPUT]: 依赖在读首页生产卡片的 pending 呈现、LoadingStateView 与首页设计令牌
 * [OUTPUT]: 对外提供首页滚动容器、语义结构壳层与紧凑加载指示，统一启动和首轮读取几何
 * [POS]: Reading/Components 的首页页面私有加载壳层，被 MainTabView 启动壳层与 ReadingDashboardView 共同复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// ReadingDashboardScrollContainer 统一首页生产态与加载态的滚动、区块间距和安全区留白。
struct ReadingDashboardScrollContainer<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(spacing: Spacing.base) {
                content
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.top, Spacing.half)
            .padding(.bottom, Spacing.section)
        }
        .scrollIndicators(.hidden)
    }
}

/// ReadingDashboardLoadingShell 使用生产卡片的待数据语义承载首轮读取，避免灰块骨架与业务区块位移。
struct ReadingDashboardLoadingShell: View {
    let isLoadingIndicatorVisible: Bool
    let errorMessage: String?
    let onRetry: () -> Void

    /// 创建首页结构壳层；默认用于运行环境尚未就绪且不显示加载提示的首个 App 自有画面。
    init(
        isLoadingIndicatorVisible: Bool = false,
        errorMessage: String? = nil,
        onRetry: @escaping () -> Void = {}
    ) {
        self.isLoadingIndicatorVisible = isLoadingIndicatorVisible
        self.errorMessage = errorMessage
        self.onRetry = onRetry
    }

    var body: some View {
        ReadingDashboardScrollContainer {
            semanticStructure
        }
        .overlay {
            if let errorMessage {
                failureOverlay(message: errorMessage)
            } else if isLoadingIndicatorVisible {
                ReadingDashboardLoadingIndicator()
            }
        }
    }

    private var semanticStructure: some View {
        Group {
            ReadingHeatmapWidgetCard(
                days: [:],
                earliestDate: nil,
                latestDate: nil,
                statisticsDataType: .all,
                errorMessage: nil,
                isLoadingIndicatorVisible: false,
                onOpenReadCalendar: { _ in },
                onOpenHelp: {},
                onRetry: {}
            )

            ReadingTrendMetricsSection(presentation: .pending)

            ReadingFeatureCardsSection(
                presentation: .pending,
                onEditDailyGoal: {},
                onResumeTap: {}
            )

            ReadingRecentBooksCard(
                presentation: .pending,
                onBookTap: { _ in }
            )

            ReadingYearSummaryCard(
                presentation: .pending,
                onOpenSummary: {},
                onEditGoal: {},
                onBookTap: { _ in }
            )
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .transaction { transaction in
            transaction.disablesAnimations = true
        }
    }

    private func failureOverlay(message: String) -> some View {
        ReadingDashboardInlineBanner(
            message: message,
            actionTitle: "重试",
            onAction: onRetry
        )
        .padding(.horizontal, Spacing.screenEdge)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .padding(.top, Spacing.section)
    }
}

/// ReadingDashboardLoadingIndicator 为超过读取阈值的首页提供单一紧凑反馈，不遮挡或参与卡片排版。
struct ReadingDashboardLoadingIndicator: View {
    var body: some View {
        LoadingStateView(style: .inline)
            .controlSize(.small)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
            .accessibilityLabel("正在加载在读首页")
    }
}
