/**
 * [INPUT]: 依赖 NoteRepositoryProtocol 的合并预览、附图暂存上传与事务提交接口，依赖 NoteImageUploadQuotaRepositoryProtocol 约束新增图片，依赖 NoteMergeDraft 描述可编辑结果
 * [OUTPUT]: 对外提供 NoteMergePhase 与 NoteMergeViewModel，编排正文/想法顺序、分隔规则、元信息选择、附图增删排序上传和最终合并
 * [POS]: ViewModels/Note 的书摘合并状态源，保证页面编辑不会绕过 Repository 的二次一致性校验
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

/// 合并页加载阶段；提交状态独立维护，避免把已有草稿替换成加载占位。
enum NoteMergePhase: Equatable {
    case loading
    case content
    case failure(String)
    case submitted(Int64)
}

@MainActor
@Observable
/// 书摘合并状态机，预览拼接和最终事务均由 Repository 提供，页面只维护显式用户选择。
final class NoteMergeViewModel {
    let bookID: Int64
    let noteIDs: [Int64]
    private(set) var phase: NoteMergePhase = .loading
    private(set) var draft: NoteMergeDraft?
    private(set) var availableTags: [NoteEditorTagOption] = []
    private(set) var chapterOptions: [NoteEditorChapterOption] = []
    private(set) var isRegenerating = false
    private(set) var isSubmitting = false
    private(set) var isStagingImages = false
    private(set) var imageQuotaState: NoteImageUploadQuotaState?
    private(set) var imageErrorMessage: String?

    private let repository: any NoteRepositoryProtocol
    private let quotaRepository: any NoteImageUploadQuotaRepositoryProtocol
    private var isPremium: Bool
    private let imageQuotaReservationID = "note-merge-\(UUID().uuidString)"
    private var loadTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var imageUploadTasks: [String: Task<Void, Never>] = [:]
    private var didDiscardImageSession = false

    var isSubmitted: Bool {
        if case .submitted = phase { return true }
        return false
    }

    /// 注入来源书摘和目标书籍；首个预览会校验至少两条且均属于同一本书。
    init(
        bookID: Int64,
        noteIDs: [Int64],
        repository: any NoteRepositoryProtocol,
        quotaRepository: any NoteImageUploadQuotaRepositoryProtocol,
        isPremium: Bool
    ) {
        self.bookID = bookID
        self.noteIDs = Array(Set(noteIDs)).sorted()
        self.repository = repository
        self.quotaRepository = quotaRepository
        self.isPremium = isPremium
        load()
    }

    var sourceNotes: [NoteExcerptListItem] { draft?.sourceNotes ?? [] }

    /// 重新拉取初始预览；取消旧任务可避免重试结果覆盖后续编辑。
    func retry() {
        guard !isSubmitted else { return }
        loadTask?.cancel()
        load()
    }

    /// 移动正文来源顺序并重新生成拼接预览；已选元信息、标签和图片并集保持不变。
    func moveContentNote(fromOffsets: IndexSet, toOffset: Int) {
        guard !isSubmitted, var draft else { return }
        draft.contentNoteIDs = moved(
            draft.contentNoteIDs,
            fromOffsets: fromOffsets,
            toOffset: toOffset
        )
        self.draft = draft
        regeneratePreview()
    }

    /// 移动想法来源顺序并重新生成拼接预览。
    func moveIdeaNote(fromOffsets: IndexSet, toOffset: Int) {
        guard !isSubmitted, var draft else { return }
        draft.ideaNoteIDs = moved(
            draft.ideaNoteIDs,
            fromOffsets: fromOffsets,
            toOffset: toOffset
        )
        self.draft = draft
        regeneratePreview()
    }

    func setContentRule(_ rule: NoteMergeLineBreakRule) {
        guard !isSubmitted, var draft, draft.contentRule != rule else { return }
        draft.contentRule = rule
        self.draft = draft
        regeneratePreview()
    }

    func setIdeaRule(_ rule: NoteMergeLineBreakRule) {
        guard !isSubmitted, var draft, draft.ideaRule != rule else { return }
        draft.ideaRule = rule
        self.draft = draft
        regeneratePreview()
    }

    /// 合并正文允许最终人工编辑；Repository 提交时不会重新拼接覆盖该值。
    func setContentHTML(_ value: String) {
        guard !isSubmitted, var draft else { return }
        draft.contentHTML = value
        self.draft = draft
    }

    /// 合并想法允许最终人工编辑；空想法是合法结果。
    func setIdeaHTML(_ value: String) {
        guard !isSubmitted, var draft else { return }
        draft.ideaHTML = value
        self.draft = draft
    }

    /// 选择来源书摘的章节；位置和创建时间保持当前独立选择。
    func selectChapterSource(noteID: Int64) {
        guard !isSubmitted,
              var draft,
              let source = draft.sourceNotes.first(where: { $0.id == noteID }) else { return }
        draft.chapterID = source.chapterID
        draft.chapterTitle = source.chapterTitle
        self.draft = draft
    }

    /// 选择来源书摘的位置和位置单位，章节与创建时间不随之变化。
    func selectPositionSource(noteID: Int64) {
        guard !isSubmitted,
              var draft,
              let source = draft.sourceNotes.first(where: { $0.id == noteID }) else { return }
        draft.position = source.position
        draft.positionUnit = source.positionUnit
        self.draft = draft
    }

    /// 选择来源书摘的创建时间；是否展示时间由独立开关维护。
    func selectCreatedDateSource(noteID: Int64) {
        guard !isSubmitted,
              var draft,
              let source = draft.sourceNotes.first(where: { $0.id == noteID }) else { return }
        draft.createdDate = source.createdDate
        self.draft = draft
    }

    func setIncludeTime(_ isIncluded: Bool) {
        guard !isSubmitted, var draft else { return }
        draft.includeTime = isIncluded
        self.draft = draft
    }

    func setPosition(_ position: String) {
        guard !isSubmitted, var draft else { return }
        draft.position = position
        self.draft = draft
    }

    func setCreatedDate(_ timestamp: Int64) {
        guard !isSubmitted, var draft else { return }
        draft.createdDate = timestamp
        self.draft = draft
    }

    /// 选择目标书籍中任意有效章节；根章节使用 ID 0，标题降级为空。
    func setChapter(id chapterID: Int64) {
        guard !isSubmitted, var draft else { return }
        if chapterID == 0 {
            draft.chapterID = 0
            draft.chapterTitle = ""
        } else if let option = chapterOptions.first(where: { $0.id == chapterID }) {
            draft.chapterID = option.id
            draft.chapterTitle = option.title
        }
        self.draft = draft
    }

    /// 页面标签选择只修改最终关系集合；提交时 Repository 会重新校验标签是否仍有效。
    func setSelectedTags(_ tags: [NoteEditorTagOption]) {
        guard !isSubmitted, var draft else { return }
        draft.selectedTags = tags.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        self.draft = draft
    }

    /// 将全局标签改名或删除同步到合并候选项与最终标签草稿，不触发预览内容重新生成。
    func applyTagCatalogMutation(_ mutation: TagCatalogMutation) {
        guard mutation.scope == .note else { return }
        let nextAvailableTags = mutation.applying(to: availableTags)
        if nextAvailableTags != availableTags {
            availableTags = nextAvailableTags
        }
        guard var draft else { return }
        let nextSelectedTags = mutation.applying(to: draft.selectedTags)
        guard nextSelectedTags != draft.selectedTags else { return }
        draft.selectedTags = nextSelectedTags
        self.draft = draft
    }

    var availableImageSelectionCount: Int {
        guard let draft else { return 0 }
        let componentRemaining = max(0, 9 - draft.imageItems.count)
        guard let imageQuotaState, imageQuotaState.isLimited else { return componentRemaining }
        return min(componentRemaining, max(0, imageQuotaState.remainingCount))
    }

    /// 相册或相机图片先原子预占额度，再逐张暂存并上传；未成功暂存的数量会立即归还。
    func stageImages(_ inputs: [(data: Data, fileExtension: String)]) async {
        guard !inputs.isEmpty, !isStagingImages, !isSubmitted, let draft else { return }
        isStagingImages = true
        defer { isStagingImages = false }
        imageErrorMessage = nil

        let componentAcceptedCount = min(inputs.count, max(0, 9 - draft.imageItems.count))
        guard componentAcceptedCount > 0 else {
            imageErrorMessage = "最多只能添加 9 张图片"
            return
        }
        let reservation = await quotaRepository.reserveImages(
            id: imageQuotaReservationID,
            owner: imageQuotaOwner,
            currentDraftNewImageCount: draft.imageItems.count { $0.origin == .newInDraft },
            requestedCount: componentAcceptedCount,
            isPremium: isPremium
        )
        imageQuotaState = reservation.state
        guard reservation.acceptedCount > 0 else {
            imageErrorMessage = reservation.state.isBlocked
                ? reservation.state.blockedMessage
                : "最多只能添加 9 张图片"
            return
        }
        if reservation.acceptedCount < inputs.count {
            imageErrorMessage = reservation.acceptedCount < componentAcceptedCount
                ? "已超出今日额度，保留前 \(reservation.acceptedCount) 张"
                : "最多只能添加 9 张图片，已保留前 \(reservation.acceptedCount) 张"
        }

        for input in inputs.prefix(reservation.acceptedCount) {
            guard !Task.isCancelled else { break }
            do {
                let item = try await repository.stageNoteEditorImage(
                    data: input.data,
                    preferredFileExtension: input.fileExtension
                )
                guard var latestDraft = self.draft else { break }
                latestDraft.imageItems.append(item.updatingUploadState(.uploading))
                self.draft = latestDraft
                startImageUpload(itemID: item.id)
            } catch {
                imageErrorMessage = error.localizedDescription
            }
        }
        await refreshImageQuota()
    }

    /// 删除合并结果中的图片；仅本会话新图需要同步清理暂存文件。
    func removeImage(id: String) async {
        guard !isSubmitted, var draft,
              let item = draft.imageItems.first(where: { $0.id == id }) else { return }
        imageUploadTasks[id]?.cancel()
        imageUploadTasks[id] = nil
        draft.imageItems.removeAll { $0.id == id }
        self.draft = draft
        if item.origin == .newInDraft {
            await repository.removeStagedNoteEditorImage(item)
        }
        await refreshImageQuota()
    }

    /// 重试失败的新图上传；既有远端图不会进入失败态。
    func retryImage(id: String) {
        guard !isSubmitted, var draft,
              let index = draft.imageItems.firstIndex(where: { $0.id == id }),
              draft.imageItems[index].canRetryUpload else { return }
        draft.imageItems[index] = draft.imageItems[index].updatingUploadState(.uploading)
        self.draft = draft
        startImageUpload(itemID: id)
    }

    /// 长按附件条排序后只改最终图片数组，Repository 按该顺序落连续 order。
    func moveImage(sourceID: String, destinationID: String) {
        guard !isSubmitted, var draft,
              let sourceIndex = draft.imageItems.firstIndex(where: { $0.id == sourceID }),
              let destinationIndex = draft.imageItems.firstIndex(where: { $0.id == destinationID }),
              sourceIndex != destinationIndex else { return }
        let movingItem = draft.imageItems.remove(at: sourceIndex)
        draft.imageItems.insert(
            movingItem,
            at: min(destinationIndex, draft.imageItems.endIndex)
        )
        self.draft = draft
    }

    /// 图片 OCR 文本追加到合并正文末尾，保留已有富文本并使用统一 HTML 桥接。
    func appendRecognizedTextToContent(_ text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty, var draft else { return }
        let mutable = NSMutableAttributedString(
            attributedString: RichTextBridge.htmlToAttributed(draft.contentHTML)
        )
        if mutable.length > 0 { mutable.append(NSAttributedString(string: "\n")) }
        mutable.append(NSAttributedString(string: normalized))
        draft.contentHTML = RichTextBridge.attributedToHtml(mutable)
        self.draft = draft
    }

    func clearImageError() {
        imageErrorMessage = nil
    }

    /// 会员状态变化时刷新本会话剩余额度，不中断已经上传的新图。
    func updatePremiumStatus(_ isPremium: Bool) async {
        self.isPremium = isPremium
        await refreshImageQuota()
    }

    /// 合并页现场创建标签后扩充可选项并返回真实记录，最终是否关联仍由标签 Sheet 确认。
    func createTag(named title: String) async throws -> NoteEditorTagOption {
        guard !isSubmitted else { throw NoteBatchMutationError.invalidMergeDraft }
        let option = try await repository.createNoteTag(named: title)
        try Task.checkCancellation()
        if !availableTags.contains(where: { $0.id == option.id }) {
            availableTags.append(option)
            availableTags.sort { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
        return option
    }

    /// 合并页可在根或任意现有章节下现场创建子章节，并立即纳入当前选择列表。
    func createChapter(parentID: Int64, named title: String) async throws -> NoteEditorChapterOption {
        guard !isSubmitted else { throw NoteBatchMutationError.invalidMergeDraft }
        let option = try await repository.createChapter(
            bookID: bookID,
            parentID: parentID,
            title: title
        )
        try Task.checkCancellation()
        if !chapterOptions.contains(where: { $0.id == option.id }) {
            chapterOptions.append(option)
        }
        return option
    }

    /// 真实提交合并事务并返回新书摘主键；成功立即进入不可逆 terminal 状态，避免二次提交。
    /// - Note: Repository 返回即代表来源软删除与合并插入事务已提交；此后不再执行取消检查，确保调用方能收到新主键并替换失效路由。
    func submit() async throws -> Int64 {
        guard case .content = phase,
              let draft else { throw NoteBatchMutationError.invalidMergeDraft }
        guard !isSubmitting else { throw NoteBatchMutationError.invalidMergeDraft }
        guard !draft.imageItems.contains(where: { $0.uploadState == .uploading }) else {
            throw NoteMergeImageError.uploadInProgress
        }
        guard !draft.imageItems.contains(where: { $0.uploadState == .failed }) else {
            throw NoteMergeImageError.uploadFailed
        }
        isSubmitting = true
        do {
            let newImages = draft.imageItems.filter { $0.origin == .newInDraft }
            let mergedID = try await repository.mergeNotes(draft)
            for image in newImages {
                await repository.removeStagedNoteEditorImage(image)
            }
            await quotaRepository.commitReservation(
                id: imageQuotaReservationID,
                savedImageCount: newImages.count,
                isPremium: isPremium
            )
            loadTask?.cancel()
            previewTask?.cancel()
            imageUploadTasks.values.forEach { $0.cancel() }
            imageUploadTasks.removeAll()
            phase = .submitted(mergedID)
            isRegenerating = false
            isSubmitting = false
            return mergedID
        } catch {
            isSubmitting = false
            throw error
        }
    }

    isolated deinit {
        loadTask?.cancel()
        previewTask?.cancel()
        imageUploadTasks.values.forEach { $0.cancel() }
    }

    /// 首次预览由 Repository 聚合图片/标签并选择默认元信息，取消后不回写页面。
    private func load() {
        guard !isSubmitted else { return }
        phase = .loading
        loadTask = Task { [weak self] in
            guard let self else { return }
            do {
                let result = try await repository.fetchNoteMergeDraft(
                    request: NoteMergePreviewRequest(sourceNoteIDs: noteIDs)
                )
                guard !Task.isCancelled else { return }
                guard result.book.id == bookID else { throw NoteBatchMutationError.notesFromDifferentBooks }
                async let bootstrap = repository.fetchNoteBatchEditBootstrap(noteIDs: noteIDs)
                async let chapters = repository.fetchNoteEditorChapters(bookId: bookID)
                let (batchBootstrap, chapterOptions) = try await (bootstrap, chapters)
                try Task.checkCancellation()
                self.draft = result
                self.availableTags = batchBootstrap.tags
                self.chapterOptions = chapterOptions
                self.phase = .content
                await self.refreshImageQuota()
            } catch {
                guard !Task.isCancelled else { return }
                self.phase = .failure(error.localizedDescription)
            }
        }
    }

    /// 顺序或规则变化时重新生成正文/想法，并把页面已选元信息、标签和图片并集合并回新预览。
    private func regeneratePreview() {
        previewTask?.cancel()
        guard !isSubmitted, let currentDraft = draft else { return }
        isRegenerating = true
        let request = NoteMergePreviewRequest(
            sourceNoteIDs: currentDraft.sourceNoteIDs,
            contentNoteIDs: currentDraft.contentNoteIDs,
            ideaNoteIDs: currentDraft.ideaNoteIDs,
            contentRule: currentDraft.contentRule,
            ideaRule: currentDraft.ideaRule
        )
        previewTask = Task { [weak self] in
            guard let self else { return }
            do {
                var regenerated = try await repository.fetchNoteMergeDraft(request: request)
                guard !Task.isCancelled else { return }
                regenerated.chapterID = currentDraft.chapterID
                regenerated.chapterTitle = currentDraft.chapterTitle
                regenerated.position = currentDraft.position
                regenerated.positionUnit = currentDraft.positionUnit
                regenerated.includeTime = currentDraft.includeTime
                regenerated.createdDate = currentDraft.createdDate
                regenerated.selectedTags = currentDraft.selectedTags
                regenerated.imageItems = currentDraft.imageItems
                self.draft = regenerated
                self.isRegenerating = false
            } catch {
                guard !Task.isCancelled else { return }
                self.isRegenerating = false
            }
        }
    }

    /// 页面未提交就离场时释放额度并清理新图；既有远端图属于来源书摘，不做对象删除。
    func discardImageSessionIfNeeded() async {
        guard !didDiscardImageSession, !isSubmitted else { return }
        didDiscardImageSession = true
        imageUploadTasks.values.forEach { $0.cancel() }
        imageUploadTasks.removeAll()
        let newImages = draft?.imageItems.filter { $0.origin == .newInDraft } ?? []
        for image in newImages {
            await repository.removeStagedNoteEditorImage(image)
        }
        await quotaRepository.releaseReservation(id: imageQuotaReservationID)
    }

    /// 独立上传任务只按稳定 itemID 回写；删除、重试或页面销毁后晚到结果会被丢弃。
    private func startImageUpload(itemID: String) {
        imageUploadTasks[itemID]?.cancel()
        guard let item = draft?.imageItems.first(where: { $0.id == itemID }) else { return }
        imageUploadTasks[itemID] = Task { [weak self] in
            guard let self else { return }
            do {
                let uploaded = try await repository.uploadStagedNoteEditorImage(item)
                guard !Task.isCancelled, var draft,
                      let index = draft.imageItems.firstIndex(where: { $0.id == itemID }) else { return }
                draft.imageItems[index] = uploaded
                self.draft = draft
            } catch {
                guard !Task.isCancelled, var draft,
                      let index = draft.imageItems.firstIndex(where: { $0.id == itemID }) else { return }
                draft.imageItems[index] = draft.imageItems[index].updatingUploadState(.failed)
                self.draft = draft
                imageErrorMessage = error.localizedDescription
            }
            imageUploadTasks[itemID] = nil
        }
    }

    private func refreshImageQuota() async {
        let newImageCount = draft?.imageItems.count { $0.origin == .newInDraft } ?? 0
        imageQuotaState = await quotaRepository.reconcileReservation(
            id: imageQuotaReservationID,
            owner: imageQuotaOwner,
            draftNewImageCount: newImageCount,
            isPersistedDraft: false,
            isPremium: isPremium
        )
    }

    private var imageQuotaOwner: NoteImageUploadReservationOwner {
        .merge(bookID: bookID, noteIDs: noteIDs)
    }

    /// Foundation 层实现稳定数组移动，避免 ViewModel 依赖 SwiftUI 的 CollectionDifference 辅助扩展。
    private func moved(
        _ values: [Int64],
        fromOffsets: IndexSet,
        toOffset: Int
    ) -> [Int64] {
        let movingValues = fromOffsets.compactMap { index in
            values.indices.contains(index) ? values[index] : nil
        }
        guard !movingValues.isEmpty else { return values }

        var result = values
        for index in fromOffsets.sorted(by: >) where result.indices.contains(index) {
            result.remove(at: index)
        }
        let removedBeforeDestination = fromOffsets.filter { $0 < toOffset }.count
        let destination = min(max(0, toOffset - removedBeforeDestination), result.count)
        result.insert(contentsOf: movingValues, at: destination)
        return result
    }
}

/// 合并提交前的图片可行动错误。
private nonisolated enum NoteMergeImageError: LocalizedError {
    case uploadInProgress
    case uploadFailed

    var errorDescription: String? {
        switch self {
        case .uploadInProgress: "请等待所有图片上传完成"
        case .uploadFailed: "仍有图片上传失败，请重试或删除后再合并"
        }
    }
}
