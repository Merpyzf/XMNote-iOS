/**
 * [INPUT]: 依赖 XMStateRole、XMStateAction 与 SwiftUI ContentUnavailableView，接收页面级状态文案和可选动作
 * [OUTPUT]: 对外提供 XMContentStateView，统一页面、Sheet 与列表背景的完整不可用状态
 * [POS]: UIComponents/Foundation/StatePresentation 的页面级状态基础组件，是 ContentUnavailableView 的项目唯一生产入口
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 完整内容状态使用系统不可用界面承载标题、说明和单一动作，并统一项目语义图标。
struct XMContentStateView: View {
    let role: XMStateRole
    let title: String
    let message: String?
    let systemImage: String?
    let action: XMStateAction?

    /// 创建完整状态；业务可替换内容型图标，但布局、文字层级和动作样式由组件统一管理。
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
            Label {
                Text(title)
            } icon: {
                Image(systemName: resolvedSystemImage)
                    .foregroundStyle(role.iconColor)
            }
        } description: {
            if let resolvedMessage {
                Text(resolvedMessage)
            }
        } actions: {
            if let action {
                Button(action: action.perform) {
                    XMStateActionLabel(action: action)
                        .frame(minHeight: Spacing.actionReserved)
                }
                .buttonStyle(.bordered)
                .disabled(!action.isEnabled)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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

#Preview("完整状态") {
    XMContentStateView(
        role: .failure,
        title: "暂时无法加载",
        message: "请检查网络后重试。",
        action: XMStateAction("重试", systemImage: "arrow.clockwise") {}
    )
    .background(Color.surfacePage)
}
