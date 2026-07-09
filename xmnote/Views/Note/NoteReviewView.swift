/**
 * [INPUT]: 依赖 NoteReviewViewModel、NoteReviewPagingDeck、NoteReviewCardView 与外部导航/设置闭包
 * [OUTPUT]: 对外提供 NoteReviewView，承载 iOS 端书摘回顾分页卡组主界面、卡片菜单与外部应用发送反馈
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
    @Environment(\.openURL) private var openURL

    @State private var loadingGate = LoadingGate()
    @State private var tagEditSession: NoteReviewTagEditSession?
    @State private var menuGalleryHost = XMJXPhotoBrowserHost(initialItems: [])
    @State private var menuGalleryTapSequence = 0

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
            ActivityShareSheet(activityItems: [file.fileURL])
                .presentationDetents([.medium, .large])
        }
        .onDisappear {
            loadingGate.hideImmediately()
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
        VStack(spacing: NoteReviewBottomLayout.actionRowSpacing) {
            NoteReviewPagingDeck(
                items: viewModel.items,
                selection: $viewModel.selectedItemID,
                hasMoreItems: viewModel.hasMoreItems,
                configuration: deckConfiguration,
                onCardAppeared: { item, index in
                    viewModel.handleCardAppeared(item, index: index)
                },
                onNeedsMoreItems: {
                    Task { await viewModel.loadMoreIfNeeded() }
                },
                onTap: { item, _ in
                    openContentViewer(for: item)
                }
            ) { item, _ in
                NoteReviewCardView(item: item, settings: viewModel.settings)
                    .contextMenu {
                        reviewCardContextMenu(for: item)
                    }
                    .padding(.horizontal, reviewLayoutSpec.cardHorizontalPadding)
                    .padding(.bottom, NoteReviewBottomLayout.cardContentBottomPadding)
            } emptyContent: {
                Color.clear
            }
            .frame(maxWidth: reviewLayoutSpec.maxDeckWidth, maxHeight: .infinity)
            .padding(.top, NoteReviewBottomLayout.deckTopPadding)
            .padding(.bottom, NoteReviewBottomLayout.deckBottomPadding)
            .animation(.smooth(duration: reduceMotion ? 0.01 : 0.22), value: viewModel.settings.palette)

            NoteReviewAuxiliaryActionRow(
                title: viewModel.settings.sortRule == .random ? "换一组" : "刷新",
                isRefreshing: viewModel.isRefreshing,
                isDisabled: viewModel.isInitialLoading || viewModel.isRefreshing,
                action: refreshCards
            )
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.bottom, NoteReviewBottomLayout.actionRowBottomPadding)
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

    private var reviewLayoutSpec: NoteReviewPagingLayoutSpec {
        .iOSReviewDefault
    }

    private var deckConfiguration: NoteReviewPagingDeckConfiguration {
        var configuration = NoteReviewPagingDeckConfiguration.iOSReviewDefault
        configuration.cardInsets = reviewLayoutSpec.cardInsets
        return configuration
    }

    private func refreshCards() {
        Task {
            await viewModel.refresh()
        }
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

    /// 生成并分享高质量回顾图片；实际渲染与相册保存由 ViewModel 编排。
    private func shareImage(for item: NoteReviewCardItem) {
        Task {
            await viewModel.shareImage(for: item)
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

private enum NoteReviewBottomLayout {
    static let cardContentBottomPadding = Spacing.cozy
    static let deckTopPadding = Spacing.base
    static let deckBottomPadding = Spacing.none
    static let actionRowSpacing = Spacing.base
    static let actionRowBottomPadding = Spacing.section
    static let actionRowMinHeight: CGFloat = 34
}

private struct NoteReviewAuxiliaryActionRow: View {
    let title: String
    let isRefreshing: Bool
    let isDisabled: Bool
    let action: () -> Void

    var body: some View {
        HStack {
            Spacer()
            Button(action: action) {
                HStack(spacing: Spacing.tiny) {
                    if isRefreshing {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(Color.textSecondary.opacity(NoteReviewAuxiliaryActionMetrics.progressOpacity))
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(AppTypography.captionMedium)
                            .accessibilityHidden(true)
                    }

                    Text(isRefreshing ? "正在刷新" : title)
                        .font(AppTypography.captionMedium)
                }
                .foregroundStyle(Color.textSecondary.opacity(isDisabled ? NoteReviewAuxiliaryActionMetrics.disabledOpacity : NoteReviewAuxiliaryActionMetrics.enabledOpacity))
                .frame(minHeight: NoteReviewBottomLayout.actionRowMinHeight)
                .contentShape(Rectangle())
            }
            .buttonStyle(NoteReviewAuxiliaryActionButtonStyle(isEnabled: !isDisabled))
            .disabled(isDisabled)
            .accessibilityLabel(title == "换一组" ? "换一组书摘" : "刷新回顾")
            .accessibilityHint("重新加载当前范围内的书摘卡片")
            Spacer()
        }
    }
}

private struct NoteReviewAuxiliaryActionButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isEnabled: Bool

    func makeBody(configuration: Configuration) -> some View {
        let isPressed = isEnabled && configuration.isPressed

        configuration.label
            .background {
                if isPressed {
                    Capsule()
                        .fill(Color.controlFillSecondary.opacity(NoteReviewAuxiliaryActionMetrics.pressedFillOpacity))
                        .padding(.horizontal, -Spacing.half)
                        .padding(.vertical, Spacing.tiny)
                        .accessibilityHidden(true)
                }
            }
            .scaleEffect(!reduceMotion && isPressed ? NoteReviewAuxiliaryActionMetrics.pressedScale : 1)
            .animation(reduceMotion ? nil : .snappy(duration: NoteReviewAuxiliaryActionMetrics.pressAnimationDuration), value: configuration.isPressed)
    }
}

private enum NoteReviewAuxiliaryActionMetrics {
    static let enabledOpacity = 0.72
    static let disabledOpacity = 0.36
    static let progressOpacity = 0.68
    static let pressedFillOpacity = 0.10
    static let pressedScale = 0.96
    static let pressAnimationDuration = 0.12
}
