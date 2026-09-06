/**
 * [INPUT]: 依赖 UserDefaults 持久化书摘回顾设置，依赖 NotificationCenter 广播设置变更
 * [OUTPUT]: 对外提供 NoteReviewSettingStore，供 NoteRepository 读取、迁移、保存并观察含独立卡宽容错的回顾设置
 * [POS]: Data 层书摘回顾设置轻量持久化协作者，避免 Repository 查询逻辑直接承载 UserDefaults 细节
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 书摘回顾设置的本地持久化入口，保持 ViewModel 仅通过 Repository 获取设置。
nonisolated struct NoteReviewSettingStore {
    static let shared = NoteReviewSettingStore()

    private let defaults: UserDefaults
    private let key = "note.review.settings.v1"
    private let chapterDefaultMigrationKey = "note.review.settings.chapter-default.v1"
    private static let didChangeNotification = Notification.Name("NoteReviewSettingStore.didChange")

    /// 注入 UserDefaults，默认使用标准容器。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 读取回顾设置；首次升级把章节展示迁移为开启，之后始终尊重用户保存的显隐选择。
    func fetchSettings() -> NoteReviewSettings {
        let decoded: NoteReviewSettings
        if let data = defaults.data(forKey: key),
           let stored = try? JSONDecoder().decode(NoteReviewSettings.self, from: data) {
            decoded = stored
        } else {
            decoded = .defaultValue
        }
        var settings = sanitize(decoded)
        guard !defaults.bool(forKey: chapterDefaultMigrationKey) else { return settings }
        settings.immersiveDisplay.showsChapter = true
        guard persistWithoutNotification(settings) else { return settings }
        defaults.set(true, forKey: chapterDefaultMigrationKey)
        return settings
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
        copy.desktopCardWidth = NoteReviewSettings.validatedDesktopCardWidth(copy.desktopCardWidth)
        if let favoriteTagID = copy.favoriteTagID, favoriteTagID <= 0 {
            copy.favoriteTagID = nil
        }
        return copy
    }

    private func persistWithoutNotification(_ settings: NoteReviewSettings) -> Bool {
        guard let data = try? JSONEncoder().encode(settings) else { return false }
        defaults.set(data, forKey: key)
        return true
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
