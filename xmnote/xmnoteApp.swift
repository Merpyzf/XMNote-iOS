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
    @State private var databaseManager: DatabaseManager
    @State private var repositories: RepositoryContainer

    init() {
        do {
            let manager = try DatabaseManager()
            _databaseManager = State(initialValue: manager)
            _repositories = State(initialValue: RepositoryContainer(databaseManager: manager))
        } catch {
            fatalError("数据库初始化失败: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(databaseManager)
                .environment(repositories)
        }
    }
}
