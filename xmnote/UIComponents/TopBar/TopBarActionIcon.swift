/**
 * [INPUT]: 依赖 SwiftUI 图标与字体渲染能力
 * [OUTPUT]: 对外提供 TopBarActionIcon 顶部栏统一图标组件、TopBarActionHitShape 热区形态、TopBarBackButton 导航返回按钮与 TopBarDismissButton 模态收起按钮
 * [POS]: UIComponents/TopBar 的原子级按钮图标、导航返回与模态收起组件，被顶部操作区域和层级退出入口复用
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

/// 顶部模态收起按钮，以明确的向下语义关闭当前业务层级。
struct TopBarDismissButton: View {
    let action: () -> Void
    var foregroundColor: Color = .primary
    var isEnabled: Bool = true
    var opacity: Double = 1

    var body: some View {
        Button(action: action) {
            TopBarActionIcon(
                systemName: "chevron.down",
                iconSize: 16,
                containerSize: 44,
                weight: .semibold,
                foregroundColor: foregroundColor
            )
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .opacity(opacity)
        .accessibilityLabel("收起阅读计时")
    }
}
