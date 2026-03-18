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

        let selectedItemID: ContentViewerItemID?
        let listState: ListState
        let itemIDs: [ContentViewerItemID]
    }

    let presentationStyle: ContentViewerPresentationStyle
    let props: Props
    let bottomChromeMetrics: ImmersiveBottomChromeMetrics
    let onPagerSelectionChanged: (ContentViewerItemID) -> Void
    let pageStateProvider: (ContentViewerItemID) -> Props.PageState
    let onLoadDetail: @MainActor @Sendable (ContentViewerItemID) async -> Void
    let onRefreshDetail: @MainActor @Sendable (ContentViewerItemID) async -> Void

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
    var pagerSelection: Binding<ContentViewerItemID?> {
        Binding(
            get: { props.selectedItemID },
            set: { newValue in
                guard let newValue, newValue != props.selectedItemID else { return }
                onPagerSelectionChanged(newValue)
            }
        )
    }

    var pager: some View {
        HorizontalPagingHost(
            ids: props.itemIDs,
            selection: pagerSelection,
            windowAnchorID: props.selectedItemID,
            windowing: .radius(3),
            onPageTask: onLoadDetail,
            onPageDidBecomeSelected: onRefreshDetail
        ) { itemID in
            ContentViewerPageView(
                state: pageStateProvider(itemID),
                presentationStyle: presentationStyle,
                bottomChromeMetrics: bottomChromeMetrics
            )
        }
    }

    var loadingState: some View {
        ProgressView(presentationStyle.loadingMessage)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    func emptyState(message: String) -> some View {
        VStack(spacing: Spacing.base) {
            Image(systemName: presentationStyle.emptyIconName)
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

/// 通用内容单页详情视图，负责页内滚动和按需加载。
private struct ContentViewerPageView: View {
    let state: ContentViewerContentView.Props.PageState
    let presentationStyle: ContentViewerPresentationStyle
    let bottomChromeMetrics: ImmersiveBottomChromeMetrics

    var body: some View {
        let readableTailBuffer = max(Spacing.base, bottomChromeMetrics.readableInset)

        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.base) {
                switch state {
                case .loading:
                    ProgressView(presentationStyle.loadingMessage)
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
