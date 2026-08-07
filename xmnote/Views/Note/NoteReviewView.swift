/**
 * [INPUT]: 依赖 NoteReviewViewModel、页面私有 NoteReviewRefreshDeckHost、NoteReviewCardView 与外部导航/设置闭包
 * [OUTPUT]: 对外提供 NoteReviewView，承载 iOS 端书摘回顾分页卡组主界面、随机换组交接、原尺寸卡片菜单、可取消分享图任务、系统分享面板与外部应用发送反馈
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    @State private var loadingGate = LoadingGate()
    @State private var tagEditSession: NoteReviewTagEditSession?
    @State private var menuGalleryHost = XMJXPhotoBrowserHost(initialItems: [])
    @State private var menuGalleryTapSequence = 0
    @State private var shareImageTask: Task<Void, Never>?
    @State private var shareImageRequestID: UUID?

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
                item: session.item,
                snapshot: session.snapshot,
                onCreateTag: { name in
                    await viewModel.createTag(named: name)
                },
                onSave: { tags in
                    await viewModel.replaceTags(tags, for: session.item)
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $viewModel.generatedShareFile) { file in
            XMActivityShareSheet(activityItems: [file.fileURL])
                .presentationDetents([.medium, .large])
        }
        .onDisappear {
            loadingGate.hideImmediately()
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
            onCardTapped: openContentViewer
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
        Task {
            guard let snapshot = await viewModel.fetchTagEditSnapshot(for: item) else { return }
            tagEditSession = NoteReviewTagEditSession(item: item, snapshot: snapshot)
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

private extension ExternalAppDestination {
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

private struct NoteReviewTagEditSession: Identifiable {
    let item: NoteReviewCardItem
    let snapshot: NoteReviewTagEditSnapshot

    var id: Int64 {
        item.id
    }
}
