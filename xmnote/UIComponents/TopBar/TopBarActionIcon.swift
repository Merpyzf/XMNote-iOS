/**
 * [INPUT]: 依赖 SwiftUI 图标与字体渲染能力
 * [OUTPUT]: 对外提供 TopBarActionIcon 顶部栏统一图标组件，以及 TopBarBackButton 导航返回按钮
 * [POS]: UIComponents/TopBar 的原子级按钮图标与导航返回组件，被顶部操作区域与返回入口复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 顶部栏操作图标原子组件，统一尺寸、字重与点击热区。
struct TopBarActionIcon: View {
    let systemName: String
    var iconSize: CGFloat = 15
    var containerSize: CGFloat = 44
    var weight: Font.Weight = .medium
    var foregroundColor: Color = .secondary

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: iconSize, weight: weight))
            .foregroundStyle(foregroundColor)
            .frame(width: containerSize, height: containerSize)
            .contentShape(Circle())
    }
}

/// 顶部栏导航返回按钮，统一返回图标尺寸、热区与基础交互语义。
struct TopBarBackButton: View {
    let action: () -> Void
    var foregroundColor: Color = .primary
    var isEnabled: Bool = true
    var opacity: Double = 1

    var body: some View {
        Button(action: action) {
            TopBarActionIcon(
                systemName: "chevron.left",
                iconSize: 16,
                weight: .semibold,
                foregroundColor: foregroundColor
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(opacity)
        .accessibilityLabel("返回")
    }
}
