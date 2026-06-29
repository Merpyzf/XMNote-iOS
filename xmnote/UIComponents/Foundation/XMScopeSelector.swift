/**
 * [INPUT]: 依赖 SwiftUI、DesignTokens 与 iOS 26 Liquid Glass 能力，承接同一内容集合内 2 个及以上互斥范围选项
 * [OUTPUT]: 对外提供 XMScopeSelector、XMScopeSelectorItem 与 XMScopeSelectorVisualStyle，统一单选范围切换控件并隔离内部选中动效
 * [POS]: UIComponents/Foundation 的范围选择基础组件，服务搜索范围、结果来源与显示模式等跨页面可复用场景
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 范围选择控件的单个选项，封装展示标题、可选数量与无障碍标题。
struct XMScopeSelectorItem<ID: Hashable>: Identifiable, Hashable {
    let id: ID
    let title: String
    let count: Int?
    let accessibilityTitle: String?

    /// 注入选项身份、标题、数量与无障碍标题，供单选范围控件渲染。
    init(
        id: ID,
        title: String,
        count: Int? = nil,
        accessibilityTitle: String? = nil
    ) {
        self.id = id
        self.title = title
        self.count = count
        self.accessibilityTitle = accessibilityTitle
    }
}

/// 范围选择控件的视觉层级，区分内容流内表达与 iOS 26 浮层功能表达。
enum XMScopeSelectorVisualStyle: Hashable {
    case content
    case floatingGlass
}

/// 范围选择控件的数量展示格式，区分原始数字与本地化分组数字。
enum XMScopeSelectorCountFormat: Hashable, CaseIterable, Identifiable {
    case plain
    case grouped

    var id: Self { self }

    /// 将数量转换成视觉展示文本；plain 保持原始数字，避免 SwiftUI 文本插值自动分组。
    func displayText(for count: Int) -> String {
        switch self {
        case .plain:
            return String(count)
        case .grouped:
            return NumberFormatter.localizedString(from: NSNumber(value: count), number: .decimal)
        }
    }
}

/// 产品级范围选择控件，用一个统一胶囊承载互斥选项并用滑动指示器表达当前范围。
struct XMScopeSelector<ID: Hashable>: View {
    let items: [XMScopeSelectorItem<ID>]
    @Binding private var selection: ID
    let style: XMScopeSelectorVisualStyle
    let countFormat: XMScopeSelectorCountFormat
    let accessibilityLabel: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var dragLocationX: CGFloat?
    @State private var isDragging = false
    @ScaledMetric(relativeTo: .subheadline) private var visualHeight: CGFloat = XMScopeSelectorMetrics.visualHeight
    @ScaledMetric(relativeTo: .subheadline) private var touchHeight: CGFloat = XMScopeSelectorMetrics.touchHeight
    @ScaledMetric(relativeTo: .caption) private var scrollableSegmentWidth: CGFloat = XMScopeSelectorMetrics.scrollableSegmentWidth

    /// 注入选项、选中绑定、视觉样式与无障碍组名，构建可复用的单选范围控件。
    init(
        items: [XMScopeSelectorItem<ID>],
        selection: Binding<ID>,
        style: XMScopeSelectorVisualStyle = .content,
        countFormat: XMScopeSelectorCountFormat = .plain,
        accessibilityLabel: String = "范围选择"
    ) {
        self.items = items
        self._selection = selection
        self.style = style
        self.countFormat = countFormat
        self.accessibilityLabel = accessibilityLabel == "范围选择" ? String(localized: "范围选择") : accessibilityLabel
    }

    var body: some View {
        if !hasValidConfiguration {
            EmptyView()
        } else {
            styledControl
                .accessibilityElement(children: .contain)
                .accessibilityLabel(accessibilityLabel)
        }
    }

    private var hasValidConfiguration: Bool {
        let hasValidItemCount = Self.hasValidItemCount(items.count)
        let containsSelection = Self.containsSelection(selection, in: items)

        #if DEBUG
        assert(
            hasValidItemCount,
            "XMScopeSelector requires at least \(XMScopeSelectorMetrics.minimumItemCount) items, got \(items.count)."
        )
        assert(
            containsSelection,
            "XMScopeSelector selection must match one item id."
        )
        #endif

        return hasValidItemCount && containsSelection
    }

    private var usesScrollableLayout: Bool {
        items.count > XMScopeSelectorMetrics.maximumFixedItemCount
    }

    @ViewBuilder
    private var styledControl: some View {
        if usesScrollableLayout {
            scrollableControl
        } else {
            fixedControl
        }
    }

    private var fixedControl: some View {
        GeometryReader { geometry in
            let controlWidth = max(geometry.size.width, XMScopeSelectorMetrics.minimumControlWidth)

            ZStack {
                shellBackground
                selectedIndicator(controlWidth: controlWidth)
                controlBody(segmentWidth: nil)
                shellBorder
            }
            .frame(width: controlWidth, height: touchHeight)
            .contentShape(Capsule())
            .highPriorityGesture(dragGesture(controlWidth: controlWidth), including: .all)
        }
        .frame(height: touchHeight)
    }

    private var scrollableControl: some View {
        GeometryReader { geometry in
            let visibleWidth = max(geometry.size.width, XMScopeSelectorMetrics.minimumControlWidth)
            let contentWidth = max(scrollableContentWidth, visibleWidth)

            ZStack {
                shellBackground
                    .allowsHitTesting(false)

                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        ZStack {
                            selectedIndicator(controlWidth: contentWidth)
                            controlBody(segmentWidth: scrollableSegmentWidth)
                        }
                        .frame(width: contentWidth, height: touchHeight)
                    }
                    .scrollIndicators(.hidden)
                    .frame(width: visibleWidth, height: touchHeight)
                    .clipShape(Capsule())
                    .contentShape(Capsule())
                    .onAppear {
                        scrollSelectionIntoView(proxy, animated: false)
                    }
                    .onChange(of: selection) { _, _ in
                        scrollSelectionIntoView(proxy, animated: !reduceMotion)
                    }
                }

                shellBorder
                    .allowsHitTesting(false)
            }
            .frame(width: visibleWidth, height: touchHeight)
            .contentShape(Capsule())
        }
        .frame(height: touchHeight)
    }

    private var scrollableContentWidth: CGFloat {
        XMScopeSelectorMetrics.containerInset * 2 + scrollableSegmentWidth * CGFloat(items.count)
    }

    private func controlBody(segmentWidth: CGFloat?) -> some View {
        HStack(spacing: Spacing.none) {
            ForEach(items) { item in
                scopeButton(for: item, segmentWidth: segmentWidth)
            }
        }
        .padding(.horizontal, XMScopeSelectorMetrics.containerInset)
        .frame(height: touchHeight)
        .contentShape(Capsule())
    }

    private var shellBackground: some View {
        Capsule()
            .fill(shellFill)
            .frame(height: visualHeight)
            .modifier(XMScopeSelectorGlassShellModifier(style: style))
    }

    private var shellBorder: some View {
        Capsule()
            .stroke(shellStroke, lineWidth: CardStyle.borderWidth)
            .frame(height: visualHeight)
    }

    private func scopeButton(for item: XMScopeSelectorItem<ID>, segmentWidth: CGFloat?) -> some View {
        let isSelected = selection == item.id

        return Button {
            select(item)
        } label: {
            if let segmentWidth {
                segmentLabel(for: item, isSelected: isSelected)
                    .frame(width: segmentWidth)
                    .frame(minHeight: touchHeight)
                    .contentShape(Rectangle())
            } else {
                segmentLabel(for: item, isSelected: isSelected)
                    .frame(maxWidth: .infinity, minHeight: touchHeight)
                    .contentShape(Rectangle())
            }
        }
        .id(item.id)
        .buttonStyle(XMScopeSelectorSegmentButtonStyle(reduceMotion: reduceMotion))
        .accessibilityLabel(accessibilityTitle(for: item))
        .accessibilityValue(isSelected ? String(localized: "已选中") : String(localized: "未选中"))
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private func selectedIndicator(controlWidth: CGFloat) -> some View {
        Capsule()
            .fill(selectionFill)
            .overlay {
                Capsule()
                    .stroke(selectionStroke, lineWidth: CardStyle.borderWidth)
            }
            .shadow(
                color: selectionShadowColor,
                radius: XMScopeSelectorMetrics.selectionShadowRadius,
                x: Spacing.none,
                y: XMScopeSelectorMetrics.selectionShadowOffsetY
            )
            .frame(
                width: indicatorWidth(controlWidth: controlWidth),
                height: max(visualHeight - XMScopeSelectorMetrics.selectionVerticalInset * 2, XMScopeSelectorMetrics.minimumSelectionHeight)
            )
            .position(
                x: indicatorCenterX(controlWidth: controlWidth),
                y: touchHeight / 2
            )
            .animation(
                isDragging || reduceMotion ? nil : .snappy(duration: XMScopeSelectorMetrics.selectionAnimationDuration),
                value: selection
            )
    }

    private func segmentLabel(for item: XMScopeSelectorItem<ID>, isSelected: Bool) -> some View {
        HStack(spacing: XMScopeSelectorMetrics.labelCountSpacing) {
            Text(item.title)
                .font(titleFont(isSelected: isSelected))
                .foregroundStyle(isSelected ? selectedTextColor : unselectedTextColor)
                .lineLimit(dynamicTypeSize >= .accessibility1 ? 2 : 1)
                .minimumScaleFactor(0.82)
                .truncationMode(.tail)
                .layoutPriority(2)

            if let count = item.count, shouldShowCountBadge {
                Text(verbatim: countFormat.displayText(for: count))
                    .font(countFont)
                    .foregroundStyle(isSelected ? selectedCountColor : unselectedCountColor)
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .contentTransition(countContentTransition(for: count))
                    .animation(countAnimation, value: count)
                    .layoutPriority(1)
                    .padding(.horizontal, XMScopeSelectorMetrics.countBadgeHorizontalPadding)
                    .padding(.vertical, Spacing.tiny)
                    .background(countBadgeFill(isSelected: isSelected), in: Capsule())
                    .accessibilityHidden(true)
            }
        }
        .padding(.horizontal, segmentHorizontalPadding)
        .frame(maxWidth: .infinity)
    }

    private func select(_ item: XMScopeSelectorItem<ID>) {
        guard selection != item.id else { return }

        if reduceMotion {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                selection = item.id
            }
        } else {
            selection = item.id
        }
    }

    private func dragGesture(controlWidth: CGFloat) -> some Gesture {
        DragGesture(minimumDistance: XMScopeSelectorMetrics.dragActivationDistance)
            .onChanged { value in
                handleDragChanged(value, controlWidth: controlWidth)
            }
            .onEnded { value in
                handleDragEnded(value, controlWidth: controlWidth)
            }
    }

    private func handleDragChanged(_ value: DragGesture.Value, controlWidth: CGFloat) {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true

        withTransaction(transaction) {
            isDragging = true
            dragLocationX = clampedIndicatorCenterX(locationX: value.location.x, controlWidth: controlWidth)

            let index = itemIndex(locationX: value.location.x, controlWidth: controlWidth)
            let nextSelection = items[index].id
            if selection != nextSelection {
                selection = nextSelection
            }
        }
    }

    private func handleDragEnded(_ value: DragGesture.Value, controlWidth: CGFloat) {
        guard isDragging else {
            dragLocationX = nil
            return
        }

        handleDragChanged(value, controlWidth: controlWidth)

        if reduceMotion {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                dragLocationX = nil
                isDragging = false
            }
        } else {
            withAnimation(.snappy(duration: XMScopeSelectorMetrics.selectionAnimationDuration)) {
                dragLocationX = nil
                isDragging = false
            }
        }
    }

    private func accessibilityTitle(for item: XMScopeSelectorItem<ID>) -> String {
        var parts = [item.accessibilityTitle ?? item.title]
        if let count = item.count {
            parts.append("\(count) \(String(localized: "项"))")
        }
        return parts.joined(separator: "，")
    }

    private func scrollSelectionIntoView(_ proxy: ScrollViewProxy, animated: Bool) {
        guard usesScrollableLayout else { return }

        if animated {
            withAnimation(.snappy(duration: XMScopeSelectorMetrics.selectionAnimationDuration)) {
                proxy.scrollTo(selection, anchor: .center)
            }
        } else {
            proxy.scrollTo(selection, anchor: .center)
        }
    }

    private static func hasValidItemCount(_ count: Int) -> Bool {
        count >= XMScopeSelectorMetrics.minimumItemCount
    }

    private static func containsSelection(_ selection: ID, in items: [XMScopeSelectorItem<ID>]) -> Bool {
        items.contains { $0.id == selection }
    }

    private var selectedItemIndex: Int {
        items.firstIndex { $0.id == selection } ?? 0
    }

    private func indicatorWidth(controlWidth: CGFloat) -> CGFloat {
        max(segmentWidth(controlWidth: controlWidth) - XMScopeSelectorMetrics.selectionHorizontalInset * 2, Spacing.none)
    }

    private func indicatorCenterX(controlWidth: CGFloat) -> CGFloat {
        if let dragLocationX {
            return dragLocationX
        }
        return segmentCenterX(index: selectedItemIndex, controlWidth: controlWidth)
    }

    private func segmentCenterX(index: Int, controlWidth: CGFloat) -> CGFloat {
        let width = segmentWidth(controlWidth: controlWidth)
        return XMScopeSelectorMetrics.containerInset + width * (CGFloat(index) + 0.5)
    }

    private func segmentWidth(controlWidth: CGFloat) -> CGFloat {
        if usesScrollableLayout {
            return scrollableSegmentWidth
        }
        let availableWidth = max(controlWidth - XMScopeSelectorMetrics.containerInset * 2, XMScopeSelectorMetrics.minimumControlWidth)
        return availableWidth / CGFloat(items.count)
    }

    private func itemIndex(locationX: CGFloat, controlWidth: CGFloat) -> Int {
        let availableWidth = max(controlWidth - XMScopeSelectorMetrics.containerInset * 2, XMScopeSelectorMetrics.minimumControlWidth)
        let segmentWidth = max(availableWidth / CGFloat(items.count), XMScopeSelectorMetrics.minimumControlWidth)
        let localX = min(max(locationX - XMScopeSelectorMetrics.containerInset, Spacing.none), availableWidth)
        let rawIndex = Int((localX / segmentWidth).rounded(.down))
        return min(max(rawIndex, 0), items.count - 1)
    }

    private func clampedIndicatorCenterX(locationX: CGFloat, controlWidth: CGFloat) -> CGFloat {
        let segmentWidth = segmentWidth(controlWidth: controlWidth)
        let minimumX = XMScopeSelectorMetrics.containerInset + segmentWidth / 2
        let maximumX = controlWidth - XMScopeSelectorMetrics.containerInset - segmentWidth / 2
        return min(max(locationX, minimumX), maximumX)
    }

    private var shouldShowCountBadge: Bool {
        if dynamicTypeSize >= .accessibility2 {
            return false
        }
        if dynamicTypeSize >= .accessibility1 && items.count >= 4 {
            return false
        }
        return true
    }

    private var segmentHorizontalPadding: CGFloat {
        if usesScrollableLayout {
            return Spacing.cozy
        }
        switch items.count {
        case XMScopeSelectorMetrics.minimumItemCount:
            return Spacing.tight
        case 3:
            return Spacing.cozy
        case 4:
            return Spacing.half
        default:
            return Spacing.compact
        }
    }

    private func titleFont(isSelected: Bool) -> Font {
        if usesScrollableLayout {
            return isSelected ? AppTypography.captionSemibold : AppTypography.captionMedium
        }
        return isSelected ? AppTypography.subheadlineSemibold : AppTypography.subheadlineMedium
    }

    private var countFont: Font {
        AppTypography.caption2Medium
    }

    private var countAnimation: Animation? {
        if reduceMotion {
            return .easeOut(duration: XMScopeSelectorMetrics.reducedMotionCountAnimationDuration)
        }
        return .snappy(duration: XMScopeSelectorMetrics.countAnimationDuration)
    }

    private func countContentTransition(for count: Int) -> ContentTransition {
        reduceMotion ? .opacity : .numericText(value: Double(count))
    }

    private func countBadgeFill(isSelected: Bool) -> Color {
        if isSelected {
            return Color.brand.opacity(0.10)
        }
        return Color.controlFillSecondary.opacity(0.42)
    }

    private var shellFill: Color {
        switch style {
        case .content:
            return Color.controlFillSecondary.opacity(0.52)
        case .floatingGlass:
            return Color.surfaceCard.opacity(0.22)
        }
    }

    private var shellStroke: Color {
        switch style {
        case .content:
            return Color.surfaceBorderSubtle.opacity(0.42)
        case .floatingGlass:
            return Color.surfaceBorderSubtle.opacity(0.28)
        }
    }

    private var selectionFill: Color {
        switch style {
        case .content:
            return Color.surfaceCard.opacity(0.98)
        case .floatingGlass:
            return Color.surfaceCard.opacity(0.92)
        }
    }

    private var selectionStroke: Color {
        switch style {
        case .content:
            return Color.surfaceBorderSubtle.opacity(0.36)
        case .floatingGlass:
            return Color.surfaceBorderSubtle.opacity(0.34)
        }
    }

    private var selectedTextColor: Color {
        switch style {
        case .content:
            return Color.textPrimary
        case .floatingGlass:
            return Color.textPrimary
        }
    }

    private var selectedCountColor: Color {
        switch style {
        case .content:
            return Color.brandDeep.opacity(0.82)
        case .floatingGlass:
            return Color.brandDeep.opacity(0.78)
        }
    }

    private var unselectedTextColor: Color {
        switch style {
        case .content:
            return Color.textSecondary.opacity(0.94)
        case .floatingGlass:
            return Color.textSecondary.opacity(0.90)
        }
    }

    private var unselectedCountColor: Color {
        switch style {
        case .content:
            return Color.textSecondary.opacity(0.70)
        case .floatingGlass:
            return Color.textSecondary.opacity(0.66)
        }
    }

    private var selectionShadowColor: Color {
        switch style {
        case .content:
            return Color.black.opacity(0.035)
        case .floatingGlass:
            return Color.black.opacity(0.025)
        }
    }
}

private enum XMScopeSelectorMetrics {
    static let minimumItemCount = 2
    static let maximumFixedItemCount = 5
    static let minimumControlWidth: CGFloat = 1
    static let visualHeight: CGFloat = 40
    static let touchHeight: CGFloat = 44
    static let scrollableSegmentWidth: CGFloat = 96
    static let containerInset: CGFloat = 3
    static let selectionVerticalInset: CGFloat = 3
    static let selectionHorizontalInset: CGFloat = 2
    static let minimumSelectionHeight: CGFloat = 30
    static let labelCountSpacing: CGFloat = Spacing.micro
    static let countBadgeHorizontalPadding: CGFloat = Spacing.micro
    static let selectionShadowRadius: CGFloat = 3
    static let selectionShadowOffsetY: CGFloat = 1
    static let selectionAnimationDuration: TimeInterval = 0.22
    static let countAnimationDuration: TimeInterval = 0.18
    static let reducedMotionCountAnimationDuration: TimeInterval = 0.12
    static let pressAnimationDuration: TimeInterval = 0.12
    static let dragActivationDistance: CGFloat = 3
}

private struct XMScopeSelectorSegmentButtonStyle: ButtonStyle {
    let reduceMotion: Bool

    /// 提供轻量按压反馈，使用 transform/opacity 避免改变布局尺寸。
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.88 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.985 : 1)
            .animation(
                reduceMotion ? nil : .snappy(duration: XMScopeSelectorMetrics.pressAnimationDuration),
                value: configuration.isPressed
            )
    }
}

private struct XMScopeSelectorGlassShellModifier: ViewModifier {
    let style: XMScopeSelectorVisualStyle

    /// 仅给整体外壳追加 iOS 26 Liquid Glass，避免玻璃吞掉前景选中态与文字。
    @ViewBuilder
    func body(content: Content) -> some View {
        switch style {
        case .content:
            content
        case .floatingGlass:
            if #available(iOS 26.0, *) {
                GlassEffectContainer(spacing: Spacing.none) {
                    content
                        .glassEffect(.regular.interactive(), in: .capsule)
                }
            } else {
                content
                    .background(.ultraThinMaterial, in: Capsule())
            }
        }
    }
}

#Preview("XMScopeSelector") {
    @Previewable @State var selection = "books"
    let items = [
        XMScopeSelectorItem(id: "books", title: "书籍", count: 28),
        XMScopeSelectorItem(id: "notes", title: "书摘", count: 12),
        XMScopeSelectorItem(id: "relevant", title: "相关", count: 6)
    ]

    VStack(spacing: Spacing.double) {
        XMScopeSelector(items: items, selection: $selection, style: .content, accessibilityLabel: "搜索范围")
        XMScopeSelector(items: items, selection: $selection, style: .floatingGlass, accessibilityLabel: "搜索范围")
    }
    .padding(Spacing.screenEdge)
    .background(Color.surfacePage)
}
