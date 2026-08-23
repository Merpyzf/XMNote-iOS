/**
 * [INPUT]: 依赖 RepositoryContainer 注入内容/AI 仓储，依赖 ContentViewerViewModel 驱动分页与详情状态
 * [OUTPUT]: 对外提供 ContentViewerView，以首帧稳定导航标题统一承接分页查看、微信读书原文跳转、书摘朗读、页面级系统分享、关联应用配置引导、AI 释义/标签与内容操作反馈
 * [POS]: Content 模块查看页壳层，被时间线与书籍详情共同复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 通用内容查看器，统一承接时间线与书籍详情的分页查看入口。
struct ContentViewerView: View {
    let source: ContentViewerSourceContext
    let initialItemID: ContentViewerItemID
    let keyword: String

    @Environment(RepositoryContainer.self) private var repositories
    @Environment(SceneStateStore.self) private var sceneStateStore
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: ContentViewerViewModel?
    @State private var showsDeleteDialog = false
    @State private var didBootstrapFromScene = false
    @State private var bootstrapLoadingGate = LoadingGate()

    private var presentationStyle: ContentViewerPresentationStyle {
        ContentViewerPresentationStyle(source: source)
    }

    var body: some View {
        ZStack {
            if let viewModel {
                ContentViewerLoadedView(
                    viewModel: viewModel,
                    showsDeleteDialog: $showsDeleteDialog
                )
                .onChange(of: viewModel.dismissalRequestToken) { _, newToken in
                    guard newToken > 0 else { return }
                    dismiss()
                }
            } else {
                Color.surfacePage.ignoresSafeArea()
                if bootstrapLoadingGate.isVisible {
                    LoadingStateView(presentationStyle.loadingMessage, style: .card)
                }
            }
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .task(id: sceneStateStore.isRestored) {
            guard sceneStateStore.isRestored else { return }
            guard !didBootstrapFromScene else { return }
            didBootstrapFromScene = true
            guard viewModel == nil else { return }
            bootstrapLoadingGate.update(intent: .read)
            let restoredSelectedItemID: ContentViewerItemID? = {
                guard let snapshot = sceneStateStore.snapshot.contentViewer,
                      snapshot.source == source else {
                    return nil
                }
                return snapshot.selectedItemID
            }()
            let newViewModel = ContentViewerViewModel(
                source: source,
                initialItemID: initialItemID,
                restoredSelectedItemID: restoredSelectedItemID,
                keyword: keyword,
                defaultTitle: presentationStyle.defaultTitle,
                missingItemMessage: presentationStyle.missingItemMessage,
                repository: repositories.contentRepository,
                noteRepository: repositories.noteRepository,
                externalAppIntegrationRepository: repositories.externalAppIntegrationRepository
            )
            viewModel = newViewModel
            bootstrapLoadingGate.update(intent: .none)
            newViewModel.startObservation()
        }
        .onChange(of: viewModel?.selectedItemID, initial: false) { _, newValue in
            guard let newValue else { return }
            sceneStateStore.updateContentViewer(
                ContentViewerSceneSnapshot(source: source, selectedItemID: newValue)
            )
        }
        .onDisappear {
            bootstrapLoadingGate.hideImmediately()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            ContentViewerNavigationTitle(pageProgress: viewModel?.selectedPageProgress) {
                if let viewModel, let selectedBookID = viewModel.selectedBookID {
                    NavigationLink(value: AppRoute.book(.detail(bookId: selectedBookID))) {
                        contentViewerTitleLabel(viewModel.selectedBookTitle)
                    }
                    .buttonStyle(.plain)
                } else {
                    contentViewerTitleLabel(viewModel?.selectedBookTitle ?? presentationStyle.defaultTitle)
                }
            }
        }
    }
}

private struct ContentViewerLoadedView: View {
    @Bindable var viewModel: ContentViewerViewModel
    @Binding var showsDeleteDialog: Bool

    @Environment(\.openURL) private var openURL
    @Environment(XMToastCenter.self) private var toastCenter
    @Environment(RepositoryContainer.self) private var repositories
    @Environment(AppNavigationCoordinator.self) private var navigationCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    @State private var bottomOrnamentHeight: CGFloat = 0
    @State private var showsTagSheet = false
    @State private var tagEditSession: ContentViewerTagEditSession?
    @State private var sharePayload: XMActivitySharePayload?
    @State private var pendingPresentation: PendingCapabilityPresentation?
    @State private var aiTextPresentation: AITextResultPresentation?
    @State private var autoTagPresentation: AIAutoTagPresentation?
    @State private var listLoadingGate = LoadingGate()
    @State private var searchMatchIndex = 0
    @State private var speechController = NoteSpeechController()
    @State private var shareGenerationTask: Task<Void, Never>?
    @State private var isGeneratingShareImage = false

    private var presentationStyle: ContentViewerPresentationStyle {
        ContentViewerPresentationStyle(source: viewModel.source)
    }

    private var deleteAlertDescriptor: XMSystemAlertDescriptor {
        XMSystemAlertDescriptor(
            title: presentationStyle.deleteDialogTitle,
            message: "删除后将从当前内容中移除。",
            actions: [
                XMSystemAlertAction(title: "取消", role: .cancel) { },
                XMSystemAlertAction(title: "删除", role: .destructive) {
                    Task { await viewModel.deleteCurrentItem() }
                },
            ]
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let safeAreaBottomInset = proxy.safeAreaInsets.bottom

            VStack(spacing: Spacing.none) {
                if presentationStyle.showsListErrorBanner,
                   let listErrorMessage = viewModel.listErrorMessage,
                   !listErrorMessage.isEmpty,
                   !viewModel.items.isEmpty {
                    viewerMessageCard(text: listErrorMessage)
                        .padding(.horizontal, Spacing.screenEdge)
                        .padding(.top, Spacing.base)
                }

                if let searchMatchContext {
                    ContentViewerSearchContextCard(
                        context: searchMatchContext,
                        currentIndex: selectedSearchMatchDisplayIndex,
                        totalCount: selectedSearchMatches.count,
                        onPrevious: selectPreviousSearchMatch,
                        onNext: selectNextSearchMatch
                    )
                    .padding(.horizontal, Spacing.screenEdge)
                    .padding(.top, viewModel.items.isEmpty ? Spacing.base : Spacing.cozy)
                }

                ContentViewerContentView(
                    presentationStyle: presentationStyle,
                    props: contentProps,
                    bottomChromeMetrics: bottomChromeMetrics(safeAreaBottomInset: safeAreaBottomInset),
                    onPagerSelectionChanged: { viewModel.select($0) },
                    pageStateProvider: pageState(for:),
                    onLoadDetail: { itemID in
                        await viewModel.loadDetailIfNeeded(itemID: itemID)
                    },
                    onRefreshDetail: { itemID in
                        await viewModel.loadDetailIfNeeded(itemID: itemID)
                    },
                    onAISelection: presentTextLookup
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(
                Color.surfacePage.ignoresSafeArea(edges: .bottom)
            )
            .overlay {
                if viewModel.isDeleting {
                    Color.overlay.ignoresSafeArea()
                    LoadingStateView("正在删除…", style: .card)
                }
            }
            .overlay(alignment: .bottom) {
                if !viewModel.items.isEmpty {
                    bottomOverlay(safeAreaBottomInset: safeAreaBottomInset)
                }
            }
        }
        .xmSystemAlert(
            isPresented: $showsDeleteDialog,
            descriptor: deleteAlertDescriptor
        )
        .xmSystemAlert(item: $pendingPresentation) { presentation in
            XMSystemAlertDescriptor(
                title: presentation.title,
                message: presentation.message,
                actions: [
                    XMSystemAlertAction(title: "知道了", role: .cancel) { }
                ]
            )
        }
        .sheet(isPresented: $showsTagSheet) {
            ContentViewerTagSheet(
                tags: selectedTagNames,
                onDismiss: { showsTagSheet = false }
            )
            .presentationDetents([.height(220)])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $tagEditSession) { session in
            NoteReviewTagEditSheet(
                contextTitle: session.bookTitle,
                snapshot: session.snapshot,
                onCreateTag: { name in
                    await viewModel.createTag(named: name)
                },
                onSave: { tags in
                    await viewModel.replaceTags(tags, noteID: session.noteID)
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $sharePayload) { payload in
            XMActivityShareSheet(activityItems: payload.activityItems)
        }
        .sheet(item: $aiTextPresentation) { presentation in
            AITextResultSheet(
                presentation: presentation,
                repository: repositories.aiRepository,
                onIdeaAppended: {
                    guard let noteID = presentation.request.noteIDForAppending else { return }
                    await viewModel.refreshDetail(itemID: .note(noteID))
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $autoTagPresentation) { presentation in
            AIAutoTagSheet(
                presentation: presentation,
                repository: repositories.aiRepository,
                onTagsApplied: {
                    await viewModel.refreshDetail(itemID: .note(presentation.noteID))
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .onAppear {
            syncListLoadingVisibility()
        }
        .onChange(of: viewModel.isLoadingList) { _, _ in
            syncListLoadingVisibility()
        }
        .onChange(of: viewModel.items.isEmpty) { _, _ in
            syncListLoadingVisibility()
        }
        .onChange(of: viewModel.selectedItemID) { _, _ in
            searchMatchIndex = 0
            speechController.stop()
            shareGenerationTask?.cancel()
        }
        .onChange(of: viewModel.actionFeedback) { _, feedback in
            guard let feedback else { return }
            showActionFeedback(feedback)
            viewModel.consumeActionFeedback()
        }
        .onPreferenceChange(ImmersiveBottomChromeHeightPreferenceKey.self) { height in
            bottomOrnamentHeight = height
        }
        .task(id: viewModel.selectedItemID) {
            guard let selectedItemID = viewModel.selectedItemID else { return }
            await viewModel.prefetchDetails(around: selectedItemID, radius: 1)
        }
        .onDisappear {
            shareGenerationTask?.cancel()
            shareGenerationTask = nil
            speechController.release()
            listLoadingGate.hideImmediately()
        }
    }

    private func bottomOverlay(safeAreaBottomInset: CGFloat) -> some View {
        ImmersiveBottomChromeOverlay(
            metrics: bottomChromeMetrics(safeAreaBottomInset: safeAreaBottomInset)
        ) {
            bottomOrnament
        }
    }

    private var bottomOrnament: some View {
        GlassEffectContainer(spacing: Spacing.base) {
            HStack(spacing: Spacing.double) {
                contentActionCluster
                    .padding(.horizontal, Spacing.base)
                    .frame(height: ImmersiveBottomChromeStyle.controlHeight)
                    .glassEffect(.regular.interactive(), in: .capsule)

                Button(role: .destructive) {
                    showsDeleteDialog = true
                } label: {
                    ImmersiveBottomChromeIcon(
                        systemName: "trash",
                        foregroundStyle: Color.feedbackError
                    )
                }
                .buttonStyle(.plain)
                .disabled(viewModel.selectedItemID == nil || viewModel.isDeleting)
                .frame(
                    width: ImmersiveBottomChromeStyle.controlHeight,
                    height: ImmersiveBottomChromeStyle.controlHeight
                )
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel(presentationStyle.deleteAccessibilityLabel)
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: ImmersiveBottomChromeHeightPreferenceKey.self, value: proxy.size.height)
            }
        }
    }

    @ViewBuilder
    private var contentActionCluster: some View {
        HStack(spacing: Spacing.cozy) {
            switch viewModel.selectedItemID {
            case .note(let noteID)?:
                noteTagMenu

                noteAPISendMenu

                Button {
                    navigationCoordinator.present(.noteEditor(mode: .edit(noteId: noteID), seed: nil))
                } label: {
                    ImmersiveBottomChromeIcon(systemName: "square.and.pencil")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("编辑书摘")

                noteShareMenu
                .disabled(selectedNoteDetail == nil)

                noteAIMenu

            case .review(let reviewID)?:
                Button {
                    navigationCoordinator.present(.reviewEditor(.edit(reviewID: reviewID)))
                } label: {
                    ImmersiveBottomChromeIcon(systemName: "square.and.pencil")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("编辑书评")

                Button {
                    copyCurrentDetail()
                } label: {
                    ImmersiveBottomChromeIcon(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .disabled(selectedReviewDetail == nil)
                .accessibilityLabel("复制书评")

            case .relevant(let contentID)?:
                Button {
                    navigationCoordinator.present(.relevantEditor(.edit(contentID: contentID)))
                } label: {
                    ImmersiveBottomChromeIcon(systemName: "square.and.pencil")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("编辑相关内容")

                Button {
                    guard let relevantURL else { return }
                    openURL(relevantURL)
                } label: {
                    ImmersiveBottomChromeIcon(systemName: "link")
                }
                .buttonStyle(.plain)
                .disabled(relevantURL == nil)
                .accessibilityLabel("打开链接")

                Button {
                    copyCurrentDetail()
                } label: {
                    ImmersiveBottomChromeIcon(systemName: "doc.on.doc")
                }
                .buttonStyle(.plain)
                .disabled(selectedRelevantDetail == nil)
                .accessibilityLabel("复制相关内容")

            case .none:
                ImmersiveBottomChromeIcon(systemName: "square.and.pencil")
                    .opacity(0.4)
                ImmersiveBottomChromeIcon(systemName: "doc.on.doc")
                    .opacity(0.4)
            }
        }
    }

    private var noteTagMenu: some View {
        Menu {
            if !selectedTagNames.isEmpty {
                Button {
                    showsTagSheet = true
                } label: {
                    XMMenuLabel("查看标签", systemImage: "tag")
                }
            }

            Button {
                openTagEditor()
            } label: {
                XMMenuLabel("编辑标签", systemImage: "pencil")
            }
            .disabled(viewModel.isLoadingTagEditor || viewModel.isSavingTags)
        } label: {
            ImmersiveBottomChromeIcon(systemName: "tag")
        }
        .buttonStyle(.plain)
        .xmMenuNeutralTint()
        .accessibilityLabel("标签")
    }

    private var noteAPISendMenu: some View {
        Menu {
            if viewModel.configuredExternalAppDestinations.isEmpty {
                Button {
                    presentPending(.apiConfiguration)
                } label: {
                    XMMenuLabel("尚未配置关联应用", systemImage: "link.badge.plus")
                }
            } else {
                ForEach(ExternalAppDestination.allCases) { destination in
                    if viewModel.configuredExternalAppDestinations.contains(destination) {
                        Button {
                            sendCurrentNote(to: destination)
                        } label: {
                            XMMenuLabel(destination.viewerMenuTitle, systemImage: destination.viewerMenuSystemImage)
                        }
                        .disabled(viewModel.sendingDestination != nil)
                    }
                }
            }
        } label: {
            ImmersiveBottomChromeIcon(
                systemName: viewModel.sendingDestination == nil ? "paperplane" : "hourglass"
            )
        }
        .buttonStyle(.plain)
        .xmMenuNeutralTint()
        .accessibilityLabel("API 外发")
    }

    /// 在菜单关闭后读取当前书摘真实标签快照，成功才展示业务 Sheet。
    private func openTagEditor() {
        guard case .note(let noteID)? = viewModel.selectedItemID else { return }
        let bookTitle = selectedNoteDetail?.bookTitle ?? viewModel.selectedBookTitle
        Task {
            toastCenter.processing("正在读取标签…")
            let processingToastID = toastCenter.current?.id
            let snapshot = await viewModel.fetchTagEditSnapshot(noteID: noteID)
            toastCenter.dismiss(id: processingToastID)
            guard let snapshot else { return }
            tagEditSession = ContentViewerTagEditSession(
                noteID: noteID,
                bookTitle: bookTitle,
                snapshot: snapshot
            )
        }
    }

    /// 将明确选择的外部目标交给 ViewModel，避免菜单状态变化后发送到错误书摘。
    private func sendCurrentNote(to destination: ExternalAppDestination) {
        guard case .note(let noteID)? = viewModel.selectedItemID else { return }
        Task { await viewModel.send(noteID: noteID, to: destination) }
    }

    private var noteShareMenu: some View {
        Menu {
            if weReadOriginalURL != nil {
                Button(action: openWeReadOriginal) {
                    XMMenuLabel("在微信读书中查看原文", systemImage: "book")
                }
                Divider()
            }

            noteSpeechActions

            Divider()

            Button {
                shareCurrentNote()
            } label: {
                XMMenuLabel("系统分享", systemImage: "square.and.arrow.up")
            }
            Button {
                generateShareCard()
            } label: {
                XMMenuLabel(
                    isGeneratingShareImage ? "正在生成分享图…" : "分享卡片",
                    systemImage: isGeneratingShareImage
                        ? "hourglass"
                        : "rectangle.portrait.on.rectangle.portrait"
                )
            }
            .disabled(isGeneratingShareImage)
        } label: {
            ImmersiveBottomChromeIcon(systemName: noteOutputSystemImage)
        }
        .buttonStyle(.plain)
        .xmMenuNeutralTint()
        .animation(reduceMotion ? nil : .snappy(duration: 0.18), value: speechController.state)
        .accessibilityLabel("原文、朗读与分享书摘")
    }

    private var noteOutputSystemImage: String {
        switch speechController.state {
        case .idle:
            "square.and.arrow.up"
        case .speaking:
            "waveform"
        case .paused:
            "pause.fill"
        }
    }

    @ViewBuilder
    private var noteSpeechActions: some View {
        switch speechController.state {
        case .idle:
            Button(action: startSpeakingCurrentNote) {
                XMMenuLabel("朗读书摘", systemImage: "waveform")
            }
        case .speaking:
            Button(action: speechController.pause) {
                XMMenuLabel("暂停朗读", systemImage: "pause.fill")
            }
            Button(action: speechController.stop) {
                XMMenuLabel("停止朗读", systemImage: "stop.fill")
            }
        case .paused:
            Button(action: speechController.resume) {
                XMMenuLabel("继续朗读", systemImage: "play.fill")
            }
            Button(action: speechController.stop) {
                XMMenuLabel("停止朗读", systemImage: "stop.fill")
            }
        }
    }

    private var noteAIMenu: some View {
        Menu {
            Button {
                presentNoteExplanation()
            } label: {
                XMMenuLabel("AI 释义", systemImage: "sparkles")
            }
            Button {
                presentAutoTag()
            } label: {
                XMMenuLabel("AI 标签", systemImage: "tag")
            }
        } label: {
            ImmersiveBottomChromeIcon(systemName: "sparkles")
        }
        .buttonStyle(.plain)
        .xmMenuNeutralTint()
        .accessibilityLabel("书摘 AI")
    }

    private func bottomChromeMetrics(safeAreaBottomInset: CGFloat) -> ImmersiveBottomChromeMetrics {
        ImmersiveBottomChromeMetrics.make(
            measuredOrnamentHeight: bottomOrnamentHeight,
            safeAreaBottomInset: safeAreaBottomInset
        )
    }

    private var contentProps: ContentViewerContentView.Props {
        ContentViewerContentView.Props(
            selectedItemID: viewModel.selectedItemID,
            listState: listState,
            itemIDs: viewModel.items.map(\.id)
        )
    }

    private var listState: ContentViewerContentView.Props.ListState {
        if viewModel.items.isEmpty {
            if viewModel.isLoadingList {
                return listLoadingGate.isVisible ? .loading : .placeholder
            }
            return .empty(viewModel.listErrorMessage ?? presentationStyle.missingItemMessage)
        }
        return .content
    }

    func syncListLoadingVisibility() {
        let intent: LoadingIntent = viewModel.items.isEmpty && viewModel.isLoadingList ? .read : .none
        listLoadingGate.update(intent: intent)
    }

    private func pageState(for itemID: ContentViewerItemID) -> ContentViewerContentView.Props.PageState {
        if let detail = viewModel.detail(for: itemID) {
            return .detail(detail)
        }
        if let message = viewModel.detailErrorMessage(for: itemID) {
            return .error(message)
        }
        return .loading
    }

    private var selectedNoteDetail: NoteContentDetail? {
        guard case .note(let detail)? = viewModel.selectedDetail else { return nil }
        return detail
    }

    private var selectedReviewDetail: ReviewContentDetail? {
        guard case .review(let detail)? = viewModel.selectedDetail else { return nil }
        return detail
    }

    private var selectedRelevantDetail: RelevantContentDetail? {
        guard case .relevant(let detail)? = viewModel.selectedDetail else { return nil }
        return detail
    }

    private var selectedTagNames: [String] {
        selectedNoteDetail?.tagNames ?? []
    }

    private var selectedSearchMatches: [ContentViewerSearchMatchContext] {
        guard let selectedDetail = viewModel.selectedDetail else { return [] }
        return ContentViewerSearchMatchContext.matches(
            in: selectedDetail,
            keyword: viewModel.keyword
        )
    }

    private var searchMatchContext: ContentViewerSearchMatchContext? {
        let matches = selectedSearchMatches
        guard !matches.isEmpty else { return nil }
        return matches[min(searchMatchIndex, matches.count - 1)]
    }

    private var selectedSearchMatchDisplayIndex: Int {
        let count = selectedSearchMatches.count
        guard count > 0 else { return 0 }
        return min(searchMatchIndex, count - 1) + 1
    }

    private var relevantURL: URL? {
        guard let selectedRelevantDetail else { return nil }
        return normalizedURL(selectedRelevantDetail.url)
    }

    private var weReadOriginalURL: URL? {
        guard let rawValue = selectedNoteDetail?.weReadOriginalURL else { return nil }
        return URL(string: rawValue)
    }

    private func presentPending(_ capability: ContentViewerPendingCapability) {
        pendingPresentation = PendingCapabilityPresentation(capability: capability)
    }

    /// 锁定当前书摘主键与书名后呈现流式释义，横向翻页不会改变本次写回目标。
    private func presentNoteExplanation() {
        guard case .note(let noteID)? = viewModel.selectedItemID else { return }
        aiTextPresentation = AITextResultPresentation(
            request: .noteExplanation(
                noteID: noteID,
                bookTitle: selectedNoteDetail?.bookTitle ?? viewModel.selectedBookTitle
            )
        )
    }

    /// 锁定 RichText 系统选区回调提供的文本与上下文后呈现释义结果。
    private func presentTextLookup(_ input: AITextLookupInput) {
        aiTextPresentation = AITextResultPresentation(request: .textLookup(input))
    }

    /// 锁定当前书摘主键后呈现自动标签建议，确认写入时不会受翻页状态影响。
    private func presentAutoTag() {
        guard case .note(let noteID)? = viewModel.selectedItemID else { return }
        autoTagPresentation = AIAutoTagPresentation(
            noteID: noteID,
            bookTitle: selectedNoteDetail?.bookTitle ?? viewModel.selectedBookTitle
        )
    }

    /// 使用系统 URL 分发打开微信读书深链；系统拒绝或目标 App 不可用时通过统一 Toast 明确反馈。
    private func openWeReadOriginal() {
        guard let weReadOriginalURL else {
            toastCenter.warning("当前书摘缺少微信读书原文位置")
            return
        }
        openURL(weReadOriginalURL) { accepted in
            if !accepted {
                toastCenter.error("未能打开微信读书")
            }
        }
    }

    /// 把状态层动作事件映射到统一 Toast；processing 会由后续 success/error newest-wins 替换。
    private func showActionFeedback(_ feedback: ContentViewerActionFeedback) {
        switch feedback.role {
        case .processing:
            toastCenter.processing(feedback.message)
        case .success:
            toastCenter.success(feedback.message)
        case .warning:
            toastCenter.warning(feedback.message)
        case .error:
            toastCenter.error(feedback.message)
        }
    }

    private func selectPreviousSearchMatch() {
        let count = selectedSearchMatches.count
        guard count > 1 else { return }
        withAnimation(.snappy) {
            searchMatchIndex = searchMatchIndex == 0 ? count - 1 : searchMatchIndex - 1
        }
    }

    private func selectNextSearchMatch() {
        let count = selectedSearchMatches.count
        guard count > 1 else { return }
        withAnimation(.snappy) {
            searchMatchIndex = (searchMatchIndex + 1) % count
        }
    }

    private func shareCurrentNote() {
        guard let detail = selectedNoteDetail else { return }
        sharePayload = XMActivitySharePayload(activityItems: [shareText(from: detail)])
    }

    /// 将当前富文本转换为系统朗读所需纯文本；状态变化直接反馈在原菜单入口，不额外弹成功提示。
    private func startSpeakingCurrentNote() {
        guard let detail = selectedNoteDetail else { return }
        let content = RichTextBridge.htmlToAttributed(detail.contentHTML).string
        let idea = RichTextBridge.htmlToAttributed(detail.ideaHTML).string
        guard speechController.start(content: content, idea: idea) else {
            toastCenter.warning("当前书摘没有可朗读内容")
            return
        }
    }

    /// 立即展示处理中反馈并串行生成 PNG；离场取消会清理尚未交给系统分享面板的本次临时文件。
    private func generateShareCard() {
        guard !isGeneratingShareImage, let detail = selectedNoteDetail else { return }

        withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
            isGeneratingShareImage = true
        }
        toastCenter.processing("正在生成分享图…")
        let processingToastID = toastCenter.current?.id ?? UUID()
        let isDarkAppearance = colorScheme == .dark

        shareGenerationTask = Task { @MainActor in
            await Task.yield()
            defer {
                toastCenter.dismiss(id: processingToastID)
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.18)) {
                    isGeneratingShareImage = false
                }
                shareGenerationTask = nil
            }

            var generatedFileURL: URL?
            do {
                try Task.checkCancellation()
                let file = try await NoteReviewShareImageRenderer().renderPNG(
                    for: detail,
                    isDarkAppearance: isDarkAppearance
                )
                generatedFileURL = file.fileURL
                try Task.checkCancellation()
                sharePayload = XMActivitySharePayload(activityItems: [file.fileURL])
            } catch is CancellationError {
                if let generatedFileURL {
                    try? FileManager.default.removeItem(at: generatedFileURL)
                }
                return
            } catch {
                if let generatedFileURL {
                    try? FileManager.default.removeItem(at: generatedFileURL)
                }
                toastCenter.error("生成分享图失败：\(error.localizedDescription)")
            }
        }
    }

    private func copyCurrentDetail() {
        switch viewModel.selectedDetail {
        case .note(let detail)?:
            UIPasteboard.general.string = shareText(from: detail)
        case .review(let detail)?:
            UIPasteboard.general.string = copyText(from: detail)
        case .relevant(let detail)?:
            UIPasteboard.general.string = copyText(from: detail)
        case .none:
            break
        }
    }

    private func shareText(from detail: NoteContentDetail) -> String {
        var sections: [String] = [detail.bookTitle]

        if !detail.chapterTitle.isEmpty {
            sections.append("章节：\(detail.chapterTitle)")
        }

        let content = RichTextBridge.htmlToAttributed(detail.contentHTML).string
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !content.isEmpty {
            sections.append(content)
        }

        let idea = RichTextBridge.htmlToAttributed(detail.ideaHTML).string
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !idea.isEmpty {
            sections.append("想法：\(idea)")
        }

        return sections.joined(separator: "\n\n")
    }

    private func copyText(from detail: ReviewContentDetail) -> String {
        let content = RichTextBridge.htmlToAttributed(detail.contentHTML).string
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return [detail.title, content]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private func copyText(from detail: RelevantContentDetail) -> String {
        let content = RichTextBridge.htmlToAttributed(detail.contentHTML).string
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return [detail.title, content, detail.url]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
    }

    private func normalizedURL(_ rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let directURL = URL(string: trimmed), directURL.scheme != nil {
            return directURL
        }

        return URL(string: "https://\(trimmed)")
    }
}

/// 搜索进入详情页时展示的命中上下文，保留字段来源和片段，帮助用户确认为什么来到当前内容。
private struct ContentViewerSearchMatchContext: Identifiable, Equatable {
    let id: String
    let field: String
    let keyword: String
    let snippet: String

    static func matches(
        in detail: ContentViewerDetail,
        keyword: String
    ) -> [ContentViewerSearchMatchContext] {
        let trimmedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKeyword.isEmpty else { return [] }

        let fields: [(String, String)]
        switch detail {
        case .note(let note):
            fields = [
                ("正文", plainText(note.contentHTML)),
                ("想法", plainText(note.ideaHTML)),
                ("章节", note.chapterTitle)
            ]
        case .review(let review):
            fields = [
                ("标题", review.title),
                ("正文", plainText(review.contentHTML))
            ]
        case .relevant(let relevant):
            fields = [
                ("标题", relevant.title),
                ("正文", plainText(relevant.contentHTML)),
                ("链接", relevant.url)
            ]
        }

        return fields.compactMap { field, text in
            guard contains(text, keyword: trimmedKeyword) else { return nil }
            return ContentViewerSearchMatchContext(
                id: field,
                field: field,
                keyword: trimmedKeyword,
                snippet: snippet(from: text, keyword: trimmedKeyword)
            )
        }
    }

    private static func plainText(_ html: String) -> String {
        RichTextBridge.htmlToAttributed(html).string
            .collapsingInternalWhitespace()
    }

    private static func contains(_ text: String, keyword: String) -> Bool {
        text.range(
            of: keyword,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: text.startIndex..<text.endIndex,
            locale: .current
        ) != nil
    }

    private static func snippet(from text: String, keyword: String, maximumLength: Int = 92) -> String {
        let normalized = text.collapsingInternalWhitespace()
        guard normalized.count > maximumLength else {
            return normalized
        }
        guard let range = normalized.range(
            of: keyword,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: normalized.startIndex..<normalized.endIndex,
            locale: .current
        ) else {
            return String(normalized.prefix(maximumLength)).trimmingCharacters(in: .whitespacesAndNewlines) + "…"
        }

        let leadingContext = 24
        let trailingContext = maximumLength - leadingContext
        let start = normalized.index(range.lowerBound, offsetBy: -leadingContext, limitedBy: normalized.startIndex) ?? normalized.startIndex
        let end = normalized.index(range.lowerBound, offsetBy: trailingContext, limitedBy: normalized.endIndex) ?? normalized.endIndex
        let prefix = start > normalized.startIndex ? "…" : ""
        let suffix = end < normalized.endIndex ? "…" : ""
        return prefix + normalized[start..<end].trimmingCharacters(in: .whitespacesAndNewlines) + suffix
    }
}

private struct ContentViewerSearchContextCard: View {
    let context: ContentViewerSearchMatchContext
    let currentIndex: Int
    let totalCount: Int
    let onPrevious: () -> Void
    let onNext: () -> Void

    var body: some View {
        CardContainer(cornerRadius: CornerRadius.blockMedium, showsBorder: true, borderColor: .surfaceBorderSubtle) {
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                HStack(spacing: Spacing.cozy) {
                    Label("搜索命中", systemImage: "magnifyingglass")
                        .font(AppTypography.captionSemibold)
                        .foregroundStyle(Color.brandDeep)

                    Text(context.field)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)

                    Spacer(minLength: 0)

                    if totalCount > 1 {
                        HStack(spacing: Spacing.tight) {
                            Button(action: onPrevious) {
                                Image(systemName: "chevron.up")
                                    .font(AppTypography.captionSemibold)
                            }
                            .buttonStyle(.plain)
                            .frame(width: Spacing.actionReserved, height: Spacing.actionReserved)
                            .accessibilityLabel("上一个命中")

                            Text("\(currentIndex)/\(totalCount)")
                                .font(AppTypography.caption2Medium)
                                .foregroundStyle(Color.textSecondary)
                                .monospacedDigit()

                            Button(action: onNext) {
                                Image(systemName: "chevron.down")
                                    .font(AppTypography.captionSemibold)
                            }
                            .buttonStyle(.plain)
                            .frame(width: Spacing.actionReserved, height: Spacing.actionReserved)
                            .accessibilityLabel("下一个命中")
                        }
                        .foregroundStyle(Color.iconSecondary)
                    }
                }

                XMKeywordHighlighting.text(
                    context.snippet,
                    keyword: context.keyword,
                    baseFont: AppTypography.subheadline,
                    baseColor: Color.textPrimary
                )
                .lineLimit(3)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Spacing.base)
        }
        .accessibilityElement(children: .combine)
    }
}

/// 标签 Sheet 的稳定会话载荷，锁定触发时书摘主键，避免横向翻页后写错记录。
private struct ContentViewerTagEditSession: Identifiable {
    let noteID: Int64
    let bookTitle: String
    let snapshot: NoteReviewTagEditSnapshot

    var id: Int64 { noteID }
}

private extension ExternalAppDestination {
    var viewerMenuTitle: String {
        switch self {
        case .flomo: "发送到 Flomo"
        case .writeathon: "发送到 Writeathon"
        case .inbox: "发送到 Inbox"
        }
    }

    var viewerMenuSystemImage: String {
        switch self {
        case .flomo, .writeathon: "paperplane"
        case .inbox: "tray.and.arrow.down"
        }
    }
}

struct ContentViewerHeroCard<Accessory: View>: View {
    let title: String
    let subtitle: String
    @ViewBuilder let accessory: Accessory

    var body: some View {
        CardContainer(cornerRadius: CornerRadius.containerMedium) {
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                Text(title)
                    .font(AppTypography.brandDisplay(size: 24, relativeTo: .title3))
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                Text(subtitle)
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(2)

                accessory
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(Spacing.contentEdge)
        }
    }
}

private extension String {
    func collapsingInternalWhitespace() -> String {
        components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

#Preview {
    NavigationStack {
        ContentViewerView(
            source: .bookNotes(bookId: 1),
            initialItemID: .note(1),
            keyword: ""
        )
    }
    .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
    .environment(SceneStateStore())
    .environment(XMToastCenter())
}
