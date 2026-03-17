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

    var body: some View {
        Group {
            if viewModel.items.isEmpty {
                emptyState
            } else {
                pager
            }
        }
        .background(Color.surfacePage)
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .safeAreaInset(edge: .bottom) {
            if !viewModel.items.isEmpty {
                bottomToolbar
            }
        }
        .confirmationDialog("删除当前内容？", isPresented: $showsDeleteDialog) {
            Button("删除", role: .destructive) {
                Task { await viewModel.deleteCurrentItem() }
            }
            Button("取消", role: .cancel) { }
        } message: {
            Text("iOS 端当前按硬删除实现，主记录和子记录会一起删除。")
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: Spacing.base) {
            if viewModel.isLoadingList {
                ProgressView("正在加载内容…")
            } else {
                Image(systemName: "doc.text.magnifyingglass")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(viewModel.listErrorMessage ?? "内容不存在或已删除")
                    .font(AppTypography.body)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pager: some View {
        let fallbackSelection = viewModel.selectedItemID ?? viewModel.items.first?.id ?? initialFallbackSelection
        return VStack(spacing: Spacing.none) {
            if let listErrorMessage = viewModel.listErrorMessage, !listErrorMessage.isEmpty {
                viewerMessageCard(text: listErrorMessage)
                    .padding(.horizontal, Spacing.screenEdge)
                    .padding(.top, Spacing.base)
            }

            TabView(
                selection: Binding(
                    get: { viewModel.selectedItemID ?? fallbackSelection },
                    set: { viewModel.select($0) }
                )
            ) {
                ForEach(viewModel.items) { item in
                    ContentViewerPage(
                        item: item,
                        viewModel: viewModel
                    )
                    .tag(item.id)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
        }
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
    }

    private var initialFallbackSelection: ContentViewerItemID {
        .note(0)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            ContentViewerNavigationTitle(pageProgress: viewModel.selectedPageProgress) {
                contentViewerTitleLabel(viewModel.selectedBookTitle)
            }
        }
    }

    private var bottomToolbar: some View {
        VStack(spacing: Spacing.none) {
            Divider()
            HStack(spacing: Spacing.base) {
                if let selectedBookID = viewModel.selectedBookID {
                    NavigationLink(value: BookRoute.detail(bookId: selectedBookID)) {
                        actionLabel(title: "书籍", systemImage: "book.closed")
                    }
                    .buttonStyle(.plain)
                } else {
                    disabledActionLabel(title: "书籍", systemImage: "book.closed")
                }

                editAction

                Button(role: .destructive) {
                    showsDeleteDialog = true
                } label: {
                    actionLabel(title: "删除", systemImage: "trash")
                }
                .buttonStyle(.plain)
                .disabled(viewModel.isDeleting || viewModel.selectedItemID == nil)
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.top, Spacing.cozy)
            .padding(.bottom, Spacing.cozy)
            .background(Color.surfacePage)
        }
    }

    @ViewBuilder
    private var editAction: some View {
        switch viewModel.selectedItemID {
        case .note(let noteId):
            NavigationLink(value: NoteRoute.edit(noteId: noteId)) {
                actionLabel(title: "编辑", systemImage: "pencil")
            }
            .buttonStyle(.plain)

        case .review(let reviewId):
            NavigationLink(value: ContentRoute.reviewEditor(reviewId: reviewId)) {
                actionLabel(title: "编辑", systemImage: "pencil")
            }
            .buttonStyle(.plain)

        case .relevant(let contentId):
            NavigationLink(value: ContentRoute.relevantEditor(contentId: contentId)) {
                actionLabel(title: "编辑", systemImage: "pencil")
            }
            .buttonStyle(.plain)

        case .none:
            disabledActionLabel(title: "编辑", systemImage: "pencil")
        }
    }

    private func actionLabel(title: String, systemImage: String) -> some View {
        VStack(spacing: Spacing.tiny) {
            Image(systemName: systemImage)
                .font(AppTypography.subheadline)
            Text(title)
                .font(AppTypography.caption2)
        }
        .frame(maxWidth: .infinity, minHeight: 52)
        .foregroundStyle(Color.textPrimary)
        .background(
            RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                .fill(Color.surfaceCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                .stroke(Color.surfaceBorderDefault, lineWidth: CardStyle.borderWidth)
        )
    }

    private func disabledActionLabel(title: String, systemImage: String) -> some View {
        actionLabel(title: title, systemImage: systemImage)
            .foregroundStyle(Color.textHint)
            .opacity(0.45)
    }
}

private struct ContentViewerPage: View {
    let item: ContentViewerListItem
    @Bindable var viewModel: ContentViewerViewModel

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.base) {
                switch contentState {
                case .loading:
                    ProgressView("正在加载内容…")
                        .frame(maxWidth: .infinity, minHeight: 320)
                case .error(let message):
                    viewerMessageCard(text: message)
                case .detail(let detail):
                    detailView(for: detail)
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
        }
        .background(Color.surfacePage)
        .task(id: item.id) {
            await viewModel.loadDetailIfNeeded(itemID: item.id)
        }
        .onAppear {
            guard viewModel.selectedItemID == item.id else { return }
            Task { await viewModel.refreshDetail(itemID: item.id) }
        }
    }

    private var contentState: ContentPageState {
        if let detail = viewModel.detail(for: item.id) {
            return .detail(detail)
        }
        if let message = viewModel.detailErrorMessage(for: item.id) {
            return .error(message)
        }
        return .loading
    }

    @ViewBuilder
    private func detailView(for detail: ContentViewerDetail) -> some View {
        switch detail {
        case .note(let note):
            noteDetailView(note)
        case .review(let review):
            reviewDetailView(review)
        case .relevant(let relevant):
            relevantDetailView(relevant)
        }
    }

    private func noteDetailView(_ detail: NoteContentDetail) -> some View {
        Group {
            ContentViewerHeroCard(
                title: detail.bookTitle,
                subtitle: detail.chapterTitle.isEmpty ? "书摘" : detail.chapterTitle
            ) {
                if let metadataText = noteMetadataText(detail), !metadataText.isEmpty {
                    Text(metadataText)
                        .font(AppTypography.caption)
                        .foregroundStyle(.secondary)
                }
            }

            contentSectionCard(title: "书摘内容") {
                RichText(
                    html: detail.contentHTML,
                    baseFont: AppTypography.uiSemantic(.body),
                    textColor: UIColor.label,
                    lineSpacing: 5
                )
            }

            if TimelineMeaningfulPreview.hasMeaningfulHTML(detail.ideaHTML) {
                contentSectionCard(title: "想法") {
                    RichText(
                        html: detail.ideaHTML,
                        baseFont: AppTypography.uiSemantic(.body),
                        textColor: UIColor(Color.textSecondary),
                        lineSpacing: 5
                    )
                }
            }

            if !detail.imageURLs.isEmpty {
                contentSectionCard(title: "附图") {
                    viewerImageWall(detail.imageURLs, prefix: "note")
                }
            }

            if !detail.tagNames.isEmpty {
                contentSectionCard(title: "标签") {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: Spacing.tight) {
                            ForEach(detail.tagNames, id: \.self) { tag in
                                Text(tag)
                                    .font(AppTypography.caption2)
                                    .foregroundStyle(Color.textSecondary)
                                    .padding(.horizontal, Spacing.cozy)
                                    .padding(.vertical, Spacing.compact)
                                    .background(Color.tagBackground, in: Capsule())
                            }
                        }
                    }
                }
            }
        }
    }

    private func reviewDetailView(_ detail: ReviewContentDetail) -> some View {
        Group {
            ContentViewerHeroCard(
                title: detail.bookTitle,
                subtitle: "书评"
            ) {
                if detail.bookScore > 0 {
                    ViewerScoreRow(score: detail.bookScore)
                }
                if let dateText = formattedDate(detail.createdDate) {
                    Text(dateText)
                        .font(AppTypography.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !detail.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                contentSectionCard(title: "标题") {
                    Text(detail.title)
                        .font(AppTypography.subheadlineSemibold)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if TimelineMeaningfulPreview.hasMeaningfulHTML(detail.contentHTML) {
                contentSectionCard(title: "正文") {
                    RichText(
                        html: detail.contentHTML,
                        baseFont: AppTypography.uiSemantic(.body),
                        textColor: UIColor.label,
                        lineSpacing: 5
                    )
                }
            }

            if !detail.imageURLs.isEmpty {
                contentSectionCard(title: "配图") {
                    viewerImageWall(detail.imageURLs, prefix: "review")
                }
            }
        }
    }

    private func relevantDetailView(_ detail: RelevantContentDetail) -> some View {
        Group {
            ContentViewerHeroCard(
                title: detail.bookTitle,
                subtitle: detail.categoryTitle.isEmpty ? "相关内容" : detail.categoryTitle
            ) {
                if let dateText = formattedDate(detail.createdDate) {
                    Text(dateText)
                        .font(AppTypography.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !detail.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                contentSectionCard(title: "标题") {
                    Text(detail.title)
                        .font(AppTypography.subheadlineSemibold)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            if TimelineMeaningfulPreview.hasMeaningfulHTML(detail.contentHTML) {
                contentSectionCard(title: "正文") {
                    RichText(
                        html: detail.contentHTML,
                        baseFont: AppTypography.uiSemantic(.body),
                        textColor: UIColor.label,
                        lineSpacing: 5
                    )
                }
            } else if let normalizedURL = normalizedURL(detail.url) {
                contentSectionCard(title: "链接") {
                    Link(destination: normalizedURL) {
                        Text(normalizedURL.absoluteString)
                            .font(AppTypography.subheadline)
                            .foregroundStyle(Color.brandDeep)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }

            if !detail.imageURLs.isEmpty {
                contentSectionCard(title: "附图") {
                    viewerImageWall(detail.imageURLs, prefix: "relevant")
                }
            }

            if let normalizedURL = normalizedURL(detail.url), TimelineMeaningfulPreview.hasMeaningfulHTML(detail.contentHTML) {
                contentSectionCard(title: "链接") {
                    Link(destination: normalizedURL) {
                        HStack(spacing: Spacing.compact) {
                            Image(systemName: "link")
                            Text(normalizedURL.absoluteString)
                                .lineLimit(1)
                        }
                        .font(AppTypography.subheadline)
                        .foregroundStyle(Color.brandDeep)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
    }

    private func contentSectionCard<Content: View>(
        title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        CardContainer {
            VStack(alignment: .leading, spacing: Spacing.base) {
                Text(title)
                    .font(AppTypography.subheadlineSemibold)
                    .foregroundStyle(.secondary)
                content()
            }
            .padding(Spacing.contentEdge)
        }
    }

    private func viewerImageWall(_ imageURLs: [String], prefix: String) -> some View {
        XMJXImageWall(
            items: imageURLs.enumerated().map { index, url in
                XMJXGalleryItem(
                    id: "\(prefix)-img-\(index)",
                    thumbnailURL: url,
                    originalURL: url
                )
            },
            columnCount: imageURLs.count == 1 ? 1 : 3
        )
    }

    private func noteMetadataText(_ detail: NoteContentDetail) -> String? {
        var parts: [String] = []
        let trimmedPosition = detail.position.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmedPosition.isEmpty {
            let unitLabel = switch detail.positionUnit {
            case 1: "位置"
            case 2: "%"
            default: "页"
            }
            parts.append(detail.positionUnit == 2 ? "\(trimmedPosition)\(unitLabel)" : "第\(trimmedPosition)\(unitLabel)")
        }
        if detail.includeTime, let dateText = formattedDate(detail.createdDate) {
            parts.append(dateText)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    private func formattedDate(_ timestamp: Int64) -> String? {
        guard timestamp > 0 else { return nil }
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000.0)
        return ContentViewerDateFormatter.shared.string(from: date)
    }

    private func normalizedURL(_ rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let directURL = URL(string: trimmed) {
            return directURL
        }
        guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) else {
            return nil
        }
        return URL(string: encoded)
    }
}

private enum ContentPageState {
    case loading
    case error(String)
    case detail(ContentViewerDetail)
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
