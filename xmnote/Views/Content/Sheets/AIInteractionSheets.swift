/**
 * [INPUT]: 依赖 AITextResultViewModel/AIAutoTagViewModel、AIRepositoryProtocol、AIMarkdownResultView、系统 Sheet/Liquid Glass、LoadingGate、xmMinimumHitTarget 与现有反馈组件
 * [OUTPUT]: 对外提供 AITextResultSheet 与 AIAutoTagSheet，承接流式 Markdown 结果、克制等待态、中性模型菜单、固定底部品牌确认操作、编辑器请求交接和 AI 标签确认写回生命周期
 * [POS]: Views/Content/Sheets 的 AI 业务 Sheet，被通用 viewer 及单页详情入口复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

private enum AIInteractionSheetLayout {
    static let titleHorizontalReserve = InteractionMetrics.minimumTouchTarget + Spacing.base
    static let chromeMinHeight = InteractionMetrics.minimumTouchTarget
    static let headerActionSlotSize: CGFloat = InteractionMetrics.minimumTouchTarget
    static let closeVisualSize: CGFloat = 32
    static let closeFillOpacity = 0.82
}

/// 宽幅品牌主操作按钮，仅服务 AI 结果 Sheet 的确认动作。
private struct AIPrimaryActionButton: View {
    let title: String
    let containerInsetCompensation: CGSize
    let action: () -> Void

    /// 使用动态标题和同步触发动作创建主操作；容器补偿仅抵消系统额外控件内距。
    init(
        _ title: String,
        containerInsetCompensation: CGSize = .zero,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.containerInsetCompensation = containerInsetCompensation
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
        }
        .buttonStyle(
            AIPrimaryActionButtonStyle(
                minimumControlHeight: AIPrimaryActionButtonMetrics.minimumControlHeight
                    + containerInsetCompensation.height
            )
        )
        .buttonSizing(.fitted)
        .frame(
            width: AIPrimaryActionButtonMetrics.controlWidth
                + containerInsetCompensation.width
        )
        .frame(minHeight: AIPrimaryActionButtonMetrics.minimumControlHeight)
        .fixedSize(horizontal: true, vertical: true)
    }
}

/// 将 AI 品牌填充、禁用语义和按压反馈收敛到业务按钮内部。
private struct AIPrimaryActionButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    let minimumControlHeight: CGFloat

    /// 构造尺寸稳定的按钮表层，按压时仅调整不透明度。
    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(
            cornerRadius: CornerRadius.blockLarge,
            style: .continuous
        )

        configuration.label
            .font(AppTypography.headlineSemibold)
            .foregroundStyle(
                isEnabled
                    ? Color.primaryActionForeground
                    : Color.buttonDisabledForeground
            )
            .multilineTextAlignment(.center)
            .padding(.horizontal, Spacing.screenEdge)
            .frame(maxWidth: .infinity, minHeight: minimumControlHeight)
            .background(
                isEnabled ? Color.primaryActionFill : Color.buttonDisabled,
                in: shape
            )
            .contentShape(shape)
            .opacity(
                isEnabled && configuration.isPressed
                    ? AIPrimaryActionButtonMetrics.pressedOpacity
                    : 1
            )
    }
}

/// 参考当前 AI 结果 Sheet 宽度校准的局部主操作规格。
private enum AIPrimaryActionButtonMetrics {
    static let controlWidth: CGFloat = 340
    static let minimumControlHeight: CGFloat = 46
    static let pressedOpacity = 0.86
}

/// 流式 AI 释义 Sheet；整条书摘释义可由用户明确交给既有编辑器继续确认。
struct AITextResultSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(XMToastCenter.self) private var toastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var viewModel: AITextResultViewModel
    @State private var loadingGate = LoadingGate()
    @State private var markdownInteractionController = AIMarkdownInteractionController()
    @State private var hasStartedGeneration = false
    @State private var selectedPresentationDetent: PresentationDetent = .medium

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
        .safeAreaBar(edge: .bottom, spacing: Spacing.none) {
            if viewModel.request.noteIDForIdeaEditor != nil {
                ideaActionBar
            }
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
        .presentationDetents(
            [.medium, .large],
            selection: $selectedPresentationDetent
        )
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
                    .frame(
                        width: AIInteractionSheetLayout.headerActionSlotSize,
                        height: AIInteractionSheetLayout.headerActionSlotSize
                    )

                Spacer(minLength: Spacing.none)

                closeButton
            }
            .frame(minHeight: AIInteractionSheetLayout.chromeMinHeight)

            VStack(spacing: Spacing.micro) {
                Text("AI 释义")
                    .font(AppTypography.headlineSemibold)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)

                modelMenu
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, AIInteractionSheetLayout.titleHorizontalReserve)
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
                .xmMinimumHitTarget(anchor: .top)
        }
        .buttonStyle(.plain)
        .xmMenuNeutralTint()
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
                containerSize: AIInteractionSheetLayout.closeVisualSize,
                weight: .bold,
                foregroundColor: .textSecondary
            )
            .background(
                Color.controlFillSecondary.opacity(AIInteractionSheetLayout.closeFillOpacity),
                in: Circle()
            )
            .frame(
                width: InteractionMetrics.minimumTouchTarget,
                height: InteractionMetrics.minimumTouchTarget
            )
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

                    if viewModel.hasCompletedSuccessfully,
                       viewModel.request.noteIDForIdeaEditor == nil {
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
        Text("内容由 AI 生成，请注意甄别")
            .font(AppTypography.caption)
            .foregroundStyle(Color.textSecondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .center)
    }

    private var ideaActionBar: some View {
        AICompletedActionBar(
            disclosure: "内容由 AI 生成，请注意甄别",
            isVisible: shouldShowIdeaAction
        ) {
            AIPrimaryActionButton(
                viewModel.isPreparingIdeaEditor ? "正在打开…" : "记录到想法",
                containerInsetCompensation: primaryActionContainerInsetCompensation
            ) {
                requestIdeaEditor()
            }
            .disabled(!viewModel.canOpenIdeaEditor)
            .accessibilityHint("打开书摘编辑器，将本次 AI 释义作为未保存想法继续编辑")
        }
    }

    private var shouldShowIdeaAction: Bool {
        viewModel.request.noteIDForIdeaEditor != nil
            && viewModel.hasCompletedSuccessfully
            && !viewModel.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !viewModel.isGenerating
            && !viewModel.isSwitchingModel
    }

    private var primaryActionContainerInsetCompensation: CGSize {
        selectedPresentationDetent == .medium
            ? AICompletedActionBarMetrics.mediumDetentControlInsetCompensation
            : .zero
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

/// 完成态底部操作组；保持透明底板与稳定占位，仅通过透明度回应流式会话终态。
private struct AICompletedActionBar<Action: View>: View {
    let disclosure: String
    let isVisible: Bool
    @ViewBuilder let action: Action

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 接收稳定完成态与具体按钮视图，不持有业务状态或异步任务。
    init(
        disclosure: String,
        isVisible: Bool,
        @ViewBuilder action: () -> Action
    ) {
        self.disclosure = disclosure
        self.isVisible = isVisible
        self.action = action()
    }

    var body: some View {
        VStack(spacing: Spacing.cozy) {
            Text(disclosure)
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .center)

            action
                .frame(maxWidth: .infinity)
        }
        .padding(.horizontal, Spacing.none)
        .padding(.top, Spacing.cozy)
        .padding(.bottom, Spacing.cozy)
        .background(Color.clear)
        .opacity(isVisible ? 1 : 0)
        .allowsHitTesting(isVisible)
        .accessibilityHidden(!isVisible)
        .animation(visibilityAnimation, value: isVisible)
    }

    private var visibilityAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .smooth(duration: 0.24)
    }
}

/// 系统半高 Sheet 会在 safeAreaBar 内额外收紧控件轮廓，此处集中保存像素校准补偿。
private enum AICompletedActionBarMetrics {
    static let mediumDetentControlInsetCompensation = CGSize(width: 14, height: 2)
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
    @State private var selectedPresentationDetent: PresentationDetent = .medium

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
        .safeAreaBar(edge: .bottom, spacing: Spacing.none) {
            autoTagActionBar
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
        .presentationDetents(
            [.medium, .large],
            selection: $selectedPresentationDetent
        )
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
                    .frame(
                        width: AIInteractionSheetLayout.headerActionSlotSize,
                        height: AIInteractionSheetLayout.headerActionSlotSize
                    )

                Spacer(minLength: Spacing.none)

                closeButton
            }
            .frame(minHeight: AIInteractionSheetLayout.chromeMinHeight)

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
            .padding(.horizontal, AIInteractionSheetLayout.titleHorizontalReserve)
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
                containerSize: AIInteractionSheetLayout.closeVisualSize,
                weight: .bold,
                foregroundColor: .textSecondary
            )
            .background(
                Color.controlFillSecondary.opacity(AIInteractionSheetLayout.closeFillOpacity),
                in: Circle()
            )
            .frame(
                width: InteractionMetrics.minimumTouchTarget,
                height: InteractionMetrics.minimumTouchTarget
            )
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
                Text("没有生成可用的标签建议")
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

    private var autoTagActionBar: some View {
        AICompletedActionBar(
            disclosure: "内容由 AI 生成，请注意甄别",
            isVisible: viewModel.phaseKind == .ready
        ) {
            AIPrimaryActionButton(
                viewModel.isApplying ? "应用中…" : "应用标签",
                containerInsetCompensation: primaryActionContainerInsetCompensation
            ) {
                applyTags()
            }
            .disabled(!viewModel.hasSelectedSuggestion || viewModel.isApplying)
        }
    }

    private var primaryActionContainerInsetCompensation: CGSize {
        selectedPresentationDetent == .medium
            ? AICompletedActionBarMetrics.mediumDetentControlInsetCompensation
            : .zero
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
        let source = suggestion.isExisting ? "直接复用" : "应用后新建"
        let selection = suggestion.isSelected ? "已选择" : "未选择"
        let reason = suggestion.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty
            ? "AI 推荐，\(source)，\(selection)"
            : "AI 推荐，\(source)，\(reason)，\(selection)"
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
private struct AIAutoTagWaitingView: View {
    var body: some View {
        Text("分析中…")
            .font(AppTypography.footnote)
            .foregroundStyle(Color.textSecondary)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityLabel("正在分析书摘")
    }
}
