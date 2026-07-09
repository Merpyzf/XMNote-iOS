/**
 * [INPUT]: 依赖 NoteRepositoryProtocol 提供书摘回顾设置、分页卡片、标签与书籍回显数据，依赖 ExternalAppIntegrationRepositoryProtocol 提供外部应用配置与书摘发送能力
 * [OUTPUT]: 对外提供 NoteReviewViewModel，驱动书摘回顾分页卡组、设置 Sheet、分页刷新与外部应用发送反馈状态
 * [POS]: ViewModels/Note 的书摘回顾状态编排器，被 NoteReviewView 与 NoteContainerView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import Photos

/// 书摘回顾外部应用发送的页面反馈事件，交给 View 消费后转为统一 Toast。
struct NoteReviewExternalAppFeedback: Identifiable, Equatable {
    /// 外部应用发送反馈的展示语义，与 XMToastCenter 的角色一一映射。
    enum Role: Equatable {
        case processing
        case success
        case error
        case warning
    }

    let id = UUID()
    let role: Role
    let message: String
}

/// 记录当前正在发送的书摘与目标，用于阻止重复触发同一类写操作。
struct NoteReviewExternalAppSendAction: Equatable {
    let noteID: Int64
    let destination: ExternalAppDestination
}

@MainActor
@Observable
/// 书摘回顾状态源，负责 Android 对齐筛选语义、卡堆分页、设置变更刷新与外部应用发送状态。
final class NoteReviewViewModel {
    private enum Constants {
        static let pageSize = 20
    }

    var settings: NoteReviewSettings = .defaultValue
    var items: [NoteReviewCardItem] = []
    var tagOptions: [NoteReviewTagOption] = []
    var selectedBooks: [BookPickerBook] = []
    var currentIndex = 0
    var selectedItemID: Int64?
    var isInitialLoading = false
    var isRefreshing = false
    var isLoadingMore = false
    var errorMessage: String?
    var configuredExternalAppDestinations: Set<ExternalAppDestination> = []
    var externalAppSendAction: NoteReviewExternalAppSendAction?
    var externalAppFeedback: NoteReviewExternalAppFeedback?
    var shareImageActionNoteID: Int64?
    var generatedShareFile: NoteReviewGeneratedShareFile?

    private let repository: any NoteRepositoryProtocol
    private let externalAppIntegrationRepository: any ExternalAppIntegrationRepositoryProtocol
    private var orderedOffset = 0
    private var canLoadMore = true
    private var hasLoadedOnce = false
    private var loadingGeneration = 0
    private var isSavingLocalSettings = false
    private var settingObservationTask: Task<Void, Never>?

    /// 注入笔记与外部应用仓储并启动设置变更观察；观察任务只在主线程回写 UI 状态，释放时会取消。
    init(
        repository: any NoteRepositoryProtocol,
        externalAppIntegrationRepository: any ExternalAppIntegrationRepositoryProtocol
    ) {
        self.repository = repository
        self.externalAppIntegrationRepository = externalAppIntegrationRepository
        observeSettingChanges()
    }

    /// 释放设置观察任务，避免页面销毁后继续刷新卡堆状态。
    isolated deinit {
        settingObservationTask?.cancel()
    }

    var currentItem: NoteReviewCardItem? {
        if let selectedItemID, let selectedItem = items.first(where: { $0.id == selectedItemID }) {
            return selectedItem
        }
        guard items.indices.contains(currentIndex) else { return items.first }
        return items[currentIndex]
    }

    var hasMoreItems: Bool {
        canLoadMore
    }

    var progressText: String {
        guard !items.isEmpty else { return "0 / 0" }
        let displayIndex = min(currentIndex + 1, items.count)
        return "\(displayIndex) / \(items.count)"
    }

    var bookScopeSummary: String {
        if selectedBooks.isEmpty {
            return "全部书籍"
        }
        if selectedBooks.count == 1, let title = selectedBooks.first?.title, !title.isEmpty {
            return title
        }
        return "\(selectedBooks.count) 本书"
    }

    var tagScopeSummary: String {
        let selected = selectedTagOptions
        if selected.isEmpty {
            return "不限标签"
        }
        if selected.count == 1, let title = selected.first?.title, !title.isEmpty {
            return title
        }
        return "\(selected.count) 个标签"
    }

    var selectedTagOptions: [NoteReviewTagOption] {
        let selectedIDs = Set(settings.selectedTagIDs)
        return tagOptions.filter { selectedIDs.contains($0.id) }
    }

    var hasConfiguredExternalAppDestinations: Bool {
        !configuredExternalAppDestinations.isEmpty
    }

    /// 首次进入时加载设置、筛选选项与第一页卡片；若任务取消则不回写旧状态。
    func loadIfNeeded() async {
        guard !hasLoadedOnce, !isInitialLoading else { return }
        loadingGeneration &+= 1
        let generation = loadingGeneration
        isInitialLoading = true
        errorMessage = nil
        defer {
            isInitialLoading = false
        }

        let storedSettings = repository.fetchNoteReviewSettings()
        settings = storedSettings

        do {
            async let tags = repository.fetchNoteReviewTagOptions()
            async let books = repository.fetchNoteReviewSelectedBooks(bookIDs: storedSettings.selectedBookIDs)
            async let page = repository.fetchNoteReviewPage(
                request: pageRequest(settings: storedSettings, reset: true)
            )
            let payload = try await (tags, books, page)
            guard !Task.isCancelled, generation == loadingGeneration else { return }
            tagOptions = payload.0
            selectedBooks = payload.1
            applyResetPage(payload.2, settings: storedSettings)
            hasLoadedOnce = true
        } catch {
            guard !Task.isCancelled, generation == loadingGeneration else { return }
            items = []
            currentIndex = 0
            selectedItemID = nil
            canLoadMore = false
            errorMessage = "加载回顾失败：\(error.localizedDescription)"
        }
    }

    /// 手动刷新当前回顾范围；刷新期间保留旧卡片，失败时只提示错误不清空当前阅读现场。
    func refresh() async {
        guard !isRefreshing else { return }
        loadingGeneration &+= 1
        let generation = loadingGeneration
        isRefreshing = true
        errorMessage = nil
        defer {
            isRefreshing = false
        }

        do {
            let page = try await repository.fetchNoteReviewPage(
                request: pageRequest(settings: settings, reset: true)
            )
            guard !Task.isCancelled, generation == loadingGeneration else { return }
            applyResetPage(page, settings: settings)
            hasLoadedOnce = true
        } catch {
            guard !Task.isCancelled, generation == loadingGeneration else { return }
            errorMessage = "刷新回顾失败：\(error.localizedDescription)"
        }
    }

    /// 卡堆接近末尾时加载下一页；分页失败不打断当前卡片浏览，只暴露错误反馈。
    func loadMoreIfNeeded() async {
        guard canLoadMore, !isLoadingMore, !items.isEmpty else { return }
        isLoadingMore = true
        errorMessage = nil
        defer {
            isLoadingMore = false
        }

        do {
            let nextPage = try await repository.fetchNoteReviewPage(
                request: pageRequest(settings: settings, reset: false)
            )
            guard !Task.isCancelled else { return }
            appendPage(nextPage, settings: settings)
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "继续加载失败：\(error.localizedDescription)"
        }
    }

    /// 卡片出现时同步当前位置；该方法只更新主线程状态，不触发数据库读取。
    func handleCardAppeared(_ item: NoteReviewCardItem, index: Int) {
        guard items.indices.contains(index), items[index].id == item.id else { return }
        currentIndex = index
        selectedItemID = item.id
    }

    /// 保存新设置，并按变化类型决定是否重载数据；外观变化只触发布局刷新。
    func updateSettings(_ nextSettings: NoteReviewSettings) async {
        let previous = settings
        guard nextSettings != previous else { return }

        settings = nextSettings
        isSavingLocalSettings = true
        repository.saveNoteReviewSettings(nextSettings)

        if previous.selectedBookIDs != nextSettings.selectedBookIDs {
            await reloadSelectedBooks(for: nextSettings.selectedBookIDs)
        }

        if !previous.hasSameDataScope(as: nextSettings) {
            await reloadForSettingsChange()
        }
    }

    /// 使用 BookPicker 回传结果更新书籍范围；空数组表示全部书籍。
    func updateSelectedBooks(_ books: [BookPickerBook]) async {
        var next = settings
        next.selectedBookIDs = books.map(\.id)
        selectedBooks = books
        await updateSettings(next)
    }

    /// 使用标签选择 Sheet 回传结果更新标签范围；空数组表示不限标签。
    func updateSelectedTagIDs(_ tagIDs: [Int64]) async {
        var next = settings
        next.selectedTagIDs = Self.uniquePositiveIDs(tagIDs)
        await updateSettings(next)
    }

    /// 当前卡堆进入通用内容查看器所需的来源上下文，按卡堆顺序保留分页身份。
    func viewerSourceContext() -> ContentViewerSourceContext {
        .noteReview(noteIDs: items.map(\.id))
    }

    /// 在主线程拉取当前卡片标签编辑快照；取消时不回写错误，失败时通过 errorMessage 交给页面反馈。
    func fetchTagEditSnapshot(for item: NoteReviewCardItem) async -> NoteReviewTagEditSnapshot? {
        do {
            return try await repository.fetchNoteReviewTagEditSnapshot(noteID: item.id)
        } catch {
            guard !Task.isCancelled else { return nil }
            errorMessage = "读取标签失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// 新建书摘标签并返回可直接选中的标签对象；取消时不回写错误，失败时由页面统一提示。
    func createTag(named name: String) async -> NoteEditorTagOption? {
        do {
            let tag = try await repository.createNoteTag(named: name)
            await reloadTagOptionsAfterTagMutation()
            return tag
        } catch {
            guard !Task.isCancelled else { return nil }
            errorMessage = "创建标签失败：\(error.localizedDescription)"
            return nil
        }
    }

    /// 保存当前卡片标签并同步当前卡堆缓存；取消时不更新 UI，成功后刷新筛选标签计数。
    func replaceTags(_ tags: [NoteEditorTagOption], for item: NoteReviewCardItem) async -> Bool {
        do {
            let confirmedTags = try await repository.replaceNoteReviewTags(noteID: item.id, tags: tags)
            updateLocalTags(confirmedTags, noteID: item.id)
            await reloadTagOptionsAfterTagMutation()
            return true
        } catch {
            guard !Task.isCancelled else { return false }
            errorMessage = "保存标签失败：\(error.localizedDescription)"
            return false
        }
    }

    /// 清除已展示的错误消息，避免 Toast 因同一状态重复出现。
    func consumeErrorMessage() {
        errorMessage = nil
    }

    /// 重新读取外部应用配置；该方法仅同步主线程可观察状态，不触发网络或数据库写入。
    func reloadExternalAppAvailability() {
        configuredExternalAppDestinations = Set(externalAppIntegrationRepository.configuredDestinations())
    }

    /// 判断指定外部应用是否已配置，用于菜单构建时过滤不可执行目标。
    func isExternalAppDestinationConfigured(_ destination: ExternalAppDestination) -> Bool {
        configuredExternalAppDestinations.contains(destination)
    }

    /// 判断指定目标当前是否处于发送中，用于让菜单按钮继承原生 disabled 语义。
    func isSendingExternalApp(to destination: ExternalAppDestination) -> Bool {
        externalAppSendAction?.destination == destination
    }

    /// 判断指定卡片是否正在生成分享图，用于菜单动作防重复。
    func isGeneratingShareImage(for item: NoteReviewCardItem) -> Bool {
        shareImageActionNoteID == item.id
    }

    /// 生成当前回顾卡片分享图，保存到相册后交给 View 打开系统分享面板。
    func shareImage(for item: NoteReviewCardItem) async {
        guard shareImageActionNoteID == nil else { return }
        shareImageActionNoteID = item.id
        externalAppFeedback = NoteReviewExternalAppFeedback(role: .processing, message: "正在生成分享图…")
        defer {
            shareImageActionNoteID = nil
        }

        do {
            let file = try NoteReviewShareImageRenderer().renderPNG(for: item)
            try await Self.saveImageToPhotoLibrary(fileURL: file.fileURL)
            guard !Task.isCancelled else { return }
            generatedShareFile = file
            externalAppFeedback = NoteReviewExternalAppFeedback(role: .success, message: "分享图已保存")
        } catch {
            guard !Task.isCancelled else { return }
            externalAppFeedback = NoteReviewExternalAppFeedback(
                role: .error,
                message: "生成分享图失败：\(error.localizedDescription)"
            )
        }
    }

    /// 发送当前书摘到外部应用；方法运行在主线程，发送前立即发布处理中反馈并设置进行中动作，取消或失败都会恢复入口状态。
    func send(item: NoteReviewCardItem, to destination: ExternalAppDestination) async {
        guard externalAppSendAction == nil else { return }
        guard isExternalAppDestinationConfigured(destination) else {
            externalAppFeedback = NoteReviewExternalAppFeedback(
                role: .warning,
                message: "请先配置 \(destination.noteReviewDisplayName)"
            )
            return
        }

        externalAppSendAction = NoteReviewExternalAppSendAction(noteID: item.id, destination: destination)
        externalAppFeedback = NoteReviewExternalAppFeedback(
            role: .processing,
            message: "正在发送到 \(destination.noteReviewDisplayName)…"
        )
        defer {
            externalAppSendAction = nil
        }

        do {
            _ = try await externalAppIntegrationRepository.send(noteID: item.id, to: destination)
            guard !Task.isCancelled else { return }
            externalAppFeedback = NoteReviewExternalAppFeedback(
                role: .success,
                message: "已发送到 \(destination.noteReviewDisplayName)"
            )
        } catch {
            guard !Task.isCancelled else { return }
            externalAppFeedback = NoteReviewExternalAppFeedback(
                role: .error,
                message: "发送到 \(destination.noteReviewDisplayName) 失败：\(error.localizedDescription)"
            )
        }
    }

    /// 清除已消费的外部应用反馈，避免同一条 Toast 反复展示。
    func consumeExternalAppFeedback() {
        externalAppFeedback = nil
    }
}

private extension NoteReviewViewModel {
    static func saveImageToPhotoLibrary(fileURL: URL) async throws {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let resolvedStatus: PHAuthorizationStatus
        if status == .notDetermined {
            resolvedStatus = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        } else {
            resolvedStatus = status
        }

        guard resolvedStatus == .authorized || resolvedStatus == .limited else {
            throw NoteReviewShareImageSaveError.photoLibraryPermissionDenied
        }

        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.creationRequestForAssetFromImage(atFileURL: fileURL)
        }
    }

    func observeSettingChanges() {
        settingObservationTask = Task { [weak self] in
            guard let self else { return }
            for await _ in repository.observeNoteReviewSettingChanges() {
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    guard !self.isSavingLocalSettings else {
                        self.isSavingLocalSettings = false
                        return
                    }
                }
                await self.reloadStoredSettingsFromExternalChange()
            }
        }
    }

    func reloadStoredSettingsFromExternalChange() async {
        let next = repository.fetchNoteReviewSettings()
        guard next != settings else { return }
        await updateSettings(next)
    }

    func reloadForSettingsChange() async {
        if items.isEmpty {
            hasLoadedOnce = false
            await loadIfNeeded()
        } else {
            await refresh()
        }
    }

    func reloadSelectedBooks(for bookIDs: [Int64]) async {
        do {
            selectedBooks = try await repository.fetchNoteReviewSelectedBooks(bookIDs: bookIDs)
        } catch {
            errorMessage = "读取书籍范围失败：\(error.localizedDescription)"
        }
    }

    func reloadTagOptionsAfterTagMutation() async {
        do {
            tagOptions = try await repository.fetchNoteReviewTagOptions()
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "刷新标签选项失败：\(error.localizedDescription)"
        }
    }

    func updateLocalTags(_ tags: [NoteEditorTagOption], noteID: Int64) {
        guard let index = items.firstIndex(where: { $0.id == noteID }) else { return }
        items[index] = items[index].replacingTags(tags)
    }

    func pageRequest(settings: NoteReviewSettings, reset: Bool) -> NoteReviewPageRequest {
        NoteReviewPageRequest(
            settings: settings,
            offset: reset ? 0 : orderedOffset,
            excludedNoteIDs: reset ? [] : items.map(\.id),
            limit: Constants.pageSize
        )
    }

    func applyResetPage(_ page: [NoteReviewCardItem], settings: NoteReviewSettings) {
        items = page
        syncSelection(preferredID: page.first?.id)
        orderedOffset = settings.sortRule == .ordered ? page.count : 0
        canLoadMore = page.count == Constants.pageSize
    }

    func appendPage(_ page: [NoteReviewCardItem], settings: NoteReviewSettings) {
        guard !page.isEmpty else {
            canLoadMore = false
            return
        }
        let existingIDs = Set(items.map(\.id))
        let uniquePage = page.filter { !existingIDs.contains($0.id) }
        let preferredID = selectedItemID ?? currentItem?.id
        items.append(contentsOf: uniquePage)
        syncSelection(preferredID: preferredID)
        if settings.sortRule == .ordered {
            orderedOffset += page.count
        }
        canLoadMore = page.count == Constants.pageSize && !uniquePage.isEmpty
    }

    func syncSelection(preferredID: Int64?) {
        guard !items.isEmpty else {
            currentIndex = 0
            selectedItemID = nil
            return
        }

        if let preferredID,
           let index = items.firstIndex(where: { $0.id == preferredID }) {
            currentIndex = index
            selectedItemID = preferredID
            return
        }

        currentIndex = 0
        selectedItemID = items[0].id
    }

    static func uniquePositiveIDs(_ ids: [Int64]) -> [Int64] {
        var seen = Set<Int64>()
        var result: [Int64] = []
        result.reserveCapacity(ids.count)
        for id in ids where id > 0 && !seen.contains(id) {
            seen.insert(id)
            result.append(id)
        }
        return result
    }
}

private extension ExternalAppDestination {
    var noteReviewDisplayName: String {
        switch self {
        case .flomo:
            return "Flomo"
        case .writeathon:
            return "Writeathon"
        case .inbox:
            return "Inbox"
        }
    }
}
