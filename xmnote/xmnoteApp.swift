//
//  xmnoteApp.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/9.
//

import SwiftUI

@main
struct xmnoteApp: App {
    @State private var appState = AppState()

    /// 数据库实例，App 生命周期内保持单例
    let database: AppDatabase

    init() {
        do {
            database = try AppDatabase()
        } catch {
            fatalError("数据库初始化失败: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(\.appDatabase, database)
        }
    }
}
