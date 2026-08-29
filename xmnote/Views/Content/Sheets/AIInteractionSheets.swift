/**
 * [INPUT]: 依赖 AITextResultViewModel/AIAutoTagViewModel、AIRepositoryProtocol、AIMarkdownResultView、XMPopupButton、系统 NavigationStack/Toolbar/safeAreaBar、iOS 26 Liquid Glass、LoadingGate、xmMinimumHitTarget 与现有反馈组件
 * [OUTPUT]: 对外提供 AITextResultSheet、AIAutoTagSheet 及可复现等待/空结果/失败状态的业务展示单元；AI 释义承接模型切换、流式结果和编辑器请求，AI 标签承接系统确认与写回生命周期
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
        NavigationStack {
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
            .safeAreaBar(edge: .bottom, spacing: Spacing.none) {
                ideaActionBarHost
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
            .navigationTitle("AI 释义")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    navigationTitleContent
                }

                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        viewModel.cancelGeneration()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .tint(Color.textSecondary)
                    .disabled(viewModel.isPreparingIdeaEditor)
                    .accessibilityLabel("关闭")
                }
            }
        }
        .interactiveDismissDisabled(viewModel.isPreparingIdeaEditor)
        .presentationDetents([.medium, .large])
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
    }

    private var navigationTitleContent: some View {
        VStack(spacing: Spacing.micro) {
            Text("AI 释义")
                .font(AppTypography.headlineSemibold)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)

            navigationModelSubtitle
        }
    }

    @ViewBuilder
    private var navigationModelSubtitle: some View {
        if viewModel.isSwitchingModel {
            navigationSubtitleText("正在切换模型…")
        } else if viewModel.modelTitle.isEmpty {
            navigationSubtitleText("正在连接模型…")
        } else if viewModel.canSelectModel {
            modelMenu
        } else {
            navigationSubtitleText(viewModel.modelTitle)
        }
    }

    private var modelMenu: some View {
        XMPopupButton(
            viewModel.modelTitle,
            font: AppTypography.caption2,
            truncationMode: .middle,
            hitTargetAnchor: .top
        ) {
            ForEach(viewModel.currentProviderModels) { model in
                Button {
                    viewModel.switchCurrentProviderModel(modelID: model.id)
                } label: {
                    XMMenuLabel(
                        model.title,
                        isSelected: viewModel.isCurrentModel(modelID: model.id)
                    )
                }
            }
        }
        .disabled(!viewModel.canSelectModel)
        .accessibilityLabel("当前模型，\(viewModel.modelTitle)")
        .accessibilityHint("打开菜单切换 DeepSeek 模型")
    }

    private func navigationSubtitleText(_ text: String) -> some View {
        Text(text)
            .font(AppTypography.caption2)
            .foregroundStyle(Color.textSecondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }

    @ViewBuilder
    private var ideaActionBarHost: some View {
        Group {
            if shouldShowIdeaAction {
                ideaActionBar
                    .glassEffectTransition(reduceMotion ? .identity : .materialize)
                    .transition(reduceMotion ? .opacity : .identity)
            }
        }
        .animation(ideaActionAppearanceAnimation, value: shouldShowIdeaAction)
    }

    private var ideaActionBar: some View {
        Button(action: requestIdeaEditor) {
            HStack(spacing: Spacing.half) {
                if viewModel.isPreparingIdeaEditor {
                    ProgressView()
                        .controlSize(.small)
                        .tint(Color.primaryActionForeground)
                }

                Text(viewModel.isPreparingIdeaEditor ? "正在打开…" : "记录到想法")
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.extraLarge)
        .tint(Color.appTint)
        .disabled(!viewModel.canOpenIdeaEditor)
        .accessibilityLabel(viewModel.isPreparingIdeaEditor ? "正在打开想法编辑器" : "记录到想法")
        .accessibilityHint("打开书摘编辑器，将本次 AI 释义作为未保存想法继续编辑")
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.vertical, Spacing.cozy)
    }

    private var shouldShowIdeaAction: Bool {
        viewModel.request.noteIDForIdeaEditor != nil
            && viewModel.hasCompletedSuccessfully
            && !viewModel.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !viewModel.isGenerating
            && !viewModel.isSwitchingModel
    }

    private var ideaActionAppearanceAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .smooth(duration: 0.28)
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
                .animation(
                    reduceMotion ? nil : .smooth(duration: 0.18),
                    value: viewModel.hasCompletedSuccessfully
                )

                if let errorMessage = viewModel.errorMessage, !viewModel.isGenerating {
                    resultError(message: errorMessage)
                }

                if viewModel.canRetryGeneration {
                    retryButton
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
        .font(AppTypography.subheadline)
        .buttonStyle(.borderless)
        .tint(Color.appTint)
        .xmMinimumHitTarget(anchor: .leading)
    }

    private var aiDisclosure: some View {
        Text("内容由 AI 生成，请注意甄别")
            .font(AppTypography.caption)
            .foregroundStyle(Color.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .center)
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

/// AI 标签 Sheet，先展示实时 Markdown 输出，完成解析后再交给用户选择并确认写回。
struct AIAutoTagSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(XMToastCenter.self) private var toastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var viewModel: AIAutoTagViewModel
    @State private var loadingGate = LoadingGate()
    @State private var markdownInteractionController = AIMarkdownInteractionController()
    @State private var hasStartedGeneration = false

    private let onApplyWillBegin: @MainActor () -> Void
    private let onApplyFailed: @MainActor () -> Void
    private let onTagsApplied: @MainActor () async -> Void

    /// 用稳定书摘主键建立状态源；标签建议只在 Sheet 出现后请求。
    init(
        presentation: AIAutoTagPresentation,
        repository: any AIRepositoryProtocol,
        onApplyWillBegin: @escaping @MainActor () -> Void = { },
        onApplyFailed: @escaping @MainActor () -> Void = { },
        onTagsApplied: @escaping @MainActor () async -> Void = { }
    ) {
        _viewModel = State(
            initialValue: AIAutoTagViewModel(
                noteID: presentation.noteID,
                bookTitle: presentation.bookTitle,
                repository: repository
            )
        )
        self.onApplyWillBegin = onApplyWillBegin
        self.onApplyFailed = onApplyFailed
        self.onTagsApplied = onTagsApplied
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                suggestionContent
                    .padding(.horizontal, Spacing.screenEdge)
                    .padding(.top, Spacing.cozy)
                    .padding(.bottom, Spacing.double)
            }
            .disabled(viewModel.isApplying)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.always)
            .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
            .scrollPosition($markdownInteractionController.scrollPosition)
            .safeAreaBar(edge: .top, spacing: Spacing.none) {
                Text(normalizedBookTitle)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Spacing.screenEdge)
                    .padding(.vertical, Spacing.cozy)
            }
            .safeAreaBar(edge: .bottom, spacing: Spacing.none) {
                Color.surfaceSheet
                    .frame(height: Spacing.half)
                    .allowsHitTesting(false)
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
            .navigationTitle("AI 标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button {
                        viewModel.cancelLoading()
                        dismiss()
                    } label: {
                        Image(systemName: "xmark")
                    }
                    .tint(Color.textSecondary)
                    .disabled(viewModel.isApplying)
                    .accessibilityLabel("关闭")
                }
                ToolbarItem(placement: .confirmationAction) {
                    XMSheetConfirmationAction(
                        isDisabled: viewModel.phaseKind != .ready || !viewModel.hasSelectedSuggestion,
                        isConfirming: viewModel.isApplying,
                        action: applyTags
                    )
                }
            }
        }
        .interactiveDismissDisabled(viewModel.isApplying)
        .presentationDetents([.medium, .large])
        .onAppear {
            markdownInteractionController.configure(
                toastCenter: toastCenter,
                reducesMotion: reduceMotion
            )
            guard !hasStartedGeneration else { return }
            hasStartedGeneration = true
            viewModel.startLoading()
            syncLoadingGate()
        }
        .onChange(of: viewModel.phaseKind) { previousPhase, currentPhase in
            if !isGenerating(previousPhase), isGenerating(currentPhase) {
                markdownInteractionController.resetForNewGeneration()
            } else if isGenerating(previousPhase), !isGenerating(currentPhase) {
                markdownInteractionController.finishStreamingContent()
            }
            syncLoadingGate()
        }
        .onChange(of: reduceMotion) { _, newValue in
            markdownInteractionController.updateReduceMotion(newValue)
        }
        .onDisappear {
            viewModel.cancelLoading()
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
            value: viewModel.phaseKind
        )
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.18),
            value: viewModel.applyErrorMessage
        )
    }

    @ViewBuilder
    private var suggestionContent: some View {
        switch viewModel.phase {
        case .idle, .connecting:
            if loadingGate.isVisible {
                AIAutoTagWaitingView()
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .transition(.opacity)
            } else {
                Color.clear.frame(minHeight: Spacing.double)
            }
        case .streaming(let content):
            AIMarkdownResultView(
                markdown: content,
                isStreaming: true,
                interactionController: markdownInteractionController
            )
            .transition(.opacity)
        case .ready(let suggestions):
            readyContent(suggestions: suggestions)
                .transition(.opacity)
        case .empty:
            AIAutoTagEmptyStateView(onRetry: viewModel.startLoading)
            .transition(.opacity)
        case .failed(let message, let partialContent):
            AIAutoTagGenerationFailureView(
                message: message,
                partialContent: partialContent,
                interactionController: markdownInteractionController,
                onRetry: viewModel.startLoading
            )
            .transition(.opacity)
        }
    }

    private func readyContent(suggestions: [AIAutoTagSuggestion]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            VStack(spacing: Spacing.none) {
                ForEach(suggestions) { suggestion in
                    Button {
                        viewModel.toggleSuggestion(id: suggestion.id)
                    } label: {
                        AIAutoTagSuggestionRow(suggestion: suggestion)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(suggestion.name)
                    .accessibilityValue(accessibilityValue(for: suggestion))
                    .accessibilityHint("双击切换选择")
                    .accessibilityAddTraits(suggestion.isSelected ? [.isSelected] : [])

                    if suggestion.id != suggestions.last?.id {
                        Divider()
                    }
                }
            }

            if let errorMessage = viewModel.applyErrorMessage {
                generationError(message: errorMessage)
                    .transition(.opacity)
            }

        }
    }

    private func generationError(message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(AppTypography.footnote)
            .foregroundStyle(Color.feedbackError)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var normalizedBookTitle: String {
        let title = viewModel.bookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "当前书摘" : title
    }

    /// 写入成功后强刷来源详情，标签 rail 与列表观察流会同步获得数据库真实结果。
    private func applyTags() {
        Task {
            onApplyWillBegin()
            guard await viewModel.applySelectedSuggestions() else {
                onApplyFailed()
                return
            }
            await onTagsApplied()
            dismiss()
        }
    }

    private func syncLoadingGate() {
        loadingGate.update(intent: viewModel.phaseKind == .connecting ? .read : .none)
    }

    private func isGenerating(_ phase: AIAutoTagViewModel.PhaseKind) -> Bool {
        phase == .connecting || phase == .streaming
    }

    private func accessibilityValue(for suggestion: AIAutoTagSuggestion) -> String {
        let source = suggestion.isExisting ? "直接复用" : "应用后新建"
        let selection = suggestion.isSelected ? "已选择" : "未选择"
        let reason = suggestion.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty
            ? "AI 推荐，\(source)，\(selection)"
            : "AI 推荐，\(source)，\(reason)，\(selection)"
    }
}

/// AI 标签生成失败时仅在确有部分结果时保留正文；完整失败回到局部失败状态，不伪装成 retained-error。
struct AIAutoTagGenerationFailureView: View {
    let message: String
    let partialContent: String?
    let interactionController: AIMarkdownInteractionController
    let onRetry: () -> Void

    @ViewBuilder
    var body: some View {
        if let resolvedPartialContent {
            VStack(alignment: .leading, spacing: Spacing.section) {
                AIMarkdownResultView(
                    markdown: resolvedPartialContent,
                    isStreaming: false,
                    interactionController: interactionController
                )

                XMInlineStatusBanner(
                    "部分结果生成失败",
                    tone: .error,
                    action: XMStateAction(
                        "重新生成",
                        perform: onRetry
                    )
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            XMCompactStateView(
                role: .failure,
                title: "暂时无法生成标签",
                action: XMStateAction("重新生成", perform: onRetry)
            )
            .frame(maxWidth: .infinity)
        }
    }

    private var resolvedPartialContent: String? {
        guard let partialContent else { return nil }
        let trimmed = partialContent.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// AI 标签生成完成但没有可用建议时，以事实文案和低权重恢复动作保留当前 Sheet 上下文。
struct AIAutoTagEmptyStateView: View {
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text("没有生成可用的标签建议")
                .font(AppTypography.subheadline)
                .foregroundStyle(Color.textSecondary)

            Button("重新生成", action: onRetry)
                .font(AppTypography.subheadline)
                .buttonStyle(.borderless)
                .tint(Color.stateActionForeground)
                .xmMinimumHitTarget(anchor: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 单条 AI 标签候选，以暖金色 Spark 标识应用后新增，副标题仅承载推荐理由。
private struct AIAutoTagSuggestionRow: View {
    let suggestion: AIAutoTagSuggestion

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.base) {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                HStack(alignment: .firstTextBaseline, spacing: Spacing.half) {
                    tagName
                        .layoutPriority(1)

                    if !suggestion.isExisting {
                        Image(systemName: "sparkles")
                            .font(AppTypography.caption)
                            .symbolRenderingMode(.palette)
                            .foregroundStyle(Color.yellow, Color.orange)
                            .fixedSize()
                            .accessibilityHidden(true)
                    }
                }

                if let reasonText {
                    Text(reasonText)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Image(systemName: "checkmark")
                .font(AppTypography.subheadlineSemibold)
                .foregroundStyle(Color.appTint)
                .opacity(suggestion.isSelected ? 1 : 0)
                .frame(width: Spacing.section)
                .accessibilityHidden(true)
        }
        .frame(minHeight: InteractionMetrics.minimumTouchTarget)
        .padding(.vertical, Spacing.cozy)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
    }

    private var tagName: some View {
        Text(suggestion.name)
            .font(AppTypography.bodyMedium)
            .foregroundStyle(Color.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var reasonText: String? {
        let reason = suggestion.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? nil : reason
    }
}

/// 首段 AI 标签内容返回前的静态等待态，只说明当前任务，不使用品牌色或循环动效。
struct AIAutoTagWaitingView: View {
    var body: some View {
        Text("分析中…")
            .font(AppTypography.footnote)
            .foregroundStyle(Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("正在分析书摘")
    }
}
