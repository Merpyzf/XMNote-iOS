import Foundation

/**
 * [INPUT]: 依赖 BookRemoteSearchService 处理远端搜索站点差异，依赖 UserDefaults 存取最近搜索词
 * [OUTPUT]: 对外提供 BookSearchRepository（BookSearchRepositoryProtocol 的默认实现）
 * [POS]: Data 层书籍搜索仓储实现，统一封装六书源搜索、豆瓣详情补抓与最近搜索持久化
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 书籍搜索仓储实现，负责远端搜索链路和搜索页本地轻量状态持久化。
struct BookSearchRepository: BookSearchRepositoryProtocol {
    private let service: BookRemoteSearchService
    private let userDefaults: UserDefaults

    private enum Keys {
        static let recentQueries = "book_search_recent_queries"
    }

    init(
        service: BookRemoteSearchService = .init(),
        userDefaults: UserDefaults = .standard
    ) {
        self.service = service
        self.userDefaults = userDefaults
    }

    /// 搜索远端书籍列表，统一交给服务层屏蔽站点差异。
    func search(keyword: String, source: BookSearchSource) async throws -> [BookSearchResult] {
        try await service.search(keyword: keyword, source: source)
    }

    /// 将轻量搜索条目补齐为录入页种子，豆瓣场景会在这里抓详情页。
    func prepareSeed(for result: BookSearchResult) async throws -> BookEditorSeed {
        try await service.prepareSeed(for: result)
    }

    /// 读取最近搜索词，默认按最近使用顺序返回。
    func fetchRecentQueries() -> [String] {
        userDefaults.stringArray(forKey: Keys.recentQueries) ?? []
    }

    /// 保存最近搜索词，最多保留 8 条并去重。
    func saveRecentQuery(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var queries = fetchRecentQueries().filter { $0 != trimmed }
        queries.insert(trimmed, at: 0)
        userDefaults.set(Array(queries.prefix(8)), forKey: Keys.recentQueries)
    }

    /// 删除单条最近搜索词。
    func removeRecentQuery(_ query: String) {
        let updated = fetchRecentQueries().filter { $0 != query }
        userDefaults.set(updated, forKey: Keys.recentQueries)
    }
}
