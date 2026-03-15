/**
 * [INPUT]: 依赖 DesignTokens 与 CardContainer 渲染搜索状态卡，依赖可选动作回调承接重试或登录等交互
 * [OUTPUT]: 对外提供 BookSearchStatusCard，统一搜索页错误、恢复和行内提示的状态表达
 * [POS]: Book 模块搜索页的页面私有状态组件，服务 BookSearchView 的状态分支，不承担业务状态编排
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 搜索状态卡，统一承接错误、登录恢复和轻量提示的图标、文案与操作布局。
struct BookSearchStatusCard: View {
    let systemImage: String
    let tint: Color
    let title: String
    let message: String
    let actionTitle: String?
    let action: (() -> Void)?

    init(
        systemImage: String,
        tint: Color = .brand,
        title: String,
        message: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.systemImage = systemImage
        self.tint = tint
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        CardContainer(
            cornerRadius: CornerRadius.containerMedium,
            showsBorder: true,
            borderColor: .surfaceBorderSubtle
        ) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                HStack(alignment: .top, spacing: Spacing.base) {
                    RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                        .fill(tint.opacity(0.12))
                        .frame(width: 40, height: 40)
                        .overlay {
                            Image(systemName: systemImage)
                                .font(.system(size: 18, weight: .semibold))
                                .foregroundStyle(tint)
                        }

                    VStack(alignment: .leading, spacing: Spacing.half) {
                        Text(title)
                            .font(AppTypography.headlineSemibold)
                            .foregroundStyle(Color.textPrimary)

                        Text(message)
                            .font(AppTypography.subheadline)
                            .foregroundStyle(Color.textSecondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                if let actionTitle, let action {
                    Button(actionTitle, action: action)
                        .buttonStyle(.plain)
                        .font(AppTypography.subheadlineSemibold)
                        .foregroundStyle(tint)
                        .padding(.top, Spacing.half)
                }
            }
            .padding(Spacing.contentEdge)
        }
    }
}
