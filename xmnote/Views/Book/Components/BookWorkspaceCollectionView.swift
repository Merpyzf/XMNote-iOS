/**
 * [INPUT]: 依赖 BookWorkspacePresentationSnapshot、书籍工作台主题色板、SwiftUI 行内容构建器与 UIKit UICollectionView
 * [OUTPUT]: 对外提供贯穿顶部安全区和完整 Header、在 Tab 内延迟衰减并于吸顶后归中性的沉浸主题背景，自适应书名状态行、无遮挡书脊封面、分行出版元数据、按有效评分收放的封面胶囊、与 Android 数据语义对齐且带动态边缘渐隐的三项阅读指标 Chip、共享可收起书籍头部、几何稳定的吸顶 Tab 与纯内容原生 Pager
 * [POS]: Views/Book/Components 的页面私有 UIKit 混合列表，负责背景/内容分层、分页、共享 Chrome、diff、章节吸顶和视口稳定
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

/// 四域常驻 UIKit 混合列表；SwiftUI 只提供可复用 Cell 的视觉内容。
struct BookWorkspaceCollectionView: UIViewRepresentable {
    let book: BookDetail
    let snapshots: [BookWorkspaceSection: BookWorkspacePresentationSnapshot]
    let committedSection: BookWorkspaceSection
    let notesCount: Int
    let notesLoadState: BookNotesLoadState
    let reduceMotion: Bool
    let canvasColor: Color
    let contentSurfaceColor: Color
    let headerLeadingColor: Color
    let headerTrailingColor: Color
    let canvasPaletteID: UInt64
    let onSectionCommit: (BookWorkspaceSection) -> Void
    let onNavigationBarSurfaceChange: (Bool) -> Void
    let onOpenReadingDetail: () -> Void
    let onEditBook: () -> Void
    let onToggleChapter: (Int64) -> Void
    let onOpenChapter: (BookDetailChapter) -> Void
    let onOpenNote: (NoteExcerpt) -> Void
    let onEditNote: (NoteExcerpt) -> Void
    let onOpenRelated: (BookRelatedExcerpt) -> Void
    let onOpenReview: (BookReviewExcerpt) -> Void

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
            committedSection: committedSection,
            notesCount: notesCount,
            notesLoadState: notesLoadState,
            reduceMotion: reduceMotion,
            canvasColor: canvasColor,
            contentSurfaceColor: contentSurfaceColor,
            headerLeadingColor: headerLeadingColor,
            headerTrailingColor: headerTrailingColor,
            canvasPaletteID: canvasPaletteID,
            onSectionCommit: onSectionCommit,
            onNavigationBarSurfaceChange: onNavigationBarSurfaceChange,
            onOpenReadingDetail: onOpenReadingDetail,
            onEditBook: onEditBook,
            onToggleChapter: onToggleChapter,
            onOpenChapter: onOpenChapter,
            onOpenNote: onOpenNote,
            onEditNote: onEditNote,
            onOpenRelated: onOpenRelated,
            onOpenReview: onOpenReview
        )
    }
}

/// UIKit 宿主消费的页面配置；闭包只在配置可见 Cell 时调用，不参与 diff 身份。
@MainActor
private struct BookWorkspaceCollectionConfiguration {
    let book: BookDetail?
    let snapshots: [BookWorkspaceSection: BookWorkspacePresentationSnapshot]
    let committedSection: BookWorkspaceSection
    let notesCount: Int
    let notesLoadState: BookNotesLoadState
    let reduceMotion: Bool
    let canvasColor: Color
    let contentSurfaceColor: Color
    let headerLeadingColor: Color
    let headerTrailingColor: Color
    let canvasPaletteID: UInt64
    let onSectionCommit: (BookWorkspaceSection) -> Void
    let onNavigationBarSurfaceChange: (Bool) -> Void
    let onOpenReadingDetail: () -> Void
    let onEditBook: () -> Void
    let onToggleChapter: (Int64) -> Void
    let onOpenChapter: (BookDetailChapter) -> Void
    let onOpenNote: (NoteExcerpt) -> Void
    let onEditNote: (NoteExcerpt) -> Void
    let onOpenRelated: (BookRelatedExcerpt) -> Void
    let onOpenReview: (BookReviewExcerpt) -> Void

    static let empty = BookWorkspaceCollectionConfiguration(
        book: nil,
        snapshots: Dictionary(
            uniqueKeysWithValues: BookWorkspaceSection.allCases.map {
                ($0, BookWorkspacePresentationSnapshot.initial(for: $0))
            }
        ),
        committedSection: .notes,
        notesCount: 0,
        notesLoadState: .loading,
        reduceMotion: false,
        canvasColor: Color.surfacePage,
        contentSurfaceColor: Color.surfaceCard,
        headerLeadingColor: Color.surfacePage,
        headerTrailingColor: Color.surfacePage,
        canvasPaletteID: 0,
        onSectionCommit: { _ in },
        onNavigationBarSurfaceChange: { _ in },
        onOpenReadingDetail: {},
        onEditBook: {},
        onToggleChapter: { _ in },
        onOpenChapter: { _ in },
        onOpenNote: { _ in },
        onEditNote: { _ in },
        onOpenRelated: { _ in },
        onOpenReview: { _ in }
    )
}

/// 向宿主暴露 automatic inset 与布局周期，便于安全区变更时保持同一业务 Item 的视觉位置。
private final class BookWorkspaceViewportStableCollectionView: UICollectionView {
    var onAdjustedInsetChange: (() -> Void)?

    override func adjustedContentInsetDidChange() {
        super.adjustedContentInsetDidChange()
        onAdjustedInsetChange?()
    }
}

/// 在 UIKit 原生 section pin/push-off 结果上校准物理像素，保持章节标题稳定贴合内容视口顶部。
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

    /// 复用系统原生 header frame，把可见顶边对齐到独立内容视口；下一 Header 仍逐点推出当前 Header。
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
            + scopeBarHeightProvider()
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

/// 页面唯一的 SwiftUI 书籍头部宿主；四个列表只保留等高占位，不各自创建头部实例。
private final class BookWorkspaceBookHeaderHostView: UIView {
    private var hostedContentView: (UIView & UIContentView)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 复用同一个 UIContentView 更新书籍信息与主题，避免切页创建新的 Header Hosting 树。
    func configure(content: AnyView) {
        let configuration = UIHostingConfiguration {
            content
        }
        .margins(.all, 0)
        .background(Color.clear)
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

    /// 在给定页面宽度下读取 SwiftUI Header 的真实动态高度。
    func fittingHeight(for width: CGFloat) -> CGFloat {
        guard let hostedContentView, width > 0 else { return 0 }
        return hostedContentView.systemLayoutSizeFitting(
            CGSize(width: width, height: UIView.layoutFittingCompressedSize.height),
            withHorizontalFittingPriority: .required,
            verticalFittingPriority: .fittingSizeLevel
        ).height
    }
}

/// 只绘制可越过顶部安全区的封面主题氛围；交互内容由独立裁切层限制在导航栏下方。
private final class BookWorkspaceHeaderBackdropView: UIView {
    private let colorGradientLayer = CAGradientLayer()
    private let verticalFadeMaskLayer = CAGradientLayer()
    private var fadeHeight = BookWorkspaceLayoutMetrics.scopeBarEstimatedHeight

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        clipsToBounds = true

        colorGradientLayer.startPoint = CGPoint(x: 0, y: 0.5)
        colorGradientLayer.endPoint = CGPoint(x: 1, y: 0.5)
        verticalFadeMaskLayer.startPoint = CGPoint(x: 0.5, y: 0)
        verticalFadeMaskLayer.endPoint = CGPoint(x: 0.5, y: 1)
        verticalFadeMaskLayer.colors = [
            UIColor.black.cgColor,
            UIColor.black.cgColor,
            UIColor.black.withAlphaComponent(
                BookWorkspaceLayoutMetrics.scopeBackdropFadeKneeOpacity
            ).cgColor,
            UIColor.clear.cgColor
        ]
        colorGradientLayer.mask = verticalFadeMaskLayer
        layer.addSublayer(colorGradientLayer)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 更新不透明画布和主题色；仅主题切换使用淡入淡出，滚动过程只改变外层 Frame。
    func configure(
        canvasColor: Color,
        leadingColor: Color,
        trailingColor: Color,
        animated: Bool
    ) {
        let resolvedCanvasColor = UIColor(canvasColor).resolvedColor(with: traitCollection)
        let resolvedLeadingColor = UIColor(leadingColor).resolvedColor(with: traitCollection)
        let resolvedTrailingColor = UIColor(trailingColor).resolvedColor(with: traitCollection)

        if animated {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.18
            transition.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer.add(transition, forKey: "bookWorkspaceBackdropPalette")
            colorGradientLayer.add(transition, forKey: "bookWorkspaceBackdropGradient")
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.backgroundColor = resolvedCanvasColor.cgColor
        colorGradientLayer.colors = [
            resolvedLeadingColor.cgColor,
            resolvedTrailingColor.cgColor
        ]
        CATransaction.commit()
    }

    /// 使用 Tab 的真实高度定义主题色衰减区，Header 内容高度变化不会移动视觉边界。
    func updateFadeHeight(_ value: CGFloat) {
        let nextValue = max(value, 0)
        guard abs(nextValue - fadeHeight) >= Spacing.hairline else { return }
        fadeHeight = nextValue
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let height = max(bounds.height, 1)
        let resolvedFadeHeight = min(max(fadeHeight, 0), height)
        let fadeStart = 1 - resolvedFadeHeight / height
        let fadeKnee = fadeStart
            + (1 - fadeStart) * BookWorkspaceLayoutMetrics.scopeBackdropFadeKneeProgress
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        colorGradientLayer.frame = bounds
        verticalFadeMaskLayer.frame = colorGradientLayer.bounds
        verticalFadeMaskLayer.locations = [
            0,
            NSNumber(value: Double(fadeStart)),
            NSNumber(value: Double(fadeKnee)),
            1
        ]
        CATransaction.commit()
    }
}

/// 原生 Tab 的稳定展示载荷；数量变化不会改变标题锚点语义。
private struct BookWorkspaceScopeBarItem: Equatable {
    let section: BookWorkspaceSection
    let title: String
    let count: Int
}

/// 单个 Tab 控件，使用系统字体缩放并把标题与数量组合为一个辅助技术元素。
@MainActor
private final class BookWorkspaceScopeTabControl: UIControl {
    let section: BookWorkspaceSection
    let titleLabel = UILabel()
    private let countLabel = UILabel()
    private let stackView = UIStackView()
    private var traitRegistration: (any UITraitChangeRegistration)?

    init(item: BookWorkspaceScopeBarItem) {
        section = item.section
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isAccessibilityElement = true
        accessibilityTraits = .button

        titleLabel.font = AppTypography.uiSemantic(.subheadline, weight: .semibold)
        titleLabel.adjustsFontForContentSizeCategory = true
        titleLabel.numberOfLines = 1
        titleLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        countLabel.font = AppTypography.uiSemantic(.caption1)
        countLabel.adjustsFontForContentSizeCategory = true
        countLabel.textColor = UIColor(Color.textSecondary)
        countLabel.numberOfLines = 1
        countLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.isUserInteractionEnabled = false
        stackView.spacing = BookWorkspaceLayoutMetrics.scopeTitleCountSpacing
        stackView.addArrangedSubview(titleLabel)
        stackView.addArrangedSubview(countLabel)
        addSubview(stackView)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(greaterThanOrEqualToConstant: BookWorkspaceLayoutMetrics.minimumControlHeight),
            heightAnchor.constraint(greaterThanOrEqualToConstant: BookWorkspaceLayoutMetrics.minimumControlHeight),
            stackView.leadingAnchor.constraint(equalTo: leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: trailingAnchor),
            stackView.topAnchor.constraint(greaterThanOrEqualTo: topAnchor),
            stackView.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor),
            stackView.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
        configure(item: item)
        updateAxis()
        traitRegistration = registerForTraitChanges(
            [UITraitPreferredContentSizeCategory.self]
        ) { (control: BookWorkspaceScopeTabControl, _) in
            control.updateAxis()
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 更新文案与无障碍值，控件身份和点击行为保持不变。
    func configure(item: BookWorkspaceScopeBarItem) {
        titleLabel.text = item.title
        countLabel.text = String(item.count)
        accessibilityLabel = "\(item.title)，\(item.count) 项"
    }

    /// 只在页面落定后提交 selected trait，避免 VoiceOver 在拖动过程中反复播报。
    func setCommitted(_ isCommitted: Bool) {
        var traits: UIAccessibilityTraits = .button
        if isCommitted {
            traits.insert(.selected)
        }
        accessibilityTraits = traits
    }

    override func accessibilityActivate() -> Bool {
        sendActions(for: .touchUpInside)
        return true
    }

    /// 辅助功能字号改为纵向排列，并为标题下方的指示线保留稳定间距。
    private func updateAxis() {
        let isAccessibility = traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        stackView.axis = isAccessibility ? .vertical : .horizontal
        stackView.alignment = isAccessibility ? .leading : .firstBaseline
        stackView.spacing = isAccessibility
            ? BookWorkspaceLayoutMetrics.scopeIndicatorHeight + Spacing.base
            : BookWorkspaceLayoutMetrics.scopeTitleCountSpacing
        invalidateIntrinsicContentSize()
    }
}

/// 页面唯一的原生 Tab Bar；分页热路径直接更新标签颜色、指示线和最小可见范围。
@MainActor
private final class BookWorkspaceScopeBarView: UIView {
    var onSelectSection: ((BookWorkspaceSection) -> Void)?

    private let scrollView = UIScrollView()
    private let stackView = UIStackView()
    private let indicatorView = UIView()
    private var controls: [BookWorkspaceScopeTabControl] = []
    private var items: [BookWorkspaceScopeBarItem] = []
    private var reduceMotion = false
    private var committedSection = BookWorkspaceSection.notes
    private var displayedPagePosition: CGFloat = 0
    private var lastRevealedIndex: Int?
    private var lastRevealBoundsSize = CGSize.zero
    private var pendingImmediateRevealIndex: Int?
    private var resolvedCanvasColor = UIColor(Color.surfacePage)
    private var canvasOverlayAlpha: CGFloat = 0

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        isOpaque = false
        clipsToBounds = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.isDirectionalLockEnabled = true
        scrollView.contentInsetAdjustmentBehavior = .never

        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.alignment = .fill
        stackView.spacing = BookWorkspaceLayoutMetrics.scopeItemSpacing

        indicatorView.backgroundColor = UIColor(Color.textPrimary).withAlphaComponent(0.72)
        indicatorView.layer.cornerRadius = BookWorkspaceLayoutMetrics.scopeIndicatorHeight / 2
        indicatorView.isUserInteractionEnabled = false
        indicatorView.isHidden = true

        addSubview(scrollView)
        scrollView.addSubview(stackView)
        scrollView.addSubview(indicatorView)
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            stackView.leadingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.leadingAnchor,
                constant: BookWorkspaceLayoutMetrics.pageHorizontalInset
            ),
            stackView.trailingAnchor.constraint(
                equalTo: scrollView.contentLayoutGuide.trailingAnchor,
                constant: -BookWorkspaceLayoutMetrics.pageHorizontalInset
            ),
            stackView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            stackView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 同步 Tab 文案与画布色；展开态保持透明，吸顶时由滚动进度恢复不透明画布。
    func configure(
        items: [BookWorkspaceScopeBarItem],
        committedSection: BookWorkspaceSection,
        reduceMotion: Bool,
        canvasColor: Color,
        animatedCanvasChange: Bool
    ) {
        self.reduceMotion = reduceMotion
        self.committedSection = committedSection
        let nextCanvasColor = UIColor(canvasColor).resolvedColor(with: traitCollection)
        resolvedCanvasColor = nextCanvasColor
        let applyCanvas = { [self] in
            backgroundColor = nextCanvasColor.withAlphaComponent(canvasOverlayAlpha)
        }
        if animatedCanvasChange && !reduceMotion {
            UIView.animate(
                withDuration: 0.18,
                delay: 0,
                options: [.beginFromCurrentState, .allowUserInteraction, .curveEaseInOut],
                animations: applyCanvas,
                completion: nil
            )
        } else {
            UIView.performWithoutAnimation {
                applyCanvas()
            }
        }

        if self.items.map(\.section) != items.map(\.section) {
            rebuildControls(with: items)
        } else {
            for (control, item) in zip(controls, items) {
                control.configure(item: item)
            }
        }
        self.items = items
        setCommittedSection(committedSection)
        setNeedsLayout()
    }

    /// 在收起末段用 smoothstep 叠加中性画布；更新留在 UIKit 滚动热路径且不启动独立动画。
    func updateCollapseProgress(_ progress: CGFloat) {
        let clampedProgress = min(max(progress, 0), 1)
        let start = BookWorkspaceLayoutMetrics.scopeNeutralizationStartProgress
        let normalizedProgress = min(
            max((clampedProgress - start) / max(1 - start, CGFloat.ulpOfOne), 0),
            1
        )
        let nextAlpha = normalizedProgress * normalizedProgress * (3 - 2 * normalizedProgress)
        guard abs(nextAlpha - canvasOverlayAlpha) >= 0.001 else { return }
        canvasOverlayAlpha = nextAlpha
        UIView.performWithoutAnimation { [self] in
            backgroundColor = resolvedCanvasColor.withAlphaComponent(nextAlpha)
        }
    }

    /// 根据原生 Pager 的连续页位置更新指示器和标题选中强度。
    func updatePagePosition(_ position: CGFloat, revealsTarget: Bool) {
        guard !controls.isEmpty else {
            displayedPagePosition = 0
            setIndicatorHidden(true)
            return
        }
        let clamped = min(max(position, 0), CGFloat(controls.count - 1))
        displayedPagePosition = clamped
        for (index, control) in controls.enumerated() {
            let weight = max(0, 1 - abs(clamped - CGFloat(index)))
            control.titleLabel.textColor = interpolatedTitleColor(progress: weight)
        }

        layoutIfNeeded()
        layoutIndicatorIfPossible()

        if revealsTarget {
            let lowerIndex = min(max(Int(floor(clamped)), 0), controls.count - 1)
            let fraction = clamped - CGFloat(lowerIndex)
            let upperIndex = min(lowerIndex + 1, controls.count - 1)
            let targetIndex = fraction > 0.001 ? upperIndex : lowerIndex
            _ = revealControlIfNeeded(at: targetIndex, animated: true)
        }
    }

    /// 页面落定后更新辅助技术选中态并保证目标完整可见。
    func setCommittedSection(_ section: BookWorkspaceSection) {
        committedSection = section
        let selectedIndex = items.firstIndex { $0.section == section } ?? 0
        for (index, control) in controls.enumerated() {
            control.setCommitted(index == selectedIndex)
        }
        pendingImmediateRevealIndex = selectedIndex
        updatePagePosition(CGFloat(selectedIndex), revealsTarget: false)
    }

    /// 按容器宽度测量真实高度，保证 Dynamic Type 不被固定高度裁切。
    func fittingHeight(for width: CGFloat) -> CGFloat {
        guard width > 0 else { return BookWorkspaceLayoutMetrics.scopeBarEstimatedHeight }
        layoutIfNeeded()
        let controlHeight = controls.map { control in
            control.systemLayoutSizeFitting(
                UIView.layoutFittingCompressedSize,
                withHorizontalFittingPriority: .fittingSizeLevel,
                verticalFittingPriority: .fittingSizeLevel
            ).height
        }.max() ?? 0
        return max(BookWorkspaceLayoutMetrics.minimumControlHeight, controlHeight)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if lastRevealBoundsSize != scrollView.bounds.size {
            lastRevealBoundsSize = scrollView.bounds.size
            lastRevealedIndex = nil
            pendingImmediateRevealIndex = items.firstIndex { $0.section == committedSection }
        }
        layoutIndicatorIfPossible()
        if let pendingImmediateRevealIndex,
           revealControlIfNeeded(at: pendingImmediateRevealIndex, animated: false) {
            self.pendingImmediateRevealIndex = nil
        }
    }

    private func rebuildControls(with items: [BookWorkspaceScopeBarItem]) {
        controls.forEach { control in
            stackView.removeArrangedSubview(control)
            control.removeFromSuperview()
        }
        controls = items.map { item in
            let control = BookWorkspaceScopeTabControl(item: item)
            control.addAction(
                UIAction { [weak self] _ in
                    self?.onSelectSection?(item.section)
                },
                for: .touchUpInside
            )
            stackView.addArrangedSubview(control)
            return control
        }
        displayedPagePosition = 0
        lastRevealedIndex = nil
        lastRevealBoundsSize = .zero
        pendingImmediateRevealIndex = nil
        setIndicatorHidden(true)
    }

    private func titleAnchor(for control: BookWorkspaceScopeTabControl) -> CGRect {
        control.titleLabel.convert(control.titleLabel.bounds, to: scrollView)
    }

    /// 仅在标题完成有效布局后落位指示线；连续分页通过逐帧无动画写入保持跟手。
    private func layoutIndicatorIfPossible() {
        guard !controls.isEmpty,
              bounds.width.isFinite,
              bounds.height.isFinite,
              bounds.width > 0,
              bounds.height > 0,
              scrollView.bounds.width.isFinite,
              scrollView.bounds.height.isFinite,
              scrollView.bounds.width > 0,
              scrollView.bounds.height > 0 else {
            setIndicatorHidden(true)
            return
        }

        let clamped = min(max(displayedPagePosition, 0), CGFloat(controls.count - 1))
        let lowerIndex = min(max(Int(floor(clamped)), 0), controls.count - 1)
        let upperIndex = min(lowerIndex + 1, controls.count - 1)
        let fraction = clamped - CGFloat(lowerIndex)
        let lowerAnchor = titleAnchor(for: controls[lowerIndex])
        let upperAnchor = titleAnchor(for: controls[upperIndex])
        guard isValidTitleAnchor(lowerAnchor), isValidTitleAnchor(upperAnchor) else {
            setIndicatorHidden(true)
            return
        }

        let centerX = lowerAnchor.midX + (upperAnchor.midX - lowerAnchor.midX) * fraction
        let indicatorY = lowerAnchor.maxY + (upperAnchor.maxY - lowerAnchor.maxY) * fraction
            + Spacing.half
        let nextFrame = CGRect(
            x: centerX - BookWorkspaceLayoutMetrics.scopeIndicatorWidth / 2,
            y: indicatorY,
            width: BookWorkspaceLayoutMetrics.scopeIndicatorWidth,
            height: BookWorkspaceLayoutMetrics.scopeIndicatorHeight
        )
        guard isFiniteNonEmpty(nextFrame),
              nextFrame.minY >= -0.5,
              nextFrame.maxY <= scrollView.bounds.height + 0.5 else {
            setIndicatorHidden(true)
            return
        }

        UIView.performWithoutAnimation {
            indicatorView.frame = nextFrame
            indicatorView.isHidden = false
            scrollView.bringSubviewToFront(indicatorView)
        }
    }

    /// 校验标题锚点已位于当前 Tab 的有效纵向布局范围内。
    private func isValidTitleAnchor(_ frame: CGRect) -> Bool {
        isFiniteNonEmpty(frame)
            && frame.minY >= -0.5
            && frame.maxY <= scrollView.bounds.height + 0.5
    }

    /// 拒绝零尺寸、空值或无限值几何，避免把布局中间态写入可见 Frame。
    private func isFiniteNonEmpty(_ frame: CGRect) -> Bool {
        !frame.isNull
            && !frame.isInfinite
            && frame.origin.x.isFinite
            && frame.origin.y.isFinite
            && frame.width.isFinite
            && frame.height.isFinite
            && frame.width > 0
            && frame.height > 0
    }

    /// 无动画切换指示线显隐，避免继承主题或导航转场事务。
    private func setIndicatorHidden(_ isHidden: Bool) {
        guard indicatorView.isHidden != isHidden else { return }
        UIView.performWithoutAnimation {
            indicatorView.isHidden = isHidden
        }
    }

    /// 在几何有效时保证目标 Tab 可见；外部同步立即落位，用户分页才允许滚动动画。
    @discardableResult
    private func revealControlIfNeeded(at index: Int, animated: Bool) -> Bool {
        guard controls.indices.contains(index),
              scrollView.bounds.width.isFinite,
              scrollView.bounds.height.isFinite,
              scrollView.bounds.width > 0,
              scrollView.bounds.height > 0 else {
            return false
        }
        guard lastRevealedIndex != index else { return true }
        let target = controls[index].convert(controls[index].bounds, to: scrollView)
        guard isFiniteNonEmpty(target) else { return false }
        let horizontalInset = BookWorkspaceLayoutMetrics.pageHorizontalInset
        let visible = CGRect(
            x: scrollView.contentOffset.x + horizontalInset,
            y: 0,
            width: max(scrollView.bounds.width - horizontalInset * 2, 1),
            height: scrollView.bounds.height
        )
        lastRevealedIndex = index
        guard !visible.contains(target) else { return true }
        var nextX = scrollView.contentOffset.x
        if target.minX < visible.minX {
            nextX = target.minX - horizontalInset
        } else if target.maxX > visible.maxX {
            nextX = target.maxX - scrollView.bounds.width + horizontalInset
        }
        let maximumX = max(scrollView.contentSize.width - scrollView.bounds.width, 0)
        nextX = min(max(nextX, 0), maximumX)
        scrollView.setContentOffset(
            CGPoint(x: nextX, y: 0),
            animated: animated && !reduceMotion && window != nil
        )
        return true
    }

    private func interpolatedTitleColor(progress: CGFloat) -> UIColor {
        let from = UIColor(Color.textSecondary).resolvedColor(with: traitCollection)
        let to = UIColor(Color.textPrimary).resolvedColor(with: traitCollection)
        var fromRed: CGFloat = 0
        var fromGreen: CGFloat = 0
        var fromBlue: CGFloat = 0
        var fromAlpha: CGFloat = 0
        var toRed: CGFloat = 0
        var toGreen: CGFloat = 0
        var toBlue: CGFloat = 0
        var toAlpha: CGFloat = 0
        guard from.getRed(&fromRed, green: &fromGreen, blue: &fromBlue, alpha: &fromAlpha),
              to.getRed(&toRed, green: &toGreen, blue: &toBlue, alpha: &toAlpha) else {
            return progress >= 0.5 ? to : from
        }
        return UIColor(
            red: fromRed + (toRed - fromRed) * progress,
            green: fromGreen + (toGreen - fromGreen) * progress,
            blue: fromBlue + (toBlue - fromBlue) * progress,
            alpha: fromAlpha + (toAlpha - fromAlpha) * progress
        )
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
    let items: [BookWorkspaceScopeBarItem]
    let committedSection: BookWorkspaceSection
    let reduceMotion: Bool
    let canvasPaletteID: UInt64
}

/// 原生 Pager 的连续位置快照；所有索引都基于稳定的 BookWorkspaceSection 顺序。
private struct BookWorkspacePagerPosition {
    let rawValue: CGFloat
    let lowerIndex: Int
    let upperIndex: Int
    let fraction: CGFloat
    let nearestIndex: Int

    init(offsetX: CGFloat, pageWidth: CGFloat, pageCount: Int) {
        let maximumIndex = max(pageCount - 1, 0)
        let raw = pageWidth > 0 && offsetX.isFinite
            ? offsetX / pageWidth
            : 0
        rawValue = min(max(raw, 0), CGFloat(maximumIndex))
        lowerIndex = min(max(Int(floor(rawValue)), 0), maximumIndex)
        upperIndex = min(lowerIndex + 1, maximumIndex)
        fraction = rawValue - CGFloat(lowerIndex)
        nearestIndex = min(max(Int(rawValue.rounded()), 0), maximumIndex)
    }
}

/// 四域原生列表宿主，负责原生横向分页、Collection 生命周期、diff、粘性头和受控预热。
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
    private let pagerScrollView = UIScrollView()
    private let headerBackdropView = BookWorkspaceHeaderBackdropView()
    private let sharedChromeContentClipView = UIView()
    private let bookHeaderHostView = BookWorkspaceBookHeaderHostView()
    private let scopeBarHostView = BookWorkspaceScopeBarView()
    private var pageConstraints: [NSLayoutConstraint] = []
    private var bookHeaderHeight: CGFloat = 180
    private var scopeBarHeight = BookWorkspaceLayoutMetrics.scopeBarEstimatedHeight
    private var scopeBarContentState: BookWorkspaceScopeBarContentState?
    private var noteRowStates: [Int64: BookWorkspaceNoteRowState] = [:]
    private var committedSection = BookWorkspaceSection.notes
    private var pendingCommitEcho: BookWorkspaceSection?
    private var requestedSection: BookWorkspaceSection?
    private var isRetargetingProgrammaticScroll = false
    private var lastPagerWidth: CGFloat = 0
    private var isPagerPositionInitialized = false
    private var transitionSections: Set<BookWorkspaceSection> = [.notes]
    private weak var prioritizedNavigationPopGestureRecognizer: UIGestureRecognizer?
    private weak var prioritizedNavigationContentPopGestureRecognizer: UIGestureRecognizer?
    private var wasNavigationContentPopGestureEnabled: Bool?
    private var navigationGesturePriorityAttempts = 0
    private var isNavigationGesturePriorityRefreshScheduled = false
    private var lastNavigationBarSurfaceVisibility: Bool?

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .clear
        clipsToBounds = true
        configurePager()
        BookWorkspaceSection.allCases.forEach(makeDomainContext)
        installPageConstraints()
        configureSharedChrome()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 同步四域快照；所有页面常驻，只把业务选中态限制在分页落定时提交。
    fileprivate func update(with configuration: BookWorkspaceCollectionConfiguration) {
        let previousConfiguration = self.configuration
        let previousCommittedSection = previousConfiguration.committedSection
        let canvasChanged = previousConfiguration.canvasPaletteID != configuration.canvasPaletteID
        let animatesCanvasChange = canvasChanged
            && previousConfiguration.book != nil
            && !configuration.reduceMotion
        self.configuration = configuration
        synchronizeExternalCommit(configuration.committedSection)
        updateHeaderBackdropContent(animatedCanvasChange: animatesCanvasChange)
        updateBookHeaderContent()
        updateScopeBarContent(animatedCanvasChange: animatesCanvasChange)
        pruneNoteRowStates()

        for section in BookWorkspaceSection.allCases {
            guard let context = contexts[section] else { continue }
            let nextSnapshot = configuration.snapshots[section]
                ?? BookWorkspacePresentationSnapshot.initial(for: section)
            apply(nextSnapshot, to: context)
            if canvasChanged {
                refreshVisibleContent(in: context, animatedCanvasChange: animatesCanvasChange)
            }
        }

        updatePageResourcePolicy()
        updateBottomContentInsets()

        if previousCommittedSection != configuration.committedSection,
           let active = contexts[committedSection] {
            active.collectionView.layoutIfNeeded()
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
        pagerScrollView.delegate = nil
        noteRowStates.removeAll()
        scopeBarContentState = nil
        restoreNavigationContentPopGestureAvailability()
        bookHeaderHostView.removeFromSuperview()
        scopeBarHostView.removeFromSuperview()
        sharedChromeContentClipView.removeFromSuperview()
        headerBackdropView.removeFromSuperview()
        pagerScrollView.removeFromSuperview()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        updateBottomContentInsets()
        let pageWidth = pagerScrollView.bounds.width
        if pageWidth > 0, abs(pageWidth - lastPagerWidth) >= 0.5 {
            let previousPosition = currentPagerPosition.rawValue
            lastPagerWidth = pageWidth
            pagerScrollView.layoutIfNeeded()
            let targetPosition = isPagerMoving
                ? previousPosition
                : CGFloat(index(for: committedSection))
            pagerScrollView.setContentOffset(
                CGPoint(x: targetPosition * pageWidth, y: 0),
                animated: false
            )
            isPagerPositionInitialized = true
        } else if !isPagerPositionInitialized, pageWidth > 0 {
            alignPager(to: committedSection, animated: false)
            isPagerPositionInitialized = true
        }

        for context in contexts.values where context.lastBoundsSize != context.collectionView.bounds.size {
            context.lastBoundsSize = context.collectionView.bounds.size
            context.collectionView.collectionViewLayout.invalidateLayout()
        }
        updateSharedChromeMetricsIfNeeded()
        layoutSharedChrome(at: currentPagerPosition)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window == nil {
            restoreNavigationContentPopGestureAvailability()
            prioritizedNavigationPopGestureRecognizer = nil
            navigationGesturePriorityAttempts = 0
            isNavigationGesturePriorityRefreshScheduled = false
        }
        prioritizeNavigationPopGestureIfNeeded()
        updateBottomContentInsets()
    }

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        updateBottomContentInsets()
        setNeedsLayout()
    }

    /// 配置页面唯一的背景、书籍头部与 Tab；背景越过安全区，内容始终裁切在导航栏下方。
    private func configureSharedChrome() {
        sharedChromeContentClipView.backgroundColor = .clear
        sharedChromeContentClipView.clipsToBounds = true
        bookHeaderHostView.isHidden = true
        scopeBarHostView.isHidden = true
        scopeBarHostView.onSelectSection = { [weak self] section in
            self?.requestPage(section)
        }
        insertSubview(headerBackdropView, belowSubview: pagerScrollView)
        addSubview(sharedChromeContentClipView)
        sharedChromeContentClipView.addSubview(bookHeaderHostView)
        sharedChromeContentClipView.addSubview(scopeBarHostView)
        accessibilityElements = [bookHeaderHostView, scopeBarHostView, pagerScrollView]
    }

    /// 配置系统原生分页容器；拖动、减速、取消和程序化滚动全部由 UIScrollView 负责。
    private func configurePager() {
        pagerScrollView.translatesAutoresizingMaskIntoConstraints = false
        pagerScrollView.backgroundColor = .clear
        pagerScrollView.isPagingEnabled = true
        pagerScrollView.isDirectionalLockEnabled = true
        pagerScrollView.showsHorizontalScrollIndicator = false
        pagerScrollView.showsVerticalScrollIndicator = false
        pagerScrollView.alwaysBounceHorizontal = true
        pagerScrollView.alwaysBounceVertical = false
        pagerScrollView.contentInsetAdjustmentBehavior = .never
        pagerScrollView.scrollsToTop = false
        pagerScrollView.delegate = self
        addSubview(pagerScrollView)
        NSLayoutConstraint.activate([
            pagerScrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            pagerScrollView.trailingAnchor.constraint(equalTo: trailingAnchor),
            pagerScrollView.topAnchor.constraint(equalTo: safeAreaLayoutGuide.topAnchor),
            pagerScrollView.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
    }

    /// 让系统左边缘返回优先于横向分页；非边缘拖动会在返回手势失败后立即交还 Pager。
    private func prioritizeNavigationPopGestureIfNeeded() {
        guard window != nil else { return }
        var responder: UIResponder? = self
        while let current = responder {
            if let viewController = current as? UIViewController,
               let navigationController = viewController.navigationController,
               let popGestureRecognizer = navigationController.interactivePopGestureRecognizer {
                if prioritizedNavigationPopGestureRecognizer !== popGestureRecognizer {
                    pagerScrollView.panGestureRecognizer.require(toFail: popGestureRecognizer)
                    for context in contexts.values {
                        context.collectionView.panGestureRecognizer.require(toFail: popGestureRecognizer)
                    }
                    prioritizedNavigationPopGestureRecognizer = popGestureRecognizer
                }
                if #available(iOS 26.0, *),
                   let contentPopGestureRecognizer = navigationController.interactiveContentPopGestureRecognizer,
                   prioritizedNavigationContentPopGestureRecognizer !== contentPopGestureRecognizer {
                    restoreNavigationContentPopGestureAvailability()
                    wasNavigationContentPopGestureEnabled = contentPopGestureRecognizer.isEnabled
                    pagerScrollView.panGestureRecognizer.require(toFail: contentPopGestureRecognizer)
                    for context in contexts.values {
                        context.collectionView.panGestureRecognizer.require(toFail: contentPopGestureRecognizer)
                    }
                    prioritizedNavigationContentPopGestureRecognizer = contentPopGestureRecognizer
                }
                navigationGesturePriorityAttempts = 0
                isNavigationGesturePriorityRefreshScheduled = false
                updateNavigationContentPopGestureAvailability()
                return
            }
            responder = current.next
        }

        guard navigationGesturePriorityAttempts < 3,
              !isNavigationGesturePriorityRefreshScheduled else { return }
        navigationGesturePriorityAttempts += 1
        isNavigationGesturePriorityRefreshScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.isNavigationGesturePriorityRefreshScheduled = false
            self.prioritizeNavigationPopGestureIfNeeded()
        }
    }

    /// 仅在目录第一页开放 iOS 26 的页面内容返回，避免它抢占后续页面向右翻页。
    private func updateNavigationContentPopGestureAvailability() {
        guard let contentPopGestureRecognizer = prioritizedNavigationContentPopGestureRecognizer,
              let wasEnabled = wasNavigationContentPopGestureEnabled else { return }
        let firstSection = BookWorkspaceSection.allCases.first
        contentPopGestureRecognizer.isEnabled = wasEnabled && committedSection == firstSection
    }

    /// 离开工作台时恢复导航容器原本的内容返回开关，不把页面私有策略泄漏到后续路由。
    private func restoreNavigationContentPopGestureAvailability() {
        if let contentPopGestureRecognizer = prioritizedNavigationContentPopGestureRecognizer,
           let wasEnabled = wasNavigationContentPopGestureEnabled {
            contentPopGestureRecognizer.isEnabled = wasEnabled
        }
        prioritizedNavigationContentPopGestureRecognizer = nil
        wasNavigationContentPopGestureEnabled = nil
    }

    /// 用 content/frame layout guide 把所有常驻列表串成等宽页面，不手工维护 contentSize。
    private func installPageConstraints() {
        NSLayoutConstraint.deactivate(pageConstraints)
        pageConstraints.removeAll(keepingCapacity: true)
        var previousView: UIView?
        for section in BookWorkspaceSection.allCases {
            guard let collectionView = contexts[section]?.collectionView else { continue }
            pageConstraints.append(contentsOf: [
                collectionView.topAnchor.constraint(equalTo: pagerScrollView.contentLayoutGuide.topAnchor),
                collectionView.bottomAnchor.constraint(equalTo: pagerScrollView.contentLayoutGuide.bottomAnchor),
                collectionView.widthAnchor.constraint(equalTo: pagerScrollView.frameLayoutGuide.widthAnchor),
                collectionView.heightAnchor.constraint(equalTo: pagerScrollView.frameLayoutGuide.heightAnchor)
            ])
            if let previousView {
                pageConstraints.append(collectionView.leadingAnchor.constraint(equalTo: previousView.trailingAnchor))
            } else {
                pageConstraints.append(
                    collectionView.leadingAnchor.constraint(equalTo: pagerScrollView.contentLayoutGuide.leadingAnchor)
                )
            }
            previousView = collectionView
        }
        if let previousView {
            pageConstraints.append(
                previousView.trailingAnchor.constraint(equalTo: pagerScrollView.contentLayoutGuide.trailingAnchor)
            )
        }
        NSLayoutConstraint.activate(pageConstraints)
    }

    private var currentPagerPosition: BookWorkspacePagerPosition {
        BookWorkspacePagerPosition(
            offsetX: pagerScrollView.contentOffset.x,
            pageWidth: max(pagerScrollView.bounds.width, lastPagerWidth),
            pageCount: BookWorkspaceSection.allCases.count
        )
    }

    private var isPagerMoving: Bool {
        pagerScrollView.isTracking
            || pagerScrollView.isDragging
            || pagerScrollView.isDecelerating
            || pagerScrollView.isScrollAnimating
            || requestedSection != nil
    }

    private func index(for section: BookWorkspaceSection) -> Int {
        BookWorkspaceSection.allCases.firstIndex(of: section) ?? 0
    }

    private func section(at index: Int) -> BookWorkspaceSection {
        let sections = BookWorkspaceSection.allCases
        guard sections.indices.contains(index) else { return sections.first ?? .notes }
        return sections[index]
    }

    /// 消费 SwiftUI 的落定态回声；外部状态不会在一次交互尚未结束时把 Pager 拉回旧页。
    private func synchronizeExternalCommit(_ section: BookWorkspaceSection) {
        if pendingCommitEcho == section {
            pendingCommitEcho = nil
            committedSection = section
            updateNavigationContentPopGestureAvailability()
            return
        }
        guard pendingCommitEcho == nil, section != committedSection else { return }
        committedSection = section
        requestedSection = nil
        transitionSections = [section]
        if isPagerPositionInitialized {
            alignPager(to: section, animated: false)
        }
        scopeBarHostView.setCommittedSection(section)
        updateNavigationContentPopGestureAvailability()
        layoutSharedChrome(at: currentPagerPosition)
    }

    /// Tab 点击只驱动原生 Pager；业务选中态等待系统滚动真正落定后再提交。
    private func requestPage(_ section: BookWorkspaceSection) {
        guard configuration.book != nil, pagerScrollView.bounds.width > 0 else { return }
        let targetX = CGFloat(index(for: section)) * pagerScrollView.bounds.width
        guard abs(pagerScrollView.contentOffset.x - targetX) > 0.5 else {
            settlePager()
            return
        }
        isRetargetingProgrammaticScroll = true
        pagerScrollView.stopScrollingAndZooming()
        requestedSection = section
        updateTransitionSections(including: section)
        if configuration.reduceMotion {
            alignPager(to: section, animated: false)
            isRetargetingProgrammaticScroll = false
            settlePager()
        } else {
            alignPager(to: section, animated: true)
            isRetargetingProgrammaticScroll = false
        }
    }

    private func alignPager(to section: BookWorkspaceSection, animated: Bool) {
        guard pagerScrollView.bounds.width > 0 else { return }
        pagerScrollView.setContentOffset(
            CGPoint(x: CGFloat(index(for: section)) * pagerScrollView.bounds.width, y: 0),
            animated: animated
        )
    }

    /// 页面停止后收敛到最近页，并且只在业务值真实变化时回写一次。
    private func settlePager() {
        let position = currentPagerPosition
        let settled = section(at: position.nearestIndex)
        let targetX = CGFloat(position.nearestIndex) * pagerScrollView.bounds.width
        if abs(pagerScrollView.contentOffset.x - targetX) > 0.5 {
            pagerScrollView.setContentOffset(CGPoint(x: targetX, y: 0), animated: false)
        }
        requestedSection = nil
        committedSection = settled
        transitionSections = [settled]
        scopeBarHostView.setCommittedSection(settled)
        updateNavigationContentPopGestureAvailability()
        layoutSharedChrome(at: currentPagerPosition)
        updatePageResourcePolicy()
        guard configuration.committedSection != settled else { return }
        pendingCommitEcho = settled
        configuration.onSectionCommit(settled)
    }

    /// 忽略被新目标打断的旧结束回调；只有最新目标真正到达后才允许提交业务选中态。
    private func settlePagerIfReady() {
        guard !isRetargetingProgrammaticScroll else { return }
        if let requestedSection {
            let targetX = CGFloat(index(for: requestedSection)) * pagerScrollView.bounds.width
            guard abs(pagerScrollView.contentOffset.x - targetX) <= 0.5 else {
                if !pagerScrollView.isScrollAnimating {
                    alignPager(to: requestedSection, animated: !configuration.reduceMotion)
                }
                return
            }
        }
        settlePager()
    }

    /// 仅起始页与当前目标页参与交互和预取，页面对象及其滚动状态始终保留。
    private func updateTransitionSections(including requested: BookWorkspaceSection? = nil) {
        let position = currentPagerPosition
        var sections: Set<BookWorkspaceSection> = [
            section(at: position.lowerIndex),
            section(at: position.upperIndex)
        ]
        if let requested {
            sections.insert(requested)
        }
        guard sections != transitionSections else { return }
        transitionSections = sections
        updatePageResourcePolicy()
    }

    private func updatePageResourcePolicy() {
        let activeSections = isPagerMoving ? transitionSections : [committedSection]
        for (section, context) in contexts {
            let participates = activeSections.contains(section)
            context.collectionView.isHidden = false
            context.collectionView.isUserInteractionEnabled = participates
            context.collectionView.accessibilityElementsHidden = section != committedSection
            context.collectionView.scrollsToTop = section == committedSection
            context.collectionView.prefetchDataSource = participates ? self : nil
            if !participates {
                cancelPrewarming(in: context)
            }
        }
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

    /// 只在主题或书籍变化时更新顶部氛围，连续滚动仅修改 Frame 与拉伸高度。
    private func updateHeaderBackdropContent(animatedCanvasChange: Bool) {
        guard configuration.book != nil else {
            headerBackdropView.isHidden = true
            publishNavigationBarSurfaceVisibility(false)
            return
        }
        headerBackdropView.isHidden = false
        headerBackdropView.configure(
            canvasColor: configuration.canvasColor,
            leadingColor: configuration.headerLeadingColor,
            trailingColor: configuration.headerTrailingColor,
            animated: animatedCanvasChange
        )
    }

    /// 只在书籍或动态设置变化时更新 Header 内容，连续分页不进入 SwiftUI 配置链路。
    private func updateBookHeaderContent() {
        guard let book = configuration.book else {
            bookHeaderHostView.isHidden = true
            return
        }
        bookHeaderHostView.isHidden = false
        bookHeaderHostView.configure(
            content: AnyView(
                BookWorkspaceBookHeader(
                    book: book,
                    onOpenReadingDetail: { [weak self] in
                        self?.configuration.onOpenReadingDetail()
                    },
                    onEditBook: { [weak self] in
                        self?.configuration.onEditBook()
                    }
                )
            )
        )
        setNeedsLayout()
    }

    private func updateScopeBarContent(animatedCanvasChange: Bool) {
        guard let book = configuration.book else {
            scopeBarContentState = nil
            scopeBarHostView.isHidden = true
            return
        }
        let items = scopeBarItems(for: book)
        let nextState = BookWorkspaceScopeBarContentState(
            items: items,
            committedSection: committedSection,
            reduceMotion: configuration.reduceMotion,
            canvasPaletteID: configuration.canvasPaletteID
        )
        scopeBarHostView.isHidden = false
        guard nextState != scopeBarContentState else { return }
        scopeBarContentState = nextState
        scopeBarHostView.configure(
            items: items,
            committedSection: committedSection,
            reduceMotion: configuration.reduceMotion,
            canvasColor: configuration.canvasColor,
            animatedCanvasChange: animatedCanvasChange
        )
        scopeBarHostView.updatePagePosition(currentPagerPosition.rawValue, revealsTarget: false)
        setNeedsLayout()
    }

    private func scopeBarItems(for book: BookDetail) -> [BookWorkspaceScopeBarItem] {
        BookWorkspaceSection.allCases.map { section in
            let count: Int
            switch section {
            case .catalog:
                count = book.chapters.count
            case .notes:
                count = configuration.notesCount
            case .related:
                count = book.relatedCount
            case .reviews:
                count = book.reviewCount
            }
            return BookWorkspaceScopeBarItem(section: section, title: section.title, count: count)
        }
    }

    /// 以唯一共享 Chrome 的真实高度同步四页滚动占位；只在宽度或动态字体变化时刷新布局。
    private func updateSharedChromeMetricsIfNeeded() {
        guard configuration.book != nil, bounds.width > 0 else { return }
        let displayScale = window?.screen.scale ?? max(traitCollection.displayScale, 1)
        let measuredHeaderHeight = bookHeaderHostView.fittingHeight(for: bounds.width)
        let measuredScopeHeight = scopeBarHostView.fittingHeight(for: bounds.width)
        let nextHeaderHeight = measuredHeaderHeight.isFinite && measuredHeaderHeight > 0
            ? ceil(measuredHeaderHeight * displayScale) / displayScale
            : bookHeaderHeight
        let nextScopeHeight = measuredScopeHeight.isFinite && measuredScopeHeight > 0
            ? max(
                BookWorkspaceLayoutMetrics.minimumControlHeight,
                ceil(measuredScopeHeight * displayScale) / displayScale
            )
            : scopeBarHeight
        let headerChanged = abs(nextHeaderHeight - bookHeaderHeight) >= 0.5
        let scopeChanged = abs(nextScopeHeight - scopeBarHeight) >= 0.5
        guard headerChanged || scopeChanged else { return }
        bookHeaderHeight = nextHeaderHeight
        scopeBarHeight = nextScopeHeight
        refreshChromeSpacers()
    }

    /// 只刷新四页当前可见的透明占位，并让离屏页在复用时读取最新高度。
    private func refreshChromeSpacers() {
        for context in contexts.values {
            if let indexPath = context.dataSource?.indexPath(for: .chromeSpacer),
               let cell = context.collectionView.cellForItem(at: indexPath)
                    as? BookWorkspaceHostingCell {
                cell.configure(content: content(for: .chromeSpacer))
            }
            context.collectionView.collectionViewLayout.invalidateLayout()
        }
    }

    /// 把相邻页面滚动量插值为背景、Header 与 Tab 的唯一位置，连续值始终停留在 UIKit。
    private func layoutSharedChrome(at position: BookWorkspacePagerPosition) {
        guard bounds.width > 0 else { return }
        let lowerOffset = min(
            effectiveScrollOffset(for: section(at: position.lowerIndex)),
            bookHeaderHeight
        )
        let upperOffset = min(
            effectiveScrollOffset(for: section(at: position.upperIndex)),
            bookHeaderHeight
        )
        let offset = lowerOffset + (upperOffset - lowerOffset) * position.fraction
        let collapseDistance = min(max(offset, 0), bookHeaderHeight)
        let collapseProgress = bookHeaderHeight > 0
            ? collapseDistance / bookHeaderHeight
            : 1
        let overscrollDistance = max(-offset, 0)
        let chromeTopInset = min(
            max(pagerScrollView.frame.minY, safeAreaInsets.top, 0),
            bounds.height
        )
        let nextBackdropFrame = CGRect(
            x: 0,
            y: -collapseDistance,
            width: bounds.width,
            height: chromeTopInset
                + bookHeaderHeight
                + scopeBarHeight
                + overscrollDistance
        )
        let nextHeaderFrame = CGRect(
            x: 0,
            y: -offset,
            width: bounds.width,
            height: bookHeaderHeight
        )
        let nextScopeFrame = CGRect(
            x: 0,
            y: max(bookHeaderHeight - offset, 0),
            width: bounds.width,
            height: scopeBarHeight
        )
        let visibleChromeHeight = min(
            max(nextHeaderFrame.maxY, nextScopeFrame.maxY, 0),
            max(bounds.height - chromeTopInset, 0)
        )
        let nextContentClipFrame = CGRect(
            x: 0,
            y: chromeTopInset,
            width: bounds.width,
            height: visibleChromeHeight
        )
        if sharedChromeContentClipView.frame != nextContentClipFrame {
            sharedChromeContentClipView.frame = nextContentClipFrame
        }
        if headerBackdropView.frame != nextBackdropFrame {
            headerBackdropView.frame = nextBackdropFrame
        }
        headerBackdropView.updateFadeHeight(scopeBarHeight)
        if bookHeaderHostView.frame != nextHeaderFrame {
            bookHeaderHostView.frame = nextHeaderFrame
        }
        if scopeBarHostView.frame != nextScopeFrame {
            scopeBarHostView.frame = nextScopeFrame
        }
        scopeBarHostView.updateCollapseProgress(collapseProgress)
        publishNavigationBarSurfaceVisibility(
            bookHeaderHeight > 0 && collapseDistance >= bookHeaderHeight - 0.5
        )
    }

    /// 只在完全收起阈值跨越时通知 SwiftUI，避免把逐帧滚动位置写入页面状态。
    private func publishNavigationBarSurfaceVisibility(_ isVisible: Bool) {
        guard lastNavigationBarSurfaceVisibility != isVisible else { return }
        lastNavigationBarSurfaceVisibility = isVisible
        configuration.onNavigationBarSurfaceChange(isVisible)
    }

    private func effectiveScrollOffset(for section: BookWorkspaceSection) -> CGFloat {
        guard let collectionView = contexts[section]?.collectionView else { return 0 }
        let value = collectionView.contentOffset.y + collectionView.adjustedContentInset.top
        return value.isFinite ? value : 0
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
        collectionView.isDirectionalLockEnabled = true
        collectionView.transfersHorizontalScrollingToParent = true
        pagerScrollView.addSubview(collectionView)

        let context = BookWorkspaceCollectionDomainContext(
            section: section,
            collectionView: collectionView,
            snapshot: initialSnapshot
        )
        contexts[section] = context
        collectionView.setCollectionViewLayout(makeLayout(for: section), animated: false)
        configureDataSource(for: context)

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
            cell.configure(content: self.content(for: item))
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
    private func content(for item: BookWorkspaceCollectionItem) -> AnyView {
        switch item {
        case .chromeSpacer:
            return AnyView(
                Color.clear
                    .frame(height: max(bookHeaderHeight + scopeBarHeight, 1))
                    .accessibilityHidden(true)
            )
        case .catalog(let row):
            return AnyView(
                BookWorkspaceCatalogCollectionRow(
                    row: row,
                    surfaceColor: configuration.contentSurfaceColor,
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
                    surfaceColor: configuration.contentSurfaceColor,
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
                BookWorkspaceRelatedCollectionRow(
                    row: row,
                    surfaceColor: configuration.contentSurfaceColor
                ) { [weak self] in
                    self?.configuration.onOpenRelated(row.item)
                }
            )
        case .review(let row):
            return AnyView(
                BookWorkspaceReviewCollectionRow(
                    row: row,
                    surfaceColor: configuration.contentSurfaceColor
                ) { [weak self] in
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
        to context: BookWorkspaceCollectionDomainContext
    ) {
        let revisionChanged = snapshot.revision != context.appliedRevision
        guard revisionChanged else { return }
        captureViewport(in: context)
        let previousItems = context.snapshot.itemsByID
        let previousDiffable = context.dataSource?.snapshot()
        context.snapshot = snapshot
        context.appliedRevision = snapshot.revision

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
                return previousItems[itemID] != snapshot.itemsByID[itemID]
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

    /// 只重建屏幕内 Cell 与章节固定层的主题视觉；离屏 Cell 复用时自然读取最新配置。
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

        for indexPath in context.collectionView.indexPathsForVisibleItems {
            guard let itemID = context.dataSource?.itemIdentifier(for: indexPath),
                  let item = context.snapshot.itemsByID[itemID],
                  let cell = context.collectionView.cellForItem(at: indexPath)
                    as? BookWorkspaceHostingCell else {
                continue
            }
            cell.configure(content: content(for: item))
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
            estimatedHeight = max(bookHeaderHeight + scopeBarHeight, 1)
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
        if scrollView === pagerScrollView {
            let position = currentPagerPosition
            scopeBarHostView.updatePagePosition(position.rawValue, revealsTarget: true)
            updateTransitionSections(including: requestedSection)
            layoutSharedChrome(at: position)
            return
        }
        guard let context = context(for: scrollView), context.section == committedSection else { return }
        layoutSharedChrome(at: currentPagerPosition)
    }

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        guard scrollView === pagerScrollView else { return }
        requestedSection = nil
        updateTransitionSections()
    }

    func scrollViewWillEndDragging(
        _ scrollView: UIScrollView,
        withVelocity velocity: CGPoint,
        targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
        guard scrollView === pagerScrollView else { return }
        let target = BookWorkspacePagerPosition(
            offsetX: targetContentOffset.pointee.x,
            pageWidth: pagerScrollView.bounds.width,
            pageCount: BookWorkspaceSection.allCases.count
        )
        updateTransitionSections(including: section(at: target.nearestIndex))
    }

    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if scrollView === pagerScrollView {
            guard !decelerate else { return }
            settlePagerIfReady()
            return
        }
        guard !decelerate, let context = context(for: scrollView) else { return }
        captureViewport(in: context)
    }

    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        if scrollView === pagerScrollView {
            settlePagerIfReady()
            return
        }
        guard let context = context(for: scrollView) else { return }
        captureViewport(in: context)
    }

    func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
        if scrollView === pagerScrollView {
            settlePagerIfReady()
            return
        }
        guard let context = context(for: scrollView) else { return }
        captureViewport(in: context)
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
            if context.section == committedSection {
                layoutSharedChrome(at: currentPagerPosition)
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
              transitionSections.contains(context.section) else { return }
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
            while !Task.isCancelled, self.transitionSections.contains(context.section) {
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

/// 页面唯一的书籍信息头部；它不参与横向分页，但随当前纵向列表连续收起。
private enum BookWorkspaceHeaderMetricKind: Int, Identifiable {
    case readingDuration
    case bookmark
    case readingProgress

    var id: Int { rawValue }

    var systemImage: String {
        switch self {
        case .readingDuration:
            return "clock"
        case .bookmark:
            return "bookmark"
        case .readingProgress:
            return "arrow.right.circle"
        }
    }
}

/// 书籍工作台头部的一项排版数据；动作按稳定种类在数据行内部映射。
private struct BookWorkspaceHeaderMetric: Identifiable {
    let kind: BookWorkspaceHeaderMetricKind
    let value: String
    let accessibilityLabel: String

    var id: BookWorkspaceHeaderMetricKind { kind }
}

/// 记录横向数据带两侧是否仍有未展示内容，只在跨过边界时触发视图更新。
private struct BookWorkspaceMetricScrollEdges: Equatable {
    static let hidden = BookWorkspaceMetricScrollEdges()

    let leading: Bool
    let trailing: Bool

    /// 配置两侧边缘是否需要显示渐进遮罩。
    init(leading: Bool = false, trailing: Bool = false) {
        self.leading = leading
        self.trailing = trailing
    }

    /// 根据滚动内容、视口和当前位置解析两侧剩余内容，回弹区间不会误点亮边缘。
    init(geometry: ScrollGeometry) {
        let maximumOffset = max(
            geometry.contentSize.width - geometry.containerSize.width,
            0
        )
        let clampedOffset = min(max(geometry.contentOffset.x, 0), maximumOffset)
        let threshold = Spacing.hairline
        leading = maximumOffset > threshold && clampedOffset > threshold
        trailing = maximumOffset > threshold
            && maximumOffset - clampedOffset > threshold
    }
}

/// 使用透明度渐变柔化横向滚动视口的真实裁切边缘，不覆盖内容或参与交互。
private struct BookWorkspaceMetricEdgeFadeMask: View {
    let activeEdges: BookWorkspaceMetricScrollEdges

    var body: some View {
        HStack(spacing: Spacing.none) {
            Group {
                if activeEdges.leading {
                    LinearGradient(
                        colors: [.clear, .black],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                } else {
                    Color.black
                }
            }
            .frame(width: BookWorkspaceLayoutMetrics.metricsEdgeFadeWidth)

            Color.black

            Group {
                if activeEdges.trailing {
                    LinearGradient(
                        colors: [.black, .clear],
                        startPoint: .leading,
                        endPoint: .trailing
                    )
                } else {
                    Color.black
                }
            }
            .frame(width: BookWorkspaceLayoutMetrics.metricsEdgeFadeWidth)
        }
    }
}

/// 用同源字体测量真实溢出，仅在需要时绘制无往返的单行书名跑马灯。
private struct BookWorkspaceMarqueeTitleText: View {
    let text: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isScrolling = false
    @State private var animationToken = UUID()

    var body: some View {
        GeometryReader { proxy in
            let containerWidth = max(proxy.size.width, 0)
            let textWidth = measuredTextWidth
            let shouldScroll = !reduceMotion && textWidth > containerWidth + Spacing.tiny

            Group {
                if shouldScroll {
                    scrollingTitle(textWidth: textWidth, containerWidth: containerWidth)
                } else {
                    titleLabel
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .frame(width: containerWidth, alignment: .leading)
                }
            }
            .clipped()
        }
        .frame(height: BookWorkspaceTypography.titleLineHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(text)
    }

    /// 在身份栏视窗内绘制首尾相接的标题；静止时首字保持完整，滚动后才弱化左侧裁切。
    private func scrollingTitle(textWidth: CGFloat, containerWidth: CGFloat) -> some View {
        let edgeWidth = min(
            BookWorkspaceLayoutMetrics.marqueeEdgeFadeWidth,
            max(containerWidth / 4, 0)
        )
        return ZStack(alignment: .leading) {
            HStack(spacing: BookWorkspaceLayoutMetrics.marqueeGap) {
                titleLabel
                    .fixedSize(horizontal: true, vertical: false)
                titleLabel
                    .fixedSize(horizontal: true, vertical: false)
                    .accessibilityHidden(true)
            }
            .offset(
                x: isScrolling
                    ? -(textWidth + BookWorkspaceLayoutMetrics.marqueeGap)
                    : 0
            )
        }
        .frame(
            width: containerWidth,
            height: BookWorkspaceTypography.titleLineHeight,
            alignment: .leading
        )
        .clipped()
        .mask {
            HStack(spacing: Spacing.none) {
                Group {
                    if isScrolling {
                        LinearGradient(
                            colors: [.clear, .black],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    } else {
                        Color.black
                    }
                }
                .frame(width: edgeWidth)
                Color.black
                LinearGradient(
                    colors: [.black, .clear],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: edgeWidth)
            }
        }
        .onAppear {
            restartAnimation(containerWidth: containerWidth, textWidth: textWidth)
        }
        .onChange(of: containerWidth) { _, newWidth in
            restartAnimation(containerWidth: newWidth, textWidth: textWidth)
        }
        .onChange(of: text) {
            restartAnimation(containerWidth: containerWidth, textWidth: measuredTextWidth)
        }
        .onDisappear {
            animationToken = UUID()
            isScrolling = false
        }
    }

    private var titleLabel: some View {
        Text(text)
            .font(BookWorkspaceTypography.title)
            .foregroundStyle(Color.textPrimary)
            .lineLimit(1)
    }

    private var measuredTextWidth: CGFloat {
        ceil((text as NSString).size(
            withAttributes: [.font: BookWorkspaceTypography.uiTitle]
        ).width)
    }

    /// 在主队列延迟启动动画；令牌会让尺寸或文本变化前创建的回调失效，避免旧动画竞态覆盖。
    private func restartAnimation(containerWidth: CGFloat, textWidth: CGFloat) {
        let token = UUID()
        animationToken = token
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            isScrolling = false
        }
        guard textWidth > containerWidth + Spacing.tiny else { return }
        let distance = textWidth + BookWorkspaceLayoutMetrics.marqueeGap
        let duration = Double(distance / BookWorkspaceLayoutMetrics.marqueePointsPerSecond)
        DispatchQueue.main.asyncAfter(
            deadline: .now() + BookWorkspaceLayoutMetrics.marqueeInitialDelay
        ) {
            guard animationToken == token else { return }
            withAnimation(.linear(duration: duration).repeatForever(autoreverses: false)) {
                isScrolling = true
            }
        }
    }
}

/// 在同一标题行内协调书名与阅读状态：短标题自然跟随，长标题为状态保留稳定行末空间。
private struct BookWorkspaceTitleStatusRow: View {
    let title: String
    let statusTitle: String
    let statusColor: Color
    let onEditBook: () -> Void

    var body: some View {
        Group {
            if statusTitle.isEmpty {
                marqueeTitle
            } else {
                ViewThatFits(in: .horizontal) {
                    naturalWidthContent
                        .fixedSize(horizontal: true, vertical: false)
                    constrainedContent
                }
            }
        }
        .frame(
            maxWidth: .infinity,
            minHeight: BookWorkspaceLayoutMetrics.titleStatusRowHeight,
            maxHeight: BookWorkspaceLayoutMetrics.titleStatusRowHeight,
            alignment: .leading
        )
    }

    private var naturalWidthContent: some View {
        HStack(spacing: BookWorkspaceLayoutMetrics.titleStatusSpacing) {
            Text(title)
                .font(BookWorkspaceTypography.title)
                .foregroundStyle(Color.textPrimary)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .accessibilityHeading(.h1)
            statusButton
        }
    }

    private var constrainedContent: some View {
        HStack(spacing: BookWorkspaceLayoutMetrics.titleStatusSpacing) {
            marqueeTitle
                .layoutPriority(1)
            statusButton
                .fixedSize(horizontal: true, vertical: false)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var marqueeTitle: some View {
        BookWorkspaceMarqueeTitleText(text: title)
            .accessibilityHeading(.h1)
    }

    private var statusButton: some View {
        Button(action: onEditBook) {
            Text(statusTitle)
                .font(AppTypography.caption2Medium)
                .foregroundStyle(statusColor)
                .lineLimit(1)
                .padding(.horizontal, Spacing.half)
                .frame(minWidth: BookWorkspaceLayoutMetrics.minimumControlHeight)
                .frame(height: BookWorkspaceLayoutMetrics.readStatusBadgeVisualHeight)
                .background(
                    statusColor.opacity(BookWorkspaceLayoutMetrics.readStatusBadgeFillOpacity),
                    in: Capsule()
                )
                .overlay {
                    Capsule().strokeBorder(
                        statusColor.opacity(
                            BookWorkspaceLayoutMetrics.readStatusBadgeBorderOpacity
                        ),
                        lineWidth: CardStyle.borderWidth
                    )
                }
                .frame(minHeight: BookWorkspaceLayoutMetrics.minimumControlHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(BookWorkspaceMetricButtonStyle())
        .accessibilityLabel("阅读状态\(statusTitle)")
        .accessibilityHint("点按修改")
    }
}

/// 以统一字号、字重和颜色绘制完整数据值，避免数字与单位产生非必要的光学重量差。
private struct BookWorkspaceMetricValueText: View {
    private let value: String

    init(_ value: String) {
        self.value = value
    }

    var body: some View {
        Text(value)
            .font(BookWorkspaceTypography.metricValue)
            .foregroundStyle(Color.textSecondary)
            .lineLimit(1)
    }
}

/// 用独立图标和弱表面建立阅读指标的语义边界，视觉高度与点击高度分别控制。
private struct BookWorkspaceMetricChipLabel: View {
    let metric: BookWorkspaceHeaderMetric

    var body: some View {
        HStack(spacing: BookWorkspaceLayoutMetrics.metricChipIconSpacing) {
            Image(systemName: metric.kind.systemImage)
                .font(BookWorkspaceTypography.metricIcon)
                .foregroundStyle(Color.iconSecondary)
                .accessibilityHidden(true)

            BookWorkspaceMetricValueText(metric.value)
        }
        .padding(.horizontal, BookWorkspaceLayoutMetrics.metricChipHorizontalInset)
        .frame(minWidth: BookWorkspaceLayoutMetrics.minimumControlHeight)
        .frame(height: BookWorkspaceLayoutMetrics.metricChipVisualHeight)
        .frame(minHeight: BookWorkspaceLayoutMetrics.minimumControlHeight)
        .fixedSize(horizontal: true, vertical: false)
        .contentShape(Rectangle())
    }
}

/// 仅为阅读指标 Chip 提供非位移式按压反馈，避免影响状态 Badge 与评分胶囊。
private struct BookWorkspaceMetricChipButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(
                configuration.isPressed
                    ? BookWorkspaceLayoutMetrics.metricChipPressedContentOpacity
                    : 1
            )
            .background {
                Capsule()
                    .fill(
                        Color.surfaceCard.opacity(
                            configuration.isPressed
                                ? BookWorkspaceLayoutMetrics.metricChipPressedFillOpacity
                                : BookWorkspaceLayoutMetrics.metricChipFillOpacity
                        )
                    )
                    .frame(height: BookWorkspaceLayoutMetrics.metricChipVisualHeight)
            }
            .overlay {
                Capsule()
                    .strokeBorder(
                        Color.surfaceBorderSubtle.opacity(
                            configuration.isPressed
                                ? BookWorkspaceLayoutMetrics.metricChipPressedBorderOpacity
                                : BookWorkspaceLayoutMetrics.metricChipBorderOpacity
                        ),
                        lineWidth: CardStyle.borderWidth
                    )
                    .frame(height: BookWorkspaceLayoutMetrics.metricChipVisualHeight)
            }
    }
}

/// 阅读数据列的轻量按压反馈，不引入独立卡片、缩放或额外动效。
private struct BookWorkspaceMetricButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.68 : 1)
    }
}

/// 以独立弱表面 Chip 承载三项阅读数据；自然宽度不足时由用户手动横向浏览。
private struct BookWorkspaceMetricsStrip: View {
    let metrics: [BookWorkspaceHeaderMetric]
    let onOpenReadingDetail: () -> Void
    let onEditBook: () -> Void

    @State private var activeScrollEdges = BookWorkspaceMetricScrollEdges.hidden

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(
                alignment: .center,
                spacing: BookWorkspaceLayoutMetrics.metricChipSpacing
            ) {
                ForEach(metrics) { metric in
                    metricButton(metric)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
        }
        .scrollBounceBehavior(.basedOnSize, axes: .horizontal)
        .onScrollGeometryChange(for: BookWorkspaceMetricScrollEdges.self) { geometry in
            BookWorkspaceMetricScrollEdges(geometry: geometry)
        } action: { _, newValue in
            guard activeScrollEdges != newValue else { return }
            activeScrollEdges = newValue
        }
        .mask {
            BookWorkspaceMetricEdgeFadeMask(activeEdges: activeScrollEdges)
        }
        .frame(minHeight: BookWorkspaceLayoutMetrics.minimumControlHeight)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }

    /// 构建单行自然宽度指标；三种数据各自保持完整的图标、点击与无障碍语义。
    private func metricButton(_ metric: BookWorkspaceHeaderMetric) -> some View {
        Button {
            performAction(for: metric.kind)
        } label: {
            BookWorkspaceMetricChipLabel(metric: metric)
        }
        .buttonStyle(BookWorkspaceMetricChipButtonStyle())
        .accessibilityLabel(metric.accessibilityLabel)
    }

    /// 保持既有业务入口：累计阅读进入阅读详情，书签与进度进入书籍编辑。
    private func performAction(for kind: BookWorkspaceHeaderMetricKind) {
        switch kind {
        case .readingDuration:
            onOpenReadingDetail()
        case .bookmark, .readingProgress:
            onEditBook()
        }
    }
}

struct BookWorkspaceBookHeader: View {
    let book: BookDetail
    let onOpenReadingDetail: () -> Void
    let onEditBook: () -> Void

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.verticalSizeClass) private var verticalSizeClass

    private enum Layout {
        static let regularCoverWidth: CGFloat = 92
        static let accessibilityCoverWidth: CGFloat = 72
        static let landscapeCoverWidth: CGFloat = 56
    }

    private enum Presentation: Equatable {
        case regular
        case accessibilityPortrait
        case landscape
    }

    var body: some View {
        HStack(alignment: .top, spacing: BookWorkspaceLayoutMetrics.identityCoverSpacing) {
            identityColumn
                .clipped()
                .layoutPriority(1)
            coverColumn
                .fixedSize(horizontal: true, vertical: true)
        }
        .padding(.horizontal, BookWorkspaceLayoutMetrics.headerHorizontalInset)
        .padding(.top, BookWorkspaceLayoutMetrics.headerTopInset)
        .padding(.bottom, BookWorkspaceLayoutMetrics.headerBottomInset)
        .accessibilityElement(children: .contain)
    }

    private var identityColumn: some View {
        VStack(alignment: .leading, spacing: BookWorkspaceLayoutMetrics.identityToMetricsSpacing) {
            identity

            if !visibleMetrics.isEmpty {
                metricsStrip
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var metricsStrip: some View {
        BookWorkspaceMetricsStrip(
            metrics: visibleMetrics,
            onOpenReadingDetail: onOpenReadingDetail,
            onEditBook: onEditBook
        )
    }

    private var identity: some View {
        VStack(alignment: .leading, spacing: BookWorkspaceLayoutMetrics.identityPrimarySpacing) {
            BookWorkspaceTitleStatusRow(
                title: book.name,
                statusTitle: readStatusTitle,
                statusColor: readStatusColor,
                onEditBook: onEditBook
            )

            if hasMetadata {
                VStack(
                    alignment: .leading,
                    spacing: BookWorkspaceLayoutMetrics.identitySecondarySpacing
                ) {
                    if !book.author.isEmpty {
                        Text(book.author)
                            .font(BookWorkspaceTypography.secondaryInformation)
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(isCompactPresentation ? 1 : 2)
                    }

                    if !publisherText.isEmpty {
                        Text(publisherText)
                            .font(BookWorkspaceTypography.secondaryInformation)
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }

                    if !publicationDateText.isEmpty {
                        Text(publicationDateText)
                            .font(BookWorkspaceTypography.secondaryInformation)
                            .foregroundStyle(Color.textSecondary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var cover: some View {
        Button(action: onOpenReadingDetail) {
            XMBookCover.fixedWidth(
                coverWidth,
                urlString: book.cover,
                cornerRadius: CornerRadius.inlaySmall,
                border: .init(color: .surfaceBorderSubtle, width: CardStyle.borderWidth),
                placeholderIconSize: .large,
                surfaceStyle: .spine
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("查看《\(book.name)》阅读详情")
    }

    /// 将有效评分作为封面附属信息独立承载；零评分不制造不可见的纵向占位。
    private var coverColumn: some View {
        VStack(spacing: Spacing.none) {
            cover
                .frame(width: coverColumnWidth, alignment: .center)

            if book.score > 0 {
                ratingSlot
            }
        }
        .frame(width: coverColumnWidth)
    }

    private var ratingSlot: some View {
        Button(action: onEditBook) {
            ratingCapsule
                .frame(
                    width: BookWorkspaceLayoutMetrics.ratingCapsuleVisualWidth,
                    height: BookWorkspaceLayoutMetrics.ratingCapsuleHeight
                )
                .frame(
                    width: coverColumnWidth,
                    height: BookWorkspaceLayoutMetrics.ratingSlotHeight
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(BookWorkspaceMetricButtonStyle())
        .accessibilityLabel("我的评分，\(ratingValueText) 分")
        .accessibilityHint("点按修改")
    }

    private var ratingCapsule: some View {
        let shape = Capsule()
        return XMRatingBar(
            value: .constant(Double(book.score) / 10.0),
            starCount: BookWorkspaceLayoutMetrics.ratingStarCount,
            size: BookWorkspaceLayoutMetrics.ratingStarSize,
            spacing: BookWorkspaceLayoutMetrics.ratingStarSpacing,
            step: .half,
            isIndicator: true
        )
        .dynamicTypeSize(...DynamicTypeSize.large)
        .accessibilityHidden(true)
        .padding(.horizontal, BookWorkspaceLayoutMetrics.ratingCapsuleHorizontalInset)
        .frame(height: BookWorkspaceLayoutMetrics.ratingCapsuleHeight)
        .background(Color.surfaceCard.opacity(0.12), in: shape)
        .overlay {
            shape.strokeBorder(
                Color.surfaceCard.opacity(0.28),
                lineWidth: CardStyle.borderWidth
            )
        }
    }

    private var coverWidth: CGFloat {
        switch presentation {
        case .regular:
            return Layout.regularCoverWidth
        case .accessibilityPortrait:
            return Layout.accessibilityCoverWidth
        case .landscape:
            return Layout.landscapeCoverWidth
        }
    }

    private var coverColumnWidth: CGFloat {
        max(coverWidth, BookWorkspaceLayoutMetrics.ratingCapsuleVisualWidth)
    }

    private var presentation: Presentation {
        if verticalSizeClass == .compact {
            return .landscape
        }
        if dynamicTypeSize.isAccessibilitySize {
            return .accessibilityPortrait
        }
        return .regular
    }

    private var isCompactPresentation: Bool {
        presentation != .regular
    }

    private var readStatusTitle: String {
        book.readStatusBadgeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var readStatusColor: Color {
        BookEntryReadingStatus(rawValue: book.readStatusID)?.coverBadgeColor
            ?? Color.textSecondary
    }

    private var visibleMetrics: [BookWorkspaceHeaderMetric] {
        var result: [BookWorkspaceHeaderMetric] = []
        if book.totalReadingSeconds > 0 {
            result.append(
                BookWorkspaceHeaderMetric(
                    kind: .readingDuration,
                    value: durationDisplayText,
                    accessibilityLabel: "累计阅读，\(durationDisplayText)"
                )
            )
        }
        if !bookmarkPositionText.isEmpty {
            result.append(
                BookWorkspaceHeaderMetric(
                    kind: .bookmark,
                    value: bookmarkPositionText,
                    accessibilityLabel: "书签页码，\(bookmarkPositionText)"
                )
            )
        }
        if !readingProgressText.isEmpty {
            result.append(
                BookWorkspaceHeaderMetric(
                    kind: .readingProgress,
                    value: readingProgressText,
                    accessibilityLabel: "阅读进度，\(readingProgressText)"
                )
            )
        }
        return result
    }

    private var ratingValueText: String {
        String(format: "%.1f", Double(book.score) / 10.0)
    }

    private var bookmarkPositionText: String {
        book.bookmarkText
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: " 页", with: "页")
    }

    private var readingProgressText: String {
        book.readingProgressText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasMetadata: Bool {
        !book.author.isEmpty || !publisherText.isEmpty || !publicationDateText.isEmpty
    }

    private var publisherText: String {
        book.press.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var publicationDateText: String {
        let value = book.attributes
            .first(where: { $0.kind == .pubDate })?
            .value
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !value.isEmpty, value != "1970-01-01" else { return "" }
        return value
    }

    private var durationDisplayText: String {
        let seconds = max(0, book.totalReadingSeconds)
        let hours = seconds / 3600
        let minutes = (seconds % 3600) / 60
        let remainingSeconds = seconds % 60
        if hours > 0 {
            return minutes > 0 ? "\(hours)小时\(minutes)分钟" : "\(hours)小时"
        }
        if minutes > 0 {
            return remainingSeconds > 0
                ? "\(minutes)分钟\(remainingSeconds)秒"
                : "\(minutes)分钟"
        }
        return "\(remainingSeconds)秒"
    }
}

/// 为分组型 Cell 绘制外层连续圆角与内部轻分隔，Cell 本身仍可独立回收。
private struct BookWorkspaceGroupedCollectionSurface<Content: View>: View {
    let isFirst: Bool
    let isLast: Bool
    let dividerLeading: CGFloat
    let surfaceColor: Color
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
        .background(surfaceColor)
        .compositingGroup()
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
    let surfaceColor: Color
    let onToggleExpansion: () -> Void
    let onOpen: () -> Void

    private let chapterIndent: CGFloat = 18

    var body: some View {
        BookWorkspaceGroupedCollectionSurface(
            isFirst: row.isFirst,
            isLast: row.isLast,
            dividerLeading: BookWorkspaceLayoutMetrics.cardContentInset
                + CGFloat(max(0, row.chapter.level - 1)) * chapterIndent,
            surfaceColor: surfaceColor
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
    let surfaceColor: Color
    let onOpen: () -> Void

    var body: some View {
        BookWorkspaceGroupedCollectionSurface(
            isFirst: row.isFirst,
            isLast: row.isLast,
            dividerLeading: BookWorkspaceLayoutMetrics.cardContentInset,
            surfaceColor: surfaceColor
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
    let surfaceColor: Color
    let onOpen: () -> Void

    var body: some View {
        BookWorkspaceGroupedCollectionSurface(
            isFirst: row.isFirst,
            isLast: row.isLast,
            dividerLeading: BookWorkspaceLayoutMetrics.cardContentInset,
            surfaceColor: surfaceColor
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
