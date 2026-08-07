/**
 * [INPUT]: 依赖 BookWorkspacePresentationSnapshot、SwiftUI 行内容构建器与 UIKit UICollectionView
 * [OUTPUT]: 对外提供 BookWorkspaceCollectionView，使用四个常驻原生 Collection 承接主题画布、轻量 Tab、内容表面，并在 DEBUG 记录书摘快照实际应用
 * [POS]: Views/Book/Components 的页面私有 UIKit 混合列表，负责复用、diff、主题画布固定层、粘性推离和视口稳定
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import SwiftUI
import UIKit
#if DEBUG
import os
#endif

/// 将固定层吸附线向物理像素对齐，避免 Tab 与章节标题之间出现亚像素缝隙。
private func bookWorkspacePixelAligned(_ value: CGFloat, scale: CGFloat) -> CGFloat {
    guard value.isFinite, scale.isFinite, scale > 0 else { return value }
    return ceil(value * scale) / scale
}

/// 从 UIKit 滚动层向 SwiftUI 氛围层发布的最小连续几何数据。
struct BookWorkspaceCollectionScrollMetrics: Equatable, Sendable {
    let effectiveOffset: CGFloat
    let viewportTop: CGFloat
    let pinOffset: CGFloat
}

/// 四域常驻 UIKit 混合列表；SwiftUI 只提供可复用 Cell 的视觉内容。
struct BookWorkspaceCollectionView: UIViewRepresentable {
    let book: BookDetail
    let snapshots: [BookWorkspaceSection: BookWorkspacePresentationSnapshot]
    let selectedSection: BookWorkspaceSection
    let notesCount: Int
    let notesLoadState: BookNotesLoadState
    let reduceMotion: Bool
    let canvasColor: Color
    let canvasPaletteID: UInt64
    let onSelectSection: (BookWorkspaceSection) -> Void
    let onOpenReadingDetail: () -> Void
    let onEditBook: () -> Void
    let onToggleChapter: (Int64) -> Void
    let onOpenChapter: (BookDetailChapter) -> Void
    let onOpenNote: (NoteExcerpt) -> Void
    let onEditNote: (NoteExcerpt) -> Void
    let onOpenRelated: (BookRelatedExcerpt) -> Void
    let onOpenReview: (BookReviewExcerpt) -> Void
    let onScrollMetricsChange: (BookWorkspaceSection, BookWorkspaceCollectionScrollMetrics) -> Void

    /// 创建四个常驻 UICollectionView 的唯一宿主。
    func makeUIView(context: Context) -> BookWorkspaceCollectionHostView {
        let host = BookWorkspaceCollectionHostView()
        host.update(with: configuration)
        return host
    }

    /// 仅同步不可变快照、当前域和最新业务闭包；具体差异由 host 内部收敛。
    func updateUIView(_ uiView: BookWorkspaceCollectionHostView, context: Context) {
        uiView.update(with: configuration)
    }

    /// 销毁页面时取消所有富文本预热任务并解除数据源。
    static func dismantleUIView(_ uiView: BookWorkspaceCollectionHostView, coordinator: ()) {
        uiView.prepareForReuse()
    }

    private var configuration: BookWorkspaceCollectionConfiguration {
        BookWorkspaceCollectionConfiguration(
            book: book,
            snapshots: snapshots,
            selectedSection: selectedSection,
            notesCount: notesCount,
            notesLoadState: notesLoadState,
            reduceMotion: reduceMotion,
            canvasColor: canvasColor,
            canvasPaletteID: canvasPaletteID,
            onSelectSection: onSelectSection,
            onOpenReadingDetail: onOpenReadingDetail,
            onEditBook: onEditBook,
            onToggleChapter: onToggleChapter,
            onOpenChapter: onOpenChapter,
            onOpenNote: onOpenNote,
            onEditNote: onEditNote,
            onOpenRelated: onOpenRelated,
            onOpenReview: onOpenReview,
            onScrollMetricsChange: onScrollMetricsChange
        )
    }
}

/// UIKit 宿主消费的页面配置；闭包只在配置可见 Cell 时调用，不参与 diff 身份。
@MainActor
private struct BookWorkspaceCollectionConfiguration {
    let book: BookDetail?
    let snapshots: [BookWorkspaceSection: BookWorkspacePresentationSnapshot]
    let selectedSection: BookWorkspaceSection
    let notesCount: Int
    let notesLoadState: BookNotesLoadState
    let reduceMotion: Bool
    let canvasColor: Color
    let canvasPaletteID: UInt64
    let onSelectSection: (BookWorkspaceSection) -> Void
    let onOpenReadingDetail: () -> Void
    let onEditBook: () -> Void
    let onToggleChapter: (Int64) -> Void
    let onOpenChapter: (BookDetailChapter) -> Void
    let onOpenNote: (NoteExcerpt) -> Void
    let onEditNote: (NoteExcerpt) -> Void
    let onOpenRelated: (BookRelatedExcerpt) -> Void
    let onOpenReview: (BookReviewExcerpt) -> Void
    let onScrollMetricsChange: (BookWorkspaceSection, BookWorkspaceCollectionScrollMetrics) -> Void

    static let empty = BookWorkspaceCollectionConfiguration(
        book: nil,
        snapshots: Dictionary(
            uniqueKeysWithValues: BookWorkspaceSection.allCases.map {
                ($0, BookWorkspacePresentationSnapshot.initial(for: $0))
            }
        ),
        selectedSection: .notes,
        notesCount: 0,
        notesLoadState: .loading,
        reduceMotion: false,
        canvasColor: Color.surfacePage,
        canvasPaletteID: 0,
        onSelectSection: { _ in },
        onOpenReadingDetail: {},
        onEditBook: {},
        onToggleChapter: { _ in },
        onOpenChapter: { _ in },
        onOpenNote: { _ in },
        onEditNote: { _ in },
        onOpenRelated: { _ in },
        onOpenReview: { _ in },
        onScrollMetricsChange: { _, _ in }
    )
}

/// 向宿主暴露 automatic inset 与布局周期，便于安全区变更时保持同一业务 Item 的视觉位置。
private final class BookWorkspaceViewportStableCollectionView: UICollectionView {
    var onBeforeLayout: (() -> Void)?
    var onAfterLayout: (() -> Void)?
    var onAdjustedInsetChange: (() -> Void)?

    override func layoutSubviews() {
        onBeforeLayout?()
        super.layoutSubviews()
        onAfterLayout?()
    }

    override func adjustedContentInsetDidChange() {
        super.adjustedContentInsetDidChange()
        onAdjustedInsetChange?()
    }
}

/// 在 UIKit 原生 section pin/push-off 结果上移动吸附线，使章节标题自然停在唯一 Tab 下方。
private final class BookWorkspacePinnedHeaderCompositionalLayout: UICollectionViewCompositionalLayout {
    private let scopeBarHeightProvider: () -> CGFloat
    private let isPinnedHeaderProvider: (IndexPath) -> Bool
    private let nextPinnedHeaderProvider: (IndexPath) -> IndexPath?

    init(
        sectionProvider: @escaping UICollectionViewCompositionalLayoutSectionProvider,
        scopeBarHeightProvider: @escaping () -> CGFloat,
        isPinnedHeaderProvider: @escaping (IndexPath) -> Bool,
        nextPinnedHeaderProvider: @escaping (IndexPath) -> IndexPath?
    ) {
        self.scopeBarHeightProvider = scopeBarHeightProvider
        self.isPinnedHeaderProvider = isPinnedHeaderProvider
        self.nextPinnedHeaderProvider = nextPinnedHeaderProvider
        super.init(sectionProvider: sectionProvider)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func shouldInvalidateLayout(forBoundsChange newBounds: CGRect) -> Bool {
        true
    }

    override func layoutAttributesForElements(in rect: CGRect) -> [UICollectionViewLayoutAttributes]? {
        guard let attributes = super.layoutAttributesForElements(in: rect) else { return nil }
        return attributes.map { layoutAttributes in
            guard layoutAttributes.representedElementKind
                == UICollectionView.elementKindSectionHeader else {
                return layoutAttributes
            }
            return adjustedHeaderAttributes(layoutAttributes)
        }
    }

    override func layoutAttributesForSupplementaryView(
        ofKind elementKind: String,
        at indexPath: IndexPath
    ) -> UICollectionViewLayoutAttributes? {
        guard let attributes = super.layoutAttributesForSupplementaryView(
            ofKind: elementKind,
            at: indexPath
        ) else {
            return nil
        }
        guard elementKind == UICollectionView.elementKindSectionHeader else {
            return attributes
        }
        return adjustedHeaderAttributes(attributes)
    }

    /// 复用系统原生 header frame，只把其可见顶边改成 Tab 底边；下一 Header 仍逐点推出当前 Header。
    private func adjustedHeaderAttributes(
        _ source: UICollectionViewLayoutAttributes
    ) -> UICollectionViewLayoutAttributes {
        guard isPinnedHeaderProvider(source.indexPath),
              let collectionView,
              let result = source.copy() as? UICollectionViewLayoutAttributes else {
            return source
        }
        let displayScale = collectionView.window?.screen.scale
            ?? max(collectionView.traitCollection.displayScale, 1)
        let alignedTopInset = bookWorkspacePixelAligned(
            collectionView.adjustedContentInset.top,
            scale: displayScale
        )
        let pinnedLine = collectionView.contentOffset.y
            + alignedTopInset
            + max(scopeBarHeightProvider(), 0)
        var targetY = max(result.frame.minY, pinnedLine)

        if let nextIndexPath = nextPinnedHeaderProvider(source.indexPath),
           let nextAttributes = super.layoutAttributesForSupplementaryView(
            ofKind: UICollectionView.elementKindSectionHeader,
            at: nextIndexPath
           ) {
            targetY = min(targetY, nextAttributes.frame.minY - result.bounds.height)
        }

        result.frame.origin.y = targetY
        result.zIndex = max(result.zIndex, 10)
        return result
    }
}

/// SwiftUI Cell 内容的轻量承载单元，复用时保留 HostingConfiguration 的宿主生命周期。
private final class BookWorkspaceHostingCell: UICollectionViewCell {
    static let reuseIdentifier = "BookWorkspaceHostingCell"

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
    }

    /// 承载页面提供的 SwiftUI 内容；外部 Compositional Layout 统一管理边距。
    func configure(content: AnyView) {
        contentConfiguration = UIHostingConfiguration {
            content
        }
        .margins(.all, 0)
    }
}

/// 粘性章节标题承载视图，背景必须不透明以阻止正文透出。
private final class BookWorkspaceHostingHeaderView: UICollectionReusableView {
    static let reuseIdentifier = "BookWorkspaceHostingHeaderView"
    private var hostedContentView: (UIView & UIContentView)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(Color.surfacePage)
        isOpaque = true
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 复用同一个 UIContentView，并让章节内容与 UIKit 宿主共享不透明主题画布。
    func configure(content: AnyView, canvasColor: Color, animated: Bool) {
        let applyConfiguration = { [self] in
            backgroundColor = UIColor(canvasColor)
            let configuration = UIHostingConfiguration {
                content
            }
            .margins(.all, 0)
            .background(canvasColor)
            if let hostedContentView {
                hostedContentView.configuration = configuration
                return
            }
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
        guard animated, hostedContentView != nil else {
            applyConfiguration()
            return
        }
        UIView.transition(
            with: self,
            duration: 0.18,
            options: [.transitionCrossDissolve, .beginFromCurrentState, .allowUserInteraction],
            animations: applyConfiguration
        )
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        transform = .identity
    }
}

/// 页面唯一的 Tab 宿主；复用同一个 UIContentView，只由 Collection 的实时几何更新位置。
@MainActor
private final class BookWorkspaceScopeBarHostView: UIView {
    private var hostedContentView: (UIView & UIContentView)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = UIColor(Color.surfacePage)
        isOpaque = true
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 保持 UIKit 宿主身份不变，并让 Tab 内容与宿主同步切换不透明主题画布。
    func configure(content: AnyView, canvasColor: Color, animated: Bool) {
        let applyConfiguration = { [self] in
            backgroundColor = UIColor(canvasColor)
            let configuration = UIHostingConfiguration {
                content
            }
            .margins(.all, 0)
            .background(canvasColor)
            if let hostedContentView {
                hostedContentView.configuration = configuration
                setNeedsLayout()
                return
            }
            let contentView = configuration.makeContentView()
            hostedContentView = contentView
            addSubview(contentView)
            setNeedsLayout()
        }
        guard animated, hostedContentView != nil else {
            applyConfiguration()
            return
        }
        UIView.transition(
            with: self,
            duration: 0.18,
            options: [.transitionCrossDissolve, .beginFromCurrentState, .allowUserInteraction],
            animations: applyConfiguration
        )
    }

    /// 按当前容器宽度测量真实高度，保证 Dynamic Type 不被固定高度裁切。
    func fittingHeight(for width: CGFloat) -> CGFloat {
        guard let hostedContentView, width > 0 else {
            return BookWorkspaceLayoutMetrics.scopeBarEstimatedHeight
        }
        let targetSize = CGSize(
            width: width,
            height: UIView.layoutFittingCompressedSize.height
        )
        return hostedContentView.systemLayoutSizeFitting(
            targetSize,
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        hostedContentView?.frame = bounds
    }
}

/// 单个内容域的 UIKit 状态，和其它域完全隔离以保留滚动位置、diff 与预取任务。
@MainActor
private final class BookWorkspaceCollectionDomainContext {
    let section: BookWorkspaceSection
    let collectionView: BookWorkspaceViewportStableCollectionView
    var dataSource: UICollectionViewDiffableDataSource<
        BookWorkspaceCollectionSectionID,
        BookWorkspaceCollectionItemID
    >?
    var snapshot: BookWorkspacePresentationSnapshot
    var appliedRevision = -1
    var lastPublishedMetrics: BookWorkspaceCollectionScrollMetrics?
    var viewportAnchor: ViewportAnchor?
    var fallbackOffsetY: CGFloat = 0
    var lastAdjustedInset: UIEdgeInsets = .zero
    var lastBoundsSize: CGSize = .zero
    var isRestoringViewport = false
    var isCapturingViewportSuspended = false
    var pendingPrewarmIDs: [Int64] = []
    var prewarmTask: Task<Void, Never>?

    init(
        section: BookWorkspaceSection,
        collectionView: BookWorkspaceViewportStableCollectionView,
        snapshot: BookWorkspacePresentationSnapshot
    ) {
        self.section = section
        self.collectionView = collectionView
        self.snapshot = snapshot
    }

    struct ViewportAnchor {
        let itemID: BookWorkspaceCollectionItemID
        let distanceFromVisibleTop: CGFloat
    }
}

/// 用纯值判断 Tab 视觉是否真正变化，滚动过程不会触发 SwiftUI 配置重建。
private struct BookWorkspaceScopeBarContentState: Equatable {
    let book: BookDetail
    let selectedSection: BookWorkspaceSection
    let notesCount: Int
    let reduceMotion: Bool
    let canvasPaletteID: UInt64
}

/// 四域原生列表宿主，负责 Collection 生命周期、diff、原生粘性头和受控预热。
@MainActor
final class BookWorkspaceCollectionHostView: UIView, UICollectionViewDelegate, UICollectionViewDataSourcePrefetching {
#if DEBUG
    private static let notesLogger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "xmnote",
        category: "BookWorkspaceNotes"
    )
    private let debugIdentifier = UUID().uuidString
#endif

    private var configuration = BookWorkspaceCollectionConfiguration.empty
    private var contexts: [BookWorkspaceSection: BookWorkspaceCollectionDomainContext] = [:]
    private let scopeBarHostView = BookWorkspaceScopeBarHostView()
    private var scopeBarHeight = BookWorkspaceLayoutMetrics.scopeBarEstimatedHeight
    private var scopeBarContentState: BookWorkspaceScopeBarContentState?
    private var isScopeBarPlaceholderRefreshScheduled = false
    private var noteRowStates: [Int64: BookWorkspaceNoteRowState] = [:]
    private var pendingMetrics: [BookWorkspaceSection: BookWorkspaceCollectionScrollMetrics] = [:]
    private var isMetricsDeliveryScheduled = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        BookWorkspaceSection.allCases.forEach(makeDomainContext)
        scopeBarHostView.isHidden = true
        addSubview(scopeBarHostView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 同步四域快照；隐藏域不销毁，只暂停交互、滚动回调和预取。
    fileprivate func update(with configuration: BookWorkspaceCollectionConfiguration) {
        let previousConfiguration = self.configuration
        let previousSelectedSection = previousConfiguration.selectedSection
        let canvasChanged = previousConfiguration.canvasPaletteID != configuration.canvasPaletteID
        let animatesCanvasChange = canvasChanged
            && previousConfiguration.book != nil
            && !configuration.reduceMotion
        self.configuration = configuration
        updateScopeBarContent(animatedCanvasChange: animatesCanvasChange)
        pruneNoteRowStates()

        for section in BookWorkspaceSection.allCases {
            guard let context = contexts[section] else { continue }
            let isActive = section == configuration.selectedSection
            context.collectionView.isHidden = !isActive
            context.collectionView.isUserInteractionEnabled = isActive
            context.collectionView.accessibilityElementsHidden = !isActive
            context.collectionView.prefetchDataSource = isActive ? self : nil
            if !isActive {
                cancelPrewarming(in: context)
            }

            let nextSnapshot = configuration.snapshots[section]
                ?? BookWorkspacePresentationSnapshot.initial(for: section)
            apply(
                nextSnapshot,
                to: context,
                forceReconfigureIDs: chromeItemIDsChanged(
                    in: section,
                    from: previousConfiguration,
                    to: configuration
                )
            )
            if canvasChanged {
                refreshVisibleContent(in: context, animatedCanvasChange: animatesCanvasChange)
            }
        }

        updateBottomContentInsets()

        if previousSelectedSection != configuration.selectedSection,
           let active = contexts[configuration.selectedSection] {
            active.collectionView.layoutIfNeeded()
            layoutScopeBar(for: active)
            publishMetrics(for: active)
        }
    }

    /// 清理所有 UIKit 数据源与异步预热工作。
    func prepareForReuse() {
        for context in contexts.values {
            cancelPrewarming(in: context)
            context.collectionView.delegate = nil
            context.collectionView.prefetchDataSource = nil
            context.dataSource = nil
        }
        contexts.removeAll()
        noteRowStates.removeAll()
        pendingMetrics.removeAll()
        scopeBarContentState = nil
        scopeBarHostView.removeFromSuperview()
        isScopeBarPlaceholderRefreshScheduled = false
        isMetricsDeliveryScheduled = false
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateBottomContentInsets()
        guard let active = contexts[configuration.selectedSection] else { return }
        if active.lastBoundsSize != active.collectionView.bounds.size {
            active.lastBoundsSize = active.collectionView.bounds.size
            active.collectionView.collectionViewLayout.invalidateLayout()
            publishMetrics(for: active)
        }
        updateScopeBarHeightIfNeeded()
        layoutScopeBar(for: active)
        bringSubviewToFront(scopeBarHostView)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateBottomContentInsets()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        updateBottomContentInsets()
    }

    /// 只补足系统未自动提供的底部安全区；系统 Toolbar 高度完全由 adjustedContentInset 承担。
    private func updateBottomContentInsets() {
        let systemBottomInset = max(window?.safeAreaInsets.bottom ?? safeAreaInsets.bottom, 0)
        let targetAdjustedInset = systemBottomInset

        for context in contexts.values {
            let collectionView = context.collectionView
            let automaticInset = max(
                collectionView.adjustedContentInset.bottom - collectionView.contentInset.bottom,
                0
            )
            let targetCustomInset = max(targetAdjustedInset - automaticInset, 0)
            let needsContentInset = abs(collectionView.contentInset.bottom - targetCustomInset) > 0.5
            let needsIndicatorInset = abs(
                collectionView.verticalScrollIndicatorInsets.bottom - targetCustomInset
            ) > 0.5
            guard needsContentInset || needsIndicatorInset else { continue }

            var contentInset = collectionView.contentInset
            contentInset.bottom = targetCustomInset
            var indicatorInsets = collectionView.verticalScrollIndicatorInsets
            indicatorInsets.bottom = targetCustomInset
            UIView.performWithoutAnimation {
                collectionView.contentInset = contentInset
                collectionView.verticalScrollIndicatorInsets = indicatorInsets
            }
        }
    }

    /// 只在书籍、选中域或动态设置变化时更新 Tab 内容，滚动吸附不进入配置链路。
    private func updateScopeBarContent(animatedCanvasChange: Bool) {
        guard let book = configuration.book else {
            scopeBarContentState = nil
            scopeBarHostView.isHidden = true
            return
        }
        let nextState = BookWorkspaceScopeBarContentState(
            book: book,
            selectedSection: configuration.selectedSection,
            notesCount: configuration.notesCount,
            reduceMotion: configuration.reduceMotion,
            canvasPaletteID: configuration.canvasPaletteID
        )
        scopeBarHostView.isHidden = false
        guard nextState != scopeBarContentState else { return }
        scopeBarContentState = nextState
        scopeBarHostView.configure(
            content: AnyView(
                BookWorkspaceCollectionScopeBar(
                    book: book,
                    selectedSection: configuration.selectedSection,
                    notesCount: configuration.notesCount,
                    reduceMotion: configuration.reduceMotion,
                    canvasColor: configuration.canvasColor,
                    canvasPaletteID: configuration.canvasPaletteID,
                    onSelectSection: { [weak self] selected in
                        self?.configuration.onSelectSection(selected)
                    }
                )
            ),
            canvasColor: configuration.canvasColor,
            animated: animatedCanvasChange
        )
        setNeedsLayout()
    }

    /// 以唯一 Tab 宿主的真实内容高度刷新透明占位；该路径只在选中值、动态字体或尺寸变化时执行。
    private func updateScopeBarHeightIfNeeded() {
        guard configuration.book != nil, bounds.width > 0 else { return }
        let measuredHeight = scopeBarHostView.fittingHeight(for: bounds.width)
        guard measuredHeight.isFinite, measuredHeight > 0 else { return }
        let displayScale = window?.screen.scale ?? max(traitCollection.displayScale, 1)
        let roundedHeight = ceil(measuredHeight * displayScale) / displayScale
        let nextHeight = max(BookWorkspaceLayoutMetrics.minimumControlHeight, roundedHeight)
        guard abs(nextHeight - scopeBarHeight) >= 0.5 else { return }
        scopeBarHeight = nextHeight
        scheduleScopeBarPlaceholderRefresh()
    }

    /// 延后一帧刷新四域等高占位，避免在 UICollectionView 当前布局事务中提交 diff。
    private func scheduleScopeBarPlaceholderRefresh() {
        guard !isScopeBarPlaceholderRefreshScheduled else { return }
        isScopeBarPlaceholderRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isScopeBarPlaceholderRefreshScheduled = false
            for context in self.contexts.values {
                guard var snapshot = context.dataSource?.snapshot(),
                      snapshot.indexOfItem(.scopeBar) != nil else { continue }
                snapshot.reconfigureItems([.scopeBar])
                context.dataSource?.apply(snapshot, animatingDifferences: false)
                context.collectionView.collectionViewLayout.invalidateLayout()
            }
            self.setNeedsLayout()
        }
    }

    /// 把唯一 Tab 放到占位项或顶部吸附线中的较低位置；滚动每帧只更新 frame。
    private func layoutScopeBar(for context: BookWorkspaceCollectionDomainContext) {
        guard context.section == configuration.selectedSection,
              configuration.book != nil,
              let indexPath = context.dataSource?.indexPath(for: .scopeBar),
              let attributes = context.collectionView.layoutAttributesForItem(at: indexPath) else {
            scopeBarHostView.isHidden = true
            return
        }
        let collectionView = context.collectionView
        let inlineFrame = collectionView.convert(attributes.frame, to: self)
        let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let pinnedPoint = collectionView.convert(
            CGPoint(x: attributes.frame.minX, y: visibleTop),
            to: self
        )
        let displayScale = window?.screen.scale ?? max(traitCollection.displayScale, 1)
        let alignedPinnedY = bookWorkspacePixelAligned(pinnedPoint.y, scale: displayScale)
        let targetFrame = CGRect(
            x: inlineFrame.minX,
            y: max(inlineFrame.minY, alignedPinnedY),
            width: inlineFrame.width,
            height: scopeBarHeight
        )
        scopeBarHostView.isHidden = false
        UIView.performWithoutAnimation {
            scopeBarHostView.frame = targetFrame
            scopeBarHostView.layoutIfNeeded()
        }
    }

    private func makeDomainContext(_ section: BookWorkspaceSection) {
        let initialSnapshot = BookWorkspacePresentationSnapshot.initial(for: section)
        let collectionView = BookWorkspaceViewportStableCollectionView(
            frame: .zero,
            collectionViewLayout: UICollectionViewFlowLayout()
        )
        collectionView.translatesAutoresizingMaskIntoConstraints = false
        collectionView.backgroundColor = .clear
        collectionView.alwaysBounceVertical = true
        collectionView.showsVerticalScrollIndicator = false
        collectionView.keyboardDismissMode = .onDrag
        collectionView.contentInsetAdjustmentBehavior = .automatic
        collectionView.delaysContentTouches = false
        collectionView.topEdgeEffect.isHidden = false
        collectionView.topEdgeEffect.style = .soft
        collectionView.bottomEdgeEffect.isHidden = false
        collectionView.bottomEdgeEffect.style = .soft
        collectionView.delegate = self
        collectionView.register(
            BookWorkspaceHostingCell.self,
            forCellWithReuseIdentifier: BookWorkspaceHostingCell.reuseIdentifier
        )
        collectionView.register(
            BookWorkspaceHostingHeaderView.self,
            forSupplementaryViewOfKind: UICollectionView.elementKindSectionHeader,
            withReuseIdentifier: BookWorkspaceHostingHeaderView.reuseIdentifier
        )
        addSubview(collectionView)
        NSLayoutConstraint.activate([
            collectionView.leadingAnchor.constraint(equalTo: leadingAnchor),
            collectionView.trailingAnchor.constraint(equalTo: trailingAnchor),
            collectionView.topAnchor.constraint(equalTo: topAnchor),
            collectionView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])

        let context = BookWorkspaceCollectionDomainContext(
            section: section,
            collectionView: collectionView,
            snapshot: initialSnapshot
        )
        contexts[section] = context
        collectionView.setCollectionViewLayout(makeLayout(for: section), animated: false)
        configureDataSource(for: context)

        collectionView.onBeforeLayout = { [weak self, weak context] in
            guard let self, let context else { return }
            self.captureViewport(in: context)
        }
        collectionView.onAfterLayout = { [weak self, weak context] in
            guard let self, let context else { return }
            if context.section == self.configuration.selectedSection {
                self.layoutScopeBar(for: context)
            }
            self.publishMetrics(for: context)
        }
        collectionView.onAdjustedInsetChange = { [weak self, weak context] in
            guard let self, let context else { return }
            self.handleAdjustedInsetChange(in: context)
        }
    }

    private func configureDataSource(for context: BookWorkspaceCollectionDomainContext) {
        let section = context.section
        let dataSource = UICollectionViewDiffableDataSource<
            BookWorkspaceCollectionSectionID,
            BookWorkspaceCollectionItemID
        >(collectionView: context.collectionView) { [weak self] collectionView, indexPath, itemID in
            guard let self,
                  let cell = collectionView.dequeueReusableCell(
                    withReuseIdentifier: BookWorkspaceHostingCell.reuseIdentifier,
                    for: indexPath
                  ) as? BookWorkspaceHostingCell,
                  let item = self.contexts[section]?.snapshot.itemsByID[itemID] else {
                return nil
            }
            cell.configure(content: self.content(for: item, in: section))
            return cell
        }
        dataSource.supplementaryViewProvider = { [weak self] collectionView, kind, indexPath in
            guard kind == UICollectionView.elementKindSectionHeader,
                  let self,
                  let context = self.contexts[section],
                  context.snapshot.sections.indices.contains(indexPath.section),
                  let header = context.snapshot.sections[indexPath.section].header,
                  let view = collectionView.dequeueReusableSupplementaryView(
                    ofKind: kind,
                    withReuseIdentifier: BookWorkspaceHostingHeaderView.reuseIdentifier,
                    for: indexPath
                  ) as? BookWorkspaceHostingHeaderView else {
                return nil
            }
            view.configure(
                content: AnyView(
                    BookWorkspaceChapterHeader(
                        title: header.title,
                        count: header.count,
                        isStarred: header.isStarred,
                        canvasColor: self.configuration.canvasColor,
                        canvasPaletteID: self.configuration.canvasPaletteID,
                        reduceMotion: self.configuration.reduceMotion
                    )
                ),
                canvasColor: self.configuration.canvasColor,
                animated: false
            )
            return view
        }
        context.dataSource = dataSource
    }

    /// 从不可变载荷构建独立 Cell 视觉；这里不读取父 SwiftUI View 的 State 或 Environment。
    private func content(
        for item: BookWorkspaceCollectionItem,
        in section: BookWorkspaceSection
    ) -> AnyView {
        switch item {
        case .bookHeader:
            guard let book = configuration.book else {
                return AnyView(EmptyView())
            }
            return AnyView(
                BookWorkspaceCollectionBookHeader(
                    book: book,
                    notesCount: configuration.notesCount,
                    onOpenReadingDetail: { [weak self] in
                        self?.configuration.onOpenReadingDetail()
                    },
                    onEditBook: { [weak self] in
                        self?.configuration.onEditBook()
                    },
                    onSelectNotes: { [weak self] in
                        self?.configuration.onSelectSection(.notes)
                    }
                )
            )
        case .scopeBar:
            return AnyView(
                Color.clear
                    .frame(maxWidth: .infinity)
                    .frame(height: scopeBarHeight)
                    .accessibilityHidden(true)
            )
        case .catalog(let row):
            return AnyView(
                BookWorkspaceCatalogCollectionRow(
                    row: row,
                    onToggleExpansion: { [weak self] in
                        self?.configuration.onToggleChapter(row.chapter.id)
                    },
                    onOpen: { [weak self] in
                        self?.configuration.onOpenChapter(row.chapter)
                    }
                )
            )
        case .note(let row):
            let state = noteRowState(for: row.note.id)
            return AnyView(
                BookWorkspaceStatefulNoteItem(
                    row: row,
                    state: state,
                    onOpen: { [weak self] in
                        self?.configuration.onOpenNote(row.note)
                    },
                    onEdit: { [weak self] in
                        self?.configuration.onEditNote(row.note)
                    }
                )
            )
        case .related(let row):
            return AnyView(
                BookWorkspaceRelatedCollectionRow(row: row) { [weak self] in
                    self?.configuration.onOpenRelated(row.item)
                }
            )
        case .review(let row):
            return AnyView(
                BookWorkspaceReviewCollectionRow(row: row) { [weak self] in
                    self?.configuration.onOpenReview(row.item)
                }
            )
        case .empty(let row):
            return AnyView(BookWorkspaceCollectionEmptyRow(row: row))
        }
    }

    private func noteRowState(for noteID: Int64) -> BookWorkspaceNoteRowState {
        let state: BookWorkspaceNoteRowState
        if let existing = noteRowStates[noteID] {
            state = existing
        } else {
            state = BookWorkspaceNoteRowState()
            noteRowStates[noteID] = state
        }
        state.onExpansionChange = { [weak self] in
            self?.scheduleHeightUpdate(for: noteID)
        }
        return state
    }

    /// 等 SwiftUI 行内容提交新 intrinsic size 后，再由 UIKit 统一更新当前 Cell 高度。
    private func scheduleHeightUpdate(for noteID: Int64) {
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  let context = self.contexts[.notes],
                  let indexPath = context.dataSource?.indexPath(for: .note(noteID)),
                  let cell = context.collectionView.cellForItem(at: indexPath) else {
                return
            }
            cell.contentView.setNeedsLayout()
            let updates = {
                context.collectionView.collectionViewLayout.invalidateLayout()
                context.collectionView.layoutIfNeeded()
            }
            if self.configuration.reduceMotion {
                UIView.performWithoutAnimation(updates)
            } else {
                UIView.animate(
                    withDuration: 0.24,
                    delay: 0,
                    options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut],
                    animations: updates
                )
            }
        }
    }

    private func pruneNoteRowStates() {
        let validIDs = Set(configuration.snapshots.values.flatMap { snapshot in
            snapshot.itemsByID.keys.compactMap { itemID -> Int64? in
                guard case .note(let noteID) = itemID else { return nil }
                return noteID
            }
        })
        noteRowStates = noteRowStates.filter { validIDs.contains($0.key) }
    }

    private func apply(
        _ snapshot: BookWorkspacePresentationSnapshot,
        to context: BookWorkspaceCollectionDomainContext,
        forceReconfigureIDs: Set<BookWorkspaceCollectionItemID>
    ) {
        let revisionChanged = snapshot.revision != context.appliedRevision
        guard revisionChanged || !forceReconfigureIDs.isEmpty else { return }
        let previousItems = context.snapshot.itemsByID
        let previousDiffable = context.dataSource?.snapshot()
        context.snapshot = snapshot
        context.appliedRevision = snapshot.revision

        guard revisionChanged else {
            guard var diffable = previousDiffable else { return }
            let existing = forceReconfigureIDs.filter { diffable.indexOfItem($0) != nil }
            guard !existing.isEmpty else { return }
            diffable.reconfigureItems(Array(existing))
            context.dataSource?.apply(diffable, animatingDifferences: false)
            return
        }

        context.collectionView.collectionViewLayout.invalidateLayout()

        var diffable = NSDiffableDataSourceSnapshot<
            BookWorkspaceCollectionSectionID,
            BookWorkspaceCollectionItemID
        >()
        for section in snapshot.sections {
            diffable.appendSections([section.id])
            diffable.appendItems(section.itemIDs, toSection: section.id)
        }
        if let previousDiffable, !previousDiffable.itemIdentifiers.isEmpty {
            let changed = diffable.itemIdentifiers.filter { itemID in
                guard previousDiffable.indexOfItem(itemID) != nil else { return false }
                return forceReconfigureIDs.contains(itemID)
                    || previousItems[itemID] != snapshot.itemsByID[itemID]
            }
            diffable.reconfigureItems(changed)
        }
        context.dataSource?.apply(diffable, animatingDifferences: false)
#if DEBUG
        if context.section == .notes {
            let noteItemCount = snapshot.itemsByID.keys.reduce(into: 0) { count, itemID in
                if case .note = itemID {
                    count += 1
                }
            }
            Self.notesLogger.debug(
                "[book.workspace.notes.collection.applied] host=\(self.debugIdentifier, privacy: .public) bookID=\(self.configuration.book?.id ?? 0) state=\(self.configuration.notesLoadState.rawValue, privacy: .public) count=\(self.configuration.notesCount) items=\(noteItemCount) revision=\(snapshot.revision)"
            )
        }
#endif
    }

    /// 比较纯值配置，只刷新真正变化的书籍头部，普通父视图刷新不会触碰内容 Cell。
    private func chromeItemIDsChanged(
        in _: BookWorkspaceSection,
        from previous: BookWorkspaceCollectionConfiguration,
        to next: BookWorkspaceCollectionConfiguration
    ) -> Set<BookWorkspaceCollectionItemID> {
        var result: Set<BookWorkspaceCollectionItemID> = []
        if previous.book != next.book || previous.notesCount != next.notesCount {
            result.insert(.bookHeader)
        }
        return result
    }

    /// 只刷新屏幕内章节固定层的主题画布，不触碰普通内容 Cell 或 Diffable Snapshot。
    private func refreshVisibleContent(
        in context: BookWorkspaceCollectionDomainContext,
        animatedCanvasChange: Bool
    ) {
        for indexPath in context.collectionView.indexPathsForVisibleSupplementaryElements(
            ofKind: UICollectionView.elementKindSectionHeader
        ) {
            guard context.snapshot.sections.indices.contains(indexPath.section),
                  let header = context.snapshot.sections[indexPath.section].header,
                  let view = context.collectionView.supplementaryView(
                    forElementKind: UICollectionView.elementKindSectionHeader,
                    at: indexPath
                  ) as? BookWorkspaceHostingHeaderView else {
                continue
            }
            view.configure(
                content: AnyView(
                    BookWorkspaceChapterHeader(
                        title: header.title,
                        count: header.count,
                        isStarred: header.isStarred,
                        canvasColor: configuration.canvasColor,
                        canvasPaletteID: configuration.canvasPaletteID,
                        reduceMotion: configuration.reduceMotion
                    )
                ),
                canvasColor: configuration.canvasColor,
                animated: animatedCanvasChange
            )
        }
    }

    private func makeLayout(for scope: BookWorkspaceSection) -> UICollectionViewLayout {
        BookWorkspacePinnedHeaderCompositionalLayout(
            sectionProvider: { [weak self] sectionIndex, _ in
                guard let self,
                      let context = self.contexts[scope],
                      context.snapshot.sections.indices.contains(sectionIndex) else {
                    return Self.makeFallbackSection()
                }
                return self.makeLayoutSection(context.snapshot.sections[sectionIndex])
            },
            scopeBarHeightProvider: { [weak self] in
                self?.scopeBarHeight ?? BookWorkspaceLayoutMetrics.scopeBarEstimatedHeight
            },
            isPinnedHeaderProvider: { [weak self] indexPath in
                guard let context = self?.contexts[scope],
                      context.snapshot.sections.indices.contains(indexPath.section) else {
                    return false
                }
                return context.snapshot.sections[indexPath.section].header?.isPinned == true
            },
            nextPinnedHeaderProvider: { [weak self] indexPath in
                guard let context = self?.contexts[scope] else { return nil }
                let sections = context.snapshot.sections
                guard indexPath.section + 1 < sections.count else { return nil }
                for sectionIndex in (indexPath.section + 1)..<sections.count
                where sections[sectionIndex].header?.isPinned == true {
                    return IndexPath(item: 0, section: sectionIndex)
                }
                return nil
            }
        )
    }

    private func makeLayoutSection(
        _ model: BookWorkspaceCollectionSectionModel
    ) -> NSCollectionLayoutSection {
        let estimatedHeight: CGFloat
        let interItemSpacing: CGFloat
        let insets: NSDirectionalEdgeInsets
        switch model.style {
        case .chrome:
            estimatedHeight = 160
            interItemSpacing = 0
            insets = .zero
        case .groupedRows:
            estimatedHeight = 84
            interItemSpacing = 0
            insets = NSDirectionalEdgeInsets(
                top: model.header == nil
                    ? BookWorkspaceLayoutMetrics.sectionSpacing
                    : BookWorkspaceLayoutMetrics.chapterToFirstItemSpacing,
                leading: BookWorkspaceLayoutMetrics.pageHorizontalInset,
                bottom: BookWorkspaceLayoutMetrics.sectionSpacing,
                trailing: BookWorkspaceLayoutMetrics.pageHorizontalInset
            )
        case .noteCards:
            estimatedHeight = 180
            interItemSpacing = BookWorkspaceLayoutMetrics.itemSpacing
            insets = NSDirectionalEdgeInsets(
                top: BookWorkspaceLayoutMetrics.chapterToFirstItemSpacing,
                leading: 0,
                bottom: BookWorkspaceLayoutMetrics.sectionSpacing,
                trailing: 0
            )
        case .empty:
            estimatedHeight = 280
            interItemSpacing = 0
            insets = NSDirectionalEdgeInsets(
                top: BookWorkspaceLayoutMetrics.sectionSpacing,
                leading: BookWorkspaceLayoutMetrics.pageHorizontalInset,
                bottom: Spacing.double,
                trailing: BookWorkspaceLayoutMetrics.pageHorizontalInset
            )
        }

        let item = NSCollectionLayoutItem(
            layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(estimatedHeight)
            )
        )
        let group = NSCollectionLayoutGroup.vertical(
            layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(estimatedHeight)
            ),
            subitems: [item]
        )
        let section = NSCollectionLayoutSection(group: group)
        section.contentInsets = insets
        section.interGroupSpacing = interItemSpacing

        if let header = model.header {
            let supplementary = NSCollectionLayoutBoundarySupplementaryItem(
                layoutSize: NSCollectionLayoutSize(
                    widthDimension: .fractionalWidth(1),
                    heightDimension: .estimated(BookWorkspaceLayoutMetrics.minimumControlHeight)
                ),
                elementKind: UICollectionView.elementKindSectionHeader,
                alignment: .top
            )
            supplementary.pinToVisibleBounds = header.isPinned
            supplementary.zIndex = header.isPinned ? 10 : 1
            section.boundarySupplementaryItems = [supplementary]
        }
        return section
    }

    private static func makeFallbackSection() -> NSCollectionLayoutSection {
        let item = NSCollectionLayoutItem(
            layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(100)
            )
        )
        let group = NSCollectionLayoutGroup.vertical(
            layoutSize: NSCollectionLayoutSize(
                widthDimension: .fractionalWidth(1),
                heightDimension: .estimated(100)
            ),
            subitems: [item]
        )
        return NSCollectionLayoutSection(group: group)
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        guard let context = context(for: scrollView), context.section == configuration.selectedSection else {
            return
        }
        captureViewport(in: context)
        layoutScopeBar(for: context)
        publishMetrics(for: context)
    }

    private func publishMetrics(for context: BookWorkspaceCollectionDomainContext) {
        guard context.section == configuration.selectedSection else { return }
        let collectionView = context.collectionView
        let rawOffset = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let effectiveOffset = rawOffset.isFinite ? rawOffset : 0
        let viewportTop = collectionView.window.map { window in
            let frameTop = collectionView.convert(collectionView.bounds.origin, to: window).y
            return frameTop + max(collectionView.adjustedContentInset.top, 0)
        } ?? 0
        let scopeIndexPath = context.dataSource?.indexPath(for: .scopeBar)
        let scopeAttributes = scopeIndexPath.flatMap { collectionView.layoutAttributesForItem(at: $0) }
        let pinOffset = scopeAttributes?.frame.minY ?? 0
        let metrics = BookWorkspaceCollectionScrollMetrics(
            effectiveOffset: effectiveOffset,
            viewportTop: viewportTop.isFinite ? max(viewportTop, 0) : 0,
            pinOffset: pinOffset
        )
        guard metrics != context.lastPublishedMetrics else { return }
        context.lastPublishedMetrics = metrics
        pendingMetrics[context.section] = metrics
        scheduleMetricsDeliveryIfNeeded()
    }

    /// 将 UIKit 布局回调延后到当前 SwiftUI 更新事务结束后再发布，避免 updateUIView 内同步回写父状态。
    private func scheduleMetricsDeliveryIfNeeded() {
        guard !isMetricsDeliveryScheduled else { return }
        isMetricsDeliveryScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isMetricsDeliveryScheduled = false
            let deliveries = self.pendingMetrics
            self.pendingMetrics.removeAll(keepingCapacity: true)
            for (section, metrics) in deliveries {
                self.configuration.onScrollMetricsChange(section, metrics)
            }
        }
    }

    private func context(for scrollView: UIScrollView) -> BookWorkspaceCollectionDomainContext? {
        contexts.values.first { $0.collectionView === scrollView }
    }

    private func captureViewport(in context: BookWorkspaceCollectionDomainContext) {
        guard !context.isRestoringViewport, !context.isCapturingViewportSuspended else { return }
        let collectionView = context.collectionView
        context.fallbackOffsetY = collectionView.contentOffset.y
        let visibleTop = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        let candidate = collectionView.indexPathsForVisibleItems.compactMap { indexPath -> (IndexPath, CGRect)? in
            guard let attributes = collectionView.layoutAttributesForItem(at: indexPath),
                  attributes.frame.maxY >= visibleTop - 1 else {
                return nil
            }
            return (indexPath, attributes.frame)
        }.sorted { lhs, rhs in
            if abs(lhs.1.minY - rhs.1.minY) > 0.5 {
                return lhs.1.minY < rhs.1.minY
            }
            return lhs.1.minX < rhs.1.minX
        }.first
        guard let candidate,
              let itemID = context.dataSource?.itemIdentifier(for: candidate.0) else { return }
        context.viewportAnchor = .init(
            itemID: itemID,
            distanceFromVisibleTop: candidate.1.minY - visibleTop
        )
    }

    private func handleAdjustedInsetChange(in context: BookWorkspaceCollectionDomainContext) {
        guard !context.isRestoringViewport, !context.isCapturingViewportSuspended else {
            context.lastAdjustedInset = context.collectionView.adjustedContentInset
            return
        }
        let nextInset = context.collectionView.adjustedContentInset
        guard nextInset != context.lastAdjustedInset else { return }
        UIView.performWithoutAnimation {
            restoreViewport(in: context)
            context.lastAdjustedInset = nextInset
            captureViewport(in: context)
            if context.section == configuration.selectedSection {
                layoutScopeBar(for: context)
            }
        }
    }

    private func restoreViewport(in context: BookWorkspaceCollectionDomainContext) {
        context.isRestoringViewport = true
        defer { context.isRestoringViewport = false }
        let collectionView = context.collectionView
        let targetY: CGFloat
        if let anchor = context.viewportAnchor,
           let indexPath = context.dataSource?.indexPath(for: anchor.itemID),
           let attributes = collectionView.layoutAttributesForItem(at: indexPath) {
            let visibleTop = attributes.frame.minY - anchor.distanceFromVisibleTop
            targetY = visibleTop - collectionView.adjustedContentInset.top
        } else {
            targetY = context.fallbackOffsetY
        }
        let minimumY = -collectionView.adjustedContentInset.top
        let maximumY = max(
            minimumY,
            collectionView.contentSize.height - collectionView.bounds.height
                + collectionView.adjustedContentInset.bottom
        )
        let clampedY = min(max(targetY, minimumY), maximumY)
        guard abs(collectionView.contentOffset.y - clampedY) > 0.5 else { return }
        collectionView.setContentOffset(
            CGPoint(x: collectionView.contentOffset.x, y: clampedY),
            animated: false
        )
    }

    func collectionView(_ collectionView: UICollectionView, prefetchItemsAt indexPaths: [IndexPath]) {
        guard let context = context(for: collectionView),
              context.section == configuration.selectedSection else { return }
        let noteIDs = indexPaths.compactMap { indexPath -> Int64? in
            guard let itemID = context.dataSource?.itemIdentifier(for: indexPath),
                  case .note(let noteID) = itemID else { return nil }
            return noteID
        }
        enqueuePrewarming(noteIDs.prefix(8), in: context)
    }

    func collectionView(
        _ collectionView: UICollectionView,
        cancelPrefetchingForItemsAt indexPaths: [IndexPath]
    ) {
        guard let context = context(for: collectionView) else { return }
        let cancelled = Set(indexPaths.compactMap { indexPath -> Int64? in
            guard let itemID = context.dataSource?.itemIdentifier(for: indexPath),
                  case .note(let noteID) = itemID else { return nil }
            return noteID
        })
        context.pendingPrewarmIDs.removeAll { cancelled.contains($0) }
    }

    private func enqueuePrewarming<S: Sequence>(
        _ noteIDs: S,
        in context: BookWorkspaceCollectionDomainContext
    ) where S.Element == Int64 {
        for noteID in noteIDs where !context.pendingPrewarmIDs.contains(noteID) {
            context.pendingPrewarmIDs.append(noteID)
        }
        guard context.prewarmTask == nil else { return }
        context.prewarmTask = Task { [weak self, weak context] in
            guard let self, let context else { return }
            while !Task.isCancelled, context.section == self.configuration.selectedSection {
                guard !context.pendingPrewarmIDs.isEmpty else { break }
                let noteID = context.pendingPrewarmIDs.removeFirst()
                await Task.yield()
                guard let item = context.snapshot.itemsByID[.note(noteID)],
                      case .note(let row) = item else { continue }
                self.prewarm(row.note, in: context.collectionView)
            }
            context.prewarmTask = nil
        }
    }

    private func prewarm(_ note: NoteExcerpt, in collectionView: UICollectionView) {
        let width = max(
            1,
            collectionView.bounds.width
                - BookWorkspaceLayoutMetrics.pageHorizontalInset * 2
                - BookWorkspaceLayoutMetrics.cardContentInset * 2
        )
        let traits = collectionView.traitCollection
        let scale = collectionView.window?.screen.scale ?? max(traits.displayScale, 1)
        if note.hasSourceContent {
            RichText.prewarmPreviewLayoutSnapshot(
                html: note.content,
                baseFont: NoteExcerptTypography.uiBody,
                textColor: UIColor(Color.textPrimary),
                lineSpacing: NoteExcerptTypography.bodyLineSpacing,
                maxLines: 6,
                width: width,
                traitCollection: traits,
                screenScale: scale
            )
        }
        if note.hasSourceIdea {
            RichText.prewarmPreviewLayoutSnapshot(
                html: note.idea,
                baseFont: NoteExcerptTypography.uiIdea,
                textColor: UIColor(Color.textSecondary),
                lineSpacing: NoteExcerptTypography.ideaLineSpacing,
                maxLines: 4,
                width: max(1, width - Spacing.base - Spacing.micro),
                traitCollection: traits,
                screenScale: scale
            )
        }
    }

    private func cancelPrewarming(in context: BookWorkspaceCollectionDomainContext) {
        context.prewarmTask?.cancel()
        context.prewarmTask = nil
        context.pendingPrewarmIDs.removeAll(keepingCapacity: true)
    }
}

/// 在 Collection 自己的 Hosting 图中重建书籍头部，避免复用父页面 View 值导致跨 AttributeGraph 访问。
private struct BookWorkspaceCollectionBookHeader: View {
    let book: BookDetail
    let notesCount: Int
    let onOpenReadingDetail: () -> Void
    let onEditBook: () -> Void
    let onSelectNotes: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    private enum Layout {
        static let coverWidth: CGFloat = 104
    }

    var body: some View {
        Group {
            if dynamicTypeSize.isAccessibilitySize {
                VStack(alignment: .leading, spacing: BookWorkspaceLayoutMetrics.sectionSpacing) {
                    identity
                    HStack(alignment: .bottom, spacing: BookWorkspaceLayoutMetrics.sectionSpacing) {
                        cover
                        Spacer(minLength: Spacing.base)
                    }
                    metricsVertical
                }
            } else {
                HStack(alignment: .top, spacing: BookWorkspaceLayoutMetrics.sectionSpacing) {
                    identity
                        .padding(.bottom, BookWorkspaceLayoutMetrics.headerMetricsReservedHeight)
                    Spacer(minLength: Spacing.base)
                    cover
                }
                .overlay(alignment: .bottomLeading) {
                    metrics
                        .padding(.trailing, Layout.coverWidth + BookWorkspaceLayoutMetrics.sectionSpacing)
                }
            }
        }
        .padding(.horizontal, BookWorkspaceLayoutMetrics.headerHorizontalInset)
        .padding(.top, BookWorkspaceLayoutMetrics.headerTopInset)
        .padding(.bottom, BookWorkspaceLayoutMetrics.headerBottomInset)
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: BookWorkspaceLayoutMetrics.identityPrimarySpacing) {
            Text(book.name)
                .font(AppTypography.title2)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityHeading(.h1)

            if !book.author.isEmpty || !publishingLine.isEmpty {
                VStack(
                    alignment: .leading,
                    spacing: BookWorkspaceLayoutMetrics.identitySecondarySpacing
                ) {
                    if !book.author.isEmpty {
                        Text(book.author)
                            .font(AppTypography.subheadline)
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(2)
                    }

                    if !publishingLine.isEmpty {
                        Text(publishingLine)
                            .font(AppTypography.footnote)
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(2)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cover: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onOpenReadingDetail) {
                XMBookCover.fixedWidth(
                    Layout.coverWidth,
                    urlString: book.cover,
                    cornerRadius: CornerRadius.inlaySmall,
                    border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                    placeholderIconSize: .large,
                    surfaceStyle: .spine
                )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("查看《\(book.name)》阅读详情")

            if !readStatusTitle.isEmpty {
                Button(action: onEditBook) {
                    BookshelfCoverTextBadge(
                        text: readStatusTitle,
                        placement: .topTrailing,
                        tone: .status(readStatusColor),
                        cornerRadius: CornerRadius.inlaySmall,
                        accessibilityLabel: "阅读状态\(readStatusTitle)"
                    )
                    .frame(
                        minWidth: BookWorkspaceLayoutMetrics.minimumControlHeight,
                        minHeight: BookWorkspaceLayoutMetrics.minimumControlHeight,
                        alignment: .topTrailing
                    )
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("阅读状态\(readStatusTitle)")
                .accessibilityHint("打开书籍编辑页修改阅读状态")
            }
        }
    }

    private var readStatusTitle: String {
        book.readStatusName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var readStatusColor: Color {
        BookEntryReadingStatus.matchingCoverBadgeTitle(readStatusTitle)?.coverBadgeColor
            ?? Color.textSecondary
    }

    private var metricsVertical: some View {
        VStack(alignment: .leading, spacing: Spacing.none) {
            readingMetric
            notesMetric
            ratingMetric
            optionalProgressMetric
        }
    }

    private var metrics: some View {
        HStack(spacing: BookWorkspaceLayoutMetrics.metricsSpacing) {
            readingMetric
            notesMetric
            ratingMetric
            optionalProgressMetric
            Spacer(minLength: 0)
        }
    }

    private var readingMetric: some View {
        metricButton(
            icon: "clock",
            title: durationText,
            accessibilityLabel: "阅读时长，\(durationText)",
            action: onOpenReadingDetail
        )
    }

    private var notesMetric: some View {
        metricButton(
            icon: "text.quote",
            title: "\(notesCount) 条",
            accessibilityLabel: "书摘 \(notesCount) 条",
            action: onSelectNotes
        )
    }

    private var ratingMetric: some View {
        metricButton(
            icon: book.score > 0 ? "star.fill" : "star",
            title: book.score > 0
                ? String(format: "%.1f", Double(book.score) / 10)
                : "未评分",
            accessibilityLabel: ratingAccessibilityLabel,
            iconColor: book.score > 0 ? Color.ratingActive : Color.textSecondary,
            textColor: Color.textSecondary,
            action: onEditBook
        )
    }

    @ViewBuilder
    private var optionalProgressMetric: some View {
        if !book.readingProgressText.isEmpty {
            metricButton(
                icon: "chart.line.uptrend.xyaxis",
                title: book.readingProgressText,
                accessibilityLabel: "阅读进度 \(book.readingProgressText)",
                action: onEditBook
            )
        } else if !book.bookmarkText.isEmpty {
            metricButton(
                icon: "bookmark",
                title: book.bookmarkText,
                accessibilityLabel: "书签 \(book.bookmarkText)",
                action: onEditBook
            )
        }
    }

    /// 构建保持 44pt 热区的指标入口，不增加额外视觉容器。
    private func metricButton(
        icon: String,
        title: String,
        accessibilityLabel: String,
        iconColor: Color = Color.textSecondary,
        textColor: Color = Color.textSecondary,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: Spacing.half) {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                Text(title)
                    .foregroundStyle(textColor)
                    .lineLimit(1)
            }
            .font(AppTypography.caption)
            .frame(minHeight: BookWorkspaceLayoutMetrics.minimumControlHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    private var publishingLine: String {
        var parts: [String] = []
        if !book.press.isEmpty {
            parts.append(book.press)
        }
        if let pubDate = book.attributes.first(where: { $0.kind == .pubDate })?.value,
           !pubDate.isEmpty {
            parts.append(pubDate)
        }
        return parts.joined(separator: " · ")
    }

    private var durationText: String {
        let seconds = max(0, book.totalReadingSeconds)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)小时\(minutes)分" : "\(hours)小时"
        }
        return "\(minutes)分钟"
    }

    private var ratingAccessibilityLabel: String {
        guard book.score > 0 else { return "我的评分，未评分" }
        return "我的评分，\(String(format: "%.1f", Double(book.score) / 10))"
    }
}

/// 在 Collection 的唯一 Hosting 图中构建四域内容导航，搜索由页面系统 Toolbar 独立承载。
private struct BookWorkspaceCollectionScopeBar: View {
    let book: BookDetail
    let selectedSection: BookWorkspaceSection
    let notesCount: Int
    let reduceMotion: Bool
    let canvasColor: Color
    let canvasPaletteID: UInt64
    let onSelectSection: (BookWorkspaceSection) -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        tabs
            .background(canvasColor)
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.18),
                value: canvasPaletteID
            )
    }

    private var tabs: some View {
        HStack(spacing: Spacing.none) {
            ForEach(BookWorkspaceSection.allCases, id: \.self) { item in
                Button {
                    onSelectSection(item)
                } label: {
                    tabLabel(for: item)
                        .frame(
                            maxWidth: .infinity,
                            minHeight: BookWorkspaceLayoutMetrics.minimumControlHeight
                        )
                        .overlay(alignment: .bottom) {
                            Capsule()
                                .fill(Color.textPrimary.opacity(0.52))
                                .frame(width: 24, height: 3)
                                .padding(.bottom, Spacing.compact)
                                .opacity(item == selectedSection ? 1 : 0)
                                .animation(
                                    reduceMotion ? nil : .snappy(duration: 0.16),
                                    value: selectedSection
                                )
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(item.title)，\(count(for: item)) 项")
                .accessibilityAddTraits(item == selectedSection ? .isSelected : [])
            }
        }
        .padding(.horizontal, BookWorkspaceLayoutMetrics.pageHorizontalInset)
    }

    @ViewBuilder
    private func tabLabel(for item: BookWorkspaceSection) -> some View {
        let titleColor = item == selectedSection ? Color.textPrimary : Color.textSecondary

        if dynamicTypeSize.isAccessibilitySize {
            VStack(spacing: Spacing.half) {
                Text(item.title)
                    .font(AppTypography.subheadlineMedium)
                    .foregroundStyle(titleColor)
                Text("\(count(for: item))")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
            }
            .lineLimit(1)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: Spacing.compact) {
                Text(item.title)
                    .font(AppTypography.subheadlineMedium)
                    .foregroundStyle(titleColor)
                Text("\(count(for: item))")
                    .font(AppTypography.caption)
                    .foregroundStyle(Color.textSecondary)
            }
            .lineLimit(1)
        }
    }

    private func count(for section: BookWorkspaceSection) -> Int {
        switch section {
        case .catalog: book.chapters.count
        case .notes: notesCount
        case .related: book.relatedCount
        case .reviews: book.reviewCount
        }
    }

}

/// 为分组型 Cell 绘制外层连续圆角与内部轻分隔，Cell 本身仍可独立回收。
private struct BookWorkspaceGroupedCollectionSurface<Content: View>: View {
    let isFirst: Bool
    let isLast: Bool
    let dividerLeading: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        let shape = UnevenRoundedRectangle(
            topLeadingRadius: isFirst ? CornerRadius.blockLarge : 0,
            bottomLeadingRadius: isLast ? CornerRadius.blockLarge : 0,
            bottomTrailingRadius: isLast ? CornerRadius.blockLarge : 0,
            topTrailingRadius: isFirst ? CornerRadius.blockLarge : 0,
            style: .continuous
        )
        VStack(spacing: Spacing.none) {
            content
            if !isLast {
                Divider()
                    .padding(.leading, dividerLeading)
            }
        }
        .background(BookWorkspaceCardSurfaceStyle.fill)
        .clipShape(shape)
        .overlay {
            shape
                .strokeBorder(
                    BookWorkspaceCardSurfaceStyle.border,
                    lineWidth: CardStyle.borderWidth
                )
                .mask {
                    BookWorkspaceGroupedSurfaceBorderMask(
                        showsTop: isFirst,
                        showsBottom: isLast
                    )
                }
        }
    }
}

/// 分组卡片描边遮罩仅保留整组外轮廓，避免相邻 Cell 之间出现重复横线。
private struct BookWorkspaceGroupedSurfaceBorderMask: View {
    let showsTop: Bool
    let showsBottom: Bool

    private enum Layout {
        static let edgeMaskThickness: CGFloat = 2
        static let cornerMaskDepth = CornerRadius.blockLarge + edgeMaskThickness
    }

    var body: some View {
        ZStack {
            HStack(spacing: Spacing.none) {
                Rectangle()
                    .frame(width: Layout.edgeMaskThickness)
                Spacer(minLength: 0)
                Rectangle()
                    .frame(width: Layout.edgeMaskThickness)
            }

            VStack(spacing: Spacing.none) {
                if showsTop {
                    Rectangle()
                        .frame(height: Layout.cornerMaskDepth)
                }
                Spacer(minLength: 0)
                if showsBottom {
                    Rectangle()
                        .frame(height: Layout.cornerMaskDepth)
                }
            }
        }
        .foregroundStyle(.white)
    }
}

/// 目录 Cell，保持层级缩进、收藏与书摘数量，同时把展开和打开动作交给页面 owner。
private struct BookWorkspaceCatalogCollectionRow: View {
    let row: BookWorkspaceCatalogRow
    let onToggleExpansion: () -> Void
    let onOpen: () -> Void

    private let chapterIndent: CGFloat = 18

    var body: some View {
        BookWorkspaceGroupedCollectionSurface(
            isFirst: row.isFirst,
            isLast: row.isLast,
            dividerLeading: BookWorkspaceLayoutMetrics.cardContentInset
                + CGFloat(max(0, row.chapter.level - 1)) * chapterIndent
        ) {
            HStack(spacing: Spacing.cozy) {
                if row.hasChildren {
                    Button(action: onToggleExpansion) {
                        Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                            .font(AppTypography.captionSemibold)
                            .foregroundStyle(Color.textSecondary)
                            .frame(width: Spacing.double, height: Spacing.actionReserved)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(row.isExpanded ? "收起章节" : "展开章节")
                } else {
                    Color.clear.frame(width: Spacing.double)
                }

                Button(action: onOpen) {
                    HStack(spacing: Spacing.cozy) {
                        VStack(alignment: .leading, spacing: Spacing.compact) {
                            Text(row.chapter.title)
                                .font(AppTypography.body)
                                .foregroundStyle(Color.textPrimary)
                                .multilineTextAlignment(.leading)
                            if row.chapter.noteCount > 0 {
                                Text("\(row.chapter.noteCount) 条书摘")
                                    .font(AppTypography.caption)
                                    .foregroundStyle(Color.textSecondary)
                            }
                        }
                        Spacer(minLength: Spacing.base)
                        if row.chapter.isStarred {
                            Image(systemName: "star.fill")
                                .foregroundStyle(Color.ratingActive)
                                .accessibilityLabel("已收藏")
                        }
                        Image(systemName: "chevron.right")
                            .font(AppTypography.captionSemibold)
                            .foregroundStyle(Color.textHint)
                    }
                    .frame(minHeight: Spacing.actionReserved)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .padding(
                .leading,
                BookWorkspaceLayoutMetrics.cardContentInset
                    + CGFloat(max(0, row.chapter.level - 1)) * chapterIndent
            )
            .padding(.trailing, BookWorkspaceLayoutMetrics.cardContentInset)
            .padding(.vertical, Spacing.compact)
        }
    }
}

/// 相关内容 Cell，覆盖普通内容和关联书籍两类真实记录。
private struct BookWorkspaceRelatedCollectionRow: View {
    let row: BookWorkspaceRelatedRow
    let onOpen: () -> Void

    var body: some View {
        BookWorkspaceGroupedCollectionSurface(
            isFirst: row.isFirst,
            isLast: row.isLast,
            dividerLeading: BookWorkspaceLayoutMetrics.cardContentInset
        ) {
            Button(action: onOpen) {
                if row.item.linkedBookID > 0 {
                    linkedBookContent
                } else {
                    relatedTextContent
                }
            }
            .buttonStyle(.plain)
        }
    }

    private var linkedBookContent: some View {
        HStack(spacing: Spacing.base) {
            XMBookCover.fixedWidth(
                48,
                urlString: row.item.linkedBookCover,
                cornerRadius: CornerRadius.inlaySmall,
                border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                placeholderIconSize: .small
            )
            VStack(alignment: .leading, spacing: Spacing.compact) {
                Text(row.item.linkedBookTitle.isEmpty ? "关联书籍" : row.item.linkedBookTitle)
                    .font(AppTypography.bodyMedium)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
                if !row.item.linkedBookAuthor.isEmpty {
                    Text(row.item.linkedBookAuthor)
                        .font(AppTypography.footnote)
                        .foregroundStyle(Color.textSecondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: Spacing.base)
            Image(systemName: "chevron.right")
                .font(AppTypography.captionSemibold)
                .foregroundStyle(Color.textHint)
        }
        .padding(BookWorkspaceLayoutMetrics.cardContentInset)
    }

    private var relatedTextContent: some View {
        VStack(alignment: .leading, spacing: Spacing.cozy) {
            if !row.item.title.isEmpty {
                Text(row.item.title)
                    .font(AppTypography.bodyMedium)
                    .foregroundStyle(Color.textPrimary)
                    .lineLimit(2)
            }
            if !row.item.contentPlainText.isEmpty {
                Text(row.item.contentPlainText)
                    .font(AppTypography.subheadline)
                    .foregroundStyle(Color.textSecondary)
                    .lineLimit(4)
                    .multilineTextAlignment(.leading)
            }
            HStack {
                if !row.item.url.isEmpty {
                    Label("链接", systemImage: "link")
                }
                Spacer(minLength: Spacing.base)
                if !row.dateText.isEmpty {
                    Text(row.dateText)
                }
            }
            .font(AppTypography.caption)
            .foregroundStyle(Color.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(BookWorkspaceLayoutMetrics.cardContentInset)
        .contentShape(Rectangle())
    }
}

/// 书评 Cell，标题优先、正文摘要次之，并保持一整行可点击。
private struct BookWorkspaceReviewCollectionRow: View {
    let row: BookWorkspaceReviewRow
    let onOpen: () -> Void

    var body: some View {
        BookWorkspaceGroupedCollectionSurface(
            isFirst: row.isFirst,
            isLast: row.isLast,
            dividerLeading: BookWorkspaceLayoutMetrics.cardContentInset
        ) {
            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: Spacing.cozy) {
                    Text(row.item.title.isEmpty ? "书评" : row.item.title)
                        .font(AppTypography.headline)
                        .foregroundStyle(Color.textPrimary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                    if !row.item.contentPlainText.isEmpty {
                        Text(row.item.contentPlainText)
                            .font(AppTypography.subheadline)
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(5)
                            .multilineTextAlignment(.leading)
                    }
                    if !row.dateText.isEmpty {
                        Text(row.dateText)
                            .font(AppTypography.caption)
                            .foregroundStyle(Color.textSecondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(BookWorkspaceLayoutMetrics.cardContentInset)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }
}

/// Collection 内的系统空态，保持页面其它域相同的信息密度和辅助技术语义。
private struct BookWorkspaceCollectionEmptyRow: View {
    let row: BookWorkspaceEmptyRow

    var body: some View {
        ContentUnavailableView(
            row.title,
            systemImage: row.systemImage,
            description: Text(row.description)
        )
        .frame(maxWidth: .infinity)
        .padding(.vertical, Spacing.double)
    }
}
