//
//  BookshelfBookListView.swift
//  xmnote
//
//  Created by Codex on 2026/5/6.
//

/**
 * [INPUT]: 依赖 BookshelfBookListRoute 提供聚合上下文，依赖 BookRepositoryProtocol 提供二级列表观察流，依赖外层 BookRoute/NoteRoute 闭包承接书籍与书摘导航
 * [OUTPUT]: 对外提供 BookshelfBookListView，使用本地顶部 chrome、collection 内单一搜索抽屉、UIKit UICollectionView 展示聚合书籍列表、底部安全区沉浸滚动、长按菜单、编辑选择顶部 chrome、底部玻璃批量工具栏与批量编辑 Sheet 容器
 * [POS]: Book 模块二级列表页，被 BookRoute.bookshelfList 导航目标消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 二级书籍列表底部玻璃栏换算出的滚动余量，供 UIKit collection 避让浮动控件。
private struct BookshelfBookListEditBottomInsetPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// 二级列表整理态的本地展示阶段，拆分顶部 chrome、底部栏与滚动避让的出现时机。
private enum BookshelfBookListChromePhase: Equatable {
    case normal
    case enteringEdit
    case editing
    case exitingEdit

    var showsEditHeader: Bool {
        switch self {
        case .normal:
            return false
        case .enteringEdit, .editing, .exitingEdit:
            return true
        }
    }

    var showsEditBottomBar: Bool {
        self == .editing
    }

    var reservesEditBottomBarSpace: Bool {
        switch self {
        case .normal:
            return false
        case .enteringEdit:
            return false
        case .editing, .exitingEdit:
            return true
        }
    }
}

/// 二级列表搜索的本地呈现状态；露出过程由 collection 滚动偏移表达，业务关键词仍由 ViewModel 管理。
private enum BookshelfBookListSearchPresentation: Equatable {
    case hidden
    case pinned

    var isPinned: Bool {
        self == .pinned
    }
}

/// 二级列表顶部本地 chrome 的状态化尺寸，避免搜索抽屉固定与底部栏避让同帧抢布局。
private enum BookshelfBookListChromeMetrics {
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
    @Bindable var viewModel: BookshelfBookListViewModel
    let onOpenRoute: (BookRoute) -> Void
    let onOpenNoteRoute: (NoteRoute) -> Void
    @State private var showsDisplaySettingSheet = false
    @State private var chromePhase: BookshelfBookListChromePhase = .normal
    @State private var chromeTransitionTask: Task<Void, Never>?
    @State private var isEditingChoreographyActive = false
    @State private var bottomOrnamentHeight: CGFloat = 0
    @State private var bottomContentInset: CGFloat = 0
    @State private var isRetainingBottomInsetForEditExit = false
    @State private var bottomInsetReleaseTask: Task<Void, Never>?
    @State private var browseSearchPresentation: BookshelfBookListSearchPresentation = .hidden
    @State private var isBrowseSearchFocused = false
    @State private var browseSearchFocusTrigger = 0
    @State private var readLoadingGate = LoadingGate()

    var body: some View {
        VStack(spacing: Spacing.none) {
            topChrome
                .zIndex(1)
            BookshelfBookListCollectionView(
                snapshot: viewModel.snapshot,
                subtitle: viewModel.subtitle,
                contentState: renderedContentState,
                layoutMode: viewModel.displaySetting.layoutMode,
                columnCount: viewModel.displaySetting.columnCount,
                showsNoteCount: viewModel.displaySetting.showsNoteCount,
                titleDisplayMode: viewModel.displaySetting.titleDisplayMode,
                isEditing: viewModel.isEditing,
                hasSearchKeyword: viewModel.hasSearchKeyword,
                searchDrawerHeight: searchAreaHeight,
                searchPresentation: browseSearchPresentation,
                isBrowseSearchFocused: isBrowseSearchFocused,
                browseSearchKeyword: viewModel.searchKeyword,
                browseSearchPlaceholder: browseSearchPlaceholder,
                browseSearchFocusTrigger: browseSearchFocusTrigger,
                selectedBookIDs: viewModel.selectedBookIDSet,
                canReorder: viewModel.canReorderBooksInDefaultGroup,
                movableBookIDs: viewModel.movableBookIDs,
                supportsContextPin: viewModel.supportsContextPin,
                activeWriteAction: viewModel.activeWriteAction,
                bottomContentInset: bottomContentInset,
                onActivateBrowseSearch: activateBrowseSearch,
                onBrowseSearchKeywordChange: { viewModel.searchKeyword = $0 },
                onBrowseSearchFocusChange: handleBrowseSearchFocusChange(_:),
                onClearBrowseSearch: clearBrowseSearch,
                onCollapseBrowseSearch: collapseBrowseSearch,
                onToggleSelection: viewModel.toggleSelection,
                onOpenBook: { bookID in
                    onOpenRoute(.detail(bookId: bookID))
                },
                onContextAction: handleContextAction(_:bookID:),
                onCommitOrder: viewModel.commitBooksInDefaultGroupOrder
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .background(Color.surfacePage.ignoresSafeArea())
        .navigationBarBackButtonHidden(true)
        .toolbar(.hidden, for: .navigationBar)
        .overlay(alignment: .bottom) {
            editBottomBarOverlay
        }
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
        .onChange(of: viewModel.hasSearchKeyword) { _, hasSearchKeyword in
            if hasSearchKeyword {
                browseSearchPresentation = .pinned
            }
        }
        .onPreferenceChange(BookshelfBookListEditBottomInsetPreferenceKey.self) { inset in
            guard reservesEditBottomInset else { return }
            guard bottomContentInset != inset else { return }
            bottomContentInset = inset
        }
        .onPreferenceChange(ImmersiveBottomChromeHeightPreferenceKey.self) { height in
            guard showsEditBottomBar, abs(bottomOrnamentHeight - height) > 0.5 else { return }
            bottomOrnamentHeight = height
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
                options: let options,
                initialSelectedIDs: let initialSelectedIDs,
                allowsEmptySelection: let allowsEmptySelection,
                isLoading: let isLoading,
                errorMessage: let errorMessage
            ):
                BookshelfBatchTagsSheet(
                    options: options,
                    selectedCount: viewModel.selectedCount,
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
            }
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
                .transition(BookshelfManagementMotion.topChromeTransition(reduceMotion: reduceMotion))
            }

            if chromePhase.showsEditHeader {
                BookshelfEditChrome(
                    selectedBookCount: viewModel.selectedCount,
                    selectionScope: .booksOnly,
                    isAllVisibleSelected: viewModel.isAllVisibleSelected,
                    isSelectionToggleEnabled: !viewModel.visibleBookIDs.isEmpty,
                    searchState: editSearchState,
                    onToggleSelectAll: toggleVisibleSelection,
                    onCancel: exitEditingWithChoreography
                )
                .frame(height: topBarRowHeight)
                .transition(BookshelfManagementMotion.topChromeTransition(reduceMotion: reduceMotion))
            }
        }
        .frame(height: reservedTopChromeHeight, alignment: .top)
        .background {
            Color.surfacePage
                .ignoresSafeArea(.container, edges: .top)
        }
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

    @ViewBuilder
    private var editBottomBarOverlay: some View {
        GeometryReader { proxy in
            let metrics = bottomChromeMetrics(safeAreaBottomInset: proxy.safeAreaInsets.bottom)

            if reservesEditBottomInset {
                if showsEditBottomBar {
                    ImmersiveBottomChromeOverlay(metrics: metrics) {
                        BookshelfBookListEditBottomBar(
                            selectedCount: viewModel.selectedCount,
                            actions: viewModel.editActions,
                            activeAction: viewModel.activeWriteAction,
                            isLoadingOptions: viewModel.isLoadingBatchOptions,
                            notice: viewModel.actionNotice,
                            onAction: viewModel.performEditAction
                        )
                    }
                    .preference(key: BookshelfBookListEditBottomInsetPreferenceKey.self, value: metrics.readableInset)
                    .transition(BookshelfManagementMotion.editBarRevealTransition(reduceMotion: reduceMotion))
                } else {
                    Color.clear
                        .preference(key: BookshelfBookListEditBottomInsetPreferenceKey.self, value: metrics.readableInset)
                }
            } else {
                Color.clear
                    .preference(key: BookshelfBookListEditBottomInsetPreferenceKey.self, value: 0)
            }
        }
        .allowsHitTesting(showsEditBottomBar)
    }

    private func bottomChromeMetrics(safeAreaBottomInset: CGFloat) -> ImmersiveBottomChromeMetrics {
        ImmersiveBottomChromeMetrics.make(
            measuredOrnamentHeight: bottomOrnamentHeight,
            safeAreaBottomInset: safeAreaBottomInset,
            ornamentMinimumTouchHeight: BookshelfGlassEditBarMetrics.clusterHeight,
            ornamentTopPadding: Spacing.tight
        )
    }

    private var reservesEditBottomInset: Bool {
        chromePhase.reservesEditBottomBarSpace || isRetainingBottomInsetForEditExit || bottomContentInset > 0
    }

    private var showsEditBottomBar: Bool {
        chromePhase.showsEditBottomBar
    }

    private var browseSearchPlaceholder: String {
        let rawCount = viewModel.subtitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !rawCount.isEmpty else { return "搜索书名、状态或来源" }
        if rawCount.hasSuffix("本") {
            let numericText = rawCount
                .dropLast()
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !numericText.isEmpty {
                return "在 \(numericText) 本中搜索"
            }
        }
        return "在 \(rawCount) 中搜索"
    }

    private var editSearchState: BookshelfEditChromeSearchState {
        viewModel.hasSearchKeyword ? .active(resultCount: viewModel.visibleBookIDs.count) : .inactive
    }

    private var renderedContentState: BookshelfContentState {
        guard case .loading = viewModel.contentState else {
            return viewModel.contentState
        }
        guard !viewModel.hasCompletedInitialLoad else {
            return .content
        }
        return readLoadingGate.isVisible ? .loading : .content
    }

    private func syncReadLoadingGate() {
        let isInitialLoading = !viewModel.hasCompletedInitialLoad && viewModel.contentState == .loading
        readLoadingGate.update(intent: isInitialLoading ? .read : .none)
    }

    /// 进入整理模式时先切换顶部 chrome，再延迟抬起底部批量栏。
    /// - Note: 所有展示状态都在 MainActor 修改；阶段任务会被后续进入/退出请求取消，避免旧动画回写新页面状态。
    private func enterEditingWithChoreography() {
        guard viewModel.canEnterEditing else { return }
        chromeTransitionTask?.cancel()
        cancelBottomInsetRelease()
        isEditingChoreographyActive = true

        withAnimation(BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion)) {
            chromePhase = .enteringEdit
            viewModel.enterEditing()
        }

        guard viewModel.isEditing else {
            releaseEditPresentationState()
            return
        }

        chromeTransitionTask = Task { @MainActor in
            try? await Task.sleep(for: BookshelfManagementMotion.editBarRevealDelay(reduceMotion: reduceMotion))
            guard !Task.isCancelled else { return }
            guard viewModel.isEditing else {
                releaseEditPresentationState()
                return
            }
            withAnimation(BookshelfManagementMotion.editBarRevealAnimation(reduceMotion: reduceMotion)) {
                chromePhase = .editing
            }
            isEditingChoreographyActive = false
            chromeTransitionTask = nil
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
        withAnimation(BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion)) {
            browseSearchPresentation = .pinned
            browseSearchFocusTrigger += 1
        }
    }

    private func handleBrowseSearchFocusChange(_ isFocused: Bool) {
        isBrowseSearchFocused = isFocused
        if isFocused {
            browseSearchPresentation = .pinned
        }
    }

    private func clearBrowseSearch() {
        viewModel.clearSearchKeyword()
        withAnimation(BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion)) {
            browseSearchPresentation = .pinned
            browseSearchFocusTrigger += 1
        }
    }

    private func collapseBrowseSearch() {
        guard !viewModel.hasSearchKeyword else { return }
        withAnimation(BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion)) {
            browseSearchPresentation = .hidden
            isBrowseSearchFocused = false
        }
    }

    /// 退出整理模式时先收起底部栏，再恢复普通顶部 chrome 并释放滚动避让。
    /// - Note: 业务选择清理由 ViewModel 执行；这里仅编排本地展示阶段和底部 inset 生命周期。
    private func exitEditingWithChoreography() {
        guard viewModel.isEditing || chromePhase != .normal else { return }
        chromeTransitionTask?.cancel()
        bottomInsetReleaseTask?.cancel()
        bottomInsetReleaseTask = nil
        isEditingChoreographyActive = true

        withAnimation(BookshelfManagementMotion.editBarExitAnimation(reduceMotion: reduceMotion)) {
            chromePhase = .exitingEdit
        }

        chromeTransitionTask = Task { @MainActor in
            try? await Task.sleep(for: BookshelfManagementMotion.editExitRestoreDelay(reduceMotion: reduceMotion))
            guard !Task.isCancelled else { return }
            isRetainingBottomInsetForEditExit = bottomContentInset > 0 || bottomOrnamentHeight > 0

            withAnimation(BookshelfManagementMotion.restoreAnimation(reduceMotion: reduceMotion)) {
                viewModel.exitEditing()
                chromePhase = .normal
            }

            bottomInsetReleaseTask = Task { @MainActor in
                try? await Task.sleep(for: BookshelfManagementMotion.editBottomInsetReleaseDelay(reduceMotion: reduceMotion))
                guard !Task.isCancelled else { return }
                releaseBottomInsetImmediately()
                isEditingChoreographyActive = false
                bottomInsetReleaseTask = nil
            }
            chromeTransitionTask = nil
        }
    }

    /// 同步外部编辑态变化，保证上下文菜单或页面恢复不会留下过期 chrome 阶段。
    private func syncChromePhaseWithEditingState() {
        guard !isEditingChoreographyActive else { return }
        if viewModel.isEditing, chromePhase == .normal {
            chromePhase = .editing
            cancelBottomInsetRelease()
        } else if !viewModel.isEditing, chromePhase != .normal {
            chromeTransitionTask?.cancel()
            chromeTransitionTask = nil
            chromePhase = .normal
            releaseEditPresentationState()
        }
    }

    /// 取消退场延迟清理，供重新进入编辑态时保持当前有效避让。
    private func cancelBottomInsetRelease() {
        bottomInsetReleaseTask?.cancel()
        bottomInsetReleaseTask = nil
        isRetainingBottomInsetForEditExit = false
    }

    /// 页面离开时立即释放本地避让状态，避免异步退场任务回写已失效页面。
    private func releaseBottomInsetImmediately() {
        bottomInsetReleaseTask?.cancel()
        bottomInsetReleaseTask = nil
        isRetainingBottomInsetForEditExit = false
        bottomContentInset = 0
        bottomOrnamentHeight = 0
    }

    /// 恢复本地展示阶段，供异常进入失败或外部状态同步时收束到普通态。
    private func releaseEditPresentationState() {
        chromePhase = viewModel.isEditing ? .editing : .normal
        isEditingChoreographyActive = false
        chromeTransitionTask = nil
        if !viewModel.isEditing {
            releaseBottomInsetImmediately()
        }
    }

    /// 页面离开时立即清理展示阶段与业务编辑态，避免延迟任务回写已失效页面。
    private func resetEditingPresentationForContextLoss() {
        chromeTransitionTask?.cancel()
        chromeTransitionTask = nil
        chromePhase = .normal
        isEditingChoreographyActive = false
        releaseBottomInsetImmediately()
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
            onOpenNoteRoute(.create(seed: NoteEditorSeed(
                bookId: bookID,
                chapterId: nil,
                contentHTML: "",
                ideaHTML: ""
            )))
        case .pin:
            viewModel.pinBook(bookID)
        case .unpin:
            viewModel.unpinBook(bookID)
        case .editBook:
            onOpenRoute(.edit(bookId: bookID))
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

/// 二级书籍列表 UIKit 集合区，负责滚动、空态和行点击命中。
private struct BookshelfBookListCollectionView: UIViewRepresentable {
    let snapshot: BookshelfBookListSnapshot
    let subtitle: String
    let contentState: BookshelfContentState
    let layoutMode: BookshelfLayoutMode
    let columnCount: Int
    let showsNoteCount: Bool
    let titleDisplayMode: BookshelfTitleDisplayMode
    let isEditing: Bool
    let hasSearchKeyword: Bool
    let searchDrawerHeight: CGFloat
    let searchPresentation: BookshelfBookListSearchPresentation
    let isBrowseSearchFocused: Bool
    let browseSearchKeyword: String
    let browseSearchPlaceholder: String
    let browseSearchFocusTrigger: Int
    let selectedBookIDs: Set<Int64>
    let canReorder: Bool
    let movableBookIDs: Set<Int64>
    let supportsContextPin: Bool
    let activeWriteAction: BookshelfBookListEditAction?
    let bottomContentInset: CGFloat
    let onActivateBrowseSearch: () -> Void
    let onBrowseSearchKeywordChange: (String) -> Void
    let onBrowseSearchFocusChange: (Bool) -> Void
    let onClearBrowseSearch: () -> Void
    let onCollapseBrowseSearch: () -> Void
    let onToggleSelection: (Int64) -> Void
    let onOpenBook: (Int64) -> Void
    let onContextAction: (BookshelfBookContextAction, Int64) -> Void
    let onCommitOrder: ([Int64]) -> Void

    /// 创建 collection view 承载视图。
    func makeUIView(context: Context) -> BookshelfBookListCollectionHostView {
        let view = BookshelfBookListCollectionHostView()
        view.update(with: configuration, animated: false)
        return view
    }

    /// 同步最新路由载荷。
    func updateUIView(_ uiView: BookshelfBookListCollectionHostView, context: Context) {
        uiView.update(with: configuration, animated: true)
    }

    /// 销毁 UIKit 承载视图时清理拖拽缓存。
    static func dismantleUIView(_ uiView: BookshelfBookListCollectionHostView, coordinator: ()) {
        uiView.prepareForReuse()
    }

    private var configuration: BookshelfBookListCollectionConfiguration {
        BookshelfBookListCollectionConfiguration(
            snapshot: snapshot,
            subtitle: subtitle,
            contentState: contentState,
            layoutMode: layoutMode,
            columnCount: max(2, min(columnCount, 4)),
            showsNoteCount: showsNoteCount,
            titleDisplayMode: titleDisplayMode,
            isEditing: isEditing,
            hasSearchKeyword: hasSearchKeyword,
            searchDrawerHeight: searchDrawerHeight,
            searchPresentation: searchPresentation,
            isBrowseSearchFocused: isBrowseSearchFocused,
            browseSearchKeyword: browseSearchKeyword,
            browseSearchPlaceholder: browseSearchPlaceholder,
            browseSearchFocusTrigger: browseSearchFocusTrigger,
            selectedBookIDs: selectedBookIDs,
            canReorder: canReorder,
            movableBookIDs: movableBookIDs,
            supportsContextPin: supportsContextPin,
            activeWriteAction: activeWriteAction,
            bottomContentInset: bottomContentInset,
            onActivateBrowseSearch: onActivateBrowseSearch,
            onBrowseSearchKeywordChange: onBrowseSearchKeywordChange,
            onBrowseSearchFocusChange: onBrowseSearchFocusChange,
            onClearBrowseSearch: onClearBrowseSearch,
            onCollapseBrowseSearch: onCollapseBrowseSearch,
            onToggleSelection: onToggleSelection,
            onOpenBook: onOpenBook,
            onContextAction: onContextAction,
            onCommitOrder: onCommitOrder
        )
    }
}

/// UIKit 集合区输入配置。
private struct BookshelfBookListCollectionConfiguration {
    let snapshot: BookshelfBookListSnapshot
    let subtitle: String
    let contentState: BookshelfContentState
    let layoutMode: BookshelfLayoutMode
    let columnCount: Int
    let showsNoteCount: Bool
    let titleDisplayMode: BookshelfTitleDisplayMode
    let isEditing: Bool
    let hasSearchKeyword: Bool
    let searchDrawerHeight: CGFloat
    let searchPresentation: BookshelfBookListSearchPresentation
    let isBrowseSearchFocused: Bool
    let browseSearchKeyword: String
    let browseSearchPlaceholder: String
    let browseSearchFocusTrigger: Int
    let selectedBookIDs: Set<Int64>
    let canReorder: Bool
    let movableBookIDs: Set<Int64>
    let supportsContextPin: Bool
    let activeWriteAction: BookshelfBookListEditAction?
    let bottomContentInset: CGFloat
    let onActivateBrowseSearch: () -> Void
    let onBrowseSearchKeywordChange: (String) -> Void
    let onBrowseSearchFocusChange: (Bool) -> Void
    let onClearBrowseSearch: () -> Void
    let onCollapseBrowseSearch: () -> Void
    let onToggleSelection: (Int64) -> Void
    let onOpenBook: (Int64) -> Void
    let onContextAction: (BookshelfBookContextAction, Int64) -> Void
    let onCommitOrder: ([Int64]) -> Void

    static let empty = BookshelfBookListCollectionConfiguration(
        snapshot: .empty,
        subtitle: "",
        contentState: .loading,
        layoutMode: .list,
        columnCount: 3,
        showsNoteCount: true,
        titleDisplayMode: .standard,
        isEditing: false,
        hasSearchKeyword: false,
        searchDrawerHeight: 0,
        searchPresentation: .hidden,
        isBrowseSearchFocused: false,
        browseSearchKeyword: "",
        browseSearchPlaceholder: "",
        browseSearchFocusTrigger: 0,
        selectedBookIDs: [],
        canReorder: false,
        movableBookIDs: [],
        supportsContextPin: false,
        activeWriteAction: nil,
        bottomContentInset: 0,
        onActivateBrowseSearch: {},
        onBrowseSearchKeywordChange: { _ in },
        onBrowseSearchFocusChange: { _ in },
        onClearBrowseSearch: {},
        onCollapseBrowseSearch: {},
        onToggleSelection: { _ in },
        onOpenBook: { _ in },
        onContextAction: { _, _ in },
        onCommitOrder: { _ in }
    )

    var showsSearchDrawerInCollection: Bool {
        searchDrawerHeight > 0
    }

    var hasBrowseSearchKeyword: Bool {
        !browseSearchKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isBrowseSearchPinned: Bool {
        searchPresentation.isPinned
    }

    var showsExpandedSearchSurface: Bool {
        searchPresentation.isPinned || hasBrowseSearchKeyword || isBrowseSearchFocused
    }

}

/// 二级书籍列表 item 类型，把 subtitle、empty 与书籍行统一交给 collection view 管理。
private enum BookshelfBookListEmptyState: Hashable {
    case contentEmpty
    case searchEmpty(selectedCount: Int)
    case error(String)

    var icon: String {
        switch self {
        case .contentEmpty:
            return "books.vertical"
        case .searchEmpty:
            return "books.vertical"
        case .error:
            return "exclamationmark.triangle"
        }
    }

    var title: String {
        switch self {
        case .contentEmpty:
            return "暂无书籍"
        case .searchEmpty:
            return "没有匹配的书籍"
        case .error:
            return "书籍加载失败"
        }
    }

    var message: String? {
        switch self {
        case .contentEmpty:
            return nil
        case .searchEmpty(let selectedCount):
            return selectedCount > 0 ? "已选书籍仍保留，清除搜索可继续整理" : "清除搜索后查看全部书籍"
        case .error(let message):
            return message.isEmpty ? "请稍后重试" : message
        }
    }

    var iconColor: Color {
        switch self {
        case .contentEmpty, .searchEmpty:
            return Color.brand.opacity(0.30)
        case .error:
            return Color.feedbackWarning.opacity(0.42)
        }
    }
}

private enum BookshelfBookListCollectionItem: Hashable {
    case searchDrawer
    case loading
    case empty(BookshelfBookListEmptyState)
    case book(BookshelfBookListItem)
}

/// 二级列表网格布局的确定性尺寸，保证 UICollectionView 切换整理态时不依赖 self-sizing 猜测。
private enum BookshelfBookListGridMetrics {
    static func itemHeight(
        containerWidth: CGFloat,
        columnCount: Int,
        titleDisplayMode: BookshelfTitleDisplayMode
    ) -> CGFloat {
        let clampedColumnCount = max(2, min(columnCount, 4))
        let sectionInset = max(0, Spacing.screenEdge / 2)
        let itemHorizontalInset = Spacing.screenEdge / 2
        let availableWidth = max(1, containerWidth - sectionInset * 2)
        let itemWidth = availableWidth / CGFloat(clampedColumnCount)
        let contentWidth = max(1, itemWidth - itemHorizontalInset * 2)
        let coverHeight = XMBookCover.height(forWidth: contentWidth)
        let titleLineCount: CGFloat = titleDisplayMode == .full ? 2 : 1
        let titleHeight = BookshelfTitleTextStyle.captionMedium.lineHeight * titleLineCount
        let authorFont = AppTypography.uiFixed(
            baseSize: 11,
            textStyle: .caption2,
            minimumPointSize: 11
        )
        let authorHeight = ceil(authorFont.lineHeight + 1)
        return ceil(coverHeight + Spacing.half + titleHeight + Spacing.tiny + authorHeight)
    }
}

/// 二级书籍列表 collection 内部 section。
private struct BookshelfBookListCollectionSectionState: Hashable {
    let id: String
    let title: String?
    let items: [BookshelfBookListCollectionItem]
}

/// 二级列表集合视图子类，向承载层暴露系统 automatic inset 与布局周期变化。
private final class BookshelfBookListViewportStableCollectionView: UICollectionView {
    var onAdjustedContentInsetDidChange: (() -> Void)?
    var onBeforeLayoutSubviews: (() -> Void)?
    var onAfterLayoutSubviews: (() -> Void)?

    /// 布局前保存当前可见锚点，避免 safe area 调整后只能拿到跳变后的 cell 位置。
    override func layoutSubviews() {
        onBeforeLayoutSubviews?()
        super.layoutSubviews()
        onAfterLayoutSubviews?()
    }

    /// UIKit 合成后的 adjusted inset 变化时，通知承载层恢复视口锚点。
    override func adjustedContentInsetDidChange() {
        super.adjustedContentInsetDidChange()
        onAdjustedContentInsetDidChange?()
    }
}

/// UICollectionView 承载视图，负责二级列表 grid/list 布局、行点击与组内排序。
private final class BookshelfBookListCollectionHostView: UIView {
    private var configuration = BookshelfBookListCollectionConfiguration.empty
    private var sections: [BookshelfBookListCollectionSectionState] = []
    private var pendingConfiguration: BookshelfBookListCollectionConfiguration?
    private var originalSectionsBeforeDrag: [BookshelfBookListCollectionSectionState] = []
    private var isInteractiveReordering = false
    private var didChangeOrderInCurrentSession = false
    private var didReceiveDropInCurrentSession = false
    private var stableViewportAnchor: ViewportAnchor?
    private var stableFallbackOffsetY: CGFloat = 0
    private var isRestoringViewport = false
    private var isViewportAnchorCaptureSuspended = false
    private var lastAdjustedContentInset: UIEdgeInsets = .zero
    private var didApplyInitialSearchDrawerOffset = false
    private var isPendingInitialSearchDrawerOffset = false
    private var isAdjustingSearchDrawerOffset = false
    private var searchDrawerExtraBottomInset: CGFloat = 0
    private let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let selectionFeedback = UISelectionFeedbackGenerator()

    private lazy var collectionView: BookshelfBookListViewportStableCollectionView = {
        let view = BookshelfBookListViewportStableCollectionView(
            frame: .zero,
            collectionViewLayout: makeLayout(for: configuration)
        )
        view.backgroundColor = .clear
        view.alwaysBounceVertical = true
        view.showsVerticalScrollIndicator = false
        view.contentInsetAdjustmentBehavior = .automatic
        view.keyboardDismissMode = .onDrag
        view.dragInteractionEnabled = false
        view.reorderingCadence = .immediate
        view.dataSource = self
        view.delegate = self
        view.dragDelegate = self
        view.dropDelegate = self
        view.register(
            BookshelfBookListCollectionCell.self,
            forCellWithReuseIdentifier: BookshelfBookListCollectionCell.reuseIdentifier
        )
        view.register(
            BookshelfBookListSearchCell.self,
            forCellWithReuseIdentifier: BookshelfBookListSearchCell.reuseIdentifier
        )
        view.register(
            BookshelfBookListSectionHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: BookshelfBookListSectionHeaderView.reuseIdentifier
        )
        view.onBeforeLayoutSubviews = { [weak self] in
            self?.storeViewportAnchorIfPossible(requiresLayout: false)
        }
        view.onAfterLayoutSubviews = { [weak self] in
            self?.applyPendingInitialSearchDrawerOffsetIfNeeded()
        }
        view.onAdjustedContentInsetDidChange = { [weak self] in
            self?.handleAdjustedContentInsetDidChange()
        }
        return view
    }()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViewHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 同步 SwiftUI 路由载荷到本地 item 列表。
    func update(
        with configuration: BookshelfBookListCollectionConfiguration,
        animated: Bool
    ) {
        if isInteractiveReordering {
            pendingConfiguration = configuration
            return
        }

        storeViewportAnchorIfPossible(requiresLayout: true)
        let previousConfiguration = self.configuration
        let nextSections = Self.makeSections(from: configuration)
        let didChangeSearchDrawerAvailability = configuration.showsSearchDrawerInCollection != previousConfiguration.showsSearchDrawerInCollection
        let needsLayoutUpdate = configuration.layoutMode != self.configuration.layoutMode
            || configuration.columnCount != self.configuration.columnCount
            || configuration.titleDisplayMode != self.configuration.titleDisplayMode
            || didChangeSearchDrawerAvailability
        self.configuration = configuration
        collectionView.dragInteractionEnabled = configuration.canReorder
        normalizeSearchDrawerExtraBottomInsetForCurrentState()
        updateBottomContentInset()
        if needsLayoutUpdate {
            collectionView.setCollectionViewLayout(makeLayout(for: configuration), animated: animated)
        }
        guard nextSections != sections else {
            refreshVisibleCells()
            syncSearchDrawerOffsetAfterUpdate(previousConfiguration: previousConfiguration, animated: animated)
            return
        }
        sections = nextSections
        collectionView.reloadData()
        syncSearchDrawerOffsetAfterUpdate(previousConfiguration: previousConfiguration, animated: animated)
    }

    /// 清理拖拽缓存，供 SwiftUI 销毁或复用承载视图时恢复稳定状态。
    func prepareForReuse() {
        pendingConfiguration = nil
        originalSectionsBeforeDrag = []
        isInteractiveReordering = false
        didChangeOrderInCurrentSession = false
        didReceiveDropInCurrentSession = false
        didApplyInitialSearchDrawerOffset = false
        isPendingInitialSearchDrawerOffset = false
        isAdjustingSearchDrawerOffset = false
        searchDrawerExtraBottomInset = 0
        sections = []
        collectionView.reloadData()
    }
}

private extension BookshelfBookListCollectionHostView {
    /// 建立 collection view 约束。
    func setupViewHierarchy() {
        addSubview(collectionView)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.accessibilityIdentifier = "bookshelf.book-list.collection"

        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    /// 按当前显示设置生成布局；书籍 section 支持确定性网格，其它副标题、加载与空态保持全宽。
    func makeLayout(for configuration: BookshelfBookListCollectionConfiguration) -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            if self?.sectionContainsSearchDrawer(at: sectionIndex) == true {
                return Self.makeSearchDrawerSection(height: configuration.searchDrawerHeight)
            }
            let usesGrid = configuration.layoutMode == .grid
                && (self?.sectionContainsBooks(at: sectionIndex) ?? false)
            let section = usesGrid
                ? Self.makeGridSection(
                    columnCount: configuration.columnCount,
                    containerWidth: environment.container.effectiveContentSize.width,
                    titleDisplayMode: configuration.titleDisplayMode
                )
                : Self.makeListSection()
            if let self,
               self.sections.indices.contains(sectionIndex),
               self.sections[sectionIndex].title != nil {
                let headerSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .estimated(34)
                )
                let header = NSCollectionLayoutBoundarySupplementaryItem(
                    layoutSize: headerSize,
                    elementKind: UICollectionView.elementKindSectionHeader,
                    alignment: .top
                )
                section.boundarySupplementaryItems = [header]
            }
            return section
        }
    }

    /// 只增加滚动余量，不改变 collection layout，避免底部玻璃栏遮挡最后一行书籍。
    func updateBottomContentInset() {
        let bottomInset = resolvedBottomContentInset()
        let didChangeCustomInset = collectionView.contentInset.bottom != bottomInset
            || collectionView.verticalScrollIndicatorInsets.bottom != bottomInset
        let didChangeAdjustedInset = collectionView.adjustedContentInset != lastAdjustedContentInset
        guard didChangeCustomInset || didChangeAdjustedInset else {
            return
        }

        storeViewportAnchorIfPossible(requiresLayout: true)
        let fallbackOffsetY = collectionView.contentOffset.y
        var contentInset = collectionView.contentInset
        contentInset.bottom = bottomInset

        var indicatorInsets = collectionView.verticalScrollIndicatorInsets
        indicatorInsets.bottom = bottomInset

        UIView.performWithoutAnimation {
            isViewportAnchorCaptureSuspended = true
            collectionView.contentInset = contentInset
            collectionView.verticalScrollIndicatorInsets = indicatorInsets
            collectionView.layoutIfNeeded()
            restoreViewportAnchor(stableViewportAnchor, fallbackOffsetY: fallbackOffsetY)
            isViewportAnchorCaptureSuspended = false
            lastAdjustedContentInset = collectionView.adjustedContentInset
            storeViewportAnchorIfPossible(requiresLayout: false)
        }
    }

    /// 根据搜索抽屉当前呈现状态收束额外滚动余量，避免输入态或无抽屉页面继承隐藏位空间。
    func normalizeSearchDrawerExtraBottomInsetForCurrentState() {
        guard configuration.showsSearchDrawerInCollection,
              !configuration.showsExpandedSearchSurface else {
            searchDrawerExtraBottomInset = 0
            return
        }
        searchDrawerExtraBottomInset = max(0, searchDrawerExtraBottomInset)
    }

    /// 合并真实底部浮层避让与搜索抽屉隐藏所需的额外滚动范围；普通态不额外制造安全区尾距。
    func resolvedBottomContentInset() -> CGFloat {
        max(
            0,
            configuration.bottomContentInset,
            searchDrawerExtraBottomInset
        )
    }

    /// 保存当前稳定视口锚点，供后续手动 bottom inset 变化恢复同一可见内容。
    func storeViewportAnchorIfPossible(requiresLayout: Bool) {
        guard !isRestoringViewport, !isViewportAnchorCaptureSuspended else { return }
        stableFallbackOffsetY = collectionView.contentOffset.y
        guard let anchor = captureViewportAnchor(requiresLayout: requiresLayout) else { return }
        stableViewportAnchor = anchor
    }

    /// 响应 adjusted inset 变化，覆盖 UIKit 内部滚动边界更新绕过自定义 inset 写入的路径。
    func handleAdjustedContentInsetDidChange() {
        guard !isRestoringViewport, !isViewportAnchorCaptureSuspended else {
            lastAdjustedContentInset = collectionView.adjustedContentInset
            return
        }
        guard collectionView.window != nil else {
            lastAdjustedContentInset = collectionView.adjustedContentInset
            return
        }
        guard collectionView.adjustedContentInset != lastAdjustedContentInset else { return }

        UIView.performWithoutAnimation {
            restoreViewportAnchor(stableViewportAnchor, fallbackOffsetY: stableFallbackOffsetY)
            lastAdjustedContentInset = collectionView.adjustedContentInset
            storeViewportAnchorIfPossible(requiresLayout: false)
        }
    }

    /// 捕获当前最靠近可视顶部的 cell，作为后续 inset 写入后的视口稳定锚点。
    func captureViewportAnchor(requiresLayout: Bool) -> ViewportAnchor? {
        if requiresLayout {
            collectionView.layoutIfNeeded()
        }
        let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        return collectionView.indexPathsForVisibleItems
            .compactMap { indexPath -> (indexPath: IndexPath, frame: CGRect)? in
                guard let attributes = collectionView.layoutAttributesForItem(at: indexPath),
                      attributes.frame.maxY >= visibleTop - 1 else {
                    return nil
                }
                return (indexPath, attributes.frame)
            }
            .sorted { lhs, rhs in
                if abs(lhs.frame.minY - rhs.frame.minY) > 0.5 {
                    return lhs.frame.minY < rhs.frame.minY
                }
                return lhs.frame.minX < rhs.frame.minX
            }
            .first
            .map { candidate in
                ViewportAnchor(
                    indexPath: candidate.indexPath,
                    distanceFromVisibleTop: candidate.frame.minY - visibleTop
                )
            }
    }

    /// 在 inset 变化后恢复先前捕获的视口锚点，避免 UIKit 自动 inset 补偿造成可见内容跳动。
    func restoreViewportAnchor(_ anchor: ViewportAnchor?, fallbackOffsetY: CGFloat) {
        isRestoringViewport = true
        defer { isRestoringViewport = false }

        let targetOffsetY: CGFloat
        if let anchor,
           let attributes = collectionView.layoutAttributesForItem(at: anchor.indexPath) {
            let visibleTop = attributes.frame.minY - anchor.distanceFromVisibleTop
            targetOffsetY = visibleTop - collectionView.adjustedContentInset.top
        } else {
            targetOffsetY = fallbackOffsetY
        }

        let clampedOffset = CGPoint(
            x: collectionView.contentOffset.x,
            y: clampedContentOffsetY(targetOffsetY)
        )
        guard abs(collectionView.contentOffset.y - clampedOffset.y) > 0.5 else { return }
        collectionView.setContentOffset(clampedOffset, animated: false)
    }

    /// 使用 adjustedContentInset 计算合法滚动边界；系统安全区交给 UIKit，页面只追加真实底部浮层避让。
    func clampedContentOffsetY(_ offsetY: CGFloat) -> CGFloat {
        let adjustedInset = collectionView.adjustedContentInset
        let minimumY = -adjustedInset.top
        let maximumY = max(
            minimumY,
            collectionView.contentSize.height - collectionView.bounds.height + adjustedInset.bottom
        )
        return min(max(offsetY, minimumY), maximumY)
    }

    /// 搜索抽屉刚进入 collection 或退出输入态时，同步列表内容偏移，保持搜索作为同一个列表 surface。
    func syncSearchDrawerOffsetAfterUpdate(
        previousConfiguration: BookshelfBookListCollectionConfiguration,
        animated: Bool
    ) {
        guard !isInteractiveReordering else { return }
        guard configuration.showsSearchDrawerInCollection else {
            didApplyInitialSearchDrawerOffset = false
            isPendingInitialSearchDrawerOffset = false
            return
        }
        if configuration.showsExpandedSearchSurface {
            didApplyInitialSearchDrawerOffset = true
            isPendingInitialSearchDrawerOffset = false
            if !previousConfiguration.showsExpandedSearchSurface {
                setSearchDrawerVisible(animated: animated)
            }
            return
        }
        if previousConfiguration.showsExpandedSearchSurface {
            didApplyInitialSearchDrawerOffset = true
            isPendingInitialSearchDrawerOffset = false
            setSearchDrawerHidden(animated: animated)
            return
        }
        let shouldApplyInitialOffset = !didApplyInitialSearchDrawerOffset
            || !previousConfiguration.showsSearchDrawerInCollection
        guard shouldApplyInitialOffset else { return }
        collectionView.layoutIfNeeded()
        isPendingInitialSearchDrawerOffset = true
        applyPendingInitialSearchDrawerOffsetIfNeeded()
    }

    /// 等 collection 具备稳定内容尺寸后再写入初始 offset，避免首帧被 clamp 回顶部导致抽屉常驻可见。
    func applyPendingInitialSearchDrawerOffsetIfNeeded() {
        guard isPendingInitialSearchDrawerOffset,
              !isInteractiveReordering,
              configuration.showsSearchDrawerInCollection,
              collectionView.window != nil,
              collectionView.bounds.height > 0 else {
            return
        }
        let hiddenOffsetY = hiddenSearchDrawerOffsetY()
        guard hiddenOffsetY > 0 else {
            isPendingInitialSearchDrawerOffset = false
            didApplyInitialSearchDrawerOffset = true
            return
        }
        ensureSearchDrawerHiddenScrollRange()
        let targetY = clampedContentOffsetY(hiddenOffsetY)
        guard targetY >= hiddenOffsetY - 0.5 else {
            return
        }
        setSearchDrawerHidden(animated: false)
        isPendingInitialSearchDrawerOffset = false
        didApplyInitialSearchDrawerOffset = true
    }

    /// 搜索抽屉的隐藏位等于抽屉高度；不改外层手势，只改 collection 自身滚动位置。
    func hiddenSearchDrawerOffsetY() -> CGFloat {
        max(0, configuration.searchDrawerHeight)
    }

    /// 短列表也必须能把搜索抽屉藏到导航下方；这里只扩展滚动范围，不新增手势或覆盖层。
    func ensureSearchDrawerHiddenScrollRange() {
        guard !isInteractiveReordering,
              configuration.showsSearchDrawerInCollection,
              !configuration.showsExpandedSearchSurface,
              collectionView.bounds.height > 0 else {
            return
        }
        let hiddenOffsetY = hiddenSearchDrawerOffsetY()
        guard hiddenOffsetY > 0 else { return }

        let overlayInset = max(0, configuration.bottomContentInset)
        let requiredSearchInset = requiredSearchDrawerBottomInset(for: hiddenOffsetY)
        let nextExtraInset = requiredSearchInset > overlayInset + 0.5 ? requiredSearchInset : 0
        guard abs(nextExtraInset - searchDrawerExtraBottomInset) > 0.5 else { return }

        searchDrawerExtraBottomInset = nextExtraInset
        var contentInset = collectionView.contentInset
        contentInset.bottom = resolvedBottomContentInset()

        var indicatorInsets = collectionView.verticalScrollIndicatorInsets
        indicatorInsets.bottom = contentInset.bottom

        UIView.performWithoutAnimation {
            isViewportAnchorCaptureSuspended = true
            collectionView.contentInset = contentInset
            collectionView.verticalScrollIndicatorInsets = indicatorInsets
            collectionView.layoutIfNeeded()
            isViewportAnchorCaptureSuspended = false
            lastAdjustedContentInset = collectionView.adjustedContentInset
        }
    }

    /// 以系统 adjusted inset 为基准计算搜索抽屉隐藏所需的自定义 bottom inset，避免与现有 inset 互相累加。
    func requiredSearchDrawerBottomInset(for hiddenOffsetY: CGFloat) -> CGFloat {
        collectionView.layoutIfNeeded()
        let systemAdjustedBottomInset = max(
            0,
            collectionView.adjustedContentInset.bottom - collectionView.contentInset.bottom
        )
        let minimumY = -collectionView.adjustedContentInset.top
        let maximumYWithoutCustomBottomInset = max(
            minimumY,
            collectionView.contentSize.height - collectionView.bounds.height + systemAdjustedBottomInset
        )
        let missingRange = hiddenOffsetY - maximumYWithoutCustomBottomInset
        return max(0, ceil(missingRange + 1))
    }

    /// 将列表滚动到搜索 surface 完整可见的位置，不改变搜索所属的 collection 层级。
    func setSearchDrawerVisible(animated: Bool) {
        guard !isInteractiveReordering,
              configuration.showsSearchDrawerInCollection else {
            return
        }
        let targetOffset = CGPoint(
            x: collectionView.contentOffset.x,
            y: clampedContentOffsetY(0)
        )
        guard abs(collectionView.contentOffset.y - targetOffset.y) > 0.5 else { return }

        isAdjustingSearchDrawerOffset = true
        isViewportAnchorCaptureSuspended = true
        let updates = { [collectionView] in
            collectionView.setContentOffset(targetOffset, animated: animated)
        }
        if animated {
            updates()
        } else {
            UIView.performWithoutAnimation(updates)
        }
        releaseSearchDrawerAdjustmentFlag(animated: animated)
    }

    /// 将普通态搜索抽屉收回到书籍列表后方，保持布局尺寸和拖拽排序路径不变。
    func setSearchDrawerHidden(animated: Bool) {
        guard !isInteractiveReordering,
              configuration.showsSearchDrawerInCollection else {
            return
        }
        ensureSearchDrawerHiddenScrollRange()
        let targetOffset = CGPoint(
            x: collectionView.contentOffset.x,
            y: clampedContentOffsetY(hiddenSearchDrawerOffsetY())
        )
        guard abs(collectionView.contentOffset.y - targetOffset.y) > 0.5 else { return }

        isAdjustingSearchDrawerOffset = true
        isViewportAnchorCaptureSuspended = true
        let updates = { [collectionView] in
            collectionView.setContentOffset(targetOffset, animated: animated)
        }
        if animated {
            updates()
        } else {
            UIView.performWithoutAnimation(updates)
        }
        releaseSearchDrawerAdjustmentFlag(animated: animated)
    }

    func releaseSearchDrawerAdjustmentFlag(animated: Bool) {
        if animated {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.28) { [weak self] in
                self?.isAdjustingSearchDrawerOffset = false
                self?.isViewportAnchorCaptureSuspended = false
            }
        } else {
            isAdjustingSearchDrawerOffset = false
            isViewportAnchorCaptureSuspended = false
        }
    }

    /// 下拉抽屉只在普通浏览态、无焦点、无拖拽排序时接管松手后的回弹目标。
    func canSnapSearchDrawerAfterPull() -> Bool {
        configuration.showsSearchDrawerInCollection
            && configuration.searchPresentation == .hidden
            && !configuration.hasBrowseSearchKeyword
            && !configuration.isBrowseSearchFocused
            && !isInteractiveReordering
            && !isAdjustingSearchDrawerOffset
    }

    /// pinned 搜索为空且失焦后，用户继续向上浏览时自动回到隐藏抽屉状态。
    func collapsePinnedSearchIfNeeded(_ scrollView: UIScrollView) {
        guard configuration.isBrowseSearchPinned,
              !configuration.isBrowseSearchFocused,
              !configuration.hasBrowseSearchKeyword,
              configuration.showsSearchDrawerInCollection,
              !isInteractiveReordering,
              scrollView.contentOffset.y > hiddenSearchDrawerOffsetY() * 0.6 else {
            return
        }
        configuration.onCollapseBrowseSearch()
    }

    struct ViewportAnchor {
        let indexPath: IndexPath
        let distanceFromVisibleTop: CGFloat
    }

    /// 二级列表 grid 模式只让真实书籍多列排列，并用绝对高度避免编辑态切换时自适应高度重算错位。
    static func makeGridSection(
        columnCount: Int,
        containerWidth: CGFloat,
        titleDisplayMode: BookshelfTitleDisplayMode
    ) -> NSCollectionLayoutSection {
        let clampedColumnCount = max(2, min(columnCount, 4))
        let itemHeight = BookshelfBookListGridMetrics.itemHeight(
            containerWidth: containerWidth,
            columnCount: clampedColumnCount,
            titleDisplayMode: titleDisplayMode
        )
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0 / CGFloat(clampedColumnCount)),
            heightDimension: .fractionalHeight(1)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        item.contentInsets = NSDirectionalEdgeInsets(
            top: 0,
            leading: Spacing.screenEdge / 2,
            bottom: 0,
            trailing: Spacing.screenEdge / 2
        )

        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .absolute(itemHeight)
        )
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: groupSize,
            repeatingSubitem: item,
            count: clampedColumnCount
        )

        let horizontalInset = max(0, Spacing.screenEdge / 2)
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = Spacing.section
        section.contentInsets = NSDirectionalEdgeInsets(
            top: Spacing.base,
            leading: horizontalInset,
            bottom: Spacing.base,
            trailing: horizontalInset
        )
        return section
    }

    /// 搜索抽屉使用精确高度，作为 collection 内容的一部分由原生滚动露出。
    static func makeSearchDrawerSection(height: CGFloat) -> NSCollectionLayoutSection {
        let resolvedHeight = max(0, height)
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .absolute(resolvedHeight)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .absolute(resolvedHeight)
        )
        let group = NSCollectionLayoutGroup.vertical(layoutSize: groupSize, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = .zero
        section.interGroupSpacing = 0
        return section
    }

    /// 二级列表 list 模式与非书籍 section 使用单列全宽估算高度。
    static func makeListSection() -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .estimated(92)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .estimated(92)
        )
        let group = NSCollectionLayoutGroup.vertical(layoutSize: groupSize, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = Spacing.base
        section.contentInsets = NSDirectionalEdgeInsets(
            top: Spacing.base,
            leading: Spacing.screenEdge,
            bottom: Spacing.base,
            trailing: Spacing.screenEdge
        )
        return section
    }

    /// 根据观察快照生成 collection item。
    static func makeSections(from configuration: BookshelfBookListCollectionConfiguration) -> [BookshelfBookListCollectionSectionState] {
        var nextSections: [BookshelfBookListCollectionSectionState] = []
        if configuration.showsSearchDrawerInCollection {
            nextSections.append(BookshelfBookListCollectionSectionState(
                id: "search-drawer",
                title: nil,
                items: [.searchDrawer]
            ))
        }
        switch configuration.contentState {
        case .loading:
            nextSections.append(BookshelfBookListCollectionSectionState(id: "loading", title: nil, items: [.loading]))
        case .empty:
            let emptyState: BookshelfBookListEmptyState = configuration.hasSearchKeyword
                ? .searchEmpty(selectedCount: configuration.selectedBookIDs.count)
                : .contentEmpty
            nextSections.append(BookshelfBookListCollectionSectionState(id: "empty", title: nil, items: [.empty(emptyState)]))
        case .error(let message):
            nextSections.append(BookshelfBookListCollectionSectionState(
                id: "error",
                title: nil,
                items: [.empty(.error(message))]
            ))
        case .content:
            nextSections.append(contentsOf: configuration.snapshot.sections.map { section in
                BookshelfBookListCollectionSectionState(
                    id: section.id,
                    title: section.title,
                    items: section.books.map(BookshelfBookListCollectionItem.book)
                )
            })
        }
        return nextSections
    }

    /// 刷新可见 cell 中的闭包和选中态，不触发布局重载。
    func refreshVisibleCells() {
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let item = item(at: indexPath) else {
                continue
            }
            if case .searchDrawer = item,
               let cell = collectionView.cellForItem(at: indexPath) as? BookshelfBookListSearchCell {
                cell.configure(with: configuration)
            } else if let cell = collectionView.cellForItem(at: indexPath) as? BookshelfBookListCollectionCell {
                cell.configure(with: item, configuration: configuration)
            }
        }
    }

    func item(at indexPath: IndexPath) -> BookshelfBookListCollectionItem? {
        guard sections.indices.contains(indexPath.section),
              sections[indexPath.section].items.indices.contains(indexPath.item) else {
            return nil
        }
        return sections[indexPath.section].items[indexPath.item]
    }

    /// 判断当前 section 是否包含真实书籍，用于避免副标题/加载/空态进入网格布局。
    func sectionContainsBooks(at sectionIndex: Int) -> Bool {
        guard sections.indices.contains(sectionIndex) else { return false }
        return sections[sectionIndex].items.contains {
            if case .book = $0 { return true }
            return false
        }
    }

    /// 判断当前 section 是否为普通态下拉搜索抽屉，避免其进入网格和排序。
    func sectionContainsSearchDrawer(at sectionIndex: Int) -> Bool {
        guard sections.indices.contains(sectionIndex) else { return false }
        return sections[sectionIndex].items.contains {
            if case .searchDrawer = $0 { return true }
            return false
        }
    }

    /// 判断指定位置是否允许启动组内排序。
    func canBeginReorder(at indexPath: IndexPath) -> Bool {
        guard configuration.canReorder,
              let item = item(at: indexPath),
              case .book(let book) = item else {
            return false
        }
        return configuration.movableBookIDs.contains(book.id)
    }

    /// 记录拖拽开始前的本地快照，取消时可恢复预览顺序。
    func beginReorderSession(at indexPath: IndexPath) {
        guard !isInteractiveReordering else { return }
        isInteractiveReordering = true
        didChangeOrderInCurrentSession = false
        didReceiveDropInCurrentSession = false
        originalSectionsBeforeDrag = sections
        impactFeedback.prepare()
        impactFeedback.impactOccurred(intensity: 0.82)
        selectionFeedback.prepare()
    }

    /// 拖拽结束时决定提交最终顺序或恢复取消前顺序。
    func finishReorderSession() {
        guard isInteractiveReordering else { return }
        let originalIDs = bookIDs(in: originalSectionsBeforeDrag)
        let currentIDs = bookIDs(in: sections)
        let shouldCommit = didReceiveDropInCurrentSession
            && didChangeOrderInCurrentSession
            && originalIDs != currentIDs

        isInteractiveReordering = false
        didChangeOrderInCurrentSession = false
        didReceiveDropInCurrentSession = false

        if shouldCommit {
            configuration.onCommitOrder(currentIDs)
            selectionFeedback.selectionChanged()
            pendingConfiguration = nil
        } else if originalIDs != currentIDs {
            sections = originalSectionsBeforeDrag
            collectionView.reloadData()
        }
        originalSectionsBeforeDrag = []

        if let pendingConfiguration {
            self.pendingConfiguration = nil
            update(with: pendingConfiguration, animated: false)
        }
    }

    /// 将系统建议目标限制在同一个书籍 section 内，避免 subtitle/loading/empty 参与排序。
    func normalizedDestinationIndexPath(
        for proposed: IndexPath?,
        movingBookID: Int64?
    ) -> IndexPath? {
        guard let bookSectionIndex = bookSectionIndex(),
              sections.indices.contains(bookSectionIndex) else {
            return nil
        }
        let itemCount = sections[bookSectionIndex].items.count
        guard itemCount > 0 else { return nil }
        var proposedItem = proposed?.item ?? (itemCount - 1)
        proposedItem = min(max(0, proposedItem), itemCount - 1)
        if let proposed, proposed.section != bookSectionIndex {
            proposedItem = proposed.section < bookSectionIndex ? 0 : itemCount - 1
        }
        if let movingBookID,
           !configuration.movableBookIDs.contains(movingBookID),
           let sourceIndex = bookIndexPath(for: movingBookID) {
            return sourceIndex
        }
        return IndexPath(item: proposedItem, section: bookSectionIndex)
    }

    /// 在 UIKit 本地 section 中执行移动，最终写入由拖拽结束统一提交。
    func applyLocalMove(from sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        guard sourceIndexPath != destinationIndexPath,
              sections.indices.contains(sourceIndexPath.section),
              sections.indices.contains(destinationIndexPath.section),
              sourceIndexPath.section == destinationIndexPath.section,
              sections[sourceIndexPath.section].items.indices.contains(sourceIndexPath.item),
              sections[destinationIndexPath.section].items.indices.contains(destinationIndexPath.item),
              case .book(let book) = sections[sourceIndexPath.section].items[sourceIndexPath.item],
              configuration.movableBookIDs.contains(book.id) else {
            return
        }
        var items = sections[sourceIndexPath.section].items
        let item = items.remove(at: sourceIndexPath.item)
        items.insert(item, at: destinationIndexPath.item)
        sections[sourceIndexPath.section] = BookshelfBookListCollectionSectionState(
            id: sections[sourceIndexPath.section].id,
            title: sections[sourceIndexPath.section].title,
            items: items
        )
        didChangeOrderInCurrentSession = true
        refreshVisibleCells()
    }

    func bookSectionIndex() -> Int? {
        sections.firstIndex { section in
            section.items.contains {
                if case .book = $0 { return true }
                return false
            }
        }
    }

    func bookIndexPath(for bookID: Int64) -> IndexPath? {
        for (sectionIndex, section) in sections.enumerated() {
            for (itemIndex, item) in section.items.enumerated() {
                if case .book(let book) = item, book.id == bookID {
                    return IndexPath(item: itemIndex, section: sectionIndex)
                }
            }
        }
        return nil
    }

    func bookIDs(in sections: [BookshelfBookListCollectionSectionState]) -> [Int64] {
        sections.flatMap(\.items).compactMap { item in
            if case .book(let book) = item { return book.id }
            return nil
        }
    }

    /// 生成 UIKit 右侧分区索引标题，只对真实书籍分区开放，避免副标题/空态进入索引。
    func sectionIndexTitles() -> [String] {
        let titles = sections.compactMap { section -> String? in
            guard let title = section.title,
                  section.items.contains(where: {
                    if case .book = $0 { return true }
                    return false
                  }) else {
                return nil
            }
            return title
        }
        return titles.count > 1 ? titles : []
    }

    /// 按索引标题定位到对应书籍分区的首项。
    func indexPath(forSectionIndexTitle title: String, at index: Int) -> IndexPath {
        let titles = sectionIndexTitles()
        let targetTitle = titles.indices.contains(index) ? titles[index] : title
        if let sectionIndex = sections.firstIndex(where: { $0.title == targetTitle }) {
            return IndexPath(item: 0, section: sectionIndex)
        }
        return IndexPath(item: 0, section: 0)
    }
}

extension BookshelfBookListCollectionHostView: UICollectionViewDataSource {
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        sections.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        sections.indices.contains(section) ? sections[section].items.count : 0
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        if let item = item(at: indexPath),
           case .searchDrawer = item,
           let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: BookshelfBookListSearchCell.reuseIdentifier,
            for: indexPath
           ) as? BookshelfBookListSearchCell {
            cell.configure(with: configuration)
            return cell
        }
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: BookshelfBookListCollectionCell.reuseIdentifier,
            for: indexPath
        ) as? BookshelfBookListCollectionCell else {
            return UICollectionViewCell()
        }
        if let item = item(at: indexPath) {
            cell.configure(with: item, configuration: configuration)
        }
        return cell
    }

    /// 让 UICollectionView 显示系统右侧索引条，对齐 Android 二级列表快速定位的业务效果。
    func indexTitles(for collectionView: UICollectionView) -> [String]? {
        let titles = sectionIndexTitles()
        return titles.isEmpty ? nil : titles
    }

    /// 点击索引标题时滚动到对应分区首个书籍行。
    func collectionView(
        _ collectionView: UICollectionView,
        indexPathForIndexTitle title: String,
        at index: Int
    ) -> IndexPath {
        indexPath(forSectionIndexTitle: title, at: index)
    }

    /// 告知 UICollectionView 哪些二级列表书籍具备系统重排资格。
    func collectionView(_ collectionView: UICollectionView, canMoveItemAt indexPath: IndexPath) -> Bool {
        canBeginReorder(at: indexPath)
    }

    /// 系统立即重排时同步 UIKit 本地数据源，最终落库仍在拖拽结束后统一提交。
    func collectionView(
        _ collectionView: UICollectionView,
        moveItemAt sourceIndexPath: IndexPath,
        to destinationIndexPath: IndexPath
    ) {
        guard let item = item(at: sourceIndexPath),
              case .book(let book) = item,
              let destination = normalizedDestinationIndexPath(
                for: destinationIndexPath,
                movingBookID: book.id
              ) else {
            return
        }
        applyLocalMove(from: sourceIndexPath, to: destination)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        guard kind == UICollectionView.elementKindSectionHeader,
              let header = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: BookshelfBookListSectionHeaderView.reuseIdentifier,
                for: indexPath
              ) as? BookshelfBookListSectionHeaderView,
              sections.indices.contains(indexPath.section),
              let title = sections[indexPath.section].title else {
            return UICollectionReusableView()
        }
        header.configure(title: title)
        return header
    }
}

extension BookshelfBookListCollectionHostView: UICollectionViewDelegate {
    /// 用户或系统滚动后刷新稳定锚点，为后续 safe area / inset 变化保留恢复基准。
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        storeViewportAnchorIfPossible(requiresLayout: false)
        collapsePinnedSearchIfNeeded(scrollView)
    }

    /// 普通态搜索抽屉松手时按原生滚动目标回弹，避免半露出状态显得像布局错误。
    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard canSnapSearchDrawerAfterPull() else { return }
        let hiddenOffsetY = hiddenSearchDrawerOffsetY()
        guard hiddenOffsetY > 0,
              targetContentOffset.pointee.y < hiddenOffsetY else {
            return
        }
        let revealThreshold = hiddenOffsetY * 0.45
        targetContentOffset.pointee.y = clampedContentOffsetY(
            targetContentOffset.pointee.y <= revealThreshold ? 0 : hiddenOffsetY
        )
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = item(at: indexPath) else { return }
        if case .book(let book) = item {
            if configuration.isEditing {
                configuration.onToggleSelection(book.id)
            } else {
                configuration.onOpenBook(book.id)
            }
        }
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        guard let item = item(at: indexPath) else { return false }
        if case .book = item {
            return true
        }
        return false
    }

    /// 重排目标限制在二级列表当前书籍 section 内。
    func collectionView(
        _ collectionView: UICollectionView,
        targetIndexPathForMoveFromItemAt originalIndexPath: IndexPath,
        toProposedIndexPath proposedIndexPath: IndexPath
    ) -> IndexPath {
        guard let item = item(at: originalIndexPath),
              case .book(let book) = item else {
            return originalIndexPath
        }
        return normalizedDestinationIndexPath(
            for: proposedIndexPath,
            movingBookID: book.id
        ) ?? originalIndexPath
    }
}

extension BookshelfBookListCollectionHostView: UICollectionViewDragDelegate {
    /// 仅允许默认分组二级列表普通书籍启动本地长按拖拽排序。
    func collectionView(
        _ collectionView: UICollectionView,
        itemsForBeginning session: UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        guard canBeginReorder(at: indexPath),
              let item = item(at: indexPath),
              case .book(let book) = item else {
            return []
        }
        beginReorderSession(at: indexPath)
        let itemProvider = NSItemProvider(object: NSString(string: "book:\(book.id)"))
        let dragItem = UIDragItem(itemProvider: itemProvider)
        dragItem.localObject = book.id
        return [dragItem]
    }

    /// 拖拽结束后收束本地顺序并决定提交或恢复。
    func collectionView(_ collectionView: UICollectionView, dragSessionDidEnd session: UIDragSession) {
        finishReorderSession()
    }
}

extension BookshelfBookListCollectionHostView: UICollectionViewDropDelegate {
    /// 二级列表排序只接受本地拖拽，拒绝跨应用投递。
    func collectionView(_ collectionView: UICollectionView, canHandle session: UIDropSession) -> Bool {
        session.localDragSession != nil
    }

    /// 声明本地 move + 插入目标，交给系统集合视图处理让位与边缘滚动。
    func collectionView(
        _ collectionView: UICollectionView,
        dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UICollectionViewDropProposal {
        guard session.localDragSession != nil,
              configuration.canReorder else {
            return UICollectionViewDropProposal(operation: .forbidden)
        }
        return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    /// 执行 drop 兜底移动；若系统已在拖拽过程中同步数据源，这里只标记成功结束。
    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        guard let dropItem = coordinator.items.first else { return }
        didReceiveDropInCurrentSession = true

        let movingID = dropItem.dragItem.localObject as? Int64
        guard let movingID,
              let sourceIndexPath = bookIndexPath(for: movingID),
              let destination = normalizedDestinationIndexPath(
                for: coordinator.destinationIndexPath,
                movingBookID: movingID
              ) else {
            return
        }

        if sourceIndexPath != destination {
            collectionView.performBatchUpdates { [weak self] in
                guard let self else { return }
                self.applyLocalMove(from: sourceIndexPath, to: destination)
                collectionView.moveItem(at: sourceIndexPath, to: destination)
            } completion: { [weak self] _ in
                self?.selectionFeedback.selectionChanged()
            }
        }
        coordinator.drop(dropItem.dragItem, toItemAt: destination)
    }
}

/// 二级列表搜索 surface，作为 collection 顶部唯一检索入口承载折叠态和输入态。
private final class BookshelfBookListSearchContainerControl: UIControl {
    var onAccessibilityActivate: () -> Bool = { false }

    override func accessibilityActivate() -> Bool {
        onAccessibilityActivate()
    }
}

/// 二级列表搜索 surface，作为 collection 顶部唯一检索入口承载折叠态和输入态。
private final class BookshelfBookListSearchCell: UICollectionViewCell, UITextFieldDelegate {
    static let reuseIdentifier = "BookshelfBookListSearchCell"

    private let containerControl = BookshelfBookListSearchContainerControl()
    private let materialView = UIVisualEffectView(effect: UIBlurEffect(style: .systemMaterial))
    private let stackView = UIStackView()
    private let iconView = UIImageView(image: UIImage(systemName: "magnifyingglass"))
    private let placeholderLabel = UILabel()
    private let textField = UITextField()
    private let clearButton = UIButton(type: .system)
    private var lastFocusTrigger = 0
    private var onActivate: () -> Void = {}
    private var onTextChange: (String) -> Void = { _ in }
    private var onFocusChange: (Bool) -> Void = { _ in }
    private var onClear: () -> Void = {}
    private var onCollapse: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViewHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        lastFocusTrigger = 0
        onActivate = {}
        onTextChange = { _ in }
        onFocusChange = { _ in }
        onClear = {}
        onCollapse = {}
        textField.text = nil
        textField.resignFirstResponder()
    }

    /// 同步搜索 surface 的折叠/输入状态；关键词回写由闭包交给 ViewModel。
    func configure(with configuration: BookshelfBookListCollectionConfiguration) {
        onActivate = configuration.onActivateBrowseSearch
        onTextChange = configuration.onBrowseSearchKeywordChange
        onFocusChange = configuration.onBrowseSearchFocusChange
        onClear = configuration.onClearBrowseSearch
        onCollapse = configuration.onCollapseBrowseSearch

        let showsInput = configuration.showsExpandedSearchSurface
        placeholderLabel.text = configuration.browseSearchPlaceholder
        textField.placeholder = configuration.browseSearchPlaceholder
        if textField.text != configuration.browseSearchKeyword {
            textField.text = configuration.browseSearchKeyword
        }

        placeholderLabel.isHidden = showsInput
        textField.isHidden = !showsInput
        clearButton.isHidden = !showsInput
        stackView.isUserInteractionEnabled = showsInput
        containerControl.isAccessibilityElement = !showsInput
        containerControl.accessibilityIdentifier = showsInput ? nil : "bookshelf.book-list.search.drawer"
        containerControl.accessibilityTraits = showsInput ? [] : [.button]
        containerControl.accessibilityLabel = showsInput ? nil : configuration.browseSearchPlaceholder
        textField.accessibilityIdentifier = "bookshelf.book-list.search.field"
        clearButton.accessibilityIdentifier = "bookshelf.book-list.search.clear"
        clearButton.accessibilityLabel = configuration.hasBrowseSearchKeyword ? "清除搜索" : "收起搜索"

        if showsInput,
           configuration.browseSearchFocusTrigger > 0,
           configuration.browseSearchFocusTrigger != lastFocusTrigger {
            lastFocusTrigger = configuration.browseSearchFocusTrigger
            DispatchQueue.main.async { [weak self] in
                self?.textField.becomeFirstResponder()
            }
        } else if !showsInput {
            textField.resignFirstResponder()
        }
    }

    private func setupViewHierarchy() {
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        containerControl.translatesAutoresizingMaskIntoConstraints = false
        containerControl.layer.cornerRadius = CornerRadius.blockMedium
        containerControl.layer.cornerCurve = .continuous
        containerControl.layer.borderWidth = CardStyle.borderWidth
        containerControl.layer.borderColor = UIColor(Color.surfaceBorderSubtle).cgColor
        containerControl.clipsToBounds = true
        containerControl.addTarget(self, action: #selector(handleContainerTap), for: .touchUpInside)
        containerControl.onAccessibilityActivate = { [weak self] in
            self?.handleContainerTap()
            return true
        }

        materialView.translatesAutoresizingMaskIntoConstraints = false
        materialView.isUserInteractionEnabled = false

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.tintColor = UIColor.secondaryLabel
        iconView.contentMode = .scaleAspectFit
        iconView.setContentHuggingPriority(.required, for: .horizontal)

        placeholderLabel.font = AppTypography.uiFixed(baseSize: 15, textStyle: .body, minimumPointSize: 15)
        placeholderLabel.adjustsFontForContentSizeCategory = true
        placeholderLabel.textColor = UIColor.secondaryLabel
        placeholderLabel.numberOfLines = 1

        textField.font = AppTypography.uiFixed(baseSize: 15, textStyle: .body, minimumPointSize: 15)
        textField.adjustsFontForContentSizeCategory = true
        textField.textColor = UIColor.label
        textField.tintColor = UIColor(Color.brand)
        textField.borderStyle = .none
        textField.returnKeyType = .search
        textField.autocapitalizationType = .none
        textField.autocorrectionType = .no
        textField.delegate = self
        textField.addTarget(self, action: #selector(handleTextChange), for: .editingChanged)

        clearButton.setImage(UIImage(systemName: "xmark.circle.fill"), for: .normal)
        clearButton.tintColor = UIColor.tertiaryLabel
        clearButton.addTarget(self, action: #selector(handleClearTap), for: .touchUpInside)
        clearButton.setContentHuggingPriority(.required, for: .horizontal)

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.alignment = .center
        stackView.spacing = Spacing.compact
        stackView.isUserInteractionEnabled = false
        stackView.addArrangedSubview(iconView)
        stackView.addArrangedSubview(placeholderLabel)
        stackView.addArrangedSubview(textField)
        stackView.addArrangedSubview(clearButton)

        contentView.addSubview(containerControl)
        containerControl.addSubview(materialView)
        containerControl.addSubview(stackView)

        NSLayoutConstraint.activate([
            containerControl.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Spacing.screenEdge),
            containerControl.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Spacing.screenEdge),
            containerControl.topAnchor.constraint(equalTo: contentView.topAnchor, constant: Spacing.base),
            containerControl.heightAnchor.constraint(greaterThanOrEqualToConstant: 40),

            materialView.leadingAnchor.constraint(equalTo: containerControl.leadingAnchor),
            materialView.trailingAnchor.constraint(equalTo: containerControl.trailingAnchor),
            materialView.topAnchor.constraint(equalTo: containerControl.topAnchor),
            materialView.bottomAnchor.constraint(equalTo: containerControl.bottomAnchor),

            stackView.leadingAnchor.constraint(equalTo: containerControl.leadingAnchor, constant: Spacing.base),
            stackView.trailingAnchor.constraint(equalTo: containerControl.trailingAnchor, constant: -Spacing.base),
            stackView.topAnchor.constraint(equalTo: containerControl.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: containerControl.bottomAnchor),

            iconView.widthAnchor.constraint(equalToConstant: 18),
            iconView.heightAnchor.constraint(equalToConstant: 18),
            clearButton.widthAnchor.constraint(equalToConstant: Spacing.actionReserved),
            clearButton.heightAnchor.constraint(equalToConstant: Spacing.actionReserved)
        ])
    }

    @objc private func handleContainerTap() {
        if textField.isHidden {
            onActivate()
        } else {
            textField.becomeFirstResponder()
        }
    }

    @objc private func handleTextChange() {
        onTextChange(textField.text ?? "")
    }

    @objc private func handleClearTap() {
        if (textField.text ?? "").isEmpty {
            textField.resignFirstResponder()
            onCollapse()
        } else {
            onClear()
        }
    }

    func textFieldDidBeginEditing(_ textField: UITextField) {
        onFocusChange(true)
    }

    func textFieldDidEndEditing(_ textField: UITextField) {
        onFocusChange(false)
    }
}

/// 二级列表分区标题。
private final class BookshelfBookListSectionHeaderView: UICollectionReusableView {
    static let reuseIdentifier = "BookshelfBookListSectionHeaderView"
    private let titleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViewHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 渲染当前分区标题。
    func configure(title: String) {
        titleLabel.text = title
    }

    private func setupViewHierarchy() {
        backgroundColor = .clear
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = UIFont.preferredFont(forTextStyle: .subheadline)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .secondaryLabel
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Spacing.tiny),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Spacing.tiny),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.tiny),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -Spacing.tiny)
        ])
    }
}

/// 二级列表 cell，使用 UIHostingConfiguration 复用 SwiftUI 行视觉。
private final class BookshelfBookListCollectionCell: UICollectionViewCell {
    static let reuseIdentifier = "BookshelfBookListCollectionCell"

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        contentView.backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        contentConfiguration = nil
    }

    /// 渲染当前 item。
    func configure(
        with item: BookshelfBookListCollectionItem,
        configuration: BookshelfBookListCollectionConfiguration
    ) {
        backgroundColor = .clear
        contentConfiguration = nil
        contentConfiguration = UIHostingConfiguration {
            switch item {
            case .searchDrawer:
                EmptyView()
            case .loading:
                BookshelfLoadingSkeletonView(
                    layoutMode: configuration.layoutMode,
                    columnCount: configuration.columnCount,
                    bottomContentInset: configuration.bottomContentInset,
                    accessibilityLabel: "正在整理书籍"
                )
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 520)
            case .empty(let emptyState):
                BookshelfContextualEmptyStateView(
                    icon: emptyState.icon,
                    title: emptyState.title,
                    message: emptyState.message,
                    iconColor: emptyState.iconColor
                )
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 320)
            case .book(let book):
                switch configuration.layoutMode {
                case .grid:
                    BookshelfBookListGridItemView(
                        book: book,
                        showsNoteCount: configuration.showsNoteCount,
                        titleDisplayMode: configuration.titleDisplayMode,
                        isEditing: configuration.isEditing,
                        isSelected: configuration.selectedBookIDs.contains(book.id),
                        supportsContextPin: configuration.supportsContextPin,
                        activeWriteAction: configuration.activeWriteAction,
                        onContextAction: configuration.onContextAction
                    )
                case .list:
                    BookshelfBookListRowView(
                        book: book,
                        showsNoteCount: configuration.showsNoteCount,
                        titleDisplayMode: configuration.titleDisplayMode,
                        isEditing: configuration.isEditing,
                        isSelected: configuration.selectedBookIDs.contains(book.id),
                        supportsContextPin: configuration.supportsContextPin,
                        activeWriteAction: configuration.activeWriteAction,
                        onContextAction: configuration.onContextAction
                    )
                }
            }
        }
        .margins(.all, 0)
    }
}

/// 二级列表普通态本地顶部 chrome，承载返回、标题、显示设置与整理入口。
private struct BookshelfBookListBrowsingChrome: View {
    let title: String
    let canEnterEditing: Bool
    let topBarHeight: CGFloat
    let onBack: () -> Void
    let onShowDisplaySettings: () -> Void
    let onEnterEditing: () -> Void

    var body: some View {
        ZStack {
            Text(title)
                .font(AppTypography.bodyMedium)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.86)
                .padding(.horizontal, BookshelfBookListChromeMetrics.titleHorizontalInset)
                .frame(maxWidth: .infinity)
                .accessibilityAddTraits(.isHeader)

            GlassEffectContainer(spacing: Spacing.double) {
                HStack(spacing: Spacing.cozy) {
                    TopBarBackButton(action: onBack, foregroundColor: Color.textPrimary)
                        .topBarGlassButtonStyle(true)

                    Spacer(minLength: Spacing.compact)

                    actionCluster
                }
            }
        }
        .padding(.horizontal, Spacing.screenEdge)
        .frame(height: topBarHeight)
        .frame(maxWidth: .infinity, alignment: .top)
        .background {
            Color.surfacePage
                .ignoresSafeArea(.container, edges: .top)
        }
        .accessibilityElement(children: .contain)
    }

    private var actionCluster: some View {
        HStack(spacing: Spacing.none) {
            Button(action: onShowDisplaySettings) {
                TopBarActionIcon(
                    systemName: "slider.horizontal.3",
                    foregroundColor: Color.iconPrimary
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("显示设置")

            if canEnterEditing {
                Divider()
                    .frame(height: Spacing.double)
                    .overlay(Color.surfaceBorderSubtle.opacity(0.58))

                Button(action: onEnterEditing) {
                    Text("选择")
                        .font(AppTypography.body)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.86)
                        .frame(minWidth: 58, minHeight: Spacing.actionReserved)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("整理书籍")
            }
        }
        .topBarGlassCapsuleStyle(true)
    }
}

/// 二级列表整理态书籍视觉参数，避免未选项被误读为禁用内容。
private enum BookshelfBookListSelectionVisualStyle {
    static let unselectedEditingOpacity = 0.94
}

/// 仅在浏览态挂载书籍长按菜单，避免整理/排序态的空菜单手势拦截 collection 原生拖拽。
private struct BookshelfBookContextMenuModifier<MenuContent: View>: ViewModifier {
    let isEnabled: Bool
    @ViewBuilder let menuContent: () -> MenuContent

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .contextMenu {
                    menuContent()
                }
                .xmMenuNeutralTint()
        } else {
            content
        }
    }
}

private extension View {
    /// 按页面模式按需挂载书籍长按菜单，保证排序态长按优先进入 collection drag。
    func bookshelfBookContextMenu<MenuContent: View>(
        isEnabled: Bool,
        @ViewBuilder content: @escaping () -> MenuContent
    ) -> some View {
        modifier(BookshelfBookContextMenuModifier(isEnabled: isEnabled, menuContent: content))
    }
}

/// 二级列表 grid 模式书籍卡片，复用书架封面角标与长按菜单语义。
private struct BookshelfBookListGridItemView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let book: BookshelfBookListItem
    let showsNoteCount: Bool
    let titleDisplayMode: BookshelfTitleDisplayMode
    let isEditing: Bool
    let isSelected: Bool
    let supportsContextPin: Bool
    let activeWriteAction: BookshelfBookListEditAction?
    let onContextAction: (BookshelfBookContextAction, Int64) -> Void

    private let coverCornerRadius = CornerRadius.inlaySmall

    var body: some View {
        VStack(alignment: .leading, spacing: Spacing.half) {
            cover

            VStack(alignment: .leading, spacing: Spacing.tiny) {
                BookshelfTitleText(
                    text: book.title,
                    mode: titleDisplayMode,
                    style: .captionMedium,
                    color: .textPrimary
                )

                Text(book.author.isEmpty ? " " : book.author)
                    .font(AppTypography.caption2)
                    .lineLimit(1)
                    .foregroundStyle(Color.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(isEditing ? (isSelected ? 1 : BookshelfBookListSelectionVisualStyle.unselectedEditingOpacity) : 1)
        .overlay(alignment: .topTrailing) {
            if isEditing {
                BookshelfSelectionOverlay(isSelected: isSelected)
                    .transition(selectionOverlayTransition)
            }
        }
        .animation(BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion), value: isEditing)
        .animation(BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion), value: isSelected)
        .contentShape(RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("bookshelf.book-list.book.\(book.id)")
        .bookshelfBookContextMenu(isEnabled: !isEditing) {
            contextMenu
        }
    }

    private var cover: some View {
        XMBookCover.responsive(
            urlString: book.cover,
            cornerRadius: coverCornerRadius,
            border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
            surfaceStyle: .spine
        )
        .overlay {
            ZStack {
                if book.pinned {
                    BookshelfCoverPinBadge(cornerRadius: coverCornerRadius)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                if showsNoteCount, book.noteCount > 0 {
                    BookshelfCoverTextBadge(
                        text: "\(book.noteCount)",
                        placement: .bottomTrailing,
                        tone: .dark,
                        cornerRadius: coverCornerRadius,
                        accessibilityLabel: "\(book.noteCount)条书摘"
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }
            }
        }
    }

    private var selectionOverlayTransition: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.94, anchor: .center))
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button {
            onContextAction(.addNote, book.id)
        } label: {
            XMMenuLabel("添加笔记", systemImage: "square.and.pencil")
        }

        if supportsContextPin {
            if book.pinned {
                Button {
                    onContextAction(.unpin, book.id)
                } label: {
                    XMMenuLabel("取消置顶", systemImage: "pin.slash")
                }
                .disabled(activeWriteAction != nil)
            } else {
                Button {
                    onContextAction(.pin, book.id)
                } label: {
                    XMMenuLabel("置顶", systemImage: "pin")
                }
                .disabled(activeWriteAction != nil)
            }
        }

        Button {
            onContextAction(.editBook, book.id)
        } label: {
            XMMenuLabel("编辑书籍", systemImage: "pencil")
        }

        Button {
            onContextAction(.showReadingDetail, book.id)
        } label: {
            XMMenuLabel("阅读详情", systemImage: "chart.bar.doc.horizontal")
        }

        Button {
            onContextAction(.startReadTiming, book.id)
        } label: {
            XMMenuLabel("开始计时", systemImage: "timer")
        }

        Button {
            onContextAction(.organizeBooks, book.id)
        } label: {
            XMMenuLabel("整理书籍", systemImage: "square.grid.2x2")
        }

        Button(role: .destructive) {
            onContextAction(.delete, book.id)
        } label: {
            Label("删除书籍", systemImage: "trash")
        }
        .disabled(activeWriteAction != nil)
    }

    private var metadata: String {
        let authorText = book.author.isEmpty ? "未知作者" : book.author
        guard showsNoteCount, book.noteCount > 0 else { return authorText }
        return "\(authorText)，\(book.noteCount)条书摘"
    }

    private var accessibilityLabel: String {
        if isEditing {
            return "\(book.title)，\(metadata)，\(isSelected ? "已选中" : "未选中")"
        }
        return "\(book.title)，\(metadata)"
    }
}

/// 二级列表书籍行视觉。
private struct BookshelfBookListRowView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let book: BookshelfBookListItem
    let showsNoteCount: Bool
    let titleDisplayMode: BookshelfTitleDisplayMode
    let isEditing: Bool
    let isSelected: Bool
    let supportsContextPin: Bool
    let activeWriteAction: BookshelfBookListEditAction?
    let onContextAction: (BookshelfBookContextAction, Int64) -> Void

    var body: some View {
        HStack(spacing: Spacing.base) {
            XMBookCover.fixedWidth(
                48,
                urlString: book.cover,
                cornerRadius: CornerRadius.inlaySmall,
                border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                placeholderIconSize: .small,
                surfaceStyle: .spine
            )

            VStack(alignment: .leading, spacing: Spacing.tiny) {
                BookshelfTitleText(
                    text: book.title,
                    mode: titleDisplayMode,
                    style: .bodyMedium,
                    color: .textPrimary
                )

                Text(metadata)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
            }

            Spacer(minLength: Spacing.compact)

            if book.pinned {
                Image(systemName: "pin.fill")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.brand)
            }

            if !isEditing {
                Image(systemName: "chevron.right")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textHint)
            }
        }
        .padding(Spacing.base)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
        }
        .opacity(isEditing ? (isSelected ? 1 : BookshelfBookListSelectionVisualStyle.unselectedEditingOpacity) : 1)
        .overlay(alignment: .topTrailing) {
            if isEditing {
                BookshelfSelectionOverlay(isSelected: isSelected)
                    .transition(selectionOverlayTransition)
            }
        }
        .animation(BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion), value: isEditing)
        .animation(BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion), value: isSelected)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .accessibilityIdentifier("bookshelf.book-list.book.\(book.id)")
        .bookshelfBookContextMenu(isEnabled: !isEditing) {
            contextMenu
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button {
            onContextAction(.addNote, book.id)
        } label: {
            XMMenuLabel("添加笔记", systemImage: "square.and.pencil")
        }

        if supportsContextPin {
            if book.pinned {
                Button {
                    onContextAction(.unpin, book.id)
                } label: {
                    XMMenuLabel("取消置顶", systemImage: "pin.slash")
                }
                .disabled(activeWriteAction != nil)
            } else {
                Button {
                    onContextAction(.pin, book.id)
                } label: {
                    XMMenuLabel("置顶", systemImage: "pin")
                }
                .disabled(activeWriteAction != nil)
            }
        }

        Button {
            onContextAction(.editBook, book.id)
        } label: {
            XMMenuLabel("编辑书籍", systemImage: "pencil")
        }

        Button {
            onContextAction(.showReadingDetail, book.id)
        } label: {
            XMMenuLabel("阅读详情", systemImage: "chart.bar.doc.horizontal")
        }

        Button {
            onContextAction(.startReadTiming, book.id)
        } label: {
            XMMenuLabel("开始计时", systemImage: "timer")
        }

        Button {
            onContextAction(.organizeBooks, book.id)
        } label: {
            XMMenuLabel("整理书籍", systemImage: "square.grid.2x2")
        }

        Button(role: .destructive) {
            onContextAction(.delete, book.id)
        } label: {
            Label("删除书籍", systemImage: "trash")
        }
        .disabled(activeWriteAction != nil)
    }

    private var selectionOverlayTransition: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.94, anchor: .center))
    }

    private var metadata: String {
        let authorText = book.author.isEmpty ? "未知作者" : book.author
        guard showsNoteCount, book.noteCount > 0 else { return authorText }
        return "\(authorText) · \(book.noteCount)条书摘"
    }

    private var accessibilityLabel: String {
        if isEditing {
            return "\(book.title)，\(metadata)，\(isSelected ? "已选中" : "未选中")"
        }
        return "\(book.title)，\(metadata)"
    }
}

/// 二级列表编辑态底部玻璃栏，提供批量管理动作、破坏性操作入口与写入反馈。
private struct BookshelfBookListEditBottomBar: View {
    let selectedCount: Int
    let actions: [BookshelfBookListEditAction]
    let activeAction: BookshelfBookListEditAction?
    let isLoadingOptions: Bool
    let notice: String?
    let onAction: (BookshelfBookListEditAction) -> Void

    var body: some View {
        VStack(spacing: statusText == nil ? Spacing.none : Spacing.tight) {
            if let statusText {
                BookshelfGlassEditStatusText(text: statusText)
            }

            GlassEffectContainer(spacing: Spacing.base) {
                HStack(spacing: Spacing.base) {
                    actionCluster
                        .layoutPriority(1)
                        .opacity(waitingForSelection ? 0.72 : 1)

                    if !destructiveActions.isEmpty {
                        destructiveActionControl
                            .opacity(destructiveActionOpacity)
                    }
                }
            }
        }
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: ImmersiveBottomChromeHeightPreferenceKey.self, value: proxy.size.height)
            }
        }
    }

    private var statusText: String? {
        if let notice, !notice.isEmpty {
            return notice
        }
        if let activeAction {
            return "\(activeAction.title)处理中..."
        }
        if isLoadingOptions {
            return "正在加载批量编辑选项..."
        }
        return nil
    }

    private var isBusy: Bool {
        activeAction != nil || isLoadingOptions
    }

    private var waitingForSelection: Bool {
        selectedCount == 0 && !isBusy
    }

    private var destructiveActionOpacity: Double {
        hasEnabledDestructiveAction ? 1 : (waitingForSelection ? 0.42 : 0.72)
    }

    private var nonDestructiveActions: [BookshelfBookListEditAction] {
        actions.filter { !$0.isDestructive }
    }

    private var destructiveActions: [BookshelfBookListEditAction] {
        actions.filter(\.isDestructive)
    }

    private var actionCluster: some View {
        BookshelfGlassEditActionCluster {
            HStack(spacing: BookshelfGlassEditBarMetrics.itemSpacing) {
                ForEach(nonDestructiveActions) { action in
                    Button {
                        onAction(action)
                    } label: {
                        actionLabel(action)
                    }
                    .buttonStyle(.plain)
                    .disabled(!isEnabled(action))
                    .accessibilityLabel(accessibilityLabel(for: action))
                }
            }
        }
    }

    @ViewBuilder
    private var destructiveActionControl: some View {
        if destructiveActions.count == 1, let action = destructiveActions.first {
            Button(role: .destructive) {
                onAction(action)
            } label: {
                destructiveActionLabel(isEnabled: isEnabled(action))
            }
            .buttonStyle(.plain)
            .disabled(!isEnabled(action))
            .frame(
                width: BookshelfGlassEditBarMetrics.destructiveButtonSize,
                height: BookshelfGlassEditBarMetrics.destructiveButtonSize
            )
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel(accessibilityLabel(for: action))
        } else {
            Menu {
                ForEach(destructiveActions) { action in
                    Button(role: .destructive) {
                        onAction(action)
                    } label: {
                        Label(action.title, systemImage: action.systemImage)
                    }
                    .disabled(!isEnabled(action))
                }
            } label: {
                destructiveActionLabel(isEnabled: hasEnabledDestructiveAction)
            }
            .buttonStyle(.plain)
            .disabled(!hasEnabledDestructiveAction)
            .frame(
                width: BookshelfGlassEditBarMetrics.destructiveButtonSize,
                height: BookshelfGlassEditBarMetrics.destructiveButtonSize
            )
            .glassEffect(.regular.interactive(), in: .circle)
            .accessibilityLabel("删除操作")
        }
    }

    private var hasEnabledDestructiveAction: Bool {
        destructiveActions.contains { isEnabled($0) }
    }

    private func actionLabel(_ action: BookshelfBookListEditAction) -> some View {
        BookshelfGlassEditActionLabel(
            title: action.title,
            systemImage: action.systemImage,
            foregroundStyle: foregroundColor(for: action),
            width: BookshelfGlassEditBarMetrics.bookListActionWidth
        )
    }

    private func destructiveActionLabel(isEnabled: Bool) -> some View {
        ImmersiveBottomChromeIcon(
            systemName: "trash",
            foregroundStyle: destructiveForegroundColor(isEnabled: isEnabled)
        )
    }

    private func foregroundColor(for action: BookshelfBookListEditAction) -> Color {
        if !isEnabled(action) {
            return Color.textSecondary.opacity(waitingForSelection ? 0.42 : 0.55)
        }
        return Color.textPrimary
    }

    private func destructiveForegroundColor(isEnabled: Bool) -> Color {
        if isEnabled {
            return Color.feedbackError
        }
        if waitingForSelection {
            return Color.textSecondary.opacity(0.42)
        }
        return Color.feedbackError.opacity(0.55)
    }

    private func isEnabled(_ action: BookshelfBookListEditAction) -> Bool {
        guard !isBusy else { return false }
        guard action.requiresSelection else { return true }
        return selectedCount > 0
    }

    private func accessibilityLabel(for action: BookshelfBookListEditAction) -> String {
        isEnabled(action) ? action.title : "\(action.title)，当前不可用"
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
