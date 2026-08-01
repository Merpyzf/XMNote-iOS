/**
 * [INPUT]: 依赖 RepositoryContainer、AppNavigationCoordinator 与 ContentViewerViewModel
 * [OUTPUT]: 对外提供 ContentViewerView，统一承接书摘/书评/相关内容的分页查看与基础操作栏
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
    let navigationContext: AppTaskNavigationContext

    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: ContentViewerViewModel?
    @State private var showsDeleteDialog = false
    @State private var didBootstrap = false
    @State private var bootstrapLoadingGate = LoadingGate()

    private var presentationStyle: ContentViewerPresentationStyle {
        ContentViewerPresentationStyle(source: source)
    }

    init(
        source: ContentViewerSourceContext,
        initialItemID: ContentViewerItemID,
        keyword: String,
        navigationContext: AppTaskNavigationContext = .taskChild
    ) {
        self.source = source
        self.initialItemID = initialItemID
        self.keyword = keyword
        self.navigationContext = navigationContext
    }

    var body: some View {
        ZStack {
            if let viewModel {
                ContentViewerLoadedView(
                    viewModel: viewModel,
                    showsDeleteDialog: $showsDeleteDialog,
                    navigationContext: navigationContext
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
        .task {
            guard !didBootstrap else { return }
            didBootstrap = true
            guard viewModel == nil else { return }
            bootstrapLoadingGate.update(intent: .read)
            let newViewModel = ContentViewerViewModel(
                source: source,
                initialItemID: initialItemID,
                restoredSelectedItemID: nil,
                keyword: keyword,
                defaultTitle: presentationStyle.defaultTitle,
                missingItemMessage: presentationStyle.missingItemMessage,
                repository: repositories.contentRepository
            )
            viewModel = newViewModel
            bootstrapLoadingGate.update(intent: .none)
            newViewModel.startObservation()
        }
        .onDisappear {
            bootstrapLoadingGate.hideImmediately()
        }
    }
}

private struct ContentViewerLoadedView: View {
    @Bindable var viewModel: ContentViewerViewModel
    @Binding var showsDeleteDialog: Bool
    let navigationContext: AppTaskNavigationContext

    @Environment(\.openURL) private var openURL
    @Environment(AppNavigationCoordinator.self) private var navigationCoordinator

    @State private var bottomOrnamentHeight: CGFloat = 0
    @State private var showsTagSheet = false
    @State private var sharePayload: ContentViewerSharePayload?
    @State private var pendingPresentation: PendingCapabilityPresentation?
    @State private var listLoadingGate = LoadingGate()
    @State private var searchMatchIndex = 0

    private var presentationStyle: ContentViewerPresentationStyle {
        ContentViewerPresentationStyle(source: viewModel.source)
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
                    }
                )
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(
                Color.surfacePage.ignoresSafeArea(edges: .bottom)
            )
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
            .navigationBarBackButtonHidden(navigationContext == .modalRoot)
            .toolbar { toolbarContent }
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
        .confirmationDialog(presentationStyle.deleteDialogTitle, isPresented: $showsDeleteDialog) {
            Button("删除", role: .destructive) {
                Task { await viewModel.deleteCurrentItem() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("iOS 端当前按硬删除实现，主记录和子记录会一起删除。")
        }
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
        .sheet(item: $sharePayload) { payload in
            ActivityShareSheet(activityItems: [payload.text])
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
        }
        .onPreferenceChange(ImmersiveBottomChromeHeightPreferenceKey.self) { height in
            bottomOrnamentHeight = height
        }
        .task(id: viewModel.selectedItemID) {
            guard let selectedItemID = viewModel.selectedItemID else { return }
            await viewModel.prefetchDetails(around: selectedItemID, radius: 1)
        }
        .onDisappear {
            listLoadingGate.hideImmediately()
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if navigationContext == .modalRoot {
            ToolbarItem(placement: .cancellationAction) {
                Button("关闭") {
                    navigationCoordinator.dismissTask()
                }
            }
        }

        ToolbarItem(placement: .principal) {
            ContentViewerNavigationTitle(pageProgress: viewModel.selectedPageProgress) {
                if let selectedBookID = viewModel.selectedBookID {
                    Button {
                        navigationCoordinator.exitTask(
                            to: .book(.detail(bookId: selectedBookID))
                        )
                    } label: {
                        contentViewerTitleLabel(viewModel.selectedBookTitle)
                    }
                    .buttonStyle(.plain)
                } else {
                    contentViewerTitleLabel(viewModel.selectedBookTitle)
                }
            }
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
                    navigationCoordinator.present(
                        .noteEditor(mode: .edit(noteId: noteID), seed: nil)
                    )
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
                    navigationCoordinator.present(.reviewEditor(reviewID: reviewID))
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

                Button {
                    presentPending(.aiAssistant)
                } label: {
                    ImmersiveBottomChromeIcon(systemName: "sparkles")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("书评 AI")

            case .relevant(let contentID)?:
                Button {
                    navigationCoordinator.present(.relevantEditor(contentID: contentID))
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

                Button {
                    presentPending(.aiAssistant)
                } label: {
                    ImmersiveBottomChromeIcon(systemName: "sparkles")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("相关内容 AI")

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
                presentPending(.editTags)
            } label: {
                XMMenuLabel("编辑标签", systemImage: "pencil")
            }
        } label: {
            ImmersiveBottomChromeIcon(systemName: "tag")
        }
        .buttonStyle(.plain)
        .xmMenuNeutralTint()
        .accessibilityLabel("标签")
    }

    private var noteAPISendMenu: some View {
        Menu {
            Button {
                presentPending(.apiSend)
            } label: {
                XMMenuLabel("发送到 Flomo", systemImage: "paperplane")
            }
            Button {
                presentPending(.apiSend)
            } label: {
                XMMenuLabel("发送到 Writeathon", systemImage: "paperplane")
            }
            Button {
                presentPending(.apiSend)
            } label: {
                XMMenuLabel("发送到 Inbox", systemImage: "tray.and.arrow.down")
            }
        } label: {
            ImmersiveBottomChromeIcon(systemName: "paperplane")
        }
        .buttonStyle(.plain)
        .xmMenuNeutralTint()
        .accessibilityLabel("API 外发")
    }

    private var noteShareMenu: some View {
        Menu {
            Button {
                shareCurrentNote()
            } label: {
                XMMenuLabel("系统分享", systemImage: "square.and.arrow.up")
            }
            Button {
                presentPending(.shareCard)
            } label: {
                XMMenuLabel("分享卡片", systemImage: "rectangle.portrait.on.rectangle.portrait")
            }
        } label: {
            ImmersiveBottomChromeIcon(systemName: "square.and.arrow.up")
        }
        .buttonStyle(.plain)
        .xmMenuNeutralTint()
        .accessibilityLabel("分享书摘")
    }

    private var noteAIMenu: some View {
        Menu {
            Button {
                presentPending(.aiExplain)
            } label: {
                XMMenuLabel("AI 解读", systemImage: "sparkles")
            }
            Button {
                presentPending(.autoTag)
            } label: {
                XMMenuLabel("自动标签", systemImage: "tag")
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

    private func presentPending(_ capability: ContentViewerPendingCapability) {
        pendingPresentation = PendingCapabilityPresentation(capability: capability)
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
        sharePayload = ContentViewerSharePayload(text: shareText(from: detail))
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
}
