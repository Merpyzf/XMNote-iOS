/**
 * [INPUT]: 依赖 AITextResultViewModel/AIAutoTagViewModel、AIRepositoryProtocol、AIMarkdownResultView、系统 Sheet/Liquid Glass、LoadingGate 与现有反馈组件
 * [OUTPUT]: 对外提供 AITextResultSheet 与 AIAutoTagSheet，承接流式 Markdown 结果、克制等待态、模型切换、编辑器请求交接和 AI 标签确认写回生命周期
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
        ScrollView {
            suggestionContent
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
        .interactiveDismissDisabled(viewModel.isApplying)
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
                Text("AI 标签")
                    .font(AppTypography.headlineSemibold)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)

                Text(normalizedBookTitle)
                    .font(AppTypography.caption2)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, XMSettingsSheetLayout.titleHorizontalReserve)
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.top, Spacing.double)
        .padding(.bottom, Spacing.section)
    }

    private var closeButton: some View {
        Button {
            viewModel.cancelLoading()
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
        .disabled(viewModel.isApplying)
        .accessibilityLabel("关闭")
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
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text("没有生成可用的标签建议。")
                    .font(AppTypography.footnote)
                    .foregroundStyle(Color.textSecondary)
                retryButton
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
        case .failed(let message, let partialContent):
            VStack(alignment: .leading, spacing: Spacing.section) {
                if let partialContent {
                    AIMarkdownResultView(
                        markdown: partialContent,
                        isStreaming: false,
                        interactionController: markdownInteractionController
                    )
                }

                generationError(message: message)
                retryButton
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .transition(.opacity)
        }
    }

    private func readyContent(suggestions: [AIAutoTagSuggestion]) -> some View {
        VStack(alignment: .leading, spacing: Spacing.section) {
            Text("最多 3 个标签；已有标签将直接复用。")
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

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

            Label("AI 生成，请确认后应用", systemImage: "sparkles")
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .trailing)

            applyAction
        }
    }

    private var applyAction: some View {
        HStack(spacing: Spacing.none) {
            Spacer(minLength: Spacing.none)

            Button {
                applyTags()
            } label: {
                Text(viewModel.isApplying ? "应用中…" : "应用标签")
                    .font(AppTypography.subheadlineMedium)
                    .foregroundStyle(Color.textPrimary)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.capsule)
            .controlSize(.regular)
            .frame(minHeight: Spacing.actionReserved)
            .contentShape(.interaction, Capsule())
            .disabled(!viewModel.hasSelectedSuggestion || viewModel.isApplying)

            Spacer(minLength: Spacing.none)
        }
        .frame(maxWidth: .infinity)
    }

    private func generationError(message: String) -> some View {
        Label(message, systemImage: "exclamationmark.circle")
            .font(AppTypography.footnote)
            .foregroundStyle(Color.feedbackError)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var retryButton: some View {
        Button("重新生成") {
            viewModel.startLoading()
        }
        .font(AppTypography.subheadlineMedium)
        .buttonStyle(.bordered)
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
        let source = suggestion.isExisting ? "已有标签" : "将新建"
        let selection = suggestion.isSelected ? "已选择" : "未选择"
        let reason = suggestion.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty
            ? "\(source)，\(selection)"
            : "\(source)，\(reason)，\(selection)"
    }
}

/// 单条 AI 标签候选，以两层中性文本承载来源和理由，仅用行尾小勾表达选择。
private struct AIAutoTagSuggestionRow: View {
    let suggestion: AIAutoTagSuggestion

    var body: some View {
        HStack(alignment: .top, spacing: Spacing.base) {
            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text(suggestion.name)
                    .font(AppTypography.bodyMedium)
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

                Text(detailText)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: Spacing.none)

            Image(systemName: "checkmark")
                .font(AppTypography.subheadlineSemibold)
                .foregroundStyle(Color.brand)
                .opacity(suggestion.isSelected ? 1 : 0)
                .frame(width: Spacing.section, height: Spacing.actionReserved, alignment: .top)
                .accessibilityHidden(true)
        }
        .frame(minHeight: Spacing.actionReserved)
        .padding(.vertical, Spacing.cozy)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
    }

    private var detailText: String {
        let source = suggestion.isExisting ? "已有标签" : "将新建"
        let reason = suggestion.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? source : "\(source) · \(reason)"
    }
}

/// 首段 AI 标签内容返回前的静态等待态，只说明当前任务，不使用品牌色或循环动效。
private struct AIAutoTagWaitingView: View {
    var body: some View {
        Text("分析中…")
            .font(AppTypography.footnote)
            .foregroundStyle(Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("正在分析书摘")
    }
}
