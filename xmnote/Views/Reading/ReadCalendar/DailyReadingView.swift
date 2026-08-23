/**
 * [INPUT]: 依赖 RepositoryContainer、AppNavigationCoordinator、DailyReadingViewModel、轨迹私有组件与浏览导航回调
 * [OUTPUT]: 对外提供 DailyReadingView，以主滚动视图展示指定自然日轨迹，并承接筛选、打卡、记录管理、统一书摘标签编辑、相关书籍编辑与可重试刷新告警
 * [POS]: ReadCalendar 日期点击后的唯一二级页面，内容态由系统主滚动视图直接承载，取代独立汇总页与单书三级页
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

/// 当日阅读轨迹页；顶部只保留统一更多入口，书籍与类型筛选不占用正文阅读空间。
struct DailyReadingView: View {
    let onOpenBookRoute: (BookRoute) -> Void
    let onOpenNoteRoute: (NoteRoute) -> Void
    let onOpenContentRoute: (ContentRoute) -> Void

    @Environment(RepositoryContainer.self) private var repositories
    @Environment(AppNavigationCoordinator.self) private var navigationCoordinator
    @Environment(\.openURL) private var openURL
    @Environment(\.colorScheme) private var colorScheme
    @State private var viewModel: DailyReadingViewModel
    @State private var loadingGate = LoadingGate()
    @State private var isCheckInPresented = false
    @State private var isBookFilterPresented = false
    @State private var editingRecord: DailyReadingRecord?
    @State private var pendingDelete: DailyReadingRecord?
    @State private var tagEditSession: DailyReadingTagEditSession?
    @State private var relatedBookDraft: RelatedBookRelationDraft?
    @State private var generatedShareFile: NoteReviewGeneratedShareFile?
    @State private var toastCenter = XMToastCenter()
    @State private var observationRevision = 0

    /// 注入目标日期与跨模块导航回调，页面自行读取当天完整轨迹。
    init(
        date: Date,
        onOpenBookRoute: @escaping (BookRoute) -> Void,
        onOpenNoteRoute: @escaping (NoteRoute) -> Void,
        onOpenContentRoute: @escaping (ContentRoute) -> Void
    ) {
        self.onOpenBookRoute = onOpenBookRoute
        self.onOpenNoteRoute = onOpenNoteRoute
        self.onOpenContentRoute = onOpenContentRoute
        _viewModel = State(initialValue: DailyReadingViewModel(date: date))
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.surfacePage.ignoresSafeArea()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .navigationTitle(viewModel.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.automatic, for: .navigationBar)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                DailyReadingMoreMenu(
                    bookCount: viewModel.books.count,
                    canCheckIn: viewModel.canCheckIn,
                    isWriting: viewModel.isWriting,
                    filter: viewModel.filter,
                    sortOrder: viewModel.sortOrder,
                    onCheckIn: { isCheckInPresented = true },
                    onShowBookFilter: { isBookFilterPresented = true },
                    onSelectFilter: selectFilter,
                    onSelectSort: selectSort
                )
            }
        }
        .sheet(isPresented: $isBookFilterPresented) {
            DailyReadingBookFilterSheet(
                books: viewModel.books,
                selectedBookID: viewModel.selectedBookID,
                onSelectBook: selectBook
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $isCheckInPresented) {
            ReadCalendarCheckInSheet(
                date: viewModel.date,
                initialBook: viewModel.checkInInitialBook,
                isSaving: viewModel.isWriting,
                onSave: { bookID, amount in
                    try await viewModel.saveCheckIn(
                        recordID: nil,
                        bookID: bookID,
                        amount: amount,
                        using: repositories.readCalendarRepository
                    )
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $editingRecord) { record in
            editSheet(for: record)
        }
        .sheet(item: $tagEditSession) { session in
            NoteReviewTagEditSheet(
                snapshot: session.snapshot,
                onCreateTag: { name in
                    try await viewModel.createTag(named: name, using: repositories.noteRepository)
                },
                onTagCatalogMutation: viewModel.applyTagCatalogMutation,
                onSave: { tags in
                    await viewModel.replaceTags(tags, for: session.item, using: repositories.noteRepository)
                }
            )
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
        .sheet(item: $relatedBookDraft) { draft in
            RelatedBookRelationEditorSheet(
                draft: draft,
                isSaving: viewModel.isWriting,
                onSave: { value in
                    try await repositories.contentRepository.saveRelatedBookRelationDraft(value)
                    await viewModel.reload(using: repositories.readCalendarRepository)
                }
            )
        }
        .sheet(item: $generatedShareFile, onDismiss: discardGeneratedShareFile) { file in
            XMActivityShareSheet(activityItems: [file.fileURL])
                .presentationDetents([.medium, .large])
        }
        .xmSystemAlert(item: $pendingDelete) { record in
            deleteDescriptor(for: record)
        }
        .xmToastHost(center: toastCenter)
        .task {
            syncLoadingGate()
            await viewModel.loadIfNeeded(using: repositories.readCalendarRepository)
            syncLoadingGate()
        }
        .task(id: observationRevision) {
            await viewModel.observeChanges(using: repositories.readCalendarRepository)
        }
        .task(id: viewModel.noteContextSignature) {
            await viewModel.reloadActionContexts(
                noteRepository: repositories.noteRepository,
                externalRepository: repositories.externalAppIntegrationRepository
            )
        }
        .onChange(of: viewModel.loadPhase) { _, _ in
            syncLoadingGate()
        }
        .onDisappear {
            viewModel.cancel()
            loadingGate.hideImmediately()
            discardGeneratedShareFile()
        }
    }

    @ViewBuilder
    private var content: some View {
        switch viewModel.loadPhase {
        case .idle:
            if loadingGate.isVisible {
                LoadingStateView("正在加载阅读轨迹…", style: .card)
            } else {
                Color.clear
            }
        case .loading where !viewModel.hasAnyData:
            if loadingGate.isVisible {
                LoadingStateView("正在加载阅读轨迹…", style: .card)
            } else {
                Color.clear
            }
        case .failed where !viewModel.hasAnyData:
            failureState
        default:
            loadedContent
        }
    }

    @ViewBuilder
    private var loadedContent: some View {
        if !viewModel.hasAnyData {
            loadedSurface(emptyState)
        } else if viewModel.records.isEmpty {
            loadedSurface(filteredEmptyState)
        } else {
            loadedSurface(recordScrollView)
        }
    }

    private var recordScrollView: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Spacing.none) {
                DailyReadingRecordSection(
                    records: viewModel.records,
                    noteActionItems: viewModel.noteActionItems,
                    configuredExternalDestinations: viewModel.configuredExternalDestinations,
                    onOpenContent: openContent,
                    onOpenBook: openBook,
                    onAction: handle
                )
            }
            .padding(.horizontal, Spacing.screenEdge)
            .padding(.top, Spacing.base)
            .padding(.bottom, Spacing.double)
        }
        .safeAreaPadding(.bottom, Spacing.base)
        .scrollBounceBehavior(.always)
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
    }

    /// 为各内容状态统一接入固定告警与增量加载反馈，并保持记录列表作为系统可识别的主滚动主体。
    private func loadedSurface<Content: View>(_ content: Content) -> some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .safeAreaBar(edge: .top, spacing: Spacing.none) {
                if let observationErrorMessage = viewModel.observationErrorMessage {
                    ReadCalendarInlineErrorBanner(
                        message: observationErrorMessage,
                        onRetry: retryObservation
                    )
                    .padding(.horizontal, Spacing.screenEdge)
                }
            }
            .overlay(alignment: .top) {
                if viewModel.loadPhase == .loading, viewModel.hasAnyData {
                    Rectangle()
                        .fill(Color.textSecondary)
                        .frame(height: 2)
                        .transition(.opacity)
                }
            }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("当天还没有阅读轨迹", systemImage: "calendar.badge.clock")
        } description: {
            Text("添加阅读打卡后，记录会按发生时间出现在这里。")
        } actions: {
            Button(viewModel.checkInActionTitle) {
                isCheckInPresented = true
            }
            .buttonStyle(.bordered)
            .disabled(!viewModel.canCheckIn || viewModel.isWriting)
        }
        .frame(maxHeight: .infinity)
    }

    private var filteredEmptyState: some View {
        ContentUnavailableView {
            Label("没有符合条件的记录", systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            Text("可以切换书籍或记录类型，查看当天的其他阅读轨迹。")
        } actions: {
            if viewModel.hasActiveFilter {
                Button("显示全部记录") {
                    Task {
                        await viewModel.clearFilters(using: repositories.readCalendarRepository)
                    }
                }
                .buttonStyle(.bordered)
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var failureState: some View {
        ContentUnavailableView {
            Label("无法加载阅读轨迹", systemImage: "exclamationmark.triangle")
        } description: {
            Text(viewModel.errorMessage ?? "请稍后重试")
        } actions: {
            Button("重试") {
                Task { await viewModel.reload(using: repositories.readCalendarRepository) }
            }
            .buttonStyle(.bordered)
        }
    }

    /// 切换书籍时立即更新选中态，并让 ViewModel 取消旧查询后读取新轨迹。
    private func selectBook(_ bookID: Int64?) {
        Task {
            await viewModel.selectBook(bookID, using: repositories.readCalendarRepository)
        }
    }

    /// 切换记录类型时保留当前书籍和排序方向。
    private func selectFilter(_ filter: DailyReadingTimelineFilter) {
        Task {
            await viewModel.selectFilter(filter, using: repositories.readCalendarRepository)
        }
    }

    /// 切换排序方向时保留当前书籍和记录类型。
    private func selectSort(_ sortOrder: DailyReadingSortOrder) {
        Task {
            await viewModel.selectSort(sortOrder, using: repositories.readCalendarRepository)
        }
    }

    /// 仅重建自动刷新监听；已有轨迹和主读取阶段保持不变。
    private func retryObservation() {
        viewModel.prepareObservationRetry()
        observationRevision &+= 1
    }

    /// 以书籍详情路由打开记录所属书籍。
    private func openBook(_ bookID: Int64) {
        onOpenBookRoute(.detail(bookId: bookID))
    }

    @ViewBuilder
    private func editSheet(for record: DailyReadingRecord) -> some View {
        if let recordID = record.recordID,
           let book = viewModel.bookSummary(for: record.event.sourceBookId)?.book {
            switch record.event.kind {
            case .checkIn(let event):
                ReadCalendarCheckInSheet(
                    date: viewModel.date,
                    recordID: recordID,
                    initialBook: book,
                    initialAmount: Int(event.amount),
                    isSaving: viewModel.isWriting,
                    onSave: { bookID, amount in
                        try await viewModel.saveCheckIn(
                            recordID: recordID,
                            bookID: bookID,
                            amount: amount,
                            using: repositories.readCalendarRepository
                        )
                    }
                )
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
            case .readTiming(let event):
                ReadCalendarTimingEditorSheet(
                    recordID: recordID,
                    initialBook: book,
                    event: event,
                    isSaving: viewModel.isWriting,
                    onSave: { draft in
                        try await viewModel.updateTiming(draft, using: repositories.readCalendarRepository)
                    }
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
            default:
                EmptyView()
            }
        } else {
            EmptyView()
        }
    }

    /// 内容事件进入既有编辑页；计时与打卡使用当前页面的业务 Sheet。
    private func edit(_ record: DailyReadingRecord) {
        switch record.event.kind {
        case .note(let note):
            navigationCoordinator.present(.noteEditor(mode: .edit(noteId: note.noteId), seed: nil))
        case .review(let review):
            navigationCoordinator.present(.reviewEditor(.edit(reviewID: review.reviewId)))
        case .relevant(let relevant):
            navigationCoordinator.present(.relevantEditor(.edit(contentID: relevant.contentId)))
        case .readTiming, .checkIn:
            guard record.recordID != nil else { return }
            editingRecord = record
        case .relevantBook, .readStatus:
            break
        }
    }

    /// 内容卡片进入通用查看器，范围限定为当前自然日与所选内容类型。
    private func openContent(_ itemID: ContentViewerItemID) {
        let start = Int64(viewModel.date.timeIntervalSince1970 * 1_000)
        let next = Calendar.current.date(byAdding: .day, value: 1, to: viewModel.date)
            ?? viewModel.date.addingTimeInterval(86_400)
        let end = Int64(next.timeIntervalSince1970 * 1_000) - 1
        let filter: TimelineContentFilter
        switch itemID {
        case .note: filter = .note
        case .review: filter = .review
        case .relevant: filter = .relevant
        }
        navigationCoordinator.present(
            .contentViewer(
                source: .timeline(startTimestamp: start, endTimestamp: end, filter: filter),
                initialItemID: itemID,
                keyword: ""
            )
        )
    }

    /// 复制记录文本并通过剪贴板状态变化表达完成，不额外弹成功提示。
    private func copy(_ text: String) {
#if canImport(UIKit)
        UIPasteboard.general.string = text
#endif
    }

    /// 将记录行菜单动作映射为导航、系统能力或 Repository 写入。
    private func handle(_ action: DailyReadingRecordAction, _ record: DailyReadingRecord) {
        switch action {
        case .edit:
            edit(record)
        case .editTags(let item):
            Task { await openTagEditor(for: item) }
        case .copy(let text):
            copy(text)
        case .openWeRead(let url):
            openURL(url) { accepted in
                if !accepted { toastCenter.warning("无法打开微信读书原文") }
            }
        case .shareNoteImage(let item):
            Task { await generateShareImage(for: item) }
        case .sendNote(let item, let destination):
            Task { await send(item, to: destination) }
        case .editRelatedBook:
            guard let recordID = record.recordID else { return }
            Task { await openRelatedBookEditor(recordID: recordID) }
        case .delete:
            guard record.recordID != nil else { return }
            pendingDelete = record
        }
    }

    /// 读取标签编辑所需快照；失败时保留当前轨迹并给出错误反馈。
    private func openTagEditor(for item: NoteReviewCardItem) async {
        do {
            let snapshot = try await repositories.noteRepository.fetchNoteReviewTagEditSnapshot(noteID: item.id)
            tagEditSession = DailyReadingTagEditSession(item: item, snapshot: snapshot)
        } catch {
            toastCenter.error("标签加载失败：\(error.localizedDescription)")
        }
    }

    /// 读取相关书籍关系草稿；读取任务随页面 Task 取消，不直接访问数据库。
    private func openRelatedBookEditor(recordID: Int64) async {
        do {
            relatedBookDraft = try await repositories.contentRepository.fetchRelatedBookRelationDraft(relationID: recordID)
            if relatedBookDraft == nil { toastCenter.warning("关联书籍已不存在") }
        } catch {
            toastCenter.error("关联信息加载失败：\(error.localizedDescription)")
        }
    }

    /// 复用书摘回顾渲染器生成分享卡片，网络背景失败时自动退回无背景版本。
    private func generateShareImage(for item: NoteReviewCardItem) async {
        do {
            discardGeneratedShareFile()
            let settings = repositories.noteRepository.fetchNoteReviewSettings()
            let backgroundData: Data?
            if settings.backgroundMode == .image,
               let rawURL = settings.backgroundImageURL,
               let url = URL(string: rawURL) {
                backgroundData = try? await repositories.noteRepository.fetchNoteReviewBackgroundData(remoteURL: url)
            } else {
                backgroundData = nil
            }
            generatedShareFile = try await NoteReviewShareImageRenderer().renderPNG(
                for: item,
                settings: settings,
                isDarkAppearance: colorScheme == .dark,
                backgroundImageData: backgroundData
            )
        } catch {
            toastCenter.error("生成分享卡片失败：\(error.localizedDescription)")
        }
    }

    /// 发送书摘到外部应用；ViewModel 在主 Actor 上阻止重复提交并暴露写入状态。
    private func send(_ item: NoteReviewCardItem, to destination: ExternalAppDestination) async {
        do {
            try await viewModel.sendNote(
                item,
                to: destination,
                using: repositories.externalAppIntegrationRepository
            )
            toastCenter.success("已发送到 \(destination.displayName)")
        } catch {
            toastCenter.error("发送到 \(destination.displayName) 失败：\(error.localizedDescription)")
        }
    }

    /// 删除临时分享文件；不存在文件时保持幂等。
    private func discardGeneratedShareFile() {
        guard let generatedShareFile else { return }
        try? FileManager.default.removeItem(at: generatedShareFile.fileURL)
        self.generatedShareFile = nil
    }

    /// 按记录类型构建删除确认弹窗；具体物理/软删除语义由 Android 对齐的 Repository 负责。
    private func deleteDescriptor(for record: DailyReadingRecord) -> XMSystemAlertDescriptor {
        XMSystemAlertDescriptor(
            title: "删除这条记录？",
            message: "删除后将从当天阅读轨迹中移除。",
            actions: [
                XMSystemAlertAction(title: "取消", role: .cancel) { },
                XMSystemAlertAction(title: "删除", role: .destructive) {
                    Task { await delete(record) }
                }
            ]
        )
    }

    /// 执行删除并在失败时展示错误；成功通过列表与书籍筛选项收缩表达。
    private func delete(_ record: DailyReadingRecord) async {
        do {
            try await viewModel.delete(
                record,
                readCalendarRepository: repositories.readCalendarRepository,
                contentRepository: repositories.contentRepository
            )
        } catch {
            toastCenter.error("删除失败：\(error.localizedDescription)")
        }
    }

    /// 将读取阶段接入延迟显示和最短驻留门闩，避免短请求闪烁。
    private func syncLoadingGate() {
        loadingGate.update(intent: viewModel.loadPhase == .loading ? .read : .none)
    }
}

/// 当日完整轨迹记录段；精确事件与按补录时刻映射的模糊计时共享同一时间轴。
private struct DailyReadingRecordSection: View {
    let records: [DailyReadingRecord]
    let noteActionItems: [Int64: NoteReviewCardItem]
    let configuredExternalDestinations: Set<ExternalAppDestination>
    let onOpenContent: (ContentViewerItemID) -> Void
    let onOpenBook: (Int64) -> Void
    let onAction: (DailyReadingRecordAction, DailyReadingRecord) -> Void

    var body: some View {
        if !records.isEmpty {
            ForEach(records.enumerated(), id: \.element.id) { index, record in
                DailyReadingRecordRow(
                    record: record,
                    isLast: index == records.count - 1,
                    noteActionItem: noteActionItem(for: record),
                    configuredExternalDestinations: configuredExternalDestinations,
                    onOpenContent: onOpenContent,
                    onOpenBook: onOpenBook,
                    onAction: { action in onAction(action, record) }
                )
            }
        }
    }

    /// 返回书摘记录对应的批量操作上下文，其他记录无需额外数据。
    private func noteActionItem(for record: DailyReadingRecord) -> NoteReviewCardItem? {
        guard case .note(let note) = record.event.kind else { return nil }
        return noteActionItems[note.noteId]
    }

}

/// 书摘标签编辑会话，以书摘主键维持 Sheet 稳定身份。
private struct DailyReadingTagEditSession: Identifiable {
    let item: NoteReviewCardItem
    let snapshot: NoteReviewTagEditSnapshot
    var id: Int64 { item.id }
}
