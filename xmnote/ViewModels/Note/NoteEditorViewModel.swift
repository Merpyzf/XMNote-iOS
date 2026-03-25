import Foundation
import Observation
import os
import SwiftUI

/**
 * [INPUT]: 依赖 NoteRepositoryProtocol 提供 bootstrap、草稿、暂存图、OCR 与保存事务，依赖 RichTextBridge 处理 HTML 与富文本互转
 * [OUTPUT]: 对外提供 NoteEditorViewModel、NoteEditorComposerTarget，驱动书摘编辑页与全屏正文编辑页
 * [POS]: ViewModels/Note 的书摘编辑状态编排器，被 NoteEditorView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 全屏富文本编辑目标，区分正文与想法两块输入区。
enum NoteEditorComposerTarget: String, Identifiable {
    case content
    case idea

    var id: String { rawValue }

    var title: String {
        switch self {
        case .content:
            return "书摘内容"
        case .idea:
            return "想法"
        }
    }
}

/// 聚焦摘录模式下想法输入区的三态状态机，对齐 Android 端 IdeaInputState。
enum IdeaInputState: Equatable {
    /// 48pt 折叠行，显示"补充想法"或内容预览
    case collapsed
    /// 内联展开编辑器，获取焦点
    case expanded
    /// 有内容，保持展开显示
    case hasContent
}

/// 书摘编辑状态源，负责 bootstrap、自动保存、附图暂存、OCR 与最终保存。
@MainActor
@Observable
final class NoteEditorViewModel {
    var availableBooks: [NoteEditorBookOption] = []
    var availableTags: [NoteEditorTagOption] = []
    var availableChapters: [NoteEditorChapterOption] = []

    var selectedBook: NoteEditorBookOption? {
        didSet {
            guard !isHydratingState else { return }
            positionUnit = selectedBook?.positionUnit ?? 0
            if selectedBook?.id != oldValue?.id {
                selectedChapterID = 0
                selectedChapterTitle = ""
                availableChapters = []
                Task { await loadChaptersForCurrentBook() }
            }
            scheduleAutoSave()
        }
    }
    var selectedTags: [NoteEditorTagOption] = [] {
        didSet {
            guard !isHydratingState else { return }
            selectedTags.sort { $0.title.localizedCompare($1.title) == .orderedAscending }
            scheduleAutoSave()
        }
    }
    var contentText = NSAttributedString() {
        didSet {
            guard !isHydratingState else { return }
            scheduleAutoSave()
        }
    }
    var ideaText = NSAttributedString() {
        didSet {
            guard !isHydratingState else { return }
            scheduleAutoSave()
        }
    }
    var positionText = "" {
        didSet {
            guard !isHydratingState else { return }
            scheduleAutoSave()
        }
    }
    var positionUnit: Int64 = 0 {
        didSet {
            guard !isHydratingState else { return }
            scheduleAutoSave()
        }
    }
    var includeTime = true {
        didSet {
            guard !isHydratingState else { return }
            scheduleAutoSave()
        }
    }
    var createdDate = NoteEditorViewModel.currentTimestampMillis {
        didSet {
            guard !isHydratingState else { return }
            scheduleAutoSave()
        }
    }
    var selectedChapterID: Int64 = 0 {
        didSet {
            guard !isHydratingState else { return }
            if let chapter = availableChapters.first(where: { $0.id == selectedChapterID }) {
                selectedChapterTitle = chapter.title
            } else if selectedChapterID == 0 {
                selectedChapterTitle = ""
            }
            scheduleAutoSave()
        }
    }
    var selectedChapterTitle = ""
    var imageItems: [NoteEditorImageItem] = [] {
        didSet {
            guard !isHydratingState else { return }
            scheduleAutoSave()
        }
    }

    var isLoading = false
    var isSaving = false
    var errorMessage: String?
    var didSave = false
    var pendingRecoveredDraft: NoteEditorDraft?
    var lastAutoSaveTime: Int64 = 0
    var ideaInputState: IdeaInputState = .collapsed

    private let mode: NoteEditorMode
    private let seed: NoteEditorSeed?
    private let repository: any NoteRepositoryProtocol
    private var hasLoaded = false
    private var initialDraft: NoteEditorDraft?
    private var isHydratingState = false
    private var autoSaveTask: Task<Void, Never>?
    private var imageUploadTasks: [String: Task<Void, Never>] = [:]

    init(
        mode: NoteEditorMode,
        seed: NoteEditorSeed?,
        repository: any NoteRepositoryProtocol
    ) {
        self.mode = mode
        self.seed = seed
        self.repository = repository
    }

    var hasUnsavedChanges: Bool {
        guard let initialDraft else { return false }
        return makeDraftSnapshot(includeAutoSaveTime: false) != initialDraft
    }

    var navigationTitle: String {
        switch mode {
        case .create:
            return "书摘编辑"
        case .edit:
            return "编辑书摘"
        }
    }

    var autoSaveDescription: String? {
        guard lastAutoSaveTime > 0 else { return nil }
        return "已自动保存于 \(Self.timeFormatter.string(from: Date(timeIntervalSince1970: Double(lastAutoSaveTime) / 1000)))"
    }

    var createdDateDescription: String {
        Self.dateTimeFormatter.string(from: Date(timeIntervalSince1970: Double(createdDate) / 1000))
    }

    var bookSelectionDescription: String {
        guard let selectedBook else { return "请选择一本书" }
        if selectedBook.author.isEmpty {
            return selectedBook.title
        }
        return "\(selectedBook.title) · \(selectedBook.author)"
    }

    var positionTitle: String {
        switch positionUnit {
        case 1:
            return "位置"
        case 2:
            return "进度"
        default:
            return "页码"
        }
    }

    var positionPlaceholder: String {
        switch positionUnit {
        case 2:
            return "输入 0 - 100"
        default:
            return "输入\(positionTitle)"
        }
    }

    var positionKeyboardType: String {
        positionUnit == 2 ? "decimal" : "number"
    }

    var selectedChapterDisplayTitle: String {
        selectedChapterTitle.isEmpty ? "不设置章节" : selectedChapterTitle
    }

    var contentPreviewText: String {
        previewText(from: contentText, placeholder: "点击进入全屏编辑书摘内容")
    }

    var ideaPreviewText: String {
        previewText(from: ideaText, placeholder: "点击进入全屏编辑你的想法")
    }

    /// 首次进入编辑页时加载 bootstrap，并准备草稿恢复提示。
    func loadIfNeeded() async {
        guard !hasLoaded else { return }
        hasLoaded = true
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            let bootstrap = try await repository.fetchNoteEditorBootstrap(mode: mode, seed: seed)
            availableBooks = bootstrap.books
            availableTags = bootstrap.tags
            availableChapters = bootstrap.chapters
            applyDraft(bootstrap.baseDraft, resetInitialDraft: true)
            if let recoveredDraft = bootstrap.recoveredDraft,
               recoveredDraft != bootstrap.baseDraft {
                pendingRecoveredDraft = mergeMissingSelections(in: recoveredDraft)
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 恢复自动保存草稿，并保留恢复时间显示。
    func restoreRecoveredDraft() {
        guard let pendingRecoveredDraft else { return }
        applyDraft(mergeMissingSelections(in: pendingRecoveredDraft), resetInitialDraft: false)
        lastAutoSaveTime = pendingRecoveredDraft.lastAutoSaveTime
        self.pendingRecoveredDraft = nil
    }

    /// 丢弃自动保存草稿，并清理对应缓存。
    func discardRecoveredDraft() {
        guard let pendingRecoveredDraft else { return }
        repository.deleteNoteEditorDraft(
            bookId: pendingRecoveredDraft.bookId,
            noteId: pendingRecoveredDraft.noteId
        )
        self.pendingRecoveredDraft = nil
    }

    /// 选中一本书，并同步当前页码单位与章节列表。
    func selectBook(_ book: NoteEditorBookOption) {
        selectedBook = book
    }

    /// 选中或清空章节。
    func selectChapter(_ chapter: NoteEditorChapterOption?) {
        selectedChapterID = chapter?.id ?? 0
        selectedChapterTitle = chapter?.title ?? ""
    }

    /// 清空当前章节选择并回退为“未设置”状态。
    func clearSelectedChapter() {
        selectChapter(nil)
    }

    /// 切换标签勾选状态。
    func toggleTag(_ tag: NoteEditorTagOption) {
        if selectedTags.contains(where: { $0.id == tag.id }) {
            selectedTags.removeAll { $0.id == tag.id }
        } else {
            selectedTags.append(tag)
        }
    }

    /// 新建 note 标签并立即加入选中列表。
    func createTag(named name: String) async {
        errorMessage = nil
        do {
            let newTag = try await repository.createNoteTag(named: name)
            if !availableTags.contains(where: { $0.id == newTag.id }) {
                availableTags.append(newTag)
                availableTags.sort { $0.title.localizedCompare($1.title) == .orderedAscending }
            }
            if !selectedTags.contains(where: { $0.id == newTag.id }) {
                selectedTags.append(newTag)
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 将相册/拍照得到的图片暂存进编辑目录，并更新附图条。
    func stageImage(data: Data, fileExtension: String) async {
        errorMessage = nil
        do {
            let stagedItem = try await repository.stageNoteEditorImage(
                data: data,
                preferredFileExtension: fileExtension
            )
            let uploadingItem = stagedItem.updatingUploadState(.uploading)
            imageItems.append(uploadingItem)
            startImageUpload(for: uploadingItem)
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    /// 删除一张附图；本地暂存图会同步清理缓存文件。
    func removeImage(_ item: NoteEditorImageItem) async {
        #if DEBUG
        let countBefore = imageItems.count
        Self.attachmentLogger.debug(
            "[note.editor.attachment.remove.enter] id=\(item.id, privacy: .public) countBefore=\(countBefore)"
        )
        #endif
        imageUploadTasks[item.id]?.cancel()
        imageUploadTasks[item.id] = nil
        imageItems.removeAll { $0.id == item.id }
        #if DEBUG
        let countAfter = imageItems.count
        let removed = max(0, countBefore - countAfter)
        Self.attachmentLogger.debug(
            "[note.editor.attachment.remove.exit] id=\(item.id, privacy: .public) removed=\(removed) countAfter=\(countAfter)"
        )
        #endif
        await repository.removeStagedNoteEditorImage(item)
    }

    /// 重试失败附图上传。
    func retryImageUpload(_ item: NoteEditorImageItem) {
        guard item.canRetryUpload else { return }
        updateImage(item.id) { $0.updatingUploadState(.uploading) }
        if let latestItem = imageItems.first(where: { $0.id == item.id }) {
            startImageUpload(for: latestItem)
        }
    }

    /// 拖拽排序附图列表。
    func moveImage(sourceID: String, destinationID: String) {
        guard let sourceIndex = imageItems.firstIndex(where: { $0.id == sourceID }),
              let destinationIndex = imageItems.firstIndex(where: { $0.id == destinationID }),
              sourceIndex != destinationIndex else {
            return
        }
        var reordered = imageItems
        reordered.move(
            fromOffsets: IndexSet(integer: sourceIndex),
            toOffset: destinationIndex > sourceIndex ? destinationIndex + 1 : destinationIndex
        )
        imageItems = reordered
    }

    /// 为全屏编辑页提供正文或想法的富文本绑定。
    func binding(for target: NoteEditorComposerTarget) -> Binding<NSAttributedString> {
        Binding(
            get: {
                switch target {
                case .content:
                    return self.contentText
                case .idea:
                    return self.ideaText
                }
            },
            set: { newValue in
                switch target {
                case .content:
                    self.contentText = newValue
                case .idea:
                    self.ideaText = newValue
                }
            }
        )
    }

    /// 将 OCR 识别文本回插到当前编辑器光标处；若无聚焦编辑器，则追加到末尾。
    func fallbackAppendRecognizedText(_ text: String, to target: NoteEditorComposerTarget) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let insertion = NSAttributedString(string: trimmed)
        switch target {
        case .content:
            let mutable = NSMutableAttributedString(attributedString: contentText)
            if mutable.length > 0 {
                mutable.append(NSAttributedString(string: "\n"))
            }
            mutable.append(insertion)
            contentText = mutable
        case .idea:
            let mutable = NSMutableAttributedString(attributedString: ideaText)
            if mutable.length > 0 {
                mutable.append(NSAttributedString(string: "\n"))
            }
            mutable.append(insertion)
            ideaText = mutable
        }
    }

    /// 提交保存当前书摘。
    func save() async -> Int64? {
        if imageItems.contains(where: { $0.uploadState == .uploading }) {
            errorMessage = NoteEditorError.imageUploadInProgress.errorDescription
            return nil
        }
        if imageItems.contains(where: { $0.uploadState == .failed }) {
            errorMessage = NoteEditorError.imageUploadFailed.errorDescription
            return nil
        }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        autoSaveTask?.cancel()

        do {
            let noteId = try await repository.saveNoteEditor(makeDraftSnapshot(includeAutoSaveTime: false))
            didSave = true
            initialDraft = makeDraftSnapshot(includeAutoSaveTime: false, overridingNoteID: noteId)
            return noteId
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    /// 连续编辑模式下，保存成功后重置为新的创建草稿，仅保留当前选中书籍。
    func prepareForContinuousEditing(preferredBookID: Int64?) async {
        didSave = false
        errorMessage = nil
        pendingRecoveredDraft = nil

        let seed = NoteEditorSeed(
            bookId: preferredBookID,
            chapterId: nil,
            contentHTML: "",
            ideaHTML: ""
        )

        do {
            let bootstrap = try await repository.fetchNoteEditorBootstrap(mode: .create, seed: seed)
            availableBooks = bootstrap.books
            availableTags = bootstrap.tags
            availableChapters = bootstrap.chapters
            applyDraft(bootstrap.baseDraft, resetInitialDraft: true)
            lastAutoSaveTime = 0
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private extension NoteEditorViewModel {
    nonisolated static var currentTimestampMillis: Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    nonisolated static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    nonisolated static let dateTimeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd HH:mm"
        return formatter
    }()

    func applyDraft(_ draft: NoteEditorDraft, resetInitialDraft: Bool) {
        imageUploadTasks.values.forEach { $0.cancel() }
        imageUploadTasks.removeAll()
        isHydratingState = true
        defer { isHydratingState = false }

        let resolvedBook = availableBooks.first(where: { $0.id == draft.bookId }) ?? fallbackBookOption(from: draft)
        selectedBook = resolvedBook
        selectedTags = draft.selectedTags
        contentText = RichTextBridge.htmlToAttributed(draft.contentHTML)
        ideaText = RichTextBridge.htmlToAttributed(draft.ideaHTML)
        positionText = draft.position
        positionUnit = draft.positionUnit
        includeTime = draft.includeTime
        createdDate = draft.createdDate
        selectedChapterID = draft.chapterId
        selectedChapterTitle = draft.chapterTitle
        imageItems = draft.imageItems
        lastAutoSaveTime = draft.lastAutoSaveTime
        resumePendingImageUploadsIfNeeded()

        if resetInitialDraft {
            initialDraft = makeDraftSnapshot(includeAutoSaveTime: false)
        }

        syncIdeaInputStateFromContent()
    }

    func mergeMissingSelections(in draft: NoteEditorDraft) -> NoteEditorDraft {
        for tag in draft.selectedTags where !availableTags.contains(where: { $0.id == tag.id }) {
            availableTags.append(tag)
        }
        availableTags.sort { $0.title.localizedCompare($1.title) == .orderedAscending }
        return draft
    }

    func fallbackBookOption(from draft: NoteEditorDraft) -> NoteEditorBookOption? {
        guard draft.bookId > 0 else { return nil }
        return NoteEditorBookOption(
            id: draft.bookId,
            title: draft.bookTitle,
            author: draft.bookAuthor,
            coverURL: draft.bookCoverURL,
            positionUnit: draft.bookPositionUnit,
            totalPosition: draft.bookTotalPosition,
            totalPagination: draft.bookTotalPagination
        )
    }

    func scheduleAutoSave() {
        guard !isHydratingState else { return }
        autoSaveTask?.cancel()
        autoSaveTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            let snapshot = self.makeDraftSnapshot(includeAutoSaveTime: true)
            guard snapshot != self.initialDraft else { return }
            self.repository.saveNoteEditorDraft(snapshot)
            self.lastAutoSaveTime = snapshot.lastAutoSaveTime
        }
    }

    func makeDraftSnapshot(
        includeAutoSaveTime: Bool,
        overridingNoteID: Int64? = nil
    ) -> NoteEditorDraft {
        let timestamp = includeAutoSaveTime ? Self.currentTimestampMillis : 0
        return NoteEditorDraft(
            noteId: overridingNoteID ?? mode.noteID,
            bookId: selectedBook?.id ?? 0,
            bookTitle: selectedBook?.title ?? "",
            bookAuthor: selectedBook?.author ?? "",
            bookCoverURL: selectedBook?.coverURL ?? "",
            bookPositionUnit: selectedBook?.positionUnit ?? 0,
            bookTotalPosition: selectedBook?.totalPosition ?? 0,
            bookTotalPagination: selectedBook?.totalPagination ?? 0,
            contentHTML: RichTextBridge.attributedToHtml(contentText),
            ideaHTML: RichTextBridge.attributedToHtml(ideaText),
            position: positionText,
            positionUnit: positionUnit,
            includeTime: includeTime,
            createdDate: createdDate,
            chapterId: selectedChapterID,
            chapterTitle: selectedChapterTitle,
            selectedTags: selectedTags,
            imageItems: imageItems,
            lastAutoSaveTime: timestamp
        )
    }

    func loadChaptersForCurrentBook() async {
        guard let book = selectedBook, book.id > 0 else {
            availableChapters = []
            return
        }
        do {
            availableChapters = try await repository.fetchNoteEditorChapters(bookId: book.id)
            if let chapter = availableChapters.first(where: { $0.id == selectedChapterID }) {
                selectedChapterTitle = chapter.title
            } else if selectedChapterID != 0 {
                selectedChapterID = 0
                selectedChapterTitle = ""
            }
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    func previewText(from attributedString: NSAttributedString, placeholder: String) -> String {
        let text = attributedString.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return placeholder }
        return text
    }

    func startImageUpload(for item: NoteEditorImageItem) {
        updateImage(item.id) { $0.updatingUploadState(.uploading) }
        imageUploadTasks[item.id]?.cancel()
        imageUploadTasks[item.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let uploadedItem = try await self.repository.uploadStagedNoteEditorImage(item)
                guard !Task.isCancelled else { return }
                self.updateImage(item.id) { _ in uploadedItem.updatingUploadState(.success) }
            } catch {
                guard !Task.isCancelled else { return }
                self.updateImage(item.id) { $0.updatingUploadState(.failed) }
            }
            self.imageUploadTasks[item.id] = nil
        }
    }

    func updateImage(_ imageID: String, mutate: (NoteEditorImageItem) -> NoteEditorImageItem) {
        guard let index = imageItems.firstIndex(where: { $0.id == imageID }) else { return }
        imageItems[index] = mutate(imageItems[index])
    }

    func resumePendingImageUploadsIfNeeded() {
        for item in imageItems where item.uploadState != .success && item.localFilePath?.isEmpty == false {
            startImageUpload(for: item.updatingUploadState(.uploading))
        }
    }
}

// MARK: - IdeaInputState

extension NoteEditorViewModel {
#if DEBUG
    private static let ideaStateLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "xmnote",
        category: "NoteEditorExpand"
    )
    private static let attachmentLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "xmnote",
        category: "NoteEditorAttachment"
    )
#endif

    var hasIdeaText: Bool {
        !ideaText.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// 聚焦模式下展开想法编辑器。
    func expandIdea() {
        let previousState = ideaInputState
        let nextState: IdeaInputState = hasIdeaText ? .hasContent : .expanded
        ideaInputState = nextState
#if DEBUG
        logIdeaState(
            "state.expandIdea",
            previousState: previousState,
            nextState: nextState,
            extra: "source=focus_row_tap"
        )
#endif
    }

    /// 聚焦模式下失焦后尝试收起想法：无内容则回到 collapsed。
    func collapseIdeaIfEmpty() {
        guard !hasIdeaText else {
            let previousState = ideaInputState
            ideaInputState = .hasContent
#if DEBUG
            logIdeaState(
                "state.collapseIfEmpty",
                previousState: previousState,
                nextState: .hasContent,
                extra: "reason=has_content_keep_expanded"
            )
#endif
            return
        }
        let previousState = ideaInputState
        ideaInputState = .collapsed
#if DEBUG
        logIdeaState(
            "state.collapseIfEmpty",
            previousState: previousState,
            nextState: .collapsed,
            extra: "reason=empty_and_focus_lost"
        )
#endif
    }

    /// 根据想法文本内容同步状态（编辑加载后、布局模式切换时调用）。
    func syncIdeaInputStateFromContent() {
        let previousState = ideaInputState
        let nextState: IdeaInputState = hasIdeaText ? .hasContent : .collapsed
        ideaInputState = nextState
#if DEBUG
        logIdeaState(
            "state.syncFromContent",
            previousState: previousState,
            nextState: nextState
        )
#endif
    }

    /// 聚焦摘录布局切换时按 Android 口径同步：有内容 > 有焦点 > 收起。
    func syncIdeaInputStateForFocusLayout(isIdeaFocused: Bool) {
        let previousState = ideaInputState
        let nextState: IdeaInputState
        if hasIdeaText {
            nextState = .hasContent
        } else if isIdeaFocused {
            nextState = .expanded
        } else {
            nextState = .collapsed
        }
        ideaInputState = nextState
#if DEBUG
        logIdeaState(
            "state.syncFocusLayout",
            previousState: previousState,
            nextState: nextState,
            extra: "isIdeaFocused=\(isIdeaFocused)"
        )
#endif
    }

#if DEBUG
    private func logIdeaState(
        _ event: String,
        previousState: IdeaInputState,
        nextState: IdeaInputState,
        extra: String = ""
    ) {
        let previous = ideaStateText(previousState)
        let next = ideaStateText(nextState)
        Self.ideaStateLogger.debug(
            "[note.editor.expand.\(event, privacy: .public)] previous=\(previous, privacy: .public) next=\(next, privacy: .public) hasIdeaText=\(self.hasIdeaText) \(extra, privacy: .public)"
        )
    }

    private func ideaStateText(_ state: IdeaInputState) -> String {
        switch state {
        case .collapsed:
            return "collapsed"
        case .expanded:
            return "expanded"
        case .hasContent:
            return "hasContent"
        }
    }
#endif
}
