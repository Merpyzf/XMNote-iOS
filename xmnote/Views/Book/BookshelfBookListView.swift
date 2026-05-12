//
//  BookshelfBookListView.swift
//  xmnote
//
//  Created by Codex on 2026/5/6.
//

/**
 * [INPUT]: 依赖 BookshelfBookListRoute 提供聚合上下文，依赖 BookRepositoryProtocol 提供二级列表观察流，依赖外层 BookRoute/NoteRoute 闭包承接书籍与书摘导航
 * [OUTPUT]: 对外提供 BookshelfBookListView，使用 UIKit UICollectionView 展示聚合书籍列表、长按菜单、编辑选择入口、底部玻璃批量工具栏与批量编辑 Sheet 容器
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var viewModel: BookshelfBookListViewModel
    let onOpenRoute: (BookRoute) -> Void
    let onOpenNoteRoute: (NoteRoute) -> Void
    @State private var showsDisplaySettingSheet = false
    @State private var bottomOrnamentHeight: CGFloat = 0
    @State private var bottomContentInset: CGFloat = 0
    @State private var isRetainingBottomInsetForEditExit = false
    @State private var bottomInsetReleaseTask: Task<Void, Never>?

    var body: some View {
        VStack(spacing: Spacing.compact) {
            if viewModel.isEditing {
                BookshelfEditHeader(
                    selectedCount: viewModel.selectedCount,
                    isAllVisibleSelected: viewModel.isAllVisibleSelected,
                    onCancel: viewModel.exitEditing,
                    onSelectAll: viewModel.selectAllVisible,
                    onInvertSelection: viewModel.invertVisibleSelection
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            } else {
                BookshelfBookListSearchBar(
                    text: $viewModel.searchKeyword,
                    onClear: viewModel.clearSearchKeyword
                )
                .transition(.move(edge: .top).combined(with: .opacity))
            }

            BookshelfBookListCollectionView(
                snapshot: viewModel.snapshot,
                subtitle: viewModel.subtitle,
                contentState: viewModel.contentState,
                layoutMode: viewModel.displaySetting.layoutMode,
                columnCount: viewModel.displaySetting.columnCount,
                showsNoteCount: viewModel.displaySetting.showsNoteCount,
                titleDisplayMode: viewModel.displaySetting.titleDisplayMode,
                isEditing: viewModel.isEditing,
                selectedBookIDs: viewModel.selectedBookIDSet,
                canReorder: viewModel.canReorderBooksInDefaultGroup,
                movableBookIDs: viewModel.movableBookIDs,
                supportsContextPin: viewModel.supportsContextPin,
                activeWriteAction: viewModel.activeWriteAction,
                bottomContentInset: bottomContentInset,
                onToggleSelection: viewModel.toggleSelection,
                onOpenBook: { bookID in
                    onOpenRoute(.detail(bookId: bookID))
                },
                onContextAction: handleContextAction(_:bookID:),
                onCommitOrder: viewModel.commitBooksInDefaultGroupOrder
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .animation(.snappy(duration: 0.24, extraBounce: 0.04), value: viewModel.isEditing)
        .background(Color.surfacePage.ignoresSafeArea())
        .navigationTitle(viewModel.navigationTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if !viewModel.isEditing {
                    Button {
                        showsDisplaySettingSheet = true
                    } label: {
                        Image(systemName: "slider.horizontal.3")
                    }
                    .accessibilityLabel("显示设置")

                    if viewModel.canEnterEditing {
                        Button("选择", action: viewModel.enterEditing)
                    }
                }
            }
        }
        .overlay(alignment: .bottom) {
            editBottomBarOverlay
        }
        .onChange(of: viewModel.isEditing) { _, isEditing in
            if isEditing {
                cancelBottomInsetRelease()
            } else {
                retainBottomInsetDuringEditExit()
            }
        }
        .onPreferenceChange(BookshelfBookListEditBottomInsetPreferenceKey.self) { inset in
            guard reservesEditBottomInset else { return }
            guard bottomContentInset != inset else { return }
            bottomContentInset = inset
        }
        .onPreferenceChange(ImmersiveBottomChromeHeightPreferenceKey.self) { height in
            guard viewModel.isEditing, abs(bottomOrnamentHeight - height) > 0.5 else { return }
            bottomOrnamentHeight = height
        }
        .onDisappear {
            releaseBottomInsetImmediately()
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
                allowsEmptySelection: let allowsEmptySelection
            ):
                BookshelfBatchTagsSheet(
                    options: options,
                    selectedCount: viewModel.selectedCount,
                    initialSelectedIDs: initialSelectedIDs,
                    allowsEmptySelection: allowsEmptySelection,
                    onConfirm: viewModel.submitBatchTags
                )
            case .source(options: let options, initialSelectedID: let initialSelectedID):
                BookshelfBatchSourceSheet(
                    options: options,
                    selectedCount: viewModel.selectedCount,
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
                    selectedCount: viewModel.selectedCount,
                    initialStatusID: initialStatusID,
                    initialChangedAt: initialChangedAt,
                    initialRatingScore: initialRatingScore,
                    onConfirm: viewModel.submitBatchReadStatus
                )
            case .moveGroup(options: let options):
                BookshelfMoveGroupSheet(
                    options: options,
                    selectedCount: viewModel.selectedCount,
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
    private var editBottomBarOverlay: some View {
        GeometryReader { proxy in
            let metrics = bottomChromeMetrics(safeAreaBottomInset: proxy.safeAreaInsets.bottom)

            if viewModel.isEditing {
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
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if reservesEditBottomInset {
                Color.clear
                    .preference(key: BookshelfBookListEditBottomInsetPreferenceKey.self, value: metrics.readableInset)
            } else {
                Color.clear
                    .preference(key: BookshelfBookListEditBottomInsetPreferenceKey.self, value: 0)
            }
        }
        .allowsHitTesting(viewModel.isEditing)
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
        viewModel.isEditing || isRetainingBottomInsetForEditExit || bottomContentInset > 0
    }

    /// 编辑态退场时短暂保留底部滚动避让，避免玻璃栏动画尚未结束时列表坐标系先变。
    /// - Note: 延迟任务运行在 MainActor；再次进入编辑态或页面消失会取消任务，避免旧任务回写新的列表状态。
    private func retainBottomInsetDuringEditExit() {
        bottomInsetReleaseTask?.cancel()
        guard bottomContentInset > 0 || bottomOrnamentHeight > 0 else {
            isRetainingBottomInsetForEditExit = false
            bottomInsetReleaseTask = nil
            return
        }

        isRetainingBottomInsetForEditExit = true
        let delay: Duration = reduceMotion ? .milliseconds(120) : .milliseconds(280)
        bottomInsetReleaseTask = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            isRetainingBottomInsetForEditExit = false
            bottomContentInset = 0
            bottomOrnamentHeight = 0
            bottomInsetReleaseTask = nil
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
            viewModel.enterEditing()
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
    let selectedBookIDs: Set<Int64>
    let canReorder: Bool
    let movableBookIDs: Set<Int64>
    let supportsContextPin: Bool
    let activeWriteAction: BookshelfBookListEditAction?
    let bottomContentInset: CGFloat
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
            selectedBookIDs: selectedBookIDs,
            canReorder: canReorder,
            movableBookIDs: movableBookIDs,
            supportsContextPin: supportsContextPin,
            activeWriteAction: activeWriteAction,
            bottomContentInset: bottomContentInset,
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
    let selectedBookIDs: Set<Int64>
    let canReorder: Bool
    let movableBookIDs: Set<Int64>
    let supportsContextPin: Bool
    let activeWriteAction: BookshelfBookListEditAction?
    let bottomContentInset: CGFloat
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
        selectedBookIDs: [],
        canReorder: false,
        movableBookIDs: [],
        supportsContextPin: false,
        activeWriteAction: nil,
        bottomContentInset: 0,
        onToggleSelection: { _ in },
        onOpenBook: { _ in },
        onContextAction: { _, _ in },
        onCommitOrder: { _ in }
    )
}

/// 二级书籍列表 item 类型，把 subtitle、empty 与书籍行统一交给 collection view 管理。
private enum BookshelfBookListCollectionItem: Hashable {
    case subtitle(String)
    case loading
    case empty
    case book(BookshelfBookListItem)
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

    /// 布局前保存当前可见锚点，避免 safe area 调整后只能拿到跳变后的 cell 位置。
    override func layoutSubviews() {
        onBeforeLayoutSubviews?()
        super.layoutSubviews()
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
            BookshelfBookListSectionHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: BookshelfBookListSectionHeaderView.reuseIdentifier
        )
        view.onBeforeLayoutSubviews = { [weak self] in
            self?.storeViewportAnchorIfPossible(requiresLayout: false)
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
        let nextSections = Self.makeSections(from: configuration)
        let didChangeEditing = configuration.isEditing != self.configuration.isEditing
        let needsLayoutUpdate = configuration.layoutMode != self.configuration.layoutMode
            || configuration.columnCount != self.configuration.columnCount
            || configuration.showsNoteCount != self.configuration.showsNoteCount
            || configuration.titleDisplayMode != self.configuration.titleDisplayMode
        self.configuration = configuration
        collectionView.dragInteractionEnabled = configuration.canReorder
        updateBottomContentInset()
        if needsLayoutUpdate {
            collectionView.setCollectionViewLayout(makeLayout(for: configuration), animated: animated)
        }
        guard nextSections != sections else {
            refreshVisibleCells()
            if didChangeEditing || needsLayoutUpdate {
                collectionView.collectionViewLayout.invalidateLayout()
            }
            return
        }
        sections = nextSections
        collectionView.reloadData()
    }

    /// 清理拖拽缓存，供 SwiftUI 销毁或复用承载视图时恢复稳定状态。
    func prepareForReuse() {
        pendingConfiguration = nil
        originalSectionsBeforeDrag = []
        isInteractiveReordering = false
        didChangeOrderInCurrentSession = false
        didReceiveDropInCurrentSession = false
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

    /// 按当前显示设置生成布局；书籍 section 支持网格，其它副标题、加载与空态保持全宽。
    func makeLayout(for configuration: BookshelfBookListCollectionConfiguration) -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { [weak self] sectionIndex, _ in
            let usesGrid = configuration.layoutMode == .grid
                && (self?.sectionContainsBooks(at: sectionIndex) ?? false)
            let section = usesGrid
                ? Self.makeGridSection(columnCount: configuration.columnCount)
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
        let bottomInset = max(0, configuration.bottomContentInset)
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

    /// 保存当前稳定视口锚点，供后续 bottom inset 与 automatic safe area 变化恢复同一可见内容。
    func storeViewportAnchorIfPossible(requiresLayout: Bool) {
        guard !isRestoringViewport, !isViewportAnchorCaptureSuspended else { return }
        stableFallbackOffsetY = collectionView.contentOffset.y
        guard let anchor = captureViewportAnchor(requiresLayout: requiresLayout) else { return }
        stableViewportAnchor = anchor
    }

    /// 响应系统合成 inset 变化，覆盖 safe area 自动调整绕过自定义 inset 写入的路径。
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

    /// 使用 adjustedContentInset 计算合法滚动边界，兼容系统 TabBar 与自定义底栏同时参与避让。
    func clampedContentOffsetY(_ offsetY: CGFloat) -> CGFloat {
        let adjustedInset = collectionView.adjustedContentInset
        let minimumY = -adjustedInset.top
        let maximumY = max(
            minimumY,
            collectionView.contentSize.height - collectionView.bounds.height + adjustedInset.bottom
        )
        return min(max(offsetY, minimumY), maximumY)
    }

    struct ViewportAnchor {
        let indexPath: IndexPath
        let distanceFromVisibleTop: CGFloat
    }

    /// 二级列表 grid 模式只让真实书籍多列排列。
    static func makeGridSection(columnCount: Int) -> NSCollectionLayoutSection {
        let clampedColumnCount = max(2, min(columnCount, 4))
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1.0 / CGFloat(clampedColumnCount)),
            heightDimension: .estimated(190)
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
            heightDimension: .estimated(220)
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
        if !configuration.subtitle.isEmpty {
            nextSections.append(BookshelfBookListCollectionSectionState(
                id: "subtitle",
                title: nil,
                items: [.subtitle(configuration.subtitle)]
            ))
        }
        switch configuration.contentState {
        case .loading:
            nextSections.append(BookshelfBookListCollectionSectionState(id: "loading", title: nil, items: [.loading]))
        case .empty:
            nextSections.append(BookshelfBookListCollectionSectionState(id: "empty", title: nil, items: [.empty]))
        case .error(let message):
            nextSections.append(BookshelfBookListCollectionSectionState(
                id: "error",
                title: nil,
                items: [.subtitle(message.isEmpty ? "书籍加载失败" : message), .empty]
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
            guard let cell = collectionView.cellForItem(at: indexPath) as? BookshelfBookListCollectionCell,
                  let item = item(at: indexPath) else {
                continue
            }
            cell.configure(with: item, configuration: configuration)
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
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 渲染当前 item。
    func configure(
        with item: BookshelfBookListCollectionItem,
        configuration: BookshelfBookListCollectionConfiguration
    ) {
        backgroundColor = .clear
        contentConfiguration = UIHostingConfiguration {
            switch item {
            case .subtitle(let subtitle):
                BookshelfBookListSubtitleView(subtitle: subtitle)
            case .loading:
                LoadingStateView("正在整理书籍", style: .inline)
                    .frame(maxWidth: .infinity)
                    .frame(minHeight: 320)
            case .empty:
                EmptyStateView(icon: "books.vertical", message: "暂无书籍")
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

/// 二级列表搜索栏。
private struct BookshelfBookListSearchBar: View {
    @Binding var text: String
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: Spacing.compact) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)

            TextField("搜索书名、状态或来源", text: $text)
                .font(AppTypography.body)
                .textInputAutocapitalization(.never)
                .disableAutocorrection(true)

            if !text.isEmpty {
                Button(action: onClear) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除搜索")
            }
        }
        .padding(.horizontal, Spacing.base)
        .frame(minHeight: 40)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
        }
        .padding(.horizontal, Spacing.screenEdge)
        .padding(.top, Spacing.base)
    }
}

/// 二级列表副标题。
private struct BookshelfBookListSubtitleView: View {
    let subtitle: String

    var body: some View {
        Text(subtitle)
            .font(AppTypography.caption)
            .foregroundStyle(Color.textSecondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Spacing.tiny)
    }
}

/// 二级列表 grid 模式书籍卡片，复用书架封面角标与长按菜单语义。
private struct BookshelfBookListGridItemView: View {
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
        .opacity(isEditing ? (isSelected ? 1 : 0.78) : 1)
        .overlay(alignment: .topTrailing) {
            if isEditing {
                BookshelfSelectionOverlay(isSelected: isSelected)
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            if !isEditing {
                contextMenu
            }
        }
        .xmMenuNeutralTint()
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
        .opacity(isEditing ? (isSelected ? 1 : 0.78) : 1)
        .overlay(alignment: .topTrailing) {
            if isEditing {
                BookshelfSelectionOverlay(isSelected: isSelected)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(.isButton)
        .contextMenu {
            if !isEditing {
                contextMenu
            }
        }
        .xmMenuNeutralTint()
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

                    if !destructiveActions.isEmpty {
                        destructiveActionControl
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
            foregroundStyle: isEnabled ? Color.feedbackError : Color.feedbackError.opacity(0.55)
        )
    }

    private func foregroundColor(for action: BookshelfBookListEditAction) -> Color {
        if !isEnabled(action) {
            return Color.textSecondary.opacity(0.55)
        }
        return Color.textPrimary
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
