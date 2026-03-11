import SwiftUI

/**
 * [INPUT]: 依赖 ReadingDashboardSnapshot 相关领域模型、XMBookCover、CardContainer 与 DesignTokens 提供首页卡片渲染能力
 * [OUTPUT]: 对外提供 ReadingTrendMetricsSection / ReadingFeatureCardsSection / ReadingRecentBooksCard / ReadingYearSummaryCard 等首页页面私有组件
 * [POS]: Reading/Components 页面私有子视图集合，负责在读首页各卡片区块的展示
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

private enum ReadingDashboardLayout {
    static let recentCoverWidth: CGFloat = 70
    static let recentCoverHeight: CGFloat = 100
}

struct ReadingDashboardInlineBanner: View {
    let message: String
    let actionTitle: String
    let onAction: () -> Void

    var body: some View {
        CardContainer(cornerRadius: CornerRadius.blockLarge) {
            HStack(spacing: Spacing.base) {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(2)

                Spacer(minLength: 0)

                Button(actionTitle, action: onAction)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.brand)
            }
            .padding(Spacing.base)
        }
    }
}

struct ReadingTrendMetricsSection: View {
    let metrics: [ReadingTrendMetric]

    var body: some View {
        if !metrics.isEmpty {
            CardContainer(cornerRadius: CornerRadius.blockLarge) {
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
        }
    }
}

/// ReadingTrendOverviewLayout 统一管理三栏总卡的比例布局，避免视图内部散落魔法数字。
private struct ReadingTrendOverviewLayout {
    static let columnAspectRatio: CGFloat = 0.98

    let containerSize: CGSize
    let columnCount: Int

    var columnWidth: CGFloat {
        containerSize.width / CGFloat(max(1, columnCount))
    }

    var columnHeight: CGFloat { containerSize.height }

    var verticalPadding: CGFloat { Spacing.screenEdge }

    var dividerVerticalInset: CGFloat { verticalPadding }

    var horizontalPadding: CGFloat { Spacing.screenEdge }

    var chartHeight: CGFloat { columnHeight * 0.32 }

    var metricTitleSpacing: CGFloat { max(0, min(0.5, columnHeight * 0.003)) }

    var headerToChartMinSpacing: CGFloat { Spacing.cozy }

    var numberFontSize: CGFloat { min(30, max(20, columnHeight * 0.20)) }

    var unitFontSize: CGFloat { max(8, numberFontSize / 3) }

    var metricValueBottomCompensation: CGFloat { min(3, max(2, numberFontSize * 0.10)) }

    var descriptionFontSize: CGFloat { min(12, max(10, columnHeight * 0.082)) }

    var chartSpacing: CGFloat { Spacing.cozy }
}

/// ReadingTrendOverviewColumn 渲染单个趋势栏位，承载主值、描述与最近窗口柱图。
private struct ReadingTrendOverviewColumn: View {
    let metric: ReadingTrendMetric
    let layout: ReadingTrendOverviewLayout

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.none) {
            VStack(alignment: .leading, spacing: layout.metricTitleSpacing) {
                ReadingTrendMetricValueLabel(
                    display: ReadingDashboardFormatting.metricValueDisplay(metric: metric),
                    numberFontSize: layout.numberFontSize,
                    unitFontSize: layout.unitFontSize,
                    bottomCompensation: layout.metricValueBottomCompensation
                )

                Text(metric.title)
                    .font(.system(size: layout.descriptionFontSize, weight: .regular, design: .rounded))
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
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
    let bottomCompensation: CGFloat

    var body: some View {
        Text(metricAttributedString())
            .foregroundStyle(Color.textPrimary)
            .lineLimit(1)
            .minimumScaleFactor(0.72)
            .contentTransition(.numericText())
            // Tighten the brand font's deeper line box so the subtitle reads as part of the same group.
            .padding(.bottom, -bottomCompensation)
    }

    /// 组合多段 AttributedString，确保数字和单位在同一基线上呈现且不使用废弃的 Text 拼接 API。
    func metricAttributedString() -> AttributedString {
        display.segments.reduce(into: AttributedString()) { partial, segment in
            partial.append(styledText(for: segment))
        }
    }

    /// 按段角色切换品牌数字字体和单位字体。
    func styledText(for segment: ReadingDashboardMetricValueDisplay.Segment) -> AttributedString {
        var piece = AttributedString(segment.text)
        switch segment.role {
        case .number:
            piece.font = .brandDisplay(size: numberFontSize, relativeTo: .title3)
        case .unit:
            piece.font = .system(size: unitFontSize, weight: .medium, design: .rounded)
        }
        return piece
    }
}

/// ReadingTrendMiniBarChart 渲染趋势栏位底部柱图，保留 Android 的零值占位语义。
private struct ReadingTrendMiniBarChart: View {
    let points: [ReadingTrendMetric.Point]
    let chartHeight: CGFloat
    let spacing: CGFloat

    private var displayedRatios: [CGFloat] {
        ReadingDashboardFormatting.displayedBarRatios(points: points, chartHeight: chartHeight)
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: spacing) {
            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                ZStack(alignment: .bottom) {
                    RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
                        .fill(Color.chartBarTrack)

                    if displayedRatios[index] > 0 {
                        RoundedRectangle(cornerRadius: CornerRadius.inlaySmall, style: .continuous)
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
        .animation(.smooth(duration: 0.45), value: displayedRatios)
    }
}

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
    static let cardAspectRatio: CGFloat = 0.82
    static let contentInset: CGFloat = Spacing.section
    static let loadingPadding: CGFloat = Spacing.tight
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

    var headerSpacing: CGFloat { Spacing.compact }

    var headerToGaugeSpacing: CGFloat { Spacing.screenEdge }

    var statusFontSize: CGFloat { 14 }

    var subtitleFontSize: CGFloat { 12 }

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

/// ReadingResumeBookCardLayout 收口继续阅读卡内部尺寸，避免受今日阅读弧环策略连带影响。
private struct ReadingResumeBookCardLayout {
    let cardSize: CGSize

    var cardHeight: CGFloat { max(1, cardSize.height) }

    var contentInset: CGFloat { ReadingFeatureCardsStyle.contentInset }

    var headerSpacing: CGFloat { Spacing.half }

    var loadingPadding: CGFloat { ReadingFeatureCardsStyle.loadingPadding }

    var continueTitleFontSize: CGFloat { min(18, max(15, cardHeight * 0.082)) }

    var continueMetaFontSize: CGFloat { min(13, max(11, cardHeight * 0.062)) }

    var continueHintFontSize: CGFloat { min(12, max(10, cardHeight * 0.056)) }

    var continueCoverWidth: CGFloat { min(56, max(42, cardHeight * 0.255)) }

    var continueContentSpacing: CGFloat { Spacing.tight }

    var continueEmptyIconSize: CGFloat { min(30, max(24, cardHeight * 0.145)) }
}

private struct ReadingDailyGoalCard: View {
    let goal: ReadingDailyGoal
    let isLoading: Bool
    let onTap: () -> Void

    private var statusTitle: String {
        goal.progress >= 1 ? "目标已达成" : "目标未达成"
    }

    var body: some View {
        Button(action: onTap) {
            CardContainer(cornerRadius: CornerRadius.containerMedium) {
                GeometryReader { proxy in
                    let layout = ReadingDailyGoalCardLayout(cardSize: proxy.size)
                    ZStack(alignment: .topTrailing) {
                        VStack(spacing: layout.headerToGaugeSpacing) {
                            VStack(spacing: layout.headerSpacing) {
                                Text(statusTitle)
                                    .font(.system(size: layout.statusFontSize, weight: .semibold, design: .rounded))
                                    .foregroundStyle(Color.textPrimary)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.9)
                                    .multilineTextAlignment(.center)

                                Text("今日阅读")
                                    .font(.system(size: layout.subtitleFontSize, weight: .medium, design: .rounded))
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
                            ProgressView()
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
                .font(.brandDisplay(size: layout.valueFontSize, relativeTo: .title2))
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
                .font(.system(size: layout.targetFontSize, weight: .regular, design: .rounded))
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

private struct ReadingResumeBookCard: View {
    let book: ReadingResumeBook?
    let isLoading: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            CardContainer(cornerRadius: CornerRadius.containerMedium) {
                GeometryReader { proxy in
                    let layout = ReadingResumeBookCardLayout(cardSize: proxy.size)
                    ZStack(alignment: .topTrailing) {
                        VStack(alignment: .leading, spacing: layout.continueContentSpacing) {
                            Text("继续阅读")
                                .font(.system(size: layout.continueMetaFontSize, weight: .medium, design: .rounded))
                                .foregroundStyle(Color.textSecondary)

                            Spacer(minLength: 0)

                            if let book {
                                VStack(alignment: .leading, spacing: layout.continueContentSpacing) {
                                    HStack(alignment: .top, spacing: layout.continueContentSpacing) {
                                        XMBookCover.fixedWidth(
                                            layout.continueCoverWidth,
                                            urlString: book.coverURL,
                                            border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth)
                                        )

                                        VStack(alignment: .leading, spacing: layout.headerSpacing) {
                                            Text(book.name)
                                                .font(.system(size: layout.continueTitleFontSize, weight: .semibold, design: .rounded))
                                                .foregroundStyle(Color.textPrimary)
                                                .lineLimit(2)

                                            Text(ReadingDashboardFormatting.percentText(book.progressPercent))
                                                .font(.system(size: layout.continueMetaFontSize, weight: .medium, design: .rounded))
                                                .foregroundStyle(Color.textSecondary)
                                                .lineLimit(1)
                                        }
                                        .frame(maxWidth: .infinity, alignment: .topLeading)
                                    }

                                    Text("继续补全今天的阅读轨迹")
                                        .font(.system(size: layout.continueHintFontSize, weight: .medium, design: .rounded))
                                        .foregroundStyle(Color.textHint)
                                        .lineLimit(2)
                                }
                            } else {
                                VStack(alignment: .leading, spacing: layout.continueContentSpacing) {
                                    Image(systemName: "book.badge.plus")
                                        .font(.system(size: layout.continueEmptyIconSize, weight: .medium))
                                        .foregroundStyle(Color.brand)

                                    Text("还没有可继续的书")
                                        .font(.system(size: layout.continueTitleFontSize, weight: .semibold, design: .rounded))
                                        .foregroundStyle(Color.textPrimary)

                                    Text("先添加一本书，再从这里快速返回阅读")
                                        .font(.system(size: layout.continueMetaFontSize, weight: .medium, design: .rounded))
                                        .foregroundStyle(Color.textSecondary)
                                        .lineLimit(3)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }

                            Spacer(minLength: 0)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(layout.contentInset)

                        if isLoading {
                            ProgressView()
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

struct ReadingRecentBooksCard: View {
    let books: [ReadingRecentBook]
    let isLoading: Bool
    let onBookTap: (Int64) -> Void

    var body: some View {
        CardContainer(cornerRadius: CornerRadius.containerMedium) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("最近在读")
                    .font(.headline.weight(.semibold))
                    .foregroundStyle(Color.textPrimary)

                if books.isEmpty {
                    EmptyStateView(icon: "books.vertical", message: isLoading ? "正在整理阅读记录" : "最近没有在读记录")
                        .frame(height: 160)
                } else {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(alignment: .top, spacing: Spacing.base) {
                            ForEach(books) { book in
                                Button {
                                    onBookTap(book.id)
                                } label: {
                                    VStack(alignment: .leading, spacing: Spacing.half) {
                                        XMBookCover.fixedSize(
                                            width: ReadingDashboardLayout.recentCoverWidth,
                                            height: ReadingDashboardLayout.recentCoverHeight,
                                            urlString: book.coverURL,
                                            border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth)
                                        )

                                        Text(book.name)
                                            .font(.caption)
                                            .foregroundStyle(Color.textPrimary)
                                            .lineLimit(1)

                                        Text(ReadingDashboardFormatting.percentText(book.progressPercent))
                                            .font(.caption2)
                                            .foregroundStyle(Color.textSecondary)
                                            .lineLimit(1)
                                    }
                                    .frame(width: ReadingDashboardLayout.recentCoverWidth, alignment: .leading)
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
            }
            .padding(Spacing.base)
        }
    }
}

struct ReadingYearSummaryCard: View {
    let summary: ReadingYearSummary
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            CardContainer(cornerRadius: CornerRadius.containerMedium) {
                HStack(spacing: Spacing.base) {
                    VStack(alignment: .leading, spacing: Spacing.half) {
                        HStack(alignment: .firstTextBaseline, spacing: Spacing.half) {
                            Text("今年已读")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(Color.textPrimary)
                            Text("\(summary.readCount)")
                                .font(.system(size: 30, weight: .bold, design: .rounded))
                                .foregroundStyle(Color.brand)
                                .monospacedDigit()
                            Text("本")
                                .font(.headline.weight(.semibold))
                                .foregroundStyle(Color.textPrimary)
                        }

                        Text(ReadingDashboardFormatting.yearSummarySubtitle(summary: summary))
                            .font(.caption)
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(2)
                    }

                    Spacer(minLength: 0)

                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(Color.textHint)
                }
                .padding(Spacing.base)
            }
        }
        .buttonStyle(.plain)
    }
}
