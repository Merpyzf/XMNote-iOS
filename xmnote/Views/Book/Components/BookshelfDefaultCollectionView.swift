/**
 * [INPUT]: 依赖 BookshelfItem/BookshelfDisplaySetting、BookRoute 与现有 SwiftUI 书架卡片，接收 BookGridView 注入的导航、搜索 drawer、选择、排序提交、底部滚动余量和底部栏滚动观察开关
 * [OUTPUT]: 对外提供 BookshelfDefaultCollectionView，使用 UIKit UICollectionView 承接默认书架滚动、集合顶部搜索 drawer、整项长按拖拽排序、本地预览顺序与 iOS 26 底部边缘过渡
 * [POS]: Book 模块页面私有集合区组件，被 BookGridView 的默认书架维度消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 默认书架长按菜单动作，区分单本书与分组后交由上层路由或 Repository 执行。
enum BookshelfBookContextAction: Hashable, Sendable {
    case addNote
    case pin
    case unpin
    case editBook
    case showReadingDetail
    case startReadTiming
    case organizeBooks
    case delete
}

/// 默认书架集合区，保留 SwiftUI 卡片视觉，同时由 UICollectionView 承接滚动与重排手势。
struct BookshelfDefaultCollectionView: UIViewRepresentable {
    let sections: [BookshelfDefaultSection]
    let layoutMode: BookshelfLayoutMode
    let columnCount: Int
    let contentState: BookshelfContentState
    let showsNoteCount: Bool
    let titleDisplayMode: BookshelfTitleDisplayMode
    let allowsStructuralAnimation: Bool
    let isEditing: Bool
    let bottomContentInset: CGFloat
    let searchDrawerHeight: CGFloat
    let searchPresentation: BookshelfSearchDrawerPresentation
    let isSearchPresented: Bool
    let isSearchFocused: Bool
    let searchText: String
    let searchKeyword: String
    let searchPlaceholder: String
    let searchFocusTrigger: Int
    let selectedIDs: Set<BookshelfItemID>
    let canReorder: Bool
    let isScrollObservationEnabled: Bool
    let activeWriteAction: BookshelfPendingAction?
    let movableIDs: Set<BookshelfItemID>
    let onActivateSearch: () -> Void
    let onRequestSearchFocus: () -> Void
    let onSearchKeywordChange: (String) -> Void
    let onSubmitSearch: (String) -> Void
    let onClearSearch: () -> Void
    let onCancelSearch: () -> Void
    let onSearchFocusChange: (Bool) -> Void
    let onOpenRoute: (BookRoute) -> Void
    let onToggleSelection: (BookshelfItemID) -> Void
    let onEnterEditing: (BookshelfItemID) -> Void
    let onPin: (BookshelfItemID) -> Void
    let onUnpin: (BookshelfItemID) -> Void
    let onMoveToStart: (BookshelfItemID) -> Void
    let onMoveToEnd: (BookshelfItemID) -> Void
    let onContextAction: (BookshelfBookContextAction, BookshelfItemID) -> Void
    let onCommitOrder: ([BookshelfItemID]) -> Void

    /// 创建 UIKit 承载视图并注入首帧书架配置。
    func makeUIView(context: Context) -> BookshelfDefaultCollectionHostView {
        let view = BookshelfDefaultCollectionHostView()
        view.update(with: configuration, animated: false)
        return view
    }

    /// 将 SwiftUI 最新状态同步到 UIKit；拖拽中由承载视图缓存并在结束后回放。
    func updateUIView(_ uiView: BookshelfDefaultCollectionHostView, context: Context) {
        uiView.update(with: configuration, animated: true)
    }

    /// 销毁时清理拖拽会话与缓存配置，避免复用残留影响下一次进入页面。
    static func dismantleUIView(_ uiView: BookshelfDefaultCollectionHostView, coordinator: ()) {
        uiView.prepareForReuse()
    }

    private var configuration: BookshelfDefaultCollectionConfiguration {
        BookshelfDefaultCollectionConfiguration(
            sections: sections,
            layoutMode: layoutMode,
            columnCount: max(2, min(columnCount, 4)),
            contentState: contentState,
            showsNoteCount: showsNoteCount,
            titleDisplayMode: titleDisplayMode,
            allowsStructuralAnimation: allowsStructuralAnimation,
            isEditing: isEditing,
            bottomContentInset: bottomContentInset,
            searchDrawerHeight: searchDrawerHeight,
            searchPresentation: searchPresentation,
            isSearchPresented: isSearchPresented,
            isSearchFocused: isSearchFocused,
            searchText: searchText,
            searchKeyword: searchKeyword,
            searchPlaceholder: searchPlaceholder,
            searchFocusTrigger: searchFocusTrigger,
            selectedIDs: selectedIDs,
            canReorder: canReorder,
            isScrollObservationEnabled: isScrollObservationEnabled,
            activeWriteAction: activeWriteAction,
            movableIDs: movableIDs,
            onActivateSearch: onActivateSearch,
            onRequestSearchFocus: onRequestSearchFocus,
            onSearchKeywordChange: onSearchKeywordChange,
            onSubmitSearch: onSubmitSearch,
            onClearSearch: onClearSearch,
            onCancelSearch: onCancelSearch,
            onSearchFocusChange: onSearchFocusChange,
            onOpenRoute: onOpenRoute,
            onToggleSelection: onToggleSelection,
            onEnterEditing: onEnterEditing,
            onPin: onPin,
            onUnpin: onUnpin,
            onMoveToStart: onMoveToStart,
            onMoveToEnd: onMoveToEnd,
            onContextAction: onContextAction,
            onCommitOrder: onCommitOrder
        )
    }
}

/// UIKit 内部配置模型，统一描述当前集合区渲染、交互与业务回调。
private struct BookshelfDefaultCollectionConfiguration {
    let sections: [BookshelfDefaultSection]
    let layoutMode: BookshelfLayoutMode
    let columnCount: Int
    let contentState: BookshelfContentState
    let showsNoteCount: Bool
    let titleDisplayMode: BookshelfTitleDisplayMode
    let allowsStructuralAnimation: Bool
    let isEditing: Bool
    let bottomContentInset: CGFloat
    let searchDrawerHeight: CGFloat
    let searchPresentation: BookshelfSearchDrawerPresentation
    let isSearchPresented: Bool
    let isSearchFocused: Bool
    let searchText: String
    let searchKeyword: String
    let searchPlaceholder: String
    let searchFocusTrigger: Int
    let selectedIDs: Set<BookshelfItemID>
    let canReorder: Bool
    let isScrollObservationEnabled: Bool
    let activeWriteAction: BookshelfPendingAction?
    let movableIDs: Set<BookshelfItemID>
    let onActivateSearch: () -> Void
    let onRequestSearchFocus: () -> Void
    let onSearchKeywordChange: (String) -> Void
    let onSubmitSearch: (String) -> Void
    let onClearSearch: () -> Void
    let onCancelSearch: () -> Void
    let onSearchFocusChange: (Bool) -> Void
    let onOpenRoute: (BookRoute) -> Void
    let onToggleSelection: (BookshelfItemID) -> Void
    let onEnterEditing: (BookshelfItemID) -> Void
    let onPin: (BookshelfItemID) -> Void
    let onUnpin: (BookshelfItemID) -> Void
    let onMoveToStart: (BookshelfItemID) -> Void
    let onMoveToEnd: (BookshelfItemID) -> Void
    let onContextAction: (BookshelfBookContextAction, BookshelfItemID) -> Void
    let onCommitOrder: ([BookshelfItemID]) -> Void

    var showsSearchDrawerInCollection: Bool {
        searchDrawerHeight > 0.5
    }

    var showsExpandedSearchSurface: Bool {
        searchPresentation.isPinned || isSearchPresented || isSearchFocused || hasSearchText || hasSearchKeyword
    }

    var hasSearchText: Bool {
        !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var hasSearchKeyword: Bool {
        !searchKeyword.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var showsSearchEmptyState: Bool {
        showsSearchDrawerInCollection && hasSearchKeyword && contentState == .empty
    }

    static let empty = BookshelfDefaultCollectionConfiguration(
        sections: [],
        layoutMode: .grid,
        columnCount: 3,
        contentState: .empty,
        showsNoteCount: true,
        titleDisplayMode: .standard,
        allowsStructuralAnimation: true,
        isEditing: false,
        bottomContentInset: 0,
        searchDrawerHeight: 0,
        searchPresentation: .hidden,
        isSearchPresented: false,
        isSearchFocused: false,
        searchText: "",
        searchKeyword: "",
        searchPlaceholder: "",
        searchFocusTrigger: 0,
        selectedIDs: [],
        canReorder: false,
        isScrollObservationEnabled: false,
        activeWriteAction: nil,
        movableIDs: [],
        onActivateSearch: {},
        onRequestSearchFocus: {},
        onSearchKeywordChange: { _ in },
        onSubmitSearch: { _ in },
        onClearSearch: {},
        onCancelSearch: {},
        onSearchFocusChange: { _ in },
        onOpenRoute: { _ in },
        onToggleSelection: { _ in },
        onEnterEditing: { _ in },
        onPin: { _ in },
        onUnpin: { _ in },
        onMoveToStart: { _ in },
        onMoveToEnd: { _ in },
        onContextAction: { _, _ in },
        onCommitOrder: { _ in }
    )
}

/// 默认书架集合内部的确定性尺寸，避免搜索结果切换依赖自动测量造成跳动。
private enum BookshelfDefaultCollectionMetrics {
    static let searchEmptyHeight: CGFloat = 320

    static func gridItemHeight(
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
        let authorHeight = ceil(BookshelfTypography.uiGridSubtitle.lineHeight + 1)
        return ceil(coverHeight + Spacing.half + titleHeight + Spacing.tiny + authorHeight)
    }
}

/// 默认书架集合视图子类，暴露系统 automatic inset 与布局周期变化给承载层做视口锚点恢复。
private final class BookshelfDefaultViewportStableCollectionView: UICollectionView {
    var onAdjustedContentInsetDidChange: (() -> Void)?
    var onBeforeLayoutSubviews: (() -> Void)?
    var onAfterLayoutSubviews: (() -> Void)?
    var onDidMoveToWindow: (() -> Void)?

    /// 布局前让承载层保存当前可见锚点，避免后续系统 inset 调整只能捕获到跳变后的状态。
    override func layoutSubviews() {
        onBeforeLayoutSubviews?()
        super.layoutSubviews()
        onAfterLayoutSubviews?()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        onDidMoveToWindow?()
    }

    /// UIKit 因 safe area、TabBar 或自定义 inset 合成值变化时通知承载层恢复视口锚点。
    override func adjustedContentInsetDidChange() {
        super.adjustedContentInsetDidChange()
        onAdjustedContentInsetDidChange?()
    }
}

/// UICollectionView 承载视图，负责布局切换、本地拖拽预览顺序和最终排序回调。
final class BookshelfDefaultCollectionHostView: UIView {
    private var configuration = BookshelfDefaultCollectionConfiguration.empty
    private var sections: [BookshelfDefaultSection] = []
    private var items: [BookshelfItem] = []
    private var pendingConfiguration: BookshelfDefaultCollectionConfiguration?
    private var originalItemsBeforeDrag: [BookshelfItem] = []
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
    private var pendingAnimatedInsertionIDs: Set<BookshelfItemID> = []
    private var isContentToEmptyTransitionPending = false
    private var contentToEmptyTransitionGeneration = 0
    private var pendingContentToEmptyConfiguration: BookshelfDefaultCollectionConfiguration?
    private let searchFocusRequestCoordinator = BookshelfSearchFocusRequestCoordinator()
    private var lastCollectionBounds: CGRect = .zero
    private weak var observedContentScrollController: UIViewController?
    private let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let selectionFeedback = UISelectionFeedbackGenerator()
    private lazy var keyboardAvoidanceCoordinator = BookshelfCollectionKeyboardAvoidanceCoordinator(
        hostView: self,
        scrollView: collectionView
    ) { [weak self] inset, animation in
        self?.applyKeyboardAvoidanceInset(inset, animation: animation)
    }

    private lazy var collectionView: BookshelfDefaultViewportStableCollectionView = {
        let view = BookshelfDefaultViewportStableCollectionView(
            frame: .zero,
            collectionViewLayout: makeLayout(for: configuration)
        )
        view.backgroundColor = .clear
        view.showsVerticalScrollIndicator = false
        view.alwaysBounceVertical = true
        view.delaysContentTouches = false
        view.contentInsetAdjustmentBehavior = .automatic
        view.keyboardDismissMode = .onDrag
        view.dragInteractionEnabled = false
        view.reorderingCadence = .immediate
        view.dataSource = self
        view.delegate = self
        view.dragDelegate = self
        view.dropDelegate = self
        view.register(
            BookshelfDefaultCollectionCell.self,
            forCellWithReuseIdentifier: BookshelfDefaultCollectionCell.reuseIdentifier
        )
        view.register(
            BookshelfDefaultSearchCell.self,
            forCellWithReuseIdentifier: BookshelfDefaultSearchCell.reuseIdentifier
        )
        view.register(
            BookshelfDefaultSearchEmptyCell.self,
            forCellWithReuseIdentifier: BookshelfDefaultSearchEmptyCell.reuseIdentifier
        )
        view.register(
            BookshelfDefaultSectionHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: BookshelfDefaultSectionHeaderView.reuseIdentifier
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
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        keyboardAvoidanceCoordinator.recalculate(animated: false)
        updateContentScrollObservation()
    }

    /// 同步 SwiftUI 传入状态；拖拽中保留 UIKit 本地顺序，避免每帧被外部 snapshot 打断。
    fileprivate func update(with configuration: BookshelfDefaultCollectionConfiguration, animated: Bool) {
        if isInteractiveReordering {
            pendingConfiguration = configuration
            return
        }

        if isContentToEmptyTransitionPending {
            if configuration.showsSearchEmptyState {
                pendingContentToEmptyConfiguration = configuration
                return
            }
            cancelPendingContentToEmptyTransition()
        }

        storeViewportAnchorIfPossible(requiresLayout: true)
        let previousConfiguration = self.configuration
        let previousIDs = items.map(\.id)
        let nextItems = configuration.sections.flatMap(\.items)
        let nextIDs = nextItems.map(\.id)
        let didChangeSearchDrawerVisibility = previousConfiguration.showsSearchDrawerInCollection != configuration.showsSearchDrawerInCollection
        let didChangeSearchDrawerHeight = abs(previousConfiguration.searchDrawerHeight - configuration.searchDrawerHeight) > 0.5
        let didChangeSearchEmptyState = previousConfiguration.showsSearchEmptyState != configuration.showsSearchEmptyState
        let didChangeSearchSurfaceContent = previousConfiguration.searchText != configuration.searchText
            || previousConfiguration.searchKeyword != configuration.searchKeyword
            || previousConfiguration.isSearchPresented != configuration.isSearchPresented
            || previousConfiguration.isSearchFocused != configuration.isSearchFocused
            || previousConfiguration.searchPresentation != configuration.searchPresentation
            || previousConfiguration.searchFocusTrigger != configuration.searchFocusTrigger
        let canAnimateStructuralDiff = previousConfiguration.sections.count == 1
            && configuration.sections.count == 1
            && previousConfiguration.sections.map(\.id) == configuration.sections.map(\.id)
            && previousConfiguration.showsSearchDrawerInCollection == configuration.showsSearchDrawerInCollection
            && previousConfiguration.showsSearchEmptyState == configuration.showsSearchEmptyState
            && !configuration.showsSearchEmptyState
        let needsLayoutUpdate = previousConfiguration.layoutMode != configuration.layoutMode
            || previousConfiguration.columnCount != configuration.columnCount
            || previousConfiguration.titleDisplayMode != configuration.titleDisplayMode
            || previousConfiguration.sections.map(\.id) != configuration.sections.map(\.id)
            || didChangeSearchDrawerHeight
            || didChangeSearchDrawerVisibility
            || didChangeSearchEmptyState

        let shouldAnimateContentToEmpty = shouldAnimateSearchContentToEmptyTransition(
            from: previousConfiguration,
            to: configuration,
            previousIDs: previousIDs,
            animated: animated && configuration.allowsStructuralAnimation
        )
        if shouldAnimateContentToEmpty {
            applySearchContentToEmptyTransition(
                nextConfiguration: configuration,
                previousConfiguration: previousConfiguration
            )
            return
        }

        self.configuration = configuration
        searchFocusRequestCoordinator.reconcile(
            isFocused: configuration.isSearchFocused,
            isExpanded: configuration.showsExpandedSearchSurface
        )
        sections = configuration.sections
        collectionView.dragInteractionEnabled = configuration.canReorder
        updateCollectionVisibilityForSearchDrawerPreparation()
        normalizeSearchDrawerExtraBottomInsetForCurrentState()
        updateBottomContentInset()
        configureScrollEdgeEffect()
        updateContentScrollObservation()

        let shouldAnimateStructuralChange = animated && configuration.allowsStructuralAnimation

        if needsLayoutUpdate {
            collectionView.setCollectionViewLayout(
                makeLayout(for: configuration),
                animated: shouldAnimateStructuralChange
            )
        }

        if didChangeSearchDrawerVisibility || didChangeSearchEmptyState {
            let insertedIDs = shouldAnimateSearchEmptyToContentTransition(
                from: previousConfiguration,
                to: configuration,
                nextIDs: nextIDs,
                animated: shouldAnimateStructuralChange
            ) ? Set(nextIDs) : []
            pendingAnimatedInsertionIDs.formUnion(insertedIDs)
            items = nextItems
            UIView.performWithoutAnimation {
                collectionView.reloadData()
                collectionView.layoutIfNeeded()
            }
            animateVisiblePendingInsertions()
            animateVisibleSearchEmptyIfNeeded(
                shouldAnimate: shouldAnimateStructuralChange
                    && configuration.showsSearchEmptyState
                    && previousConfiguration.showsSearchEmptyState == false
            )
            syncSearchDrawerOffsetAfterUpdate(
                previousConfiguration: previousConfiguration,
                animated: shouldAnimateStructuralChange
            )
            return
        }

        if previousIDs == nextIDs {
            items = nextItems
            if didChangeSearchSurfaceContent {
                refreshVisibleSearchCells()
            }
            refreshVisibleCells()
            syncSearchDrawerOffsetAfterUpdate(
                previousConfiguration: previousConfiguration,
                animated: shouldAnimateStructuralChange
            )
            return
        }

        let applied = canAnimateStructuralDiff
            && applyStructuralDiffUpdate(
                from: previousIDs,
                to: nextIDs,
                nextItems: nextItems,
                animated: shouldAnimateStructuralChange
            )
        if applied, didChangeSearchSurfaceContent {
            refreshVisibleSearchCells()
        }
        if !applied {
            items = nextItems
            collectionView.reloadData()
        }
        syncSearchDrawerOffsetAfterUpdate(
            previousConfiguration: previousConfiguration,
            animated: shouldAnimateStructuralChange
        )
    }

    /// 释放拖拽与缓存状态，供 SwiftUI 销毁承载视图时调用。
    func prepareForReuse() {
        clearContentScrollObservation()
        pendingConfiguration = nil
        pendingContentToEmptyConfiguration = nil
        sections = []
        items = []
        pendingAnimatedInsertionIDs.removeAll()
        isContentToEmptyTransitionPending = false
        originalItemsBeforeDrag = []
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
        collectionView.alpha = 1
        collectionView.transform = .identity
        collectionView.isUserInteractionEnabled = true
        collectionView.reloadData()
    }
}

private extension BookshelfDefaultCollectionHostView {
    /// 搭建集合视图层级并约束到宿主视图四边。
    func setupViewHierarchy() {
        addSubview(collectionView)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.accessibilityIdentifier = "bookshelf.default.collection"

        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    /// collection 尺寸变化时只重算布局与滚动边界，不把搜索结果重新加载成页面级状态。
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
        updateBottomContentInset()
        applyPendingInitialSearchDrawerOffsetIfNeeded()
        storeViewportAnchorIfPossible(requiresLayout: false)
    }

    /// 接收统一键盘协调器给出的自定义避让高度，并用同一条底部 inset 管线更新 collection。
    func applyKeyboardAvoidanceInset(
        _ inset: CGFloat,
        animation: BookshelfCollectionKeyboardAvoidanceCoordinator.AnimationContext
    ) {
        guard abs(keyboardAvoidanceInset - inset) > 0.5 else { return }
        keyboardAvoidanceInset = inset
        updateBottomContentInset(animated: animation)
    }

    /// 初始隐藏搜索抽屉时先等滚动位置收敛，避免首帧露出一个会被马上推走的半高胶囊。
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

    var searchSectionOffset: Int {
        configuration.showsSearchDrawerInCollection ? 1 : 0
    }

    var searchEmptySectionOffset: Int {
        configuration.showsSearchEmptyState ? 1 : 0
    }

    /// 判断指定集合 section 是否为搜索 drawer 专用 section。
    func isSearchSection(_ section: Int) -> Bool {
        configuration.showsSearchDrawerInCollection && section == 0
    }

    /// 判断指定集合 section 是否为搜索空结果专用 section。
    func isSearchEmptySection(_ section: Int) -> Bool {
        configuration.showsSearchEmptyState && section == searchSectionOffset
    }

    /// 将 UICollectionView section 映射回默认书架真实 section，搜索 section 不映射。
    func realSectionIndex(for collectionSection: Int) -> Int? {
        guard !isSearchSection(collectionSection),
              !isSearchEmptySection(collectionSection) else {
            return nil
        }
        let realSection = collectionSection - searchSectionOffset - searchEmptySectionOffset
        guard sections.indices.contains(realSection) else { return nil }
        return realSection
    }

    /// 将 UICollectionView indexPath 映射回真实书架 indexPath，供点击、排序与 cell 渲染复用。
    func realIndexPath(for collectionIndexPath: IndexPath) -> IndexPath? {
        guard let section = realSectionIndex(for: collectionIndexPath.section),
              sections[section].items.indices.contains(collectionIndexPath.item) else {
            return nil
        }
        return IndexPath(item: collectionIndexPath.item, section: section)
    }

    /// 默认书架目前只有单真实 section 支持排序，转换成包含搜索 section 偏移后的 UICollectionView indexPath。
    func collectionIndexPath(forRealItemIndex itemIndex: Int) -> IndexPath {
        IndexPath(item: itemIndex, section: searchSectionOffset + searchEmptySectionOffset)
    }

    /// 按当前展示模式构建 CompositionalLayout，Grid 和 List 共用同一个集合承载。
    func makeLayout(for configuration: BookshelfDefaultCollectionConfiguration) -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { sectionIndex, environment in
            if configuration.showsSearchDrawerInCollection, sectionIndex == 0 {
                return Self.makeSearchDrawerSection(height: configuration.searchDrawerHeight)
            }
            if configuration.showsSearchEmptyState,
               sectionIndex == (configuration.showsSearchDrawerInCollection ? 1 : 0) {
                return Self.makeSearchEmptySection()
            }
            let realSectionIndex = sectionIndex
                - (configuration.showsSearchDrawerInCollection ? 1 : 0)
                - (configuration.showsSearchEmptyState ? 1 : 0)
            let section: NSCollectionLayoutSection
            switch configuration.layoutMode {
            case .grid:
                section = Self.makeGridSection(
                    columnCount: configuration.columnCount,
                    containerWidth: environment.container.effectiveContentSize.width,
                    titleDisplayMode: configuration.titleDisplayMode
                )
            case .list:
                section = Self.makeListSection()
            }
            if configuration.sections.indices.contains(realSectionIndex),
               configuration.sections[realSectionIndex].title != nil {
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

    /// 构建搜索空结果 section，让空态归属 collection 内容区而不是外层页面。
    static func makeSearchEmptySection() -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .absolute(BookshelfDefaultCollectionMetrics.searchEmptyHeight)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .absolute(BookshelfDefaultCollectionMetrics.searchEmptyHeight)
        )
        let group = NSCollectionLayoutGroup.horizontal(layoutSize: groupSize, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = NSDirectionalEdgeInsets(
            top: Spacing.base,
            leading: Spacing.screenEdge,
            bottom: Spacing.base,
            trailing: Spacing.screenEdge
        )
        return section
    }

    /// 构建集合顶部搜索 drawer section，固定高度避免输入态切换时网格列宽重新计算。
    static func makeSearchDrawerSection(height: CGFloat) -> NSCollectionLayoutSection {
        let clampedHeight = max(0, height)
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .absolute(clampedHeight)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .absolute(clampedHeight)
        )
        let group = NSCollectionLayoutGroup.vertical(layoutSize: groupSize, subitems: [item])
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = .zero
        section.interGroupSpacing = 0
        return section
    }

    /// 让 UIKit 集合视图参与系统底部栏滚动观察，驱动 iOS 26 TabBar 最小化与底部边缘过渡。
    func updateContentScrollObservation() {
        guard configuration.isScrollObservationEnabled, window != nil else {
            performViewportPreservingSystemUpdate {
                clearContentScrollObservation()
            }
            return
        }

        guard let controller = nearestOwningViewController() else {
            performViewportPreservingSystemUpdate {
                clearContentScrollObservation()
            }
            return
        }

        if observedContentScrollController !== controller {
            performViewportPreservingSystemUpdate {
                clearContentScrollObservation()
                controller.setContentScrollView(collectionView, for: .bottom)
                observedContentScrollController = controller
            }
            return
        }

        if controller.contentScrollView(for: .bottom) !== collectionView {
            performViewportPreservingSystemUpdate {
                controller.setContentScrollView(collectionView, for: .bottom)
            }
        }
    }

    /// 离开默认书架可见态时释放系统底部栏观察对象，避免影响其它 Tab 或其它维度页面。
    func clearContentScrollObservation() {
        guard let controller = observedContentScrollController else { return }
        if controller.contentScrollView(for: .bottom) === collectionView {
            controller.setContentScrollView(nil, for: .bottom)
        }
        observedContentScrollController = nil
    }

    /// 包裹会影响系统 bar 观察对象的 UIKit 调用，确保 safe area 重算后仍恢复进入调用前的可见锚点。
    func performViewportPreservingSystemUpdate(_ update: () -> Void) {
        storeViewportAnchorIfPossible(requiresLayout: true)
        let fallbackOffsetY = collectionView.contentOffset.y
        let adjustedInsetBeforeUpdate = collectionView.adjustedContentInset
        isViewportAnchorCaptureSuspended = true
        update()
        collectionView.layoutIfNeeded()
        if collectionView.adjustedContentInset != adjustedInsetBeforeUpdate {
            restoreViewportAnchor(stableViewportAnchor, fallbackOffsetY: fallbackOffsetY)
        }
        isViewportAnchorCaptureSuspended = false
        lastAdjustedContentInset = collectionView.adjustedContentInset
        storeViewportAnchorIfPossible(requiresLayout: false)
    }

    /// 取当前 UIKit bridge 所属的最近视图控制器，作为系统 bar 观察 scroll view 的登记 owner。
    func nearestOwningViewController() -> UIViewController? {
        var responder: UIResponder? = self
        while let current = responder {
            if let controller = current as? UIViewController {
                return controller
            }
            responder = current.next
        }
        return nil
    }

    /// iOS 26 下保留系统默认底部 scroll edge effect，让 Liquid Glass TabBar 自行渲染过渡蒙版。
    func configureScrollEdgeEffect() {
        guard #available(iOS 26.0, *) else { return }
        collectionView.bottomEdgeEffect.isHidden = false
        collectionView.bottomEdgeEffect.style = .automatic
    }

    /// 根据搜索抽屉当前呈现状态收束额外滚动余量，避免输入态继承隐藏位空间。
    func normalizeSearchDrawerExtraBottomInsetForCurrentState() {
        guard configuration.showsSearchDrawerInCollection,
              !configuration.showsExpandedSearchSurface else {
            searchDrawerExtraBottomInset = 0
            return
        }
        searchDrawerExtraBottomInset = max(0, searchDrawerExtraBottomInset)
    }

    /// 合并真实底部浮层避让与隐藏搜索抽屉所需的额外滚动范围。
    func resolvedBottomContentInset() -> CGFloat {
        max(
            0,
            configuration.bottomContentInset,
            searchDrawerExtraBottomInset,
            keyboardAvoidanceInset
        )
    }

    /// 只增加滚动余量，不改变 collection layout，避免编辑工具栏入场时书籍网格重新排版。
    func updateBottomContentInset(
        animated animation: BookshelfCollectionKeyboardAvoidanceCoordinator.AnimationContext = .immediate
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
            isViewportAnchorCaptureSuspended = true
            collectionView.contentInset = contentInset
            collectionView.verticalScrollIndicatorInsets = indicatorInsets
            collectionView.layoutIfNeeded()
            restoreViewportAnchor(stableViewportAnchor, fallbackOffsetY: fallbackOffsetY)
            isViewportAnchorCaptureSuspended = false
            lastAdjustedContentInset = collectionView.adjustedContentInset
            storeViewportAnchorIfPossible(requiresLayout: false)
        }
        guard animation.isAnimated else {
            UIView.performWithoutAnimation(insetUpdates)
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
                configuration.searchPresentation.isPinned
                || configuration.isSearchFocused
                || searchFocusRequestCoordinator.isPending
                || configuration.hasSearchText
                || configuration.hasSearchKeyword
            )
    }

    /// 搜索抽屉刚进入 collection 或退出输入态时，同步 collection 偏移，保持它是列表的一部分。
    func syncSearchDrawerOffsetAfterUpdate(
        previousConfiguration: BookshelfDefaultCollectionConfiguration,
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

    /// 等 collection 具备稳定内容尺寸后再写入初始 offset，避免首帧被 clamp 回顶部。
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

    /// 短列表也必须能把搜索抽屉藏到导航下方；这里只扩展滚动范围，不新增覆盖层。
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

    /// 以系统 adjusted inset 为基准计算搜索抽屉隐藏所需的自定义 bottom inset。
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

    /// 将 collection 滚动到搜索 surface 完整可见的位置。
    func setSearchDrawerVisible(animated: Bool, completion: (() -> Void)? = nil) {
        guard !isInteractiveReordering,
              configuration.showsSearchDrawerInCollection else {
            completion?()
            return
        }
        collectionView.alpha = 1
        collectionView.transform = .identity
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

    /// 将普通态搜索抽屉收回到书籍列表后方，保持 collection section 结构稳定。
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
              !configuration.isSearchFocused else {
            return
        }
        searchFocusRequestCoordinator.request(configuration.onRequestSearchFocus)
    }

    /// 下拉抽屉只在普通浏览态、无焦点、无拖拽排序时接管松手后的回弹目标。
    func canSnapSearchDrawerAfterPull() -> Bool {
        configuration.showsSearchDrawerInCollection
            && configuration.searchPresentation == .hidden
            && !configuration.hasSearchText
            && !configuration.hasSearchKeyword
            && !configuration.isSearchFocused
            && !isInteractiveReordering
            && !isAdjustingSearchDrawerOffset
    }

    /// pinned 搜索为空且失焦后，用户继续向上浏览时自动回到隐藏抽屉状态。
    func collapsePinnedSearchIfNeeded(_ scrollView: UIScrollView) {
        guard configuration.searchPresentation.isPinned,
              !configuration.isSearchFocused,
              !configuration.hasSearchText,
              !configuration.hasSearchKeyword,
              configuration.showsSearchDrawerInCollection,
              !isInteractiveReordering,
              scrollView.contentOffset.y > hiddenSearchDrawerOffsetY() * 0.6 else {
            return
        }
        configuration.onCancelSearch()
    }

    /// 保存当前稳定视口锚点。该方法可在滚动、SwiftUI update 和 UIKit 布局周期中高频调用，因此只做轻量可见 cell 采样。
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

    /// 响应系统 automatic adjusted inset 变化，覆盖 TabBar 显隐和 safe area 重算绕过自定义 inset 写入的路径。
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

    /// 搜索输入态以 drawer 自身作为锚点，保证键盘 inset 改变时搜索框不被书籍 cell 锚点牵引。
    func restorePinnedSearchDrawerOffsetIfNeeded(lockedOffsetY: CGFloat? = nil) {
        let targetOffset = CGPoint(
            x: collectionView.contentOffset.x,
            y: clampedContentOffsetY(lockedOffsetY ?? searchDrawerLockedOffsetY ?? 0)
        )
        guard abs(collectionView.contentOffset.y - targetOffset.y) > 0.5 else { return }
        collectionView.setContentOffset(targetOffset, animated: false)
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

    /// Grid 模式使用动态列数和确定高度，避免搜索结果切换时 self-sizing 缓存裁剪内容。
    static func makeGridSection(
        columnCount: Int,
        containerWidth: CGFloat,
        titleDisplayMode: BookshelfTitleDisplayMode
    ) -> NSCollectionLayoutSection {
        let clampedColumnCount = max(2, min(columnCount, 4))
        let itemHeight = BookshelfDefaultCollectionMetrics.gridItemHeight(
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
        group.interItemSpacing = .fixed(0)

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

    /// List 模式使用单列全宽估算高度，保持现有列表行视觉密度。
    static func makeListSection() -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .estimated(88)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .estimated(88)
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

    /// 只刷新可见 cell 的 SwiftUI 配置，避免全量 reload 打断滚动位置。
    func refreshVisibleCells() {
        for cell in collectionView.visibleCells {
            guard let indexPath = collectionView.indexPath(for: cell),
                  let bookshelfCell = cell as? BookshelfDefaultCollectionCell else {
                continue
            }
            configureCell(bookshelfCell, at: indexPath)
        }
    }

    /// 只刷新可见搜索 cell，避免输入关键词时重建整组书架 cell。
    func refreshVisibleSearchCells() {
        for cell in collectionView.visibleCells {
            guard let indexPath = collectionView.indexPath(for: cell),
                  isSearchSection(indexPath.section),
                  let searchCell = cell as? BookshelfDefaultSearchCell else {
                continue
            }
            searchCell.configure(with: configuration)
        }
    }

    /// 判断搜索结果从内容进入空态时是否需要先播放短退场，避免列表瞬间消失。
    func shouldAnimateSearchContentToEmptyTransition(
        from previousConfiguration: BookshelfDefaultCollectionConfiguration,
        to nextConfiguration: BookshelfDefaultCollectionConfiguration,
        previousIDs: [BookshelfItemID],
        animated: Bool
    ) -> Bool {
        animated
            && collectionView.window != nil
            && !UIAccessibility.isReduceMotionEnabled
            && previousConfiguration.showsSearchDrawerInCollection
            && nextConfiguration.showsSearchDrawerInCollection
            && !previousConfiguration.showsSearchEmptyState
            && nextConfiguration.showsSearchEmptyState
            && !previousIDs.isEmpty
    }

    /// 判断搜索空态恢复为内容时是否需要给首屏结果补一段轻量进场。
    func shouldAnimateSearchEmptyToContentTransition(
        from previousConfiguration: BookshelfDefaultCollectionConfiguration,
        to nextConfiguration: BookshelfDefaultCollectionConfiguration,
        nextIDs: [BookshelfItemID],
        animated: Bool
    ) -> Bool {
        animated
            && collectionView.window != nil
            && !UIAccessibility.isReduceMotionEnabled
            && previousConfiguration.showsSearchEmptyState
            && !nextConfiguration.showsSearchEmptyState
            && !nextIDs.isEmpty
    }

    /// 取消尚未提交的内容退场动画，避免快速清空搜索时旧 completion 覆盖新列表。
    func cancelPendingContentToEmptyTransition() {
        isContentToEmptyTransitionPending = false
        contentToEmptyTransitionGeneration += 1
        pendingContentToEmptyConfiguration = nil
        for cell in collectionView.visibleCells {
            cell.layer.removeAllAnimations()
            cell.alpha = 1
            cell.transform = .identity
        }
    }

    /// 搜索结果从内容变为空态时，先让当前可见书籍短退场，再提交空态刷新。
    func applySearchContentToEmptyTransition(
        nextConfiguration: BookshelfDefaultCollectionConfiguration,
        previousConfiguration: BookshelfDefaultCollectionConfiguration
    ) {
        let generation = contentToEmptyTransitionGeneration + 1
        contentToEmptyTransitionGeneration = generation
        isContentToEmptyTransitionPending = true
        pendingContentToEmptyConfiguration = nextConfiguration

        let commitReplacement = { [weak self] in
            guard let self,
                  self.isContentToEmptyTransitionPending,
                  self.contentToEmptyTransitionGeneration == generation else {
                return
            }
            let committedConfiguration = self.pendingContentToEmptyConfiguration ?? nextConfiguration
            self.pendingContentToEmptyConfiguration = nil
            self.isContentToEmptyTransitionPending = false
            self.commitSearchStateReplacement(
                with: committedConfiguration,
                previousConfiguration: previousConfiguration,
                animateSearchEmptyEntrance: true
            )
        }

        let visibleCells = visibleBookshelfContentCells()
        guard !visibleCells.isEmpty else {
            commitReplacement()
            return
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
    }

    /// 将需要切换搜索空态 section 的刷新集中提交，避免延迟退场期间提前改变数据源 section 数。
    func commitSearchStateReplacement(
        with nextConfiguration: BookshelfDefaultCollectionConfiguration,
        previousConfiguration: BookshelfDefaultCollectionConfiguration,
        animateSearchEmptyEntrance: Bool
    ) {
        let nextItems = nextConfiguration.sections.flatMap(\.items)
        self.configuration = nextConfiguration
        searchFocusRequestCoordinator.reconcile(
            isFocused: nextConfiguration.isSearchFocused,
            isExpanded: nextConfiguration.showsExpandedSearchSurface
        )
        sections = nextConfiguration.sections
        items = nextItems
        collectionView.dragInteractionEnabled = nextConfiguration.canReorder
        updateCollectionVisibilityForSearchDrawerPreparation()
        normalizeSearchDrawerExtraBottomInsetForCurrentState()
        updateBottomContentInset()
        configureScrollEdgeEffect()
        updateContentScrollObservation()
        collectionView.setCollectionViewLayout(makeLayout(for: nextConfiguration), animated: false)
        UIView.performWithoutAnimation {
            collectionView.reloadData()
            collectionView.layoutIfNeeded()
        }
        animateVisibleSearchEmptyIfNeeded(shouldAnimate: animateSearchEmptyEntrance)
        syncSearchDrawerOffsetAfterUpdate(
            previousConfiguration: previousConfiguration,
            animated: false
        )
    }

    /// 返回当前可见的真实书架内容 cell，排除搜索 drawer 与搜索空态。
    func visibleBookshelfContentCells() -> [UICollectionViewCell] {
        collectionView.indexPathsForVisibleItems.compactMap { indexPath in
            guard let cell = collectionView.cellForItem(at: indexPath) else {
                return nil
            }
            guard !isSearchSection(indexPath.section),
                  !isSearchEmptySection(indexPath.section),
                  cell is BookshelfDefaultCollectionCell else {
                return nil
            }
            return cell
        }
    }

    /// 对已经进入可视区的搜索结果新项补充统一进场动画。
    func animateVisiblePendingInsertions() {
        guard !pendingAnimatedInsertionIDs.isEmpty else { return }
        let pendingIDs = pendingAnimatedInsertionIDs
        defer { pendingAnimatedInsertionIDs.subtract(pendingIDs) }
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let item = item(at: indexPath),
                  pendingIDs.contains(item.id),
                  let cell = collectionView.cellForItem(at: indexPath) as? BookshelfDefaultCollectionCell else {
                continue
            }
            applyResultEntranceAnimation(to: cell)
        }
    }

    /// 空态 cell 出现时使用与结果卡一致的轻量进场节奏。
    func animateVisibleSearchEmptyIfNeeded(shouldAnimate: Bool) {
        guard shouldAnimate, !UIAccessibility.isReduceMotionEnabled else { return }
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard isSearchEmptySection(indexPath.section),
                  let cell = collectionView.cellForItem(at: indexPath) else {
                continue
            }
            applyResultEntranceAnimation(to: cell)
        }
    }

    /// 搜索过滤新增项的统一轻量进场，传达结果恢复但不制造页面级转场。
    func applyResultEntranceAnimation(to cell: UICollectionViewCell) {
        cell.layer.removeAllAnimations()
        cell.alpha = 0
        cell.transform = CGAffineTransform(translationX: 0, y: 8).scaledBy(x: 0.985, y: 0.985)
        UIView.animate(
            withDuration: BookshelfManagementMotion.bookListResultTransitionDuration,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut]
        ) {
            cell.alpha = 1
            cell.transform = .identity
        }
    }

    /// 绑定 cell 内容，仍复用现有 SwiftUI 书籍、分组与列表行组件。
    func configureCell(_ cell: BookshelfDefaultCollectionCell, at indexPath: IndexPath) {
        guard let item = item(at: indexPath) else { return }
        cell.configure(
            with: BookshelfDefaultCollectionCellContent(
                item: item,
                layoutMode: configuration.layoutMode,
                showsNoteCount: configuration.showsNoteCount,
                titleDisplayMode: configuration.titleDisplayMode,
                searchKeyword: configuration.searchKeyword,
                isEditing: configuration.isEditing,
                isSelected: configuration.selectedIDs.contains(item.id),
                canMove: configuration.movableIDs.contains(item.id),
                activeWriteAction: configuration.activeWriteAction,
                onContextAction: configuration.onContextAction
            )
        )
    }

    func item(at indexPath: IndexPath) -> BookshelfItem? {
        guard let realIndexPath = realIndexPath(for: indexPath),
              sections[realIndexPath.section].items.indices.contains(realIndexPath.item) else {
            return nil
        }
        return sections[realIndexPath.section].items[realIndexPath.item]
    }

    /// 外部结构变化转换为批量更新动画；不适合动画时由调用方回退 reloadData。
    func applyStructuralDiffUpdate(
        from previousIDs: [BookshelfItemID],
        to nextIDs: [BookshelfItemID],
        nextItems: [BookshelfItem],
        animated: Bool
    ) -> Bool {
        guard animated,
              collectionView.window != nil,
              !UIAccessibility.isReduceMotionEnabled,
              Set(previousIDs).count == previousIDs.count,
              Set(nextIDs).count == nextIDs.count else {
            return false
        }

        let diff = nextIDs.difference(from: previousIDs).inferringMoves()
        var deletions: [IndexPath] = []
        var insertions: [IndexPath] = []
        var moves: [(from: IndexPath, to: IndexPath)] = []
        var insertedIDs: Set<BookshelfItemID> = []

        for change in diff {
            switch change {
            case let .remove(offset, _, associatedWith):
                if let destination = associatedWith {
                    moves.append((
                        from: collectionIndexPath(forRealItemIndex: offset),
                        to: collectionIndexPath(forRealItemIndex: destination)
                    ))
                } else {
                    deletions.append(collectionIndexPath(forRealItemIndex: offset))
                }
            case let .insert(offset, id, associatedWith):
                if associatedWith == nil {
                    insertions.append(collectionIndexPath(forRealItemIndex: offset))
                    insertedIDs.insert(id)
                }
            }
        }

        guard !deletions.isEmpty || !insertions.isEmpty || !moves.isEmpty else {
            return false
        }

        pendingAnimatedInsertionIDs.formUnion(insertedIDs)
        items = nextItems
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
            self?.pendingAnimatedInsertionIDs.subtract(insertedIDs)
            self?.refreshVisibleCells()
        }
        return true
    }

    /// 判断指定位置是否允许启动排序；置顶项和非排序态始终返回 false。
    func canBeginReorder(at indexPath: IndexPath) -> Bool {
        guard configuration.canReorder,
              let realIndexPath = realIndexPath(for: indexPath),
              realIndexPath.section == 0,
              items.indices.contains(realIndexPath.item) else {
            return false
        }
        return !items[realIndexPath.item].pinned
    }

    /// 记录拖拽初始状态，后续取消时可恢复 UIKit 本地预览顺序。
    func beginReorderSession(at indexPath: IndexPath) {
        guard !isInteractiveReordering else { return }
        isInteractiveReordering = true
        didChangeOrderInCurrentSession = false
        didReceiveDropInCurrentSession = false
        originalItemsBeforeDrag = items
        impactFeedback.prepare()
        impactFeedback.impactOccurred(intensity: 0.82)
        selectionFeedback.prepare()
    }

    /// 结束拖拽：成功 drop 后一次性提交最终顺序；取消则恢复拖拽前本地预览。
    func finishReorderSession() {
        guard isInteractiveReordering else { return }
        let originalIDs = originalItemsBeforeDrag.map(\.id)
        let currentIDs = items.map(\.id)
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
            items = originalItemsBeforeDrag
            replaceSingleSectionItems(items)
            collectionView.reloadData()
        }
        originalItemsBeforeDrag = []

        if let pendingConfiguration {
            self.pendingConfiguration = nil
            update(with: pendingConfiguration, animated: false)
        }
    }

    /// 计算普通项重排的目标位置，禁止普通项落入置顶前缀区。
    func normalizedDestinationIndexPath(
        for proposed: IndexPath?,
        movingItemID: BookshelfItemID?
    ) -> IndexPath? {
        guard !items.isEmpty else { return nil }
        let lowerBound = pinnedPrefixCount()
        let proposedRealIndexPath = proposed.flatMap { realIndexPath(for: $0) }
        var proposedItem = proposedRealIndexPath?.item ?? (items.count - 1)
        if let proposed, isSearchSection(proposed.section) {
            proposedItem = lowerBound
        }
        proposedItem = min(max(lowerBound, proposedItem), items.count - 1)

        if let movingItemID,
           let sourceIndex = items.firstIndex(where: { $0.id == movingItemID }),
           items[sourceIndex].pinned {
            return collectionIndexPath(forRealItemIndex: sourceIndex)
        }
        return collectionIndexPath(forRealItemIndex: proposedItem)
    }

    /// 置顶项必须保持当前前缀顺序，不参与普通区重排。
    func pinnedPrefixCount() -> Int {
        items.prefix { $0.pinned }.count
    }

    /// 在 UIKit 本地顺序中执行移动，供数据源移动和 drop 兜底共用。
    func applyLocalMove(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex,
              items.indices.contains(sourceIndex),
              items.indices.contains(destinationIndex),
              !items[sourceIndex].pinned,
              destinationIndex >= pinnedPrefixCount() else {
            return
        }
        items.xmBookshelfMove(from: sourceIndex, to: destinationIndex)
        replaceSingleSectionItems(items)
        didChangeOrderInCurrentSession = true
        refreshVisibleCells()
    }

    func replaceSingleSectionItems(_ nextItems: [BookshelfItem]) {
        guard sections.count == 1 else { return }
        sections[0] = BookshelfDefaultSection(
            id: sections[0].id,
            title: sections[0].title,
            items: nextItems
        )
    }

    /// 由 Book/Group 载荷构造主导航路由。
    func route(for item: BookshelfItem) -> BookRoute {
        switch item.content {
        case .book(let book):
            return .detail(bookId: book.id)
        case .group(let group):
            return .bookshelfList(route(for: group))
        }
    }

    /// 分组卡片进入二级书籍列表时，复用 SwiftUI 旧路径的路由载荷。
    func route(for group: BookshelfGroupPayload) -> BookshelfBookListRoute {
        BookshelfBookListRoute(
            context: .defaultGroup(group.id),
            title: group.name,
            subtitleHint: "\(group.bookCount)本"
        )
    }
}

extension BookshelfDefaultCollectionHostView: UICollectionViewDataSource {
    /// 返回默认书架当前 section 数量。
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        sections.count + searchSectionOffset + searchEmptySectionOffset
    }

    /// 返回默认书架当前可见顶层条目数量。
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        if isSearchSection(section) {
            return 1
        }
        if isSearchEmptySection(section) {
            return 1
        }
        guard let realSection = realSectionIndex(for: section) else { return 0 }
        return sections[realSection].items.count
    }

    /// 配置默认书架 cell 的 SwiftUI 内容。
    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        if isSearchSection(indexPath.section) {
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: BookshelfDefaultSearchCell.reuseIdentifier,
                for: indexPath
            ) as? BookshelfDefaultSearchCell else {
                return UICollectionViewCell()
            }
            cell.configure(with: configuration)
            return cell
        }
        if isSearchEmptySection(indexPath.section) {
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: BookshelfDefaultSearchEmptyCell.reuseIdentifier,
                for: indexPath
            ) as? BookshelfDefaultSearchEmptyCell else {
                return UICollectionViewCell()
            }
            cell.configure()
            return cell
        }
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: BookshelfDefaultCollectionCell.reuseIdentifier,
            for: indexPath
        ) as? BookshelfDefaultCollectionCell else {
            return UICollectionViewCell()
        }
        configureCell(cell, at: indexPath)
        return cell
    }

    /// 配置条件排序分区标题。
    func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        guard kind == UICollectionView.elementKindSectionHeader,
              let header = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: BookshelfDefaultSectionHeaderView.reuseIdentifier,
                for: indexPath
              ) as? BookshelfDefaultSectionHeaderView,
              let realSection = realSectionIndex(for: indexPath.section),
              let title = sections[realSection].title else {
            return UICollectionReusableView()
        }
        header.configure(title: title)
        return header
    }

    /// 告知 UICollectionView 哪些条目具备系统重排资格。
    func collectionView(_ collectionView: UICollectionView, canMoveItemAt indexPath: IndexPath) -> Bool {
        canBeginReorder(at: indexPath)
    }

    /// 系统立即重排时同步 UIKit 本地数据源，最终落库仍在拖拽结束后统一提交。
    func collectionView(
        _ collectionView: UICollectionView,
        moveItemAt sourceIndexPath: IndexPath,
        to destinationIndexPath: IndexPath
    ) {
        guard let realSourceIndexPath = realIndexPath(for: sourceIndexPath) else { return }
        guard let destination = normalizedDestinationIndexPath(
            for: destinationIndexPath,
            movingItemID: items.indices.contains(realSourceIndexPath.item) ? items[realSourceIndexPath.item].id : nil
        ) else {
            return
        }
        applyLocalMove(from: realSourceIndexPath.item, to: destination.item)
    }
}

extension BookshelfDefaultCollectionHostView: UICollectionViewDelegate {
    /// 批量更新插入的搜索结果 cell 在进入首屏时补一段轻量进场。
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let item = item(at: indexPath),
              pendingAnimatedInsertionIDs.contains(item.id) else {
            return
        }
        pendingAnimatedInsertionIDs.remove(item.id)
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        applyResultEntranceAnimation(to: cell)
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

    /// 点击条目：编辑态切换选择，普通态走 SwiftUI 主导航路由。
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = item(at: indexPath) else { return }
        if configuration.isEditing {
            configuration.onToggleSelection(item.id)
        } else {
            configuration.onOpenRoute(route(for: item))
        }
    }

    /// 重排目标归一化，保证普通项不能插入置顶前缀。
    func collectionView(
        _ collectionView: UICollectionView,
        targetIndexPathForMoveFromItemAt originalIndexPath: IndexPath,
        toProposedIndexPath proposedIndexPath: IndexPath
    ) -> IndexPath {
        let realOriginalIndexPath = realIndexPath(for: originalIndexPath)
        return normalizedDestinationIndexPath(
            for: proposedIndexPath,
            movingItemID: realOriginalIndexPath.flatMap { items.indices.contains($0.item) ? items[$0.item].id : nil }
        ) ?? originalIndexPath
    }
}

extension BookshelfDefaultCollectionHostView: UICollectionViewDragDelegate {
    /// 仅允许默认书架普通项启动本地长按拖拽排序。
    func collectionView(
        _ collectionView: UICollectionView,
        itemsForBeginning session: UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        guard canBeginReorder(at: indexPath),
              let realIndexPath = realIndexPath(for: indexPath),
              items.indices.contains(realIndexPath.item) else {
            return []
        }
        beginReorderSession(at: indexPath)
        let itemID = items[realIndexPath.item].id
        let itemProvider = NSItemProvider(object: NSString(string: itemID.dragProviderKey))
        let dragItem = UIDragItem(itemProvider: itemProvider)
        dragItem.localObject = itemID
        return [dragItem]
    }

    /// 拖拽结束后收束本地顺序并决定提交或恢复。
    func collectionView(_ collectionView: UICollectionView, dragSessionDidEnd session: UIDragSession) {
        finishReorderSession()
    }
}

extension BookshelfDefaultCollectionHostView: UICollectionViewDropDelegate {
    /// 默认书架排序只接受本地拖拽，拒绝跨应用投递。
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

        let movingID = dropItem.dragItem.localObject as? BookshelfItemID
        guard let movingID,
              let sourceIndex = items.firstIndex(where: { $0.id == movingID }),
              let destination = normalizedDestinationIndexPath(
                for: coordinator.destinationIndexPath,
                movingItemID: movingID
              ) else {
            return
        }

        if sourceIndex != destination.item {
            collectionView.performBatchUpdates { [weak self] in
                guard let self else { return }
                self.applyLocalMove(from: sourceIndex, to: destination.item)
                collectionView.moveItem(
                    at: self.collectionIndexPath(forRealItemIndex: sourceIndex),
                    to: destination
                )
            } completion: { [weak self] _ in
                self?.selectionFeedback.selectionChanged()
            }
        }
        coordinator.drop(dropItem.dragItem, toItemAt: destination)
    }
}

/// 默认书架集合顶部搜索 cell，复用统一 search surface 承载输入、清除和取消状态。
private final class BookshelfDefaultSearchCell: UICollectionViewCell {
    static let reuseIdentifier = "BookshelfDefaultSearchCell"
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

    /// 使用默认书架搜索配置刷新共享 surface。
    func configure(with configuration: BookshelfDefaultCollectionConfiguration) {
        searchSurface.configure(with: BookshelfSearchSurfaceConfiguration(
            namespace: "bookshelf.default.search",
            placeholder: configuration.searchPlaceholder,
            keyword: configuration.searchText,
            showsInput: configuration.showsExpandedSearchSurface,
            showsClearAction: configuration.hasSearchText || configuration.hasSearchKeyword,
            usesAccessibilityLayout: configuration.searchDrawerHeight > 56,
            focusTrigger: configuration.searchFocusTrigger,
            accessibilityLabel: "搜索当前书架",
            onActivate: configuration.onActivateSearch,
            onTextChange: configuration.onSearchKeywordChange,
            onSubmit: configuration.onSubmitSearch,
            onClear: configuration.onClearSearch,
            onCancel: configuration.onCancelSearch,
            onFocusChange: configuration.onSearchFocusChange
        ))
    }

    /// 将搜索 surface 固定在集合 section 内，左右边距对齐书架内容边界。
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

/// 默认书架搜索无结果 cell，保持搜索 drawer 仍在 collection 顶部。
private final class BookshelfDefaultSearchEmptyCell: UICollectionViewCell {
    static let reuseIdentifier = "BookshelfDefaultSearchEmptyCell"

    override func prepareForReuse() {
        super.prepareForReuse()
        contentConfiguration = nil
        layer.removeAllAnimations()
        alpha = 1
        transform = .identity
    }

    /// 刷新默认书架搜索空态文案。
    func configure() {
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        contentConfiguration = UIHostingConfiguration {
            BookshelfContextualEmptyStateView(
                icon: "books.vertical",
                title: "没有匹配的书籍",
                message: "清除搜索后查看全部书籍",
                iconColor: Color.brand.opacity(0.30)
            )
            .frame(minHeight: BookshelfDefaultCollectionMetrics.searchEmptyHeight)
        }
        .margins(.all, 0)
    }
}

/// 默认书架条件排序分区标题。
private final class BookshelfDefaultSectionHeaderView: UICollectionReusableView {
    static let reuseIdentifier = "BookshelfDefaultSectionHeaderView"
    private let titleLabel = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupViewHierarchy()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 渲染分区标题。
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

/// 默认书架 collection cell，内部通过 UIHostingConfiguration 承载 SwiftUI 内容。
private final class BookshelfDefaultCollectionCell: UICollectionViewCell {
    static let reuseIdentifier = "BookshelfDefaultCollectionCell"

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
        layer.removeAllAnimations()
        alpha = 1
        transform = .identity
    }

    /// 使用现有 SwiftUI 书架内容作为 cell 渲染配置。
    func configure(with content: BookshelfDefaultCollectionCellContent) {
        contentConfiguration = UIHostingConfiguration {
            content
        }
        .margins(.all, 0)
    }
}

/// 单个默认书架 cell 的 SwiftUI 内容，集中处理编辑态选中视觉和 context menu。
private struct BookshelfDefaultCollectionCellContent: View {
    let item: BookshelfItem
    let layoutMode: BookshelfLayoutMode
    let showsNoteCount: Bool
    let titleDisplayMode: BookshelfTitleDisplayMode
    let searchKeyword: String
    let isEditing: Bool
    let isSelected: Bool
    let canMove: Bool
    let activeWriteAction: BookshelfPendingAction?
    let onContextAction: (BookshelfBookContextAction, BookshelfItemID) -> Void

    var body: some View {
        itemLabel
            .frame(
                maxWidth: .infinity,
                maxHeight: layoutMode == .grid ? .infinity : nil,
                alignment: .topLeading
            )
            .modifier(BookshelfDefaultCollectionSelectionModifier(
                isEditing: isEditing,
                isSelected: isSelected
            ))
            .contextMenu {
                contextMenu
            }
            .xmMenuNeutralTint()
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityIdentifier(accessibilityIdentifier)
            .accessibilityAddTraits(.isButton)
    }

    @ViewBuilder
    private var itemLabel: some View {
        switch layoutMode {
        case .grid:
            switch item.content {
            case .book(let book):
                BookGridItemView(
                    book: book,
                    showsNoteCount: showsNoteCount,
                    isPinned: item.pinned,
                    titleDisplayMode: titleDisplayMode,
                    searchKeyword: searchKeyword
                )
            case .group(let group):
                BookshelfGroupGridItemView(
                    group: group,
                    isPinned: item.pinned,
                    titleDisplayMode: titleDisplayMode,
                    searchKeyword: searchKeyword
                )
            }
        case .list:
            BookshelfDefaultListRow(
                item: item,
                showsNoteCount: showsNoteCount,
                titleDisplayMode: titleDisplayMode,
                searchKeyword: searchKeyword
            )
        }
    }

    @ViewBuilder
    private var contextMenu: some View {
        switch item.content {
        case .book:
            Button {
                onContextAction(.addNote, item.id)
            } label: {
                XMMenuLabel("添加笔记", systemImage: "square.and.pencil")
            }

            pinMenuButton

            Button {
                onContextAction(.editBook, item.id)
            } label: {
                XMMenuLabel("编辑书籍", systemImage: "pencil")
            }

            Button {
                onContextAction(.showReadingDetail, item.id)
            } label: {
                XMMenuLabel("阅读详情", systemImage: "chart.bar.doc.horizontal")
            }

            Button {
                onContextAction(.startReadTiming, item.id)
            } label: {
                XMMenuLabel("开始计时", systemImage: "timer")
            }

            Button {
                onContextAction(.organizeBooks, item.id)
            } label: {
                XMMenuLabel("整理书籍", systemImage: "checklist")
            }

            Button(role: .destructive) {
                onContextAction(.delete, item.id)
            } label: {
                Label("删除书籍", systemImage: "trash")
            }
            .disabled(activeWriteAction != nil)
        case .group:
            pinMenuButton

            Button {
                onContextAction(.organizeBooks, item.id)
            } label: {
                XMMenuLabel("整理书籍", systemImage: "checklist")
            }

            Button(role: .destructive) {
                onContextAction(.delete, item.id)
            } label: {
                Label("删除分组", systemImage: "trash")
            }
            .disabled(activeWriteAction != nil)
        }
    }

    @ViewBuilder
    private var pinMenuButton: some View {
        if item.pinned {
                Button {
                    onContextAction(.unpin, item.id)
                } label: {
                    XMMenuLabel("取消置顶", systemImage: "pin.slash")
                }
                .disabled(activeWriteAction != nil)
            } else {
                Button {
                    onContextAction(.pin, item.id)
                } label: {
                    XMMenuLabel("置顶", systemImage: "pin")
                }
                .disabled(activeWriteAction != nil)
            }
    }

    private var accessibilityLabel: String {
        if isEditing {
            return "\(item.title)，\(isSelected ? "已选中" : "未选中")"
        }
        return item.title
    }

    private var accessibilityIdentifier: String {
        switch item.id {
        case .book(let id):
            return "bookshelf.default.book.\(id)"
        case .group(let id):
            return "bookshelf.default.group.\(id)"
        }
    }
}

/// 编辑态选中外观，复用旧 SwiftUI 路径中的选择勾选与边框反馈。
private struct BookshelfDefaultCollectionSelectionModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isEditing: Bool
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isEditing ? (isSelected ? 1 : 0.92) : 1)
            .overlay(alignment: .bottomLeading) {
                if isEditing {
                    BookshelfSelectionOverlay(isSelected: isSelected)
                        .transition(selectionOverlayTransition)
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                    .stroke(
                        isEditing && isSelected ? Color.brand.opacity(0.42) : Color.clear,
                        lineWidth: isEditing && isSelected ? 1 : 0
                    )
            }
            .contentShape(RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
            .animation(selectionAnimation, value: isEditing)
            .animation(selectionAnimation, value: isSelected)
    }

    private var selectionAnimation: Animation? {
        reduceMotion ? .easeInOut(duration: 0.12) : .smooth(duration: 0.16)
    }

    private var selectionOverlayTransition: AnyTransition {
        reduceMotion ? .opacity : .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 0, y: -2)),
            removal: .opacity
        )
    }
}

private extension BookshelfItemID {
    var dragProviderKey: String {
        switch self {
        case .book(let id):
            return "book:\(id)"
        case .group(let id):
            return "group:\(id)"
        }
    }
}

private extension Array where Element == BookshelfItem {
    /// 将默认书架条目从 source 索引移动到 destination 索引。
    mutating func xmBookshelfMove(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex,
              indices.contains(sourceIndex),
              indices.contains(destinationIndex) else {
            return
        }
        let item = remove(at: sourceIndex)
        insert(item, at: destinationIndex)
    }
}
