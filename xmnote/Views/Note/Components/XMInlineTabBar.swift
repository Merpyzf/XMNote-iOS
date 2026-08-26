/**
 * [INPUT]: 依赖 SwiftUI Binding、稳定 Hashable 身份与 DesignTokens，接收 2-5 个互斥子页面入口及当前选中项
 * [OUTPUT]: 对外提供 XMInlineTabItem 与 XMInlineTabBar，以左对齐内容流、选中胶囊和局部动效统一内容区子页面切换
 * [POS]: Views/Note/Components 的笔记集合私有分类切换组件，不作为跨模块公共控件暴露
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 内容区 Inline Tab 的局部排版 owner，在辅助导航与正文之间保持 14pt 中间档。
private enum XMInlineTabTypography {
    static let label: Font = AppTypography.fixed(
        baseSize: 14,
        relativeTo: .footnote,
        minimumPointSize: 14
    )
    static let selectedLabel: Font = AppTypography.fixed(
        baseSize: 14,
        relativeTo: .footnote,
        weight: .semibold,
        minimumPointSize: 14
    )
}

/// 内容区子页面的稳定入口模型，隔离业务身份、展示标题与无障碍文案。
struct XMInlineTabItem<ID: Hashable>: Identifiable, Hashable {
    let id: ID
    let title: String
    let accessibilityTitle: String?

    /// 注入稳定身份、可见标题与可选无障碍标题，供切换组件复用。
    init(id: ID, title: String, accessibilityTitle: String? = nil) {
        self.id = id
        self.title = title
        self.accessibilityTitle = accessibilityTitle
    }
}

/// 内容区子页面切换器；路由保持硬切，仅让选中胶囊保留连续视觉身份。
struct XMInlineTabBar<ID: Hashable>: View {
    let items: [XMInlineTabItem<ID>]
    @Binding private var selection: ID
    let accessibilityLabel: String

    @Namespace private var selectionNamespace
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.isEnabled) private var isEnabled
    @State private var visualSelection: ID?
    @ScaledMetric(relativeTo: .subheadline) private var selectionVisualHeight = XMInlineTabMetrics.selectionVisualHeight
    @ScaledMetric(relativeTo: .subheadline) private var labelHorizontalPadding = XMInlineTabMetrics.labelHorizontalPadding

    /// 注入入口集合、选中绑定与无障碍组名；视觉规格由组件统一维护，不向页面开放样式分支。
    init(
        items: [XMInlineTabItem<ID>],
        selection: Binding<ID>,
        accessibilityLabel: String = "子页面"
    ) {
        self.items = items
        self._selection = selection
        self.accessibilityLabel = accessibilityLabel
    }

    var body: some View {
        Group {
            if hasValidConfiguration {
                tabLayout
            } else {
                EmptyView()
            }
        }
        .opacity(isEnabled ? 1 : XMInlineTabMetrics.disabledOpacity)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilityLabel)
        .onAppear(perform: synchronizeVisualSelectionWithoutAnimation)
        .onChange(of: selection) { _, newSelection in
            updateVisualSelection(newSelection, animated: true)
        }
        .onChange(of: items) { _, _ in
            synchronizeVisualSelectionWithoutAnimation()
        }
    }

    private var hasValidConfiguration: Bool {
        let hasSupportedCount = XMInlineTabMetrics.supportedItemCount.contains(items.count)
        let containsSelection = items.contains { $0.id == selection }

        #if DEBUG
        assert(
            hasSupportedCount,
            "XMInlineTabBar requires 2-5 items, got \(items.count)."
        )
        assert(
            containsSelection,
            "XMInlineTabBar selection must match one item id."
        )
        #endif

        return hasSupportedCount && containsSelection
    }

    private var displayedSelection: ID {
        guard let visualSelection, items.contains(where: { $0.id == visualSelection }) else {
            return selection
        }
        return visualSelection
    }

    private var tabLayout: some View {
        ScrollView(.horizontal) {
            HStack(spacing: XMInlineTabMetrics.itemSpacing) {
                ForEach(items) { item in
                    tabButton(item)
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
        }
        .scrollIndicators(.hidden)
        .frame(height: XMInlineTabMetrics.trackHeight)
    }

    private func tabButton(_ item: XMInlineTabItem<ID>) -> some View {
        let isSelected = displayedSelection == item.id

        return Button {
            select(item.id)
        } label: {
            Text(item.title)
                .font(isSelected ? XMInlineTabTypography.selectedLabel : XMInlineTabTypography.label)
                .foregroundStyle(isSelected ? Color.textPrimary : Color.textSecondary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.horizontal, labelHorizontalPadding)
                .frame(
                    minWidth: InteractionMetrics.minimumTouchTarget,
                    minHeight: selectionVisualHeight
                )
                .background {
                    selectionBackground(isSelected: isSelected)
                }
                .frame(minHeight: InteractionMetrics.minimumTouchTarget)
                .contentShape(Rectangle())
        }
        .buttonStyle(XMInlineTabButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(item.accessibilityTitle ?? item.title)
        .accessibilityValue(isSelected ? "已选中" : "未选中")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    @ViewBuilder
    private func selectionBackground(isSelected: Bool) -> some View {
        if isSelected {
            Capsule()
                .fill(Color.surfaceCard)
                .overlay {
                    Capsule()
                        .stroke(
                            Color.surfaceBorderSubtle.opacity(XMInlineTabMetrics.selectionStrokeOpacity),
                            lineWidth: StrokeWidth.hairline
                        )
                }
                .shadow(
                    color: Color.black.opacity(XMInlineTabMetrics.selectionShadowOpacity),
                    radius: XMInlineTabMetrics.selectionShadowRadius,
                    x: Spacing.none,
                    y: XMInlineTabMetrics.selectionShadowOffsetY
                )
                .matchedGeometryEffect(id: XMInlineTabMetrics.selectionMatchedID, in: selectionNamespace)
        }
    }

    /// 先以无动画事务更新业务 selection，再单独驱动胶囊位移，避免动画污染内容宿主。
    private func select(_ newSelection: ID) {
        guard selection != newSelection else { return }

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            selection = newSelection
        }
        updateVisualSelection(newSelection, animated: true)
    }

    /// 同步外部 selection 的视觉身份；Reduce Motion 下即时落位，不移除选中反馈。
    private func updateVisualSelection(_ newSelection: ID, animated: Bool) {
        guard visualSelection != newSelection else { return }
        guard items.contains(where: { $0.id == newSelection }) else { return }

        if animated, !reduceMotion {
            withAnimation(.snappy(duration: XMInlineTabMetrics.selectionAnimationDuration)) {
                visualSelection = newSelection
            }
        } else {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                visualSelection = newSelection
            }
        }
    }

    /// 首次挂载或入口集合变化时无动画校准，避免恢复态从错误位置滑入。
    private func synchronizeVisualSelectionWithoutAnimation() {
        guard items.contains(where: { $0.id == selection }) else { return }
        updateVisualSelection(selection, animated: false)
    }
}

private enum XMInlineTabMetrics {
    static let supportedItemCount = 2...5
    static let trackHeight: CGFloat = InteractionMetrics.minimumTouchTarget
    static let selectionVisualHeight: CGFloat = 34
    static let labelHorizontalPadding: CGFloat = 12
    static let itemSpacing: CGFloat = 12
    static let selectionStrokeOpacity: Double = 0.32
    static let selectionShadowOpacity: Double = 0.025
    static let selectionShadowRadius: CGFloat = 2
    static let selectionShadowOffsetY: CGFloat = 1
    static let selectionAnimationDuration: TimeInterval = 0.22
    static let pressAnimationDuration: TimeInterval = 0.12
    static let pressedOpacity: Double = 0.88
    static let pressedScale: CGFloat = 0.985
    static let disabledOpacity: Double = 0.38
    static let selectionMatchedID = "xm-inline-tab-selection"
}

private struct XMInlineTabButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    /// 以轻量透明度和缩放确认按下，不改变布局或延迟高频切换。
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? XMInlineTabMetrics.pressedOpacity : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? XMInlineTabMetrics.pressedScale : 1)
            .animation(
                reduceMotion ? nil : .snappy(duration: XMInlineTabMetrics.pressAnimationDuration),
                value: configuration.isPressed
            )
    }
}

#Preview("XMInlineTabBar") {
    @Previewable @State var selection = "excerpts"

    XMInlineTabBar(
        items: [
            XMInlineTabItem(id: "excerpts", title: "书摘"),
            XMInlineTabItem(id: "chapters", title: "星标章节"),
            XMInlineTabItem(id: "related", title: "相关"),
            XMInlineTabItem(id: "reviews", title: "书评")
        ],
        selection: $selection,
        accessibilityLabel: "笔记分类"
    )
    .background(Color.surfacePage)
}
