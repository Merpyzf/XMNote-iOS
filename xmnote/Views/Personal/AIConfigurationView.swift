/**
 * [INPUT]: 依赖 RepositoryContainer 注入 AIRepositoryProtocol，依赖 AIConfigurationViewModel、设置分组卡片与统一反馈组件
 * [OUTPUT]: 对外提供 AIConfigurationView，承载模型服务、按需展开的 API 凭证管理和三类 Prompt 配置入口
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
    @State private var isEditingAPIKey = false
    @FocusState private var isAPIKeyFocused: Bool

    var body: some View {
        XMSettingsPage {
            modelServiceSection
            credentialsSection
            promptSection
        }
        .scrollDismissesKeyboard(.interactively)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(viewModel.isSaving ? "保存中…" : "保存") {
                    saveConfiguration()
                }
                .tint(Color.brand)
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

    private var modelServiceSection: some View {
        XMSettingsSection("模型服务") {
            XMSettingsGroup(
                horizontalPadding: Spacing.contentEdge,
                verticalPadding: Spacing.none
            ) {
                VStack(spacing: Spacing.none) {
                    Toggle(isOn: $viewModel.configuration.isEnabled) {
                        VStack(alignment: .leading, spacing: Spacing.compact) {
                            Text("启用 AI 功能")
                                .font(AppTypography.subheadlineMedium)
                                .foregroundStyle(Color.textPrimary)

                            Text("用于书摘释义、选词解释与标签推荐")
                                .font(AppTypography.caption)
                                .foregroundStyle(Color.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(Color.brand)
                    .frame(minHeight: XMSettingsPageLayout.detailRowMinHeight)

                    settingsDivider
                    providerPicker
                    settingsDivider
                    modelPicker
                }
            }
        }
    }

    private var credentialsSection: some View {
        XMSettingsSection("访问凭证") {
            XMSettingsGroup(
                presentation: credentialCardPresentation,
                horizontalPadding: Spacing.contentEdge,
                verticalPadding: Spacing.none
            ) {
                VStack(spacing: Spacing.none) {
                    HStack(spacing: Spacing.base) {
                        Text("API Key")
                            .font(AppTypography.subheadlineMedium)
                            .foregroundStyle(Color.textPrimary)

                        Spacer(minLength: Spacing.base)

                        apiKeyTrailingAction
                    }
                    .frame(
                        minHeight: shouldShowAPIKeyInput
                            ? Spacing.actionReserved
                            : XMSettingsPageLayout.detailRowMinHeight
                    )

                    if shouldShowAPIKeyInput {
                        settingsDivider

                        apiKeyInput
                            .padding(.top, Spacing.cozy)
                            .padding(.bottom, Spacing.base)
                            .transition(.opacity)
                    }
                }
                .animation(credentialAnimation, value: shouldShowAPIKeyInput)
            }

            if let validationMessage = viewModel.validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.feedbackWarning)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, Spacing.contentEdge)
                    .transition(.opacity)
            }
        }
    }

    private var promptSection: some View {
        XMSettingsSection("提示词") {
            XMSettingsGroup(
                horizontalPadding: Spacing.contentEdge,
                verticalPadding: Spacing.none
            ) {
                VStack(spacing: Spacing.none) {
                    ForEach(AIPromptKind.allCases) { kind in
                        Button {
                            activePromptKind = kind
                        } label: {
                            HStack(spacing: Spacing.base) {
                                Image(systemName: kind.systemImage)
                                    .font(AppTypography.bodyMedium)
                                    .foregroundStyle(Color.iconSecondary)
                                    .frame(width: XMSettingsPageLayout.iconSlotWidth)
                                    .accessibilityHidden(true)

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
                                    .accessibilityHidden(true)
                            }
                            .frame(minHeight: XMSettingsPageLayout.detailRowMinHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("编辑 System Prompt 与 User Prompt")

                        if kind != AIPromptKind.allCases.last {
                            settingsDivider
                                .padding(.leading, XMSettingsPageLayout.iconSlotWidth + Spacing.base)
                        }
                    }
                }
            }
        }
    }

    private var providerPicker: some View {
        XMSettingsValueMenuRow(
            title: "服务商",
            value: viewModel.selectedProvider.displayName,
            options: AIProvider.allCases,
            selection: viewModel.selectedProvider,
            optionTitle: { $0.displayName },
            optionImage: { _ in nil },
            onSelect: selectProvider
        )
        .frame(minHeight: XMSettingsPageLayout.regularRowMinHeight)
    }

    private var modelPicker: some View {
        XMSettingsValueMenuRow(
            title: "模型",
            value: viewModel.selectedProvider.modelTitle(for: viewModel.selectedModelID),
            options: viewModel.selectedProvider.modelOptions.map(\.id),
            selection: viewModel.selectedModelID,
            optionTitle: { viewModel.selectedProvider.modelTitle(for: $0) },
            optionImage: { _ in nil },
            onSelect: viewModel.selectModel
        )
        .frame(minHeight: XMSettingsPageLayout.regularRowMinHeight)
    }

    private var apiKeyInput: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            SecureField("输入新的 \(viewModel.selectedProvider.displayName) API Key", text: $viewModel.apiKeyDraft)
                .font(AppTypography.subheadline)
                .foregroundStyle(Color.textPrimary)
                .focused($isAPIKeyFocused)
                .privacySensitive()
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .submitLabel(.done)
                .padding(.horizontal, Spacing.base)
                .frame(minHeight: XMSettingsPageLayout.inputMinHeight)
                .background(
                    Color.surfaceNested,
                    in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                )
                .onAppear {
                    guard isEditingAPIKey else { return }
                    isAPIKeyFocused = true
                }

            if viewModel.selectedProviderHasStoredKey {
                Text("保存后将替换当前 API Key")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var apiKeyTrailingAction: some View {
        if viewModel.selectedProviderHasStoredKey, isEditingAPIKey {
            Button("取消") {
                cancelAPIKeyEditing()
            }
            .font(AppTypography.subheadline)
            .foregroundStyle(Color.textPrimary)
            .frame(minHeight: Spacing.actionReserved)
            .disabled(viewModel.isSaving)
        } else if viewModel.selectedProviderHasStoredKey {
            Menu {
                Button {
                    beginAPIKeyEditing()
                } label: {
                    XMMenuLabel("更换密钥", systemImage: "key")
                }

                Button(role: .destructive) {
                    showsDeleteKeyAlert = true
                } label: {
                    Label("移除", systemImage: "trash")
                }
                .tint(Color.feedbackError)
            } label: {
                HStack(spacing: Spacing.compact) {
                    Text("管理")
                        .font(AppTypography.subheadline)
                    Image(systemName: "chevron.down")
                        .font(AppTypography.captionSemibold)
                        .accessibilityHidden(true)
                }
                .foregroundStyle(Color.textPrimary)
                .frame(minHeight: Spacing.actionReserved)
            }
            .xmMenuNeutralTint()
            .disabled(viewModel.isSaving)
            .accessibilityLabel("管理 API Key")
        }
    }

    private var shouldShowAPIKeyInput: Bool {
        !viewModel.selectedProviderHasStoredKey || isEditingAPIKey
    }

    private var credentialCardPresentation: XMSettingsGroupPresentation {
        shouldShowAPIKeyInput || viewModel.validationMessage != nil
            ? .grouped
            : .singleItem
    }

    private var credentialAnimation: Animation? {
        reduceMotion ? nil : .smooth(duration: 0.18)
    }

    private var settingsDivider: some View {
        XMSettingsDivider()
    }

    private func beginAPIKeyEditing() {
        withAnimation(credentialAnimation) {
            isEditingAPIKey = true
        }
    }

    private func selectProvider(_ provider: AIProvider) {
        resetAPIKeyEditing(animated: false)
        viewModel.selectProvider(provider)
    }

    private func cancelAPIKeyEditing() {
        viewModel.apiKeyDraft = ""
        resetAPIKeyEditing(animated: true)
    }

    private func resetAPIKeyEditing(animated: Bool) {
        isAPIKeyFocused = false
        withAnimation(animated ? credentialAnimation : nil) {
            isEditingAPIKey = false
        }
    }

    /// 在主 Actor 上启动现有保存流程；非结构化任务不随页面消失自动取消，并由 ViewModel 防止重复写入。
    private func saveConfiguration() {
        Task { @MainActor in
            guard await viewModel.save() else { return }
            resetAPIKeyEditing(animated: true)
        }
    }

    /// 在主 Actor 上启动密钥删除；非结构化任务不随警告收起自动取消，失败时保留当前凭证界面状态。
    private func deleteSelectedProviderKey() {
        Task { @MainActor in
            guard await viewModel.deleteSelectedProviderKey() else { return }
            resetAPIKeyEditing(animated: true)
        }
    }

    private var deleteKeyAlertDescriptor: XMSystemAlertDescriptor {
        XMSystemAlertDescriptor(
            title: "移除 \(viewModel.selectedProvider.displayName) API Key？",
            message: "移除后，当前服务商将无法继续使用，AI 功能会同时关闭。",
            actions: [
                XMSystemAlertAction(title: "取消", role: .cancel) { },
                XMSystemAlertAction(title: "移除", role: .destructive) {
                    deleteSelectedProviderKey()
                },
            ]
        )
    }
}

private extension AIPromptKind {
    var systemImage: String {
        switch self {
        case .noteExplanation:
            "quote.bubble"
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
