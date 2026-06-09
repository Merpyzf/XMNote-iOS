/**
 * [INPUT]: 依赖 Foundation/UserDefaults 保存不同搜索场景的最近关键词
 * [OUTPUT]: 对外提供 SearchHistoryStore，统一最近搜索词的读取、写入、删除与清空规则
 * [POS]: Data/Repositories 的轻量历史存储工具，被书籍搜索与全局搜索仓储复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 最近搜索词存储工具，统一 trim、去重、置顶与容量裁切，避免各仓储重复维护 UserDefaults 规则。
struct SearchHistoryStore {
    private let key: String
    private let limit: Int
    private let userDefaults: UserDefaults

    /// 注入 UserDefaults key 与容量上限，支持不同搜索场景隔离持久化命名空间。
    init(
        key: String,
        limit: Int = 8,
        userDefaults: UserDefaults = .standard
    ) {
        self.key = key
        self.limit = max(limit, 1)
        self.userDefaults = userDefaults
    }

    /// 读取当前场景的最近搜索词，返回顺序保持最近使用优先。
    func fetch() -> [String] {
        userDefaults.stringArray(forKey: key) ?? []
    }

    /// 保存确认过的搜索词，按大小写与音标不敏感规则去重后置顶。
    func save(_ query: String) {
        let trimmed = Self.trimmed(query)
        guard !trimmed.isEmpty else { return }

        var queries = fetch().filter { !Self.matches($0, trimmed) }
        queries.insert(trimmed, at: 0)
        userDefaults.set(Array(queries.prefix(limit)), forKey: key)
    }

    /// 删除指定搜索词，使用与保存一致的宽松匹配规则，避免大小写差异导致删除失败。
    func remove(_ query: String) {
        let trimmed = Self.trimmed(query)
        guard !trimmed.isEmpty else { return }
        let updated = fetch().filter { !Self.matches($0, trimmed) }
        userDefaults.set(updated, forKey: key)
    }

    /// 清空当前搜索场景的全部历史词。
    func clear() {
        userDefaults.set([], forKey: key)
    }

    private static func trimmed(_ query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matches(_ lhs: String, _ rhs: String) -> Bool {
        trimmed(lhs).compare(
            trimmed(rhs),
            options: [.caseInsensitive, .diacriticInsensitive]
        ) == .orderedSame
    }
}
