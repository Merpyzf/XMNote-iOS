/**
 * [INPUT]: 依赖 RepositoryContainer 注入 AIRepositoryProtocol，依赖 AIConfigurationViewModel、设置分组卡片与统一反馈组件
 * [OUTPUT]: 对外提供 AIConfigurationView，以统一设置页层级和 Reicon 语义图标承载“AI 助手”的 DeepSeek 模型、API 凭证管理与三类独立 push Prompt 编辑入口
 * [POS]: Views/Personal 的 AI 助手页面壳层，被 PersonalRoute.aiConfiguration 导航消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// AI 助手配置页严格复用当前设置页卡片、字体、颜色与导航结构，不引入独立视觉语言。
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
                LoadingStateView("正在载入…", style: .card)
            }
        }
        .navigationTitle("AI 助手")
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

/// 配置加载后的页面内容，承接独立 Prompt push 入口与密钥删除确认。
private struct AIConfigurationContentView: View {
    @Bindable var viewModel: AIConfigurationViewModel

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsDeleteKeyAlert = false
    @State private var isEditingAPIKey = false
    @State private var hasCompletedInitialAppearance = false
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
                .tint(Color.primaryActionFill)
                .disabled(!viewModel.canSave)
            }
        }
        .xmSystemAlert(
            isPresented: $showsDeleteKeyAlert,
            descriptor: deleteKeyAlertDescriptor
        )
        .overlay {
            Group {
                if viewModel.isSaving {
                    Color.overlay.ignoresSafeArea()
                    LoadingStateView("正在保存…", style: .card)
                        .transition(.opacity)
                }
            }
            .animation(
                reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.18),
                value: viewModel.isSaving
            )
        }
        .onAppear {
            if hasCompletedInitialAppearance {
                Task { await viewModel.refreshPrompts() }
            } else {
                hasCompletedInitialAppearance = true
            }
        }
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
                                .font(SettingsTypography.rowTitle)
                                .foregroundStyle(Color.textPrimary)

                            Text("用于书摘释义、查词和标签推荐")
                                .font(SettingsTypography.rowDescription)
                                .foregroundStyle(Color.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .tint(Color.appTint)
                    .frame(minHeight: XMSettingsPageLayout.detailRowMinHeight)

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
                            .font(SettingsTypography.rowTitle)
                            .foregroundStyle(Color.textPrimary)

                        Spacer(minLength: Spacing.base)

                        apiKeyTrailingAction
                    }
                    .frame(
                        minHeight: shouldShowAPIKeyInput
                            ? InteractionMetrics.minimumTouchTarget
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
        .animation(credentialAnimation, value: viewModel.validationMessage != nil)
                .animation(credentialAnimation, value: shouldShowAPIKeyInput)
            }

            if let validationMessage = viewModel.validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.circle")
                    .font(SettingsTypography.rowDescription)
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
                        NavigationLink(value: AppRoute.personal(.aiPromptEditor(kind))) {
                            HStack(spacing: Spacing.base) {
                                Image(kind.iconResource)
                                    .resizable()
                                    .scaledToFit()
                                    .foregroundStyle(Color.iconSecondary)
                                    .frame(width: 18, height: 18)
                                    .frame(width: XMSettingsPageLayout.iconSlotWidth)
                                    .accessibilityHidden(true)

                                VStack(alignment: .leading, spacing: Spacing.compact) {
                                    Text(kind.title)
                                        .font(SettingsTypography.rowTitle)
                                        .foregroundStyle(Color.textPrimary)
                                    Text(kind.subtitle)
                                        .font(SettingsTypography.rowDescription)
                                        .foregroundStyle(Color.textSecondary)
                                        .lineLimit(2)
                                }

                                Spacer(minLength: Spacing.base)

                                Text(viewModel.isPromptCustomized(kind) ? "自定义" : "默认")
                                    .font(AppTypography.caption)
                                    .foregroundStyle(Color.textSecondary)

                                Image(systemName: "chevron.right")
                                    .font(AppTypography.captionSemibold)
                                    .foregroundStyle(Color.textHint)
                                    .accessibilityHidden(true)
                            }
                            .frame(minHeight: XMSettingsPageLayout.detailRowMinHeight)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .accessibilityHint("编辑用户提示词和系统提示词")

                        if kind != AIPromptKind.allCases.last {
                            settingsDivider
                                .padding(.leading, XMSettingsPageLayout.iconSlotWidth + Spacing.base)
                        }
                    }
                }
            }
        }
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
                .onSubmit { isAPIKeyFocused = false }
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
                Text("保存后替换现有 API Key")
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
            .frame(minHeight: InteractionMetrics.minimumTouchTarget)
            .disabled(viewModel.isSaving)
        } else if viewModel.selectedProviderHasStoredKey {
            Menu {
                Button {
                    beginAPIKeyEditing()
                } label: {
                    XMMenuLabel("更换 API Key", systemImage: "key")
                }

                Button(role: .destructive) {
                    isAPIKeyFocused = false
                    showsDeleteKeyAlert = true
                } label: {
                    Label("移除 API Key", systemImage: "trash")
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
                .frame(minHeight: InteractionMetrics.minimumTouchTarget)
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

    private var credentialAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .smooth(duration: 0.18)
    }

    private var settingsDivider: some View {
        XMSettingsDivider()
    }

    private func beginAPIKeyEditing() {
        withAnimation(credentialAnimation) {
            isEditingAPIKey = true
        }
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
        isAPIKeyFocused = false
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
            message: "移除后，AI 功能将关闭。",
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
    var iconResource: ImageResource {
        switch self {
        case .noteExplanation:
            .reiconQuoteUpOutline
        case .wordLookup:
            .reiconSearchOutline
        case .autoTag:
            .reiconTagOutline
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
