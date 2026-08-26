/**
 * [INPUT]: 依赖 SwiftUI、DesignTokens 与动态字号环境，接收索引标题、计数、搜索词及点击语义
 * [OUTPUT]: 对外提供 NoteIndexGridLayout 与 NoteIndexGridItemButton，统一笔记首页标签和相关分类的双列间距与 44pt 索引卡片规格
 * [POS]: Note/Components 页面私有索引组件，仅供笔记首页标签与相关分类复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 笔记首页双列索引的共享布局规格，保证标签与相关分类在各尺寸环境下使用同一列策略。
enum NoteIndexGridLayout {
    static let columnSpacing: CGFloat = Spacing.base
    static let rowSpacing: CGFloat = Spacing.base
    static let itemHorizontalPadding: CGFloat = Spacing.base
    static let itemSurfaceOpacity: Double = 0.72
    static let countColumnWidth: CGFloat = 48

    /// 辅助功能字号使用单列，其余尺寸统一保持双列，避免标签与相关列表随设备宽度产生列数漂移。
    static func columns(dynamicTypeSize: DynamicTypeSize) -> [GridItem] {
        if dynamicTypeSize.isAccessibilitySize {
            return [GridItem(.flexible())]
        }
        return [
            GridItem(.flexible(), spacing: columnSpacing),
            GridItem(.flexible())
        ]
    }
}

/// 索引卡片的文件内几何规格，保持当前 44pt 视觉高度而不借用触控语义令牌。
private enum NoteIndexGridItemMetrics {
    static let minimumHeight: CGFloat = 44
}

/// 标签与相关分类共用的索引按钮；业务页面只注入文案、计数和点击结果，不再各自维护视觉常量。
struct NoteIndexGridItemButton: View {
    let title: String
    let count: Int
    let searchQuery: String
    let accessibilityLabel: String
    let accessibilityHint: String
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.half) {
                highlightedTitle
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
                    .truncationMode(.tail)
                    .layoutPriority(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text("\(count.formatted())条")
                    .font(ReadingContentTypography.metadata)
                    .foregroundStyle(Color.textSecondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.85)
                    .frame(width: NoteIndexGridLayout.countColumnWidth, alignment: .trailing)
                    .contentTransition(.numericText(value: Double(count)))
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, NoteIndexGridLayout.itemHorizontalPadding)
            .frame(maxWidth: .infinity)
            .frame(minHeight: NoteIndexGridItemMetrics.minimumHeight)
            .background(
                Color.surfaceCard.opacity(NoteIndexGridLayout.itemSurfaceOpacity),
                in: RoundedRectangle(
                    cornerRadius: CornerRadius.blockMedium,
                    style: .continuous
                )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(NoteIndexGridButtonStyle(reduceMotion: reduceMotion))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
    }

    private var highlightedTitle: Text {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return Text(title) }
        var attributed = AttributedString(title)
        guard let range = attributed.range(of: query, options: .caseInsensitive) else {
            return Text(attributed)
        }
        attributed[range].foregroundColor = .keywordHighlight
        return Text(attributed)
    }
}

/// 共享索引按钮仅用透明度表达按压，保持网格尺寸和文字位置稳定。
private struct NoteIndexGridButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.72 : 1)
            .animation(
                reduceMotion ? nil : .smooth(duration: 0.12),
                value: configuration.isPressed
            )
    }
}
