import SwiftUI

/**
 * [INPUT]: 依赖 DesignTokens/Spacing 设计令牌，依赖 HeatmapLevel 与状态色定义，依赖 HeatmapChart.legend
 * [OUTPUT]: 对外提供 HeatmapHelpSheetView（热力图说明弹层）
 * [POS]: 在读页热力图小组件的帮助说明面板，纯展示职责（文案 + 图例），零回调信息卡片
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

struct HeatmapHelpSheetView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(alignment: .leading, spacing: Spacing.double) {
                titleSection
                    .padding(.trailing, 44)
                descriptionSection
                legendSection
            }
            .padding(Spacing.double)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(key: SheetHeightKey.self, value: proxy.size.height)
                }
            )

            closeButton
        }
    }

    // MARK: - Close Button

    private var closeButton: some View {
        Button { dismiss() } label: {
            Image(systemName: "xmark")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 28, height: 28)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .circle)
        .padding(.top, Spacing.double)
        .padding(.trailing, Spacing.double)
    }

    // MARK: - Title

    private var titleSection: some View {
        Text("热力图说明")
            .font(.title3.weight(.semibold))
    }

    // MARK: - Description

    private var descriptionSection: some View {
        Text("无论是你记录的每一条笔记，还是统计的读书时长，或标记的书籍状态，都可以点亮每天的小格子。记录越多、时长越长，颜色就越深。")
            .font(.body)
            .foregroundStyle(Color.textSecondary)
            .lineSpacing(4)
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
            ("想读", .statusWish),
            ("在读", .statusReading),
            ("读完", .statusDone),
            ("搁置", .statusOnHold),
            ("弃读", .statusAbandoned)
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
        HStack(spacing: 6) {
            RoundedRectangle(cornerRadius: CornerRadius.inlayTiny)
                .fill(color)
                .frame(width: 12, height: 12)
            Text(title)
                .font(.subheadline)
                .foregroundStyle(Color.textSecondary)
        }
    }
}

// MARK: - Sheet 高度测量

struct SheetHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}