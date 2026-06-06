/**
 * [INPUT]: 依赖 BookshelfAggregateGroup、BookshelfDisplaySetting 与 BookRoute，接收 BookGridView 注入的导航、搜索 drawer 和聚合排序提交闭包
 * [OUTPUT]: 对外提供 BookshelfAggregateCollectionView，使用 UIKit UICollectionView 承接非默认维度聚合入口滚动、集合顶部搜索 drawer、按列数约束的 Grid/List 布局与可选排序
 * [POS]: Book 模块页面私有集合区组件，被 BookGridView 的状态、标签、来源、评分、作者与出版社维度消费
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 聚合维度中的一个 collection section。
struct BookshelfAggregateCollectionSection: Hashable {
    let id: String
    let title: String?
    let groups: [BookshelfAggregateGroup]
}

/// 聚合卡长按菜单动作，当前仅作者/出版社维度开放编辑与删除。
enum BookshelfAggregateContextAction: Hashable {
    case edit
    case delete
}

/// 非默认维度聚合入口集合区，保留 SwiftUI 卡片视觉，同时由 UICollectionView 承接滚动与排序。
struct BookshelfAggregateCollectionView: UIViewRepresentable {
    let sections: [BookshelfAggregateCollectionSection]
    let layoutMode: BookshelfLayoutMode
    let columnCount: Int
    let contentState: BookshelfContentState
    let searchDrawerHeight: CGFloat
    let searchPresentation: BookshelfSearchDrawerPresentation
    let isSearchPresented: Bool
    let isSearchFocused: Bool
    let searchText: String
    let searchKeyword: String
    let searchPlaceholder: String
    let searchFocusTrigger: Int
    let canReorder: Bool
    let onActivateSearch: () -> Void
    let onRequestSearchFocus: () -> Void
    let onSearchKeywordChange: (String) -> Void
    let onSubmitSearch: (String) -> Void
    let onClearSearch: () -> Void
    let onCancelSearch: () -> Void
    let onSearchFocusChange: (Bool) -> Void
    let onOpenRoute: (BookRoute) -> Void
    let onContextAction: (BookshelfAggregateContextAction, BookshelfAggregateGroup) -> Void
    let onCommitOrder: ([Int64]) -> Void

    /// 创建 UIKit 承载视图并注入首帧配置。
    func makeUIView(context: Context) -> BookshelfAggregateCollectionHostView {
        let view = BookshelfAggregateCollectionHostView()
        view.update(with: configuration, animated: false)
        return view
    }

    /// 同步 SwiftUI 最新状态。
    func updateUIView(_ uiView: BookshelfAggregateCollectionHostView, context: Context) {
        uiView.update(with: configuration, animated: true)
    }

    private var configuration: BookshelfAggregateCollectionConfiguration {
        BookshelfAggregateCollectionConfiguration(
            sections: sections,
            layoutMode: layoutMode,
            columnCount: max(1, min(columnCount, 6)),
            contentState: contentState,
            searchDrawerHeight: searchDrawerHeight,
            searchPresentation: searchPresentation,
            isSearchPresented: isSearchPresented,
            isSearchFocused: isSearchFocused,
            searchText: searchText,
            searchKeyword: searchKeyword,
            searchPlaceholder: searchPlaceholder,
            searchFocusTrigger: searchFocusTrigger,
            canReorder: canReorder && sections.count == 1,
            onActivateSearch: onActivateSearch,
            onRequestSearchFocus: onRequestSearchFocus,
            onSearchKeywordChange: onSearchKeywordChange,
            onSubmitSearch: onSubmitSearch,
            onClearSearch: onClearSearch,
            onCancelSearch: onCancelSearch,
            onSearchFocusChange: onSearchFocusChange,
            onOpenRoute: onOpenRoute,
            onContextAction: onContextAction,
            onCommitOrder: onCommitOrder
        )
    }
}

/// UIKit 聚合集合区输入配置。
private struct BookshelfAggregateCollectionConfiguration {
    let sections: [BookshelfAggregateCollectionSection]
    let layoutMode: BookshelfLayoutMode
    let columnCount: Int
    let contentState: BookshelfContentState
    let searchDrawerHeight: CGFloat
    let searchPresentation: BookshelfSearchDrawerPresentation
    let isSearchPresented: Bool
    let isSearchFocused: Bool
    let searchText: String
    let searchKeyword: String
    let searchPlaceholder: String
    let searchFocusTrigger: Int
    let canReorder: Bool
    let onActivateSearch: () -> Void
    let onRequestSearchFocus: () -> Void
    let onSearchKeywordChange: (String) -> Void
    let onSubmitSearch: (String) -> Void
    let onClearSearch: () -> Void
    let onCancelSearch: () -> Void
    let onSearchFocusChange: (Bool) -> Void
    let onOpenRoute: (BookRoute) -> Void
    let onContextAction: (BookshelfAggregateContextAction, BookshelfAggregateGroup) -> Void
    let onCommitOrder: ([Int64]) -> Void

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

    static let empty = BookshelfAggregateCollectionConfiguration(
        sections: [],
        layoutMode: .grid,
        columnCount: 2,
        contentState: .empty,
        searchDrawerHeight: 0,
        searchPresentation: .hidden,
        isSearchPresented: false,
        isSearchFocused: false,
        searchText: "",
        searchKeyword: "",
        searchPlaceholder: "",
        searchFocusTrigger: 0,
        canReorder: false,
        onActivateSearch: {},
        onRequestSearchFocus: {},
        onSearchKeywordChange: { _ in },
        onSubmitSearch: { _ in },
        onClearSearch: {},
        onCancelSearch: {},
        onSearchFocusChange: { _ in },
        onOpenRoute: { _ in },
        onContextAction: { _, _ in },
        onCommitOrder: { _ in }
    )
}

/// 聚合集合内部的确定性尺寸，避免搜索空结果切换时依赖自动测量。
private enum BookshelfAggregateCollectionMetrics {
    static let searchEmptyHeight: CGFloat = 320
}

/// UICollectionView 承载视图，负责聚合卡片布局和本地排序预览。
final class BookshelfAggregateCollectionHostView: UIView {
    private var configuration = BookshelfAggregateCollectionConfiguration.empty
    private var sections: [BookshelfAggregateCollectionSection] = []
    private var didChangeOrderInCurrentSession = false
    private var didApplyInitialSearchDrawerOffset = false
    private var isPendingInitialSearchDrawerOffset = false
    private var isAdjustingSearchDrawerOffset = false
    private var searchDrawerExtraBottomInset: CGFloat = 0
    private var keyboardAvoidanceInset: CGFloat = 0
    private var searchDrawerLockedOffsetY: CGFloat?
    private var pendingAnimatedInsertionGroupIDs: Set<String> = []
    private var isContentToEmptyTransitionPending = false
    private var contentToEmptyTransitionGeneration = 0
    private var pendingContentToEmptyConfiguration: BookshelfAggregateCollectionConfiguration?
    private let searchFocusRequestCoordinator = BookshelfSearchFocusRequestCoordinator()
    private var lastCollectionBounds: CGRect = .zero
    private let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let selectionFeedback = UISelectionFeedbackGenerator()
    private lazy var keyboardAvoidanceCoordinator = BookshelfCollectionKeyboardAvoidanceCoordinator(
        hostView: self,
        scrollView: collectionView
    ) { [weak self] inset, animation in
        self?.applyKeyboardAvoidanceInset(inset, animation: animation)
    }

    private lazy var collectionView: UICollectionView = {
        let view = UICollectionView(frame: .zero, collectionViewLayout: makeLayout(for: configuration))
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
            BookshelfAggregateCollectionCell.self,
            forCellWithReuseIdentifier: BookshelfAggregateCollectionCell.reuseIdentifier
        )
        view.register(
            BookshelfAggregateSearchCell.self,
            forCellWithReuseIdentifier: BookshelfAggregateSearchCell.reuseIdentifier
        )
        view.register(
            BookshelfAggregateSearchEmptyCell.self,
            forCellWithReuseIdentifier: BookshelfAggregateSearchEmptyCell.reuseIdentifier
        )
        view.register(
            BookshelfAggregateHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: BookshelfAggregateHeaderView.reuseIdentifier
        )
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
        searchFocusRequestCoordinator.cancel()
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

    /// 同步聚合列表配置。
    fileprivate func update(with configuration: BookshelfAggregateCollectionConfiguration, animated: Bool) {
        if isContentToEmptyTransitionPending {
            if configuration.showsSearchEmptyState {
                pendingContentToEmptyConfiguration = configuration
                return
            }
            cancelPendingContentToEmptyTransition()
        }

        let previousConfiguration = self.configuration
        let previousSections = sections
        let nextSections = configuration.sections
        let didChangeSearchDrawerVisibility = previousConfiguration.showsSearchDrawerInCollection != configuration.showsSearchDrawerInCollection
        let didChangeSearchEmptyState = previousConfiguration.showsSearchEmptyState != configuration.showsSearchEmptyState
        let didChangeSearchSurfaceContent = previousConfiguration.searchText != configuration.searchText
            || previousConfiguration.searchKeyword != configuration.searchKeyword
            || previousConfiguration.isSearchPresented != configuration.isSearchPresented
            || previousConfiguration.isSearchFocused != configuration.isSearchFocused
            || previousConfiguration.searchPresentation != configuration.searchPresentation
            || previousConfiguration.searchFocusTrigger != configuration.searchFocusTrigger
        let needsLayoutUpdate = previousConfiguration.layoutMode != configuration.layoutMode
            || previousConfiguration.columnCount != configuration.columnCount
            || previousConfiguration.sections.map(\.id) != configuration.sections.map(\.id)
            || didChangeSearchDrawerVisibility
            || didChangeSearchEmptyState
            || abs(previousConfiguration.searchDrawerHeight - configuration.searchDrawerHeight) > 0.5
        let shouldAnimateContentToEmpty = shouldAnimateSearchContentToEmptyTransition(
            from: previousConfiguration,
            to: configuration,
            previousSections: previousSections,
            animated: animated
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
        collectionView.dragInteractionEnabled = configuration.canReorder
        updateCollectionVisibilityForSearchDrawerPreparation()
        normalizeSearchDrawerExtraBottomInsetForCurrentState()
        updateBottomContentInset()

        if needsLayoutUpdate {
            collectionView.setCollectionViewLayout(makeLayout(for: configuration), animated: animated)
        }
        if didChangeSearchDrawerVisibility || didChangeSearchEmptyState {
            let insertedGroupIDs = shouldAnimateSearchEmptyToContentTransition(
                from: previousConfiguration,
                to: configuration,
                nextSections: nextSections,
                animated: animated
            ) ? Set(nextSections.flatMap(\.groups).map(\.id)) : []
            pendingAnimatedInsertionGroupIDs.formUnion(insertedGroupIDs)
            sections = nextSections
            UIView.performWithoutAnimation {
                collectionView.reloadData()
                collectionView.layoutIfNeeded()
            }
            animateVisiblePendingInsertions()
            animateVisibleSearchEmptyIfNeeded(
                shouldAnimate: animated
                    && !UIAccessibility.isReduceMotionEnabled
                    && configuration.showsSearchEmptyState
                    && previousConfiguration.showsSearchEmptyState == false
            )
        } else if previousSections != nextSections {
            if !needsLayoutUpdate,
               applyAnimatedGroupUpdate(
                from: previousSections,
                to: nextSections,
                animated: animated
               ) {
                if didChangeSearchSurfaceContent {
                    refreshVisibleSearchCells()
                }
                syncSearchDrawerOffsetAfterUpdate(previousConfiguration: previousConfiguration, animated: animated)
                return
            }
            sections = nextSections
            reloadCollectionWithCrossfadeIfNeeded(animated: animated && configuration.showsExpandedSearchSurface)
        } else if didChangeSearchSurfaceContent {
            refreshVisibleSearchCells()
            refreshVisibleGroupCells()
        }
        syncSearchDrawerOffsetAfterUpdate(previousConfiguration: previousConfiguration, animated: animated)
    }
}

private extension BookshelfAggregateCollectionHostView {
    /// 搭建集合视图层级。
    func setupViewHierarchy() {
        addSubview(collectionView)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.accessibilityIdentifier = "bookshelf.aggregate.collection"

        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    /// 聚合 collection 尺寸变化时重算布局与搜索隐藏位，避免键盘收起后沿用旧视口边界。
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
        collectionView.collectionViewLayout.invalidateLayout()
        updateBottomContentInset()
        applyPendingInitialSearchDrawerOffsetIfNeeded()
    }

    /// 接收统一键盘协调器给出的自定义避让高度，并复用聚合 collection 的底部 inset 管线。
    func applyKeyboardAvoidanceInset(
        _ inset: CGFloat,
        animation: BookshelfCollectionKeyboardAvoidanceCoordinator.AnimationContext
    ) {
        guard abs(keyboardAvoidanceInset - inset) > 0.5 else { return }
        keyboardAvoidanceInset = inset
        updateBottomContentInset(animated: animation)
    }

    /// 初始隐藏搜索抽屉时先等滚动位置收敛，避免首帧露出半收起胶囊。
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

    /// 判断指定 section 是否承载搜索 drawer。
    func isSearchSection(_ section: Int) -> Bool {
        configuration.showsSearchDrawerInCollection && section == 0
    }

    /// 判断指定 section 是否承载搜索空结果。
    func isSearchEmptySection(_ section: Int) -> Bool {
        configuration.showsSearchEmptyState && section == searchSectionOffset
    }

    /// 将集合 section 映射为真实聚合 section，搜索 section 不参与业务数据。
    func realSectionIndex(for collectionSection: Int) -> Int? {
        guard !isSearchSection(collectionSection),
              !isSearchEmptySection(collectionSection) else {
            return nil
        }
        let realSection = collectionSection - searchSectionOffset - searchEmptySectionOffset
        guard sections.indices.contains(realSection) else { return nil }
        return realSection
    }

    /// 将集合 indexPath 映射为真实聚合 indexPath。
    func realIndexPath(for collectionIndexPath: IndexPath) -> IndexPath? {
        guard let section = realSectionIndex(for: collectionIndexPath.section),
              sections[section].groups.indices.contains(collectionIndexPath.item) else {
            return nil
        }
        return IndexPath(item: collectionIndexPath.item, section: section)
    }

    /// 将真实聚合 indexPath 转回带搜索 section 偏移的集合 indexPath。
    func collectionIndexPath(for realIndexPath: IndexPath) -> IndexPath {
        IndexPath(item: realIndexPath.item, section: realIndexPath.section + searchSectionOffset + searchEmptySectionOffset)
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

    /// 聚合维度没有额外底部工具栏；底部 inset 只合成搜索隐藏位与键盘避让。
    func updateBottomContentInset(
        animated animation: BookshelfCollectionKeyboardAvoidanceCoordinator.AnimationContext = .immediate
    ) {
        let bottomInset = max(0, searchDrawerExtraBottomInset, keyboardAvoidanceInset)
        let didChangeInset = collectionView.contentInset.bottom != bottomInset
            || collectionView.verticalScrollIndicatorInsets.bottom != bottomInset
        guard didChangeInset else { return }
        var contentInset = collectionView.contentInset
        contentInset.bottom = bottomInset

        var indicatorInsets = collectionView.verticalScrollIndicatorInsets
        indicatorInsets.bottom = bottomInset

        if shouldPreserveTopPinnedSearchDuringInsetChange {
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
            collectionView.contentInset = contentInset
            collectionView.verticalScrollIndicatorInsets = indicatorInsets
            collectionView.layoutIfNeeded()
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

    /// 搜索输入态只锁定 drawer 自身 offset，键盘 inset 不再牵引聚合卡片锚点。
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

    /// 在键盘或安全区重算期间锁住当前搜索抽屉 offset，避免输入框出现二次校正。
    func performSearchDrawerOffsetLocked(_ updates: () -> Void) {
        let lockedOffsetY = searchDrawerLockedOffsetY ?? collectionView.contentOffset.y
        searchDrawerLockedOffsetY = lockedOffsetY
        updates()
        UIView.performWithoutAnimation {
            restorePinnedSearchDrawerOffsetIfNeeded(lockedOffsetY: lockedOffsetY)
            collectionView.layoutIfNeeded()
        }
    }

    /// 搜索抽屉刚进入 collection 或退出输入态时，同步 collection 偏移。
    func syncSearchDrawerOffsetAfterUpdate(
        previousConfiguration: BookshelfAggregateCollectionConfiguration,
        animated: Bool
    ) {
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

    /// 搜索抽屉的隐藏位等于抽屉高度。
    func hiddenSearchDrawerOffsetY() -> CGFloat {
        max(0, configuration.searchDrawerHeight)
    }

    /// 短列表也必须能把搜索抽屉藏到顶部外侧；这里只扩展滚动范围。
    func ensureSearchDrawerHiddenScrollRange() {
        guard configuration.showsSearchDrawerInCollection,
              !configuration.showsExpandedSearchSurface,
              collectionView.bounds.height > 0 else {
            return
        }
        let hiddenOffsetY = hiddenSearchDrawerOffsetY()
        guard hiddenOffsetY > 0 else { return }

        let overlayInset = max(0, keyboardAvoidanceInset)
        let requiredSearchInset = requiredSearchDrawerBottomInset(for: hiddenOffsetY)
        let nextExtraInset = requiredSearchInset > overlayInset + 0.5 ? requiredSearchInset : 0
        guard abs(nextExtraInset - searchDrawerExtraBottomInset) > 0.5 else { return }
        searchDrawerExtraBottomInset = nextExtraInset
        updateBottomContentInset()
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

    /// 使用 adjustedContentInset 计算合法滚动边界。
    func clampedContentOffsetY(_ offsetY: CGFloat) -> CGFloat {
        let adjustedInset = collectionView.adjustedContentInset
        let minimumY = -adjustedInset.top
        let maximumY = max(
            minimumY,
            collectionView.contentSize.height - collectionView.bounds.height + adjustedInset.bottom
        )
        return min(max(offsetY, minimumY), maximumY)
    }

    /// 将 collection 滚动到搜索 surface 完整可见的位置。
    func setSearchDrawerVisible(animated: Bool, completion: (() -> Void)? = nil) {
        guard configuration.showsSearchDrawerInCollection else {
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
        animateSearchDrawerOffset(to: targetOffset, animated: animated, completion: completion)
    }

    /// 将普通态搜索抽屉收回到聚合列表后方，保持 section 结构稳定。
    func setSearchDrawerHidden(animated: Bool) {
        guard configuration.showsSearchDrawerInCollection else { return }
        ensureSearchDrawerHiddenScrollRange()
        let targetOffset = CGPoint(
            x: collectionView.contentOffset.x,
            y: clampedContentOffsetY(hiddenSearchDrawerOffsetY())
        )
        guard abs(collectionView.contentOffset.y - targetOffset.y) > 0.5 else { return }

        isAdjustingSearchDrawerOffset = true
        animateSearchDrawerOffset(to: targetOffset, animated: animated)
    }

    /// 用页面统一节奏移动搜索抽屉，避免 UIScrollView 默认动画和 SwiftUI 状态动画脱节。
    func animateSearchDrawerOffset(to targetOffset: CGPoint, animated: Bool, completion: (() -> Void)? = nil) {
        guard animated, !UIAccessibility.isReduceMotionEnabled else {
            UIView.performWithoutAnimation {
                collectionView.setContentOffset(targetOffset, animated: false)
            }
            isAdjustingSearchDrawerOffset = false
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
            completion?()
        }
    }

    /// 搜索输入态以 drawer 自身作为锚点，保证键盘 inset 改变时搜索框不被内容区牵引。
    func restorePinnedSearchDrawerOffsetIfNeeded(lockedOffsetY: CGFloat? = nil) {
        let targetOffset = CGPoint(
            x: collectionView.contentOffset.x,
            y: clampedContentOffsetY(lockedOffsetY ?? searchDrawerLockedOffsetY ?? 0)
        )
        guard abs(collectionView.contentOffset.y - targetOffset.y) > 0.5 else { return }
        collectionView.setContentOffset(targetOffset, animated: false)
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
            && !isAdjustingSearchDrawerOffset
    }

    /// pinned 搜索为空且失焦后，用户继续向上浏览时自动回到隐藏抽屉状态。
    func collapsePinnedSearchIfNeeded(_ scrollView: UIScrollView) {
        guard configuration.searchPresentation.isPinned,
              !configuration.isSearchFocused,
              !configuration.hasSearchText,
              !configuration.hasSearchKeyword,
              configuration.showsSearchDrawerInCollection,
              scrollView.contentOffset.y > hiddenSearchDrawerOffsetY() * 0.6 else {
            return
        }
        configuration.onCancelSearch()
    }

    /// 只刷新可见搜索 cell，避免输入关键词时重建整组聚合卡。
    func refreshVisibleSearchCells() {
        for cell in collectionView.visibleCells {
            guard let indexPath = collectionView.indexPath(for: cell),
                  isSearchSection(indexPath.section),
                  let searchCell = cell as? BookshelfAggregateSearchCell else {
                continue
            }
            searchCell.configure(with: configuration)
        }
    }

    /// 只刷新可见聚合卡内容，保留当前滚动和批量更新产生的 cell 身份。
    func refreshVisibleGroupCells() {
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let cell = collectionView.cellForItem(at: indexPath) as? BookshelfAggregateCollectionCell,
                  let group = group(at: indexPath) else {
                continue
            }
            cell.configure(
                group: group,
                layoutMode: configuration.layoutMode,
                searchKeyword: configuration.searchKeyword,
                onContextAction: configuration.onContextAction
            )
        }
    }

    /// 判断搜索结果从内容进入空态时是否需要先播放短退场。
    func shouldAnimateSearchContentToEmptyTransition(
        from previousConfiguration: BookshelfAggregateCollectionConfiguration,
        to nextConfiguration: BookshelfAggregateCollectionConfiguration,
        previousSections: [BookshelfAggregateCollectionSection],
        animated: Bool
    ) -> Bool {
        animated
            && collectionView.window != nil
            && !UIAccessibility.isReduceMotionEnabled
            && previousConfiguration.showsSearchDrawerInCollection
            && nextConfiguration.showsSearchDrawerInCollection
            && !previousConfiguration.showsSearchEmptyState
            && nextConfiguration.showsSearchEmptyState
            && !previousSections.flatMap(\.groups).isEmpty
    }

    /// 判断搜索空态恢复为内容时是否需要给首屏聚合卡补进场。
    func shouldAnimateSearchEmptyToContentTransition(
        from previousConfiguration: BookshelfAggregateCollectionConfiguration,
        to nextConfiguration: BookshelfAggregateCollectionConfiguration,
        nextSections: [BookshelfAggregateCollectionSection],
        animated: Bool
    ) -> Bool {
        animated
            && collectionView.window != nil
            && !UIAccessibility.isReduceMotionEnabled
            && previousConfiguration.showsSearchEmptyState
            && !nextConfiguration.showsSearchEmptyState
            && !nextSections.flatMap(\.groups).isEmpty
    }

    /// 取消尚未提交的内容退场动画，避免快速清空搜索时旧 completion 覆盖新聚合列表。
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

    /// 搜索结果从内容变为空态时，先让可见聚合卡短退场，再提交空态刷新。
    func applySearchContentToEmptyTransition(
        nextConfiguration: BookshelfAggregateCollectionConfiguration,
        previousConfiguration: BookshelfAggregateCollectionConfiguration
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

        let visibleCells = visibleAggregateContentCells()
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

    /// 将搜索空态 section 切换集中提交，避免退场动画期间提前改变 collection 数据源结构。
    func commitSearchStateReplacement(
        with nextConfiguration: BookshelfAggregateCollectionConfiguration,
        previousConfiguration: BookshelfAggregateCollectionConfiguration,
        animateSearchEmptyEntrance: Bool
    ) {
        self.configuration = nextConfiguration
        searchFocusRequestCoordinator.reconcile(
            isFocused: nextConfiguration.isSearchFocused,
            isExpanded: nextConfiguration.showsExpandedSearchSurface
        )
        sections = nextConfiguration.sections
        collectionView.dragInteractionEnabled = nextConfiguration.canReorder
        updateCollectionVisibilityForSearchDrawerPreparation()
        normalizeSearchDrawerExtraBottomInsetForCurrentState()
        updateBottomContentInset()
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

    /// 返回当前可见的真实聚合卡 cell，排除搜索 drawer 与搜索空态。
    func visibleAggregateContentCells() -> [UICollectionViewCell] {
        collectionView.indexPathsForVisibleItems.compactMap { indexPath in
            guard let cell = collectionView.cellForItem(at: indexPath) else {
                return nil
            }
            guard !isSearchSection(indexPath.section),
                  !isSearchEmptySection(indexPath.section),
                  cell is BookshelfAggregateCollectionCell else {
                return nil
            }
            return cell
        }
    }

    /// 对已经进入可视区的搜索结果新聚合卡补充统一进场动画。
    func animateVisiblePendingInsertions() {
        guard !pendingAnimatedInsertionGroupIDs.isEmpty else { return }
        let pendingIDs = pendingAnimatedInsertionGroupIDs
        defer { pendingAnimatedInsertionGroupIDs.subtract(pendingIDs) }
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        for indexPath in collectionView.indexPathsForVisibleItems {
            guard let group = group(at: indexPath),
                  pendingIDs.contains(group.id),
                  let cell = collectionView.cellForItem(at: indexPath) as? BookshelfAggregateCollectionCell else {
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

    /// 在 section 身份稳定时按 group id 执行插入、删除和移动动画。
    func applyAnimatedGroupUpdate(
        from previousSections: [BookshelfAggregateCollectionSection],
        to nextSections: [BookshelfAggregateCollectionSection],
        animated: Bool
    ) -> Bool {
        guard animated,
              collectionView.window != nil,
              !UIAccessibility.isReduceMotionEnabled,
              previousSections.map(\.id) == nextSections.map(\.id),
              hasUniqueGroupIDs(in: previousSections),
              hasUniqueGroupIDs(in: nextSections) else {
            return false
        }

        var deletions: [IndexPath] = []
        var insertions: [IndexPath] = []
        var moves: [(from: IndexPath, to: IndexPath)] = []
        var insertedGroupIDs: Set<String> = []

        for sectionIndex in previousSections.indices {
            let previousIDs = previousSections[sectionIndex].groups.map(\.id)
            let nextIDs = nextSections[sectionIndex].groups.map(\.id)
            let diff = nextIDs.difference(from: previousIDs).inferringMoves()
            for change in diff {
                switch change {
                case let .remove(offset, _, associatedWith):
                    if let destination = associatedWith {
                        moves.append((
                            from: collectionIndexPath(for: IndexPath(item: offset, section: sectionIndex)),
                            to: collectionIndexPath(for: IndexPath(item: destination, section: sectionIndex))
                        ))
                    } else {
                        deletions.append(collectionIndexPath(for: IndexPath(item: offset, section: sectionIndex)))
                    }
                case let .insert(offset, id, associatedWith):
                    if associatedWith == nil {
                        insertions.append(collectionIndexPath(for: IndexPath(item: offset, section: sectionIndex)))
                        insertedGroupIDs.insert(id)
                    }
                }
            }
        }

        guard !deletions.isEmpty || !insertions.isEmpty || !moves.isEmpty else {
            sections = nextSections
            refreshVisibleGroupCells()
            return true
        }

        pendingAnimatedInsertionGroupIDs.formUnion(insertedGroupIDs)
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
            self?.pendingAnimatedInsertionGroupIDs.subtract(insertedGroupIDs)
            self?.refreshVisibleGroupCells()
        }
        return true
    }

    /// 检查 group 身份是否唯一，避免 UICollectionView diff 在重复 ID 下执行错误移动。
    func hasUniqueGroupIDs(in sections: [BookshelfAggregateCollectionSection]) -> Bool {
        let ids = sections.flatMap(\.groups).map(\.id)
        return Set(ids).count == ids.count
    }

    /// 复杂聚合结构变化使用短 crossfade 兜底，避免搜索时整屏硬切。
    func reloadCollectionWithCrossfadeIfNeeded(animated: Bool) {
        let updates = {
            self.collectionView.reloadData()
            self.collectionView.layoutIfNeeded()
        }
        guard animated,
              collectionView.window != nil,
              !UIAccessibility.isReduceMotionEnabled else {
            UIView.performWithoutAnimation(updates)
            return
        }
        UIView.transition(
            with: collectionView,
            duration: BookshelfManagementMotion.bookListResultTransitionDuration,
            options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState],
            animations: updates
        )
    }

    /// 根据 Grid/List 模式构建布局。
    func makeLayout(for configuration: BookshelfAggregateCollectionConfiguration) -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { sectionIndex, _ in
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
            let isGrid = configuration.layoutMode == .grid
            let columns = isGrid ? max(2, configuration.columnCount) : 1
            let estimatedItemHeight: CGFloat = isGrid ? 176 : 138
            let itemSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1.0 / CGFloat(columns)),
                heightDimension: .estimated(estimatedItemHeight)
            )
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            if isGrid {
                item.contentInsets = NSDirectionalEdgeInsets(
                    top: 0,
                    leading: Spacing.base / 2,
                    bottom: 0,
                    trailing: Spacing.base / 2
                )
            }

            let groupSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(estimatedItemHeight)
            )
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: groupSize,
                repeatingSubitem: item,
                count: columns
            )
            group.interItemSpacing = .fixed(isGrid ? 0 : Spacing.base)

            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = isGrid ? Spacing.section : Spacing.base
            let horizontalInset = isGrid ? max(0, Spacing.screenEdge - Spacing.base / 2) : Spacing.screenEdge
            section.contentInsets = NSDirectionalEdgeInsets(
                top: Spacing.base,
                leading: horizontalInset,
                bottom: Spacing.base,
                trailing: horizontalInset
            )

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

    /// 构建搜索空结果 section，让聚合维度空态留在 collection 内容区。
    static func makeSearchEmptySection() -> NSCollectionLayoutSection {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .absolute(BookshelfAggregateCollectionMetrics.searchEmptyHeight)
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: .absolute(BookshelfAggregateCollectionMetrics.searchEmptyHeight)
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

    /// 构建聚合维度集合顶部的统一搜索 drawer section。
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

    func group(at indexPath: IndexPath) -> BookshelfAggregateGroup? {
        guard let realIndexPath = realIndexPath(for: indexPath),
              sections[realIndexPath.section].groups.indices.contains(realIndexPath.item) else {
            return nil
        }
        return sections[realIndexPath.section].groups[realIndexPath.item]
    }

    func canMoveItem(at indexPath: IndexPath) -> Bool {
        configuration.canReorder && group(at: indexPath)?.orderID != nil
    }

    func reorder(from source: IndexPath, to proposedDestination: IndexPath) -> IndexPath? {
        guard let realSource = realIndexPath(for: source),
              let realProposed = realIndexPath(for: proposedDestination),
              realSource.section == realProposed.section,
              sections.indices.contains(realSource.section),
              canMoveItem(at: source) else {
            return nil
        }
        var groups = sections[realSource.section].groups
        guard groups.indices.contains(realSource.item) else { return nil }

        let firstMovableIndex = groups.firstIndex { $0.orderID != nil } ?? 0
        let destinationItem = max(firstMovableIndex, min(realProposed.item, groups.count - 1))
        let destination = IndexPath(item: destinationItem, section: realSource.section)
        guard destinationItem != realSource.item else {
            return collectionIndexPath(for: destination)
        }

        let moved = groups.remove(at: realSource.item)
        groups.insert(moved, at: destinationItem)
        sections[realSource.section] = BookshelfAggregateCollectionSection(
            id: sections[realSource.section].id,
            title: sections[realSource.section].title,
            groups: groups
        )
        didChangeOrderInCurrentSession = true
        selectionFeedback.selectionChanged()
        return collectionIndexPath(for: destination)
    }

    func finishReorderIfNeeded() {
        guard didChangeOrderInCurrentSession else { return }
        didChangeOrderInCurrentSession = false
        let orderedIDs = sections.flatMap(\.groups).compactMap(\.orderID)
        configuration.onCommitOrder(orderedIDs)
    }
}

extension BookshelfAggregateCollectionHostView: UICollectionViewDataSource {
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        sections.count + searchSectionOffset + searchEmptySectionOffset
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        if isSearchSection(section) {
            return 1
        }
        if isSearchEmptySection(section) {
            return 1
        }
        guard let realSection = realSectionIndex(for: section) else { return 0 }
        return sections[realSection].groups.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        if isSearchSection(indexPath.section) {
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: BookshelfAggregateSearchCell.reuseIdentifier,
                for: indexPath
            ) as? BookshelfAggregateSearchCell else {
                return UICollectionViewCell()
            }
            cell.configure(with: configuration)
            return cell
        }
        if isSearchEmptySection(indexPath.section) {
            guard let cell = collectionView.dequeueReusableCell(
                withReuseIdentifier: BookshelfAggregateSearchEmptyCell.reuseIdentifier,
                for: indexPath
            ) as? BookshelfAggregateSearchEmptyCell else {
                return UICollectionViewCell()
            }
            cell.configure()
            return cell
        }
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: BookshelfAggregateCollectionCell.reuseIdentifier,
            for: indexPath
        ) as? BookshelfAggregateCollectionCell,
              let group = group(at: indexPath) else {
            return UICollectionViewCell()
        }
        cell.configure(
            group: group,
            layoutMode: configuration.layoutMode,
            searchKeyword: configuration.searchKeyword,
            onContextAction: configuration.onContextAction
        )
        return cell
    }

    func collectionView(
        _ collectionView: UICollectionView,
        viewForSupplementaryElementOfKind kind: String,
        at indexPath: IndexPath
    ) -> UICollectionReusableView {
        guard kind == UICollectionView.elementKindSectionHeader,
              let header = collectionView.dequeueReusableSupplementaryView(
                ofKind: kind,
                withReuseIdentifier: BookshelfAggregateHeaderView.reuseIdentifier,
                for: indexPath
              ) as? BookshelfAggregateHeaderView,
              let realSection = realSectionIndex(for: indexPath.section),
              let title = sections[realSection].title else {
            return UICollectionReusableView()
        }
        header.configure(title: title)
        return header
    }

    func collectionView(_ collectionView: UICollectionView, canMoveItemAt indexPath: IndexPath) -> Bool {
        canMoveItem(at: indexPath)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        moveItemAt sourceIndexPath: IndexPath,
        to destinationIndexPath: IndexPath
    ) {
        _ = reorder(from: sourceIndexPath, to: destinationIndexPath)
    }
}

extension BookshelfAggregateCollectionHostView: UICollectionViewDelegate {
    /// 批量更新插入的搜索结果聚合卡在进入首屏时补一段轻量进场。
    func collectionView(_ collectionView: UICollectionView, willDisplay cell: UICollectionViewCell, forItemAt indexPath: IndexPath) {
        guard let group = group(at: indexPath),
              pendingAnimatedInsertionGroupIDs.contains(group.id) else {
            return
        }
        pendingAnimatedInsertionGroupIDs.remove(group.id)
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        applyResultEntranceAnimation(to: cell)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if shouldPreserveTopPinnedSearchDuringInsetChange {
            searchDrawerLockedOffsetY = scrollView.contentOffset.y
        }
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
        guard let group = group(at: indexPath) else { return }
        configuration.onOpenRoute(.bookshelfList(BookshelfBookListRoute(
            context: group.context,
            title: group.title,
            subtitleHint: group.subtitle
        )))
    }

    func collectionView(
        _ collectionView: UICollectionView,
        targetIndexPathForMoveFromItemAt originalIndexPath: IndexPath,
        toProposedIndexPath proposedIndexPath: IndexPath
    ) -> IndexPath {
        guard let realOriginal = realIndexPath(for: originalIndexPath),
              let realProposed = realIndexPath(for: proposedIndexPath),
              realOriginal.section == realProposed.section,
              sections.indices.contains(realOriginal.section) else {
            return originalIndexPath
        }
        let groups = sections[realOriginal.section].groups
        let firstMovableIndex = groups.firstIndex { $0.orderID != nil } ?? 0
        let clampedItem = max(firstMovableIndex, min(realProposed.item, groups.count - 1))
        return collectionIndexPath(for: IndexPath(item: clampedItem, section: realOriginal.section))
    }
}

extension BookshelfAggregateCollectionHostView: UICollectionViewDragDelegate {
    func collectionView(
        _ collectionView: UICollectionView,
        itemsForBeginning session: UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        guard canMoveItem(at: indexPath),
              let orderID = group(at: indexPath)?.orderID else {
            return []
        }
        impactFeedback.prepare()
        impactFeedback.impactOccurred()
        let provider = NSItemProvider(object: NSString(string: "\(orderID)"))
        let item = UIDragItem(itemProvider: provider)
        item.localObject = orderID
        return [item]
    }

    func collectionView(_ collectionView: UICollectionView, dragSessionDidEnd session: UIDragSession) {
        finishReorderIfNeeded()
    }
}

extension BookshelfAggregateCollectionHostView: UICollectionViewDropDelegate {
    func collectionView(_ collectionView: UICollectionView, canHandle session: UIDropSession) -> Bool {
        configuration.canReorder && session.localDragSession != nil
    }

    func collectionView(
        _ collectionView: UICollectionView,
        dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UICollectionViewDropProposal {
        guard configuration.canReorder else {
            return UICollectionViewDropProposal(operation: .forbidden)
        }
        return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        guard let source = coordinator.items.first?.sourceIndexPath else { return }
        let fallbackDestination = IndexPath(
            item: max(0, collectionView.numberOfItems(inSection: source.section) - 1),
            section: source.section
        )
        let proposedDestination = coordinator.destinationIndexPath ?? fallbackDestination
        guard let destination = reorder(from: source, to: proposedDestination) else { return }
        collectionView.performBatchUpdates {
            collectionView.moveItem(at: source, to: destination)
        }
        if let dragItem = coordinator.items.first?.dragItem {
            coordinator.drop(dragItem, toItemAt: destination)
        }
    }
}

/// 聚合维度集合顶部搜索 cell，复用统一 search surface 承载维度内筛选。
private final class BookshelfAggregateSearchCell: UICollectionViewCell {
    static let reuseIdentifier = "BookshelfAggregateSearchCell"
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

    /// 使用聚合维度搜索配置刷新共享 surface。
    func configure(with configuration: BookshelfAggregateCollectionConfiguration) {
        searchSurface.configure(with: BookshelfSearchSurfaceConfiguration(
            namespace: "bookshelf.aggregate.search",
            placeholder: configuration.searchPlaceholder,
            keyword: configuration.searchText,
            showsInput: configuration.showsExpandedSearchSurface,
            showsClearAction: configuration.hasSearchText || configuration.hasSearchKeyword,
            usesAccessibilityLayout: configuration.searchDrawerHeight > 56,
            focusTrigger: configuration.searchFocusTrigger,
            accessibilityLabel: "搜索当前维度",
            onActivate: configuration.onActivateSearch,
            onTextChange: configuration.onSearchKeywordChange,
            onSubmit: configuration.onSubmitSearch,
            onClear: configuration.onClearSearch,
            onCancel: configuration.onCancelSearch,
            onFocusChange: configuration.onSearchFocusChange
        ))
    }

    /// 将搜索 surface 固定在聚合集合顶部，左右边距对齐内容列。
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

/// 聚合维度搜索无结果 cell，保持搜索 drawer 与内容空态处在同一个 collection。
private final class BookshelfAggregateSearchEmptyCell: UICollectionViewCell {
    static let reuseIdentifier = "BookshelfAggregateSearchEmptyCell"

    override func prepareForReuse() {
        super.prepareForReuse()
        contentConfiguration = nil
        layer.removeAllAnimations()
        alpha = 1
        transform = .identity
    }

    /// 刷新聚合维度搜索空态文案。
    func configure() {
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        contentConfiguration = UIHostingConfiguration {
            BookshelfContextualEmptyStateView(
                icon: "square.grid.2x2",
                title: "没有匹配的项",
                message: "清除搜索后查看全部内容",
                iconColor: Color.brand.opacity(0.30)
            )
            .frame(minHeight: BookshelfAggregateCollectionMetrics.searchEmptyHeight)
        }
        .margins(.all, 0)
    }
}

/// 聚合入口 cell，按 Grid/List 模式选择封面卡或信息优先的列表行。
private final class BookshelfAggregateCollectionCell: UICollectionViewCell {
    static let reuseIdentifier = "BookshelfAggregateCollectionCell"

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
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

    /// 渲染聚合卡片，并为作者/出版社维度补齐 Android 对齐的长按菜单。
    func configure(
        group: BookshelfAggregateGroup,
        layoutMode: BookshelfLayoutMode,
        searchKeyword: String,
        onContextAction: @escaping (BookshelfAggregateContextAction, BookshelfAggregateGroup) -> Void
    ) {
        contentConfiguration = UIHostingConfiguration {
            BookshelfAggregateCollectionCellContent(
                group: group,
                layoutMode: layoutMode,
                searchKeyword: searchKeyword,
                onContextAction: onContextAction
            )
        }
        .margins(.all, 0)
    }
}

/// 聚合入口 cell 的 SwiftUI 内容，避免列表模式继续复用网格拼贴卡。
private struct BookshelfAggregateCollectionCellContent: View {
    let group: BookshelfAggregateGroup
    let layoutMode: BookshelfLayoutMode
    let searchKeyword: String
    let onContextAction: (BookshelfAggregateContextAction, BookshelfAggregateGroup) -> Void

    var body: some View {
        if group.context.supportsContributorContextMenu {
            content
                .contextMenu {
                    Button {
                        onContextAction(.edit, group)
                    } label: {
                        XMMenuLabel("编辑", systemImage: "pencil")
                    }

                    Button(role: .destructive) {
                        onContextAction(.delete, group)
                    } label: {
                        Label("删除", systemImage: "trash")
                    }
                }
                .xmMenuNeutralTint()
        } else {
            content
        }
    }

    @ViewBuilder
    private var content: some View {
        switch layoutMode {
        case .grid:
            BookshelfAggregateCardView(
                group: group,
                searchKeyword: searchKeyword
            )
        case .list:
            BookshelfAggregateListRowView(
                group: group,
                searchKeyword: searchKeyword
            )
        }
    }
}

private extension BookshelfListContext {
    var supportsContributorContextMenu: Bool {
        switch self {
        case .author, .press:
            return true
        case .defaultGroup, .readStatus, .tag, .source, .rating:
            return false
        }
    }
}

/// 聚合分区标题。
private final class BookshelfAggregateHeaderView: UICollectionReusableView {
    static let reuseIdentifier = "BookshelfAggregateHeaderView"
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
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = UIFont.preferredFont(forTextStyle: .title3)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.textColor = .label
        addSubview(titleLabel)

        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: Spacing.compact),
            titleLabel.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}
