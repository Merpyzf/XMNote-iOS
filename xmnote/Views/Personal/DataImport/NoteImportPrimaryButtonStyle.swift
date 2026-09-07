/**
 * [INPUT]: 依赖设计令牌、按钮可用状态与保留系统辅助功能适配的交互式 Liquid Glass
 * [OUTPUT]: 提供书摘导入流程专用的胶囊主操作样式
 * [POS]: Views/Personal/DataImport 的功能内样式，不改变全局按钮或业务状态
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 导入主动作只由系统玻璃响应触摸，不叠加按压缩放、弹跳或触感。
struct NoteImportPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    /// 保留真实 Button 点击语义，禁用时移除品牌强调与玻璃交互。
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(AppTypography.headline)
            .foregroundStyle(isEnabled ? Color.primaryActionForeground : Color.buttonDisabledForeground)
            .tint(isEnabled ? Color.primaryActionForeground : Color.buttonDisabledForeground)
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.comfortable)
            .frame(maxWidth: .infinity, minHeight: 50)
            .contentShape(Capsule())
            .glassEffect(
                .regular
                    .tint(isEnabled ? Color.appTint : Color.buttonDisabled)
                    .interactive(isEnabled),
                in: .capsule
            )
    }
}

#Preview("导入主操作") {
    VStack(spacing: Spacing.section) {
        Button("选择文件") {}.buttonStyle(NoteImportPrimaryButtonStyle())
        Button("预览书摘") {}.buttonStyle(NoteImportPrimaryButtonStyle()).disabled(true)
    }
    .padding(Spacing.screenEdge)
}
