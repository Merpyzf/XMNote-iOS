/**
 * [INPUT]: 依赖 SwiftUI 与 DesignSystem 的自适应品牌色和页面表层色
 * [OUTPUT]: 对外提供 HomeTopHeaderGradient 浅色首页顶部氛围渐变，统一中性深色纸面与文字角色
 * [POS]: UIComponents/Navigation/ScrollEdge 的首页导航背景装饰，由页面壳层选择组合
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 浅色首页顶部氛围渐变背景，用于衬托顶部切换栏与首屏内容层次。
struct HomeTopHeaderGradient: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LinearGradient(
            colors: [
                colorScheme == .dark ? Color.clear : Color.appTint.opacity(0.2),
                Color.surfacePage.opacity(0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 150)
        .ignoresSafeArea(edges: .top)
    }
}
