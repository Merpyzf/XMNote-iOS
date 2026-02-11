import SwiftUI
import GRDB

// MARK: - SwiftUI Environment Key
// 通过 Environment 将 AppDatabase 注入到整个视图树

private struct AppDatabaseKey: EnvironmentKey {
    static let defaultValue: AppDatabase? = nil
}

extension EnvironmentValues {
    var appDatabase: AppDatabase? {
        get { self[AppDatabaseKey.self] }
        set { self[AppDatabaseKey.self] = newValue }
    }
}
