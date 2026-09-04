/**
 * [INPUT]: 依赖 AppNavigationCoordinator、DataImportCollectionView、系统 scrollEdgeEffectStyle、微信读书导入 ViewModel、全屏 WebView、浮动操作面板、BookPickerView、Photos 与统一反馈组件
 * [OUTPUT]: 对外提供支持系统上下滚动边缘过渡、分组/组内排序的书摘导入入口、非模态授权面板、分批、WereadImportBatchStatusView、导入预览和单书内容预览页面
 * [POS]: Views/Personal/DataImport 的完整微信读书扫码授权导入交互流
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import Photos
import SwiftUI
import UIKit

struct DataImportView: View {
    @Environment(AppNavigationCoordinator.self) private var navigationCoordinator
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var groups: [DataImportGroup]
    @State private var isEditing = false

    init() {
        _groups = State(initialValue: DataImportOrderingStore.loadGroups())
    }

    var body: some View {
        DataImportCollectionView(
            groups: groups,
            isEditing: isEditing,
            reducesMotion: accessibilityReduceMotion,
            onOpen: openImportTask,
            onCommitGroupOrder: commitGroupOrder,
            onCommitEntryOrder: commitEntryOrder
        )
        .background(Color.surfacePage)
        .ignoresSafeArea(.container, edges: [.top, .bottom])
        .scrollEdgeEffectStyle(.soft, for: [.top, .bottom])
        .navigationTitle("书摘导入")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isEditing ? "完成" : "编辑", action: toggleEditing)
                    .xmToolbarNeutralTint()
            }
        }
    }

    /// 在不改变当前 Tab 浏览栈的前提下启动独立导入任务。
    private func openImportTask(_ destination: DataImportTaskDestination) {
        guard !isEditing else { return }
        navigationCoordinator.present(.dataImport(destination))
    }

    /// 切换目录编辑状态；实际拖拽过程与收起动画由 UIKit 列表 owner 管理。
    private func toggleEditing() {
        isEditing.toggle()
    }

    /// 提交分组最终顺序并立即持久化；所有子项仍随各自分组保持原有顺序。
    private func commitGroupOrder(_ orderedIDs: [DataImportGroupID]) {
        let groupByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        let reorderedGroups = orderedIDs.compactMap { groupByID[$0] }
        guard reorderedGroups.count == groups.count, reorderedGroups.map(\.id) != groups.map(\.id) else {
            return
        }
        groups = reorderedGroups
        DataImportOrderingStore.saveGroupOrder(orderedIDs)
    }

    /// 提交单个分组的条目顺序，拒绝跨组或缺失条目的非完整结果。
    private func commitEntryOrder(_ groupID: DataImportGroupID, orderedEntryIDs: [String]) {
        guard let groupIndex = groups.firstIndex(where: { $0.id == groupID }) else { return }
        let entries = groups[groupIndex].entries
        let entryByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let reorderedEntries = orderedEntryIDs.compactMap { entryByID[$0] }
        guard reorderedEntries.count == entries.count,
              reorderedEntries.map(\.id) != entries.map(\.id) else {
            return
        }
        groups[groupIndex].entries = reorderedEntries
        DataImportOrderingStore.saveEntryOrder(reorderedEntries.map(\.id), for: groupID)
    }
}

struct WereadImportAuthView: View {
    @Environment(AppState.self) private var appState
    @Environment(XMToastCenter.self) private var toastCenter
    @State private var viewModel: WereadImportAuthViewModel
    @State private var showsError = false
    @State private var showsPremium = false
    @State private var showsBackfillPrompt = false
    @State private var isActionPanelPresented = true
    @State private var selectedActionPanelDetent = WereadImportActionPanel.expandedDetent
    @State private var activeDestination: WereadImportAuthViewModel.Destination?
    @State private var isSavingQRCode = false
    @State private var qrCodeSaveTask: Task<Void, Never>?
    let onOpenPremium: () -> Void

    init(repository: any WereadImportRepositoryProtocol, onOpenPremium: @escaping () -> Void) {
        _viewModel = State(initialValue: WereadImportAuthViewModel(repository: repository)); self.onOpenPremium = onOpenPremium
    }

    var body: some View {
        GeometryReader { geometry in
            authorizationContent(bottomSafeAreaInset: geometry.safeAreaInsets.bottom)
        }
    }

    /// 以页面真实安全区作为 Sheet 折叠基准，避免把 Home Indicator 留白误算为内容位移。
    private func authorizationContent(bottomSafeAreaInset: CGFloat) -> some View {
        WereadAuthorizationWebView(
            reloadToken: viewModel.webReloadToken,
            onQRCode: viewModel.receiveQRCode,
            onCookie: viewModel.receiveCookie,
            onExpired: viewModel.markExpired,
            onFailed: viewModel.markFailed
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea(.container, edges: .bottom)
        .background(Color.surfacePage)
        .navigationTitle("微信读书导入")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("刷新授权页面", systemImage: "arrow.clockwise", action: refresh)
                    .labelStyle(.iconOnly)
                    .xmToolbarNeutralTint()
                    .disabled(viewModel.isWorking || isSavingQRCode)
            }
        }
        .sheet(isPresented: $isActionPanelPresented, onDismiss: actionPanelDidDismiss) {
            actionPanel(bottomSafeAreaInset: bottomSafeAreaInset)
                .presentationDetents(
                    WereadImportActionPanel.detents,
                    selection: $selectedActionPanelDetent
                )
                .presentationDragIndicator(.visible)
                .presentationBackgroundInteraction(.enabled)
                .presentationContentInteraction(.scrolls)
                .interactiveDismissDisabled()
        }
        .task { await viewModel.load() }
        .onDisappear(perform: cancelTasks)
        .onChange(of: viewModel.errorMessage) { _, value in showsError = value != nil }
        .onChange(of: viewModel.backfillPrompt) { _, prompt in showsBackfillPrompt = prompt != nil }
        .onChange(of: viewModel.destination) { _, destination in
            guard destination != nil else { return }
            isActionPanelPresented = false
        }
        .onChange(of: activeDestination) { _, destination in
            guard destination == nil, viewModel.destination == nil else { return }
            selectedActionPanelDetent = WereadImportActionPanel.expandedDetent
            isActionPanelPresented = true
        }
        .navigationDestination(item: $activeDestination) { destination in
            switch destination {
            case .batches(let route): WereadBatchView(route: route)
            case .preview(let route): WereadImportPreviewView(route: route)
            }
        }
        .xmSystemAlert(isPresented: $showsError, descriptor: errorDescriptor)
        .xmSystemAlert(isPresented: $showsPremium, descriptor: premiumDescriptor)
        .xmSystemAlert(isPresented: $showsBackfillPrompt, descriptor: backfillDescriptor)
    }

    private var phaseIsLoading: Bool { if case .loading = viewModel.phase { return true }; return false }

    private func actionPanel(bottomSafeAreaInset: CGFloat) -> some View {
        WereadImportActionPanel(
            selectedDetent: $selectedActionPanelDetent,
            bottomSafeAreaInset: bottomSafeAreaInset,
            recentBookCount: viewModel.preferences.recentBookCount,
            importsReadingTime: viewModel.preferences.importsReadingTime,
            onlyBooksWithNotes: viewModel.preferences.onlyBooksWithNotes,
            primaryTitle: primaryTitle,
            showsPrimaryProgress: showsPrimaryProgress,
            isPrimaryDisabled: isSavingQRCode || viewModel.isWorking || phaseIsLoading,
            areSettingsDisabled: viewModel.isWorking,
            onRecentBookCountChange: { value in
                viewModel.updatePreferences { $0.recentBookCount = value }
            },
            onImportsReadingTimeChange: { value in
                viewModel.updatePreferences { $0.importsReadingTime = value }
            },
            onOnlyBooksWithNotesChange: { value in
                viewModel.updatePreferences { $0.onlyBooksWithNotes = value }
            },
            onPrimaryAction: primaryAction
        )
    }

    private var primaryTitle: String {
        if isSavingQRCode { return "正在保存二维码…" }
        if viewModel.isWorking {
            switch viewModel.workKind {
            case .backfill:
                return viewModel.backfillProgressText.isEmpty
                    ? "正在关联历史数据…"
                    : viewModel.backfillProgressText
            case .candidateFetch, nil:
                return viewModel.progressText.isEmpty
                    ? "正在获取候选书籍…"
                    : viewModel.progressText
            }
        }
        switch viewModel.phase {
        case .loading: return "正在加载二维码…"
        case .available: return "保存二维码到相册"
        case .expired: return "刷新二维码"
        case .failed: return "重新加载"
        case .authorized: return "获取候选书籍"
        }
    }

    private var showsPrimaryProgress: Bool {
        isSavingQRCode || viewModel.isWorking || phaseIsLoading
    }

    private func primaryAction() {
        switch viewModel.phase {
        case .available: saveQRCode()
        case .expired, .failed: refresh()
        case .authorized:
            guard appState.isPremium else { showsPremium = true; return }
            viewModel.beginCandidateFetch()
        case .loading: break
        }
    }

    private func refresh() { viewModel.beginRefresh() }

    private func saveQRCode() {
        guard !isSavingQRCode,
              let data = viewModel.qrCodeData,
              let image = UIImage(data: data) else {
            toastCenter.error("二维码保存失败")
            return
        }
        isSavingQRCode = true
        qrCodeSaveTask?.cancel()
        qrCodeSaveTask = Task { @MainActor in
            defer {
                isSavingQRCode = false
                qrCodeSaveTask = nil
            }
            let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
            guard !Task.isCancelled else { return }
            guard status == .authorized || status == .limited else { toastCenter.error(WereadImportError.photoPermissionDenied.localizedDescription); return }
            let size = CGSize(width: image.size.width + 100, height: image.size.height + 100)
            let renderer = UIGraphicsImageRenderer(size: size)
            let padded = renderer.image { context in UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size)); image.draw(at: CGPoint(x: 50, y: 50)) }
            guard !Task.isCancelled else { return }
            do { try await PHPhotoLibrary.shared().performChanges { PHAssetChangeRequest.creationRequestForAsset(from: padded) }; toastCenter.success("二维码已保存到照片") }
            catch { toastCenter.error("二维码保存失败：\(error.localizedDescription)") }
        }
    }

    /// Sheet 完成程序化收起后再提交导航，避免呈现层与 push 同时竞争。
    private func actionPanelDidDismiss() {
        guard let destination = viewModel.destination else { return }
        viewModel.destination = nil
        activeDestination = destination
    }

    /// 页面离开时同时取消 ViewModel 与照片写入任务，阻止过期状态回写当前界面。
    private func cancelTasks() {
        qrCodeSaveTask?.cancel()
        qrCodeSaveTask = nil
        isSavingQRCode = false
        viewModel.cancel()
    }

    private var errorDescriptor: XMSystemAlertDescriptor? {
        guard let message = viewModel.errorMessage else { return nil }
        return .init(
            title: errorTitle,
            message: message,
            actions: [.init(title: "知道了") { viewModel.clearError() }]
        )
    }
    private var errorTitle: String {
        switch viewModel.errorContext {
        case .authorization: "授权失败"
        case .candidateFetch: "获取候选书籍失败"
        case .backfill: "历史数据关联失败"
        case nil: "操作失败"
        }
    }
    private var premiumDescriptor: XMSystemAlertDescriptor { .init(title: "会员功能", message: "微信读书授权导入是会员功能。", actions: [.init(title: "取消", role: .cancel) {}, .init(title: "升级会员") { onOpenPremium() }]) }
    private var backfillDescriptor: XMSystemAlertDescriptor? {
        guard let prompt = viewModel.backfillPrompt else { return nil }
        return .init(title: "关联历史微信数据", message: "发现 \(prompt.pendingCount) 本历史导入书籍缺少微信关联信息，是否现在补全？", actions: [.init(title: "稍后", role: .cancel) { viewModel.postponeBackfill() }, .init(title: "开始") { viewModel.beginBackfill() }])
    }
}

private struct WereadBatchView: View {
    @State private var viewModel: WereadBatchViewModel
    @State private var showsError = false
    init(route: WereadBatchRoute) { _viewModel = State(initialValue: WereadBatchViewModel(route: route)) }

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: Spacing.half) {
                    Text("共 \(viewModel.batches.reduce(0) { $0 + $1.bookIDs.count }) 本书，分为 \(viewModel.batches.count) 批").font(AppTypography.headline)
                    ProgressView(value: Double(viewModel.completedPercent), total: 100)
                    Text("已完成 \(viewModel.completedPercent)% · 每批最多 100 本，完成度按已成功加载批次计算").font(AppTypography.caption).foregroundStyle(Color.textSecondary)
                }.padding(.vertical, Spacing.half)
            }
            Section {
                ForEach(viewModel.batches) { batch in
                    Button { viewModel.beginOpen(batch.id) } label: {
                        HStack {
                            VStack(alignment: .leading) { Text("第 \(batch.number) 批"); Text("第 \(batch.start)–\(batch.end) 本").font(AppTypography.caption).foregroundStyle(Color.textSecondary) }
                            Spacer(); WereadImportBatchStatusView(status: batch.status)
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.isLoading && { if case .loading = batch.status { return false }; return true }())
                }
            }
        }
        .navigationTitle("分批导入")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(item: $viewModel.preview) { WereadImportPreviewView(route: $0) }
        .onDisappear { viewModel.cancel() }
        .onChange(of: viewModel.errorMessage) { _, value in showsError = value != nil }
        .xmSystemAlert(isPresented: $showsError, descriptor: viewModel.errorMessage.map { message in .init(title: "本批加载失败", message: message, actions: [.init(title: "知道了") { viewModel.errorMessage = nil }]) })
    }

}

/// 微信读书分批导入的确定进度与结果状态，保持批次语义而不并入通用页面状态角色。
struct WereadImportBatchStatusView: View {
    let status: WereadImportBatchStatus

    @ViewBuilder
    var body: some View {
        switch status {
        case .notStarted:
            Text("未开始")
                .font(AppTypography.subheadline)
                .foregroundStyle(Color.textSecondary)
        case .loading(let percent):
            ProgressView(value: Double(percent), total: 100)
                .controlSize(.small)
                .tint(Color.appTint)
                .frame(width: 72)
                .accessibilityLabel("本批导入进度")
                .accessibilityValue("\(percent)%")
        case .failed:
            Text("重试")
                .font(AppTypography.subheadline)
                .foregroundStyle(Color.feedbackError)
        case .success:
            Image(systemName: "checkmark.circle")
                .font(.system(size: 16, weight: .regular))
                .foregroundStyle(Color.feedbackSuccess)
                .accessibilityLabel("已完成")
        }
    }
}

private struct WereadImportPreviewView: View {
    @Environment(AppNavigationCoordinator.self) private var navigationCoordinator
    @State private var viewModel: WereadPreviewViewModel
    @State private var contentBook: WereadImportBook?
    @State private var mappingBook: WereadImportBook?
    @State private var editingBook: WereadImportBook?
    @State private var editTitle = ""
    @State private var editAuthor = ""
    @State private var showsError = false

    init(route: WereadPreviewRoute) { _viewModel = State(initialValue: WereadPreviewViewModel(route: route)) }

    var body: some View {
        List {
            Section {
                HStack { Button("全选") { viewModel.selectAll(true) }; Spacer(); Button("取消全选") { viewModel.selectAll(false) } }
            }
            ForEach(viewModel.visibleBooks) { book in
                bookSection(book)
            }
        }
        .searchable(text: $viewModel.query, prompt: "搜索书名或作者")
        .scrollDismissesKeyboard(.immediately)
        .navigationTitle("导入预览")
        .navigationBarTitleDisplayMode(.inline)
        .safeAreaInset(edge: .bottom) {
            Button { viewModel.beginCommit() } label: { HStack { Spacer(); if viewModel.isCommitting { ProgressView().controlSize(.small) }; Text(viewModel.isCommitting ? viewModel.progressText : "导入（\(viewModel.selectedCount)/\(viewModel.books.count)）"); Spacer() } }
                .buttonStyle(.borderedProminent).padding(Spacing.screenEdge).background(.ultraThinMaterial).disabled(viewModel.isCommitting)
        }
        .navigationDestination(item: $contentBook) { book in WereadBookContentPreviewView(book: binding(for: book.id)) }
        .sheet(item: $mappingBook) { book in
            BookPickerView(configuration: .init(title: "映射到已有书籍", scope: .local, selectionMode: .single, defaultQuery: book.title)) { result in
                if case .single(.local(let selected)) = result { viewModel.map(book.id, to: selected) }
                mappingBook = nil
            }
        }
        .onChange(of: viewModel.errorMessage) { _, value in showsError = value != nil }
        .onChange(of: viewModel.didCommit) { _, done in
            if done {
                navigationCoordinator.dismissTask()
            }
        }
        .onDisappear { viewModel.cancel() }
        .xmSystemAlert(isPresented: $showsError, descriptor: viewModel.errorMessage.map { message in .init(title: "无法导入", message: message, actions: [.init(title: "知道了") { viewModel.errorMessage = nil }]) })
        .xmSystemAlert(item: $editingBook) { book in
            .init(title: "编辑新书资料", actions: [.init(title: "取消", role: .cancel) {}, .init(title: "保存", isEnabled: !editTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) { var updated = book; updated.title = editTitle.trimmingCharacters(in: .whitespacesAndNewlines); updated.rawTitle = updated.title; updated.author = editAuthor.trimmingCharacters(in: .whitespacesAndNewlines); viewModel.updateBook(updated) }], textFields: [.init(text: $editTitle, placeholder: "书名"), .init(text: $editAuthor, placeholder: "作者")])
        }
    }

    private func binding(for id: UUID) -> Binding<WereadImportBook> { Binding(get: { viewModel.books.first { $0.id == id }! }, set: viewModel.updateBook) }

    /// 打开含书摘或书评的单书预览；空内容保持无操作。
    private func openBookContentIfAvailable(_ book: WereadImportBook) {
        guard book.hasBrowsableContent else { return }
        contentBook = book
    }

    /// 进入未映射书籍的信息编辑态，已映射书籍保持原有阻断语义。
    private func beginEditing(_ book: WereadImportBook) {
        guard book.targetBookID == nil else { return }
        editingBook = book
        editTitle = book.title
        editAuthor = book.author
    }

    @ViewBuilder
    private func bookSection(_ book: WereadImportBook) -> some View {
        Section {
            HStack(alignment: .top, spacing: Spacing.base) {
                selectionButton(book)
                XMBookCover.fixedWidth(
                    48,
                    urlString: book.coverURL,
                    cornerRadius: CornerRadius.inlaySmall,
                    placeholderIconSize: .small
                )
                VStack(alignment: .leading, spacing: Spacing.compact) {
                    Text(book.title).font(AppTypography.headline)
                    Text(book.author).font(AppTypography.caption).foregroundStyle(Color.textSecondary)
                    Text(summaryText(for: book)).font(AppTypography.caption).foregroundStyle(Color.textSecondary)
                    if let target = book.targetBookTitle { Text("导入到：\(target)").font(AppTypography.caption).foregroundStyle(Color.selectionAccent) }
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture {
                openBookContentIfAvailable(book)
            }
            .onLongPressGesture {
                beginEditing(book)
            }
            .accessibilityActions {
                if book.hasBrowsableContent {
                    Button("预览导入内容") {
                        openBookContentIfAvailable(book)
                    }
                }
                if book.targetBookID == nil {
                    Button("编辑书籍信息") {
                        beginEditing(book)
                    }
                }
            }
            HStack {
                Button(book.targetBookID == nil ? "映射已有书籍" : "更换映射") { mappingBook = book }
                if book.targetBookID != nil { Spacer(); Button("清除映射", role: .destructive) { viewModel.map(book.id, to: nil) } }
            }
        }
    }

    private func selectionButton(_ book: WereadImportBook) -> some View {
        Button { viewModel.toggleBook(book.id) } label: {
            XMSelectionIndicator(
                style: .checkbox,
                isSelected: book.isSelected,
                font: AppTypography.title2,
                showsUnselectedBase: true
            )
            .frame(
                width: InteractionMetrics.minimumTouchTarget,
                height: InteractionMetrics.minimumTouchTarget
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(book.isSelected ? "取消选择《\(book.title)》" : "选择《\(book.title)》")
        .accessibilityAddTraits(book.isSelected ? .isSelected : [])
    }

    private func summaryText(for book: WereadImportBook) -> String {
        "\(book.readStatusID == 3 ? "已读完" : "阅读中") · \(book.notes.count) 条书摘 · \(book.reviews.count) 条书评"
    }
}

private struct WereadBookContentPreviewView: View {
    @Binding var book: WereadImportBook
    var body: some View {
        List {
            if !book.notes.isEmpty {
                Section { HStack { Button("全选") { selectNotes(true) }; Spacer(); Button("取消全选") { selectNotes(false) } } } header: { Text("书摘") }
                ForEach($book.notes) { $note in
                    HStack(alignment: .top) {
                        Button { note.isSelected.toggle() } label: {
                            XMSelectionIndicator(
                                style: .checkbox,
                                isSelected: note.isSelected,
                                font: AppTypography.title2,
                                showsUnselectedBase: true
                            )
                            .frame(
                                width: InteractionMetrics.minimumTouchTarget,
                                height: InteractionMetrics.minimumTouchTarget
                            )
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(note.isSelected ? "取消选择书摘" : "选择书摘")
                        .accessibilityAddTraits(note.isSelected ? .isSelected : [])

                        VStack(alignment: .leading) {
                            Text(note.content)
                            if !note.idea.isEmpty {
                                Text(note.idea)
                                    .font(AppTypography.caption)
                                    .foregroundStyle(Color.textSecondary)
                            }
                        }
                    }
                }
            }
            if !book.reviews.isEmpty { Section("书评（随书导入）") { ForEach(book.reviews) { review in VStack(alignment: .leading) { if !review.title.isEmpty { Text(review.title).font(AppTypography.headline) }; Text(review.content) } } } }
        }
        .navigationTitle(book.title)
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: book.notes.map(\.isSelected)) { _, values in book.isSelected = values.contains(true) || (!book.reviews.isEmpty && book.isSelected) }
    }
    private func selectNotes(_ selected: Bool) { book.notes.indices.forEach { book.notes[$0].isSelected = selected }; book.isSelected = selected || (!book.reviews.isEmpty && book.isSelected) }
}
