/**
 * [INPUT]: 依赖 NotePullDownSearchBar 与 NoteScrollBoundaryCoordinator，接收分类独立搜索 Binding、页面激活态与分类内容
 * [OUTPUT]: 对 NoteCollectionView 提供单滚动坐标搜索抽屉，以透明揭示轨道承接原生滚动、端点 Snap、搜索固定、彻底裁剪收起与轨道外有效视口计算
 * [POS]: Note 模块首页页面私有滚动容器，仅被 NoteCollectionView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 分类内容可使用的稳定 viewport 指标；空态偏移只改变绘制位置，不参与滚动内容尺寸计算。
struct NoteCollapsibleSearchMetrics {
    let viewportHeight: CGFloat
    let emptyStateOffset: CGFloat
}

/// 搜索抽屉以滚动内容顶部的透明轨道提供真实行程，搜索像素只在 sibling overlay 中硬裁剪显示。
struct NoteCollapsibleSearchPage<Content: View>: View {
    @Binding var searchText: String
    let placeholder: String
    let isPageActive: Bool
    @ViewBuilder let content: (NoteCollapsibleSearchMetrics) -> Content

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isSearchActive = false
    @State private var visibleSearchHeight: CGFloat
    @State private var searchPhase: NoteSearchSessionPhase
    @State private var boundaryController = NoteScrollBoundaryController()

    /// 以分类已恢复的查询决定首帧高度，避免有效搜索先显示为收起状态。
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
        self._visibleSearchHeight = State(
            initialValue: hasQuery ? NoteCollapsibleSearchLayout.headerHeight : 0
        )
        self._searchPhase = State(initialValue: hasQuery ? .searching : .browsing)
    }

    private var hasQuery: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var isSearchPinned: Bool {
        searchPhase != .browsing || isSearchActive || hasQuery
    }

    private var isSearchInteractable: Bool {
        isSearchPinned
            || visibleSearchHeight >= NoteCollapsibleSearchLayout.headerHeight
                - NoteCollapsibleSearchLayout.interactionTolerance
    }

    private var isSearchFullyHidden: Bool {
        visibleSearchHeight <= NoteCollapsibleSearchLayout.interactionTolerance
    }

    var body: some View {
        GeometryReader { proxy in
            let contentViewportHeight = max(
                proxy.size.height - NoteCollapsibleSearchLayout.headerHeight,
                0
            )

            ZStack(alignment: .top) {
                ScrollView {
                    LazyVStack(
                        alignment: .leading,
                        spacing: Spacing.none
                    ) {
                        searchRevealTrack

                        content(
                            NoteCollapsibleSearchMetrics(
                                viewportHeight: contentViewportHeight,
                                emptyStateOffset: -visibleSearchHeight / 2
                            )
                        )
                        .frame(
                            maxWidth: .infinity,
                            minHeight: contentViewportHeight,
                            alignment: .top
                        )
                    }
                    .background(alignment: .topLeading) {
                        boundaryBridge
                    }
                }
                .scrollBounceBehavior(.always)

                searchDrawer
            }
            .accessibilityAction(named: "显示搜索") {
                revealSearchForAccessibility()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear(perform: synchronizeRestoredQuery)
        .onChange(of: hasQuery) { _, newValue in
            guard newValue else { return }
            searchPhase = .searching
            revealSearch(animated: false)
        }
        .onChange(of: isSearchActive) { _, newValue in
            if newValue {
                searchPhase = .searching
                revealSearch(animated: false)
            } else if !hasQuery, searchPhase == .searching {
                searchPhase = .browsing
            }
        }
        .onChange(of: isPageActive) { _, newValue in
            guard !newValue else { return }
            boundaryController.cancelProgrammaticMovement()
            isSearchActive = false
            if searchPhase == .dismissing {
                finalizeCancelSearch()
            }
        }
    }

    /// 透明轨道只提供 0...52pt 的原生滚动行程，不渲染搜索像素，也不暴露无障碍语义。
    private var searchRevealTrack: some View {
        Color.clear
            .frame(height: NoteCollapsibleSearchLayout.headerHeight)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    private var boundaryBridge: some View {
        NoteScrollBoundaryBridge(
            controller: boundaryController,
            maximumRevealHeight: NoteCollapsibleSearchLayout.headerHeight,
            isEnabled: isPageActive && !isSearchPinned,
            isPinned: isSearchPinned,
            reduceMotion: reduceMotion,
            onRevealHeightChange: updateVisibleSearchHeight
        )
        .frame(width: 0, height: 0)
        .accessibilityHidden(true)
    }

    private var searchDrawer: some View {
        ZStack(alignment: .bottom) {
            if !isSearchFullyHidden {
                searchHeaderContent
                    .padding(.vertical, NoteCollapsibleSearchLayout.verticalBreathing)
                    .padding(.horizontal, Spacing.screenEdge)
                    .frame(
                        maxWidth: .infinity,
                        minHeight: NoteCollapsibleSearchLayout.headerHeight,
                        maxHeight: NoteCollapsibleSearchLayout.headerHeight,
                        alignment: .top
                    )
                    .background(Color.surfacePage)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: visibleSearchHeight, alignment: .top)
        .clipped()
        .allowsHitTesting(isSearchInteractable)
        .accessibilityHidden(!isSearchInteractable)
        .zIndex(1)
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var searchHeaderContent: some View {
        NotePullDownSearchBar(
            text: $searchText,
            isActive: $isSearchActive,
            placeholder: placeholder,
            isAccessibilityVisible: isSearchInteractable,
            onCancel: cancelSearch
        )
    }

    /// UIKit 只回传抽屉的真实显示高度；相同高度不重复写入 SwiftUI 状态。
    private func updateVisibleSearchHeight(_ height: CGFloat) {
        guard abs(visibleSearchHeight - height) >= NoteCollapsibleSearchLayout.geometryEpsilon else {
            return
        }
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            visibleSearchHeight = height
        }
    }

    /// Scene 恢复的有效查询必须从首帧保持搜索抽屉完整展开。
    private func synchronizeRestoredQuery() {
        guard hasQuery else { return }
        searchPhase = .searching
        revealSearch(animated: false)
    }

    /// VoiceOver 不依赖下拉手势即可显示搜索；展开后恢复完整命中与可访问性语义。
    private func revealSearchForAccessibility() {
        guard !isSearchInteractable else { return }
        revealSearch(animated: true)
    }

    /// 聚焦、查询恢复和无障碍动作统一交给 UIKit 协调器，不创建第二套转场动画。
    private func revealSearch(animated: Bool) {
        boundaryController.setExpandedWhenAvailable(
            true,
            animated: animated && !reduceMotion
        )
    }

    /// 取消先稳定失焦并恢复展开端点，再清空查询，避免键盘与内容在同一帧改变几何。
    private func cancelSearch() {
        guard searchPhase != .dismissing else { return }
        searchPhase = .dismissing
        isSearchActive = false

        boundaryController.setExpanded(
            true,
            animated: !reduceMotion
        ) { _ in
            guard isPageActive else { return }
            finalizeCancelSearch()
        }
    }

    /// 在搜索抽屉已稳定的位置提交清词并回到普通浏览态，等待下一次上划自然收起。
    private func finalizeCancelSearch() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            searchText = ""
            isSearchActive = false
            searchPhase = .browsing
            visibleSearchHeight = NoteCollapsibleSearchLayout.headerHeight
        }
    }
}

/// 搜索阶段把普通浏览、固定搜索和取消收口分离，避免焦点布尔值同时承担布局语义。
private enum NoteSearchSessionPhase {
    case browsing
    case searching
    case dismissing
}

/// 搜索抽屉固定几何与高频更新容差，沿用既有首页搜索区域高度。
private enum NoteCollapsibleSearchLayout {
    static let headerHeight: CGFloat = 52
    static let verticalBreathing: CGFloat = 4
    static let interactionTolerance: CGFloat = 0.5
    static let geometryEpsilon: CGFloat = 0.25
}
