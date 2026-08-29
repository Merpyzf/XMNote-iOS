/**
 * [INPUT]: 依赖 DesignSystem 的颜色、圆角与描边令牌，接收容器 Shape 与内容构造闭包
 * [OUTPUT]: 对外提供 CardContainer，可配置语义 Shape、连续圆角与可选描边
 * [POS]: UIComponents/Foundation 的基础表层容器，不持有业务状态或交互
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 内容卡片容器，对应 Android 端的 ContentBox。
/// 默认仅提供背景与圆角，按需显式开启描边。
struct CardContainer<Content: View, ContainerShape: Shape>: View {
    let shape: ContainerShape
    let showsBorder: Bool
    let borderColor: Color
    let content: Content

    /// 注入语义 Shape、边框与内容闭包，组装基础容器外观。
    init(
        shape: ContainerShape,
        showsBorder: Bool = false,
        borderColor: Color = .surfaceBorderStrong,
        @ViewBuilder content: () -> Content
    ) {
        self.shape = shape
        self.showsBorder = showsBorder
        self.borderColor = borderColor
        self.content = content()
    }

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.surfaceCard)
            .clipShape(shape)
            .overlay {
                if showsBorder {
                    shape
                        .stroke(borderColor, lineWidth: StrokeWidth.hairline)
                }
            }
    }
}

extension CardContainer where ContainerShape == RoundedRectangle {
    /// 注入连续圆角、边框与内容闭包，保持普通内容卡片的既有默认外观。
    init(
        cornerRadius: CGFloat = CornerRadius.blockLarge,
        showsBorder: Bool = false,
        borderColor: Color = .surfaceBorderStrong,
        @ViewBuilder content: () -> Content
    ) {
        self.init(
            shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
            showsBorder: showsBorder,
            borderColor: borderColor,
            content: content
        )
    }
}

#Preview("CardContainer") {
    ZStack {
        Color.surfacePage.ignoresSafeArea()
        CardContainer {
            VStack(spacing: Spacing.none) {
                Text("卡片内容示例")
                    .padding(Spacing.screenEdge)
            }
        }
        .padding(Spacing.screenEdge)
    }
}
