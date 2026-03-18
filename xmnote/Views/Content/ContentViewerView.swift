/**
 * [INPUT]: 依赖 RepositoryContainer 注入内容仓储，依赖 ContentViewerViewModel 驱动分页与详情状态
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

    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: ContentViewerViewModel?
    @State private var showsDeleteDialog = false

    private var presentationStyle: ContentViewerPresentationStyle {
        ContentViewerPresentationStyle(source: source)
    }

    var body: some View {
        Group {
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
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.surfacePage)
            }
        }
        .task {
            guard viewModel == nil else { return }
            let newViewModel = ContentViewerViewModel(
                source: source,
                initialItemID: initialItemID,
                defaultTitle: presentationStyle.defaultTitle,
                missingItemMessage: presentationStyle.missingItemMessage,
                repository: repositories.contentRepository
            )
            viewModel = newViewModel
            newViewModel.startObservation()
        }
    }
}

private struct ContentViewerLoadedView: View {
    @Bindable var viewModel: ContentViewerViewModel
    @Binding var showsDeleteDialog: Bool

    @Environment(\.openURL) private var openURL

    @State private var bottomOrnamentHeight: CGFloat = 0
    @State private var showsTagSheet = false
    @State private var sharePayload: ContentViewerSharePayload?

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
            .toolbar { toolbarContent }
            .overlay {
                if viewModel.isDeleting {
                    Color.overlay.ignoresSafeArea()
                    ProgressView("正在删除…")
                        .padding(Spacing.contentEdge)
                        .background(
                            Color.surfaceCard,
                            in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                        )
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
        .onPreferenceChange(ImmersiveBottomChromeHeightPreferenceKey.self) { height in
            bottomOrnamentHeight = height
        }
        .task(id: viewModel.selectedItemID) {
            guard let selectedItemID = viewModel.selectedItemID else { return }
            await viewModel.prefetchDetails(around: selectedItemID, radius: 1)
        }
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            ContentViewerNavigationTitle(pageProgress: viewModel.selectedPageProgress) {
                if let selectedBookID = viewModel.selectedBookID {
                    NavigationLink(value: BookRoute.detail(bookId: selectedBookID)) {
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
            HStack(spacing: Spacing.base) {
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
                Button {
                    showsTagSheet = true
                } label: {
                    ImmersiveBottomChromeIcon(systemName: "tag")
                }
                .buttonStyle(.plain)
                .disabled(selectedTagNames.isEmpty)
                .accessibilityLabel("查看标签")

                NavigationLink(value: NoteRoute.edit(noteId: noteID)) {
                    ImmersiveBottomChromeIcon(systemName: "square.and.pencil")
                }
                .buttonStyle(.plain)
                .accessibilityLabel("编辑书摘")

                Button {
                    guard let detail = selectedNoteDetail else { return }
                    sharePayload = ContentViewerSharePayload(text: shareText(from: detail))
                } label: {
                    ImmersiveBottomChromeIcon(systemName: "square.and.arrow.up")
                }
                .buttonStyle(.plain)
                .disabled(selectedNoteDetail == nil)
                .accessibilityLabel("分享书摘")

            case .review(let reviewID)?:
                NavigationLink(value: ContentRoute.reviewEditor(reviewId: reviewID)) {
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
                NavigationLink(value: ContentRoute.relevantEditor(contentId: contentID)) {
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
                return .loading
            }
            return .empty(viewModel.listErrorMessage ?? presentationStyle.missingItemMessage)
        }
        return .content
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

    private var relevantURL: URL? {
        guard let selectedRelevantDetail else { return nil }
        return normalizedURL(selectedRelevantDetail.url)
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

struct ViewerScoreRow: View {
    let score: Int64

    var body: some View {
        HStack(spacing: Spacing.tiny) {
            ForEach(1...5, id: \.self) { index in
                Image(systemName: imageName(for: index))
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.statusDone)
            }
        }
    }

    private func imageName(for index: Int) -> String {
        let normalizedScore = Double(score) / 10.0
        let threshold = Double(index)
        if normalizedScore >= threshold {
            return "star.fill"
        }
        if normalizedScore >= threshold - 0.5 {
            return "star.leadinghalf.filled"
        }
        return "star"
    }
}

#Preview {
    NavigationStack {
        ContentViewerView(
            source: .bookNotes(bookId: 1),
            initialItemID: .note(1)
        )
    }
    .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
}
