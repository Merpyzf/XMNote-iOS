import Foundation

/**
 * [INPUT]: 依赖 BookRemoteSearchService 处理远端搜索站点差异，依赖 UserDefaults 存取最近搜索词与搜索设置
 * [OUTPUT]: 对外提供 BookSearchRepository（BookSearchRepositoryProtocol 的默认实现）
 * [POS]: Data 层书籍搜索仓储实现，统一封装在线来源搜索、豆瓣详情补抓、最近搜索与搜索设置持久化
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 书籍搜索仓储实现，负责远端搜索链路、最近搜索与添加书籍偏好持久化。
struct BookSearchRepository: BookSearchRepositoryProtocol {
    private let service: BookRemoteSearchService
    private let userDefaults: UserDefaults

    private enum Keys {
        static let recentQueries = "book_search_recent_queries"
        static let defaultSource = "book_search_default_source"
        static let quickSourceSwitch = "book_search_quick_source_switch"
        static let autoBackHome = "book_search_auto_back_home"
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

    /// 读取搜索设置，缺省值保持 Android 首次进入设置页的关闭态。
    func fetchSearchSettings() -> BookSearchSettings {
        let rawSource = userDefaults.object(forKey: Keys.defaultSource) as? Int
        let source = rawSource.flatMap(BookSearchSource.init(rawValue:)) ?? BookSearchSettings.default.defaultSource
        return BookSearchSettings(
            defaultSource: source,
            isQuickSourceSwitchEnabled: userDefaults.bool(forKey: Keys.quickSourceSwitch),
            shouldReturnToBookshelfAfterSave: userDefaults.bool(forKey: Keys.autoBackHome)
        )
    }

    /// 持久化搜索设置，供搜索页与设置页共享当前来源和流程偏好。
    func saveSearchSettings(_ settings: BookSearchSettings) {
        userDefaults.set(settings.defaultSource.rawValue, forKey: Keys.defaultSource)
        userDefaults.set(settings.isQuickSourceSwitchEnabled, forKey: Keys.quickSourceSwitch)
        userDefaults.set(settings.shouldReturnToBookshelfAfterSave, forKey: Keys.autoBackHome)
    }
}
