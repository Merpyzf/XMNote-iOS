/**
 * [INPUT]: 依赖 TagManagementItem/TagManagementScope、PersonalManagementSearchBar、XMSelectionIndicator/XMKeywordHighlighting、iOS 26 UIScrollEdgeEffect、UIViewController 顶部滚动观察、范围栏实测高度与页面传入的标签状态和操作回调
 * [OUTPUT]: 对外提供 TagManagementCollectionView，封装带可滚动系统搜索头的 UICollectionView、系统顶部自动边缘过渡、动态顶部内边距、底部 Chrome 避让、常规双列/辅助字号单列布局、长按管理、选择态、排序态与滚动边缘状态上报
 * [POS]: Views/Personal/Components 的标签管理页面私有集合组件，被 TagManagementView 用作标签主体内容区
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit
import Combine

/// 标签管理两列集合视图，负责普通态、选择态和排序态的布局与本地拖拽预览。
struct TagManagementCollectionView: UIViewRepresentable {
    let items: [TagManagementItem]
    let scope: TagManagementScope
    let searchText: String
    let isSearchActive: Bool
    let searchPrompt: String
    let isSearchVisible: Bool
    let isSearchEnabled: Bool
    let emptyState: TagManagementCollectionEmptyState
    let searchKeyword: String
    let isSelectionMode: Bool
    let isReordering: Bool
    let selectedTagIDs: Set<Int64>
    let isDisabled: Bool
    let topBarHeight: CGFloat
    let onScrollEdgeWashEdgesChange: (XMScrollEdgeWashEdges) -> Void
    let onSearchTextChange: (String) -> Void
    let onSearchActiveChange: (Bool) -> Void
    let onPrimaryAction: (TagManagementItem) -> Void
    let onRename: (TagManagementItem) -> Void
    let onDelete: (TagManagementItem) -> Void
    let onCommitOrder: ([Int64]) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// 创建 UIKit 承载视图。
    func makeUIView(context: Context) -> TagManagementCollectionHostView {
        let view = TagManagementCollectionHostView()
        view.update(with: configuration, animated: false)
        return view
    }

    /// 同步 SwiftUI 状态到 collection host。
    func updateUIView(_ uiView: TagManagementCollectionHostView, context: Context) {
        uiView.update(with: configuration, animated: true)
    }

    /// 销毁承载视图时清理拖拽快照。
    static func dismantleUIView(_ uiView: TagManagementCollectionHostView, coordinator: ()) {
        uiView.prepareForReuse()
    }

    private var configuration: TagManagementCollectionConfiguration {
        TagManagementCollectionConfiguration(
            items: items,
            scope: scope,
            searchText: searchText,
            isSearchActive: isSearchActive,
            searchPrompt: searchPrompt,
            isSearchVisible: isSearchVisible,
            isSearchEnabled: isSearchEnabled,
            emptyState: emptyState,
            searchKeyword: searchKeyword,
            isSelectionMode: isSelectionMode,
            isReordering: isReordering,
            selectedTagIDs: selectedTagIDs,
            isDisabled: isDisabled,
            reducesMotion: reduceMotion,
            topBarHeight: topBarHeight,
            onScrollEdgeWashEdgesChange: onScrollEdgeWashEdgesChange,
            onSearchTextChange: onSearchTextChange,
            onSearchActiveChange: onSearchActiveChange,
            onPrimaryAction: onPrimaryAction,
            onRename: onRename,
            onDelete: onDelete,
            onCommitOrder: onCommitOrder
        )
    }
}

/// 直接作为页面主滚动视图的 UICollectionView，隔离 UIKit 拖拽排序细节并让系统识别底部浮动 Chrome。
final class TagManagementCollectionHostView: UICollectionView {
    private var configuration = TagManagementCollectionConfiguration.empty
    private var items: [TagManagementItem] = []
    private var pendingConfiguration: TagManagementCollectionConfiguration?
    private var originalItemsBeforeDrag: [TagManagementItem] = []
    private var isInteractiveReordering = false
    private var didChangeOrderInCurrentSession = false
    private var didReceiveDropInCurrentSession = false
    private var lastReportedScrollEdgeWashEdges = XMScrollEdgeWashEdges.hidden
    private var lastPreferredContentSizeCategory: UIContentSizeCategory?
    private var emptyContentView: (UIView & UIContentView)?
    private weak var observedTopContentScrollController: UIViewController?
    private weak var enclosingTabBarController: UITabBarController?
    private let impactFeedback = UIImpactFeedbackGenerator(style: .light)
    private let selectionFeedback = UISelectionFeedbackGenerator()

    private var collectionView: UICollectionView { self }

    convenience init() {
        self.init(
            frame: .zero,
            collectionViewLayout: UICollectionViewFlowLayout()
        )
    }

    override init(frame: CGRect, collectionViewLayout layout: UICollectionViewLayout) {
        super.init(frame: frame, collectionViewLayout: layout)
        collectionViewLayout = makeLayout(for: configuration)
        backgroundColor = .clear
        alwaysBounceVertical = true
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .always
        configureTopScrollEdgeEffect()
        keyboardDismissMode = .onDrag
        dragInteractionEnabled = false
        reorderingCadence = .immediate
        dataSource = self
        delegate = self
        dragDelegate = self
        dropDelegate = self
        register(
            TagManagementCollectionCell.self,
            forCellWithReuseIdentifier: TagManagementCollectionCell.reuseIdentifier
        )
        register(
            TagManagementCollectionHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: TagManagementCollectionHeaderView.reuseIdentifier
        )
        accessibilityIdentifier = "personal.tag-management.collection"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 布局时维持顶部滚动观察与底部避让，并在字号类别变化后重建自适应布局。
    override func layoutSubviews() {
        super.layoutSubviews()
        updateTopContentScrollObservation()
        updateTopChromeInsets()
        updateBottomChromeInsets()
        let preferredContentSizeCategory = traitCollection.preferredContentSizeCategory
        guard lastPreferredContentSizeCategory != preferredContentSizeCategory else { return }
        let previousContentSizeCategory = lastPreferredContentSizeCategory
        lastPreferredContentSizeCategory = preferredContentSizeCategory

        if previousContentSizeCategory?.isAccessibilityCategory
            != preferredContentSizeCategory.isAccessibilityCategory {
            collectionView.setCollectionViewLayout(
                makeLayout(for: configuration),
                animated: false
            )
        } else {
            collectionView.collectionViewLayout.invalidateLayout()
        }
        updateVisibleCells(animated: false)
    }

    /// 进入或离开窗口时登记/释放顶部滚动 owner，并重算系统底部 Chrome 的实际遮挡。
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            clearTopContentScrollObservation()
        } else {
            updateTopContentScrollObservation()
        }
        updateTopChromeInsets()
        updateBottomChromeInsets()
    }

    /// 安全区变化时同步滚动末端避让，不缓存设备或方向相关的固定高度。
    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        updateTopChromeInsets()
        updateBottomChromeInsets()
    }

    /// 同步页面配置；拖拽过程中延后外部刷新，避免本地预览顺序被中途覆盖。
    func update(with configuration: TagManagementCollectionConfiguration, animated: Bool) {
        if isInteractiveReordering {
            pendingConfiguration = configuration
            return
        }

        let previousConfiguration = self.configuration
        let displayedItems = items
        let needsLayoutUpdate = abs(previousConfiguration.headerHeight - configuration.headerHeight) > 0.5
        let needsDataUpdate = displayedItems != configuration.items
        let needsVisibleCellUpdate = previousConfiguration.presentationSignature != configuration.presentationSignature
        let needsHeaderUpdate = previousConfiguration.headerPresentationSignature
            != configuration.headerPresentationSignature
        self.configuration = configuration
        collectionView.dragInteractionEnabled = configuration.canReorder
        collectionView.isUserInteractionEnabled = !configuration.isDisabled || configuration.canReorder
        updateTopChromeInsets()
        updateEmptyState()

        if needsLayoutUpdate {
            updateLayout(
                from: previousConfiguration,
                to: configuration,
                animated: animated && collectionView.window != nil
            )
        }

        if needsDataUpdate {
            applyItemChanges(
                from: displayedItems,
                previousConfiguration: previousConfiguration,
                animated: animated && collectionView.window != nil
            )
        } else if needsVisibleCellUpdate {
            updateVisibleCells(animated: animated && collectionView.window != nil && !configuration.reducesMotion)
        }
        if needsHeaderUpdate {
            updateVisibleHeader()
        }
        updateScrollEdgeWashEdges()
    }

    /// 清理拖拽缓存，供 SwiftUI 销毁或复用承载视图时恢复稳定状态。
    func prepareForReuse() {
        clearTopContentScrollObservation()
        pendingConfiguration = nil
        originalItemsBeforeDrag = []
        isInteractiveReordering = false
        didChangeOrderInCurrentSession = false
        didReceiveDropInCurrentSession = false
        items = []
        emptyContentView = nil
        collectionView.backgroundView = nil
        lastReportedScrollEdgeWashEdges = .hidden
        let onScrollEdgeWashEdgesChange = configuration.onScrollEdgeWashEdgesChange
        DispatchQueue.main.async {
            onScrollEdgeWashEdgesChange(.hidden)
        }
        collectionView.reloadData()
    }
}

private extension TagManagementCollectionHostView {
    /// 使用系统自动顶部边缘效果，让导航控件在内容经过下方时保持清晰。
    func configureTopScrollEdgeEffect() {
        topEdgeEffect.isHidden = false
        topEdgeEffect.style = .automatic
    }

    /// 将当前集合登记为页面顶部栏的真实滚动 owner，并在控制器切换时移交观察关系。
    func updateTopContentScrollObservation() {
        guard window != nil, let controller = nearestOwningViewController() else {
            clearTopContentScrollObservation()
            return
        }

        guard observedTopContentScrollController !== controller else { return }
        clearTopContentScrollObservation()
        controller.setContentScrollView(self, for: .top)
        observedTopContentScrollController = controller
    }

    /// 仅在控制器仍观察当前集合时释放顶部关系，避免清除后来页面登记的滚动视图。
    func clearTopContentScrollObservation() {
        guard let controller = observedTopContentScrollController else { return }
        if controller.contentScrollView(for: .top) === self {
            controller.setContentScrollView(nil, for: .top)
        }
        observedTopContentScrollController = nil
    }

    /// 沿响应链查找承载当前 SwiftUI 页面桥接层的最近视图控制器。
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

    /// 用页面控制器真实安全区与范围栏实测高度恢复首屏位置，同时保留内容向导航层连续滚动的空间。
    func updateTopChromeInsets() {
        guard window != nil,
              let controller = nearestOwningViewController() else { return }
        let targetTopInset = max(
            controller.view.safeAreaInsets.top + configuration.topBarHeight,
            0
        )
        let previousAdjustedTopInset = adjustedContentInset.top
        let wasAtTop = contentOffset.y <= -previousAdjustedTopInset + Spacing.hairline
        let needsContentInset = abs(contentInset.top - targetTopInset) > Spacing.hairline
        let needsIndicatorInset = abs(
            verticalScrollIndicatorInsets.top - targetTopInset
        ) > Spacing.hairline
        guard needsContentInset || needsIndicatorInset else { return }

        var nextContentInset = contentInset
        nextContentInset.top = targetTopInset
        var nextIndicatorInsets = verticalScrollIndicatorInsets
        nextIndicatorInsets.top = targetTopInset
        UIView.performWithoutAnimation {
            contentInset = nextContentInset
            verticalScrollIndicatorInsets = nextIndicatorInsets
            if wasAtTop {
                contentOffset.y = -adjustedContentInset.top
            }
        }
    }

    /// 读取当前系统 Tab Bar 的真实几何遮挡，只补足 UIKit 未自动提供的部分。
    func updateBottomChromeInsets() {
        guard bounds.height > 0 else { return }
        let tabBarController = resolvedTabBarController()
        let tabBar = tabBarController?.tabBar
        let chromeOverlap: CGFloat
        if let tabBar,
           !tabBar.isHidden,
           tabBar.alpha > 0.01,
           tabBar.window != nil {
            let tabBarFrame = tabBar.convert(tabBar.bounds, to: self)
            chromeOverlap = max(
                min(bounds.maxY, tabBarFrame.maxY) - max(bounds.minY, tabBarFrame.minY),
                0
            )
        } else {
            chromeOverlap = 0
        }

        let automaticBottomInset = max(adjustedContentInset.bottom - contentInset.bottom, 0)
        let targetCustomInset = max(chromeOverlap - automaticBottomInset, 0)
        let needsContentInset = abs(contentInset.bottom - targetCustomInset) > 0.5
        let needsIndicatorInset = abs(
            verticalScrollIndicatorInsets.bottom - targetCustomInset
        ) > 0.5
        guard needsContentInset || needsIndicatorInset else { return }

        var nextContentInset = contentInset
        nextContentInset.bottom = targetCustomInset
        var nextIndicatorInsets = verticalScrollIndicatorInsets
        nextIndicatorInsets.bottom = targetCustomInset
        UIView.performWithoutAnimation {
            contentInset = nextContentInset
            verticalScrollIndicatorInsets = nextIndicatorInsets
        }
        updateScrollEdgeWashEdges()
    }

    /// 从公开控制器层级中定位承载当前页面的系统 Tab Bar Controller。
    func resolvedTabBarController() -> UITabBarController? {
        if let enclosingTabBarController,
           enclosingTabBarController.viewIfLoaded?.window === window {
            return enclosingTabBarController
        }
        guard let rootViewController = window?.rootViewController else { return nil }
        let resolved = findTabBarController(in: rootViewController)
        enclosingTabBarController = resolved
        return resolved
    }

    /// 深度优先查找系统 Tab Bar Controller，覆盖 SwiftUI 根 Hosting Controller 的嵌套关系。
    func findTabBarController(in viewController: UIViewController) -> UITabBarController? {
        if let tabBarController = viewController as? UITabBarController {
            return tabBarController
        }
        if let presentedViewController = viewController.presentedViewController,
           let result = findTabBarController(in: presentedViewController) {
            return result
        }
        for child in viewController.children {
            if let result = findTabBarController(in: child) {
                return result
            }
        }
        return nil
    }

    /// 创建常规双列、辅助字号单列布局，保持搜索头和卡片共享 16pt 视觉边界。
    func makeLayout(for configuration: TagManagementCollectionConfiguration) -> UICollectionViewLayout {
        let isAccessibilityLayout = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        let columnCount = isAccessibilityLayout
            ? TagManagementCollectionMetrics.accessibilityColumnCount
            : TagManagementCollectionMetrics.regularColumnCount
        let itemHeightDimension: NSCollectionLayoutDimension = isAccessibilityLayout
            ? .estimated(TagManagementCollectionMetrics.accessibilityMinimumItemHeight)
            : .fractionalHeight(1)
        let groupHeightDimension: NSCollectionLayoutDimension = isAccessibilityLayout
            ? .estimated(TagManagementCollectionMetrics.accessibilityMinimumItemHeight)
            : .absolute(TagManagementCollectionMetrics.normalItemHeight)
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1 / CGFloat(columnCount)),
            heightDimension: itemHeightDimension
        )
        let item = NSCollectionLayoutItem(layoutSize: itemSize)
        item.contentInsets = NSDirectionalEdgeInsets(
            top: 0,
            leading: TagManagementCollectionMetrics.itemHorizontalGap / 2,
            bottom: 0,
            trailing: TagManagementCollectionMetrics.itemHorizontalGap / 2
        )

        let groupSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1),
            heightDimension: groupHeightDimension
        )
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: groupSize,
            repeatingSubitem: item,
            count: columnCount
        )

        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = TagManagementCollectionMetrics.rowSpacing
        section.contentInsets = NSDirectionalEdgeInsets(
            top: TagManagementCollectionMetrics.dataTopInset,
            leading: TagManagementCollectionMetrics.horizontalInset - TagManagementCollectionMetrics.itemHorizontalGap / 2,
            bottom: TagManagementCollectionMetrics.bottomInset,
            trailing: TagManagementCollectionMetrics.horizontalInset - TagManagementCollectionMetrics.itemHorizontalGap / 2
        )
        if configuration.isSearchVisible {
            let headerSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(configuration.headerHeight)
            )
            let header = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: headerSize,
                elementKind: UICollectionView.elementKindSectionHeader,
                alignment: .top
            )
            header.pinToVisibleBounds = false
            section.boundarySupplementaryItems = [header]
        }

        let layoutConfiguration = UICollectionViewCompositionalLayoutConfiguration()
        layoutConfiguration.scrollDirection = .vertical
        return UICollectionViewCompositionalLayout(section: section, configuration: layoutConfiguration)
    }

    /// 替换搜索头布局时补偿 header 高度变化，避免进出排序态让首个可见标签跳动。
    func updateLayout(
        from previousConfiguration: TagManagementCollectionConfiguration,
        to nextConfiguration: TagManagementCollectionConfiguration,
        animated: Bool
    ) {
        if previousConfiguration.isSearchVisible && !nextConfiguration.isSearchVisible {
            collectionView.endEditing(true)
        }

        let previousHeaderHeight = previousConfiguration.headerHeight
        let nextHeaderHeight = nextConfiguration.headerHeight
        let headerHeightDelta = nextHeaderHeight - previousHeaderHeight
        let previousOffset = collectionView.contentOffset
        let distanceFromTop = previousOffset.y + collectionView.adjustedContentInset.top
        let shouldPreserveFirstVisibleItem = distanceFromTop > previousHeaderHeight

        collectionView.setCollectionViewLayout(
            makeLayout(for: nextConfiguration),
            animated: animated
        ) { [weak self] _ in
            guard let self else { return }
            self.collectionView.layoutIfNeeded()
            guard abs(headerHeightDelta) > 0.5 else { return }

            let minimumOffsetY = -self.collectionView.adjustedContentInset.top
            let targetOffsetY = shouldPreserveFirstVisibleItem
                ? max(minimumOffsetY, previousOffset.y + headerHeightDelta)
                : minimumOffsetY
            self.collectionView.setContentOffset(
                CGPoint(x: previousOffset.x, y: targetOffsetY),
                animated: false
            )
            self.updateScrollEdgeWashEdges()
        }
    }

    /// 使用系统内容不可用视图承载加载、空结果和错误，collection 头部因此始终保留清除查询的入口。
    func updateEmptyState() {
        guard configuration.emptyState != .none else {
            emptyContentView = nil
            collectionView.backgroundView = nil
            return
        }

        let hostedConfiguration = UIHostingConfiguration {
            TagManagementCollectionEmptyStateView(
                state: configuration.emptyState,
                headerHeight: configuration.headerHeight
            )
        }
        .margins(.all, 0)
        .background(Color.surfacePage)

        if let emptyContentView {
            emptyContentView.configuration = hostedConfiguration
        } else {
            let contentView = hostedConfiguration.makeContentView()
            emptyContentView = contentView
            collectionView.backgroundView = contentView
        }
    }

    /// 根据稳定标签 ID 应用局部数据变化，保留删除、插入和排序回滚时的对象连续性。
    func applyItemChanges(
        from previousItems: [TagManagementItem],
        previousConfiguration: TagManagementCollectionConfiguration,
        animated: Bool
    ) {
        let nextItems = configuration.items
        if animated,
           canApplyIdentityItemUpdate(
            from: previousItems,
            to: nextItems,
            previousConfiguration: previousConfiguration,
            nextConfiguration: configuration
           ),
           applyIdentityItemUpdate(from: previousItems, to: nextItems, animated: animated) {
            return
        }

        items = nextItems
        reloadCollection(
            animated: shouldCrossfadeReload(
                from: previousConfiguration,
                to: configuration,
                animated: animated
            )
        )
    }

    /// 判断两个标签数组是否可在当前 collection section 内安全做 item 级批量更新。
    func canApplyIdentityItemUpdate(
        from previousItems: [TagManagementItem],
        to nextItems: [TagManagementItem],
        previousConfiguration: TagManagementCollectionConfiguration,
        nextConfiguration: TagManagementCollectionConfiguration
    ) -> Bool {
        previousConfiguration.scope == nextConfiguration.scope
            && hasUniqueTagIDs(in: previousItems)
            && hasUniqueTagIDs(in: nextItems)
    }

    /// 将同一语境下的标签数组差异转换为 collection view 的删除、插入和移动动画。
    func applyIdentityItemUpdate(
        from previousItems: [TagManagementItem],
        to nextItems: [TagManagementItem],
        animated: Bool
    ) -> Bool {
        let previousIDs = previousItems.map(\.id)
        let nextIDs = nextItems.map(\.id)
        let difference = nextIDs.difference(from: previousIDs).inferringMoves()
        var deletions: [IndexPath] = []
        var insertions: [IndexPath] = []
        var moves: [(from: IndexPath, to: IndexPath)] = []

        for change in difference {
            switch change {
            case let .remove(offset, _, associatedWith):
                if let destination = associatedWith {
                    moves.append((
                        from: IndexPath(item: offset, section: 0),
                        to: IndexPath(item: destination, section: 0)
                    ))
                } else {
                    deletions.append(IndexPath(item: offset, section: 0))
                }
            case let .insert(offset, _, associatedWith):
                if associatedWith == nil {
                    insertions.append(IndexPath(item: offset, section: 0))
                }
            }
        }

        guard !deletions.isEmpty || !insertions.isEmpty || !moves.isEmpty else {
            items = nextItems
            updateVisibleCells(animated: animated && !configuration.reducesMotion)
            return true
        }
        guard collectionView.numberOfSections > 0,
              collectionView.numberOfItems(inSection: 0) == previousItems.count else {
            return false
        }

        items = nextItems
        let updates = {
            if !deletions.isEmpty {
                self.collectionView.deleteItems(at: deletions)
            }
            if !insertions.isEmpty {
                self.collectionView.insertItems(at: insertions)
            }
            for move in moves {
                self.collectionView.moveItem(at: move.from, to: move.to)
            }
        }
        let completion: (Bool) -> Void = { [weak self] _ in
            guard let self else { return }
            self.updateVisibleCells(animated: animated && !self.configuration.reducesMotion)
            self.updateScrollEdgeWashEdges()
        }

        if animated && !configuration.reducesMotion {
            collectionView.performBatchUpdates(updates, completion: completion)
        } else {
            UIView.performWithoutAnimation {
                collectionView.performBatchUpdates(updates, completion: completion)
            }
        }
        return true
    }

    /// 对不适合 item diff 的范围切换做受控刷新；逐字搜索只更新 item，避免重建输入头。
    func reloadCollection(animated: Bool) {
        let updates = {
            self.collectionView.reloadData()
            self.collectionView.layoutIfNeeded()
        }
        guard animated else {
            UIView.performWithoutAnimation(updates)
            return
        }
        UIView.transition(
            with: collectionView,
            duration: TagManagementCollectionMetrics.reloadCrossfadeDuration,
            options: [.transitionCrossDissolve, .allowUserInteraction, .beginFromCurrentState]
        ) {
            updates()
        }
    }

    /// 判断当前 reload 是否适合轻微 crossfade；搜索变化保持即时刷新以保证输入跟手。
    func shouldCrossfadeReload(
        from previousConfiguration: TagManagementCollectionConfiguration,
        to nextConfiguration: TagManagementCollectionConfiguration,
        animated: Bool
    ) -> Bool {
        animated
            && !nextConfiguration.reducesMotion
            && previousConfiguration.scope != nextConfiguration.scope
    }

    /// 撤销未提交的拖拽预览顺序时复用 item 级移动，避免取消排序时整组闪烁。
    func restoreItemsAfterCancelledReorder(
        from previewItems: [TagManagementItem],
        to restoredItems: [TagManagementItem]
    ) {
        if collectionView.window != nil,
           canApplyIdentityItemUpdate(
            from: previewItems,
            to: restoredItems,
            previousConfiguration: configuration,
            nextConfiguration: configuration
           ),
           applyIdentityItemUpdate(from: previewItems, to: restoredItems, animated: true) {
            return
        }

        items = restoredItems
        reloadCollection(animated: false)
    }

    /// 校验标签 ID 唯一性，避免同一轮批量更新中出现 UIKit 无法判定的身份冲突。
    func hasUniqueTagIDs(in items: [TagManagementItem]) -> Bool {
        Set(items.map(\.id)).count == items.count
    }

    /// 将 UIKit 滚动状态转换为公共柔化层状态，并去重后回传给 SwiftUI 外层。
    func updateScrollEdgeWashEdges() {
        let topOffset = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let bottomRemaining = collectionView.contentSize.height
            + collectionView.adjustedContentInset.bottom
            - collectionView.bounds.height
            - collectionView.contentOffset.y
        let activeEdges = XMScrollEdgeWashEdges(
            top: topOffset > Spacing.hairline,
            bottom: bottomRemaining > Spacing.hairline
        )
        reportScrollEdgeWashEdges(activeEdges)
    }

    /// 异步上报边缘状态，避免 UIViewRepresentable 更新期同步写入 SwiftUI 状态。
    func reportScrollEdgeWashEdges(_ activeEdges: XMScrollEdgeWashEdges) {
        guard activeEdges != lastReportedScrollEdgeWashEdges else { return }
        lastReportedScrollEdgeWashEdges = activeEdges
        let onScrollEdgeWashEdgesChange = configuration.onScrollEdgeWashEdgesChange
        DispatchQueue.main.async {
            onScrollEdgeWashEdgesChange(activeEdges)
        }
    }

    /// 读取指定位置的标签项。
    func item(at indexPath: IndexPath) -> TagManagementItem? {
        guard indexPath.section == 0, items.indices.contains(indexPath.item) else { return nil }
        return items[indexPath.item]
    }

    /// 按当前位置重新配置可见 cell，让模式切换和选择反馈保留 SwiftUI 内部过渡。
    func updateVisibleCells(animated: Bool) {
        for case let cell as TagManagementCollectionCell in collectionView.visibleCells {
            guard let indexPath = collectionView.indexPath(for: cell) else { continue }
            configure(cell, at: indexPath, animated: animated)
        }
    }

    /// 更新当前可见控制头的 Binding 与计数，不重载标签 cell 或改变滚动位置。
    func updateVisibleHeader() {
        for case let header as TagManagementCollectionHeaderView in collectionView.visibleSupplementaryViews(
            ofKind: UICollectionView.elementKindSectionHeader
        ) {
            configure(header)
        }
    }

    /// 更新稳定控制头模型，让逐字搜索不会替换 SwiftUI 宿主或第一响应者。
    func configure(_ header: TagManagementCollectionHeaderView) {
        header.configure(
            searchText: configuration.searchText,
            isSearchActive: configuration.isSearchActive,
            prompt: configuration.searchPrompt,
            isEnabled: configuration.isSearchEnabled,
            onSearchTextChange: { [weak self] in self?.configuration.onSearchTextChange($0) },
            onSearchActiveChange: { [weak self] in self?.configuration.onSearchActiveChange($0) }
        )
    }

    /// 统一组装 cell 的展示配置和操作闭包，避免 data source 与局部刷新路径行为分叉。
    func configure(_ cell: TagManagementCollectionCell, at indexPath: IndexPath, animated: Bool) {
        guard let item = item(at: indexPath) else { return }
        cell.configure(
            with: item,
            configuration: configuration,
            animated: animated,
            onRename: { [weak self] in
                guard let self else { return }
                self.configuration.onRename(self.currentItem(matching: item))
            },
            onDelete: { [weak self] in
                guard let self else { return }
                self.configuration.onDelete(self.currentItem(matching: item))
            }
        )
    }

    /// 按标签 ID 回读当前数据源中的展示项，让复用 cell 的菜单动作始终使用最新配置分发。
    func currentItem(matching item: TagManagementItem) -> TagManagementItem {
        items.first { $0.id == item.id } ?? item
    }

    /// 返回指定标签 ID 当前所在位置。
    func indexPath(for tagID: Int64) -> IndexPath? {
        guard let index = items.firstIndex(where: { $0.id == tagID }) else { return nil }
        return IndexPath(item: index, section: 0)
    }

    /// 当前本地预览顺序。
    func currentOrderedIDs() -> [Int64] {
        items.map(\.id)
    }

    /// 判断指定位置是否允许启动排序。
    func canBeginReorder(at indexPath: IndexPath) -> Bool {
        configuration.canReorder && item(at: indexPath) != nil
    }

    /// 记录拖拽开始前的本地快照。
    func beginReorderSession(at indexPath: IndexPath) {
        guard !isInteractiveReordering else { return }
        isInteractiveReordering = true
        didChangeOrderInCurrentSession = false
        didReceiveDropInCurrentSession = false
        originalItemsBeforeDrag = items
        impactFeedback.prepare()
        impactFeedback.impactOccurred(intensity: 0.72)
        selectionFeedback.prepare()
    }

    /// 拖拽结束时提交最终顺序，取消或未变化时恢复原顺序。
    func finishReorderSession() {
        guard isInteractiveReordering else { return }
        let originalIDs = originalItemsBeforeDrag.map(\.id)
        let currentIDs = currentOrderedIDs()
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
            restoreItemsAfterCancelledReorder(from: items, to: originalItemsBeforeDrag)
        }
        originalItemsBeforeDrag = []

        if let pendingConfiguration {
            self.pendingConfiguration = nil
            update(with: pendingConfiguration, animated: false)
        }
    }

    /// 将系统建议的 drop 目标约束到唯一标签 section。
    func normalizedDestinationIndexPath(for proposed: IndexPath?) -> IndexPath? {
        guard !items.isEmpty else { return nil }
        var proposedItem = proposed?.item ?? (items.count - 1)
        proposedItem = min(max(0, proposedItem), items.count - 1)
        return IndexPath(item: proposedItem, section: 0)
    }

    /// 在 UIKit 本地数据源中移动标签，最终落库由拖拽结束统一提交。
    func applyLocalMove(from sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        guard sourceIndexPath != destinationIndexPath,
              sourceIndexPath.section == 0,
              destinationIndexPath.section == 0,
              items.indices.contains(sourceIndexPath.item),
              items.indices.contains(destinationIndexPath.item) else {
            return
        }
        let item = items.remove(at: sourceIndexPath.item)
        items.insert(item, at: destinationIndexPath.item)
        didChangeOrderInCurrentSession = true
    }
}

extension TagManagementCollectionHostView: UICollectionViewDataSource {
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: TagManagementCollectionCell.reuseIdentifier,
            for: indexPath
        ) as? TagManagementCollectionCell else {
            return UICollectionViewCell()
        }

        configure(cell, at: indexPath, animated: false)
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
                withReuseIdentifier: TagManagementCollectionHeaderView.reuseIdentifier,
                for: indexPath
              ) as? TagManagementCollectionHeaderView else {
            return UICollectionReusableView()
        }
        configure(header)
        return header
    }

    func collectionView(_ collectionView: UICollectionView, canMoveItemAt indexPath: IndexPath) -> Bool {
        canBeginReorder(at: indexPath)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        moveItemAt sourceIndexPath: IndexPath,
        to destinationIndexPath: IndexPath
    ) {
        guard let destination = normalizedDestinationIndexPath(for: destinationIndexPath) else { return }
        applyLocalMove(from: sourceIndexPath, to: destination)
    }
}

extension TagManagementCollectionHostView: UICollectionViewDelegate {
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        updateScrollEdgeWashEdges()
    }

    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard let item = item(at: indexPath) else { return }
        configuration.onPrimaryAction(item)
    }

    func collectionView(_ collectionView: UICollectionView, shouldSelectItemAt indexPath: IndexPath) -> Bool {
        !configuration.isDisabled && !configuration.isReordering && item(at: indexPath) != nil
    }

    func collectionView(
        _ collectionView: UICollectionView,
        targetIndexPathForMoveFromItemAt originalIndexPath: IndexPath,
        toProposedIndexPath proposedIndexPath: IndexPath
    ) -> IndexPath {
        normalizedDestinationIndexPath(for: proposedIndexPath) ?? originalIndexPath
    }
}

extension TagManagementCollectionHostView: UICollectionViewDragDelegate {
    func collectionView(
        _ collectionView: UICollectionView,
        itemsForBeginning session: UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        guard canBeginReorder(at: indexPath), let item = item(at: indexPath) else { return [] }
        beginReorderSession(at: indexPath)
        let itemProvider = NSItemProvider(object: NSString(string: "tag:\(item.id)"))
        let dragItem = UIDragItem(itemProvider: itemProvider)
        dragItem.localObject = item.id
        return [dragItem]
    }

    func collectionView(_ collectionView: UICollectionView, dragSessionDidEnd session: UIDragSession) {
        finishReorderSession()
    }
}

extension TagManagementCollectionHostView: UICollectionViewDropDelegate {
    func collectionView(_ collectionView: UICollectionView, canHandle session: UIDropSession) -> Bool {
        session.localDragSession != nil
    }

    func collectionView(
        _ collectionView: UICollectionView,
        dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UICollectionViewDropProposal {
        guard session.localDragSession != nil, configuration.canReorder else {
            return UICollectionViewDropProposal(operation: .forbidden)
        }
        return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        guard let dropItem = coordinator.items.first else { return }
        didReceiveDropInCurrentSession = true

        guard let movingID = dropItem.dragItem.localObject as? Int64,
              let sourceIndexPath = indexPath(for: movingID),
              let destination = normalizedDestinationIndexPath(for: coordinator.destinationIndexPath) else {
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

struct TagManagementCollectionConfiguration {
    let items: [TagManagementItem]
    let scope: TagManagementScope
    let searchText: String
    let isSearchActive: Bool
    let searchPrompt: String
    let isSearchVisible: Bool
    let isSearchEnabled: Bool
    let emptyState: TagManagementCollectionEmptyState
    let searchKeyword: String
    let isSelectionMode: Bool
    let isReordering: Bool
    let selectedTagIDs: Set<Int64>
    let isDisabled: Bool
    let reducesMotion: Bool
    let topBarHeight: CGFloat
    let onScrollEdgeWashEdgesChange: (XMScrollEdgeWashEdges) -> Void
    let onSearchTextChange: (String) -> Void
    let onSearchActiveChange: (Bool) -> Void
    let onPrimaryAction: (TagManagementItem) -> Void
    let onRename: (TagManagementItem) -> Void
    let onDelete: (TagManagementItem) -> Void
    let onCommitOrder: ([Int64]) -> Void

    var canReorder: Bool {
        isReordering && !isDisabled && items.count > 1
    }

    var headerHeight: CGFloat {
        isSearchVisible ? TagManagementCollectionMetrics.searchHeaderHeight : 0
    }

    var headerPresentationSignature: TagManagementCollectionHeaderPresentationSignature {
        TagManagementCollectionHeaderPresentationSignature(
            searchText: searchText,
            isSearchActive: isSearchActive,
            searchPrompt: searchPrompt,
            isSearchVisible: isSearchVisible,
            isSearchEnabled: isSearchEnabled
        )
    }

    var presentationSignature: TagManagementCollectionPresentationSignature {
        TagManagementCollectionPresentationSignature(
            items: items,
            scope: scope,
            searchKeyword: searchKeyword,
            isSelectionMode: isSelectionMode,
            isReordering: isReordering,
            selectedTagIDs: selectedTagIDs,
            isDisabled: isDisabled,
            reducesMotion: reducesMotion
        )
    }

    static let empty = TagManagementCollectionConfiguration(
        items: [],
        scope: .note,
        searchText: "",
        isSearchActive: false,
        searchPrompt: "搜索书摘标签",
        isSearchVisible: true,
        isSearchEnabled: true,
        emptyState: .none,
        searchKeyword: "",
        isSelectionMode: false,
        isReordering: false,
        selectedTagIDs: [],
        isDisabled: false,
        reducesMotion: false,
        topBarHeight: 0,
        onScrollEdgeWashEdgesChange: { _ in },
        onSearchTextChange: { _ in },
        onSearchActiveChange: { _ in },
        onPrimaryAction: { _ in },
        onRename: { _ in },
        onDelete: { _ in },
        onCommitOrder: { _ in }
    )
}

/// 标签 collection 的系统空态，保留可比较身份以过滤无效宿主刷新。
enum TagManagementCollectionEmptyState: Hashable {
    case none
    case loading(String)
    case empty(title: String)
    case search(query: String)
    case error(message: String)
}

/// 聚合控制头的可见输入与模式，用于只刷新 supplementary header。
struct TagManagementCollectionHeaderPresentationSignature: Hashable {
    let searchText: String
    let isSearchActive: Bool
    let searchPrompt: String
    let isSearchVisible: Bool
    let isSearchEnabled: Bool
}

/// 聚合会影响 cell 内容、布局态或交互语义的字段，用于过滤 SwiftUI 外层状态变化带来的无效刷新。
struct TagManagementCollectionPresentationSignature: Hashable {
    let items: [TagManagementItem]
    let scope: TagManagementScope
    let searchKeyword: String
    let isSelectionMode: Bool
    let isReordering: Bool
    let selectedTagIDs: Set<Int64>
    let isDisabled: Bool
    let reducesMotion: Bool
}

private enum TagManagementCollectionMetrics {
    static let regularColumnCount = 2
    static let accessibilityColumnCount = 1
    static let normalItemHeight: CGFloat = 48
    static let accessibilityMinimumItemHeight: CGFloat = 56
    static let horizontalInset: CGFloat = Spacing.screenEdge
    static let dataTopInset: CGFloat = 0
    static let bottomInset: CGFloat = Spacing.double
    static let searchHeaderHeight: CGFloat = 56
    static let itemHorizontalGap: CGFloat = Spacing.cozy
    static let searchHeaderHorizontalInset: CGFloat = -(itemHorizontalGap / 2)
    static let rowSpacing: CGFloat = Spacing.cozy
    static let reorderHitWidth: CGFloat = Spacing.actionReserved
    static let reorderHitHeight: CGFloat = Spacing.actionReserved
    static let reloadCrossfadeDuration: TimeInterval = 0.16
}

/// 标签 collection 的边界搜索头，保持系统搜索栏与标签内容的滚动关系。
private final class TagManagementCollectionHeaderView: UICollectionReusableView {
    static let reuseIdentifier = "TagManagementCollectionHeaderView"
    private var hostedContentView: (UIView & UIContentView)?
    private let model = TagManagementCollectionHeaderModel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 使用宿主内容的压缩尺寸修正 estimated header，支持系统搜索栏随辅助功能字号增高。
    override func preferredLayoutAttributesFitting(
        _ layoutAttributes: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        guard let attributes = layoutAttributes.copy() as? UICollectionViewLayoutAttributes,
              let hostedContentView else {
            return layoutAttributes
        }

        let fittingSize = CGSize(
            width: layoutAttributes.size.width,
            height: UIView.layoutFittingCompressedSize.height
        )
        let measuredHeight = hostedContentView.systemLayoutSizeFitting(
            fittingSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
        attributes.frame.size.height = ceil(max(measuredHeight, 1))
        return attributes
    }

    /// 只更新可观察模型；宿主在首次展示后保持身份稳定，保证输入焦点与键盘连续。
    func configure(
        searchText: String,
        isSearchActive: Bool,
        prompt: String,
        isEnabled: Bool,
        onSearchTextChange: @escaping (String) -> Void,
        onSearchActiveChange: @escaping (Bool) -> Void
    ) {
        model.update(
            searchText: searchText,
            isSearchActive: isSearchActive,
            prompt: prompt,
            isEnabled: isEnabled,
            onSearchTextChange: onSearchTextChange,
            onSearchActiveChange: onSearchActiveChange
        )

        guard hostedContentView == nil else { return }
        let configuration = UIHostingConfiguration {
            TagManagementCollectionHeaderContent(model: model)
        }
        .margins(.all, 0)
        .background(Color.clear)
        let contentView = configuration.makeContentView()
        contentView.translatesAutoresizingMaskIntoConstraints = false
        hostedContentView = contentView
        addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: trailingAnchor),
            contentView.topAnchor.constraint(equalTo: topAnchor),
            contentView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }
}

/// UIKit supplementary view 持有的稳定状态模型，区分外部同步与用户输入回调。
private final class TagManagementCollectionHeaderModel: ObservableObject {
    @Published var searchText = ""
    @Published var isSearchActive = false
    @Published var prompt = "搜索书摘标签"
    @Published var isEnabled = true

    private var onSearchTextChange: (String) -> Void = { _ in }
    private var onSearchActiveChange: (Bool) -> Void = { _ in }

    /// 从页面 owner 同步展示配置，不反向触发业务写入。
    func update(
        searchText: String,
        isSearchActive: Bool,
        prompt: String,
        isEnabled: Bool,
        onSearchTextChange: @escaping (String) -> Void,
        onSearchActiveChange: @escaping (Bool) -> Void
    ) {
        self.onSearchTextChange = onSearchTextChange
        self.onSearchActiveChange = onSearchActiveChange
        if self.searchText != searchText { self.searchText = searchText }
        if self.isSearchActive != isSearchActive { self.isSearchActive = isSearchActive }
        if self.prompt != prompt { self.prompt = prompt }
        if self.isEnabled != isEnabled { self.isEnabled = isEnabled }
    }

    /// 接收搜索文本变化并回写 TagManagementView。
    func setSearchText(_ value: String) {
        guard searchText != value else { return }
        searchText = value
        onSearchTextChange(value)
    }

    /// 接收焦点变化并回写 TagManagementView。
    func setSearchActive(_ value: Bool) {
        guard isSearchActive != value else { return }
        isSearchActive = value
        onSearchActiveChange(value)
    }
}

/// 标签搜索的 SwiftUI 宿主，所有写入通过 Binding 回到 TagManagementView。
private struct TagManagementCollectionHeaderContent: View {
    @ObservedObject var model: TagManagementCollectionHeaderModel

    private var searchText: Binding<String> {
        Binding(get: { model.searchText }, set: model.setSearchText)
    }

    private var isSearchActive: Binding<Bool> {
        Binding(get: { model.isSearchActive }, set: model.setSearchActive)
    }

    var body: some View {
        PersonalManagementSearchBar(
            text: searchText,
            isActive: isSearchActive,
            prompt: model.prompt,
            isEnabled: model.isEnabled
        )
        .padding(.horizontal, TagManagementCollectionMetrics.searchHeaderHorizontalInset)
    }
}

/// 标签 collection 的系统内容不可用宿主，空结果时不替换滚动控制头。
private struct TagManagementCollectionEmptyStateView: View {
    let state: TagManagementCollectionEmptyState
    let headerHeight: CGFloat

    var body: some View {
        Group {
            switch state {
            case .none:
                Color.clear
            case .loading(let message):
                LoadingStateView(message, style: .inline)
            case .empty(let title):
                ContentUnavailableView(title, systemImage: "tag")
            case .search(let query):
                ContentUnavailableView.search(text: query)
            case .error(let message):
                ContentUnavailableView(
                    "标签加载失败",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, headerHeight)
        .background(Color.surfacePage)
    }
}

/// 标签 collection cell，通过 UIHostingConfiguration 复用 SwiftUI 卡片视觉。
private final class TagManagementCollectionCell: UICollectionViewCell {
    static let reuseIdentifier = "TagManagementCollectionCell"

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

    /// 渲染当前标签项。
    func configure(
        with item: TagManagementItem,
        configuration: TagManagementCollectionConfiguration,
        animated: Bool,
        onRename: @escaping () -> Void,
        onDelete: @escaping () -> Void
    ) {
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        let nextContentConfiguration = UIHostingConfiguration {
            TagManagementCollectionItemView(
                item: item,
                scope: configuration.scope,
                searchKeyword: configuration.searchKeyword,
                isSelectionMode: configuration.isSelectionMode,
                isSelected: configuration.selectedTagIDs.contains(item.id),
                isReordering: configuration.isReordering,
                isDisabled: configuration.isDisabled,
                allowsMotion: animated && !configuration.reducesMotion,
                onRename: onRename,
                onDelete: onDelete
            )
        }
        .margins(.all, 0)

        if animated {
            contentConfiguration = nextContentConfiguration
        } else {
            UIView.performWithoutAnimation {
                contentConfiguration = nextContentConfiguration
            }
        }
    }
}

private struct TagManagementCollectionItemView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let item: TagManagementItem
    let scope: TagManagementScope
    let searchKeyword: String
    let isSelectionMode: Bool
    let isSelected: Bool
    let isReordering: Bool
    let isDisabled: Bool
    let allowsMotion: Bool
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Spacing.compact) {
            if isSelectionMode {
                XMSelectionIndicator(
                    style: .checkbox,
                    isSelected: isSelected,
                    font: AppTypography.subheadline
                )
                .transition(selectionIndicatorTransition)
                .animation(selectionAnimation, value: isSelected)
            }

            XMKeywordHighlighting.text(
                item.name,
                keyword: searchKeyword,
                baseFont: AppTypography.subheadlineMedium,
                highlightFont: AppTypography.subheadlineMedium,
                baseColor: Color.textPrimary
            )
                .lineLimit(isAccessibilityLayout ? 2 : 1)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            if isReordering {
                reorderHandle
                    .transition(trailingSlotTransition)
            }
        }
        .padding(.horizontal, Spacing.base)
        .padding(.vertical, isAccessibilityLayout ? Spacing.cozy : Spacing.none)
        .frame(
            maxWidth: .infinity,
            minHeight: minimumItemHeight,
            maxHeight: .infinity,
            alignment: .leading
        )
        .contentShape(.interaction, RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
        }
        .modifier(TagManagementItemManagementModifier(
            isEnabled: shouldShowManagementMenu,
            onRename: onRename,
            onDelete: onDelete
        ))
        .xmMenuNeutralTint()
        .disabled(isDisabled)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint(accessibilityHint)
        .accessibilityAddTraits(accessibilityTraits)
        .animation(modeAnimation, value: isSelectionMode)
        .animation(modeAnimation, value: isReordering)
        .animation(selectionAnimation, value: isSelected)
        .transaction { transaction in
            guard shouldReduceMotion else { return }
            transaction.disablesAnimations = true
            transaction.animation = nil
        }
    }

    private var reorderHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(AppTypography.subheadline)
            .foregroundStyle(Color.textSecondary)
            .frame(
                width: TagManagementCollectionMetrics.reorderHitWidth,
                height: TagManagementCollectionMetrics.reorderHitHeight,
                alignment: .center
            )
            .contentShape(Rectangle())
            .accessibilityHidden(true)
    }

    private var shouldShowManagementMenu: Bool {
        !isSelectionMode && !isReordering && !isDisabled
    }

    private var isAccessibilityLayout: Bool {
        dynamicTypeSize.isAccessibilitySize
    }

    private var minimumItemHeight: CGFloat {
        isAccessibilityLayout
            ? TagManagementCollectionMetrics.accessibilityMinimumItemHeight
            : TagManagementCollectionMetrics.normalItemHeight
    }

    private var shouldReduceMotion: Bool {
        reduceMotion || !allowsMotion
    }

    private var modeAnimation: Animation? {
        shouldReduceMotion ? nil : .smooth(duration: 0.22)
    }

    private var selectionAnimation: Animation? {
        shouldReduceMotion ? nil : .snappy(duration: 0.16)
    }

    private var selectionIndicatorTransition: AnyTransition {
        if shouldReduceMotion {
            return .opacity
        }
        return .scale(scale: 0.82, anchor: .center).combined(with: .opacity)
    }

    private var trailingSlotTransition: AnyTransition {
        if shouldReduceMotion {
            return .opacity
        }
        return .opacity.combined(with: .scale(scale: 0.94, anchor: .trailing))
    }

    private var associatedText: String {
        if item.associatedCount == 0 {
            return "未关联\(scope.associatedItemTitle)"
        }
        return "关联 \(item.associatedCount) 条\(scope.associatedItemTitle)"
    }

    private var accessibilityLabel: String {
        if isSelectionMode {
            return "\(item.name)，\(associatedText)"
        }
        if isReordering {
            return "\(item.name)，可拖动调整顺序"
        }
        return item.name
    }

    private var accessibilityHint: String {
        if isSelectionMode {
            return "轻点切换选择状态"
        }
        if isReordering {
            return "长按并拖动调整顺序"
        }
        if isDisabled {
            return ""
        }
        return "轻点编辑，长按显示更多操作"
    }

    private var accessibilityTraits: AccessibilityTraits {
        var traits: AccessibilityTraits = isReordering ? [] : .isButton
        if isSelectionMode && isSelected {
            traits.formUnion(.isSelected)
        }
        return traits
    }
}

/// 仅在普通可交互状态提供整卡长按菜单及等价 VoiceOver 操作。
private struct TagManagementItemManagementModifier: ViewModifier {
    let isEnabled: Bool
    let onRename: () -> Void
    let onDelete: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if isEnabled {
            content
                .contentShape(
                    .contextMenuPreview,
                    RoundedRectangle(cornerRadius: CornerRadius.blockLarge, style: .continuous)
                )
                .contextMenu {
                    Button(action: onRename) {
                        XMMenuLabel("编辑标签", systemImage: "pencil")
                    }
                    Button(role: .destructive, action: onDelete) {
                        Label("删除标签", systemImage: "trash")
                    }
                }
                .accessibilityAction(named: "编辑标签", onRename)
                .accessibilityAction(named: "删除标签", onDelete)
        } else {
            content
        }
    }
}
