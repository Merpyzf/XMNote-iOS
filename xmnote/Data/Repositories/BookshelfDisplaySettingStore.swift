/**
 * [INPUT]: 依赖 UserDefaults 持久化书架显示设置，依赖 NotificationCenter 广播维度级设置变更
 * [OUTPUT]: 对外提供 BookshelfDisplaySettingStore，供 BookRepository 读取、保存并观察书架显示设置
 * [POS]: Data 层书架显示设置轻量持久化协作者，避免 BookRepository 直接承载 UserDefaults 细节
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 书架显示设置的本地轻量持久化入口，保持 ViewModel 只经 Repository 获取本地数据。
nonisolated struct BookshelfDisplaySettingStore {
    static let shared = BookshelfDisplaySettingStore()

    private let defaults: UserDefaults
    private let mainKey = "bookshelf.display.settings.v1"
    private let bookListKey = "bookshelf.book-list.display.settings.v1"
    private static let didChangeNotification = Notification.Name("BookshelfDisplaySettingStore.didChange")
    private static let scopeUserInfoKey = "scope"
    private static let dimensionUserInfoKey = "dimension"

    /// 注入 UserDefaults，默认使用标准容器。
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 读取全部维度设置；缺失或解码失败时回退到各作用域默认值。
    func fetchSettings(scope: BookshelfDisplaySettingScope) -> [BookshelfDimension: BookshelfDisplaySetting] {
        let fallback = Self.defaultSettings(scope: scope)
        guard let data = defaults.data(forKey: key(for: scope)),
              let decoded = try? JSONDecoder().decode([BookshelfDimension: BookshelfDisplaySetting].self, from: data) else {
            return fallback
        }
        return fallback.merging(decoded) { _, stored in stored }
    }

    /// 保存指定维度设置，并广播该作用域与维度的变更事件。
    func save(_ setting: BookshelfDisplaySetting, for dimension: BookshelfDimension, scope: BookshelfDisplaySettingScope) {
        var settings = fetchSettings(scope: scope)
        settings[dimension] = setting
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key(for: scope))
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: nil,
            userInfo: [
                Self.scopeUserInfoKey: scope.rawValue,
                Self.dimensionUserInfoKey: dimension.rawValue
            ]
        )
    }

    /// 观察指定维度设置变更；通知过滤在轻量 Task 中执行，AsyncStream 终止时取消该任务。
    func observeChanges(scope: BookshelfDisplaySettingScope, dimension: BookshelfDimension) -> AsyncStream<Void> {
        AsyncStream { continuation in
            let task = Task {
                for await notification in NotificationCenter.default.notifications(named: Self.didChangeNotification) {
                    guard let rawScope = notification.userInfo?[Self.scopeUserInfoKey] as? String,
                          let rawDimension = notification.userInfo?[Self.dimensionUserInfoKey] as? String,
                          BookshelfDisplaySettingScope(rawValue: rawScope) == scope,
                          BookshelfDimension(rawValue: rawDimension) == dimension else {
                        continue
                    }
                    continuation.yield(())
                }
            }
            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private func key(for scope: BookshelfDisplaySettingScope) -> String {
        switch scope {
        case .main:
            return mainKey
        case .bookList:
            return bookListKey
        }
    }

    private static func defaultSettings(scope: BookshelfDisplaySettingScope) -> [BookshelfDimension: BookshelfDisplaySetting] {
        Dictionary(uniqueKeysWithValues: BookshelfDimension.allCases.map {
            switch scope {
            case .main:
                return ($0, BookshelfDisplaySetting.defaultValue(for: $0))
            case .bookList:
                return ($0, BookshelfDisplaySetting.defaultBookListValue(for: $0))
            }
        })
    }
}
