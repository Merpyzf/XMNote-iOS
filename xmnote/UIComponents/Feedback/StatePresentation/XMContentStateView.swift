/**
 * [INPUT]: 依赖 XMStateRole、XMStateAction、XMMinimumHitTarget 与 SwiftUI ContentUnavailableView，接收页面级状态文案和可选动作
 * [OUTPUT]: 对外提供 XMContentStateView，统一页面、Sheet 与列表背景的完整不可用状态及原生动作层级
 * [POS]: UIComponents/Feedback/StatePresentation 的页面级状态基础组件，是 ContentUnavailableView 的项目唯一生产入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 完整内容状态使用系统不可用界面承载标题、说明和单一动作，并为所有角色保持一致的低权重排版。
struct XMContentStateView: View {
    let role: XMStateRole
    let title: String
    let message: String?
    let systemImage: String?
    let action: XMStateAction?

    @ScaledMetric(relativeTo: .body) private var centeredIconSize = StatePresentationMetrics.centeredIconSize

    /// 创建完整状态；空态只有显式提供图标时才进入引导表达，其余角色自动使用语义图标。
    init(
        role: XMStateRole,
        title: String,
        message: String? = nil,
        systemImage: String? = nil,
        action: XMStateAction? = nil
    ) {
        self.role = role
        self.title = title
        self.message = message
        self.systemImage = systemImage
        self.action = action
    }

    var body: some View {
        ContentUnavailableView {
            VStack(spacing: Spacing.base) {
                if let resolvedSystemImage {
                    Image(systemName: resolvedSystemImage)
                        .font(.system(size: centeredIconSize, weight: .regular))
                        .foregroundStyle(role.iconColor)
                        .accessibilityHidden(true)
                }

                titleText
            }
        } description: {
            if let resolvedMessage {
                Text(resolvedMessage)
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Color.textHint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } actions: {
            if let action {
                actionButton(action)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: action == nil ? .combine : .contain)
    }

    private var titleText: some View {
        Text(title)
            .font(StatePresentationTypography.title)
            .foregroundStyle(Color.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 状态内动作保持纯文字层级，页面唯一主操作继续由工具栏或页面操作区承载。
    private func actionButton(_ action: XMStateAction) -> some View {
        Button(action: action.perform) {
            XMStateActionLabel(action: action)
                .font(StatePresentationTypography.action)
        }
        .buttonStyle(.borderless)
        .tint(Color.stateActionForeground)
        .xmMinimumHitTarget(anchor: .center)
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

#Preview("完整状态") {
    VStack {
        XMContentStateView(role: .empty, title: "暂无书籍")
        XMContentStateView(
            role: .failure,
            title: "暂时无法加载",
            action: XMStateAction("重试") {}
        )
    }
    .background(Color.surfacePage)
}
