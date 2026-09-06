/**
 * [INPUT]: 依赖 BigUIPaging PageView、NoteReviewPagingModels 与 SwiftUI 手势/可访问性环境
 * [OUTPUT]: 对外提供 NoteReviewPagingDeck，支持首帧同步成组、数据源变更重建、书摘回顾双向滑动、后卡补位、分页预加载与空态承载
 * [POS]: Views/Note/Components/NoteReviewPaging 的页面私有卡组，隔离业务卡片内容与 BigUIPaging 源码基座
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书摘回顾卡片渲染上下文，供内容视图判断当前位置与数据规模。
struct NoteReviewPagingDeckCardContext {
    let index: Int
    let itemCount: Int
    let isSelectedCard: Bool
}

/// 基于 BigUIPaging 的书摘回顾卡组，左滑进入下一张、右滑回到上一张。
struct NoteReviewPagingDeck<Item: Identifiable, CardContent: View, EmptyContent: View>: View {
    let items: [Item]
    @Binding var selection: Item.ID?
    var hasMoreItems: Bool
    var configuration: NoteReviewPagingDeckConfiguration
    var onCardAppeared: (Item, Int) -> Void
    var onNeedsMoreItems: () -> Void
    var onTap: (Item, Int) -> Void
    @ViewBuilder let content: (Item, NoteReviewPagingDeckCardContext) -> CardContent
    @ViewBuilder let emptyContent: () -> EmptyContent

    @State private var lastNotifiedSelection: Item.ID?

    private var itemIDs: [Item.ID] {
        items.map(\.id)
    }

    init(
        items: [Item],
        selection: Binding<Item.ID?>,
        hasMoreItems: Bool,
        configuration: NoteReviewPagingDeckConfiguration = .iOSReviewDefault,
        onCardAppeared: @escaping (Item, Int) -> Void = { _, _ in },
        onNeedsMoreItems: @escaping () -> Void = {},
        onTap: @escaping (Item, Int) -> Void = { _, _ in },
        @ViewBuilder content: @escaping (Item, NoteReviewPagingDeckCardContext) -> CardContent,
        @ViewBuilder emptyContent: @escaping () -> EmptyContent
    ) {
        self.items = items
        _selection = selection
        self.hasMoreItems = hasMoreItems
        self.configuration = configuration
        self.onCardAppeared = onCardAppeared
        self.onNeedsMoreItems = onNeedsMoreItems
        self.onTap = onTap
        self.content = content
        self.emptyContent = emptyContent
    }

    var body: some View {
        Group {
            if items.isEmpty {
                emptyContent()
            } else {
                deckContent
            }
        }
        .onAppear {
            normalizeSelection()
            notifyCurrentSelectionIfNeeded()
        }
        .onChange(of: itemIDs) { _, _ in
            normalizeSelection()
            notifyCurrentSelectionIfNeeded()
        }
        .onChange(of: selection) { _, _ in
            normalizeSelection()
            notifyCurrentSelectionIfNeeded()
        }
    }

    private var deckContent: some View {
        PageView(selection: selectedIDBinding) { value in
            pagingState(for: value).nextID()
        } previous: { value in
            pagingState(for: value).previousID()
        } content: { id in
            cardContent(for: id)
        }
        .pageViewStyle(
            NoteReviewCardDeckPageViewStyle(
                configuration: configuration,
                sourceIDs: itemIDs.map(AnyHashable.init)
            )
        )
        .padding(configuration.cardInsets)
        .accessibilityElement(children: .contain)
        .accessibilityValue(accessibilityValue)
    }

    private var selectedIDBinding: Binding<Item.ID> {
        Binding {
            pagingState().normalizedSelection ?? items[0].id
        } set: { newValue in
            selection = newValue
        }
    }

    private var accessibilityValue: String {
        guard let index = currentIndex else { return "" }
        return "\(index + 1) / \(items.count)"
    }

    private var currentIndex: Int? {
        guard let selection else { return nil }
        return items.firstIndex { $0.id == selection }
    }

    private func pagingState(for currentSelection: Item.ID? = nil) -> NoteReviewPagingState<Item.ID> {
        NoteReviewPagingState(
            itemIDs: itemIDs,
            selection: currentSelection ?? selection,
            hasMoreItems: hasMoreItems,
            isLoopingEnabled: configuration.isLoopingEnabled
        )
    }

    private func normalizeSelection() {
        let state = pagingState()
        if selection != state.normalizedSelection {
            selection = state.normalizedSelection
        }
    }

    private func notifyCurrentSelectionIfNeeded() {
        guard let selection,
              selection != lastNotifiedSelection,
              let index = items.firstIndex(where: { $0.id == selection })
        else { return }

        lastNotifiedSelection = selection
        let item = items[index]
        onCardAppeared(item, index)

        if hasMoreItems, index + configuration.preloadDistance >= max(items.count - 1, 0) {
            onNeedsMoreItems()
        }
    }

    @ViewBuilder
    private func cardContent(for id: Item.ID) -> some View {
        if let index = items.firstIndex(where: { $0.id == id }) {
            let item = items[index]
            let context = NoteReviewPagingDeckCardContext(
                index: index,
                itemCount: items.count,
                isSelectedCard: item.id == selection
            )
            content(item, context)
                .contentShape(Rectangle())
                .simultaneousGesture(TapGesture().onEnded {
                    guard configuration.isTapEnabled else { return }
                    onTap(item, index)
                })
                .accessibilityAddTraits(.isButton)
                .accessibilityAction {
                    onTap(item, index)
                }
        } else {
            Color.clear
        }
    }
}

private struct NoteReviewCardDeckPageViewStyle: PageViewStyle {
    let configuration: NoteReviewPagingDeckConfiguration
    let sourceIDs: [AnyHashable]

    func makeBody(configuration pageConfiguration: Configuration) -> some View {
        NoteReviewCardDeckPageView(
            pageConfiguration: pageConfiguration,
            deckConfiguration: configuration,
            sourceIDs: sourceIDs
        )
    }
}

private struct NoteReviewCardDeckPageView: View {
    private struct Page: Identifiable {
        let index: Int
        let value: PageViewStyleConfiguration.Value

        var id: PageViewStyleConfiguration.Value {
            value
        }
    }

    private struct RenderedLayerID: Hashable {
        let value: PageViewStyleConfiguration.Value
        let role: NoteReviewPagingLayerRole
    }

    private struct RenderedLayer: Identifiable {
        let id: RenderedLayerID
        let page: Page
        let plan: NoteReviewPagingLayerPlan
    }

    let pageConfiguration: PageViewStyleConfiguration
    let deckConfiguration: NoteReviewPagingDeckConfiguration
    let sourceIDs: [AnyHashable]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragTracker = NoteReviewPagingDragTracker()
    @State private var visualSession: NoteReviewPagingVisualSession<PageViewStyleConfiguration.Value>?
    @State private var internallyCommittedSelection: PageViewStyleConfiguration.Value?
    @State private var containerSize = CGSize.zero
    @State private var pages: [Page] = []
    @State private var selectedIndex = 0

    /// 使用当前选中项同步建立首批视觉层，避免组件先提交空页面、再等待 onAppear 补齐卡组。
    init(
        pageConfiguration: PageViewStyleConfiguration,
        deckConfiguration: NoteReviewPagingDeckConfiguration,
        sourceIDs: [AnyHashable]
    ) {
        self.pageConfiguration = pageConfiguration
        self.deckConfiguration = deckConfiguration
        self.sourceIDs = sourceIDs

        let visibleLimit = max(deckConfiguration.visibleCount - 1, 1)
        let resolved = pageConfiguration.values(
            surrounding: pageConfiguration.selection.wrappedValue,
            limit: visibleLimit
        )
        _pages = State(
            initialValue: resolved.0.enumerated().map {
                Page(index: $0.offset, value: $0.element)
            }
        )
        _selectedIndex = State(initialValue: resolved.1)
    }

    private var activeMotionSpec: NoteReviewPagingMotionSpec {
        deckConfiguration.motionSpec.applyingReduceMotion(reduceMotion)
    }

    var body: some View {
        ZStack {
            ForEach(renderedLayers) { layer in
                let transform = layer.plan.transform
                pageConfiguration.content(layer.page.value)
                    .environment(\.noteReviewPagingCardContentVisibility, transform.contentVisibility)
                    .allowsHitTesting(layer.plan.allowsHitTesting)
                    .accessibilityHidden(layer.plan.isAccessibilityHidden)
                    .zIndex(layer.plan.zIndex)
                    .offset(x: transform.offsetX, y: transform.offsetY)
                    .scaleEffect(transform.scale)
                    .rotationEffect(.degrees(transform.rotationDegrees))
                    .opacity(transform.opacity)
            }
        }
        .measure($containerSize)
        .simultaneousGesture(dragGesture)
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment:
                commitAccessibilityNavigation(.next)
            case .decrement:
                commitAccessibilityNavigation(.previous)
            @unknown default:
                break
            }
        }
        .onAppear {
            let selection = pageConfiguration.selection.wrappedValue
            rebuildPages(from: selection)
        }
        .onChange(of: pageConfiguration.selection.wrappedValue) { _, newValue in
            if internallyCommittedSelection == newValue {
                internallyCommittedSelection = nil
                return
            }
            visualSession = nil
            rebuildPages(from: newValue)
            dragTracker.reset()
        }
        .onChange(of: sourceIDs) { oldIDs, newIDs in
            reconcileSourceChange(from: oldIDs, to: newIDs)
        }
        .onChange(of: deckConfiguration) { _, _ in
            visualSession = nil
            rebuildPages(from: pageConfiguration.selection.wrappedValue)
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard deckConfiguration.isSwipeEnabled else { return }
                guard visualSession?.isCommitting != true else { return }
                guard let effectiveTranslation = dragTracker.update(
                    translation: value.translation,
                    motionSpec: activeMotionSpec
                ) else { return }
                beginVisualSessionIfNeeded()
                let progress = activeMotionSpec.progressOffset(
                    translationWidth: effectiveTranslation.width,
                    containerWidth: containerSize.width
                )
                updateVisualSession { session in
                    session.updateDragProgress(boundedDragProgress(progress))
                }
            }
            .onEnded { value in
                guard deckConfiguration.isSwipeEnabled else {
                    resetDrag()
                    return
                }
                guard visualSession?.isCommitting != true else { return }
                let effectiveTranslation = dragTracker.effectiveTranslation
                let effectivePredictedEndTranslation = dragTracker.effectivePredictedEndTranslation(value.predictedEndTranslation)
                let navigation = activeMotionSpec.navigation(
                    translation: effectiveTranslation,
                    predictedEndTranslation: effectivePredictedEndTranslation,
                    containerWidth: containerSize.width
                )
                guard let navigation, let destination = destinationValue(for: navigation) else {
                    resetDrag()
                    return
                }

                commitNavigation(navigation, destination: destination)
            }
    }

    private func resetDrag() {
        guard visualSession != nil else {
            dragTracker.reset()
            return
        }

        withAnimation(
            .smooth(duration: activeMotionSpec.resetDuration),
            completionCriteria: .removed
        ) {
            updateVisualSession { session in
                session.cancel()
            }
        } completion: {
            visualSession = nil
        }
        dragTracker.reset()
    }

    private func commitNavigation(
        _ navigation: NoteReviewPagingNavigation,
        destination: PageViewStyleConfiguration.Value
    ) {
        guard let targetIndex = pages.firstIndex(where: { $0.value == destination }) else {
            finishSelection(destination, isInternalCommit: true)
            return
        }

        beginVisualSessionIfNeeded()
        updateVisualSession { session in
            session.beginCommit(to: destination, targetIndex: targetIndex, direction: navigation)
        }
        withAnimation(
            .smooth(duration: activeMotionSpec.settleDuration),
            completionCriteria: .removed
        ) {
            updateVisualSession { session in
                session.animateToCommitBoundary()
            }
        } completion: {
            finishVisualCommit(destination)
        }
        dragTracker.reset()
    }

    private func commitAccessibilityNavigation(_ navigation: NoteReviewPagingNavigation) {
        guard visualSession?.isCommitting != true,
              let destination = destinationValue(for: navigation),
              destination != pageConfiguration.selection.wrappedValue
        else { return }
        commitNavigation(navigation, destination: destination)
    }

    private func finishVisualCommit(_ destination: PageViewStyleConfiguration.Value) {
        guard var session = visualSession,
              session.destination == destination,
              session.completeCommit() == destination
        else { return }
        visualSession = session
        finishSelection(destination, isInternalCommit: true)
    }

    private func finishSelection(
        _ destination: PageViewStyleConfiguration.Value,
        isInternalCommit: Bool
    ) {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            if isInternalCommit {
                internallyCommittedSelection = destination
            }
            pageConfiguration.selection.wrappedValue = destination
            rebuildPages(from: destination)
            visualSession = nil
        }
        dragTracker.reset()
    }

    private func rebuildPages(from value: PageViewStyleConfiguration.Value) {
        let visibleLimit = max(deckConfiguration.visibleCount - 1, 1)
        let resolved = pageConfiguration.values(surrounding: value, limit: visibleLimit)
        pages = resolved.0.enumerated().map { Page(index: $0.offset, value: $0.element) }
        selectedIndex = resolved.1
    }

    /// 数据仅在尾部追加时保留正在进行的直操；范围替换或重排则立即丢弃旧视觉会话并从权威 selection 重建。
    private func reconcileSourceChange(from oldIDs: [AnyHashable], to newIDs: [AnyHashable]) {
        let isAppendOnly = newIDs.count >= oldIDs.count && newIDs.starts(with: oldIDs)
        if !isAppendOnly {
            visualSession = nil
            internallyCommittedSelection = nil
            dragTracker.reset()
        }

        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            rebuildPages(from: pageConfiguration.selection.wrappedValue)
        }
    }

    private func destinationValue(for navigation: NoteReviewPagingNavigation) -> PageViewStyleConfiguration.Value? {
        switch navigation {
        case .next:
            return pageConfiguration.next(pageConfiguration.selection.wrappedValue)
        case .previous:
            return pageConfiguration.previous(pageConfiguration.selection.wrappedValue)
        }
    }

    private func boundedDragProgress(_ progress: CGFloat) -> CGFloat {
        if progress > 0, destinationValue(for: .next) == nil {
            return progress * 0.18
        }
        if progress < 0, destinationValue(for: .previous) == nil {
            return progress * 0.18
        }
        return progress
    }

    private var deckProgressIndex: Double {
        visualSession?.progressIndex ?? activeMotionSpec.deckProgressIndex(
            sourceIndex: selectedIndex,
            visualProgress: 0
        )
    }

    private var activeSourceIndex: Int {
        visualSession?.sourceIndex ?? selectedIndex
    }

    private var renderedLayers: [RenderedLayer] {
        let progressIndex = deckProgressIndex
        return activeMotionSpec.layerPlans(
            pageCount: pages.count,
            sourceIndex: activeSourceIndex,
            progressIndex: progressIndex,
            containerWidth: containerSize.width,
            containerHeight: containerSize.height,
            isSupportProxyEnabled: shouldRenderSupportProxy
        ).compactMap { plan in
            guard pages.indices.contains(plan.pageIndex) else { return nil }
            let page = pages[plan.pageIndex]
            return RenderedLayer(
                id: RenderedLayerID(value: page.value, role: plan.role),
                page: page,
                plan: plan
            )
        }
    }

    private var shouldRenderSupportProxy: Bool {
        guard let session = visualSession, abs(session.visualProgress) > 0.001 else { return false }
        if let destination = session.destination, destination != session.sourceSelection {
            return true
        }
        if session.visualProgress > 0 {
            return destinationValue(for: .next) != nil
        }
        if session.visualProgress < 0 {
            return destinationValue(for: .previous) != nil
        }
        return false
    }

    private func beginVisualSessionIfNeeded() {
        guard visualSession == nil else { return }
        visualSession = NoteReviewPagingVisualSession(
            sourceSelection: pageConfiguration.selection.wrappedValue,
            sourceIndex: selectedIndex
        )
    }

    private func updateVisualSession(
        _ update: (inout NoteReviewPagingVisualSession<PageViewStyleConfiguration.Value>) -> Void
    ) {
        guard var session = visualSession else { return }
        update(&session)
        visualSession = session
    }
}
