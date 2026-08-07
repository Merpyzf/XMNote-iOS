/**
 * [INPUT]: 依赖 RepositoryContainer 注入 AIRepositoryProtocol，依赖 AIConfigurationViewModel、项目设置卡片与统一反馈组件
 * [OUTPUT]: 对外提供 AIConfigurationView，承载供应商、固定 Base URL、模型、Keychain 密钥和三类 Prompt 配置入口
 * [POS]: Views/Personal 的 AI 配置页面壳层，被 PersonalRoute.aiConfiguration 导航消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// AI 配置页严格复用当前设置页卡片、字体、颜色与导航结构，不引入独立视觉语言。
struct AIConfigurationView: View {
    @Environment(RepositoryContainer.self) private var repositories
    @Environment(XMToastCenter.self) private var toastCenter

    @State private var viewModel: AIConfigurationViewModel?
    @State private var bootstrapLoadingGate = LoadingGate()

    var body: some View {
        ZStack {
            Color.surfacePage.ignoresSafeArea()

            if let viewModel {
                AIConfigurationContentView(viewModel: viewModel)
            } else if bootstrapLoadingGate.isVisible {
                LoadingStateView("正在读取 AI 配置…", style: .card)
            }
        }
        .navigationTitle("AI 配置")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard viewModel == nil else { return }
            bootstrapLoadingGate.update(intent: .read)
            let model = AIConfigurationViewModel(repository: repositories.aiRepository)
            viewModel = model
            await model.load()
            bootstrapLoadingGate.update(intent: .none)
        }
        .onChange(of: viewModel?.feedback) { _, feedback in
            guard let feedback else { return }
            switch feedback.role {
            case .success:
                toastCenter.success(feedback.message)
            case .error:
                toastCenter.error(feedback.message)
            }
            viewModel?.consumeFeedback()
        }
        .onDisappear {
            bootstrapLoadingGate.hideImmediately()
        }
    }
}

/// 配置加载后的页面内容，集中承接单一 Prompt Sheet 与密钥删除确认。
private struct AIConfigurationContentView: View {
    @Bindable var viewModel: AIConfigurationViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activePromptKind: AIPromptKind?
    @State private var showsDeleteKeyAlert = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.section) {
                basicConfigurationSection
                promptSection
                privacyNotice
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.top, Spacing.section)
            .padding(.bottom, Spacing.contentEdge)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .background(Color.surfacePage)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(viewModel.isSaving ? "保存中…" : "保存") {
                    Task { await viewModel.save() }
                }
                .disabled(!viewModel.canSave)
            }
        }
        .sheet(item: $activePromptKind) { kind in
            AIConfigurationPromptEditSheet(kind: kind, viewModel: viewModel)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .xmSystemAlert(
            isPresented: $showsDeleteKeyAlert,
            descriptor: deleteKeyAlertDescriptor
        )
        .overlay {
            if viewModel.isSaving {
                Color.overlay.ignoresSafeArea()
                LoadingStateView("正在保存 AI 配置…", style: .card)
                    .transition(.opacity)
            }
        }
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.18),
            value: viewModel.configuration.provider
        )
    }

    private var basicConfigurationSection: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            sectionTitle("模型服务")

            XMSettingsGroupCard {
                VStack(spacing: Spacing.none) {
                    Toggle("启用 AI 功能", isOn: $viewModel.configuration.isEnabled)
                        .font(AppTypography.subheadline)
                        .tint(Color.brand)
                        .frame(minHeight: AIConfigurationLayout.rowHeight)

                    settingsDivider
                    providerPicker
                    settingsDivider
                    modelPicker
                    settingsDivider
                    baseURLRow
                    settingsDivider
                    apiKeyRow
                }
                .padding(.horizontal, Spacing.contentEdge)
            }

            if let validationMessage = viewModel.validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.feedbackWarning)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
            }
        }
    }

    private var promptSection: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            sectionTitle("提示词")

            XMSettingsGroupCard {
                VStack(spacing: Spacing.none) {
                    ForEach(AIPromptKind.allCases) { kind in
                        Button {
                            activePromptKind = kind
                        } label: {
                            HStack(spacing: Spacing.base) {
                                Image(systemName: kind.systemImage)
                                    .font(AppTypography.bodyMedium)
                                    .foregroundStyle(Color.iconSecondary)
                                    .frame(width: Spacing.section)

                                VStack(alignment: .leading, spacing: Spacing.compact) {
                                    Text(kind.title)
                                        .font(AppTypography.subheadlineSemibold)
                                        .foregroundStyle(Color.textPrimary)
                                    Text(kind.subtitle)
                                        .font(AppTypography.caption)
                                        .foregroundStyle(Color.textSecondary)
                                        .lineLimit(2)
                                }

                                Spacer(minLength: Spacing.base)

                                Image(systemName: "chevron.right")
                                    .font(AppTypography.captionSemibold)
                                    .foregroundStyle(Color.textHint)
                            }
                            .frame(minHeight: AIConfigurationLayout.promptRowHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("编辑 System Prompt 与 User Prompt")

                        if kind != AIPromptKind.allCases.last {
                            settingsDivider
                                .padding(.leading, Spacing.section + Spacing.base)
                        }
                    }
                }
                .padding(.horizontal, Spacing.contentEdge)
            }
        }
    }

    private var privacyNotice: some View {
        Label {
            Text("API Key 仅保存在本机 Keychain，不写入数据库、UserDefaults 或备份。模型请求会直接发送到所选服务商。")
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: "lock.shield")
                .foregroundStyle(Color.iconSecondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var providerPicker: some View {
        HStack(spacing: Spacing.base) {
            Text("服务商")
                .font(AppTypography.subheadline)
                .foregroundStyle(Color.textPrimary)
            Spacer(minLength: Spacing.base)
            Picker("服务商", selection: providerBinding) {
                ForEach(AIProvider.allCases) { provider in
                    Text(provider.displayName).tag(provider)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .frame(minHeight: AIConfigurationLayout.rowHeight)
    }

    private var modelPicker: some View {
        HStack(spacing: Spacing.base) {
            Text("模型")
                .font(AppTypography.subheadline)
                .foregroundStyle(Color.textPrimary)
            Spacer(minLength: Spacing.base)
            Picker("模型", selection: modelBinding) {
                ForEach(viewModel.selectedProvider.modelOptions) { model in
                    Text(model.title).tag(model.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
        }
        .frame(minHeight: AIConfigurationLayout.rowHeight)
    }

    private var baseURLRow: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            Text("Base URL")
                .font(AppTypography.captionMedium)
                .foregroundStyle(Color.textSecondary)
            Text(viewModel.selectedBaseURL)
                .font(AppTypography.subheadline)
                .foregroundStyle(Color.textPrimary)
                .textSelection(.enabled)
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: AIConfigurationLayout.rowHeight, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    private var apiKeyRow: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            HStack(spacing: Spacing.base) {
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    Text("API Key")
                        .font(AppTypography.captionMedium)
                        .foregroundStyle(Color.textSecondary)
                    Text(viewModel.selectedProviderHasStoredKey ? "Keychain 中已有密钥" : "尚未配置")
                        .font(AppTypography.caption)
                        .foregroundStyle(
                            viewModel.selectedProviderHasStoredKey
                                ? Color.feedbackSuccess
                                : Color.textHint
                        )
                }

                Spacer(minLength: Spacing.base)

                if viewModel.selectedProviderHasStoredKey {
                    Button("移除", role: .destructive) {
                        showsDeleteKeyAlert = true
                    }
                    .font(AppTypography.captionMedium)
                    .disabled(viewModel.isSaving)
                }
            }

            SecureField("输入新的 \(viewModel.selectedProvider.displayName) API Key", text: $viewModel.apiKeyDraft)
                .font(AppTypography.body)
                .privacySensitive()
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .padding(.horizontal, Spacing.base)
                .frame(minHeight: AIConfigurationLayout.inputHeight)
                .background(
                    Color.surfaceNested,
                    in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                )

            Text(viewModel.selectedProviderHasStoredKey ? "留空会保留现有密钥；输入内容只用于本次更新。" : "密钥保存后不会再次回填显示。")
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, Spacing.cozy)
    }

    private var providerBinding: Binding<AIProvider> {
        Binding(
            get: { viewModel.selectedProvider },
            set: { viewModel.selectProvider($0) }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { viewModel.selectedModelID },
            set: { viewModel.selectModel($0) }
        )
    }

    private var settingsDivider: some View {
        Divider()
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(AppTypography.captionMedium)
            .foregroundStyle(Color.textSecondary)
            .padding(.horizontal, Spacing.contentEdge)
    }

    private var deleteKeyAlertDescriptor: XMSystemAlertDescriptor {
        XMSystemAlertDescriptor(
            title: "移除 \(viewModel.selectedProvider.displayName) API Key？",
            message: "密钥会从本机 Keychain 永久移除，AI 功能同时关闭。",
            actions: [
                XMSystemAlertAction(title: "取消", role: .cancel) { },
                XMSystemAlertAction(title: "移除", role: .destructive) {
                    Task { await viewModel.deleteSelectedProviderKey() }
                },
            ]
        )
    }
}

/// AI 设置页局部布局只复用现有间距并固定最小触控高度，不定义新的视觉 token。
private enum AIConfigurationLayout {
    static let rowHeight: CGFloat = 52
    static let promptRowHeight: CGFloat = 64
    static let inputHeight: CGFloat = 48
}

private extension AIPromptKind {
    var systemImage: String {
        switch self {
        case .noteExplanation:
            "sparkles"
        case .wordLookup:
            "text.magnifyingglass"
        case .autoTag:
            "tag"
        }
    }
}

#Preview {
    NavigationStack {
        AIConfigurationView()
    }
    .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
    .environment(XMToastCenter())
}
