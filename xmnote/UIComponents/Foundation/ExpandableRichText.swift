/**
 * [INPUT]: 依赖 RichText 的正式 HTML 解析/共享缓存、RichTextLayoutManager、DesignTokens 与 TextKit 字形几何、SwiftUI/UIKit 动画和无障碍能力
 * [OUTPUT]: 对外提供 ExpandableRichText，以及供正式组件和调试验证共享的 ExpandableRichTextLayoutEngine
 * [POS]: UIComponents/Foundation 的跨模块长文本披露组件，以末行有效字形为锚点实现内联「… 展开」微过渡与正文末尾收起
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import QuartzCore
import os
import SwiftUI
import UIKit

/// 可展开/收起的 HTML 富文本组件，使用中性内联操作保持正文为第一视觉焦点。
/// 展开状态由组件内部持有；懒加载回收或内容替换后恢复收起态。
struct ExpandableRichText: View, Equatable {
    let html: String
    var baseFont: UIFont = .preferredFont(forTextStyle: .body)
    var textColor: UIColor = .label
    var lineSpacing: CGFloat = 4
    var maxLines: Int = 3
    var actionColor: Color = .textSecondary
    var quoteColor: UIColor = .systemGreen
#if DEBUG
    var debugTargetExpanded: Bool?
#endif

    /// 只比较影响渲染与布局的输入，减少长列表里的无效 UIKit 更新。
    static func == (lhs: ExpandableRichText, rhs: ExpandableRichText) -> Bool {
        let sharedInputsMatch = lhs.html == rhs.html &&
        lhs.baseFont == rhs.baseFont &&
        lhs.textColor == rhs.textColor &&
        lhs.lineSpacing == rhs.lineSpacing &&
        lhs.maxLines == rhs.maxLines &&
        lhs.actionColor == rhs.actionColor &&
        lhs.quoteColor == rhs.quoteColor
#if DEBUG
        return sharedInputsMatch &&
            lhs.debugTargetExpanded == rhs.debugTargetExpanded
#else
        return sharedInputsMatch
#endif
    }

    var body: some View {
#if DEBUG
        ExpandableRichTextCore(
            html: html,
            baseFont: baseFont,
            textColor: textColor,
            lineSpacing: lineSpacing,
            maxLines: max(1, maxLines),
            actionColor: actionColor,
            quoteColor: quoteColor,
            debugTargetExpanded: debugTargetExpanded
        )
#else
        ExpandableRichTextCore(
            html: html,
            baseFont: baseFont,
            textColor: textColor,
            lineSpacing: lineSpacing,
            maxLines: max(1, maxLines),
            actionColor: actionColor,
            quoteColor: quoteColor
        )
#endif
    }
}

/// 长文本披露的唯一阶段状态，目标高度和正文形态均由当前阶段派生。
private enum ExpandableRichTextPhase: Equatable {
    case collapsed
    case expanding(UUID)
    case expanded
    case collapsing(UUID)

    var presentation: ExpandableRichTextPresentation {
        switch self {
        case .collapsed:
            return .collapsed
        case .expanding:
            return .expanding
        case .expanded:
            return .expanded
        case .collapsing:
            return .collapsing
        }
    }
}

/// UIKit 只消费阶段的派生展示语义，不再维护独立的展开布尔状态。
private enum ExpandableRichTextPresentation: Equatable {
    case collapsed
    case expanding
    case expanded
    case collapsing

    var targetsExpandedHeight: Bool {
        self == .expanding || self == .expanded
    }

    var rendersExpandedContent: Bool {
        self != .collapsed
    }
}

/// 长文本披露的 SwiftUI 状态壳层，以单一阶段保证动画可中断且完成回调不会回写旧状态。
private struct ExpandableRichTextCore: View {
    let html: String
    let baseFont: UIFont
    let textColor: UIColor
    let lineSpacing: CGFloat
    let maxLines: Int
    let actionColor: Color
    let quoteColor: UIColor
#if DEBUG
    let debugTargetExpanded: Bool?
#endif

    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion
    @State private var phase: ExpandableRichTextPhase = .collapsed

    var body: some View {
        ExpandableRichTextRepresentable(
            html: html,
            baseFont: baseFont,
            textColor: textColor,
            lineSpacing: lineSpacing,
            maxLines: maxLines,
            actionColor: actionColor,
            quoteColor: quoteColor,
            presentation: phase.presentation,
            reduceMotion: accessibilityReduceMotion,
            onToggle: toggleDisclosure
        )
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .onChange(of: contentResetSignature) {
            resetForContentReplacement()
        }
#if DEBUG
        .onChange(of: debugTargetExpanded) {
            guard let debugTargetExpanded else { return }
            setDisclosure(expanded: debugTargetExpanded)
        }
#endif
    }

    private var contentResetSignature: String {
        [
            html,
            baseFont.fontName,
            String(describing: baseFont.pointSize),
            textColor.description,
            String(describing: lineSpacing),
            String(maxLines),
            quoteColor.description,
        ].joined(separator: "|")
    }

    /// 根据当前目标反转披露状态；阶段令牌阻止被打断的旧动画回写最终状态。
    private func toggleDisclosure() {
        setDisclosure(expanded: !phase.presentation.targetsExpandedHeight)
    }

    /// 将组件推进到明确的目标状态；相同目标不会重复触发测量或动画。
    private func setDisclosure(expanded shouldExpand: Bool) {
        guard phase.presentation.targetsExpandedHeight != shouldExpand else { return }
        ExpandableRichTextDiagnostics.record(.phaseTransition)

        if accessibilityReduceMotion {
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                phase = shouldExpand ? .expanded : .collapsed
            }
            return
        }

        let token = UUID()
        let transition: ExpandableRichTextPhase = shouldExpand
            ? .expanding(token)
            : .collapsing(token)

        withAnimation(
            .smooth(duration: 0.28, extraBounce: 0),
            completionCriteria: .logicallyComplete
        ) {
            phase = transition
        } completion: {
            guard phase == transition else { return }
            var transaction = Transaction(animation: nil)
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                phase = shouldExpand ? .expanded : .collapsed
            }
        }
    }

    /// 内容或排版输入替换时无动画回到收起态，阶段替换会让旧完成回调自然失效。
    private func resetForContentReplacement() {
        var transaction = Transaction(animation: nil)
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            phase = .collapsed
        }
    }
}

/// SwiftUI 到 UIKit 的稳定桥接层；展开与收起只改变同一承载视图的配置和测量高度。
private struct ExpandableRichTextRepresentable: UIViewRepresentable {
    let html: String
    let baseFont: UIFont
    let textColor: UIColor
    let lineSpacing: CGFloat
    let maxLines: Int
    let actionColor: Color
    let quoteColor: UIColor
    let presentation: ExpandableRichTextPresentation
    let reduceMotion: Bool
    let onToggle: () -> Void

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.layoutDirection) private var layoutDirection

    /// 创建单一 TextKit 承载视图，并在首次测量前写入完整配置。
    func makeUIView(context: Context) -> ExpandableRichTextCarrierView {
        let view = ExpandableRichTextCarrierView()
        update(view)
        return view
    }

    /// 同步主题、动态字体、书写方向与内部状态，不替换 UIKit 视图身份。
    func updateUIView(_ uiView: ExpandableRichTextCarrierView, context: Context) {
        ExpandableRichTextDiagnostics.record(.updateUIView)
        update(uiView)
    }

    /// 从共享布局引擎读取收起/展开高度，让 SwiftUI 只对目标高度做结构动画。
    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: ExpandableRichTextCarrierView,
        context: Context
    ) -> CGSize? {
        ExpandableRichTextDiagnostics.record(.sizeThatFits)
        let fallbackWidth = uiView.window?.screen.bounds.width ?? 390
        let width = proposal.width ?? fallbackWidth
        guard width > 0, width.isFinite else { return nil }

        let snapshot = uiView.layoutSnapshot(
            width: width,
            maxLines: maxLines,
            layoutDirection: uiLayoutDirection
        )
        return presentation.targetsExpandedHeight ? snapshot.expandedSize : snapshot.size
    }

    private var uiLayoutDirection: UIUserInterfaceLayoutDirection {
        layoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
    }

    private func update(_ uiView: ExpandableRichTextCarrierView) {
        _ = dynamicTypeSize
        let interfaceStyle: UIUserInterfaceStyle = colorScheme == .dark ? .dark : .light
        let colorTraits = UITraitCollection(userInterfaceStyle: interfaceStyle)
        uiView.updateConfiguration(
            html: html,
            baseFont: baseFont,
            textColor: textColor,
            lineSpacing: lineSpacing,
            maxLines: maxLines,
            actionColor: UIColor(actionColor).resolvedColor(with: colorTraits),
            quoteColor: quoteColor.resolvedColor(with: colorTraits),
            layoutDirection: uiLayoutDirection,
            presentation: presentation,
            reduceMotion: reduceMotion,
            onToggle: onToggle
        )
    }
}

/// 单一 TextKit 富文本承载视图，只在披露操作热区参与命中，其他触控透传给外部卡片。
private final class ExpandableRichTextCarrierView: UIView {
    private struct DisclosureTailAnimationKey: Equatable {
        let presentation: ExpandableRichTextPresentation
        let isTruncated: Bool
        let reduceMotion: Bool
    }

    private enum RenderedTextKind: Equatable {
        case none
        case collapsed
        case expanded
    }

    private struct TextContainerConfiguration: Equatable {
        let layoutKey: String
        let renderedTextKind: RenderedTextKind
    }

    private let layoutManager = RichTextLayoutManager()
    private let textStorage = NSTextStorage()
    private let textContainer = NSTextContainer(
        size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
    )
    private lazy var textView = UITextView(frame: .zero, textContainer: textContainer)
    private let disclosureTailLabel = UILabel()
    private let expandButton = UIButton(type: .custom)
    private let collapseButton = UIButton(type: .custom)
    private let textMaskRootLayer = CALayer()
    private let textMaskTopLayer = CALayer()
    private let textMaskBottomLayer = CALayer()
    private let textMaskLeadingLayer = CALayer()
    private let textMaskTrailingLayer = CALayer()
    private let textMaskTailRevealLayer = CALayer()

    private var baseAttributedText = NSAttributedString()
    private var expandedAttributedText = NSAttributedString()
    private var contentKey = ""
    private var actionSignature = ""
    private var localLayoutKey = ""
    private var localLayoutSnapshot: RichTextLayoutSnapshot?
    private var maxLines = 3
    private var actionFont = AppTypography.uiCaptionMedium()
    private var actionColor = UIColor.secondaryLabel
    private var layoutDirection: UIUserInterfaceLayoutDirection = .leftToRight
    private var presentation: ExpandableRichTextPresentation = .collapsed
    private var renderedTextKind: RenderedTextKind = .none
    private var renderedTextKey = ""
    private var reduceMotion = false
    private var snapshot = RichTextLayoutSnapshot(size: .zero, isTruncated: false)
    private var textContainerConfiguration: TextContainerConfiguration?
    private var expandHitRect = CGRect.zero
    private var collapseHitRect = CGRect.zero
    private var collapseActionRange = NSRange(location: NSNotFound, length: 0)
    private var onToggle: (() -> Void)?
    private var disclosureTailAnimator: UIViewPropertyAnimator?
    private var lastDisclosureTailAnimationKey: DisclosureTailAnimationKey?
    private var lastAccessibilityPresentation: ExpandableRichTextPresentation?

    /// 创建文本系统、覆盖按钮与无障碍承载关系。
    override init(frame: CGRect) {
        super.init(frame: frame)
        setupTextSystem()
        setupSubviews()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 仅在内容或环境签名变化时解析富文本，其余更新只改变排版状态。
    func updateConfiguration(
        html: String,
        baseFont: UIFont,
        textColor: UIColor,
        lineSpacing: CGFloat,
        maxLines: Int,
        actionColor: UIColor,
        quoteColor: UIColor,
        layoutDirection: UIUserInterfaceLayoutDirection,
        presentation: ExpandableRichTextPresentation,
        reduceMotion: Bool,
        onToggle: @escaping () -> Void
    ) {
        ExpandableRichTextDiagnostics.record(.configurationUpdate)
        self.onToggle = onToggle
        let normalizedMaxLines = max(1, maxLines)
        let resolvedActionFont = AppTypography.uiCaptionMedium(compatibleWith: traitCollection)

        let resolvedContentKey = RichText.contentCacheKey(
            html: html,
            baseFont: baseFont,
            textColor: textColor,
            lineSpacing: lineSpacing,
            traitCollection: traitCollection
        )
        let resolvedActionSignature = [
            actionColor.description,
            resolvedActionFont.fontName,
            String(describing: resolvedActionFont.pointSize),
        ].joined(separator: "|")

        var needsLayout = false
        let contentChanged = contentKey != resolvedContentKey
        let actionChanged = actionSignature != resolvedActionSignature
        let geometryChanged = self.maxLines != normalizedMaxLines ||
            self.layoutDirection != layoutDirection ||
            actionChanged
        let appearanceChanged = self.actionColor != actionColor ||
            layoutManager.quoteColor != quoteColor ||
            actionChanged ||
            self.layoutDirection != layoutDirection
        let presentationChanged = self.presentation != presentation

        if contentChanged {
            contentKey = resolvedContentKey
            localLayoutKey = ""
            localLayoutSnapshot = nil

            let attributed = RichText.resolvedAttributedString(
                html: html,
                baseFont: baseFont,
                textColor: textColor,
                lineSpacing: lineSpacing,
                traitCollection: traitCollection
            )
            baseAttributedText = ExpandableRichTextLayoutEngine.normalizedAttributedText(attributed)
            needsLayout = true
        }

        if contentChanged || actionChanged {
            actionSignature = resolvedActionSignature
            actionFont = resolvedActionFont
            expandedAttributedText = ExpandableRichTextLayoutEngine.appendingCollapseAction(
                to: baseAttributedText,
                actionFont: actionFont,
                actionColor: actionColor
            )
            collapseActionRange = ExpandableRichTextLayoutEngine.collapseActionRange(
                in: expandedAttributedText
            ) ?? NSRange(location: NSNotFound, length: 0)
            localLayoutKey = ""
            localLayoutSnapshot = nil
            needsLayout = true
        }

        if geometryChanged {
            self.maxLines = normalizedMaxLines
            self.layoutDirection = layoutDirection
            textContainerConfiguration = nil
            localLayoutKey = ""
            localLayoutSnapshot = nil
            needsLayout = true
        }

        if appearanceChanged {
            self.actionColor = actionColor
            layoutManager.quoteColor = quoteColor
            actionFont = resolvedActionFont
            semanticContentAttribute = layoutDirection == .rightToLeft
                ? .forceRightToLeft
                : .forceLeftToRight
            textView.semanticContentAttribute = semanticContentAttribute
            disclosureTailLabel.font = actionFont
            disclosureTailLabel.textColor = actionColor
            textView.linkTextAttributes = [.foregroundColor: actionColor]
            textView.setNeedsDisplay()
        }

        self.reduceMotion = reduceMotion
        if presentationChanged {
            self.presentation = presentation
            needsLayout = true
        }

        let renderStateChanged = applyRenderedAttributedTextIfNeeded()
        if contentChanged || presentationChanged || renderStateChanged {
            updateAccessibilityState(shouldMoveFocus: renderStateChanged)
        }
        if needsLayout || renderStateChanged {
            setNeedsLayout()
        }
    }

    /// 读取或生成当前宽度桶的正式布局快照，展开/收起过程不重新解析 HTML。
    func layoutSnapshot(
        width: CGFloat,
        maxLines: Int,
        layoutDirection: UIUserInterfaceLayoutDirection
    ) -> RichTextLayoutSnapshot {
        let scale = window?.screen.scale ?? max(traitCollection.displayScale, 1)
        let layoutKey = RichText.expandableLayoutCacheKey(
            contentKey: contentKey,
            maxLines: max(1, maxLines),
            width: width,
            screenScale: scale,
            actionFont: actionFont,
            layoutDirection: layoutDirection
        )

        if localLayoutKey == layoutKey, let localLayoutSnapshot {
            ExpandableRichTextDiagnostics.record(.layoutCacheHit)
            return localLayoutSnapshot
        }
        if let cached = RichText.cachedLayoutSnapshot(for: layoutKey) {
            ExpandableRichTextDiagnostics.record(.layoutCacheHit)
            localLayoutKey = layoutKey
            localLayoutSnapshot = cached
            return cached
        }

        ExpandableRichTextDiagnostics.record(.layoutCacheMiss)
        let measured = ExpandableRichTextLayoutEngine.measure(
            attributedText: baseAttributedText,
            width: width,
            maxLines: max(1, maxLines),
            actionFont: actionFont,
            actionColor: actionColor,
            layoutDirection: layoutDirection
        )
        RichText.storeLayoutSnapshot(measured, for: layoutKey)
        localLayoutKey = layoutKey
        localLayoutSnapshot = measured
        return measured
    }

    /// 只把展开/收起的透明按钮作为命中结果，保留外层卡片点击和长按语义。
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        if expandButton.isUserInteractionEnabled, expandHitRect.contains(point) {
            return expandButton
        }
        if collapseButton.isUserInteractionEnabled, collapseHitRect.contains(point) {
            return collapseButton
        }
        return nil
    }

    /// 依据当前快照排版同一 UITextView，并把视觉操作与 44pt 热区定位到真实基线。
    override func layoutSubviews() {
        super.layoutSubviews()
        guard bounds.width > 0 else { return }
        ExpandableRichTextDiagnostics.record(.layoutSubviews)

        let resolvedSnapshot = layoutSnapshot(
            width: bounds.width,
            maxLines: maxLines,
            layoutDirection: layoutDirection
        )
        if snapshot != resolvedSnapshot {
            snapshot = resolvedSnapshot
            updateAccessibilityState(shouldMoveFocus: false)
        }

        let textHeight = presentation.rendersExpandedContent
            ? max(bounds.height, snapshot.expandedSize.height)
            : bounds.height
        let nextTextFrame = CGRect(
            x: 0,
            y: 0,
            width: bounds.width,
            height: textHeight
        )
        if textView.frame != nextTextFrame {
            textView.frame = nextTextFrame
        }

        configureTextContainerIfNeeded()
        layoutExpandAction()
        layoutCollapseAction()
        layoutTextMask()
        updateDisclosureTailTransition()
    }

    private func setupTextSystem() {
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        layoutManager.bulletColor = .label

        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
        textContainer.lineFragmentPadding = 0
    }

    private func setupSubviews() {
        clipsToBounds = true
        backgroundColor = .clear

        textView.backgroundColor = .clear
        textView.isEditable = false
        textView.isSelectable = false
        textView.isScrollEnabled = false
        textView.isUserInteractionEnabled = false
        textView.textContainerInset = .zero
        textView.contentInset = .zero
        textView.adjustsFontForContentSizeCategory = true
        textView.isAccessibilityElement = false
        addSubview(textView)

        setupTextMask()

        disclosureTailLabel.text = ExpandableRichTextLayoutEngine.disclosureTailText
        disclosureTailLabel.numberOfLines = 1
        disclosureTailLabel.isUserInteractionEnabled = false
        disclosureTailLabel.isAccessibilityElement = false
        disclosureTailLabel.alpha = 0
        addSubview(disclosureTailLabel)

        configureActionButton(expandButton)
        expandButton.addTarget(self, action: #selector(handleToggleTapped), for: .touchUpInside)
        addSubview(expandButton)

        configureActionButton(collapseButton)
        collapseButton.addTarget(self, action: #selector(handleToggleTapped), for: .touchUpInside)
        addSubview(collapseButton)

        isAccessibilityElement = true
        accessibilityTraits = .staticText
    }

    private func setupTextMask() {
        let opaqueColor = UIColor.white.cgColor
        [
            textMaskTopLayer,
            textMaskBottomLayer,
            textMaskLeadingLayer,
            textMaskTrailingLayer,
            textMaskTailRevealLayer,
        ].forEach { layer in
            layer.backgroundColor = opaqueColor
            textMaskRootLayer.addSublayer(layer)
        }
        textView.layer.mask = textMaskRootLayer
    }

    private func configureActionButton(_ button: UIButton) {
        button.backgroundColor = .clear
        button.isAccessibilityElement = false
        button.addTarget(self, action: #selector(handleActionTouchDown(_:)), for: .touchDown)
        button.addTarget(
            self,
            action: #selector(handleActionTouchUp(_:)),
            for: [.touchUpInside, .touchUpOutside, .touchCancel, .touchDragExit]
        )
    }

    @discardableResult
    private func applyRenderedAttributedTextIfNeeded() -> Bool {
        let nextKind: RenderedTextKind = presentation.rendersExpandedContent
            ? .expanded
            : .collapsed
        let nextRenderedTextKey = nextKind == .expanded
            ? "\(contentKey)|\(actionSignature)|expanded"
            : "\(contentKey)|collapsed"
        guard renderedTextKey != nextRenderedTextKey else { return false }
        let nextAttributed = nextKind == .expanded
            ? expandedAttributedText
            : baseAttributedText

        textStorage.setAttributedString(nextAttributed)
        renderedTextKind = nextKind
        renderedTextKey = nextRenderedTextKey
        textContainerConfiguration = nil
        ExpandableRichTextDiagnostics.record(.textStorageWrite)
        return true
    }

    private func configureTextContainerIfNeeded() {
        let nextConfiguration = TextContainerConfiguration(
            layoutKey: localLayoutKey,
            renderedTextKind: renderedTextKind
        )
        guard textContainerConfiguration != nextConfiguration else { return }
        textContainerConfiguration = nextConfiguration

        let nextSize = CGSize(
            width: bounds.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        if textContainer.size != nextSize {
            textContainer.size = nextSize
        }

        guard snapshot.isTruncated, !presentation.rendersExpandedContent else {
            textContainer.exclusionPaths = []
            textContainer.maximumNumberOfLines = 0
            textContainer.lineBreakMode = .byWordWrapping
            return
        }

        textContainer.maximumNumberOfLines = maxLines
        textContainer.lineBreakMode = .byWordWrapping
        let reservedRect = ExpandableRichTextLayoutEngine.exclusionRect(
            actionRect: snapshot.actionRect,
            lastLineRect: snapshot.lastLineRect,
            width: bounds.width,
            layoutDirection: layoutDirection
        )
        textContainer.exclusionPaths = reservedRect.width > 0 && reservedRect.height > 0
            ? [UIBezierPath(rect: reservedRect)]
            : []
    }

    private func layoutExpandAction() {
        guard snapshot.isTruncated else {
            disclosureTailLabel.frame = .zero
            expandButton.frame = .zero
            expandHitRect = .zero
            expandButton.isUserInteractionEnabled = false
            return
        }

        disclosureTailLabel.frame = snapshot.actionRect
        expandHitRect = minimumHitRect(around: snapshot.actionRect)
        let isInteractive = presentation == .collapsed
        expandButton.frame = isInteractive ? expandHitRect : .zero
        expandButton.isUserInteractionEnabled = isInteractive
    }

    private func layoutCollapseAction() {
        guard snapshot.isTruncated,
              presentation.rendersExpandedContent,
              !snapshot.collapseActionRect.isEmpty else {
            collapseButton.frame = .zero
            collapseHitRect = .zero
            collapseButton.isUserInteractionEnabled = false
            return
        }

        collapseHitRect = minimumHitRect(around: snapshot.collapseActionRect)
        collapseButton.frame = collapseHitRect
        collapseButton.isUserInteractionEnabled = true
    }

    private func minimumHitRect(around visualRect: CGRect) -> CGRect {
        guard !bounds.isEmpty else { return visualRect }
        let targetWidth = min(max(Spacing.actionReserved, visualRect.width), bounds.width)
        let targetHeight = min(max(Spacing.actionReserved, visualRect.height), bounds.height)
        let proposedX = visualRect.midX - targetWidth / 2
        let proposedY = visualRect.midY - targetHeight / 2
        return CGRect(
            x: min(max(0, proposedX), max(0, bounds.width - targetWidth)),
            y: min(max(0, proposedY), max(0, bounds.height - targetHeight)),
            width: targetWidth,
            height: targetHeight
        )
    }

    /// 只在末行披露尾部所在矩形改变文本可见度，避免完整正文与「… 展开」短暂重叠。
    private func layoutTextMask() {
        let maskBounds = textView.bounds
        let reservedRect: CGRect
        if snapshot.isTruncated {
            reservedRect = ExpandableRichTextLayoutEngine.exclusionRect(
                actionRect: snapshot.actionRect,
                lastLineRect: snapshot.lastLineRect,
                width: bounds.width,
                layoutDirection: layoutDirection
            ).intersection(maskBounds)
        } else {
            reservedRect = .zero
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        textMaskRootLayer.frame = maskBounds
        if reservedRect.isEmpty {
            textMaskTopLayer.frame = maskBounds
            textMaskBottomLayer.frame = .zero
            textMaskLeadingLayer.frame = .zero
            textMaskTrailingLayer.frame = .zero
            textMaskTailRevealLayer.frame = .zero
            textMaskTailRevealLayer.opacity = 1
        } else {
            textMaskTopLayer.frame = CGRect(
                x: 0,
                y: 0,
                width: maskBounds.width,
                height: max(0, reservedRect.minY)
            )
            textMaskBottomLayer.frame = CGRect(
                x: 0,
                y: reservedRect.maxY,
                width: maskBounds.width,
                height: max(0, maskBounds.height - reservedRect.maxY)
            )
            textMaskLeadingLayer.frame = CGRect(
                x: 0,
                y: reservedRect.minY,
                width: max(0, reservedRect.minX),
                height: reservedRect.height
            )
            textMaskTrailingLayer.frame = CGRect(
                x: reservedRect.maxX,
                y: reservedRect.minY,
                width: max(0, maskBounds.width - reservedRect.maxX),
                height: reservedRect.height
            )
            textMaskTailRevealLayer.frame = reservedRect
        }
        CATransaction.commit()
    }

    /// 将披露尾部绑定到结构阶段：展开前80ms淡出，收起最后80ms淡入。
    private func updateDisclosureTailTransition() {
        let key = DisclosureTailAnimationKey(
            presentation: presentation,
            isTruncated: snapshot.isTruncated,
            reduceMotion: reduceMotion
        )
        guard lastDisclosureTailAnimationKey != key else { return }
        lastDisclosureTailAnimationKey = key

        guard snapshot.isTruncated else {
            settleDisclosureTail(labelAlpha: 0, textReveal: 1)
            return
        }
        guard !reduceMotion else {
            let showsTail = presentation == .collapsed
            settleDisclosureTail(
                labelAlpha: showsTail ? 1 : 0,
                textReveal: showsTail ? 0 : 1
            )
            return
        }

        switch presentation {
        case .expanding:
            animateDisclosureTail(
                labelAlpha: 0,
                textReveal: 1,
                duration: 0.08,
                delayFactor: 0
            )
        case .collapsing:
            animateDisclosureTail(
                labelAlpha: 1,
                textReveal: 0,
                duration: 0.28,
                delayFactor: (0.28 - 0.08) / 0.28
            )
        case .collapsed:
            settleDisclosureTail(labelAlpha: 1, textReveal: 0)
        case .expanded:
            settleDisclosureTail(labelAlpha: 0, textReveal: 1)
        }
    }

    private func animateDisclosureTail(
        labelAlpha: CGFloat,
        textReveal: Float,
        duration: TimeInterval,
        delayFactor: CGFloat
    ) {
        stopDisclosureTailAnimatorAtCurrentValues()
        let animator = UIViewPropertyAnimator(duration: duration, curve: .easeOut)
        animator.isInterruptible = true
        animator.addAnimations({
            self.disclosureTailLabel.alpha = labelAlpha
            self.textMaskTailRevealLayer.opacity = textReveal
        }, delayFactor: delayFactor)
        disclosureTailAnimator = animator
        animator.startAnimation()
    }

    private func settleDisclosureTail(
        labelAlpha: CGFloat,
        textReveal: Float
    ) {
        disclosureTailAnimator?.stopAnimation(true)
        disclosureTailAnimator = nil
        disclosureTailLabel.layer.removeAllAnimations()
        textMaskTailRevealLayer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disclosureTailLabel.alpha = labelAlpha
        textMaskTailRevealLayer.opacity = textReveal
        CATransaction.commit()
    }

    private func stopDisclosureTailAnimatorAtCurrentValues() {
        let currentLabelAlpha = CGFloat(
            disclosureTailLabel.layer.presentation()?.opacity
                ?? Float(disclosureTailLabel.alpha)
        )
        let currentTextReveal = textMaskTailRevealLayer.presentation()?.opacity
            ?? textMaskTailRevealLayer.opacity
        disclosureTailAnimator?.stopAnimation(true)
        disclosureTailAnimator = nil
        disclosureTailLabel.layer.removeAllAnimations()
        textMaskTailRevealLayer.removeAllAnimations()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        disclosureTailLabel.alpha = currentLabelAlpha
        textMaskTailRevealLayer.opacity = currentTextReveal
        CATransaction.commit()
    }

    private func updateAccessibilityState(shouldMoveFocus: Bool) {
        let baseString = baseAttributedText.string
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let spokenText: String
        if presentation.rendersExpandedContent {
            spokenText = baseString
        } else if snapshot.isTruncated,
                  snapshot.visibleCharacterRange.location != NSNotFound,
                  NSMaxRange(snapshot.visibleCharacterRange) <= baseAttributedText.length {
            let visible = baseAttributedText.attributedSubstring(
                from: snapshot.visibleCharacterRange
            ).string.trimmingCharacters(in: .whitespacesAndNewlines)
            spokenText = visible.isEmpty ? baseString : "\(visible)…"
        } else {
            spokenText = baseString
        }

        isAccessibilityElement = !spokenText.isEmpty
        accessibilityLabel = spokenText
        accessibilityCustomActions = snapshot.isTruncated
            ? [
                UIAccessibilityCustomAction(
                    name: presentation.targetsExpandedHeight ? "收起全文" : "展开全文",
                    target: self,
                    selector: #selector(handleAccessibilityToggle)
                ),
            ]
            : []

        guard shouldMoveFocus,
              lastAccessibilityPresentation != presentation else {
            lastAccessibilityPresentation = presentation
            return
        }
        lastAccessibilityPresentation = presentation
        guard UIAccessibility.isVoiceOverRunning else { return }
        UIAccessibility.post(notification: .layoutChanged, argument: self)
    }

    private func updateCollapseActionPressed(_ isPressed: Bool) {
        guard collapseActionRange.location != NSNotFound,
              NSMaxRange(collapseActionRange) <= textStorage.length else {
            return
        }
        let color = isPressed ? actionColor.withAlphaComponent(0.62) : actionColor
        textStorage.addAttribute(
            .foregroundColor,
            value: color,
            range: collapseActionRange
        )
        textView.setNeedsDisplay()
    }

    @objc
    private func handleToggleTapped() {
        onToggle?()
    }

    @objc
    private func handleActionTouchDown(_ sender: UIButton) {
        if sender === expandButton {
            disclosureTailLabel.alpha = min(disclosureTailLabel.alpha, 0.62)
        } else {
            updateCollapseActionPressed(true)
        }
    }

    @objc
    private func handleActionTouchUp(_ sender: UIButton) {
        if sender === expandButton {
            disclosureTailLabel.alpha = presentation == .collapsed ? 1 : 0
        } else {
            updateCollapseActionPressed(false)
        }
    }

    @objc
    private func handleAccessibilityToggle() -> Bool {
        onToggle?()
        return true
    }
}

/// TextKit 布局引擎为正式组件与调试验证生成同一份收起/展开几何快照。
enum ExpandableRichTextLayoutEngine {
    static let disclosureTailText = "…\u{00A0}展开"
    private static let collapseURL = URL(string: "xmnote://rich-text/collapse")!
    private static let collapseText = "\u{00A0}收\u{2060}起"

    /// 测量完整富文本、内联操作基线、可见字符范围和两种高度。
    static func measure(
        attributedText: NSAttributedString,
        width: CGFloat,
        maxLines: Int,
        actionFont: UIFont,
        actionColor: UIColor,
        layoutDirection: UIUserInterfaceLayoutDirection
    ) -> RichTextLayoutSnapshot {
        guard width > 0, width.isFinite, attributedText.length > 0 else {
            return RichTextLayoutSnapshot(
                size: CGSize(width: max(0, width), height: 0),
                isTruncated: false
            )
        }
        ExpandableRichTextDiagnostics.record(.textKitMeasurement)

        let normalized = normalizedAttributedText(attributedText)
        let fullLayout = measureLayout(
            attributedText: normalized,
            width: width,
            maximumNumberOfLines: 0,
            exclusionRect: nil
        )
        let normalizedMaxLines = max(1, maxLines)
        let hasOverflow = fullLayout.lineRects.count > normalizedMaxLines
        let expanded = appendingCollapseAction(
            to: normalized,
            actionFont: actionFont,
            actionColor: actionColor
        )
        let trackedCollapseRange = collapseActionRange(in: expanded)
        let expandedLayout = measureLayout(
            attributedText: expanded,
            width: width,
            maximumNumberOfLines: 0,
            exclusionRect: nil,
            trackedCharacterRange: trackedCollapseRange
        )

        guard hasOverflow else {
            return RichTextLayoutSnapshot(
                size: CGSize(width: width, height: fullLayout.height),
                isTruncated: false,
                expandedSize: CGSize(width: width, height: fullLayout.height),
                lastLineBaseline: fullLayout.lineBaselines.last ?? 0,
                lastLineRect: fullLayout.lineRects.last ?? .zero,
                visibleCharacterRange: NSRange(location: 0, length: normalized.length)
            )
        }

        let provisionalLineRect = fullLayout.lineRects[normalizedMaxLines - 1]
        let provisionalReservedRect = provisionalExclusionRect(
            actionWidth: actionSize(actionFont: actionFont).width,
            lastLineRect: provisionalLineRect,
            width: width,
            layoutDirection: layoutDirection
        )
        var collapsedLayout = measureLayout(
            attributedText: normalized,
            width: width,
            maximumNumberOfLines: normalizedMaxLines,
            exclusionRect: provisionalReservedRect
        )
        var lastLineRect = collapsedLayout.lineRects.last ?? provisionalLineRect
        var baseline = collapsedLayout.lineBaselines.last
            ?? fullLayout.lineBaselines[normalizedMaxLines - 1]
        var lastLineUsedRect = collapsedLayout.lineMeaningfulGlyphRects.last ?? .zero
        var actionRect = actionFrame(
            width: width,
            baseline: baseline,
            actionFont: actionFont,
            contentRect: lastLineUsedRect,
            layoutDirection: layoutDirection
        )
        let finalReservedRect = exclusionRect(
            actionRect: actionRect,
            lastLineRect: lastLineRect,
            width: width,
            layoutDirection: layoutDirection
        )

        if !finalReservedRect.approximatelyEquals(provisionalReservedRect) {
            collapsedLayout = measureLayout(
                attributedText: normalized,
                width: width,
                maximumNumberOfLines: normalizedMaxLines,
                exclusionRect: finalReservedRect
            )
            lastLineRect = collapsedLayout.lineRects.last ?? lastLineRect
            baseline = collapsedLayout.lineBaselines.last ?? baseline
            lastLineUsedRect = collapsedLayout.lineMeaningfulGlyphRects.last
                ?? lastLineUsedRect
            actionRect = actionFrame(
                width: width,
                baseline: baseline,
                actionFont: actionFont,
                contentRect: lastLineUsedRect,
                layoutDirection: layoutDirection
            )
        }

        return RichTextLayoutSnapshot(
            size: CGSize(width: width, height: collapsedLayout.height),
            isTruncated: true,
            expandedSize: CGSize(width: width, height: expandedLayout.height),
            lastLineBaseline: baseline,
            lastLineRect: lastLineRect,
            visibleCharacterRange: collapsedLayout.visibleCharacterRange,
            actionRect: actionRect,
            collapseActionRect: expandedLayout.trackedCharacterRect
        )
    }

    /// 复制正式富文本并统一自然换行，保留粗体、链接、列表和引用等语义属性。
    static func normalizedAttributedText(
        _ attributedText: NSAttributedString
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: attributedText)
        let fullRange = NSRange(location: 0, length: result.length)
        guard fullRange.length > 0 else { return result }

        result.enumerateAttribute(.paragraphStyle, in: fullRange) { value, range, _ in
            let style = (value as? NSParagraphStyle)?.mutableCopy()
                as? NSMutableParagraphStyle ?? NSMutableParagraphStyle()
            style.lineBreakMode = .byWordWrapping
            result.addAttribute(.paragraphStyle, value: style, range: range)
        }
        return result
    }

    /// 在完整正文末尾追加不可拆分的中性“收起”链接，供视觉排版和透明热区定位。
    static func appendingCollapseAction(
        to attributedText: NSAttributedString,
        actionFont: UIFont,
        actionColor: UIColor
    ) -> NSAttributedString {
        let result = NSMutableAttributedString(attributedString: attributedText)
        trimTrailingWhitespaceAndNewlines(in: result)

        var attributes: [NSAttributedString.Key: Any] = [
            .font: actionFont,
            .foregroundColor: actionColor,
            .link: collapseURL,
        ]
        if result.length > 0,
           let paragraphStyle = result.attribute(
               .paragraphStyle,
               at: result.length - 1,
               effectiveRange: nil
           ) {
            attributes[.paragraphStyle] = paragraphStyle
        }
        result.append(NSAttributedString(string: collapseText, attributes: attributes))
        return result
    }

    /// 返回追加“收起”在完整富文本中的字符范围，供点击热区和按压反馈复用。
    static func collapseActionRange(
        in attributedText: NSAttributedString
    ) -> NSRange? {
        guard attributedText.length > 0 else { return nil }
        var effectiveRange = NSRange(location: NSNotFound, length: 0)
        let value = attributedText.attribute(
            .link,
            at: attributedText.length - 1,
            effectiveRange: &effectiveRange
        )
        guard let url = value as? URL,
              url == collapseURL,
              effectiveRange.location != NSNotFound else {
            return nil
        }
        return effectiveRange
    }

    /// 从内联披露尾部起点生成排除区域，阻止正文继续进入尾部及其 trailing 空间。
    static func exclusionRect(
        actionRect: CGRect,
        lastLineRect: CGRect,
        width: CGFloat,
        layoutDirection: UIUserInterfaceLayoutDirection
    ) -> CGRect {
        switch layoutDirection {
        case .rightToLeft:
            return CGRect(
                x: 0,
                y: lastLineRect.minY,
                width: min(width, max(0, actionRect.maxX)),
                height: lastLineRect.height
            )
        default:
            let x = min(width, max(0, actionRect.minX))
            return CGRect(
                x: x,
                y: lastLineRect.minY,
                width: max(0, width - x),
                height: lastLineRect.height
            )
        }
    }

    /// 首次测量只按完整披露尾部宽度保留 trailing 空间，不把该位置作为视觉锚点。
    private static func provisionalExclusionRect(
        actionWidth: CGFloat,
        lastLineRect: CGRect,
        width: CGFloat,
        layoutDirection: UIUserInterfaceLayoutDirection
    ) -> CGRect {
        let reservedWidth = min(max(0, actionWidth), width)
        switch layoutDirection {
        case .rightToLeft:
            return CGRect(
                x: 0,
                y: lastLineRect.minY,
                width: reservedWidth,
                height: lastLineRect.height
            )
        default:
            return CGRect(
                x: max(0, width - reservedWidth),
                y: lastLineRect.minY,
                width: reservedWidth,
                height: lastLineRect.height
            )
        }
    }

    private static func actionFrame(
        width: CGFloat,
        baseline: CGFloat,
        actionFont: UIFont,
        contentRect: CGRect,
        layoutDirection: UIUserInterfaceLayoutDirection
    ) -> CGRect {
        let measuredSize = actionSize(actionFont: actionFont)
        let actionWidth = min(measuredSize.width, max(0, width))
        let maximumX = max(0, width - actionWidth)
        let naturalX: CGFloat
        switch layoutDirection {
        case .rightToLeft:
            naturalX = contentRect.minX - actionWidth
        default:
            naturalX = contentRect.maxX
        }
        let x = min(max(0, naturalX), maximumX)
        return CGRect(
            x: x,
            y: max(0, baseline - actionFont.ascender),
            width: actionWidth,
            height: measuredSize.height
        )
    }

    private static func actionSize(actionFont: UIFont) -> CGSize {
        let titleSize = (disclosureTailText as NSString).size(
            withAttributes: [.font: actionFont]
        )
        return CGSize(
            width: ceil(titleSize.width),
            height: ceil(actionFont.lineHeight)
        )
    }

    private static func measureLayout(
        attributedText: NSAttributedString,
        width: CGFloat,
        maximumNumberOfLines: Int,
        exclusionRect: CGRect?,
        trackedCharacterRange: NSRange? = nil
    ) -> TextLayout {
        let textStorage = NSTextStorage(attributedString: attributedText)
        let layoutManager = RichTextLayoutManager()
        let textContainer = NSTextContainer(
            size: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        )
        textContainer.lineFragmentPadding = 0
        textContainer.maximumNumberOfLines = maximumNumberOfLines
        textContainer.lineBreakMode = .byWordWrapping
        if let exclusionRect, exclusionRect.width > 0, exclusionRect.height > 0 {
            textContainer.exclusionPaths = [UIBezierPath(rect: exclusionRect)]
        }
        layoutManager.addTextContainer(textContainer)
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureLayout(for: textContainer)

        let glyphRange = layoutManager.glyphRange(for: textContainer)
        var lineRects: [CGRect] = []
        var lineMeaningfulGlyphRects: [CGRect] = []
        var lineBaselines: [CGFloat] = []
        var lineGlyphRanges: [NSRange] = []
        if glyphRange.length > 0 {
            layoutManager.enumerateLineFragments(
                forGlyphRange: glyphRange
            ) { lineRect, usedRect, _, lineGlyphRange, _ in
                lineRects.append(lineRect)
                lineMeaningfulGlyphRects.append(
                    meaningfulGlyphRect(
                        layoutManager: layoutManager,
                        textContainer: textContainer,
                        attributedText: attributedText,
                        lineGlyphRange: lineGlyphRange,
                        fallbackUsedRect: usedRect
                    )
                )
                lineGlyphRanges.append(lineGlyphRange)
                let baselineOffset = lineGlyphRange.length > 0
                    ? layoutManager.location(forGlyphAt: lineGlyphRange.location).y
                    : 0
                lineBaselines.append(lineRect.minY + baselineOffset)
            }
        }

        let visibleCharacterRange = visibleCharacterRange(
            layoutManager: layoutManager,
            lineGlyphRanges: lineGlyphRanges,
            attributedText: attributedText
        )
        let trackedCharacterRect: CGRect
        if let trackedCharacterRange,
           trackedCharacterRange.location != NSNotFound,
           NSMaxRange(trackedCharacterRange) <= attributedText.length {
            let trackedGlyphRange = layoutManager.glyphRange(
                forCharacterRange: trackedCharacterRange,
                actualCharacterRange: nil
            )
            trackedCharacterRect = layoutManager.boundingRect(
                forGlyphRange: trackedGlyphRange,
                in: textContainer
            )
        } else {
            trackedCharacterRect = .zero
        }
        let height = ceil(max(0, lineRects.last?.maxY ?? 0))
        return TextLayout(
            lineRects: lineRects,
            lineMeaningfulGlyphRects: lineMeaningfulGlyphRects,
            lineBaselines: lineBaselines,
            height: height,
            visibleCharacterRange: visibleCharacterRange,
            trackedCharacterRect: trackedCharacterRect
        )
    }

    private static func visibleCharacterRange(
        layoutManager: NSLayoutManager,
        lineGlyphRanges: [NSRange],
        attributedText: NSAttributedString
    ) -> NSRange {
        guard let lastGlyphRange = lineGlyphRanges.last,
              lastGlyphRange.length > 0 else {
            return NSRange(location: 0, length: 0)
        }

        var visibleGlyphEnd = NSMaxRange(lastGlyphRange)
        let truncatedRange = layoutManager.truncatedGlyphRange(
            inLineFragmentForGlyphAt: lastGlyphRange.location
        )
        if truncatedRange.location != NSNotFound, truncatedRange.length > 0 {
            visibleGlyphEnd = min(visibleGlyphEnd, truncatedRange.location)
        }
        guard visibleGlyphEnd > 0 else {
            return NSRange(location: 0, length: 0)
        }
        let characterRange = layoutManager.characterRange(
            forGlyphRange: NSRange(location: 0, length: visibleGlyphEnd),
            actualGlyphRange: nil
        )
        return trimmingTrailingWhitespaceAndNewlines(
            from: characterRange,
            in: attributedText.string as NSString
        )
    }

    /// 返回一行中最后一个有效字形对应的真实绘制区域，忽略尾随空格和换行。
    private static func meaningfulGlyphRect(
        layoutManager: NSLayoutManager,
        textContainer: NSTextContainer,
        attributedText: NSAttributedString,
        lineGlyphRange: NSRange,
        fallbackUsedRect: CGRect
    ) -> CGRect {
        guard lineGlyphRange.location != NSNotFound,
              lineGlyphRange.length > 0 else {
            return CGRect(
                x: fallbackUsedRect.minX,
                y: fallbackUsedRect.minY,
                width: 0,
                height: fallbackUsedRect.height
            )
        }

        let characterRange = layoutManager.characterRange(
            forGlyphRange: lineGlyphRange,
            actualGlyphRange: nil
        )
        let meaningfulCharacterRange = trimmingTrailingWhitespaceAndNewlines(
            from: characterRange,
            in: attributedText.string as NSString
        )
        guard meaningfulCharacterRange.length > 0 else {
            return CGRect(
                x: fallbackUsedRect.minX,
                y: fallbackUsedRect.minY,
                width: 0,
                height: fallbackUsedRect.height
            )
        }

        let glyphRange = layoutManager.glyphRange(
            forCharacterRange: meaningfulCharacterRange,
            actualCharacterRange: nil
        )
        let meaningfulGlyphRange = NSIntersectionRange(glyphRange, lineGlyphRange)
        guard meaningfulGlyphRange.length > 0 else {
            return CGRect(
                x: fallbackUsedRect.minX,
                y: fallbackUsedRect.minY,
                width: 0,
                height: fallbackUsedRect.height
            )
        }
        return layoutManager.boundingRect(
            forGlyphRange: meaningfulGlyphRange,
            in: textContainer
        )
    }

    private static func trimmingTrailingWhitespaceAndNewlines(
        from range: NSRange,
        in string: NSString
    ) -> NSRange {
        guard range.location != NSNotFound, range.length > 0 else { return range }
        var end = min(NSMaxRange(range), string.length)
        while end > range.location {
            let sequenceRange = string.rangeOfComposedCharacterSequence(at: end - 1)
            guard sequenceRange.location >= range.location else { break }
            let sequence = string.substring(with: sequenceRange)
            let isWhitespace = sequence.unicodeScalars.allSatisfy {
                CharacterSet.whitespacesAndNewlines.contains($0)
            }
            guard isWhitespace else { break }
            end = sequenceRange.location
        }
        return NSRange(
            location: range.location,
            length: max(0, end - range.location)
        )
    }

    private static func trimTrailingWhitespaceAndNewlines(
        in attributedText: NSMutableAttributedString
    ) {
        while attributedText.length > 0 {
            let lastRange = NSRange(location: attributedText.length - 1, length: 1)
            let lastCharacter = attributedText.attributedSubstring(from: lastRange).string
            guard lastCharacter.rangeOfCharacter(from: .whitespacesAndNewlines) != nil else {
                return
            }
            attributedText.deleteCharacters(in: lastRange)
        }
    }

    /// 单次 TextKit 测量的内部行片段结果。
    private struct TextLayout {
        let lineRects: [CGRect]
        let lineMeaningfulGlyphRects: [CGRect]
        let lineBaselines: [CGFloat]
        let height: CGFloat
        let visibleCharacterRange: NSRange
        let trackedCharacterRect: CGRect
    }
}

private extension CGRect {
    func approximatelyEquals(_ other: CGRect, tolerance: CGFloat = 0.5) -> Bool {
        abs(minX - other.minX) <= tolerance &&
            abs(minY - other.minY) <= tolerance &&
            abs(width - other.width) <= tolerance &&
            abs(height - other.height) <= tolerance
    }
}

/// 长文本披露组件的可计数事件，供 Debug 压测页和 Instruments signpost 共用。
enum ExpandableRichTextDiagnosticEvent: String, CaseIterable {
    case updateUIView
    case configurationUpdate
    case sizeThatFits
    case layoutSubviews
    case layoutCacheHit
    case layoutCacheMiss
    case textKitMeasurement
    case textStorageWrite
    case phaseTransition
    case htmlParse
}

#if DEBUG
/// Debug 诊断快照按事件保存累计次数，读取快照不会驱动组件重新布局。
struct ExpandableRichTextDiagnosticSnapshot {
    let counts: [ExpandableRichTextDiagnosticEvent: Int]

    func count(for event: ExpandableRichTextDiagnosticEvent) -> Int {
        counts[event, default: 0]
    }
}
#endif

/// Release 中为零成本空操作；Debug 中同时写入 signpost 和线程安全计数。
enum ExpandableRichTextDiagnostics {
#if DEBUG
    private static let lock = NSLock()
    private static let log = OSLog(
        subsystem: Bundle.main.bundleIdentifier ?? "com.merpyzf.xmnote",
        category: "ExpandableRichText"
    )
    nonisolated(unsafe) private static var counts: [ExpandableRichTextDiagnosticEvent: Int] = [:]

    static func record(_ event: ExpandableRichTextDiagnosticEvent) {
        os_signpost(
            .event,
            log: log,
            name: "ExpandableRichText",
            "%{public}@",
            event.rawValue
        )
        lock.lock()
        counts[event, default: 0] += 1
        lock.unlock()
    }

    static func reset() {
        lock.lock()
        counts.removeAll(keepingCapacity: true)
        lock.unlock()
    }

    static func snapshot() -> ExpandableRichTextDiagnosticSnapshot {
        lock.lock()
        let current = counts
        lock.unlock()
        return ExpandableRichTextDiagnosticSnapshot(counts: current)
    }
#else
    @inline(__always)
    static func record(_ event: ExpandableRichTextDiagnosticEvent) {}
#endif
}

#Preview {
    ScrollView {
        VStack(spacing: Spacing.double) {
            ExpandableRichText(html: "短文本，不会出现披露操作。")
            ExpandableRichText(
                html: "这是一段<b>很长</b>的富文本内容，用于验证末行省略号和内联展开。第一行保持清晰，第二行保持稳定，第三行在尾部自然出现展开操作。第四行以及更多正文只在用户主动展开后显示。<br><br><blockquote>引用和列表语义也必须保留。</blockquote>"
            )
        }
        .padding()
    }
}
