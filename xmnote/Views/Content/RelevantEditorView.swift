/**
 * [INPUT]: 依赖 RepositoryContainer 注入内容/S3/OCR/图片额度仓储，依赖 AppState 提供会员状态，依赖 RelevantEditorMode 与 RelevantEditorViewModel 驱动 create/edit 双模式，依赖 RichTextEditor、ContentEditorImageSection、LoadingGate、XMSystemAlert 复用既有交互
 * [OUTPUT]: 对外提供 RelevantEditorView，承接相关内容新建/编辑、自动草稿恢复/保留退出、URL、图片/OCR 与真实主键原子保存
 * [POS]: Content 模块相关内容编辑壳层，被书籍分类入口和通用 viewer 的编辑动作推入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 相关内容编辑页，以统一模式兼容新建与既有主键编辑入口。
struct RelevantEditorView: View {
    let mode: RelevantEditorMode
    let navigationContext: AppTaskNavigationContext

    @Environment(RepositoryContainer.self) private var repositories
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: RelevantEditorViewModel?
    @State private var bootstrapLoadingGate = LoadingGate()

    private let onSaved: (Int64) -> Void

    /// 通过统一模式建立相关内容编辑页；保存回调返回数据库中的真实主键。
    init(
        mode: RelevantEditorMode,
        onSaved: @escaping (Int64) -> Void = { _ in },
        navigationContext: AppTaskNavigationContext = .taskChild
    ) {
        self.mode = mode
        self.onSaved = onSaved
        self.navigationContext = navigationContext
    }

    /// 兼容既有只传相关内容主键的编辑路由。
    init(
        contentId: Int64,
        onSaved: @escaping (Int64) -> Void = { _ in },
        navigationContext: AppTaskNavigationContext = .taskChild
    ) {
        self.init(
            mode: .edit(contentID: contentId),
            onSaved: onSaved,
            navigationContext: navigationContext
        )
    }

    /// 为书籍分类页提供明确的新建入口。
    init(
        bookId: Int64,
        categoryId: Int64,
        onSaved: @escaping (Int64) -> Void = { _ in },
        navigationContext: AppTaskNavigationContext = .taskChild
    ) {
        self.init(
            mode: .create(bookID: bookId, categoryID: categoryId),
            onSaved: onSaved,
            navigationContext: navigationContext
        )
    }

    var body: some View {
        ZStack {
            if let viewModel {
                RelevantEditorLoadedView(
                    viewModel: viewModel,
                    navigationContext: navigationContext
                ) { contentID in
                    onSaved(contentID)
                    dismiss()
                }
            } else {
                Color.surfacePage.ignoresSafeArea()
                if bootstrapLoadingGate.isVisible {
                    LoadingStateView("正在准备相关内容…", style: .card)
                }
            }
        }
        .task {
            guard viewModel == nil else { return }
            bootstrapLoadingGate.update(intent: .read)
            let newViewModel = RelevantEditorViewModel(
                mode: mode,
                repository: repositories.contentRepository,
                s3UploadRepository: repositories.s3UploadRepository,
                quotaRepository: repositories.noteImageUploadQuotaRepository,
                isPremium: appState.isPremium
            )
            viewModel = newViewModel
            bootstrapLoadingGate.update(intent: .none)
            await newViewModel.load()
        }
        .onDisappear {
            bootstrapLoadingGate.hideImmediately()
        }
    }
}

/// 相关内容草稿加载后的编辑内容，集中承接脏表单返回保护与写操作反馈。
private struct RelevantEditorLoadedView: View {
    @Bindable var viewModel: RelevantEditorViewModel
    let navigationContext: AppTaskNavigationContext
    let onSaved: (Int64) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @Environment(RepositoryContainer.self) private var repositories
    @Environment(AppState.self) private var appState

    @State private var activeAlert: RelevantEditorAlert?
    @State private var readLoadingGate = LoadingGate()

    var body: some View {
        ZStack {
            Color.surfacePage.ignoresSafeArea()

            editorPhase

            if viewModel.isSaving {
                Color.overlay.ignoresSafeArea()
                LoadingStateView("正在保存相关内容…", style: .card)
                    .transition(.opacity)
            } else if readLoadingGate.isVisible {
                LoadingStateView("正在加载相关内容草稿…", style: .card)
                    .transition(.opacity)
            }
        }
        .navigationTitle(viewModel.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .navigationBarBackButtonHidden(true)
        .navigationPopGuard(
            canPop: !viewModel.hasUnsavedChanges && !viewModel.isSaving,
            onBlockedAttempt: handleDismissAttempt
        )
        .toolbar { toolbarContent }
        .interactiveDismissDisabled(viewModel.hasUnsavedChanges || viewModel.isSaving)
        .xmSystemAlert(item: $activeAlert, descriptor: alertDescriptor)
        .onAppear {
            syncReadLoadingVisibility()
        }
        .onChange(of: viewModel.isLoading) { _, _ in
            syncReadLoadingVisibility()
        }
        .onChange(of: viewModel.errorMessage) { _, message in
            guard let message, !message.isEmpty else { return }
            activeAlert = .message(message)
        }
        .onChange(of: viewModel.imageErrorMessage) { _, message in
            guard let message, !message.isEmpty else { return }
            activeAlert = .imageMessage(message)
        }
        .onChange(of: viewModel.pendingRecoveredDraft?.savedTime) { _, savedTime in
            guard let savedTime else { return }
            activeAlert = .recovery(Self.autoSaveTimeDescription(savedTime))
        }
        .onChange(of: appState.isPremium) { _, isPremium in
            Task { await viewModel.updatePremiumStatus(isPremium) }
        }
        .onDisappear {
            readLoadingGate.hideImmediately()
        }
        .animation(editorAnimation, value: viewModel.draft != nil)
        .animation(.smooth(duration: 0.12), value: viewModel.isSaving)
    }

    @ViewBuilder
    private var editorPhase: some View {
        if let draft = viewModel.draft {
            RelevantEditorForm(
                viewModel: viewModel,
                draft: draft,
                ocrRepository: repositories.ocrRepository,
                onTransferError: { activeAlert = .imageMessage($0) }
            )
            .transition(editorTransition)
        } else if let errorMessage = viewModel.errorMessage, !viewModel.isLoading {
            viewerMessageCard(text: errorMessage)
                .padding(Spacing.screenEdge)
                .transition(.opacity)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            if navigationContext == .modalRoot {
                Button("取消", action: handleDismissAttempt)
            } else {
                TopBarBackButton(action: handleDismissAttempt)
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            Button(viewModel.isSaving ? "保存中…" : "保存", action: save)
                .disabled(viewModel.draft == nil || viewModel.isLoading || viewModel.isSaving)
        }
    }

    private var editorAnimation: Animation {
        reduceMotion ? .smooth(duration: 0.12) : .smooth(duration: 0.28)
    }

    private var editorTransition: AnyTransition {
        reduceMotion ? .opacity : .move(edge: .bottom).combined(with: .opacity)
    }

    /// 启动一次保存任务；ViewModel 负责竞态门闩，成功后把真实主键交还上层并退出。
    private func save() {
        Task {
            guard let contentID = await viewModel.save() else { return }
            onSaved(contentID)
        }
    }

    /// 根据保存中与脏状态决定直接返回或请求用户确认。
    private func handleDismissAttempt() {
        guard !viewModel.isSaving else { return }
        if viewModel.hasUnsavedChanges {
            activeAlert = .discard
        } else {
            dismiss()
        }
    }

    /// 把 ViewModel 读取阶段同步给延迟显示、最短驻留的加载门闩。
    private func syncReadLoadingVisibility() {
        readLoadingGate.update(intent: viewModel.isLoading ? .read : .none)
    }

    /// 把编辑器内部提示统一映射为项目标准 UIKit 系统弹窗。
    private func alertDescriptor(for alert: RelevantEditorAlert) -> XMSystemAlertDescriptor {
        switch alert {
        case .discard:
            return XMSystemAlertDescriptor(
                title: "相关内容尚未保存",
                message: "可以保留自动草稿后退出，下次进入同一分类与内容时继续编辑。",
                actions: [
                    XMSystemAlertAction(title: "继续编辑", role: .cancel) { },
                    XMSystemAlertAction(title: "保留草稿并退出") {
                        if viewModel.preserveDraftForExit() {
                            dismiss()
                        }
                    },
                    XMSystemAlertAction(title: "放弃更改", role: .destructive) {
                        Task {
                            await viewModel.discardEditingSession()
                            dismiss()
                        }
                    }
                ]
            )
        case .recovery(let savedTimeDescription):
            return XMSystemAlertDescriptor(
                title: "发现自动保存草稿",
                message: "检测到 \(savedTimeDescription) 保存的相关内容，是否恢复继续编辑？",
                actions: [
                    XMSystemAlertAction(title: "恢复") {
                        Task { await viewModel.restoreRecoveredDraft() }
                    },
                    XMSystemAlertAction(title: "丢弃", role: .destructive) {
                        Task { await viewModel.discardRecoveredDraft() }
                    }
                ]
            )
        case .imageMessage(let message):
            return XMSystemAlertDescriptor(
                title: "图片处理遇到问题",
                message: message,
                actions: [
                    XMSystemAlertAction(title: "知道了", role: .cancel) {
                        viewModel.clearImageError()
                    }
                ]
            )
        case .message(let message):
            return XMSystemAlertDescriptor(
                title: "相关内容编辑遇到问题",
                message: message,
                actions: [
                    XMSystemAlertAction(title: "知道了", role: .cancel) {
                        viewModel.clearError()
                    }
                ]
            )
        }
    }

    nonisolated private static func autoSaveTimeDescription(_ timestamp: Int64) -> String {
        let date = Date(timeIntervalSince1970: Double(timestamp) / 1_000)
        return date.formatted(date: .omitted, time: .shortened)
    }
}

/// 相关内容表单复用现有 Hero、卡片和富文本组件，不定义额外视觉规格。
private struct RelevantEditorForm: View {
    @Bindable var viewModel: RelevantEditorViewModel
    let draft: RelevantEditorDraft
    let ocrRepository: any OCRRepositoryProtocol
    let onTransferError: (String) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.base) {
                ContentViewerHeroCard(
                    title: draft.bookTitle,
                    subtitle: viewModel.contextSubtitle
                ) {
                    VStack(alignment: .leading, spacing: Spacing.cozy) {
                        Text("标题、正文、链接与图片会在一次保存中共同更新")
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.textSecondary)

                        if let autoSaveDescription = viewModel.autoSaveDescription {
                            Label(autoSaveDescription, systemImage: "checkmark.circle")
                                .font(AppTypography.caption)
                                .foregroundStyle(Color.textSecondary)
                                .transition(
                                    reduceMotion
                                        ? .opacity
                                        : .move(edge: .top).combined(with: .opacity)
                                )
                        }
                    }
                    .animation(
                        reduceMotion ? .smooth(duration: 0.12) : .smooth(duration: 0.2),
                        value: viewModel.autoSaveDescription
                    )
                }

                CardContainer {
                    VStack(alignment: .leading, spacing: Spacing.base) {
                        Text("标题")
                            .font(AppTypography.subheadlineSemibold)
                            .foregroundStyle(Color.textSecondary)

                        TextField("输入相关内容标题", text: $viewModel.title, axis: .vertical)
                            .font(AppTypography.body)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(1...3)
                    }
                    .padding(Spacing.contentEdge)
                }

                CardContainer {
                    VStack(alignment: .leading, spacing: Spacing.base) {
                        Text("链接")
                            .font(AppTypography.subheadlineSemibold)
                            .foregroundStyle(Color.textSecondary)

                        TextField("https://example.com", text: $viewModel.url)
                            .font(AppTypography.body)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.URL)
                            .textContentType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                    .padding(Spacing.contentEdge)
                }

                CardContainer {
                    VStack(alignment: .leading, spacing: Spacing.base) {
                        Text("正文")
                            .font(AppTypography.subheadlineSemibold)
                            .foregroundStyle(Color.textSecondary)

                        RichTextEditor(
                            attributedText: $viewModel.contentText,
                            activeFormats: $viewModel.activeFormats,
                            placeholder: "记录与这本书相关的内容…",
                            baseFont: AppTypography.uiSemantic(.body)
                        )
                        .frame(minHeight: 280)
                        .compositingGroup()
                        .clipShape(.rect(cornerRadius: CornerRadius.blockMedium))
                        .overlay {
                            RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                                .stroke(Color.surfaceBorderDefault, lineWidth: CardStyle.borderWidth)
                        }
                    }
                    .padding(Spacing.contentEdge)
                }

                ContentEditorImageSection(
                    items: viewModel.imageItems,
                    accessibilityNamespace: "relevant_editor.attachment_strip",
                    ocrRepository: ocrRepository,
                    availableSelectionCount: viewModel.availableImageSelectionCount,
                    onStageImages: viewModel.stageImages(_:),
                    onMove: viewModel.moveImage(sourceID:destinationID:),
                    onRemove: viewModel.removeImage(id:),
                    onRetry: viewModel.retryImage(id:),
                    onRecognizedText: viewModel.appendRecognizedText(_:),
                    onTransferError: onTransferError,
                    onQuotaBlocked: viewModel.showImageQuotaBlockedMessage
                )
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
            .safeAreaPadding(.bottom)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollIndicators(.hidden)
    }
}

/// 相关内容编辑器统一弹窗状态，避免并发显示多个 UIKit Alert。
private enum RelevantEditorAlert: Identifiable {
    case discard
    case recovery(String)
    case imageMessage(String)
    case message(String)

    var id: String {
        switch self {
        case .discard: "discard"
        case .recovery(let savedTime): "recovery-\(savedTime)"
        case .imageMessage(let message): "image-message-\(message)"
        case .message(let message): "message-\(message)"
        }
    }
}

#Preview("新建相关内容") {
    NavigationStack {
        RelevantEditorView(bookId: 1, categoryId: 2)
    }
    .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
    .environment(AppState())
}

#Preview("编辑相关内容") {
    NavigationStack {
        RelevantEditorView(mode: .edit(contentID: 1))
    }
    .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
    .environment(AppState())
}
