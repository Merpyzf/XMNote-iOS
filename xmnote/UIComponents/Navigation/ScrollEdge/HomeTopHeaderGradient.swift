/**
 * [INPUT]: 依赖 SwiftUI 与 DesignSystem 的自适应品牌色和页面表层色
 * [OUTPUT]: 对外提供 HomeTopHeaderGradient 首页顶部氛围渐变
 * [POS]: UIComponents/Navigation/ScrollEdge 的首页导航背景装饰，由页面壳层选择组合
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 首页顶部氛围渐变背景，用于衬托顶部切换栏与首屏内容层次。
struct HomeTopHeaderGradient: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color.xmAdaptive(light: Color.appTint.opacity(0.2), dark: Color.xmHex(0x1E2A25)),
                Color.surfacePage.opacity(0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 150)
        .ignoresSafeArea(edges: .top)
    }
}
