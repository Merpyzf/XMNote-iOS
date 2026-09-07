/**
 * [INPUT]: 依赖 AIPromptEditorViewModel、AIPromptTrialSessionViewModel、NoteRepositoryProtocol、XMBookCover、AI 生成等待反馈、标准 Sheet/搜索/状态组件、系统交互式玻璃反馈、提示词变量只读渲染器与流式 Markdown 渲染器
 * [OUTPUT]: 对外提供提示词请求预览、可编辑书摘流式试运行、AI 标签 JSON/格式化双层结果与可中断展开反馈、本地书摘选择，以及单一 Sheet 内推进的字段优化流程，品牌操作前景随外观配对
 * [POS]: Views/Personal/Sheets 的提示词编辑次级任务集合，由 AIPromptEditorView 的 item-driven Sheet 路由消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 展示本次即将发送的最终提示词，并按需补充应用规则与响应格式。
struct AIPromptPreviewSheet: View {
    let preview: AIPromptRequestPreview

    @Environment(\.dismiss) private var dismiss
    @State private var showsApplicationRules = false

    var body: some View {
        XMSheetScaffold(
            title: "发送内容预览",
            onClose: { dismiss() }
        ) {
            VStack(alignment: .leading, spacing: Spacing.double) {
                promptSection(
                    title: "系统提示词",
                    content: preview.systemPrompt
                )

                promptSection(
                    title: "用户提示词（变量已替换）",
                    content: preview.userPrompt
                )

                DisclosureGroup("查看应用规则", isExpanded: $showsApplicationRules) {
                    VStack(alignment: .leading, spacing: Spacing.base) {
                        detailSection(
                            title: "应用规则",
                            content: preview.applicationRules
                        )

                        if preview.expectsJSON {
                            detailSection(
                                title: "响应格式",
                                content: "JSON"
                            )
                        }
                    }
                    .padding(.top, Spacing.half)
                }
                .font(AppTypography.body)
                .foregroundStyle(Color.textPrimary)
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.contentEdge)
        }
    }

    /// 以统一标题和正文层级展示一次最终发送的提示词，保留复制能力。
    private func promptSection(
        title: LocalizedStringResource,
        content: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text(title)
                .font(AppTypography.headline)
                .foregroundStyle(Color.textPrimary)
                .accessibilityAddTraits(.isHeader)

            Text(content)
                .font(AppTypography.body)
                .foregroundStyle(Color.textPrimary)
                .lineSpacing(Spacing.compact)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 以次级标题区分附加规则，避免把提示词主体再次复制到展开区域。
    private func detailSection(
        title: LocalizedStringResource,
        content: String
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            Text(title)
                .font(AppTypography.subheadlineSemibold)
                .foregroundStyle(Color.textSecondary)

            Text(content)
                .font(AppTypography.body)
                .foregroundStyle(Color.textPrimary)
                .lineSpacing(Spacing.compact)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
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
    @FocusState private var isExcerptFocused: Bool

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
                isExcerptFocused: $isExcerptFocused,
                onChooseExcerpt: {
                    isExcerptFocused = false
                    activeSheet = .excerptPicker
                }
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
        .scrollDismissesKeyboard(.interactively)
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
            isExcerptFocused = false
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
        .foregroundStyle(Color.primaryActionForeground)
        .buttonStyle(.glassProminent)
        .controlSize(.extraLarge)
        .tint(Color.appTint)
        .disabled(!session.hasStarted && !session.canStart)
        .accessibilityHint(preparationActionHint)
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.vertical, Spacing.cozy)
    }

    private var preparationActionTitle: String {
        if session.isRunning { return String(localized: "查看生成进度") }
        return session.hasStarted
            ? String(localized: "查看结果")
            : String(localized: "生成结果")
    }

    private var preparationActionHint: String {
        if session.hasStarted {
            return session.isRunning ? "打开正在生成的测试结果" : "打开已生成的测试结果"
        }
        return session.startDisabledReason
            ?? String(localized: "使用当前书摘生成测试结果")
    }

    /// 已有任务只恢复结果页；首次运行在 Push 前建立 connecting 状态，避免目的页出现空白帧。
    private func handlePreparationAction() {
        if session.hasStarted {
            showsResult = true
            return
        }
        isExcerptFocused = false
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
        isExcerptFocused = false
        session.cancelAndDiscard()
        dismiss()
    }
}

/// 测试准备页只承载书摘输入与选择入口；结果和对照控制不进入该信息层级。
private struct AIPromptTrialPreparationView: View {
    @Bindable var session: AIPromptTrialSessionViewModel
    @Binding var excerptSelection: TextSelection?
    @FocusState.Binding var isExcerptFocused: Bool
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
                    .focused($isExcerptFocused)
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        XMScrollEdgeChrome(
            presentation: .overlaySoft,
            edges: chromeEdges,
            topBar: {
                if session.comparesDefault {
                    resultPicker
                }
            },
            bottomBar: {
                if !session.isRunning {
                    resultActionBar
                        .transition(resultActionTransition)
                }
            },
            content: { resultScrollView }
        )
        .animation(
            reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.28),
            value: session.isRunning
        )
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.2),
            value: session.errorMessage != nil
        )
        .background(Color.surfaceSheet.ignoresSafeArea())
        .navigationTitle("测试结果")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var chromeEdges: Edge.Set {
        var edges = Edge.Set()
        if session.comparesDefault {
            edges.insert(.top)
        }
        if !session.isRunning {
            edges.insert(.bottom)
        }
        return edges
    }

    private var resultActionTransition: AnyTransition {
        if reduceMotion {
            return .opacity
        }
        return .move(edge: .bottom).combined(with: .opacity)
    }

    private var resultPicker: some View {
        Picker("结果来源", selection: $session.selectedResultTarget) {
            Text("当前提示词").tag(AIPromptTrialTarget.current)
            Text("原始提示词").tag(AIPromptTrialTarget.appDefault)
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
                title: "无法生成结果",
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
            Text("重新生成")
                .frame(maxWidth: .infinity)
        }
        .foregroundStyle(Color.primaryActionForeground)
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
            : "应用原始提示词生成结果"
    }
}

/// 两个试运行结果在同一内容区域水平分页，当前页高度随流式 Markdown 实际内容更新。
private struct AIPromptTrialResultPager: View {
    @Bindable var session: AIPromptTrialSessionViewModel
    let currentController: AIMarkdownInteractionController
    let defaultController: AIMarkdownInteractionController
    @Binding var pageHeights: [AIPromptTrialTarget: CGFloat]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.28),
            value: session.selectedResultTarget
        )
        .onAppear {
            var transaction = Transaction()
            transaction.animation = nil
            withTransaction(transaction) {
                scrollTarget = session.selectedResultTarget
            }
        }
        .onChange(of: session.selectedResultTarget) { _, newValue in
            guard scrollTarget != newValue else { return }
            var transaction = Transaction()
            transaction.animation = reduceMotion
                ? nil
                : HorizontalPagingMotion.programmaticScroll
            withTransaction(transaction) {
                scrollTarget = newValue
            }
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

/// 不携带流式正文的稳定展示阶段，避免每个 token 重启结构动画。
private enum AIPromptTrialPresentationStage: Equatable {
    case idle
    case waiting
    case markdown
    case autoTags
    case failure
}

/// 单个目标的流式结果展示；同类内容保持视图身份，只对结构阶段做局部过渡。
private struct AIPromptTrialResultPage: View {
    let target: AIPromptTrialTarget
    let phase: AIPromptTrialPhase
    let interactionController: AIMarkdownInteractionController

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var loadingGate = LoadingGate()

    var body: some View {
        resultContent
            .animation(structuralAnimation, value: presentationStage)
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
        switch presentationStage {
        case .idle:
            Text("尚未生成")
                .font(AppTypography.footnote)
                .foregroundStyle(Color.textSecondary)
                .frame(
                    maxWidth: .infinity,
                    minHeight: InteractionMetrics.minimumTouchTarget,
                    alignment: .leading
                )
                .transition(.opacity)
        case .waiting:
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
                .transition(.opacity)
            } else {
                Color.clear
                    .frame(
                        maxWidth: .infinity,
                        minHeight: InteractionMetrics.minimumTouchTarget
                    )
            }
        case .markdown:
            VStack(alignment: .leading, spacing: Spacing.base) {
                markdownView(phase.content, isStreaming: phase.isStreaming)

                if let partialFailureMessage {
                    XMInlineStatusBanner(
                        "生成中断：\(partialFailureMessage)",
                        tone: .error
                    )
                    .transition(.opacity)
                }
            }
            .animation(structuralAnimation, value: partialFailureMessage)
            .transition(.opacity)
        case .autoTags:
            switch phase {
            case .completedAutoTags(let rawJSON, let suggestions):
                AIPromptTrialAutoTagResultView(
                    suggestions: suggestions,
                    rawJSON: rawJSON,
                    interactionController: interactionController
                )
                .transition(.opacity)
            case .invalidAutoTags(let rawJSON):
                AIPromptTrialAutoTagResultView(
                    suggestions: nil,
                    rawJSON: rawJSON,
                    interactionController: interactionController
                )
                .transition(.opacity)
            default:
                EmptyView()
            }
        case .failure:
            XMCompactStateView(
                role: .failure,
                title: "\(targetTitle)生成失败",
                message: emptyFailureMessage
            )
            .transition(.opacity)
        }
    }

    private var targetTitle: String {
        target == .current ? "当前提示词" : "原始提示词"
    }

    private var presentationStage: AIPromptTrialPresentationStage {
        switch phase {
        case .idle:
            .idle
        case .connecting:
            .waiting
        case .streaming, .completed:
            .markdown
        case .completedAutoTags, .invalidAutoTags:
            .autoTags
        case .failed(_, let partialContent):
            partialContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? .failure
                : .markdown
        }
    }

    private var partialFailureMessage: String? {
        guard case .failed(let message, let partialContent) = phase,
              !partialContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return message
    }

    private var emptyFailureMessage: String? {
        guard case .failed(let message, _) = phase else { return nil }
        return message
    }

    private var structuralAnimation: Animation {
        reduceMotion
            ? .easeOut(duration: 0.12)
            : .smooth(duration: 0.2)
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

/// AI 标签完成态使用无卡只读列表，原始 JSON 作为可展开的次级事实来源。
private struct AIPromptTrialAutoTagResultView: View {
    let suggestions: [AIAutoTagSuggestion]?
    let rawJSON: String
    let interactionController: AIMarkdownInteractionController

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsRawJSON = false

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.none) {
            formattedContent

            Divider()

            rawJSONDisclosure
        }
    }

    private var rawJSONDisclosure: some View {
        VStack(alignment: .leading, spacing: Spacing.none) {
            Button(action: toggleRawJSON) {
                HStack(spacing: Spacing.base) {
                    Text("原始 JSON")
                        .font(AppTypography.subheadline)
                        .foregroundStyle(Color.textPrimary)

                    Spacer(minLength: Spacing.base)

                    Image(systemName: "chevron.right")
                        .font(AppTypography.captionSemibold)
                        .foregroundStyle(Color.iconSecondary)
                        .rotationEffect(.degrees(showsRawJSON ? 90 : 0))
                        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: showsRawJSON)
                        .accessibilityHidden(true)
                }
                .frame(
                    maxWidth: .infinity,
                    minHeight: InteractionMetrics.minimumTouchTarget,
                    alignment: .leading
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("原始 JSON")
            .accessibilityValue(showsRawJSON ? "已展开" : "已收起")

            if showsRawJSON {
                AIMarkdownResultView(
                    markdown: rawJSONMarkdown,
                    isStreaming: false,
                    interactionController: interactionController
                )
                .padding(.top, Spacing.compact)
                .transition(rawJSONTransition)
            }
        }
    }

    @ViewBuilder
    private var formattedContent: some View {
        if let suggestions {
            if suggestions.isEmpty {
                Text("没有推荐标签")
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Color.textSecondary)
            } else {
                VStack(spacing: Spacing.none) {
                    ForEach(suggestions) { suggestion in
                        AIPromptTrialAutoTagRow(suggestion: suggestion)

                        if suggestion.id != suggestions.last?.id {
                            Divider()
                        }
                    }
                }
            }
        } else {
            XMInlineStatusBanner(
                "标签结果格式有误",
                tone: .warning
            )
        }
    }

    /// 代码围栏只负责原样排版；会话中的 rawJSON 不被重新序列化或覆盖。
    private var rawJSONMarkdown: String {
        "```json\n\(rawJSON)\n```"
    }

    private var rawJSONTransition: AnyTransition {
        reduceMotion
            ? .opacity
            : .opacity.combined(with: .offset(y: -Spacing.half))
    }

    /// 展开状态由本地按钮即时写入；结构与箭头均可从当前可见位置被反向打断。
    private func toggleRawJSON() {
        withAnimation(
            reduceMotion
                ? .easeOut(duration: 0.12)
                : .smooth(duration: 0.26)
        ) {
            showsRawJSON.toggle()
        }
    }
}

/// AI 标签试运行的只读行；Sparkles 与正式页一致，只标记应用后新建的标签。
private struct AIPromptTrialAutoTagRow: View {
    let suggestion: AIAutoTagSuggestion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.half) {
                Text(verbatim: suggestion.name)
                    .font(AppTypography.bodyMedium)
                    .foregroundStyle(Color.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)

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
                Text(verbatim: reasonText)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: InteractionMetrics.minimumTouchTarget,
            alignment: .leading
        )
        .padding(.vertical, Spacing.cozy)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(verbatim: suggestion.name))
        .accessibilityValue(Text(verbatim: accessibilityValue))
    }

    private var reasonText: String? {
        let reason = suggestion.reason.trimmingCharacters(in: .whitespacesAndNewlines)
        return reason.isEmpty ? nil : reason
    }

    private var accessibilityValue: String {
        let source = suggestion.isExisting ? "直接复用" : "应用后新建"
        guard let reasonText else { return source }
        return "\(source)，\(reasonText)"
    }
}

/// 本地书摘单选 Sheet；搜索、分页和错误状态由页面专属 ViewModel 持有，选择后立即返回快照。
private struct AIPromptExcerptPickerSheet: View {
    /// 书摘列表的稳定结构阶段，搜索词与分页更新不参与阶段动画。
    private enum PresentationKind: Equatable {
        case loading
        case failure
        case empty
        case noResults
        case content
    }

    let selectedNoteID: Int64?
    let onSelect: (NoteExcerptListItem) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
            onClose: {
                isSearchActive = false
                dismiss()
            },
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
                .animation(
                    reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.2),
                    value: presentationKind
                )
        }
        .scrollDismissesKeyboard(.immediately)
        .presentationDetents([.large])
        .onAppear(perform: viewModel.start)
        .onDisappear(perform: viewModel.cancel)
    }

    @ViewBuilder
    private var pickerContent: some View {
        if viewModel.items.isEmpty, viewModel.isLoading {
            LoadingStateView("正在读取书摘…", style: .inline)
                .frame(maxWidth: .infinity, minHeight: 320)
                .transition(.opacity)
        } else if viewModel.items.isEmpty, let error = viewModel.errorMessage {
            XMContentStateView(
                role: .failure,
                title: "暂时无法读取书摘",
                message: error,
                action: XMStateAction("重试", perform: viewModel.retry)
            )
            .frame(minHeight: 320)
            .transition(.opacity)
        } else if viewModel.items.isEmpty {
            XMContentStateView(
                role: viewModel.isSearching ? .noResults : .empty,
                title: viewModel.isSearching ? "没有匹配的书摘" : "暂无可选书摘"
            )
            .frame(minHeight: 320)
            .transition(.opacity)
        } else {
            LazyVStack(spacing: Spacing.none) {
                if viewModel.retainedErrorMessage != nil {
                    XMInlineStatusBanner(
                        "书摘列表未更新",
                        tone: .error,
                        action: XMStateAction("重试", perform: viewModel.retry)
                    )
                    .padding(.bottom, Spacing.base)
                    .transition(.opacity)
                }

                ForEach(viewModel.items) { item in
                    AIPromptExcerptPickerRow(
                        item: item,
                        query: viewModel.query,
                        isSelected: item.id == selectedNoteID,
                        onSelect: {
                            isSearchActive = false
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
                    if viewModel.isLoading {
                        HStack(spacing: Spacing.cozy) {
                            ProgressView()
                                .controlSize(.small)
                            Text("正在载入更多…")
                                .font(AppTypography.footnote)
                                .foregroundStyle(Color.textSecondary)
                        }
                        .frame(maxWidth: .infinity, minHeight: InteractionMetrics.minimumTouchTarget)
                    }
                }
            }
            .animation(
                reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.18),
                value: viewModel.retainedErrorMessage != nil
            )
            .transition(.opacity)
        }
    }

    private var presentationKind: PresentationKind {
        if viewModel.items.isEmpty, viewModel.isLoading {
            return .loading
        }
        if viewModel.items.isEmpty, viewModel.errorMessage != nil {
            return .failure
        }
        if viewModel.items.isEmpty {
            return viewModel.isSearching ? .noResults : .empty
        }
        return .content
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
        .accessibilityHint(isSelectable ? "选择此书摘用于提示词测试" : "没有正文，无法测试")
    }

    private var excerptContent: some View {
        XMKeywordHighlighting.text(
            isSelectable ? excerptText : "没有正文，无法测试",
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
        var values = [isSelectable ? excerptText : "没有正文，无法测试"]
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

/// 字段优化输入页；请求成功后在同一 Sheet 内推进到差异页，只有用户应用才修改本地草稿。
struct AIPromptOptimizationSheet: View {
    @Bindable var viewModel: AIPromptEditorViewModel

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var optimizationTask: Task<Void, Never>?
    @State private var resultContext: AIPromptOptimizationResultContext?
    @State private var showsResult = false
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
                        placeholder: optimizationPlaceholder
                    )
                    .padding(Spacing.contentEdge)
                    .accessibilityLabel("优化方向")
                    .accessibilityHint(Text(verbatim: optimizationPlaceholder))
                }

                if let error = viewModel.optimizationErrorMessage {
                    Label(error, systemImage: "exclamationmark.circle")
                        .font(AppTypography.footnote)
                        .foregroundStyle(Color.feedbackError)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.horizontal, Spacing.compact)
                        .transition(.opacity)
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, Spacing.contentEdge)
            .animation(
                reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.18),
                value: viewModel.optimizationErrorMessage != nil
            )
            .navigationDestination(isPresented: $showsResult) {
                if let resultContext {
                    AIPromptOptimizationResultPage(
                        viewModel: viewModel,
                        result: resultContext,
                        onApplySucceeded: finishApplyingSuggestion
                    )
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .presentationContentInteraction(isKeyboardPresented ? .scrolls : .automatic)
        .presentationDetents([.large])
        .onChange(of: viewModel.activeField) { _, _ in
            cancelOptimization()
        }
        .onDisappear(perform: cancelOptimization)
    }

    private var optimizationActionBar: some View {
        AIPromptSheetGlassActionButton(
            title: String(localized: "优化"),
            progressTitle: String(localized: "优化中…"),
            isEnabled: canStartOptimization,
            isProgressing: viewModel.isOptimizing,
            accessibilityHint: String(localized: "根据输入的方向优化当前提示词"),
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

    private var optimizationPlaceholder: String {
        let resource: LocalizedStringResource = switch (viewModel.kind, viewModel.activeField) {
        case (.noteExplanation, .taskTemplate):
            "例如：减少延伸内容，重点解释书摘本身"
        case (.noteExplanation, .roleRules):
            "例如：用更通俗的中文回答，每段更短"
        case (.wordLookup, .taskTemplate):
            "例如：先解释选中的文字，再结合书摘上下文说明"
        case (.wordLookup, .roleRules):
            "例如：多义词分别说明，并给出简短例句"
        case (.autoTag, .taskTemplate):
            "例如：优先复用已有标签，只保留与书摘主题直接相关的标签"
        case (.autoTag, .roleRules):
            "例如：避免人物、书名和一次性细节，最多推荐 3 个标签"
        }
        return String(localized: resource)
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
            resultContext = AIPromptOptimizationResultContext(
                kind: viewModel.kind,
                field: viewModel.activeField,
                current: viewModel.optimizationSourceText ?? viewModel.currentText,
                suggestion: suggestion
            )
            showsResult = true
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

    /// 应用后一次关闭整个优化 Sheet，避免结果页与输入页重复退场。
    private func finishApplyingSuggestion() {
        dismiss()
    }
}

/// 优化方向的轻量输入；编辑器按内容自适应高度，键盘手势统一交由 Sheet 唯一滚动容器处理。
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
        textView.accessibilityLabel = String(localized: "优化方向")
        textView.accessibilityHint = placeholder
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
        textView.accessibilityLabel = String(localized: "优化方向")
        textView.accessibilityHint = placeholder

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

/// 同一 Sheet 内的优化结果页；系统返回保留输入，应用成功才退出整个流程。
private struct AIPromptOptimizationResultPage: View {
    @Bindable var viewModel: AIPromptEditorViewModel
    let result: AIPromptOptimizationResultContext
    let onApplySucceeded: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        XMScrollEdgeChrome(
            presentation: .overlaySoft,
            edges: .bottom,
            bottomBar: { resultActionBar }
        ) {
            ScrollView {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    if let error = viewModel.optimizationErrorMessage {
                        XMInlineStatusBanner(error, tone: .error)
                            .transition(.opacity)
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
                .padding(.top, Spacing.cozy)
                .padding(.bottom, Spacing.double)
                .animation(
                    reduceMotion ? .easeOut(duration: 0.12) : .smooth(duration: 0.18),
                    value: viewModel.optimizationErrorMessage != nil
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .scrollIndicators(.hidden)
            .scrollBounceBehavior(.always)
        }
        .background(Color.surfaceSheet.ignoresSafeArea())
        .navigationTitle("优化结果")
        .navigationBarTitleDisplayMode(.inline)
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

    /// 继续调用现有草稿应用入口；失败保留结果页，成功才退出优化流程。
    private func applySuggestion() {
        guard viewModel.applyOptimizationSuggestion() else { return }
        onApplySucceeded()
    }
}

/// 提示词优化流程私有的单一玻璃主操作；按压与辅助功能适配交给系统，不把减少动态效果当作禁用。
private struct AIPromptSheetGlassActionButton: View {
    let title: String
    let progressTitle: String
    let isEnabled: Bool
    let isProgressing: Bool
    let accessibilityHint: String
    let action: () -> Void

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
        isEnabled && !isProgressing
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
                Text("没有可应用的修改")
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
