import SwiftUI

/**
 * [INPUT]: 依赖 ReadingDashboardViewModel.GoalEditorMode 与目标草稿/错误状态，依赖 DesignTokens 与 SwiftUI 输入控件承接目标编辑
 * [OUTPUT]: 对外提供 ReadingGoalEditorSheet（今日目标数字输入 + 年度目标 1...365 原生滚轮）
 * [POS]: Reading/Sheets 业务弹层，负责今日目标与年度目标的差异化编辑和明确提交
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */
/// ReadingGoalEditorSheet 统一承接首页的今日目标与年度目标编辑流程，避免页面内散落重复表单逻辑。
struct ReadingGoalEditorSheet: View {
    /// Layout 收口年度滚轮在普通字号下的紧凑 Sheet 高度，避免移除说明文案后留下无意义空区。
    private enum Layout {
        static let yearlyRegularPresentationHeight: CGFloat = 380
    }

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
    let errorMessage: String?
    let onConfirm: () -> Void
    let onCancel: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var isFocused: Bool

    @ViewBuilder
    var body: some View {
        switch item.mode {
        case .daily:
            XMSheetScaffold(
                title: item.mode.title,
                onClose: cancelDailyGoal,
                isConfirming: isSaving,
                confirmationAction: confirmDailyGoal
            ) {
                dailyGoalForm
            }
            .scrollDismissesKeyboard(.interactively)
            .presentationDetents(presentationDetents)
            .presentationDragIndicator(.visible)
            .interactiveDismissDisabled(isSaving)
            .task { isFocused = true }
        case .yearly:
            yearlySystemPickerSheet
        }
    }

    private var dailyGoalForm: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            XMSettingsSection("单位：分钟") {
                XMSettingsGroup(presentation: .singleItem) {
                TextField("请输入目标值", text: $value)
                    .font(AppTypography.body)
                    .keyboardType(.numberPad)
                    .focused($isFocused)
                    .disabled(isSaving)
                    .frame(minHeight: XMSettingsPageLayout.inputMinHeight)
                }
            }

            goalEditorError
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.bottom, Spacing.contentEdge)
    }

    private func cancelDailyGoal() {
        guard !isSaving else { return }
        isFocused = false
        onCancel()
    }

    private func confirmDailyGoal() {
        isFocused = false
        onConfirm()
    }

    private var yearlySystemPickerSheet: some View {
        NavigationStack {
            yearlyGoalPicker
                .navigationTitle(item.mode.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(action: onCancel) {
                            Image(systemName: "xmark")
                                .font(.body.weight(.semibold))
                        }
                            .tint(Color.textSecondary)
                            .disabled(isSaving)
                            .accessibilityLabel("关闭")
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        XMSheetConfirmationAction(
                            isDisabled: false,
                            isConfirming: isSaving,
                            action: onConfirm
                        )
                    }
                }
        }
        .presentationDetents(presentationDetents)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isSaving)
    }

    private var yearlyGoalPicker: some View {
        VStack(spacing: Spacing.base) {
            Picker("年度阅读目标", selection: yearlyGoalBinding) {
                ForEach(ReadingDashboardViewModel.yearlyGoalRange, id: \.self) { count in
                    Text("\(count) 本")
                        .font(AppTypography.title3)
                        .tag(count)
                }
            }
            .pickerStyle(.wheel)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            .disabled(isSaving)
            .accessibilityLabel("年度阅读目标")
            .accessibilityValue("\(yearlyGoalValue) 本")
            .accessibilityHint("上下轻扫调整")

            goalEditorError
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.vertical, Spacing.cozy)
        .background(Color.surfaceSheet)
    }

    @ViewBuilder
    private var goalEditorError: some View {
        if let errorMessage, !errorMessage.isEmpty {
            Text(errorMessage)
                .font(AppTypography.caption)
                .foregroundStyle(Color.feedbackError)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("错误：\(errorMessage)")
        }
    }

    private var yearlyGoalBinding: Binding<Int> {
        Binding(
            get: { yearlyGoalValue },
            set: { value = String(Self.clampedYearlyGoal($0)) }
        )
    }

    private var yearlyGoalValue: Int {
        Self.clampedYearlyGoal(Int(value) ?? ReadingDashboardViewModel.yearlyGoalRange.lowerBound)
    }

    private var presentationDetents: Set<PresentationDetent> {
        guard !dynamicTypeSize.isAccessibilitySize else { return [.large] }
        switch item.mode {
        case .daily:
            return [.medium]
        case .yearly:
            return [.height(Layout.yearlyRegularPresentationHeight)]
        }
    }

    /// 将外部草稿收敛到年度滚轮可表达的业务范围，避免旧数据导致 Picker 无选中项。
    private static func clampedYearlyGoal(_ value: Int) -> Int {
        min(
            max(value, ReadingDashboardViewModel.yearlyGoalRange.lowerBound),
            ReadingDashboardViewModel.yearlyGoalRange.upperBound
        )
    }
}
