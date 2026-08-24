import SwiftUI

/**
 * [INPUT]: 依赖 ReadingDashboardSnapshot 相关领域模型、XMBookCover、CardContainer、HorizontalPagingHost 与 DesignTokens 提供首页卡片渲染能力
 * [OUTPUT]: 对外提供支持 pending/content 语义呈现的首页趋势、功能、最近在读与年度总结页面私有卡片
 * [POS]: Reading/Components 页面私有子视图集合，负责在读首页各卡片区块的展示
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
/// ReadingDashboardPresentation 区分尚无业务数据的结构壳层与已取得真实值的生产内容。
enum ReadingDashboardPresentation<Value> {
    case pending
    case content(Value)

    var isPending: Bool {
        if case .pending = self {
            return true
        }
        return false
    }
}

/// ReadingRecentBooksCardLayout 统一最近在读卡片的标题节奏、书架间距与单本书展示尺寸。
private enum ReadingRecentBooksCardLayout {
    static let titleFontSize: CGFloat = 15
    static let contentSpacing: CGFloat = Spacing.tight
    static let itemSpacing: CGFloat = Spacing.comfortable
    static let coverWidth: CGFloat = 76
    static let coverToTextSpacing: CGFloat = Spacing.cozy
    static let textGroupSpacing: CGFloat = Spacing.compact
    static let textHorizontalInset: CGFloat = Spacing.micro
    static let bookTitleFontSize: CGFloat = 13
    static let progressFontSize: CGFloat = 10
}

/// ReadingTrendMetricsSection 把三项趋势指标收口为单张卡片，并统一处理分栏与分割线布局。
struct ReadingTrendMetricsSection: View {
    let presentation: ReadingDashboardPresentation<[ReadingTrendMetric]>

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 使用真实趋势数据创建生产卡片。
    init(metrics: [ReadingTrendMetric]) {
        presentation = .content(metrics)
    }

    /// 创建指定呈现阶段的趋势卡；pending 阶段只保留栏目和图表轨道。
    init(presentation: ReadingDashboardPresentation<[ReadingTrendMetric]>) {
        self.presentation = presentation
    }

    private var items: [ReadingTrendOverviewItem] {
        switch presentation {
        case .pending:
            return [
                .pending(id: "reading-duration", title: "阅读时长"),
                .pending(id: "note-count", title: "书摘数量"),
                .pending(id: "read-done-count", title: "已读书籍")
            ]
        case .content(let metrics):
            return metrics.map(ReadingTrendOverviewItem.content)
        }
    }

    var body: some View {
        if !items.isEmpty {
            CardContainer(cornerRadius: CornerRadius.blockLarge, showsBorder: false) {
                GeometryReader { proxy in
                    let layout = ReadingTrendOverviewLayout(
                        containerSize: proxy.size,
                        columnCount: items.count
                    )
                    HStack(spacing: Spacing.none) {
                        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                            switch item {
                            case .pending(_, let title):
                                ReadingTrendPendingColumn(title: title, layout: layout)
                            case .content(let metric):
                                ReadingTrendOverviewColumn(metric: metric, layout: layout)
                            }

                            if index != items.index(before: items.endIndex) {
                                Rectangle()
                                    .fill(Color.surfaceBorderStrong.opacity(0.78))
                                    .frame(width: CardStyle.borderWidth)
                                    .padding(.vertical, layout.dividerVerticalInset)
                            }
                        }
                    }
                }
            }
            .aspectRatio(
                ReadingTrendOverviewLayout.columnAspectRatio * CGFloat(items.count),
                contentMode: .fit
            )
            .frame(minHeight: dynamicTypeSize.xmUsesExpandedTextLayout ? 142 : nil)
        }
    }
}

/// ReadingTrendOverviewItem 为同一趋势卡布局提供真实指标或无伪值的待数据栏目。
private enum ReadingTrendOverviewItem: Identifiable {
    case pending(id: String, title: String)
    case content(ReadingTrendMetric)

    var id: String {
        switch self {
        case .pending(let id, _):
            return "pending-\(id)"
        case .content(let metric):
            return "content-\(metric.kind.rawValue)"
        }
    }
}

/// ReadingTrendOverviewLayout 统一管理三栏总卡的比例布局，避免视图内部散落魔法数字。
private struct ReadingTrendOverviewLayout {
    static let columnAspectRatio: CGFloat = 1.06

    let containerSize: CGSize
    let columnCount: Int

    var columnWidth: CGFloat {
        containerSize.width / CGFloat(max(1, columnCount))
    }

    var columnHeight: CGFloat { containerSize.height }

    var verticalPadding: CGFloat { Spacing.base }

    var dividerVerticalInset: CGFloat { verticalPadding }

    var horizontalPadding: CGFloat { Spacing.screenEdge }

    var chartHeight: CGFloat { columnHeight * 0.32 }

    var metricTitleSpacing: CGFloat { max(0, min(0.5, columnHeight * 0.003)) }

    var headerToChartMinSpacing: CGFloat { Spacing.cozy }

    var numberFontSize: CGFloat { min(30, max(20, columnHeight * 0.20)) }

    var unitFontSize: CGFloat { max(8, numberFontSize / 3) }

    var descriptionFontSize: CGFloat { min(12, max(10, columnHeight * 0.082)) }

    var chartSpacing: CGFloat { Spacing.cozy }
}

/// ReadingDashboardTypography 统一首页卡片副标题层的字重语义，避免各卡片独立漂移。
private enum ReadingDashboardTypography {
    static let subtitleWeight: Font.Weight = .regular
}

/// ReadingTrendMetricTypography 管理趋势总卡数值位的紧凑语义字体，避免误用正文最小字号下限。
private enum ReadingTrendMetricTypography {
    static func compactUnitFont(baseSize: CGFloat) -> Font {
        AppTypography.fixed(
            baseSize: baseSize,
            relativeTo: .caption2,
            weight: .medium,
            design: .rounded,
            minimumPointSize: baseSize
        )
    }
}

/// ReadingTrendOverviewColumn 渲染单个趋势栏位，承载主值、描述与最近窗口柱图。
private struct ReadingTrendOverviewColumn: View {
    let metric: ReadingTrendMetric
    let layout: ReadingTrendOverviewLayout

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.none) {
            VStack(alignment: .leading, spacing: layout.metricTitleSpacing) {
                ReadingTrendMetricValueLabel(
                    display: ReadingDashboardFormatting.metricValueDisplay(metric: metric),
                    numberFontSize: layout.numberFontSize,
                    unitFontSize: layout.unitFontSize
                )

                Text(metric.title)
                    .font(
                        AppTypography.fixed(
                            baseSize: layout.descriptionFontSize,
                            relativeTo: .caption,
                            weight: ReadingDashboardTypography.subtitleWeight,
                            design: .rounded,
                            minimumPointSize: layout.descriptionFontSize
                        )
                    )
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(dynamicTypeSize.xmUsesExpandedTextLayout ? 2 : 1)
            }

            Spacer(minLength: layout.headerToChartMinSpacing)

            ReadingTrendMiniBarChart(
                points: metric.points,
                chartHeight: layout.chartHeight,
                spacing: layout.chartSpacing
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.vertical, layout.verticalPadding)
    }
}

/// ReadingTrendPendingColumn 保留真实趋势栏的文字与图表几何，只用破折号表达数值尚未就绪。
private struct ReadingTrendPendingColumn: View {
    let title: String
    let layout: ReadingTrendOverviewLayout

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.none) {
            VStack(alignment: .leading, spacing: layout.metricTitleSpacing) {
                Text("—")
                    .font(AppTypography.brandDisplay(size: layout.numberFontSize, relativeTo: .title3))
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)

                Text(title)
                    .font(
                        AppTypography.fixed(
                            baseSize: layout.descriptionFontSize,
                            relativeTo: .caption,
                            weight: ReadingDashboardTypography.subtitleWeight,
                            design: .rounded,
                            minimumPointSize: layout.descriptionFontSize
                        )
                    )
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(dynamicTypeSize.xmUsesExpandedTextLayout ? 2 : 1)
            }

            Spacer(minLength: layout.headerToChartMinSpacing)

            ReadingTrendMiniBarChart(
                points: nil,
                chartHeight: layout.chartHeight,
                spacing: layout.chartSpacing
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(.horizontal, layout.horizontalPadding)
        .padding(.vertical, layout.verticalPadding)
    }
}

/// ReadingTrendMetricValueLabel 负责按品牌数字 / 系统单位的组合样式渲染趋势总值。
private struct ReadingTrendMetricValueLabel: View {
    let display: ReadingDashboardMetricValueDisplay
    let numberFontSize: CGFloat
    let unitFontSize: CGFloat

    var body: some View {
        let pairs = display.pairs
        Group {
            if pairs.isEmpty {
                EmptyView()
            } else if dynamicTypeSize.xmUsesExpandedTextLayout && pairs.count > 1 {
                VStack(alignment: .leading, spacing: Spacing.hairline) {
                    ForEach(Array(pairs.enumerated()), id: \.offset) { _, pair in
                        ReadingTrendMetricPairLine(
                            pair: pair,
                            numberFontSize: numberFontSize,
                            unitFontSize: unitFontSize
                        )
                    }
                }
            } else {
                combinedLineText(for: pairs)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.68)
                    .contentTransition(.numericText())
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private func combinedLineText(for pairs: [ReadingDashboardMetricValueDisplay.Pair]) -> Text {
        pairs.enumerated().reduce(Text("")) { partial, item in
            let spacingText = item.offset == 0 ? Text("") : Text(" ")
            return partial + spacingText + pairText(item.element)
        }
    }

    private func pairText(_ pair: ReadingDashboardMetricValueDisplay.Pair) -> Text {
        let numberText = Text(pair.number.text)
            .font(AppTypography.brandDisplay(size: numberFontSize, relativeTo: .title3))
            .monospacedDigit()
        let unitText = Text(pair.unit.text)
            .font(ReadingTrendMetricTypography.compactUnitFont(baseSize: unitFontSize))
        return numberText + unitText
    }
}

/// ReadingTrendMetricPairLine 负责渲染单个“数字 + 单位”组合，供 AX1 下多行值块复用。
private struct ReadingTrendMetricPairLine: View {
    let pair: ReadingDashboardMetricValueDisplay.Pair
    let numberFontSize: CGFloat
    let unitFontSize: CGFloat

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.none) {
            Text(pair.number.text)
                .font(AppTypography.brandDisplay(size: numberFontSize, relativeTo: .title3))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .monospacedDigit()
                .contentTransition(.numericText())
            Text(pair.unit.text)
                .font(
                    ReadingTrendMetricTypography.compactUnitFont(baseSize: unitFontSize)
                )
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
        }
    }
}

/// ReadingTrendMiniBarChart 渲染趋势栏位底部柱图，保留 Android 的零值占位语义。
private struct ReadingTrendMiniBarChart: View {
    private enum AxisStyle {
        static let lineWidth: CGFloat = 1
        static let dashPattern: [CGFloat] = [3, 3]
        static let horizontalInset: CGFloat = Spacing.micro
        static let color: Color = Color.textHint.opacity(0.24)
    }

    let points: [ReadingTrendMetric.Point]?
    let chartHeight: CGFloat
    let spacing: CGFloat

    private var displayedRatios: [CGFloat] {
        guard let points else {
            return Array(repeating: 0, count: 7)
        }
        return ReadingDashboardFormatting.displayedBarRatios(points: points, chartHeight: chartHeight)
    }

    private var verticalBarShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            cornerRadii: .init(
                topLeading: CornerRadius.inlaySmall,
                bottomLeading: CornerRadius.none,
                bottomTrailing: CornerRadius.none,
                topTrailing: CornerRadius.inlaySmall
            ),
            style: .continuous
        )
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: spacing) {
            ForEach(Array(displayedRatios.enumerated()), id: \.offset) { index, ratio in
                ZStack(alignment: .bottom) {
                    verticalBarShape
                        .fill(Color.chartBarTrack)

                    if ratio > 0 {
                        verticalBarShape
                            .fill(Color.brand)
                            .frame(height: chartHeight * ratio)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: chartHeight, alignment: .bottom)
                .accessibilityLabel(points?[index].label ?? "")
                .accessibilityValue(points?[index].value == 0 ? "0" : "\(points?[index].value ?? 0)")
                .accessibilityHidden(points == nil)
            }
        }
        .frame(height: chartHeight)
        .overlay(alignment: .bottom) {
            ReadingTrendMiniXAxis()
                .stroke(
                    AxisStyle.color,
                    style: StrokeStyle(
                        lineWidth: AxisStyle.lineWidth,
                        lineCap: .round,
                        lineJoin: .round,
                        dash: AxisStyle.dashPattern
                    )
                )
                .frame(height: AxisStyle.lineWidth)
                .padding(.horizontal, AxisStyle.horizontalInset)
        }
        .animation(.smooth(duration: 0.45), value: displayedRatios)
    }
}

/// ReadingTrendMiniXAxis 仅负责底部水平轴线，让趋势柱图的基线更易感知。
private struct ReadingTrendMiniXAxis: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let y = rect.midY
        path.move(to: CGPoint(x: rect.minX, y: y))
        path.addLine(to: CGPoint(x: rect.maxX, y: y))
        return path
    }
}

/// ReadingFeatureCardsSection 在标准字号并排展示两张功能卡，并在辅助功能字号切换为纵向可读布局。
struct ReadingFeatureCardsSection: View {
    let presentation: ReadingDashboardPresentation<ReadingFeatureCardsContent>
    let onEditDailyGoal: () -> Void
    let onResumeTap: () -> Void
    let readingTimerZoomConfiguration: ReadingTimerZoomSourceConfiguration?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    /// 使用真实目标与续读书籍创建生产功能卡组。
    init(
        dailyGoal: ReadingDailyGoal,
        resumeBook: ReadingResumeBook?,
        onEditDailyGoal: @escaping () -> Void,
        onResumeTap: @escaping () -> Void,
        readingTimerZoomConfiguration: ReadingTimerZoomSourceConfiguration? = nil
    ) {
        presentation = .content(
            ReadingFeatureCardsContent(
                dailyGoal: dailyGoal,
                resumeBook: resumeBook
            )
        )
        self.onEditDailyGoal = onEditDailyGoal
        self.onResumeTap = onResumeTap
        self.readingTimerZoomConfiguration = readingTimerZoomConfiguration
    }

    /// 创建指定呈现阶段的功能卡组；pending 阶段不构造目标或书籍伪值。
    init(
        presentation: ReadingDashboardPresentation<ReadingFeatureCardsContent>,
        onEditDailyGoal: @escaping () -> Void,
        onResumeTap: @escaping () -> Void,
        readingTimerZoomConfiguration: ReadingTimerZoomSourceConfiguration? = nil
    ) {
        self.presentation = presentation
        self.onEditDailyGoal = onEditDailyGoal
        self.onResumeTap = onResumeTap
        self.readingTimerZoomConfiguration = readingTimerZoomConfiguration
    }

    private var featureCardsLayout: AnyLayout {
        if dynamicTypeSize.xmUsesExpandedTextLayout {
            AnyLayout(VStackLayout(spacing: Spacing.base))
        } else {
            AnyLayout(HStackLayout(spacing: Spacing.base))
        }
    }

    var body: some View {
        featureCardsLayout {
            featureCardFrame {
                ReadingDailyGoalCard(
                    presentation: dailyGoalPresentation,
                    onTap: onEditDailyGoal
                )
            }

            featureCardFrame {
                ReadingResumeBookCard(
                    presentation: resumeBookPresentation,
                    onTap: onResumeTap,
                    readingTimerZoomConfiguration: readingTimerZoomConfiguration
                )
            }
        }
    }

    private var dailyGoalPresentation: ReadingDashboardPresentation<ReadingDailyGoal> {
        switch presentation {
        case .pending:
            return .pending
        case .content(let content):
            return .content(content.dailyGoal)
        }
    }

    private var resumeBookPresentation: ReadingDashboardPresentation<ReadingResumeBook?> {
        switch presentation {
        case .pending:
            return .pending
        case .content(let content):
            return .content(content.resumeBook)
        }
    }

    /// 在标准字号保持双列比例，在辅助功能字号为两张功能卡提供一致的纵向可读高度。
    @ViewBuilder
    private func featureCardFrame<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        if dynamicTypeSize.xmUsesExpandedTextLayout {
            content()
                .frame(maxWidth: .infinity)
                .frame(height: ReadingFeatureCardsStyle.expandedCardHeight)
        } else {
            content()
                .frame(maxWidth: .infinity)
                .aspectRatio(ReadingFeatureCardsStyle.cardAspectRatio, contentMode: .fit)
        }
    }
}

/// ReadingFeatureCardsContent 承载功能卡生产态所需的目标与续读书籍真值。
struct ReadingFeatureCardsContent {
    let dailyGoal: ReadingDailyGoal
    let resumeBook: ReadingResumeBook?
}

/// ReadingFeatureCardsStyle 统一收口双功能卡共享的标准比例、辅助功能高度与内边距语义。
private enum ReadingFeatureCardsStyle {
    static let cardAspectRatio: CGFloat = 0.88
    static let expandedCardHeight: CGFloat = 236
    static let contentInset: CGFloat = Spacing.base
}

/// ReadingFeatureCardHeaderMetrics 固定双功能卡顶部两行的字号与节奏，保证相邻卡片视觉对齐。
private enum ReadingFeatureCardHeaderMetrics {
    static let titleFontSize: CGFloat = 14
    static let subtitleFontSize: CGFloat = 12
    static let subtitleFontWeight: Font.Weight = ReadingDashboardTypography.subtitleWeight
    static let titleSubtitleSpacing: CGFloat = Spacing.compact
    static let headerToBodySpacing: CGFloat = Spacing.tight
}

/// ReadingDailyGoalCardLayout 约束今日阅读卡的标题、弧环与中心主值，避免横纵向同时超配。
private struct ReadingDailyGoalCardLayout {
    static let arcSweepDegrees: CGFloat = 270
    static let arcStartAngle: Angle = .degrees(135)

    let cardSize: CGSize

    var cardWidth: CGFloat { max(1, cardSize.width) }

    var cardHeight: CGFloat { max(1, cardSize.height) }

    var contentInset: CGFloat { ReadingFeatureCardsStyle.contentInset }

    var contentWidth: CGFloat { max(1, cardWidth - contentInset * 2) }

    var contentHeight: CGFloat { max(1, cardHeight - contentInset * 2) }

    var headerSpacing: CGFloat { ReadingFeatureCardHeaderMetrics.titleSubtitleSpacing }

    var headerToGaugeSpacing: CGFloat { ReadingFeatureCardHeaderMetrics.headerToBodySpacing }

    var statusFontSize: CGFloat { ReadingFeatureCardHeaderMetrics.titleFontSize }

    var subtitleFontSize: CGFloat { ReadingFeatureCardHeaderMetrics.subtitleFontSize }

    private var headerGroupHeight: CGFloat {
        statusFontSize * 1.16 + subtitleFontSize * 1.10 + headerSpacing
    }

    var gaugeAvailableHeight: CGFloat { max(1, contentHeight - headerGroupHeight - headerToGaugeSpacing) }

    var gaugeSquareSide: CGFloat { min(contentWidth, gaugeAvailableHeight) }

    var arcLineWidth: CGFloat { min(9, max(6.5, gaugeSquareSide * 0.066)) }

    var valueMaxWidth: CGFloat { cardWidth * 0.40 }

    var valueFontSize: CGFloat { min(30, max(26, cardWidth * 0.168)) }

    var valueVerticalOffset: CGFloat { -Spacing.tiny }

    var targetFontSize: CGFloat { 11 }

    var targetMaxWidth: CGFloat { gaugeSquareSide * 0.62 }

    var targetCenterYOffset: CGFloat { gaugeSquareSide * 0.40 }

}

/// ReadingResumeBookCardLayout 统一继续阅读卡的标题节奏与封面剩余空间填充策略，保证与今日阅读卡并排时的对齐感。
private struct ReadingResumeBookCardLayout {
    let cardSize: CGSize

    var cardWidth: CGFloat { max(1, cardSize.width) }

    var contentInset: CGFloat { ReadingFeatureCardsStyle.contentInset }

    var headerSpacing: CGFloat { ReadingFeatureCardHeaderMetrics.titleSubtitleSpacing }

    var headerToCoverSpacing: CGFloat { ReadingFeatureCardHeaderMetrics.headerToBodySpacing }

    var titleFontSize: CGFloat { ReadingFeatureCardHeaderMetrics.titleFontSize }

    var subtitleFontSize: CGFloat { ReadingFeatureCardHeaderMetrics.subtitleFontSize }

    var coverHorizontalInset: CGFloat { contentInset + 6 }

    var emptyTextSpacing: CGFloat { Spacing.compact }

    var emptyActionTopSpacing: CGFloat { Spacing.tight }

    var emptyActionIconSize: CGFloat { subtitleFontSize }

    var emptySymbolSize: CGFloat { cardWidth * 0.54 }

    var emptySymbolTrailingOffset: CGFloat { Spacing.tight }

    var emptySymbolBottomInset: CGFloat { Spacing.base }
}

/// ReadingDailyGoalCard 承接今日阅读目标的标题、状态和弧环进度，提供目标编辑入口。
private struct ReadingDailyGoalCard: View {
    let presentation: ReadingDashboardPresentation<ReadingDailyGoal>
    let onTap: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var statusTitle: String {
        guard case .content(let goal) = presentation else {
            return "目标未达成"
        }
        return goal.progress >= 1 ? "目标已达成" : "目标未达成"
    }

    var body: some View {
        Button(action: onTap) {
            CardContainer(cornerRadius: CornerRadius.containerMedium, showsBorder: false) {
                GeometryReader { proxy in
                    let layout = ReadingDailyGoalCardLayout(cardSize: proxy.size)
                    ZStack(alignment: .topTrailing) {
                        VStack(spacing: layout.headerToGaugeSpacing) {
                            VStack(spacing: layout.headerSpacing) {
                                Text(statusTitle)
                                    .font(
                                        AppTypography.fixed(
                                            baseSize: layout.statusFontSize,
                                            relativeTo: .subheadline,
                                            weight: .semibold,
                                            design: .rounded,
                                            minimumPointSize: layout.statusFontSize
                                        )
                                    )
                                    .foregroundStyle(Color.textPrimary)
                                    .lineLimit(dynamicTypeSize.xmUsesExpandedTextLayout ? 2 : 1)
                                    .minimumScaleFactor(0.9)
                                    .multilineTextAlignment(.center)
                                    .opacity(presentation.isPending ? 0 : 1)

                                Text("今日阅读")
                                    .font(
                                        AppTypography.fixed(
                                            baseSize: layout.subtitleFontSize,
                                            relativeTo: .caption,
                                            weight: ReadingFeatureCardHeaderMetrics.subtitleFontWeight,
                                            design: .rounded,
                                            minimumPointSize: layout.subtitleFontSize
                                        )
                                    )
                                    .foregroundStyle(Color.textSecondary)
                                    .lineLimit(1)
                            }
                            .frame(maxWidth: .infinity)

                            ReadingDailyGoalArcGauge(presentation: presentation, layout: layout)
                                .frame(maxWidth: .infinity, maxHeight: layout.gaugeAvailableHeight, alignment: .top)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(layout.contentInset)

                    }
                }
            }
        }
        .buttonStyle(.plain)
        .disabled(presentation.isPending)
    }
}

/// ReadingDailyGoalArcGauge 渲染底部缺口的今日阅读进度弧环。
private struct ReadingDailyGoalArcGauge: View {
    let presentation: ReadingDashboardPresentation<ReadingDailyGoal>
    let layout: ReadingDailyGoalCardLayout

    private var progress: CGFloat {
        guard case .content(let goal) = presentation else { return 0 }
        return CGFloat(min(1, max(0, goal.progress)))
    }

    private var targetText: String {
        guard case .content(let goal) = presentation else { return "目标 60 分钟" }
        return "目标 \(max(1, goal.targetSeconds / 60)) 分钟"
    }

    private var valueText: String {
        guard case .content(let goal) = presentation else { return "00:00" }
        return ReadingDashboardFormatting.dailyGoalValueText(seconds: goal.readSeconds)
    }

    var body: some View {
        ZStack {
            ReadingDailyGoalArcShape(progress: 1)
                .stroke(
                    Color.surfaceBorderSubtle,
                    style: StrokeStyle(
                        lineWidth: layout.arcLineWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )

            ReadingDailyGoalArcShape(progress: progress)
                .stroke(
                    Color.brand,
                    style: StrokeStyle(
                        lineWidth: layout.arcLineWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .animation(.smooth(duration: 0.45), value: progress)

            Text(valueText)
                .font(AppTypography.brandDisplay(size: layout.valueFontSize, relativeTo: .title2))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: layout.valueMaxWidth)
                .contentTransition(.numericText())
                .offset(y: layout.valueVerticalOffset)
                .opacity(presentation.isPending ? 0 : 1)
        }
        .frame(width: layout.gaugeSquareSide, height: layout.gaugeSquareSide)
        .overlay {
            Text(targetText)
                .font(
                    AppTypography.fixed(
                        baseSize: layout.targetFontSize,
                        relativeTo: .footnote,
                        design: .rounded,
                        minimumPointSize: layout.targetFontSize
                    )
                )
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.9)
                .frame(maxWidth: layout.targetMaxWidth)
                .offset(y: layout.targetCenterYOffset)
                .opacity(presentation.isPending ? 0 : 1)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("今日阅读")
        .accessibilityValue(accessibilityValue)
        .accessibilityHidden(presentation.isPending)
    }

    private var accessibilityValue: String {
        guard case .content(let goal) = presentation else { return "" }
        return "\(ReadingDashboardFormatting.clockText(seconds: goal.readSeconds))，\(targetText)"
    }
}

/// ReadingDailyGoalArcShape 提供固定底部缺口的弧环 path，供轨道和进度共用。
private struct ReadingDailyGoalArcShape: Shape {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    /// 按正方形画布生成 270 度弧环路径，保证轨道与进度条共享同一几何基准。
    func path(in rect: CGRect) -> Path {
        let clampedProgress = min(1, max(0, progress))
        guard clampedProgress > 0, rect.width > 0, rect.height > 0 else { return Path() }
        let radius = min(rect.width, rect.height) / 2

        let endAngle = Angle.degrees(
            ReadingDailyGoalCardLayout.arcStartAngle.degrees
                + Double(ReadingDailyGoalCardLayout.arcSweepDegrees * clampedProgress)
        )

        var path = Path()
        path.addArc(
            center: CGPoint(x: rect.midX, y: rect.midY),
            radius: radius,
            startAngle: ReadingDailyGoalCardLayout.arcStartAngle,
            endAngle: endAngle,
            clockwise: false
        )
        return path
    }
}

/// ReadingResumeBookCard 展示最近可继续阅读的书籍与进度，缺省时回退到添加书籍引导。
private struct ReadingResumeBookCard: View {
    let presentation: ReadingDashboardPresentation<ReadingResumeBook?>
    let onTap: () -> Void
    let readingTimerZoomConfiguration: ReadingTimerZoomSourceConfiguration?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    private var contentTransitionAnimation: Animation {
        accessibilityReduceMotion
            ? .easeOut(duration: 0.10)
            : .smooth(duration: 0.20)
    }

    private var book: ReadingResumeBook? {
        guard case .content(let book) = presentation else { return nil }
        return book
    }

    var body: some View {
        Group {
            if let book, let readingTimerZoomConfiguration {
                ReadingTimerNormalZoomSource(configuration: readingTimerZoomConfiguration) { open in
                    Button(action: open) {
                        cardContent(book: book)
                    }
                    .buttonStyle(.plain)
                }
            } else {
                Button(action: onTap) {
                    cardContent(book: book)
                }
                .buttonStyle(.plain)
            }
        }
        .disabled(presentation.isPending)
        .accessibilityLabel("继续阅读，先添加一本书", isEnabled: book == nil)
        .accessibilityHint("打开添加书籍页面", isEnabled: book == nil)
    }

    /// 复用快照驱动的稳定卡片几何；计时器缩放入口与普通按钮仅替换外层交互壳。
    @ViewBuilder
    private func cardContent(book: ReadingResumeBook?) -> some View {
        CardContainer(cornerRadius: CornerRadius.containerMedium, showsBorder: false) {
            GeometryReader { proxy in
                let layout = ReadingResumeBookCardLayout(cardSize: proxy.size)
                ZStack(alignment: .topTrailing) {
                    Group {
                        if presentation.isPending {
                            pendingResumeContent(layout: layout)
                        } else if let book {
                            resumeBookContent(book: book, layout: layout)
                                .transition(.opacity)
                        } else {
                            emptyResumeContent(layout: layout)
                                .transition(.opacity)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                    .animation(contentTransitionAnimation, value: book?.id)
                }
            }
        }
    }

    /// 生成继续阅读状态副标题；有进度时恢复百分比与动作语义，缺省时仅保留继续阅读提示。
    private func resumeSubtitle(for book: ReadingResumeBook) -> String {
        guard let progressPercent = book.progressPercent else { return "继续阅读" }
        return "\(ReadingDashboardFormatting.percentText(progressPercent)) | 继续阅读"
    }

    private var resumeCoverCornerRadii: RectangleCornerRadii {
        .init(
            topLeading: CornerRadius.inlayHairline,
            bottomLeading: CornerRadius.none,
            bottomTrailing: CornerRadius.none,
            topTrailing: CornerRadius.inlayHairline
        )
    }

    /// 只保留继续阅读栏目与业务剪影，其他空态行动文案透明占位以维持生产几何。
    @ViewBuilder
    private func pendingResumeContent(layout: ReadingResumeBookCardLayout) -> some View {
        VStack(alignment: .leading, spacing: Spacing.none) {
            VStack(alignment: .leading, spacing: layout.emptyTextSpacing) {
                Text("继续阅读")
                    .font(
                        AppTypography.fixed(
                            baseSize: layout.subtitleFontSize,
                            relativeTo: .caption,
                            weight: ReadingFeatureCardHeaderMetrics.subtitleFontWeight,
                            design: .rounded,
                            minimumPointSize: layout.subtitleFontSize
                        )
                    )
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)

                Text("先添加一本书")
                    .font(
                        AppTypography.fixed(
                            baseSize: layout.titleFontSize,
                            relativeTo: .subheadline,
                            weight: .semibold,
                            design: .rounded,
                            minimumPointSize: layout.titleFontSize
                        )
                    )
                    .lineLimit(dynamicTypeSize.xmUsesExpandedTextLayout ? 2 : 1)
                    .opacity(0)

                Text("去添加")
                    .font(
                        AppTypography.fixed(
                            baseSize: layout.subtitleFontSize,
                            relativeTo: .caption,
                            weight: ReadingFeatureCardHeaderMetrics.subtitleFontWeight,
                            design: .rounded,
                            minimumPointSize: layout.subtitleFontSize
                        )
                    )
                    .padding(.top, layout.emptyActionTopSpacing)
                    .opacity(0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, layout.contentInset)
            .padding(.horizontal, layout.contentInset)
            .layoutPriority(1)

            if !dynamicTypeSize.xmUsesExpandedTextLayout {
                Image(systemName: "books.vertical.fill")
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Color.textPrimary.opacity(0.08))
                    .frame(width: layout.emptySymbolSize, height: layout.emptySymbolSize)
                    .offset(x: layout.emptySymbolTrailingOffset)
                    .padding(.bottom, layout.emptySymbolBottomInset)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .bottomTrailing
                    )
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 以与今日阅读一致的标题区节奏承载当前书名和继续阅读状态。
    @ViewBuilder
    private func resumeBookContent(book: ReadingResumeBook, layout: ReadingResumeBookCardLayout) -> some View {
        VStack(spacing: layout.headerToCoverSpacing) {
            resumeHeader(
                title: book.name,
                subtitle: resumeSubtitle(for: book),
                layout: layout,
                titleLineLimit: 1
            )
            .padding(.top, layout.contentInset)
            .padding(.horizontal, layout.contentInset)

            GeometryReader { proxy in
                let coverViewportSize = proxy.size
                let coverViewportWidth = max(1, coverViewportSize.width)
                let coverViewportHeight = max(1, coverViewportSize.height)
                let coverRenderWidth = max(
                    coverViewportWidth,
                    XMBookCover.width(forHeight: coverViewportHeight)
                )

                XMBookCover.fixedWidth(
                    coverRenderWidth,
                    urlString: book.coverURL,
                    cornerRadius: CornerRadius.inlayHairline,
                    cornerRadii: resumeCoverCornerRadii,
                    border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                    surfaceStyle: .spine
                )
                .accessibilityHidden(true)
                .frame(
                    width: coverViewportWidth,
                    height: coverViewportHeight,
                    alignment: .top
                )
                .clipped()
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
            .padding(.horizontal, layout.coverHorizontalInset)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// 以左对齐行动文案和右下系统书籍剪影承接无在读书籍状态，并让两者使用独立布局空间。
    @ViewBuilder
    private func emptyResumeContent(layout: ReadingResumeBookCardLayout) -> some View {
        VStack(alignment: .leading, spacing: Spacing.none) {
            VStack(alignment: .leading, spacing: layout.emptyTextSpacing) {
                Text("继续阅读")
                    .font(
                        AppTypography.fixed(
                            baseSize: layout.subtitleFontSize,
                            relativeTo: .caption,
                            weight: ReadingFeatureCardHeaderMetrics.subtitleFontWeight,
                            design: .rounded,
                            minimumPointSize: layout.subtitleFontSize
                        )
                    )
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(dynamicTypeSize.xmUsesExpandedTextLayout ? 1 : 0.9)

                Text("先添加一本书")
                    .font(
                        AppTypography.fixed(
                            baseSize: layout.titleFontSize,
                            relativeTo: .subheadline,
                            weight: .semibold,
                            design: .rounded,
                            minimumPointSize: layout.titleFontSize
                        )
                    )
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(dynamicTypeSize.xmUsesExpandedTextLayout ? 2 : 1)
                    .minimumScaleFactor(dynamicTypeSize.xmUsesExpandedTextLayout ? 1 : 0.9)
                    .multilineTextAlignment(.leading)

                HStack(spacing: layout.emptyTextSpacing) {
                    Text("去添加")
                        .font(
                            AppTypography.fixed(
                                baseSize: layout.subtitleFontSize,
                                relativeTo: .caption,
                                weight: ReadingFeatureCardHeaderMetrics.subtitleFontWeight,
                                design: .rounded,
                                minimumPointSize: layout.subtitleFontSize
                            )
                        )
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(dynamicTypeSize.xmUsesExpandedTextLayout ? 1 : 0.9)

                    Image(systemName: "chevron.right")
                        .font(
                            AppTypography.fixed(
                                baseSize: layout.emptyActionIconSize,
                                relativeTo: .caption,
                                weight: .semibold,
                                minimumPointSize: layout.emptyActionIconSize
                            )
                        )
                        .foregroundStyle(Color.brand)
                        .accessibilityHidden(true)
                }
                .padding(.top, layout.emptyActionTopSpacing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, layout.contentInset)
            .padding(.horizontal, layout.contentInset)
            .layoutPriority(1)

            if !dynamicTypeSize.xmUsesExpandedTextLayout {
                Image(systemName: "books.vertical.fill")
                    .resizable()
                    .scaledToFit()
                    .symbolRenderingMode(.monochrome)
                    .foregroundStyle(Color.textPrimary.opacity(0.08))
                    .frame(
                        width: layout.emptySymbolSize,
                        height: layout.emptySymbolSize
                    )
                    .offset(x: layout.emptySymbolTrailingOffset)
                    .padding(.bottom, layout.emptySymbolBottomInset)
                    .frame(
                        maxWidth: .infinity,
                        maxHeight: .infinity,
                        alignment: .bottomTrailing
                    )
                    .accessibilityHidden(true)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// 统一继续阅读卡顶部两行文案排版，使其和今日阅读卡形成一组稳定的双列头部节奏。
    @ViewBuilder
    private func resumeHeader(
        title: String,
        subtitle: String,
        layout: ReadingResumeBookCardLayout,
        titleLineLimit: Int
        ) -> some View {
        VStack(spacing: layout.headerSpacing) {
            Text(title)
                .font(
                    AppTypography.fixed(
                        baseSize: layout.titleFontSize,
                        relativeTo: .subheadline,
                        weight: .semibold,
                        design: .rounded,
                        minimumPointSize: layout.titleFontSize
                    )
                )
                .foregroundStyle(Color.textPrimary)
                .lineLimit(dynamicTypeSize.xmUsesExpandedTextLayout ? 2 : titleLineLimit)
                .minimumScaleFactor(0.9)
                .multilineTextAlignment(.center)
                .truncationMode(.tail)

            Text(subtitle)
                .font(
                    AppTypography.fixed(
                        baseSize: layout.subtitleFontSize,
                        relativeTo: .caption,
                        weight: ReadingFeatureCardHeaderMetrics.subtitleFontWeight,
                        design: .rounded,
                        minimumPointSize: layout.subtitleFontSize
                    )
                )
                .foregroundStyle(Color.textSecondary)
                .lineLimit(dynamicTypeSize.xmUsesExpandedTextLayout ? 2 : 1)
                .minimumScaleFactor(0.9)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
    }
}

/// ReadingRecentBooksCard 负责横向展示最近活跃书籍列表，承接从首页快速进入书籍详情的入口。
struct ReadingRecentBooksCard: View {
    let presentation: ReadingDashboardPresentation<[ReadingRecentBook]>
    let onBookTap: (Int64) -> Void

    /// 使用真实书籍创建生产态最近在读卡片。
    init(books: [ReadingRecentBook], onBookTap: @escaping (Int64) -> Void) {
        presentation = .content(books)
        self.onBookTap = onBookTap
    }

    /// 创建指定呈现阶段的最近在读卡片；pending 阶段不展示真实空态文案。
    init(
        presentation: ReadingDashboardPresentation<[ReadingRecentBook]>,
        onBookTap: @escaping (Int64) -> Void
    ) {
        self.presentation = presentation
        self.onBookTap = onBookTap
    }

    var body: some View {
        CardContainer(cornerRadius: CornerRadius.containerMedium, showsBorder: false) {
            VStack(alignment: .leading, spacing: ReadingRecentBooksCardLayout.contentSpacing) {
                Text("最近在读")
                    .font(
                        AppTypography.fixed(
                            baseSize: ReadingRecentBooksCardLayout.titleFontSize,
                            relativeTo: .headline,
                            weight: .semibold,
                            design: .rounded,
                            minimumPointSize: ReadingRecentBooksCardLayout.titleFontSize
                        )
                    )
                    .foregroundStyle(Color.textPrimary)

                switch presentation {
                case .pending:
                    Image(systemName: "books.vertical")
                        .font(AppTypography.title2)
                        .foregroundStyle(Color.textHint)
                        .frame(maxWidth: .infinity)
                        .frame(height: 160)
                        .accessibilityHidden(true)
                case .content(let books):
                    if books.isEmpty {
                        XMCompactStateView(
                            role: .empty,
                            title: "最近没有在读记录",
                            systemImage: "books.vertical"
                        )
                            .frame(height: 160)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(alignment: .top, spacing: ReadingRecentBooksCardLayout.itemSpacing) {
                                ForEach(books) { book in
                                    ReadingRecentBookItemView(book: book, onTap: onBookTap)
                                }
                            }
                        }
                    }
                }
            }
            .padding(Spacing.base)
        }
    }
}

/// ReadingRecentBookItemView 渲染最近在读书架中的单本书，保持封面主导、书名次之、进度最轻的层级。
private struct ReadingRecentBookItemView: View {
    let book: ReadingRecentBook
    let onTap: (Int64) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var progressRatio: Double? {
        guard let progressPercent = book.progressPercent else { return nil }
        let clampedPercent = min(100, max(0, progressPercent))
        return clampedPercent / 100
    }

    var body: some View {
        Button {
            onTap(book.id)
        } label: {
            VStack(alignment: .leading, spacing: ReadingRecentBooksCardLayout.coverToTextSpacing) {
                XMBookCover.fixedWidth(
                    ReadingRecentBooksCardLayout.coverWidth,
                    urlString: book.coverURL,
                    cornerRadius: CornerRadius.inlayHairline,
                    border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                    surfaceStyle: .spine
                )
                .overlay {
                    if let progressRatio {
                        BookCoverProgressBar(progress: progressRatio)
                    }
                }
                .shadow(
                    color: Color.bookCoverDropShadow.opacity(0.38),
                    radius: 1.4,
                    x: 0,
                    y: 0.9
                )
                .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: ReadingRecentBooksCardLayout.textGroupSpacing) {
                    Text(book.name)
                        .font(
                            AppTypography.fixed(
                                baseSize: ReadingRecentBooksCardLayout.bookTitleFontSize,
                                relativeTo: .footnote,
                                weight: .medium,
                                design: .rounded,
                                minimumPointSize: ReadingRecentBooksCardLayout.bookTitleFontSize
                            )
                        )
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(dynamicTypeSize.xmUsesExpandedTextLayout ? 2 : 1)
                        .minimumScaleFactor(0.92)

                    Text(ReadingDashboardFormatting.percentText(book.progressPercent))
                        .font(
                            AppTypography.fixed(
                                baseSize: ReadingRecentBooksCardLayout.progressFontSize,
                                relativeTo: .caption2,
                                weight: ReadingDashboardTypography.subtitleWeight,
                                design: .rounded,
                                minimumPointSize: ReadingRecentBooksCardLayout.progressFontSize
                            )
                        )
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.92)
                        .monospacedDigit()
                }
                .padding(.horizontal, ReadingRecentBooksCardLayout.textHorizontalInset)
            }
            .frame(width: ReadingRecentBooksCardLayout.coverWidth, alignment: .leading)
        }
        .buttonStyle(.plain)
    }
}

/// ReadingYearSummaryCardLayout 收口年度摘要卡的标题、状态说明与目标书架节奏。
private enum ReadingYearSummaryCardLayout {
    static let contentInset: CGFloat = Spacing.base
    static let titleToSubtitleSpacing: CGFloat = Spacing.compact
    static let subtitleToGridSpacing: CGFloat = Spacing.contentEdge
    static let pagerToIndicatorSpacing: CGFloat = Spacing.cozy
    static let headerTrailingSpacing: CGFloat = Spacing.base
    static let gridSpacing: CGFloat = Spacing.base
    static let gridColumnCount = 4
    static let gridRowCount = 3
    static let slotsPerPage = gridColumnCount * gridRowCount
    static let geometryUpdateThreshold: CGFloat = 0.5
    static let minimumPagerDimension: CGFloat = 1
    static let actionHitSize: CGFloat = Spacing.actionReserved
    static let actionVisualSize: CGFloat = Spacing.double
    static let pageIndicatorActiveWidth: CGFloat = Spacing.comfortable
    static let pageIndicatorMarkerSize: CGFloat = Spacing.half
    static let pageIndicatorMarkerSpacing: CGFloat = Spacing.compact
    static let pageIndicatorConnectorMaxHalfHeight: CGFloat = Spacing.hairline

    static let titleFontSize: CGFloat = 15
    static let countFontSize: CGFloat = 30
    static let countVerticalTrim = AppTypography.brandTrim(size: countFontSize, textStyle: .title2)
    static let subtitleFontSize: CGFloat = 12
    static let subtitleNumberFontSize: CGFloat = 16
    static let subtitleNumberVerticalTrim = AppTypography.brandTrim(size: subtitleNumberFontSize, textStyle: .body)
    static let subtitleInlineSpacing: CGFloat = Spacing.compact
    static let placeholderNumberFontSize: CGFloat = 28
    static let placeholderNumberHorizontalInset: CGFloat = Spacing.cozy
}

/// ReadingYearSummaryGoalSlot 统一年度目标卡中真实已读书与未完成占位槽位的渲染输入。
private enum ReadingYearSummaryGoalSlot: Identifiable {
    case book(ReadingYearReadBook)
    case placeholder(Int)

    var id: String {
        switch self {
        case let .book(book):
            return "book-\(book.id)"
        case let .placeholder(index):
            return "placeholder-\(index)"
        }
    }
}

/// ReadingYearSummaryPagerSlot 区分年度目标内容与仅用于稳定页面高度的不可见槽位。
private enum ReadingYearSummaryPagerSlot: Identifiable {
    case goal(ReadingYearSummaryGoalSlot)
    case pending(position: Int)
    case layoutSpacer(pageID: Int, position: Int)

    var id: String {
        switch self {
        case let .goal(slot):
            return slot.id
        case let .pending(position):
            return "pending-\(position)"
        case let .layoutSpacer(pageID, position):
            return "layout-spacer-\(pageID)-\(position)"
        }
    }
}

/// ReadingYearSummaryPagerPage 固定承载单页 4×3 槽位，保证尾页和首页面积一致。
private struct ReadingYearSummaryPagerPage: Identifiable {
    let id: Int
    let slots: [ReadingYearSummaryPagerSlot]
}

/// ReadingYearSummaryCard 展示年度阅读目标完成情况、目标书架和操作入口。
struct ReadingYearSummaryCard: View {
    let presentation: ReadingDashboardPresentation<ReadingYearSummary>
    let onOpenSummary: () -> Void
    let onEditGoal: () -> Void
    let onBookTap: (Int64) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedPage: Int? = 0
    @State private var pagerWidth: CGFloat = 0

    /// 使用真实年度摘要创建生产卡片。
    init(
        summary: ReadingYearSummary,
        onOpenSummary: @escaping () -> Void,
        onEditGoal: @escaping () -> Void,
        onBookTap: @escaping (Int64) -> Void
    ) {
        presentation = .content(summary)
        self.onOpenSummary = onOpenSummary
        self.onEditGoal = onEditGoal
        self.onBookTap = onBookTap
    }

    /// 创建指定呈现阶段的年度卡片；pending 阶段使用透明布局槽位稳定书架高度。
    init(
        presentation: ReadingDashboardPresentation<ReadingYearSummary>,
        onOpenSummary: @escaping () -> Void,
        onEditGoal: @escaping () -> Void,
        onBookTap: @escaping (Int64) -> Void
    ) {
        self.presentation = presentation
        self.onOpenSummary = onOpenSummary
        self.onEditGoal = onEditGoal
        self.onBookTap = onBookTap
    }

    private var summary: ReadingYearSummary? {
        guard case .content(let summary) = presentation else { return nil }
        return summary
    }

    private var goalSlots: [ReadingYearSummaryGoalSlot] {
        guard let summary else { return [] }
        var slots = summary.books.map(ReadingYearSummaryGoalSlot.book)
        guard summary.readCount < summary.targetCount else { return slots }

        slots.append(
            contentsOf: (summary.readCount + 1...summary.targetCount).map(ReadingYearSummaryGoalSlot.placeholder)
        )
        return slots
    }

    private var pages: [ReadingYearSummaryPagerPage] {
        if presentation.isPending {
            return [
                ReadingYearSummaryPagerPage(
                    id: 0,
                    slots: (0..<ReadingYearSummaryCardLayout.slotsPerPage).map(
                        ReadingYearSummaryPagerSlot.pending
                    )
                )
            ]
        }

        let slots = goalSlots
        let pageCount = max(
            1,
            Int(ceil(Double(slots.count) / Double(ReadingYearSummaryCardLayout.slotsPerPage)))
        )

        return (0..<pageCount).map { pageID in
            let lowerBound = pageID * ReadingYearSummaryCardLayout.slotsPerPage
            let upperBound = min(
                lowerBound + ReadingYearSummaryCardLayout.slotsPerPage,
                slots.count
            )
            var pageSlots = slots[lowerBound..<upperBound].map(ReadingYearSummaryPagerSlot.goal)

            if pageSlots.count < ReadingYearSummaryCardLayout.slotsPerPage {
                pageSlots.append(
                    contentsOf: (pageSlots.count..<ReadingYearSummaryCardLayout.slotsPerPage).map { position in
                        ReadingYearSummaryPagerSlot.layoutSpacer(pageID: pageID, position: position)
                    }
                )
            }

            return ReadingYearSummaryPagerPage(id: pageID, slots: pageSlots)
        }
    }

    private var pageIDs: [Int] {
        pages.map(\.id)
    }

    private var pagerHeight: CGFloat {
        guard pagerWidth > 0 else {
            return ReadingYearSummaryCardLayout.minimumPagerDimension
        }

        let horizontalSpacing = ReadingYearSummaryCardLayout.gridSpacing
            * CGFloat(ReadingYearSummaryCardLayout.gridColumnCount - 1)
        let itemWidth = max(
            ReadingYearSummaryCardLayout.minimumPagerDimension,
            (pagerWidth - horizontalSpacing) / CGFloat(ReadingYearSummaryCardLayout.gridColumnCount)
        )
        let itemHeight = XMBookCover.height(forWidth: itemWidth)
        let verticalSpacing = ReadingYearSummaryCardLayout.gridSpacing
            * CGFloat(ReadingYearSummaryCardLayout.gridRowCount - 1)
        return itemHeight * CGFloat(ReadingYearSummaryCardLayout.gridRowCount) + verticalSpacing
    }

    var body: some View {
        CardContainer(cornerRadius: CornerRadius.containerMedium, showsBorder: false) {
            VStack(alignment: .leading, spacing: ReadingYearSummaryCardLayout.subtitleToGridSpacing) {
                headerSection

                ReadingYearSummaryPagerSection(
                    pages: pages,
                    selectedPage: $selectedPage,
                    pagerHeight: pagerHeight,
                    onBookTap: onBookTap
                )
                .onGeometryChange(for: CGFloat.self) { geometry in
                    geometry.size.width
                } action: { width in
                    updatePagerWidth(width)
                }
            }
            .padding(ReadingYearSummaryCardLayout.contentInset)
        }
        .onChange(of: pageIDs, initial: true) { _, newPageIDs in
            normalizeSelectedPage(in: newPageIDs)
        }
    }

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: ReadingYearSummaryCardLayout.titleToSubtitleSpacing) {
            titleContent
                .layoutPriority(1)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(yearSummaryAccessibilityLabel)
                .padding(
                    .trailing,
                    ReadingYearSummaryCardLayout.actionHitSize
                        + ReadingYearSummaryCardLayout.headerTrailingSpacing
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .trailing) {
                    Button(action: onOpenSummary) {
                        Image(systemName: "chevron.right")
                            .font(AppTypography.footnoteSemibold)
                            .foregroundStyle(Color.textHint)
                            .frame(
                                width: ReadingYearSummaryCardLayout.actionVisualSize,
                                height: ReadingYearSummaryCardLayout.actionVisualSize
                            )
                            .frame(
                                width: ReadingYearSummaryCardLayout.actionHitSize,
                                height: ReadingYearSummaryCardLayout.actionHitSize
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(presentation.isPending)
                    .opacity(presentation.isPending ? 0 : 1)
                    .accessibilityLabel("查看年度已读列表")
                }

            HStack(
                alignment: dynamicTypeSize.xmUsesExpandedTextLayout ? .top : .center,
                spacing: ReadingYearSummaryCardLayout.subtitleInlineSpacing
            ) {
                statusContent
                    .layoutPriority(1)

                Button(action: onEditGoal) {
                    Image(systemName: "pencil.line")
                        .font(
                            AppTypography.fixed(
                                baseSize: ReadingYearSummaryCardLayout.subtitleFontSize,
                                relativeTo: .caption,
                                minimumPointSize: ReadingYearSummaryCardLayout.subtitleFontSize
                            )
                        )
                        .foregroundStyle(Color.textSecondary)
                        .frame(
                            width: ReadingYearSummaryCardLayout.actionVisualSize,
                            height: ReadingYearSummaryCardLayout.actionVisualSize
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(presentation.isPending)
                .opacity(presentation.isPending ? 0 : 1)
                .accessibilityLabel("编辑年度阅读目标")
            }
        }
    }

    @ViewBuilder
    private var titleContent: some View {
        if dynamicTypeSize.xmUsesExpandedTextLayout {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                yearTitleText
                HStack(alignment: .firstTextBaseline, spacing: Spacing.half) {
                    readCountText
                    bookCountUnitText
                }
            }
        } else {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.half) {
                yearTitleText
                readCountText
                bookCountUnitText
            }
        }
    }

    private var yearTitleText: some View {
        Text("今年已读")
            .font(
                AppTypography.fixed(
                    baseSize: ReadingYearSummaryCardLayout.titleFontSize,
                    relativeTo: .subheadline,
                    weight: .semibold,
                    design: .rounded,
                    minimumPointSize: ReadingYearSummaryCardLayout.titleFontSize
                )
            )
            .foregroundStyle(Color.textPrimary)
    }

    private var readCountText: some View {
        Text(summary.map { "\($0.readCount)" } ?? "—")
            .font(AppTypography.brandDisplay(size: ReadingYearSummaryCardLayout.countFontSize, relativeTo: .title2))
            .foregroundStyle(presentation.isPending ? Color.textSecondary : Color.brand)
            .minimumScaleFactor(0.72)
            .lineLimit(1)
            .brandVerticalTrim(
                ReadingYearSummaryCardLayout.countVerticalTrim,
                edges: [.top, .bottom]
            )
    }

    private var bookCountUnitText: some View {
        Text("本")
            .font(
                AppTypography.fixed(
                    baseSize: ReadingYearSummaryCardLayout.titleFontSize,
                    relativeTo: .subheadline,
                    weight: .semibold,
                    design: .rounded,
                    minimumPointSize: ReadingYearSummaryCardLayout.titleFontSize
                )
            )
            .foregroundStyle(Color.textPrimary)
    }

    @ViewBuilder
    private var statusContent: some View {
        if let summary, summary.isTargetAchieved || dynamicTypeSize.xmUsesExpandedTextLayout {
            Text(ReadingDashboardFormatting.yearSummarySubtitle(summary: summary))
                .font(
                    AppTypography.fixed(
                        baseSize: ReadingYearSummaryCardLayout.subtitleFontSize,
                        relativeTo: .caption,
                        weight: ReadingDashboardTypography.subtitleWeight,
                        design: .rounded,
                        minimumPointSize: ReadingYearSummaryCardLayout.subtitleFontSize
                    )
                )
                .foregroundStyle(Color.textSecondary)
                .lineLimit(dynamicTypeSize.xmUsesExpandedTextLayout ? nil : 1)
                .fixedSize(horizontal: false, vertical: dynamicTypeSize.xmUsesExpandedTextLayout)
        } else if let summary {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.none) {
                Text("再读 ")
                    .font(
                        AppTypography.fixed(
                            baseSize: ReadingYearSummaryCardLayout.subtitleFontSize,
                            relativeTo: .caption,
                            weight: ReadingDashboardTypography.subtitleWeight,
                            design: .rounded,
                            minimumPointSize: ReadingYearSummaryCardLayout.subtitleFontSize
                        )
                    )
                    .foregroundStyle(Color.textSecondary)

                Text("\(summary.remainingCount)")
                    .font(AppTypography.brandDisplay(
                        size: ReadingYearSummaryCardLayout.subtitleNumberFontSize,
                        relativeTo: .body
                    ))
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.88)
                    .brandVerticalTrim(
                        ReadingYearSummaryCardLayout.subtitleNumberVerticalTrim,
                        edges: [.top, .bottom]
                    )

                Text(" 本，即可完成今年目标")
                    .font(
                        AppTypography.fixed(
                            baseSize: ReadingYearSummaryCardLayout.subtitleFontSize,
                            relativeTo: .caption,
                            weight: ReadingDashboardTypography.subtitleWeight,
                            design: .rounded,
                            minimumPointSize: ReadingYearSummaryCardLayout.subtitleFontSize
                        )
                    )
                    .foregroundStyle(Color.textSecondary)
            }
            .lineLimit(dynamicTypeSize.xmUsesExpandedTextLayout ? 2 : 1)
            .minimumScaleFactor(0.92)
        } else {
            Text("年度阅读目标")
                .font(
                    AppTypography.fixed(
                        baseSize: ReadingYearSummaryCardLayout.subtitleFontSize,
                        relativeTo: .caption,
                        weight: ReadingDashboardTypography.subtitleWeight,
                        design: .rounded,
                        minimumPointSize: ReadingYearSummaryCardLayout.subtitleFontSize
                    )
                )
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
        }
    }

    private var yearSummaryAccessibilityLabel: String {
        guard let summary else { return "年度阅读数据尚未就绪" }
        return "今年已读 \(summary.readCount) 本"
    }

    /// 根据分页容器的真实宽度更新高度计算输入，并过滤亚像素级重复回写。
    private func updatePagerWidth(_ width: CGFloat) {
        let normalizedWidth = max(0, width)
        guard abs(normalizedWidth - pagerWidth) > ReadingYearSummaryCardLayout.geometryUpdateThreshold else {
            return
        }
        pagerWidth = normalizedWidth
    }

    /// 当目标槽位页数变化时把当前页收敛到有效范围，避免数据刷新后停留在失效页面。
    private func normalizeSelectedPage(in pageIDs: [Int]) {
        guard let firstPage = pageIDs.first, let lastPage = pageIDs.last else {
            if selectedPage != nil {
                selectedPage = nil
            }
            return
        }

        let currentPage = selectedPage ?? firstPage
        let normalizedPage = min(max(currentPage, firstPage), lastPage)
        if selectedPage != normalizedPage {
            selectedPage = normalizedPage
        }
    }
}

/// ReadingYearSummaryPagerSection 局部持有高频连续页进度，避免拖动期间把重绘扩散到整张年度摘要卡。
private struct ReadingYearSummaryPagerSection: View {
    let pages: [ReadingYearSummaryPagerPage]
    @Binding var selectedPage: Int?
    let pagerHeight: CGFloat
    let onBookTap: (Int64) -> Void

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var continuousPage: CGFloat = 0

    private var pageIDs: [Int] {
        pages.map(\.id)
    }

    private var showsPageIndicator: Bool {
        pageIDs.count > 1
    }

    private var pageIndicatorVisibilityAnimation: Animation {
        accessibilityReduceMotion
            ? .easeOut(duration: 0.10)
            : .smooth(duration: 0.20)
    }

    var body: some View {
        VStack(spacing: ReadingYearSummaryCardLayout.pagerToIndicatorSpacing) {
            ReadingYearSummaryPager(
                pages: pages,
                selectedPage: $selectedPage,
                onPageProgressChange: updateContinuousPage,
                onBookTap: onBookTap
            )
            .frame(maxWidth: .infinity)
            .frame(height: pagerHeight)

            if showsPageIndicator {
                ReadingYearSummaryPageIndicator(
                    pageIDs: pageIDs,
                    selectedPage: $selectedPage,
                    continuousPage: continuousPage
                )
                .transition(.opacity)
            }
        }
        .animation(pageIndicatorVisibilityAnimation, value: showsPageIndicator)
        .onChange(of: pageIDs, initial: true) { _, _ in
            normalizeContinuousPage()
        }
    }

    /// 接收分页宿主的连续逻辑页进度，以无动画事务逐帧驱动 Gooey 几何。
    private func updateContinuousPage(_ progress: CGFloat?) {
        let normalizedProgress = normalizedContinuousPage(progress)
        guard continuousPage != normalizedProgress else { return }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            continuousPage = normalizedProgress
        }
    }

    /// 页数变化时把高频视觉进度收敛到新范围，避免旧页位置残留。
    private func normalizeContinuousPage() {
        updateContinuousPage(continuousPage)
    }

    private func normalizedContinuousPage(_ progress: CGFloat?) -> CGFloat {
        guard !pageIDs.isEmpty else { return 0 }

        let selectedIndex = selectedPage
            .flatMap { pageIDs.firstIndex(of: $0) }
            .map(CGFloat.init)
            ?? 0
        let candidate = progress.flatMap { $0.isFinite ? $0 : nil } ?? selectedIndex
        return min(CGFloat(pageIDs.count - 1), max(0, candidate))
    }
}

/// ReadingYearSummaryPager 用现有横向分页宿主承载年度目标页，并输出拖动过程中的连续逻辑页进度。
private struct ReadingYearSummaryPager: View {
    let pages: [ReadingYearSummaryPagerPage]
    @Binding var selectedPage: Int?
    let onPageProgressChange: @MainActor @Sendable (CGFloat?) -> Void
    let onBookTap: (Int64) -> Void

    var body: some View {
        HorizontalPagingHost(
            ids: pages.map(\.id),
            selection: $selectedPage,
            showsIndicators: false,
            pageAlignment: .top,
            onPageProgressChange: onPageProgressChange
        ) { pageID in
            if let page = pages.first(where: { $0.id == pageID }) {
                ReadingYearSummaryPageGrid(slots: page.slots, onBookTap: onBookTap)
            } else {
                Color.clear
                    .accessibilityHidden(true)
            }
        }
    }
}

/// ReadingYearSummaryPageIndicator 以连续 Gooey 形变提示年度书架横向进度，并支持 VoiceOver 调整页码。
private struct ReadingYearSummaryPageIndicator: View {
    let pageIDs: [Int]
    @Binding var selectedPage: Int?
    let continuousPage: CGFloat

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @Environment(\.layoutDirection) private var layoutDirection

    private var currentPageIndex: Int {
        guard
            let selectedPage,
            let selectedIndex = pageIDs.firstIndex(of: selectedPage)
        else {
            return 0
        }
        return selectedIndex
    }

    private var displayedPageIndex: Int {
        guard !pageIDs.isEmpty else { return 0 }
        let roundedPage = Int(normalizedContinuousPage.rounded())
        return min(pageIDs.count - 1, max(0, roundedPage))
    }

    private var normalizedContinuousPage: CGFloat {
        guard !pageIDs.isEmpty, continuousPage.isFinite else { return 0 }
        return min(CGFloat(pageIDs.count - 1), max(0, continuousPage))
    }

    private var indicatorWidth: CGFloat {
        guard !pageIDs.isEmpty else { return 0 }
        return ReadingYearSummaryCardLayout.pageIndicatorActiveWidth
            + CGFloat(pageIDs.count - 1)
                * (
                    ReadingYearSummaryCardLayout.pageIndicatorMarkerSize
                        + ReadingYearSummaryCardLayout.pageIndicatorMarkerSpacing
                )
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            markerRow
            compactPageDescription
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("年度书架分页")
        .accessibilityValue("第 \(currentPageIndex + 1) 页，共 \(pageIDs.count) 页")
        .accessibilityAdjustableAction { direction in
            adjustPage(direction)
        }
    }

    private var markerRow: some View {
        let drawing = ReadingYearSummaryGooeyIndicatorDrawing(
            pageCount: pageIDs.count,
            continuousPage: normalizedContinuousPage,
            isRightToLeft: layoutDirection == .rightToLeft,
            drawsConnector: !accessibilityReduceMotion,
            activeWidth: ReadingYearSummaryCardLayout.pageIndicatorActiveWidth,
            markerSize: ReadingYearSummaryCardLayout.pageIndicatorMarkerSize,
            markerSpacing: ReadingYearSummaryCardLayout.pageIndicatorMarkerSpacing,
            connectorMaxHalfHeight: ReadingYearSummaryCardLayout.pageIndicatorConnectorMaxHalfHeight
        )
        let activeColor = Color.brand
        let inactiveColor = Color.controlFillSecondary

        return Canvas { [drawing, activeColor, inactiveColor] context, size in
            drawing.draw(
                context: &context,
                size: size,
                activeColor: activeColor,
                inactiveColor: inactiveColor
            )
        }
        .frame(
            width: indicatorWidth,
            height: ReadingYearSummaryCardLayout.pageIndicatorMarkerSize
        )
        .accessibilityHidden(true)
    }

    private var compactPageDescription: some View {
        Label(
            "\(displayedPageIndex + 1)/\(pageIDs.count)",
            systemImage: "arrow.left.and.right"
        )
        .font(AppTypography.caption2Medium)
        .foregroundStyle(Color.textHint)
        .accessibilityHidden(true)
    }

    /// 响应 VoiceOver 增减手势并把页码限制在当前有效范围内。
    private func adjustPage(_ direction: AccessibilityAdjustmentDirection) {
        guard !pageIDs.isEmpty else { return }

        let targetIndex: Int
        switch direction {
        case .increment:
            targetIndex = min(currentPageIndex + 1, pageIDs.count - 1)
        case .decrement:
            targetIndex = max(currentPageIndex - 1, 0)
        @unknown default:
            return
        }

        let targetPage = pageIDs[targetIndex]
        guard selectedPage != targetPage else { return }
        selectedPage = targetPage
    }
}

/// ReadingYearSummaryGooeyIndicatorDrawing 把连续页进度转换为活动瓣、普通页点与相邻 Bézier 连接颈。
private struct ReadingYearSummaryGooeyIndicatorDrawing: Sendable {
    private struct Lobe: Sendable {
        let centerX: CGFloat
        let halfWidth: CGFloat
        let halfHeight: CGFloat
    }

    let pageCount: Int
    let continuousPage: CGFloat
    let isRightToLeft: Bool
    let drawsConnector: Bool
    let activeWidth: CGFloat
    let markerSize: CGFloat
    let markerSpacing: CGFloat
    let connectorMaxHalfHeight: CGFloat
    private let connectorAttachFraction: CGFloat = 0.68
    private let connectorAttachHeightFraction: CGFloat = 0.72
    private let connectorAttachNeckMultiplier: CGFloat = 2
    private let connectorControlFraction: CGFloat = 0.35

    /// 在固定总宽度内绘制跟手形变；所有几何都由当前滚动进度即时派生。
    nonisolated func draw(
        context: inout GraphicsContext,
        size: CGSize,
        activeColor: Color,
        inactiveColor: Color
    ) {
        guard pageCount > 1, size.width > 0, size.height > 0 else { return }

        let clampedPage = min(CGFloat(pageCount - 1), max(0, continuousPage))
        let lowerPage = Int(floor(clampedPage))
        let upperPage = Int(ceil(clampedPage))
        let transitionProgress = clampedPage - CGFloat(lowerPage)
        let markerRadius = markerSize / 2
        let centerY = size.height / 2

        var lowerLobe = Lobe(centerX: 0, halfWidth: 0, halfHeight: 0)
        var upperLobe = Lobe(centerX: 0, halfWidth: 0, halfHeight: 0)
        var markerStartX: CGFloat = 0

        for index in 0..<pageCount {
            let selectionWeight = min(1, max(0, 1 - abs(clampedPage - CGFloat(index))))
            let markerWidth = markerSize + (activeWidth - markerSize) * selectionWeight
            let logicalCenterX = markerStartX + markerWidth / 2
            let physicalCenterX = isRightToLeft
                ? size.width - logicalCenterX
                : logicalCenterX

            let dotRect = CGRect(
                x: physicalCenterX - markerRadius,
                y: centerY - markerRadius,
                width: markerSize,
                height: markerSize
            )
            context.fill(Path(ellipseIn: dotRect), with: .color(inactiveColor))

            if index == lowerPage || index == upperPage {
                let lobeScale = sqrt(selectionWeight)
                let lobe = Lobe(
                    centerX: physicalCenterX,
                    halfWidth: markerWidth * lobeScale / 2,
                    halfHeight: markerSize * lobeScale / 2
                )
                if index == lowerPage {
                    lowerLobe = lobe
                }
                if index == upperPage {
                    upperLobe = lobe
                }
            }

            markerStartX += markerWidth + markerSpacing
        }

        if lowerPage == upperPage {
            drawLobe(lowerLobe, centerY: centerY, color: activeColor, context: &context)
            return
        }

        if drawsConnector {
            let neckHalfHeight = sin(.pi * transitionProgress) * connectorMaxHalfHeight
            drawConnector(
                lowerLobe: lowerLobe,
                upperLobe: upperLobe,
                centerY: centerY,
                neckHalfHeight: neckHalfHeight,
                color: activeColor,
                context: &context
            )
        }

        drawLobe(lowerLobe, centerY: centerY, color: activeColor, context: &context)
        drawLobe(upperLobe, centerY: centerY, color: activeColor, context: &context)
    }

    private nonisolated func drawLobe(
        _ lobe: Lobe,
        centerY: CGFloat,
        color: Color,
        context: inout GraphicsContext
    ) {
        guard lobe.halfWidth > 0, lobe.halfHeight > 0 else { return }

        let rect = CGRect(
            x: lobe.centerX - lobe.halfWidth,
            y: centerY - lobe.halfHeight,
            width: lobe.halfWidth * 2,
            height: lobe.halfHeight * 2
        )
        var path = Path()
        path.addRoundedRect(
            in: rect,
            cornerSize: CGSize(width: lobe.halfHeight, height: lobe.halfHeight)
        )
        context.fill(path, with: .color(color))
    }

    private nonisolated func drawConnector(
        lowerLobe: Lobe,
        upperLobe: Lobe,
        centerY: CGFloat,
        neckHalfHeight: CGFloat,
        color: Color,
        context: inout GraphicsContext
    ) {
        guard
            neckHalfHeight > 0,
            lowerLobe.halfWidth > 0,
            upperLobe.halfWidth > 0
        else { return }

        let lowerIsLeft = lowerLobe.centerX <= upperLobe.centerX
        let leftLobe = lowerIsLeft ? lowerLobe : upperLobe
        let rightLobe = lowerIsLeft ? upperLobe : lowerLobe
        let leftAttachX = leftLobe.centerX
            + leftLobe.halfWidth * connectorAttachFraction
        let rightAttachX = rightLobe.centerX
            - rightLobe.halfWidth * connectorAttachFraction
        guard rightAttachX > leftAttachX else { return }

        let span = rightAttachX - leftAttachX
        let leftAttachHalfHeight = min(
            leftLobe.halfHeight * connectorAttachHeightFraction,
            neckHalfHeight * connectorAttachNeckMultiplier
        )
        let rightAttachHalfHeight = min(
            rightLobe.halfHeight * connectorAttachHeightFraction,
            neckHalfHeight * connectorAttachNeckMultiplier
        )
        let controlInset = span * connectorControlFraction

        var path = Path()
        path.move(to: CGPoint(x: leftAttachX, y: centerY - leftAttachHalfHeight))
        path.addCurve(
            to: CGPoint(x: rightAttachX, y: centerY - rightAttachHalfHeight),
            control1: CGPoint(x: leftAttachX + controlInset, y: centerY - neckHalfHeight),
            control2: CGPoint(x: rightAttachX - controlInset, y: centerY - neckHalfHeight)
        )
        path.addLine(to: CGPoint(x: rightAttachX, y: centerY + rightAttachHalfHeight))
        path.addCurve(
            to: CGPoint(x: leftAttachX, y: centerY + leftAttachHalfHeight),
            control1: CGPoint(x: rightAttachX - controlInset, y: centerY + neckHalfHeight),
            control2: CGPoint(x: leftAttachX + controlInset, y: centerY + neckHalfHeight)
        )
        path.closeSubpath()
        context.fill(path, with: .color(color))
    }
}

/// ReadingYearSummaryPageGrid 以稳定的 4×3 网格渲染单页真实封面、目标占位与布局占位。
private struct ReadingYearSummaryPageGrid: View {
    let slots: [ReadingYearSummaryPagerSlot]
    let onBookTap: (Int64) -> Void

    private var columns: [GridItem] {
        Array(
            repeating: GridItem(
                .flexible(),
                spacing: ReadingYearSummaryCardLayout.gridSpacing,
                alignment: .top
            ),
            count: ReadingYearSummaryCardLayout.gridColumnCount
        )
    }

    var body: some View {
        LazyVGrid(
            columns: columns,
            alignment: .leading,
            spacing: ReadingYearSummaryCardLayout.gridSpacing
        ) {
            ForEach(slots) { slot in
                ReadingYearSummaryPageSlotView(slot: slot, onBookTap: onBookTap)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

/// ReadingYearSummaryPageSlotView 保持每个分页槽位只有一个稳定视图节点。
private struct ReadingYearSummaryPageSlotView: View {
    let slot: ReadingYearSummaryPagerSlot
    let onBookTap: (Int64) -> Void

    var body: some View {
        switch slot {
        case let .goal(goalSlot):
            switch goalSlot {
            case let .book(book):
                ReadingYearSummaryCompletedBookCover(book: book, onTap: onBookTap)
            case let .placeholder(index):
                ReadingYearSummaryPlaceholderCover(index: index)
            }
        case .pending:
            ReadingYearSummaryPendingCover()
        case .layoutSpacer:
            Color.clear
                .aspectRatio(XMBookCover.aspectRatio, contentMode: .fit)
                .accessibilityHidden(true)
        }
    }
}

/// ReadingYearSummaryPendingCover 使用无数字书脊轮廓表达年度书架结构，不伪装成未完成目标。
private struct ReadingYearSummaryPendingCover: View {
    var body: some View {
        XMBookCover.responsive(
            urlString: "",
            cornerRadius: CornerRadius.inlayHairline,
            border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
            placeholderIconSize: .hidden,
            surfaceStyle: .spine
        )
        .opacity(0.42)
        .accessibilityHidden(true)
    }
}

/// ReadingYearSummaryCompletedBookCover 展示年度目标中已经读完的真实书籍封面。
private struct ReadingYearSummaryCompletedBookCover: View {
    let book: ReadingYearReadBook
    let onTap: (Int64) -> Void

    var body: some View {
        Button {
            onTap(book.id)
        } label: {
            XMBookCover.responsive(
                urlString: book.coverURL,
                cornerRadius: CornerRadius.inlayHairline,
                border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                surfaceStyle: .spine
            )
            .accessibilityHidden(true)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("已读《\(book.name)》")
    }
}

/// ReadingYearSummaryPlaceholderCover 展示年度目标中尚未完成的占位封面与序号。
private struct ReadingYearSummaryPlaceholderCover: View {
    let index: Int

    var body: some View {
        XMBookCover.responsive(
            urlString: "",
            cornerRadius: CornerRadius.inlayHairline,
            border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
            placeholderIconSize: .hidden,
            surfaceStyle: .spine
        )
        .overlay {
            Text("\(index)")
                .font(AppTypography.brandDisplay(size: ReadingYearSummaryCardLayout.placeholderNumberFontSize, relativeTo: .title3))
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
                .minimumScaleFactor(0.42)
                .padding(.horizontal, ReadingYearSummaryCardLayout.placeholderNumberHorizontalInset)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("年度目标第 \(index) 本，尚未完成")
    }
}

private extension DynamicTypeSize {
    var xmUsesExpandedTextLayout: Bool {
        self >= .accessibility1
    }
}
