/**
 * [INPUT]: 依赖 SwiftUI interaction content shape 与 InteractionMetrics 的最小触控目标
 * [OUTPUT]: 对外提供不改变布局和绘制的 xmMinimumHitTarget，以及可测试的 XMMinimumHitTargetShape
 * [POS]: UIComponents/Controls/Button 的 SwiftUI 交互基础设施，与 UIKit 的 XMMinimumHitTargetButton 形成明确边界
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 指定视觉内容在最小命中矩形中的固定方位，避免边缘控件把热区扩向容器外侧。
enum XMMinimumHitTargetAnchor {
    case center
    case top
    case bottom
    case leading
    case trailing
    case topLeading
    case topTrailing
    case bottomLeading
    case bottomTrailing
}

/// 生成至少 44pt 的交互矩形；Shape 路径可超出视觉 bounds，但不会参与布局或绘制。
struct XMMinimumHitTargetShape: Shape {
    let minimumSize: CGSize
    let anchor: XMMinimumHitTargetAnchor
    let layoutDirection: LayoutDirection

    init(
        minimumSize: CGSize = CGSize(
            width: InteractionMetrics.minimumTouchTarget,
            height: InteractionMetrics.minimumTouchTarget
        ),
        anchor: XMMinimumHitTargetAnchor = .center,
        layoutDirection: LayoutDirection = .leftToRight
    ) {
        self.minimumSize = minimumSize
        self.anchor = anchor
        self.layoutDirection = layoutDirection
    }

    /// 返回语义命中矩形，供 Shape 渲染与几何测试共享同一计算结果。
    func expandedRect(in rect: CGRect) -> CGRect {
        let horizontalExpansion = max(minimumSize.width - rect.width, 0)
        let verticalExpansion = max(minimumSize.height - rect.height, 0)
        let horizontalOutsets = resolvedHorizontalOutsets(total: horizontalExpansion)
        let verticalOutsets = resolvedVerticalOutsets(total: verticalExpansion)

        return CGRect(
            x: rect.minX - horizontalOutsets.left,
            y: rect.minY - verticalOutsets.top,
            width: rect.width + horizontalExpansion,
            height: rect.height + verticalExpansion
        )
    }

    /// 仅提供 interaction content shape，不生成任何可见路径样式。
    func path(in rect: CGRect) -> Path {
        Path(expandedRect(in: rect))
    }

    /// 按语义 leading/trailing 与当前布局方向分配水平方向扩展量。
    private func resolvedHorizontalOutsets(total: CGFloat) -> (left: CGFloat, right: CGFloat) {
        switch anchor {
        case .leading, .topLeading, .bottomLeading:
            return layoutDirection == .rightToLeft ? (total, 0) : (0, total)
        case .trailing, .topTrailing, .bottomTrailing:
            return layoutDirection == .rightToLeft ? (0, total) : (total, 0)
        case .center, .top, .bottom:
            return (total / 2, total / 2)
        }
    }

    /// 按顶部、底部或居中锚点分配垂直方向扩展量。
    private func resolvedVerticalOutsets(total: CGFloat) -> (top: CGFloat, bottom: CGFloat) {
        switch anchor {
        case .top, .topLeading, .topTrailing:
            return (0, total)
        case .bottom, .bottomLeading, .bottomTrailing:
            return (total, 0)
        case .center, .leading, .trailing:
            return (total / 2, total / 2)
        }
    }
}

private struct XMMinimumHitTargetModifier: ViewModifier {
    let anchor: XMMinimumHitTargetAnchor

    @Environment(\.layoutDirection) private var layoutDirection

    /// 把计算后的形状仅写入 interaction 语义，不参与默认绘制与布局。
    func body(content: Content) -> some View {
        content.contentShape(
            .interaction,
            XMMinimumHitTargetShape(anchor: anchor, layoutDirection: layoutDirection)
        )
    }
}

extension View {
    /// 把 SwiftUI 控件的交互与可访问性轮廓补足到 44pt，同时保持原有 frame、间距、背景和视觉 bounds。
    func xmMinimumHitTarget(anchor: XMMinimumHitTargetAnchor = .center) -> some View {
        modifier(XMMinimumHitTargetModifier(anchor: anchor))
    }
}
