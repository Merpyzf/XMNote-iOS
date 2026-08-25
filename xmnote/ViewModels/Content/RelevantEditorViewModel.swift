/**
 * [INPUT]: 依赖 RelevantEditorMode 描述新建/编辑上下文，依赖 Content/S3/NoteImageUploadQuota Repository 完成草稿、图片与额度读写，依赖 RichTextBridge 完成 HTML 与富文本互转
 * [OUTPUT]: 对外提供 RelevantEditorViewModel，驱动相关内容 create/edit、自动草稿恢复、附图缓存、OCR、校验与真实主键保存
 * [POS]: Content 模块相关内容编辑状态源，承接书籍分类/详情入口到统一编辑器、自动草稿与共享图片控制器的状态编排
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation

@MainActor
@Observable
/// 相关内容编辑状态源，负责标题/正文/URL 的加载、保存与错误反馈。
final class RelevantEditorViewModel {
    let mode: RelevantEditorMode

    var draft: RelevantEditorDraft?
    var title = "" {
        didSet { scheduleAutoSave() }
    }
    var url = "" {
        didSet { scheduleAutoSave() }
    }
    var contentText = NSAttributedString() {
        didSet { scheduleAutoSave() }
    }
    var activeFormats = Set<RichTextFormat>()
    var isLoading = false
    var isSaving = false
    var errorMessage: String?
    var pendingRecoveredDraft: RelevantEditorAutoSaveDraft?
    var lastAutoSaveTime: Int64 = 0
    var imageQuotaState: NoteImageUploadQuotaState?
    let imageController: ContentEditorImageController

    private let repository: any ContentRepositoryProtocol
    private let quotaRepository: any NoteImageUploadQuotaRepositoryProtocol
    private var isPremium: Bool
    private var baselineTitle = ""
    private var baselineURL = ""
    private var baselineContentText = NSAttributedString()
    private var baselineImageItems: [ContentEditorImageItem] = []
    private var isHydratingState = false
    private var autoSaveTask: Task<Void, Never>?
    private var imageQuotaReservationID = UUID().uuidString
    private var isImageQuotaReservationBackedByDraft = false
    private var isStagingImages = false

    /// 注入内容与上传仓储，建立不直接访问数据库、文件系统或网络客户端的编辑上下文。
    init(
        mode: RelevantEditorMode,
        repository: any ContentRepositoryProtocol,
        s3UploadRepository: any S3UploadRepositoryProtocol,
        quotaRepository: any NoteImageUploadQuotaRepositoryProtocol,
        isPremium: Bool
    ) {
        self.mode = mode
        self.repository = repository
        self.quotaRepository = quotaRepository
        self.isPremium = isPremium
        let imageController = ContentEditorImageController(
            repository: s3UploadRepository,
            uploadPrefix: "category_image"
        )
        self.imageController = imageController
        imageController.setItemsChangedHandler { [weak self] in
            self?.scheduleAutoSave()
        }
    }

    /// 兼容既有只传相关内容主键的编辑入口。
    convenience init(
        contentId: Int64,
        repository: any ContentRepositoryProtocol,
        s3UploadRepository: any S3UploadRepositoryProtocol,
        quotaRepository: any NoteImageUploadQuotaRepositoryProtocol,
        isPremium: Bool
    ) {
        self.init(
            mode: .edit(contentID: contentId),
            repository: repository,
            s3UploadRepository: s3UploadRepository,
            quotaRepository: quotaRepository,
            isPremium: isPremium
        )
    }

    var navigationTitle: String {
        switch mode {
        case .create: "新建相关内容"
        case .edit: "编辑相关内容"
        }
    }

    var contextSubtitle: String {
        let categoryTitle = draft?.categoryTitle.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !categoryTitle.isEmpty else { return navigationTitle }
        return categoryTitle
    }

    var imageItems: [ContentEditorImageItem] {
        imageController.items
    }

    var imageErrorMessage: String? {
        imageController.errorMessage
    }

    var availableImageSelectionCount: Int {
        let componentRemaining = max(0, ContentEditorImageItem.maximumCount - imageItems.count)
        return min(componentRemaining, imageQuotaState?.remainingCount ?? componentRemaining)
    }

    var autoSaveDescription: String? {
        guard lastAutoSaveTime > 0 else { return nil }
        let date = Date(timeIntervalSince1970: Double(lastAutoSaveTime) / 1_000)
        return "已自动保存于 \(Self.timeFormatter.string(from: date))"
    }

    var hasUnsavedChanges: Bool {
        guard draft != nil else { return false }
        return title != baselineTitle ||
            url != baselineURL ||
            !contentText.isEqual(to: baselineContentText) ||
            imageItems != baselineImageItems
    }

    /// 按入口模式加载相关内容草稿并转换为富文本状态；任务取消后不会覆盖当前页面内容。
    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            guard let draft = try await repository.fetchRelevantEditorDraft(mode: mode) else {
                errorMessage = "相关内容不存在或已删除"
                return
            }
            guard !Task.isCancelled else { return }
            isHydratingState = true
            self.draft = draft
            title = draft.title
            url = draft.url
            contentText = RichTextBridge.htmlToAttributed(draft.contentHTML)
            imageController.loadExistingItems(draft.imageItems)
            isHydratingState = false
            captureBaseline()

            if let recoveredDraft = repository.fetchRelevantEditorAutoSaveDraft(
                sourceBookId: draft.sourceBookId,
                categoryId: draft.categoryId,
                contentId: draft.contentId
            ), recoveredDraft.matches(
                sourceBookId: draft.sourceBookId,
                categoryId: draft.categoryId,
                contentId: draft.contentId
            ) {
                pendingRecoveredDraft = recoveredDraft
            }
            await refreshImageQuota()
        } catch {
            isHydratingState = false
            guard !Task.isCancelled else { return }
            errorMessage = "加载失败：\(error.localizedDescription)"
        }
    }

    /// 恢复严格匹配的自动草稿，并经图片仓储校验本地缓存后保留可重试项。
    func restoreRecoveredDraft() async {
        guard let recoveredDraft = pendingRecoveredDraft,
              let baseDraft = draft,
              recoveredDraft.matches(
                sourceBookId: baseDraft.sourceBookId,
                categoryId: baseDraft.categoryId,
                contentId: baseDraft.contentId
              ) else {
            pendingRecoveredDraft = nil
            return
        }

        if let reservationID = recoveredDraft.imageQuotaReservationID,
           !reservationID.isEmpty {
            imageQuotaReservationID = reservationID
        }
        isImageQuotaReservationBackedByDraft = true
        isHydratingState = true
        title = recoveredDraft.title
        url = recoveredDraft.url
        contentText = RichTextBridge.htmlToAttributed(recoveredDraft.contentHTML)
        await imageController.loadRecoveredItems(recoveredDraft.imageItems)
        lastAutoSaveTime = recoveredDraft.savedTime
        pendingRecoveredDraft = nil
        isHydratingState = false
        await refreshImageQuota()
    }

    /// 丢弃待恢复草稿并清理本地暂存图；成功远端 URL 只解除草稿引用。
    func discardRecoveredDraft() async {
        guard let recoveredDraft = pendingRecoveredDraft else { return }
        await imageController.discardStagedFiles(in: recoveredDraft.imageItems)
        repository.deleteRelevantEditorAutoSaveDraft(
            sourceBookId: recoveredDraft.sourceBookId,
            categoryId: recoveredDraft.categoryId,
            contentId: recoveredDraft.contentId
        )
        if let recoveredReservationID = recoveredDraft.imageQuotaReservationID {
            await quotaRepository.releaseReservation(id: recoveredReservationID)
        }
        pendingRecoveredDraft = nil
        lastAutoSaveTime = 0
        await refreshImageQuota()
    }

    /// 在 MainActor 校验并保存标题、正文与链接，成功时返回真实主键；重复提交被前置阻断，任务取消后不再改写页面基线。
    func save() async -> Int64? {
        guard !isSaving else { return nil }
        guard var draft else {
            errorMessage = "相关内容不存在或已删除"
            return nil
        }
        guard hasMeaningfulContent else {
            errorMessage = "请至少填写标题、正文或链接"
            return nil
        }
        guard isURLValid else {
            errorMessage = "链接必须以 http:// 或 https:// 开头"
            return nil
        }
        guard !imageController.hasUploadingImage else {
            errorMessage = "请等待所有图片上传成功后再保存"
            return nil
        }
        guard !imageController.hasFailedImage else {
            errorMessage = "仍有图片上传失败，请重试或删除后再保存"
            return nil
        }

        isSaving = true
        errorMessage = nil
        defer { isSaving = false }

        autoSaveTask?.cancel()
        autoSaveTask = nil

        draft.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.url = url.trimmingCharacters(in: .whitespacesAndNewlines)
        draft.contentHTML = RichTextBridge.attributedToHtml(contentText)
        draft.imageItems = imageItems
        let newImageCount = imageController.newDraftImageCount

        do {
            persistAutoSaveDraftIfNeeded()
            let contentID = try await repository.saveRelevantEditorDraft(draft, mode: mode)
            await quotaRepository.commitReservation(
                id: imageQuotaReservationID,
                savedImageCount: newImageCount,
                isPremium: isPremium
            )
            isImageQuotaReservationBackedByDraft = false
            imageController.markDraftImagesAsPersisted()
            draft.imageItems = imageItems
            self.draft = draft
            captureBaseline()
            pendingRecoveredDraft = nil
            lastAutoSaveTime = 0
            await refreshImageQuota()
            return contentID
        } catch {
            guard !Task.isCancelled else { return nil }
            errorMessage = "保存失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// 清空已经被界面消费的错误，允许后续同文案错误再次触发展示。
    func clearError() {
        errorMessage = nil
    }

    /// 将相册图片交给共享图片控制器暂存并上传，ViewModel 不直接执行文件或网络操作。
    func stageImages(_ inputs: [(data: Data, fileExtension: String)]) async {
        guard !inputs.isEmpty, !isStagingImages else { return }
        isStagingImages = true
        defer { isStagingImages = false }
        let componentAcceptedCount = min(
            inputs.count,
            max(0, ContentEditorImageItem.maximumCount - imageItems.count)
        )
        guard componentAcceptedCount > 0 else {
            errorMessage = "最多只能添加 \(ContentEditorImageItem.maximumCount) 张图片"
            return
        }
        let reservation = await quotaRepository.reserveImages(
            id: imageQuotaReservationID,
            owner: imageQuotaOwner,
            currentDraftNewImageCount: imageController.newDraftImageCount,
            requestedCount: componentAcceptedCount,
            isPremium: isPremium
        )
        imageQuotaState = reservation.state
        let acceptedCount = reservation.acceptedCount
        guard acceptedCount > 0 else {
            errorMessage = reservation.state.blockedMessage
            return
        }
        if acceptedCount < inputs.count {
            errorMessage = acceptedCount < componentAcceptedCount
                ? "已超出今日额度，保留前 \(acceptedCount) 张"
                : "最多只能添加 \(ContentEditorImageItem.maximumCount) 张图片，已保留前 \(acceptedCount) 张"
        }
        await imageController.stageImages(Array(inputs.prefix(acceptedCount)))
        autoSaveTask?.cancel()
        autoSaveTask = nil
        if persistAutoSaveDraftIfNeeded() {
            isImageQuotaReservationBackedByDraft = imageController.newDraftImageCount > 0
        }
        await refreshImageQuota()
    }

    /// 删除指定附图并清理未保存缓存，既有远端对象保持不变。
    func removeImage(id: String) async {
        await imageController.removeImage(id: id)
        await refreshImageQuota()
    }

    /// 重试一张失败附图的真实上传。
    func retryImage(id: String) {
        imageController.retryImage(id: id)
    }

    /// 更新附图拖拽顺序，供保存事务写入连续 order。
    func moveImage(sourceID: String, destinationID: String) {
        imageController.moveImage(sourceID: sourceID, destinationID: destinationID)
    }

    /// 将 OCR 识别结果追加到相关内容正文，保留原正文并用换行分隔。
    func appendRecognizedText(_ text: String) {
        let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        let mutable = NSMutableAttributedString(attributedString: contentText)
        if mutable.length > 0 {
            mutable.append(NSAttributedString(string: "\n"))
        }
        mutable.append(NSAttributedString(string: normalized))
        contentText = mutable
    }

    /// 放弃编辑时取消图片任务并清理本会话暂存文件。
    func discardEditingSession() async {
        autoSaveTask?.cancel()
        autoSaveTask = nil
        if let pendingRecoveredDraft {
            await imageController.discardStagedFiles(in: pendingRecoveredDraft.imageItems)
        }
        await imageController.discardEditingSession()
        deleteCurrentAutoSaveDraft()
        await quotaRepository.releaseReservation(id: imageQuotaReservationID)
        isImageQuotaReservationBackedByDraft = false
        if let recoveredReservationID = pendingRecoveredDraft?.imageQuotaReservationID,
           recoveredReservationID != imageQuotaReservationID {
            await quotaRepository.releaseReservation(id: recoveredReservationID)
        }
        pendingRecoveredDraft = nil
        lastAutoSaveTime = 0
    }

    /// 保留草稿退出时停止上传并立即落下最新快照，不清理仍有效的本地缓存。
    func preserveDraftForExit() -> Bool {
        autoSaveTask?.cancel()
        autoSaveTask = nil
        imageController.pauseUploadsPreservingStagedFiles()
        autoSaveTask?.cancel()
        autoSaveTask = nil
        return persistAutoSaveDraftIfNeeded()
    }

    /// 清空已被界面消费的图片错误。
    func clearImageError() {
        imageController.clearError()
    }

    /// 图片入口被额度前置阻断时复用当前快照生成标准系统弹窗文案。
    func showImageQuotaBlockedMessage() {
        if let imageQuotaState, imageQuotaState.isBlocked {
            errorMessage = imageQuotaState.blockedMessage
        } else {
            errorMessage = "最多只能添加 \(ContentEditorImageItem.maximumCount) 张图片"
        }
    }

    /// 会员状态变化时立即重算选择额度；MainActor 保证状态刷新不会与编辑器选择回写交错。
    func updatePremiumStatus(_ isPremium: Bool) async {
        self.isPremium = isPremium
        await refreshImageQuota()
    }

    private var hasMeaningfulContent: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !contentText.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            !imageItems.isEmpty
    }

    /// 通过额度仓储读取当前自然日状态；草稿预占只统计显式 newInDraft 图片。
    private func refreshImageQuota() async {
        imageQuotaState = await quotaRepository.reconcileReservation(
            id: imageQuotaReservationID,
            owner: imageQuotaOwner,
            draftNewImageCount: imageController.newDraftImageCount,
            isPersistedDraft: isImageQuotaReservationBackedByDraft,
            isPremium: isPremium
        )
    }

    /// 额度 owner 与相关内容自动草稿三元身份一致，用于恢复时清理同 owner 旧 ticket。
    private var imageQuotaOwner: NoteImageUploadReservationOwner {
        if let draft {
            return .relevant(
                bookID: draft.sourceBookId,
                categoryID: draft.categoryId,
                contentID: draft.contentId
            )
        }
        switch mode {
        case .create(let bookID, let categoryID):
            return .relevant(bookID: bookID, categoryID: categoryID, contentID: 0)
        case .edit(let contentID):
            return .relevant(bookID: 0, categoryID: 0, contentID: contentID)
        }
    }

    private var isURLValid: Bool {
        let value = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return true }
        let lowercased = value.lowercased()
        if lowercased.hasPrefix("http://") {
            return value.count > "http://".count
        }
        if lowercased.hasPrefix("https://") {
            return value.count > "https://".count
        }
        return false
    }

    /// 标题、正文、URL 或附件状态变化后重置两秒任务；取消后不会写入过期快照。
    private func scheduleAutoSave() {
        guard !isHydratingState, draft != nil, !isSaving else { return }
        autoSaveTask?.cancel()
        autoSaveTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            guard !Task.isCancelled, let self else { return }
            self.persistAutoSaveDraftIfNeeded()
            self.autoSaveTask = nil
        }
    }

    /// 相关内容允许 URL 或图片单独构成有效业务内容，修正 Android 自动草稿只看标题/正文的遗漏。
    @discardableResult
    private func persistAutoSaveDraftIfNeeded() -> Bool {
        guard let draft else { return false }
        guard hasUnsavedChanges else {
            deleteCurrentAutoSaveDraft()
            lastAutoSaveTime = 0
            return true
        }
        let timestamp = Self.currentTimestampMillis
        let autoSaveDraft = RelevantEditorAutoSaveDraft(
            sourceBookId: draft.sourceBookId,
            categoryId: draft.categoryId,
            contentId: draft.contentId,
            title: title,
            contentHTML: RichTextBridge.attributedToHtml(contentText),
            url: url,
            imageItems: imageItems,
            savedTime: timestamp,
            imageQuotaReservationID: imageQuotaReservationID
        )
        do {
            try repository.saveRelevantEditorAutoSaveDraft(autoSaveDraft)
            lastAutoSaveTime = timestamp
            return true
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return false
        }
    }

    /// 删除当前模式的精确自动草稿键，不影响同书其他分类或内容草稿。
    private func deleteCurrentAutoSaveDraft() {
        guard let draft else { return }
        repository.deleteRelevantEditorAutoSaveDraft(
            sourceBookId: draft.sourceBookId,
            categoryId: draft.categoryId,
            contentId: draft.contentId
        )
    }

    /// 复制当前字段与富文本快照作为脏状态基线，避免后续可变文本引用互相影响。
    private func captureBaseline() {
        baselineTitle = title
        baselineURL = url
        baselineContentText = contentText.copy() as? NSAttributedString ?? NSAttributedString()
        baselineImageItems = imageItems
    }

    nonisolated private static var currentTimestampMillis: Int64 {
        Int64(Date().timeIntervalSince1970 * 1_000)
    }

    nonisolated private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()
}
