/**
 * [INPUT]: 依赖 AIConfigurationViewModel 提供 Prompt 草稿，依赖 XMSystemAlert 与当前设置页设计组件承接确认交互
 * [OUTPUT]: 对外提供 AIConfigurationPromptEditSheet，编辑单类 System/User Prompt 并支持恢复 Android 同源默认值
 * [POS]: Views/Personal/Sheets 的 AI Prompt 业务 Sheet，被 AIConfigurationView 通过 sheet(item:) 呈现
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 单类 Prompt 编辑 Sheet；只有“保存”会把本地文本回写页面配置草稿。
struct AIConfigurationPromptEditSheet: View {
    let kind: AIPromptKind
    @Bindable var viewModel: AIConfigurationViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var systemPrompt: String
    @State private var userPrompt: String
    @State private var activeAlert: PromptEditAlert?

    /// 从页面当前草稿建立 Sheet 自有编辑副本，取消时不会污染待保存配置。
    init(kind: AIPromptKind, viewModel: AIConfigurationViewModel) {
        self.kind = kind
        self.viewModel = viewModel
        let template = viewModel.configuration.prompts.template(for: kind)
        _systemPrompt = State(initialValue: template.system)
        _userPrompt = State(initialValue: template.user)
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.section) {
                    promptEditor(
                        title: "System Prompt",
                        hint: "定义角色、输出结构与边界。",
                        text: $systemPrompt
                    )
                    promptEditor(
                        title: "User Prompt",
                        hint: "可保留当前默认模板中的中文占位符。",
                        text: $userPrompt
                    )

                    Button(role: .destructive) {
                        activeAlert = .reset
                    } label: {
                        Label("恢复此项默认 Prompt", systemImage: "arrow.counterclockwise")
                            .font(AppTypography.subheadlineSemibold)
                            .frame(maxWidth: .infinity)
                            .frame(height: Spacing.actionReserved)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.vertical, Spacing.section)
            }
            .scrollDismissesKeyboard(.interactively)
            .scrollIndicators(.hidden)
            .background(Color.surfaceSheet.ignoresSafeArea())
            .navigationTitle(kind.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("取消", action: requestDismiss)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("保存", action: save)
                        .disabled(!canSave)
                }
            }
        }
        .interactiveDismissDisabled(hasChanges)
        .xmSystemAlert(item: $activeAlert, descriptor: alertDescriptor)
    }

    private var initialTemplate: AIPromptTemplate {
        viewModel.configuration.prompts.template(for: kind)
    }

    private var hasChanges: Bool {
        systemPrompt != initialTemplate.system || userPrompt != initialTemplate.user
    }

    private var canSave: Bool {
        !systemPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !userPrompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && hasChanges
    }

    private func promptEditor(
        title: String,
        hint: String,
        text: Binding<String>
    ) -> some View {
        XMSettingsGroupCard {
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                Text(title)
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(Color.textPrimary)
                Text(hint)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)

                TextEditor(text: text)
                    .font(AppTypography.body)
                    .foregroundStyle(Color.textPrimary)
                    .textInputAutocapitalization(.sentences)
                    .autocorrectionDisabled(false)
                    .scrollContentBackground(.hidden)
                    .padding(Spacing.cozy)
                    .frame(minHeight: AIConfigurationPromptLayout.editorHeight)
                    .background(
                        Color.surfaceNested,
                        in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                    )
            }
            .padding(Spacing.contentEdge)
        }
    }

    private func requestDismiss() {
        if hasChanges {
            activeAlert = .discard
        } else {
            dismiss()
        }
    }

    private func save() {
        guard canSave else { return }
        viewModel.updatePrompt(
            AIPromptTemplate(system: systemPrompt, user: userPrompt),
            for: kind
        )
        dismiss()
    }

    private func restoreDefault() {
        let template = AIPromptConfiguration.androidAlignedDefault.template(for: kind)
        systemPrompt = template.system
        userPrompt = template.user
    }

    private func alertDescriptor(_ alert: PromptEditAlert) -> XMSystemAlertDescriptor {
        switch alert {
        case .discard:
            XMSystemAlertDescriptor(
                title: "放弃 Prompt 修改？",
                message: "本次尚未保存的文本会丢失。",
                actions: [
                    XMSystemAlertAction(title: "继续编辑", role: .cancel) { },
                    XMSystemAlertAction(title: "放弃", role: .destructive) { dismiss() },
                ]
            )
        case .reset:
            XMSystemAlertDescriptor(
                title: "恢复默认 Prompt？",
                message: "当前编辑内容会替换为 Android 同源默认模板。",
                actions: [
                    XMSystemAlertAction(title: "取消", role: .cancel) { },
                    XMSystemAlertAction(title: "恢复默认") { restoreDefault() },
                ]
            )
        }
    }
}

/// Prompt Sheet 的互斥中心弹窗状态。
private enum PromptEditAlert: String, Identifiable {
    case discard
    case reset

    var id: String { rawValue }
}

private enum AIConfigurationPromptLayout {
    static let editorHeight: CGFloat = 220
}
