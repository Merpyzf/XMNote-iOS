/**
 * [INPUT]: 依赖 XMStateAction、XMMinimumHitTarget 与设计系统状态令牌，接收保留内容时的局部反馈文案和可选动作
 * [OUTPUT]: 对外提供 XMInlineStatusBanner，统一中性提示、警告与失败横幅及尾部文字动作
 * [POS]: UIComponents/Feedback/StatePresentation 的非阻断反馈组件，由页面决定插入位置和外边距
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 局部状态横幅在不遮挡已有内容的前提下提供原因说明和单一恢复动作。
struct XMInlineStatusBanner: View {
    enum Tone {
        case neutral
        case warning
        case error

        var color: Color {
            switch self {
            case .neutral:
                .textSecondary
            case .warning:
                .feedbackWarning
            case .error:
                .feedbackError
            }
        }

        var defaultSystemImage: String {
            switch self {
            case .neutral:
                "info.circle"
            case .warning:
                "exclamationmark.triangle"
            case .error:
                "exclamationmark.circle"
            }
        }
    }

    let message: String
    let tone: Tone
    let systemImage: String?
    let action: XMStateAction?

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .footnote) private var iconSize = StatePresentationMetrics.bannerIconSize

    /// 创建局部状态横幅；组件不添加外边距，避免破坏页面现有安全区和滚动布局。
    init(
        _ message: String,
        tone: Tone = .neutral,
        systemImage: String? = nil,
        action: XMStateAction? = nil
    ) {
        self.message = message
        self.tone = tone
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        Group {
            if dynamicTypeSize >= .accessibility1 {
                expandedContent
            } else {
                regularContent
            }
        }
        .padding(.horizontal, Spacing.base)
        .padding(.vertical, Spacing.cozy)
        .background(
            Color.controlFillSecondary,
            in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
        )
        .accessibilityElement(children: .contain)
    }

    private var regularContent: some View {
        HStack(spacing: Spacing.base) {
            statusMessage

            Spacer(minLength: 0)

            if let action {
                actionButton(action, hitTargetAnchor: .trailing)
            }
        }
    }

    private var expandedContent: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            statusMessage

            if let action {
                actionButton(action, hitTargetAnchor: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var statusMessage: some View {
        HStack(alignment: .firstTextBaseline, spacing: Spacing.cozy) {
            Image(systemName: systemImage ?? tone.defaultSystemImage)
                .font(.system(size: iconSize, weight: .regular))
                .foregroundStyle(tone.color)
                .accessibilityHidden(true)

            Text(message)
                .font(StatePresentationTypography.bannerMessage)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    /// 使用系统无边框动作保持横幅紧凑，并按横向或纵向布局扩展点击热区。
    private func actionButton(
        _ action: XMStateAction,
        hitTargetAnchor: XMMinimumHitTargetAnchor
    ) -> some View {
        Button(action: action.perform) {
            XMStateActionLabel(action: action)
                .font(StatePresentationTypography.bannerAction)
        }
        .buttonStyle(.borderless)
        .tint(Color.stateActionForeground)
        .xmMinimumHitTarget(anchor: hitTargetAnchor)
        .disabled(!action.isEnabled)
    }
}

#Preview("局部状态横幅") {
    VStack(spacing: Spacing.base) {
        XMInlineStatusBanner("部分内容暂时无法更新", tone: .warning)
        XMInlineStatusBanner(
            "内容更新失败",
            tone: .error,
            action: XMStateAction("重试") {}
        )
    }
    .padding()
    .background(Color.surfacePage)
}
