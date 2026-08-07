import SwiftUI

/**
 * [INPUT]: 依赖 ReadCalendarSummaryMetric 指标描述与阅读日历统计设计令牌
 * [OUTPUT]: 对外提供 ReadCalendarSummaryMetricSection、指标网格、结构化指标值与环比模型
 * [POS]: 阅读日历月度/年度统计 Sheet 共用的页面私有指标网格，统一卡片层级、分段颜色和无障碍朗读
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 指标值由可独立排版的文本片段组成，数字、单位与普通文本不再依赖字符串拼接。
struct ReadCalendarSummaryValue: Hashable {
    enum PartRole: Hashable {
        case number
        case unit
        case text
    }

    struct Part: Hashable {
        let text: String
        let role: PartRole
    }

    let parts: [Part]
    let accessibilityLabel: String

    /// 构造数字加单位的统计值，并保留完整 VoiceOver 读法。
    static func quantity(_ number: Int, unit: String) -> Self {
        Self(
            parts: [.init(text: String(number), role: .number), .init(text: unit, role: .unit)],
            accessibilityLabel: "\(number)\(unit)"
        )
    }

    /// 构造普通状态文案，例如“未开始”或“暂无”。
    static func text(_ text: String) -> Self {
        Self(parts: [.init(text: text, role: .text)], accessibilityLabel: text)
    }
}

/// 指标环比只给变化数字赋予趋势色，前缀、单位与补充文案始终保持次级色。
struct ReadCalendarSummaryDelta: Hashable {
    enum Trend: Hashable {
        case up
        case down
        case flat
    }

    let prefix: String
    let parts: [ReadCalendarSummaryValue.Part]
    let trailingText: String?
    let trend: Trend
    let accessibilityLabel: String

    /// 将整数变化转换为统一的增减/持平展示。
    static func make(prefix: String, delta: Int, unit: String) -> Self {
        if delta == 0 {
            return Self(
                prefix: prefix,
                parts: [],
                trailingText: "持平",
                trend: .flat,
                accessibilityLabel: "\(prefix)持平"
            )
        }
        let trend: Trend = delta > 0 ? .up : .down
        let direction = delta > 0 ? "增加" : "减少"
        return Self(
            prefix: prefix,
            parts: [
                .init(text: "\(delta > 0 ? "+" : "−")\(abs(delta))", role: .number),
                .init(text: unit, role: .unit)
            ],
            trailingText: nil,
            trend: trend,
            accessibilityLabel: "\(prefix)\(direction)\(abs(delta))\(unit)"
        )
    }
}

/// 单张统计指标卡的数据描述，月度与年度 Sheet 通过同一结构生成布局。
struct ReadCalendarSummaryMetric: Identifiable, Hashable {
    let id: String
    let title: String
    let icon: String
    let gradientRole: ReadCalendarSummaryGradientRole
    let value: ReadCalendarSummaryValue
    let delta: ReadCalendarSummaryDelta?
}

/// 月度与年度共用的指标分组，将标题与网格作为同一内容组保持稳定的亲密性。
struct ReadCalendarSummaryMetricSection: View {
    let metrics: [ReadCalendarSummaryMetric]
    let isLoading: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text("阅读总结")
                .font(ReadCalendarSummaryTypography.sectionTitle)
                .foregroundStyle(Color.textPrimary)

            ReadCalendarSummaryMetricGrid(metrics: metrics)
                .redacted(reason: isLoading ? .placeholder : [])
                .allowsHitTesting(!isLoading)
        }
    }
}

/// 月度与年度共用的统计指标网格，常规字号双列，无障碍字号自动切换为单列。
struct ReadCalendarSummaryMetricGrid: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    let metrics: [ReadCalendarSummaryMetric]

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            LazyVStack(spacing: Spacing.base) {
                metricCards
            }
        } else {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: Spacing.base), count: 2),
                spacing: Spacing.base
            ) {
                metricCards
            }
        }
    }

    @ViewBuilder
    private var metricCards: some View {
        ForEach(metrics) { metric in
            ReadCalendarSummaryMetricCard(metric: metric)
        }
    }
}

/// 单张指标卡以标题图标在上、主值和环比在下的结构稳定信息层级。
private struct ReadCalendarSummaryMetricCard: View {
    let metric: ReadCalendarSummaryMetric

    private var gradient: ReadCalendarSummaryGradientSpec {
        Color.readCalendarSummaryGradientSpec(for: metric.gradientRole)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            HStack(spacing: Spacing.cozy) {
                Image(systemName: metric.icon)
                    .font(AppTypography.caption2Semibold)
                    .foregroundStyle(.white)
                    .frame(width: 26, height: 26)
                    .background(
                        LinearGradient(
                            colors: [gradient.start, gradient.mid, gradient.end],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        in: RoundedRectangle(cornerRadius: CornerRadius.inlayMedium, style: .continuous)
                    )

                Text(metric.title)
                    .font(ReadCalendarSummaryTypography.metricTitle)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }

            VStack(alignment: .leading, spacing: Spacing.tiny) {
                ReadCalendarSummaryValueView(value: metric.value)
                deltaSlot
            }
        }
        .padding(.horizontal, Spacing.comfortable)
        .padding(.vertical, Spacing.base)
        .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
        .background(
            LinearGradient(
                colors: [gradient.start.opacity(0.10), gradient.end.opacity(0.035)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .stroke(gradient.mid.opacity(0.16), lineWidth: CardStyle.borderWidth)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var deltaSlot: some View {
        if let delta = metric.delta {
            ReadCalendarSummaryDeltaView(delta: delta)
        } else {
            Text(verbatim: "环比占位")
                .font(ReadCalendarSummaryTypography.metricSubtitle)
                .hidden()
                .accessibilityHidden(true)
        }
    }

    private var accessibilityLabel: String {
        [metric.title, metric.value.accessibilityLabel, metric.delta?.accessibilityLabel]
            .compactMap { $0 }
            .joined(separator: "，")
    }
}

/// 将结构化指标值渲染为同 baseline 的数字、单位或普通状态文案。
struct ReadCalendarSummaryValueView: View {
    let value: ReadCalendarSummaryValue
    var numberColor: Color = .textPrimary

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.tiny) {
            ForEach(Array(value.parts.enumerated()), id: \.offset) { _, part in
                Text(part.text)
                    .font(font(for: part.role))
                    .foregroundStyle(color(for: part.role))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(value.accessibilityLabel)
    }

    private func font(for role: ReadCalendarSummaryValue.PartRole) -> Font {
        switch role {
        case .number: ReadCalendarSummaryTypography.metricNumber
        case .unit: ReadCalendarSummaryTypography.metricUnit
        case .text: ReadCalendarSummaryTypography.metricText
        }
    }

    private func color(for role: ReadCalendarSummaryValue.PartRole) -> Color {
        switch role {
        case .number: numberColor
        case .unit: .textSecondary
        case .text: .textPrimary
        }
    }
}

/// 环比分段视图保证只有变化数字使用成功色或警告色。
private struct ReadCalendarSummaryDeltaView: View {
    let delta: ReadCalendarSummaryDelta

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.hairline) {
            Text(delta.prefix)
                .foregroundStyle(Color.textSecondary)

            ForEach(Array(delta.parts.enumerated()), id: \.offset) { _, part in
                Text(part.text)
                    .foregroundStyle(part.role == .number ? trendColor : Color.textSecondary)
            }

            if let trailingText = delta.trailingText {
                Text(trailingText)
                    .foregroundStyle(trendColor)
            }
        }
        .font(ReadCalendarSummaryTypography.metricSubtitle)
        .lineLimit(1)
        .minimumScaleFactor(0.8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(delta.accessibilityLabel)
    }

    private var trendColor: Color {
        switch delta.trend {
        case .up: .readCalendarSummaryDeltaUp
        case .down: .readCalendarSummaryDeltaDown
        case .flat: .readCalendarSummaryDeltaFlat
        }
    }
}
