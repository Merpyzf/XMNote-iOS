/**
 * [INPUT]: 依赖 XMTagLabel、XMSheetScaffold、SwiftUI Layout 与 DesignTokens，并接收查看器的只读标签列表
 * [OUTPUT]: 对外提供 ContentViewerTagSheet，以实际可用宽度换行承载书摘标签只读浏览
 * [POS]: Views/Content/Sheets 的页面业务 Sheet；由 ContentViewerView 呈现
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 标签查看弹层，统一承接书摘标签只读浏览体验。
struct ContentViewerTagSheet: View {
    let tags: [String]
    let onDismiss: () -> Void

    var body: some View {
        XMSheetScaffold(
            title: "标签",
            subtitle: tags.isEmpty ? nil : "共 \(tags.count) 个",
            onClose: onDismiss
        ) {
            Group {
                if tags.isEmpty {
                    XMContentStateView(
                        role: .empty,
                        title: "书摘没有标签"
                    )
                    .frame(maxWidth: .infinity, minHeight: 180)
                } else {
                    ContentViewerTagFlowLayout(
                        horizontalSpacing: Spacing.cozy,
                        verticalSpacing: Spacing.cozy
                    ) {
                        ForEach(tags, id: \.self) { tag in
                            XMTagLabel(tag)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(Spacing.screenEdge)
        }
    }
}

/// Viewer 私有标签流式布局，按容器实际宽度换行，不把单一只读 Sheet 晋升为公共能力。
private struct ContentViewerTagFlowLayout: Layout {
    let horizontalSpacing: CGFloat
    let verticalSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let availableWidth = proposal.width ?? .greatestFiniteMagnitude
        let rows = rows(for: subviews, availableWidth: availableWidth)
        let width = proposal.width ?? rows.map(\.width).max() ?? 0
        let height = rows.enumerated().reduce(CGFloat.zero) { partial, entry in
            partial + entry.element.height + (entry.offset == rows.startIndex ? 0 : verticalSpacing)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        var originY = bounds.minY
        for row in rows(for: subviews, availableWidth: bounds.width) {
            var originX = bounds.minX
            for item in row.items {
                item.subview.place(
                    at: CGPoint(x: originX, y: originY),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                originX += item.size.width + horizontalSpacing
            }
            originY += row.height + verticalSpacing
        }
    }

    private func rows(for subviews: Subviews, availableWidth: CGFloat) -> [Row] {
        var rows: [Row] = []
        var current = Row()

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let nextWidth = current.items.isEmpty
                ? size.width
                : current.width + horizontalSpacing + size.width

            if !current.items.isEmpty, nextWidth > availableWidth {
                rows.append(current)
                current = Row()
            }

            current.items.append(Item(subview: subview, size: size))
            current.width = current.items.count == 1
                ? size.width
                : current.width + horizontalSpacing + size.width
            current.height = max(current.height, size.height)
        }

        if !current.items.isEmpty {
            rows.append(current)
        }
        return rows
    }

    private struct Item {
        let subview: LayoutSubview
        let size: CGSize
    }

    private struct Row {
        var items: [Item] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }
}
