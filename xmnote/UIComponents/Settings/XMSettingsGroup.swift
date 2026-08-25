/**
 * [INPUT]: 依赖 DesignSystem 的表层、圆角、间距和 Reduce Motion 环境，接收配置项内容
 * [OUTPUT]: 对外提供 grouped/singleItem 形态的 XMSettingsGroup 与 XMSettingsDivider
 * [POS]: UIComponents/Settings 的配置项分组层，统一卡片表层、内部留白、形态过渡与弱分割线
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

private enum XMSettingsGroupLayout {
    static let groupedCornerRadius = CornerRadius.containerXXL
    static let weakSeparatorOpacity = 0.42
    static let presentationDuration = 0.18
}

/// 设置分组的内容组织形态；单项形态只用于没有附属输入、提示或错误内容的唯一顶层设置行。
enum XMSettingsGroupPresentation: Equatable {
    case grouped
    case singleItem
}

/// 设置分组，统一业务设置页的表层、圆角与内部边距，并为真正的单项设置提供 Capsule 语义。
struct XMSettingsGroup<Content: View>: View {
    let presentation: XMSettingsGroupPresentation
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let content: Content
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 注入设置行内容；默认保持统一分组圆角，页面只选择单项形态与内容留白。
    init(
        presentation: XMSettingsGroupPresentation = .grouped,
        horizontalPadding: CGFloat = Spacing.contentEdge,
        verticalPadding: CGFloat = Spacing.half,
        @ViewBuilder content: () -> Content
    ) {
        self.presentation = presentation
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .background(
                Color.surfaceCard,
                in: XMSettingsGroupShape(
                    singleItemProgress: presentation == .singleItem ? 1 : 0
                )
            )
            .animation(presentationAnimation, value: presentation)
    }

    private var presentationAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: XMSettingsGroupLayout.presentationDuration)
    }
}

/// 在真实容器高度内计算 Capsule 半径，使单项与分组圆角可连续插值且无需伪造超大圆角令牌。
private struct XMSettingsGroupShape: Shape {
    var singleItemProgress: CGFloat

    var animatableData: CGFloat {
        get { singleItemProgress }
        set { singleItemProgress = newValue }
    }

    /// 根据当前布局尺寸生成连续圆角路径，展开过程中保持边缘稳定。
    func path(in rect: CGRect) -> Path {
        let capsuleRadius = min(rect.width, rect.height) / 2
        let groupedCornerRadius = XMSettingsGroupLayout.groupedCornerRadius
        let resolvedRadius = groupedCornerRadius
            + (capsuleRadius - groupedCornerRadius) * singleItemProgress
        return RoundedRectangle(cornerRadius: resolvedRadius, style: .continuous)
            .path(in: rect)
    }
}

/// 设置分组内的弱分割线，以半点语义线降低结构噪声，同时保持组内关系可辨识。
struct XMSettingsDivider: View {
    var body: some View {
        Rectangle()
            .fill(Color.surfaceBorderSubtle.opacity(XMSettingsGroupLayout.weakSeparatorOpacity))
            .frame(height: CardStyle.borderWidth)
            .accessibilityHidden(true)
    }
}
