/**
 * [INPUT]: 依赖 SwiftUI/UIKit/Nuke 与 XMImageRequestBuilder，依赖 DesignTokens 提供尺寸、圆角与颜色语义
 * [OUTPUT]: 对外提供 XMAttachmentUploadItem、XMAttachmentUploadState、XMAttachmentUploadStrip、XMAttachmentUploadPreviewMapper
 * [POS]: UIComponents/Foundation 通用附图上传条组件，统一承接上传态展示、长按拖拽排序、删除/重试与可选全屏预览交互
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit
import Nuke
import ImageIO
import os

/// 附图上传条交互策略：按钮点击优先，按钮区域不触发重排手势。
enum XMAttachmentUploadInteractionPolicy {
    /// 是否允许从当前触点开启长按重排。
    static func shouldBeginReorder(from touchedView: UIView?) -> Bool {
        nearestControl(from: touchedView) == nil
    }

    /// 是否允许在当前位置开启长按重排；保护区内触点必须优先交给按钮点击。
    static func shouldBeginReorder(at location: CGPoint, protectedFrames: [CGRect]) -> Bool {
        !protectedFrames.contains { $0.contains(location) }
    }

    private static func nearestControl(from view: UIView?) -> UIControl? {
        var cursor = view
        while let current = cursor {
            if let control = current as? UIControl {
                return control
            }
            cursor = current.superview
        }
        return nil
    }
}

/// 附图预览映射策略，负责生成可预览数据与稳定索引映射。
enum XMAttachmentUploadPreviewMapper {
    struct Result: Equatable {
        let previewItems: [XMJXGalleryItem]
        let previewIndexByItemID: [String: Int]
        let duplicateIDs: [String]
    }

    /// 从上传条条目生成预览所需模型与索引映射。
    static func makeResult(from items: [XMAttachmentUploadItem]) -> Result {
        let previewItems = items.compactMap { item -> XMJXGalleryItem? in
            let localSource = normalizedSource(item.localFilePath)
            let remoteSource = normalizedSource(item.remoteURL)
            let thumbnailSource = localSource ?? remoteSource
            let originalSource = remoteSource ?? localSource
            guard let thumbnailSource, let originalSource else { return nil }
            return XMJXGalleryItem(
                id: item.id,
                thumbnailURL: thumbnailSource,
                originalURL: originalSource
            )
        }

        var previewIndexByItemID: [String: Int] = [:]
        var duplicateIDs = Set<String>()
        for (index, item) in previewItems.enumerated() {
            if previewIndexByItemID[item.id] == nil {
                previewIndexByItemID[item.id] = index
            } else {
                duplicateIDs.insert(item.id)
            }
        }

        return Result(
            previewItems: previewItems,
            previewIndexByItemID: previewIndexByItemID,
            duplicateIDs: duplicateIDs.sorted()
        )
    }

    /// 标准化预览图源；无法被图片请求层识别时返回 nil。
    static func normalizedSource(_ source: String?) -> String? {
        guard let source,
              XMImageRequestBuilder.normalizedURL(from: source) != nil else {
            return nil
        }
        return source
    }
}

/// 附图渲染源，描述当前条目应采用的缩略图加载通道。
enum XMAttachmentUploadRenderSource: Equatable {
    case local(path: String)
    case remote(url: URL)
    case none
}

/// 附图渲染源解析器：本地可用优先，本地不可用自动回退远端。
enum XMAttachmentUploadRenderSourceResolver {
    /// 解析最终渲染源；仅当本地路径真实存在时才走本地分支。
    static func resolve(
        localFilePath: String?,
        remoteURL: String?,
        fileExists: (String) -> Bool = { path in
            FileManager.default.fileExists(atPath: path)
        }
    ) -> XMAttachmentUploadRenderSource {
        if let normalizedLocalPath = normalizedLocalPath(localFilePath),
           fileExists(normalizedLocalPath) {
            return .local(path: normalizedLocalPath)
        }

        if let normalizedRemoteURL = normalizedRemoteURL(remoteURL) {
            return .remote(url: normalizedRemoteURL)
        }

        return .none
    }

    /// 当本地解码失败时，尝试回退远端地址。
    static func fallbackRemoteURL(from remoteURL: String?) -> URL? {
        normalizedRemoteURL(remoteURL)
    }

    private static func normalizedLocalPath(_ rawPath: String?) -> String? {
        guard let rawPath else { return nil }
        let trimmedPath = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPath.isEmpty else { return nil }
        return trimmedPath
    }

    private static func normalizedRemoteURL(_ rawRemoteURL: String?) -> URL? {
        guard let rawRemoteURL else { return nil }
        return XMImageRequestBuilder.normalizedURL(from: rawRemoteURL)
    }
}

/// 附图上传状态，统一抽象“上传中 / 成功 / 失败”三态。
enum XMAttachmentUploadState: String, Hashable, Sendable {
    case uploading
    case success
    case failed
}

/// 通用附图条条目模型，兼容本地暂存路径与远端 URL。
struct XMAttachmentUploadItem: Identifiable, Hashable, Sendable {
    let id: String
    let localFilePath: String?
    let remoteURL: String?
    let uploadState: XMAttachmentUploadState
}

/// 附图上传条文案配置，支持组件跨业务复用时按场景自定义语义。
struct XMAttachmentUploadStripStrings: Hashable, Sendable {
    let retryTitle: String
    let removeAccessibilityLabel: String
    let removeAccessibilityHint: String
    let retryAccessibilityLabel: String
    let retryAccessibilityHint: String

    static let `default` = XMAttachmentUploadStripStrings(
        retryTitle: "重试",
        removeAccessibilityLabel: "删除图片",
        removeAccessibilityHint: "从附图列表中移除当前图片",
        retryAccessibilityLabel: "重试上传",
        retryAccessibilityHint: "重新上传当前图片"
    )
}

/// 通用附图上传条 SwiftUI 入口，内部由 UIKit UICollectionView 承接重排与手势交互。
struct XMAttachmentUploadStrip: UIViewRepresentable {
    let items: [XMAttachmentUploadItem]
    let itemSide: CGFloat
    let itemSpacing: CGFloat
    let contentInsets: UIEdgeInsets
    let showsRemoveButton: Bool
    let allowsFullScreenPreview: Bool
    let accessibilityNamespace: String
    let strings: XMAttachmentUploadStripStrings
    let onMove: (_ sourceID: String, _ destinationID: String) -> Void
    let onRemove: (_ id: String) -> Void
    let onRequestRemove: ((_ id: String, _ completion: @escaping (Bool) -> Void) -> Void)?
    let onRetry: (_ id: String) -> Void
    let onTap: ((_ id: String) -> Void)?

    /// 初始化附图上传条参数，默认保持与书摘编辑页视觉尺寸一致。
    init(
        items: [XMAttachmentUploadItem],
        itemSide: CGFloat = 84,
        itemSpacing: CGFloat = Spacing.cozy,
        contentInsets: UIEdgeInsets = .zero,
        showsRemoveButton: Bool = true,
        allowsFullScreenPreview: Bool = false,
        accessibilityNamespace: String = "xm_attachment_upload_strip",
        strings: XMAttachmentUploadStripStrings = .default,
        onMove: @escaping (_ sourceID: String, _ destinationID: String) -> Void,
        onRemove: @escaping (_ id: String) -> Void,
        onRequestRemove: ((_ id: String, _ completion: @escaping (Bool) -> Void) -> Void)? = nil,
        onRetry: @escaping (_ id: String) -> Void,
        onTap: ((_ id: String) -> Void)? = nil
    ) {
        self.items = items
        self.itemSide = itemSide
        self.itemSpacing = itemSpacing
        self.contentInsets = contentInsets
        self.showsRemoveButton = showsRemoveButton
        self.allowsFullScreenPreview = allowsFullScreenPreview
        self.accessibilityNamespace = accessibilityNamespace
        self.strings = strings
        self.onMove = onMove
        self.onRemove = onRemove
        self.onRequestRemove = onRequestRemove
        self.onRetry = onRetry
        self.onTap = onTap
    }

    /// 创建 UIKit 承载视图并注入首帧数据。
    func makeUIView(context: Context) -> XMAttachmentUploadStripView {
        let view = XMAttachmentUploadStripView()
        view.update(
            with: .init(
                items: items,
                itemSide: itemSide,
                itemSpacing: itemSpacing,
                contentInsets: contentInsets,
                showsRemoveButton: showsRemoveButton,
                allowsFullScreenPreview: allowsFullScreenPreview,
                accessibilityNamespace: accessibilityNamespace,
                strings: strings,
                onMove: onMove,
                onRemove: onRemove,
                onRequestRemove: onRequestRemove,
                onRetry: onRetry,
                onTap: onTap
            ),
            animated: false
        )
        return view
    }

    /// 同步 SwiftUI 新状态到 UIKit 视图。
    func updateUIView(_ uiView: XMAttachmentUploadStripView, context: Context) {
        uiView.update(
            with: .init(
                items: items,
                itemSide: itemSide,
                itemSpacing: itemSpacing,
                contentInsets: contentInsets,
                showsRemoveButton: showsRemoveButton,
                allowsFullScreenPreview: allowsFullScreenPreview,
                accessibilityNamespace: accessibilityNamespace,
                strings: strings,
                onMove: onMove,
                onRemove: onRemove,
                onRequestRemove: onRequestRemove,
                onRetry: onRetry,
                onTap: onTap
            ),
            animated: true
        )
    }

    /// 销毁前清理异步任务与手势状态，避免复用残留。
    static func dismantleUIView(_ uiView: XMAttachmentUploadStripView, coordinator: ()) {
        uiView.prepareForReuse()
    }
}

/// UIKit 内部配置模型，统一承接 SwiftUI 层传入参数。
fileprivate struct XMAttachmentUploadStripConfiguration {
    let items: [XMAttachmentUploadItem]
    let itemSide: CGFloat
    let itemSpacing: CGFloat
    let contentInsets: UIEdgeInsets
    let showsRemoveButton: Bool
    let allowsFullScreenPreview: Bool
    let accessibilityNamespace: String
    let strings: XMAttachmentUploadStripStrings
    let onMove: (_ sourceID: String, _ destinationID: String) -> Void
    let onRemove: (_ id: String) -> Void
    let onRequestRemove: ((_ id: String, _ completion: @escaping (Bool) -> Void) -> Void)?
    let onRetry: (_ id: String) -> Void
    let onTap: ((_ id: String) -> Void)?
}

/// UIKit 承载视图，负责横向列表布局、拖拽排序与条目更新编排。
final class XMAttachmentUploadStripView: UIView {
    /// InteractionPhase 负责当前场景的enum定义，明确职责边界并组织相关能力。
    private enum InteractionPhase: Equatable {
        case idle
        case trackingControl
        case reordering
        case removing(id: String)
    }

    private var configuration = XMAttachmentUploadStripConfiguration(
        items: [],
        itemSide: 84,
        itemSpacing: Spacing.cozy,
        contentInsets: .zero,
        showsRemoveButton: true,
        allowsFullScreenPreview: false,
        accessibilityNamespace: "xm_attachment_upload_strip",
        strings: .default,
        onMove: { _, _ in },
        onRemove: { _ in },
        onRequestRemove: nil,
        onRetry: { _ in },
        onTap: nil
    )

    private var items: [XMAttachmentUploadItem] = []
    private var pendingConfiguration: XMAttachmentUploadStripConfiguration?
    private var isInteractiveReordering = false
    private var didCommitMoveInCurrentSession = false
    private var trackingControlIDs: Set<String> = []
    private var pendingRemoveID: String?
    private var interactionPhase: InteractionPhase = .idle
    private var previewIndexByItemID: [String: Int] = [:]
    private var previewTapSequence = 0
    private weak var liftedCell: XMAttachmentUploadCell?
    private let previewHost = XMJXPhotoBrowserHost(initialItems: [])

    private let impactFeedback = UIImpactFeedbackGenerator(style: .medium)
    private let removeFeedback = UIImpactFeedbackGenerator(style: .light)
    private let selectionFeedback = UISelectionFeedbackGenerator()
#if DEBUG
    fileprivate static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "xmnote",
        category: "AttachmentUploadStrip"
    )
#endif

    private var hasActiveControlTracking: Bool {
        !trackingControlIDs.isEmpty
    }

    private lazy var layout: UICollectionViewFlowLayout = {
        let layout = UICollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.minimumLineSpacing = Spacing.cozy
        layout.minimumInteritemSpacing = Spacing.cozy
        layout.itemSize = CGSize(width: 84, height: 84)
        return layout
    }()

    private lazy var collectionView: UICollectionView = {
        let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
        view.backgroundColor = .clear
        view.showsHorizontalScrollIndicator = false
        view.alwaysBounceHorizontal = true
        view.clipsToBounds = false
        view.delaysContentTouches = false
        view.dragInteractionEnabled = true
        view.reorderingCadence = .immediate
        view.dataSource = self
        view.delegate = self
        view.dragDelegate = self
        view.dropDelegate = self
        view.register(XMAttachmentUploadCell.self, forCellWithReuseIdentifier: XMAttachmentUploadCell.reuseIdentifier)
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

    override var intrinsicContentSize: CGSize {
        let height = configuration.itemSide + configuration.contentInsets.top + configuration.contentInsets.bottom
        return CGSize(width: UIView.noIntrinsicMetric, height: height)
    }

    /// 同步新配置到列表；拖拽进行中会先缓存，待拖拽结束再落盘。
    fileprivate func update(with configuration: XMAttachmentUploadStripConfiguration, animated: Bool) {
        if isInteractiveReordering {
            pendingConfiguration = configuration
            return
        }

        let previousIDs = items.map(\.id)
        let nextIDs = configuration.items.map(\.id)

        self.configuration = configuration
        applyLayoutConfiguration()
        syncPreviewState(with: configuration.items)

        if previousIDs == nextIDs {
            items = configuration.items
            refreshVisibleCells(animated: true)
            return
        }

        let applied = applyStructuralDiffUpdate(
            from: previousIDs,
            to: nextIDs,
            nextItems: configuration.items,
            animated: animated
        )
        if !applied {
            items = configuration.items
            collectionView.reloadData()
            refreshVisibleCells(animated: true)
        }
    }

    /// 释放内部状态，供 SwiftUI 视图销毁时调用。
    func prepareForReuse() {
        pendingConfiguration = nil
        isInteractiveReordering = false
        didCommitMoveInCurrentSession = false
        trackingControlIDs.removeAll()
        pendingRemoveID = nil
        interactionPhase = .idle
        previewIndexByItemID.removeAll()
        previewTapSequence = 0
        previewHost.updateItems([])
        previewHost.registry.setAllVisible()
        liftedCell?.setLifted(false, animated: false)
        liftedCell = nil
        collectionView.visibleCells
            .compactMap { $0 as? XMAttachmentUploadCell }
            .forEach { $0.cancelImageLoading() }
    }
}

private extension XMAttachmentUploadStripView {
    /// 执行resolveInteractionPhase对应的数据处理步骤，并返回当前流程需要的结果。
    private func resolveInteractionPhase() -> InteractionPhase {
        if let pendingRemoveID {
            return .removing(id: pendingRemoveID)
        }
        if isInteractiveReordering {
            return .reordering
        }
        if !trackingControlIDs.isEmpty {
            return .trackingControl
        }
        return .idle
    }

    /// 处理syncInteractionPhase对应的状态流转，确保交互过程与数据状态保持一致。
    private func syncInteractionPhase() {
        interactionPhase = resolveInteractionPhase()
    }

    /// 封装configureCell对应的业务步骤，确保调用方可以稳定复用该能力。
    private func configureCell(_ cell: XMAttachmentUploadCell, at indexPath: IndexPath, animated: Bool) {
        guard items.indices.contains(indexPath.item) else { return }
        let item = items[indexPath.item]
        let thumbnailRegistry = configuration.allowsFullScreenPreview ? previewHost.registry : nil
        cell.configure(
            item: item,
            showsRemoveButton: configuration.showsRemoveButton,
            onRemove: { [weak self] id in
                self?.handleRemoveRequested(id: id)
            },
            onRetry: { [weak self] id in
#if DEBUG
                Self.logger.debug("strip.onRetry id=\(id, privacy: .public)")
#endif
                self?.configuration.onRetry(id)
            },
            onControlTrackingChanged: { [weak self] id, isTracking in
                self?.setControlTracking(id: id, isTracking: isTracking)
            },
            thumbnailRegistry: thumbnailRegistry,
            accessibilityNamespace: configuration.accessibilityNamespace,
            strings: configuration.strings,
            animated: animated
        )
    }

    /// 搭建子视图结构并绑定拖拽能力。
    func setupViewHierarchy() {
        addSubview(collectionView)
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.accessibilityIdentifier = "\(configuration.accessibilityNamespace).collection"

        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    /// 应用 item 尺寸、间距与内边距配置。
    func applyLayoutConfiguration() {
        layout.itemSize = CGSize(width: configuration.itemSide, height: configuration.itemSide)
        layout.minimumLineSpacing = configuration.itemSpacing
        layout.minimumInteritemSpacing = configuration.itemSpacing
        collectionView.contentInset = configuration.contentInsets
        collectionView.accessibilityIdentifier = "\(configuration.accessibilityNamespace).collection"
        invalidateIntrinsicContentSize()
    }

    /// 刷新可见 cell，避免全量 reload 造成滚动位置与手势状态抖动。
    func refreshVisibleCells(animated: Bool) {
        for cell in collectionView.visibleCells {
            guard let indexPath = collectionView.indexPath(for: cell),
                  let attachmentCell = cell as? XMAttachmentUploadCell else {
                continue
            }
            configureCell(attachmentCell, at: indexPath, animated: animated)
        }
    }

    /// 同步全屏预览数据源与 itemID 到浏览索引映射。
    func syncPreviewState(with items: [XMAttachmentUploadItem]) {
        guard configuration.allowsFullScreenPreview else {
            previewIndexByItemID.removeAll()
            previewHost.updateItems([])
            previewHost.registry.setAllVisible()
            return
        }

        let result = XMAttachmentUploadPreviewMapper.makeResult(from: items)
        previewIndexByItemID = result.previewIndexByItemID
        previewHost.updateItems(result.previewItems)
#if DEBUG
        if !result.duplicateIDs.isEmpty {
            let duplicateText = result.duplicateIDs.joined(separator: ",")
            Self.logger.error("preview.duplicate_ids ids=[\(duplicateText, privacy: .public)]")
        }
#endif
    }

    /// 收束拖拽结束状态并回放待处理配置。
    func finishInteractiveReorder(cancelled: Bool) {
        isInteractiveReordering = false
        didCommitMoveInCurrentSession = false
        syncInteractionPhase()
        liftedCell?.setLifted(false, animated: true)
        liftedCell = nil

        if !cancelled {
            selectionFeedback.selectionChanged()
        }
#if DEBUG
        Self.logger.debug("reorder.end cancelled=\(cancelled, privacy: .public)")
#endif

        if let pendingConfiguration {
            self.pendingConfiguration = nil
            update(with: pendingConfiguration, animated: false)
        }
    }
}

private extension XMAttachmentUploadStripView {
    /// 汇总当前可见 cell 的按钮保护区，用于重排触发前置拦截。
    func protectedControlFrames() -> [CGRect] {
        collectionView.visibleCells
            .compactMap { $0 as? XMAttachmentUploadCell }
            .flatMap { $0.protectedControlFrames(in: collectionView) }
    }

    /// 判断当前触点是否允许进入重排会话，按钮追踪期间必须阻断重排。
    func canBeginReorder(at location: CGPoint) -> Bool {
        guard interactionPhase == .idle, !hasActiveControlTracking else {
#if DEBUG
            Self.logger.debug("reorder.blocked reason=control_tracking_active")
#endif
            return false
        }
        guard XMAttachmentUploadInteractionPolicy.shouldBeginReorder(
            at: location,
            protectedFrames: protectedControlFrames()
        ) else {
#if DEBUG
            Self.logger.debug("reorder.blocked reason=protected_control_area")
#endif
            return false
        }
        guard XMAttachmentUploadInteractionPolicy.shouldBeginReorder(
            from: collectionView.hitTest(location, with: nil)
        ) else {
#if DEBUG
            Self.logger.debug("reorder.blocked reason=control_view_hittest")
#endif
            return false
        }
        return true
    }

    /// 记录每个条目的控件追踪状态，避免并发触控时提前解锁拖拽。
    func setControlTracking(id: String, isTracking: Bool) {
        guard !id.isEmpty else { return }
        if isTracking {
            trackingControlIDs.insert(id)
        } else {
            trackingControlIDs.remove(id)
        }
        syncInteractionPhase()
    }

    /// 记录并启动重排会话 UI 状态。
    func beginReorderSession(at indexPath: IndexPath) {
        guard !isInteractiveReordering, interactionPhase == .idle else { return }
        isInteractiveReordering = true
        didCommitMoveInCurrentSession = false
        syncInteractionPhase()
        impactFeedback.prepare()
        impactFeedback.impactOccurred(intensity: 0.88)
        selectionFeedback.prepare()
        if let cell = collectionView.cellForItem(at: indexPath) as? XMAttachmentUploadCell {
            liftedCell = cell
            cell.setLifted(true, animated: true)
        }
#if DEBUG
        Self.logger.debug("reorder.begin index=\(indexPath.item)")
#endif
    }

    /// 以与业务层一致的语义更新本地排序并抛出回调。
    func applyMove(from sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        guard items.indices.contains(sourceIndexPath.item),
              items.indices.contains(destinationIndexPath.item),
              sourceIndexPath.item != destinationIndexPath.item else {
            return
        }

        let sourceID = items[sourceIndexPath.item].id
        let destinationID = items[destinationIndexPath.item].id

        items.xmMove(from: sourceIndexPath.item, to: destinationIndexPath.item)
        syncPreviewState(with: items)
        configuration.onMove(sourceID, destinationID)
    }

    /// 对 drop 目标做边界归一化，保证 destination 永远落在有效区间。
    func normalizedDestinationIndexPath(for proposed: IndexPath?) -> IndexPath? {
        guard !items.isEmpty else { return nil }
        let proposedItem = proposed?.item ?? (items.count - 1)
        let clamped = min(max(0, proposedItem), items.count - 1)
        return IndexPath(item: clamped, section: 0)
    }

    /// 将结构变化转换为批量更新动画，失败时返回 false 以便上层回退 reloadData。
    func applyStructuralDiffUpdate(
        from previousIDs: [String],
        to nextIDs: [String],
        nextItems: [XMAttachmentUploadItem],
        animated: Bool
    ) -> Bool {
        guard Set(previousIDs).count == previousIDs.count,
              Set(nextIDs).count == nextIDs.count else {
            return false
        }
        guard animated else {
            items = nextItems
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
            self?.refreshVisibleCells(animated: true)
        }
        return true
    }

    /// 删除流程先执行退出动画，再将删除事件回调给上层，确保“目标消失 + 邻项补位”连贯。
    func handleRemoveRequested(id: String) {
        guard pendingRemoveID == nil else { return }
        pendingRemoveID = id
        trackingControlIDs.remove(id)
        syncInteractionPhase()

        guard let index = items.firstIndex(where: { $0.id == id }),
              let cell = collectionView.cellForItem(at: IndexPath(item: index, section: 0)) as? XMAttachmentUploadCell else {
            submitRemoveRequest(id: id) { [weak self] accepted in
                self?.pendingRemoveID = nil
                self?.syncInteractionPhase()
                if !accepted {
                    self?.trackingControlIDs.remove(id)
                }
            }
            return
        }

        removeFeedback.prepare()
        cell.animateRemovalExit(reduceMotion: UIAccessibility.isReduceMotionEnabled) { [weak self, weak cell] in
            guard let self else { return }
            self.removeFeedback.impactOccurred(intensity: 0.72)
            self.submitRemoveRequest(id: id) { [weak self, weak cell] accepted in
                guard let self else { return }
                self.pendingRemoveID = nil
                self.syncInteractionPhase()
                if accepted {
                    return
                }
                self.trackingControlIDs.remove(id)
                self.syncInteractionPhase()
                cell?.animateRemovalRollback(reduceMotion: UIAccessibility.isReduceMotionEnabled)
            }
        }
    }

    /// 统一封装删除请求回调，支持同步删除和异步确认两种接入方式。
    func submitRemoveRequest(id: String, completion: @escaping (_ accepted: Bool) -> Void) {
#if DEBUG
        Self.logger.debug("strip.onRemove id=\(id, privacy: .public)")
#endif
        if let onRequestRemove = configuration.onRequestRemove {
            onRequestRemove(id) { accepted in
                Task { @MainActor in
                    completion(accepted)
                }
            }
            return
        }
        configuration.onRemove(id)
        completion(true)
    }
}

extension XMAttachmentUploadStripView: UICollectionViewDataSource {
    /// 返回当前可渲染附图数量。
    func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    /// 绑定附图 cell 内容与交互回调。
    func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
        guard let cell = collectionView.dequeueReusableCell(
            withReuseIdentifier: XMAttachmentUploadCell.reuseIdentifier,
            for: indexPath
        ) as? XMAttachmentUploadCell,
              items.indices.contains(indexPath.item) else {
            return UICollectionViewCell()
        }

        configureCell(cell, at: indexPath, animated: false)
        return cell
    }
}

extension XMAttachmentUploadStripView: UICollectionViewDelegate {
    /// 处理条目点击回调，用于后续接入预览等扩展能力。
    func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
        guard items.indices.contains(indexPath.item) else { return }
        let itemID = items[indexPath.item].id
        if let previewIndex = previewIndexByItemID[itemID] {
            previewTapSequence += 1
            previewHost.open(
                at: previewIndex,
                wallID: configuration.accessibilityNamespace,
                tapSequence: previewTapSequence
            )
        }
        configuration.onTap?(itemID)
    }
}

extension XMAttachmentUploadStripView: UICollectionViewDragDelegate {
    /// 仅在非按钮区域启动本地拖拽重排，保证删除/重试按钮始终优先响应。
    func collectionView(
        _ collectionView: UICollectionView,
        itemsForBeginning session: UIDragSession,
        at indexPath: IndexPath
    ) -> [UIDragItem] {
        guard items.indices.contains(indexPath.item) else { return [] }
        let location = session.location(in: collectionView)
        guard canBeginReorder(at: location) else { return [] }

        beginReorderSession(at: indexPath)

        let itemID = items[indexPath.item].id
        let itemProvider = NSItemProvider(object: NSString(string: itemID))
        let dragItem = UIDragItem(itemProvider: itemProvider)
        dragItem.localObject = itemID
        return [dragItem]
    }

    /// 本地重排结束后统一回放缓存配置并收束 lifted 动效。
    func collectionView(_ collectionView: UICollectionView, dragSessionDidEnd session: UIDragSession) {
        guard isInteractiveReordering else { return }
        finishInteractiveReorder(cancelled: !didCommitMoveInCurrentSession)
    }
}

extension XMAttachmentUploadStripView: UICollectionViewDropDelegate {
    /// 仅允许本地拖拽会话，禁止跨应用投递。
    func collectionView(_ collectionView: UICollectionView, canHandle session: UIDropSession) -> Bool {
        session.localDragSession != nil
    }

    /// 声明 drop 为本地 move，确保系统以重排语义处理。
    func collectionView(
        _ collectionView: UICollectionView,
        dropSessionDidUpdate session: UIDropSession,
        withDestinationIndexPath destinationIndexPath: IndexPath?
    ) -> UICollectionViewDropProposal {
        guard session.localDragSession != nil else {
            return UICollectionViewDropProposal(operation: .forbidden)
        }
        return UICollectionViewDropProposal(operation: .move, intent: .insertAtDestinationIndexPath)
    }

    /// 执行本地重排并同步业务回调。
    func collectionView(_ collectionView: UICollectionView, performDropWith coordinator: UICollectionViewDropCoordinator) {
        guard let dropItem = coordinator.items.first,
              let sourceIndexPath = dropItem.sourceIndexPath,
              let destinationIndexPath = normalizedDestinationIndexPath(for: coordinator.destinationIndexPath) else {
            return
        }
        guard sourceIndexPath != destinationIndexPath else {
            coordinator.drop(dropItem.dragItem, toItemAt: destinationIndexPath)
            return
        }

#if DEBUG
        Self.logger.debug("reorder.move source=\(sourceIndexPath.item) destination=\(destinationIndexPath.item)")
#endif
        collectionView.performBatchUpdates { [weak self] in
            guard let self else { return }
            self.applyMove(from: sourceIndexPath, to: destinationIndexPath)
            collectionView.moveItem(at: sourceIndexPath, to: destinationIndexPath)
        } completion: { [weak self] _ in
            guard let self else { return }
            self.didCommitMoveInCurrentSession = true
            self.selectionFeedback.selectionChanged()
        }
        coordinator.drop(dropItem.dragItem, toItemAt: destinationIndexPath)
    }
}

/// 附图 cell 渲染器：统一处理本地优先、远端回退和异步图片解码。
private enum XMAttachmentUploadCellRenderer {
    /// 执行loadImage对应的数据处理步骤，并返回当前流程需要的结果。
    static func loadImage(for item: XMAttachmentUploadItem, maxPixelSize: CGFloat) async -> UIImage? {
        switch XMAttachmentUploadRenderSourceResolver.resolve(
            localFilePath: item.localFilePath,
            remoteURL: item.remoteURL
        ) {
        case let .local(path):
            if let image = await loadLocalImage(path: path, maxPixelSize: maxPixelSize) {
                return image
            }
            guard let fallbackURL = XMAttachmentUploadRenderSourceResolver.fallbackRemoteURL(from: item.remoteURL) else {
                return nil
            }
            return await loadRemoteImage(from: fallbackURL)

        case let .remote(url):
            return await loadRemoteImage(from: url)

        case .none:
            return nil
        }
    }

    private static func loadRemoteImage(from url: URL) async -> UIImage? {
        let request = XMImageRequestBuilder.makeImageRequest(url: url, priority: .high)
        do {
            return try await ImagePipeline.shared.image(for: request)
        } catch {
            return nil
        }
    }

    /// 异步下采样本地图片，避免主线程同步解码造成卡顿。
    private static func loadLocalImage(path: String, maxPixelSize: CGFloat) async -> UIImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: downsampledLocalImage(path: path, maxPixelSize: maxPixelSize))
            }
        }
    }

    /// 基于 ImageIO 生成缩略图；失败时回退原图解码。
    private static func downsampledLocalImage(path: String, maxPixelSize: CGFloat) -> UIImage? {
        let fileURL = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            return UIImage(contentsOfFile: path)
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize)
        ]
        if let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
            return UIImage(cgImage: cgImage)
        }
        return UIImage(contentsOfFile: path)
    }
}

/// 附图条单元格，负责缩略图渲染、上传态覆盖层与删除/重试操作。
private final class XMAttachmentUploadCell: UICollectionViewCell {
    static let reuseIdentifier = "XMAttachmentUploadCell"

    /// RenderSignature 负责当前场景的struct定义，明确职责边界并组织相关能力。
    private struct RenderSignature: Equatable {
        let id: String
        let localFilePath: String?
        let remoteURL: String?
        let uploadState: XMAttachmentUploadState
    }

    private let imageContainer = UIView()
    private let imageView = UIImageView()
    private let placeholderView = UIView()
    private let statusOverlayView = UIView()
    private let loadingIndicator = UIActivityIndicatorView(style: .medium)
    private let retryButton = XMTouchAreaButton(type: .system)
    private let removeButton = XMTouchAreaButton(type: .system)

    private var onRemove: (() -> Void)?
    private var onRetry: (() -> Void)?
    private var onControlTrackingChanged: ((_ id: String, _ isTracking: Bool) -> Void)?
    private var imageTask: Task<Void, Never>?
    private var lastSignature: RenderSignature?
    private weak var thumbnailRegistry: XMJXThumbnailRegistry?
    private var currentItemID = ""
    private var isRemovalExitAnimating = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupCell()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 处理prepareForReuse对应的状态流转，确保交互过程与数据状态保持一致。
    override func prepareForReuse() {
        super.prepareForReuse()
        unregisterThumbnailIfNeeded()
        cancelImageLoading()
        imageView.image = nil
        lastSignature = nil
        removeButton.isHidden = false
        statusOverlayView.alpha = 0
        retryButton.isHidden = true
        loadingIndicator.stopAnimating()
        onControlTrackingChanged?(currentItemID, false)
        currentItemID = ""
        thumbnailRegistry = nil
        onControlTrackingChanged = nil
        accessibilityIdentifier = nil
        removeButton.accessibilityIdentifier = nil
        retryButton.accessibilityIdentifier = nil
        removeButton.accessibilityLabel = nil
        removeButton.accessibilityHint = nil
        retryButton.accessibilityLabel = nil
        retryButton.accessibilityHint = nil
        contentView.transform = .identity
        contentView.alpha = 1
        imageContainer.transform = .identity
        imageContainer.alpha = 1
        removeButton.transform = .identity
        removeButton.alpha = 1
        isRemovalExitAnimating = false
    }

    /// 配置条目内容与事件回调，并按需执行状态转场动画。
    func configure(
        item: XMAttachmentUploadItem,
        showsRemoveButton: Bool,
        onRemove: @escaping (_ id: String) -> Void,
        onRetry: @escaping (_ id: String) -> Void,
        onControlTrackingChanged: @escaping (_ id: String, _ isTracking: Bool) -> Void,
        thumbnailRegistry: XMJXThumbnailRegistry?,
        accessibilityNamespace: String,
        strings: XMAttachmentUploadStripStrings,
        animated: Bool
    ) {
        syncThumbnailRegistry(to: thumbnailRegistry, nextItemID: item.id)
        self.onRemove = { onRemove(item.id) }
        self.onRetry = { onRetry(item.id) }
        self.onControlTrackingChanged = onControlTrackingChanged
        let shouldResetVisualState = !isRemovalExitAnimating || currentItemID != item.id
        if shouldResetVisualState {
            contentView.transform = .identity
            contentView.alpha = 1
            imageContainer.transform = .identity
            imageContainer.alpha = 1
            removeButton.transform = .identity
            removeButton.alpha = 1
            isRemovalExitAnimating = false
        }
        removeButton.isHidden = !showsRemoveButton
        currentItemID = item.id
        accessibilityIdentifier = "\(accessibilityNamespace).item.\(item.id)"
        removeButton.accessibilityIdentifier = "\(accessibilityNamespace).remove.\(item.id)"
        retryButton.accessibilityIdentifier = "\(accessibilityNamespace).retry.\(item.id)"
        removeButton.accessibilityLabel = strings.removeAccessibilityLabel
        removeButton.accessibilityHint = strings.removeAccessibilityHint
        retryButton.accessibilityLabel = strings.retryAccessibilityLabel
        retryButton.accessibilityHint = strings.retryAccessibilityHint
        updateRetryButtonTitle(strings.retryTitle)

        let signature = RenderSignature(
            id: item.id,
            localFilePath: item.localFilePath,
            remoteURL: item.remoteURL,
            uploadState: item.uploadState
        )

        let visualChanged = lastSignature != signature
        lastSignature = signature

        if visualChanged {
            renderImage(item)
            applyUploadState(item.uploadState, animated: animated)
        }
    }

    /// 更新拖拽抬起视觉反馈。
    func setLifted(_ lifted: Bool, animated: Bool) {
        let targetTransform: CGAffineTransform = lifted ? CGAffineTransform(scaleX: 1.04, y: 1.04) : .identity
        let targetShadowOpacity: Float = lifted ? 0.22 : 0
        let targetShadowRadius: CGFloat = lifted ? 10 : 0

        let animations = {
            self.transform = targetTransform
            self.layer.shadowColor = UIColor.black.cgColor
            self.layer.shadowOpacity = targetShadowOpacity
            self.layer.shadowRadius = targetShadowRadius
            self.layer.shadowOffset = CGSize(width: 0, height: lifted ? 4 : 0)
        }

        if animated {
            UIView.animate(
                withDuration: 0.18,
                delay: 0,
                options: [.curveEaseInOut, .allowUserInteraction],
                animations: animations
            )
        } else {
            animations()
        }
    }

    /// 删除时先执行目标项退出动画，提升“删除已生效”的即时感知。
    func animateRemovalExit(reduceMotion: Bool, completion: @escaping () -> Void) {
        isRemovalExitAnimating = true
        onControlTrackingChanged?(currentItemID, false)
        let targetTransform: CGAffineTransform = reduceMotion
            ? .identity
            : CGAffineTransform(translationX: 4, y: -4).scaledBy(x: 0.9, y: 0.9)
        let duration: TimeInterval = reduceMotion ? 0.12 : 0.16

        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [.curveEaseIn, .allowUserInteraction]
        ) {
            self.contentView.alpha = 0
            self.contentView.transform = targetTransform
            self.imageContainer.alpha = reduceMotion ? 0 : 0.12
            self.removeButton.alpha = 0
        } completion: { _ in
            completion()
        }
    }

    /// 删除请求被上层拒绝时回滚退出态，恢复卡片可见与可交互状态。
    func animateRemovalRollback(reduceMotion: Bool) {
        let duration: TimeInterval = reduceMotion ? 0.1 : 0.16
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [.curveEaseOut, .allowUserInteraction]
        ) {
            self.contentView.alpha = 1
            self.contentView.transform = .identity
            self.imageContainer.alpha = 1
            self.removeButton.alpha = 1
            self.removeButton.transform = .identity
        } completion: { _ in
            self.isRemovalExitAnimating = false
        }
    }

    /// 取消远端缩略图加载任务，避免复用时串图。
    func cancelImageLoading() {
        imageTask?.cancel()
        imageTask = nil
    }

    /// 同步重试按钮文案，支持业务侧按场景覆盖默认文本。
    func updateRetryButtonTitle(_ title: String) {
        guard var configuration = retryButton.configuration else { return }
        let retryFont = AppTypography.uiFixed(
            baseSize: 12,
            textStyle: .footnote,
            weight: .semibold,
            minimumPointSize: 12
        )
        var attributedTitle = AttributedString(title)
        attributedTitle.font = retryFont
        configuration.attributedTitle = attributedTitle
        retryButton.configuration = configuration
    }

    /// 同步缩略图注册关系，确保 Zoom 转场始终命中当前可见 cell。
    func syncThumbnailRegistry(to registry: XMJXThumbnailRegistry?, nextItemID: String) {
        let currentRegistry = thumbnailRegistry
        if currentItemID != nextItemID || currentRegistry !== registry {
            unregisterThumbnailIfNeeded()
        }
        thumbnailRegistry = registry
        guard let registry else { return }
        guard !nextItemID.isEmpty else { return }
        registry.register(itemID: nextItemID, view: imageView)
    }

    /// 解除当前 item 与缩略图视图的绑定，避免复用时错绑。
    func unregisterThumbnailIfNeeded() {
        guard let thumbnailRegistry else { return }
        guard !currentItemID.isEmpty else { return }
        thumbnailRegistry.unregister(itemID: currentItemID, view: imageView)
    }
}

private extension XMAttachmentUploadCell {
    /// 返回删除/重试按钮在指定坐标系下的保护区矩形。
    func protectedControlFrames(in coordinateSpaceView: UIView) -> [CGRect] {
        var frames: [CGRect] = []
        if removeButton.canParticipateInHitTesting {
            frames.append(removeButton.expandedHitFrame(in: coordinateSpaceView))
        }
        if retryButton.canParticipateInHitTesting {
            frames.append(retryButton.expandedHitFrame(in: coordinateSpaceView))
        }
        return frames
    }

    /// 搭建 cell 子视图层级与基础样式。
    func setupCell() {
        backgroundColor = .clear
        contentView.backgroundColor = .clear
        contentView.clipsToBounds = false

        imageContainer.translatesAutoresizingMaskIntoConstraints = false
        imageContainer.layer.cornerRadius = CornerRadius.blockMedium
        imageContainer.layer.cornerCurve = .continuous
        imageContainer.clipsToBounds = true
        imageContainer.backgroundColor = UIColor(Color.surfaceNested)
        contentView.addSubview(imageContainer)

        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.contentMode = .scaleAspectFill
        imageView.clipsToBounds = true
        imageContainer.addSubview(imageView)

        placeholderView.translatesAutoresizingMaskIntoConstraints = false
        placeholderView.backgroundColor = UIColor(Color.surfaceNested)
        imageContainer.addSubview(placeholderView)

        statusOverlayView.translatesAutoresizingMaskIntoConstraints = false
        statusOverlayView.backgroundColor = UIColor.black.withAlphaComponent(0.22)
        statusOverlayView.alpha = 0
        imageContainer.addSubview(statusOverlayView)

        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.color = .white
        statusOverlayView.addSubview(loadingIndicator)

        retryButton.translatesAutoresizingMaskIntoConstraints = false
        var retryConfiguration = UIButton.Configuration.plain()
        var retryTitle = AttributedString(XMAttachmentUploadStripStrings.default.retryTitle)
        retryTitle.font = AppTypography.uiFixed(
            baseSize: 12,
            textStyle: .footnote,
            weight: .semibold,
            minimumPointSize: 12
        )
        retryConfiguration.attributedTitle = retryTitle
        retryConfiguration.baseForegroundColor = UIColor(Color.feedbackError)
        retryConfiguration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 10, bottom: 4, trailing: 10)
        retryButton.configuration = retryConfiguration
        retryButton.backgroundColor = UIColor.black.withAlphaComponent(0.72)
        retryButton.layer.cornerRadius = 13
        retryButton.layer.cornerCurve = .continuous
        retryButton.touchAreaOutsets = .init(top: 6, left: 6, bottom: 6, right: 6)
        retryButton.isHidden = true
        retryButton.addTarget(self, action: #selector(handleControlTouchDown), for: .touchDown)
        retryButton.addTarget(self, action: #selector(handleControlTouchUp), for: [.touchDragExit, .touchCancel, .touchUpOutside, .touchUpInside])
        retryButton.addTarget(self, action: #selector(handleControlTouchDown), for: .touchDragEnter)
        retryButton.addTarget(self, action: #selector(handleRetryTapped), for: .touchUpInside)
        statusOverlayView.addSubview(retryButton)

        removeButton.translatesAutoresizingMaskIntoConstraints = false
        let removeImage = UIImage(systemName: "xmark", withConfiguration: UIImage.SymbolConfiguration(pointSize: 10, weight: .bold))
        removeButton.setImage(removeImage, for: .normal)
        removeButton.tintColor = .white
        removeButton.backgroundColor = UIColor.black.withAlphaComponent(0.65)
        removeButton.layer.cornerRadius = 12
        removeButton.layer.cornerCurve = .continuous
        removeButton.touchAreaOutsets = .init(top: 10, left: 10, bottom: 10, right: 10)
        removeButton.addTarget(self, action: #selector(handleRemoveTouchDown), for: .touchDown)
        removeButton.addTarget(self, action: #selector(handleRemoveTouchUp), for: [.touchDragExit, .touchCancel, .touchUpOutside, .touchUpInside])
        removeButton.addTarget(self, action: #selector(handleRemoveTouchDown), for: .touchDragEnter)
        removeButton.addTarget(self, action: #selector(handleRemoveTapped), for: .touchUpInside)
        contentView.addSubview(removeButton)

        NSLayoutConstraint.activate([
            imageContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            imageContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            imageContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            imageContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            imageView.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: imageContainer.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor),

            placeholderView.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor),
            placeholderView.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor),
            placeholderView.topAnchor.constraint(equalTo: imageContainer.topAnchor),
            placeholderView.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor),

            statusOverlayView.leadingAnchor.constraint(equalTo: imageContainer.leadingAnchor),
            statusOverlayView.trailingAnchor.constraint(equalTo: imageContainer.trailingAnchor),
            statusOverlayView.topAnchor.constraint(equalTo: imageContainer.topAnchor),
            statusOverlayView.bottomAnchor.constraint(equalTo: imageContainer.bottomAnchor),

            loadingIndicator.centerXAnchor.constraint(equalTo: statusOverlayView.centerXAnchor),
            loadingIndicator.centerYAnchor.constraint(equalTo: statusOverlayView.centerYAnchor),

            retryButton.centerXAnchor.constraint(equalTo: statusOverlayView.centerXAnchor),
            retryButton.centerYAnchor.constraint(equalTo: statusOverlayView.centerYAnchor),

            removeButton.widthAnchor.constraint(equalToConstant: 24),
            removeButton.heightAnchor.constraint(equalToConstant: 24),
            removeButton.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 2),
            removeButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -2)
        ])
    }

    /// 渲染缩略图：优先本地路径，其次远端 URL，最后占位态。
    func renderImage(_ item: XMAttachmentUploadItem) {
        cancelImageLoading()
        imageView.image = nil
        placeholderView.isHidden = false
        let maxPixelSize = max(bounds.width, 84) * max(traitCollection.displayScale, 1)
        imageTask = Task { [weak self] in
            let image = await XMAttachmentUploadCellRenderer.loadImage(
                for: item,
                maxPixelSize: maxPixelSize
            )
            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard let self else { return }
                self.imageView.image = image
                self.placeholderView.isHidden = image != nil
            }
        }
    }

    /// 根据上传状态更新遮罩层，统一应用转场动画，避免状态硬切。
    func applyUploadState(_ state: XMAttachmentUploadState, animated: Bool) {
        let updates = {
            switch state {
            case .uploading:
                self.statusOverlayView.alpha = 1
                self.statusOverlayView.backgroundColor = UIColor.black.withAlphaComponent(0.22)
                self.retryButton.isHidden = true
                self.loadingIndicator.startAnimating()

            case .failed:
                self.statusOverlayView.alpha = 1
                self.statusOverlayView.backgroundColor = UIColor.black.withAlphaComponent(0.38)
                self.loadingIndicator.stopAnimating()
                self.retryButton.isHidden = false

            case .success:
                self.statusOverlayView.alpha = 0
                self.loadingIndicator.stopAnimating()
                self.retryButton.isHidden = true
            }
        }

        if animated {
            UIView.transition(
                with: statusOverlayView,
                duration: 0.18,
                options: [.transitionCrossDissolve, .allowUserInteraction]
            ) {
                updates()
            }
        } else {
            updates()
        }
    }

    /// 处理删除按钮点击事件。
    @objc
    func handleRemoveTouchDown() {
        onControlTrackingChanged?(currentItemID, true)
        animateRemoveButton(isPressed: true)
    }

    /// 删除按钮取消或抬起时恢复视觉状态。
    @objc
    func handleRemoveTouchUp() {
        onControlTrackingChanged?(currentItemID, false)
        animateRemoveButton(isPressed: false)
    }

    /// 处理删除按钮点击事件。
    @objc
    func handleRemoveTapped() {
#if DEBUG
        XMAttachmentUploadStripView.logger.debug("remove.tap id=\(self.currentItemID, privacy: .public)")
#endif
        onRemove?()
    }

    /// 处理重试按钮点击事件。
    @objc
    func handleRetryTapped() {
#if DEBUG
        XMAttachmentUploadStripView.logger.debug("retry.tap id=\(self.currentItemID, privacy: .public)")
#endif
        onRetry?()
    }

    /// 所有可交互控件共用的按下态通知，供上层阻断拖拽启动。
    @objc
    func handleControlTouchDown() {
        onControlTrackingChanged?(currentItemID, true)
    }

    /// 控件取消或抬起时恢复拖拽可用性。
    @objc
    func handleControlTouchUp() {
        onControlTrackingChanged?(currentItemID, false)
    }

    func animateRemoveButton(isPressed: Bool) {
        let targetTransform: CGAffineTransform = isPressed ? CGAffineTransform(scaleX: 0.92, y: 0.92) : .identity
        let targetAlpha: CGFloat = isPressed ? 0.78 : 1
        UIView.animate(
            withDuration: 0.12,
            delay: 0,
            options: [.curveEaseOut, .allowUserInteraction]
        ) {
            self.removeButton.transform = targetTransform
            self.removeButton.alpha = targetAlpha
        }
    }
}

private extension Array {
    /// 将元素从 source 索引移动到 destination 索引。
    mutating func xmMove(from sourceIndex: Int, to destinationIndex: Int) {
        guard sourceIndex != destinationIndex,
              indices.contains(sourceIndex),
              indices.contains(destinationIndex) else {
            return
        }
        let item = remove(at: sourceIndex)
        insert(item, at: destinationIndex)
    }
}

/// 扩展按钮点击热区，视觉尺寸不变但提升可点击性。
private final class XMTouchAreaButton: UIButton {
    var touchAreaOutsets: UIEdgeInsets = .zero

    var canParticipateInHitTesting: Bool {
        isEnabled && !isHidden && alpha > 0.01 && isUserInteractionEnabled
    }

    var expandedHitBounds: CGRect {
        guard touchAreaOutsets != .zero else { return bounds }
        return bounds.inset(
            by: UIEdgeInsets(
                top: -touchAreaOutsets.top,
                left: -touchAreaOutsets.left,
                bottom: -touchAreaOutsets.bottom,
                right: -touchAreaOutsets.right
            )
        )
    }

    func expandedHitFrame(in view: UIView) -> CGRect {
        convert(expandedHitBounds, to: view)
    }

    /// 封装point对应的业务步骤，确保调用方可以稳定复用该能力。
    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard canParticipateInHitTesting else { return false }
        return expandedHitBounds.contains(point)
    }
}
