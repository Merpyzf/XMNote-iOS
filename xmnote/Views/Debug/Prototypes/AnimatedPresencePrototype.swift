#if DEBUG
/**
 * [INPUT]: 依赖 SwiftUI Layout、LayoutValueKey、onGeometryChange 与动画完成回调，接收可选展示值、结构动画和内容构造器
 * [OUTPUT]: 对外提供 AnimatedPresencePrototype 与 CollapseAwareVStackPrototype，用于验证列表行内容展开收起的连续高度和间距
 * [POS]: Debug/Prototypes 的行为基建候选，仅供测试中心和 Preview 实证，不属于生产公共组件
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 让可收起子视图的高度与相邻间距沿同一进度变化，避免高度归零后仍残留一拍间距。
struct CollapseAwareVStackPrototype: Layout {
    enum Alignment {
        case leading
        case center
        case trailing
    }

    var alignment: Alignment
    var spacing: CGFloat?

    /// 创建仅处理垂直排列与收起间距的原型布局；复杂 alignment guide 仍由内部原生容器负责。
    init(alignment: Alignment = .center, spacing: CGFloat? = nil) {
        self.alignment = alignment
        self.spacing = spacing
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        let items = measuredItems(subviews: subviews, proposedWidth: proposal.width)
        let measuredWidth = items.reduce(into: CGFloat.zero) { width, item in
            guard item.presenceProgress > 0 else { return }
            width = max(width, item.size.width)
        }
        let width = finiteNonnegative(proposal.width ?? measuredWidth)
        let height = items.reduce(into: CGFloat.zero) { total, item in
            total += item.size.height + item.spacingAfter
        }
        return CGSize(width: width, height: finiteNonnegative(height))
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        let items = measuredItems(subviews: subviews, proposedWidth: bounds.width)
        var currentY = bounds.minY

        for index in subviews.indices {
            let item = items[index]
            subviews[index].place(
                at: CGPoint(x: xOrigin(for: item.size, in: bounds), y: currentY),
                anchor: .topLeading,
                proposal: ProposedViewSize(width: bounds.width, height: item.size.height)
            )
            currentY += item.size.height + item.spacingAfter
        }
    }

    private func measuredItems(
        subviews: Subviews,
        proposedWidth: CGFloat?
    ) -> [MeasuredItem] {
        let sizes = subviews.map { subview in
            sanitized(
                subview.sizeThatFits(
                    ProposedViewSize(width: proposedWidth, height: nil)
                )
            )
        }
        let progresses = subviews.map { subview in
            clampedProgress(subview[PrototypePresenceProgressKey.self] ?? 1)
        }
        var spacings = subviews.indices.map { index in
            let nextIndex = subviews.index(after: index)
            guard nextIndex < subviews.endIndex else { return CGFloat.zero }
            return baseSpacing(previous: subviews[index], next: subviews[nextIndex])
                * min(progresses[index], progresses[nextIndex])
        }

        addBridgedSpacing(
            to: &spacings,
            subviews: subviews,
            progresses: progresses
        )

        return subviews.indices.map { index in
            MeasuredItem(
                size: sizes[index],
                presenceProgress: progresses[index],
                spacingAfter: finiteNonnegative(spacings[index])
            )
        }
    }

    /// 已收起的连续区段消失后，两侧可见兄弟仍需恢复为正常相邻间距。
    private func addBridgedSpacing(
        to spacings: inout [CGFloat],
        subviews: Subviews,
        progresses: [CGFloat]
    ) {
        var index = subviews.startIndex

        while index < subviews.endIndex {
            guard progresses[index] < 1 else {
                index = subviews.index(after: index)
                continue
            }

            let runStart = index
            var runEnd = index
            var maximumProgress = progresses[index]
            var nextIndex = subviews.index(after: index)

            while nextIndex < subviews.endIndex, progresses[nextIndex] < 1 {
                runEnd = nextIndex
                maximumProgress = max(maximumProgress, progresses[nextIndex])
                nextIndex = subviews.index(after: nextIndex)
            }

            if runStart > subviews.startIndex, nextIndex < subviews.endIndex {
                let previousIndex = subviews.index(before: runStart)
                let bridge = baseSpacing(
                    previous: subviews[previousIndex],
                    next: subviews[nextIndex]
                ) * (1 - maximumProgress)
                spacings[previousIndex] += bridge / 2
                spacings[runEnd] += bridge / 2
            }

            index = nextIndex
        }
    }

    private func baseSpacing(previous: LayoutSubview, next: LayoutSubview) -> CGFloat {
        let resolved = spacing
            ?? previous.spacing.distance(to: next.spacing, along: .vertical)
        return finiteNonnegative(resolved)
    }

    private func xOrigin(for size: CGSize, in bounds: CGRect) -> CGFloat {
        switch alignment {
        case .leading:
            bounds.minX
        case .center:
            bounds.midX - size.width / 2
        case .trailing:
            bounds.maxX - size.width
        }
    }

    private func sanitized(_ size: CGSize) -> CGSize {
        CGSize(
            width: finiteNonnegative(size.width),
            height: finiteNonnegative(size.height)
        )
    }

    private func finiteNonnegative(_ value: CGFloat) -> CGFloat {
        value.isFinite ? max(0, value) : 0
    }

    private func clampedProgress(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else { return 0 }
        return min(max(value, 0), 1)
    }

    private struct MeasuredItem {
        let size: CGSize
        let presenceProgress: CGFloat
        let spacingAfter: CGFloat
    }
}

/// 为列表行中的可选内容提供可中断的出现、消失和固有高度变化动画。
struct AnimatedPresencePrototype<Value: Equatable, Content: View>: View {
    private let value: Value?
    private let animation: Animation?
    private let contentTransition: ContentTransition
    private let content: (Value) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var displayValue: Value?
    @State private var visibleHeight: CGFloat = 0
    @State private var targetHeight: CGFloat = 0
    @State private var presenceProgress: CGFloat = 0
    @State private var isAwaitingInitialMeasurement = false
    @State private var collapseGeneration = 0

    /// 创建由可选值驱动的内容；外部值清空后，旧内容会保留到收起动画完成。
    init(
        value: Value?,
        animation: Animation?,
        contentTransition: ContentTransition = .identity,
        @ViewBuilder content: @escaping (Value) -> Content
    ) {
        self.value = value
        self.animation = animation
        self.contentTransition = contentTransition
        self.content = content
        _displayValue = State(initialValue: nil)
    }

    /// 创建由布尔状态驱动的内容，适合不需要额外展示值的展开收起区域。
    init(
        isPresented: Bool,
        animation: Animation?,
        contentTransition: ContentTransition = .identity,
        @ViewBuilder content: @escaping () -> Content
    ) where Value == Bool {
        self.init(
            value: isPresented ? true : nil,
            animation: animation,
            contentTransition: contentTransition,
            content: { _ in content() }
        )
    }

    var body: some View {
        PrototypeVisibleHeightLayout(visibleHeight: visibleHeight) {
            if let displayValue {
                content(displayValue)
                    .fixedSize(horizontal: false, vertical: true)
                    .contentTransition(contentTransition)
                    .animation(effectiveAnimation, value: displayValue)
                    .onGeometryChange(for: CGFloat.self) { geometry in
                        geometry.size.height
                    } action: { measuredHeight in
                        handleMeasurement(measuredHeight)
                    }
            }
        }
        .clipped()
        .allowsHitTesting(value != nil)
        .accessibilityHidden(value == nil)
        .modifier(PrototypePresenceProgressModifier(progress: presenceProgress))
        .onAppear(perform: handleAppearance)
        .onChange(of: value) { _, newValue in
            handleValueChange(newValue)
        }
    }

    private var effectiveAnimation: Animation? {
        reduceMotion ? nil : animation
    }

    private func handleAppearance() {
        guard let value, displayValue == nil else { return }
        displayValue = value
        isAwaitingInitialMeasurement = true
    }

    private func handleValueChange(_ newValue: Value?) {
        if let newValue {
            collapseGeneration &+= 1
            isAwaitingInitialMeasurement = false

            if displayValue == nil {
                targetHeight = 0
                displayValue = newValue
                return
            }

            displayValue = newValue
            settlePresence(at: targetHeight)
            return
        }

        collapseGeneration &+= 1
        let generation = collapseGeneration

        guard let effectiveAnimation else {
            visibleHeight = 0
            presenceProgress = 0
            displayValue = nil
            return
        }

        withAnimation(effectiveAnimation, completionCriteria: .logicallyComplete) {
            visibleHeight = 0
            presenceProgress = 0
        } completion: {
            guard collapseGeneration == generation, value == nil else { return }
            displayValue = nil
        }
    }

    private func handleMeasurement(_ measuredHeight: CGFloat) {
        guard measuredHeight.isFinite, displayValue != nil, value != nil else { return }
        let measuredHeight = max(0, measuredHeight)

        if isAwaitingInitialMeasurement {
            isAwaitingInitialMeasurement = false
            targetHeight = measuredHeight
            visibleHeight = measuredHeight
            presenceProgress = 1
            return
        }

        let didHeightChange = abs(measuredHeight - targetHeight) > 0.5
        let needsPresenceSettle = presenceProgress < 1
        guard didHeightChange || needsPresenceSettle else { return }
        targetHeight = measuredHeight

        guard let effectiveAnimation else {
            visibleHeight = measuredHeight
            presenceProgress = 1
            return
        }

        withAnimation(effectiveAnimation) {
            visibleHeight = measuredHeight
            presenceProgress = 1
        }
    }

    /// 使用最近一次固有高度中断收起动画；若内容刚挂载尚未测量，则继续等待几何回调。
    private func settlePresence(at height: CGFloat) {
        guard height.isFinite, height > 0 else { return }

        guard let effectiveAnimation else {
            visibleHeight = height
            presenceProgress = 1
            return
        }

        withAnimation(effectiveAnimation) {
            visibleHeight = height
            presenceProgress = 1
        }
    }
}

private struct PrototypeVisibleHeightLayout: Layout {
    var visibleHeight: CGFloat

    var animatableData: CGFloat {
        get { visibleHeight }
        set { visibleHeight = newValue }
    }

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) -> CGSize {
        guard let subview = subviews.first else { return .zero }
        let intrinsicSize = subview.sizeThatFits(
            ProposedViewSize(width: proposal.width, height: nil)
        )
        let width = proposal.width ?? intrinsicSize.width
        return CGSize(
            width: width.isFinite ? max(0, width) : 0,
            height: visibleHeight.isFinite ? max(0, visibleHeight) : 0
        )
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache: inout ()
    ) {
        guard let subview = subviews.first else { return }
        let intrinsicSize = subview.sizeThatFits(
            ProposedViewSize(width: bounds.width, height: nil)
        )
        subview.place(
            at: bounds.origin,
            anchor: .topLeading,
            proposal: ProposedViewSize(
                width: bounds.width,
                height: intrinsicSize.height.isFinite ? max(0, intrinsicSize.height) : 0
            )
        )
    }

    func spacing(subviews: Subviews, cache: inout ()) -> ViewSpacing {
        subviews.first?.spacing ?? .zero
    }
}

private nonisolated struct PrototypePresenceProgressKey: LayoutValueKey {
    static let defaultValue: CGFloat? = nil
}

private struct PrototypePresenceProgressModifier: ViewModifier, Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content.layoutValue(
            key: PrototypePresenceProgressKey.self,
            value: progress.isFinite ? min(max(progress, 0), 1) : 0
        )
    }
}

#Preview("列表展开收起基建候选") {
    @Previewable @State var isVisible = true
    @Previewable @State var sampleIndex = 0
    let samples = [
        "短内容。",
        "这是一段会换成多行的较长内容，用于检查 List 行高变化时文字是否保持固有尺寸，并确认后续兄弟内容能够连续移动。",
        "中等长度内容，用于验证动画中替换展示值。"
    ]

    List {
        CollapseAwareVStackPrototype(alignment: .leading, spacing: Spacing.half) {
            Text("平滑基建")
                .font(AppTypography.headlineSemibold)

            AnimatedPresencePrototype(
                value: isVisible ? samples[sampleIndex] : nil,
                animation: .smooth(duration: 0.28),
                contentTransition: .opacity
            ) { value in
                Text(value)
                    .font(AppTypography.footnote)
                    .foregroundStyle(Color.textSecondary)
            }

            Text("后续内容应连续跟随")
                .font(AppTypography.caption)
                .foregroundStyle(Color.textHint)
        }
        .frame(maxWidth: .infinity, alignment: .leading)

        Button(isVisible ? "收起" : "展开") {
            isVisible.toggle()
        }

        Button("切换内容") {
            isVisible = true
            sampleIndex = (sampleIndex + 1) % samples.count
        }
    }
}
#endif
