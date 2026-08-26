/**
 * [INPUT]: 依赖 RepositoryContainer 注入内容/S3/OCR/图片额度仓储，依赖 AppState 提供会员状态，依赖 ReviewEditorMode 与 ReviewEditorViewModel 驱动 create/edit 双模式，依赖 RichTextEditor、ContentEditorImageSection、LoadingGate、XMSystemAlert 复用既有交互
 * [OUTPUT]: 对外提供 ReviewEditorView，以单一写作表面承接书评新建/编辑、自动草稿恢复/保留退出、图片/OCR、校验与真实主键原子保存
 * [POS]: Content 模块书评编辑壳层，被书籍入口和通用 viewer 的编辑动作推入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书评编辑页，以统一模式兼容新建与既有主键编辑入口。
struct ReviewEditorView: View {
    let mode: ReviewEditorMode
    let navigationContext: AppTaskNavigationContext

    @Environment(RepositoryContainer.self) private var repositories
    @Environment(AppState.self) private var appState
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: ReviewEditorViewModel?
    @State private var bootstrapLoadingGate = LoadingGate()

    private let onSaved: (Int64) -> Void

    /// 通过统一模式建立书评编辑页；保存回调返回数据库中的真实主键。
    init(
        mode: ReviewEditorMode,
        onSaved: @escaping (Int64) -> Void = { _ in },
        navigationContext: AppTaskNavigationContext = .taskChild
    ) {
        self.mode = mode
        self.onSaved = onSaved
        self.navigationContext = navigationContext
    }

    /// 兼容既有只传书评主键的编辑路由。
    init(
        reviewId: Int64,
        onSaved: @escaping (Int64) -> Void = { _ in },
        navigationContext: AppTaskNavigationContext = .taskChild
    ) {
        self.init(
            mode: .edit(reviewID: reviewId),
            onSaved: onSaved,
            navigationContext: navigationContext
        )
    }

    /// 为书籍详情或书评列表提供明确的新建入口。
    init(
        bookId: Int64,
        onSaved: @escaping (Int64) -> Void = { _ in },
        navigationContext: AppTaskNavigationContext = .taskChild
    ) {
        self.init(
            mode: .create(bookID: bookId),
            onSaved: onSaved,
            navigationContext: navigationContext
        )
    }

    var body: some View {
        ZStack {
            if let viewModel {
                ReviewEditorLoadedView(
                    viewModel: viewModel,
                    navigationContext: navigationContext
                ) { reviewID in
                    onSaved(reviewID)
                    dismiss()
                }
            } else {
                Color.surfacePage.ignoresSafeArea()
                if bootstrapLoadingGate.isVisible {
                    LoadingStateView("正在准备书评…", style: .card)
                }
            }
        }
        .task {
            guard viewModel == nil else { return }
            bootstrapLoadingGate.update(intent: .read)
            let newViewModel = ReviewEditorViewModel(
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

/// 书评草稿加载后的编辑内容，集中承接脏表单返回保护与写操作反馈。
private struct ReviewEditorLoadedView: View {
    @Bindable var viewModel: ReviewEditorViewModel
    let navigationContext: AppTaskNavigationContext
    let onSaved: (Int64) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss
    @Environment(RepositoryContainer.self) private var repositories
    @Environment(AppState.self) private var appState

    @State private var activeAlert: ReviewEditorAlert?
    @State private var readLoadingGate = LoadingGate()

    var body: some View {
        ZStack {
            Color.surfacePage.ignoresSafeArea()

            editorPhase

            if viewModel.isSaving {
                Color.overlay.ignoresSafeArea()
                LoadingStateView("正在保存书评…", style: .card)
                    .transition(.opacity)
            } else if readLoadingGate.isVisible {
                LoadingStateView("正在加载书评草稿…", style: .card)
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
            ReviewEditorForm(
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
            guard let reviewID = await viewModel.save() else { return }
            onSaved(reviewID)
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
    private func alertDescriptor(for alert: ReviewEditorAlert) -> XMSystemAlertDescriptor {
        switch alert {
        case .discard:
            return XMSystemAlertDescriptor(
                title: "书评尚未保存",
                message: "可以保留自动草稿后退出，下次进入同一书评时继续编辑。",
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
                message: "检测到 \(savedTimeDescription) 保存的书评内容，是否恢复继续编辑？",
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
                title: "书评编辑遇到问题",
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

/// 书评表单以轻量书籍上下文和单一写作表面组织标题、正文与附图。
private struct ReviewEditorForm: View {
    @Bindable var viewModel: ReviewEditorViewModel
    let draft: ReviewEditorDraft
    let ocrRepository: any OCRRepositoryProtocol
    let onTransferError: (String) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.base) {
                ReviewEditorBookContext(
                    bookTitle: draft.bookTitle,
                    autoSaveDescription: viewModel.autoSaveDescription
                )

                CardContainer(showsBorder: false) {
                    VStack(alignment: .leading, spacing: Spacing.none) {
                        TextField("书评标题（可选）", text: $viewModel.title, axis: .vertical)
                            .font(AppTypography.title3)
                            .textFieldStyle(.plain)
                            .lineLimit(1...3)
                            .padding(Spacing.contentEdge)

                        Divider()
                            .overlay(Color.surfaceDividerSubtle)
                            .padding(.horizontal, Spacing.contentEdge)

                        RichTextEditor(
                            attributedText: $viewModel.contentText,
                            activeFormats: $viewModel.activeFormats,
                            placeholder: "写下你的书评…",
                            baseFont: ContentEditorTypography.richTextBodyUIFont
                        )
                        .frame(minHeight: 280)
                        .padding(.horizontal, Spacing.half)
                        .padding(.vertical, Spacing.half)
                    }
                }

                ContentEditorImageSection(
                    items: viewModel.imageItems,
                    accessibilityNamespace: "review_editor.attachment_strip",
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

/// 编辑页书籍上下文只保留创作对象与必要草稿状态，不再使用大尺寸 Hero 卡片。
private struct ReviewEditorBookContext: View {
    let bookTitle: String
    let autoSaveDescription: String?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.compact) {
            Text(bookTitle)
                .font(AppTypography.headline)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(2)

            autoSaveStatus
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Spacing.compact)
        .animation(
            reduceMotion ? nil : .smooth(duration: 0.2),
            value: autoSaveDescription
        )
    }

    @ViewBuilder
    private var autoSaveStatus: some View {
        if let autoSaveDescription {
            Text(autoSaveDescription)
                .font(AppTypography.caption)
                .foregroundStyle(Color.textSecondary)
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
        }
    }
}

/// 书评编辑器统一弹窗状态，避免并发显示多个 UIKit Alert。
private enum ReviewEditorAlert: Identifiable {
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

#Preview("新建书评") {
    NavigationStack {
        ReviewEditorView(bookId: 1)
    }
    .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
    .environment(AppState())
}

#Preview("编辑书评") {
    NavigationStack {
        ReviewEditorView(mode: .edit(reviewID: 1))
    }
    .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
    .environment(AppState())
}
