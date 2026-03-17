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
        .safeAreaBar(edge: .bottom, spacing: Spacing.none) {
            if !viewModel.items.isEmpty {
                bottomOrnament
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
    }

    @ViewBuilder
    private var emptyState: some View {
        VStack(spacing: Spacing.base) {
            if viewModel.isLoadingList {
                ProgressView("正在加载书摘…")
            } else {
                Image(systemName: "text.quote")
                    .font(.system(size: 28, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text(viewModel.listErrorMessage ?? "书摘不存在或已删除")
                    .font(AppTypography.body)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pager: some View {
        let fallbackSelection = viewModel.selectedNoteID ?? viewModel.items.first?.noteID ?? 0
        return TabView(
            selection: Binding(
                get: { viewModel.selectedNoteID ?? fallbackSelection },
                set: { viewModel.select($0) }
            )
        ) {
            ForEach(viewModel.items) { item in
                NoteViewerPage(
                    noteID: item.noteID,
                    viewModel: viewModel
                )
                .tag(item.noteID)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .principal) {
            if let selectedBookID = viewModel.selectedBookID {
                NavigationLink(value: BookRoute.detail(bookId: selectedBookID)) {
                    Text(viewModel.selectedBookTitle)
                        .font(AppTypography.subheadlineSemibold)
                        .lineLimit(1)
                        .foregroundStyle(Color.textPrimary)
                }
                .buttonStyle(.plain)
            } else {
                Text(viewModel.selectedBookTitle)
                    .font(AppTypography.subheadlineSemibold)
                    .lineLimit(1)
                    .foregroundStyle(Color.textPrimary)
            }
        }

        ToolbarItem(placement: .topBarTrailing) {
            if viewModel.items.count > 1 {
                Text(viewModel.selectedPageText)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .padding(.horizontal, Spacing.cozy)
                    .padding(.vertical, Spacing.micro)
                    .background(Color.surfaceCard, in: Capsule())
                    .overlay(Capsule().stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth))
                    .monospacedDigit()
            }
        }
    }

    private var bottomOrnament: some View {
        HStack {
            Spacer(minLength: 0)

            GlassEffectContainer(spacing: Spacing.base) {
                HStack(spacing: Spacing.base) {
                    HStack(spacing: Spacing.cozy) {
                        Button {
                            showsTagSheet = true
                        } label: {
                            NoteViewerOrnamentIcon(systemName: "tag")
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.selectedTagNames.isEmpty)
                        .accessibilityLabel("查看标签")

                        if let noteID = viewModel.selectedNoteID {
                            NavigationLink(value: NoteRoute.edit(noteId: noteID)) {
                                NoteViewerOrnamentIcon(systemName: "square.and.pencil")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("编辑书摘")
                        } else {
                            NoteViewerOrnamentIcon(systemName: "square.and.pencil")
                                .opacity(0.4)
                        }

                        Button {
                            guard let detail = viewModel.selectedDetail else { return }
                            sharePayload = NoteViewerSharePayload(text: shareText(from: detail))
                        } label: {
                            NoteViewerOrnamentIcon(systemName: "square.and.arrow.up")
                        }
                        .buttonStyle(.plain)
                        .disabled(viewModel.selectedDetail == nil)
                        .accessibilityLabel("分享书摘")
                    }
                    .padding(.horizontal, Spacing.base)
                    .padding(.vertical, Spacing.half)
                    .glassEffect(.regular, in: .capsule)

                    Button(role: .destructive) {
                        showsDeleteDialog = true
                    } label: {
                        NoteViewerOrnamentIcon(
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

            Spacer(minLength: 0)
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.top, Spacing.cozy)
        .padding(.bottom, Spacing.base)
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
}

private struct NoteViewerPage: View {
    let noteID: Int64
    @Bindable var viewModel: NoteViewerViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Spacing.base) {
                switch contentState {
                case .loading:
                    ProgressView("正在加载书摘…")
                        .frame(maxWidth: .infinity, minHeight: 320)
                case .error(let message):
                    viewerMessageCard(text: message)
                case .detail(let detail):
                    noteDetailView(detail)
                }
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.top, Spacing.base)
            .padding(.bottom, 96)
        }
        .background(Color.surfacePage)
        .task(id: noteID) {
            await viewModel.loadDetailIfNeeded(noteID: noteID)
        }
        .onAppear {
            guard viewModel.selectedNoteID == noteID else { return }
            Task { await viewModel.refreshDetail(noteID: noteID) }
        }
    }

    private var contentState: NoteContentPageState {
        if let detail = viewModel.detail(for: noteID) {
            return .detail(detail)
        }
        if let message = viewModel.detailErrorMessage(for: noteID) {
            return .error(message)
        }
        return .loading
    }

    private func noteDetailView(_ detail: NoteContentDetail) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            noteMeta(detail)

            if TimelineMeaningfulPreview.hasMeaningfulHTML(detail.contentHTML) {
                RichText(
                    html: detail.contentHTML,
                    baseFont: AppTypography.uiSemantic(.body),
                    textColor: UIColor.label,
                    lineSpacing: 5
                )
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if TimelineMeaningfulPreview.hasMeaningfulHTML(detail.ideaHTML) {
                RichText(
                    html: detail.ideaHTML,
                    baseFont: AppTypography.uiSemantic(.body),
                    textColor: UIColor(Color.textSecondary),
                    lineSpacing: 5
                )
                .padding(Spacing.cozy)
                .background(
                    Color.surfaceCard,
                    in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                )
            }

            if !detail.imageURLs.isEmpty {
                ContentImageWall(
                    imageURLs: detail.imageURLs,
                    prefix: "note"
                )
            }

            if let footer = footerText(for: detail), !footer.isEmpty {
                Text(footer)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .multilineTextAlignment(.leading)
                    .padding(.top, Spacing.half)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func noteMeta(_ detail: NoteContentDetail) -> some View {
        if detail.includeTime || !detail.tagNames.isEmpty {
            VStack(alignment: .leading, spacing: Spacing.cozy) {
                if detail.includeTime, let dateText = formattedDate(detail.createdDate) {
                    Text(dateText)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                }

                if !detail.tagNames.isEmpty {
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

    private func footerText(for detail: NoteContentDetail) -> String? {
        var parts: [String] = []

        if !detail.position.isEmpty {
            let positionLabel: String
            switch detail.positionUnit {
            case 1:
                positionLabel = "位置"
            case 2:
                positionLabel = "页码"
            default:
                positionLabel = "进度"
            }
            let value = detail.positionUnit == 3 ? "\(detail.position)%" : detail.position
            parts.append("\(positionLabel)：\(value)")
        }

        if !detail.chapterTitle.isEmpty {
            parts.append("章节：\(detail.chapterTitle)")
        }

        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    private func formattedDate(_ timestamp: Int64) -> String? {
        guard timestamp > 0 else { return nil }
        return ContentDetailDateFormatter.full.string(
            from: Date(timeIntervalSince1970: TimeInterval(timestamp) / 1000)
        )
    }
}

private enum NoteContentPageState {
    case loading
    case error(String)
    case detail(NoteContentDetail)
}

private struct NoteViewerOrnamentIcon: View {
    let systemName: String
    var foregroundStyle: Color = .textPrimary

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(foregroundStyle)
            .frame(width: 44, height: 44)
            .contentShape(Circle())
    }
}

private struct NoteViewerTagSheet: View {
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

private struct FlowTagWrap: View {
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

private struct ActivityShareSheet: UIViewControllerRepresentable {
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
