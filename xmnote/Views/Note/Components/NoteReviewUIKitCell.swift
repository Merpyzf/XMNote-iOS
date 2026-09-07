/**
 * [INPUT]: 依赖 NoteReviewCardItem、NoteReviewSettings、RichText 共享解析缓存、TopSwitcherQuote 资源、Nuke 图片管线与设计系统令牌
 * [OUTPUT]: 对外提供三模式 NoteReviewCollectionCell、可并发生成的概览快照、一次性纸张测量与桌面远景分块绘制模型，统一中性深色纸面与文字角色
 * [POS]: Views/Note/Components 的全屏回顾 Cell 层；沉浸阅读保留完整内容，桌面与瀑布流共享可虚拟化的纸张预览
 * [PROTOCOL]: 变更时更新此头部，然后检查 CLAUDE.md
 */

import CoreText
import Nuke
import SwiftUI
import UIKit

/// 区分单条阅读、二维桌面与纵向瀑布流；稳定英文 rawValue 仅用于页面偏好持久化。
enum NoteReviewPresentationMode: String, CaseIterable, Equatable, Hashable {
    case immersive
    case desktop
    case waterfall
}

/// 概览渲染所需的不可变纯文本快照，可在后台从完整卡片生成后安全传回主线程复用。
nonisolated struct NoteReviewOverviewSnapshot: Hashable, Sendable {
    let noteID: Int64
    let body: String
    let idea: String
    let bookTitle: String?
    let chapter: String?
    let isBodySourceTruncated: Bool
}

/// 一次性文本测量结果；Cell 布局与桌面远景直接消费结果，避免滚动热路径重复排版全文。
nonisolated struct NoteReviewOverviewMeasurement: Hashable, Sendable {
    let cardHeight: CGFloat
    let bodyLineCount: Int
    let ideaLineCount: Int
    let isBodyTruncated: Bool
}

/// 把主线程解析后的动态字体压缩为可发送的测量描述；后台任务据此独立创建 Core Text 对象。
nonisolated struct NoteReviewOverviewMeasurementDescriptor: Hashable, Sendable {
    /// 描述一个已经按动态字号解析完成的字体，供后台 Core Text 以相同度量重建字体。
    nonisolated struct Font: Hashable, Sendable {
        let postScriptName: String
        let pointSize: CGFloat
        let lineHeight: CGFloat
    }

    let bookFont: Font
    let bodyFont: Font
    let ideaFont: Font
    let chapterFont: Font
    let contentInset: CGFloat
    let previewSpacing: CGFloat
    let footerSpacing: CGFloat
    let bodyLineSpacing: CGFloat
    let ideaLineSpacing: CGFloat
    let minimumHeight: CGFloat
    let maximumHeight: CGFloat
    let usesAccessibilityText: Bool
}

/// 桌面远景分块中的纯数据覆盖项，可安全在后台从同一几何快照构造。
nonisolated struct NoteReviewDesktopTileItem: Sendable {
    let noteID: Int64
    let frame: CGRect
    let rotation: CGFloat
    let body: String?
    let idea: String?
    let bookTitle: String?
    let chapter: String?
    let bodyLineCount: Int
    let ideaLineCount: Int
    let isBodyTruncated: Bool
    let isLoaded: Bool
    let isSelected: Bool
}

/// 把动态颜色解析为后台 Core Graphics 可消费的不可变 RGBA 值。
nonisolated struct NoteReviewDesktopRGBAColor: Sendable {
    let red: CGFloat
    let green: CGFloat
    let blue: CGFloat
    let alpha: CGFloat

    func cgColor(in colorSpace: CGColorSpace) -> CGColor {
        CGColor(
            colorSpace: colorSpace,
            components: [red, green, blue, alpha]
        ) ?? CGColor(gray: 0, alpha: alpha)
    }

    func withAlphaComponent(_ value: CGFloat) -> NoteReviewDesktopRGBAColor {
        NoteReviewDesktopRGBAColor(
            red: red,
            green: green,
            blue: blue,
            alpha: max(0, min(1, value))
        )
    }
}

/// 远景纸壳栅格只携带线程安全的颜色与几何样式，不把 UIKit 对象送入后台。
nonisolated struct NoteReviewDesktopRasterStyle: Sendable {
    let surfaceColor: NoteReviewDesktopRGBAColor
    let borderColor: NoteReviewDesktopRGBAColor
    let shadowColor: NoteReviewDesktopRGBAColor
    let bodyTextColor: NoteReviewDesktopRGBAColor
    let supplementTextColor: NoteReviewDesktopRGBAColor
    let sourceTextColor: NoteReviewDesktopRGBAColor
    let metadataTextColor: NoteReviewDesktopRGBAColor
    let isDarkAppearance: Bool
    let bodyFont: NoteReviewOverviewMeasurementDescriptor.Font
    let ideaFont: NoteReviewOverviewMeasurementDescriptor.Font
    let bookFont: NoteReviewOverviewMeasurementDescriptor.Font
    let chapterFont: NoteReviewOverviewMeasurementDescriptor.Font
    let bodyAlignment: UInt8
    let auxiliaryAlignment: UInt8
    let contentInset: CGFloat
    let blockSpacing: CGFloat
    let footerSpacing: CGFloat
    let bodyLineSpacing: CGFloat
    let ideaLineSpacing: CGFloat
    let cornerRadius: CGFloat
    let shadowRadius: CGFloat
    let shadowOffset: CGSize
    let borderWidth: CGFloat
}

/// 远景正文覆盖层共享一份字体与动态颜色，避免为每张纸重复解析外观。
struct NoteReviewDesktopTileStyle {
    let rasterStyle: NoteReviewDesktopRasterStyle
    let surfaceColor: UIColor
    let bodyTextColor: UIColor
    let supplementTextColor: UIColor
    let sourceTextColor: UIColor
    let metadataTextColor: UIColor
    let isDarkAppearance: Bool
    let bodyFont: UIFont
    let ideaFont: UIFont
    let bookFont: UIFont
    let chapterFont: UIFont
    let bodyAlignment: NSTextAlignment
    let auxiliaryAlignment: NSTextAlignment
}

/// 包装后台生成的不可变 CGImage；唯一非 Sendable 成员只在完成后交回主线程展示。
nonisolated final class NoteReviewDesktopTileRaster: @unchecked Sendable {
    let image: CGImage
    let contentsScale: CGFloat
    let includesContent: Bool

    init(image: CGImage, contentsScale: CGFloat, includesContent: Bool = false) {
        self.image = image
        self.contentsScale = contentsScale
        self.includesContent = includesContent
    }
}

/// 同一个复用 Cell 中保留两套轻重分明的 UIKit 内容容器，布局切换不更换数据源身份。
@MainActor
final class NoteReviewCollectionCell: UICollectionViewCell {
    static let reuseIdentifier = "NoteReviewCollectionCell"

    /// 区分真正会改变纸面内容与排版的输入，避免可见区刷新反复重建文字和表层。
    private struct ConfigurationSignature: Equatable {
        let noteID: Int64
        let mode: NoteReviewPresentationMode
        let contentRevision: Int
        let appearanceGeneration: Int
        let appearanceTraits: Int
        let widthBucket: Int
    }

    /// 仅服务全屏回顾分页的局部几何，动态 chrome inset 注入前使用与当前页面一致的稳定占位值。
    private enum Layout {
        static let maxReadableWidth: CGFloat = 680
        static let immersiveTopChromeClearance: CGFloat = 132
        static let immersiveBottomChromeClearance: CGFloat = 98
        static let quoteDecorationWidth: CGFloat = 38
        static let quoteDecorationHeight: CGFloat = 26
        static let sourceSeparation: CGFloat = Spacing.double + Spacing.cozy
        static let paperBleed: CGFloat = 0
        static let minimumOverviewHeight: CGFloat = 168
        static let maximumOverviewHeight: CGFloat = 420
        static let paperFooterSpacing: CGFloat = Spacing.compact
        static let paperShadowOpacity: Float = 0.065
        static let paperPlaceholderShadowOpacity: Float = 0.035
        static let paperHighlightedShadowOpacity: Float = 0.085
        static let paperSelectedShadowBoost: Float = 0.018
        static let paperShadowRadius: CGFloat = 10
        static let paperHighlightedShadowRadius: CGFloat = 12
        static let paperShadowOffset = CGSize(width: 0, height: 4)
        static let paperHighlightedShadowOffset = CGSize(width: 0, height: 5)
        static let paperHighlightTranslation: CGFloat = -1
        static let paperHighlightDuration: TimeInterval = 0.16
        static let paperRotationDuration: TimeInterval = 0.3
    }

    var onOpenImages: ((NoteReviewCardItem, Int) -> Void)?
    var onDirectManipulation: (() -> Void)?

    private let immersiveContainer = UIView()
    private let immersiveScrollView = UIScrollView()
    private let immersiveStack = UIStackView()
    private let quoteDecorationHost = UIView()
    private let quoteDecorationImageView = UIImageView(image: UIImage(named: "TopSwitcherQuote"))
    private let contentTextView = NoteReviewReadOnlyRichTextView()
    private let ideaSurface = UIView()
    private let ideaRule = UIView()
    private let ideaTextView = NoteReviewReadOnlyRichTextView()
    private let imageStack = UIStackView()
    private let tagsLabel = UILabel()
    private let immersiveTopFlexibleSpacer = UIView()
    private let immersiveBottomFlexibleSpacer = UIView()
    private let sourceAttributionHost = UIView()
    private var immersiveTopConstraint: NSLayoutConstraint?
    private var immersiveBottomConstraint: NSLayoutConstraint?

    private let paperView = UIView()
    private let paperSurfaceHost = UIView()
    private let paperContainer = UIView()
    private let paperStack = UIStackView()
    private let paperPreviewStack = UIStackView()
    private let paperFooterStack = UIStackView()
    private let paperFlexibleSpacer = UIView()
    private let paperBodyLabel = UILabel()
    private let paperIdeaLabel = UILabel()
    private let paperBookLabel = UILabel()
    private let paperChapterLabel = UILabel()
    private let paperBodyFadeLayer = CAGradientLayer()

    private let immersivePlaceholderView = NoteReviewCellPlaceholderView()
    private let paperPlaceholderView = NoteReviewCellPlaceholderView()
    private var configuredNoteID: Int64?
    private var mode: NoteReviewPresentationMode = .immersive
    private var imageViews: [NoteReviewRemoteImageView] = []
    private var representedItem: NoteReviewCardItem?
    private var isPaperBodyTruncated = false
    private var paperRotation: CGFloat = 0
    private var isPaperHighlighted = false
    private var isPaperSelected = false
    private var paperShadowOpacity = Layout.paperShadowOpacity
    private var paperBorderColor: CGColor?
    private var paperSelectedBorderColor: CGColor?
    private var configurationSignature: ConfigurationSignature?
    private var configuredOverviewSnapshot: NoteReviewOverviewSnapshot?
    private var configuredOverviewMeasurement: NoteReviewOverviewMeasurement?
    private var isOverviewMeasurementProvisional = false
    private var isPaperHiddenForTransition = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        buildViewHierarchy()
        applyDesignTokens()
        immersiveScrollView.panGestureRecognizer.addTarget(self, action: #selector(readingPanBegan(_:)))
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        alpha = 1
        representedItem = nil
        configuredNoteID = nil
        configurationSignature = nil
        configuredOverviewSnapshot = nil
        configuredOverviewMeasurement = nil
        isOverviewMeasurementProvisional = false
        contentTextView.clear()
        ideaTextView.clear()
        imageViews.forEach { $0.cancel() }
        imageViews.removeAll()
        imageStack.arrangedSubviews.forEach { view in
            imageStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        sourceAttributionHost.subviews.forEach { $0.removeFromSuperview() }
        paperSurfaceHost.backgroundColor = .clear
        isPaperBodyTruncated = false
        paperRotation = 0
        isPaperHighlighted = false
        isPaperSelected = false
        paperShadowOpacity = Layout.paperShadowOpacity
        paperBorderColor = nil
        paperSelectedBorderColor = nil
        paperBodyLabel.layer.mask = nil
        setPaperHiddenForTransition(false)
        applyPaperTransform(animated: false, duration: 0)
        immersiveScrollView.setContentOffset(.zero, animated: false)
        onOpenImages = nil
        onDirectManipulation = nil
        sourceAttributionHost.accessibilityCustomActions = nil
        contentTextView.accessibilityCustomActions = nil
        ideaTextView.accessibilityCustomActions = nil
        accessibilityCustomActions = nil
        isAccessibilityElement = false
        accessibilityLabel = nil
        accessibilityValue = nil
        accessibilityHint = nil
        accessibilityTraits = []
        accessibilityIdentifier = nil
    }

    /// 只在内容完全未知时显示中性纸壳；已有相同签名内容时保持原画面，避免 dataSource 回调制造闪白。
    func configurePlaceholder(noteID: Int64, mode: NoteReviewPresentationMode) {
        if configuredNoteID == noteID,
           self.mode == mode,
           configurationSignature != nil {
            return
        }
        if configuredNoteID != noteID {
            immersiveScrollView.setContentOffset(.zero, animated: false)
        }
        configuredNoteID = noteID
        representedItem = nil
        configurationSignature = nil
        configuredOverviewSnapshot = nil
        configuredOverviewMeasurement = nil
        isOverviewMeasurementProvisional = false
        self.mode = mode
        immersiveContainer.isHidden = mode != .immersive
        paperView.isHidden = mode == .immersive || isPaperHiddenForTransition
        paperContainer.isHidden = true
        immersivePlaceholderView.isHidden = mode != .immersive
        paperPlaceholderView.isHidden = mode == .immersive
        immersivePlaceholderView.mode = .immersive
        paperPlaceholderView.mode = mode
        immersiveContainer.accessibilityElementsHidden = true
        contentView.backgroundColor = .clear
        if mode != .immersive {
            configurePaperPlaceholderSurface()
            isAccessibilityElement = true
            accessibilityLabel = "正在加载书摘"
            accessibilityValue = nil
            accessibilityHint = nil
            accessibilityTraits = []
        } else {
            isAccessibilityElement = false
            accessibilityLabel = nil
            accessibilityValue = nil
            accessibilityHint = nil
            accessibilityTraits = []
        }
        setNeedsLayout()
    }

    /// 在 Cell 已进入可见阶段后配置内容；正文预览先于精确测高展示，复用身份不匹配时直接丢弃结果。
    func configure(
        item: NoteReviewCardItem,
        mode: NoteReviewPresentationMode,
        settings: NoteReviewSettings,
        overviewSnapshot: NoteReviewOverviewSnapshot?,
        overviewMeasurement: NoteReviewOverviewMeasurement?,
        paperWidth: CGFloat,
        chromeInsets: UIEdgeInsets,
        contentRevision: Int? = nil,
        appearanceGeneration: Int? = nil
    ) {
        if configuredNoteID != item.id {
            immersiveScrollView.setContentOffset(.zero, animated: false)
            configurationSignature = nil
            configuredOverviewSnapshot = nil
            configuredOverviewMeasurement = nil
            isOverviewMeasurementProvisional = false
        }
        configuredNoteID = item.id
        representedItem = item
        self.mode = mode
        updateChromeInsets(top: chromeInsets.top, bottom: chromeInsets.bottom)
        immersiveContainer.isHidden = mode != .immersive
        paperView.isHidden = mode == .immersive || isPaperHiddenForTransition
        let nextSignature = ConfigurationSignature(
            noteID: item.id,
            mode: mode,
            contentRevision: contentRevision ?? Self.fallbackContentRevision(item: item),
            appearanceGeneration: appearanceGeneration ?? settings.hashValue,
            appearanceTraits: traitCollection.userInterfaceStyle.rawValue * 10 + traitCollection.accessibilityContrast.rawValue,
            widthBucket: Self.widthBucket(for: paperWidth, traitCollection: traitCollection)
        )

        switch mode {
        case .immersive:
            immersivePlaceholderView.isHidden = true
            paperPlaceholderView.isHidden = true
            paperContainer.isHidden = true
            configureImmersiveAccessibility()
            if configurationSignature != nextSignature {
                configureImmersive(item: item, settings: settings)
            }
            configurationSignature = nextSignature
            configuredOverviewSnapshot = nil
            configuredOverviewMeasurement = nil
            isOverviewMeasurementProvisional = false
        case .desktop, .waterfall:
            immersivePlaceholderView.isHidden = true
            guard let overviewSnapshot,
                  overviewSnapshot.noteID == item.id else {
                paperContainer.isHidden = true
                paperPlaceholderView.isHidden = false
                configurePaperPlaceholderSurface()
                configurationSignature = nil
                configuredOverviewSnapshot = nil
                configuredOverviewMeasurement = nil
                isOverviewMeasurementProvisional = false
                isAccessibilityElement = true
                accessibilityLabel = "正在加载书摘"
                accessibilityValue = nil
                accessibilityHint = nil
                accessibilityTraits = []
                accessibilityIdentifier = "note-review-\(item.id)"
                setNeedsLayout()
                return
            }
            paperPlaceholderView.isHidden = true
            paperContainer.isHidden = false
            let resolvedMeasurement = overviewMeasurement
                ?? Self.provisionalOverviewMeasurement(snapshot: overviewSnapshot)
            let isProvisional = overviewMeasurement == nil
            if configurationSignature != nextSignature
                || configuredOverviewSnapshot != overviewSnapshot {
                configureOverview(
                    snapshot: overviewSnapshot,
                    measurement: resolvedMeasurement,
                    settings: settings,
                    paperWidth: paperWidth,
                    isProvisional: isProvisional
                )
            } else if configuredOverviewMeasurement != resolvedMeasurement
                        || isOverviewMeasurementProvisional != isProvisional {
                applyOverviewMeasurement(
                    resolvedMeasurement,
                    snapshot: overviewSnapshot,
                    isProvisional: isProvisional
                )
            }
            configurationSignature = nextSignature
            configuredOverviewSnapshot = overviewSnapshot
            configuredOverviewMeasurement = resolvedMeasurement
            isOverviewMeasurementProvisional = isProvisional
        }
        accessibilityIdentifier = "note-review-\(item.id)"
        setNeedsLayout()
        invalidateIntrinsicContentSize()
    }

    /// 仅凭有界概览快照配置桌面或瀑布流纸张，使正文预览不再等待完整操作卡片查询。
    func configureOverviewPreview(
        noteID: Int64,
        mode: NoteReviewPresentationMode,
        settings: NoteReviewSettings,
        snapshot: NoteReviewOverviewSnapshot,
        measurement: NoteReviewOverviewMeasurement?,
        paperWidth: CGFloat,
        contentRevision: Int,
        appearanceGeneration: Int
    ) {
        guard mode != .immersive, snapshot.noteID == noteID else { return }
        if configuredNoteID != noteID {
            configurationSignature = nil
            configuredOverviewSnapshot = nil
            configuredOverviewMeasurement = nil
            isOverviewMeasurementProvisional = false
        }
        configuredNoteID = noteID
        representedItem = nil
        self.mode = mode
        immersiveContainer.isHidden = true
        immersivePlaceholderView.isHidden = true
        paperView.isHidden = isPaperHiddenForTransition
        paperPlaceholderView.isHidden = true
        paperContainer.isHidden = false
        contentView.backgroundColor = .clear

        let nextSignature = ConfigurationSignature(
            noteID: noteID,
            mode: mode,
            contentRevision: contentRevision,
            appearanceGeneration: appearanceGeneration,
            appearanceTraits: traitCollection.userInterfaceStyle.rawValue * 10 + traitCollection.accessibilityContrast.rawValue,
            widthBucket: Self.widthBucket(for: paperWidth, traitCollection: traitCollection)
        )
        let resolvedMeasurement = measurement
            ?? Self.provisionalOverviewMeasurement(snapshot: snapshot)
        let isProvisional = measurement == nil
        if configurationSignature != nextSignature
            || configuredOverviewSnapshot != snapshot {
            configureOverview(
                snapshot: snapshot,
                measurement: resolvedMeasurement,
                settings: settings,
                paperWidth: paperWidth,
                isProvisional: isProvisional
            )
        } else if configuredOverviewMeasurement != resolvedMeasurement
                    || isOverviewMeasurementProvisional != isProvisional {
            applyOverviewMeasurement(
                resolvedMeasurement,
                snapshot: snapshot,
                isProvisional: isProvisional
            )
        }
        configurationSignature = nextSignature
        configuredOverviewSnapshot = snapshot
        configuredOverviewMeasurement = resolvedMeasurement
        isOverviewMeasurementProvisional = isProvisional
        accessibilityIdentifier = "note-review-\(noteID)"
        setNeedsLayout()
        invalidateIntrinsicContentSize()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let hasOverflow = immersiveScrollView.contentSize.height > immersiveScrollView.bounds.height + 1
        immersiveScrollView.isScrollEnabled = mode == .immersive && hasOverflow
        guard mode != .immersive else { return }
        paperView.layer.shadowPath = UIBezierPath(
            roundedRect: paperView.bounds,
            cornerRadius: CornerRadius.blockLarge
        ).cgPath
        updatePaperBodyFadeMask()
    }

    /// 暴露沉浸内容的真实滚动视图，供页面 chrome 连接系统渐进边缘效果。
    var activeContentScrollView: UIScrollView {
        immersiveScrollView
    }

    /// 内层长文开始滚动也属于直接操控，让父页撤销尚未接管显示权的模式请求。
    @objc private func readingPanBegan(_ recognizer: UIPanGestureRecognizer) {
        if recognizer.state == .began { onDirectManipulation?() }
    }

    /// 对象菜单只占书籍信息与纸面空白；正文、想法、图片和链接保留原生选择/点击。
    func allowsNoteActions(at point: CGPoint) -> Bool {
        guard mode == .immersive, representedItem != nil, let target = hitTest(point, with: nil) else { return false }
        return ![contentTextView, ideaTextView, imageStack].contains { target === $0 || target.isDescendant(of: $0) }
    }

    /// 将同一身份的对象动作附着到可访问的来源区域，避免把富文本整体收为一个元素。
    func setNoteAccessibilityActions(_ actions: [UIAccessibilityCustomAction]) {
        accessibilityCustomActions = actions
        sourceAttributionHost.accessibilityCustomActions = actions
        contentTextView.accessibilityCustomActions = actions
        ideaTextView.accessibilityCustomActions = actions
    }

    /// 为跨模式交接捕获真实单条阅读端点；只截取有效阅读区域，不另建字体或富文本排版。
    func immersiveTransitionEndpoint(in container: UIView, insets: UIEdgeInsets,
                                     surfaceColor: UIColor, requestGeneration: Int = 0) -> NoteReviewCanvasReadingEndpoint? {
        guard mode == .immersive, immersivePlaceholderView.isHidden,
              let signature = configurationSignature else { return nil }
        layoutIfNeeded()
        immersiveContainer.layoutIfNeeded()
        let local = bounds.inset(by: insets)
        guard local.width > 0, local.height > 0 else { return nil }
        let format = UIGraphicsImageRendererFormat()
        format.scale = traitCollection.displayScale
        format.opaque = false
        if representedItem?.imageURLs.isEmpty != false { format.preferredRange = .standard }
        // The scroll view owns system edge composition. Capture its real content subtree,
        // not that composition layer: layer.render on it produces nearly transparent ink.
        let stackFrame = immersiveStack.convert(immersiveStack.bounds, to: self)
        var complete = false
        let viewportImage = UIGraphicsImageRenderer(size: bounds.size, format: format).image { output in
            output.cgContext.translateBy(x: stackFrame.minX, y: stackFrame.minY)
            complete = immersiveStack.drawHierarchy(in: immersiveStack.bounds, afterScreenUpdates: true)
        }
        guard complete, let bitmap = viewportImage.cgImage,
              let crop = bitmap.cropping(to: CGRect(x: local.minX * viewportImage.scale,
                y: local.minY * viewportImage.scale, width: local.width * viewportImage.scale,
                height: local.height * viewportImage.scale)) else { return nil }
        let image = UIImage(cgImage: crop, scale: viewportImage.scale, orientation: .up)
        let color = surfaceColor.resolvedColor(with: traitCollection)
        return NoteReviewCanvasReadingEndpoint(image: image, frame: convert(local, to: container), rotation: 0,
            logicalSize: local.size, surface: NoteReviewCanvasReadingSurface(color: color), backdropColor: color,
            viewportImage: viewportImage, viewportFrame: convert(bounds, to: container),
            identity: .init(noteID: signature.noteID, requestGeneration: requestGeneration,
                contentVersion: signature.contentRevision, appearanceVersion: signature.appearanceGeneration))
    }

    /// 根据真实安全区和浮动控件尺寸更新内容起排边界，旋转和窗口尺寸变化时可重复调用。
    func updateChromeInsets(top: CGFloat, bottom: CGFloat) {
        immersiveTopConstraint?.constant = top
        immersiveBottomConstraint?.constant = -bottom
        immersivePlaceholderView.immersiveTopInset = top
    }

    /// 只有沉浸阅读的无内容背景可切换 chrome，正文及其语义附属内容保持原生选择与点击行为。
    func isBlankChromeToggleTarget(_ target: UIView?) -> Bool {
        guard mode == .immersive, let target,
              target === immersiveContainer || target.isDescendant(of: immersiveContainer) else {
            return false
        }
        let contentViews = [
            quoteDecorationHost,
            contentTextView,
            ideaSurface,
            imageStack,
            tagsLabel,
            sourceAttributionHost
        ]
        return !contentViews.contains { target === $0 || target.isDescendant(of: $0) }
    }

    /// Cell 离开屏幕后立即终止图片请求；再次显示时按当前目标尺寸重新加载。
    func didEndDisplaying() {
        imageViews.forEach { $0.cancel() }
        if mode == .immersive {
            // 图片请求已取消，下一次显示必须重新进入完整配置以恢复图片，而不是命中旧签名。
            configurationSignature = nil
        }
    }

    /// 返回不含 Cell 命中外框的纸面快照，供模式切换按同一 noteID 保持共享对象连续性。
    func makePaperTransitionSnapshot(afterScreenUpdates: Bool = false) -> UIView? {
        guard mode != .immersive,
              !paperView.isHidden,
              paperView.bounds.width > 0,
              paperView.bounds.height > 0 else { return nil }
        return paperView.snapshotView(afterScreenUpdates: afterScreenUpdates)
    }

    /// 返回纸面在指定转场容器中的旋转后视觉外框；控制器只需持有 noteID，不依赖易变 IndexPath。
    func paperTransitionFrame(in container: UIView) -> CGRect? {
        guard mode != .immersive,
              paperView.window != nil else { return nil }
        return paperView.convert(paperView.bounds, to: container)
    }

    /// 转场期间只隐藏真实纸面，Cell 的布局与无障碍身份保持不变；结束或复用时可幂等恢复。
    func setPaperHiddenForTransition(_ hidden: Bool) {
        isPaperHiddenForTransition = hidden
        paperView.isHidden = mode == .immersive || hidden
    }

    /// 指示当前纸面是否仍是内容未知的中性纸壳，转场协调器据此决定是否只运动纸壳。
    var isShowingPaperPlaceholder: Bool {
        mode != .immersive && !paperPlaceholderView.isHidden
    }

    /// 按稳定书摘身份注入纸面的轻微旋转；动画从当前展示状态继续，减少动态效果时立即落位。
    func setPaperRotation(_ radians: CGFloat, animated: Bool) {
        guard paperRotation != radians else { return }
        paperRotation = radians
        applyPaperTransform(
            animated: animated && !UIAccessibility.isReduceMotionEnabled,
            duration: Layout.paperRotationDuration
        )
    }

    /// 反馈纸张按压状态；只抬升一像素并轻微增强既有单层阴影，不改变 Cell 布局外框。
    func setPaperHighlighted(_ isHighlighted: Bool, reduceMotion: Bool) {
        guard isPaperHighlighted != isHighlighted else { return }
        isPaperHighlighted = isHighlighted
        applyPaperTransform(
            animated: !reduceMotion,
            duration: Layout.paperHighlightDuration
        )
    }

    /// 标记桌面或瀑布流的当前书摘，以边线与静态阴影双通道建立轻量焦点，不复用按压态。
    func setPaperSelected(_ selected: Bool) {
        guard isPaperSelected != selected else { return }
        isPaperSelected = selected
        updatePaperEmphasis()
        if mode != .immersive {
            if selected {
                accessibilityTraits.insert(.selected)
            } else {
                accessibilityTraits.remove(.selected)
            }
        }
    }

    /// 在非主线程将完整富文本模型压缩为概览所需的纯文本，滚动阶段只消费结果而不解析 HTML。
    nonisolated static func makeOverviewSnapshot(
        item: NoteReviewCardItem,
        settings: NoteReviewSettings
    ) -> NoteReviewOverviewSnapshot? {
        let rawBookTitle = item.bookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookTitle = settings.immersiveDisplay.showsBookInfo
            ? boundedOverviewText(
                rawBookTitle.isEmpty ? "未命名书籍" : normalizedBookTitle(rawBookTitle),
                limit: 180
            ).text
            : nil
        guard !Task.isCancelled else { return nil }
        let extractedBody = RichTextPlainTextExtractor.plainText(from: item.contentHTML)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Task.isCancelled else { return nil }
        let body = boundedOverviewText(extractedBody, limit: 720)
        let extractedIdea = settings.immersiveDisplay.showsIdea
            ? RichTextPlainTextExtractor.plainText(from: item.ideaHTML)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        guard !Task.isCancelled else { return nil }
        let idea = boundedOverviewText(extractedIdea, limit: 360)
        let rawChapter = item.chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let chapter = settings.immersiveDisplay.showsChapter && !rawChapter.isEmpty
            ? boundedOverviewText(rawChapter, limit: 180).text
            : nil
        return NoteReviewOverviewSnapshot(
            noteID: item.id,
            body: body.text,
            idea: idea.text,
            bookTitle: bookTitle,
            chapter: chapter,
            isBodySourceTruncated: body.isTruncated
        )
    }

    /// 将页面轻量布局源压缩为同一概览快照；原始 HTML 由调用方在本次后台任务结束后立即释放。
    nonisolated static func makeOverviewSnapshot(
        source: NoteReviewOverviewLayoutSource,
        settings: NoteReviewSettings
    ) -> NoteReviewOverviewSnapshot? {
        let rawBookTitle = source.bookTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let bookTitle = settings.immersiveDisplay.showsBookInfo
            ? boundedOverviewText(
                rawBookTitle.isEmpty ? "未命名书籍" : normalizedBookTitle(rawBookTitle),
                limit: 180
            ).text
            : nil
        guard !Task.isCancelled else { return nil }
        let extractedBody = RichTextPlainTextExtractor.plainText(from: source.contentHTML)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !Task.isCancelled else { return nil }
        let body = boundedOverviewText(extractedBody, limit: 720)
        let extractedIdea = settings.immersiveDisplay.showsIdea
            ? RichTextPlainTextExtractor.plainText(from: source.ideaHTML)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        guard !Task.isCancelled else { return nil }
        let idea = boundedOverviewText(extractedIdea, limit: 360)
        let rawChapter = source.chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let chapter = settings.immersiveDisplay.showsChapter && !rawChapter.isEmpty
            ? boundedOverviewText(rawChapter, limit: 180).text
            : nil
        return NoteReviewOverviewSnapshot(
            noteID: source.noteID,
            body: body.text,
            idea: idea.text,
            bookTitle: bookTitle,
            chapter: chapter,
            isBodySourceTruncated: body.isTruncated
        )
    }

    /// 在主线程解析当前 trait 下的动态字体，随后测量任务只携带不可变描述进入后台。
    static func makeOverviewMeasurementDescriptor(
        settings: NoteReviewSettings,
        traitCollection: UITraitCollection
    ) -> NoteReviewOverviewMeasurementDescriptor {
        let fonts = overviewFonts(settings: settings, traitCollection: traitCollection)
        return NoteReviewOverviewMeasurementDescriptor(
            bookFont: measurementFontDescriptor(fonts.book),
            bodyFont: measurementFontDescriptor(fonts.body),
            ideaFont: measurementFontDescriptor(fonts.idea),
            chapterFont: measurementFontDescriptor(fonts.chapter),
            contentInset: Spacing.contentEdge,
            previewSpacing: Spacing.base,
            footerSpacing: Layout.paperFooterSpacing,
            bodyLineSpacing: ReadingContentTypography.bodyLineSpacing,
            ideaLineSpacing: ReadingContentTypography.annotationLineSpacing,
            minimumHeight: Layout.minimumOverviewHeight,
            maximumHeight: Layout.maximumOverviewHeight,
            usesAccessibilityText: traitCollection.preferredContentSizeCategory.isAccessibilityCategory
        )
    }

    /// 保留原调用入口；控制器迁移期间仍可在主线程同步测量，结果与后台版本完全同源。
    static func measureOverview(
        snapshot: NoteReviewOverviewSnapshot,
        settings: NoteReviewSettings,
        paperWidth: CGFloat,
        maximumHeight: CGFloat,
        traitCollection: UITraitCollection
    ) -> NoteReviewOverviewMeasurement {
        measureOverview(
            snapshot: snapshot,
            descriptor: makeOverviewMeasurementDescriptor(
                settings: settings,
                traitCollection: traitCollection
            ),
            paperWidth: paperWidth,
            maximumHeight: maximumHeight
        )
    }

    /// 在后台为一个快照创建独立 Core Text framesetter 并返回最终高度，任务取消由调用方 generation 负责。
    nonisolated static func measureOverview(
        snapshot: NoteReviewOverviewSnapshot,
        descriptor: NoteReviewOverviewMeasurementDescriptor,
        paperWidth: CGFloat,
        maximumHeight: CGFloat
    ) -> NoteReviewOverviewMeasurement {
        let textWidth = max(1, paperWidth - descriptor.contentInset * 2)
        let resolvedMaximumHeight = max(
            descriptor.minimumHeight,
            min(descriptor.maximumHeight, maximumHeight)
        )
        let contentHeightLimit = max(1, resolvedMaximumHeight - descriptor.contentInset * 2)
        var previewHeights: [CGFloat] = []
        let bodyNaturalHeight = coreTextMeasuredHeight(
            snapshot.body,
            font: descriptor.bodyFont,
            width: textWidth,
            lineSpacing: descriptor.bodyLineSpacing,
            lineLimit: nil,
            heightLimit: CGFloat.greatestFiniteMagnitude
        )
        if bodyNaturalHeight > 0 { previewHeights.append(bodyNaturalHeight) }
        let ideaNaturalHeight = coreTextMeasuredHeight(
            snapshot.idea,
            font: descriptor.ideaFont,
            width: textWidth,
            lineSpacing: descriptor.ideaLineSpacing,
            lineLimit: nil,
            heightLimit: CGFloat.greatestFiniteMagnitude
        )
        if ideaNaturalHeight > 0 { previewHeights.append(ideaNaturalHeight) }

        var footerHeights: [CGFloat] = []
        if let bookTitle = snapshot.bookTitle {
            footerHeights.append(
                coreTextMeasuredHeight(
                    bookTitle,
                    font: descriptor.bookFont,
                    width: textWidth,
                    lineSpacing: 0,
                    lineLimit: 2,
                    heightLimit: contentHeightLimit
                )
            )
        }
        if let chapter = snapshot.chapter {
            footerHeights.append(
                coreTextMeasuredHeight(
                    chapter,
                    font: descriptor.chapterFont,
                    width: textWidth,
                    lineSpacing: 0,
                    lineLimit: 2,
                    heightLimit: contentHeightLimit
                )
            )
        }

        let previewSpacing = CGFloat(max(0, previewHeights.count - 1)) * descriptor.previewSpacing
        let footerSpacing = CGFloat(max(0, footerHeights.count - 1)) * descriptor.footerSpacing
        let groupSpacing = previewHeights.isEmpty || footerHeights.isEmpty ? 0 : descriptor.previewSpacing
        let naturalHeight = descriptor.contentInset * 2
            + previewHeights.reduce(0, +)
            + previewSpacing
            + groupSpacing
            + footerHeights.reduce(0, +)
            + footerSpacing
        let cardHeight = ceil(
            min(
                resolvedMaximumHeight,
                max(descriptor.minimumHeight, naturalHeight)
            )
        )
        let fixedHeight = descriptor.contentInset * 2
            + footerHeights.reduce(0, +)
            + footerSpacing
            + groupSpacing
        let textBudget = max(0, cardHeight - fixedHeight - previewSpacing)
        let allocations = paperTextAllocations(
            bodyNaturalHeight: bodyNaturalHeight,
            ideaNaturalHeight: ideaNaturalHeight,
            availableHeight: textBudget,
            bodyFont: descriptor.bodyFont,
            ideaFont: descriptor.ideaFont,
            bodyLineSpacing: descriptor.bodyLineSpacing,
            ideaLineSpacing: descriptor.ideaLineSpacing,
            usesAccessibilityText: descriptor.usesAccessibilityText
        )
        let bodyLineCount = snapshot.body.isEmpty
            ? 0
            : lineCount(
                naturalHeight: bodyNaturalHeight,
                font: descriptor.bodyFont,
                lineSpacing: descriptor.bodyLineSpacing,
                allocatedHeight: allocations.body
            )
        let ideaLineCount = snapshot.idea.isEmpty
            ? 0
            : lineCount(
                naturalHeight: ideaNaturalHeight,
                font: descriptor.ideaFont,
                lineSpacing: descriptor.ideaLineSpacing,
                allocatedHeight: allocations.idea
            )
        return NoteReviewOverviewMeasurement(
            cardHeight: cardHeight,
            bodyLineCount: bodyLineCount,
            ideaLineCount: ideaLineCount,
            isBodyTruncated: snapshot.isBodySourceTruncated
                || bodyNaturalHeight > allocations.body + 0.5
        )
    }

    /// 每个远景 generation 只解析一次字体与动态颜色，供所有分块覆盖层共享。
    static func makeDesktopTileStyle(
        settings: NoteReviewSettings,
        traitCollection: UITraitCollection
    ) -> NoteReviewDesktopTileStyle {
        let appearance = settings.cardAppearance
        let fonts = overviewFonts(settings: settings, traitCollection: traitCollection)
        let surfaceColor = appearance.uiSurface.resolvedColor(with: traitCollection)
        let bodyTextColor = appearance.bodyTextColor.resolvedColor(with: traitCollection)
        let supplementTextColor = appearance.supplementTextColor.resolvedColor(with: traitCollection)
        return NoteReviewDesktopTileStyle(
            rasterStyle: NoteReviewDesktopRasterStyle(
                surfaceColor: desktopRGBA(surfaceColor),
                borderColor: desktopRGBA(supplementTextColor.withAlphaComponent(0.16)),
                shadowColor: NoteReviewDesktopRGBAColor(red: 0, green: 0, blue: 0, alpha: 0.065),
                bodyTextColor: desktopRGBA(bodyTextColor),
                supplementTextColor: desktopRGBA(supplementTextColor),
                sourceTextColor: desktopRGBA(appearance.sourceTextColor.resolvedColor(with: traitCollection)),
                metadataTextColor: desktopRGBA(appearance.metadataTextColor.resolvedColor(with: traitCollection)),
                isDarkAppearance: traitCollection.userInterfaceStyle == .dark,
                bodyFont: measurementFontDescriptor(fonts.body),
                ideaFont: measurementFontDescriptor(fonts.idea),
                bookFont: measurementFontDescriptor(fonts.book),
                chapterFont: measurementFontDescriptor(fonts.chapter),
                bodyAlignment: coreTextAlignment(settings.textAlignment.nsTextAlignment).rawValue,
                auxiliaryAlignment: coreTextAlignment(settings.textAlignment.auxiliaryNSTextAlignment).rawValue,
                contentInset: Spacing.contentEdge,
                blockSpacing: Spacing.base,
                footerSpacing: Layout.paperFooterSpacing,
                bodyLineSpacing: ReadingContentTypography.bodyLineSpacing,
                ideaLineSpacing: ReadingContentTypography.annotationLineSpacing,
                cornerRadius: CornerRadius.blockLarge,
                shadowRadius: 10,
                shadowOffset: CGSize(width: 0, height: 4),
                borderWidth: StrokeWidth.hairline
            ),
            surfaceColor: surfaceColor,
            bodyTextColor: bodyTextColor,
            supplementTextColor: supplementTextColor,
            sourceTextColor: appearance.sourceTextColor.resolvedColor(with: traitCollection),
            metadataTextColor: appearance.metadataTextColor.resolvedColor(with: traitCollection),
            isDarkAppearance: traitCollection.userInterfaceStyle == .dark,
            bodyFont: fonts.body,
            ideaFont: fonts.idea,
            bookFont: fonts.book,
            chapterFont: fonts.chapter,
            bodyAlignment: settings.textAlignment.nsTextAlignment,
            auxiliaryAlignment: settings.textAlignment.auxiliaryNSTextAlignment
        )
    }

    /// 将后台纸张几何与有界正文快照合并为覆盖项，不触发网络请求或创建 UIKit 对象。
    nonisolated static func makeDesktopTileItem(
        noteID: Int64,
        frame: CGRect,
        rotation: CGFloat,
        snapshot: NoteReviewOverviewSnapshot?,
        measurement: NoteReviewOverviewMeasurement?,
        isSelected: Bool
    ) -> NoteReviewDesktopTileItem {
        let resolvedSnapshot = snapshot?.noteID == noteID ? snapshot : nil
        let bodyLineCount = measurement?.bodyLineCount
            ?? (resolvedSnapshot?.body.isEmpty == false ? 3 : 0)
        let ideaLineCount = measurement?.ideaLineCount
            ?? (resolvedSnapshot?.idea.isEmpty == false ? 1 : 0)
        return NoteReviewDesktopTileItem(
            noteID: noteID,
            frame: frame,
            rotation: rotation,
            body: resolvedSnapshot?.body,
            idea: resolvedSnapshot?.idea,
            bookTitle: resolvedSnapshot?.bookTitle,
            chapter: resolvedSnapshot?.chapter,
            bodyLineCount: bodyLineCount,
            ideaLineCount: ideaLineCount,
            isBodyTruncated: measurement?.isBodyTruncated
                ?? (resolvedSnapshot?.isBodySourceTruncated == true || bodyLineCount > 0),
            isLoaded: resolvedSnapshot != nil,
            isSelected: isSelected
        )
    }

    /// 将已按当前 trait 解析的 UIKit 颜色压缩成设备 RGB 数值，供后台纸壳栅格使用。
    private static func desktopRGBA(_ color: UIColor) -> NoteReviewDesktopRGBAColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        if color.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
            return NoteReviewDesktopRGBAColor(red: red, green: green, blue: blue, alpha: alpha)
        }
        var white: CGFloat = 0
        if color.getWhite(&white, alpha: &alpha) {
            return NoteReviewDesktopRGBAColor(red: white, green: white, blue: white, alpha: alpha)
        }
        return NoteReviewDesktopRGBAColor(red: 1, green: 1, blue: 1, alpha: 1)
    }

}

private extension NoteReviewCollectionCell {
    func buildViewHierarchy() {
        contentView.addSubview(immersiveContainer)
        contentView.addSubview(paperView)
        contentView.addSubview(immersivePlaceholderView)
        [immersiveContainer, paperView, immersivePlaceholderView].forEach {
            $0.translatesAutoresizingMaskIntoConstraints = false
        }

        paperSurfaceHost.translatesAutoresizingMaskIntoConstraints = false
        paperSurfaceHost.isAccessibilityElement = false
        paperSurfaceHost.isUserInteractionEnabled = false
        paperContainer.translatesAutoresizingMaskIntoConstraints = false
        paperPlaceholderView.translatesAutoresizingMaskIntoConstraints = false
        paperView.addSubview(paperSurfaceHost)
        paperView.addSubview(paperContainer)
        paperView.addSubview(paperPlaceholderView)

        immersiveStack.axis = .vertical
        immersiveStack.spacing = Spacing.base
        immersiveStack.alignment = .fill
        immersiveStack.translatesAutoresizingMaskIntoConstraints = false
        immersiveScrollView.translatesAutoresizingMaskIntoConstraints = false
        immersiveScrollView.alwaysBounceVertical = true
        immersiveScrollView.showsVerticalScrollIndicator = false
        immersiveScrollView.contentInsetAdjustmentBehavior = .never
        immersiveScrollView.keyboardDismissMode = .interactive
        immersiveScrollView.topEdgeEffect.style = .automatic
        immersiveScrollView.bottomEdgeEffect.style = .automatic
        immersiveContainer.addSubview(immersiveScrollView)
        immersiveScrollView.addSubview(immersiveStack)

        quoteDecorationHost.translatesAutoresizingMaskIntoConstraints = false
        quoteDecorationHost.isUserInteractionEnabled = true
        quoteDecorationImageView.image = UIImage(named: "TopSwitcherQuote")?.withRenderingMode(.alwaysTemplate)
        quoteDecorationImageView.translatesAutoresizingMaskIntoConstraints = false
        quoteDecorationImageView.contentMode = .scaleAspectFit
        quoteDecorationImageView.isAccessibilityElement = false
        quoteDecorationImageView.isUserInteractionEnabled = false
        quoteDecorationHost.addSubview(quoteDecorationImageView)

        ideaRule.translatesAutoresizingMaskIntoConstraints = false
        ideaTextView.translatesAutoresizingMaskIntoConstraints = false
        ideaSurface.addSubview(ideaRule)
        ideaSurface.addSubview(ideaTextView)
        let quoteDecorationHeightConstraint = quoteDecorationHost.heightAnchor.constraint(
            equalToConstant: Layout.quoteDecorationHeight
        )
        quoteDecorationHeightConstraint.priority = .init(999)
        NSLayoutConstraint.activate([
            quoteDecorationHeightConstraint,
            quoteDecorationImageView.leadingAnchor.constraint(equalTo: quoteDecorationHost.leadingAnchor),
            quoteDecorationImageView.topAnchor.constraint(equalTo: quoteDecorationHost.topAnchor),
            quoteDecorationImageView.bottomAnchor.constraint(equalTo: quoteDecorationHost.bottomAnchor),
            quoteDecorationImageView.widthAnchor.constraint(equalToConstant: Layout.quoteDecorationWidth),

            ideaRule.leadingAnchor.constraint(equalTo: ideaSurface.leadingAnchor),
            ideaRule.topAnchor.constraint(equalTo: ideaTextView.topAnchor),
            ideaRule.bottomAnchor.constraint(equalTo: ideaTextView.bottomAnchor),
            ideaRule.widthAnchor.constraint(equalToConstant: StrokeWidth.hairline),
            ideaTextView.leadingAnchor.constraint(equalTo: ideaRule.trailingAnchor, constant: Spacing.screenEdge),
            ideaTextView.trailingAnchor.constraint(equalTo: ideaSurface.trailingAnchor),
            ideaTextView.topAnchor.constraint(equalTo: ideaSurface.topAnchor),
            ideaTextView.bottomAnchor.constraint(equalTo: ideaSurface.bottomAnchor)
        ])

        imageStack.axis = .horizontal
        imageStack.spacing = Spacing.cozy
        imageStack.distribution = .fillEqually
        let immersiveImageHeightConstraint = imageStack.heightAnchor.constraint(equalToConstant: 148)
        immersiveImageHeightConstraint.priority = .init(999)
        immersiveImageHeightConstraint.isActive = true

        immersiveStack.addArrangedSubview(immersiveTopFlexibleSpacer)
        immersiveStack.addArrangedSubview(quoteDecorationHost)
        immersiveStack.addArrangedSubview(contentTextView)
        immersiveStack.addArrangedSubview(ideaSurface)
        immersiveStack.addArrangedSubview(imageStack)
        immersiveStack.addArrangedSubview(tagsLabel)
        immersiveStack.addArrangedSubview(sourceAttributionHost)
        immersiveStack.addArrangedSubview(immersiveBottomFlexibleSpacer)
        [immersiveTopFlexibleSpacer, immersiveBottomFlexibleSpacer].forEach { spacer in
            spacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
            spacer.setContentHuggingPriority(.init(1), for: .vertical)
            spacer.setContentCompressionResistancePriority(.init(1), for: .vertical)
            spacer.isUserInteractionEnabled = false
        }
        immersiveTopFlexibleSpacer.heightAnchor.constraint(
            equalTo: immersiveBottomFlexibleSpacer.heightAnchor
        ).isActive = true
        sourceAttributionHost.setContentHuggingPriority(.required, for: .vertical)
        sourceAttributionHost.setContentCompressionResistancePriority(.required, for: .vertical)

        paperStack.axis = .vertical
        paperStack.spacing = Spacing.none
        paperStack.alignment = .fill
        paperStack.translatesAutoresizingMaskIntoConstraints = false
        paperContainer.addSubview(paperStack)

        paperPreviewStack.axis = .vertical
        paperPreviewStack.spacing = Spacing.base
        paperPreviewStack.alignment = .fill
        paperPreviewStack.addArrangedSubview(paperBodyLabel)
        paperPreviewStack.addArrangedSubview(paperIdeaLabel)

        paperFooterStack.axis = .vertical
        paperFooterStack.spacing = Layout.paperFooterSpacing
        paperFooterStack.alignment = .fill
        paperFooterStack.addArrangedSubview(paperBookLabel)
        paperFooterStack.addArrangedSubview(paperChapterLabel)

        paperFlexibleSpacer.heightAnchor.constraint(greaterThanOrEqualToConstant: 0).isActive = true
        paperFlexibleSpacer.setContentHuggingPriority(.init(1), for: .vertical)
        paperFlexibleSpacer.setContentCompressionResistancePriority(.init(1), for: .vertical)
        paperFlexibleSpacer.isUserInteractionEnabled = false
        paperStack.addArrangedSubview(paperPreviewStack)
        paperStack.addArrangedSubview(paperFlexibleSpacer)
        paperStack.addArrangedSubview(paperFooterStack)
        paperStack.setCustomSpacing(Spacing.none, after: paperPreviewStack)
        paperStack.setCustomSpacing(Spacing.base, after: paperFlexibleSpacer)

        let readableWidth = immersiveStack.widthAnchor.constraint(
            lessThanOrEqualToConstant: Layout.maxReadableWidth
        )
        readableWidth.priority = .required
        immersiveTopConstraint = immersiveStack.topAnchor.constraint(
            equalTo: immersiveScrollView.contentLayoutGuide.topAnchor,
            constant: Layout.immersiveTopChromeClearance
        )
        immersiveBottomConstraint = immersiveStack.bottomAnchor.constraint(
            equalTo: immersiveScrollView.contentLayoutGuide.bottomAnchor,
            constant: -Layout.immersiveBottomChromeClearance
        )
        NSLayoutConstraint.activate([
            immersiveContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            immersiveContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            immersiveContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
            immersiveContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            immersiveScrollView.leadingAnchor.constraint(equalTo: immersiveContainer.leadingAnchor),
            immersiveScrollView.trailingAnchor.constraint(equalTo: immersiveContainer.trailingAnchor),
            immersiveScrollView.topAnchor.constraint(equalTo: immersiveContainer.topAnchor),
            immersiveScrollView.bottomAnchor.constraint(equalTo: immersiveContainer.bottomAnchor),
            immersiveScrollView.contentLayoutGuide.widthAnchor.constraint(
                equalTo: immersiveScrollView.frameLayoutGuide.widthAnchor
            ),
            immersiveScrollView.contentLayoutGuide.heightAnchor.constraint(
                greaterThanOrEqualTo: immersiveScrollView.frameLayoutGuide.heightAnchor
            ),
            immersiveStack.centerXAnchor.constraint(equalTo: immersiveScrollView.contentLayoutGuide.centerXAnchor),
            immersiveStack.leadingAnchor.constraint(
                greaterThanOrEqualTo: immersiveScrollView.contentLayoutGuide.leadingAnchor,
                constant: Spacing.double
            ),
            immersiveStack.trailingAnchor.constraint(
                lessThanOrEqualTo: immersiveScrollView.contentLayoutGuide.trailingAnchor,
                constant: -Spacing.double
            ),
            immersiveTopConstraint!,
            immersiveBottomConstraint!,
            readableWidth,

            paperView.leadingAnchor.constraint(
                equalTo: contentView.leadingAnchor,
                constant: Layout.paperBleed
            ),
            paperView.trailingAnchor.constraint(
                equalTo: contentView.trailingAnchor,
                constant: -Layout.paperBleed
            ),
            paperView.topAnchor.constraint(
                equalTo: contentView.topAnchor,
                constant: Layout.paperBleed
            ),
            paperView.bottomAnchor.constraint(
                equalTo: contentView.bottomAnchor,
                constant: -Layout.paperBleed
            ),

            paperSurfaceHost.leadingAnchor.constraint(equalTo: paperView.leadingAnchor),
            paperSurfaceHost.trailingAnchor.constraint(equalTo: paperView.trailingAnchor),
            paperSurfaceHost.topAnchor.constraint(equalTo: paperView.topAnchor),
            paperSurfaceHost.bottomAnchor.constraint(equalTo: paperView.bottomAnchor),

            paperContainer.leadingAnchor.constraint(equalTo: paperView.leadingAnchor),
            paperContainer.trailingAnchor.constraint(equalTo: paperView.trailingAnchor),
            paperContainer.topAnchor.constraint(equalTo: paperView.topAnchor),
            paperContainer.bottomAnchor.constraint(equalTo: paperView.bottomAnchor),
            paperStack.leadingAnchor.constraint(
                equalTo: paperContainer.leadingAnchor,
                constant: Spacing.contentEdge
            ),
            paperStack.trailingAnchor.constraint(
                equalTo: paperContainer.trailingAnchor,
                constant: -Spacing.contentEdge
            ),
            paperStack.topAnchor.constraint(
                equalTo: paperContainer.topAnchor,
                constant: Spacing.contentEdge
            ),
            paperStack.bottomAnchor.constraint(
                equalTo: paperContainer.bottomAnchor,
                constant: -Spacing.contentEdge
            ),

            paperPlaceholderView.leadingAnchor.constraint(equalTo: paperView.leadingAnchor),
            paperPlaceholderView.trailingAnchor.constraint(equalTo: paperView.trailingAnchor),
            paperPlaceholderView.topAnchor.constraint(equalTo: paperView.topAnchor),
            paperPlaceholderView.bottomAnchor.constraint(equalTo: paperView.bottomAnchor),

            immersivePlaceholderView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            immersivePlaceholderView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            immersivePlaceholderView.topAnchor.constraint(equalTo: contentView.topAnchor),
            immersivePlaceholderView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }

    func applyDesignTokens() {
        contentView.backgroundColor = .clear
        contentView.layer.masksToBounds = false
        paperView.layer.masksToBounds = false
        paperView.layer.cornerRadius = CornerRadius.blockLarge
        paperView.layer.cornerCurve = .continuous
        paperView.layer.borderWidth = StrokeWidth.hairline
        paperSurfaceHost.layer.cornerRadius = CornerRadius.blockLarge
        paperSurfaceHost.layer.cornerCurve = .continuous
        paperSurfaceHost.clipsToBounds = true
        paperContainer.backgroundColor = .clear
        paperContainer.clipsToBounds = true
        paperContainer.accessibilityElementsHidden = true
        paperPlaceholderView.mode = .desktop
        immersivePlaceholderView.mode = .immersive

        quoteDecorationImageView.tintColor = NoteReviewCanvasAppearance.decoration
        quoteDecorationImageView.alpha = 1
        ideaSurface.backgroundColor = .clear
        ideaRule.backgroundColor = .separator

        tagsLabel.font = ReadingContentTypography.uiMetadataMedium
        tagsLabel.textColor = .secondaryLabel
        tagsLabel.numberOfLines = 0
        tagsLabel.lineBreakMode = .byWordWrapping
        tagsLabel.adjustsFontForContentSizeCategory = true
        tagsLabel.isAccessibilityElement = true
        tagsLabel.setContentCompressionResistancePriority(.required, for: .vertical)

        [paperBodyLabel, paperIdeaLabel].forEach { label in
            label.numberOfLines = 2
            label.lineBreakMode = .byTruncatingTail
            label.adjustsFontForContentSizeCategory = true
            label.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        }
        paperBodyLabel.font = ReadingContentTypography.uiBody
        paperIdeaLabel.font = ReadingContentTypography.uiAnnotation

        paperBookLabel.font = ReadingContentTypography.uiAnnotationSemibold
        paperChapterLabel.font = ReadingContentTypography.uiMetadata
        [paperBookLabel, paperChapterLabel].forEach { label in
            label.numberOfLines = 2
            label.lineBreakMode = .byTruncatingTail
            label.adjustsFontForContentSizeCategory = true
            label.setContentCompressionResistancePriority(.required, for: .vertical)
        }

        paperBodyFadeLayer.colors = [
            UIColor.black.cgColor,
            UIColor.black.cgColor,
            UIColor.clear.cgColor
        ]
        paperBodyFadeLayer.locations = [0, 0.68, 1]
        paperBodyFadeLayer.startPoint = CGPoint(x: 0.5, y: 0)
        paperBodyFadeLayer.endPoint = CGPoint(x: 0.5, y: 1)
    }

    func configureImmersive(item: NoteReviewCardItem, settings: NoteReviewSettings) {
        contentView.backgroundColor = UIColor.clear
        contentView.layer.cornerRadius = 0
        contentView.layer.shadowOpacity = 0
        let display = settings.immersiveDisplay
        let bodyFont = settings.fontSelection.uiFont(base: ReadingContentTypography.uiBody)
        let annotationFont = settings.fontSelection.uiFont(base: ReadingContentTypography.uiAnnotation)
        let appearance = settings.cardAppearance
        let bodyColor = appearance.immersiveBodyTextColor
        let secondaryColor = appearance.immersiveSupplementTextColor
        let contentPlainText = RichTextPlainTextExtractor.plainText(from: item.contentHTML)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        quoteDecorationHost.isHidden = contentPlainText.isEmpty

        contentTextView.update(
            html: item.contentHTML,
            baseFont: bodyFont,
            textColor: bodyColor,
            lineSpacing: ReadingContentTypography.bodyLineSpacing,
            alignment: settings.textAlignment.nsTextAlignment
        )

        ideaSurface.isHidden = !display.showsIdea || item.ideaHTML.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if !ideaSurface.isHidden {
            let ideaPlainText = RichTextPlainTextExtractor.plainText(from: item.ideaHTML)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            ideaTextView.update(
                html: item.ideaHTML,
                baseFont: annotationFont,
                textColor: secondaryColor,
                lineSpacing: ReadingContentTypography.annotationLineSpacing,
                alignment: settings.textAlignment.nsTextAlignment
            )
            ideaTextView.accessibilityLabel = ideaPlainText.isEmpty
                ? "个人想法"
                : "个人想法，\(ideaPlainText)"
        } else {
            ideaTextView.accessibilityLabel = nil
        }

        configureImages(item: item, isVisible: display.showsImages)
        configureTags(item.tags, isVisible: display.showsTags)
        configureSourceAttribution(
            item: item,
            display: display,
            titleFont: Font(annotationFont as CTFont),
            appearance: appearance
        )
        updateSemanticProximity()
    }

    /// 同组内容使用紧密节奏，书籍出处与最后一项内容用更大留白分层。
    func updateSemanticProximity() {
        immersiveStack.setCustomSpacing(Spacing.half, after: quoteDecorationHost)
        immersiveStack.setCustomSpacing(Spacing.section, after: contentTextView)
        immersiveStack.setCustomSpacing(Spacing.base, after: ideaSurface)
        immersiveStack.setCustomSpacing(Spacing.base, after: imageStack)

        let lastContentView = [tagsLabel, imageStack, ideaSurface, contentTextView]
            .first(where: { !$0.isHidden })
        if !sourceAttributionHost.isHidden, let lastContentView {
            immersiveStack.setCustomSpacing(Layout.sourceSeparation, after: lastContentView)
        }
    }

    /// 将书名与章节合并为居中出处，不重复展示封面、作者、日期或位置元数据。
    func configureSourceAttribution(
        item: NoteReviewCardItem,
        display: NoteReviewImmersiveDisplaySettings,
        titleFont: Font,
        appearance: NoteReviewCardAppearance
    ) {
        let title = display.showsBookInfo
            ? Self.normalizedBookTitle(item.bookTitle)
            : ""
        let chapter = display.showsChapter
            ? item.chapterTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            : ""
        sourceAttributionHost.isHidden = title.isEmpty && chapter.isEmpty
        sourceAttributionHost.subviews.forEach { $0.removeFromSuperview() }
        guard !sourceAttributionHost.isHidden else { return }

        let configuration = UIHostingConfiguration {
            NoteReviewSourceAttributionView(
                title: title,
                chapter: chapter,
                titleFont: titleFont,
                sourceColor: appearance.immersiveSourceColor,
                chapterColor: appearance.immersiveChapterColor
            )
        }
        .margins(.all, Spacing.none)
        .background(Color.clear)
        let hostedView = configuration.makeContentView()
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        sourceAttributionHost.addSubview(hostedView)
        NSLayoutConstraint.activate([
            hostedView.leadingAnchor.constraint(equalTo: sourceAttributionHost.leadingAnchor),
            hostedView.trailingAnchor.constraint(equalTo: sourceAttributionHost.trailingAnchor),
            hostedView.topAnchor.constraint(equalTo: sourceAttributionHost.topAnchor),
            hostedView.bottomAnchor.constraint(equalTo: sourceAttributionHost.bottomAnchor)
        ])
    }

    /// 将完整模型压缩为桌面与瀑布流共用的纸张预览，缩放只由外层几何变换负责。
    func configureOverview(
        snapshot: NoteReviewOverviewSnapshot,
        measurement: NoteReviewOverviewMeasurement,
        settings: NoteReviewSettings,
        paperWidth: CGFloat,
        isProvisional: Bool = false
    ) {
        paperShadowOpacity = Layout.paperShadowOpacity
        let appearance = settings.cardAppearance
        let fonts = Self.overviewFonts(settings: settings, traitCollection: traitCollection)
        let textWidth = max(1, paperWidth - Spacing.contentEdge * 2)
        let previewAlignment: NSTextAlignment = mode == .waterfall
            && paperWidth < NoteReviewOverviewMetrics.waterfallMinimumRegularColumnWidth
            && settings.textAlignment == .justified
            ? .natural
            : settings.textAlignment.nsTextAlignment

        paperBodyLabel.font = fonts.body
        paperIdeaLabel.font = fonts.idea
        paperBookLabel.font = fonts.book
        paperChapterLabel.font = fonts.chapter
        [paperBodyLabel, paperIdeaLabel, paperBookLabel, paperChapterLabel].forEach {
            $0.preferredMaxLayoutWidth = textWidth
        }

        paperBodyLabel.attributedText = Self.paperAttributedText(
            snapshot.body,
            font: fonts.body,
            color: appearance.bodyTextColor,
            lineSpacing: ReadingContentTypography.bodyLineSpacing,
            alignment: previewAlignment
        )
        paperBodyLabel.isHidden = snapshot.body.isEmpty

        paperIdeaLabel.attributedText = Self.paperAttributedText(
            snapshot.idea,
            font: fonts.idea,
            color: appearance.supplementTextColor,
            lineSpacing: ReadingContentTypography.annotationLineSpacing,
            alignment: previewAlignment
        )
        paperIdeaLabel.isHidden = snapshot.idea.isEmpty

        paperBookLabel.text = snapshot.bookTitle
        paperBookLabel.isHidden = snapshot.bookTitle == nil
        paperBookLabel.textAlignment = settings.textAlignment.auxiliaryNSTextAlignment
        paperChapterLabel.text = snapshot.chapter
        paperChapterLabel.isHidden = snapshot.chapter == nil
        paperChapterLabel.textAlignment = settings.textAlignment.auxiliaryNSTextAlignment
        paperPreviewStack.isHidden = snapshot.body.isEmpty && snapshot.idea.isEmpty
        paperFooterStack.isHidden = snapshot.bookTitle == nil && snapshot.chapter == nil
        paperBookLabel.textColor = appearance.sourceTextColor
        paperChapterLabel.textColor = appearance.metadataTextColor
        configurePaperSurface(appearance: appearance)
        configureOverviewAccessibility(snapshot: snapshot)
        applyOverviewMeasurement(
            measurement,
            snapshot: snapshot,
            isProvisional: isProvisional
        )
    }

    /// 精确高度回传时只更新行数与渐隐，不重建文字、约束或纸面表层。
    func applyOverviewMeasurement(
        _ measurement: NoteReviewOverviewMeasurement,
        snapshot: NoteReviewOverviewSnapshot,
        isProvisional: Bool
    ) {
        paperBodyLabel.numberOfLines = snapshot.body.isEmpty ? 0 : measurement.bodyLineCount
        paperIdeaLabel.numberOfLines = snapshot.idea.isEmpty ? 0 : measurement.ideaLineCount
        paperBookLabel.numberOfLines = isProvisional ? 1 : 2
        paperChapterLabel.numberOfLines = isProvisional ? 1 : 2
        isPaperBodyTruncated = measurement.isBodyTruncated
        updatePaperBodyFadeMask()
    }

    func configureImages(item: NoteReviewCardItem, isVisible: Bool) {
        imageViews.forEach { $0.cancel() }
        imageViews.removeAll()
        imageStack.arrangedSubviews.forEach { view in
            imageStack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        imageStack.isHidden = !isVisible || item.imageURLs.isEmpty
        guard !imageStack.isHidden else { return }
        for (index, rawURL) in item.imageURLs.prefix(3).enumerated() {
            let imageView = NoteReviewRemoteImageView()
            imageView.layer.cornerRadius = 12
            imageView.layer.cornerCurve = .continuous
            imageView.clipsToBounds = true
            imageView.tag = index
            imageView.isUserInteractionEnabled = true
            imageView.addGestureRecognizer(UITapGestureRecognizer(target: self, action: #selector(handleImageTap(_:))))
            imageView.load(rawURL: rawURL, targetSize: CGSize(width: 240, height: 148), priority: .normal)
            imageView.accessibilityLabel = "查看第 \(index + 1) 张书摘图片"
            imageStack.addArrangedSubview(imageView)
            imageViews.append(imageView)
        }
    }

    /// 使用仅靠井号与留白构成的页面私有标签表达，避免胶囊、品牌色和符号分隔抢占阅读焦点。
    func configureTags(_ tags: [NoteEditorTagOption], isVisible: Bool) {
        let normalizedTitles = tags.compactMap { Self.normalizedTagTitle($0.title) }
        tagsLabel.isHidden = !isVisible || normalizedTitles.isEmpty
        guard !tagsLabel.isHidden else {
            tagsLabel.attributedText = nil
            tagsLabel.accessibilityLabel = nil
            return
        }

        let hashtags = normalizedTitles.map { "#\($0)" }.joined(separator: "   ")
        tagsLabel.attributedText = NSAttributedString(
            string: hashtags,
            attributes: [
                .font: ReadingContentTypography.uiMetadataMedium,
                .foregroundColor: UIColor.secondaryLabel
            ]
        )
        tagsLabel.accessibilityLabel = "标签：\(normalizedTitles.joined(separator: "、"))"
    }

    /// 复用同一个 UIKit 表层并只更新动态颜色；概览不为每次配置销毁、重建 Hosted View。
    func configurePaperSurface(appearance: NoteReviewCardAppearance) {
        paperView.backgroundColor = .clear
        paperSurfaceHost.backgroundColor = appearance.uiSurface
        paperBorderColor = appearance.uiOnSurface
            .resolvedColor(with: traitCollection)
            .withAlphaComponent(0.16)
            .cgColor
        paperSelectedBorderColor = appearance.uiOnSurface
            .resolvedColor(with: traitCollection)
            .withAlphaComponent(0.34)
            .cgColor
        paperView.layer.shadowColor = UIColor.black.cgColor
        updatePaperEmphasis()
    }

    /// 为尚未载入正文的纸张提供同尺寸中性表面，避免复用期间闪现上一条内容。
    func configurePaperPlaceholderSurface() {
        paperView.backgroundColor = .clear
        paperSurfaceHost.backgroundColor = .secondarySystemGroupedBackground
        paperView.layer.borderColor = UIColor.separator
            .resolvedColor(with: traitCollection)
            .withAlphaComponent(0.72)
            .cgColor
        paperBorderColor = paperView.layer.borderColor
        paperSelectedBorderColor = UIColor.label
            .resolvedColor(with: traitCollection)
            .withAlphaComponent(0.24)
            .cgColor
        paperView.layer.shadowColor = UIColor.black.cgColor
        paperShadowOpacity = Layout.paperPlaceholderShadowOpacity
        updatePaperEmphasis()
    }

    /// 恢复沉浸模式原有的子视图朗读语义，让正文选择和图片操作继续独立可达。
    func configureImmersiveAccessibility() {
        isAccessibilityElement = false
        accessibilityLabel = nil
        accessibilityValue = nil
        accessibilityHint = nil
        accessibilityTraits = []
        immersiveContainer.accessibilityElementsHidden = false
    }

    /// 将桌面或瀑布流纸张合并为一个有序可点击元素，朗读预览后提示进入全文。
    func configureOverviewAccessibility(snapshot: NoteReviewOverviewSnapshot) {
        immersiveContainer.accessibilityElementsHidden = true
        isAccessibilityElement = true
        let title = snapshot.bookTitle?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        accessibilityLabel = title.isEmpty ? "书摘" : "\(title)的书摘"

        var valueParts: [String] = []
        if !snapshot.body.isEmpty {
            valueParts.append("摘录：\(Self.accessibilityPreview(snapshot.body))")
        }
        if !snapshot.idea.isEmpty {
            valueParts.append("想法：\(Self.accessibilityPreview(snapshot.idea))")
        }
        if let bookTitle = snapshot.bookTitle {
            valueParts.append("书名：\(bookTitle)")
        }
        if let chapter = snapshot.chapter {
            valueParts.append("章节：\(chapter)")
        }
        accessibilityValue = valueParts.joined(separator: "。")
        accessibilityHint = "点按进入全文"
        accessibilityTraits = isPaperSelected ? [.button, .selected] : [.button]
    }

    /// 合成稳定旋转与瞬时按压位移，确保两种反馈不会相互覆盖或改变 Cell 外框。
    func applyPaperTransform(animated: Bool, duration: TimeInterval) {
        let translationY = isPaperHighlighted ? Layout.paperHighlightTranslation : 0
        let targetTransform = CGAffineTransform(translationX: 0, y: translationY)
            .rotated(by: paperRotation)
        let changes = { [self] in
            paperView.transform = targetTransform
            updatePaperEmphasis()
        }
        guard animated else {
            UIView.performWithoutAnimation(changes)
            return
        }
        UIView.animate(
            withDuration: duration,
            delay: 0,
            options: [.allowUserInteraction, .beginFromCurrentState, .curveEaseOut],
            animations: changes
        )
    }

    /// 合并当前项与按压反馈；两者共享单层阴影，但保持彼此独立的状态来源。
    func updatePaperEmphasis() {
        let selectedShadowOpacity = min(
            1,
            paperShadowOpacity + (isPaperSelected ? Layout.paperSelectedShadowBoost : 0)
        )
        paperView.layer.shadowOpacity = isPaperHighlighted
            ? max(Layout.paperHighlightedShadowOpacity, selectedShadowOpacity)
            : selectedShadowOpacity
        paperView.layer.shadowRadius = isPaperHighlighted
            ? Layout.paperHighlightedShadowRadius
            : Layout.paperShadowRadius + (isPaperSelected ? 1 : 0)
        paperView.layer.shadowOffset = isPaperHighlighted
            ? Layout.paperHighlightedShadowOffset
            : Layout.paperShadowOffset
        paperView.layer.borderColor = isPaperSelected
            ? paperSelectedBorderColor
            : paperBorderColor
    }

    /// 只在摘录确实被高度上限截断时应用尾部透明遮罩，底部出处不参与渐隐。
    func updatePaperBodyFadeMask() {
        guard isPaperBodyTruncated, paperBodyLabel.bounds.height > 0 else {
            paperBodyLabel.layer.mask = nil
            return
        }
        paperBodyFadeLayer.frame = paperBodyLabel.bounds
        let fadeStart = traitCollection.userInterfaceStyle == .dark
            ? max(0, 1 - 8 / max(1, paperBodyLabel.bounds.height)) : 0.68
        paperBodyFadeLayer.locations = [0, NSNumber(value: Double(fadeStart)), 1]
        paperBodyLabel.layer.mask = paperBodyFadeLayer
    }

    static func normalizedTagTitle(_ title: String) -> String? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutHash = String(trimmed.drop(while: { $0 == "#" }))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return withoutHash.isEmpty ? nil : withoutHash
    }

    nonisolated static func normalizedBookTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        guard !(trimmed.hasPrefix("《") && trimmed.hasSuffix("》")) else { return trimmed }
        let unwrapped = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "《》"))
        return unwrapped.isEmpty ? "" : "《\(unwrapped)》"
    }

    /// 将概览正文压缩为足以覆盖最大纸高的有界字符串，避免 Cell 与远景分块强引用整篇内容。
    nonisolated static func boundedOverviewText(
        _ text: String,
        limit: Int
    ) -> (text: String, isTruncated: Bool) {
        guard limit > 0, !text.isEmpty else { return ("", !text.isEmpty) }
        let candidate = text.prefix(limit + 1)
        let isTruncated = candidate.count > limit
        let prefix = isTruncated ? candidate.prefix(limit) : candidate[...]
        return (String(prefix) + (isTruncated ? "…" : ""), isTruncated)
    }

    /// 汇集概览纸张渲染、高度测量和远景分块共用的动态字体。
    struct OverviewFonts {
        let book: UIFont
        let body: UIFont
        let idea: UIFont
        let chapter: UIFont
    }

    /// 在目标 trait 环境中解析字体，避免离屏测量与最终 Cell 的动态字号不一致。
    static func overviewFonts(
        settings: NoteReviewSettings,
        traitCollection: UITraitCollection
    ) -> OverviewFonts {
        var fonts = OverviewFonts(
            book: settings.fontSelection.uiFont(base: ReadingContentTypography.uiAnnotationSemibold),
            body: settings.fontSelection.uiFont(base: ReadingContentTypography.uiBody),
            idea: settings.fontSelection.uiFont(base: ReadingContentTypography.uiAnnotation),
            chapter: ReadingContentTypography.uiMetadata
        )
        traitCollection.performAsCurrent {
            fonts = OverviewFonts(
                book: settings.fontSelection.uiFont(base: ReadingContentTypography.uiAnnotationSemibold),
                body: settings.fontSelection.uiFont(base: ReadingContentTypography.uiBody),
                idea: settings.fontSelection.uiFont(base: ReadingContentTypography.uiAnnotation),
                chapter: ReadingContentTypography.uiMetadata
            )
        }
        return fonts
    }

    /// 将 UIFont 的已解析度量复制为 Sendable 值，后台不再触碰 trait 或动态字体 API。
    static func measurementFontDescriptor(
        _ font: UIFont
    ) -> NoteReviewOverviewMeasurementDescriptor.Font {
        NoteReviewOverviewMeasurementDescriptor.Font(
            postScriptName: font.fontName,
            pointSize: font.pointSize,
            lineHeight: font.lineHeight
        )
    }

    /// 将 UIKit 对齐语义一次性映射为 Core Text 原始值，分块后台绘制不再捕获 UIKit 枚举。
    static func coreTextAlignment(_ alignment: NSTextAlignment) -> CTTextAlignment {
        switch alignment {
        case .left: .left
        case .center: .center
        case .right: .right
        case .justified: .justified
        case .natural: .natural
        @unknown default: .natural
        }
    }

    /// 真实纯文本已经就绪但精确测高仍在后台时，先以稳定估高展示固定行数预览。
    static func provisionalOverviewMeasurement(
        snapshot: NoteReviewOverviewSnapshot
    ) -> NoteReviewOverviewMeasurement {
        NoteReviewOverviewMeasurement(
            cardHeight: 280,
            bodyLineCount: snapshot.body.isEmpty ? 0 : 3,
            ideaLineCount: snapshot.idea.isEmpty ? 0 : 1,
            isBodyTruncated: snapshot.isBodySourceTruncated || !snapshot.body.isEmpty
        )
    }

    /// 老调用方未显式提供 revision 时使用内容指纹兜底，避免同 ID 编辑后错误复用旧纸面。
    nonisolated static func fallbackContentRevision(item: NoteReviewCardItem) -> Int {
        var hasher = Hasher()
        hasher.combine(item.contentHTML)
        hasher.combine(item.ideaHTML)
        hasher.combine(item.bookTitle)
        hasher.combine(item.chapterTitle)
        hasher.combine(item.imageURLs)
        for tag in item.tags {
            hasher.combine(tag.id)
            hasher.combine(tag.title)
        }
        return hasher.finalize()
    }

    /// 卡宽量化到物理像素，消除缩放回调中的亚像素抖动对配置签名的污染。
    static func widthBucket(for width: CGFloat, traitCollection: UITraitCollection) -> Int {
        let scale = max(1, traitCollection.displayScale)
        return Int((max(0, width) * scale).rounded())
    }

    /// 构造与 UILabel 渲染及离屏测量共用的段落样式。
    static func paperAttributedText(
        _ text: String,
        font: UIFont,
        color: UIColor,
        lineSpacing: CGFloat,
        alignment: NSTextAlignment,
        lineBreakMode: NSLineBreakMode = .byTruncatingTail
    ) -> NSAttributedString {
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.alignment = alignment
        paragraphStyle.lineSpacing = lineSpacing
        paragraphStyle.lineBreakMode = lineBreakMode
        return NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraphStyle
            ]
        )
    }

    /// 计算指定宽度中的文本自然高度，并可限制为固定行数。
    static func measuredTextHeight(
        _ text: String,
        font: UIFont,
        width: CGFloat,
        lineSpacing: CGFloat,
        lineLimit: Int?,
        heightLimit: CGFloat
    ) -> CGFloat {
        guard !text.isEmpty, width > 0, heightLimit > 0 else { return 0 }
        let attributedText = paperAttributedText(
            text,
            font: font,
            color: .label,
            lineSpacing: lineSpacing,
            alignment: .natural,
            lineBreakMode: .byWordWrapping
        )
        let measuredHeight = ceil(
            attributedText.boundingRect(
                with: CGSize(width: width, height: heightLimit),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                context: nil
            ).height
        )
        guard let lineLimit else { return measuredHeight }
        let maximumLineHeight = heightForLines(
            lineLimit,
            font: font,
            lineSpacing: lineSpacing
        )
        return min(measuredHeight, maximumLineHeight)
    }

    /// 在正文和想法之间分配剩余高度，正文优先并为辅助功能字号保留至少两行。
    static func paperTextAllocations(
        bodyNaturalHeight: CGFloat,
        ideaNaturalHeight: CGFloat,
        availableHeight: CGFloat,
        bodyFont: UIFont,
        ideaFont: UIFont,
        usesAccessibilityText: Bool
    ) -> (body: CGFloat, idea: CGFloat) {
        guard bodyNaturalHeight > 0 || ideaNaturalHeight > 0 else { return (0, 0) }
        guard bodyNaturalHeight > 0 else { return (0, min(ideaNaturalHeight, availableHeight)) }
        guard ideaNaturalHeight > 0 else { return (min(bodyNaturalHeight, availableHeight), 0) }
        guard bodyNaturalHeight + ideaNaturalHeight > availableHeight else {
            return (bodyNaturalHeight, ideaNaturalHeight)
        }

        let bodyMinimum = min(
            bodyNaturalHeight,
            heightForLines(
                usesAccessibilityText ? 2 : 1,
                font: bodyFont,
                lineSpacing: ReadingContentTypography.bodyLineSpacing
            )
        )
        let ideaMinimum = min(
            ideaNaturalHeight,
            heightForLines(
                1,
                font: ideaFont,
                lineSpacing: ReadingContentTypography.annotationLineSpacing
            )
        )
        guard bodyMinimum + ideaMinimum <= availableHeight else {
            let bodyHeight = min(bodyMinimum, availableHeight)
            return (bodyHeight, max(0, availableHeight - bodyHeight))
        }

        var bodyHeight = bodyMinimum
        var ideaHeight = ideaMinimum
        var remainingHeight = availableHeight - bodyHeight - ideaHeight
        let initialBodyGrant = min(bodyNaturalHeight - bodyHeight, remainingHeight * 0.65)
        bodyHeight += initialBodyGrant
        remainingHeight -= initialBodyGrant
        let ideaGrant = min(ideaNaturalHeight - ideaHeight, remainingHeight)
        ideaHeight += ideaGrant
        remainingHeight -= ideaGrant
        bodyHeight += min(bodyNaturalHeight - bodyHeight, remainingHeight)
        return (bodyHeight, ideaHeight)
    }

    /// 将已测得的自然高度与分配预算转换为 UILabel 行数，不再次排版正文。
    static func lineCount(
        naturalHeight: CGFloat,
        font: UIFont,
        lineSpacing: CGFloat,
        allocatedHeight: CGFloat
    ) -> Int {
        let lineStride = max(1, font.lineHeight + lineSpacing)
        let naturalLines = max(1, Int(ceil((naturalHeight + lineSpacing) / lineStride)))
        let fittingLines = max(1, Int(floor((allocatedHeight + lineSpacing) / lineStride)))
        return min(naturalLines, fittingLines)
    }

    /// 按字体行高和段落行距计算固定行数占用的高度。
    static func heightForLines(
        _ count: Int,
        font: UIFont,
        lineSpacing: CGFloat
    ) -> CGFloat {
        guard count > 0 else { return 0 }
        return ceil(font.lineHeight * CGFloat(count) + lineSpacing * CGFloat(count - 1))
    }

    /// 使用调用任务独享的 framesetter 测量纯文本，避免在滚动主线程执行 UIKit 富文本排版。
    nonisolated static func coreTextMeasuredHeight(
        _ text: String,
        font: NoteReviewOverviewMeasurementDescriptor.Font,
        width: CGFloat,
        lineSpacing: CGFloat,
        lineLimit: Int?,
        heightLimit: CGFloat
    ) -> CGFloat {
        guard !text.isEmpty, width > 0, heightLimit > 0 else { return 0 }
        let ctFont = CTFontCreateWithName(
            font.postScriptName as CFString,
            max(1, font.pointSize),
            nil
        )
        var spacing = lineSpacing
        let paragraphStyle: CTParagraphStyle = withUnsafePointer(to: &spacing) { pointer in
            var setting = CTParagraphStyleSetting(
                spec: .lineSpacingAdjustment,
                valueSize: MemoryLayout<CGFloat>.size,
                value: pointer
            )
            return CTParagraphStyleCreate(&setting, 1)
        }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(rawValue: kCTFontAttributeName as String): ctFont,
            NSAttributedString.Key(rawValue: kCTParagraphStyleAttributeName as String): paragraphStyle
        ]
        let attributedText = NSAttributedString(string: text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributedText)
        let measured = CTFramesetterSuggestFrameSizeWithConstraints(
            framesetter,
            CFRange(location: 0, length: 0),
            nil,
            CGSize(width: width, height: heightLimit),
            nil
        )
        let measuredHeight = ceil(min(heightLimit, measured.height))
        guard let lineLimit else { return measuredHeight }
        return min(
            measuredHeight,
            heightForLines(lineLimit, font: font, lineSpacing: lineSpacing)
        )
    }

    /// 后台测量版的正文/想法高度分配，与近景 UILabel 规则保持同一优先级。
    nonisolated static func paperTextAllocations(
        bodyNaturalHeight: CGFloat,
        ideaNaturalHeight: CGFloat,
        availableHeight: CGFloat,
        bodyFont: NoteReviewOverviewMeasurementDescriptor.Font,
        ideaFont: NoteReviewOverviewMeasurementDescriptor.Font,
        bodyLineSpacing: CGFloat,
        ideaLineSpacing: CGFloat,
        usesAccessibilityText: Bool
    ) -> (body: CGFloat, idea: CGFloat) {
        guard bodyNaturalHeight > 0 || ideaNaturalHeight > 0 else { return (0, 0) }
        guard bodyNaturalHeight > 0 else { return (0, min(ideaNaturalHeight, availableHeight)) }
        guard ideaNaturalHeight > 0 else { return (min(bodyNaturalHeight, availableHeight), 0) }
        guard bodyNaturalHeight + ideaNaturalHeight > availableHeight else {
            return (bodyNaturalHeight, ideaNaturalHeight)
        }

        let bodyMinimum = min(
            bodyNaturalHeight,
            heightForLines(
                usesAccessibilityText ? 2 : 1,
                font: bodyFont,
                lineSpacing: bodyLineSpacing
            )
        )
        let ideaMinimum = min(
            ideaNaturalHeight,
            heightForLines(1, font: ideaFont, lineSpacing: ideaLineSpacing)
        )
        guard bodyMinimum + ideaMinimum <= availableHeight else {
            let bodyHeight = min(bodyMinimum, availableHeight)
            return (bodyHeight, max(0, availableHeight - bodyHeight))
        }

        var bodyHeight = bodyMinimum
        var ideaHeight = ideaMinimum
        var remainingHeight = availableHeight - bodyHeight - ideaHeight
        let initialBodyGrant = min(bodyNaturalHeight - bodyHeight, remainingHeight * 0.65)
        bodyHeight += initialBodyGrant
        remainingHeight -= initialBodyGrant
        let ideaGrant = min(ideaNaturalHeight - ideaHeight, remainingHeight)
        ideaHeight += ideaGrant
        remainingHeight -= ideaGrant
        bodyHeight += min(bodyNaturalHeight - bodyHeight, remainingHeight)
        return (bodyHeight, ideaHeight)
    }

    /// 将后台测得的自然高度转换为与 UILabel 一致的有界行数。
    nonisolated static func lineCount(
        naturalHeight: CGFloat,
        font: NoteReviewOverviewMeasurementDescriptor.Font,
        lineSpacing: CGFloat,
        allocatedHeight: CGFloat
    ) -> Int {
        let lineStride = max(1, font.lineHeight + lineSpacing)
        let naturalLines = max(1, Int(ceil((naturalHeight + lineSpacing) / lineStride)))
        let fittingLines = max(1, Int(floor((allocatedHeight + lineSpacing) / lineStride)))
        return min(naturalLines, fittingLines)
    }

    /// 按已解析字体行高计算后台固定行数高度，不访问 UIKit 对象。
    nonisolated static func heightForLines(
        _ count: Int,
        font: NoteReviewOverviewMeasurementDescriptor.Font,
        lineSpacing: CGFloat
    ) -> CGFloat {
        guard count > 0 else { return 0 }
        return ceil(font.lineHeight * CGFloat(count) + lineSpacing * CGFloat(count - 1))
    }

    /// 压缩空白并限制 VoiceOver 预览长度，完整内容仍通过点按进入沉浸阅读。
    static func accessibilityPreview(_ text: String, limit: Int = 220) -> String {
        let normalized = text
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard normalized.count > limit else { return normalized }
        return String(normalized.prefix(limit)) + "……"
    }

    @objc func handleImageTap(_ recognizer: UITapGestureRecognizer) {
        guard let representedItem, let index = recognizer.view?.tag else { return }
        onOpenImages?(representedItem, index)
    }

    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()
}

/// 在后台把一个逻辑分块的纸面、阴影与已准备正文压成同一张有界位图。
nonisolated enum NoteReviewDesktopTileRasterizer {
    static func makeRaster(
        geometries: [NoteReviewDesktopPaperGeometry],
        drawingRect: CGRect,
        contentsScale: CGFloat,
        style: NoteReviewDesktopRasterStyle,
        items: [NoteReviewDesktopTileItem] = []
    ) -> NoteReviewDesktopTileRaster? {
        guard drawingRect.width > 0,
              drawingRect.height > 0,
              contentsScale.isFinite,
              contentsScale > 0 else { return nil }
        let pixelWidth = max(1, Int(ceil(drawingRect.width * contentsScale)))
        let pixelHeight = max(1, Int(ceil(drawingRect.height * contentsScale)))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: pixelWidth,
            height: pixelHeight,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                | CGBitmapInfo.byteOrder32Big.rawValue
        ) else { return nil }
        let surfaceColor = style.surfaceColor.cgColor(in: colorSpace)
        let borderColor = style.borderColor.cgColor(in: colorSpace)
        let shadowColor = style.shadowColor.cgColor(in: colorSpace)
        var itemByID: [Int64: NoteReviewDesktopTileItem] = [:]
        itemByID.reserveCapacity(items.count)
        for item in items {
            itemByID[item.noteID] = item
        }
        context.setAllowsAntialiasing(true)
        context.setShouldAntialias(true)
        context.interpolationQuality = .high
        context.translateBy(x: 0, y: CGFloat(pixelHeight))
        context.scaleBy(x: contentsScale, y: -contentsScale)
        context.translateBy(x: -drawingRect.minX, y: -drawingRect.minY)
        for (offset, geometry) in geometries.enumerated() {
            if offset.isMultiple(of: 64), Task.isCancelled { return nil }
            drawPaper(
                geometry,
                in: context,
                contentsScale: contentsScale,
                style: style,
                surfaceColor: surfaceColor,
                borderColor: borderColor,
                shadowColor: shadowColor,
                item: itemByID[geometry.noteID],
                colorSpace: colorSpace
            )
        }
        guard !Task.isCancelled, let image = context.makeImage() else { return nil }
        return NoteReviewDesktopTileRaster(
            image: image,
            contentsScale: contentsScale,
            includesContent: !items.isEmpty
        )
    }

    private static func drawPaper(
        _ geometry: NoteReviewDesktopPaperGeometry,
        in context: CGContext,
        contentsScale: CGFloat,
        style: NoteReviewDesktopRasterStyle,
        surfaceColor: CGColor,
        borderColor: CGColor,
        shadowColor: CGColor,
        item: NoteReviewDesktopTileItem?,
        colorSpace: CGColorSpace
    ) {
        context.saveGState()
        context.translateBy(x: geometry.logicalFrame.midX, y: geometry.logicalFrame.midY)
        context.rotate(by: geometry.rotationAngle)
        context.translateBy(x: -geometry.logicalFrame.midX, y: -geometry.logicalFrame.midY)
        let path = CGPath(
            roundedRect: geometry.logicalFrame,
            cornerWidth: style.cornerRadius,
            cornerHeight: style.cornerRadius,
            transform: nil
        )
        // 原生 bitmap context 的正 y 阴影朝上，且 shadow 使用 base-space；换算后保持纸张下投影的点值语义。
        context.setShadow(
            offset: CGSize(
                width: style.shadowOffset.width * contentsScale,
                height: -style.shadowOffset.height * contentsScale
            ),
            blur: style.shadowRadius * contentsScale,
            color: shadowColor
        )
        context.addPath(path)
        context.setFillColor(surfaceColor)
        context.fillPath()
        context.setShadow(offset: .zero, blur: 0, color: nil)
        context.addPath(path)
        let resolvedBorderColor = item?.isSelected == true
            ? style.bodyTextColor.withAlphaComponent(0.34).cgColor(in: colorSpace)
            : borderColor
        context.setStrokeColor(resolvedBorderColor)
        context.setLineWidth(style.borderWidth)
        context.strokePath()
        context.addPath(path)
        context.clip()
        if let item, item.isLoaded {
            drawLoadedContent(item, in: context, style: style, colorSpace: colorSpace)
        }
        context.restoreGState()
    }

    /// 使用与近景相同的内容层级在后台绘制正文、想法、书名和章节，避免主线程文字 overlay。
    private static func drawLoadedContent(
        _ item: NoteReviewDesktopTileItem,
        in context: CGContext,
        style: NoteReviewDesktopRasterStyle,
        colorSpace: CGColorSpace
    ) {
        let contentRect = item.frame.insetBy(dx: style.contentInset, dy: style.contentInset)
        guard contentRect.width > 0, contentRect.height > 0 else { return }
        var footerTop = contentRect.maxY

        if let chapter = normalized(item.chapter) {
            let height = textHeight(
                chapter,
                font: style.chapterFont,
                width: contentRect.width,
                lineSpacing: 0,
                maximumLines: 2
            )
            footerTop -= height
            drawText(
                chapter,
                in: CGRect(x: contentRect.minX, y: footerTop, width: contentRect.width, height: height),
                font: style.chapterFont,
                color: style.metadataTextColor.cgColor(in: colorSpace),
                lineSpacing: 0,
                alignment: style.auxiliaryAlignment,
                context: context
            )
        }
        if let bookTitle = normalized(item.bookTitle) {
            if footerTop < contentRect.maxY { footerTop -= style.footerSpacing }
            let height = textHeight(
                bookTitle,
                font: style.bookFont,
                width: contentRect.width,
                lineSpacing: 0,
                maximumLines: 2
            )
            footerTop -= height
            drawText(
                bookTitle,
                in: CGRect(x: contentRect.minX, y: footerTop, width: contentRect.width, height: height),
                font: style.bookFont,
                color: style.sourceTextColor.cgColor(in: colorSpace),
                lineSpacing: 0,
                alignment: style.auxiliaryAlignment,
                context: context
            )
        }

        let previewBottom = footerTop < contentRect.maxY
            ? footerTop - style.blockSpacing
            : contentRect.maxY
        var previewY = contentRect.minY
        if let body = normalized(item.body), item.bodyLineCount > 0 {
            let bodyHeight = min(
                heightForLines(
                    item.bodyLineCount,
                    font: style.bodyFont,
                    lineSpacing: style.bodyLineSpacing
                ),
                max(0, previewBottom - previewY)
            )
            let bodyRect = CGRect(
                x: contentRect.minX,
                y: previewY,
                width: contentRect.width,
                height: bodyHeight
            )
            drawText(
                body,
                in: bodyRect,
                font: style.bodyFont,
                color: style.bodyTextColor.cgColor(in: colorSpace),
                lineSpacing: style.bodyLineSpacing,
                alignment: style.bodyAlignment,
                context: context
            )
            if item.isBodyTruncated {
                drawFade(
                    in: bodyRect,
                    surfaceColor: style.surfaceColor.cgColor(in: colorSpace),
                    isDarkAppearance: style.isDarkAppearance,
                    context: context
                )
            }
            previewY = bodyRect.maxY
        }
        if let idea = normalized(item.idea), item.ideaLineCount > 0 {
            if previewY > contentRect.minY { previewY += style.blockSpacing }
            let ideaHeight = min(
                heightForLines(
                    item.ideaLineCount,
                    font: style.ideaFont,
                    lineSpacing: style.ideaLineSpacing
                ),
                max(0, previewBottom - previewY)
            )
            drawText(
                idea,
                in: CGRect(
                    x: contentRect.minX,
                    y: previewY,
                    width: contentRect.width,
                    height: ideaHeight
                ),
                font: style.ideaFont,
                color: style.supplementTextColor.cgColor(in: colorSpace),
                lineSpacing: style.ideaLineSpacing,
                alignment: style.bodyAlignment,
                context: context
            )
        }
    }

    /// 在 UIKit 坐标系的逻辑矩形中用 Core Text 绘制文本，并局部恢复 Core Text 的纵轴方向。
    private static func drawText(
        _ text: String,
        in rect: CGRect,
        font: NoteReviewOverviewMeasurementDescriptor.Font,
        color: CGColor,
        lineSpacing: CGFloat,
        alignment: UInt8,
        context: CGContext
    ) {
        guard rect.width > 0, rect.height > 0 else { return }
        let ctFont = CTFontCreateWithName(font.postScriptName as CFString, font.pointSize, nil)
        let paragraphStyle = makeParagraphStyle(alignment: alignment, lineSpacing: lineSpacing)
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(rawValue: kCTFontAttributeName as String): ctFont,
            NSAttributedString.Key(rawValue: kCTParagraphStyleAttributeName as String): paragraphStyle,
            NSAttributedString.Key(rawValue: kCTForegroundColorAttributeName as String): color
        ]
        let attributedText = NSAttributedString(string: text, attributes: attributes)
        let framesetter = CTFramesetterCreateWithAttributedString(attributedText)
        let path = CGPath(rect: CGRect(origin: .zero, size: rect.size), transform: nil)
        let frame = CTFramesetterCreateFrame(
            framesetter,
            CFRange(location: 0, length: 0),
            path,
            nil
        )
        context.saveGState()
        context.translateBy(x: rect.minX, y: rect.maxY)
        context.scaleBy(x: 1, y: -1)
        CTFrameDraw(frame, context)
        context.restoreGState()
    }

    /// 测量远景页脚文本的有界高度，确保其行数与近景纸面一致。
    private static func textHeight(
        _ text: String,
        font: NoteReviewOverviewMeasurementDescriptor.Font,
        width: CGFloat,
        lineSpacing: CGFloat,
        maximumLines: Int
    ) -> CGFloat {
        let measured = NoteReviewCollectionCell.coreTextMeasuredHeight(
            text,
            font: font,
            width: width,
            lineSpacing: lineSpacing,
            lineLimit: maximumLines,
            heightLimit: CGFloat.greatestFiniteMagnitude
        )
        return min(
            measured,
            heightForLines(maximumLines, font: font, lineSpacing: lineSpacing)
        )
    }

    /// 以不可变字体描述计算远景固定行数高度。
    private static func heightForLines(
        _ count: Int,
        font: NoteReviewOverviewMeasurementDescriptor.Font,
        lineSpacing: CGFloat
    ) -> CGFloat {
        guard count > 0 else { return 0 }
        return ceil(font.lineHeight * CGFloat(count) + lineSpacing * CGFloat(count - 1))
    }

    /// 为一次后台绘制创建独立段落样式，不在线程之间共享可变排版对象。
    private static func makeParagraphStyle(
        alignment rawAlignment: UInt8,
        lineSpacing: CGFloat
    ) -> CTParagraphStyle {
        var alignment = CTTextAlignment(rawValue: rawAlignment) ?? .natural
        var spacing = lineSpacing
        return withUnsafePointer(to: &alignment) { alignmentPointer in
            withUnsafePointer(to: &spacing) { spacingPointer in
                var settings = [
                    CTParagraphStyleSetting(
                        spec: .alignment,
                        valueSize: MemoryLayout<CTTextAlignment>.size,
                        value: alignmentPointer
                    ),
                    CTParagraphStyleSetting(
                        spec: .lineSpacingAdjustment,
                        valueSize: MemoryLayout<CGFloat>.size,
                        value: spacingPointer
                    )
                ]
                return CTParagraphStyleCreate(&settings, settings.count)
            }
        }
    }

    /// 在被截断正文尾部绘制纸面色渐隐，提示完整内容可在单条模式阅读。
    private static func drawFade(
        in rect: CGRect,
        surfaceColor: CGColor,
        isDarkAppearance: Bool,
        context: CGContext
    ) {
        let fadeHeight = isDarkAppearance ? min(8, rect.height) : rect.height * 0.32
        let fadeRect = CGRect(
            x: rect.minX,
            y: rect.maxY - fadeHeight,
            width: rect.width,
            height: fadeHeight
        )
        guard fadeRect.height > 0,
              let transparent = surfaceColor.copy(alpha: 0),
              let gradient = CGGradient(
                colorsSpace: surfaceColor.colorSpace,
                colors: [transparent, surfaceColor] as CFArray,
                locations: [0, 1]
              ) else { return }
        context.saveGState()
        context.clip(to: fadeRect)
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: fadeRect.midX, y: fadeRect.minY),
            end: CGPoint(x: fadeRect.midX, y: fadeRect.maxY),
            options: []
        )
        context.restoreGState()
    }

    /// 过滤空白文本，避免为无内容块预留远景空间。
    private static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 远景桌面的可复用分块绘制器；新管线直接显示后台完整位图，旧调用仍可短期回退覆盖层。
@MainActor
final class NoteReviewDesktopTileView: UIView {
    static let reuseIdentifier = "NoteReviewDesktopTileView"

    private let baseRasterLayer = CALayer()
    private let overlayView = NoteReviewDesktopTileOverlayView()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        backgroundColor = .clear
        isUserInteractionEnabled = false
        accessibilityElementsHidden = true
        contentMode = .redraw
        layer.drawsAsynchronously = true
        baseRasterLayer.contentsGravity = .resize
        baseRasterLayer.magnificationFilter = .linear
        baseRasterLayer.minificationFilter = .linear
        layer.addSublayer(baseRasterLayer)
        overlayView.isOpaque = false
        overlayView.backgroundColor = .clear
        overlayView.isUserInteractionEnabled = false
        addSubview(overlayView)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        baseRasterLayer.frame = bounds
        overlayView.frame = bounds
    }

    /// 原子提交后台位图；若位图已包含正文则关闭主线程覆盖层，避免缩放时重复绘制文字。
    func configure(
        raster: NoteReviewDesktopTileRaster,
        items: [NoteReviewDesktopTileItem],
        style: NoteReviewDesktopTileStyle,
        tileRect: CGRect
    ) {
        baseRasterLayer.contents = raster.image
        baseRasterLayer.contentsScale = raster.contentsScale
        if raster.includesContent {
            overlayView.prepareForReuse()
        } else {
            overlayView.configure(
                items: items,
                style: style,
                tileRect: tileRect,
                contentsScale: raster.contentsScale
            )
        }
    }

    /// 清除上一分块的强引用，使控制器维护的有界池可以立即复用。
    func prepareForReuse() {
        baseRasterLayer.contents = nil
        overlayView.prepareForReuse()
    }
}

/// 每块只绘制当前、可见与预测范围内的正文覆盖项，数量与筛选总数无关。
@MainActor
private final class NoteReviewDesktopTileOverlayView: UIView {
    private var items: [NoteReviewDesktopTileItem] = []
    private var style: NoteReviewDesktopTileStyle?
    private var tileRect: CGRect = .zero

    func configure(
        items: [NoteReviewDesktopTileItem],
        style: NoteReviewDesktopTileStyle,
        tileRect: CGRect,
        contentsScale: CGFloat
    ) {
        self.items = items
        self.style = style
        self.tileRect = tileRect
        contentScaleFactor = max(0.001, contentsScale)
        layer.contentsScale = contentScaleFactor
        isHidden = items.isEmpty
        if items.isEmpty {
            layer.contents = nil
        } else {
            setNeedsDisplay()
        }
    }

    func prepareForReuse() {
        items.removeAll(keepingCapacity: false)
        style = nil
        tileRect = .zero
        isHidden = true
        layer.contents = nil
    }

    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(),
              let style,
              !items.isEmpty else { return }
        context.saveGState()
        context.translateBy(x: -tileRect.minX, y: -tileRect.minY)
        for item in items {
            draw(item, style: style, in: context)
        }
        context.restoreGState()
    }
}

private extension NoteReviewDesktopTileOverlayView {
    enum Drawing {
        static let contentInset: CGFloat = Spacing.contentEdge
        static let blockSpacing: CGFloat = Spacing.base
        static let footerSpacing: CGFloat = Spacing.compact
        static let cornerRadius: CGFloat = CornerRadius.blockLarge
    }

    func draw(
        _ item: NoteReviewDesktopTileItem,
        style: NoteReviewDesktopTileStyle,
        in context: CGContext
    ) {
        context.saveGState()
        context.translateBy(x: item.frame.midX, y: item.frame.midY)
        context.rotate(by: item.rotation)
        context.translateBy(x: -item.frame.midX, y: -item.frame.midY)

        let path = UIBezierPath(
            roundedRect: item.frame,
            cornerRadius: Drawing.cornerRadius
        )
        style.surfaceColor.setFill()
        path.fill()
        (item.isSelected ? style.bodyTextColor : style.supplementTextColor)
            .withAlphaComponent(item.isSelected ? 0.34 : 0.16)
            .setStroke()
        path.lineWidth = StrokeWidth.hairline
        if item.isSelected {
            path.stroke()
        } else {
            // 底图保留外半圈纸边；覆盖层只补回被不透明纸面遮住的内半圈，避免边线叠加变深。
            context.saveGState()
            path.addClip()
            path.stroke()
            context.restoreGState()
        }
        path.addClip()

        if item.isLoaded {
            drawLoadedContent(item, style: style)
        } else {
            drawPlaceholder(for: item, style: style)
        }
        context.restoreGState()
    }

    func drawLoadedContent(_ item: NoteReviewDesktopTileItem, style: NoteReviewDesktopTileStyle) {
        let contentRect = item.frame.insetBy(
            dx: Drawing.contentInset,
            dy: Drawing.contentInset
        )
        guard contentRect.width > 0, contentRect.height > 0 else { return }

        var footerTop = contentRect.maxY
        if let chapter = normalized(item.chapter) {
            let height = textHeight(
                chapter,
                font: style.chapterFont,
                width: contentRect.width,
                maximumLines: 2
            )
            footerTop -= height
            drawText(
                chapter,
                in: CGRect(x: contentRect.minX, y: footerTop, width: contentRect.width, height: height),
                font: style.chapterFont,
                color: style.metadataTextColor,
                lineSpacing: 0,
                alignment: style.auxiliaryAlignment
            )
        }
        if let bookTitle = normalized(item.bookTitle) {
            if footerTop < contentRect.maxY { footerTop -= Drawing.footerSpacing }
            let height = textHeight(
                bookTitle,
                font: style.bookFont,
                width: contentRect.width,
                maximumLines: 2
            )
            footerTop -= height
            drawText(
                bookTitle,
                in: CGRect(x: contentRect.minX, y: footerTop, width: contentRect.width, height: height),
                font: style.bookFont,
                color: style.sourceTextColor,
                lineSpacing: 0,
                alignment: style.auxiliaryAlignment
            )
        }

        let hasFooter = footerTop < contentRect.maxY
        let previewBottom = hasFooter ? footerTop - Drawing.blockSpacing : contentRect.maxY
        let body = normalized(item.body)
        let idea = normalized(item.idea)
        guard body != nil || idea != nil, previewBottom > contentRect.minY else { return }
        var nextPreviewY = contentRect.minY
        if let body, item.bodyLineCount > 0 {
            let bodyHeight = min(
                lineHeight(
                    count: item.bodyLineCount,
                    font: style.bodyFont,
                    lineSpacing: ReadingContentTypography.bodyLineSpacing
                ),
                max(0, previewBottom - nextPreviewY)
            )
            let bodyRect = CGRect(
                x: contentRect.minX,
                y: nextPreviewY,
                width: contentRect.width,
                height: bodyHeight
            )
            drawText(
                body,
                in: bodyRect,
                font: style.bodyFont,
                color: style.bodyTextColor,
                lineSpacing: ReadingContentTypography.bodyLineSpacing,
                alignment: style.bodyAlignment
            )
            if item.isBodyTruncated {
                drawFade(in: bodyRect, surfaceColor: style.surfaceColor, isDarkAppearance: style.isDarkAppearance)
            }
            nextPreviewY = bodyRect.maxY
        }

        if let idea, item.ideaLineCount > 0 {
            if nextPreviewY > contentRect.minY {
                nextPreviewY += Drawing.blockSpacing
            }
            let ideaHeight = min(
                lineHeight(
                    count: item.ideaLineCount,
                    font: style.ideaFont,
                    lineSpacing: ReadingContentTypography.annotationLineSpacing
                ),
                max(0, previewBottom - nextPreviewY)
            )
            drawText(
                idea,
                in: CGRect(
                    x: contentRect.minX,
                    y: nextPreviewY,
                    width: contentRect.width,
                    height: ideaHeight
                ),
                font: style.ideaFont,
                color: style.supplementTextColor,
                lineSpacing: ReadingContentTypography.annotationLineSpacing,
                alignment: style.bodyAlignment
            )
        }
    }

    func drawPlaceholder(
        for item: NoteReviewDesktopTileItem,
        style: NoteReviewDesktopTileStyle
    ) {
        _ = item
        _ = style
    }

    func drawText(
        _ text: String,
        in rect: CGRect,
        font: UIFont,
        color: UIColor,
        lineSpacing: CGFloat,
        alignment: NSTextAlignment
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        paragraph.lineSpacing = lineSpacing
        paragraph.lineBreakMode = .byTruncatingTail
        NSAttributedString(
            string: text,
            attributes: [
                .font: font,
                .foregroundColor: color,
                .paragraphStyle: paragraph
            ]
        ).draw(
            with: rect,
            options: [.usesLineFragmentOrigin, .usesFontLeading, .truncatesLastVisibleLine],
            context: nil
        )
    }

    func textHeight(
        _ text: String,
        font: UIFont,
        width: CGFloat,
        maximumLines: Int?
    ) -> CGFloat {
        let measured = ceil(
            (text as NSString).boundingRect(
                with: CGSize(width: width, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading],
                attributes: [.font: font],
                context: nil
            ).height
        )
        guard let maximumLines else { return measured }
        return min(measured, ceil(font.lineHeight * CGFloat(maximumLines)))
    }

    /// 复用近景测量的行数语义，确保远景只改变栅格精度而不重新分配正文与想法层级。
    func lineHeight(count: Int, font: UIFont, lineSpacing: CGFloat) -> CGFloat {
        guard count > 0 else { return 0 }
        return ceil(
            font.lineHeight * CGFloat(count)
                + lineSpacing * CGFloat(max(0, count - 1))
        )
    }

    func drawFade(in rect: CGRect, surfaceColor: UIColor, isDarkAppearance: Bool) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let fadeHeight = isDarkAppearance ? min(8, rect.height) : rect.height * (1 - 0.68)
        let fadeRect = CGRect(
            x: rect.minX,
            y: max(rect.minY, rect.maxY - fadeHeight),
            width: rect.width,
            height: min(fadeHeight, rect.height)
        )
        guard let gradient = CGGradient(
            colorsSpace: CGColorSpaceCreateDeviceRGB(),
            colors: [
                surfaceColor.withAlphaComponent(0).cgColor,
                surfaceColor.cgColor
            ] as CFArray,
            locations: [0, 1]
        ) else { return }
        context.saveGState()
        context.clip(to: fadeRect)
        context.drawLinearGradient(
            gradient,
            start: CGPoint(x: fadeRect.midX, y: fadeRect.minY),
            end: CGPoint(x: fadeRect.midX, y: fadeRect.maxY),
            options: []
        )
        context.restoreGState()
    }

    func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 全屏回顾的居中出处；仅用书名和章节收束内容归属，不引入封面及其他元数据干扰。
private struct NoteReviewSourceAttributionView: View {
    let title: String
    let chapter: String
    let titleFont: Font
    let sourceColor: Color
    let chapterColor: Color

    var body: some View {
        VStack(alignment: .center, spacing: Spacing.compact) {
            if !title.isEmpty {
                Text(title)
                    .font(titleFont)
                    .foregroundStyle(sourceColor)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !chapter.isEmpty {
                Text(chapter)
                    .font(ReadingContentTypography.metadata)
                    .foregroundStyle(chapterColor)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilitySummary)
    }

    private var accessibilitySummary: String {
        [title, chapter]
            .filter { !$0.isEmpty }
            .joined(separator: "，")
    }
}

/// 直接复用 RichText 解析缓存的只读 TextKit 视图，内部永不纵向滚动。
@MainActor
private final class NoteReviewReadOnlyRichTextView: UITextView {
    private var contentSignature = ""

    init() {
        let layoutManager = RichTextLayoutManager()
        layoutManager.bulletColor = .label
        layoutManager.quoteColor = .secondaryLabel
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)
        let container = NSTextContainer(
            size: CGSize(width: 0, height: CGFloat.greatestFiniteMagnitude)
        )
        container.widthTracksTextView = true
        container.lineFragmentPadding = 0
        layoutManager.addTextContainer(container)
        super.init(frame: .zero, textContainer: container)
        isEditable = false
        isSelectable = true
        isScrollEnabled = false
        backgroundColor = .clear
        textContainerInset = .zero
        adjustsFontForContentSizeCategory = true
        setContentCompressionResistancePriority(.required, for: .vertical)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(
        html: String,
        baseFont: UIFont,
        textColor: UIColor,
        lineSpacing: CGFloat,
        alignment: NSTextAlignment
    ) {
        let resolvedColor = textColor.resolvedColor(with: traitCollection)
        let signature = "\(String(describing: resolvedColor.cgColor.components))|\(traitCollection.accessibilityContrast.rawValue)|\(html.hashValue)|\(baseFont.fontName)|\(baseFont.pointSize)|\(lineSpacing)|\(alignment.rawValue)|\(traitCollection.userInterfaceStyle.rawValue)"
        guard signature != contentSignature else { return }
        contentSignature = signature
        textStorage.setAttributedString(
            RichText.resolvedAttributedString(
                html: html,
                baseFont: baseFont,
                textColor: textColor,
                lineSpacing: lineSpacing,
                textAlignment: alignment,
                traitCollection: traitCollection
            )
        )
        invalidateIntrinsicContentSize()
    }

    func clear() {
        contentSignature = ""
        textStorage.setAttributedString(NSAttributedString())
        invalidateIntrinsicContentSize()
    }
}

/// 使用项目统一 Nuke 请求构造器的页面私有图片视图，按目标点尺寸降采样并支持复用取消。
@MainActor
private final class NoteReviewRemoteImageView: UIImageView {
    private var loadingTask: Task<Void, Never>?
    private var representedURL: URL?

    init() {
        super.init(frame: .zero)
        contentMode = .scaleAspectFill
        backgroundColor = .tertiarySystemGroupedBackground
        isAccessibilityElement = true
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func load(rawURL: String, targetSize: CGSize, priority: XMImageRequestBuilder.Priority) {
        guard let url = XMImageRequestBuilder.normalizedURL(from: rawURL) else {
            cancel()
            return
        }
        guard representedURL != url || image == nil else { return }
        cancel()
        representedURL = url
        let request = XMImageLoadRequest(url: url, priority: priority, targetSizeInPoints: targetSize)
        loadingTask = Task { [weak self] in
            do {
                let loadedImage = try await ImagePipeline.shared.image(for: request.imageRequest)
                guard !Task.isCancelled, self?.representedURL == url else { return }
                self?.image = loadedImage
            } catch {
                guard !Task.isCancelled else { return }
            }
        }
    }

    func cancel() {
        loadingTask?.cancel()
        loadingTask = nil
        representedURL = nil
        image = nil
    }
}

/// 与最终布局等尺寸的中性占位表层；不使用会被误认成未完成内容的灰色横条或 shimmer。
private final class NoteReviewCellPlaceholderView: UIView {
    var mode: NoteReviewPresentationMode = .immersive {
        didSet {
            updateSurface()
        }
    }

    var immersiveTopInset: CGFloat = 132 {
        didSet {}
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        updateSurface()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func updateSurface() {
        backgroundColor = mode == .immersive ? .systemBackground : .clear
    }
}
