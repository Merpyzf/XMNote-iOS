/**
 * [INPUT]: 依赖 AppTypography、SemanticColors 与 XMSettingsPageLayout，接收本地化分区标题和内容
 * [OUTPUT]: 对外提供标题与内容层级稳定的 XMSettingsSection
 * [POS]: UIComponents/Settings 的配置页分区组件，负责分区标题语义与从属间距
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 配置页标准分区，将标题对齐到卡片内容线，并维持标题与内容的紧密从属关系。
struct XMSettingsSection<Content: View>: View {
    let title: LocalizedStringResource
    @ViewBuilder let content: Content

    /// 注入可本地化的分区标题与内容；标题仅表达信息分组，不承载交互。
    init(
        _ title: LocalizedStringResource,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: XMSettingsPageLayout.sectionContentSpacing) {
            Text(title)
                .font(AppTypography.footnoteSemibold)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, Spacing.contentEdge)

            content
        }
    }
}
