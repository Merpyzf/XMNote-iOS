/**
 * [INPUT]: 依赖 AITextResultViewModel/AIAutoTagViewModel、AIRepositoryProtocol、系统 Sheet/Liquid Glass、LoadingGate 与现有反馈组件
 * [OUTPUT]: 对外提供 AITextResultSheet 与 AIAutoTagSheet，承接内容优先的流式释义、文字呼吸等待态、模型切换、编辑器请求交接和标签确认写回
 * [POS]: Views/Content/Sheets 的 AI 业务 Sheet，被通用 viewer 及单页详情入口复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 流式 AI 释义 Sheet；整条书摘释义可由用户明确交给既有编辑器继续确认。
struct AITextResultSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(XMToastCenter.self) private var toastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var viewModel: AITextResultViewModel
    @State private var loadingGate = LoadingGate()
    @State private var markdownInteractionController = AIMarkdownInteractionController()
    @State private var hasStartedGeneration = false

    private let onIdeaEditorRequested: @MainActor (AIExplanationIdeaEditRequest) -> Void

    /// 用稳定 presentation 建立状态源；网络只在 Sheet 出现后启动。
    init(
        presentation: AITextResultPresentation,
        repository: any AIRepositoryProtocol,
        onIdeaEditorRequested: @escaping @MainActor (AIExplanationIdeaEditRequest) -> Void = { _ in }
    ) {
        _viewModel = State(
            initialValue: AITextResultViewModel(
                request: presentation.request,
                repository: repository
            )
        )
        self.onIdeaEditorRequested = onIdeaEditorRequested
    }

    var body: some View {
        ScrollView {
            resultContent
                .animation(
                    reduceMotion ? nil : .smooth(duration: 0.18),
                    value: viewModel.content.isEmpty
                )
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.top, Spacing.cozy)
                .padding(.bottom, Spacing.double)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.always)
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .scrollPosition($markdownInteractionController.scrollPosition)
        .safeAreaBar(edge: .top, spacing: Spacing.none) {
            topChrome
        }
        .onScrollGeometryChange(for: Bool.self) { geometry in
            let distanceFromBottom = geometry.contentSize.height
                - geometry.contentOffset.y
                - geometry.containerSize.height
            return distanceFromBottom <= Spacing.double
        } action: { _, isAtBottom in
            markdownInteractionController.updateIsAtBottom(
                isAtBottom,
                isPositionedByUser: markdownInteractionController.scrollPosition.isPositionedByUser
            )
        }
        .onChange(of: markdownInteractionController.scrollPosition.isPositionedByUser) { _, newValue in
            markdownInteractionController.updateIsPositionedByUser(newValue)
        }
        .interactiveDismissDisabled(viewModel.isPreparingIdeaEditor)
        .onAppear {
            markdownInteractionController.configure(
                toastCenter: toastCenter,
                reducesMotion: reduceMotion
            )
            guard !hasStartedGeneration else { return }
            hasStartedGeneration = true
            viewModel.startGeneration()
            syncLoadingGate()
        }
        .onChange(of: viewModel.isGenerating) { wasGenerating, isGenerating in
            if !wasGenerating, isGenerating {
                markdownInteractionController.resetForNewGeneration()
            }
            syncLoadingGate()
        }
        .onChange(of: viewModel.modelSwitchErrorMessage) { _, message in
            guard let message else { return }
            toastCenter.error(message)
            viewModel.consumeModelSwitchError()
        }
        .onChange(of: reduceMotion) { _, newValue in
            markdownInteractionController.updateReduceMotion(newValue)
        }
        .onDisappear {
            viewModel.cancelGeneration()
            markdownInteractionController.discardPendingTableExport()
            loadingGate.hideImmediately()
        }
        .sheet(
            item: $markdownInteractionController.pendingTableExport,
            onDismiss: markdownInteractionController.discardPendingTableExport
        ) { export in
            XMActivityShareSheet(activityItems: [export.fileURL])
                .presentationDetents([.medium, .large])
                .onDisappear {
                    export.discard()
                }
        }
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.2),
            value: viewModel.errorMessage
        )
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.18),
            value: viewModel.hasCompletedSuccessfully
        )
    }

    private var topChrome: some View {
        ZStack {
            HStack {
                Color.clear
                    .frame(width: Spacing.actionReserved, height: Spacing.actionReserved)

                Spacer(minLength: Spacing.none)

                closeButton
            }
            .frame(minHeight: XMSettingsSheetLayout.chromeMinHeight)

            VStack(spacing: Spacing.micro) {
                Text("AI 释义")
                    .font(AppTypography.headlineSemibold)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)

                modelMenu
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, XMSettingsSheetLayout.titleHorizontalReserve)
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.top, Spacing.double)
        .padding(.bottom, Spacing.section)
    }

    private var modelMenu: some View {
        Menu {
            ForEach(viewModel.availableProviders) { provider in
                Section(provider.displayName) {
                    ForEach(provider.modelOptions) { model in
                        Button {
                            viewModel.switchModel(provider: provider, modelID: model.id)
                        } label: {
                            if viewModel.isCurrentModel(provider: provider, modelID: model.id) {
                                Label(model.title, systemImage: "checkmark")
                            } else {
                                Text(model.title)
                            }
                        }
                    }
                }
            }
        } label: {
            Text(modelMenuTitle)
                .font(AppTypography.caption2)
                .foregroundStyle(Color.textSecondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .contentShape(.interaction, ModelMenuHitShape())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.availableProviders.isEmpty || viewModel.isSwitchingModel)
        .accessibilityLabel("当前模型，\(modelMenuTitle)")
        .accessibilityHint("打开菜单切换 AI 模型")
    }

    private var modelMenuTitle: String {
        if viewModel.isSwitchingModel {
            return "正在切换模型…"
        }
        return viewModel.modelDescription.isEmpty ? "正在连接模型…" : viewModel.modelDescription
    }

    private var closeButton: some View {
        Button {
            viewModel.cancelGeneration()
            dismiss()
        } label: {
            TopBarActionIcon(
                systemName: "xmark",
                iconSize: 13,
                containerSize: XMSettingsSheetLayout.closeVisualSize,
                weight: .bold,
                foregroundColor: .textSecondary
            )
            .background(Color.controlFillSecondary.opacity(0.82), in: Circle())
            .frame(width: Spacing.actionReserved, height: Spacing.actionReserved)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(viewModel.isPreparingIdeaEditor)
        .accessibilityLabel("关闭")
    }

    @ViewBuilder
    private var resultContent: some View {
        if !viewModel.content.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.section) {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    AIMarkdownResultView(
                        markdown: viewModel.content,
                        isStreaming: viewModel.isGenerating,
                        interactionController: markdownInteractionController
                    )

                    if viewModel.hasCompletedSuccessfully {
                        aiDisclosure
                            .transition(.opacity)
                    }
                }

                if let errorMessage = viewModel.errorMessage, !viewModel.isGenerating {
                    resultError(message: errorMessage)
                }

                if viewModel.canRetryGeneration {
                    retryButton
                }

                if viewModel.hasCompletedSuccessfully,
                   viewModel.request.noteIDForIdeaEditor != nil {
                    recordToIdeaAction
                        .transition(.opacity)
                }
            }
            .transition(.opacity)
        } else if let errorMessage = viewModel.errorMessage {
            VStack(alignment: .leading, spacing: Spacing.base) {
                resultError(message: errorMessage)
                retryButton
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
        } else if loadingGate.isVisible {
            AIGenerationWaitingView(reduceMotion: reduceMotion)
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
        } else {
            Color.clear.frame(minHeight: Spacing.double)
        }
    }

    private func resultError(message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(AppTypography.footnote)
            .foregroundStyle(Color.feedbackError)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var retryButton: some View {
        Button("重新生成") {
            viewModel.startGeneration()
        }
        .font(AppTypography.subheadlineMedium)
        .buttonStyle(.bordered)
    }

    private var aiDisclosure: some View {
        Label("AI 生成内容，仅供参考", systemImage: "sparkles")
            .font(AppTypography.caption)
            .foregroundStyle(Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .trailing)
    }

    private var recordToIdeaAction: some View {
        HStack(spacing: Spacing.none) {
            Spacer(minLength: Spacing.none)

            Button {
                requestIdeaEditor()
            } label: {
                Text(viewModel.isPreparingIdeaEditor ? "正在打开…" : "记录到想法")
                    .font(AppTypography.subheadlineMedium)
                    .foregroundStyle(Color.textPrimary)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.regular)
            .frame(minHeight: Spacing.actionReserved)
            .contentShape(.interaction, Capsule())
            .disabled(!viewModel.canOpenIdeaEditor)
            .accessibilityHint("打开书摘编辑器，将本次 AI 释义作为未保存想法继续编辑")

            Spacer(minLength: Spacing.none)
        }
        .frame(maxWidth: .infinity)
    }

    /// 转换任务继承当前主执行器；仅在请求准备成功后交给来源页，并由 Sheet 自己触发退场。
    private func requestIdeaEditor() {
        Task {
            guard let request = await viewModel.prepareIdeaEditorRequest() else { return }
            onIdeaEditorRequested(request)
            dismiss()
        }
    }

    private func syncLoadingGate() {
        let shouldShow = viewModel.isGenerating && viewModel.content.isEmpty
        loadingGate.update(intent: shouldShow ? .read : .none)
    }
}

/// 首个可见 token 返回前，以低干扰文字呼吸表达生成中的页面私有等待态。
private struct AIGenerationWaitingView: View {
    let reduceMotion: Bool

    var body: some View {
        if reduceMotion {
            waitingText
                .opacity(0.82)
        } else {
            PhaseAnimator([0.90, 0.55]) { opacity in
                waitingText
                    .opacity(opacity)
            } animation: { _ in
                .easeInOut(duration: 0.7)
            }
        }
    }

    private var waitingText: some View {
        Text("正在生成…")
            .font(AppTypography.footnote)
            .foregroundStyle(Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("正在生成 AI 释义")
    }
}

/// 模型副标题的交互形状只向下补足命中高度，避免热区改变视觉排版或覆盖标题。
private struct ModelMenuHitShape: Shape {
    private let minimumSize = Spacing.actionReserved

    /// 以文本顶部为锚点生成至少 44pt 的命中矩形，保持短文本可触达且不扩大布局尺寸。
    func path(in rect: CGRect) -> Path {
        let width = max(rect.width, minimumSize)
        let height = max(rect.height, minimumSize)
        let hitRect = CGRect(
            x: rect.midX - width / 2,
            y: rect.minY,
            width: width,
            height: height
        )
        return Path(hitRect)
    }
}

/// 自动标签 Sheet，保留用户对建议的最终选择权并在确认后刷新来源详情。
struct AIAutoTagSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(XMToastCenter.self) private var toastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var viewModel: AIAutoTagViewModel
    @State private var loadingGate = LoadingGate()

    private let onTagsApplied: @MainActor () async -> Void

    /// 用稳定书摘主键建立状态源；标签建议只在 Sheet 出现后请求。
    init(
        presentation: AIAutoTagPresentation,
        repository: any AIRepositoryProtocol,
        onTagsApplied: @escaping @MainActor () async -> Void = { }
    ) {
        _viewModel = State(
            initialValue: AIAutoTagViewModel(
                noteID: presentation.noteID,
                bookTitle: presentation.bookTitle,
                repository: repository
            )
        )
        self.onTagsApplied = onTagsApplied
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color.surfaceSheet.ignoresSafeArea()

                ScrollView {
                    VStack(alignment: .leading, spacing: Spacing.section) {
                        ContentViewerHeroCard(
                            title: normalizedBookTitle,
                            subtitle: "自动标签"
                        ) {
                            Text("AI 最多推荐 3 个标签；已有标签会复用，确认前可以自由选择。")
                                .font(AppTypography.caption)
                                .foregroundStyle(Color.textSecondary)
                        }

                        suggestionContent
                    }
                    .padding(.horizontal, Spacing.screenEdge)
                    .padding(.vertical, Spacing.section)
                    .safeAreaPadding(.bottom, Spacing.double)
                }
                .scrollIndicators(.hidden)

                if viewModel.isApplying {
                    Color.overlay.ignoresSafeArea()
                    LoadingStateView("正在应用标签…", style: .card)
                        .transition(.opacity)
                }
            }
            .navigationTitle("自动标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") {
                        viewModel.cancelLoading()
                        dismiss()
                    }
                    .disabled(viewModel.isApplying)
                }
            }
            .safeAreaInset(edge: .bottom, spacing: Spacing.none) {
                applyActionBar
            }
        }
        .interactiveDismissDisabled(viewModel.isApplying)
        .onAppear {
            viewModel.startLoading()
            syncLoadingGate()
        }
        .onChange(of: viewModel.isLoading) { _, _ in
            syncLoadingGate()
        }
        .onDisappear {
            viewModel.cancelLoading()
            loadingGate.hideImmediately()
        }
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.2),
            value: viewModel.suggestions
        )
    }

    @ViewBuilder
    private var suggestionContent: some View {
        if !viewModel.suggestions.isEmpty {
            XMSettingsGroupCard {
                VStack(spacing: Spacing.none) {
                    ForEach(viewModel.suggestions) { suggestion in
                        Button {
                            viewModel.toggleSuggestion(id: suggestion.id)
                        } label: {
                            AIAutoTagSuggestionRow(suggestion: suggestion)
                        }
                        .buttonStyle(.plain)

                        if suggestion.id != viewModel.suggestions.last?.id {
                            Divider().padding(.leading, Spacing.double)
                        }
                    }
                }
                .padding(.horizontal, Spacing.contentEdge)
            }
            .transition(.opacity)
        } else if let errorMessage = viewModel.errorMessage {
            VStack(spacing: Spacing.base) {
                viewerMessageCard(text: errorMessage)
                Button("重新推荐") {
                    viewModel.startLoading()
                }
                .buttonStyle(.bordered)
            }
            .transition(.opacity)
        } else if loadingGate.isVisible {
            LoadingStateView("正在分析书摘…", style: .card)
                .frame(maxWidth: .infinity)
                .transition(.opacity)
        } else if !viewModel.isLoading {
            viewerMessageCard(text: "当前书摘没有适合长期知识管理的标签建议。")
                .transition(.opacity)
        } else {
            Color.clear.frame(minHeight: Spacing.double)
        }
    }

    private var applyActionBar: some View {
        VStack(spacing: Spacing.none) {
            Divider()
            Button {
                applyTags()
            } label: {
                Text(viewModel.isApplying ? "应用中…" : "应用所选标签")
                    .font(AppTypography.subheadlineSemibold)
                    .frame(maxWidth: .infinity)
                    .frame(height: Spacing.actionReserved)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.brand)
            .disabled(!viewModel.hasSelectedSuggestion || viewModel.isLoading || viewModel.isApplying)
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.cozy)
        }
        .background(Color.surfaceSheet)
    }

    private var normalizedBookTitle: String {
        let title = viewModel.bookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "当前书摘" : title
    }

    /// 写入成功后强刷来源详情，标签 rail 与列表观察流会同步获得数据库真实结果。
    private func applyTags() {
        Task {
            guard await viewModel.applySelectedSuggestions() else { return }
            await onTagsApplied()
            toastCenter.success("标签已更新")
            dismiss()
        }
    }

    private func syncLoadingGate() {
        loadingGate.update(intent: viewModel.isLoading ? .read : .none)
    }
}

/// 单条自动标签候选，复用设置行密度并明确区分已有与新建标签。
private struct AIAutoTagSuggestionRow: View {
    let suggestion: AIAutoTagSuggestion

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            Image(systemName: suggestion.isSelected ? "checkmark.circle.fill" : "circle")
                .font(AppTypography.title3)
                .foregroundStyle(suggestion.isSelected ? Color.brand : Color.iconSecondary)

            VStack(alignment: .leading, spacing: Spacing.compact) {
                HStack(spacing: Spacing.cozy) {
                    Text(suggestion.name)
                        .font(AppTypography.subheadlineSemibold)
                        .foregroundStyle(Color.textPrimary)
                    Text(suggestion.isExisting ? "已有" : "新标签")
                        .font(AppTypography.caption2Medium)
                        .foregroundStyle(suggestion.isExisting ? Color.feedbackSuccess : Color.textSecondary)
                        .padding(.horizontal, Spacing.cozy)
                        .padding(.vertical, Spacing.compact)
                        .background(Color.tagBackground, in: Capsule())
                }

                if !suggestion.reason.isEmpty {
                    Text(suggestion.reason)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: Spacing.none)
        }
        .padding(.vertical, Spacing.base)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(suggestion.name)，\(suggestion.isExisting ? "已有标签" : "新标签")")
        .accessibilityValue(suggestion.isSelected ? "已选择" : "未选择")
        .accessibilityHint("双击切换选择")
        .accessibilityAddTraits(suggestion.isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
