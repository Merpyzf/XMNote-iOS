import SwiftUI

/**
 * [INPUT]: 依赖 HeatmapLevel 与 DesignTokens 中的热力颜色、排版和间距令牌
 * [OUTPUT]: 对外提供 HeatmapColorPalette、HeatmapLegendStyle 与 HeatmapLegend，支持连续/分离色阶图例和动态调色板注入
 * [POS]: UIComponents/Charts 的热力图共享图例与调色板组件，供 HeatmapChart、CalendarHeatmap 及业务页面复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

// MARK: - 调色板

/// 热力图五级颜色集合，调用方负责把业务主题色转换成组件可直接消费的色阶。
struct HeatmapColorPalette {
    let none: Color
    let veryLess: Color
    let less: Color
    let more: Color
    let veryMore: Color

    /// 创建完整五级调色板，分别表达无活动和由少到多的四级活动强度。
    init(
        none: Color,
        veryLess: Color,
        less: Color,
        more: Color,
        veryMore: Color
    ) {
        self.none = none
        self.veryLess = veryLess
        self.less = less
        self.more = more
        self.veryMore = veryMore
    }

    static let appDefault = HeatmapColorPalette(
        none: .heatmapNone,
        veryLess: .brandLight,
        less: .brand,
        more: .brandDeep,
        veryMore: .brandDarkest
    )

    /// 返回指定强度对应的颜色，供方格和图例共享同一映射。
    func color(for level: HeatmapLevel) -> Color {
        switch level {
        case .none: none
        case .veryLess: veryLess
        case .less: less
        case .more: more
        case .veryMore: veryMore
        }
    }
}

// MARK: - 图例样式

/// 热力图色阶的排列方式：连续色带用于月历，分离色块用于 GitHub 风格网格。
enum HeatmapLegendArrangement: Equatable {
    case continuous
    case separated
}

/// 热力图图例的视觉注入参数，控制排列、尺寸、圆角、间距与文本层级。
struct HeatmapLegendStyle {
    let arrangement: HeatmapLegendArrangement
    let squareSize: CGFloat
    let squareSpacing: CGFloat
    let labelSpacing: CGFloat
    let cornerRadius: CGFloat
    let textSize: CGFloat
    let textColor: Color

    /// 创建图例样式，使不同图表保留各自密度而复用相同语义结构。
    init(
        arrangement: HeatmapLegendArrangement,
        squareSize: CGFloat,
        squareSpacing: CGFloat,
        labelSpacing: CGFloat,
        cornerRadius: CGFloat,
        textSize: CGFloat,
        textColor: Color
    ) {
        self.arrangement = arrangement
        self.squareSize = squareSize
        self.squareSpacing = squareSpacing
        self.labelSpacing = labelSpacing
        self.cornerRadius = cornerRadius
        self.textSize = textSize
        self.textColor = textColor
    }

    static let chart = HeatmapLegendStyle(
        arrangement: .separated,
        squareSize: 10,
        squareSpacing: Spacing.compact,
        labelSpacing: Spacing.compact,
        cornerRadius: CornerRadius.inlayTiny,
        textSize: 9,
        textColor: .textHint
    )

    static let calendarReadingDetail = HeatmapLegendStyle(
        arrangement: .continuous,
        squareSize: 16,
        squareSpacing: Spacing.none,
        labelSpacing: Spacing.half,
        cornerRadius: CornerRadius.inlaySmall,
        textSize: 10,
        textColor: .textSecondary
    )
}

// MARK: - 图例组件

private enum HeatmapLegendConstants {
    static let orderedLevels: [HeatmapLevel] = [.veryLess, .less, .more, .veryMore]
}

/// 展示从“少”到“多”的四级热力颜色，并为辅助技术提供合并后的阅读强度说明。
struct HeatmapLegend: View {
    let palette: HeatmapColorPalette
    var style: HeatmapLegendStyle = .chart

    var body: some View {
        HStack(spacing: style.labelSpacing) {
            Text("少")
                .font(CalendarHeatmapTypography.legend(baseSize: style.textSize))
                .foregroundStyle(style.textColor)

            colorBar

            Text("多")
                .font(CalendarHeatmapTypography.legend(baseSize: style.textSize))
                .foregroundStyle(style.textColor)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("阅读强度，少到多，四级")
    }
}

private extension HeatmapLegend {
    @ViewBuilder
    var colorBar: some View {
        switch style.arrangement {
        case .continuous:
            HStack(spacing: style.squareSpacing) {
                colorSquares
            }
            .compositingGroup()
            .clipShape(
                RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous)
            )
        case .separated:
            HStack(spacing: style.squareSpacing) {
                colorSquares
            }
        }
    }

    @ViewBuilder
    var colorSquares: some View {
        ForEach(HeatmapLegendConstants.orderedLevels, id: \.rawValue) { level in
            Rectangle()
                .fill(palette.color(for: level))
                .frame(width: style.squareSize, height: style.squareSize)
                .clipShape(
                    RoundedRectangle(
                        cornerRadius: style.arrangement == .separated ? style.cornerRadius : 0,
                        style: .continuous
                    )
                )
        }
    }
}

#Preview("连续月历图例") {
    HeatmapLegend(
        palette: .appDefault,
        style: .calendarReadingDetail
    )
    .padding()
}
