/**
 * [INPUT]: 依赖 TagManagementItem/TagManagementScope、XMSelectionIndicator/XMKeywordHighlighting、XMScrollEdgeWashEdges 与页面传入的搜索关键词和标签操作回调，承接标签管理页的两列展示与本地拖拽排序
 * [OUTPUT]: 对外提供 TagManagementCollectionView，封装页面私有 UICollectionView bridge、两列布局、选择态、排序态与滚动边缘状态上报
 * [POS]: Views/Personal/Components 的标签管理页面私有集合组件，被 TagManagementView 用作标签主体内容区
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 标签管理两列集合视图，负责普通态、选择态和排序态的布局与本地拖拽预览。
struct TagManagementCollectionView: UIViewRepresentable {
    let items: [TagManagementItem]
    let scope: TagManagementScope
    let searchKeyword: String
    let isSelectionMode: Bool
    let isReordering: Bool
    let selectedTagIDs: Set<Int64>
    let isDisabled: Bool
    let bottomContentInset: CGFloat
    let onScrollEdgeWashEdgesChange: (XMScrollEdgeWashEdges) -> Void
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
            searchKeyword: searchKeyword,
            isSelectionMode: isSelectionMode,
            isReordering: isReordering,
            selectedTagIDs: selectedTagIDs,
            isDisabled: isDisabled,
            reducesMotion: reduceMotion,
            bottomContentInset: bottomContentInset,
            onScrollEdgeWashEdgesChange: onScrollEdgeWashEdgesChange,
            onPrimaryAction: onPrimaryAction,
            onRename: onRename,
            onDelete: onDelete,
            onCommitOrder: onCommitOrder
        )
    }
}

/// UICollectionView 承载视图，隔离 UIKit 拖拽排序细节。
final class TagManagementCollectionHostView: UIView {
    private var configuration = TagManagementCollectionConfiguration.empty
    private var items: [TagManagementItem] = []
    private var pendingConfiguration: TagManagementCollectionConfiguration?
    private var originalItemsBeforeDrag: [TagManagementItem] = []
    private var isInteractiveReordering = false
    private var didChangeOrderInCurrentSession = false
    private var didReceiveDropInCurrentSession = false
    private var lastReportedScrollEdgeWashEdges = XMScrollEdgeWashEdges.hidden
    private let impactFeedback = UIImpactFeedbackGenerator(style: .light)
    private let selectionFeedback = UISelectionFeedbackGenerator()

    private lazy var collectionView: UICollectionView = {
        let view = UICollectionView(
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
            TagManagementCollectionCell.self,
            forCellWithReuseIdentifier: TagManagementCollectionCell.reuseIdentifier
        )
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

    /// 同步页面配置；拖拽过程中延后外部刷新，避免本地预览顺序被中途覆盖。
    func update(with configuration: TagManagementCollectionConfiguration, animated: Bool) {
        if isInteractiveReordering {
            pendingConfiguration = configuration
            return
        }

        let previousConfiguration = self.configuration
        let displayedItems = items
        let needsLayoutUpdate = abs(previousConfiguration.itemHeight - configuration.itemHeight) > 0.5
        let needsDataUpdate = displayedItems != configuration.items
        let needsVisibleCellUpdate = previousConfiguration.presentationSignature != configuration.presentationSignature
        self.configuration = configuration
        collectionView.dragInteractionEnabled = configuration.canReorder
        collectionView.isUserInteractionEnabled = !configuration.isDisabled || configuration.canReorder
        updateBottomContentInset()

        if needsLayoutUpdate {
            collectionView.setCollectionViewLayout(
                makeLayout(for: configuration),
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
        updateScrollEdgeWashEdges()
    }

    /// 清理拖拽缓存，供 SwiftUI 销毁或复用承载视图时恢复稳定状态。
    func prepareForReuse() {
        pendingConfiguration = nil
        originalItemsBeforeDrag = []
        isInteractiveReordering = false
        didChangeOrderInCurrentSession = false
        didReceiveDropInCurrentSession = false
        items = []
        lastReportedScrollEdgeWashEdges = .hidden
        let onScrollEdgeWashEdgesChange = configuration.onScrollEdgeWashEdgesChange
        DispatchQueue.main.async {
            onScrollEdgeWashEdgesChange(.hidden)
        }
        collectionView.reloadData()
    }
}

private extension TagManagementCollectionHostView {
    /// 建立 collection view 约束。
    func setupViewHierarchy() {
        addSubview(collectionView)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.accessibilityIdentifier = "personal.tag-management.collection"

        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    /// 创建固定两列布局，确保普通态、选择态和排序态的空间关系一致。
    func makeLayout(for configuration: TagManagementCollectionConfiguration) -> UICollectionViewLayout {
        let itemSize = NSCollectionLayoutSize(
            widthDimension: .fractionalWidth(1 / CGFloat(TagManagementCollectionMetrics.columnCount)),
            heightDimension: .fractionalHeight(1)
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
            heightDimension: .absolute(configuration.itemHeight)
        )
        let group = NSCollectionLayoutGroup.horizontal(
            layoutSize: groupSize,
            repeatingSubitem: item,
            count: TagManagementCollectionMetrics.columnCount
        )

        let section = NSCollectionLayoutSection(group: group)
        section.interGroupSpacing = TagManagementCollectionMetrics.rowSpacing
        section.contentInsets = NSDirectionalEdgeInsets(
            top: TagManagementCollectionMetrics.topInset,
            leading: TagManagementCollectionMetrics.horizontalInset - TagManagementCollectionMetrics.itemHorizontalGap / 2,
            bottom: TagManagementCollectionMetrics.bottomInset,
            trailing: TagManagementCollectionMetrics.horizontalInset - TagManagementCollectionMetrics.itemHorizontalGap / 2
        )

        let layoutConfiguration = UICollectionViewCompositionalLayoutConfiguration()
        layoutConfiguration.scrollDirection = .vertical
        return UICollectionViewCompositionalLayout(section: section, configuration: layoutConfiguration)
    }

    /// 同步自定义底部操作栏占位；普通系统 toolbar 由安全区与滚动边缘效果接管。
    func updateBottomContentInset() {
        let targetBottomInset = configuration.bottomContentInset
        let needsContentInsetUpdate = abs(collectionView.contentInset.bottom - targetBottomInset) > 0.5
        let needsScrollIndicatorInsetUpdate = abs(collectionView.verticalScrollIndicatorInsets.bottom - targetBottomInset) > 0.5
        guard needsContentInsetUpdate || needsScrollIndicatorInsetUpdate else { return }
        collectionView.contentInset.bottom = targetBottomInset
        collectionView.verticalScrollIndicatorInsets.bottom = targetBottomInset
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
            && previousConfiguration.searchKeyword == nextConfiguration.searchKeyword
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

    /// 对不适合 item diff 的语境切换做受控刷新，避免搜索逐字筛选产生误导性删除动画。
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
    let searchKeyword: String
    let isSelectionMode: Bool
    let isReordering: Bool
    let selectedTagIDs: Set<Int64>
    let isDisabled: Bool
    let reducesMotion: Bool
    let bottomContentInset: CGFloat
    let onScrollEdgeWashEdgesChange: (XMScrollEdgeWashEdges) -> Void
    let onPrimaryAction: (TagManagementItem) -> Void
    let onRename: (TagManagementItem) -> Void
    let onDelete: (TagManagementItem) -> Void
    let onCommitOrder: ([Int64]) -> Void

    var canReorder: Bool {
        isReordering && !isDisabled && items.count > 1
    }

    var itemHeight: CGFloat {
        TagManagementCollectionMetrics.normalItemHeight
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
        searchKeyword: "",
        isSelectionMode: false,
        isReordering: false,
        selectedTagIDs: [],
        isDisabled: false,
        reducesMotion: false,
        bottomContentInset: 0,
        onScrollEdgeWashEdgesChange: { _ in },
        onPrimaryAction: { _ in },
        onRename: { _ in },
        onDelete: { _ in },
        onCommitOrder: { _ in }
    )
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
    static let columnCount = 2
    static let normalItemHeight: CGFloat = 44
    static let horizontalInset: CGFloat = Spacing.screenEdge
    static let topInset: CGFloat = Spacing.base
    static let bottomInset: CGFloat = Spacing.double
    static let itemHorizontalGap: CGFloat = Spacing.cozy
    static let rowSpacing: CGFloat = Spacing.cozy
    static let menuHitWidth: CGFloat = Spacing.actionReserved
    static let menuHitHeight: CGFloat = Spacing.actionReserved
    static let reloadCrossfadeDuration: TimeInterval = 0.16
}

/// 标签管理更多按钮的竖向三点图标，用几何点阵规避 SF Symbol 名称在 Menu label 中解析为空的问题。
struct TagManagementMoreGlyph: View {
    let color: Color
    var dotSize: CGFloat = 3
    var dotSpacing: CGFloat = 2.5

    var body: some View {
        VStack(spacing: dotSpacing) {
            ForEach(0..<3, id: \.self) { _ in
                Circle()
                    .fill(color)
                    .frame(width: dotSize, height: dotSize)
            }
        }
        .accessibilityHidden(true)
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
                .lineLimit(1)
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                .layoutPriority(1)

            if shouldReserveTrailingAccessory {
                trailingAccessory
                    .transition(trailingSlotTransition)
            }
        }
        .padding(.leading, Spacing.tight)
        .padding(.trailing, shouldReserveTrailingAccessory ? Spacing.none : Spacing.tight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockSmall, style: .continuous)
                .stroke(Color.surfaceBorderSubtle, lineWidth: CardStyle.borderWidth)
        }
        .contextMenu {
            if shouldShowMoreButton {
                Button(action: onRename) {
                    XMMenuLabel("编辑", systemImage: "pencil")
                }
                Button(role: .destructive, action: onDelete) {
                    Label("删除", systemImage: "trash")
                }
            }
        }
        .xmMenuNeutralTint()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityAddTraits(isReordering ? AccessibilityTraits() : .isButton)
        .animation(modeAnimation, value: isSelectionMode)
        .animation(modeAnimation, value: isReordering)
        .animation(selectionAnimation, value: isSelected)
        .transaction { transaction in
            guard shouldReduceMotion else { return }
            transaction.disablesAnimations = true
            transaction.animation = nil
        }
    }

    private var trailingAccessory: some View {
        ZStack(alignment: .trailing) {
            if shouldShowReorderHandle {
                reorderHandle
                    .transition(accessorySwapTransition)
            }

            if shouldShowMoreButton {
                moreButton
                    .transition(accessorySwapTransition)
            }
        }
        .frame(
            width: TagManagementCollectionMetrics.menuHitWidth,
            height: TagManagementCollectionMetrics.menuHitHeight,
            alignment: .center
        )
    }

    private var reorderHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(AppTypography.subheadline)
            .foregroundStyle(Color.textSecondary)
            .frame(
                width: TagManagementCollectionMetrics.menuHitWidth,
                height: TagManagementCollectionMetrics.menuHitHeight,
                alignment: .center
            )
            .contentShape(Rectangle())
            .accessibilityHidden(true)
    }

    private var moreButton: some View {
        Menu {
            Button(action: onRename) {
                XMMenuLabel("编辑", systemImage: "pencil")
            }
            Button(role: .destructive, action: onDelete) {
                Label("删除", systemImage: "trash")
            }
        } label: {
            TagManagementMoreGlyph(color: Color.textSecondary, dotSize: 2.7, dotSpacing: 2.4)
                .frame(
                    width: TagManagementCollectionMetrics.menuHitWidth,
                    height: TagManagementCollectionMetrics.menuHitHeight,
                    alignment: .center
                )
                .contentShape(Rectangle())
        }
        .disabled(isDisabled)
        .xmMenuNeutralTint()
        .accessibilityLabel("标签操作")
        .accessibilityHint("打开编辑和删除操作")
    }

    private var shouldShowMoreButton: Bool {
        !isSelectionMode && !isReordering
    }

    private var shouldShowReorderHandle: Bool {
        isReordering
    }

    private var shouldReserveTrailingAccessory: Bool {
        !isSelectionMode
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

    private var accessorySwapTransition: AnyTransition {
        if shouldReduceMotion {
            return .opacity
        }
        return .asymmetric(
            insertion: .opacity.combined(with: .offset(x: 6)),
            removal: .opacity.combined(with: .offset(x: -4))
        )
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
}
