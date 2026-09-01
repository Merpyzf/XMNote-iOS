/**
 * [INPUT]: 依赖 AIPromptEditorViewModel、AIPromptTrialSessionViewModel、NoteRepositoryProtocol、XMBookCover、AI 生成等待反馈、标准 Sheet/搜索/状态组件、提示词变量只读渲染器与流式 Markdown 渲染器
 * [OUTPUT]: 对外提供提示词请求预览、可编辑书摘流式试运行、本地书摘选择，以及输入/结果分层的字段优化业务 Sheet
 * [POS]: Views/Personal/Sheets 的提示词编辑次级任务集合，由 AIPromptEditorView 的 item-driven Sheet 路由消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 离线真实请求预览；固定规则只在用户展开完整请求时出现。
struct AIPromptPreviewSheet: View {
    let editableRoleRules: String
    let preview: AIPromptRequestPreview

    @Environment(\.dismiss) private var dismiss
    @State private var showsFullRequest = false

    var body: some View {
        NavigationStack {
            Form {
                Section("系统提示词") {
                    Text(editableRoleRules)
                        .textSelection(.enabled)
                }

                Section("用户提示词（变量已替换）") {
                    Text(preview.userPrompt)
                        .textSelection(.enabled)
                }

                DisclosureGroup("完整请求", isExpanded: $showsFullRequest) {
                    LabeledContent("System") {
                        Text(editableRoleRules)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    LabeledContent("User") {
                        Text(preview.userPrompt)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    VStack(alignment: .leading, spacing: Spacing.half) {
                        Text("应用自动附加内容")
                            .font(AppTypography.captionSemibold)
                            .foregroundStyle(Color.textSecondary)
                        Text(preview.applicationRules)
                            .textSelection(.enabled)
                    }
                    if preview.expectsJSON {
                        LabeledContent("响应格式", value: "JSON")
                    }
                }
            }
            .navigationTitle("实际发送内容")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}

private enum AIPromptTrialNestedSheet: String, Identifiable {
    case excerptPicker

    var id: String { rawValue }
}

private enum AIPromptTrialResources {
    static let sampleBookCoverURL = Bundle.main.url(
        forResource: "AIPromptTrialHundredYearsOfSolitudeCover",
        withExtension: "jpg"
    )?.absoluteString ?? ""
}

/// 提示词试运行 Flow；准备页与 Push 结果页共享同一会话，导航变化不会中断流式生成。
struct AIPromptTrialSheet: View {
    let noteRepository: any NoteRepositoryProtocol

    @Environment(\.dismiss) private var dismiss
    @Environment(XMToastCenter.self) private var toastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @State private var session: AIPromptTrialSessionViewModel
    @State private var excerptSelection: TextSelection?
    @State private var activeSheet: AIPromptTrialNestedSheet?
    @State private var showsResult = false
    @State private var currentMarkdownController = AIMarkdownInteractionController()
    @State private var defaultMarkdownController = AIMarkdownInteractionController()
    @State private var resultPageHeights: [AIPromptTrialTarget: CGFloat] = [:]

    /// 使用编辑页当前草稿建立一次稳定测试会话；书摘仓储只服务用户主动打开的选择 Sheet。
    init(
        kind: AIPromptKind,
        template: AIPromptTemplate,
        aiRepository: any AIRepositoryProtocol,
        noteRepository: any NoteRepositoryProtocol
    ) {
        self.noteRepository = noteRepository
        _session = State(
            initialValue: AIPromptTrialSessionViewModel(
                kind: kind,
                template: template,
                repository: aiRepository
            )
        )
    }

    var body: some View {
        XMSheetScaffold(
            title: "测试提示词",
            onClose: close,
            bottomBar: {
                preparationActionBar
            }
        ) {
            AIPromptTrialPreparationView(
                session: session,
                excerptSelection: $excerptSelection,
                onChooseExcerpt: { activeSheet = .excerptPicker }
            )
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.double)
            .navigationDestination(isPresented: $showsResult) {
                AIPromptTrialResultView(
                    session: session,
                    currentController: currentMarkdownController,
                    defaultController: defaultMarkdownController,
                    pageHeights: $resultPageHeights,
                    onRetry: retryTrial
                )
            }
        }
        .presentationDetents([.large])
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .excerptPicker:
                AIPromptExcerptPickerSheet(
                    repository: noteRepository,
                    selectedNoteID: session.excerpt.localNoteID,
                    onSelect: selectExcerpt
                )
            }
        }
        .sheet(
            item: $currentMarkdownController.pendingTableExport,
            onDismiss: currentMarkdownController.discardPendingTableExport
        ) { export in
            XMActivityShareSheet(activityItems: [export.fileURL])
                .presentationDetents([.medium, .large])
                .onDisappear { export.discard() }
        }
        .sheet(
            item: $defaultMarkdownController.pendingTableExport,
            onDismiss: defaultMarkdownController.discardPendingTableExport
        ) { export in
            XMActivityShareSheet(activityItems: [export.fileURL])
                .presentationDetents([.medium, .large])
                .onDisappear { export.discard() }
        }
        .onAppear {
            currentMarkdownController.configure(
                toastCenter: toastCenter,
                reducesMotion: reduceMotion
            )
            defaultMarkdownController.configure(
                toastCenter: toastCenter,
                reducesMotion: reduceMotion
            )
        }
        .onChange(of: reduceMotion) { _, newValue in
            currentMarkdownController.updateReduceMotion(newValue)
            defaultMarkdownController.updateReduceMotion(newValue)
        }
        .onChange(of: dynamicTypeSize) { _, _ in
            resultPageHeights.removeAll()
        }
        .onChange(of: session.excerptText) { _, _ in
            excerptSelection = nil
        }
        .onChange(of: excerptSelection) { _, _ in
            updateSelectedQuery()
        }
        .onChange(of: session.phase(for: .current).isStreaming) { wasStreaming, isStreaming in
            if wasStreaming, !isStreaming {
                currentMarkdownController.finishStreamingContent()
            }
        }
        .onChange(of: session.phase(for: .appDefault).isStreaming) { wasStreaming, isStreaming in
            if wasStreaming, !isStreaming {
                defaultMarkdownController.finishStreamingContent()
            }
        }
        .onDisappear {
            session.cancelAndDiscard()
            currentMarkdownController.discardPendingTableExport()
            defaultMarkdownController.discardPendingTableExport()
        }
    }

    private var preparationActionBar: some View {
        Button(action: handlePreparationAction) {
            Text(preparationActionTitle)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.extraLarge)
        .tint(Color.appTint)
        .disabled(!session.hasStarted && !session.canStart)
        .accessibilityHint(preparationActionHint)
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.vertical, Spacing.cozy)
    }

    private var preparationActionTitle: String {
        if session.isRunning { return "查看进度" }
        return session.hasStarted ? "查看结果" : "开始测试"
    }

    private var preparationActionHint: String {
        if session.hasStarted {
            return session.isRunning ? "打开正在生成的测试结果" : "打开已生成的测试结果"
        }
        return session.startDisabledReason ?? "使用当前书摘运行提示词"
    }

    /// 已有任务只恢复结果页；首次运行在 Push 前建立 connecting 状态，避免目的页出现空白帧。
    private func handlePreparationAction() {
        if session.hasStarted {
            showsResult = true
            return
        }
        currentMarkdownController.resetForNewGeneration()
        defaultMarkdownController.resetForNewGeneration()
        guard session.start() else { return }
        resultPageHeights.removeAll()
        showsResult = true
    }

    /// 结果页重试留在当前导航层级；两侧控制器与会话请求在同一时刻重置。
    private func retryTrial() {
        currentMarkdownController.resetForNewGeneration()
        defaultMarkdownController.resetForNewGeneration()
        guard session.start() else { return }
        resultPageHeights.removeAll()
    }

    /// 选中书摘后替换正文与元数据快照；后续正文编辑继续保留这组来源信息。
    private func selectExcerpt(_ note: NoteExcerptListItem) {
        session.selectExcerpt(note)
        excerptSelection = nil
    }

    /// 从 TextEditor 的单一连续选区提取查词文本；插入点、空白或多重选区均视为未选择。
    private func updateSelectedQuery() {
        guard session.kind == .wordLookup,
              let excerptSelection else {
            session.updateSelectedQuery(nil)
            return
        }
        switch excerptSelection.indices {
        case .selection(let range):
            guard !range.isEmpty,
                  range.lowerBound >= session.excerptText.startIndex,
                  range.upperBound <= session.excerptText.endIndex else {
                session.updateSelectedQuery(nil)
                return
            }
            let query = String(session.excerptText[range])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            session.updateSelectedQuery(query.isEmpty ? nil : query)
        case .multiSelection:
            session.updateSelectedQuery(nil)
        @unknown default:
            session.updateSelectedQuery(nil)
        }
    }

    private func close() {
        session.cancelAndDiscard()
        dismiss()
    }
}

/// 测试准备页只承载书摘输入与选择入口；结果和对照控制不进入该信息层级。
private struct AIPromptTrialPreparationView: View {
    @Bindable var session: AIPromptTrialSessionViewModel
    @Binding var excerptSelection: TextSelection?
    let onChooseExcerpt: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @ScaledMetric(relativeTo: .body) private var excerptEditorMinimumHeight: CGFloat = 120
    @ScaledMetric(relativeTo: .caption) private var sourceCoverWidth: CGFloat = 28

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            excerptEditorCard

            if session.kind == .wordLookup {
                Text(wordLookupGuidance)
                    .font(AppTypography.footnote)
                    .foregroundStyle(session.selectedQuery == nil ? Color.feedbackWarning : Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(wordLookupGuidance)
            }
        }
    }

    private var excerptEditorCard: some View {
        CardContainer(shape: ConcentricRectangle.xmSheetContentPanel) {
            VStack(alignment: .leading, spacing: Spacing.none) {
                TextEditor(text: $session.excerptText, selection: $excerptSelection)
                    .font(AppTypography.body)
                    .foregroundStyle(Color.textPrimary)
                    .scrollContentBackground(.hidden)
                    .frame(minHeight: excerptEditorMinimumHeight)
                    .padding(.horizontal, Spacing.base)
                    .padding(.top, Spacing.cozy)
                    .disabled(session.isRunning)
                    .accessibilityLabel("测试书摘正文")

                Rectangle()
                    .fill(Color.surfaceDividerSubtle)
                    .frame(height: StrokeWidth.hairline)
                    .padding(.horizontal, Spacing.contentEdge)
                    .accessibilityHidden(true)

                Button(action: onChooseExcerpt) {
                    sourceSelectionContent
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                        .padding(.horizontal, Spacing.contentEdge)
                        .padding(.vertical, Spacing.cozy)
                }
                .buttonStyle(.plain)
                .disabled(session.isRunning)
                .accessibilityLabel(sourceSelectionAccessibilityLabel)
                .accessibilityHint("打开本地书摘列表")
            }
        }
    }

    @ViewBuilder
    private var sourceSelectionContent: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                bookSourceIdentity
                selectionActionLabel
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(alignment: .center, spacing: Spacing.base) {
                bookSourceIdentity
                    .frame(maxWidth: .infinity, alignment: .leading)

                selectionActionLabel
                    .fixedSize(horizontal: true, vertical: false)
            }
        }
    }

    private var bookSourceIdentity: some View {
        HStack(alignment: .top, spacing: Spacing.cozy) {
            XMBookCover.fixedWidth(
                sourceCoverWidth,
                urlString: resolvedBookCoverURL,
                cornerRadius: CornerRadius.inlayHairline,
                border: .init(color: .surfaceBorderSubtle, width: StrokeWidth.hairline),
                placeholderIconSize: .small,
                surfaceStyle: .plain
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text(displayBookTitle)
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                    .fixedSize(horizontal: false, vertical: true)

                if !bookMetadataLine.isEmpty {
                    Text(bookMetadataLine)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 1)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var selectionActionLabel: some View {
        HStack(spacing: Spacing.compact) {
            Text("选择书摘")
                .font(AppTypography.subheadline)
                .foregroundStyle(Color.textSecondary)

            Spacer(minLength: Spacing.none)

            Image(systemName: "chevron.right")
                .font(AppTypography.captionSemibold)
                .foregroundStyle(Color.textHint)
                .accessibilityHidden(true)
        }
    }

    private var resolvedBookCoverURL: String {
        let coverURL = session.excerpt.bookCoverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !coverURL.isEmpty { return coverURL }
        return session.excerpt.localNoteID == nil ? AIPromptTrialResources.sampleBookCoverURL : ""
    }

    private var displayBookTitle: String {
        let title = session.excerpt.bookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "本地书摘" : title
    }

    private var trimmedBookAuthor: String {
        session.excerpt.bookAuthor.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var trimmedChapterTitle: String {
        session.excerpt.chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var bookMetadataLine: String {
        [trimmedBookAuthor, trimmedChapterTitle]
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }

    private var sourceSelectionAccessibilityLabel: String {
        var values = ["选择书摘", "当前《\(displayBookTitle)》"]
        if !trimmedBookAuthor.isEmpty { values.append("作者，\(trimmedBookAuthor)") }
        if !trimmedChapterTitle.isEmpty { values.append("章节，\(trimmedChapterTitle)") }
        return values.joined(separator: "，")
    }

    private var wordLookupGuidance: String {
        guard let selectedQuery = session.selectedQuery else {
            return "请在书摘中选中要查询的文字"
        }
        return "将查询：“\(selectedQuery)”"
    }
}

/// Push 结果页；原生 SegmentedPicker、流式 Markdown 与重试操作共同消费外层共享会话。
private struct AIPromptTrialResultView: View {
    @Bindable var session: AIPromptTrialSessionViewModel
    let currentController: AIMarkdownInteractionController
    let defaultController: AIMarkdownInteractionController
    @Binding var pageHeights: [AIPromptTrialTarget: CGFloat]
    let onRetry: () -> Void

    var body: some View {
        Group {
            if session.comparesDefault {
                if session.isRunning {
                    XMScrollEdgeChrome(
                        presentation: .overlaySoft,
                        edges: .top,
                        topBar: { resultPicker },
                        content: { resultScrollView }
                    )
                } else {
                    XMScrollEdgeChrome(
                        presentation: .overlaySoft,
                        edges: [.top, .bottom],
                        topBar: { resultPicker },
                        bottomBar: { resultActionBar },
                        content: { resultScrollView }
                    )
                }
            } else if session.isRunning {
                XMScrollEdgeChrome(
                    presentation: .overlaySoft,
                    content: { resultScrollView }
                )
            } else {
                XMScrollEdgeChrome(
                    presentation: .overlaySoft,
                    edges: .bottom,
                    bottomBar: { resultActionBar },
                    content: { resultScrollView }
                )
            }
        }
        .background(Color.surfaceSheet.ignoresSafeArea())
        .navigationTitle("测试结果")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var resultPicker: some View {
        Picker("结果来源", selection: $session.selectedResultTarget) {
            Text("当前提示词").tag(AIPromptTrialTarget.current)
            Text("默认提示词").tag(AIPromptTrialTarget.appDefault)
        }
        .pickerStyle(SegmentedPickerStyle())
        .accessibilityLabel("结果来源")
        .accessibilityValue(resultSourceAccessibilityValue)
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.vertical, Spacing.cozy)
    }

    private var resultScrollView: some View {
        @Bindable var activeController = activeInteractionController

        return ScrollView {
            resultContent
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.top, Spacing.cozy)
                .padding(.bottom, Spacing.double)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .scrollIndicators(.hidden)
        .scrollBounceBehavior(.always)
        .scrollPosition($activeController.scrollPosition)
        .onScrollGeometryChange(for: Bool.self) { geometry in
            let distanceFromBottom = geometry.contentSize.height
                - geometry.contentOffset.y
                - geometry.containerSize.height
            return distanceFromBottom <= Spacing.double
        } action: { _, isAtBottom in
            activeController.updateIsAtBottom(
                isAtBottom,
                isPositionedByUser: activeController.scrollPosition.isPositionedByUser
            )
        }
        .onChange(of: activeController.scrollPosition.isPositionedByUser) { _, newValue in
            activeController.updateIsPositionedByUser(newValue)
        }
    }

    @ViewBuilder
    private var resultContent: some View {
        if let errorMessage = session.errorMessage {
            XMContentStateView(
                role: .failure,
                title: "暂时无法生成结果",
                message: errorMessage
            )
            .frame(minHeight: 320)
        } else if session.comparesDefault {
            AIPromptTrialResultPager(
                session: session,
                currentController: currentController,
                defaultController: defaultController,
                pageHeights: $pageHeights
            )
        } else {
            AIPromptTrialResultPage(
                target: .current,
                phase: session.phase(for: .current),
                interactionController: currentController
            )
        }
    }

    private var resultActionBar: some View {
        Button(action: onRetry) {
            Text("重新测试")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.glassProminent)
        .controlSize(.extraLarge)
        .tint(Color.appTint)
        .accessibilityHint("使用当前书摘重新生成测试结果")
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.vertical, Spacing.cozy)
    }

    private var activeInteractionController: AIMarkdownInteractionController {
        session.selectedResultTarget == .current ? currentController : defaultController
    }

    private var resultSourceAccessibilityValue: String {
        session.selectedResultTarget == .current
            ? "当前提示词生成结果"
            : "应用内置默认提示词生成结果"
    }
}

/// 两个试运行结果在同一内容区域水平分页，当前页高度随流式 Markdown 实际内容更新。
private struct AIPromptTrialResultPager: View {
    @Bindable var session: AIPromptTrialSessionViewModel
    let currentController: AIMarkdownInteractionController
    let defaultController: AIMarkdownInteractionController
    @Binding var pageHeights: [AIPromptTrialTarget: CGFloat]

    @State private var scrollTarget: AIPromptTrialTarget? = .current

    var body: some View {
        ScrollView(.horizontal) {
            LazyHStack(alignment: .top, spacing: Spacing.none) {
                resultPage(for: .current, controller: currentController)
                resultPage(for: .appDefault, controller: defaultController)
            }
            .scrollTargetLayout()
        }
        .scrollIndicators(.hidden)
        .scrollTargetBehavior(.paging)
        .scrollPosition(id: $scrollTarget, anchor: .topLeading)
        .frame(height: resolvedPageHeight)
        .onAppear {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                scrollTarget = session.selectedResultTarget
            }
        }
        .onChange(of: session.selectedResultTarget) { _, newValue in
            guard scrollTarget != newValue else { return }
            scrollTarget = newValue
        }
        .onChange(of: scrollTarget) { _, newValue in
            guard let newValue, session.selectedResultTarget != newValue else { return }
            session.selectedResultTarget = newValue
        }
    }

    private func resultPage(
        for target: AIPromptTrialTarget,
        controller: AIMarkdownInteractionController
    ) -> some View {
        AIPromptTrialResultPage(
            target: target,
            phase: session.phase(for: target),
            interactionController: controller
        )
        .containerRelativeFrame(.horizontal)
        .id(target)
        .onGeometryChange(for: CGFloat.self) { geometry in
            ceil(geometry.size.height)
        } action: { height in
            let previousHeight = pageHeights[target]
            guard height.isFinite,
                  height > 0,
                  previousHeight == nil || abs((previousHeight ?? 0) - height) > 0.5 else {
                return
            }
            pageHeights[target] = height
        }
    }

    private var resolvedPageHeight: CGFloat {
        if let selectedHeight = validHeight(for: session.selectedResultTarget) {
            return selectedHeight
        }

        let alternateTarget: AIPromptTrialTarget = session.selectedResultTarget == .current
            ? .appDefault
            : .current
        return validHeight(for: alternateTarget) ?? InteractionMetrics.minimumTouchTarget
    }

    private func validHeight(for target: AIPromptTrialTarget) -> CGFloat? {
        guard let height = pageHeights[target], height.isFinite, height > 0 else { return nil }
        return max(height, InteractionMetrics.minimumTouchTarget)
    }
}

/// 单个目标的流式结果展示；失败时只在确有部分内容的情况下使用保留内容 Banner。
private struct AIPromptTrialResultPage: View {
    let target: AIPromptTrialTarget
    let phase: AIPromptTrialPhase
    let interactionController: AIMarkdownInteractionController

    @State private var loadingGate = LoadingGate()

    var body: some View {
        resultContent
            .onAppear(perform: syncLoadingGate)
            .onChange(of: isConnecting) { _, newValue in
                loadingGate.update(intent: newValue ? .read : .none)
            }
            .onDisappear {
                loadingGate.hideImmediately()
            }
    }

    @ViewBuilder
    private var resultContent: some View {
        switch phase {
        case .idle:
            Text("尚未开始测试")
                .font(AppTypography.footnote)
                .foregroundStyle(Color.textSecondary)
                .frame(
                    maxWidth: .infinity,
                    minHeight: InteractionMetrics.minimumTouchTarget,
                    alignment: .leading
                )
        case .connecting:
            if loadingGate.isVisible {
                AIGenerationWaitingView(
                    "正在生成…",
                    accessibilityLabel: "正在生成测试结果"
                )
                .frame(
                    maxWidth: .infinity,
                    minHeight: InteractionMetrics.minimumTouchTarget,
                    alignment: .leading
                )
            } else {
                Color.clear
                    .frame(
                        maxWidth: .infinity,
                        minHeight: InteractionMetrics.minimumTouchTarget
                    )
            }
        case .streaming(let markdown):
            markdownView(markdown, isStreaming: true)
        case .completed(let markdown):
            markdownView(markdown, isStreaming: false)
        case .failed(let message, let partialContent):
            if partialContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                XMCompactStateView(
                    role: .failure,
                    title: "\(targetTitle)暂时无法生成",
                    message: message
                )
            } else {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    markdownView(partialContent, isStreaming: false)
                    XMInlineStatusBanner(
                        "结果未完整生成：\(message)",
                        tone: .error
                    )
                }
            }
        }
    }

    private var targetTitle: String {
        target == .current ? "当前提示词" : "默认提示词"
    }

    private var isConnecting: Bool {
        if case .connecting = phase { return true }
        return false
    }

    private func syncLoadingGate() {
        loadingGate.update(intent: isConnecting ? .read : .none)
    }

    private func markdownView(_ markdown: String, isStreaming: Bool) -> some View {
        AIMarkdownResultView(
            markdown: markdown,
            isStreaming: isStreaming,
            interactionController: interactionController
        )
    }
}

/// 本地书摘单选 Sheet；搜索、分页和错误状态由页面专属 ViewModel 持有，选择后立即返回快照。
private struct AIPromptExcerptPickerSheet: View {
    let selectedNoteID: Int64?
    let onSelect: (NoteExcerptListItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: AIPromptExcerptPickerViewModel
    @State private var isSearchActive = false

    /// 为本次选择会话创建独立状态源；关闭后观察任务随 ViewModel 生命周期取消。
    init(
        repository: any NoteRepositoryProtocol,
        selectedNoteID: Int64?,
        onSelect: @escaping (NoteExcerptListItem) -> Void
    ) {
        self.selectedNoteID = selectedNoteID
        self.onSelect = onSelect
        _viewModel = State(initialValue: AIPromptExcerptPickerViewModel(repository: repository))
    }

    var body: some View {
        XMSheetScaffold(
            title: "选择书摘",
            onClose: { dismiss() },
            contentTopBar: {
                XMSystemSearchBar(
                    text: Binding(
                        get: { viewModel.query },
                        set: viewModel.updateQuery
                    ),
                    isActive: $isSearchActive,
                    prompt: "搜索书名、作者、书摘或想法",
                    accessibilityIdentifier: "ai.prompt.trial.excerpt.search"
                )
                .padding(.horizontal, Spacing.cozy)
            }
        ) {
            pickerContent
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.bottom, Spacing.contentEdge)
        }
        .presentationDetents([.large])
        .onAppear(perform: viewModel.start)
        .onDisappear(perform: viewModel.cancel)
    }

    @ViewBuilder
    private var pickerContent: some View {
        if viewModel.items.isEmpty, viewModel.isLoading {
            LoadingStateView("正在读取书摘…", style: .inline)
                .frame(maxWidth: .infinity, minHeight: 320)
        } else if viewModel.items.isEmpty, let error = viewModel.errorMessage {
            XMContentStateView(
                role: .failure,
                title: "暂时无法读取书摘",
                message: error,
                action: XMStateAction("重试", perform: viewModel.retry)
            )
            .frame(minHeight: 320)
        } else if viewModel.items.isEmpty {
            XMContentStateView(
                role: viewModel.isSearching ? .noResults : .empty,
                title: viewModel.isSearching ? "没有匹配的书摘" : "暂无可选书摘",
                message: viewModel.isSearching ? "请更换关键词" : nil
            )
            .frame(minHeight: 320)
        } else {
            LazyVStack(spacing: Spacing.none) {
                if let retainedError = viewModel.retainedErrorMessage {
                    XMInlineStatusBanner(
                        "部分书摘未能更新：\(retainedError)",
                        tone: .error,
                        action: XMStateAction("重试", perform: viewModel.retry)
                    )
                    .padding(.bottom, Spacing.base)
                }

                ForEach(viewModel.items) { item in
                    AIPromptExcerptPickerRow(
                        item: item,
                        query: viewModel.query,
                        isSelected: item.id == selectedNoteID,
                        onSelect: {
                            onSelect(item)
                            dismiss()
                        }
                    )
                    .onAppear {
                        viewModel.loadNextPageIfNeeded(currentItemID: item.id)
                    }

                    if item.id != viewModel.items.last?.id {
                        Rectangle()
                            .fill(Color.surfaceDividerSubtle)
                            .frame(height: StrokeWidth.hairline)
                            .accessibilityHidden(true)
                    }
                }

                if viewModel.hasMore {
                    HStack(spacing: Spacing.cozy) {
                        if viewModel.isLoading {
                            ProgressView()
                                .controlSize(.small)
                        }
                        Text(viewModel.isLoading ? "正在加载更多…" : "继续向下浏览")
                            .font(AppTypography.footnote)
                            .foregroundStyle(Color.textSecondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: InteractionMetrics.minimumTouchTarget)
                }
            }
        }
    }
}

/// 提示词测试专用书摘选择行，按书摘、章节、书籍来源的阅读顺序组织单一选择目标。
private struct AIPromptExcerptPickerRow: View {
    let item: NoteExcerptListItem
    let query: String
    let isSelected: Bool
    let onSelect: () -> Void

    @ScaledMetric(relativeTo: .caption) private var coverWidth: CGFloat = 28

    var body: some View {
        Button(action: onSelect) {
            HStack(alignment: .top, spacing: Spacing.base) {
                VStack(alignment: .leading, spacing: Spacing.none) {
                    excerptContent

                    if !chapterTitle.isEmpty {
                        chapterContent
                            .padding(.top, Spacing.half)
                    }

                    if let ideaMatchContext {
                        ideaMatchContent(ideaMatchContext)
                            .padding(.top, Spacing.half)
                    }

                    bookIdentity
                        .padding(.top, Spacing.base)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                XMSelectionIndicator(
                    style: .checkmarkOnly,
                    isSelected: isSelected,
                    font: AppTypography.body
                )
                .padding(.top, Spacing.tiny)
            }
            .padding(.vertical, Spacing.base)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!isSelectable)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(isSelected ? "已选择" : "未选择")
        .accessibilityHint(isSelectable ? "选择此书摘用于提示词测试" : "无正文，无法用于测试")
    }

    private var excerptContent: some View {
        XMKeywordHighlighting.text(
            isSelectable ? excerptText : "无正文，无法用于测试",
            keyword: query,
            baseFont: ReadingContentTypography.body,
            highlightFont: ReadingContentTypography.body,
            baseColor: isSelectable ? Color.textPrimary : Color.textHint
        )
        .lineSpacing(ReadingContentTypography.bodyLineSpacing)
        .lineLimit(4)
        .multilineTextAlignment(.leading)
    }

    private var chapterContent: some View {
        XMKeywordHighlighting.text(
            "章节 · \(chapterTitle)",
            keyword: query,
            baseFont: AppTypography.caption,
            highlightFont: AppTypography.captionMedium,
            baseColor: Color.textSecondary
        )
        .lineLimit(2)
        .multilineTextAlignment(.leading)
    }

    private func ideaMatchContent(_ context: String) -> some View {
        XMKeywordHighlighting.text(
            "想法 · \(context)",
            keyword: query,
            baseFont: AppTypography.caption,
            highlightFont: AppTypography.captionMedium,
            baseColor: Color.textSecondary
        )
        .lineLimit(2)
        .multilineTextAlignment(.leading)
    }

    private var bookIdentity: some View {
        HStack(alignment: .top, spacing: Spacing.cozy) {
            XMBookCover.fixedWidth(
                coverWidth,
                urlString: item.bookCoverURL,
                cornerRadius: CornerRadius.inlayHairline,
                border: .init(color: .surfaceBorderSubtle, width: StrokeWidth.hairline),
                placeholderIconSize: .small,
                priority: .low,
                surfaceStyle: .plain
            )
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: Spacing.compact) {
                XMKeywordHighlighting.text(
                    bookTitle,
                    keyword: query,
                    baseFont: AppTypography.footnote,
                    highlightFont: AppTypography.footnote,
                    baseColor: Color.textPrimary
                )
                .lineLimit(2)
                .multilineTextAlignment(.leading)

                if !bookAuthor.isEmpty {
                    XMKeywordHighlighting.text(
                        bookAuthor,
                        keyword: query,
                        baseFont: AppTypography.caption2,
                        highlightFont: AppTypography.caption2Semibold,
                        baseColor: Color.textSecondary
                    )
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var isSelectable: Bool {
        !excerptText.isEmpty
    }

    private var excerptText: String {
        item.plainContent.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var chapterTitle: String {
        item.chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var bookTitle: String {
        let title = item.bookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "本地书摘" : title
    }

    private var bookAuthor: String {
        item.bookAuthor.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var ideaMatchContext: String? {
        let idea = item.plainIdea.trimmingCharacters(in: .whitespacesAndNewlines)
        guard XMKeywordHighlighting.contains(idea, keyword: query),
              !visibleContentContainsQuery else {
            return nil
        }
        return Self.matchingSnippet(in: idea, keyword: query)
    }

    private var visibleContentContainsQuery: Bool {
        [excerptText, chapterTitle, bookTitle, bookAuthor]
            .contains { XMKeywordHighlighting.contains($0, keyword: query) }
    }

    private var accessibilityLabel: String {
        var values = [isSelectable ? excerptText : "无正文，无法用于测试"]
        if !chapterTitle.isEmpty { values.append("章节，\(chapterTitle)") }
        values.append("书籍，\(bookTitle)")
        if !bookAuthor.isEmpty { values.append("作者，\(bookAuthor)") }
        if let ideaMatchContext { values.append("想法命中，\(ideaMatchContext)") }
        return values.joined(separator: "，")
    }

    /// 截取命中词附近的可读片段，避免只因想法命中却让用户看不到搜索依据。
    private static func matchingSnippet(in text: String, keyword: String) -> String {
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKeyword.isEmpty,
              let matchRange = text.range(
                of: trimmedKeyword,
                options: [.caseInsensitive, .diacriticInsensitive],
                range: text.startIndex..<text.endIndex,
                locale: .current
              ) else {
            return text
        }

        let lowerBound = text.index(
            matchRange.lowerBound,
            offsetBy: -24,
            limitedBy: text.startIndex
        ) ?? text.startIndex
        let upperBound = text.index(
            matchRange.upperBound,
            offsetBy: 48,
            limitedBy: text.endIndex
        ) ?? text.endIndex
        let fragment = text[lowerBound..<upperBound]
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let prefix = lowerBound == text.startIndex ? "" : "…"
        let suffix = upperBound == text.endIndex ? "" : "…"
        return "\(prefix)\(fragment)\(suffix)"
    }
}

/// 字段优化输入页；请求成功后以独立结果 Sheet 展示差异，只有用户应用才修改本地草稿。
struct AIPromptOptimizationSheet: View {
    @Bindable var viewModel: AIPromptEditorViewModel

    @Environment(\.dismiss) private var dismiss
    @State private var optimizationTask: Task<Void, Never>?
    @State private var presentedResult: AIPromptOptimizationResultContext?
    @State private var isKeyboardPresented = false
    @State private var isInstructionFocused = false

    var body: some View {
        XMSheetScaffold(
            title: "优化\(String(localized: viewModel.activeField.displayTitle))",
            onClose: close,
            bottomBar: { optimizationActionBar }
        ) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                CardContainer(shape: ConcentricRectangle.xmSheetContentPanel) {
                    AIPromptOptimizationInstructionEditor(
                        text: $viewModel.optimizationInstruction,
                        isFocused: $isInstructionFocused,
                        isKeyboardPresented: $isKeyboardPresented,
                        isEnabled: !viewModel.isOptimizing,
                        placeholder: "描述你希望如何调整当前提示词，如精简表达、减少重复或补充要求"
                    )
                    .padding(Spacing.contentEdge)
                    .accessibilityLabel("调整期望")
                }

                if let error = viewModel.optimizationErrorMessage {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(AppTypography.footnote)
                        .foregroundStyle(Color.feedbackError)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Spacing.compact)
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.contentEdge)
        }
        .scrollDismissesKeyboard(.interactively)
        .presentationContentInteraction(isKeyboardPresented ? .scrolls : .automatic)
        .presentationDetents([.large])
        .sheet(item: $presentedResult) { result in
            AIPromptOptimizationResultSheet(
                viewModel: viewModel,
                result: result,
                onApplySucceeded: finishApplyingSuggestion
            )
            .presentationDetents([.large])
        }
        .onChange(of: viewModel.activeField) { _, _ in
            cancelOptimization()
        }
        .onDisappear(perform: cancelOptimization)
    }

    private var optimizationActionBar: some View {
        AIPromptSheetGlassActionButton(
            title: "开始优化",
            progressTitle: "优化中…",
            isEnabled: canStartOptimization,
            isProgressing: viewModel.isOptimizing,
            accessibilityHint: "根据调整期望优化当前提示词",
            action: startOptimization
        )
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.vertical, Spacing.cozy)
    }

    private var canStartOptimization: Bool {
        !viewModel.isOptimizing
            && !viewModel.optimizationInstruction
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty
    }

    /// Sheet 持有优化 Task；字段变化、关闭按钮或交互式下滑都会取消网络并使 request ID 失效。
    private func startOptimization() {
        guard canStartOptimization else { return }
        isInstructionFocused = false
        optimizationTask?.cancel()
        optimizationTask = Task { @MainActor in
            await viewModel.optimizeCurrentField()
            guard !Task.isCancelled,
                  let suggestion = viewModel.optimizationSuggestion else { return }
            presentedResult = AIPromptOptimizationResultContext(
                kind: viewModel.kind,
                field: viewModel.activeField,
                current: viewModel.optimizationSourceText ?? viewModel.currentText,
                suggestion: suggestion
            )
        }
    }

    private func close() {
        cancelOptimization()
        dismiss()
    }

    private func cancelOptimization() {
        optimizationTask?.cancel()
        optimizationTask = nil
        viewModel.cancelOptimization()
    }

    /// 先收起结果层，再在下一次主线程更新中关闭输入层，避免两层 Sheet 竞争同一次 dismiss。
    private func finishApplyingSuggestion() {
        presentedResult = nil
        Task { @MainActor in
            await Task.yield()
            dismiss()
        }
    }
}

/// 优化要求的轻量输入；编辑器按内容自适应高度，键盘手势统一交由 Sheet 唯一滚动容器处理。
private struct AIPromptOptimizationInstructionEditor: UIViewRepresentable {
    @Binding var text: String
    @Binding var isFocused: Bool
    @Binding var isKeyboardPresented: Bool

    let isEnabled: Bool
    let placeholder: String

    /// 创建系统多行编辑器；输入区与 Sheet 都使用系统交互式键盘策略。
    func makeUIView(context: Context) -> AIPromptOptimizationInstructionTextView {
        let textView = AIPromptOptimizationInstructionTextView()
        textView.delegate = context.coordinator
        textView.backgroundColor = .clear
        textView.isScrollEnabled = true
        textView.alwaysBounceVertical = true
        textView.keyboardDismissMode = .interactive
        textView.textContainerInset = .zero
        textView.textContainer.lineFragmentPadding = 0
        textView.adjustsFontForContentSizeCategory = true
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.textColor = .label
        textView.accessibilityLabel = "调整期望"
        textView.updatePlaceholder(
            placeholder,
            color: .placeholderText,
            font: UIFont.preferredFont(forTextStyle: .body)
        )
        textView.text = text
        textView.updatePlaceholderVisibility()
        textView.onKeyboardPresentationSettled = context.coordinator.updateKeyboardPresentation
        return textView
    }

    /// 同步文本、焦点和可编辑态；存在中文组合输入时不从 SwiftUI 反向覆盖。
    func updateUIView(
        _ textView: AIPromptOptimizationInstructionTextView,
        context: Context
    ) {
        context.coordinator.parent = self
        textView.onKeyboardPresentationSettled = context.coordinator.updateKeyboardPresentation
        textView.isEditable = isEnabled
        textView.isSelectable = isEnabled
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.textColor = .label
        textView.updatePlaceholder(
            placeholder,
            color: .placeholderText,
            font: UIFont.preferredFont(forTextStyle: .body)
        )

        if textView.markedTextRange == nil, textView.text != text {
            textView.text = text
            textView.updatePlaceholderVisibility()
        }

        if isFocused, !textView.isFirstResponder {
            DispatchQueue.main.async { [weak textView] in
                textView?.becomeFirstResponder()
            }
        } else if !isFocused, textView.isFirstResponder {
            textView.resignFirstResponder()
        }
        textView.observeOuterScrollIfNeeded()
    }

    /// 按当前 Dynamic Type 正文字号预留 8 行；更长内容继续增长并由 Sheet 外层滚动承载。
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: AIPromptOptimizationInstructionTextView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        let font = uiView.font ?? UIFont.preferredFont(forTextStyle: .body)
        let measuredHeight = uiView.sizeThatFits(
            CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        ).height
        return CGSize(
            width: width,
            height: max(measuredHeight, ceil(font.lineHeight * 8))
        )
    }

    /// 建立 UIKit delegate 桥接，回写正文和首响应者状态。
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: AIPromptOptimizationInstructionEditor

        init(parent: AIPromptOptimizationInstructionEditor) {
            self.parent = parent
        }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            (textView as? AIPromptOptimizationInstructionTextView)?
                .updatePlaceholderVisibility()
            textView.invalidateIntrinsicContentSize()
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.isFocused = true
            parent.isKeyboardPresented = true
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.isFocused = false
            parent.isKeyboardPresented = false
        }

        /// 系统交互手势完成后同步真实键盘位置；隐藏时再结束焦点，避免拖动中途切换 owner。
        func updateKeyboardPresentation(_ isPresented: Bool) {
            parent.isKeyboardPresented = isPresented
            if !isPresented {
                parent.isFocused = false
            }
        }
    }
}

/// 输入控件只持有 placeholder；不创建第二个纵向滚动 owner。
private final class AIPromptOptimizationInstructionTextView: UITextView {
    private let placeholderLabel = UILabel()
    private let observedOuterScrollViews = NSHashTable<UIScrollView>.weakObjects()
    var onKeyboardPresentationSettled: ((Bool) -> Void)?

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        placeholderLabel.numberOfLines = 0
        placeholderLabel.isUserInteractionEnabled = false
        addSubview(placeholderLabel)
        panGestureRecognizer.addTarget(self, action: #selector(handlePanState(_:)))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        observeOuterScrollIfNeeded()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let size = placeholderLabel.sizeThatFits(
            CGSize(width: max(bounds.width, 0), height: CGFloat.greatestFiniteMagnitude)
        )
        placeholderLabel.frame = CGRect(origin: .zero, size: size)
        observeOuterScrollIfNeeded()
    }

    /// 让输入框 pan 等待 Sheet ScrollView，并在系统手势结束后同步键盘位置。
    func observeOuterScrollIfNeeded() {
        var ancestor = superview
        while let current = ancestor {
            if let scrollView = current as? UIScrollView,
               scrollView !== self,
               !observedOuterScrollViews.contains(scrollView) {
                panGestureRecognizer.require(toFail: scrollView.panGestureRecognizer)
                scrollView.panGestureRecognizer.addTarget(
                    self,
                    action: #selector(handlePanState(_:))
                )
                observedOuterScrollViews.add(scrollView)
            }
            ancestor = current.superview
        }
    }

    /// 同步 placeholder 外观，不将 hint 写入正文存储。
    func updatePlaceholder(_ text: String, color: UIColor, font: UIFont) {
        placeholderLabel.text = text
        placeholderLabel.textColor = color
        placeholderLabel.font = font
        setNeedsLayout()
        updatePlaceholderVisibility()
    }

    /// 仅在正文为空时显示 hint。
    func updatePlaceholderVisibility() {
        placeholderLabel.isHidden = !text.isEmpty
    }

    @objc
    private func handlePanState(_ recognizer: UIPanGestureRecognizer) {
        guard recognizer.state == .ended || recognizer.state == .cancelled else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, let window else { return }
            let keyboardFrame = window.keyboardLayoutGuide.layoutFrame
            let keyboardHeight = keyboardFrame.height
            let isPresented = keyboardHeight > window.safeAreaInsets.bottom + 1
            onKeyboardPresentationSettled?(isPresented)
        }
    }
}

/// 优化结果的稳定展示快照；应用失败时仍保留差异上下文，不依赖 ViewModel 清理后的建议状态。
private struct AIPromptOptimizationResultContext: Identifiable {
    let id = UUID()
    let kind: AIPromptKind
    let field: AIPromptEditorField
    let current: String
    let suggestion: String
}

/// 独立结果 Sheet 持有差异、应用错误与固定主操作；关闭只返回优化输入层。
private struct AIPromptOptimizationResultSheet: View {
    @Bindable var viewModel: AIPromptEditorViewModel
    let result: AIPromptOptimizationResultContext
    let onApplySucceeded: () -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        XMSheetScaffold(
            title: "优化结果",
            onClose: { dismiss() },
            bottomBar: { resultActionBar }
        ) {
            VStack(alignment: .leading, spacing: Spacing.base) {
                if let error = viewModel.optimizationErrorMessage {
                    XMInlineStatusBanner(error, tone: .error)
                }

                CardContainer(shape: ConcentricRectangle.xmSheetContentPanel) {
                    AIPromptCompactDiffView(
                        current: result.current,
                        suggestion: result.suggestion,
                        kind: result.kind,
                        field: result.field
                    )
                    .padding(Spacing.contentEdge)
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.contentEdge)
        }
    }

    private var resultActionBar: some View {
        AIPromptSheetGlassActionButton(
            title: "应用修改",
            progressTitle: "应用中…",
            isEnabled: viewModel.optimizationSuggestion != nil,
            isProgressing: false,
            accessibilityHint: "将优化结果应用到当前提示词",
            action: applySuggestion
        )
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.vertical, Spacing.cozy)
    }

    /// 继续调用现有草稿应用入口；失败保留结果 Sheet，成功才由输入层统一关闭两层。
    private func applySuggestion() {
        guard viewModel.applyOptimizationSuggestion() else { return }
        onApplySucceeded()
    }
}

/// 提示词优化流程私有的单一玻璃主操作；交互形变完全交给 iOS 26 regular glass。
private struct AIPromptSheetGlassActionButton: View {
    let title: String
    let progressTitle: String
    let isEnabled: Bool
    let isProgressing: Bool
    let accessibilityHint: String
    let action: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if usesPrimaryAppearance {
                actionButton
                    .glassEffect(
                        .regular
                            .tint(Color.primaryActionFill)
                            .interactive(isGlassInteractive),
                        in: .capsule
                    )
            } else {
                actionButton
                    .glassEffect(
                        .regular
                            .tint(Color.buttonDisabled)
                            .interactive(false),
                        in: .capsule
                    )
            }
        }
    }

    private var actionButton: some View {
        Button {
            guard isEnabled, !isProgressing else { return }
            action()
        } label: {
            HStack(spacing: Spacing.cozy) {
                if isProgressing {
                    ProgressView()
                        .controlSize(.small)
                        .tint(foregroundColor)
                        .accessibilityHidden(true)
                }

                Text(isProgressing ? progressTitle : title)
            }
            .font(AppTypography.bodyMedium)
            .foregroundStyle(foregroundColor)
            .frame(
                maxWidth: .infinity,
                minHeight: InteractionMetrics.minimumTouchTarget
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .controlSize(.extraLarge)
        .disabled(!isEnabled || isProgressing)
        .accessibilityLabel(isProgressing ? progressTitle : title)
        .accessibilityHint(accessibilityHint)
    }

    private var usesPrimaryAppearance: Bool {
        isEnabled || isProgressing
    }

    private var foregroundColor: Color {
        usesPrimaryAppearance
            ? .primaryActionForeground
            : .buttonDisabledForeground
    }

    private var isGlassInteractive: Bool {
        isEnabled && !isProgressing && !reduceMotion
    }
}

/// 只展示最长公共前后文之间的删除与新增片段，避免把两份长提示词并排形成视觉噪音。
private struct AIPromptCompactDiffView: View {
    let current: String
    let suggestion: String
    let kind: AIPromptKind
    let field: AIPromptEditorField

    var body: some View {
        let difference = compactDifference
        VStack(alignment: .leading, spacing: Spacing.base) {
            if difference.removed.isEmpty && difference.added.isEmpty {
                Text("没有文字变化")
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Color.textSecondary)
            } else {
                if !difference.removed.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.cozy) {
                        Label("删除", systemImage: "minus")
                            .font(AppTypography.captionSemibold)
                            .foregroundStyle(Color.feedbackError)
                        AIPromptReadOnlyTokenTextView(
                            text: difference.removed,
                            kind: kind,
                            field: field,
                            style: .removed
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }

                if !difference.removed.isEmpty && !difference.added.isEmpty {
                    Rectangle()
                        .fill(Color.surfaceDividerSubtle)
                        .frame(height: StrokeWidth.hairline)
                        .accessibilityHidden(true)
                }

                if !difference.added.isEmpty {
                    VStack(alignment: .leading, spacing: Spacing.cozy) {
                        Label("新增", systemImage: "plus")
                            .font(AppTypography.captionSemibold)
                            .foregroundStyle(Color.feedbackSuccess)
                        AIPromptReadOnlyTokenTextView(
                            text: difference.added,
                            kind: kind,
                            field: field,
                            style: .added
                        )
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private var compactDifference: (removed: String, added: String) {
        let oldCharacters = Array(current)
        let newCharacters = Array(suggestion)
        var prefixCount = 0
        while prefixCount < min(oldCharacters.count, newCharacters.count),
              oldCharacters[prefixCount] == newCharacters[prefixCount] {
            prefixCount += 1
        }

        var suffixCount = 0
        while suffixCount < oldCharacters.count - prefixCount,
              suffixCount < newCharacters.count - prefixCount,
              oldCharacters[oldCharacters.count - suffixCount - 1]
                == newCharacters[newCharacters.count - suffixCount - 1] {
            suffixCount += 1
        }

        let oldEnd = oldCharacters.count - suffixCount
        let newEnd = newCharacters.count - suffixCount
        return (
            String(oldCharacters[prefixCount..<oldEnd]),
            String(newCharacters[prefixCount..<newEnd])
        )
    }
}
