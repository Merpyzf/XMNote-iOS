/**
 * [INPUT]: 依赖搜索历史词数组、展开/编辑状态绑定、编辑态展开策略与按下/取消按下/点击/删除/清空回调，依赖 DesignTokens、SwiftUI Layout 与可选 Liquid Glass 效果
 * [OUTPUT]: 对外提供 XMSearchHistorySection、XMSearchHistoryStyle、XMSearchHistoryEmptyPresentation，统一渲染搜索历史浏览态、编辑态、可选空态、流式胶囊与可选提前按下捕获
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
    let expandsWhenEditing: Bool
    let onBeginSelect: ((String) -> Void)?
    let onCancelBeginSelect: ((String) -> Void)?
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
        emptyPresentation: XMSearchHistoryEmptyPresentation = .hidden,
        expandsWhenEditing: Bool = true,
        onBeginSelect: ((String) -> Void)? = nil,
        onCancelBeginSelect: ((String) -> Void)? = nil,
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
        self.expandsWhenEditing = expandsWhenEditing
        self.onBeginSelect = onBeginSelect
        self.onCancelBeginSelect = onCancelBeginSelect
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
                    queryFlow(visibleItems: arrangement.visibleItems)
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
            HStack(spacing: Spacing.half) {
                Button(action: onClearAll) {
                    Text("清空")
                        .font(AppTypography.captionMedium)
                        .foregroundStyle(Color.feedbackError)
                        .frame(minWidth: XMSearchHistoryMetrics.headerActionMinWidth)
                        .frame(minHeight: XMSearchHistoryMetrics.headerActionTapHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清空全部搜索历史")

                Button {
                    withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.18)) {
                        isEditing = false
                        isExpanded = false
                    }
                } label: {
                    Text("完成")
                        .font(AppTypography.captionMedium)
                        .foregroundStyle(Color.brand)
                        .frame(minWidth: XMSearchHistoryMetrics.headerActionMinWidth)
                        .frame(minHeight: XMSearchHistoryMetrics.headerActionTapHeight)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("完成编辑搜索历史")
            }
            .transition(.opacity)
        } else {
            Button {
                withAnimation(reduceMotion ? .easeOut(duration: 0.12) : .snappy(duration: 0.18)) {
                    isEditing = true
                    if expandsWhenEditing {
                        isExpanded = true
                    }
                }
            } label: {
                Text("编辑")
                    .font(AppTypography.captionMedium)
                    .foregroundStyle(Color.textSecondary)
                    .frame(minWidth: XMSearchHistoryMetrics.headerActionMinWidth)
                    .frame(minHeight: XMSearchHistoryMetrics.headerActionTapHeight)
                    .contentShape(Rectangle())
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
    private func queryFlow(visibleItems: [XMSearchHistoryChipLayoutItem]) -> some View {
        if style == .glass {
            GlassEffectContainer(spacing: XMSearchHistoryMetrics.chipSpacing) {
                flowLayout(visibleItems: visibleItems)
            }
        } else {
            flowLayout(visibleItems: visibleItems)
        }
    }

    private func flowLayout(visibleItems: [XMSearchHistoryChipLayoutItem]) -> some View {
        XMSearchHistoryFlowLayout(
            horizontalSpacing: XMSearchHistoryMetrics.chipSpacing,
            verticalSpacing: XMSearchHistoryMetrics.rowSpacing
        ) {
            ForEach(visibleItems) { item in
                XMSearchHistoryChip(
                    query: item.query,
                    style: style,
                    isEditing: isEditing,
                    visualWidth: item.visualWidth,
                    hitWidth: item.hitWidth,
                    textWidth: item.textWidth,
                    onBeginSelect: {
                        guard !isEditing else { return }
                        onBeginSelect?(item.query)
                    },
                    onCancelBeginSelect: {
                        guard !isEditing else { return }
                        onCancelBeginSelect?(item.query)
                    },
                    onSelect: {
                        guard !isEditing else { return }
                        onSelect(item.query)
                    },
                    onRemove: {
                        onRemove(item.query)
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
            return XMSearchHistoryArrangement(visibleItems: [], showsToggle: false)
        }

        let layoutItems = layoutItems(for: availableWidth)
        let resolvedWidth = max(availableWidth, 0)
        guard resolvedWidth > 1 else {
            return XMSearchHistoryArrangement(visibleItems: layoutItems, showsToggle: false)
        }

        var rows: [[XMSearchHistoryChipLayoutItem]] = [[]]
        var currentRowWidth: CGFloat = 0

        for item in layoutItems {
            let measuredWidth = item.hitWidth
            let nextWidth = rows[rows.count - 1].isEmpty
                ? measuredWidth
                : currentRowWidth + XMSearchHistoryMetrics.chipSpacing + measuredWidth

            if nextWidth > resolvedWidth && !rows[rows.count - 1].isEmpty {
                rows.append([item])
                currentRowWidth = measuredWidth
            } else {
                rows[rows.count - 1].append(item)
                currentRowWidth = nextWidth
            }
        }

        let showsToggle = rows.count > XMSearchHistoryMetrics.collapsedRowLimit
        let showsAllQueries = isExpanded || (isEditing && expandsWhenEditing)
        let visibleItems = showsAllQueries || !showsToggle
            ? layoutItems
            : Array(rows.prefix(XMSearchHistoryMetrics.collapsedRowLimit).joined())
        return XMSearchHistoryArrangement(visibleItems: visibleItems, showsToggle: showsToggle && !isEditing)
    }

    /// 生成渲染同源的胶囊布局数据，保证折叠判断与真实 chip 尺寸使用同一套宽度。
    private func layoutItems(for availableWidth: CGFloat) -> [XMSearchHistoryChipLayoutItem] {
        let maximumChipWidth = availableWidth > 1 ? availableWidth : nil
        return queries.map { query in
            layoutItem(for: query, maximumChipWidth: maximumChipWidth)
        }
    }

    private func layoutItem(for query: String, maximumChipWidth: CGFloat?) -> XMSearchHistoryChipLayoutItem {
        let font = AppTypography.uiSemantic(.footnote, weight: .medium)
        let textWidth = (query as NSString).size(withAttributes: [.font: font]).width.rounded(.up)
        let reservedWidth = XMSearchHistoryMetrics.labelLeadingPadding
            + XMSearchHistoryMetrics.labelTrailingPadding(isEditing: isEditing)
            + (isEditing ? XMSearchHistoryMetrics.removeActionSlotWidth : 0)
        let maximumTextWidth = maximumChipWidth.map {
            max($0 - reservedWidth, 0)
        } ?? .greatestFiniteMagnitude
        let resolvedTextWidth = min(textWidth, maximumTextWidth)
        let intrinsicVisualWidth = resolvedTextWidth + reservedWidth
        let visualWidth = min(intrinsicVisualWidth, maximumChipWidth ?? intrinsicVisualWidth)
        let hitWidth = min(
            max(visualWidth, XMSearchHistoryMetrics.minimumChipHitWidth),
            maximumChipWidth ?? max(visualWidth, XMSearchHistoryMetrics.minimumChipHitWidth)
        )
        return XMSearchHistoryChipLayoutItem(
            query: query,
            visualWidth: visualWidth,
            hitWidth: hitWidth,
            textWidth: resolvedTextWidth
        )
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
    let visualWidth: CGFloat
    let hitWidth: CGFloat
    let textWidth: CGFloat
    let onBeginSelect: () -> Void
    let onCancelBeginSelect: () -> Void
    let onSelect: () -> Void
    let onRemove: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasReportedSelectionPress = false
    @State private var hasCancelledSelectionPress = false
    @State private var shouldSuppressSelectionAction = false

    var body: some View {
        ZStack(alignment: .leading) {
            Button(action: selectIfAllowed) {
                surfacedChip
                    .contentShape(Capsule())
            }
            .buttonStyle(XMSearchHistoryPressButtonStyle(reduceMotion: reduceMotion))
            .disabled(isEditing)
            .accessibilityLabel("搜索 \(query)")
            .accessibilityHidden(isEditing)

            removeButtonOverlay
        }
        .frame(width: hitWidth, alignment: .leading)
        .frame(minHeight: XMSearchHistoryMetrics.chipTapHeight, alignment: .leading)
        .simultaneousGesture(selectionPressGesture)
        .animation(editAnimation, value: isEditing)
    }

    private var editAnimation: Animation? {
        reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.26)
    }

    /// 在 Button action 之前捕获按下意图；若移动超过点击容差，则取消 fallback，避免滚动历史时误提交搜索。
    private var selectionPressGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { value in
                guard !isEditing, !hasCancelledSelectionPress else { return }
                if shouldCancelSelectionPress(for: value.translation) {
                    hasCancelledSelectionPress = true
                    shouldSuppressSelectionAction = true
                    if hasReportedSelectionPress {
                        onCancelBeginSelect()
                    }
                    return
                }
                guard !hasReportedSelectionPress else { return }
                hasReportedSelectionPress = true
                onBeginSelect()
            }
            .onEnded { _ in
                hasReportedSelectionPress = false
                hasCancelledSelectionPress = false
                DispatchQueue.main.async {
                    shouldSuppressSelectionAction = false
                }
            }
    }

    private func shouldCancelSelectionPress(for translation: CGSize) -> Bool {
        max(abs(translation.width), abs(translation.height)) > XMSearchHistoryMetrics.selectionCancelDistance
    }

    private func selectIfAllowed() {
        guard !shouldSuppressSelectionAction else { return }
        onSelect()
    }

    private var surfacedChip: some View {
        visualContent
            .frame(width: visualWidth, alignment: .leading)
            .modifier(XMSearchHistoryChipSurface(style: style))
            .frame(width: hitWidth, alignment: .leading)
            .frame(minHeight: XMSearchHistoryMetrics.chipTapHeight, alignment: .leading)
    }

    private var visualContent: some View {
        HStack(spacing: Spacing.none) {
            queryLabel
                .accessibilityLabel(isEditing ? "搜索词 \(query)" : "搜索 \(query)")

            Color.clear
                .frame(width: isEditing ? XMSearchHistoryMetrics.removeActionSlotWidth : 0)
        }
        .frame(minHeight: XMSearchHistoryMetrics.chipTapHeight, alignment: .leading)
    }

    private var removeButtonOverlay: some View {
        Button(action: onRemove) {
            Image(systemName: "xmark.circle.fill")
                .font(AppTypography.captionSemibold)
                .foregroundStyle(Color.iconSecondary.opacity(0.58))
                .frame(
                    width: XMSearchHistoryMetrics.removeButtonIconSize,
                    height: XMSearchHistoryMetrics.removeButtonIconSize
                )
                .frame(
                    width: XMSearchHistoryMetrics.removeButtonHitWidth,
                    height: XMSearchHistoryMetrics.chipTapHeight
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(XMSearchHistoryPressButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel("删除搜索词 \(query)")
        .accessibilityHidden(!isEditing)
        .allowsHitTesting(isEditing)
        .opacity(isEditing ? 1 : 0)
        .scaleEffect(reduceMotion || isEditing ? 1 : 0.82)
        .offset(x: removeButtonOffset)
        .frame(width: hitWidth, height: XMSearchHistoryMetrics.chipTapHeight, alignment: .leading)
    }

    private var removeButtonOffset: CGFloat {
        let trailingPosition = max(
            visualWidth - XMSearchHistoryMetrics.removeButtonHitWidth,
            0
        )
        let collapsedDrift = reduceMotion || isEditing
            ? 0
            : XMSearchHistoryMetrics.removeButtonCollapsedDrift
        return trailingPosition + collapsedDrift
    }

    private var queryLabel: some View {
        Text(query)
            .font(AppTypography.semantic(.footnote, weight: .medium))
            .foregroundStyle(Color.textSecondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: textWidth, alignment: .leading)
            .padding(.leading, XMSearchHistoryMetrics.labelLeadingPadding)
            .padding(.trailing, XMSearchHistoryMetrics.labelTrailingPadding(isEditing: isEditing))
            .frame(minHeight: XMSearchHistoryMetrics.chipTapHeight, alignment: .leading)
            .accessibilityHidden(!isEditing)
    }
}

/// 搜索历史胶囊表层，只绘制真实视觉宽度，透明命中区由外层 hitWidth 承担。
private struct XMSearchHistoryChipSurface: ViewModifier {
    let style: XMSearchHistoryStyle

    func body(content: Content) -> some View {
        switch style {
        case .content:
            content
                .background {
                    Capsule()
                        .fill(Color.controlFillSecondary.opacity(0.56))
                        .padding(.vertical, XMSearchHistoryMetrics.chipVisualInset)
                }
                .overlay {
                    Capsule()
                        .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
                        .padding(.vertical, XMSearchHistoryMetrics.chipVisualInset)
                }
        case .glass:
            content
                .glassEffect(.regular.interactive(), in: .capsule)
        }
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
    let visibleItems: [XMSearchHistoryChipLayoutItem]
    let showsToggle: Bool
}

/// 搜索历史单个关键词的确定布局数据，避免 Layout 测量阶段把短词胶囊横向拉满。
private struct XMSearchHistoryChipLayoutItem: Identifiable {
    let query: String
    let visualWidth: CGFloat
    let hitWidth: CGFloat
    let textWidth: CGFloat

    var id: String { query }
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
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: nil, height: nil))
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
    static let chipVisualInset: CGFloat = (chipTapHeight - chipVisualHeight) / 2
    static let chipHorizontalPadding: CGFloat = 12
    static let labelLeadingPadding: CGFloat = chipHorizontalPadding
    static let minimumChipHitWidth: CGFloat = 44
    static let chipSpacing: CGFloat = Spacing.cozy
    static let rowSpacing: CGFloat = Spacing.tight
    static let toggleTopSpacing: CGFloat = Spacing.tiny
    static let removeActionSlotWidth: CGFloat = 30
    static let removeButtonIconSize: CGFloat = 16
    static let removeButtonHitWidth: CGFloat = 32
    static let removeButtonCollapsedDrift: CGFloat = 8
    static let headerActionMinWidth: CGFloat = 44
    static let headerActionTapHeight: CGFloat = 44
    static let selectionCancelDistance: CGFloat = 10
    static let emptyStateMinHeight: CGFloat = 132

    static func labelTrailingPadding(isEditing: Bool) -> CGFloat {
        isEditing ? Spacing.compact : chipHorizontalPadding
    }
}
