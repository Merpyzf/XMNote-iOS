/**
 * [INPUT]: 依赖最近搜索词数组与点击/删除回调，依赖页面内展开状态驱动折叠与展开，依赖语义字体与设计令牌完成胶囊排布
 * [OUTPUT]: 对外提供 BookSearchRecentQueriesSection 与 SearchChipButtonStyle，渲染最近搜索标题、流式标签与展开收起交互
 * [POS]: Book 模块搜索页的页面私有子视图，服务 BookSearchView 的最近搜索展示，不承担搜索请求与导航编排
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 书籍搜索页最近搜索区块，负责按容器宽度流式排布历史关键词并管理折叠态。
struct BookSearchRecentQueriesSection: View {
    let queries: [String]
    @Binding var isExpanded: Bool
    let onTap: (String) -> Void
    let onRemove: (String) -> Void

    @State private var containerWidth: CGFloat = 0

    var body: some View {
        let arrangement = arrangement(for: containerWidth)

        VStack(alignment: .leading, spacing: Spacing.tight) {
            HStack(spacing: Spacing.half) {
                Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.textSecondary)

                Text("最近搜索")
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(Color.textSecondary)
            }

            if !arrangement.visibleQueries.isEmpty {
                BookSearchRecentQueriesFlowLayout(
                    horizontalSpacing: RecentQueriesLayoutMetrics.chipSpacing,
                    verticalSpacing: RecentQueriesLayoutMetrics.rowSpacing
                ) {
                    ForEach(arrangement.visibleQueries, id: \.self) { query in
                        recentQueryChip(query)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                if arrangement.showsToggle {
                    HStack {
                        Spacer(minLength: 0)
                        toggleChip
                    }
                    .padding(.top, RecentQueriesLayoutMetrics.toggleTopSpacing)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            GeometryReader { proxy in
                Color.clear
                    .onAppear {
                        updateContainerWidth(proxy.size.width)
                    }
                    .onChange(of: proxy.size.width) { _, newWidth in
                        updateContainerWidth(newWidth)
                    }
            }
        }
        .animation(.snappy(duration: 0.22), value: isExpanded)
        .animation(.smooth(duration: 0.18), value: queries)
    }

    private func recentQueryChip(_ query: String) -> some View {
        Button {
            onTap(query)
        } label: {
            Text(query)
                .lineLimit(1)
                .truncationMode(.tail)
                .padding(.horizontal, RecentQueriesLayoutMetrics.chipHorizontalPadding)
                .frame(minHeight: RecentQueriesLayoutMetrics.chipVisualHeight, alignment: .leading)
        }
        .buttonStyle(SearchChipButtonStyle())
        .font(AppTypography.semantic(.footnote, weight: .medium))
        .foregroundStyle(Color.textSecondary)
        .background(Color.controlFillSecondary, in: Capsule())
        .overlay {
            Capsule()
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
        }
        .frame(minHeight: RecentQueriesLayoutMetrics.chipTapHeight)
        .contentShape(Capsule())
        .contextMenu {
            Button(role: .destructive) {
                onRemove(query)
            } label: {
                Label("删除搜索词", systemImage: "trash")
            }
        }
        .tint(nil)
    }

    private var toggleChip: some View {
        Button {
            withAnimation(.snappy(duration: 0.22)) {
                isExpanded.toggle()
            }
        } label: {
            Label(isExpanded ? "收起" : "更多", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                .labelStyle(.titleAndIcon)
                .font(AppTypography.footnoteSemibold)
                .foregroundStyle(Color.brand)
                .padding(.horizontal, RecentQueriesLayoutMetrics.chipHorizontalPadding)
                .frame(minHeight: RecentQueriesLayoutMetrics.chipVisualHeight)
                .background(Color.tagBackground.opacity(0.92), in: Capsule())
                .overlay {
                    Capsule()
                        .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
                }
        }
        .buttonStyle(SearchChipButtonStyle())
        .frame(minHeight: RecentQueriesLayoutMetrics.chipTapHeight)
    }

    /// 根据当前容器宽度计算折叠态应显示的关键词集合，并决定是否展示展开按钮。
    private func arrangement(for availableWidth: CGFloat) -> RecentQueriesArrangement {
        guard !queries.isEmpty else {
            return RecentQueriesArrangement(visibleQueries: [], showsToggle: false)
        }

        let resolvedWidth = max(availableWidth, 0)
        guard resolvedWidth > 1 else {
            return RecentQueriesArrangement(visibleQueries: queries, showsToggle: false)
        }

        var rows: [[String]] = [[]]
        var currentRowWidth: CGFloat = 0

        for query in queries {
            let measuredWidth = min(
                max(width(for: query), RecentQueriesLayoutMetrics.minimumChipWidth),
                resolvedWidth
            )
            let nextWidth = rows[rows.count - 1].isEmpty
                ? measuredWidth
                : currentRowWidth + RecentQueriesLayoutMetrics.chipSpacing + measuredWidth

            if nextWidth > resolvedWidth && !rows[rows.count - 1].isEmpty {
                rows.append([query])
                currentRowWidth = measuredWidth
            } else {
                rows[rows.count - 1].append(query)
                currentRowWidth = nextWidth
            }
        }

        let showsToggle = rows.count > 2
        let visibleQueries = isExpanded || !showsToggle
            ? queries
            : Array(rows.prefix(2).joined())
        return RecentQueriesArrangement(visibleQueries: visibleQueries, showsToggle: showsToggle)
    }

    /// 使用与渲染同源的语义字体测量胶囊宽度，保证折叠态与真实流式排布一致。
    private func width(for query: String) -> CGFloat {
        let font = AppTypography.uiSemantic(.footnote, weight: .medium)
        let textWidth = (query as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        return textWidth + RecentQueriesLayoutMetrics.chipHorizontalPadding * 2
    }

    private func updateContainerWidth(_ width: CGFloat) {
        let resolvedWidth = max(width, 0)
        guard abs(resolvedWidth - containerWidth) > 0.5 else { return }
        containerWidth = resolvedWidth
        if resolvedWidth > 1, !arrangement(for: resolvedWidth).showsToggle {
            isExpanded = false
        }
    }
}

/// 搜索页胶囊按钮样式，统一轻量按压反馈，避免和结果卡的按压感冲突。
struct SearchChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.smooth(duration: 0.16), value: configuration.isPressed)
    }
}

/// 最近搜索的原生流式布局，负责按提议宽度自动换行并摆放胶囊。
private struct BookSearchRecentQueriesFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let rows = rows(for: proposal.width, subviews: subviews)
        guard !rows.isEmpty else { return .zero }

        let totalHeight = rows.reduce(CGFloat.zero) { partialResult, row in
            partialResult + row.height
        } + verticalSpacing * CGFloat(max(rows.count - 1, 0))
        let widestRow = rows.map(\.width).max() ?? 0
        return CGSize(
            width: proposal.width ?? widestRow,
            height: totalHeight
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let rows = rows(for: bounds.width, subviews: subviews)
        var currentY = bounds.minY

        for row in rows {
            var currentX = bounds.minX
            for item in row.items {
                subviews[item.index].place(
                    at: CGPoint(x: currentX, y: currentY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: item.size.width, height: item.size.height)
                )
                currentX += item.size.width + horizontalSpacing
            }
            currentY += row.height + verticalSpacing
        }
    }

    private func rows(for availableWidth: CGFloat?, subviews: Subviews) -> [FlowLayoutRow] {
        guard !subviews.isEmpty else { return [] }

        let resolvedWidth = max(availableWidth ?? .greatestFiniteMagnitude, 0)
        let maxRowWidth = resolvedWidth > 1 ? resolvedWidth : .greatestFiniteMagnitude
        var rows: [FlowLayoutRow] = []
        var currentItems: [FlowLayoutItem] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: maxRowWidth, height: nil))
            let nextWidth = currentItems.isEmpty ? size.width : currentWidth + horizontalSpacing + size.width

            if nextWidth > maxRowWidth && !currentItems.isEmpty {
                rows.append(FlowLayoutRow(items: currentItems, width: currentWidth, height: currentHeight))
                currentItems = [FlowLayoutItem(index: index, size: size)]
                currentWidth = size.width
                currentHeight = size.height
            } else {
                currentItems.append(FlowLayoutItem(index: index, size: size))
                currentWidth = nextWidth
                currentHeight = max(currentHeight, size.height)
            }
        }

        if !currentItems.isEmpty {
            rows.append(FlowLayoutRow(items: currentItems, width: currentWidth, height: currentHeight))
        }
        return rows
    }
}

/// 最近搜索折叠态计算结果，只暴露当前应渲染的关键词集合与展开按钮状态。
private struct RecentQueriesArrangement {
    let visibleQueries: [String]
    let showsToggle: Bool
}

/// 流式布局中的单个子视图测量结果，缓存索引与布局尺寸。
private struct FlowLayoutItem {
    let index: Int
    let size: CGSize
}

/// 流式布局中的单行信息，统一记录行内子项、行宽与行高。
private struct FlowLayoutRow {
    let items: [FlowLayoutItem]
    let width: CGFloat
    let height: CGFloat
}

/// 最近搜索区块的局部布局常量，统一胶囊尺寸与行间距。
private enum RecentQueriesLayoutMetrics {
    static let chipTapHeight: CGFloat = 44
    static let chipVisualHeight: CGFloat = 32
    static let chipHorizontalPadding: CGFloat = 12
    static let minimumChipWidth: CGFloat = 64
    static let chipSpacing: CGFloat = Spacing.cozy
    static let rowSpacing: CGFloat = Spacing.half
    static let toggleTopSpacing: CGFloat = Spacing.tiny
}
