/**
 * [INPUT]: 依赖 RepositoryContainer 注入 NoteRepository/OCRRepository，依赖 NoteMergeViewModel、NoteTextComposerView、XMTagLabel 与页面私有图片占位外观
 * [OUTPUT]: 对外提供 NoteMergeView，覆盖正文/想法独立排序与分隔、富文本编辑、统一标签草稿选择、图片并集、中性元信息菜单及真实事务合并
 * [POS]: Note 模块书摘合并页面，由 NoteRoute.mergeNotes 进入
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 书摘合并页图片占位容器的私有外观，避免与领域标签产生伪共享。
private enum NoteMergeAppearance {
    static let imagePlaceholderBackground = Color.xmAdaptive(
        light: Color.xmHex(0xE8F0EC),
        dark: Color.xmHex(0x343536)
    )
}

/// 书摘合并页；所有预览和提交校验经 Repository 完成，页面只表达用户可见的最终选择。
struct NoteMergeView: View {
    let bookID: Int64
    let noteIDs: [Int64]
    let onOpenMergedNote: (ContentViewerSourceContext, ContentViewerItemID) -> Void

    @Environment(RepositoryContainer.self) private var repositories
    @Environment(AppState.self) private var appState
    @Environment(XMToastCenter.self) private var toastCenter
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var viewModel: NoteMergeViewModel?
    @State private var bootstrapLoadingGate = LoadingGate()
    @State private var presentedSheet: NoteMergeSheet?
    @State private var pendingSubmitConfirmation = false
    @FocusState private var isPositionFocused: Bool

    var body: some View {
        Group {
            if bootstrapLoadingGate.isVisible {
                LoadingStateView("正在生成合并预览…", style: .card)
                    .padding(Spacing.screenEdge)
            } else if let viewModel {
                mergeContent(viewModel)
            } else {
                Color.clear
            }
        }
        .background(Color.surfacePage)
        .navigationTitle("合并书摘")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard viewModel == nil else { return }
            viewModel = NoteMergeViewModel(
                bookID: bookID,
                noteIDs: noteIDs,
                repository: repositories.noteRepository,
                quotaRepository: repositories.noteImageUploadQuotaRepository
            )
        }
        .task(id: appState.isPremium) {
            await viewModel?.refreshMembershipQuota()
        }
        .onAppear(perform: syncBootstrapLoading)
        .onChange(of: viewModel == nil) { _, _ in syncBootstrapLoading() }
        .onDisappear {
            isPositionFocused = false
            bootstrapLoadingGate.hideImmediately()
            guard let viewModel else { return }
            Task { await viewModel.discardImageSessionIfNeeded() }
        }
    }

    private func syncBootstrapLoading() {
        bootstrapLoadingGate.update(intent: viewModel == nil ? .read : .none)
    }

    private func mergeContent(_ viewModel: NoteMergeViewModel) -> some View {
        NoteListPhaseHost(
            isLoading: viewModel.phase == .loading,
            isEmpty: false,
            errorMessage: failureMessage(viewModel.phase),
            loadingMessage: "正在生成合并预览…",
            emptyMessage: "",
            onRetry: viewModel.retry
        ) {
            if viewModel.isSubmitted {
                submittedState
                    .transition(.opacity)
            } else if let draft = viewModel.draft {
                mergeForm(draft, viewModel: viewModel)
            }
        }
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button(submitButtonTitle(viewModel)) {
                    isPositionFocused = false
                    pendingSubmitConfirmation = true
                }
                .disabled(
                    viewModel.draft == nil
                        || viewModel.isSubmitting
                        || viewModel.isRegenerating
                        || viewModel.isSubmitted
                )
            }
        }
        .sheet(item: $presentedSheet) { sheet in
            mergeSheet(sheet, viewModel: viewModel)
        }
        .xmSystemAlert(
            isPresented: $pendingSubmitConfirmation,
            descriptor: XMSystemAlertDescriptor(
                title: "合并所选书摘？",
                message: "将创建一条合并书摘，并把 \(noteIDs.count) 条来源书摘标记为删除。",
                actions: [
                    XMSystemAlertAction(title: "取消", role: .cancel) { },
                    XMSystemAlertAction(title: "合并", role: .destructive) {
                        submit(viewModel)
                    }
                ]
            )
        )
        .animation(
            reduceMotion ? .smooth(duration: 0.12) : .smooth(duration: 0.24),
            value: viewModel.isSubmitted
        )
    }

    private var submittedState: some View {
        VStack(spacing: Spacing.base) {
            Image(systemName: "checkmark.circle")
                .font(AppTypography.largeTitle)
                .foregroundStyle(Color.feedbackSuccess)
            Text("书摘已合并")
                .font(AppTypography.headline)
                .foregroundStyle(Color.textPrimary)
            Text("正在打开合并后的书摘…")
                .font(AppTypography.subheadline)
                .foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func submitButtonTitle(_ viewModel: NoteMergeViewModel) -> String {
        if viewModel.isSubmitted { return "已合并" }
        return viewModel.isSubmitting ? "合并中…" : "合并"
    }

    private func mergeForm(
        _ draft: NoteMergeDraft,
        viewModel: NoteMergeViewModel
    ) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.double) {
                bookHeader(draft)

                NoteMergeOrderSection(
                    title: "正文顺序",
                    rule: draft.contentRule,
                    orderedIDs: draft.contentNoteIDs,
                    sourceNotes: draft.sourceNotes,
                    onRuleChanged: viewModel.setContentRule,
                    onMove: viewModel.moveContentNote
                )

                previewSection(
                    title: "合并正文",
                    html: draft.contentHTML,
                    emptyMessage: "合并后正文为空",
                    editTitle: "编辑正文"
                ) {
                    presentSheet(.composer(.content))
                }

                NoteMergeOrderSection(
                    title: "想法顺序",
                    rule: draft.ideaRule,
                    orderedIDs: draft.ideaNoteIDs,
                    sourceNotes: draft.sourceNotes,
                    onRuleChanged: viewModel.setIdeaRule,
                    onMove: viewModel.moveIdeaNote
                )

                previewSection(
                    title: "合并想法",
                    html: draft.ideaHTML,
                    emptyMessage: "合并后没有想法",
                    editTitle: "编辑想法"
                ) {
                    presentSheet(.composer(.idea))
                }

                metadataSection(draft, viewModel: viewModel)
                relationshipUnionSection(draft, viewModel: viewModel)
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.vertical, Spacing.base)
        }
        .scrollDismissesKeyboard(.interactively)
        .scrollContentBackground(.hidden)
        .overlay(alignment: .top) {
            if viewModel.isRegenerating {
                LoadingStateView("正在更新预览…", style: .inline)
                    .padding(.top, Spacing.cozy)
                    .transition(.opacity)
            }
        }
        .animation(
            reduceMotion ? .smooth(duration: 0.12) : .smooth(duration: 0.28),
            value: viewModel.isRegenerating
        )
    }

    private func bookHeader(_ draft: NoteMergeDraft) -> some View {
        CardContainer(showsBorder: true, borderColor: Color.surfaceBorderSubtle) {
            HStack(spacing: Spacing.base) {
                XMBookCover.fixedHeight(
                    60,
                    urlString: draft.book.coverURL,
                    placeholderIconSize: .small
                )
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    Text(draft.book.title)
                        .font(AppTypography.headline)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(2)
                    if !draft.book.author.isEmpty {
                        Text(draft.book.author)
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(1)
                    }
                    Text("合并 \(draft.sourceNotes.count) 条书摘")
                        .font(ReadingContentTypography.metadata)
                        .foregroundStyle(Color.textSecondary)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: Spacing.compact)
            }
            .padding(Spacing.contentEdge)
        }
    }

    private func previewSection(
        title: String,
        html: String,
        emptyMessage: String,
        editTitle: String,
        onEdit: @escaping () -> Void
    ) -> some View {
        let plainText = RichTextPlainTextExtractor.plainText(from: html)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: Spacing.base) {
            HStack(spacing: Spacing.base) {
                Text(title)
                    .font(AppTypography.headline)
                    .foregroundStyle(Color.textPrimary)
                Spacer(minLength: Spacing.compact)
                Button(editTitle, action: onEdit)
                    .font(AppTypography.subheadline)
            }

            Text(plainText.isEmpty ? emptyMessage : plainText)
                .font(ReadingContentTypography.body)
                .foregroundStyle(plainText.isEmpty ? Color.textHint : Color.textPrimary)
                .lineSpacing(ReadingContentTypography.bodyLineSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(Spacing.contentEdge)
                .background(
                    Color.surfaceCard,
                    in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                        .stroke(Color.surfaceBorderSubtle, lineWidth: StrokeWidth.hairline)
                }
        }
    }

    private func metadataSection(
        _ draft: NoteMergeDraft,
        viewModel: NoteMergeViewModel
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text("章节、位置与创建时间")
                .font(AppTypography.headline)
                .foregroundStyle(Color.textPrimary)

            Button {
                presentSheet(.chapters)
            } label: {
                HStack(spacing: Spacing.base) {
                    Label("章节", systemImage: "text.book.closed")
                        .foregroundStyle(Color.textPrimary)
                    Spacer(minLength: Spacing.compact)
                    Text(draft.chapterTitle.isEmpty ? "未分章节" : draft.chapterTitle)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                    Image(systemName: "chevron.right")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textHint)
                }
            }
            .buttonStyle(.plain)

            HStack(spacing: Spacing.base) {
                Label("位置", systemImage: "bookmark")
                    .foregroundStyle(Color.textPrimary)
                TextField("未记录位置", text: Binding(
                    get: { draft.position },
                    set: viewModel.setPosition
                ))
                .multilineTextAlignment(.trailing)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isPositionFocused)
                .submitLabel(.done)
                .onSubmit { isPositionFocused = false }
            }

            Menu {
                Button("使用当前时间") {
                    viewModel.setCreatedDate(Int64(Date().timeIntervalSince1970 * 1_000))
                }
                ForEach(draft.sourceNotes) { note in
                    Button(dateLabel(note.createdDate)) {
                        viewModel.setCreatedDate(note.createdDate)
                    }
                }
            } label: {
                HStack(spacing: Spacing.base) {
                    Label("创建时间", systemImage: "calendar")
                        .foregroundStyle(Color.textPrimary)
                    Spacer(minLength: Spacing.compact)
                    Text(dateLabel(draft.createdDate))
                        .foregroundStyle(Color.textSecondary)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textHint)
                }
            }
            .xmMenuNeutralTint()

            Toggle("在书摘中显示创建时间", isOn: Binding(
                get: { draft.includeTime },
                set: viewModel.setIncludeTime
            ))
            .font(AppTypography.subheadline)
        }
        .padding(Spacing.contentEdge)
        .background(
            Color.surfaceCard,
            in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
        )
    }

    private func relationshipUnionSection(
        _ draft: NoteMergeDraft,
        viewModel: NoteMergeViewModel
    ) -> some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text("关系并集")
                .font(AppTypography.headline)
                .foregroundStyle(Color.textPrimary)

            CardContainer(showsBorder: true, borderColor: Color.surfaceBorderSubtle) {
                VStack(alignment: .leading, spacing: Spacing.base) {
                    HStack(spacing: Spacing.base) {
                        Label("标签 \(draft.selectedTags.count) 个", systemImage: "tag")
                            .font(AppTypography.subheadlineMedium)
                            .foregroundStyle(Color.textPrimary)
                        Spacer(minLength: Spacing.compact)
                        Button("编辑") { presentSheet(.tags) }
                            .font(AppTypography.subheadline)
                    }
                    if draft.selectedTags.isEmpty {
                        Text("来源书摘没有标签")
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.textHint)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Spacing.cozy) {
                                ForEach(draft.selectedTags) { tag in
                                    XMTagLabel(tag.title)
                                }
                            }
                        }
                    }

                    Divider()

                    HStack(spacing: Spacing.base) {
                        Label("图片 \(draft.imageItems.count) 张", systemImage: "photo.on.rectangle")
                            .font(AppTypography.subheadlineMedium)
                            .foregroundStyle(Color.textPrimary)
                        Spacer(minLength: Spacing.compact)
                        Button("编辑") { presentSheet(.images) }
                            .font(AppTypography.subheadline)
                    }
                    if draft.imageItems.isEmpty {
                        Text("来源书摘没有图片")
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.textHint)
                    } else {
                        ScrollView(.horizontal, showsIndicators: false) {
                            HStack(spacing: Spacing.cozy) {
                                ForEach(draft.imageItems) { image in
                                    XMRemoteImage(urlString: image.remoteURL ?? "") {
                                        NoteMergeAppearance.imagePlaceholderBackground.overlay {
                                            Image(systemName: "photo")
                                                .foregroundStyle(Color.textHint)
                                        }
                                    }
                                    .frame(width: 72, height: 72)
                                    .compositingGroup()
                                    .clipShape(.rect(cornerRadius: CornerRadius.blockSmall))
                                }
                            }
                        }
                    }
                }
                .padding(Spacing.contentEdge)
            }
        }
    }

    private func dateLabel(_ timestamp: Int64) -> String {
        guard timestamp > 0 else { return "未记录时间" }
        return Date(timeIntervalSince1970: TimeInterval(timestamp) / 1_000)
            .formatted(date: .abbreviated, time: .shortened)
    }

    private func presentSheet(_ sheet: NoteMergeSheet) {
        isPositionFocused = false
        presentedSheet = sheet
    }

    private func submit(_ viewModel: NoteMergeViewModel) {
        Task {
            toastCenter.processing("正在合并书摘…")
            let toastID = toastCenter.current?.id
            do {
                let mergedID = try await viewModel.submit()
                toastCenter.dismiss(id: toastID)
                presentedSheet = nil
                onOpenMergedNote(
                    .noteExcerpts(
                        scope: .all,
                        query: "",
                        sort: .createdDescending,
                        randomSeed: 0
                    ),
                    .note(mergedID)
                )
            } catch {
                toastCenter.error(error.localizedDescription)
            }
        }
    }

    @ViewBuilder
    private func mergeSheet(
        _ sheet: NoteMergeSheet,
        viewModel: NoteMergeViewModel
    ) -> some View {
        switch sheet {
        case .composer(let composer):
            NoteMergeComposerSheet(
                composer: composer,
                initialHTML: composer == .content
                    ? (viewModel.draft?.contentHTML ?? "")
                    : (viewModel.draft?.ideaHTML ?? ""),
                ocrRepository: repositories.ocrRepository
            ) { html in
                switch composer {
                case .content: viewModel.setContentHTML(html)
                case .idea: viewModel.setIdeaHTML(html)
                }
            }
        case .chapters:
            NoteChapterSelectionSheet(
                title: "选择合并章节",
                allowsRootSelection: true,
                options: viewModel.chapterOptions,
                onSelect: viewModel.setChapter,
                onCreate: { parentID, title in
                    try await viewModel.createChapter(parentID: parentID, named: title)
                }
            )
        case .tags:
            NoteTagSelectionSheet(
                title: "合并书摘标签",
                options: viewModel.availableTags,
                initialIDs: Set(viewModel.draft?.selectedTags.map(\.id) ?? []),
                onCreate: viewModel.createTag,
                onTagCatalogMutation: viewModel.applyTagCatalogMutation,
                onSave: { tags in
                    viewModel.setSelectedTags(tags)
                    return true
                }
            )
        case .images:
            NoteMergeImageEditorSheet(
                viewModel: viewModel,
                ocrRepository: repositories.ocrRepository
            )
        }
    }

    private func failureMessage(_ phase: NoteMergePhase) -> String? {
        if case .failure(let message) = phase { return message }
        return nil
    }
}

/// 正文或想法的独立顺序区，通过明确的上移/下移操作提供稳定且可访问的排序语义。
private struct NoteMergeOrderSection: View {
    let title: String
    let rule: NoteMergeLineBreakRule
    let orderedIDs: [Int64]
    let sourceNotes: [NoteExcerptListItem]
    let onRuleChanged: (NoteMergeLineBreakRule) -> Void
    let onMove: (IndexSet, Int) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.base) {
            Text(title)
                .font(AppTypography.headline)
                .foregroundStyle(Color.textPrimary)

            Picker("段落间隔", selection: Binding(get: { rule }, set: onRuleChanged)) {
                ForEach(NoteMergeLineBreakRule.allCases, id: \.self) { option in
                    Text(option.displayTitle).tag(option)
                }
            }
            .pickerStyle(.segmented)

            VStack(spacing: Spacing.none) {
                ForEach(Array(orderedIDs.enumerated()), id: \.element) { index, noteID in
                    if let note = sourceNotes.first(where: { $0.id == noteID }) {
                        HStack(alignment: .center, spacing: Spacing.cozy) {
                            VStack(alignment: .leading, spacing: Spacing.compact) {
                                Text(note.chapterTitle.isEmpty ? "未分章节" : note.chapterTitle)
                                    .font(AppTypography.captionMedium)
                                    .foregroundStyle(Color.textSecondary)
                                Text(preview(note))
                                    .font(AppTypography.subheadline)
                                    .foregroundStyle(Color.textPrimary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: Spacing.compact)
                            VStack(spacing: Spacing.compact) {
                                reorderButton(
                                    systemImage: "chevron.up",
                                    label: "将第 \(index + 1) 条上移",
                                    isDisabled: index == 0
                                ) {
                                    onMove(IndexSet(integer: index), index - 1)
                                }
                                reorderButton(
                                    systemImage: "chevron.down",
                                    label: "将第 \(index + 1) 条下移",
                                    isDisabled: index == orderedIDs.count - 1
                                ) {
                                    onMove(IndexSet(integer: index), min(orderedIDs.count, index + 2))
                                }
                            }
                        }
                        .padding(.horizontal, Spacing.contentEdge)
                        .padding(.vertical, Spacing.base)
                        if index < orderedIDs.count - 1 { Divider() }
                    }
                }
            }
            .background(Color.surfaceCard)
            .clipShape(.rect(cornerRadius: CornerRadius.blockLarge))
            .overlay {
                RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                    .stroke(Color.surfaceBorderSubtle, lineWidth: StrokeWidth.hairline)
            }
        }
    }

    private func reorderButton(
        systemImage: String,
        label: String,
        isDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(AppTypography.captionMedium)
                .frame(
                    width: InteractionMetrics.minimumTouchTarget,
                    height: InteractionMetrics.minimumTouchTarget
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(label)
        .accessibilityHint("调整合并顺序")
    }

    private func preview(_ note: NoteExcerptListItem) -> String {
        let plain = title == "正文顺序" ? note.plainContent : note.plainIdea
        return plain.isEmpty ? "（空）" : plain
    }
}

private enum NoteMergeSheet: Identifiable {
    case composer(NoteMergeComposer)
    case chapters
    case tags
    case images

    var id: String {
        switch self {
        case .composer(let composer): "composer-\(composer.rawValue)"
        case .chapters: "chapters"
        case .tags: "tags"
        case .images: "images"
        }
    }
}

private extension NoteMergeLineBreakRule {
    var displayTitle: String {
        switch self {
        case .follow: "直接连接"
        case .oneLine: "换行"
        case .twoLines: "空一行"
        }
    }
}
