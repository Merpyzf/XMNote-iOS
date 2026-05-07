/**
 * [INPUT]: 依赖 BookshelfAggregateGroup、BookshelfDisplaySetting 与 BookRoute，接收 BookGridView 注入的导航和聚合排序提交闭包
 * [OUTPUT]: 对外提供 BookshelfAggregateCollectionView，使用 UIKit UICollectionView 承接非默认维度聚合入口滚动、Grid/List 布局与可选排序
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

/// 非默认维度聚合入口集合区，保留 SwiftUI 卡片视觉，同时由 UICollectionView 承接滚动与排序。
struct BookshelfAggregateCollectionView: UIViewRepresentable {
    let sections: [BookshelfAggregateCollectionSection]
    let layoutMode: BookshelfLayoutMode
    let columnCount: Int
    let canReorder: Bool
    let onOpenRoute: (BookRoute) -> Void
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
            canReorder: canReorder && sections.count == 1,
            onOpenRoute: onOpenRoute,
            onCommitOrder: onCommitOrder
        )
    }
}

/// UIKit 聚合集合区输入配置。
private struct BookshelfAggregateCollectionConfiguration {
    let sections: [BookshelfAggregateCollectionSection]
    let layoutMode: BookshelfLayoutMode
    let columnCount: Int
    let canReorder: Bool
    let onOpenRoute: (BookRoute) -> Void
    let onCommitOrder: ([Int64]) -> Void

    static let empty = BookshelfAggregateCollectionConfiguration(
        sections: [],
        layoutMode: .grid,
        columnCount: 2,
        canReorder: false,
        onOpenRoute: { _ in },
        onCommitOrder: { _ in }
    )
}

/// UICollectionView 承载视图，负责聚合卡片布局和本地排序预览。
final class BookshelfAggregateCollectionHostView: UIView {
    private var configuration = BookshelfAggregateCollectionConfiguration.empty
    private var sections: [BookshelfAggregateCollectionSection] = []
    private var didChangeOrderInCurrentSession = false
    private let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let selectionFeedback = UISelectionFeedbackGenerator()

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
            BookshelfAggregateHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: BookshelfAggregateHeaderView.reuseIdentifier
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

    /// 同步聚合列表配置。
    fileprivate func update(with configuration: BookshelfAggregateCollectionConfiguration, animated: Bool) {
        let needsLayoutUpdate = self.configuration.layoutMode != configuration.layoutMode
            || self.configuration.columnCount != configuration.columnCount
            || self.configuration.sections.map(\.id) != configuration.sections.map(\.id)

        self.configuration = configuration
        sections = configuration.sections
        collectionView.dragInteractionEnabled = configuration.canReorder

        if needsLayoutUpdate {
            collectionView.setCollectionViewLayout(makeLayout(for: configuration), animated: animated)
        }
        collectionView.reloadData()
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

    /// 根据 Grid/List 模式构建布局。
    func makeLayout(for configuration: BookshelfAggregateCollectionConfiguration) -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { sectionIndex, _ in
            let columns = configuration.layoutMode == .grid ? max(2, configuration.columnCount) : 1
            let itemSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(configuration.layoutMode == .grid ? 176 : 116)
            )
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            let groupSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(configuration.layoutMode == .grid ? 176 : 116)
            )
            let group = NSCollectionLayoutGroup.horizontal(
                layoutSize: groupSize,
                repeatingSubitem: item,
                count: columns
            )
            group.interItemSpacing = .fixed(Spacing.base)

            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = Spacing.base
            section.contentInsets = NSDirectionalEdgeInsets(
                top: Spacing.base,
                leading: Spacing.screenEdge,
                bottom: Spacing.base,
                trailing: Spacing.screenEdge
            )

            if configuration.sections.indices.contains(sectionIndex),
               configuration.sections[sectionIndex].title != nil {
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

    func group(at indexPath: IndexPath) -> BookshelfAggregateGroup? {
        guard sections.indices.contains(indexPath.section),
              sections[indexPath.section].groups.indices.contains(indexPath.item) else {
            return nil
        }
        return sections[indexPath.section].groups[indexPath.item]
    }

    func canMoveItem(at indexPath: IndexPath) -> Bool {
        configuration.canReorder && group(at: indexPath)?.orderID != nil
    }

    func reorder(from source: IndexPath, to proposedDestination: IndexPath) -> IndexPath? {
        guard source.section == proposedDestination.section,
              sections.indices.contains(source.section),
              canMoveItem(at: source) else {
            return nil
        }
        var groups = sections[source.section].groups
        guard groups.indices.contains(source.item) else { return nil }

        let firstMovableIndex = groups.firstIndex { $0.orderID != nil } ?? 0
        let destinationItem = max(firstMovableIndex, min(proposedDestination.item, groups.count - 1))
        guard destinationItem != source.item else {
            return IndexPath(item: destinationItem, section: source.section)
        }

        let moved = groups.remove(at: source.item)
        groups.insert(moved, at: destinationItem)
        sections[source.section] = BookshelfAggregateCollectionSection(
            id: sections[source.section].id,
            title: sections[source.section].title,
            groups: groups
        )
        didChangeOrderInCurrentSession = true
        selectionFeedback.selectionChanged()
        return IndexPath(item: destinationItem, section: source.section)
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
        sections.count
    }

    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        sections.indices.contains(section) ? sections[section].groups.count : 0
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: BookshelfAggregateCollectionCell.reuseIdentifier,
            for: indexPath
        ) as? BookshelfAggregateCollectionCell,
              let group = group(at: indexPath) else {
            return UICollectionViewCell()
        }
        cell.configure(group: group)
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
              sections.indices.contains(indexPath.section),
              let title = sections[indexPath.section].title else {
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
        guard originalIndexPath.section == proposedIndexPath.section,
              sections.indices.contains(originalIndexPath.section) else {
            return originalIndexPath
        }
        let groups = sections[originalIndexPath.section].groups
        let firstMovableIndex = groups.firstIndex { $0.orderID != nil } ?? 0
        let clampedItem = max(firstMovableIndex, min(proposedIndexPath.item, groups.count - 1))
        return IndexPath(item: clampedItem, section: originalIndexPath.section)
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

/// 聚合卡 cell，使用 UIHostingConfiguration 复用 SwiftUI 卡片视觉。
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

    /// 渲染聚合卡片。
    func configure(group: BookshelfAggregateGroup) {
        contentConfiguration = UIHostingConfiguration {
            BookshelfAggregateCardView(group: group)
        }
        .margins(.all, 0)
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
