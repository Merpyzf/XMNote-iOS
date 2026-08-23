//
//  BookContainerView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/10.
//

/**
 * [INPUT]: 依赖 RepositoryContainer 注入仓储，依赖 BookCollectionImportRouter 承接外部书单导入，依赖 HomeSubtabScaffold 承载首页二级页硬切，依赖 BookViewModel 与 BookCollectionListViewModel 驱动书架浏览、书单列表、显示设置与顶部操作
 * [OUTPUT]: 对外提供 BookContainerView 与 BookSubTab 枚举，承载书籍/书单二级页切换、外部导入入口定位、顶部批量菜单、批量 Sheet、删除确认、书单入口与方案 A 规格的横向三点更多菜单
 * [POS]: Book 模块容器壳层，承载书籍页与书架管理模式编排
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

// MARK: - Sub Tab

/// 书籍页二级分栏，承载书架与书单两个首页入口。
enum BookSubTab: String, CaseIterable, Hashable, Codable {
    case books, collections

    static var allCases: [BookSubTab] { [.books, .collections] }

    var title: String {
        switch self {
        case .books: "书籍"
        case .collections: "书单"
        }
    }

    var productionValue: BookSubTab {
        self
    }
}

// MARK: - Container

/// 书籍模块入口容器，负责书籍页顶部工具入口与外层路由转发。
struct BookContainerView: View {
    @Environment(RepositoryContainer.self) private var repositories
    @Environment(SceneStateStore.self) private var sceneStateStore
    @Environment(BookCollectionImportRouter.self) private var importRouter
    @State private var viewModel: BookViewModel?
    @State private var selectedSubTab: BookSubTab = .books
    @State private var didBootstrapFromScene = false
    let onAddBook: () -> Void
    let onAddNote: () -> Void
    let onOpenDebugCenter: (() -> Void)?
    let onOpenBookRoute: (BookRoute) -> Void
    let onOpenNoteRoute: (NoteRoute) -> Void
    let onOpenTagManagement: () -> Void
    let onOpenSourceManagement: () -> Void
    let onOpenAuthorManagement: () -> Void
    let onOpenPressManagement: () -> Void
    let onOpenGuide: () -> Void

    /// 注入书籍页所需操作与路由回调，连接页内 chrome 与外层导航入口。
    init(
        onAddBook: @escaping () -> Void = {},
        onAddNote: @escaping () -> Void = {},
        onOpenDebugCenter: (() -> Void)? = nil,
        onOpenBookRoute: @escaping (BookRoute) -> Void = { _ in },
        onOpenNoteRoute: @escaping (NoteRoute) -> Void = { _ in },
        onOpenTagManagement: @escaping () -> Void = {},
        onOpenSourceManagement: @escaping () -> Void = {},
        onOpenAuthorManagement: @escaping () -> Void = {},
        onOpenPressManagement: @escaping () -> Void = {},
        onOpenGuide: @escaping () -> Void = {}
    ) {
        self.onAddBook = onAddBook
        self.onAddNote = onAddNote
        self.onOpenDebugCenter = onOpenDebugCenter
        self.onOpenBookRoute = onOpenBookRoute
        self.onOpenNoteRoute = onOpenNoteRoute
        self.onOpenTagManagement = onOpenTagManagement
        self.onOpenSourceManagement = onOpenSourceManagement
        self.onOpenAuthorManagement = onOpenAuthorManagement
        self.onOpenPressManagement = onOpenPressManagement
        self.onOpenGuide = onOpenGuide
    }

    var body: some View {
        Group {
            if let viewModel {
                BookContentView(
                    viewModel: viewModel,
                    selectedSubTab: $selectedSubTab,
                    onAddBook: onAddBook,
                    onAddNote: onAddNote,
                    onOpenDebugCenter: onOpenDebugCenter,
                    onOpenBookRoute: onOpenBookRoute,
                    onOpenNoteRoute: onOpenNoteRoute,
                    onOpenTagManagement: onOpenTagManagement,
                    onOpenSourceManagement: onOpenSourceManagement,
                    onOpenAuthorManagement: onOpenAuthorManagement,
                    onOpenPressManagement: onOpenPressManagement,
                    onOpenGuide: onOpenGuide
                )
            } else {
                Color.clear
            }
        }
        .task(id: sceneStateStore.isRestored) {
            guard sceneStateStore.isRestored else { return }
            guard !didBootstrapFromScene else { return }
            didBootstrapFromScene = true
            selectedSubTab = importRouter.pendingImport == nil
                ? sceneStateStore.snapshot.books.selectedSubTab.productionValue
                : .collections
            sceneStateStore.updateBookSelectedSubTab(selectedSubTab)
        }
        .task {
            guard viewModel == nil else { return }
            viewModel = BookViewModel(repository: repositories.bookRepository)
        }
        .onAppear {
            guard importRouter.pendingImport != nil else { return }
            selectedSubTab = .collections
        }
        .onChange(of: selectedSubTab) { _, newValue in
            let normalizedValue = newValue.productionValue
            guard normalizedValue == newValue else {
                selectedSubTab = normalizedValue
                return
            }
            sceneStateStore.updateBookSelectedSubTab(normalizedValue)
        }
        .onChange(of: importRouter.pendingImport) { _, request in
            guard request != nil else { return }
            selectedSubTab = .collections
        }
    }
}

// MARK: - Content View

private struct BookContentView: View {
    @Environment(RepositoryContainer.self) private var repositories
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Bindable var viewModel: BookViewModel
    @Binding var selectedSubTab: BookSubTab
    @State private var collectionViewModel: BookCollectionListViewModel?
    @State private var collectionEditMode: EditMode = .inactive
    @State private var showsDisplaySettingSheet = false
    @State private var showsCollectionDisplaySettingSheet = false
    @State private var editingPresentation = BookshelfEditingPresentationState()
    @State private var chromeTransitionTask: Task<Void, Never>?
    @State private var browseSearch = BookshelfSearchDrawerState()
    let onAddBook: () -> Void
    let onAddNote: () -> Void
    let onOpenDebugCenter: (() -> Void)?
    let onOpenBookRoute: (BookRoute) -> Void
    let onOpenNoteRoute: (NoteRoute) -> Void
    let onOpenTagManagement: () -> Void
    let onOpenSourceManagement: () -> Void
    let onOpenAuthorManagement: () -> Void
    let onOpenPressManagement: () -> Void
    let onOpenGuide: () -> Void

    private var chromePhase: BookshelfEditingChromePhase {
        get { editingPresentation.phase }
        nonmutating set { editingPresentation.phase = newValue }
    }

    private var isEditingChoreographyActive: Bool {
        get { editingPresentation.isChoreographyActive }
        nonmutating set { editingPresentation.isChoreographyActive = newValue }
    }

    private var browseSearchPresentation: BookshelfSearchDrawerPresentation {
        get { browseSearch.presentation }
        nonmutating set { browseSearch.presentation = newValue }
    }

    private var isBrowseSearchFocused: Bool {
        get { browseSearch.isFocused }
        nonmutating set { browseSearch.isFocused = newValue }
    }

    private var browseSearchDraftKeyword: String {
        get { browseSearch.draftKeyword }
        nonmutating set { browseSearch.draftKeyword = newValue }
    }

    private var browseSearchFocusTrigger: Int {
        get { browseSearch.focusTrigger }
        nonmutating set { browseSearch.focusTrigger = newValue }
    }

    var body: some View {
        HomeSubtabScaffold(
            selection: $selectedSubTab,
            tabs: BookSubTab.allCases,
            topBarHeight: topBarRowHeight,
            showsTopSwitcher: showsBrowsingChrome,
            showsHeaderGradient: showsBrowsingChrome,
            titleProvider: \.title
        ) { tab in
            topSwitcherTrailing(for: tab)
        } content: { tab in
            segmentedPage(for: tab)
        }
        .overlay(alignment: .top) {
            editHeaderOverlay
        }
        .sheet(isPresented: $showsDisplaySettingSheet) {
            BookshelfDisplaySettingSheet(
                dimension: viewModel.selectedDimension,
                scope: .main,
                setting: $viewModel.displaySetting
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
        }
        .sheet(isPresented: $showsCollectionDisplaySettingSheet) {
            if let collectionViewModel {
                BookCollectionDisplaySettingSheet(
                    setting: Binding(
                        get: { collectionViewModel.displaySetting },
                        set: { collectionViewModel.updateDisplaySetting($0) }
                    )
                )
                .presentationDetents([.large])
                .presentationDragIndicator(.hidden)
            }
        }
        .sheet(item: $viewModel.activeBatchSheet) { sheet in
            switch sheet {
            case .tags(
                options: let options,
                initialSelectedIDs: let initialSelectedIDs,
                allowsEmptySelection: let allowsEmptySelection,
                isLoading: let isLoading,
                errorMessage: let errorMessage
            ):
                BookshelfBatchTagsSheet(
                    options: options,
                    selectedCount: viewModel.selectedBookIDs.count,
                    initialSelectedIDs: initialSelectedIDs,
                    allowsEmptySelection: allowsEmptySelection,
                    isLoading: isLoading,
                    errorMessage: errorMessage,
                    onCreate: viewModel.createBatchTag(named:),
                    onConfirm: viewModel.submitBatchTags
                )
            case .source(options: let options, initialSelectedID: let initialSelectedID):
                BookshelfBatchSourceSheet(
                    options: options,
                    selectedCount: viewModel.selectedBookIDs.count,
                    initialSelectedID: initialSelectedID,
                    onCreate: viewModel.createBatchSource(named:),
                    onConfirm: viewModel.submitBatchSource
                )
            case .readStatus(
                options: let options,
                initialStatusID: let initialStatusID,
                initialChangedAt: let initialChangedAt,
                initialRatingScore: let initialRatingScore
            ):
                BookshelfBatchReadStatusSheet(
                    options: options,
                    selectedCount: viewModel.selectedBookIDs.count,
                    initialStatusID: initialStatusID,
                    initialChangedAt: initialChangedAt,
                    initialRatingScore: initialRatingScore,
                    onConfirm: viewModel.submitBatchReadStatus
                )
            case .moveGroup(
                options: let options,
                isLoading: let isLoading,
                errorMessage: let errorMessage
            ):
                BookshelfMoveGroupSheet(
                    options: options,
                    selectedCount: viewModel.selectedBookIDs.count,
                    isLoading: isLoading,
                    errorMessage: errorMessage,
                    onCreate: viewModel.createMoveTargetGroup(named:),
                    onConfirm: viewModel.submitMoveToGroup
                )
            case .bookCollection(
                options: let options,
                isLoading: let isLoading,
                errorMessage: let errorMessage
            ):
                BookshelfBookCollectionSheet(
                    options: options,
                    selectedCount: viewModel.selectedBookIDsIncludingGroupBooks.count,
                    isLoading: isLoading,
                    errorMessage: errorMessage,
                    onCreate: viewModel.createBookCollection(named:),
                    onConfirm: viewModel.submitBookCollection
                )
            }
        }
        .xmSystemAlert(item: $viewModel.activeDeleteConfirmation) { confirmation in
            defaultDeleteDescriptor(for: confirmation)
        }
        .task {
            guard collectionViewModel == nil else { return }
            let nextViewModel = BookCollectionListViewModel(repository: repositories.bookRepository)
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                collectionViewModel = nextViewModel
            }
        }
        .onAppear {
            syncChromePhaseWithEditingState()
        }
        .onChange(of: viewModel.isEditing) { _, _ in
            syncChromePhaseWithEditingState()
        }
        .onChange(of: selectedSubTab) { _, newValue in
            guard newValue != .books else { return }
            resetBookChromeForSubtabSwitch()
        }
        .onChange(of: viewModel.selectedDimension) { _, _ in
            collapseBrowseSearchIfUnsupported()
        }
        .onDisappear {
            resetEditingPresentationForContextLoss()
        }
    }

    @ViewBuilder
    private var editHeaderOverlay: some View {
        if showsEditHeader {
            VStack(spacing: Spacing.none) {
                BookshelfEditChrome(
                    selectedBookCount: viewModel.selectedBookIDs.count,
                    selectedGroupCount: viewModel.selectedGroupCount,
                    isAllVisibleSelected: viewModel.isAllVisibleSelected,
                    isSelectionToggleEnabled: !viewModel.visibleDefaultItemIDs.isEmpty,
                    searchState: editSearchState,
                    statusText: editStatusText,
                    onToggleSelectAll: toggleVisibleSelection,
                    onCancel: exitEditingWithChoreography
                ) {
                    editBatchMenu
                }
                .frame(height: topBarRowHeight)
            }
            .frame(height: topBarRowHeight, alignment: .top)
            .transition(BookshelfManagementMotion.topChromeTransition(reduceMotion: reduceMotion))
            .zIndex(2)
        }
    }

    private var editBatchMenu: some View {
        Menu {
            Section {
                Button(action: viewModel.pinSelectedItems) {
                    Label("置顶", systemImage: "pin")
                }
                .disabled(!viewModel.canSubmitSelectedPin || isEditBatchActionBusy)
            }

            Section {
                ForEach(viewModel.defaultBottomActions) { action in
                    Button {
                        viewModel.performBottomAction(action)
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                    }
                    .disabled(!isEditBatchActionEnabled(action))
                }
            }

            Section {
                Button(role: .destructive, action: viewModel.presentDeleteConfirmation) {
                    Label("删除", systemImage: "trash")
                }
                .disabled(!viewModel.canDeleteSelectedItems || isEditBatchActionBusy)
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .font(AppTypography.body)
                .foregroundStyle(Color.textPrimary)
                .frame(width: Spacing.actionReserved, height: Spacing.actionReserved)
                .contentShape(Rectangle())
        }
        .accessibilityLabel("批量操作")
    }

    private var isEditBatchActionBusy: Bool {
        viewModel.activeWriteAction != nil || viewModel.isLoadingBatchOptions
    }

    private func isEditBatchActionEnabled(_ action: BookshelfBookListEditAction) -> Bool {
        guard !isEditBatchActionBusy else { return false }
        switch action {
        case .moveToStart, .moveToEnd:
            return viewModel.canMoveSelectedItems
        case .moveToGroup, .addToBookList, .setTag, .setSource, .setReadStatus, .exportNote, .exportBook,
                .pin, .unpin, .reorder, .moveOut, .renameGroup, .deleteGroup, .renameTag, .deleteTag,
                .renameSource, .deleteSource, .deleteBooks:
            return viewModel.canMoreSelectedItems
        }
    }

    @ViewBuilder
    private func topSwitcherTrailing(for tab: BookSubTab) -> some View {
        switch tab {
        case .books:
            AddMenuCircleButton(
                onAddBook: onAddBook,
                onAddNote: onAddNote,
                onOpenDebugCenter: onOpenDebugCenter,
                usesGlassStyle: true
            )
            .transaction { transaction in
                transaction.animation = nil
                transaction.disablesAnimations = true
            }
        case .collections:
            if let collectionViewModel {
                BookCollectionTopActionPill(
                    isReordering: collectionEditMode.isEditing,
                    showsCreateAction: collectionViewModel.selectedKind == .manual,
                    canCreate: collectionViewModel.canCreateManualCollection,
                    allowsReorderAction: collectionViewModel.selectedKind == .manual,
                    manualCount: collectionViewModel.snapshot.manualCollections.count,
                    canReorder: collectionViewModel.selectedKind == .manual
                        && collectionViewModel.visibleCollections.count >= 2
                        && collectionViewModel.activeAction == nil,
                    canImportWeread: collectionViewModel.activeAction == nil,
                    onCreate: collectionViewModel.presentCreateForm,
                    onImportWeread: collectionViewModel.presentWereadImport,
                    onToggleReorder: toggleCollectionReordering,
                    onShowDisplaySettings: { showsCollectionDisplaySettingSheet = true }
                )
                .transition(.opacity.combined(with: .scale(scale: 0.96, anchor: .trailing)))
            }
        }
    }

    private var showsBrowsingChrome: Bool {
        selectedSubTab != .books || chromePhase == .normal
    }

    private var showsEditHeader: Bool {
        selectedSubTab == .books && chromePhase.showsEditHeader
    }

    private var editSearchState: BookshelfEditChromeSearchState {
        viewModel.hasSearchKeyword ? .active(resultCount: viewModel.visibleDefaultItemIDs.count) : .inactive
    }

    private var editStatusText: String? {
        if let notice = viewModel.actionNotice, !notice.isEmpty {
            return notice
        }
        if let activeAction = viewModel.activeWriteAction {
            return "正在\(activeAction.title)"
        }
        if viewModel.isLoadingBatchOptions {
            return "正在加载选项"
        }
        return viewModel.searchReorderDisabledNotice
    }

    private var canSearchCurrentDimension: Bool {
        selectedSubTab == .books && viewModel.selectedDimension.searchMenuTitle != nil
    }

    private var shouldRenderBrowseSearchDrawer: Bool {
        canSearchCurrentDimension
    }

    private var browseSearchDrawerHeight: CGFloat {
        shouldRenderBrowseSearchDrawer
            ? BookshelfChromeMetrics.searchDrawerHeight(for: dynamicTypeSize)
            : 0
    }

    private var isBrowseSearchSurfacePresented: Bool {
        browseSearch.isSurfacePresented(
            isSearchActive: viewModel.isSearchActive,
            hasSearchKeyword: viewModel.hasSearchKeyword
        )
    }

    private var hasBrowseSearchDraftKeyword: Bool {
        browseSearch.hasDraftKeyword
    }

    private var showsBrowsingGradient: Bool {
        selectedSubTab != .books || chromePhase == .normal
    }

    private var canShowSelectAction: Bool {
        selectedSubTab == .books && chromePhase == .normal && !viewModel.isEditing
    }

    private var topBarRowHeight: CGFloat {
        BookshelfEditChromeMetrics.topBarHeight(for: dynamicTypeSize)
    }

    private func toggleCollectionReordering() {
        withAnimation(reduceMotion ? nil : .smooth(duration: 0.18)) {
            collectionEditMode = collectionEditMode.isEditing ? .inactive : .active
        }
    }

    /// 进入书架管理模式，并为菜单收口与顶部 chrome 切换保留清晰节奏。
    /// - Note: 所有 SwiftUI 状态都在 MainActor 上修改；延迟任务会被后续进入/退出请求取消，避免旧阶段覆盖新阶段。
    private func enterEditingWithChoreography(initialSelection: BookshelfItemID? = nil) {
        guard selectedSubTab == .books, viewModel.canEditCurrentDimension else {
            return
        }
        chromeTransitionTask?.cancel()
        isEditingChoreographyActive = true
        prepareBrowseSearchForEditing()

        withAnimation(BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion)) {
            chromePhase = .enteringEdit
            viewModel.enterEditing(initialSelection: initialSelection)
        }

        guard viewModel.isEditing else {
            chromePhase = .normal
            isEditingChoreographyActive = false
            chromeTransitionTask = nil
            return
        }

        chromeTransitionTask = Task { @MainActor in
            try? await Task.sleep(for: BookshelfManagementMotion.editBarRevealDelay(reduceMotion: reduceMotion))
            guard !Task.isCancelled else { return }
            guard selectedSubTab == .books, viewModel.isEditing else {
                chromePhase = .normal
                isEditingChoreographyActive = false
                chromeTransitionTask = nil
                return
            }
            withAnimation(BookshelfManagementMotion.editBarRevealAnimation(reduceMotion: reduceMotion)) {
                chromePhase = .editing
            }
            isEditingChoreographyActive = false
            chromeTransitionTask = nil
        }
    }

    /// 退出书架管理模式并恢复普通浏览 chrome，系统 Tab Bar 在整个过程中保持可见。
    /// - Note: 方法只编排本地展示阶段；真正的选择清理仍交给 `BookViewModel.exitEditing()`，延迟任务可取消以处理快速反复切换。
    private func exitEditingWithChoreography() {
        guard viewModel.isEditing || chromePhase != .normal else { return }
        chromeTransitionTask?.cancel()
        isEditingChoreographyActive = true

        withAnimation(BookshelfManagementMotion.editBarExitAnimation(reduceMotion: reduceMotion)) {
            chromePhase = .exitingEdit
        }

        chromeTransitionTask = Task { @MainActor in
            try? await Task.sleep(for: BookshelfManagementMotion.editExitRestoreDelay(reduceMotion: reduceMotion))
            guard !Task.isCancelled else { return }
            withAnimation(BookshelfManagementMotion.restoreAnimation(reduceMotion: reduceMotion)) {
                viewModel.exitEditing()
                chromePhase = .normal
            }
            isEditingChoreographyActive = false
            chromeTransitionTask = nil
        }
    }

    private func toggleVisibleSelection() {
        withAnimation(BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion)) {
            if viewModel.isAllVisibleSelected {
                viewModel.clearVisibleSelection()
            } else {
                viewModel.selectAllVisible()
            }
        }
    }

    /// 同步外部编辑态变化，保证页面恢复或异步清理后本地 chrome 阶段不滞留。
    private func syncChromePhaseWithEditingState() {
        guard !isEditingChoreographyActive else { return }
        guard selectedSubTab == .books else {
            if viewModel.isEditing {
                viewModel.exitEditing()
            }
            chromeTransitionTask?.cancel()
            editingPresentation.resetForContextLoss()
            collapseBrowseSearchIfUnsupported()
            return
        }

        if viewModel.isEditing, chromePhase == .normal {
            chromePhase = .editing
        } else if !viewModel.isEditing, chromePhase != .normal {
            chromeTransitionTask?.cancel()
            chromePhase = .normal
            collapseBrowseSearchIfUnsupported()
        }
    }

    /// 打开集合顶部搜索 drawer；输入焦点由 collection 在 drawer 稳定后回调触发。
    private func activateBrowseSearch() {
        guard canSearchCurrentDimension else { return }
        browseSearch.seedDraftIfNeeded(
            hasSearchKeyword: viewModel.hasSearchKeyword,
            searchKeyword: viewModel.searchKeyword
        )
        withAnimation(BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion)) {
            viewModel.activateSearch()
            browseSearch.pin()
        }
    }

    /// 在搜索 drawer 完成 pinned 收敛后请求输入焦点，避免键盘动画与 offset 动画重叠。
    private func requestBrowseSearchFocus() {
        guard canSearchCurrentDimension else { return }
        browseSearch.requestFocus()
    }

    /// 处理搜索输入变化；关键词即时进入 ViewModel 触发过滤，键盘焦点继续由搜索 surface 管理。
    private func updateBrowseSearchKeyword(_ keyword: String) {
        guard canSearchCurrentDimension else { return }
        let normalizedKeyword = browseSearch.updateDraft(keyword)
        viewModel.searchQueryDidChange(normalizedKeyword)
    }

    /// 用户点击键盘 Search 后确认当前输入；过滤已随输入实时发生，这里只做 trim 收尾。
    private func submitBrowseSearch(_ keyword: String) {
        guard canSearchCurrentDimension else { return }
        let submittedKeyword = browseSearch.submit(keyword)
        viewModel.submitSearchQuery(submittedKeyword)
        if submittedKeyword.isEmpty {
            return
        }
        browseSearch.pin()
    }

    /// 清空关键词但保持搜索 drawer 与键盘焦点，方便用户连续修正查询。
    private func clearBrowseSearch() {
        guard canSearchCurrentDimension else { return }
        withAnimation(BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion)) {
            viewModel.clearSearchKeyword()
            viewModel.activateSearch()
            browseSearch.clearDraftAndPin(requestsFocus: true)
        }
    }

    /// 退出搜索并恢复原书架列表；整理态选择状态仍按 ViewModel 现有规则保留。
    private func collapseBrowseSearch() {
        withAnimation(BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion)) {
            viewModel.deactivateSearch()
            browseSearch.collapse()
        }
    }

    /// 二级页切换离开书籍页时立即收束页面私有状态，避免搜索与整理模式的退场动画污染子页面切换。
    private func resetBookChromeForSubtabSwitch() {
        chromeTransitionTask?.cancel()
        chromeTransitionTask = nil

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            viewModel.deactivateSearch()
            browseSearch.collapse()
            viewModel.exitEditing()
            editingPresentation.resetForContextLoss()
        }

        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// 同步输入框焦点变化，让 drawer 激活态与 UIKit first responder 不脱节。
    private func updateBrowseSearchFocus(_ isFocused: Bool) {
        browseSearch.updateFocus(isFocused)
        if isFocused, canSearchCurrentDimension {
            if !viewModel.isSearchActive {
                viewModel.activateSearch()
            }
            if !browseSearch.presentation.isPinned {
                browseSearch.pin()
            }
        } else if !isFocused, !hasBrowseSearchDraftKeyword, !viewModel.hasSearchKeyword {
            viewModel.deactivateSearch()
            browseSearch.presentation = .hidden
        }
    }

    /// 进入整理态时收起空搜索；有关键词时仅保留过滤结果，不让键盘继续抢占批量操作。
    private func prepareBrowseSearchForEditing() {
        browseSearch.prepareForEditing(
            hasSearchKeyword: viewModel.hasSearchKeyword,
            searchKeyword: viewModel.searchKeyword
        )
        if !viewModel.hasSearchKeyword {
            viewModel.deactivateSearch()
        }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
    }

    /// 当当前维度不支持搜索时收束搜索状态，避免关键词泄漏到状态维度。
    private func collapseBrowseSearchIfUnsupported() {
        guard !canSearchCurrentDimension else { return }
        collapseBrowseSearch()
    }

    /// 页面失活时立即清理展示阶段和业务编辑态，避免异步动画任务回写已离开的页面。
    private func resetEditingPresentationForContextLoss() {
        chromeTransitionTask?.cancel()
        chromeTransitionTask = nil
        editingPresentation.resetForContextLoss()
        collapseBrowseSearchIfUnsupported()
        viewModel.exitEditing()
    }

    private func defaultDeleteDescriptor(for confirmation: BookshelfDefaultDeleteConfirmation) -> XMSystemAlertDescriptor {
        if confirmation.groupCount == 0 {
            return XMSystemAlertDescriptor(
                title: "删除书籍",
                message: "将删除已选 \(confirmation.bookCount) 本书，并清理书摘、标签、分组、阅读状态、打卡、书单关系等关联数据。此操作不可撤销。",
                actions: [
                    XMSystemAlertAction(title: "取消", role: .cancel) { },
                    XMSystemAlertAction(title: "删除", role: .destructive) {
                        viewModel.submitDeleteItems(confirmation.targetIDs, placement: .end)
                    }
                ]
            )
        }

        let bookText = confirmation.bookCount > 0 ? "\(confirmation.bookCount) 本书" : ""
        let groupText = "\(confirmation.groupCount) 个分组"
        let targetText = [bookText, groupText].filter { !$0.isEmpty }.joined(separator: "和")
        return XMSystemAlertDescriptor(
            title: "删除书架项目",
            message: "将删除已选 \(targetText)。分组内书籍会移回默认书架，请选择它们的位置；此操作不可撤销。",
            actions: [
                XMSystemAlertAction(title: "取消", role: .cancel) { },
                XMSystemAlertAction(title: "移到最前并删除", role: .destructive) {
                    viewModel.submitDeleteItems(confirmation.targetIDs, placement: .start)
                },
                XMSystemAlertAction(title: "移到最后并删除", role: .destructive) {
                    viewModel.submitDeleteItems(confirmation.targetIDs, placement: .end)
                }
            ]
        )
    }

    // MARK: - Segmented Content

    private var segmentedContent: some View {
        KeepAliveSwitcherHost(
            selection: selectedSubTab,
            tabs: BookSubTab.allCases
        ) { tab in
            segmentedPage(for: tab)
        }
    }

    @ViewBuilder
    private func segmentedPage(for tab: BookSubTab) -> some View {
        switch tab {
        case .books:
            bookGridPage
        case .collections:
            collectionPlaceholderPage
        }
    }

    private var bookGridPage: some View {
        BookGridView(
            viewModel: viewModel,
            isPageActive: selectedSubTab == .books,
            hasSearchKeyword: viewModel.hasSearchKeyword,
            searchDrawerHeight: browseSearchDrawerHeight,
            searchPresentation: browseSearchPresentation,
            isSearchPresented: isBrowseSearchSurfacePresented,
            isSearchFocused: isBrowseSearchFocused,
            searchText: browseSearchDraftKeyword,
            searchKeyword: viewModel.searchKeyword,
            searchPlaceholder: viewModel.selectedDimension.searchPlaceholder,
            searchFocusTrigger: browseSearchFocusTrigger,
            canShowSelectAction: canShowSelectAction,
            canEditCurrentDimension: viewModel.canEditCurrentDimension,
            onActivateSearch: activateBrowseSearch,
            onRequestSearchFocus: requestBrowseSearchFocus,
            onSearchKeywordChange: updateBrowseSearchKeyword,
            onSubmitSearch: submitBrowseSearch,
            onClearSearch: clearBrowseSearch,
            onCancelSearch: collapseBrowseSearch,
            onSearchFocusChange: updateBrowseSearchFocus,
            onOpenRoute: onOpenBookRoute,
            onOpenNoteRoute: onOpenNoteRoute,
            onEnterEditing: { initialSelection in
                enterEditingWithChoreography(initialSelection: initialSelection)
            },
            onShowDisplaySettings: { showsDisplaySettingSheet = true },
            onOpenTagManagement: onOpenTagManagement,
            onOpenSourceManagement: onOpenSourceManagement,
            onOpenAuthorManagement: onOpenAuthorManagement,
            onOpenPressManagement: onOpenPressManagement,
            onOpenGuide: onOpenGuide
        )
    }

    private var collectionPlaceholderPage: some View {
        Group {
            if let collectionViewModel {
                BookCollectionListView(
                    viewModel: collectionViewModel,
                    editMode: $collectionEditMode,
                    onOpenCollection: { collectionID in
                        onOpenBookRoute(.collectionDetail(collectionID: collectionID))
                    }
                )
            } else {
                BookCollectionListSkeletonRows()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.surfacePage)
    }

}

// MARK: - Top Chrome Components

/// 书单页顶部操作区，以轻量图标按钮承接新建、更多菜单和完成排序入口。
private struct BookCollectionTopActionPill: View {
    let isReordering: Bool
    let showsCreateAction: Bool
    let canCreate: Bool
    let allowsReorderAction: Bool
    let manualCount: Int
    let canReorder: Bool
    let canImportWeread: Bool
    let onCreate: () -> Void
    let onImportWeread: () -> Void
    let onToggleReorder: () -> Void
    let onShowDisplaySettings: () -> Void

    private enum Style {
        static let hitSize: CGFloat = Spacing.actionReserved
        static let actionIconSize: CGFloat = 14
        static let trailingIconSize: CGFloat = 15
        static let iconColor = Color.iconPrimary.opacity(0.88)
    }

    var body: some View {
        Group {
            if isReordering {
                actionButton(
                    systemImage: "checkmark",
                    tint: Style.iconColor,
                    isDisabled: false,
                    presentation: .standalone,
                    accessibilityLabel: "完成排序",
                    accessibilityIdentifier: "book.collection.top.reorder.done",
                    action: onToggleReorder
                )
            } else if showsCreateAction {
                TopBarActionPill {
                    actionButton(
                        systemImage: "plus",
                        tint: Style.iconColor,
                        isDisabled: !canCreate,
                        presentation: .pillSegment,
                        accessibilityLabel: "新建书单",
                        accessibilityIdentifier: "book.collection.top.create",
                        action: onCreate
                    )
                } trailing: {
                    moreMenu(presentation: .pillSegment)
                }
            } else {
                moreMenu(presentation: .standalone)
            }
        }
        .frame(height: Style.hitSize)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("book.collection.top.actions")
        .animation(.smooth(duration: 0.16), value: isReordering)
        .animation(.smooth(duration: 0.16), value: showsCreateAction)
    }

    private var canStartReordering: Bool {
        allowsReorderAction && manualCount >= 2 && canReorder
    }

    /// 构造顶部轻量图标按钮，保留 44pt 热区并由无障碍标签补足语义。
    private func actionButton(
        systemImage: String,
        tint: Color,
        isDisabled: Bool,
        presentation: TopBarActionPresentation,
        accessibilityLabel: String,
        accessibilityIdentifier: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            TopBarActionIcon(
                systemName: systemImage,
                iconSize: Style.actionIconSize,
                foregroundColor: isDisabled ? Color.textHint : tint,
                hitShape: presentation == .pillSegment ? .rectangle : .circle
            )
        }
        .topBarActionPresentationStyle(presentation, enabled: !isDisabled)
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityIdentifier(accessibilityIdentifier)
    }

    /// 构造书单更多菜单，把低频整理和显示设置收敛到同一入口。
    private func moreMenu(presentation: TopBarActionPresentation) -> some View {
        Menu {
            if allowsReorderAction {
                Button(action: onToggleReorder) {
                    XMMenuLabel("调整排序", systemImage: "arrow.up.arrow.down")
                }
                .disabled(!canStartReordering)
            }

            Button(action: onImportWeread) {
                XMMenuLabel("导入微信读书书单", systemImage: "link.badge.plus")
            }
            .disabled(!canImportWeread)

            Button(action: onShowDisplaySettings) {
                XMMenuLabel("显示设置", systemImage: "slider.horizontal.3")
            }
        } label: {
            TopBarActionIcon(
                systemName: "ellipsis",
                iconSize: presentation == .pillSegment
                    ? Style.trailingIconSize
                    : Style.actionIconSize,
                foregroundColor: Style.iconColor,
                hitShape: presentation == .pillSegment ? .rectangle : .circle
            )
        }
        .topBarActionPresentationStyle(presentation)
        .xmMenuNeutralTint()
        .menuOrder(.fixed)
        .accessibilityLabel("书单更多操作")
        .accessibilityIdentifier("book.collection.top.more")
    }
}

private enum BookshelfChromeMetrics {
    /// 根据动态字体返回集合内搜索 drawer 高度，让一级页与二级列表在大字号下保持一致热区。
    static func searchDrawerHeight(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        dynamicTypeSize >= .accessibility1 ? 62 : 52
    }
}

private extension BookshelfDimension {
    var searchMenuTitle: String? {
        switch self {
        case .default:
            return "搜索书籍"
        case .tag:
            return "搜索标签"
        case .source:
            return "搜索来源"
        case .rating:
            return "搜索评分"
        case .author:
            return "搜索作者"
        case .press:
            return "搜索出版社"
        case .status:
            return nil
        }
    }

    var searchPlaceholder: String {
        switch self {
        case .default:
            return "搜索书名或作者"
        case .tag:
            return "搜索标签"
        case .source:
            return "搜索来源"
        case .rating:
            return "搜索评分"
        case .author:
            return "搜索作者"
        case .press:
            return "搜索出版社"
        case .status:
            return "搜索状态"
        }
    }
}

#Preview {
    let repositories = RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty()))
    NavigationStack {
        BookContainerView()
    }
    .environment(repositories)
}
