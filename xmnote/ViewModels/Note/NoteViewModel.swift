/**
 * [INPUT]: 依赖 NoteRepositoryProtocol 提供笔记首页四分类聚合观察流，依赖 ContentRepositoryProtocol/BookDetailRepositoryProtocol 承接书评软删除与单本评分，依赖 NoteCategory 与 NoteCollectionModels 描述筛选/排序语义
 * [OUTPUT]: 对外提供 NoteViewModel 与 NoteHomeSectionState，输出四分类独立搜索/排序、书评增量分页状态及星标/相关分类/书评写入动作
 * [POS]: Note 模块首页状态编排器，被 NoteContainerView、NoteCollectionView 与 NoteTagsView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 首页单分类的稳定阶段，内容刷新期间保留已展示数据，首屏才进入 loading。
enum NoteHomeSectionState: Equatable {
    case loading
    case content
    case empty
    case error(String)
}

private enum NoteHomeSearchPolicy {
    static let delay: Duration = .milliseconds(200)
}

private enum NoteBookReviewPagingPolicy {
    static let pageSize = 40
}

/// 首页写入互斥门闩的可行动错误，避免并发点击被静默吞掉。
private nonisolated enum NoteHomeWriteError: LocalizedError {
    case operationInProgress
    case ratingRepositoryUnavailable

    var errorDescription: String? {
        switch self {
        case .operationInProgress:
            return "有操作正在进行，请稍后再试"
        case .ratingRepositoryUnavailable:
            return "当前页面暂时无法更新书籍评分"
        }
    }
}

@MainActor
@Observable
/// 笔记首页状态源，集中维护四分类选择、页内搜索、分类排序与 Repository 观察任务。
final class NoteViewModel {
    var selectedCategory: NoteCategory = .excerpts
    private var searchTexts: [NoteCategory: String] = [:]
    var searchText: String {
        get { searchText(for: selectedCategory) }
        set { updateSearchText(newValue, for: selectedCategory) }
    }

    var excerptSort: NoteExcerptGroupSort = .customOrder
    var starredSort: StarredChapterSort = .recentlyChanged {
        didSet {
            guard oldValue != starredSort, isObserving else { return }
            restartStarredObservation()
        }
    }
    var relatedSort: RelatedCategorySort = .createdAscending {
        didSet {
            guard oldValue != relatedSort, isObserving else { return }
            restartRelatedObservation()
        }
    }
    var reviewSort: BookReviewSortRule = .createdDescending {
        didSet {
            guard oldValue != reviewSort, isObserving else { return }
            restartReviewObservation(resetsPagination: true)
        }
    }

    private(set) var noteHomeSnapshot = NoteHomeSnapshot(defaultGroups: [], userTags: [])
    private(set) var starredGroups: [StarredChapterGroup] = []
    private(set) var relatedSnapshot = RelatedCategorySnapshot(items: [], totalContentCount: 0)
    private(set) var reviewSnapshot = BookReviewListSnapshot(items: [], totalCount: 0)
    private(set) var excerptState: NoteHomeSectionState = .loading
    private(set) var starredState: NoteHomeSectionState = .loading
    private(set) var relatedState: NoteHomeSectionState = .loading
    private(set) var reviewState: NoteHomeSectionState = .loading
    private(set) var isWriting = false
    private(set) var isReviewLoadingMore = false
    private(set) var reviewLoadMoreErrorMessage: String?

    private let repository: any NoteRepositoryProtocol
    private let contentRepository: (any ContentRepositoryProtocol)?
    private let bookRepository: (any BookDetailRepositoryProtocol)?
    private var excerptObservationTask: Task<Void, Never>?
    private var starredObservationTask: Task<Void, Never>?
    private var relatedObservationTask: Task<Void, Never>?
    private var reviewObservationTask: Task<Void, Never>?
    private var searchDebounceTasks: [NoteCategory: Task<Void, Never>] = [:]
    private var isObserving = false
    private var reviewRequestedLimit = NoteBookReviewPagingPolicy.pageSize

    /// 注入笔记仓储；scene 恢复方可延迟启动观察，普通页面与 Preview 默认立即观察。
    init(
        repository: any NoteRepositoryProtocol,
        contentRepository: (any ContentRepositoryProtocol)? = nil,
        bookRepository: (any BookDetailRepositoryProtocol)? = nil,
        startsObserving: Bool = true
    ) {
        self.repository = repository
        self.contentRepository = contentRepository
        self.bookRepository = bookRepository
        if startsObserving {
            restartObservations()
        }
    }

    /// 应用 scene 语义快照并暂停旧观察；调用方随后显式重启观察，避免默认条件先发起查询。
    func applySceneSnapshot(_ snapshot: NotesSceneSnapshot) {
        stopObservations()
        selectedCategory = snapshot.selectedCategory
        searchTexts = [
            .excerpts: snapshot.excerptSearchText,
            .starredChapters: snapshot.starredChapterSearchText,
            .related: snapshot.relatedSearchText,
            .reviews: snapshot.reviewSearchText
        ]
        excerptSort = snapshot.excerptSort
        starredSort = snapshot.starredSort
        relatedSort = snapshot.relatedSort
        reviewSort = snapshot.reviewSort
    }

    /// 导出首页完整语义快照；搜索字典始终由 ViewModel 封装，View 不接触其内部结构。
    func sceneSnapshot(selectedSubTab: NoteSubTab) -> NotesSceneSnapshot {
        NotesSceneSnapshot(
            selectedSubTab: selectedSubTab,
            selectedCategory: selectedCategory,
            excerptSearchText: searchTexts[.excerpts] ?? "",
            starredChapterSearchText: searchTexts[.starredChapters] ?? "",
            relatedSearchText: searchTexts[.related] ?? "",
            reviewSearchText: searchTexts[.reviews] ?? "",
            excerptSort: excerptSort,
            starredSort: starredSort,
            relatedSort: relatedSort,
            reviewSort: reviewSort
        )
    }

    /// 以当前已应用的搜索和排序条件并行重启四条 Repository 观察流。
    func restartObservations() {
        stopObservations()
        isObserving = true
        startExcerptObservation()
        startStarredObservation()
        startRelatedObservation()
        startReviewObservation()
    }

    /// 当前书摘分组按搜索词和页内排序得到的稳定展示结果。
    var filteredDefaultGroups: [NoteExcerptGroupItem] {
        noteHomeSnapshot.defaultGroups.filter(matchesExcerptQuery)
    }

    /// 当前用户标签按搜索词和页内排序得到的稳定展示结果。
    var filteredUserTags: [NoteExcerptGroupItem] {
        sortedExcerptGroups(noteHomeSnapshot.userTags.filter(matchesExcerptQuery))
    }

    var hasVisibleExcerptGroups: Bool {
        !filteredDefaultGroups.isEmpty || !filteredUserTags.isEmpty
    }

    var normalizedSearchText: String {
        normalizedSearchText(for: selectedCategory)
    }

    /// 返回指定分类独立保存的搜索词，使常驻子页无需借用当前选中分类的临时 Binding。
    func searchText(for category: NoteCategory) -> String {
        searchTexts[category] ?? ""
    }

    /// 更新指定分类搜索词；仅当规范化查询改变时重启该分类观察，避免输入空白触发无效查询。
    func updateSearchText(_ newValue: String, for category: NoteCategory) {
        let oldValue = searchTexts[category] ?? ""
        guard oldValue != newValue else { return }
        let shouldRestartObservation = normalizedQuery(oldValue) != normalizedQuery(newValue)
        searchTexts[category] = newValue
        guard shouldRestartObservation, isObserving else { return }
        scheduleSearchObservationRestart(for: category)
    }

    /// 返回指定分类去除首尾空白后的有效搜索词，供常驻页面独立判断搜索状态。
    func normalizedSearchText(for category: NoteCategory) -> String {
        normalizedQuery(searchTexts[category] ?? "")
    }

    var hasMoreReviews: Bool {
        reviewSnapshot.items.count < reviewSnapshot.totalCount
    }

    /// 取消指定章节星标；章节和书摘保持不变，观察流会自动移除对应入口。
    func removeChapterStar(chapterID: Int64) async throws {
        try await performWrite {
            try await repository.setChapterStarred(chapterID: chapterID, isStarred: false)
        }
    }

    /// 删除首页相关分类聚合项；默认分类仅清空内容，自定义分类按精确标题跨书软删除。
    func deleteRelatedCategory(scope: RelatedCategoryScope) async throws {
        try await performWrite {
            try await repository.deleteRelatedCategory(scope: scope)
        }
    }

    /// 按 Android 语义软删除首页书评及其附图；生产环境必须注入 ContentRepository。
    func deleteReview(reviewID: Int64) async throws {
        guard let contentRepository else { return }
        try await performWrite {
            try await contentRepository.delete(itemID: .review(reviewID))
        }
    }

    /// 按 Android 评分 SQL 更新单本书，成功后由书评观察流中的 bookScore 变化表达结果。
    func updateBookRating(bookID: Int64, score: Int64) async throws {
        guard let bookRepository else {
            throw NoteHomeWriteError.ratingRepositoryUnavailable
        }
        try await performWrite {
            try await bookRepository.updateBookRating(bookId: bookID, score: score)
        }
    }

    /// 最后一张书评卡出现时扩大稳定观察窗口；前缀快照整体替换可避免并发新增/删除造成重复或漏项。
    func loadMoreReviewsIfNeeded(currentReviewID: Int64) {
        guard hasMoreReviews,
              !isReviewLoadingMore,
              reviewSnapshot.items.last?.id == currentReviewID else { return }
        isReviewLoadingMore = true
        reviewLoadMoreErrorMessage = nil
        reviewRequestedLimit += NoteBookReviewPagingPolicy.pageSize
        restartReviewObservation(resetsPagination: false)
    }

    /// 继续请求上次失败的扩展窗口，保留已显示卡片与当前搜索/排序条件。
    func retryReviewLoadMore() {
        guard reviewLoadMoreErrorMessage != nil, !isReviewLoadingMore else { return }
        isReviewLoadingMore = true
        reviewLoadMoreErrorMessage = nil
        restartReviewObservation(resetsPagination: false)
    }

    /// 按当前分类重建失败的观察流；已有内容保留在页面直到新快照返回。
    func retrySelectedCategory() {
        switch selectedCategory {
        case .excerpts:
            excerptObservationTask?.cancel()
            startExcerptObservation()
        case .starredChapters:
            restartStarredObservation()
        case .related:
            restartRelatedObservation()
        case .reviews:
            restartReviewObservation(resetsPagination: reviewSnapshot.items.isEmpty)
        }
    }

    /// 释放首页持有的观察与防抖任务，避免离开页面后继续回写状态。
    isolated deinit {
        excerptObservationTask?.cancel()
        starredObservationTask?.cancel()
        relatedObservationTask?.cancel()
        reviewObservationTask?.cancel()
        searchDebounceTasks.values.forEach { $0.cancel() }
    }

    // MARK: - Observation

    /// 书摘入口流由 Repository 持续推送；任务取消时静默结束，其他错误进入可重试状态。
    private func startExcerptObservation() {
        if noteHomeSnapshot.defaultGroups.isEmpty && noteHomeSnapshot.userTags.isEmpty {
            excerptState = .loading
        }
        let stream = repository.observeNoteHomeSnapshot()
        excerptObservationTask = Task { [weak self] in
            do {
                for try await snapshot in stream {
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    self.noteHomeSnapshot = snapshot
                    self.excerptState = self.hasVisibleExcerptGroups ? .content : .empty
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.excerptState = .error(error.localizedDescription)
            }
        }
    }

    /// 星标章节流绑定当前搜索和排序请求；新请求会取消旧流，避免晚到快照覆盖新条件。
    private func startStarredObservation() {
        if starredGroups.isEmpty { starredState = .loading }
        let request = StarredChapterRequest(
            query: normalizedSearchText(for: .starredChapters),
            sort: starredSort
        )
        let stream = repository.observeStarredChapterGroups(request: request)
        starredObservationTask = Task { [weak self] in
            do {
                for try await groups in stream {
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    self.starredGroups = groups
                    self.starredState = groups.isEmpty ? .empty : .content
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.starredState = .error(error.localizedDescription)
            }
        }
    }

    /// 相关分类流绑定当前搜索和排序请求；作用域聚合由 Repository 完成，ViewModel 不拼接数据库结果。
    private func startRelatedObservation() {
        if relatedSnapshot.items.isEmpty { relatedState = .loading }
        let request = RelatedCategoryRequest(
            query: normalizedSearchText(for: .related),
            sort: relatedSort
        )
        let stream = repository.observeRelatedCategories(request: request)
        relatedObservationTask = Task { [weak self] in
            do {
                for try await snapshot in stream {
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    self.relatedSnapshot = snapshot
                    self.relatedState = snapshot.items.isEmpty ? .empty : .content
                }
            } catch {
                guard !Task.isCancelled else { return }
                self?.relatedState = .error(error.localizedDescription)
            }
        }
    }

    /// 书评首页观察当前稳定前缀窗口；加载更多扩大 limit 后整体刷新前缀，数据库变化不会造成 offset 重复或漏项。
    private func startReviewObservation() {
        if reviewSnapshot.items.isEmpty { reviewState = .loading }
        let request = BookReviewPageRequest(
            query: normalizedSearchText(for: .reviews),
            sort: reviewSort,
            offset: 0,
            limit: reviewRequestedLimit
        )
        let stream = repository.observeBookReviewList(request: request)
        reviewObservationTask = Task { [weak self] in
            do {
                for try await snapshot in stream {
                    guard !Task.isCancelled else { return }
                    guard let self else { return }
                    self.reviewSnapshot = snapshot
                    self.isReviewLoadingMore = false
                    self.reviewLoadMoreErrorMessage = nil
                    self.reviewState = snapshot.items.isEmpty ? .empty : .content
                }
            } catch {
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.isReviewLoadingMore = false
                if self.reviewSnapshot.items.isEmpty {
                    self.reviewState = .error(error.localizedDescription)
                } else {
                    self.reviewState = .content
                    self.reviewLoadMoreErrorMessage = error.localizedDescription
                }
            }
        }
    }

    /// 搜索输入稳定 200ms 后同步重建三条查询流；书摘入口仅做本地标题过滤，无需访问数据库。
    private func scheduleSearchObservationRestart(for category: NoteCategory) {
        if category == .excerpts {
            excerptState = hasVisibleExcerptGroups ? .content : .empty
        }
        searchDebounceTasks[category]?.cancel()
        searchDebounceTasks[category] = Task { [weak self, category] in
            do {
                try await Task.sleep(for: NoteHomeSearchPolicy.delay)
                try Task.checkCancellation()
                self?.restartObservation(for: category)
            } catch {
                return
            }
        }
    }

    private func restartObservation(for category: NoteCategory) {
        searchDebounceTasks[category] = nil
        switch category {
        case .excerpts:
            excerptState = hasVisibleExcerptGroups ? .content : .empty
        case .starredChapters:
            restartStarredObservation()
        case .related:
            restartRelatedObservation()
        case .reviews:
            restartReviewObservation(resetsPagination: true)
        }
    }

    private func restartStarredObservation() {
        starredObservationTask?.cancel()
        startStarredObservation()
    }

    private func restartRelatedObservation() {
        relatedObservationTask?.cancel()
        startRelatedObservation()
    }

    private func restartReviewObservation(resetsPagination: Bool) {
        reviewObservationTask?.cancel()
        if resetsPagination {
            reviewRequestedLimit = NoteBookReviewPagingPolicy.pageSize
            reviewSnapshot = BookReviewListSnapshot(items: [], totalCount: 0)
            isReviewLoadingMore = false
            reviewLoadMoreErrorMessage = nil
            reviewState = .loading
        }
        startReviewObservation()
    }

    /// 同步取消并释放所有观察与防抖任务；任务闭包通过取消检查停止后续 MainActor 写回。
    private func stopObservations() {
        isObserving = false
        excerptObservationTask?.cancel()
        starredObservationTask?.cancel()
        relatedObservationTask?.cancel()
        reviewObservationTask?.cancel()
        searchDebounceTasks.values.forEach { $0.cancel() }
        excerptObservationTask = nil
        starredObservationTask = nil
        relatedObservationTask = nil
        reviewObservationTask = nil
        searchDebounceTasks.removeAll()
    }

    private func normalizedQuery(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func matchesExcerptQuery(_ item: NoteExcerptGroupItem) -> Bool {
        let query = normalizedSearchText(for: .excerpts)
        return query.isEmpty || item.title.localizedCaseInsensitiveContains(query)
    }

    private func sortedExcerptGroups(_ groups: [NoteExcerptGroupItem]) -> [NoteExcerptGroupItem] {
        switch excerptSort {
        case .customOrder:
            groups.sorted { lhs, rhs in
                if lhs.order != rhs.order { return lhs.order < rhs.order }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        case .countDescending:
            groups.sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count > rhs.count }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        case .countAscending:
            groups.sorted { lhs, rhs in
                if lhs.count != rhs.count { return lhs.count < rhs.count }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        }
    }

    /// 写操作即时进入禁用态，取消和错误继续向页面系统反馈层传播。
    private func performWrite(_ operation: () async throws -> Void) async throws {
        guard !isWriting else { throw NoteHomeWriteError.operationInProgress }
        isWriting = true
        defer { isWriting = false }
        try await operation()
        try Task.checkCancellation()
    }
}
