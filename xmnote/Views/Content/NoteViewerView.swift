/**
 * [INPUT]: 依赖 RepositoryContainer 注入内容仓储，依赖 NoteViewerViewModel 驱动书摘分页与详情状态
 * [OUTPUT]: 对外提供 NoteViewerView，承接书摘全屏查看与底部 ornament 风格操作区
 * [POS]: Content 模块书摘查看壳层，被时间线与书籍详情共同复用
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 书摘全屏查看器，对齐 Android 的顶部进度、横向翻页和底部操作结构。
struct NoteViewerView: View {
    let source: ContentViewerSourceContext
    let initialNoteID: Int64

    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.dismiss) private var dismiss

    @State private var viewModel: NoteViewerViewModel?
    @State private var showsDeleteDialog = false
    @State private var showsTagSheet = false
    @State private var sharePayload: NoteViewerSharePayload?

    var body: some View {
        Group {
            if let viewModel {
                NoteViewerLoadedView(
                    viewModel: viewModel,
                    showsDeleteDialog: $showsDeleteDialog,
                    showsTagSheet: $showsTagSheet,
                    sharePayload: $sharePayload
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
            let newViewModel = NoteViewerViewModel(
                source: source,
                initialNoteID: initialNoteID,
                repository: repositories.contentRepository
            )
            viewModel = newViewModel
            newViewModel.startObservation()
        }
    }
}

private struct NoteViewerLoadedView: View {
    @Bindable var viewModel: NoteViewerViewModel
    @Binding var showsDeleteDialog: Bool
    @Binding var showsTagSheet: Bool
    @Binding var sharePayload: NoteViewerSharePayload?
    @State private var bottomOrnamentHeight: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            let safeAreaBottomInset = proxy.safeAreaInsets.bottom

            NoteViewerContentView(
                props: contentProps,
                bottomChromeMetrics: bottomChromeMetrics(safeAreaBottomInset: safeAreaBottomInset),
                onPagerSelectionChanged: { viewModel.select($0) },
                onLoadDetail: { noteID in
                    await viewModel.loadDetailIfNeeded(noteID: noteID)
                },
                onRefreshDetail: { noteID in
                    await viewModel.refreshDetail(noteID: noteID)
                }
            )
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
        .confirmationDialog("删除当前书摘？", isPresented: $showsDeleteDialog) {
            Button("删除", role: .destructive) {
                Task { await viewModel.deleteCurrentNote() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("iOS 端当前按硬删除实现，主记录和子记录会一起删除。")
        }
        .sheet(isPresented: $showsTagSheet) {
            NoteViewerTagSheet(
                tags: viewModel.selectedTagNames,
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
        .task(id: viewModel.selectedNoteID) {
            guard let selectedNoteID = viewModel.selectedNoteID else { return }
            await viewModel.prefetchDetails(around: selectedNoteID, radius: 1)
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
                HStack(spacing: Spacing.cozy) {
                    Button {
                        showsTagSheet = true
                    } label: {
                        ImmersiveBottomChromeIcon(systemName: "tag")
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.selectedTagNames.isEmpty)
                    .accessibilityLabel("查看标签")

                    if let noteID = viewModel.selectedNoteID {
                        NavigationLink(value: NoteRoute.edit(noteId: noteID)) {
                            ImmersiveBottomChromeIcon(systemName: "square.and.pencil")
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("编辑书摘")
                    } else {
                        ImmersiveBottomChromeIcon(systemName: "square.and.pencil")
                            .opacity(0.4)
                    }

                    Button {
                        guard let detail = viewModel.selectedDetail else { return }
                        sharePayload = NoteViewerSharePayload(text: shareText(from: detail))
                    } label: {
                        ImmersiveBottomChromeIcon(systemName: "square.and.arrow.up")
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.selectedDetail == nil)
                    .accessibilityLabel("分享书摘")
                }
                .padding(.horizontal, Spacing.base)
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
                .disabled(viewModel.selectedNoteID == nil || viewModel.isDeleting)
                .glassEffect(.regular.interactive(), in: .circle)
                .accessibilityLabel("删除书摘")
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: ImmersiveBottomChromeHeightPreferenceKey.self, value: proxy.size.height)
            }
        }
    }

    private func bottomChromeMetrics(safeAreaBottomInset: CGFloat) -> ImmersiveBottomChromeMetrics {
        ImmersiveBottomChromeMetrics.make(
            measuredOrnamentHeight: bottomOrnamentHeight,
            safeAreaBottomInset: safeAreaBottomInset
        )
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

    private var contentProps: NoteViewerContentView.Props {
        NoteViewerContentView.Props(
            selectedNoteID: viewModel.selectedNoteID,
            listState: listState,
            notePages: visibleNoteItems.map(makeNotePage)
        )
    }

    private var visibleNoteItems: [ContentViewerListItem] {
        viewModel.visibleNoteItems(radius: 3)
    }

    private var listState: NoteViewerContentView.Props.ListState {
        if viewModel.items.isEmpty {
            if viewModel.isLoadingList {
                return .loading
            }
            return .empty(viewModel.listErrorMessage ?? "书摘不存在或已删除")
        }
        return .content
    }

    private func makeNotePage(_ item: ContentViewerListItem) -> NoteViewerContentView.Props.NotePage {
        NoteViewerContentView.Props.NotePage(
            noteID: item.noteID,
            state: pageState(for: item.noteID),
            isSelected: item.noteID == viewModel.selectedNoteID
        )
    }

    private func pageState(for noteID: Int64) -> NoteViewerContentView.Props.NotePageState {
        if let detail = viewModel.detail(for: noteID) {
            return .detail(detail)
        }
        if let message = viewModel.detailErrorMessage(for: noteID) {
            return .error(message)
        }
        return .loading
    }
}

struct NoteViewerTagSheet: View {
    let tags: [String]
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Spacing.base) {
                if tags.isEmpty {
                    Text("当前书摘没有标签")
                        .font(AppTypography.body)
                        .foregroundStyle(Color.textSecondary)
                } else {
                    FlowTagWrap(tags: tags)
                }

                Spacer(minLength: 0)
            }
            .padding(Spacing.screenEdge)
            .navigationTitle("标签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成", action: onDismiss)
                }
            }
        }
    }
}

struct FlowTagWrap: View {
    let tags: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            ForEach(chunkedTags, id: \.self) { row in
                HStack(spacing: Spacing.cozy) {
                    ForEach(row, id: \.self) { tag in
                        Text(tag)
                            .font(AppTypography.subheadline)
                            .foregroundStyle(Color.textPrimary)
                            .padding(.horizontal, Spacing.cozy)
                            .padding(.vertical, Spacing.compact)
                            .background(Color.tagBackground, in: Capsule())
                    }
                    Spacer(minLength: 0)
                }
            }
        }
    }

    private var chunkedTags: [[String]] {
        stride(from: 0, to: tags.count, by: 3).map { index in
            Array(tags[index..<min(index + 3, tags.count)])
        }
    }
}

private struct NoteViewerSharePayload: Identifiable {
    let text: String
    let id = UUID()
}

struct ActivityShareSheet: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

#Preview {
    NavigationStack {
        NoteViewerView(
            source: .bookNotes(bookId: 1),
            initialNoteID: 1
        )
    }
    .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
}
