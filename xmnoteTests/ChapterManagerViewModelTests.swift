/**
 * [INPUT]: 依赖 ChapterManagerViewModel 与可控 ChapterManagementRepositoryProtocol 测试替身
 * [OUTPUT]: 验证路由身份、首次定位、观察刷新、两种删除处置及失败状态
 * [POS]: xmnoteTests 的目录管理 ViewModel TDD 测试
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Testing
@testable import xmnote

@MainActor
struct ChapterManagerViewModelTests {
    @Test
    func specifiedChapterFocusExpandsAncestorsExactlyOnce() async throws {
        let repository = ChapterManagementRepositorySpy()
        let viewModel = ChapterManagerViewModel(
            bookID: 81_001,
            bookName: "路由书名",
            doubanID: 81_777,
            focusChapterID: 81_102,
            repository: repository
        )

        viewModel.startObservation()
        repository.yield(makeSnapshot())
        try await waitUntil { viewModel.contentState == .content }

        #expect(viewModel.bookID == 81_001)
        #expect(viewModel.bookName == "路由书名")
        #expect(viewModel.doubanID == 81_777)
        #expect(viewModel.expandedIDs == [81_101])
        #expect(viewModel.pendingScrollTargetID == 81_102)

        viewModel.consumeScrollTarget(81_102)
        repository.yield(makeSnapshot())
        try await waitUntil { viewModel.pendingScrollTargetID == nil }
        #expect(viewModel.pendingScrollTargetID == nil)
    }

    @Test
    func deleteConfirmationForwardsDeleteNotesDispositionAndClearsSelectionOnSuccess() async throws {
        let repository = ChapterManagementRepositorySpy()
        let viewModel = ChapterManagerViewModel(bookID: 81_001, repository: repository)
        viewModel.startObservation()
        repository.yield(makeSnapshot())
        try await waitUntil { viewModel.contentState == .content }
        viewModel.toggleSelection(chapterID: 81_101)
        viewModel.presentDelete(chapterIDs: [81_101])

        viewModel.confirmDeletion(noteDisposition: .delete)
        try await waitUntil { repository.deleteCalls.count == 1 && !viewModel.isWriting }

        #expect(repository.deleteCalls == [DeleteCall(chapterIDs: [81_101], disposition: .delete)])
        #expect(viewModel.selectedIDs.isEmpty)
    }

    @Test
    func failedDetachDeletionKeepsSelectionAndShowsRepositoryError() async throws {
        let repository = ChapterManagementRepositorySpy()
        repository.deleteError = ChapterManagementError.invalidSelection
        let viewModel = ChapterManagerViewModel(bookID: 81_001, repository: repository)
        viewModel.startObservation()
        repository.yield(makeSnapshot())
        try await waitUntil { viewModel.contentState == .content }
        viewModel.toggleSelection(chapterID: 81_101)
        viewModel.presentDelete(chapterIDs: [81_101])

        viewModel.confirmDeletion(noteDisposition: .detach)
        try await waitUntil { viewModel.writeErrorMessage != nil && !viewModel.isWriting }

        #expect(repository.deleteCalls == [DeleteCall(chapterIDs: [81_101], disposition: .detach)])
        #expect(viewModel.selectedIDs == [81_101])
        #expect(viewModel.writeErrorMessage == ChapterManagementError.invalidSelection.localizedDescription)
    }

    @Test
    func externalEmptySnapshotClearsInvalidSelectionAndRefreshesPageState() async throws {
        let repository = ChapterManagementRepositorySpy()
        let viewModel = ChapterManagerViewModel(bookID: 81_001, repository: repository)
        viewModel.startObservation()
        repository.yield(makeSnapshot())
        try await waitUntil { viewModel.contentState == .content }
        viewModel.toggleExpanded(chapterID: 81_101)
        viewModel.toggleSelection(chapterID: 81_102)

        repository.yield(.empty(bookID: 81_001))
        try await waitUntil { viewModel.contentState == .empty }

        #expect(viewModel.snapshot.chapterCount == 0)
        #expect(viewModel.expandedIDs.isEmpty)
        #expect(viewModel.selectedIDs.isEmpty)
    }

    private func makeSnapshot() -> ChapterManagementSnapshot {
        let child = ChapterManagementNode(
            item: makeItem(
                id: 81_102,
                parentID: 81_101,
                title: "子章节",
                order: 1,
                level: 2,
                pathTitles: ["根章节", "子章节"]
            ),
            children: []
        )
        let root = ChapterManagementNode(
            item: makeItem(
                id: 81_101,
                parentID: 0,
                title: "根章节",
                order: 1,
                level: 1,
                pathTitles: ["根章节"],
                descendantNoteCount: 2,
                childCount: 1
            ),
            children: [child]
        )
        return ChapterManagementSnapshot(bookID: 81_001, roots: [root], unassignedNoteCount: 0)
    }

    private func makeItem(
        id: Int64,
        parentID: Int64,
        title: String,
        order: Int64,
        level: Int,
        pathTitles: [String],
        descendantNoteCount: Int = 0,
        childCount: Int = 0
    ) -> ChapterManagementItem {
        ChapterManagementItem(
            id: id,
            bookID: 81_001,
            parentID: parentID,
            title: title,
            remark: "",
            order: order,
            level: level,
            pathTitles: pathTitles,
            directNoteCount: 0,
            descendantNoteCount: descendantNoteCount,
            childCount: childCount,
            isStarred: false
        )
    }

    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async throws {
        for _ in 0..<200 {
            if condition() { return }
            await Task.yield()
        }
        Issue.record("异步状态未在期限内收敛")
    }
}

private struct DeleteCall: Equatable {
    let chapterIDs: [Int64]
    let disposition: ChapterNoteDisposition
}

private final class ChapterManagementRepositorySpy: ChapterManagementRepositoryProtocol {
    private var continuation: AsyncThrowingStream<ChapterManagementSnapshot, Error>.Continuation?
    var deleteCalls: [DeleteCall] = []
    var deleteError: Error?

    func observeSnapshot(bookID: Int64) -> AsyncThrowingStream<ChapterManagementSnapshot, Error> {
        AsyncThrowingStream { continuation in
            self.continuation = continuation
        }
    }

    func yield(_ snapshot: ChapterManagementSnapshot) {
        continuation?.yield(snapshot)
    }

    func discoverRemoteCatalog(bookID: Int64) async throws -> ChapterRemoteCatalogDiscovery {
        throw ChapterManagementError.invalidBook
    }

    func fetchRemoteConfigurationState() async -> ChapterRemoteConfigurationState { .unavailable }

    func importRemoteCatalog(bookID: Int64, titles: [String]) async throws -> ChapterRemoteImportResult {
        ChapterRemoteImportResult(importedChapterCount: 0, reusedChapterCount: 0)
    }

    func importChapterBatch(bookID: Int64, draft: ChapterBatchImportDraft) async throws -> ChapterBatchImportResult {
        throw ChapterManagementError.invalidSelection
    }

    func createChapter(bookID: Int64, parentID: Int64, title: String) async throws -> Int64 { 0 }
    func renameChapter(bookID: Int64, chapterID: Int64, title: String) async throws { }
    func setChapterStarred(bookID: Int64, chapterID: Int64, isStarred: Bool) async throws { }

    func reorderSiblings(
        bookID: Int64,
        parentID: Int64,
        orderedChapterIDs: [Int64]
    ) async throws -> ChapterStructureRestoreSnapshot {
        throw ChapterManagementError.invalidSiblingOrder
    }

    func moveChapters(
        bookID: Int64,
        chapterIDs: [Int64],
        targetParentID: Int64
    ) async throws -> ChapterStructureRestoreSnapshot {
        throw ChapterManagementError.invalidSelection
    }

    func restoreChapterStructure(_ snapshot: ChapterStructureRestoreSnapshot) async throws { }

    func deleteChapters(
        bookID: Int64,
        chapterIDs: [Int64],
        noteDisposition: ChapterNoteDisposition
    ) async throws -> ChapterDeletionResult {
        deleteCalls.append(DeleteCall(chapterIDs: chapterIDs, disposition: noteDisposition))
        if let deleteError { throw deleteError }
        return ChapterDeletionResult(
            deletedChapterCount: chapterIDs.count,
            affectedNoteCount: 0,
            unassignedNoteCount: noteDisposition == .detach ? 1 : 0,
            deletedNoteCount: noteDisposition == .delete ? 1 : 0
        )
    }

    func deleteDescendants(
        bookID: Int64,
        parentID: Int64,
        noteDisposition: ChapterNoteDisposition
    ) async throws -> ChapterDeletionResult {
        try await deleteChapters(
            bookID: bookID,
            chapterIDs: [parentID],
            noteDisposition: noteDisposition
        )
    }
}
