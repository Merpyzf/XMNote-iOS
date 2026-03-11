import SwiftUI

/**
 * [INPUT]: 依赖 ReadingDashboardViewModel.GoalEditorMode 提供标题语义，依赖 DesignTokens 与 SwiftUI 输入控件承接目标编辑
 * [OUTPUT]: 对外提供 ReadingGoalEditorSheet（首页阅读目标编辑弹层）
 * [POS]: Reading/Sheets 业务弹层，负责今日目标与年度目标的统一输入表单
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
/// ReadingGoalEditorSheet 统一承接首页的今日目标与年度目标编辑流程，避免页面内散落重复表单逻辑。
struct ReadingGoalEditorSheet: View {
    /// Item 让 sheet 能以 `Identifiable` 形式驱动展示，同时保留目标类型语义。
    struct Item: Identifiable {
        let mode: ReadingDashboardViewModel.GoalEditorMode

        var id: String {
            switch mode {
            case .daily: "daily"
            case .yearly: "yearly"
            }
        }
    }

    let item: Item
    @Binding var value: String
    let isSaving: Bool
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section(item.mode == .daily ? "单位：分钟" : "单位：本") {
                    TextField("请输入目标值", text: $value)
                        .keyboardType(.numberPad)
                        .focused($isFocused)
                }
            }
            .navigationTitle(item.mode.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存", action: onConfirm)
                        .disabled(isSaving)
                }
            }
        }
        .presentationDetents([.medium])
        .task { isFocused = true }
    }
}
