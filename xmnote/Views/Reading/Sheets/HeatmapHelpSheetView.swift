import SwiftUI

/**
 * [INPUT]: 依赖 XMSheetScaffold、DesignTokens/Spacing、HeatmapLevel、ReadingStatusPresentation 与 HeatmapChart.legend
 * [OUTPUT]: 对外提供 HeatmapHelpSheetView（热力图说明弹层）
 * [POS]: 在读页热力图小组件的帮助说明面板，纯展示职责（文案 + 图例），零回调信息卡片
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// HeatmapHelpSheetView 展示热力图阅读规则和图例，承接首页热力图右上角说明入口。
struct HeatmapHelpSheetView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        XMSheetScaffold(
            title: "热力图说明",
            onClose: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Spacing.double) {
                descriptionSection
                legendSection
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.contentEdge)
        }
    }

    // MARK: - Description

    private var descriptionSection: some View {
        Text("无论是你记录的每一条笔记，还是统计的读书时长，或标记的书籍状态，都可以点亮每天的小格子。记录越多、时长越长，颜色就越深。")
            .font(AppTypography.body)
            .foregroundStyle(Color.textSecondary)
            .lineSpacing(Spacing.compact)
    }

    // MARK: - Legend

    private var legendSection: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            statusLegendGrid
            HeatmapChart.legend(squareSize: 12, fontSize: 11)
        }
    }

    private var statusLegendGrid: some View {
        let states: [(String, Color)] = [
            ("想读", ReadingStatusPresentation.wantRead),
            ("在读", ReadingStatusPresentation.reading),
            ("读完", ReadingStatusPresentation.readDone),
            ("搁置", ReadingStatusPresentation.onHold),
            ("弃读", ReadingStatusPresentation.abandoned)
        ]

        return LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 68), spacing: Spacing.half)],
            alignment: .leading,
            spacing: Spacing.half
        ) {
            ForEach(states, id: \.0) { item in
                statusLegendItem(item.0, color: item.1)
            }
        }
    }

    private func statusLegendItem(_ title: String, color: Color) -> some View {
        HStack(spacing: Spacing.half) {
            RoundedRectangle(cornerRadius: CornerRadius.inlayTiny, style: .continuous)
                .fill(color)
                .frame(width: 12, height: 12)
            Text(title)
                .font(AppTypography.subheadline)
                .foregroundStyle(Color.textSecondary)
        }
    }
}
