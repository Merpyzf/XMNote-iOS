//
//  BookshelfBookListView.swift
//  xmnote
//
//  Created by Codex on 2026/5/6.
//

/**
 * [INPUT]: 依赖 BookshelfBookListRoute、RepositoryContainer、AppNavigationCoordinator、书架整理 accessory 协调器、系统返回手势桥接、InteractionMetrics 与外层普通浏览路由闭包
 * [OUTPUT]: 对外提供 BookshelfBookListView，组合本地顶部 chrome、搜索抽屉、BookshelfBookListCollectionView、写入失败反馈、根级底部编辑动作与统一批量标签 Sheet 容器
 * [POS]: Book 模块二级列表页，被 BookRoute.bookshelfList 导航目标消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 二级列表顶部本地 chrome 的状态化尺寸，避免搜索抽屉固定与底部栏避让同帧抢布局。
enum BookshelfBookListChromeMetrics {
    static let normalSearchAreaHeight: CGFloat = 52
    static let accessibilitySearchAreaHeight: CGFloat = 62
    static let titleHorizontalInset: CGFloat = 132

    static func searchAreaHeight(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        dynamicTypeSize >= .accessibility1 ? accessibilitySearchAreaHeight : normalSearchAreaHeight
    }

    static func browsingHeight(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        BookshelfEditChromeMetrics.topBarHeight(for: dynamicTypeSize)
    }

    static func editingHeight(for dynamicTypeSize: DynamicTypeSize) -> CGFloat {
        BookshelfEditChromeMetrics.topBarHeight(for: dynamicTypeSize)
    }
}

/// 书架聚合入口的二级只读列表页，通过 Repository 实时观察聚合上下文下的书籍集合。
struct BookshelfBookListView: View {
    @Environment(RepositoryContainer.self) private var repositories
    let route: BookshelfBookListRoute
    let onOpenRoute: (BookRoute) -> Void
    let onOpenNoteRoute: (NoteRoute) -> Void
    @State private var viewModel: BookshelfBookListViewModel?

    /// 构建二级书籍列表；点击书籍与添加笔记时把导航意图交回外层 NavigationStack。
    init(
        route: BookshelfBookListRoute,
        onOpenRoute: @escaping (BookRoute) -> Void = { _ in },
        onOpenNoteRoute: @escaping (NoteRoute) -> Void = { _ in }
    ) {
        self.route = route
        self.onOpenRoute = onOpenRoute
        self.onOpenNoteRoute = onOpenNoteRoute
    }

    var body: some View {
        Group {
            if let viewModel {
                BookshelfBookListContentView(
                    viewModel: viewModel,
                    onOpenRoute: onOpenRoute,
                    onOpenNoteRoute: onOpenNoteRoute
                )
            } else {
                Color.clear
                    .background(Color.surfacePage.ignoresSafeArea())
            }
        }
        .task(id: route) {
            viewModel = BookshelfBookListViewModel(
                route: route,
                repository: repositories.bookRepository
            )
        }
    }
}

/// 二级书籍列表 SwiftUI 壳层，承接搜索栏、加载态和 UIKit 集合区。
private struct BookshelfBookListContentView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(AppNavigationCoordinator.self) private var navigationCoordinator
    @Environment(BookshelfEditingAccessoryCoordinator.self) private var editingAccessoryCoordinator
    @Bindable var viewModel: BookshelfBookListViewModel
    let onOpenRoute: (BookRoute) -> Void
    let onOpenNoteRoute: (NoteRoute) -> Void
    @State private var showsDisplaySettingSheet = false
    @State private var editingPresentation = BookshelfEditingPresentationState()
    @State private var chromeTransitionID: UUID?
    @State private var accessoryOwnerID = UUID()
    @State private var browseSearch = BookshelfSearchDrawerState()
    @State private var readLoadingGate = LoadingGate()

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
        VStack(spacing: Spacing.none) {
            topChrome
                .zIndex(1)
            if chromePhase == .normal, viewModel.writeError != nil {
                XMInlineStatusBanner(
                    "操作未完成，请稍后重试",
                    tone: .error,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .padding(.horizontal, Spacing.screenEdge)
                .padding(.vertical, Spacing.cozy)
                .transition(.opacity)
                .accessibilityIdentifier("bookshelf.booklist.write-error")
            }

            collectionContent
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background(Color.surfacePage.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .navigationPopGuard(canPop: true, onBlockedAttempt: { })
        .onAppear {
            syncReadLoadingGate()
            syncChromePhaseWithEditingState()
        }
        .onChange(of: viewModel.contentState) { _, _ in
            syncReadLoadingGate()
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
        .onChange(of: viewModel.hasSearchKeyword) { _, hasSearchKeyword in
            if hasSearchKeyword {
                browseSearch.pin()
            }
        }
        .onDisappear {
            readLoadingGate.hideImmediately()
            resetEditingPresentationForContextLoss()
        }
        .sheet(isPresented: $showsDisplaySettingSheet) {
            BookshelfDisplaySettingSheet(
                dimension: viewModel.route.context.dimension,
                scope: .bookList,
                setting: Binding(
                    get: { viewModel.displaySetting },
                    set: { viewModel.updateDisplaySetting($0) }
                ),
                availableCriteria: BookshelfSortCriteria.availableForBookList(for: viewModel.route.context.dimension),
                showsPinnedInAllSortsSetting: true
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
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
                    selectedCount: viewModel.selectedCount,
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
                    selectedCount: viewModel.selectedCount,
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
                    selectedCount: viewModel.selectedCount,
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
                    selectedCount: viewModel.selectedCount,
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
        .xmSystemAlert(item: $viewModel.activeMoveOutConfirmation) { confirmation in
            XMSystemAlertDescriptor(
                title: "移出分组",
                message: "将已选 \(confirmation.selectedCount) 本书移回默认书架。请选择它们回到默认书架的位置。",
                actions: [
                    XMSystemAlertAction(title: "取消", role: .cancel) { },
                    XMSystemAlertAction(title: "移到最前") {
                        viewModel.submitMoveOut(placement: .start)
                    },
                    XMSystemAlertAction(title: "移到最后") {
                        viewModel.submitMoveOut(placement: .end)
                    }
                ]
            )
        }
        .xmSystemAlert(item: $viewModel.activeDeleteConfirmation) { confirmation in
            deleteDescriptor(for: confirmation)
        }
        .xmSystemAlert(item: $viewModel.activeNameEdit) { nameEdit in
            nameEditDescriptor(for: nameEdit)
        }
    }

    @ViewBuilder
    private var topChrome: some View {
        ZStack(alignment: .top) {
            if chromePhase == .normal {
                BookshelfBookListBrowsingChrome(
                    title: viewModel.navigationTitle,
                    canEnterEditing: viewModel.canEnterEditing,
                    topBarHeight: topBarRowHeight,
                    onBack: { dismiss() },
                    onShowDisplaySettings: { showsDisplaySettingSheet = true },
                    onEnterEditing: enterEditingWithChoreography
                )
                .allowsHitTesting(chromePhase == .normal)
                .transition(BookshelfManagementMotion.bookListTopChromeTransition(reduceMotion: reduceMotion))
            }

            if chromePhase.showsEditHeader {
                BookshelfEditChrome(
                    title: viewModel.navigationTitle,
                    selectedBookCount: viewModel.selectedCount,
                    selectionScope: .booksOnly,
                    isAllVisibleSelected: viewModel.isAllVisibleSelected,
                    isSelectionToggleEnabled: !viewModel.visibleBookIDs.isEmpty,
                    searchState: editSearchState,
                    statusText: editStatusText,
                    drawsSurfaceBackground: false,
                    showsBottomDivider: false,
                    onToggleSelectAll: toggleVisibleSelection,
                    onCancel: exitEditingWithChoreography
                )
                .frame(height: topBarRowHeight)
                .transition(BookshelfManagementMotion.bookListTopChromeTransition(reduceMotion: reduceMotion))
            }
        }
        .frame(height: reservedTopChromeHeight, alignment: .top)
        .background {
            Color.surfacePage
                .ignoresSafeArea(.container, edges: .top)
        }
    }

    private var isEditActionBusy: Bool {
        viewModel.activeWriteAction != nil || viewModel.isLoadingBatchOptions
    }

    private func isEditActionEnabled(_ action: BookshelfBookListEditAction) -> Bool {
        guard !isEditActionBusy else { return false }
        return !action.requiresSelection || viewModel.selectedCount > 0
    }

    private var editingAccessorySnapshot: BookshelfEditingAccessorySnapshot? {
        guard viewModel.isEditing || chromePhase != .normal else { return nil }
        let actions = viewModel.editActions
        return BookshelfEditingAccessorySnapshot(
            ownerID: accessoryOwnerID,
            source: .bookList,
            bookshelfTitle: viewModel.navigationTitle,
            actions: actions,
            enabledActions: Set(actions.filter(isEditActionEnabled)),
            selectedCount: viewModel.selectedCount,
            isBusy: isEditActionBusy
        )
    }

    /// 仅向根 Tab 发布当前二级书架的纯值快照，离开页面时按 owner 精确撤销。
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

    /// 消费属于当前二级书架的瞬时请求，并复用既有动作分发与确认流程。
    private func handleEditingAccessoryCommand(_ command: BookshelfEditingAccessoryCommand?) {
        guard let command, command.ownerID == accessoryOwnerID else { return }
        guard editingAccessoryCoordinator.consume(
            requestID: command.requestID,
            ownerID: command.ownerID,
            presentationID: command.presentationID
        ) else { return }
        viewModel.performEditAction(command.action)
    }

    private var topBarRowHeight: CGFloat {
        BookshelfEditChromeMetrics.topBarHeight(for: dynamicTypeSize)
    }

    private var searchAreaHeight: CGFloat {
        BookshelfBookListChromeMetrics.searchAreaHeight(for: dynamicTypeSize)
    }

    private var reservedTopChromeHeight: CGFloat {
        expectedTopChromeHeight
    }

    private var expectedTopChromeHeight: CGFloat {
        switch chromePhase {
        case .normal:
            return BookshelfBookListChromeMetrics.browsingHeight(for: dynamicTypeSize)
        case .enteringEdit, .editing, .exitingEdit:
            return BookshelfBookListChromeMetrics.editingHeight(for: dynamicTypeSize)
        }
    }

    private var browseSearchPlaceholder: String {
        "搜索书名或作者"
    }

    private var editSearchState: BookshelfEditChromeSearchState {
        viewModel.hasSearchKeyword ? .active(resultCount: viewModel.visibleBookIDs.count) : .inactive
    }

    private var editStatusText: String? {
        if let notice = viewModel.actionNotice, !notice.isEmpty {
            return notice
        }
        if let activeAction = viewModel.activeWriteAction {
            return "\(activeAction.title)处理中…"
        }
        if viewModel.isLoadingBatchOptions {
            return "正在加载批量编辑选项…"
        }
        return viewModel.searchReorderDisabledNotice
    }

    private var renderedContentState: BookshelfContentState {
        isInitialReadLoading ? .loading : viewModel.contentState
    }

    private var isInitialReadLoading: Bool {
        !viewModel.hasCompletedInitialLoad && viewModel.contentState == .loading
    }

    private var shouldRenderCollection: Bool {
        !isInitialReadLoading || readLoadingGate.isVisible
    }

    private var shouldRenderSearchDrawer: Bool {
        viewModel.hasCompletedInitialLoad
            || viewModel.hasSearchKeyword
            || hasBrowseSearchDraftKeyword
            || browseSearch.presentation.isPinned
            || browseSearch.isFocused
    }

    private var hasBrowseSearchDraftKeyword: Bool {
        browseSearch.hasDraftKeyword
    }

    private var effectiveSearchDrawerHeight: CGFloat {
        shouldRenderSearchDrawer ? searchAreaHeight : 0
    }

    @ViewBuilder
    private var collectionContent: some View {
        if shouldRenderCollection {
            BookshelfBookListCollectionView(
                snapshot: viewModel.snapshot,
                subtitle: viewModel.subtitle,
                contentState: renderedContentState,
                layoutMode: viewModel.displaySetting.layoutMode,
                columnCount: viewModel.displaySetting.columnCount,
                showsNoteCount: viewModel.displaySetting.showsNoteCount,
                sortCriteria: viewModel.displaySetting.sortCriteria,
                titleDisplayMode: viewModel.displaySetting.titleDisplayMode,
                isEditing: viewModel.isEditing,
                hasSearchKeyword: viewModel.hasSearchKeyword,
                searchDrawerHeight: effectiveSearchDrawerHeight,
                searchPresentation: browseSearchPresentation,
                isBrowseSearchFocused: isBrowseSearchFocused,
                browseSearchText: browseSearchDraftKeyword,
                browseSearchKeyword: viewModel.searchKeyword,
                browseSearchPlaceholder: browseSearchPlaceholder,
                browseSearchFocusTrigger: browseSearchFocusTrigger,
                selectedBookIDs: viewModel.selectedBookIDSet,
                canReorder: viewModel.canReorderBooksInDefaultGroup,
                movableBookIDs: viewModel.movableBookIDs,
                supportsContextPin: viewModel.supportsContextPin,
                activeWriteAction: viewModel.activeWriteAction,
                bottomContentInset: .zero,
                onActivateBrowseSearch: activateBrowseSearch,
                onRequestBrowseSearchFocus: requestBrowseSearchFocus,
                onBrowseSearchKeywordChange: updateBrowseSearchKeyword(_:),
                onSubmitBrowseSearch: submitBrowseSearch(_:),
                onBrowseSearchFocusChange: handleBrowseSearchFocusChange(_:),
                onClearBrowseSearch: clearBrowseSearch,
                onCollapseBrowseSearch: collapseBrowseSearch,
                onToggleSelection: viewModel.toggleSelection,
                onSelectBook: handleBookSelection(_:),
                onContextAction: handleContextAction(_:bookID:),
                onCommitOrder: viewModel.commitBooksInDefaultGroupOrder
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .bottom)
            .ignoresSafeArea(.keyboard, edges: .bottom)
        } else {
            Color.clear
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityHidden(true)
        }
    }

    private func syncReadLoadingGate() {
        let isInitialLoading = !viewModel.hasCompletedInitialLoad && viewModel.contentState == .loading
        readLoadingGate.update(intent: isInitialLoading ? .read : .none)
    }

    /// 进入整理模式时以可反向动画切换顶部 chrome，并同步发布底部 accessory 快照。
    /// - Note: 所有状态都在 MainActor 修改；每次请求替换 transition ID，过期 completion 无法回写新状态。
    private func enterEditingWithChoreography() {
        guard viewModel.canEnterEditing else { return }
        let transitionID = UUID()
        chromeTransitionID = transitionID
        isEditingChoreographyActive = true
        prepareBrowseSearchForEditing()

        withAnimation(
            BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion),
            completionCriteria: .logicallyComplete
        ) {
            chromePhase = .enteringEdit
            viewModel.enterEditing()
        } completion: {
            guard chromeTransitionID == transitionID else { return }
            guard viewModel.isEditing else {
                releaseEditPresentationState()
                return
            }
            chromePhase = .editing
            isEditingChoreographyActive = false
            chromeTransitionID = nil
        }
    }

    /// 按一级书架同款语义切换当前可见书籍的全选状态。
    private func toggleVisibleSelection() {
        withAnimation(BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion)) {
            if viewModel.isAllVisibleSelected {
                viewModel.clearVisibleSelection()
            } else {
                viewModel.selectAllVisible()
            }
        }
    }

    private func activateBrowseSearch() {
        browseSearch.seedDraftIfNeeded(
            hasSearchKeyword: viewModel.hasSearchKeyword,
            searchKeyword: viewModel.searchKeyword
        )
        withAnimation(BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion)) {
            browseSearch.pin()
        }
    }

    private func requestBrowseSearchFocus() {
        browseSearch.requestFocus()
    }

    private func updateBrowseSearchKeyword(_ keyword: String) {
        let normalizedKeyword = browseSearch.updateDraft(keyword)
        viewModel.searchQueryDidChange(normalizedKeyword)
    }

    private func submitBrowseSearch(_ keyword: String) {
        let submittedKeyword = browseSearch.submit(keyword)
        viewModel.submitSearchQuery(submittedKeyword)
        if submittedKeyword.isEmpty {
            return
        }
        browseSearch.pin()
    }

    private func handleBrowseSearchFocusChange(_ isFocused: Bool) {
        browseSearch.updateFocus(isFocused)
        if isFocused {
            if !browseSearch.presentation.isPinned {
                browseSearch.pin()
            }
        } else if !hasBrowseSearchDraftKeyword, !viewModel.hasSearchKeyword {
            browseSearch.presentation = .hidden
        }
    }

    /// 处理 UIKit collection 发出的书籍选择事件，由 SwiftUI 页面层负责转换为导航路由。
    private func handleBookSelection(_ bookID: Int64) {
        onOpenRoute(.detail(bookId: bookID))
    }

    private func clearBrowseSearch() {
        viewModel.clearSearchKeyword()
        withAnimation(BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion)) {
            browseSearch.clearDraftAndPin(requestsFocus: true)
        }
    }

    private func collapseBrowseSearch() {
        viewModel.clearSearchKeyword()
        withAnimation(BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion)) {
            browseSearch.collapse()
        }
    }

    /// 进入整理态时收起空搜索；有关键词时保留过滤结果但取消键盘焦点。
    private func prepareBrowseSearchForEditing() {
        browseSearch.prepareForEditing(
            hasSearchKeyword: viewModel.hasSearchKeyword,
            searchKeyword: viewModel.searchKeyword
        )
        if !viewModel.hasSearchKeyword {
            viewModel.clearSearchKeyword()
        }
    }

    /// 退出整理模式时同步淡出底部动作与恢复普通顶部 chrome，避免串行形成两段舞台感。
    /// - Note: 所有状态都在 MainActor 上修改；旧 completion 需同时匹配页面 transition 与 accessory presentation。
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

    /// 同步外部编辑态变化，保证上下文菜单或页面恢复不会留下过期 chrome 阶段。
    private func syncChromePhaseWithEditingState() {
        guard !isEditingChoreographyActive else { return }
        if viewModel.isEditing, chromePhase == .normal {
            chromePhase = .editing
        } else if !viewModel.isEditing, chromePhase != .normal {
            chromeTransitionID = nil
            chromePhase = .normal
            releaseEditPresentationState()
        }
    }

    /// 恢复本地展示阶段，供异常进入失败或外部状态同步时收束到普通态。
    private func releaseEditPresentationState() {
        chromePhase = viewModel.isEditing ? .editing : .normal
        isEditingChoreographyActive = false
        chromeTransitionID = nil
    }

    /// 页面离开时立即清理展示阶段、accessory owner 与业务编辑态，避免 completion 回写失效页面。
    private func resetEditingPresentationForContextLoss() {
        chromeTransitionID = nil
        editingAccessoryCoordinator.revokeImmediately(ownerID: accessoryOwnerID)
        editingPresentation.resetForContextLoss()
        viewModel.exitEditing()
    }

    private func deleteDescriptor(for confirmation: BookshelfBookListDeleteConfirmation) -> XMSystemAlertDescriptor {
        switch confirmation.kind {
        case .books(let bookIDs):
            return XMSystemAlertDescriptor(
                title: "删除书籍",
                message: "将删除已选 \(bookIDs.count) 本书，并清理书摘、标签、分组、阅读状态、打卡、书单关系等关联数据。此操作不可撤销。",
                actions: [
                    XMSystemAlertAction(title: "取消", role: .cancel) { },
                    XMSystemAlertAction(title: "删除", role: .destructive) {
                        viewModel.submitDeleteBooks()
                    }
                ],
                preferredActionID: nil
            )
        case .group(let title):
            return XMSystemAlertDescriptor(
                title: "删除分组",
                message: "将删除“\(title)”分组，并把组内书籍移回默认书架。请选择它们回到默认书架的位置。",
                actions: [
                    XMSystemAlertAction(title: "取消", role: .cancel) { },
                    XMSystemAlertAction(title: "移到最前并删除", role: .destructive) {
                        viewModel.submitDeleteGroup(placement: .start)
                    },
                    XMSystemAlertAction(title: "移到最后并删除", role: .destructive) {
                        viewModel.submitDeleteGroup(placement: .end)
                    }
                ]
            )
        case .tag(let title):
            return XMSystemAlertDescriptor(
                title: "删除标签",
                message: "将删除“\(title)”标签，并清理它与书籍、书摘的关系。此操作不可撤销。",
                actions: [
                    XMSystemAlertAction(title: "取消", role: .cancel) { },
                    XMSystemAlertAction(title: "删除", role: .destructive) {
                        viewModel.submitDeleteTag()
                    }
                ]
            )
        case .source(let title):
            return XMSystemAlertDescriptor(
                title: "删除来源",
                message: "将删除“\(title)”来源，并把使用该来源的书籍迁移到未知来源。此操作不可撤销。",
                actions: [
                    XMSystemAlertAction(title: "取消", role: .cancel) { },
                    XMSystemAlertAction(title: "删除", role: .destructive) {
                        viewModel.submitDeleteSource()
                    }
                ]
            )
        }
    }

    private func handleContextAction(_ action: BookshelfBookContextAction, bookID: Int64) {
        switch action {
        case .addNote:
            navigationCoordinator.present(
                .noteEditor(
                    mode: .create,
                    seed: NoteEditorSeed(
                        bookId: bookID,
                        chapterId: nil,
                        contentHTML: "",
                        ideaHTML: ""
                    )
                )
            )
        case .pin:
            viewModel.pinBook(bookID)
        case .unpin:
            viewModel.unpinBook(bookID)
        case .editBook:
            navigationCoordinator.present(.bookEditor(.edit(bookId: bookID)))
        case .showReadingDetail:
            viewModel.presentContextPlaceholder("阅读详情将在阅读模块迁移后开放")
        case .startReadTiming:
            viewModel.presentContextPlaceholder("开始计时将在阅读模块迁移后开放")
        case .organizeBooks:
            enterEditingWithChoreography()
        case .delete:
            viewModel.presentDeleteBookConfirmation(bookID: bookID)
        }
    }

    private func nameEditDescriptor(for nameEdit: BookshelfBookListNameEdit) -> XMSystemAlertDescriptor {
        XMSystemAlertDescriptor(
            title: nameEdit.action.title,
            message: "请输入新的名称。",
            actions: [
                XMSystemAlertAction(title: "取消", role: .cancel) { },
                XMSystemAlertAction(title: "完成") {
                    viewModel.submitNameEdit()
                }
            ],
            textFields: [
                XMSystemAlertTextField(
                    text: Binding(
                        get: { viewModel.nameEditText },
                        set: { viewModel.nameEditText = $0 }
                    ),
                    placeholder: nameEdit.currentName,
                    autocorrectionDisabled: true
                )
            ]
        )
    }
}


#Preview {
    NavigationStack {
        BookshelfBookListView(route: BookshelfBookListRoute(
            context: .tag(1),
            title: "文学",
            subtitleHint: "2本"
        ))
    }
    .environment(RepositoryContainer(databaseManager: DatabaseManager(database: try! .empty())))
}
