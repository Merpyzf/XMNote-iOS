/**
 * [INPUT]: 依赖 PersonalRoute 导航到阅读计时设置
 * [OUTPUT]: 对外提供 PersonalSettingsView，承载个人模块设置入口
 * [POS]: Views/Personal 页面壳层，由“我的”顶部设置按钮进入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 个人设置页，集中承载需要持久化的应用偏好入口。
struct PersonalSettingsView: View {
    var body: some View {
        Form {
            Section("阅读") {
                NavigationLink(value: PersonalRoute.readingTimerSettings) {
                    Label("阅读计时", systemImage: "timer")
                        .font(AppTypography.body)
                }
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}
