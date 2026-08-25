import Foundation
import Observation
import os
import SwiftUI
import UIKit

/**
 * [INPUT]: 依赖 NoteRepositoryProtocol 提供 bootstrap、草稿、暂存图与保存事务，依赖 NoteEditorSeed 注入一次性想法追加文本，依赖 NoteImageUploadQuotaRepositoryProtocol 与 RichTextBridge 管理图片额度及富文本互转
 * [OUTPUT]: 对外提供 NoteEditorViewModel、NoteEditorComposerTarget，驱动书摘编辑页、全屏正文编辑页、标签选择草稿回写与未保存 AI 想法草稿
 * [POS]: ViewModels/Note 的书摘编辑状态编排器，被 NoteEditorView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

/// 全屏富文本编辑目标，区分正文与想法两块输入区。
enum NoteEditorComposerTarget: String, Identifiable, Hashable {
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
#if DEBUG
    private static let bootstrapLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "xmnote",
        category: "NoteEditorExpand"
    )
#endif

    /// 书摘编辑富文本基线字体，统一 HTML 解析、编辑器输入与占位展示。
    nonisolated static let editorBaseUIFont: UIFont = .systemFont(ofSize: 16)

    var availableBooks: [BookPickerBook] = []
    var availableTags: [NoteEditorTagOption] = []
    var availableChapters: [NoteEditorChapterOption] = []

    var selectedBook: BookPickerBook? {
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
            guard !isAutoUpdatingCreatedDate else { return }
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
    var imageQuotaAlertMessage: String?
    var didSave = false
    var pendingRecoveredDraft: NoteEditorDraft?
    var lastAutoSaveTime: Int64 = 0
    var imageQuotaState: NoteImageUploadQuotaState?
    var ideaInputState: IdeaInputState = .collapsed

    private let mode: NoteEditorMode
    private let seed: NoteEditorSeed?
    private let repository: any NoteRepositoryProtocol
    private let quotaRepository: any NoteImageUploadQuotaRepositoryProtocol
    private var isPremium: Bool
    private var hasLoaded = false
    private var initialDraft: NoteEditorDraft?
    private var initialPerceivedDirtyTrackingSnapshot: NoteEditorPerceivedDirtyTrackingSnapshot?
    private var isHydratingState = false
    private var isAwaitingRecoveredDraftDecision = false
    private var isCreatedDateManuallyEdited = false
    private var isAutoUpdatingCreatedDate = false
    private var autoSaveTask: Task<Void, Never>?
    private var createdDateAutoUpdateTask: Task<Void, Never>?
    private var imageUploadTasks: [String: Task<Void, Never>] = [:]
    private var imageQuotaReservationID = UUID().uuidString
    private var isImageQuotaReservationBackedByDraft = false
    private var isStagingImages = false

    init(
        mode: NoteEditorMode,
        seed: NoteEditorSeed?,
        repository: any NoteRepositoryProtocol,
        quotaRepository: any NoteImageUploadQuotaRepositoryProtocol,
        isPremium: Bool
    ) {
        self.mode = mode
        self.seed = seed
        self.repository = repository
        self.quotaRepository = quotaRepository
        self.isPremium = isPremium
    }

    var hasUnsavedChanges: Bool {
        guard let initialPerceivedDirtyTrackingSnapshot else { return false }
        let currentSnapshot = makePerceivedDirtyTrackingSnapshot()
        // 对齐 Android 当前返回拦截语义：正文与想法都为空时，始终视为“未修改”。
        guard !currentSnapshot.hasBlankContentAndIdea else { return false }
        return currentSnapshot != initialPerceivedDirtyTrackingSnapshot
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
        NotePositionUnitFormatter.title(for: positionUnit)
    }

    var positionPlaceholder: String {
        switch positionUnit {
        case 0:
            return "输入 0 - 100"
        default:
            return "输入\(positionTitle)"
        }
    }

    var positionKeyboardType: UIKeyboardType {
        positionUnit == 0 ? .decimalPad : .numberPad
    }

    var selectedChapterDisplayTitle: String {
        selectedChapterTitle.isEmpty ? "不设置章节" : selectedChapterTitle
    }

    var availableImageSelectionCount: Int {
        let componentRemaining = max(0, 9 - imageItems.count)
        return min(componentRemaining, imageQuotaState?.remainingCount ?? componentRemaining)
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
#if DEBUG
        Self.bootstrapLogger.debug(
            "[note.editor.expand.bootstrap.start] mode=\(self.debugModeName, privacy: .public) seedBookID=\(self.seed?.bookId ?? 0) seedChapterID=\(self.seed?.chapterId ?? 0)"
        )
#endif
        defer { isLoading = false }

        do {
            let bootstrap = try await repository.fetchNoteEditorBootstrap(mode: mode, seed: seed)
            availableBooks = bootstrap.books
            availableTags = bootstrap.tags
            availableChapters = bootstrap.chapters
            applyDraft(bootstrap.baseDraft, resetInitialDraft: true)

            let ideaAppendText = launchIdeaAppendText
            if let ideaAppendText {
                applyIdeaAppendTextToCurrentDraft(ideaAppendText)
            }

            if let recoveredDraft = bootstrap.recoveredDraft,
               recoveredDraft != bootstrap.baseDraft {
                var preparedRecoveredDraft = mergeMissingSelections(in: recoveredDraft)
                if let ideaAppendText {
                    preparedRecoveredDraft = draft(
                        preparedRecoveredDraft,
                        appendingIdeaText: ideaAppendText
                    )
                    isAwaitingRecoveredDraftDecision = true
                }
                pendingRecoveredDraft = preparedRecoveredDraft
            } else if ideaAppendText != nil {
                scheduleAutoSave()
            }
            await refreshImageQuota()
            syncCreatedDateAutoUpdateState()
#if DEBUG
            Self.bootstrapLogger.debug(
                "[note.editor.expand.bootstrap.success] mode=\(self.debugModeName, privacy: .public) books=\(self.availableBooks.count) tags=\(self.availableTags.count) chapters=\(self.availableChapters.count) recoveredDraft=\(self.pendingRecoveredDraft != nil)"
            )
#endif
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
#if DEBUG
            Self.bootstrapLogger.error(
                "[note.editor.expand.bootstrap.failed] mode=\(self.debugModeName, privacy: .public) error=\(self.errorMessage ?? error.localizedDescription, privacy: .public)"
            )
#endif
        }
    }

    /// 恢复自动保存草稿，并保留恢复时间显示。
    func restoreRecoveredDraft() async {
        guard let pendingRecoveredDraft else { return }
        applyDraft(mergeMissingSelections(in: pendingRecoveredDraft), resetInitialDraft: false)
        isImageQuotaReservationBackedByDraft = true
        lastAutoSaveTime = pendingRecoveredDraft.lastAutoSaveTime
        self.pendingRecoveredDraft = nil
        isAwaitingRecoveredDraftDecision = false
        scheduleAutoSave()
        await refreshImageQuota()
        syncCreatedDateAutoUpdateState()
    }

    /// 丢弃自动保存草稿，并清理对应缓存。
    func discardRecoveredDraft() async {
        guard let pendingRecoveredDraft else { return }
        repository.deleteNoteEditorDraft(
            bookId: pendingRecoveredDraft.bookId,
            noteId: pendingRecoveredDraft.noteId
        )
        self.pendingRecoveredDraft = nil
        isAwaitingRecoveredDraftDecision = false
        if let recoveredReservationID = pendingRecoveredDraft.imageQuotaReservationID {
            await quotaRepository.releaseReservation(id: recoveredReservationID)
        }
        scheduleAutoSave()
        await refreshImageQuota()
    }

    /// 选中一本书，并同步当前页码单位与章节列表。
    func selectBook(_ book: BookPickerBook) {
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

    /// 用户手动选择创建时间后，停止自动走时并立即写入新值。
    func setCreatedDateManually(_ date: Date) {
        setCreatedDateManually(Int64(date.timeIntervalSince1970 * 1000))
    }

    /// 用户手动选择创建时间后，停止自动走时并立即写入新值。
    func setCreatedDateManually(_ milliseconds: Int64) {
        isCreatedDateManuallyEdited = true
        stopCreatedDateAutoUpdate()
        createdDate = milliseconds
    }

    /// 一次性替换编辑器所选标签，确保 Sheet 关闭前的逐项勾选不会提前污染自动保存草稿。
    func setSelectedTags(_ tags: [NoteEditorTagOption]) {
        selectedTags = tags
    }

    /// 将全局标签改名或删除同步到编辑器候选项与当前草稿，避免关闭选择 Sheet 后恢复旧目录快照。
    func applyTagCatalogMutation(_ mutation: TagCatalogMutation) {
        guard mutation.scope == .note else { return }
        let nextAvailableTags = mutation.applying(to: availableTags)
        let nextSelectedTags = mutation.applying(to: selectedTags)
        if nextAvailableTags != availableTags {
            availableTags = nextAvailableTags
        }
        if nextSelectedTags != selectedTags {
            selectedTags = nextSelectedTags
        }
    }

    /// 新建 note 标签并返回真实对象；任务取消不回写错误，选中关系只由父 Sheet 保存时一次性替换。
    func createTag(named name: String) async throws -> NoteEditorTagOption {
        errorMessage = nil
        do {
            let newTag = try await repository.createNoteTag(named: name)
            try Task.checkCancellation()
            if !availableTags.contains(where: { $0.id == newTag.id }) {
                availableTags.append(newTag)
            }
            return newTag
        } catch {
            if !Task.isCancelled {
                errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            throw error
        }
    }

    /// 批量接收相册图片，先按当前日额度和页面上限裁剪，再逐张经仓储暂存与上传。
    func stageImages(_ inputs: [(data: Data, fileExtension: String)]) async {
        guard !inputs.isEmpty, !isStagingImages else { return }
        isStagingImages = true
        defer { isStagingImages = false }
        errorMessage = nil
        let componentAcceptedCount = min(inputs.count, max(0, 9 - imageItems.count))
        guard componentAcceptedCount > 0 else {
            errorMessage = "最多只能添加 9 张图片"
            return
        }
        let reservation = await quotaRepository.reserveImages(
            id: imageQuotaReservationID,
            owner: imageQuotaOwner,
            currentDraftNewImageCount: imageItems.count { $0.origin == .newInDraft },
            requestedCount: componentAcceptedCount,
            isPremium: isPremium
        )
        imageQuotaState = reservation.state
        let acceptedCount = reservation.acceptedCount
        guard acceptedCount > 0 else {
            let message = reservation.state.isBlocked
                ? reservation.state.blockedMessage
                : "最多只能添加 9 张图片"
            if reservation.state.isBlocked {
                imageQuotaAlertMessage = message
            } else {
                errorMessage = message
            }
            return
        }
        if acceptedCount < inputs.count {
            if acceptedCount < componentAcceptedCount {
                imageQuotaAlertMessage = "已超出今日额度，保留前 \(acceptedCount) 张"
            } else {
                errorMessage = "最多只能添加 9 张图片，已保留前 \(acceptedCount) 张"
            }
        }

        for input in inputs.prefix(acceptedCount) {
            guard !Task.isCancelled else { break }
            await stageImageWithoutQuotaCheck(data: input.data, fileExtension: input.fileExtension)
        }
        persistAutoSaveDraftImmediatelyIfNeeded()
        isImageQuotaReservationBackedByDraft = imageItems.contains { $0.origin == .newInDraft }
        await refreshImageQuota()
    }

    /// 单图入口兼容拍照等调用，实际仍复用批量额度门闩。
    func stageImage(data: Data, fileExtension: String) async {
        await stageImages([(data: data, fileExtension: fileExtension)])
    }

    /// 图片入口被额度前置阻断时复用当前快照生成标准系统弹窗文案。
    func showImageQuotaBlockedMessage() {
        if let imageQuotaState, imageQuotaState.isBlocked {
            imageQuotaAlertMessage = imageQuotaState.blockedMessage
        } else {
            errorMessage = "最多只能添加 9 张图片"
        }
    }

    /// 会员状态变化时立即重算选择额度；MainActor 保证状态刷新不会与编辑器选择回写交错。
    func updatePremiumStatus(_ isPremium: Bool) async {
        self.isPremium = isPremium
        await refreshImageQuota()
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
        await refreshImageQuota()
    }

    /// 将已通过额度门闩的单张图片写入仓储并启动上传；取消后不再继续追加后续图片。
    private func stageImageWithoutQuotaCheck(data: Data, fileExtension: String) async {
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
        let insertion = NSAttributedString(
            string: trimmed,
            attributes: [.font: Self.editorBaseUIFont]
        )
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
            let snapshot = makeDraftSnapshot(includeAutoSaveTime: false)
            let newImageCount = snapshot.imageItems.count { $0.origin == .newInDraft }
            let noteId = try await repository.saveNoteEditor(snapshot)
            await quotaRepository.commitReservation(
                id: imageQuotaReservationID,
                savedImageCount: newImageCount,
                isPremium: isPremium
            )
            isImageQuotaReservationBackedByDraft = false
            isHydratingState = true
            imageItems = imageItems.map { $0.markingPersisted() }
            isHydratingState = false
            await refreshImageQuota()
            didSave = true
            initialDraft = makeDraftSnapshot(includeAutoSaveTime: false, overridingNoteID: noteId)
            initialPerceivedDirtyTrackingSnapshot = makePerceivedDirtyTrackingSnapshot()
            return noteId
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return nil
        }
    }

    /// 放弃当前编辑会话，并清理自动保存草稿与本地暂存图。
    func discardEditingSession() async {
        autoSaveTask?.cancel()
        autoSaveTask = nil
        stopCreatedDateAutoUpdate()

        imageUploadTasks.values.forEach { $0.cancel() }
        imageUploadTasks.removeAll()

        let currentDraft = makeDraftSnapshot(includeAutoSaveTime: false)
        for item in imageItems {
            await repository.removeStagedNoteEditorImage(item)
        }
        repository.deleteNoteEditorDraft(bookId: currentDraft.bookId, noteId: currentDraft.noteId)
        await quotaRepository.releaseReservation(id: imageQuotaReservationID)
        isImageQuotaReservationBackedByDraft = false
        if let recoveredReservationID = pendingRecoveredDraft?.imageQuotaReservationID,
           recoveredReservationID != imageQuotaReservationID {
            await quotaRepository.releaseReservation(id: recoveredReservationID)
        }

        pendingRecoveredDraft = nil
        isAwaitingRecoveredDraftDecision = false
    }

    /// 连续编辑模式下，保存成功后重置为新的创建草稿，仅保留当前选中书籍。
    func prepareForContinuousEditing(preferredBookID: Int64?) async {
        didSave = false
        errorMessage = nil
        pendingRecoveredDraft = nil
        isAwaitingRecoveredDraftDecision = false
        imageQuotaReservationID = UUID().uuidString
        isImageQuotaReservationBackedByDraft = false

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
            await refreshImageQuota()
            syncCreatedDateAutoUpdateState()
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}

private extension NoteEditorViewModel {
    /// 编辑模式才消费外部追加文本；归一化后为空的种子不会改变编辑器 dirty baseline。
    var launchIdeaAppendText: String? {
        guard case .edit = mode else { return nil }
        let normalized = seed?.ideaAppendText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return normalized.isEmpty ? nil : normalized
    }

    /// 通过额度仓储读取当前自然日状态；草稿预占只统计显式 newInDraft 图片。
    func refreshImageQuota() async {
        imageQuotaState = await quotaRepository.reconcileReservation(
            id: imageQuotaReservationID,
            owner: imageQuotaOwner,
            draftNewImageCount: imageItems.count { $0.origin == .newInDraft },
            isPersistedDraft: isImageQuotaReservationBackedByDraft,
            isPremium: isPremium
        )
    }

    /// 额度 owner 与书摘自动草稿 `(book_id, note_id)` 身份一致，切书后新草稿会接管当前 ticket。
    var imageQuotaOwner: NoteImageUploadReservationOwner {
        .note(bookID: selectedBook?.id ?? 0, noteID: mode.noteID)
    }

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

        if let reservationID = draft.imageQuotaReservationID,
           !reservationID.isEmpty {
            imageQuotaReservationID = reservationID
        }

        let resolvedBook = availableBooks.first(where: { $0.id == draft.bookId }) ?? fallbackBookOption(from: draft)
        selectedBook = resolvedBook
        selectedTags = draft.selectedTags
        contentText = RichTextBridge.htmlToAttributed(
            draft.contentHTML,
            baseFont: Self.editorBaseUIFont
        )
        ideaText = RichTextBridge.htmlToAttributed(
            draft.ideaHTML,
            baseFont: Self.editorBaseUIFont
        )
        positionText = draft.position
        positionUnit = draft.positionUnit
        includeTime = draft.includeTime
        createdDate = draft.createdDate
        if case .edit = self.mode {
            isCreatedDateManuallyEdited = true
        } else {
            isCreatedDateManuallyEdited = false
        }
        selectedChapterID = draft.chapterId
        selectedChapterTitle = draft.chapterTitle
        imageItems = draft.imageItems
        lastAutoSaveTime = draft.lastAutoSaveTime
        resumePendingImageUploadsIfNeeded()

        if resetInitialDraft {
            initialDraft = makeDraftSnapshot(includeAutoSaveTime: false)
            initialPerceivedDirtyTrackingSnapshot = makePerceivedDirtyTrackingSnapshot()
        }

        syncIdeaInputStateFromContent()
#if DEBUG
        let selectedBookID = selectedBook?.id ?? 0
        let contentLength = contentText.string.count
        let ideaLength = ideaText.string.count
        Self.bootstrapLogger.debug(
            "[note.editor.expand.apply-draft] resetInitialDraft=\(resetInitialDraft) selectedBookID=\(selectedBookID) contentLength=\(contentLength) ideaLength=\(ideaLength) imageCount=\(self.imageItems.count) hasRecoveredAutoSaveTime=\(self.lastAutoSaveTime > 0) ideaState=\(self.debugIdeaStateName(self.ideaInputState), privacy: .public)"
        )
#endif
    }

    /// 在数据库基础草稿建立初始基线后追加本轮 AI 文本，因此关闭编辑器时会被识别为未保存修改。
    func applyIdeaAppendTextToCurrentDraft(_ text: String) {
        isHydratingState = true
        ideaText = attributedIdeaText(byAppending: text, to: ideaText)
        isHydratingState = false
        syncIdeaInputStateFromContent()
    }

    /// 为恢复候选制作独立追加版本；基础版本与恢复版本都只消费一次同一启动种子。
    func draft(_ draft: NoteEditorDraft, appendingIdeaText text: String) -> NoteEditorDraft {
        var updatedDraft = draft
        let attributedIdea = RichTextBridge.htmlToAttributed(
            draft.ideaHTML,
            baseFont: Self.editorBaseUIFont
        )
        updatedDraft.ideaHTML = RichTextBridge.attributedToHtml(
            attributedIdeaText(byAppending: text, to: attributedIdea)
        )
        return updatedDraft
    }

    /// 保留既有富文本，并按 Android 业务语义以两个换行追加“🔮 AI结果”。
    func attributedIdeaText(
        byAppending text: String,
        to existingText: NSAttributedString
    ) -> NSAttributedString {
        let hasVisibleIdea = !normalizedVisibleText(from: existingText).isEmpty
        let mutable = hasVisibleIdea
            ? NSMutableAttributedString(attributedString: existingText)
            : NSMutableAttributedString()
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.editorBaseUIFont]
        if hasVisibleIdea {
            mutable.append(NSAttributedString(string: "\n\n", attributes: attributes))
        }
        mutable.append(
            NSAttributedString(
                string: "🔮 \(text)",
                attributes: attributes
            )
        )
        return mutable
    }

    func mergeMissingSelections(in draft: NoteEditorDraft) -> NoteEditorDraft {
        for tag in draft.selectedTags where !availableTags.contains(where: { $0.id == tag.id }) {
            availableTags.append(tag)
        }
        availableTags.sort { $0.title.localizedCompare($1.title) == .orderedAscending }
        return draft
    }

    func fallbackBookOption(from draft: NoteEditorDraft) -> BookPickerBook? {
        guard draft.bookId > 0 else { return nil }
        return BookPickerBook(
            id: draft.bookId,
            title: draft.bookTitle,
            author: draft.bookAuthor,
            press: "",
            coverURL: draft.bookCoverURL,
            positionUnit: draft.bookPositionUnit,
            totalPosition: draft.bookTotalPosition,
            totalPagination: draft.bookTotalPagination
        )
    }

    func scheduleAutoSave() {
        guard !isHydratingState, !isAwaitingRecoveredDraftDecision else { return }
        autoSaveTask?.cancel()
        autoSaveTask = Task { [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled else { return }
            self.persistAutoSaveDraftImmediatelyIfNeeded()
        }
    }

    /// 图片预占完成后立即持久化 ticket 与附件快照，缩短进程退出造成孤立预占的窗口。
    func persistAutoSaveDraftImmediatelyIfNeeded() {
        guard !isAwaitingRecoveredDraftDecision else { return }
        autoSaveTask?.cancel()
        autoSaveTask = nil
        let snapshot = makeDraftSnapshot(includeAutoSaveTime: true)
        guard snapshot != initialDraft else { return }
        repository.saveNoteEditorDraft(snapshot)
        lastAutoSaveTime = snapshot.lastAutoSaveTime
    }

    /// 仅新建书摘在未手动选择时间前保持“当前时间”自动走时。
    func syncCreatedDateAutoUpdateState() {
        guard mode == .create else {
            stopCreatedDateAutoUpdate()
            return
        }
        guard !isCreatedDateManuallyEdited else {
            stopCreatedDateAutoUpdate()
            return
        }
        startCreatedDateAutoUpdateIfNeeded()
    }

    /// 启动创建时间自动走时任务；重复调用会被幂等拦截。
    func startCreatedDateAutoUpdateIfNeeded() {
        guard createdDateAutoUpdateTask == nil else { return }
        createdDateAutoUpdateTask = Task { [weak self] in
            while let self {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { break }
                guard self.mode == .create, !self.isCreatedDateManuallyEdited else { break }
                self.isAutoUpdatingCreatedDate = true
                self.createdDate = Self.currentTimestampMillis
                self.isAutoUpdatingCreatedDate = false
            }
            self?.createdDateAutoUpdateTask = nil
        }
    }

    /// 停止创建时间自动走时任务。
    func stopCreatedDateAutoUpdate() {
        createdDateAutoUpdateTask?.cancel()
        createdDateAutoUpdateTask = nil
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
            lastAutoSaveTime: timestamp,
            imageQuotaReservationID: imageQuotaReservationID
        )
    }

    func makePerceivedDirtyTrackingSnapshot() -> NoteEditorPerceivedDirtyTrackingSnapshot {
        NoteEditorPerceivedDirtyTrackingSnapshot(
            contentText: normalizedVisibleText(from: contentText),
            ideaText: normalizedVisibleText(from: ideaText),
            position: positionText,
            chapterId: selectedChapterID,
            selectedTagIDs: selectedTags.map(\.id).sorted(),
            imageIdentities: imageItems.map(imageIdentity(for:))
        )
    }

    func normalizedVisibleText(from attributedText: NSAttributedString) -> String {
        let scalars = Array(
            attributedText.string.unicodeScalars.filter { $0.value != 0x200D }
        )
        var startIndex = 0
        var endIndex = scalars.count
        while startIndex < endIndex, scalars[startIndex].value <= 0x20 {
            startIndex += 1
        }
        while startIndex < endIndex, scalars[endIndex - 1].value <= 0x20 {
            endIndex -= 1
        }
        return String(String.UnicodeScalarView(scalars[startIndex..<endIndex]))
    }

    func imageIdentity(for item: NoteEditorImageItem) -> String {
        if let remoteURL = item.remoteURL, !remoteURL.isEmpty {
            return remoteURL
        }
        if let localFilePath = item.localFilePath, !localFilePath.isEmpty {
            return localFilePath
        }
        return item.id
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

#if DEBUG
    var debugModeName: String {
        switch mode {
        case .create:
            return "create"
        case .edit:
            return "edit"
        }
    }

    func debugIdeaStateName(_ state: IdeaInputState) -> String {
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

private struct NoteEditorPerceivedDirtyTrackingSnapshot: Equatable {
    let contentText: String
    let ideaText: String
    let position: String
    let chapterId: Int64
    let selectedTagIDs: [Int64]
    let imageIdentities: [String]

    var hasBlankContentAndIdea: Bool {
        contentText.isEmpty && ideaText.isEmpty
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
