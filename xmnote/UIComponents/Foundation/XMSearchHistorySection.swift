/**
 * [INPUT]: 依赖搜索历史词数组、展开/编辑状态绑定与点击/删除/清空回调，依赖 DesignTokens、SwiftUI Layout 与可选 Liquid Glass 效果
 * [OUTPUT]: 对外提供 XMSearchHistorySection、XMSearchHistoryStyle、XMSearchHistoryEmptyPresentation，统一渲染搜索历史浏览态、编辑态、空态与流式胶囊
 * [POS]: UIComponents/Foundation 的通用搜索历史基础组件，被全局搜索、书籍搜索与 Debug 测试页复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 搜索历史组件的视觉样式；content 用于普通内容流，glass 用于 iOS 26 功能浮层验证场景。
enum XMSearchHistoryStyle: String, CaseIterable, Identifiable {
    case content
    case glass

    var id: Self { self }

    var title: String {
        switch self {
        case .content:
            return "内容层"
        case .glass:
            return "玻璃层"
        }
    }
}

/// 搜索历史为空时的展示策略，让业务页可以隐藏辅助区，测试页可以显式验证空态。
enum XMSearchHistoryEmptyPresentation {
    case hidden
    case message(title: String, subtitle: String?)

    var isVisible: Bool {
        switch self {
        case .hidden:
            return false
        case .message:
            return true
        }
    }
}

/// 通用搜索历史区块，负责展示最近搜索词、浏览/编辑模式、历史空态、单条删除、清空全部与折叠展开交互。
struct XMSearchHistorySection: View {
    let queries: [String]
    @Binding var isExpanded: Bool
    @Binding var isEditing: Bool
    let style: XMSearchHistoryStyle
    let title: String
    let emptyPresentation: XMSearchHistoryEmptyPresentation
    let onSelect: (String) -> Void
    let onRemove: (String) -> Void
    let onClearAll: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var containerWidth: CGFloat = 0

    /// 注入搜索历史展示数据与交互回调，组件本身不持有业务搜索状态或持久化依赖。
    init(
        queries: [String],
        isExpanded: Binding<Bool>,
        isEditing: Binding<Bool> = .constant(false),
        style: XMSearchHistoryStyle = .content,
        title: String = "最近搜索",
        emptyPresentation: XMSearchHistoryEmptyPresentation = .message(
            title: "暂无搜索历史",
            subtitle: "确认搜索后会出现在这里"
        ),
        onSelect: @escaping (String) -> Void,
        onRemove: @escaping (String) -> Void,
        onClearAll: @escaping () -> Void
    ) {
        self.queries = queries
        self._isExpanded = isExpanded
        self._isEditing = isEditing
        self.style = style
        self.title = title
        self.emptyPresentation = emptyPresentation
        self.onSelect = onSelect
        self.onRemove = onRemove
        self.onClearAll = onClearAll
    }

    @ViewBuilder
    var body: some View {
        let arrangement = arrangement(for: containerWidth)

        if shouldRenderSection {
            VStack(alignment: .leading, spacing: Spacing.tight) {
                header

                if queries.isEmpty {
                    emptyState
                        .transition(.opacity)
                } else {
                    queryFlow(visibleQueries: arrangement.visibleQueries)
                        .transition(.opacity)

                    if arrangement.showsToggle {
                        toggleRow
                            .transition(.opacity)
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
            .onChange(of: queries) { _, newValue in
                if newValue.isEmpty {
                    isEditing = false
                    isExpanded = false
                }
            }
            .animation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.22), value: isExpanded)
            .animation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.18), value: isEditing)
            .animation(reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.18), value: queries)
        }
    }

    private var shouldRenderSection: Bool {
        !queries.isEmpty || emptyPresentation.isVisible
    }

    private var header: some View {
        HStack(alignment: .center, spacing: Spacing.half) {
            Image(systemName: "clock.arrow.trianglehead.counterclockwise.rotate.90")
                .font(AppTypography.captionSemibold)
                .foregroundStyle(Color.textSecondary)
                .accessibilityHidden(true)

            Text(title)
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.textSecondary)

            Spacer(minLength: Spacing.base)

            if !queries.isEmpty {
                headerActions
            }
        }
    }

    @ViewBuilder
    private var headerActions: some View {
        if isEditing {
            HStack(spacing: Spacing.base) {
                Button(action: onClearAll) {
                    Text("清空")
                        .font(AppTypography.captionMedium)
                        .foregroundStyle(Color.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空全部搜索历史")

                Button {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.18)) {
                        isEditing = false
                    }
                } label: {
                    Text("完成")
                        .font(AppTypography.captionMedium)
                        .foregroundStyle(Color.brand)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("完成编辑搜索历史")
            }
            .transition(.opacity)
        } else {
            Button {
                withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.18)) {
                    isEditing = true
                }
            } label: {
                Text("编辑")
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(Color.textSecondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("编辑搜索历史")
            .transition(.opacity)
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        switch emptyPresentation {
        case .hidden:
            EmptyView()
        case .message(let emptyTitle, let emptySubtitle):
            VStack(spacing: Spacing.half) {
                Image(systemName: "clock")
                    .font(AppTypography.title2)
                    .foregroundStyle(Color.iconSecondary.opacity(0.5))
                    .accessibilityHidden(true)

                Text(emptyTitle)
                    .font(AppTypography.subheadlineMedium)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.center)

                if let emptySubtitle, !emptySubtitle.isEmpty {
                    Text(emptySubtitle)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textHint)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: XMSearchHistoryMetrics.emptyStateMinHeight)
            .padding(.vertical, Spacing.base)
            .padding(.horizontal, Spacing.contentEdge)
            .background(Color.surfaceCard.opacity(0.72), in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                    .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
            }
        }
    }

    @ViewBuilder
    private func queryFlow(visibleQueries: [String]) -> some View {
        if style == .glass {
            GlassEffectContainer(spacing: XMSearchHistoryMetrics.chipSpacing) {
                flowLayout(visibleQueries: visibleQueries)
            }
        } else {
            flowLayout(visibleQueries: visibleQueries)
        }
    }

    private func flowLayout(visibleQueries: [String]) -> some View {
        XMSearchHistoryFlowLayout(
            horizontalSpacing: XMSearchHistoryMetrics.chipSpacing,
            verticalSpacing: XMSearchHistoryMetrics.rowSpacing
        ) {
            ForEach(visibleQueries, id: \.self) { query in
                XMSearchHistoryChip(
                    query: query,
                    style: style,
                    isEditing: isEditing,
                    maximumWidth: containerWidth,
                    onSelect: {
                        guard !isEditing else { return }
                        onSelect(query)
                    },
                    onRemove: {
                        onRemove(query)
                    }
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var toggleRow: some View {
        HStack {
            Spacer(minLength: 0)

            Button {
                withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.22)) {
                    isExpanded.toggle()
                }
            } label: {
                Label(isExpanded ? "收起" : "更多", systemImage: isExpanded ? "chevron.up" : "chevron.down")
                    .font(AppTypography.footnoteSemibold)
                    .foregroundStyle(Color.brand)
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, XMSearchHistoryMetrics.chipHorizontalPadding)
                    .frame(minHeight: XMSearchHistoryMetrics.chipVisualHeight)
            }
            .buttonStyle(XMSearchHistoryPressButtonStyle(reduceMotion: reduceMotion))
            .background(Color.tagBackground.opacity(0.92), in: Capsule())
            .overlay {
                Capsule()
                    .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
            }
            .frame(minHeight: XMSearchHistoryMetrics.chipTapHeight)
            .accessibilityLabel(isExpanded ? "收起搜索历史" : "展开更多搜索历史")
        }
        .padding(.top, XMSearchHistoryMetrics.toggleTopSpacing)
    }

    /// 根据当前容器宽度计算折叠态展示范围，保证折叠判断与真实胶囊宽度同源。
    private func arrangement(for availableWidth: CGFloat) -> XMSearchHistoryArrangement {
        guard !queries.isEmpty else {
            return XMSearchHistoryArrangement(visibleQueries: [], showsToggle: false)
        }

        let resolvedWidth = max(availableWidth, 0)
        guard resolvedWidth > 1 else {
            return XMSearchHistoryArrangement(visibleQueries: queries, showsToggle: false)
        }

        var rows: [[String]] = [[]]
        var currentRowWidth: CGFloat = 0

        for query in queries {
            let measuredWidth = min(
                max(width(for: query), XMSearchHistoryMetrics.minimumChipWidth),
                resolvedWidth
            )
            let nextWidth = rows[rows.count - 1].isEmpty
                ? measuredWidth
                : currentRowWidth + XMSearchHistoryMetrics.chipSpacing + measuredWidth

            if nextWidth > resolvedWidth && !rows[rows.count - 1].isEmpty {
                rows.append([query])
                currentRowWidth = measuredWidth
            } else {
                rows[rows.count - 1].append(query)
                currentRowWidth = nextWidth
            }
        }

        let showsToggle = rows.count > XMSearchHistoryMetrics.collapsedRowLimit
        let visibleQueries = isExpanded || !showsToggle
            ? queries
            : Array(rows.prefix(XMSearchHistoryMetrics.collapsedRowLimit).joined())
        return XMSearchHistoryArrangement(visibleQueries: visibleQueries, showsToggle: showsToggle)
    }

    /// 用渲染同源字体测量关键词，确保短词不会被固定网格拉成竖向胶囊。
    private func width(for query: String) -> CGFloat {
        let font = AppTypography.uiSemantic(.footnote, weight: .medium)
        let textWidth = (query as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        let removeButtonWidth = isEditing
            ? Spacing.tiny + XMSearchHistoryMetrics.removeButtonSize + XMSearchHistoryMetrics.removeButtonTrailingPadding
            : 0
        return textWidth
            + XMSearchHistoryMetrics.chipHorizontalPadding * 2
            + removeButtonWidth
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

private struct XMSearchHistoryChip: View {
    let query: String
    let style: XMSearchHistoryStyle
    let isEditing: Bool
    let maximumWidth: CGFloat
    let onSelect: () -> Void
    let onRemove: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var constrainedWidth: CGFloat? {
        maximumWidth > 1 ? maximumWidth : nil
    }

    var body: some View {
        Group {
            switch style {
            case .content:
                chipContent
                    .background(Color.controlFillSecondary.opacity(0.56), in: Capsule())
                    .overlay {
                        Capsule()
                            .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
                    }
            case .glass:
                chipContent
                    .glassEffect(.regular.interactive(), in: .capsule)
            }
        }
        .buttonStyle(XMSearchHistoryPressButtonStyle(reduceMotion: reduceMotion))
        .frame(maxWidth: constrainedWidth, minHeight: XMSearchHistoryMetrics.chipTapHeight, alignment: .leading)
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.18), value: isEditing)
    }

    private var chipContent: some View {
        HStack(spacing: Spacing.tiny) {
            Button(action: onSelect) {
                Text(query)
                    .font(AppTypography.semantic(.footnote, weight: .medium))
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.leading, XMSearchHistoryMetrics.chipHorizontalPadding)
                    .padding(.trailing, isEditing ? Spacing.compact : XMSearchHistoryMetrics.chipHorizontalPadding)
                    .frame(minHeight: XMSearchHistoryMetrics.chipVisualHeight, alignment: .leading)
            }
            .buttonStyle(.plain)
            .disabled(isEditing)
            .accessibilityLabel(isEditing ? "搜索词 \(query)" : "搜索 \(query)")

            if isEditing {
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(AppTypography.captionSemibold)
                        .foregroundStyle(Color.iconSecondary.opacity(0.58))
                        .frame(width: XMSearchHistoryMetrics.removeButtonSize, height: XMSearchHistoryMetrics.chipVisualHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .padding(.trailing, XMSearchHistoryMetrics.removeButtonTrailingPadding)
                .accessibilityLabel("删除搜索词 \(query)")
                .transition(.opacity.combined(with: .scale(scale: 0.92)))
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// 搜索历史胶囊按钮样式，提供短促按压反馈并在 Reduce Motion 下关闭缩放。
private struct XMSearchHistoryPressButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.985 : 1)
            .animation(.smooth(duration: 0.16), value: configuration.isPressed)
    }
}

/// 搜索历史折叠态计算结果，只暴露当前应渲染的关键词集合与展开按钮状态。
private struct XMSearchHistoryArrangement {
    let visibleQueries: [String]
    let showsToggle: Bool
}

/// 搜索历史流式布局，按提议宽度自动换行并摆放胶囊。
private struct XMSearchHistoryFlowLayout: Layout {
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

    private func rows(for availableWidth: CGFloat?, subviews: Subviews) -> [XMSearchHistoryFlowRow] {
        guard !subviews.isEmpty else { return [] }

        let resolvedWidth = max(availableWidth ?? .greatestFiniteMagnitude, 0)
        let maxRowWidth = resolvedWidth > 1 ? resolvedWidth : .greatestFiniteMagnitude
        var rows: [XMSearchHistoryFlowRow] = []
        var currentItems: [XMSearchHistoryFlowItem] = []
        var currentWidth: CGFloat = 0
        var currentHeight: CGFloat = 0

        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: maxRowWidth, height: nil))
            let clampedSize = CGSize(width: min(size.width, maxRowWidth), height: size.height)
            let nextWidth = currentItems.isEmpty ? clampedSize.width : currentWidth + horizontalSpacing + clampedSize.width

            if nextWidth > maxRowWidth && !currentItems.isEmpty {
                rows.append(XMSearchHistoryFlowRow(items: currentItems, width: currentWidth, height: currentHeight))
                currentItems = [XMSearchHistoryFlowItem(index: index, size: clampedSize)]
                currentWidth = clampedSize.width
                currentHeight = clampedSize.height
            } else {
                currentItems.append(XMSearchHistoryFlowItem(index: index, size: clampedSize))
                currentWidth = nextWidth
                currentHeight = max(currentHeight, clampedSize.height)
            }
        }

        if !currentItems.isEmpty {
            rows.append(XMSearchHistoryFlowRow(items: currentItems, width: currentWidth, height: currentHeight))
        }
        return rows
    }
}

/// 流式布局中的单个子视图测量结果，缓存索引与布局尺寸。
private struct XMSearchHistoryFlowItem {
    let index: Int
    let size: CGSize
}

/// 流式布局中的单行信息，统一记录行内子项、行宽与行高。
private struct XMSearchHistoryFlowRow {
    let items: [XMSearchHistoryFlowItem]
    let width: CGFloat
    let height: CGFloat
}

/// 搜索历史区块布局常量，集中约束胶囊尺寸、折叠行数与空态高度。
private enum XMSearchHistoryMetrics {
    static let collapsedRowLimit = 2
    static let chipTapHeight: CGFloat = 44
    static let chipVisualHeight: CGFloat = 32
    static let chipHorizontalPadding: CGFloat = 12
    static let minimumChipWidth: CGFloat = 64
    static let chipSpacing: CGFloat = Spacing.cozy
    static let rowSpacing: CGFloat = Spacing.half
    static let toggleTopSpacing: CGFloat = Spacing.tiny
    static let removeButtonSize: CGFloat = 28
    static let removeButtonTrailingPadding: CGFloat = Spacing.compact
    static let emptyStateMinHeight: CGFloat = 132
}
