/**
 * [INPUT]: 依赖 NoteReviewViewModel、RepositoryContainer、AppNavigationCoordinator、页面私有 NoteReviewRefreshDeckHost、NoteReviewCardView 与外部导航/设置闭包
 * [OUTPUT]: 对外提供 NoteReviewView，承载 iOS 端书摘回顾分页卡组、底部一级操作与 AI 助手菜单、随机换组交接、卡片菜单、统一标签编辑、可取消分享、AI 释义/标签会话与编辑器交接
 * [POS]: Note 模块回顾 Tab 页面入口，被 NoteContainerView 托管
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

/// 书摘回顾主界面，负责卡片阅读、分页预加载、低强调刷新与轻量状态反馈。
struct NoteReviewView: View {
    @Bindable var viewModel: NoteReviewViewModel
    let onOpenContentViewer: (ContentViewerSourceContext, ContentViewerItemID) -> Void
    let onOpenSettings: () -> Void

    @Environment(XMToastCenter.self) private var toastCenter
    @Environment(RepositoryContainer.self) private var repositories
    @Environment(AppNavigationCoordinator.self) private var navigationCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    @State private var loadingGate = LoadingGate()
    @State private var tagLoadingGate = LoadingGate()
    @State private var aiLoadingGate = LoadingGate()
    @State private var tagEditSession: NoteReviewTagEditSession?
    @State private var aiTextPresentation: AITextResultPresentation?
    @State private var autoTagPresentation: AIAutoTagPresentation?
    @State private var pendingAIExplanationIdeaEditRequest: AIExplanationIdeaEditRequest?
    @State private var pendingConfigurationPrompt: NoteReviewConfigurationPrompt?
    @State private var tagLoadingNoteID: Int64?
    @State private var aiPreparingNoteID: Int64?
    @State private var menuGalleryHost = XMJXPhotoBrowserHost(initialItems: [])
    @State private var menuGalleryTapSequence = 0
    @State private var shareImageTask: Task<Void, Never>?
    @State private var shareImageRequestID: UUID?
    @State private var tagSnapshotTask: Task<Void, Never>?
    @State private var aiPreparationTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            Color.surfacePage.ignoresSafeArea()

            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            if loadingGate.isVisible, viewModel.items.isEmpty {
                LoadingStateView("正在加载回顾…", style: .card)
                    .transition(.opacity)
            }
        }
        .task {
            viewModel.reloadExternalAppAvailability()
            await viewModel.loadIfNeeded()
        }
        .onAppear {
            viewModel.reloadExternalAppAvailability()
            syncLoadingGate()
        }
        .onChange(of: viewModel.isInitialLoading) { _, _ in
            syncLoadingGate()
        }
        .onChange(of: viewModel.errorMessage) { _, message in
            guard let message, !message.isEmpty else { return }
            toastCenter.error(message)
            viewModel.consumeErrorMessage()
        }
        .onChange(of: viewModel.externalAppFeedback) { _, feedback in
            guard let feedback else { return }
            showExternalAppFeedback(feedback)
            viewModel.consumeExternalAppFeedback()
        }
        .sheet(item: $tagEditSession) { session in
            NoteReviewTagEditSheet(
                snapshot: session.snapshot,
                onCreateTag: { name in
                    try await viewModel.createTag(named: name)
                },
                onTagCatalogMutation: viewModel.applyTagCatalogMutation,
                onSave: { tags in
                    await viewModel.replaceTags(tags, for: session.item)
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(
            item: $aiTextPresentation,
            onDismiss: openPendingAIExplanationIdeaEditor
        ) { presentation in
            AITextResultSheet(
                presentation: presentation,
                repository: repositories.aiRepository,
                onIdeaEditorRequested: { request in
                    pendingAIExplanationIdeaEditRequest = request
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $autoTagPresentation) { presentation in
            AIAutoTagSheet(
                presentation: presentation,
                repository: repositories.aiRepository,
                onApplyWillBegin: {
                    viewModel.beginLocalDataChange()
                },
                onApplyFailed: {
                    viewModel.cancelLocalDataChange()
                },
                onTagsApplied: {
                    await viewModel.reloadItemAfterLocalDataChange(noteID: presentation.noteID)
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $viewModel.generatedShareFile) { file in
            XMActivityShareSheet(activityItems: [file.fileURL])
                .presentationDetents([.medium, .large])
        }
        .xmSystemAlert(item: $pendingConfigurationPrompt) { prompt in
            configurationAlertDescriptor(for: prompt)
        }
        .onDisappear {
            loadingGate.hideImmediately()
            tagLoadingGate.hideImmediately()
            aiLoadingGate.hideImmediately()
            tagSnapshotTask?.cancel()
            tagSnapshotTask = nil
            tagLoadingNoteID = nil
            aiPreparationTask?.cancel()
            aiPreparationTask = nil
            aiPreparingNoteID = nil
            shareImageTask?.cancel()
            shareImageTask = nil
            shareImageRequestID = nil
            viewModel.cancelShareImageGeneration()
        }
    }

    @ViewBuilder
    private var content: some View {
        if viewModel.items.isEmpty {
            emptyOrFailureContent
                .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : Spacing.half)))
        } else {
            cardStackContent
                .transition(.opacity.combined(with: .offset(y: reduceMotion ? 0 : Spacing.half)))
        }
    }

    private var cardStackContent: some View {
        NoteReviewRefreshDeckHost(
            viewModel: viewModel,
            isTagActionInFlight: tagLoadingNoteID != nil,
            isTagProgressVisible: tagLoadingGate.isVisible,
            isAIActionInFlight: aiPreparingNoteID != nil,
            isAIProgressVisible: aiLoadingGate.isVisible,
            onCardTapped: openContentViewer,
            onSend: send,
            onRequestSendConfiguration: {
                pendingConfigurationPrompt = .externalApp
            },
            onEditTags: openTagEditSheet,
            onExplain: presentAIExplanation,
            onAutoTag: presentAIAutoTag
        ) { item in
            NoteReviewCardView(item: item, settings: viewModel.settings)
                .contentShape(
                    .contextMenuPreview,
                    RoundedRectangle(
                        cornerRadius: NoteReviewCardLayout.cornerRadius,
                        style: .continuous
                    )
                )
                .contextMenu {
                    reviewCardContextMenu(for: item)
                }
                .padding(.horizontal, NoteReviewPagingLayoutSpec.iOSReviewDefault.cardHorizontalPadding)
                .padding(.bottom, Spacing.cozy)
        }
    }

    private var emptyOrFailureContent: some View {
        VStack(spacing: Spacing.base) {
            EmptyStateView(icon: "text.quote", message: "暂无可回顾书摘")
                .frame(maxHeight: 260)

            Button {
                onOpenSettings()
            } label: {
                Label("调整范围", systemImage: "slider.horizontal.3")
                    .font(AppTypography.subheadlineSemibold)
                    .frame(height: Spacing.actionReserved)
                    .padding(.horizontal, Spacing.contentEdge)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.brand)
            .disabled(viewModel.isInitialLoading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Spacing.screenEdge)
    }

    private func openContentViewer(for item: NoteReviewCardItem) {
        onOpenContentViewer(viewModel.viewerSourceContext(), .note(item.id))
    }

    @ViewBuilder
    private func reviewCardContextMenu(for item: NoteReviewCardItem) -> some View {
        Button {
            openContentViewer(for: item)
        } label: {
            Label("查看详情", systemImage: "doc.text")
        }

        Button {
            openTagEditSheet(for: item)
        } label: {
            Label("编辑标签", systemImage: "tag")
        }

        if !item.imageURLs.isEmpty {
            Button {
                previewImages(for: item)
            } label: {
                Label("预览附图", systemImage: "photo")
            }
        }

        Button {
            shareImage(for: item)
        } label: {
            Label("分享为图片", systemImage: "square.and.arrow.up")
        }
        .disabled(viewModel.shareImageActionNoteID != nil || viewModel.isGeneratingShareImage(for: item))

        if item.weReadOriginalURL != nil {
            Button {
                openWeReadOriginal(for: item)
            } label: {
                Label("打开微信读书原文", systemImage: "book")
            }
        }

        if viewModel.hasConfiguredExternalAppDestinations {
            Menu("发送到") {
                externalAppSendButton(.flomo, for: item)
                externalAppSendButton(.writeathon, for: item)
                externalAppSendButton(.inbox, for: item)
            }
        }
    }

    @ViewBuilder
    private func externalAppSendButton(
        _ destination: ExternalAppDestination,
        for item: NoteReviewCardItem
    ) -> some View {
        if viewModel.isExternalAppDestinationConfigured(destination) {
            Button {
                send(item: item, to: destination)
            } label: {
                Label(destination.noteReviewMenuTitle, systemImage: destination.noteReviewMenuSystemImage)
            }
            .disabled(viewModel.externalAppSendAction != nil || viewModel.isSendingExternalApp(to: destination))
        }
    }

    private func openTagEditSheet(for item: NoteReviewCardItem) {
        guard tagSnapshotTask == nil else { return }
        tagLoadingNoteID = item.id
        tagLoadingGate.update(intent: .read)
        tagSnapshotTask = Task { @MainActor in
            let snapshot = await viewModel.fetchTagEditSnapshot(for: item)
            guard !Task.isCancelled else { return }
            finishTagSnapshotPreparation()
            guard let snapshot else { return }
            tagEditSession = NoteReviewTagEditSession(item: item, snapshot: snapshot)
        }
    }

    private func finishTagSnapshotPreparation() {
        tagLoadingGate.update(intent: .none)
        tagLoadingNoteID = nil
        tagSnapshotTask = nil
    }

    /// 锁定触发时卡片后启动 AI 释义配置预检；任务在页面离场时取消，迟到结果不会建立会话。
    private func presentAIExplanation(for item: NoteReviewCardItem) {
        prepareAIAction(.explanation, for: item)
    }

    /// 锁定触发时卡片后启动 AI 标签配置预检；写回目标不受后续卡片翻页影响。
    private func presentAIAutoTag(for item: NoteReviewCardItem) {
        prepareAIAction(.autoTag, for: item)
    }

    /// 串行预检选定 AI 能力；页面只持有一个准备任务，并在主线程建立对应的稳定 Sheet 会话。
    private func prepareAIAction(_ action: NoteReviewAIAction, for item: NoteReviewCardItem) {
        guard aiPreparationTask == nil else { return }
        aiPreparingNoteID = item.id
        aiLoadingGate.update(intent: .read)
        aiPreparationTask = Task { @MainActor in
            let availability = await viewModel.checkAIAvailability()
            guard !Task.isCancelled else { return }
            aiLoadingGate.update(intent: .none)
            aiPreparingNoteID = nil
            aiPreparationTask = nil

            switch availability {
            case .available:
                switch action {
                case .explanation:
                    aiTextPresentation = AITextResultPresentation(
                        request: .noteExplanation(noteID: item.id, bookTitle: item.bookTitle)
                    )
                case .autoTag:
                    autoTagPresentation = AIAutoTagPresentation(
                        noteID: item.id,
                        bookTitle: item.bookTitle
                    )
                }
            case .configurationRequired:
                pendingConfigurationPrompt = .ai
            case .failed(let message):
                toastCenter.error(message)
            case .cancelled:
                break
            }
        }
    }

    /// 等 AI Sheet 完全退场后打开根级书摘编辑任务；协调器拒绝时清除请求并给出可感知反馈。
    private func openPendingAIExplanationIdeaEditor() {
        guard let request = pendingAIExplanationIdeaEditRequest else { return }
        pendingAIExplanationIdeaEditRequest = nil
        let seed = NoteEditorSeed(
            bookId: nil,
            chapterId: nil,
            contentHTML: "",
            ideaHTML: "",
            ideaAppendText: request.explanationText
        )
        guard navigationCoordinator.present(
            .noteEditor(mode: .edit(noteId: request.noteID), seed: seed)
        ) else {
            toastCenter.error("暂时无法打开编辑页，请稍后重试")
            return
        }
    }

    private func previewImages(for item: NoteReviewCardItem) {
        let galleryItems = item.imageURLs.enumerated().map { index, url in
            XMJXGalleryItem(
                id: "note-review-menu-\(item.id)-image-\(index)",
                thumbnailURL: url,
                originalURL: url
            )
        }
        guard !galleryItems.isEmpty else { return }
        menuGalleryHost.updateItems(galleryItems)
        menuGalleryTapSequence += 1
        menuGalleryHost.open(
            at: 0,
            wallID: "note-review-menu-\(item.id)",
            tapSequence: menuGalleryTapSequence
        )
    }

    /// 关闭菜单后启动外部应用发送任务；ViewModel 会立即发布处理中反馈并阻止重复触发。
    private func send(item: NoteReviewCardItem, to destination: ExternalAppDestination) {
        Task {
            await viewModel.send(item: item, to: destination)
        }
    }

    /// 将配置引导切换到“我的”Tab 的对应原生浏览页面，笔记 Tab 的回顾现场由独立导航栈保留。
    private func openConfiguration(_ prompt: NoteReviewConfigurationPrompt) {
        navigationCoordinator.push(.personal(prompt.route), in: .profile)
        navigationCoordinator.updateCurrentTab(.profile)
    }

    private func configurationAlertDescriptor(
        for prompt: NoteReviewConfigurationPrompt
    ) -> XMSystemAlertDescriptor {
        XMSystemAlertDescriptor(
            title: prompt.title,
            message: prompt.message,
            actions: [
                XMSystemAlertAction(title: "取消", role: .cancel) { },
                XMSystemAlertAction(title: prompt.actionTitle) {
                    openConfiguration(prompt)
                }
            ]
        )
    }

    /// 在主线程托管单次分享图任务；页面离场会取消任务，request ID 防止旧任务迟到清空新任务句柄。
    private func shareImage(for item: NoteReviewCardItem) {
        let isDarkAppearance = colorScheme == .dark
        shareImageTask?.cancel()
        let requestID = UUID()
        shareImageRequestID = requestID
        shareImageTask = Task { @MainActor in
            defer {
                if shareImageRequestID == requestID {
                    shareImageTask = nil
                    shareImageRequestID = nil
                }
            }
            await viewModel.shareImage(for: item, isDarkAppearance: isDarkAppearance)
        }
    }

    /// 使用系统 URL 打开微信读书原文深链；失败时给出可感知反馈。
    private func openWeReadOriginal(for item: NoteReviewCardItem) {
        guard let rawURL = item.weReadOriginalURL, let url = URL(string: rawURL) else {
            toastCenter.error("当前书摘缺少微信读书原文位置")
            return
        }
        openURL(url) { accepted in
            if !accepted {
                toastCenter.error("未能打开微信读书")
            }
        }
    }

    /// 将 ViewModel 的外部应用反馈事件映射到统一 Toast 中心，消费后由 ViewModel 清空状态。
    private func showExternalAppFeedback(_ feedback: NoteReviewExternalAppFeedback) {
        switch feedback.role {
        case .processing:
            toastCenter.processing(feedback.message)
        case .success:
            toastCenter.success(feedback.message)
        case .error:
            toastCenter.error(feedback.message)
        case .warning:
            toastCenter.warning(feedback.message)
        }
    }

    private func syncLoadingGate() {
        loadingGate.update(intent: viewModel.isInitialLoading ? .read : .none)
    }
}

extension ExternalAppDestination {
    var noteReviewMenuTitle: String {
        switch self {
        case .flomo:
            return "Flomo"
        case .writeathon:
            return "Writeathon"
        case .inbox:
            return "Inbox"
        }
    }

    var noteReviewMenuSystemImage: String {
        switch self {
        case .flomo, .writeathon:
            return "paperplane"
        case .inbox:
            return "tray.and.arrow.down"
        }
    }
}

private enum NoteReviewConfigurationPrompt: String, Identifiable {
    case externalApp
    case ai

    var id: String { rawValue }

    var title: String {
        switch self {
        case .externalApp:
            "尚未配置关联应用"
        case .ai:
            "请先完成 AI 配置"
        }
    }

    var message: String {
        switch self {
        case .externalApp:
            "请先前往“我的 > API 集成”，配置至少一个发送目标后再试。"
        case .ai:
            "启用 AI 并配置模型与 API Key 后，即可使用 AI 释义和 AI 标签。"
        }
    }

    var actionTitle: String {
        switch self {
        case .externalApp:
            "去配置"
        case .ai:
            "前往设置"
        }
    }

    var route: PersonalRoute {
        switch self {
        case .externalApp:
            .apiIntegration
        case .ai:
            .aiConfiguration
        }
    }
}

private enum NoteReviewAIAction {
    case explanation
    case autoTag
}

private struct NoteReviewTagEditSession: Identifiable {
    let item: NoteReviewCardItem
    let snapshot: NoteReviewTagEditSnapshot

    var id: Int64 {
        item.id
    }
}
