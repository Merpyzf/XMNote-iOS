/**
 * [INPUT]: 依赖 TagManagementItem/TagManagementScope、XMSelectionIndicator 与页面传入的标签操作回调，承接标签管理页的两列展示与本地拖拽排序
 * [OUTPUT]: 对外提供 TagManagementCollectionView，封装页面私有 UICollectionView bridge、两列布局、选择态与排序态
 * [POS]: Views/Personal/Components 的标签管理页面私有集合组件，被 TagManagementView 用作标签主体内容区
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 标签管理两列集合视图，负责普通态、选择态和排序态的布局与本地拖拽预览。
struct TagManagementCollectionView: UIViewRepresentable {
    let items: [TagManagementItem]
    let scope: TagManagementScope
    let isSelectionMode: Bool
    let isReordering: Bool
    let selectedTagIDs: Set<Int64>
    let isDisabled: Bool
    let bottomContentInset: CGFloat
    let onPrimaryAction: (TagManagementItem) -> Void
    let onRename: (TagManagementItem) -> Void
    let onDelete: (TagManagementItem) -> Void
    let onCommitOrder: ([Int64]) -> Void

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
            isSelectionMode: isSelectionMode,
            isReordering: isReordering,
            selectedTagIDs: selectedTagIDs,
            isDisabled: isDisabled,
            bottomContentInset: bottomContentInset,
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
        let needsLayoutUpdate = abs(previousConfiguration.itemHeight - configuration.itemHeight) > 0.5
        self.configuration = configuration
        items = configuration.items
        collectionView.dragInteractionEnabled = configuration.canReorder
        collectionView.isUserInteractionEnabled = !configuration.isDisabled || configuration.canReorder
        updateBottomContentInset()

        if needsLayoutUpdate {
            collectionView.setCollectionViewLayout(
                makeLayout(for: configuration),
                animated: animated && collectionView.window != nil
            )
        }

        UIView.performWithoutAnimation {
            collectionView.reloadData()
        }
    }

    /// 清理拖拽缓存，供 SwiftUI 销毁或复用承载视图时恢复稳定状态。
    func prepareForReuse() {
        pendingConfiguration = nil
        originalItemsBeforeDrag = []
        isInteractiveReordering = false
        didChangeOrderInCurrentSession = false
        didReceiveDropInCurrentSession = false
        items = []
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

    /// 同步底部操作栏占位，避免选择态底部内容被遮挡。
    func updateBottomContentInset() {
        guard abs(collectionView.contentInset.bottom - configuration.bottomContentInset) > 0.5 else { return }
        collectionView.contentInset.bottom = configuration.bottomContentInset
        collectionView.verticalScrollIndicatorInsets.bottom = configuration.bottomContentInset
    }

    /// 读取指定位置的标签项。
    func item(at indexPath: IndexPath) -> TagManagementItem? {
        guard indexPath.section == 0, items.indices.contains(indexPath.item) else { return nil }
        return items[indexPath.item]
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
            items = originalItemsBeforeDrag
            collectionView.reloadData()
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
        ) as? TagManagementCollectionCell,
              let item = item(at: indexPath) else {
            return UICollectionViewCell()
        }

        cell.configure(with: item, configuration: configuration)
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
    let isSelectionMode: Bool
    let isReordering: Bool
    let selectedTagIDs: Set<Int64>
    let isDisabled: Bool
    let bottomContentInset: CGFloat
    let onPrimaryAction: (TagManagementItem) -> Void
    let onRename: (TagManagementItem) -> Void
    let onDelete: (TagManagementItem) -> Void
    let onCommitOrder: ([Int64]) -> Void

    var canReorder: Bool {
        isReordering && !isDisabled && items.count > 1
    }

    var itemHeight: CGFloat {
        isSelectionMode ? TagManagementCollectionMetrics.selectionItemHeight : TagManagementCollectionMetrics.normalItemHeight
    }

    static let empty = TagManagementCollectionConfiguration(
        items: [],
        scope: .note,
        isSelectionMode: false,
        isReordering: false,
        selectedTagIDs: [],
        isDisabled: false,
        bottomContentInset: 0,
        onPrimaryAction: { _ in },
        onRename: { _ in },
        onDelete: { _ in },
        onCommitOrder: { _ in }
    )
}

private enum TagManagementCollectionMetrics {
    static let columnCount = 2
    static let normalItemHeight: CGFloat = 56
    static let selectionItemHeight: CGFloat = 74
    static let horizontalInset: CGFloat = Spacing.screenEdge
    static let topInset: CGFloat = Spacing.base
    static let bottomInset: CGFloat = Spacing.double
    static let itemHorizontalGap: CGFloat = Spacing.tight
    static let rowSpacing: CGFloat = Spacing.tight
    static let menuHitWidth: CGFloat = 30
    static let menuHitHeight: CGFloat = 44
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
        configuration: TagManagementCollectionConfiguration
    ) {
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        contentConfiguration = nil
        contentConfiguration = UIHostingConfiguration {
            TagManagementCollectionItemView(
                item: item,
                scope: configuration.scope,
                isSelectionMode: configuration.isSelectionMode,
                isSelected: configuration.selectedTagIDs.contains(item.id),
                isReordering: configuration.isReordering,
                isDisabled: configuration.isDisabled,
                onRename: { configuration.onRename(item) },
                onDelete: { configuration.onDelete(item) }
            )
        }
        .margins(.all, 0)
    }
}

private struct TagManagementCollectionItemView: View {
    let item: TagManagementItem
    let scope: TagManagementScope
    let isSelectionMode: Bool
    let isSelected: Bool
    let isReordering: Bool
    let isDisabled: Bool
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
                .transition(.scale.combined(with: .opacity))
            }

            VStack(alignment: .leading, spacing: Spacing.tiny) {
                Text(item.name)
                    .font(AppTypography.subheadlineMedium)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .layoutPriority(1)

                if isSelectionMode {
                    Text(associatedText)
                        .font(AppTypography.caption)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.82)
                        .transition(.opacity)
                }
            }
            .layoutPriority(1)

            if shouldShowMoreButton {
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
                            height: TagManagementCollectionMetrics.menuHitHeight
                        )
                        .contentShape(Rectangle())
                }
                .disabled(isDisabled)
                .xmMenuNeutralTint()
                .accessibilityLabel("标签操作")
            }
        }
        .padding(.horizontal, Spacing.tight)
        .padding(.vertical, Spacing.tight)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Color.surfaceCard, in: RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
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
    }

    private var shouldShowMoreButton: Bool {
        !isSelectionMode && !isReordering
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
        return item.name
    }
}
