/**
 * [INPUT]: 依赖 DataImportTaskDestination、UserDefaults、UIKit interactive movement、XMSystemScrollEdgeRegistration，以及 XMNote 设计系统令牌
 * [OUTPUT]: 对外提供书摘导入分组模型、兼容旧设置的排序存储，以及支持系统上下滚动边缘过渡和单一视觉载体排序的 DataImportCollectionView
 * [POS]: Views/Personal/DataImport 的主页排序与视觉承载层，SwiftUI 持有业务状态，UIKit 仅管理可中断拖拽交互
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit

/// 书摘导入主页可持久化的四个业务分组标识。
enum DataImportGroupID: String, CaseIterable, Hashable {
    case quick
    case api
    case file
    case clipboard
}

/// 单个可启动的导入入口，稳定 ID 同时用于旧版顺序兼容与 UIKit 拖拽定位。
struct DataImportEntry: Identifiable {
    let id: String
    let title: LocalizedStringResource
    let destination: DataImportTaskDestination
}

/// 书摘导入业务分组，分组移动时完整携带其内部已排序条目。
struct DataImportGroup: Identifiable {
    let id: DataImportGroupID
    let title: LocalizedStringResource
    var entries: [DataImportEntry]
}

/// 书摘导入顺序存储，过滤失效 ID、保留已有偏好，并将新入口追加到默认位置之后。
enum DataImportOrderingStore {
    private static let groupOrderKey = "noteImportGroupOrder"
    private static let quickOrderKey = "noteImportQuickOrder"
    private static let fileOrderKey = "noteImportFileOrder"
    private static let clipboardOrderKey = "noteImportClipboardOrder"

    /// 读取分组及条目顺序；没有旧值的新用户采用与 Android 业务意图一致的快捷导入顺序。
    static func loadGroups(userDefaults: UserDefaults = .standard) -> [DataImportGroup] {
        let groups = defaultGroups.map { group in
            guard let orderKey = entryOrderKey(for: group.id) else { return group }
            let savedIDs = userDefaults.stringArray(forKey: orderKey) ?? []
            let normalizedIDs = normalizedOrder(
                savedIDs,
                availableIDs: group.entries.map(\.id)
            )
            let entryByID = Dictionary(uniqueKeysWithValues: group.entries.map { ($0.id, $0) })
            return DataImportGroup(
                id: group.id,
                title: group.title,
                entries: normalizedIDs.compactMap { entryByID[$0] }
            )
        }

        let savedGroupIDs = (userDefaults.stringArray(forKey: groupOrderKey) ?? [])
            .compactMap(DataImportGroupID.init(rawValue:))
        let normalizedGroupIDs = normalizedOrder(
            savedGroupIDs,
            availableIDs: groups.map(\.id)
        )
        let groupByID = Dictionary(uniqueKeysWithValues: groups.map { ($0.id, $0) })
        return normalizedGroupIDs.compactMap { groupByID[$0] }
    }

    /// 保存全部分组的最终顺序，不写入拖动过程中的预览状态。
    static func saveGroupOrder(
        _ orderedIDs: [DataImportGroupID],
        userDefaults: UserDefaults = .standard
    ) {
        userDefaults.set(orderedIDs.map(\.rawValue), forKey: groupOrderKey)
    }

    /// 保存指定分组内的最终条目顺序；单项 API 分组不产生无意义设置项。
    static func saveEntryOrder(
        _ orderedIDs: [String],
        for groupID: DataImportGroupID,
        userDefaults: UserDefaults = .standard
    ) {
        guard let orderKey = entryOrderKey(for: groupID) else { return }
        userDefaults.set(orderedIDs, forKey: orderKey)
    }

    /// 对已保存顺序执行去重、失效过滤与新增默认项补齐。
    private static func normalizedOrder<ID: Hashable>(
        _ savedIDs: [ID],
        availableIDs: [ID]
    ) -> [ID] {
        let availableIDSet = Set(availableIDs)
        var seenIDs: Set<ID> = []
        let validSavedIDs = savedIDs.filter { id in
            availableIDSet.contains(id) && seenIDs.insert(id).inserted
        }
        return validSavedIDs + availableIDs.filter { !seenIDs.contains($0) }
    }

    /// 返回允许持久化组内顺序的旧版设置键，保持升级用户偏好不丢失。
    private static func entryOrderKey(for groupID: DataImportGroupID) -> String? {
        switch groupID {
        case .quick:
            quickOrderKey
        case .api:
            nil
        case .file:
            fileOrderKey
        case .clipboard:
            clipboardOrderKey
        }
    }

    private static let defaultGroups: [DataImportGroup] = [
        DataImportGroup(
            id: .quick,
            title: "快捷导入",
            entries: [
                DataImportEntry(id: "computer", title: "从电脑导入", destination: .desktopComputer),
                DataImportEntry(id: "weread-auth", title: "微信读书授权导入", destination: .wereadAuthorization),
                DataImportEntry(id: "lifeweek", title: "三联生活周刊", destination: .lifeWeek)
            ]
        ),
        DataImportGroup(
            id: .api,
            title: "API 导入",
            entries: [
                DataImportEntry(id: "api", title: "API 导入", destination: .api)
            ]
        ),
        DataImportGroup(
            id: .file,
            title: "本地文件",
            entries: [
                DataImportEntry(id: "kindle", title: "Kindle", destination: .kindle),
                DataImportEntry(id: "koreader", title: "KOReader", destination: .file(title: "KOReader", parserID: .koreader)),
                DataImportEntry(id: "boox", title: "BOOX", destination: .fileCandidates(title: "BOOX", parserIDs: [.booxOld, .booxNew])),
                DataImportEntry(id: "legado", title: "阅读", destination: .file(title: "阅读", parserID: .legado)),
                DataImportEntry(id: "apple-books", title: "Apple Books", destination: .file(title: "Apple Books", parserID: .appleBooks)),
                DataImportEntry(id: "douban-read", title: "豆瓣阅读", destination: .file(title: "豆瓣阅读", parserID: .doubanRead)),
                DataImportEntry(id: "jd-reader", title: "京东读书", destination: .file(title: "京东读书", parserID: .jdReader)),
                DataImportEntry(id: "ireader-file", title: "掌阅", destination: .file(title: "掌阅", parserID: .ireaderFile)),
                DataImportEntry(id: "ireader-epub", title: "iReader 笔记成书", destination: .file(title: "iReader 笔记成书", parserID: .ireaderEpub)),
                DataImportEntry(id: "neat", title: "Neat Reader", destination: .file(title: "Neat Reader", parserID: .neatReader)),
                DataImportEntry(id: "koodo", title: "Koodo Reader", destination: .file(title: "Koodo Reader", parserID: .koodo)),
                DataImportEntry(id: "hanwang", title: "汉王", destination: .hanwang),
                DataImportEntry(id: "dimo", title: "滴墨", destination: .file(title: "滴墨", parserID: .dimo)),
                DataImportEntry(id: "reeden", title: "Reeden", destination: .file(title: "Reeden", parserID: .reeden))
            ]
        ),
        DataImportGroup(
            id: .clipboard,
            title: "剪贴板",
            entries: [
                DataImportEntry(id: "weread-clipboard", title: "微信读书", destination: .clipboardCandidates(title: "微信读书", parserIDs: [.wereadOld, .wereadPre830, .weread830])),
                DataImportEntry(id: "dedao", title: "得到", destination: .clipboard(title: "得到", parserID: .dedao)),
                DataImportEntry(id: "ireader-selected", title: "掌阅精选", destination: .clipboard(title: "掌阅精选", parserID: .ireaderSelected)),
                DataImportEntry(id: "moon", title: "静读天下", destination: .clipboard(title: "静读天下", parserID: .moonReader)),
                DataImportEntry(id: "duokan", title: "多看", destination: .clipboard(title: "多看", parserID: .duokan)),
                DataImportEntry(id: "dangdang", title: "当当", destination: .clipboard(title: "当当", parserID: .dangdang)),
                DataImportEntry(id: "douban-app", title: "豆瓣阅读 App", destination: .clipboard(title: "豆瓣阅读 App", parserID: .doubanApp)),
                DataImportEntry(id: "reader163", title: "网易蜗牛", destination: .clipboard(title: "网易蜗牛", parserID: .reader163)),
                DataImportEntry(id: "fanqie", title: "番茄小说", destination: .clipboard(title: "番茄小说", parserID: .fanqie)),
                DataImportEntry(id: "readingo", title: "Readingo", destination: .clipboard(title: "Readingo", parserID: .readingo))
            ]
        )
    ]
}

/// SwiftUI 到 UIKit 的页面私有桥接层，导航与最终排序仍由 SwiftUI 作为唯一业务 owner。
struct DataImportCollectionView: UIViewRepresentable {
    let groups: [DataImportGroup]
    let isEditing: Bool
    let reducesMotion: Bool
    let onOpen: (DataImportTaskDestination) -> Void
    let onCommitGroupOrder: ([DataImportGroupID]) -> Void
    let onCommitEntryOrder: (DataImportGroupID, [String]) -> Void

    /// 创建承载两级排序的 UIKit 集合视图。
    func makeUIView(context: Context) -> DataImportCollectionHostView {
        let collectionView = DataImportCollectionHostView()
        collectionView.update(with: configuration, animated: false)
        return collectionView
    }

    /// 将 SwiftUI 的编辑状态、动态设置与最终业务数据同步到 UIKit。
    func updateUIView(_ uiView: DataImportCollectionHostView, context: Context) {
        uiView.update(with: configuration, animated: true)
    }

    /// 销毁桥接层时取消本地预览状态，避免未完成拖拽泄漏到下一次展示。
    static func dismantleUIView(_ uiView: DataImportCollectionHostView, coordinator: ()) {
        uiView.prepareForReuse()
    }

    private var configuration: DataImportCollectionConfiguration {
        DataImportCollectionConfiguration(
            groups: groups,
            isEditing: isEditing,
            reducesMotion: reducesMotion,
            onOpen: onOpen,
            onCommitGroupOrder: onCommitGroupOrder,
            onCommitEntryOrder: onCommitEntryOrder
        )
    }
}

/// UIKit 排序交互的显式状态机，避免收起、移动、落位和恢复相互抢写。
private enum DataImportReorderInteractionState: Equatable {
    case normal
    case editingExpanded
    case preparingGroupDrag(DataImportGroupID)
    case draggingGroup(DataImportGroupID)
    case settlingGroup
}

/// 结构变化期间的视觉阶段；持续到属性动画收口，供复用与 willDisplay 恢复正确中间态。
private enum DataImportVisualTransitionPhase: Equatable {
    case idle
    case departingEntries(DataImportGroupID)
    case collapsing(DataImportGroupID)
    case reordering(DataImportGroupID)
    case expanding(DataImportGroupID)

    var sourceCompactProgress: CGFloat {
        switch self {
        case .idle, .departingEntries, .collapsing:
            0
        case .reordering, .expanding:
            1
        }
    }

    var targetCompactProgress: CGFloat {
        switch self {
        case .idle, .departingEntries, .expanding:
            0
        case .collapsing, .reordering:
            1
        }
    }
}

/// 本地拖拽载荷，严格区分分组与条目两种互斥会话。
private enum DataImportDragPayload: Hashable {
    case group(DataImportGroupID)
    case entry(groupID: DataImportGroupID, entryID: String)
}

/// 集合视图内部的稳定项目标识；每个 section 的首项代表可拖动分组标题。
private enum DataImportCollectionItemID: Hashable {
    case group(DataImportGroupID)
    case entry(groupID: DataImportGroupID, entryID: String)
}

/// SwiftUI 传入的不可变页面快照与业务回调集合。
private struct DataImportCollectionConfiguration {
    let groups: [DataImportGroup]
    let isEditing: Bool
    let reducesMotion: Bool
    let onOpen: (DataImportTaskDestination) -> Void
    let onCommitGroupOrder: ([DataImportGroupID]) -> Void
    let onCommitEntryOrder: (DataImportGroupID, [String]) -> Void

    static let empty = DataImportCollectionConfiguration(
        groups: [],
        isEditing: false,
        reducesMotion: false,
        onOpen: { _ in },
        onCommitGroupOrder: { _ in },
        onCommitEntryOrder: { _, _ in }
    )

    var dataSignature: [String] {
        groups.flatMap { group in
            ["group:\(group.id.rawValue)"]
                + group.entries.map { "entry:\(group.id.rawValue):\($0.id)" }
        }
    }

    /// 用本地已验证顺序替换业务数据，同时保留最新编辑态、动效偏好与回调身份。
    func replacingGroups(_ groups: [DataImportGroup]) -> DataImportCollectionConfiguration {
        DataImportCollectionConfiguration(
            groups: groups,
            isEditing: isEditing,
            reducesMotion: reducesMotion,
            onOpen: onOpen,
            onCommitGroupOrder: onCommitGroupOrder,
            onCommitEntryOrder: onCommitEntryOrder
        )
    }

    /// 只替换辅助功能动效偏好，拖拽期间仍保留当前业务快照与回调身份。
    func replacingReducedMotion(_ reducesMotion: Bool) -> DataImportCollectionConfiguration {
        DataImportCollectionConfiguration(
            groups: groups,
            isEditing: isEditing,
            reducesMotion: reducesMotion,
            onOpen: onOpen,
            onCommitGroupOrder: onCommitGroupOrder,
            onCommitEntryOrder: onCommitEntryOrder
        )
    }
}

/// 同一布局实例按状态重算 section 间距，避免收展时替换 layout 造成短暂无 cell 窗口。
private final class DataImportCollectionLayout: UICollectionViewCompositionalLayout {
    private final class State {
        var isCollapsed: Bool

        init(isCollapsed: Bool) {
            self.isCollapsed = isCollapsed
        }
    }

    private let layoutState: State

    init(isCollapsed: Bool = false) {
        let layoutState = State(isCollapsed: isCollapsed)
        self.layoutState = layoutState
        super.init { _, _ in
            let itemSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(DataImportCollectionMetrics.entryMinimumHeight)
            )
            let item = NSCollectionLayoutItem(layoutSize: itemSize)
            let groupSize = NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(DataImportCollectionMetrics.entryMinimumHeight)
            )
            let group = NSCollectionLayoutGroup.vertical(layoutSize: groupSize, subitems: [item])
            let section = NSCollectionLayoutSection(group: group)
            section.interGroupSpacing = 0
            section.contentInsets = NSDirectionalEdgeInsets(
                top: 0,
                leading: Spacing.screenEdge,
                bottom: layoutState.isCollapsed ? Spacing.cozy : Spacing.section,
                trailing: Spacing.screenEdge
            )
            return section
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 更新紧凑状态并让当前 layout 原位重算，不触发 layout 对象替换。
    func setEntriesCollapsed(_ isCollapsed: Bool) {
        guard layoutState.isCollapsed != isCollapsed else { return }
        layoutState.isCollapsed = isCollapsed
        invalidateLayout()
    }
}

/// 书摘导入主滚动视图；所有 UIKit 状态都由主线程隔离，分组排序以标题为连续锚点。
@MainActor
final class DataImportCollectionHostView: UICollectionView, UIGestureRecognizerDelegate {
    private var configuration = DataImportCollectionConfiguration.empty
    private var displayedGroups: [DataImportGroup] = []
    private var pendingConfiguration: DataImportCollectionConfiguration?
    private var originalGroupsBeforeDrag: [DataImportGroup] = []
    private var interactionState = DataImportReorderInteractionState.normal
    private var activePayload: DataImportDragPayload?
    private var areEntriesCollapsed = false
    private var isPerformingStructuralUpdate = false
    private var isInteractiveMovementActive = false
    private var latestReorderLocation: CGPoint?
    private var pendingGroupFinishCancelled: Bool?
    private var dragGeneration = UUID()
    private var groupDragAnchorScreenY: CGFloat?
    private weak var groupDragOverlayHost: UIView?
    private var groupDragProxy: DataImportGroupDragProxyView?
    private var groupDragTouchOffsetY: CGFloat = 0
    private var transitionAnimator: UIViewPropertyAnimator?
    private var visualTransitionPhase = DataImportVisualTransitionPhase.idle
    private var transitionStartingGroupFrames: [DataImportGroupID: CGRect] = [:]
    private var preparedTransitionCells: [DataImportCollectionItemID: ObjectIdentifier] = [:]
    private var lateCellAnimators: [ObjectIdentifier: UIViewPropertyAnimator] = [:]
    private var isFinishingGroupDragQuickly = false
    private var lastPreferredContentSizeCategory: UIContentSizeCategory?
    private var hasPendingContentSizeCategoryUpdate = false
    private var reorderPanGestureRecognizer: UIPanGestureRecognizer!
    private let systemScrollEdgeRegistration = XMSystemScrollEdgeRegistration(
        edges: [.top, .bottom]
    )

    convenience init() {
        self.init(frame: .zero, collectionViewLayout: Self.makeLayout())
    }

    override init(frame: CGRect, collectionViewLayout layout: UICollectionViewLayout) {
        super.init(frame: frame, collectionViewLayout: layout)
        backgroundColor = .clear
        alwaysBounceVertical = true
        showsVerticalScrollIndicator = false
        contentInsetAdjustmentBehavior = .always
        keyboardDismissMode = .onDrag
        reorderingCadence = .immediate
        dragInteractionEnabled = false
        dataSource = self
        delegate = self

        let reorderPanGestureRecognizer = UIPanGestureRecognizer(
            target: self,
            action: #selector(handleReorderPan(_:))
        )
        reorderPanGestureRecognizer.maximumNumberOfTouches = 1
        reorderPanGestureRecognizer.cancelsTouchesInView = true
        reorderPanGestureRecognizer.delegate = self
        addGestureRecognizer(reorderPanGestureRecognizer)
        panGestureRecognizer.require(toFail: reorderPanGestureRecognizer)
        self.reorderPanGestureRecognizer = reorderPanGestureRecognizer

        register(
            DataImportCollectionCell.self,
            forCellWithReuseIdentifier: DataImportCollectionCell.reuseIdentifier
        )
        accessibilityIdentifier = "personal.data-import.collection"
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 进入或离开页面层级时登记或释放系统栏的真实滚动主体。
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            systemScrollEdgeRegistration.invalidate()
        } else {
            systemScrollEdgeRegistration.update(scrollView: self)
        }
    }

    /// 编辑态仅让从 44pt 把手开始的纵向拖动进入排序，其他手势继续交给列表滚动。
    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === reorderPanGestureRecognizer else {
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        guard configuration.isEditing,
              activePayload == nil,
              !isPerformingStructuralUpdate,
              let pan = gestureRecognizer as? UIPanGestureRecognizer else {
            return false
        }

        let velocity = pan.velocity(in: self)
        guard abs(velocity.y) >= abs(velocity.x) else { return false }
        let startLocation = reorderStartLocation(for: pan)
        guard let indexPath = indexPathForItem(at: startLocation),
              let cell = cellForItem(at: indexPath) as? DataImportCollectionCell,
              cell.showsReorderHandle,
              isReorderHandleHit(for: cell, point: convert(startLocation, to: cell)),
              let itemID = itemID(at: indexPath) else {
            return false
        }

        switch itemID {
        case .group:
            return true
        case .entry(let groupID, _):
            return (displayedGroups.first(where: { $0.id == groupID })?.entries.count ?? 0) > 1
        }
    }

    /// 字号变化时重新计算自适应高度，保持辅助功能字号下的完整文本与命中区域。
    override func layoutSubviews() {
        super.layoutSubviews()
        systemScrollEdgeRegistration.update(scrollView: self)
        let currentCategory = traitCollection.preferredContentSizeCategory
        guard lastPreferredContentSizeCategory != currentCategory else { return }
        guard activePayload == nil else {
            hasPendingContentSizeCategoryUpdate = true
            return
        }
        hasPendingContentSizeCategoryUpdate = false
        lastPreferredContentSizeCategory = currentCategory
        collectionViewLayout.invalidateLayout()
        updateVisibleCells()
    }

    /// 接收 SwiftUI 快照；拖拽与结构动画期间延后外部刷新，避免覆盖本地预览顺序。
    fileprivate func update(with configuration: DataImportCollectionConfiguration, animated: Bool) {
        if activePayload != nil || isPerformingStructuralUpdate {
            pendingConfiguration = configuration
            let shouldSettleForReducedMotion = !self.configuration.reducesMotion
                && configuration.reducesMotion
            self.configuration = self.configuration.replacingReducedMotion(
                configuration.reducesMotion
            )
            if shouldSettleForReducedMotion {
                settleCurrentVisualTransitionForReducedMotion()
            }
            return
        }

        let previousConfiguration = self.configuration
        let needsDataUpdate = previousConfiguration.dataSignature != configuration.dataSignature
        let needsPresentationUpdate = previousConfiguration.isEditing != configuration.isEditing
            || previousConfiguration.reducesMotion != configuration.reducesMotion
        self.configuration = configuration
        displayedGroups = configuration.groups
        interactionState = configuration.isEditing ? .editingExpanded : .normal

        if needsDataUpdate {
            reloadData()
        } else if needsPresentationUpdate {
            if animated, window != nil, !configuration.reducesMotion {
                UIView.transition(
                    with: self,
                    duration: DataImportCollectionMetrics.presentationDuration,
                    options: [.transitionCrossDissolve, .allowAnimatedContent]
                ) {
                    self.reloadData()
                }
            } else {
                reloadData()
            }
        }
    }

    /// 清空拖拽会话与覆盖层，供 SwiftUI 拆卸时安全复用。
    func prepareForReuse() {
        systemScrollEdgeRegistration.invalidate()
        dragGeneration = UUID()
        if isInteractiveMovementActive {
            cancelInteractiveMovement()
        }
        transitionAnimator?.stopAnimation(true)
        transitionAnimator = nil
        stopLateCellAnimators()
        groupDragProxy?.removeFromSuperview()
        groupDragProxy = nil
        groupDragOverlayHost = nil
        pendingConfiguration = nil
        originalGroupsBeforeDrag = []
        activePayload = nil
        areEntriesCollapsed = false
        setEntriesCollapsedInLayout(false)
        isPerformingStructuralUpdate = false
        visualTransitionPhase = .idle
        transitionStartingGroupFrames.removeAll()
        preparedTransitionCells.removeAll()
        isInteractiveMovementActive = false
        latestReorderLocation = nil
        pendingGroupFinishCancelled = nil
        isFinishingGroupDragQuickly = false
        groupDragAnchorScreenY = nil
        displayedGroups = []
        accessibilityCustomActions = nil
        reloadData()
    }
}

private extension DataImportCollectionHostView {
    /// 构建展开与紧凑态共用的多 section 布局，分组身份在结构切换前后保持不变。
    static func makeLayout() -> UICollectionViewCompositionalLayout {
        DataImportCollectionLayout()
    }

    /// 在同一 compositional layout 上切换 section 参数，保持可见 cell 身份连续。
    func setEntriesCollapsedInLayout(_ isCollapsed: Bool) {
        (collectionViewLayout as? DataImportCollectionLayout)?
            .setEntriesCollapsed(isCollapsed)
    }

    /// 将索引路径解析为当前可见模型，首项固定为分组标题。
    func itemID(at indexPath: IndexPath) -> DataImportCollectionItemID? {
        guard displayedGroups.indices.contains(indexPath.section) else { return nil }
        let group = displayedGroups[indexPath.section]
        if indexPath.item == 0 {
            return .group(group.id)
        }
        let entryIndex = indexPath.item - 1
        guard group.entries.indices.contains(entryIndex) else { return nil }
        return .entry(groupID: group.id, entryID: group.entries[entryIndex].id)
    }

    /// 用最新交互状态刷新可见行的箭头、把手、紧凑分组和可访问动作。
    func updateVisibleCells() {
        for case let cell as DataImportCollectionCell in visibleCells {
            guard let indexPath = indexPath(for: cell) else { continue }
            configure(cell, at: indexPath)
            applyVisualOwnership(to: cell, at: indexPath)
        }
    }

    /// 为分组标题或条目配置设计系统排版、表层、语义图标与操作回调。
    func configure(_ cell: DataImportCollectionCell, at indexPath: IndexPath) {
        guard displayedGroups.indices.contains(indexPath.section) else { return }
        let group = displayedGroups[indexPath.section]
        if indexPath.item == 0 {
            let canMoveUp = configuration.isEditing && indexPath.section > 0
            let canMoveDown = configuration.isEditing && indexPath.section < displayedGroups.count - 1
            cell.configureGroup(
                group,
                isEditing: configuration.isEditing,
                isCompact: areEntriesCollapsed,
                isDropTarget: false,
                moveUp: canMoveUp ? { [weak self] in
                    self?.moveGroupForAccessibility(group.id, offset: -1)
                    return true
                } : nil,
                moveDown: canMoveDown ? { [weak self] in
                    self?.moveGroupForAccessibility(group.id, offset: 1)
                    return true
                } : nil
            )
            if visualTransitionPhase == .idle {
                cell.setCompactProgress(areEntriesCollapsed ? 1 : 0)
            }
            return
        }

        let entryIndex = indexPath.item - 1
        guard group.entries.indices.contains(entryIndex) else { return }
        let entry = group.entries[entryIndex]
        let canReorderEntries = configuration.isEditing && group.entries.count > 1
        cell.configureEntry(
            entry,
            isEditing: configuration.isEditing,
            showsReorderHandle: canReorderEntries,
            isFirst: entryIndex == 0,
            isLast: entryIndex == group.entries.count - 1,
            moveUp: canReorderEntries && entryIndex > 0 ? { [weak self] in
                self?.moveEntryForAccessibility(group.id, entryID: entry.id, offset: -1)
                return true
            } : nil,
            moveDown: canReorderEntries && entryIndex < group.entries.count - 1 ? { [weak self] in
                self?.moveEntryForAccessibility(group.id, entryID: entry.id, offset: 1)
                return true
            } : nil
        )
    }

    /// 判断触点是否落在当前书写方向对应的 44pt 排序把手命中区。
    func isReorderHandleHit(for cell: DataImportCollectionCell, point: CGPoint) -> Bool {
        let hitWidth = max(InteractionMetrics.minimumTouchTarget, cell.reorderHandleWidth)
        let handleRect: CGRect
        if effectiveUserInterfaceLayoutDirection == .rightToLeft {
            handleRect = CGRect(x: 0, y: 0, width: hitWidth, height: cell.bounds.height)
        } else {
            handleRect = CGRect(
                x: max(cell.bounds.width - hitWidth, 0),
                y: 0,
                width: hitWidth,
                height: cell.bounds.height
            )
        }
        return handleRect.contains(point)
    }

    /// 自定义纵向手势只接管分组代理；组内条目仍使用 UIKit 原生 interactive movement。
    @objc func handleReorderPan(_ recognizer: UIPanGestureRecognizer) {
        let location = recognizer.location(in: self)
        latestReorderLocation = location

        switch recognizer.state {
        case .began:
            let startLocation = reorderStartLocation(for: recognizer)
            guard let indexPath = indexPathForItem(at: startLocation),
                  let itemID = itemID(at: indexPath) else {
                return
            }
            switch itemID {
            case .group(let groupID):
                beginGroupDrag(groupID, sourceIndexPath: indexPath, location: location)
            case .entry(let groupID, let entryID):
                beginEntryDrag(
                    groupID: groupID,
                    entryID: entryID,
                    sourceIndexPath: indexPath,
                    location: location
                )
            }
        case .changed:
            switch activePayload {
            case .group:
                updateGroupDrag(at: location)
            case .entry:
                guard isInteractiveMovementActive else { return }
                updateInteractiveMovementTargetPosition(interactiveMovementTarget(for: location))
            case nil:
                break
            }
        case .ended:
            finishActivePan(cancelled: false)
        case .cancelled, .failed:
            finishActivePan(cancelled: true)
        default:
            break
        }
    }

    /// 由当前触点减去累计位移还原按下位置，避免首个采样跨出标题后误判为条目。
    func reorderStartLocation(for recognizer: UIPanGestureRecognizer) -> CGPoint {
        let location = recognizer.location(in: self)
        let translation = recognizer.translation(in: self)
        return CGPoint(
            x: location.x - translation.x,
            y: location.y - translation.y
        )
    }

    /// 将系统条目移动限制在列表纵轴，避免从尾部把手起拖时横向偏移。
    func interactiveMovementTarget(for location: CGPoint) -> CGPoint {
        CGPoint(
            x: contentOffset.x + bounds.width / 2,
            y: location.y
        )
    }

    /// 分组按下首帧立即创建唯一代理，真实子项退场后再写入紧凑结构。
    func beginGroupDrag(
        _ groupID: DataImportGroupID,
        sourceIndexPath: IndexPath,
        location: CGPoint
    ) {
        guard let sourceCell = cellForItem(at: sourceIndexPath) as? DataImportCollectionCell,
              let group = displayedGroups.first(where: { $0.id == groupID }) else {
            return
        }
        let overlayHost = superview ?? self

        originalGroupsBeforeDrag = displayedGroups
        activePayload = .group(groupID)
        interactionState = .preparingGroupDrag(groupID)
        pendingGroupFinishCancelled = nil
        dragGeneration = UUID()
        groupDragAnchorScreenY = currentScreenY(for: groupID)
        groupDragOverlayHost = overlayHost

        let sourceFrame = sourceCell.convert(sourceCell.bounds, to: overlayHost)
        let proxyFrame = sourceFrame
        let proxy = DataImportGroupDragProxyView(
            group: group,
            frame: proxyFrame
        )
        overlayHost.addSubview(proxy)
        groupDragProxy = proxy
        let touchInHost = convert(location, to: overlayHost)
        groupDragTouchOffsetY = touchInHost.y - proxyFrame.minY
        let startingGroupFrames = visibleGroupFrames(in: overlayHost)
        transitionStartingGroupFrames = startingGroupFrames
        sourceCell.setContentSuppressed(true)
        overlayHost.bringSubviewToFront(proxy)

        if UIAccessibility.isVoiceOverRunning {
            UIAccessibility.post(notification: .announcement, argument: "正在调整分组顺序")
        }

        isPerformingStructuralUpdate = true
        visualTransitionPhase = .departingEntries(groupID)
        preparedTransitionCells = visibleCells.reduce(into: [:]) { result, cell in
            guard let indexPath = indexPath(for: cell),
                  let itemID = itemID(at: indexPath),
                  case .group = itemID else {
                return
            }
            result[itemID] = ObjectIdentifier(cell)
        }
        let generation = dragGeneration
        animateEntryDepartureBeforeCollapse(
            groupID: groupID,
            generation: generation
        ) { [weak self] in
            self?.applyCollapsedStructure(
                groupID: groupID,
                startingGroupFrames: startingGroupFrames,
                generation: generation
            )
        }
    }

    /// 子项先在原有结构中快速退场，避免紧凑卡片上移时穿过半透明文字。
    func animateEntryDepartureBeforeCollapse(
        groupID: DataImportGroupID,
        generation: UUID,
        completion: @escaping () -> Void
    ) {
        let visibleEntryCells = visibleCells.compactMap { cell -> DataImportCollectionCell? in
            guard let cell = cell as? DataImportCollectionCell,
                  let indexPath = indexPath(for: cell),
                  case .entry = itemID(at: indexPath) else {
                return nil
            }
            return cell
        }
        guard !visibleEntryCells.isEmpty else {
            completion()
            return
        }
        let animator = UIViewPropertyAnimator(
            duration: configuration.reducesMotion
                ? DataImportCollectionMetrics.reduceMotionFadeDuration
                : DataImportCollectionMetrics.entryDepartureDuration,
            curve: .easeOut
        )
        animator.addAnimations { [weak self] in
            guard let self else { return }
            for cell in visibleEntryCells {
                if !self.configuration.reducesMotion {
                    cell.transform = CGAffineTransform(
                        translationX: 0,
                        y: -DataImportCollectionMetrics.entryDepartureTravel
                    )
                }
                cell.alpha = 0
            }
        }
        animator.addCompletion { [weak self] _ in
            guard let self,
                  self.dragGeneration == generation,
                  self.activePayload == .group(groupID) else {
                return
            }
            self.transitionAnimator = nil
            completion()
        }
        transitionAnimator = animator
        animator.startAnimation()
        accelerateCurrentVisualTransitionIfFinishing()
    }

    /// 条目已不可见后原子写入紧凑结构，再由真实标题完成唯一一轮 FLIP。
    func applyCollapsedStructure(
        groupID: DataImportGroupID,
        startingGroupFrames: [DataImportGroupID: CGRect],
        generation: UUID
    ) {
        visualTransitionPhase = .collapsing(groupID)
        preparedTransitionCells.removeAll()
        let entryIndexPaths = displayedGroups.enumerated().flatMap { section, group in
            group.entries.indices.map { IndexPath(item: $0 + 1, section: section) }
        }
        areEntriesCollapsed = true
        setEntriesCollapsedInLayout(true)
        performStructuralUpdateWithoutAnimation({
            self.deleteItems(at: entryIndexPaths)
        }, prepare: { [weak self] in
            guard let self else { return }
            self.updateVisibleCells()
            self.stabilizeCurrentLayout()
            self.restoreAnchor(for: groupID, screenY: self.groupDragAnchorScreenY)
            self.layoutIfNeeded()
            self.prepareVisibleGroupsForTransition(
                from: startingGroupFrames,
                activeGroupID: groupID
            )
        }) { [weak self] _ in
            guard let self,
                  self.dragGeneration == generation,
                  self.activePayload == .group(groupID) else {
                return
            }
            self.animateCollapseTowardGroups(groupID: groupID, generation: generation)
        }
    }

    /// 条目退场后，其他标题由同一真实 cell 连续移动到紧凑位置。
    func animateCollapseTowardGroups(groupID: DataImportGroupID, generation: UUID) {
        layoutIfNeeded()
        if configuration.reducesMotion {
            UIView.performWithoutAnimation {
                self.groupDragProxy?.frame.size.height =
                    DataImportCollectionMetrics.compactGroupMinimumHeight
            }
        }
        let animator = UIViewPropertyAnimator(
            duration: configuration.reducesMotion
                ? DataImportCollectionMetrics.reduceMotionFadeDuration
                : DataImportCollectionMetrics.collapseDuration,
            curve: .easeInOut
        )
        animator.addAnimations { [weak self] in
            guard let self else { return }
            for case let cell as DataImportCollectionCell in self.visibleCells {
                guard let indexPath = self.indexPath(for: cell),
                      case .group(let visibleGroupID) = self.itemID(at: indexPath),
                      visibleGroupID != groupID else {
                    continue
                }
                cell.alpha = 1
                cell.transform = .identity
                cell.setCompactProgress(1)
            }
            if !self.configuration.reducesMotion {
                self.groupDragProxy?.frame.size.height =
                    DataImportCollectionMetrics.compactGroupMinimumHeight
            }
            self.groupDragProxy?.setCompactProgress(1)
        }
        animator.addCompletion { [weak self] _ in
            guard let self,
                  self.dragGeneration == generation,
                  self.activePayload == .group(groupID) else {
                return
            }
            self.transitionAnimator = nil
            self.visualTransitionPhase = .idle
            self.transitionStartingGroupFrames.removeAll()
            self.preparedTransitionCells.removeAll()
            self.normalizeVisibleCellPresentation(preservingActiveGroup: groupID)
            self.interactionState = .draggingGroup(groupID)
            self.isPerformingStructuralUpdate = false
            if self.pendingGroupFinishCancelled == true {
                self.processPendingGroupFinishIfNeeded()
                return
            }
            if let latestLocation = self.latestReorderLocation {
                self.updateGroupDrag(at: latestLocation)
            }
            self.processPendingGroupFinishIfNeeded()
        }
        transitionAnimator = animator
        animator.startAnimation()
        accelerateCurrentVisualTransitionIfFinishing()
    }

    /// 浮动代理持续直接跟手；紧凑结构稳定后才根据相邻标题中心移动 section。
    func updateGroupDrag(at location: CGPoint) {
        guard case .group(let groupID) = activePayload,
              let proxy = groupDragProxy,
              let overlayHost = groupDragOverlayHost else {
            return
        }

        let touchInHost = convert(location, to: overlayHost)
        var proxyFrame = proxy.frame
        proxyFrame.origin.y = touchInHost.y - groupDragTouchOffsetY
        proxy.frame = proxyFrame

        guard interactionState == .draggingGroup(groupID),
              !isPerformingStructuralUpdate,
              let destinationIndex = resolvedGroupDestinationIndex(for: proxy.frame.midY),
              let sourceIndex = displayedGroups.firstIndex(where: { $0.id == groupID }),
              destinationIndex != sourceIndex else {
            return
        }
        moveGroupSection(groupID: groupID, from: sourceIndex, to: destinationIndex)
    }

    /// 跨越相邻分组中心时移动完整 section，浮动代理不参与布局动画因而保持跟手。
    func moveGroupSection(
        groupID: DataImportGroupID,
        from sourceIndex: Int,
        to destinationIndex: Int
    ) {
        guard displayedGroups.indices.contains(sourceIndex),
              destinationIndex >= 0,
              destinationIndex < displayedGroups.count else {
            return
        }

        transitionGroupSection(
            groupID: groupID,
            from: sourceIndex,
            to: destinationIndex
        ) { [weak self] in
            guard let self else { return }
            if self.pendingGroupFinishCancelled == true {
                self.processPendingGroupFinishIfNeeded()
                return
            }
            if let latestLocation = self.latestReorderLocation {
                self.updateGroupDrag(at: latestLocation)
            }
            self.processPendingGroupFinishIfNeeded()
        }
    }

    /// 以 FLIP 几何衔接无动画 section 写入，避免 UIKit 批量更新再叠加第二套外层动画。
    func transitionGroupSection(
        groupID: DataImportGroupID,
        from sourceIndex: Int,
        to destinationIndex: Int,
        completion: @escaping () -> Void
    ) {
        let overlayHost = groupDragOverlayHost ?? superview ?? self
        let startingGroupFrames = visibleGroupFrames(in: overlayHost)
        transitionStartingGroupFrames = startingGroupFrames
        isPerformingStructuralUpdate = true
        visualTransitionPhase = .reordering(groupID)
        preparedTransitionCells.removeAll()

        let group = displayedGroups.remove(at: sourceIndex)
        displayedGroups.insert(group, at: destinationIndex)
        let generation = dragGeneration
        performStructuralUpdateWithoutAnimation({
            self.moveSection(sourceIndex, toSection: destinationIndex)
        }, prepare: { [weak self] in
            guard let self else { return }
            self.updateVisibleCells()
            self.stabilizeCurrentLayout()
            self.prepareVisibleGroupsForTransition(
                from: startingGroupFrames,
                activeGroupID: groupID
            )
        }) { [weak self] _ in
            guard let self,
                  self.dragGeneration == generation,
                  self.activePayload == .group(groupID) else {
                return
            }
            self.animateCollapsedGroupRelayout(
                activeGroupID: groupID,
                generation: generation,
                completion: completion
            )
        }
    }

    /// 只移动兄弟分组的真实 cell；活动分组始终由手指下的唯一代理持有。
    func animateCollapsedGroupRelayout(
        activeGroupID: DataImportGroupID,
        generation: UUID,
        completion: @escaping () -> Void
    ) {
        let finish = { [weak self] in
            guard let self,
                  self.dragGeneration == generation,
                  self.activePayload == .group(activeGroupID) else {
                return
            }
            self.transitionAnimator = nil
            self.visualTransitionPhase = .idle
            self.transitionStartingGroupFrames.removeAll()
            self.preparedTransitionCells.removeAll()
            self.normalizeVisibleCellPresentation(preservingActiveGroup: activeGroupID)
            self.isPerformingStructuralUpdate = false
            completion()
        }
        guard !configuration.reducesMotion else {
            UIView.performWithoutAnimation {
                for case let cell as DataImportCollectionCell in self.visibleCells {
                    cell.alpha = 1
                    cell.transform = .identity
                }
            }
            finish()
            return
        }

        let animator = UIViewPropertyAnimator(
            duration: DataImportCollectionMetrics.sectionMoveDuration,
            curve: .easeInOut
        )
        animator.addAnimations { [weak self] in
            guard let self else { return }
            for case let cell as DataImportCollectionCell in self.visibleCells {
                cell.alpha = 1
                cell.transform = .identity
            }
        }
        animator.addCompletion { _ in finish() }
        transitionAnimator = animator
        animator.startAnimation()
        accelerateCurrentVisualTransitionIfFinishing()
    }

    /// 只在跨过相邻标题中心并越过滞回区后移动一步，避免跨级与边界来回抖动。
    func resolvedGroupDestinationIndex(for proxyCenterY: CGFloat) -> Int? {
        guard case .group(let groupID) = activePayload,
              let currentIndex = displayedGroups.firstIndex(where: { $0.id == groupID }) else {
            return nil
        }
        let hysteresis = DataImportCollectionMetrics.sectionMoveHysteresis
        if currentIndex > 0,
           let previousFrame = frameInOverlay(forSection: currentIndex - 1),
           proxyCenterY < previousFrame.midY - hysteresis {
            return currentIndex - 1
        }
        if currentIndex + 1 < displayedGroups.count,
           let nextFrame = frameInOverlay(forSection: currentIndex + 1),
           proxyCenterY > nextFrame.midY + hysteresis {
            return currentIndex + 1
        }
        return currentIndex
    }

    /// 条目沿用当前 section 的原生 interactive movement，不触发分组收起。
    func beginEntryDrag(
        groupID: DataImportGroupID,
        entryID: String,
        sourceIndexPath: IndexPath,
        location: CGPoint
    ) {
        originalGroupsBeforeDrag = displayedGroups
        activePayload = .entry(groupID: groupID, entryID: entryID)
        dragGeneration = UUID()
        guard beginInteractiveMovementForItem(at: sourceIndexPath) else {
            resetDragSession()
            return
        }
        isInteractiveMovementActive = true
        updateInteractiveMovementTargetPosition(interactiveMovementTarget(for: location))
    }

    /// 手势收口按载荷分流；分组等待当前结构更新，条目结束系统原生移动。
    func finishActivePan(cancelled: Bool) {
        switch activePayload {
        case .group:
            requestGroupDragFinish(cancelled: cancelled)
        case .entry(let groupID, _):
            finishEntryDrag(groupID: groupID, cancelled: cancelled)
        case nil:
            break
        }
    }

    /// 快速松手或系统打断时记录最终意图，当前折叠或 section 移动完成后立即收口。
    func requestGroupDragFinish(cancelled: Bool) {
        if pendingGroupFinishCancelled == nil {
            isFinishingGroupDragQuickly = isPerformingStructuralUpdate
                || transitionAnimator?.isRunning == true
        }
        if let pendingGroupFinishCancelled {
            self.pendingGroupFinishCancelled = pendingGroupFinishCancelled || cancelled
        } else {
            pendingGroupFinishCancelled = cancelled
        }
        accelerateCurrentVisualTransitionIfFinishing()
        processPendingGroupFinishIfNeeded()
    }

    /// 快速松手时从当前进度缩短剩余视觉时长，结构仍先收敛到安全端点再展开。
    func accelerateCurrentVisualTransitionIfFinishing() {
        guard isFinishingGroupDragQuickly else { return }
        let animators = [transitionAnimator].compactMap { $0 } + lateCellAnimators.values
        for animator in animators where animator.isRunning {
            animator.pauseAnimation()
            animator.continueAnimation(
                withTimingParameters: UICubicTimingParameters(animationCurve: .easeOut),
                durationFactor: DataImportCollectionMetrics.finishDurationFactor
            )
        }
    }

    /// 仅在没有结构写入时进入吸附与展开，避免两个批量更新重叠。
    func processPendingGroupFinishIfNeeded() {
        guard let cancelled = pendingGroupFinishCancelled,
              !isPerformingStructuralUpdate,
              case .group(let groupID) = activePayload,
              interactionState == .draggingGroup(groupID) else {
            return
        }
        pendingGroupFinishCancelled = nil
        settleGroupDrag(groupID: groupID, cancelled: cancelled)
    }

    /// 取消时先将活动分组平滑移回原 section；正常落位直接吸附当前目标标题。
    func settleGroupDrag(groupID: DataImportGroupID, cancelled: Bool) {
        interactionState = .settlingGroup
        isPerformingStructuralUpdate = true
        if cancelled {
            restoreGroupSectionForCancellation(groupID: groupID) { [weak self] in
                self?.snapGroupProxyAndExpand(groupID: groupID, cancelled: true)
            }
        } else {
            snapGroupProxyAndExpand(groupID: groupID, cancelled: false)
        }
    }

    /// 单次分组拖动只改变活动分组位置，取消时一次 moveSection 即可恢复会话前顺序。
    func restoreGroupSectionForCancellation(
        groupID: DataImportGroupID,
        completion: @escaping () -> Void
    ) {
        guard let sourceIndex = displayedGroups.firstIndex(where: { $0.id == groupID }),
              let destinationIndex = originalGroupsBeforeDrag.firstIndex(where: { $0.id == groupID }),
              sourceIndex != destinationIndex else {
            displayedGroups = originalGroupsBeforeDrag
            completion()
            return
        }

        transitionGroupSection(
            groupID: groupID,
            from: sourceIndex,
            to: destinationIndex
        ) { [weak self] in
            guard let self else { return }
            self.displayedGroups = self.originalGroupsBeforeDrag
            completion()
        }
    }

    /// 浮动代理干净吸附到目标标题；Reduce Motion 下立即对齐并只做局部淡变。
    func snapGroupProxyAndExpand(groupID: DataImportGroupID, cancelled: Bool) {
        guard let proxy = groupDragProxy,
              let targetFrame = frameInOverlay(for: groupID) else {
            expandEntries(afterGroupDrag: groupID, cancelled: cancelled)
            return
        }

        let animations = {
            proxy.bounds.size = targetFrame.size
            proxy.center = CGPoint(x: targetFrame.midX, y: targetFrame.midY)
        }
        guard !configuration.reducesMotion else {
            animations()
            expandEntries(afterGroupDrag: groupID, cancelled: cancelled)
            return
        }

        let animator = UIViewPropertyAnimator(
            duration: DataImportCollectionMetrics.snapDuration,
            curve: .easeOut,
            animations: animations
        )
        animator.addCompletion { [weak self] _ in
            guard let self else { return }
            self.transitionAnimator = nil
            self.expandEntries(afterGroupDrag: groupID, cancelled: cancelled)
        }
        transitionAnimator = animator
        animator.startAnimation()
        accelerateCurrentVisualTransitionIfFinishing()
    }

    /// 在唯一代理与真实标题遮蔽下原子插入子项，再启动唯一一轮展开动画。
    func expandEntries(afterGroupDrag groupID: DataImportGroupID, cancelled: Bool) {
        let overlayHost = groupDragOverlayHost ?? superview ?? self
        let compactGroupFrames = visibleGroupFrames(in: overlayHost)
        transitionStartingGroupFrames = compactGroupFrames
        let anchorScreenY = currentScreenY(for: groupID)
        let entryIndexPaths = displayedGroups.enumerated().flatMap { section, group in
            group.entries.indices.map { IndexPath(item: $0 + 1, section: section) }
        }
        isPerformingStructuralUpdate = true
        visualTransitionPhase = .expanding(groupID)
        preparedTransitionCells.removeAll()
        areEntriesCollapsed = false
        setEntriesCollapsedInLayout(false)
        let generation = dragGeneration

        performStructuralUpdateWithoutAnimation({
            self.insertItems(at: entryIndexPaths)
        }, prepare: { [weak self] in
            guard let self else { return }
            self.updateVisibleCells()
            self.stabilizeCurrentLayout()
            self.restoreAnchor(for: groupID, screenY: anchorScreenY)
            self.layoutIfNeeded()
            self.prepareVisibleGroupsForTransition(
                from: compactGroupFrames,
                activeGroupID: groupID
            )
            self.prepareVisibleEntriesForExpansion()
        }) { [weak self] _ in
            guard let self,
                  self.dragGeneration == generation,
                  self.activePayload == .group(groupID) else {
                return
            }
            self.animateExpansion(groupID: groupID, cancelled: cancelled, generation: generation)
        }
    }

    /// 分组标题保持身份连续，子项从各自父标题区域淡入并展开到最终位置。
    func animateExpansion(
        groupID: DataImportGroupID,
        cancelled: Bool,
        generation: UUID
    ) {
        if configuration.reducesMotion,
           let proxy = groupDragProxy,
           let targetFrame = frameInOverlay(for: groupID) {
            UIView.performWithoutAnimation {
                proxy.frame = targetFrame
            }
        }
        let animator = UIViewPropertyAnimator(
            duration: configuration.reducesMotion
                ? DataImportCollectionMetrics.reduceMotionFadeDuration
                : DataImportCollectionMetrics.expandDuration,
            curve: .easeInOut
        )
        animator.addAnimations { [weak self] in
            guard let self else { return }
            if let proxy = self.groupDragProxy,
               let targetFrame = self.frameInOverlay(for: groupID) {
                if !self.configuration.reducesMotion {
                    proxy.frame = targetFrame
                }
                proxy.setCompactProgress(0)
            }
            for case let cell as DataImportCollectionCell in self.visibleCells {
                cell.alpha = 1
                cell.transform = .identity
                cell.setCompactProgress(0)
            }
        }
        animator.addCompletion { [weak self] _ in
            guard let self,
                  self.dragGeneration == generation,
                  self.activePayload == .group(groupID) else {
                return
            }
            self.transitionAnimator = nil
            self.visualTransitionPhase = .idle
            self.transitionStartingGroupFrames.removeAll()
            self.preparedTransitionCells.removeAll()
            UIView.performWithoutAnimation {
                self.handoffGroupProxy(to: groupID)
                self.normalizeVisibleCellPresentation(preservingActiveGroup: nil)
            }
            self.isPerformingStructuralUpdate = false
            let orderedIDs = self.displayedGroups.map(\.id)
            let originalIDs = self.originalGroupsBeforeDrag.map(\.id)
            let shouldCommit = !cancelled && orderedIDs != originalIDs
            let commit = self.configuration.onCommitGroupOrder
            if shouldCommit {
                self.adoptDisplayedGroupsAsConfigurationBaseline()
            }
            self.resetDragSession()
            if shouldCommit {
                commit(orderedIDs)
            }
        }
        transitionAnimator = animator
        animator.startAnimation()
        accelerateCurrentVisualTransitionIfFinishing()
    }

    /// 为展开条目设置短距离父向位移；不再压扁文字或从屏外长距离飞入。
    func prepareVisibleEntriesForExpansion() {
        for case let cell as DataImportCollectionCell in visibleCells {
            guard let indexPath = indexPath(for: cell),
                  let itemID = itemID(at: indexPath),
                  case .entry(let groupID, _) = itemID else {
                continue
            }
            preparedTransitionCells[itemID] = ObjectIdentifier(cell)
            cell.alpha = 0
            cell.transform = .identity
            guard !configuration.reducesMotion,
                  let parentFrame = frameInCollection(for: groupID) else {
                continue
            }
            let deltaY = clampedEntryTravel(parentFrame.midY - cell.frame.midY)
            cell.transform = CGAffineTransform(translationX: 0, y: deltaY)
        }
    }

    /// 完成组内移动；取消时恢复快照，有效变更只写回当前分组。
    func finishEntryDrag(groupID: DataImportGroupID, cancelled: Bool) {
        guard isInteractiveMovementActive else {
            resetDragSession()
            return
        }
        isInteractiveMovementActive = false
        if cancelled {
            cancelInteractiveMovement()
        } else {
            endInteractiveMovement()
        }

        let generation = dragGeneration
        DispatchQueue.main.asyncAfter(
            deadline: .now() + DataImportCollectionMetrics.entrySettleDuration
        ) { [weak self] in
            guard let self, self.dragGeneration == generation else { return }
            if cancelled {
                self.displayedGroups = self.originalGroupsBeforeDrag
                self.reloadData()
            }
            let orderedIDs = self.displayedGroups
                .first(where: { $0.id == groupID })?.entries.map(\.id) ?? []
            let originalIDs = self.originalGroupsBeforeDrag
                .first(where: { $0.id == groupID })?.entries.map(\.id) ?? []
            let shouldCommit = !cancelled && orderedIDs != originalIDs
            let commit = self.configuration.onCommitEntryOrder
            if shouldCommit {
                self.adoptDisplayedGroupsAsConfigurationBaseline()
            }
            self.resetDragSession()
            if shouldCommit {
                commit(groupID, orderedIDs)
            }
        }
    }

    /// 记录当前可见分组在覆盖层中的首帧几何，用于无快照的 FLIP 连续位移。
    func visibleGroupFrames(in overlayHost: UIView) -> [DataImportGroupID: CGRect] {
        visibleCells.reduce(into: [:]) { result, cell in
            guard let indexPath = indexPath(for: cell),
                  case .group(let groupID) = itemID(at: indexPath) else {
                return
            }
            result[groupID] = cell.convert(cell.bounds, to: overlayHost)
        }
    }

    /// 将真实分组 cell 放回结构变更前的屏幕几何，下一帧只需动画到 identity。
    func prepareVisibleGroupsForTransition(
        from startingFrames: [DataImportGroupID: CGRect],
        activeGroupID: DataImportGroupID
    ) {
        let overlayHost = groupDragOverlayHost ?? superview ?? self
        for case let cell as DataImportCollectionCell in visibleCells {
            guard let indexPath = indexPath(for: cell),
                  let itemID = itemID(at: indexPath),
                  case .group(let groupID) = itemID else {
                continue
            }
            preparedTransitionCells[itemID] = ObjectIdentifier(cell)
            cell.setContentSuppressed(groupID == activeGroupID && groupDragProxy != nil)
            cell.transform = .identity
            cell.setCompactProgress(
                startingFrames[groupID] == nil
                    ? visualTransitionPhase.targetCompactProgress
                    : visualTransitionPhase.sourceCompactProgress
            )
            guard !configuration.reducesMotion,
                  let startingFrame = startingFrames[groupID] else {
                cell.alpha = startingFrames[groupID] == nil ? 0 : 1
                continue
            }
            let targetFrame = cell.convert(cell.bounds, to: overlayHost)
            cell.alpha = 1
            cell.transform = transformMapping(targetFrame: targetFrame, to: startingFrame)
        }
    }

    /// 仅映射标题中心位置；高度由布局和卡片外壳承担，避免缩放文字与图标。
    func transformMapping(targetFrame: CGRect, to startingFrame: CGRect) -> CGAffineTransform {
        CGAffineTransform(
            translationX: startingFrame.midX - targetFrame.midX,
            y: startingFrame.midY - targetFrame.midY
        )
    }

    /// 在首个屏幕提交前写入结构终态与 FLIP 初态，再等待 UIKit 完成批量更新后启动主动画。
    func performStructuralUpdateWithoutAnimation(
        _ updates: @escaping () -> Void,
        prepare: @escaping () -> Void,
        completion: @escaping (Bool) -> Void
    ) {
        UIView.performWithoutAnimation {
            performBatchUpdates(updates) { finished in
                UIView.performWithoutAnimation {
                    prepare()
                }
                DispatchQueue.main.async {
                    completion(finished)
                }
            }
            layoutIfNeeded()
            prepare()
        }
    }

    /// 让 Hosting 自适应高度在读取目标 frame 前完成两轮配置与布局收敛。
    func stabilizeCurrentLayout() {
        collectionViewLayout.invalidateLayout()
        layoutIfNeeded()
        updateVisibleCells()
        collectionViewLayout.invalidateLayout()
        layoutIfNeeded()
    }

    /// 将布局属性换算到覆盖层坐标，供代理与真实标题共享同一锚点。
    func frameInOverlay(for groupID: DataImportGroupID) -> CGRect? {
        guard let groupIndex = displayedGroups.firstIndex(where: { $0.id == groupID }) else {
            return nil
        }
        return frameInOverlay(forSection: groupIndex)
    }

    /// 将指定 section 标题换算到当前覆盖层坐标。
    func frameInOverlay(forSection section: Int) -> CGRect? {
        guard let overlayHost = groupDragOverlayHost,
              let attributes = layoutAttributesForItem(at: IndexPath(item: 0, section: section)) else {
            return nil
        }
        return convert(attributes.frame, to: overlayHost)
    }

    /// 返回当前集合内容坐标中的分组标题 frame，用于设置子项展开初始位移。
    func frameInCollection(for groupID: DataImportGroupID) -> CGRect? {
        guard let groupIndex = displayedGroups.firstIndex(where: { $0.id == groupID }) else {
            return nil
        }
        return layoutAttributesForItem(at: IndexPath(item: 0, section: groupIndex))?.frame
    }

    /// 将条目位移限制在局部范围，避免长列表文字压缩成残影或跨屏飞行。
    func clampedEntryTravel(_ proposed: CGFloat) -> CGFloat {
        min(
            max(proposed, -DataImportCollectionMetrics.entryTransitionTravel),
            DataImportCollectionMetrics.entryTransitionTravel
        )
    }

    /// 最终 frame 对齐后原子交还活动分组视觉所有权，不产生代理与真实标题的重叠帧。
    func handoffGroupProxy(to groupID: DataImportGroupID) {
        if let indexPath = indexPathForGroup(groupID) {
            let cell = cellForItem(at: indexPath) as? DataImportCollectionCell
            cell?.alpha = 1
            cell?.transform = .identity
            cell?.setContentSuppressed(false)
        }
        groupDragProxy?.removeFromSuperview()
        groupDragProxy = nil
    }

    /// 将所有迟到 cell 动画收敛到目标端点，避免离屏 cell 停在半透明或半紧凑状态。
    func stopLateCellAnimators() {
        let animators = Array(lateCellAnimators.values)
        lateCellAnimators.removeAll()
        for animator in animators {
            if animator.state == .inactive {
                animator.startAnimation()
            }
            guard animator.state == .active else { continue }
            animator.stopAnimation(false)
            animator.finishAnimation(at: .end)
        }
    }

    /// 用户在拖拽中开启“减少动态效果”时，从当前帧立即结束自动位移，后续阶段改用局部淡变。
    func settleCurrentVisualTransitionForReducedMotion() {
        stopLateCellAnimators()
        guard let animator = transitionAnimator else { return }
        if animator.state == .inactive {
            animator.startAnimation()
        }
        guard animator.state == .active else { return }
        animator.stopAnimation(false)
        animator.finishAnimation(at: .end)
    }

    /// 将可见 cell 收敛到稳定状态，并按业务 ID 持续隐藏唯一代理下方的活动标题。
    func normalizeVisibleCellPresentation(preservingActiveGroup activeGroupID: DataImportGroupID?) {
        stopLateCellAnimators()
        for case let cell as DataImportCollectionCell in visibleCells {
            cell.removeVisualAnimations()
            cell.alpha = 1
            cell.transform = .identity
            guard let indexPath = indexPath(for: cell),
                  case .group(let groupID) = itemID(at: indexPath) else {
                cell.setContentSuppressed(false)
                continue
            }
            cell.setCompactProgress(areEntriesCollapsed ? 1 : 0)
            cell.setContentSuppressed(
                groupID == activeGroupID && groupDragProxy != nil
            )
        }
    }

    /// 在创建和复用边界重申视觉所有权，杜绝活动 section 的真实内容重新露出。
    func applyVisualOwnership(to cell: DataImportCollectionCell, at indexPath: IndexPath) {
        guard let itemID = itemID(at: indexPath) else { return }
        if visualTransitionPhase != .idle,
           preparedTransitionCells[itemID] != ObjectIdentifier(cell) {
            prepareLateVisibleCell(cell, itemID: itemID)
        }
        guard case .group(let groupID) = itemID else {
            cell.setContentSuppressed(false)
            return
        }
        let activeGroupID: DataImportGroupID?
        if case .group(let groupID) = activePayload {
            activeGroupID = groupID
        } else {
            activeGroupID = nil
        }
        cell.setContentSuppressed(
            groupDragProxy != nil && groupID == activeGroupID
        )
    }

    /// 让动画期间才进入视口的 cell 从当前进度加入，而不是直接跳到最终状态。
    func prepareLateVisibleCell(
        _ cell: DataImportCollectionCell,
        itemID: DataImportCollectionItemID
    ) {
        let cellIdentifier = ObjectIdentifier(cell)
        if let existingAnimator = lateCellAnimators.removeValue(forKey: cellIdentifier) {
            if existingAnimator.state == .inactive {
                existingAnimator.startAnimation()
            }
            if existingAnimator.state == .active {
                existingAnimator.stopAnimation(false)
                existingAnimator.finishAnimation(at: .end)
            }
        }
        preparedTransitionCells[itemID] = cellIdentifier
        guard let animator = transitionAnimator else {
            prepareCellBeforeTransitionAnimator(cell, itemID: itemID)
            return
        }
        let progress = min(max(animator.fractionComplete, 0), 1)
        switch itemID {
        case .group(let groupID):
            if !configuration.reducesMotion,
               let startingFrame = transitionStartingGroupFrames[groupID] {
                let overlayHost = groupDragOverlayHost ?? superview ?? self
                let targetFrame = cell.convert(cell.bounds, to: overlayHost)
                let startTransform = transformMapping(
                    targetFrame: targetFrame,
                    to: startingFrame
                )
                cell.alpha = 1
                cell.transform = CGAffineTransform(
                    translationX: startTransform.tx * (1 - progress),
                    y: startTransform.ty * (1 - progress)
                )
            } else {
                cell.alpha = progress
                cell.transform = .identity
            }
            let sourceProgress = visualTransitionPhase.sourceCompactProgress
            let targetProgress = visualTransitionPhase.targetCompactProgress
            cell.setCompactProgress(
                sourceProgress + (targetProgress - sourceProgress) * progress
            )
        case .entry(let groupID, _):
            guard case .expanding = visualTransitionPhase else {
                cell.alpha = 0
                return
            }
            cell.alpha = progress
            if !configuration.reducesMotion,
               let parentFrame = frameInCollection(for: groupID) {
                let deltaY = clampedEntryTravel(parentFrame.midY - cell.frame.midY)
                cell.transform = CGAffineTransform(
                    translationX: 0,
                    y: deltaY * (1 - progress)
                )
            }
        }
        let remainingDuration = visualTransitionDuration * TimeInterval(1 - progress)
        let targetCompactProgress = visualTransitionPhase.targetCompactProgress
        let generation = dragGeneration
        let lateAnimator = UIViewPropertyAnimator(
            duration: max(remainingDuration, 0.01),
            curve: .easeInOut
        )
        lateAnimator.addAnimations { [weak cell] in
            guard let cell else { return }
            cell.alpha = 1
            cell.transform = .identity
            if case .group = itemID {
                cell.setCompactProgress(targetCompactProgress)
            }
        }
        lateAnimator.addCompletion { [weak self, weak lateAnimator] _ in
            guard let self,
                  let lateAnimator,
                  self.dragGeneration == generation,
                  self.lateCellAnimators[cellIdentifier] === lateAnimator else {
                return
            }
            self.lateCellAnimators.removeValue(forKey: cellIdentifier)
        }
        lateCellAnimators[cellIdentifier] = lateAnimator
        lateAnimator.startAnimation()
        accelerateCurrentVisualTransitionIfFinishing()
    }

    /// batch 尚未完成时，分组直接从已保存几何承担视觉；只有新条目保持隐藏。
    func prepareCellBeforeTransitionAnimator(
        _ cell: DataImportCollectionCell,
        itemID: DataImportCollectionItemID
    ) {
        cell.transform = .identity
        switch itemID {
        case .group(let groupID):
            cell.setCompactProgress(visualTransitionPhase.sourceCompactProgress)
            guard !configuration.reducesMotion,
                  let startingFrame = transitionStartingGroupFrames[groupID] else {
                cell.alpha = transitionStartingGroupFrames[groupID] == nil ? 0 : 1
                return
            }
            let overlayHost = groupDragOverlayHost ?? superview ?? self
            let targetFrame = cell.convert(cell.bounds, to: overlayHost)
            cell.alpha = 1
            cell.transform = transformMapping(targetFrame: targetFrame, to: startingFrame)
        case .entry:
            cell.alpha = 0
        }
    }

    /// 返回当前阶段的最长剩余视觉时长，供迟到 cell 与主动画同步收口。
    var visualTransitionDuration: TimeInterval {
        if configuration.reducesMotion {
            return DataImportCollectionMetrics.reduceMotionFadeDuration
        }
        switch visualTransitionPhase {
        case .idle:
            return 0
        case .departingEntries:
            return DataImportCollectionMetrics.entryDepartureDuration
        case .collapsing:
            return DataImportCollectionMetrics.collapseDuration
        case .reordering:
            return DataImportCollectionMetrics.sectionMoveDuration
        case .expanding:
            return DataImportCollectionMetrics.expandDuration
        }
    }

    /// 将本地最终顺序设为配置比较基线，阻止持久化回流对同一结构再次整表刷新。
    func adoptDisplayedGroupsAsConfigurationBaseline() {
        configuration = configuration.replacingGroups(displayedGroups)
        if let pendingConfiguration {
            self.pendingConfiguration = pendingConfiguration.replacingGroups(displayedGroups)
        }
    }

    /// 清理一次会话并应用拖拽期间延迟到达的 SwiftUI 配置。
    func resetDragSession() {
        dragGeneration = UUID()
        transitionAnimator?.stopAnimation(true)
        transitionAnimator = nil
        stopLateCellAnimators()
        groupDragProxy?.removeFromSuperview()
        groupDragProxy = nil
        groupDragOverlayHost = nil
        activePayload = nil
        originalGroupsBeforeDrag = []
        areEntriesCollapsed = false
        setEntriesCollapsedInLayout(false)
        isPerformingStructuralUpdate = false
        visualTransitionPhase = .idle
        transitionStartingGroupFrames.removeAll()
        preparedTransitionCells.removeAll()
        isInteractiveMovementActive = false
        latestReorderLocation = nil
        pendingGroupFinishCancelled = nil
        isFinishingGroupDragQuickly = false
        groupDragAnchorScreenY = nil
        interactionState = configuration.isEditing ? .editingExpanded : .normal
        normalizeVisibleCellPresentation(preservingActiveGroup: nil)

        if let pendingConfiguration {
            self.pendingConfiguration = nil
            update(with: pendingConfiguration, animated: false)
        }
        applyPendingContentSizeCategoryUpdateIfNeeded()
    }

    /// 会话结束后只补做一次被拖拽延后的字号布局刷新，避免系统设置变化留下旧行高。
    func applyPendingContentSizeCategoryUpdateIfNeeded() {
        let currentCategory = traitCollection.preferredContentSizeCategory
        guard hasPendingContentSizeCategoryUpdate
                || lastPreferredContentSizeCategory != currentCategory else {
            return
        }
        hasPendingContentSizeCategoryUpdate = false
        lastPreferredContentSizeCategory = currentCategory
        collectionViewLayout.invalidateLayout()
        updateVisibleCells()
        setNeedsLayout()
    }

    /// 读取指定分组标题当前相对屏幕的纵向位置，用于结构变化后的跳手补偿。
    func currentScreenY(for groupID: DataImportGroupID) -> CGFloat? {
        guard let indexPath = indexPathForGroup(groupID),
              let attributes = layoutAttributesForItem(at: indexPath) else {
            return nil
        }
        return attributes.frame.minY - contentOffset.y
    }

    /// 调整 contentOffset，使收起或展开后的分组标题仍停留在原屏幕位置。
    func restoreAnchor(for groupID: DataImportGroupID, screenY: CGFloat?) {
        guard let screenY,
              let indexPath = indexPathForGroup(groupID),
              let attributes = layoutAttributesForItem(at: indexPath) else {
            return
        }
        let proposedOffset = attributes.frame.minY - screenY
        let minimumOffset = -adjustedContentInset.top
        let maximumOffset = max(
            minimumOffset,
            contentSize.height - bounds.height + adjustedContentInset.bottom
        )
        setContentOffset(
            CGPoint(x: contentOffset.x, y: min(max(proposedOffset, minimumOffset), maximumOffset)),
            animated: false
        )
    }

    /// 返回当前分组标题在多 section 结构中的索引路径。
    func indexPathForGroup(_ groupID: DataImportGroupID) -> IndexPath? {
        guard let groupIndex = displayedGroups.firstIndex(where: { $0.id == groupID }) else {
            return nil
        }
        return IndexPath(item: 0, section: groupIndex)
    }

    /// 通过 VoiceOver 自定义动作移动完整分组，并立即提交最终顺序。
    func moveGroupForAccessibility(_ groupID: DataImportGroupID, offset: Int) {
        guard activePayload == nil,
              let sourceIndex = displayedGroups.firstIndex(where: { $0.id == groupID }) else {
            return
        }
        let destinationIndex = sourceIndex + offset
        guard displayedGroups.indices.contains(destinationIndex) else { return }
        let group = displayedGroups.remove(at: sourceIndex)
        displayedGroups.insert(group, at: destinationIndex)
        performBatchUpdates {
            self.moveSection(sourceIndex, toSection: destinationIndex)
        } completion: { [weak self] _ in
            guard let self else { return }
            self.updateVisibleCells()
            self.adoptDisplayedGroupsAsConfigurationBaseline()
            self.configuration.onCommitGroupOrder(self.displayedGroups.map(\.id))
            UIAccessibility.post(
                notification: .announcement,
                argument: "已移至第 \(destinationIndex + 1) 组"
            )
        }
    }

    /// 通过 VoiceOver 自定义动作在原分组内移动条目，并立即提交最终顺序。
    func moveEntryForAccessibility(
        _ groupID: DataImportGroupID,
        entryID: String,
        offset: Int
    ) {
        guard activePayload == nil,
              let groupIndex = displayedGroups.firstIndex(where: { $0.id == groupID }),
              let sourceIndex = displayedGroups[groupIndex].entries
                .firstIndex(where: { $0.id == entryID }) else {
            return
        }
        let destinationIndex = sourceIndex + offset
        guard displayedGroups[groupIndex].entries.indices.contains(destinationIndex) else { return }
        let entry = displayedGroups[groupIndex].entries.remove(at: sourceIndex)
        displayedGroups[groupIndex].entries.insert(entry, at: destinationIndex)
        performBatchUpdates {
            self.moveItem(
                at: IndexPath(item: sourceIndex + 1, section: groupIndex),
                to: IndexPath(item: destinationIndex + 1, section: groupIndex)
            )
        } completion: { [weak self] _ in
            guard let self else { return }
            self.updateVisibleCells()
            self.adoptDisplayedGroupsAsConfigurationBaseline()
            let orderedIDs = self.displayedGroups[groupIndex].entries.map(\.id)
            self.configuration.onCommitEntryOrder(groupID, orderedIDs)
            UIAccessibility.post(
                notification: .announcement,
                argument: "已移至第 \(destinationIndex + 1) 项"
            )
        }
    }
}

extension DataImportCollectionHostView: UICollectionViewDataSource {
    /// 始终以一个业务分组对应一个 section，收起态只改变 section 内项目数量。
    func numberOfSections(in collectionView: UICollectionView) -> Int {
        displayedGroups.count
    }

    /// 收起态每组只保留标题项；展开态在标题后返回全部导入入口。
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        guard displayedGroups.indices.contains(section) else { return 0 }
        return areEntriesCollapsed ? 1 : displayedGroups[section].entries.count + 1
    }

    /// 创建并配置分组标题或条目行。
    func collectionView(
        _ collectionView: UICollectionView,
        cellForItemAt indexPath: IndexPath
    ) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: DataImportCollectionCell.reuseIdentifier,
            for: indexPath
        ) as? DataImportCollectionCell else {
            return UICollectionViewCell()
        }
        configure(cell, at: indexPath)
        applyVisualOwnership(to: cell, at: indexPath)
        return cell
    }

    /// 分组由浮动代理移动 section；原生 interactive movement 只处理组内多条目排序。
    func collectionView(_ collectionView: UICollectionView, canMoveItemAt indexPath: IndexPath) -> Bool {
        guard configuration.isEditing,
              let itemID = itemID(at: indexPath),
              case .entry(let groupID, _) = itemID else {
            return false
        }
        return (displayedGroups.first(where: { $0.id == groupID })?.entries.count ?? 0) > 1
    }

    /// 响应 UIKit 条目 interactive movement，并同步唯一的本地排序模型。
    func collectionView(
        _ collectionView: UICollectionView,
        moveItemAt sourceIndexPath: IndexPath,
        to destinationIndexPath: IndexPath
    ) {
        guard sourceIndexPath.section == destinationIndexPath.section,
              displayedGroups.indices.contains(sourceIndexPath.section),
              sourceIndexPath.item > 0,
              destinationIndexPath.item > 0 else {
            return
        }
        let groupIndex = sourceIndexPath.section
        let sourceEntryIndex = sourceIndexPath.item - 1
        let destinationEntryIndex = destinationIndexPath.item - 1
        guard displayedGroups[groupIndex].entries.indices.contains(sourceEntryIndex),
              displayedGroups[groupIndex].entries.indices.contains(destinationEntryIndex) else {
            return
        }
        let entry = displayedGroups[groupIndex].entries.remove(at: sourceEntryIndex)
        displayedGroups[groupIndex].entries.insert(entry, at: destinationEntryIndex)
    }
}

extension DataImportCollectionHostView: UICollectionViewDelegate {
    /// cell 即将进入视口时再次按业务 ID 应用视觉所有权，覆盖复用带来的默认显露。
    func collectionView(
        _ collectionView: UICollectionView,
        willDisplay cell: UICollectionViewCell,
        forItemAt indexPath: IndexPath
    ) {
        guard let cell = cell as? DataImportCollectionCell else { return }
        applyVisualOwnership(to: cell, at: indexPath)
    }

    /// 普通态点击条目才进入导入流程；编辑态与分组标题都不承担导航。
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        collectionView.deselectItem(at: indexPath, animated: true)
        guard !configuration.isEditing,
              indexPath.item > 0,
              displayedGroups.indices.contains(indexPath.section) else {
            return
        }
        let entryIndex = indexPath.item - 1
        let group = displayedGroups[indexPath.section]
        guard group.entries.indices.contains(entryIndex) else { return }
        configuration.onOpen(group.entries[entryIndex].destination)
    }

    /// 条目移动严格限制在原分组且不能占用标题位置。
    func collectionView(
        _ collectionView: UICollectionView,
        targetIndexPathForMoveFromItemAt originalIndexPath: IndexPath,
        toProposedIndexPath proposedIndexPath: IndexPath
    ) -> IndexPath {
        guard originalIndexPath.section == proposedIndexPath.section,
              displayedGroups.indices.contains(originalIndexPath.section) else {
            return originalIndexPath
        }
        let maximumItem = displayedGroups[originalIndexPath.section].entries.count
        let item = min(max(proposedIndexPath.item, 1), maximumItem)
        return IndexPath(item: item, section: originalIndexPath.section)
    }
}

/// 使用 SwiftUI 内容配置的集合行，统一管理高亮、44pt 把手命中和 VoiceOver 自定义动作。
private final class DataImportCollectionCell: UICollectionViewCell {
    static let reuseIdentifier = "DataImportCollectionCell"
    private(set) var showsReorderHandle = false
    let reorderHandleWidth = InteractionMetrics.minimumTouchTarget
    private let compactChromeHostingController = UIHostingController(
        rootView: DataImportGroupCompactChrome(
            itemCount: 0,
            isEditing: false,
            isDropTarget: false
        )
    )
    private var allowsHighlight = false
    private var isContentSuppressed = false
    private var compactProgress: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        let compactChromeView = compactChromeHostingController.view
        compactChromeView?.backgroundColor = .clear
        compactChromeView?.isUserInteractionEnabled = false
        compactChromeView?.alpha = 0
        backgroundView = compactChromeView
        configurationUpdateHandler = { [weak self] cell, state in
            guard let self else { return }
            if self.isContentSuppressed {
                cell.contentView.alpha = 0
            } else {
                cell.contentView.alpha = self.allowsHighlight && state.isHighlighted ? 0.62 : 1
            }
            self.updateCompactChromeVisibility()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 复用前清空可访问动作与交互标记，防止跨类型行残留。
    override func prepareForReuse() {
        super.prepareForReuse()
        removeVisualAnimations()
        showsReorderHandle = false
        allowsHighlight = false
        isContentSuppressed = false
        compactProgress = 0
        accessibilityCustomActions = nil
        contentConfiguration = nil
        contentView.alpha = 1
        compactChromeHostingController.view.alpha = 0
        alpha = 1
        transform = .identity
    }

    /// 清除 cell、内容与紧凑附属层的 presentation 动画，供复用和会话收口统一归一。
    func removeVisualAnimations() {
        layer.removeAllAnimations()
        contentView.layer.removeAllAnimations()
        backgroundView?.layer.removeAllAnimations()
        compactChromeHostingController.view.layer.removeAllAnimations()
    }

    /// 仅隐藏内容而保留 cell 几何，使活动分组始终只由浮动代理绘制。
    func setContentSuppressed(_ isSuppressed: Bool) {
        guard isContentSuppressed != isSuppressed else { return }
        isContentSuppressed = isSuppressed
        setNeedsUpdateConfiguration()
        contentView.alpha = isSuppressed ? 0 : 1
        updateCompactChromeVisibility()
    }

    /// 只改变紧凑卡片与数量附属层，标题和把手不参与交叉淡变。
    func setCompactProgress(_ progress: CGFloat) {
        compactProgress = min(max(progress, 0), 1)
        updateCompactChromeVisibility()
    }

    /// 配置一级分组标题；收起态显示条目数量和卡片表层。
    func configureGroup(
        _ group: DataImportGroup,
        isEditing: Bool,
        isCompact: Bool,
        isDropTarget: Bool,
        moveUp: (() -> Bool)?,
        moveDown: (() -> Bool)?
    ) {
        showsReorderHandle = isEditing
        allowsHighlight = false
        contentConfiguration = UIHostingConfiguration {
            DataImportGroupRow(
                title: group.title,
                isEditing: isEditing,
                isCompactGeometry: isCompact
            )
            .accessibilityHidden(true)
        }
        .margins(.all, 0)
        compactChromeHostingController.rootView = DataImportGroupCompactChrome(
            itemCount: group.entries.count,
            isEditing: isEditing,
            isDropTarget: isDropTarget
        )
        isAccessibilityElement = true
        accessibilityLabel = String(localized: group.title)
        accessibilityValue = "\(group.entries.count) 项"
        accessibilityHint = isEditing ? "拖动排序，或使用上移和下移动作" : nil
        accessibilityTraits = [.header]
        accessibilityCustomActions = Self.accessibilityMoveActions(
            moveUp: moveUp,
            moveDown: moveDown,
            upName: "上移分组",
            downName: "下移分组"
        )
    }

    /// 配置二级导入入口；普通态显示跳转箭头，编辑态仅在可排序时显示把手。
    func configureEntry(
        _ entry: DataImportEntry,
        isEditing: Bool,
        showsReorderHandle: Bool,
        isFirst: Bool,
        isLast: Bool,
        moveUp: (() -> Bool)?,
        moveDown: (() -> Bool)?
    ) {
        self.showsReorderHandle = showsReorderHandle
        allowsHighlight = !isEditing
        setCompactProgress(0)
        contentConfiguration = UIHostingConfiguration {
            DataImportEntryRow(
                title: entry.title,
                isEditing: isEditing,
                showsReorderHandle: showsReorderHandle,
                isFirst: isFirst,
                isLast: isLast
            )
            .accessibilityHidden(true)
        }
        .margins(.all, 0)
        isAccessibilityElement = true
        accessibilityLabel = String(localized: entry.title)
        accessibilityValue = nil
        accessibilityHint = isEditing ? "拖动排序，或使用上移和下移动作" : "打开导入任务"
        accessibilityTraits = isEditing ? [] : [.button]
        accessibilityCustomActions = Self.accessibilityMoveActions(
            moveUp: moveUp,
            moveDown: moveDown,
            upName: "上移",
            downName: "下移"
        )
        setNeedsUpdateConfiguration()
    }

    /// 统一应用紧凑附属层可见度，并让活动分组的真实 cell 始终完全隐身。
    private func updateCompactChromeVisibility() {
        compactChromeHostingController.view.alpha = isContentSuppressed ? 0 : compactProgress
    }

    /// 按当前边界组装 VoiceOver 上移与下移动作，不暴露不可执行操作。
    private static func accessibilityMoveActions(
        moveUp: (() -> Bool)?,
        moveDown: (() -> Bool)?,
        upName: String,
        downName: String
    ) -> [UIAccessibilityCustomAction]? {
        var actions: [UIAccessibilityCustomAction] = []
        if let moveUp {
            actions.append(UIAccessibilityCustomAction(name: upName) { _ in moveUp() })
        }
        if let moveDown {
            actions.append(UIAccessibilityCustomAction(name: downName) { _ in moveDown() })
        }
        return actions.isEmpty ? nil : actions
    }
}

/// 分组标题和把手始终只有一份；布局高度独立于卡片与数量的透明度。
private struct DataImportGroupRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let title: LocalizedStringResource
    let isEditing: Bool
    let isCompactGeometry: Bool

    var body: some View {
        HStack(spacing: Spacing.cozy) {
            Text(title)
                .font(AppTypography.headline)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 2 : 1)
            Spacer(minLength: Spacing.cozy)
            if isEditing {
                reorderHandle
            }
        }
        .padding(.leading, Spacing.screenEdge)
        .frame(
            minHeight: isCompactGeometry
                ? DataImportCollectionMetrics.compactGroupMinimumHeight
                : DataImportCollectionMetrics.groupHeaderMinimumHeight
        )
        .contentShape(Rectangle())
    }

    private var reorderHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(AppTypography.subheadlineSemibold)
            .foregroundStyle(Color.iconPrimary)
            .frame(
                width: InteractionMetrics.minimumTouchTarget
            )
            .frame(minHeight: InteractionMetrics.minimumTouchTarget)
            .accessibilityHidden(true)
    }
}

/// 紧凑态附属层只绘制卡片、数量和可选描边，由 UIKit alpha 与几何动画共用同一时钟。
private struct DataImportGroupCompactChrome: View {
    let itemCount: Int
    let isEditing: Bool
    let isDropTarget: Bool

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                .fill(Color.surfaceCard)
            if isDropTarget {
                RoundedRectangle(cornerRadius: CornerRadius.blockMedium, style: .continuous)
                    .stroke(Color.surfaceBorderStrong, lineWidth: StrokeWidth.hairline)
            }
            HStack(spacing: Spacing.cozy) {
                Spacer(minLength: Spacing.cozy)
                Text("\(itemCount) 项")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
                    .fixedSize(horizontal: true, vertical: false)
                if isEditing {
                    Color.clear
                        .frame(width: InteractionMetrics.minimumTouchTarget)
                        .frame(minHeight: InteractionMetrics.minimumTouchTarget)
                }
            }
            .padding(.leading, Spacing.screenEdge)
        }
    }
}

/// 52pt 基线的导入入口行，按首尾位置组成 grouped-card 并在编辑态切换中性把手。
private struct DataImportEntryRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.displayScale) private var displayScale
    let title: LocalizedStringResource
    let isEditing: Bool
    let showsReorderHandle: Bool
    let isFirst: Bool
    let isLast: Bool

    var body: some View {
        HStack(spacing: Spacing.cozy) {
            Text(title)
                .font(AppTypography.body)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? 3 : 1)
            Spacer(minLength: Spacing.cozy)
            if isEditing, showsReorderHandle {
                reorderHandle
            } else if !isEditing {
                Image(systemName: "chevron.forward")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.iconSecondary)
                    .frame(
                        width: InteractionMetrics.minimumTouchTarget
                    )
                    .frame(minHeight: InteractionMetrics.minimumTouchTarget)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, Spacing.screenEdge)
        .frame(minHeight: DataImportCollectionMetrics.entryMinimumHeight)
        .background(Color.surfaceCard)
        .overlay(alignment: .bottom) {
            if !isLast {
                Rectangle()
                    .fill(Color.surfaceDividerSubtle)
                    .frame(height: 1 / max(displayScale, 1))
                    .padding(.leading, Spacing.screenEdge)
            }
        }
        .clipShape(cardShape)
        .contentShape(Rectangle())
    }

    private var reorderHandle: some View {
        Image(systemName: "line.3.horizontal")
            .font(AppTypography.subheadlineSemibold)
            .foregroundStyle(Color.iconSecondary)
            .frame(
                width: InteractionMetrics.minimumTouchTarget
            )
            .frame(minHeight: InteractionMetrics.minimumTouchTarget)
            .accessibilityHidden(true)
    }

    private var cardShape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
            topLeadingRadius: isFirst ? CornerRadius.blockMedium : 0,
            bottomLeadingRadius: isLast ? CornerRadius.blockMedium : 0,
            bottomTrailingRadius: isLast ? CornerRadius.blockMedium : 0,
            topTrailingRadius: isFirst ? CornerRadius.blockMedium : 0,
            style: .continuous
        )
    }
}

/// 分组拖动的唯一浮动代理；标题与把手全程只有一份，紧凑元数据独立渐隐。
private final class DataImportGroupDragProxyView: UIView {
    private let chromeHostingController: UIHostingController<DataImportGroupCompactChrome>
    private let identityHostingController: UIHostingController<DataImportGroupRow>

    /// 创建单一 SwiftUI 层级，并让代理尺寸始终由外部几何状态机控制。
    init(group: DataImportGroup, frame: CGRect) {
        chromeHostingController = UIHostingController(
            rootView: DataImportGroupCompactChrome(
                itemCount: group.entries.count,
                isEditing: true,
                isDropTarget: false
            )
        )
        identityHostingController = UIHostingController(
            rootView: DataImportGroupRow(
                title: group.title,
                isEditing: true,
                isCompactGeometry: false
            )
        )
        super.init(frame: frame)
        isUserInteractionEnabled = false
        backgroundColor = .clear
        clipsToBounds = false

        guard let chromeView = chromeHostingController.view,
              let identityView = identityHostingController.view else {
            return
        }
        chromeView.backgroundColor = .clear
        chromeView.alpha = 0
        identityView.backgroundColor = .clear
        [chromeView, identityView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
            addSubview($0)
        }
        NSLayoutConstraint.activate([
            chromeView.leadingAnchor.constraint(equalTo: leadingAnchor),
            chromeView.trailingAnchor.constraint(equalTo: trailingAnchor),
            chromeView.topAnchor.constraint(equalTo: topAnchor),
            chromeView.bottomAnchor.constraint(equalTo: bottomAnchor),
            identityView.leadingAnchor.constraint(equalTo: leadingAnchor),
            identityView.trailingAnchor.constraint(equalTo: trailingAnchor),
            identityView.topAnchor.constraint(equalTo: topAnchor),
            identityView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 只动画紧凑元数据，标题与把手保持同一 SwiftUI 身份。
    func setCompactProgress(_ progress: CGFloat) {
        chromeHostingController.view.alpha = min(max(progress, 0), 1)
    }
}

/// 书摘导入页面私有尺寸与动效参数，避免将单场景数值提升为全局令牌。
private enum DataImportCollectionMetrics {
    static let groupHeaderMinimumHeight: CGFloat = 40
    static let compactGroupMinimumHeight: CGFloat = 52
    static let entryMinimumHeight: CGFloat = 52
    static let entryDepartureDuration: TimeInterval = 0.10
    static let collapseDuration: TimeInterval = 0.18
    static let sectionMoveDuration: TimeInterval = 0.18
    static let snapDuration: TimeInterval = 0.16
    static let expandDuration: TimeInterval = 0.28
    static let entrySettleDuration: TimeInterval = 0.16
    static let reduceMotionFadeDuration: TimeInterval = 0.10
    static let presentationDuration: TimeInterval = 0.16
    static let entryTransitionTravel: CGFloat = 10
    static let entryDepartureTravel: CGFloat = 4
    static let finishDurationFactor: CGFloat = 0.35
    static let sectionMoveHysteresis: CGFloat = 7
}
