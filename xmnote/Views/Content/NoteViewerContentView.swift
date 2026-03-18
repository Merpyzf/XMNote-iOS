/**
 * [INPUT]: 依赖书摘分页 Props 快照、加载/刷新/切页回调与 DesignTokens 视觉令牌
 * [OUTPUT]: 对外提供 NoteViewerContentView，承接书摘查看的横向分页与单页纵向滚动
 * [POS]: Content 模块书摘查看业务内容壳层，对齐阅读日历的自建 paging 架构
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

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

        let selectedNoteID: Int64?
        let listState: ListState
        let noteIDs: [Int64]
    }

    let props: Props
    let bottomChromeMetrics: ImmersiveBottomChromeMetrics
    let onPagerSelectionChanged: (Int64) -> Void
    let notePageStateProvider: (Int64) -> Props.NotePageState
    let onLoadDetail: @MainActor @Sendable (Int64) async -> Void
    let onRefreshDetail: @MainActor @Sendable (Int64) async -> Void

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
    var pagerSelection: Binding<Int64?> {
        Binding(
            get: { props.selectedNoteID },
            set: { newValue in
                guard let newValue, newValue != props.selectedNoteID else { return }
                onPagerSelectionChanged(newValue)
            }
        )
    }

    var pager: some View {
        HorizontalPagingHost(
            ids: props.noteIDs,
            selection: pagerSelection,
            windowAnchorID: props.selectedNoteID,
            windowing: .radius(3),
            onPageTask: onLoadDetail,
            onPageDidBecomeSelected: onRefreshDetail
        ) { noteID in
            NoteViewerPage(
                state: notePageStateProvider(noteID),
                bottomChromeMetrics: bottomChromeMetrics
            )
        }
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
}

/// 单页书摘详情视图，负责页内滚动和按需加载。
private struct NoteViewerPage: View {
    let state: NoteViewerContentView.Props.NotePageState
    let bottomChromeMetrics: ImmersiveBottomChromeMetrics

    var body: some View {
        let immersiveBottomInset = Spacing.none
        let readableTailBuffer = max(Spacing.base, bottomChromeMetrics.readableInset)

        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.base) {
                switch state {
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
    }
}
