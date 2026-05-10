/**
 * [INPUT]: 依赖 BookshelfItem/BookshelfDisplaySetting、BookRoute 与现有 SwiftUI 书架卡片，接收 BookGridView 注入的导航、选择、排序提交、底部滚动余量和底部栏滚动观察开关
 * [OUTPUT]: 对外提供 BookshelfDefaultCollectionView，使用 UIKit UICollectionView 承接默认书架滚动、整项长按拖拽排序、本地预览顺序与 iOS 26 底部边缘过渡
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
    let showsNoteCount: Bool
    let titleDisplayMode: BookshelfTitleDisplayMode
    let allowsStructuralAnimation: Bool
    let isEditing: Bool
    let bottomContentInset: CGFloat
    let selectedIDs: Set<BookshelfItemID>
    let canReorder: Bool
    let isScrollObservationEnabled: Bool
    let activeWriteAction: BookshelfPendingAction?
    let movableIDs: Set<BookshelfItemID>
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
            showsNoteCount: showsNoteCount,
            titleDisplayMode: titleDisplayMode,
            allowsStructuralAnimation: allowsStructuralAnimation,
            isEditing: isEditing,
            bottomContentInset: bottomContentInset,
            selectedIDs: selectedIDs,
            canReorder: canReorder,
            isScrollObservationEnabled: isScrollObservationEnabled,
            activeWriteAction: activeWriteAction,
            movableIDs: movableIDs,
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
    let showsNoteCount: Bool
    let titleDisplayMode: BookshelfTitleDisplayMode
    let allowsStructuralAnimation: Bool
    let isEditing: Bool
    let bottomContentInset: CGFloat
    let selectedIDs: Set<BookshelfItemID>
    let canReorder: Bool
    let isScrollObservationEnabled: Bool
    let activeWriteAction: BookshelfPendingAction?
    let movableIDs: Set<BookshelfItemID>
    let onOpenRoute: (BookRoute) -> Void
    let onToggleSelection: (BookshelfItemID) -> Void
    let onEnterEditing: (BookshelfItemID) -> Void
    let onPin: (BookshelfItemID) -> Void
    let onUnpin: (BookshelfItemID) -> Void
    let onMoveToStart: (BookshelfItemID) -> Void
    let onMoveToEnd: (BookshelfItemID) -> Void
    let onContextAction: (BookshelfBookContextAction, BookshelfItemID) -> Void
    let onCommitOrder: ([BookshelfItemID]) -> Void

    static let empty = BookshelfDefaultCollectionConfiguration(
        sections: [],
        layoutMode: .grid,
        columnCount: 3,
        showsNoteCount: true,
        titleDisplayMode: .standard,
        allowsStructuralAnimation: true,
        isEditing: false,
        bottomContentInset: 0,
        selectedIDs: [],
        canReorder: false,
        isScrollObservationEnabled: false,
        activeWriteAction: nil,
        movableIDs: [],
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

/// 默认书架集合视图子类，暴露系统 automatic inset 与布局周期变化给承载层做视口锚点恢复。
private final class BookshelfDefaultViewportStableCollectionView: UICollectionView {
    var onAdjustedContentInsetDidChange: (() -> Void)?
    var onBeforeLayoutSubviews: (() -> Void)?

    /// 布局前让承载层保存当前可见锚点，避免后续系统 inset 调整只能捕获到跳变后的状态。
    override func layoutSubviews() {
        onBeforeLayoutSubviews?()
        super.layoutSubviews()
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
    private weak var observedContentScrollController: UIViewController?
    private let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let selectionFeedback = UISelectionFeedbackGenerator()

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
            BookshelfDefaultSectionHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: BookshelfDefaultSectionHeaderView.reuseIdentifier
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

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateContentScrollObservation()
    }

    /// 同步 SwiftUI 传入状态；拖拽中保留 UIKit 本地顺序，避免每帧被外部 snapshot 打断。
    fileprivate func update(with configuration: BookshelfDefaultCollectionConfiguration, animated: Bool) {
        if isInteractiveReordering {
            pendingConfiguration = configuration
            return
        }

        storeViewportAnchorIfPossible(requiresLayout: true)
        let previousIDs = items.map(\.id)
        let nextItems = configuration.sections.flatMap(\.items)
        let nextIDs = nextItems.map(\.id)
        let canAnimateStructuralDiff = self.configuration.sections.count == 1
            && configuration.sections.count == 1
        let needsLayoutUpdate = self.configuration.layoutMode != configuration.layoutMode
            || self.configuration.columnCount != configuration.columnCount
            || self.configuration.titleDisplayMode != configuration.titleDisplayMode
            || self.configuration.sections.map(\.id) != configuration.sections.map(\.id)

        self.configuration = configuration
        sections = configuration.sections
        collectionView.dragInteractionEnabled = configuration.canReorder
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

        if previousIDs == nextIDs {
            items = nextItems
            refreshVisibleCells()
            return
        }

        let applied = canAnimateStructuralDiff
            && applyStructuralDiffUpdate(
                from: previousIDs,
                to: nextIDs,
                nextItems: nextItems,
                animated: shouldAnimateStructuralChange
            )
        if !applied {
            items = nextItems
            collectionView.reloadData()
        }
    }

    /// 释放拖拽与缓存状态，供 SwiftUI 销毁承载视图时调用。
    func prepareForReuse() {
        clearContentScrollObservation()
        pendingConfiguration = nil
        sections = []
        items = []
        originalItemsBeforeDrag = []
        isInteractiveReordering = false
        didChangeOrderInCurrentSession = false
        didReceiveDropInCurrentSession = false
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

    /// 按当前展示模式构建 CompositionalLayout，Grid 和 List 共用同一个集合承载。
    func makeLayout(for configuration: BookshelfDefaultCollectionConfiguration) -> UICollectionViewLayout {
        UICollectionViewCompositionalLayout { sectionIndex, _ in
            let section: NSCollectionLayoutSection
            switch configuration.layoutMode {
            case .grid:
                section = Self.makeGridSection(
                    columnCount: configuration.columnCount
                )
            case .list:
                section = Self.makeListSection()
            }
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

    /// 只增加滚动余量，不改变 collection layout，避免编辑工具栏入场时书籍网格重新排版。
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

    /// 保存当前稳定视口锚点。该方法可在滚动、SwiftUI update 和 UIKit 布局周期中高频调用，因此只做轻量可见 cell 采样。
    func storeViewportAnchorIfPossible(requiresLayout: Bool) {
        guard !isRestoringViewport, !isViewportAnchorCaptureSuspended else { return }
        stableFallbackOffsetY = collectionView.contentOffset.y
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

    /// Grid 模式使用动态列数和估算高度，交由 UIHostingConfiguration 自适应卡片内容。
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

    /// 绑定 cell 内容，仍复用现有 SwiftUI 书籍、分组与列表行组件。
    func configureCell(_ cell: BookshelfDefaultCollectionCell, at indexPath: IndexPath) {
        guard let item = item(at: indexPath) else { return }
        cell.configure(
            with: BookshelfDefaultCollectionCellContent(
                item: item,
                layoutMode: configuration.layoutMode,
                showsNoteCount: configuration.showsNoteCount,
                titleDisplayMode: configuration.titleDisplayMode,
                isEditing: configuration.isEditing,
                isSelected: configuration.selectedIDs.contains(item.id),
                canMove: configuration.movableIDs.contains(item.id),
                activeWriteAction: configuration.activeWriteAction,
                onContextAction: configuration.onContextAction
            )
        )
    }

    func item(at indexPath: IndexPath) -> BookshelfItem? {
        guard sections.indices.contains(indexPath.section),
              sections[indexPath.section].items.indices.contains(indexPath.item) else {
            return nil
        }
        return sections[indexPath.section].items[indexPath.item]
    }

    /// 外部结构变化转换为批量更新动画；不适合动画时由调用方回退 reloadData。
    func applyStructuralDiffUpdate(
        from previousIDs: [BookshelfItemID],
        to nextIDs: [BookshelfItemID],
        nextItems: [BookshelfItem],
        animated: Bool
    ) -> Bool {
        guard animated,
              Set(previousIDs).count == previousIDs.count,
              Set(nextIDs).count == nextIDs.count else {
            return false
        }

        let diff = nextIDs.difference(from: previousIDs).inferringMoves()
        var deletions: [IndexPath] = []
        var insertions: [IndexPath] = []
        var moves: [(from: IndexPath, to: IndexPath)] = []

        for change in diff {
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
            return false
        }

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
            self?.refreshVisibleCells()
        }
        return true
    }

    /// 判断指定位置是否允许启动排序；置顶项和非排序态始终返回 false。
    func canBeginReorder(at indexPath: IndexPath) -> Bool {
        guard configuration.canReorder,
              indexPath.section == 0,
              items.indices.contains(indexPath.item) else {
            return false
        }
        return !items[indexPath.item].pinned
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
        var proposedItem = proposed?.item ?? (items.count - 1)
        proposedItem = min(max(lowerBound, proposedItem), items.count - 1)

        if let movingItemID,
           let sourceIndex = items.firstIndex(where: { $0.id == movingItemID }),
           items[sourceIndex].pinned {
            return IndexPath(item: sourceIndex, section: 0)
        }
        return IndexPath(item: proposedItem, section: 0)
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
        sections.count
    }

    /// 返回默认书架当前可见顶层条目数量。
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        sections.indices.contains(section) ? sections[section].items.count : 0
    }

    /// 配置默认书架 cell 的 SwiftUI 内容。
    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
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
              sections.indices.contains(indexPath.section),
              let title = sections[indexPath.section].title else {
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
        guard let destination = normalizedDestinationIndexPath(
            for: destinationIndexPath,
            movingItemID: items.indices.contains(sourceIndexPath.item) ? items[sourceIndexPath.item].id : nil
        ) else {
            return
        }
        applyLocalMove(from: sourceIndexPath.item, to: destination.item)
    }
}

extension BookshelfDefaultCollectionHostView: UICollectionViewDelegate {
    /// 用户或系统滚动后刷新稳定锚点，为后续 safe area / inset 变化保留恢复基准。
    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        storeViewportAnchorIfPossible(requiresLayout: false)
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
        normalizedDestinationIndexPath(
            for: proposedIndexPath,
            movingItemID: items.indices.contains(originalIndexPath.item) ? items[originalIndexPath.item].id : nil
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
              items.indices.contains(indexPath.item) else {
            return []
        }
        beginReorderSession(at: indexPath)
        let itemID = items[indexPath.item].id
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
                    at: IndexPath(item: sourceIndex, section: 0),
                    to: destination
                )
            } completion: { [weak self] _ in
                self?.selectionFeedback.selectionChanged()
            }
        }
        coordinator.drop(dropItem.dragItem, toItemAt: destination)
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
    let isEditing: Bool
    let isSelected: Bool
    let canMove: Bool
    let activeWriteAction: BookshelfPendingAction?
    let onContextAction: (BookshelfBookContextAction, BookshelfItemID) -> Void

    var body: some View {
        itemLabel
            .modifier(BookshelfDefaultCollectionSelectionModifier(
                isEditing: isEditing,
                isSelected: isSelected
            ))
            .contextMenu {
                contextMenu
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(accessibilityLabel)
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
                    titleDisplayMode: titleDisplayMode
                )
            case .group(let group):
                BookshelfGroupGridItemView(
                    group: group,
                    isPinned: item.pinned,
                    titleDisplayMode: titleDisplayMode
                )
            }
        case .list:
            BookshelfDefaultListRow(
                item: item,
                showsNoteCount: showsNoteCount,
                titleDisplayMode: titleDisplayMode
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
                Label("添加笔记", systemImage: "square.and.pencil")
            }

            pinMenuButton

            Button {
                onContextAction(.editBook, item.id)
            } label: {
                Label("编辑书籍", systemImage: "pencil")
            }

            Button {
                onContextAction(.showReadingDetail, item.id)
            } label: {
                Label("阅读详情", systemImage: "chart.bar.doc.horizontal")
            }

            Button {
                onContextAction(.startReadTiming, item.id)
            } label: {
                Label("开始计时", systemImage: "timer")
            }

            Button {
                onContextAction(.organizeBooks, item.id)
            } label: {
                Label("整理书籍", systemImage: "square.grid.2x2")
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
                Label("整理书籍", systemImage: "square.grid.2x2")
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
                Label("取消置顶", systemImage: "pin.slash")
            }
            .disabled(activeWriteAction != nil)
        } else {
            Button {
                onContextAction(.pin, item.id)
            } label: {
                Label("置顶", systemImage: "pin")
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
}

/// 编辑态选中外观，复用旧 SwiftUI 路径中的选择勾选与边框反馈。
private struct BookshelfDefaultCollectionSelectionModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let isEditing: Bool
    let isSelected: Bool

    func body(content: Content) -> some View {
        content
            .opacity(isEditing ? (isSelected ? 1 : 0.92) : 1)
            .overlay(alignment: .topTrailing) {
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
