/**
 * [INPUT]: 依赖 NotePullDownSearchBar 与 SwiftUI 原生滚动几何/目标 API，接收分类独立搜索 Binding、页面激活态与分类内容
 * [OUTPUT]: 对 NoteCollectionView 提供单一系统滚动坐标的下拉搜索页，以固定 Section Header 承载揭示、搜索固定与端点吸附
 * [POS]: Note 模块首页页面私有滚动容器，仅被 NoteCollectionView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 分类内容可使用的稳定 viewport 指标；空态偏移只改变绘制位置，不参与滚动内容尺寸计算。
struct NoteCollapsibleSearchMetrics {
    let viewportHeight: CGFloat
    let emptyStateOffset: CGFloat
}

/// 分类搜索与内容共享同一个 SwiftUI ScrollView，系统完整拥有拖动、减速、橡皮筋和回弹。
struct NoteCollapsibleSearchPage<Content: View>: View {
    @Binding var searchText: String
    let placeholder: String
    let isPageActive: Bool
    @ViewBuilder let content: (NoteCollapsibleSearchMetrics) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSearchActive = false
    @State private var normalizedSearchOffset: CGFloat
    @State private var scrollPhase: ScrollPhase = .idle
    @State private var scrollPosition: ScrollPosition
    @State private var searchPhase: NoteSearchPresentationPhase
    @State private var pendingScrollAction: NoteSearchPendingScrollAction?

    /// 以分类已恢复的查询决定首帧搜索状态与原生滚动位置，避免空查询闪现搜索头。
    init(
        searchText: Binding<String>,
        placeholder: String,
        isPageActive: Bool,
        @ViewBuilder content: @escaping (NoteCollapsibleSearchMetrics) -> Content
    ) {
        self._searchText = searchText
        self.placeholder = placeholder
        self.isPageActive = isPageActive
        self.content = content

        let hasQuery = !searchText.wrappedValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .isEmpty
        let initialOffset = hasQuery
            ? NoteCollapsibleSearchLayout.expandedOffset
            : NoteCollapsibleSearchLayout.collapsedOffset
        self._normalizedSearchOffset = State(initialValue: initialOffset)
        self._scrollPosition = State(initialValue: ScrollPosition(y: initialOffset))
        self._searchPhase = State(initialValue: hasQuery ? .searching : .browsing)
    }

    private var hasQuery: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isSearchPinned: Bool {
        searchPhase != .browsing || isSearchActive || hasQuery
    }

    private var collapseDistance: CGFloat {
        isSearchPinned ? 0 : normalizedSearchOffset
    }

    private var revealProgress: CGFloat {
        isSearchPinned
            ? 1
            : 1 - normalizedSearchOffset / NoteCollapsibleSearchLayout.headerHeight
    }

    private var visibleSearchHeight: CGFloat {
        NoteCollapsibleSearchLayout.headerHeight * revealProgress
    }

    private var isSearchInteractable: Bool {
        isSearchPinned
            || normalizedSearchOffset <= NoteCollapsibleSearchLayout.interactionTolerance
    }

    private var isSearchSnapEnabled: Bool {
        isPageActive && searchPhase == .browsing && !isSearchActive && !hasQuery
    }

    var body: some View {
        GeometryReader { proxy in
            ScrollView {
                LazyVStack(
                    alignment: .leading,
                    spacing: Spacing.none,
                    pinnedViews: [.sectionHeaders]
                ) {
                    Section {
                        content(
                            NoteCollapsibleSearchMetrics(
                                viewportHeight: proxy.size.height,
                                emptyStateOffset: -visibleSearchHeight / 2
                            )
                        )
                        .frame(
                            maxWidth: .infinity,
                            minHeight: proxy.size.height,
                            alignment: .top
                        )
                    } header: {
                        searchHeader
                    }
                }
            }
            .scrollPosition($scrollPosition)
            .scrollTargetBehavior(
                NoteSearchRevealTargetBehavior(isEnabled: isSearchSnapEnabled)
            )
            .scrollBounceBehavior(.always)
            .scrollDismissesKeyboard(.interactively)
            .onScrollGeometryChange(for: CGFloat.self) { geometry in
                NoteCollapsibleSearchLayout.clampedOffset(
                    geometry.contentOffset.y + geometry.contentInsets.top
                )
            } action: { _, newOffset in
                updateNormalizedSearchOffset(newOffset)
            }
            .onScrollPhaseChange { _, newPhase in
                handleScrollPhaseChange(newPhase)
            }
            .accessibilityAction(named: "显示搜索") {
                revealSearchForAccessibility()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear(perform: synchronizeRestoredQuery)
        .onChange(of: hasQuery) { _, newValue in
            handleQueryChange(hasQuery: newValue)
        }
        .onChange(of: isSearchActive) { _, newValue in
            handleSearchActivationChange(isActive: newValue)
        }
        .onChange(of: isPageActive) { _, newValue in
            handlePageActivationChange(isActive: newValue)
        }
    }

    private var searchHeader: some View {
        NotePullDownSearchBar(
            text: $searchText,
            isActive: $isSearchActive,
            placeholder: placeholder,
            isAccessibilityVisible: isSearchInteractable,
            onCancel: cancelSearch
        )
        .padding(.vertical, NoteCollapsibleSearchLayout.verticalBreathing)
        .padding(.horizontal, Spacing.screenEdge)
        .frame(
            maxWidth: .infinity,
            minHeight: NoteCollapsibleSearchLayout.headerHeight,
            maxHeight: NoteCollapsibleSearchLayout.headerHeight,
            alignment: .top
        )
        .background(Color.surfacePage)
        .offset(y: -collapseDistance)
        .opacity(revealProgress)
        .allowsHitTesting(isSearchInteractable)
        .accessibilityHidden(!isSearchInteractable)
        .zIndex(1)
    }

    /// 把原生滚动几何限制在搜索头区间，只在真实值变化时刷新搜索头展示。
    private func updateNormalizedSearchOffset(_ offset: CGFloat) {
        guard abs(normalizedSearchOffset - offset)
                >= NoteCollapsibleSearchLayout.geometryEpsilon else {
            return
        }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            normalizedSearchOffset = offset
        }
        completePendingScrollActionIfPossible()
    }

    /// 页面恢复有效查询时保持搜索头固定；空查询的首帧位置已由 ScrollPosition 初始化。
    private func synchronizeRestoredQuery() {
        guard hasQuery else { return }
        searchPhase = .searching
    }

    /// 查询出现时进入固定搜索态；查询清空后的最终阶段由焦点或取消流程决定。
    private func handleQueryChange(hasQuery: Bool) {
        if hasQuery {
            pendingScrollAction = nil
            searchPhase = .searching
            revealSearch(animated: false)
        } else if !isSearchActive, searchPhase == .searching {
            searchPhase = .browsing
        }
    }

    /// 焦点只管理搜索呈现，不重建列表；普通点击发生在完整揭示端点，因此无需额外运动。
    private func handleSearchActivationChange(isActive: Bool) {
        if isActive {
            pendingScrollAction = nil
            searchPhase = .searching
            revealSearch(animated: false)
        } else if !hasQuery, searchPhase == .searching {
            searchPhase = .browsing
        }
    }

    /// 隐藏分类结束输入与待提交动作，保留该分类已经形成的搜索词和系统滚动现场。
    private func handlePageActivationChange(isActive: Bool) {
        guard !isActive else { return }
        pendingScrollAction = nil
        isSearchActive = false
        searchPhase = hasQuery ? .searching : .browsing
    }

    /// 记录系统滚动阶段；用户重新触摸时立即获得控制权，程序化收口不再争夺滚动位置。
    private func handleScrollPhaseChange(_ newPhase: ScrollPhase) {
        scrollPhase = newPhase
        if newPhase == .tracking || newPhase == .interacting {
            interruptPendingScrollActionForUserInteraction()
        } else if newPhase == .idle {
            completePendingScrollActionIfPossible()
        }
    }

    /// 用户中断无障碍揭示或取消回位后，只收口搜索头视觉，不追加第二次滚动。
    private func interruptPendingScrollActionForUserInteraction() {
        guard let pendingScrollAction else { return }
        self.pendingScrollAction = nil
        guard pendingScrollAction == .finishCancellation else { return }

        if reduceMotion {
            searchPhase = .browsing
        } else {
            withAnimation(.smooth(duration: NoteCollapsibleSearchLayout.interruptionDuration)) {
                searchPhase = .browsing
            }
        }
    }

    /// VoiceOver 先沿系统滚动到完整揭示端点，再把焦点交给稳定存在的输入框。
    private func revealSearchForAccessibility() {
        guard isPageActive, !isSearchActive else { return }
        guard normalizedSearchOffset
                > NoteCollapsibleSearchLayout.interactionTolerance else {
            searchPhase = .searching
            isSearchActive = true
            return
        }

        pendingScrollAction = .activateSearch
        revealSearch(animated: true)
    }

    /// 聚焦、查询恢复和无障碍动作只通过官方 ScrollPosition 提交明确端点，不参与手势减速。
    private func revealSearch(animated: Bool) {
        guard normalizedSearchOffset
                > NoteCollapsibleSearchLayout.interactionTolerance else {
            completePendingScrollActionIfPossible()
            return
        }

        if reduceMotion || !animated {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                scrollPosition.scrollTo(y: NoteCollapsibleSearchLayout.expandedOffset)
            }
        } else {
            withAnimation(.smooth(duration: NoteCollapsibleSearchLayout.programmaticScrollDuration)) {
                scrollPosition.scrollTo(y: NoteCollapsibleSearchLayout.expandedOffset)
            }
        }
    }

    /// 共享搜索组件已完成清词和失焦；页面只维持固定搜索头并请求一次系统位置回归。
    private func cancelSearch() {
        guard searchPhase != .returningAfterCancel else { return }
        searchPhase = .returningAfterCancel
        pendingScrollAction = .finishCancellation
        revealSearch(animated: true)
    }

    /// 只有系统滚动真正空闲且到达展开端点后，才提交焦点或解除取消期间的临时固定。
    private func completePendingScrollActionIfPossible() {
        guard scrollPhase == .idle,
              normalizedSearchOffset <= NoteCollapsibleSearchLayout.interactionTolerance,
              let pendingScrollAction else {
            return
        }
        self.pendingScrollAction = nil

        switch pendingScrollAction {
        case .activateSearch:
            searchPhase = .searching
            isSearchActive = true
        case .finishCancellation:
            searchPhase = .browsing
        }
    }
}

/// 搜索头的展示阶段独立于查询业务状态，避免焦点、清词和滚动位置互相覆盖。
private enum NoteSearchPresentationPhase {
    case browsing
    case searching
    case returningAfterCancel
}

/// 程序化滚动完成后需要提交的单一页面动作；用户触摸可以随时取消它。
private enum NoteSearchPendingScrollAction {
    case activateSearch
    case finishCancellation
}

/// 仅在搜索头区间修正 SwiftUI 已预测的落点，让系统继续负责实际减速与回弹。
private struct NoteSearchRevealTargetBehavior: ScrollTargetBehavior {
    let isEnabled: Bool

    /// 在系统 proposed target 仍位于 0...52pt 时选择展开或收起端点，内容区目标保持不变。
    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        guard isEnabled,
              context.axes.contains(.vertical),
              target.rect.minY <= NoteCollapsibleSearchLayout.collapsedOffset else {
            return
        }
        target.rect.origin.y = target.rect.minY < NoteCollapsibleSearchLayout.snapMidpoint
            ? NoteCollapsibleSearchLayout.expandedOffset
            : NoteCollapsibleSearchLayout.collapsedOffset
    }
}

/// 搜索头固定几何、滚动端点和低频状态过渡参数。
private enum NoteCollapsibleSearchLayout {
    static let headerHeight: CGFloat = 52
    static let expandedOffset: CGFloat = 0
    static let collapsedOffset = headerHeight
    static let snapMidpoint = headerHeight / 2
    static let verticalBreathing: CGFloat = 4
    static let interactionTolerance: CGFloat = 0.5
    static let geometryEpsilon: CGFloat = 0.25
    static let interruptionDuration = 0.18
    static let programmaticScrollDuration = 0.22

    /// 将任意系统滚动位置映射到搜索头关心的稳定区间，内容区滚动不再触发状态刷新。
    static func clampedOffset(_ offset: CGFloat) -> CGFloat {
        min(max(offset, expandedOffset), collapsedOffset)
    }
}
