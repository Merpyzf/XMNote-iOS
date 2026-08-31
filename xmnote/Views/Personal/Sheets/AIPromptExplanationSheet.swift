/**
 * [INPUT]: 依赖 XMSheetScaffold 与设计系统排版、间距语义，接收系统 Sheet 的关闭环境
 * [OUTPUT]: 对外提供 AIPromptExplanationSheet，以只读短文解释用户提示词与系统提示词的用途和边界
 * [POS]: Views/Personal/Sheets 的提示词新手说明页，由 AI 提示词编辑页更多菜单按需呈现
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 用最少层级说明两类提示词的分工，帮助首次编辑的用户决定内容应放在哪里。
struct AIPromptExplanationSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        XMSheetScaffold(
            title: "提示词说明",
            onClose: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Spacing.double) {
                Text("用户提示词说明每次要做什么；系统提示词说明处理时遵循什么方式。两者会共同影响运行结果。")
                    .font(AppTypography.body)
                    .foregroundStyle(Color.textSecondary)
                    .lineSpacing(Spacing.compact)

                explanationSection(
                    title: "用户提示词",
                    description: "写明每次运行要处理的内容，以及要完成的任务。例如，总结书摘、解释词义，或为书摘生成标签。书摘、章节等变量会在运行时自动替换为实际内容。"
                )

                explanationSection(
                    title: "系统提示词",
                    description: "写明每次运行都应遵循的角色、判断原则和表达方式。例如，以阅读助手的角度回答、有多种可能时分别说明，或使用简洁、客观的语言。这里不支持变量；会变化的书摘、章节等内容应放在用户提示词中。"
                )
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.contentEdge)
        }
    }

    /// 以系统标题层级和正文层级构成可顺序朗读的说明分组，不增加卡片或装饰表层。
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
