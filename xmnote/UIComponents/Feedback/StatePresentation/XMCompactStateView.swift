/**
 * [INPUT]: 依赖 XMStateRole、XMStateAction、XMMinimumHitTarget、CardContainer 与设计系统状态令牌，接收局部容器状态文案
 * [OUTPUT]: 对外提供 XMCompactStateView，统一卡片、分区与局部内容区的紧凑状态及低权重动作
 * [POS]: UIComponents/Feedback/StatePresentation 的局部状态基础组件，不负责页面占位高度与业务阶段切换
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 紧凑状态提供居中内容区与带表层卡片两种稳定布局；所有角色与页面状态共享低权重排版。
struct XMCompactStateView: View {
    enum Style {
        case centered
        case card
    }

    let role: XMStateRole
    let title: String
    let message: String?
    let systemImage: String?
    let action: XMStateAction?
    let style: Style

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var centeredIconSize = StatePresentationMetrics.centeredIconSize
    @ScaledMetric(relativeTo: .body) private var cardIconSize = StatePresentationMetrics.cardIconSize

    /// 创建紧凑状态；空态只有显式提供图标时才进入引导表达，外层继续负责容器几何。
    init(
        role: XMStateRole,
        title: String,
        message: String? = nil,
        systemImage: String? = nil,
        action: XMStateAction? = nil,
        style: Style = .centered
    ) {
        self.role = role
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.action = action
        self.style = style
    }

    var body: some View {
        Group {
            switch style {
            case .centered:
                centeredContent
            case .card:
                CardContainer(
                    cornerRadius: CornerRadius.blockLarge,
                    showsBorder: true,
                    borderColor: .surfaceBorderSubtle
                ) {
                    cardContent
                        .padding(Spacing.contentEdge)
                }
            }
        }
        .accessibilityElement(children: action == nil ? .combine : .contain)
    }

    private var centeredContent: some View {
        VStack(spacing: Spacing.base) {
            if let resolvedSystemImage {
                Image(systemName: resolvedSystemImage)
                    .font(.system(size: centeredIconSize, weight: .regular))
                    .foregroundStyle(role.iconColor)
                    .accessibilityHidden(true)
            }

            textContent(alignment: .center)

            if let action {
                actionButton(action, hitTargetAnchor: .center)
            }
        }
        .padding(.horizontal, Spacing.contentEdge)
        .padding(
            .vertical,
            resolvedSystemImage == nil
                ? XMCompactStateLayout.quietVerticalPadding
                : XMCompactStateLayout.centeredVerticalPadding
        )
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var cardContent: some View {
        if resolvedSystemImage == nil {
            cardTextColumn
        } else if dynamicTypeSize >= .accessibility1 {
            VStack(alignment: .leading, spacing: Spacing.base) {
                cardIcon
                cardTextColumn
            }
        } else {
            HStack(alignment: .top, spacing: Spacing.base) {
                cardIcon
                cardTextColumn
            }
        }
    }

    private var cardTextColumn: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            textContent(alignment: .leading)

            if let action {
                actionButton(action, hitTargetAnchor: .leading)
            }
        }
    }

    private var cardIcon: some View {
        Image(systemName: resolvedSystemImage ?? role.defaultSystemImage)
            .font(.system(size: cardIconSize, weight: .regular))
            .foregroundStyle(role.iconColor)
            .frame(minWidth: cardIconSize, minHeight: cardIconSize)
            .accessibilityHidden(true)
    }

    /// 组合标题与可选说明，保持测量字体、对齐方向和动态换行一致。
    private func textContent(alignment: TextAlignment) -> some View {
        VStack(alignment: alignment == .center ? .center : .leading, spacing: Spacing.half) {
            Text(title)
                .font(StatePresentationTypography.title)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(alignment)
                .fixedSize(horizontal: false, vertical: true)

            if let resolvedMessage {
                Text(resolvedMessage)
                    .font(StatePresentationTypography.compactMessage)
                    .foregroundStyle(Color.textHint)
                    .multilineTextAlignment(alignment)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// 使用系统无边框样式渲染局部唯一动作，并按容器对齐方向扩展点击热区。
    private func actionButton(
        _ action: XMStateAction,
        hitTargetAnchor: XMMinimumHitTargetAnchor
    ) -> some View {
        Button(action: action.perform) {
            XMStateActionLabel(action: action)
                .font(StatePresentationTypography.action)
        }
        .buttonStyle(.borderless)
        .tint(Color.stateActionForeground)
        .xmMinimumHitTarget(anchor: hitTargetAnchor)
        .disabled(!action.isEnabled)
    }

    private var resolvedSystemImage: String? {
        if let systemImage {
            return systemImage
        }
        return role == .empty ? nil : role.defaultSystemImage
    }

    private var resolvedMessage: String? {
        guard let message else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 紧凑状态局部布局组合，避免把单一容器的视觉留白晋升为全局间距令牌。
private enum XMCompactStateLayout {
    static let quietVerticalPadding = Spacing.double
    static let centeredVerticalPadding = Spacing.double + Spacing.screenEdge
}

#Preview("紧凑状态") {
    VStack(spacing: Spacing.section) {
        XMCompactStateView(
            role: .empty,
            title: "暂无书籍"
        )

        XMCompactStateView(
            role: .failure,
            title: "搜索失败",
            action: XMStateAction("重试") {},
            style: .card
        )
    }
    .padding()
    .background(Color.surfacePage)
}
