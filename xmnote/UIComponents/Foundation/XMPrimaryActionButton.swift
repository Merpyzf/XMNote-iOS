/**
 * [INPUT]: 依赖 SwiftUI Button、DesignTokens 中的主操作颜色、字体与圆角语义
 * [OUTPUT]: 对外提供 XMPrimaryActionButton，统一宽幅品牌主操作的尺寸、状态与按压反馈
 * [POS]: UIComponents/Foundation 的跨业务主操作按钮，被需要明确确认语义的底部操作区复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 宽幅品牌主操作按钮，以固定视觉上限和连续圆角承载页面唯一确认动作。
struct XMPrimaryActionButton: View {
    let title: String
    let containerInsetCompensation: CGSize
    let action: () -> Void

    /// 使用动态标题和同步触发动作创建主操作；容器补偿仅用于抵消系统额外的控件内距。
    init(
        _ title: String,
        containerInsetCompensation: CGSize = .zero,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.containerInsetCompensation = containerInsetCompensation
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
        }
        .buttonStyle(
            XMPrimaryActionButtonStyle(
                minimumControlHeight: XMPrimaryActionButtonMetrics.minimumControlHeight
                    + containerInsetCompensation.height
            )
        )
        .buttonSizing(.fitted)
        .frame(
            width: XMPrimaryActionButtonMetrics.controlWidth
                + containerInsetCompensation.width
        )
        .frame(minHeight: XMPrimaryActionButtonMetrics.minimumControlHeight)
        .fixedSize(horizontal: true, vertical: true)
    }
}

/// 将品牌填充、禁用语义和轻量按压反馈收敛到组件内部，保持轮廓尺寸稳定。
private struct XMPrimaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    let minimumControlHeight: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: CornerRadius.blockLarge,
            style: .continuous
        )

        configuration.label
            .font(AppTypography.headlineSemibold)
            .foregroundStyle(
                isEnabled
                    ? Color.primaryActionForeground
                    : Color.buttonDisabledForeground
            )
            .multilineTextAlignment(.center)
            .padding(.horizontal, Spacing.screenEdge)
            .frame(maxWidth: .infinity, minHeight: minimumControlHeight)
            .background(
                isEnabled ? Color.primaryActionFill : Color.buttonDisabled,
                in: shape
            )
            .contentShape(shape)
            .opacity(
                isEnabled && configuration.isPressed
                    ? XMPrimaryActionButtonMetrics.pressedOpacity
                    : 1
            )
    }
}

/// 参考 402pt 宽、3 倍分辨率界面校准的可见轮廓规格。
private enum XMPrimaryActionButtonMetrics {
    static let controlWidth: CGFloat = 340
    static let minimumControlHeight: CGFloat = 46
    static let pressedOpacity = 0.86
}
