/**
 * [INPUT]: 依赖 XMStateRole、XMStateAction、CardContainer 与状态呈现设计令牌，接收局部容器状态文案
 * [OUTPUT]: 对外提供 XMCompactStateView，统一卡片、分区与局部内容区的紧凑状态
 * [POS]: UIComponents/Foundation/StatePresentation 的局部状态基础组件，不负责页面占位高度与业务阶段切换
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 紧凑状态提供居中内容区与带表层卡片两种稳定布局，不假设调用方容器尺寸。
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
    @ScaledMetric(relativeTo: .title3) private var centeredIconSize = StatePresentationMetrics.centeredIconSize
    @ScaledMetric(relativeTo: .headline) private var cardIconSize = StatePresentationMetrics.cardIconSize
    @ScaledMetric(relativeTo: .headline) private var cardIconContainerSize = StatePresentationMetrics.cardIconContainerSize

    /// 创建紧凑状态；外层页面继续负责最小高度、滚动位置和安全区关系。
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
            Image(systemName: resolvedSystemImage)
                .font(.system(size: centeredIconSize, weight: .regular))
                .foregroundStyle(role.iconColor)
                .accessibilityHidden(true)

            textContent(alignment: .center)

            if let action {
                actionButton(action)
            }
        }
        .padding(.horizontal, Spacing.contentEdge)
        .padding(.vertical, Spacing.section * 2)
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var cardContent: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            if dynamicTypeSize >= .accessibility1 {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    cardIcon
                    textContent(alignment: .leading)
                }
            } else {
                HStack(alignment: .top, spacing: Spacing.base) {
                    cardIcon
                    textContent(alignment: .leading)
                }
            }

            if let action {
                actionButton(action)
            }
        }
    }

    private var cardIcon: some View {
        RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
            .fill(role.iconColor.opacity(StatePresentationMetrics.toneBackgroundOpacity))
            .frame(width: cardIconContainerSize, height: cardIconContainerSize)
            .overlay {
                Image(systemName: resolvedSystemImage)
                    .font(.system(size: cardIconSize, weight: .semibold))
                    .foregroundStyle(role.iconColor)
            }
            .accessibilityHidden(true)
    }

    /// 组合标题与可选说明，保持测量字体、对齐方向和动态换行一致。
    private func textContent(alignment: TextAlignment) -> some View {
        VStack(alignment: alignment == .center ? .center : .leading, spacing: Spacing.half) {
            Text(title)
                .font(StatePresentationTypography.compactTitle)
                .foregroundStyle(Color.textPrimary)
                .multilineTextAlignment(alignment)
                .fixedSize(horizontal: false, vertical: true)

            if let resolvedMessage {
                Text(resolvedMessage)
                    .font(StatePresentationTypography.compactMessage)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(alignment)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// 使用系统 bordered 样式渲染唯一动作，并保证动态字体下仍有完整点击热区。
    private func actionButton(_ action: XMStateAction) -> some View {
        Button(action: action.perform) {
            XMStateActionLabel(action: action)
                .font(StatePresentationTypography.compactAction)
                .frame(minHeight: Spacing.actionReserved)
        }
        .buttonStyle(.bordered)
        .disabled(!action.isEnabled)
    }

    private var resolvedSystemImage: String {
        systemImage ?? role.defaultSystemImage
    }

    private var resolvedMessage: String? {
        guard let message else { return nil }
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

#Preview("紧凑状态") {
    VStack(spacing: Spacing.section) {
        XMCompactStateView(
            role: .empty,
            title: "暂无书籍",
            message: "添加书籍后会显示在这里。",
            systemImage: "books.vertical"
        )

        XMCompactStateView(
            role: .failure,
            title: "搜索失败",
            message: "网络连接恢复后可以重新搜索。",
            action: XMStateAction("重新搜索", systemImage: "arrow.clockwise") {},
            style: .card
        )
    }
    .padding()
    .background(Color.surfacePage)
}
