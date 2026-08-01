/**
 * [INPUT]: 依赖 GlobalSearchRepositoryProtocol 执行四类本地检索，依赖 GlobalSearchModels 表达筛选、结果与加载阶段
 * [OUTPUT]: 对外提供 GlobalSearchViewModel，驱动 iOS 全局搜索页的提交式搜索、加载态、错误态、结果筛选、结果版本与确认式历史记录
 * [POS]: ViewModels/Search 的全局搜索状态编排器，被 GlobalSearchView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Observation

/// 全局搜索状态源；所有可观察 UI 状态固定在 MainActor，搜索任务会在新 query 到达时取消旧请求以避免过期结果回写。
@MainActor
@Observable
final class GlobalSearchViewModel {
    /// 搜索加载阶段，区分初始、读取、成功与失败状态。
    enum LoadState: Equatable {
        case idle
        case loading(keyword: String)
        case loaded(keyword: String)
        case failed(keyword: String, message: String)

        var isLoading: Bool {
            if case .loading = self {
                return true
            }
            return false
        }
    }

    private enum ResultLimit {
        static let recentQueryCount = 8
    }

    var snapshot: GlobalSearchSnapshot = .empty
    var selectedScope: GlobalSearchScope = .all
    var selectedFieldScopes: [GlobalSearchCategory: GlobalSearchFieldScope] = [:]
    var loadState: LoadState = .idle
    var recentQueries: [String] = []
    /// 搜索结果快照版本；每次清空或应用新快照时递增，供页面清理滚动等瞬时 UI 状态。
    var resultRevision = 0

    private let repository: any GlobalSearchRepositoryProtocol
    @ObservationIgnored
    private var derivedState: GlobalSearchDerivedState = .empty
    nonisolated(unsafe) private var searchTask: Task<Void, Never>?

    /// 注入全局搜索仓储；ViewModel 不持有数据库或网络客户端，保持数据访问统一经 Repository。
    init(repository: any GlobalSearchRepositoryProtocol) {
        self.repository = repository
        self.recentQueries = repository.fetchRecentQueries()
    }

    deinit {
        searchTask?.cancel()
    }

    var availableScopes: [GlobalSearchScope] {
        derivedState.availableScopes
    }

    var shouldShowScopeFilter: Bool {
        availableScopes.count > 1
    }

    var availableFieldScopes: [GlobalSearchFieldScope] {
        guard let category = selectedScope.category else {
            return []
        }
        return derivedState.availableFieldScopes(for: category)
    }

    var shouldShowFieldScopeFilter: Bool {
        availableFieldScopes.count > 1
    }

    var currentFieldScope: GlobalSearchFieldScope? {
        guard let category = selectedScope.category,
              let fieldScope = selectedFieldScopes[category],
              availableFieldScopes.contains(fieldScope) else {
            return nil
        }
        return fieldScope
    }

    var visibleResults: [GlobalSearchResult] {
        derivedState.results(for: selectedScope, fieldScope: currentFieldScope)
    }

    var errorMessage: String? {
        if case .failed(_, let message) = loadState {
            return message
        }
        return nil
    }

    /// 响应搜索框草稿变化；仅在草稿偏离当前提交关键词时取消旧任务并回到根态，不触发本地检索。
    func draftDidChange(_ query: String) {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            resetToIdle()
            return
        }
        guard activeKeyword != keyword else { return }
        resetToIdle()
    }

    /// 响应键盘 search 提交；提交本身代表明确搜索意图，因此先记录历史，再立即读取。
    func submit(query: String) {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            resetToIdle()
            return
        }
        rememberQuery(keyword)
        startSearch(keyword: keyword, remembersOnSuccess: false)
    }

    /// 对当前关键词重试；重试会复用相同取消机制，确保失败后的旧任务不会回写状态。
    func retry(query: String) {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !keyword.isEmpty else {
            resetToIdle()
            return
        }
        startSearch(keyword: keyword, remembersOnSuccess: true)
    }

    /// 记录用户通过打开结果等方式确认过的关键词，避免输入过程词污染历史。
    func recordConfirmedQuery(_ query: String) {
        rememberQuery(query)
    }

    /// 删除一条最近搜索词，并刷新根页历史展示。
    func removeRecentQuery(_ query: String) {
        repository.removeRecentQuery(query)
        recentQueries = Array(repository.fetchRecentQueries().prefix(ResultLimit.recentQueryCount))
    }

    /// 清空全部最近搜索词，并刷新根页空态。
    func clearRecentQueries() {
        repository.clearRecentQueries()
        recentQueries = []
    }

    /// 切换分类内字段范围；nil 表示回到当前分类的完整结果。
    func selectFieldScope(_ fieldScope: GlobalSearchFieldScope?) {
        guard let category = selectedScope.category else { return }
        if let fieldScope, fieldScope.category == category {
            selectedFieldScopes[category] = fieldScope
        } else {
            selectedFieldScopes[category] = nil
        }
    }

    /// 返回某个字段范围在当前分类里的可见数量，数字只作为轻量辅助信息。
    func fieldScopeCount(_ fieldScope: GlobalSearchFieldScope) -> Int {
        derivedState.fieldScopeCount(fieldScope)
    }

    /// 切换全局搜索主范围；只过滤当前快照，不触发重新搜索或重置输入框。
    func selectScope(_ scope: GlobalSearchScope) {
        guard availableScopes.contains(scope), selectedScope != scope else { return }
        selectedScope = scope
    }

    /// 返回主范围结果数量，供范围选择控件展示从属 metadata。
    func scopeCount(for scope: GlobalSearchScope) -> Int {
        derivedState.scopeCount(for: scope)
    }

    private var activeKeyword: String? {
        switch loadState {
        case .idle:
            return nil
        case .loading(let keyword), .loaded(let keyword), .failed(let keyword, _):
            return keyword
        }
    }

    /// 编排一次提交式搜索任务；任务取消后不会触发错误态，避免过期结果回写当前页面。
    private func startSearch(keyword: String, remembersOnSuccess: Bool) {
        searchTask?.cancel()
        searchTask = nil

        snapshot = .empty
        derivedState = .empty
        selectedScope = .all
        selectedFieldScopes.removeAll()
        resultRevision += 1
        loadState = .loading(keyword: keyword)
        let repository = self.repository
        searchTask = Task { [weak self] in
            do {
                try Task.checkCancellation()
                let result = try await repository.search(keyword: keyword)
                let derivedState = try await Self.makeDerivedState(snapshot: result)
                try Task.checkCancellation()
                await MainActor.run {
                    guard let self else { return }
                    self.apply(
                        snapshot: result,
                        derivedState: derivedState,
                        keyword: keyword,
                        remembersOnSuccess: remembersOnSuccess
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.snapshot = .empty
                    self.derivedState = .empty
                    self.selectedScope = .all
                    self.selectedFieldScopes.removeAll()
                    self.resultRevision += 1
                    self.loadState = .failed(
                        keyword: keyword,
                        message: Self.displayMessage(for: error)
                    )
                }
            }
        }
    }

    private func resetToIdle() {
        searchTask?.cancel()
        searchTask = nil

        guard snapshot != .empty ||
                selectedScope != .all ||
                !selectedFieldScopes.isEmpty ||
                loadState != .idle else {
            return
        }
        snapshot = .empty
        derivedState = .empty
        selectedScope = .all
        selectedFieldScopes.removeAll()
        resultRevision += 1
        loadState = .idle
    }

    private func apply(
        snapshot: GlobalSearchSnapshot,
        derivedState: GlobalSearchDerivedState,
        keyword: String,
        remembersOnSuccess: Bool
    ) {
        self.snapshot = snapshot
        self.derivedState = derivedState
        selectedScope = availableScopes.first ?? .all
        pruneFieldScopes()
        resultRevision += 1
        if remembersOnSuccess {
            rememberQuery(keyword)
        }
        loadState = .loaded(keyword: keyword)
    }

    private static func displayMessage(for error: Error) -> String {
        let description = error.localizedDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        return description.isEmpty ? "搜索失败，请稍后重试" : description
    }

    private func rememberQuery(_ keyword: String) {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        repository.saveRecentQuery(trimmed)
        recentQueries = Array(repository.fetchRecentQueries().prefix(ResultLimit.recentQueryCount))
    }

    /// 在后台任务中构建结果派生缓存，避免大量排序与字段统计占用 MainActor 的输入动画窗口。
    /// - Note: 输入仅为已完成读取的 `GlobalSearchSnapshot`；父任务取消时会同步取消 detached 派生任务，防止旧关键词继续消耗 CPU。
    private nonisolated static func makeDerivedState(
        snapshot: GlobalSearchSnapshot
    ) async throws -> GlobalSearchDerivedState {
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let derivedState = GlobalSearchDerivedState(snapshot: snapshot)
            try Task.checkCancellation()
            return derivedState
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    private func pruneFieldScopes() {
        for (category, fieldScope) in Array(selectedFieldScopes) {
            guard derivedState.fieldScopeCount(fieldScope, in: category) > 0 else {
                selectedFieldScopes[category] = nil
                continue
            }
        }
    }
}

/// 全局搜索结果派生缓存，在结果落地前预先计算排序、范围数量与字段筛选，避免 SwiftUI 渲染阶段重复做主线程重活。
nonisolated private struct GlobalSearchDerivedState: Sendable {
    static let empty = GlobalSearchDerivedState(snapshot: .empty)

    let availableScopes: [GlobalSearchScope]

    private let scopeCounts: [GlobalSearchScope: Int]
    private let rankedResultsByScope: [GlobalSearchScope: [GlobalSearchResult]]
    private let availableFieldScopesByCategory: [GlobalSearchCategory: [GlobalSearchFieldScope]]
    private let fieldCountsByCategory: [GlobalSearchCategory: [GlobalSearchFieldScope: Int]]
    private let fieldResultsByCategory: [GlobalSearchCategory: [GlobalSearchFieldScope: [GlobalSearchResult]]]

    init(snapshot: GlobalSearchSnapshot) {
        self.availableScopes = Self.makeAvailableScopes(snapshot: snapshot)

        var scopeCounts: [GlobalSearchScope: Int] = [.all: snapshot.totalCount]
        var rankedResultsByScope: [GlobalSearchScope: [GlobalSearchResult]] = [
            .all: Self.ranked(snapshot.results(for: .all))
        ]
        var availableFieldScopesByCategory: [GlobalSearchCategory: [GlobalSearchFieldScope]] = [:]
        var fieldCountsByCategory: [GlobalSearchCategory: [GlobalSearchFieldScope: Int]] = [:]
        var fieldResultsByCategory: [GlobalSearchCategory: [GlobalSearchFieldScope: [GlobalSearchResult]]] = [:]

        for category in GlobalSearchCategory.allCases {
            let scope = GlobalSearchScope(category: category)
            let rankedResults = Self.ranked(snapshot.results(for: scope))
            scopeCounts[scope] = snapshot.count(for: category)
            rankedResultsByScope[scope] = rankedResults

            var fieldCounts: [GlobalSearchFieldScope: Int] = [:]
            var fieldResults: [GlobalSearchFieldScope: [GlobalSearchResult]] = [:]
            for fieldScope in category.fieldScopes {
                let results = rankedResults.filter { Self.result($0, matches: fieldScope) }
                fieldCounts[fieldScope] = results.count
                fieldResults[fieldScope] = results
            }

            fieldCountsByCategory[category] = fieldCounts
            fieldResultsByCategory[category] = fieldResults
            availableFieldScopesByCategory[category] = Self.shouldOfferFieldScopes(for: rankedResults)
                ? category.fieldScopes.filter { (fieldCounts[$0] ?? 0) > 0 }
                : []
        }

        self.scopeCounts = scopeCounts
        self.rankedResultsByScope = rankedResultsByScope
        self.availableFieldScopesByCategory = availableFieldScopesByCategory
        self.fieldCountsByCategory = fieldCountsByCategory
        self.fieldResultsByCategory = fieldResultsByCategory
    }

    func availableFieldScopes(for category: GlobalSearchCategory) -> [GlobalSearchFieldScope] {
        availableFieldScopesByCategory[category] ?? []
    }

    func results(
        for scope: GlobalSearchScope,
        fieldScope: GlobalSearchFieldScope?
    ) -> [GlobalSearchResult] {
        guard let fieldScope, let category = scope.category else {
            return rankedResultsByScope[scope] ?? []
        }
        return fieldResultsByCategory[category]?[fieldScope] ?? []
    }

    func scopeCount(for scope: GlobalSearchScope) -> Int {
        scopeCounts[scope] ?? 0
    }

    func fieldScopeCount(_ fieldScope: GlobalSearchFieldScope) -> Int {
        fieldScopeCount(fieldScope, in: fieldScope.category)
    }

    func fieldScopeCount(
        _ fieldScope: GlobalSearchFieldScope,
        in category: GlobalSearchCategory
    ) -> Int {
        fieldCountsByCategory[category]?[fieldScope] ?? 0
    }

    private static func makeAvailableScopes(snapshot: GlobalSearchSnapshot) -> [GlobalSearchScope] {
        guard snapshot.totalCount > 0 else {
            return []
        }
        let categoryScopes = snapshot.nonEmptyCategories.map(GlobalSearchScope.init(category:))
        guard categoryScopes.count > 1 else {
            return categoryScopes
        }
        return [.all] + categoryScopes
    }

    private static func ranked(_ results: [GlobalSearchResult]) -> [GlobalSearchResult] {
        results.sorted { lhs, rhs in
            let lhsRank = rank(lhs)
            let rhsRank = rank(rhs)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.timestamp > rhs.timestamp
        }
    }

    private static func rank(_ result: GlobalSearchResult) -> Int {
        let fields = result.matchedFields
        switch result.category {
        case .book:
            if fields.contains("书名") {
                return 0
            }
            if fields.contains(where: { $0 == "作者" || $0 == "译者" || $0 == "出版社" || $0 == "ISBN" }) {
                return 1
            }
            return fields.contains("标签") ? 2 : 3
        case .note:
            if fields.contains("正文") {
                return 0
            }
            if fields.contains("想法") {
                return 1
            }
            return fields.contains(where: { $0 == "书名" || $0 == "标签" }) ? 2 : 3
        case .relevant:
            if fields.contains(where: { $0 == "标题" || $0 == "书名" }) {
                return 0
            }
            if fields.contains("内容") {
                return 1
            }
            return fields.contains("分类") ? 2 : 3
        case .review:
            if fields.contains("标题") {
                return 0
            }
            if fields.contains("正文") {
                return 1
            }
            return fields.contains("书名") ? 2 : 3
        }
    }

    private static func shouldOfferFieldScopes(for results: [GlobalSearchResult]) -> Bool {
        guard !results.isEmpty else { return false }
        if results.count >= 8 {
            return true
        }
        let matchedFieldCount = Set(results.flatMap(\.matchedFields)).count
        return matchedFieldCount > 2
    }

    private static func result(_ result: GlobalSearchResult, matches fieldScope: GlobalSearchFieldScope) -> Bool {
        guard result.category == fieldScope.category else {
            return false
        }
        return result.matchedFields.contains { fieldScope.matchedFieldNames.contains($0) }
    }
}
