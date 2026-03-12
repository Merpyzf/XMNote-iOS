/**
 * [INPUT]: 依赖 SwiftUI 图标与字体渲染能力
 * [OUTPUT]: 对外提供 TopBarActionIcon 顶部栏统一图标组件
 * [POS]: UIComponents/TopBar 的原子级按钮图标组件，被个人页与其它顶部操作区域复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 顶部栏操作图标原子组件，统一尺寸、字重与点击热区。
struct TopBarActionIcon: View {
    let systemName: String
    var iconSize: CGFloat = 15
    var weight: Font.Weight = .medium
    var foregroundColor: Color = .secondary

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: iconSize, weight: weight))
            .foregroundStyle(foregroundColor)
            .frame(width: 36, height: 36)
            .contentShape(Circle())
    }
}

/// 顶部栏液态玻璃返回按钮，统一导航返回的图标尺寸、热区与玻璃按压反馈。
struct TopBarGlassBackButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            TopBarActionIcon(
                systemName: "chevron.left",
                iconSize: 16,
                weight: .semibold,
                foregroundColor: .primary
            )
        }
        .topBarGlassButtonStyle(true)
        .accessibilityLabel("返回")
    }
}
