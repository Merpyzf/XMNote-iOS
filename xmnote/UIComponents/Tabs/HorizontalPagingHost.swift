/**
 * [INPUT]: 依赖 SwiftUI ScrollView paging 能力，接收稳定 ID、选中态绑定与页面内容构建闭包
 * [OUTPUT]: 对外提供 HorizontalPagingHost（横向分页 + 窗口化懒挂载 + 页级生命周期回调）
 * [POS]: UIComponents/Tabs 的通用横向分页宿主，被阅读日历与内容查看页复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 通用横向分页宿主，统一处理分页吸附、选中同步、窗口化懒挂载与页级生命周期。
struct HorizontalPagingHost<ID: Hashable & Sendable, PageContent: View>: View {
    /// 控制横向分页的挂载窗口范围。
    enum WindowingStrategy: Equatable {
        case all
        case radius(Int)
    }

    let ids: [ID]
    @Binding var selection: ID?
    let windowAnchorID: ID?
    var windowing: WindowingStrategy = .all
    var showsIndicators = false
    var pageAlignment: Alignment = .top
    var programmaticScrollAnimation: Animation = .snappy(duration: 0.24)
    var onPageTask: (@MainActor @Sendable (ID) async -> Void)? = nil
    var onPageDidBecomeSelected: (@MainActor @Sendable (ID) async -> Void)? = nil
    private let content: (ID) -> PageContent

    @State private var horizontalPagerPosition: ID?
    @State private var isHorizontalPagerInteractionActive = false
    @State private var pendingPagerSelectionCommit: ID?
    @State private var settledSelectionID: ID?

    /// 注入分页 ID 列表、外部选中态与页面构建闭包，组装统一横向分页宿主。
    init(
        ids: [ID],
        selection: Binding<ID?>,
        windowAnchorID: ID? = nil,
        windowing: WindowingStrategy = .all,
        showsIndicators: Bool = false,
        pageAlignment: Alignment = .top,
        programmaticScrollAnimation: Animation = .snappy(duration: 0.24),
        onPageTask: (@MainActor @Sendable (ID) async -> Void)? = nil,
        onPageDidBecomeSelected: (@MainActor @Sendable (ID) async -> Void)? = nil,
        @ViewBuilder content: @escaping (ID) -> PageContent
    ) {
        self.ids = ids
        self._selection = selection
        self.windowAnchorID = windowAnchorID
        self.windowing = windowing
        self.showsIndicators = showsIndicators
        self.pageAlignment = pageAlignment
        self.programmaticScrollAnimation = programmaticScrollAnimation
        self.onPageTask = onPageTask
        self.onPageDidBecomeSelected = onPageDidBecomeSelected
        self.content = content
    }

    var body: some View {
        GeometryReader { proxy in
            let pageWidth = max(1, proxy.size.width)
            let pageHeight = max(1, proxy.size.height)

            ScrollView(.horizontal, showsIndicators: showsIndicators) {
                LazyHStack(spacing: Spacing.none) {
                    ForEach(visibleIDs, id: \.self) { id in
                        HorizontalPagingLifecycleContainer(
                            id: id,
                            isSelected: id == settledSelectionID,
                            onPageTask: onPageTask,
                            onPageDidBecomeSelected: onPageDidBecomeSelected
                        ) {
                            content(id)
                        }
                        .frame(width: pageWidth, height: pageHeight, alignment: pageAlignment)
                        .id(id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $horizontalPagerPosition, anchor: .topLeading)
            .onAppear {
                normalizeState(syncPositionIfNeeded: true)
            }
            .onChange(of: ids) { _, _ in
                normalizeState(syncPositionIfNeeded: true)
            }
            .onChange(of: windowAnchorID) { _, _ in
                normalizeState(syncPositionIfNeeded: true)
            }
            .onChange(of: selection) { _, newID in
                guard !isHorizontalPagerInteractionActive else { return }
                syncSelectionChange(newID)
            }
            .onChange(of: visibleIDs) { _, window in
                guard !window.isEmpty else {
                    clearInternalState()
                    return
                }

                if let pending = pendingPagerSelectionCommit, !window.contains(pending) {
                    pendingPagerSelectionCommit = nil
                }

                if let current = validID(horizontalPagerPosition),
                   !window.contains(current) {
                    let fallback = validID(selection) ?? validWindowAnchorID ?? window.first
                    syncHorizontalPagerPositionIfNeeded(id: fallback, animated: false)
                    return
                }
            }
            .onChange(of: horizontalPagerPosition) { _, id in
                guard let id = validID(id), visibleIDs.contains(id) else { return }
                if isHorizontalPagerInteractionActive {
                    pendingPagerSelectionCommit = id
                    return
                }
                settledSelectionID = id
                guard validID(selection) != nil else { return }
                guard id != selection else { return }
                selection = id
            }
            .onScrollPhaseChange { _, phase in
                if phase.isScrolling {
                    isHorizontalPagerInteractionActive = true
                    return
                }

                guard isHorizontalPagerInteractionActive else { return }
                isHorizontalPagerInteractionActive = false
                commitPendingPagerSelectionIfNeeded()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: pageAlignment)
    }
}

private extension HorizontalPagingHost {
    var validWindowAnchorID: ID? {
        if let windowAnchorID = validID(windowAnchorID) {
            return windowAnchorID
        }
        if let selection = validID(selection) {
            return selection
        }
        if let horizontalPagerPosition = validID(horizontalPagerPosition) {
            return horizontalPagerPosition
        }
        return ids.first
    }

    var visibleIDs: [ID] {
        guard !ids.isEmpty else { return [] }

        switch windowing {
        case .all:
            return ids
        case .radius(let radius):
            guard let bounds = windowBounds(around: validWindowAnchorID, radius: radius) else {
                return ids
            }
            return Array(ids[bounds])
        }
    }

    /// 过滤失效状态并在需要时把滚动位置收敛到当前有效页，避免数据源变化后残留陈旧状态。
    func normalizeState(syncPositionIfNeeded: Bool) {
        guard !ids.isEmpty else {
            clearInternalState()
            return
        }

        if validID(pendingPagerSelectionCommit) == nil {
            pendingPagerSelectionCommit = nil
        }
        if validID(horizontalPagerPosition) == nil {
            horizontalPagerPosition = nil
        }
        if validID(settledSelectionID) == nil {
            settledSelectionID = validID(selection) ?? validID(horizontalPagerPosition) ?? ids.first
        }

        guard syncPositionIfNeeded else { return }
        let targetID = validID(selection)
            ?? validWindowAnchorID
            ?? ids.first
        syncHorizontalPagerPositionIfNeeded(id: targetID, animated: false)
    }

    /// 根据外部选中态变化同步滚动位置，并在无需滚动时直接提交生命周期选中态。
    func syncSelectionChange(_ newID: ID?) {
        guard let newID = validID(newID) else {
            normalizeState(syncPositionIfNeeded: true)
            return
        }

        if validID(horizontalPagerPosition) == newID {
            settledSelectionID = newID
            syncHorizontalPagerPositionIfNeeded(id: newID, animated: false)
            return
        }

        pendingPagerSelectionCommit = nil
        syncHorizontalPagerPositionIfNeeded(id: newID, animated: true)
    }

    /// 将外部选中态同步到横向分页位置，避免窗口重建后发生错页。
    func syncHorizontalPagerPositionIfNeeded(id: ID?, animated: Bool) {
        guard let id = validID(id), visibleIDs.contains(id) else { return }
        guard horizontalPagerPosition != id else { return }

        if animated {
            withAnimation(programmaticScrollAnimation) {
                horizontalPagerPosition = id
            }
            return
        }

        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            horizontalPagerPosition = id
        }
    }

    /// 在横向滚动结束时提交待生效页，避免滚动中频繁回写业务选中态。
    func commitPendingPagerSelectionIfNeeded() {
        defer { pendingPagerSelectionCommit = nil }

        let finalID = validID(pendingPagerSelectionCommit)
            ?? validID(horizontalPagerPosition)

        if let finalID {
            settledSelectionID = finalID
            if finalID != selection {
                selection = finalID
            }
            return
        }

        let fallback = validID(selection) ?? validWindowAnchorID ?? ids.first
        settledSelectionID = fallback
        syncHorizontalPagerPositionIfNeeded(id: fallback, animated: false)
    }

    /// 基于稳定 ID 计算分页窗口索引区间，保证挂载集合只围绕可达页面展开。
    func windowBounds(around centerID: ID?, radius: Int) -> ClosedRange<Int>? {
        let resolvedRadius = max(0, radius)
        guard
            let centerID = validID(centerID),
            let centerIndex = ids.firstIndex(of: centerID)
        else {
            guard !ids.isEmpty else { return nil }
            let upperBound = min(ids.count - 1, resolvedRadius * 2)
            return 0...upperBound
        }

        let lowerBound = max(0, centerIndex - resolvedRadius)
        let upperBound = min(ids.count - 1, centerIndex + resolvedRadius)
        return lowerBound...upperBound
    }

    func validID(_ id: ID?) -> ID? {
        guard let id, ids.contains(id) else { return nil }
        return id
    }

    func clearInternalState() {
        horizontalPagerPosition = nil
        isHorizontalPagerInteractionActive = false
        pendingPagerSelectionCommit = nil
        settledSelectionID = nil
    }
}

/// 单页生命周期包裹器：统一把加载与“成为当前页”事件绑定到分页宿主。
private struct HorizontalPagingLifecycleContainer<ID: Hashable & Sendable, Content: View>: View {
    let id: ID
    let isSelected: Bool
    let onPageTask: (@MainActor @Sendable (ID) async -> Void)?
    let onPageDidBecomeSelected: (@MainActor @Sendable (ID) async -> Void)?
    private let content: Content

    init(
        id: ID,
        isSelected: Bool,
        onPageTask: (@MainActor @Sendable (ID) async -> Void)?,
        onPageDidBecomeSelected: (@MainActor @Sendable (ID) async -> Void)?,
        @ViewBuilder content: () -> Content
    ) {
        self.id = id
        self.isSelected = isSelected
        self.onPageTask = onPageTask
        self.onPageDidBecomeSelected = onPageDidBecomeSelected
        self.content = content()
    }

    var body: some View {
        content
            .task(id: id) {
                guard let onPageTask else { return }
                await onPageTask(id)
            }
            .task(id: isSelected) {
                guard isSelected, let onPageDidBecomeSelected else { return }
                await onPageDidBecomeSelected(id)
            }
    }
}
