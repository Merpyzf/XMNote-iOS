/**
 * [INPUT]: 依赖 XMSheetScaffold 与设计系统排版、间距语义，接收系统 Sheet 的关闭环境
 * [OUTPUT]: 对外提供 AIPromptExplanationSheet，以只读短文解释两类提示词的用途与边界
 * [POS]: Views/Personal/Sheets 的提示词新手说明页，由 AI 提示词编辑页更多菜单按需呈现
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 用最少层级说明两类提示词的分工，帮助首次编辑的用户理解调整方向。
struct AIPromptExplanationSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        XMSheetScaffold(
            title: "提示词说明",
            onClose: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Spacing.double) {
                explanationSection(
                    title: "用户提示词",
                    description: "告诉 AI 这次要做什么，以及希望得到怎样的结果。适合调整要处理的内容、任务要求和结果重点。书摘内容、书名等变量会在运行时自动替换为当前内容。"
                )

                explanationSection(
                    title: "系统提示词",
                    description: "告诉 AI 应该怎样完成任务。适合设定回答时采用的角色、判断标准、表达方式和输出格式。这里不能使用变量；会随书摘变化的内容，请放在用户提示词中。"
                )
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.contentEdge)
        }
    }

    /// 以标题和概念说明构成可顺序朗读的分组，不增加卡片或装饰表层。
    private func explanationSection(
        title: LocalizedStringResource,
        description: LocalizedStringResource
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text(title)
                .font(AppTypography.headline)
                .foregroundStyle(Color.textPrimary)
                .accessibilityAddTraits(.isHeader)

            Text(description)
                .font(AppTypography.body)
                .foregroundStyle(Color.textSecondary)
                .lineSpacing(Spacing.compact)
        }
    }
}
