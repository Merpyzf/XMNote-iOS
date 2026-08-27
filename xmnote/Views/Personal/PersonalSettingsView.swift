/**
 * [INPUT]: 依赖 PersonalRoute、XMSettingsPage/Section/Group 与页面私有导航行
 * [OUTPUT]: 对外提供 PersonalSettingsView，以 canonical 设置结构承载个人模块设置入口
 * [POS]: Views/Personal 页面壳层，由“我的”顶部设置按钮进入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 个人设置页，集中承载需要持久化的应用偏好入口。
struct PersonalSettingsView: View {
    var body: some View {
        XMSettingsPage {
            XMSettingsSection("阅读") {
                XMSettingsGroup(presentation: .singleItem) {
                    NavigationLink(value: AppRoute.personal(.readingTimerSettings)) {
                        HStack(spacing: Spacing.base) {
                            Image(systemName: "timer")
                                .font(AppTypography.bodyMedium)
                                .foregroundStyle(Color.iconSecondary)
                                .frame(width: XMSettingsPageLayout.iconSlotWidth)
                                .accessibilityHidden(true)

                            Text("阅读计时")
                                .font(SettingsTypography.rowTitle)
                                .foregroundStyle(Color.textPrimary)

                            Spacer(minLength: Spacing.base)

                            Image(systemName: "chevron.forward")
                                .font(AppTypography.caption2Semibold)
                                .foregroundStyle(Color.iconSecondary)
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: XMSettingsPageLayout.regularRowMinHeight)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
    }
}
