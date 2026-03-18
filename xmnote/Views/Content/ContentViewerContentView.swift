/**
 * [INPUT]: 依赖内容分页 Props 快照、加载/刷新/切页回调与 DesignTokens 视觉令牌
 * [OUTPUT]: 对外提供 ContentViewerContentView，承接书摘/书评/相关内容的统一横向分页与单页纵向滚动
 * [POS]: Content 模块通用内容查看业务内容壳层，对齐阅读日历与书摘查看的自建 paging 架构
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 通用内容查看业务内容壳层，负责空态、横向分页和单页详情滚动。
struct ContentViewerContentView: View {
    /// 渲染所需的分页快照。
    struct Props {
        /// 内容列表根状态，区分加载中、空态和可分页内容。
        enum ListState: Equatable {
            case loading
            case empty(String)
            case content
        }

        /// 单页渲染状态，避免内容壳层直接读取 ViewModel。
        enum PageState: Equatable {
            case loading
            case error(String)
            case detail(ContentViewerDetail)
        }

        /// 单页渲染快照，承接分页窗口内的内容页面。
        struct Page: Identifiable, Equatable {
            let item: ContentViewerListItem
            let state: PageState
            let isSelected: Bool

            var id: ContentViewerItemID { item.id }
        }

        let selectedItemID: ContentViewerItemID?
        let listState: ListState
        let pages: [Page]
    }

    let props: Props
    let bottomChromeMetrics: ImmersiveBottomChromeMetrics
    let onPagerSelectionChanged: (ContentViewerItemID) -> Void
    let onLoadDetail: (ContentViewerItemID) async -> Void
    let onRefreshDetail: (ContentViewerItemID) async -> Void

    @State private var horizontalPagerPosition: ContentViewerItemID?
    @State private var isHorizontalPagerInteractionActive = false
    @State private var pendingPagerSelectionCommit: ContentViewerItemID?

    var body: some View {
        Group {
            switch props.listState {
            case .loading:
                loadingState
            case .empty(let message):
                emptyState(message: message)
            case .content:
                pager
            }
        }
        .background(Color.surfacePage)
    }
}

private extension ContentViewerContentView {
    var visibleItemIDs: [ContentViewerItemID] {
        props.pages.map(\.item.id)
    }

    var pager: some View {
        GeometryReader { proxy in
            let pageWidth = max(1, proxy.size.width)
            let pageHeight = max(1, proxy.size.height)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Spacing.none) {
                    ForEach(props.pages) { page in
                        ContentViewerPageView(
                            page: page,
                            bottomChromeMetrics: bottomChromeMetrics,
                            onLoadDetail: onLoadDetail,
                            onRefreshDetail: onRefreshDetail
                        )
                        .frame(width: pageWidth, height: pageHeight, alignment: .top)
                        .id(page.item.id)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $horizontalPagerPosition, anchor: .topLeading)
            .onAppear {
                syncHorizontalPagerPositionIfNeeded(itemID: props.selectedItemID, animated: false)
            }
            .onChange(of: props.selectedItemID) { _, itemID in
                guard !isHorizontalPagerInteractionActive else { return }
                pendingPagerSelectionCommit = nil
                syncHorizontalPagerPositionIfNeeded(itemID: itemID, animated: true)
            }
            .onChange(of: visibleItemIDs) { _, window in
                guard !window.isEmpty else {
                    horizontalPagerPosition = nil
                    pendingPagerSelectionCommit = nil
                    return
                }

                if let pending = pendingPagerSelectionCommit, !window.contains(pending) {
                    pendingPagerSelectionCommit = nil
                }

                guard let current = horizontalPagerPosition, window.contains(current) else {
                    guard !isHorizontalPagerInteractionActive else { return }
                    syncHorizontalPagerPositionIfNeeded(itemID: props.selectedItemID, animated: false)
                    return
                }
            }
            .onChange(of: horizontalPagerPosition) { _, itemID in
                guard let itemID, visibleItemIDs.contains(itemID) else { return }
                if isHorizontalPagerInteractionActive {
                    pendingPagerSelectionCommit = itemID
                    return
                }
                guard itemID != props.selectedItemID else { return }
                onPagerSelectionChanged(itemID)
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
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    var loadingState: some View {
        ProgressView("正在加载内容…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func emptyState(message: String) -> some View {
        VStack(spacing: Spacing.base) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(message)
                .font(AppTypography.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Spacing.screenEdge)
    }

    /// 将外部选中态同步到横向分页位置，避免窗口重建后错页。
    func syncHorizontalPagerPositionIfNeeded(itemID: ContentViewerItemID?, animated: Bool) {
        guard let itemID, visibleItemIDs.contains(itemID) else { return }
        guard horizontalPagerPosition != itemID else { return }

        if animated {
            withAnimation(.snappy(duration: 0.24)) {
                horizontalPagerPosition = itemID
            }
            return
        }

        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            horizontalPagerPosition = itemID
        }
    }

    /// 横向滚动结束后再提交最终页，避免滑动过程中反复回写业务状态。
    func commitPendingPagerSelectionIfNeeded() {
        defer { pendingPagerSelectionCommit = nil }

        if let pending = pendingPagerSelectionCommit,
           visibleItemIDs.contains(pending),
           pending != props.selectedItemID {
            onPagerSelectionChanged(pending)
            return
        }

        if let current = horizontalPagerPosition,
           !visibleItemIDs.contains(current) {
            syncHorizontalPagerPositionIfNeeded(itemID: props.selectedItemID, animated: false)
        }
    }
}

/// 通用内容单页详情视图，负责页内滚动和按需加载。
private struct ContentViewerPageView: View {
    let page: ContentViewerContentView.Props.Page
    let bottomChromeMetrics: ImmersiveBottomChromeMetrics
    let onLoadDetail: (ContentViewerItemID) async -> Void
    let onRefreshDetail: (ContentViewerItemID) async -> Void

    var body: some View {
        let readableTailBuffer = max(Spacing.base, bottomChromeMetrics.readableInset)

        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.base) {
                switch page.state {
                case .loading:
                    ProgressView("正在加载内容…")
                        .frame(maxWidth: .infinity, minHeight: 320)
                case .error(let message):
                    viewerMessageCard(text: message)
                case .detail(let detail):
                    detailBody(detail)
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.top, Spacing.base)

            Color.clear
                .frame(height: readableTailBuffer)
        }
        .background(Color.surfacePage)
        .contentMargins(.bottom, Spacing.none, for: .scrollContent)
        .contentMargins(.bottom, bottomChromeMetrics.scrollIndicatorInset, for: .scrollIndicators)
        .ignoresSafeArea(.container, edges: .bottom)
        .task(id: page.item.id) {
            await onLoadDetail(page.item.id)
        }
        .onAppear {
            guard page.isSelected else { return }
            Task { await onRefreshDetail(page.item.id) }
        }
        .onChange(of: page.isSelected) { _, isSelected in
            guard isSelected else { return }
            Task { await onRefreshDetail(page.item.id) }
        }
    }

    @ViewBuilder
    private func detailBody(_ detail: ContentViewerDetail) -> some View {
        switch detail {
        case .note(let note):
            NoteContentDetailBody(detail: note)
        case .review(let review):
            ReviewContentDetailBody(detail: review)
        case .relevant(let relevant):
            RelevantContentDetailBody(detail: relevant)
        }
    }
}
