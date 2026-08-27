/**
 * [INPUT]: 依赖 BookshelfBookListSnapshot、BookshelfBookListCollectionConfiguration 与 UIKit UICollectionView 展示二级书籍列表
 * [OUTPUT]: 对外提供 BookshelfBookListCollectionView，封装二级列表 collection host、布局、拖拽排序与搜索抽屉滚动控制
 * [POS]: Book 模块二级书籍列表页面私有 collection 组件，隔离 UIKit bridge 细节以降低 BookshelfBookListView 页面职责
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 二级书籍列表 UIKit 集合区，负责滚动、空态和行点击命中。
struct BookshelfBookListCollectionView: UIViewRepresentable {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let snapshot: BookshelfBookListSnapshot
    let subtitle: String
    let contentState: BookshelfContentState
    let layoutMode: BookshelfLayoutMode
    let columnCount: Int
    let showsNoteCount: Bool
    let sortCriteria: BookshelfSortCriteria
    let titleDisplayMode: BookshelfTitleDisplayMode
    let isEditing: Bool
    let hasSearchKeyword: Bool
    let searchDrawerHeight: CGFloat
    let searchPresentation: BookshelfSearchDrawerPresentation
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
    let onSelectBook: (Int64) -> Void
    let onContextAction: (BookshelfBookContextAction, Int64) -> Void
    let onCommitOrder: ([Int64]) -> Void

    /// 创建 collection view 承载视图。
    func makeUIView(context: Context) -> BookshelfBookListCollectionHostView {
        let view = BookshelfBookListCollectionHostView()
        view.update(with: configuration, animated: false)
        return view
    }

    /// 同步最新集合配置。
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
            columnCount: BookshelfGridLayoutPolicy.effectiveColumnCount(
                requested: columnCount,
                dynamicTypeSize: dynamicTypeSize
            ),
            dynamicTypeSize: dynamicTypeSize,
            showsNoteCount: showsNoteCount,
            sortCriteria: sortCriteria,
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
            onSelectBook: onSelectBook,
            onContextAction: onContextAction,
            onCommitOrder: onCommitOrder
        )
    }
}

/// UICollectionView 承载视图，负责二级列表 grid/list 布局、行点击与组内排序。
final class BookshelfBookListCollectionHostView: UIView {
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
        let nextSections = BookshelfBookListCollectionSectionBuilder.makeSections(from: configuration)
        let resultTransition = BookshelfBookListCollectionSectionBuilder.resultTransition(
            from: previousSections,
            to: nextSections
        )
        let needsLayoutUpdate = configuration.layoutMode != previousConfiguration.layoutMode
            || configuration.columnCount != previousConfiguration.columnCount
            || configuration.dynamicTypeSize != previousConfiguration.dynamicTypeSize
            || configuration.titleDisplayMode != previousConfiguration.titleDisplayMode
            || configuration.sortCriteria != previousConfiguration.sortCriteria
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
           BookshelfBookListCollectionSectionBuilder.resultState(in: nextSections) == .empty {
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
        emptyPresentationMode = BookshelfBookListCollectionSectionBuilder.emptyPresentationMode(for: resultTransition)
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
        emptyPresentationMode = BookshelfBookListCollectionSectionBuilder.emptyPresentationMode(for: transition)
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
                return BookshelfBookListCollectionLayoutFactory.makeSearchDrawerSection(
                    height: resolvedConfiguration.searchDrawerHeight
                )
            }
            let usesGrid = resolvedConfiguration.layoutMode == .grid
                && (self?.sectionContainsBooks(at: sectionIndex) ?? false)
            let listItemHeight = self?.listItemHeight(at: sectionIndex) ?? BookshelfBookListLayoutMetrics.listRowHeight
            let usesEstimatedHeight = self?.listItemUsesEstimatedHeight(at: sectionIndex) ?? false
            let section = usesGrid
                ? BookshelfBookListCollectionLayoutFactory.makeGridSection(
                    columnCount: resolvedConfiguration.columnCount,
                    containerWidth: environment.container.effectiveContentSize.width,
                    dynamicTypeSize: resolvedConfiguration.dynamicTypeSize,
                    titleDisplayMode: resolvedConfiguration.titleDisplayMode,
                    sortCriteria: resolvedConfiguration.sortCriteria
                )
                : BookshelfBookListCollectionLayoutFactory.makeListSection(
                    itemHeight: listItemHeight,
                    usesEstimatedHeight: usesEstimatedHeight
                )
            if let self,
               self.sections.indices.contains(sectionIndex),
               self.sections[sectionIndex].title != nil {
                section.boundarySupplementaryItems = [
                    BookshelfBookListCollectionLayoutFactory.makeSectionHeader()
                ]
            }
            return section
        }
    }

    /// 根据 section 内容返回基础行高，书籍行会以该值作为自适应估算高度。
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

    /// 书籍列表行需要承载可变标签与排序辅助信息，使用 self-sizing 避免固定高度截断内容。
    func listItemUsesEstimatedHeight(at sectionIndex: Int) -> Bool {
        guard sections.indices.contains(sectionIndex),
              let firstItem = sections[sectionIndex].items.first else {
            return false
        }
        if case .book = firstItem {
            return true
        }
        return false
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
        collectionView.layoutIfNeeded()
        let targetY = clampedContentOffsetY(hiddenOffsetY)
        guard targetY >= hiddenOffsetY - 0.5 else {
            revealCollectionIfInitialSearchHideCannotSettle()
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
        let maximumYWithoutCustomBottomInset = collectionView.contentSize.height
            - collectionView.bounds.height
            + systemAdjustedBottomInset
        let missingRange = hiddenOffsetY - maximumYWithoutCustomBottomInset
        return max(0, ceil(missingRange + 1))
    }

    /// 滚动范围仍无法稳定隐藏搜索抽屉时，优先展示结果区，避免短列表永久停留在透明预备态。
    func revealCollectionIfInitialSearchHideCannotSettle() {
        guard hasDisplayableResultSection else { return }
        isPendingInitialSearchDrawerOffset = false
        didApplyInitialSearchDrawerOffset = true
        updateCollectionVisibilityForSearchDrawerPreparation()
    }

    private var hasDisplayableResultSection: Bool {
        switch BookshelfBookListCollectionSectionBuilder.resultState(in: sections) {
        case .content, .empty, .error:
            return true
        case .loading, .other:
            return false
        }
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
                configuration.onSelectBook(book.id)
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
