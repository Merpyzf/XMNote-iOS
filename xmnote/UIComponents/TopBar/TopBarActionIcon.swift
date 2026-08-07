/**
 * [INPUT]: 依赖 SwiftUI 图标与字体渲染能力
 * [OUTPUT]: 对外提供 TopBarActionIcon 顶部栏统一图标组件、TopBarActionHitShape 热区形态，以及采用系统自适应标签的 TopBarBackButton
 * [POS]: UIComponents/TopBar 的原子级按钮图标与特殊场景返回组件，被自定义顶部操作区域与需拦截退出的返回入口复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 顶部工具图标的命中区域形态，区分独立圆形按钮与胶囊内分段按钮。
enum TopBarActionHitShape {
    case circle
    case rectangle
}

/// 顶部栏操作图标原子组件，统一尺寸、字重与点击热区。
struct TopBarActionIcon: View {
    let systemName: String
    var iconSize: CGFloat = 12
    var containerSize: CGFloat = 44
    var weight: Font.Weight = .medium
    var foregroundColor: Color = Color.textPrimary.opacity(0.80)
    var hitShape: TopBarActionHitShape = .circle

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: iconSize, weight: weight))
            .foregroundStyle(foregroundColor)
            .frame(width: containerSize, height: containerSize)
            .modifier(TopBarActionHitShapeModifier(hitShape: hitShape))
    }
}

private struct TopBarActionHitShapeModifier: ViewModifier {
    let hitShape: TopBarActionHitShape

    func body(content: Content) -> some View {
        switch hitShape {
        case .circle:
            content.contentShape(Circle())
        case .rectangle:
            content.contentShape(Rectangle())
        }
    }
}

/// 特殊场景导航返回按钮，保留业务拦截能力并交由系统工具栏决定视觉规格。
struct TopBarBackButton: View {
    let action: () -> Void
    var foregroundColor: Color? = nil
    var isEnabled: Bool = true
    var opacity: Double = 1

    var body: some View {
        Button("返回", systemImage: "chevron.left", action: action)
            .labelStyle(.iconOnly)
            .tint(foregroundColor)
            .disabled(!isEnabled)
            .opacity(opacity)
    }
}
