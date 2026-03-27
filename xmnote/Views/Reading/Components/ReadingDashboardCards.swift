import SwiftUI

/**
 * [INPUT]: 依赖 ReadingDashboardSnapshot 相关领域模型、XMBookCover、CardContainer 与 DesignTokens 提供首页卡片渲染能力
 * [OUTPUT]: 对外提供 ReadingTrendMetricsSection / ReadingFeatureCardsSection / ReadingRecentBooksCard / ReadingYearSummaryCard 等首页页面私有组件
 * [POS]: Reading/Components 页面私有子视图集合，负责在读首页各卡片区块的展示
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
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

/// ReadingDashboardInlineBanner 承接首页内联错误或提示文案，提供轻量动作出口而不打断滚动流。
struct ReadingDashboardInlineBanner: View {
    let message: String
    let actionTitle: String
    let onAction: () -> Void

    var body: some View {
        CardContainer(cornerRadius: CornerRadius.blockLarge, showsBorder: false) {
            HStack(spacing: Spacing.base) {
                Text(message)
                    .font(AppTypography.footnote)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(2)

                Spacer(minLength: 0)

                Button(actionTitle, action: onAction)
                    .font(AppTypography.footnoteSemibold)
                    .foregroundStyle(Color.brand)
            }
            .padding(Spacing.base)
        }
    }
}

/// ReadingTrendMetricsSection 把三项趋势指标收口为单张卡片，并统一处理分栏与分割线布局。
struct ReadingTrendMetricsSection: View {
    let metrics: [ReadingTrendMetric]

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        if !metrics.isEmpty {
            CardContainer(cornerRadius: CornerRadius.blockLarge, showsBorder: false) {
                GeometryReader { proxy in
                    let layout = ReadingTrendOverviewLayout(
                        containerSize: proxy.size,
                        columnCount: metrics.count
                    )
                    HStack(spacing: Spacing.none) {
                        ForEach(Array(metrics.enumerated()), id: \.offset) { index, metric in
                            ReadingTrendOverviewColumn(metric: metric, layout: layout)

                            if index != metrics.index(before: metrics.endIndex) {
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
                ReadingTrendOverviewLayout.columnAspectRatio * CGFloat(metrics.count),
                contentMode: .fit
            )
            .frame(minHeight: dynamicTypeSize.xmUsesExpandedTextLayout ? 142 : nil)
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
    /// 封装compactUnitFont对应的业务步骤，确保调用方可以稳定复用该能力。
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

    /// 封装combinedLineText对应的业务步骤，确保调用方可以稳定复用该能力。
    private func combinedLineText(for pairs: [ReadingDashboardMetricValueDisplay.Pair]) -> Text {
        pairs.enumerated().reduce(Text("")) { partial, item in
            let spacingText = item.offset == 0 ? Text("") : Text(" ")
            return partial + spacingText + pairText(item.element)
        }
    }

    /// 封装pairText对应的业务步骤，确保调用方可以稳定复用该能力。
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
    /// AxisStyle 负责当前场景的enum定义，明确职责边界并组织相关能力。
    private enum AxisStyle {
        static let lineWidth: CGFloat = 1
        static let dashPattern: [CGFloat] = [3, 3]
        static let horizontalInset: CGFloat = Spacing.micro
        static let color: Color = Color.textHint.opacity(0.24)
    }

    let points: [ReadingTrendMetric.Point]
    let chartHeight: CGFloat
    let spacing: CGFloat

    private var displayedRatios: [CGFloat] {
        ReadingDashboardFormatting.displayedBarRatios(points: points, chartHeight: chartHeight)
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
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                ZStack(alignment: .bottom) {
                    verticalBarShape
                        .fill(Color.chartBarTrack)

                    if displayedRatios[index] > 0 {
                        verticalBarShape
                            .fill(Color.brand)
                            .frame(height: chartHeight * displayedRatios[index])
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: chartHeight, alignment: .bottom)
                .accessibilityLabel(point.label)
                .accessibilityValue(point.value == 0 ? "0" : "\(point.value)")
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

/// ReadingFeatureCardsSection 并排展示今日阅读与继续阅读两张功能卡，统一控制二者比例和节奏。
struct ReadingFeatureCardsSection: View {
    let dailyGoal: ReadingDailyGoal
    let resumeBook: ReadingResumeBook?
    let isLoading: Bool
    let onEditDailyGoal: () -> Void
    let onResumeTap: () -> Void

    var body: some View {
        HStack(spacing: Spacing.base) {
            ReadingDailyGoalCard(
                goal: dailyGoal,
                isLoading: isLoading,
                onTap: onEditDailyGoal
            )
            .frame(maxWidth: .infinity)
            .aspectRatio(ReadingFeatureCardsStyle.cardAspectRatio, contentMode: .fit)

            ReadingResumeBookCard(
                book: resumeBook,
                isLoading: isLoading,
                onTap: onResumeTap
            )
            .frame(maxWidth: .infinity)
            .aspectRatio(ReadingFeatureCardsStyle.cardAspectRatio, contentMode: .fit)
        }
    }
}

/// ReadingFeatureCardsStyle 统一收口双功能卡共享的外层比例与内边距语义。
private enum ReadingFeatureCardsStyle {
    static let cardAspectRatio: CGFloat = 0.88
    static let contentInset: CGFloat = Spacing.base
    static let loadingPadding: CGFloat = Spacing.tight
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

    var loadingPadding: CGFloat { ReadingFeatureCardsStyle.loadingPadding }
}

/// ReadingResumeBookCardLayout 统一继续阅读卡的标题节奏与封面剩余空间填充策略，保证与今日阅读卡并排时的对齐感。
private struct ReadingResumeBookCardLayout {
    let cardSize: CGSize

    var cardHeight: CGFloat { max(1, cardSize.height) }

    var contentInset: CGFloat { ReadingFeatureCardsStyle.contentInset }

    var headerSpacing: CGFloat { ReadingFeatureCardHeaderMetrics.titleSubtitleSpacing }

    var headerToCoverSpacing: CGFloat { ReadingFeatureCardHeaderMetrics.headerToBodySpacing }

    var loadingPadding: CGFloat { ReadingFeatureCardsStyle.loadingPadding }

    var titleFontSize: CGFloat { ReadingFeatureCardHeaderMetrics.titleFontSize }

    var subtitleFontSize: CGFloat { ReadingFeatureCardHeaderMetrics.subtitleFontSize }

    var coverHorizontalInset: CGFloat { contentInset + 6 }

    var emptyIconSize: CGFloat { min(30, max(24, cardHeight * 0.145)) }

    var emptyStateSpacing: CGFloat { Spacing.tight }
}

/// ReadingDailyGoalCard 承接今日阅读目标的标题、状态和弧环进度，提供目标编辑入口。
private struct ReadingDailyGoalCard: View {
    let goal: ReadingDailyGoal
    let isLoading: Bool
    let onTap: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var statusTitle: String {
        goal.progress >= 1 ? "目标已达成" : "目标未达成"
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

                            ReadingDailyGoalArcGauge(goal: goal, layout: layout)
                                .frame(maxWidth: .infinity, maxHeight: layout.gaugeAvailableHeight, alignment: .top)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                        .padding(layout.contentInset)

                        if isLoading {
                            LoadingStateView(style: .inline)
                                .controlSize(.small)
                                .padding(layout.loadingPadding)
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
    }
}

/// ReadingDailyGoalArcGauge 渲染底部缺口的今日阅读进度弧环。
private struct ReadingDailyGoalArcGauge: View {
    let goal: ReadingDailyGoal
    let layout: ReadingDailyGoalCardLayout

    private var progress: CGFloat {
        CGFloat(min(1, max(0, goal.progress)))
    }

    private var targetText: String {
        "目标 \(max(1, goal.targetSeconds / 60)) 分钟"
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

            Text(ReadingDashboardFormatting.dailyGoalValueText(seconds: goal.readSeconds))
                .font(AppTypography.brandDisplay(size: layout.valueFontSize, relativeTo: .title2))
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.82)
                .frame(maxWidth: layout.valueMaxWidth)
                .contentTransition(.numericText())
                .offset(y: layout.valueVerticalOffset)
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
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("今日阅读")
        .accessibilityValue("\(ReadingDashboardFormatting.clockText(seconds: goal.readSeconds))，\(targetText)")
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
    let book: ReadingResumeBook?
    let isLoading: Bool
    let onTap: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: onTap) {
            CardContainer(cornerRadius: CornerRadius.containerMedium, showsBorder: false) {
                GeometryReader { proxy in
                    let layout = ReadingResumeBookCardLayout(cardSize: proxy.size)
                    ZStack(alignment: .topTrailing) {
                        Group {
                            if let book {
                                resumeBookContent(book: book, layout: layout)
                            } else {
                                emptyResumeContent(layout: layout)
                                    .padding(layout.contentInset)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

                        if isLoading {
                            LoadingStateView(style: .inline)
                                .controlSize(.small)
                                .padding(layout.loadingPadding)
                        }
                    }
                }
            }
        }
        .buttonStyle(.plain)
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
                    coverViewportHeight * XMBookCover.aspectRatio
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

    /// 空态延续同一标题骨架，再以下方图标和提示承接添加书籍入口。
    @ViewBuilder
    private func emptyResumeContent(layout: ReadingResumeBookCardLayout) -> some View {
        VStack(spacing: 0) {
            resumeHeader(
                title: "暂无在读书籍",
                subtitle: "添加一本书后会显示在这里",
                layout: layout,
                titleLineLimit: 1
            )

            VStack(spacing: layout.emptyStateSpacing) {
                Image("BookCoverPlaceholder")
                    .renderingMode(.template)
                    .resizable()
                    .scaledToFit()
                    .frame(width: layout.emptyIconSize, height: layout.emptyIconSize)
                    .foregroundStyle(Color.textHint)
                    .accessibilityHidden(true)

                Text("开始阅读后，可从这里快速返回")
                    .font(
                        AppTypography.fixed(
                            baseSize: layout.subtitleFontSize,
                            relativeTo: .caption,
                            weight: ReadingFeatureCardHeaderMetrics.subtitleFontWeight,
                            design: .rounded,
                            minimumPointSize: layout.subtitleFontSize
                        )
                    )
                    .foregroundStyle(Color.textHint)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
            }
            .padding(.top, layout.headerToCoverSpacing)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
    let books: [ReadingRecentBook]
    let isLoading: Bool
    let onBookTap: (Int64) -> Void

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

                if books.isEmpty {
                    EmptyStateView(icon: "books.vertical", message: isLoading ? "正在整理阅读记录" : "最近没有在读记录")
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
    static let titleToSubtitleSpacing: CGFloat = Spacing.none
    static let subtitleToGridSpacing: CGFloat = Spacing.contentEdge
    static let headerTrailingSpacing: CGFloat = Spacing.base
    static let gridSpacing: CGFloat = Spacing.base
    static let gridColumnCount = 4

    static let titleFontSize: CGFloat = 15
    static let countFontSize: CGFloat = 30
    static let countVerticalTrim = AppTypography.brandTrim(size: countFontSize, textStyle: .title2)
    static let titleBottomCompensation: CGFloat = Spacing.tiny
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

/// ReadingYearSummaryCard 展示年度阅读目标完成情况、目标书架和操作入口。
struct ReadingYearSummaryCard: View {
    let summary: ReadingYearSummary
    let onOpenSummary: () -> Void
    let onEditGoal: () -> Void
    let onBookTap: (Int64) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private var goalSlots: [ReadingYearSummaryGoalSlot] {
        var slots = summary.books.map(ReadingYearSummaryGoalSlot.book)
        guard summary.readCount < summary.targetCount else { return slots }

        slots.append(
            contentsOf: (summary.readCount + 1...summary.targetCount).map(ReadingYearSummaryGoalSlot.placeholder)
        )
        return slots
    }

    private var gridColumns: [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: ReadingYearSummaryCardLayout.gridSpacing, alignment: .top),
            count: ReadingYearSummaryCardLayout.gridColumnCount
        )
    }

    var body: some View {
        CardContainer(cornerRadius: CornerRadius.containerMedium, showsBorder: false) {
            VStack(alignment: .leading, spacing: ReadingYearSummaryCardLayout.subtitleToGridSpacing) {
                headerSection

                LazyVGrid(columns: gridColumns, alignment: .leading, spacing: ReadingYearSummaryCardLayout.gridSpacing) {
                    ForEach(goalSlots) { slot in
                        switch slot {
                        case let .book(book):
                            ReadingYearSummaryCompletedBookCover(book: book, onTap: onBookTap)
                        case let .placeholder(index):
                            ReadingYearSummaryPlaceholderCover(index: index)
                        }
                    }
                }
            }
            .padding(ReadingYearSummaryCardLayout.contentInset)
        }
    }

    private var headerSection: some View {
        HStack(alignment: .center, spacing: ReadingYearSummaryCardLayout.headerTrailingSpacing) {
            VStack(alignment: .leading, spacing: ReadingYearSummaryCardLayout.titleToSubtitleSpacing) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.half) {
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

                    Text("\(summary.readCount)")
                        .font(AppTypography.brandDisplay(size: ReadingYearSummaryCardLayout.countFontSize, relativeTo: .title2))
                        .foregroundStyle(Color.brand)
                        .minimumScaleFactor(0.72)
                        .lineLimit(1)
                        .brandVerticalTrim(ReadingYearSummaryCardLayout.countVerticalTrim)

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
                .padding(.bottom, -ReadingYearSummaryCardLayout.titleBottomCompensation)

                HStack(alignment: .center, spacing: ReadingYearSummaryCardLayout.subtitleInlineSpacing) {
                    statusContent
                        .layoutPriority(1)

                    Button(action: onEditGoal) {
                        Image(systemName: "pencil.line")
                            .font(.system(size: ReadingYearSummaryCardLayout.subtitleFontSize, weight: .regular))
                            .foregroundStyle(Color.textSecondary)
                            .frame(width: Spacing.tight, height: Spacing.tight)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("编辑年度阅读目标")
                }
            }

            Spacer(minLength: 0)

            Button(action: onOpenSummary) {
                Image(systemName: "chevron.right")
                    .font(AppTypography.footnoteSemibold)
                    .foregroundStyle(Color.textHint)
                    .frame(width: Spacing.base, height: Spacing.base)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看年度已读列表")
        }
    }

    @ViewBuilder
    private var statusContent: some View {
        if summary.isTargetAchieved {
            Text("已完成今年阅读目标")
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
                .lineLimit(dynamicTypeSize.xmUsesExpandedTextLayout ? 2 : 1)
                .minimumScaleFactor(0.92)
        } else {
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
        }
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
