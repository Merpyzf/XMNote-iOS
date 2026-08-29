/**
 * [INPUT]: 依赖 NoteRepositoryProtocol 的相关分类/内容观察流与 ContentRepositoryProtocol 的关系软删除接口
 * [OUTPUT]: 对外提供 RelatedCategoryListPhase 与 RelatedCategoryListViewModel
 * [POS]: ViewModels/Note 的相关内容状态层，隔离列表搜索分页与关系软删除事务
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 相关列表与管理页共用的读取阶段。
enum RelatedCategoryListPhase: Equatable {
    case loading
    case content
    case empty
    case failure(String)
}

private enum RelatedCategoryListPolicy {
    static let pageSize = 30
    static let searchDelay: Duration = .milliseconds(200)
}

@MainActor
@Observable
/// 单个相关分类的混排列表状态源，普通内容和相关书籍保持不同业务跳转。
final class RelatedCategoryListViewModel {
    let scope: RelatedCategoryScope
    var searchText = "" {
        didSet {
            guard normalized(oldValue) != normalized(searchText) else { return }
            scheduleRestart()
        }
    }
    var sort: RelatedContentSortRule = .createdDescending {
        didSet {
            guard oldValue != sort else { return }
            restartObservation(resetsPagination: true)
        }
    }

    private(set) var items: [RelatedListItem] = []
    private(set) var totalCount = 0
    private(set) var phase: RelatedCategoryListPhase = .loading
    private(set) var observationErrorMessage: String?
    private(set) var isLoadingMore = false
    private(set) var isWriting = false

    private let noteRepository: any NoteRepositoryProtocol
    private let contentRepository: any ContentRepositoryProtocol
    private var randomSeed: Int64
    private var requestedLimit = RelatedCategoryListPolicy.pageSize
    private var observationTask: Task<Void, Never>?
    private var searchTask: Task<Void, Never>?

    /// 注入两个职责明确的 Repository；读取由 NoteRepository 聚合，关系删除由 ContentRepository 事务完成。
    init(
        scope: RelatedCategoryScope,
        noteRepository: any NoteRepositoryProtocol,
        contentRepository: any ContentRepositoryProtocol
    ) {
        self.scope = scope
        self.noteRepository = noteRepository
        self.contentRepository = contentRepository
        self.randomSeed = Int64.random(in: 1...Int64.max)
        startObservation()
    }

    var normalizedSearchText: String { normalized(searchText) }
    var hasMore: Bool { items.count < totalCount }
    var viewerSource: ContentViewerSourceContext {
        .relatedCategory(
            scope: scope,
            query: normalizedSearchText,
            sort: sort,
            randomSeed: randomSeed
        )
    }

    /// 最后一项出现时扩大稳定查询窗口，避免 offset 分页在并发删除后漏项。
    func loadMoreIfNeeded(currentItemID: RelatedListItemID) {
        guard hasMore, !isLoadingMore, items.last?.id == currentItemID else { return }
        isLoadingMore = true
        requestedLimit += RelatedCategoryListPolicy.pageSize
        restartObservation(resetsPagination: false)
    }

    func retry() {
        restartObservation(resetsPagination: items.isEmpty)
    }

    /// 随机分页期间保持 seed 稳定，仅在用户主动“重新随机”时生成新顺序并回到第一页。
    func reshuffleRandomOrder() {
        guard sort == .random else { return }
        randomSeed = Int64.random(in: 1...Int64.max)
        restartObservation(resetsPagination: true)
    }

    /// 软删除普通相关内容或相关书籍关系；书籍实体始终由 Book Repository 管理。
    func deleteRelation(_ item: RelatedListItem) async throws {
        guard !isWriting else { return }
        isWriting = true
        defer { isWriting = false }
        try await contentRepository.deleteRelatedRelation(relationID: item.relationID)
        try Task.checkCancellation()
    }

    isolated deinit {
        observationTask?.cancel()
        searchTask?.cancel()
    }

    /// 当前 query/sort/seed 绑定一个数据库观察任务，取消时不会把旧快照写回新页面条件。
    private func startObservation() {
        observationErrorMessage = nil
        if items.isEmpty { phase = .loading }
        let stream = noteRepository.observeRelatedContentList(
            request: RelatedContentPageRequest(
                scope: scope,
                query: normalizedSearchText,
                sort: sort,
                randomSeed: randomSeed,
                offset: 0,
                limit: requestedLimit
            )
        )
        observationTask = Task { [weak self] in
            do {
                for try await snapshot in stream {
                    guard !Task.isCancelled, let self else { return }
                    self.items = snapshot.items
                    self.totalCount = snapshot.totalCount
                    self.isLoadingMore = false
                    self.observationErrorMessage = nil
                    self.phase = snapshot.items.isEmpty ? .empty : .content
                }
            } catch {
                guard !Task.isCancelled, let self else { return }
                self.isLoadingMore = false
                if self.items.isEmpty {
                    self.phase = .failure("暂时无法加载相关内容")
                } else {
                    self.phase = .content
                    self.observationErrorMessage = "相关内容刷新失败"
                }
            }
        }
    }

    private func scheduleRestart() {
        searchTask?.cancel()
        searchTask = Task { [weak self] in
            do {
                try await Task.sleep(for: RelatedCategoryListPolicy.searchDelay)
                try Task.checkCancellation()
                self?.restartObservation(resetsPagination: true)
            } catch {
                return
            }
        }
    }

    private func restartObservation(resetsPagination: Bool) {
        observationTask?.cancel()
        if resetsPagination {
            requestedLimit = RelatedCategoryListPolicy.pageSize
            isLoadingMore = false
        }
        startObservation()
    }

    private func normalized(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
