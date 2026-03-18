/**
 * [INPUT]: 依赖书摘分页 Props 快照、加载/刷新/切页回调与 DesignTokens 视觉令牌
 * [OUTPUT]: 对外提供 NoteViewerContentView，承接书摘查看的横向分页与单页纵向滚动
 * [POS]: Content 模块书摘查看业务内容壳层，对齐阅读日历的自建 paging 架构
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 书摘查看业务内容壳层，负责空态、横向分页和单页详情滚动。
struct NoteViewerContentView: View {
    /// 渲染所需的书摘分页快照。
    struct Props {
        /// 书摘列表根状态，区分加载中、空态和可分页内容。
        enum ListState: Equatable {
            case loading
            case empty(String)
            case content
        }

        /// 单页渲染状态，避免内容壳层直接读取 ViewModel。
        enum NotePageState: Equatable {
            case loading
            case error(String)
            case detail(NoteContentDetail)
        }

        /// 单页渲染快照，承接分页窗口内的书摘页面。
        struct NotePage: Identifiable, Equatable {
            let noteID: Int64
            let state: NotePageState
            let isSelected: Bool

            var id: Int64 { noteID }
        }

        let selectedNoteID: Int64?
        let listState: ListState
        let notePages: [NotePage]
    }

    let props: Props
    let bottomChromeMetrics: ImmersiveBottomChromeMetrics
    let onPagerSelectionChanged: (Int64) -> Void
    let onLoadDetail: (Int64) async -> Void
    let onRefreshDetail: (Int64) async -> Void

    @State private var horizontalPagerPosition: Int64?
    @State private var isHorizontalPagerInteractionActive = false
    @State private var pendingPagerSelectionCommit: Int64?

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

private extension NoteViewerContentView {
    var visibleNoteIDs: [Int64] {
        props.notePages.map(\.noteID)
    }

    var pager: some View {
        GeometryReader { proxy in
            let pageWidth = max(1, proxy.size.width)
            let pageHeight = max(1, proxy.size.height)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: Spacing.none) {
                    ForEach(props.notePages) { page in
                        NoteViewerPage(
                            page: page,
                            bottomChromeMetrics: bottomChromeMetrics,
                            onLoadDetail: onLoadDetail,
                            onRefreshDetail: onRefreshDetail
                        )
                        .frame(width: pageWidth, height: pageHeight, alignment: .top)
                        .id(page.noteID)
                    }
                }
                .scrollTargetLayout()
            }
            .scrollTargetBehavior(.paging)
            .scrollPosition(id: $horizontalPagerPosition, anchor: .topLeading)
            .onAppear {
                syncHorizontalPagerPositionIfNeeded(noteID: props.selectedNoteID, animated: false)
            }
            .onChange(of: props.selectedNoteID) { _, noteID in
                guard !isHorizontalPagerInteractionActive else { return }
                pendingPagerSelectionCommit = nil
                syncHorizontalPagerPositionIfNeeded(noteID: noteID, animated: true)
            }
            .onChange(of: visibleNoteIDs) { _, window in
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
                    syncHorizontalPagerPositionIfNeeded(noteID: props.selectedNoteID, animated: false)
                    return
                }
            }
            .onChange(of: horizontalPagerPosition) { _, noteID in
                guard let noteID, visibleNoteIDs.contains(noteID) else { return }
                if isHorizontalPagerInteractionActive {
                    pendingPagerSelectionCommit = noteID
                    return
                }
                guard noteID != props.selectedNoteID else { return }
                onPagerSelectionChanged(noteID)
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
        ProgressView("正在加载书摘…")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func emptyState(message: String) -> some View {
        VStack(spacing: Spacing.base) {
            Image(systemName: "text.quote")
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
    func syncHorizontalPagerPositionIfNeeded(noteID: Int64?, animated: Bool) {
        guard let noteID, visibleNoteIDs.contains(noteID) else { return }
        guard horizontalPagerPosition != noteID else { return }

        if animated {
            withAnimation(.snappy(duration: 0.24)) {
                horizontalPagerPosition = noteID
            }
            return
        }

        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            horizontalPagerPosition = noteID
        }
    }

    /// 横向滚动结束后再提交最终页，避免滑动过程中反复回写业务状态。
    func commitPendingPagerSelectionIfNeeded() {
        defer { pendingPagerSelectionCommit = nil }

        if let pending = pendingPagerSelectionCommit,
           visibleNoteIDs.contains(pending),
           pending != props.selectedNoteID {
            onPagerSelectionChanged(pending)
            return
        }

        if let current = horizontalPagerPosition,
           !visibleNoteIDs.contains(current) {
            syncHorizontalPagerPositionIfNeeded(noteID: props.selectedNoteID, animated: false)
        }
    }
}

/// 单页书摘详情视图，负责页内滚动和按需加载。
private struct NoteViewerPage: View {
    let page: NoteViewerContentView.Props.NotePage
    let bottomChromeMetrics: ImmersiveBottomChromeMetrics
    let onLoadDetail: (Int64) async -> Void
    let onRefreshDetail: (Int64) async -> Void

    var body: some View {
        let immersiveBottomInset = Spacing.none
        let readableTailBuffer = max(Spacing.base, bottomChromeMetrics.readableInset)

        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.base) {
                switch page.state {
                case .loading:
                    ProgressView("正在加载书摘…")
                        .frame(maxWidth: .infinity, minHeight: 320)
                case .error(let message):
                    viewerMessageCard(text: message)
                case .detail(let detail):
                    NoteContentDetailBody(detail: detail)
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.top, Spacing.base)
            .padding(.bottom, immersiveBottomInset)

            Color.clear
                .frame(height: readableTailBuffer)
        }
        .background(Color.surfacePage)
        .contentMargins(.bottom, Spacing.none, for: .scrollContent)
        .contentMargins(.bottom, bottomChromeMetrics.scrollIndicatorInset, for: .scrollIndicators)
        .ignoresSafeArea(.container, edges: .bottom)
        .task(id: page.noteID) {
            await onLoadDetail(page.noteID)
        }
        .onAppear {
            guard page.isSelected else { return }
            Task { await onRefreshDetail(page.noteID) }
        }
        .onChange(of: page.isSelected) { _, isSelected in
            guard isSelected else { return }
            Task { await onRefreshDetail(page.noteID) }
        }
    }

}
