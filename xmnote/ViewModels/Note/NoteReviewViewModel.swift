/**
 * [INPUT]: 依赖 NoteRepositoryProtocol 提供书摘回顾设置、分页卡片、标签与书籍回显数据，依赖 ExternalAppIntegrationRepositoryProtocol/AIRepositoryProtocol 提供外部发送与 AI 配置预检，并向页面私有换组宿主提供候选页准备与无动画提交能力
 * [OUTPUT]: 对外提供 NoteReviewViewModel，驱动书摘回顾分页卡组、设置 Sheet、统一标签编辑、随机换组交接、可取消分享图与外部应用发送反馈状态
 * [POS]: ViewModels/Note 的书摘回顾状态编排器，被 NoteReviewView 与 NoteContainerView 消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Foundation
import CoreText
import Photos
import UIKit

/// 随机换组在视觉交接前持有的候选页面；不保存点击时 selection，提交时始终从候选第一页开始。
nonisolated struct NoteReviewPreparedRefresh: Sendable {
    let items: [NoteReviewCardItem]
    let settings: NoteReviewSettings
    let generation: Int
}

/// 候选页查询的显式结果，让页面宿主仅为仍处于最新意图的失败发布现有 Toast。
nonisolated enum NoteReviewPrepareRefreshResult: Sendable {
    case prepared(NoteReviewPreparedRefresh)
    case failed(String)
    case cancelled
}

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

/// 回顾页启动整条书摘 AI 释义前的配置检查结果，区分设置引导、读取失败与任务取消。
nonisolated enum NoteReviewAIAvailabilityResult: Equatable, Sendable {
    case available
    case configurationRequired
    case failed(String)
    case cancelled
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
    var isUploadingBackground = false
    var isImportingFont = false

    private let repository: any NoteRepositoryProtocol
    private let externalAppIntegrationRepository: any ExternalAppIntegrationRepositoryProtocol
    private let aiRepository: any AIRepositoryProtocol
    private var orderedOffset = 0
    private var canLoadMore = true
    private var hasLoadedOnce = false
    private var loadingGeneration = 0
    private var isSavingLocalSettings = false
    private var isApplyingLocalDataChange = false
    private var hasPendingExternalDataRefresh = false
    private var settingObservationTask: Task<Void, Never>?
    private var dataObservationTask: Task<Void, Never>?
    private var externalDataRefreshTask: Task<Void, Never>?
    private var externalAppObservationTask: Task<Void, Never>?
    private var shareImageGenerationID: UUID?

    /// 注入笔记、外部应用与 AI 仓储并启动设置变更观察；观察任务只在主线程回写 UI 状态，释放时会取消。
    init(
        repository: any NoteRepositoryProtocol,
        externalAppIntegrationRepository: any ExternalAppIntegrationRepositoryProtocol,
        aiRepository: any AIRepositoryProtocol
    ) {
        self.repository = repository
        self.externalAppIntegrationRepository = externalAppIntegrationRepository
        self.aiRepository = aiRepository
        observeSettingChanges()
        observeDataChanges()
        observeExternalAppConfigurationChanges()
    }

    /// 释放全部观察与数据刷新任务，确保页面销毁后取消数据库迭代和仍在途的补刷查询。
    isolated deinit {
        settingObservationTask?.cancel()
        dataObservationTask?.cancel()
        externalDataRefreshTask?.cancel()
        externalAppObservationTask?.cancel()
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
            schedulePendingExternalDataRefreshIfNeeded()
        }

        let storedSettings = resolvedStoredSettings(repository.fetchNoteReviewSettings())
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

    /// 手动刷新当前回顾范围；此路径供顺序模式和设置变更即时提交，任务在主线程回写且用 generation 丢弃取消或过期响应。
    func refresh() async {
        guard !isRefreshing else { return }
        loadingGeneration &+= 1
        let generation = loadingGeneration
        isRefreshing = true
        errorMessage = nil
        defer {
            isRefreshing = false
            schedulePendingExternalDataRefreshIfNeeded()
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

    /// 为随机“换一组”查询候选页但不改动 live deck；任务从主线程发起，取消或 generation 失效的响应不会回写状态，也不会捕获查询开始时的旧 selection。
    func prepareRefresh() async -> NoteReviewPrepareRefreshResult {
        guard !isInitialLoading, !isRefreshing else { return .cancelled }
        loadingGeneration &+= 1
        let generation = loadingGeneration
        let preparedSettings = settings
        isRefreshing = true
        errorMessage = nil

        do {
            let page = try await repository.fetchNoteReviewPage(
                request: pageRequest(settings: preparedSettings, reset: true)
            )
            guard !Task.isCancelled, generation == loadingGeneration else { return .cancelled }
            return .prepared(
                NoteReviewPreparedRefresh(
                    items: page,
                    settings: preparedSettings,
                    generation: generation
                )
            )
        } catch {
            guard !Task.isCancelled, generation == loadingGeneration else { return .cancelled }
            return .failed("刷新回顾失败：\(error.localizedDescription)")
        }
    }

    /// 在卡组交接落定后一次性提交候选页并选择第一页；提交会消费并推进 generation，使换组期间启动的旧分页响应失效。
    @discardableResult
    func commitPreparedRefresh(_ prepared: NoteReviewPreparedRefresh) -> Bool {
        guard prepared.generation == loadingGeneration else { return false }
        applyResetPage(prepared.items, settings: prepared.settings)
        loadingGeneration &+= 1
        hasLoadedOnce = true
        isRefreshing = false
        schedulePendingExternalDataRefreshIfNeeded()
        return true
    }

    /// 取消仍在途或尚未提交的随机换组；在主线程推进 generation，使 Task 返回后无法覆盖设置变化、页面消失后的 live deck。
    func cancelPreparedRefresh() {
        loadingGeneration &+= 1
        isRefreshing = false
        schedulePendingExternalDataRefreshIfNeeded()
    }

    /// 仅由最新随机换组意图调用，复用页面既有 errorMessage → Toast 反馈链路。
    func publishPreparedRefreshError(_ message: String) {
        errorMessage = message
    }

    /// 卡堆接近末尾时加载下一页；分页失败不打断当前卡片浏览，只暴露错误反馈。
    func loadMoreIfNeeded() async {
        guard canLoadMore,
              !isRefreshing,
              !isLoadingMore,
              externalDataRefreshTask == nil,
              !items.isEmpty
        else { return }
        let generation = loadingGeneration
        let requestedSettings = settings
        isLoadingMore = true
        errorMessage = nil
        defer {
            isLoadingMore = false
            schedulePendingExternalDataRefreshIfNeeded()
        }

        do {
            let nextPage = try await repository.fetchNoteReviewPage(
                request: pageRequest(settings: requestedSettings, reset: false)
            )
            guard !Task.isCancelled,
                  generation == loadingGeneration,
                  requestedSettings == settings
            else { return }
            appendPage(nextPage, settings: requestedSettings)
        } catch {
            guard !Task.isCancelled,
                  generation == loadingGeneration,
                  requestedSettings == settings
            else { return }
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

        cancelPreparedRefresh()
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

    /// 保存回顾背景类型；图片模式在没有已上传图片时仍保留颜色回退，避免卡片出现空白背景。
    func updateBackgroundMode(_ mode: NoteReviewBackgroundMode) async {
        var next = settings
        next.backgroundMode = mode
        await updateSettings(next)
    }

    /// 将本地相册图片经 Repository 上传后写入回顾设置；上传期间锁定重复入口，失败只回写错误反馈。
    func uploadBackgroundImage(from localURL: URL) async {
        guard !isUploadingBackground else { return }
        isUploadingBackground = true
        defer { isUploadingBackground = false }

        do {
            let result = try await repository.uploadNoteReviewBackground(localURL: localURL)
            var next = settings
            next.backgroundMode = .image
            next.backgroundImageURL = result.remoteURL.absoluteString
            await updateSettings(next)
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "上传回顾背景失败：\(error.localizedDescription)"
        }
    }

    /// 清除已保存的图片背景地址并回退到颜色背景；远端对象保留，避免当前配置被误删影响其他设备。
    func clearBackgroundImage() async {
        var next = settings
        next.backgroundImageURL = nil
        next.backgroundMode = .color
        await updateSettings(next)
    }

    /// 保存 Android 回顾设置中的自定义文字颜色（RGB，不保存透明度）。
    func updateCustomTextColorHex(_ hex: UInt32) async {
        var next = settings
        next.customTextColorHex = hex
        await updateSettings(next)
    }

    /// 在主线程串行复制并注册本地字体，重复触发由 isImportingFont 阻断；同步注册不可取消，真实失败时回收本次复制文件且不破坏当前选择。
    func importFont(from sourceURL: URL) async {
        guard !isImportingFont else { return }
        isImportingFont = true
        defer { isImportingFont = false }

        var copiedFontURL: URL?
        do {
            let destination = try Self.copyFontToApplicationSupport(from: sourceURL)
            copiedFontURL = destination
            let displayName = try Self.registerFontIfNeeded(at: destination)
            copiedFontURL = nil
            var next = settings
            next.fontSelection = .local(fileName: destination.lastPathComponent, displayName: displayName)
            await updateSettings(next)
        } catch {
            if let copiedFontURL {
                try? FileManager.default.removeItem(at: copiedFontURL)
            }
            guard !Task.isCancelled else { return }
            errorMessage = "导入回顾字体失败：\(error.localizedDescription)"
        }
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

    /// 新建书摘标签并返回可直接选中的标签对象；任务随调用方取消，失败同时保留页面既有错误通道并向创建 Sheet 抛出。
    func createTag(named name: String) async throws -> NoteEditorTagOption {
        do {
            let tag = try await repository.createNoteTag(named: name)
            await reloadTagOptionsAfterTagMutation()
            return tag
        } catch {
            if !Task.isCancelled {
                errorMessage = "创建标签失败：\(error.localizedDescription)"
            }
            throw error
        }
    }

    /// 保存当前卡片标签并同步当前卡堆缓存；取消时不更新 UI，成功后刷新筛选标签计数。
    func replaceTags(_ tags: [NoteEditorTagOption], for item: NoteReviewCardItem) async -> Bool {
        isApplyingLocalDataChange = true
        defer {
            isApplyingLocalDataChange = false
        }
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

    /// 通过 AI Repository 读取安全配置快照；取消不产生反馈，配置不完整时由页面引导到 AI 设置。
    func checkAIAvailability() async -> NoteReviewAIAvailabilityResult {
        do {
            let snapshot = try await aiRepository.fetchConfiguration()
            try Task.checkCancellation()
            let configuration = snapshot.configuration.normalized
            let hasCompletePrompts = AIPromptKind.allCases.allSatisfy { kind in
                let prompt = configuration.prompts.template(for: kind)
                return !prompt.system.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    && !prompt.user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            guard configuration.isEnabled,
                  snapshot.hasStoredKey(for: configuration.provider),
                  hasCompletePrompts
            else {
                return .configurationRequired
            }
            return .available
        } catch is CancellationError {
            return .cancelled
        } catch {
            return .failed("读取 AI 配置失败：\(error.localizedDescription)")
        }
    }

    /// 在 AI 追加想法前声明本地写入，使数据库观察仅消费本次事件而不随机重载整组卡片。
    func beginLocalAIAppend() {
        isApplyingLocalDataChange = true
    }

    /// AI 追加失败时撤销本地写入声明，避免吞掉下一次无关的数据变化事件。
    func cancelLocalAIAppend() {
        isApplyingLocalDataChange = false
    }

    /// AI 追加成功后按主键重读单张卡片；只替换原位置内容，保持当前卡组顺序与选中身份。
    func reloadItemAfterAIAppend(noteID: Int64) async {
        do {
            guard let refreshedItem = try await repository.fetchNoteReviewItem(noteID: noteID),
                  let index = items.firstIndex(where: { $0.id == noteID })
            else { return }
            items[index] = refreshedItem
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = "刷新 AI 释义结果失败：\(error.localizedDescription)"
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

    /// 在主线程编排分享图与相册写入；调用任务取消或 generation 失效后丢弃迟到结果，并由匹配 generation 的 defer 复位入口。
    func shareImage(for item: NoteReviewCardItem, isDarkAppearance: Bool) async {
        guard shareImageActionNoteID == nil else { return }
        let generationID = UUID()
        shareImageGenerationID = generationID
        shareImageActionNoteID = item.id
        externalAppFeedback = NoteReviewExternalAppFeedback(role: .processing, message: "正在生成分享图…")
        defer {
            if shareImageGenerationID == generationID {
                shareImageGenerationID = nil
                shareImageActionNoteID = nil
            }
        }

        var renderedFile: NoteReviewGeneratedShareFile?
        do {
            let file = try await renderShareImage(for: item, isDarkAppearance: isDarkAppearance)
            renderedFile = file
            try Task.checkCancellation()
            guard shareImageGenerationID == generationID else {
                Self.discardTemporaryShareFile(file.fileURL)
                return
            }
            try await Self.saveImageToPhotoLibrary(fileURL: file.fileURL)
            guard !Task.isCancelled, shareImageGenerationID == generationID else {
                Self.discardTemporaryShareFile(file.fileURL)
                return
            }
            generatedShareFile = file
            externalAppFeedback = NoteReviewExternalAppFeedback(role: .success, message: "分享图已保存")
        } catch {
            if let renderedFile {
                Self.discardTemporaryShareFile(renderedFile.fileURL)
            }
            guard !Task.isCancelled, shareImageGenerationID == generationID else { return }
            externalAppFeedback = NoteReviewExternalAppFeedback(
                role: .error,
                message: "生成分享图失败：\(error.localizedDescription)"
            )
        }
    }

    /// 在主线程立即失效当前分享 generation；页面托管任务随后取消，旧响应与旧 defer 均无法覆盖下一次分享状态。
    func cancelShareImageGeneration() {
        shareImageGenerationID = nil
        shareImageActionNoteID = nil
        if externalAppFeedback?.role == .processing,
           externalAppFeedback?.message == "正在生成分享图…" {
            externalAppFeedback = nil
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

    /// 将全局标签目录写入即时投影到筛选选项和已加载卡片，数据库观察后的刷新仍作为最终事实收敛。
    func applyTagCatalogMutation(_ mutation: TagCatalogMutation) {
        guard mutation.scope == .note else { return }
        let nextOptions = mutation.applying(to: tagOptions)
        if nextOptions != tagOptions {
            tagOptions = nextOptions
        }
        items = items.map { item in
            let nextTags = mutation.applying(to: item.tags)
            return nextTags == item.tags ? item : item.replacingTags(nextTags)
        }
    }
}

private extension NoteReviewViewModel {
    /// 读取设置后确认本地字体文件仍存在；文件丢失时回退到内置衬线字体，保持卡片可读。
    func resolvedStoredSettings(_ stored: NoteReviewSettings) -> NoteReviewSettings {
        var resolved = stored
        if case .local(let fileName, _) = stored.fontSelection {
            let url = Self.fontDirectoryURL().appendingPathComponent(fileName)
            if !FileManager.default.fileExists(atPath: url.path)
                || (try? Self.registerFontIfNeeded(at: url)) == nil {
                resolved.fontSelection = .sourceHanSerif
            }
        }
        return resolved
    }

    /// 在主线程串起远程背景读取与固定 PNG 渲染，并将触发时的亮暗外观显式传给渲染器。
    func renderShareImage(
        for item: NoteReviewCardItem,
        isDarkAppearance: Bool
    ) async throws -> NoteReviewGeneratedShareFile {
        let backgroundImageData: Data?
        if settings.backgroundMode == .image,
           let rawURL = settings.backgroundImageURL,
           let url = URL(string: rawURL) {
            backgroundImageData = try? await repository.fetchNoteReviewBackgroundData(remoteURL: url)
        } else {
            backgroundImageData = nil
        }

        return try await NoteReviewShareImageRenderer().renderPNG(
            for: item,
            settings: settings,
            isDarkAppearance: isDarkAppearance,
            backgroundImageData: backgroundImageData
        )
    }

    /// 将导入的字体复制到应用支持目录，避免依赖外部文件提供者的临时安全作用域。
    static func copyFontToApplicationSupport(from sourceURL: URL) throws -> URL {
        let didStartAccessing = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didStartAccessing {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let directory = fontDirectoryURL()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let ext = sourceURL.pathExtension.isEmpty ? "ttf" : sourceURL.pathExtension.lowercased()
        let destination = directory.appendingPathComponent("font_\(UUID().uuidString).\(ext)")
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    static func fontDirectoryURL() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NoteReviewFonts", isDirectory: true)
    }

    static func fontDisplayName(at url: URL) -> String? {
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let descriptor = descriptors.first,
              let name = CTFontDescriptorCopyAttribute(descriptor, kCTFontNameAttribute) as? String else {
            return nil
        }
        return name
    }

    /// 在主线程确认本地字体已进入进程作用域；同步调用没有取消点，并通过注册后再次查询消解并发或重复注册竞态。
    static func registerFontIfNeeded(at url: URL) throws -> String {
        guard let fontName = fontDisplayName(at: url) else {
            throw NoteReviewFontImportError.registrationFailed
        }
        if UIFont(name: fontName, size: 12) != nil {
            return fontName
        }

        var registrationError: Unmanaged<CFError>?
        let didRegister = CTFontManagerRegisterFontsForURL(
            url as CFURL,
            .process,
            &registrationError
        )
        if let registrationError {
            _ = registrationError.takeRetainedValue()
        }
        guard didRegister || UIFont(name: fontName, size: 12) != nil else {
            throw NoteReviewFontImportError.registrationFailed
        }
        return fontName
    }

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

    /// 仅移除本次尚未交给系统分享面板的临时 PNG；文件已被渲染器清理时静默忽略。
    static func discardTemporaryShareFile(_ fileURL: URL) {
        try? FileManager.default.removeItem(at: fileURL)
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

    /// 观察 Repository 的数据库变化；任务继承主线程状态上下文，仅标记待刷新并交给单任务调度器合并，取消后不再回写回顾卡组。
    /// 本地标签写入会先更新当前卡片，消费下一次数据库事件，避免 Android 同类事件造成重复重载。
    func observeDataChanges() {
        dataObservationTask = Task { [weak self] in
            guard let self else { return }
            do {
                for try await _ in repository.observeNoteReviewDataChanges() {
                    guard !Task.isCancelled else { return }
                    if isApplyingLocalDataChange {
                        isApplyingLocalDataChange = false
                        continue
                    }
                    markExternalDataRefreshPending()
                }
            } catch {
                guard !Task.isCancelled else { return }
                errorMessage = "同步回顾数据失败：\(error.localizedDescription)"
            }
        }
    }

    private var canProcessPendingExternalDataRefresh: Bool {
        hasLoadedOnce
            && !isInitialLoading
            && !isRefreshing
            && !isLoadingMore
    }

    /// 在主线程记录一次外部数据脏状态并尝试调度；重复事件只保留一个 pending 标记，不创建队列。
    func markExternalDataRefreshPending() {
        hasPendingExternalDataRefresh = true
        schedulePendingExternalDataRefreshIfNeeded()
    }

    /// 在主线程创建唯一补刷任务；忙碌状态只保留 pending，现有任务或页面释放取消可阻止重复查询与旧状态回写。
    func schedulePendingExternalDataRefreshIfNeeded() {
        guard externalDataRefreshTask == nil,
              hasPendingExternalDataRefresh,
              canProcessPendingExternalDataRefresh
        else { return }

        externalDataRefreshTask = Task { [weak self] in
            guard let self else { return }
            await processPendingExternalDataRefreshes()
        }
    }

    /// 在主线程串行消费 pending 数据事件；每轮查询沿用 generation 竞态保护，任务取消时停止循环且不再自调度。
    func processPendingExternalDataRefreshes() async {
        defer {
            externalDataRefreshTask = nil
            if !Task.isCancelled {
                schedulePendingExternalDataRefreshIfNeeded()
            }
        }

        while !Task.isCancelled,
              hasPendingExternalDataRefresh,
              canProcessPendingExternalDataRefresh {
            hasPendingExternalDataRefresh = false
            await reloadForExternalDataChange()
        }
    }

    /// 观察关联应用配置，保持保活回顾页的“发送到”菜单与 Android API 配置事件一致。
    func observeExternalAppConfigurationChanges() {
        externalAppObservationTask = Task { [weak self] in
            guard let self else { return }
            for await _ in externalAppIntegrationRepository.observeConfigurationChanges() {
                guard !Task.isCancelled else { return }
                reloadExternalAppAvailability()
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

    /// 由唯一补刷任务在主线程刷新当前范围；generation 丢弃竞态旧响应，若当前卡仍在首屏结果中则保留其选中身份。
    func reloadForExternalDataChange() async {
        guard hasLoadedOnce else { return }
        let preferredID = selectedItemID ?? currentItem?.id
        loadingGeneration &+= 1
        let generation = loadingGeneration

        do {
            let page = try await repository.fetchNoteReviewPage(
                request: pageRequest(settings: settings, reset: true)
            )
            guard !Task.isCancelled, generation == loadingGeneration else { return }
            applyResetPage(page, settings: settings, preferredID: preferredID)
        } catch {
            guard !Task.isCancelled, generation == loadingGeneration else { return }
            errorMessage = "同步回顾失败：\(error.localizedDescription)"
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

    func applyResetPage(
        _ page: [NoteReviewCardItem],
        settings: NoteReviewSettings,
        preferredID: Int64? = nil
    ) {
        items = page
        syncSelection(preferredID: preferredID ?? page.first?.id)
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

/// 本地回顾字体导入失败原因，映射为设置页可见的错误反馈。
nonisolated enum NoteReviewFontImportError: LocalizedError, Equatable, Sendable {
    case registrationFailed

    var errorDescription: String? {
        switch self {
        case .registrationFailed:
            return "系统无法注册该字体文件"
        }
    }
}
