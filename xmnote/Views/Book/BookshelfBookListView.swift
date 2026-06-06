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
    @State private var browseSearchDraftKeyword = ""
    @State private var browseSearchFocusTrigger = 0
    @State private var readLoadingGate = LoadingGate()

    var body: some View {
        VStack(spacing: Spacing.none) {
            topChrome
                .zIndex(1)
            collectionContent
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
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
                .transition(BookshelfManagementMotion.bookListTopChromeTransition(reduceMotion: reduceMotion))
            }

            if chromePhase.showsEditHeader {
                BookshelfEditChrome(
                    selectedBookCount: viewModel.selectedCount,
                    selectionScope: .booksOnly,
                    isAllVisibleSelected: viewModel.isAllVisibleSelected,
                    isSelectionToggleEnabled: !viewModel.visibleBookIDs.isEmpty,
                    searchState: editSearchState,
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
                            notice: editBottomBarNotice,
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
        "搜索书名或作者"
    }

    private var editSearchState: BookshelfEditChromeSearchState {
        viewModel.hasSearchKeyword ? .active(resultCount: viewModel.visibleBookIDs.count) : .inactive
    }

    private var editBottomBarNotice: String? {
        if let notice = viewModel.actionNotice, !notice.isEmpty {
            return notice
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
            || browseSearchPresentation.isPinned
            || isBrowseSearchFocused
    }

    private var hasBrowseSearchDraftKeyword: Bool {
        !browseSearchDraftKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
                bottomContentInset: bottomContentInset,
                onActivateBrowseSearch: activateBrowseSearch,
                onRequestBrowseSearchFocus: requestBrowseSearchFocus,
                onBrowseSearchKeywordChange: updateBrowseSearchKeyword(_:),
                onSubmitBrowseSearch: submitBrowseSearch(_:),
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

    /// 进入整理模式时先切换顶部 chrome，再延迟抬起底部批量栏。
    /// - Note: 所有展示状态都在 MainActor 修改；阶段任务会被后续进入/退出请求取消，避免旧动画回写新页面状态。
    private func enterEditingWithChoreography() {
        guard viewModel.canEnterEditing else { return }
        chromeTransitionTask?.cancel()
        cancelBottomInsetRelease()
        isEditingChoreographyActive = true
        prepareBrowseSearchForEditing()

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
        if browseSearchDraftKeyword.isEmpty, viewModel.hasSearchKeyword {
            browseSearchDraftKeyword = viewModel.searchKeyword
        }
        withAnimation(BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion)) {
            browseSearchPresentation = .pinned
        }
    }

    private func requestBrowseSearchFocus() {
        browseSearchFocusTrigger += 1
    }

    private func updateBrowseSearchKeyword(_ keyword: String) {
        let normalizedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        browseSearchDraftKeyword = keyword
        if normalizedKeyword.isEmpty {
            viewModel.clearSearchKeyword()
        } else if viewModel.searchKeyword != normalizedKeyword {
            viewModel.searchKeyword = normalizedKeyword
        }
        browseSearchPresentation = .pinned
    }

    private func submitBrowseSearch(_ keyword: String) {
        let submittedKeyword = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        browseSearchDraftKeyword = submittedKeyword
        if submittedKeyword.isEmpty {
            viewModel.clearSearchKeyword()
        } else {
            if viewModel.searchKeyword != submittedKeyword {
                viewModel.searchKeyword = submittedKeyword
            }
            browseSearchPresentation = .pinned
        }
    }

    private func handleBrowseSearchFocusChange(_ isFocused: Bool) {
        isBrowseSearchFocused = isFocused
        if isFocused {
            if browseSearchPresentation != .pinned {
                browseSearchPresentation = .pinned
            }
        } else if !hasBrowseSearchDraftKeyword, !viewModel.hasSearchKeyword {
            browseSearchPresentation = .hidden
        }
    }

    private func clearBrowseSearch() {
        browseSearchDraftKeyword = ""
        viewModel.clearSearchKeyword()
        withAnimation(BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion)) {
            browseSearchPresentation = .pinned
            browseSearchFocusTrigger += 1
        }
    }

    private func collapseBrowseSearch() {
        browseSearchDraftKeyword = ""
        viewModel.clearSearchKeyword()
        withAnimation(BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion)) {
            browseSearchPresentation = .hidden
            isBrowseSearchFocused = false
        }
    }

    /// 进入整理态时收起空搜索；有关键词时保留过滤结果但取消键盘焦点。
    private func prepareBrowseSearchForEditing() {
        isBrowseSearchFocused = false
        if viewModel.hasSearchKeyword {
            browseSearchDraftKeyword = viewModel.searchKeyword
            browseSearchPresentation = .pinned
        } else {
            browseSearchDraftKeyword = ""
            viewModel.clearSearchKeyword()
            browseSearchPresentation = .hidden
        }
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
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
    let browseSearchText: String
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
    let onRequestBrowseSearchFocus: () -> Void
    let onBrowseSearchKeywordChange: (String) -> Void
    let onSubmitBrowseSearch: (String) -> Void
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
            browseSearchText: browseSearchText,
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
            onRequestBrowseSearchFocus: onRequestBrowseSearchFocus,
            onBrowseSearchKeywordChange: onBrowseSearchKeywordChange,
            onSubmitBrowseSearch: onSubmitBrowseSearch,
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
    let browseSearchText: String
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
    let onRequestBrowseSearchFocus: () -> Void
    let onBrowseSearchKeywordChange: (String) -> Void
    let onSubmitBrowseSearch: (String) -> Void
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
        browseSearchText: "",
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
        onRequestBrowseSearchFocus: {},
        onBrowseSearchKeywordChange: { _ in },
        onSubmitBrowseSearch: { _ in },
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

    var hasBrowseSearchText: Bool {
        !browseSearchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var isBrowseSearchPinned: Bool {
        searchPresentation.isPinned
    }

    var showsExpandedSearchSurface: Bool {
        searchPresentation.isPinned || hasBrowseSearchText || hasBrowseSearchKeyword || isBrowseSearchFocused
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
        case .contentEmpty:
            return Color.brand.opacity(0.32)
        case .searchEmpty:
            return Color.brand.opacity(0.40)
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

/// 搜索结果区的粗粒度状态，用于决定结构动效是内容补位还是空态稳定刷新。
private enum BookshelfBookListResultState: Equatable {
    case content
    case empty
    case loading
    case error
    case other
}

/// 二级列表搜索结果切换类型，避免空态重复查询误触发布局位移动画。
private enum BookshelfBookListResultTransition: Equatable {
    case contentToEmpty
    case emptyToContent
    case contentToContent
    case emptyToEmpty
    case other
}

/// 空态 SwiftUI 容器的呈现模式；重复无结果更新必须保持位置稳定。
private enum BookshelfBookListEmptyPresentationMode: Hashable {
    case enteringFromContent
    case steadyEmptyUpdate
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

/// 二级书籍列表非网格内容的确定性尺寸，避免 estimated self-sizing 在状态切换中二次测量。
private enum BookshelfBookListLayoutMetrics {
    static let listRowHeight: CGFloat = 92
    static let loadingHeight: CGFloat = 520
    static let emptyHeight: CGFloat = 320
    static let sectionHeaderHeight: CGFloat = 34
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
    var onDidMoveToWindow: (() -> Void)?

    /// 布局前保存当前可见锚点，避免 safe area 调整后只能拿到跳变后的 cell 位置。
    override func layoutSubviews() {
        onBeforeLayoutSubviews?()
        super.layoutSubviews()
        onAfterLayoutSubviews?()
    }

    /// 进入窗口时立即收敛初始滚动位置，避免导航转场首帧暴露隐藏搜索抽屉。
    override func didMoveToWindow() {
        super.didMoveToWindow()
        onDidMoveToWindow?()
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
    private var keyboardAvoidanceInset: CGFloat = 0
    private var searchDrawerLockedOffsetY: CGFloat?
    private let searchFocusRequestCoordinator = BookshelfSearchFocusRequestCoordinator()
    private var lastCollectionBounds: CGRect = .zero
    private var pendingAnimatedInsertionIdentities: Set<ViewportAnchorIdentity> = []
    private var emptyPresentationMode: BookshelfBookListEmptyPresentationMode = .steadyEmptyUpdate
    private var isContentToEmptyTransitionPending = false
    private var contentToEmptyTransitionGeneration = 0
    private var pendingContentToEmptySections: [BookshelfBookListCollectionSectionState]?
    private let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let selectionFeedback = UISelectionFeedbackGenerator()
    private lazy var keyboardAvoidanceCoordinator = BookshelfCollectionKeyboardAvoidanceCoordinator(
        hostView: self,
        scrollView: collectionView
    ) { [weak self] inset, animation in
        self?.applyKeyboardAvoidanceInset(inset, animation: animation)
    }

    private lazy var collectionView: BookshelfBookListViewportStableCollectionView = {
        let view = BookshelfBookListViewportStableCollectionView(
            frame: .zero,
            collectionViewLayout: makeLayout(for: configuration)
        )
        view.backgroundColor = .clear
        view.alpha = 0
        view.transform = CGAffineTransform(translationX: 0, y: 6)
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
        view.onDidMoveToWindow = { [weak self] in
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
        keyboardAvoidanceCoordinator.start()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        keyboardAvoidanceCoordinator.invalidate()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reconcileCollectionBoundsIfNeeded()
        keyboardAvoidanceCoordinator.recalculate(animated: false)
        applyPendingInitialSearchDrawerOffsetIfNeeded()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        keyboardAvoidanceCoordinator.recalculate(animated: false)
        applyPendingInitialSearchDrawerOffsetIfNeeded()
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
        let previousSections = sections
        let nextSections = Self.makeSections(from: configuration)
        let resultTransition = Self.resultTransition(from: previousSections, to: nextSections)
        let needsLayoutUpdate = configuration.layoutMode != previousConfiguration.layoutMode
            || configuration.columnCount != previousConfiguration.columnCount
            || configuration.titleDisplayMode != previousConfiguration.titleDisplayMode
        let needsLayoutInvalidation = needsLayoutUpdate
            || configuration.searchDrawerHeight != previousConfiguration.searchDrawerHeight
        self.configuration = configuration
        searchFocusRequestCoordinator.reconcile(
            isFocused: configuration.isBrowseSearchFocused,
            isExpanded: configuration.showsExpandedSearchSurface
        )
        updateCollectionVisibilityForSearchDrawerPreparation()
        collectionView.dragInteractionEnabled = configuration.canReorder
        normalizeSearchDrawerExtraBottomInsetForCurrentState()
        updateBottomContentInset(
            animated: animated
                && collectionView.window != nil
                && abs(previousConfiguration.bottomContentInset - configuration.bottomContentInset) > 0.5
        )
        if needsLayoutUpdate {
            collectionView.setCollectionViewLayout(
                makeLayout(for: configuration),
                animated: animated && collectionView.window != nil
            )
        } else if needsLayoutInvalidation {
            collectionView.collectionViewLayout.invalidateLayout()
        }
        if isContentToEmptyTransitionPending,
           Self.resultState(in: nextSections) == .empty {
            pendingContentToEmptySections = nextSections
            refreshSearchDrawerCellOnly()
            syncSearchDrawerOffsetAfterUpdate(previousConfiguration: previousConfiguration, animated: animated)
            return
        } else if isContentToEmptyTransitionPending {
            cancelPendingContentToEmptyTransition()
        }
        guard nextSections != sections else {
            refreshVisibleCells(
                for: resultTransition,
                refreshEmptyCells: resultTransition != .emptyToEmpty
            )
            syncSearchDrawerOffsetAfterUpdate(previousConfiguration: previousConfiguration, animated: animated)
            return
        }
        let fallbackOffsetY = collectionView.contentOffset.y
        if !needsLayoutUpdate,
           applyAnimatedSectionUpdate(
            from: previousSections,
            to: nextSections,
            transition: resultTransition,
            animated: animated
           ) {
            syncSearchDrawerOffsetAfterUpdate(previousConfiguration: previousConfiguration, animated: animated)
            return
        }
        emptyPresentationMode = Self.emptyPresentationMode(for: resultTransition)
        sections = nextSections
        reloadCollectionPreservingViewport(
            fallbackOffsetY: fallbackOffsetY,
            animated: animated && collectionView.window != nil && !needsLayoutUpdate
        )
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
        keyboardAvoidanceInset = 0
        searchDrawerLockedOffsetY = nil
        searchFocusRequestCoordinator.cancel()
        lastCollectionBounds = .zero
        keyboardAvoidanceCoordinator.reset()
        pendingAnimatedInsertionIdentities = []
        emptyPresentationMode = .steadyEmptyUpdate
        isContentToEmptyTransitionPending = false
        contentToEmptyTransitionGeneration += 1
        pendingContentToEmptySections = nil
        sections = []
        collectionView.alpha = 0
        collectionView.transform = CGAffineTransform(translationX: 0, y: 6)
        collectionView.isUserInteractionEnabled = true
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

    /// collection 尺寸变化时只重算布局与滚动边界，不把搜索结果重置成另一套页面状态。
    func reconcileCollectionBoundsIfNeeded() {
        let bounds = collectionView.bounds
        guard bounds.width > 0, bounds.height > 0 else { return }
        let previousBounds = lastCollectionBounds
        guard previousBounds == .zero
            || abs(previousBounds.width - bounds.width) > 0.5
            || abs(previousBounds.height - bounds.height) > 0.5 else {
            return
        }

        lastCollectionBounds = bounds
        guard previousBounds != .zero else { return }
        storeViewportAnchorIfPossible(requiresLayout: false)
        collectionView.collectionViewLayout.invalidateLayout()
        updateBottomContentInset(animated: false)
        applyPendingInitialSearchDrawerOffsetIfNeeded()
        storeViewportAnchorIfPossible(requiresLayout: false)
    }

    /// 接收统一键盘协调器给出的自定义避让高度，并进入二级列表现有 bottom inset 管线。
    func applyKeyboardAvoidanceInset(
        _ inset: CGFloat,
        animation: BookshelfCollectionKeyboardAvoidanceCoordinator.AnimationContext
    ) {
        guard abs(keyboardAvoidanceInset - inset) > 0.5 else { return }
        keyboardAvoidanceInset = inset
        updateBottomContentInset(animation: animation)
    }

    private var defaultBottomInsetAnimationContext: BookshelfCollectionKeyboardAvoidanceCoordinator.AnimationContext {
        BookshelfCollectionKeyboardAvoidanceCoordinator.AnimationContext(
            duration: BookshelfManagementMotion.bookListSearchDrawerDuration,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseInOut]
        )
    }

    /// 初始隐藏搜索抽屉时先等滚动位置收敛，避免用户看到抽屉从首帧闪出再被推走。
    func updateCollectionVisibilityForSearchDrawerPreparation() {
        let shouldHideUntilOffsetSettles = configuration.showsSearchDrawerInCollection
            && !configuration.showsExpandedSearchSurface
            && !didApplyInitialSearchDrawerOffset
        let targetAlpha: CGFloat = shouldHideUntilOffsetSettles ? 0 : 1
        let targetTransform = shouldHideUntilOffsetSettles
            ? CGAffineTransform(translationX: 0, y: 6)
            : .identity
        collectionView.isUserInteractionEnabled = !shouldHideUntilOffsetSettles
        guard abs(collectionView.alpha - targetAlpha) > 0.01 || collectionView.transform != targetTransform else {
            return
        }
        if shouldHideUntilOffsetSettles || collectionView.window == nil {
            collectionView.alpha = targetAlpha
            collectionView.transform = targetTransform
            return
        }
        UIView.animate(
            withDuration: BookshelfManagementMotion.bookListInitialRevealDuration,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]
        ) {
            self.collectionView.alpha = targetAlpha
            self.collectionView.transform = targetTransform
        }
    }

    /// 从 section 快照识别结果区状态，忽略搜索抽屉这类 chrome section。
    static func resultState(in sections: [BookshelfBookListCollectionSectionState]) -> BookshelfBookListResultState {
        let resultSections = sections.filter { $0.id != "search-drawer" }
        guard !resultSections.isEmpty else { return .other }
        if resultSections.contains(where: { $0.id == "loading" }) {
            return .loading
        }
        if resultSections.contains(where: { $0.id == "error" }) {
            return .error
        }
        if resultSections.contains(where: { $0.id == "empty" }) {
            return .empty
        }
        if resultSections.contains(where: { section in
            section.items.contains {
                if case .book = $0 { return true }
                return false
            }
        }) {
            return .content
        }
        return .other
    }

    /// 将前后结果状态转换为动效意图，避免把重复无结果输入误当作结构变化。
    static func resultTransition(
        from previousSections: [BookshelfBookListCollectionSectionState],
        to nextSections: [BookshelfBookListCollectionSectionState]
    ) -> BookshelfBookListResultTransition {
        switch (resultState(in: previousSections), resultState(in: nextSections)) {
        case (.content, .empty):
            return .contentToEmpty
        case (.empty, .content):
            return .emptyToContent
        case (.content, .content):
            return .contentToContent
        case (.empty, .empty):
            return .emptyToEmpty
        default:
            return .other
        }
    }

    /// 只有内容首次筛成空态时允许空态上浮进入，重复空态更新必须保持稳定。
    static func emptyPresentationMode(
        for transition: BookshelfBookListResultTransition
    ) -> BookshelfBookListEmptyPresentationMode {
        transition == .contentToEmpty ? .enteringFromContent : .steadyEmptyUpdate
    }

    /// 取消尚未提交的内容退场动画，避免快速清空关键词时旧 completion 覆盖新结果。
    func cancelPendingContentToEmptyTransition() {
        isContentToEmptyTransitionPending = false
        contentToEmptyTransitionGeneration += 1
        pendingContentToEmptySections = nil
        for cell in collectionView.visibleCells {
            cell.layer.removeAllAnimations()
            cell.alpha = 1
            cell.transform = .identity
        }
    }

    /// 搜索过滤和空态切换优先走批量更新，保留书籍补位关系；复杂状态仍交给受控 reload 兜底。
    func applyAnimatedSectionUpdate(
        from previousSections: [BookshelfBookListCollectionSectionState],
        to nextSections: [BookshelfBookListCollectionSectionState],
        transition: BookshelfBookListResultTransition,
        animated: Bool
    ) -> Bool {
        guard animated,
              collectionView.window != nil,
              !previousSections.isEmpty,
              canAnimateTransition(from: previousSections, to: nextSections) else {
            return false
        }
        emptyPresentationMode = Self.emptyPresentationMode(for: transition)
        if transition == .emptyToEmpty {
            sections = nextSections
            refreshVisibleCells(for: transition, refreshEmptyCells: true)
            return true
        }
        if transition == .contentToEmpty {
            return applyContentToEmptyTransition(from: previousSections, to: nextSections)
        }
        if sectionIDs(in: previousSections) == sectionIDs(in: nextSections) {
            return applyAnimatedItemUpdate(
                from: previousSections,
                to: nextSections,
                transition: transition
            )
        }
        return applyAnimatedSectionReplacement(
            from: previousSections,
            to: nextSections,
            transition: transition
        )
    }

    /// 判断本次数据变化是否属于搜索结果/空态这类可安全批量更新的结构切换。
    func canAnimateTransition(
        from previousSections: [BookshelfBookListCollectionSectionState],
        to nextSections: [BookshelfBookListCollectionSectionState]
    ) -> Bool {
        let disallowedIDs: Set<String> = ["loading", "error"]
        return previousSections.allSatisfy { !disallowedIDs.contains($0.id) }
            && nextSections.allSatisfy { !disallowedIDs.contains($0.id) }
            && hasUniqueItemIdentities(in: previousSections)
            && hasUniqueItemIdentities(in: nextSections)
    }

    /// 在 section 结构稳定时按 item 身份执行插入、删除和移动动画。
    func applyAnimatedItemUpdate(
        from previousSections: [BookshelfBookListCollectionSectionState],
        to nextSections: [BookshelfBookListCollectionSectionState],
        transition: BookshelfBookListResultTransition
    ) -> Bool {
        var deletions: [IndexPath] = []
        var insertions: [IndexPath] = []
        var moves: [(from: IndexPath, to: IndexPath)] = []
        var insertedIdentities = Set<ViewportAnchorIdentity>()

        for sectionIndex in previousSections.indices {
            let previousIdentities = previousSections[sectionIndex].items.map(anchorIdentity(for:))
            let nextIdentities = nextSections[sectionIndex].items.map(anchorIdentity(for:))
            let diff = nextIdentities.difference(from: previousIdentities).inferringMoves()
            for change in diff {
                switch change {
                case let .remove(offset, _, associatedWith):
                    if let destination = associatedWith {
                        moves.append((
                            from: IndexPath(item: offset, section: sectionIndex),
                            to: IndexPath(item: destination, section: sectionIndex)
                        ))
                    } else {
                        deletions.append(IndexPath(item: offset, section: sectionIndex))
                    }
                case let .insert(offset, identity, associatedWith):
                    if associatedWith == nil {
                        insertions.append(IndexPath(item: offset, section: sectionIndex))
                        insertedIdentities.insert(identity)
                    }
                }
            }
        }

        guard !deletions.isEmpty || !insertions.isEmpty || !moves.isEmpty else {
            sections = nextSections
            refreshVisibleCells(for: transition, refreshEmptyCells: true)
            return true
        }

        pendingAnimatedInsertionIdentities.formUnion(insertedIdentities)
        sections = nextSections
        collectionView.performBatchUpdates {
            if !deletions.isEmpty {
                collectionView.deleteItems(at: deletions)
            }
            if !insertions.isEmpty {
                collectionView.insertItems(at: insertions)
            }
            for move in moves {
                collectionView.moveItem(at: move.from, to: move.to)
            }
        } completion: { [weak self] _ in
            self?.pendingAnimatedInsertionIdentities.subtract(insertedIdentities)
            self?.refreshVisibleCells(for: transition, refreshEmptyCells: true)
        }
        return true
    }

    /// 搜索结果从内容变为空态时，先让可见书籍短退场，再让空态接管结果区。
    func applyContentToEmptyTransition(
        from previousSections: [BookshelfBookListCollectionSectionState],
        to nextSections: [BookshelfBookListCollectionSectionState]
    ) -> Bool {
        let generation = contentToEmptyTransitionGeneration + 1
        contentToEmptyTransitionGeneration = generation
        isContentToEmptyTransitionPending = true
        pendingContentToEmptySections = nextSections
        emptyPresentationMode = .enteringFromContent

        let visibleCells = visibleBookCells(in: previousSections)
        let commitReplacement = { [weak self] in
            guard let self,
                  self.isContentToEmptyTransitionPending,
                  self.contentToEmptyTransitionGeneration == generation else {
                return
            }
            let committedSections = self.pendingContentToEmptySections ?? nextSections
            self.pendingContentToEmptySections = nil
            self.isContentToEmptyTransitionPending = false
            self.emptyPresentationMode = .enteringFromContent
            _ = self.applyAnimatedSectionReplacement(
                from: previousSections,
                to: committedSections,
                transition: .contentToEmpty,
                suppressDefaultAnimation: true
            )
        }

        guard !UIAccessibility.isReduceMotionEnabled,
              !visibleCells.isEmpty else {
            commitReplacement()
            return true
        }

        UIView.animate(
            withDuration: BookshelfManagementMotion.bookListResultExitDuration,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseIn]
        ) {
            for cell in visibleCells {
                cell.alpha = 0
                cell.transform = CGAffineTransform(translationX: 0, y: 8).scaledBy(x: 0.985, y: 0.985)
            }
        } completion: { _ in
            commitReplacement()
        }
        return true
    }

    /// 取出真实书籍 cell，避免搜索框和空态参与内容筛除退场。
    func visibleBookCells(
        in previousSections: [BookshelfBookListCollectionSectionState]
    ) -> [UICollectionViewCell] {
        collectionView.indexPathsForVisibleItems.compactMap { indexPath in
            guard previousSections.indices.contains(indexPath.section),
                  previousSections[indexPath.section].items.indices.contains(indexPath.item),
                  case .book = previousSections[indexPath.section].items[indexPath.item] else {
                return nil
            }
            return collectionView.cellForItem(at: indexPath)
        }
    }

    /// 在搜索结果与空态互换时保留共同前缀 section，只替换实际内容区。
    func applyAnimatedSectionReplacement(
        from previousSections: [BookshelfBookListCollectionSectionState],
        to nextSections: [BookshelfBookListCollectionSectionState],
        transition: BookshelfBookListResultTransition,
        suppressDefaultAnimation: Bool = false
    ) -> Bool {
        let commonPrefixCount = zip(previousSections, nextSections)
            .prefix { $0.0.id == $0.1.id }
            .count
        guard commonPrefixCount < previousSections.count || commonPrefixCount < nextSections.count else {
            return false
        }
        let deletedSections = IndexSet(integersIn: commonPrefixCount..<previousSections.count)
        let insertedSections = IndexSet(integersIn: commonPrefixCount..<nextSections.count)
        let insertedIdentities = Set(nextSections[commonPrefixCount...].flatMap { section in
            section.items.compactMap { item -> ViewportAnchorIdentity? in
                if case .book = item {
                    return anchorIdentity(for: item)
                }
                return nil
            }
        })

        pendingAnimatedInsertionIdentities.formUnion(insertedIdentities)
        sections = nextSections
        let updates = {
            if !deletedSections.isEmpty {
                self.collectionView.deleteSections(deletedSections)
            }
            if !insertedSections.isEmpty {
                self.collectionView.insertSections(insertedSections)
            }
        }
        let completion: (Bool) -> Void = { [weak self] _ in
            self?.pendingAnimatedInsertionIdentities.subtract(insertedIdentities)
            self?.refreshVisibleCells(for: transition, refreshEmptyCells: true)
        }
        if suppressDefaultAnimation {
            UIView.performWithoutAnimation {
                collectionView.performBatchUpdates(updates, completion: completion)
            }
        } else {
            collectionView.performBatchUpdates(updates, completion: completion)
        }
        return true
    }

    /// 对无法安全 diff 的状态做受控刷新，并尽量保留刷新前的可见锚点。
    func reloadCollectionPreservingViewport(fallbackOffsetY: CGFloat, animated: Bool) {
        let updates = {
            self.collectionView.reloadData()
            self.collectionView.layoutIfNeeded()
            self.restoreViewportAnchor(self.stableViewportAnchor, fallbackOffsetY: fallbackOffsetY)
        }
        guard animated else {
            UIView.performWithoutAnimation(updates)
            return
        }
        UIView.transition(
            with: collectionView,
            duration: BookshelfManagementMotion.bookListResultTransitionDuration,
            options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState]
        ) {
            updates()
        }
    }

    /// 提取 section 稳定身份，用于判断是否可以走 item 级批量更新。
    func sectionIDs(in sections: [BookshelfBookListCollectionSectionState]) -> [String] {
        sections.map(\.id)
    }

    /// 确保批量更新身份唯一，避免 UICollectionView 同一轮 diff 中出现歧义。
    func hasUniqueItemIdentities(in sections: [BookshelfBookListCollectionSectionState]) -> Bool {
        let identities = sections.flatMap { section in
            section.items.map(anchorIdentity(for:))
        }
        return Set(identities).count == identities.count
    }

    /// 按当前显示设置生成布局；书籍 section 支持确定性网格，其它副标题、加载与空态保持全宽。
    func makeLayout(for configuration: BookshelfBookListCollectionConfiguration) -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, environment in
            let resolvedConfiguration = self?.configuration ?? configuration
            if self?.sectionContainsSearchDrawer(at: sectionIndex) == true {
                return Self.makeSearchDrawerSection(height: resolvedConfiguration.searchDrawerHeight)
            }
            let usesGrid = resolvedConfiguration.layoutMode == .grid
                && (self?.sectionContainsBooks(at: sectionIndex) ?? false)
            let section = usesGrid
                ? Self.makeGridSection(
                    columnCount: resolvedConfiguration.columnCount,
                    containerWidth: environment.container.effectiveContentSize.width,
                    titleDisplayMode: resolvedConfiguration.titleDisplayMode
                )
                : Self.makeListSection(
                    itemHeight: self?.listItemHeight(at: sectionIndex) ?? BookshelfBookListLayoutMetrics.listRowHeight
                )
            if let self,
               self.sections.indices.contains(sectionIndex),
               self.sections[sectionIndex].title != nil {
                let headerSize = NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .absolute(BookshelfBookListLayoutMetrics.sectionHeaderHeight)
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

    /// 根据 section 内容返回稳定行高，避免 loading/empty/list row 依赖自动测量。
    func listItemHeight(at sectionIndex: Int) -> CGFloat {
        guard sections.indices.contains(sectionIndex),
              let firstItem = sections[sectionIndex].items.first else {
            return BookshelfBookListLayoutMetrics.listRowHeight
        }
        switch firstItem {
        case .searchDrawer:
            return configuration.searchDrawerHeight
        case .loading:
            return BookshelfBookListLayoutMetrics.loadingHeight
        case .empty:
            return BookshelfBookListLayoutMetrics.emptyHeight
        case .book:
            return BookshelfBookListLayoutMetrics.listRowHeight
        }
    }

    /// 只增加滚动余量，不改变 collection layout，避免底部玻璃栏遮挡最后一行书籍。
    func updateBottomContentInset(animated: Bool = false) {
        updateBottomContentInset(
            animation: animated ? defaultBottomInsetAnimationContext : .immediate
        )
    }

    /// 只增加滚动余量，不改变 collection layout，避免底部玻璃栏遮挡最后一行书籍。
    func updateBottomContentInset(
        animation: BookshelfCollectionKeyboardAvoidanceCoordinator.AnimationContext
    ) {
        let bottomInset = resolvedBottomContentInset()
        let didChangeCustomInset = collectionView.contentInset.bottom != bottomInset
            || collectionView.verticalScrollIndicatorInsets.bottom != bottomInset
        let didChangeAdjustedInset = collectionView.adjustedContentInset != lastAdjustedContentInset
        guard didChangeCustomInset || didChangeAdjustedInset else {
            return
        }

        let shouldPreserveSearchDrawer = shouldPreserveTopPinnedSearchDuringInsetChange
        if !shouldPreserveSearchDrawer {
            storeViewportAnchorIfPossible(requiresLayout: true)
        }
        let fallbackOffsetY = collectionView.contentOffset.y
        var contentInset = collectionView.contentInset
        contentInset.bottom = bottomInset

        var indicatorInsets = collectionView.verticalScrollIndicatorInsets
        indicatorInsets.bottom = bottomInset

        if shouldPreserveSearchDrawer {
            let lockedUpdates = {
                self.performSearchDrawerOffsetLocked {
                    self.collectionView.contentInset = contentInset
                    self.collectionView.verticalScrollIndicatorInsets = indicatorInsets
                    self.collectionView.layoutIfNeeded()
                }
            }
            guard animation.isAnimated else {
                UIView.performWithoutAnimation(lockedUpdates)
                return
            }
            UIView.animate(
                withDuration: animation.duration,
                delay: 0,
                options: animation.options,
                animations: lockedUpdates
            )
            return
        }

        let insetUpdates = { [self] in
            self.isViewportAnchorCaptureSuspended = true
            self.collectionView.contentInset = contentInset
            self.collectionView.verticalScrollIndicatorInsets = indicatorInsets
            self.collectionView.layoutIfNeeded()
            self.restoreViewportAnchor(stableViewportAnchor, fallbackOffsetY: fallbackOffsetY)
            self.isViewportAnchorCaptureSuspended = false
            self.lastAdjustedContentInset = self.collectionView.adjustedContentInset
            self.storeViewportAnchorIfPossible(requiresLayout: false)
        }
        guard animation.isAnimated else {
            UIView.performWithoutAnimation {
                insetUpdates()
            }
            return
        }
        UIView.animate(
            withDuration: animation.duration,
            delay: 0,
            options: animation.options,
            animations: insetUpdates
        )
    }

    /// 搜索输入聚焦期间，键盘只改变底部可滚动空间，不恢复书籍 cell 锚点。
    var shouldPreserveTopPinnedSearchDuringInsetChange: Bool {
        configuration.showsSearchDrawerInCollection
            && (
                configuration.isBrowseSearchPinned
                || configuration.isBrowseSearchFocused
                || searchFocusRequestCoordinator.isPending
                || configuration.hasBrowseSearchText
                || configuration.hasBrowseSearchKeyword
            )
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
            searchDrawerExtraBottomInset,
            keyboardAvoidanceInset
        )
    }

    /// 保存当前稳定视口锚点，供后续手动 bottom inset 变化恢复同一可见内容。
    func storeViewportAnchorIfPossible(requiresLayout: Bool) {
        guard !isRestoringViewport, !isViewportAnchorCaptureSuspended else { return }
        stableFallbackOffsetY = collectionView.contentOffset.y
        guard !shouldPreserveTopPinnedSearchDuringInsetChange else {
            searchDrawerLockedOffsetY = collectionView.contentOffset.y
            return
        }
        searchDrawerLockedOffsetY = nil
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
            if shouldPreserveTopPinnedSearchDuringInsetChange {
                performSearchDrawerOffsetLocked { }
            } else {
                restoreViewportAnchor(stableViewportAnchor, fallbackOffsetY: stableFallbackOffsetY)
            }
            lastAdjustedContentInset = collectionView.adjustedContentInset
            if !shouldPreserveTopPinnedSearchDuringInsetChange {
                storeViewportAnchorIfPossible(requiresLayout: false)
            }
        }
    }

    /// 在键盘或安全区重算期间锁住当前搜索抽屉 offset，避免输入框被普通内容锚点牵引。
    func performSearchDrawerOffsetLocked(_ updates: () -> Void) {
        let lockedOffsetY = searchDrawerLockedOffsetY ?? collectionView.contentOffset.y
        searchDrawerLockedOffsetY = lockedOffsetY
        isViewportAnchorCaptureSuspended = true
        updates()
        UIView.performWithoutAnimation {
            restorePinnedSearchDrawerOffsetIfNeeded(lockedOffsetY: lockedOffsetY)
            collectionView.layoutIfNeeded()
        }
        isViewportAnchorCaptureSuspended = false
        lastAdjustedContentInset = collectionView.adjustedContentInset
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
                    identity: item(at: candidate.indexPath).map(anchorIdentity(for:)),
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
           let resolvedIndexPath = resolvedIndexPath(for: anchor),
           let attributes = collectionView.layoutAttributesForItem(at: resolvedIndexPath) {
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

    /// 搜索输入态以 drawer 自身作为锚点，保证键盘 inset 改变时搜索框不被书籍 cell 锚点牵引。
    func restorePinnedSearchDrawerOffsetIfNeeded(lockedOffsetY: CGFloat? = nil) {
        let targetOffset = CGPoint(
            x: collectionView.contentOffset.x,
            y: clampedContentOffsetY(lockedOffsetY ?? searchDrawerLockedOffsetY ?? 0)
        )
        guard abs(collectionView.contentOffset.y - targetOffset.y) > 0.5 else { return }
        collectionView.setContentOffset(targetOffset, animated: false)
    }

    /// 优先使用稳定业务身份找回刷新前的可见项；找不到时退回 UIKit 原始 indexPath。
    func resolvedIndexPath(for anchor: ViewportAnchor) -> IndexPath? {
        if let identity = anchor.identity,
           let indexPath = indexPath(for: identity) {
            return indexPath
        }
        guard sections.indices.contains(anchor.indexPath.section),
              sections[anchor.indexPath.section].items.indices.contains(anchor.indexPath.item) else {
            return nil
        }
        return anchor.indexPath
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
            updateCollectionVisibilityForSearchDrawerPreparation()
            return
        }
        if configuration.showsExpandedSearchSurface {
            didApplyInitialSearchDrawerOffset = true
            isPendingInitialSearchDrawerOffset = false
            updateCollectionVisibilityForSearchDrawerPreparation()
            if !previousConfiguration.showsExpandedSearchSurface {
                setSearchDrawerVisible(animated: animated) { [weak self] in
                    self?.requestSearchFocusAfterDrawerSettles()
                }
            }
            return
        }
        if previousConfiguration.showsExpandedSearchSurface {
            didApplyInitialSearchDrawerOffset = true
            isPendingInitialSearchDrawerOffset = false
            setSearchDrawerHidden(animated: animated)
            updateCollectionVisibilityForSearchDrawerPreparation()
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
            updateCollectionVisibilityForSearchDrawerPreparation()
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
        updateCollectionVisibilityForSearchDrawerPreparation()
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

        let overlayInset = max(0, configuration.bottomContentInset, keyboardAvoidanceInset)
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
    func setSearchDrawerVisible(animated: Bool, completion: (() -> Void)? = nil) {
        guard !isInteractiveReordering,
              configuration.showsSearchDrawerInCollection else {
            completion?()
            return
        }
        collectionView.alpha = 1
        collectionView.isUserInteractionEnabled = true
        let targetOffset = CGPoint(
            x: collectionView.contentOffset.x,
            y: clampedContentOffsetY(0)
        )
        guard abs(collectionView.contentOffset.y - targetOffset.y) > 0.5 else {
            completion?()
            return
        }

        isAdjustingSearchDrawerOffset = true
        isViewportAnchorCaptureSuspended = true
        animateSearchDrawerOffset(to: targetOffset, animated: animated, completion: completion)
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
        animateSearchDrawerOffset(to: targetOffset, animated: animated)
    }

    /// 用页面统一节奏移动搜索抽屉，避免 UIScrollView 默认动画和 SwiftUI 状态动画脱节。
    func animateSearchDrawerOffset(to targetOffset: CGPoint, animated: Bool, completion: (() -> Void)? = nil) {
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            UIView.performWithoutAnimation {
                collectionView.setContentOffset(targetOffset, animated: false)
            }
            isAdjustingSearchDrawerOffset = false
            isViewportAnchorCaptureSuspended = false
            completion?()
            return
        }

        UIView.animate(
            withDuration: BookshelfManagementMotion.bookListSearchDrawerDuration,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseInOut]
        ) {
            self.collectionView.setContentOffset(targetOffset, animated: false)
            self.collectionView.layoutIfNeeded()
        } completion: { [weak self] _ in
            self?.isAdjustingSearchDrawerOffset = false
            self?.isViewportAnchorCaptureSuspended = false
            completion?()
        }
    }

    /// drawer offset 已稳定后再让 SwiftUI 触发 TextField 聚焦，避免键盘动画叠加顶部位移。
    func requestSearchFocusAfterDrawerSettles() {
        guard configuration.showsExpandedSearchSurface,
              !configuration.isBrowseSearchFocused else {
            return
        }
        searchFocusRequestCoordinator.request(configuration.onRequestBrowseSearchFocus)
    }

    /// 下拉抽屉只在普通浏览态、无焦点、无拖拽排序时接管松手后的回弹目标。
    func canSnapSearchDrawerAfterPull() -> Bool {
        configuration.showsSearchDrawerInCollection
            && configuration.searchPresentation == .hidden
            && !configuration.hasBrowseSearchText
            && !configuration.hasBrowseSearchKeyword
            && !configuration.isBrowseSearchFocused
            && !isInteractiveReordering
            && !isAdjustingSearchDrawerOffset
    }

    /// pinned 搜索为空且失焦后，用户继续向上浏览时自动回到隐藏抽屉状态。
    func collapsePinnedSearchIfNeeded(_ scrollView: UIScrollView) {
        guard configuration.isBrowseSearchPinned,
              !configuration.isBrowseSearchFocused,
              !configuration.hasBrowseSearchText,
              !configuration.hasBrowseSearchKeyword,
              configuration.showsSearchDrawerInCollection,
              !isInteractiveReordering,
              scrollView.contentOffset.y > hiddenSearchDrawerOffsetY() * 0.6 else {
            return
        }
        configuration.onCollapseBrowseSearch()
    }

    enum ViewportAnchorIdentity: Hashable {
        case searchDrawer
        case loading
        case empty
        case book(Int64)
    }

    struct ViewportAnchor {
        let identity: ViewportAnchorIdentity?
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

    /// 二级列表 list 模式与非书籍 section 使用单列全宽确定高度。
    static func makeListSection(itemHeight: CGFloat) -> NSCollectionLayoutSection {
        let resolvedHeight = max(1, itemHeight)
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
    func refreshVisibleCells(
        for transition: BookshelfBookListResultTransition = .other,
        refreshEmptyCells: Bool = true
    ) {
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let item = item(at: indexPath) else {
                continue
            }
            if case .searchDrawer = item,
               let cell = collectionView.cellForItem(at: indexPath) as? BookshelfBookListSearchCell {
                cell.configure(with: configuration)
            } else if let cell = collectionView.cellForItem(at: indexPath) as? BookshelfBookListCollectionCell {
                if case .empty = item, !refreshEmptyCells {
                    continue
                }
                cell.configure(
                    with: item,
                    configuration: configuration,
                    emptyPresentationMode: transition == .emptyToEmpty ? .steadyEmptyUpdate : emptyPresentationMode
                )
            }
        }
    }

    /// 内容退场期间只同步搜索输入 cell，避免正在淡出的书籍被重复配置后闪回。
    func refreshSearchDrawerCellOnly() {
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let item = item(at: indexPath),
                  case .searchDrawer = item,
                  let cell = collectionView.cellForItem(at: indexPath) as? BookshelfBookListSearchCell else {
                continue
            }
            cell.configure(with: configuration)
        }
    }

    func item(at indexPath: IndexPath) -> BookshelfBookListCollectionItem? {
        guard sections.indices.contains(indexPath.section),
              sections[indexPath.section].items.indices.contains(indexPath.item) else {
            return nil
        }
        return sections[indexPath.section].items[indexPath.item]
    }

    /// 将 collection item 映射成跨刷新稳定的锚点身份。
    func anchorIdentity(for item: BookshelfBookListCollectionItem) -> ViewportAnchorIdentity {
        switch item {
        case .searchDrawer:
            return .searchDrawer
        case .loading:
            return .loading
        case .empty:
            return .empty
        case .book(let book):
            return .book(book.id)
        }
    }

    /// 在当前 section 快照中查找锚点身份对应的位置。
    func indexPath(for identity: ViewportAnchorIdentity) -> IndexPath? {
        for (sectionIndex, section) in sections.enumerated() {
            for (itemIndex, item) in section.items.enumerated() {
                if anchorIdentity(for: item) == identity {
                    return IndexPath(item: itemIndex, section: sectionIndex)
                }
            }
        }
        return nil
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
            cell.configure(
                with: item,
                configuration: configuration,
                emptyPresentationMode: emptyPresentationMode
            )
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
    /// 对批量更新插入的 cell 补一段轻量进场，强化结果恢复时的空间连续性。
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let item = item(at: indexPath) else { return }
        let identity = anchorIdentity(for: item)
        guard pendingAnimatedInsertionIdentities.contains(identity) else { return }
        cell.alpha = 0
        cell.transform = CGAffineTransform(translationX: 0, y: 10).scaledBy(x: 0.985, y: 0.985)
        UIView.animate(
            withDuration: BookshelfManagementMotion.bookListResultTransitionDuration,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]
        ) {
            cell.alpha = 1
            cell.transform = .identity
        }
    }

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
private final class BookshelfBookListSearchCell: UICollectionViewCell {
    static let reuseIdentifier = "BookshelfBookListSearchCell"
    private let searchSurface = BookshelfSearchSurfaceView()

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
        searchSurface.prepareForReuse()
    }

    /// 同步搜索 surface 的折叠/输入状态；关键词回写由闭包交给 ViewModel。
    func configure(with configuration: BookshelfBookListCollectionConfiguration) {
        searchSurface.configure(with: BookshelfSearchSurfaceConfiguration(
            namespace: "bookshelf.book-list.search",
            placeholder: configuration.browseSearchPlaceholder,
            keyword: configuration.browseSearchText,
            showsInput: configuration.showsExpandedSearchSurface,
            showsClearAction: configuration.hasBrowseSearchText || configuration.hasBrowseSearchKeyword,
            usesAccessibilityLayout: configuration.searchDrawerHeight > BookshelfBookListChromeMetrics.normalSearchAreaHeight,
            focusTrigger: configuration.browseSearchFocusTrigger,
            accessibilityLabel: configuration.browseSearchPlaceholder,
            onActivate: configuration.onActivateBrowseSearch,
            onTextChange: configuration.onBrowseSearchKeywordChange,
            onSubmit: configuration.onSubmitBrowseSearch,
            onClear: configuration.onClearBrowseSearch,
            onCancel: configuration.onCollapseBrowseSearch,
            onFocusChange: configuration.onBrowseSearchFocusChange
        ))
    }

    private func setupViewHierarchy() {
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        searchSurface.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(searchSurface)
        NSLayoutConstraint.activate([
            searchSurface.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: Spacing.screenEdge),
            searchSurface.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -Spacing.screenEdge),
            searchSurface.topAnchor.constraint(equalTo: contentView.topAnchor),
            searchSurface.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
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

/// 二级列表空态的进场承载层，避免搜索结果区从网格硬切到占位。
private struct BookshelfBookListEmptyStateContainer: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let emptyState: BookshelfBookListEmptyState
    let presentationMode: BookshelfBookListEmptyPresentationMode
    @State private var isVisible: Bool

    init(
        emptyState: BookshelfBookListEmptyState,
        presentationMode: BookshelfBookListEmptyPresentationMode
    ) {
        self.emptyState = emptyState
        self.presentationMode = presentationMode
        _isVisible = State(initialValue: presentationMode == .steadyEmptyUpdate)
    }

    var body: some View {
        BookshelfContextualEmptyStateView(
            icon: emptyState.icon,
            title: emptyState.title,
            message: emptyState.message,
            iconColor: emptyState.iconColor
        )
        .frame(maxWidth: .infinity)
        .frame(minHeight: BookshelfBookListLayoutMetrics.emptyHeight)
        .opacity(isVisible ? 1 : 0)
        .scaleEffect(shouldUseSpatialEntrance && !isVisible ? 0.985 : 1)
        .offset(y: shouldUseSpatialEntrance && !isVisible ? 8 : 0)
        .onAppear {
            guard !isVisible else { return }
            guard presentationMode == .enteringFromContent else {
                isVisible = true
                return
            }
            withAnimation(BookshelfManagementMotion.bookListResultStateAnimation(reduceMotion: reduceMotion)) {
                isVisible = true
            }
        }
    }

    private var shouldUseSpatialEntrance: Bool {
        presentationMode == .enteringFromContent && !reduceMotion
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
        configuration: BookshelfBookListCollectionConfiguration,
        emptyPresentationMode: BookshelfBookListEmptyPresentationMode = .steadyEmptyUpdate
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
                    .frame(minHeight: BookshelfBookListLayoutMetrics.loadingHeight)
            case .empty(let emptyState):
                BookshelfBookListEmptyStateContainer(
                    emptyState: emptyState,
                    presentationMode: emptyPresentationMode
                )
            case .book(let book):
                switch configuration.layoutMode {
                case .grid:
                    BookshelfBookListGridItemView(
                        book: book,
                        showsNoteCount: configuration.showsNoteCount,
                        titleDisplayMode: configuration.titleDisplayMode,
                        searchKeyword: configuration.browseSearchKeyword,
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
                        searchKeyword: configuration.browseSearchKeyword,
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
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
                .truncationMode(.tail)
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

            Divider()
                .frame(height: Spacing.double)
                .overlay(Color.surfaceBorderSubtle.opacity(canEnterEditing ? 0.58 : 0.18))
                .animation(BookshelfManagementMotion.bookListTopActionAnimation(reduceMotion: reduceMotion), value: canEnterEditing)

            Button(action: onEnterEditing) {
                TopBarActionIcon(
                    systemName: "checklist",
                    foregroundColor: canEnterEditing ? Color.iconPrimary : Color.textHint
                )
            }
            .buttonStyle(.plain)
            .disabled(!canEnterEditing)
            .opacity(canEnterEditing ? 1 : 0.42)
            .scaleEffect(canEnterEditing ? 1 : 0.96)
            .animation(BookshelfManagementMotion.bookListTopActionAnimation(reduceMotion: reduceMotion), value: canEnterEditing)
            .accessibilityLabel(canEnterEditing ? "整理书籍" : "整理书籍，当前不可用")
            .accessibilityHint(canEnterEditing ? "进入书籍整理模式" : "当前没有可整理的书籍")
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
    let searchKeyword: String
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
                    color: .textPrimary,
                    highlightKeyword: searchKeyword
                )

                XMKeywordHighlighting.text(
                    metadataText(separator: "，", emptyAuthorFallback: " ", includesNoteCount: false),
                    keyword: searchKeyword,
                    baseFont: AppTypography.caption2,
                    highlightFont: AppTypography.caption2,
                    baseColor: Color.textSecondary
                )
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .opacity(isEditing ? (isSelected ? 1 : BookshelfBookListSelectionVisualStyle.unselectedEditingOpacity) : 1)
        .overlay(alignment: .bottomLeading) {
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
            XMMenuLabel("整理书籍", systemImage: "checklist")
        }

        Button(role: .destructive) {
            onContextAction(.delete, book.id)
        } label: {
            Label("删除书籍", systemImage: "trash")
        }
        .disabled(activeWriteAction != nil)
    }

    private var metadata: String {
        metadataText(separator: "，", emptyAuthorFallback: "未知作者", includesNoteCount: true)
    }

    private func metadataText(separator: String, emptyAuthorFallback: String, includesNoteCount: Bool) -> String {
        let authorText = book.author.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if let searchContextText {
            parts.append(searchContextText)
        }
        if !authorText.isEmpty {
            parts.append(authorText)
        } else if searchContextText == nil {
            parts.append(emptyAuthorFallback)
        }
        if includesNoteCount, showsNoteCount, book.noteCount > 0 {
            parts.append("\(book.noteCount)条书摘")
        }
        return parts.joined(separator: separator)
    }

    private var searchContextText: String? {
        guard hasSearchKeyword,
              !XMKeywordHighlighting.contains(book.title, keyword: searchKeyword),
              !XMKeywordHighlighting.contains(book.author, keyword: searchKeyword) else {
            return nil
        }
        return nil
    }

    private var hasSearchKeyword: Bool {
        !searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
    let searchKeyword: String
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
                    color: .textPrimary,
                    highlightKeyword: searchKeyword
                )

                XMKeywordHighlighting.text(
                    metadata,
                    keyword: searchKeyword,
                    baseFont: AppTypography.caption,
                    highlightFont: AppTypography.caption,
                    baseColor: Color.textSecondary
                )
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
        .overlay(alignment: .bottomLeading) {
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
            XMMenuLabel("整理书籍", systemImage: "checklist")
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
        metadataText(separator: " · ", emptyAuthorFallback: "未知作者")
    }

    private func metadataText(separator: String, emptyAuthorFallback: String) -> String {
        let authorText = book.author.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        if let searchContextText {
            parts.append(searchContextText)
        }
        parts.append(authorText.isEmpty ? emptyAuthorFallback : authorText)
        if showsNoteCount, book.noteCount > 0 {
            parts.append("\(book.noteCount)条书摘")
        }
        return parts.joined(separator: separator)
    }

    private var searchContextText: String? {
        guard hasSearchKeyword,
              !XMKeywordHighlighting.contains(book.title, keyword: searchKeyword),
              !XMKeywordHighlighting.contains(book.author, keyword: searchKeyword) else {
            return nil
        }
        return nil
    }

    private var hasSearchKeyword: Bool {
        !searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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
        .background {
            GeometryReader { proxy in
                Color.clear
                    .preference(key: ImmersiveBottomChromeHeightPreferenceKey.self, value: proxy.size.height)
            }
        }
        .overlay(alignment: .bottom) {
            if let statusText {
                BookshelfGlassEditStatusText(text: statusText)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: -(BookshelfGlassEditBarMetrics.clusterHeight + Spacing.tight))
                    .transition(.opacity)
                    .allowsHitTesting(false)
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
