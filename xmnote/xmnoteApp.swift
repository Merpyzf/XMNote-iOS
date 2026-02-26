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

    init() {
        do {
            _databaseManager = State(initialValue: try DatabaseManager())
        } catch {
            fatalError("数据库初始化失败: \(error)")
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
                .environment(databaseManager)
        }
    }
}
