//
//  BookContainerView.swift
//  xmnote
//
//  Created by 王珂 on 2026/2/10.
//

/**
 * [INPUT]: 依赖 RepositoryContainer 注入仓储，依赖 BookViewModel 驱动书架浏览、编辑态选择与批量操作，依赖本地 chrome 阶段、固定顶部 chrome 高度、底部面板高度与外层 TabBar snapshot 回调稳定内容布局
 * [OUTPUT]: 对外提供 BookContainerView 与 BookSubTab 枚举，承载书架顶部 chrome、TabBar 协调、编辑工具栏、批量 Sheet、删除确认与 snapshot 恢复交接通知
 * [POS]: Book 模块容器壳层，承载书籍页与书架管理模式编排
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI

// MARK: - Sub Tab

/// 书籍页二级分栏；保留 collections 的 Codable 兼容，但生产入口只开放书籍列表。
enum BookSubTab: String, CaseIterable, Hashable, Codable {
    case books, collections

    static var allCases: [BookSubTab] { [.books] }

    var title: String {
        switch self {
        case .books: "书籍"
        case .collections: "书单"
        }
    }

    var productionValue: BookSubTab {
        switch self {
        case .books, .collections:
            return .books
        }
    }
}

// MARK: - Management Chrome

/// 书架管理模式的本地展示阶段，仅编排顶部 chrome、底部面板与 TabBar 的视觉交接。
private enum BookshelfChromePhase: Equatable {
    case normal
    case enteringEdit
    case editing
    case exitingEdit

    var hidesTabBar: Bool {
        self != .normal
    }

    var showsEditHeader: Bool {
        self == .enteringEdit || self == .editing
    }

    var showsEditBottomBar: Bool {
        self == .editing
    }
}

/// 记录编辑底部面板的实际高度，作为书架集合滚动余量而不是布局压缩来源。
private struct BookshelfEditBottomBarHeightPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

// MARK: - Container

/// 书籍模块入口容器，负责书籍页顶部工具入口与外层路由转发。
struct BookContainerView: View {
    @Environment(RepositoryContainer.self) private var repositories
    @Environment(SceneStateStore.self) private var sceneStateStore
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
    let onTabBarSnapshotHandoff: (BookshelfTabBarSnapshotHandoffEvent) -> Void

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
        onOpenGuide: @escaping () -> Void = {},
        onTabBarSnapshotHandoff: @escaping (BookshelfTabBarSnapshotHandoffEvent) -> Void = { _ in }
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
        self.onTabBarSnapshotHandoff = onTabBarSnapshotHandoff
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
                    onOpenGuide: onOpenGuide,
                    onTabBarSnapshotHandoff: onTabBarSnapshotHandoff
                )
            } else {
                Color.clear
            }
        }
        .task(id: sceneStateStore.isRestored) {
            guard sceneStateStore.isRestored else { return }
            guard !didBootstrapFromScene else { return }
            didBootstrapFromScene = true
            selectedSubTab = sceneStateStore.snapshot.books.selectedSubTab.productionValue
            sceneStateStore.updateBookSelectedSubTab(selectedSubTab)
        }
        .task {
            guard viewModel == nil else { return }
            viewModel = BookViewModel(repository: repositories.bookRepository)
        }
        .onChange(of: selectedSubTab) { _, newValue in
            let normalizedValue = newValue.productionValue
            guard normalizedValue == newValue else {
                selectedSubTab = normalizedValue
                return
            }
            sceneStateStore.updateBookSelectedSubTab(normalizedValue)
        }
    }
}

// MARK: - Content View

private struct BookContentView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Bindable var viewModel: BookViewModel
    @Binding var selectedSubTab: BookSubTab
    @State private var showsDisplaySettingSheet = false
    @State private var chromePhase: BookshelfChromePhase = .normal
    @State private var chromeTransitionTask: Task<Void, Never>?
    @State private var editBottomBarHeight: CGFloat = 0
    @State private var frozenTopChromeHeight: CGFloat?
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
    let onTabBarSnapshotHandoff: (BookshelfTabBarSnapshotHandoffEvent) -> Void

    var body: some View {
        ZStack(alignment: .top) {
            Color.surfacePage.ignoresSafeArea()

            segmentedContent
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .padding(.top, reservedTopChromeHeight)

            if showsBrowsingGradient {
                HomeTopHeaderGradient()
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }

            topChrome
                .zIndex(1)
        }
        .overlay(alignment: .bottom) {
            editBottomBarOverlay
        }
        .toolbar(.hidden, for: .navigationBar)
        .toolbar(tabBarVisibility, for: .tabBar)
        .sheet(isPresented: $showsDisplaySettingSheet) {
            BookshelfDisplaySettingSheet(
                dimension: viewModel.selectedDimension,
                scope: .main,
                setting: $viewModel.displaySetting
            )
            .presentationDetents([.large])
            .presentationDragIndicator(.hidden)
        }
        .sheet(item: $viewModel.activeBatchSheet) { sheet in
            switch sheet {
            case .tags(
                options: let options,
                initialSelectedIDs: let initialSelectedIDs,
                allowsEmptySelection: let allowsEmptySelection
            ):
                BookshelfBatchTagsSheet(
                    options: options,
                    selectedCount: viewModel.selectedBookIDs.count,
                    initialSelectedIDs: initialSelectedIDs,
                    allowsEmptySelection: allowsEmptySelection,
                    onConfirm: viewModel.submitBatchTags
                )
            case .source(options: let options, initialSelectedID: let initialSelectedID):
                BookshelfBatchSourceSheet(
                    options: options,
                    selectedCount: viewModel.selectedBookIDs.count,
                    initialSelectedID: initialSelectedID,
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
            case .moveGroup(options: let options):
                BookshelfMoveGroupSheet(
                    options: options,
                    selectedCount: viewModel.selectedBookIDs.count,
                    onConfirm: viewModel.submitMoveToGroup
                )
            }
        }
        .xmSystemAlert(item: $viewModel.activeDeleteConfirmation) { confirmation in
            defaultDeleteDescriptor(for: confirmation)
        }
        .onAppear {
            syncChromePhaseWithEditingState()
        }
        .onChange(of: viewModel.isEditing) { _, _ in
            syncChromePhaseWithEditingState()
        }
        .onChange(of: selectedSubTab) { _, newValue in
            guard newValue != .books else { return }
            exitEditingWithChoreography()
        }
        .onChange(of: showsEditBottomBar) { _, isVisible in
            guard !isVisible else { return }
            editBottomBarHeight = 0
        }
        .onPreferenceChange(BookshelfEditBottomBarHeightPreferenceKey.self) { height in
            guard showsEditBottomBar, height > 0 else { return }
            editBottomBarHeight = height
        }
        .onDisappear {
            resetEditingPresentationForContextLoss()
        }
    }

    @ViewBuilder
    private var editBottomBarOverlay: some View {
        GeometryReader { proxy in
            VStack(spacing: Spacing.none) {
                Spacer(minLength: Spacing.none)
                    .allowsHitTesting(false)

                if showsEditBottomBar {
                    editBottomBar(bottomSafeAreaInset: proxy.safeAreaInsets.bottom)
                        .background {
                            GeometryReader { panelProxy in
                                Color.clear.preference(
                                    key: BookshelfEditBottomBarHeightPreferenceKey.self,
                                    value: panelProxy.size.height
                                )
                            }
                        }
                        .transition(BookshelfManagementMotion.bottomPanelTransition(reduceMotion: reduceMotion))
                }
            }
            .ignoresSafeArea(.container, edges: .bottom)
        }
        .allowsHitTesting(showsEditBottomBar)
    }

    @ViewBuilder
    private var topChrome: some View {
        ZStack(alignment: .top) {
            if showsBrowsingChrome {
                BookshelfBrowsingChrome(
                    selectedSubTab: $selectedSubTab,
                    selectedDimension: viewModel.selectedDimension,
                    isSearchActive: viewModel.isSearchActive,
                    searchKeyword: $viewModel.searchKeyword,
                    hasSearchKeyword: viewModel.hasSearchKeyword,
                    canShowBookActions: selectedSubTab == .books,
                    canShowSelectAction: canShowSelectAction,
                    canEditCurrentDimension: viewModel.canEditCurrentDimension,
                    onActivateSearch: viewModel.activateSearch,
                    onDeactivateSearch: viewModel.deactivateSearch,
                    onClearSearch: viewModel.clearSearchKeyword,
                    onSelectDimension: viewModel.selectDimension,
                    onShowDisplaySettings: { showsDisplaySettingSheet = true },
                    onEnterEditing: { enterEditingWithChoreography() },
                    onAddBook: onAddBook,
                    onAddNote: onAddNote,
                    onOpenDebugCenter: onOpenDebugCenter,
                    onOpenTagManagement: onOpenTagManagement,
                    onOpenSourceManagement: onOpenSourceManagement,
                    onOpenAuthorManagement: onOpenAuthorManagement,
                    onOpenPressManagement: onOpenPressManagement,
                    onOpenGuide: onOpenGuide
                )
                .allowsHitTesting(chromePhase == .normal)
                .transition(BookshelfManagementMotion.topChromeTransition(reduceMotion: reduceMotion))
            }

            if showsEditHeader {
                BookshelfEditChrome(
                    selectedBookCount: viewModel.selectedBookIDs.count,
                    selectedGroupCount: viewModel.selectedGroupCount,
                    isAllVisibleSelected: viewModel.isAllVisibleSelected,
                    onToggleSelectAll: toggleVisibleSelection,
                    onCancel: exitEditingWithChoreography
                )
                    .transition(BookshelfManagementMotion.topChromeTransition(reduceMotion: reduceMotion))
            }
        }
        .frame(height: reservedTopChromeHeight, alignment: .top)
        .clipped()
    }

    private func editBottomBar(bottomSafeAreaInset: CGFloat) -> some View {
        BookshelfEditBottomBar(
            selectedCount: viewModel.selectedCount,
            bottomSafeAreaInset: bottomSafeAreaInset,
            canPin: viewModel.canSubmitSelectedPin,
            canMoveBoundary: viewModel.canMoveSelectedItems,
            canBatchAction: viewModel.canMoreSelectedItems,
            canDelete: viewModel.canDeleteSelectedItems,
            activeAction: viewModel.activeWriteAction,
            actions: viewModel.defaultBottomActions,
            isLoadingOptions: viewModel.isLoadingBatchOptions,
            notice: viewModel.actionNotice,
            onPin: viewModel.pinSelectedItems,
            onAction: viewModel.performBottomAction,
            onDelete: viewModel.presentDeleteConfirmation
        )
    }

    private var showsBrowsingChrome: Bool {
        selectedSubTab != .books || chromePhase == .normal
    }

    private var showsEditHeader: Bool {
        selectedSubTab == .books && chromePhase.showsEditHeader
    }

    private var showsEditBottomBar: Bool {
        selectedSubTab == .books && chromePhase.showsEditBottomBar
    }

    private var showsBrowsingGradient: Bool {
        selectedSubTab != .books || chromePhase == .normal
    }

    private var canShowSelectAction: Bool {
        selectedSubTab == .books && chromePhase == .normal && !viewModel.isEditing
    }

    private var tabBarVisibility: Visibility {
        selectedSubTab == .books && chromePhase.hidesTabBar ? .hidden : .automatic
    }

    private var reservedTopChromeHeight: CGFloat {
        frozenTopChromeHeight ?? expectedTopChromeHeight
    }

    private var expectedTopChromeHeight: CGFloat {
        guard selectedSubTab == .books else { return topBarRowHeight }
        return topBarRowHeight
            + (viewModel.isSearchActive ? BookshelfChromeMetrics.searchBarHeight : BookshelfChromeMetrics.dimensionRailHeight)
            + (viewModel.hasSearchKeyword ? BookshelfChromeMetrics.searchHintHeight : 0)
    }

    private var topBarRowHeight: CGFloat {
        dynamicTypeSize >= .accessibility1 ? BookshelfChromeMetrics.accessibilityTopBarHeight : BookshelfChromeMetrics.topBarHeight
    }

    /// 进入书架管理模式，并为菜单收口、顶部 chrome 和底部面板保留清晰的分层节奏。
    /// - Note: 所有 SwiftUI 状态都在 MainActor 上修改；延迟任务会被后续进入/退出请求取消，避免旧阶段覆盖新阶段。
    private func enterEditingWithChoreography(initialSelection: BookshelfItemID? = nil) {
        guard selectedSubTab == .books, viewModel.canEditCurrentDimension else {
            onTabBarSnapshotHandoff(.hideSnapshot)
            return
        }
        chromeTransitionTask?.cancel()
        onTabBarSnapshotHandoff(.prepareSnapshot)
        frozenTopChromeHeight = expectedTopChromeHeight

        chromeTransitionTask = Task { @MainActor in
            try? await Task.sleep(for: BookshelfManagementMotion.editEntryPreparationDelay(reduceMotion: reduceMotion))
            guard !Task.isCancelled else { return }
            guard selectedSubTab == .books, viewModel.canEditCurrentDimension else {
                onTabBarSnapshotHandoff(.hideSnapshot)
                chromePhase = .normal
                frozenTopChromeHeight = nil
                chromeTransitionTask = nil
                return
            }

            withAnimation(BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion)) {
                chromePhase = .enteringEdit
                viewModel.enterEditing(initialSelection: initialSelection)
            }

            guard viewModel.isEditing else {
                chromePhase = .normal
                frozenTopChromeHeight = nil
                chromeTransitionTask = nil
                return
            }

            try? await Task.sleep(for: BookshelfManagementMotion.editPanelDelay(reduceMotion: reduceMotion))
            guard !Task.isCancelled else { return }
            withAnimation(BookshelfManagementMotion.panelAnimation(reduceMotion: reduceMotion)) {
                chromePhase = .editing
            }
            chromeTransitionTask = nil
        }
    }

    /// 退出书架管理模式并先收起编辑 chrome，再恢复系统 TabBar。
    /// - Note: 方法只编排本地展示阶段；真正的选择清理仍交给 `BookViewModel.exitEditing()`，延迟任务可取消以处理快速反复切换。
    private func exitEditingWithChoreography() {
        guard viewModel.isEditing || chromePhase != .normal else { return }
        chromeTransitionTask?.cancel()
        if frozenTopChromeHeight == nil {
            frozenTopChromeHeight = expectedTopChromeHeight
        }

        withAnimation(BookshelfManagementMotion.panelAnimation(reduceMotion: reduceMotion)) {
            chromePhase = .exitingEdit
        }

        chromeTransitionTask = Task { @MainActor in
            try? await Task.sleep(for: BookshelfManagementMotion.tabBarSnapshotShowDelay(reduceMotion: reduceMotion))
            guard !Task.isCancelled else {
                onTabBarSnapshotHandoff(.hideSnapshot)
                return
            }
            onTabBarSnapshotHandoff(.showSnapshot)
            try? await Task.sleep(for: BookshelfManagementMotion.tabBarSnapshotRestoreDelay(reduceMotion: reduceMotion))
            guard !Task.isCancelled else {
                onTabBarSnapshotHandoff(.hideSnapshot)
                return
            }

            withAnimation(BookshelfManagementMotion.restoreAnimation(reduceMotion: reduceMotion)) {
                viewModel.exitEditing()
                chromePhase = .normal
            }
            try? await Task.sleep(for: BookshelfManagementMotion.tabBarSnapshotRevealHoldDelay(reduceMotion: reduceMotion))
            guard !Task.isCancelled else {
                onTabBarSnapshotHandoff(.hideSnapshot)
                return
            }
            onTabBarSnapshotHandoff(.hideSnapshot)
            frozenTopChromeHeight = nil
            chromeTransitionTask = nil
        }
    }

    private func toggleVisibleSelection() {
        withAnimation(BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion)) {
            if viewModel.isAllVisibleSelected {
                viewModel.clearSelection()
            } else {
                viewModel.selectAllVisible()
            }
        }
    }

    private func invertVisibleSelection() {
        withAnimation(BookshelfManagementMotion.modeAnimation(reduceMotion: reduceMotion)) {
            viewModel.invertVisibleSelection()
        }
    }

    /// 同步外部编辑态变化，保证页面恢复或异步清理后本地 chrome 阶段不滞留。
    private func syncChromePhaseWithEditingState() {
        guard selectedSubTab == .books else {
            if viewModel.isEditing {
                viewModel.exitEditing()
            }
            chromeTransitionTask?.cancel()
            onTabBarSnapshotHandoff(.hideSnapshot)
            chromePhase = .normal
            frozenTopChromeHeight = nil
            return
        }

        if viewModel.isEditing, chromePhase == .normal {
            chromePhase = .editing
            frozenTopChromeHeight = expectedTopChromeHeight
        } else if !viewModel.isEditing, chromePhase != .normal {
            chromeTransitionTask?.cancel()
            onTabBarSnapshotHandoff(.hideSnapshot)
            chromePhase = .normal
            frozenTopChromeHeight = nil
        }
    }

    /// 页面失活时立即清理展示阶段和业务编辑态，避免异步动画任务回写已离开的页面。
    private func resetEditingPresentationForContextLoss() {
        chromeTransitionTask?.cancel()
        chromeTransitionTask = nil
        onTabBarSnapshotHandoff(.hideSnapshot)
        chromePhase = .normal
        frozenTopChromeHeight = nil
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
            bookGridPage
        }
    }

    private var bookGridPage: some View {
        BookGridView(
            viewModel: viewModel,
            isPageActive: selectedSubTab.productionValue == .books,
            bottomContentInset: editBottomBarHeight,
            onOpenRoute: onOpenBookRoute,
            onOpenNoteRoute: onOpenNoteRoute,
            onEnterEditing: { initialSelection in
                enterEditingWithChoreography(initialSelection: initialSelection)
            }
        )
    }

}

// MARK: - Top Chrome Components

private enum BookshelfChromeMetrics {
    static let topBarHeight: CGFloat = 56
    static let accessibilityTopBarHeight: CGFloat = 60
    static let dimensionRailHeight: CGFloat = 44
    static let searchBarHeight: CGFloat = 40
    static let searchHintHeight: CGFloat = 20
    static let editContextHeight: CGFloat = 40
}

private enum BookshelfDimensionManagementAction {
    case tag
    case source
    case author
    case press

    var title: String {
        switch self {
        case .tag:
            return "标签管理"
        case .source:
            return "来源管理"
        case .author:
            return "作者管理"
        case .press:
            return "出版社管理"
        }
    }

    var systemImage: String {
        switch self {
        case .tag:
            return "tag"
        case .source:
            return "tray.full"
        case .author:
            return "person.text.rectangle"
        case .press:
            return "building.2"
        }
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
            return "搜索当前分类"
        }
    }

    var managementAction: BookshelfDimensionManagementAction? {
        switch self {
        case .tag:
            return .tag
        case .source:
            return .source
        case .author:
            return .author
        case .press:
            return .press
        case .default, .status, .rating:
            return nil
        }
    }
}

/// 普通浏览态顶部 chrome，承载页面切换、书架工具、搜索与维度 rail。
private struct BookshelfBrowsingChrome: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Binding var selectedSubTab: BookSubTab
    let selectedDimension: BookshelfDimension
    let isSearchActive: Bool
    @Binding var searchKeyword: String
    let hasSearchKeyword: Bool
    let canShowBookActions: Bool
    let canShowSelectAction: Bool
    let canEditCurrentDimension: Bool
    let onActivateSearch: () -> Void
    let onDeactivateSearch: () -> Void
    let onClearSearch: () -> Void
    let onSelectDimension: (BookshelfDimension) -> Void
    let onShowDisplaySettings: () -> Void
    let onEnterEditing: () -> Void
    let onAddBook: () -> Void
    let onAddNote: () -> Void
    let onOpenDebugCenter: (() -> Void)?
    let onOpenTagManagement: () -> Void
    let onOpenSourceManagement: () -> Void
    let onOpenAuthorManagement: () -> Void
    let onOpenPressManagement: () -> Void
    let onOpenGuide: () -> Void

    var body: some View {
        VStack(spacing: Spacing.none) {
            TopSwitcher(
                selection: $selectedSubTab,
                tabs: BookSubTab.allCases,
                titleProvider: \.title
            ) {
                topBarActions
            }

            if canShowBookActions {
                if isSearchActive {
                    BookshelfSearchBar(
                        text: $searchKeyword,
                        placeholder: selectedDimension.searchPlaceholder,
                        onCancel: onDeactivateSearch,
                        onClear: onClearSearch
                    )
                    .frame(minHeight: BookshelfChromeMetrics.searchBarHeight)
                    .transition(BookshelfManagementMotion.browsingChromeTransition(reduceMotion: reduceMotion))
                } else {
                    dimensionToolRow
                        .frame(minHeight: BookshelfChromeMetrics.dimensionRailHeight)
                        .transition(BookshelfManagementMotion.browsingChromeTransition(reduceMotion: reduceMotion))
                }

                if hasSearchKeyword {
                    searchHint
                        .frame(minHeight: BookshelfChromeMetrics.searchHintHeight)
                        .transition(.opacity)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private var topBarActions: some View {
        HStack(spacing: Spacing.cozy) {
            AddMenuCircleButton(
                onAddBook: onAddBook,
                onAddNote: onAddNote,
                onOpenDebugCenter: onOpenDebugCenter,
                usesGlassStyle: true
            )
        }
    }

    private var dimensionToolRow: some View {
        HStack(spacing: Spacing.none) {
            BookshelfDimensionRail(
                selectedDimension: selectedDimension,
                onSelect: onSelectDimension,
                trailingPadding: Spacing.none
            )
            .frame(maxWidth: .infinity)

            bookshelfToolMenu
                .padding(.leading, Spacing.tight)
                .padding(.trailing, Spacing.screenEdge)
        }
    }

    private var bookshelfToolMenu: some View {
        Menu {
            if let searchTitle = selectedDimension.searchMenuTitle {
                Button(action: onActivateSearch) {
                    Label(searchTitle, systemImage: "magnifyingglass")
                }
            }

            if selectedDimension == .default {
                Button(action: onEnterEditing) {
                    Label("书籍整理", systemImage: "sparkles")
                }
                .disabled(!canShowSelectAction || !canEditCurrentDimension)
            }

            if let managementAction = selectedDimension.managementAction {
                Button(action: managementActionHandler(for: managementAction)) {
                    Label(managementAction.title, systemImage: managementAction.systemImage)
                }
            }

            Button(action: onShowDisplaySettings) {
                Label("显示与排序", systemImage: "slider.horizontal.3")
            }

            Divider()

            Button(action: onOpenGuide) {
                Label("使用说明", systemImage: "questionmark.circle")
            }
        } label: {
            BookshelfToolMenuButton()
        }
        .menuOrder(.fixed)
        .accessibilityLabel("书架更多操作")
    }

    private func managementActionHandler(for action: BookshelfDimensionManagementAction) -> () -> Void {
        switch action {
        case .tag:
            return onOpenTagManagement
        case .source:
            return onOpenSourceManagement
        case .author:
            return onOpenAuthorManagement
        case .press:
            return onOpenPressManagement
        }
    }

    private var searchHint: some View {
        Text("搜索结果不支持排序，清除搜索后可调整书架顺序")
            .font(AppTypography.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.screenEdge)
    }
}

/// 书架维度 rail 右侧固定的末尾 chip，保持 44pt 热区并对齐未选中维度项。
private struct BookshelfToolMenuButton: View {
    private enum Style {
        static let hitSize = Spacing.actionReserved
        static let visualWidth: CGFloat = 32
        static let visualHeight: CGFloat = 28
        static let cornerRadius = CornerRadius.blockSmall
    }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Style.cornerRadius, style: .continuous)
                .fill(Color.surfaceCard)

            RoundedRectangle(cornerRadius: Style.cornerRadius, style: .continuous)
                .stroke(Color.surfaceBorderSubtle.opacity(0.18), lineWidth: CardStyle.borderWidth)

            BookshelfMoreGlyph()
        }
        .frame(width: Style.visualWidth, height: Style.visualHeight)
        .frame(width: Style.hitSize, height: Style.hitSize)
        .contentShape(Rectangle())
    }
}

/// 自绘竖向三点，避免 SF Symbol 旋转或 `ellipsis.vertical` 在菜单 label 中显示不稳定。
private struct BookshelfMoreGlyph: View {
    private enum Style {
        static let dotSize: CGFloat = 3
        static let dotSpacing: CGFloat = 2.5
    }

    var body: some View {
        VStack(spacing: Style.dotSpacing) {
            ForEach(0..<3, id: \.self) { _ in
                Circle()
                    .fill(Color.iconSecondary)
                    .frame(width: Style.dotSize, height: Style.dotSize)
            }
        }
        .accessibilityHidden(true)
    }
}

/// 默认书架编辑态顶部 chrome，复用浏览态顶部高度表达当前批量管理上下文。
private struct BookshelfEditChrome: View {
    let selectedBookCount: Int
    let selectedGroupCount: Int
    let isAllVisibleSelected: Bool
    let onToggleSelectAll: () -> Void
    let onCancel: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.base) {
            Button(selectionToggleTitle, action: onToggleSelectAll)
                .font(AppTypography.body)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.86)
                .frame(minWidth: 74, minHeight: Spacing.actionReserved, alignment: .leading)
                .accessibilityLabel(selectionToggleTitle)

            Spacer(minLength: Spacing.compact)

            VStack(spacing: Spacing.tiny) {
                Text("选择书籍")
                    .font(AppTypography.bodyMedium)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.90)

                Text(selectionSummaryText)
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
            }
            .frame(maxWidth: .infinity)
            .accessibilityElement(children: .combine)

            Spacer(minLength: Spacing.compact)

            Button("取消", action: onCancel)
                .font(AppTypography.body)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .minimumScaleFactor(0.86)
                .frame(minWidth: 74, minHeight: Spacing.actionReserved, alignment: .trailing)
                .accessibilityLabel("取消选择")
        }
        .padding(.horizontal, Spacing.screenEdge)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .background {
            Color.surfacePage
                .ignoresSafeArea(.container, edges: .top)
        }
        .overlay(alignment: .bottom) {
            Divider()
                .overlay(Color.surfaceBorderSubtle.opacity(0.38))
        }
        .accessibilityElement(children: .contain)
    }

    private var selectionToggleTitle: String {
        isAllVisibleSelected ? "取消全选" : "全选"
    }

    private var selectionSummaryText: String {
        switch (selectedBookCount, selectedGroupCount) {
        case (0, 0):
            return "未选择书籍或分组"
        case (let bookCount, 0):
            return "已选择 \(bookCount) 本书籍"
        case (0, let groupCount):
            return "已选择 \(groupCount) 个分组"
        case (let bookCount, let groupCount):
            return "已选择 \(bookCount) 本书籍和 \(groupCount) 个分组"
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
