/**
 * [INPUT]: 依赖 GlobalSearchRepositoryProtocol 执行四类本地检索，依赖 GlobalSearchModels 表达筛选、结果与加载阶段
 * [OUTPUT]: 对外提供 GlobalSearchViewModel，驱动 iOS 全局搜索页的 query 防抖、加载态、错误态、结果筛选与结果版本
 * [POS]: ViewModels/Search 的全局搜索状态编排器，被 GlobalSearchView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Observation

/// 全局搜索状态源；所有可观察 UI 状态固定在 MainActor，搜索任务会在新 query 到达时取消旧请求以避免过期结果回写。
@MainActor
@Observable
final class GlobalSearchViewModel {
    /// 搜索加载阶段，区分初始、输入稳定、读取、成功与失败状态。
    enum LoadState: Equatable {
        case idle
        case preparing(keyword: String)
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

    private enum Timing {
        static let debounceNanoseconds: UInt64 = 450_000_000
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
    private var searchTask: Task<Void, Never>?

    /// 注入全局搜索仓储；ViewModel 不持有数据库或网络客户端，保持数据访问统一经 Repository。
    init(repository: any GlobalSearchRepositoryProtocol) {
        self.repository = repository
        self.recentQueries = repository.fetchRecentQueries()
    }

    var availableScopes: [GlobalSearchScope] {
        guard snapshot.totalCount > 0 else {
            return []
        }
        let categoryScopes = snapshot.nonEmptyCategories.map(GlobalSearchScope.init(category:))
        guard categoryScopes.count > 1 else {
            return categoryScopes
        }
        return [.all] + categoryScopes
    }

    var shouldShowScopeFilter: Bool {
        availableScopes.count > 1
    }

    var availableFieldScopes: [GlobalSearchFieldScope] {
        guard let category = selectedScope.category else {
            return []
        }
        let results = ranked(snapshot.results(for: selectedScope))
        guard shouldOfferFieldScopes(for: results) else {
            return []
        }
        return category.fieldScopes.filter { fieldScope in
            fieldScopeCount(fieldScope, in: results) > 0
        }
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
        let results = ranked(snapshot.results(for: selectedScope))
        guard let fieldScope = currentFieldScope else {
            return results
        }
        return results.filter { Self.result($0, matches: fieldScope) }
    }

    var errorMessage: String? {
        if case .failed(_, let message) = loadState {
            return message
        }
        return nil
    }

    /// 响应搜索框输入变化；会取消尚未完成的旧任务，并对非空关键词启动防抖读取。
    func queryDidChange(_ query: String) {
        scheduleSearch(query: query, debounce: true)
    }

    /// 响应键盘 search 提交；跳过防抖立即读取，并继续使用任务取消防止旧结果覆盖新 query。
    func submit(query: String) {
        scheduleSearch(query: query, debounce: false)
    }

    /// 对当前关键词重试；重试会复用相同取消机制，确保失败后的旧任务不会回写状态。
    func retry(query: String) {
        scheduleSearch(query: query, debounce: false)
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
        fieldScopeCount(fieldScope, in: ranked(snapshot.results(for: selectedScope)))
    }

    /// 切换全局搜索主范围；只过滤当前快照，不触发重新搜索或重置输入框。
    func selectScope(_ scope: GlobalSearchScope) {
        guard availableScopes.contains(scope), selectedScope != scope else { return }
        selectedScope = scope
    }

    /// 返回主范围结果数量，供范围选择控件展示从属 metadata。
    func scopeCount(for scope: GlobalSearchScope) -> Int {
        if let category = scope.category {
            return snapshot.count(for: category)
        }
        return snapshot.totalCount
    }

    /// 页面离场或搜索关闭时取消读取任务，避免释放后仍回写主线程状态。
    func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
    }

    /// 编排一次搜索任务；非空关键词先等待输入稳定，真正读取前再进入 loading，任务取消后不会触发错误态。
    private func scheduleSearch(query: String, debounce: Bool) {
        let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
        searchTask?.cancel()
        searchTask = nil

        guard !keyword.isEmpty else {
            snapshot = .empty
            selectedScope = .all
            selectedFieldScopes.removeAll()
            resultRevision += 1
            loadState = .idle
            return
        }

        snapshot = .empty
        selectedScope = .all
        selectedFieldScopes.removeAll()
        resultRevision += 1
        loadState = debounce ? .preparing(keyword: keyword) : .loading(keyword: keyword)
        let repository = self.repository
        searchTask = Task { [weak self] in
            do {
                if debounce {
                    try await Task.sleep(nanoseconds: Timing.debounceNanoseconds)
                }
                try Task.checkCancellation()
                await MainActor.run {
                    guard let self else { return }
                    self.loadState = .loading(keyword: keyword)
                }
                try Task.checkCancellation()
                let result = try await repository.search(keyword: keyword)
                try Task.checkCancellation()
                await MainActor.run {
                    guard let self else { return }
                    self.apply(snapshot: result, keyword: keyword)
                }
            } catch is CancellationError {
                return
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.snapshot = .empty
                    self.selectedScope = .all
                    self.resultRevision += 1
                    self.loadState = .failed(
                        keyword: keyword,
                        message: Self.displayMessage(for: error)
                    )
                }
            }
        }
    }

    private func apply(snapshot: GlobalSearchSnapshot, keyword: String) {
        self.snapshot = snapshot
        selectedScope = availableScopes.first ?? .all
        pruneFieldScopes()
        resultRevision += 1
        rememberQuery(keyword)
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

    private func ranked(_ results: [GlobalSearchResult]) -> [GlobalSearchResult] {
        results.sorted { lhs, rhs in
            let lhsRank = rank(lhs)
            let rhsRank = rank(rhs)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }
            return lhs.timestamp > rhs.timestamp
        }
    }

    private func rank(_ result: GlobalSearchResult) -> Int {
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

    private func shouldOfferFieldScopes(for results: [GlobalSearchResult]) -> Bool {
        guard !results.isEmpty else { return false }
        if results.count >= 8 {
            return true
        }
        let matchedFieldCount = Set(results.flatMap(\.matchedFields)).count
        return matchedFieldCount > 2
    }

    private func fieldScopeCount(_ fieldScope: GlobalSearchFieldScope, in results: [GlobalSearchResult]) -> Int {
        results.filter { Self.result($0, matches: fieldScope) }.count
    }

    private func pruneFieldScopes() {
        for (category, fieldScope) in Array(selectedFieldScopes) {
            let results = ranked(snapshot.results(for: GlobalSearchScope(category: category)))
            guard fieldScopeCount(fieldScope, in: results) > 0 else {
                selectedFieldScopes[category] = nil
                continue
            }
        }
    }

    private static func result(_ result: GlobalSearchResult, matches fieldScope: GlobalSearchFieldScope) -> Bool {
        guard result.category == fieldScope.category else {
            return false
        }
        return result.matchedFields.contains { fieldScope.matchedFieldNames.contains($0) }
    }
}
