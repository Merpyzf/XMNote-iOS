/**
 * [INPUT]: 依赖 UserDefaults 持久化书摘回顾设置，依赖 NotificationCenter 广播设置变更
 * [OUTPUT]: 对外提供 NoteReviewSettingStore，供 NoteRepository 读取、保存并观察书摘回顾设置
 * [POS]: Data 层书摘回顾设置轻量持久化协作者，避免 Repository 查询逻辑直接承载 UserDefaults 细节
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 书摘回顾设置的本地持久化入口，保持 ViewModel 仅通过 Repository 获取设置。
nonisolated struct NoteReviewSettingStore {
    static let shared = NoteReviewSettingStore()

    private let defaults: UserDefaults
    private let key = "note.review.settings.v1"
    private static let didChangeNotification = Notification.Name("NoteReviewSettingStore.didChange")

    /// 注入 UserDefaults，默认使用标准容器。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 读取回顾设置；缺失或解码失败时回退到默认值。
    func fetchSettings() -> NoteReviewSettings {
        guard let data = defaults.data(forKey: key),
              let decoded = try? JSONDecoder().decode(NoteReviewSettings.self, from: data) else {
            return .defaultValue
        }
        return sanitize(decoded)
    }

    /// 保存回顾设置，并广播设置变更事件。
    func save(_ settings: NoteReviewSettings) {
        let sanitized = sanitize(settings)
        guard let data = try? JSONEncoder().encode(sanitized) else { return }
        defaults.set(data, forKey: key)
        NotificationCenter.default.post(name: Self.didChangeNotification, object: nil)
    }

    /// 观察回顾设置变更；调用方取消迭代后底层观察任务会随流终止。
    func observeChanges() -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                for await _ in NotificationCenter.default.notifications(named: Self.didChangeNotification) {
                    continuation.yield(())
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func sanitize(_ settings: NoteReviewSettings) -> NoteReviewSettings {
        var copy = settings
        copy.selectedBookIDs = Self.uniquePositiveIDs(copy.selectedBookIDs)
        copy.selectedTagIDs = Self.uniquePositiveIDs(copy.selectedTagIDs)
        if let favoriteTagID = copy.favoriteTagID, favoriteTagID <= 0 {
            copy.favoriteTagID = nil
        }
        return copy
    }

    private static func uniquePositiveIDs(_ ids: [Int64]) -> [Int64] {
        var seen = Set<Int64>()
        var result: [Int64] = []
        result.reserveCapacity(ids.count)
        for id in ids where id > 0 && !seen.contains(id) {
            seen.insert(id)
            result.append(id)
        }
        return result
    }
}
