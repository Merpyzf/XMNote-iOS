//
//  BookContainerView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/10.
//

/**
 * [INPUT]: 依赖 RepositoryContainer、BookshelfEditingAccessoryCoordinator、HomeSubtabScaffold、InteractionMetrics、BookViewModel 与 BookCollectionListViewModel 驱动书架浏览、书单列表、显示设置、整理操作与活动写入反馈
 * [OUTPUT]: 对外提供 BookContainerView 与 BookSubTab 枚举，承载书籍/书单二级页切换、书单模式切换视口锚点、外部导入入口定位、顶部编辑摘要、含活动动作的根级底部整理快照、统一批量 Sheet 与删除确认
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
    @Environment(BookshelfEditingAccessoryCoordinator.self) private var editingAccessoryCoordinator
    @Environment(AppNavigationCoordinator.self) private var navigationCoordinator
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Bindable var viewModel: BookViewModel
    @Binding var selectedSubTab: BookSubTab
    @State private var collectionViewModel: BookCollectionListViewModel?
    @State private var collectionEditMode: EditMode = .inactive
    @State private var collectionViewportAnchorID: Int64?
    @State private var showsDisplaySettingSheet = false
    @State private var showsCollectionDisplaySettingSheet = false
    @State private var editingPresentation = BookshelfEditingPresentationState()
    @State private var chromeTransitionID: UUID?
    @State private var accessoryOwnerID = UUID()
    @State private var browseSearch = BookshelfSearchDrawerState()
    let onAddBook: () -> Void
    let onAddNote: () -> Void
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
                mode: let mode,
                bookIDs: let bookIDs,
                options: let options,
                initialSelectedIDs: let initialSelectedIDs,
                allowsEmptySelection: let allowsEmptySelection,
                isLoading: let isLoading,
                errorMessage: let errorMessage
            ):
                BookshelfBatchTagsSheet(
                    mode: mode,
                    options: options,
                    selectedCount: bookIDs.count,
                    initialSelectedIDs: initialSelectedIDs,
                    allowsEmptySelection: allowsEmptySelection,
                    isLoading: isLoading,
                    errorMessage: errorMessage,
                    onCreate: viewModel.createBatchTag(named:),
                    onSave: { tagIDs in
                        await viewModel.submitTagMutation(
                            bookIDs: bookIDs,
                            tagIDs: tagIDs,
                            mode: mode
                        )
                    }
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
        .xmSystemAlert(item: $viewModel.activeBatchTagModeConfirmation) { confirmation in
            XMSystemAlertDescriptor(
                title: "批量设置标签",
                message: "请选择对已选 \(confirmation.bookIDs.count) 本书执行的标签操作。",
                actions: [
                    XMSystemAlertAction(title: "取消", role: .cancel) { },
                    XMSystemAlertAction(title: "添加标签") {
                        viewModel.confirmBatchTagMode(.add, bookIDs: confirmation.bookIDs)
                    },
                    XMSystemAlertAction(title: "移除标签") {
                        viewModel.confirmBatchTagMode(.remove, bookIDs: confirmation.bookIDs)
                    }
                ]
            )
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
        .onChange(of: editingAccessorySnapshot, initial: true) { _, snapshot in
            publishEditingAccessory(snapshot)
        }
        .onChange(of: editingAccessoryCoordinator.pendingCommand) { _, command in
            handleEditingAccessoryCommand(command)
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
                )
                .frame(height: topBarRowHeight)
            }
            .frame(height: topBarRowHeight, alignment: .top)
            .transition(BookshelfManagementMotion.topChromeTransition(reduceMotion: reduceMotion))
            .zIndex(2)
        }
    }

    private var isEditBatchActionBusy: Bool {
        viewModel.activeWriteAction != nil || viewModel.isLoadingBatchOptions
    }

    /// 导出动作在当前 Tab 冻结所选书籍顺序并进入统一页面，其余批量写入继续由书架 ViewModel 负责。
    private func performBottomAction(_ action: BookshelfBookListEditAction) {
        let ids = viewModel.selectedBookIDsIncludingGroupBooks
        switch action {
        case .exportNote:
            navigationCoordinator.push(.export(ExportRoute(
                scope: .bookIDs(ids),
                initialKind: .noteExcerpt
            )))
        case .exportBook:
            navigationCoordinator.push(.export(ExportRoute(
                scope: .bookIDs(ids),
                initialKind: .bookInformation
            )))
        default:
            viewModel.performBottomAction(action)
        }
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

    private var editingAccessorySnapshot: BookshelfEditingAccessorySnapshot? {
        guard selectedSubTab == .books,
              viewModel.isEditing || chromePhase != .normal else {
            return nil
        }
        let actions = [.pin] + viewModel.defaultBottomActions + [.deleteBooks]
        let enabledActions = Set(actions.filter(isEditingAccessoryActionEnabled))
        return BookshelfEditingAccessorySnapshot(
            ownerID: accessoryOwnerID,
            source: .mainBookshelf,
            bookshelfTitle: "主书架",
            actions: actions,
            enabledActions: enabledActions,
            selectedCount: viewModel.selectedBookIDs.count + viewModel.selectedGroupCount,
            activeAction: editingAccessoryActiveAction,
            isBusy: isEditBatchActionBusy
        )
    }

    private var editingAccessoryActiveAction: BookshelfBookListEditAction? {
        guard let action = viewModel.activeWriteAction else { return nil }
        switch action {
        case .pin:
            return .pin
        case .unpin:
            return .unpin
        case .moveToStart:
            return .moveToStart
        case .moveToEnd:
            return .moveToEnd
        case .moveToGroup:
            return .moveToGroup
        case .addToBookList:
            return .addToBookList
        case .setTag:
            return .setTag
        case .setSource:
            return .setSource
        case .setReadStatus:
            return .setReadStatus
        case .exportNote:
            return .exportNote
        case .exportBook:
            return .exportBook
        case .delete:
            return .deleteBooks
        case .reorder:
            return .reorder
        case .move, .more, .editContributor, .deleteContributor:
            return nil
        }
    }

    private func isEditingAccessoryActionEnabled(_ action: BookshelfBookListEditAction) -> Bool {
        switch action {
        case .pin:
            return viewModel.canSubmitSelectedPin && !isEditBatchActionBusy
        case .deleteBooks:
            return viewModel.canDeleteSelectedItems && !isEditBatchActionBusy
        case .moveToStart, .moveToEnd, .moveToGroup, .addToBookList, .setTag, .setSource,
                .setReadStatus, .exportNote, .exportBook:
            return isEditBatchActionEnabled(action)
        case .unpin, .reorder, .moveOut, .renameGroup, .deleteGroup, .renameTag, .deleteTag,
                .renameSource, .deleteSource:
            return false
        }
    }

    /// 仅把页面当前编辑快照发布给根 Tab，业务对象和执行闭包始终留在页面内。
    private func publishEditingAccessory(_ snapshot: BookshelfEditingAccessorySnapshot?) {
        if let snapshot {
            if editingAccessoryCoordinator.presentationID(ownedBy: accessoryOwnerID) == nil {
                editingAccessoryCoordinator.activatePresentation(with: snapshot)
            } else if editingAccessoryCoordinator.presentationPhase == .exiting {
                guard chromePhase == .enteringEdit else { return }
                editingAccessoryCoordinator.activatePresentation(with: snapshot)
            } else {
                editingAccessoryCoordinator.updatePayload(snapshot)
            }
        } else {
            guard editingAccessoryCoordinator.presentationPhase != .exiting
                    || editingAccessoryCoordinator.presentationID(ownedBy: accessoryOwnerID) == nil else {
                return
            }
            editingAccessoryCoordinator.revokeImmediately(ownerID: accessoryOwnerID)
        }
    }

    /// 消费属于当前页面的 accessory 请求，并转发到既有 ViewModel 业务入口。
    private func handleEditingAccessoryCommand(_ command: BookshelfEditingAccessoryCommand?) {
        guard let command, command.ownerID == accessoryOwnerID else { return }
        guard editingAccessoryCoordinator.consume(
            requestID: command.requestID,
            ownerID: command.ownerID,
            presentationID: command.presentationID
        ) else { return }
        switch command.action {
        case .pin:
            viewModel.pinSelectedItems()
        case .deleteBooks:
            viewModel.presentDeleteConfirmation()
        case .moveToStart, .moveToEnd, .moveToGroup, .addToBookList, .setTag, .setSource,
                .setReadStatus, .exportNote, .exportBook:
            viewModel.performBottomAction(command.action)
        case .unpin, .reorder, .moveOut, .renameGroup, .deleteGroup, .renameTag, .deleteTag,
                .renameSource, .deleteSource:
            break
        }
    }

    @ViewBuilder
    private func topSwitcherTrailing(for tab: BookSubTab) -> some View {
        switch tab {
        case .books:
            AddMenuCircleButton(
                onAddBook: onAddBook,
                onAddNote: onAddNote,
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

    /// 进入书架管理模式，并以可反向的顶部 chrome 动画同步选择态与底部 accessory。
    /// - Note: 所有状态都在 MainActor 上修改；每次请求都会替换 transition ID，过期 completion 无法覆盖最新阶段。
    private func enterEditingWithChoreography(initialSelection: BookshelfItemID? = nil) {
        guard selectedSubTab == .books, viewModel.canEditCurrentDimension else {
            return
        }
        let transitionID = UUID()
        chromeTransitionID = transitionID
        isEditingChoreographyActive = true
        prepareBrowseSearchForEditing()

        withAnimation(
            BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion),
            completionCriteria: .logicallyComplete
        ) {
            chromePhase = .enteringEdit
            viewModel.enterEditing(initialSelection: initialSelection)
        } completion: {
            guard chromeTransitionID == transitionID else { return }
            guard selectedSubTab == .books, viewModel.isEditing else {
                chromePhase = .normal
                isEditingChoreographyActive = false
                chromeTransitionID = nil
                return
            }
            chromePhase = .editing
            isEditingChoreographyActive = false
            chromeTransitionID = nil
        }
    }

    /// 退出书架管理模式，同时淡出 accessory 与恢复浏览 chrome，各自 completion 只处理自己的生命周期。
    /// - Note: 所有状态都在 MainActor 上修改；owner、presentation 与 transition 三重校验阻止旧退场清掉后续重新进入。
    private func exitEditingWithChoreography() {
        guard viewModel.isEditing || chromePhase != .normal else { return }
        let transitionID = UUID()
        let accessoryPresentationID = editingAccessoryCoordinator.presentationID(ownedBy: accessoryOwnerID)
        chromeTransitionID = transitionID
        isEditingChoreographyActive = true

        if let accessoryPresentationID {
            withAnimation(
                BookshelfManagementMotion.accessoryExitAnimation(reduceMotion: reduceMotion),
                completionCriteria: .logicallyComplete
            ) {
                editingAccessoryCoordinator.beginExit(
                    ownerID: accessoryOwnerID,
                    presentationID: accessoryPresentationID,
                    transitionID: transitionID
                )
            } completion: {
                editingAccessoryCoordinator.completeExit(
                    ownerID: accessoryOwnerID,
                    presentationID: accessoryPresentationID,
                    transitionID: transitionID
                )
            }
        }

        withAnimation(
            BookshelfManagementMotion.restoreAnimation(reduceMotion: reduceMotion),
            completionCriteria: .logicallyComplete
        ) {
            viewModel.exitEditing()
            chromePhase = .normal
        } completion: {
            guard chromeTransitionID == transitionID else { return }
            isEditingChoreographyActive = false
            chromeTransitionID = nil
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
            chromeTransitionID = nil
            editingPresentation.resetForContextLoss()
            collapseBrowseSearchIfUnsupported()
            return
        }

        if viewModel.isEditing, chromePhase == .normal {
            chromePhase = .editing
        } else if !viewModel.isEditing, chromePhase != .normal {
            chromeTransitionID = nil
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
        chromeTransitionID = nil
        editingAccessoryCoordinator.revokeImmediately(ownerID: accessoryOwnerID)

        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            viewModel.deactivateSearch()
            browseSearch.collapse()
            viewModel.exitEditing()
            editingPresentation.resetForContextLoss()
        }
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
    }

    /// 当当前维度不支持搜索时收束搜索状态，避免关键词泄漏到状态维度。
    private func collapseBrowseSearchIfUnsupported() {
        guard !canSearchCurrentDimension else { return }
        collapseBrowseSearch()
    }

    /// 页面失活时立即清理展示阶段和业务编辑态，避免异步动画任务回写已离开的页面。
    private func resetEditingPresentationForContextLoss() {
        chromeTransitionID = nil
        editingAccessoryCoordinator.revokeImmediately(ownerID: accessoryOwnerID)
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
                    viewportAnchorID: $collectionViewportAnchorID,
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
        static let hitSize: CGFloat = InteractionMetrics.minimumTouchTarget
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
