/**
 * [INPUT]: 依赖 ContentViewerContentView.Props.ListState 的列表事实映射
 * [OUTPUT]: 验证 loading、empty、failure、content 与保留内容错误的互斥语义
 * [POS]: xmnoteTests 的 Content Viewer 状态回归测试，保护失败不伪装为空态
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Testing
@testable import xmnote

@MainActor
struct ContentViewerStateMappingTests {
    @Test
    func emptyListMapsLoadingEmptyAndFailureSeparately() {
        let placeholder = ContentViewerContentView.Props.ListState.resolve(
            isEmpty: true,
            isLoading: true,
            isLoadingVisible: false,
            errorMessage: nil,
            emptyMessage: "暂无内容"
        )
        let loading = ContentViewerContentView.Props.ListState.resolve(
            isEmpty: true,
            isLoading: true,
            isLoadingVisible: true,
            errorMessage: nil,
            emptyMessage: "暂无内容"
        )
        let empty = ContentViewerContentView.Props.ListState.resolve(
            isEmpty: true,
            isLoading: false,
            isLoadingVisible: false,
            errorMessage: nil,
            emptyMessage: "暂无内容"
        )
        let failure = ContentViewerContentView.Props.ListState.resolve(
            isEmpty: true,
            isLoading: false,
            isLoadingVisible: false,
            errorMessage: "请检查后重试",
            emptyMessage: "暂无内容"
        )

        #expect(placeholder == .placeholder)
        #expect(loading == .loading)
        #expect(empty == .empty("暂无内容"))
        #expect(failure == .failure("请检查后重试"))
    }

    @Test
    func trustedContentRemainsContentWhenRefreshFails() {
        let state = ContentViewerContentView.Props.ListState.resolve(
            isEmpty: false,
            isLoading: false,
            isLoadingVisible: false,
            errorMessage: "刷新失败",
            emptyMessage: "暂无内容"
        )

        #expect(state == .content)
    }
}
